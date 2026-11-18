//! ESP-IDF v5.4 (Apache-2.0), components/efuse/esp32c6/
//! esp_efuse_rtc_calib.c and components/esp_adc/adc_cali_curve_fitting.c,
//! esp32c6/curve_fitting_coefficients.c. No C3 calibration data is reused.
const std = @import("std");

pub const Calibration = struct {
    version: enum { v1, v2 },
    init_codes: [4]u12,
    reference_codes: [4]u12,
    reference_mv: [4]u16,
    channel_compensation: [7]i8,

    pub fn millivolts(self: Calibration, raw: u12, channel: u3, atten: u2) i32 {
        // IDF subtracts channel compensation in raw units before curve fitting.
        const adjusted: u64 = @intCast(std.math.clamp(@as(i32, raw) -
            @as(i32, self.channel_compensation[channel]) * (4 - @as(i32, atten)), 0, 4095));
        const slope = @as(u64, 65536) * self.reference_mv[atten] / self.reference_codes[atten];
        const voltage = adjusted * slope / 65536;
        if (voltage == 0 or (self.version == .v2 and atten < 2)) return @intCast(voltage);
        const coefficients = [2][4][3]u64{
            .{
                .{ 487166399931449, 6436483033201, 30410131806 },
                .{ 8665498165817785, 15239070452946, 13818878844 },
                .{ 12277821756674387, 22275554717885, 5924302667 },
                .{ 3801417550380255, 6020352420772, 12442478488 },
            },
            .{
                .{ 0, 0, 0 },
                .{ 0, 0, 0 },
                .{ 12217864764388775, 1954123107752, 6409679727 },
                .{ 3915910437042445, 31536470857564, 12493873014 },
            },
        };
        const version_index: usize = if (self.version == .v1) 0 else 1;
        var power: u64 = 1;
        var correction: i32 = 0;
        for (0..3) |term_index| {
            const divisor: u64 = if (self.version == .v1 and atten == 0 and term_index == 0)
                1_000_000_000_000_000
            else
                10_000_000_000_000_000;
            // Even the minimum v1 reference code (989) and raw=4095 fit u64.
            const term: i32 = @intCast(power * coefficients[version_index][atten][term_index] / divisor);
            const negative = term_index == 0 or (term_index == 1 and (atten == 3 or self.version == .v2));
            correction += if (negative) -term else term;
            power *= voltage;
        }
        return @as(i32, @intCast(voltage)) - correction;
    }
};

// ESP32-C6 TRM v1.2 §§6.4–6.5: BLOCK1 words at EFUSE + 0x44..0x58,
// BLOCK2 at +0x5c..0x78, matching ESP32-C6.svd. Field positions and the
// full version calculation follow ESP-IDF v5.4 esp32c6/esp_efuse_table.csv
// and components/hal/efuse_hal.c, efuse_hal_blk_version.
pub fn decode_blocks(block1: [6]u32, block2: [8]u32) ?Calibration {
    const major = field(u2, &block1, 126);
    const minor = field(u3, &block1, 123);
    var init: [4]u10 = undefined;
    var voltage: [4]u10 = undefined;
    var channels: [7]u4 = undefined;
    inline for (0..4) |i| {
        init[i] = field(u10, &block2, 145 + 10 * i);
        voltage[i] = field(u10, &block2, 185 + 10 * i);
    }
    inline for (0..7) |i| {
        channels[i] = field(u4, &block2, 225 + 4 * i);
    }
    return decode(@as(u16, major) * 100 + minor, init, voltage, channels);
}

fn field(comptime T: type, words: []const u32, comptime offset: usize) T {
    const word = offset / 32;
    const shift = offset % 32;
    var value = words[word] >> shift;
    if (shift + @bitSizeOf(T) > 32) value |= words[word + 1] << (32 - shift);
    return @truncate(value);
}

fn signed_magnitude(value: u10, sign: u10) i16 {
    const magnitude: i16 = @intCast(value & (sign - 1));
    return if (value & sign != 0) -magnitude else magnitude;
}

/// IDF uses the full BLOCK2 version (major * 100 + minor): 1 is v1,
/// >=2 is v2; zero is unprogrammed.
/// Zero payload fields are valid. Channel fields use sign-magnitude too.
pub fn decode(block_version: u16, init: [4]u10, voltage: [4]u10, channels: [7]u4) ?Calibration {
    if (block_version == 0) return null;
    var result: Calibration = .{
        .version = if (block_version == 1) .v1 else .v2,
        .init_codes = undefined,
        .reference_codes = undefined,
        .reference_mv = if (block_version == 1) .{ 400, 550, 750, 1370 } else .{ 750, 1000, 1500, 2800 },
        .channel_compensation = undefined,
    };
    for (0..4) |atten| {
        result.init_codes[atten] = 1600 + @as(u12, init[atten]);
        const base: i16 = if (block_version == 1) 1500 else if (atten == 2) 2900 else 2850;
        result.reference_codes[atten] = @intCast(base + signed_magnitude(voltage[atten], 0x200));
    }
    for (channels, 0..) |value, channel| {
        result.channel_compensation[channel] = @intCast(signed_magnitude(value, 8));
    }
    return result;
}

test "C6 calibration versions and sign magnitude boundaries" {
    const expect = std.testing.expectEqual;
    try std.testing.expect(decode(0, @splat(0), @splat(0), @splat(0)) == null);
    const v1 = decode(1, .{ 0, 1023, 1, 2 }, .{ 0, 0x200, 0x1ff, 0x3ff }, .{ 0, 8, 7, 15, 1, 9, 2 }).?;
    try expect([4]u12{ 1600, 2623, 1601, 1602 }, v1.init_codes);
    try expect([4]u12{ 1500, 1500, 2011, 989 }, v1.reference_codes);
    try expect([7]i8{ 0, 0, 7, -7, 1, -1, 2 }, v1.channel_compensation);
    const v2 = decode(2, @splat(0), .{ 0, 0x1ff, 0x3ff, 0x200 }, @splat(0)).?;
    try expect([4]u12{ 2850, 3361, 2389, 2850 }, v2.reference_codes);
    try expect(v2, decode(3, @splat(0), .{ 0, 0x1ff, 0x3ff, 0x200 }, @splat(0)).?);
}

test "C6 IDF integer curve reference vectors for every attenuation and version" {
    const expect = std.testing.expectEqual;
    const expected = [2][3][4]i32{
        .{ .{ 399, 549, 750, 1367 }, .{ 859, 1182, 1612, 2941 }, .{ 1088, 1496, 2042, 3725 } },
        .{ .{ 749, 999, 1474, 2798 }, .{ 850, 1133, 1671, 3172 }, .{ 1077, 1436, 2117, 4015 } },
    };
    for ([_]u2{ 1, 2 }, 0..) |version, v| {
        const cal = decode(version, @splat(0), @splat(0), @splat(0)).?;
        for ([_]u12{ if (version == 1) 1500 else 2850, 3231, 4095 }, 0..) |raw, r| {
            for (0..4) |atten| {
                try expect(expected[v][r][atten], cal.millivolts(raw, 0, @intCast(atten)));
                try expect(@as(i32, 0), cal.millivolts(0, 0, @intCast(atten)));
            }
        }
    }
}

test "C6 channel compensation sign attenuation scaling and clamping" {
    const expect = std.testing.expectEqual;
    const plain = decode(2, @splat(0), @splat(0), @splat(0)).?;
    const compensated = decode(2, @splat(0), @splat(0), .{ 7, 15, 0, 0, 0, 0, 0 }).?;
    for (0..4) |a| {
        const atten: u2 = @intCast(a);
        const delta: u12 = @intCast(7 * (4 - a));
        try expect(plain.millivolts(2000 - delta, 0, atten), compensated.millivolts(2000, 0, atten));
        try expect(plain.millivolts(2000 + delta, 0, atten), compensated.millivolts(2000, 1, atten));
        try expect(@as(i32, 0), compensated.millivolts(0, 0, atten));
        try expect(plain.millivolts(4095, 0, atten), compensated.millivolts(4095, 1, atten));
    }
}

test "C6 all raw inputs with extreme valid reference codes stay monotonic" {
    // Includes above-range voltages: no overflow or polynomial wrap at saturation.
    for ([_]u2{ 1, 2 }) |version| {
        for ([_]u10{ 0x1ff, 0x3ff }) |code| {
            const cal = decode(version, @splat(1023), @splat(code), @splat(0)).?;
            for (0..4) |a| {
                var previous: i32 = 0;
                for (0..4096) |raw| {
                    const mv = cal.millivolts(@intCast(raw), 0, @intCast(a));
                    // Per-term integer truncation can introduce 1 mV steps down.
                    try std.testing.expect(mv >= previous - 1);
                    previous = mv;
                }
            }
        }
    }
}

test "C6FH4 rev 0.2 eFuse dump matches ESP-IDF v5.4 calibration v2" {
    const expect = std.testing.expectEqual;
    var block1 = [6]u32{ 0xe07efc74, 0xfffe9888, 0x089f1af5, 0x19080000, 0x00000029, 0 };
    const block2 = [8]u32{ 0x3af387ab, 0x5616817d, 0x9db05fc2, 0xcb2ba005, 0x0c32d986, 0xf713c431, 0x3b4cd344, 0x11111111 };
    try expect(@as(u2, 0), field(u2, &block1, 126)); // BLK_VERSION_MAJOR
    try expect(@as(u3, 3), field(u3, &block1, 123)); // BLK_VERSION_MINOR
    const cal = decode_blocks(block1, block2).?;
    try expect(.v2, cal.version);
    // ADC1_INIT_CODE_ATTEN0..3: 537, 545, 545, 551, plus 1600.
    try expect([4]u12{ 2137, 2145, 2145, 2151 }, cal.init_codes);
    // ADC1_CAL_VOL_ATTEN0..3: 635, 616, 614, 630 (sign-magnitude).
    // IDF adds -123/-104/-102/-118 to 2850/2850/2900/2850.
    try expect([4]u12{ 2727, 2746, 2798, 2732 }, cal.reference_codes);
    try expect([4]u16{ 750, 1000, 1500, 2800 }, cal.reference_mv);
    // ADC1_INIT_CODE_ATTEN0_CH0..6 are all 8 (negative zero).
    try expect([7]i8{ 0, 0, 0, 0, 0, 0, 0 }, cal.channel_compensation);
    // Payload alone must not make unprogrammed version 0 look calibrated.
    block1[3] &= ~@as(u32, 0xf8000000);
    try std.testing.expect(decode_blocks(block1, block2) == null);
    block1[3] |= 1 << 23; // Wafer major is independent of block version.
    try std.testing.expect(decode_blocks(block1, block2) == null);
    block1[3] |= 1 << 27; // Block version 0.1 selects v1.
    try expect(.v1, decode_blocks(block1, block2).?.version);
    block1[3] = 1 << 30; // Full version 1.0 is 100, hence v2.
    try expect(.v2, decode_blocks(block1, block2).?.version);
}
