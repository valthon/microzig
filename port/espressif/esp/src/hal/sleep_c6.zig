//! ESP32-C6 sleep. ESP-IDF v5.5.1 sleep_modes.c:978–1162,
//! esp_hw_support/port/esp32c6/{pmu_init,pmu_sleep,pmu_param,rtc_clk}.c.
//! TRM v1.2 §§12.4.2.1–7,12.10.1–3. Hardware results: port README.
//! Light sleep retains CPU, HP SRAM and TOP: no peripheral retention DMA.
//! Deep defaults power down flash and unused LP domains; radios must be off.
//! CPU switches to XTAL; PMU powers down PLL, then software recalibrates it.
//! Deep sleep drops HP digital domains and returns through ROM.
//! SYSTIMER time is not compensated. Quiesce DMA and peripherals first.
const microzig = @import("microzig");
const p = microzig.chip.peripherals;
const pmu = p.PMU;
const timer = p.LP_TIMER;
const aon = p.LP_AON;
const lp_pad_names = .{ "GPIO0", "GPIO1", "GPIO2", "GPIO3", "GPIO4", "GPIO5", "GPIO6", "GPIO7" };
const usb = @import("usb_serial_jtag.zig");
const analog = @import("analog/esp32_c6.zig");

const setup = @import("pmu_c6.zig");
const sleep_clock = @import("clocks/sleep_c6.zig");
const pmu_analog = @import("pmu_analog_c6.zig");
const wdt = @import("wdt.zig");

// First-sleep initialization is serialized by the enclosing critical section.
// No application or LP firmware may subsequently reconfigure these PMU tables.
var initialized = false;
pub const milestone_address = setup.milestone_address;

pub const GpioWake = struct { pin: u5, level: u1 };
/// EXT1-style OR of selected LP GPIO0–7, with independent high/low levels.
/// Selected pads must not already be held. Sleep owns their input configuration
/// until return, or until default HAL startup releases them after reset.
pub const Ext1Wake = struct { pins: u8, levels: u8 };
pub const UsbPolicy = enum { unchanged, disconnect_and_reenumerate };
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
    restore_power = 0x91,
    restore_usb = 0x92,
};
pub const Config = struct {
    usb_policy: UsbPolicy = .unchanged,
    usb_reattach: usb.ReattachOptions = .{},
    allow_usb_loss: bool = false,
    /// Bench-only reset recovery, including while asleep; requires timer_ticks.
    /// Default off preserves IDF pause-in-sleep behaviour.
    bench_recovery: bool = false,
    /// Light sleep only: default keeps XTAL for existing LP peripheral users.
    /// XTAL-off requires LP_FAST=RC_FAST and quiescent XTAL-clocked clients.
    power_down_xtal: bool = false,
    /// Bench-only reset deadline in slow ticks, with a later LP timer fallback.
    bench_reset_ticks: ?u48 = null,
    trace: ?*const fn (Step) void = null,
    diagnostics: ?*Diagnostics = null,
    /// Relative LP_SLOW_CLK ticks, 1 .. 2^47-1; calibrate for wall-clock time.
    timer_ticks: ?u48 = null,
    /// LP GPIO0–7 only. Caller configures LP mux, input and pull with lp_io.
    gpio: ?GpioWake = null,
    /// Mutually exclusive with gpio; caller configures all selected LP inputs.
    ext1: ?Ext1Wake = null,
    /// Light sleep only. Configure UARTx.SLEEP_CONF2 first with WK_MODE_SEL=0
    /// and ACTIVE_THRESHOLD (wake at threshold+3 rising edges, TRM §27.4.8).
    /// Trigger bytes are lost. After wake, transmit data in active mode or reset
    /// the UART to clear its wake signal before another sleep (§27.4.8).
    uart0: bool = false,
    uart1: bool = false,
    /// LP firmware wakes HP with PMU.HP_LP_CPU_COMM.LP_TRIGGER_HP (§3.9.3).
    lp_core: bool = false,

    fn mark(self: Config, step: Step) void {
        setup.milestone(@backingInt(step), 0);
        if (self.trace) |trace| trace(step);
    }
};
pub const WakeCause = struct {
    timer: bool,
    gpio: bool,
    uart0: bool,
    uart1: bool,
    lp_core: bool,
    raw: u32,
    gpio_pins: u8,
};
pub const Diagnostics = struct {
    wake: u32 = 0,
    reject: u32 = 0,
    interrupt_raw: u32 = 0,
    usb_bus_reset: ?bool = null,
};
pub const ResetReason = enum(u5) { deep_sleep = 5, _ };
pub const BootCause = struct { reset: ResetReason, wake: WakeCause };
pub const Error = error{
    InvalidTimer,
    TimerExpired,
    InvalidPin,
    InvalidWakeConfig,
    NoWakeSource,
    UnsupportedClock,
    UnsupportedUartMode,
    UsbSerialJtagActive,
    RadioActive,
    Rejected,
    Timeout,
    UnexpectedWake,
    WatchdogActive,
};

fn decode(raw: u32) WakeCause {
    return .{
        .timer = raw & 0x10 != 0,
        .gpio = raw & 6 != 0,
        .uart0 = raw & 0x40 != 0,
        .uart1 = raw & 0x80 != 0,
        .lp_core = raw & 0x800 != 0,
        .raw = raw,
        .gpio_pins = if (raw & 2 != 0) aon.EXT_WAKEUP_CNTL.read().EXT_WAKEUP_STATUS else 0,
    };
}

/// Read before the first sleep call: cause flags are consumed by that call.
/// Only a deep-sleep reset gives boot wake flags meaning. TRM §8.2.2.7,
/// §12.4.2.2, LP_CLKRST_RESET_CAUSE and PMU_SLP_WAKEUP_STATUS0.
/// Reading the cause does not release pad holds or clear status. Default HAL
/// startup calls release_ext1_holds_at_startup() before application code.
pub fn wake_cause() BootCause {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    const reset: ResetReason = @fromBackingInt(@intCast(p.LP_CLKRST.RESET_CAUSE.read().RESET_CAUSE));
    const wake = decode(if (reset == .deep_sleep) pmu.SLP_WAKEUP_STATUS0.read().WAKEUP_CAUSE else 0);
    return .{ .reset = reset, .wake = wake };
}

/// Release only the retained EXT1-selected pad holds, preserving wake status
/// and other pads' holds. Disable selection first, as ESP-IDF v5.5.1
/// cpu_start.c:773–777 / sleep_gpio.c:188–201 do on deep-sleep startup.
/// Unlike IDF, also recover after an interrupted sleep preparation: CPU and
/// Core resets preserve the LP system (TRM v1.2 §8.1.3, Table 8.1-1), including
/// LP_AON.GPIO_HOLD0 (§12.10.2 register 12.60). System/Chip resets clear it.
/// Default HAL startup calls this before application pad users, irrespective
/// of reset cause. With HAL_Options.release_ext1_holds_at_startup=false,
/// call manually before reconfiguring retained wake pads. Serialize with LP users.
pub fn release_ext1_holds_at_startup() void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    const pins = aon.EXT_WAKEUP_CNTL.read().EXT_WAKEUP_SEL;
    disable_ext1();
    release_ext1_holds(pins);
}

/// Uses the shared software snapshot. Serialize with LP snapshot users (§12.4.3).
pub fn rtc_ticks() u48 {
    setup.milestone(0x36, @intFromPtr(&timer.UPDATE));
    return @import("lp_timer.zig").now();
}

/// Selected EXT1 pads get the LP GPIO input path with LP IO clock enabled.
/// LP peripherals stay powered in light sleep, so no pad hold is added.
/// Pad settings and the clock gate are restored before return, also on error.
/// IDF sleep_modes.c:2046–2060; TRM §§7.7,7.9,12.4.2.4.
pub fn enter_light_sleep(config: Config) Error!WakeCause {
    return enter(config, false);
}

/// Success never returns: HP context and code in RAM are lost. Install a flash
/// image-boot application before calling. LP SRAM survives (§5.3.2); application
/// startup must leave its retained area untouched. No wake stub is installed.
/// USB policy detaches before entry; ROM/application reinitializes USB on reboot.
/// EXT1 pads are held when LP peripherals power down (unless lp_core is set),
/// retaining the input path and caller's pulls; external input can still change.
/// Default HAL startup releases these holds on reboot, before application code.
/// Errors release holds and restore pad/clock settings here.
/// IDF sleep_modes.c:2037–2081, sleep_gpio.c:188–201; TRM §§7.7,7.9,12.4.2.4.
pub fn enter_deep_sleep(config: Config) Error!noreturn {
    _ = try enter(config, true);
    return error.UnexpectedWake;
}

fn enter(config: Config, deep: bool) Error!WakeCause {
    if (config.diagnostics) |d| d.* = .{};
    if (config.timer_ticks) |ticks| {
        if (ticks == 0 or ticks >= (@as(u48, 1) << 47)) return error.InvalidTimer;
    }
    if (config.gpio) |gpio| {
        if (gpio.pin >= 8) return error.InvalidPin;
        if (config.ext1 != null) return error.InvalidWakeConfig;
    }
    if (config.ext1) |ext1| {
        if (ext1.pins == 0 or ext1.levels & ~ext1.pins != 0) return error.InvalidWakeConfig;
    }
    if (deep and (config.uart0 or config.uart1)) return error.InvalidWakeConfig;
    const ext1: Ext1Wake = if (config.ext1) |value| value else if (config.gpio) |gpio|
        .{ .pins = @as(u8, 1) << @as(u3, @intCast(gpio.pin)), .levels = @as(u8, gpio.level) << @as(u3, @intCast(gpio.pin)) }
    else
        .{ .pins = 0, .levels = 0 };
    const sources: u31 = @as(u31, if (config.timer_ticks != null) 0x10 else 0) |
        @as(u31, if (ext1.pins != 0) 2 else 0) |
        @as(u31, if (config.uart0) 0x40 else 0) |
        @as(u31, if (config.uart1) 0x80 else 0) |
        @as(u31, if (config.lp_core) 0x800 else 0);
    if (sources == 0) return error.NoWakeSource;
    if (config.bench_recovery and config.timer_ticks == null) return error.InvalidTimer;

    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    if (analog.sleep_blocked()) return error.RadioActive;
    if (p.PCR.SYSCLK_CONF.read().SOC_CLK_SEL > 1) return error.UnsupportedClock;
    if ((config.uart0 and p.UART0.SLEEP_CONF2.read().WK_MODE_SEL != 0) or
        (config.uart1 and p.UART1.SLEEP_CONF2.read().WK_MODE_SEL != 0)) return error.UnsupportedUartMode;
    if (aon.GPIO_MUX.read().SEL & ext1.pins != ext1.pins) return error.InvalidPin;
    // Startup releases retained EXT1 holds. Any remaining hold belongs to the
    // caller: it prevents our input setup from reaching the pad (TRM §7.9).
    // Reject rather than silently unholding and changing a caller-owned pad.
    if (aon.GPIO_HOLD0.read().GPIO_HOLD0 & ext1.pins != 0) return error.InvalidPin;
    if (config.usb_policy == .unchanged and !config.allow_usb_loss and p.USB_DEVICE.CONF0.read().USB_PAD_ENABLE != 0)
        return error.UsbSerialJtagActive;
    // Reject before regulator handoff or USB detachment. TRM §12.4.2.5.
    if ((deep or config.power_down_xtal) and p.LP_CLKRST.LP_CLK_CONF.read().FAST_CLK_SEL != 0)
        return error.UnsupportedClock;
    if (config.bench_reset_ticks) |ticks| {
        if (!config.bench_recovery or ticks == 0 or ticks >= config.timer_ticks.?) return error.InvalidTimer;
    }
    const sleep_start = rtc_ticks();
    const cal = setup.Calibration.read();
    var measured: ?sleep_clock.Periods = null;
    if (!initialized) {
        try pmu_analog.give_regulators_to_pmu();
        const plan = setup.init_plan(cal);
        plan.apply(0x30);
        const periods = try sleep_clock.calibrate();
        if (p.LP_CLKRST.RESET_CAUSE.read().RESET_CAUSE == 1)
            try pmu_analog.ocode_init(periods.slow);
        measured = periods;
        initialized = true;
    }
    const periods = measured orelse try sleep_clock.calibrate();
    // IDF timer_wakeup_prepare anchors the alarm to the API entry snapshot,
    // rather than adding the requested interval after PMU setup.
    const target = if (config.timer_ticks) |ticks| sleep_start +% ticks else null;
    const clock = sleep_clock.Saved.capture();
    config.mark(.usb);
    const detached = if (config.usb_policy == .disconnect_and_reenumerate) usb.Disconnect.begin(config.usb_reattach) else null;
    defer if (detached) |connection| {
        config.mark(.restore_usb);
        const reset = connection.finish();
        if (config.diagnostics) |d| d.usb_bus_reset = reset;
    };

    // USB host reenumeration has its own potentially longer timeout. Keep
    // RWDT around hardware entry/exit, then disarm before waiting for a host.
    const guard = try wdt.C6SleepGuard.begin(periods.slow, if (config.bench_recovery) config.timer_ticks else null, config.bench_reset_ticks);
    defer guard.finish();
    const ext_saved = aon.EXT_WAKEUP_CNTL.read();
    config.mark(.saved);
    defer {
        config.mark(.restore_power);
        setup.milestone(0x35, @intFromPtr(&aon.EXT_WAKEUP_CNTL));
        aon.EXT_WAKEUP_CNTL.write(.{ .EXT_WAKEUP_STATUS = 0, .EXT_WAKEUP_STATUS_CLR = 0, .EXT_WAKEUP_SEL = ext_saved.EXT_WAKEUP_SEL, .EXT_WAKEUP_LV = ext_saved.EXT_WAKEUP_LV, .EXT_WAKEUP_FILTER = ext_saved.EXT_WAKEUP_FILTER });
        config.mark(.restored);
    }
    // IDF sleep_modes.c:1001–1008. C6 MSPI synchronization is a no-op
    // (clk_utils.c:23–43; FLASH_CPU_CLK_SRC_BINDED is only defined on S3).
    var uarts = Uarts.capture();
    const prepared = uarts.prepare(deep);
    if (prepared) |_| {} else |err| {
        try uarts.finish();
        return err;
    }
    // No retention/ADC monitor profile: remove PWDET power ownership while
    // asleep, as sar_periph_ctrl_power_disable does (TRM §39.3 CTRL bit 29).
    const sar_clock = p.PCR.SARADC_CONF.read();
    p.PCR.SARADC_CONF.modify(.{ .SARADC_REG_CLK_EN = 1, .SARADC_REG_RST_EN = 0 });
    const pwdet = p.APB_SARADC.CTRL.read().SARADC2_PWDET_DRV;
    p.APB_SARADC.CTRL.modify(.{ .SARADC2_PWDET_DRV = 0 });
    defer {
        p.APB_SARADC.CTRL.modify(.{ .SARADC2_PWDET_DRV = pwdet });
        p.PCR.SARADC_CONF.modify(.{ .SARADC_REG_CLK_EN = sar_clock.SARADC_REG_CLK_EN, .SARADC_REG_RST_EN = sar_clock.SARADC_REG_RST_EN });
    }
    // sleep_modes.c:1011–1014: save, then switch CPU to XTAL before setup.
    config.mark(.cpu_clock);
    clock.to_xtal();
    // Restoration errors must be reported; USB and IRQ defers still run.
    const result = enter_on_xtal(config, deep, cal, periods, ext1, sources, target);
    const restored = clock.restore();
    const resumed = uarts.finish();
    try restored;
    try resumed;
    return result;
}

fn enter_on_xtal(config: Config, deep: bool, cal: setup.Calibration, periods: sleep_clock.Periods, ext1: Ext1Wake, sources: u31, target: ?u48) Error!WakeCause {
    config.mark(.power);
    const plan = try setup.sleep_plan(cal, periods, deep, .{
        .power_down_xtal = config.power_down_xtal,
        .lp_core = config.lp_core,
        .slow_source = p.LP_CLKRST.LP_CLK_CONF.read().SLOW_CLK_SEL,
    });
    for (plan.rows[0..plan.len]) |r| {
        if (@import("std").mem.eql(u8, r.name, "HP_SLEEP_HP_CK_POWER")) config.mark(.clocks);
        if (@import("std").mem.eql(u8, r.name, "HP_SLEEP_BIAS")) config.mark(.bias);
        setup.milestone(0x31, @intFromPtr(r.reg));
        r.reg.write_raw(if (r.mask == 0xffffffff) r.value else (r.reg.raw & ~r.mask) | r.value);
    }
    if (config.bench_recovery)
        pmu.HP_SLEEP_HP_SYS_CNTL.modify(.{ .HP_SLEEP_DIG_PAUSE_WDT = 0 });
    defer if (config.bench_recovery)
        pmu.HP_SLEEP_HP_SYS_CNTL.modify(.{ .HP_SLEEP_DIG_PAUSE_WDT = 1 });
    config.mark(.gpio);
    const io_clock = p.LP_PERI.CLK_EN.read().LP_IO_CK_EN;
    defer if (ext1.pins != 0) {
        // Restore the independent gate: rtc_io_ll.h:59–65; TRM §8.2.4
        // (TRM v1.2 omits LPPERI_CLK_EN; the field follows IDF).
        p.LP_PERI.CLK_EN.modify(.{ .LP_IO_CK_EN = io_clock });
    };
    if (ext1.pins != 0) {
        // IDF components/hal/esp32c6/include/hal/rtc_io_ll.h:59–65,
        // sleep_modes.c:2046–2049; TRM §8.2.4 (independent LP clock gate).
        p.LP_PERI.CLK_EN.modify(.{ .LP_IO_CK_EN = 1 });
        // This is a gate control, not a readiness flag. IDF rtc_io_ll.h:59–65
        // polls this same control bit; TRM §8.2.4 defines no LP IO ready signal.
    }
    var pads: [8]u32 = undefined;
    inline for (lp_pad_names, 0..) |name, pin| {
        if (ext1.pins & (@as(u8, 1) << pin) != 0) {
            const r = &@field(p.LP_IO, name);
            pads[pin] = r.raw;
            // LP mux ownership was validated above. IDF rtc_io_ll.h:49–51,
            // 79–87,136–139,414–417; TRM §§7.7,7.16.4, register 7.46.
            // Use the active input/pulls in sleep, as lp_io.apply does.
            r.modify(.{ .MCU_SEL = 0, .FUN_IE = 1, .SLP_SEL = 0 });
        }
    }
    defer if (ext1.pins != 0) {
        disable_ext1();
        // Restore configuration before unholding; same LP IO fields cited above.
        inline for (lp_pad_names, 0..) |name, pin| {
            if (ext1.pins & (@as(u8, 1) << pin) != 0)
                @field(p.LP_IO, name).write_raw(pads[pin]);
        }
        release_ext1_holds(ext1.pins);
    };
    const gpio = gpio_plan(ext1);
    gpio.apply(0x32);
    if (ext1.pins != 0 and deep and !config.lp_core) {
        // IDF sleep_modes.c:2056–2060; C6 rtc_io_ll.h:271–274;
        // TRM §7.9, register 12.60. Match the LP peripheral power policy
        // (IDF port/esp32c6/private_include/pmu_param.h:305–308).
        // Deliberately select before holding, reversing IDF v5.5.1's order:
        // startup cleanup can find held pads if preparation is interrupted.
        aon.GPIO_HOLD0.modify(.{ .GPIO_HOLD0 = aon.GPIO_HOLD0.read().GPIO_HOLD0 | ext1.pins });
    }
    config.mark(.timer);
    const alarm = alarm_plan(target);
    alarm.apply(0x33);
    defer {
        const cleanup = cleanup_plan();
        cleanup.apply(0x34);
    }
    if (target) |deadline| {
        const remaining = deadline -% rtc_ticks();
        if (remaining < 4 or remaining >= (@as(u48, 1) << 47)) return error.TimerExpired;
    }
    // IDF arms the alarm before pmu_sleep_start enables/clears PMU sources.
    const wake = wake_plan(deep, sources);
    wake.apply(0x32);
    config.mark(.request);
    const outcome = request_sleep(deep);
    if (config.diagnostics) |d| {
        d.wake = pmu.SLP_WAKEUP_STATUS0.read().WAKEUP_CAUSE;
        d.reject = pmu.SLP_WAKEUP_STATUS1.read().REJECT_CAUSE;
        d.interrupt_raw = pmu.INT_RAW.raw;
    }
    switch (outcome) {
        .timeout => return error.Timeout,
        .rejected => return error.Rejected,
        .woke => {
            config.mark(.woke);
            if (deep) return error.UnexpectedWake;
            return decode(pmu.SLP_WAKEUP_STATUS0.read().WAKEUP_CAUSE);
        },
    }
}

// IDF sleep_modes.c:605–651 and uart_ll.h:1445–1468; TRM §§27.4.7,
// 27.5.1. Own enabled HP UARTs under the sleep critical section. Do not let
// an absent UART clock hang before SLEEP_REQ: all pre-entry waits are bounded.
const Uarts = struct {
    enabled: [2]bool,
    suspended: [2]bool = .{ false, false },

    fn capture() Uarts {
        const a = p.PCR.UART0_CONF.read();
        const b = p.PCR.UART1_CONF.read();
        return .{ .enabled = .{ a.UART0_CLK_EN != 0 and a.UART0_RST_EN == 0, b.UART1_CLK_EN != 0 and b.UART1_RST_EN == 0 } };
    }
    fn update(r: *volatile microzig.chip.types.peripherals.UART0) error{Timeout}!void {
        r.REG_UPDATE.write(.{ .REG_UPDATE = 1 });
        for (0..100_000) |_| {
            if (r.REG_UPDATE.read().REG_UPDATE == 0) return;
        }
        return error.Timeout;
    }
    fn prepare(self: *Uarts, deep: bool) error{Timeout}!void {
        inline for (.{ p.UART0, p.UART1 }, 0..) |r, i| {
            if (self.enabled[i]) {
                if (!deep) {
                    self.suspended[i] = true;
                    r.SWFC_CONF0_SYNC.modify(.{ .FORCE_XON = 0, .SW_FLOW_CON_EN = 1, .FORCE_XOFF = 1 });
                    try update(r);
                }
                var idle = false;
                for (0..1_000_000) |_| {
                    const fsm = r.FSM_STATUS.read().ST_UTX_OUT;
                    if (if (deep) r.STATUS.read().TXFIFO_CNT == 0 and fsm == 0 else fsm == 0 or fsm == 15) {
                        idle = true;
                        break;
                    }
                }
                if (!idle) return error.Timeout;
            }
        }
    }
    fn finish(self: *Uarts) error{Timeout}!void {
        var failed = false;
        inline for (.{ p.UART0, p.UART1 }, 0..) |r, i| {
            if (self.suspended[i]) {
                r.SWFC_CONF0_SYNC.modify(.{ .FORCE_XOFF = 0, .FORCE_XON = 1 });
                r.SWFC_CONF0_SYNC.modify(.{ .SW_FLOW_CON_EN = 0, .FORCE_XON = 0 });
                update(r) catch {
                    failed = true;
                };
            }
        }
        if (failed) return error.Timeout;
    }
};

const Outcome = enum { woke, rejected, timeout };

// Disable selection before unholding to preserve latched status: IDF v5.5.1
// sleep_gpio.c:191–199; hal/esp32c6/include/hal/lp_aon_ll.h:57–60;
// TRM §12.10.2, EXT_WAKEUP_CNTL. Never echo the status-clear trigger.
fn disable_ext1() void {
    aon.EXT_WAKEUP_CNTL.modify(.{ .EXT_WAKEUP_SEL = 0, .EXT_WAKEUP_STATUS_CLR = 0 });
}

// IDF hal/esp32c6/include/hal/rtc_io_ll.h:282–285; TRM §7.9,
// register 12.60. Only selected pads are released; other holds stay intact.
fn release_ext1_holds(pins: u8) void {
    aon.GPIO_HOLD0.modify(.{ .GPIO_HOLD0 = aon.GPIO_HOLD0.read().GPIO_HOLD0 & ~@as(u32, pins) });
}
// sleep_modes.c:861–893,895–897,968–970: only light sleep suspends cache.
// No trace callbacks or flash data references while cache is disabled.
noinline fn request_sleep(deep: bool) linksection(".ram_text") Outcome {
    const rom = microzig.hal.rom.functions;
    setup.milestone(0x40, 0);
    const autoload = if (!deep) rom.Cache_Suspend_ICache() else 0;
    defer {
        setup.milestone(0x43, 0);
        if (!deep) rom.Cache_Resume_ICache(autoload);
    }
    setup.milestone(0x41, @intFromPtr(&pmu.SLP_WAKEUP_CNTL0));
    pmu.SLP_WAKEUP_CNTL0.write(.{ .SLEEP_REQ = 1 });
    var wake = false;
    var reject = false;
    // IDF pmu_sleep.c:375–378: SLEEP_REQ is a trigger (TRM ch.12,
    // register 12.40), not a cancellable transaction. Never return and
    // disarm the alarm while PMU may still accept it. RWDT covers active
    // entry/exit; the opt-in bench guard also runs during sleep.
    while (true) {
        const status = pmu.INT_RAW.read();
        wake = status.SOC_WAKEUP_INT_RAW != 0;
        reject = status.SOC_SLEEP_REJECT_INT_RAW != 0;
        if (wake or reject) break;
    }
    // pmu_sleep.c:384–391, hal/esp32c6/include/hal/efuse_ll.h:23–30.
    // EFUSE_CONTROLLER_STATE_IDLE is 1, not RESET (0). Finish also on reject.
    setup.milestone(0x42, @intFromPtr(&p.EFUSE.STATUS));
    for (0..100_000) |_| {
        if (p.EFUSE.STATUS.read().STATE == 1) return if (reject) .rejected else .woke;
    }
    return .timeout;
}

// IDF sleep_modes.c:2078–2081; hal/esp32c6/include/hal/lp_aon_ll.h:35–51.
// TRM §§12.4.2.2,12.10.2–3. LP software wake latches stay intact.
fn gpio_plan(ext1: Ext1Wake) setup.Plan {
    var plan: setup.Plan = .{};
    if (ext1.pins == 0) return plan;
    plan.modify(aon, "EXT_WAKEUP_CNTL", .{ .EXT_WAKEUP_STATUS = @as(u8, 0), .EXT_WAKEUP_STATUS_CLR = @as(u1, 1), .EXT_WAKEUP_SEL = ext1.pins, .EXT_WAKEUP_LV = ext1.levels, .EXT_WAKEUP_FILTER = @as(u1, 0) }, 0x4000 | (@as(u32, ext1.pins) << 15) | (@as(u32, ext1.levels) << 23));
    plan.rows[plan.len - 1].mask = 0xffffffff;
    return plan;
}
fn wake_plan(deep: bool, sources: u31) setup.Plan {
    var plan: setup.Plan = .{};
    // lp_aon_ll_inform_wakeup_type: STORE9 bit 0. No optional wake stub.
    plan.modify(aon, "STORE9", .{ .LP_AON_STORE9 = (aon.STORE9.raw & ~@as(u32, 1)) | @intFromBool(deep) }, (aon.STORE9.raw & 0xfffffffe) | @as(u32, @intFromBool(deep)));
    plan.modify(pmu, "SLP_WAKEUP_CNTL2", .{ .WAKEUP_ENA = @as(u32, sources) }, sources);
    plan.modify(pmu, "SLP_WAKEUP_CNTL1", .{ .SLP_REJECT_EN = @as(u1, 1), .SLEEP_REJECT_ENA = sources }, 0x80000000 | @as(u32, sources));
    plan.add(setup.row(pmu, "HP_INT_CLR", .{ .LP_CPU_EXC_INT_CLR = 0, .SDIO_IDLE_INT_CLR = 0, .SW_INT_CLR = 0, .SOC_SLEEP_REJECT_INT_CLR = 1, .SOC_WAKEUP_INT_CLR = 1 }, 0xc0000000, true));
    plan.add(setup.row(pmu, "SLP_WAKEUP_CNTL4", .{ .SLP_REJECT_CAUSE_CLR = 1 }, 0x80000000, true));
    return plan;
}
fn alarm_plan(target: ?u48) setup.Plan {
    var plan: setup.Plan = .{};
    plan.modify(timer, "TAR0_HIGH", .{ .MAIN_TIMER_TAR_EN0 = @as(u1, 0) }, 0);
    plan.add(setup.row(timer, "INT_CLR", .{ .OVERFLOW_CLR = 0, .SOC_WAKEUP_INT_CLR = 1 }, 0x80000000, true));
    if (target) |value| {
        // lp_timer_ll.h:25–34: high/low while disabled, enable last.
        plan.modify(timer, "TAR0_HIGH", .{ .MAIN_TIMER_TAR_HIGH0 = @as(u16, @truncate(value >> 32)), .MAIN_TIMER_TAR_EN0 = @as(u1, 0) }, @as(u32, @intCast(value >> 32)));
        plan.modify(timer, "TAR0_LOW", .{ .MAIN_TIMER_TAR_LOW0 = @as(u32, @truncate(value)) }, @as(u32, @truncate(value)));
        plan.modify(timer, "TAR0_HIGH", .{ .MAIN_TIMER_TAR_HIGH0 = @as(u16, @truncate(value >> 32)), .MAIN_TIMER_TAR_EN0 = @as(u1, 1) }, (@as(u32, @intCast(value >> 32)) | 0x80000000));
    }
    return plan;
}
fn cleanup_plan() setup.Plan {
    var plan: setup.Plan = .{};
    plan.modify(timer, "TAR0_HIGH", .{ .MAIN_TIMER_TAR_EN0 = @as(u1, 0) }, 0);
    plan.add(setup.row(timer, "INT_CLR", .{ .OVERFLOW_CLR = 0, .SOC_WAKEUP_INT_CLR = 1 }, 0x80000000, true));
    plan.add(setup.row(pmu, "HP_INT_CLR", .{ .LP_CPU_EXC_INT_CLR = 0, .SDIO_IDLE_INT_CLR = 0, .SW_INT_CLR = 0, .SOC_SLEEP_REJECT_INT_CLR = 1, .SOC_WAKEUP_INT_CLR = 1 }, 0xc0000000, true));
    return plan;
}

pub const RegisterProbe = struct {
    phase: []const u8,
    name: []const u8,
    address: usize,
    current: u32,
    would_write: u32,
    idf_expected: u32,
    mask: u32,
};
/// No sleep, no PMU state-table writes or regulator handoff. Temporarily
/// routes LP clocks for bounded TIMG calibration, restoring the clock gates.
/// Target deadlines are illustrative (100 ms / 2 s from the sampled count).
/// Run before any radio initialization or LP snapshot/calibration client.
pub fn probe_registers(visitor: *const fn (RegisterProbe) void) Error!void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    if (analog.sleep_blocked()) return error.RadioActive;
    // Read-only check of the startup invariant (TRM Register 8.75).
    const lp_clock = p.LP_CLKRST.LP_CLK_CONF.raw;
    visitor(.{ .phase = "startup", .name = "LP_CLK_CONF", .address = @intFromPtr(&p.LP_CLKRST.LP_CLK_CONF), .current = lp_clock, .would_write = lp_clock, .idf_expected = lp_clock & ~@as(u32, 4), .mask = 4 });
    // First print the literal reference-input profiles. These comparisons use
    // checked-in words directly, without the runtime oracle's arithmetic.
    inline for (setup.idf_reference.vectors, 0..) |v, i| {
        if (i < 3) {
            const fixture_cal = setup.Calibration.from_fuses(.{ .version = v.fuses.version, .hp = v.fuses.hp, .lp = v.fuses.lp, .deep_dbg = v.fuses.deep_dbg, .deep_lp = v.fuses.deep_lp });
            const fixture_plan = try setup.sleep_plan_for_clock(fixture_cal, .{ .slow = v.slow, .fast = v.fast }, v.deep, false, .{ .power_down_xtal = v.xtal_off });
            inline for (v.words, 0..) |word, j| {
                const r = fixture_plan.rows[j];
                const current = r.reg.raw;
                visitor(.{ .phase = v.name, .name = r.name, .address = @intFromPtr(r.reg), .current = current, .would_write = (current & ~r.mask) | r.value, .idf_expected = (current & ~@as(u32, word.mask)) | word.value, .mask = r.mask });
            }
        }
    }
    const cal = setup.Calibration.read();
    const periods = try sleep_clock.calibrate();
    const init = setup.init_plan(cal);
    var base: ProbeState = .{};
    report_plan("init", &init, &base, visitor);
    inline for (.{ 0, 1, 2 }) |profile| {
        const deep = profile == 1;
        const phase = if (deep) "deep" else if (profile == 2) "light_xtal_off" else "light";
        var state = base;
        const plan = try setup.sleep_plan(cal, periods, deep, .{ .power_down_xtal = profile == 2, .slow_source = p.LP_CLKRST.LP_CLK_CONF.read().SLOW_CLK_SEL });
        report_plan(phase, &plan, &state, visitor);
        const gpio = gpio_plan(.{ .pins = 0, .levels = 0 });
        report_plan(phase, &gpio, &state, visitor);
        const ticks = sleep_clock.Periods.cycles(periods.slow, if (deep) 2_000_000 else 100_000);
        const alarm = alarm_plan(rtc_ticks() +% ticks);
        report_plan(phase, &alarm, &state, visitor);
        const wake = wake_plan(deep, 0x10);
        report_plan(phase, &wake, &state, visitor);
        var commands: setup.Plan = .{};
        commands.add(setup.row(timer, "UPDATE", .{ .MAIN_TIMER_UPDATE = 1 }, 0x10000000, false));
        commands.add(setup.row(pmu, "SLP_WAKEUP_CNTL0", .{ .SLEEP_REQ = 1 }, 0x80000000, true));
        report_plan(phase, &commands, &state, visitor);
    }
    const cleanup = cleanup_plan();
    report_plan("finish", &cleanup, &base, visitor);
    var clock: setup.Plan = .{};
    clock.modify(p.PCR, "AHB_FREQ_CONF", .{ .AHB_LS_DIV_NUM = @as(u8, 0) }, 0);
    clock.modify(p.PCR, "CPU_FREQ_CONF", .{ .CPU_LS_DIV_NUM = @as(u8, 0) }, 0);
    clock.modify(p.PCR, "SYSCLK_CONF", .{ .SOC_CLK_SEL = @as(u2, 0) }, 0);
    const ahb = p.PCR.AHB_FREQ_CONF.read();
    const cpu = p.PCR.CPU_FREQ_CONF.read();
    clock.modify(p.PCR, "AHB_FREQ_CONF", .{ .AHB_LS_DIV_NUM = ahb.AHB_LS_DIV_NUM, .AHB_HS_DIV_NUM = ahb.AHB_HS_DIV_NUM }, p.PCR.AHB_FREQ_CONF.raw & 0x0000ffff);
    clock.modify(p.PCR, "CPU_FREQ_CONF", .{ .CPU_LS_DIV_NUM = cpu.CPU_LS_DIV_NUM, .CPU_HS_DIV_NUM = cpu.CPU_HS_DIV_NUM, .CPU_HS_120M_FORCE = cpu.CPU_HS_120M_FORCE }, p.PCR.CPU_FREQ_CONF.raw & 0x0001ffff);
    clock.modify(p.PCR, "SYSCLK_CONF", .{ .SOC_CLK_SEL = p.PCR.SYSCLK_CONF.read().SOC_CLK_SEL }, p.PCR.SYSCLK_CONF.raw & 0x00030000);
    clock.modify(aon, "EXT_WAKEUP_CNTL", .{ .EXT_WAKEUP_STATUS = @as(u8, 0), .EXT_WAKEUP_STATUS_CLR = @as(u1, 0), .EXT_WAKEUP_SEL = aon.EXT_WAKEUP_CNTL.read().EXT_WAKEUP_SEL, .EXT_WAKEUP_LV = aon.EXT_WAKEUP_CNTL.read().EXT_WAKEUP_LV, .EXT_WAKEUP_FILTER = aon.EXT_WAKEUP_CNTL.read().EXT_WAKEUP_FILTER }, aon.EXT_WAKEUP_CNTL.raw & 0xffff8000);
    clock.modify(p.LP_CLKRST, "CLK_TO_HP", .{ .ICG_HP_FOSC = @as(u1, 1), .ICG_HP_XTAL32K = @as(u1, 1), .ICG_HP_OSC32K = @as(u1, 1) }, 0xd0000000);
    clock.add(setup.row(pmu, "IMM_HP_CK_POWER", .{ .TIE_LOW_GLOBAL_BBPLL_ICG = 1 }, 1, false));
    clock.add(setup.row(pmu, "IMM_HP_CK_POWER", .{ .TIE_LOW_XPD_BBPLL = 1, .TIE_LOW_XPD_BBPLL_I2C = 1 }, 0x30, false));
    clock.add(setup.row(pmu, "IMM_HP_CK_POWER", .{ .TIE_HIGH_XPD_BB_I2C = 1, .TIE_HIGH_XPD_BBPLL = 1, .TIE_HIGH_XPD_BBPLL_I2C = 1 }, 0x70000000, false));
    clock.add(setup.row(pmu, "IMM_HP_CK_POWER", .{ .TIE_HIGH_GLOBAL_BBPLL_ICG = 1 }, 0x02000000, false));
    clock.modify(p.LP_CLKRST, "CLK_TO_HP", p.LP_CLKRST.CLK_TO_HP.read(), p.LP_CLKRST.CLK_TO_HP.raw);
    report_plan("clock", &clock, &base, visitor);
    // Safe analog reads through the same bounded bus; never write an ENIF/XPD
    // field. The address column encodes slave:register, rather than MMIO.
    const bus = pmu_analog.Bus.begin();
    defer bus.end();
    inline for (.{
        .{ "ENIF_RTC_DREG", 5, 0x80, 0x80 },
        .{ "ENIF_DIG_DREG", 7, 0x80, 0x80 },
        .{ "XPD_RTC_REG", 13, 4, 0 },
        .{ "XPD_DIG_REG", 13, 8, 0 },
    }) |field| {
        const current = try pmu_analog.read_byte(0x6d, field[1]);
        const would = (current & ~@as(u8, field[2])) | field[3];
        visitor(.{ .phase = "analog", .name = field[0], .address = 0x6d00 | field[1], .current = current, .would_write = would, .idf_expected = would, .mask = field[2] });
    }
}
const ProbeState = struct {
    registers: [128]usize = undefined,
    values: [128]u32 = undefined,
    expected: [128]u32 = undefined,
    len: usize = 0,

    fn index(self: *ProbeState, address: usize, current: u32) usize {
        for (self.registers[0..self.len], 0..) |reg, i| {
            if (reg == address) return i;
        }
        @import("std").debug.assert(self.len < self.values.len);
        const i = self.len;
        self.registers[i] = address;
        self.values[i] = current;
        self.expected[i] = current;
        self.len += 1;
        return i;
    }
};
fn report_plan(phase: []const u8, plan: *const setup.Plan, state: *ProbeState, visitor: *const fn (RegisterProbe) void) void {
    // Carry init state into each sleep profile without executing any write.
    for (plan.rows[0..plan.len]) |r| {
        const current = r.reg.raw;
        const index = state.index(@intFromPtr(r.reg), current);
        const previous = state.values[index];
        const predicted = (previous & ~r.mask) | r.value;
        const expected = (state.expected[index] & ~r.mask) | r.idf;
        visitor(.{ .phase = phase, .name = r.name, .address = @intFromPtr(r.reg), .current = current, .would_write = predicted, .idf_expected = expected, .mask = r.mask });
        state.values[index] = predicted;
        state.expected[index] = expected;
    }
}
