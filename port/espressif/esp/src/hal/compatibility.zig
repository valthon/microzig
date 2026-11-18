const std = @import("std");
const microzig = @import("microzig");

pub const Chip = enum {
    esp32_c3,
    esp32_c6,
};

pub const chip: Chip = blk: {
    if (std.mem.eql(u8, microzig.config.chip_name, "ESP32-C3")) {
        break :blk .esp32_c3;
    } else if (std.mem.eql(u8, microzig.config.chip_name, "ESP32-C6")) {
        break :blk .esp32_c6;
    } else {
        @compileError(std.fmt.comptimePrint("Unsupported chip for ESP HAL: \"{s}\"", .{microzig.config.chip_name}));
    }
};

/// Fails compilation when a HAL module that only drives ESP32-C3 registers is used on another
/// chip, instead of failing later on a missing or differently laid out register.
pub fn require_esp32_c3(comptime module: []const u8) void {
    if (@import("builtin").is_test) return;
    if (chip != .esp32_c3)
        @compileError(module ++ " drives ESP32-C3 registers only and is not ported to " ++ @tagName(chip));
}
