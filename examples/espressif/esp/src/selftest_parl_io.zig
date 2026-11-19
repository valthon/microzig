const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const parl = hal.parl_io;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .logFn = hal.usb_serial_jtag.logger.log, .log_level = .info });
comptime {
    _ = microzig.export_startup();
}
var tx: [4096]u8 align(4) = undefined;
var rx: [4096]u8 align(4) = undefined;
var output: [2]hal.gdma.Descriptor = undefined;
var input: [2]hal.gdma.Descriptor = undefined;
pub fn main() void {
    const pads = [_]hal.gpio.Pin{ hal.gpio.num(0), hal.gpio.num(1), hal.gpio.num(2), hal.gpio.num(3), hal.gpio.num(4), hal.gpio.num(5), hal.gpio.num(6), hal.gpio.num(7) };
    var state: u32 = 0x38d5317;
    for (&tx) |*byte| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = @truncate(state);
    }
    hal.gdma.init();
    var pass: usize = 0;
    var fail: usize = 0;
    const widths = [_]parl.Width{ .bits1, .bits2, .bits4, .bits8 };
    const lengths = [_]usize{ 64, 4096 };
    // Per case: null passed, otherwise the transfer error or "Mismatch".
    var results: [widths.len][2][lengths.len]?[]const u8 = undefined;
    for (widths, 0..) |width, w| {
        const count: usize = @as(usize, 16) >> @backingInt(width);
        for ([_]bool{ true, false }, 0..) |with_valid, m| {
            for (lengths, 0..) |length, l| {
                @memset(&rx, 0xa5);
                var ok = true;
                parl.Port(1).transfer(.{ .width = width, .tx_data = pads[0..count], .rx_data = pads[0..count], .tx_clock = hal.gpio.num(10), .rx_clock = hal.gpio.num(10), .tx_valid = if (with_valid) hal.gpio.num(11) else null, .rx_valid = if (with_valid) hal.gpio.num(11) else null }, .{ .tx = tx[0..length], .rx = rx[0..length], .tx_descriptors = &output, .rx_descriptors = &input }, 200000) catch |err| {
                    results[w][m][l] = @errorName(err);
                    ok = false;
                };
                if (ok) {
                    // Compare every byte in order: a leading idle prefix or a
                    // shifted/missing tail must fail even when DMA reports length.
                    ok = std.mem.eql(u8, tx[0..length], rx[0..length]);
                    for (rx[length..]) |byte| {
                        if (byte != 0xa5) ok = false;
                    }
                    results[w][m][l] = if (ok) null else "Mismatch";
                }
                if (ok) pass += 1 else fail += 1;
            }
        }
    }
    for (pads) |pin| pin.apply(.{});
    hal.gpio.num(10).apply(.{});
    hal.gpio.num(11).apply(.{});
    // Lines logged in the first moments after the RAM load are lost before the
    // host reopens the port; report once it is back, and repeat.
    hal.time.sleep_ms(1500);
    while (true) {
        for (widths, results) |width, modes| {
            for ([_][]const u8{ "valid", "software" }, modes) |mode, row| {
                for (lengths, row) |length, result| {
                    if (result) |reason| {
                        std.log.err("SELFTEST parl_io {s}_{s}_{d}: FAIL {s}", .{ @tagName(width), mode, length, reason });
                    } else std.log.info("SELFTEST parl_io {s}_{s}_{d}: PASS", .{ @tagName(width), mode, length });
                }
            }
        }
        std.log.info("SELFTEST parl_io DONE pass={d} fail={d}", .{ pass, fail });
        hal.time.sleep_ms(1000);
    }
}
