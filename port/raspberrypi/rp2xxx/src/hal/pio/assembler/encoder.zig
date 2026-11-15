const std = @import("std");
const assert = std.debug.assert;

const assembler = @import("../assembler.zig");
const Diagnostics = assembler.Diagnostics;

const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const Value = tokenizer.Value;

const Expression = @import("Expression.zig");
const lexer = @import("lexer.zig");
const Chip = @import("../../chip.zig").Chip;

const BoundedArray = @import("bounded-array").BoundedArray;

pub const Options = struct {
    max_defines: u32 = 16,
    max_programs: u32 = 16,
};

pub fn encode(
    comptime chip: Chip,
    comptime tokens: []const Token(chip),
    diags: *?assembler.Diagnostics,
    comptime options: Options,
) !Encoder(chip, options).Output {
    var encoder = Encoder(chip, options).init(tokens);
    return encoder.encode_output(diags);
}

pub const SideSet = struct {
    count: u3,
    optional: bool,
    pindir: bool,
};

pub const Define = struct {
    name: []const u8,
    value: i128,
};

pub const DefineWithIndex = struct {
    name: []const u8,
    value: i128,
    index: u32,
};

pub fn Encoder(comptime chip: Chip, comptime options: Options) type {
    return struct {
        output: Self.Output,
        tokens: []const Token(chip),
        index: u32,
        default_version: u1 = if (chip == .RP2350) 1 else 0,

        const Self = @This();
        const Output = struct {
            global_defines: BoundedDefines,
            private_defines: BoundedDefines,
            programs: BoundedPrograms,
        };

        const BoundedDefines = BoundedArray(DefineWithIndex, options.max_defines);
        const BoundedPrograms = BoundedArray(BoundedProgram, options.max_programs);
        const BoundedInstructions = BoundedArray(Instruction(chip), 32);
        const BoundedRelocations = BoundedArray(assembler.Relocation, 32);
        const BoundedLabels = BoundedArray(Label, 32);
        const Label = struct {
            name: []const u8,
            index: u5,
            public: bool,
        };

        const BoundedProgram = struct {
            name: []const u8,
            defines: BoundedDefines,
            private_defines: BoundedDefines,
            instructions: BoundedInstructions,
            relocations: BoundedRelocations,
            labels: BoundedLabels,
            origin: ?i32,
            side_set: ?SideSet,
            wrap_target: ?u5,
            wrap: ?u5,
            config: assembler.Config = .{},
            pio_version: u1 = if (chip == .RP2350) 1 else 0,
            used_gpio_ranges: u3 = 0,

            fn comptime_copy(comptime T: type, comptime slice: []const T) []const T {
                const arr: [slice.len]T = slice[0..slice.len].*;
                return &arr;
            }

            pub fn to_exported_program(comptime bounded: BoundedProgram) assembler.Program {
                comptime var program_name: [bounded.name.len]u8 = undefined;
                std.mem.copyForwards(u8, &program_name, bounded.name);
                const name_const = program_name;
                return assembler.Program{
                    .name = &name_const,
                    .defines = blk: {
                        var tmp = BoundedArray(assembler.Define, options.max_defines).init(0) catch unreachable;
                        for (bounded.defines.slice()) |define| {
                            comptime var define_name: [define.name.len]u8 = undefined;
                            std.mem.copyForwards(u8, &define_name, define.name);
                            const const_def_name = define_name;
                            tmp.append(.{
                                .name = &const_def_name,
                                .value = @as(i64, @intCast(define.value)),
                            }) catch unreachable;
                        }

                        const defines_const = tmp;
                        break :blk defines_const.const_slice();
                    },
                    .labels = blk: {
                        var tmp = BoundedArray(assembler.Label, 32).init(0) catch unreachable;
                        for (bounded.labels.slice()) |label| {
                            if (label.public) {
                                tmp.append(.{
                                    .name = comptime_copy(u8, label.name),
                                    .index = label.index,
                                }) catch unreachable;
                            }
                        }

                        break :blk comptime_copy(assembler.Label, tmp.slice());
                    },
                    .instructions = @as([]const u16, @ptrCast(bounded.instructions.const_slice())),
                    .relocations = @as([]const assembler.Relocation, @ptrCast(bounded.relocations.const_slice())),
                    .origin = bounded.origin,
                    .side_set = bounded.side_set,
                    .wrap_target = bounded.wrap_target,
                    .wrap = bounded.wrap,
                    .config = bounded.config,
                    .pio_version = bounded.pio_version,
                    .used_gpio_ranges = bounded.used_gpio_ranges,
                };
            }
        };

        fn init(tokens: []const Token(chip)) Self {
            return Self{
                .output = Self.Output{
                    .global_defines = BoundedDefines.init(0) catch unreachable,
                    .private_defines = BoundedDefines.init(0) catch unreachable,
                    .programs = BoundedPrograms.init(0) catch unreachable,
                },
                .tokens = tokens,
                .index = 0,
            };
        }

        fn peek_token(self: Self) ?Token(chip) {
            return if (self.index < self.tokens.len)
                self.tokens[self.index]
            else
                null;
        }

        fn get_token(self: *Self) ?Token(chip) {
            return if (self.peek_token()) |token| blk: {
                self.consume(1);
                break :blk token;
            } else null;
        }

        fn consume(self: *Self, count: u32) void {
            self.index += count;
        }

        fn evaluate_impl(
            comptime T: type,
            define_lists: []const []const DefineWithIndex,
            value: Value,
            index: u32,
            diags: *?Diagnostics,
        ) !T {
            return switch (value) {
                .integer => |int| blk: {
                    if (int > std.math.maxInt(T)) {
                        diags.* = Diagnostics.init(index, "value of {} does not fit in a u{}", .{ int, @bitSizeOf(T) });
                        break :blk error.TooBig;
                    }
                    break :blk @as(T, @intCast(int));
                },
                .string => |str| outer: for (define_lists) |defines| {
                    for (defines) |define| {
                        if (std.mem.eql(u8, str, define.name)) {
                            if (define.value < std.math.minInt(T) or define.value > std.math.maxInt(T)) {
                                diags.* = Diagnostics.init(
                                    index,
                                    "{s}'s value ({}) is too large to fit in {} bits",
                                    .{ str, define.value, @bitSizeOf(T) },
                                );

                                break :outer error.TooBig;
                            }

                            break :outer @as(T, @intCast(define.value));
                        }
                    }
                } else {
                    diags.* = Diagnostics.init(index, "define '{s}' not found", .{
                        str,
                    });

                    break :outer error.DefineNotFound;
                },
                .expression => |expr_str| outer: {
                    // Most side-set and delay operands are single integers.
                    // Avoid constructing a syntax tree for those common values.
                    const result = lexer.integer(expr_str) catch result: {
                        const expr = try Expression.tokenize(expr_str, index, diags);
                        break :result try expr.evaluate(define_lists, diags);
                    };
                    if (result < std.math.minInt(T) or result > std.math.maxInt(T)) {
                        diags.* = Diagnostics.init(
                            index,
                            "value of {} does not fit in a u{}",
                            .{ result, @bitSizeOf(T) },
                        );
                        break :outer error.TooBig;
                    }

                    break :outer @as(T, @intCast(result));
                },
            };
        }

        fn value_index(self: Self, value: Value, fallback: u32) u32 {
            const text = switch (value) {
                .integer => return fallback,
                .string => |text| text,
                .expression => |text| text,
            };
            if (self.tokens.len == 0) return fallback;
            const source = self.tokens[0].source;
            var i: usize = fallback;
            while (i < source.len and source[i] != '\n') : (i += 1) {
                if (source[i..].ptr == text.ptr) return @intCast(i);
            }
            return fallback;
        }

        fn evaluate(
            self: *Self,
            comptime T: type,
            program: BoundedProgram,
            value: Value,
            index: u32,
            diags: *?Diagnostics,
        ) !T {
            var labels: BoundedArray(DefineWithIndex, 32) = .{};
            for (program.labels.slice()) |label| {
                labels.append(.{ .name = label.name, .value = label.index, .index = index }) catch unreachable;
            }
            return evaluate_impl(T, &.{
                self.output.global_defines.slice(),
                self.output.private_defines.slice(),
                program.defines.slice(),
                program.private_defines.slice(),
                labels.slice(),
            }, value, self.value_index(value, index), diags);
        }

        fn evaluate_target(
            self: *Self,
            program: BoundedProgram,
            target: []const u8,
            index: u32,
            diags: *?Diagnostics,
        ) !u5 {
            return for (program.labels.slice()) |label| {
                if (std.mem.eql(u8, target, label.name))
                    break label.index;
            } else try self.evaluate(u5, program, .{ .expression = target }, index, diags);
        }

        fn evaluate_global(
            self: *Self,
            comptime T: type,
            value: Value,
            index: u32,
            diags: *?Diagnostics,
        ) !T {
            return evaluate_impl(T, &.{
                self.output.global_defines.slice(),
                self.output.private_defines.slice(),
            }, value, self.value_index(value, index), diags);
        }

        fn check_symbol(self: Self, program: ?BoundedProgram, name: []const u8, index: u32, diags: *?Diagnostics) !void {
            for (self.output.global_defines.slice()) |define| {
                if (std.mem.eql(u8, define.name, name)) return duplicate_symbol(name, index, diags);
            }
            for (self.output.private_defines.slice()) |define| {
                if (std.mem.eql(u8, define.name, name)) return duplicate_symbol(name, index, diags);
            }
            if (program) |p| {
                for (p.defines.slice()) |define| {
                    if (std.mem.eql(u8, define.name, name)) return duplicate_symbol(name, index, diags);
                }
                for (p.private_defines.slice()) |define| {
                    if (std.mem.eql(u8, define.name, name)) return duplicate_symbol(name, index, diags);
                }
                for (p.labels.slice()) |label| {
                    if (std.mem.eql(u8, label.name, name)) return duplicate_symbol(name, index, diags);
                }
            }
        }

        fn duplicate_symbol(name: []const u8, index: u32, diags: *?Diagnostics) error{DuplicateSymbol} {
            diags.* = Diagnostics.init(index, "symbol '{s}' is already defined", .{name});
            return error.DuplicateSymbol;
        }

        fn add_define(self: *Self, program: *BoundedProgram, define: Token(chip).Define, index: u32, diags: *?Diagnostics) !void {
            try self.check_symbol(program.*, define.name, define.index, diags);
            const result = DefineWithIndex{
                .name = define.name,
                .value = try self.evaluate(i64, program.*, define.value, index, diags),
                .index = define.index,
            };
            if (define.public) try program.defines.append(result) else try program.private_defines.append(result);
        }

        fn encode_globals(self: *Self, diags: *?Diagnostics) !void {
            assert(self.index == 0);

            // read defines until program is had
            while (self.peek_token()) |token| switch (token.data) {
                .define => |define| {
                    try self.check_symbol(null, define.name, define.index, diags);
                    const result = DefineWithIndex{
                        .name = define.name,
                        .value = try self.evaluate_global(i64, define.value, token.index, diags),
                        .index = define.index,
                    };

                    if (define.public)
                        try self.output.global_defines.append(result)
                    else
                        try self.output.private_defines.append(result);

                    self.consume(1);
                },
                .config => |config| {
                    if (config != .pio_version) return error.InvalidTokenInGlobalSpace;
                    const version = try self.evaluate_global(u32, config.pio_version, token.index, diags);
                    if (version > 1) return invalid_config(token.index, diags, "PIO version must be 0 or 1");
                    if (chip == .RP2040 and version == 1) return invalid_config(token.index, diags, "PIO version 1 is not supported on RP2040");
                    self.default_version = @intCast(version);
                    self.consume(1);
                },
                .program => break,
                else => return error.InvalidTokenInGlobalSpace,
            };
        }

        fn invalid_config(index: u32, diags: *?Diagnostics, comptime message: []const u8) error{InvalidConfig} {
            diags.* = Diagnostics.init(index, message, .{});
            return error.InvalidConfig;
        }

        fn require_v1(program: BoundedProgram, index: u32, diags: *?Diagnostics) !void {
            if (program.pio_version == 0) return invalid_config(index, diags, "construct requires PIO version 1");
        }

        fn encode_config(self: *Self, program: *BoundedProgram, config: Token(chip).Config, index: u32, diags: *?Diagnostics) !void {
            switch (config) {
                .pio_version => |value| {
                    const version = try self.evaluate(u32, program.*, value, index, diags);
                    if (version > 1) return invalid_config(index, diags, "PIO version must be 0 or 1");
                    if (chip == .RP2040 and version == 1) return invalid_config(index, diags, "PIO version 1 is not supported on RP2040");
                    program.pio_version = @intCast(version);
                },
                .clock_div => |text| {
                    const value: f32 = if (std.ascii.eqlIgnoreCase(text, "one")) 1 else if (std.ascii.eqlIgnoreCase(text, "zero")) 0 else value: {
                        if (lexer.integer(text)) |integer| break :value @floatFromInt(integer) else |_| {}
                        break :value std.fmt.parseFloat(f32, text) catch return invalid_config(index, diags, "clock_div requires a numeric literal");
                    };
                    if (!std.math.isFinite(value) or value < 1 or value >= 65536) return invalid_config(index, diags, "clock divider must be in 1..<65536");
                    program.config.clock_div = value;
                },
                .fifo => |fifo| {
                    if (@backingInt(fifo) >= @backingInt(assembler.Config.Fifo.txput)) try require_v1(program.*, index, diags);
                    program.config.fifo = fifo;
                },
                .in, .out => |shift| {
                    const is_in = config == .in;
                    const dest = if (is_in) &program.config.in else &program.config.out;
                    const count = try self.evaluate(i64, program.*, shift.count, index, diags);
                    const threshold = try self.evaluate(i64, program.*, shift.threshold, index, diags);
                    if (count < @as(i64, if (is_in) 1 else 0) or count > 32) return invalid_config(index, diags, "pin count out of range");
                    if (is_in and program.pio_version == 0 and count != 32) return invalid_config(index, diags, ".in count must be 32 for PIO version 0");
                    if (threshold < 1 or threshold > 32) return invalid_config(index, diags, "shift threshold must be in 1..32");
                    dest.* = .{ .count = @intCast(count), .right = shift.right, .auto = shift.auto, .threshold = @intCast(threshold) };
                },
                .set => |value| {
                    const count = try self.evaluate(i64, program.*, value, index, diags);
                    if (count < 0 or count > 5) return invalid_config(index, diags, ".set count must be in 0..5");
                    program.config.set = @intCast(count);
                },
                .mov_status => |status| {
                    const n = try self.evaluate(i64, program.*, status.n, index, diags);
                    if (status.source == .irq) try require_v1(program.*, index, diags);
                    if (n < 0 or n > @as(i64, if (status.source == .irq) 7 else 31)) return invalid_config(index, diags, "mov_status index out of range");
                    program.config.mov_status = .{ .source = status.source, .block = status.block, .n = @intCast(n) };
                },
            }
        }

        fn encode_program_init(self: *Self, program: *BoundedProgram, diags: *?Diagnostics) !void {
            while (self.peek_token()) |token| {
                switch (token.data) {
                    .program, .label, .instruction, .word, .wrap_target => break,
                    .config => |config| {
                        switch (config) {
                            .pio_version, .fifo, .clock_div => try self.encode_config(program, config, token.index, diags),
                            else => {}, // Resolve values after collecting the program's defines.
                        }
                        self.consume(1);
                    },
                    .define => |define| {
                        try self.add_define(program, define, token.index, diags);
                        self.consume(1);
                    },
                    // Values are resolved only for the final occurrence.
                    .origin, .side_set => self.consume(1),
                    // ignore
                    .lang_opt => self.consume(1),
                    .wrap => {
                        diags.* = Diagnostics.init(token.index, ".wrap requires a preceding instruction", .{});
                        return error.InvalidWrap;
                    },
                }
            }
        }

        fn evaluate_bit_count(self: *Self, program: BoundedProgram, value: Value, index: u32, diags: *?Diagnostics) !u5 {
            const count = try self.evaluate(i128, program, value, index, diags);
            if (count < 1 or count > 32) {
                diags.* = Diagnostics.init(index, "bit count must be in 1..32", .{});
                return error.InvalidBitCount;
            }
            return @truncate(@as(u6, @intCast(count)));
        }

        fn encode_instruction(
            self: *Self,
            program: *BoundedProgram,
            token: Token(chip).Instruction,
            token_index: u32,
            instruction_count: u32,
            diags: *?Diagnostics,
        ) !void {
            const fifo = program.config.fifo orelse .txrx;
            switch (token.payload) {
                // RP2350 datasheet §11.4.6 forbids PUSH in PUT/GET modes.
                .push => if (fifo != .txrx and fifo != .rx) return invalid_config(token_index, diags, "push requires txrx or rx FIFO configuration"),
                .movtorx => {
                    try require_v1(program.*, token_index, diags);
                    if (fifo != .txput and fifo != .putget) return invalid_config(token_index, diags, "mov rxfifo[] requires txput or putget FIFO configuration");
                },
                .movfromrx => {
                    try require_v1(program.*, token_index, diags);
                    if (fifo != .txget and fifo != .putget) return invalid_config(token_index, diags, "mov osr, rxfifo[] requires txget or putget FIFO configuration");
                },
                .mov => |mov| if (chip == .RP2350 and mov.destination == .pindirs) {
                    try require_v1(program.*, token_index, diags);
                },
                .irq => |irq| if (chip == .RP2350 and (irq.idxmode == .prev or irq.idxmode == .next)) {
                    try require_v1(program.*, token_index, diags);
                },
                else => {},
            }
            // guaranteed to be an instruction variant
            const payload: Instruction(chip).Payload = switch (token.payload) {
                .nop => .{
                    .mov = .{
                        .destination = .y,
                        .operation = .none,
                        .source = .y,
                    },
                },
                .jmp => |jmp| blk: {
                    const address = try self.evaluate_target(program.*, jmp.target, token_index, diags);
                    if (address >= instruction_count) {
                        diags.* = Diagnostics.init(token_index, "jump target is outside program", .{});
                        return error.InvalidJump;
                    }
                    break :blk .{ .jmp = .{ .condition = jmp.condition, .address = address } };
                },
                .wait => |wait| blk: {
                    if ((chip == .RP2350 and wait.source == .jmppin) or wait.irq_mode != 0) try require_v1(program.*, token_index, diags);
                    const n = try self.evaluate(u32, program.*, wait.num, token_index, diags);
                    const limit: u32 = if (wait.source == .irq) 7 else if (chip == .RP2350 and wait.source == .jmppin) 3 else if (wait.source == .gpio and program.pio_version == 1) 47 else 31;
                    if (n > limit) return invalid_config(token_index, diags, "wait index out of range");
                    if (wait.source == .gpio) {
                        program.used_gpio_ranges |= @as(u3, 1) << @as(u2, @intCast(n / 16));
                        if (program.used_gpio_ranges & 5 == 5) return invalid_config(token_index, diags, "absolute GPIO ranges 0..15 and 32..47 cannot be combined");
                    }
                    break :blk .{ .wait = .{
                        .polarity = try self.evaluate(u1, program.*, wait.polarity, token_index, diags),
                        .source = wait.source,
                        .index = @as(u5, @truncate(n)) | (@as(u5, if (wait.rel) 2 else wait.irq_mode) << 3),
                    } };
                },
                .in => |in| .{
                    .in = .{
                        .source = in.source,
                        .bit_count = try self.evaluate_bit_count(program.*, in.bit_count, token_index, diags),
                    },
                },
                .out => |out| .{
                    .out = .{
                        .destination = out.destination,
                        .bit_count = try self.evaluate_bit_count(program.*, out.bit_count, token_index, diags),
                    },
                },
                .push => |push| .{
                    .push = .{
                        .if_full = @intFromBool(push.iffull),
                        .block = @intFromBool(push.block),
                    },
                },
                .pull => |pull| .{
                    .pull = .{
                        .if_empty = @intFromBool(pull.ifempty),
                        .block = @intFromBool(pull.block),
                    },
                },
                .mov => |mov| .{
                    .mov = .{
                        .destination = mov.destination,
                        .operation = mov.operation,
                        .source = mov.source,
                    },
                },
                // NOTE: These instructions values only exist for RP2350
                .movtorx => |mov| .{
                    .movtorx = .{
                        .idx = try self.evaluate(u3, program.*, mov.idx, token_index, diags),
                        .idxl = @intFromBool(!mov.idxl),
                    },
                },
                .movfromrx => |mov| .{
                    .movfromrx = .{
                        .idx = try self.evaluate(u3, program.*, mov.idx, token_index, diags),
                        .idxl = @intFromBool(!mov.idxl),
                    },
                },
                .irq => |irq| blk: {
                    switch (chip) {
                        .RP2040 => {
                            const irq_num = try self.evaluate(u3, program.*, irq.num, token_index, diags);
                            break :blk .{
                                .irq = .{
                                    .clear = @intFromBool(irq.clear),
                                    .wait = @intFromBool(irq.wait),
                                    .index = if (irq.rel)
                                        @as(u5, 0x10) | irq_num
                                    else
                                        irq_num,
                                },
                            };
                        },
                        .RP2350 => {
                            const irq_num = try self.evaluate(u3, program.*, irq.num, token_index, diags);
                            break :blk .{
                                .irq = .{
                                    .clear = @intFromBool(irq.clear),
                                    .wait = @intFromBool(irq.wait),
                                    .index = @as(u3, irq_num),
                                    .idxmode = @backingInt(irq.idxmode),
                                },
                            };
                        },
                    }
                },
                .set => |set| .{
                    .set = .{
                        .destination = set.destination,
                        .data = try self.evaluate(u5, program.*, set.value, token_index, diags),
                    },
                },
            };

            const tag: Instruction(chip).Tag = switch (token.payload) {
                .nop => .mov,
                .jmp => .jmp,
                .wait => .wait,
                .in => .in,
                .out => .out,
                .push => .push_pull_mov_rx,
                .pull => .push_pull_mov_rx,
                .movtorx => .push_pull_mov_rx,
                .movfromrx => .push_pull_mov_rx,
                .mov => .mov,
                .irq => .irq,
                .set => .set,
            };

            if (program.side_set) |side_set| {
                if (!side_set.optional and token.side_set == null) {
                    diags.* = Diagnostics.init(token_index, "'side' must be specified for this instruction because 'opt' was not specied in the .side_set directive", .{});
                    return error.InvalidSideSet;
                }
            } else {
                if (token.side_set != null) {
                    diags.* = Diagnostics.init(token_index, ".side_set directive must be specified for program to use side_set", .{});
                    return error.InvalidSideSet;
                }
            }

            const side_set: ?u5 = if (token.side_set) |s|
                try self.evaluate(u5, program.*, s, token_index, diags)
            else
                null;

            const delay: ?u5 = if (token.delay) |d|
                try self.evaluate(u5, program.*, d, token_index, diags)
            else
                null;

            const delay_side_set = calc_delay_side_set(
                program.side_set,
                side_set,
                delay,
            ) catch |err| {
                diags.* = Diagnostics.init(token_index, "delay exceeds available delay bits", .{});
                return err;
            };
            if (side_set) |value| {
                if (@as(u6, value) >= @as(u6, 1) << program.side_set.?.count) {
                    diags.* = Diagnostics.init(token_index, "side-set value exceeds declared width", .{});
                    return error.InvalidSideSet;
                }
            }

            try program.instructions.append(Instruction(chip){
                .tag = tag,
                .payload = payload,
                .delay_side_set = delay_side_set,
            });

            program.relocations.append(switch (tag) {
                .jmp => .jmpslot,
                else => .none,
            }) catch unreachable;

            std.debug.assert(program.instructions.len == program.relocations.len);
        }

        fn calc_delay_side_set(
            sideset_settings: ?SideSet,
            side_set_opt: ?u5,
            delay_opt: ?u5,
        ) !u5 {
            const delay: u5 = if (delay_opt) |delay| delay else 0;
            const bits_needed = std.math.log2_int_ceil(u6, @as(u6, delay) + 1);

            return if (sideset_settings) |sideset|
                if (sideset.optional)
                    if (sideset.count + bits_needed > 4)
                        error.SideSetDelayCollision
                    else if (side_set_opt) |side_set|
                        0x10 | (side_set << @as(u3, 4) - sideset.count) | delay
                    else
                        delay
                else if (sideset.count + bits_needed > 5)
                    error.SideSetDelayCollision
                else
                    (side_set_opt.? << @as(u3, 5) - sideset.count) | delay
            else
                delay;
        }

        fn encode_instruction_body(self: *Self, program: *BoundedProgram, config_start: u32, diags: *?Diagnostics) !void {
            // first scan through body for labels
            var instr_index: u32 = 0;
            var wrap_target_index: ?u32 = null;
            for (self.tokens[self.index..]) |token| {
                switch (token.data) {
                    .label => |label| {
                        try self.check_symbol(program.*, label.name, token.index, diags);
                        if (instr_index >= 32) {
                            diags.* = Diagnostics.init(token.index, "label exceeds instruction memory", .{});
                            return error.TooBig;
                        }
                        try program.labels.append(.{
                            .name = label.name,
                            .public = label.public,
                            .index = @intCast(instr_index),
                        });
                    },
                    .instruction, .word => {
                        if (instr_index >= 32) {
                            diags.* = Diagnostics.init(token.index, "program exceeds 32 instructions", .{});
                            return error.TooBig;
                        }
                        instr_index += 1;
                    },
                    .wrap_target => {
                        if (program.wrap_target != null) {
                            diags.* = Diagnostics.init(token.index, "wrap_target already set for this program", .{});
                            return error.WrapTargetAlreadySet;
                        }

                        if (instr_index >= 32) {
                            diags.* = Diagnostics.init(token.index, "wrap target exceeds instruction memory", .{});
                            return error.InvalidWrap;
                        }
                        program.wrap_target = @intCast(instr_index);
                        wrap_target_index = token.index;
                    },
                    .wrap => {
                        if (program.wrap != null) {
                            diags.* = Diagnostics.init(token.index, "wrap already set for this program", .{});
                            return error.WrapAlreadySet;
                        }

                        if (instr_index == 0) {
                            diags.* = Diagnostics.init(token.index, ".wrap requires a preceding instruction", .{});
                            return error.InvalidWrap;
                        }
                        program.wrap = @intCast(instr_index - 1);
                    },
                    .define => |define| try self.add_define(program, define, token.index, diags),
                    .config => |config| {
                        if (instr_index != 0 and config != .clock_div) return invalid_config(token.index, diags, "directive must precede instructions");
                        switch (config) {
                            .pio_version, .fifo, .clock_div => try self.encode_config(program, config, token.index, diags),
                            else => {},
                        }
                    },
                    .origin, .side_set => {
                        if (instr_index != 0) return invalid_config(token.index, diags, "directive must precede instructions");
                    },
                    .lang_opt => {},
                    .program => break,
                }
            }

            if (program.wrap_target) |target| {
                if (target >= instr_index) {
                    diags.* = Diagnostics.init(wrap_target_index.?, "wrap target is outside program", .{});
                    return error.InvalidWrap;
                }
            }

            // pioasm stores the last value of each deferred directive. Walk
            // backwards so overridden expressions are never resolved or checked.
            // Version, divider and FIFO checks are immediate in pioasm and have
            // already run in source order above.
            var end = config_start;
            while (end < self.tokens.len and self.tokens[end].data != .program) : (end += 1) {}
            var seen_configs: [@typeInfo(Token(chip).Config).@"union".field_names.len]bool = @splat(false);
            var seen_origin = false;
            var seen_side_set = false;
            while (end > config_start) {
                end -= 1;
                const token = self.tokens[end];
                switch (token.data) {
                    .config => |config| switch (config) {
                        .pio_version, .fifo, .clock_div => {},
                        else => {
                            const tag = @backingInt(std.meta.activeTag(config));
                            if (!seen_configs[tag]) {
                                try self.encode_config(program, config, token.index, diags);
                                seen_configs[tag] = true;
                            }
                        },
                    },
                    .origin => |value| if (!seen_origin) {
                        const origin = try self.evaluate(i32, program.*, value, token.index, diags);
                        program.origin = if (origin == -1) null else origin;
                        seen_origin = true;
                    },
                    .side_set => |side_set| if (!seen_side_set) {
                        const count = try self.evaluate(u3, program.*, side_set.count, token.index, diags);
                        if (@as(u4, count) + @intFromBool(side_set.opt) > 5) {
                            diags.* = Diagnostics.init(token.index, "side-set requires more than 5 bits", .{});
                            return error.InvalidSideSet;
                        }
                        program.side_set = .{ .count = count, .optional = side_set.opt, .pindir = side_set.pindir };
                        seen_side_set = true;
                    },
                    else => {},
                }
            }

            const fifo = program.config.fifo orelse .txrx;
            if (program.pio_version == 0) {
                if (fifo == .txput or fifo == .txget or fifo == .putget) try require_v1(program.*, 0, diags);
                if (program.config.in) |input| {
                    if (input.count != 32) return invalid_config(0, diags, ".in count must be 32 for PIO version 0");
                }
                if (program.config.mov_status) |status| {
                    if (status.source == .irq) try require_v1(program.*, 0, diags);
                }
            }
            // RP2350 datasheet §11.5.4.1: autopush is undefined in PUT/GET modes.
            if (fifo == .txput or fifo == .txget or fifo == .putget) {
                if (program.config.in) |input| {
                    if (input.auto) return invalid_config(0, diags, "autopush is incompatible with selected FIFO configuration");
                }
            }

            // encode instructions, labels will be populated
            for (self.tokens[self.index..], self.index..) |token, i| {
                switch (token.data) {
                    .instruction => |instr| try self.encode_instruction(program, instr, token.index, instr_index, diags),
                    .word => |word| {
                        try program.instructions.append(@bitCast(try self.evaluate(u16, program.*, word, token.index, diags)));
                        try program.relocations.append(.none);
                    },
                    // already processed
                    .label, .wrap_target, .wrap, .define, .lang_opt, .config, .origin, .side_set => {},
                    .program => {
                        self.index = @as(u32, @intCast(i));
                        break;
                    },
                }
            } else if (self.tokens.len > 0)
                self.index = @as(u32, @intCast(self.tokens.len));
        }

        fn encode_program(self: *Self, diags: *?Diagnostics) !?BoundedProgram {
            const program_token = self.get_token() orelse return null;
            if (program_token.data != .program)
                return error.ExpectedProgramToken;

            for (self.output.programs.slice()) |previous| {
                if (std.mem.eql(u8, previous.name, program_token.data.program)) {
                    diags.* = Diagnostics.init(program_token.index, "program is already defined", .{});
                    return error.DuplicateProgram;
                }
            }

            var program = BoundedProgram{
                .name = program_token.data.program,
                .pio_version = self.default_version,
                .defines = .{},
                .private_defines = .{},
                .instructions = .{},
                .relocations = .{},
                .labels = .{},
                .side_set = null,
                .origin = null,
                .wrap_target = null,
                .wrap = null,
            };

            const config_start = self.index;
            try self.encode_program_init(&program, diags);
            try self.encode_instruction_body(&program, config_start, diags);

            return program;
        }

        fn encode_output(self: *Self, diags: *?Diagnostics) !Self.Output {
            return self.encode_output_impl(diags) catch |err| {
                if (diags.* == null) {
                    const idx = if (self.tokens.len == 0) 0 else self.tokens[@min(self.index, self.tokens.len - 1)].index;
                    diags.* = Diagnostics.init(idx, "{s}", .{@errorName(err)});
                }
                return err;
            };
        }

        fn encode_output_impl(self: *Self, diags: *?Diagnostics) !Self.Output {
            try self.encode_globals(diags);

            while (try self.encode_program(diags)) |program|
                try self.output.programs.append(program);

            return self.output;
        }
    };
}

pub fn Instruction(comptime chip: Chip) type {
    return packed struct(u16) {
        payload: Payload,
        delay_side_set: u5,
        tag: Tag,

        pub const Payload = packed union {
            jmp: Jmp,
            wait: Wait,
            in: In,
            out: Out,
            push: Push,
            pull: Pull,
            mov: Mov,
            movtorx: MovToRx,
            movfromrx: MovFromRx,
            irq: Irq,
            set: Set,
        };

        pub const Tag = enum(u3) {
            jmp,
            wait,
            in,
            out,
            push_pull_mov_rx,
            mov,
            irq,
            set,
        };

        pub const Jmp = packed struct(u8) {
            address: u5,
            condition: Token(chip).Instruction.Jmp.Condition,
        };

        pub const Wait = packed struct(u8) {
            index: u5,
            source: Token(chip).Instruction.Wait.Source,
            polarity: u1,
        };

        pub const In = packed struct(u8) {
            bit_count: u5,
            source: Token(chip).Instruction.In.Source,
        };

        pub const Out = packed struct(u8) {
            bit_count: u5,
            destination: Token(chip).Instruction.Out.Destination,
        };

        pub const Push = packed struct(u8) {
            _reserved0: u5 = 0,
            block: u1,
            if_full: u1,
            _reserved1: u1 = 0,
        };

        pub const Pull = packed struct(u8) {
            _reserved0: u5 = 0,
            block: u1,
            if_empty: u1,
            _reserved1: u1 = 1,
        };

        pub const Mov = packed struct(u8) {
            source: Token(chip).Instruction.Mov.Source,
            operation: Token(chip).Instruction.Mov.Operation,
            destination: Token(chip).Instruction.Mov.Destination,
        };

        pub const Irq = switch (chip) {
            .RP2040 => packed struct(u8) {
                index: u5,
                wait: u1,
                clear: u1,
                reserved: u1 = 0,
            },
            .RP2350 => packed struct(u8) {
                index: u3,
                idxmode: u2,
                wait: u1,
                clear: u1,
                reserved: u1 = 0,
            },
        };

        // RP2350 only, but we need them for the switch case
        pub const MovToRx = packed struct(u8) {
            idx: u3,
            idxl: u1,
            _reserved0: u4 = 1,
        };
        pub const MovFromRx = packed struct(u8) {
            idx: u3,
            idxl: u1,
            _reserved0: u4 = 9,
        };

        pub const Set = packed struct(u8) {
            data: u5,
            destination: Token(chip).Instruction.Set.Destination,
        };
    };
}

//==============================================================================
// Encoder Tests
//==============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

fn encode_bounded_output_impl(comptime chip: Chip, source: []const u8, diags: *?assembler.Diagnostics) !Encoder(chip, .{}).Output {
    const tokens = try tokenizer.tokenize(chip, source, diags, .{});
    var encoder = Encoder(chip, .{}).init(tokens.slice());
    return try encoder.encode_output(diags);
}

fn encode_bounded_output(comptime chip: Chip, source: []const u8) !Encoder(chip, .{}).Output {
    var diags: ?assembler.Diagnostics = null;
    return encode_bounded_output_impl(chip, source, &diags) catch |err| if (diags) |d| blk: {
        std.log.info("error at index {}: {s}", .{ d.index, d.message.slice() });
        break :blk err;
    } else err;
}

test "encode.define" {
    const output = try encode_bounded_output(.RP2040, ".define foo 5");

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 1), output.private_defines.len);
    try expectEqual(@as(usize, 0), output.programs.len);

    try expectEqualStrings("foo", output.private_defines.get(0).name);
    try expectEqual(@as(i128, 5), output.private_defines.get(0).value);
}

test "encode.define.public" {
    const output = try encode_bounded_output(.RP2040, ".define PUBLIC foo 5");

    try expectEqual(@as(usize, 1), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 0), output.programs.len);
}

test "encode.program.empty" {
    const output = try encode_bounded_output(.RP2040, ".program arst");

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.programs.len);

    try expectEqualStrings("arst", output.programs.get(0).name);
    try expectEqual(@as(usize, 0), output.programs.get(0).instructions.len);
}

test "encode.program.define" {
    const output = try encode_bounded_output(.RP2040,
        \\.program arst
        \\.define bruh 7
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.programs.len);

    const program = output.programs.get(0);
    try expectEqualStrings("arst", program.name);
    try expectEqual(@as(usize, 0), program.instructions.len);

    const define = program.private_defines.get(0);
    try expectEqualStrings("bruh", define.name);
    try expectEqual(@as(i128, 7), define.value);
}

test "encode.program.define.public" {
    const output = try encode_bounded_output(.RP2040,
        \\.program arst
        \\.define public bruh 7
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.programs.len);

    const program = output.programs.get(0);
    try expectEqualStrings("arst", program.name);
    try expectEqual(@as(usize, 0), program.instructions.len);

    const define = program.defines.get(0);
    try expectEqualStrings("bruh", define.name);
    try expectEqual(@as(i128, 7), define.value);
}

test "encode.program.define.namespaced" {
    const output = try encode_bounded_output(.RP2040,
        \\.program arst
        \\.define public bruh 7
        \\.program what
        \\.define public hi 8
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 2), output.programs.len);

    const program_arst = output.programs.get(0);
    try expectEqualStrings("arst", program_arst.name);
    try expectEqual(@as(usize, 0), program_arst.instructions.len);

    const define_bruh = program_arst.defines.get(0);
    try expectEqualStrings("bruh", define_bruh.name);
    try expectEqual(@as(i128, 7), define_bruh.value);

    const program_what = output.programs.get(1);
    try expectEqualStrings("what", program_what.name);
    try expectEqual(@as(usize, 0), program_what.instructions.len);

    const define_hi = program_what.defines.get(0);
    try expectEqualStrings("hi", define_hi.name);
    try expectEqual(@as(i128, 8), define_hi.value);
}

test "encode.origin" {
    const output = try encode_bounded_output(.RP2040,
        \\.program arst
        \\.origin 0
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.programs.len);

    const program = output.programs.get(0);
    try expectEqualStrings("arst", program.name);
    try expectEqual(@as(usize, 0), program.instructions.len);

    try expectEqual(@as(?i32, 0), program.origin);
}

test "encode.wrap_target" {
    const output = try encode_bounded_output(.RP2040,
        \\.program arst
        \\nop
        \\.wrap_target
        \\nop
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.programs.len);

    const program = output.programs.get(0);
    try expectEqualStrings("arst", program.name);
    try expectEqual(@as(usize, 2), program.instructions.len);

    try expectEqual(@as(?u5, 1), program.wrap_target);
}

test "encode.wrap" {
    const output = try encode_bounded_output(.RP2040,
        \\.program arst
        \\nop
        \\.wrap
        \\nop
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.programs.len);

    const program = output.programs.get(0);
    try expectEqualStrings("arst", program.name);
    try expectEqual(@as(usize, 2), program.instructions.len);

    try expectEqual(@as(?u5, 0), program.wrap);
}

test "encode.side_set" {
    const output = try encode_bounded_output(.RP2040,
        \\.program arst
        \\.side_set 1
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.programs.len);

    const program = output.programs.get(0);
    try expectEqual(@as(?u5, 1), program.side_set.?.count);
}

test "encode.side_set.opt" {
    const output = try encode_bounded_output(.RP2040,
        \\.program arst
        \\.side_set 1 opt
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.programs.len);

    const program = output.programs.get(0);
    try expectEqual(@as(?u5, 1), program.side_set.?.count);
    try expect(program.side_set.?.optional);
}

test "encode.side_set.pindirs" {
    const output = try encode_bounded_output(.RP2040,
        \\.program arst
        \\.side_set 1 pindirs
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.programs.len);

    const program = output.programs.get(0);
    try expectEqual(@as(?u5, 1), program.side_set.?.count);
    try expect(program.side_set.?.pindir);
}

test "encode.label" {
    const output = try encode_bounded_output(.RP2040,
        \\.program arst
        \\nop
        \\my_label:
        \\nop
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.programs.len);

    const program = output.programs.get(0);
    try expectEqual(@as(usize, 1), program.labels.len);

    const label = program.labels.get(0);
    try expectEqualStrings("my_label", label.name);
    try expectEqual(@as(u32, 1), label.index);
    try expectEqual(false, label.public);
}

test "encode.label.public" {
    const output = try encode_bounded_output(.RP2040,
        \\.program arst
        \\nop
        \\nop
        \\public my_label:
        \\nop
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.programs.len);

    const program = output.programs.get(0);
    try expectEqual(@as(usize, 1), program.labels.len);

    const label = program.labels.get(0);
    try expectEqualStrings("my_label", label.name);
    try expectEqual(@as(u32, 2), label.index);
    try expectEqual(true, label.public);
}

test "encode.side_set.bits" {
    const output = try encode_bounded_output(.RP2040,
        \\.program arst
        \\.side_set 1 opt
        \\nop side 1
        \\nop [1]
        \\nop side 0 [1]
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.programs.len);

    const program = output.programs.get(0);

    const instr0 = program.instructions.get(0);
    try expectEqual(@as(u5, 0x18), instr0.delay_side_set);

    const instr1 = program.instructions.get(1);
    try expectEqual(@as(u5, 0x1), instr1.delay_side_set);

    const instr2 = program.instructions.get(2);
    try expectEqual(@as(u5, 0x11), instr2.delay_side_set);
}

test "encode.evaluate.global" {
    const output = try encode_bounded_output(.RP2040,
        \\.define NUM 5
        \\.define public FOO NUM
    );

    try expectEqual(@as(usize, 1), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.global_defines.len);
    try expectEqualStrings("FOO", output.global_defines.get(0).name);
    try expectEqual(@as(i128, 5), output.global_defines.get(0).value);
}

test "encode.evaluate.addition" {
    const output = try encode_bounded_output(.RP2040,
        \\.define public FOO (1+5)
    );

    try expectEqual(@as(usize, 1), output.global_defines.len);
    try expectEqualStrings("FOO", output.global_defines.get(0).name);
    try expectEqual(@as(i128, 6), output.global_defines.get(0).value);
}

test "encode.evaluate.subtraction" {
    const output = try encode_bounded_output(.RP2040,
        \\.define public FOO (5-1)
    );

    try expectEqual(@as(usize, 1), output.global_defines.len);
    try expectEqualStrings("FOO", output.global_defines.get(0).name);
    try expectEqual(@as(i128, 4), output.global_defines.get(0).value);
}

test "encode.evaluate.multiplication" {
    const output = try encode_bounded_output(.RP2040,
        \\.define public FOO (5*2)
    );

    try expectEqual(@as(usize, 1), output.global_defines.len);
    try expectEqualStrings("FOO", output.global_defines.get(0).name);
    try expectEqual(@as(i128, 10), output.global_defines.get(0).value);
}

test "encode.evaluate.division" {
    const output = try encode_bounded_output(.RP2040,
        \\.define public FOO (6/2)
    );

    try expectEqual(@as(usize, 1), output.global_defines.len);
    try expectEqualStrings("FOO", output.global_defines.get(0).name);
    try expectEqual(@as(i128, 3), output.global_defines.get(0).value);
}

test "encode.evaluate.bit reversal" {
    const output = try encode_bounded_output(.RP2040,
        \\.define public FOO ::1
    );

    try expectEqual(@as(usize, 1), output.global_defines.len);
    try expectEqualStrings("FOO", output.global_defines.get(0).name);
    try expectEqual(@as(i128, -0x80000000), output.global_defines.get(0).value);
}

test "encode.evaluate.value size" {
    const bits = encode_bounded_output(.RP2040,
        \\.program delay_too_big
        \\nop [32]
    );
    try expectError(error.TooBig, bits);
}

test "encode.jmp.label" {
    const output = try encode_bounded_output(.RP2040,
        \\.program arst
        \\nop
        \\my_label:
        \\nop
        \\nop
        \\jmp my_label
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 1), output.programs.len);

    const program = output.programs.get(0);
    try expectEqual(@as(usize, 1), program.labels.len);

    const label = program.labels.get(0);
    try expectEqualStrings("my_label", label.name);
    try expectEqual(@as(u32, 1), label.index);
    try expectEqual(false, label.public);

    const instr = program.instructions.get(3);
    try expectEqual(Instruction(.RP2040).Tag.jmp, instr.tag);
    try expectEqual(@as(u5, 0), instr.delay_side_set);
    try expectEqual(Token(.RP2040).Instruction.Jmp.Condition.always, instr.payload.jmp.condition);
    try expectEqual(@as(u5, 1), instr.payload.jmp.address);
}

test "encode.jmp.label origin" {
    const output = try encode_bounded_output(.RP2040,
        \\.program program_at_4
        \\.origin 4
        \\nop
        \\program_at_4__label:
        \\nop
        \\jmp program_at_4__label
        \\.program program_at_20
        \\.origin 20
        \\nop
        \\nop
        \\program_at_20__label:
        \\nop
        \\jmp program_at_20__label
    );

    try expectEqual(@as(usize, 0), output.global_defines.len);
    try expectEqual(@as(usize, 0), output.private_defines.len);
    try expectEqual(@as(usize, 2), output.programs.len);

    {
        const program = output.programs.get(0);
        try expectEqual(@as(usize, 1), program.labels.len);

        const label = program.labels.get(0);
        try expectEqualStrings("program_at_4__label", label.name);
        try expectEqual(@as(u32, 1), label.index);
        try expectEqual(false, label.public);

        const instr = program.instructions.get(2);
        try expectEqual(Instruction(.RP2040).Tag.jmp, instr.tag);
        try expectEqual(@as(u5, 0), instr.delay_side_set);
        try expectEqual(Token(.RP2040).Instruction.Jmp.Condition.always, instr.payload.jmp.condition);
        try expectEqual(@as(u5, 1), instr.payload.jmp.address);
    }

    {
        const program = output.programs.get(1);
        try expectEqual(@as(usize, 1), program.labels.len);

        const label = program.labels.get(0);
        try expectEqualStrings("program_at_20__label", label.name);
        try expectEqual(@as(u32, 2), label.index);
        try expectEqual(false, label.public);

        const instr = program.instructions.get(3);
        try expectEqual(Instruction(.RP2040).Tag.jmp, instr.tag);
        try expectEqual(@as(u5, 0), instr.delay_side_set);
        try expectEqual(Token(.RP2040).Instruction.Jmp.Condition.always, instr.payload.jmp.condition);
        try expectEqual(@as(u5, 2), instr.payload.jmp.address);
    }
}

test "encode.error.sideset delay collision" {
    const collision = encode_bounded_output(.RP2040,
        \\.program sideset_delay_collision
        \\.side_set 2
        \\nop side 3 [8]
    );
    try expectError(error.SideSetDelayCollision, collision);

    const collision2 = encode_bounded_output(.RP2040,
        \\.program sideset_delay_collision
        \\.side_set 1
        \\nop side 3 [31]
    );
    try expectError(error.SideSetDelayCollision, collision2);

    const collision3 = encode_bounded_output(.RP2040,
        \\.program sideset_delay_collision
        \\.side_set 1 opt
        \\nop side 3 [31]
    );
    try expectError(error.SideSetDelayCollision, collision3);

    _ = try encode_bounded_output(.RP2040,
        \\.program sideset_delay_collision
        \\.side_set 2
        \\nop side 3 [7]
    );

    _ = try encode_bounded_output(.RP2040,
        \\.program sideset_delay_collision
        \\nop [31]
    );
}

test "encode.error.sideset opt delay collision" {
    const collision = encode_bounded_output(.RP2040,
        \\.program sideset_delay_collision
        \\.side_set 2 opt
        \\nop side 3 [4]
    );
    try expectError(error.SideSetDelayCollision, collision);

    _ = try encode_bounded_output(.RP2040,
        \\.program sideset_delay_collision
        \\.side_set 2 opt
        \\nop side 3 [3]
    );
}

//test "encode.error.duplicated program name" {}
//test "encode.error.duplicated define" {}
//test "encode.error.multiple side_set" {}
//test "encode.error.label with no instruction" {}
//test "encode.error.label with no instruction" {}

// Test Plan
// =========
//
// - .program name validation
// - .origin in program init and in program body
// - .side_set must be in the program init
// - .wrap_target must come before an instruction, defaults to start of a program
// - .wrap_target must only be used once in a program
// - .wrap must be placed after an instruction, defaults to end of a program
// - .wrap must only be used once in a program
// -
//
fn expect_diagnostic(comptime source: []const u8, expected_error: anyerror, index: u32, message: []const u8) !void {
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        var diags: ?Diagnostics = null;
        try expectError(expected_error, encode_bounded_output_impl(chip, source, &diags));
        try expectEqual(index, diags.?.index);
        try expectEqualStrings(message, diags.?.message.slice());
    }
}

test "encode.range diagnostics" {
    try expect_diagnostic(".program p\nin pins, 0", error.InvalidBitCount, 11, "bit count must be in 1..32");
    try expect_diagnostic(".program p\nout pins, 33", error.InvalidBitCount, 11, "bit count must be in 1..32");
    try expect_diagnostic(".program p\nout pins, 64", error.InvalidBitCount, 11, "bit count must be in 1..32");
    try expect_diagnostic(".program p\nin pins, (-1)", error.InvalidBitCount, 11, "bit count must be in 1..32");
    try expect_diagnostic(".program p\nset pins, 32", error.TooBig, 11, "value of 32 does not fit in a u5");
    try expect_diagnostic(".program p\n.side_set 1\nnop side 2", error.InvalidSideSet, 23, "side-set value exceeds declared width");
    try expect_diagnostic(".program p\n.side_set 1 opt\nnop side 2", error.InvalidSideSet, 27, "side-set value exceeds declared width");
    try expect_diagnostic(".program p\n.side_set 1\nnop side 1 [16]", error.SideSetDelayCollision, 23, "delay exceeds available delay bits");
    try expect_diagnostic(".program p\n.side_set 1 opt\nnop [8]", error.SideSetDelayCollision, 27, "delay exceeds available delay bits");
    try expect_diagnostic(".program p\n.side_set 6\nnop", error.InvalidSideSet, 12, "side-set requires more than 5 bits");
    try expect_diagnostic(".program p\n.side_set 5 opt\nnop", error.InvalidSideSet, 12, "side-set requires more than 5 bits");
    try expect_diagnostic(".program p\nnop [32]", error.TooBig, 16, "value of 32 does not fit in a u5");
}

test "encode.user input formerly unreachable diagnostics" {
    try expect_diagnostic(".program p\n.wrap", error.InvalidWrap, 12, ".wrap requires a preceding instruction");
    try expect_diagnostic(".program p\nnop\n.origin 1", error.InvalidConfig, 16, "directive must precede instructions");
    try expect_diagnostic(".program p\nnop\n.side_set 1", error.InvalidConfig, 16, "directive must precede instructions");
}

test "encode.expressions and default wait polarity" {
    const output = try encode_bounded_output(.RP2040,
        \\.define N 8 * 2 | 1
        \\.program p
        \\*entry:
        \\in pins, N
        \\out pins, (1 << 5)
        \\wait gpio 2
        \\wait (1-1) irq (2+1) rel
    );
    const program = output.programs.get(0);
    try expectEqual(@as(u5, 24), program.instructions.get(0).payload.in.bit_count);
    try expectEqual(@as(u5, 0), program.instructions.get(1).payload.out.bit_count);
    try expectEqual(@as(u1, 1), program.instructions.get(2).payload.wait.polarity);
    try expectEqual(@as(u1, 0), program.instructions.get(3).payload.wait.polarity);
    try expect(program.labels.get(0).public);
}
// Each expression below was rejected by pico-sdk 2.1.1 pioasm after its
// signed 32-bit evaluation. Check both the rejection and the operand caret.
test "encode.negative int32 expression diagnostics" {
    const cases = .{
        .{ "((1 << 31) >> 31)", -1 },
        .{ "(2147483647 + 1)", -2147483648 },
        .{ "((-2147483647) - 1)", -2147483648 },
        .{ "((1 << 30) * 2)", -2147483648 },
        .{ "((1 << 31) / 2)", -1073741824 },
        .{ "(-(1 << 31))", -2147483648 },
        .{ "((1 << 31) | 1)", -2147483647 },
        .{ "((1 << 31) & (-1))", -2147483648 },
        .{ "((1 << 31) ^ 1)", -2147483647 },
        .{ "(::1)", -2147483648 },
        .{ "(1 << (-1))", -2147483648 },
    };
    inline for (cases) |case| {
        try expect_diagnostic(".program p\nset pins, " ++ case[0], error.TooBig, 21, std.fmt.comptimePrint("value of {} does not fit in a u5", .{case[1]}));
    }
}

// Differential rejection probes against pico-sdk 2.1.1 lexer.ll/parser.yy.
test "encode.expression token boundary diagnostics" {
    const cases = .{
        .{ "(--1)", 22, "unexpected decrement token in expression" },
        .{ "(1--2)", 23, "unexpected decrement token in expression" },
        .{ "(−−1)", 22, "unexpected decrement token in expression" },
        .{ "(1::2)", 23, "expected binary operator" },
        .{ "(1!=2)", 23, "invalid expression token" },
        .{ "(1 < < 2)", 24, "expected shift operator" },
        .{ "(1>>>2)", 25, "expected shift operator" },
        .{ "(1&&2)", 24, "expected expression" },
        .{ "(1||2)", 24, "expected expression" },
        .{ "(0o10)", 23, "expected binary operator" },
        .{ "(1_0)", 23, "expected binary operator" },
        .{ "(0x1_f)", 25, "expected binary operator" },
        .{ "(0b1_0)", 25, "expected binary operator" },
        .{ "(1e1)", 23, "expected binary operator" },
        .{ "(1.0)", 23, "invalid expression token" },
        .{ "(1 + +2)", 26, "expected expression" },
        .{ "(pins)", 22, "keyword is not valid in an expression" },
        .{ "(::)", 24, "expected expression" },
        .{ "(1\n+2)", 23, "invalid expression token" },
    };
    inline for (cases) |case| {
        try expect_diagnostic(".program p\nset pins, " ++ case[0], error.InvalidExpression, case[1], case[2]);
    }
}
test "encode.lang_opt quoting and label line diagnostics" {
    try expect_diagnostic(".program p\n.lang_opt c_sdk foo = \"unterminated", error.InvalidExpression, 33, "unterminated .lang_opt string");
    try expect_diagnostic(".program p\n.lang_opt c_sdk foo = 1 ;x", error.InvalidExpression, 35, "unexpected token after .lang_opt value");
    try expect_diagnostic(".program p\n.lang_opt 1 foo = bar", error.InvalidExpression, 21, "expected .lang_opt language name = value");
    try expect_diagnostic(".program p\n.lang_opt c_sdk foo = ", error.MissingArg, 33, "expected .lang_opt language name = value");
    try expect_diagnostic(".program p\na:b:nop\n", error.InvalidExpression, 13, "only one label is allowed on a line");
    try expect_diagnostic(".program p\na: .word 1\n", error.InvalidExpression, 14, "expected instruction after label");
    try expect_diagnostic(".program p\na: % c-sdk {\n%}\n", error.InvalidExpression, 14, "expected instruction after label");
}

test "encode.corpus discovered rejection diagnostics" {
    try expect_diagnostic(".program p\njmp 1\n", error.InvalidJump, 11, "jump target is outside program");
    try expect_diagnostic(".program p\n.define N 1\n.define N 2\nset pins,N\n", error.DuplicateSymbol, 31, "symbol 'N' is already defined");
    try expect_diagnostic(".program p\nnop\n.program p\nnop\n", error.DuplicateProgram, 16, "program is already defined");
    try expect_diagnostic(".program p\nnop\n.wrap_target\n", error.InvalidWrap, 16, "wrap target is outside program");
}
