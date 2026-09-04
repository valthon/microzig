const std = @import("std");

pub const DriveStrength = enum {
    @"5mA",
    @"10mA",
    @"20mA",
    @"40mA",

    /// IO_MUX_GPIOn_FUN_DRV value of this drive strength for an esp32c3 pad.
    /// ESP32-C3 TRM v1.4 section 5.12, Drive Strength note under Table 5.12-1.
    pub fn to_esp32_c3_value(strength: DriveStrength, pin: u5) u2 {
        return switch (pin) {
            2, 3, 4, 5, 18, 19 => switch (strength) {
                .@"5mA" => 0,
                .@"10mA" => 2,
                .@"20mA" => 1,
                .@"40mA" => 3,
            },
            else => switch (strength) {
                .@"5mA" => 0,
                .@"10mA" => 1,
                .@"20mA" => 2,
                .@"40mA" => 3,
            },
        };
    }
};

test "drive strength encoding for every esp32c3 GPIO" {
    for (0..22) |n| {
        const pin: u5 = @intCast(n);
        const expected: [4]u2 = switch (n) {
            2, 3, 4, 5, 18, 19 => .{ 0, 2, 1, 3 },
            else => .{ 0, 1, 2, 3 },
        };
        for (std.enums.values(DriveStrength), expected) |strength, value| {
            try std.testing.expectEqual(value, strength.to_esp32_c3_value(pin));
        }
    }
}
