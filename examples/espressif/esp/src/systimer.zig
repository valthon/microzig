//! C3/C6 periodic alarm demo: expected SELFTEST systimer DONE pass=4 fail=0.
//! Four interrupts and three 1 s intervals within +/-100 us, measured by TIMG0
//! at 1 MHz from APB (C3) / PLL_F80M (C6), not by the systimer counter.
//! Both counters derive from the one 40 MHz crystal (systimer from XTAL_CLK,
//! TIMG0 from a PLL locked to it), so their rates agree exactly; see the
//! tolerance note in main. First-alarm phase is unspecified; observation is
//! bounded to 5 seconds of TIMG0 time and 6 seconds of systimer time.
//! C3 TRM v1.4 sections 6.2, 10.3, 11.2.1; C6 TRM v1.2 sections 8.2, 13.3,
//! 13.5.3, 14.3.1 describe the clock sources and periodic alarm setup.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const systimer = hal.systimer;
const usb_serial_jtag = hal.usb_serial_jtag;

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .logFn = usb_serial_jtag.logger.log,
});

comptime {
    _ = microzig.export_startup();
}

pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt1 = .{ .c = timer_interrupt },
    },
};

const alarm = systimer.alarm(0);
const reference: hal.timer.Group = .timg0;
const period_us = 1_000_000;
// Both counters run from the same crystal, so a correct alarm period differs
// from the TIMG0 interval only by timestamp latency: interrupt entry plus one
// polling iteration, each a few microseconds (measured spread on the C3, Super
// Mini and XIAO: 999,997 to 1,000,002 us). 100 us keeps margin for that while
// still failing a wrong ticks-per-us value, which is off by at least 1/16
// (6.25%, one systimer tick of 16 per us).
const tolerance_us = 100;
var interrupt_count: std.atomic.Value(u32) = .init(0);

fn timer_interrupt(_: *microzig.cpu.TrapFrame) linksection(".ram_text") callconv(.c) void {
    alarm.clear_interrupt();
    _ = interrupt_count.fetchAdd(1, .release);
}

fn observe(times: *[4]u64, count: *u32) !void {
    reference.configure(.{ .divider = 80 });
    defer reference.set_enabled(false);
    reference.set_enabled(true);
    const start = try reference.read();
    var last_count: u32 = 0;
    var settled_at: ?u64 = null;
    // Also bound polling by the systimer's own clock (hal.time), in case the
    // reference counter stops advancing. The window exceeds TIMG0's 5 s bound.
    const limit = microzig.drivers.time.make_timeout_us(hal.time.get_time_since_boot(), 6 * period_us);
    while (!limit.is_reached_by(hal.time.get_time_since_boot())) {
        // Pair the counter and timestamp with interrupts masked. No UART work
        // takes place during observation; main-loop timestamp latency is covered
        // by the stated tolerance. A skipped observation fails its interval.
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const now = try reference.read();
        count.* = interrupt_count.load(.acquire);
        if (count.* != last_count) {
            if (count.* == last_count + 1 and count.* <= times.len)
                times[count.* - 1] = now - start;
            last_count = count.*;
        }
        if (count.* >= times.len and settled_at == null) settled_at = now;
        // An extra half-period catches duplicate/spurious interrupts after N.
        if (settled_at) |at| {
            if (now - at >= period_us / 2) return;
        }
        if (now - start >= 5 * period_us) return;
    }
    return error.Timeout;
}

pub fn main() void {
    std.log.info("hello world!", .{});

    // unit0 is already enabled as it is used by `hal.time`.
    alarm.set_unit(.unit0);

    // sets the period to one second.
    alarm.set_period(@intCast(1_000_000 * systimer.ticks_per_us()));

    // to enable period mode you have to first clear the mode bit.
    alarm.set_mode(.target);
    alarm.set_mode(.period);

    alarm.set_interrupt_enabled(true);

    microzig.cpu.interrupt.set_priority_threshold(.zero);

    microzig.cpu.interrupt.set_type(.interrupt1, .level);
    microzig.cpu.interrupt.set_priority(.interrupt1, .highest);
    microzig.cpu.interrupt.map(.systimer_target0, .interrupt1);
    microzig.cpu.interrupt.enable(.interrupt1);

    microzig.cpu.interrupt.enable_interrupts();

    var times: [4]u64 = @splat(0);
    var count: u32 = 0;
    alarm.set_enabled(true);
    var reference_ok = true;
    observe(&times, &count) catch |err| {
        reference_ok = false;
        std.log.err("reference timer: {s}", .{@errorName(err)});
    };
    alarm.set_enabled(false);
    alarm.set_interrupt_enabled(false);
    microzig.cpu.interrupt.disable(.interrupt1);

    hal.time.sleep_ms(1500);
    while (true) {
        const count_ok = reference_ok and count == times.len;
        var pass: usize = @intFromBool(count_ok);
        std.log.info("SELFTEST systimer count: {s} observed={d} expected=4", .{
            if (count_ok) "PASS" else "FAIL", count,
        });
        for (1..times.len) |i| {
            const elapsed = times[i] -| times[i - 1];
            const passed = reference_ok and times[i - 1] != 0 and times[i] != 0 and
                elapsed >= period_us - tolerance_us and elapsed <= period_us + tolerance_us;
            if (passed) pass += 1;
            std.log.info("SELFTEST systimer period{d}: {s} us={d} expected={d} tolerance_us={d}", .{
                i, if (passed) "PASS" else "FAIL", elapsed, period_us, tolerance_us,
            });
        }
        std.log.info("SELFTEST systimer DONE pass={d} fail={d}", .{ pass, 4 - pass });
        hal.time.sleep_ms(1000);
    }
}
