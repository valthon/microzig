//! C3/C6 custom 20 MHz clock demo: expected
//! SELFTEST custom_clock_config DONE pass=3 fail=0 (CPU, APB, busy_delay).
//! The ROM's CPU-calibrated busy loop requests 100 ms; systimer must measure
//! 100 ms +/-100 us (see `tolerance_us`). No systimer-based sleep is used in
//! the measured loop.
//! Clock readback: C3 TRM v1.4 section 6.2 (XTAL/PRE_DIV_CNT);
//! C6 TRM v1.2 section 8.2.4.1 (root/CPU/AHB/APB dividers).
//! Systimer latch: C3 TRM v1.4 section 10.5.1; C6 TRM v1.2 section 13.5.1.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const clocks = hal.clocks;
const usb_serial_jtag = hal.usb_serial_jtag;

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .logFn = usb_serial_jtag.logger.log,
});

comptime {
    _ = microzig.export_startup();
}

// Clock config with a cpu speed of 20mhz.
const clock_config: clocks.Config = .init_comptime(20_000_000);

// Have to override init() so we can apply our own custom pre-main startup procedure.
pub fn init() void {
    // Use the recommended init sequence with a custom clock config.
    hal.init_sequence(clock_config);
}

// Decode only the XTAL path this demo requests. Other sources fail rather
// than accidentally reporting the requested frequency from a software cache.
fn read_clock_hz() struct { cpu: u32, apb: u32 } {
    const p = microzig.chip.peripherals;
    switch (hal.compatibility.chip) {
        .esp32_c3 => {
            const sys = p.SYSTEM.SYSCLK_CONF.read();
            if (sys.SOC_CLK_SEL != 0) return .{ .cpu = 0, .apb = 0 };
            const hz = clocks.xtal_clk_freq / (@as(u32, sys.PRE_DIV_CNT) + 1);
            return .{ .cpu = hz, .apb = hz };
        },
        .esp32_c6 => {
            const sys = p.PCR.SYSCLK_CONF.read();
            if (sys.SOC_CLK_SEL != 0) return .{ .cpu = 0, .apb = 0 };
            const root = clocks.xtal_clk_freq / (@as(u32, sys.LS_DIV_NUM) + 1);
            const cpu = root / (@as(u32, p.PCR.CPU_FREQ_CONF.read().CPU_LS_DIV_NUM) + 1);
            const ahb = root / (@as(u32, p.PCR.AHB_FREQ_CONF.read().AHB_LS_DIV_NUM) + 1);
            const apb = p.PCR.APB_FREQ_CONF.read();
            // Automatic reduction must also be disabled for a fixed APB rate.
            return .{
                .cpu = cpu,
                .apb = if (apb.APB_DECREASE_DIV_NUM == 0)
                    ahb / (@as(u32, apb.APB_DIV_NUM) + 1)
                else
                    0,
            };
        },
    }
}

fn systimer_ticks() error{Timeout}!u52 {
    const s = microzig.chip.peripherals.SYSTIMER;
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    s.UNIT0_OP.modify(.{ .TIMER_UNIT0_UPDATE = 1 });
    for (0..100_000) |_| {
        if (s.UNIT0_OP.read().TIMER_UNIT0_VALUE_VALID == 1) {
            const lo = s.UNIT0_VALUE_LO.read().TIMER_UNIT0_VALUE_LO;
            return (@as(u52, s.UNIT0_VALUE_HI.read().TIMER_UNIT0_VALUE_HI) << 32) | lo;
        }
    }
    return error.Timeout;
}

const delay_us = 100_000;
// The CPU (XTAL/2 here) and the systimer (XTAL/2.5) run from the same 40 MHz
// crystal, so a correctly calibrated busy delay differs from the systimer
// interval only by call and latch overhead: measured 100,004 to 100,005 us on
// the C3, Super Mini and XIAO. 100 us keeps margin for that while still failing
// a calibration off by one CPU tick per us, which is off by 5% (1 of 20).
const tolerance_us = 100;

fn measure_busy_delay() !u64 {
    const start = try systimer_ticks();
    // ESP-IDF v5.5.1 esp_rom_sys.h documents that this busy delay depends on
    // CPU ticks/us; Config.apply updates that calibration for the custom clock.
    hal.rom.delay_us(delay_us);
    return (try systimer_ticks() -% start) / hal.systimer.ticks_per_us();
}

pub fn main() void {
    const hz = read_clock_hz();
    var measured = true;
    const elapsed = measure_busy_delay() catch |err| blk: {
        measured = false;
        std.log.err("busy delay measurement: {s}", .{@errorName(err)});
        break :blk 0;
    };
    const cpu_ok = hz.cpu == clock_config.cpu_clk_freq;
    const apb_ok = hz.apb == clock_config.apb_clk_freq;
    const delay_ok = measured and elapsed >= delay_us - tolerance_us and elapsed <= delay_us + tolerance_us;
    const pass: usize = @as(usize, @intFromBool(cpu_ok)) + @intFromBool(apb_ok) + @intFromBool(delay_ok);

    hal.time.sleep_ms(1500);
    var ticks: u32 = 0;
    while (true) {
        std.log.info("Hello from Zig! Tick number {}.", .{ticks});
        ticks +%= 1;
        std.log.info("SELFTEST custom_clock_config cpu: {s} hz={d} expected={d}", .{
            if (cpu_ok) "PASS" else "FAIL", hz.cpu, clock_config.cpu_clk_freq,
        });
        std.log.info("SELFTEST custom_clock_config apb: {s} hz={d} expected={d}", .{
            if (apb_ok) "PASS" else "FAIL", hz.apb, clock_config.apb_clk_freq,
        });
        std.log.info("SELFTEST custom_clock_config busy_delay: {s} us={d} expected={d} tolerance_us={d}", .{
            if (delay_ok) "PASS" else "FAIL", elapsed, delay_us, tolerance_us,
        });
        std.log.info("SELFTEST custom_clock_config DONE pass={d} fail={d}", .{ pass, 3 - pass });
        hal.rom.delay_us(1_000_000);
    }
}
