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
var mutex: rtos.Mutex = .{};
var timer_list: std.SinglyLinkedList = .{};

const CoexDeadlines = @import("coex_timer_wait.zig").Deadlines;
const coex_enabled = @import("../radio.zig").coex_enabled;
const host_test = @import("callback_context.zig").host_test;

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

    reload_semaphore.give();
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
            tim.deadline = .init_relative(get_time_since_boot(), duration);
            tim.periodic = if (repeat) duration else null;
        } else {
            log.warn("arm: timer not found based on ets_timer", .{});
        }
    }

    reload_semaphore.give();
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

fn task_fn() void {
    while (true) {
        if (exit_flag.load(.monotonic))
            return;

        const now = get_time_since_boot();
        while (true) {
            const callback, const arg = blk: {
                mutex.lock();
                defer mutex.unlock();

                const tim = find_expired(now) orelse break;
                if (tim.periodic) |period| {
                    tim.deadline = .init_relative(now, if (coex_enabled and period.to_us() == 0) time.Duration.from_us(1) else period);
                } else {
                    tim.deadline = .no_deadline;
                }
                break :blk .{ tim.callback, tim.arg };
            };

            const scope = @import("callback_context.zig").Scope.enter();
            defer scope.leave();
            callback(arg);
        }

        if (coex_enabled) {
            const next = coex_deadlines();
            next.wait(&reload_semaphore, get_time_since_boot().to_us(), rtos.Duration.us_per_tick);
            continue;
        }

        const timeout: rtos.Timeout = blk: {
            mutex.lock();
            defer mutex.unlock();
            break :blk if (find_next_wake_absolute()) |next_wake_absolute|
                .{ .after = .from_us(@truncate(next_wake_absolute.diff(now).to_us())) }
            else
                .never;
        };

        reload_semaphore.take_with_timeout(timeout) catch {};
    }
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
        if (timer.deadline.is_reached_by(now)) {
            return timer;
        }
    }
    return null;
}

fn coex_deadlines() CoexDeadlines {
    mutex.lock();
    defer mutex.unlock();
    var next: CoexDeadlines = .{};
    var it = timer_list.first;
    while (it) |node| : (it = node.next) {
        const tim: *Timer = @alignCast(@fieldParentPtr("node", node));
        if (tim.deadline.can_be_reached())
            next.include(tim.deadline.timeout.to_us(), tim.periodic != null);
    }
    return next;
}

fn find_next_wake_absolute() ?time.Absolute {
    var it = timer_list.first;
    var min_deadline: time.Deadline = .no_deadline;
    while (it) |node| : (it = node.next) {
        const timer: *Timer = @alignCast(@fieldParentPtr("node", node));
        if (@backingInt(timer.deadline.timeout) < @backingInt(min_deadline.timeout)) {
            min_deadline = timer.deadline;
        }
    }
    return if (min_deadline.can_be_reached()) min_deadline.timeout else null;
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
