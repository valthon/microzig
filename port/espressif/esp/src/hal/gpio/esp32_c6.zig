//! GPIO matrix and IO mux registers of the esp32c6.
//!
//! See section 7 of the Technical Reference Manual
//! https://www.espressif.com/sites/default/files/documentation/esp32-c6_technical_reference_manual_en.pdf
//!
//! The svd of this chip spells the per pad registers out one by one (PIN0, PIN1, ... and
//! FUNC0_IN_SEL_CFG, FUNC1_IN_SEL_CFG, ...) instead of describing them as an array, and it
//! repeats the pad index inside the field names. The registers are laid out consecutively, so
//! they are reached here through the first register of each block with a normalized type.

const std = @import("std");
const microzig = @import("microzig");
const peripherals = microzig.chip.peripherals;
const IO_MUX = peripherals.IO_MUX;
const GPIO = peripherals.GPIO;
const DriveStrength = @import("../gpio_encoding.zig").DriveStrength;

/// Number of usable pads, the pins are numbered 0 to `pin_count - 1`.
pub const pin_count = 31;

/// Integer holding one bit per pad.
pub const PinMask = u31;

/// Width of the pad bitmasks in the GPIO registers.
const RegMask = u32;

pub const InputSignal = enum(u8) {
    pcnt_unit0_channel0 = 101,
    pcnt_unit1_channel0 = 105,
    pcnt_unit2_channel0 = 109,
    pcnt_unit3_channel0 = 113,

    u0rxd = 6,
    u0cts = 7,
    u0dsr = 8,
    u1rxd = 9,
    u1cts = 10,
    u1dsr = 11,

    i2s_mclk = 12,
    i2so_bck = 13,
    i2so_ws = 14,
    i2si_sd = 15,
    i2si_bck = 16,
    i2si_ws = 17,

    cpu_gpio0 = 28,
    cpu_gpio1 = 29,
    cpu_gpio2 = 30,
    cpu_gpio3 = 31,
    cpu_gpio4 = 32,
    cpu_gpio5 = 33,
    cpu_gpio6 = 34,
    cpu_gpio7 = 35,

    i2cext0_scl = 45,
    i2cext0_sda = 46,

    /// Tied to a constant one by the gpio matrix.
    const_high = 56,
    /// Tied to a constant zero by the gpio matrix.
    const_low = 60,

    parl_data0 = 47,
    parl_data1 = 48,
    parl_data2 = 49,
    parl_data3 = 50,
    parl_data4 = 51,
    parl_data5 = 52,
    parl_data6 = 53,
    parl_data7 = 54,
    parl_data15 = 62,

    fspiclk = 63,
    fspiq = 64,
    fspid = 65,
    fspihd = 66,
    fspiwp = 67,
    fspics0 = 68,

    parl_rx_clk = 69,

    rmt_sig0 = 71,
    rmt_sig1 = 72,

    twai0_rx = 73,
    twai1_rx = 77,

    sig_in_func_97 = 97,
    sig_in_func_98 = 98,
    sig_in_func_99 = 99,
    sig_in_func_100 = 100,

    /// Changes inversion by peripheral signal index, preserving its pad routing.
    pub fn set_input_invert(self: InputSignal, invert: bool) void {
        set_input_signal_invert(@backingInt(self), invert);
    }

    pub const always_low: InputSignal = .const_low;
    pub const always_high: InputSignal = .const_high;
};

pub const OutputSignal = enum(u8) {
    mcpwm0_a = 87,
    mcpwm0_b = 88,
    sigma_delta0 = 83,
    sigma_delta1 = 84,
    sigma_delta2 = 85,
    sigma_delta3 = 86,

    ledc_ls_sig0 = 0,
    ledc_ls_sig1 = 1,
    ledc_ls_sig2 = 2,
    ledc_ls_sig3 = 3,
    ledc_ls_sig4 = 4,
    ledc_ls_sig5 = 5,

    u0txd = 6,
    u0rts = 7,
    u0dtr = 8,
    u1txd = 9,
    u1rts = 10,
    u1dtr = 11,

    i2s_mclk = 12,
    i2so_bck = 13,
    i2so_ws = 14,
    i2si_sd = 15,
    i2si_bck = 16,
    i2si_ws = 17,

    cpu_gpio0 = 28,
    cpu_gpio1 = 29,
    cpu_gpio2 = 30,
    cpu_gpio3 = 31,
    cpu_gpio4 = 32,
    cpu_gpio5 = 33,
    cpu_gpio6 = 34,
    cpu_gpio7 = 35,

    usb_jtag_tck = 36,
    usb_jtag_tms = 37,
    usb_jtag_tdi = 38,
    usb_jtag_tdo = 39,

    i2cext0_scl = 45,
    i2cext0_sda = 46,

    parl_data0 = 47,
    parl_data1 = 48,
    parl_data2 = 49,
    parl_data3 = 50,
    parl_data4 = 51,
    parl_data5 = 52,
    parl_data6 = 53,
    parl_data7 = 54,
    parl_data15 = 62,

    fspiclk = 63,
    fspiq = 64,
    fspid = 65,
    fspihd = 66,
    fspiwp = 67,
    fspics0 = 68,
    fspics1 = 69,
    fspics2 = 70,

    rmt_sig0 = 71,
    rmt_sig1 = 72,

    twai0_tx = 73,
    twai0_bus_off_on = 74,
    twai0_clk_out = 75,
    twai0_standby = 76,
    twai1_tx = 77,
    twai1_bus_off_on = 78,
    twai1_clk_out = 79,
    twai1_standby = 80,

    ant_sel0 = 89,
    ant_sel1 = 90,
    ant_sel2 = 91,
    ant_sel3 = 92,
    ant_sel4 = 93,
    ant_sel5 = 94,
    ant_sel6 = 95,
    ant_sel7 = 96,

    sig_in_func_97 = 97,
    sig_in_func_98 = 98,
    sig_in_func_99 = 99,
    sig_in_func_100 = 100,

    clk_out1 = 123,
    clk_out2 = 124,
    clk_out3 = 125,

    gpio = 128,
    /// C6 TRM table 7.11-1: PARL TX clock is matrix signal 70.
    pub const parl_tx_clk: @This() = .fspics2;
};

/// C6 TRM v1.2 §7.16.2, IO_MUX_GPIOn_REG: 0/1/2/3 select 5/10/20/40 mA.
/// The esp32c6 maps every drive strength straight onto its register value, there are no pads
/// with a swapped 10 mA / 20 mA setting like on the esp32c3.
pub fn drive_strength_value(pin: u5, strength: DriveStrength) u2 {
    _ = pin;
    return switch (strength) {
        .@"5mA" => 0,
        .@"10mA" => 1,
        .@"20mA" => 2,
        .@"40mA" => 3,
    };
}

/// Assert that the USB_SERIAL_JTAG peripheral, which uses pins GPIO12 and GPIO13, is disabled
/// and that the USB pullup/down resistors are disabled.
pub fn assert_usb_disabled(pin: u5) void {
    if (pin == 12 or pin == 13) {
        const usb_conf0 = peripherals.USB_DEVICE.CONF0.read();
        std.debug.assert(usb_conf0.USB_PAD_ENABLE == 0 and
            usb_conf0.DP_PULLUP == 0 and
            usb_conf0.DP_PULLDOWN == 0 and
            usb_conf0.DM_PULLUP == 0 and
            usb_conf0.DM_PULLDOWN == 0);
    }
}

// All pad blocks have a four-byte stride. Reuse the first generated type
// for each block instead of redeclaring its bit positions (TRM §7.16).
const IoMux = @TypeOf(IO_MUX.GPIO0);
const PinCfg = @TypeOf(GPIO.PIN0);
const FuncInSel = @TypeOf(GPIO.FUNC0_IN_SEL_CFG);
const FuncOutSel = @TypeOf(GPIO.FUNC0_OUT_SEL_CFG);

fn reg(comptime T: type, first: anytype, index: usize) *volatile T {
    return @ptrFromInt(@intFromPtr(first) + @sizeOf(u32) * index);
}

fn io_mux(pin: u5) *volatile IoMux {
    return reg(IoMux, &IO_MUX.GPIO0, pin);
}

fn pin_cfg(pin: u5) *volatile PinCfg {
    return reg(PinCfg, &GPIO.PIN0, pin);
}

fn func_in_sel(signal: u8) *volatile FuncInSel {
    return reg(FuncInSel, &GPIO.FUNC0_IN_SEL_CFG, signal);
}

fn func_out_sel(pin: u5) *volatile FuncOutSel {
    return reg(FuncOutSel, &GPIO.FUNC0_OUT_SEL_CFG, pin);
}

// C6 TRM v1.2 §§7.7.1–7.7.2: GPIO0–7 bypass the HP IO MUX and
// GPIO matrix while their LP_AON_GPIO_MUX_SEL bit is set.
fn select_hp_mux(pin: u5) void {
    if (pin >= 8) return;
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    const mux = peripherals.LP_AON.GPIO_MUX.read();
    peripherals.LP_AON.GPIO_MUX.modify(.{ .SEL = mux.SEL & ~(@as(u8, 1) << @as(u3, @intCast(pin))) });
}

pub fn set_mux(pin: u5, options: struct {
    pull_down: bool,
    pull_up: bool,
    drive_strength: u2,
    input_enable: bool,
    function: u3,
    input_filter_enable: bool,
}) void {
    select_hp_mux(pin);
    io_mux(pin).modify(.{
        .SLP_SEL = 0,
        .FUN_WPD = @intFromBool(options.pull_down),
        .FUN_WPU = @intFromBool(options.pull_up),
        .FUN_DRV = options.drive_strength,
        .FUN_IE = @intFromBool(options.input_enable),
        .MCU_SEL = options.function,
        .FILTER_EN = @intFromBool(options.input_filter_enable),
    });
}

pub fn set_pull(pin: u5, pull_down: bool, pull_up: bool) void {
    io_mux(pin).modify(.{
        .FUN_WPD = @intFromBool(pull_down),
        .FUN_WPU = @intFromBool(pull_up),
    });
}

pub fn set_drive_strength(pin: u5, value: u2) void {
    io_mux(pin).modify(.{ .FUN_DRV = value });
}

pub fn set_input_enabled(pin: u5, enable: bool) void {
    io_mux(pin).modify(.{ .FUN_IE = @intFromBool(enable) });
}

pub fn get_input_enabled(pin: u5) bool {
    return io_mux(pin).read().FUN_IE == 1;
}

pub fn set_input_filter_enabled(pin: u5, enable: bool) void {
    io_mux(pin).modify(.{ .FILTER_EN = @intFromBool(enable) });
}

pub fn set_open_drain(pin: u5, open_drain: bool) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    pin_cfg(pin).modify(.{ .PAD_DRIVER = @intFromBool(open_drain) });
}

// Preserve inversion and output-enable selection, as Pin.apply did before
// the chip split. Complete peripheral routing is configured separately.
pub fn select_gpio_output(pin: u5) void {
    select_hp_mux(pin);
    func_out_sel(pin).modify(.{ .FUNC_OUT_SEL = @backingInt(OutputSignal.gpio) });
}

pub fn set_output_signal(pin: u5, options: struct {
    signal: u8,
    invert: bool = false,
    output_enable_signal_controlled_by_peripheral: bool = false,
    invert_output_enable_signal: bool = false,
}) void {
    select_hp_mux(pin);
    func_out_sel(pin).write(.{
        .FUNC_OUT_SEL = options.signal,
        .FUNC_OEN_SEL = @intFromBool(!options.output_enable_signal_controlled_by_peripheral),
        .FUNC_OUT_INV_SEL = @intFromBool(options.invert),
        .FUNC_OEN_INV_SEL = @intFromBool(options.invert_output_enable_signal),
        .padding = 0,
    });
}

pub fn get_output_routing(pin: u5) u32 {
    return func_out_sel(pin).raw;
}

pub fn set_output_routing(pin: u5, raw: u32) void {
    select_hp_mux(pin);
    func_out_sel(pin).write_raw(raw);
}

pub fn set_output_invert(pin: u5, invert: bool) void {
    func_out_sel(pin).modify(.{ .FUNC_OUT_INV_SEL = @intFromBool(invert) });
}

pub fn set_input_signal(signal: u8, pin: u5, invert: bool) void {
    select_hp_mux(pin);
    func_in_sel(signal).write(.{
        .FUNC0_IN_SEL = pin,
        .FUNC0_IN_INV_SEL = @intFromBool(invert),
        .SIG0_IN_SEL = 1,
        .padding = 0,
    });
}

pub fn set_input_signal_invert(signal: u8, invert: bool) void {
    func_in_sel(signal).modify(.{ .FUNC0_IN_INV_SEL = @intFromBool(invert) });
}

pub fn set_output_enabled(pin: u5, enable: bool) void {
    if (enable) {
        GPIO.ENABLE_W1TS.write(.{ .ENABLE_W1TS = @as(RegMask, 1) << pin });
    } else {
        GPIO.ENABLE_W1TC.write(.{ .ENABLE_W1TC = @as(RegMask, 1) << pin });
    }
}

pub fn put(pin: u5, level: u1) void {
    switch (level) {
        0 => GPIO.OUT_W1TC.write(.{ .OUT_W1TC = @as(RegMask, 1) << pin }),
        1 => GPIO.OUT_W1TS.write(.{ .OUT_W1TS = @as(RegMask, 1) << pin }),
    }
}

pub fn read(pin: u5) u1 {
    return @intCast((GPIO.IN.raw >> pin) & 1);
}

test "drive strength encoding for every C6 GPIO" {
    for (0..pin_count) |n| {
        const strengths = .{ .@"5mA", .@"10mA", .@"20mA", .@"40mA" };
        inline for (strengths, 0..) |strength, value| {
            try std.testing.expectEqual(@as(u2, value), drive_strength_value(@intCast(n), strength));
        }
    }
}

// C6 TRM §7.16.1: PINn selects the trigger and maskable CPU route;
// STATUS_W1TC clears only the written pins. Serialize PINn read-modify-writes
// with set_open_drain, which shares this register with interrupt handlers.
pub fn set_interrupt_type(pin: u5, event: u3) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    pin_cfg(pin).modify(.{ .INT_TYPE = event });
}

pub fn set_interrupt_enabled(pin: u5, enable: bool) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    // INT_ENA bit 0 is the maskable route; leave the NMI route untouched.
    const old = pin_cfg(pin).read().INT_ENA;
    pin_cfg(pin).modify(.{ .INT_ENA = (old & ~@as(u5, 1)) | @as(u5, @intFromBool(enable)) });
}

pub fn interrupt_status(pin: u5) bool {
    return (GPIO.STATUS.read().INTERRUPT & (@as(RegMask, 1) << pin)) != 0;
}

pub fn clear_interrupt(pin: u5) void {
    GPIO.STATUS_W1TC.write(.{ .STATUS_W1TC = @as(RegMask, 1) << pin });
}
