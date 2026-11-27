//! No-wiring analog peripheral checks for the USB-powered XIAO nRF52840 Sense.
const microzig = @import("microzig");
const nrf = microzig.hal;
const harness = @import("harness.zig");

pub const panic = microzig.panic;
pub const init = harness.init;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

const suite = "analog";

pub fn main() void {
    check_reset_reason();
    check_wdt();
    check_saadc();
    check_temp();
    check_rng("rng_corrected", .enabled, 35, 65);
    check_rng("rng_raw", .disabled, 25, 75);
    harness.finish(suite);
}

fn deadline_us(us: u64) microzig.drivers.time.Absolute {
    return microzig.drivers.time.make_timeout_us(nrf.time.get_time_since_boot(), us);
}

// Keep DMA storage reserved for the life of the test even if STOP fails.
var vdd_sample: i16 align(4) = undefined;
var vdd_samples: [8]i16 align(4) = undefined;

fn check_saadc() void {
    nrf.saadc.calibrate_offset(deadline_us(20_000)) catch |err| {
        harness.check(suite, "saadc_calibration", false, "{s}", .{@errorName(err)});
        return;
    };
    harness.check(suite, "saadc_calibration", true, "CALIBRATEDONE", .{});

    // Seeed Sense schematic, sheet 3, System 3.3V and nRF52840 blocks.
    // PS v1.11 §§5.3.1 and 6.23.3. Internal 600 mV reference, VDD at gain 1/6.
    const vdd = nrf.saadc.sample(.{ .positive = .VDD }, &vdd_sample, deadline_us(20_000)) catch |err| {
        harness.check(suite, "saadc_vdd", false, "{s}", .{@errorName(err)});
        return;
    };
    const vdd_mv = @divTrunc(@as(i32, vdd) * 3600, 4096);
    harness.check(suite, "saadc_vdd", vdd_mv >= 3000 and vdd_mv <= 3550, "{d} mV", .{vdd_mv});

    // A buffered, oversampled VDD conversion. VDDHDIV5 is not used here: on
    // this board VDDH is tied to VDD, and VDDHDIV5 read 1.7-2.1 V for the
    // 3.3 V rail depending on gain, with no change from a longer acquisition
    // time (measured; see the port README). The high limit, 3.0 V at gain 1/6,
    // makes normal samples raise LIMITH.
    nrf.saadc.sample_buffer(.{
        .positive = .VDD,
        .oversampling = .Over4x,
        .low = 0,
        .high = 3413,
    }, &vdd_samples, deadline_us(20_000)) catch |err| {
        harness.check(suite, "saadc_vdd_buffer", false, "{s}", .{@errorName(err)});
        return;
    };
    var plausible = true;
    var sum_mv: i32 = 0;
    for (vdd_samples) |raw| {
        const mv = @divTrunc(@as(i32, raw) * 3600, 4096);
        plausible = plausible and mv >= 3000 and mv <= 3550;
        sum_mv += mv;
    }
    harness.check(suite, "saadc_vdd_buffer", plausible, "mean={d} mV", .{@divTrunc(sum_mv, vdd_samples.len)});
    const limits = nrf.saadc.limit_events();
    harness.check(suite, "saadc_limits", limits.high and !limits.low, "high={} low={}", .{ limits.high, limits.low });
}

fn check_temp() void {
    // TEMP accuracy requires HFCLK from the crystal (PS v1.11 §6.28).
    const clock = microzig.chip.peripherals.CLOCK;
    clock.TASKS_HFCLKSTART.write_raw(1);
    const deadline = deadline_us(20_000);
    while (true) {
        const status = clock.HFCLKSTAT.read();
        if (status.SRC == .Xtal and status.STATE == .Running) break;
        if (deadline.is_reached_by(nrf.time.get_time_since_boot())) {
            harness.check(suite, "temp", false, "HFXO timeout", .{});
            return;
        }
    }

    nrf.temp.init();
    const quarters = nrf.temp.read(deadline_us(20_000)) catch |err| {
        harness.check(suite, "temp", false, "{s}", .{@errorName(err)});
        return;
    };
    harness.check(suite, "temp", quarters >= 40 and quarters <= 200, "{d} quarter-degrees Celsius", .{quarters});
}

fn check_rng(case: []const u8, correction: nrf.rng.BiasCorrection, min_percent: usize, max_percent: usize) void {
    var bytes: [64]u8 = undefined;
    nrf.rng.fill(&bytes, correction, deadline_us(250_000)) catch |err| {
        harness.check(suite, case, false, "{s}", .{@errorName(err)});
        return;
    };

    var ones: usize = 0;
    var varied = false;
    for (bytes) |byte| {
        ones += @popCount(byte);
        varied = varied or byte != bytes[0];
    }
    const bits = bytes.len * 8;
    const plausible = ones * 100 >= bits * min_percent and ones * 100 <= bits * max_percent;
    harness.check(suite, case, varied and plausible, "ones={d}/{d} varied={}", .{ ones, bits, varied });
}

fn check_reset_reason() void {
    // Fallback clears the flags through the HAL before starting the timebase.
    const reasons = harness.boot_reset_reason;
    const remaining: u32 = @bitCast(nrf.power.reset_reason());
    harness.check(suite, "power_resetreas", remaining == 0, "before=0x{x} after=0x{x}", .{
        @as(u32, @bitCast(reasons)), remaining,
    });
}

fn check_wdt() void {
    // The harness requests a 20 s timeout only for a fresh watchdog. These
    // checks observe run status and RR0 enablement.
    const wdt = microzig.chip.peripherals.WDT;
    const running = nrf.wdt.is_running();
    const rr0_enabled = wdt.RREN.read().RR0 == .Enabled;
    harness.check(suite, "wdt_running", running, "RUNSTATUS running={}", .{running});
    harness.check(suite, "wdt_rr0_enabled", rr0_enabled, "RREN.RR0 enabled={}", .{rr0_enabled});
}
