//! Bluetooth Core HCI / L2CAP / ATT byte encoding. No allocation or hardware.
const std = @import("std");
pub const Error = error{
    Timeout,
    TransportFailed,
    ReceiveOverflow,
    InvalidPacket,
    CommandFailed,
    HardwareError,
    NoConnection,
    ConnectionFailed,
    Disconnected,
    AttError,
    Unsupported,
    NotFound,
    InvalidName,
    Busy,
    NoBuffer,
};
pub const PacketKind = enum { event, acl };
pub const Packet = struct {
    kind: PacketKind,
    len: u16,
    bytes: [260]u8,
    pub fn data(self: *const Packet) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Transport = struct {
    context: *anyopaque,
    send_command_fn: *const fn (*anyopaque, []const u8) Error!void,
    send_acl_fn: *const fn (*anyopaque, []const u8) Error!void,
    receive_fn: *const fn (*anyopaque, u32) Error!Packet,
    now_ms_fn: *const fn (*anyopaque) u64,
};
pub fn read16(data: []const u8) u16 {
    return std.mem.readInt(u16, data[0..2], .little);
}
pub fn write16(data: []u8, value: u16) void {
    std.mem.writeInt(u16, data[0..2], value, .little);
}

pub const Advertisement = struct {
    event_type: u8,
    address_type: u8,
    address: [6]u8,
    rssi: i8,
    len: u8,
    bytes: [31]u8,
    pub fn name(self: *const Advertisement) ?[]const u8 {
        return local_name(self.bytes[0..self.len]);
    }
};
/// AD length includes the AD type. Complete name takes precedence over short name.
pub fn local_name(data: []const u8) ?[]const u8 {
    var short: ?[]const u8 = null;
    var offset: usize = 0;
    while (offset < data.len) {
        const len = data[offset];
        if (len == 0) break;
        if (len > data.len - offset - 1) return null;
        const typ = data[offset + 1];
        const value = data[offset + 2 .. offset + 1 + len];
        if (typ == 9) return value;
        if (typ == 8) short = value;
        offset += @as(usize, len) + 1;
    }
    return short;
}

/// Iterate all legacy advertising reports in one LE Meta event.
pub const Reports = struct {
    remaining: u8,
    data: []const u8,
    pub fn init(data: []const u8) Error!Reports {
        if (data.len < 2 or data[0] != 2) return error.InvalidPacket;
        return .{ .remaining = data[1], .data = data[2..] };
    }
    pub fn next(self: *Reports) Error!?Advertisement {
        if (self.remaining == 0) {
            if (self.data.len != 0) return error.InvalidPacket;
            return null;
        }
        if (self.data.len < 10) return error.InvalidPacket;
        const len = self.data[8];
        if (len > 31 or self.data.len < @as(usize, len) + 10) return error.InvalidPacket;
        var ad: Advertisement = .{
            .event_type = self.data[0],
            .address_type = self.data[1],
            .address = self.data[2..8].*,
            .rssi = @bitCast(self.data[9 + @as(usize, len)]),
            .len = len,
            .bytes = @splat(0),
        };
        @memcpy(ad.bytes[0..len], self.data[9..][0..len]);
        self.data = self.data[10 + @as(usize, len) ..];
        self.remaining -= 1;
        return ad;
    }
};

test "AD names and malformed length fields" {
    try std.testing.expectEqualStrings("MZ", local_name(&.{ 3, 8, 'm', 'z', 3, 9, 'M', 'Z' }).?);
    try std.testing.expectEqualStrings("mz", local_name(&.{ 3, 8, 'm', 'z', 0 }).?);
    try std.testing.expect(local_name(&.{ 5, 9, 'M' }) == null);
    try std.testing.expect(local_name(&.{1}) == null);
    var reports = try Reports.init(&.{ 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 3, 2, 9, 'X', 0xc0 });
    const ad = (try reports.next()).?;
    try std.testing.expectEqual(@as(i8, -64), ad.rssi);
    try std.testing.expectEqualStrings("X", ad.name().?);
    try std.testing.expectEqual(@as(?Advertisement, null), try reports.next());
    var truncated = try Reports.init(&.{ 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 31, 0 });
    try std.testing.expectError(error.InvalidPacket, truncated.next());
}

test "all advertising reports are parsed, with exact packet consumption" {
    var reports = try Reports.init(&.{ 2, 2, 0, 0, 1, 2, 3, 4, 5, 6, 0, 0xd0, 4, 1, 6, 5, 4, 3, 2, 1, 3, 2, 9, 'Y', 0xb0 });
    const first = (try reports.next()).?;
    const second = (try reports.next()).?;
    try std.testing.expectEqual(@as(i8, -48), first.rssi);
    try std.testing.expect(first.name() == null);
    try std.testing.expectEqual(@as(u8, 1), second.address_type);
    try std.testing.expectEqualStrings("Y", second.name().?);
    try std.testing.expect((try reports.next()) == null);
    var extra = try Reports.init(&.{ 2, 0, 0 });
    try std.testing.expectError(error.InvalidPacket, extra.next());
}
