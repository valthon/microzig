//! C3/C6 periodic alarm demo: expected SELFTEST systimer DONE pass=4 fail=0.
//! Four interrupts and three 1 s intervals within +/-100 us, measured by TIMG0
//! at 1 MHz from APB (C3) / PLL_F80M (C6), not by the systimer counter.
//! Both counters derive from the one 40 MHz crystal (systimer from XTAL_CLK,
//! TIMG0 from a PLL locked to it), so their rates agree exactly; see the
//! tolerance note in main. First-alarm phase is unspecified; observation is
//! bounded to 5 seconds of TIMG0 time and 6 seconds of TIMG1 time.
//! C3 TRM v1.4 sections 6.2, 10.3, 11.2.1; C6 TRM v1.2 sections 8.2, 13.3,
//! 13.5.3, 14.3.1 describe the clock sources and periodic alarm setup.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const systimer = hal.systimer;
const usb_serial_jtag = hal.usb_serial_jtag;

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .logFn = report,
});

comptime {
    if (!@import("builtin").is_test) _ = microzig.export_startup();
}

// This demo owns USB TX and its ISR never logs. The normal logger timestamps
// lines and waits with hal.time, which is the clock being tested. Instead use
// only the FIFO helpers (C3 TRM v1.4 §30.3.2; C6 TRM v1.2 §32.3.2), with one
// finite poll budget for the entire line, including all host-consumption waits.
// A stalled host can lose a line; main repeats saved results after it resumes.
fn report(
    comptime _: std.log.Level,
    comptime _: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [256]u8 = undefined;
    // Start on a fresh line even if the previous attempt delivered a fragment.
    const line = std.fmt.bufPrint(&buffer, "\r\n" ++ format ++ "\r\n", args) catch
        "\r\nSELFTEST systimer report: FAIL formatting overflow\r\n";
    var polls_left: usize = 1_000_000;
    var offset: usize = 0;
    while (true) {
        while (usb_serial_jtag.tx_fifo_full()) {
            if (polls_left == 0) {
                // Same stuck-IN-buffer recovery as the port logger, without
                // consulting systimer. No bytes are retained in software.
                usb_serial_jtag.tx_fifo_flush();
                return;
            }
            polls_left -= 1;
        }
        // Wait for the final packet too, using the same remaining budget.
        if (offset == line.len) return;
        const packet = line[offset..][0..@min(64, line.len - offset)];
        for (packet) |byte| usb_serial_jtag.tx_fifo_write(byte);
        // A full 64-byte packet is committed automatically.
        if (packet.len < 64) usb_serial_jtag.tx_fifo_flush();
        offset += packet.len;
    }
}

pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt1 = .{ .c = timer_interrupt },
    },
};

const alarm = systimer.alarm(0);
const reference: hal.timer.Group = .timg0;
const deadline: hal.timer.Group = .timg1;
const period_us = 1_000_000;
// Both counters run from the same crystal, so a correct alarm period differs
// from the TIMG0 interval only by timestamp latency: interrupt entry plus one
// polling iteration, each a few microseconds (measured spread on the C3, Super
// Mini ESP32-C6 and XIAO ESP32-C6: 999,997 to 1,000,002 us). 100 us keeps
// margin for that while still failing a wrong ticks-per-us value, which is
// off by at least 1/16 (6.25%, one systimer tick of 16 per us).
const tolerance_us = 100;
// Only this ISR writes the counter; main reads it with interrupts masked.
// Volatile scalar access avoids C3 atomic libcalls (RV32IMC has no A extension),
// as in the port's hal/atomic.zig implementation.
var interrupt_count: u32 = 0;

fn timer_interrupt(_: *microzig.cpu.TrapFrame) linksection(".ram_text") callconv(.c) void {
    @call(.always_inline, systimer.Alarm.clear_interrupt, .{alarm});
    const counter: *volatile u32 = &interrupt_count;
    counter.* +|= 1;
}

fn observe(times: *[4]u64, count: *u32) !void {
    reference.configure(.{ .divider = 80 });
    defer reference.set_enabled(false);
    reference.set_enabled(true);
    const start = try reference.read();
    var last_count: u32 = 0;
    var settled_at: ?u64 = null;
    // TIMG1 remains independent of SYSTIMER and TIMG0. Its read has a finite
    // latch poll budget, so a read failure also reaches the FAIL reporter.
    deadline.configure(.{ .divider = 80 });
    defer deadline.set_enabled(false);
    deadline.set_enabled(true);
    const deadline_start = try deadline.read();
    while (try deadline.read() - deadline_start < 6 * period_us) {
        // Pair the counter and timestamp with interrupts masked. No UART work
        // takes place during observation; main-loop timestamp latency is covered
        // by the stated tolerance. A skipped observation fails its interval.
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const now = try reference.read();
        count.* = @as(*volatile u32, &interrupt_count).*;
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

    hal.rom.delay_us(1_500_000);
    while (true) {
        const count_ok = reference_ok and count == times.len;
        var pass: usize = @intFromBool(count_ok);
        std.log.info("SELFTEST systimer count: {s} observed={d} expected=4", .{
            if (count_ok) "PASS" else "FAIL", count,
        });
        for (1..times.len) |i| {
            const elapsed = times[i] -| times[i - 1];
            const passed = interval_passed(reference_ok, times[i - 1], times[i]);
            if (passed) pass += 1;
            std.log.info("SELFTEST systimer period{d}: {s} us={d} expected={d} tolerance_us={d}", .{
                i, if (passed) "PASS" else "FAIL", elapsed, period_us, tolerance_us,
            });
        }
        std.log.info("SELFTEST systimer DONE pass={d} fail={d}", .{ pass, 4 - pass });
        hal.rom.delay_us(1_000_000);
    }
}

fn interval_passed(reference_ok: bool, before: u64, after: u64) bool {
    const elapsed = after -| before;
    return reference_ok and before != 0 and after != 0 and
        elapsed >= period_us - tolerance_us and elapsed <= period_us + tolerance_us;
}

test "interval limits and failed observations" {
    const expect = std.testing.expect;
    try expect(interval_passed(true, 1_000_000, 1_999_900));
    try expect(interval_passed(true, 1_000_000, 2_000_100));
    try expect(!interval_passed(true, 1_000_000, 1_999_899));
    try expect(!interval_passed(true, 1_000_000, 2_000_101));
    try expect(!interval_passed(false, 1_000_000, 2_000_000));
    try expect(!interval_passed(true, 0, 1_000_000));
    try expect(!interval_passed(true, 1_000_000, 0));
    try expect(!interval_passed(true, 2_000_000, 1_000_000));
}
