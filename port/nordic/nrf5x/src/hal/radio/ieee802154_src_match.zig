//! Fixed-size source matching for legacy MAC Data Request commands.
const std = @import("std");
const header = @import("ieee802154_header.zig");

pub const capacity = 16;

pub const Table = struct {
    enabled: bool = false,
    short: [capacity]?u16 = @splat(null),
    extended: [capacity]?[8]u8 = @splat(null),

    pub fn add(entries: anytype, address: anytype) error{NoSpace}!void {
        if (find(entries, address) != null) return;
        for (entries) |*entry| {
            if (entry.* == null) {
                entry.* = address;
                return;
            }
        }
        return error.NoSpace;
    }

    pub fn remove(entries: anytype, address: anytype) error{NotFound}!void {
        const index = find(entries, address) orelse return error.NotFound;
        entries[index] = null;
    }

    fn find(entries: anytype, address: anytype) ?usize {
        const wanted = word(@as(@TypeOf(entries[0].?), address));
        for (entries, 0..) |entry, index| {
            if (entry) |value| {
                if (word(value) == wanted) return index;
            }
        }
        return null;
    }

    /// Compare an address as one integer. A Data Request is matched before
    /// its ACK is armed, and ReleaseSmall compares arrays byte by byte.
    fn word(address: anytype) u64 {
        return switch (@TypeOf(address)) {
            u16 => address,
            [8]u8 => @as(*align(1) const u64, @ptrCast(&address)).*,
            else => @compileError("unsupported source address type"),
        };
    }

    pub fn frame_pending(self: *const Table, h: header.Header, bytes: []const u8) bool {
        if (!h.possible_data_request(bytes)) return false;
        if (!self.enabled) return true;
        return switch (h.source.len) {
            2 => find(&self.short, std.mem.readInt(u16, h.source[0..2], .little)) != null,
            8 => find(&self.extended, h.source[0..8].*) != null,
            else => false,
        };
    }
};

test "only data requests get pending, using source match when enabled" {
    var bytes = [_]u8{ 0x63, 0x88, 9, 0x34, 0x12, 3, 0, 1, 0, 0x04 };
    var table: Table = .{ .enabled = true };
    const request = try header.parse(&bytes);
    try std.testing.expect(!table.frame_pending(request, &bytes));

    try Table.add(&table.short, 1);
    try std.testing.expect(table.frame_pending(request, &bytes));
    bytes[0] = 0x61; // A data frame whose payload starts with the same octet.
    try std.testing.expect(!table.frame_pending(try header.parse(&bytes), &bytes));
    try Table.remove(&table.short, 1);
    try std.testing.expectError(error.NotFound, Table.remove(&table.short, 1));

    table.enabled = false;
    try std.testing.expect(!table.frame_pending(try header.parse(&bytes), &bytes));
    bytes[0] = 0x63;
    try std.testing.expect(table.frame_pending(try header.parse(&bytes), &bytes));
    try std.testing.expect(!table.frame_pending(request, bytes[0 .. bytes.len - 1]));
}

test "extended sources match in wire order and each table has fixed capacity" {
    const bytes = [_]u8{ 0x63, 0xc8, 9, 0x34, 0x12, 3, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0x04 };
    var table: Table = .{ .enabled = true };
    try Table.add(&table.extended, [8]u8{ 0, 2, 3, 4, 5, 6, 7, 8 });
    try Table.add(&table.extended, [8]u8{ 1, 2, 3, 4, 5, 6, 7, 9 });
    try std.testing.expect(!table.frame_pending(try header.parse(&bytes), &bytes));
    try Table.add(&table.extended, [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try std.testing.expect(table.frame_pending(try header.parse(&bytes), &bytes));
    for (0..capacity) |address| try Table.add(&table.short, @as(u16, @intCast(address)));
    try Table.add(&table.short, 0);
    try std.testing.expectError(error.NoSpace, Table.add(&table.short, capacity));
}

test "secured command uses source match without inspecting its protected body" {
    var bytes = [_]u8{ 0x6b, 0x98, 9, 0x34, 0x12, 3, 0, 1, 0, 0x0d, 0, 0, 0, 0, 1, 0x84, 0, 0, 0, 0 };
    var table: Table = .{ .enabled = true };
    const command = try header.parse(&bytes);
    try std.testing.expect(!table.frame_pending(command, &bytes));
    try Table.add(&table.short, 1);
    try std.testing.expect(table.frame_pending(command, &bytes));
    table.enabled = false;
    try std.testing.expect(table.frame_pending(command, &bytes));

    bytes[0] = 0x69;
    try std.testing.expect(!table.frame_pending(try header.parse(&bytes), &bytes));
}
