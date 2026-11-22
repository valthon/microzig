//! s9: UART0 light-sleep wake, expected DONE pass=3 fail=0.
//! Wire a 3.3 V USB-UART adapter TX -> GPIO17 (XIAO ESP32-C6
//! D7), RX <- GPIO16 (D6), GND -> GND; the Super Mini ESP32-C6
//! exposes them too.
//! Use 115200 8N1, no flow control. Arm with S on USB Serial/JTAG, NOT UART.
//! Keep adapter TX idle high until UART_WAKE cue, wait 2 s, then send sixteen
//! ASCII U bytes once. WK_MODE_SEL=0, ACTIVE_THRESHOLD=2: five rising edges
//! wake (TRM v1.2 §27.4.8; IDF v5.5.1 uart_ll_set_wakeup_edge_thrd).
//! Trigger bytes may be lost; pass checks setup, UART0-only cause (not the
//! 30 s timer fallback), and >=100 ms / >=90% CPU stall between request/wake.
//!
//! s10: real-pad EXT1 deep-sleep wake, expected DONE pass=4 fail=0.
//! Flash image boot only (both stages). One jumper: GPIO2 (XIAO ESP32-C6 D2 or
//! Super Mini ESP32-C6 GPIO2) -> 3V3 BEFORE S. At GPIO_WAKE cue wait 2 s,
//! MOVE that jumper to GND, hold through reboot; remove after DONE. Never
//! bridge 3V3 to GND.
//! Alternatively use a 3.3 V UART TX with common GND: idle high before S,
//! then assert break (low) after the same 2 s wait and hold through reboot.
//! Pass checks deep reset, EXT1-only cause, GPIO2 status and retained marker.
//! A 30 s timer fallback or watchdog reset fails. EXT1 is level-sensitive:
//! the initial-high check prevents an already grounded pad from passing.
//! C6 TRM v1.2 §§7.7,12.4.2.2,12.10.2–3; LP SRAM retention §5.3.2.
//!
//! Both: open native USB CDC, wait ARMED?, send single S once per fresh run.
//! Reopen CDC after detach/reboot; do not auto-send S. Reports start after
//! 1.5 s and repeat every 3 s. GPIO8 beacons HAL milestones as in s1–s8;
//! LP_AON.STORE0 holds the latest callback. Hardware results: port README.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const sleep = hal.clocks.sleep;
const usj = hal.usb_serial_jtag;
const p = microzig.chip.peripherals;
const stage = @import("sleep_test_options").stage;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = usj.logger.log });
comptime {
    microzig.export_startup();
}

const Result = struct { name: []const u8, ok: bool = false };
var diagnostics: sleep.Diagnostics = .{};
var entry_error: ?sleep.Error = null;
var request_lp: u48 = 0;
var request_sys: u52 = 0;
var slept_ticks: u48 = 0;
var active_us: u64 = 0;
var last_step: u8 = 0;

fn trace(step: sleep.Step) void {
    last_step = @backingInt(step);
    p.LP_AON.STORE0.write_raw(last_step);
    hal.gpio.num(8).put(@truncate(last_step));
    if (stage == 9) switch (step) {
        .request => {
            request_lp = sleep.rtc_ticks();
            request_sys = hal.systimer.unit(1).read();
        },
        .woke => {
            slept_ticks = sleep.rtc_ticks() -% request_lp;
            active_us = @intCast((hal.systimer.unit(1).read() -% request_sys) / 16);
        },
        else => {},
    };
}

fn report(results: []const Result) noreturn {
    hal.time.sleep_ms(1500);
    while (true) {
        var pass: usize = 0;
        for (results) |r| {
            pass += @intFromBool(r.ok);
            std.log.info("SELFTEST sleep_c6_s{} {s}: {s} wake=0x{x} reject=0x{x} error={s} step=0x{x}", .{
                stage,              r.name,                                             if (r.ok) @as([]const u8, "PASS") else "FAIL", diagnostics.wake,
                diagnostics.reject, if (entry_error) |err| @errorName(err) else "none", last_step,
            });
        }
        std.log.info("SELFTEST sleep_c6_s{} DONE pass={} fail={}", .{ stage, pass, results.len - pass });
        hal.time.sleep_ms(3000);
    }
}

fn wait_for_arm() void {
    while (true) {
        std.log.info("SELFTEST sleep_c6_s{} ARMED? send S to start", .{stage});
        const start = hal.time.get_time_since_boot().to_us();
        while (hal.time.get_time_since_boot().to_us() -% start < 1_000_000) {
            if (usj.rx_fifo_available() and usj.rx_fifo_read() == 'S') return;
        }
    }
}

fn ticks_per_second() u48 {
    const start = sleep.rtc_ticks();
    hal.time.sleep_ms(100);
    return (sleep.rtc_ticks() -% start) * 10;
}

// Exclusively own the same last 16 LP mailbox bytes as s5; no LP image is
// loaded. HP startup leaves this SRAM intact (TRM v1.2 §5.3.2).
const retained: *volatile [4]u32 = @ptrFromInt(hal.lp_core.mailbox_base + 0xf0);
const magic: u32 = 0xc6deed10;

pub fn main() void {
    // Capture boot evidence before any sleep setup or pad reconfiguration.
    const boot = sleep.wake_cause();
    const recovery = hal.wdt.C6SleepGuard.take_recovery();
    if (stage == 10 and (retained[0] == magic or boot.reset == .deep_sleep)) {
        const pending = retained[0] == magic and retained[1] == ~magic and
            retained[2] == 4 and retained[3] == ~@as(u32, 4);
        retained[0] = 0;
        diagnostics.wake = boot.wake.raw;
        report(&.{
            .{ .name = "deep_sleep_reset", .ok = boot.reset == .deep_sleep },
            .{ .name = "ext1_wake", .ok = boot.wake.gpio and boot.wake.raw == 2 },
            .{ .name = "gpio2_status", .ok = boot.wake.gpio_pins == 4 },
            .{ .name = "retained_marker", .ok = pending },
        });
    }
    if (recovery) |r| {
        std.log.err("sleep_c6_s{} unexpected recovery reset=0x{x} milestone=0x{x}", .{ stage, r.reset, r.milestone });
        report(&.{.{ .name = "recovered_hang" }});
    }
    hal.gpio.num(8).apply(.{ .output_enable = true });
    hal.time.sleep_ms(1500);
    wait_for_arm();
    const hz = ticks_per_second();
    if (hz == 0) report(&.{.{ .name = "slow_clock" }});
    var attachment: usj.Attachment = .{};
    _ = usj.wait_for_host(.from_ms(2000), &attachment);
    if (stage == 9) uart_test(hz, &attachment);
    deep_gpio_test(hz);
}

fn uart_test(hz: u48, attachment: *usj.Attachment) noreturn {
    var results = [_]Result{ .{ .name = "uart_setup" }, .{ .name = "uart0_wake" }, .{ .name = "cpu_stalled" } };
    const uart = hal.uart.instance.num(0);
    uart.init(.{}) catch |err| {
        std.log.err("UART0 init: {s}", .{@errorName(err)});
        report(&results);
    };
    uart.connect_pins(.{ .tx = hal.gpio.num(16), .rx = hal.gpio.num(17) });
    // IDF v5.5.1 components/hal/esp32c6/include/hal/uart_ll.h:
    // uart_ll_set_wakeup_mode + uart_ll_set_wakeup_edge_thrd(5).
    // SLEEP_CONF2 is not a _SYNC register (TRM §§27.4.8,27.5.1).
    p.UART0.SLEEP_CONF2.modify(.{ .WK_MODE_SEL = 0, .ACTIVE_THRESHOLD = 2 });
    results[0].ok = p.UART0.SLEEP_CONF2.read().ACTIVE_THRESHOLD == 2 and
        p.UART0.SLEEP_CONF2.read().WK_MODE_SEL == 0 and hal.gpio.num(17).read() == 1;
    if (!results[0].ok) report(&results);
    hal.systimer.unit(1).apply(.disabled_if_cpu_stalled);
    std.log.info("SELFTEST sleep_c6_s9 UART_WAKE wait 2 s then send sixteen U bytes on adapter", .{});
    const cause = sleep.enter_light_sleep(.{
        .uart0 = true,
        .timer_ticks = hz * 30,
        .bench_recovery = true,
        .usb_policy = .disconnect_and_reenumerate,
        .usb_reattach = .{ .attachment = attachment },
        .trace = trace,
        .diagnostics = &diagnostics,
    }) catch |err| failed: {
        entry_error = err;
        break :failed null;
    };
    results[1].ok = if (cause) |wake| wake.uart0 and wake.raw == 0x40 else false;
    const slept_us = @as(u64, slept_ticks) * 1_000_000 / hz;
    const stopped_us = slept_us -| active_us;
    results[2].ok = cause != null and stopped_us >= 100_000 and stopped_us * 100 >= slept_us * 90;
    std.log.info("SELFTEST sleep_c6_s9 timing lp_hz={} slept_us={} active_us={} stopped_us={}", .{ hz, slept_us, active_us, stopped_us });
    // Clear the wake signal before any future sleep (TRM §27.4.8).
    uart.init(.{}) catch |err| {
        std.log.err("UART0 reset after wake: {s}", .{@errorName(err)});
        results[0].ok = false;
    };
    report(&results);
}

fn deep_gpio_test(hz: u48) noreturn {
    hal.lp_io.apply(2, .{ .input = true, .pull = .up });
    if (hal.lp_io.read(2) != 1) report(&.{.{ .name = "gpio2_initial_high" }});
    std.log.info("SELFTEST sleep_c6_s10 GPIO_WAKE wait 2 s then move GPIO2 jumper from 3V3 to GND; hold through reboot", .{});
    retained[1] = ~magic;
    retained[2] = 4;
    retained[3] = ~@as(u32, 4);
    retained[0] = magic;
    sleep.enter_deep_sleep(.{
        .ext1 = .{ .pins = 4, .levels = 0 },
        .timer_ticks = hz * 30,
        .bench_recovery = true,
        .usb_policy = .disconnect_and_reenumerate,
        .trace = trace,
        .diagnostics = &diagnostics,
    }) catch |err| {
        retained[0] = 0;
        entry_error = err;
        report(&.{.{ .name = "deep_sleep_entry" }});
    };
}
