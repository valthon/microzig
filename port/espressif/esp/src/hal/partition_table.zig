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
        var pos: usize = 0;
        while (pos < table_size) : (pos += 32) {
            const bytes = raw[pos..][0..32];
            switch (std.mem.readInt(u16, bytes[0..2], .little)) {
                0xffff => {
                    if (!std.mem.allEqual(u8, raw[pos..], 0xff)) return error.InvalidTable;
                    return self;
                },
                0xebeb => {
                    if (!std.mem.allEqual(u8, bytes[2..16], 0xff) or
                        !std.mem.allEqual(u8, raw[pos + 32 ..], 0xff)) return error.InvalidTable;
                    var digest: [16]u8 = undefined;
                    std.crypto.hash.Md5.hash(raw[0..pos], &digest, .{});
                    if (!std.mem.eql(u8, &digest, bytes[16..32])) return error.InvalidChecksum;
                    return self;
                },
                0x50aa => {},
                else => return error.InvalidTable,
            }
            if (self.count == max_entries) return error.InvalidTable;
            const p: Partition = .{
                .type = @fromBackingInt(@intCast(bytes[2])),
                .subtype = bytes[3],
                .offset = std.mem.readInt(u32, bytes[4..8], .little),
                .size = std.mem.readInt(u32, bytes[8..12], .little),
                .label_buf = bytes[12..28].*,
                .flags = std.mem.readInt(u32, bytes[28..32], .little),
            };
            if (p.offset < default_offset + 4096 or p.offset % 4096 != 0 or p.size == 0 or
                p.offset > flash_size or p.size > flash_size - p.offset or
                (p.type == .app and p.offset % 65536 != 0)) return error.InvalidPartition;
            for (self.entries[0..self.count]) |previous| {
                if (p.offset < previous.offset + previous.size and previous.offset < p.offset + p.size)
                    return error.Overlap;
                if (std.mem.eql(u8, p.label(), previous.label())) return error.InvalidPartition;
            }
            self.entries[self.count] = p;
            self.count += 1;
        }
        return error.InvalidTable;
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
    var raw: [table_size]u8 = undefined;
    try device.read(default_offset, &raw);
    return Table.decode(&raw, device.size);
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
