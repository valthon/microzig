const microzig = @import("microzig");
const nrf = microzig.hal;
const harness = @import("harness.zig");

pub const panic = microzig.panic;
pub const init = harness.init;
pub const std_options = microzig.std_options(.{});
pub const microzig_options: microzig.Options = .{
    .interrupts = .{ .RTC1 = .{ .c = rtc_interrupt } },
};

comptime {
    _ = microzig.export_startup();
}

const suite = "timing";
const poll_limit = 1_000_000;

pub fn main() void {
    check_timer() catch |err| harness.check(suite, "timer_elapsed", false, "{s}", .{@errorName(err)});
    check_rtc();
    check_gpiote() catch |err| harness.check(suite, "gpiote_edge", false, "{s}", .{@errorName(err)});
    check_gpiote_port();
    check_ppi() catch |err| harness.check(suite, "ppi_setup", false, "{s}", .{@errorName(err)});
    harness.finish(suite);
}

fn check_timer() !void {
    const timer: nrf.timer.Timer = .timer1;
    timer.stop();
    defer timer.stop();
    try timer.apply(.{ .prescaler = 4 }); // 1 tick per microsecond
    timer.set_compare_interrupt(0, false);
    timer.set_shortcuts(0, .{ .stop = true });
    defer timer.set_shortcuts(0, .{});
    timer.set_compare(0, 10_000);
    timer.clear_compare(0);
    timer.clear();

    const start_us = nrf.time.get_time_since_boot().to_us();
    timer.start();
    const matched = for (0..poll_limit) |_| {
        if (timer.compare_pending(0)) break true;
    } else false;
    const elapsed_us = nrf.time.get_time_since_boot().to_us() - start_us;
    const captured = timer.capture(1);
    harness.check(suite, "timer_elapsed", matched and captured == 10_000 and
        elapsed_us >= 9_500 and elapsed_us <= 10_500, "match={} capture={d} rtc_us={d}", .{
        matched, captured, elapsed_us,
    });
}

const alarm_rtc: nrf.rtc.Rtc = .rtc1;
const alarm_tick = 128;
var alarm_count: u32 = 0;
var observed_tick: u32 = 0;

fn rtc_interrupt() callconv(.c) void {
    if (alarm_rtc.event_pending(.compare0)) {
        @atomicStore(u32, &observed_tick, alarm_rtc.counter(), .monotonic);
        alarm_rtc.clear_event(.compare0);
    }
    _ = @atomicRmw(u32, &alarm_count, .Add, 1, .release);
}

fn check_rtc() void {
    const irq = comptime alarm_rtc.interrupt();
    // HAL time init has started LFCLK. Allow the RTC1 STOP and CLEAR tasks
    // to cross into that clock domain (nRF52840 PS v1.11 §6.22.8).
    alarm_rtc.stop();
    nrf.time.sleep_us(64);
    alarm_rtc.clear();
    nrf.time.sleep_us(64);
    alarm_rtc.apply(0);
    alarm_rtc.set_compare(0, alarm_tick);
    alarm_rtc.clear_event(.compare0);
    alarm_rtc.set_interrupt(.compare0, true);
    defer alarm_rtc.set_interrupt(.compare0, false);
    microzig.cpu.interrupt.clear_pending(irq);
    microzig.cpu.interrupt.enable(irq);
    defer microzig.cpu.interrupt.disable(irq);
    alarm_rtc.start();
    defer alarm_rtc.stop();

    // Keep running past the alarm to detect any repeated interrupt.
    const advanced = for (0..poll_limit) |_| {
        if (alarm_rtc.counter() >= alarm_tick + 16) break true;
    } else false;
    const count = @atomicLoad(u32, &alarm_count, .acquire);
    const tick = @atomicLoad(u32, &observed_tick, .monotonic);
    harness.check(suite, "rtc1_alarm", advanced and count == 1 and
        tick >= alarm_tick and tick <= alarm_tick + 2, "advanced={} count={d} tick={d}", .{
        advanced, count, tick,
    });
}

fn check_gpiote() !void {
    const channel: nrf.gpiote.Channel = @fromBackingInt(0);
    // D6 is on the edge connector. Internal pulls drive it with no wiring.
    const pin = microzig.board.uart_tx;
    pin.set_direction(.in);
    pin.set_input_buffer(.connect);
    defer pin.set_input_buffer(.disconnect);
    pin.set_pull(.down);
    defer pin.set_pull(.disabled);
    const was_low = for (0..poll_limit) |_| {
        if (pin.read() == 0) break true;
    } else false;

    // PS v1.11 §6.10.3 forces the pin to input in Event mode.
    try channel.configure_event(pin, .rising);
    defer channel.disable();
    channel.clear_event();
    pin.set_pull(.up);
    const pending = for (0..poll_limit) |_| {
        if (channel.event_pending()) break true;
    } else false;
    const high = pin.read() == 1;
    channel.clear_event();
    harness.check(suite, "gpiote_edge", was_low and pending and high and !channel.event_pending(), "initial_low={} event={} high={}", .{ was_low, pending, high });
}

fn check_gpiote_port() void {
    const pin = microzig.board.led_r;
    pin.put(1);
    pin.set_input_buffer(.connect);
    defer pin.set_input_buffer(.disconnect);
    nrf.gpiote.set_port_interrupt(false);
    pin.set_sense(.low);
    defer {
        pin.set_sense(.disabled);
        pin.put(1);
        nrf.gpiote.clear_port();
    }
    nrf.gpiote.clear_port();
    pin.toggle();

    const pending = for (0..poll_limit) |_| {
        if (nrf.gpiote.port_pending()) break true;
    } else false;
    const level = pin.read();
    harness.check(suite, "gpiote_port", pending and level == 0, "event={} level={d}", .{ pending, level });
}

fn check_ppi() !void {
    const pin = microzig.board.led_r;
    const fork_pin = microzig.board.led_g;
    const output: nrf.gpiote.Channel = @fromBackingInt(1);
    const fork_output: nrf.gpiote.Channel = @fromBackingInt(2);
    pin.set_input_buffer(.connect);
    defer pin.set_input_buffer(.disconnect);
    fork_pin.set_input_buffer(.connect);
    defer fork_pin.set_input_buffer(.disconnect);
    try output.configure_task(pin, .toggle, 1);
    defer output.disable();
    try fork_output.configure_task(fork_pin, .toggle, 1);
    defer fork_output.disable();

    const timer: nrf.timer.Timer = .timer4;
    timer.stop();
    defer timer.stop();
    try timer.apply(.{ .prescaler = 4 });
    timer.set_compare(5, 250);
    // Stop later than the routed event, so both tasks have time to reach the pins.
    timer.set_compare(0, 500);
    timer.set_shortcuts(0, .{ .stop = true });
    defer timer.set_shortcuts(0, .{});

    const route: nrf.ppi.Channel = @fromBackingInt(0);
    const group: nrf.ppi.Group = .group0;
    route.disable();
    try route.connect(timer.compare_endpoint(5), output.task_endpoint(.out), fork_output.task_endpoint(.out));
    defer route.set_fork(null);
    group.set_channels(route.mask());
    defer group.set_channels(0);
    defer group.disable();

    for ([_]bool{ true, false }) |enable| {
        if (enable) group.enable() else group.disable();
        output.trigger(.set);
        fork_output.trigger(.set);
        timer.clear();
        timer.clear_compare(5);
        timer.clear_compare(0);
        timer.start();

        const stopped = for (0..poll_limit) |_| {
            if (timer.compare_pending(0)) break true;
        } else false;
        timer.stop();
        const fired = timer.compare_pending(5);
        const level = pin.read();
        const fork_level = fork_pin.read();
        const expected: u1 = if (enable) 0 else 1;
        const enabled = route.enabled();
        harness.check(suite, if (enable) "ppi_fork" else "ppi_group_disable", stopped and fired and enabled == enable and level == expected and fork_level == expected, "compare={} stop={} enabled={} primary={d} fork={d}", .{
            fired, stopped, enabled, level, fork_level,
        });
    }
}
