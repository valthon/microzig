//! This store's half of `nvs_testdata/init_diff_idf.py`, which runs it with
//! `zig build nvs-init-diff -Dnvs-init-diff=<dir>`: for each four-page
//! partition in `<dir>/partitions.bin`, two boots, the second on what the
//! first left, each an init and then the blobs of three keys read four
//! times, written to `<dir>/store.bin` in the format `init_diff_idf.cpp`
//! writes ESP-IDF's boots in. Not part of `zig build test`; without the
//! option it does nothing.
const std = @import("std");
const nvs = @import("nvs.zig");
const options = @import("nvs_init_diff_options");
const testing = std.testing;
const partition_size = 4 * nvs.page_size;

const Flash = struct {
    pub const Error = error{};
    mem: *[partition_size]u8,

    pub fn read(self: *Flash, offset: u32, dest: []u8) Error!void {
        @memcpy(dest, self.mem[offset..][0..dest.len]);
    }

    pub fn write(self: *Flash, offset: u32, bytes: []const u8) Error!void {
        for (self.mem[offset..][0..bytes.len], bytes) |*dest, byte| dest.* &= byte;
    }

    pub fn erase(self: *Flash, offset: u32) Error!void {
        @memset(self.mem[offset..][0..nvs.page_size], 0xff);
    }
};
const Store = nvs.Storage(*Flash);

/// As `init_diff_idf.cpp`'s `Read`: u8 status (0 read, 1 not found, 2
/// failed, 3 type mismatch, 4 longer than the buffer), u32 length, the
/// buffer.
const Read = struct {
    status: u8 = 0,
    len: u32 = 0,
    data: [256]u8 = @splat(0),

    fn append(read: Read, out: *std.ArrayList(u8)) !void {
        try out.append(testing.allocator, read.status);
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, read.len, .little);
        try out.appendSlice(testing.allocator, &word);
        try out.appendSlice(testing.allocator, &read.data);
    }
};

fn read_blob(store: *Store, namespace: []const u8, key: []const u8) !Read {
    var read: Read = .{};
    const h = try store.open(namespace, .read_only);
    const len = h.blob_len(key) catch |err| return status(err);
    if (len > read.data.len) return .{ .status = 4 };
    read.len = @intCast((h.get_blob(key, &read.data) catch |err| return status(err)).len);
    return read;
}

fn status(err: Store.Err) !Read {
    return .{ .status = switch (err) {
        error.NotFound => 1,
        error.Corrupt => 2,
        error.TypeMismatch => 3,
        else => return err,
    } };
}

const boot_size = 1 + 2 * partition_size + 4 * 3 * (5 + 256);

/// As `init_diff_idf.cpp`'s `boot`.
fn boot(flash: *Flash, out: *std.ArrayList(u8)) !void {
    var store: Store = undefined;
    // A failed init is status 9, compared with ESP-IDF's.
    const initialized = if (store.init(flash, partition_size)) |_| true else |_| false;
    try out.append(testing.allocator, if (initialized) 0 else 9);
    try out.appendSlice(testing.allocator, flash.mem);
    for (0..4) |_| {
        inline for (.{ .{ "fixture", "legacy" }, .{ "fixture", "other" }, .{ "second", "legacy" } }) |name| {
            const read: Read = if (initialized) try read_blob(&store, name[0], name[1]) else .{};
            try read.append(out);
        }
    }
    try out.appendSlice(testing.allocator, flash.mem);
}

test "init and read each partition" {
    if (options.dir.len == 0) return;
    const io = testing.io;
    const gpa = testing.allocator;
    var dir = try std.Io.Dir.openDirAbsolute(io, options.dir, .{});
    defer dir.close(io);
    const input = try dir.readFileAlloc(io, "partitions.bin", gpa, .unlimited);
    defer gpa.free(input);
    try testing.expect(input.len % partition_size == 0);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, input.len / partition_size * 2 * boot_size);
    var at: usize = 0;
    while (at < input.len) : (at += partition_size) {
        var mem: [partition_size]u8 = input[at..][0..partition_size].*;
        var flash: Flash = .{ .mem = &mem };
        try boot(&flash, &out);
        try boot(&flash, &out);
    }
    try dir.writeFile(io, .{ .sub_path = "store.bin", .data = out.items });
}
