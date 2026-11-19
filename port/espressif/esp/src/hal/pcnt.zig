//! ESP32-C6 TRM v1.2 §31.2–31.3: signed edge counters and watchpoints.
//! Polling API. Each unit owns channel 0; channel 1 is disabled.
const microzig = @import("microzig");
const gpio = @import("gpio.zig");
const system = @import("system.zig");
comptime {
    if (@import("compatibility.zig").chip != .esp32_c6) @compileError("PCNT requires ESP32-C6");
}
const PCNT = microzig.chip.peripherals.PCNT;

/// Call once before configuring units; does not reset other units.
pub fn apply() void {
    system.enable_clocks_and_release_reset(.{ .pcnt = true });
}
pub fn unit(index: u2) Unit {
    return @fromBackingInt(@intCast(index));
}
pub const EdgeAction = enum(u2) { hold, increment, decrement };
pub const Config = struct {
    low_limit: i16 = -32768,
    high_limit: i16 = 32767,
    threshold0: i16 = 0,
    threshold1: i16 = 0,
    rising: EdgeAction = .increment,
    falling: EdgeAction = .hold,
    /// APB cycles; zero bypasses the filter. C6 APB normally runs at 40 MHz.
    filter_cycles: u10 = 0,
};
pub const Events = struct { threshold0: bool, threshold1: bool, low_limit: bool, high_limit: bool, zero: bool };
pub const Unit = enum(u2) {
    unit0,
    unit1,
    unit2,
    unit3,
    pub fn apply(self: Unit, config: Config) error{ InvalidLimits, InvalidThreshold }!void {
        if (config.low_limit >= 0 or config.high_limit <= 0) return error.InvalidLimits;
        if (config.threshold0 < config.low_limit or config.threshold0 > config.high_limit or
            config.threshold1 < config.low_limit or config.threshold1 > config.high_limit) return error.InvalidThreshold;
        self.pause(true);
        const regs = self.config_regs();
        regs.conf2.write(.{ .CNT_H_LIM_U = @bitCast(config.high_limit), .CNT_L_LIM_U = @bitCast(config.low_limit) });
        regs.conf1.write(.{ .CNT_THRES0_U = @bitCast(config.threshold0), .CNT_THRES1_U = @bitCast(config.threshold1) });
        regs.conf0.write(.{
            .FILTER_THRES_U = config.filter_cycles,
            .FILTER_EN_U = @intFromBool(config.filter_cycles != 0),
            .THR_ZERO_EN_U = 1,
            .THR_H_LIM_EN_U = 1,
            .THR_L_LIM_EN_U = 1,
            .THR_THRES0_EN_U = 1,
            .THR_THRES1_EN_U = 1,
            .CH0_POS_MODE_U = @backingInt(config.rising),
            .CH0_NEG_MODE_U = @backingInt(config.falling),
            .CH0_HCTRL_MODE_U = 0,
            .CH0_LCTRL_MODE_U = 0,
            .CH1_POS_MODE_U = 0,
            .CH1_NEG_MODE_U = 0,
        });
        self.clear();
        self.clear_events();
    }
    /// Enable the pad input buffer before routing it; control levels are ignored.
    pub fn connect_pin(self: Unit, pin: gpio.Pin) void {
        pin.connect_input_to_peripheral(.{ .signal = @fromBackingInt(@intCast(@as(u8, 101) + @as(u8, @backingInt(self)) * 4)) });
    }
    pub fn count(self: Unit) i16 {
        return @bitCast(self.count_reg().read().PULSE_CNT_U);
    }
    pub fn events(self: Unit) Events {
        const value = self.status_reg().read();
        return .{ .threshold0 = value.CNT_THR_THRES0_LAT_U == 1, .threshold1 = value.CNT_THR_THRES1_LAT_U == 1, .low_limit = value.CNT_THR_L_LIM_LAT_U == 1, .high_limit = value.CNT_THR_H_LIM_LAT_U == 1, .zero = value.CNT_THR_ZERO_LAT_U == 1 };
    }
    pub fn pause(self: Unit, enabled: bool) void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        switch (self) {
            .unit0 => PCNT.CTRL.modify(.{ .CNT_PAUSE_U0 = @intFromBool(enabled) }),
            .unit1 => PCNT.CTRL.modify(.{ .CNT_PAUSE_U1 = @intFromBool(enabled) }),
            .unit2 => PCNT.CTRL.modify(.{ .CNT_PAUSE_U2 = @intFromBool(enabled) }),
            .unit3 => PCNT.CTRL.modify(.{ .CNT_PAUSE_U3 = @intFromBool(enabled) }),
        }
    }
    fn reset(self: Unit, enabled: bool) void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        switch (self) {
            .unit0 => PCNT.CTRL.modify(.{ .PULSE_CNT_RST_U0 = @intFromBool(enabled) }),
            .unit1 => PCNT.CTRL.modify(.{ .PULSE_CNT_RST_U1 = @intFromBool(enabled) }),
            .unit2 => PCNT.CTRL.modify(.{ .PULSE_CNT_RST_U2 = @intFromBool(enabled) }),
            .unit3 => PCNT.CTRL.modify(.{ .PULSE_CNT_RST_U3 = @intFromBool(enabled) }),
        }
    }
    pub fn clear(self: Unit) void {
        self.reset(true);
        self.reset(false);
    }
    pub fn clear_events(self: Unit) void {
        switch (self) {
            .unit0 => PCNT.INT_CLR.write(.{ .CNT_THR_EVENT_U0_INT_CLR = 1 }),
            .unit1 => PCNT.INT_CLR.write(.{ .CNT_THR_EVENT_U1_INT_CLR = 1 }),
            .unit2 => PCNT.INT_CLR.write(.{ .CNT_THR_EVENT_U2_INT_CLR = 1 }),
            .unit3 => PCNT.INT_CLR.write(.{ .CNT_THR_EVENT_U3_INT_CLR = 1 }),
        }
    }
    const Registers = extern struct { conf0: @TypeOf(PCNT.U0_CONF0), conf1: @TypeOf(PCNT.U0_CONF1), conf2: @TypeOf(PCNT.U0_CONF2) };
    fn config_regs(self: Unit) *volatile Registers {
        return switch (self) {
            .unit0 => @ptrCast(&PCNT.U0_CONF0),
            .unit1 => @ptrCast(&PCNT.U1_CONF0),
            .unit2 => @ptrCast(&PCNT.U2_CONF0),
            .unit3 => @ptrCast(&PCNT.U3_CONF0),
        };
    }
    fn count_reg(self: Unit) *volatile @TypeOf(PCNT.U0_CNT) {
        return switch (self) {
            .unit0 => @ptrCast(&PCNT.U0_CNT),
            .unit1 => @ptrCast(&PCNT.U1_CNT),
            .unit2 => @ptrCast(&PCNT.U2_CNT),
            .unit3 => @ptrCast(&PCNT.U3_CNT),
        };
    }
    fn status_reg(self: Unit) *volatile @TypeOf(PCNT.U0_STATUS) {
        return switch (self) {
            .unit0 => @ptrCast(&PCNT.U0_STATUS),
            .unit1 => @ptrCast(&PCNT.U1_STATUS),
            .unit2 => @ptrCast(&PCNT.U2_STATUS),
            .unit3 => @ptrCast(&PCNT.U3_STATUS),
        };
    }
};
