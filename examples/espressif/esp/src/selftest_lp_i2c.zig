//! External LP I2C register-file test on LP, then HP.
//! Load pico2_w_ram_esp_peer on the Pico 2 W before selecting its mode.
//! PASS: SELFTEST lp_i2c DONE pass=7 fail=0: load, one ACK at 0x42
//! and 111 NACKs in 0x08–0x77, 14-byte readback and version 1 at 0xf3,
//! NACK at 0x55 then ACK at 0x42, on both cores. Require peer errors=0.
//! Super Mini GPIO6 SDA / GPIO7 SCL -> Pico GP14 / GP15, common GND.
//! Fixed LP pins: ESP32-C6 datasheet v1.6 Table 2-7. Start the 0x42 peer
//! with `mode i2c c6` first (I2C1 on the Pico). Internal pull-ups, 100 kHz;
//! LP runs before HP.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const lp = hal.lp_core;
const check = @import("lp_i2c_check.zig");
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
        if (!loaded) break;
        if (lp.Mailbox.read(.sequence) == 1) {
            complete = true;
            break;
        }
        hal.time.sleep_ms(1);
    }
    lp.stop();
    hal.time.sleep_ms(10);
    const result: check.Result = .{
        .nacks = lp.Mailbox.read(.counter),
        .acks = lp.Mailbox.read(.detail),
        .faults = lp.Mailbox.read(.result),
        .bits = @bitCast(lp.Mailbox.read(.pad_level)),
    };
    const hp = check.run();
    hal.lp_io.release(6);
    hal.lp_io.release(7);
    const lp_done = loaded and complete;
    const checks = [_]bool{
        lp_done,
        lp_done and result.scan_ok(),
        lp_done and result.bits.write_read,
        lp_done and result.recovery_ok(),
        hp.scan_ok(),
        hp.bits.write_read,
        hp.recovery_ok(),
    };
    const names = [_][]const u8{ "load", "lp_scan", "lp_write_read", "lp_nack_recovery", "hp_scan", "hp_write_read", "hp_nack_recovery" };
    hal.time.sleep_ms(1500);
    while (true) {
        var pass: usize = 0;
        for (checks, names) |ok, name| {
            if (ok) pass += 1;
            std.log.info("SELFTEST lp_i2c {s}: {s} nack={}/{} ack={}/{} fault={}/{} bits={x}/{x}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL", result.nacks, hp.nacks, result.acks, hp.acks, result.faults, hp.faults, @as(u32, @bitCast(result.bits)), @as(u32, @bitCast(hp.bits)) });
        }
        std.log.info("SELFTEST lp_i2c DONE pass={} fail={}", .{ pass, checks.len - pass });
        hal.time.sleep_ms(1000);
    }
}
