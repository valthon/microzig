const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const c = @import("esp-wifi-driver");
const microzig = @import("microzig");
const time = microzig.drivers.time;

const rtos = @import("../rtos.zig");
const get_time_since_boot = @import("../time.zig").get_time_since_boot;

const log = std.log.scoped(.esp_radio_timer);

pub const CallbackFn = *const fn (?*anyopaque) callconv(.c) void;

pub const Timer = struct {
    ets_timer: *c.ets_timer,
    callback: CallbackFn,
    arg: ?*anyopaque,
    deadline: time.Deadline,
    periodic: ?time.Duration,
    dispatched: bool = false,
    node: std.SinglyLinkedList.Node = .{},
};

// One allocator backs the worker and every node on `timer_list`: the
// radio's. `radio.init` passes it to `init` and for the PHY and coex nodes;
// `radio.deinit` and the blob's `timer_setfn`/`timer_done` callbacks pass
// `osi.callback_allocator()`, which routes to it (the attached heap in a
// coexistence image, the first owner's allocator in a single-radio image).
var timer_task: ?*rtos.Task = null;
var exit_flag: std.atomic.Value(bool) = .init(false);
var reload_semaphore: rtos.Semaphore = .init(0, 1);
var mutex: if (host_test) microzig.radio_test.Mutex else rtos.Mutex = .{};
var timer_list: std.SinglyLinkedList = .{};

const Deadlines = @import("coex_timer_wait.zig").Deadlines;
const coex_enabled = @import("../radio.zig").coex_enabled;
const callback_context = @import("callback_context.zig");
const host_test = callback_context.host_test;

// IDF v5.5.1 esp_system/include/esp_task.h:46 runs the esp_timer task at MAX-3.
// NPL callouts use that task (bt/porting/npl/freertos/src/npl_os_freertos.c:656-668).
pub fn coex_task_priority() rtos.Priority {
    return @fromBackingInt(@max(1, @backingInt(rtos.Priority.highest) -| 2));
}

pub fn init(gpa: Allocator) Allocator.Error!void {
    exit_flag.store(false, .monotonic);

    assert(timer_task == null);
    timer_task = try rtos.spawn(gpa, task_fn, .{}, .{
        .name = "radio_timer",
        .priority = if (coex_enabled) coex_task_priority() else .lowest,
        .stack_size = 4096,
    });
}

pub fn deinit(gpa: Allocator) void {
    if (timer_task != null and timer_task == callback_context.current_task())
        @panic("radio timer worker cannot release its own final reference");

    // Host tests have no scheduler and start no worker (radio.zig's
    // HostResources stands in); they run only the drain below.
    if (!host_test) {
        exit_flag.store(true, .monotonic);
        reload_semaphore.give();

        if (timer_task) |task| {
            rtos.wait_and_free(gpa, task);
            timer_task = null;
        }
    }

    while (timer_list.popFirst()) |node| {
        const timer: *Timer = @alignCast(@fieldParentPtr("node", node));
        gpa.destroy(timer);
    }
}

pub fn setfn(
    gpa: std.mem.Allocator,
    ets_timer: *c.ets_timer,
    callback: CallbackFn,
    arg: ?*anyopaque,
) !void {
    {
        mutex.lock();
        defer mutex.unlock();

        if (find(ets_timer)) |tim| {
            tim.callback = callback;
            tim.arg = arg;
            tim.deadline = .no_deadline;
        } else {
            const timer = try gpa.create(Timer);
            insert(timer, ets_timer, callback, arg);
        }
    }

    if (!host_test) reload_semaphore.give();
}

pub fn setfn_reserved(node: *Timer, ets_timer: *c.ets_timer, callback: CallbackFn, arg: ?*anyopaque) void {
    mutex.lock();
    defer mutex.unlock();
    // Pre-init runs once per timer worker. The new timer is disarmed.
    insert(node, ets_timer, callback, arg);
}

/// Host tests: put `node` on the list as `setfn_reserved` does, without its
/// lock, which needs the scheduler. The new timer is disarmed.
pub fn insert_for_test(node: *Timer, ets_timer: *c.ets_timer) void {
    comptime assert(host_test);
    insert(node, ets_timer, undefined, null);
}

inline fn insert(timer: *Timer, ets_timer: *c.ets_timer, callback: CallbackFn, arg: ?*anyopaque) void {
    timer.* = .{
        .ets_timer = ets_timer,
        .callback = callback,
        .arg = arg,
        .deadline = .no_deadline,
        .periodic = null,
    };
    timer_list.prepend(&timer.node);
}

pub fn arm(
    ets_timer: *c.ets_timer,
    duration: time.Duration,
    repeat: bool,
) void {
    {
        mutex.lock();
        defer mutex.unlock();

        if (find(ets_timer)) |tim| {
            const now: time.Absolute = if (host_test) .from_us(0) else get_time_since_boot();
            const interval: time.Duration = if (repeat) .from_us(@max(duration.to_us(), 1)) else duration;
            tim.deadline = .init_relative(now, interval);
            tim.periodic = if (repeat) interval else null;
        } else {
            log.warn("arm: timer not found based on ets_timer", .{});
        }
    }

    if (!host_test) reload_semaphore.give();
}

pub fn disarm(ets_timer: *c.ets_timer) void {
    mutex.lock();
    defer mutex.unlock();

    if (find(ets_timer)) |tim| {
        tim.deadline = .no_deadline;
    } else {
        log.warn("disarm: timer not found based on ets_timer", .{});
    }
}

pub fn done(gpa: std.mem.Allocator, ets_timer: *c.ets_timer) void {
    mutex.lock();
    defer mutex.unlock();

    if (find(ets_timer)) |tim| {
        timer_list.remove(&tim.node);
        gpa.destroy(tim);
    } else {
        log.warn("done: timer not found based on ets_timer", .{});
    }
}

const WorkerWait = struct {
    pub fn sleep_one_tick(_: WorkerWait) void {
        rtos.sleep(.from_ticks(1));
    }

    pub fn take_with_timeout(_: WorkerWait, timeout: rtos.Timeout) rtos.TimeoutError!void {
        return reload_semaphore.take_with_timeout(timeout);
    }
};

fn task_fn() void {
    while (!exit_flag.load(.monotonic))
        run_scan(get_time_since_boot, WorkerWait{}, rtos.Duration.us_per_tick);
}

fn run_scan(comptime clock: fn () time.Absolute, signal: anytype, us_per_tick: u32) void {
    // A callback can rearm its own timer. Keep it ineligible until the
    // next pass so other due timers get a turn before it runs again.
    {
        mutex.lock();
        defer mutex.unlock();
        var it = timer_list.first;
        while (it) |node| : (it = node.next) {
            const tim: *Timer = @alignCast(@fieldParentPtr("node", node));
            tim.dispatched = false;
        }
    }

    while (true) {
        const scan_time = clock();
        while (!exit_flag.load(.monotonic)) {
            const callback, const arg = take_expired(scan_time) orelse break;
            const scope = callback_context.Scope.enter();
            defer scope.leave();
            callback(arg);
        }
        if (exit_flag.load(.monotonic)) return;

        const next = deadlines();
        if (!next.wait(signal, clock().to_us(), us_per_tick)) return;
    }
}

fn take_expired(now: time.Absolute) ?struct { CallbackFn, ?*anyopaque } {
    mutex.lock();
    defer mutex.unlock();

    const tim = find_expired(now) orelse return null;
    tim.dispatched = true;
    if (tim.periodic) |period| {
        tim.deadline = .init_relative(now, period);
    } else {
        tim.deadline = .no_deadline;
    }
    return .{ tim.callback, tim.arg };
}

fn find(ets_timer: *c.ets_timer) ?*Timer {
    var it = timer_list.first;
    while (it) |node| : (it = node.next) {
        const timer: *Timer = @alignCast(@fieldParentPtr("node", node));
        if (timer.ets_timer == ets_timer) {
            return timer;
        }
    }
    return null;
}

fn find_expired(now: time.Absolute) ?*Timer {
    var it = timer_list.first;
    while (it) |node| : (it = node.next) {
        const timer: *Timer = @alignCast(@fieldParentPtr("node", node));
        if (!timer.dispatched and timer.deadline.is_reached_by(now)) {
            return timer;
        }
    }
    return null;
}

fn deadlines() Deadlines {
    mutex.lock();
    defer mutex.unlock();
    var next: Deadlines = .{};
    var it = timer_list.first;
    while (it) |node| : (it = node.next) {
        const tim: *Timer = @alignCast(@fieldParentPtr("node", node));
        if (tim.deadline.can_be_reached())
            next.include(tim.deadline.timeout.to_us(), tim.dispatched);
    }
    return next;
}

test "deinit returns every node to the allocator it is given" {
    var accounting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var keys: [3]c.ets_timer = undefined;
    for (&keys) |*key| {
        const node = try accounting.allocator().create(Timer);
        insert(node, key, undefined, null);
    }
    deinit(accounting.allocator());
    try std.testing.expect(timer_list.first == null);
    try std.testing.expect(accounting.allocations == 3 and accounting.allocated_bytes == accounting.freed_bytes);
}

test "timer arm preserves the full millisecond ABI range" {
    const osi = @import("osi.zig");
    const noop = struct {
        fn run(_: ?*anyopaque) callconv(.c) void {}
    }.run;
    const gpa = std.testing.allocator;
    defer deinit(gpa);
    var key: c.ets_timer = undefined;
    try setfn(gpa, &key, noop, null);
    const ms = std.math.maxInt(u32);
    osi.timer_arm(&key, ms, true);
    const node = find(&key).?;
    try std.testing.expectEqual(@as(u64, 4_294_967_295_000), node.deadline.timeout.to_us());
    try std.testing.expectEqual(node.deadline.timeout.to_us(), node.periodic.?.to_us());
}

test "timer setfn panics when allocation fails" {
    if (!@hasDecl(@import("root"), "stop_panic_runner")) return error.SkipZigTest;
    const noop = struct {
        fn run(_: ?*anyopaque) callconv(.c) void {}
    }.run;
    var route: @import("shared_heap.zig").TestRoute = .{};
    route.install(.failing);
    defer route.restore();
    var key: c.ets_timer = undefined;
    @import("osi.zig").timer_setfn(&key, @ptrCast(@constCast(&noop)), null);
}

test "a zero-period repeat advances past the current scan" {
    const noop = struct {
        fn run(_: ?*anyopaque) callconv(.c) void {}
    }.run;
    const gpa = std.testing.allocator;
    defer deinit(gpa);
    var key: c.ets_timer = undefined;
    try setfn(gpa, &key, noop, null);
    arm(&key, .from_us(0), true);
    try std.testing.expect(take_expired(.from_us(0)) == null);
    try std.testing.expect(take_expired(.from_us(1)) != null);
    try std.testing.expectEqual(2, find(&key).?.deadline.timeout.to_us());
}

const TestScheduler = struct {
    var now: u64 = 0;
    const tick_us = 1000;

    sleeps: usize = 0,
    waits: usize = 0,
    timeout: rtos.Timeout = .never,

    fn clock() time.Absolute {
        return .from_us(now);
    }

    pub fn sleep_one_tick(self: *@This()) void {
        self.sleeps += 1;
        now += tick_us;
    }

    pub fn take_with_timeout(self: *@This(), timeout: rtos.Timeout) rtos.TimeoutError!void {
        // Model a pending reload: a semaphore take alone would not block.
        self.waits += 1;
        self.timeout = timeout;
    }
};

test "timer worker rescans due one-shots and blocks between overdue repeats" {
    const Callbacks = struct {
        var count: usize = 0;
        fn slow_callback(_: ?*anyopaque) callconv(.c) void {
            count += 1;
            TestScheduler.now += 2 * TestScheduler.tick_us;
        }

        fn one_shot(_: ?*anyopaque) callconv(.c) void {
            count += 1;
        }
    };
    const Scheduler = TestScheduler;
    for ([_]u64{ 0, Scheduler.tick_us }) |period| {
        const gpa = std.testing.allocator;
        defer deinit(gpa);
        var repeat_key: c.ets_timer = undefined;
        var once_key: c.ets_timer = undefined;
        var scheduler: Scheduler = .{};
        Scheduler.now = 0;
        Callbacks.count = 0;

        try setfn(gpa, &repeat_key, Callbacks.slow_callback, null);
        arm(&repeat_key, .from_us(period), true);
        try setfn(gpa, &once_key, Callbacks.one_shot, null);
        arm(&once_key, .from_us(2 * Scheduler.tick_us), false);

        if (period == 0) {
            run_scan(Scheduler.clock, &scheduler, Scheduler.tick_us);
            try std.testing.expectEqual(1, scheduler.timeout.after.to_ticks());
            scheduler.waits = 0;
        }
        Scheduler.now = @max(period, 1);
        run_scan(Scheduler.clock, &scheduler, Scheduler.tick_us);
        // The one-shot became due during the repeat and must run before
        // sleeping. The repeat must not run again before that sleep.
        try std.testing.expectEqual(2, Callbacks.count);
        try std.testing.expectEqual(1, scheduler.sleeps);
        try std.testing.expectEqual(0, scheduler.waits);

        run_scan(Scheduler.clock, &scheduler, Scheduler.tick_us);
        try std.testing.expectEqual(3, Callbacks.count);
        try std.testing.expectEqual(2, scheduler.sleeps);
        try std.testing.expectEqual(0, scheduler.waits);
    }
}

fn check_repeat_after_one_shot(rearms: usize) !void {
    const Callbacks = struct {
        one_shot_key: c.ets_timer = undefined,
        rearms_left: usize,
        one_shot_runs: usize = 0,
        repeat_at: ?u64 = null,

        fn slow_one_shot(arg: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(arg.?));
            self.one_shot_runs += 1;
            if (self.rearms_left > 0) {
                self.rearms_left -= 1;
                // Host arm is relative to boot time zero. Make this arm
                // due after the current scan's clock sample.
                arm(&self.one_shot_key, .from_us(TestScheduler.now + 1), false);
            }
            TestScheduler.now += 2 * TestScheduler.tick_us;
        }

        fn repeat(arg: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(arg.?));
            self.repeat_at = TestScheduler.now;
        }
    };
    const gpa = std.testing.allocator;
    defer deinit(gpa);
    var callbacks: Callbacks = .{ .rearms_left = rearms };
    var repeat_key: c.ets_timer = undefined;
    try setfn(gpa, &repeat_key, Callbacks.repeat, &callbacks);
    arm(&repeat_key, .from_us(TestScheduler.tick_us), true);
    try setfn(gpa, &callbacks.one_shot_key, Callbacks.slow_one_shot, &callbacks);
    arm(&callbacks.one_shot_key, .from_us(0), false);
    var scheduler: TestScheduler = .{};
    TestScheduler.now = 0;

    run_scan(TestScheduler.clock, &scheduler, TestScheduler.tick_us);
    try std.testing.expectEqual(@as(?u64, 2 * TestScheduler.tick_us), callbacks.repeat_at);
    try std.testing.expectEqual(1, callbacks.one_shot_runs);
    try std.testing.expectEqual(@as(usize, @intFromBool(rearms > 0)), scheduler.sleeps);

    if (rearms > 0) {
        run_scan(TestScheduler.clock, &scheduler, TestScheduler.tick_us);
        try std.testing.expectEqual(@as(?u64, 5 * TestScheduler.tick_us), callbacks.repeat_at);
        try std.testing.expectEqual(2, callbacks.one_shot_runs);
        try std.testing.expectEqual(2, scheduler.sleeps);
    }
}

test "timer worker dispatches a repeat due during a slow one-shot before waiting" {
    try check_repeat_after_one_shot(0);
}

test "timer worker dispatches repeats alongside a self-rearming one-shot" {
    try check_repeat_after_one_shot(3);
}

test "timer worker stops between callbacks when exit is requested" {
    const Callbacks = struct {
        fn request_exit(_: ?*anyopaque) callconv(.c) void {
            exit_flag.store(true, .monotonic);
        }

        fn record(arg: ?*anyopaque) callconv(.c) void {
            const ran: *bool = @ptrCast(@alignCast(arg.?));
            ran.* = true;
        }
    };
    const gpa = std.testing.allocator;
    defer deinit(gpa);
    exit_flag.store(false, .monotonic);
    defer exit_flag.store(false, .monotonic);
    var later_ran = false;
    var later_key: c.ets_timer = undefined;
    var exit_key: c.ets_timer = undefined;
    try setfn(gpa, &later_key, Callbacks.record, &later_ran);
    arm(&later_key, .from_us(0), false);
    try setfn(gpa, &exit_key, Callbacks.request_exit, null);
    arm(&exit_key, .from_us(0), false);
    var scheduler: TestScheduler = .{};
    TestScheduler.now = 0;

    run_scan(TestScheduler.clock, &scheduler, TestScheduler.tick_us);
    try std.testing.expect(exit_flag.load(.monotonic));
    try std.testing.expect(!later_ran);
    try std.testing.expectEqual(0, scheduler.sleeps);
    try std.testing.expectEqual(0, scheduler.waits);
}

test "timer worker cannot release its own final reference" {
    if (!@hasDecl(@import("root"), "stop_panic_runner")) return error.SkipZigTest;
    timer_task = callback_context.current_task();
    defer timer_task = null;
    deinit(std.testing.allocator);
}
