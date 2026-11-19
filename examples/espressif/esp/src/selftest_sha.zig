//! No wiring. Hardware results compared with Zig's software SHA (FIPS 180-4).
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = hal.usb_serial_jtag.logger.log });
comptime {
    _ = microzig.export_startup();
}
pub fn main() void {
    hal.time.sleep_ms(1500);
    var pass: usize = 0;
    var fail: usize = 0;
    const data: [129]u8 = @splat(0x61);
    inline for (.{ hal.sha.Algorithm.sha1, hal.sha.Algorithm.sha224, hal.sha.Algorithm.sha256 }) |algorithm| {
        const Software = switch (algorithm) {
            .sha1 => std.crypto.hash.Sha1,
            .sha224 => std.crypto.hash.sha2.Sha224,
            .sha256 => std.crypto.hash.sha2.Sha256,
        };
        for ([_][]const u8{ "", "abc", data[0..55], data[0..56], data[0..63], data[0..64], &data }) |input| {
            var expected: [Software.digest_length]u8 = undefined;
            var actual: [Software.digest_length]u8 = undefined;
            Software.hash(input, &expected, .{});
            const ok = if (hal.sha.hash(algorithm, input, &actual)) |_| std.mem.eql(u8, &expected, &actual) else |_| false;
            if (ok) pass += 1 else fail += 1;
            std.log.info("SELFTEST sha {s}_{d}: {s}", .{ @tagName(algorithm), input.len, if (ok) @as([]const u8, "PASS") else "FAIL" });
        }
    }
    while (true) {
        std.log.info("SELFTEST sha DONE pass={} fail={}", .{ pass, fail });
        hal.time.sleep_ms(1000);
    }
}
