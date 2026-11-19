//! ESP32-C6 RTC/LP timer: TRM v1.2 §§12.4.3, 12.10.3, Table 3.9-1.
//! Own target 1 and software snapshot triggers exclusively (HP or LP).
//! Target 0, the RTC slow clock source and its calibration are left alone.
const microzig = @import("microzig");
const t = microzig.chip.peripherals.LP_TIMER;

/// Snapshot count in LP_SLOW_CLK ticks, not microseconds. Sequence follows
/// ESP-IDF rtc_timer_ll_get_cycle_count(0). Other snapshot users must serialize.
pub fn now() u48 {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    t.UPDATE.modify(.{ .MAIN_TIMER_UPDATE = 1 });
    const lo = t.MAIN_BUF0_LOW.read().MAIN_TIMER_BUF0_LOW;
    const hi = t.MAIN_BUF0_HIGH.read().MAIN_TIMER_BUF0_HIGH;
    return (@as(u48, hi) << 32) | lo;
}

pub fn pending() bool {
    return t.LP_INT_RAW.read().MAIN_TIMER_LP_INT_RAW != 0;
}

pub fn acknowledge() void {
    t.LP_INT_CLR.write(.{ .MAIN_TIMER_LP_INT_CLR = 1 });
}

/// One shot; LP must rearm before each halt for periodic reset/wake operation.
/// The caller must allow enough ticks for its work and the PMU sleep flow.
pub fn arm_after(ticks: u47) error{InvalidInterval}!void {
    if (ticks < 8) return error.InvalidInterval;
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    const target = now() +% @as(u48, ticks);
    t.TAR1_HIGH.modify(.{ .MAIN_TIMER_TAR_EN1 = 0 });
    acknowledge();
    t.TAR1_LOW.write(.{ .MAIN_TIMER_TAR_LOW1 = @truncate(target) });
    t.TAR1_HIGH.write(.{ .MAIN_TIMER_TAR_HIGH1 = @truncate(target >> 32), .MAIN_TIMER_TAR_EN1 = 1 });
    t.LP_INT_ENA.modify(.{ .MAIN_TIMER_LP_INT_ENA = 1 });
}

pub fn disable() void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    t.TAR1_HIGH.modify(.{ .MAIN_TIMER_TAR_EN1 = 0 });
    t.LP_INT_ENA.modify(.{ .MAIN_TIMER_LP_INT_ENA = 0 });
    acknowledge();
}
