//! No external wiring. ESP32-C6 TRM v1.2 §§1.5.2, 6.3, 7.4, 8.2.4, 13.3–13.4.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const csr = microzig.cpu.csr;
const SYSTIMER = microzig.chip.peripherals.SYSTIMER;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .log_level = .info,
    .logFn = hal.usb_serial_jtag.logger.log,
});

comptime {
    if (hal.compatibility.chip != .esp32_c6) @compileError("selftest_c6_core requires ESP32-C6");
    _ = microzig.export_startup();
}

const Result = struct {
    name: []const u8,
    expected: u64,
    actual: u64,
    pass: bool,
};

fn within_percent(actual: u64, expected: u64) bool {
    return actual >= expected - expected / 100 and actual <= expected + expected / 100;
}

// Use bounded register snapshots here so a broken timer produces FAIL instead
// of hanging inside the HAL's normal timer reader.
fn timer_ticks() ?u52 {
    SYSTIMER.UNIT0_OP.modify(.{ .TIMER_UNIT0_UPDATE = 1 });
    for (0..100_000) |_| {
        if (SYSTIMER.UNIT0_OP.read().TIMER_UNIT0_VALUE_VALID == 1) {
            return (@as(u52, SYSTIMER.UNIT0_VALUE_HI.read().TIMER_UNIT0_VALUE_HI) << 32) |
                SYSTIMER.UNIT0_VALUE_LO.read().TIMER_UNIT0_VALUE_LO;
        }
    }
    return null;
}

fn cycle_count() u32 {
    return csr.mpccr.read_raw();
}

fn measure_cpu_hz() u64 {
    const start_ticks = timer_ticks() orelse return 0;
    const start_cycles = cycle_count();
    // 100 milliseconds at the documented 16 MHz systimer rate keeps snapshot
    // overhead below the tolerance even at 1.25 MHz. The cycle bound is
    // independent of the timer and covers even a stalled systimer.
    while (cycle_count() -% start_cycles < 32_000_000) {
        const ticks = timer_ticks() orelse return 0;
        const elapsed = ticks -% start_ticks;
        if (elapsed >= 1_600_000) {
            const cycles = cycle_count() -% start_cycles;
            return @as(u64, cycles) * 16_000_000 / elapsed;
        }
    }
    return 0;
}

fn measure_timer_hz() u64 {
    const start_ticks = timer_ticks() orelse return 0;
    const start_cycles = cycle_count();
    while (cycle_count() -% start_cycles < 800_000) {}
    const end_ticks = timer_ticks() orelse return 0;
    const elapsed_cycles = cycle_count() -% start_cycles;
    return @as(u64, end_ticks -% start_ticks) * 80_000_000 / elapsed_cycles;
}

fn gpio_loopback() bool {
    // GPIO0 is a chip pad, not an assertion about this board's LED wiring.
    // Read GPIO_IN through the enabled input buffer on that very same pad.
    const pin = hal.gpio.num(0);
    pin.put(0);
    pin.apply(.{ .output_enable = true, .input_enable = true });
    defer pin.apply(.{});
    var pass = true;
    for ([_]u1{ 0, 1, 0, 1, 1, 0 }) |level| {
        pin.put(level);
        hal.rom.delay_us(10);
        if (pin.read() != level) pass = false;
    }
    pin.set_output_invert(true);
    pin.put(1);
    hal.rom.delay_us(10);
    if (pin.read() != 0) pass = false;
    pin.set_output_invert(false);

    // Inversion belongs to a peripheral signal, not the pad index. Restore
    // UART0's routing after probing signal 6 through pad 0.
    const GPIO = microzig.chip.peripherals.GPIO;
    const saved = GPIO.FUNC6_IN_SEL_CFG.read();
    defer GPIO.FUNC6_IN_SEL_CFG.write(saved);
    pin.connect_input_to_peripheral(.{ .signal = .u0rxd });
    hal.gpio.InputSignal.u0rxd.set_input_invert(true);
    const routed = GPIO.FUNC6_IN_SEL_CFG.read();
    if (routed.FUNC6_IN_SEL != 0 or routed.FUNC6_IN_INV_SEL != 1 or routed.SIG6_IN_SEL != 1) pass = false;
    hal.gpio.InputSignal.u0rxd.set_input_invert(false);
    if (GPIO.FUNC6_IN_SEL_CFG.read().FUNC6_IN_INV_SEL != 0) pass = false;
    return pass;
}

fn load_hi() bool {
    hal.systimer.unit(1).apply(.disabled);
    const expected: u52 = 0xabcde_12345678;
    hal.systimer.unit(1).write(expected);
    SYSTIMER.UNIT1_OP.modify(.{ .TIMER_UNIT1_UPDATE = 1 });
    for (0..100_000) |_| {
        if (SYSTIMER.UNIT1_OP.read().TIMER_UNIT1_VALUE_VALID == 1) {
            const actual = (@as(u52, SYSTIMER.UNIT1_VALUE_HI.read().TIMER_UNIT1_VALUE_HI) << 32) |
                SYSTIMER.UNIT1_VALUE_LO.read().TIMER_UNIT1_VALUE_LO;
            return actual == expected;
        }
    }
    return false;
}

pub fn main() void {
    // C6 HP CPU's counter is MPCCR, not the LP CPU's mcycle.
    csr.mpcmr.write(.{ .count_en = 0, .count_sat = 0 });
    csr.mpcer.write(.{ .cycle = 1 });
    csr.mpccr.write_raw(0);
    csr.mpcmr.write(.{ .count_en = 1, .count_sat = 0 });

    // Every supported frequency, including all six power-of-two XTAL dividers.
    const frequencies = [_]u32{ 1_250_000, 2_500_000, 5_000_000, 10_000_000, 20_000_000, 40_000_000, 80_000_000, 120_000_000, 160_000_000 };
    const transitions = comptime blk: {
        @setEvalBranchQuota(100_000);
        const Transition = struct {
            from: hal.clocks.Config,
            to: hal.clocks.Config,
            name: []const u8,
        };
        var entries: [frequencies.len * frequencies.len]Transition = undefined;
        for (frequencies, 0..) |from, i| {
            for (frequencies, 0..) |to, j| {
                entries[i * frequencies.len + j] = .{
                    .from = hal.clocks.Config.init_comptime(from),
                    .to = hal.clocks.Config.init_comptime(to),
                    .name = std.fmt.comptimePrint("cpu_{}hz_to_{}hz", .{ from, to }),
                };
            }
        }
        break :blk entries;
    };
    var results: [transitions.len + 4]Result = undefined;
    const initial_config = comptime hal.clocks.Config.init_comptime(80_000_000);
    initial_config.apply();
    const timer_hz = measure_timer_hz();
    results[0] = .{ .name = "systimer_rate", .expected = 16_000_000, .actual = timer_hz, .pass = within_percent(timer_hz, 16_000_000) };
    for (transitions, 0..) |transition, i| {
        transition.from.apply();
        transition.to.apply();
        const measured = measure_cpu_hz();
        results[i + 1] = .{
            .name = transition.name,
            .expected = transition.to.cpu_clk_freq,
            .actual = measured,
            .pass = within_percent(measured, transition.to.cpu_clk_freq),
        };
    }
    hal.clock_config.apply();
    const gpio_index = transitions.len + 1;
    results[gpio_index] = .{ .name = "gpio_loopback", .expected = 1, .actual = @intFromBool(gpio_loopback()), .pass = false };
    results[gpio_index].pass = results[gpio_index].actual == 1;
    const mac = hal.efuse.read_mac();
    var mac_value: u48 = 0;
    for (mac) |byte| mac_value = (mac_value << 8) | byte;
    results[transitions.len + 2] = .{ .name = "mac", .expected = 0x9888e07efc74, .actual = mac_value, .pass = mac_value == 0x9888e07efc74 };
    const load_index = transitions.len + 3;
    results[load_index] = .{ .name = "systimer_load_hi", .expected = 1, .actual = @intFromBool(load_hi()), .pass = false };
    results[load_index].pass = results[load_index].actual == 1;

    // Exercise the C6 RNG access too; this is not an entropy certification.
    if (results[0].pass) _ = hal.rng.random_u32();

    // Use ROM delays so failed systimer checks cannot suppress their reports.
    hal.rom.delay_us(1_500_000);
    while (true) {
        var passed: usize = 0;
        for (results) |result| {
            const verdict: []const u8 = if (result.pass) "PASS" else "FAIL";
            if (result.pass) passed += 1;
            if (std.mem.eql(u8, result.name, "mac")) {
                std.log.info("SELFTEST c6_core mac: {s} expected=98:88:e0:7e:fc:74 actual={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ verdict, mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] });
            } else {
                std.log.info("SELFTEST c6_core {s}: {s} expected={} actual={}", .{ result.name, verdict, result.expected, result.actual });
            }
        }
        std.log.info("SELFTEST c6_core DONE pass={} fail={}", .{ passed, results.len - passed });
        hal.rom.delay_us(1_000_000);
    }
}
