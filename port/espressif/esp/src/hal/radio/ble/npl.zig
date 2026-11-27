//! NimBLE NPL v5.5.1 ABI backed by hal.rtos. NPL time units are milliseconds.
//! Blob objects contain one opaque pointer, as in nimble_npl_os.h.
const std = @import("std");
const microzig = @import("microzig");
const rtos = @import("../../rtos.zig");
const time = @import("../../time.zig");
const cs_enter = microzig.interrupt.enter_critical_section;
const Handle = extern struct { ptr: ?*anyopaque };
const Callback = *const fn (*Handle) callconv(.c) void;
const Event = struct {
    callback: Callback,
    arg: ?*anyopaque,
    handle: *Handle,
    next: ?*Event = null,
    queue: ?*EventQueue = null,
    allocation_next: ?*Event = null,
};
const EventQueue = struct {
    head: ?*Event = null,
    tail: ?*Event = null,
    wake: rtos.Semaphore = .init(0, 1),
};
const Callout = struct {
    handle: *Handle,
    event: Handle,
    queue: ?*Handle,
    deadline: ?u32 = null,
    next: ?*Callout = null,
    running: bool = false,
    destroy_pending: bool = false,
};
const Mutex = struct {
    base: rtos.Mutex = .{},
    owner: ?*rtos.Task = null,
    depth: u32 = 0,
};

/// Kept at a stable address by the controller for its entire boot lifetime.
/// All NPL allocations use the allocator explicitly passed to start().
pub const State = struct {
    allocator: std.mem.Allocator,
    callouts: ?*Callout = null,
    events: ?*Event = null,

    pub fn start(self: *State) std.mem.Allocator.Error!void {
        active = self;
        _ = try rtos.spawn(self.allocator, service, .{self}, .{
            .name = "ble_callout",
            .priority = if (@import("../../radio.zig").coex_enabled) @import("../timer.zig").coex_task_priority() else .lowest,
            .stack_size = 2048,
        });
    }
};
// The controller blob is a process-wide singleton; only ABI trampolines use this.
var active: *State = undefined;
fn alloc(comptime T: type) *T {
    return active.allocator.create(T) catch @panic("BLE NPL allocation failed");
}
fn object(comptime T: type, h: *Handle) *T {
    return @ptrCast(@alignCast(h.ptr orelse @panic("BLE NPL object not initialized")));
}
fn timeout(ms: u32) rtos.Timeout {
    return switch (ms) {
        0 => .non_blocking,
        0xffffffff => .never,
        else => .{ .after = .from_ms(@min(ms, 4_000_000)) },
    };
}
fn started() callconv(.c) bool {
    return true;
}
fn current_task() callconv(.c) ?*anyopaque {
    return rtos.get_current_task();
}
fn eventq_init(h: *Handle) callconv(.c) void {
    const q = alloc(EventQueue);
    q.* = .{};
    h.ptr = q;
}
fn eventq_deinit(h: *Handle) callconv(.c) void {
    const q = object(EventQueue, h);
    const cs = cs_enter();
    defer cs.leave();
    while (q.head) |ev| {
        q.head = ev.next;
        ev.queue = null;
        ev.next = null;
    }
    active.allocator.destroy(q);
    h.ptr = null;
}
fn eventq_get(h: *Handle, ms: u32) callconv(.c) ?*Handle {
    const q = object(EventQueue, h);
    const deadline = rtos.ResolvedTimeout.init(timeout(ms));
    while (true) {
        {
            const cs = cs_enter();
            defer cs.leave();
            if (q.head) |ev| {
                q.head = ev.next;
                if (q.head == null) q.tail = null;
                ev.next = null;
                ev.queue = null;
                return ev.handle;
            }
        }
        const remaining = deadline.tick() catch return null;
        q.wake.take_with_timeout(if (remaining) |d| .{ .after = d } else .never) catch return null;
    }
}
fn put(h: *Handle, eh: *Handle, front: bool) void {
    const q = object(EventQueue, h);
    const ev = object(Event, eh);
    const cs = cs_enter();
    defer cs.leave();
    if (ev.queue != null) return;
    ev.queue = q;
    if (front) {
        ev.next = q.head;
        q.head = ev;
        if (q.tail == null) q.tail = ev;
    } else {
        ev.next = null;
        if (q.tail) |tail| tail.next = ev else q.head = ev;
        q.tail = ev;
    }
    var hptw = false;
    q.wake.give_from_isr(&hptw);
    if (hptw) rtos.yield_from_isr();
}
fn eventq_put(h: *Handle, ev: *Handle) callconv(.c) void {
    put(h, ev, false);
}
fn eventq_front(h: *Handle, ev: *Handle) callconv(.c) void {
    put(h, ev, true);
}
fn eventq_remove(h: *Handle, eh: *Handle) callconv(.c) void {
    const q = object(EventQueue, h);
    const ev = object(Event, eh);
    const cs = cs_enter();
    defer cs.leave();
    if (ev.queue != q) return;
    var prev: ?*Event = null;
    var it = &q.head;
    while (it.*) |item| {
        if (item == ev) {
            it.* = ev.next;
            if (q.tail == ev) q.tail = prev;
            ev.next = null;
            ev.queue = null;
            return;
        }
        prev = item;
        it = &item.next;
    }
}
fn event_run(h: *Handle) callconv(.c) void {
    object(Event, h).callback(h);
}
fn eventq_empty(h: *Handle) callconv(.c) bool {
    const cs = cs_enter();
    defer cs.leave();
    return object(EventQueue, h).head == null;
}
fn event_init(h: *Handle, callback: Callback, arg: ?*anyopaque) callconv(.c) void {
    // The blob can initialize an event again, and can pass uninitialized
    // storage. Test ownership by the handle address, never its old contents.
    const cs = cs_enter();
    defer cs.leave();
    var it = active.events;
    while (it) |ev| : (it = ev.allocation_next) {
        if (ev.handle != h) continue;
        event_reset(h);
        ev.callback = callback;
        ev.arg = arg;
        return;
    }
    const ev = alloc(Event);
    install_event(ev, h, callback, arg);
}
fn install_event(ev: *Event, h: *Handle, callback: Callback, arg: ?*anyopaque) void {
    ev.* = .{ .callback = callback, .arg = arg, .handle = h, .allocation_next = active.events };
    active.events = ev;
    h.ptr = ev;
}
fn event_deinit(h: *Handle) callconv(.c) void {
    if (h.ptr == null) return;
    const cs = cs_enter();
    defer cs.leave();
    event_reset(h);
    const ev = object(Event, h);
    var it = &active.events;
    while (it.*) |item| {
        if (item == ev) {
            it.* = item.allocation_next;
            break;
        }
        it = &item.allocation_next;
    }
    active.allocator.destroy(ev);
    h.ptr = null;
}
fn event_reset(h: *Handle) callconv(.c) void {
    const cs = cs_enter();
    defer cs.leave();
    const ev = object(Event, h);
    if (ev.queue) |q| {
        var qh: Handle = .{ .ptr = q };
        eventq_remove(&qh, h);
    }
}
fn event_queued(h: *Handle) callconv(.c) bool {
    const cs = cs_enter();
    defer cs.leave();
    return object(Event, h).queue != null;
}
fn event_arg(h: *Handle) callconv(.c) ?*anyopaque {
    const cs = cs_enter();
    defer cs.leave();
    return object(Event, h).arg;
}
fn event_set_arg(h: *Handle, arg: ?*anyopaque) callconv(.c) void {
    const cs = cs_enter();
    defer cs.leave();
    object(Event, h).arg = arg;
}
fn mutex_init(h: *Handle) callconv(.c) c_int {
    const m = active.allocator.create(Mutex) catch return 1;
    m.* = .{};
    h.ptr = m;
    return 0;
}
fn mutex_deinit(h: *Handle) callconv(.c) c_int {
    active.allocator.destroy(object(Mutex, h));
    h.ptr = null;
    return 0;
}
fn mutex_pend(h: *Handle, ms: u32) callconv(.c) c_int {
    const m = object(Mutex, h);
    const task = rtos.get_current_task();
    {
        const cs = cs_enter();
        defer cs.leave();
        if (m.owner == task) {
            m.depth += 1;
            return 0;
        }
    }
    m.base.lock_with_timeout(timeout(ms)) catch return 6;
    const cs = cs_enter();
    defer cs.leave();
    m.owner = task;
    m.depth = 1;
    return 0;
}
fn mutex_release(h: *Handle) callconv(.c) c_int {
    const m = object(Mutex, h);
    const cs = cs_enter();
    defer cs.leave();
    if (m.owner != rtos.get_current_task() or m.depth == 0) return 5;
    m.depth -= 1;
    if (m.depth == 0) {
        m.owner = null;
        m.base.unlock();
    }
    return 0;
}
fn sem_init(h: *Handle, n: u16) callconv(.c) c_int {
    const s = active.allocator.create(rtos.Semaphore) catch return 1;
    s.* = .init(n, 65535);
    h.ptr = s;
    return 0;
}
fn sem_deinit(h: *Handle) callconv(.c) c_int {
    active.allocator.destroy(object(rtos.Semaphore, h));
    h.ptr = null;
    return 0;
}
fn sem_pend(h: *Handle, ms: u32) callconv(.c) c_int {
    object(rtos.Semaphore, h).take_with_timeout(timeout(ms)) catch return 6;
    return 0;
}
fn sem_release(h: *Handle) callconv(.c) c_int {
    var hptw = false;
    object(rtos.Semaphore, h).give_from_isr(&hptw);
    if (hptw) rtos.yield_from_isr();
    return 0;
}
fn sem_count(h: *Handle) callconv(.c) u16 {
    const cs = cs_enter();
    defer cs.leave();
    return @intCast(object(rtos.Semaphore, h).current_value);
}
fn callout_init(h: *Handle, q: ?*Handle, cb: Callback, arg: ?*anyopaque) callconv(.c) c_int {
    const cs = cs_enter();
    defer cs.leave();
    var it = active.callouts;
    while (it) |co| : (it = co.next) {
        if (co.handle != h) continue;
        co.queue = q;
        event_init(&co.event, cb, arg);
        return 0;
    }
    const co = active.allocator.create(Callout) catch return 1;
    co.* = .{ .handle = h, .event = .{ .ptr = null }, .queue = q };
    if (@import("../../radio.zig").coex_enabled) {
        // callout_init can report BLE_NPL_ENOMEM even if its nested event
        // allocation fails. Neither handle is published until both exist.
        const ev = active.allocator.create(Event) catch {
            active.allocator.destroy(co);
            return 1;
        };
        install_event(ev, &co.event, cb, arg);
    } else event_init(&co.event, cb, arg);
    co.next = active.callouts;
    active.callouts = co;
    h.ptr = co;
    return 0;
}
fn callout_reset(h: *Handle, ms: u32) callconv(.c) c_int {
    if (ms > 0x7fffffff) return 3;
    const cs = cs_enter();
    defer cs.leave();
    object(Callout, h).deadline = time_get() +% @max(ms, 1);
    return 0;
}
fn callout_stop(h: *Handle) callconv(.c) void {
    const cs = cs_enter();
    defer cs.leave();
    if (h.ptr == null) return; // IDF permits stop on a zeroed callout.
    const co = object(Callout, h);
    co.deadline = null;
    event_reset(&co.event);
}
fn callout_deinit(h: *Handle) callconv(.c) void {
    if (h.ptr == null) return;
    const cs = cs_enter();
    defer cs.leave();
    const co = object(Callout, h);
    callout_stop(h);
    var it = &active.callouts;
    while (it.*) |item| {
        if (item == co) {
            it.* = item.next;
            break;
        }
        it = &item.next;
    }
    h.ptr = null;
    if (co.running) {
        co.destroy_pending = true;
    } else {
        event_deinit(&co.event);
        active.allocator.destroy(co);
    }
}
fn callout_mem_reset(h: *Handle) callconv(.c) void {
    event_reset(&object(Callout, h).event);
}
fn callout_active(h: *Handle) callconv(.c) bool {
    const cs = cs_enter();
    defer cs.leave();
    return object(Callout, h).deadline != null;
}
fn callout_ticks(h: *Handle) callconv(.c) u32 {
    const cs = cs_enter();
    defer cs.leave();
    return object(Callout, h).deadline orelse 0;
}
fn callout_remaining(h: *Handle, now: u32) callconv(.c) u32 {
    const cs = cs_enter();
    defer cs.leave();
    const end = object(Callout, h).deadline orelse return 0;
    const delta: i32 = @bitCast(end -% now);
    return if (delta > 0) @intCast(delta) else 0;
}
fn callout_arg(h: *Handle, arg: ?*anyopaque) callconv(.c) void {
    event_set_arg(&object(Callout, h).event, arg);
}
fn time_get() callconv(.c) u32 {
    return @truncate(time.get_time_since_boot().to_us() / 1000);
}
fn time_convert(n: u32, out: *u32) callconv(.c) c_int {
    out.* = n;
    return 0;
}
fn time_identity(n: u32) callconv(.c) u32 {
    return n;
}
fn time_delay(ms: u32) callconv(.c) void {
    rtos.sleep(.from_ms(@min(ms, 4_000_000)));
}
fn critical_enter() callconv(.c) u32 {
    const enabled = microzig.cpu.interrupt.globally_enabled();
    microzig.cpu.interrupt.disable_interrupts();
    return @intFromBool(enabled);
}
fn critical_exit(enabled: u32) callconv(.c) void {
    if (enabled != 0) microzig.cpu.interrupt.enable_interrupts();
}
fn time_forever() callconv(.c) u32 {
    return 0xffffffff;
}
fn in_critical() callconv(.c) u8 {
    return @intFromBool(!microzig.cpu.interrupt.globally_enabled());
}
// spawn can immediately preempt Controller.start. At a slow tick rate a
// millisecond rounds down to zero and the higher-priority worker stays ready.
pub inline fn wait_for_next_poll(comptime sleep: fn (rtos.Duration) void) void {
    sleep(if (@import("../../radio.zig").coex_enabled) .from_ticks(1) else .from_ms(1));
}

fn service(state: *State) void {
    while (true) {
        // Select one expired callout at a time. Queue insertion is done with the
        // same IRQ mask as stop/deinit, so cancellation cannot free it under us.
        while (true) {
            const direct = blk: {
                const cs = cs_enter();
                defer cs.leave();
                var it = state.callouts;
                while (it) |co| : (it = co.next) {
                    const end = co.deadline orelse continue;
                    if (@as(i32, @bitCast(time_get() -% end)) < 0) continue;
                    co.deadline = null;
                    if (co.queue) |q| {
                        eventq_put(q, &co.event);
                        break :blk @as(?*Callout, null);
                    }
                    co.running = true;
                    break :blk @as(?*Callout, co);
                }
                break;
            };
            if (direct) |co| {
                event_run(&co.event);
                const cs = cs_enter();
                defer cs.leave();
                co.running = false;
                if (co.destroy_pending) {
                    event_deinit(&co.event);
                    active.allocator.destroy(co);
                }
            }
        }
        wait_for_next_poll(rtos.sleep);
    }
}

// ESP-IDF v5.5.1 nimble_npl_os.h, struct npl_funcs_t (45 pointers).
pub const Funcs = extern struct {
    p_ble_npl_os_started: @TypeOf(&started) = &started,
    p_ble_npl_get_current_task_id: @TypeOf(&current_task) = &current_task,
    p_ble_npl_eventq_init: @TypeOf(&eventq_init) = &eventq_init,
    p_ble_npl_eventq_deinit: @TypeOf(&eventq_deinit) = &eventq_deinit,
    p_ble_npl_eventq_get: @TypeOf(&eventq_get) = &eventq_get,
    p_ble_npl_eventq_put: @TypeOf(&eventq_put) = &eventq_put,
    p_ble_npl_eventq_remove: @TypeOf(&eventq_remove) = &eventq_remove,
    p_ble_npl_event_run: @TypeOf(&event_run) = &event_run,
    p_ble_npl_eventq_is_empty: @TypeOf(&eventq_empty) = &eventq_empty,
    p_ble_npl_event_init: @TypeOf(&event_init) = &event_init,
    p_ble_npl_event_deinit: @TypeOf(&event_deinit) = &event_deinit,
    p_ble_npl_event_reset: @TypeOf(&event_reset) = &event_reset,
    p_ble_npl_event_is_queued: @TypeOf(&event_queued) = &event_queued,
    p_ble_npl_event_get_arg: @TypeOf(&event_arg) = &event_arg,
    p_ble_npl_event_set_arg: @TypeOf(&event_set_arg) = &event_set_arg,
    p_ble_npl_mutex_init: @TypeOf(&mutex_init) = &mutex_init,
    p_ble_npl_mutex_deinit: @TypeOf(&mutex_deinit) = &mutex_deinit,
    p_ble_npl_mutex_pend: @TypeOf(&mutex_pend) = &mutex_pend,
    p_ble_npl_mutex_release: @TypeOf(&mutex_release) = &mutex_release,
    p_ble_npl_sem_init: @TypeOf(&sem_init) = &sem_init,
    p_ble_npl_sem_deinit: @TypeOf(&sem_deinit) = &sem_deinit,
    p_ble_npl_sem_pend: @TypeOf(&sem_pend) = &sem_pend,
    p_ble_npl_sem_release: @TypeOf(&sem_release) = &sem_release,
    p_ble_npl_sem_get_count: @TypeOf(&sem_count) = &sem_count,
    p_ble_npl_callout_init: @TypeOf(&callout_init) = &callout_init,
    p_ble_npl_callout_reset: @TypeOf(&callout_reset) = &callout_reset,
    p_ble_npl_callout_stop: @TypeOf(&callout_stop) = &callout_stop,
    p_ble_npl_callout_deinit: @TypeOf(&callout_deinit) = &callout_deinit,
    p_ble_npl_callout_mem_reset: @TypeOf(&callout_mem_reset) = &callout_mem_reset,
    p_ble_npl_callout_is_active: @TypeOf(&callout_active) = &callout_active,
    p_ble_npl_callout_get_ticks: @TypeOf(&callout_ticks) = &callout_ticks,
    p_ble_npl_callout_remaining_ticks: @TypeOf(&callout_remaining) = &callout_remaining,
    p_ble_npl_callout_set_arg: @TypeOf(&callout_arg) = &callout_arg,
    p_ble_npl_time_get: @TypeOf(&time_get) = &time_get,
    p_ble_npl_time_ms_to_ticks: @TypeOf(&time_convert) = &time_convert,
    p_ble_npl_time_ticks_to_ms: @TypeOf(&time_convert) = &time_convert,
    p_ble_npl_time_ms_to_ticks32: @TypeOf(&time_identity) = &time_identity,
    p_ble_npl_time_ticks_to_ms32: @TypeOf(&time_identity) = &time_identity,
    p_ble_npl_time_delay: @TypeOf(&time_delay) = &time_delay,
    p_ble_npl_hw_set_isr: ?*const fn (c_int, u32) callconv(.c) void = null,
    p_ble_npl_hw_enter_critical: @TypeOf(&critical_enter) = &critical_enter,
    p_ble_npl_hw_exit_critical: @TypeOf(&critical_exit) = &critical_exit,
    p_ble_npl_get_time_forever: @TypeOf(&time_forever) = &time_forever,
    p_ble_npl_hw_is_in_critical: @TypeOf(&in_critical) = &in_critical,
    p_ble_npl_eventq_put_to_front: @TypeOf(&eventq_front) = &eventq_front,
};
pub const funcs: Funcs = .{};

test "callout init returns ENOMEM and can retry after its event allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var state: State = .{ .allocator = failing.allocator() };
    const previous_context = active;
    active = &state;
    defer active = previous_context;
    var handle: Handle = .{ .ptr = null };
    const cb = struct {
        fn run(_: *Handle) callconv(.c) void {}
    }.run;
    try std.testing.expectEqual(1, callout_init(&handle, null, cb, null));
    try std.testing.expect(handle.ptr == null and state.callouts == null and state.events == null);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(0, callout_init(&handle, null, cb, null));
    callout_deinit(&handle);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}
