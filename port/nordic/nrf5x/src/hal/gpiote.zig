//! nRF52840 GPIOTE (Product Specification v1.11, §6.10).
const microzig = @import("microzig");
const gpio = @import("gpio.zig");
const compatibility = @import("compatibility.zig");
const Regs = microzig.chip.types.peripherals.GPIOTE;
const EventRegister = @typeInfo(@FieldType(Regs, "EVENTS_IN")).array.child;

pub const interrupt: microzig.cpu.Interrupt = .GPIOTE;
pub const Edge = enum { rising, falling, toggle };
pub const OutAction = enum { set, clear, toggle };

fn regs() *volatile Regs {
    if (compatibility.chip != .nrf52840) compatibility.unsupported_chip("GPIOTE");
    return microzig.chip.peripherals.GPIOTE;
}

pub const Channel = enum(u3) {
    _,

    /// Event mode overrides GPIO direction. Connect the pin's input buffer first.
    /// Keep signal edges at least 1.3 µs apart and periodic signals below 750 kHz
    /// when routing IN events to tasks. On affected nRF52840 silicon (anomaly 155),
    /// faster edges can trigger a task twice.
    pub fn configure_event(channel: Channel, pin: gpio.Pin, edge: Edge) error{ InvalidPin, PinInUse }!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        try channel.check_pin(pin);
        channel.disable();
        regs().CONFIG[@backingInt(channel)].write(.{
            .MODE = .Event,
            .PSEL = pin.index(),
            .PORT = pin.port(),
            .POLARITY = switch (edge) {
                .rising => .LoToHi,
                .falling => .HiToLo,
                .toggle => .Toggle,
            },
        });
    }

    /// Task mode drives the pin from OUTINIT until a task runs.
    pub fn configure_task(channel: Channel, pin: gpio.Pin, action: OutAction, initial: u1) error{ InvalidPin, PinInUse }!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        try channel.check_pin(pin);
        channel.disable();
        regs().CONFIG[@backingInt(channel)].write(.{
            .MODE = .Task,
            .PSEL = pin.index(),
            .PORT = pin.port(),
            .POLARITY = switch (action) {
                .set => .LoToHi,
                .clear => .HiToLo,
                .toggle => .Toggle,
            },
            .OUTINIT = if (initial == 0) .Low else .High,
        });
    }

    fn check_pin(channel: Channel, pin: gpio.Pin) error{ InvalidPin, PinInUse }!void {
        if (pin.port() == 1 and pin.index() >= 16) return error.InvalidPin;
        // PS v1.11 §6.10.3 allows only one channel per pin.
        for (&regs().CONFIG, 0..) |*config, index| {
            if (index == @backingInt(channel)) continue;
            const value = config.read();
            if (value.MODE != .Disabled and value.PORT == pin.port() and value.PSEL == pin.index())
                return error.PinInUse;
        }
    }

    /// Return the pin to GPIO control and clear the channel IRQ and event.
    pub fn disable(channel: Channel) void {
        channel.set_interrupt(false);
        regs().CONFIG[@backingInt(channel)].write(.{});
        channel.clear_event();
    }

    pub fn event_endpoint(channel: Channel) *volatile EventRegister {
        return &regs().EVENTS_IN[@backingInt(channel)];
    }

    pub fn event_pending(channel: Channel) bool {
        return channel.event_endpoint().raw != 0;
    }

    pub fn clear_event(channel: Channel) void {
        const event = channel.event_endpoint();
        event.write_raw(0);
        // PS v1.11 §6.1.8, Interrupt clearing.
        _ = event.raw;
    }

    pub fn set_interrupt(channel: Channel, enabled: bool) void {
        const Bits = @FieldType(Regs, "INTENSET").underlying_type;
        const mask = @as(u32, 1 << @bitOffsetOf(Bits, "IN0")) << @backingInt(channel);
        set_interrupt_mask(mask, enabled);
    }

    pub const Task = enum { out, set, clear };

    pub fn trigger(channel: Channel, task: Task) void {
        const i = @backingInt(channel);
        const r = regs();
        switch (task) {
            .out => r.TASKS_OUT[i].write_raw(1),
            .set => r.TASKS_SET[i].write_raw(1),
            .clear => r.TASKS_CLR[i].write_raw(1),
        }
    }

    pub fn task_endpoint(channel: Channel, task: Task) *volatile anyopaque {
        const i = @backingInt(channel);
        const r = regs();
        return switch (task) {
            .out => &r.TASKS_OUT[i],
            .set => &r.TASKS_SET[i],
            .clear => &r.TASKS_CLR[i],
        };
    }
};

/// PORT is raised on the rising edge of GPIO DETECT (§6.10.2).
pub fn port_endpoint() *volatile @FieldType(Regs, "EVENTS_PORT") {
    return &regs().EVENTS_PORT;
}

pub fn port_pending() bool {
    return port_endpoint().raw != 0;
}

pub fn clear_port() void {
    const event = port_endpoint();
    event.write_raw(0);
    _ = event.raw;
}

/// Disable the interrupt before configuring GPIO SENSE, then clear PORT before
/// enabling the interrupt again (§6.10.2).
pub fn set_port_interrupt(enabled: bool) void {
    const Bits = @FieldType(Regs, "INTENSET").underlying_type;
    set_interrupt_mask(1 << @bitOffsetOf(Bits, "PORT"), enabled);
}

fn set_interrupt_mask(mask: u32, enabled: bool) void {
    const r = regs();
    if (enabled) {
        r.INTENSET.write_raw(mask);
    } else {
        r.INTENCLR.write_raw(mask);
        _ = r.INTENCLR.raw;
    }
}
