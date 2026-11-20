//! HP software trigger interrupts an already-running LP CPU; no wiring.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const lp = hal.lp_core;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = hal.usb_serial_jtag.logger.log });
comptime {
    microzig.export_startup();
}
fn await_sequence(wanted: u32) bool {
    for (0..1000) |_| {
        if (lp.Mailbox.read(.sequence) == wanted) return true;
        hal.time.sleep_ms(1);
    }
    return false;
}
pub fn main() void {
    lp.stop();
    hal.time.sleep_ms(10);
    const ready = blk: {
        lp.load(@embedFile("lp_image")) catch break :blk false;
        lp.start(.{}, 10000) catch break :blk false;
        break :blk await_sequence(1);
    };
    if (ready) lp.wake();
    const handled = ready and await_sequence(2);
    const source = handled and lp.Mailbox.read(.result) == 1 and lp.Mailbox.read(.counter) == 1;
    lp.Mailbox.write(.command, 1);
    const returned = handled and await_sequence(3);
    lp.stop();
    const checks = [_]bool{ ready, handled, source, returned };
    const names = [_][]const u8{ "ready", "vector30", "pmu_source", "mret" };
    hal.time.sleep_ms(1500);
    while (true) {
        var pass: usize = 0;
        for (checks, names) |ok, name| {
            if (ok) pass += 1;
            std.log.info("SELFTEST lp_irq {s}: {s}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL" });
        }
        std.log.info("SELFTEST lp_irq DONE pass={} fail={}", .{ pass, checks.len - pass });
        hal.time.sleep_ms(1000);
    }
}
