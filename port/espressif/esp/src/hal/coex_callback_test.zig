//! Host probe for the C6 adapter entry points. Count even debug diagnostics.
const std = @import("std");
const host = @import("microzig");
const osi = @import("radio/osi.zig");
const coex = @import("radio/coex.zig");

var diagnostics: usize = 0;
var expected_panic: []const u8 = "";

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = count_log };
fn count_log(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {
    diagnostics += 1;
}

pub const panic = std.debug.FullPanic(check_panic);
fn check_panic(message: []const u8, _: ?usize) noreturn {
    std.process.exit(if (expected_panic.len != 0 and std.mem.eql(u8, message, expected_panic)) 0 else 1);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (std.mem.eql(u8, args[1], "take")) {
        expected_panic = "coex semphr_take requires task context";
        _ = coex.SemaphoreSlots.take(null, std.math.maxInt(u32));
        return error.MissingTaskContextPanic;
    }
    if (std.mem.eql(u8, args[1], "give")) {
        expected_panic = "coex semphr_give requires task context";
        _ = coex.SemaphoreSlots.give(null);
        return error.MissingTaskContextPanic;
    }

    // The adapter's TimerSlots forward to the radio timer, which this host
    // build cannot link; the guard is the same with a target that must not run.
    const Timers = coex.TimerCallbacks(@import("rtos.zig"), struct {
        fn reached() noreturn {
            std.process.exit(2);
        }
        pub fn disarm(_: ?*anyopaque) void {
            reached();
        }
        pub fn done(_: ?*anyopaque) void {
            reached();
        }
        pub fn setfn(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) void {
            reached();
        }
        pub fn arm_us(_: ?*anyopaque, _: u32, _: bool) void {
            reached();
        }
    });
    if (std.mem.eql(u8, args[1], "timer_disarm")) {
        expected_panic = "coex timer_disarm requires task context";
        Timers.disarm(null);
    } else if (std.mem.eql(u8, args[1], "timer_done")) {
        expected_panic = "coex timer_done requires task context";
        Timers.done(null);
    } else if (std.mem.eql(u8, args[1], "timer_setfn")) {
        expected_panic = "coex timer_setfn requires task context";
        Timers.setfn(null, null, null);
    } else if (std.mem.eql(u8, args[1], "timer_arm_us")) {
        expected_panic = "coex timer_arm_us requires task context";
        Timers.arm_us(null, 1000, false);
    }
    if (expected_panic.len != 0) return error.MissingTaskContextPanic;

    std.log.scoped(.esp_radio_osi).debug("verify diagnostic counter", .{});
    if (diagnostics != 1) return error.DisabledDiagnosticCounter;
    diagnostics = 0;

    const ble = @import("radio/bluetooth.zig").coex_funcs;
    ble.set(1, 7);
    ble.clear(1, 2);
    osi.task_yield_from_isr();
    if (host.bitmap != 5 or host.yield_requests != 1 or diagnostics != 0)
        return error.UnexpectedCallbackEffect;

    if (Duration.us_per_tick != 10_000 or Scheduler.caller_resumes_after_spawn(Scheduler.millisecond_poll))
        return error.InvalidSlowTickControl;
    if (!Scheduler.caller_resumes_after_spawn(@import("radio/ble/npl.zig").wait_for_next_poll))
        return error.ControllerStartStarved;

    const priority = @import("radio/timer.zig").coex_task_priority();
    if (@backingInt(priority) != 16 - 3)
        return error.WrongTimerPriority;
}

// Model the first scheduling decisions inside npl_state.start at 100 Hz.
// Both tasks are ready at spawn. The higher-priority worker repeatedly finds
// no callouts. Controller.start resumes only while the worker is asleep.
const Duration = @import("rtos.zig").Duration;
const Scheduler = struct {
    var tick: u32 = 0;
    var wake_tick: u32 = 0;

    fn sleep(interval: Duration) void {
        wake_tick = tick + interval.to_ticks();
    }

    fn millisecond_poll(comptime sleep_fn: fn (Duration) void) void {
        sleep_fn(.from_ms(1));
    }

    fn caller_resumes_after_spawn(comptime wait_for_poll: anytype) bool {
        wake_tick = 0;
        tick = 0;
        while (tick < 4) : (tick += 1) {
            for (0..8) |_| {
                if (wake_tick > tick) return true; // dispatch the ready controller caller
                wait_for_poll(sleep);
            }
        }
        return false;
    }
};
