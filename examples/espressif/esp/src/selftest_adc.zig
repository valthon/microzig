//! No wiring: ADC1 channel 0 senses its own GPIO0 output driver.
//! C6 datasheet v1.6 §2.3.3, table 2-9: GPIO0 (QFN32 pin 6) is
//! ADC1_CH0. It is free on the unwired C6 Super Mini; USB
//! uses GPIO12/13. Keep GPIO0 connected only to its own output driver.
//! C6 uses the LP GPIO driver: TRM v1.2 §7.7.2–7.7.3 and §7.13.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;

pub const panic = microzig.panic;
pub const std_options: std.Options = .{
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_level = .info,
};
comptime {
    _ = microzig.export_startup();
}

const PadResult = struct {
    attenuation: u2 = 0,
    low: ?hal.adc.Sample = null,
    high: ?hal.adc.Sample = null,
    low_driven: bool = true,
    high_driven: bool = true,

    fn low_pass(self: PadResult) bool {
        return self.low_driven and if (self.low) |sample| sample.raw <= 200 else false;
    }
    fn high_pass(self: PadResult) bool {
        if (!self.high_driven) return false;
        const sample = self.high orelse return false;
        if (sample.millivolts) |mv| return mv >= self.high_min_mv();
        // VDD saturates atten0..2 on both chips. C6 atten3 needs voltage
        // calibration: an absent eFuse must not turn that check into a pass.
        if (hal.compatibility.chip == .esp32_c6 and self.attenuation == 3) return false;
        return sample.raw >= 3800;
    }

    fn high_min_mv(self: PadResult) i32 {
        // C6 datasheet v1.6 §5.5 table 5-6: tops 1000/1300/1900/3300
        // mV, total errors ±12/12/23/40 mV (date-code qualification applies).
        // Atten0..2 must reach the range top minus error, even though VDD
        // overdrives them. At 12 dB use 3000 mV, allowing supply/pad drop
        // as well as the ±40 mV error; this is a rail check, not a voltmeter.
        // C3 datasheet v2.5 §5.5 table 5-6: tops 750/1050/1300/2500
        // mV with ±10/10/10/35 mV error. Its calibration stays unchanged.
        return switch (hal.compatibility.chip) {
            .esp32_c3 => ([4]i32{ 740, 1040, 1290, 2465 })[self.attenuation],
            .esp32_c6 => ([4]i32{ 988, 1288, 1877, 3000 })[self.attenuation],
        };
    }
};

fn verdict(pass: bool) []const u8 {
    return if (pass) "PASS" else "FAIL";
}

pub fn main() void {
    var init_error: ?[]const u8 = null;
    const adc: ?hal.adc.Adc1 = switch (hal.compatibility.chip) {
        .esp32_c3 => hal.adc.Adc1.init(),
        .esp32_c6 => hal.adc.Adc1.init() catch |err| blk: {
            init_error = @errorName(err);
            break :blk null;
        },
    };
    const pin = hal.gpio.num(0);
    pin.put(0);
    // Keep the digital input buffer off; only output driver and SAR share pad.
    pin.apply(.{ .output_enable = true });
    if (hal.compatibility.chip == .esp32_c6) {
        const p = microzig.chip.peripherals;
        // HP GPIO output does not control an LP-muxed analog pad (§7.7.2).
        // Function 0 is LP_GPIO0 (§7.13 table 7.13-1) and permits analog
        // access (§7.7.3). Unlike an external-input ADC application, this
        // test deliberately enables the LP output driver as its stimulus.
        pin.set_output_enabled(false);
        p.LP_PERI.CLK_EN.modify(.{ .LP_IO_CK_EN = 1 });
        p.LP_IO.OUT_ENABLE_W1TC.write(.{ .ENABLE_W1TC = 1 });
        p.LP_IO.OUT_DATA_W1TC.write(.{ .OUT_DATA_W1TC = 1 });
        p.LP_IO.GPIO0.write(.{ .MCU_SEL = 0, .FUN_IE = 0, .FUN_WPU = 0, .FUN_WPD = 0 });
        p.LP_IO.PIN0.modify(.{ .PAD_DRIVER = 0 });
        p.LP_AON.GPIO_MUX.modify(.{ .SEL = p.LP_AON.GPIO_MUX.read().SEL | 1 });
        p.LP_IO.OUT_ENABLE_W1TS.write(.{ .ENABLE_W1TS = 1 });
    }
    var results: [4]PadResult = @splat(.{});
    for (&results, 0..) |*result, i| {
        result.attenuation = @intCast(i);
        const config: hal.adc.Config = .{ .attenuation = @fromBackingInt(@intCast(i)) };
        result.low_driven = drive_pad(0);
        result.low = read_pad(adc, config);
        result.high_driven = drive_pad(1);
        result.high = read_pad(adc, config);
    }
    pin.put(0);
    pin.apply(.analog);
    if (hal.compatibility.chip == .esp32_c6) {
        microzig.chip.peripherals.LP_IO.OUT_ENABLE_W1TC.write(.{ .ENABLE_W1TC = 1 });
    }

    const temperature_ready = switch (hal.compatibility.chip) {
        .esp32_c3 => blk: {
            hal.temperature.init();
            break :blk true;
        },
        .esp32_c6 => blk: {
            hal.temperature.init() catch break :blk false;
            break :blk true;
        },
    };
    const first = if (temperature_ready) hal.temperature.read_celsius() else std.math.nan(f32);
    hal.time.sleep_ms(100);
    const second = if (temperature_ready) hal.temperature.read_celsius() else std.math.nan(f32);
    const range_pass = first >= 0 and first <= 80 and second >= 0 and second <= 80;
    const stable_pass = @abs(second - first) < 5;
    var passed: usize = @intFromBool(range_pass) + @as(usize, @intFromBool(stable_pass));
    for (results) |result| {
        passed += @intFromBool(result.low_pass());
        passed += @intFromBool(result.high_pass());
    }

    hal.time.sleep_ms(1500);
    while (true) {
        if (hal.compatibility.chip == .esp32_c3) {
            std.log.info("ADC calibration: {s} version={d} (0=raw, 1=efuse)", .{
                if (adc.?.calibration != null) "efuse" else "raw", @as(u8, if (adc.?.calibration != null) 1 else 0),
            });
        } else {
            std.log.info("ADC C6: init_ok={} init_error={?s} temperature_init_ok={} efuse_calibration={}", .{
                adc != null, init_error, temperature_ready, adc != null and adc.?.calibration != null,
            });
            if (adc) |converter| std.log.info("ADC C6 offset_codes atten0..3={any} source={s}", .{
                converter.offset_codes, if (converter.calibration != null) "efuse" else "internal_ground",
            });
            if (adc) |converter| {
                if (converter.calibration) |cal| std.log.info("ADC C6 calibration: version={s} reference_codes={any} reference_mv={any} channel_compensation={any}", .{
                    @tagName(cal.version), cal.reference_codes, cal.reference_mv, cal.channel_compensation,
                });
            }
        }
        for (results, 0..) |result, i| {
            if (hal.compatibility.chip == .esp32_c6) {
                std.log.info("ADC C6 atten{d} pad_drive: low_ok={} high_ok={}", .{ i, result.low_driven, result.high_driven });
            }
            std.log.info("SELFTEST adc atten{d}_low: {s} raw={?d} mv={?d} expected<=200 timeout={}", .{
                i,                                          verdict(result.low_pass()), if (result.low) |s| s.raw else null,
                if (result.low) |s| s.millivolts else null, result.low == null,
            });
            const calibrated = if (result.high) |s| s.millivolts != null else false;
            const needs_calibration = hal.compatibility.chip == .esp32_c6 and i == 3;
            std.log.info("SELFTEST adc atten{d}_high: {s} raw={?d} mv={?d} expected_{s}>={d} calibration_required={} timeout={}", .{
                i,                                           verdict(result.high_pass()),                          if (result.high) |s| s.raw else null,
                if (result.high) |s| s.millivolts else null, if (calibrated or needs_calibration) "mv" else "raw", if (calibrated or needs_calibration) result.high_min_mv() else @as(i32, 3800),
                needs_calibration,                           result.high == null,
            });
        }
        std.log.info("SELFTEST adc temperature_range: {s} first={d:.2}C second={d:.2}C expected=0..80C", .{ verdict(range_pass), first, second });
        std.log.info("SELFTEST adc temperature_stable: {s} delta={d:.2}C expected<5C interval=100ms", .{ verdict(stable_pass), @abs(second - first) });
        std.log.info("SELFTEST adc DONE pass={d} fail={d}", .{ passed, 10 - passed });
        hal.time.sleep_ms(1000);
    }
}

fn drive_pad(level: u1) bool {
    if (hal.compatibility.chip == .esp32_c6) {
        const lp = microzig.chip.peripherals.LP_IO;
        // TRM v1.2 §7.16.4: W1TS/W1TC drive LP_GPIO0, IN reads the pad.
        // Check the actual pad, then disable its digital input for sampling.
        if (level == 1) {
            lp.OUT_DATA_W1TS.write(.{ .OUT_DATA_W1TS = 1 });
        } else {
            lp.OUT_DATA_W1TC.write(.{ .OUT_DATA_W1TC = 1 });
        }
        lp.GPIO0.modify(.{ .FUN_IE = 1 });
        hal.time.sleep_ms(1);
        const driven = (lp.IN.read().DATA_NEXT & 1) == level;
        lp.GPIO0.modify(.{ .FUN_IE = 0 });
        return driven;
    }
    hal.gpio.num(0).put(level);
    hal.time.sleep_ms(1);
    return true;
}

fn read_pad(adc: ?hal.adc.Adc1, config: hal.adc.Config) ?hal.adc.Sample {
    return if (adc) |a| a.read(.gpio0, config) catch null else null;
}
