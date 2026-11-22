const microzig = @import("microzig");
const timer = @import("../timer.zig");
const wdt = @import("../wdt.zig");
const RtcStage = wdt.RtcStage;
const rtc = microzig.chip.peripherals.LP_WDT;
const key = 0x50d83aa1;
// C6 TRM v1.2 §15.6, register 15.9: SWD uses the common WDT key.
const swd_key = key;

pub const Rtc = struct {
    /// The default HAL init sequence calls this after clock/time initialization,
    /// before starting USB users, to recover USJ after RWDT core reset (0x09,
    /// C6 TRM v1.2 Table 8.1-1). USJ loses its connection after this reset.
    /// With HAL_Options.recover_usb_at_startup
    /// disabled, call it manually at that point if recovery is needed.
    /// Other reset causes and application-disabled USB pads are left alone.
    ///
    /// Use CONF0's independent pull override and pad controls (§32.7 reg 32.3)
    /// through the existing soft reconnect, including its 10 ms detach.
    /// This discards pending transfers; the host must follow re-enumeration.
    pub fn recover_usb_at_startup() void {
        switch (microzig.chip.peripherals.LP_CLKRST.RESET_CAUSE.read().RESET_CAUSE) {
            0x09 => {},
            else => return,
        }
        _ = @import("../usb_serial_jtag.zig").reconnect(.{});
    }

    /// RWDT uses RTC_SLOW_CLK directly and has no configuration-update latch.
    pub fn configure(stages: [4]RtcStage) void {
        rtc.WPROTECT.write(.{ .WDT_WKEY = key });
        defer rtc.WPROTECT.write(.{ .WDT_WKEY = 0 });
        rtc.CONFIG0.modify(.{ .WDT_EN = 0, .WDT_FLASHBOOT_MOD_EN = 0 });
        rtc.CONFIG1.write(.{ .WDT_STG0_HOLD = stages[0].timeout });
        rtc.CONFIG2.write(.{ .WDT_STG1_HOLD = stages[1].timeout });
        rtc.CONFIG3.write(.{ .WDT_STG2_HOLD = stages[2].timeout });
        rtc.CONFIG4.write(.{ .WDT_STG3_HOLD = stages[3].timeout });
        rtc.CONFIG0.modify(.{
            .WDT_STG0 = @backingInt(stages[0].action),
            .WDT_STG1 = @backingInt(stages[1].action),
            .WDT_STG2 = @backingInt(stages[2].action),
            .WDT_STG3 = @backingInt(stages[3].action),
            .WDT_PROCPU_RESET_EN = 1,
            // Match ESP-IDF v5.5.1 components/hal/wdt_hal_iram.c:57-58:
            // 7 selects 3.2 us CPU/core reset pulses. C6 TRM v1.2 §15.6,
            // Register 15.1 RTC_WDT_CONFIG0_REG (LP_WDT.CONFIG0).
            .WDT_SYS_RESET_LENGTH = 7,
            .WDT_CPU_RESET_LENGTH = 7,
        });
        rtc.FEED.write(.{ .RTC_WDT_FEED = 1 });
        rtc.CONFIG0.modify(.{ .WDT_EN = 1 });
    }

    pub fn feed() void {
        rtc.WPROTECT.write(.{ .WDT_WKEY = key });
        defer rtc.WPROTECT.write(.{ .WDT_WKEY = 0 });
        rtc.FEED.write(.{ .RTC_WDT_FEED = 1 });
    }

    pub fn disable() void {
        rtc.WPROTECT.write(.{ .WDT_WKEY = key });
        defer rtc.WPROTECT.write(.{ .WDT_WKEY = 0 });
        rtc.CONFIG0.write_raw(0);
    }
};

pub const Super = struct {
    pub fn feed() void {
        rtc.SWD_WPROTECT.write(.{ .SWD_WKEY = swd_key });
        defer rtc.SWD_WPROTECT.write(.{ .SWD_WKEY = 0 });
        rtc.SWD_CONFIG.modify(.{ .SWD_FEED = 1 });
    }

    pub fn disable() void {
        rtc.SWD_WPROTECT.write(.{ .SWD_WKEY = swd_key });
        defer rtc.SWD_WPROTECT.write(.{ .SWD_WKEY = 0 });
        rtc.SWD_CONFIG.modify(.{ .SWD_DISABLE = 1 });
    }
};

/// Same early-boot shutdown as the existing C6 HAL startup (TRM v1.2
/// §§14.6, 15.2.2.4, 15.6). Both timer groups may be armed by ROM.
pub fn disable_at_boot() void {
    inline for (.{ timer.Group.timg0, timer.Group.timg1 }) |g| {
        const r = g.registers();
        r.WDTWPROTECT.write(.{ .WDT_WKEY = key });
        r.WDTCONFIG0.write_raw(0);
        r.WDTCONFIG0.modify(.{ .WDT_CONF_UPDATE_EN = 1 });
        r.WDTWPROTECT.write(.{ .WDT_WKEY = 0 });
    }
    Rtc.disable();
    Super.disable();
}

pub fn configure_main(group: timer.Group, use_xtal: bool, stages: [4]wdt.Stage) void {
    const r = group.registers();
    // MWDT has its own PCR clock mux (C6 TRM v1.2 §15.2.2.1;
    // §8.5.1 registers 8.16/8.19). TIMG bit 21 is reserved on C6.
    const pcr = microzig.chip.peripherals.PCR;
    switch (group) {
        .timg0 => pcr.TIMERGROUP0_WDT_CLK_CONF.modify(.{ .TG0_WDT_CLK_SEL = @as(u2, if (use_xtal) 0 else 1), .TG0_WDT_CLK_EN = 1 }),
        .timg1 => pcr.TIMERGROUP1_WDT_CLK_CONF.modify(.{ .TG1_WDT_CLK_SEL = @as(u2, if (use_xtal) 0 else 1), .TG1_WDT_CLK_EN = 1 }),
    }
    r.WDTCONFIG0.modify(.{
        .WDT_STG0 = @backingInt(stages[0].action),
        .WDT_STG1 = @backingInt(stages[1].action),
        .WDT_STG2 = @backingInt(stages[2].action),
        .WDT_STG3 = @backingInt(stages[3].action),
        .WDT_FLASHBOOT_MOD_EN = 0,
        .WDT_PROCPU_RESET_EN = 1,
    });
}
