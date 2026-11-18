// C6 TRM v1.2 §14.6: the SVD spells timer-0 registers/fields T instead of T0.
const microzig = @import("microzig");
const timer = @import("../timer.zig");

pub fn configure_timer(group: timer.Group, config: timer.Group.Config) void {
    const r = group.registers();
    // C6 TRM v1.2 §14.3.1; PCR registers 8.15/8.18 (§8.5.1).
    const pcr = microzig.chip.peripherals.PCR;
    switch (group) {
        .timg0 => pcr.TIMERGROUP0_TIMER_CLK_CONF.modify(.{ .TG0_TIMER_CLK_SEL = @as(u2, if (config.use_xtal) 0 else 1), .TG0_TIMER_CLK_EN = 1 }),
        .timg1 => pcr.TIMERGROUP1_TIMER_CLK_CONF.modify(.{ .TG1_TIMER_CLK_SEL = @as(u2, if (config.use_xtal) 0 else 1), .TG1_TIMER_CLK_EN = 1 }),
    }
    r.TCONFIG.write(.{
        .T_AUTORELOAD = 0,
        .T_DIVIDER = config.divider,
        .T_INCREASE = @intFromBool(config.increase),
    });
}

const Registers = @TypeOf(microzig.chip.peripherals.TIMG0);

pub fn reset_divider(r: Registers) void {
    r.TCONFIG.modify(.{ .T_DIVCNT_RST = 1 });
}

pub fn set_enabled(r: Registers, enabled: bool) void {
    r.TCONFIG.modify(.{ .T_EN = @intFromBool(enabled) });
}

pub fn read(r: Registers) error{Timeout}!u54 {
    r.TUPDATE.write(.{ .T_UPDATE = 1 });
    for (0..10000) |_| {
        if (r.TUPDATE.read().T_UPDATE == 0) {
            const lo = r.TLO.read().T_LO;
            return (@as(u54, r.THI.read().T_HI) << 32) | lo;
        }
    }
    return error.Timeout;
}

pub fn set_reload(r: Registers, value: u54) void {
    r.TLOADLO.write(.{ .T_LOAD_LO = @truncate(value) });
    r.TLOADHI.write(.{ .T_LOAD_HI = @truncate(value >> 32) });
}

pub fn reload(r: Registers) void {
    r.TLOAD.write(.{ .T_LOAD = 1 });
}

pub fn set_alarm(r: Registers, value: u54, auto_reload: bool) void {
    r.TCONFIG.modify(.{ .T_ALARM_EN = 0, .T_AUTORELOAD = @intFromBool(auto_reload) });
    r.TALARMLO.write(.{ .T_ALARM_LO = @truncate(value) });
    r.TALARMHI.write(.{ .T_ALARM_HI = @truncate(value >> 32) });
}

pub fn arm_alarm(r: Registers) void {
    r.TCONFIG.modify(.{ .T_ALARM_EN = 1 });
}
