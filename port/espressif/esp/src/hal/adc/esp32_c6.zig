//! C6 ADC1 oneshot conversions, TRM v1.2 §39.2. Owns the controller;
//! do not combine with continuous/radio ADC use. Configure pads separately;
//! read preserves the output driver for same-pad loopback. Initialization
//! and reads report analog-bus/conversion timeouts to the caller.
const microzig = @import("microzig");
const efuse = @import("../efuse.zig");
const calibration_c6 = @import("calibration_c6.zig");
const rom = @import("../rom.zig");
const analog = @import("../analog/esp32_c6.zig");
const PCR = microzig.chip.peripherals.PCR;
const time = @import("../time.zig");
const ADC = microzig.chip.peripherals.APB_SARADC;
pub const Error = analog.Error || error{CalibrationFailed};

/// C6 TRM v1.2 §39.2.3.1, table 39.2-1; datasheet v1.6 table 2-9.
pub const Channel = enum(u3) { gpio0, gpio1, gpio2, gpio3, gpio4, gpio5, gpio6 };
pub const Attenuation = enum(u2) { db0, db2_5, db6, db12 };
/// C6 TRM v1.2 §39.2.2: 12-bit resolution.
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
    /// Null for unprogrammed eFuses; internal-ground calibration still supplies offsets.
    calibration: ?calibration_c6.Calibration,
    /// Effective per-attenuation hardware codes, from eFuse or internal-ground
    /// self-calibration when the eFuse version is unavailable.
    offset_codes: [4]u12,

    pub fn init() Error!Adc1 {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        // Restore MODEM_APB before the FE register writes below. PCR SARADC
        // clocks alone cannot make the modem/analog register bank accessible.
        analog.enable();
        // The SAR front end also needs MODEM clocks: PCR alone only clocks
        // the digital controller. ESP-IDF sar_periph_ctrl.c s_sar_power_acquire
        // and esp32c6/modem_clock_hal.c enable these before acquiring SAR.
        // modem_clock_module_enable also opens the domain's ICG map. Use
        // the current PMU code (RAM boot need not have IDF's active code 2)
        // and preserve the maps for other states/domains. No sleep support.
        const modem = microzig.chip.peripherals.MODEM_SYSCON;
        const pmu_code = microzig.chip.peripherals.PMU.CLK_STATE0.read().ICG_MODEM_CODE_STATE;
        modem.CLK_CONF_POWER_ST.modify(.{
            .CLK_FE_ST_MAP = modem.CLK_CONF_POWER_ST.read().CLK_FE_ST_MAP | (@as(u4, 1) << pmu_code),
        });
        microzig.chip.peripherals.MODEM_SYSCON.CLK_CONF1.modify(.{ .CLK_FE_APB_EN = 1, .CLK_FE_80M_EN = 1 });
        // C6 TRM v1.2 §8.5.1, registers 8.31–8.32: separate register
        // clock/reset and functional clock. Match IDF's oneshot dividers:
        // XTAL / (15 + 1) = 2.5 MHz, then SAR divider 1.
        // §39.2.3's >=15 guidance differs from adc_ll.h's SAR default;
        // use the chip-specific IDF oneshot setup rather than combining them.
        // system.init also asserts the separate function reset (captured
        // SARADC_CONF=0x6). Release it as well as the APB register reset.
        // Do not pulse either reset: temperature shares the register block.
        PCR.SARADC_CONF.modify(.{ .SARADC_RST_EN = 0, .SARADC_REG_CLK_EN = 1, .SARADC_REG_RST_EN = 0 });
        PCR.SARADC_CLKM_CONF.modify(.{ .SARADC_CLKM_EN = 1, .SARADC_CLKM_SEL = 0, .SARADC_CLKM_DIV_NUM = 15, .SARADC_CLKM_DIV_A = 0, .SARADC_CLKM_DIV_B = 1 });
        // Use digital-controller power ownership, not PWDET/radio ownership.
        // adc_ll_set_power_manage: force=3 is SW on; 0 is FSM, 2 SW off.
        // sar_ctrl_ll_force_power_ctrl_from_pwdet(false) selects this path.
        ADC.CTRL.modify(.{ .SARADC_SAR_CLK_GATED = 1, .SARADC_SAR_CLK_DIV = 1, .SARADC_XPD_SAR_FORCE = 3, .SARADC2_PWDET_DRV = 0, .SARADC_START_FORCE = 0, .SARADC_START = 0 });
        ADC.CTRL2.modify(.{ .SARADC_TIMER_EN = 0, .SARADC_MEAS_NUM_LIMIT = 0, .SARADC_SAR1_INV = 0 });
        // IDF adc_ll_digi_set_fsm_time defaults: reset=8, start=5, standby=100.
        ADC.FSM_WAIT.modify(.{ .SARADC_RSTB_WAIT = 8, .SARADC_XPD_WAIT = 5, .SARADC_STANDBY_WAIT = 100 });
        ADC.FILTER_CTRL0.modify(.{ .APB_SARADC_FILTER_CHANNEL0 = 15, .APB_SARADC_FILTER_CHANNEL1 = 15 });
        ADC.ONETIME_SAMPLE.modify(.{ .SARADC1_ONETIME_SAMPLE = 0, .SARADC2_ONETIME_SAMPLE = 0, .SARADC_ONETIME_START = 0 });
        // ESP-IDF v5.4 adc_ll_set_sample_cycle/calibration_init/finish,
        // soc/esp32c6/include/soc/regi2c_saradc.h (Apache-2.0).
        try analog.write_mask(2, 2, 0, 2); // SAMPLE_CYCLE
        try analog.write_mask(2, 6, 4, 1); // SAR1_DREF
        try analog.write_mask(7, 5, 5, 0); // SAR1_ENCAL_GND
        // adc_ll_regi2c_adc_deinit: leave the bootloader RNG's internal
        // test/reference path and sample the pad. Preserve TSENS bit 2.
        try analog.write_mask(7, 1, 0, 0); // DTEST_RTC
        try analog.write_mask(7, 3, 3, 0); // ENT_RTC
        try analog.write_mask(7, 4, 4, 0); // SAR1_ENCAL_REF
        try analog.write_mask(7, 6, 6, 0); // SAR2_ENCAL_REF (RNG compatibility)
        rom.delay_us(100);
        const calibration = read_calibration();
        return .{ .calibration = calibration, .offset_codes = if (calibration) |cal| cal.init_codes else try calibrate_offsets() };
    }

    pub fn read(self: *const Adc1, channel: Channel, config: Config) analog.Error!Sample {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        defer {
            ADC.ONETIME_SAMPLE.modify(.{ .SARADC_ONETIME_START = 0, .SARADC1_ONETIME_SAMPLE = 0 });
            ADC.INT_CLR.write(.{ .APB_SARADC1_DONE_INT_CLR = 1 });
        }
        const atten = @backingInt(config.attenuation);
        _ = config.bit_width; // Sole hardware width: 12 bits.
        try set_offset(self.offset_codes[atten]);
        const raw = try convert(@backingInt(channel), atten);
        return .{
            .raw = raw,
            .millivolts = if (self.calibration) |cal| cal.millivolts(raw, @backingInt(channel), atten) else null,
        };
    }
};

fn set_offset(code: u12) analog.Error!void {
    try analog.write_mask(1, 3, 0, @intCast(code >> 8));
    try analog.write_mask(0, 7, 0, @truncate(code));
}

// C6 TRM v1.2 §§39.2.3.2–39.2.3.3 describes attenuation and oneshot
// conversion, but does not specify the internal offset calibration protocol.
// Follow ESP-IDF v5.4 components/hal/adc_hal_common.c,
// adc_hal_self_calibration, and hal/esp32c6/include/hal/adc_ll.h:
// disconnect pads (channel 15), connect internal ground, find the first
// zero-output initial code ten times, discard extremes, round the mean.
fn calibrate_offsets() Error![4]u12 {
    try analog.write_mask(7, 5, 5, 1); // SAR1_ENCAL_GND
    const codes = calibrate_ground() catch |err| {
        // Cleanup failures are propagated too: never leave an apparently
        // usable ADC sampling internal ground instead of the selected pad.
        try analog.write_mask(7, 5, 5, 0);
        return err;
    };
    try analog.write_mask(7, 5, 5, 0);
    return codes;
}

fn calibrate_ground() Error![4]u12 {
    defer {
        ADC.ONETIME_SAMPLE.modify(.{ .SARADC_ONETIME_START = 0, .SARADC1_ONETIME_SAMPLE = 0 });
        ADC.INT_CLR.write(.{ .APB_SARADC1_DONE_INT_CLR = 1 });
    }
    var codes: [4]u12 = undefined;
    for (&codes, 0..) |*code, atten| {
        var sum: u32 = 0;
        var minimum: u12 = 4095;
        var maximum: u12 = 0;
        for (0..10) |_| {
            var low: u13 = 0;
            var high: u13 = 4096;
            while (high - low > 1) {
                const middle: u12 = @intCast((high + low) / 2);
                try set_offset(middle);
                if (try convert(15, @intCast(atten)) == 0) {
                    high = middle;
                } else {
                    low = middle;
                }
            }
            if (high == 4096) return error.CalibrationFailed;
            const result: u12 = @intCast(high);
            sum += result;
            minimum = @min(minimum, result);
            maximum = @max(maximum, result);
        }
        code.* = @intCast((sum - minimum - maximum + 4) / 8);
    }
    return codes;
}

fn convert(channel: u4, atten: u2) analog.Error!u12 {
    ADC.ONETIME_SAMPLE.modify(.{
        .SARADC_ONETIME_START = 0,
        .SARADC1_ONETIME_SAMPLE = 1,
        .SARADC2_ONETIME_SAMPLE = 0,
        .SARADC_ONETIME_CHANNEL = channel,
        .SARADC_ONETIME_ATTEN = atten,
    });
    // W1C: clear only ADC1's completion, never read/modify/write INT_CLR.
    ADC.INT_CLR.write(.{ .APB_SARADC1_DONE_INT_CLR = 1 });
    // C6 TRM v1.2 §39.2.3.3 gives the enable/channel/atten/start
    // sequence. The additional channel-selection settling requirement
    // comes from local ESP-IDF components/esp_hal_ana_conv/esp32c6/
    // include/hal/adc_ll.h, adc_oneshot_ll_enable: wait 50 us after
    // enabling oneshot. Cleanup disables it, so every read must settle.
    rom.delay_us(50);
    ADC.ONETIME_SAMPLE.modify(.{ .SARADC_ONETIME_START = 1 });
    // adc_oneshot_hal.c adc_hal_onetime_start drives BOTH edges before
    // waiting for done. At 2.5 MHz, IDF rounds the >=3-cycle delay to 3 us.
    rom.delay_us(3);
    ADC.ONETIME_SAMPLE.modify(.{ .SARADC_ONETIME_START = 0 });
    rom.delay_us(3);
    const deadline = microzig.drivers.time.make_timeout_us(time.get_time_since_boot(), 1000);
    while (ADC.INT_RAW.read().APB_SARADC1_DONE_INT_RAW == 0) {
        if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
    }
    return @truncate(ADC.SAR1DATA_STATUS.read().APB_SARADC1_DATA);
}

// Read the same block words that espefuse read_regs reports. The shared
// decoder owns field extraction and the full (major * 100 + minor) version.
// C6 TRM v1.2 §§6.4–6.5, registers 6.18–6.31; SVD offsets agree.
fn read_calibration() ?calibration_c6.Calibration {
    var block1: [6]u32 = undefined;
    var block2: [8]u32 = undefined;
    inline for (0..6) |i| {
        block1[i] = efuse.read(.{ .block = 1, .bit_offset = 32 * i, .bit_length = 32 });
    }
    inline for (0..8) |i| {
        block2[i] = efuse.read(.{ .block = 2, .bit_offset = 32 * i, .bit_length = 32 });
    }
    return calibration_c6.decode_blocks(block1, block2);
}
