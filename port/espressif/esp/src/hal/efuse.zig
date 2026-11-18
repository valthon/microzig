const std = @import("std");
const microzig = @import("microzig");
const peripherals = microzig.chip.peripherals;
const EFUSE = peripherals.EFUSE;

pub fn read_mac() [6]u8 {
    var mac: [6]u8 = undefined;
    inline for (items.mac, 0..) |item, i| {
        mac[i] = read(item);
    }
    return mac;
}

pub fn read(comptime what: Item) @Int(.unsigned, what.bit_length) {
    const OutputType = @Int(.unsigned, what.bit_length);

    if (what.block > 2) @compileError("invalid block");

    const start_word = what.bit_offset / 32;
    const start_bit_offset_in_word = what.bit_offset % 32;

    const end_bit = @as(usize, what.bit_offset) + what.bit_length - 1;
    const end_word = end_bit / 32;
    const end_bit_offset_in_word = end_bit % 32;

    var result: OutputType = 0;
    comptime var current_bit = 0;

    inline for (start_word..end_word + 1) |word| {
        const name = comptime switch (what.block) {
            0 => if (word == 0) "RD_WR_DIS" else std.fmt.comptimePrint("RD_REPEAT_DATA{d}", .{word - 1}),
            1 => std.fmt.comptimePrint("RD_MAC_SPI_SYS_{d}", .{word}),
            2 => std.fmt.comptimePrint("RD_SYS_PART1_DATA{d}", .{word}),
            else => unreachable,
        };
        var value: u32 = @bitCast(@field(EFUSE, name).read());

        comptime var increment = 32;
        comptime var pre_shift = 0;

        if (word == start_word) {
            value >>= start_bit_offset_in_word;
            increment -= start_bit_offset_in_word;
            pre_shift = start_bit_offset_in_word;
        }

        if (word == end_word) {
            const shift = 31 - (end_bit_offset_in_word - pre_shift);
            const mask = ~@as(u32, 0) <<| shift >> shift;

            value &= mask;
            increment -= 31 - end_bit_offset_in_word;
        }

        result |= @as(OutputType, @intCast(value)) << current_bit;
        current_bit += increment;
    }

    comptime std.debug.assert(current_bit == what.bit_length);

    return result;
}

pub const Item = struct {
    block: u8,
    bit_offset: u8,
    bit_length: u8,
};

// Using a separate namespace here to make it easy to port to other chips.
pub const items = struct {
    // Bytes are in inverse order.
    pub const mac: []const Item = &.{
        .{
            .block = 1,
            .bit_offset = 40,
            .bit_length = 8,
        },
        .{
            .block = 1,
            .bit_offset = 32,
            .bit_length = 8,
        },
        .{
            .block = 1,
            .bit_offset = 24,
            .bit_length = 8,
        },
        .{
            .block = 1,
            .bit_offset = 16,
            .bit_length = 8,
        },
        .{
            .block = 1,
            .bit_offset = 8,
            .bit_length = 8,
        },
        .{
            .block = 1,
            .bit_offset = 0,
            .bit_length = 8,
        },
    };

    pub const blk_version_minor: Item = .{
        .block = 1,
        .bit_offset = 120,
        .bit_length = 3,
    };

    pub const blk_version_major: Item = .{
        // ESP-IDF v5.3.1 esp_efuse_table.csv: BLK_VERSION_MAJOR is in BLOCK2.
        .block = 2,
        .bit_offset = 128,
        .bit_length = 2,
    };

    pub const adc1_init_code: []const Item = &.{
        .{
            .block = 2,
            .bit_offset = 148,
            .bit_length = 10,
        },
        .{
            .block = 2,
            .bit_offset = 158,
            .bit_length = 10,
        },
        .{
            .block = 2,
            .bit_offset = 168,
            .bit_length = 10,
        },
        .{
            .block = 2,
            .bit_offset = 178,
            .bit_length = 10,
        },
    };

    pub const adc1_cal_voltage: []const Item = &.{
        .{
            .block = 2,
            .bit_offset = 188,
            .bit_length = 10,
        },
        .{
            .block = 2,
            .bit_offset = 198,
            .bit_length = 10,
        },
        .{
            .block = 2,
            .bit_offset = 208,
            .bit_length = 10,
        },
        .{
            .block = 2,
            .bit_offset = 218,
            .bit_length = 10,
        },
    };
};

pub const AdcCalibration = struct {
    init_code: u12,
    reference_code: u12,
    reference_mv: u16,
};

/// Only encoding version 1 (BLOCK2 major = 1) is supported. Other versions,
/// including unburnt eFuses, return null. Zero payload fields are valid in v1.
/// Arithmetic from ESP-IDF v5.3.1 esp_efuse_rtc_calib.c:
/// esp_efuse_rtc_calib_get_ver/get_init_code/get_cal_voltage (Apache-2.0).
pub fn read_adc1_calibration() ?[4]AdcCalibration {
    if (read(items.blk_version_major) != 1) return null;
    var result: [4]AdcCalibration = undefined;
    inline for (0..4) |atten| {
        result[atten] = decode_adc_calibration(
            read(items.adc1_init_code[atten]),
            read(items.adc1_cal_voltage[atten]),
            .{ 400, 550, 750, 1370 }[atten],
        );
    }
    return result;
}

fn decode_adc_calibration(init_code: u10, voltage_code: u10, reference_mv: u16) AdcCalibration {
    const magnitude: u12 = voltage_code & 0x1ff;
    return .{
        .init_code = 1000 + @as(u12, init_code),
        .reference_code = if (voltage_code & 0x200 != 0) 2000 - magnitude else 2000 + magnitude,
        .reference_mv = reference_mv,
    };
}

test "ADC v1 sign magnitude voltage and init code boundaries" {
    const expect = std.testing.expectEqual;
    try expect(@as(u12, 1000), decode_adc_calibration(0, 0, 400).init_code);
    try expect(@as(u12, 2023), decode_adc_calibration(1023, 0, 400).init_code);
    try expect(@as(u12, 2000), decode_adc_calibration(0, 0x200, 400).reference_code);
    try expect(@as(u12, 2511), decode_adc_calibration(0, 0x1ff, 400).reference_code);
    try expect(@as(u12, 1489), decode_adc_calibration(0, 0x3ff, 400).reference_code);
}
