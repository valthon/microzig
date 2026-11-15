const std = @import("std");

const hw = @import("../hw.zig");

pub fn sm_mask(sm: u2) u32 {
    return @as(u32, 1) << sm;
}

pub fn debug_mask(sm: u2) u32 {
    // FDEBUG: RXSTALL[3:0], RXUNDER[11:8], TXOVER[19:16], TXSTALL[27:24].
    // RP2040 §3.7, RP2350 §11.7 register listings.
    return @as(u32, 0x01010101) << sm;
}

pub fn sm_set_enabled(ctrl: anytype, sm: u2, enabled: bool) void {
    // RP2040 §2.1.2 and RP2350 §2.1.3: atomic register aliases.
    const alias = if (enabled) hw.set_alias(ctrl) else hw.clear_alias(ctrl);
    alias.write_raw(sm_mask(sm));
}

pub fn sm_clear_debug(debug: anytype, sm: u2) void {
    debug.write_raw(debug_mask(sm));
}

pub fn sm_clear_interrupt(irq: anytype, sm: u2) void {
    // IRQ flags are W1C, indexed directly rather than by the INTE layout.
    irq.write_raw(sm_mask(sm));
}

pub fn interrupt_mask(sm: u2, source: u2) u32 {
    return @as(u32, 1) << (@as(u5, 4) * source + sm);
}

pub fn sm_enable_interrupt(enable: anytype, sm: u2, source: u2) void {
    hw.set_alias(enable).write_raw(interrupt_mask(sm, source));
}

// These register models record bus writes, including the reads hidden by modify.
const TestCtrl = extern struct {
    raw: u32 = 0,
    const Value = packed struct(u32) { SM_ENABLE: u4, reserved: u28 = 0 };
    fn read(self: *volatile TestCtrl) Value {
        return @bitCast(self.raw);
    }
    fn write(self: *volatile TestCtrl, value: Value) void {
        self.raw = @bitCast(value);
    }
    fn write_raw(self: *volatile TestCtrl, value: u32) void {
        self.raw = value;
    }
};

const TestDebug = extern struct {
    raw: u32 = 0,
    reads: usize = 0,
    fn modify(self: *volatile TestDebug, value: anytype) void {
        self.reads += 1;
        self.raw = @as(u32, value.RXSTALL) | (@as(u32, value.RXUNDER) << 8) |
            (@as(u32, value.TXOVER) << 16) | (@as(u32, value.TXSTALL) << 24);
    }
    fn write_raw(self: *volatile TestDebug, value: u32) void {
        self.raw = value;
    }
};

test "IRQ clear writes only the selected SM flag" {
    var irq: TestCtrl = .{ .raw = 0xff };
    sm_clear_interrupt(&irq, 2);
    try std.testing.expectEqual(@as(u32, 4), irq.raw);
}

test "debug clear writes one SM without reading W1C state" {
    var debug: TestDebug = .{ .raw = 0x0f0f0f0f };
    sm_clear_debug(&debug, 1);
    try std.testing.expectEqual(@as(u32, 0x02020202), debug.raw);
    try std.testing.expectEqual(@as(usize, 0), debug.reads);
}

test "enable writes use hardware SET and CLR aliases" {
    // Aliases share the low 12 address bits (40DS §2.1.2, 50DS §2.1.3).
    var bank: [4096]u32 align(16384) = @splat(0);
    const ctrl: *volatile TestCtrl = @ptrCast(&bank[0]);
    const enable: *volatile TestCtrl = @ptrCast(&bank[32]);
    ctrl.raw = 8;
    sm_set_enabled(ctrl, 2, true);
    try std.testing.expectEqual(@as(u32, 8), ctrl.raw);
    try std.testing.expectEqual(@as(u32, 4), bank[0x2000 / 4]);
    sm_set_enabled(ctrl, 2, false);
    try std.testing.expectEqual(@as(u32, 4), bank[0x3000 / 4]);
    enable.raw = 1;
    sm_enable_interrupt(enable, 3, 2);
    try std.testing.expectEqual(@as(u32, 1), enable.raw);
    try std.testing.expectEqual(@as(u32, 1 << 11), bank[32 + 0x2000 / 4]);
}

test "register masks cover each SM and source independently" {
    for (0..4) |index| {
        const sm: u2 = @intCast(index);
        try std.testing.expectEqual(@as(u32, 1) << sm, sm_mask(sm));
        try std.testing.expectEqual(@as(u32, 0x01010101) << sm, debug_mask(sm));
        try std.testing.expectEqual(@as(u32, 1) << sm, interrupt_mask(sm, 0));
        try std.testing.expectEqual(@as(u32, 0x10) << sm, interrupt_mask(sm, 1));
        try std.testing.expectEqual(@as(u32, 0x100) << sm, interrupt_mask(sm, 2));
    }
}
