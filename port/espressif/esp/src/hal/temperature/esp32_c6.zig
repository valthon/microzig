//! ESP32-C6 die temperature, C6 TRM v1.2 §39.3.3. Fixed -10..80 °C
//! range (offset zero); measures die temperature, without eFuse correction.
//! Call init after HAL initialization, from task context. init can time out
//! on the analog-I2C bus; read_celsius requires successful initialization.
const std = @import("std");
const microzig = @import("microzig");
const analog = @import("../analog/esp32_c6.zig");
const PCR = microzig.chip.peripherals.PCR;
const time = @import("../time.zig");
const ADC = microzig.chip.peripherals.APB_SARADC;

pub fn init() analog.Error!void {
    {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        // C6 TRM v1.2 §8.5 register 8.33 and §39.3.3: XTAL selection
        // moved to PCR; do not reset the ADC/temperature shared registers.
        PCR.SARADC_CONF.modify(.{ .SARADC_REG_CLK_EN = 1, .SARADC_REG_RST_EN = 0 });
        PCR.TSENS_CLK_CONF.modify(.{ .TSENS_CLK_EN = 1, .TSENS_RST_EN = 0, .TSENS_CLK_SEL = 1 });
        analog.enable();
        ADC.APB_TSENS_CTRL.modify(.{ .TSENS_PU = 0 });
        // ESP-IDF v5.4 temperature_sensor_ll_set_range and
        // temperature_sensor_periph.c temperature_sensor_attributes:
        // DAC code 15 selects offset 0 (-10..80 °C). Analog field from
        // soc/esp32c6/include/soc/regi2c_saradc.h (Apache-2.0).
        try analog.write_mask(6, 3, 0, 15);
        ADC.TSENS_CTRL2.modify(.{ .TSENS_XPD_WAIT = 2 });
        ADC.APB_TSENS_CTRL.modify(.{ .TSENS_CLK_DIV = 6, .TSENS_IN_INV = 0, .TSENS_PU = 1 });
    }
    // C6 TRM v1.2 §39.3.3 asks for settling after XPD_WAIT. Allow 10 ms before
    // reading; there is no ready bit. XTAL avoids RC_FAST frequency drift.
    time.sleep_ms(10);
}

/// Continuous sensor output; call init first. C6 TRM v1.2 §39.3.3 conversion with
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
