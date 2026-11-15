//! Value-only PIO register operations (40DS §3.7, 50DS §11.7).
const std = @import("std");
const Chip = @import("../chip.zig").Chip;
const assembler = @import("assembler.zig");

pub const Status = union(enum) { tx_level: u4, rx_level: u4 };
pub const Fifo = enum { tx, rx };
pub const InterruptLine = enum(u1) { irq0, irq1 };
pub const StateMachine = enum(u2) { sm0, sm1, sm2, sm3 };
// Keep the flag wide enough for RP2350's additional routes; validate support
// separately so adding those routes does not change the source type.
pub const InterruptSource = union(enum) {
    rx_not_empty: StateMachine,
    tx_not_full: StateMachine,
    flag: u3,
};

pub fn interrupt_mask(comptime chip: Chip, source: InterruptSource) error{UnsupportedInterruptFlag}!u32 {
    _ = chip;
    const bit: u5 = switch (source) {
        .rx_not_empty => |sm| @backingInt(sm),
        .tx_not_full => |sm| 4 + @as(u5, @backingInt(sm)),
        .flag => |flag| if (flag < 4) 8 + @as(u5, flag) else return error.UnsupportedInterruptFlag,
    };
    return @as(u32, 1) << bit;
}

pub fn dreq_number(comptime chip: Chip, pio: u2, sm: StateMachine, fifo: Fifo) error{InvalidPio}!u6 {
    if (pio >= @as(u3, if (chip == .RP2040) 2 else 3)) return error.InvalidPio;
    return @as(u6, pio) * 8 + @backingInt(sm) + @as(u6, if (fifo == .rx) 4 else 0);
}

pub fn irq_number(comptime chip: Chip, pio: u2, line: InterruptLine) error{InvalidPio}!u6 {
    if (pio >= @as(u3, if (chip == .RP2040) 2 else 3)) return error.InvalidPio;
    return @as(u6, if (chip == .RP2040) 7 else 15) + @as(u6, pio) * 2 + @backingInt(line);
}

pub const Control = enum { enable, restart, clkdiv_restart, enable_in_sync };
pub fn ctrl_mask(mask: u4, action: Control) u32 {
    return switch (action) {
        .enable => mask,
        .restart => @as(u32, mask) << 4,
        .clkdiv_restart => @as(u32, mask) << 8,
        .enable_in_sync => @as(u32, mask) | (@as(u32, mask) << 8),
    };
}

pub const Fdebug = struct { rx_stall: bool, rx_under: bool, tx_over: bool, tx_stall: bool };
pub fn fdebug(value: u32, sm: StateMachine) Fdebug {
    const bits = value >> @backingInt(sm);
    return .{ .rx_stall = bits & 1 != 0, .rx_under = bits & 0x100 != 0, .tx_over = bits & 0x10000 != 0, .tx_stall = bits & 0x1000000 != 0 };
}
pub const DebugConfig = struct { fifo_depth: u6, sm_count: u4, instruction_count: u6 };
pub fn debug_config(value: u32) DebugConfig {
    return .{ .fifo_depth = @truncate(value), .sm_count = @truncate(value >> 8), .instruction_count = @truncate(value >> 16) };
}

pub fn claim_mask(claimed: u4, mask: u4) error{AlreadyClaimed}!u4 {
    if (claimed & mask != 0) return error.AlreadyClaimed;
    return claimed | mask;
}
pub fn first_unused(claimed: u4) error{NoSpace}!StateMachine {
    for (0..4) |i| {
        const sm: u2 = @intCast(i);
        if (claimed & (@as(u4, 1) << sm) == 0) return @fromBackingInt(sm);
    }
    return error.NoSpace;
}

pub fn exec_bits(options: anytype, jmp_pin: u5) u32 {
    const status: u32 = switch (options.status) {
        .tx_level => |n| n,
        .rx_level => |n| @as(u32, n) | 0x10,
    };
    return status | (@as(u32, options.wrap_target) << 7) | (@as(u32, options.wrap) << 12) |
        (@as(u32, @intFromBool(options.out_sticky)) << 17) |
        (@as(u32, @intFromBool(options.inline_out_en)) << 18) | (@as(u32, options.out_en_sel) << 19) |
        (@as(u32, jmp_pin) << 24) | (@as(u32, @intFromBool(options.side_pindir)) << 29) |
        (@as(u32, @intFromBool(options.side_set_optional)) << 30);
}

pub const PinChunk = struct { base: u5, count: u3, data: u5 };
pub fn pindir_chunk(base: u5, remaining: u6, is_out: bool) PinChunk {
    return .{ .base = base, .count = @intCast(@min(remaining, 5)), .data = if (is_out) 31 else 0 };
}
pub fn set_pinctrl(chunk: PinChunk) u32 {
    // No side-set during injected SET instructions (SIDESET_COUNT=0).
    return (@as(u32, chunk.count) << 26) | (@as(u32, chunk.base) << 5);
}

pub const Divider = struct { int: u16, frac: u8 };
pub fn clkdiv_from_hz(sys_hz: u32, sm_hz: u32) error{InvalidFrequency}!Divider {
    if (sys_hz == 0 or sm_hz == 0 or sm_hz > sys_hz) return error.InvalidFrequency;
    const fixed = (@as(u64, sys_hz) * 256) / sm_hz;
    // INT=0 means 65536, and is valid only with FRAC=0 (40DS §3.7).
    if (fixed > 65536 * 256) return error.InvalidFrequency;
    return .{ .int = @truncate(fixed >> 8), .frac = @truncate(fixed) };
}

pub const ProgramConfig = struct {
    wrap: u5,
    wrap_target: u5,
    side_pindir: bool = false,
    side_set_optional: bool = false,
    side_set_count: u3 = 0,
    status: Status = .{ .tx_level = 0 },
    clock_div: f32 = 1,
    in_shift: ?assembler.Config.Shift = null,
    out_shift: ?assembler.Config.Shift = null,
    set_count: ?u3 = null,
    fifo: assembler.Config.Fifo = .txrx,
};
pub fn default_config(program: assembler.Program) error{ UnsupportedConfig, InvalidProgram }!ProgramConfig {
    if (program.instructions.len == 0 or program.instructions.len > 32) return error.InvalidProgram;
    var config: ProgramConfig = .{
        .wrap = program.wrap orelse @intCast(program.instructions.len - 1),
        .wrap_target = program.wrap_target orelse 0,
        .clock_div = program.config.clock_div orelse 1,
        .in_shift = program.config.in,
        .out_shift = program.config.out,
        .set_count = program.config.set,
        .fifo = program.config.fifo orelse .txrx,
    };
    if (program.side_set) |side| {
        config.side_pindir = side.pindir;
        config.side_set_optional = side.optional;
        config.side_set_count = side.count;
    }
    if (program.config.mov_status) |status| {
        if (status.source == .irq or status.n > 15) return error.UnsupportedConfig;
        config.status = if (status.source == .txfifo) .{ .tx_level = @intCast(status.n) } else .{ .rx_level = @intCast(status.n) };
    }
    if (config.fifo != .txrx and config.fifo != .tx and config.fifo != .rx) return error.UnsupportedConfig;
    return config;
}

test "shared register layouts and claim transitions on both chips" {
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        for (0..4) |index| {
            const sm: StateMachine = @fromBackingInt(@as(u2, @intCast(index)));
            try std.testing.expectEqual(@as(u32, 1) << @backingInt(sm), try interrupt_mask(chip, .{ .rx_not_empty = sm }));
            try std.testing.expectEqual(@as(u32, 16) << @backingInt(sm), try interrupt_mask(chip, .{ .tx_not_full = sm }));
            try std.testing.expectEqual(@as(u32, 256) << @backingInt(sm), try interrupt_mask(chip, .{ .flag = @intCast(index) }));
            for (0..@as(usize, if (chip == .RP2040) 2 else 3)) |p| {
                try std.testing.expectEqual(@as(u6, @intCast(p * 8 + index)), try dreq_number(chip, @intCast(p), sm, .tx));
                try std.testing.expectEqual(@as(u6, @intCast(p * 8 + index + 4)), try dreq_number(chip, @intCast(p), sm, .rx));
            }
        }
        try std.testing.expectError(error.UnsupportedInterruptFlag, interrupt_mask(chip, .{ .flag = 4 }));
        try std.testing.expectEqual(@as(u6, if (chip == .RP2040) 10 else 18), try irq_number(chip, 1, .irq1));
    }
    try std.testing.expectError(error.InvalidPio, dreq_number(.RP2040, 2, .sm0, .tx));
    var claimed: u4 = 0;
    for (0..4) |i| {
        const sm = try first_unused(claimed);
        try std.testing.expectEqual(@as(u2, @intCast(i)), @backingInt(sm));
        claimed = try claim_mask(claimed, @as(u4, 1) << @backingInt(sm));
    }
    try std.testing.expectError(error.NoSpace, first_unused(claimed));
    try std.testing.expectError(error.AlreadyClaimed, claim_mask(claimed, 3));
    claimed &= ~@as(u4, 6);
    try std.testing.expectEqual(@as(u4, 15), try claim_mask(claimed, 6));
    for (0..16) |mask| {
        const m: u4 = @intCast(mask);
        try std.testing.expectEqual(@as(u32, @intCast(mask * 257)), ctrl_mask(m, .enable_in_sync));
        try std.testing.expectEqual(@as(u32, @intCast(mask * 16)), ctrl_mask(m, .restart));
        try std.testing.expectEqual(@as(u32, @intCast(mask * 256)), ctrl_mask(m, .clkdiv_restart));
    }
    try std.testing.expectEqual(Fdebug{ .rx_stall = true, .rx_under = false, .tx_over = true, .tx_stall = false }, fdebug(0x00040004, .sm2));
    try std.testing.expectEqual(DebugConfig{ .fifo_depth = 4, .sm_count = 4, .instruction_count = 32 }, debug_config(0x200404));
}

test "divider boundaries and fractional clocks" {
    try std.testing.expectEqual(Divider{ .int = 2, .frac = 128 }, try clkdiv_from_hz(125_000_000, 50_000_000));
    try std.testing.expectEqual(Divider{ .int = 0, .frac = 0 }, try clkdiv_from_hz(65536, 1));
    try std.testing.expectError(error.InvalidFrequency, clkdiv_from_hz(65537, 1));
    try std.testing.expectError(error.InvalidFrequency, clkdiv_from_hz(1, 0));
    try std.testing.expectError(error.InvalidFrequency, clkdiv_from_hz(1, 2));
}

test "program directives derive configuration for both chips" {
    @setEvalBranchQuota(100_000);
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        const p = comptime assembler.assemble(chip,
            \\.program configured
            \\.side_set 1 opt pindirs
            \\.in 32 left auto 16
            \\.out 8 right auto 32
            \\.set 3
            \\.fifo tx
            \\.clock_div 2.5
            \\.mov_status rxfifo < 3
            \\.wrap_target
            \\nop
            \\.wrap
        , .{}).get_program_by_name("configured");
        const c = try default_config(p);
        try std.testing.expectEqual(@as(f32, 2.5), c.clock_div);
        try std.testing.expectEqual(Status{ .rx_level = 3 }, c.status);
        try std.testing.expect(c.side_pindir and c.side_set_optional);
        try std.testing.expectEqual(@as(u3, 1), c.side_set_count);
        try std.testing.expectEqual(@as(u6, 32), c.in_shift.?.count);
        try std.testing.expectEqual(@as(u6, 8), c.out_shift.?.count);
        try std.testing.expectEqual(@as(?u3, 3), c.set_count);
        try std.testing.expectEqual(assembler.Config.Fifo.tx, c.fifo);
        const shift = default_shift_config(chip, c);
        try std.testing.expect(shift.autopush and shift.autopull and shift.join_tx and !shift.join_rx);
        try std.testing.expectEqual(@as(u5, 16), shift.push_threshold);
        try std.testing.expectEqual(@as(u5, 0), shift.pull_threshold);
        try std.testing.expectEqual(ShiftOptions(chip).Direction.left, shift.in_shiftdir);
        try std.testing.expectEqual(ShiftOptions(chip).Direction.right, shift.out_shiftdir);
        if (chip == .RP2350) try std.testing.expectEqual(@as(u5, 0), shift.in_count);
    }
}

pub fn clkdiv_from_float(divider: f32) error{InvalidDivider}!Divider {
    if (!std.math.isFinite(divider) or divider < 1 or divider > 65536) return error.InvalidDivider;
    const fixed: u32 = @intFromFloat(@floor(divider * 256));
    return .{ .int = @truncate(fixed >> 8), .frac = @truncate(fixed) };
}

pub const PinCounts = struct { out: u6 = 0, set: u6 = 0, side_set: u6 = 0, in: ?u6 = null };
pub fn validate_pin_counts(counts: PinCounts, optional: bool) !void {
    if (counts.set > 5) return error.InvalidSetCount;
    if (counts.out > 32) return error.InvalidOutCount;
    if (counts.side_set > 5 - @as(u6, @intFromBool(optional))) return error.InvalidSideSetCount;
    if (counts.in) |count| if (count > 32) return error.InvalidInCount;
}
pub fn validate_program_counts(program: assembler.Program, counts: PinCounts, has_in_base: bool) !void {
    if (counts.side_set != (if (program.side_set) |side| side.count else @as(u3, 0))) return error.SideSetCountMismatch;
    if (program.config.set) |count| if (count != counts.set) return error.SetCountMismatch;
    if (program.config.out) |output| if (output.count != counts.out) return error.OutCountMismatch;
    if (program.config.in) |input| {
        if (counts.in) |count| {
            if (input.count != count) return error.InCountMismatch;
        } else if (input.count != 0 and !has_in_base) return error.InCountMismatch;
    }
}

test "exec fields occupy the documented positions and mapping mismatches are errors" {
    const options = .{ .status = Status{ .rx_level = 9 }, .wrap_target = @as(u5, 2), .wrap = @as(u5, 17), .out_sticky = true, .inline_out_en = true, .out_en_sel = @as(u5, 13), .side_pindir = true, .side_set_optional = true };
    try std.testing.expectEqual(@as(u32, 0x656f1119), exec_bits(options, 5));
    try std.testing.expectError(error.InvalidSetCount, validate_pin_counts(.{ .set = 6 }, false));
    try std.testing.expectError(error.InvalidSideSetCount, validate_pin_counts(.{ .side_set = 5 }, true));
    try std.testing.expectError(error.InvalidOutCount, validate_pin_counts(.{ .out = 33 }, false));
    try std.testing.expectError(error.InvalidInCount, validate_pin_counts(.{ .in = 33 }, false));
    @setEvalBranchQuota(100_000);
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        const p = comptime assembler.assemble(chip, ".program p\n.side_set 1\n.in 32\n.out 4\n.set 2\nnop side 0", .{}).get_program_by_name("p");
        const counts: PinCounts = .{ .side_set = 1, .in = 32, .out = 4, .set = 2 };
        try validate_program_counts(p, counts, false);
        var invalid = counts;
        invalid.side_set = 0;
        try std.testing.expectError(error.SideSetCountMismatch, validate_program_counts(p, invalid, false));
        invalid = counts;
        invalid.in = 7;
        try std.testing.expectError(error.InCountMismatch, validate_program_counts(p, invalid, false));
        invalid = counts;
        invalid.out = 3;
        try std.testing.expectError(error.OutCountMismatch, validate_program_counts(p, invalid, false));
        invalid = counts;
        invalid.set = 1;
        try std.testing.expectError(error.SetCountMismatch, validate_program_counts(p, invalid, false));
    }
}

pub fn ShiftOptions(chip: Chip) type {
    return switch (chip) {
        .RP2040 => struct {
            autopush: bool = false,
            autopull: bool = false,
            in_shiftdir: Direction = .right,
            out_shiftdir: Direction = .right,
            /// 0 means full 32-bits
            push_threshold: u5 = 0,
            /// 0 means full 32-bits
            pull_threshold: u5 = 0,
            join_tx: bool = false,
            join_rx: bool = false,

            pub const Direction = enum(u1) {
                left,
                right,
            };
        },
        .RP2350 => struct {
            autopush: bool = false,
            autopull: bool = false,
            in_shiftdir: Direction = .right,
            out_shiftdir: Direction = .right,
            /// 0 means full 32-bits
            push_threshold: u5 = 0,
            /// 0 means full 32-bits
            pull_threshold: u5 = 0,
            join_tx: bool = false,
            join_rx: bool = false,

            fjoin_rx_get: bool = false,
            fjoin_rx_put: bool = false,
            in_count: u5 = 0,

            pub const Direction = enum(u1) {
                left,
                right,
            };
        },
    };
}

pub fn default_shift_config(comptime chip: Chip, defaults: ProgramConfig) ShiftOptions(chip) {
    var config: ShiftOptions(chip) = .{};
    if (defaults.in_shift) |input| {
        config.in_shiftdir = if (input.right) .right else .left;
        config.autopush = input.auto;
        config.push_threshold = @truncate(input.threshold);
        if (chip == .RP2350) config.in_count = @truncate(input.count);
    }
    if (defaults.out_shift) |output| {
        config.out_shiftdir = if (output.right) .right else .left;
        config.autopull = output.auto;
        config.pull_threshold = @truncate(output.threshold);
    }
    config.join_tx = defaults.fifo == .tx;
    config.join_rx = defaults.fifo == .rx;
    return config;
}

pub fn apply_exec_overrides(defaults: anytype, overrides: anytype) @TypeOf(defaults) {
    var result = defaults;
    inline for (comptime std.meta.fieldNames(@TypeOf(overrides))) |field| {
        if (@field(overrides, field)) |value| @field(result, field) = value;
    }
    return result;
}

test "every exec override is applied, including explicit false and zero" {
    const Exec = struct {
        jmp_pin: u5 = 0,
        wrap: u5 = 31,
        wrap_target: u5 = 0,
        side_pindir: bool = false,
        side_set_optional: bool = false,
        status: Status = .{ .tx_level = 0 },
        out_sticky: bool = false,
        inline_out_en: bool = false,
        out_en_sel: u5 = 0,
    };
    const Overrides = struct {
        jmp_pin: ?u5 = null,
        wrap: ?u5 = null,
        wrap_target: ?u5 = null,
        side_pindir: ?bool = null,
        side_set_optional: ?bool = null,
        status: ?Status = null,
        out_sticky: ?bool = null,
        inline_out_en: ?bool = null,
        out_en_sel: ?u5 = null,
    };
    const wanted: Exec = .{ .jmp_pin = 7, .wrap = 9, .wrap_target = 2, .side_pindir = true, .side_set_optional = true, .status = .{ .rx_level = 4 }, .out_sticky = true, .inline_out_en = true, .out_en_sel = 3 };
    const overrides: Overrides = .{ .jmp_pin = 7, .wrap = 9, .wrap_target = 2, .side_pindir = true, .side_set_optional = true, .status = .{ .rx_level = 4 }, .out_sticky = true, .inline_out_en = true, .out_en_sel = 3 };
    try std.testing.expectEqualDeep(wanted, apply_exec_overrides(Exec{}, overrides));
    try std.testing.expectEqualDeep(wanted, apply_exec_overrides(wanted, Overrides{}));
    try std.testing.expectEqualDeep(Exec{}, apply_exec_overrides(wanted, Overrides{ .jmp_pin = 0, .wrap = 31, .wrap_target = 0, .side_pindir = false, .side_set_optional = false, .status = .{ .tx_level = 0 }, .out_sticky = false, .inline_out_en = false, .out_en_sel = 0 }));
}
