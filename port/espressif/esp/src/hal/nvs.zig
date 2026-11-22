//! ESP-IDF NVS v2 store using a partition-relative NOR flash backend.
//! Based on totorototo/microzig@f64390f2.
//! Call from one task only; handles borrow the storage. After a flash I/O
//! error reinitialize the store before further use. Writes are synchronous;
//! commit is a durability barrier, not a multi-key transaction.
const std = @import("std");
const assert = std.debug.assert;
const format = @import("nvs_format.zig");
pub const page_size = format.page_size;
pub const max_key_len = format.max_key_len;
pub const max_str_len = format.max_str_len;
pub const max_pages = format.max_pages;
const entry_size = format.entry_size;
const entries_per_page = format.entries_per_page;
const header_size = format.header_size;
const bitmap_offset = format.bitmap_offset;
const entries_offset = format.entries_offset;
const max_item_data = format.max_item_data;
const max_blob_chunks = format.max_blob_chunks;
const PageState = format.PageState;
const EntryState = format.EntryState;
const type_u8 = format.type_u8;
const type_str = format.type_str;
const type_blob_legacy = format.type_blob_legacy;
const type_blob_data = format.type_blob_data;
const type_blob_index = format.type_blob_index;
const no_chunk = format.no_chunk;
const Item = format.Item;
pub const crc32 = format.crc32;
/// ESP-IDF's `nvs_open_mode_t` (nvs.h).
pub const OpenMode = enum {
    read_only,
    /// Writes and erases mark a replaced or erased value erased; its bytes
    /// stay in flash until its page is reclaimed (`NVS_READWRITE`).
    read_write,
    /// Writes and erases also overwrite a replaced or erased value with
    /// zeros (`NVS_READWRITE_PURGE`).
    read_write_purge,
};

pub const Error = error{
    /// The key, or the namespace when opening read only, doesn't exist.
    NotFound,
    /// The key exists with another type.
    TypeMismatch,
    /// Keys and namespace names are 1 to 15 bytes long, without zeros.
    InvalidName,
    /// The value is longer than the format or the partition allows.
    ValueTooLong,
    /// The destination buffer is smaller than the stored value.
    BufferTooSmall,
    /// No room left, even after reclaiming erased entries.
    NotEnoughSpace,
    /// All 254 namespaces are in use.
    TooManyNamespaces,
    /// The namespace was opened read only.
    ReadOnly,
    /// The stored value doesn't match its checksum.
    Corrupt,
    /// The partition is smaller than 3 pages, larger than `max_pages`, or not a whole number
    /// of pages.
    InvalidPartition,
    /// The partition was written by ESP-IDF older than v3.3 (format version 1).
    UnsupportedVersion,
};

/// A key-value store on `Flash`, which needs, with offsets relative to the start of the partition:
///   - `pub const Error`
///   - `fn read(flash, offset: u32, dest: []u8) Error!void`
///   - `fn write(flash, offset: u32, data: []const u8) Error!void`: clears bits only (NOR flash).
///     Offsets and lengths are multiples of 4.
///   - `fn erase(flash, offset: u32) Error!void`: sets one 4096 byte sector to 0xFF.
pub fn Storage(comptime Flash: type) type {
    return struct {
        const Self = @This();

        /// `Flash` can be a pointer to the type that has the declarations.
        const FlashImpl = switch (@typeInfo(Flash)) {
            .pointer => |pointer| pointer.child,
            else => Flash,
        };

        pub const Err = Error || FlashImpl.Error;

        const PageInfo = struct {
            state: PageState = .uninitialized,
            seq: u32 = 0,
        };

        const Location = struct {
            page: u8,
            index: u8,
        };

        flash: Flash,
        page_count: u8,
        pages: [max_pages]PageInfo = @splat(.{}),
        /// The page items are appended to, and its first unused entry.
        active: ?u8 = null,
        next_free: u8 = 0,
        /// A copy of page `cached`. Every scan goes through it.
        cached: ?u8 = null,
        buf: [page_size]u8 align(4) = undefined,
        /// Reclaim source snapshot, retained while scans reuse `buf` (4 KiB).
        reclaim_buf: [page_size]u8 align(4) = undefined,
        page_index: format.PageIndex = .{},
        index_dirty: bool = true,

        /// Opens the partition, repairing what an interrupted write may have left behind. A blank
        /// partition is valid and empty. `self` is initialized in place because it holds two 4 KiB
        /// page buffers.
        pub fn init(self: *Self, flash: Flash, partition_size: u32) Err!void {
            if (partition_size % page_size != 0) return error.InvalidPartition;
            const page_count = partition_size / page_size;
            if (page_count < 3 or page_count > max_pages) return error.InvalidPartition;

            self.* = .{ .flash = flash, .page_count = @intCast(page_count) };

            for (0..self.page_count) |i| try self.load_header(@intCast(i));

            // The newest page is the one being filled. An older page still
            // marked active was about to be marked full.
            var list: [max_pages]u8 = undefined;
            const pages = self.page_list(&list);
            for (pages, 1..) |page, n| {
                if (self.pages[page].state != .active) continue;
                if (n == pages.len) self.active = page else try self.set_page_state(page, .full);
            }

            // From here on in ESP-IDF's order. `PageManager::load`: every
            // page is repaired as it is loaded, then the item that the last
            // write replaced is erased, then an interrupted reclaim finished.
            var tail_chunk: ?Item = null;
            for (0..self.page_count) |page| switch (self.pages[page].state) {
                .full, .freeing => try self.repair_full(@intCast(page)),
                .active => tail_chunk = try self.repair_active(@intCast(page)),
                else => {},
            };
            try self.erase_replaced();
            try self.finish_reclaim();
            if (self.count_free() == 0) return error.NotEnoughSpace;
            // `Storage::init`.
            try self.erase_stale_blobs(tail_chunk);
        }

        /// Opens a namespace, creating it in read-write mode if it doesn't exist.
        pub fn open(self: *Self, namespace: []const u8, mode: OpenMode) Err!Handle {
            try check_name(namespace);

            if (try self.find(0, type_u8, namespace, no_chunk)) |loc| {
                return .{ .storage = self, .ns = (try self.item_at(loc)).data[0], .mode = mode };
            }
            if (mode == .read_only) return error.NotFound;

            // Take the first index that no namespace entry uses.
            var used: [256]bool = @splat(false);
            var items = self.scan();
            while (try items.next(self)) |loc| {
                const item = self.item_in_buf(loc.index);
                if (item.ns == 0 and item.type == type_u8) used[item.data[0]] = true;
            }
            const ns: u8 = for (1..255) |candidate| {
                if (!used[candidate]) break @intCast(candidate);
            } else return error.TooManyNamespaces;

            var item = make_item(0, type_u8, namespace, no_chunk);
            item.data[0] = ns;
            _ = try self.append(&item, &.{}, &.{});
            return .{ .storage = self, .ns = ns, .mode = mode };
        }

        pub const Handle = struct {
            storage: *Self,
            ns: u8,
            mode: OpenMode,

            /// Reads an integer: `T` is u8, i8, u16, i16, u32, i32, u64 or i64, and must be the
            /// type the value was stored with.
            pub fn get(handle: Handle, comptime T: type, key: []const u8) Err!T {
                const self = handle.storage;
                try check_name(key);
                const loc = try self.find_typed(handle.ns, int_type(T), key);
                const item = try self.item_at(loc);
                return std.mem.readInt(T, item.data[0..@sizeOf(T)], .little);
            }

            /// Stores an integer. Nothing is written if the key already holds this value.
            pub fn set(handle: Handle, comptime T: type, key: []const u8, value: T) Err!void {
                const self = handle.storage;
                try handle.check_writable(key);

                var item = make_item(handle.ns, int_type(T), key, no_chunk);
                std.mem.writeInt(T, item.data[0..@sizeOf(T)], value, .little);

                const maybe_old = try self.find(handle.ns, null, key, no_chunk);
                if (maybe_old) |old| {
                    const old_item = try self.item_at(old);
                    if (old_item.type != item.type) return error.TypeMismatch;
                    if (std.mem.eql(u8, &old_item.data, &item.data)) return;
                }

                const new = try self.append(&item, &.{}, &.{});
                if (try self.find_other(handle.ns, item.type, key, no_chunk, new)) |old| try self.erase_item(old, handle.purges());
            }

            /// Reads a string into `dest` and returns the part of it that was filled.
            pub fn get_str(handle: Handle, key: []const u8, dest: []u8) Err![]u8 {
                const self = handle.storage;
                try check_name(key);
                const loc = try self.find_typed(handle.ns, type_str, key);
                const data = try self.item_data(loc);
                // ESP-IDF stores the terminating zero with the string.
                if (data.len == 0 or data[data.len - 1] != 0 or
                    std.mem.indexOfScalar(u8, data[0 .. data.len - 1], 0) != null) return error.Corrupt;
                const str = data[0 .. data.len - 1];
                if (str.len > dest.len) return error.BufferTooSmall;
                @memcpy(dest[0..str.len], str);
                return dest[0..str.len];
            }

            pub fn set_str(handle: Handle, key: []const u8, value: []const u8) Err!void {
                const self = handle.storage;
                try handle.check_writable(key);
                if (value.len >= max_str_len) return error.ValueTooLong;
                if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidName;

                const maybe_old = try self.find(handle.ns, null, key, no_chunk);
                if (maybe_old) |old| {
                    if ((try self.item_at(old)).type != type_str) return error.TypeMismatch;
                }

                var item = make_item(handle.ns, type_str, key, no_chunk);
                const new = try self.append(&item, value, &.{0});
                // The append may have moved the old item to another page.
                if (try self.find_other(handle.ns, type_str, key, no_chunk, new)) |old| {
                    try self.erase_item(old, handle.purges());
                }
            }

            /// Size of the blob stored under `key`.
            pub fn blob_len(handle: Handle, key: []const u8) Err!usize {
                const self = handle.storage;
                try check_name(key);
                const loc = try self.find_blob(handle.ns, key) orelse return error.NotFound;
                const item = try self.item_at(loc);
                return if (item.type == type_blob_legacy) item.data_len() else item.blob_size();
            }

            /// Reads a blob into `dest` and returns the part of it that was filled.
            /// A key without a blob index is read from a format version 1 blob
            /// (one item of type 0x41), as ESP-IDF v6 still does; `set_blob`
            /// replaces one with a version 2 blob.
            pub fn get_blob(handle: Handle, key: []const u8, dest: []u8) Err![]u8 {
                const self = handle.storage;
                try check_name(key);
                const loc = try self.find_blob(handle.ns, key) orelse return error.NotFound;
                const blob = (try self.item_at(loc)).*;
                if (blob.type == type_blob_legacy) {
                    const data = try self.item_data(loc);
                    if (data.len > dest.len) return error.BufferTooSmall;
                    @memcpy(dest[0..data.len], data);
                    return dest[0..data.len];
                }

                const size = blob.blob_size();
                if (size > dest.len) return error.BufferTooSmall;
                try self.read_chunks(handle.ns, key, blob, dest[0..size]);
                return dest[0..size];
            }

            /// Stores a blob, split into one chunk per page it touches.
            pub fn set_blob(handle: Handle, key: []const u8, value: []const u8) Err!void {
                const self = handle.storage;
                try handle.check_writable(key);
                // One page stays free and each chunk needs an entry for itself.
                if (value.len > @as(usize, self.page_count - 1) * max_item_data) return error.ValueTooLong;

                // As ESP-IDF's `Storage::writeItem`: the new chunks take the
                // other half of the chunk numbers from the blob index the key
                // reads, so that both versions live side by side until the new
                // index is written. Over a version 1 blob they start at 0.
                // An index from another chunk number than 0 or 128, which no
                // ESP-IDF write leaves, is refused there too (`ESP_FAIL`).
                try handle.erase_unserved(key);
                const chunk_start: u8 = if (try self.find(handle.ns, type_blob_index, key, no_chunk)) |old| switch ((try self.item_at(old)).data[5]) {
                    0 => 0x80,
                    0x80 => 0,
                    else => return error.Corrupt,
                } else 0;

                const new = handle.append_blob(key, value, chunk_start) catch |err| {
                    // Propagate cleanup I/O failures as well. On a device error
                    // the caller must reopen; init also removes orphan chunks.
                    try handle.erase_unserved(key);
                    return err;
                };

                // The append may have moved the old items to another page.
                // The new index is read once no older item of the key is in
                // its way; the old chunks go last.
                if (try self.find_other(handle.ns, type_blob_index, key, no_chunk, new)) |old| try self.erase_item(old, handle.purges());
                while (try self.find(handle.ns, type_blob_legacy, key, no_chunk)) |old| try self.erase_item(old, handle.purges());
                try handle.erase_unserved(key);
            }

            /// Erases what the key has beside the blob it reads: every other
            /// blob index, then every chunk the index it reads does not claim.
            /// This changes no read. Only a reset, damage or another writer
            /// leaves such items (the `two_indexes` fixture); a write starts
            /// with this so that its chunks meet no chunk with their numbers,
            /// and a write or an erase ends with it once the index it replaces
            /// is erased: from a reset in between on, the chunks are orphans
            /// that init removes.
            fn erase_unserved(handle: Handle, key: []const u8) Err!void {
                const self = handle.storage;
                var served: ?Location = null;
                var claims: ?Item = null;
                if (try self.find_blob(handle.ns, key)) |loc| {
                    const item = (try self.item_at(loc)).*;
                    if (item.type == type_blob_index) {
                        served = loc;
                        claims = item;
                    }
                }
                while (try self.find_other(handle.ns, type_blob_index, key, no_chunk, served)) |other| try self.erase_item(other, handle.purges());

                var items = self.scan();
                while (try items.next(self)) |loc| {
                    const chunk = self.item_in_buf(loc.index);
                    if (!chunk.is(type_blob_data, handle.ns, key)) continue;
                    if (claims) |blob| if (blob.claims(chunk.chunk_index)) continue;
                    try self.erase_item(loc, handle.purges());
                }
            }

            fn append_blob(handle: Handle, key: []const u8, value: []const u8, chunk_start: u8) Err!Location {
                const self = handle.storage;
                var done: usize = 0;
                var chunk_count: u8 = 0;
                while (done < value.len) {
                    if (chunk_count == max_blob_chunks) return error.ValueTooLong;
                    var room = self.data_room();
                    if (room == 0) {
                        try self.reserve(2);
                        room = self.data_room();
                    }
                    const len = @min(value.len - done, room);
                    var chunk = make_item(handle.ns, type_blob_data, key, chunk_start + chunk_count);
                    _ = try self.append(&chunk, value[done..][0..len], &.{});
                    done += len;
                    chunk_count += 1;
                }
                var index = make_item(handle.ns, type_blob_index, key, no_chunk);
                std.mem.writeInt(u32, index.data[0..4], @intCast(value.len), .little);
                index.data[4] = chunk_count;
                index.data[5] = chunk_start;
                return self.append(&index, &.{}, &.{});
            }

            /// Removes a key, whatever its type. A blob loses every blob index
            /// with its chunks and every version 1 item.
            pub fn erase_key(handle: Handle, key: []const u8) Err!void {
                const self = handle.storage;
                try handle.check_writable(key);
                const purge = handle.purges();
                const loc = try self.find(handle.ns, null, key, no_chunk) orelse return error.NotFound;
                const item_type = (try self.item_at(loc)).type;
                if (item_type != type_blob_index and item_type != type_blob_legacy) return self.erase_item(loc, purge);

                // The items the key does not read first, the one it reads
                // last: a reset in between leaves the blob as it was.
                try handle.erase_unserved(key);
                const served = (try self.find_blob(handle.ns, key)).?;
                while (try self.find_other(handle.ns, type_blob_legacy, key, no_chunk, served)) |legacy| try self.erase_item(legacy, purge);
                try self.erase_item(served, purge);
                try handle.erase_unserved(key);
            }

            /// All writes have already reached flash on successful return.
            /// This barrier does not provide atomic multi-key transactions.
            pub fn commit(handle: Handle) Err!void {
                if (handle.mode == .read_only) return error.ReadOnly;
            }

            fn check_writable(handle: Handle, key: []const u8) Err!void {
                if (handle.mode == .read_only) return error.ReadOnly;
                try check_name(key);
            }

            fn purges(handle: Handle) bool {
                return handle.mode == .read_write_purge;
            }
        };

        // ----- items -----

        fn check_name(name: []const u8) Error!void {
            if (name.len == 0 or name.len > max_key_len) return error.InvalidName;
            if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;
        }

        fn int_type(comptime T: type) u8 {
            const info = @typeInfo(T).int;
            const size: u8 = switch (info.bits) {
                8, 16, 32, 64 => @divExact(info.bits, 8),
                else => @compileError("NVS stores 8, 16, 32 and 64 bit integers"),
            };
            return size | (if (info.signedness == .signed) @as(u8, 0x10) else 0);
        }

        fn make_item(ns: u8, item_type: u8, key: []const u8, chunk_index: u8) Item {
            var item: Item = .{
                .ns = ns,
                .type = item_type,
                .span = 1,
                .chunk_index = chunk_index,
                .crc32 = undefined,
                .key = @splat(0),
                .data = @splat(0xFF),
            };
            @memcpy(item.key[0..key.len], key);
            return item;
        }

        const Iterator = format.Iterator;

        /// The pages in use, oldest first: ESP-IDF's page list
        /// (`PageManager::load` orders it by sequence number).
        fn page_list(self: *const Self, list: *[max_pages]u8) []const u8 {
            var count: usize = 0;
            for (0..self.page_count) |page| {
                const info = self.pages[page];
                if (info.state == .uninitialized) continue;
                var at = count;
                while (at > 0 and self.pages[list[at - 1]].seq > info.seq) : (at -= 1) list[at] = list[at - 1];
                list[at] = @intCast(page);
                count += 1;
            }
            return list[0..count];
        }

        /// A walk of every item this store serves, in ESP-IDF's list order:
        /// pages oldest first, then entry order. The item it returned last
        /// may be erased before the next call.
        const Scan = struct {
            list: [max_pages]u8 = undefined,
            pages: usize = 0,
            at: usize = 0,
            it: ?Iterator = null,

            fn next(items: *Scan, self: *Self) Err!?Location {
                while (items.at < items.pages) : (items.at += 1) {
                    const page = items.list[items.at];
                    try self.load(page);
                    if (items.it == null) items.it = self.walk(page);
                    if (items.it.?.next(&self.buf)) |index| return .{ .page = page, .index = index };
                    items.it = null;
                }
                return null;
            }
        };

        fn scan(self: *const Self) Scan {
            var items: Scan = .{};
            items.pages = self.page_list(&items.list).len;
            return items;
        }

        /// Whether `a` comes before `b` in ESP-IDF's list order.
        fn before(self: *const Self, a: Location, b: Location) bool {
            if (a.page == b.page) return a.index < b.index;
            var list: [max_pages]u8 = undefined;
            for (self.page_list(&list)) |page| {
                if (page == a.page) return true;
                if (page == b.page) return false;
            }
            unreachable; // Both locations belong to pages in use.
        }

        /// The first item on `page` with this exact type and chunk index, or,
        /// without a type, the first one the key is known by: anything but
        /// a blob's data chunks. Optionally ignores the entry `skip`.
        fn find_on_page(self: *Self, page: u8, ns: u8, item_type: ?u8, key: []const u8, chunk_index: u8, skip: ?u8) Err!?u8 {
            try self.load(page);
            self.ensure_index();
            return self.page_index.find(&self.buf, ns, item_type, key, chunk_index, skip);
        }

        /// Finds an item as `find_on_page` does, optionally ignoring the one
        /// at `skip`. Like ESP-IDF's `Storage::findItem`, the first one: on
        /// the oldest page that has one, the first on that page.
        fn find_other(self: *Self, ns: u8, item_type: ?u8, key: []const u8, chunk_index: u8, skip: ?Location) Err!?Location {
            var list: [max_pages]u8 = undefined;
            for (self.page_list(&list)) |page| {
                const skip_index: ?u8 = if (skip) |loc| (if (loc.page == page) loc.index else null) else null;
                if (try self.find_on_page(page, ns, item_type, key, chunk_index, skip_index)) |index| {
                    return .{ .page = page, .index = index };
                }
            }
            return null;
        }

        fn find(self: *Self, ns: u8, item_type: ?u8, key: []const u8, chunk_index: u8) Err!?Location {
            return self.find_other(ns, item_type, key, chunk_index, null);
        }

        /// The blob a key holds, as ESP-IDF's `Storage::getItemDataSize` and
        /// `Storage::readItem` find it: its blob index, or else a version 1
        /// (single item) blob. On each page, oldest first, only the key's
        /// first item that is not a blob chunk counts: `Page::findItem`
        /// answers a type mismatch when it meets another item of the key
        /// first (nvs_page.cpp:1128-1134), and `Storage::findItem` goes on to
        /// the next page. Null if the key has no item, `TypeMismatch` if it
        /// has only items of other types.
        fn find_blob(self: *Self, ns: u8, key: []const u8) Err!?Location {
            var legacy: ?Location = null;
            var other = false;
            var list: [max_pages]u8 = undefined;
            for (self.page_list(&list)) |page| {
                const index = try self.find_on_page(page, ns, null, key, no_chunk, null) orelse continue;
                const loc: Location = .{ .page = page, .index = index };
                switch (self.item_in_buf(index).type) {
                    type_blob_index => return loc,
                    type_blob_legacy => legacy = legacy orelse loc,
                    else => other = true,
                }
            }
            return legacy orelse if (other) error.TypeMismatch else null;
        }

        /// Reads the chunks the blob index `blob` names into `dest`, or only
        /// checks them without it: each one there, by the first copy of its
        /// number (`find`), with a good CRC, adding up to the index's size.
        fn read_chunks(self: *Self, ns: u8, key: []const u8, blob: Item, dest: ?[]u8) Err!void {
            const size = blob.blob_size();
            var done: usize = 0;
            for (0..blob.data[4]) |i| {
                const chunk_index = blob.data[5] +% @as(u8, @intCast(i));
                const chunk_loc = try self.find(ns, type_blob_data, key, chunk_index) orelse return error.Corrupt;
                const data = try self.item_data(chunk_loc);
                if (done + data.len > size) return error.Corrupt;
                if (dest) |buf| @memcpy(buf[done..][0..data.len], data);
                done += data.len;
            }
            if (done != size) return error.Corrupt;
        }

        fn find_typed(self: *Self, ns: u8, item_type: u8, key: []const u8) Err!Location {
            const loc = try self.find(ns, null, key, no_chunk) orelse return error.NotFound;
            if ((try self.item_at(loc)).type != item_type) return error.TypeMismatch;
            return loc;
        }

        fn item_at(self: *Self, loc: Location) Err!*const Item {
            try self.load(loc.page);
            return self.item_in_buf(loc.index);
        }

        /// The data of a string or blob chunk, checked against its CRC. Valid until the next call.
        fn item_data(self: *Self, loc: Location) Err![]const u8 {
            const item = try self.item_at(loc);
            const len = item.data_len();
            if (len > @as(usize, item.span - 1) * entry_size) return error.Corrupt;
            const data = self.buf[entries_offset + (@as(usize, loc.index) + 1) * entry_size ..][0..len];
            if (crc32(0xFFFF_FFFF, data) != item.data_crc()) return error.Corrupt;
            return data;
        }

        /// Bytes of data an item appended now could carry in the active page.
        fn data_room(self: *const Self) usize {
            if (self.active == null) return 0;
            const free = entries_per_page - @as(usize, self.next_free);
            return if (free < 2) 0 else (free - 1) * entry_size;
        }

        /// Appends an item whose data is `data` followed by `suffix`, and returns where it went.
        fn append(self: *Self, item: *Item, data: []const u8, suffix: []const u8) Err!Location {
            const len = data.len + suffix.len;
            if (len > max_item_data) return error.ValueTooLong;
            const span = 1 + (len + entry_size - 1) / entry_size;
            item.span = @intCast(span);

            const has_data = item.type == type_str or item.type == type_blob_data;
            if (has_data) {
                std.mem.writeInt(u16, item.data[0..2], @intCast(len), .little);
                std.mem.writeInt(u16, item.data[2..4], 0xFFFF, .little);
                std.mem.writeInt(u32, item.data[4..8], crc32(crc32(0xFFFF_FFFF, data), suffix), .little);
            }
            item.seal();

            try self.reserve(@intCast(span));
            const page = self.active.?;
            const index = self.next_free;
            try self.load(page);

            // Build the entries in the page copy, then write them in one go.
            const bytes = self.buf[entries_offset + @as(usize, index) * entry_size ..][0 .. span * entry_size];
            @memset(bytes, 0xFF);
            @memcpy(bytes[0..entry_size], std.mem.asBytes(item));
            @memcpy(bytes[entry_size..][0..data.len], data);
            @memcpy(bytes[entry_size + data.len ..][0..suffix.len], suffix);
            errdefer self.cached = null;
            try self.flash.write(page_offset(page) + entries_offset + @as(u32, index) * entry_size, bytes);

            // The item only exists once its entries are marked written. If power is lost before
            // that, `repair_active` discards them.
            try self.set_entry_states(page, index, @intCast(span), .written);
            self.next_free += @intCast(span);
            return .{ .page = page, .index = index };
        }

        /// Erases a live item for a handle: marks its entries erased and,
        /// with `purge`, then zeroes them, as ESP-IDF's
        /// `Page::eraseEntryAndSpan` does with the handle's
        /// `purgeAfterErase` (nvs_handle_simple.cpp): the page is left byte
        /// for byte as ESP-IDF would leave it.
        fn erase_item(self: *Self, loc: Location, purge: bool) Err!void {
            const span = (try self.item_at(loc)).span;
            if (purge) return self.discard_item(loc.page, loc.index, span);
            try self.set_entry_states(loc.page, loc.index, span, .erased);
        }

        // ----- pages -----

        fn page_offset(page: u8) u32 {
            return @as(u32, page) * page_size;
        }

        fn load(self: *Self, page: u8) Err!void {
            if (self.cached == page) return;
            self.cached = null;
            try self.flash.read(page_offset(page), &self.buf);
            self.cached = page;
            self.index_dirty = true;
        }

        fn ensure_index(self: *Self) void {
            if (!self.index_dirty) return;
            self.page_index.rebuild(&self.buf, self.walk(self.cached.?).end);
            self.index_dirty = false;
        }

        /// A walk of `page`: the active page only up to its first free
        /// entry, as ESP-IDF reads it.
        fn walk(self: *const Self, page: u8) Iterator {
            return .{ .end = if (self.active == page) self.next_free else entries_per_page };
        }

        fn item_in_buf(self: *Self, index: usize) *const Item {
            return @ptrCast(self.buf[entries_offset + index * entry_size ..][0..entry_size]);
        }

        fn entry_state(self: *const Self, index: usize) EntryState {
            return format.entry_state(&self.buf, index);
        }

        /// Changes the state of `count` entries of a page, in its copy and in flash.
        /// Publication goes from the first entry (an item's header) to the
        /// last, in one write. Erasure goes the other way, one bitmap word at a
        /// time, as ESP-IDF's `Page::alterEntryRangeState` does: an
        /// interrupted erase leaves the header marked written, so its payload
        /// is never read as headers, here or by ESP-IDF.
        fn set_entry_states(self: *Self, page: u8, first: u8, count: u8, state: EntryState) Err!void {
            try self.load(page);
            self.index_dirty = true;
            errdefer self.cached = null;
            for (first..@as(usize, first) + count) |index| {
                const bytes = self.buf[bitmap_offset + index / 16 * 4 ..][0..4];
                const shift: u5 = @intCast(index % 16 * 2);
                const word = std.mem.readInt(u32, bytes, .little);
                // Only clears bits, like the flash.
                std.mem.writeInt(u32, bytes, word & ~(@as(u32, ~@backingInt(state) & 0b11) << shift), .little);
            }
            const first_word = @as(u32, first) / 16;
            const last_word = (@as(u32, first) + count - 1) / 16;
            if (state == .erased) {
                var word = last_word + 1;
                while (word > first_word) {
                    word -= 1;
                    try self.flash.write(page_offset(page) + bitmap_offset + word * 4, self.buf[bitmap_offset + word * 4 ..][0..4]);
                }
                return;
            }
            const bytes = self.buf[bitmap_offset + first_word * 4 .. bitmap_offset + (last_word + 1) * 4];
            try self.flash.write(page_offset(page) + bitmap_offset + first_word * 4, bytes);
        }

        fn set_page_state(self: *Self, page: u8, state: PageState) Err!void {
            var bytes: [4]u8 align(4) = undefined;
            std.mem.writeInt(u32, &bytes, @backingInt(state), .little);
            try self.flash.write(page_offset(page), &bytes);
            if (self.cached == page) @memcpy(self.buf[0..4], &bytes);
            self.pages[page].state = state;
        }

        fn erase_page(self: *Self, page: u8) Err!void {
            if (self.cached == page) self.cached = null;
            try self.flash.erase(page_offset(page));
            self.pages[page] = .{};
        }

        /// Reads a page header at init. Pages that can't be used as they are get erased.
        fn load_header(self: *Self, page: u8) Err!void {
            try self.load(page);
            if (std.mem.readInt(u32, self.buf[0..4], .little) == @backingInt(PageState.uninitialized)) {
                // An interrupted erase can leave a page that looks free but isn't blank.
                if (!std.mem.allEqual(u8, &self.buf, 0xFF)) try self.erase_page(page);
                return;
            }
            const header = format.Header.decode(self.buf[0..header_size]) catch |err| switch (err) {
                error.Corrupt => return self.erase_page(page),
                error.UnsupportedVersion => return err,
            };
            self.pages[page] = .{ .state = header.state, .seq = header.seq };
        }

        fn count_free(self: *const Self) usize {
            var count: usize = 0;
            for (self.pages[0..self.page_count]) |info| count += @intFromBool(info.state == .uninitialized);
            return count;
        }

        fn first_free(self: *const Self) ?u8 {
            for (self.pages[0..self.page_count], 0..) |info, i| {
                if (info.state == .uninitialized) return @intCast(i);
            }
            return null;
        }

        /// Turns a free page into the active one.
        fn activate(self: *Self, page: u8) Err!void {
            var seq: u32 = 0;
            for (self.pages[0..self.page_count]) |info| {
                if (info.state != .uninitialized) seq = @max(seq, std.math.add(u32, info.seq, 1) catch return error.NotEnoughSpace);
            }

            const header = (format.Header{ .state = .active, .seq = seq }).encode();
            try self.flash.write(page_offset(page), &header);

            if (self.cached == page) self.cached = null;
            self.pages[page] = .{ .state = .active, .seq = seq };
            self.active = page;
            self.next_free = 0;
        }

        /// Makes sure the active page has `span` unused entries, moving on to a new page if not.
        fn reserve(self: *Self, span: u8) Err!void {
            // Each round frees at least one entry or fails, so this ends.
            for (0..@as(usize, self.page_count) + 1) |_| {
                if (self.active != null and entries_per_page - self.next_free >= span) return;
                try self.new_page();
            }
            return error.NotEnoughSpace;
        }

        fn new_page(self: *Self) Err!void {
            if (self.active) |active| {
                try self.set_page_state(active, .full);
                self.active = null;
            }

            if (self.count_free() > 1) return self.activate(self.first_free().?);

            // Only the reserve page is left: reclaim the full page that wastes the most entries.
            var victim: ?u8 = null;
            var victim_live: usize = entries_per_page;
            for (0..self.page_count) |page| {
                if (self.pages[page].state != .full) continue;
                try self.load(@intCast(page));
                var live: usize = 0;
                for (0..entries_per_page) |index| live += @intFromBool(self.entry_state(index) == .written);
                if (live < victim_live) {
                    victim = @intCast(page);
                    victim_live = live;
                }
            }
            const page = victim orelse return error.NotEnoughSpace;

            // Persist recovery intent before consuming the reserve page.
            // A reset after this marker can restart from the intact victim,
            // even if destination activation/copy has not started. See IDF
            // components/nvs_flash/src/nvs_pagemanager.cpp, requestNewPage.
            try self.set_page_state(page, .freeing);
            try self.activate(self.first_free().?);
            try self.copy_and_erase(page);
        }

        /// Copies the live items of a page being freed into the fresh active page, then erases it.
        /// Uses the store's reclaim buffer and one replacement bit per source entry.
        /// Reads the source and each newer page at most once; the destination is not read.
        fn copy_and_erase(self: *Self, from: u8) Err!void {
            const to = self.active.?;
            assert(self.next_free == 0);

            try self.load(from);
            self.reclaim_buf = self.buf;
            const source = &self.reclaim_buf;
            var replaced: std.StaticBitSet(entries_per_page) = .empty;
            var list: [max_pages]u8 = undefined;
            const pages = self.page_list(&list);
            // PageManager::load (v5.5.1 nvs_pagemanager.cpp:75-79)
            // leaves replacements on FREEING pages. Unlike its blind
            // copy (113-118), do not move one after its newer value:
            // Storage::writeItem (nvs_storage.cpp:581-582) would erase
            // only that live value on the next replacement.
            var newer = false;
            for (pages) |page| {
                if (page == from) {
                    newer = true;
                    continue;
                }
                if (!newer or page == to) continue;
                try self.load(page);
                self.ensure_index();
                var it: Iterator = .{};
                while (it.next_published(source)) |index| {
                    if (replaced.isSet(index)) continue;
                    const item = format.item_at(source, index);
                    if (self.page_index.find(&self.buf, item.ns, item.type, item.key_slice(), item.chunk_index, null) != null) replaced.set(index);
                }
            }

            var bitmap: [32]u8 align(4) = @splat(0xFF);
            var count: u8 = 0;
            var it: Iterator = .{};
            while (it.next_published(source)) |index| {
                if (replaced.isSet(index)) continue;
                const item = format.item_at(source, index);
                const span: u8 = if (format.variable_length(item.type)) item.span else 1;
                const bytes = source[entries_offset + @as(usize, index) * entry_size ..][0 .. @as(usize, span) * entry_size];
                try self.flash.write(page_offset(to) + entries_offset + @as(u32, count) * entry_size, bytes);
                for (count..count + span) |entry| {
                    // written = 0b10: clear the low bit of the entry's pair.
                    bitmap[entry / 4] &= ~(@as(u8, 1) << @intCast(entry % 4 * 2));
                }
                count += span;
            }
            // Until this bitmap write, the copies don't count.
            if (count > 0) try self.flash.write(page_offset(to) + bitmap_offset, &bitmap);

            try self.erase_page(from);
            self.next_free = count;
        }

        /// Completes a reclaim that was interrupted, at init.
        fn finish_reclaim(self: *Self) Err!void {
            var list: [max_pages]u8 = undefined;
            const from = for (self.page_list(&list)) |page| {
                if (self.pages[page].state == .freeing) break page;
            } else return;

            // The page being freed is intact until it is erased, and its destination is only ever
            // the fresh page of this reclaim. How far the copy went can't be told reliably (its
            // bitmap write may be half done), so start it again from a blank page.
            if (self.active) |to| {
                try self.erase_page(to);
                try self.activate(to);
            } else {
                try self.activate(self.first_free() orelse return error.NotEnoughSpace);
            }
            try self.copy_and_erase(from);
        }

        /// Repairs the active page at init as ESP-IDF's `Page::mLoadEntryTable`
        /// does, finds its first free entry, and returns its final chunk
        /// so blob cleanup can judge indexes affected by the tail check.
        fn repair_active(self: *Self, page: u8) Err!?Item {
            try self.load(page);
            // ESP-IDF's first free entry is the first one marked empty.
            var next_free: u8 = for (0..entries_per_page) |i| {
                if (self.entry_state(i) == .empty) break @intCast(i);
            } else entries_per_page;
            // An interrupted write may have programmed entries from there on
            // before marking any of them written. ESP-IDF erases and zeroes
            // them one at a time while their first word is programmed. This
            // also goes on while any byte is, and over the whole extent a
            // torn header there claims, so that the next item is written on
            // blank flash: ESP-IDF reads none of these entries either way.
            // The extent goes from its last entry to its header, so a reset
            // in between leaves the header that claims the rest.
            while (next_free < entries_per_page) {
                if (std.mem.allEqual(u8, std.mem.asBytes(self.item_in_buf(next_free)), 0xff)) break;
                const span = format.scan_span(&self.buf, next_free) orelse 1;
                var entry: usize = next_free + span;
                while (entry > next_free) {
                    entry -= 1;
                    try self.discard_stray(page, @intCast(entry));
                }
                next_free += span;
            }

            // Entries before it are repaired in turn (`repair_entry`); an
            // item not marked written in all its entries moves the first free
            // entry past it. ESP-IDF also erases and zeroes an earlier item
            // with the namespace, key and chunk index of a later one, which
            // an interrupted update leaves.
            const end = next_free;
            var items: [entries_per_page]u8 = undefined;
            var item_count: usize = 0;
            var index: u8 = 0;
            while (index < end) {
                const entry = try self.repair_entry(page, index, true);
                defer index += entry.span;
                if (!entry.item) {
                    next_free = @max(next_free, index + entry.span);
                    continue;
                }
                const item = self.item_in_buf(index).*;
                for (items[0..item_count], 0..) |earlier, i| {
                    const old = self.item_in_buf(earlier);
                    if (old.ns != item.ns or old.chunk_index != item.chunk_index or !std.mem.eql(u8, &old.key, &item.key)) continue;
                    try self.discard_item(page, earlier, if (format.variable_length(old.type)) old.span else 1);
                    items[i] = items[item_count - 1];
                    item_count -= 1;
                    break;
                }
                items[item_count] = index;
                item_count += 1;
            }
            // ESP-IDF v5.5.1 nvs_page.cpp:697-709 checks the last item
            // again with CHUNK_ANY, so a final chunk can erase an earlier
            // chunk of the key even when their chunk numbers differ.
            var tail_chunk: ?Item = null;
            if (item_count > 0) {
                const last = items[item_count - 1];
                const tail = self.item_in_buf(last).*;
                if (tail.type == type_blob_data and last + tail.span == end) {
                    tail_chunk = tail;
                    var previous: Iterator = .{ .end = end };
                    while (previous.next_published(&self.buf)) |earlier| {
                        if (earlier >= last) break;
                        const old = self.item_in_buf(earlier).*;
                        if (old.is(type_blob_data, tail.ns, tail.key_slice())) {
                            try self.discard_item(page, earlier, old.span);
                            break;
                        }
                    }
                }
            }
            self.next_free = next_free;
            self.index_dirty = true;
            return tail_chunk;
        }

        /// Repairs a full or freeing page at init as ESP-IDF's
        /// `Page::mLoadEntryTable` does (`repair_entry`).
        fn repair_full(self: *Self, page: u8) Err!void {
            try self.load(page);
            var index: u8 = 0;
            while (index < entries_per_page) index += (try self.repair_entry(page, index, false)).span;
        }

        /// What ESP-IDF's `Page::mLoadEntryTable` does with the entry at
        /// `index` of `page`, the cached page: it erases and zeroes a stray
        /// entry alone (`format.stray_entry`; one marked illegal only on the
        /// active page, elsewhere it is stepped over), and a variable-length
        /// item not marked written in all its entries whole. Returns the
        /// entries to step over and whether an item is left there.
        fn repair_entry(self: *Self, page: u8, index: u8, active: bool) Err!struct { span: u8, item: bool } {
            const state = self.entry_state(index);
            if (format.stray_entry(&self.buf, index)) {
                if (active or state == .written) try self.discard_stray(page, index);
                return .{ .span = 1, .item = false };
            }
            if (state != .written) return .{ .span = 1, .item = false };
            const item = self.item_in_buf(index);
            const span: u8 = if (format.variable_length(item.type)) item.span else 1;
            const published = format.published(&self.buf, index);
            if (!published) try self.discard_item(page, index, span);
            return .{ .span = span, .item = published };
        }

        /// Erases and zeroes a single entry, as ESP-IDF's
        /// `Page::eraseEntryAndSpan` does with `DEFAULT_PURGE_AFTER_ERASE`.
        /// Zeroing first keeps every interrupted state one the next init
        /// picks up again: a written entry stays inconsistent, an empty one
        /// stays programmed.
        fn discard_stray(self: *Self, page: u8, index: u8) Err!void {
            const zeros: [entry_size]u8 align(4) = @splat(0);
            try self.load(page);
            errdefer self.cached = null;
            try self.flash.write(page_offset(page) + entries_offset + @as(u32, index) * entry_size, &zeros);
            @memset(self.buf[entries_offset + @as(usize, index) * entry_size ..][0..entry_size], 0);
            self.index_dirty = true;
            try self.set_entry_states(page, index, 1, .erased);
        }

        /// Erases an item and then zeroes its entries, as ESP-IDF's
        /// `Page::eraseEntryAndSpan` and `Page::purgeEntryRange` do with
        /// `DEFAULT_PURGE_AFTER_ERASE`, which ESP-IDF's own repairs use:
        /// recovery here uses this, and so do a purging handle's erases. A
        /// reset between the bitmap update and the zeroing leaves erased
        /// entries that are never zeroed, which no walk parses.
        fn discard_item(self: *Self, page: u8, index: u8, span: u8) Err!void {
            try self.set_entry_states(page, index, span, .erased);
            const bytes = self.buf[entries_offset + @as(usize, index) * entry_size ..][0 .. @as(usize, span) * entry_size];
            @memset(bytes, 0);
            errdefer self.cached = null;
            try self.flash.write(page_offset(page) + entries_offset + @as(u32, index) * entry_size, bytes);
        }

        /// A new item is written before the old one is erased, so a reset in
        /// between leaves both, the new one the last item of the newest
        /// page. As ESP-IDF's `PageManager::load`, this erases the item it
        /// replaced: on the first older page where an item has its
        /// namespace, key and chunk index, that item if it has its type too
        /// (`Page::findItem`). On its own page `repair_active` already has.
        /// A page being freed is left out of the search, as ESP-IDF leaves
        /// it out. Unlike ESP-IDF, nothing is erased if the newest page is
        /// active while a page is being freed: it is then taken for that
        /// reclaim's unfinished copy, which `finish_reclaim` erases and
        /// writes again. ESP-IDF also erases a version 1 blob for a last
        /// item that is a blob index; that is left to `erase_stale_blobs`,
        /// which erases it only if the index reads.
        fn erase_replaced(self: *Self) Err!void {
            var list: [max_pages]u8 = undefined;
            const pages = self.page_list(&list);
            if (pages.len == 0) return;
            const newest = pages[pages.len - 1];
            const older = pages[0 .. pages.len - 1];
            if (self.active == newest) {
                for (older) |page| if (self.pages[page].state == .freeing) return;
            }
            try self.load(newest);
            var it = self.walk(newest);
            var last: ?u8 = null;
            while (it.next_published(&self.buf)) |index| last = index;
            const new = self.item_in_buf(last orelse return).*;

            for (older) |page| {
                if (self.pages[page].state == .freeing) continue;
                const kind: ?u8 = if (new.type == type_blob_data) type_blob_data else null;
                const index = try self.find_on_page(page, new.ns, kind, new.key_slice(), new.chunk_index, null) orelse continue;
                const old = self.item_in_buf(index);
                if (old.type != new.type) continue;
                return self.discard_item(page, index, if (format.variable_length(old.type)) old.span else 1);
            }
        }

        /// What ESP-IDF's `Storage::init` and its first read do to blobs, with
        /// a difference each way.
        ///   - Beside a version 1 blob, the key's blob indexes that ESP-IDF's
        ///     init counts incomplete are erased (`erase_incomplete_indexes`).
        ///     Then, if the first one left reads (`read_chunks`), the version
        ///     1 blob is erased, which ESP-IDF keeps and never reads again;
        ///     if it does not, every index of the key is, as ESP-IDF's failed
        ///     read does (`Storage::readMultiPageBlob`), and the version 1
        ///     blob is read.
        ///   - An incomplete index of the active page's final chunk key is
        ///     erased, including one whose old chunk the tail check erased.
        ///     Other keys without a version 1 blob keep their indexes.
        ///   - Blob chunks that no index claims are erased
        ///     (`Storage::eraseOrphanDataBlobs`).
        /// Chunks are written before their index and erased after it. Only
        /// ESP-IDF older than v3.3 wrote version 1 blobs, so one is always
        /// older than any index of its key.
        fn erase_stale_blobs(self: *Self, tail_chunk: ?Item) Err!void {
            // Besides legacy keys, judge the final chunk's key. Its old
            // chunk may have been removed on this boot or a previous,
            // interrupted recovery; the old index must then go too.
            var indexes_judged = tail_chunk != null;
            if (indexes_judged) try self.erase_incomplete_indexes(tail_chunk);
            var items = self.scan();
            while (try items.next(self)) |loc| {
                const legacy = self.item_in_buf(loc.index).*;
                if (legacy.type != type_blob_legacy) continue;
                if (!indexes_judged) {
                    try self.erase_incomplete_indexes(null);
                    indexes_judged = true;
                }
                const key = legacy.key_slice();
                const first = try self.find(legacy.ns, type_blob_index, key, no_chunk) orelse continue;
                if (self.read_chunks(legacy.ns, key, (try self.item_at(first)).*, null)) |_| {
                    try self.discard_item(loc.page, loc.index, legacy.span);
                } else |err| switch (err) {
                    error.Corrupt => while (try self.find(legacy.ns, type_blob_index, key, no_chunk)) |index| {
                        try self.discard_item(index.page, index.index, 1);
                    },
                    else => return err,
                }
            }

            // After the indexes: one erased above leaves its chunks orphans.
            items = self.scan();
            while (try items.next(self)) |loc| {
                const chunk = self.item_in_buf(loc.index).*;
                if (chunk.type == type_blob_data and !try self.chunk_owned(&chunk)) try self.discard_item(loc.page, loc.index, chunk.span);
            }
        }

        /// Erases the blob indexes that are not complete (`index_complete`)
        /// beside a version 1 blob or the active page's final chunk.
        /// The last one first: an index's verdict depends only on the indexes before it, which are
        /// all still there when it is judged, as ESP-IDF judges every index
        /// before erasing any.
        fn erase_incomplete_indexes(self: *Self, tail_chunk: ?Item) Err!void {
            var bound: ?Location = null;
            while (true) {
                var last: ?Location = null;
                var items = self.scan();
                while (try items.next(self)) |loc| {
                    if (bound) |end| if (!self.before(loc, end)) break;
                    if (self.item_in_buf(loc.index).type == type_blob_index) last = loc;
                }
                bound = last orelse return;
                const index = (try self.item_at(bound.?)).*;
                const tail_key = if (tail_chunk) |tail| index.is(type_blob_index, tail.ns, tail.key_slice()) else false;
                if (!tail_key and try self.find(index.ns, type_blob_legacy, index.key_slice(), no_chunk) == null) continue;
                if (!try self.index_complete(bound.?)) try self.discard_item(bound.?.page, bound.?.index, 1);
            }
        }

        /// The chunk numbers an index starting at `chunk_start` may own, as
        /// ESP-IDF's `Storage::eraseMismatchedBlobIndexes` takes them: from
        /// its first one to the end of the lower half (0x00-0x7f) if that is
        /// 0, else to the last one (0xfe).
        fn index_range(chunk_start: u8) std.bit_set.Range {
            return .{ .start = chunk_start, .end = if (chunk_start == 0) 0x80 else no_chunk };
        }

        /// Whether the blob index at `loc` has all its chunks, as
        /// `Storage::eraseMismatchedBlobIndexes` counts them: each chunk of
        /// the key is credited to the first index of the key, in list order,
        /// whose range (`index_range`) holds its number, and an index is
        /// complete if it is credited as many chunks as it says, adding up
        /// to its size. Two indexes of one key share a range only in states
        /// no ESP-IDF write leaves. ESP-IDF then erases an incomplete index
        /// by its key and first chunk number, which takes the first index
        /// with that number, complete or not; init here erases the
        /// incomplete one (`legacy_shared_start` fixture).
        fn index_complete(self: *Self, loc: Location) Err!bool {
            const blob = (try self.item_at(loc)).*;
            const own = index_range(blob.data[5]);
            var earlier: std.StaticBitSet(256) = .empty;
            var chunks: usize = 0;
            var size: usize = 0;
            // The indexes before it, then the chunks.
            inline for (.{ type_blob_index, type_blob_data }) |item_type| {
                var items = self.scan();
                while (try items.next(self)) |at| {
                    const item = self.item_in_buf(at.index);
                    if (!item.is(item_type, blob.ns, blob.key_slice())) continue;
                    if (item_type == type_blob_index) {
                        if (!self.before(at, loc)) break;
                        earlier.setRangeValue(index_range(item.data[5]), true);
                    } else if (own.start <= item.chunk_index and item.chunk_index < own.end and !earlier.isSet(item.chunk_index)) {
                        chunks += 1;
                        size += item.data_len();
                    }
                }
            }
            return chunks == blob.data[4] and size == blob.blob_size();
        }

        /// Whether a blob index of the chunk's key claims its chunk number.
        fn chunk_owned(self: *Self, chunk: *const Item) Err!bool {
            var items = self.scan();
            while (try items.next(self)) |loc| {
                const blob = self.item_in_buf(loc.index);
                if (blob.is(type_blob_index, chunk.ns, chunk.key_slice()) and blob.claims(chunk.chunk_index)) return true;
            }
            return false;
        }
    };
}

// ----- tests -----

/// NOR flash in RAM: writes can only clear bits, and it can "lose power" after a number of
/// operations, either between completed operations or halfway through one.
const TestFlash = struct {
    pub const Error = error{PowerLoss};

    mem: []u8,
    /// Operations left before the power fails.
    budget: ?usize = null,
    writes: usize = 0,
    operations: usize = 0,
    page_reads: usize = 0,
    page_reads_by_page: [max_pages]usize = @splat(0),
    /// False models a reset before the next write/erase changes any bits.
    partial_on_failure: bool = true,

    /// Set once the power has failed: nothing reaches the flash after that.
    dead: bool = false,

    fn spend(flash: *TestFlash) bool {
        if (flash.budget) |budget| {
            if (budget == 0) return false;
            flash.budget = budget - 1;
        }
        flash.operations += 1;
        return true;
    }

    fn restore_power(flash: *TestFlash) void {
        flash.budget = null;
        flash.dead = false;
    }

    pub fn read(flash: *TestFlash, offset: u32, dest: []u8) TestFlash.Error!void {
        if (dest.len == page_size) {
            flash.page_reads += 1;
            flash.page_reads_by_page[offset / page_size] += 1;
        }
        @memcpy(dest, flash.mem[offset..][0..dest.len]);
    }

    pub fn write(flash: *TestFlash, offset: u32, data: []const u8) TestFlash.Error!void {
        std.debug.assert(offset % 4 == 0 and data.len % 4 == 0);
        if (flash.dead) return error.PowerLoss;
        const complete = flash.spend();
        flash.dead = !complete;
        if (!complete and !flash.partial_on_failure) return error.PowerLoss;
        // A write cut short has stored the first half of its bytes.
        const len = if (complete) data.len else data.len / 2;
        for (flash.mem[offset..][0..len], data[0..len]) |*dst, src| dst.* &= src;
        flash.writes += 1;
        if (!complete) return error.PowerLoss;
    }

    pub fn erase(flash: *TestFlash, offset: u32) TestFlash.Error!void {
        std.debug.assert(offset % page_size == 0);
        if (flash.dead) return error.PowerLoss;
        const complete = flash.spend();
        flash.dead = !complete;
        if (!complete and !flash.partial_on_failure) return error.PowerLoss;
        // An erase cut short has blanked half of the sector.
        @memset(flash.mem[offset..][0..if (complete) page_size else page_size / 2], 0xFF);
        if (!complete) return error.PowerLoss;
    }
};

const TestStorage = Storage(*TestFlash);

test "reclaim reads each newer page once regardless of source item count" {
    var mem: [7 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("ns", .read_write);
    // A match on an older page must not suppress a source item.
    try append_u32(&store, h.ns, "k11", 99);
    try store.new_page();
    const from = store.active.?;
    for (0..12) |i| {
        var key_buf: [8]u8 = undefined;
        try append_u32(&store, h.ns, try std.fmt.bufPrint(&key_buf, "k{d}", .{i}), @intCast(i));
    }
    const text = "source payload spans several entries and survives the copy";
    try h.set_str("text", text);
    for (0..3) |p| {
        try store.new_page();
        // Leave stale source entries published, as interrupted replacement
        // cleanup can do. Each newer page replaces a different pair.
        for (0..2) |j| {
            const i = p * 2 + j;
            var key_buf: [8]u8 = undefined;
            try append_u32(&store, h.ns, try std.fmt.bufPrint(&key_buf, "k{d}", .{i}), @intCast(100 + i));
        }
    }
    try store.set_page_state(from, .freeing);
    try store.new_page();
    const to = store.active.?;
    store.cached = null;
    flash.page_reads = 0;
    flash.page_reads_by_page = @splat(0);
    try store.copy_and_erase(from);
    // One source read plus three newer-page reads, no destination read.
    // Check each page separately so a repeated read cannot hide a missed one.
    try testing.expectEqual(@as(usize, 4), flash.page_reads);
    for (flash.page_reads_by_page[0..7], 0..) |reads, page| {
        try testing.expectEqual(@as(usize, @intFromBool(page >= from and page < to)), reads);
    }
    for (0..12) |i| {
        var key_buf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "k{d}", .{i});
        const copied = try store.find_on_page(to, h.ns, TestStorage.int_type(u32), key, no_chunk, null);
        try testing.expectEqual(i >= 6, copied != null);
        if (copied) |index| {
            try testing.expectEqual(@as(u32, @intCast(i)), std.mem.readInt(u32, store.item_in_buf(index).data[0..4], .little));
        }
    }
    var buf: [100]u8 = undefined;
    try testing.expectEqualStrings(text, try h.get_str("text", &buf));
}

test "init judges blob indexes in page list order even with equal sequences" {
    inline for (.{ false, true }) |equal_sequences| {
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("ns", .read_write);
        const legacy: [20]u8 = @splat(0x11);
        const chunk: [10]u8 = @splat(0x22);
        _ = try append_legacy(&store, h.ns, "k", &legacy);
        try append_chunk(&store, h.ns, "k", 0, &chunk);
        try append_chunk(&store, h.ns, "k", 1, &chunk);
        // One named chunk, but two credited chunks: this index must go.
        try append_index(&store, h.ns, "k", chunk.len, 1, 0);
        try store.new_page();
        try h.set_blob("m", &chunk);
        try h.set(u32, "later", 7);
        if (equal_sequences) {
            const header = mem[page_size..][0..header_size];
            @memcpy(header[4..8], mem[4..8]);
            std.mem.writeInt(u32, header[28..32], crc32(0xFFFF_FFFF, header[4..28]), .little);
        }
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_index, "k", no_chunk));
        var buf: [20]u8 = undefined;
        try testing.expectEqualSlices(u8, &legacy, try h.get_blob("k", &buf));
        try testing.expectEqualSlices(u8, &chunk, try h.get_blob("m", &buf));
        try testing.expectEqual(@as(u32, 7), try h.get(u32, "later"));
    }
}

test "blob-heavy init page reads stay within the pre-regression cost" {
    var within_limits = true;
    inline for (.{ .{ 6, 20, 7 }, .{ 16, 200, 581 }, .{ 64, 1000, 12571 } }) |case| {
        const pages, const blobs, const limit = case;
        var mem: [pages * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("ns", .read_write);
        for (0..blobs) |i| {
            var key_buf: [15]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "b{d}", .{i});
            try h.set_blob(key, &@as([20]u8, @splat(0x11)));
        }
        flash.page_reads = 0;
        try store.init(&flash, mem.len);
        std.debug.print("init page reads: {d} pages/{d} blobs: {d} (limit {d})\n", .{ pages, blobs, flash.page_reads, limit });
        within_limits = within_limits and flash.page_reads <= limit;
    }
    try testing.expect(within_limits);
}
const testing = std.testing;

fn test_flash(mem: []u8) TestFlash {
    @memset(mem, 0xFF);
    return .{ .mem = mem };
}

test "crc32 matches the ROM's crc32_le" {
    // zlib.crc32(b"123456789", 0xFFFFFFFF) and the standard check value with seed 0.
    try testing.expectEqual(@as(u32, 0xCBF4_3926), crc32(0, "123456789"));
    try testing.expectEqual(@as(u32, 0xD202_D277), crc32(0xFFFF_FFFF, "123456789"));
}

test "integers, strings and blobs round trip and survive a reopen" {
    var mem: [6 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var nvs: TestStorage = undefined;
    try nvs.init(&flash, mem.len);

    const cfg = try nvs.open("config", .read_write);
    try cfg.set(u8, "boot", 7);
    try cfg.set(i32, "offset", -123456);
    try cfg.set(u64, "big", 0x0123_4567_89AB_CDEF);
    try cfg.set_str("ssid", "Wokwi-GUEST");
    var blob: [300]u8 = undefined;
    for (&blob, 0..) |*b, i| b.* = @truncate(i * 7);
    try cfg.set_blob("cal", &blob);

    // A second namespace has its own keys.
    const other = try nvs.open("other", .read_write);
    try other.set(u8, "boot", 99);

    var reopened: TestStorage = undefined;
    try reopened.init(&flash, mem.len);
    const cfg2 = try reopened.open("config", .read_only);
    var buf: [512]u8 = undefined;
    try testing.expectEqual(@as(u8, 7), try cfg2.get(u8, "boot"));
    try testing.expectEqual(@as(i32, -123456), try cfg2.get(i32, "offset"));
    try testing.expectEqual(@as(u64, 0x0123_4567_89AB_CDEF), try cfg2.get(u64, "big"));
    try testing.expectEqualStrings("Wokwi-GUEST", try cfg2.get_str("ssid", &buf));
    try testing.expectEqual(@as(usize, 300), try cfg2.blob_len("cal"));
    try testing.expectEqualSlices(u8, &blob, try cfg2.get_blob("cal", &buf));
    try testing.expectEqual(@as(u8, 99), try (try reopened.open("other", .read_only)).get(u8, "boot"));

    try testing.expectError(error.NotFound, cfg2.get(u8, "missing"));
    try testing.expectError(error.TypeMismatch, cfg2.get(u16, "boot"));
    try testing.expectError(error.ReadOnly, cfg2.set(u8, "boot", 1));
    try testing.expectError(error.NotFound, reopened.open("nope", .read_only));
    try testing.expectError(error.InvalidName, cfg.set(u8, "a_key_that_is_too_long", 1));
    try testing.expectError(error.BufferTooSmall, cfg2.get_str("ssid", buf[0..3]));
}

test "updates replace, erase removes, same value writes nothing" {
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var nvs: TestStorage = undefined;
    try nvs.init(&flash, mem.len);
    const h = try nvs.open("ns", .read_write);

    try h.set(u32, "n", 1);
    const writes = flash.writes;
    try h.set(u32, "n", 1);
    try testing.expectEqual(writes, flash.writes);

    try h.set(u32, "n", 2);
    try testing.expectEqual(@as(u32, 2), try h.get(u32, "n"));
    try testing.expectError(error.TypeMismatch, h.set(u8, "n", 3));
    try testing.expectError(error.TypeMismatch, h.set_str("n", "x"));

    var buf: [64]u8 = undefined;
    try h.set_str("s", "first");
    try h.set_str("s", "second, longer");
    try testing.expectEqualStrings("second, longer", try h.get_str("s", &buf));
    try h.set_str("s", "");
    try testing.expectEqualStrings("", try h.get_str("s", &buf));

    try h.set_blob("b", "one");
    try h.set_blob("b", "two!");
    try h.set_blob("b", "three");
    try testing.expectEqualStrings("three", try h.get_blob("b", &buf));

    try h.erase_key("b");
    try h.erase_key("n");
    try testing.expectError(error.NotFound, h.get_blob("b", &buf));
    try testing.expectError(error.NotFound, h.get(u32, "n"));
    try testing.expectError(error.NotFound, h.erase_key("n"));
}

test "a counter written many times reclaims pages" {
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var nvs: TestStorage = undefined;
    try nvs.init(&flash, mem.len);
    const h = try nvs.open("ns", .read_write);
    try h.set_str("keep", "still here");

    // 3 pages hold 2 x 126 entries: 2000 updates need many reclaims.
    for (0..2000) |i| try h.set(u32, "count", @intCast(i));
    try testing.expectEqual(@as(u32, 1999), try h.get(u32, "count"));

    var reopened: TestStorage = undefined;
    try reopened.init(&flash, mem.len);
    const h2 = try reopened.open("ns", .read_only);
    var buf: [32]u8 = undefined;
    try testing.expectEqual(@as(u32, 1999), try h2.get(u32, "count"));
    try testing.expectEqualStrings("still here", try h2.get_str("keep", &buf));
}

/// Entries marked erased that are all zeros: purged.
fn zeroed_entries(mem: []const u8) usize {
    var count: usize = 0;
    for (0..mem.len / page_size) |page| {
        const image = mem[page * page_size ..][0..page_size];
        for (0..entries_per_page) |index| {
            if (format.entry_state(image, index) != .erased) continue;
            count += @intFromBool(std.mem.allEqual(u8, std.mem.asBytes(format.item_at(image, index)), 0));
        }
    }
    return count;
}

test "a blob larger than a page is split, and the partition can fill up" {
    inline for (.{ OpenMode.read_write, OpenMode.read_write_purge }) |mode| {
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var nvs: TestStorage = undefined;
        try nvs.init(&flash, mem.len);
        const h = try nvs.open("ns", mode);

        var big: [6000]u8 = undefined;
        for (&big, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 8));
        try h.set_blob("big", &big);
        var buf: [6000]u8 = undefined;
        try testing.expectEqualSlices(u8, &big, try h.get_blob("big", &buf));

        // Rewriting it needs both versions for a moment: 12000 bytes don't fit in 3 usable pages
        // with the rest, and the old version must survive the failure. The
        // chunks already written are erased, purged as the handle purges.
        big[0] ^= 0xFF;
        try testing.expectEqual(@as(usize, 0), zeroed_entries(&mem));
        try testing.expectError(error.NotEnoughSpace, h.set_blob("big", &big));
        try testing.expectEqual(mode == .read_write_purge, zeroed_entries(&mem) > 0);
        big[0] ^= 0xFF;
        try testing.expectEqualSlices(u8, &big, try h.get_blob("big", &buf));

        var reopened: TestStorage = undefined;
        try reopened.init(&flash, mem.len);
        try testing.expectEqualSlices(u8, &big, try (try reopened.open("ns", .read_only)).get_blob("big", &buf));

        try testing.expectError(error.ValueTooLong, h.set_blob("huge", &(@as([3 * max_item_data + 1]u8, @splat(0)))));
    }
}

test "power loss at any point leaves the old or the new value" {
    // Runs a workload, cutting the power after every possible number of flash operations, and
    // checks after each cut that the store opens and holds a consistent state.
    inline for (.{ false, true }) |partial| {
        var mem: [3 * page_size]u8 = undefined;

        var cut: usize = 0;
        while (true) : (cut += 1) {
            var flash = test_flash(&mem);
            flash.partial_on_failure = partial;
            var nvs: TestStorage = undefined;
            try nvs.init(&flash, mem.len);
            const h = try nvs.open("ns", .read_write);
            try h.set(u32, "count", 0);
            try h.set_str("name", "old name");
            try h.set_blob("blob", "old blob contents");

            flash.budget = cut;
            const result = workload(h);
            flash.restore_power();
            errdefer std.debug.print("failed with the power cut after {} flash operations\n", .{cut});

            var after: TestStorage = undefined;
            try after.init(&flash, mem.len);
            const h2 = try after.open("ns", .read_write);
            var buf: [64]u8 = undefined;

            const count = try h2.get(u32, "count");
            try testing.expect(count <= 300);
            const name = try h2.get_str("name", &buf);
            try testing.expect(std.mem.eql(u8, name, "old name") or std.mem.eql(u8, name, "new name, longer"));
            const blob = try h2.get_blob("blob", &buf);
            try testing.expect(std.mem.eql(u8, blob, "old blob contents") or std.mem.eql(u8, blob, "new blob"));

            // The store still works after the repair.
            try h2.set(u32, "count", 1000);
            try testing.expectEqual(@as(u32, 1000), try h2.get(u32, "count"));

            if (result) |_| break else |err| try testing.expectEqual(error.PowerLoss, err);
        }
        // The uncut run takes a few thousand operations: make sure the loop covered them.
        try testing.expect(cut > 600);
    }
}

fn workload(h: TestStorage.Handle) !void {
    // Enough counter updates to go through several page reclaims.
    for (1..151) |i| try h.set(u32, "count", @intCast(i));
    try h.set_str("name", "new name, longer");
    try h.set_blob("blob", "new blob");
    for (151..301) |i| try h.set(u32, "count", @intCast(i));
}

test "all integer widths, commit, empty blob and erase persist" {
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("limits", .read_write);
    inline for (.{ u8, u16, u32, u64, i8, i16, i32, i64 }) |T| {
        const name = @typeName(T);
        try h.set(T, name, std.math.maxInt(T));
        try testing.expectEqual(std.math.maxInt(T), try h.get(T, name));
        try h.set(T, name, std.math.minInt(T));
        try testing.expectEqual(std.math.minInt(T), try h.get(T, name));
    }
    try h.set_blob("empty", "");
    try h.commit();
    try store.init(&flash, mem.len);
    const ro = try store.open("limits", .read_only);
    try testing.expectEqual(@as(usize, 0), try ro.blob_len("empty"));
    var buf: [1]u8 = undefined;
    try testing.expectEqualStrings("", try ro.get_blob("empty", &buf));
    try testing.expectError(error.ReadOnly, ro.commit());
    const rw = try store.open("limits", .read_write);
    inline for (.{ u8, u16, u32, u64, i8, i16, i32, i64 }) |T| {
        try testing.expectEqual(std.math.minInt(T), try ro.get(T, @typeName(T)));
        try rw.erase_key(@typeName(T));
    }
    try rw.erase_key("empty");
    try rw.commit();
    try store.init(&flash, mem.len);
    const after = try store.open("limits", .read_only);
    inline for (.{ u8, u16, u32, u64, i8, i16, i32, i64 }) |T| {
        try testing.expectError(error.NotFound, after.get(T, @typeName(T)));
    }
    try testing.expectError(error.NotFound, after.blob_len("empty"));
}

test "ESP-IDF image can be read, updated and reopened" {
    var mem = @embedFile("nvs_testdata/idf.bin").*;
    var flash: TestFlash = .{ .mem = &mem };
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("fixture", .read_write);
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u64, 0xfedcba9876543210), try h.get(u64, "unsigned"));
    try testing.expectEqual(@as(i32, -123456), try h.get(i32, "signed"));
    try testing.expectEqualStrings("ESP-IDF fixture", try h.get_str("message", &buf));
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 127, 128, 254, 255 }, try h.get_blob("payload", &buf));
    try h.set_blob("payload", "updated blob");
    try h.set_str("message", "updated string");
    try h.commit();
    try store.init(&flash, mem.len);
    const after = try store.open("fixture", .read_only);
    try testing.expectEqualStrings("updated blob", try after.get_blob("payload", &buf));
    try testing.expectEqualStrings("updated string", try after.get_str("message", &buf));
    try testing.expectEqual(@as(i32, -123456), try after.get(i32, "signed"));
}

test "full scalar partition reclaims erased space without losing surviving keys" {
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("full", .read_write);
    // Namespace + 251 distinct keys fills both usable pages.
    for (0..251) |n| {
        var key: [15]u8 = undefined;
        try h.set(u16, try std.fmt.bufPrint(&key, "k{d}", .{n}), @intCast(n));
    }
    try testing.expectError(error.NotEnoughSpace, h.set(u16, "overflow", 999));
    try h.erase_key("k0");
    try h.erase_key("k1");
    // k2 is copied during reclaim. The update must erase its new location.
    try h.set(u16, "k2", 999);
    try h.erase_key("k2");
    try h.set(u16, "replacement", 42);
    try h.commit();
    try store.init(&flash, mem.len);
    const after = try store.open("full", .read_only);
    try testing.expectError(error.NotFound, after.get(u16, "k2"));
    try testing.expectEqual(@as(u16, 42), try after.get(u16, "replacement"));
    for (3..251) |n| {
        var key: [15]u8 = undefined;
        try testing.expectEqual(@as(u16, @intCast(n)), try after.get(u16, try std.fmt.bufPrint(&key, "k{d}", .{n})));
    }
}

test "string limits, corrupt payload and invalid geometry" {
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try testing.expectError(error.InvalidPartition, store.init(&flash, 2 * page_size));
    try testing.expectError(error.InvalidPartition, store.init(&flash, mem.len - 1));
    try store.init(&flash, mem.len);
    const h = try store.open("strings", .read_write);
    const long: [max_str_len]u8 = @splat('x');
    try h.set_str("max", long[0 .. max_str_len - 1]);
    try testing.expectError(error.ValueTooLong, h.set_str("too_long", &long));
    try testing.expectError(error.InvalidName, h.set_str("nul", "a\x00b"));
    var dest: [max_str_len]u8 = undefined;
    try testing.expectEqualStrings(long[0 .. max_str_len - 1], try h.get_str("max", &dest));
    const location = (try store.find(h.ns, null, "max", no_chunk)).?;
    mem[@as(usize, location.page) * page_size + entries_offset + (@as(usize, location.index) + 1) * entry_size] ^= 1;
    try store.init(&flash, mem.len);
    try testing.expectError(error.Corrupt, (try store.open("strings", .read_only)).get_str("max", &dest));
}

test "type and payload errors stay distinct from NotFound and a read erases nothing" {
    // ESP-IDF answers these with ESP_ERR_NVS_NOT_FOUND (a type mismatch, a
    // payload failing its CRC) or ESP_FAIL, and erases a damaged item as it
    // reads it. This store keeps TypeMismatch and Corrupt (README table).
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("errors", .read_write);
    var buf: [128]u8 = undefined;
    try h.set(u32, "number", 1);
    try h.set_str("text", "text");
    try h.set_blob("blob", &(@as([100]u8, @splat(0x5a))));
    try h.set_blob("gap", &(@as([100]u8, @splat(0xa5))));
    var no_nul = TestStorage.make_item(h.ns, type_str, "no_nul", no_chunk);
    _ = try store.append(&no_nul, "abc", &.{});

    try testing.expectError(error.TypeMismatch, h.get(u16, "number"));
    try testing.expectError(error.TypeMismatch, h.get(i32, "number"));
    try testing.expectError(error.TypeMismatch, h.get_str("number", &buf));
    try testing.expectError(error.TypeMismatch, h.get_blob("text", &buf));
    try testing.expectError(error.TypeMismatch, h.blob_len("text"));
    try testing.expectError(error.TypeMismatch, h.get_str("blob", &buf));
    try testing.expectError(error.TypeMismatch, h.set_blob("number", "x"));
    try testing.expectError(error.TypeMismatch, h.set(u32, "text", 2));
    try testing.expectError(error.NotFound, h.get(u32, "missing"));
    try testing.expectError(error.NotFound, h.get_blob("missing", &buf));
    try testing.expectError(error.NotFound, store.open("absent", .read_only));

    // A chunk failing its CRC, a missing chunk, chunks longer or shorter
    // than their index says, a string without its NUL and one with another
    // NUL.
    const chunk = (try store.find(h.ns, type_blob_data, "blob", 0)).?;
    mem[@as(usize, chunk.page) * page_size + entries_offset + (@as(usize, chunk.index) + 1) * entry_size] ^= 1;
    try store.erase_item((try store.find(h.ns, type_blob_data, "gap", 0)).?, false);
    var long_chunk = TestStorage.make_item(h.ns, type_blob_data, "long", 0);
    _ = try store.append(&long_chunk, "0123456789", &.{});
    var long_index = TestStorage.make_item(h.ns, type_blob_index, "long", no_chunk);
    std.mem.writeInt(u32, long_index.data[0..4], 5, .little);
    long_index.data[4] = 1;
    long_index.data[5] = 0;
    _ = try store.append(&long_index, &.{}, &.{});
    var short_chunk = TestStorage.make_item(h.ns, type_blob_data, "short", 0);
    _ = try store.append(&short_chunk, "0123456789", &.{});
    var short_index = TestStorage.make_item(h.ns, type_blob_index, "short", no_chunk);
    std.mem.writeInt(u32, short_index.data[0..4], 15, .little);
    short_index.data[4] = 1;
    short_index.data[5] = 0;
    _ = try store.append(&short_index, &.{}, &.{});
    var embedded = TestStorage.make_item(h.ns, type_str, "embedded", no_chunk);
    _ = try store.append(&embedded, "a\x00b", &.{0});
    try store.init(&flash, mem.len);
    const before = mem;
    try testing.expectError(error.Corrupt, h.get_blob("blob", &buf));
    try testing.expectError(error.Corrupt, h.get_blob("gap", &buf));
    try testing.expectError(error.Corrupt, h.get_blob("long", &buf));
    try testing.expectError(error.Corrupt, h.get_blob("short", &buf));
    try testing.expectError(error.Corrupt, h.get_str("no_nul", &buf));
    try testing.expectError(error.Corrupt, h.get_str("embedded", &buf));
    try testing.expectEqualSlices(u8, &before, &mem);
}

test "board workload repeats in minimum partition and preserves unrelated data" {
    // A partition-relative backend surrounded by guard pages, as on a board.
    var mem: [5 * page_size]u8 = @splat(0xa5);
    var flash = test_flash(mem[page_size .. 4 * page_size]);
    var store: TestStorage = undefined;
    try store.init(&flash, 3 * page_size);
    const existing = try store.open("existing", .read_write);
    try existing.set(u32, "keep", 0x12345678);
    var blob: [6000]u8 = undefined;
    for (&blob, 0..) |*byte, i| byte.* = @truncate((i *% 37) ^ (i >> 4) ^ 0xa5);
    var dest: [6000]u8 = undefined;
    for (0..2) |_| {
        const h = try store.open("mz_selftest", .read_write);
        inline for (.{ u8, u16, u32, u64, i8, i16, i32, i64 }) |T| {
            try h.set(T, @typeName(T), std.math.minInt(T));
            try h.set(T, @typeName(T), std.math.maxInt(T));
        }
        try h.set_str("text", "MicroZig NVS");
        try h.set_blob("blob", &blob);
        for (0..300) |i| try h.set(u32, "counter", @intCast(i));
        try h.commit();
        try store.init(&flash, 3 * page_size);
        const reopened = try store.open("mz_selftest", .read_write);
        inline for (.{ u8, u16, u32, u64, i8, i16, i32, i64 }) |T| {
            try testing.expectEqual(std.math.maxInt(T), try reopened.get(T, @typeName(T)));
            try reopened.erase_key(@typeName(T));
        }
        try testing.expectEqualStrings("MicroZig NVS", try reopened.get_str("text", &dest));
        try testing.expectEqualSlices(u8, &blob, try reopened.get_blob("blob", &dest));
        try testing.expectEqual(@as(u32, 299), try reopened.get(u32, "counter"));
        try reopened.erase_key("text");
        try reopened.erase_key("blob");
        try reopened.erase_key("counter");
        try reopened.commit();
        try store.init(&flash, 3 * page_size);
        try testing.expectEqual(@as(u32, 0x12345678), try (try store.open("existing", .read_only)).get(u32, "keep"));
        try testing.expectError(error.NotFound, (try store.open("mz_selftest", .read_only)).blob_len("blob"));
        try testing.expect(std.mem.allEqual(u8, mem[0..page_size], 0xa5));
        try testing.expect(std.mem.allEqual(u8, mem[4 * page_size ..], 0xa5));
    }
}

// Keep live namespace, scalar, string and blob items on the reclaim victim,
// and 126 other live keys on the other full page. Only the reserve page is free.
fn prepare_reclaim(flash: *TestFlash) !u32 {
    var store: TestStorage = undefined;
    try store.init(flash, @intCast(flash.mem.len));
    const h = try store.open("reclaim", .read_write);
    try h.set(u32, "first", 7);
    try h.set_str("text", "survives a reset during page reclaim");
    try h.set_blob("blob", &(@as([70]u8, @splat(0x5a))));
    var scratch: u32 = 0;
    while (store.next_free < entries_per_page) : (scratch += 1) try h.set(u32, "scratch", scratch);
    for (0..entries_per_page) |i| {
        var key: [15]u8 = undefined;
        try h.set(u32, try std.fmt.bufPrint(&key, "k{d}", .{i}), @intCast(i));
    }
    try testing.expectEqual(@as(usize, 1), store.count_free());
    try testing.expectEqual(@as(u8, entries_per_page), store.next_free);
    return scratch - 1;
}

fn check_reclaim_keys(flash: *TestFlash, scratch: u32) !void {
    var store: TestStorage = undefined;
    try store.init(flash, @intCast(flash.mem.len));
    try testing.expectEqual(@as(usize, 1), store.count_free());
    const h = try store.open("reclaim", .read_only);
    try testing.expectEqual(@as(u32, 7), try h.get(u32, "first"));
    try testing.expectEqual(scratch, try h.get(u32, "scratch"));
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("survives a reset during page reclaim", try h.get_str("text", &buf));
    try testing.expectEqualSlices(u8, &(@as([70]u8, @splat(0x5a))), try h.get_blob("blob", &buf));
    for (0..entries_per_page) |i| {
        var key: [15]u8 = undefined;
        try testing.expectEqual(@as(u32, @intCast(i)), try h.get(u32, try std.fmt.bufPrint(&key, "k{d}", .{i})));
    }
}

test "reclaim recovers a reset between every pair of completed flash operations" {
    var seed: [3 * page_size]u8 = undefined;
    var seed_flash = test_flash(&seed);
    const scratch = try prepare_reclaim(&seed_flash);

    // Count the close, freeing marker, activation, individual item copies,
    // bitmap publication and source erase in one uninterrupted reclaim.
    var probe = seed;
    var probe_flash: TestFlash = .{ .mem = &probe };
    var store: TestStorage = undefined;
    try store.init(&probe_flash, probe.len);
    const before = probe_flash.operations;
    try store.new_page();
    const operations = probe_flash.operations - before;
    try testing.expect(operations > 6);

    for (0..operations + 1) |cut| {
        errdefer std.debug.print("reclaim reset after {d} completed operations\n", .{cut});
        var mem = seed;
        var flash: TestFlash = .{ .mem = &mem, .partial_on_failure = false };
        try store.init(&flash, mem.len);
        flash.budget = cut;
        if (cut < operations) {
            try testing.expectError(error.PowerLoss, store.new_page());
        } else try store.new_page();
        flash.restore_power();
        try check_reclaim_keys(&flash, scratch);
    }
}

test "reclaim recovery survives resets between its own completed flash operations" {
    var seed: [3 * page_size]u8 = undefined;
    var seed_flash = test_flash(&seed);
    const scratch = try prepare_reclaim(&seed_flash);
    var store: TestStorage = undefined;
    var probe = seed;
    var probe_flash: TestFlash = .{ .mem = &probe };
    try store.init(&probe_flash, probe.len);
    const before = probe_flash.operations;
    try store.new_page();
    const reclaim_operations = probe_flash.operations - before;

    for (0..reclaim_operations) |first_cut| {
        // Capture every intermediate reclaim state, without changing any bits
        // in the operation at which the reset occurs.
        var interrupted = seed;
        var first_flash: TestFlash = .{ .mem = &interrupted, .partial_on_failure = false };
        try store.init(&first_flash, interrupted.len);
        first_flash.budget = first_cut;
        try testing.expectError(error.PowerLoss, store.new_page());

        // Measure recovery from this particular state, then reset before each
        // of its writes/erases, including erase/reactivation of a destination.
        var recovered = interrupted;
        var recovery_probe: TestFlash = .{ .mem = &recovered };
        try store.init(&recovery_probe, recovered.len);
        const recovery_operations = recovery_probe.operations;
        for (0..recovery_operations + 1) |second_cut| {
            errdefer std.debug.print("reclaim reset after {d}, recovery reset after {d} completed operations\n", .{ first_cut, second_cut });
            var mem = interrupted;
            var flash: TestFlash = .{ .mem = &mem, .partial_on_failure = false, .budget = second_cut };
            if (second_cut < recovery_operations) {
                try testing.expectError(error.PowerLoss, store.init(&flash, mem.len));
            } else try store.init(&flash, mem.len);
            flash.restore_power();
            try check_reclaim_keys(&flash, scratch);
        }
    }
}

test "interrupted blob publication never promotes encoded payload to a key" {
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("opaque", .read_write);
    try h.set(u32, "untouched", 7);
    var fake = TestStorage.make_item(h.ns, TestStorage.int_type(u32), "untouched", no_chunk);
    std.mem.writeInt(u32, fake.data[0..4], 999, .little);
    fake.seal();
    var payload: [256]u8 = @splat(0xff);
    @memcpy(payload[0..entry_size], std.mem.asBytes(&fake));

    // Complete the blob chunk write, then publish only the first half of its
    // bitmap word. Its header and fake payload header are marked written,
    // while the last payload entries remain empty.
    flash.budget = 1;
    try testing.expectError(error.PowerLoss, h.set_blob("blob", &payload));
    flash.restore_power();
    try store.init(&flash, mem.len);
    const after = try store.open("opaque", .read_only);
    try testing.expectEqual(@as(u32, 7), try after.get(u32, "untouched"));
    try testing.expectError(error.NotFound, after.blob_len("blob"));
    try store.init(&flash, mem.len);
    try testing.expectEqual(@as(u32, 7), try (try store.open("opaque", .read_only)).get(u32, "untouched"));
}

test "discard interrupted item spans despite bad CRC, header state or recovery reset" {
    var seed: [3 * page_size]u8 = undefined;
    var seed_flash = test_flash(&seed);
    var store: TestStorage = undefined;
    try store.init(&seed_flash, seed.len);
    const h = try store.open("opaque", .read_write);
    try h.set(u32, "untouched", 7);
    const first = store.next_free;
    var fake = TestStorage.make_item(h.ns, TestStorage.int_type(u32), "untouched", no_chunk);
    std.mem.writeInt(u32, fake.data[0..4], 999, .little);
    fake.seal();
    var payload: [256]u8 = @splat(0xff);
    @memcpy(payload[0..entry_size], std.mem.asBytes(&fake));
    seed_flash.budget = 1;
    try testing.expectError(error.PowerLoss, h.set_blob("blob", &payload));
    const span = format.item_span(seed[0..page_size], first).?;
    // The torn bitmap write published the header, the fake key and the
    // blank payload entries after it, up to `published`.
    const published = 8;
    for (first..published) |entry| try testing.expectEqual(EntryState.written, format.entry_state(seed[0..page_size], entry));
    try testing.expectEqual(EntryState.empty, format.entry_state(seed[0..page_size], published));

    const Damage = union(enum) { state: EntryState, bad_crc: EntryState, span: u8 };
    const damages = [_]Damage{
        .{ .state = .written },   .{ .state = .erased },   .{ .state = .empty },              .{ .state = .illegal },
        .{ .bad_crc = .written }, .{ .bad_crc = .erased }, .{ .bad_crc = .empty },            .{ .bad_crc = .illegal },
        .{ .span = 0 },           .{ .span = 1 },          .{ .span = entries_per_page + 1 },
    };
    for (damages) |damage| {
        var interrupted = seed;
        const header = entries_offset + @as(usize, first) * entry_size;
        const state: EntryState = switch (damage) {
            .state, .bad_crc => |state| state,
            .span => .written,
        };
        const shift: u3 = @intCast(first % 4 * 2);
        const byte = &interrupted[bitmap_offset + first / 4];
        byte.* = (byte.* & ~(@as(u8, 3) << shift)) | (@as(u8, @backingInt(state)) << shift);
        switch (damage) {
            .state => {},
            .bad_crc => interrupted[header + 4] ^= 1,
            .span => |bad_span| interrupted[header + 2] = bad_span,
        }
        // ESP-IDF steps over the header with its span only while it is
        // marked written and consistent; then it erases the whole unpublished
        // item. Marked empty, it is the first free entry, and the entries
        // programmed from there on are erased one by one. Otherwise it is
        // stepped over alone, as ESP-IDF does, and the fake key after it is
        // read as an item that replaces the older copy (this store's own
        // writes and erases never leave such a state).
        const stray = format.stray_entry(interrupted[0..page_size], first);
        try testing.expectEqual(damage != .state and state == .written or state == .illegal, stray);
        const whole = state == .written and damage == .state;
        const served = !whole and state != .empty;
        var probe = interrupted;
        var probe_flash: TestFlash = .{ .mem = &probe };
        try store.init(&probe_flash, probe.len);
        const operations = probe_flash.operations;
        try testing.expect(operations > 0);

        inline for (.{ false, true }) |partial| {
            for (0..operations + 1) |cut| {
                errdefer std.debug.print("{any}: reset after {d} operations, partial {}\n", .{ damage, cut, partial });
                var mem = interrupted;
                var flash: TestFlash = .{ .mem = &mem, .budget = cut, .partial_on_failure = partial };
                if (cut < operations) {
                    try testing.expectError(error.PowerLoss, store.init(&flash, mem.len));
                } else try store.init(&flash, mem.len);
                flash.restore_power();
                try store.init(&flash, mem.len);
                const after = try store.open("opaque", .read_only);
                try testing.expectEqual(@as(u32, if (served) 999 else 7), try after.get(u32, "untouched"));
                try testing.expectError(error.NotFound, after.blob_len("blob"));
                try store.load(0);
                const end = @as(usize, first) + span;
                if (served) {
                    try testing.expectEqual(EntryState.erased, store.entry_state(first));
                    if (stray) try testing.expect(std.mem.allEqual(u8, mem[header..][0..entry_size], 0));
                    try testing.expectEqual(EntryState.written, store.entry_state(first + 1));
                    for (first + 2..published) |entry| try testing.expectEqual(EntryState.erased, store.entry_state(entry));
                    try testing.expectEqual(@as(u8, published), store.next_free);
                } else if (whole) {
                    // ESP-IDF's erase of a range is one bitmap write per
                    // word, high to low; a write cut short can leave the
                    // blank tail of the span empty. It is never read.
                    for (first..published) |entry| try testing.expectEqual(EntryState.erased, store.entry_state(entry));
                    for (published..end) |entry| {
                        const blank = std.mem.allEqual(u8, mem[entries_offset + entry * entry_size ..][0..entry_size], 0xff);
                        try testing.expect(store.entry_state(entry) == .erased or store.entry_state(entry) == .empty and blank);
                    }
                    try testing.expectEqual(if (store.entry_state(end - 1) == .erased) end else published, store.next_free);
                } else {
                    for (first..end) |entry| try testing.expectEqual(EntryState.erased, store.entry_state(entry));
                    try testing.expectEqual(end, store.next_free);
                }
            }
        }
    }
}

/// The ESP-IDF erase+purge fixtures written by nvs_testdata/purge_fixture.cpp:
/// which keys each one erased, and whether its purge stopped after zeroing the
/// erased item's header, leaving the rest of the item erased but not zeroed.
const IdfPurge = struct {
    name: []const u8,
    unsigned: bool = false,
    long_text: bool = false,
    long_blob: bool = false,
    interrupted: bool = false,
};

const idf_purges = [_]IdfPurge{
    .{ .name = "integer", .unsigned = true },
    .{ .name = "string", .long_text = true },
    .{ .name = "string_partial", .long_text = true, .interrupted = true },
    .{ .name = "blob", .long_blob = true },
    .{ .name = "blob_partial", .long_blob = true, .interrupted = true },
    .{ .name = "all", .unsigned = true, .long_text = true, .long_blob = true },
};

/// The 96-byte blob purge_fixture.cpp stores. Its first entry is a CRC-valid
/// string header claiming six entries: read as a header once a purge has
/// zeroed the blob's own, it would cover the two tail keys.
fn idf_long_blob() [96]u8 {
    var blob: [96]u8 = undefined;
    for (&blob, 0..) |*byte, i| byte.* = @truncate(i * 7);
    var fake: Item = .{ .ns = 1, .type = type_str, .span = 6, .chunk_index = no_chunk, .crc32 = undefined, .key = @splat(0), .data = @splat(0xff) };
    @memcpy(fake.key[0..4], "fake");
    std.mem.writeInt(u16, fake.data[0..2], 160, .little);
    fake.seal();
    @memcpy(blob[0..entry_size], std.mem.asBytes(&fake));
    return blob;
}

fn check_idf_purged_values(store: *TestStorage, purge: IdfPurge) !void {
    const h = try store.open("fixture", .read_only);
    var buf: [128]u8 = undefined;
    if (purge.unsigned) {
        try testing.expectError(error.NotFound, h.get(u64, "unsigned"));
    } else try testing.expectEqual(@as(u64, 0xfedcba9876543210), try h.get(u64, "unsigned"));
    try testing.expectEqual(@as(i32, -123456), try h.get(i32, "signed"));
    try testing.expectEqualStrings("ESP-IDF fixture", try h.get_str("message", &buf));
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 127, 128, 254, 255 }, try h.get_blob("payload", &buf));
    if (purge.long_text) {
        try testing.expectError(error.NotFound, h.get_str("long_text", &buf));
    } else try testing.expectEqualStrings(&(@as([100]u8, @splat('x'))), try h.get_str("long_text", &buf));
    if (purge.long_blob) {
        try testing.expectError(error.NotFound, h.get_blob("long_blob", &buf));
    } else try testing.expectEqualSlices(u8, &idf_long_blob(), try h.get_blob("long_blob", &buf));
    try testing.expectError(error.NotFound, h.get_str("fake", &buf));
    try testing.expectEqual(@as(u32, 0x12345678), try h.get(u32, "tail"));
    try testing.expectEqualStrings("after purged items", try h.get_str("tail_text", &buf));
}

test "ESP-IDF zero-purged items on active and full pages hide no other key" {
    inline for (.{ "active", "full" }) |state| {
        inline for (idf_purges) |purge| {
            const image = @embedFile("nvs_testdata/idf_purged_" ++ purge.name ++ "_" ++ state ++ ".bin");
            // The fixture really holds ESP-IDF's purge: erased entries are all
            // zero, except the not yet zeroed rest of an interrupted one.
            var zeroed: usize = 0;
            var remnants: usize = 0;
            for (0..entries_per_page) |index| {
                if (format.entry_state(image, index) != .erased) continue;
                if (std.mem.allEqual(u8, std.mem.asBytes(format.item_at(image, index)), 0)) {
                    zeroed += 1;
                } else remnants += 1;
            }
            try testing.expect(zeroed > 0);
            try testing.expectEqual(purge.interrupted, remnants > 0);

            var mem: [3 * page_size]u8 = @splat(0xff);
            @memcpy(mem[0..page_size], image);
            var flash: TestFlash = .{ .mem = &mem };
            var store: TestStorage = undefined;
            try store.init(&flash, mem.len);
            try check_idf_purged_values(&store, purge);
            // Like ESP-IDF, recovery leaves erased entries as they are, and
            // the first free entry follows the last item.
            try testing.expectEqualSlices(u8, image, mem[0..page_size]);
            if (comptime std.mem.eql(u8, state, "active")) try testing.expectEqual(@as(u8, 21), store.next_free);
            try store.init(&flash, mem.len);
            try check_idf_purged_values(&store, purge);
        }
    }
}

/// Opens an ESP-IDF fixture page, reclaims it into the reserve page and checks
/// that every live key survived.
fn check_idf_page_reclaim(image: *const [page_size]u8, purge: IdfPurge) !void {
    var mem: [3 * page_size]u8 = @splat(0xff);
    @memcpy(mem[0..page_size], image);
    var flash: TestFlash = .{ .mem = &mem };
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    // Seal the fixture page and fill the second page with live keys,
    // so reclaim must copy the fixture's survivors into the reserve.
    try store.new_page();
    const filler = try store.open("filler", .read_write);
    for (0..entries_per_page - 1) |i| {
        var key: [15]u8 = undefined;
        try filler.set(u16, try std.fmt.bufPrint(&key, "k{d}", .{i}), @intCast(i));
    }
    try testing.expectEqual(@as(u8, entries_per_page), store.next_free);
    try store.new_page();
    try testing.expectEqual(PageState.uninitialized, store.pages[0].state);
    try testing.expect(std.mem.allEqual(u8, mem[0..page_size], 0xff));

    try store.init(&flash, mem.len);
    try check_idf_purged_values(&store, purge);
    const after = try store.open("filler", .read_only);
    for (0..entries_per_page - 1) |i| {
        var key: [15]u8 = undefined;
        try testing.expectEqual(@as(u16, @intCast(i)), try after.get(u16, try std.fmt.bufPrint(&key, "k{d}", .{i})));
    }
    const h = try store.open("fixture", .read_write);
    try h.set(u32, "after_reclaim", 99);
    try h.commit();
    try store.init(&flash, mem.len);
    try testing.expectEqual(@as(u32, 99), try (try store.open("fixture", .read_only)).get(u32, "after_reclaim"));
    try check_idf_purged_values(&store, purge);
}

test "an erase leaves the page byte for byte as ESP-IDF's erase, with and without purging" {
    // purge_fixture.cpp erased these keys with `Page::eraseItem`, purging
    // (idf_purged_*, as an `NVS_READWRITE_PURGE` handle does) and not
    // (idf_erased_*, as an `NVS_READWRITE` handle does). Its page before the
    // erases is the damaged-header fixture with the flipped CRC bit flipped
    // back.
    inline for (.{ "active", "full" }) |state| {
        var base: [page_size]u8 = @embedFile("nvs_testdata/idf_corrupt_crc_" ++ state ++ ".bin").*;
        base[entries_offset + 8 * entry_size + 4] ^= 1;
        inline for (idf_purges) |purge| {
            if (purge.interrupted) continue;
            inline for (.{ .{ OpenMode.read_write_purge, "purged" }, .{ OpenMode.read_write, "erased" } }) |mode| {
                const fixture = "idf_" ++ mode[1] ++ "_" ++ purge.name ++ "_" ++ state ++ ".bin";
                errdefer std.debug.print("{s}\n", .{fixture});
                var mem: [3 * page_size]u8 = @splat(0xff);
                @memcpy(mem[0..page_size], &base);
                var flash: TestFlash = .{ .mem = &mem };
                var store: TestStorage = undefined;
                try store.init(&flash, mem.len);
                try testing.expectEqualSlices(u8, &base, mem[0..page_size]);
                const h = try store.open("fixture", mode[0]);
                if (purge.unsigned) try h.erase_key("unsigned");
                if (purge.long_text) try h.erase_key("long_text");
                if (purge.long_blob) try h.erase_key("long_blob");
                try testing.expectEqualSlices(u8, @embedFile("nvs_testdata/" ++ fixture), mem[0..page_size]);
                try store.init(&flash, mem.len);
                try testing.expectEqualSlices(u8, @embedFile("nvs_testdata/" ++ fixture), mem[0..page_size]);
                try check_idf_purged_values(&store, purge);
            }
        }
    }
}

test "ESP-IDF erased but not purged items are read, kept and reclaimed" {
    inline for (.{ "active", "full" }) |state| {
        inline for (idf_purges) |purge| {
            if (purge.interrupted) continue;
            const image = @embedFile("nvs_testdata/idf_erased_" ++ purge.name ++ "_" ++ state ++ ".bin");
            // Erased entries keep their bytes: no entry is zero.
            var erased: usize = 0;
            for (0..entries_per_page) |index| {
                if (format.entry_state(image, index) != .erased) continue;
                erased += 1;
                try testing.expect(!std.mem.allEqual(u8, std.mem.asBytes(format.item_at(image, index)), 0));
            }
            try testing.expect(erased > 0);
            try check_idf_page_reclaim(image, purge);
        }
    }
}

test "reclaim ESP-IDF zero-purged pages without losing live keys" {
    inline for (.{ "active", "full" }) |state| {
        inline for (idf_purges) |purge| {
            try check_idf_page_reclaim(@embedFile("nvs_testdata/idf_purged_" ++ purge.name ++ "_" ++ state ++ ".bin"), purge);
        }
    }
}

/// purge_fixture.cpp's damaged-header pages: the string's header with a
/// flipped CRC bit or a wrong span, ESP-IDF's repair interrupted after it
/// zeroed only that header, and the page once ESP-IDF's repair finished.
const idf_corrupt_names = .{ "crc", "span", "repairing", "repaired" };

test "ESP-IDF damaged headers hide no key and are repaired as ESP-IDF repairs them" {
    inline for (.{ "active", "full" }) |state| {
        const repaired = @embedFile("nvs_testdata/idf_corrupt_repaired_" ++ state ++ ".bin");
        inline for (idf_corrupt_names) |name| {
            errdefer std.debug.print("idf_corrupt_{s}_{s}.bin\n", .{ name, state });
            const image = @embedFile("nvs_testdata/idf_corrupt_" ++ name ++ "_" ++ state ++ ".bin");
            var mem: [3 * page_size]u8 = @splat(0xff);
            @memcpy(mem[0..page_size], image);
            var flash: TestFlash = .{ .mem = &mem };
            var store: TestStorage = undefined;
            try store.init(&flash, mem.len);
            try check_idf_purged_values(&store, .{ .name = name, .long_text = true });
            // Each written entry of the damaged item is erased and zeroed on
            // its own, leaving the bytes ESP-IDF's own repair leaves.
            try testing.expectEqualSlices(u8, repaired, mem[0..page_size]);
            if (comptime std.mem.eql(u8, state, "active")) try testing.expectEqual(@as(u8, 21), store.next_free);
            try store.init(&flash, mem.len);
            try check_idf_purged_values(&store, .{ .name = name, .long_text = true });
            try testing.expectEqualSlices(u8, repaired, mem[0..page_size]);
        }
    }
}

test "reclaim ESP-IDF damaged-header pages without losing live keys" {
    inline for (.{ "active", "full" }) |state| {
        inline for (idf_corrupt_names) |name| {
            try check_idf_page_reclaim(@embedFile("nvs_testdata/idf_corrupt_" ++ name ++ "_" ++ state ++ ".bin"), .{ .name = name, .long_text = true });
        }
    }
}

test "a header ESP-IDF accepts is not discarded, even if it is not served" {
    // ESP-IDF does not check an integer's chunk index; this store does not
    // serve one that is not 0xff. Neither is a reason to erase it.
    var mem = @embedFile("nvs_testdata/idf.bin").*;
    const unsigned: *Item = @ptrCast(mem[entries_offset + entry_size ..][0..entry_size]);
    try testing.expectEqualStrings("unsigned", unsigned.key_slice());
    unsigned.chunk_index = 0;
    unsigned.seal();
    try testing.expect(format.consistent_header(mem[0..page_size], 1));
    try testing.expect(!format.valid_header(mem[0..page_size], 1));
    const before = mem;
    var flash: TestFlash = .{ .mem = &mem };
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    try testing.expectEqualSlices(u8, &before, &mem);
    const h = try store.open("fixture", .read_only);
    try testing.expectError(error.NotFound, h.get(u64, "unsigned"));
    try testing.expectEqual(@as(i32, -123456), try h.get(i32, "signed"));
}

test "a written stray entry on a full page is discarded, an illegal one kept" {
    // A zeroed entry marked written is a stray entry: ESP-IDF would erase it
    // and read on, and so does init here, before reclaim copies the page.
    var image: [page_size]u8 = @embedFile("nvs_testdata/idf_purged_integer_full.bin").*;
    image[bitmap_offset] |= 0b10 << 2;
    try testing.expect(format.stray_entry(&image, 1));
    try check_idf_page_reclaim(&image, .{ .name = "integer", .unsigned = true });

    // ESP-IDF steps over an illegal entry on a full page without erasing it.
    var mem: [3 * page_size]u8 = @splat(0xff);
    @memcpy(mem[0..page_size], @embedFile("nvs_testdata/idf_purged_integer_full.bin"));
    mem[bitmap_offset] |= 0b01 << 2;
    try testing.expectEqual(EntryState.illegal, format.entry_state(mem[0..page_size], 1));
    try testing.expect(format.stray_entry(mem[0..page_size], 1));
    const before = mem[0..page_size].*;
    var flash: TestFlash = .{ .mem = &mem };
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    try testing.expectEqualSlices(u8, &before, mem[0..page_size]);
    try check_idf_purged_values(&store, .{ .name = "integer", .unsigned = true });
    try check_idf_page_reclaim(before[0..page_size], .{ .name = "integer", .unsigned = true });
}

test "a programmed entry marked empty is skipped on a full page and reclaimed" {
    // ESP-IDF's `Page::mLoadEntryTable` reads only entries marked written on
    // a full page: a zeroed entry marked empty is stepped over alone, and
    // reclaim copies every item after it.
    var image: [page_size]u8 = @embedFile("nvs_testdata/idf_purged_integer_full.bin").*;
    image[bitmap_offset] |= 0b11 << 2;
    try testing.expectEqual(EntryState.empty, format.entry_state(&image, 1));
    var mem: [3 * page_size]u8 = @splat(0xff);
    @memcpy(mem[0..page_size], &image);
    var flash: TestFlash = .{ .mem = &mem };
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    try testing.expectEqualSlices(u8, &image, mem[0..page_size]);
    try check_idf_purged_values(&store, .{ .name = "integer", .unsigned = true });
    try check_idf_page_reclaim(&image, .{ .name = "integer", .unsigned = true });
}

test "an interrupted erase never leaves payload marked written behind an erased header" {
    // ESP-IDF's `Page::alterEntryRangeState` (nvs_page.cpp:926-954) erases a
    // range from its last bitmap word to its first, and so does this store:
    // a reset in between leaves the header marked written, and the load
    // erases the rest. Erased first, the header would let ESP-IDF read
    // the payload after it as items.
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("opaque", .read_write);
    try h.set(u32, "untouched", 7);
    for (0..12) |i| {
        var key: [15]u8 = undefined;
        try h.set(u8, try std.fmt.bufPrint(&key, "k{d}", .{i}), @intCast(i));
    }
    // The chunk's header is entry 14 and its payload 15 to 17: the range
    // crosses from the first bitmap word into the second at entry 16.
    try testing.expectEqual(@as(u8, 14), store.next_free);
    var fake = TestStorage.make_item(h.ns, TestStorage.int_type(u32), "untouched", no_chunk);
    std.mem.writeInt(u32, fake.data[0..4], 999, .little);
    fake.seal();
    var payload: [96]u8 = @splat(0x55);
    @memcpy(payload[entry_size..][0..entry_size], std.mem.asBytes(&fake));
    try h.set_blob("blob", &payload);
    const seed = mem;

    inline for (.{ OpenMode.read_write, OpenMode.read_write_purge }) |mode| {
        inline for (.{ false, true }) |partial| {
            // The index's erase (and zeroing), then the chunk's last bitmap
            // word, whole or cut short, and no more.
            mem = seed;
            flash = .{ .mem = &mem };
            try store.init(&flash, mem.len);
            flash.budget = @as(usize, if (partial) 1 else 2) + @intFromBool(mode == .read_write_purge);
            flash.partial_on_failure = partial;
            try testing.expectError(error.PowerLoss, (try store.open("opaque", mode)).erase_key("blob"));
            try testing.expectEqual(EntryState.written, format.entry_state(mem[0..page_size], 14));
            try testing.expectEqual(EntryState.erased, format.entry_state(mem[0..page_size], 16));
            flash.restore_power();
            try store.init(&flash, mem.len);
            const after = try store.open("opaque", .read_only);
            try testing.expectEqual(@as(u32, 7), try after.get(u32, "untouched"));
            try testing.expectError(error.NotFound, after.blob_len("blob"));
            for (14..18) |entry| try testing.expectEqual(EntryState.erased, format.entry_state(mem[0..page_size], entry));
        }
    }
}

test "blank entries marked written or illegal are erased and zeroed as ESP-IDF does" {
    // `Page::mLoadEntryTable`: on an active page, eraseEntryAndSpan erases
    // and zeroes an illegal entry, and one marked written whose header is
    // inconsistent, blank or not; on a full page only the latter.
    inline for (.{ "active", "full" }) |state| {
        inline for (.{ EntryState.written, EntryState.illegal }) |entry_state| {
            errdefer std.debug.print("{s} page, {any}\n", .{ state, entry_state });
            var mem: [3 * page_size]u8 = @splat(0xff);
            @memcpy(mem[0..page_size], @embedFile("nvs_testdata/idf_purged_integer_" ++ state ++ ".bin"));
            // The purged item's entry, blank and marked again.
            @memset(mem[entries_offset + entry_size ..][0..entry_size], 0xff);
            mem[bitmap_offset] = (mem[bitmap_offset] & ~@as(u8, 0b1100)) | @as(u8, @backingInt(entry_state)) << 2;
            var flash: TestFlash = .{ .mem = &mem };
            var store: TestStorage = undefined;
            try store.init(&flash, mem.len);
            const kept = comptime std.mem.eql(u8, state, "full") and entry_state == .illegal;
            try testing.expectEqual(if (kept) entry_state else .erased, format.entry_state(mem[0..page_size], 1));
            try testing.expect(std.mem.allEqual(u8, mem[entries_offset + entry_size ..][0..entry_size], if (kept) 0xff else 0));
            try check_idf_purged_values(&store, .{ .name = "integer", .unsigned = true });
        }
    }
}

/// What ESP-IDF read from an idf_state_*.bin partition state_fixture.cpp
/// wrote, in namespace "fixture".
fn check_idf_state(store: *TestStorage, comptime name: []const u8) !void {
    const h = try store.open("fixture", .read_only);
    var buf: [640]u8 = undefined;
    try testing.expectEqual(@as(u32, 0x0badcafe), try h.get(u32, "before"));
    if (comptime std.mem.eql(u8, name, "torn_entry")) {
        try testing.expectError(error.NotFound, h.get(u32, "torn"));
    } else if (comptime std.mem.eql(u8, name, "torn_string") or std.mem.eql(u8, name, "full_partial")) {
        try testing.expectEqual(@as(u32, 0x5eed), try h.get(u32, "torn"));
        try testing.expectError(error.NotFound, h.get_str("text", &buf));
    } else if (comptime std.mem.startsWith(u8, name, "legacy_blob")) {
        // ESP-IDF v6 still reads a version 1 blob, and so does this store.
        try testing.expectEqual(idf_legacy_first.len, try h.blob_len("legacy"));
        try testing.expectEqualSlices(u8, &idf_legacy_first, try h.get_blob("legacy", &buf));
        try testing.expectError(error.TypeMismatch, h.get(u32, "legacy"));
        try testing.expectError(error.TypeMismatch, h.get_str("legacy", &buf));
        try testing.expectEqual(@as(u32, 0xfeedf00d), try h.get(u32, "after"));
    } else unreachable;
}

/// state_fixture.cpp's blob contents: byte i is i * 7 + seed.
fn idf_state_pattern(comptime len: usize, seed: u8) [len]u8 {
    var data: [len]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @truncate(i *% 7 +% seed);
    return data;
}

test "ESP-IDF interrupted writes load to the bytes ESP-IDF's own load leaves" {
    // An entry or a payload written but not yet marked written, at the first
    // free entry, and an item whose payload is not marked written on
    // a full page: ESP-IDF erases and zeroes them at load. A version 1
    // blob is stepped over with its span, on active and full pages.
    inline for (.{ "torn_entry", "torn_string", "full_partial", "legacy_blob", "legacy_blob_full" }) |name| {
        errdefer std.debug.print("idf_state_{s}.bin\n", .{name});
        var mem: [3 * page_size]u8 = @embedFile("nvs_testdata/idf_state_" ++ name ++ ".bin").*;
        const loaded = @embedFile("nvs_testdata/idf_state_" ++ name ++ "_loaded.bin");
        var flash: TestFlash = .{ .mem = &mem };
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        try testing.expectEqualSlices(u8, loaded, &mem);
        try check_idf_state(&store, name);
        try store.init(&flash, mem.len);
        try testing.expectEqualSlices(u8, loaded, &mem);
        try check_idf_state(&store, name);
    }
}

/// state_fixture.cpp's version 1 blob, and the blob ESP-IDF wrote over it.
const idf_legacy_first = idf_state_pattern(100, 3);
const idf_legacy_second = idf_state_pattern(150, 0x21);

/// What ESP-IDF read from a partition state_fixture.cpp's write_over_legacy
/// made: the two keys around the version 1 blob, and "legacy" holding `blob`
/// or nothing.
fn check_idf_legacy(store: *TestStorage, blob: ?[]const u8) !void {
    const h = try store.open("fixture", .read_only);
    try testing.expectEqual(@as(u32, 0x0badcafe), try h.get(u32, "before"));
    try testing.expectEqual(@as(u32, 0xfeedf00d), try h.get(u32, "after"));
    var buf: [200]u8 = undefined;
    const expected = blob orelse {
        try testing.expectError(error.NotFound, h.blob_len("legacy"));
        try testing.expectError(error.NotFound, h.get_blob("legacy", &buf));
        return;
    };
    try testing.expectEqual(expected.len, try h.blob_len("legacy"));
    try testing.expectEqualSlices(u8, expected, try h.get_blob("legacy", &buf));
    if (expected.len > 0) try testing.expectError(error.BufferTooSmall, h.get_blob("legacy", buf[0 .. expected.len - 1]));
}

test "ESP-IDF's writes over a version 1 blob load to ESP-IDF's bytes and read as ESP-IDF reads them" {
    const cases = .{
        // The new index marked written, the old item not yet erased. On an
        // active page the load erases it as an earlier item with the same
        // key; on the full page before it, `PageManager::load` does.
        .{ "legacy_blob_rewriting", &idf_legacy_second },
        .{ "legacy_blob_full_rewriting", &idf_legacy_second },
        .{ "legacy_blob_rewritten", &idf_legacy_second },
        .{ "legacy_blob_full_rewritten", &idf_legacy_second },
        .{ "legacy_blob_erased", null },
        // ESP-IDF's erase of the version 1 item of legacy_and_index (below).
        .{ "legacy_and_index_erased", &idf_legacy_second },
        // legacy_and_index without the index's chunk: the incomplete index
        // is erased, as `Storage::eraseMismatchedBlobIndexes` erases it,
        // and the version 1 blob read.
        .{ "legacy_and_broken_index", &idf_legacy_first },
        // An index, then a version 1 blob of its key on the active page:
        // the load erases the earlier of the two items, here the index,
        // whatever its type, and then its orphan chunk.
        .{ "index_then_legacy", &idf_legacy_first },
    };
    inline for (cases) |case| {
        errdefer std.debug.print("idf_state_{s}.bin\n", .{case[0]});
        var mem: [3 * page_size]u8 = @embedFile("nvs_testdata/idf_state_" ++ case[0] ++ ".bin").*;
        const loaded = @embedFile("nvs_testdata/idf_state_" ++ case[0] ++ "_loaded.bin");
        var flash: TestFlash = .{ .mem = &mem };
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        try testing.expectEqualSlices(u8, loaded, &mem);
        try check_idf_legacy(&store, case[1]);
        try store.init(&flash, mem.len);
        try testing.expectEqualSlices(u8, loaded, &mem);
        try check_idf_legacy(&store, case[1]);
    }
}

test "writing and erasing a version 1 blob leave the bytes ESP-IDF's Storage leaves" {
    inline for (.{ "legacy_blob", "legacy_blob_full" }) |name| {
        errdefer std.debug.print("idf_state_{s}.bin\n", .{name});
        var mem: [3 * page_size]u8 = @embedFile("nvs_testdata/idf_state_" ++ name ++ ".bin").*;
        var flash: TestFlash = .{ .mem = &mem };
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        // A version 2 blob, chunks from 0, then the old item erased and
        // zeroed: state_fixture.cpp's writes purge.
        try (try store.open("fixture", .read_write_purge)).set_blob("legacy", &idf_legacy_second);
        try testing.expectEqualSlices(u8, @embedFile("nvs_testdata/idf_state_" ++ name ++ "_rewritten.bin"), &mem);
        try store.init(&flash, mem.len);
        try check_idf_legacy(&store, &idf_legacy_second);
    }

    var mem: [3 * page_size]u8 = @embedFile("nvs_testdata/idf_state_legacy_blob.bin").*;
    var flash: TestFlash = .{ .mem = &mem };
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    try (try store.open("fixture", .read_write_purge)).erase_key("legacy");
    try testing.expectEqualSlices(u8, @embedFile("nvs_testdata/idf_state_legacy_blob_erased.bin"), &mem);
    try store.init(&flash, mem.len);
    try check_idf_legacy(&store, null);
}

test "a blob lookup takes a page's first item of the key, as ESP-IDF's Page::findItem does" {
    // An integer before a blob index of the same key on one page, as only
    // ESP-IDF with CONFIG_NVS_LEGACY_DUP_KEYS_COMPATIBILITY writes: ESP-IDF
    // finds a type mismatch on that page and no blob. On a later page than
    // the integer, the index is found.
    inline for (.{ false, true }) |later_page| {
        var mem: [3 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("dup", .read_write);
        try h.set(u32, "key", 1);
        if (later_page) try store.new_page();
        _ = try h.append_blob("key", "blob", 0);
        var buf: [8]u8 = undefined;
        if (later_page) {
            try testing.expectEqualStrings("blob", try h.get_blob("key", &buf));
            try testing.expectEqual(@as(usize, 4), try h.blob_len("key"));
        } else {
            try testing.expectError(error.TypeMismatch, h.get_blob("key", &buf));
            try testing.expectError(error.TypeMismatch, h.blob_len("key"));
            try testing.expectError(error.TypeMismatch, h.set_blob("key", "new"));
        }
        try testing.expectEqual(@as(u32, 1), try h.get(u32, "key"));
    }
}

/// legacy_blob_full with a blob index of "legacy" written on the next page by
/// the store's own append, without the erase of the version 1 item a write
/// does: both versions, the version 1 item on the older page.
fn legacy_and_new_index(mem: *[3 * page_size]u8, flash: *TestFlash, store: *TestStorage, value: []const u8) !TestStorage.Handle {
    mem.* = @embedFile("nvs_testdata/idf_state_legacy_blob_full.bin").*;
    flash.* = .{ .mem = mem };
    try store.init(flash, mem.len);
    const h = try store.open("fixture", .read_write);
    _ = try h.append_blob("legacy", value, 0);
    return h;
}

test "a blob index and a version 1 blob of one key: the index is read, and a write or an erase drops both" {
    var mem: [3 * page_size]u8 = undefined;
    var flash: TestFlash = undefined;
    var store: TestStorage = undefined;
    const third: [40]u8 = @splat(0x33);
    var buf: [200]u8 = undefined;

    var h = try legacy_and_new_index(&mem, &flash, &store, &idf_legacy_second);
    try testing.expectEqualSlices(u8, &idf_legacy_second, try h.get_blob("legacy", &buf));
    try testing.expect(try store.find(h.ns, type_blob_legacy, "legacy", no_chunk) != null);
    try store.init(&flash, mem.len);
    try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
    try check_idf_legacy(&store, &idf_legacy_second);

    h = try legacy_and_new_index(&mem, &flash, &store, &idf_legacy_second);
    try h.set_blob("legacy", &third);
    try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
    try check_idf_legacy(&store, &third);

    h = try legacy_and_new_index(&mem, &flash, &store, &idf_legacy_second);
    try h.erase_key("legacy");
    try check_idf_legacy(&store, null);
    try store.init(&flash, mem.len);
    try check_idf_legacy(&store, null);

    // An erase takes the version 1 item before the index: a reset in
    // between leaves the index's blob, never the version 1 one.
    inline for (.{ false, true }) |partial| {
        var cut: usize = 0;
        while (true) : (cut += 1) {
            errdefer std.debug.print("reset after {d} operations, partial {}\n", .{ cut, partial });
            h = try legacy_and_new_index(&mem, &flash, &store, &idf_legacy_second);
            flash.partial_on_failure = partial;
            flash.budget = cut;
            const result = h.erase_key("legacy");
            flash.restore_power();
            try store.init(&flash, mem.len);
            const read: ?[]const u8 = (try store.open("fixture", .read_only)).get_blob("legacy", &buf) catch |err| switch (err) {
                error.NotFound => null,
                else => return err,
            };
            if (read) |value| try testing.expectEqualSlices(u8, &idf_legacy_second, value);
            if (result) |_| {
                try testing.expectEqual(@as(?[]const u8, null), read);
                break;
            } else |err| try testing.expectEqual(error.PowerLoss, err);
        }
    }
}

test "a version 1 blob next to a complete blob index of its key is erased at init, unlike ESP-IDF" {
    // legacy_and_index holds both versions, the version 1 item on the older
    // page. ESP-IDF's load keeps both and reads the index. A reclaim of that
    // page then copies the version 1 item after the index, where ESP-IDF's
    // erase or rewrite of the key takes the index and leaves the version 1
    // item, whose value the key then reads, after the next boot too. Init
    // here erases it, leaving the bytes of ESP-IDF's own erase of it, so
    // no reclaim after an init meets both.
    var mem: [3 * page_size]u8 = @embedFile("nvs_testdata/idf_state_legacy_and_index.bin").*;
    var flash: TestFlash = .{ .mem = &mem };
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    try testing.expectEqualSlices(u8, @embedFile("nvs_testdata/idf_state_legacy_and_index_erased.bin"), &mem);
    try check_idf_legacy(&store, &idf_legacy_second);

    // Fill page 1 with distinct keys until page 0 is reclaimed, then write
    // over the key, and from the same state erase it.
    const h = try store.open("fixture", .read_write);
    var name: [8]u8 = undefined;
    var keys: u32 = 0;
    while (store.pages[0].state != .uninitialized) : (keys += 1) {
        try h.set(u32, try std.fmt.bufPrint(&name, "k{d}", .{keys}), keys);
    }
    try testing.expectEqual(@as(u32, 119), keys);
    try check_idf_legacy(&store, &idf_legacy_second);
    const reclaimed = mem;
    const third: [40]u8 = @splat(0x33);
    try h.set_blob("legacy", &third);
    try check_idf_legacy(&store, &third);
    try store.init(&flash, mem.len);
    try check_idf_legacy(&store, &third);

    mem = reclaimed;
    try store.init(&flash, mem.len);
    try h.erase_key("legacy");
    try check_idf_legacy(&store, null);
    try store.init(&flash, mem.len);
    try check_idf_legacy(&store, null);
    try testing.expectError(error.NotFound, h.erase_key("legacy"));
}

test "a reset anywhere in a write over or an erase of a version 1 blob leaves the old or the new value" {
    inline for (.{ "legacy_blob", "legacy_blob_full" }) |name| {
        inline for (.{ false, true }) |erase| {
            inline for (.{ OpenMode.read_write, OpenMode.read_write_purge }) |mode| {
                inline for (.{ false, true }) |partial| {
                    var cut: usize = 0;
                    while (true) : (cut += 1) {
                        errdefer std.debug.print("idf_state_{s}.bin, erase {}, {s}, reset after {d} operations, partial {}\n", .{ name, erase, @tagName(mode), cut, partial });
                        var mem: [3 * page_size]u8 = @embedFile("nvs_testdata/idf_state_" ++ name ++ ".bin").*;
                        var flash: TestFlash = .{ .mem = &mem, .partial_on_failure = partial };
                        var store: TestStorage = undefined;
                        try store.init(&flash, mem.len);
                        const h = try store.open("fixture", mode);
                        flash.budget = cut;
                        const result = if (erase) h.erase_key("legacy") else h.set_blob("legacy", &idf_legacy_second);
                        flash.restore_power();
                        const new: ?[]const u8 = if (erase) null else &idf_legacy_second;

                        try store.init(&flash, mem.len);
                        const after = try store.open("fixture", .read_only);
                        var buf: [200]u8 = undefined;
                        const read: ?[]const u8 = after.get_blob("legacy", &buf) catch |err| switch (err) {
                            error.NotFound => null,
                            else => return err,
                        };
                        const kept_old = read != null and std.mem.eql(u8, read.?, &idf_legacy_first);
                        const took_new = if (new) |n| read != null and std.mem.eql(u8, read.?, n) else read == null;
                        try testing.expect(kept_old or took_new);
                        if (result) |_| try testing.expect(took_new) else |err| try testing.expectEqual(error.PowerLoss, err);
                        // Once the new value is read, the version 1 item is gone.
                        if (took_new) try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(after.ns, type_blob_legacy, "legacy", no_chunk));
                        try check_idf_legacy(&store, if (kept_old) &idf_legacy_first else new);
                        try store.init(&flash, mem.len);
                        try check_idf_legacy(&store, if (kept_old) &idf_legacy_first else new);
                        if (result) |_| break else |_| {}
                    }
                    // An erase is a bitmap write and, purging, a zeroing; a
                    // write over it a chunk and its index, each data then
                    // bitmap, and that erase.
                    const erase_ops: usize = if (mode == .read_write_purge) 2 else 1;
                    try testing.expect(cut >= if (erase) erase_ops else 4 + erase_ops);
                }
            }
        }
    }
}

test "a blob index is complete with its chunk on another page, and init then erases the version 1 blob" {
    // The version 1 blob on page 0, the chunk on page 1, the index on
    // page 2: `Storage::eraseMismatchedBlobIndexes` counts the chunks over
    // every page.
    var mem: [4 * page_size]u8 = @splat(0xff);
    mem[0 .. 3 * page_size].* = @embedFile("nvs_testdata/idf_state_legacy_blob_full.bin").*;
    var flash: TestFlash = .{ .mem = &mem };
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("fixture", .read_write);
    var chunk = TestStorage.make_item(h.ns, type_blob_data, "legacy", 0);
    const chunk_loc = try store.append(&chunk, &idf_legacy_second, &.{});
    try store.new_page();
    var index = TestStorage.make_item(h.ns, type_blob_index, "legacy", no_chunk);
    std.mem.writeInt(u32, index.data[0..4], idf_legacy_second.len, .little);
    index.data[4] = 1;
    index.data[5] = 0;
    const index_loc = try store.append(&index, &.{}, &.{});
    try h.set(u32, "later", 7);
    try testing.expect(chunk_loc.page != index_loc.page);
    try store.init(&flash, mem.len);
    try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
    try check_idf_legacy(&store, &idf_legacy_second);
}

test "two blob indexes on different pages: the one on the oldest page is read" {
    // ESP-IDF's `Storage::findItem` returns the first match in its page list,
    // which `PageManager::load` sorts by sequence number. Here an old
    // index survived on page 0 and a new one on page 1.
    var mem: [3 * page_size]u8 = @embedFile("nvs_testdata/idf_state_two_indexes.bin").*;
    try testing.expectEqualSlices(u8, @embedFile("nvs_testdata/idf_state_two_indexes_loaded.bin"), &mem);
    var flash: TestFlash = .{ .mem = &mem };
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    try testing.expectEqualSlices(u8, @embedFile("nvs_testdata/idf_state_two_indexes_loaded.bin"), &mem);
    const h = try store.open("fixture", .read_only);
    var buf: [200]u8 = undefined;
    const first = idf_state_pattern(100, 0);
    try testing.expectEqual(first.len, try h.blob_len("big"));
    try testing.expectEqualSlices(u8, &first, try h.get_blob("big", &buf));
    try testing.expectEqual(@as(u32, 7), try h.get(u32, "later"));
}

/// The blob `key` of namespace "fixture" holds, or null.
fn read_fixture_blob(store: *TestStorage, key: []const u8, buf: []u8) !?[]const u8 {
    return (try store.open("fixture", .read_only)).get_blob(key, buf) catch |err| switch (err) {
        error.NotFound => null,
        else => return err,
    };
}

/// Whether `a` and `b` are both null or hold the same bytes.
fn same_blob(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Checks that `key` has `index` as its only blob index, or none, and only
/// the chunks that index claims.
fn check_only_blob(store: *TestStorage, ns: u8, key: []const u8, index: ?Item) !void {
    const first = try store.find(ns, type_blob_index, key, no_chunk);
    try testing.expectEqual(index == null, first == null);
    if (first) |loc| try testing.expectEqual(@as(?TestStorage.Location, null), try store.find_other(ns, type_blob_index, key, no_chunk, loc));
    for (0..256) |chunk| {
        const owned = if (index) |blob| @as(u8, @intCast(chunk)) -% blob.data[5] < blob.data[4] else false;
        try testing.expectEqual(owned, try store.find(ns, type_blob_data, key, @intCast(chunk)) != null);
    }
}

test "a write or an erase of a key with two blob indexes takes both, reset anywhere" {
    // idf_state_two_indexes: the index read on page 0 (chunks from 0), and
    // a newer one on page 1 (chunks from 128). The index not read goes
    // first, so the new chunks take its chunk numbers without a collision.
    const first = idf_state_pattern(100, 0);
    const third: [40]u8 = @splat(0x33);
    inline for (.{ OpenMode.read_write, OpenMode.read_write_purge }) |mode| {
        inline for (.{ false, true }) |erase| {
            inline for (.{ false, true }) |partial| {
                var cut: usize = 0;
                while (true) : (cut += 1) {
                    errdefer std.debug.print("{s}, erase {}, reset after {d} operations, partial {}\n", .{ @tagName(mode), erase, cut, partial });
                    var mem: [3 * page_size]u8 = @embedFile("nvs_testdata/idf_state_two_indexes.bin").*;
                    var flash: TestFlash = .{ .mem = &mem, .partial_on_failure = partial };
                    var store: TestStorage = undefined;
                    try store.init(&flash, mem.len);
                    const h = try store.open("fixture", mode);
                    var buf: [200]u8 = undefined;
                    flash.budget = cut;
                    const result = if (erase) h.erase_key("big") else h.set_blob("big", &third);
                    flash.restore_power();
                    const new: ?[]const u8 = if (erase) null else &third;
                    if (result) |_| {
                        try testing.expect(same_blob(new, try read_fixture_blob(&store, "big", &buf)));
                        const index: ?Item = if (try store.find(h.ns, type_blob_index, "big", no_chunk)) |loc| (try store.item_at(loc)).* else null;
                        try testing.expectEqual(erase, index == null);
                        try check_only_blob(&store, h.ns, "big", index);
                    } else |err| try testing.expectEqual(error.PowerLoss, err);

                    try store.init(&flash, mem.len);
                    const read = try read_fixture_blob(&store, "big", &buf);
                    try testing.expect(same_blob(read, &first) or same_blob(read, new));
                    if (result) |_| try testing.expect(same_blob(read, new)) else |_| {}
                    try testing.expectEqual(@as(u32, 7), try (try store.open("fixture", .read_only)).get(u32, "later"));
                    try store.init(&flash, mem.len);
                    try testing.expect(same_blob(read, try read_fixture_blob(&store, "big", &buf)));
                    if (result) |_| break else |_| {}
                }
            }
        }
    }
}

test "a write or an erase over two blob indexes that claim the same chunk keeps the read one's chunk until its turn, reset anywhere" {
    // The index read, on page 0, holds 100 bytes in chunk 0; a stale one on
    // page 1 claims chunk 0 too, for 60 bytes. Erasing the stale index must
    // not take the chunk the read one still needs.
    const first = idf_state_pattern(100, 0);
    const third: [40]u8 = @splat(0x33);
    inline for (.{ OpenMode.read_write, OpenMode.read_write_purge }) |mode| {
        inline for (.{ false, true }) |erase| {
            inline for (.{ false, true }) |partial| {
                var cut: usize = 0;
                while (true) : (cut += 1) {
                    errdefer std.debug.print("{s}, erase {}, reset after {d} operations, partial {}\n", .{ @tagName(mode), erase, cut, partial });
                    var mem: [3 * page_size]u8 = undefined;
                    var flash = test_flash(&mem);
                    var store: TestStorage = undefined;
                    try store.init(&flash, mem.len);
                    const h = try store.open("fixture", mode);
                    try h.set_blob("big", &first);
                    try store.new_page();
                    var stale = TestStorage.make_item(h.ns, type_blob_index, "big", no_chunk);
                    std.mem.writeInt(u32, stale.data[0..4], 60, .little);
                    stale.data[4] = 1;
                    stale.data[5] = 0;
                    _ = try store.append(&stale, &.{}, &.{});
                    try h.set(u32, "later", 7);
                    var buf: [200]u8 = undefined;
                    try testing.expectEqualSlices(u8, &first, try h.get_blob("big", &buf));
                    flash.partial_on_failure = partial;
                    flash.budget = cut;
                    const result = if (erase) h.erase_key("big") else h.set_blob("big", &third);
                    flash.restore_power();
                    const new: ?[]const u8 = if (erase) null else &third;
                    if (result) |_| {
                        try testing.expect(same_blob(new, try read_fixture_blob(&store, "big", &buf)));
                        const index: ?Item = if (try store.find(h.ns, type_blob_index, "big", no_chunk)) |loc| (try store.item_at(loc)).* else null;
                        try check_only_blob(&store, h.ns, "big", index);
                    } else |err| try testing.expectEqual(error.PowerLoss, err);

                    try store.init(&flash, mem.len);
                    const read = try read_fixture_blob(&store, "big", &buf);
                    try testing.expect(same_blob(read, &first) or same_blob(read, new));
                    if (result) |_| try testing.expect(same_blob(read, new)) else |_| {}
                    try testing.expectEqual(@as(u32, 7), try (try store.open("fixture", .read_only)).get(u32, "later"));
                    if (result) |_| break else |_| {}
                }
            }
        }
    }
}

test "two blob indexes, each with its own copy of chunk 0: a write or an erase takes both copies" {
    // The index read, on page 0, holds 100 bytes in chunk 0; a stale one on
    // page 1 claims 60 bytes in another chunk 0 after it. The stale index
    // goes first and leaves chunk 0 to the read one; erasing that one must
    // take both copies, or the next write's chunk 0 is read from the stale
    // copy on the older page.
    const first = idf_state_pattern(100, 0);
    const stale_value: [60]u8 = @splat(0x22);
    const third: [40]u8 = @splat(0x33);
    const fourth: [60]u8 = @splat(0x44);
    inline for (.{ OpenMode.read_write, OpenMode.read_write_purge }) |mode| {
        inline for (.{ false, true }) |erase| {
            inline for (.{ false, true }) |reinit| {
                errdefer std.debug.print("{s}, erase {}, init between {}\n", .{ @tagName(mode), erase, reinit });
                var mem: [4 * page_size]u8 = undefined;
                var flash = test_flash(&mem);
                var store: TestStorage = undefined;
                try store.init(&flash, mem.len);
                const h = try store.open("fixture", mode);
                try h.set_blob("big", &first);
                try store.new_page();
                _ = try h.append_blob("big", &stale_value, 0);
                try h.set(u32, "later", 7);
                try store.init(&flash, mem.len);
                var buf: [200]u8 = undefined;
                try testing.expectEqualSlices(u8, &first, try h.get_blob("big", &buf));

                if (erase) try h.erase_key("big") else try h.set_blob("big", &third);
                const index: ?Item = if (try store.find(h.ns, type_blob_index, "big", no_chunk)) |loc| (try store.item_at(loc)).* else null;
                try testing.expectEqual(erase, index == null);
                try check_only_blob(&store, h.ns, "big", index);
                if (reinit) try store.init(&flash, mem.len);
                try h.set_blob("big", &fourth);
                try testing.expectEqualSlices(u8, &fourth, try h.get_blob("big", &buf));
                try store.init(&flash, mem.len);
                try testing.expectEqualSlices(u8, &fourth, try h.get_blob("big", &buf));
                try testing.expectEqual(@as(u32, 7), try h.get(u32, "later"));
            }
        }
    }
}

/// Appends blob chunk `chunk` of `key`, holding `value`, without an index.
fn append_chunk(store: *TestStorage, ns: u8, key: []const u8, chunk: u8, value: []const u8) !void {
    var item = TestStorage.make_item(ns, type_blob_data, key, chunk);
    _ = try store.append(&item, value, &.{});
}

/// Appends a blob index of `key` that names `count` chunks from `start`,
/// adding up to `size` bytes, whichever chunks are there.
fn append_index(store: *TestStorage, ns: u8, key: []const u8, size: u32, count: u8, start: u8) !void {
    var item = TestStorage.make_item(ns, type_blob_index, key, no_chunk);
    std.mem.writeInt(u32, item.data[0..4], size, .little);
    item.data[4] = count;
    item.data[5] = start;
    _ = try store.append(&item, &.{}, &.{});
}

/// Appends a version 1 blob of "legacy" and starts a new page: on the
/// active page, a later item of the key (an index, another version 1 blob)
/// would erase it at init, as ESP-IDF's `Page::mLoadEntryTable` does.
fn append_legacy_page(store: *TestStorage, ns: u8, value: []const u8) !void {
    _ = try append_legacy(store, ns, "legacy", value);
    try store.new_page();
}

/// Appends a format version 1 blob, which this store never writes itself.
fn append_legacy(store: *TestStorage, ns: u8, key: []const u8, value: []const u8) !TestStorage.Location {
    var item = TestStorage.make_item(ns, type_blob_legacy, key, no_chunk);
    std.mem.writeInt(u16, item.data[0..2], @intCast(value.len), .little);
    std.mem.writeInt(u16, item.data[2..4], 0xFFFF, .little);
    std.mem.writeInt(u32, item.data[4..8], crc32(0xFFFF_FFFF, value), .little);
    return store.append(&item, value, &.{});
}

test "init keeps a version 1 blob beside an incomplete blob index and erases the index, reset anywhere" {
    // As legacy_and_broken_index, whose chunk is missing, but the chunk is
    // there and the index claims a byte more than it holds:
    // `Storage::eraseMismatchedBlobIndexes` erases such an index too.
    // Or it holds the bytes but claims two chunks.
    inline for (.{ .{ idf_legacy_second.len + 1, 1 }, .{ idf_legacy_second.len, 2 } }) |claim| {
        errdefer std.debug.print("index of {d} bytes in {d} chunks\n", .{ claim[0], claim[1] });
        var seed: [3 * page_size]u8 = @embedFile("nvs_testdata/idf_state_legacy_blob_full.bin").*;
        var seed_flash: TestFlash = .{ .mem = &seed };
        var store: TestStorage = undefined;
        try store.init(&seed_flash, seed.len);
        const h = try store.open("fixture", .read_write);
        var chunk = TestStorage.make_item(h.ns, type_blob_data, "legacy", 0);
        _ = try store.append(&chunk, &idf_legacy_second, &.{});
        var index = TestStorage.make_item(h.ns, type_blob_index, "legacy", no_chunk);
        std.mem.writeInt(u32, index.data[0..4], claim[0], .little);
        index.data[4] = claim[1];
        index.data[5] = 0;
        _ = try store.append(&index, &.{}, &.{});
        try h.set(u32, "later", 7);

        var probe = seed;
        var probe_flash: TestFlash = .{ .mem = &probe };
        try store.init(&probe_flash, probe.len);
        const operations = probe_flash.operations;
        // The index's and the chunk's erase, each bitmap writes and zeros.
        try testing.expect(operations >= 4);
        inline for (.{ false, true }) |partial| {
            for (0..operations + 1) |cut| {
                errdefer std.debug.print("init reset after {d} operations, partial {}\n", .{ cut, partial });
                var mem = seed;
                var flash: TestFlash = .{ .mem = &mem, .budget = cut, .partial_on_failure = partial };
                if (cut < operations) {
                    try testing.expectError(error.PowerLoss, store.init(&flash, mem.len));
                } else try store.init(&flash, mem.len);
                flash.restore_power();
                try store.init(&flash, mem.len);
                try check_idf_legacy(&store, &idf_legacy_first);
                try testing.expectEqual(@as(u32, 7), try (try store.open("fixture", .read_only)).get(u32, "later"));
                try check_only_blob(&store, h.ns, "legacy", null);
            }
        }
    }
}

test "beside a version 1 blob, init erases the indexes ESP-IDF's load erases, judged as ESP-IDF judges them" {
    // state_fixture.cpp's version 1 blob with blob indexes of its key on its
    // page and the next. ESP-IDF's load erases the incomplete ones; where a
    // complete one is left, init here also erases the version 1 blob, which
    // leaves the bytes of ESP-IDF's own erase of it after that load.
    const cases = .{
        // An index with no chunk, then a complete one: the complete one is
        // read.
        .{ "legacy_complete_and_broken_index", true, &idf_legacy_second },
        // Two indexes with no chunk: the version 1 blob is read.
        .{ "legacy_two_broken_indexes", false, &idf_legacy_first },
        // Chunk 0 and its index, then chunk 1 and an index of chunks 0 and
        // 1: both chunks credited to the first index, so neither is
        // complete, though each would read.
        .{ "legacy_overlapping_indexes", false, &idf_legacy_first },
        // Chunks 0 and 1 and an index of chunk 0, then an empty blob's
        // index from 0: both chunks credited to the first, which goes, and
        // none to the second, which is complete and read. Judged once the
        // first is gone, it would be credited both and erased too.
        .{ "legacy_broken_then_empty_index", true, "" },
    };
    inline for (cases) |case| {
        errdefer std.debug.print("idf_state_{s}.bin\n", .{case[0]});
        const expected = @embedFile("nvs_testdata/idf_state_" ++ case[0] ++ if (case[1]) "_v1_erased.bin" else "_loaded.bin");
        var mem: [3 * page_size]u8 = @embedFile("nvs_testdata/idf_state_" ++ case[0] ++ ".bin").*;
        var flash: TestFlash = .{ .mem = &mem };
        var store: TestStorage = undefined;
        for (0..2) |_| {
            try store.init(&flash, mem.len);
            try testing.expectEqualSlices(u8, expected, &mem);
            try check_idf_legacy(&store, case[2]);
            try testing.expectEqual(@as(u32, 7), try (try store.open("fixture", .read_only)).get(u32, "later"));
        }
    }

    // Chunk 0 and its index, then an index from 0 with no chunk: the
    // second is incomplete. ESP-IDF erases an incomplete index by its key
    // and first chunk number (`Page::eraseItem` with its `chunkStart`),
    // which takes the first such index, here the complete one, and reads
    // the second. Init here erases the second, and the version 1 blob
    // beside the first, which is read: the same value.
    {
        var mem: [3 * page_size]u8 = @embedFile("nvs_testdata/idf_state_legacy_shared_start.bin").*;
        var flash: TestFlash = .{ .mem = &mem };
        var store: TestStorage = undefined;
        const at_0 = idf_state_pattern(60, 0x40);
        for (0..2) |_| {
            try store.init(&flash, mem.len);
            try check_idf_legacy(&store, &at_0);
            const ns = (try store.open("fixture", .read_only)).ns;
            const index = (try store.find(ns, type_blob_index, "legacy", no_chunk)).?;
            try testing.expectEqual(@as(u8, 0), index.page);
            try check_only_blob(&store, ns, "legacy", (try store.item_at(index)).*);
            try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(ns, type_blob_legacy, "legacy", no_chunk));
        }
    }

    // A reset anywhere in init on the first: the indexes go before the
    // version 1 blob, so the complete index is read all along.
    const seed: [3 * page_size]u8 = @embedFile("nvs_testdata/idf_state_legacy_complete_and_broken_index.bin").*;
    var probe = seed;
    var probe_flash: TestFlash = .{ .mem = &probe };
    var store: TestStorage = undefined;
    try store.init(&probe_flash, probe.len);
    const operations = probe_flash.operations;
    // The index's and the version 1 blob's erase, each a bitmap write and zeros.
    try testing.expect(operations >= 4);
    inline for (.{ false, true }) |partial| {
        for (0..operations + 1) |cut| {
            errdefer std.debug.print("init reset after {d} operations, partial {}\n", .{ cut, partial });
            var mem = seed;
            var flash: TestFlash = .{ .mem = &mem, .budget = cut, .partial_on_failure = partial };
            if (cut < operations) {
                try testing.expectError(error.PowerLoss, store.init(&flash, mem.len));
                flash.restore_power();
                try check_idf_legacy(&store, &idf_legacy_second);
            } else try store.init(&flash, mem.len);
            flash.restore_power();
            try store.init(&flash, mem.len);
            // A reset between an erase's bitmap write and its zeros leaves
            // the entries unzeroed, so the bytes are not compared.
            try check_idf_legacy(&store, &idf_legacy_second);
            const ns = (try store.open("fixture", .read_only)).ns;
            try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(ns, type_blob_legacy, "legacy", no_chunk));
            const index = (try store.find(ns, type_blob_index, "legacy", no_chunk)).?;
            try check_only_blob(&store, ns, "legacy", (try store.item_at(index)).*);
        }
    }
}

test "init judges a version 1 blob's index by the chunks of its key, namespace and half only" {
    // An index of "legacy" from 128, complete, beside the version 1 blob,
    // with chunks it must not count before it: a chunk 0 of the key, the
    // key's blob in another namespace and another key's blob, both from 128.
    // Init erases the version 1 blob and the stray chunk, and keeps the rest.
    var mem: [5 * page_size]u8 = @splat(0xff);
    mem[0 .. 3 * page_size].* = @embedFile("nvs_testdata/idf_state_legacy_blob_full.bin").*;
    var flash: TestFlash = .{ .mem = &mem };
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("fixture", .read_write);
    const other_ns = try store.open("other", .read_write);
    const stray: [10]u8 = @splat(0x55);
    const elsewhere: [30]u8 = @splat(0x66);
    const other_key: [20]u8 = @splat(0x77);
    var chunk = TestStorage.make_item(h.ns, type_blob_data, "legacy", 0);
    _ = try store.append(&chunk, &stray, &.{});
    // A chunk no index of its namespace names, though one of its key in the
    // other namespace names its number: an orphan.
    try append_chunk(&store, h.ns, "solo", 0, &stray);
    _ = try other_ns.append_blob("solo", &elsewhere, 0);
    // An incomplete index of a key without a version 1 blob: kept.
    try append_index(&store, h.ns, "gap", stray.len, 1, 0);
    _ = try other_ns.append_blob("legacy", &elsewhere, 0x80);
    _ = try h.append_blob("other", &other_key, 0x80);
    _ = try h.append_blob("legacy", &idf_legacy_second, 0x80);
    try h.set(u32, "later", 7);

    try store.init(&flash, mem.len);
    try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
    try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_data, "legacy", 0));
    try check_idf_legacy(&store, &idf_legacy_second);
    try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_data, "solo", 0));
    var buf: [40]u8 = undefined;
    try testing.expectEqualSlices(u8, &elsewhere, try other_ns.get_blob("solo", &buf));
    try testing.expectError(error.Corrupt, h.get_blob("gap", &buf));
    try testing.expectEqualSlices(u8, &elsewhere, try other_ns.get_blob("legacy", &buf));
    try testing.expectEqualSlices(u8, &other_key, try h.get_blob("other", &buf));
    try testing.expectEqual(@as(u32, 7), try h.get(u32, "later"));
}

test "init adds a version 1 blob's chunk sizes beyond 16 bits" {
    // A 70000-byte index beside the version 1 blob: complete, so init
    // erases the version 1 blob.
    const page_count = 22;
    const mem = try testing.allocator.alloc(u8, page_count * page_size);
    defer testing.allocator.free(mem);
    @memset(mem, 0xff);
    mem[0 .. 3 * page_size].* = @embedFile("nvs_testdata/idf_state_legacy_blob_full.bin").*;
    const value = try testing.allocator.alloc(u8, 70000);
    defer testing.allocator.free(value);
    for (value, 0..) |*byte, i| byte.* = @truncate(i * 7);
    var flash: TestFlash = .{ .mem = mem };
    var store: TestStorage = undefined;
    try store.init(&flash, @intCast(mem.len));
    const h = try store.open("fixture", .read_write);
    _ = try h.append_blob("legacy", value, 0);
    try h.set(u32, "later", 7);

    try store.init(&flash, @intCast(mem.len));
    try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
    const buf = try testing.allocator.alloc(u8, value.len);
    defer testing.allocator.free(buf);
    try testing.expectEqualSlices(u8, value, try h.get_blob("legacy", buf));
    try testing.expectEqual(@as(u32, 7), try h.get(u32, "later"));
}

test "beside a version 1 blob, init erases the key's indexes if the first does not read, and else the version 1 blobs" {
    const ten: [10]u8 = @splat(0x5a);
    // An index `Storage::eraseMismatchedBlobIndexes` counts complete that
    // does not read: with two copies of chunk 0 and no chunk 1, the second
    // copy 10 bytes or empty (the bytes there then add up to the index's
    // size), or with a chunk whose payload fails its CRC. ESP-IDF's reads
    // fail and erase what they could not read; init erases the index here,
    // with its chunks, and the version 1 blob is read.
    inline for (.{ .{ false, 10 }, .{ false, 0 }, .{ true, 10 } }) |case| {
        const bad_crc, const second_len = case;
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        try append_legacy_page(&store, h.ns, &idf_legacy_first);
        try append_chunk(&store, h.ns, "legacy", 0, &ten);
        try store.new_page();
        try append_chunk(&store, h.ns, "legacy", if (bad_crc) 1 else 0, ten[0..second_len]);
        try append_index(&store, h.ns, "legacy", ten.len + second_len, 2, 0);
        try h.set(u32, "later", 7);
        if (bad_crc) {
            const chunk = (try store.find(h.ns, type_blob_data, "legacy", 1)).?;
            mem[@as(usize, chunk.page) * page_size + entries_offset + (@as(usize, chunk.index) + 1) * entry_size] ^= 1;
        }
        try store.init(&flash, mem.len);
        var buf: [200]u8 = undefined;
        try testing.expectEqualSlices(u8, &idf_legacy_first, try h.get_blob("legacy", &buf));
        try testing.expectEqual(@as(u32, 7), try h.get(u32, "later"));
        try check_only_blob(&store, h.ns, "legacy", null);
        const settled = mem;
        try store.init(&flash, mem.len);
        try testing.expectEqualSlices(u8, &settled, &mem);
    }
    // An index of chunk 0, which reads, then one of two 10-byte chunks from
    // 128 that counts two copies of chunk 128 and does not read: the first,
    // which the key reads, decides, and the version 1 blob goes.
    {
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        try append_legacy_page(&store, h.ns, &idf_legacy_first);
        try append_chunk(&store, h.ns, "legacy", 0, &ten);
        try append_index(&store, h.ns, "legacy", ten.len, 1, 0);
        try append_chunk(&store, h.ns, "legacy", 0x80, &ten);
        try store.new_page();
        try append_chunk(&store, h.ns, "legacy", 0x80, &ten);
        try append_index(&store, h.ns, "legacy", 2 * ten.len, 2, 0x80);
        try h.set(u32, "later", 7);
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
        var buf: [200]u8 = undefined;
        try testing.expectEqualSlices(u8, &ten, try h.get_blob("legacy", &buf));
    }
    // The same two indexes in the other order: the first does not read, so
    // both go, as after ESP-IDF's failed read, and the version 1 blob stays.
    {
        var mem: [5 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        try append_legacy_page(&store, h.ns, &idf_legacy_first);
        try append_chunk(&store, h.ns, "legacy", 0, &ten);
        try store.new_page();
        try append_chunk(&store, h.ns, "legacy", 0, &ten);
        try append_index(&store, h.ns, "legacy", 2 * ten.len, 2, 0);
        try store.new_page();
        try append_chunk(&store, h.ns, "legacy", 0x80, &ten);
        try append_index(&store, h.ns, "legacy", ten.len, 1, 0x80);
        try h.set(u32, "later", 7);
        try store.init(&flash, mem.len);
        var buf: [200]u8 = undefined;
        try testing.expectEqualSlices(u8, &idf_legacy_first, try h.get_blob("legacy", &buf));
        try check_only_blob(&store, h.ns, "legacy", null);
    }
    // A first index that is not complete, by its size (its chunk a byte
    // short) or by its count (one chunk of two), goes before the read
    // check, which then takes the index after it: that one reads, and the
    // version 1 blob goes.
    inline for (.{ .{ 11, 1 }, .{ 10, 2 } }) |case| {
        const size, const count = case;
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        try append_legacy_page(&store, h.ns, &idf_legacy_first);
        try append_chunk(&store, h.ns, "legacy", 0, &ten);
        try append_index(&store, h.ns, "legacy", size, count, 0);
        try store.new_page();
        _ = try h.append_blob("legacy", &idf_legacy_second, 0x80);
        try h.set(u32, "later", 7);
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
        var buf: [200]u8 = undefined;
        try testing.expectEqualSlices(u8, &idf_legacy_second, try h.get_blob("legacy", &buf));
    }
    // The read check takes the first copy of a chunk number, as a read does.
    // An index of two chunks from 129 with only chunk 129 is incomplete and
    // goes; the index after it, of chunks 128 and 129, counts the two copies
    // of chunk 128 before chunk 129 and is complete. The second copy fails
    // its CRC, the first is read: the version 1 blob goes.
    {
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        try append_legacy_page(&store, h.ns, &idf_legacy_first);
        try append_chunk(&store, h.ns, "legacy", 0x80, &ten);
        try append_index(&store, h.ns, "legacy", 2 * ten.len, 2, 0x81);
        try store.new_page();
        try append_chunk(&store, h.ns, "legacy", 0x80, &ten);
        try append_chunk(&store, h.ns, "legacy", 0x81, &ten);
        try append_index(&store, h.ns, "legacy", 2 * ten.len, 2, 0x80);
        try h.set(u32, "later", 7);
        const first = (try store.find(h.ns, type_blob_data, "legacy", 0x80)).?;
        const second = (try store.find_other(h.ns, type_blob_data, "legacy", 0x80, first)).?;
        mem[@as(usize, second.page) * page_size + entries_offset + (@as(usize, second.index) + 1) * entry_size] ^= 1;
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
        var buf: [200]u8 = undefined;
        try testing.expectEqualSlices(u8, &(ten ++ ten), try h.get_blob("legacy", &buf));
    }
    // Two version 1 blobs beside a complete index that reads: both go.
    {
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        try append_legacy_page(&store, h.ns, &idf_legacy_first);
        try append_legacy_page(&store, h.ns, &idf_state_pattern(70, 9));
        _ = try h.append_blob("legacy", &idf_legacy_second, 0);
        try h.set(u32, "later", 7);
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
        var buf: [200]u8 = undefined;
        try testing.expectEqualSlices(u8, &idf_legacy_second, try h.get_blob("legacy", &buf));
    }
    // Two version 1 blobs beside an index that does not read: both stay,
    // and the first is read.
    {
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        try append_legacy_page(&store, h.ns, &idf_legacy_first);
        try append_legacy_page(&store, h.ns, &idf_state_pattern(70, 9));
        try append_chunk(&store, h.ns, "legacy", 0, &ten);
        try append_chunk(&store, h.ns, "legacy", 0, &ten);
        try append_index(&store, h.ns, "legacy", 2 * ten.len, 2, 0);
        try h.set(u32, "later", 7);
        try store.init(&flash, mem.len);
        var buf: [200]u8 = undefined;
        try testing.expectEqualSlices(u8, &idf_legacy_first, try h.get_blob("legacy", &buf));
        try testing.expectEqual(@as(u32, 7), try h.get(u32, "later"));
        const first = (try store.find(h.ns, type_blob_legacy, "legacy", no_chunk)).?;
        try testing.expect(try store.find_other(h.ns, type_blob_legacy, "legacy", no_chunk, first) != null);
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_index, "legacy", no_chunk));
    }
}

test "a blob index from another chunk number than 0 or 128 is read and erased, not written over, and costs no other item" {
    // No ESP-IDF write leaves one; ESP-IDF loads and reads it, and its
    // `Storage::writeItem` answers ESP_FAIL.
    const value = idf_state_pattern(20, 3);
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("fixture", .read_write);
    try h.set(u32, "before", 1);
    try append_chunk(&store, h.ns, "odd", 5, value[0..10]);
    try append_chunk(&store, h.ns, "odd", 6, value[10..]);
    try append_index(&store, h.ns, "odd", value.len, 2, 5);
    try h.set(u32, "later", 7);
    const before = mem;
    try store.init(&flash, mem.len);
    var buf: [32]u8 = undefined;
    try testing.expectEqualSlices(u8, &value, try h.get_blob("odd", &buf));
    try testing.expectError(error.Corrupt, h.set_blob("odd", "new"));
    try testing.expectEqualSlices(u8, &before, &mem);
    try h.erase_key("odd");
    try testing.expectError(error.NotFound, h.get_blob("odd", &buf));
    try check_only_blob(&store, h.ns, "odd", null);
    try testing.expectEqual(@as(u32, 1), try h.get(u32, "before"));
    try testing.expectEqual(@as(u32, 7), try h.get(u32, "later"));

    // An index of three chunks from 254, the last chunk number: it names
    // 254 and no chunk 0, which init erases as an orphan
    // (`Storage::eraseOrphanDataBlobs` does not wrap either).
    try append_chunk(&store, h.ns, "end", 0, value[0..10]);
    try append_chunk(&store, h.ns, "end", 0xfe, value[0..10]);
    try append_index(&store, h.ns, "end", value.len, 3, 0xfe);
    try store.init(&flash, mem.len);
    try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_data, "end", 0));
    try testing.expect(try store.find(h.ns, type_blob_data, "end", 0xfe) != null);
}

test "init judges a key's blob indexes once, beside one or two version 1 blobs, reset anywhere" {
    // Chunks 0 and 1 and an index of chunk 0, then an empty blob's index
    // from 0 on the next page, beside a version 1 blob
    // (legacy_broken_then_empty_index), or beside two: both chunks count
    // for the first index, which goes, and none for the second, which is
    // complete and read. Judged again at the second version 1 blob, with
    // the chunks still there, the second index would be credited both and
    // erased, and that version 1 blob read.
    const second = idf_state_pattern(70, 9);
    var seeds: [2][5 * page_size]u8 = @splat(@splat(0xff));
    seeds[0][0 .. 3 * page_size].* = @embedFile("nvs_testdata/idf_state_legacy_broken_then_empty_index.bin").*;
    {
        var flash: TestFlash = .{ .mem = &seeds[1] };
        var store: TestStorage = undefined;
        try store.init(&flash, seeds[1].len);
        const h = try store.open("fixture", .read_write);
        try append_legacy_page(&store, h.ns, &idf_legacy_first);
        try append_legacy_page(&store, h.ns, &second);
        try append_chunk(&store, h.ns, "legacy", 0, &idf_state_pattern(60, 1));
        try append_chunk(&store, h.ns, "legacy", 1, &idf_state_pattern(40, 2));
        try append_index(&store, h.ns, "legacy", 60, 1, 0);
        try store.new_page();
        try append_index(&store, h.ns, "legacy", 0, 0, 0);
        try h.set(u32, "later", 7);
    }
    for (seeds, 0..) |seed, s| {
        var probe = seed;
        var probe_flash: TestFlash = .{ .mem = &probe };
        var store: TestStorage = undefined;
        try store.init(&probe_flash, probe.len);
        const operations = probe_flash.operations;
        // The first index's, the version 1 blobs' and the chunks' erases,
        // each a bitmap write and zeros.
        try testing.expect(operations >= 8 + 2 * s);
        inline for (.{ false, true }) |partial| {
            for (0..operations + 1) |cut| {
                errdefer std.debug.print("state {d}, init reset after {d} operations, partial {}\n", .{ s, cut, partial });
                var mem = seed;
                var flash: TestFlash = .{ .mem = &mem, .budget = cut, .partial_on_failure = partial };
                if (cut < operations) {
                    try testing.expectError(error.PowerLoss, store.init(&flash, mem.len));
                } else try store.init(&flash, mem.len);
                flash.restore_power();
                try store.init(&flash, mem.len);
                // A reset after the first index's erase leaves its chunks,
                // which the second index is then credited, as ESP-IDF
                // credits them in that state: a version 1 value is read.
                const h = try store.open("fixture", .read_only);
                var buf: [200]u8 = undefined;
                const read = try h.get_blob("legacy", &buf);
                try testing.expect(read.len == 0 or std.mem.eql(u8, read, &idf_legacy_first) or std.mem.eql(u8, read, &second));
                try testing.expectEqual(@as(u32, 7), try h.get(u32, "later"));
                if (cut == operations) {
                    try testing.expectEqual(@as(usize, 0), read.len);
                    try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
                    const index = (try store.find(h.ns, type_blob_index, "legacy", no_chunk)).?;
                    try check_only_blob(&store, h.ns, "legacy", (try store.item_at(index)).*);
                }
            }
        }
    }
}

test "init credits a chunk to the first blob index whose range holds it, to the end of its half, on the active page up to its first blank entry" {
    const ten: [10]u8 = @splat(0x5a);
    // An index of one 10-byte chunk from 0 or 128, its chunk, and a stray
    // chunk at the end of its half (127 or 254): the index is credited two
    // chunks, so it is incomplete and goes, and the version 1 blob is read.
    inline for (.{ 0, 0x80 }, .{ 0x7f, 0xfe }) |start, stray| {
        errdefer std.debug.print("index from {d}, stray chunk {d}\n", .{ start, stray });
        var mem: [3 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        try append_legacy_page(&store, h.ns, &idf_legacy_first);
        try append_chunk(&store, h.ns, "legacy", start, &ten);
        try append_chunk(&store, h.ns, "legacy", stray, &ten);
        try append_index(&store, h.ns, "legacy", ten.len, 1, start);
        try h.set(u32, "later", 7);
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_index, "legacy", no_chunk));
        var buf: [200]u8 = undefined;
        try testing.expectEqualSlices(u8, &idf_legacy_first, try h.get_blob("legacy", &buf));
    }
    // Chunk 0 and its index, then an empty blob's index from 0 on the next
    // page, whose range holds chunk 0 too: the chunk counts for the first
    // index only, so both are complete and kept. The version 1 blob goes,
    // and the first index is read.
    {
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        try append_legacy_page(&store, h.ns, &idf_legacy_first);
        try append_chunk(&store, h.ns, "legacy", 0, &ten);
        try append_index(&store, h.ns, "legacy", ten.len, 1, 0);
        try store.new_page();
        try append_index(&store, h.ns, "legacy", 0, 0, 0);
        try h.set(u32, "later", 7);
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
        const first = (try store.find(h.ns, type_blob_index, "legacy", no_chunk)).?;
        try testing.expect(try store.find_other(h.ns, type_blob_index, "legacy", no_chunk, first) != null);
        var buf: [200]u8 = undefined;
        try testing.expectEqualSlices(u8, &ten, try h.get_blob("legacy", &buf));
    }
    // A chunk past a blank entry on the active page is not there
    // (`Page::findItem` stops at `mNextFreeEntry`, the first blank entry):
    // the index is complete, and the version 1 blob goes.
    {
        var mem: [3 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        try append_legacy_page(&store, h.ns, &idf_legacy_first);
        try append_chunk(&store, h.ns, "legacy", 0, &ten);
        try append_index(&store, h.ns, "legacy", ten.len, 1, 0);
        try h.set(u32, "later", 7);
        store.next_free += 1;
        try append_chunk(&store, h.ns, "legacy", 1, &ten);
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
        var buf: [200]u8 = undefined;
        try testing.expectEqualSlices(u8, &ten, try h.get_blob("legacy", &buf));
    }
}

test "a write or an erase of a key with three blob indexes takes all three" {
    // The index read on page 0 (chunk 0), and two more on pages 1 and 2,
    // each with its own chunk 128.
    const first = idf_state_pattern(100, 0);
    const third: [40]u8 = @splat(0x33);
    inline for (.{ false, true }) |erase| {
        errdefer std.debug.print("erase {}\n", .{erase});
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        try h.set_blob("big", &first);
        inline for (.{ 0x11, 0x22 }) |fill| {
            try store.new_page();
            _ = try h.append_blob("big", &@as([60]u8, @splat(fill)), 0x80);
        }
        try h.set(u32, "later", 7);
        try store.init(&flash, mem.len);
        var buf: [200]u8 = undefined;
        try testing.expectEqualSlices(u8, &first, try h.get_blob("big", &buf));

        if (erase) try h.erase_key("big") else try h.set_blob("big", &third);
        const index: ?Item = if (try store.find(h.ns, type_blob_index, "big", no_chunk)) |loc| (try store.item_at(loc)).* else null;
        try testing.expectEqual(erase, index == null);
        try check_only_blob(&store, h.ns, "big", index);
        try store.init(&flash, mem.len);
        try testing.expect(same_blob(if (erase) null else &third, try read_fixture_blob(&store, "big", &buf)));
    }
}

test "a write or an erase takes every version 1 blob of a key, the one read last, reset anywhere" {
    // Three version 1 blobs of one key on three pages: the first is read.
    // An erase that took it before the others would, reset in between,
    // leave the second one read.
    const values = .{ idf_legacy_first, idf_state_pattern(80, 0x11), idf_state_pattern(60, 0x22) };
    const third: [40]u8 = @splat(0x33);
    inline for (.{ OpenMode.read_write, OpenMode.read_write_purge }) |mode| {
        inline for (.{ false, true }) |erase| {
            inline for (.{ false, true }) |partial| {
                var cut: usize = 0;
                while (true) : (cut += 1) {
                    errdefer std.debug.print("{s}, erase {}, reset after {d} operations, partial {}\n", .{ @tagName(mode), erase, cut, partial });
                    var mem: [5 * page_size]u8 = undefined;
                    var flash = test_flash(&mem);
                    var store: TestStorage = undefined;
                    try store.init(&flash, mem.len);
                    const h = try store.open("fixture", mode);
                    inline for (values, 0..) |value, i| {
                        if (i > 0) try store.new_page();
                        _ = try append_legacy(&store, h.ns, "legacy", &value);
                    }
                    try h.set(u32, "later", 7);
                    try store.init(&flash, mem.len);
                    var buf: [200]u8 = undefined;
                    try testing.expectEqualSlices(u8, &idf_legacy_first, try h.get_blob("legacy", &buf));

                    flash.partial_on_failure = partial;
                    flash.budget = cut;
                    const result = if (erase) h.erase_key("legacy") else h.set_blob("legacy", &third);
                    flash.restore_power();
                    const new: ?[]const u8 = if (erase) null else &third;
                    if (result) |_| {
                        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
                        try testing.expect(same_blob(new, try read_fixture_blob(&store, "legacy", &buf)));
                    } else |err| try testing.expectEqual(error.PowerLoss, err);

                    try store.init(&flash, mem.len);
                    const read = try read_fixture_blob(&store, "legacy", &buf);
                    try testing.expect(same_blob(read, &idf_legacy_first) or same_blob(read, new));
                    if (result) |_| try testing.expect(same_blob(read, new)) else |_| {}
                    try testing.expectEqual(@as(u32, 7), try (try store.open("fixture", .read_only)).get(u32, "later"));
                    if (result) |_| break else |_| {}
                }
            }
        }
    }
}

test "the first of two version 1 blobs of a key is read, as ESP-IDF's Storage::findItem finds it" {
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("fixture", .read_write);
    _ = try append_legacy(&store, h.ns, "legacy", &idf_legacy_first);
    try store.new_page();
    _ = try append_legacy(&store, h.ns, "legacy", &idf_legacy_second);
    // Not the last item: init would erase the first copy.
    try h.set(u32, "later", 7);
    try store.init(&flash, mem.len);
    var buf: [200]u8 = undefined;
    try testing.expectEqualSlices(u8, &idf_legacy_first, (try read_fixture_blob(&store, "legacy", &buf)).?);
    try testing.expectEqual(idf_legacy_first.len, try h.blob_len("legacy"));
}

test "init erases the first older copy of the newest page's last item, as ESP-IDF's PageManager::load does" {
    // Three copies of one key on three pages, the newest last: the copy on
    // page 0 goes, and the one on page 1 is read.
    {
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("ns", .read_write);
        for (1..4) |value| {
            if (value > 1) try store.new_page();
            var item = TestStorage.make_item(h.ns, TestStorage.int_type(u32), "n", no_chunk);
            std.mem.writeInt(u32, item.data[0..4], @intCast(value), .little);
            _ = try store.append(&item, &.{}, &.{});
        }
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(u32, 2), try h.get(u32, "n"));
        const read = (try store.find(h.ns, TestStorage.int_type(u32), "n", no_chunk)).?;
        try testing.expectEqual(@as(u8, 1), read.page);
        try testing.expect(try store.find_other(h.ns, TestStorage.int_type(u32), "n", no_chunk, read) != null);
    }
    // A blob chunk last, with an older copy of its number that the key's
    // index names: the older copy goes, and the blob reads the newer one.
    {
        var mem: [3 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("ns", .read_write);
        const old: [10]u8 = @splat(0x11);
        const new: [10]u8 = @splat(0x22);
        try append_chunk(&store, h.ns, "blob", 0, &old);
        try append_index(&store, h.ns, "blob", old.len, 1, 0);
        var buf: [10]u8 = undefined;
        try testing.expectEqualSlices(u8, &old, try h.get_blob("blob", &buf));
        try store.new_page();
        try append_chunk(&store, h.ns, "blob", 0, &new);
        try store.init(&flash, mem.len);
        try testing.expectEqualSlices(u8, &new, try h.get_blob("blob", &buf));
        const chunk = (try store.find(h.ns, type_blob_data, "blob", 0)).?;
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find_other(h.ns, type_blob_data, "blob", 0, chunk));
    }
    // The older copy on the second of three pages, the first without the
    // key: it goes. Not with its page marked as being freed and the newest
    // page active: the newest page then counts as that reclaim's unfinished
    // copy and is written again, so the older copy is the one left.
    inline for (.{ false, true }) |freeing| {
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("ns", .read_write);
        try h.set(u32, "between", 5);
        try store.new_page();
        try h.set(u32, "n", 1);
        try store.new_page();
        var item = TestStorage.make_item(h.ns, TestStorage.int_type(u32), "n", no_chunk);
        std.mem.writeInt(u32, item.data[0..4], 3, .little);
        _ = try store.append(&item, &.{}, &.{});
        if (freeing) std.mem.writeInt(u32, mem[page_size..][0..4], @backingInt(format.PageState.freeing), .little);
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(u32, if (freeing) 1 else 3), try h.get(u32, "n"));
        try testing.expectEqual(@as(u32, 5), try h.get(u32, "between"));
        const read = (try store.find(h.ns, TestStorage.int_type(u32), "n", no_chunk)).?;
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find_other(h.ns, TestStorage.int_type(u32), "n", no_chunk, read));
    }
    // The older copy on a third page, beside a page being freed and the
    // newest page active, as only another writer leaves them: it stays
    // and is read, since the newest page goes as that reclaim's unfinished
    // copy. The reclaim is copied again to that page, not to the first
    // free one.
    {
        var mem: [5 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        // Page 0 stays empty, to be a free page before the others.
        while (store.active != 1) try store.new_page();
        const h = try store.open("ns", .read_write);
        try h.set(u32, "n", 1);
        try store.new_page();
        try h.set(u32, "other", 9);
        try store.new_page();
        try append_u32(&store, h.ns, "n", 3);
        @memset(mem[0..page_size], 0xFF);
        try store.set_page_state(2, .freeing);
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(?u8, 3), store.active);
        try testing.expectEqual(PageState.uninitialized, store.pages[2].state);
        try testing.expectEqual(@as(u32, 1), try h.get(u32, "n"));
        try testing.expectEqual(@as(u32, 9), try h.get(u32, "other"));
    }
    // The newest page full, as after a reset before the next page is
    // activated, with or without a page being freed: the older copy goes,
    // unless it is on the page being freed, which is left out of the
    // search as ESP-IDF's `PageManager::load` leaves it out. Reclaim here
    // skips that stale copy rather than moving it after the live value.
    for ([_]?u8{ null, 0, 1 }) |freeing| {
        errdefer std.debug.print("page being freed: {?d}\n", .{freeing});
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("ns", .read_write);
        try h.set(u32, "between", 5);
        try h.set(u32, "n", 1);
        try store.new_page();
        try h.set(u32, "other", 9);
        try store.new_page();
        var item = TestStorage.make_item(h.ns, TestStorage.int_type(u32), "n", no_chunk);
        std.mem.writeInt(u32, item.data[0..4], 3, .little);
        _ = try store.append(&item, &.{}, &.{});
        try store.set_page_state(2, .full);
        if (freeing) |page| try store.set_page_state(page, .freeing);
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(?u8, if (freeing == null) null else 3), store.active);
        try testing.expectEqual(@as(u32, 3), try h.get(u32, "n"));
        try testing.expectEqual(@as(u32, 5), try h.get(u32, "between"));
        try testing.expectEqual(@as(u32, 9), try h.get(u32, "other"));
        const read = (try store.find(h.ns, TestStorage.int_type(u32), "n", no_chunk)).?;
        try testing.expectEqual(@as(u8, 2), read.page);
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find_other(h.ns, TestStorage.int_type(u32), "n", no_chunk, read));
    }
    // An older item of the key with another type stays, as
    // `Page::findItem` stops at it.
    {
        var mem: [3 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("ns", .read_write);
        try h.set(u8, "n", 1);
        try store.new_page();
        var item = TestStorage.make_item(h.ns, TestStorage.int_type(u32), "n", no_chunk);
        std.mem.writeInt(u32, item.data[0..4], 3, .little);
        _ = try store.append(&item, &.{}, &.{});
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(u8, 1), try h.get(u8, "n"));
        try testing.expect(try store.find(h.ns, TestStorage.int_type(u32), "n", no_chunk) != null);
    }
    // And the search goes on past that page: of an item of another type on
    // the oldest page and a copy on the next one, the copy goes.
    {
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("ns", .read_write);
        try h.set(u8, "n", 1);
        try store.new_page();
        try append_u32(&store, h.ns, "n", 2);
        try store.new_page();
        try append_u32(&store, h.ns, "n", 3);
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(u8, 1), try h.get(u8, "n"));
        const read = (try store.find(h.ns, TestStorage.int_type(u32), "n", no_chunk)).?;
        try testing.expectEqual(@as(u8, 2), read.page);
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find_other(h.ns, TestStorage.int_type(u32), "n", no_chunk, read));
    }
    // A blob index last, which does not read, after a version 1 blob of
    // its key: ESP-IDF erases the version 1 blob here; this store keeps and
    // reads it, and erases the index.
    {
        var mem: [3 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        const ten: [10]u8 = @splat(0x5a);
        try append_legacy_page(&store, h.ns, &idf_legacy_first);
        try append_chunk(&store, h.ns, "legacy", 0, &ten);
        try append_chunk(&store, h.ns, "legacy", 0, &ten);
        try append_index(&store, h.ns, "legacy", 2 * ten.len, 2, 0);
        try store.init(&flash, mem.len);
        var buf: [200]u8 = undefined;
        try testing.expectEqualSlices(u8, &idf_legacy_first, try h.get_blob("legacy", &buf));
        try check_only_blob(&store, h.ns, "legacy", null);
    }
}

/// Appends a u32 without erasing an older item of the key, as a write
/// leaves the page if it is reset before that erase.
fn append_u32(store: *TestStorage, ns: u8, key: []const u8, value: u32) !void {
    var item = TestStorage.make_item(ns, TestStorage.int_type(u32), key, no_chunk);
    std.mem.writeInt(u32, item.data[0..4], value, .little);
    _ = try store.append(&item, &.{}, &.{});
}

test "init orders pages by sequence number, the later of two equal ones last, as ESP-IDF's PageManager::load does" {
    // Two copies of a key, the newer one last on the newest page, which
    // `tie` gives the older page's sequence number and `swap` puts first
    // in the partition: either way it stays the newest page, so the older
    // copy is the one that goes and the next write lands after the newer.
    inline for (.{ .{ false, true }, .{ true, false } }) |case| {
        const tie, const swap = case;
        var mem: [3 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("ns", .read_write);
        try h.set(u32, "n", 1);
        try store.new_page();
        try append_u32(&store, h.ns, "n", 3);
        if (tie) {
            const header = mem[page_size..][0..format.header_size];
            @memcpy(header[4..8], mem[4..8]);
            std.mem.writeInt(u32, header[28..32], crc32(0xFFFF_FFFF, header[4..28]), .little);
        }
        if (swap) {
            var page: [page_size]u8 = mem[0..page_size].*;
            @memcpy(mem[0..page_size], mem[page_size..][0..page_size]);
            @memcpy(mem[page_size..][0..page_size], &page);
        }
        const newest: u8 = if (swap) 0 else 1;
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(?u8, newest), store.active);
        try testing.expectEqual(@as(u32, 3), try h.get(u32, "n"));
        const read = (try store.find(h.ns, TestStorage.int_type(u32), "n", no_chunk)).?;
        try testing.expectEqual(newest, read.page);
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find_other(h.ns, TestStorage.int_type(u32), "n", no_chunk, read));
    }
    // An older page still marked active, which only another writer leaves:
    // it is marked full, and the newest page is the one written.
    {
        var mem: [3 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("ns", .read_write);
        try h.set(u32, "n", 1);
        try store.new_page();
        try h.set(u32, "m", 2);
        std.mem.writeInt(u32, mem[0..4], @backingInt(format.PageState.active), .little);
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(?u8, 1), store.active);
        try testing.expectEqual(@backingInt(format.PageState.full), std.mem.readInt(u32, mem[0..4], .little));
        try testing.expectEqual(@as(u32, 1), try h.get(u32, "n"));
        try testing.expectEqual(@as(u32, 2), try h.get(u32, "m"));
    }
}

test "init erases what the last write replaced, then finishes a reclaim, then judges blobs, in ESP-IDF's order" {
    // A blob written over, reset before the old index is erased: the old
    // index goes as the item the last write replaced, and only then are
    // the old chunks orphans, which go in the same init.
    {
        var mem: [3 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("ns", .read_write);
        const old: [40]u8 = @splat(0x11);
        const new: [50]u8 = @splat(0x22);
        try h.set_blob("blob", &old);
        try store.new_page();
        _ = try h.append_blob("blob", &new, 0x80);
        try store.init(&flash, mem.len);
        var buf: [50]u8 = undefined;
        try testing.expectEqualSlices(u8, &new, try h.get_blob("blob", &buf));
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_data, "blob", 0));
        try check_only_blob(&store, h.ns, "blob", (try store.item_at((try store.find(h.ns, type_blob_index, "blob", no_chunk)).?)).*);
    }
    // A version 1 blob, an index of its key that does not read, and a
    // newer index that does, written last, as only another writer leaves
    // them: the older index goes as the item the last write replaced, so
    // the newer one is the key's first, and the version 1 blob goes.
    // Judged before that, all three would count against the indexes.
    {
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        const old: [10]u8 = @splat(0x11);
        const new: [10]u8 = @splat(0x22);
        try append_legacy_page(&store, h.ns, &idf_legacy_first);
        try append_chunk(&store, h.ns, "legacy", 0, &old);
        try append_index(&store, h.ns, "legacy", old.len, 1, 0);
        const chunk = (try store.find(h.ns, type_blob_data, "legacy", 0)).?;
        mem[@as(usize, chunk.page) * page_size + (@as(usize, chunk.index) + 3) * 32] ^= 0xff;
        try store.new_page();
        try append_chunk(&store, h.ns, "legacy", 0x80, &new);
        try append_index(&store, h.ns, "legacy", new.len, 1, 0x80);
        try store.init(&flash, mem.len);
        var buf: [200]u8 = undefined;
        try testing.expectEqualSlices(u8, &new, try h.get_blob("legacy", &buf));
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_legacy, "legacy", no_chunk));
        try check_only_blob(&store, h.ns, "legacy", (try store.item_at((try store.find(h.ns, type_blob_index, "legacy", no_chunk)).?)).*);
    }
    // A page being freed and a newest, active page with a blob index, as
    // only another writer leaves them: the newest page counts as the
    // reclaim's unfinished copy and is erased, and only then are the
    // index's chunks on a third page orphans, which go in the same init.
    {
        var mem: [4 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("ns", .read_write);
        const ten: [10]u8 = @splat(0x5a);
        try append_chunk(&store, h.ns, "blob", 0, &ten);
        try store.new_page();
        try h.set(u32, "n", 1);
        try store.new_page();
        try append_index(&store, h.ns, "blob", ten.len, 1, 0);
        var buf: [10]u8 = undefined;
        try testing.expectEqualSlices(u8, &ten, try h.get_blob("blob", &buf));
        try store.set_page_state(1, .freeing);
        try store.init(&flash, mem.len);
        try testing.expectEqual(@as(u32, 1), try h.get(u32, "n"));
        try testing.expectError(error.NotFound, h.get_blob("blob", &buf));
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_data, "blob", 0));
    }
}

test "a write replaces through a purging handle by zeroing the old entries, through a read_write one by marking them" {
    inline for (.{ OpenMode.read_write, OpenMode.read_write_purge }) |mode| {
        var mem: [3 * page_size]u8 = undefined;
        var flash = test_flash(&mem);
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("ns", mode);
        try h.set(u32, "number", 1);
        try h.set_str("text", "a first value that spans several entries");
        try h.set_blob("blob", &(@as([100]u8, @splat(0x5a))));
        const old = [_]TestStorage.Location{
            (try store.find(h.ns, TestStorage.int_type(u32), "number", no_chunk)).?,
            (try store.find(h.ns, type_str, "text", no_chunk)).?,
            (try store.find(h.ns, type_blob_index, "blob", no_chunk)).?,
            (try store.find(h.ns, type_blob_data, "blob", 0)).?,
        };
        const before = mem;
        try h.set(u32, "number", 2);
        try h.set_str("text", "second");
        try h.set_blob("blob", "second");
        var buf: [16]u8 = undefined;
        try testing.expectEqual(@as(u32, 2), try h.get(u32, "number"));
        try testing.expectEqualStrings("second", try h.get_str("text", &buf));
        try testing.expectEqualStrings("second", try h.get_blob("blob", &buf));
        try check_replaced(mode, &before, &mem, &old);
    }
    // A key with a blob index and a version 1 blob: an erase takes both.
    inline for (.{ OpenMode.read_write, OpenMode.read_write_purge }) |mode| {
        var mem: [3 * page_size]u8 = undefined;
        var flash: TestFlash = undefined;
        var store: TestStorage = undefined;
        _ = try legacy_and_new_index(&mem, &flash, &store, &idf_legacy_second);
        const h = try store.open("fixture", mode);
        const old = [_]TestStorage.Location{
            (try store.find(h.ns, type_blob_legacy, "legacy", no_chunk)).?,
            (try store.find(h.ns, type_blob_index, "legacy", no_chunk)).?,
            (try store.find(h.ns, type_blob_data, "legacy", 0)).?,
        };
        const before = mem;
        try h.erase_key("legacy");
        try testing.expectError(error.NotFound, h.blob_len("legacy"));
        try check_replaced(mode, &before, &mem, &old);
    }
}

/// Checks that the items at `old` in `before` are erased in `mem`: zeroed
/// when `mode` purges, their bytes kept otherwise.
fn check_replaced(mode: OpenMode, before: []const u8, mem: []const u8, old: []const TestStorage.Location) !void {
    for (old) |loc| {
        errdefer std.debug.print("{s}: item at page {d}, entry {d}\n", .{ @tagName(mode), loc.page, loc.index });
        const offset = @as(usize, loc.page) * page_size;
        const item = format.item_at(before[offset..][0..page_size], loc.index);
        const span: usize = if (format.variable_length(item.type)) item.span else 1;
        for (loc.index..loc.index + span) |entry| try testing.expectEqual(EntryState.erased, format.entry_state(mem[offset..][0..page_size], entry));
        const bytes = offset + entries_offset + @as(usize, loc.index) * entry_size;
        const now = mem[bytes..][0 .. span * entry_size];
        if (mode == .read_write_purge) {
            try testing.expect(std.mem.allEqual(u8, now, 0));
        } else try testing.expectEqualSlices(u8, before[bytes..][0 .. span * entry_size], now);
    }
}

/// Source-derived v5.5.1 fixture: nvs_page.cpp:697-709 removes the old
/// chunk, then nvs_storage.cpp:90-152 removes the incomplete index and
/// Storage::eraseOrphanDataBlobs removes the unindexed replacement chunk.
fn check_idf_tail_chunk_loss() !void {
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("fixture", .read_write);
    const old: [320]u8 = @splat(0x11);
    const new: [640]u8 = @splat(0x22);
    try h.set(u32, "before", 0x0badcafe);
    try h.set_blob("big", &old);
    try append_chunk(&store, h.ns, "big", 0x80, &new);
    const seed = mem;
    var probe = seed;
    var probe_flash: TestFlash = .{ .mem = &probe };
    try store.init(&probe_flash, probe.len);
    const operations = probe_flash.operations;
    // Recovery can itself reset between its bitmap and payload writes.
    for (0..operations + 1) |cut| {
        mem = seed;
        flash = .{ .mem = &mem, .budget = cut };
        if (cut < operations) {
            try testing.expectError(error.PowerLoss, store.init(&flash, mem.len));
        } else try store.init(&flash, mem.len);
        flash.restore_power();
        try store.init(&flash, mem.len);
        var buf: [640]u8 = undefined;
        try testing.expectError(error.NotFound, h.get_blob("big", &buf));
        try testing.expectError(error.NotFound, h.blob_len("big"));
        try testing.expectEqual(@as(u32, 0x0badcafe), try h.get(u32, "before"));
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_data, "big", 0));
        try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_data, "big", 0x80));
    }
}

// A full newest page holds n=3 while the freeing page still holds n=1.
// ESP-IDF v5.5.1 copies the stale item (nvs_pagemanager.cpp:75-79,
// 113-118; nvs_page.cpp:484-523), then removes only n=3 on set(n,4)
// (nvs_storage.cpp:581-582). Reclaim here must preserve the live value.
test "reclaim never resurrects a stale scalar after replacement or reboot" {
    var mem: [4 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("ns", .read_write);
    try h.set(u32, "n", 1);
    try store.new_page();
    try h.set(u32, "other", 9);
    try store.new_page();
    try append_u32(&store, h.ns, "n", 3);
    try store.set_page_state(2, .full);
    try store.set_page_state(0, .freeing);
    const fixture = mem;
    const before = flash.operations;
    try store.init(&flash, mem.len);
    const operations = flash.operations - before;
    try testing.expectEqual(@as(u32, 3), try h.get(u32, "n"));
    try h.set(u32, "n", 4);
    try testing.expectEqual(@as(u32, 4), try h.get(u32, "n"));
    try store.init(&flash, mem.len);
    try testing.expectEqual(@as(u32, 4), try h.get(u32, "n"));
    // A second boot without the intervening set must also keep n=3.
    mem = fixture;
    try store.init(&flash, mem.len);
    try store.init(&flash, mem.len);
    try testing.expectEqual(@as(u32, 3), try h.get(u32, "n"));
    try testing.expectEqual(@as(u32, 9), try h.get(u32, "other"));

    // The skipped source must stay skipped when recovery itself is reset,
    // including a torn destination bitmap or source-sector erase.
    for ([_]bool{ false, true }) |partial| {
        for (0..operations) |cut| {
            errdefer std.debug.print("stale reclaim reset after {d} operations, partial={}\n", .{ cut, partial });
            mem = fixture;
            flash = .{ .mem = &mem, .budget = cut, .partial_on_failure = partial };
            try testing.expectError(error.PowerLoss, store.init(&flash, mem.len));
            flash.restore_power();
            try store.init(&flash, mem.len);
            try testing.expectEqual(@as(u32, 3), try h.get(u32, "n"));
            try testing.expectEqual(@as(u32, 9), try h.get(u32, "other"));
            try h.set(u32, "n", 4);
            try testing.expectEqual(@as(u32, 4), try h.get(u32, "n"));
            try store.init(&flash, mem.len);
            try testing.expectEqual(@as(u32, 4), try h.get(u32, "n"));
        }
    }
}

test "v5.5.1 loses a same-page blob rewrite reset before its index" {
    try check_idf_tail_chunk_loss();
}

// Source-derived v5.5.1 nvs_pagemanager.cpp:166-178: activation precedes
// marking the victim FREEING, so a reset can leave an empty destination.
test "v5.5.1 empty reclaim destination keeps the source before freeing" {
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("ns", .read_write);
    try h.set(u32, "n", 3);
    try store.new_page();
    try store.init(&flash, mem.len);
    try testing.expectEqual(@as(u32, 3), try h.get(u32, "n"));
    try h.set(u32, "n", 4);
    try store.init(&flash, mem.len);
    try testing.expectEqual(@as(u32, 4), try h.get(u32, "n"));
}

// Source-derived v5.5.1 nvs_pagemanager.cpp:96-126 finishes one FREEING
// page per boot. The next boot erases the active copy to finish the other.
test "v5.5.1 two freeing pages complete one per boot" {
    var mem: [4 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("ns", .read_write);
    try h.set(u32, "n", 1);
    try store.new_page();
    try h.set(u32, "other", 9);
    try store.new_page();
    try h.set(u32, "last", 7);
    try store.set_page_state(2, .full);
    try store.set_page_state(0, .freeing);
    try store.set_page_state(1, .freeing);
    try store.init(&flash, mem.len);
    try testing.expectEqual(PageState.uninitialized, store.pages[0].state);
    try testing.expectEqual(PageState.freeing, store.pages[1].state);
    try testing.expectEqual(@as(u32, 1), try h.get(u32, "n"));
    try h.set(u32, "n", 4);
    try testing.expectEqual(@as(u32, 4), try h.get(u32, "n"));
    try store.init(&flash, mem.len);
    try testing.expectEqual(PageState.uninitialized, store.pages[1].state);
    try testing.expectError(error.NotFound, store.open("ns", .read_only));
}

// Source-derived v5.5.1 nvs_pagemanager.cpp:130-132 rejects a writable
// partition with no reserve page after recovery.
test "v5.5.1 init requires a free page after recovery" {
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    const h = try store.open("ns", .read_write);
    try h.set(u32, "n", 1);
    try store.new_page();
    try h.set(u32, "other", 9);
    try store.set_page_state(1, .full);
    try store.activate(2);
    try h.set(u32, "last", 7);
    try testing.expectError(error.NotEnoughSpace, store.init(&flash, mem.len));
}

/// The blobs blob_fixture.cpp stores under "big": 9000 bytes, then 6000.
fn idf_blob_pattern(comptime len: usize, seed: u8) [len]u8 {
    @setEvalBranchQuota(4 * len);
    var data: [len]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @truncate(i *% 7 +% (i >> 8) +% seed);
    return data;
}

const idf_blob_first = idf_blob_pattern(9000, 0);
const idf_blob_second = idf_blob_pattern(6000, 0x5a);

/// Opens a five-page partition blob_fixture.cpp wrote with ESP-IDF's Storage
/// and checks what ESP-IDF read from it: the two keys, and "big" holding
/// `blob`, or nothing. A blob's chunks are all those its index names.
fn check_idf_blob(store: *TestStorage, blob: ?[]const u8) !void {
    const h = try store.open("fixture", .read_only);
    try testing.expectEqual(@as(u32, 0x0badcafe), try h.get(u32, "before"));
    try testing.expectEqual(@as(u32, 0xfeedf00d), try h.get(u32, "after"));
    var buf: [9000]u8 = undefined;
    const expected = blob orelse {
        try testing.expectError(error.NotFound, h.blob_len("big"));
        try testing.expectError(error.NotFound, h.get_blob("big", &buf));
        for (0..256) |chunk| try testing.expectEqual(@as(?TestStorage.Location, null), try store.find(h.ns, type_blob_data, "big", @intCast(chunk)));
        return;
    };
    try testing.expectEqual(expected.len, try h.blob_len("big"));
    try testing.expectEqualSlices(u8, expected, try h.get_blob("big", &buf));
    const index = (try store.item_at((try store.find(h.ns, type_blob_index, "big", no_chunk)).?)).*;
    for (0..256) |chunk| {
        const owned = @as(u8, @intCast(chunk)) -% index.data[5] < index.data[4];
        try testing.expectEqual(owned, try store.find(h.ns, type_blob_data, "big", @intCast(chunk)) != null);
    }
}

test "ESP-IDF multi-page blobs read back across pages, versions and interrupted writes" {
    const cases = .{
        .{ "written", &idf_blob_first },
        // The rewrite's chunks are orphans until its index is written:
        // ESP-IDF reads the first blob, and so does init after dropping them.
        .{ "rewriting", &idf_blob_first },
        .{ "rewritten", &idf_blob_second },
        // The erase zeroed the index first: its chunks are orphans.
        .{ "erasing", null },
        .{ "erased", null },
    };
    inline for (cases) |case| {
        errdefer std.debug.print("idf_blob_{s}.bin\n", .{case[0]});
        var mem = @embedFile("nvs_testdata/idf_blob_" ++ case[0] ++ ".bin").*;
        var flash: TestFlash = .{ .mem = &mem };
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        try check_idf_blob(&store, case[1]);
        try store.init(&flash, mem.len);
        try check_idf_blob(&store, case[1]);
    }

    // One chunk per page the blob touches, and the rewrite in the other
    // chunk-number half (VerOffset::VER_1_OFFSET).
    var mem = @embedFile("nvs_testdata/idf_blob_written.bin").*;
    var flash: TestFlash = .{ .mem = &mem };
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    for (0..3) |chunk| try testing.expectEqual(@as(u8, @intCast(chunk)), (try store.find(1, type_blob_data, "big", @intCast(chunk))).?.page);
    mem = @embedFile("nvs_testdata/idf_blob_rewritten.bin").*;
    try store.init(&flash, mem.len);
    const index = (try store.item_at((try store.find(1, type_blob_index, "big", no_chunk)).?)).*;
    try testing.expectEqual(@as(u8, 2), index.data[4]);
    try testing.expectEqual(@as(u8, 0x80), index.data[5]);
    try testing.expectEqual(@as(u8, 2), (try store.find(1, type_blob_data, "big", 0x80)).?.page);
    try testing.expectEqual(@as(u8, 3), (try store.find(1, type_blob_data, "big", 0x81)).?.page);
}

test "erasing an ESP-IDF multi-page blob leaves the partition ESP-IDF's erase leaves" {
    // blob_fixture.cpp made idf_blob_erased.bin from idf_blob_rewritten.bin
    // with `Storage::eraseItem` and purging: the index, then each chunk.
    var mem = @embedFile("nvs_testdata/idf_blob_rewritten.bin").*;
    var flash: TestFlash = .{ .mem = &mem };
    var store: TestStorage = undefined;
    try store.init(&flash, mem.len);
    try testing.expectEqualSlices(u8, @embedFile("nvs_testdata/idf_blob_rewritten.bin"), &mem);
    try (try store.open("fixture", .read_write_purge)).erase_key("big");
    try testing.expectEqualSlices(u8, @embedFile("nvs_testdata/idf_blob_erased.bin"), &mem);
}

test "ESP-IDF multi-page blobs can be rewritten, erased and reclaimed" {
    inline for (.{ "written", "rewriting", "rewritten" }) |name| {
        errdefer std.debug.print("idf_blob_{s}.bin\n", .{name});
        var mem = @embedFile("nvs_testdata/idf_blob_" ++ name ++ ".bin").*;
        var flash: TestFlash = .{ .mem = &mem };
        var store: TestStorage = undefined;
        try store.init(&flash, mem.len);
        const h = try store.open("fixture", .read_write);
        var buf: [9000]u8 = undefined;
        const current: []const u8 = if (comptime std.mem.eql(u8, name, "rewritten")) &idf_blob_second else &idf_blob_first;
        // Fill the partition with distinct live keys. Reclaim takes the full
        // page with the fewest live entries, so once the filler's own pages
        // are full of live keys, pages ESP-IDF left with erased entries next
        // to chunks (its purges, or the orphans init dropped) are reclaimed
        // and those chunks copied. The written partition has no erased
        // entries: there the store just fills up, and no chunk moves.
        const chunk_start = (try store.item_at((try store.find(h.ns, type_blob_index, "big", no_chunk)).?)).data[5];
        var before: [3]?u8 = @splat(null);
        for (&before, 0..) |*page, i| page.* = if (try store.find(h.ns, type_blob_data, "big", chunk_start + @as(u8, @intCast(i)))) |loc| loc.page else null;
        var keys: u32 = 0;
        while (true) : (keys += 1) {
            var key: [15]u8 = undefined;
            h.set(u32, try std.fmt.bufPrint(&key, "k{d}", .{keys}), keys) catch |err| switch (err) {
                error.NotEnoughSpace => break,
                else => return err,
            };
        }
        try testing.expect(keys > 100);
        var moved = false;
        for (before, 0..) |page, i| {
            const now = if (try store.find(h.ns, type_blob_data, "big", chunk_start + @as(u8, @intCast(i)))) |loc| loc.page else null;
            try testing.expectEqual(page == null, now == null);
            moved = moved or page != now;
        }
        try testing.expectEqual(comptime !std.mem.eql(u8, name, "written"), moved);
        try store.init(&flash, mem.len);
        try check_idf_blob(&store, current);
        for (0..keys) |i| {
            var key: [15]u8 = undefined;
            const filler = try std.fmt.bufPrint(&key, "k{d}", .{i});
            try testing.expectEqual(@as(u32, @intCast(i)), try h.get(u32, filler));
            try h.erase_key(filler);
        }

        const replacement = idf_blob_pattern(3000, 0x33);
        try h.set_blob("big", &replacement);
        try store.init(&flash, mem.len);
        try check_idf_blob(&store, &replacement);
        try h.erase_key("big");
        try store.init(&flash, mem.len);
        try check_idf_blob(&store, null);
        try testing.expectError(error.NotFound, (try store.open("fixture", .read_only)).get_blob("big", &buf));
    }
}
