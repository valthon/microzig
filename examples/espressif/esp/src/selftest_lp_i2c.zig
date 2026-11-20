//! No devices or wiring: scan LP I2C from LP, then transfer ownership to HP.
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
    for (0..10000) |_| {
        if (lp.Mailbox.read(.sequence) == 1) {
            complete = true;
            break;
        }
        hal.time.sleep_ms(1);
    }
    lp.stop();
    hal.time.sleep_ms(10);
    const nacks = lp.Mailbox.read(.counter);
    const acks = lp.Mailbox.read(.detail);
    const faults = lp.Mailbox.read(.result);
    const bits = lp.Mailbox.read(.pad_level);
    const hp = @import("lp_i2c_check.zig").run();
    hal.lp_io.release(6);
    hal.lp_io.release(7);
    const checks = [_]bool{ loaded and complete, nacks == 112 and acks == 0 and faults == 0, bits == 7, hp.nacks == 112 and hp.acks == 0 and hp.faults == 0, hp.bits == 7 };
    const names = [_][]const u8{ "load", "lp_empty_scan", "lp_recovery", "hp_empty_scan", "hp_recovery" };
    hal.time.sleep_ms(1500);
    while (true) {
        var pass: usize = 0;
        for (checks, names) |ok, name| {
            if (ok) pass += 1;
            std.log.info("SELFTEST lp_i2c {s}: {s} nack={}/{} ack={}/{} fault={}/{}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL", nacks, hp.nacks, acks, hp.acks, faults, hp.faults });
        }
        std.log.info("SELFTEST lp_i2c DONE pass={} fail={}", .{ pass, checks.len - pass });
        hal.time.sleep_ms(1000);
    }
}
