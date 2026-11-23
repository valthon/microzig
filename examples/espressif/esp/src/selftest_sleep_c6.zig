//! No wiring; evidence per stage in the port README. Stages: s1 guards/awake control; s2 100 ms;
//! s3 100/250/500 ms retention; s4 LP drives GPIO0 high after HP requests
//! sleep (EXT1 with 1 s timer fallback); s5 flash image deep-sleep reset;
//! s6 reconnect, 100/500 ms sleep and host nonce echo, as C3 s6;
//! s7 RWDT reset at 3 s with XTAL on and 10 s timer fallback;
//! s8 RC_FAST LP clock, XTAL-off light sleep. Send S before first sleep.
//! USB s6: reopen after EACH detach, send USJ? after 1.5 s, answer
//! USJ nonce=xxxxxxxx with ACK xxxxxxxx. Each exchange has a 10 s deadline.
//! All summaries start after 1.5 s and repeat every 3 s. GPIO8 toggles on HAL
//! milestones; LP_AON.STORE0 holds the latest milestone for a halted run.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const sleep = hal.clocks.sleep;
const stage = @import("sleep_test_options").stage;
const usj = hal.usb_serial_jtag;
const p = microzig.chip.peripherals;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = usj.logger.log });
comptime {
    microzig.export_startup();
}
const Result = struct {
    name: []const u8,
    ok: bool = false,
    elapsed: u48 = 0,
    active_us: u64 = 0,
    requested_us: u64 = 0,
    requested_ticks: u48 = 0,
    hz: u48 = 0,
    call_lp_us: u64 = 0,
    setup_us: u64 = 0,
    slept_ticks: u48 = 0,
    slept_us: u64 = 0,
    sleep_active_us: u64 = 0,
    stopped_us: u64 = 0,
    diagnostics: sleep.Diagnostics = .{},
    err: ?sleep.Error = null,
};
var last_step: u8 = 0;
const Snapshot = struct {
    lp: u48,
    sys: u52,

    fn read() Snapshot {
        return .{ .lp = sleep.rtc_ticks(), .sys = hal.systimer.unit(1).read() };
    }
};
const TimerWindow = struct { request: ?Snapshot = null, woke: ?Snapshot = null };
var timer_window: ?TimerWindow = null;
fn trace(step: sleep.Step) void {
    last_step = @backingInt(step);
    p.LP_AON.STORE0.write_raw(last_step);
    hal.gpio.num(8).put(@truncate(last_step));
    if (stage == 4 and step == .request) hal.lp_core.Mailbox.write(.command, 1);
    if (timer_window) |*window| switch (step) {
        .request => window.request = Snapshot.read(),
        .woke => window.woke = Snapshot.read(),
        else => {},
    };
}
fn report(results: []const Result) noreturn {
    hal.time.sleep_ms(1500);
    while (true) {
        var pass: usize = 0;
        for (results) |r| {
            pass += @intFromBool(r.ok);
            std.log.info("SELFTEST sleep_c6_s{} {s}: {s} ticks={} active_us={} wake=0x{x} reject=0x{x} error={s} step=0x{x}", .{
                stage,              r.name,               if (r.ok) @as([]const u8, "PASS") else "FAIL", r.elapsed, r.active_us,
                r.diagnostics.wake, r.diagnostics.reject, if (r.err) |err| @errorName(err) else "none",  last_step,
            });
            if (r.requested_us != 0) std.log.info("SELFTEST sleep_c6_s{} {s} timing requested_us={} requested_ticks={} lp_hz={} call_lp_us={} setup_us={} slept_ticks={} slept_us={} systimer_us={} sleep_active_us={} stopped_us={}", .{
                stage,         r.name,     r.requested_us, r.requested_ticks, r.hz,         r.call_lp_us, r.setup_us,
                r.slept_ticks, r.slept_us, r.active_us,    r.sleep_active_us, r.stopped_us,
            });
        }
        std.log.info("SELFTEST sleep_c6_s{} DONE pass={} fail={}", .{ stage, pass, results.len - pass });
        hal.time.sleep_ms(3000);
    }
}
fn ticks_per_second() u48 {
    const start = sleep.rtc_ticks();
    hal.time.sleep_ms(100);
    return (sleep.rtc_ticks() -% start) * 10;
}
/// Ceiling on entry-to-request LP time in timer_check.
const max_setup_us = 30_000;
fn timer_check(ms: u32, hz: u48, attachment: *usj.Attachment) Result {
    var r: Result = .{ .name = "timer_retention" };
    const ticks = hz * ms / 1000;
    r.requested_us = @as(u64, ms) * 1000;
    r.requested_ticks = ticks;
    r.hz = hz;
    // Volatile application SRAM, with a runtime pattern live across the call.
    var words: [32]u32 = undefined;
    const memory: *volatile [32]u32 = &words;
    const seed = hal.rng.random_u32();
    for (0..32) |i| memory[i] = seed +% @as(u32, @intCast(i));
    const source = p.PCR.SYSCLK_CONF.raw;
    const cpu = p.PCR.CPU_FREQ_CONF.raw;
    const ahb = p.PCR.AHB_FREQ_CONF.raw;
    timer_window = .{};
    defer timer_window = null;
    const before = Snapshot.read();
    const cause = sleep.enter_light_sleep(.{
        .timer_ticks = ticks,
        .bench_recovery = true,
        .power_down_xtal = stage == 8,
        .usb_policy = .disconnect_and_reenumerate,
        .usb_reattach = .{ .attachment = attachment },
        .diagnostics = &r.diagnostics,
        .trace = trace,
    }) catch |err| failed: {
        r.err = err;
        break :failed null;
    };
    const after = Snapshot.read();
    r.elapsed = after.lp -% before.lp;
    r.active_us = @intCast((after.sys -% before.sys) / 16);
    r.call_lp_us = @as(u64, r.elapsed) * 1_000_000 / hz;
    const request = timer_window.?.request orelse return r;
    const woke = timer_window.?.woke orelse return r;
    const setup_ticks = request.lp -% before.lp;
    r.setup_us = @as(u64, setup_ticks) * 1_000_000 / hz;
    r.slept_ticks = woke.lp -% request.lp;
    r.slept_us = @as(u64, r.slept_ticks) * 1_000_000 / hz;
    r.sleep_active_us = @intCast((woke.sys -% request.sys) / 16);
    r.stopped_us = r.slept_us -| r.sleep_active_us;
    // IDF v5.5.1 sleep_modes.c:1431,1501,1808-1809 anchors the deadline
    // before calibration/setup, subtracting overhead rather than promising
    // ms of CPU stall. Our raw-tick API omits that estimated adjustment.
    // Check entry-to-wake LP time, excluding PLL/UART/USB restoration.
    const deadline_ticks = woke.lp -% before.lp;
    const deadline_ok = @as(u64, deadline_ticks) * 100 >= @as(u64, ticks) * 99 and
        @as(u64, deadline_ticks) * 100 <= @as(u64, ticks) * 120;
    // Bench runs at 706cfe9c measured about 20 ms of setup; a setup that
    // consumes most of a short request would leave little time stopped.
    const setup_ok = r.setup_us <= max_setup_us;
    // LP counts throughout; UNIT1 counts XTAL/2.5 (16 MHz) only while CPU
    // runs (TRM §§12.4.3,13.3-13.4.1). Require >=1 ms stopped AND >=90%
    // of the request-to-wake window stopped: immediate wake or busy waiting
    // cannot pass by spending the requested duration in setup or restoration.
    const slept = r.stopped_us >= 1000 and r.stopped_us * 100 >= r.slept_us * 90;
    r.ok = if (cause) |wake| wake.timer and !wake.gpio and deadline_ok and setup_ok and slept and source == p.PCR.SYSCLK_CONF.raw and
        cpu == p.PCR.CPU_FREQ_CONF.raw and ahb == p.PCR.AHB_FREQ_CONF.raw else false;
    if (stage == 8) r.ok = r.ok and p.LP_CLKRST.LP_CLK_CONF.read().FAST_CLK_SEL == 0 and
        p.PMU.HP_SLEEP_XTAL.read().HP_SLEEP_XPD_XTAL == 0 and p.PMU.LP_SLEEP_XTAL.read().LP_SLEEP_XPD_XTAL == 0;
    for (0..32) |i| r.ok = r.ok and memory[i] == seed +% @as(u32, @intCast(i));
    return r;
}
pub fn main() void {
    if (hal.wdt.C6SleepGuard.take_recovery()) |recovery| {
        if (recovery.reset != 5) {
            hal.time.sleep_ms(1500);
            while (true) {
                const ok = stage == 7 and recovery.reset == 0x10 and recovery.milestone == 0x41;
                std.log.info("SELFTEST sleep_c6_s{} recovered_hang: {s} reset=0x{x} marker=0x{x} milestone=0x{x} address=0x{x}", .{ stage, if (ok) @as([]const u8, "PASS") else "FAIL", recovery.reset, recovery.marker, recovery.milestone, recovery.address });
                std.log.info("SELFTEST sleep_c6_s{} DONE pass={} fail={}", .{ stage, @intFromBool(ok), @intFromBool(!ok) });
                hal.time.sleep_ms(3000);
            }
        }
    }
    hal.gpio.num(8).apply(.{ .output_enable = true });
    hal.time.sleep_ms(1500);
    if (stage == 5) deep_test();
    wait_for_arm();
    hal.systimer.unit(1).apply(.disabled_if_cpu_stalled);
    const active = hal.systimer.unit(1).read();
    const hz = ticks_per_second();
    const awake = [_]Result{.{ .name = "awake_control", .ok = hz > 0 and
        (hal.systimer.unit(1).read() -% active) / 16 >= 100_000 }};
    if (stage == 1) {
        var checks = [_]Result{ awake[0], .{ .name = "usb_loss_guard" }, .{ .name = "invalid_pin" } };
        _ = sleep.enter_light_sleep(.{ .bench_recovery = true, .timer_ticks = hz }) catch |err| {
            checks[1].ok = err == error.UsbSerialJtagActive;
        };
        _ = sleep.enter_light_sleep(.{ .gpio = .{ .pin = 8, .level = 1 } }) catch |err| {
            checks[2].ok = err == error.InvalidPin;
        };
        report(&checks);
    }
    if (hz == 0) report(&awake);
    var attachment: usj.Attachment = .{};
    const host = usj.wait_for_host(.from_ms(2000), &attachment);
    if (stage == 7) watchdog_test(hz, &attachment);
    if (stage == 8 and p.LP_CLKRST.LP_CLK_CONF.read().FAST_CLK_SEL != 0)
        report(&.{.{ .name = "lp_fast_rc", .ok = false }});
    if (stage == 6) usb_test(hz, host, &attachment);
    if (stage == 4) gpio_test(hz, &attachment);
    var results = [_]Result{ awake[0], timer_check(100, hz, &attachment), .{ .name = "timer_250ms" }, .{ .name = "timer_500ms" } };
    results[1].name = "timer_100ms";
    if (stage == 2) report(results[0..2]);
    results[2] = timer_check(250, hz, &attachment);
    results[2].name = "timer_250ms";
    results[3] = timer_check(500, hz, &attachment);
    results[3].name = "timer_500ms";
    report(&results);
}
/// Deliberately idle until the host arms this boot; reset/replug never arms it.
fn wait_for_arm() void {
    while (true) {
        std.log.info("SELFTEST sleep_c6_s{} ARMED? send S to start", .{stage});
        const start = hal.time.get_time_since_boot().to_us();
        while (hal.time.get_time_since_boot().to_us() -% start < 1_000_000) {
            if (usj.rx_fifo_available() and usj.rx_fifo_read() == 'S') return;
        }
    }
}

fn watchdog_test(hz: u48, attachment: *usj.Attachment) noreturn {
    var result: Result = .{ .name = "rwdt_timer_fallback" };
    // No deliberate hang: the independent LP alarm wakes after 10 s if the
    // watchdog fails to reset at 3 s. XTAL remains powered in both PMU tables.
    _ = sleep.enter_light_sleep(.{
        .timer_ticks = hz * 10,
        .bench_recovery = true,
        .bench_reset_ticks = hz * 3,
        .usb_policy = .disconnect_and_reenumerate,
        .usb_reattach = .{ .attachment = attachment },
        .trace = trace,
        .diagnostics = &result.diagnostics,
    }) catch |err| {
        result.err = err;
    };
    report(&.{result});
}

fn gpio_test(hz: u48, attachment: *usj.Attachment) noreturn {
    const lp = hal.lp_core;
    lp.stop();
    hal.time.sleep_ms(10);
    hal.lp_io.apply(0, .{ .input = true, .output = true, .initial_level = 0 });
    var results = [_]Result{ .{ .name = "lp_loaded" }, .{ .name = "gpio_internal" } };
    const loaded = blk: {
        lp.load(@embedFile("lp_image")) catch break :blk false;
        lp.start(.{}, 10000) catch break :blk false;
        const start = hal.time.get_time_since_boot().to_us();
        while (lp.Mailbox.read(.sequence) == 0) {
            if (hal.time.get_time_since_boot().to_us() -% start >= 100_000) break :blk false;
        }
        break :blk true;
    };
    results[0].ok = loaded;
    if (loaded) {
        const before = sleep.rtc_ticks();
        const cause = sleep.enter_light_sleep(.{
            .gpio = .{ .pin = 0, .level = 1 },
            .timer_ticks = hz,
            .bench_recovery = true,
            .usb_policy = .disconnect_and_reenumerate,
            .usb_reattach = .{ .attachment = attachment },
            .trace = trace,
            .diagnostics = &results[1].diagnostics,
        }) catch |err| failed: {
            results[1].err = err;
            break :failed null;
        };
        results[1].elapsed = sleep.rtc_ticks() -% before;
        results[1].ok = if (cause) |wake| wake.gpio and !wake.timer and wake.gpio_pins == 1 and
            results[1].elapsed >= hz / 20 and lp.Mailbox.read(.result) == 1 else false;
    }
    lp.stop();
    hal.time.sleep_ms(10);
    hal.lp_io.release(0);
    report(&results);
}
// LP SRAM, not MMIO. The test exclusively reserves the last 16 mailbox bytes;
// no LP image is loaded in stage 5, and HP startup does not clear LP SRAM.
const retained: *volatile [4]u32 = @ptrFromInt(hal.lp_core.mailbox_base + 0xf0);
fn deep_test() noreturn {
    const cause = sleep.wake_cause();
    const magic: u32 = 0xc6deed51;
    const pending = retained[0] == magic and retained[2] == ~retained[1];
    if (cause.reset == .deep_sleep or pending) {
        if (pending) retained[1] +%= 1;
        var results = [_]Result{
            .{ .name = "deep_sleep_reset", .ok = cause.reset == .deep_sleep },
            .{ .name = "timer_wake", .ok = cause.wake.timer },
            .{ .name = "lp_memory_counter", .ok = pending and retained[1] == 2, .elapsed = retained[1] },
        };
        for (&results) |*r| r.diagnostics.wake = cause.wake.raw;
        retained[0] = 0;
        report(&results);
    }
    wait_for_arm();
    retained[0] = magic;
    retained[1] = 1;
    retained[2] = ~@as(u32, 1);
    const hz = ticks_per_second();
    if (hz == 0) report(&.{.{ .name = "slow_clock", .ok = false }});
    // This build is restricted to esp32_c6 image boot, never load_ram.
    sleep.enter_deep_sleep(.{ .bench_recovery = true, .timer_ticks = hz * 2, .usb_policy = .disconnect_and_reenumerate, .trace = trace }) catch |err| {
        retained[0] = 0;
        report(&.{.{ .name = "deep_sleep_entry", .err = err }});
    };
}
fn receive(expected: []const u8, line: ?[]const u8) bool {
    const start = hal.time.get_time_since_boot().to_us();
    var sent: ?u64 = null;
    var matched: usize = 0;
    while (hal.time.get_time_since_boot().to_us() -% start < 10_000_000) {
        const now = hal.time.get_time_since_boot().to_us();
        if (line) |bytes| {
            const due = if (sent) |last| now -% last >= 1_000_000 else true;
            if (due and !usj.tx_fifo_full()) {
                for (bytes) |byte| usj.tx_fifo_write(byte);
                usj.tx_fifo_flush();
                sent = now;
            }
        }
        if (!usj.rx_fifo_available()) continue;
        const byte = usj.rx_fifo_read();
        matched = if (byte == expected[matched]) matched + 1 else @intFromBool(byte == expected[0]);
        if (matched == expected.len) return true;
    }
    return false;
}
fn drain() void {
    // Bound a continuously transmitting host too.
    for (0..256) |_| {
        if (!usj.rx_fifo_available()) break;
        _ = usj.rx_fifo_read();
    }
}
fn usb_test(hz: u48, host: bool, attachment: *usj.Attachment) noreturn {
    var results: [13]Result = @splat(.{ .name = "unreached" });
    results[0] = .{ .name = "wait_for_host", .ok = host };
    for ([_]u32{ 0, 100, 500 }, 0..) |ms, phase| {
        const base = 1 + phase * 4;
        drain();
        const conf = p.USB_DEVICE.CONF0.raw;
        const ena = p.USB_DEVICE.INT_ENA.raw;
        if (ms == 0) {
            const reset = usj.reconnect(.{ .attachment = attachment });
            results[base] = .{ .name = "reconnect", .ok = true };
            results[base + 1] = .{ .name = "bus_reset", .ok = reset orelse false };
        } else {
            results[base] = timer_check(ms, hz, attachment);
            results[base + 1] = .{ .name = "bus_reset", .ok = results[base].diagnostics.usb_bus_reset orelse false };
        }
        results[base].ok = results[base].ok and conf == p.USB_DEVICE.CONF0.raw and ena == p.USB_DEVICE.INT_ENA.raw;
        drain();
        results[base + 3] = .{ .name = "cdc_out", .ok = receive("USJ?", null) };
        var nonce_line: [24]u8 = undefined;
        var ack: [12]u8 = undefined;
        const nonce = hal.rng.random_u32();
        // Fixed formats occupy 20 and 12 bytes respectively.
        const line = std.mem.print(&nonce_line, "USJ nonce={x:0>8}\r\n", .{nonce}) catch unreachable;
        const expected = std.mem.print(&ack, "ACK {x:0>8}", .{nonce}) catch unreachable;
        results[base + 2] = .{ .name = "cdc_in", .ok = receive(expected, line) };
    }
    const names = [_][]const u8{
        "reconnect_operation", "reconnect_bus_reset", "reconnect_cdc_in", "reconnect_cdc_out",
        "100ms_operation",     "100ms_bus_reset",     "100ms_cdc_in",     "100ms_cdc_out",
        "500ms_operation",     "500ms_bus_reset",     "500ms_cdc_in",     "500ms_cdc_out",
    };
    for (results[1..], names) |*r, name| r.name = name;
    report(&results);
}
