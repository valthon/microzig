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

/// C6 sleep owns this temporary RWDT only when no application RWDT is active.
/// IDF v5.5.1 sleep_modes.c:1557–1565 uses stage 0 RESET_RTC at one second.
/// Bench mode additionally runs through HP_SLEEP and allows the requested sleep
/// plus five seconds for setup/restore, unless reset_ticks requests an earlier
/// bench deadline with a later timer fallback. TRM v1.2 §15.2.2.2 Table 15.2-1:
/// action 4 resets PMU and RTC as well as HP, unlike a core-only reset.
/// §8.1.1 preserves internal memory on system reset, including this LP marker.
/// The caller holds the interrupt critical section until finish().
pub const C6SleepGuard = struct {
    installed: bool,
    bench: bool,
    saved_config: u32,
    saved_hold: u32,
    saved_interrupt: u32,

    const microzig = @import("microzig");
    const p = microzig.chip.peripherals;
    const magic: u32 = 0xc6_51_ee_90;
    // Last two words of the existing milestone reservation. SRAM, not MMIO.
    const record: *volatile [4]u32 = @ptrFromInt(0x5000_3fe0);

    pub const Recovery = struct { reset: u5, marker: u32, milestone: u32, address: u32 };

    /// Consume before another sleep or LP firmware load. RESET_RTC is code 0x10
    /// (TRM §8.1 Table 8.1-1); code 5 with a marker is normal deep-sleep wake.
    pub fn take_recovery() ?Recovery {
        if (record[2] != magic or record[3] != ~magic) return null;
        const result: Recovery = .{
            .reset = @intCast(p.LP_CLKRST.RESET_CAUSE.read().RESET_CAUSE),
            .marker = record[2],
            .milestone = record[0],
            .address = record[1],
        };
        record[2] = 0;
        record[3] = 0;
        return result;
    }

    pub fn begin(slow_period: u32, bench_ticks: ?u48, reset_ticks: ?u48) error{ InvalidTimer, WatchdogActive }!C6SleepGuard {
        if (@import("compatibility.zig").chip != .esp32_c6)
            @compileError("C6 sleep guard is C6-only");
        if (slow_period == 0) return error.InvalidTimer;
        if (reset_ticks) |ticks| {
            const fallback = bench_ticks orelse return error.InvalidTimer;
            if (ticks == 0 or ticks >= fallback) return error.InvalidTimer;
        }
        const rtc = p.LP_WDT;
        const enabled = rtc.CONFIG0.read().WDT_EN != 0;
        if (enabled and bench_ticks != null) return error.WatchdogActive;
        const saved: C6SleepGuard = .{
            .installed = !enabled,
            .bench = bench_ticks != null,
            .saved_config = rtc.CONFIG0.raw,
            .saved_hold = rtc.CONFIG1.raw,
            .saved_interrupt = rtc.INT_ENA.raw,
        };
        if (enabled) return saved; // Preserve the user's policy, as IDF does.
        const hz: u64 = (@as(u64, 1_000_000) << 19) / slow_period;
        const ticks = if (reset_ticks) |ticks| @as(u64, ticks) else if (bench_ticks) |sleep_ticks| @as(u64, sleep_ticks) + hz * 5 else hz;
        const shift: u5 = @as(u5, p.EFUSE.RD_REPEAT_DATA1.read().WDT_DELAY_SEL) + 1;
        // IDF's LL divides the effective stage-0 duration by the eFuse factor.
        // Round bench time upward so the recovery deadline is never shortened.
        const quantum = @as(u64, 1) << shift;
        const hold = if (bench_ticks != null) (ticks + quantum - 1) >> shift else ticks >> shift;
        if (hold == 0 or hold > 0xffff_ffff) return error.InvalidTimer;
        rtc.WPROTECT.write(.{ .WDT_WKEY = key });
        defer rtc.WPROTECT.write(.{ .WDT_WKEY = 0 });
        rtc.CONFIG0.modify(.{
            .WDT_EN = 0,
            .WDT_FLASHBOOT_MOD_EN = 0,
            .WDT_STG0 = 4,
            .WDT_STG1 = 0,
            .WDT_STG2 = 0,
            .WDT_STG3 = 0,
            .WDT_PAUSE_IN_SLP = @intFromBool(bench_ticks == null),
            .WDT_CHIP_RESET_EN = 0,
            .WDT_CHIP_RESET_WIDTH = 0,
            .WDT_PROCPU_RESET_EN = 1,
            .WDT_CPU_RESET_LENGTH = 7,
            .WDT_SYS_RESET_LENGTH = 7,
        });
        rtc.INT_CLR.write(.{ .LP_WDT_INT_CLR = 1 });
        rtc.INT_ENA.modify(.{ .LP_WDT_INT_ENA = 0 });
        rtc.CONFIG1.write(.{ .WDT_STG0_HOLD = @intCast(hold) });
        if (bench_ticks != null) {
            record[2] = magic;
            record[3] = ~magic;
            asm volatile ("fence iorw, iorw");
        }
        rtc.FEED.write(.{ .RTC_WDT_FEED = 1 });
        rtc.CONFIG0.modify(.{ .WDT_EN = 1 });
        return saved;
    }

    pub fn finish(self: C6SleepGuard) void {
        if (!self.installed) return;
        const rtc = p.LP_WDT;
        rtc.WPROTECT.write(.{ .WDT_WKEY = key });
        defer rtc.WPROTECT.write(.{ .WDT_WKEY = 0 });
        rtc.CONFIG0.modify(.{ .WDT_EN = 0 });
        rtc.CONFIG1.write_raw(self.saved_hold);
        rtc.INT_ENA.write_raw(self.saved_interrupt);
        rtc.CONFIG0.write_raw(self.saved_config);
        if (self.bench) {
            record[2] = 0;
            record[3] = 0;
        }
    }
};
