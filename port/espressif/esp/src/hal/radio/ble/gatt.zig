//! Single-connection, MTU-23 ATT server. Bluetooth Core Vol 3, Part F §3.4.
//! GAP Device Name plus FFF0 / FFF1 (read, write, command) / FFF2 (notify).
const std = @import("std");
const wire = @import("protocol.zig");
const read16 = wire.read16;
const write16 = wire.write16;
pub const mtu = 23;
pub const value_handle = 6;
pub const notify_handle = 8;
pub const cccd_handle = 9;
const types = [_]u16{ 0x2800, 0x2803, 0x2a00, 0x2800, 0x2803, 0xfff1, 0x2803, 0xfff2, 0x2902 };
pub const Server = struct {
    name: [20]u8 = @splat(0),
    name_len: u8 = 0,
    value: [20]u8 = @splat(0),
    value_len: u8 = 0,
    subscribed: bool = false,
    counter: u32 = 0,

    pub fn init(name: []const u8) wire.Error!Server {
        if (name.len == 0 or name.len > 20) return error.InvalidName;
        var self: Server = .{};
        @memcpy(self.name[0..name.len], name);
        self.name_len = @intCast(name.len);
        return self;
    }
    pub fn disconnected(self: *Server) void {
        self.subscribed = false;
        self.counter = 0;
    }

    fn value_of(self: *const Server, handle: u16, out: *[20]u8) ?[]const u8 {
        switch (handle) {
            1 => {
                out[0..2].* = .{ 0, 0x18 };
                return out[0..2];
            },
            2 => {
                out[0..5].* = .{ 2, 3, 0, 0, 0x2a };
                return out[0..5];
            },
            3 => return self.name[0..self.name_len],
            4 => {
                out[0..2].* = .{ 0xf0, 0xff };
                return out[0..2];
            },
            5 => {
                out[0..5].* = .{ 0x0e, value_handle, 0, 0xf1, 0xff };
                return out[0..5];
            },
            value_handle => return self.value[0..self.value_len],
            7 => {
                out[0..5].* = .{ 0x10, notify_handle, 0, 0xf2, 0xff };
                return out[0..5];
            },
            notify_handle => return null,
            cccd_handle => {
                out[0..2].* = .{ @intFromBool(self.subscribed), 0 };
                return out[0..2];
            },
            else => return null,
        }
    }
    fn failure(out: *[mtu]u8, op: u8, handle: u16, code: u8) []const u8 {
        out[0] = 1;
        out[1] = op;
        write16(out[2..4], handle);
        out[4] = code;
        return out[0..5];
    }

    /// Writes and subscription updates occur only after the entire PDU validates.
    /// An ATT command never has a response, including malformed commands.
    pub fn respond(self: *Server, req: []const u8, out: *[mtu]u8) []const u8 {
        if (req.len == 0) return out[0..0];
        const op = req[0];
        const handle: u16 = if (req.len >= 3) read16(req[1..3]) else 0;
        if (req.len > mtu) return if (op & 0x40 != 0) out[0..0] else failure(out, op, handle, 4);
        if (op == 0x52 or op == 0x12) {
            if (req.len < 3) return if (op == 0x52) out[0..0] else failure(out, op, handle, 4);
            var code: u8 = 0;
            if (handle == value_handle) {
                @memcpy(self.value[0 .. req.len - 3], req[3..]);
                self.value_len = @intCast(req.len - 3);
            } else if (handle == cccd_handle) {
                if (req.len != 5) code = 0x0d else if (read16(req[3..5]) > 1) code = 0x13 else {
                    self.subscribed = req[3] == 1;
                }
            } else code = if (handle == 0 or handle > types.len) 1 else 3;
            if (op == 0x52) return out[0..0];
            if (code != 0) return failure(out, op, handle, code);
            out[0] = 0x13;
            return out[0..1];
        }
        // Ignore unsupported commands; responding to a command violates ATT.
        if (op & 0x40 != 0) return out[0..0];
        if (op == 2) {
            if (req.len != 3 or handle < mtu) return failure(out, op, 0, 4);
            out[0..3].* = .{ 3, mtu, 0 };
            return out[0..3];
        }
        if (op == 0x0a or op == 0x0c) {
            if (req.len != (if (op == 0x0a) @as(usize, 3) else 5)) return failure(out, op, handle, 4);
            if (handle == 0 or handle > types.len) return failure(out, op, handle, 1);
            var tmp: [20]u8 = undefined;
            const value = self.value_of(handle, &tmp) orelse return failure(out, op, handle, 2);
            const offset: usize = if (op == 0x0c) read16(req[3..5]) else 0;
            if (offset > value.len) return failure(out, op, handle, 7);
            const len = @min(value.len - offset, mtu - 1);
            out[0] = op + 1;
            @memcpy(out[1..][0..len], value[offset..][0..len]);
            return out[0 .. len + 1];
        }
        if (op != 4 and op != 6 and op != 8 and op != 0x10) return failure(out, op, handle, 6);
        const valid_len = switch (op) {
            4 => req.len == 5,
            6 => req.len >= 7,
            else => req.len == 7 or req.len == 21,
        };
        if (!valid_len) return failure(out, op, handle, 4);
        const end = read16(req[3..5]);
        if (handle == 0 or handle > end) return failure(out, op, handle, 1);
        if (op == 4) {
            out[0..2].* = .{ 5, 1 };
            var len: usize = 2;
            var h = handle;
            while (h <= @min(end, types.len) and len + 4 <= mtu) : (h += 1) {
                write16(out[len..], h);
                write16(out[len + 2 ..], types[h - 1]);
                len += 4;
            }
            return if (len == 2) failure(out, op, handle, 0x0a) else out[0..len];
        }
        const typ = read16(req[5..7]);
        if (op == 0x10 or op == 6) {
            if (typ != 0x2800 and typ != 0x2801) return failure(out, op, handle, if (op == 0x10) 0x10 else 0x0a);
            out[0] = op + 1;
            var len: usize = if (op == 0x10) 2 else 1;
            out[1] = 6;
            if (typ == 0x2800 and ((op == 0x10 and req.len == 7) or (op == 6 and req.len == 9))) {
                for ([_]u16{ 1, 4 }, [_]u16{ 3, 9 }, [_]u16{ 0x1800, 0xfff0 }) |start, last, uuid| {
                    if (start < handle or start > end) continue;
                    if (op == 6 and read16(req[7..9]) != uuid) continue;
                    write16(out[len..], start);
                    write16(out[len + 2 ..], last);
                    if (op == 0x10) write16(out[len + 4 ..], uuid);
                    len += if (op == 0x10) @as(usize, 6) else 4;
                }
            }
            return if (len == (if (op == 0x10) @as(usize, 2) else 1)) failure(out, op, handle, 0x0a) else out[0..len];
        }
        // Read By Type: a response contains only entries of equal value length.
        if (req.len != 7) return failure(out, op, handle, 0x0a);
        out[0] = 9;
        var len: usize = 2;
        var width: usize = 0;
        var h = handle;
        while (h <= @min(end, types.len)) : (h += 1) {
            if (types[h - 1] != typ) continue;
            var tmp: [20]u8 = undefined;
            const value = self.value_of(h, &tmp) orelse {
                if (len == 2) return failure(out, op, h, 2);
                break;
            };
            const count = @min(value.len, mtu - 4);
            if (width != 0 and width != count + 2) break;
            width = count + 2;
            if (len + width > mtu) break;
            write16(out[len..], h);
            @memcpy(out[len + 2 ..][0..count], value[0..count]);
            len += width;
        }
        if (len == 2) return failure(out, op, handle, 0x0a);
        out[1] = @intCast(width);
        return out[0..len];
    }
    pub fn notification(self: *Server) [7]u8 {
        self.counter +%= 1;
        var out: [7]u8 = .{ 0x1b, notify_handle, 0, 0, 0, 0, 0 };
        std.mem.writeInt(u32, out[3..7], self.counter, .little);
        return out;
    }
};

test "ATT discovery follows actual handles and scopes service groups" {
    var server = try Server.init("MZ-C6");
    var out: [mtu]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 6, 1, 0, 3, 0, 0, 0x18, 4, 0, 9, 0, 0xf0, 0xff }, server.respond(&.{ 0x10, 1, 0, 0xff, 0xff, 0, 0x28 }, &out));
    try std.testing.expectEqualSlices(u8, &.{ 9, 7, 5, 0, 0x0e, 6, 0, 0xf1, 0xff, 7, 0, 0x10, 8, 0, 0xf2, 0xff }, server.respond(&.{ 8, 4, 0, 9, 0, 3, 0x28 }, &out));
    try std.testing.expectEqualSlices(u8, &.{ 5, 1, 9, 0, 2, 0x29 }, server.respond(&.{ 4, 9, 0, 9, 0 }, &out));
    try std.testing.expectEqualSlices(u8, &.{ 1, 4, 10, 0, 0x0a }, server.respond(&.{ 4, 10, 0, 0xff, 0xff }, &out));
}
test "ATT invalid requests do not modify values or subscription" {
    var server = try Server.init("MZ-C6");
    var out: [mtu]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{0x13}, server.respond(&.{ 0x12, 6, 0, 1, 2 }, &out));
    try std.testing.expectEqualSlices(u8, &.{ 0x0b, 1, 2 }, server.respond(&.{ 0x0a, 6, 0 }, &out));
    try std.testing.expectEqualSlices(u8, &.{ 1, 0x12, 9, 0, 0x0d }, server.respond(&.{ 0x12, 9, 0, 1 }, &out));
    try std.testing.expect(!server.subscribed);
    try std.testing.expectEqualSlices(u8, &.{0x13}, server.respond(&.{ 0x12, 9, 0, 1, 0 }, &out));
    try std.testing.expect(server.subscribed);
    try std.testing.expectEqual(@as(usize, 0), server.respond(&.{ 0x52, 0xff, 0xff, 9 }, &out).len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0x0a, 0, 0, 1 }, server.respond(&.{ 0x0a, 0, 0 }, &out));
    try std.testing.expectEqualSlices(u8, &.{ 1, 8, 1, 0, 1 }, server.respond(&.{ 8, 1, 0, 0, 0, 3, 0x28 }, &out));
    server.disconnected();
    try std.testing.expect(!server.subscribed);
}
