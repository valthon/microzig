//! C6 TRM v1.2 §7.5.4; C3 TRM, GPIO sigma-delta modulation.
//! The functional clock enable is shared by all four channels.
const microzig = @import("microzig");
const compatibility = @import("compatibility.zig");
const gpio = @import("gpio.zig");
const regs = switch (compatibility.chip) {
    .esp32_c3 => microzig.chip.peripherals.GPIOSD,
    .esp32_c6 => microzig.chip.peripherals.GPIO_SD,
};

pub fn enable(enabled: bool) void {
    regs.SIGMADELTA_MISC.modify(.{ .FUNCTION_CLK_EN = @intFromBool(enabled) });
}

pub fn channel(index: u2) Channel {
    return @fromBackingInt(@intCast(index));
}

pub const Channel = enum(u2) {
    channel0,
    channel1,
    channel2,
    channel3,

    /// Density is signed: -128 = 0%, 0 ≈ 50%, 127 ≈ 100%.
    /// Divider is the actual divisor, 1..256, not the register encoding.
    pub fn apply(self: Channel, density: i8, divider: u9) error{InvalidDivider}!void {
        if (divider == 0 or divider > 256) return error.InvalidDivider;
        if (comptime compatibility.chip == .esp32_c3) {
            self.get_regs().write(.{ .SD0_IN = @bitCast(density), .SD0_PRESCALE = @intCast(divider - 1) });
        } else {
            self.get_regs().write(.{ .SD_IN = @bitCast(density), .SD_PRESCALE = @intCast(divider - 1) });
        }
    }

    fn get_regs(self: Channel) *volatile @TypeOf(regs.SIGMADELTA0) {
        return switch (self) {
            .channel0 => &regs.SIGMADELTA0,
            .channel1 => @ptrCast(&regs.SIGMADELTA1),
            .channel2 => @ptrCast(&regs.SIGMADELTA2),
            .channel3 => @ptrCast(&regs.SIGMADELTA3),
        };
    }

    pub fn connect_pin(self: Channel, pin: gpio.Pin) void {
        const first: u8 = if (compatibility.chip == .esp32_c3) 55 else 83;
        pin.connect_peripheral_to_output(.{ .signal = @fromBackingInt(@intCast(first + @as(u8, @backingInt(self)))) });
    }
};
