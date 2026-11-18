//! ESP32-C3/C6 watchdogs (C3 TRM v1.4 ch.12; C6 TRM v1.2 ch.15).
//! Caller owns configuration and must serialize protected transactions with ISRs.
//! XTAL32K watchdog is intentionally untouched.

const chip_specific = switch (@import("compatibility.zig").chip) {
    .esp32_c3 => @import("wdt/esp32_c3.zig"),
    .esp32_c6 => @import("wdt/esp32_c6.zig"),
};

const timer = @import("timer.zig");
const key = 0x50d83aa1;

pub const Action = enum(u2) { off, interrupt, reset_cpu, reset_core };
pub const RtcAction = enum(u3) { off, interrupt, reset_cpu, reset_core, reset_system };
pub const Stage = struct { timeout: u32, action: Action = .off };
pub const RtcStage = struct {
    /// Raw HOLD value in RTC slow-clock cycles. Stage 0's effective timeout is
    /// HOLD << (EFUSE_WDT_DELAY_SEL + 1), unlike stages 1–3
    /// (C3 TRM v1.4 §12.2.2.2; C6 TRM v1.2 §15.2.2.2).
    timeout: u32,
    action: RtcAction = .off,
};

pub const Main = enum(u1) {
    mwdt0,
    mwdt1,

    fn group(self: Main) timer.Group {
        return @fromBackingInt(@intCast(@backingInt(self)));
    }

    /// Configures all stages, feeds, then enables. Prescaler must be nonzero.
    pub fn configure(self: Main, prescaler: u16, use_xtal: bool, stages: [4]Stage) error{InvalidPrescaler}!void {
        if (prescaler == 0) return error.InvalidPrescaler;
        const g = self.group();
        g.enable_clock();
        const r = g.registers();
        r.REGCLK.modify(.{ .WDT_CLK_IS_ACTIVE = 1 });
        r.WDTWPROTECT.write(.{ .WDT_WKEY = key });
        defer r.WDTWPROTECT.write(.{ .WDT_WKEY = 0 });
        r.WDTCONFIG0.modify(.{ .WDT_EN = 0 });
        r.WDTCONFIG0.modify(.{ .WDT_CONF_UPDATE_EN = 1 });
        r.WDTCONFIG1.write(.{ .WDT_CLK_PRESCALE = prescaler, .WDT_DIVCNT_RST = 1 });
        r.WDTCONFIG2.write(.{ .WDT_STG0_HOLD = stages[0].timeout });
        r.WDTCONFIG3.write(.{ .WDT_STG1_HOLD = stages[1].timeout });
        r.WDTCONFIG4.write(.{ .WDT_STG2_HOLD = stages[2].timeout });
        r.WDTCONFIG5.write(.{ .WDT_STG3_HOLD = stages[3].timeout });
        chip_specific.configure_main(g, use_xtal, stages);
        // TIMG_WDTCONFIG0 update strobe commits buffered configuration
        // (C3 TRM v1.4 §11.5; C6 TRM v1.2 §14.6). Feed is a command.
        r.WDTCONFIG0.modify(.{ .WDT_CONF_UPDATE_EN = 1 });
        r.WDTFEED.write(.{ .WDT_FEED = 1 });
        self.clear_interrupt();
        r.WDTCONFIG0.modify(.{ .WDT_EN = 1 });
        r.WDTCONFIG0.modify(.{ .WDT_CONF_UPDATE_EN = 1 });
    }

    pub fn feed(self: Main) void {
        const r = self.group().registers();
        r.WDTWPROTECT.write(.{ .WDT_WKEY = key });
        defer r.WDTWPROTECT.write(.{ .WDT_WKEY = 0 });
        r.WDTFEED.write(.{ .WDT_FEED = 1 });
    }

    pub fn disable(self: Main) void {
        const r = self.group().registers();
        r.WDTWPROTECT.write(.{ .WDT_WKEY = key });
        defer r.WDTWPROTECT.write(.{ .WDT_WKEY = 0 });
        r.WDTCONFIG0.modify(.{ .WDT_EN = 0, .WDT_FLASHBOOT_MOD_EN = 0 });
        r.WDTCONFIG0.modify(.{ .WDT_CONF_UPDATE_EN = 1 });
    }

    pub fn interrupt_raw(self: Main) bool {
        return self.group().registers().INT_RAW_TIMERS.read().WDT_INT_RAW != 0;
    }

    pub fn set_interrupt_enabled(self: Main, enabled: bool) void {
        self.group().registers().INT_ENA_TIMERS.modify(.{ .WDT_INT_ENA = @intFromBool(enabled) });
    }

    pub fn clear_interrupt(self: Main) void {
        self.group().registers().INT_CLR_TIMERS.write(.{ .T0_INT_CLR = 0, .WDT_INT_CLR = 1 });
    }
};

pub const Rtc = chip_specific.Rtc;
pub const Super = chip_specific.Super;
pub const disable_at_boot = chip_specific.disable_at_boot;
