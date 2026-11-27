//! C6 ABI from IDF v5.5.1 esp_coex/include/private/esp_coexist_adapter.h:16-52.
//! Declare the versioned interface here because esp-wifi-sys also ships older headers.
const std = @import("std");
const microzig = @import("microzig");
const timer = @import("timer.zig");
const abi = @import("coex_abi.zig");
const osi = @import("osi.zig");
const rtos = @import("../rtos.zig");

const Handle = ?*anyopaque;
const Adapter = abi.Adapter;

pub extern fn coex_status_get(bitmap: u8) u32;
pub extern fn coex_schm_get_phase_by_idx(index: c_int) ?*anyopaque;
extern fn esp_coex_adapter_register(*Adapter) c_int;
extern fn coex_pre_init() c_int;

pub const SemaphoreSlots = SemaphoreCallbacks(rtos, microzig.interrupt.enter_critical_section, osi.semphr_take);

const storage_callbacks = .{
    .semphr_create = create_semaphore,
    .semphr_delete = keep_semaphore,
    .malloc_internal = alloc_rom_funcs,
    .free = free_rom_funcs,
};

// esp_coex_adapter_register+0x5e saves this address in g_coa_funcs_p.
var adapter: Adapter = .{
    .task_yield_from_isr = osi.task_yield_from_isr,
    .semphr_create = storage_callbacks.semphr_create,
    .semphr_delete = storage_callbacks.semphr_delete,
    .semphr_take_from_isr = SemaphoreSlots.take_from_isr,
    .semphr_give_from_isr = SemaphoreSlots.give_from_isr,
    .semphr_take = SemaphoreSlots.take,
    .semphr_give = SemaphoreSlots.give,
    .is_in_isr = is_in_isr,
    .malloc_internal = storage_callbacks.malloc_internal,
    .free = storage_callbacks.free,
    .esp_timer_get_time = osi.esp_timer_get_time,
    .env_is_chip = osi.env_is_chip,
    .timer_disarm = TimerSlots.disarm,
    .timer_done = TimerSlots.done,
    .timer_setfn = TimerSlots.setfn,
    .timer_arm_us = TimerSlots.arm_us,
    .debug_matrix_init = debug_matrix,
    .xtal_freq_get = osi.rtc_clk_xtal_freq_get,
};

// IDF v5.5.1 C6 libcoexist.a: coex_core_pre_init+0x26..0x2a stores the
// core semaphore at coex_env+0, coex_schm_init+0x24..0x2c the scheme
// semaphore at coex_schm_env+0x10. coex_core_deinit+0..2 just returns.
var semaphores: [2]rtos.Semaphore = undefined;
var semaphore_count: usize = 0;
var startup: abi.Startup(timer.Timer) = .{};

// coex_rom_osi_funcs_init+0x30..0x48 skips malloc if coexist_funcs is
// already set. Its only allocation is 13 RV32 function pointers, populated
// at +0x82..0xfa. The table survives final radio.deinit and arena release.
const RomFuncs = [13]u32;
var rom_funcs: RomFuncs = undefined;
var rom_funcs_in_use = false;

fn alloc_rom_funcs(size: usize) callconv(.c) Handle {
    if (size != @sizeOf(RomFuncs) or rom_funcs_in_use) return null;
    rom_funcs_in_use = true;
    return &rom_funcs;
}

fn free_rom_funcs(ptr: Handle) callconv(.c) void {
    // coex_rom_osi_funcs_deinit+0x18..0x1c frees then clears coexist_funcs.
    if (ptr == null) return;
    if (ptr != @as(Handle, &rom_funcs) or !rom_funcs_in_use) @panic("coex freed memory its adapter did not allocate");
    rom_funcs_in_use = false;
}

fn create_semaphore(max: u32, initial: u32) callconv(.c) Handle {
    if (semaphore_count == semaphores.len) return null;
    const slot = &semaphores[semaphore_count];
    slot.* = .init(initial, max);
    semaphore_count += 1;
    return slot;
}

fn keep_semaphore(_: Handle) callconv(.c) void {
    // On scheme init failure the core calls delete but retries using the saved
    // handle. Its boot-lifetime slot must remain initialized and exclusive.
}

/// The timer slots take the task-owned timer mutex, so an interrupt entry
/// panics before logging or locking. In IDF v5.5.1 C6 libcoexist.a the only
/// slot loads are in coex_schm_change_phase (disarm +0x7e, arm +0xde), after
/// its call to coex_schm_lock at +0x14, which takes a task slot (+0x18);
/// coex_schm_deinit (done +0x10); and coex_schm_init (setfn +0x72), reached
/// only from coex_core_pre_init.
pub const TimerSlots = TimerCallbacks(rtos, struct {
    pub const disarm = osi.timer_disarm;
    pub const done = osi.timer_done;
    pub const arm_us = osi.timer_arm_us;

    // coex_schm_init+0x6a..0x7a passes the static key coex_schm_env+0x20
    // on every pre-init. Only timer_list holds the arena node, until timer.deinit.
    pub fn setfn(key: Handle, callback: Handle, arg: Handle) callconv(.c) void {
        timer.setfn_reserved(startup.take_timer(), @ptrCast(@alignCast(key)), @ptrCast(@alignCast(callback)), arg);
    }
});

pub fn TimerCallbacks(comptime Kernel: type, comptime Target: type) type {
    return struct {
        fn enter(comptime message: []const u8) void {
            if (Kernel.in_isr()) @panic(message);
        }

        pub fn disarm(key: Handle) callconv(.c) void {
            enter("coex timer_disarm requires task context");
            Target.disarm(key);
        }

        pub fn done(key: Handle) callconv(.c) void {
            enter("coex timer_done requires task context");
            Target.done(key);
        }

        pub fn setfn(key: Handle, callback: Handle, arg: Handle) callconv(.c) void {
            enter("coex timer_setfn requires task context");
            Target.setfn(key, callback, arg);
        }

        pub fn arm_us(key: Handle, us: u32, repeat: bool) callconv(.c) void {
            enter("coex timer_arm_us requires task context");
            Target.arm_us(key, us, repeat);
        }
    };
}

/// `gpa` backs the coex timer node, which stays on the radio timer list
/// until `timer.deinit`: the attached heap, as for every radio timer node.
pub fn init(gpa: std.mem.Allocator) !void {
    try startup.start(gpa, &adapter, esp_coex_adapter_register, coex_pre_init);
}

fn is_in_isr() callconv(.c) c_int {
    return @intFromBool(rtos.in_isr());
}

fn debug_matrix(_: c_int, _: c_int, _: bool) callconv(.c) c_int {
    return 0x106; // ESP_ERR_NOT_SUPPORTED, esp_coex_adapter.c:146-153.
}

// IDF v5.5.1 esp_coex/esp32c6/esp_coex_adapter.c:87-99,136-144,165-169.
// C6 coex_schm_lock/unlock use the ordinary task slots (take with UINT32_MAX).
// The core lock selects the dedicated ISR slots through is_in_isr.
fn SemaphoreCallbacks(comptime Kernel: type, comptime enter: anytype, comptime task_take: anytype) type {
    return struct {
        /// task_calls counts take/give calls on the task slots. The Wi-Fi
        /// blob's OSI _semphr_take/_semphr_give use the same slots in a
        /// coexistence image (wifi.zig g_wifi_osi_funcs), so the count mixes
        /// coex scheme locks with every Wi-Fi driver semaphore call.
        /// from_isr_calls counts calls of the separate from-ISR slots, which
        /// only the coex core lock selects through is_in_isr. Neither is the
        /// task-only check: an interrupt entry into a task slot panics, and
        /// that panic is the check.
        pub var task_calls: std.atomic.Value(u32) = .init(0);
        pub var from_isr_calls: std.atomic.Value(u32) = .init(0);

        fn enter_task_slot(comptime message: []const u8) void {
            if (Kernel.in_isr()) @panic(message);
            _ = task_calls.rmw(.Add, 1, .monotonic);
        }

        pub fn take(handle: Handle, ticks: u32) callconv(.c) i32 {
            enter_task_slot("coex semphr_take requires task context");
            return task_take(handle, ticks);
        }

        fn take_from_isr(handle: Handle, _: ?*i32) callconv(.c) i32 {
            _ = from_isr_calls.rmw(.Add, 1, .monotonic);
            const sem: *Kernel.Semaphore = @ptrCast(@alignCast(handle));
            sem.take_with_timeout(.non_blocking) catch return 0;
            return 1;
        }

        fn give_from_isr(handle: Handle, woken: ?*i32) callconv(.c) i32 {
            _ = from_isr_calls.rmw(.Add, 1, .monotonic);
            const sem: *Kernel.Semaphore = @ptrCast(@alignCast(handle));
            const cs = enter();
            defer cs.leave();
            if (sem.current_value == sem.max_value) return 0;
            var hptw = false;
            sem.give_from_isr(&hptw);
            if (hptw) {
                if (woken) |flag| flag.* = 1;
            }
            return 1;
        }

        pub fn give(handle: Handle) callconv(.c) i32 {
            enter_task_slot("coex semphr_give requires task context");
            const sem: *Kernel.Semaphore = @ptrCast(@alignCast(handle));
            const cs = enter();
            defer cs.leave();
            if (sem.current_value == sem.max_value) return 0;
            sem.give();
            return 1;
        }
    };
}

pub const SemaphoreStats = struct { task_calls: u32, from_isr_calls: u32 };

pub fn semaphore_stats() SemaphoreStats {
    return .{
        .task_calls = SemaphoreSlots.task_calls.load(.monotonic),
        .from_isr_calls = SemaphoreSlots.from_isr_calls.load(.monotonic),
    };
}

// IDF v5.5.1 esp_phy/src/btbb_init.c:61-95. BLE owns a reference for
// the lifetime of its controller. 802.15.4 releases its reference at deinit.
var btbb_mutex: rtos.Mutex = .{};
var btbb: @import("shared_clocks.zig").Btbb = .{};

pub fn btbb_enable(print_version: u32) void {
    btbb_mutex.lock();
    defer btbb_mutex.unlock();
    btbb.enable(print_version, @import("ble/abi.zig").bt_bb_v2_init_cmplx);
}

pub fn btbb_disable() void {
    btbb_mutex.lock();
    defer btbb_mutex.unlock();
    btbb.disable();
}

test "coex and Wi-Fi retain boot locks and ROM callbacks across fresh radio arenas" {
    const Sem = rtos.Semaphore;
    const Blob = struct {
        var adapter_ptr: *Adapter = undefined;
        var coexist_funcs: ?*RomFuncs = null;
        var wifi_api_lock: Handle = null;
        var wifi_global_lock: Handle = null;
        var core: ?*Sem = null;
        var scheme: ?*Sem = null;
        var fail_second = true;
        var reservation: abi.Startup(u32) = .{};
        var installed: ?*u32 = null;
        var calls: usize = 0;

        fn register(table: *Adapter) i32 {
            if (table.version != 2 or table.magic != 0xdeadbeaf) return 1;
            adapter_ptr = table;
            return 0;
        }

        fn pre_init() i32 {
            calls += 1;
            if (core == null) core = @ptrCast(@alignCast(adapter_ptr.semphr_create(1, 1)));
            if (scheme == null) {
                if (fail_second) {
                    // coex_core_pre_init calls the adapter's delete callback,
                    // retaining core for its next attempt.
                    adapter_ptr.semphr_delete(core);
                    return 0x101;
                }
                scheme = @ptrCast(@alignCast(adapter_ptr.semphr_create(1, 1)));
            }
            installed = reservation.take_timer();
            installed.?.* = 1;
            if (coexist_funcs == null) {
                const storage = adapter_ptr.malloc_internal(0x34) orelse return 0x101;
                coexist_funcs = @ptrCast(@alignCast(storage));
                // Distinct simulated ROM entries reveal any overwrite between inits.
                for (coexist_funcs.?, 0..) |*entry, idx| entry.* = @intCast(0x40000000 + 4 * idx);
            }
            return 0;
        }
    };
    const previous_semaphores = semaphores;
    const previous_count = semaphore_count;
    const previous_table = rom_funcs;
    const previous_in_use = rom_funcs_in_use;
    semaphore_count = 0;
    rom_funcs_in_use = false;
    defer {
        semaphores = previous_semaphores;
        semaphore_count = previous_count;
        rom_funcs = previous_table;
        rom_funcs_in_use = previous_in_use;
    }
    var table: Adapter = undefined;
    table.magic = 0xdeadbeaf;
    table.semphr_create = storage_callbacks.semphr_create;
    table.semphr_delete = storage_callbacks.semphr_delete;
    table.malloc_internal = storage_callbacks.malloc_internal;
    table.free = storage_callbacks.free;
    const expect = std.testing.expect;
    const expect_error = std.testing.expectError;
    table.version = 1;
    try expect_error(error.CoexAdapterRegistrationFailed, Blob.reservation.start(std.testing.allocator, &table, Blob.register, Blob.pre_init));
    try expect(Blob.calls == 0);
    table.version = 2;
    try expect_error(error.CoexPreInitFailed, Blob.reservation.start(std.testing.allocator, &table, Blob.register, Blob.pre_init));
    const core = Blob.core.?;
    try expect(core.current_value == 1);
    Blob.fail_second = false;
    const calls = Blob.calls;
    try expect_error(error.OutOfMemory, Blob.reservation.start(std.testing.failing_allocator, &table, Blob.register, Blob.pre_init));
    try expect(Blob.installed == null and Blob.calls == calls and Blob.scheme == null);

    var wifi_locks: osi.WifiBootLocks = .{};
    var buffers: [3][1024]u8 align(16) = undefined;
    var saved_scheme: ?*Sem = null;
    try expect(table.malloc_internal(0x35) == null);
    for (&buffers, 0..) |*buffer, session| {
        var arena = std.heap.FixedBufferAllocator.init(buffer);
        var route: @import("shared_heap.zig").TestRoute = .{};
        route.install(arena.allocator());
        defer route.restore();
        wifi_locks.install(&Blob.wifi_api_lock, &Blob.wifi_global_lock);
        try Blob.reservation.start(arena.allocator(), &table, Blob.register, Blob.pre_init);
        try expect(Blob.coexist_funcs.? == &rom_funcs);
        try expect(table.malloc_internal(0x34) == null); // never alias a live allocation
        const scheme = Blob.scheme.?;
        if (saved_scheme) |saved| try expect(scheme == saved);
        saved_scheme = scheme;
        try expect(Blob.core == core and core != scheme and semaphore_count == 2);
        try expect(core.current_value == 1 and scheme.current_value == 1);
        try expect(@intFromPtr(Blob.installed.?) >= @intFromPtr(buffer) and @intFromPtr(Blob.installed.?) < @intFromPtr(buffer) + buffer.len);
        try test_exhausted_wifi_shutdown(&arena, &route, session);
        arena.allocator().destroy(Blob.installed.?);
        Blob.installed = null;
        @memset(buffer, 0xaa);
        try expect(Blob.wifi_api_lock == @as(Handle, &wifi_locks.api));
        try expect(Blob.wifi_global_lock == @as(Handle, &wifi_locks.global));
        try expect(wifi_locks.api.recursive and wifi_locks.global.recursive);
        for (Blob.coexist_funcs.?, 0..) |entry, idx| try expect(entry == 0x40000000 + 4 * idx);
    }
    table.free(Blob.coexist_funcs);
    Blob.coexist_funcs = null;
    try expect(table.malloc_internal(0x34) == @as(Handle, &rom_funcs));
    table.free(&rom_funcs);
}

// Exercise the OSI storage and scheduler lists used by the C6 shutdown
// callbacks. Only the hardware context switch is replaced on the host.
fn test_exhausted_wifi_shutdown(arena: *std.heap.FixedBufferAllocator, route: *@import("shared_heap.zig").TestRoute, session: usize) !void {
    const Host = struct {
        var scheduler: rtos.RTOS_State = undefined;
        fn detach(task: *rtos.Task) void {
            scheduler.detach_task(task);
        }
        fn unexpected_exit(_: rtos.YieldAction) void {
            @panic("shutdown caller tried to delete itself");
        }
    };
    var caller: rtos.Task = .{ .context = undefined, .stack = &.{}, .priority = .lowest };
    Host.scheduler = .{
        .current_task = &caller,
        .current_sleep_queue = &Host.scheduler.sleep_queues[0],
        .overflow_sleep_queue = &Host.scheduler.sleep_queues[1],
    };

    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    route.reroute(failing.allocator());
    defer route.reroute(arena.allocator());
    const task_mem = try failing.allocator().alignedAlloc(u8, .@"16", @sizeOf(rtos.Task) + 128);
    const worker: *rtos.Task = @ptrCast(task_mem.ptr);
    worker.* = .{
        .context = undefined,
        .stack = task_mem[@sizeOf(rtos.Task)..],
        .priority = .lowest,
        .state = switch (session) {
            0 => .suspended, // blocked waiting for a PP queue message
            1 => .sleep_queue_1, // timed wait across tick rollover
            else => .ready, // woken but still on the queue until it resumes
        },
    };
    const queue_handle = osi.wifi_create_queue(4, 8) orelse return error.OutOfMemory;
    const slot: *?*osi.QueueWrapper = @ptrCast(@alignCast(queue_handle));
    const getters = &slot.*.?.inner.getters;
    var waiter: rtos.PriorityWaitQueue.Waiter = .{ .task = worker, .priority = worker.priority };
    getters.list.append(&waiter.node);
    worker.active_wait = .{ .queue = getters, .node = &waiter.node };
    switch (worker.state) {
        .sleep_queue_1 => Host.scheduler.sleep_queues[1].append(&worker.node),
        .ready => Host.scheduler.ready_queue.put(worker),
        .suspended => {},
        else => unreachable,
    }

    // Exhaust the actual session arena before the stop. Only the stop is
    // offered the reserved ioctl: its three steps run with `owner` set, as
    // WifiShutdown.stop sets it. The driver deinit and pp_delete_task run
    // after it is clear.
    failing.fail_index = failing.alloc_index;
    var shutdown: osi.WifiShutdown = .{ .owner = &caller, .worker = worker };
    for (0..3) |_| {
        const ioctl = shutdown.reserve_ioctl(&caller, 24) orelse return error.MissingShutdownIoctl;
        const bytes: *[24]u8 = @ptrCast(ioctl);
        try std.testing.expectEqualSlices(u8, &@as([24]u8, @splat(0)), bytes);
        @memset(bytes, 0xab);
        try std.testing.expect(shutdown.reserve_ioctl(worker, 24) == null);
        try std.testing.expect(shutdown.release_ioctl(ioctl));
    }
    // Once the stop returns `owner` is clear, so the driver deinit's ioctl is offered nothing.
    shutdown.owner = null;
    try std.testing.expect(shutdown.reserve_ioctl(&caller, 24) == null);
    try std.testing.expect(osi.semphr_create(1, 0) == null);
    shutdown.delete_task(worker, &caller, Host.detach, Host.unexpected_exit);
    try std.testing.expect(worker.state == .exited and getters.list.first == null);
    try std.testing.expect(Host.scheduler.sleep_queues[1].last == null and Host.scheduler.ready_queue.max_ready_priority() == null);
    osi.wifi_delete_queue(queue_handle);
    try std.testing.expect(slot.* == null);
    rtos.free_exited_task(failing.allocator(), worker);
    try std.testing.expect(failing.has_induced_failure and failing.allocated_bytes == failing.freed_bytes);
}

test "core ISR slots report a wake and ordinary scheme slots forward the task timeout" {
    const Kernel = struct {
        var interrupt = true;
        var task_take_calls: usize = 0;
        var task_timeout: u32 = 0;

        fn in_isr() bool {
            return interrupt;
        }
        fn enter() @This() {
            return .{};
        }
        fn leave(_: @This()) void {}
        fn task_take(handle: Handle, ticks: u32) i32 {
            // Stands in for osi.semphr_take, which forwards the timeout and
            // returns pdTRUE (1) on success and pdFALSE (0) on timeout. The
            // real one reads the RISC-V mscratch CSR and cannot run on the host.
            task_take_calls += 1;
            task_timeout = ticks;
            const sem: *Semaphore = @ptrCast(@alignCast(handle));
            if (sem.current_value == 0) return 0;
            sem.current_value -= 1;
            return 1;
        }

        const Semaphore = struct {
            current_value: u32 = 0,
            max_value: u32 = 1,
            higher_priority_waiter: bool = true,
            task_gives: usize = 0,

            fn take_with_timeout(self: *@This(), timeout: rtos.Timeout) error{Timeout}!void {
                std.debug.assert(timeout == .non_blocking);
                if (self.current_value == 0) return error.Timeout;
                self.current_value -= 1;
            }
            fn give_from_isr(self: *@This(), woken: *bool) void {
                self.current_value += 1;
                woken.* = self.higher_priority_waiter;
                self.higher_priority_waiter = false;
            }
            fn give(self: *@This()) void {
                self.task_gives += 1;
                self.current_value += 1;
            }
        };
    };
    const Slots = SemaphoreCallbacks(Kernel, Kernel.enter, Kernel.task_take);
    var table: Adapter = undefined;
    table.semphr_take = Slots.take;
    table.semphr_give = Slots.give;
    var lock: Kernel.Semaphore = .{};
    const forever = std.math.maxInt(u32);
    const expect = std.testing.expectEqual;

    table.semphr_take_from_isr = Slots.take_from_isr;
    table.semphr_give_from_isr = Slots.give_from_isr;
    var woken: i32 = 0;
    try expect(0, table.semphr_take_from_isr(&lock, &woken));
    try expect(1, table.semphr_give_from_isr(&lock, &woken));
    try expect(1, woken);
    try expect(0, table.semphr_give_from_isr(&lock, &woken));
    try expect(0, lock.task_gives);
    try expect(0, Kernel.task_take_calls);

    Kernel.interrupt = false;
    try expect(1, table.semphr_take(&lock, forever));
    try expect(forever, Kernel.task_timeout);
    try expect(1, Kernel.task_take_calls);
    try expect(1, table.semphr_give(&lock));
    try expect(1, lock.task_gives);
}
