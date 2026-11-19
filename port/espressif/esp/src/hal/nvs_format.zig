//! ESP-IDF NVS v2 page and entry encoding. No flash or target dependencies.
//! Based on totorototo/microzig@f64390f2.
//! Reference: ESP-IDF components/nvs_flash/src/nvs_{types,page}.{hpp,cpp}.
const std = @import("std");
const assert = std.debug.assert;

pub const page_size = 4096;
pub const max_key_len = 15;
/// Longest string, including the terminating zero ESP-IDF stores with it.
pub const max_str_len = 4000;

/// Most pages a partition can have here (256 KiB). Each costs 8 bytes of RAM.
pub const max_pages = 64;

pub const entry_size = 32;
pub const entries_per_page = 126;
pub const header_size = 32;
pub const bitmap_offset = 32;
pub const entries_offset = 64;
pub const version_2 = 0xFE;
/// Most data in one item: all the entries of a page but the item's own.
pub const max_item_data = (entries_per_page - 1) * entry_size;
pub const max_blob_chunks = 127;

pub const PageState = enum(u32) {
    uninitialized = 0xFFFF_FFFF,
    active = 0xFFFF_FFFE,
    full = 0xFFFF_FFFC,
    freeing = 0xFFFF_FFF8,
    corrupt = 0xFFFF_FFF0,
    _,
};

pub const EntryState = enum(u2) {
    erased = 0b00,
    illegal = 0b01,
    written = 0b10,
    empty = 0b11,
};

pub const type_u8 = 0x01;
pub const type_str = 0x21;
/// A format version 1 blob: one item, no chunks. Version 2 never writes it.
pub const type_blob_legacy = 0x41;
pub const type_blob_data = 0x42;
pub const type_blob_index = 0x48;

pub const no_chunk = 0xFF;

/// The on-flash layout of an entry that starts an item.
pub const Item = extern struct {
    ns: u8,
    type: u8,
    span: u8,
    chunk_index: u8,
    crc32: [4]u8,
    key: [16]u8,
    data: [8]u8,

    comptime {
        assert(@sizeOf(Item) == entry_size);
    }

    pub fn compute_crc(item: *const Item) u32 {
        const bytes = std.mem.asBytes(item);
        var crc = crc32(0xFFFF_FFFF, bytes[0..4]);
        crc = crc32(crc, bytes[8..24]);
        return crc32(crc, bytes[24..32]);
    }

    pub fn seal(item: *Item) void {
        std.mem.writeInt(u32, &item.crc32, item.compute_crc(), .little);
    }

    pub fn crc_ok(item: *const Item) bool {
        return std.mem.readInt(u32, &item.crc32, .little) == item.compute_crc();
    }

    pub fn key_slice(item: *const Item) []const u8 {
        return std.mem.sliceTo(&item.key, 0);
    }

    /// Strings and blob chunks: byte count of the data that follows.
    pub fn data_len(item: *const Item) u16 {
        return std.mem.readInt(u16, item.data[0..2], .little);
    }

    pub fn data_crc(item: *const Item) u32 {
        return std.mem.readInt(u32, item.data[4..8], .little);
    }

    /// Blob index: total size, number of chunks and index of the first one.
    pub fn blob_size(item: *const Item) u32 {
        return std.mem.readInt(u32, item.data[0..4], .little);
    }

    pub fn is(item: *const Item, item_type: u8, ns: u8, key: []const u8) bool {
        return item.type == item_type and item.ns == ns and std.mem.eql(u8, item.key_slice(), key);
    }

    /// Blob index: whether `chunk_index` is one of the chunks it names, as
    /// ESP-IDF's `Storage::eraseOrphanDataBlobs` decides.
    pub fn claims(item: *const Item, chunk_index: u8) bool {
        return chunk_index >= item.data[5] and chunk_index - item.data[5] < item.data[4];
    }
};

/// CRC-32 as computed by the ROM's `crc32_le`: `seed` is the value returned for the data before.
/// ESP-IDF's NVS starts from 0xFFFFFFFF, which is not the standard CRC-32 (that one starts at 0).
pub fn crc32(seed: u32, data: []const u8) u32 {
    var crc = ~seed;
    for (data) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            crc = (crc >> 1) ^ (0xEDB8_8320 & (0 -% (crc & 1)));
        }
    }
    return ~crc;
}

pub const Error = error{ Corrupt, UnsupportedVersion };

pub const Header = struct {
    state: PageState,
    seq: u32,

    /// The header of a page in use. As ESP-IDF's `Page::load`, the CRC is
    /// checked before the version.
    pub fn decode(bytes: *const [header_size]u8) Error!Header {
        const state: PageState = @fromBackingInt(std.mem.readInt(u32, bytes[0..4], .little));
        switch (state) {
            .active, .full, .freeing => {},
            else => return error.Corrupt,
        }
        if (std.mem.readInt(u32, bytes[28..32], .little) != crc32(0xffffffff, bytes[4..28])) return error.Corrupt;
        if (bytes[8] != version_2) return error.UnsupportedVersion;
        return .{ .state = state, .seq = std.mem.readInt(u32, bytes[4..8], .little) };
    }

    pub fn encode(self: Header) [header_size]u8 {
        var bytes: [header_size]u8 = @splat(0xff);
        std.mem.writeInt(u32, bytes[0..4], @backingInt(self.state), .little);
        std.mem.writeInt(u32, bytes[4..8], self.seq, .little);
        bytes[8] = version_2;
        std.mem.writeInt(u32, bytes[28..32], crc32(0xffffffff, bytes[4..28]), .little);
        return bytes;
    }
};

pub fn item_at(page: *const [page_size]u8, index: usize) *const Item {
    assert(index < entries_per_page);
    return @ptrCast(page[entries_offset + index * entry_size ..][0..entry_size]);
}

pub fn entry_state(page: *const [page_size]u8, index: usize) EntryState {
    assert(index < entries_per_page);
    return @fromBackingInt(@intCast(@as(u2, @truncate(page[bitmap_offset + index / 4] >> @intCast(index % 4 * 2)))));
}

/// The bounded extent claimed by an item header, independent of publication
/// and CRC checks.
pub fn item_span(page: *const [page_size]u8, index: usize) ?u8 {
    const item = item_at(page, index);
    const span = item.span;
    if (span == 0 or index + span > entries_per_page) return null;
    switch (item.type) {
        0x01, 0x02, 0x04, 0x08, 0x11, 0x12, 0x14, 0x18, type_blob_index => {
            if (span != 1) return null;
        },
        type_str, type_blob_legacy, type_blob_data => {
            if (span != 1 + (@as(usize, item.data_len()) + entry_size - 1) / entry_size) return null;
        },
        else => return null,
    }
    return span;
}

/// The extent of a torn, unpublished variable-length header, from its first
/// word: the writer programs that word (with the span) before any payload.
/// Length, key and CRC may still be erased. Only extents of wholly empty or
/// erased entries qualify, so no published entry is ever covered.
pub fn scan_span(page: *const [page_size]u8, index: usize) ?u8 {
    if (item_span(page, index)) |span| return span;
    const item = item_at(page, index);
    if (item.type != type_str and item.type != type_blob_data) return null;
    const span = item.span;
    if (span < 2 or index + span > entries_per_page) return null;
    for (index..index + span) |i| switch (entry_state(page, i)) {
        .empty, .erased => {},
        else => return null,
    };
    return span;
}

/// Header consistency is independent of the publication bitmap. Payload CRC
/// is checked when reading data, separately from this header CRC.
pub fn valid_header(page: *const [page_size]u8, index: usize) bool {
    const item = item_at(page, index);
    if (!item.crc_ok() or item_span(page, index) == null or item.ns == 255) return false;
    const key_len = std.mem.indexOfScalar(u8, &item.key, 0) orelse return false;
    if (key_len == 0) return false;
    if (item.ns == 0 and (item.type != type_u8 or item.data[0] == 0 or item.data[0] == 255)) return false;
    switch (item.type) {
        0x01, 0x02, 0x04, 0x08, 0x11, 0x12, 0x14, 0x18 => {
            if (item.chunk_index != no_chunk) return false;
        },
        type_blob_index => {
            if (item.chunk_index != no_chunk or item.data[4] > max_blob_chunks or
                item.blob_size() > max_blob_chunks * max_item_data) return false;
        },
        type_str, type_blob_data => {
            const len: usize = item.data_len();
            if (item.type == type_str and (len == 0 or item.chunk_index != no_chunk)) return false;
            if (item.type == type_blob_data and item.chunk_index == no_chunk) return false;
        },
        // ESP-IDF looks a version 1 blob up with the chunk index 0xff it
        // was written with (`Storage::findItem` with `Page::CHUNK_ANY`).
        type_blob_legacy => if (item.chunk_index != no_chunk) return false,
        else => return false,
    }
    return true;
}

/// ESP-IDF's `Item::checkHeaderConsistency`: CRC, type, and the span and
/// chunk fields that type requires. Looser than `valid_header`, which also
/// refuses what this store will not return as a key; only this decides what
/// ESP-IDF itself would erase.
pub fn consistent_header(page: *const [page_size]u8, index: usize) bool {
    const item = item_at(page, index);
    if (!item.crc_ok()) return false;
    switch (item.type) {
        0x01, 0x02, 0x04, 0x08, 0x11, 0x12, 0x14, 0x18 => return item.span == 1,
        type_blob_index => return item.span == 1 and item.chunk_index == no_chunk and
            item.blob_size() <= max_blob_chunks * max_item_data,
        type_str, type_blob_legacy, type_blob_data => {
            if (item.type == type_blob_data and item.chunk_index == no_chunk) return false;
            const len: usize = item.data_len();
            return len <= (entries_per_page - index - 1) * entry_size and
                item.span == 1 + (len + entry_size - 1) / entry_size;
        },
        else => return false,
    }
}

/// ESP-IDF's `isVariableLengthType`: the item's span covers its payload.
pub fn variable_length(item_type: u8) bool {
    return item_type == type_str or item_type == type_blob_legacy or item_type == type_blob_data;
}

/// Whether the consistent header at `index` is an item: marked written in
/// every entry it takes, its span if it is of a variable-length type.
pub fn published(page: *const [page_size]u8, index: usize) bool {
    const item = item_at(page, index);
    const span: usize = if (variable_length(item.type)) item.span else 1;
    for (index..index + span) |i| if (entry_state(page, i) != .written) return false;
    return true;
}

/// An entry marked illegal, or marked written with an inconsistent header
/// (all-0xff bytes included). ESP-IDF erases and zeroes such an entry on its
/// own, never trusting its span, and goes on to the next entry
/// (`Page::mLoadEntryTable`, `Page::findItem`, `Page::eraseEntryAndSpan`);
/// so do walks and recovery here. Neither this store's writes nor its erases
/// ever leave one behind, interrupted or not: a header is complete before its
/// bitmap marks it written, and illegal is never written. It takes damage,
/// or a header programmed in place.
pub fn stray_entry(page: *const [page_size]u8, index: usize) bool {
    return switch (entry_state(page, index)) {
        .illegal => true,
        .written => !consistent_header(page, index),
        .empty, .erased => false,
    };
}

/// Walks a page item by item the way ESP-IDF's `Page::findItem`,
/// `Page::copyItems` and the full-page part of `Page::mLoadEntryTable` do:
/// an entry not marked written is stepped over alone, and so is a written
/// one whose header is not consistent; a consistent header of a
/// variable-length type is stepped over with its span. ESP-IDF never parses
/// an entry that is not marked written: it never reads a span from an
/// erased, empty or illegal header. This store's own writes and erases keep
/// that safe: an item is published header first and erased payload first
/// (as ESP-IDF's `Page::alterEntryRangeState` does), so a header is marked
/// written whenever any of its payload is.
pub const Iterator = struct {
    index: usize = 0,
    /// ESP-IDF reads an active page only up to its first free entry
    /// (`mNextFreeEntry`); a full page to its end.
    end: usize = entries_per_page,

    /// The next item that is marked written in all its entries, with a
    /// consistent header: what ESP-IDF's reclaim copies. Null at the end.
    pub fn next_published(self: *Iterator, page: *const [page_size]u8) ?u8 {
        while (self.index < self.end) {
            const index = self.index;
            self.index += 1;
            if (entry_state(page, index) != .written or !consistent_header(page, index)) continue;
            const item = item_at(page, index);
            if (variable_length(item.type)) self.index = index + item.span;
            if (published(page, index)) return @intCast(index);
        }
        return null;
    }

    /// The next published item this store serves as a key. Null at the end.
    pub fn next(self: *Iterator, page: *const [page_size]u8) ?u8 {
        while (self.next_published(page)) |index| {
            if (valid_header(page, index)) return index;
        }
        return null;
    }
};

/// A caller-owned hash map for one cached page. Hash collisions are resolved
/// by chains and full key comparison; data entries never become map items.
pub const PageIndex = struct {
    heads: [128]u8 = @splat(255),
    next: [entries_per_page]u8 = @splat(255),
    hashes: [entries_per_page]u32 = undefined,

    pub fn hash(ns: u8, key: []const u8) u32 {
        return crc32(crc32(0, &.{ns}), key);
    }

    /// Indexes the items a walk up to `end` serves (see `Iterator.end`).
    pub fn rebuild(self: *PageIndex, page: *const [page_size]u8, end: usize) void {
        self.* = .{};
        var it: Iterator = .{ .end = end };
        while (it.next(page)) |index| {
            const item = item_at(page, index);
            const h = hash(item.ns, item.key_slice());
            const bucket = h % self.heads.len;
            self.hashes[index] = h;
            self.next[index] = self.heads[bucket];
            self.heads[bucket] = index;
        }
    }

    /// Returns the first matching item on this page, ignoring an optional
    /// location, as ESP-IDF's `Page::findItem` does. A null type selects
    /// primary items (excludes blob chunks).
    pub fn find(self: *const PageIndex, page: *const [page_size]u8, ns: u8, kind: ?u8, key: []const u8, chunk: u8, skip: ?u8) ?u8 {
        const h = hash(ns, key);
        var found: ?u8 = null;
        // Chains run from the last item indexed to the first.
        var index = self.heads[h % self.heads.len];
        while (index != 255) : (index = self.next[index]) {
            if (skip == index or self.hashes[index] != h) continue;
            const item = item_at(page, index);
            const type_matches = if (kind) |t| item.type == t and item.chunk_index == chunk else item.type != type_blob_data;
            if (item.ns == ns and type_matches and std.mem.eql(u8, item.key_slice(), key)) found = index;
        }
        return found;
    }
};

const testing = std.testing;

test "CRC seeds, chaining, headers and item encoding" {
    try testing.expectEqual(@as(u32, 0xcbf43926), crc32(0, "123456789"));
    try testing.expectEqual(@as(u32, 0xd202d277), crc32(0xffffffff, "123456789"));
    try testing.expectEqual(crc32(0xffffffff, "123456789"), crc32(crc32(0xffffffff, "1234"), "56789"));
    const header: Header = .{ .state = .active, .seq = 42 };
    var raw = header.encode();
    try testing.expectEqual(header, try Header.decode(&raw));
    raw[8] = 0xff;
    std.mem.writeInt(u32, raw[28..32], crc32(0xffffffff, raw[4..28]), .little);
    try testing.expectError(error.UnsupportedVersion, Header.decode(&raw));
    // A bad CRC decides before the version.
    raw[4] ^= 1;
    try testing.expectError(error.Corrupt, Header.decode(&raw));
    raw = header.encode();
    raw[0] = 0xf0;
    try testing.expectError(error.Corrupt, Header.decode(&raw));
    var item: Item = .{ .ns = 1, .type = 0x18, .span = 1, .chunk_index = no_chunk, .crc32 = undefined, .key = @splat(0), .data = undefined };
    @memcpy(item.key[0..3], "key");
    std.mem.writeInt(i64, &item.data, -123456789, .little);
    item.seal();
    try testing.expect(item.crc_ok());
    try testing.expectEqual(@as(i64, -123456789), std.mem.readInt(i64, &item.data, .little));
    item.data[7] ^= 1;
    try testing.expect(!item.crc_ok());
}

test "page index resolves bucket collisions and finds the first duplicate, as ESP-IDF does" {
    var page: [page_size]u8 = @splat(0xff);
    // More than 128 candidates guarantees a shared bucket. Keep just that pair.
    var seen: [128]?u16 = @splat(null);
    var keys: [2][16]u8 = @splat(@splat(0));
    for (0..129) |n| {
        var key: [16]u8 = @splat(0);
        const name = try std.fmt.bufPrint(&key, "key{d}", .{n});
        const bucket = PageIndex.hash(1, name) % 128;
        if (seen[bucket]) |previous| {
            _ = try std.fmt.bufPrint(&keys[0], "key{d}", .{previous});
            keys[1] = key;
            break;
        }
        seen[bucket] = @intCast(n);
    }
    for (0..3) |i| {
        var item: Item = .{ .ns = 1, .type = type_u8, .span = 1, .chunk_index = no_chunk, .crc32 = undefined, .key = keys[i % 2], .data = @splat(0xff) };
        item.data[0] = @intCast(i);
        item.seal();
        @memcpy(page[entries_offset + i * entry_size ..][0..entry_size], std.mem.asBytes(&item));
        page[bitmap_offset] &= ~(@as(u8, 1) << @intCast(i * 2));
    }
    var index: PageIndex = .{};
    index.rebuild(&page, entries_per_page);
    try testing.expectEqual(@as(?u8, 0), index.find(&page, 1, type_u8, std.mem.sliceTo(&keys[0], 0), no_chunk, null));
    try testing.expectEqual(@as(?u8, 2), index.find(&page, 1, type_u8, std.mem.sliceTo(&keys[0], 0), no_chunk, 0));
    try testing.expectEqual(@as(?u8, 1), index.find(&page, 1, null, std.mem.sliceTo(&keys[1], 0), no_chunk, null));
    try testing.expectEqual(@as(?u8, null), index.find(&page, 2, null, std.mem.sliceTo(&keys[1], 0), no_chunk, null));
}

test "decode ESP-IDF generated v2 page and reject malformed spans" {
    const image = @embedFile("nvs_testdata/idf.bin");
    var page: [page_size]u8 = image[0..page_size].*;
    try testing.expectEqual(@as(u32, 0), (try Header.decode(page[0..32])).seq);
    var it: Iterator = .{};
    const expected = [_]u8{ 0, 1, 2, 3, 5, 7 };
    for (expected) |i| {
        try testing.expectEqual(@as(?u8, i), it.next(&page));
        try testing.expect(item_at(&page, i).crc_ok());
    }
    try testing.expectEqual(@as(?u8, null), it.next(&page));
    try testing.expectEqual(@as(u64, 0xfedcba9876543210), std.mem.readInt(u64, &item_at(&page, 1).data, .little));
    try testing.expectEqual(@as(i32, -123456), std.mem.readInt(i32, item_at(&page, 2).data[0..4], .little));
    const string = item_at(&page, 3);
    try testing.expectEqual(@as(u8, 2), string.span);
    const data = page[entries_offset + 4 * entry_size ..][0..string.data_len()];
    try testing.expectEqualStrings("ESP-IDF fixture\x00", data);
    try testing.expectEqual(string.data_crc(), crc32(0xffffffff, data));
    var map: PageIndex = .{};
    map.rebuild(&page, entries_per_page);
    try testing.expectEqual(@as(?u8, 7), map.find(&page, 1, null, "payload", no_chunk, null));
    // On an active page ESP-IDF reads up to the first free entry only.
    map.rebuild(&page, 7);
    try testing.expectEqual(@as(?u8, null), map.find(&page, 1, null, "payload", no_chunk, null));
    try testing.expectEqual(@as(?u8, 2), map.find(&page, 1, null, "signed", no_chunk, null));
    var malformed = string.*;
    malformed.span = 126;
    malformed.seal();
    @memcpy(page[entries_offset + 3 * entry_size ..][0..entry_size], std.mem.asBytes(&malformed));
    try testing.expect(!consistent_header(&page, 3));
    malformed = @as(*const Item, @ptrCast(image[entries_offset + 3 * entry_size ..][0..entry_size])).*;
    @memcpy(page[entries_offset + 3 * entry_size ..][0..entry_size], std.mem.asBytes(&malformed));
    try testing.expect(consistent_header(&page, 3) and published(&page, 3));
    page[bitmap_offset + 1] &= 0xfc; // Erase string payload entry 4.
    try testing.expect(consistent_header(&page, 3) and !published(&page, 3));
}

test "walk keeps the payload of a written header opaque and steps over other entries alone" {
    var page: [page_size]u8 = @splat(0xff);
    var container: Item = .{ .ns = 1, .type = type_blob_data, .span = 3, .chunk_index = 0, .crc32 = undefined, .key = @splat(0), .data = @splat(0xff) };
    @memcpy(container.key[0..4], "blob");
    std.mem.writeInt(u16, container.data[0..2], 64, .little);
    container.seal();
    var fake: Item = .{ .ns = 1, .type = 4, .span = 1, .chunk_index = no_chunk, .crc32 = undefined, .key = @splat(0), .data = @splat(0xff) };
    @memcpy(fake.key[0..9], "untouched");
    std.mem.writeInt(u32, fake.data[0..4], 999, .little);
    fake.seal();
    var following = fake;
    following.key = @splat(0);
    @memcpy(following.key[0..4], "next");
    following.seal();
    @memcpy(page[entries_offset + entry_size ..][0..entry_size], std.mem.asBytes(&fake));
    @memcpy(page[entries_offset + 3 * entry_size ..][0..entry_size], std.mem.asBytes(&following));

    for ([_]EntryState{ .written, .erased, .empty, .illegal }) |state| {
        inline for (.{ true, false }) |crc_valid| {
            @memcpy(page[entries_offset..][0..entry_size], std.mem.asBytes(&container));
            if (!crc_valid) page[entries_offset + 4] ^= 1;
            // Payload entry 1 and following item 3 are written; payload entry
            // 2 is empty. The enclosing item is never completely published.
            page[bitmap_offset] = 0xb8 | @as(u8, @backingInt(state));
            try testing.expectEqual(crc_valid, valid_header(&page, 0));
            try testing.expectEqual(crc_valid, consistent_header(&page, 0));
            try testing.expect(!published(&page, 0));
            try testing.expectEqual(@as(?u8, 3), item_span(&page, 0));
            // Like ESP-IDF, only a consistent header marked written claims
            // its span. Any other entry is stepped over alone, and payload
            // marked written after it is read as headers. This store's
            // writes and erases never leave payload marked written behind a
            // header that is not (see `Iterator`).
            const opaque_extent = state == .written and crc_valid;
            try testing.expectEqual(state == .illegal or (state == .written and !crc_valid), stray_entry(&page, 0));
            var it: Iterator = .{};
            if (!opaque_extent) try testing.expectEqual(@as(?u8, 1), it.next(&page));
            try testing.expectEqual(@as(?u8, 3), it.next(&page));
            try testing.expectEqual(@as(?u8, null), it.next(&page));
            var map: PageIndex = .{};
            map.rebuild(&page, entries_per_page);
            try testing.expectEqual(if (opaque_extent) null else @as(?u8, 1), map.find(&page, 1, null, "untouched", no_chunk, null));
            try testing.expectEqual(@as(?u8, 3), map.find(&page, 1, null, "next", no_chunk, null));
        }
    }
    // A span that is out of bounds or disagrees with the data length makes
    // the header inconsistent: marked written, it is a stray entry; marked
    // empty, an entry ESP-IDF does not parse. Either way it is stepped over
    // alone.
    for ([_]u8{ 0, 1, entries_per_page + 1 }) |span| {
        container.span = span;
        container.seal();
        @memcpy(page[entries_offset..][0..entry_size], std.mem.asBytes(&container));
        for ([_]u8{ 0xaa, 0xab }) |bitmap| {
            page[bitmap_offset] = bitmap;
            try testing.expectEqual(bitmap == 0xaa, stray_entry(&page, 0));
            var it: Iterator = .{};
            try testing.expectEqual(@as(?u8, 1), it.next(&page));
            try testing.expectEqual(@as(?u8, 3), it.next(&page));
            try testing.expectEqual(@as(?u8, null), it.next(&page));
        }
    }
    // An all-0xff entry marked written or illegal is a stray entry too.
    page = @splat(0xff);
    page[bitmap_offset] = 0b0110;
    try testing.expect(stray_entry(&page, 0));
    try testing.expect(stray_entry(&page, 1));
    try testing.expect(!stray_entry(&page, 2));
}

test "a legacy 0x41 blob is stepped over with its span and served" {
    var page: [page_size]u8 = @splat(0xff);
    var legacy: Item = .{ .ns = 1, .type = type_blob_legacy, .span = 3, .chunk_index = no_chunk, .crc32 = undefined, .key = @splat(0), .data = @splat(0xff) };
    @memcpy(legacy.key[0..3], "old");
    std.mem.writeInt(u16, legacy.data[0..2], 64, .little);
    legacy.seal();
    var fake: Item = .{ .ns = 1, .type = 4, .span = 1, .chunk_index = no_chunk, .crc32 = undefined, .key = @splat(0), .data = @splat(0xff) };
    @memcpy(fake.key[0..4], "fake");
    fake.seal();
    @memcpy(page[entries_offset..][0..entry_size], std.mem.asBytes(&legacy));
    @memcpy(page[entries_offset + entry_size ..][0..entry_size], std.mem.asBytes(&fake));
    @memcpy(page[entries_offset + 3 * entry_size ..][0..entry_size], std.mem.asBytes(&fake));
    page[bitmap_offset] = 0b10_10_10_10;
    try testing.expect(consistent_header(&page, 0));
    try testing.expectEqual(@as(?u8, 3), item_span(&page, 0));
    try testing.expect(valid_header(&page, 0));
    var it: Iterator = .{};
    try testing.expectEqual(@as(?u8, 0), it.next_published(&page));
    try testing.expectEqual(@as(?u8, 3), it.next_published(&page));
    it = .{};
    try testing.expectEqual(@as(?u8, 0), it.next(&page));
    try testing.expectEqual(@as(?u8, 3), it.next(&page));
    try testing.expectEqual(@as(?u8, null), it.next(&page));
    // It is a key, as a blob index is: what a lookup without a type finds.
    var map: PageIndex = .{};
    map.rebuild(&page, entries_per_page);
    try testing.expectEqual(@as(?u8, 0), map.find(&page, 1, null, "old", no_chunk, null));
    // Written with another chunk index, ESP-IDF's lookups miss it.
    page[entries_offset + 3] = 0;
    @as(*Item, @ptrCast(page[entries_offset..][0..entry_size])).seal();
    try testing.expect(consistent_header(&page, 0));
    try testing.expect(!valid_header(&page, 0));
}

test "walk steps over ESP-IDF zero-purged entries and interrupted purges one at a time" {
    const cases = .{
        .{ "idf_purged_all_full.bin", [_]u8{ 0, 2, 3, 5, 7, 18, 19 } },
        // The purge zeroed only the string's header: entries 9-12 still hold text.
        .{ "idf_purged_string_partial_full.bin", [_]u8{ 0, 1, 2, 3, 5, 7, 13, 17, 18, 19 } },
        // The blob's header is zeroed and its first payload entry, 14, is a
        // CRC-valid string header whose span 6 would cover the keys at 18-19.
        .{ "idf_purged_blob_partial_full.bin", [_]u8{ 0, 1, 2, 3, 5, 7, 8, 18, 19 } },
    };
    inline for (cases) |case| {
        const page: *const [page_size]u8 = @embedFile("nvs_testdata/" ++ case[0]);
        var it: Iterator = .{};
        for (case[1]) |index| try testing.expectEqual(@as(?u8, index), it.next(page));
        try testing.expectEqual(@as(?u8, null), it.next(page));
        var map: PageIndex = .{};
        map.rebuild(page, entries_per_page);
        try testing.expectEqual(@as(?u8, 18), map.find(page, 1, null, "tail", no_chunk, null));
        try testing.expectEqual(@as(?u8, 19), map.find(page, 1, null, "tail_text", no_chunk, null));
        try testing.expectEqual(@as(?u8, null), map.find(page, 1, null, "fake", no_chunk, null));
    }

    // Zero bytes marked written are a stray entry, and marked empty an
    // entry ESP-IDF does not parse: either way stepped over alone.
    var page: [page_size]u8 = @embedFile("nvs_testdata/idf_purged_integer_full.bin").*;
    for ([_]EntryState{ .written, .empty }) |state| {
        page[bitmap_offset] |= @as(u8, @backingInt(state)) << 2;
        try testing.expectEqual(state, entry_state(&page, 1));
        try testing.expectEqual(state == .written, stray_entry(&page, 1));
        var it: Iterator = .{};
        for ([_]u8{ 0, 2, 3, 5, 7, 8, 13, 17, 18, 19 }) |index| try testing.expectEqual(@as(?u8, index), it.next(&page));
        try testing.expectEqual(@as(?u8, null), it.next(&page));
    }
}

test "walk steps over a damaged ESP-IDF header and its payload as ESP-IDF does" {
    // purge_fixture.cpp damaged the 100-byte string's header at entry 8 (its
    // CRC, or its span) and saved the page before, during and after ESP-IDF's
    // Page::load repaired it. Payload entries 9-12 are 'x' text.
    const names = .{ "crc", "span", "repairing", "repaired" };
    inline for (.{ "active", "full" }) |state| {
        inline for (names) |name| {
            const page: *const [page_size]u8 = @embedFile("nvs_testdata/idf_corrupt_" ++ name ++ "_" ++ state ++ ".bin");
            var it: Iterator = .{};
            for ([_]u8{ 0, 1, 2, 3, 5, 7, 13, 17, 18, 19 }) |index| try testing.expectEqual(@as(?u8, index), it.next(page));
            try testing.expectEqual(@as(?u8, null), it.next(page));
            for (8..13) |index| {
                const repaired = comptime std.mem.eql(u8, name, "repaired");
                const zeroed = repaired or (index == 8 and comptime std.mem.eql(u8, name, "repairing"));
                try testing.expectEqual(!zeroed, stray_entry(page, index));
                try testing.expectEqual(if (zeroed) EntryState.erased else .written, entry_state(page, index));
            }
            var map: PageIndex = .{};
            map.rebuild(page, entries_per_page);
            try testing.expectEqual(@as(?u8, null), map.find(page, 1, null, "long_text", no_chunk, null));
            try testing.expectEqual(@as(?u8, 18), map.find(page, 1, null, "tail", no_chunk, null));
        }
    }
}
