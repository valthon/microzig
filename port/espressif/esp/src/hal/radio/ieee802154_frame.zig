//! Legacy MAC header validation and C6 power conversion, ESP-IDF v5.5.1
//! esp_ieee802154_frame.c, esp_ieee802154_pib.c and ieee802154_ll.h.
const std = @import("std");
pub const header = @import("ieee802154/header.zig");
pub const tx = @import("ieee802154_tx.zig");

test {
    _ = tx;
    _ = header;
}

pub fn validate_tx(frame: []const u8) error{ InvalidFrame, UnsupportedFrame }!void {
    if (frame.len < 3 or frame.len > 125) return error.InvalidFrame;
    const frame_type = frame[0] & 7;
    // No security, reserved type, enhanced ACKs, sequence suppression or IEs.
    if (frame[0] & 0x88 != 0 or frame_type > 3 or frame[1] & 0x23 != 0)
        return error.UnsupportedFrame;
    const dest_mode = frame[1] >> 2 & 3;
    const src_mode = frame[1] >> 6;
    if (dest_mode == 1 or src_mode == 1) return error.InvalidFrame;
    const compressed = frame[0] & 0x40 != 0;
    if (compressed and (dest_mode == 0 or src_mode == 0)) return error.InvalidFrame;
    var header_len: usize = 3;
    if (dest_mode != 0) header_len += 2 + address_len(dest_mode);
    if (src_mode != 0) header_len += @as(usize, if (compressed) 0 else 2) + address_len(src_mode);
    if (frame.len < header_len) return error.InvalidFrame;
    if (frame_type == 2 and (frame.len != 3 or frame[0] & 0x20 != 0)) return error.InvalidFrame;
}

fn address_len(mode: u8) usize {
    return if (mode == 2) 2 else 8;
}

pub fn power_index(power: i8) u5 {
    if (power >= 20) return 15;
    if (power <= -15) return 3;
    return @intCast(@divTrunc(@as(i16, power) + 15, 3) + 3);
}

test "reject truncated short and extended address headers before DMA" {
    const short = [_]u8{ 0x61, 0x88, 1, 0x34, 0x12, 1, 0, 2, 0, 0xaa };
    try validate_tx(&short);
    var version1 = short;
    version1[1] |= 0x10;
    try validate_tx(&version1);
    for (0..9) |len| try std.testing.expectError(error.InvalidFrame, validate_tx(short[0..len]));
    var extended: [21]u8 = @splat(0);
    @memcpy(extended[0..5], &[_]u8{ 0x41, 0xcc, 1, 0x34, 0x12 });
    try validate_tx(&extended);
    try std.testing.expectError(error.InvalidFrame, validate_tx(extended[0..20]));
    const reserved_mode = [_]u8{ 1, 4, 1 };
    try std.testing.expectError(error.InvalidFrame, validate_tx(&reserved_mode));
    try std.testing.expectError(error.UnsupportedFrame, validate_tx(&.{ 9, 0, 1 }));
    try std.testing.expectError(error.UnsupportedFrame, validate_tx(&.{ 1, 0x20, 1 }));
    try validate_tx(&.{ 2, 0, 1 });
    try std.testing.expectError(error.InvalidFrame, validate_tx(&.{ 0x22, 0, 1 }));
}

test "C6 power limits and three dB quantization" {
    try std.testing.expectEqual(@as(u5, 3), power_index(-128));
    try std.testing.expectEqual(@as(u5, 3), power_index(-15));
    try std.testing.expectEqual(@as(u5, 3), power_index(-13));
    try std.testing.expectEqual(@as(u5, 4), power_index(-12));
    try std.testing.expectEqual(@as(u5, 8), power_index(0));
    try std.testing.expectEqual(@as(u5, 14), power_index(19));
    try std.testing.expectEqual(@as(u5, 15), power_index(20));
    try std.testing.expectEqual(@as(u5, 15), power_index(127));
}
