const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const uart1 = hal.uart.instance.num(1);
const uart0 = hal.uart.instance.num(0);
// C6 datasheet v1.6 §2.2 Table 2-2 and §3: GPIO6 (MTCK) is a GPIO,
// not a strap, flash pad, or USB D-/D+ (GPIO12/13). It is free on the Super Mini.
const pad = hal.gpio.num(if (std.mem.eql(u8, microzig.config.chip_name, "ESP32-C6")) 6 else 4);
const mtime = microzig.drivers.time;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_level = .info,
});
comptime {
    _ = microzig.export_startup();
}

const Result = struct {
    data: bool = false,
    timing: bool = false,
    elapsed_us: u64 = 0,
    expected_us: u64 = 0,
};

fn round_trip(baud: u32) !Result {
    try uart1.init(.{ .baud_rate = baud });
    uart1.connect_pins(.{ .tx = pad, .rx = pad });
    var tx: [300]u8 = undefined;
    var rx: [300]u8 = undefined;
    for (&tx, 0..) |*byte, i| byte.* = @truncate(i * 73 + 19);
    var sent: usize = 0;
    var received: usize = 0;
    const start = hal.systimer.unit(0).read();
    const deadline = mtime.Deadline.init_relative(hal.time.get_time_since_boot(), .from_ms(200));
    // Drain RX while refilling TX: writing all 300 bytes first would overrun
    // the 128-byte RX FIFO (TRM v1.4 §26.4.2).
    while (received < rx.len) {
        if (deadline.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
        received += try uart1.try_read(rx[received..]);
        sent += uart1.try_write(tx[sent..]);
    }
    try uart1.flush_blocking(.from_ms(100));
    const elapsed = (hal.systimer.unit(0).read() - start) / hal.systimer.ticks_per_us();
    const expected = 300 * @as(u64, 10) * 1_000_000 / baud;
    return .{
        .data = sent == tx.len and std.mem.eql(u8, &tx, &rx),
        // Allow 10% for fractional rounding, FIFO refill and software overhead.
        // Too-fast transfers fail as well, catching the wrong clock/divider.
        .timing = elapsed >= expected * 9 / 10 and elapsed <= expected * 11 / 10,
        .elapsed_us = elapsed,
        .expected_us = expected,
    };
}

fn parity_mismatch() !bool {
    // PARITY controls both TX and RX (§26.4.4), so use UART0 as the even
    // transmitter and UART1 as the odd receiver, still through the one pad.
    try uart1.init(.{ .parity = .odd });
    uart1.connect_pins(.{ .rx = pad });
    try uart0.init(.{ .parity = .even });
    uart0.connect_pins(.{ .tx = pad });
    uart1.clear_rx_errors();
    var stream: hal.uart.Stream = .{ .uart = uart0, .timeout = .from_ms(100) };
    const sent = try stream.stream_device().write(&.{0x55});
    try uart0.flush_blocking(.from_ms(100));
    var byte: [1]u8 = undefined;
    uart1.read_blocking(&byte, .from_ms(100)) catch |err| return sent == 1 and err == error.ParityError;
    return false;
}

fn verdict(ok: bool) []const u8 {
    return if (ok) "PASS" else "FAIL";
}

pub fn main() void {
    const slow = round_trip(115200) catch |err| blk: {
        std.log.err("UART 115200: {s}", .{@errorName(err)});
        break :blk Result{};
    };
    const fast = round_trip(1_000_000) catch |err| blk: {
        std.log.err("UART 1000000: {s}", .{@errorName(err)});
        break :blk Result{};
    };
    const parity = parity_mismatch() catch |err| blk: {
        std.log.err("UART parity: {s}", .{@errorName(err)});
        break :blk false;
    };
    const pass: u32 = @as(u32, @intFromBool(slow.data)) + @intFromBool(slow.timing) +
        @intFromBool(fast.data) + @intFromBool(fast.timing) + @intFromBool(parity);
    hal.time.sleep_ms(1500);
    while (true) {
        std.log.info("SELFTEST uart roundtrip_115200: {s} bytes=300", .{verdict(slow.data)});
        std.log.info("SELFTEST uart timing_115200: {s} us={} expected={}", .{ verdict(slow.timing), slow.elapsed_us, slow.expected_us });
        std.log.info("SELFTEST uart roundtrip_1000000: {s} bytes=300", .{verdict(fast.data)});
        std.log.info("SELFTEST uart timing_1000000: {s} us={} expected={}", .{ verdict(fast.timing), fast.elapsed_us, fast.expected_us });
        std.log.info("SELFTEST uart parity: {s} TX=even RX=odd", .{verdict(parity)});
        std.log.info("SELFTEST uart DONE pass={} fail={}", .{ pass, 5 - pass });
        hal.time.sleep_ms(1000);
    }
}
