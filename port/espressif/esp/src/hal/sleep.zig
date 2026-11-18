//! ESP32-C3 retained-CPU light sleep (TRM v1.4 §§9.3, 9.4, 9.5).
//! Quiesce peripherals before entering; interrupts are masked until clocks are restored.
//! CPU, SRAM, flash supply and digital peripherals remain powered. XTAL and PLL
//! remain powered too, trading power savings for avoiding oscillator startup and
//! flash power sequencing. The RTC FSM gates clocks and stalls the CPU.
//! USB Serial/JTAG cannot be kept working by this sleep mode (TRM v1.4 §30.4).
//! Entry with enabled USB pads is rejected unless USB loss or re-enumeration is selected.
//! Reopening the port may not recover it; physical disconnect/reset may be needed.
//! Use an RTC watchdog to bound a failed wakeup.
//! SYSTIMER-based time may pause; this API does not adjust counters or alarms.
//!
//! Clock/power audit (C3 TRM v1.4): DIG_PWC retains DG_WRAP, CPU_TOP,
//! DG_PERI and SRAM (§9.8 reg 9.29); OPTIONS0 retains XTAL/BBPLL (reg 9.1).
//! CLK_CONF bypasses XTAL gating (reg 9.25), not the sleep FSM's APB/USB
//! PHY clock gates (§30.4). SYSCLK_CONF selects undivided 40 MHz XTAL while
//! awake (§16.3.1, reg 16.10). SYSTEM.PERIP_CLK_EN0.USB_DEVICE_CLK_EN is
//! enabled by system.init; EN1 has no USB_DEVICE control (§16.3.5, §16.4).
//! Neither that enable nor USB.MISC_CONF.CLK_EN (register access force-on,
//! §30.6 reg 30.4) guarantees a running APB or 48 MHz PHY clock in sleep.
//! DIG_ISO is untouched: DG_PAD_FORCE_NOISO concerns pad isolation, not
//! clocks (§9.8 reg 9.30). Forcing it cannot establish USB clock continuity.
//!
//! ESP-IDF v5.4.2 references (https://github.com/espressif/esp-idf/tree/v5.4.2):
//! components/soc/esp32c3/include/soc/soc_caps.h has no
//! SOC_USB_SERIAL_JTAG_SUPPORT_LIGHT_SLEEP. components/esp_hw_support/
//! sleep_modes.c calls sleep_console.c pad disable/restore on such chips;
//! this avoids leakage, not endpoint loss. port/esp32c3/rtc_sleep.c retains
//! XTAL when requested but does not implement USB keepalive. components/hal/
//! esp32c3/include/hal/usb_serial_jtag_ll.h enables the bus via EN0 and
//! declares PHY_DEPENDS_ON_BBPLL. docs/en/api-guides/usb-serial-jtag-console.rst,
//! "Light-sleep", documents gated APB/PHY clocks and possible failure to
//! reconnect. CONFIG_USJ_NO_AUTO_LS_ON_CONNECTION prevents automatic sleep
//! while connected; it does not preserve USB during manual sleep.
const microzig = @import("microzig");
const compatibility = @import("compatibility.zig");
const rom = @import("rom.zig");
const RTC = microzig.chip.peripherals.RTC_CNTL;
const SYSTEM = microzig.chip.peripherals.SYSTEM;
const GPIO = microzig.chip.peripherals.GPIO;
const usb_serial_jtag = @import("usb_serial_jtag.zig");
const USB = microzig.chip.peripherals.USB_DEVICE;

comptime {
    compatibility.require_esp32_c3("light sleep");
}

pub const GpioWake = struct {
    pin: u5,
    level: u1,
};

/// Diagnostic milestones, emitted before the next potentially blocking operation.
pub const Step = enum(u8) {
    saved = 0x80,
    usb = 0x81,
    power = 0x82,
    clocks = 0x83,
    bias = 0x84,
    cpu_clock = 0x85,
    gpio = 0x86,
    timer = 0x87,
    request = 0x88,
    woke = 0x89,
    restored = 0x8a,
    read_dig_bias = 0x8b,
    write_rtc_bias = 0x8c,
    write_dig_bias = 0x8d,
    restore_dig_bias = 0x8e,
    restore_rtc_bias = 0x8f,
    restore_cpu_clock = 0x90,
    restore_power = 0x91,
    restore_usb = 0x92,
};

pub const UsbPolicy = enum {
    /// Keep the existing allow_usb_loss behavior (reject active USB by default).
    unchanged,
    /// Discard pending transfers, detach for >=10 ms, reattach after clocks return.
    /// Host must reopen its port. Diagnostics.usb_bus_reset reports the bounded
    /// reset wait (Config.usb_reattach), also on sleep errors; it stays null and
    /// nothing waits when the pads were disabled or no host was counted before
    /// detach (usb_serial_jtag.Disconnect.begin): no SOFs, no pending bus reset
    /// and, with a Config.usb_reattach.attachment handle, no reset seen by an
    /// earlier wait since the last timeout. With the handle, a host still
    /// re-enumerating from the previous sleep still gets its wait, and an
    /// unplugged host costs one timeout. Without it, back-to-back sleeps keep
    /// their wait only while the bus reset stays latched in INT_RAW: once an
    /// application USB interrupt handler clears USB_BUS_RESET, or one sleep
    /// skips its wait, every later one skips. The first sleep after power-up or
    /// attach counts no host that is still debouncing the attach; call
    /// usb_serial_jtag.wait_for_host with the same handle before sleeping
    /// back-to-back (usb_serial_jtag.Attachment).
    /// No CDC success is implied.
    disconnect_and_reenumerate,
};

pub const Config = struct {
    usb_policy: UsbPolicy = .unchanged,
    /// Bus reset wait and caller-owned attachment history for
    /// .disconnect_and_reenumerate; pass the same .attachment to every sleep.
    usb_reattach: usb_serial_jtag.ReattachOptions = .{},
    /// Accept loss of USB CDC/JTAG, including after wakeup (§30.4).
    /// No pad toggle/reset is attempted: neither guarantees host recovery.
    /// Use an independent reporting/recovery path when opting in.
    allow_usb_loss: bool = false,
    /// Optional diagnostic trace with interrupts masked. Keep it bounded; no
    /// logging or waits on sleep-affected peripherals. GPIO beacons may use
    /// SYSTIMER unit 0, which must keep counting while the CPU runs.
    trace: ?*const fn (Step) void = null,
    /// Captured before acknowledging a wake/reject, including on Rejected or
    /// Timeout. Zero on errors detected before requesting sleep.
    diagnostics: ?*Diagnostics = null,

    /// Relative RTC_SLOW_CLK ticks, 1 .. 2^47-1. Calibrate the slow clock
    /// against an independent clock when a wall-clock duration is required.
    timer_ticks: ?u48 = null,
    /// Configure the pad's input, pull and SLP_SEL before calling. No edge is
    /// required: a level already asserted can wake the chip (§5.10.1, §9.4.3).
    gpio: ?GpioWake = null,

    fn mark(self: Config, step: Step) void {
        if (self.trace) |trace| trace(step);
    }
};

/// Multiple enabled sources can assert together; preserve both cause bits.
pub const WakeCause = struct {
    timer: bool,
    gpio: bool,
    raw: u17,
};

pub const Diagnostics = struct {
    wake: u17 = 0,
    reject: u18 = 0,
    interrupt_raw: u32 = 0,
    /// null when no bus reset wait ran (see UsbPolicy.disconnect_and_reenumerate).
    usb_bus_reset: ?bool = null,
};

pub const Error = error{ InvalidTimer, TimerExpired, InvalidPin, NoWakeSource, UnsupportedClock, UsbSerialJtagActive, Rejected, Timeout };

/// Latch the free-running 48-bit RTC timer (§9.3.3, registers 9.4–9.6).
/// Interrupt exclusion prevents another caller from replacing the snapshot.
pub fn rtc_ticks() u48 {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    RTC.TIME_UPDATE.modify(.{ .RTC_TIME_UPDATE = 1 });
    // Allow the APB-to-RTC register bridge to transfer the sample before reading.
    // RTC registers use RTC_FAST_CLK, not the much slower RTC_SLOW_CLK (§9.3.2).
    rom.delay_us(10);
    return (@as(u48, RTC.TIME_HIGH0.read().RTC_TIMER_VALUE0_HIGH) << 32) |
        RTC.TIME_LOW0.read().RTC_TIMER_VALUE0_LOW;
}

/// Enter light sleep and resume here. GPIO-only sleep deliberately has no sleep
/// deadline; supply a timer as well when a fallback wakeup is needed. Timeout
/// bounds active polling if the FSM fails to stall the CPU, not time asleep.
/// Consumes the RTC sleep timer and sleep/wakeup flags; do not share them with
/// another sleep manager. TimerExpired means the deadline was too close to enter.
/// UsbSerialJtagActive rejects enabled pads before any sleep configuration write;
/// enabled pads are a conservative proxy, not proof of a listening host.
pub fn enter_light_sleep(config: Config) Error!WakeCause {
    if (config.diagnostics) |diagnostics| diagnostics.* = .{};
    if (config.timer_ticks) |ticks| {
        if (ticks == 0 or ticks >= (@as(u48, 1) << 47)) return error.InvalidTimer;
    }
    if (config.gpio) |gpio| {
        if (gpio.pin >= 22) return error.InvalidPin;
    }
    if (config.timer_ticks == null and config.gpio == null) return error.NoWakeSource;

    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();

    if (config.usb_policy == .unchanged and !config.allow_usb_loss and USB.CONF0.read().USB_PAD_ENABLE == 1)
        return error.UsbSerialJtagActive;

    const sysclk = SYSTEM.SYSCLK_CONF.read();
    if (sysclk.SOC_CLK_SEL > 1) return error.UnsupportedClock;
    const cpu_mhz: u32 = if (sysclk.SOC_CLK_SEL == 0)
        (40_000_000 / (@as(u32, sysclk.PRE_DIV_CNT) + 1)) / 1_000_000
    else if (SYSTEM.CPU_PER_CONF.read().CPUPERIOD_SEL == 0) 80 else 160;
    const disconnected = if (config.usb_policy == .disconnect_and_reenumerate)
        usb_serial_jtag.Disconnect.begin(config.usb_reattach)
    else
        null;
    // Registered before clock/power restoration defers: reconnect runs last,
    // while the critical section still excludes the logger and USB ISR.
    defer if (disconnected) |connection| {
        config.mark(.restore_usb);
        const reset_seen = connection.finish();
        if (config.diagnostics) |diagnostics| diagnostics.usb_bus_reset = reset_seen;
    };
    const options = RTC.OPTIONS0.read();
    const power = RTC.DIG_PWC.read();
    const timer1 = RTC.TIMER1.read();
    const reject = RTC.SLP_REJECT_CONF.read();
    const wake = RTC.WAKEUP_STATE.read();
    const clock = RTC.CLK_CONF.read();
    const regulator = RTC.RTC_CNTL.read();
    const bias = RTC.BIAS_CONF.read();
    const sdio = RTC.SDIO_CONF.read();
    config.mark(.saved);
    defer config.mark(.restored);
    config.mark(.usb);
    defer RTC.SDIO_CONF.write(sdio);
    defer RTC.BIAS_CONF.write(bias);
    defer RTC.RTC_CNTL.write(regulator);
    defer RTC.CLK_CONF.write(clock);
    defer RTC.WAKEUP_STATE.write(wake);
    defer RTC.SLP_REJECT_CONF.write(reject);
    defer RTC.TIMER1.write(timer1);
    defer {
        config.mark(.restore_power);
        RTC.DIG_PWC.write(power);
    }
    defer RTC.OPTIONS0.write(options);
    defer {
        config.mark(.restore_cpu_clock);
        SYSTEM.SYSCLK_CONF.write(sysclk);
        rom.functions.ets_update_cpu_frequency(cpu_mhz);
    }

    // §9.4.2/Table 9.4-1 and §9.5: retain CPU context without retention DMA.
    config.mark(.power);
    RTC.DIG_PWC.modify(.{
        .DG_WRAP_PD_EN = 0,
        .CPU_TOP_PD_EN = 0,
        .DG_PERI_PD_EN = 0,
        .DG_WRAP_FORCE_PD = 0,
        .CPU_TOP_FORCE_PD = 0,
        .DG_PERI_FORCE_PD = 0,
        .DG_WRAP_FORCE_PU = 1,
        .CPU_TOP_FORCE_PU = 1,
        .DG_PERI_FORCE_PU = 1,
        .LSLP_MEM_FORCE_PD = 0,
        .LSLP_MEM_FORCE_PU = 1,
        .RTC_FASTMEM_FORCE_LPD = 0,
        .RTC_FASTMEM_FORCE_LPU = 1,
    });
    // §9.3.4 and registers 9.25, 9.27, 9.29. Retention is needed for the
    // flashless image's IRAM instructions and DRAM stack/data, not just cache.
    // ESP-IDF esp32c3/rtc_sleep.c, rtc_sleep_init, explicitly sets these too.
    config.mark(.clocks);
    RTC.RTC_CNTL.modify(.{ .REGULATOR_FORCE_PD = 0, .REGULATOR_FORCE_PU = 1 });
    RTC.CLK_CONF.modify(.{
        .XTAL_GLOBAL_FORCE_GATING = 0,
        .XTAL_GLOBAL_FORCE_NOGATING = 1,
        .XTAL_FORCE_NOGATING = 1,
        .CK8M_FORCE_PD = 0,
        .CK8M_FORCE_PU = 1,
        .CK8M_FORCE_NOGATING = 1,
    });
    RTC.SDIO_CONF.modify(.{ .SDIO_REG_PD_EN = 0 });
    // Keeping XTAL alive requires the full-voltage sleep configuration, not
    // ROM's reset defaults. The analog fields are not described in the TRM:
    // ESP-IDF esp32c3 rtc_sleep_get_default_config(!RTC_SLEEP_PD_XTAL),
    // rtc_sleep_init and soc/regi2c_dig_reg.h define these as 1.10 V (code 23).
    config.mark(.bias);
    const rtc_sleep_bias = rom.functions.esp_rom_regi2c_read_mask(0x6d, 0, 5, 4, 0);
    config.mark(.read_dig_bias);
    const dig_sleep_bias = rom.functions.esp_rom_regi2c_read_mask(0x6d, 0, 7, 4, 0);
    config.mark(.write_rtc_bias);
    rom.functions.esp_rom_regi2c_write_mask(0x6d, 0, 5, 4, 0, 23);
    config.mark(.write_dig_bias);
    rom.functions.esp_rom_regi2c_write_mask(0x6d, 0, 7, 4, 0, 23);
    defer {
        config.mark(.restore_rtc_bias);
        rom.functions.esp_rom_regi2c_write_mask(0x6d, 0, 5, 4, 0, rtc_sleep_bias);
    }
    defer {
        config.mark(.restore_dig_bias);
        rom.functions.esp_rom_regi2c_write_mask(0x6d, 0, 7, 4, 0, dig_sleep_bias);
    }
    RTC.BIAS_CONF.modify(.{
        .DBG_ATTEN_DEEP_SLP = 0,
        .BIAS_SLEEP_DEEP_SLP = 0,
        .PD_CUR_DEEP_SLP = 0,
        .DG_VDD_DRV_B_SLP_EN = 1,
        .DG_VDD_DRV_B_SLP = 254,
    });
    // §9.3/Fig.9.3-1, register 9.1: leave clock sources powered. Execute on
    // XTAL during the transition and restore the exact previous source/divider.
    config.mark(.cpu_clock);
    RTC.OPTIONS0.modify(.{
        .XTL_FORCE_PD = 0,
        .XTL_FORCE_PU = 1,
        .BBPLL_FORCE_PD = 0,
        .BBPLL_FORCE_PU = 1,
    });
    SYSTEM.SYSCLK_CONF.modify(.{ .PRE_DIV_CNT = 0 });
    SYSTEM.SYSCLK_CONF.modify(.{ .SOC_CLK_SEL = 0 });
    rom.functions.ets_update_cpu_frequency(40);
    RTC.TIMER1.modify(.{ .CPU_STALL_EN = 1 });
    // An already-held GPIO level must wake rather than reject (§9.4.4).
    RTC.SLP_REJECT_CONF.write(.{});

    // Own all GPIO wake enables during this call so an old pin cannot wake us.
    config.mark(.gpio);
    var pins: [22]@TypeOf(GPIO.PIN[0].read()) = undefined;
    for (&pins, 0..) |*saved, index| {
        saved.* = GPIO.PIN[index].read();
        GPIO.PIN[index].modify(.{ .PIN_WAKEUP_ENABLE = 0 });
    }
    defer for (pins, 0..) |saved, index| {
        GPIO.PIN[index].write(saved);
    };
    if (config.gpio) |gpio| {
        GPIO.PIN[gpio.pin].modify(.{
            .PIN_INT_TYPE = @as(u3, if (gpio.level == 1) 5 else 4),
            .PIN_WAKEUP_ENABLE = 1,
        });
    }

    // §9.4.3/Table 9.4-2: GPIO=0x4, RTC timer=0x8.
    config.mark(.timer);
    RTC.WAKEUP_STATE.write(.{ .RTC_WAKEUP_ENA = @as(u17, if (config.gpio != null) 4 else 0) |
        @as(u17, if (config.timer_ticks != null) 8 else 0) });
    if (config.timer_ticks) |ticks| {
        const target = rtc_ticks() +% ticks;
        RTC.SLP_TIMER0.write(.{ .SLP_VAL_LO = @truncate(target) });
        RTC.SLP_TIMER1.write(.{ .SLP_VAL_HI = @truncate(target >> 32) });
        // TRM v1.4 §9.8 regs 9.3, 9.14, 9.17: the main timer event
        // (bit 10) is distinct from the sleep-wakeup event (bit 0).
        // Acknowledging only sleep-wakeup leaves the previous alarm latched,
        // so subsequent sleeps can wake immediately. Match ESP-IDF's
        // rtc_timer_ll_set_wakeup_time: target, clear MAIN_TIMER, then arm.
        // ALARM_EN is a WO command, not a readable enable to save/restore;
        // writing a zero target on return does not acknowledge the event.
        RTC.INT_CLR_RTC.write(.{ .RTC_MAIN_TIMER_INT_CLR = 1 });
        RTC.SLP_TIMER1.write(.{
            .SLP_VAL_HI = @truncate(target >> 32),
            .RTC_MAIN_TIMER_ALARM_EN = 1,
        });
        // Do not enter with a deadline already passed: the one-shot alarm may
        // have fired before the sleep request and cannot provide a future wake.
        const remaining = target -% rtc_ticks();
        if (remaining < 4 or remaining >= (@as(u48, 1) << 47)) return error.TimerExpired;
    }

    // Registers 9.7 and 9.17: clear only the owned W1C flags, then request
    // sleep. No WFI: the RTC FSM itself stalls and releases the CPU.
    RTC.INT_CLR_RTC.write(.{ .SLP_WAKEUP_INT_CLR = 1, .SLP_REJECT_INT_CLR = 1 });
    defer RTC.INT_CLR_RTC.write(.{ .SLP_WAKEUP_INT_CLR = 1, .SLP_REJECT_INT_CLR = 1 });
    config.mark(.request);
    RTC.STATE0.modify(.{ .RTC_SLP_REJECT_CAUSE_CLR = 1, .SLEEP_EN = 1 });
    defer RTC.STATE0.modify(.{ .SLEEP_EN = 0 });
    // Runs before the interrupt-clear defer, preserving evidence on all
    // requested-sleep paths. Cause registers are RO (§9.8 regs 9.54, 9.56).
    defer if (config.diagnostics) |diagnostics| {
        diagnostics.* = .{
            .wake = RTC.SLP_WAKEUP_CAUSE.read().WAKEUP_CAUSE,
            .reject = RTC.SLP_REJECT_CAUSE.read().REJECT_CAUSE,
            .interrupt_raw = RTC.INT_RAW_RTC.raw,
        };
    };
    for (0..1_000_000) |_| {
        const status = RTC.INT_RAW_RTC.read();
        if (status.SLP_REJECT_INT_RAW == 1) return error.Rejected;
        if (status.SLP_WAKEUP_INT_RAW == 1) {
            config.mark(.woke);
            const cause = RTC.SLP_WAKEUP_CAUSE.read().WAKEUP_CAUSE;
            return .{ .timer = cause & 8 != 0, .gpio = cause & 4 != 0, .raw = cause };
        }
    }
    return error.Timeout;
}
