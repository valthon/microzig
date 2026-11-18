const std = @import("std");

pub const Interrupt = enum(u5) {
    interrupt1 = 1,
    interrupt2 = 2,
    interrupt3 = 3,
    interrupt4 = 4,
    interrupt5 = 5,
    interrupt6 = 6,
    interrupt7 = 7,
    interrupt8 = 8,
    interrupt9 = 9,
    interrupt10 = 10,
    interrupt11 = 11,
    interrupt12 = 12,
    interrupt13 = 13,
    interrupt14 = 14,
    interrupt15 = 15,
    interrupt16 = 16,
    interrupt17 = 17,
    interrupt18 = 18,
    interrupt19 = 19,
    interrupt20 = 20,
    interrupt21 = 21,
    interrupt22 = 22,
    interrupt23 = 23,
    interrupt24 = 24,
    interrupt25 = 25,
    interrupt26 = 26,
    interrupt27 = 27,
    interrupt28 = 28,
    interrupt29 = 29,
    interrupt30 = 30,
    interrupt31 = 31,
};

pub const Type = enum(u1) {
    level = 0,
    edge = 1,
};

pub fn type_from_bits(bits: u32, int: Interrupt) Type {
    return @fromBackingInt(@as(u1, @truncate(bits >> @backingInt(int))));
}

pub fn interrupt_from_map_bits(bits: u32) ?Interrupt {
    const source_raw: u5 = @truncate(bits);
    if (source_raw != 0) {
        return @fromBackingInt(source_raw);
    } else {
        return null;
    }
}

test "interrupt type selects each interrupt bit independently" {
    for (std.enums.values(Interrupt)) |int| {
        const bit = @as(u32, 1) << @backingInt(int);
        try std.testing.expectEqual(Type.edge, type_from_bits(bit, int));
        try std.testing.expectEqual(Type.level, type_from_bits(~bit, int));
    }
}

test "interrupt mapping preserves all five bits and zero means unmapped" {
    try std.testing.expectEqual(@as(?Interrupt, null), interrupt_from_map_bits(0));
    try std.testing.expectEqual(@as(?Interrupt, null), interrupt_from_map_bits(0xffff_ffe0));
    for (std.enums.values(Interrupt)) |int| {
        try std.testing.expectEqual(@as(?Interrupt, int), interrupt_from_map_bits(@backingInt(int)));
        try std.testing.expectEqual(@as(?Interrupt, int), interrupt_from_map_bits(0xffff_ffe0 | @as(u32, @backingInt(int))));
    }
}
