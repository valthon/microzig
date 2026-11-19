//! Sleep-only C6 clock transaction. ESP-IDF v5.5.1 rtc_clk.c:174–180,
//! 252–270,335–345; rtc_time.c:35–246. TRM v1.2 §§8.2.4.1,14.3.6.
const microzig = @import("microzig");
const p = microzig.chip.peripherals;
const clocks = @import("esp32_c6.zig");
const diag = @import("../pmu_c6.zig");
const analog = @import("../pmu_analog_c6.zig");
const rom = microzig.hal.rom.functions;

pub const Saved = struct {
    sys: @TypeOf(p.PCR.SYSCLK_CONF.read()),
    cpu: @TypeOf(p.PCR.CPU_FREQ_CONF.read()),
    ahb: @TypeOf(p.PCR.AHB_FREQ_CONF.read()),

    pub fn capture() Saved {
        return .{ .sys = p.PCR.SYSCLK_CONF.read(), .cpu = p.PCR.CPU_FREQ_CONF.read(), .ahb = p.PCR.AHB_FREQ_CONF.read() };
    }
    pub fn to_xtal(_: Saved) void {
        diag.milestone(0x20, @intFromPtr(&p.PCR.AHB_FREQ_CONF));
        diag.milestone(0x29, @intFromPtr(&p.PCR.AHB_FREQ_CONF));
        // rtc_clk_cpu_freq_to_xtal: AHB divider, CPU divider, then source.
        p.PCR.AHB_FREQ_CONF.modify(.{ .AHB_LS_DIV_NUM = 0 });
        diag.milestone(0x29, @intFromPtr(&p.PCR.CPU_FREQ_CONF));
        p.PCR.CPU_FREQ_CONF.modify(.{ .CPU_LS_DIV_NUM = 0 });
        diag.milestone(0x21, @intFromPtr(&p.PCR.SYSCLK_CONF));
        p.PCR.SYSCLK_CONF.modify(.{ .SOC_CLK_SEL = 0 });
        rom.ets_update_cpu_frequency(clocks.xtal_clk_freq / 1_000_000);
    }
    pub fn restore(self: Saved) analog.Error!void {
        var calibration: analog.Error!void = {};
        if (self.sys.SOC_CLK_SEL == 1) {
            // IDF recalibrates even though HP_ACTIVE has powered PLL back up.
            diag.milestone(0x22, @intFromPtr(&p.PMU.IMM_HP_CK_POWER));
            p.PMU.IMM_HP_CK_POWER.modify(.{ .TIE_HIGH_XPD_BB_I2C = 1, .TIE_HIGH_XPD_BBPLL = 1, .TIE_HIGH_XPD_BBPLL_I2C = 1 });
            diag.milestone(0x29, @intFromPtr(&p.PMU.IMM_HP_CK_POWER));
            p.PMU.IMM_HP_CK_POWER.modify(.{ .TIE_HIGH_GLOBAL_BBPLL_ICG = 1 });
            calibration = analog.calibrate_pll();
        }
        diag.milestone(0x23, @intFromPtr(&p.PCR.AHB_FREQ_CONF));
        // On XTAL, slow AHB first, then CPU, and select the saved source last.
        diag.milestone(0x29, @intFromPtr(&p.PCR.AHB_FREQ_CONF));
        p.PCR.AHB_FREQ_CONF.modify(.{ .AHB_LS_DIV_NUM = self.ahb.AHB_LS_DIV_NUM, .AHB_HS_DIV_NUM = self.ahb.AHB_HS_DIV_NUM });
        diag.milestone(0x29, @intFromPtr(&p.PCR.CPU_FREQ_CONF));
        p.PCR.CPU_FREQ_CONF.modify(.{ .CPU_LS_DIV_NUM = self.cpu.CPU_LS_DIV_NUM, .CPU_HS_DIV_NUM = self.cpu.CPU_HS_DIV_NUM, .CPU_HS_120M_FORCE = self.cpu.CPU_HS_120M_FORCE });
        diag.milestone(0x29, @intFromPtr(&p.PCR.SYSCLK_CONF));
        // Complete the divider restoration even if the analog bus failed.
        // A genuinely uncalibrated PLL must not be selected: retain XTAL and
        // report Timeout, with ROM delay timing updated for the saved divider.
        calibration catch |err| {
            rom.ets_update_cpu_frequency(clocks.xtal_clk_freq / (@as(u32, self.cpu.CPU_LS_DIV_NUM) + 1) / 1_000_000);
            return err;
        };
        p.PCR.SYSCLK_CONF.modify(.{ .SOC_CLK_SEL = self.sys.SOC_CLK_SEL });
        const hz = if (self.sys.SOC_CLK_SEL == 0)
            clocks.xtal_clk_freq / (@as(u32, self.cpu.CPU_LS_DIV_NUM) + 1)
        else if (self.cpu.CPU_HS_120M_FORCE != 0)
            120_000_000
        else
            160_000_000 / (@as(u32, self.cpu.CPU_HS_DIV_NUM) + 1);
        rom.ets_update_cpu_frequency(hz / 1_000_000);
    }
};

pub const Periods = struct {
    slow: u32, // microseconds, Q13.19, as rtc_clk_cal
    fast: u32,

    pub fn cycles(period: u32, us: u32) u32 {
        return @intCast((@as(u64, us) << 19) / period);
    }
};

/// Own TIMG0 RTC calibration during this operation. It does not alter either
/// selected LP clock. Calibration failures return before USB detachment.
pub fn calibrate() error{Timeout}!Periods {
    const clock = p.PCR.TIMERGROUP0_CONF.read();
    diag.milestone(0x24, @intFromPtr(&p.PCR.TIMERGROUP0_CONF));
    p.PCR.TIMERGROUP0_CONF.modify(.{ .TG0_CLK_EN = 1, .TG0_RST_EN = 0 });
    defer p.PCR.TIMERGROUP0_CONF.write(clock);
    const source = p.LP_CLKRST.LP_CLK_CONF.read().SLOW_CLK_SEL;
    const to_hp = p.LP_CLKRST.CLK_TO_HP.read();
    const tick = p.PCR.CTRL_TICK_CONF.read();
    const target = p.PCR.CTRL_32K_CONF.read();
    defer {
        diag.milestone(0x25, @intFromPtr(&p.LP_CLKRST.CLK_TO_HP));
        p.LP_CLKRST.CLK_TO_HP.write(to_hp);
        diag.milestone(0x29, @intFromPtr(&p.PCR.CTRL_TICK_CONF));
        p.PCR.CTRL_TICK_CONF.write(tick);
        diag.milestone(0x29, @intFromPtr(&p.PCR.CTRL_32K_CONF));
        p.PCR.CTRL_32K_CONF.write(target);
    }
    // rtc_time.c:67–110: route the selected oscillator to calibration.
    diag.milestone(0x26, @intFromPtr(&p.LP_CLKRST.CLK_TO_HP));
    p.LP_CLKRST.CLK_TO_HP.modify(.{ .ICG_HP_FOSC = 1, .ICG_HP_XTAL32K = 1, .ICG_HP_OSC32K = 1 });
    if (source != 0) p.PCR.CTRL_32K_CONF.modify(.{
        .CLK_32K_SEL = switch (source) {
            1 => @as(u2, 1), // XTAL32K
            2 => @as(u2, 0), // RC32K
            else => @as(u2, 2), // external OSC_SLOW
        },
    });
    const slow = try measure(if (source == 0) 0 else 2, 1024, false);
    const rev = p.EFUSE.RD_MAC_SPI_SYS_3.raw;
    const eco1 = ((rev >> 22) & 3) * 100 + ((rev >> 18) & 15) >= 1;
    diag.milestone(0x27, @intFromPtr(&p.PCR.CTRL_TICK_CONF));
    p.PCR.CTRL_TICK_CONF.modify(.{ .FOSC_TICK_NUM = 255, .TICK_ENABLE = @intFromBool(eco1) });
    const fast = try measure(1, if (eco1) 2048 >> 5 else 2048, eco1);
    // TRM §12.4.2.5: HP PMU waits count LP_FAST, not always RC_FAST.
    const selected_fast = if (p.LP_CLKRST.LP_CLK_CONF.read().FAST_CLK_SEL == 0)
        fast
    else
        @as(u32, @intCast((@as(u64, 1_000_000) << 19) / (clocks.xtal_clk_freq / 2)));
    return .{ .slow = slow, .fast = selected_fast };
}
fn measure(select: u2, cycles: u15, divided_fast: bool) error{Timeout}!u32 {
    const t = p.TIMG0;
    diag.milestone(0x28, @intFromPtr(&t.RTCCALICFG));
    if (t.RTCCALICFG.read().RTC_CALI_START_CYCLING != 0) {
        diag.milestone(0x29, @intFromPtr(&t.RTCCALICFG2));
        t.RTCCALICFG2.modify(.{ .RTC_CALI_TIMEOUT_THRES = 1 });
        var n: u32 = 1_000_000;
        while (t.RTCCALICFG.read().RTC_CALI_RDY == 0 and t.RTCCALICFG2.read().RTC_CALI_TIMEOUT == 0) {
            n -= 1;
            if (n == 0) return error.Timeout;
        }
    }
    diag.milestone(0x29, @intFromPtr(&t.RTCCALICFG));
    t.RTCCALICFG.modify(.{ .RTC_CALI_START_CYCLING = 0, .RTC_CALI_START = 0, .RTC_CALI_CLK_SEL = select, .RTC_CALI_MAX = cycles });
    // rtc_time.c:137–147 and soc/rtc.h:52–54: 32 kHz needs four times
    // the RC_SLOW threshold; RC_FAST uses the maximum hardware threshold.
    diag.milestone(0x29, @intFromPtr(&t.RTCCALICFG2));
    t.RTCCALICFG2.modify(.{ .RTC_CALI_TIMEOUT_THRES = switch (select) {
        2 => @as(u25, cycles) << 12,
        1 => @as(u25, 0x1ffffff),
        else => @as(u25, cycles) << 10,
    } });
    diag.milestone(0x29, @intFromPtr(&t.RTCCALICFG));
    t.RTCCALICFG.modify(.{ .RTC_CALI_START = 1 });
    defer t.RTCCALICFG.modify(.{ .RTC_CALI_START = 0 });
    for (0..4_000_000) |_| {
        if (t.RTCCALICFG2.read().RTC_CALI_TIMEOUT != 0) return error.Timeout;
        if (t.RTCCALICFG.read().RTC_CALI_RDY != 0) {
            var xtal: u64 = t.RTCCALICFG1.read().RTC_CALI_VALUE;
            if (divided_fast) xtal >>= 5;
            if (xtal == 0) return error.Timeout;
            const divider = @as(u64, clocks.xtal_clk_freq / 1_000_000) * cycles;
            return @intCast(((xtal << 19) + divider / 2 - 1) / divider);
        }
    }
    return error.Timeout;
}
