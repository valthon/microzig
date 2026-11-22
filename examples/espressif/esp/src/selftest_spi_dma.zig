//! SPI DMA master against a Pico 2 W PIO mode-0 slave.
//! Wire ESP C6 GPIO0/1/2/3 to Pico GP8/9/10/11 respectively;
//! for ESP C3, GPIO0/1/3/10 to Pico GP0/1/2/3. Connect common GND.
//! Load pico2_w_ram_esp_peer, send `mode spi c3` or `mode spi c6` over
//! Pico USB CDC, then start this test and request `status` after DONE.
//! PASS requires SELFTEST spi_dma DONE pass=8 fail=0 (echo equality,
//! intact guards and CPU transfer after DMA), PEER spi clk: PASS
//! (1 MHz within 1%), and no peer FAIL verdicts.
//! L2=SCLK, L1=MOSI, L0=MISO, L3=GPIO CS; mode 0, MSB first, 1 MHz.
//! spi.apply clears USER.CK_OUT_EDGE and MISC.CK_IDLE_EDGE: mode 0 per
//! C3 TRM v1.4 §27.7.2 Table 27.7-1 / C6 TRM v1.2 §28.7.2 Table 28.7-1.
//! Each second frame receives the first frame's bytes. CS setup >=2 us,
//! CS high with SCLK idle for 110 ms between frames (peer minimum 100 ms,
//! with margin for capture completion). Select peer `mode spi c3|c6` first.
//! SPI's synchronous reply uses only the input MISO pad;
//! unlike the asynchronous replay tests, MOSI/SCLK/CS stay outputs until done.
//! cpu_after_dma uses the bounded FIFO transceive variant instead
//! of transceive_blocking, whose legacy hardware polls have no deadline.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const spi = hal.spi.instance.SPI2;
const gdma = hal.spi.gdma;
const is_c6 = std.mem.eql(u8, microzig.config.chip_name, "ESP32-C6");
const sclk = hal.gpio.num(if (is_c6) 2 else 3);
const mosi = hal.gpio.num(1);
const miso = hal.gpio.num(0);
const cs = hal.gpio.num(if (is_c6) 3 else 10);
const baud = 1_000_000;
const lengths = [_]usize{ 1, 64, 4092, 4096, 10000 };
const expected_us = 80_000;
const guard = 0xa5;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_level = .info,
});
comptime {
    _ = microzig.export_startup();
}

var tx_a: [10000]u8 align(4) = undefined;
var tx_b: [10000]u8 align(4) = undefined;
// Four leading bytes keep the DMA payload aligned; trailing guards also
// cover the full-size transfer, not just the shorter descriptor cases.
var guarded_rx: [10008]u8 align(4) = undefined;
var out: [3]gdma.Descriptor = undefined;
var input: [3]gdma.Descriptor = undefined;

const TestError = hal.spi.SPI.DmaError || error{ EchoMismatch, GuardCorruption, TimingOutOfRange, DependencyFailed };
const Result = struct {
    elapsed_us: u64 = 0,
    failure: ?TestError = null,

    fn ok(self: Result) bool {
        return self.failure == null;
    }
};

fn pattern(buffer: []u8, seed: u32) void {
    // Xorshift32 avoids a 256-byte period across descriptor boundaries.
    var state = seed;
    for (buffer) |*byte| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = @truncate(state);
    }
}

fn configure() void {
    spi.apply(.{ .clock_config = hal.clocks.Config.default, .baud_rate = baud });
    cs.put(1);
    cs.apply(.{ .output_enable = true });
    sclk.apply(.{ .output_enable = true });
    mosi.apply(.{ .output_enable = true });
    miso.apply(.{ .input_enable = true, .pull = .down });
    spi.connect_pins(.{
        .clk = sclk,
        .data = .{ .single_two_wires = .{ .mosi = mosi, .miso = miso } },
    });
    hal.time.sleep_us(10);
}

fn end_frame() void {
    cs.put(1);
    // The peer decodes the capture and rearms while CS is high/SCLK idle.
    hal.time.sleep_ms(110);
}

fn dma_frame(tx: ?[]const u8, rx: ?[]u8) TestError!u64 {
    cs.put(0);
    defer end_frame();
    hal.time.sleep_us(2);
    const start = hal.systimer.unit(0).read();
    try spi.transfer_dma_blocking(.{
        .tx = tx,
        .rx = rx,
        .tx_descriptors = &out,
        .rx_descriptors = &input,
    }, .from_ms(500));
    return (hal.systimer.unit(0).read() - start) / hal.systimer.ticks_per_us();
}

fn check_guards(len: usize) TestError!void {
    if (!std.mem.allEqual(u8, guarded_rx[0..4], guard) or
        !std.mem.allEqual(u8, guarded_rx[4 + len ..], guard)) return error.GuardCorruption;
}

fn check_echo(expected: []const u8) TestError!void {
    try check_guards(expected.len);
    const received = guarded_rx[4..][0..expected.len];
    if (!std.mem.eql(u8, expected, received)) return error.EchoMismatch;
}

fn round_trip(len: usize) TestError!Result {
    configure();
    pattern(tx_a[0..len], 0x62a9d37b ^ @as(u32, @intCast(len)));
    pattern(tx_b[0..len], 0xb17f034d ^ @as(u32, @intCast(len)));
    @memset(&guarded_rx, guard);
    _ = try dma_frame(tx_a[0..len], guarded_rx[4..][0..len]);
    try check_guards(len);
    @memset(&guarded_rx, guard);
    const elapsed = try dma_frame(tx_b[0..len], guarded_rx[4..][0..len]);
    try check_echo(tx_a[0..len]);
    return .{ .elapsed_us = elapsed };
}

fn one_direction() TestError!Result {
    configure();
    pattern(&tx_a, 0x397ab501);
    _ = try dma_frame(&tx_a, null);
    @memset(&guarded_rx, guard);
    const elapsed = try dma_frame(null, guarded_rx[4..][0..tx_a.len]);
    try check_echo(&tx_a);
    return .{ .elapsed_us = elapsed };
}

fn cpu_frame(tx: []const u8) TestError!void {
    cs.put(0);
    defer end_frame();
    hal.time.sleep_us(2);
    try spi.transceive_blocking_timeout(tx, guarded_rx[4..][0..tx.len], .from_ms(500));
}

fn cpu_after_dma() TestError!Result {
    // No apply() or pin reroute after directions' successful DMA call:
    // the FIFO path must work with the state that DMA left behind.
    pattern(tx_a[0..64], 0xf5912bc3);
    pattern(tx_b[0..64], 0x834d06a7);
    @memset(&guarded_rx, guard);
    try cpu_frame(tx_a[0..64]);
    try check_guards(64);
    @memset(&guarded_rx, guard);
    try cpu_frame(tx_b[0..64]);
    try check_echo(tx_a[0..64]);
    return .{};
}

fn verdict(result: Result) []const u8 {
    return if (result.ok()) "PASS" else "FAIL";
}

fn error_name(result: Result) []const u8 {
    return if (result.failure) |err| @errorName(err) else "none";
}

pub fn main() void {
    gdma.init();
    var results: [lengths.len]Result = undefined;
    var pass: u32 = 0;
    for (lengths, &results) |len, *result| {
        result.* = round_trip(len) catch |err| .{ .failure = err };
        pass += @intFromBool(result.ok());
    }
    const directions = one_direction() catch |err| Result{ .failure = err };
    const cpu = if (directions.ok())
        cpu_after_dma() catch |err| Result{ .failure = err }
    else
        Result{ .failure = error.DependencyFailed };
    var timing = results[4];
    if (timing.ok() and (timing.elapsed_us < expected_us * 9 / 10 or
        timing.elapsed_us > expected_us * 11 / 10)) timing.failure = error.TimingOutOfRange;
    pass += @intFromBool(directions.ok());
    pass += @intFromBool(cpu.ok());
    pass += @intFromBool(timing.ok());
    cs.put(1);
    for ([_]hal.gpio.Pin{ sclk, mosi, miso, cs }) |pin| pin.apply(.{});
    hal.time.sleep_ms(1500);
    while (true) {
        for (lengths, results) |len, result| {
            std.log.info("SELFTEST spi_dma roundtrip_{d}: {s} descriptors={d} elapsed_us={d} error={s}", .{
                len, verdict(result), gdma.descriptor_count(len), result.elapsed_us, error_name(result),
            });
        }
        std.log.info("SELFTEST spi_dma directions: {s} bytes=10000 error={s}", .{ verdict(directions), error_name(directions) });
        std.log.info("SELFTEST spi_dma cpu_after_dma: {s} bytes=64 error={s}", .{ verdict(cpu), error_name(cpu) });
        std.log.info("SELFTEST spi_dma throughput: {s} elapsed_us={d} expected_us={d} tolerance=10% error={s}", .{
            verdict(timing), timing.elapsed_us, expected_us, error_name(timing),
        });
        std.log.info("SELFTEST spi_dma DONE pass={d} fail={d}", .{ pass, 8 - pass });
        hal.time.sleep_ms(1000);
    }
}
