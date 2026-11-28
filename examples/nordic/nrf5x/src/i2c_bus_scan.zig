const std = @import("std");
const microzig = @import("microzig");
const board = microzig.board;
const nrf = microzig.hal;

const gpio = nrf.gpio;
const i2c = nrf.i2c;
const i2cdma = nrf.i2cdma;

const uart = nrf.uart.num(0);
const i2c0 = i2c.num(0);
const i2c0dma = i2cdma.num(0);
// Keep the destination in RAM if a stuck STOP outlives main.
var dma_rx: [1]u8 = undefined;

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .log_level = .debug,
    .logFn = nrf.uart.log,
});

comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    board.init();

    uart.apply(.{
        .tx_pin = board.uart_tx,
        .rx_pin = board.uart_rx,
    });

    nrf.uart.init_logger(uart);

    // ------------------------ BUS SCAN ------------------------
    std.log.info("I2C bus scan", .{});

    try i2c0.apply(.{
        .scl_pin = gpio.num(0, 9),
        .sda_pin = gpio.num(0, 10),
    });
    for (0..std.math.maxInt(u7)) |addr| {
        const a: i2c.Address = @fromBackingInt(@intCast(addr));

        var rx_data: [1]u8 = undefined;
        _ = i2c0.read_blocking(a, &rx_data, null) catch |e| {
            if (e != i2c.Error.DeviceNotPresent and
                e != i2c.Error.IllegalAddress)
                std.log.info("Error {any}", .{e});
            continue;
        };

        std.log.info("I2C device found at address {X}.", .{addr});
    }
    i2c0.reset();

    // ------------------------ BUS SCAN (DMA) ------------------------
    std.log.info("I2C bus scan (DMA)", .{});

    try i2c0dma.apply(.{
        .scl_pin = gpio.num(0, 9),
        .sda_pin = gpio.num(0, 10),
    });
    errdefer i2c0dma.reset();
    for (0..std.math.maxInt(u7)) |addr| {
        const a: i2cdma.Address = @fromBackingInt(@intCast(addr));

        _ = i2c0dma.read_blocking(a, &dma_rx, null) catch |e| {
            if (e == error.BusStuck) return e;
            if (e != i2c.Error.DeviceNotPresent and
                e != i2c.Error.IllegalAddress)
                std.log.info("Error {any}", .{e});
            continue;
        };

        std.log.info("I2C device found at address {X}.", .{addr});
    }
    try i2c0dma.deinit();

    std.log.info("Done!", .{});
}
