//! External LP UART echo and empty-read timeout on each core.
//! Super Mini GPIO4 RX <- Pico 2 W GP12 TX; GPIO5 TX -> GP13 RX, common GND.
//! Load pico2_w_ram_esp_peer, send `mode lpuart c6` on Pico USB CDC,
//! then start this test. Peer echoes at 115200 8N1.
//! PASS: SELFTEST lp_uart DONE pass=5 fail=0 (load, 64-byte echo and
//! empty-read timeout on LP and HP). Request `status`: require errors=0,
//! PEER lpuart clk: PASS (115200 within 1%) and no peer FAIL verdicts.
//! C6 datasheet v1.6 Table 2-7 and
//! TRM v1.2 §7.13: fixed LP IO MUX function 1, selected by hal.lp_io.
//! UART uses separate TX/RX wires, so TX stays routed during the echo reply;
//! both pads are released after HP finishes. HP stays awake for XTAL_D2.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const lp = hal.lp_core;
const check = @import("lp_uart_check.zig");
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
    lp.stop();
    hal.time.sleep_ms(10);
    const result: check.Result = @bitCast(lp.Mailbox.read(.result));
    const hp = check.run();
    hal.lp_io.release(4);
    hal.lp_io.release(5);
    const checks = [_]bool{ loaded and complete, loaded and complete and result.echo, loaded and complete and result.empty_timeout, hp.echo, hp.empty_timeout };
    const names = [_][]const u8{ "load", "lp_echo", "lp_empty_timeout", "hp_echo", "hp_empty_timeout" };
    const errors = [_][]const u8{
        if (loaded and complete) "none" else "LoadOrCompletionFailed",
        if (loaded and complete) @tagName(result.echo_error) else "LoadOrCompletionFailed",
        if (result.empty_timeout) "none" else "ExpectedTimeout",
        @tagName(hp.echo_error),
        if (hp.empty_timeout) "none" else "ExpectedTimeout",
    };
    hal.time.sleep_ms(1500);
    while (true) {
        var pass: usize = 0;
        for (checks, names, errors) |ok, name, err| {
            if (ok) pass += 1;
            std.log.info("SELFTEST lp_uart {s}: {s} error={s}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL", err });
        }
        std.log.info("SELFTEST lp_uart DONE pass={} fail={}", .{ pass, checks.len - pass });
        hal.time.sleep_ms(1000);
    }
}
