//! Checks that each C3 LEDC channel reports the end of its own duty fade.
//! Channel 0 completes a one-step duty change first, so its DUTY_CHNG_END raw bit is set while
//! channels 1-3 fade; a channel that read channel 0's bit would report "done" at once.
//! C3 TRM v1.4 §32.3.4 (fades) and Register 32.9 (LEDC_INT_RAW_REG). No wiring required.
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
    if (hal.compatibility.chip != .esp32_c3) @compileError("selftest_ledc_fade covers the ESP32-C3 LEDC driver");
    _ = microzig.export_startup();
}

const Result = struct { elapsed_us: u64, done: bool, final_duty: u32 };

fn final_duty(chan: ledc.Channel) u32 {
    const L = microzig.chip.peripherals.LEDC;
    return switch (chan) {
        .channel0 => L.LSCH0_DUTY_R.read().DUTY_LSCH0_R,
        .channel1 => L.LSCH1_DUTY_R.read().DUTY_LSCH1_R,
        .channel2 => L.LSCH2_DUTY_R.read().DUTY_LSCH2_R,
        .channel3 => L.LSCH3_DUTY_R.read().DUTY_LSCH3_R,
    } >> 4;
}

fn fade(chan: ledc.Channel) Result {
    // Fifty increments from 150 to 200, one per 1 kHz PWM period: about 50 ms.
    chan.start_duty_fade(150, .{ .increment = 1, .cycle = 1, .duration = 50 });
    const start = hal.time.get_time_since_boot().to_us();
    var now = start;
    while (now - start < 500_000) : (now = hal.time.get_time_since_boot().to_us()) {
        if (chan.is_duty_fade_done()) return .{ .elapsed_us = now - start, .done = true, .final_duty = final_duty(chan) };
    }
    return .{ .elapsed_us = now - start, .done = false, .final_duty = final_duty(chan) };
}

pub fn main() void {
    ledc.apply(.xtal_clk);
    const timer = ledc.timer(0);
    timer.apply(.{ .clock_config = hal.clock_config, .frequency = 1000, .precision = 10 }, .xtal_clk);
    var results: [4]Result = undefined;
    for (0..4) |i| {
        const chan = ledc.channel(@intCast(i));
        chan.apply(.{ .timer = timer, .initial_duty = 100 });
    }
    hal.time.sleep_ms(5); // channel 0's one-step duty change has ended: its raw bit is set
    for (&results, 0..) |*r, i| r.* = fade(ledc.channel(@intCast(i)));
    hal.time.sleep_ms(1500);
    while (true) {
        var passed: usize = 0;
        for (results, 0..) |r, i| {
            const ok = r.done and r.elapsed_us >= 45_000 and r.elapsed_us <= 60_000 and r.final_duty == 200;
            if (ok) passed += 1;
            std.log.info("SELFTEST ledc_fade channel{}: {s} done={} elapsed_us={} final_duty={}", .{ i, if (ok) @as([]const u8, "PASS") else "FAIL", r.done, r.elapsed_us, r.final_duty });
        }
        std.log.info("SELFTEST ledc_fade DONE pass={} fail={}", .{ passed, results.len - passed });
        hal.time.sleep_ms(1000);
    }
}
