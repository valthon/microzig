const microzig = @import("microzig");
pub const peripherals = microzig.chip.peripherals;
const clocks = microzig.hal.clocks;

const GPIOA = peripherals.GPIOA;
const GPIOB = peripherals.GPIOB;
const GPIOC = peripherals.GPIOC;
const GPIOD = peripherals.GPIOD; // GPIOD has only 3 pins.

const GPIO = @TypeOf(GPIOA);

pub const Mode = union(enum) {
    input: InputMode,
    output: OutputMode,
};

pub const InputMode = enum(u2) {
    analog,
    floating,
    pull,
    reserved,
};

pub const OutputMode = enum(u2) {
    general_purpose_push_pull,
    general_purpose_open_drain,
    alternate_function_push_pull, // multiplexing_
    alternate_function_open_drain, // multiplexing_
};

pub const Speed = enum(u2) {
    reserved,
    max_10MHz,
    max_2MHz,
    max_50MHz,
};

// pub const DriveStrength = enum(u1) {
//     low,
//     high,
// };

pub const Pull = enum {
    up,
    down,
    disabled,
};

pub const AlternateFunctionMode = enum {
    push_pull,
    open_drain,
};

// NOTE: With this current setup, every time we want to do anythting we go through a switch
//       Do we want this?
// NOTE: How about to use port_config_mask, _value as previous apply function?
pub const Pin = packed struct(u8) {
    number: u4,
    port: u2,
    padding: u2 = 0,

    pub fn init(port: u2, number: u4) Pin {
        return Pin{
            .number = number,
            .port = port,
        };
    }

    inline fn config_offset(gpio: Pin) u5 {
        const index: u3 = @truncate(gpio.number);
        return @as(u5, index) << 2;
    }

    inline fn read_pin_config(gpio: Pin) u4 {
        const port = gpio.get_port();
        const config = if (gpio.number < 8) port.CFGLR.raw else port.CFGHR.raw;
        return @truncate(config >> gpio.config_offset());
    }

    inline fn write_pin_config(gpio: Pin, config: u32) void {
        const port = gpio.get_port();
        const offset = gpio.config_offset();
        const mask_bits = @as(u32, 0b1111) << offset;
        if (gpio.number < 8) {
            port.CFGLR.write_raw((port.CFGLR.raw & ~mask_bits) | (config << offset));
        } else {
            port.CFGHR.write_raw((port.CFGHR.raw & ~mask_bits) | (config << offset));
        }
    }

    fn mask(gpio: Pin) u16 {
        return @as(u16, 1) << gpio.number;
    }

    // NOTE: Im not sure I like this
    //       We could probably calculate an offset from GPIOA?
    pub fn get_port(gpio: Pin) GPIO {
        return switch (gpio.port) {
            0 => GPIOA,
            1 => GPIOB,
            2 => GPIOC,
            3 => GPIOD,
            // else => @panic("The CH32V[12]03 has only ports A..D"),
        };
    }

    pub fn get_block(gpio: Pin) clocks.GPIO_Block {
        return switch (gpio.port) {
            0 => .A,
            1 => .B,
            2 => .C,
            3 => .D,
        };
    }

    pub inline fn set_mode(gpio: Pin, mode: Mode) void {
        switch (mode) {
            .input => |in| gpio.set_input_mode(in),
            .output => |out| gpio.set_output_mode(out, .max_2MHz),
        }
    }

    pub inline fn set_input_mode(gpio: Pin, mode: InputMode) void {
        const m_mode = @as(u32, @backingInt(mode));
        const config: u32 = m_mode << 2;
        gpio.write_pin_config(config);
    }

    pub inline fn set_output_mode(gpio: Pin, mode: OutputMode, speed: Speed) void {
        const s_speed = @as(u32, @backingInt(speed));
        const m_mode = @as(u32, @backingInt(mode));
        const config: u32 = s_speed + (m_mode << 2);
        gpio.write_pin_config(config);
    }

    pub inline fn enable_clock(gpio: Pin) void {
        clocks.enable_gpio_clock(gpio.get_block());
    }

    /// Configure pin for alternate function use (e.g., USART, I2C, SPI)
    /// Combines enable_clock + set_output_mode for convenience
    pub inline fn configure_alternate_function(
        gpio: Pin,
        mode: AlternateFunctionMode,
        speed: Speed,
    ) void {
        gpio.enable_clock();
        switch (mode) {
            .push_pull => gpio.set_output_mode(.alternate_function_push_pull, speed),
            .open_drain => gpio.set_output_mode(.alternate_function_open_drain, speed),
        }
    }

    /// Apply pull to digital inputs. Other modes have no internal pull.
    pub inline fn set_pull(gpio: Pin, pull: Pull) void {
        gpio.try_set_pull(pull) catch return;
    }

    pub inline fn try_set_pull(gpio: Pin, pull: Pull) error{Unsupported}!void {
        const config = gpio.read_pin_config();
        const mode = (try input_mode_for_pull(config, pull)) orelse return;
        gpio.apply_input_pull(config, mode, pull);
    }

    /// Select digital input mode and apply the requested pull.
    pub inline fn set_input_pull(gpio: Pin, pull: Pull) void {
        const config = gpio.read_pin_config();
        const mode = input_mode_for_pull(config, pull) catch blk: {
            // Release the pin before writing the latch that selects up or down.
            gpio.set_input_mode(.floating);
            break :blk .pull;
        };
        gpio.apply_input_pull(config, mode orelse .floating, pull);
    }

    inline fn apply_input_pull(gpio: Pin, config: u4, mode: InputMode, pull: Pull) void {
        if (pull != .disabled) {
            const high = gpio.get_port().OUTDR.raw & gpio.mask() != 0;
            const want_high = pull == .up;
            if (high != want_high) gpio.put(@intFromBool(want_high));
        }
        if (config != @as(u4, @backingInt(mode)) << 2)
            gpio.set_input_mode(mode);
    }

    pub inline fn read(gpio: Pin) u1 {
        const port = gpio.get_port();
        return if (port.INDR.raw & gpio.mask() != 0)
            1
        else
            0;
    }

    pub inline fn put(gpio: Pin, value: u1) void {
        var port = gpio.get_port();
        switch (value) {
            // 0 => port.BSHR.raw = gpio.mask() << 16, // BR
            0 => port.BCR.raw = gpio.mask(), // clear, accessed only 16bit form
            1 => port.BSHR.raw = gpio.mask(), // BS
        }
    }

    pub inline fn toggle(gpio: Pin) void {
        var port = gpio.get_port();
        port.OUTDR.raw ^= gpio.mask(); // mask: 0 => stay, 1 => flip
    }
};

// CH32F/V20x_V30x_V31x RM §10.3.1.1–2: MODE selects input or output.
// Only the digital input configurations support switching the internal pull.
fn input_mode_for_pull(config: u4, pull: Pull) error{Unsupported}!?InputMode {
    if (config & 0b11 != 0) return no_pull_available(pull);
    const mode: InputMode = @fromBackingInt(@as(u2, @truncate(config >> 2)));
    return switch (mode) {
        .floating, .pull => if (pull == .disabled) .floating else .pull,
        .analog, .reserved => no_pull_available(pull),
    };
}

fn no_pull_available(pull: Pull) error{Unsupported}!?InputMode {
    if (pull != .disabled) return error.Unsupported;
    return null;
}

test "GPIO rejects explicit pulls outside digital input modes" {
    const testing = @import("std").testing;
    for (0..16) |raw| {
        const config: u4 = @intCast(raw);
        if (config == 0b0100 or config == 0b1000) continue;
        try testing.expectEqual(null, try input_mode_for_pull(config, .disabled));
        try testing.expectError(error.Unsupported, input_mode_for_pull(config, .up));
        try testing.expectError(error.Unsupported, input_mode_for_pull(config, .down));
    }
}

test "GPIO digital input can enable and disable pull" {
    const expect_equal = @import("std").testing.expectEqual;
    try expect_equal(InputMode.pull, (try input_mode_for_pull(0b0100, .up)).?);
    try expect_equal(InputMode.pull, (try input_mode_for_pull(0b0100, .down)).?);
    try expect_equal(InputMode.floating, (try input_mode_for_pull(0b1000, .disabled)).?);
}
