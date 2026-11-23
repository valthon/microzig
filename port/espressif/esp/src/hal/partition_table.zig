//! Read-only ESP-IDF partition tables at the default 0x8000 offset.
//! Based on totorototo/microzig@f64390f2 (entry layout and data subtypes).
//! Format reference: ESP-IDF components/partition_table/gen_esp32part.py.
const std = @import("std");
pub const default_offset = 0x8000;
pub const table_size = 0xc00;
pub const max_entries = 95;
pub const Error = error{ InvalidTable, InvalidChecksum, InvalidPartition, Overlap };
pub const Type = enum(u8) { app = 0, data = 1, _ };
pub const DataSubtype = enum(u8) { ota = 0, phy = 1, nvs = 2, coredump = 3, nvs_keys = 4, efuse = 5, undefined = 6, fat = 0x81, spiffs = 0x82, littlefs = 0x83, _ };

pub const Partition = struct {
    type: Type,
    subtype: u8,
    offset: u32,
    size: u32,
    label_buf: [16]u8,
    flags: u32,

    pub fn label(self: *const Partition) []const u8 {
        return std.mem.sliceTo(&self.label_buf, 0);
    }
};

pub const Table = struct {
    entries: [max_entries]Partition = undefined,
    count: usize = 0,

    /// Validate the entire table before returning any partition, including MD5
    /// when present. Legacy tables with an erased terminator are accepted.
    pub fn decode(raw: *const [table_size]u8, flash_size: u32) Error!Table {
        var self: Table = .{};
        _ = try scan(RawTable{ .raw = raw, .size = flash_size }, &self, null);
        return self;
    }

    pub fn find_data(self: *const Table, subtype: DataSubtype, name: []const u8) ?Partition {
        for (self.entries[0..self.count]) |p| {
            if (p.type == .data and p.subtype == @backingInt(subtype) and std.mem.eql(u8, p.label(), name)) return p;
        }
        return null;
    }
};

/// Device must provide read(offset, destination) and size. Performs no writes.
pub fn read(device: anytype) !Table {
    var result: Table = .{};
    _ = try scan(device, &result, null);
    return result;
}

/// Validate the complete table while retaining only the matching partition.
/// Serialize access with table writers for the duration of the scan.
pub fn find_data(device: anytype, subtype: DataSubtype, name: []const u8) !?Partition {
    return scan(device, null, .{ .subtype = subtype, .name = name });
}

const Query = struct { subtype: DataSubtype, name: []const u8 };

const RawTable = struct {
    raw: *const [table_size]u8,
    size: u32,

    fn read(self: RawTable, offset: u32, dest: []u8) Error!void {
        const pos = offset - default_offset;
        @memcpy(dest, self.raw[pos..][0..dest.len]);
    }
};

fn decode_entry(bytes: *const [32]u8) Partition {
    return .{
        .type = @fromBackingInt(@intCast(bytes[2])),
        .subtype = bytes[3],
        .offset = std.mem.readInt(u32, bytes[4..8], .little),
        .size = std.mem.readInt(u32, bytes[8..12], .little),
        .label_buf = bytes[12..28].*,
        .flags = std.mem.readInt(u32, bytes[28..32], .little),
    };
}

// Read one entry at a time. A lookup rereads prior entries for overlap/label
// checks instead of keeping a whole table on the task stack. At most 95 entries
// means at most 4465 prior-entry reads; the common NVS table has three entries.
fn scan(device: anytype, output: ?*Table, query: ?Query) !?Partition {
    var hash = std.crypto.hash.Md5.init(.{});
    var found: ?Partition = null;
    var pos: u32 = 0;
    while (pos < table_size) : (pos += 32) {
        var bytes: [32]u8 = undefined;
        try device.read(default_offset + pos, &bytes);
        const magic = std.mem.readInt(u16, bytes[0..2], .little);
        if (magic == 0xffff or magic == 0xebeb) {
            if (magic == 0xffff) {
                if (!std.mem.allEqual(u8, &bytes, 0xff)) return error.InvalidTable;
            } else {
                if (!std.mem.allEqual(u8, bytes[2..16], 0xff)) return error.InvalidTable;
            }
            // Validate the erased tail before the checksum, matching decode's
            // error precedence even when both the tail and digest are damaged.
            var tail = pos + 32;
            while (tail < table_size) : (tail += 32) {
                var erased: [32]u8 = undefined;
                try device.read(default_offset + tail, &erased);
                if (!std.mem.allEqual(u8, &erased, 0xff)) return error.InvalidTable;
            }
            if (magic == 0xebeb) {
                var digest: [16]u8 = undefined;
                hash.final(&digest);
                if (!std.mem.eql(u8, &digest, bytes[16..32])) return error.InvalidChecksum;
            }
            return found;
        }
        if (magic != 0x50aa or pos / 32 == max_entries) return error.InvalidTable;
        const p = decode_entry(&bytes);
        if (p.offset < default_offset + 4096 or p.offset % 4096 != 0 or p.size == 0 or
            p.offset > device.size or p.size > device.size - p.offset or
            (p.type == .app and p.offset % 65536 != 0)) return error.InvalidPartition;
        var previous_pos: u32 = 0;
        while (previous_pos < pos) : (previous_pos += 32) {
            const previous = if (output) |table| table.entries[previous_pos / 32] else previous: {
                var raw: [32]u8 = undefined;
                try device.read(default_offset + previous_pos, &raw);
                break :previous decode_entry(&raw);
            };
            if (p.offset < previous.offset + previous.size and previous.offset < p.offset + p.size)
                return error.Overlap;
            if (std.mem.eql(u8, p.label(), previous.label())) return error.InvalidPartition;
        }
        if (output) |table| {
            table.entries[table.count] = p;
            table.count += 1;
        }
        if (query) |q| {
            if (p.type == .data and p.subtype == @backingInt(q.subtype) and std.mem.eql(u8, p.label(), q.name)) found = p;
        }
        hash.update(&bytes);
    }
    return error.InvalidTable;
}

fn test_entry(raw: []u8, kind: u8, offset: u32, size: u32, name: []const u8) void {
    @memset(raw[0..32], 0);
    std.mem.writeInt(u16, raw[0..2], 0x50aa, .little);
    raw[2] = kind;
    raw[3] = 2;
    std.mem.writeInt(u32, raw[4..8], offset, .little);
    std.mem.writeInt(u32, raw[8..12], size, .little);
    @memcpy(raw[12..][0..name.len], name);
}

test "partition table bounds, overlaps, flags and MD5" {
    const t = std.testing;
    var raw: [table_size]u8 = @splat(0xff);
    test_entry(&raw, 1, 0x9000, 0x6000, "nvs");
    test_entry(raw[32..], 0, 0x10000, 0x100000, "factory");
    raw[28] = 1;
    raw[64] = 0xeb;
    raw[65] = 0xeb;
    std.crypto.hash.Md5.hash(raw[0..64], raw[80..96], .{});
    var table = try Table.decode(&raw, 0x400000);
    const p = table.find_data(.nvs, "nvs").?;
    try t.expectEqual(@as(u32, 0x9000), p.offset);
    try t.expectEqual(@as(u32, 1), p.flags);
    try t.expect(table.find_data(.nvs, "absent") == null);
    raw[80] ^= 1;
    try t.expectError(error.InvalidChecksum, Table.decode(&raw, 0x400000));
    @memset(raw[64..], 0xff);
    _ = try Table.decode(&raw, 0x400000);
    test_entry(raw[32..], 1, 0xa000, 0x1000, "overlap");
    try t.expectError(error.Overlap, Table.decode(&raw, 0x400000));
    test_entry(raw[32..], 1, 0xfffff000, 0x2000, "overflow");
    try t.expectError(error.InvalidPartition, Table.decode(&raw, 0xffffffff));
    test_entry(raw[32..], 1, 0x8000, 0x1000, "boot");
    try t.expectError(error.InvalidPartition, Table.decode(&raw, 0x400000));
    raw[32] = 0x55;
    try t.expectError(error.InvalidTable, Table.decode(&raw, 0x400000));
}

test "streamed lookup validates entries and checksum after the match" {
    const t = std.testing;
    var raw: [table_size]u8 = @splat(0xff);
    const device: RawTable = .{ .raw = &raw, .size = 0x400000 };
    try t.expectEqual(null, try find_data(device, .nvs, "nvs"));
    for (0..max_entries) |i| {
        var name: [16]u8 = undefined;
        const label = try std.mem.print(&name, "part{d}", .{i});
        test_entry(raw[i * 32 ..], 1, @intCast(0x9000 + i * 4096), 4096, label);
    }
    var table = try read(device);
    try t.expectEqual(max_entries, table.count);
    const first = (try find_data(device, .nvs, "part0")).?;
    try t.expectEqualDeep(table.find_data(.nvs, "part0").?, first);
    try t.expectEqualDeep(table.find_data(.nvs, "part94"), try find_data(device, .nvs, "part94"));
    try t.expectEqual(null, try find_data(device, .phy, "part0"));
    try t.expectEqual(null, try find_data(device, .nvs, "missing"));

    const end = max_entries * 32;
    raw[end] = 0xeb;
    raw[end + 1] = 0xeb;
    std.crypto.hash.Md5.hash(raw[0..end], raw[end + 16 ..][0..16], .{});
    try t.expectEqualDeep(first, (try find_data(device, .nvs, "part0")).?);
    raw[end + 16] ^= 1;
    try t.expectError(error.InvalidChecksum, find_data(device, .nvs, "part0"));
    @memset(raw[end..], 0xff);
    test_entry(raw[end..], 1, 0x100000, 4096, "extra");
    try t.expectError(error.InvalidTable, find_data(device, .nvs, "part0"));
    @memset(raw[end..], 0xff);
    test_entry(raw[32..], 1, first.offset, 4096, "overlap");
    try t.expectError(error.Overlap, find_data(device, .nvs, "part0"));
    test_entry(raw[32..], 1, first.offset + 4096, 4096, "part0");
    try t.expectError(error.InvalidPartition, find_data(device, .nvs, "part0"));

    @memset(raw[32..], 0xff);
    raw[64] = 0;
    try t.expectError(error.InvalidTable, find_data(device, .nvs, "part0"));
    raw[32] = 0xeb;
    raw[33] = 0xeb;
    // Both the tail and digest are corrupt: reject the tail first.
    try t.expectError(error.InvalidTable, find_data(device, .nvs, "part0"));
}

test "streamed lookup propagates flash read failures after the match" {
    const FailingFlash = struct {
        raw: *const [table_size]u8,
        size: u32 = 0x400000,
        fail_offset: u32,

        pub fn read(self: @This(), offset: u32, dest: []u8) error{ReadFailed}!void {
            if (offset == self.fail_offset) return error.ReadFailed;
            @memcpy(dest, self.raw[offset - default_offset ..][0..dest.len]);
        }
    };
    var raw: [table_size]u8 = @splat(0xff);
    test_entry(&raw, 1, 0x9000, 4096, "nvs");
    test_entry(raw[32..], 1, 0xa000, 4096, "other");
    for (0..table_size / 32) |i| {
        try std.testing.expectError(error.ReadFailed, find_data(FailingFlash{
            .raw = &raw,
            .fail_offset = @intCast(default_offset + i * 32),
        }, .nvs, "nvs"));
    }
}
