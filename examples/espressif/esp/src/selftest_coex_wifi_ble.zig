//! Wi-Fi + BLE coexistence self-test for a Super Mini ESP32-C6. No wiring needed.
//!
//! The DUT joins the AP named by -Dwifi_ssid/-Dwifi_password (WPA2) and sends a
//! UDP datagram to the echo server at 192.168.4.1:7 every 100 ms. It advertises
//! as "MZ-COEX" for a central (the xiao_esp32_c6_selftest_coex_ble_peer build)
//! that subscribes to its notifications. With -Dcoex_ble_first=true the BLE
//! controller starts before Wi-Fi; otherwise Wi-Fi joins first. Twelve 60 s
//! phases interleave four modes, A/B/C/D three times:
//!   A  UDP echo, BLE off (the DUT drops the link and does not advertise)
//!   B  UDP echo, BLE link up and idle
//!   C  UDP echo, BLE notifications every 25 ms
//!   D  BLE notifications every 25 ms, no UDP. Wi-Fi cycles under the link: the
//!      UDP task deinitializes Wi-Fi at the phase start (retrying WouldBlock)
//!      and keeps it down for 20 s. It then calls init with a country of zero
//!      channels, which the driver rejects, so init must roll back and return
//!      the driver's error. Then it initializes Wi-Fi again, calls init once
//!      more with the rejected configuration (a running session must return
//!      success without reading it), rejoins, renews DHCP and waits for a UDP
//!      echo probe.
//! Every phase logs its AP RSSI median, UDP sent/echoed, BLE notifications sent
//! and unexpected disconnects; each D phase also logs its Wi-Fi cycle. Checks:
//! wifi_join, dhcp, ble_controller, ble_link, zero unexpected disconnects, UDP
//! loss (every A/B/C phase sent a datagram and got at least one echo back;
//! each A phase lost at most 2% of the datagrams it sent; each B/C phase lost
//! at most max(2 x the A-mode median loss, 2% of its datagrams sent); each 2%
//! rounds down: 12 of about 600 sent. A send error counts as a loss. The 2%
//! floor keeps a lossless A median from allowing no loss at all, and the A
//! bound keeps a dead echo server from raising the B/C bound to everything),
//! each C phase sending at least half the D-mode median notifications (a
//! D-mode median of 0 fails), and wifi_cycle: in every D phase deinit
//! succeeds, the rejected init rolls back with InvalidArg, re-init succeeds,
//! the second init on the running session succeeds, the station rejoins and
//! gets an address, a UDP echo returns, notifications are sent while Wi-Fi
//! is deinitialized, and the cycle finishes inside its D phase. If the UDP task
//! has not closed a phase 125 s after it ended (the sum of the cycle's waits
//! and retry sleeps, not counting the time spent inside the driver calls), the
//! run stops there and udp_loss and wifi_cycle fail. The run is VOID
//! when the phase AP RSSI medians span more than 3 dB, or when no phase got an
//! RSSI sample. The coex semaphore counters are printed, not checked: the
//! task-slot count includes every Wi-Fi driver semaphore call, and an
//! interrupt entry into a task slot panics, which is the task-only check.
//! Expected: SELFTEST coex_wifi_ble DONE pass=8 fail=0 void=0, repeated every 3 s
//! on the USB serial port after COEX order=wifi_first (or ble_first).
const std = @import("std");
const microzig = @import("microzig");
const wifi_options = @import("wifi_options");
const coex_options = @import("coex_options");
const hal = microzig.hal;
const rtos = hal.rtos;
const radio = hal.radio;
const ble = radio.bluetooth;
const Host = ble.host.Host;

const exports = @import("lwip/exports.zig");
const lwip = @import("lwip/include.zig");

comptime {
    _ = exports;
    _ = microzig.export_startup();
}

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .log_level = .info,
    .log_scope_levels = &.{
        .{ .scope = .esp_radio, .level = .err },
        .{ .scope = .esp_radio_timer, .level = .err },
        .{ .scope = .esp_radio_wifi, .level = .err },
        .{ .scope = .esp_radio_osi, .level = .err },
    },
    .logFn = hal.usb_serial_jtag.logger.log,
});

pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt29 = ble.interrupt_handler,
        .interrupt30 = radio.interrupt_handler,
        .interrupt31 = rtos.interrupt_handler,
    },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{
        // As the BLE bench examples: IDF's controller priorities, with fair
        // service for same-priority tasks.
        .rtos = .{ .enable = true, .priority_bits = 5, .preempt_same_priority_tasks_on_tick = true },
        .radio = .{
            .radios = .{ .wifi = true, .ble = true },
            .wifi = .{ .on_packet_received = on_packet_received },
        },
    },
};

const clock_config: hal.clocks.Config = .init_comptime(160_000_000);
pub fn init() void {
    hal.init_sequence(clock_config);
}

const suite = "coex_wifi_ble";
const peer_name = "MZ-COEX";
const checks = 8;
const udp_loss = @import("selftest_coex_udp_loss.zig");
const Mode = udp_loss.Mode;
const modes = udp_loss.modes;
const rounds = udp_loss.rounds;
const phase_count = udp_loss.phase_count;
const phase_ms = 60_000;
const udp_period_ms = 100;
const notify_period_ms = 25;
const relink_ms = 30_000;
/// How long a D phase keeps Wi-Fi deinitialized before initializing it again.
const wifi_down_ms = 20_000;
/// Bound of each station state, DHCP lease and echo-probe wait.
const wait_ms = 30_000;
const probe_datagrams = 50;
/// A Wi-Fi deinit that returns WouldBlock is retried this often, this far apart.
const deinit_retries = 1000;
const deinit_retry_ms = 10;
/// How long the main task waits, after a phase ends, for the UDP task to close
/// it: the sum of a D phase's Wi-Fi cycle waits and sleeps (deinit retries, the
/// down time, the rejoin, DHCP and probe waits, and the probe datagrams), most
/// of which already elapsed inside the phase. The driver calls themselves
/// (deinit, init, connect) are not bounded by it.
const close_wait_ms = deinit_retries * deinit_retry_ms + wifi_down_ms + 3 * wait_ms + probe_datagrams * udp_period_ms;
/// Echo-probe datagrams carry this phase tag, outside the counted phases.
const probe_tag = 0xffff;
const idle_phase = std.math.maxInt(u8);

fn mode_of(phase: usize) Mode {
    return modes[phase % modes.len];
}
fn uses_udp(mode: Mode) bool {
    return mode != .D;
}
fn cycles_wifi(mode: Mode) bool {
    return mode == .D;
}
fn uses_link(mode: Mode) bool {
    return mode != .A;
}
fn notifies(mode: Mode) bool {
    return mode == .C or mode == .D;
}

const max_rssi_samples = phase_ms / 1000 + 4;
/// Per-phase UDP and RSSI results, written by the UDP task and read by the
/// main task only after the UDP task has acknowledged closing the phase.
const UdpPhase = struct {
    sent: u32 = 0,
    echoed: u32 = 0,
    rssi: [max_rssi_samples]i8 = undefined,
    rssi_len: u32 = 0,
};
const BlePhase = struct {
    sent: u32 = 0,
    /// Notifications sent between a successful Wi-Fi deinit and the next init.
    sent_wifi_off: u32 = 0,
    disconnects: u32 = 0,
    relink_failed: bool = false,
};

/// A D phase's Wi-Fi deinit and re-init, written by the UDP task, which runs
/// the cycle; read under the same acknowledgement as `UdpPhase`.
const CyclePhase = struct {
    deinit_ok: bool = false,
    would_block: u32 = 0,
    deinit_ms: u32 = 0,
    rollback_ok: bool = false,
    reinit_ok: bool = false,
    shared_ok: bool = false,
    rejoin_ms: u32 = 0,
    probe_ok: bool = false,
    /// The cycle returned before its D phase ended.
    in_phase: bool = false,
    done: bool = false,
};

var udp_phases: [phase_count]UdpPhase = @splat(.{});
var cycle_phases: [phase_count]CyclePhase = @splat(.{});
/// False from just before a Wi-Fi deinit until the station has rejoined.
var wifi_live: std.atomic.Value(bool) = .init(false);
/// True from a successful Wi-Fi deinit until the next init call.
var wifi_off: std.atomic.Value(bool) = .init(false);
var probe_echoed: std.atomic.Value(bool) = .init(false);
var heap_gpa: std.mem.Allocator = undefined;
var ble_phases: [phase_count]BlePhase = @splat(.{});
/// The phase the UDP task samples for, or `idle_phase`.
var current_phase: std.atomic.Value(u8) = .init(idle_phase);
/// Phases the main task has asked the UDP task to close, in order.
var udp_close: std.atomic.Value(u8) = .init(0);
/// Phases the UDP task has closed: stored with release after its last write to
/// them (cycle, counters and echoes), so an acquire load that reaches a phase
/// orders all of that phase's results before the main task reads them.
var udp_closed: std.atomic.Value(u8) = .init(0);
/// Phases the main task saw closed in time, in order; only their UDP and cycle
/// results are read.
var phases_closed: usize = 0;

var controller: ble.Controller = .{};
var host: Host = undefined;
// The heap that Wi-Fi and BLE share, attached before either starts. It stays
// in use for the rest of the boot.
var radio_heap_buffer: [128 * 1024]u8 align(16) = undefined;
var radio_heap: radio.SharedHeap = undefined;
var maybe_netif: std.atomic.Value(?*lwip.c.netif) = .init(null);
var ip_ready: rtos.Signal(void) = .{};
var netif: lwip.c.netif = undefined;

var passed: u32 = 0;
var void_run = false;
var finished = false;

fn now_ms() u64 {
    return hal.time.get_time_since_boot().to_us() / 1000;
}

fn pass(step: []const u8) void {
    passed += 1;
    std.log.info("SELFTEST {s} {s}: PASS", .{ suite, step });
}

fn fail(step: []const u8, err: anyerror) void {
    std.log.err("SELFTEST {s} {s}: FAIL {t}", .{ suite, step, err });
}

const order = if (coex_options.ble_first) "ble_first" else "wifi_first";

/// Repeats the start order and the verdict for a late serial attachment; a
/// setup failure ends here too.
fn report_loop() noreturn {
    while (true) {
        const stats = radio.coex_semaphore_stats();
        std.log.info("COEX semaphore task_calls={d} from_isr_calls={d}", .{ stats.task_calls, stats.from_isr_calls });
        if (finished) print_summary();
        std.log.info("COEX order={s}", .{order});
        std.log.info("SELFTEST {s} DONE pass={d} fail={d} void={d}", .{ suite, passed, checks - passed, @intFromBool(void_run) });
        rtos.sleep(.from_ms(3000));
    }
}

pub fn main() void {
    var heap = microzig.Allocator.init_with_heap(160 * 1024) catch |err| {
        fail("heap", err);
        report_loop();
    };
    const gpa = heap.allocator();
    heap_gpa = gpa;
    radio_heap = radio.SharedHeap.init(&radio_heap_buffer) catch |err| {
        fail("heap", err);
        report_loop();
    };
    radio.attach_shared_heap(&radio_heap) catch |err| {
        fail("heap", err);
        report_loop();
    };
    host = .init(controller.transport());

    if (coex_options.ble_first) start_ble(gpa);
    join_wifi(gpa) catch report_loop();
    if (!coex_options.ble_first) start_ble(gpa);
    host.advertise(peer_name) catch |err| {
        fail("ble_link", err);
        report_loop();
    };
    if (relink(now_ms() + 120_000)) pass("ble_link") else {
        fail("ble_link", error.Timeout);
        report_loop();
    }

    _ = rtos.spawn(gpa, udp_task, .{}, .{ .name = "coex_udp", .priority = @fromBackingInt(2), .stack_size = 8192 }) catch |err| {
        fail("udp_task", err);
        report_loop();
    };
    for (0..phase_count) |phase| {
        if (!run_phase(phase)) break;
        phases_closed = phase + 1;
    }
    finish();
    finished = true;
    report_loop();
}

fn start_ble(gpa: std.mem.Allocator) void {
    controller.start(gpa) catch |err| {
        fail("ble_controller", err);
        report_loop();
    };
    host.initialize() catch |err| {
        fail("ble_controller", err);
        report_loop();
    };
    pass("ble_controller");
}

fn join_wifi(gpa: std.mem.Allocator) !void {
    start_wifi(gpa) catch |err| return fail_with("wifi_join", err);
    exports.gpa = gpa;
    lwip.c.tcpip_init(null, null);
    lwip.c_err(lwip.c.netifapi_netif_add(&netif, @ptrCast(lwip.c.IP4_ADDR_ANY), @ptrCast(lwip.c.IP4_ADDR_ANY), @ptrCast(lwip.c.IP4_ADDR_ANY), null, netif_init, lwip.c.tcpip_input)) catch |err| return fail_with("wifi_join", err);
    maybe_netif.store(&netif, .release);
    connect_wifi() catch |err| return fail_with("wifi_join", err);
    pass("wifi_join");
    get_address() catch |err| return fail_with("dhcp", err);
    pass("dhcp");
}

fn start_wifi(gpa: std.mem.Allocator) !void {
    try radio.wifi.init(gpa, .{});
    try radio.wifi.apply(.{ .sta = .{
        .ssid = wifi_options.ssid,
        .password = wifi_options.password,
        .auth_method = .wpa2_personal,
    } });
    try radio.wifi.start();
    try wait_sta(.started);
}

/// Start DHCP and associate; the netif must already be added.
fn connect_wifi() !void {
    try lwip.c_err(lwip.c.netifapi_netif_common(&netif, null, lwip.c.dhcp_start));
    try radio.wifi.connect();
    try wait_sta(.connected);
    wifi_live.store(true, .release);
}

fn get_address() !void {
    try lwip.c_err(lwip.c.netifapi_netif_common(&netif, lwip.c.netif_set_link_up, null));
    try ip_ready.wait_with_timeout(.{ .after = .from_ms(wait_ms) });
}

/// D phase, on the UDP task: tear Wi-Fi down while the main task keeps
/// notifying, bring it back after `wifi_down_ms`, and prove UDP with a probe.
fn cycle_wifi(conn: *lwip.c.struct_netconn, phase: usize, phase_start: u64) void {
    const cycle = &cycle_phases[phase];
    defer {
        cycle.in_phase = current_phase.load(.acquire) == phase;
        cycle.done = true;
    }
    // Release the lease and drop the link first, so lwIP stops sending.
    lwip.c_err(lwip.c.netifapi_netif_common(&netif, lwip.c.dhcp_release_and_stop, null)) catch |err| std.log.warn("COEX dhcp release: {t}", .{err});
    lwip.c_err(lwip.c.netifapi_netif_common(&netif, lwip.c.netif_set_link_down, null)) catch |err| std.log.warn("COEX link down: {t}", .{err});
    wifi_live.store(false, .release);
    const deinit_start = now_ms();
    while (true) {
        radio.wifi.deinit() catch |err| switch (err) {
            error.WouldBlock => {
                cycle.would_block += 1;
                if (cycle.would_block < deinit_retries) {
                    rtos.sleep(.from_ms(deinit_retry_ms));
                    continue;
                }
                std.log.err("COEX phase={d} wifi deinit: still WouldBlock", .{phase + 1});
                return;
            },
            else => {
                std.log.err("COEX phase={d} wifi deinit: {t}", .{ phase + 1, err });
                return;
            },
        };
        break;
    }
    cycle.deinit_ms = @intCast(now_ms() - deinit_start);
    cycle.deinit_ok = true;
    wifi_off.store(true, .release);

    const resume_at = phase_start + wifi_down_ms;
    while (now_ms() < resume_at) {
        drain(conn);
        rtos.sleep(.from_ms(udp_period_ms));
    }
    // libnet80211 wifi_set_country+0x86 rejects zero channels with
    // ESP_ERR_INVALID_ARG after the driver and supplicant are up, so init
    // rolls the partial session back before it returns.
    const rejected: radio.wifi.InitConfig = .{ .country_info = .{ .manual = .{ .total_channel_number = 0 } } };
    wifi_off.store(false, .release);
    if (radio.wifi.init(heap_gpa, rejected)) |_| {
        std.log.err("COEX phase={d} init accepted a zero-channel country", .{phase + 1});
        return;
    } else |err| switch (err) {
        error.InvalidArg => cycle.rollback_ok = true,
        else => {
            std.log.err("COEX phase={d} rejected init: {t}", .{ phase + 1, err });
            return;
        },
    }
    const rejoin_start = now_ms();
    ip_ready.clear();
    start_wifi(heap_gpa) catch |err| {
        std.log.err("COEX phase={d} wifi re-init: {t}", .{ phase + 1, err });
        return;
    };
    cycle.reinit_ok = true;
    // IDF v5.5.1 wifi_init.c:343-345: init on a running session succeeds
    // without reading its configuration, so the rejected country is ignored.
    radio.wifi.init(heap_gpa, rejected) catch |err| {
        std.log.err("COEX phase={d} init on the running session: {t}", .{ phase + 1, err });
        return;
    };
    cycle.shared_ok = true;
    connect_wifi() catch |err| {
        std.log.err("COEX phase={d} wifi rejoin: {t}", .{ phase + 1, err });
        return;
    };
    get_address() catch |err| {
        std.log.err("COEX phase={d} dhcp after re-init: {t}", .{ phase + 1, err });
        return;
    };
    cycle.rejoin_ms = @intCast(now_ms() - rejoin_start);

    probe_echoed.store(false, .release);
    for (0..probe_datagrams) |seq| {
        send(conn, .{ .phase = probe_tag, .seq = @intCast(seq) }) catch |err| std.log.warn("COEX probe send: {t}", .{err});
        rtos.sleep(.from_ms(udp_period_ms));
        drain(conn);
        if (probe_echoed.load(.acquire)) {
            cycle.probe_ok = true;
            return;
        }
    }
    std.log.err("COEX phase={d} no UDP echo after re-init", .{phase + 1});
}

fn fail_with(step: []const u8, err: anyerror) anyerror {
    fail(step, err);
    return err;
}

fn wait_sta(expected: radio.wifi.StaState) !void {
    const deadline = now_ms() + wait_ms;
    while (radio.wifi.get_sta_state() != expected) {
        if (now_ms() >= deadline) return error.Timeout;
        rtos.sleep(.from_ms(20));
    }
}

/// Poll the host once; a timeout is idle and a disconnect is handled by the caller.
fn poll(timeout_ms: u32) ble.host.Error!void {
    host.poll(timeout_ms) catch |err| switch (err) {
        error.Timeout => {},
        error.Disconnected => if (host.connection != null) return err,
        else => return err,
    };
}

fn subscribed() bool {
    return host.connection != null and host.server.?.subscribed;
}

/// Wait for the peer to connect and subscribe; advertising is already on.
fn relink(deadline: u64) bool {
    while (!subscribed()) {
        if (now_ms() >= deadline) return false;
        poll(100) catch |err| {
            std.log.warn("COEX relink poll: {t}", .{err});
            if (host.connection == null) host.resume_advertising() catch {};
        };
    }
    return true;
}

/// Run one phase; false when the UDP task did not close it in time.
fn run_phase(phase: usize) bool {
    const mode = mode_of(phase);
    const stats = &ble_phases[phase];
    if (uses_link(mode)) {
        if (!subscribed()) {
            if (host.connection == null) host.resume_advertising() catch |err| std.log.warn("COEX advertise: {t}", .{err});
            if (!relink(now_ms() + relink_ms)) stats.relink_failed = true;
        }
    } else if (host.connection != null) {
        host.disconnect() catch |err| std.log.warn("COEX drop link: {t}", .{err});
    }
    std.log.info("COEX phase={d}/{d} mode={t} start", .{ phase + 1, phase_count, mode });
    current_phase.store(@intCast(phase), .release);
    const end = now_ms() + phase_ms;
    var next_notify = now_ms();
    var was_connected = host.connection != null;
    while (now_ms() < end) {
        poll(if (notifies(mode)) 5 else 50) catch |err| std.log.warn("COEX poll: {t}", .{err});
        if (was_connected and host.connection == null) {
            stats.disconnects += 1;
            std.log.warn("COEX phase={d} unexpected disconnect reason={?x}", .{ phase + 1, host.disconnect_reason });
            if (uses_link(mode)) host.resume_advertising() catch |err| std.log.warn("COEX advertise: {t}", .{err});
        }
        was_connected = host.connection != null;
        if (notifies(mode) and now_ms() >= next_notify) {
            next_notify += notify_period_ms;
            if (host.notify() catch |err| blk: {
                std.log.warn("COEX notify: {t}", .{err});
                break :blk false;
            }) {
                stats.sent += 1;
                if (wifi_off.load(.acquire)) stats.sent_wifi_off += 1;
            }
            // Do not build a backlog after a stall; keep the period from now.
            if (next_notify < now_ms()) next_notify = now_ms() + notify_period_ms;
        }
    }
    current_phase.store(idle_phase, .release);
    // Let the last echoes in flight arrive, then wait for the UDP task to close
    // the phase. A Wi-Fi cycle still running past the phase end is waited for
    // and then fails its in_phase check. A UDP task stuck past the sum of the
    // cycle's bounds ends the run: its phase results are not read.
    rtos.sleep(.from_ms(udp_period_ms * 3));
    udp_close.store(@intCast(phase + 1), .release);
    const close_deadline = now_ms() + close_wait_ms;
    while (udp_closed.load(.acquire) <= phase) {
        if (now_ms() >= close_deadline) {
            std.log.err("COEX phase={d} UDP task did not close the phase within {d} ms", .{ phase + 1, close_wait_ms });
            return false;
        }
        poll(50) catch |err| std.log.warn("COEX poll: {t}", .{err});
    }
    print_phase(phase);
    return true;
}

fn print_phase(phase: usize) void {
    const u = &udp_phases[phase];
    const b = &ble_phases[phase];
    std.log.info("COEX phase={d}/{d} mode={t} rssi_median={d} rssi_samples={d} udp_sent={d} udp_echoed={d} ble_sent={d} ble_disconnects={d} relink_failed={}", .{
        phase + 1, phase_count, mode_of(phase), rssi_median(phase), u.rssi_len, u.sent, u.echoed, b.sent, b.disconnects, b.relink_failed,
    });
    if (!cycles_wifi(mode_of(phase))) return;
    const w = &cycle_phases[phase];
    std.log.info("COEX phase={d}/{d} wifi_cycle deinit_ok={} would_block={d} deinit_ms={d} rollback_ok={} reinit_ok={} shared_ok={} rejoin_ms={d} probe_ok={} in_phase={} ble_sent_wifi_off={d}", .{
        phase + 1, phase_count, w.deinit_ok, w.would_block, w.deinit_ms, w.rollback_ok, w.reinit_ok, w.shared_ok, w.rejoin_ms, w.probe_ok, w.in_phase, b.sent_wifi_off,
    });
}

fn cycle_ok(phase: usize) bool {
    const w = &cycle_phases[phase];
    return w.done and w.in_phase and w.deinit_ok and w.rollback_ok and w.reinit_ok and w.shared_ok and w.probe_ok and ble_phases[phase].sent_wifi_off > 0;
}

fn rssi_median(phase: usize) i32 {
    const u = &udp_phases[phase];
    if (u.rssi_len == 0) return 0;
    var samples: [max_rssi_samples]i8 = undefined;
    @memcpy(samples[0..u.rssi_len], u.rssi[0..u.rssi_len]);
    std.mem.sort(i8, samples[0..u.rssi_len], {}, std.sort.asc(i8));
    return samples[u.rssi_len / 2];
}

/// Median of `value(phase)` over the three phases of one mode.
fn mode_median(mode: Mode, comptime value: fn (usize) u32) u32 {
    var values: [rounds]u32 = undefined;
    for (0..rounds) |round| values[round] = value(round * modes.len + @backingInt(mode));
    std.mem.sort(u32, &values, {}, std.sort.asc(u32));
    return values[rounds / 2];
}

fn udp_counts() [phase_count]udp_loss.Counts {
    var counts: [phase_count]udp_loss.Counts = undefined;
    for (&counts, udp_phases) |*phase, u| phase.* = .{ .sent = u.sent, .echoed = u.echoed };
    return counts;
}

fn ble_sent(phase: usize) u32 {
    return ble_phases[phase].sent;
}

fn finish() void {
    var disconnects: u32 = 0;
    var relink_failures: u32 = 0;
    for (ble_phases) |b| {
        disconnects += b.disconnects;
        relink_failures += @intFromBool(b.relink_failed);
    }
    if (disconnects == 0 and relink_failures == 0) pass("ble_disconnects") else fail("ble_disconnects", error.Disconnected);

    // A stalled UDP task leaves phases unread.
    const complete = phases_closed == phase_count;
    if (!complete) fail("udp_loss", error.UdpTaskStalled) else if (udp_loss.check(&udp_counts())) |_| pass("udp_loss") else |err| fail("udp_loss", err);

    const reference = mode_median(.D, ble_sent);
    var rate_ok = reference > 0;
    for (0..phase_count) |phase| {
        if (mode_of(phase) == .C and 2 * ble_sent(phase) < reference) rate_ok = false;
    }
    if (rate_ok) pass("ble_rate") else fail("ble_rate", error.RateBelowThreshold);

    var cycles_ok = complete;
    for (0..phases_closed) |phase| {
        if (cycles_wifi(mode_of(phase)) and !cycle_ok(phase)) cycles_ok = false;
    }
    if (cycles_ok) pass("wifi_cycle") else fail("wifi_cycle", error.WifiCycleFailed);

    var low: i32 = std.math.maxInt(i32);
    var high: i32 = std.math.minInt(i32);
    for (0..phases_closed) |phase| {
        if (udp_phases[phase].rssi_len == 0) continue;
        low = @min(low, rssi_median(phase));
        high = @max(high, rssi_median(phase));
    }
    // RF A/B comparisons are void when the bench drifts by more than 3 dB.
    void_run = low > high or high - low > 3;
}

fn print_summary() void {
    for (0..phases_closed) |phase| print_phase(phase);
    if (phases_closed < phase_count) std.log.err("COEX UDP task stalled after {d} closed phases", .{phases_closed});
    const a_lost: ?u32 = if (phases_closed == phase_count) udp_loss.a_median(&udp_counts()) else null;
    std.log.info("COEX udp_lost_A_median={?d} ble_sent_D_median={d} void={}", .{ a_lost, mode_median(.D, ble_sent), void_run });
}

extern fn netconn_new_with_proto_and_callback(t: lwip.c.enum_netconn_type, proto: lwip.c.u8_t, callback: ?*const anyopaque) [*c]lwip.c.struct_netconn;

const Datagram = extern struct {
    magic: u32 = 0x58454f43, // "COEX"
    phase: u32,
    seq: u32,
    pad: [20]u8 = @splat(0x5a),
};

fn udp_task() void {
    udp_loop() catch |err| {
        std.log.err("COEX udp task: {t}", .{err});
        // Only setup fails here, before any datagram. Release every phase so
        // the main task can finish; they sent nothing, which fails udp_loss.
        udp_closed.store(phase_count, .release);
    };
}

fn udp_loop() !void {
    const conn = netconn_new_with_proto_and_callback(lwip.c.NETCONN_UDP, 0, null) orelse return error.OutOfMemory;
    conn.*.flags |= lwip.c.NETCONN_FLAG_NON_BLOCKING;
    var ip: lwip.c.ip_addr_t = std.mem.zeroes(lwip.c.ip_addr_t);
    ip.u_addr.ip4.addr = @bitCast([4]u8{ 192, 168, 4, 1 });
    try lwip.c_err(lwip.c.netconn_connect(conn, &ip, 7));
    var seq: u32 = 0;
    var next_rssi = now_ms();
    while (true) {
        drain(conn);
        // Acknowledge at the top of the loop, after this task's last write to
        // the closed phases; the next current_phase load sees idle or later.
        const close = udp_close.load(.acquire);
        if (close > udp_closed.load(.monotonic)) udp_closed.store(close, .release);
        if (close == phase_count) return;
        const raw = current_phase.load(.acquire);
        if (raw != idle_phase and cycles_wifi(mode_of(raw)) and !cycle_phases[raw].done) {
            cycle_wifi(conn, raw, now_ms());
            continue;
        }
        if (raw != idle_phase) {
            const phase: usize = raw;
            const u = &udp_phases[phase];
            if (now_ms() >= next_rssi and !cycles_wifi(mode_of(phase))) {
                next_rssi = now_ms() + 1000;
                if (radio.wifi.get_sta_rssi()) |rssi| {
                    if (u.rssi_len < u.rssi.len) {
                        u.rssi[u.rssi_len] = @intCast(std.math.clamp(rssi, -128, 127));
                        u.rssi_len += 1;
                    }
                } else |err| std.log.warn("COEX rssi: {t}", .{err});
            }
            if (uses_udp(mode_of(phase))) {
                seq +%= 1;
                send(conn, .{ .phase = raw, .seq = seq }) catch |err| std.log.warn("COEX udp send: {t}", .{err});
                u.sent += 1;
            }
        }
        rtos.sleep(.from_ms(udp_period_ms));
    }
}

fn send(conn: *lwip.c.struct_netconn, datagram: Datagram) !void {
    const buf = lwip.c.netbuf_new() orelse return error.OutOfMemory;
    defer lwip.c.netbuf_delete(buf);
    const bytes = std.mem.asBytes(&datagram);
    try lwip.c_err(lwip.c.netbuf_ref(buf, bytes.ptr, bytes.len));
    try lwip.c_err(lwip.c.netconn_send(conn, buf));
}

/// Count every echo received so far against the phase it was sent in.
fn drain(conn: *lwip.c.struct_netconn) void {
    while (true) {
        var buf: [*c]lwip.c.netbuf = null;
        lwip.c_err(lwip.c.netconn_recv(conn, &buf)) catch return;
        defer lwip.c.netbuf_delete(buf);
        var echo: Datagram = undefined;
        const bytes = std.mem.asBytes(&echo);
        const n = lwip.c.pbuf_copy_partial(buf.*.p, bytes.ptr, bytes.len, 0);
        if (n != bytes.len or echo.magic != (Datagram{ .phase = 0, .seq = 0 }).magic) continue;
        if (echo.phase == probe_tag) {
            probe_echoed.store(true, .release);
            continue;
        }
        // A closed phase is not updated any more. Only this task stores udp_closed.
        if (echo.phase < phase_count and echo.phase >= udp_closed.load(.monotonic))
            udp_phases[echo.phase].echoed += 1;
    }
}

fn netif_status_callback(netif_ptr: [*c]lwip.c.netif) callconv(.c) void {
    if (netif_ptr[0].ip_addr.u_addr.ip4.addr != 0) ip_ready.put({});
}

fn on_packet_received(comptime _: radio.wifi.Interface, data: []const u8) void {
    const nif = maybe_netif.load(.acquire) orelse return;
    const pbuf = lwip.c.pbuf_alloc(lwip.c.PBUF_RAW, @intCast(data.len), lwip.c.PBUF_POOL) orelse return;
    lwip.c_err(lwip.c.pbuf_take(pbuf, data.ptr, @intCast(data.len))) catch {
        _ = lwip.c.pbuf_free(pbuf);
        return;
    };
    lwip.c_err(nif.input.?(pbuf, nif)) catch {
        _ = lwip.c.pbuf_free(pbuf);
    };
}

fn netif_init(netif_ptr: [*c]lwip.c.struct_netif) callconv(.c) lwip.c.err_t {
    const nif = &netif_ptr[0];
    @memcpy(&nif.name, "w0");
    nif.linkoutput = netif_output;
    nif.output = lwip.c.etharp_output;
    nif.output_ip6 = lwip.c.ethip6_output;
    nif.mtu = 1500;
    nif.flags = lwip.c.NETIF_FLAG_BROADCAST | lwip.c.NETIF_FLAG_ETHARP | lwip.c.NETIF_FLAG_ETHERNET | lwip.c.NETIF_FLAG_IGMP | lwip.c.NETIF_FLAG_MLD6;
    @memcpy(&nif.hwaddr, &radio.read_mac(.sta));
    nif.hwaddr_len = 6;
    lwip.c.netif_create_ip6_linklocal_address(nif, 1);
    lwip.c.netif_set_status_callback(nif, netif_status_callback);
    lwip.c.netif_set_default(nif);
    lwip.c.netif_set_up(nif);
    return lwip.c.ERR_OK;
}

var packet_buf: [1600]u8 = undefined;

fn netif_output(_: [*c]lwip.c.struct_netif, pbuf_c: [*c]lwip.c.struct_pbuf) callconv(.c) lwip.c.err_t {
    // The driver is down or not yet associated during a D-phase cycle.
    if (!wifi_live.load(.acquire)) return lwip.c.ERR_IF;
    const pbuf: *lwip.c.struct_pbuf = pbuf_c;
    if (pbuf.tot_len > packet_buf.len) return lwip.c.ERR_BUF;
    if (lwip.c.pbuf_copy_partial(pbuf, &packet_buf, pbuf.tot_len, 0) != pbuf.tot_len) return lwip.c.ERR_BUF;
    radio.wifi.send_packet(.sta, packet_buf[0..pbuf.tot_len]) catch return lwip.c.ERR_IF;
    return lwip.c.ERR_OK;
}
