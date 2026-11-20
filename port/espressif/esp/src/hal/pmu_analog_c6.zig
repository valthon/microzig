//! Internal I2C subset needed by PMU init and CPU clock restoration.
//! ESP-IDF v5.5.1 esp_rom/patches/esp_rom_hp_regi2c_esp32c6.c:107–245,
//! hal/esp32c6/include/hal/{regi2c_ctrl_ll.h:70–95,clk_tree_ll.h:297–339}.
//! The bus itself is undocumented in the TRM; PMU ownership: §12.4.2.3.
const microzig = @import("microzig");
const p = microzig.chip.peripherals;
const master = p.I2C_ANA_MST;
const diagnostic = @import("pmu_c6.zig");
pub const Error = error{Timeout};

pub const Bus = struct {
    modem_apb: @TypeOf(p.PCR.MODEM_APB_CONF.read()),
    clock: @TypeOf(p.MODEM_LPCON.CLK_CONF.read()),
    force: @TypeOf(p.MODEM_LPCON.CLK_CONF_FORCE_ON.read()),
    mask: @TypeOf(master.ANA_CONF1.read()),

    sysmap: @TypeOf(p.MODEM_SYSCON.CLK_CONF_POWER_ST.read()),
    lpmap: @TypeOf(p.MODEM_LPCON.CLK_CONF_POWER_ST.read()),

    pub fn begin() Bus {
        const apb = p.PCR.MODEM_APB_CONF.read();
        diagnostic.milestone(0x10, @intFromPtr(&p.PCR.MODEM_APB_CONF));
        p.PCR.MODEM_APB_CONF.modify(.{ .MODEM_APB_CLK_EN = 1, .MODEM_RST_EN = 0 });
        var saved: Bus = .{
            .modem_apb = apb,
            .clock = p.MODEM_LPCON.CLK_CONF.read(),
            .force = p.MODEM_LPCON.CLK_CONF_FORCE_ON.read(),
            .mask = undefined,
            .sysmap = p.MODEM_SYSCON.CLK_CONF_POWER_ST.read(),
            .lpmap = p.MODEM_LPCON.CLK_CONF_POWER_ST.read(),
        };
        // IDF regi2c_ctrl.h:34–59 acquires MODEM_APB and analog master
        // clock references. Open the current PMU code without radio ownership.
        const bit = @as(u4, 1) << p.PMU.CLK_STATE0.read().ICG_MODEM_CODE_STATE;
        diagnostic.milestone(0x19, @intFromPtr(&p.MODEM_SYSCON.CLK_CONF_POWER_ST));
        p.MODEM_SYSCON.CLK_CONF_POWER_ST.modify(.{ .CLK_MODEM_APB_ST_MAP = saved.sysmap.CLK_MODEM_APB_ST_MAP | bit });
        diagnostic.milestone(0x19, @intFromPtr(&p.MODEM_LPCON.CLK_CONF_POWER_ST));
        p.MODEM_LPCON.CLK_CONF_POWER_ST.modify(.{ .CLK_LP_APB_ST_MAP = saved.lpmap.CLK_LP_APB_ST_MAP | bit, .CLK_I2C_MST_ST_MAP = saved.lpmap.CLK_I2C_MST_ST_MAP | bit });
        diagnostic.milestone(0x11, @intFromPtr(&p.MODEM_LPCON.CLK_CONF_FORCE_ON));
        p.MODEM_LPCON.CLK_CONF_FORCE_ON.modify(.{ .CLK_I2C_MST_FO = 1 });
        diagnostic.milestone(0x19, @intFromPtr(&p.MODEM_LPCON.CLK_CONF));
        p.MODEM_LPCON.CLK_CONF.modify(.{ .CLK_I2C_MST_EN = 1 });
        diagnostic.milestone(0x13, @intFromPtr(&master.ANA_CONF1));
        saved.mask = master.ANA_CONF1.read();
        return saved;
    }
    pub fn end(self: Bus) void {
        diagnostic.milestone(0x12, @intFromPtr(&master.ANA_CONF1));
        master.ANA_CONF1.write(self.mask);
        diagnostic.milestone(0x19, @intFromPtr(&p.MODEM_LPCON.CLK_CONF));
        p.MODEM_LPCON.CLK_CONF.write(self.clock);
        diagnostic.milestone(0x19, @intFromPtr(&p.MODEM_LPCON.CLK_CONF_FORCE_ON));
        p.MODEM_LPCON.CLK_CONF_FORCE_ON.write(self.force);
        diagnostic.milestone(0x19, @intFromPtr(&p.MODEM_LPCON.CLK_CONF_POWER_ST));
        p.MODEM_LPCON.CLK_CONF_POWER_ST.write(self.lpmap);
        diagnostic.milestone(0x19, @intFromPtr(&p.MODEM_SYSCON.CLK_CONF_POWER_ST));
        p.MODEM_SYSCON.CLK_CONF_POWER_ST.write(self.sysmap);
        diagnostic.milestone(0x19, @intFromPtr(&p.PCR.MODEM_APB_CONF));
        p.PCR.MODEM_APB_CONF.write(self.modem_apb);
    }
};

pub fn write_mask(comptime slave: u8, reg: u8, mask: u8, bits: u8) Error!void {
    const use_zero = select_slave(slave);
    if (use_zero) try update("I2C0_CTRL", slave, reg, mask, bits) else try update("I2C1_CTRL", slave, reg, mask, bits);
}
fn select_slave(comptime slave: u8) bool {
    // esp_rom_hp_regi2c_esp32c6.c:107–142 returns master zero when set.
    const select = master.ANA_CONF2.read();
    const use_zero = switch (slave) {
        0x6d => select.DIG_REG_MST_SEL,
        0x66 => select.BBPLL_MST_SEL,
        0x61 => select.ULP_CAL_MST_SEL,
        else => @compileError("unsupported internal I2C slave"),
    };
    diagnostic.milestone(0x13, @intFromPtr(&master.ANA_CONF1));
    // Match regi2c_enable_block's whole-register REG_WRITE, including the
    // non-mask bits (esp_rom_hp_regi2c_esp32c6.c:94–110).
    master.ANA_CONF1.write_raw(if (slave == 0x6d) 0xfffbff else if (slave == 0x61) 0xfffeff else 0xffff7f);
    return use_zero != 0;
}
pub fn read_byte(comptime slave: u8, reg: u8) Error!u8 {
    return if (select_slave(slave)) read("I2C0_CTRL", slave, reg) else read("I2C1_CTRL", slave, reg);
}
fn wait_idle(comptime name: []const u8) error{Timeout}!void {
    diagnostic.milestone(0x14, @intFromPtr(&@field(master, name)));
    for (0..100_000) |_| {
        if (@field(master, name).read().BUSY == 0) return;
    }
    return error.Timeout;
}
fn read(comptime name: []const u8, slave: u8, reg: u8) Error!u8 {
    const ctrl = &@field(master, name);
    try wait_idle(name);
    ctrl.write(.{ .SLAVE_ID = slave, .REGISTER = reg, .DATA = 0, .WRITE = 0, .BUSY = 0 });
    try wait_idle(name);
    return ctrl.read().DATA;
}
fn update(comptime name: []const u8, slave: u8, reg: u8, mask: u8, bits: u8) Error!void {
    const old = try read(name, slave, reg);
    @field(master, name).write(.{ .SLAVE_ID = slave, .REGISTER = reg, .DATA = (old & ~mask) | (bits & mask), .WRITE = 1, .BUSY = 0 });
    try wait_idle(name);
    // ROM only waits for the write transaction. Analog command fields may be
    // write-only or self-clearing; reading them back cannot verify the write.
}

pub fn give_regulators_to_pmu() Error!void {
    const bus = Bus.begin();
    defer bus.end();
    // pmu_init.c:210–213; soc/regi2c_dig_reg.h:36–76.
    try write_mask(0x6d, 5, 0x80, 0x80); // ENIF_RTC_DREG
    try write_mask(0x6d, 7, 0x80, 0x80); // ENIF_DIG_DREG
    try write_mask(0x6d, 13, 4, 0); // XPD_RTC_REG
    try write_mask(0x6d, 13, 8, 0); // XPD_DIG_REG
}

pub fn calibrate_pll() Error!void {
    const bus = Bus.begin();
    defer bus.end();
    diagnostic.milestone(0x15, @intFromPtr(&master.ANA_CONF0));
    master.ANA_CONF0.modify(.{ .BBPLL_STOP_FORCE_HIGH = 0 });
    diagnostic.milestone(0x19, @intFromPtr(&master.ANA_CONF0));
    master.ANA_CONF0.modify(.{ .BBPLL_STOP_FORCE_LOW = 1 });
    defer {
        diagnostic.milestone(0x19, @intFromPtr(&master.ANA_CONF0));
        master.ANA_CONF0.modify(.{ .BBPLL_STOP_FORCE_LOW = 0 });
        diagnostic.milestone(0x19, @intFromPtr(&master.ANA_CONF0));
        master.ANA_CONF0.modify(.{ .BBPLL_STOP_FORCE_HIGH = 1 });
    }
    // clk_tree_ll.h:310–339: 480 MHz PLL, 40 MHz XTAL.
    try write_mask(0x66, 2, 0xff, 0x50);
    try write_mask(0x66, 3, 0xff, 8);
    try write_mask(0x66, 5, 7, 0);
    try write_mask(0x66, 5, 0x70, 0);
    try write_mask(0x66, 6, 0xff, 0x73);
    try write_mask(0x66, 9, 3, 2);
    diagnostic.milestone(0x16, @intFromPtr(&master.ANA_CONF0));
    for (0..100_000) |_| {
        if (master.ANA_CONF0.read().BBPLL_CAL_DONE != 0) {
            microzig.hal.rom.functions.ets_delay_us(10);
            return;
        }
    }
    return error.Timeout;
}

/// pmu_init.c:222–225, ocode_init.c:20–97. Power-on only; eFuse encoding
/// version >=1 has a burned o-code. Unburned parts use bounded calibration.
pub fn ocode_init(slow_period: u32) Error!void {
    const version = p.EFUSE.RD_MAC_SPI_SYS_3.raw;
    if (((version >> 30) & 3) * 100 + ((version >> 27) & 7) >= 1) {
        const bus = Bus.begin();
        defer bus.end();
        // efuse_ll.h:129–132, efuse_struct.h:670–673; lp_bias.h:53–59.
        const code: u8 = @truncate(p.EFUSE.RD_SYS_PART1_DATA4.raw >> 9);
        try write_mask(0x61, 6, 0xff, code);
        try write_mask(0x61, 5, 0x40, 0x40);
        return;
    }
    const clock = @import("clocks/sleep_c6.zig").Saved.capture();
    clock.to_xtal();
    diagnostic.milestone(0x17, @intFromPtr(&p.PMU.IMM_HP_CK_POWER));
    p.PMU.IMM_HP_CK_POWER.modify(.{ .TIE_LOW_GLOBAL_BBPLL_ICG = 1 });
    diagnostic.milestone(0x19, @intFromPtr(&p.PMU.IMM_HP_CK_POWER));
    p.PMU.IMM_HP_CK_POWER.modify(.{ .TIE_LOW_XPD_BBPLL = 1, .TIE_LOW_XPD_BBPLL_I2C = 1 });
    const result = calibrate_ocode(slow_period);
    try clock.restore();
    return result;
}
fn calibrate_ocode(period: u32) Error!void {
    const bus = Bus.begin();
    defer bus.end();
    try write_mask(0x61, 0, 1, 0);
    try write_mask(0x61, 0, 1, 1);
    const limit = @import("clocks/sleep_c6.zig").Periods.cycles(period, 10_000);
    const timer = @import("lp_timer.zig");
    diagnostic.milestone(0x18, @intFromPtr(&p.LP_TIMER.UPDATE));
    const start = timer.now();
    // Bound the poll even if LP time is stopped.
    for (0..100_000) |_| {
        if ((try read_byte(0x61, 3)) & 9 == 9) return;
        diagnostic.milestone(0x18, @intFromPtr(&p.LP_TIMER.UPDATE));
        if (timer.now() -% start >= limit) return error.Timeout;
    }
    return error.Timeout;
}
