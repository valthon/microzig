//! Replay every recorded mutation prefix, independent of the store's error paths:
//! a workload over every key type, and writes over and erases of a format
//! version 1 blob ESP-IDF wrote, each with handles that purge and that do not.
//! With `zig build test -Dnvs-crash-dump=<file>`, every replayed image is also
//! written to that file for ESP-IDF's own code to read
//! (`nvs_testdata/crosscheck_idf.py`).
const std = @import("std");
const nvs = @import("nvs.zig");
const format = @import("nvs_format.zig");
const options = @import("nvs_crash_options");
const testing = std.testing;
const partition_size = 3 * nvs.page_size;

const Operation = struct {
    kind: enum { program, erase },
    offset: u32,
    bytes: []const u8,
    step: usize,
};

const Flash = struct {
    pub const Error = std.mem.Allocator.Error;
    mem: []u8,
    recording: bool = false,
    step: usize = 0,
    operations: std.ArrayList(Operation) = .empty,

    fn deinit(self: *Flash) void {
        for (self.operations.items) |op| testing.allocator.free(op.bytes);
        self.operations.deinit(testing.allocator);
    }

    pub fn read(self: *Flash, offset: u32, dest: []u8) Error!void {
        @memcpy(dest, self.mem[offset..][0..dest.len]);
    }

    pub fn write(self: *Flash, offset: u32, bytes: []const u8) Error!void {
        std.debug.assert(offset % 4 == 0 and bytes.len % 4 == 0);
        if (self.recording) {
            const owned = try testing.allocator.dupe(u8, bytes);
            errdefer testing.allocator.free(owned);
            try self.operations.append(testing.allocator, .{ .kind = .program, .offset = offset, .bytes = owned, .step = self.step });
        }
        for (self.mem[offset..][0..bytes.len], bytes) |*dest, byte| dest.* &= byte;
    }

    pub fn erase(self: *Flash, offset: u32) Error!void {
        std.debug.assert(offset % nvs.page_size == 0);
        if (self.recording) try self.operations.append(testing.allocator, .{ .kind = .erase, .offset = offset, .bytes = &.{}, .step = self.step });
        @memset(self.mem[offset..][0..nvs.page_size], 0xff);
    }
};
const Store = nvs.Storage(*Flash);
const Key = enum { keep, other_keep, byte, half, word, wide, signed_byte, signed_half, signed_word, signed_wide, text, blob, counter };
const key_count = std.enums.values(Key).len;
const Value = union(enum) { absent, integer: u64, string: u8, blob: u8 };
const Action = struct { key: Key, value: Value };
const Model = [key_count]Value;

const Workload = struct {
    actions: std.ArrayList(Action) = .empty,
    blobs: [4][4300]u8 = undefined,
    const blob_lengths = [_]usize{ 320, 640, 4300, 64 };
    const strings = [_][]const u8{
        "old string",
        "A longer replacement string crossing several entry boundaries, with a terminating NUL stored by NVS.",
        "final string",
    };
    const strings_z = blk: {
        var z: [strings.len][]const u8 = undefined;
        for (strings, &z) |string, *with_nul| with_nul.* = string ++ "\x00";
        break :blk z;
    };

    fn init(self: *Workload) !void {
        // Each aligned blob payload entry is itself a CRC-valid replacement
        // for keep=999. These bytes must always remain opaque as blob data.
        var fake: format.Item = .{ .ns = 1, .type = 4, .span = 1, .chunk_index = 255, .crc32 = undefined, .key = @splat(0), .data = @splat(0xff) };
        @memcpy(fake.key[0..4], "keep");
        std.mem.writeInt(u32, fake.data[0..4], 999, .little);
        fake.seal();
        for (&self.blobs, 0..) |*blob, version| {
            for (blob, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% version *% 53);
            var offset: usize = 0;
            while (offset + 32 <= blob_lengths[version]) : (offset += 32) @memcpy(blob[offset..][0..32], std.mem.asBytes(&fake));
        }
        try self.add(.keep, .{ .integer = 7 });
        try self.add(.other_keep, .{ .integer = 77 });
        inline for (.{ Key.byte, Key.half, Key.word, Key.wide, Key.signed_byte, Key.signed_half, Key.signed_word, Key.signed_wide }) |key| {
            try self.add(key, .{ .integer = 0xfedcba9876543210 });
            try self.add(key, .{ .integer = 0x0123456789abcdef });
        }
        try self.add(.text, .{ .string = 0 });
        try self.add(.blob, .{ .blob = 0 });
        try self.add(.text, .{ .string = 1 });
        try self.add(.blob, .{ .blob = 1 });
        try self.add(.blob, .absent);
        try self.add(.blob, .{ .blob = 2 });
        try self.add(.blob, .{ .blob = 3 });
        try self.add(.text, .absent);
        try self.add(.text, .{ .string = 2 });
        // Force several reclaims while other keys, strings and blob chunks
        // remain live. Mix overwrites and erases into the counter workload.
        for (0..600) |i| {
            try self.add(.counter, .{ .integer = i });
            if (i == 175 or i == 350) {
                try self.add(.signed_wide, .absent);
                try self.add(.signed_wide, .{ .integer = i });
                try self.add(.blob, .{ .blob = @intCast((i / 175) % 2) });
                try self.add(.text, .{ .string = @intCast((i / 175) % 3) });
            }
        }
        try self.add(.blob, .absent);
        try self.add(.byte, .absent);
        try self.add(.byte, .{ .integer = 42 });
    }

    fn deinit(self: *Workload) void {
        self.actions.deinit(testing.allocator);
    }

    fn add(self: *Workload, key: Key, value: Value) !void {
        try self.actions.append(testing.allocator, .{ .key = key, .value = value });
    }
};

fn namespace(key: Key) []const u8 {
    return if (key == .other_keep) "other" else "crash";
}

fn integer_type(comptime key: Key) type {
    return switch (key) {
        .byte => u8,
        .half => u16,
        .wide => u64,
        .signed_byte => i8,
        .signed_half => i16,
        .signed_word => i32,
        .signed_wide => i64,
        else => u32,
    };
}

fn integer_value(comptime T: type, bits: u64) T {
    return @bitCast(@as(@Int(.unsigned, @bitSizeOf(T)), @truncate(bits)));
}

fn apply_action(store: *Store, work: *const Workload, action: Action, mode: nvs.OpenMode) !void {
    const h = try store.open(namespace(action.key), mode);
    const name = @tagName(action.key);
    switch (action.value) {
        .absent => try h.erase_key(name),
        .string => |id| try h.set_str(name, Workload.strings[id]),
        .blob => |id| try h.set_blob(name, work.blobs[id][0..Workload.blob_lengths[id]]),
        .integer => |bits| switch (action.key) {
            inline else => |key| {
                const T = integer_type(key);
                try h.set(T, name, integer_value(T, bits));
            },
        },
    }
    try h.commit();
}

fn matches(store: *Store, work: *const Workload, key: Key, value: Value) !bool {
    const h = store.open(namespace(key), .read_only) catch |err| switch (err) {
        error.NotFound => return std.meta.activeTag(value) == .absent,
        else => return err,
    };
    const name = @tagName(key);
    var bytes: [4300]u8 = undefined;
    switch (key) {
        .text => {
            const result = h.get_str(name, &bytes) catch |err| switch (err) {
                error.NotFound => return std.meta.activeTag(value) == .absent,
                else => return err,
            };
            return switch (value) {
                .string => |id| std.mem.eql(u8, result, Workload.strings[id]),
                else => false,
            };
        },
        .blob => {
            const result = h.get_blob(name, &bytes) catch |err| switch (err) {
                error.NotFound => return std.meta.activeTag(value) == .absent,
                else => return err,
            };
            return switch (value) {
                .blob => |id| std.mem.eql(u8, result, work.blobs[id][0..Workload.blob_lengths[id]]),
                else => false,
            };
        },
        inline else => |k| {
            const T = integer_type(k);
            const result = h.get(T, name) catch |err| switch (err) {
                error.NotFound => return std.meta.activeTag(value) == .absent,
                else => return err,
            };
            return switch (value) {
                .integer => |bits| result == integer_value(T, bits),
                else => false,
            };
        },
    }
}

fn check_model(store: *Store, work: *const Workload, before: *const Model, action: Action, complete: bool) !Model {
    var observed = before.*;
    for (std.enums.values(Key)) |key| {
        const old = before[@backingInt(key)];
        if (key == action.key) {
            if (try matches(store, work, key, action.value)) {
                observed[@backingInt(key)] = action.value;
                continue;
            }
            if (!complete and try matches(store, work, key, old)) continue;
            // v5.5.1 can lose both versions before a same-page rewrite's
            // index is published (nvs_page.cpp:697-709).
            if (!complete and key == .blob and old == .blob and action.value == .blob and
                try matches(store, work, key, .absent))
            {
                observed[@backingInt(key)] = .absent;
                continue;
            }
        } else if (try matches(store, work, key, old)) continue;
        std.debug.print("model mismatch: key={s}, action={s}, complete={}\n", .{ @tagName(key), @tagName(action.key), complete });
        return error.TestUnexpectedResult;
    }
    return observed;
}

/// ESP-IDF `ItemType` of a key, as `crosscheck_idf.cpp` reads it.
fn idf_type(comptime key: Key) u8 {
    return switch (key) {
        .text => 0x21,
        .blob => 0x41,
        else => blk: {
            const info = @typeInfo(integer_type(key)).int;
            break :blk @as(u8, info.bits / 8) | (if (info.signedness == .signed) @as(u8, 0x10) else 0);
        },
    };
}

/// The bytes ESP-IDF stores for `value` under `key`, or null when it is absent.
fn value_bytes(work: *const Workload, key: Key, value: Value, buf: *[8]u8) ?[]const u8 {
    return switch (value) {
        .absent => null,
        // ESP-IDF stores the terminating NUL with the string.
        .string => |id| Workload.strings_z[id],
        .blob => |id| work.blobs[id][0..Workload.blob_lengths[id]],
        .integer => |bits| switch (key) {
            inline else => |k| blk: {
                const T = integer_type(k);
                std.mem.writeInt(T, buf[0..@sizeOf(T)], integer_value(T, bits), .little);
                break :blk buf[0..@sizeOf(T)];
            },
        },
    };
}

/// A key in a dump record: the values ESP-IDF may read there, null for none.
const DumpKey = struct {
    ns: []const u8,
    name: []const u8,
    /// ESP-IDF `ItemType`, as `crosscheck_idf.cpp` reads the key.
    idf_type: u8,
    allowed: []const ?[]const u8,
};

/// Appends one image to the dump: the flash, then for every key the values
/// ESP-IDF may read there. Little endian: "NVSR", u32 operation, u32 prefix,
/// u8 after, u8 recovered, the image, u8 key count, and per key u8 namespace
/// length and name, u8 key length and name, u8 ESP-IDF type, u8 alternative
/// count and per alternative u8 present, u32 length and the bytes.
fn write_record(mem: []const u8, keys: []const DumpKey, target: usize, prefix: usize, after: bool, recovered: bool) !void {
    const file = try dump() orelse return;
    var record: std.ArrayList(u8) = .empty;
    const gpa = testing.allocator;
    defer record.deinit(gpa);
    try record.appendSlice(gpa, "NVSR");
    var word: [4]u8 = undefined;
    for ([_]usize{ target, prefix }) |n| {
        std.mem.writeInt(u32, &word, @intCast(n), .little);
        try record.appendSlice(gpa, &word);
    }
    try record.append(gpa, @intFromBool(after));
    try record.append(gpa, @intFromBool(recovered));
    try record.appendSlice(gpa, mem);
    try record.append(gpa, @intCast(keys.len));
    for (keys) |key| {
        try record.append(gpa, @intCast(key.ns.len));
        try record.appendSlice(gpa, key.ns);
        try record.append(gpa, @intCast(key.name.len));
        try record.appendSlice(gpa, key.name);
        try record.append(gpa, key.idf_type);
        try record.append(gpa, @intCast(key.allowed.len));
        for (key.allowed) |bytes| {
            try record.append(gpa, @intFromBool(bytes != null));
            std.mem.writeInt(u32, &word, @intCast(if (bytes) |b| b.len else 0), .little);
            try record.appendSlice(gpa, &word);
            try record.appendSlice(gpa, bytes orelse &.{});
        }
    }
    try file.writeStreamingAll(testing.io, record.items);
}

/// Dumps an image of the workload: every key holds its value in `expected`,
/// except the in-flight `action`'s key, which may also hold the old one if
/// `either`.
fn dump_image(mem: []const u8, work: *const Workload, expected: *const Model, action: Action, either: bool, target: usize, prefix: usize, after: bool, recovered: bool) !void {
    if (options.dump_path.len == 0) return;
    var bufs: [key_count][3][8]u8 = undefined;
    var allowed: [key_count][3]?[]const u8 = undefined;
    var keys: [key_count]DumpKey = undefined;
    for (std.enums.values(Key), 0..) |key, i| {
        const pair = [3]Value{ if (key == action.key) action.value else expected[i], expected[i], .absent };
        const lossy = key == .blob and action.value == .blob and expected[i] == .blob;
        const count: usize = if (key == action.key and either) (if (lossy) @as(usize, 3) else 2) else 1;
        for (pair[0..count], 0..) |value, j| allowed[i][j] = value_bytes(work, key, value, &bufs[i][j]);
        keys[i] = .{
            .ns = namespace(key),
            .name = @tagName(key),
            .idf_type = switch (key) {
                inline else => |k| idf_type(k),
            },
            .allowed = allowed[i][0..count],
        };
    }
    try write_record(mem, &keys, target, prefix, after, recovered);
}

var dump_file: ?std.Io.File = null;

/// The dump, created by the first test that writes to it and kept open for
/// the next ones; the test runner's exit closes it.
fn dump() !?std.Io.File {
    if (options.dump_path.len == 0) return null;
    if (dump_file == null) dump_file = try std.Io.Dir.createFileAbsolute(testing.io, options.dump_path, .{});
    return dump_file;
}

/// The flash after `operations[0..target]` and `prefix` bytes of
/// `operations[target]` (all of it for an erase), from `seed`.
fn replay_image(seed: []const u8, operations: []const Operation, target: usize, prefix: usize) [partition_size]u8 {
    var mem: [partition_size]u8 = seed[0..partition_size].*;
    for (operations[0 .. target + 1], 0..) |op, index| {
        if (op.kind == .erase) {
            @memset(mem[op.offset..][0..nvs.page_size], 0xff);
        } else {
            const len = if (index == target) prefix else op.bytes.len;
            for (mem[op.offset..][0..len], op.bytes[0..len]) |*dest, byte| dest.* &= byte;
        }
    }
    return mem;
}

fn replay(operations: []const Operation, work: *const Workload, before: *const Model, target: usize, prefix: usize, after: bool) !void {
    // Replay the recorded physical workload, not a store error/cleanup path.
    // Prefix replay is also independent of any cached state in the writer.
    const blank: [partition_size]u8 = @splat(0xff);
    var mem = replay_image(&blank, operations, target, prefix);
    const current = operations[target];
    errdefer std.debug.print("crash operation={d} step={d} kind={s} offset=0x{x} length={d} prefix={d} after={}\n", .{
        target, current.step, @tagName(current.kind), current.offset, current.bytes.len, prefix, after,
    });
    const complete = after and (target + 1 == operations.len or operations[target + 1].step != current.step);
    const action = work.actions.items[current.step];
    // ESP-IDF boots on the flash as the crash left it: committed keys, and
    // the in-flight key old or new.
    try dump_image(&mem, work, before, action, !complete, target, prefix, after, false);
    var flash: Flash = .{ .mem = &mem };
    defer flash.deinit();
    var store: Store = undefined;
    try store.init(&flash, mem.len);
    const observed = try check_model(&store, work, before, action, complete);
    // Once this store has recovered, ESP-IDF reads exactly what it read.
    try dump_image(&mem, work, &observed, .{ .key = action.key, .value = observed[@backingInt(action.key)] }, false, target, prefix, after, true);

    const h = try store.open("crash", .read_write);
    try h.set(u32, "probe", 0xdecafbad);
    try h.commit();
    try store.init(&flash, mem.len);
    try testing.expectEqual(@as(u32, 0xdecafbad), try (try store.open("crash", .read_only)).get(u32, "probe"));
    // Recovery's chosen old/new value must itself remain durable. A later
    // unrelated write cannot change that choice or resurrect an erased key.
    _ = try check_model(&store, work, &observed, .{ .key = .keep, .value = observed[@backingInt(Key.keep)] }, true);
}

test "exhaustive recorded NVS workload survives every word-boundary crash" {
    inline for (.{ nvs.OpenMode.read_write, nvs.OpenMode.read_write_purge }) |mode| try replay_workload(mode);
}

fn replay_workload(mode: nvs.OpenMode) !void {
    var work: Workload = .{};
    defer work.deinit();
    try work.init();
    var mem: [partition_size]u8 = @splat(0xff);
    var flash: Flash = .{ .mem = &mem, .recording = true };
    defer flash.deinit();
    var store: Store = undefined;
    try store.init(&flash, mem.len);
    for (work.actions.items, 0..) |action, step| {
        flash.step = step;
        try apply_action(&store, &work, action, mode);
    }
    var erases: usize = 0;
    var programs: usize = 0;
    var zeroings: usize = 0;
    var points: usize = 0;
    for (flash.operations.items) |op| {
        if (op.kind == .erase) erases += 1 else {
            programs += 1;
            // A purging handle zeroes an erased item's entries after its
            // bitmap update, as ESP-IDF's purge does: a reset can fall in
            // between. Without purging nothing is zeroed.
            if (op.bytes.len % format.entry_size == 0 and std.mem.allEqual(u8, op.bytes, 0)) zeroings += 1;
            points += op.bytes.len / 4;
        }
        points += 1; // Reset immediately after this completed operation.
    }
    try testing.expect(erases > 1);
    try testing.expectEqual(mode == .read_write_purge, zeroings > 0);
    std.debug.print("NVS exhaustive harness, {s}: actions={d} programs={d} zeroings={d} erases={d} crash_points={d}\n", .{ @tagName(mode), work.actions.items.len, programs, zeroings, erases, points });

    var model: Model = @splat(.absent);
    var next_action: usize = 0;
    var checked: usize = 0;
    for (flash.operations.items, 0..) |op, target| {
        while (next_action < op.step) : (next_action += 1) {
            const action = work.actions.items[next_action];
            model[@backingInt(action.key)] = action.value;
        }
        if (op.kind == .program) {
            for (0..op.bytes.len / 4) |word| {
                try replay(flash.operations.items, &work, &model, target, word * 4, false);
                checked += 1;
            }
        }
        try replay(flash.operations.items, &work, &model, target, op.bytes.len, true);
        checked += 1;
    }
    try testing.expectEqual(points, checked);
    std.debug.print("NVS exhaustive harness, {s}: checked={d} PASS\n", .{ @tagName(mode), checked });
}

/// state_fixture.cpp's blob contents: byte i is i * 7 + seed.
fn idf_state_pattern(comptime len: usize, seed: u8) [len]u8 {
    var data: [len]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @truncate(i *% 7 +% seed);
    return data;
}

/// The version 1 blob state_fixture.cpp wrote under "legacy", and the blob
/// written over it.
const legacy_first = idf_state_pattern(100, 3);
const legacy_second = idf_state_pattern(150, 0x21);

const LegacyCase = struct {
    fixture: []const u8,
    erase: bool,
    /// Fill the page after the fixture's full one with keys first, so that
    /// the write reclaims the fixture's page and moves the version 1 item.
    fill: bool = false,
};

const legacy_cases = [_]LegacyCase{
    .{ .fixture = "legacy_blob", .erase = false },
    .{ .fixture = "legacy_blob", .erase = true },
    .{ .fixture = "legacy_blob_full", .erase = false },
    .{ .fixture = "legacy_blob_full", .erase = true },
    .{ .fixture = "legacy_blob_full", .erase = false, .fill = true },
};

/// Live version 1 items of "legacy" in an image.
fn legacy_items(mem: []const u8) usize {
    var count: usize = 0;
    for (0..partition_size / nvs.page_size) |page| {
        const image = mem[page * nvs.page_size ..][0..nvs.page_size];
        var it: format.Iterator = .{};
        while (it.next(image)) |index| {
            const item = format.item_at(image, index);
            count += @intFromBool(item.type == format.type_blob_legacy and std.mem.eql(u8, item.key_slice(), "legacy"));
        }
    }
    return count;
}

/// The u32 keys around and after the version 1 blob, and "legacy" with
/// `allowed`, for the dump.
fn legacy_dump_keys(keys: []DumpKey, values: [][4]u8, allowed_u32: [][1]?[]const u8, names: [][8]u8, fillers: u32, legacy: []const ?[]const u8) ![]DumpKey {
    const fixed = [_]struct { []const u8, u32 }{ .{ "before", 0x0badcafe }, .{ "after", 0xfeedf00d } };
    var count: usize = 0;
    for (0..fixed.len + fillers) |i| {
        const name: []const u8 = if (i < fixed.len) fixed[i][0] else try std.mem.print(&names[i], "k{d}", .{i - fixed.len});
        std.mem.writeInt(u32, &values[i], if (i < fixed.len) fixed[i][1] else @intCast(i - fixed.len), .little);
        allowed_u32[i] = .{&values[i]};
        keys[count] = .{ .ns = "fixture", .name = name, .idf_type = 0x04, .allowed = &allowed_u32[i] };
        count += 1;
    }
    keys[count] = .{ .ns = "fixture", .name = "legacy", .idf_type = format.type_blob_legacy, .allowed = legacy };
    return keys[0 .. count + 1];
}

test "a reset at every word of a write over or an erase of a version 1 blob leaves the old or the new value" {
    var total: usize = 0;
    inline for (.{ nvs.OpenMode.read_write, nvs.OpenMode.read_write_purge }) |mode| {
        inline for (legacy_cases) |case| total += try replay_legacy(case, mode);
    }
    std.debug.print("NVS version 1 blob harness: crash_points={d} PASS\n", .{total});
}

fn replay_legacy(comptime case: LegacyCase, mode: nvs.OpenMode) !usize {
    var base: [partition_size]u8 = @embedFile("nvs_testdata/idf_state_" ++ case.fixture ++ ".bin").*;
    var flash: Flash = .{ .mem = &base };
    defer flash.deinit();
    var store: Store = undefined;
    try store.init(&flash, base.len);
    const h = try store.open("fixture", mode);
    var fillers: u32 = 0;
    var name: [8]u8 = undefined;
    if (case.fill) {
        while (store.active == null or format.entries_per_page - @as(usize, store.next_free) > 3) : (fillers += 1) {
            try h.set(u32, try std.mem.print(&name, "k{d}", .{fillers}), fillers);
        }
    }
    const seed = base;
    flash.recording = true;
    if (case.erase) try h.erase_key("legacy") else try h.set_blob("legacy", &legacy_second);
    const operations = flash.operations.items;
    const new: ?[]const u8 = if (case.erase) null else &legacy_second;
    const old: ?[]const u8 = &legacy_first;

    if (case.fill) {
        // The write reclaimed the fixture's page 0: the version 1 item was
        // copied to another page, and page 0 erased.
        var copied = false;
        var erased = false;
        for (operations) |op| {
            if (op.kind == .erase) {
                erased = erased or op.offset == 0;
            } else if (op.offset >= nvs.page_size and op.bytes.len >= format.entry_size) {
                var item: format.Item = undefined;
                @memcpy(std.mem.asBytes(&item), op.bytes[0..format.entry_size]);
                copied = copied or (item.type == format.type_blob_legacy and std.mem.eql(u8, item.key_slice(), "legacy"));
            }
        }
        try testing.expect(copied and erased);
    }

    var keys: [130]DumpKey = undefined;
    var values: [130][4]u8 = undefined;
    var allowed: [130][1]?[]const u8 = undefined;
    var names: [130][8]u8 = undefined;
    var points: usize = 0;
    for (operations, 0..) |op, target| {
        const cuts = if (op.kind == .erase) 1 else op.bytes.len / 4 + 1;
        for (0..cuts) |cut| {
            const prefix = if (op.kind == .erase) 0 else cut * 4;
            const after = op.kind == .erase or prefix == op.bytes.len;
            errdefer std.debug.print("idf_state_{s}.bin, erase {}, fill {}, {s}: operation {d} of {d}, prefix {d}\n", .{ case.fixture, case.erase, case.fill, @tagName(mode), target, operations.len, prefix });
            var mem = replay_image(&seed, operations, target, prefix);
            const done = after and target + 1 == operations.len;
            const either = [_]?[]const u8{ new, old };
            try write_record(&mem, try legacy_dump_keys(&keys, &values, &allowed, &names, fillers, either[0..if (done) 1 else 2]), target, prefix, after, false);

            var crashed: Flash = .{ .mem = &mem };
            defer crashed.deinit();
            var recovered: Store = undefined;
            try recovered.init(&crashed, mem.len);
            const r = try recovered.open("fixture", .read_only);
            var buf: [200]u8 = undefined;
            const read: ?[]const u8 = r.get_blob("legacy", &buf) catch |err| switch (err) {
                error.NotFound => null,
                else => return err,
            };
            const kept_old = read != null and std.mem.eql(u8, read.?, old.?);
            const took_new = if (new) |n| read != null and std.mem.eql(u8, read.?, n) else read == null;
            try testing.expect(kept_old or took_new);
            if (done) try testing.expect(took_new);
            // Once the new value is read, the version 1 item is gone.
            try testing.expectEqual(@as(usize, @intFromBool(kept_old)), legacy_items(&mem));
            try testing.expectEqual(@as(u32, 0x0badcafe), try r.get(u32, "before"));
            try testing.expectEqual(@as(u32, 0xfeedf00d), try r.get(u32, "after"));
            for (0..fillers) |i| try testing.expectEqual(@as(u32, @intCast(i)), try r.get(u32, try std.mem.print(&name, "k{d}", .{i})));
            const chosen = [_]?[]const u8{if (kept_old) old else new};
            try write_record(&mem, try legacy_dump_keys(&keys, &values, &allowed, &names, fillers, &chosen), target, prefix, after, true);

            // The choice survives another write and a reopen.
            try (try recovered.open("fixture", .read_write)).set(u32, "probe", 5);
            try recovered.init(&crashed, mem.len);
            const again: ?[]const u8 = (try recovered.open("fixture", .read_only)).get_blob("legacy", &buf) catch |err| switch (err) {
                error.NotFound => null,
                else => return err,
            };
            try testing.expectEqual(chosen[0] == null, again == null);
            if (chosen[0]) |value| try testing.expectEqualSlices(u8, value, again.?);
            points += 1;
        }
    }
    std.debug.print("NVS version 1 blob harness, idf_state_{s}.bin, erase {}, fill {}, {s}: operations={d} crash_points={d}\n", .{ case.fixture, case.erase, case.fill, @tagName(mode), operations.len, points });
    return points;
}
