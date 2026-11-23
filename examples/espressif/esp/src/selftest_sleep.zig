//! OLED reporter (default; -Dsleep_report=beacon selects the original wire protocol).
//! GPIO5/6 are exclusively I2C0 SDA/SCL, 0x3C, or beacon data/clock. GPIO8 blinks.
//! First main action clears the ENTIRE 128x64 RAM, then shows S1..S6 and BOOT.
//! Five 12-character lines fit the 72x40 window: stage, step, CODE=hex,
//! P=passed F=failed, and an inverted final PASS/FAIL which remains on screen.
//! Counts include one latched display check in OLED mode; a write failure cannot
//! be erased by a later successful retry. An absent panel cannot show its failure.
//! S1: BOOT, attached control and USB probes, final PASS P=4 F=0 expected.
//! S2: BOOT, ARMING, WAIT RESET; after the RWDT reset the flash image boots
//! again and shows PASS P=2 F=0 for reset cause 9, otherwise FAIL.
//! S3: BOOT, 100MS, sleep/USB checks, final PASS P=9 F=0 if all pass.
//! S4: BOOT, 100MS/500MS/GPIO, final PASS P=12 F=0 if all pass.
//! S3/S4 accept USB loss: a failed USB check makes the final screen FAIL.
//! S5: BOOT, detach/reset/attach and USB probes, final PASS P=5 F=0 expected.
//! S6: BOOT, RECONNECT/100MS/500MS and nonce exchanges, PASS P=13 F=0 expected.
//! In all stages any failed check instead leaves inverted FAIL with its counts,
//! and line 2 names the first check that failed (e.g. HOST SOF) instead of DONE.
//! CODE retains ALL original meanings documented below, including HAL 80..92,
//! indexed checks 70+i/A0+i, diagnostic C0..C2/D0..DF and final 63/64.
//! OLED adds check index 12: 7C=display PASS, AC=display FAIL (no new beacon bytes).
//! HAL trace codes are buffered while sleep changes clocks and replayed AFTER
//! return and timing samples, with I2C configuration re-applied before drawing.
//! Thus the OLED cannot identify an internal sleep halt; beacon mode still can.
//! Once final, later repeated diagnostic/result codes leave the screen intact.
//!
//! Start with flashless selftest_sleep_s1 (keeps USB attached), then s3/s4.
//! s2 and s5 are opt-in recovery/re-enumeration experiments; see below.
//! selftest_sleep is an alias for s4. s1/s2/s5 use USB reports; s3/s4 report
//! out of band, because C3 light sleep can lose USB after wakeup.
//! Selectable out-of-band beacon in ALL stage images: GPIO5=data, GPIO6=clock, idle low.
//! Each byte starts with clock low for >=60 us; then 8 bits MSB first. For
//! each bit set data while clock is low, wait >=10 us, raise clock for >=10 us,
//! then lower it. Sample data on each rising edge; eight edges form one code.
//! A clock-low gap >=60 us frames the next byte (normal low time is ~10 us).
//! Data returns low after bit 0. At 4 MHz each half-bit spans >=40 samples.
//! Every progress() emits its operation code BEFORE touching the SRAM journal.
//! End loops repeat the last code on a 200 ms schedule, also during report
//! delays and between USB log calls. Logging may delay a heartbeat while its
//! bounded TX waits run (100 ms per drain); byte framing is unchanged.
//! GPIO8 (active-low LED) toggles on every code, visibly blinking at the end.
//! Beacon mode borrows the SSD1306 pins; OLED mode never drives the beacon.
//! No USB or retained memory is needed to capture/decode these bytes. A halt
//! before main/beacon initialization produces no beacon; a halt mid-byte is
//! recognizable as fewer than eight edges. Capture continuously before load_ram.
//!
//! s6: reconnect() without sleep, then 100 ms and 500 ms sleeps using the
//! disconnect_and_reenumerate policy, all three sharing one
//! usb_serial_jtag.Attachment owned by the test. Before the first phase,
//! usb_serial_jtag.wait_for_host (<=2 s) records an attached host in that
//! Attachment; its result and wait time repeat on USB as the info line
//! "SELFTEST sleep_s6 info wait_for_host host_seen=<bool> wait_us=<n>",
//! which is not a check: it is outside the twelve checks, DONE and the
//! beacon. Each phase runs once; all results repeat forever on USB and the
//! beacon. Host procedure: after EACH detach close the old COM handle and
//! reopen the re-enumerated port; 1.5 s after opening send exactly "USJ?";
//! print every line received; on a line "USJ nonce=<8 hex digits>" send
//! "ACK <same digits>\r\n".
//! Per phase the device drains RX before detaching and again as soon as the
//! re-attach returns (a "USJ?" that arrived after the first drain and before
//! the detach, e.g. during the SOF sampling, may survive it and must not
//! count), then:
//! 0xe4 waits <=10 s for "USJ?" (cdc_out), then 0xe3 sends the nonce line
//! (again each second while the IN FIFO is free) and waits <=10 s for the
//! matching ACK (cdc_in). The nonce comes from the RNG and differs per phase,
//! so only a host that read the IN data can pass cdc_in; a bus reset, a free
//! IN FIFO or a stale OUT string cannot. No USB logs occur between attach
//! and the end of the ACK wait.
//! Codes 0xe0/e1/e2=start reconnect/100ms/500ms; 0xe4=waiting for "USJ?",
//! 0xe3=nonce sent, waiting for ACK. HAL sleep trace codes keep their meanings.
//! Beacon 0x70+i=PASS, 0xa0+i=FAIL, i=0..11: groups of four checks for
//! reconnect, 100ms, 500ms, respectively: operation, bus_reset, cdc_in, cdc_out.
//! Operation checks exact CONF0/INT_ENA restoration; sleep also requires timer
//! wake and RTC elapsed minus active UNIT1 time consistent with CPU stall.
//! 0x63/64=end frame all passed/at least one failed.
//! Failed checks stay failed even if a subsequent phase recovers the host.
//!
//! s1: awake attached control only, no detach, watchdog or RTC configuration.
//! s1/s5 cdc_in passes when the IN FIFO frees after the "USJ IN probe" line is
//! flushed: the host controller took the packet at the USB level. It does not
//! show that a host application read it (s6 checks that with a nonce echo).
//! s5: destructive USB_DEVICE reset and one-second disconnect, then attach.
//! Close the old COM handle and reopen the re-enumerated port, then send
//! exactly "USJ?" 1.5 s after opening, as in s6; do not wait for the probe line,
//! which may never reach the application after re-enumeration (see s6). The
//! device reads the OUT FIFO for <=10 s after its cdc_in check.
//! No observed Windows removal/re-enumeration is claimed by an on-chip PASS.
//! After attach wait <=10 s for SOF_FRAME_INDEX to change from a post-attach
//! sample (§30.6 register 30.8). Codes 9=waiting, 0x0a=SOF advanced,
//! 0x0b=host timeout. CDC checks then replace this with their outcome code.
//! SOF proves host bus activity, not successful CDC enumeration/host reading.
//! USB reports pad state, host_sof and cdc_in independently; each can FAIL.
//! s5 also reports cdc_out. 0x0c=before reset, 0x0d=reset and detached,
//! 0x0e=one-second hold ended, 0x0f=waiting for CDC, 0x61=CDC passed,
//! 0x62=CDC failed. SOF alone never makes CDC pass.
//! s2: RWDT core reset with USB attached, WITHOUT sleep. Run the direct-boot
//! build from flash (esp32_c3_direct_boot_selftest_sleep_s2.bin at 0x0), not
//! a RAM load: s2 does not force download boot, so after the reset the chip
//! boots the same image again, which reports PASS only for a pending s2 journal
//! AND RESET_CAUSE_PROCPU 9 (RTC_CNTL_RESET_STATE_REG 0x60008038, TRM v1.4 Register 9.12;
//! causes in §6.1.4). No host step between the boots: opening the port from
//! the host can raise a USB-JTAG reset (cause 0x15, TRM v1.4 §6.1.4),
//! invalidating the retained journal.
//! If RWDT fails to fire, a bounded wait disables it and reports FAIL instead.
//! s3: ONE 100 ms sleep, explicitly accepting USB loss, with no pad disconnect.
//! s4: full timer/GPIO/retention test with the same policy as s3.
//! TRM §30.4 and ESP-IDF v5.4.2 docs/en/api-guides/usb-serial-jtag-console.rst
//! "Light-sleep" document APB/PHY clock gating and failure to reconnect.
//! See hal/sleep.zig for the register audit and IDF source references. Powered
//! domains/PLL and attached pads cannot establish uninterrupted USB clocks.
//! After checks, disable RWDT and test SOF advancement and an IN probe taken
//! by the host controller at the USB level (the IN FIFO frees; no proof that a
//! host application read it), each with a 10 s deadline. Keep the host monitor
//! reading.
//! 0x50 means BOTH passed, 0x51 means one or both failed; neither proves OUT.
//! s3/s4 never log a USB report or emit 0x60. Their beacon report repeats:
//! 0x70+i=PASS, 0xa0+i=FAIL for result index i (decimal):
//! 0 awake_control, 1 timer_100ms, 2 cpu_stalled_100ms,
//! 3 timer_500ms, 4 cpu_stalled_500ms, 5 gpio_pullup,
//! 6 output_retained, 7 ram_retained, 8 clocks_restored,
//! 9 host_sof, 10 cdc_in, 11 usb_loss_guard. s3 omits indices 3..5.
//! cdc_in (10) is a note, not a check, in s3/s4: allow_usb_loss leaves the
//! endpoints dead after wake by design, so it is never emitted or counted; the
//! final OLED screen says DONE USBLOST when the IN probe was not consumed.
//! Each frame ends 0x63=all checks passed or 0x64=at least one failed.
//! Before USB probing and in every result frame, diagnostics use 0xb1/b2/b3
//! for the 100ms/500ms/GPIO call, then 0xc0 + five 0xd0|nibble bytes for
//! WAKEUP_CAUSE, 0xc1 + five for REJECT_CAUSE, 0xc2 + eight for INT_RAW_RTC.
//! Nibbles are most significant first; payload bytes never mimic progress.
//! INT_RAW bits 0/1/10 are sleep-wakeup/reject/main-timer (TRM §9.8 reg 9.14).
//! Zero diagnostics mean no request completed (inspect the error milestone).
//! Retention observations: 0xb4/b5=output matches/mismatches, 0xb6/b7=RAM
//! matches/mismatches, 0xb8/b9=timer sleep precondition passed/failed. The
//! indexed retention checks still require the precondition to avoid an awake
//! run passing retention; observations distinguish skipped proof from damage.
//! The first full frame ends within 3 s of the USB probe's last check.
//! A failed USB check stays a failure even if a later reopen recovers USB.
//! Repeating 0x52 means download recovery was unavailable; no sleep attempted.
//!
//! RWDT recovery for s3/s4 forces Joint Download Boot rather than the unrelated
//! flash app (TRM §7.2, §9.8 OPTION1). Refuse risky stages if download eFuses
//! prohibit this. No system-reset fallback: it would clear FORCE_DOWNLOAD_BOOT.
//! s2 does not set FORCE_DOWNLOAD_BOOT and boots its own flash image (above);
//! it clears an inherited FORCE_DOWNLOAD_BOOT itself before arming (OPTION1
//! 0x600080F4 bit 0, TRM v1.4 §9.8 OPTION1).
//! §30.3.4 explicitly exempts USJ from JTAG SRST. Keep USB pads attached
//! through the core-reset recovery path.
//!
//! Forensics BEFORE loading another image (esptool flags above, add --port):
//! read_mem 0x50001000 = magic 0xc350bace
//! read_mem 0x50001004 = build stage (1..6)
//! read_mem 0x50001008 = latest operation; 0x5000100c = its bitwise complement
//! read_mem 0x50001010 = last wake bits; 0x50001014 = last Zig error number
//! read_mem 0x50001018 = s2 pending marker (0x52574454)
//! Operations: 1=start, 2=calibrated, 3=before detach, 4=detached, 5=attached,
//! 6=before watchdog setup, 7=watchdog armed, 8=s2 detached awaiting reset; 0x10/20/30=100ms/500ms/GPIO call,
//! 0x11/21/31=returned, 0x12/22/32=cause saved, 0x1f/2f/3f=error,
//! 0x40=sleep checks ended, 0x50=USB verified, 0x51=USB failed,
//! 0x60=USB report attempted (s2 only), 0x63/64=beacon report passed/failed.
//! HAL operations 0x80..0x92: see sleep.Step; each marks the NEXT operation.
//! STORE0/2/3 mirror operation/wake/error while RTC registers survive.
//!
//! TRM v1.4 §3.3.2/§14.4.3: C3 has 8 KiB RTC FAST SRAM, no RTC SLOW SRAM.
//! This test reserves 28 bytes at 0x50001000, outside the port's linked regions;
//! neither startup BSS clearing nor esptool's image segments initialize it.
//! §6.1.1 guarantees internal memory through CPU/core/system resets, NOT chip
//! reset. §6.1.4 classifies power-glitch reset as CORE reset (retained), whereas
//! power-on/brownout chip reset has NO retention guarantee. Thus try this SRAM
//! journal after BOOT+RST, but reject bad magic/complement; even a valid journal
//! can be stale. No on-chip memory is documented as surviving a true chip reset.
//! A power cycle can destroy all evidence; capture the last host report too.
//!
//! HAL init configures PLL/CPU clocks before main. TRM v1.4 §§6.2, 30.4
//! require PLL and >=40 MHz APB for USB.
//! Local ESP-IDF components/esp_hw_support/sleep_console.c disables USJ pads
//! AND bus clock, restores bus clock BEFORE pads; sleep_modes.c calls it only
//! in light-sleep preparation (for pad leakage). It is not a startup requirement.
//! port/esp32c3/rtc_sleep.c configures memory force-PU, regulator, analog sleep
//! bias and XTAL before rtc_sleep_start requests the FSM (§§9.3–9.5). Our HAL
//! marks these transitions separately to identify the last operation.
//! s5 resets USB_DEVICE (§16.3.5 PERIP_RST_EN0), then keeps
//! pads disabled with both pull-ups overridden off (§30.6 register 30.2).
//! USB 2.0 §7.1.7.3/Table 7-13 TDDIS is electrical disconnect detection, not
//! Windows removal notification. One second is an experimental host allowance,
//! not a specified Windows minimum. Host reset/enumeration must be observed.
//! RTC_CNTL.USB_CONF is IO_MUX_RESET_DISABLE, NOT a USB pull/attach control
//! (§9.8 register 9.53). Digital GPIO hold includes USB GPIO18/19 (§5.8,
//! §9.8 register 9.47); this test never enables hold. s1 reports CONF0 before,
//! detached, attached, USB_CONF and DIG_PAD_HOLD for diagnosis of inherited state.
//! Reset-to-first-report startup sequence:
//! esp_riscv._start -> BSS-only initialization for RAM images -> interrupts ->
//! microzig_main -> hal.init (cache, watchdogs, clocks, system, time) -> main.
//! Cache initialization also runs for RAM images.
//! Hardware results for each stage: see the port README.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const sleep = hal.clocks.sleep;
const RTC = microzig.chip.peripherals.RTC_CNTL;
const USB = microzig.chip.peripherals.USB_DEVICE;
const build_stage = @import("sleep_test_options").stage;
const use_oled = @import("sleep_test_options").oled;
const oled = @import("oled_text.zig");
// Ordinary retained SRAM, not MMIO. No linked allocation overlaps this area.
const journal: *volatile [7]u32 = @ptrFromInt(0x50001000);
const journal_magic = 0xc350bace;
const pending_magic = 0x52574454;
const beacon_data = hal.gpio.num(5);
const beacon_clock = hal.gpio.num(6);
const beacon_led = hal.gpio.num(8);
var beacon_enabled = false;
var last_code: u8 = 1;
var led_level: u1 = 1;
var last_beacon_us: u64 = 0;

var display_failed = false;
var display_busy = false;
var display_final = false;
var check_pass: usize = 0;
var check_fail: usize = 0;
var display_pass: usize = 0;
var display_fail: usize = 0;
var display_deferred = false;
var deferred_codes: [32]u8 = undefined;
var deferred_count: usize = 0;

fn display_error(err: (oled.Error || error{NoSpaceLeft})) void {
    const first = !display_failed;
    display_failed = true;
    counts(check_pass, check_fail);
    // Use the logger directly: the normal log callback services the reporter.
    if (first and build_stage != 3 and build_stage != 4)
        hal.usb_serial_jtag.logger.log(.info, .default, "SELFTEST sleep_s{d} display: FAIL error={s}", .{ build_stage, @errorName(err) });
}

fn draw_code(code: u8) !void {
    counts(check_pass, check_fail);
    var buffer: [12]u8 = undefined;
    try oled.line(0, try std.mem.print(&buffer, "S{d} SLEEP", .{build_stage}), false);
    const step: []const u8 = switch (code) {
        1 => "BOOT",
        2 => "CALIBRATED",
        6 => "ARMING",
        7 => "RWDT ARMED",
        8 => "WAIT RESET",
        9 => "WAIT SOF",
        0x10, 0xe1 => "100MS",
        0x20, 0xe2 => "500MS",
        0x30 => "GPIO",
        0x40 => "CHECKS ENDED",
        0x52 => "NO RECOVERY",
        0x63, 0x64 => "DONE",
        0x7c, 0xac => "DISPLAY",
        0xe0 => "RECONNECT",
        0xe3 => "WAIT ACK",
        0xe4 => "WAIT USJ",
        else => "STEP",
    };
    const failed_step = if (code == 0x64 and first_failed != null)
        failed_name(first_failed.?)
    else if (code == 0x63 and usb_lost_note)
        "DONE USBLOST"
    else
        step;
    try oled.line(1, failed_step, false);
    try oled.line(2, try std.mem.print(&buffer, "CODE={X:0>2}", .{code}), false);
    try oled.line(3, try std.mem.print(&buffer, "P={d} F={d}", .{ display_pass, display_fail }), false);
    const final = code == 0x63 or code == 0x64;
    try oled.line(4, if (final) (if (code == 0x63 and !display_failed) "PASS" else "FAIL") else "", final);
    display_final = final;
}

/// Index of the first check reported as failed (0xa0 + i), shown on the final screen.
var first_failed: ?u8 = null;

/// Short check names for the final screen (font: A-Z, 0-9, space, = : - /).
fn failed_name(index: u8) []const u8 {
    if (index == 12) return "DISPLAY";
    const names: []const []const u8 = if (build_stage == 6)
        &.{ "RECON OP", "RECON BUSRST", "RECON CDCIN", "RECON CDCOUT", "100 OP", "100 BUSRST", "100 CDCIN", "100 CDCOUT", "500 OP", "500 BUSRST", "500 CDCIN", "500 CDCOUT" }
    else
        &.{ "AWAKE", "TIMER 100", "STALL 100", "TIMER 500", "STALL 500", "GPIO PULLUP", "OUTPUT RET", "RAM RET", "CLOCKS", "HOST SOF", "CDC IN", "USB GUARD" };
    return if (index < names.len) names[index] else "CHECK";
}

fn show_code(code: u8) void {
    if (code >= 0xa0 and code <= 0xac and first_failed == null) first_failed = code - 0xa0;
    if (display_busy or display_final) return;
    if (display_deferred) {
        // The HAL's bounded trace has fewer than 32 milestones per call.
        if (deferred_count < deferred_codes.len) {
            deferred_codes[deferred_count] = code;
            deferred_count += 1;
        } else display_failed = true; // No logging/waits inside the HAL trace.
        return;
    }
    display_busy = true;
    defer display_busy = false;
    draw_code(code) catch |err| display_error(err);
}

fn resume_display() void {
    if (!use_oled) return;
    display_busy = true;
    oled.configure() catch |err| display_error(err);
    display_busy = false;
    display_deferred = false;
    for (deferred_codes[0..deferred_count]) |code| show_code(code);
    deferred_count = 0;
}

// Called once results are known, and on repeated USB reports for consistency.
fn counts(pass: usize, fail: usize) void {
    check_pass = pass;
    check_fail = fail;
    display_pass = pass + @intFromBool(use_oled and !display_failed);
    display_fail = fail + @intFromBool(use_oled and display_failed);
}

fn finish(pass: usize, fail: usize) void {
    counts(pass, fail);
    if (use_oled) {
        progress(if (display_failed) 0xac else 0x7c);
        counts(pass, fail);
    }
    progress(if (display_fail == 0) 0x63 else 0x64);
    // The final write can itself fail: latch and include it in USB totals.
    counts(pass, fail);
}

fn beacon(code: u8) void {
    if (use_oled) {
        show_code(code);
        led_level ^= 1;
        beacon_led.put(led_level);
        last_beacon_us = hal.time.get_time_since_boot().to_us();
        return;
    }

    beacon_clock.put(0);
    hal.time.sleep_us(60);
    for (0..8) |bit| {
        beacon_data.put(@truncate(code >> @as(u3, @intCast(7 - bit))));
        hal.time.sleep_us(10);
        beacon_clock.put(1);
        hal.time.sleep_us(10);
        beacon_clock.put(0);
    }
    beacon_data.put(0);
    led_level ^= 1;
    beacon_led.put(led_level);
    last_beacon_us = hal.time.get_time_since_boot().to_us();
}

fn heartbeat() void {
    if (!beacon_enabled) return;
    if (hal.time.get_time_since_boot().to_us() -% last_beacon_us >= 200_000)
        beacon(last_code);
}

fn report_delay(ms: u32) void {
    const start = hal.time.get_time_since_boot().to_us();
    while (hal.time.get_time_since_boot().to_us() -% start < @as(u64, ms) * 1000) {
        heartbeat();
    }
}

// Keep the heartbeat serviced even when a host is absent and logging times out.
fn log(comptime level: std.log.Level, comptime scope: @TypeOf(.EnumLiteral), comptime format: []const u8, args: anytype) void {
    heartbeat();
    hal.usb_serial_jtag.logger.log(level, scope, format, args);
    heartbeat();
}

fn trace(step: sleep.Step) void {
    progress(@backingInt(step));
}

fn progress(stage: u8) void {
    last_code = stage;
    beacon(stage);
    journal[3] = 0;
    journal[2] = stage;
    journal[3] = ~@as(u32, stage);
    RTC.STORE0.write_raw(0xc3500000 | @as(u32, stage));
}

fn arm_watchdog(ticks_per_second: u32, force_download: bool) void {
    // §7.2: retained across core reset, so ROM stays reachable for RAM reload.
    // s2 instead boots the same image again from flash after the reset.
    RTC.OPTION1.modify(.{ .FORCE_DOWNLOAD_BOOT = @intFromBool(force_download) });
    const shift: u5 = @as(u5, microzig.chip.peripherals.EFUSE.RD_REPEAT_DATA1.read().WDT_DELAY_SEL) + 1;
    // The reset defaults may pause RWDT in sleep; explicitly clear that bit.
    RTC.WDTWPROTECT.write(.{ .WDT_WKEY = 0x50d83aa1 });
    RTC.WDTCONFIG0.modify(.{ .WDT_PAUSE_IN_SLP = 0, .WDT_CHIP_RESET_EN = 0 });
    RTC.WDTWPROTECT.write(.{ .WDT_WKEY = 0 });
    hal.wdt.Rtc.configure(.{
        .{ .timeout = @max(1, ticks_per_second * 3 >> shift), .action = .reset_core },
        .{ .timeout = ticks_per_second * 2, .action = .reset_core },
        .{ .timeout = 0 },
        .{ .timeout = 0 },
    });
}

fn enter(config: sleep.Config, stage: u8) sleep.Error!sleep.WakeCause {
    hal.wdt.Rtc.feed();
    if (use_oled) display_deferred = true;
    progress(stage);
    var traced = config;
    traced.allow_usb_loss = true;
    traced.trace = trace;
    traced.diagnostics = &sleep_diagnostics[(stage >> 4) - 1];
    const cause = sleep.enter_light_sleep(traced) catch |err| {
        journal[5] = @intFromError(err);
        RTC.STORE3.write_raw(@intFromError(err));
        progress(stage | 0xf);
        return err;
    };
    progress(stage | 1);
    journal[4] = cause.raw;
    RTC.STORE2.write_raw(cause.raw);
    progress(stage | 2);
    return cause;
}

var sleep_diagnostics: [3]sleep.Diagnostics = @splat(.{});

fn diagnostic_value(marker: u8, value: u32, nibbles: u4) void {
    beacon(marker);
    var remaining = nibbles;
    while (remaining > 0) {
        remaining -= 1;
        const shift: u5 = @intCast(@as(u6, remaining) * 4);
        beacon(0xd0 | @as(u8, @intCast((value >> shift) & 0xf)));
    }
}

fn report_sleep_diagnostics() void {
    for (sleep_diagnostics, 0..) |diagnostics, i| {
        if (build_stage == 3 and i != 0) continue;
        beacon(0xb1 + @as(u8, @intCast(i)));
        diagnostic_value(0xc0, diagnostics.wake, 5);
        diagnostic_value(0xc1, diagnostics.reject, 5);
        diagnostic_value(0xc2, diagnostics.interrupt_raw, 8);
    }
}

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = log,
    .log_level = .info,
});
comptime {
    _ = microzig.export_startup();
}

const Result = struct {
    name: []const u8,
    passed: bool = false,
    rtc: u64 = 0,
    active_us: u64 = 0,
    cause: u17 = 0,
    err: ?sleep.Error = null,
    nonce: u32 = 0,
};

fn timer_check(ms: u32, ticks: u48, stage: u8, result: *Result, stalled: *Result) sleep.Error!void {
    // Draw outside both clocks' measurement windows: I2C traffic is active CPU time.
    if (use_oled) progress(stage);
    const before = sleep.rtc_ticks();
    const active_before = hal.systimer.unit(1).read();
    const cause = enter(.{ .timer_ticks = ticks }, stage) catch |err| {
        resume_display();
        return err;
    };
    const active_after = hal.systimer.unit(1).read();
    const elapsed = sleep.rtc_ticks() -% before;
    resume_display();
    const active_us = (active_after -% active_before) / 16;
    result.rtc = elapsed;
    result.active_us = active_us;
    result.cause = cause.raw;
    // RTC comparison is independent of the counter used to prove CPU stall.
    // Permit 10% entry/wakeup overhead and RC drift, but never early wake.
    result.passed = cause.timer and !cause.gpio and elapsed >= ticks and
        elapsed <= ticks + ticks / 10;
    stalled.rtc = elapsed;
    stalled.active_us = active_us;
    // TRM v1.4 §10.2: UNIT1_CORE0_STALL_EN stops counting on CPU stall.
    // §9.3.3: the independent RTC continues through sleep. The awake control
    // below first proves UNIT1 counts normally; a busy delay would fail here.
    stalled.passed = result.passed and active_us < @as(u64, ms) * 1000 / 4;
}

pub fn main() void {
    // HAL startup has already initialized clocks/system/time; draw before journal access.
    if (use_oled) {
        display_busy = true;
        oled.init() catch |err| display_error(err);
        display_busy = false;
        show_code(1);
    } else {
        beacon_data.put(0);
        beacon_clock.put(0);
        beacon_data.apply(.{ .output_enable = true });
        beacon_clock.apply(.{ .output_enable = true });
    }
    beacon_led.put(1);
    beacon_led.apply(.{ .output_enable = true });
    beacon_enabled = true;
    const reset_cause = RTC.RESET_STATE.read().RESET_CAUSE_PROCPU;
    const pending = journal[0] == journal_magic and journal[1] == 2 and
        journal[2] == 8 and journal[3] == ~@as(u32, 8) and journal[6] == pending_magic;
    journal[0] = 0;
    journal[1] = build_stage;
    journal[4] = 0;
    journal[5] = 0;
    journal[6] = 0;
    progress(1);
    journal[0] = journal_magic;
    RTC.STORE2.write_raw(0);
    RTC.STORE3.write_raw(0);
    report_delay(1500);
    if (build_stage == 1 or build_stage == 5) stage_one(reset_cause);
    if (build_stage == 2 and pending) {
        // Never treat a software/manual reset, or just being alive, as RWDT proof.
        report_simple("rwdt_recovery", reset_cause == 9, 0, reset_cause);
    }
    const efuse = microzig.chip.peripherals.EFUSE;
    const download_allowed = efuse.RD_REPEAT_DATA0.read().DIS_FORCE_DOWNLOAD == 0 and
        efuse.RD_REPEAT_DATA3.read().DIS_DOWNLOAD_MODE == 0 and
        efuse.RD_REPEAT_DATA3.read().ENABLE_SECURITY_DOWNLOAD == 0;
    if (!download_allowed) {
        if (build_stage == 3 or build_stage == 4) {
            progress(0x52);
            while (true) report_delay(1000);
        }
        report_simple("download_recovery_available", false, 0, reset_cause);
    }
    if (build_stage == 6) stage_six();
    if (build_stage == 2) {
        // Arm from the measured RTC_SLOW_CLK rate, as s3/s4 do, not the nominal 136 kHz.
        const cal_rtc = sleep.rtc_ticks();
        const cal_sys = hal.systimer.unit(0).read();
        hal.time.sleep_ms(50);
        const cal_us = (hal.systimer.unit(0).read() -% cal_sys) / 16;
        const slow_hz: u32 = if (cal_us > 0) @intCast(@as(u64, sleep.rtc_ticks() -% cal_rtc) * 1000000 / cal_us) else 136000;
        journal[6] = pending_magic;
        progress(6);
        arm_watchdog(slow_hz, false);
        progress(7);
        std.log.info("SELFTEST sleep_s2 ARMING: USB stays attached; expect RWDT reset, then this flash image reports rwdt_recovery; slow_hz={d} wdtconfig0=0x{x} stg0_hold={d} stg1_hold={d} delay_sel={d}", .{
            slow_hz,                                                              RTC.WDTCONFIG0.raw, RTC.WDTCONFIG1.raw, RTC.WDTCONFIG2.raw,
            microzig.chip.peripherals.EFUSE.RD_REPEAT_DATA1.read().WDT_DELAY_SEL,
        });
        report_delay(300);
        // Keep USB pads attached: C3 retains its connection through RWDT reset.
        // The TRM guarantees USJ is not affected by SRST (v1.4 §30.3.4).
        progress(8);
        const before = hal.systimer.unit(0).read();
        hal.time.sleep_ms(6500);
        const elapsed_us = (hal.systimer.unit(0).read() -% before) / 16;
        hal.wdt.Rtc.disable();
        journal[6] = 0;
        RTC.OPTION1.modify(.{ .FORCE_DOWNLOAD_BOOT = 0 });
        report_simple("rwdt_did_not_reset", false, elapsed_us, reset_cause);
    }
    progress(6);
    arm_watchdog(136000, true);
    progress(7);
    var results = [_]Result{
        .{ .name = "awake_control" },
        .{ .name = "timer_100ms" },
        .{ .name = "cpu_stalled_100ms" },
        .{ .name = "timer_500ms" },
        .{ .name = "cpu_stalled_500ms" },
        .{ .name = "gpio_pullup" },
        .{ .name = "output_retained" },
        .{ .name = "ram_retained" },
        .{ .name = "clocks_restored" },
        .{ .name = "host_sof" },
        .{ .name = "cdc_in" },
        .{ .name = "usb_loss_guard" },
    };

    // GPIO0 and GPIO7 have no board wiring. Avoid OLED 5/6, LED 8, flash and USB.
    const wake_pin = hal.gpio.num(0);
    wake_pin.apply(.{ .input_enable = true, .pull = .up });
    const output = hal.gpio.num(7);
    output.put(1);
    output.apply(.{ .output_enable = true, .input_enable = true });
    const output_before = output.read() == 1;

    // Volatile prevents the optimizer from replacing the post-sleep RAM reads
    // with known constants. Check every word, including a changing pattern.
    var memory: [128]u32 = undefined;
    const ram: *volatile [128]u32 = &memory;
    for (0..128) |i| ram[i] = 0xa5c30000 ^ @as(u32, @intCast(i * 7919));

    hal.systimer.unit(1).apply(.disabled_if_cpu_stalled);
    const calibration_start = sleep.rtc_ticks();
    const sys_start = hal.systimer.unit(0).read();
    const control_start = hal.systimer.unit(1).read();
    hal.time.sleep_ms(50);
    const control_us = (hal.systimer.unit(1).read() -% control_start) / 16;
    const sys_us = (hal.systimer.unit(0).read() -% sys_start) / 16;
    const calibration_ticks = sleep.rtc_ticks() -% calibration_start;
    progress(2);
    results[0].rtc = calibration_ticks;
    results[0].active_us = control_us;
    results[0].passed = calibration_ticks > 0 and control_us >= 49000 and control_us <= 51000;

    const sysclk_before = microzig.chip.peripherals.SYSTEM.SYSCLK_CONF.raw;
    const cpu_before = microzig.chip.peripherals.SYSTEM.CPU_PER_CONF.raw;
    if (calibration_ticks > 0 and sys_us > 0) {
        arm_watchdog(@intCast(@as(u64, calibration_ticks) * 1000000 / sys_us), true);
        const ticks100: u48 = @intCast(@as(u64, calibration_ticks) * 100000 / sys_us);
        const ticks500: u48 = @intCast(@as(u64, calibration_ticks) * 500000 / sys_us);
        // Default entry must refuse enabled USB pads before any sleep writes.
        // The subsequent diagnostic entry explicitly opts in to losing USB.
        if (USB.CONF0.read().USB_PAD_ENABLE == 1) {
            const power_before = RTC.DIG_PWC.raw;
            const clock_before = RTC.CLK_CONF.raw;
            const usb_before = USB.CONF0.raw;
            const refused = if (sleep.enter_light_sleep(.{ .timer_ticks = ticks100 })) |_|
                false
            else |err|
                err == error.UsbSerialJtagActive;
            results[11].passed = refused and RTC.DIG_PWC.raw == power_before and
                RTC.CLK_CONF.raw == clock_before and USB.CONF0.raw == usb_before and
                microzig.chip.peripherals.SYSTEM.SYSCLK_CONF.raw == sysclk_before;
        }
        timer_check(100, ticks100, 0x10, &results[1], &results[2]) catch |err| {
            results[1].err = err;
            results[2].err = err;
        };
        if (build_stage == 4) {
            timer_check(500, ticks500, 0x20, &results[3], &results[4]) catch |err| {
                results[3].err = err;
                results[4].err = err;
            };

            if (use_oled) progress(0x30);
            const gpio_before = sleep.rtc_ticks();
            const high_before = wake_pin.read() == 1;
            // Timer is a fallback: missing GPIO wake must terminate and FAIL.
            const cause = enter(.{
                .timer_ticks = ticks500,
                .gpio = .{ .pin = 0, .level = 1 },
            }, 0x30) catch |err| blk: {
                results[5].err = err;
                break :blk null;
            };
            const elapsed = sleep.rtc_ticks() -% gpio_before;
            resume_display();
            results[5].rtc = elapsed;
            if (cause) |woke| {
                results[5].cause = woke.raw;
                results[5].passed = high_before and wake_pin.read() == 1 and
                    woke.gpio and !woke.timer and elapsed < ticks100;
            }
        }
        const restored_before = sleep.rtc_ticks();
        hal.time.sleep_ms(20);
        const restored_ticks = sleep.rtc_ticks() -% restored_before;
        const expected = @as(u64, calibration_ticks) * 20000 / sys_us;
        results[8].rtc = restored_ticks;
        results[8].passed = microzig.chip.peripherals.SYSTEM.SYSCLK_CONF.raw == sysclk_before and
            microzig.chip.peripherals.SYSTEM.CPU_PER_CONF.raw == cpu_before and
            restored_ticks >= expected * 9 / 10 and restored_ticks <= expected * 11 / 10;
    }
    const slept = results[1].passed and (build_stage == 3 or results[3].passed);
    const output_matches = output_before and output.read() == 1;
    var ram_matches = true;
    for (0..128) |i| {
        if (ram[i] != 0xa5c30000 ^ @as(u32, @intCast(i * 7919))) ram_matches = false;
    }
    results[6].passed = slept and output_matches;
    results[7].passed = slept and ram_matches;

    progress(0x40);
    hal.wdt.Rtc.disable();
    RTC.OPTION1.modify(.{ .FORCE_DOWNLOAD_BOOT = 0 });
    report_sleep_diagnostics();
    beacon(if (output_matches) 0xb4 else 0xb5);
    beacon(if (ram_matches) 0xb6 else 0xb7);
    beacon(if (slept) 0xb8 else 0xb9);
    const usb = probe_usb();
    results[9].passed = usb.host_seen;
    results[10].passed = usb.cdc_in;
    usb_lost_note = !usb.cdc_in;
    progress(if (usb.host_seen and usb.cdc_in) 0x50 else 0x51);
    while (true) {
        report_sleep_diagnostics();
        beacon(if (output_matches) 0xb4 else 0xb5);
        beacon(if (ram_matches) 0xb6 else 0xb7);
        beacon(if (slept) 0xb8 else 0xb9);
        var pass: usize = 0;
        var fail: usize = 0;
        for (results, 0..) |result, i| {
            if (!counted(i)) continue;
            if (result.passed) pass += 1 else fail += 1;
        }
        counts(pass, fail);
        for (results, 0..) |result, i| {
            if (!counted(i)) continue;
            progress(@as(u8, if (result.passed) 0x70 else 0xa0) + @as(u8, @intCast(i)));
            report_delay(100);
        }
        finish(pass, fail);
        report_delay(1000);
    }
}

/// s3 omits the 500 ms and GPIO checks. In s3/s4, cdc_in (index 10) is not a
/// check: with allow_usb_loss the endpoints stay dead after wake by design
/// (README "C3 light sleep and USB-Serial-JTAG"); it is reported as a note.
fn counted(i: usize) bool {
    if (build_stage == 3 and i >= 3 and i <= 5) return false;
    return i != 10;
}

var usb_lost_note = false;

const UsbProbe = struct {
    frame_before: u32,
    frame_after: u32,
    wait_us: u64,
    host_seen: bool,
    cdc_in: bool,
};

fn probe_usb() UsbProbe {
    // Fresh post-wake/attach samples; a stale SOF interrupt cannot pass.
    // No IRQ enable/handler or W1C acknowledgement needed (§30.6 reg 30.8).
    const frame_before = USB.FRAM_NUM.read().SOF_FRAME_INDEX;
    const wait_start = hal.time.get_time_since_boot().to_us();
    progress(9);
    var frame_after = frame_before;
    while (hal.time.get_time_since_boot().to_us() -% wait_start < 10_000_000) {
        frame_after = USB.FRAM_NUM.read().SOF_FRAME_INDEX;
        if (frame_after != frame_before) break;
        heartbeat();
    }
    const host_seen = frame_after != frame_before;
    const wait_us = hal.time.get_time_since_boot().to_us() -% wait_start;
    progress(if (host_seen) 0x0a else 0x0b);
    report_delay(1500);
    progress(0x0f);
    // A flushed short packet keeps the IN FIFO busy until the host controller
    // reads it over USB (§30.3.2). Passing shows USB-level consumption, not
    // that a host application read the bytes. SOFs or initial FIFO capacity
    // alone cannot pass this check.
    const cdc_start = hal.time.get_time_since_boot().to_us();
    var cdc_in = false;
    var queued = false;
    while (hal.time.get_time_since_boot().to_us() -% cdc_start < 10_000_000) {
        heartbeat();
        if (hal.usb_serial_jtag.tx_fifo_full()) continue;
        if (!queued) {
            for ("USJ IN probe\r\n") |byte| hal.usb_serial_jtag.tx_fifo_write(byte);
            hal.usb_serial_jtag.tx_fifo_flush();
            queued = true;
            continue;
        }
        cdc_in = true;
        break;
    }
    return .{ .frame_before = frame_before, .frame_after = frame_after, .wait_us = wait_us, .host_seen = host_seen, .cdc_in = cdc_in };
}

fn report_simple(comptime name: []const u8, passed: bool, elapsed_us: u64, reset_cause: u6) noreturn {
    if (build_stage >= 2) RTC.OPTION1.modify(.{ .FORCE_DOWNLOAD_BOOT = 0 });
    report_delay(1500);
    while (true) {
        finish(@intFromBool(passed), @intFromBool(!passed));
        std.log.info("SELFTEST sleep_s{d} " ++ name ++ ": {s} elapsed_us={d} reset_cause=0x{x}", .{ build_stage, if (passed) "PASS" else "FAIL", elapsed_us, reset_cause });
        if (use_oled) std.log.info("SELFTEST sleep_s{d} display: {s}", .{ build_stage, if (display_failed) "FAIL" else "PASS" });
        std.log.info("SELFTEST sleep_s{d} DONE pass={d} fail={d}", .{ build_stage, display_pass, display_fail });
        progress(0x60);
        report_delay(1000);
    }
}

fn stage_one(reset_cause: u6) noreturn {
    const before = hal.systimer.unit(0).read();
    const conf_before = USB.CONF0.read();
    var conf_detached = conf_before;
    var hold_us: u64 = 0;
    if (build_stage == 5) {
        progress(3);
        progress(0x0c);
        const connection = hal.usb_serial_jtag.Reenumeration.detach_and_reset();
        progress(0x0d);
        conf_detached = USB.CONF0.read();
        progress(4);
        const hold_start = hal.systimer.unit(0).read();
        report_delay(1000);
        hold_us = (hal.systimer.unit(0).read() -% hold_start) / 16;
        progress(0x0e);
        connection.attach();
        progress(5);
    } else {
        // Control: no writes to USB configuration, even a write of its old value.
        report_delay(1000);
    }
    const conf_attached = USB.CONF0.read();
    const elapsed_us = (hal.systimer.unit(0).read() -% before) / 16;
    const pads_ok = conf_before.USB_PAD_ENABLE == 1 and
        @as(u32, @bitCast(conf_attached)) == @as(u32, @bitCast(conf_before)) and
        if (build_stage == 5)
            conf_detached.USB_PAD_ENABLE == 0 and conf_detached.PAD_PULL_OVERRIDE == 1 and
                conf_detached.DP_PULLUP == 0 and conf_detached.DM_PULLUP == 0 and
                hold_us >= 1_000_000 and hold_us < 1_100_000
        else
            elapsed_us >= 1_000_000 and elapsed_us < 1_100_000;

    const usb = probe_usb();
    // Stage 5 requires a known OUT payload; absence and wrong data both FAIL.
    // Do not accept any FIFO availability bit as proof of the expected bytes.
    var cdc_out = false;
    if (build_stage == 5) {
        const expected = "USJ?";
        var matched: usize = 0;
        const rx_start = hal.time.get_time_since_boot().to_us();
        while (hal.time.get_time_since_boot().to_us() -% rx_start < 10_000_000) {
            heartbeat();
            if (!hal.usb_serial_jtag.rx_fifo_available()) continue;
            const byte = hal.usb_serial_jtag.rx_fifo_read();
            if (byte != expected[matched]) break;
            matched += 1;
            if (matched == expected.len) {
                cdc_out = true;
                break;
            }
        }
    }
    progress(if (usb.cdc_in and (build_stage == 1 or cdc_out)) 0x61 else 0x62);
    const pass = @as(u3, @intFromBool(pads_ok)) + @intFromBool(usb.host_seen) +
        @intFromBool(usb.cdc_in) + @as(u3, if (build_stage == 5) @intFromBool(cdc_out) else 0);
    const count: u3 = if (build_stage == 5) 4 else 3;
    while (true) {
        finish(pass, count - pass);
        std.log.info("SELFTEST sleep_s{d} {s}: {s} elapsed_us={d} hold_us={d} reset_cause=0x{x}", .{ build_stage, if (build_stage == 5) "detach_attach" else "keep_attached", if (pads_ok) "PASS" else "FAIL", elapsed_us, hold_us, reset_cause });
        std.log.info("SELFTEST sleep_s{d} host_sof: {s} wait_us={d} frame_before={d} frame_after={d}", .{ build_stage, if (usb.host_seen) "PASS" else "FAIL", usb.wait_us, usb.frame_before, usb.frame_after });
        std.log.info("SELFTEST sleep_s{d} cdc_in: {s} usb_level_consumed_probe={}", .{ build_stage, if (usb.cdc_in) "PASS" else "FAIL", usb.cdc_in });
        if (build_stage == 5) std.log.info("SELFTEST sleep_s5 cdc_out: {s} expected=USJ?", .{if (cdc_out) "PASS" else "FAIL"});
        std.log.info("SELFTEST sleep_s{d} pads: conf0_before=0x{x} detached=0x{x} attached=0x{x} rtc_usb_conf=0x{x} dig_pad_hold=0x{x}", .{
            build_stage,
            @as(u32, @bitCast(conf_before)),
            @as(u32, @bitCast(conf_detached)),
            @as(u32, @bitCast(conf_attached)),
            RTC.USB_CONF.raw,
            RTC.DIG_PAD_HOLD.raw,
        });
        if (use_oled) std.log.info("SELFTEST sleep_s{d} display: {s}", .{ build_stage, if (display_failed) "FAIL" else "PASS" });
        std.log.info("SELFTEST sleep_s{d} DONE pass={d} fail={d}", .{ build_stage, display_pass, display_fail });
        report_delay(1000);
    }
}

// Waits <=10 s for `expected` in the OUT stream; other bytes restart the match.
fn receive(comptime expected: []const u8) bool {
    const usj = hal.usb_serial_jtag;
    const start = hal.time.get_time_since_boot().to_us();
    var matched: usize = 0;
    while (hal.time.get_time_since_boot().to_us() -% start < 10_000_000) {
        heartbeat();
        if (!usj.rx_fifo_available()) continue;
        const byte = usj.rx_fifo_read();
        matched = if (byte == expected[matched]) matched + 1 else @intFromBool(byte == expected[0]);
        if (matched == expected.len) return true;
    }
    return false;
}

// Sends `line` (again each second once the host has consumed the previous
// copy) and waits <=10 s for `expected` in the OUT stream.
fn exchange(line: []const u8, expected: []const u8) bool {
    const usj = hal.usb_serial_jtag;
    const start = hal.time.get_time_since_boot().to_us();
    var sent_us: ?u64 = null;
    var matched: usize = 0;
    while (true) {
        const now = hal.time.get_time_since_boot().to_us();
        if (now -% start >= 10_000_000) return false;
        heartbeat();
        const due = if (sent_us) |sent| now -% sent >= 1_000_000 else true;
        if (due and !usj.tx_fifo_full()) {
            for (line) |byte| usj.tx_fifo_write(byte);
            usj.tx_fifo_flush();
            sent_us = now;
        }
        if (!usj.rx_fifo_available()) continue;
        const byte = usj.rx_fifo_read();
        matched = if (byte == expected[matched]) matched + 1 else @intFromBool(byte == expected[0]);
        if (matched == expected.len) return true;
    }
}

// No logger calls while checking endpoint traffic: only the nonce may be queued.
fn stage_six() noreturn {
    const usj = hal.usb_serial_jtag;
    var results = [_]Result{
        .{ .name = "reconnect_operation" }, .{ .name = "reconnect_bus_reset" },
        .{ .name = "reconnect_cdc_in" },    .{ .name = "reconnect_cdc_out" },
        .{ .name = "100ms_operation" },     .{ .name = "100ms_bus_reset" },
        .{ .name = "100ms_cdc_in" },        .{ .name = "100ms_cdc_out" },
        .{ .name = "500ms_operation" },     .{ .name = "500ms_bus_reset" },
        .{ .name = "500ms_cdc_in" },        .{ .name = "500ms_cdc_out" },
    };
    hal.systimer.unit(1).apply(.disabled_if_cpu_stalled);
    const rtc_start = sleep.rtc_ticks();
    const sys_start = hal.time.get_time_since_boot().to_us();
    report_delay(50);
    const sys_us = hal.time.get_time_since_boot().to_us() -% sys_start;
    const rtc_elapsed = sleep.rtc_ticks() -% rtc_start;
    const calibrated = rtc_elapsed > 0 and sys_us >= 50_000 and sys_us < 60_000;
    // One history for the whole run: a host still re-enumerating from the
    // previous phase keeps its bus reset wait.
    var attachment: usj.Attachment = .{};
    const reattach: usj.ReattachOptions = .{ .attachment = &attachment };
    // A host still in its attach debounce after boot sends no SOF; without
    // this the first phase could count no host (usj.Attachment).
    const host_wait_start = hal.time.get_time_since_boot().to_us();
    const host_seen = usj.wait_for_host(.from_ms(2000), &attachment);
    const host_wait_us = hal.time.get_time_since_boot().to_us() -% host_wait_start;
    for ([_]u32{ 0, 100, 500 }, 0..) |ms, phase| {
        const base = phase * 4;
        progress(0xe0 + @as(u8, @intCast(phase)));
        // Bytes from an earlier connection must not satisfy this phase's checks.
        while (usj.rx_fifo_available()) _ = usj.rx_fifo_read();
        const conf_before = USB.CONF0.raw;
        const interrupts_before = USB.INT_ENA.raw;
        if (ms == 0) {
            results[base + 1].passed = usj.reconnect(reattach) orelse false;
            results[base].passed = true;
        } else if (calibrated) {
            const ticks: u48 = @intCast(@as(u64, rtc_elapsed) * ms * 1000 / sys_us);
            arm_watchdog(@intCast(@as(u64, rtc_elapsed) * 1_000_000 / sys_us), true);
            var diagnostics: sleep.Diagnostics = .{};
            const before_rtc = sleep.rtc_ticks();
            const before_active = hal.systimer.unit(1).read();
            if (use_oled) display_deferred = true;
            const cause = sleep.enter_light_sleep(.{
                .timer_ticks = ticks,
                .usb_policy = .disconnect_and_reenumerate,
                .usb_reattach = reattach,
                .diagnostics = &diagnostics,
                .trace = trace,
            }) catch |err| failed: {
                results[base].err = err;
                break :failed null;
            };
            const active_us = (hal.systimer.unit(1).read() -% before_active) / 16;
            const elapsed_us = @as(u64, sleep.rtc_ticks() -% before_rtc) * sys_us / rtc_elapsed;
            resume_display();
            hal.wdt.Rtc.disable();
            RTC.OPTION1.modify(.{ .FORCE_DOWNLOAD_BOOT = 0 });
            // Independent RTC versus CPU-stall-sensitive UNIT1 distinguishes
            // actual sleep from an awake delay (C3 TRM v1.4 §§9.3.3, 10.2).
            const stalled_us = elapsed_us -| active_us;
            results[base].active_us = stalled_us;
            results[base].passed = if (cause) |wake| wake.timer and !wake.gpio and
                stalled_us >= @as(u64, ms) * 900 and stalled_us <= @as(u64, ms) * 1100 else false;
            results[base + 1].passed = diagnostics.usb_bus_reset orelse false;
        }
        // A "USJ?" that arrived after the first drain and before the detach
        // (e.g. during the SOF sampling) may have survived the detach; it
        // must not satisfy this phase's cdc_out.
        while (usj.rx_fifo_available()) _ = usj.rx_fifo_read();
        results[base].passed = results[base].passed and USB.CONF0.raw == conf_before and
            USB.INT_ENA.raw == interrupts_before;
        // OUT: the exact string, matched anywhere in what arrives.
        progress(0xe4);
        results[base + 3].passed = receive("USJ?");
        // IN: only a host that read this phase's nonce can echo it back.
        progress(0xe3);
        var nonce_line: [24]u8 = undefined;
        var ack: [12]u8 = undefined;
        const nonce = hal.rng.random_u32();
        const line = std.mem.print(&nonce_line, "USJ nonce={x:0>8}\r\n", .{nonce}) catch unreachable;
        const expected_ack = std.mem.print(&ack, "ACK {x:0>8}", .{nonce}) catch unreachable;
        results[base + 2].nonce = nonce;
        results[base + 2].passed = exchange(line, expected_ack);
        var completed_pass: usize = 0;
        for (results[0 .. base + 4]) |result| completed_pass += @intFromBool(result.passed);
        counts(completed_pass, base + 4 - completed_pass);
        // Report the completed phase on the beacon before the next detach; a
        // stale nonce left in the IN FIFO cannot match the next phase's ACK.
        for (results[base..][0..4], base..) |result, i|
            beacon(@as(u8, if (result.passed) 0x70 else 0xa0) + @as(u8, @intCast(i)));
    }
    report_delay(1500);
    while (true) {
        std.log.info("SELFTEST sleep_s6 info wait_for_host host_seen={} wait_us={d}", .{ host_seen, host_wait_us });
        var pass: usize = 0;
        for (results, 0..) |result, i| {
            beacon(@as(u8, if (result.passed) 0x70 else 0xa0) + @as(u8, @intCast(i)));
            pass += @intFromBool(result.passed);
            std.log.info("SELFTEST sleep_s6 {s}: {s} stalled_us={d} nonce={x:0>8} error={s}", .{
                result.name,  if (result.passed) "PASS" else "FAIL",             result.active_us,
                result.nonce, if (result.err) |err| @errorName(err) else "none",
            });
        }
        finish(pass, results.len - pass);
        if (use_oled) std.log.info("SELFTEST sleep_s6 display: {s}", .{if (display_failed) "FAIL" else "PASS"});
        std.log.info("SELFTEST sleep_s6 DONE pass={d} fail={d}", .{ display_pass, display_fail });
        report_delay(1000);
    }
}
