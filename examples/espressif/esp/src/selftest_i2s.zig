const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const i2s = hal.i2s;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .logFn = hal.usb_serial_jtag.logger.log, .log_level = .info });
comptime {
    _ = microzig.export_startup();
}
var tx: [2048]u8 align(4) = undefined;
var rx: [2048]u8 align(4) = undefined;
var output: [1]hal.gdma.Descriptor = undefined;
var input: [1]hal.gdma.Descriptor = undefined;

fn config(bits: i2s.SampleBits) i2s.Config {
    return .{ .bits = bits, .bck = hal.gpio.num(5), .ws = hal.gpio.num(6), .tx_data = hal.gpio.num(4), .rx_data = hal.gpio.num(4) };
}

fn loopback(cfg: i2s.Config, tx_length: usize, rx_capacity: usize) i2s.Error!usize {
    @memset(&rx, 0xa5);
    return i2s.Port(2).transfer(cfg, .{ .tx = tx[0..tx_length], .rx = rx[0..rx_capacity], .tx_descriptors = &output, .rx_descriptors = &input }, 100000);
}

fn guards_untouched(start: usize) bool {
    for (rx[start..]) |byte| {
        if (byte != 0xa5) return false;
    }
    return true;
}

pub fn main() void {
    var state: u32 = 0x30d5317;
    for (&tx) |*byte| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = @truncate(state);
    }
    hal.gdma.init();
    var pass: usize = 0;
    var fail: usize = 0;
    // Keep the first EOF well within the descriptor under either interpretation:
    // IDF: 64 bytes. TRM: (RX_BITS_MOD+1)*(EOF_NUM+1)/8 = 32*65/8 = 260.
    // RX_STOP_MODE=1 stops reception at that first EOF even while TX continues.
    var probe = config(.bits32);
    probe.rx_eof_num = 64;
    const eof = loopback(probe, 1024, 512);
    const eof_ok = if (eof) |actual| actual == 64 and guards_untouched(actual) else |_| false;
    if (eof_ok) pass += 1 else fail += 1;
    const widths = [_]i2s.SampleBits{ .bits16, .bits32 };
    const lengths = [_]usize{ 64, 512, 2048 };
    var results: [widths.len][lengths.len]Outcome = undefined;
    for (widths, &results) |bits, *row| {
        for (lengths, row) |length, *result| {
            const outcome = loopback(config(bits), length, length);
            const ok = if (outcome) |actual| actual == length and std.mem.eql(u8, tx[0..length], rx[0..length]) and guards_untouched(length) else |_| false;
            result.* = .{ .ok = ok, .outcome = outcome };
            if (ok) pass += 1 else fail += 1;
        }
    }
    hal.gpio.num(4).apply(.{});
    hal.gpio.num(5).apply(.{});
    hal.gpio.num(6).apply(.{});
    // Lines logged in the first moments after the RAM load are lost before the
    // host reopens the port; report once it is back, and repeat.
    hal.time.sleep_ms(1500);
    while (true) {
        std.log.info("SELFTEST i2s eof_num info raw=64 bits=32 idf_bytes=64 trm_bytes=260 rx_capacity=512", .{});
        if (eof) |actual| {
            std.log.info("SELFTEST i2s eof_num: {s} expected=64 actual={d}", .{ if (eof_ok) "PASS" else "FAIL", actual });
        } else |err| std.log.err("SELFTEST i2s eof_num: FAIL expected=64 actual=unavailable error={s}", .{@errorName(err)});
        for (widths, results) |bits, row| {
            for (lengths, row) |length, result| {
                if (result.outcome) |actual| {
                    std.log.info("SELFTEST i2s {s}_{d}: {s} actual={d}", .{ @tagName(bits), length, if (result.ok) "PASS" else "FAIL", actual });
                } else |err| std.log.err("SELFTEST i2s {s}_{d}: FAIL {s}", .{ @tagName(bits), length, @errorName(err) });
            }
        }
        std.log.info("SELFTEST i2s DONE pass={d} fail={d}", .{ pass, fail });
        hal.time.sleep_ms(1000);
    }
}

const Outcome = struct { ok: bool, outcome: i2s.Error!usize };
