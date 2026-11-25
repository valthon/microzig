/// ESP Wi-Fi drivers integration.
///
/// Based on https://github.com/esp-rs/esp-hal/tree/main/esp-radio.
const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const c = @import("esp-wifi-driver");
const microzig = @import("microzig");
const TrapFrame = microzig.cpu.TrapFrame;
const peripherals = microzig.chip.peripherals;
const compatibility = @import("compatibility.zig");
const clocks_c6 = @import("analog/esp32_c6.zig");

const efuse = @import("efuse.zig");
pub const bluetooth = @import("radio/bluetooth.zig");
const osi = @import("radio/osi.zig");
const timer = @import("radio/timer.zig");
const callbacks = @import("radio/callback_context.zig");
pub const espnow = @import("radio/espnow.zig");
pub const wifi = @import("radio/wifi.zig");
pub const ieee802154 = if (compatibility.chip == .esp32_c6) @import("radio/ieee802154.zig") else void;

const log = std.log.scoped(.esp_radio);

const selection = @import("radio/radios.zig");
pub const Radios = selection.Radios;
pub const coex_enabled = microzig.options.hal.radio.radios.coexistence();

pub const Options = struct {
    radios: Radios = selection.default,
    interrupt: microzig.cpu.Interrupt = .interrupt30,
    wifi: wifi.Options = .{},
};

var coex_init_mutex: if (callbacks.host_test) microzig.radio_test.Mutex else @import("rtos.zig").Mutex = .{};
var refcount: std.atomic.Value(usize) = .init(0);

pub const InitError = Allocator.Error || error{ CpuClockNotPll, SlowClockCalibrationTimeout } ||
    (if (coex_enabled) (@import("radio/coex_abi.zig").InitError || error{ WouldBlock, SharedHeapNotAttached }) else error{});

const shared_heap = @import("radio/shared_heap.zig");

/// The heap a coexistence image's radios share. It backs the blob OSI
/// adapter's allocations and the radio HAL's own init allocations: the
/// radio timer worker, the PHY and coex timer nodes, and the Wi-Fi eloop
/// reservation. In a coexistence image the allocator argument of `init` and
/// `wifi.init` is not used; the BLE controller's allocator still backs its
/// NPL state. Either radio can be torn down while the other runs, so this
/// storage cannot come from either radio's allocator.
///
/// The application owns the buffer and this handle. Both must stay valid,
/// unmoved and otherwise unused for the rest of the boot: the blobs keep
/// allocations from it after every radio has been deinitialized.
pub const SharedHeap = shared_heap.SharedHeap;

pub const AttachError = error{ SharedHeapAlreadyAttached, WouldBlock };

/// Attach the shared heap once, from task context, before the first radio
/// init of a coexistence image. Until then every radio init returns
/// `error.SharedHeapNotAttached`. A second attach returns
/// `error.SharedHeapAlreadyAttached` and leaves the first heap in use.
///
/// The attach writes the image's one allocator route: the blob OSI
/// callbacks, which take no context argument, and the radio code that frees
/// what they allocated read their allocator from it for the rest of the boot.
pub fn attach_shared_heap(heap: *SharedHeap) AttachError!void {
    if (!coex_enabled) @compileError("attach_shared_heap requires a coexistence radio selection; single-radio inits take their allocator");
    if (callbacks.active()) return error.WouldBlock;
    coex_init_mutex.lock();
    defer coex_init_mutex.unlock();
    try shared_heap.attach(heap);
}

/// In a coexistence image the radio allocates from the attached
/// `SharedHeap` and `session_allocator` is not used. The parameter stays so
/// that `init` has one signature in every radio selection; single-radio
/// images allocate from it.
pub fn init(session_allocator: Allocator) InitError!void {
    if (coex_enabled and callbacks.active()) return error.WouldBlock;
    {
        // C6 TRM v1.2 §8.2.4.4: Wi-Fi requires the PLL CPU clock source.
        // Read hardware so custom hal.init_sequence clock configurations are checked too.
        const source = if (callbacks.host_test) microzig.radio_test.clock_source else switch (compatibility.chip) {
            .esp32_c3 => peripherals.SYSTEM.SYSCLK_CONF.read().SOC_CLK_SEL,
            .esp32_c6 => peripherals.PCR.SYSCLK_CONF.read().SOC_CLK_SEL,
        };
        if (source != 1) return error.CpuClockNotPll;

        comptime {
            if (!microzig.options.hal.rtos.enable)
                @compileError("radio requires the rtos option to be enabled");

            if (!callbacks.host_test) {
                microzig.cpu.interrupt.expect_handler(microzig.options.hal.radio.interrupt, interrupt_handler);
                osi.export_symbols();
            }
        }
    }
    if (coex_enabled) coex_init_mutex.lock();
    defer if (coex_enabled) coex_init_mutex.unlock();
    const gpa = if (coex_enabled) try shared_heap.allocator() else session_allocator;
    if (refcount.rmw(.Add, 1, .monotonic) > 0) {
        return;
    }

    errdefer _ = refcount.rmw(.Sub, 1, .monotonic);
    if (callbacks.host_test) return HostResources.start(gpa);
    const radio_interrupt = microzig.options.hal.radio.interrupt;
    try timer.init(gpa);
    errdefer timer.deinit(gpa);
    try osi.phy_timer_init(gpa);

    {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();

        enable_wifi_power_domain_and_init_clocks();
        // phy_mem_init(); // only sets some global variable on esp32c3

        // A coexistence image routes the callbacks from attach_shared_heap.
        if (!coex_enabled) osi.gpa = gpa;

        microzig.cpu.interrupt.map(.wifi_mac, radio_interrupt);
        microzig.cpu.interrupt.map(.wifi_pwr, radio_interrupt);
        microzig.cpu.interrupt.set_type(radio_interrupt, .level);
        microzig.cpu.interrupt.set_priority(radio_interrupt, .highest);
    }

    if (compatibility.chip == .esp32_c6) try clocks_c6.calibrate_slow_clock();

    if (coex_enabled) try @import("radio/coex.zig").init(gpa);

    log.debug("initialization complete", .{});

    const internal_wifi_log_level = switch (builtin.mode) {
        .Debug => c.WIFI_LOG_VERBOSE,
        else => c.WIFI_LOG_NONE,
    };
    // BLE-only images leave the Wi-Fi blob's log level alone.
    const radios = microzig.options.hal.radio.radios;
    if (!radios.ble or radios.wifi) wifi.c_err(c.esp_wifi_internal_set_log_level(internal_wifi_log_level)) catch {
        log.warn("failed to set wifi internal log level", .{});
    };
}

pub fn deinit() if (coex_enabled) error{WouldBlock}!void else void {
    if (coex_enabled and callbacks.active()) return error.WouldBlock;
    if (coex_enabled) coex_init_mutex.lock();
    defer if (coex_enabled) coex_init_mutex.unlock();
    const prev_count = refcount.rmw(.Sub, 1, .monotonic);
    assert(prev_count != 0);
    if (prev_count != 1) {
        return;
    }

    // The worker and its nodes came from this route: the attached heap in a
    // coexistence image, the first owner's allocator in a single-radio image.
    const gpa = osi.callback_allocator();
    if (callbacks.host_test) HostResources.stop(gpa);
    timer.deinit(gpa);
}

/// Semaphore slot counters for a coexistence image. `task_calls` counts
/// take/give calls on the task slots, which the coex scheme locks and every
/// Wi-Fi driver semaphore share; `from_isr_calls` counts the from-ISR slots,
/// which only the coex core lock uses. An interrupt entry into a task slot
/// panics rather than counting. Coexistence images only.
pub fn coex_semaphore_stats() @import("radio/coex.zig").SemaphoreStats {
    if (!coex_enabled) @compileError("coex_semaphore_stats requires a coexistence radio selection");
    return @import("radio/coex.zig").semaphore_stats();
}

pub fn read_mac(iface: enum {
    sta,
    ap,
    bt,
}) [6]u8 {
    var mac = efuse.read_mac();
    switch (iface) {
        .sta => {},
        .ap => mac[5] += 1,
        .bt => mac[5] += 2,
    }
    return mac;
}

fn enable_wifi_power_domain_and_init_clocks() void {
    switch (compatibility.chip) {
        .esp32_c3 => enable_wifi_power_domain_and_init_clocks_c3(),
        .esp32_c6 => clocks_c6.radio_init(),
    }
}

fn enable_wifi_power_domain_and_init_clocks_c3() void {
    const RTC_CNTL = peripherals.RTC_CNTL;
    const APB_CTRL = peripherals.APB_CTRL;

    const system_wifibb_rst: u32 = 1 << 0;
    const system_fe_rst: u32 = 1 << 1;
    const system_wifimac_rst: u32 = 1 << 2;
    const system_btbb_rst: u32 = 1 << 3; // bluetooth baseband
    const system_btmac_rst: u32 = 1 << 4; // deprecated
    const system_rw_btmac_rst: u32 = 1 << 9; // bluetooth mac
    const system_rw_btmac_reg_rst: u32 = 1 << 11; // bluetooth mac registers
    const system_btbb_reg_rst: u32 = 1 << 13; // bluetooth baseband registers

    const modem_reset_field_when_pu: u32 = system_wifibb_rst |
        system_fe_rst |
        system_wifimac_rst |
        system_btbb_rst |
        system_btmac_rst |
        system_rw_btmac_rst |
        system_rw_btmac_reg_rst |
        system_btbb_reg_rst;

    RTC_CNTL.DIG_PWC.modify(.{
        .WIFI_FORCE_PD = 0,
        .BT_FORCE_PD = 0,
    });

    APB_CTRL.WIFI_RST_EN.write(.{ .WIFI_RST = APB_CTRL.WIFI_RST_EN.read().WIFI_RST | modem_reset_field_when_pu });
    APB_CTRL.WIFI_RST_EN.write(.{ .WIFI_RST = APB_CTRL.WIFI_RST_EN.read().WIFI_RST & ~modem_reset_field_when_pu });

    RTC_CNTL.DIG_ISO.modify(.{
        .WIFI_FORCE_ISO = 0,
        .BT_FORCE_ISO = 0,
    });

    const system_wifi_clk_i2c_clk_en: u32 = 1 << 5;
    const system_wifi_clk_unused_bit12: u32 = 1 << 12;
    const wifi_bt_sdio_clk: u32 = system_wifi_clk_i2c_clk_en | system_wifi_clk_unused_bit12;
    const system_wifi_clk_en: u32 = 0x00FB9FCF;

    RTC_CNTL.DIG_ISO.modify(.{
        .WIFI_FORCE_ISO = 0,
        .BT_FORCE_ISO = 0,
    });

    RTC_CNTL.DIG_PWC.modify(.{
        .WIFI_FORCE_PD = 0,
        .BT_FORCE_PD = 0,
    });

    APB_CTRL.WIFI_CLK_EN.write(.{
        .WIFI_CLK_EN = APB_CTRL.WIFI_CLK_EN.read().WIFI_CLK_EN &
            ~wifi_bt_sdio_clk |
            system_wifi_clk_en,
    });
}

pub const interrupt_handler: microzig.cpu.InterruptHandler = .{
    .c = struct {
        fn handler_fn(_: *TrapFrame) linksection(".ram_text") callconv(.c) void {
            const status: microzig.cpu.interrupt.Status = .init();
            if (status.is_set(.wifi_mac) or status.is_set(.wifi_pwr)) {
                if (osi.wifi_interrupt_handler) |handler| {
                    handler.f(handler.arg);
                } else {
                    // should be unreachable
                }
            }
        }
    }.handler_fn,
};

test {
    _ = osi;
    _ = @import("radio/ble/npl.zig");
    _ = @import("radio/coex.zig");
    _ = @import("radio/coex_abi.zig");
    _ = @import("radio/coex_timer_wait.zig");
    _ = @import("radio/phy_modems.zig");
    _ = @import("radio/radios.zig");
    _ = @import("radio/shared_clocks.zig");
    _ = timer;
    _ = bluetooth;
}

// Replace the hardware timer worker on the host: a stack from init's
// allocator in its place, and a node from it on the timer list as the PHY
// timer's is. `deinit` frees both through the allocator it routes to, so a
// wrong route leaks them.
const HostResources = struct {
    const Allocation = struct {
        stack: []u8,
        node: *timer.Timer,
    };
    var live: ?Allocation = null;
    var key: c.ets_timer = undefined;
    fn start(gpa: Allocator) Allocator.Error!void {
        assert(live == null);
        const stack = try gpa.alloc(u8, 4096);
        errdefer gpa.free(stack);
        const node = try gpa.create(timer.Timer);
        timer.insert_for_test(node, &key);
        live = .{ .stack = stack, .node = node };
    }
    fn stop(gpa: Allocator) void {
        gpa.free(live.?.stack);
        live = null;
    }
};

test "coexistence radio allocations come from the shared heap and survive release of the first radio owner" {
    const host_test_heap = @import("radio/host_test_heap.zig");
    host_test_heap.attach();
    // Each init gets a failing allocator: in a coexistence image the
    // argument is not used, so an allocation through it fails the test.
    try wifi.init(std.testing.failing_allocator, .{});
    try init(std.testing.failing_allocator);
    try wifi.deinit();

    try std.testing.expect(refcount.load(.monotonic) == 1);
    const lo = @intFromPtr(&host_test_heap.buffer);
    const hi = lo + host_test_heap.buffer.len;
    const live = HostResources.live.?;
    try std.testing.expect(@intFromPtr(live.stack.ptr) >= lo and @intFromPtr(live.stack.ptr) + live.stack.len <= hi);
    try std.testing.expect(@intFromPtr(live.node) >= lo and @intFromPtr(live.node) + @sizeOf(timer.Timer) <= hi);
    @memset(live.stack, 0xa5);
    live.node.arg = null;
    const blob_object = osi.calloc(1, 64) orelse return error.OutOfMemory;
    try std.testing.expect(@intFromPtr(blob_object) >= lo and @intFromPtr(blob_object) + 64 <= hi);
    osi.free(blob_object);
    const before_release = host_test_heap.heap.heap.free_heap();
    try deinit();
    try std.testing.expect(refcount.load(.monotonic) == 0 and host_test_heap.heap.heap.free_heap() >= before_release + 4096 + @sizeOf(timer.Timer));
}

// Runs with the process heap detached whatever the test order, and restores it.
fn expect_detached(comptime body: fn () anyerror!void) !void {
    const previous = shared_heap.swap_for_test(null);
    defer _ = shared_heap.swap_for_test(previous);
    try body();
}

test "a coexistence radio init before attach_shared_heap returns SharedHeapNotAttached and acquires nothing" {
    try expect_detached(struct {
        fn body() !void {
            try std.testing.expectError(error.SharedHeapNotAttached, init(std.testing.allocator));
            try std.testing.expect(refcount.load(.monotonic) == 0 and HostResources.live == null);
            if (microzig.options.hal.radio.radios.wifi) {
                try std.testing.expectError(error.SharedHeapNotAttached, wifi.init(std.testing.allocator, .{}));
                try std.testing.expect(osi.wifi_shutdown.stage == .off and refcount.load(.monotonic) == 0);
                try std.testing.expectError(error.WifiNotInitialized, wifi.deinit());
            }
            // Still unattached: the blob allocation callbacks fail instead of
            // reaching storage nobody owns.
            try std.testing.expect(osi.malloc(16) == null);
        }
    }.body);
}

test "attach_shared_heap attaches once; a second attach is rejected and keeps the first heap" {
    try expect_detached(struct {
        var first_buffer: [8192]u8 align(16) = undefined;
        var second_buffer: [1024]u8 align(16) = undefined;
        fn body() !void {
            var first: SharedHeap = try .init(&first_buffer);
            var second: SharedHeap = try .init(&second_buffer);
            microzig.radio_test.in_isr = true;
            const from_isr = attach_shared_heap(&first);
            microzig.radio_test.in_isr = false;
            try std.testing.expectError(error.WouldBlock, from_isr);
            try std.testing.expectError(error.SharedHeapNotAttached, shared_heap.allocator());

            try attach_shared_heap(&first);
            try std.testing.expectError(error.SharedHeapAlreadyAttached, attach_shared_heap(&second));
            try std.testing.expect(shared_heap.attached_for_test() == &first and osi.callback_allocator().ptr == @as(*anyopaque, &first.heap));

            // Attach, then init: the radio's shared allocations come from the attached heap.
            try init(std.testing.failing_allocator);
            const live = HostResources.live.?;
            const lo = @intFromPtr(&first_buffer);
            try std.testing.expect(@intFromPtr(live.stack.ptr) >= lo and @intFromPtr(live.stack.ptr) + live.stack.len <= lo + first_buffer.len);
            try deinit();
            try std.testing.expect(refcount.load(.monotonic) == 0 and shared_heap.attached_for_test() == &first);
        }
    }.body);
}

test "host radio rejects interrupt entry and a non-PLL clock before acquiring resources" {
    const hw = microzig.radio_test;
    const previous_clock = hw.clock_source;
    const previous_isr = hw.in_isr;
    defer hw.clock_source = previous_clock;
    defer hw.in_isr = previous_isr;
    hw.clock_source = 0;
    hw.in_isr = true;
    try std.testing.expectError(error.WouldBlock, init(std.testing.failing_allocator));
    hw.in_isr = false;
    try std.testing.expectError(error.CpuClockNotPll, init(std.testing.failing_allocator));
    try std.testing.expect(refcount.load(.monotonic) == 0 and HostResources.live == null);
}
