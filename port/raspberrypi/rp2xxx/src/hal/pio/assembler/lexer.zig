//! Lexical rules shared by instruction values and full expressions.
const std = @import("std");

const keywords = std.StaticStringMap(void).initComptime(.{
    .{ "jmp", {} },
    .{ "wait", {} },
    .{ "in", {} },
    .{ "out", {} },
    .{ "push", {} },
    .{ "pull", {} },
    .{ "mov", {} },
    .{ "irq", {} },
    .{ "set", {} },
    .{ "nop", {} },
    .{ "pin", {} },
    .{ "gpio", {} },
    .{ "osre", {} },
    .{ "jmppin", {} },
    .{ "prev", {} },
    .{ "next", {} },
    .{ "pins", {} },
    .{ "null", {} },
    .{ "pindirs", {} },
    .{ "block", {} },
    .{ "noblock", {} },
    .{ "ifempty", {} },
    .{ "iffull", {} },
    .{ "nowait", {} },
    .{ "clear", {} },
    .{ "rel", {} },
    .{ "x", {} },
    .{ "y", {} },
    .{ "exec", {} },
    .{ "pc", {} },
    .{ "isr", {} },
    .{ "osr", {} },
    .{ "optional", {} },
    .{ "opt", {} },
    .{ "side", {} },
    .{ "sideset", {} },
    .{ "side_set", {} },
    .{ "status", {} },
    .{ "public", {} },
    .{ "rp2040", {} },
    .{ "rp2350", {} },
    .{ "rxfifo", {} },
    .{ "txfifo", {} },
    .{ "txrx", {} },
    .{ "tx", {} },
    .{ "rx", {} },
    .{ "txput", {} },
    .{ "txget", {} },
    .{ "putget", {} },
    .{ "left", {} },
    .{ "right", {} },
    .{ "auto", {} },
    .{ "manual", {} },
    .{ "one", {} },
    .{ "zero", {} },
});

pub fn identifier_end(source: []const u8, start: usize) usize {
    var end = start;
    while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) : (end += 1) {}
    return end;
}

pub fn is_identifier(str: []const u8) bool {
    if (str.len == 0 or (!std.ascii.isAlphabetic(str[0]) and str[0] != '_') or identifier_end(str, 0) != str.len) return false;
    var lower: [16]u8 = undefined;
    if (str.len > lower.len) return true;
    for (str, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    return !keywords.has(lower[0..str.len]);
}

pub fn number_end(source: []const u8, start: usize) usize {
    var base: u8 = 10;
    var end = start;
    if (source.len - start >= 3 and source[start] == '0') {
        switch (std.ascii.toLower(source[start + 1])) {
            'x' => base = 16,
            'b' => base = 2,
            else => {},
        }
        if (base != 10 and is_digit(source[start + 2], base)) end += 2;
    }
    while (end < source.len and is_digit(source[end], base)) : (end += 1) {}
    return end;
}

fn is_digit(c: u8, base: u8) bool {
    const digit: u8 = switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => return false,
    };
    return digit < base;
}

pub fn integer(str: []const u8) error{InvalidInteger}!i32 {
    if (str.len == 0 or !std.ascii.isDigit(str[0]) or number_end(str, 0) != str.len) return error.InvalidInteger;
    const prefixed = str.len > 2 and str[0] == '0' and (std.ascii.toLower(str[1]) == 'x' or std.ascii.toLower(str[1]) == 'b');
    const base: u8 = if (prefixed) (if (std.ascii.toLower(str[1]) == 'x') @as(u8, 16) else 2) else 10;
    return std.fmt.parseInt(i32, if (prefixed) str[2..] else str, base) catch error.InvalidInteger;
}

/// Comments are whitespace; their contents do not contain grammar tokens.
pub fn comment_end(source: []const u8, start: usize) ?usize {
    if (!std.mem.startsWith(u8, source[start..], "/*")) return null;
    const end = std.mem.indexOf(u8, source[start + 2 ..], "*/") orelse return source.len;
    return start + 2 + end + 2;
}
