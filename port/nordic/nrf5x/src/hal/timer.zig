//! nRF52840 TIMER peripheral (Product Specification v1.11, §6.30).
const std = @import("std");
const microzig = @import("microzig");
const compatibility = @import("compatibility.zig");
const peripherals = microzig.chip.peripherals;
const Regs = microzig.chip.types.peripherals.TIMER0;

pub const Config = struct {
    mode: enum { timer, counter } = .timer,
    width: enum { bits8, bits16, bits24, bits32 } = .bits32,
    prescaler: u4 = 4,
};

pub const Shortcuts = struct {
    clear: bool = false,
    stop: bool = false,
};

pub const Timer = enum {
    timer0,
    timer1,
    timer2,
    timer3,
    timer4,

    fn regs(timer: Timer) *volatile Regs {
        if (compatibility.chip != .nrf52840) compatibility.unsupported_chip("TIMER");
        return switch (timer) {
            .timer0 => peripherals.TIMER0,
            .timer1 => peripherals.TIMER1,
            .timer2 => peripherals.TIMER2,
            .timer3 => peripherals.TIMER3,
            .timer4 => peripherals.TIMER4,
        };
    }

    pub fn interrupt(comptime timer: Timer) microzig.cpu.Interrupt {
        return switch (timer) {
            .timer0 => .TIMER0,
            .timer1 => .TIMER1,
            .timer2 => .TIMER2,
            .timer3 => .TIMER3,
            .timer4 => .TIMER4,
        };
    }

    fn channel_index(comptime timer: Timer, comptime channel: u3) usize {
        const count_limit = switch (timer) {
            .timer0, .timer1, .timer2 => 4,
            .timer3, .timer4 => 6,
        };
        if (channel >= count_limit) @compileError("invalid TIMER capture/compare channel");
        return channel;
    }

    /// Configure a stopped timer. The tick rate in timer mode is 16 MHz / 2^prescaler.
    pub fn apply(timer: Timer, config: Config) error{InvalidPrescaler}!void {
        if (config.prescaler > 9) return error.InvalidPrescaler;
        const r = timer.regs();
        r.MODE.write(.{ .MODE = switch (config.mode) {
            .timer => .Timer,
            .counter => .LowPowerCounter,
        } });
        r.BITMODE.write(.{ .BITMODE = switch (config.width) {
            .bits8 => .@"08Bit",
            .bits16 => .@"16Bit",
            .bits24 => .@"24Bit",
            .bits32 => .@"32Bit",
        } });
        r.PRESCALER.write(.{ .PRESCALER = config.prescaler });
    }

    pub fn start(timer: Timer) void {
        timer.regs().TASKS_START.write_raw(1);
    }

    /// On affected nRF52840 silicon (anomaly 78), STOP alone leaves excess
    /// current. For low-power shutdown, trigger the TIMER's TASKS_SHUTDOWN.
    pub fn stop(timer: Timer) void {
        timer.regs().TASKS_STOP.write_raw(1);
    }

    pub fn clear(timer: Timer) void {
        timer.regs().TASKS_CLEAR.write_raw(1);
    }

    pub fn count(timer: Timer) void {
        timer.regs().TASKS_COUNT.write_raw(1);
    }

    /// Capture overwrites the channel's compare value.
    pub fn capture(comptime timer: Timer, comptime channel: u3) u32 {
        const i = comptime timer.channel_index(channel);
        const r = timer.regs();
        r.TASKS_CAPTURE[i].write_raw(1);
        return r.CC[i].read().CC;
    }

    /// Hardware uses the low bits selected by BITMODE.
    pub fn set_compare(comptime timer: Timer, comptime channel: u3, value: u32) void {
        timer.regs().CC[comptime timer.channel_index(channel)].write(.{ .CC = value });
    }

    pub fn compare_endpoint(comptime timer: Timer, comptime channel: u3) *volatile @typeInfo(@FieldType(Regs, "EVENTS_COMPARE")).array.child {
        return &timer.regs().EVENTS_COMPARE[comptime timer.channel_index(channel)];
    }

    pub fn compare_pending(comptime timer: Timer, comptime channel: u3) bool {
        return timer.compare_endpoint(channel).raw != 0;
    }

    pub fn clear_compare(comptime timer: Timer, comptime channel: u3) void {
        const event = timer.compare_endpoint(channel);
        event.write_raw(0);
        // PS v1.11 §6.1, Interrupt clearing.
        _ = event.raw;
    }

    pub fn set_compare_interrupt(comptime timer: Timer, comptime channel: u3, enabled: bool) void {
        const field = comptime std.fmt.comptimePrint("COMPARE{d}", .{timer.channel_index(channel)});
        const r = timer.regs();
        const mask = 1 << @bitOffsetOf(@TypeOf(r.INTENSET).underlying_type, field);
        if (enabled) {
            r.INTENSET.write_raw(mask);
        } else {
            r.INTENCLR.write_raw(mask);
            _ = r.INTENCLR.raw;
        }
    }

    /// With the STOP shortcut, also trigger TASKS_SHUTDOWN after the timer
    /// has stopped if low current is required (nRF52840 anomaly 78).
    pub fn set_shortcuts(comptime timer: Timer, comptime channel: u3, shortcuts: Shortcuts) void {
        const i = comptime timer.channel_index(channel);
        const clear_field = comptime std.fmt.comptimePrint("COMPARE{d}_CLEAR", .{i});
        const stop_field = comptime std.fmt.comptimePrint("COMPARE{d}_STOP", .{i});
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();

        const r = timer.regs();
        var value = r.SHORTS.read();
        @field(value, clear_field) = if (shortcuts.clear) .Enabled else .Disabled;
        @field(value, stop_field) = if (shortcuts.stop) .Enabled else .Disabled;
        r.SHORTS.write(value);
    }
};
