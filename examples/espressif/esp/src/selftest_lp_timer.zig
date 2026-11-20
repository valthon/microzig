//! RTC target 1 periodically resets/wakes LP. No wiring.
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
    hal.lp_timer.disable();
    const loaded = blk: {
        lp.load(@embedFile("lp_image")) catch break :blk false;
        lp.start(.{ .timer = true }, 10000) catch break :blk false;
        break :blk true;
    };
    hal.time.sleep_ms(2000);
    const first = lp.Mailbox.read(.counter);
    hal.time.sleep_ms(2000);
    const second = lp.Mailbox.read(.counter);
    lp.stop();
    hal.time.sleep_ms(10);
    hal.lp_timer.disable();
    const stopped = lp.Mailbox.read(.counter);
    hal.time.sleep_ms(100);
    const checks = [_]bool{ loaded, first >= 2, second > first and lp.Mailbox.read(.result) == 0, lp.Mailbox.read(.counter) == stopped };
    const names = [_][]const u8{ "load", "periodic", "rearm", "stop" };
    hal.time.sleep_ms(1500);
    while (true) {
        var pass: usize = 0;
        for (checks, names) |ok, name| {
            if (ok) pass += 1;
            std.log.info("SELFTEST lp_timer {s}: {s} count={}/{}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL", first, second });
        }
        std.log.info("SELFTEST lp_timer DONE pass={} fail={}", .{ pass, checks.len - pass });
        hal.time.sleep_ms(1000);
    }
}
