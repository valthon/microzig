const microzig = @import("microzig");
const rp2xxx = microzig.hal;

const pin_config: rp2xxx.pins.GlobalConfiguration = .{
    .GPIO0 = .{ .name = "uart_tx", .function = .UART0_TX },
    .GPIO1 = .{ .name = "uart_rx", .function = .UART0_RX },
    .GPIO4 = .{ .function = .I2C0_SDA },
    .GPIO5 = .{ .name = "i2c_scl", .function = .I2C0_SCL },
    .GPIO6 = .{ .name = "pio", .function = .PIO0 },
    .GPIO7 = .{ .name = "pwm", .function = .PWM3_B },
    .GPIO16 = .{ .name = "spi_rx", .function = .SPI0_RX },
    .GPIO17 = .{ .name = "spi_cs", .function = .SPI0_CSn },
    .GPIO18 = .{ .name = "spi_sck", .function = .SPI0_SCK },
    .GPIO19 = .{ .name = "spi_tx", .function = .SPI0_TX },
    .GPIO25 = .{ .name = "led", .direction = .out },
    .GPIO26 = .{ .name = "adc", .function = .ADC0 },
};

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();

    const Pins = pin_config.PinsType();
    const pins = pin_config.pins();
    for (.{
        .{ "uart_tx", 0 },
        .{ "uart_rx", 1 },
        .{ "GPIO4", 4 },
        .{ "i2c_scl", 5 },
        .{ "pio", 6 },
        .{ "spi_rx", 16 },
        .{ "spi_cs", 17 },
        .{ "spi_sck", 18 },
        .{ "spi_tx", 19 },
        .{ "led", 25 },
    }) |entry| {
        const name, const number = entry;
        if (!@hasField(Pins, name))
            @compileError("PinsType has no field " ++ name);
        if (@TypeOf(@field(pins, name)) != rp2xxx.gpio.Pin)
            @compileError("expected gpio.Pin for " ++ name);
        if (@field(pins, name) != rp2xxx.gpio.num(number))
            @compileError("wrong GPIO for " ++ name);
    }
    if (@TypeOf(pins.pwm) != rp2xxx.pwm.Pwm or
        pins.pwm.slice_number != 3 or pins.pwm.channel != .b)
        @compileError("incorrect PWM handle");
    if (@TypeOf(pins.adc) != rp2xxx.adc.Input or pins.adc != .ain0)
        @compileError("incorrect ADC handle");
}

pub fn main() !void {
    const pins = pin_config.apply();
    while (true) {
        pins.led.toggle();
        rp2xxx.time.sleep_ms(250);
    }
}
