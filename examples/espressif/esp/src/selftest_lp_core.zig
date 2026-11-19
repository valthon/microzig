//! HP embeds the LP binary built by the same build graph; no wiring.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const lp = hal.lp_core;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = hal.usb_serial_jtag.logger.log });
comptime {
    microzig.export_startup();
}
fn await_count(wanted: u32) bool {
    for (0..1000) |_| {
        if (lp.Mailbox.read(.sequence) == wanted) return lp.Mailbox.read(.counter) == wanted;
        hal.time.sleep_us(100);
    }
    return false;
}
pub fn main() void {
    // Enable the HP GPIO input path before LP takes ownership of the pad.
    hal.gpio.num(0).apply(.{ .input_enable = true });
    lp.stop();
    // HP active; allow the 255 LP_FAST_CLK sleep-stall cycles (§3.9.2).
    hal.time.sleep_ms(10);
    const loaded = blk: {
        lp.load(@embedFile("lp_image")) catch break :blk false;
        lp.start(.{ .etm = true }, 10000) catch break :blk false;
        break :blk true;
    };
    const first = loaded and await_count(1);
    const high = first and hal.gpio.num(0).read() == 1 and lp.Mailbox.read(.pad_level) == 1;
    hal.time.sleep_ms(10); // LP must finish its sleep flow before another wake.
    if (first) lp.wake();
    const second = first and await_count(2);
    const low = second and hal.gpio.num(0).read() == 0 and lp.Mailbox.read(.pad_level) == 0;
    hal.time.sleep_ms(10);
    const source = hal.gpio.num(1);
    source.apply(.{ .input_enable = true, .output_enable = true });
    source.put(0);
    hal.time.sleep_us(10);
    hal.etm.apply();
    const event = hal.etm.gpio_event(0, source, .rising);
    const route = hal.etm.channel(0);
    const routed = blk: {
        route.apply(event, .lp_cpu_wake) catch break :blk false;
        route.enable(true);
        break :blk true;
    };
    source.put(1);
    const etm = second and routed and await_count(3) and lp.Mailbox.read(.result) == 1;
    route.enable(false);
    source.apply(.{});
    lp.stop();
    hal.time.sleep_ms(10);
    // Exercise HP access to the same LP peripheral while LP is stopped.
    hal.lp_io.put(0, 1);
    hal.time.sleep_us(10);
    const hp_io = hal.lp_io.read(0) == 1 and hal.gpio.num(0).read() == 1;
    hal.lp_io.release(0);
    const checks = [_]bool{ loaded, first, second, high, low, hp_io, etm };
    const names = [_][]const u8{ "load", "counter", "hp_wake", "lp_io_high", "lp_io_low", "hp_lp_io", "etm_wake" };
    hal.time.sleep_ms(1500);
    while (true) {
        var pass: usize = 0;
        for (checks, names) |ok, name| {
            if (ok) pass += 1;
            std.log.info("SELFTEST lp_core {s}: {s}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL" });
        }
        std.log.info("SELFTEST lp_core DONE pass={} fail={}", .{ pass, checks.len - pass });
        hal.time.sleep_ms(1000);
    }
}
