//! ESP32-C6 TRM v1.2 §§7.7, 7.13, 7.16.4. GPIO0–7 only.
//! Usable from HP or LP; one core must own pad/mux configuration at a time.
//! Pad holds must be released by the application before changing a held pad.
const std = @import("std");
const microzig = @import("microzig");
const p = microzig.chip.peripherals;

pub const Config = struct {
    input: bool = true,
    output: bool = false,
    initial_level: u1 = 0,
    open_drain: bool = false,
    pull: enum { none, up, down } = .none,
    function: enum(u3) { gpio = 0, peripheral = 1 } = .gpio,
};

pub fn apply(comptime pin: u3, config: Config) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    // Preload before enabling the output to avoid a spurious transition.
    put(pin, config.initial_level);
    @field(p.LP_IO, std.fmt.comptimePrint("PIN{d}", .{pin})).modify(.{ .PAD_DRIVER = @intFromBool(config.open_drain) });
    @field(p.LP_IO, std.fmt.comptimePrint("GPIO{d}", .{pin})).modify(.{
        .MCU_SEL = @backingInt(config.function),
        .SLP_SEL = 0,
        .FUN_IE = @intFromBool(config.input),
        .FUN_WPU = @intFromBool(config.pull == .up),
        .FUN_WPD = @intFromBool(config.pull == .down),
    });
    if (config.output) {
        p.LP_IO.OUT_ENABLE_W1TS.write(.{ .ENABLE_W1TS = @as(u8, 1) << pin });
    } else {
        p.LP_IO.OUT_ENABLE_W1TC.write(.{ .ENABLE_W1TC = @as(u8, 1) << pin });
    }
    const mux = p.LP_AON.GPIO_MUX.read().SEL;
    p.LP_AON.GPIO_MUX.modify(.{ .SEL = mux | (@as(u8, 1) << pin) });
}

pub fn put(pin: u3, level: u1) void {
    if (level != 0) {
        p.LP_IO.OUT_DATA_W1TS.write(.{ .OUT_DATA_W1TS = @as(u8, 1) << pin });
    } else {
        p.LP_IO.OUT_DATA_W1TC.write(.{ .OUT_DATA_W1TC = @as(u8, 1) << pin });
    }
}

pub fn read(pin: u3) u1 {
    return @truncate(p.LP_IO.IN.read().DATA_NEXT >> pin);
}

/// Return a pad to the HP IO MUX; configure its HP function separately.
pub fn release(pin: u3) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    p.LP_IO.OUT_ENABLE_W1TC.write(.{ .ENABLE_W1TC = @as(u8, 1) << pin });
    const mux = p.LP_AON.GPIO_MUX.read().SEL;
    p.LP_AON.GPIO_MUX.modify(.{ .SEL = mux & ~(@as(u8, 1) << pin) });
}
