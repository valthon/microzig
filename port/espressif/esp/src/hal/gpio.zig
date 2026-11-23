//! GPIO and pin configuration
//!
//! The GPIO matrix and IO mux allows input from any pin to be routed to any peripheral, and any
//! peripheral output to be routed to any pin.
//!
//! The registers behind this differ between chips, see `gpio/<chip>.zig`.
//!
const std = @import("std");

const compatibility = @import("compatibility.zig");

/// Number of usable pads. The pins are numbered 0 to `pin_count - 1`.
pub const pin_count = chip_specific.pin_count;

/// Peripheral signals that can be routed onto a pin.
pub const InputSignal = chip_specific.InputSignal;

/// Peripheral output signals that can be routed onto a pin.
pub const OutputSignal = chip_specific.OutputSignal;

/// Feed a peripheral input a constant level through the GPIO matrix instead of a pad.
/// The signal stays detached from any pad until explicitly re-routed.
pub fn connect_constant_to_peripheral(signal: InputSignal, level: u1) void {
    chip_specific.set_input_constant(@backingInt(signal), level);
}

/// Pad drive strength. The register encoding is chip specific, see
/// `gpio/<chip>.zig` `drive_strength_value`.
pub const DriveStrength = @import("gpio_encoding.zig").DriveStrength;

/// Alternative pin functions
pub const AlternateFunction = enum(u3) {
    function0 = 0,
    function1 = 1,
    function2 = 2,
    function3 = 3,
};

/// Interrupt events
pub const Event = enum(u3) {
    disabled = 0,
    rising_edge = 1,
    falling_edge = 2,
    any_edge = 3,
    low_level = 4,
    high_level = 5,
};

pub const Pull = enum {
    up,
    down,
    disabled,
};

pub const Mask = enum(chip_specific.PinMask) {
    _,
};

pub fn num(n: u5) Pin {
    std.debug.assert(n < pin_count);
    return @fromBackingInt(n);
}

pub const Pin = enum(u5) {
    _,

    pub const Config = struct {
        output_enable: bool = false,
        input_enable: bool = false,
        open_drain: bool = false,
        pull: Pull = .disabled,
        drive_strength: DriveStrength = .@"5mA",
        input_filter_enable: bool = false,

        pub const analog: Config = .{
            .output_enable = false,
            .input_enable = false,
            .pull = .disabled,
        };
    };

    fn assert_usb_disabled(self: Pin) void {
        chip_specific.assert_usb_disabled(@backingInt(self));
    }

    pub fn apply(self: Pin, config: Config) void {
        self.assert_usb_disabled();

        const n = @backingInt(self);

        chip_specific.select_gpio_output(n);

        chip_specific.set_mux(n, .{
            .pull_down = config.pull == .down,
            .pull_up = config.pull == .up,
            .drive_strength = chip_specific.drive_strength_value(n, config.drive_strength),
            .input_enable = config.input_enable,
            .function = @backingInt(AlternateFunction.function1),
            .input_filter_enable = config.input_filter_enable,
        });

        chip_specific.set_open_drain(n, config.open_drain);
        chip_specific.set_output_enabled(n, config.output_enable);
    }

    pub const ConnectToOutputOptions = struct {
        signal: OutputSignal,
        invert: bool = false,
        output_enable_signal_controlled_by_peripheral: bool = false,
        invert_output_enable_signal: bool = false,
    };

    // TODO: bypass gpio matrix
    pub fn connect_peripheral_to_output(self: Pin, options: ConnectToOutputOptions) void {
        self.assert_usb_disabled();

        chip_specific.set_output_signal(@backingInt(self), .{
            .signal = @backingInt(options.signal),
            .invert = options.invert,
            .output_enable_signal_controlled_by_peripheral = options.output_enable_signal_controlled_by_peripheral,
            .invert_output_enable_signal = options.invert_output_enable_signal,
        });
    }

    /// Raw GPIO matrix output routing (FUNC_OUT_SEL_CFG) of a pad, saved by code that borrows
    /// the pad as a GPIO and restores the peripheral routing afterwards.
    pub const OutputRouting = struct { raw: u32 };

    pub fn get_output_routing(self: Pin) OutputRouting {
        return .{ .raw = chip_specific.get_output_routing(@backingInt(self)) };
    }

    pub fn restore_output_routing(self: Pin, routing: OutputRouting) void {
        chip_specific.set_output_routing(@backingInt(self), routing.raw);
    }

    pub const ConnectToInputOptions = struct {
        signal: InputSignal,
        invert: bool = false,
    };

    // TODO: bypass gpio matrix
    pub fn connect_input_to_peripheral(self: Pin, options: ConnectToInputOptions) void {
        self.assert_usb_disabled();

        chip_specific.set_input_signal(@backingInt(options.signal), @backingInt(self), options.invert);
    }

    pub fn set_output_enabled(self: Pin, enable: bool) void {
        chip_specific.set_output_enabled(@backingInt(self), enable);
    }

    pub fn set_output_invert(self: Pin, invert: bool) void {
        chip_specific.set_output_invert(@backingInt(self), invert);
    }

    pub fn set_input_enabled(self: Pin, enable: bool) void {
        chip_specific.set_input_enabled(@backingInt(self), enable);
    }

    pub fn set_input_filter_enabled(self: Pin, enable: bool) void {
        chip_specific.set_input_filter_enabled(@backingInt(self), enable);
    }

    pub fn set_pull(self: Pin, pull: Pull) void {
        chip_specific.set_pull(@backingInt(self), pull == .down, pull == .up);
    }

    pub fn set_drive_strength(self: Pin, drive_strength: DriveStrength) void {
        chip_specific.set_drive_strength(@backingInt(self), chip_specific.drive_strength_value(@backingInt(self), drive_strength));
    }

    pub fn set_open_drain(self: Pin, open_drain: bool) void {
        chip_specific.set_open_drain(@backingInt(self), open_drain);
    }

    /// Select the trigger independently of CPU interrupt delivery. Enable the
    /// input buffer first. Route `.gpio` with `microzig.cpu.interrupt.map` to
    /// a level-type CPU interrupt and install its handler in microzig_options.
    pub fn set_interrupt_type(self: Pin, event: Event) void {
        chip_specific.set_interrupt_type(@backingInt(self), @backingInt(event));
    }

    /// Enable maskable CPU delivery for this pin, preserving its trigger type.
    /// Does not clear latched status. Disable and clear before reconfiguring
    /// if old events must be discarded.
    pub fn set_interrupt_enabled(self: Pin, enable: bool) void {
        chip_specific.set_interrupt_enabled(@backingInt(self), enable);
    }

    /// Raw latched status, independent of CPU delivery enable.
    pub fn interrupt_status(self: Pin) bool {
        return chip_specific.interrupt_status(@backingInt(self));
    }

    /// Clear only this pin's latched status (write-one-to-clear). A level
    /// trigger must be deasserted or disabled before clearing to avoid reentry.
    pub fn clear_interrupt(self: Pin) void {
        chip_specific.clear_interrupt(@backingInt(self));
    }

    pub fn put(self: Pin, level: u1) void {
        chip_specific.put(@backingInt(self), level);
    }

    pub fn read(self: Pin) u1 {
        std.debug.assert(chip_specific.get_input_enabled(@backingInt(self)));

        return chip_specific.read(@backingInt(self));
    }

    pub fn toggle(self: Pin) void {
        switch (self.read()) {
            0 => self.put(1),
            1 => self.put(0),
        }
    }
};

const chip_specific = switch (compatibility.chip) {
    .esp32_c3 => @import("gpio/esp32_c3.zig"),
    .esp32_c6 => @import("gpio/esp32_c6.zig"),
};
