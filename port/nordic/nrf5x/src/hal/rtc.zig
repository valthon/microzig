//! nRF52840 RTC1 and RTC2 (Product Specification v1.11, §6.22).
const microzig = @import("microzig");
const compatibility = @import("compatibility.zig");
const peripherals = microzig.chip.peripherals;
const Regs = microzig.chip.types.peripherals.RTC0;
const InterruptBits = @FieldType(Regs, "INTENSET").underlying_type;

pub const Event = enum(u5) {
    tick = @bitOffsetOf(InterruptBits, "TICK"),
    overflow = @bitOffsetOf(InterruptBits, "OVRFLW"),
    compare0 = @bitOffsetOf(InterruptBits, "COMPARE0"),
    compare1 = @bitOffsetOf(InterruptBits, "COMPARE1"),
    compare2 = @bitOffsetOf(InterruptBits, "COMPARE2"),
    compare3 = @bitOffsetOf(InterruptBits, "COMPARE3"),

    fn mask(event: Event) u32 {
        return @as(u32, 1) << @backingInt(event);
    }
};

pub const Rtc = enum {
    rtc1,
    rtc2,

    fn regs(rtc: Rtc) *volatile Regs {
        if (compatibility.chip != .nrf52840) compatibility.unsupported_chip("RTC");
        return switch (rtc) {
            .rtc1 => peripherals.RTC1,
            .rtc2 => peripherals.RTC2,
        };
    }

    pub fn interrupt(comptime rtc: Rtc) microzig.cpu.Interrupt {
        return switch (rtc) {
            .rtc1 => .RTC1,
            .rtc2 => .RTC2,
        };
    }

    /// Set the divider (prescaler + 1) of the 32.768 kHz LFCLK while stopped.
    pub fn apply(rtc: Rtc, prescaler: u12) void {
        rtc.regs().PRESCALER.write(.{ .PRESCALER = prescaler });
    }

    pub fn start(rtc: Rtc) void {
        rtc.regs().TASKS_START.write_raw(1);
    }

    /// The task is asynchronous. Allow up to 46 us on a running LFCLK (§6.22.8).
    pub fn stop(rtc: Rtc) void {
        rtc.regs().TASKS_STOP.write_raw(1);
    }

    /// The task is asynchronous. Allow up to 46 us on a running LFCLK (§6.22.8).
    pub fn clear(rtc: Rtc) void {
        rtc.regs().TASKS_CLEAR.write_raw(1);
    }

    pub fn counter(rtc: Rtc) u24 {
        return rtc.regs().COUNTER.read().COUNTER;
    }

    /// Set an absolute compare tick. While running, leave at least two ticks
    /// at the write. An old compare within the next two ticks can still fire.
    /// Program a stopped RTC for initial setup (§6.22.7).
    pub fn set_compare(rtc: Rtc, channel: u2, tick: u24) void {
        rtc.regs().CC[channel].write(.{ .COMPARE = tick });
    }

    fn event_register(rtc: Rtc, comptime event: Event) *volatile switch (event) {
        .tick => @FieldType(Regs, "EVENTS_TICK"),
        .overflow => @FieldType(Regs, "EVENTS_OVRFLW"),
        else => @typeInfo(@FieldType(Regs, "EVENTS_COMPARE")).array.child,
    } {
        const r = rtc.regs();
        return switch (event) {
            .tick => &r.EVENTS_TICK,
            .overflow => &r.EVENTS_OVRFLW,
            else => &r.EVENTS_COMPARE[@backingInt(event) - @backingInt(Event.compare0)],
        };
    }

    /// Enable event routing before using this endpoint with PPI.
    /// On nRF52840 (anomaly 179), avoid CPU access to this RTC's registers
    /// while waiting for a PPI-routed compare. Such access can trigger the
    /// routed task twice. The compare interrupt may still be enabled.
    pub fn event_endpoint(rtc: Rtc, comptime event: Event) *volatile anyopaque {
        return rtc.event_register(event);
    }

    pub fn event_pending(rtc: Rtc, comptime event: Event) bool {
        return rtc.event_register(event).raw != 0;
    }

    pub fn clear_event(rtc: Rtc, comptime event: Event) void {
        const reg = rtc.event_register(event);
        reg.write_raw(0);
        // PS v1.11 §6.1.8, Interrupt clearing.
        _ = reg.raw;
    }

    /// Enable an event for polling or PPI, independently of IRQ delivery.
    pub fn set_event_enabled(rtc: Rtc, event: Event, enabled: bool) void {
        const r = rtc.regs();
        if (enabled) r.EVTENSET.write_raw(event.mask()) else r.EVTENCLR.write_raw(event.mask());
    }

    pub fn set_interrupt(rtc: Rtc, event: Event, enabled: bool) void {
        const r = rtc.regs();
        if (enabled) {
            r.INTENSET.write_raw(event.mask());
        } else {
            r.INTENCLR.write_raw(event.mask());
            _ = r.INTENCLR.raw;
        }
    }
};
