//! ESP32-C3 ADC1 software-triggered oneshot conversions (TRM v1.4 §34.2).
//! ADC2 is intentionally unavailable: SoC Errata v1.3, ADC-183 (§3.2).
//! Owns the ADC controller; do not combine with continuous ADC or radio ADC use.
//! Call after HAL initialization. Configure pads with gpio.Pin.Config.analog;
//! reads leave the pad configuration intact (including an output for loopback).

comptime {
    @import("../compatibility.zig").require_esp32_c3("hal.adc");
}

const std = @import("std");
const microzig = @import("microzig");
const efuse = @import("../efuse.zig");
const rom = @import("../rom.zig");
const system = @import("../system.zig");
const time = @import("../time.zig");
const ADC = microzig.chip.peripherals.APB_SARADC;
const RTC = microzig.chip.peripherals.RTC_CNTL;

/// TRM §34.2.3.1: channel number equals GPIO number for ADC1.
pub const Channel = enum(u3) { gpio0, gpio1, gpio2, gpio3, gpio4 };
pub const Attenuation = enum(u2) { db0, db2_5, db6, db12 };
/// C3 hardware supports only 12 bits (TRM §34.2.2; IDF adc_oneshot_ll_set_output_bits).
pub const BitWidth = enum(u5) { bits12 = 12 };
pub const Config = struct {
    attenuation: Attenuation = .db0,
    bit_width: BitWidth = .bits12,
};
pub const Sample = struct {
    raw: u12,
    /// Null means raw/uncalibrated. Values near saturation are not accurate
    /// voltage measurements; see the datasheet ADC characteristics.
    millivolts: ?i32,
};

pub const Adc1 = struct {
    /// Encoding version 1 only; null for absent or unsupported eFuse data.
    calibration: ?[4]efuse.AdcCalibration,

    pub fn init() Adc1 {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        system.enable_clocks_and_release_reset(.{ .apb_saradc = true });
        // ESP-IDF v5.3.1 adc_ll_digi_clk_sel uses CLK_SEL=2 for APB,
        // unlike TRM §34.2.3.4 / register 34.19, which says 0.
        ADC.CLKM_CONF.modify(.{ .CLK_SEL = 2, .CLK_EN = 1, .CLKM_DIV_NUM = 15, .CLKM_DIV_A = 0, .CLKM_DIV_B = 0 });
        // TRM §34.2.3.4 requires SAR divider >= 2. IDF's default is 1.
        ADC.CTRL.modify(.{ .SARADC_SAR_CLK_GATED = 1, .SARADC_SAR_CLK_DIV = 2, .SARADC_XPD_SAR_FORCE = 3, .SARADC_START_FORCE = 0, .SARADC_START = 0 });
        ADC.CTRL2.modify(.{ .SARADC_TIMER_EN = 0, .SARADC_MEAS_NUM_LIMIT = 0, .SARADC_SAR1_INV = 0 });
        // IDF adc_ll_digi_set_fsm_time defaults: reset=8, start=5, standby=100.
        ADC.FSM_WAIT.modify(.{ .SARADC_RSTB_WAIT = 8, .SARADC_XPD_WAIT = 5, .SARADC_STANDBY_WAIT = 100 });
        ADC.FILTER_CTRL0.modify(.{ .APB_SARADC_FILTER_CHANNEL0 = 15, .APB_SARADC_FILTER_CHANNEL1 = 15 });
        ADC.ONETIME_SAMPLE.modify(.{ .SARADC1_ONETIME_SAMPLE = 0, .SARADC2_ONETIME_SAMPLE = 0, .SARADC_ONETIME_START = 0 });
        // IDF adc_ll_set_sample_cycle / adc_ll_calibration_init/finish;
        // analog fields: soc/esp32c3/include/soc/regi2c_saradc.h (Apache-2.0).
        // regi2c_ctrl_ll_i2c_saradc_enable: power the analog register bus
        // before accessing it through the ROM I2C functions.
        microzig.chip.peripherals.I2C_ANA_MST.ANA_CONFIG.modify(.{ .SAR_FORCE_PD = 0 });
        microzig.chip.peripherals.I2C_ANA_MST.ANA_CONFIG2.modify(.{ .SAR_FORCE_PU = 1 });
        RTC.ANA_CONF.modify(.{ .SAR_I2C_PU = 1 });
        rom.functions.esp_rom_regi2c_write_mask(0x69, 0, 2, 2, 0, 2); // SAMPLE_CYCLE
        rom.functions.esp_rom_regi2c_write_mask(0x69, 0, 2, 6, 4, 1); // SAR1_DREF
        rom.functions.esp_rom_regi2c_write_mask(0x69, 0, 7, 5, 5, 0); // SAR1_ENCAL_GND
        rom.delay_us(100);
        return .{ .calibration = efuse.read_adc1_calibration() };
    }

    pub fn read(self: *const Adc1, channel: Channel, config: Config) error{Timeout}!Sample {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const atten = @backingInt(config.attenuation);
        _ = config.bit_width; // Sole hardware width: 12 bits.
        if (self.calibration) |cal| {
            // IDF adc_ll_set_calibration_param: each attenuation has its own offset.
            const code = cal[atten].init_code;
            rom.functions.esp_rom_regi2c_write_mask(0x69, 0, 1, 3, 0, @intCast(code >> 8));
            rom.functions.esp_rom_regi2c_write_mask(0x69, 0, 0, 7, 0, @truncate(code));
        }
        ADC.ONETIME_SAMPLE.modify(.{
            .SARADC_ONETIME_START = 0,
            .SARADC1_ONETIME_SAMPLE = 1,
            .SARADC2_ONETIME_SAMPLE = 0,
            .SARADC_ONETIME_CHANNEL = @backingInt(channel),
            .SARADC_ONETIME_ATTEN = atten,
        });
        // W1C: clear only ADC1's completion, never read/modify/write INT_CLR.
        ADC.INT_CLR.write(.{ .APB_SARADC1_DONE_INT_CLR = 1 });
        rom.delay_us(1);
        ADC.ONETIME_SAMPLE.modify(.{ .SARADC_ONETIME_START = 1 });
        // IDF adc_oneshot_ll_start requires a pulse >= 3 controller clocks.
        rom.delay_us(2);
        defer {
            ADC.ONETIME_SAMPLE.modify(.{ .SARADC_ONETIME_START = 0, .SARADC1_ONETIME_SAMPLE = 0 });
            ADC.INT_CLR.write(.{ .APB_SARADC1_DONE_INT_CLR = 1 });
        }
        const deadline = microzig.drivers.time.make_timeout_us(time.get_time_since_boot(), 1000);
        while (ADC.INT_RAW.read().APB_SARADC1_DONE_INT_RAW == 0) {
            if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
        }
        const raw: u12 = @truncate(ADC.SAR1DATA_STATUS.read().APB_SARADC1_DATA);
        return .{
            .raw = raw,
            .millivolts = if (self.calibration) |cal| calibrated_mv(raw, config.attenuation, cal[atten]) else null,
        };
    }
};

// Arithmetic and numeric coefficients ported from ESP-IDF v5.3.1 (Apache-2.0):
// adc_cali_curve_fitting.c: calc_first_step_coefficients, cali_raw_to_voltage,
// get_reading_error; esp32c3/curve_fitting_coefficients.c: adc1_error_coef_atten.
// Keep integer truncation per term, as in IDF. u64 covers the full u12 input
// even at the smallest valid v1 reference code (1489).
fn calibrated_mv(raw: u12, attenuation: Attenuation, cal: efuse.AdcCalibration) i32 {
    const slope = @as(u64, 65536) * cal.reference_mv / cal.reference_code;
    const voltage = @as(u64, raw) * slope / 65536;
    if (voltage == 0) return 0;
    const coefficients = [_][5]u64{
        .{ 225966470500043, 7265418501948, 109410402681, 0, 0 },
        .{ 4229623392600516, 731527490903, 88166562521, 0, 0 },
        .{ 1017859239236435, 97159265299153, 149794028038, 0, 0 },
        .{ 14912262772850453, 228549975564099, 356391935717, 179964582, 42046 },
    };
    const signs = [_][5]i32{
        .{ -1, -1, 1, 0, 0 }, .{ 1, -1, 1, 0, 0 },
        .{ -1, -1, 1, 0, 0 }, .{ -1, -1, 1, -1, 1 },
    };
    const atten = @backingInt(attenuation);
    var power: u64 = 1;
    var correction: i32 = 0;
    for (0..if (attenuation == .db12) @as(usize, 5) else 3) |i| {
        const divisor: u64 = if (i == 0 and (attenuation == .db0 or attenuation == .db6)) 1_000_000_000_000_000 else 10_000_000_000_000_000;
        const term: i32 = @intCast(power * coefficients[atten][i] / divisor);
        correction += term * signs[atten][i];
        if (i < 4) power *= voltage;
    }
    return @as(i32, @intCast(voltage)) - correction;
}

test "curve fitting reference vectors and full scale extremes" {
    const expect = std.testing.expectEqual;
    // Independent reference vectors from the IDF integer polynomial.
    const refs = [4]u16{ 400, 550, 750, 1370 };
    const expected = [4]i32{ 398, 547, 750, 1367 };
    const full_scale = [4][2]i32{ .{ 1087, 648 }, .{ 1492, 889 }, .{ 2020, 1213 }, .{ 3464, 2205 } };
    inline for (0..4) |i| {
        const cal: efuse.AdcCalibration = .{ .init_code = 1000, .reference_code = 2000, .reference_mv = refs[i] };
        try expect(@as(i32, 0), calibrated_mv(0, @fromBackingInt(@intCast(i)), cal));
        try expect(expected[i], calibrated_mv(2000, @fromBackingInt(@intCast(i)), cal));
        for ([_]u12{ 1489, 2511 }, full_scale[i]) |reference_code, expected_full_scale| {
            try expect(expected_full_scale, calibrated_mv(4095, @fromBackingInt(@intCast(i)), .{ .init_code = 2023, .reference_code = reference_code, .reference_mv = refs[i] }));
        }
    }
}
