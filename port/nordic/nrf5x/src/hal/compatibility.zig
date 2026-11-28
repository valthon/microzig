const std = @import("std");
const builtin = @import("builtin");
const microzig = @import("microzig");
const Chip = @import("chip.zig").Chip;

const chip_name = if (builtin.is_test) "nrf52840" else microzig.config.chip_name;

pub const chip: Chip =
    if (std.mem.eql(u8, chip_name, "nrf51"))
        .nrf51
    else if (std.mem.eql(u8, chip_name, "nrf52"))
        .nrf52
    else if (std.mem.eql(u8, chip_name, "nrf52833"))
        .nrf52833
    else if (std.mem.eql(u8, chip_name, "nrf52840"))
        .nrf52840
    else
        unsupported_chip(null);

pub inline fn unsupported_chip(maybe_for_what: ?[]const u8) void {
    @compileError(std.fmt.comptimePrint("unsupported chip for nRF5x {s}HAL: \"{s}\"", .{
        if (maybe_for_what) |for_what| for_what ++ " " else "",
        chip_name,
    }));
}
