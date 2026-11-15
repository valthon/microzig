const std = @import("std");

const BoundedArray = @import("bounded-array").BoundedArray;

const Chip = @import("../chip.zig").Chip;

pub const tokenizer = @import("assembler/tokenizer.zig");
pub const encoder = @import("assembler/encoder.zig");
pub const TokenizeOptions = tokenizer.Options;
pub const EncodeOptions = encoder.Options;

pub const Define = struct {
    name: []const u8,
    value: i64,
};

pub const Label = struct {
    name: []const u8,
    index: u5,
};

pub const Program = struct {
    name: []const u8,
    defines: []const Define,
    /// Public labels
    labels: []const Label,

    /// Stores the raw instruction stream.
    instructions: []const u16,
    /// For each instruction, stores the kind of relocation required on load.
    relocations: []const Relocation,

    origin: ?i32,
    side_set: ?encoder.SideSet,
    wrap_target: ?u5,
    wrap: ?u5,

    pub fn get_mask(program: Program) u32 {
        return @intCast((@as(u64, 1) << @as(u6, @intCast(program.instructions.len))) - 1);
    }

    pub fn get_label_index(program: Program, name: []const u8) ?u5 {
        return for (program.labels) |label| {
            if (std.mem.eql(u8, label.name, name))
                break label.index;
        } else null;
    }
};

pub const Relocation = union(enum) {
    /// Keep the instruction as-is.
    none,

    /// Add the program origin to the lower 5 bit of the instruction.
    jmpslot,
};

pub const Output = struct {
    defines: []const Define,
    programs: []const Program,

    pub fn get_program_by_name(
        comptime output: Output,
        comptime name: []const u8,
    ) Program {
        return for (output.programs) |program| {
            if (std.mem.eql(u8, name, program.name))
                break program;
        } else @panic(std.fmt.comptimePrint("program '{s}' not found", .{name}));
    }

    pub fn get_define_by_name(
        comptime output: Output,
        comptime name: []const u8,
    ) i64 {
        return for (output.defines) |define| {
            if (std.mem.eql(u8, name, define.name))
                break define.value;
        } else @panic(std.fmt.comptimePrint("define '{s}' not found", .{name}));
    }
};

pub const AssembleOptions = struct {
    tokenize: TokenizeOptions = .{},
    encode: EncodeOptions = .{},
};

pub const Diagnostics = struct {
    message: BoundedArray(u8, 256),
    index: u32,

    pub fn init(index: u32, comptime fmt: []const u8, args: anytype) Diagnostics {
        var ret = Diagnostics{
            .message = BoundedArray(u8, 256).init(0) catch unreachable,
            .index = index,
        };

        var writer = ret.message.writer();

        // A long user identifier may exceed the diagnostic buffer. Keep the
        // formatted prefix, which still explains the error at the same location.
        writer.interface.print(fmt, args) catch return ret;
        return ret;
    }
};

/// Creates a copy of a slice at comptime that is guaranteed to be immutable.
fn comptime_copy(comptime T: type, comptime slice: []const T) []const T {
    const arr: [slice.len]T = slice[0..slice.len].*;
    return &arr;
}

pub fn assemble_impl(comptime chip: Chip, comptime source: []const u8, diags: *?Diagnostics, options: AssembleOptions) !Output {
    const tokens = try tokenizer.tokenize(chip, source, diags, options.tokenize);
    const encoder_output = try encoder.encode(chip, tokens.slice(), diags, options.encode);
    var programs = BoundedArray(Program, options.encode.max_programs).init(0) catch unreachable;
    for (encoder_output.programs.slice()) |bounded|
        try programs.append(bounded.to_exported_program());

    var defines = BoundedArray(Define, options.encode.max_defines).init(0) catch unreachable;
    for (encoder_output.global_defines.slice()) |define|
        try defines.append(.{ .name = define.name, .value = define.value });

    return Output{
        .defines = comptime_copy(Define, defines.slice()),
        .programs = comptime_copy(Program, programs.slice()),
    };
}

fn format_compile_error(comptime message: []const u8, comptime source: []const u8, comptime index: u32) []const u8 {
    const caret = @min(index, source.len);
    const start = if (std.mem.lastIndexOfScalar(u8, source[0..caret], '\n')) |newline| newline + 1 else 0;
    const end = if (std.mem.indexOfScalar(u8, source[caret..], '\n')) |newline| caret + newline else source.len;
    const line_str = source[start..end];
    const column = caret - start;

    const indent: [column]u8 = @splat(' ');

    return std.fmt.comptimePrint(
        \\failed to assemble PIO code:
        \\
        \\{s}
        \\{s}^
        \\{s}{s}
        \\
    , .{
        line_str,
        indent,
        indent,
        message,
    });
}

pub fn assemble(comptime chip: Chip, comptime source: []const u8, comptime options: AssembleOptions) Output {
    // Budget the lexer and expression parser here instead of requiring callers
    // to track the assembler's internal comptime work.
    @setEvalBranchQuota(10_000);
    var diags: ?Diagnostics = null;
    return assemble_impl(chip, source, &diags, options) catch |err| {
        if (diags) |d|
            @compileError(format_compile_error(d.message.slice(), source, d.index));
        @compileError(@errorName(err));
    };
}

test "tokenizer and encoder" {
    std.testing.refAllDecls(tokenizer);
    std.testing.refAllDecls(@import("assembler/Expression.zig"));
    std.testing.refAllDecls(encoder);
}

test "differential corpus" {
    std.testing.refAllDecls(@import("assembler/corpus_tests.zig"));
}

test "comparison" {
    std.testing.refAllDecls(@import("assembler/comparison_tests.zig"));
}

test "assemble" {
    // Test that the assembler can compile a simple program
    // this also verifies that the assemble function can be compiled
    _ = comptime assemble(.RP2040, ".program testprog", .{})
        .get_program_by_name("testprog");
}

test "get_define_by_name" {
    const output = comptime assemble(.RP2040,
        \\.define PUBLIC T1 3
        \\.program testprog
        \\    nop
    , .{});
    try std.testing.expectEqual(@as(i64, 3), comptime output.get_define_by_name("T1"));
}

test "format compile error" {
    const result = comptime format_compile_error(
        "invalid instruction",
        ".program testprog\n bad",
        19,
    );
    try std.testing.expectEqualStrings(
        \\failed to assemble PIO code:
        \\
        \\ bad
        \\ ^
        \\ invalid instruction
        \\
    , result);
}

test "word keeps relocation entries aligned" {
    @setEvalBranchQuota(100_000);
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        const program = comptime assemble(chip,
            \\.program words
            \\.word 0
            \\jmp 0
            \\.word 0xffff
        , .{}).get_program_by_name("words");
        try std.testing.expectEqual(program.instructions.len, program.relocations.len);
        try std.testing.expectEqual(Relocation.none, program.relocations[0]);
        try std.testing.expectEqual(Relocation.jmpslot, program.relocations[1]);
        try std.testing.expectEqual(Relocation.none, program.relocations[2]);
    }
}

test "full instruction memory mask" {
    @setEvalBranchQuota(100_000);
    const program = comptime assemble(.RP2040, ".program full\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\n", .{}).get_program_by_name("full");
    try std.testing.expectEqual(@as(u32, 0xffffffff), program.get_mask());
}
test "format compile error at empty input and after blank lines" {
    const empty = comptime format_compile_error("missing value", "", 0);
    try std.testing.expect(std.mem.indexOf(u8, empty, "^\nmissing value") != null);
    const after_blank = comptime format_compile_error("bad", "\n\n nop\n", 3);
    try std.testing.expect(std.mem.indexOf(u8, after_blank, " nop\n ^\n bad") != null);
}
