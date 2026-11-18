//! Raw, unencrypted ESP32-C3/C6 flash access. Call after HAL initialization, from
//! task context, with no concurrent SPI1 users. No allocation or MMU changes.
//! Offsets and lengths must be multiples of four; erase offsets are 4 KiB aligned.

const compatibility = @import("compatibility.zig");
const impl = switch (compatibility.chip) {
    .esp32_c3 => @import("flash/esp32_c3.zig"),
    .esp32_c6 => @import("flash/esp32_c6.zig"),
};

const std = @import("std");
const microzig = @import("microzig");
const rom = @import("rom.zig").functions;
const FlashChip = @import("rom.zig").FlashChip;
extern const _start: u8;
extern const microzig_data_start: u8;
extern const microzig_data_end: u8;

pub const sector_size = 4096;
pub const Error = error{ OutOfBounds, Unaligned, RunningImage, UnsupportedFlash, RomFailure, Timeout };
pub const Options = struct {
    /// Optional caller-owned snapshots, populated even when initialization fails.
    diagnostics: ?*Diagnostics = null,
    /// Destructive opt-in, including bootloader and application bytes. The
    /// caller must ensure it never erases code/data needed after this call.
    allow_running_image: bool = false,
};

pub const Diagnostics = struct {
    before: FlashChip = std.mem.zeroes(FlashChip),
    after: FlashChip = std.mem.zeroes(FlashChip),
    raw_rdid: u32 = 0,
    attached: bool = false,
};

pub const Flash = struct {
    size: u32,
    protected_end: u32,
    allow_running_image: bool,

    /// Reads JEDEC ID independently of the bootloader's ROM descriptor.
    /// Retains a valid descriptor's smaller addressing limit.
    pub fn init(options: Options) Error!Flash {
        const chip = rom.rom_spiflash_legacy_data.*;
        var diagnostics: Diagnostics = .{ .before = chip, .after = chip };
        defer if (options.diagnostics) |dest| {
            diagnostics.after = rom.rom_spiflash_legacy_data.*;
            dest.* = diagnostics;
        };
        // RAM boot has no guarantee that SPI1 or its pads were attached.
        // Direct/ESP boot already has a working cache mapping; attach only
        // when the legacy descriptor is incomplete, leaving MMU state alone.
        diagnostics.attached = microzig.config.ram_image or !valid_geometry(chip) or
            (detected_size(chip.device_id, 0) catch 0) == 0;
        try result(impl.probe(diagnostics.attached, &diagnostics.raw_rdid));
        const id = normalized_id(diagnostics.raw_rdid);
        const size = try initialization_size(id, chip, diagnostics.attached);
        // ESP-IDF v5.4 bootloader_flash_config_esp32c3.c / esp32c6.c:
        // bootloader_flash_hardware_init attaches before RDID; update_flash_config
        // sets 64 KiB blocks, 4 KiB sectors, 256-byte pages and mask 0xffff.
        // https://github.com/espressif/esp-idf/blob/v5.4/components/bootloader_support/bootloader_flash/src/bootloader_flash_config_esp32c3.c
        try result(impl.configure(id, size));
        var self: Flash = .{
            .size = size,
            .protected_end = 0,
            .allow_running_image = options.allow_running_image,
        };
        if (!valid_geometry(rom.rom_spiflash_legacy_data.*) or
            rom.rom_spiflash_legacy_data.device_id != id or
            rom.rom_spiflash_legacy_data.chip_size != size)
            return error.UnsupportedFlash;
        self.protected_end = try self.image_end();
        return self;
    }

    /// Buffers need not be aligned. Only the private, aligned RAM bounce buffer
    /// is passed to ROM, so flash-backed sources remain safe with cache off.
    pub fn read(self: Flash, offset: u32, dest: []u8) Error!void {
        try self.check_range(offset, dest.len, false);
        var words: [64]u32 = undefined;
        const bytes = std.mem.asBytes(&words);
        var done: usize = 0;
        while (done < dest.len) {
            const len = @min(bytes.len, dest.len - done);
            try result(impl.transaction(.read, offset + @as(u32, @intCast(done)), &words, @intCast(len)));
            @memcpy(dest[done..][0..len], bytes[0..len]);
            done += len;
        }
    }

    /// Programming only clears bits, including when a source bit is one over
    /// an existing zero. Erase first to restore ones. Partial writes on errors
    /// are possible; no automatic retry or erase is performed.
    pub fn write(self: Flash, offset: u32, src: []const u8) Error!void {
        try self.check_range(offset, src.len, true);
        var words: [64]u32 = undefined;
        const bytes = std.mem.asBytes(&words);
        var done: usize = 0;
        while (done < src.len) {
            const len = @min(bytes.len, src.len - done);
            const address = offset + @as(u32, @intCast(done));
            try result(impl.transaction(.read, address, &words, @intCast(len)));
            // Both reading the source and combining bytes happen cache-on.
            for (bytes[0..len], src[done..][0..len]) |*old, new| old.* &= new;
            try result(impl.transaction(.write, address, &words, @intCast(len)));
            done += len;
        }
    }

    pub fn erase_sector(self: Flash, offset: u32) Error!void {
        if (offset % sector_size != 0) return error.Unaligned;
        try self.check_range(offset, sector_size, true);
        var unused: [64]u32 = undefined;
        try result(impl.transaction(.erase, offset, &unused, 0));
    }

    fn check_range(self: Flash, offset: u32, len: usize, modifying: bool) Error!void {
        if (offset > self.size or len > self.size - offset) return error.OutOfBounds;
        if (offset % 4 != 0 or len % 4 != 0) return error.Unaligned;
        if (modifying and len != 0 and !self.allow_running_image and offset < self.protected_end)
            return error.RunningImage;
    }

    fn image_end(self: Flash) Error!u32 {
        if (microzig.config.ram_image) return 0; // This image is entirely in RAM.
        const entry = @intFromPtr(&_start);
        if (entry == 0x4200_0008) {
            // Direct-boot linker: RAM text and initialized data follow rodata
            // in the binary; microzig_data_start includes the RAM text alias.
            const load = @extern(*const u8, .{ .name = "microzig_data_load_start", .linkage = .weak });
            const start = @intFromPtr(load);
            const drom: usize = switch (compatibility.chip) {
                .esp32_c3 => 0x3c00_0000,
                .esp32_c6 => 0x4200_0000,
            };
            if (start < drom or start > drom + 0x800000) return self.size;
            const end = start - drom + @intFromPtr(&microzig_data_end) - @intFromPtr(&microzig_data_start);
            return if (end <= self.size) @intCast(end) else self.size;
        }

        return esp_image_end(self, @intCast(entry));
    }
};

// The reader is either the device or a byte-backed image in host tests.
fn esp_image_end(self: anytype, entry: u32) Error!u32 {
    // ESP images can contain RAM segments after the mapped segments. Scan
    // sector-aligned image headers and protect ALL images with our entry
    // point (conservative for OTA copies), including checksum and digest.
    // Layout: tools/esp-image/src/elf2image.zig, ImageHeader and write_to.
    var end: u32 = 0;
    var base: u32 = 0;
    while (base <= self.size - 24) : (base += sector_size) {
        var header: [24]u8 = undefined;
        try self.read(base, &header);
        if (header[0] != 0xe9 or header[1] == 0 or header[1] > 16 or
            std.mem.readInt(u32, header[4..8], .little) != entry) continue;
        var cursor = base + 24;
        for (0..header[1]) |_| {
            if (cursor > self.size - 8) return self.size;
            var segment: [8]u8 = undefined;
            try self.read(cursor, &segment);
            const len = std.mem.readInt(u32, segment[4..8], .little);
            if (len % 4 != 0 or len > self.size - cursor - 8) return self.size;
            cursor += 8 + len;
        }
        // Checksum is the last byte of the next 16-byte boundary.
        const trailer_end = (@as(u64, cursor) + 16) & ~@as(u64, 15);
        const image_limit = trailer_end + @as(u64, if (header[23] != 0) 32 else 0);
        if (image_limit > self.size) return self.size;
        end = @max(end, @as(u32, @intCast(image_limit)));
    }
    return if (end == 0) self.size else end;
}

fn detected_size(id: u32, configured: u32) Error!u32 {
    const capacity: u8 = @truncate(id);
    const manufacturer: u8 = @truncate(id >> 16);
    // Conventional JEDEC capacity encoding; at most 16 MiB addressed
    // (C3 TRM v1.4 §3.3.3.1; C6 TRM v1.2 §5.3.3.1). Reject absent/unsupported IDs, not a guess.
    // ESP-IDF bootloader_read_flash_id normalizes RDID to manufacturer in
    // bits 23:16 and capacity in bits 7:0 (not SPI receive-register order).
    if (manufacturer == 0 or manufacturer == 0xff or capacity < 18 or capacity > 24)
        return error.UnsupportedFlash;
    const size = @as(u32, 1) << @as(u5, @intCast(capacity));
    if (configured == 0) return size;
    if (configured < sector_size or configured % sector_size != 0) return error.UnsupportedFlash;
    return @min(size, configured);
}

fn valid_geometry(chip: FlashChip) bool {
    return chip.chip_size >= sector_size and chip.chip_size <= 0x1000000 and
        chip.chip_size % sector_size == 0 and chip.block_size == 0x10000 and
        chip.sector_size == sector_size and chip.page_size == 256 and chip.status_mask == 0xffff;
}

fn initialization_size(id: u32, chip: FlashChip, attached: bool) Error!u32 {
    // Only a complete, matching record from an already attached boot path
    // supplies a meaningful size limit. RAM boot's ROM defaults do not.
    const configured = if (!attached and valid_geometry(chip) and chip.device_id == id) chip.chip_size else 0;
    return detected_size(id, configured);
}

fn normalized_id(raw: u32) u32 {
    return ((raw & 0xff) << 16) | (raw & 0xff00) | ((raw >> 16) & 0xff);
}

fn result(rc: u32) Error!void {
    return switch (rc) {
        0 => {},
        2 => error.Timeout,
        else => error.RomFailure,
    };
}

test "bounds, overflow, alignment and image protection precede flash operations" {
    const flash: Flash = .{ .size = 0x400000, .protected_end = 0x21001, .allow_running_image = false };
    try flash.check_range(0x3f0000, 4096, true);
    try flash.check_range(flash.size, 0, true);
    try flash.check_range(0, 4, false);
    try std.testing.expectError(error.OutOfBounds, flash.check_range(0xfffffffc, 4, false));
    try std.testing.expectError(error.OutOfBounds, flash.check_range(0x3ffffc, 8, true));
    try std.testing.expectError(error.OutOfBounds, flash.check_range(4, std.math.maxInt(usize), false));
    try std.testing.expectError(error.Unaligned, flash.check_range(1, 4, false));
    try std.testing.expectError(error.Unaligned, flash.check_range(4, 3, false));
    try std.testing.expectError(error.RunningImage, flash.check_range(0x21000, 4096, true));
    var allowed = flash;
    allowed.allow_running_image = true;
    try allowed.check_range(0, 4096, true);
    try std.testing.expectError(error.OutOfBounds, allowed.check_range(flash.size, 4, true));
}

test "detected capacity caps ROM configuration and rejects absent chips" {
    // XMC 4 MiB board: received bytes 46 40 16, not a ROM-populated ID.
    const xmc = normalized_id(0x164046);
    try std.testing.expectEqual(@as(u32, 0x464016), xmc);
    try std.testing.expectEqual(@as(u32, 0x400000), try detected_size(xmc, 0));
    try std.testing.expectEqual(@as(u32, 0x200000), try detected_size(xmc, 0x200000));
    try std.testing.expectEqual(@as(u32, 0x400000), try detected_size(0xc84016, 0x1000000));
    try std.testing.expectEqual(@as(u32, 0x200000), try detected_size(0xc84016, 0x200000));
    try std.testing.expectError(error.UnsupportedFlash, detected_size(0xffffff, 0x400000));
    try std.testing.expectError(error.UnsupportedFlash, detected_size(0, 0x400000));
    try std.testing.expectError(error.UnsupportedFlash, detected_size(0xc84020, 0x400000));
    try std.testing.expectError(error.UnsupportedFlash, detected_size(0x1640c8, 0x400000));
}

test "initialization repairs absent records and ignores RAM boot defaults" {
    const id = normalized_id(0x164046);
    var chip = std.mem.zeroes(FlashChip);
    try std.testing.expect(!valid_geometry(chip));
    try std.testing.expectEqual(@as(u32, 0x400000), try initialization_size(id, chip, true));
    chip = .{ .device_id = id, .chip_size = 0x200000, .block_size = 0x10000, .sector_size = sector_size, .page_size = 256, .status_mask = 0xffff };
    try std.testing.expect(valid_geometry(chip));
    try std.testing.expectEqual(@as(u32, 0x200000), try initialization_size(id, chip, false));
    try std.testing.expectEqual(@as(u32, 0x400000), try initialization_size(id, chip, true));
    chip.device_id = 0;
    try std.testing.expectEqual(@as(u32, 0x400000), try initialization_size(id, chip, false));
    chip.page_size = 0;
    try std.testing.expect(!valid_geometry(chip));
    try std.testing.expectEqual(@as(u32, 0x400000), try initialization_size(id, chip, false));
    try std.testing.expectError(error.UnsupportedFlash, initialization_size(0xffffff, chip, true));
}

test "image guard covers trailing RAM segments, digests and OTA copies; unknown layouts fail closed" {
    const Image = struct {
        size: u32 = 3 * sector_size,
        bytes: [3 * sector_size]u8 = @splat(0xff),

        fn read(self: *const @This(), offset: u32, dest: []u8) Error!void {
            if (offset > self.size or dest.len > self.size - offset) return error.OutOfBounds;
            @memcpy(dest, self.bytes[offset..][0..dest.len]);
        }

        fn add(self: *@This(), base: usize, entry: u32) void {
            const header = self.bytes[base..][0..24];
            @memset(header, 0);
            header[0] = 0xe9;
            header[1] = 2;
            header[23] = 1;
            std.mem.writeInt(u32, header[4..8], entry, .little);
            // Two segments: mapped code, then a RAM-loaded segment.
            std.mem.writeInt(u32, self.bytes[base + 24 ..][0..4], 0x42000020, .little);
            std.mem.writeInt(u32, self.bytes[base + 28 ..][0..4], 64, .little);
            std.mem.writeInt(u32, self.bytes[base + 96 ..][0..4], 0x40380000, .little);
            std.mem.writeInt(u32, self.bytes[base + 100 ..][0..4], 128, .little);
        }
    };
    var image: Image = .{};
    const entry = 0x42000020;
    try std.testing.expectEqual(image.size, try esp_image_end(&image, entry));
    image.add(0, entry);
    // 24 + (8 + 64) + (8 + 128) = 232; checksum rounds to 240,
    // followed by the 32-byte digest.
    try std.testing.expectEqual(@as(u32, 272), try esp_image_end(&image, entry));
    image.add(sector_size, entry);
    try std.testing.expectEqual(@as(u32, sector_size + 272), try esp_image_end(&image, entry));
    image.add(2 * sector_size, 0x40380000); // Other entry point is irrelevant.
    try std.testing.expectEqual(@as(u32, sector_size + 272), try esp_image_end(&image, entry));
    std.mem.writeInt(u32, image.bytes[sector_size + 100 ..][0..4], 0xfffffff0, .little);
    try std.testing.expectEqual(image.size, try esp_image_end(&image, entry));
}
