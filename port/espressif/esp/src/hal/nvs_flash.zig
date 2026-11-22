//! Cache-safe flash adapter for a validated, named ESP-IDF NVS partition.
const flash = @import("flash.zig");
const table = @import("partition_table.zig");
const nvs = @import("nvs.zig");

pub const Error = flash.Error || table.Error || error{ NotFound, UnsupportedPartition };
pub const Store = nvs.Storage(PartitionFlash);

pub const PartitionFlash = struct {
    pub const Error = flash.Error;
    region: flash.DataRegion,

    pub fn read(self: PartitionFlash, offset: u32, dest: []u8) flash.Error!void {
        try self.region.read(offset, dest);
    }
    pub fn write(self: PartitionFlash, offset: u32, bytes: []const u8) flash.Error!void {
        try self.region.write(offset, bytes);
    }
    pub fn erase(self: PartitionFlash, offset: u32) flash.Error!void {
        try self.region.erase_sector(offset);
    }
};

/// Read and validate the complete table on every open. Reject encrypted,
/// read-only or unknown flags, and geometries the store cannot represent.
/// Never formats a partition or writes outside the named partition range.
pub fn open(device: flash.Flash, name: []const u8) Error!PartitionFlash {
    const p = try table.find_data(device, .nvs, name) orelse return error.NotFound;
    if (p.flags != 0 or p.size % nvs.page_size != 0 or
        p.size < 3 * nvs.page_size or p.size > nvs.max_pages * nvs.page_size) return error.UnsupportedPartition;
    return .{ .region = try device.data_region(p.offset, p.size) };
}
