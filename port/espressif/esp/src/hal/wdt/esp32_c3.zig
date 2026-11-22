const microzig = @import("microzig");
const timer = @import("../timer.zig");
const wdt = @import("../wdt.zig");
const RtcStage = wdt.RtcStage;
const rtc = microzig.chip.peripherals.RTC_CNTL;
const key = 0x50d83aa1;
const swd_key = 0x8f1d312a;

pub const Rtc = struct {
    /// RWDT uses RTC_SLOW_CLK directly and has no configuration-update latch.
    pub fn configure(stages: [4]RtcStage) void {
        rtc.WDTWPROTECT.write(.{ .WDT_WKEY = key });
        defer rtc.WDTWPROTECT.write(.{ .WDT_WKEY = 0 });
        rtc.WDTCONFIG0.modify(.{ .WDT_EN = 0, .WDT_FLASHBOOT_MOD_EN = 0 });
        rtc.WDTCONFIG1.write(.{ .WDT_STG0_HOLD = stages[0].timeout });
        rtc.WDTCONFIG2.write(.{ .WDT_STG1_HOLD = stages[1].timeout });
        rtc.WDTCONFIG3.write(.{ .WDT_STG2_HOLD = stages[2].timeout });
        rtc.WDTCONFIG4.write(.{ .WDT_STG3_HOLD = stages[3].timeout });
        rtc.WDTCONFIG0.modify(.{
            .WDT_STG0 = @backingInt(stages[0].action),
            .WDT_STG1 = @backingInt(stages[1].action),
            .WDT_STG2 = @backingInt(stages[2].action),
            .WDT_STG3 = @backingInt(stages[3].action),
            .WDT_PROCPU_RESET_EN = 1,
            // 3.2 us CPU and system reset pulses (value 7), as ESP-IDF v5.5.1
            // wdt_hal_init sets them (components/hal/wdt_hal_iram.c:57-58;
            // C3 TRM v1.4 §9.8 Register 9.31 RTC_CNTL_WDTCONFIG0). The reset value 0
            // is a 100 ns pulse.
            .WDT_SYS_RESET_LENGTH = 7,
            .WDT_CPU_RESET_LENGTH = 7,
        });
        rtc.WDTFEED.write(.{ .RTC_WDT_FEED = 1 });
        rtc.WDTCONFIG0.modify(.{ .WDT_EN = 1 });
    }

    pub fn feed() void {
        rtc.WDTWPROTECT.write(.{ .WDT_WKEY = key });
        defer rtc.WDTWPROTECT.write(.{ .WDT_WKEY = 0 });
        rtc.WDTFEED.write(.{ .RTC_WDT_FEED = 1 });
    }

    pub fn disable() void {
        rtc.WDTWPROTECT.write(.{ .WDT_WKEY = key });
        defer rtc.WDTWPROTECT.write(.{ .WDT_WKEY = 0 });
        rtc.WDTCONFIG0.write_raw(0);
    }
};

pub const Super = struct {
    pub fn feed() void {
        rtc.SWD_WPROTECT.write(.{ .SWD_WKEY = swd_key });
        defer rtc.SWD_WPROTECT.write(.{ .SWD_WKEY = 0 });
        rtc.SWD_CONF.modify(.{ .SWD_FEED = 1 });
    }

    pub fn disable() void {
        rtc.SWD_WPROTECT.write(.{ .SWD_WKEY = swd_key });
        defer rtc.SWD_WPROTECT.write(.{ .SWD_WKEY = 0 });
        rtc.SWD_CONF.modify(.{ .SWD_DISABLE = 1 });
    }
};

/// Preserve the HAL's original pre-clock-init boot sequence exactly. Only MWDT0
/// and RWDT are enabled by flash boot (§12.2.2.4). Runtime changes use Main.disable
/// with the update latch; this early boot path retains the original zero write.
pub fn disable_at_boot() void {
    const r = timer.Group.timg0.registers();
    r.WDTWPROTECT.write(.{ .WDT_WKEY = key });
    r.WDTCONFIG0.write_raw(0);
    r.WDTWPROTECT.write(.{ .WDT_WKEY = 0 });
    Rtc.disable();
    Super.disable();
}

pub fn configure_main(group: timer.Group, use_xtal: bool, stages: [4]wdt.Stage) void {
    const r = group.registers();
    r.WDTCONFIG0.modify(.{
        .WDT_STG0 = @backingInt(stages[0].action),
        .WDT_STG1 = @backingInt(stages[1].action),
        .WDT_STG2 = @backingInt(stages[2].action),
        .WDT_STG3 = @backingInt(stages[3].action),
        .WDT_USE_XTAL = @intFromBool(use_xtal),
        .WDT_FLASHBOOT_MOD_EN = 0,
        .WDT_PROCPU_RESET_EN = 1,
    });
}
