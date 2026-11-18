//! GPIO0 loops the PWM back into its own input buffer. No wiring required.
//! ESP32-C6 TRM v1.2 §35.3.2–35.3.4 and §7.4.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const ledc = hal.ledc;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .log_level = .info,
    .logFn = hal.usb_serial_jtag.logger.log,
});

comptime {
    if (hal.compatibility.chip != .esp32_c6) @compileError("selftest_c6_ledc requires ESP32-C6");
    _ = microzig.export_startup();
}

const Sample = struct { hz: u64, duty_per_mille: u64 };

fn sample() Sample {
    const pin = hal.gpio.num(0);
    var last = pin.read();
    var rising: u64 = 0;
    var high: u64 = 0;
    var total: u64 = 0;
    const start = hal.time.get_time_since_boot().to_us();
    while (hal.time.get_time_since_boot().to_us() - start < 40_000) {
        const value = pin.read();
        if (value == 1 and last == 0) rising += 1;
        high += value;
        total += 1;
        last = value;
    }
    const elapsed = hal.time.get_time_since_boot().to_us() - start;
    return .{ .hz = rising * 1_000_000 / elapsed, .duty_per_mille = high * 1000 / @max(1, total) };
}

pub fn main() void {
    const pin = hal.gpio.num(0);
    const timer = ledc.timer(0);
    const channel = ledc.channel(0);
    pin.apply(.{ .input_enable = true, .output_enable = true });
    ledc.apply(.xtal_clk);
    timer.apply(.{ .clock_config = hal.clock_config, .frequency = 1000, .precision = 10 }, .xtal_clk);
    channel.connect_pin(pin);
    channel.apply(.{ .timer = timer, .initial_duty = 256 });
    hal.time.sleep_ms(5);
    const quarter = sample();
    const quarter_duty = microzig.chip.peripherals.LEDC.CH0_DUTY_R.read().DUTY_CH_R >> 4;
    channel.set_duty(768);
    hal.time.sleep_ms(5);
    const three_quarters = sample();
    const three_quarters_duty = microzig.chip.peripherals.LEDC.CH0_DUTY_R.read().DUTY_CH_R >> 4;
    // Verify both supported PCR clock sources with the same pad loopback.
    ledc.set_clock_source(.pll_f80m_clk);
    timer.apply(.{ .clock_config = hal.clock_config, .frequency = 1000, .precision = 10 }, .pll_f80m_clk);
    hal.time.sleep_ms(5);
    const pll = sample();
    // Fifty increments from 150 to 200 at one increment per PWM period.
    const fade_completed = if (channel.fade_duty_blocking(150, .{ .increment = 1, .cycle = 1, .duration = 50 }, 250_000)) |_| true else |_| false;
    const final_duty = microzig.chip.peripherals.LEDC.CH0_DUTY_R.read().DUTY_CH_R >> 4;
    const checks = [_]bool{
        quarter.hz >= 900 and quarter.hz <= 1100,
        quarter.duty_per_mille >= 200 and quarter.duty_per_mille <= 300,
        three_quarters.duty_per_mille >= 700 and three_quarters.duty_per_mille <= 800,
        fade_completed and final_duty == 200,
        quarter_duty == 256,
        three_quarters_duty == 768,
        pll.hz >= 900 and pll.hz <= 1100,
    };
    const names = [_][]const u8{ "frequency", "duty_25", "duty_75", "fade", "latched_duty_25", "latched_duty_75", "pll_frequency" };
    const expected = [_]u64{ 1000, 250, 750, 200, 256, 768, 1000 };
    const actual = [_]u64{ quarter.hz, quarter.duty_per_mille, three_quarters.duty_per_mille, final_duty, quarter_duty, three_quarters_duty, pll.hz };
    pin.apply(.{});
    hal.time.sleep_ms(1500);
    while (true) {
        var passed: usize = 0;
        for (checks, names, expected, actual) |pass, name, want, got| {
            if (pass) passed += 1;
            std.log.info("SELFTEST c6_ledc {s}: {s} expected={} actual={}", .{ name, if (pass) @as([]const u8, "PASS") else "FAIL", want, got });
        }
        std.log.info("SELFTEST c6_ledc DONE pass={} fail={}", .{ passed, checks.len - passed });
        hal.time.sleep_ms(1000);
    }
}
