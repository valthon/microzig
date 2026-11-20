//! LP UART internal loopback, on each core, with no pad routing or wiring.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const lp = hal.lp_core;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = hal.usb_serial_jtag.logger.log });
comptime {
    microzig.export_startup();
}
pub fn main() void {
    lp.stop();
    hal.time.sleep_ms(10);
    const loaded = blk: {
        lp.load(@embedFile("lp_image")) catch break :blk false;
        lp.start(.{}, 10000) catch break :blk false;
        break :blk true;
    };
    var complete = false;
    for (0..3000) |_| {
        if (lp.Mailbox.read(.sequence) == 1) {
            complete = true;
            break;
        }
        hal.time.sleep_ms(1);
    }
    const result = lp.Mailbox.read(.result);
    lp.stop();
    hal.time.sleep_ms(10);
    const hp = @import("lp_uart_check.zig").run();
    const checks = [_]bool{ loaded and complete, result & 1 != 0, result & 2 != 0, hp & 1 != 0, hp & 2 != 0 };
    const names = [_][]const u8{ "load", "lp_loopback", "lp_empty_timeout", "hp_loopback", "hp_empty_timeout" };
    hal.time.sleep_ms(1500);
    while (true) {
        var pass: usize = 0;
        for (checks, names) |ok, name| {
            if (ok) pass += 1;
            std.log.info("SELFTEST lp_uart {s}: {s}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL" });
        }
        std.log.info("SELFTEST lp_uart DONE pass={} fail={}", .{ pass, checks.len - pass });
        hal.time.sleep_ms(1000);
    }
}
