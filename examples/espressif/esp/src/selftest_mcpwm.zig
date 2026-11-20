//! GPIO0/1 sample PWM A/B through their own input buffers. PCNT counts A.
//! No external wiring. TRM v1.2 §36.3.2–36.3.3, §31.2, §7.4.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = hal.usb_serial_jtag.logger.log });
comptime {
    _ = microzig.export_startup();
}
const Sample = struct { hz: u64, a: u32, b: u32, overlap: u32, gap: u32 };
fn sample() Sample {
    const unit = hal.pcnt.unit(0);
    unit.clear();
    unit.pause(false);
    var a: u32 = 0;
    var b: u32 = 0;
    var overlap: u32 = 0;
    var gap: u32 = 0;
    var total: u32 = 0;
    const start = hal.time.get_time_since_boot().to_us();
    while (hal.time.get_time_since_boot().to_us() - start < 100_000) {
        // A single GPIO input snapshot avoids false overlap across an edge.
        const inputs = microzig.chip.peripherals.GPIO.IN.read().DATA_NEXT;
        const x = inputs & 1;
        const y = (inputs >> 1) & 1;
        a += x;
        b += y;
        overlap += x & y;
        gap += @intFromBool(x == 0 and y == 0);
        total += 1;
    }
    unit.pause(true);
    const elapsed = hal.time.get_time_since_boot().to_us() - start;
    const edges: u64 = @intCast(@max(0, unit.count()));
    return .{ .hz = edges * 1_000_000 / elapsed, .a = a * 1000 / total, .b = b * 1000 / total, .overlap = overlap * 1000 / total, .gap = gap * 1000 / total };
}
fn run(dead_ticks: u16, clock_source: hal.mcpwm.ClockSource, divider: u9) Sample {
    const a = hal.gpio.num(0);
    const b = hal.gpio.num(1);
    // Disconnect both pads during group reset/reconfiguration.
    a.apply(.{});
    b.apply(.{});
    hal.mcpwm.apply(.{ .dead_ticks = dead_ticks, .clock_source = clock_source, .group_divider = divider }) catch unreachable;
    a.apply(.{ .input_enable = true, .output_enable = true });
    b.apply(.{ .input_enable = true, .output_enable = true });
    hal.mcpwm.connect_pin(.a, a);
    hal.mcpwm.connect_pin(.b, b);
    hal.time.sleep_ms(2);
    return sample();
}
pub fn main() void {
    hal.pcnt.apply();
    hal.pcnt.unit(0).apply(.{}) catch unreachable;
    hal.pcnt.unit(0).connect_pin(hal.gpio.num(0));
    const normal = run(0, .xtal_clk, 40);
    const delayed = run(100, .xtal_clk, 40);
    const pll = run(100, .pll_f160m_clk, 160);
    hal.gpio.num(0).apply(.{});
    hal.gpio.num(1).apply(.{});
    hal.mcpwm.pause(true);
    const checks = [_]bool{
        normal.hz >= 970 and normal.hz <= 1030,
        normal.a >= 470 and normal.a <= 530 and normal.b >= 470 and normal.b <= 530,
        delayed.hz >= 970 and delayed.hz <= 1030,
        delayed.a >= 370 and delayed.a <= 430 and delayed.b >= 370 and delayed.b <= 430,
        delayed.overlap <= 5 and delayed.gap >= 170 and delayed.gap <= 230,
        pll.hz >= 970 and pll.hz <= 1030 and pll.a >= 370 and pll.a <= 430,
    };
    const names = [_][]const u8{ "pcnt_frequency", "complementary_duty", "deadtime_frequency", "deadtime_duty", "deadtime_gap", "pll_frequency" };
    hal.time.sleep_ms(1500);
    while (true) {
        var passed: usize = 0;
        for (checks, names) |ok, name| {
            if (ok) passed += 1;
            std.log.info("SELFTEST mcpwm {s}: {s}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL" });
        }
        std.log.info("SELFTEST mcpwm measurements: normal_hz={} dead_hz={} a={} b={} gap={} overlap={} pll_hz={}", .{ normal.hz, delayed.hz, delayed.a, delayed.b, delayed.gap, delayed.overlap, pll.hz });
        std.log.info("SELFTEST mcpwm DONE pass={} fail={}", .{ passed, checks.len - passed });
        hal.time.sleep_ms(1000);
    }
}
