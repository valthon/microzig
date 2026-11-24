//! Compare each FIELD payload against the following length and CRC32.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_level = .info,
});

comptime {
    _ = microzig.export_startup();
}

pub fn main() void {
    // Give the parent time to open the USB port after flashing/resetting.
    hal.time.sleep_ms(3000);
    inline for (.{ 31, 32, 63, 64, 65, 100, 200 }) |len| {
        const field: [len]u8 = @splat('h');
        std.log.info("FIELD {s} len={d} crc32={x:0>8}", .{ &field, field.len, std.hash.Crc32.hash(&field) });
    }
    var raw: [32]u8 = undefined;
    for (&raw, 0..) |*byte, i| byte.* = @intCast(i);
    const hex = std.fmt.bytesToHex(raw, .lower);
    std.log.info("HEX {s} len={d} crc32={x:0>8}", .{ hex[0..], hex.len, std.hash.Crc32.hash(&hex) });
    std.log.info("SELFTEST usj_log DONE", .{});
    while (true) hal.time.sleep_ms(1000);
}
