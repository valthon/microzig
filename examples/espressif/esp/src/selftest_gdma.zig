const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const gdma = hal.gdma;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .logFn = hal.usb_serial_jtag.logger.log, .log_level = .info });
comptime {
    _ = microzig.export_startup();
}
var source: [10000]u8 align(4) = undefined;
var destination: [10000]u8 align(4) = undefined;
var output: [3]gdma.Descriptor = undefined;
var input: [3]gdma.Descriptor = undefined;
// Only the dummy clients selected by Channel.copy may have changed mode.
fn permission_modes() [16]u2 {
    var modes: [16]u2 = undefined;
    inline for (0..16) |selector| {
        const master = std.fmt.comptimePrint("M{d}", .{16 + selector});
        modes[selector] = @field(@field(microzig.chip.peripherals.TEE, master ++ "_MODE_CTRL").read(), master ++ "_MODE");
    }
    return modes;
}

pub fn main() void {
    var state: u32 = 0x12345678;
    for (&source) |*byte| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = @truncate(state);
    }
    gdma.init();
    const before = if (hal.compatibility.chip == .esp32_c6) permission_modes() else undefined;
    var pass: usize = 0;
    var fail: usize = 0;
    const lengths = [_]usize{ 1, 64, 4092, 4096, 10000 };
    // Per case: null passed, otherwise the copy error or "Mismatch".
    var results: [3][lengths.len]?[]const u8 = undefined;
    var permissions: ?bool = null;
    inline for (0..3) |channel| {
        for (lengths, 0..) |length, case| {
            @memset(&destination, 0xa5);
            var ok = true;
            gdma.Channel(channel).copy(destination[0..length], source[0..length], &output, &input, 100000) catch |err| {
                results[channel][case] = @errorName(err);
                ok = false;
            };
            if (ok) {
                ok = std.mem.eql(u8, source[0..length], destination[0..length]);
                for (destination[length..]) |byte| {
                    if (byte != 0xa5) ok = false;
                }
                results[channel][case] = if (ok) null else "Mismatch";
            }
            if (ok) pass += 1 else fail += 1;
        }
    }
    if (hal.compatibility.chip == .esp32_c6) {
        const after = permission_modes();
        var ok = true;
        for (before, after, 0..) |old, new, selector| {
            const expected: u2 = if (selector == 1 or selector == 4 or selector == 5) 0 else old;
            if (new != expected) ok = false;
        }
        permissions = ok;
        if (ok) pass += 1 else fail += 1;
    }
    // Lines logged in the first moments after the RAM load are lost before the
    // host reopens the port; report once it is back, and repeat.
    hal.time.sleep_ms(1500);
    while (true) {
        for (results, 0..) |row, channel| {
            for (row, lengths) |result, length| {
                if (result) |reason| {
                    std.log.err("SELFTEST gdma ch{d}_{d}: FAIL {s}", .{ channel, length, reason });
                } else std.log.info("SELFTEST gdma ch{d}_{d}: PASS", .{ channel, length });
            }
        }
        if (permissions) |ok| std.log.info("SELFTEST gdma permissions: {s}", .{if (ok) "PASS" else "FAIL"});
        std.log.info("SELFTEST gdma DONE pass={d} fail={d}", .{ pass, fail });
        hal.time.sleep_ms(1000);
    }
}
