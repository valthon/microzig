const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const spi = hal.spi.instance.SPI2;
const gdma = hal.spi.gdma;
const pad = hal.gpio.num(4);
const baud = 1_000_000;
const lengths = [_]usize{ 1, 64, 4092, 4096, 10000 };

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_level = .info,
});
comptime {
    _ = microzig.export_startup();
}

var tx: [10000]u8 align(4) = undefined;
var rx: [10000]u8 align(4) = undefined;
var out: [3]gdma.Descriptor = undefined;
var input: [3]gdma.Descriptor = undefined;

const Result = struct {
    ok: bool = false,
    elapsed_us: u64 = 0,
    failure: ?hal.spi.SPI.DmaError = null,
};

fn configure() void {
    spi.apply(.{ .clock_config = hal.clocks.Config.default, .baud_rate = baud });
    pad.apply(.{ .input_enable = true, .output_enable = true });
    // C3 TRM v1.4 §5.4–5.5, §27.5.2; C6 TRM v1.2 §7.4–7.5,
    // §28.5.2: route FSPID output and FSPIQ input to the same pad.
    spi.connect_pins(.{ .data = .{ .single_two_wires = .{ .mosi = pad, .miso = pad } } });
}

fn round_trip(len: usize) !Result {
    configure();
    @memset(&rx, 0xa5);
    const start = hal.systimer.unit(0).read();
    try spi.transfer_dma_blocking(.{
        .tx = tx[0..len],
        .rx = rx[0..len],
        .tx_descriptors = &out,
        .rx_descriptors = &input,
    }, .from_ms(500));
    const elapsed = (hal.systimer.unit(0).read() - start) / hal.systimer.ticks_per_us();
    return .{
        .ok = std.mem.eql(u8, tx[0..len], rx[0..len]) and std.mem.allEqual(u8, rx[len..], 0xa5),
        .elapsed_us = elapsed,
    };
}

fn one_direction() !bool {
    configure();
    try spi.transfer_dma_blocking(.{ .tx = &tx, .tx_descriptors = &out }, .from_ms(500));
    // Use an independent, constant input for a receive-only transfer.
    // Reconnect MOSI to GPIO output high, leaving FSPIQ on the same pad.
    pad.set_output_enabled(true);
    pad.put(1);
    pad.connect_peripheral_to_output(.{ .signal = .gpio });
    @memset(&rx, 0);
    try spi.transfer_dma_blocking(.{ .rx = &rx, .rx_descriptors = &input }, .from_ms(500));
    return std.mem.allEqual(u8, &rx, 0xff);
}

fn cpu_after_dma() bool {
    // Restore the matrix only; do not re-apply SPI configuration. This checks
    // that a successful DMA call really restores the existing FIFO API.
    spi.connect_pins(.{ .data = .{ .single_two_wires = .{ .mosi = pad, .miso = pad } } });
    var result: [64]u8 = undefined;
    spi.transceive_blocking(tx[0..64], &result);
    return std.mem.eql(u8, tx[0..64], &result);
}

fn verdict(ok: bool) []const u8 {
    return if (ok) "PASS" else "FAIL";
}

pub fn main() void {
    // Xorshift32 has a 2^32-1 state period; unlike an affine byte pattern,
    // this stream does not repeat every 256 bytes across descriptor boundaries.
    var state: u32 = 0x62a9d37b;
    for (&tx) |*byte| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = @truncate(state);
    }
    gdma.init();
    var results: [lengths.len]Result = undefined;
    var pass: u32 = 0;
    for (lengths, &results) |len, *result| {
        result.* = round_trip(len) catch |err| .{ .failure = err };
        pass += @intFromBool(result.ok);
    }
    const directions = one_direction() catch |err| blk: {
        std.log.err("SPI DMA directions: {s}", .{@errorName(err)});
        break :blk false;
    };
    const cpu = if (directions) cpu_after_dma() else false;
    // At exactly 1 MHz the long transaction takes 80 ms. Allow 10% for
    // descriptor setup, polling and systimer quantization; this excludes a
    // factor-of-two clock error.
    const elapsed = results[4].elapsed_us;
    const expected = 10000 * @as(u64, 8) * 1_000_000 / baud;
    const timing = results[4].ok and elapsed >= expected * 9 / 10 and elapsed <= expected * 11 / 10;
    pass += @intFromBool(directions);
    pass += @intFromBool(cpu);
    pass += @intFromBool(timing);
    hal.time.sleep_ms(1500);
    while (true) {
        for (lengths, results) |len, result| {
            std.log.info("SELFTEST spi_dma roundtrip_{d}: {s} descriptors={d} elapsed_us={d} error={s}", .{
                len,                                                   verdict(result.ok), gdma.descriptor_count(len), result.elapsed_us,
                if (result.failure) |err| @errorName(err) else "none",
            });
        }
        std.log.info("SELFTEST spi_dma directions: {s} bytes=10000", .{verdict(directions)});
        std.log.info("SELFTEST spi_dma cpu_after_dma: {s} bytes=64", .{verdict(cpu)});
        std.log.info("SELFTEST spi_dma throughput: {s} elapsed_us={d} expected_us={d} tolerance=10%", .{ verdict(timing), elapsed, expected });
        std.log.info("SELFTEST spi_dma DONE pass={d} fail={d}", .{ pass, 8 - pass });
        hal.time.sleep_ms(1000);
    }
}
