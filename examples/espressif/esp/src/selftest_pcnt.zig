//! GPIO0 drives its own PCNT input through the matrix; no wiring.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = hal.usb_serial_jtag.logger.log });
comptime {
    _ = microzig.export_startup();
}
fn pulses(n: usize, width_us: u32) void {
    const pin = hal.gpio.num(0);
    for (0..n) |_| {
        pin.put(1);
        hal.rom.delay_us(width_us);
        pin.put(0);
        hal.rom.delay_us(width_us);
    }
}
pub fn main() void {
    const pin = hal.gpio.num(0);
    pin.apply(.{ .input_enable = true, .output_enable = true });
    pin.put(0);
    hal.pcnt.apply();
    const unit = hal.pcnt.unit(0);
    unit.connect_pin(pin);
    unit.apply(.{ .low_limit = -5, .high_limit = 5, .threshold0 = 3, .threshold1 = -3 }) catch unreachable;
    unit.pause(false);
    pulses(3, 100);
    const count = unit.count();
    const threshold = unit.events().threshold0;
    unit.clear_events();
    pulses(2, 100);
    const high = unit.count() == 0 and unit.events().high_limit;
    unit.pause(true);
    pulses(2, 100);
    const paused = unit.count() == 0;
    unit.apply(.{ .low_limit = -5, .high_limit = 5, .rising = .decrement, .threshold0 = -3 }) catch unreachable;
    unit.pause(false);
    pulses(3, 100);
    const negative = unit.count() == -3 and unit.events().threshold0;
    unit.clear_events();
    pulses(2, 100);
    const low = unit.count() == 0 and unit.events().low_limit;
    unit.apply(.{ .filter_cycles = 1023 }) catch unreachable;
    unit.pause(false);
    pulses(20, 2);
    const rejected = unit.count() == 0;
    pulses(4, 100);
    const accepted = unit.count() == 4;
    unit.pause(true);
    unit.clear();
    const cleared = unit.count() == 0;
    pin.apply(.{});
    const checks = [_]bool{ count == 3, threshold, high, paused, negative, low, rejected, accepted, cleared };
    const names = [_][]const u8{ "edges", "threshold", "high_limit", "pause", "decrement", "low_limit", "filter_reject", "filter_accept", "clear" };
    hal.time.sleep_ms(1500);
    while (true) {
        var passed: usize = 0;
        for (checks, names) |ok, name| {
            if (ok) passed += 1;
            std.log.info("SELFTEST pcnt {s}: {s}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL" });
        }
        std.log.info("SELFTEST pcnt DONE pass={} fail={}", .{ passed, checks.len - passed });
        hal.time.sleep_ms(1000);
    }
}
