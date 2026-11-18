const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const Group = hal.timer.Group;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_level = .info,
});

comptime {
    _ = microzig.export_startup();
}

fn now_us() u64 {
    return hal.systimer.unit(0).read() / hal.systimer.ticks_per_us();
}

const Result = struct {
    name: []const u8,
    passed: bool = false,
    observed: u64 = 0,
};

fn rate(g: Group, result: *Result) !void {
    // Default APB is 80 MHz; divider 80 gives one count per microsecond.
    g.configure(.{ .divider = 80 });
    defer g.set_enabled(false);
    g.set_enabled(true);
    const start = now_us();
    const before = try g.read();
    hal.time.sleep_ms(50);
    const after = try g.read();
    const elapsed = now_us() - start;
    const ticks = after -% before;
    result.observed = ticks;
    const difference = if (ticks > elapsed) ticks - elapsed else elapsed - ticks;
    result.passed = elapsed >= 50000 and difference * 100 <= elapsed;
}

fn alarm_check(result: *Result) !void {
    const g: Group = .timg0;
    g.configure(.{});
    defer g.set_enabled(false);
    g.set_interrupt_enabled(true);
    defer g.set_interrupt_enabled(false);
    g.set_alarm(20000, false);
    g.arm_alarm();
    const start = now_us();
    g.set_enabled(true);
    while (!g.interrupt_raw()) {
        if (now_us() - start > 100000) return;
    }
    const count = try g.read();
    result.observed = count;
    result.passed = count >= 20000 and count <= 20200 and g.interrupt_status();
    g.clear_interrupt();
    result.passed = result.passed and !g.interrupt_raw();
}

fn reload_check(result: *Result) !void {
    const g: Group = .timg1;
    g.configure(.{});
    defer g.set_enabled(false);
    g.set_reload(1234);
    g.reload();
    g.set_alarm(21234, true);
    g.arm_alarm();
    g.set_enabled(true);
    var passed: u64 = 0;
    for (0..3) |_| {
        const start = now_us();
        while (!g.interrupt_raw()) {
            if (now_us() - start > 100000) return;
        }
        const count = try g.read();
        const elapsed = now_us() - start;
        // The counter must have reloaded to 1234, not continued past 21234.
        if (count < 1234 or count > 1434 or elapsed < 19000 or elapsed > 21000) return;
        passed += 1;
        g.clear_interrupt();
        g.arm_alarm();
    }
    result.observed = passed;
    result.passed = passed == 3;
}

fn watchdog_checks(timeout: *Result, fed: *Result) !void {
    const w: hal.wdt.Main = .mwdt1;
    // APB / 80 = 1 MHz. No reset action is configured at any stage.
    const stages: [4]hal.wdt.Stage = .{
        .{ .timeout = 40000, .action = .interrupt },
        .{ .timeout = 1000000 },
        .{ .timeout = 1000000 },
        .{ .timeout = 1000000 },
    };
    w.set_interrupt_enabled(false); // Poll RAW; never route this to the CPU.
    try w.configure(80, false, stages);
    defer w.disable();
    const start = now_us();
    while (!w.interrupt_raw()) {
        if (now_us() - start > 120000) return;
    }
    const elapsed = now_us() - start;
    timeout.observed = elapsed;
    timeout.passed = elapsed >= 39000 and elapsed <= 41000;
    w.disable();
    w.clear_interrupt();
    try w.configure(80, false, stages);
    var prevented = true;
    for (0..6) |_| {
        hal.time.sleep_ms(10);
        if (w.interrupt_raw()) prevented = false;
        w.feed();
    }
    // 60 ms exceeds the original 40 ms timeout, but each feed restarts stage 0.
    fed.observed = 60000;
    fed.passed = prevented and !w.interrupt_raw();
    // Confirm the fed watchdog still expires when feeding stops.
    const last_feed = now_us();
    while (!w.interrupt_raw()) {
        if (now_us() - last_feed > 120000) {
            fed.passed = false;
            return;
        }
    }
    const after_feed = now_us() - last_feed;
    fed.passed = fed.passed and after_feed >= 39000 and after_feed <= 41000;
    w.clear_interrupt();
}

pub fn main() void {
    var results = [_]Result{
        .{ .name = "timg0_rate" },
        .{ .name = "timg1_rate" },
        .{ .name = "alarm" },
        .{ .name = "auto_reload" },
        .{ .name = "mwdt1_timeout" },
        .{ .name = "mwdt1_feed" },
    };
    // A latch timeout leaves that check failed; all remaining checks still run.
    rate(.timg0, &results[0]) catch |err| {
        results[0].passed = false;
        results[0].observed = @intFromError(err);
    };
    rate(.timg1, &results[1]) catch |err| {
        results[1].passed = false;
        results[1].observed = @intFromError(err);
    };
    alarm_check(&results[2]) catch |err| {
        results[2].passed = false;
        results[2].observed = @intFromError(err);
    };
    reload_check(&results[3]) catch |err| {
        results[3].passed = false;
        results[3].observed = @intFromError(err);
    };
    watchdog_checks(&results[4], &results[5]) catch |err| {
        results[4].passed = false;
        results[4].observed = @intFromError(err);
    };
    hal.time.sleep_ms(1500);
    while (true) {
        var pass: usize = 0;
        for (results) |result| {
            if (result.passed) pass += 1;
            std.log.info("SELFTEST timers {s}: {s} observed={d}", .{
                result.name, if (result.passed) "PASS" else "FAIL", result.observed,
            });
        }
        std.log.info("SELFTEST timers DONE pass={d} fail={d}", .{ pass, results.len - pass });
        hal.time.sleep_ms(1000);
    }
}
