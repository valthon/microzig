const microzig = @import("microzig");
const timer = @import("../timer.zig");

pub fn configure_timer(group: timer.Group, config: timer.Group.Config) void {
    const r = group.registers();
    r.T0CONFIG.write(.{
        .T0_AUTORELOAD = 0,
        .T0_USE_XTAL = @intFromBool(config.use_xtal),
        .T0_DIVIDER = config.divider,
        .T0_INCREASE = @intFromBool(config.increase),
    });
}

const Registers = @TypeOf(microzig.chip.peripherals.TIMG0);

pub fn reset_divider(r: Registers) void {
    r.T0CONFIG.modify(.{ .T0_DIVCNT_RST = 1 });
}

pub fn set_enabled(r: Registers, enabled: bool) void {
    r.T0CONFIG.modify(.{ .T0_EN = @intFromBool(enabled) });
}

pub fn read(r: Registers) error{Timeout}!u54 {
    r.T0UPDATE.write(.{ .T0_UPDATE = 1 });
    for (0..10000) |_| {
        if (r.T0UPDATE.read().T0_UPDATE == 0) {
            const lo = r.T0LO.read().T0_LO;
            return (@as(u54, r.T0HI.read().T0_HI) << 32) | lo;
        }
    }
    return error.Timeout;
}

pub fn set_reload(r: Registers, value: u54) void {
    r.T0LOADLO.write(.{ .T0_LOAD_LO = @truncate(value) });
    r.T0LOADHI.write(.{ .T0_LOAD_HI = @truncate(value >> 32) });
}

pub fn reload(r: Registers) void {
    r.T0LOAD.write(.{ .T0_LOAD = 1 });
}

pub fn set_alarm(r: Registers, value: u54, auto_reload: bool) void {
    r.T0CONFIG.modify(.{ .T0_ALARM_EN = 0, .T0_AUTORELOAD = @intFromBool(auto_reload) });
    r.T0ALARMLO.write(.{ .T0_ALARM_LO = @truncate(value) });
    r.T0ALARMHI.write(.{ .T0_ALARM_HI = @truncate(value >> 32) });
}

pub fn arm_alarm(r: Registers) void {
    r.T0CONFIG.modify(.{ .T0_ALARM_EN = 1 });
}
