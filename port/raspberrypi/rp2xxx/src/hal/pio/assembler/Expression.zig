//! pioasm expressions in prefix order, with source indices for diagnostics.
ops: BoundedOperations,
values: BoundedValues,

const std = @import("std");
const assert = std.debug.assert;

const assembler = @import("../assembler.zig");
const Diagnostics = assembler.Diagnostics;

const encoder = @import("encoder.zig");
const DefineWithIndex = encoder.DefineWithIndex;

const BoundedArray = @import("bounded-array").BoundedArray;

const Expression = @This();
const lexer = @import("lexer.zig");
const BoundedOperations = BoundedArray(OperationWithIndex, 32);
const BoundedValues = BoundedArray(Value, 32);

const Value = struct {
    str: []const u8,
    index: u32,
};

const OperationWithIndex = struct {
    op: Operation,
    index: u32,
};

const call_depth_max = 64;

pub const Operation = enum {
    add,
    sub,
    mul,
    div,
    bit_or,
    bit_and,
    bit_xor,
    shl,
    shr,
    negative,
    bit_reverse,
    value,

    pub fn format(
        op: Operation,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}", .{switch (op) {
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => "div",
            .bit_or => "or",
            .bit_and => "and",
            .bit_xor => "xor",
            .shl => "shl",
            .shr => "shr",
            .negative => "neg",
            .bit_reverse => "rev",
            .value => "val",
        }});
    }
};

pub fn tokenize(str: []const u8, index: u32, diags: *?Diagnostics) !Expression {
    var parser = Parser{ .source = str, .source_index = index, .diags = diags };
    errdefer if (diags.* == null) {
        diags.* = Diagnostics.init(index + @as(u32, @intCast(parser.cursor)), "expression is too complex", .{});
    };
    const root = try parser.expression(0, 1);
    const tail = try parser.peek();
    if (tail.tag != .end) {
        diags.* = Diagnostics.init(tail.index, "{s}", .{if (tail.tag == .close) "mismatched parenthesis" else "expected binary operator"});
        return if (tail.tag == .close) error.MismatchedParenthesis else error.InvalidExpression;
    }
    var result = Expression{ .ops = .{}, .values = .{} };
    try parser.emit(root, &result);
    return result;
}

const ParseError = error{ ExpressionTooDeep, InvalidExpression, MismatchedParenthesis, InvalidBitReverse, Overflow };
const Parser = struct {
    source: []const u8,
    source_index: u32,
    cursor: usize = 0,
    diags: *?Diagnostics,
    lookahead: ?LexToken = null,
    nodes: BoundedArray(Node, 32) = .{},

    const Node = struct {
        op: Operation,
        index: u32,
        str: []const u8 = "",
        lhs: ?u5 = null,
        rhs: ?u5 = null,
    };
    const LexToken = struct {
        tag: enum { value, operator, open, close, end },
        index: u32,
        str: []const u8,
        op: Operation = .value,
    };

    fn peek(self: *Parser) ParseError!LexToken {
        if (self.lookahead) |token| return token;
        const token = try self.read();
        self.lookahead = token;
        return token;
    }

    fn take(self: *Parser) ParseError!LexToken {
        const token = try self.peek();
        self.lookahead = null;
        return token;
    }

    fn read(self: *Parser) ParseError!LexToken {
        while (self.cursor < self.source.len) {
            if (std.mem.findScalar(u8, " \t\r", self.source[self.cursor]) != null) {
                self.cursor += 1;
            } else if (lexer.comment_end(self.source, self.cursor)) |end| {
                self.cursor = end;
            } else break;
        }
        const start = self.cursor;
        const index = self.source_index + @as(u32, @intCast(start));
        if (start == self.source.len) return .{ .tag = .end, .str = "", .index = index };
        const rest = self.source[start..];
        if (std.mem.startsWith(u8, rest, "--") or std.mem.startsWith(u8, rest, "−−")) {
            self.diags.* = Diagnostics.init(index, "unexpected decrement token in expression", .{});
            return error.InvalidExpression;
        }
        if (std.ascii.isDigit(rest[0])) {
            self.cursor = lexer.number_end(self.source, start);
            return .{ .tag = .value, .str = self.source[start..self.cursor], .index = index };
        }
        if (std.ascii.isAlphabetic(rest[0]) or rest[0] == '_') {
            self.cursor = lexer.identifier_end(self.source, start);
            const str = self.source[start..self.cursor];
            if (!lexer.is_identifier(str) and !std.ascii.eqlIgnoreCase(str, "one") and !std.ascii.eqlIgnoreCase(str, "zero")) {
                self.diags.* = Diagnostics.init(index, "keyword is not valid in an expression", .{});
                return error.InvalidExpression;
            }
            return .{ .tag = .value, .str = str, .index = index };
        }
        self.cursor += 1;
        switch (rest[0]) {
            '(' => return .{ .tag = .open, .str = rest[0..1], .index = index },
            ')' => return .{ .tag = .close, .str = rest[0..1], .index = index },
            else => {},
        }
        const op: Operation = switch (rest[0]) {
            '+' => .add,
            '-' => .sub,
            '*' => .mul,
            '/' => .div,
            '|' => .bit_or,
            '&' => .bit_and,
            '^' => .bit_xor,
            '<', '>' => blk: {
                if (rest.len < 2 or rest[1] != rest[0]) {
                    self.diags.* = Diagnostics.init(index, "expected shift operator", .{});
                    return error.InvalidExpression;
                }
                self.cursor += 1;
                break :blk if (rest[0] == '<') .shl else .shr;
            },
            ':' => blk: {
                if (rest.len < 2 or rest[1] != ':') {
                    self.diags.* = Diagnostics.init(index, "invalid bit reverse", .{});
                    return error.InvalidBitReverse;
                }
                self.cursor += 1;
                break :blk .bit_reverse;
            },
            else => {
                self.diags.* = Diagnostics.init(index, "invalid expression token", .{});
                return error.InvalidExpression;
            },
        };
        return .{ .tag = .operator, .op = op, .str = self.source[start..self.cursor], .index = index };
    }

    fn append(self: *Parser, node: Node) ParseError!u5 {
        try self.nodes.append(node);
        return @intCast(self.nodes.len - 1);
    }

    // parser.yy, low to high: REVERSE; SHL SHR; PLUS MINUS;
    // MULTIPLY DIVIDE; AND OR XOR. Binary operators associate left.
    fn expression(self: *Parser, depth: u32, minimum: u8) ParseError!u5 {
        const token = try self.take();
        if (depth >= call_depth_max) return error.ExpressionTooDeep;
        var lhs = switch (token.tag) {
            .value => try self.append(.{ .op = .value, .index = token.index, .str = token.str }),
            .open => blk: {
                const inside = try self.expression(depth + 1, 1);
                const close = try self.take();
                if (close.tag == .end) {
                    self.diags.* = Diagnostics.init(token.index, "mismatched parenthesis", .{});
                    return error.MismatchedParenthesis;
                }
                if (close.tag != .close) {
                    self.diags.* = Diagnostics.init(close.index, "expected binary operator", .{});
                    return error.InvalidExpression;
                }
                break :blk inside;
            },
            .operator => blk: {
                if (token.op != .sub and token.op != .bit_reverse) {
                    self.diags.* = Diagnostics.init(token.index, "expected expression", .{});
                    return error.InvalidExpression;
                }
                const rhs = try self.expression(depth + 1, if (token.op == .sub) 4 else 2);
                break :blk try self.append(.{ .op = if (token.op == .sub) .negative else .bit_reverse, .index = token.index, .rhs = rhs });
            },
            else => {
                self.diags.* = Diagnostics.init(token.index, "expected expression", .{});
                return error.InvalidExpression;
            },
        };
        while (true) {
            const next = try self.peek();
            if (next.tag != .operator or next.op == .bit_reverse) break;
            const precedence: u8 = switch (next.op) {
                .shl, .shr => 2,
                .add, .sub => 3,
                .mul, .div => 4,
                .bit_and, .bit_or, .bit_xor => 5,
                else => unreachable,
            };
            if (precedence < minimum) break;
            _ = try self.take();
            const rhs = try self.expression(depth + 1, precedence + 1);
            lhs = try self.append(.{ .op = next.op, .index = next.index, .lhs = lhs, .rhs = rhs });
        }
        return lhs;
    }

    fn emit(self: *const Parser, index: u5, result: *Expression) error{Overflow}!void {
        const node = self.nodes.get(index);
        try result.ops.append(.{ .op = node.op, .index = node.index });
        if (node.op == .value) try result.values.append(.{ .str = node.str, .index = node.index });
        if (node.rhs) |rhs| try self.emit(rhs, result);
        if (node.lhs) |lhs| try self.emit(lhs, result);
    }
};

const EvaluatedValue = struct {
    num: i32,
    index: u32,

    pub fn format(
        eval_value: EvaluatedValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}", .{eval_value.num});
    }
};

pub fn evaluate(
    self: Expression,
    define_lists: []const []const DefineWithIndex,
    diags: *?Diagnostics,
) !i32 {
    var values = BoundedArray(EvaluatedValue, 32).init(0) catch unreachable;
    // parse/extract values into numbers
    for (self.values.slice()) |entry| {
        const literal: ?i32 = if (std.ascii.eqlIgnoreCase(entry.str, "one")) 1 else if (std.ascii.eqlIgnoreCase(entry.str, "zero")) 0 else lexer.integer(entry.str) catch null;
        const value: EvaluatedValue = if (literal) |num| .{
            .num = num,
            .index = entry.index,
        } else blk: {
            if (entry.str.len > 0 and std.ascii.isDigit(entry.str[0])) {
                diags.* = Diagnostics.init(entry.index, "integer literal must fit in a signed 32-bit value", .{});
                return error.InvalidInteger;
            }
            // if it fails, try looking up the strings in definitions
            for (define_lists) |define_list|
                for (define_list) |define|
                    if (std.mem.eql(u8, define.name, entry.str))
                        break :blk .{
                            .num = @truncate(define.value),
                            .index = define.index,
                        };

            diags.* = Diagnostics.init(entry.index, "value doesn't parse as an integer, or define not found", .{});
            return error.UnresolvedValue;
        };

        try values.append(value);
    }

    return if (self.ops.len == 1) blk: {
        assert(self.values.len == 1);
        assert(self.ops.get(0).op == .value);

        break :blk values.get(0).num;
    } else blk: {
        const result = try recursive_evaluate(0, self.ops.slice(), values.slice(), diags);
        assert(result.consumed.ops == self.ops.len);
        assert(result.consumed.values == self.values.len);
        break :blk result.value;
    };
}

const RecursiveEvalResult = struct {
    value: i32,
    consumed: struct {
        ops: u32,
        values: u32,
    },
    index: u32,
};

fn recursive_evaluate(
    call_depth: u32,
    owis: []const OperationWithIndex,
    values: []const EvaluatedValue,
    diags: *?Diagnostics,
) !RecursiveEvalResult {
    assert(call_depth < call_depth_max);
    assert(owis.len != 0);
    assert(values.len != 0);

    return switch (owis[0].op) {
        .value => .{
            .value = values[0].num,
            .index = values[0].index,
            .consumed = .{
                .ops = 1,
                .values = 1,
            },
        },
        .negative, .bit_reverse => blk: {
            const rhs = try recursive_evaluate(call_depth + 1, owis[1..], values, diags);
            break :blk .{
                .value = if (owis[0].op == .negative) 0 -% rhs.value else @bitReverse(rhs.value),
                .index = owis[0].index,
                .consumed = .{ .ops = rhs.consumed.ops + 1, .values = rhs.consumed.values },
            };
        },
        .add, .sub, .mul, .div, .bit_or, .bit_and, .bit_xor, .shl, .shr => blk: {
            const rhs = try recursive_evaluate(call_depth + 1, owis[1..], values, diags);
            const lhs = try recursive_evaluate(call_depth + 1, owis[1 + rhs.consumed.ops ..], values[rhs.consumed.values..], diags);
            break :blk .{
                .consumed = .{
                    .ops = 1 + lhs.consumed.ops + rhs.consumed.ops,
                    .values = lhs.consumed.values + rhs.consumed.values,
                },
                .index = lhs.index,
                .value = switch (owis[0].op) {
                    .add => lhs.value +% rhs.value,
                    .sub => lhs.value -% rhs.value,
                    .mul => lhs.value *% rhs.value,
                    .div => div: {
                        if (rhs.value == 0) {
                            diags.* = Diagnostics.init(owis[0].index, "divide by zero (denominator evaluates to zero)", .{});
                            return error.DivideByZero;
                        }

                        if (lhs.value == std.math.minInt(i32) and rhs.value == -1) {
                            diags.* = Diagnostics.init(owis[0].index, "integer division overflow", .{});
                            return error.ExpressionOverflow;
                        }
                        break :div @divTrunc(lhs.value, rhs.value);
                    },
                    .bit_or => lhs.value | rhs.value,
                    .bit_and => lhs.value & rhs.value,
                    .bit_xor => lhs.value ^ rhs.value,
                    .shl, .shr => shift: {
                        // Differential probes of pico-sdk 2.1.1 pioasm built
                        // with GCC on x86_64 mask counts, including negatives.
                        const amount: u5 = @truncate(@as(u32, @bitCast(rhs.value)));
                        break :shift if (owis[0].op == .shl) lhs.value << amount else lhs.value >> amount;
                    },
                    else => unreachable,
                },
            };
        },
    };
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn expect_equal_slices_of_values(
    expected: []const Value,
    actual: []const Value,
) !void {
    for (expected, actual) |e, a| {
        try expectEqualStrings(e.str, a.str);
        try expectEqual(e.index, a.index);
    }
}

fn expect_equal_slices_of_ops(
    expected: []const OperationWithIndex,
    actual: []const OperationWithIndex,
) !void {
    for (expected, actual) |e, a| {
        try expectEqual(e.op, a.op);
        try expectEqual(e.index, a.index);
    }
}

test "expr.tokenize.integer" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("1", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 0, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 0, .str = "1" },
    }, expr.values.slice());
}

test "expr.tokenize.integer.parenthesis" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("(1)", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 1, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 1, .str = "1" },
    }, expr.values.slice());
}

test "expr.tokenize.integer.double parenthesis" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("((1))", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 2, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 2, .str = "1" },
    }, expr.values.slice());
}

test "expr.tokenize.symbol" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("BAR", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 0, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 0, .str = "BAR" },
    }, expr.values.slice());
}

test "expr.tokenize.add" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("1 + 2", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 2, .op = .add },
        .{ .index = 4, .op = .value },
        .{ .index = 0, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 4, .str = "2" },
        .{ .index = 0, .str = "1" },
    }, expr.values.slice());
}

test "expr.tokenize.add.chain" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("1 + 2 + 3", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 6, .op = .add },
        .{ .index = 8, .op = .value },
        .{ .index = 2, .op = .add },
        .{ .index = 4, .op = .value },
        .{ .index = 0, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 8, .str = "3" },
        .{ .index = 4, .str = "2" },
        .{ .index = 0, .str = "1" },
    }, expr.values.slice());
}

test "expr.tokenize.sub" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("1 - 2", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 2, .op = .sub },
        .{ .index = 4, .op = .value },
        .{ .index = 0, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 4, .str = "2" },
        .{ .index = 0, .str = "1" },
    }, expr.values.slice());
}

test "expr.tokenize.sub.nospace" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("1-2", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 1, .op = .sub },
        .{ .index = 2, .op = .value },
        .{ .index = 0, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 2, .str = "2" },
        .{ .index = 0, .str = "1" },
    }, expr.values.slice());
}

test "expr.tokenize.sub.negative" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("1 - -2", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 2, .op = .sub },
        .{ .index = 4, .op = .negative },
        .{ .index = 5, .op = .value },
        .{ .index = 0, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 5, .str = "2" },
        .{ .index = 0, .str = "1" },
    }, expr.values.slice());
}

test "expr.tokenize.mul" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("1 * 2", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 2, .op = .mul },
        .{ .index = 4, .op = .value },
        .{ .index = 0, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 4, .str = "2" },
        .{ .index = 0, .str = "1" },
    }, expr.values.slice());
}

test "expr.tokenize.div" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("1 / 2", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 2, .op = .div },
        .{ .index = 4, .op = .value },
        .{ .index = 0, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 4, .str = "2" },
        .{ .index = 0, .str = "1" },
    }, expr.values.slice());
}

test "expr.tokenize.negative" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("-1", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 0, .op = .negative },
        .{ .index = 1, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 1, .str = "1" },
    }, expr.values.slice());
}

test "expr.tokenize.bit reverse" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("::1", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 0, .op = .bit_reverse },
        .{ .index = 2, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 2, .str = "1" },
    }, expr.values.slice());
}

test "expr.tokenzie.parenthesis" {
    var diags: ?Diagnostics = null;
    const expr = try tokenize("1 * (::2 + (12 / 3)) - 5", 0, &diags);

    try expect_equal_slices_of_ops(&.{
        .{ .index = 21, .op = .sub },
        .{ .index = 23, .op = .value },
        .{ .index = 2, .op = .mul },
        .{ .index = 5, .op = .bit_reverse },
        .{ .index = 9, .op = .add },
        .{ .index = 15, .op = .div },
        .{ .index = 17, .op = .value },
        .{ .index = 12, .op = .value },
        .{ .index = 7, .op = .value },
        .{ .index = 0, .op = .value },
    }, expr.ops.slice());

    try expect_equal_slices_of_values(&.{
        .{ .index = 23, .str = "5" },
        .{ .index = 17, .str = "3" },
        .{ .index = 12, .str = "12" },
        .{ .index = 7, .str = "2" },
        .{ .index = 0, .str = "1" },
    }, expr.values.slice());
}

fn evaluate_test(expected: i128, str: []const u8, define_list: []const DefineWithIndex) !void {
    var diags: ?Diagnostics = null;
    const expr = tokenize(str, 0, &diags) catch |err| {
        if (diags) |d|
            std.log.err("{}: {s}", .{ err, d.message.slice() });

        return err;
    };

    const actual = expr.evaluate(&.{define_list}, &diags) catch |err| {
        if (diags) |d|
            std.log.err("{}: {s}", .{ err, d.message.slice() })
        else
            std.log.err("{}", .{err});

        return err;
    };

    try expectEqual(expected, actual);
}

test "expr.evaluate.integer" {
    try evaluate_test(1, "1", &.{});
}

test "expr.evaluate.symbol" {
    try evaluate_test(5, "BAR", &.{
        .{
            .name = "BAR",
            .value = 5,
            .index = 0,
        },
    });
}

test "expr.evaluate.add" {
    try evaluate_test(3, "1 + 2", &.{});
    try evaluate_test(6, "1 + 2 + 3", &.{});
}

test "expr.evaluate.sub" {
    try evaluate_test(1, "2 - 1", &.{});
    try evaluate_test(1, "(NUM_CYCLES - 1)", &.{
        .{
            .name = "NUM_CYCLES",
            .value = 2,
            .index = 1,
        },
    });
}

test "expr.evaluate.mul" {
    try evaluate_test(9, "3 * 3", &.{});
}

test "expr.evaluate.div" {
    try evaluate_test(3, "9 / 3", &.{});
    try evaluate_test(3, "9 / 3", &.{});
}

test "expr.evaluate.negative" {
    try evaluate_test(-3, "-3", &.{});
}

test "expr.evaluate.bit reverse" {
    try evaluate_test(-0x80000000, "::1", &.{});
}

test "expr.evaluate.parenthesis" {
    try evaluate_test(15, "5 * (1 + 2)", &.{});
    try evaluate_test(1 * @bitReverse(@as(u32, 2 + (12 / 3))) - 5, "1 * (::2 + (12 / 3)) - 5", &.{});
}
test "expr.pioasm precedence and associativity" {
    try evaluate_test(24, "8 * 2 | 1", &.{});
    try evaluate_test(3, "1 | 2 & 4 ^ 3", &.{});
    try evaluate_test(8, "1 << 1 + 2", &.{});
    try evaluate_test(2, "16 >> 2 >> 1", &.{});
    try evaluate_test(7, "15 & 7", &.{});
    try evaluate_test(1, "-1 + 2", &.{});
    try evaluate_test(1 - @as(i128, -1073741824), "1 - ::1 + 2", &.{});
    try evaluate_test(0, "1 * -2 + 2", &.{});
    try evaluate_test(1, "7 / 4", &.{});
    try evaluate_test(-3, "-(1 + 2)", &.{});
}

test "expr.invalid input diagnostics" {
    const cases = .{
        .{ "", error.InvalidExpression, 5, "expected expression" },
        .{ "(1", error.MismatchedParenthesis, 5, "mismatched parenthesis" },
        .{ "1)", error.MismatchedParenthesis, 6, "mismatched parenthesis" },
        .{ ":1", error.InvalidBitReverse, 5, "invalid bit reverse" },
        .{ "1 < 2", error.InvalidExpression, 7, "expected shift operator" },
        .{ "1 +", error.InvalidExpression, 8, "expected expression" },
    };
    inline for (cases) |case| {
        var diags: ?Diagnostics = null;
        try std.testing.expectError(case[1], tokenize(case[0], 5, &diags));
        try expectEqual(@as(u32, case[2]), diags.?.index);
        try expectEqualStrings(case[3], diags.?.message.slice());
    }
    const eval_cases = .{
        .{ "1 / 0", error.DivideByZero, 2, "divide by zero (denominator evaluates to zero)" },
        .{ "missing", error.UnresolvedValue, 0, "value doesn't parse as an integer, or define not found" },
        .{ "2147483648", error.InvalidInteger, 0, "integer literal must fit in a signed 32-bit value" },
        .{ "(1 << 31) / (-1)", error.ExpressionOverflow, 10, "integer division overflow" },
    };
    inline for (eval_cases) |case| {
        var diags: ?Diagnostics = null;
        const expr = try tokenize(case[0], 0, &diags);
        try std.testing.expectError(case[1], expr.evaluate(&.{}, &diags));
        try expectEqual(@as(u32, case[2]), diags.?.index);
        try expectEqualStrings(case[3], diags.?.message.slice());
    }
}
