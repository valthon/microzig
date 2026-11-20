//! Image-boot C3/C6 self-test; no external wiring.
//! Uses only the partition named "nvs" and reserves namespace "mz_selftest".
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

const names = [_][]const u8{ "partition", "integers", "string", "blob", "rollover", "commit_reopen", "erase", "boots_increment" };
var store: Store = undefined;
var expected: [6000]u8 = undefined;
var actual: [6000]u8 = undefined;
var partition_offset: u32 = 0;
var partition_size: u32 = 0;
var stage: []const u8 = "partition";
var boots: u32 = 0;

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
        std.log.info("SELFTEST nvs boots={d}", .{boots});
        if (failure) |err| std.log.info("SELFTEST nvs error: stage={s} error={s}", .{ stage, @errorName(err) });
        std.log.info("SELFTEST nvs DONE pass={d} fail={d}", .{ count, passed.len - count });
        hal.time.sleep_ms(1000);
    }
}

fn run(passed: *[names.len]bool) Error!void {
    const device = try hal.flash.Flash.init(.{});
    // No hard-coded scratch offset, default partition, or format-on-error.
    // open checks the whole table, NVS flags, image overlap and flash bounds.
    const backend = try hal.nvs_flash.open(device, "nvs");
    partition_offset = backend.region.offset;
    partition_size = backend.region.size;
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

fn require(condition: bool) Error!void {
    if (!condition) return error.Mismatch;
}
