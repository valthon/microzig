const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const c = @import("esp-wifi-driver");
const microzig = @import("microzig");
const enter_critical_section = microzig.interrupt.enter_critical_section;
const peripherals = microzig.chip.peripherals;
const compatibility = @import("../compatibility.zig");
const clocks_c6 = @import("../analog/esp32_c6.zig");
const radio_interrupt = microzig.options.hal.radio.interrupt;

const radio = @import("../radio.zig");
const rng = @import("../rng.zig");
const rtos = @import("../rtos.zig");
const get_time_since_boot = @import("../time.zig").get_time_since_boot;
const timer = @import("timer.zig");
const wifi = @import("wifi.zig");

const log = std.log.scoped(.esp_radio_osi);

const coex_enabled = radio.coex_enabled;
const coex = @import("coex.zig");
const phy_modems = @import("phy_modems.zig");
const shared_heap = @import("shared_heap.zig");

/// The allocator of the blob-facing C callbacks in this file. The blobs
/// call `malloc(size_t)` and `free(void *)` by symbol, and the adapter
/// table's `void *(*_malloc)(size_t size)` and `void (*_free)(void *p)`
/// (esp-wifi-sys `c/include/esp_private/wifi_os_adapter.h:73-74`) carry no
/// context argument, so these callbacks cannot be handed an allocator.
///
/// Read by those callbacks (`malloc`, `calloc`, `free`, the semaphore,
/// mutex, queue and task create and delete slots, `timer_setfn` and
/// `timer_done`) and by the Zig code that frees what they allocated: the
/// Wi-Fi PP task, the eloop reservation, the radio timer worker and nodes.
///
/// A coexistence image keeps no allocator here: this reads the route
/// `radio.attach_shared_heap` writes once (`shared_heap.zig`), and returns
/// `Allocator.failing` until then. A single-radio image returns
/// `gpa`, which the first owner's `radio.init` writes in a critical section.
pub inline fn callback_allocator() std.mem.Allocator {
    return if (coex_enabled) shared_heap.callback_allocator() else gpa;
}

/// Single-radio images only; see `callback_allocator`.
pub var gpa: if (coex_enabled) void else std.mem.Allocator = if (coex_enabled) {} else undefined;

pub var wifi_interrupt_handler: ?struct {
    f: *const fn (?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
} = undefined;

extern fn vsnprintf(buffer: [*c]u8, len: usize, fmt: [*c]const u8, va_list: std.lang.VaList) callconv(.c) void;

fn syslog(fmt: ?[*:0]const u8, va_list: std.lang.VaList) callconv(.c) void {
    var buf: [512:0]u8 = undefined;
    vsnprintf(&buf, 512, fmt, va_list);
    log.debug("{s}", .{std.mem.span((&buf).ptr)});
}

// ----- exports -----

pub fn strlen(str: ?[*:0]const u8) callconv(.c) usize {
    const s = str orelse return 0;

    return std.mem.len(s);
}

// The blobs use ASCII protocol strings; avoid ROM's newlib locale/reent state.
pub fn strcasecmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    var i: usize = 0;
    while (true) : (i += 1) {
        const x = std.ascii.toLower(a[i]);
        const y = std.ascii.toLower(b[i]);
        if (x != y or x == 0) return @as(c_int, x) - @as(c_int, y);
    }
}

pub fn strnlen(str: ?[*:0]const u8, n: usize) callconv(.c) usize {
    const s = str orelse return 0;
    return if (std.mem.findScalar(u8, s[0..n], 0)) |index| index else n;
}

test "strnlen" {
    try std.testing.expect(strnlen(&.{ 10, 20, 30, 0 }, 4) == 3);
    try std.testing.expect(strnlen(&.{ 10, 20, 30, 0, 10, 20, 30 }, 7) == 3);
}

pub fn strrchr(str: ?[*:0]const u8, chr: u32) callconv(.c) ?[*:0]const u8 {
    const s = str orelse return null;

    // Should return even the index of the zero byte if requested. This
    // implementation only works with single byte characters.

    if (std.mem.findScalarLast(u8, s[0 .. std.mem.len(s) + 1], @intCast(chr))) |index| {
        return @ptrFromInt(@intFromPtr(s) + index);
    } else {
        return null;
    }
}

pub fn __assert_func(
    file: ?[*:0]const u8,
    line: u32,
    func: ?[*:0]const u8,
    failed_expr: ?[*:0]const u8,
) callconv(.c) void {
    switch (builtin.mode) {
        .Debug, .ReleaseSafe => {
            log.err("assertion failed: `{s}` in file {s}, line {}, function {s}", .{
                failed_expr orelse "",
                file orelse "",
                line,
                func orelse "",
            });
            @panic("assertion failed");
        },
        .ReleaseSmall => @panic("assertion failed"),
        .ReleaseFast => unreachable,
    }
}

pub fn malloc(len: usize) callconv(.c) ?*anyopaque {
    log.debug("malloc {}", .{len});

    if (len == 0) return null;
    const alloc_len = std.math.add(usize, 8, len) catch return null;
    const buf = callback_allocator().rawAlloc(alloc_len, .@"8", @returnAddress()) orelse {
        log.warn("failed to allocate memory: {}", .{len});
        return null;
    };

    const stored_len: *usize = @ptrCast(@alignCast(buf));
    stored_len.* = len;
    return @ptrFromInt(@intFromPtr(buf) + 8);
}

pub fn calloc(number: usize, size: usize) callconv(.c) ?*anyopaque {
    const total_size = std.math.mul(usize, number, size) catch return null;
    if (malloc(total_size)) |ptr| {
        @memset(@as([*]u8, @ptrCast(ptr))[0..total_size], 0);
        return ptr;
    }
    return null;
}

pub fn free(ptr: ?*anyopaque) callconv(.c) void {
    log.debug("free {?}", .{ptr});

    // NOTE: The wifi driver calls this function with null sometimes. Just
    // ignore it.
    if (ptr == null) return;

    const buf_ptr: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - 8);
    const buf_len: *usize = @ptrCast(@alignCast(buf_ptr));
    callback_allocator().rawFree(buf_ptr[0 .. 8 + buf_len.*], .@"8", @returnAddress());
}

pub fn puts(ptr: ?*anyopaque) callconv(.c) void {
    const s: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
    log.debug("{s}", .{s});
}

pub fn gettimeofday(tv: ?*c.timeval, _: ?*anyopaque) callconv(.c) i32 {
    if (tv) |time_val| {
        const usec = get_time_since_boot().to_us();
        time_val.tv_sec = usec / 1_000_000;
        time_val.tv_usec = @intCast(usec % 1_000_000);
    }

    return 0;
}

pub fn sleep(time_sec: c_uint) callconv(.c) c_int {
    rtos.sleep(.from_us(time_sec * 1_000_000));
    return 0;
}

pub fn usleep(time_us: u32) callconv(.c) c_int {
    rtos.sleep(.from_us(time_us));
    return 0;
}

pub fn vTaskDelay(ticks: u32) callconv(.c) void {
    rtos.sleep(.from_ticks(ticks));
}

pub var WIFI_EVENT: c.esp_event_base_t = "WIFI_EVENT";

pub fn printf(fmt: ?[*:0]const u8, ...) callconv(.c) void {
    syslog(fmt, @cVaStart());
}

/// Referenced by the C6 PHY blob for debug output; dropped, like esp-radio does by default.
pub fn putchar(ch: c_int) callconv(.c) c_int {
    return ch;
}

/// XTAL frequency in MHz, referenced by the C6 PHY blob.
pub fn rtc_clk_xtal_freq_get() callconv(.c) c_int {
    return switch (compatibility.chip) {
        .esp32_c3 => 40,
        .esp32_c6 => peripherals.PCR.SYSCLK_CONF.read().CLK_XTAL_FREQ,
    };
}

pub fn esp_fill_random(buf: [*c]u8, len: usize) callconv(.c) void {
    log.debug("esp_fill_random {any} {}", .{ buf, len });

    rng.read(buf[0..len]);
}

/// Some are weaklinks which can be overriten.
pub fn export_symbols() void {
    @export(&strcasecmp, .{ .name = "strcasecmp", .linkage = .weak });
    @export(&strlen, .{ .name = "strlen", .linkage = .weak });
    @export(&strnlen, .{ .name = "strnlen", .linkage = .weak });
    @export(&strrchr, .{ .name = "strrchr", .linkage = .weak });

    @export(&__assert_func, .{ .name = "__assert_func", .linkage = .weak });

    @export(&malloc, .{ .name = "malloc", .linkage = .weak });
    @export(&calloc, .{ .name = "calloc", .linkage = .weak });
    @export(&free, .{ .name = "free", .linkage = .weak });
    @export(&puts, .{ .name = "puts", .linkage = .weak });

    @export(&gettimeofday, .{ .name = "gettimeofday", .linkage = .weak });
    @export(&sleep, .{ .name = "sleep", .linkage = .weak });
    @export(&usleep, .{ .name = "usleep", .linkage = .weak });
    @export(&vTaskDelay, .{ .name = "vTaskDelay", .linkage = .weak });

    @export(&WIFI_EVENT, .{ .name = "WIFI_EVENT" });
    inline for (&.{
        "rtc_printf",
        "phy_printf",
        "coexist_printf",
        "net80211_printf",
        "pp_printf",
    }) |name| {
        @export(&printf, .{ .name = name });
    }
    @export(&esp_fill_random, .{ .name = "esp_fill_random" });
    if (compatibility.chip == .esp32_c6) {
        @export(&putchar, .{ .name = "putchar", .linkage = .weak });
        @export(&rtc_clk_xtal_freq_get, .{ .name = "rtc_clk_xtal_freq_get", .linkage = .weak });
    }
    @export(&esp_event_post, .{ .name = "esp_event_post" });
}

// ----- end of exports -----

pub fn env_is_chip() callconv(.c) bool {
    return true;
}

pub fn set_intr(cpu_no: i32, intr_source: u32, intr_num: u32, intr_prio: i32) callconv(.c) void {
    log.debug("set_intr {} {} {} {}", .{ cpu_no, intr_source, intr_num, intr_prio });

    // esp32c3
    // these are already set up
    // possible calls:
    // INFO - set_intr 0 2 1 1 (WIFI_PWR)
    // INFO - set_intr 0 0 1 1 (WIFI_MAC)
    //
    // we don't need to do anything as these interrupts are already setup in
    // `radio.init`
}

pub fn clear_intr(intr_source: u32, intr_num: u32) callconv(.c) void {
    log.debug("clear_intr {} {}", .{ intr_source, intr_num });
}

pub fn set_isr(
    n: i32,
    f: ?*anyopaque,
    arg: ?*anyopaque,
) callconv(.c) void {
    log.debug("set_isr {} {?} {?}", .{ n, f, arg });

    // esp32c3 specific

    switch (n) {
        0, 1 => {
            wifi_interrupt_handler = if (f) |handler| .{
                .f = @ptrCast(@alignCast(handler)),
                .arg = arg,
            } else null;
        },
        else => @panic("invalid interrupt number"),
    }
}

pub fn ints_on(mask: u32) callconv(.c) void {
    log.debug("ints_on {}", .{mask});

    if (mask == 2) {
        microzig.cpu.interrupt.enable(radio_interrupt);
    } else {
        @panic("ints_on: not implemented");
    }
}

pub fn ints_off(mask: u32) callconv(.c) void {
    log.debug("ints_off {}", .{mask});

    if (mask == 2) {
        microzig.cpu.interrupt.disable(radio_interrupt);
    } else {
        @panic("ints_off: not implemented");
    }
}

pub fn is_from_isr() callconv(.c) bool {
    return true;
}

pub fn spin_lock_create() callconv(.c) ?*anyopaque {
    log.debug("spin_lock_create", .{});
    return semphr_create(1, 1);
}

pub fn spin_lock_delete(ptr: ?*anyopaque) callconv(.c) void {
    log.debug("spin_lock_delete {?}", .{ptr});
    return semphr_delete(ptr);
}

pub fn wifi_int_disable(mux_ptr: ?*anyopaque) callconv(.c) u32 {
    log.debug("wifi_int_disable {?}", .{mux_ptr});

    const ints_enabled = microzig.cpu.interrupt.globally_enabled();
    if (ints_enabled) {
        microzig.cpu.interrupt.disable_interrupts();
    }
    return @intFromBool(ints_enabled);
}

pub fn wifi_int_restore(mux_ptr: ?*anyopaque, state: u32) callconv(.c) void {
    log.debug("wifi_int_restore {?} {}", .{ mux_ptr, state });

    // check if interrupts were enabled before.
    if (state != 0) {
        microzig.cpu.interrupt.enable_interrupts();
    }
}

// In a coexistence image this callback and the two coex status-bit callbacks
// log nothing at any level: this one runs in an interrupt, and
// coex_callback_test checks all three. Single-radio images keep their logs.
pub fn task_yield_from_isr() callconv(.c) void {
    if (!coex_enabled) log.debug("task_yield_from_isr", .{});

    rtos.yield_from_isr();
}

pub fn semphr_create(max_value: u32, init_value: u32) callconv(.c) ?*anyopaque {
    log.debug("semphr_create {} {}", .{ max_value, init_value });

    if (max_value == 0 or init_value > max_value) return null;
    const sem = callback_allocator().create(rtos.Semaphore) catch {
        log.warn("failed to allocate semaphore", .{});
        return null;
    };
    sem.* = .init(init_value, max_value);

    log.debug(">>>> semaphore create: {*}", .{sem});

    return sem;
}

pub fn semphr_delete(ptr: ?*anyopaque) callconv(.c) void {
    log.debug("semphr_delete {?}", .{ptr});

    callback_allocator().destroy(@as(*rtos.Semaphore, @ptrCast(@alignCast(ptr))));
}

/// Returns 1 (pdTRUE) when taken and 0 (pdFALSE) on timeout, as xSemaphoreTake
/// in IDF v5.5.1 esp_coex/esp32c6/esp_coex_adapter.c:87-94 (esp32c3 alike).
/// Linked callers compare the result with 1: ieee80211_ioctl reads an
/// ioctl's result only then, and otherwise returns 0 (C3 and C6 libnet80211.a
/// ieee80211_ioctl+0x1b8..0x1be), and wps_post_block returns -1 instead of
/// the posted request's result (libwpa_supplicant.a wps_post_block+0x38..0x3e).
pub fn semphr_take(ptr: ?*anyopaque, tick: u32) callconv(.c) i32 {
    log.debug("semphr_take {?} {}", .{ ptr, tick });

    const sem: *rtos.Semaphore = @ptrCast(@alignCast(ptr));
    const timeout: rtos.Timeout = switch (tick) {
        0 => .non_blocking,
        c.OSI_FUNCS_TIME_BLOCKING => .never,
        else => |ticks| .{ .after = .from_ticks(ticks) },
    };
    sem.take_with_timeout(timeout) catch {
        log.debug(">>>> return from semaphore take with timeout: {*}", .{sem});
        return 0;
    };

    return 1;
}

pub fn semphr_give(ptr: ?*anyopaque) callconv(.c) i32 {
    log.debug("semphr_give {?}", .{ptr});

    const sem: *rtos.Semaphore = @ptrCast(@alignCast(ptr));
    sem.give();
    return 1;
}

pub fn wifi_thread_semphr_get() callconv(.c) ?*anyopaque {
    return &rtos.get_current_task().semaphore;
}

const RecursiveMutex = struct {
    recursive: bool,
    value: u32 = 0,
    owning_task: ?*rtos.Task = null,
    prev_priority: ?rtos.Priority = null,
    wait_queue: rtos.PriorityWaitQueue = .{},

    pub fn lock(mutex: *RecursiveMutex) void {
        const cs = enter_critical_section();
        defer cs.leave();

        const current_task = rtos.get_current_task();

        if (mutex.owning_task == current_task) {
            assert(mutex.recursive);
            mutex.value += 1;
            return;
        }

        while (mutex.owning_task) |owning_task| {
            // Owning task inherits the priority of the current task if it the
            // current task has a bigger priority.
            if (@backingInt(current_task.priority) > @backingInt(owning_task.priority)) {
                mutex.prev_priority = owning_task.priority;
                owning_task.priority = current_task.priority;
                var _hptw = false;
                rtos.make_ready(owning_task, &_hptw);
            }

            mutex.wait_queue.wait(null);
        }

        assert(mutex.value == 0);
        mutex.value += 1;
        mutex.owning_task = current_task;
    }

    pub fn unlock(mutex: *RecursiveMutex) bool {
        const cs = enter_critical_section();
        defer cs.leave();

        assert(mutex.owning_task == rtos.get_current_task());

        assert(mutex.value > 0);
        mutex.value -= 1;
        if (mutex.value <= 0) {
            const owning_task = mutex.owning_task.?;

            // Restore the priority of the task
            if (mutex.prev_priority) |prev_priority| {
                owning_task.priority = prev_priority;
                mutex.prev_priority = null;
            }

            mutex.owning_task = null;

            var hptw = false;
            mutex.wait_queue.wake_one(&hptw);
            if (hptw) rtos.yield_from_cs(.reschedule);

            return true;
        } else {
            return false;
        }
    }
};

// C6 libnet80211.a, ieee80211_api.o: wifi_api_lock+0x3e..0x42 and
// wifi_init_in_caller_task+0x14..0x2a lazily install recursive mutexes.
// wifi_deinit_in_caller_task+0x1e..0x50 deletes only the interrupt and MAC
// list locks. Supply the two persistent handles before the first Wi-Fi init.
pub const WifiBootLocks = struct {
    api: RecursiveMutex = .{ .recursive = true },
    global: RecursiveMutex = .{ .recursive = true },

    pub fn api_depth(self: *WifiBootLocks, caller: *rtos.Task) u32 {
        const cs = enter_critical_section();
        defer cs.leave();
        return if (self.api.owning_task == caller) self.api.value else 0;
    }

    pub fn install(self: *WifiBootLocks, api_slot: *?*anyopaque, global_slot: *?*anyopaque) void {
        if (api_slot.* == null) api_slot.* = &self.api;
        if (global_slot.* == null) global_slot.* = &self.global;
    }
};

pub fn mutex_create() callconv(.c) ?*anyopaque {
    log.debug("mutex_create", .{});

    const mutex = callback_allocator().create(RecursiveMutex) catch {
        log.warn("failed to allocate recursive mutex", .{});
        return null;
    };
    mutex.* = .{ .recursive = false };

    log.debug(">>>> mutex create: {*}", .{mutex});

    return mutex;
}

// IDF v5.5.1 wpa_supplicant/port/eloop.c:72-90 installs the timer
// before creating its recursive mutex. esp_wpa_main.c:513 ignores the
// eloop_init result. Reserve both before entering esp_supplicant_init.
// Both come from `callback_allocator()`: the blob frees them through `timer_done` and
// `mutex_delete`.
pub const EloopReservation = struct {
    owner: ?*rtos.Task = null,
    timer_node: ?*timer.Timer = null,
    mutex: ?*RecursiveMutex = null,

    pub fn reserve(self: *@This(), caller: *rtos.Task) error{OutOfMemory}!void {
        const node = try callback_allocator().create(timer.Timer);
        errdefer callback_allocator().destroy(node);
        const lock = try callback_allocator().create(RecursiveMutex);
        lock.* = .{ .recursive = true };
        self.* = .{ .owner = caller, .timer_node = node, .mutex = lock };
    }

    pub fn finish(self: *@This()) void {
        if (self.timer_node) |node| callback_allocator().destroy(node);
        if (self.mutex) |lock| callback_allocator().destroy(lock);
        self.* = .{};
    }

    pub fn take_timer(self: *@This(), caller: *rtos.Task) ?*timer.Timer {
        if (self.owner != caller) return null;
        const node = self.timer_node;
        self.timer_node = null;
        return node;
    }

    pub fn take_mutex(self: *@This(), caller: *rtos.Task) ?*anyopaque {
        if (self.owner != caller) return null;
        const lock = self.mutex;
        self.mutex = null;
        return lock;
    }
};

pub var eloop_reservation: EloopReservation = .{};

pub fn wifi_recursive_mutex_create() callconv(.c) ?*anyopaque {
    if (!rtos.in_isr()) {
        if (eloop_reservation.take_mutex(rtos.get_current_task())) |lock| return lock;
    }
    return recursive_mutex_create();
}

pub fn wifi_timer_setfn(ptr: ?*anyopaque, callback: ?*anyopaque, arg: ?*anyopaque) callconv(.c) void {
    if (!rtos.in_isr()) {
        if (eloop_reservation.take_timer(rtos.get_current_task())) |node| {
            timer.setfn_reserved(node, @ptrCast(@alignCast(ptr)), @ptrCast(@alignCast(callback)), arg);
            return;
        }
    }
    timer_setfn(ptr, callback, arg);
}

pub fn recursive_mutex_create() callconv(.c) ?*anyopaque {
    log.debug("recursive_mutex_create", .{});

    const mutex = callback_allocator().create(RecursiveMutex) catch {
        log.warn("failed to allocate recursive mutex", .{});
        return null;
    };
    mutex.* = .{ .recursive = true };

    log.debug(">>>> mutex create: {*}", .{mutex});

    return mutex;
}

pub fn mutex_delete(ptr: ?*anyopaque) callconv(.c) void {
    log.debug("mutex_delete {?}", .{ptr});

    const mutex: *RecursiveMutex = @ptrCast(@alignCast(ptr));
    callback_allocator().destroy(mutex);
}

pub fn mutex_lock(ptr: ?*anyopaque) callconv(.c) i32 {
    log.debug("mutex lock {?}", .{ptr});

    const mutex: *RecursiveMutex = @ptrCast(@alignCast(ptr));
    mutex.lock();

    return 1;
}

pub fn mutex_unlock(ptr: ?*anyopaque) callconv(.c) i32 {
    log.debug("mutex unlock {?}", .{ptr});

    const mutex: *RecursiveMutex = @ptrCast(@alignCast(ptr));
    return @intFromBool(mutex.unlock());
}

pub const QueueWrapper = struct {
    item_len: u32,
    inner: rtos.TypeErasedQueue,
};

fn queue_buffer_len(capacity: u32, item_len: u32) ?usize {
    if (capacity == 0 or item_len == 0) return null;
    return std.math.mul(u32, capacity, item_len) catch null;
}

pub fn queue_create(capacity: u32, item_len: u32) callconv(.c) ?*anyopaque {
    log.debug("queue_create {} {}", .{ capacity, item_len });

    // esp-wifi's WIFI-6676 workaround is for the supplicant message queue.
    // The pinned C3/C6 eap_peer_sm_init already requests (3, 8).
    const stored_item_len: u32 = if (capacity == 3 and item_len == 4) 8 else item_len;

    const len = queue_buffer_len(capacity, stored_item_len) orelse return null;
    const buf: []u8 = callback_allocator().alloc(u8, len) catch {
        log.warn("failed to allocate queue buffer", .{});
        return null;
    };

    const queue = callback_allocator().create(QueueWrapper) catch {
        log.warn("failed to allocate queue", .{});
        callback_allocator().free(buf);
        return null;
    };

    queue.* = .{
        .item_len = stored_item_len,
        .inner = .init(buf),
    };

    log.debug(">>>> queue create: {*}", .{queue});

    return queue;
}

pub fn queue_delete(ptr: ?*anyopaque) callconv(.c) void {
    log.debug("queue_delete {?}", .{ptr});

    const queue: *QueueWrapper = @ptrCast(@alignCast(ptr));
    callback_allocator().free(queue.inner.buffer);
    callback_allocator().destroy(queue);
}

pub fn queue_send(ptr: ?*anyopaque, item_ptr: ?*anyopaque, block_time_tick: u32) callconv(.c) i32 {
    log.debug("queue_send {?} {?} {}", .{ ptr, item_ptr, block_time_tick });

    const queue: *QueueWrapper = @ptrCast(@alignCast(ptr));
    const item: [*]const u8 = @ptrCast(@alignCast(item_ptr));

    const timeout: rtos.Timeout = switch (block_time_tick) {
        0 => .non_blocking,
        c.OSI_FUNCS_TIME_BLOCKING => .never,
        else => |ticks| .{ .after = .from_ticks(ticks) },
    };
    const size = queue.inner.put(item[0..queue.item_len], 1, timeout);
    if (size == 0) return -1;
    return 1;
}

pub fn queue_send_from_isr(ptr: ?*anyopaque, item_ptr: ?*anyopaque, _hptw: ?*anyopaque) callconv(.c) i32 {
    log.debug("queue_send_from_isr {?} {?} {?}", .{ ptr, item_ptr, _hptw });

    const queue: *QueueWrapper = @ptrCast(@alignCast(ptr));
    const item: [*]const u8 = @ptrCast(@alignCast(item_ptr));

    var hptw = false;
    const n = @divExact(queue.inner.put_from_isr(item[0..queue.item_len], &hptw), queue.item_len);

    @as(*u32, @ptrCast(@alignCast(_hptw))).* |= @intFromBool(hptw);

    return @intCast(n);
}

pub fn queue_send_to_back(ptr: ?*anyopaque, item_ptr: ?*anyopaque, block_time_tick: u32) callconv(.c) i32 {
    // The queue is a FIFO, a plain send already goes to the back.
    return queue_send(ptr, item_ptr, block_time_tick);
}

pub fn queue_send_to_front(ptr: ?*anyopaque, item_ptr: ?*anyopaque, block_time_tick: u32) callconv(.c) i32 {
    log.debug("queue_send_to_front {?} {?} {}", .{ ptr, item_ptr, block_time_tick });

    const queue: *QueueWrapper = @ptrCast(@alignCast(ptr));
    const item: [*]const u8 = @ptrCast(@alignCast(item_ptr));

    const timeout: rtos.Timeout = switch (block_time_tick) {
        0 => .non_blocking,
        c.OSI_FUNCS_TIME_BLOCKING => .never,
        else => |ticks| .{ .after = .from_ticks(ticks) },
    };
    return if (queue.inner.put_front(item[0..queue.item_len], timeout)) 1 else -1;
}

pub fn queue_recv(ptr: ?*anyopaque, item_ptr: ?*anyopaque, block_time_tick: u32) callconv(.c) i32 {
    log.debug("queue_recv {?} {?} {}", .{ ptr, item_ptr, block_time_tick });

    const queue: *QueueWrapper = @ptrCast(@alignCast(ptr));
    const item: [*]u8 = @ptrCast(@alignCast(item_ptr));

    const timeout: rtos.Timeout = switch (block_time_tick) {
        0 => .non_blocking,
        c.OSI_FUNCS_TIME_BLOCKING => .never,
        else => |ticks| .{ .after = .from_ticks(ticks) },
    };
    const size = queue.inner.get(item[0..queue.item_len], 1, timeout);
    if (size == 0) return -1;
    return 1;
}

pub fn queue_msg_waiting(ptr: ?*anyopaque) callconv(.c) u32 {
    log.debug("queue_msg_waiting {?}", .{ptr});

    const queue: *QueueWrapper = @ptrCast(@alignCast(ptr));
    return @divExact(queue.inner.len, queue.item_len);
}

pub fn event_group_create() callconv(.c) void {
    @panic("event_group_create: not implemented");
}

pub fn event_group_delete() callconv(.c) void {
    @panic("event_group_delete: not implemented");
}

pub fn event_group_set_bits() callconv(.c) void {
    @panic("event_group_set_bits: not implemented");
}

pub fn event_group_clear_bits() callconv(.c) void {
    @panic("event_group_clear_bits: not implemented");
}

pub fn event_group_wait_bits() callconv(.c) void {
    @panic("event_group_wait_bits: not implemented");
}

fn task_wrapper(
    task_entry: *const fn (param: ?*anyopaque) callconv(.c) noreturn,
    param: ?*anyopaque,
) noreturn {
    task_entry(param);
}

extern var pp_task_hdl: ?*rtos.Task;

fn task_create_common(
    task_func: ?*anyopaque,
    name: [*c]const u8,
    stack_depth: u32,
    param: ?*anyopaque,
    prio: u32,
    task_handle: ?*anyopaque,
    core_id: u32,
) i32 {
    _ = core_id; // autofix

    if (stack_depth == 0) return 0;
    const debug_stack_extra = if (builtin.mode == .debug) 6000 else 0;
    const stack_size = std.math.add(u32, stack_depth, debug_stack_extra) catch return 0;
    const task_entry: *const fn (param: ?*anyopaque) callconv(.c) noreturn = @ptrCast(@alignCast(task_func));
    const task: *rtos.Task = rtos.spawn(callback_allocator(), task_wrapper, .{ task_entry, param }, .{
        .name = std.mem.span(name),
        .priority = @fromBackingInt(@truncate(prio)),
        .stack_size = stack_size,
    }) catch {
        log.warn("failed to create task", .{});
        return 0;
    };

    if (microzig.options.hal.radio.radios.wifi and task_handle == @as(?*anyopaque, @ptrCast(&pp_task_hdl))) {
        // C3/C6 libpp.a pp_create_task loads &pp_task_hdl at +0x154, calls at +0x164.
        // The blob clears that slot even on an internal init rollback.
        wifi_shutdown.record_worker(task);
    }
    @as(*usize, @ptrCast(@alignCast(task_handle))).* = @intFromPtr(task);

    return 1;
}

pub fn task_create_pinned_to_core(
    task_func: ?*anyopaque,
    name: [*c]const u8,
    stack_depth: u32,
    param: ?*anyopaque,
    prio: u32,
    task_handle: ?*anyopaque,
    core_id: u32,
) callconv(.c) i32 {
    log.debug("task_create_pinned_to_core {?} {s} {} {?} {} {?} {}", .{
        task_func,
        name,
        stack_depth,
        param,
        prio,
        task_handle,
        core_id,
    });

    return task_create_common(task_func, name, stack_depth, param, prio, task_handle, core_id);
}

pub fn task_create(
    task_func: ?*anyopaque,
    name: [*c]const u8,
    stack_depth: u32,
    param: ?*anyopaque,
    prio: u32,
    task_handle: ?*anyopaque,
) callconv(.c) i32 {
    log.debug("task_create {?} {s} {} {?} {} {?}", .{
        task_func,
        name,
        stack_depth,
        param,
        prio,
        task_handle,
    });

    return task_create_common(task_func, name, stack_depth, param, prio, task_handle, 0);
}

pub fn task_delete(handle: ?*anyopaque) callconv(.c) void {
    log.debug("task_delete {?}", .{handle});
    if (handle != null) {
        @panic("task_delete(non-null): not implemented");
    }
    rtos.yield(.exit);
}

// C6 libnet80211.a esp_wifi_stop posts three stop steps to the PP task through
// ieee80211_ioctl, each in a fresh 24-byte ioctl from _wifi_malloc (+0x2a,
// +0xf8, +0x18c). pp_post waits 10 ms for a slot in the 200-entry PP queue
// (libpp.a pp_post+0xee..0x10c, pp_create_task+0x8e..0x9a); a full queue
// fails a step with ESP_ERR_WIFI_POST (ieee80211_ioctl+0x14e..0x18e).
// - Step 0 stops the interfaces: wifi_stop_process+0x60 sets g_ic+0x1f1, the
//   byte IDF v5.5.1 wifi_init.c:180-183 reads, to 1. esp_wifi_stop ignores a
//   failed step 0 (+0xcc..0xe2).
// - Step 1 waits for an empty TX queue. esp_wifi_stop retries it up to 500
//   times, task_delay(task_ms_to_tick(10)) apart, then goes on to step 2
//   whether or not it succeeded (+0xf4..0x188).
// - Step 2 stops the hardware. wifi_stop_process+0xaa..0x108 then returns 0,
//   so only ieee80211_ioctl fails it, and esp_wifi_stop returns that result
//   (+0x1a4..0x1c4).
// A failed allocation for step 1 or 2 returns ESP_ERR_NO_MEM after step 0
// (+0xf4..0x11e, +0x188..0x194, +0x1c6..0x1d4). A stop that fails part-way
// leaves the interfaces started with the hardware off, where a second stop
// spins in wifi_hw_stop+0x10..0x42, or the interfaces stopped with the
// hardware running, where a second stop returns success at +0x1d6 without
// stopping it. Neither can be repaired, so both panic. WifiShutdown.stop
// hands the three allocations the reserved ioctl, so they cannot fail.
pub fn stop_driver(backend: anytype) @import("wifi_status.zig").Error!void {
    const was_started = backend.driver_started();
    const result = backend.stop();
    if (!was_started) return result;
    const interfaces_stopped = !backend.driver_started();
    if (result) |_| {
        if (!interfaces_stopped) @panic("Wi-Fi stop: the PP queue rejected the interface stop (ESP_ERR_WIFI_POST)");
    } else |err| {
        if (interfaces_stopped) {
            if (err == error.WifiPost) @panic("Wi-Fi stop: the PP queue rejected the hardware stop (ESP_ERR_WIFI_POST)");
            @panic("Wi-Fi stop failed after the interfaces stopped");
        }
        // The interfaces are still started. WifiPost means steps 0 and 2 were
        // both rejected and panics like either alone. Any other error came
        // before the interfaces stopped and is returned. With step 0
        // rejected, though, a step-2 allocation failure can follow a step 1
        // that already called ieee80211_set_hmac_stop(1)
        // (wifi_stop_process+0x9c).
        if (err == error.WifiPost) @panic("Wi-Fi stop: the PP queue rejected the interface stop and the hardware stop (ESP_ERR_WIFI_POST)");
        return err;
    }
}

/// esp_wifi_disconnect_internal tests g_ic+0x1f1 without the API lock
/// (+0xe..0x18) before it posts, and wifi_disconnect_process+0x1a sets the
/// byte to 2 (started) unconditionally. ieee80211_ioctl+0x116..0x14c rejects
/// the post only while esp_wifi_stop runs; esp_wifi_stop+0x1b6 clears that
/// flag before it returns. A public disconnect that overlaps a stop could mark
/// the stopped interfaces started, so a stop closes this gate around the call
/// and both state reads, and a disconnect that finds it closed returns
/// WouldBlock. In libnet80211.a, sta_recv_mgmt+0x4ec calls the process
/// directly on the PP task for a received station frame, only when
/// g_mesh_is_root is non-zero (+0x4e0..0x4e8); the gate does not cover that
/// path. The other direct caller is wifi_station_stop+0x5a. It is reached
/// from the stop's own step 0 (_do_wifi_stop+0x30, after which
/// wifi_stop_process+0x60 sets the byte to 1), from wifi_restart_process,
/// and through _do_wifi_stop from the set_mode (via wifi_stop_old_mode),
/// set_mac, set_protocol, set_bw, set_band_mode, set_phy_2nd_chan and
/// set_country (via wifi_check_home_channel) processes. It calls the process
/// only while the station vif is set with vif+0x141 bit 1 (+0x14..0x1c), and
/// clears that bit (+0x50..0x56) before the call. Step 0 then destroys the
/// station vif (wifi_stop_process+0x3a, wifi_destroy_sta+0x50), and only a
/// start recreates it, so once step 0 has run none of those routes reaches
/// it.
pub const DisconnectGate = struct {
    const closed: u32 = 1 << 31;
    state: std.atomic.Value(u32) = .init(0),

    pub fn enter(self: *DisconnectGate) bool {
        if (self.state.fetchAdd(1, .acquire) & closed == 0) return true;
        self.leave();
        return false;
    }

    pub fn leave(self: *DisconnectGate) void {
        _ = self.state.fetchSub(1, .release);
    }

    /// Waits for the disconnects already inside to return.
    pub fn close(self: *DisconnectGate, comptime wait: fn () void) void {
        _ = self.state.fetchOr(closed, .acquire);
        while (self.state.load(.acquire) != closed) wait();
    }

    pub fn open(self: *DisconnectGate) void {
        _ = self.state.fetchAnd(~closed, .release);
    }
};

pub var disconnect_gate: DisconnectGate = .{};

test "DisconnectGate.close waits for the disconnects already inside" {
    const T = struct {
        var gate: DisconnectGate = .{};
        var waits: u32 = 0;
        // Each wait lets one disconnect inside return.
        fn wait() void {
            waits += 1;
            gate.leave();
        }
    };

    // Nothing inside: close does not wait.
    T.gate.close(T.wait);
    try std.testing.expectEqual(0, T.waits);
    try std.testing.expect(!T.gate.enter());
    T.gate.open();

    // Two disconnects inside: close waits until both have left.
    try std.testing.expect(T.gate.enter());
    try std.testing.expect(T.gate.enter());
    T.gate.close(T.wait);
    try std.testing.expectEqual(2, T.waits);
    try std.testing.expectEqual(DisconnectGate.closed, T.gate.state.load(.monotonic));

    // Closed: a disconnect is refused and leaves no count behind.
    try std.testing.expect(!T.gate.enter());
    try std.testing.expectEqual(DisconnectGate.closed, T.gate.state.load(.monotonic));

    // Reopened: disconnects enter again.
    T.gate.open();
    try std.testing.expect(T.gate.enter());
    T.gate.leave();
    try std.testing.expectEqual(0, T.gate.state.load(.monotonic));
}

fn wait_one_tick() void {
    rtos.sleep(.from_ticks(1));
}

// Host lifecycle tests run on one thread, so no disconnect is ever inside.
const wifi_test_host = @import("callback_context.zig").host_test;
fn no_wait() void {
    unreachable;
}

// C3/C6 libpp.a: pp_delete_task+0x24..0x42 falls back to
// pp_delete_task_manually on semaphore OOM. A failed pp_post takes the
// same path at +0x54. Manual deletion stops pp_task_hdl before s_wifi_queue.
pub const WifiShutdown = struct {
    // The next teardown step. A full PP queue can reject the synchronous
    // ioctl after the supplicant is already gone.
    stage: enum { off, running, stop, supplicant, unregister, driver, release } = .off,
    // The task inside `stop`, the only one offered the reserved ioctl. It and
    // `ioctl_in_use` are compared only against the calling task, so no other
    // task matches.
    owner: ?*rtos.Task = null,
    // The PP task, which the task-create callback spawned from `callback_allocator()`.
    worker: ?*rtos.Task = null,
    // libnet80211.a esp_wifi_stop+0x2a,+0xf8,+0x18c each request a
    // synchronous 24-byte ioctl from _wifi_malloc; ieee80211_ioctl frees it
    // before the next request, also on each retry of the second one (up to
    // 500). The callees read on the caller's task (ieee80211_ioctl, pp_post,
    // reset_cs_thres, wifi_api_lock/unlock) make no other _wifi_malloc or
    // _wifi_zalloc call; this list is not every callee. The driver deinit's
    // ioctl (esp_wifi_deinit_internal+0xd8, _wifi_zalloc) comes from the
    // heap: on failure the blob restores its initialized state
    // (+0x132..0x140) and returns ESP_ERR_NO_MEM, so that step stays pending.
    ioctl: [24]u8 align(8) = undefined,
    ioctl_in_use: bool = false,

    pub fn record_worker(self: *WifiShutdown, worker: *rtos.Task) void {
        if (self.worker != null) @panic("Wi-Fi driver started a second PP task in one session");
        self.worker = worker;
    }

    /// A failed step stays pending. A driver deinit the PP queue rejected
    /// returns WouldBlock; the caller retries.
    pub fn deinit(self: *WifiShutdown, caller: *rtos.Task, backend: anytype) wifi.InternalError!void {
        if (self.stage == .off) return;
        if (self.stage == .running) self.stage = .stop;

        if (self.stage == .stop) {
            try self.stop(caller, backend);
            self.stage = .supplicant;
        }
        if (self.stage == .supplicant) {
            // IDF v5.5.1 esp_wpa_main.c:529-538 destroys local state, then
            // returns the result of unregistering the WPA callbacks.
            self.stage = .unregister;
            try backend.deinit_supplicant();
            self.stage = .driver;
        }
        if (self.stage == .unregister) {
            try backend.unregister_wpa();
            self.stage = .driver;
        }
        if (self.stage == .driver) {
            // C6 esp_wifi_deinit_internal+0xf0..0xfa,+0x136 restores the
            // initialized state when ieee80211_ioctl+0x14e..0x18e cannot post
            // the deinit to the PP task. Keep ownership for retry.
            // ESP_ERR_WIFI_NOT_INIT (+0x6e..0x7e) leaves no driver to release.
            backend.deinit_driver() catch |err| switch (err) {
                error.WifiPost => return error.WouldBlock,
                error.WifiNotInitialized => {},
                else => return err,
            };
            self.stage = .release;
        }
        self.join_worker(backend);
        backend.release();
        self.* = .{};
    }

    // This join is bounded, also after ESP_ERR_WIFI_NOT_INIT. In C3/C6
    // libnet80211.a, s_wifi_init_state (static to ieee80211_api.o) is 1,
    // the NOT_INIT case of esp_wifi_deinit_internal+0x6e, at boot and
    // after the only two stores of 1: esp_wifi_deinit_internal+0x124
    // and the esp_wifi_init_internal rollback (+0x13a stores it,
    // +0x16c loads it). Both follow wifi_deinit_in_caller_task
    // (+0xfc, +0x144), whose
    // ic_delete_wifi_task call (+0xe) runs libpp.a pp_delete_task. That
    // deletes the PP task by handle (+0x3e or +0x54 into
    // pp_delete_task_manually+0x18) or posts the delete and waits for
    // ppTask's semaphore give (+0x84..0x90). After the give
    // (C3 ppTask+0xd4..0xe4, C6 +0xd6..0xe6), ppTask only deletes its queue
    // and clears two handles before calling task_delete(null) at C3 +0x10e
    // (argument and slot load at +0x108/+0x10a) or C6 +0x110 (+0x10a/+0x10c).
    pub fn join_worker(self: *WifiShutdown, backend: anytype) void {
        const task = self.worker orelse return;
        backend.join(task);
        rtos.free_exited_task(callback_allocator(), task);
        self.worker = null;
    }

    /// Stops the driver with the caller owning the reserved ioctl and with
    /// public disconnects held off. See `stop_driver`.
    pub fn stop(self: *WifiShutdown, caller: *rtos.Task, backend: anytype) wifi.InternalError!void {
        self.owner = caller;
        defer self.owner = null;
        disconnect_gate.close(if (wifi_test_host) no_wait else wait_one_tick);
        defer disconnect_gate.open();
        try stop_driver(backend);
        // ieee80211_ioctl+0x1c4 frees each synchronous ioctl before it returns.
        if (self.ioctl_in_use) @panic("Wi-Fi stop finished with its ioctl buffer still reserved");
    }

    pub fn reserve_ioctl(self: *WifiShutdown, caller: *rtos.Task, len: usize) ?*anyopaque {
        if (self.owner != caller or len != self.ioctl.len or self.ioctl_in_use) return null;
        self.ioctl_in_use = true;
        @memset(&self.ioctl, 0);
        return &self.ioctl;
    }

    pub fn release_ioctl(self: *WifiShutdown, ptr: ?*anyopaque) bool {
        if (ptr != @as(?*anyopaque, &self.ioctl)) return false;
        if (!self.ioctl_in_use) @panic("Wi-Fi blob freed the shutdown ioctl buffer twice");
        self.ioctl_in_use = false;
        return true;
    }

    /// A task that deletes itself exits without being freed. In the C3/C6 Wi-Fi
    /// blobs that is ppTask (C3 +0x10e, C6 +0x110), which teardown frees,
    /// and tasks the port never starts: libmesh's task mains and
    /// libwpa_supplicant.a's wpa2_task (+0x17e) and wps_task (+0x192), which
    /// only the WPA2-Enterprise and WPS APIs create (the port has neither).
    /// Starting any of them would leak its stack and TCB for the boot.
    pub fn delete_task(self: *WifiShutdown, handle: ?*anyopaque, current: *rtos.Task, comptime detach: anytype, comptime yield: anytype) void {
        const task: *rtos.Task = @ptrCast(@alignCast(handle orelse return yield(.exit)));
        if (task == current) return yield(.exit);
        detach(task);
        // During shutdown the caller joins both the manual and the normal
        // self-delete path, including rollback inside esp_wifi_init_internal.
        if (task != self.worker) rtos.free_exited_task(callback_allocator(), task);
    }
};

pub var wifi_shutdown: WifiShutdown = .{};

pub fn wifi_task_delete(handle: ?*anyopaque) callconv(.c) void {
    wifi_shutdown.delete_task(handle, rtos.get_current_task(), rtos.detach_task, rtos.yield);
}

pub fn wifi_shutdown_malloc(len: usize) callconv(.c) ?*anyopaque {
    if (!rtos.in_isr()) {
        if (wifi_shutdown.reserve_ioctl(rtos.get_current_task(), len)) |ptr| return ptr;
    }
    return malloc(len);
}

pub fn wifi_shutdown_zalloc(len: usize) callconv(.c) ?*anyopaque {
    if (!rtos.in_isr()) {
        if (wifi_shutdown.reserve_ioctl(rtos.get_current_task(), len)) |ptr| return ptr;
    }
    return zalloc_internal(len);
}

pub fn wifi_shutdown_free(ptr: ?*anyopaque) callconv(.c) void {
    if (!wifi_shutdown.release_ioctl(ptr)) free(ptr);
}

pub fn task_delay(tick: u32) callconv(.c) void {
    log.debug("task_delay {}", .{tick});

    rtos.sleep(.from_ticks(tick));
}

pub fn task_ms_to_tick(ms: u32) callconv(.c) i32 {
    return @intCast(rtos.Duration.from_ms(ms).to_ticks());
}

pub fn task_get_current_task() callconv(.c) ?*anyopaque {
    return rtos.get_current_task();
}

pub fn task_get_max_priority() callconv(.c) i32 {
    return @backingInt(rtos.Priority.highest);
}

pub fn esp_event_post(
    base: [*c]const u8,
    id: i32,
    data: ?*anyopaque,
    data_size: usize,
    ticks_to_wait: u32,
) callconv(.c) i32 {
    log.debug("esp_event_post {*} {} {?} {} {}", .{ base, id, data, data_size, ticks_to_wait });
    wifi.on_event_post(id, data, data_size);
    return 0;
}

pub fn get_free_heap_size() callconv(.c) void {
    @panic("get_free_heap_size: not implemented");
}

pub fn rand() callconv(.c) u32 {
    return rng.random_u32();
}

pub fn dport_access_stall_other_cpu_start_wrap() callconv(.c) void {
    log.debug("dport_access_stall_other_cpu_start_wrap", .{});
}

pub fn dport_access_stall_other_cpu_end_wrap() callconv(.c) void {
    log.debug("dport_access_stall_other_cpu_end_wrap", .{});
}

pub fn wifi_apb80m_request() callconv(.c) void {
    log.debug("wifi_apb80m_request", .{});
}

pub fn wifi_apb80m_release() callconv(.c) void {
    log.debug("wifi_apb80m_release", .{});
}

const CONFIG_ESP32_PHY_MAX_TX_POWER: u8 = 20;

fn limit(val: u8, low: u8, high: u8) u8 {
    return if (val < low) low else if (val > high) high else val;
}

/// PHY init data. The layout is chip specific and the blob reads it as is: the esp32c3 table
/// does not describe the esp32c6 PHY.
const phy_init_data_default: c.esp_phy_init_data_t = switch (compatibility.chip) {
    .esp32_c3 => phy_init_data_esp32_c3,
    .esp32_c6 => phy_init_data_esp32_c6,
};

/// ESP-IDF components/esp_phy/esp32c6/phy_init_data.c (Apache-2.0): two config bytes, the
/// 18 per-rate TX power limits, zero padding and the trailing 0x51.
const phy_init_data_esp32_c6: c.esp_phy_init_data_t = .{ .params = blk: {
    const tx_power_limits = [18]u8{ 0x54, 0x54, 0x50, 0x50, 0x50, 0x4c, 0x4c, 0x4c, 0x4c, 0x48, 0x44, 0x3c, 0x3c, 0x3c, 0x4c, 0x4c, 0x4c, 0x48 };
    var params: [128]u8 = @splat(0);
    params[0] = 0x0a;
    for (tx_power_limits, 0..) |high, i| params[2 + i] = limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, high);
    params[127] = 0x51;
    break :blk params;
} };

const phy_init_data_esp32_c3: c.esp_phy_init_data_t = .{
    .params = .{
        0x00,
        0x00,
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x50),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x50),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x50),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x4c),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x4c),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x48),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x4c),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x48),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x48),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x44),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x4a),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x46),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x46),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x42),
        0x00,
        0x00,
        0x00,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0x74,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    },
};

fn clocks_phy_set_enabled(enable: bool) void {
    switch (compatibility.chip) {
        .esp32_c3 => clocks_phy_set_enabled_c3(enable),
        .esp32_c6 => clocks_c6.phy_clocks_set_enabled(enable),
    }
}

fn clocks_phy_set_enabled_c3(enable: bool) void {
    const APB_CTRL = peripherals.APB_CTRL;
    const system_wifi_clk_wifi_bt_common_m: u32 = 0x78078F;

    var wifi_clk_en = APB_CTRL.WIFI_CLK_EN.read().WIFI_CLK_EN;
    if (enable) {
        wifi_clk_en |= system_wifi_clk_wifi_bt_common_m;
    } else {
        wifi_clk_en &= ~system_wifi_clk_wifi_bt_common_m;
    }
    APB_CTRL.WIFI_CLK_EN.write(.{ .WIFI_CLK_EN = wifi_clk_en });
}

// ESP-IDF phy_init.c / phy_common.c lifecycle. The selected protocol is
// exclusive for this image; Wi-Fi retains its adapter enable/disable calls.
// These OS adapter entry points and the timer callback run in task context.
const phy = struct {
    const is_wifi = !microzig.options.hal.radio.radios.ieee802154;
    extern fn phy_init_param_set(param: u8) void;
    extern fn phy_wifi_enable_set(enabled: u8) void;
    extern fn phy_bbpll_en_usb(enabled: bool) void;
    extern fn phy_wakeup_init() void;
    extern fn phy_close_rf() void;
    extern fn phy_xpd_tsens() void;
    extern fn phy_param_track_tot(wifi_enabled: bool, bt_enabled: bool) void;

    // Like IDF's _lock_acquire: calibration must allow interrupts/task scheduling.
    // Short blob register critical sections use the existing PHY OS callbacks.
    var mutex: rtos.Mutex = .{};
    var ref_count: u32 = 0;
    var calibrated = false;
    var tracking_timer: c.ets_timer = undefined;
    var last_tracking_us: u64 = 0;
    const tracking_period_us = 1_000_000; // IDF default ESP_PHY_PLL_TRACK_PERIOD_MS.

    fn track(_: ?*anyopaque) callconv(.c) void {
        mutex.lock();
        defer mutex.unlock();
        if (coex_enabled) {
            // phy_common.c:104-110 phy_track_pll_timer_callback. With no modem
            // enabled a dequeued callback finds nothing to track.
            if (modems.track(get_time_since_boot().to_us())) |groups| phy_param_track_tot(groups.wifi, groups.bt_154);
            return;
        }
        // A callback already dequeued when disarmed must not access a closed PHY.
        if (ref_count == 0) return;
        phy_param_track_tot(is_wifi, !is_wifi);
        last_tracking_us = get_time_since_boot().to_us();
    }

    fn enable() void {
        mutex.lock();
        defer mutex.unlock();

        if (ref_count == 0) {
            clocks_phy_set_enabled(true);
            if (compatibility.chip == .esp32_c6) clocks_c6.calibration_clocks_set_enabled(true);
            if (calibrated) {
                phy_wakeup_init();
            } else {
                phy_init_param_set(1);
                // Keep the PLL used by USB-Serial-JTAG during full calibration.
                phy_bbpll_en_usb(true);
                var cal_data: c.esp_phy_calibration_data_t = std.mem.zeroes(c.esp_phy_calibration_data_t);
                _ = c.register_chipv7_phy(&phy_init_data_default, &cal_data, c.PHY_RF_CAL_FULL);
                calibrated = true;
            }
            if (compatibility.chip == .esp32_c6) clocks_c6.calibration_clocks_set_enabled(false);
            timer.arm(&tracking_timer, .from_us(tracking_period_us), true);
        }
        ref_count = std.math.add(u32, ref_count, 1) catch @panic("PHY reference count overflow");
        // IDF also tracks on enable if more than a period elapsed while disabled.
        const now = get_time_since_boot().to_us();
        if (now - last_tracking_us > tracking_period_us) {
            phy_param_track_tot(is_wifi, !is_wifi);
            last_tracking_us = now;
        }
        // IDF esp_adapter.c does this on every enable, after esp_phy_enable.
        if (is_wifi) phy_wifi_enable_set(1);
    }

    // Coexistence images share one PHY between modems, as IDF phy_init.c
    // esp_phy_enable/esp_phy_disable (308-415) do with per-modem flags.
    var modems: phy_modems.State = .{};

    fn enable_modem(modem: phy_modems.Modem) void {
        mutex.lock();
        defer mutex.unlock();
        if (modems.enable(modem)) {
            clocks_phy_set_enabled(true);
            // phy_init.c:276-288: only BT and 802.15.4 open the calibration
            // clocks; Wi-Fi's own clocks already include the baseband.
            const calibration_clocks = modem != .wifi;
            if (calibration_clocks) clocks_c6.calibration_clocks_set_enabled(true);
            if (calibrated) {
                phy_wakeup_init();
            } else {
                phy_init_param_set(1);
                phy_bbpll_en_usb(true);
                var cal_data: c.esp_phy_calibration_data_t = std.mem.zeroes(c.esp_phy_calibration_data_t);
                _ = c.register_chipv7_phy(&phy_init_data_default, &cal_data, c.PHY_RF_CAL_FULL);
                calibrated = true;
            }
            if (calibration_clocks) clocks_c6.calibration_clocks_set_enabled(false);
            timer.arm(&tracking_timer, .from_us(phy_modems.track_period_us), true);
        }
        // phy_init.c:369-370: track immediately when a group is overdue.
        if (modems.track_if_due(get_time_since_boot().to_us())) |groups| phy_param_track_tot(groups.wifi, groups.bt_154);
        // esp_adapter.c:558-562 sets the Wi-Fi enable after esp_phy_enable.
        if (modem == .wifi) phy_wifi_enable_set(1);
    }

    fn disable_modem(modem: phy_modems.Modem) void {
        mutex.lock();
        defer mutex.unlock();
        // esp_adapter.c:564-568 clears the Wi-Fi enable before esp_phy_disable.
        if (modem == .wifi) phy_wifi_enable_set(0);
        if (!modems.disable(modem)) return;
        timer.disarm(&tracking_timer);
        phy_close_rf();
        phy_xpd_tsens();
        clocks_phy_set_enabled(false);
    }

    fn disable() void {
        mutex.lock();
        defer mutex.unlock();
        // IDF adapter does this even for an unbalanced disable.
        if (is_wifi) phy_wifi_enable_set(0);
        if (ref_count == 0) return;
        ref_count -= 1;
        if (ref_count != 0) return;

        timer.disarm(&tracking_timer);
        phy_close_rf();
        phy_xpd_tsens();
        // The pinned esp-wifi-sys C3/C6 libphy.a does not export
        // phy_wait_freq_hw_hop_done (IDF v6.0.2 does). No callable hop wait.
        clocks_phy_set_enabled(false);
    }
};

/// Preallocate the PLL timer before the blob can enable the PHY.
pub fn phy_timer_init(allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
    try timer.setfn(allocator, &phy.tracking_timer, phy.track, null);
}

pub fn phy_disable() callconv(.c) void {
    if (coex_enabled) phy.disable_modem(.wifi) else phy.disable();
}

pub fn phy_enable() callconv(.c) void {
    if (coex_enabled) phy.enable_modem(.wifi) else phy.enable();
}

/// The shared PHY for the BLE controller and 802.15.4 in coexistence images.
/// The Wi-Fi driver enables its modem through `phy_enable`.
pub fn phy_modem_enable(comptime modem: phy_modems.Modem) void {
    comptime assert(coex_enabled and modem != .wifi);
    phy.enable_modem(modem);
}

pub fn phy_modem_disable(comptime modem: phy_modems.Modem) void {
    comptime assert(coex_enabled and modem != .wifi);
    phy.disable_modem(modem);
}

pub fn phy_update_country_info(country: [*c]const u8) callconv(.c) c_int {
    log.debug("phy_update_country_info {s}", .{country});
    return -1;
}

pub fn read_mac(mac: [*c]u8, typ: c_uint) callconv(.c) c_int {
    log.debug("read_mac {*} {}", .{ mac, typ });

    const mac_tmp: [6]u8 = radio.read_mac(switch (typ) {
        0 => .sta,
        1 => .ap,
        2 => .bt,
        else => @panic("unknown mac typ"),
    });
    @memcpy(mac[0..6], &mac_tmp);

    return 0;
}

pub fn timer_arm(ets_timer_ptr: ?*anyopaque, ms: u32, repeat: bool) callconv(.c) void {
    timer_arm_us(ets_timer_ptr, ms * 1_000, repeat);
}

pub fn timer_disarm(ets_timer_ptr: ?*anyopaque) callconv(.c) void {
    log.debug("timer_disarm {?}", .{ets_timer_ptr});

    const ets_timer: *c.ets_timer = @ptrCast(@alignCast(ets_timer_ptr));
    timer.disarm(ets_timer);
}

pub fn timer_done(ets_timer_ptr: ?*anyopaque) callconv(.c) void {
    log.debug("timer_done {?}", .{ets_timer_ptr});

    const ets_timer: *c.ets_timer = @ptrCast(@alignCast(ets_timer_ptr));
    timer.done(callback_allocator(), ets_timer);
}

pub fn timer_setfn(ets_timer_ptr: ?*anyopaque, callback_ptr: ?*anyopaque, arg: ?*anyopaque) callconv(.c) void {
    log.debug("timer_setfn {?} {?} {?}", .{ ets_timer_ptr, callback_ptr, arg });

    const ets_timer: *c.ets_timer = @ptrCast(@alignCast(ets_timer_ptr));
    const callback: timer.CallbackFn = @ptrCast(@alignCast(callback_ptr));
    timer.setfn(callback_allocator(), ets_timer, callback, arg) catch {
        log.warn("failed to allocate timer", .{});
    };
}

pub fn timer_arm_us(ets_timer_ptr: ?*anyopaque, us: u32, repeat: bool) callconv(.c) void {
    log.debug("timer_arm_us {?} {} {}", .{ ets_timer_ptr, us, repeat });

    const ets_timer: *c.ets_timer = @ptrCast(@alignCast(ets_timer_ptr));
    timer.arm(ets_timer, .from_us(us), repeat);
}

pub fn wifi_reset_mac() callconv(.c) void {
    log.debug("wifi_reset_mac", .{});

    switch (compatibility.chip) {
        .esp32_c3 => {
            const APB_CTRL = peripherals.APB_CTRL;
            APB_CTRL.WIFI_RST_EN.write(.{ .WIFI_RST = APB_CTRL.WIFI_RST_EN.read().WIFI_RST | (1 << 2) });
            APB_CTRL.WIFI_RST_EN.write(.{ .WIFI_RST = APB_CTRL.WIFI_RST_EN.read().WIFI_RST & ~@as(u32, 1 << 2) });
        },
        // Same as esp-radio: no MAC reset on the C6. ESP-IDF v6.0.2 pulses MODEM_SYSCON
        // RST_WIFIMAC here; association works without it.
        .esp32_c6 => {},
    }
}

pub fn wifi_clock_enable() callconv(.c) void {
    log.debug("wifi_clock_enable", .{});

    // no op on esp32c3
    if (compatibility.chip == .esp32_c6) clocks_c6.wifi_clocks_set_enabled(true);
}

pub fn wifi_clock_disable() callconv(.c) void {
    log.debug("wifi_clock_disable", .{});

    // no op on esp32c3
    if (compatibility.chip == .esp32_c6) clocks_c6.wifi_clocks_set_enabled(false);
}

pub fn regdma_link_set_write_wait_content(_: ?*anyopaque, _: u32, _: u32) callconv(.c) void {
    log.err("regdma_link_set_write_wait_content: modem sleep retention is not supported", .{});
}

pub fn sleep_retention_find_link_by_id(_: c_int) callconv(.c) ?*anyopaque {
    log.err("sleep_retention_find_link_by_id: modem sleep retention is not supported", .{});
    return null;
}

pub fn wifi_rtc_enable_iso() callconv(.c) void {
    @panic("wifi_rtc_enable_iso: not implemented");
}

pub fn wifi_rtc_disable_iso() callconv(.c) void {
    @panic("wifi_rtc_disable_iso: not implemented");
}

pub fn esp_timer_get_time() callconv(.c) i64 {
    log.debug("esp_timer_get_time", .{});

    return @intCast(get_time_since_boot().to_us());
}

pub fn nvs_set_i8() callconv(.c) void {
    @panic("nvs_set_i8: not implemented");
}

pub fn nvs_get_i8() callconv(.c) void {
    @panic("nvs_get_i8: not implemented");
}

pub fn nvs_set_u8() callconv(.c) void {
    @panic("nvs_set_u8: not implemented");
}

pub fn nvs_get_u8() callconv(.c) void {
    @panic("nvs_get_u8: not implemented");
}

pub fn nvs_set_u16() callconv(.c) void {
    @panic("nvs_set_u16: not implemented");
}

pub fn nvs_get_u16() callconv(.c) void {
    @panic("nvs_get_u16: not implemented");
}

pub fn nvs_open() callconv(.c) void {
    @panic("nvs_open: not implemented");
}

pub fn nvs_close() callconv(.c) void {
    @panic("nvs_close: not implemented");
}

pub fn nvs_commit() callconv(.c) void {
    @panic("nvs_commit: not implemented");
}

pub fn nvs_set_blob() callconv(.c) void {
    @panic("nvs_set_blob: not implemented");
}

pub fn nvs_get_blob() callconv(.c) void {
    @panic("nvs_get_blob: not implemented");
}

pub fn nvs_erase_key() callconv(.c) void {
    @panic("nvs_erase_key: not implemented");
}

pub fn get_random(buf: [*c]u8, len: usize) callconv(.c) c_int {
    rng.read(buf[0..len]);
    return 0;
}

// ESP-IDF v6.0.2 wpa_supplicant/port/include/os.h: os_time_t is uint64_t.
const OsTime = extern struct { sec: u64, usec: c_long };

comptime {
    std.debug.assert(@offsetOf(OsTime, "usec") == 8);
    std.debug.assert(@sizeOf(OsTime) == 16);
}

pub fn get_time(t: ?*anyopaque) callconv(.c) c_int {
    const os_time: *OsTime = @ptrCast(@alignCast(t orelse return -1));
    const usec = get_time_since_boot().to_us();
    os_time.* = .{
        .sec = @intCast(usec / 1_000_000),
        .usec = @intCast(usec % 1_000_000),
    };
    return 0;
}

pub fn random() callconv(.c) c_ulong {
    return rng.random_u32();
}

pub fn slowclk_cal_get() callconv(.c) u32 {
    return switch (compatibility.chip) {
        .esp32_c3 => 28639,
        .esp32_c6 => clocks_c6.slowclk_cal(),
    };
}

pub fn log_write(_: c_uint, _: [*c]const u8, fmt: [*c]const u8, ...) callconv(.c) void {
    syslog(fmt, @cVaStart());
}

pub fn log_writev(_: c_uint, _: [*c]const u8, fmt: [*c]const u8, va_list: c.va_list) callconv(.c) void {
    syslog(fmt, @ptrCast(va_list));
}

pub fn log_timestamp() callconv(.c) u32 {
    return @truncate(get_time_since_boot().to_us() * 1_000);
}

pub const malloc_internal = malloc;

pub fn realloc_internal(ptr: ?*anyopaque, len: usize) callconv(.c) ?*anyopaque {
    log.debug("realloc {?} {}", .{ ptr, len });

    const old = ptr orelse return malloc(len);
    if (len == 0) {
        free(old);
        return null;
    }

    const old_len: *const usize = @ptrFromInt(@intFromPtr(old) - 8);
    const new = malloc(len) orelse return null; // the old block stays valid, as in C
    const copy_len = @min(old_len.*, len);
    @memcpy(@as([*]u8, @ptrCast(new))[0..copy_len], @as([*]const u8, @ptrCast(old))[0..copy_len]);
    free(old);
    return new;
}

pub const calloc_internal = calloc;

pub fn zalloc_internal(len: usize) callconv(.c) ?*anyopaque {
    if (malloc(len)) |ptr| {
        @memset(@as([*]u8, @ptrCast(ptr))[0..len], 0);
        return ptr;
    }

    return null;
}

pub const wifi_malloc = malloc;

pub const wifi_realloc = realloc_internal;

pub const wifi_calloc = calloc;
pub const wifi_zalloc = zalloc_internal;

var wifi_queue_handle: ?*QueueWrapper = null;
var wifi_queue: QueueWrapper = undefined;

extern var s_pp_task_create_sem: ?*anyopaque;
extern var xphyQueue: ?*anyopaque;
pub const WifiPpSlots = PpDeleteCallbacks(&s_pp_task_create_sem, &xphyQueue);

fn PpDeleteCallbacks(comptime create_sem: *?*anyopaque, comptime phy_queue: *?*anyopaque) type {
    return struct {
        pub fn delete_sem(ptr: ?*anyopaque) callconv(.c) void {
            // C3/C6 pp_create_task frees the startup semaphore on task-create
            // failure, but only the success path clears s_pp_task_create_sem.
            if (create_sem.* == ptr) create_sem.* = null;
            semphr_delete(ptr);
        }

        pub fn delete_queue(ptr: ?*anyopaque) callconv(.c) void {
            // pp_create_task copies *s_wifi_queue into xphyQueue.
            // pp_delete_task_manually clears only s_wifi_queue.
            const handle: *?*QueueWrapper = @ptrCast(@alignCast(ptr));
            if (phy_queue.* == @as(?*anyopaque, @ptrCast(handle.*))) phy_queue.* = null;
            wifi_delete_queue(ptr);
        }
    };
}

test "PP rollback clears ROM aliases before freeing the queue and startup semaphore" {
    const Slots = struct {
        var create_sem: ?*anyopaque = null;
        var phy_queue: ?*anyopaque = null;
    };
    const callbacks = PpDeleteCallbacks(&Slots.create_sem, &Slots.phy_queue);
    var route: @import("shared_heap.zig").TestRoute = .{};
    route.install(std.testing.allocator);
    defer route.restore();
    for (0..2) |_| {
        const queue = wifi_create_queue(4, 8) orelse return error.OutOfMemory;
        Slots.phy_queue = @ptrCast(wifi_queue_handle);
        Slots.create_sem = semphr_create(1, 0) orelse return error.OutOfMemory;
        const other = semphr_create(1, 0) orelse return error.OutOfMemory;
        callbacks.delete_sem(other);
        try std.testing.expect(Slots.create_sem != null);
        callbacks.delete_sem(Slots.create_sem);
        callbacks.delete_queue(queue);
        try std.testing.expect(Slots.create_sem == null and Slots.phy_queue == null and wifi_queue_handle == null);
    }
}

pub fn wifi_create_queue(capacity: c_int, item_len: c_int) callconv(.c) ?*anyopaque {
    log.debug("wifi_create_queue {} {}", .{ capacity, item_len });

    if (capacity <= 0 or item_len <= 0) return null;
    const width: u32 = @intCast(item_len);
    const len = queue_buffer_len(@intCast(capacity), width) orelse return null;
    std.debug.assert(wifi_queue_handle == null);

    const buf: []u8 = callback_allocator().alloc(u8, len) catch {
        log.warn("failed to allocate queue buffer", .{});
        return null;
    };

    wifi_queue = .{
        .inner = .init(buf),
        .item_len = width,
    };
    wifi_queue_handle = &wifi_queue;

    log.debug(">>>> wifi queue create: {*}", .{&wifi_queue_handle});

    return @ptrCast(&wifi_queue_handle);
}

pub fn wifi_delete_queue(ptr: ?*anyopaque) callconv(.c) void {
    log.debug("wifi_delete_queue {?}", .{ptr});

    std.debug.assert(ptr == @as(?*anyopaque, @ptrCast(&wifi_queue_handle)));

    const queue: *?*QueueWrapper = @ptrCast(@alignCast(ptr));
    callback_allocator().free(queue.*.?.inner.buffer);

    wifi_queue_handle = null;
    wifi_queue = undefined;
}

pub fn coex_init() callconv(.c) c_int {
    log.debug("coex_init", .{});

    return if (coex_enabled) c.coex_init() else 0;
}

pub fn coex_deinit() callconv(.c) void {
    log.debug("coex_deinit", .{});

    if (coex_enabled) c.coex_deinit();
}

pub fn coex_enable() callconv(.c) c_int {
    log.debug("coex_enable", .{});

    return if (coex_enabled) c.coex_enable() else 0;
}

pub fn coex_disable() callconv(.c) void {
    log.debug("coex_disable", .{});

    if (coex_enabled) c.coex_disable();
}

pub fn coex_status_get() callconv(.c) u32 {
    log.debug("coex_status_get", .{});

    return if (coex_enabled) coex.coex_status_get(1) else 0;
}

pub fn coex_condition_set() callconv(.c) void {
    @panic("coex_condition_set");
}

pub fn coex_wifi_request(
    event: u32,
    latency: u32,
    duration: u32,
) callconv(.c) c_int {
    log.debug("coex_wifi_request", .{});

    return if (coex_enabled) c.coex_wifi_request(event, latency, duration) else 0;
}

pub fn coex_wifi_release(event: u32) callconv(.c) c_int {
    log.debug("coex_wifi_release", .{});

    return if (coex_enabled) c.coex_wifi_release(event) else 0;
}

pub fn coex_wifi_channel_set(
    primary: u8,
    secondary: u8,
) callconv(.c) c_int {
    log.debug("coex_wifi_channel_set", .{});

    return if (coex_enabled) c.coex_wifi_channel_set(primary, secondary) else 0;
}

pub fn coex_event_duration_get(event: u32, duration: [*c]u32) callconv(.c) c_int {
    log.debug("coex_event_duration_get", .{});

    return if (coex_enabled) c.coex_event_duration_get(event, duration) else 0;
}

pub fn coex_pti_get(event: u32, pti: [*c]u8) callconv(.c) c_int {
    log.debug("coex_pti_get", .{});

    return if (coex_enabled) c.coex_pti_get(event, pti) else 0;
}

pub fn coex_schm_status_bit_clear(@"type": u32, status: u32) callconv(.c) void {
    if (!coex_enabled) log.debug("coex_schm_status_bit_clear", .{});

    if (coex_enabled) c.coex_schm_status_bit_clear(@"type", status);
}

pub fn coex_schm_status_bit_set(@"type": u32, status: u32) callconv(.c) void {
    if (!coex_enabled) log.debug("coex_schm_status_bit_set", .{});

    if (coex_enabled) c.coex_schm_status_bit_set(@"type", status);
}

pub fn coex_schm_interval_set(interval: u32) callconv(.c) c_int {
    log.debug("coex_schm_interval_set", .{});

    return if (coex_enabled) c.coex_schm_interval_set(interval) else 0;
}

pub fn coex_schm_interval_get() callconv(.c) u32 {
    log.debug("coex_schm_interval_get", .{});

    return if (coex_enabled) c.coex_schm_interval_get() else 0;
}

pub fn coex_schm_curr_period_get() callconv(.c) u8 {
    log.debug("coex_schm_curr_period_get", .{});

    return if (coex_enabled) c.coex_schm_curr_period_get() else 0;
}

pub fn coex_schm_curr_phase_get() callconv(.c) ?*anyopaque {
    log.debug("coex_schm_curr_phase_get", .{});

    return if (coex_enabled) c.coex_schm_curr_phase_get() else null;
}

pub fn coex_schm_process_restart() callconv(.c) c_int {
    log.debug("coex_schm_process_restart", .{});

    return if (coex_enabled) c.coex_schm_process_restart() else 0;
}

pub fn coex_schm_register_cb(
    @"type": c_int,
    callback: ?*const fn (c_int) callconv(.c) c_int,
) callconv(.c) c_int {
    log.debug("coex_schm_register_cb", .{});

    return if (coex_enabled) c.coex_schm_register_callback(@bitCast(@"type"), @ptrCast(@constCast(callback))) else 0;
}

pub fn coex_register_start_cb(cb: ?*const fn () callconv(.c) c_int) callconv(.c) c_int {
    log.debug("coex_register_start_cb", .{});

    return if (coex_enabled) c.coex_register_start_cb(cb) else 0;
}

pub fn coex_schm_flexible_period_set(period: u8) callconv(.c) c_int {
    log.debug("coex_schm_flexible_period_set {}", .{period});

    return 0;
}

pub fn coex_schm_flexible_period_get() callconv(.c) u8 {
    log.debug("coex_schm_flexible_period_get", .{});

    return if (coex_enabled) 1 else 0;
}

test "queue creation widens only the legacy supplicant shape" {
    var route: @import("shared_heap.zig").TestRoute = .{};
    route.install(std.testing.allocator);
    defer route.restore();

    for ([_]struct { capacity: u32, requested: u32, stored: u32 }{
        .{ .capacity = 10, .requested = 4, .stored = 4 },
        .{ .capacity = 3, .requested = 12, .stored = 12 },
        .{ .capacity = 3, .requested = 8, .stored = 8 },
        .{ .capacity = 3, .requested = 4, .stored = 8 },
    }) |shape| {
        const handle = queue_create(shape.capacity, shape.requested) orelse return error.OutOfMemory;
        defer queue_delete(handle);
        const queue: *QueueWrapper = @ptrCast(@alignCast(handle));
        try std.testing.expectEqual(shape.stored, queue.item_len);
        try std.testing.expectEqual(shape.capacity * shape.stored, queue.inner.buffer.len);
    }
}

test "OSI size validation rejects invalid requests before the allocator" {
    var rejecting = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var route: @import("shared_heap.zig").TestRoute = .{};
    route.install(rejecting.allocator());
    defer route.restore();

    try std.testing.expect(queue_create(0, 4) == null);
    try std.testing.expect(queue_create(3, 0) == null);
    try std.testing.expect(queue_create(1_073_741_825, 4) == null);
    try std.testing.expect(queue_create(3, std.math.maxInt(u32) / 3 + 1) == null);
    try std.testing.expect(wifi_create_queue(0, 4) == null);
    try std.testing.expect(wifi_create_queue(3, 0) == null);
    try std.testing.expect(wifi_create_queue(-3, -4) == null);
    try std.testing.expect(wifi_create_queue(std.math.maxInt(c_int), 3) == null);

    try std.testing.expect(malloc(0) == null);
    try std.testing.expect(malloc(std.math.maxInt(usize) - 7) == null);
    try std.testing.expect(calloc(0, 1) == null);
    try std.testing.expect(calloc(std.math.maxInt(usize) / 2 + 1, 2) == null);
    try std.testing.expect(calloc(1, std.math.maxInt(usize)) == null);
    try std.testing.expect(wifi_zalloc(0) == null);
    try std.testing.expect(wifi_realloc(null, std.math.maxInt(usize)) == null);
    try std.testing.expect(semphr_create(0, 0) == null);
    try std.testing.expect(semphr_create(1, 2) == null);
    try std.testing.expect(!rejecting.has_induced_failure);
}

test "an overflowing OSI reallocation keeps the old allocation" {
    var route: @import("shared_heap.zig").TestRoute = .{};
    route.install(std.testing.allocator);
    defer route.restore();

    const old = wifi_malloc(8) orelse return error.OutOfMemory;
    defer free(old);
    const bytes: *[8]u8 = @ptrCast(old);
    @memcpy(bytes, "retained");
    try std.testing.expect(wifi_realloc(old, std.math.maxInt(usize)) == null);
    try std.testing.expectEqualStrings("retained", bytes);
}

test "a deleted blob task is freed into the callback route, the PP task only by teardown" {
    const Host = struct {
        var detached: usize = 0;
        fn detach(task: *rtos.Task) void {
            task.state = .exited;
            detached += 1;
        }
        fn yield(_: rtos.YieldAction) void {
            unreachable; // the caller deletes another task
        }
        fn spawn() !*rtos.Task {
            const mem = try callback_allocator().alignedAlloc(u8, .@"16", @sizeOf(rtos.Task) + 64);
            const task: *rtos.Task = @ptrCast(mem.ptr);
            task.* = .{ .context = undefined, .stack = mem[@sizeOf(rtos.Task)..], .priority = .lowest, .allocation_alignment = .@"16" };
            return task;
        }
    };
    var accounting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var route: @import("shared_heap.zig").TestRoute = .{};
    route.install(accounting.allocator());
    defer route.restore();
    var caller: rtos.Task = undefined;
    var shutdown: WifiShutdown = .{};
    const pp = try Host.spawn();
    shutdown.record_worker(pp);
    const other = try Host.spawn();
    shutdown.delete_task(other, &caller, Host.detach, Host.yield);
    try std.testing.expect(Host.detached == 1 and accounting.deallocations == 1);
    shutdown.delete_task(pp, &caller, Host.detach, Host.yield);
    try std.testing.expect(Host.detached == 2 and pp.state == .exited and accounting.deallocations == 1);
    rtos.free_exited_task(callback_allocator(), pp);
    try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
}

const TeardownBackend = struct {
    shutdown: *WifiShutdown,
    caller: *rtos.Task,
    queue: std.ArrayList(u8),
    // The driver deinit's answer once the post succeeds: 0 or ESP_ERR_WIFI_NOT_INIT.
    deinit_result: i32 = 0,
    // The heap has no 24 bytes for the driver deinit's ioctl.
    no_heap: bool = false,
    stops: usize = 0,
    stop_reserved: bool = false,
    supplicant_deinits: usize = 0,
    driver_initialized: bool = true,
    joined: ?*rtos.Task = null,
    released: bool = false,

    pub fn stop(self: *@This()) wifi.InternalError!void {
        self.stops += 1;
        const ioctl = self.shutdown.reserve_ioctl(self.caller, 24) orelse return error.OutOfMemory;
        self.stop_reserved = true;
        assert(self.shutdown.release_ioctl(ioctl));
    }

    pub fn driver_started(_: *@This()) bool {
        return false;
    }

    fn deinit_supplicant(self: *@This()) wifi.InternalError!void {
        // Outside the stop the caller is offered no reserved ioctl.
        assert(self.shutdown.reserve_ioctl(self.caller, 24) == null);
        self.supplicant_deinits += 1;
    }

    fn unregister_wpa(_: *@This()) wifi.InternalError!void {
        unreachable;
    }

    fn deinit_driver(self: *@This()) wifi.InternalError!void {
        // esp_wifi_deinit_internal+0xd8 takes its ioctl from the heap.
        assert(self.shutdown.reserve_ioctl(self.caller, 24) == null);
        // +0xe0 / +0x132..0x140: ESP_ERR_NO_MEM with the initialized state restored.
        if (self.no_heap) return wifi.c_err(0x101);
        self.queue.appendBounded(1) catch return wifi.c_err(0x3012);
        self.driver_initialized = false;
        try wifi.c_err(self.deinit_result);
    }

    fn join(self: *@This(), task: *rtos.Task) void {
        task.state = .exited;
        self.joined = task;
    }

    fn release(self: *@This()) void {
        assert(self.joined != null);
        self.released = true;
    }

    // A PP task from the callback route; teardown returns it there.
    fn spawn_worker() !*rtos.Task {
        const mem = try callback_allocator().alignedAlloc(u8, .@"16", @sizeOf(rtos.Task) + 64);
        const worker: *rtos.Task = @ptrCast(mem.ptr);
        worker.* = .{ .context = undefined, .stack = mem[@sizeOf(rtos.Task)..], .priority = .lowest, .allocation_alignment = .@"16" };
        return worker;
    }
};

test "a failed deinit ioctl can be posted after the packet worker drains its queue" {
    var route: @import("shared_heap.zig").TestRoute = .{};
    route.install(std.testing.allocator);
    defer route.restore();
    var caller: rtos.Task = undefined;
    const worker = try TeardownBackend.spawn_worker();
    var shutdown: WifiShutdown = .{ .stage = .running };
    var buffer: [1]u8 = undefined;
    var backend: TeardownBackend = .{ .shutdown = &shutdown, .caller = &caller, .queue = .initBuffer(&buffer) };
    shutdown.record_worker(worker);
    backend.queue.appendAssumeCapacity(0);
    try std.testing.expectError(error.WouldBlock, shutdown.deinit(&caller, &backend));
    try std.testing.expect(backend.driver_initialized and backend.joined == null and !backend.released);
    try std.testing.expect(shutdown.stage == .driver and shutdown.worker == worker);
    try std.testing.expect(shutdown.owner == null and !shutdown.ioctl_in_use);
    try std.testing.expectEqual(0, backend.queue.pop().?);
    try shutdown.deinit(&caller, &backend);
    try std.testing.expect(!backend.driver_initialized and backend.joined == worker and backend.released);
    try std.testing.expect(shutdown.stage == .off and shutdown.worker == null);
    try std.testing.expect(backend.stops == 1 and backend.stop_reserved and backend.supplicant_deinits == 1);
    try std.testing.expectError(error.WifiOther, wifi.c_err(-1));
}

test "a driver deinit without heap for its ioctl stays pending and is retried" {
    var route: @import("shared_heap.zig").TestRoute = .{};
    route.install(std.testing.allocator);
    defer route.restore();
    var caller: rtos.Task = undefined;
    const worker = try TeardownBackend.spawn_worker();
    var shutdown: WifiShutdown = .{ .stage = .running };
    var buffer: [1]u8 = undefined;
    var backend: TeardownBackend = .{ .shutdown = &shutdown, .caller = &caller, .queue = .initBuffer(&buffer), .no_heap = true };
    shutdown.record_worker(worker);
    try std.testing.expectError(error.OutOfMemory, shutdown.deinit(&caller, &backend));
    try std.testing.expect(backend.driver_initialized and backend.joined == null and !backend.released);
    try std.testing.expect(shutdown.stage == .driver and shutdown.worker == worker);
    backend.no_heap = false;
    try shutdown.deinit(&caller, &backend);
    try std.testing.expect(!backend.driver_initialized and backend.joined == worker and backend.released);
    try std.testing.expect(shutdown.stage == .off and backend.stops == 1 and backend.supplicant_deinits == 1);
}

test "a driver deinit answered with NOT_INIT joins and frees the PP task" {
    var accounting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var route: @import("shared_heap.zig").TestRoute = .{};
    route.install(accounting.allocator());
    defer route.restore();
    var caller: rtos.Task = undefined;
    const worker = try TeardownBackend.spawn_worker();
    var shutdown: WifiShutdown = .{ .stage = .running };
    var buffer: [1]u8 = undefined;
    var backend: TeardownBackend = .{ .shutdown = &shutdown, .caller = &caller, .queue = .initBuffer(&buffer), .deinit_result = 0x3001 };
    shutdown.record_worker(worker);
    try shutdown.deinit(&caller, &backend);
    try std.testing.expect(backend.joined == worker and backend.released);
    try std.testing.expect(shutdown.stage == .off and shutdown.worker == null);
    try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
}
