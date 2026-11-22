//! C3/C6 RWDT core-reset test. Run from flash, using image boot or direct boot;
//! never RAM-load it. Build with -Dexample=selftest_rwdt. Flash the selected
//! esp32_c3[_direct_boot]_selftest_rwdt or esp32_c6[_direct_boot]_selftest_rwdt
//! artifact using that target's normal flash layout (direct-boot .bin at 0x0).
//! Keep the USB monitor reading: no host step occurs between the two boots.
//! C3 USB pads stay attached; C6 performs a soft reconnect after cause 0x09.
//! The monitor must follow re-enumeration without resetting the board: a host
//! reset replaces the cause and invalidates the test. RWDT fires after about 2 s.
//!
//! Expected output after the autonomous second boot (repeated once per second):
//! SELFTEST rwdt core_reset: PASS reset_cause=0x9 journal=true
//! SELFTEST rwdt DONE pass=1 fail=0
//! PASS requires BOTH the pending journal and RWDT core-reset cause 0x09:
//! C3 TRM v1.4 §6.1.4 Table 6.1-1, RTC_CNTL_RESET_STATE_REG 0x60008038
//! (Register 9.12); C6 TRM v1.2 §8.1.4 Table 8.1-1, LP_CLKRST.RESET_CAUSE.
//! CPU reset (C3 0x0d/C6 0x0d) and system reset (0x10) cannot pass.
//! A 6.5 s wait disables RWDT and reports FAIL if it did not reset.
//!
//! Journal: two volatile SRAM words at 0x50001020, outside HP linked memory
//! and startup BSS/data; no LP firmware is loaded. C3 RTC FAST SRAM retention
//! through core reset: TRM v1.4 §§3.3.2, 6.1.1; C6 LP SRAM: TRM v1.2
//! §§5.3.2, 8.1.1. Magic plus complement is consumed before any new arm.
//! True chip reset has no retention guarantee; stale SRAM alone cannot pass.
//! Stage-0 HOLD compensates for the eFuse multiplier (C3 §12.2.2.2;
//! C6 §15.2.2.2). The slow clock is measured against awake system time.

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const p = microzig.chip.peripherals;
const is_c3 = hal.compatibility.chip == .esp32_c3;
// Retained SRAM, not a peripheral register.
const journal: *volatile [2]u32 = @ptrFromInt(0x50001020);
const magic: u32 = if (is_c3) 0xc3_72_77_d7 else 0xc6_72_77_d7;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_level = .info,
});

comptime {
    _ = microzig.export_startup();
}

fn report(passed: bool, reset_cause: u32, pending: bool) noreturn {
    while (true) {
        std.log.info("SELFTEST rwdt core_reset: {s} reset_cause=0x{x} journal={}", .{
            if (passed) "PASS" else "FAIL", reset_cause, pending,
        });
        std.log.info("SELFTEST rwdt DONE pass={d} fail={d}", .{
            @intFromBool(passed), @intFromBool(!passed),
        });
        hal.time.sleep_ms(1000);
    }
}

pub fn main() void {
    const reset_cause: u32 = if (is_c3)
        p.RTC_CNTL.RESET_STATE.read().RESET_CAUSE_PROCPU
    else
        p.LP_CLKRST.RESET_CAUSE.read().RESET_CAUSE;
    const pending = journal[0] == magic and journal[1] == ~magic;
    journal[0] = 0;
    journal[1] = 0;
    asm volatile ("fence iorw, iorw");
    // Clear inherited forced-download state before any watchdog can fire.
    // C3 TRM §9.8 OPTION1; C6 TRM §12.10 Register 12.61 LP_AON_SYS_CFG_REG.
    if (is_c3) {
        p.RTC_CNTL.OPTION1.modify(.{ .FORCE_DOWNLOAD_BOOT = 0 });
    } else {
        p.LP_AON.SYS_CFG.modify(.{ .FORCE_DOWNLOAD_BOOT = 0 });
    }
    hal.time.sleep_ms(1500);
    if (pending or reset_cause == 0x09)
        report(pending and reset_cause == 0x09, reset_cause, pending);

    const rtc_before = hal.clocks.sleep.rtc_ticks();
    const us_before = hal.time.get_time_since_boot().to_us();
    hal.time.sleep_ms(100);
    const rtc_elapsed = hal.clocks.sleep.rtc_ticks() -% rtc_before;
    const us_elapsed = hal.time.get_time_since_boot().to_us() - us_before;
    if (us_elapsed == 0 or rtc_elapsed == 0) report(false, reset_cause, false);
    const slow_hz = @as(u64, rtc_elapsed) * 1_000_000 / us_elapsed;
    const shift: u5 = @as(u5, p.EFUSE.RD_REPEAT_DATA1.read().WDT_DELAY_SEL) + 1;
    const hold = (slow_hz * 2) >> shift;
    if (hold == 0 or hold > std.math.maxInt(u32)) report(false, reset_cause, false);

    std.log.info("SELFTEST rwdt ARMING slow_hz={d} hold={d}; no host step", .{ slow_hz, hold });
    journal[1] = ~magic;
    journal[0] = magic;
    asm volatile ("fence iorw, iorw");
    hal.wdt.Rtc.configure(.{
        .{ .timeout = @intCast(hold), .action = .reset_core },
        .{ .timeout = 0 },
        .{ .timeout = 0 },
        .{ .timeout = 0 },
    });
    hal.time.sleep_ms(6500);
    hal.wdt.Rtc.disable();
    journal[0] = 0;
    journal[1] = 0;
    report(false, reset_cause, false);
}
