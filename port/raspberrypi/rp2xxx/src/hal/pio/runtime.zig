//! Value-only PIO register operations (40DS §3.7, 50DS §11.7).
const std = @import("std");
const Chip = @import("../chip.zig").Chip;
const assembler = @import("assembler.zig");

pub const IrqStatus = struct { flag: u3, block: enum { this, prev, next } = .this };
pub fn StatusFor(comptime chip: Chip) type {
    return if (chip == .RP2040) union(enum) { tx_level: u4, rx_level: u4 } else union(enum) { tx_level: u4, rx_level: u4, irq: IrqStatus };
}
pub const Status = StatusFor(.RP2350);

/// 50DS §11.7, SMx_EXECCTRL.STATUS_N.
pub fn status_n(irq: IrqStatus) u5 {
    return @as(u5, irq.flag) + @as(u5, switch (irq.block) {
        .this => 0,
        .prev => 8,
        .next => 16,
    });
}
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
    const bit: u5 = switch (source) {
        .rx_not_empty => |sm| @backingInt(sm),
        .tx_not_full => |sm| 4 + @as(u5, @backingInt(sm)),
        .flag => |flag| if (chip == .RP2350 or flag < 4) 8 + @as(u5, flag) else return error.UnsupportedInterruptFlag,
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

pub fn exec_bits(comptime chip: Chip, options: anytype, jmp_pin: u5) u32 {
    const status: u32 = if (comptime @hasField(@TypeOf(options.status), "irq")) switch (options.status) {
        .tx_level => |n| n,
        .rx_level => |n| @as(u32, n) | @as(u32, if (chip == .RP2040) 0x10 else 0x20),
        .irq => |irq| @as(u32, status_n(irq)) | 0x40,
    } else switch (options.status) {
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
        if (status.source == .irq) {
            if (status.n > 7) return error.UnsupportedConfig;
            config.status = .{ .irq = .{ .flag = @intCast(status.n), .block = @fromBackingInt(@intCast(@backingInt(status.block))) } };
        } else {
            if (status.n > 15) return error.UnsupportedConfig;
            config.status = if (status.source == .txfifo) .{ .tx_level = @intCast(status.n) } else .{ .rx_level = @intCast(status.n) };
        }
    }
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
        if (chip == .RP2040) try std.testing.expectError(error.UnsupportedInterruptFlag, interrupt_mask(chip, .{ .flag = 4 }));
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
    // Distinct field values, reserved bits and VERSION set: a swapped or
    // misplaced field shows (50DS §11.7 DBG_CFGINFO: 21:16, 11:8, 5:0).
    try std.testing.expectEqual(DebugConfig{ .fifo_depth = 8, .sm_count = 3, .instruction_count = 17 }, debug_config(0x1fd1_f3c8));
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
    try std.testing.expectEqual(@as(u32, 0x656f1119), exec_bits(.RP2040, options, 5));
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
    if (chip == .RP2350) {
        config.fjoin_rx_put = defaults.fifo == .txput or defaults.fifo == .putget;
        config.fjoin_rx_get = defaults.fifo == .txget or defaults.fifo == .putget;
    }
    config.join_tx = defaults.fifo == .tx;
    config.join_rx = defaults.fifo == .rx;
    return config;
}

pub fn apply_exec_overrides(defaults: anytype, overrides: anytype) @TypeOf(defaults) {
    var result = defaults;
    inline for (comptime @typeInfo(@TypeOf(overrides)).@"struct".field_names) |field| {
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

/// 50DS §11.7 GPIOBASE: the 32-pin window is independent of the package.
pub const GpioBase = enum(u5) { gpio0 = 0, gpio16 = 16 };
pub fn pin_index(base: GpioBase, pin: u32) error{InvalidPin}!u5 {
    const first: u32 = @backingInt(base);
    if (pin < first or pin >= first + 32 or pin >= 48) return error.InvalidPin;
    return @intCast(pin - first);
}
pub fn gpio_compatible(base: GpioBase, ranges: u3) bool {
    return ranges & @as(u3, if (base == .gpio0) 4 else 1) == 0;
}
pub fn validate_gpio_base(used: u32, claimed: u4) error{ InstructionMemoryInUse, StateMachinesClaimed }!void {
    if (used != 0) return error.InstructionMemoryInUse;
    // An SM can retain pin configuration without a loaded program when driven
    // through SMx_INSTR (50DS §11.5.7). Its GPIO window must remain unchanged.
    if (claimed != 0) return error.StateMachinesClaimed;
}
/// 50DS §11.4.3; pico-sdk 2.1.1 pio.c:165–172. Only absolute WAIT GPIO.
pub fn fixup_wait_gpio(instruction: u16, base: GpioBase) u16 {
    return instruction ^ @as(u16, if (instruction & 0xe060 == 0x2000) @backingInt(base) else 0);
}
pub fn gpio_range_mask(base: u6, count: u6) error{InvalidPin}!u3 {
    if (count == 0 or base >= 48 or @as(u7, base) + count > 48) return error.InvalidPin;
    var ranges: u3 = 0;
    for (base..@as(u7, base) + count) |pin| ranges |= @as(u3, 1) << @as(u2, @intCast(pin / 16));
    return ranges;
}
pub const BlockResources = struct { base: GpioBase, used: u32, claimed: u4, offset: ?u5 };
pub const GpioSelection = struct { block: u2, base: GpioBase, sm: StateMachine, offset: u5 };
/// Prefer a compatible current base; change it only with no memory used or SMs claimed.
pub fn select_gpio_program(blocks: [3]BlockResources, used_ranges: u3, pin: u6, count: u6) !GpioSelection {
    const ranges = used_ranges | try gpio_range_mask(pin, count);
    for (blocks, 0..) |block, i| {
        const sm = first_unused(block.claimed) catch continue;
        const offset = block.offset orelse continue;
        if (gpio_compatible(block.base, ranges)) return .{ .block = @intCast(i), .base = block.base, .sm = sm, .offset = offset };
        validate_gpio_base(block.used, block.claimed) catch continue;
        const other: GpioBase = if (block.base == .gpio0) .gpio16 else .gpio0;
        if (gpio_compatible(other, ranges)) return .{ .block = @intCast(i), .base = other, .sm = sm, .offset = offset };
    }
    return error.NoSpace;
}
/// 50DS §11.5.4.1: automatic PUSH is incompatible with random RX access.
pub fn validate_shift(options: ShiftOptions(.RP2350)) error{InvalidShiftOptions}!void {
    if (options.fjoin_rx_put or options.fjoin_rx_get) {
        if (options.autopush or options.join_tx or options.join_rx) return error.InvalidShiftOptions;
    }
}
/// 50DS §11.4.8.2 / §11.4.9.2. Direction names refer to the system.
pub fn validate_putget(shiftctrl: u32, write: bool) error{InvalidFifoMode}!void {
    const mode = shiftctrl & 0xc000;
    if (mode != @as(u32, if (write) 0x4000 else 0x8000) or shiftctrl & 0xc0010000 != 0) return error.InvalidFifoMode;
}
/// Byte offset within PIO, 50DS §11.7 Table 1037.
pub fn putget_offset(sm: StateMachine, index: u2) u16 {
    return 0x128 + @as(u16, @backingInt(sm)) * 16 + @as(u16, index) * 4;
}
pub const BlockMasks = struct { pio0: u4 = 0, pio1: u4 = 0, pio2: u4 = 0 };
pub const CrossControl = enum { enable_in_sync, disable, clkdiv_restart };
/// 50DS §11.7 Table 1038. Preserve unselected local SM_ENABLE bits.
pub fn cross_ctrl(block: u2, masks: BlockMasks, enabled: u4, action: CrossControl) u32 {
    std.debug.assert(block < 3);
    const all = [3]u4{ masks.pio0, masks.pio1, masks.pio2 };
    const local = all[block];
    const next = all[(@as(u3, block) + 1) % 3];
    const prev = all[(@as(u3, block) + 2) % 3];
    const neighbors = (@as(u32, prev) << 16) | (@as(u32, next) << 20);
    return neighbors | switch (action) {
        .enable_in_sync => @as(u32, enabled | local) | (@as(u32, local) << 8) | (1 << 24) | (1 << 26),
        .disable => @as(u32, enabled & ~local) | (1 << 25),
        .clkdiv_restart => @as(u32, enabled) | (@as(u32, local) << 8) | (1 << 26),
    };
}

pub fn valid_pin_mask(base: GpioBase, mask: u32, has_rp2350b: bool) bool {
    const count: u6 = if (has_rp2350b) 32 else if (base == .gpio0) 30 else 14;
    return @as(u64, mask) >> count == 0;
}

test "RP2350 interrupt routes and IRQ status encodings" {
    for (4..8) |flag| try std.testing.expectEqual(@as(u32, 1) << @as(u5, @intCast(8 + flag)), try interrupt_mask(.RP2350, .{ .flag = @intCast(flag) }));
    inline for (.{ .this, .prev, .next }, .{ 0, 8, 16 }) |block, base| {
        for (0..8) |flag| {
            const irq: IrqStatus = .{ .flag = @intCast(flag), .block = block };
            try std.testing.expectEqual(@as(u5, @intCast(base + flag)), status_n(irq));
        }
    }
    try std.testing.expect(!@hasField(StatusFor(.RP2040), "irq"));
    try std.testing.expect(@hasField(StatusFor(.RP2350), "irq"));
    const p = comptime assembler.assemble(.RP2350, ".program p\n.mov_status irq next set 7\nmov x, status", .{}).get_program_by_name("p");
    const c = try default_config(p);
    try std.testing.expectEqual(Status{ .irq = .{ .flag = 7, .block = .next } }, c.status);
    const options = .{ .status = c.status, .wrap_target = @as(u5, 0), .wrap = @as(u5, 0), .out_sticky = false, .inline_out_en = false, .out_en_sel = @as(u5, 0), .side_pindir = false, .side_set_optional = false };
    try std.testing.expectEqual(@as(u32, 0x57), exec_bits(.RP2350, options, 0));
    var rx = options;
    rx.status = .{ .rx_level = 3 };
    try std.testing.expectEqual(@as(u32, 0x23), exec_bits(.RP2350, rx, 0));
}

test "GPIO windows, package masks and real assembled WAIT fixup" {
    @setEvalBranchQuota(100_000);
    for (0..48) |pin| {
        if (pin < 32) try std.testing.expectEqual(@as(u5, @intCast(pin)), try pin_index(.gpio0, @intCast(pin))) else try std.testing.expectError(error.InvalidPin, pin_index(.gpio0, @intCast(pin)));
        if (pin >= 16) try std.testing.expectEqual(@as(u5, @intCast(pin - 16)), try pin_index(.gpio16, @intCast(pin))) else try std.testing.expectError(error.InvalidPin, pin_index(.gpio16, @intCast(pin)));
    }
    try std.testing.expectError(error.InvalidPin, pin_index(.gpio16, 48));
    try validate_gpio_base(0, 0);
    try std.testing.expectError(error.InstructionMemoryInUse, validate_gpio_base(1, 0));
    try std.testing.expect(valid_pin_mask(.gpio0, 0x3fffffff, false));
    try std.testing.expect(!valid_pin_mask(.gpio0, 0x40000000, false));
    try std.testing.expect(valid_pin_mask(.gpio16, 0x3fff, false));
    try std.testing.expect(!valid_pin_mask(.gpio16, 0x4000, false));
    try std.testing.expect(valid_pin_mask(.gpio16, 0xffffffff, true));
    const p = comptime assembler.assemble(.RP2350, ".program p\nwait 1 gpio 16\nwait 0 gpio 47\nwait 1 pin 4\nwait 1 irq 2\nwait 1 jmppin\nnop", .{}).get_program_by_name("p");
    for (p.instructions, 0..) |instruction, i| {
        try std.testing.expectEqual(instruction, fixup_wait_gpio(instruction, .gpio0));
        try std.testing.expectEqual(instruction ^ @as(u16, if (i < 2) 16 else 0), fixup_wait_gpio(instruction, .gpio16));
    }
}

test "GPIO program selection respects ranges, occupied memory, claims and space" {
    var blocks: [3]BlockResources = @splat(.{ .base = .gpio0, .used = 0, .claimed = 0, .offset = 2 });
    try std.testing.expectEqual(GpioSelection{ .block = 0, .base = .gpio16, .sm = .sm0, .offset = 2 }, try select_gpio_program(blocks, 4, 32, 16));
    blocks[0].used = 1;
    blocks[1].claimed = 15;
    try std.testing.expectEqual(@as(u2, 2), (try select_gpio_program(blocks, 4, 32, 1)).block);
    blocks[2].offset = null;
    try std.testing.expectError(error.NoSpace, select_gpio_program(blocks, 4, 32, 1));
    try std.testing.expectError(error.NoSpace, select_gpio_program(blocks, 5, 16, 1));
    try std.testing.expectError(error.InvalidPin, select_gpio_program(blocks, 0, 47, 2));
    try std.testing.expectError(error.InvalidPin, select_gpio_program(blocks, 0, 0, 0));
    try std.testing.expectEqual(@as(u3, 7), try gpio_range_mask(0, 48));
    try std.testing.expectEqual(@as(u3, 6), try gpio_range_mask(31, 2));
}

test "RX random access addresses, directions and shift validation" {
    for (0..4) |sm| for (0..4) |index| {
        try std.testing.expectEqual(@as(u16, @intCast(0x128 + sm * 16 + index * 4)), putget_offset(@fromBackingInt(@as(u2, @intCast(sm))), @intCast(index)));
    };
    for (0..4) |mode| {
        const bits = @as(u32, @intCast(mode)) << 14;
        if (mode == 2) try validate_putget(bits, false) else try std.testing.expectError(error.InvalidFifoMode, validate_putget(bits, false));
        if (mode == 1) try validate_putget(bits, true) else try std.testing.expectError(error.InvalidFifoMode, validate_putget(bits, true));
    }
    try std.testing.expectError(error.InvalidFifoMode, validate_putget(0x18000, false));
    inline for (.{ assembler.Config.Fifo.txput, .txget, .putget }) |fifo| {
        const shift = default_shift_config(.RP2350, .{ .wrap = 0, .wrap_target = 0, .fifo = fifo });
        try validate_shift(shift);
        try std.testing.expect(shift.fjoin_rx_put == (fifo != .txget));
        try std.testing.expect(shift.fjoin_rx_get == (fifo != .txput));
        var bad = shift;
        bad.autopush = true;
        try std.testing.expectError(error.InvalidShiftOptions, validate_shift(bad));
        bad = shift;
        bad.join_tx = true;
        try std.testing.expectError(error.InvalidShiftOptions, validate_shift(bad));
    }
}

test "cross-PIO control words for all target blocks and actions" {
    const masks: BlockMasks = .{ .pio0 = 1, .pio1 = 2, .pio2 = 4 };
    const neighbor_bits = [_]u32{ 0x240000, 0x410000, 0x120000 };
    for (0..3) |block| {
        const local: u4 = @as(u4, 1) << @as(u2, @intCast(block));
        const n = neighbor_bits[block];
        try std.testing.expectEqual(n | 0x05000000 | (@as(u32, local) << 8) | (8 | @as(u32, local)), cross_ctrl(@intCast(block), masks, 8, .enable_in_sync));
        try std.testing.expectEqual(n | 0x02000000 | (15 & ~@as(u32, local)), cross_ctrl(@intCast(block), masks, 15, .disable));
        try std.testing.expectEqual(n | 0x04000000 | (@as(u32, local) << 8) | 8, cross_ctrl(@intCast(block), masks, 8, .clkdiv_restart));
    }
}

/// Check WAIT's absolute pins as well as the assembler's coarse 16-pin ranges.
pub fn validate_program_gpio(program: assembler.Program, base: GpioBase, has_rp2350b: bool) error{InvalidPin}!void {
    if (!gpio_compatible(base, program.used_gpio_ranges)) return error.InvalidPin;
    const limit: u32 = if (has_rp2350b) 48 else 30;
    for (program.instructions) |instruction| {
        if (instruction & 0xe060 == 0x2000) {
            const pin = @as(u32, fixup_wait_gpio(instruction, base) & 31) + @backingInt(base);
            if (pin >= limit) return error.InvalidPin;
        }
    }
}

test "absolute WAIT rejects pins absent on the selected package" {
    @setEvalBranchQuota(100_000);
    const a = comptime assembler.assemble(.RP2350, ".program p\nwait 1 gpio 29", .{}).get_program_by_name("p");
    const b = comptime assembler.assemble(.RP2350, ".program p\nwait 1 gpio 30", .{}).get_program_by_name("p");
    const upper = comptime assembler.assemble(.RP2350, ".program p\nwait 1 gpio 47", .{}).get_program_by_name("p");
    try validate_program_gpio(a, .gpio0, false);
    try validate_program_gpio(a, .gpio16, false);
    try std.testing.expectError(error.InvalidPin, validate_program_gpio(b, .gpio0, false));
    try std.testing.expectError(error.InvalidPin, validate_program_gpio(b, .gpio16, false));
    try std.testing.expectError(error.InvalidPin, validate_program_gpio(upper, .gpio16, false));
    try validate_program_gpio(upper, .gpio16, true);
}

/// PINCTRL groups wrap within the 32-pin window (50DS §11.5.6).
pub fn mapping_mask(first: u5, count: u6) error{InvalidPinCount}!u32 {
    if (count > 32) return error.InvalidPinCount;
    var mask: u32 = 0;
    for (0..count) |i| mask |= @as(u32, 1) << (first +% @as(u5, @intCast(i)));
    return mask;
}

test "mapping masks include every pin across the window wrap" {
    try std.testing.expectEqual(@as(u32, 0xc0000003), try mapping_mask(30, 4));
    try std.testing.expectEqual(@as(u32, 0xffffffff), try mapping_mask(16, 32));
    try std.testing.expectEqual(@as(u32, 0), try mapping_mask(0, 0));
    try std.testing.expectError(error.InvalidPinCount, mapping_mask(0, 33));
    try std.testing.expect(!valid_pin_mask(.gpio0, try mapping_mask(29, 4), false));
}

test "GPIOBASE changes reject every claimed SM even without loaded instructions" {
    try validate_gpio_base(0, 0);
    for (1..16) |claimed| {
        try std.testing.expectError(error.StateMachinesClaimed, validate_gpio_base(0, @intCast(claimed)));
    }
    try std.testing.expectError(error.InstructionMemoryInUse, validate_gpio_base(1, 0));
    try std.testing.expectError(error.InstructionMemoryInUse, validate_gpio_base(1, 1));
}

test "GPIO program selection preserves the window of an SM driven by injected instructions" {
    var blocks: [3]BlockResources = @splat(.{ .base = .gpio0, .used = 0, .claimed = 0, .offset = 0 });
    // SM0 can have a configured pin mapping even though no program is loaded.
    blocks[0].claimed = 1;
    try std.testing.expectEqual(GpioSelection{ .block = 1, .base = .gpio16, .sm = .sm0, .offset = 0 }, try select_gpio_program(blocks, 0, 32, 1));
    blocks[1].claimed = 1;
    blocks[2].claimed = 1;
    try std.testing.expectError(error.NoSpace, select_gpio_program(blocks, 0, 32, 1));
    // Sharing a block remains valid if its existing window is compatible.
    try std.testing.expectEqual(GpioSelection{ .block = 0, .base = .gpio0, .sm = .sm1, .offset = 0 }, try select_gpio_program(blocks, 0, 16, 1));
    // The same guard applies when changing back from base 16 to base 0.
    for (&blocks) |*block| block.base = .gpio16;
    try std.testing.expectError(error.NoSpace, select_gpio_program(blocks, 0, 0, 1));
}
