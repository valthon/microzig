//! External RMT test against the Pico 2 W PIO edge timer/replay peer in rmt mode.
//! C6 Super Mini and C3: TX channel 0 on L1/GPIO1, RX channel 2 on L0/GPIO0.
//! Pico bank c6: L1/GP9, L0/GP8; bank c3: L1/GP1, L0/GP0; common ground.
//! GPIO0/1 are priority 2 (free): ESP32-C6 datasheet v1.6 §§2.3.4–2.3.5,
//! ESP32-C3 datasheet v2.5 §2.3.4 (peripheral pin assignment).
//! The peer measures absolute widths, ends a frame after 2 ms low, then replays
//! on L0 after 20 ms. Release TX with a pull-down to keep the low frame
//! delimiter (the peer also pulls its input down); arm RX right after TX.
//! Load pico2_w_ram_esp_peer and send `mode rmt c3` or `mode rmt c6`
//! over Pico USB CDC before starting; request `status` after ESP DONE.
//! PASS requires SELFTEST rmt DONE pass=3 fail=0: echoed levels and
//! widths within one tick, TX duration within 100 us. Require peer
//! tx_widths_64 and tx_widths_137 PASS (absolute widths within 2 us,
//! excluding final low merged with idle), with no peer FAIL verdicts.
//! RMT: C3 TRM v1.4 §§33.3.2–33.3.7; C6 TRM v1.2 §§37.3.2–37.3.7.
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
    // First mismatching item: index, then sent and received high/low ticks.
    first_bad: ?[5]usize = null,
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
    const tx_pad = hal.gpio.num(1);
    tx_pad.apply(.{ .output_enable = true });
    tx_pad.connect_peripheral_to_output(.{ .signal = .rmt_sig0 });
    defer tx_pad.apply(.{ .pull = .down });
    var tx = try rmt.Tx(0).start(&sent, .{ .divider = 160 });
    // start() sets TX_START last; timing from its return excludes item
    // validation and RAM fill, which run slowly from a cold flash cache.
    const before = hal.systimer.unit(0).read();
    defer tx.stop();
    while (!try tx.poll()) {
        if (hal.systimer.unit(0).read() -% before > 16 * 1_000_000) return error.Timeout;
    }
    result.measured_ticks = hal.systimer.unit(0).read() -% before;
    tx_pad.apply(.{ .pull = .down });
    tx.stop();
    // RX counts from the first edge, not from enable (C6 TRM v1.2
    // §37.3.5.1; C3 TRM v1.4 §33.3.5.1). The 200-tick idle threshold
    // therefore terminates the replay, not the wait for its first edge.
    var rx = try rmt.Rx(2).start(&received, .{ .divider = 160, .idle_threshold = 200 });
    defer rx.stop();
    const rx_before = hal.systimer.unit(0).read();
    while (!try rx.poll()) {
        if (hal.systimer.unit(0).read() -% rx_before > 16 * 1_000_000) return error.Timeout;
    }
    result.received = rx.count;
    result.widths = rx.count >= count and rx.count <= count + 2;
    if (result.widths) {
        for (sent[0..count], received[0..count], 0..) |expected, actual, i| {
            if (actual.level0 != expected.level0 or actual.level1 != expected.level1 or
                @abs(@as(i32, actual.duration0) - expected.duration0) > 1 or
                @abs(@as(i32, actual.duration1) - expected.duration1) > 1)
            {
                if (result.first_bad == null) result.first_bad = .{ i, expected.duration0, expected.duration1, actual.duration0, actual.duration1 };
                result.widths = false;
            }
        }
    }
    // The residue is the TX_START-to-timestamp delay and end polling, tens
    // of us; the 100 us bound is under 0.4% of the shorter transfer and
    // catches a wrong divider.
    result.duration = @abs(@as(i64, @intCast(result.measured_ticks)) -
        @as(i64, @intCast(result.expected_ticks))) <= 16 * 100;
    return result;
}

const FirstBad = struct {
    item: ?[5]usize,
    pub fn format(self: FirstBad, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const b = self.item orelse return;
        try writer.print(" first_bad={d} sent={d}/{d} received={d}/{d}", .{ b[0], b[1], b[2], b[3], b[4] });
    }
};

fn verdict(pass: bool) []const u8 {
    return if (pass) "PASS" else "FAIL";
}

pub fn main() !void {
    try rmt.init(.{});
    const rx_pad = hal.gpio.num(0);
    rx_pad.apply(.{ .input_enable = true, .pull = .down });
    // The first RX channel (channel 2) uses matrix input rmt_sig0.
    rx_pad.connect_input_to_peripheral(.{ .signal = .rmt_sig0 });
    const short = exercise(64) catch |err| Result{ .failure = err };
    const long = exercise(137) catch |err| Result{ .failure = err };
    const timing = short.duration and long.duration;
    const pass: usize = @as(usize, @intFromBool(short.widths)) + @intFromBool(long.widths) + @intFromBool(timing);
    hal.time.sleep_ms(1500);
    while (true) {
        std.log.info("SELFTEST rmt widths: {s} items=64 received={d} tolerance=1 error={s}{f}", .{ verdict(short.widths), short.received, if (short.failure) |err| @errorName(err) else "none", FirstBad{ .item = short.first_bad } });
        std.log.info("SELFTEST rmt wrap: {s} items=137 received={d} error={s}{f}", .{ verdict(long.widths), long.received, if (long.failure) |err| @errorName(err) else "none", FirstBad{ .item = long.first_bad } });
        std.log.info("SELFTEST rmt duration: {s} systimer={d}/{d} expected={d}/{d} error={s}", .{ verdict(timing), short.measured_ticks, long.measured_ticks, short.expected_ticks, long.expected_ticks, if (short.failure) |err| @errorName(err) else if (long.failure) |err| @errorName(err) else "none" });
        std.log.info("SELFTEST rmt DONE pass={d} fail={d}", .{ pass, 3 - pass });
        hal.time.sleep_ms(1000);
    }
}
