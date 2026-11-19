//! GPIO0's output/input loopback generates edges; ETM toggles GPIO1.
//! Observe GPIO1 through its own input buffer. No external wiring.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = hal.usb_serial_jtag.logger.log });
comptime {
    _ = microzig.export_startup();
}
pub fn main() void {
    const source = hal.gpio.num(0);
    const target = hal.gpio.num(1);
    source.apply(.{ .input_enable = true, .output_enable = true });
    target.apply(.{ .input_enable = true, .output_enable = true });
    source.put(0);
    target.put(0);
    hal.rom.delay_us(10);
    hal.etm.apply();
    const event = hal.etm.gpio_event(0, source, .rising);
    const task = hal.etm.gpio_task(1, 0, .toggle, true);
    const route = hal.etm.channel(0);
    route.apply(event, task) catch unreachable; // nonzero hardware IDs
    route.enable(true);
    source.put(1);
    hal.rom.delay_us(10);
    const first = target.read() == 1;
    source.put(0);
    hal.rom.delay_us(10);
    const falling = target.read() == 1;
    source.put(1);
    hal.rom.delay_us(10);
    const second = target.read() == 0;
    route.enable(false);
    source.put(0);
    hal.rom.delay_us(10);
    source.put(1);
    hal.rom.delay_us(10);
    const disabled = target.read() == 0;
    // Exercise the second enable bank and the last legal channel.
    const last = hal.etm.channel(49);
    last.apply(event, task) catch unreachable;
    last.enable(true);
    source.put(0);
    hal.rom.delay_us(10);
    source.put(1);
    hal.rom.delay_us(10);
    const bank1 = target.read() == 1;
    last.enable(false);
    _ = hal.etm.gpio_task(1, 0, .toggle, false);
    source.apply(.{});
    target.apply(.{});
    const checks = [_]bool{ first, falling, second, disabled, bank1 };
    const names = [_][]const u8{ "rising_toggle", "falling_ignored", "second_toggle", "disabled", "channel49" };
    hal.time.sleep_ms(1500);
    while (true) {
        var passed: usize = 0;
        for (checks, names) |ok, name| {
            if (ok) passed += 1;
            std.log.info("SELFTEST etm {s}: {s}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL" });
        }
        std.log.info("SELFTEST etm DONE pass={} fail={}", .{ passed, checks.len - passed });
        hal.time.sleep_ms(1000);
    }
}
