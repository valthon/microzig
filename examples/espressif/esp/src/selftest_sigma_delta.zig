//! GPIO0 output is sampled through its own input buffer; no wiring.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = hal.usb_serial_jtag.logger.log });
comptime {
    _ = microzig.export_startup();
}

fn sample() u32 {
    var high: u32 = 0;
    var total: u32 = 0;
    const start = hal.time.get_time_since_boot().to_us();
    while (hal.time.get_time_since_boot().to_us() - start < 100_000) {
        high += hal.gpio.num(0).read();
        total += 1;
    }
    return high * 1000 / @max(1, total);
}

pub fn main() void {
    const pin = hal.gpio.num(0);
    pin.apply(.{ .input_enable = true, .output_enable = true });
    const channel = hal.sigma_delta.channel(0);
    channel.connect_pin(pin);
    hal.sigma_delta.enable(true);
    var values: [3]u32 = undefined;
    for ([_]i8{ -64, 0, 64 }, &values) |density, *value| {
        channel.apply(density, 251) catch unreachable; // fixed valid divider
        hal.time.sleep_ms(2);
        value.* = sample();
    }
    hal.sigma_delta.enable(false);
    pin.apply(.{});
    hal.time.sleep_ms(1500);
    while (true) {
        var passed: usize = 0;
        for (values, [_]u32{ 250, 500, 750 }, [_][]const u8{ "density_25", "density_50", "density_75" }) |actual, expected, name| {
            const ok = actual + 60 >= expected and actual <= expected + 60;
            if (ok) passed += 1;
            std.log.info("SELFTEST sigma_delta {s}: {s} expected={} actual={}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL", expected, actual });
        }
        std.log.info("SELFTEST sigma_delta DONE pass={} fail={}", .{ passed, 3 - passed });
        hal.time.sleep_ms(1000);
    }
}
