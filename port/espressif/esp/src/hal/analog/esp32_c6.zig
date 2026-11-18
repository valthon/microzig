//! SAR analog register access. C6 TRM v1.2 §§39.2–39.3 covers the
//! sensors; the internal I2C protocol is specified by ESP-IDF v5.4
//! esp_rom/patches/esp_rom_hp_regi2c_esp32c6.c (Apache-2.0), not the TRM.
//! Do not use concurrently with radio/PHY analog configuration or LP firmware.
const microzig = @import("microzig");
const peripherals = microzig.chip.peripherals;
const master = peripherals.I2C_ANA_MST;
pub const Error = error{ Timeout, VerificationFailed };

pub fn enable() void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    // system.init disables/resets MODEM_APB. Restore register access before
    // touching MODEM_LPCON, MODEM_SYSCON or the HP analog master.
    // C6 TRM v1.2 §8.5, register 8.61 (PCR_MODEM_APB_CONF).
    peripherals.PCR.MODEM_APB_CONF.modify(.{ .MODEM_APB_CLK_EN = 1, .MODEM_RST_EN = 0 });
    // IDF modem_clock.c initial_gating_mode opens these domains as well as
    // FE. Use the actual PMU code for RAM boot; this HAL does not sleep.
    const state = peripherals.PMU.CLK_STATE0.read().ICG_MODEM_CODE_STATE;
    const state_mask = @as(u4, 1) << state;
    const syscon = peripherals.MODEM_SYSCON;
    syscon.CLK_CONF_POWER_ST.modify(.{
        .CLK_MODEM_APB_ST_MAP = syscon.CLK_CONF_POWER_ST.read().CLK_MODEM_APB_ST_MAP | state_mask,
    });
    const lpcon = peripherals.MODEM_LPCON;
    const maps = lpcon.CLK_CONF_POWER_ST.read();
    lpcon.CLK_CONF_POWER_ST.modify(.{
        .CLK_LP_APB_ST_MAP = maps.CLK_LP_APB_ST_MAP | state_mask,
        .CLK_I2C_MST_ST_MAP = maps.CLK_I2C_MST_ST_MAP | state_mask,
    });
    peripherals.MODEM_LPCON.CLK_CONF.modify(.{ .CLK_I2C_MST_EN = 1 });
    // C6 TRM v1.2 §12.4.2.3 covers PMU analog power control, but not
    // this internal bus sequence. Local ESP-IDF
    // components/hal/esp32c6/include/hal/regi2c_ctrl_ll.h,
    // regi2c_ctrl_ll_i2c_sar_periph_enable: reset, power up, release reset.
    // RF_PWC.PERIF_I2C_RSTB defaults to zero; bootloader setup is not enough.
    peripherals.PMU.RF_PWC.modify(.{ .PERIF_I2C_RSTB = 0 });
    peripherals.PMU.RF_PWC.modify(.{ .XPD_PERIF_I2C = 1 });
    peripherals.PMU.RF_PWC.modify(.{ .PERIF_I2C_RSTB = 1 });
}

pub fn write_mask(reg: u8, comptime msb: u3, comptime lsb: u3, value: u8) Error!void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    // Select SAR for readback while masking other analog slaves, as in IDF.
    // Restore the mask so unrelated analog clients keep their configuration.
    const saved = master.ANA_CONF1.read();
    defer master.ANA_CONF1.write(saved);
    master.ANA_CONF1.modify(.{ .READ_MASK = 0xfffdff });
    if (master.ANA_CONF2.read().SAR_MST_SEL != 0) {
        try update("I2C0_CTRL", reg, msb, lsb, value);
    } else {
        try update("I2C1_CTRL", reg, msb, lsb, value);
    }
}

fn read_register(comptime name: []const u8, reg: u8) error{Timeout}!u8 {
    const ctrl = &@field(master, name);
    try wait_idle(name);
    ctrl.write(.{ .SLAVE_ID = 0x69, .REGISTER = reg, .DATA = 0, .WRITE = 0, .BUSY = 0 });
    try wait_idle(name);
    return ctrl.read().DATA;
}

fn update(comptime name: []const u8, reg: u8, comptime msb: u3, comptime lsb: u3, value: u8) Error!void {
    const ctrl = &@field(master, name);
    const old = try read_register(name, reg);
    const mask: u8 = @intCast((@as(u16, 1) << (@as(u4, msb) - lsb + 1)) - 1);
    const data = (old & ~(mask << lsb)) | ((value & mask) << lsb);
    ctrl.write(.{ .SLAVE_ID = 0x69, .REGISTER = reg, .DATA = data, .WRITE = 1, .BUSY = 0 });
    try wait_idle(name);
    // BUSY=0 alone also occurs for an inaccessible master. Issue a new
    // read command so a dropped write cannot masquerade as successful init.
    if ((try read_register(name, reg)) & (mask << lsb) != data & (mask << lsb))
        return error.VerificationFailed;
}

fn wait_idle(comptime name: []const u8) error{Timeout}!void {
    // A bounded register poll also works before systimer initialization.
    var remaining: u32 = 100_000;
    while (@field(master, name).read().BUSY != 0) {
        remaining -= 1;
        if (remaining == 0) return error.Timeout;
    }
}
