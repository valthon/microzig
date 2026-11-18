const std = @import("std");

pub const Divider = struct { clock: u8, integer: u12, fraction: u4 };
pub const Error = error{InvalidBaudRate};

/// C3 TRM v1.4 §§26.4.1, 26.4.3.1; C6 TRM v1.2 §§27.3, 27.4.3.1:
/// core predivider followed
/// by a 12.4 baud divider. Keep at least 16 core clocks per bit.
pub fn calculate(source_hz: u32, baud: u32) Error!Divider {
    if (baud == 0 or @as(u64, baud) * 16 > source_hz) return error.InvalidBaudRate;
    const pre = @as(u64, source_hz) / (@as(u64, baud) * 4096) + 1;
    if (pre > 256) return error.InvalidBaudRate;
    const divisor = (@as(u64, source_hz) * 16 + pre * baud / 2) / (pre * baud);
    if (divisor < 256 or divisor > 65535) return error.InvalidBaudRate;
    return .{ .clock = @intCast(pre - 1), .integer = @intCast(divisor / 16), .fraction = @intCast(divisor % 16) };
}

test "baud divider precision and range" {
    for ([_]u32{ 300, 9600, 115200, 1_000_000, 2_500_000 }) |baud| {
        const d = try calculate(40_000_000, baud);
        const divisor = (@as(u64, d.clock) + 1) * (@as(u64, d.integer) * 16 + d.fraction);
        const actual = 40_000_000 * @as(u64, 16) / divisor;
        try std.testing.expect(@abs(@as(i64, @intCast(actual)) - baud) <= baud / 100 + 1);
    }
    const d = try calculate(40_000_000, 115200);
    try std.testing.expectEqual(@as(u4, 4), d.fraction);
    for ([_]u32{ 0, 1, 2_500_001, std.math.maxInt(u32) }) |baud|
        try std.testing.expectError(error.InvalidBaudRate, calculate(40_000_000, baud));
}
