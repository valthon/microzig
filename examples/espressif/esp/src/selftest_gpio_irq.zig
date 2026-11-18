//! No wiring: GPIO0's matrix output is read through its own input buffer.
//! C3 TRM v1.4 §§5.4.4, 5.5.3, 5.15.1; C6 TRM v1.2 §§7.4.4, 7.5.3, 7.16.1.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const irq = microzig.cpu.interrupt;
const pin = hal.gpio.num(0);
const other = hal.gpio.num(1);

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .log_level = .info,
    .logFn = hal.usb_serial_jtag.logger.log,
});
pub const microzig_options: microzig.Options = .{
    .interrupts = .{ .interrupt1 = .{ .c = gpio_interrupt } },
};

comptime {
    _ = microzig.export_startup();
}

const State = struct {
    entries: u32 = 0,
    status_hits: u32 = 0,
    level: bool = false,
    inactive: u1 = 0,
};
// Main accesses all ISR state inside critical sections.
var state: State = .{};

fn gpio_interrupt(_: *microzig.cpu.TrapFrame) callconv(.c) void {
    state.entries += 1;
    if (pin.interrupt_status()) {
        state.status_hits += 1;
        if (state.level) {
            // Stop a persistent level before acknowledgement. No waits in ISR.
            pin.set_interrupt_type(.disabled);
            pin.put(state.inactive);
        }
        pin.clear_interrupt();
    }
    // A broken acknowledgement must produce FAIL, not starve the reporter.
    if (state.entries >= 64) irq.disable(.interrupt1);
}

fn snapshot() State {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    return state;
}

fn reset_state(level: bool, inactive: u1) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    state = .{ .level = level, .inactive = inactive };
}

const Result = struct {
    name: []const u8,
    expected: u32,
    actual: u32,
    passed: bool,
};

fn prepare(event: hal.gpio.Event, initial: u1, level: bool) void {
    irq.disable(.interrupt1);
    pin.set_interrupt_enabled(false);
    pin.set_interrupt_type(.disabled);
    pin.put(initial);
    hal.rom.delay_us(100);
    pin.clear_interrupt();
    reset_state(level, initial);
    pin.set_interrupt_type(event);
    pin.set_interrupt_enabled(true);
    irq.enable(.interrupt1);
}

fn drive(value: u1) bool {
    pin.put(value);
    // Fixed, bounded observation window also catches unexpected extra entries.
    hal.rom.delay_us(100);
    return pin.read() == value;
}

fn edge_check(name: []const u8, event: hal.gpio.Event, expected: u32) Result {
    prepare(event, 0, false);
    var readback = true;
    // Seven complete cycles: exactly seven rising and seven falling edges.
    for (0..7) |_| {
        if (!drive(1)) readback = false;
        if (!drive(0)) readback = false;
    }
    irq.disable(.interrupt1);
    const actual = snapshot();
    return .{
        .name = name,
        .expected = expected,
        .actual = actual.entries,
        .passed = readback and actual.entries == expected and actual.status_hits == expected and !pin.interrupt_status(),
    };
}

fn level_check(name: []const u8, event: hal.gpio.Event, inactive: u1) Result {
    prepare(event, inactive, true);
    pin.put(inactive ^ 1);
    hal.rom.delay_us(100);
    irq.disable(.interrupt1);
    const actual = snapshot();
    const passed = actual.entries == 1 and actual.status_hits == 1 and
        pin.read() == inactive and !pin.interrupt_status();
    pin.set_interrupt_type(.disabled);
    pin.clear_interrupt();
    return .{ .name = name, .expected = 1, .actual = actual.entries, .passed = passed };
}

fn enable_check() Result {
    prepare(.rising_edge, 0, false);
    pin.set_interrupt_enabled(false);
    var readback = drive(1);
    readback = drive(0) and readback;
    const masked = snapshot();
    const latched = pin.interrupt_status();
    pin.clear_interrupt();
    const cleared = !pin.interrupt_status();
    pin.set_interrupt_enabled(true);
    readback = drive(1) and readback;
    irq.disable(.interrupt1);
    const actual = snapshot();
    return .{
        .name = "enable_disable",
        .expected = 1,
        .actual = actual.entries,
        .passed = readback and latched and cleared and masked.entries == 0 and
            actual.entries == 1 and actual.status_hits == 1 and !pin.interrupt_status(),
    };
}

fn status_clear_check() Result {
    // Latch real edges on two pads with CPU delivery masked. Clearing GPIO0
    // must preserve GPIO1, and clearing GPIO1 must then leave both clear.
    prepare(.rising_edge, 0, false);
    irq.disable(.interrupt1);
    other.put(0);
    other.apply(.{ .output_enable = true, .input_enable = true });
    defer other.apply(.{});
    other.set_interrupt_enabled(false);
    other.set_interrupt_type(.disabled);
    hal.rom.delay_us(100);
    other.clear_interrupt();
    other.set_interrupt_type(.rising_edge);
    const readback = drive(1);
    other.put(1);
    hal.rom.delay_us(100);
    const both_set = pin.interrupt_status() and other.interrupt_status();
    pin.clear_interrupt();
    const isolated = !pin.interrupt_status() and other.interrupt_status();
    other.clear_interrupt();
    const both_clear = !pin.interrupt_status() and !other.interrupt_status();
    other.set_interrupt_type(.disabled);
    const passed = readback and other.read() == 1 and both_set and isolated and both_clear and snapshot().entries == 0;
    return .{ .name = "status_clear", .expected = 1, .actual = @intFromBool(passed), .passed = passed };
}

fn lp_mux_check() Result {
    // Simulate preceding LP/analog firmware without relying on a chip reset.
    // C6 TRM v1.2 §§7.7.1–7.7.3; §12.10, Register 12.59.
    const mux = &microzig.chip.peripherals.LP_AON.GPIO_MUX;
    const mask = @as(u8, 1) << @backingInt(pin);
    pin.set_interrupt_enabled(false);
    pin.set_interrupt_type(.disabled);
    const original = mux.read().SEL;
    mux.modify(.{ .SEL = original | mask });
    const seeded = mux.read().SEL == original | mask;
    pin.put(0);
    pin.apply(.{ .input_enable = true, .output_enable = true });
    const reclaimed = mux.read().SEL == original & ~mask;
    const high = drive(1);
    const low = drive(0);
    const passed = seeded and reclaimed and high and low;
    return .{ .name = "lp_mux_reclaim", .expected = 1, .actual = @intFromBool(passed), .passed = passed };
}

pub fn main() void {
    const mux_results = if (hal.compatibility.chip == .esp32_c6)
        [_]Result{lp_mux_check()}
    else
        [_]Result{};
    pin.put(0);
    pin.apply(.{ .input_enable = true, .output_enable = true });
    pin.connect_peripheral_to_output(.{ .signal = .gpio });
    // GPIO's latched status drives a level source even for pad edge triggers.
    // C3 TRM §§8.3.1–8.3.3; C6 TRM §§10.3.1–10.3.3.
    irq.disable(.interrupt1);
    irq.set_type(.interrupt1, .level);
    irq.set_priority(.interrupt1, .highest);
    irq.map(.gpio, .interrupt1);
    irq.enable_interrupts();

    const results = mux_results ++ [_]Result{
        edge_check("rising", .rising_edge, 7),
        edge_check("falling", .falling_edge, 7),
        edge_check("any_edge", .any_edge, 14),
        level_check("low_level", .low_level, 1),
        level_check("high_level", .high_level, 0),
        edge_check("disabled_type", .disabled, 0),
        enable_check(),
        status_clear_check(),
    };
    irq.disable(.interrupt1);
    irq.map(.gpio, null);
    pin.set_interrupt_enabled(false);
    pin.set_interrupt_type(.disabled);
    pin.clear_interrupt();
    pin.apply(.{});

    hal.rom.delay_us(1_500_000);
    while (true) {
        var passed: usize = 0;
        for (results) |result| {
            if (result.passed) passed += 1;
            std.log.info("SELFTEST gpio_irq {s}: {s} expected={} actual={}", .{
                result.name, if (result.passed) @as([]const u8, "PASS") else "FAIL", result.expected, result.actual,
            });
        }
        std.log.info("SELFTEST gpio_irq DONE pass={} fail={}", .{ passed, results.len - passed });
        hal.rom.delay_us(1_000_000);
    }
}
