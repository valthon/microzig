const std = @import("std");

pub const Bounds = struct {
    low: usize,
    top: usize,

    /// Linker-provided free space must contain the initial stack pointer.
    pub fn init(free_start: usize, free_end: usize, top: usize) ?Bounds {
        if (free_start == 0 or free_start >= top or top > free_end) return null;
        return .{ .low = free_start, .top = top };
    }

    /// A disjoint heap does not consume this stack's free space.
    pub fn with_heap(self: Bounds, heap_start: usize, heap_end: usize) Bounds {
        if (heap_start >= self.top or heap_end <= self.low) return self;
        return .{ .low = @max(self.low, heap_end), .top = self.top };
    }
};

pub const Guard = struct {
    base: usize,
    limit: usize,
    size_field: u5,
};

/// Decode the RBAR alignment probe. A zero mask requires an unrepresentable
/// 4GiB guard on Cortex-M, so cannot protect a usable stack.
pub fn mpu_minimum_size(address_mask: u32) ?usize {
    if (address_mask == 0) return null;
    return @as(usize, 1) << @as(u5, @intCast(@ctz(address_mask)));
}

/// Place the whole guard above occupied memory. The alignment padding and
/// guard consume stack space, never globals or memory returned by heap().
pub fn mpu_guard(low: usize, top: usize, minimum_size: usize) ?Guard {
    const rounded = std.math.add(usize, low, minimum_size - 1) catch return null;
    const base = rounded & ~(minimum_size - 1);
    const limit = std.math.add(usize, base, minimum_size) catch return null;
    if (base < low or limit >= top) return null;
    return .{ .base = base, .limit = limit, .size_field = @intCast(std.math.log2_int(usize, minimum_size) - 1) };
}

/// MSPLIM has three RES0 low bits (Arm DDI0553B.y, D1.2.177).
pub fn main_limit(low: usize, top: usize) ?usize {
    const limit = std.math.add(usize, low, 7) catch return null;
    const aligned = limit & ~@as(usize, 7);
    return if (aligned < top) aligned else null;
}

test "default and fixed-address stacks use linker free bounds" {
    const expect = std.testing.expectEqual;
    try expect(@as(?Bounds, .{ .low = 0x20000104, .top = 0x20040000 }), Bounds.init(0x20000104, 0x20040000, 0x20040000));
    try expect(@as(?Bounds, .{ .low = 0x20000104, .top = 0x20020000 }), Bounds.init(0x20000104, 0x20040000, 0x20020000));
    try expect(@as(?Bounds, null), Bounds.init(0, 0, 0x20040000));
    try expect(@as(?Bounds, null), Bounds.init(0x20000104, 0x20040000, 0x20000080));
    try expect(@as(?Bounds, null), Bounds.init(0x20000104, 0x20040000, 0x21000000));
}

test "heap claim raises only an overlapping stack boundary" {
    const bounds = Bounds{ .low = 0x20000104, .top = 0x20040000 };
    const claimed = bounds.with_heap(0x20000104, 0x2003f001);
    try std.testing.expectEqual(@as(usize, 0x2003f001), claimed.low);
    try std.testing.expectEqual(@as(?usize, 0x2003f008), main_limit(claimed.low, claimed.top));
    const guard = mpu_guard(claimed.low, claimed.top, 256).?;
    try std.testing.expectEqual(@as(usize, 0x2003f100), guard.base);
    try std.testing.expectEqual(@as(usize, 0x2003f200), guard.limit);
    const other_region = Bounds.init(0x21000000, 0x21001000, 0x21001000).?;
    try std.testing.expectEqual(other_region, other_region.with_heap(0x20000104, 0x20040000));
    try std.testing.expectEqual(claimed, claimed.with_heap(0x20000104, 0x20030000));
}

test "MPU size alignment and exhausted space" {
    for ([_]usize{ 32, 256 }) |size| {
        const guard = mpu_guard(0x20000101, 0x20001000, size).?;
        try std.testing.expect(guard.base >= 0x20000101);
        try std.testing.expectEqual(@as(usize, 0), guard.base % size);
        try std.testing.expectEqual(size, guard.limit - guard.base);
        try std.testing.expectEqual(size, @as(usize, 1) << (@as(std.math.Log2Int(usize), guard.size_field) + 1));
    }
    try std.testing.expectEqual(@as(?Guard, null), mpu_guard(0x20000100, 0x20000200, 256));
    try std.testing.expectEqual(@as(?usize, null), main_limit(0x20000200, 0x20000200));
    try std.testing.expectEqual(@as(?usize, null), main_limit(std.math.maxInt(usize), std.math.maxInt(usize)));
}

test "MPU implemented minimum region size" {
    try std.testing.expectEqual(@as(?usize, 32), mpu_minimum_size(0xffffffe0));
    try std.testing.expectEqual(@as(?usize, 256), mpu_minimum_size(0xffffff00));
    try std.testing.expectEqual(@as(?usize, 1024), mpu_minimum_size(0xfffffc00));
    try std.testing.expectEqual(@as(?usize, null), mpu_minimum_size(0));
}

test "heap exhausting the stack cannot produce a usable limit or guard" {
    const bounds = Bounds.init(0x20000100, 0x20040000, 0x20040000).?;
    const claimed = bounds.with_heap(bounds.low, bounds.top);
    try std.testing.expectEqual(@as(?usize, null), main_limit(claimed.low, claimed.top));
    try std.testing.expectEqual(@as(?Guard, null), mpu_guard(claimed.low, claimed.top, 256));
    try std.testing.expectEqual(bounds, bounds.with_heap(0x21000000, 0x21001000));
    try std.testing.expectEqual(@as(?Guard, null), mpu_guard(std.math.maxInt(usize), std.math.maxInt(usize), 256));
}
