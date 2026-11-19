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
    // Analog helpers have no disable operation: retain their root-clock ownership
    // for the rest of this boot, independently of PHY references.
    analog_clock_owned = true;
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

// Radio clock maps: C6 TRM v1.2 §8.2.4.4 and §12.4.2.5 (PMU clocks).
// Sequence follows ESP-IDF modem_clock.c and totorototo's radio clocks.
const PMU = peripherals.PMU;
const MODEM_SYSCON = peripherals.MODEM_SYSCON;
const MODEM_LPCON = peripherals.MODEM_LPCON;
const LP_AON = peripherals.LP_AON;

const icg_modem_code_active = 2;
const icg_nogating_modem: u4 = 1 << 1;
const icg_nogating_active: u4 = 1 << 2;
const icg_nogating_active_modem: u4 = icg_nogating_active | icg_nogating_modem;

/// Powers the Wi-Fi domain and sets up modem clock gating and the Wi-Fi low-power clock.
/// Call once before any radio driver starts.
pub fn radio_init() void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    // C6 TRM v1.2 §8.5, PCR_MODEM_APB_CONF: system.init reset this domain.
    peripherals.PCR.MODEM_APB_CONF.modify(.{ .MODEM_APB_CLK_EN = 1, .MODEM_RST_EN = 0 });
    // Let the PMU state machine control the Wi-Fi power domain (no forced power down / isolation).
    PMU.POWER_PD_HPWIFI_CNTL.modify(.{
        .FORCE_HP_WIFI_RESET = 0,
        .FORCE_HP_WIFI_ISO = 0,
        .FORCE_HP_WIFI_PU = 0,
        .FORCE_HP_WIFI_NO_RESET = 0,
        .FORCE_HP_WIFI_NO_ISO = 0,
        .FORCE_HP_WIFI_PD = 0,
    });

    // ESP-IDF v6.0.2 modem_clock.c initial_gating_mode:
    // modem_clock_domain_power_state_icg_map_init: bit 0/1/2 of each map = SLEEP/MODEM/ACTIVE
    // states in which the clock domain is not gated.
    MODEM_SYSCON.CLK_CONF_POWER_ST.modify(.{
        .CLK_MODEM_APB_ST_MAP = icg_nogating_active_modem,
        .CLK_MODEM_PERI_ST_MAP = icg_nogating_active,
        .CLK_WIFI_ST_MAP = icg_nogating_active_modem,
        .CLK_BT_ST_MAP = icg_nogating_active,
        .CLK_FE_ST_MAP = icg_nogating_active_modem,
        .CLK_ZB_ST_MAP = icg_nogating_active,
    });
    MODEM_LPCON.CLK_CONF_POWER_ST.modify(.{
        .CLK_LP_APB_ST_MAP = icg_nogating_active_modem,
        .CLK_I2C_MST_ST_MAP = icg_nogating_active_modem,
        .CLK_COEX_ST_MAP = icg_nogating_active_modem,
        .CLK_WIFIPWR_ST_MAP = icg_nogating_active_modem,
    });

    // Wi-Fi low-power clock follows the system slow clock: RC_SLOW, no divider.
    MODEM_LPCON.WIFI_LP_CLK_CONF.modify(.{
        .CLK_WIFIPWR_LP_SEL_OSC_SLOW = 1,
        .CLK_WIFIPWR_LP_SEL_OSC_FAST = 0,
        .CLK_WIFIPWR_LP_SEL_XTAL = 0,
        .CLK_WIFIPWR_LP_SEL_XTAL32K = 0,
        .CLK_WIFIPWR_LP_DIV_NUM = 0,
    });
    MODEM_LPCON.CLK_CONF.modify(.{ .CLK_WIFIPWR_EN = 1 });

    // modem_clk_domain_active_state_icg_map_preinit
    PMU.HP_ACTIVE_ICG_MODEM.modify(.{ .HP_ACTIVE_DIG_ICG_MODEM_CODE = icg_modem_code_active });
    PMU.HP_MODEM_ICG_MODEM.modify(.{ .HP_MODEM_DIG_ICG_MODEM_CODE = 1 });
    PMU.HP_SLEEP_ICG_MODEM.modify(.{ .HP_SLEEP_DIG_ICG_MODEM_CODE = 0 });
    PMU.IMM_MODEM_ICG.write(.{ .UPDATE_DIG_ICG_MODEM_EN = 1 });
    PMU.IMM_SLEEP_SYSCLK.write(.{ .UPDATE_DIG_ICG_SWITCH = 1 });
}

// ESP-IDF v6.0.2 modem_clock.c WIFI_CLOCK_DEPS and PHY_CALIBRATION_WIFI_CLOCK_DEPS.
// APB/BB/44M always have the same users here, so share a reference count.
// All state and clock RMWs below are protected by short critical sections.
var wifi_inited = false;
var wifi_clock_refs: u32 = 0;
var bb_clock_refs: u32 = 0;
var phy_clock_refs: u32 = 0;
var analog_clock_owned = false;
var slowclk_period: u32 = 0;

pub fn wifi_set_inited(inited: bool) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    wifi_inited = inited;
}

/// Wi-Fi MAC/APB/BB/44M stay enabled after Wi-Fi init, including stop and
/// mode changes. Coexistence follows its references, as in IDF modem_clock.c.
pub fn wifi_clocks_set_enabled(enabled: bool) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    if (enabled) {
        wifi_clock_refs += 1;
        if (wifi_clock_refs == 1) {
            MODEM_SYSCON.CLK_CONF1.modify(.{ .CLK_WIFIMAC_EN = 1 });
            MODEM_LPCON.CLK_CONF.modify(.{ .CLK_COEX_EN = 1 });
        }
    } else {
        if (wifi_clock_refs == 0) return;
        wifi_clock_refs -= 1;
        if (wifi_clock_refs == 0) {
            if (!wifi_inited) MODEM_SYSCON.CLK_CONF1.modify(.{ .CLK_WIFIMAC_EN = 0 });
            MODEM_LPCON.CLK_CONF.modify(.{ .CLK_COEX_EN = 0 });
        }
    }
    bb_clocks_set_enabled(enabled);
}

/// Temporary APB/BB/44M ownership during PHY calibration/wakeup, shared
/// with Wi-Fi. Caller holds the PHY lock; register changes are IRQ-safe.
pub fn calibration_clocks_set_enabled(enabled: bool) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    bb_clocks_set_enabled(enabled);
    // IDF PHY_CALIBRATION_BT_I154_CLOCK_DEPS also opens the shared BT BB.
    const en = @intFromBool(enabled);
    MODEM_SYSCON.CLK_CONF1.modify(.{ .CLK_BT_APB_EN = en, .CLK_BT_EN = en });
}

fn bb_clocks_set_enabled(enabled: bool) void {
    if (enabled) {
        bb_clock_refs += 1;
        if (bb_clock_refs != 1) return;
    } else {
        if (bb_clock_refs == 0) return;
        bb_clock_refs -= 1;
        if (bb_clock_refs != 0 or wifi_inited) return;
    }
    const en = @intFromBool(enabled);
    // IDF modem_syscon_ll_clk_wifibb_configure mask 0x1ff plus WIFI_APB.
    MODEM_SYSCON.CLK_CONF1.modify(.{
        .CLK_WIFI_APB_EN = en,
        .CLK_WIFIBB_160X1_EN = en,
        .CLK_WIFIBB_80X1_EN = en,
        .CLK_WIFIBB_40X1_EN = en,
        .CLK_WIFIBB_80X_EN = en,
        .CLK_WIFIBB_40X_EN = en,
        .CLK_WIFIBB_80M_EN = en,
        .CLK_WIFIBB_44M_EN = en,
        .CLK_WIFIBB_40M_EN = en,
        .CLK_WIFIBB_22M_EN = en,
    });
}

/// IDF v6.0.2 modem_clock_hal_enable_modem_{common,private}_fe_clock
/// enables FE clocks but never disables them. The analog master root has
/// independent ownership; do not remove the SAR helpers' clock on PHY stop.
pub fn phy_clocks_set_enabled(enabled: bool) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    if (enabled) {
        phy_clock_refs += 1;
        if (phy_clock_refs != 1) return;
        MODEM_SYSCON.CLK_CONF1.modify(.{
            .CLK_FE_APB_EN = 1,
            .CLK_FE_CAL_160M_EN = 1,
            .CLK_FE_160M_EN = 1,
            .CLK_FE_80M_EN = 1,
        });
        MODEM_LPCON.I2C_MST_CLK_CONF.modify(.{ .CLK_I2C_MST_SEL_160M = 1 });
        MODEM_LPCON.CLK_CONF.modify(.{ .CLK_I2C_MST_EN = 1 });
    } else {
        if (phy_clock_refs == 0) return;
        phy_clock_refs -= 1;
        if (phy_clock_refs == 0 and !analog_clock_owned)
            MODEM_LPCON.CLK_CONF.modify(.{ .CLK_I2C_MST_EN = 0 });
    }
}

/// Measure the RC_SLOW source selected by radio_init against XTAL, once
/// per radio initialization. Never consume an IDF application's retained STORE1.
/// C6 TRM v1.2 §14.3.6 and registers 14.18–14.20 (RTC calibration), §8.3.2.
/// Algorithm/timeout threshold: IDF v6.0.2 esp_hw_support/port/esp32c6/rtc_time.c.
pub fn calibrate_slow_clock() error{SlowClockCalibrationTimeout}!void {
    const timg = peripherals.TIMG0;
    const time = @import("../time.zig");
    const clocks = @import("../clocks.zig");
    // Also stops the MWDT0 flash-boot protection that leaving reset re-arms.
    @import("../timer.zig").Group.timg0.enable_clock();
    const deadline = microzig.drivers.time.Deadline.init_relative(time.get_time_since_boot(), .from_ms(100));
    if (timg.RTCCALICFG.read().RTC_CALI_START_CYCLING != 0) {
        timg.RTCCALICFG2.modify(.{ .RTC_CALI_TIMEOUT_THRES = 1 });
        while (timg.RTCCALICFG.read().RTC_CALI_RDY == 0 and timg.RTCCALICFG2.read().RTC_CALI_TIMEOUT == 0) {
            if (deadline.is_reached_by(time.get_time_since_boot())) return error.SlowClockCalibrationTimeout;
        }
    }
    const cycles = 1024;
    timg.RTCCALICFG.modify(.{
        .RTC_CALI_START_CYCLING = 0,
        .RTC_CALI_START = 0,
        .RTC_CALI_CLK_SEL = 0, // RC_SLOW, which also drives WIFI_LP_CLK.
        .RTC_CALI_MAX = cycles,
    });
    timg.RTCCALICFG2.modify(.{ .RTC_CALI_TIMEOUT_THRES = cycles << 10 });
    timg.RTCCALICFG.modify(.{ .RTC_CALI_START = 1 });
    defer timg.RTCCALICFG.modify(.{ .RTC_CALI_START = 0 });
    while (timg.RTCCALICFG.read().RTC_CALI_RDY == 0) {
        if (timg.RTCCALICFG2.read().RTC_CALI_TIMEOUT != 0 or
            deadline.is_reached_by(time.get_time_since_boot())) return error.SlowClockCalibrationTimeout;
    }
    const xtal_cycles: u64 = timg.RTCCALICFG1.read().RTC_CALI_VALUE;
    if (xtal_cycles == 0) return error.SlowClockCalibrationTimeout;
    const divider: u64 = (clocks.xtal_clk_freq / 1_000_000) * cycles;
    slowclk_period = @intCast(((xtal_cycles << 19) + divider / 2 - 1) / divider);
    LP_AON.STORE1.modify(.{ .LP_AON_STORE1 = slowclk_period });
}

/// RTC slow clock period in microseconds with 12 fractional bits.
pub fn slowclk_cal() u32 {
    return slowclk_period >> (19 - 12);
}
