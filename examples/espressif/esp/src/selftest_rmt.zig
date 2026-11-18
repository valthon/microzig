//! C6 pad: GPIO3, ESP32-C6 datasheet v1.6 Table 2-5, §§2.3.4–2.3.5.
//! General-purpose pad, outside strapping, USB and flash restrictions.
//! C3 one-pad loopback: GPIO4 is otherwise unconnected on the controller board.
//! ESP32-C3 TRM v1.4 §§5.4, 33.3.2–33.3.7; no external wiring.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const rmt = hal.rmt;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_level = .info,
});
comptime {
    _ = microzig.export_startup();
}

const Result = struct {
    failure: ?anyerror = null,
    widths: bool = false,
    duration: bool = false,
    received: usize = 0,
    expected_ticks: u64 = 0,
    measured_ticks: u64 = 0,
};

fn exercise(comptime count: usize) !Result {
    // XTAL 40 MHz / 160 = 250 kHz: four microseconds per tick. Even a
    // one-tick pulse satisfies TRM eq. 33.1 and leaves ample polling time.
    var sent: [count + 1]rmt.Item = undefined;
    var received: [count + 3]rmt.Item = undefined;
    for (sent[0..count], 0..) |*item, i| {
        item.* = .{
            .duration0 = @intCast(1 + (2 * i) % 127),
            .level0 = 1,
            .duration1 = @intCast(1 + (2 * i + 1) % 127),
            .level1 = 0,
        };
    }
    // The guard's rising edge closes the last measured low pulse. Its own
    // final low merges with idle, so do not compare that final RX duration.
    sent[count] = .{ .duration0 = 64, .level0 = 1, .duration1 = 64, .level1 = 0 };
    var result: Result = .{};
    for (sent) |item| result.expected_ticks += (@as(u64, item.duration0) + item.duration1) * 4 * 16;
    var rx = try rmt.Rx(2).start(&received, .{ .divider = 160, .idle_threshold = 200 });
    defer rx.stop();
    const before = hal.systimer.unit(0).read();
    var tx = try rmt.Tx(0).start(&sent, .{ .divider = 160 });
    defer tx.stop();
    var tx_done = false;
    var rx_done = false;
    while (!tx_done or !rx_done) {
        if (!tx_done) {
            tx_done = try tx.poll();
            if (tx_done) result.measured_ticks = hal.systimer.unit(0).read() -% before;
        }
        if (!rx_done) rx_done = try rx.poll();
        if (hal.systimer.unit(0).read() -% before > 16 * 1_000_000) return error.Timeout;
    }
    result.received = rx.count;
    result.widths = rx.count >= count and rx.count <= count + 2;
    if (result.widths) {
        for (sent[0..count], received[0..count]) |expected, actual| {
            if (actual.level0 != expected.level0 or actual.level1 != expected.level1 or
                @abs(@as(i32, actual.duration0) - expected.duration0) > 1 or
                @abs(@as(i32, actual.duration1) - expected.duration1) > 1)
                result.widths = false;
        }
    }
    // Includes software start/setup and end polling latency; 100 us bound
    // is less than 0.4% of the shorter transfer and catches a wrong divider.
    result.duration = @abs(@as(i64, @intCast(result.measured_ticks)) -
        @as(i64, @intCast(result.expected_ticks))) <= 16 * 100;
    return result;
}

fn verdict(pass: bool) []const u8 {
    return if (pass) "PASS" else "FAIL";
}

pub fn main() !void {
    try rmt.init(.{});
    const pad = hal.gpio.num(if (std.mem.eql(u8, microzig.config.chip_name, "ESP32-C6")) 3 else 4);
    pad.apply(.{ .input_enable = true, .output_enable = true });
    pad.connect_peripheral_to_output(.{ .signal = .rmt_sig0 });
    pad.connect_input_to_peripheral(.{ .signal = .rmt_sig0 });
    // Establish a low idle before arming RX.
    var warmup = try rmt.Tx(0).start(&.{.{ .duration0 = 64, .level0 = 0, .duration1 = 64, .level1 = 0 }}, .{ .divider = 160 });
    warmup.stop();
    const short = exercise(64) catch |err| Result{ .failure = err };
    const long = exercise(137) catch |err| Result{ .failure = err };
    const timing = short.duration and long.duration;
    const pass: usize = @as(usize, @intFromBool(short.widths)) + @intFromBool(long.widths) + @intFromBool(timing);
    hal.time.sleep_ms(1500);
    while (true) {
        std.log.info("SELFTEST rmt widths: {s} items=64 received={d} tolerance=1 error={s}", .{ verdict(short.widths), short.received, if (short.failure) |err| @errorName(err) else "none" });
        std.log.info("SELFTEST rmt wrap: {s} items=137 received={d} error={s}", .{ verdict(long.widths), long.received, if (long.failure) |err| @errorName(err) else "none" });
        std.log.info("SELFTEST rmt duration: {s} systimer={d}/{d} expected={d}/{d}", .{ verdict(timing), short.measured_ticks, long.measured_ticks, short.expected_ticks, long.expected_ticks });
        std.log.info("SELFTEST rmt DONE pass={d} fail={d}", .{ pass, 3 - pass });
        hal.time.sleep_ms(1000);
    }
}
