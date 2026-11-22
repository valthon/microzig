//! Image-boot C3/C6 self-test; no external wiring.
//! Uses only partition "nvs"; reserves namespaces "mz_selftest" and "mz_purge".
//! Expected: SELFTEST nvs DONE pass=12 fail=0 (see the README).
//! Expects ESP-IDF's default single-app table (partitions_singleapp.csv) at 0x8000:
//! nvs, phy_init and factory at the offsets in `default_table`; `partition_list`
//! fails on any other layout; store cases still run against the named NVS partition.
//! Key "boots" survives the run: each boot logs boots=N, so a reboot without
//! reflashing must report N+1 (checked by the host, not by the test).
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const Store = hal.nvs_flash.Store;
const Error = Store.Err || hal.nvs_flash.Error || error{Mismatch};

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_level = .info,
});
comptime {
    _ = microzig.export_startup();
}

const names = [_][]const u8{ "partition", "integers", "string", "blob", "rollover", "commit_reopen", "erase", "boots_increment", "read_only", "purge", "partition_list", "partition_md5" };
var store: Store = undefined;
var expected: [6000]u8 = undefined;
var actual: [6000]u8 = undefined;
var partition_offset: u32 = 0;
var partition_size: u32 = 0;
var stage: []const u8 = "partition";
var boots: u32 = 0;
var partitions: hal.partition_table.Table = .{};
var partition_list_error: ?Error = null;
var partition_md5_error: ?Error = null;

const Expected = struct {
    label: []const u8,
    type: hal.partition_table.Type,
    subtype: u8,
    offset: u32,
    size: u32,
};
// ESP-IDF v6.0.2 components/partition_table/partitions_singleapp.csv, as
// placed by gen_esp32part.py: the table the bench flashes before the app.
const default_table = [_]Expected{
    .{ .label = "nvs", .type = .data, .subtype = @backingInt(hal.partition_table.DataSubtype.nvs), .offset = 0x9000, .size = 0x6000 },
    .{ .label = "phy_init", .type = .data, .subtype = @backingInt(hal.partition_table.DataSubtype.phy), .offset = 0xf000, .size = 0x1000 },
    .{ .label = "factory", .type = .app, .subtype = 0x00, .offset = 0x10000, .size = 0x100000 },
};

pub fn main() void {
    var passed: [names.len]bool = @splat(false);
    var failure: ?Error = null;
    run(&passed) catch |err| {
        failure = err;
    };
    // Repeat results for monitors attached after boot. The writes run once.
    hal.time.sleep_ms(1500);
    while (true) {
        var count: usize = 0;
        for (names, passed) |name, ok| {
            if (ok) count += 1;
            std.log.info("SELFTEST nvs {s}: {s} offset=0x{X} size=0x{X}", .{
                name, if (ok) "PASS" else "FAIL", partition_offset, partition_size,
            });
        }
        for (partitions.entries[0..partitions.count]) |p| {
            std.log.info("SELFTEST nvs table label={s} type=0x{X} subtype=0x{X} offset=0x{X} size=0x{X} flags=0x{X}", .{
                p.label(), @backingInt(p.type), p.subtype, p.offset, p.size, p.flags,
            });
        }
        if (partition_list_error) |err| std.log.info("SELFTEST nvs info partition_list error={s}", .{@errorName(err)});
        if (partition_md5_error) |err| std.log.info("SELFTEST nvs info partition_md5 error={s}", .{@errorName(err)});
        std.log.info("SELFTEST nvs boots={d}", .{boots});
        if (failure) |err| std.log.info("SELFTEST nvs error: stage={s} error={s}", .{ stage, @errorName(err) });
        std.log.info("SELFTEST nvs DONE pass={d} fail={d}", .{ count, passed.len - count });
        hal.time.sleep_ms(1000);
    }
}

fn run(passed: *[names.len]bool) Error!void {
    const device = try hal.flash.Flash.init(.{});
    stage = "partition_list";
    partitions = try hal.partition_table.read(device);
    // Table diagnostics are independent of the store cases. A valid custom
    // table can fail the default-layout check and still contain a usable NVS.
    if (check_partition_list()) |_| {
        passed[10] = true;
    } else |err| {
        partition_list_error = err;
    }
    stage = "partition_md5";
    if (check_partition_md5(device)) |_| {
        passed[11] = true;
    } else |err| {
        partition_md5_error = err;
    }

    stage = "partition";
    // No hard-coded scratch offset, default partition, or format-on-error.
    // open checks the whole table, NVS flags, image overlap and flash bounds.
    const backend = try hal.nvs_flash.open(device, "nvs");
    partition_offset = backend.region.offset;
    partition_size = backend.region.size;
    const nvs_partition = partitions.find_data(.nvs, "nvs") orelse return error.NotFound;
    try require(partition_offset == nvs_partition.offset and partition_size == nvs_partition.size);
    try store.init(backend, partition_size);
    const h = try store.open("mz_selftest", .read_write);
    passed[0] = true;

    stage = "integers";
    inline for (.{ u8, u16, u32, u64, i8, i16, i32, i64 }) |T| {
        // Type names are distinct keys. Exercise both limits of every type.
        try h.set(T, @typeName(T), std.math.minInt(T));
        try require(try h.get(T, @typeName(T)) == std.math.minInt(T));
        try h.set(T, @typeName(T), std.math.maxInt(T));
        try require(try h.get(T, @typeName(T)) == std.math.maxInt(T));
    }
    passed[1] = true;

    stage = "string";
    try h.set_str("text", "MicroZig NVS");
    try require(std.mem.eql(u8, "MicroZig NVS", try h.get_str("text", &actual)));
    passed[2] = true;

    stage = "blob";
    for (&expected, 0..) |*byte, i| byte.* = @truncate((i *% 37) ^ (i >> 4) ^ 0xa5);
    try h.set_blob("blob", &expected);
    try require(try h.blob_len("blob") == expected.len);
    try require(std.mem.eql(u8, &expected, try h.get_blob("blob", &actual)));
    passed[3] = true;

    stage = "rollover";
    // Cross multiple 126-entry pages and exercise reclaim in a small partition.
    for (0..300) |i| try h.set(u32, "counter", @intCast(i));
    try require(try h.get(u32, "counter") == 299);
    passed[4] = true;

    stage = "commit_reopen";
    try h.commit();
    try store.init(backend, partition_size);
    const reopened = try store.open("mz_selftest", .read_only);
    inline for (.{ u8, u16, u32, u64, i8, i16, i32, i64 }) |T| {
        try require(try reopened.get(T, @typeName(T)) == std.math.maxInt(T));
    }
    try require(std.mem.eql(u8, "MicroZig NVS", try reopened.get_str("text", &actual)));
    try require(std.mem.eql(u8, &expected, try reopened.get_blob("blob", &actual)));
    try require(try reopened.get(u32, "counter") == 299);
    passed[5] = true;

    stage = "read_only";
    try expect_read_only(reopened.set(u32, "counter", 123));
    try expect_read_only(reopened.set_str("text", "refused"));
    try expect_read_only(reopened.set_blob("blob", "refused"));
    try expect_read_only(reopened.erase_key("counter"));
    try expect_read_only(reopened.commit());
    try store.init(backend, partition_size);
    const unchanged = try store.open("mz_selftest", .read_only);
    try require(try unchanged.get(u32, "counter") == 299);
    try require(std.mem.eql(u8, "MicroZig NVS", try unchanged.get_str("text", &actual)));
    try require(std.mem.eql(u8, &expected, try unchanged.get_blob("blob", &actual)));
    passed[8] = true;

    stage = "erase";
    const cleanup = try store.open("mz_selftest", .read_write);
    inline for (.{ u8, u16, u32, u64, i8, i16, i32, i64 }) |T| try cleanup.erase_key(@typeName(T));
    try cleanup.erase_key("text");
    try cleanup.erase_key("blob");
    try cleanup.erase_key("counter");
    try cleanup.commit();
    try store.init(backend, partition_size);
    const after = try store.open("mz_selftest", .read_only);
    inline for (.{ u8, u16, u32, u64, i8, i16, i32, i64 }) |T| {
        if (after.get(T, @typeName(T))) |_| return error.Mismatch else |err| {
            if (err != error.NotFound) return err;
        }
    }
    if (after.get_str("text", &actual)) |_| return error.Mismatch else |err| {
        if (err != error.NotFound) return err;
    }
    if (after.get_blob("blob", &actual)) |_| return error.Mismatch else |err| {
        if (err != error.NotFound) return err;
    }
    if (after.get(u32, "counter")) |_| return error.Mismatch else |err| {
        if (err != error.NotFound) return err;
    }
    passed[6] = true;

    stage = "purge";
    // Erase every key in this separate test namespace, never the boot counter
    // or another application's data. No whole-partition format is needed.
    const purge = try store.open("mz_purge", .read_write_purge);
    try purge.set(u32, "number", 0x12345678);
    const text = "purge-text-0123456789abcdefghijk";
    const blob = "purge-blob-0123456789abcdefghijk";
    try purge.set_str("text", text);
    try purge.set_blob("blob", blob);
    try purge.commit();
    const text_offset = try find_payload(backend, text);
    const blob_offset = try find_payload(backend, blob);
    try purge.erase_key("number");
    try purge.erase_key("text");
    try purge.erase_key("blob");
    try purge.commit();
    // Logical absence alone would also pass with ordinary read_write erasure.
    try backend.read(text_offset, actual[0..text.len]);
    try require(std.mem.allEqual(u8, actual[0..text.len], 0));
    try backend.read(blob_offset, actual[0..blob.len]);
    try require(std.mem.allEqual(u8, actual[0..blob.len], 0));
    try store.init(backend, partition_size);
    const empty = try store.open("mz_purge", .read_only);
    if (empty.get(u32, "number")) |_| return error.Mismatch else |err| {
        if (err != error.NotFound) return err;
    }
    if (empty.get_str("text", &actual)) |_| return error.Mismatch else |err| {
        if (err != error.NotFound) return err;
    }
    if (empty.get_blob("blob", &actual)) |_| return error.Mismatch else |err| {
        if (err != error.NotFound) return err;
    }
    const reuse = try store.open("mz_purge", .read_write_purge);
    try reuse.set(u32, "number", 42);
    try reuse.commit();
    try store.init(backend, partition_size);
    const reused = try store.open("mz_purge", .read_write_purge);
    try require(try reused.get(u32, "number") == 42);
    try reused.erase_key("number");
    try reused.commit();
    passed[9] = true;

    stage = "boots_increment";
    const counter = try store.open("mz_selftest", .read_write);
    const previous = counter.get(u32, "boots") catch |err| switch (err) {
        error.NotFound => 0,
        else => return err,
    };
    try counter.set(u32, "boots", previous +% 1);
    try counter.commit();
    try store.init(backend, partition_size);
    boots = try (try store.open("mz_selftest", .read_only)).get(u32, "boots");
    try require(boots == previous +% 1);
    passed[7] = true;
}

fn check_partition_list() Error!void {
    // Every decoded field of every entry must match the flashed table.
    try require(partitions.count == default_table.len);
    for (default_table, partitions.entries[0..partitions.count]) |want, got| {
        try require(std.mem.eql(u8, got.label(), want.label));
        try require(got.type == want.type and got.subtype == want.subtype);
        try require(got.offset == want.offset and got.size == want.size);
    }
}

fn check_partition_md5(device: hal.flash.Flash) Error!void {
    // decode permits legacy tables without MD5; this case requires an MD5 entry.
    var raw: [hal.partition_table.table_size]u8 = undefined;
    try device.read(hal.partition_table.default_offset, &raw);
    const md5_offset = partitions.count * 32;
    try require(md5_offset + 32 <= raw.len);
    const md5_entry = raw[md5_offset..][0..32];
    try require(std.mem.readInt(u16, md5_entry[0..2], .little) == 0xebeb);
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(raw[0..md5_offset], &digest, .{});
    try require(std.mem.eql(u8, &digest, md5_entry[16..32]));
    // Also prove that the reader rejects a bad digest, changing only RAM.
    md5_entry[16] ^= 1;
    if (hal.partition_table.Table.decode(&raw, device.size)) |_| return error.Mismatch else |err| {
        if (err != error.InvalidChecksum) return err;
    }
}

fn require(condition: bool) Error!void {
    if (!condition) return error.Mismatch;
}

fn expect_read_only(result: Store.Err!void) Error!void {
    if (result) |_| return error.Mismatch else |err| {
        if (err != error.ReadOnly) return err;
    }
}

fn find_payload(backend: hal.nvs_flash.PartitionFlash, payload: []const u8) Error!u32 {
    var offset: u32 = 0;
    while (offset < partition_size) : (offset += hal.nvs.page_size) {
        const page = actual[0..hal.nvs.page_size];
        try backend.read(offset, page);
        if (std.mem.indexOf(u8, page, payload)) |pos| {
            return offset + @as(u32, @intCast(pos));
        }
    }
    return error.Mismatch;
}
