const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const FamilyId = @import("family_id.zig").FamilyId;

const prog_page_size = 256;

pub const FileEntry = struct {
    name: []const u8,
    start_block: u64,
    end_block: u64,
    family_id: ?FamilyId,
};

pub const Archive = struct {
    allocator: Allocator,
    io: std.Io,
    blocks: std.ArrayList(Block),
    families: std.AutoArrayHashMapUnmanaged(FamilyId, void),
    files: std.ArrayList(FileEntry),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Archive {
        return .{ .allocator = allocator, .blocks = .empty, .families = .empty, .files = .empty, .io = io };
    }

    pub fn deinit(self: *Archive) void {
        self.blocks.deinit(self.allocator);
        self.families.deinit(self.allocator);
        for (self.files.items) |*file| {
            self.allocator.free(file.name);
        }
        self.files.deinit(self.allocator);
    }

    pub fn write_to(self: *Archive, writer: *std.Io.Writer) !void {
        for (self.blocks.items, 0..) |*block, i| {
            block.block_number = @as(u32, @intCast(i));
            block.total_blocks = @as(u32, @intCast(self.blocks.items.len));
            try writer.writeStruct(block.*, .little);
        }
        try writer.flush();
    }

    pub const ReadFromOptions = struct {
        /// If true, checks if any new block has a family_id already present in
        /// the archive.
        check_family_id_collision: bool = true,
    };

    /// Reads UF2 blocks from a reader. Reader buffer size must be at least 512
    /// bytes.
    pub fn read_from(self: *Archive, reader: *std.Io.Reader, options: ReadFromOptions) !void {
        var new_family_ids: std.AutoArrayHashMapUnmanaged(FamilyId, void) = .empty;
        defer new_family_ids.deinit(self.allocator);

        while (reader.takeStruct(Block, .little)) |block| {
            if (block.flags.family_id_present) {
                const family_id = block.file_size_or_family_id.family_id;

                // Check if family id is already present in the archive
                if (try new_family_ids.fetchPut(self.allocator, family_id, {}) == null and
                    try self.families.fetchPut(self.allocator, family_id, {}) != null)
                {
                    if (options.check_family_id_collision) {
                        return error.FamilyIdCollision;
                    }
                }
            }

            try self.blocks.append(self.allocator, block);
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }

    pub const ELF_Options = struct {
        // TODO: when implemented set to true by default
        bundle_source: bool = false,
        family_id: ?FamilyId = null,
    };

    /// Adds an elf to the archive. Returns error if the family id (if
    /// specified) is already present in the archive.
    ///
    /// Returns `error.ElfHeadersInSegment` for a LOAD segment that takes in the ELF header
    /// or the program header table. A linker makes such a segment when the page of the
    /// first section has room for the headers below it, at an address the image does not
    /// own: for firmware that starts at 0x26000, with 64 KiB pages, at 0x20000.
    pub fn add_elf(self: *Archive, reader: *std.Io.File.Reader, opts: ELF_Options) !void {
        if (opts.family_id) |family_id|
            if (self.families.contains(family_id))
                return error.FamilyIdCollision;

        const Segment = struct {
            addr: u32,
            file_offset: u32,
            size: u32,

            fn less_than(_: void, lhs: @This(), rhs: @This()) bool {
                return lhs.addr < rhs.addr;
            }
        };

        var segments: std.ArrayList(Segment) = .empty;
        defer segments.deinit(self.allocator);

        const header = try std.elf.Header.read(&reader.interface);
        var it = header.iterateProgramHeaders(reader);
        while (try it.next()) |prog_hdr|
            if (prog_hdr.type == std.elf.PT.LOAD and prog_hdr.memsz > 0 and prog_hdr.filesz > 0) {
                std.log.debug("segment: {}", .{prog_hdr});
                if (holds_elf_headers(&header, prog_hdr.offset, prog_hdr.filesz))
                    return error.ElfHeadersInSegment;
                try segments.append(self.allocator, .{
                    .addr = @as(u32, @intCast(prog_hdr.paddr)),
                    .file_offset = @as(u32, @intCast(prog_hdr.offset)),
                    .size = @as(u32, @intCast(prog_hdr.memsz)),
                });
            };

        if (segments.items.len == 0)
            return error.NoSegments;

        // Only now, so that an ELF file that was refused leaves its family id free.
        if (opts.family_id) |family_id|
            try self.families.put(self.allocator, family_id, {});

        std.sort.insertion(Segment, segments.items, {}, Segment.less_than);
        // TODO: check for overlaps, assert no zero sized segments

        var first = true;
        for (segments.items) |segment| {
            var segment_offset: u32 = 0;
            while (segment_offset < segment.size) {
                const addr = segment.addr + segment_offset;
                if (first or addr >= self.blocks.items[self.blocks.items.len - 1].target_addr + prog_page_size) {
                    try self.blocks.append(self.allocator, .{
                        .flags = .{
                            .not_main_flash = false,
                            .file_container = false,
                            .family_id_present = opts.family_id != null,
                            .md5_checksum_present = false,
                            .extension_tags_present = false,
                        },
                        .target_addr = std.mem.alignBackward(u32, addr, prog_page_size),
                        .payload_size = prog_page_size,
                        .block_number = undefined,
                        .total_blocks = undefined,
                        .file_size_or_family_id = .{
                            .family_id = if (opts.family_id) |family_id|
                                family_id
                            else
                                @as(FamilyId, @fromBackingInt(0)),
                        },
                        .data = @splat(0),
                    });
                    first = false;
                }

                const block = &self.blocks.items[self.blocks.items.len - 1];
                const block_offset = addr - block.target_addr;
                const n_bytes = @min(prog_page_size - block_offset, segment.size - segment_offset);

                try reader.seekTo(segment.file_offset + segment_offset);
                try reader.interface.readSliceAll(block.data[block_offset..][0..n_bytes]);

                segment_offset += n_bytes;
            }
        }

        if (opts.bundle_source)
            @panic("TODO: bundle source in UF2 file");
    }

    /// Whether `filesz` bytes of the file at `offset` take in any of the ELF header or of
    /// the program header table.
    fn holds_elf_headers(header: *const std.elf.Header, offset: u64, filesz: u64) bool {
        const ehsize: u64 = if (header.is_64) @sizeOf(std.elf.Elf64.Ehdr) else @sizeOf(std.elf.Elf32.Ehdr);
        const phsize = @as(u64, header.phentsize) * header.phnum;
        const end = offset + filesz;
        return offset < ehsize or (offset < header.phoff + phsize and header.phoff < end);
    }

    pub fn add_file(self: *Archive, path: []const u8) !void {
        if (self.has_file(path)) return error.FileAlreadyAdded;
        const file = if (std.fs.path.isAbsolute(path))
            try std.Io.Dir.openFileAbsolute(self.io, path, .{})
        else
            try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);

        const file_size = @as(u32, @intCast((try file.stat(self.io)).size));
        const start_block = @as(u32, @intCast(self.blocks.items.len));

        var path_pos: u32 = 0;

        var target_addr: u32 = 0;
        var read_buf: [512]u8 = undefined;
        var reader = file.reader(self.io, &read_buf);
        while (true) {
            try self.blocks.append(self.allocator, .{
                .flags = .{
                    .not_main_flash = true,
                    .file_container = true,
                    .family_id_present = false,
                    .md5_checksum_present = false,
                    .extension_tags_present = false,
                },
                .target_addr = target_addr,
                .payload_size = 0,
                .block_number = undefined,
                .total_blocks = undefined,
                .file_size_or_family_id = .{
                    .file_size = file_size,
                },
                .data = undefined,
            });
            errdefer _ = self.blocks.pop();

            const block = &self.blocks.items[self.blocks.items.len - 1];
            if (target_addr < file_size) {
                // copying file content into block
                const n_read = try reader.interface.readSliceShort(block.data[0..]);
                target_addr += @as(u32, @intCast(n_read));
                block.payload_size = @as(u32, @intCast(n_read));
                if (n_read < block.data.len) {
                    const copy_len = @min(block.data.len - n_read, path.len);
                    path_pos = @intCast(copy_len);
                    @memcpy(block.data[n_read..][0..copy_len], path[0..copy_len]);
                    if (n_read + copy_len < block.data.len) {
                        block.data[n_read + copy_len] = 0;
                        break;
                    }
                }
            } else {
                // File fully read, copy remaining path
                const copy_len = @min(block.data.len, path.len - path_pos);
                @memcpy(block.data[0..copy_len], path[path_pos..][0..copy_len]);
                path_pos += @intCast(copy_len);
                if (copy_len < block.data.len) {
                    block.data[copy_len] = 0;
                    break;
                }
            }
        }
        // add file record
        try self.files.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, path),
            .start_block = start_block,
            .end_block = @as(u32, @intCast(self.blocks.items.len)),
            .family_id = null,
        });
    }

    pub fn get_files(self: *const Archive) []const FileEntry {
        return self.files.items;
    }

    pub fn has_file(self: *const Archive, name: []const u8) bool {
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.name, name)) {
                return true;
            }
        }
        return false;
    }

    pub fn get_file(self: *const Archive, name: []const u8) ?FileEntry {
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.name, name)) {
                return file;
            }
        }
        return null;
    }

    pub fn get_file_blocks(self: *const Archive, file_index: usize) ?struct { start: u64, end: u64 } {
        if (file_index >= self.files.items.len) return null;
        const file = self.files.items[file_index];
        return .{
            .start = file.start_block,
            .end = file.end_block,
        };
    }

    pub fn print_files(self: *const Archive) void {
        std.log.info("Archive contains {d} files:", .{self.files.items.len});
        for (self.files.items, 0..) |file, i| {
            const blocks = file.end_block - file.start_block;
            std.log.info("  [{d}] {s}: {d} blocks", .{ i, file.name, blocks });
        }
    }
};

pub const Flags = packed struct(u32) {
    not_main_flash: bool,
    reserved: u11 = 0,
    file_container: bool,
    family_id_present: bool,
    md5_checksum_present: bool,
    extension_tags_present: bool,
    padding: u16 = 0,
};

const first_magic = 0x0a324655;
const second_magic = 0x9e5d5157;
const last_magic = 0x0ab16f30;

pub const Block = extern struct {
    magic_start1: u32 = first_magic,
    magic_start2: u32 = second_magic,
    flags: Flags,
    target_addr: u32,
    payload_size: u32,
    block_number: u32,
    total_blocks: u32,
    file_size_or_family_id: extern union {
        file_size: u32,
        /// From uf2 documentation:
        ///
        /// > It is recommended that new bootloaders require the field to be
        ///   set appropriately, and refuse to flash UF2 files without it
        ///
        /// So if your chip is not in the official list, then PR it or don't
        /// follow this recommendation in your bootloader
        family_id: FamilyId,
    },
    data: [476]u8,
    magic_end: u32 = last_magic,

    comptime {
        assert(512 == @sizeOf(Block));
    }
};

test "Archive read and write" {
    const data_1_block_1: Block = .{
        .flags = .{
            .not_main_flash = false,
            .file_container = false,
            .family_id_present = true,
            .md5_checksum_present = false,
            .extension_tags_present = false,
        },
        .target_addr = 0x10000000,
        .payload_size = prog_page_size,
        .block_number = undefined,
        .total_blocks = undefined,
        .file_size_or_family_id = .{
            .family_id = .RP2040,
        },
        .data = @splat(0),
    };
    const data_1_block_2: Block = .{
        .flags = .{
            .not_main_flash = false,
            .file_container = false,
            .family_id_present = true,
            .md5_checksum_present = false,
            .extension_tags_present = false,
        },
        .target_addr = 0x10000000,
        .payload_size = prog_page_size,
        .block_number = undefined,
        .total_blocks = undefined,
        .file_size_or_family_id = .{
            .family_id = .RP2350_ARM_S,
        },
        .data = @splat(0),
    };
    const data_2_block_1: Block = .{
        .flags = .{
            .not_main_flash = false,
            .file_container = false,
            .family_id_present = true,
            .md5_checksum_present = false,
            .extension_tags_present = false,
        },
        .target_addr = 0x10000100,
        .payload_size = prog_page_size,
        .block_number = 1,
        .total_blocks = 2,
        .file_size_or_family_id = .{
            .family_id = .RP2350_ARM_S,
        },
        .data = @splat(0),
    };

    var data_1: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data_1.deinit();
    try data_1.writer.writeStruct(data_1_block_1, .little);
    try data_1.writer.writeStruct(data_1_block_2, .little);

    var data_2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data_2.deinit();
    try data_2.writer.writeStruct(data_2_block_1, .little);

    var data_1_reader: std.Io.Reader = .fixed(data_1.written());

    var archive = Archive.init(std.testing.allocator, std.testing.io);
    defer archive.deinit();

    try archive.read_from(&data_1_reader, .{});

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try archive.write_to(&output.writer);

    try std.testing.expectEqualSlices(FamilyId, archive.families.keys(), &.{ .RP2040, .RP2350_ARM_S });

    // these are set by write_to
    std.mem.writeInt(u32, data_1.written()[@offsetOf(Block, "block_number")..][0..4], 0, .little);
    std.mem.writeInt(u32, data_1.written()[@offsetOf(Block, "total_blocks")..][0..4], 2, .little);
    std.mem.writeInt(u32, data_1.written()[@sizeOf(Block)..][@offsetOf(Block, "block_number")..][0..4], 1, .little);
    std.mem.writeInt(u32, data_1.written()[@sizeOf(Block)..][@offsetOf(Block, "total_blocks")..][0..4], 2, .little);
    try std.testing.expectEqualSlices(u8, data_1.written(), output.written());

    // test name collisions
    var data_2_reader: std.Io.Reader = .fixed(data_2.written());
    try std.testing.expectError(error.FamilyIdCollision, archive.read_from(&data_2_reader, .{}));
}
test "File tracking - basic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var archive = Archive.init(allocator, io);
    defer archive.deinit();

    // Create temporary test files
    {
        var file = try std.Io.Dir.cwd().createFile(io, "test1.uf2", .{});
        defer file.close(io);
        // Write at least one block, then more data
        var buf: [512]u8 = @splat(0);
        var writer_buf: [512]u8 = undefined;
        var writer = file.writer(io, &writer_buf);
        try writer.interface.writeAll(&buf);
        try writer.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(io, "test1.uf2") catch {};

    {
        var file = try std.Io.Dir.cwd().createFile(io, "test2.uf2", .{});
        defer file.close(io);
        var buf: [512]u8 = @splat(0);
        var writer_buf: [512]u8 = undefined;
        var writer = file.writer(io, &writer_buf);
        try writer.interface.writeAll(&buf);
        try writer.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(io, "test2.uf2") catch {};

    // Add test files
    try archive.add_file("test1.uf2");
    try archive.add_file("test2.uf2");

    // Verify file records
    try std.testing.expectEqual(@as(usize, 2), archive.files.items.len);
    try std.testing.expectEqualStrings("test1.uf2", archive.files.items[0].name);
    try std.testing.expectEqualStrings("test2.uf2", archive.files.items[1].name);

    // Verify block range
    const file1_blocks = archive.get_file_blocks(0).?;
    try std.testing.expect(file1_blocks.start < file1_blocks.end);

    // Test duplicate detection
    try std.testing.expectError(error.FileAlreadyAdded, archive.add_file("test1.uf2"));

    // Test has_file
    try std.testing.expect(archive.has_file("test1.uf2"));
    try std.testing.expect(!archive.has_file("test3.uf2"));
}
test "File tracking - comprehensive" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var archive = Archive.init(allocator, io);
    defer archive.deinit();

    // Create test files
    {
        var file = try std.Io.Dir.cwd().createFile(io, "test1.uf2", .{});
        defer file.close(io);
        // Write more than 476 bytes (triggers multiple blocks)
        var buf: [1024]u8 = @splat(0x41); // Fill with 'A'
        var writer_buf: [1024]u8 = undefined;
        var writer = file.writer(io, &writer_buf);
        try writer.interface.writeAll(&buf);
        try writer.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(io, "test1.uf2") catch {};

    {
        var file = try std.Io.Dir.cwd().createFile(io, "test2.uf2", .{});
        defer file.close(io);
        var buf: [512]u8 = @splat(0x42); // Fill with 'B'
        var writer_buf: [512]u8 = undefined;
        var writer = file.writer(io, &writer_buf);
        try writer.interface.writeAll(&buf);
        try writer.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(io, "test2.uf2") catch {};

    // Test 1: Add files
    try archive.add_file("test1.uf2");
    try archive.add_file("test2.uf2");
    try std.testing.expectEqual(@as(usize, 2), archive.files.items.len);

    // Test 2: Verify block ranges don't overlap
    const file1 = archive.get_file_blocks(0).?;
    const file2 = archive.get_file_blocks(1).?;
    try std.testing.expect(file1.end <= file2.start);

    // Test 3: Verify block data
    const block0 = archive.blocks.items[file1.start];
    try std.testing.expectEqual(@as(u8, 0x41), block0.data[0]); // File 1 data
    if (block0.payload_size < block0.data.len) {
        try std.testing.expectEqual(@as(u8, 0), block0.data[block0.payload_size]); // null terminator
    }

    // Test 4: Duplicate detection
    try std.testing.expectError(error.FileAlreadyAdded, archive.add_file("test1.uf2"));

    // Test 5: has_file
    try std.testing.expect(archive.has_file("test1.uf2"));
    try std.testing.expect(!archive.has_file("nonexistent.uf2"));

    // Test 6: get_files
    const files = archive.get_files();
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("test1.uf2", files[0].name);
}

test "File tracking - deinit cleanup" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var archive = Archive.init(allocator, io);

    // Add file
    {
        var file = try std.Io.Dir.cwd().createFile(io, "cleanup_test.uf2", .{});
        defer file.close(io);
        var buf: [512]u8 = @splat(0);
        var writer_buf: [512]u8 = undefined;
        var writer = file.writer(io, &writer_buf);
        try writer.interface.writeAll(&buf);
        try writer.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(io, "cleanup_test.uf2") catch {};

    try archive.add_file("cleanup_test.uf2");
    try std.testing.expectEqual(@as(usize, 1), archive.files.items.len);

    // deinit should free all memory
    archive.deinit();

    // Reinitialize to verify no memory leak
    var archive2 = Archive.init(allocator, io);
    defer archive2.deinit();
    try std.testing.expectEqual(@as(usize, 0), archive2.files.items.len);
}

test "File tracking - long path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var archive = Archive.init(allocator, io);
    defer archive.deinit();

    // Create a file that's almost a full block (476 bytes), so that
    // even a short path requires crossing into a new block.
    // remaining space = 476 - file_size, path must exceed this.
    const file_size = 400;
    const path_len = 77; // 77 > 476 - 400 = 76, crosses block boundary

    var long_name_buf: [path_len]u8 = undefined;
    @memset(long_name_buf[0 .. path_len - 4], 'x');
    @memcpy(long_name_buf[path_len - 4 ..], ".uf2");
    const long_name = long_name_buf[0..path_len];
    {
        var file = try std.Io.Dir.cwd().createFile(io, long_name, .{});
        defer file.close(io);
        var buf: [file_size]u8 = @splat(0);
        var writer_buf: [512]u8 = undefined;
        var writer = file.writer(io, &writer_buf);
        try writer.interface.writeAll(&buf);
        try writer.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(io, long_name) catch {};

    try archive.add_file(long_name);
    try std.testing.expectEqual(@as(usize, 1), archive.files.items.len);
    try std.testing.expectEqualStrings(long_name, archive.files.items[0].name);

    // Verify path spans multiple blocks
    const file_blocks = archive.get_file_blocks(0).?;
    try std.testing.expect(file_blocks.end > file_blocks.start);
}

/// A 32-bit little-endian ELF file of 0x100 bytes whose program header table, right after
/// the ELF header, has `segments` as LOAD segments. Byte n of the file past the headers is n.
fn test_elf(comptime segments: []const struct { offset: u32, paddr: u32, size: u32 }) [0x100]u8 {
    var elf: [0x100]u8 = undefined;
    for (&elf, 0..) |*byte, n| byte.* = @intCast(n);
    const ehsize = @sizeOf(std.elf.Elf32.Ehdr);
    const phentsize = @sizeOf(std.elf.Elf32.Phdr);
    @memset(elf[0 .. ehsize + segments.len * phentsize], 0);
    @memcpy(elf[0..7], "\x7fELF\x01\x01\x01"); // magic, 32-bit, little-endian, version 1
    std.mem.writeInt(u16, elf[0x10..0x12], 2, .little); // e_type: executable
    std.mem.writeInt(u16, elf[0x12..0x14], 40, .little); // e_machine: Arm
    std.mem.writeInt(u32, elf[0x14..0x18], 1, .little); // e_version
    std.mem.writeInt(u32, elf[0x1c..0x20], ehsize, .little); // e_phoff
    std.mem.writeInt(u16, elf[0x28..0x2a], ehsize, .little); // e_ehsize
    std.mem.writeInt(u16, elf[0x2a..0x2c], phentsize, .little); // e_phentsize
    std.mem.writeInt(u16, elf[0x2c..0x2e], segments.len, .little); // e_phnum
    for (segments, 0..) |segment, i| {
        const phdr = elf[ehsize + i * phentsize ..][0..phentsize];
        std.mem.writeInt(u32, phdr[0x00..0x04], 1, .little); // p_type: LOAD
        std.mem.writeInt(u32, phdr[0x04..0x08], segment.offset, .little); // p_offset
        std.mem.writeInt(u32, phdr[0x08..0x0c], segment.paddr, .little); // p_vaddr
        std.mem.writeInt(u32, phdr[0x0c..0x10], segment.paddr, .little); // p_paddr
        std.mem.writeInt(u32, phdr[0x10..0x14], segment.size, .little); // p_filesz
        std.mem.writeInt(u32, phdr[0x14..0x18], segment.size, .little); // p_memsz
        std.mem.writeInt(u32, phdr[0x18..0x1c], 4, .little); // p_flags: R
        std.mem.writeInt(u32, phdr[0x1c..0x20], 4, .little); // p_align
    }
    return elf;
}

fn add_test_elf(archive: *Archive, name: []const u8, elf: []const u8) !void {
    const io = std.testing.io;
    const file = try std.Io.Dir.cwd().createFile(io, name, .{});
    // Once the file exists it is deleted on every path, and a failed delete is reported.
    const result = write_then_add(io, archive, file, name, elf);
    try std.Io.Dir.cwd().deleteFile(io, name);
    return result;
}

fn write_then_add(io: std.Io, archive: *Archive, created: std.Io.File, name: []const u8, elf: []const u8) !void {
    {
        var file = created;
        defer file.close(io);
        var writer_buf: [512]u8 = undefined;
        var writer = file.writer(io, &writer_buf);
        try writer.interface.writeAll(elf);
        try writer.flush();
    }
    const file = try std.Io.Dir.cwd().openFile(io, name, .{});
    defer file.close(io);
    var reader_buf: [1024]u8 = undefined;
    var reader = file.reader(io, &reader_buf);
    return archive.add_elf(&reader, .{ .family_id = .NRF52840 });
}

test "add_elf - a segment of firmware" {
    var archive = Archive.init(std.testing.allocator, std.testing.io);
    defer archive.deinit();

    const elf = comptime test_elf(&.{.{ .offset = 0x80, .paddr = 0x26000, .size = 0x10 }});
    try add_test_elf(&archive, "test_firmware.elf", &elf);

    try std.testing.expectEqual(1, archive.blocks.items.len);
    try std.testing.expectEqual(0x26000, archive.blocks.items[0].target_addr);
    try std.testing.expectEqualSlices(u8, elf[0x80..0x90], archive.blocks.items[0].data[0..0x10]);
}

// What a linker with 64 KiB pages makes of firmware that starts at 0x26000: the ELF header
// and the program header table in a segment at the start of the page, 0x20000.
test "add_elf - a segment with the ELF file's headers" {
    var archive = Archive.init(std.testing.allocator, std.testing.io);
    defer archive.deinit();

    const elf = comptime test_elf(&.{
        .{ .offset = 0, .paddr = 0x20000, .size = 0x74 },
        .{ .offset = 0x80, .paddr = 0x26000, .size = 0x10 },
    });
    try std.testing.expectError(error.ElfHeadersInSegment, add_test_elf(&archive, "test_headers.elf", &elf));
    try std.testing.expectEqual(0, archive.blocks.items.len);

    // The family id is still free: the same archive takes the firmware linked without pages.
    const relinked = comptime test_elf(&.{.{ .offset = 0x80, .paddr = 0x26000, .size = 0x10 }});
    try add_test_elf(&archive, "test_relinked.elf", &relinked);
    try std.testing.expectEqual(1, archive.blocks.items.len);
}

test "add_elf - a segment that starts inside the program header table" {
    var archive = Archive.init(std.testing.allocator, std.testing.io);
    defer archive.deinit();

    const elf = comptime test_elf(&.{.{ .offset = 0x40, .paddr = 0x26000, .size = 0x50 }});
    try std.testing.expectError(error.ElfHeadersInSegment, add_test_elf(&archive, "test_phdrs.elf", &elf));
}
