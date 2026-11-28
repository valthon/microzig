const std = @import("std");
const microzig = @import("microzig");
const systick = microzig.cpu.peripherals.systick;
const hal = microzig.hal;

var ns_per_ticks: u64 = 0;
var wraps: u32 = 0;

const SystickError = error{
    ClkOverflow,
    ClkUnderflow,
};

// HAL should provide clock source for systick as well as ahb.
// We will choose from the fastest clock source.
// See: https://developer.arm.com/documentation/dui0497/a/cortex-m0-peripherals/optional-system-timer--systick/systick-control-and-status-register
pub fn init() SystickError!void {
    if (microzig.cpu.using_ram_vector_table) {
        microzig.cpu.ram_vector_table.SysTick = .{ .c = SysTick_handler };
    } else {
        const vector_table: *microzig.cpu.VectorTable = @ptrFromInt(0x0);
        // SysTick_Handler need to be setup in the interrupt table
        std.debug.assert(vector_table.SysTick.* == @intFromPtr(&SysTick_handler));
    }

    const use_processor_clk = if (hal.get_sys_clk() > hal.get_systick_clk()) false else true;
    const sys_freq = if (use_processor_clk) hal.get_sys_clk() else hal.get_systick_clk();

    const scale = 1_024_000_000 / sys_freq;
    if (scale > 1024) {
        // We need a clock source that is at least capable of us resolution (>1Mhz)
        return SystickError.ClkUnderflow;
    }

    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    systick.CTRL.raw = 0;
    ns_per_ticks = scale;
    wraps = 0;
    systick.LOAD.write(.{ .RELOAD = 0xFFFFFF });
    systick.VAL.raw = 0;
    systick.CTRL.write(.{
        .COUNTFLAG = 0,
        .CLKSOURCE = @intFromBool(use_processor_clk),
        .TICKINT = 1,
        .ENABLE = 1,
    });
}

pub fn deinit() void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    systick.CTRL.raw = 0;
    systick.LOAD.raw = 0;
    systick.VAL.raw = 0;
    ns_per_ticks = 0;
    wraps = 0;
}

pub fn is_initialized() bool {
    return ns_per_ticks > 0;
}

// Low level function to build clock device from it.
pub fn get_time_since_boot() u64 {
    const ticks, const scale = blk: {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        break :blk .{ sample_ticks(systick, &wraps), ns_per_ticks };
    };
    return (ticks * scale) >> 10;
}

// Armv7-M Cortex-M3 PM0056 §4.5 and Armv8-M Cortex-M33 100235,
// "System timer (SysTick)". The 1-to-0 transition sets COUNTFLAG and
// requests the exception. Exception entry can lag the reload or occur
// before the handler runs. Both callers consume the read-to-clear flag
// with interrupts masked, so a pending (or preempted) handler counts it
// only if the getter has not. At least one caller must run per period.
fn record_wrap(timer: anytype, count: *u32) bool {
    if (timer.CTRL.read().COUNTFLAG == 0) return false;
    count.* +%= 1;
    return true;
}

fn sample_ticks(timer: anytype, count: *u32) u64 {
    const period = @as(u32, timer.LOAD.read().RELOAD) + 1;
    while (true) {
        const current = timer.VAL.read().CURRENT;
        // A wrap could occur between reading VAL and consuming COUNTFLAG.
        // Discard VAL when we discover a wrap, then sample the new cycle.
        if (record_wrap(timer, count)) continue;
        const elapsed = if (current == 0) 0 else period - current;
        return @as(u64, count.*) * period + elapsed;
    }
}

pub fn SysTick_handler() callconv(.c) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    _ = record_wrap(systick, &wraps);
}

test "SysTick samples remain monotonic when a wrap precedes the handler" {
    const Load = struct {
        fn read(_: @This()) struct { RELOAD: u24 } {
            return .{ .RELOAD = 7 };
        }
    };
    const Value = struct {
        values: []const u24,

        fn read(self: *@This()) struct { CURRENT: u24 } {
            const value = self.values[0];
            self.values = self.values[1..];
            return .{ .CURRENT = value };
        }
    };
    const Control = struct {
        flags: []const u1,

        fn read(self: *@This()) struct { COUNTFLAG: u1 } {
            const flag = self.flags[0];
            self.flags = self.flags[1..];
            return .{ .COUNTFLAG = flag };
        }
    };
    var timer: struct { LOAD: Load, VAL: Value, CTRL: Control } = .{
        .LOAD = .{},
        .VAL = .{ .values = &.{ 1, 1, 0, 7, 5 } },
        .CTRL = .{ .flags = &.{ 0, 1, 0, 0, 0, 0 } },
    };
    var count: u32 = 0;
    try std.testing.expectEqual(@as(u64, 7), sample_ticks(&timer, &count));
    try std.testing.expectEqual(@as(u64, 8), sample_ticks(&timer, &count));
    try std.testing.expectEqual(@as(u64, 9), sample_ticks(&timer, &count));
    try std.testing.expect(!record_wrap(&timer, &count));
    try std.testing.expectEqual(@as(u64, 11), sample_ticks(&timer, &count));
}

/// A polled peripheral uses elapsed microseconds when its clock advances.
/// The finite fallback bounds waits even before clock initialization or if it stalls.
pub const PollDeadline = struct {
    // A software watchdog budget, independent of the peripheral's bus rate.
    const max_stalled_polls = 1_000_000;

    started: u64,
    latest: u64,
    duration_us: u64,
    stalled_polls_left: u32 = max_stalled_polls,

    pub fn init(now_us: u64, duration_us: u64) PollDeadline {
        return .{ .started = now_us, .latest = now_us, .duration_us = duration_us };
    }

    pub fn expired(self: *PollDeadline, now_us: u64) bool {
        if (now_us > self.latest) {
            self.latest = now_us;
            self.stalled_polls_left = max_stalled_polls;
        } else {
            self.stalled_polls_left -|= 1;
        }
        return self.latest - self.started >= self.duration_us or self.stalled_polls_left == 0;
    }
};

test "poll deadline bounds running and stalled clocks" {
    var running = PollDeadline.init(100, 10);
    try std.testing.expect(!running.expired(109));
    try std.testing.expect(running.expired(110));

    var stalled = PollDeadline.init(0, 100);
    stalled.stalled_polls_left = 2;
    try std.testing.expect(!stalled.expired(0));
    try std.testing.expect(stalled.expired(0));
}
