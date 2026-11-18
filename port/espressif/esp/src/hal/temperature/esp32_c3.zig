//! ESP32-C3 die temperature, ESP32-C3 TRM v1.4 §34.3.3.
//! Fixed -10..80 °C range (offset zero). This measures die, not ambient,
//! temperature. Call init after HAL initialization; do not use from an ISR.

comptime {
    @import("../compatibility.zig").require_esp32_c3("hal.temperature");
}

const std = @import("std");
const microzig = @import("microzig");
const rom = @import("../rom.zig");
const system = @import("../system.zig");
const time = @import("../time.zig");
const ADC = microzig.chip.peripherals.APB_SARADC;

pub fn init() void {
    {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        // ADC and temperature share the register block. Release resets without
        // resetting it, so an initialized ADC1 remains usable.
        system.enable_clocks_and_release_reset(.{ .apb_saradc = true, .tsens = true });
        // ESP-IDF v5.3.1 regi2c_ctrl_ll_i2c_saradc_enable.
        microzig.chip.peripherals.I2C_ANA_MST.ANA_CONFIG.modify(.{ .SAR_FORCE_PD = 0 });
        microzig.chip.peripherals.I2C_ANA_MST.ANA_CONFIG2.modify(.{ .SAR_FORCE_PU = 1 });
        microzig.chip.peripherals.RTC_CNTL.ANA_CONF.modify(.{ .SAR_I2C_PU = 1 });
        ADC.APB_TSENS_CTRL.modify(.{ .TSENS_PU = 0 });
        // ESP-IDF v5.3.1 temperature_sensor_ll_set_range and
        // temperature_sensor_periph.c temperature_sensor_attributes:
        // DAC code 15 selects offset 0 (-10..80 °C). Analog field from
        // soc/esp32c3/include/soc/regi2c_saradc.h (Apache-2.0).
        rom.functions.esp_rom_regi2c_write_mask(0x69, 0, 6, 3, 0, 15);
        ADC.TSENS_CTRL2.modify(.{ .TSENS_CLK_SEL = 1, .TSENS_XPD_WAIT = 2 });
        ADC.APB_TSENS_CTRL.modify(.{ .TSENS_CLK_DIV = 6, .TSENS_IN_INV = 0, .TSENS_PU = 1 });
    }
    // TRM §34.3.3 asks for settling after XPD_WAIT. Allow 10 ms before
    // reading; there is no ready bit. XTAL avoids RC_FAST frequency drift.
    time.sleep_ms(10);
}

/// Continuous sensor output; call init first. TRM §34.3.3 conversion with
/// offset 0. No eFuse temperature correction is applied.
pub fn read_celsius() f32 {
    return raw_to_celsius(ADC.APB_TSENS_CTRL.read().TSENS_OUT);
}

fn raw_to_celsius(raw: u8) f32 {
    return 0.4386 * @as(f32, @floatFromInt(raw)) - 20.52;
}

test "temperature conversion uses TRM slope and zero range offset" {
    try std.testing.expectApproxEqAbs(@as(f32, -20.52), raw_to_celsius(0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 23.34), raw_to_celsius(100), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 91.323), raw_to_celsius(255), 0.001);
}
