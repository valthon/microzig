//! ESP32-C6 TRM v1.2 §36.3.2, §36.3.3.1–36.3.3.2.
//! Owns the MCPWM group; timer 0 drives operator 0, generators A/B.
//! Count-up PWM with complementary outputs and symmetric edge dead time.
const microzig = @import("microzig");
const gpio = @import("gpio.zig");
const system = @import("system.zig");
comptime {
    if (@import("compatibility.zig").chip != .esp32_c6) @compileError("MCPWM requires ESP32-C6");
}
const PWM = microzig.chip.peripherals.MCPWM0;
const PCR = microzig.chip.peripherals.PCR;
pub const ClockSource = enum(u2) { pll_f160m_clk = 1, xtal_clk = 2 };
pub const Output = enum { a, b };
pub const Config = struct {
    clock_source: ClockSource = .xtal_clk,
    /// Actual divisors, 1..256. PWM tick = source / group / timer.
    group_divider: u9 = 40,
    timer_divider: u9 = 1,
    /// Actual period, 2..65536 timer ticks (register stores period - 1).
    period_ticks: u17 = 1000,
    /// Strictly inside the period. Constant 0%/100% outputs are not supported.
    high_ticks: u16 = 500,
    /// Timer ticks, applied to A's rising edge and complementary B's rising edge.
    /// Zero bypasses both delay paths. Must fit in both high and low intervals.
    dead_ticks: u16 = 0,
};
pub const Error = error{ InvalidDivider, InvalidPeriod, InvalidDuty, InvalidDeadTime };

/// Resets the whole MCPWM group. Disconnect output pads before reconfiguring.
/// Callers must not share this group with capture, faults or other operators.
pub fn apply(config: Config) Error!void {
    if (config.group_divider == 0 or config.group_divider > 256 or config.timer_divider == 0 or config.timer_divider > 256) return error.InvalidDivider;
    if (config.period_ticks < 2 or config.period_ticks > 65536) return error.InvalidPeriod;
    if (config.high_ticks == 0 or config.high_ticks >= config.period_ticks) return error.InvalidDuty;
    if (config.dead_ticks >= config.high_ticks or config.dead_ticks >= config.period_ticks - config.high_ticks) return error.InvalidDeadTime;
    system.enable_clocks_and_release_reset(.{ .mcpwm = true });
    system.peripheral_reset(.{ .mcpwm = true });
    // C6's functional clock is in PCR (TRM §8.2.4, PWM_CLK_CONF).
    PCR.PWM_CLK_CONF.modify(.{ .PWM_CLKM_EN = 1, .PWM_CLKM_SEL = @backingInt(config.clock_source), .PWM_DIV_NUM = @as(u8, @intCast(config.group_divider - 1)) });
    PWM.CLK_CFG.write(.{ .CLK_PRESCALE = 0 });
    PWM.UPDATE_CFG.modify(.{ .GLOBAL_UP_EN = 1, .OP0_UP_EN = 1 });
    PWM.TIMER0_CFG0.write(.{ .TIMER0_PRESCALE = @intCast(config.timer_divider - 1), .TIMER0_PERIOD = @intCast(config.period_ticks - 1), .TIMER0_PERIOD_UPMETHOD = 0 });
    PWM.OPERATOR_TIMERSEL.modify(.{ .OPERATOR0_TIMERSEL = 0 });
    PWM.GEN0_STMP_CFG.write(.{ .CMPR0_A_UPMETHOD = 0, .CMPR0_B_UPMETHOD = 0 });
    PWM.GEN0_TSTMP_A.write(.{ .CMPR0_A = config.high_ticks });
    PWM.GEN0_CFG0.write(.{ .GEN0_CFG_UPMETHOD = 0 });
    // TEZ sets A high, comparator A clears it. B is its inverse.
    PWM.GEN0_A.write(.{ .UTEZ = 2, .UTEA = 1 });
    PWM.GEN0_B.write(.{ .UTEZ = 1, .UTEA = 2 });
    if (config.dead_ticks == 0) {
        PWM.DT0_CFG.write(.{ .DB0_A_OUTBYPASS = 1, .DB0_B_OUTBYPASS = 1 });
    } else {
        // RED(A) -> output A; inverted FED(A) -> output B.
        // Both paths use timer ticks; delay registers encode ticks - 1.
        PWM.DT0_RED_CFG.write(.{ .DB0_RED = config.dead_ticks - 1 });
        PWM.DT0_FED_CFG.write(.{ .DB0_FED = config.dead_ticks - 1 });
        PWM.DT0_CFG.write(.{ .DB0_A_OUTBYPASS = 0, .DB0_B_OUTBYPASS = 0, .DB0_RED_INSEL = 0, .DB0_FED_INSEL = 0, .DB0_FED_OUTINVERT = 1, .DB0_RED_OUTINVERT = 0, .DB0_CLK_SEL = 1, .DB0_RED_UPMETHOD = 0, .DB0_FED_UPMETHOD = 0 });
    }
    PWM.UPDATE_CFG.modify(.{ .GLOBAL_FORCE_UP = 1 });
    PWM.UPDATE_CFG.modify(.{ .GLOBAL_FORCE_UP = 0 });
    PWM.TIMER0_CFG1.write(.{ .TIMER0_MOD = 1, .TIMER0_START = 2 });
}

pub fn connect_pin(output: Output, pin: gpio.Pin) void {
    pin.connect_peripheral_to_output(.{ .signal = switch (output) {
        .a => .mcpwm0_a,
        .b => .mcpwm0_b,
    } });
}

/// Freeze/resume the timer; outputs hold their current levels when frozen.
/// Disable the pads separately when electrical shutdown is required.
pub fn pause(paused: bool) void {
    PWM.TIMER0_CFG1.modify(.{ .TIMER0_MOD = @as(u2, if (paused) 0 else 1) });
}
