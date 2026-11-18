const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const flash = hal.flash;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_level = .info,
});
comptime {
    _ = microzig.export_startup();
}

// Destructive scratch sector in the last 64 KiB of a 4 MiB part. Preserve
// the verified C3 location; C6 uses the final sector. Protection stays on:
// an image reaching the scratch sector must refuse the destructive checks.
const scratch: u32 = switch (hal.compatibility.chip) {
    .esp32_c3 => 0x3f0000,
    .esp32_c6 => 0x3ff000,
};
var pattern: [flash.sector_size]u8 = undefined;
var actual: [flash.sector_size]u8 = undefined;
const names = [_][]const u8{ "erase", "pattern", "nor_and", "bounds", "image_guard" };
const Evidence = struct {
    stage: []const u8 = "init",
    diagnostics: flash.Diagnostics = .{},
    offset: usize = 0,
    expected: u32 = 0,
    observed: u32 = 0,
    comparison: bool = false,
};

pub fn main() void {
    var passed: [names.len]bool = @splat(false);
    var failure: ?flash.Error = null;
    var evidence: Evidence = .{};
    run(&passed, &evidence) catch |err| {
        failure = err;
    };
    hal.time.sleep_ms(1500);
    while (true) {
        var count: usize = 0;
        for (names, passed) |name, ok| {
            if (ok) count += 1;
            std.log.info("SELFTEST flash {s}: {s} scratch=0x{X} {s}", .{
                name, if (ok) "PASS" else "FAIL", scratch, if (failure) |err| @errorName(err) else "comparison",
            });
            if (!ok) {
                std.log.info("SELFTEST flash {s}: stopped_at={s}", .{ name, evidence.stage });
                if (evidence.comparison) std.log.info("SELFTEST flash {s}: offset=0x{X} expected=0x{X} observed=0x{X}", .{
                    name, evidence.offset, evidence.expected, evidence.observed,
                });
            }
        }
        if (count != passed.len) {
            const d = evidence.diagnostics;
            std.log.info("SELFTEST flash init: raw_rdid=0x{X} attached={}", .{ d.raw_rdid, d.attached });
            for ([_]@TypeOf(d.before){ d.before, d.after }, [_][]const u8{ "before", "after" }) |chip, when| {
                std.log.info("SELFTEST flash ROM {s}: id=0x{X} size=0x{X} block=0x{X} sector=0x{X} page=0x{X} status_mask=0x{X}", .{
                    when, chip.device_id, chip.chip_size, chip.block_size, chip.sector_size, chip.page_size, chip.status_mask,
                });
            }
        }
        std.log.info("SELFTEST flash DONE pass={d} fail={d}", .{ count, passed.len - count });
        hal.time.sleep_ms(1000);
    }
}

fn run(passed: *[names.len]bool, evidence: *Evidence) flash.Error!void {
    const device = try flash.Flash.init(.{ .diagnostics = &evidence.diagnostics });
    evidence.stage = "size";
    evidence.expected = 0x400000;
    evidence.observed = device.size;
    evidence.comparison = true;
    if (device.size != 0x400000) return error.UnsupportedFlash;

    evidence.stage = "bounds";
    evidence.comparison = false;
    // Out-of-bounds check is a read, so a regression cannot erase low flash.
    var word: [4]u8 = undefined;
    if (device.read(device.size, &word)) |_| {} else |err| {
        passed[3] = err == error.OutOfBounds;
        if (!passed[3]) return err;
    }
    if (!passed[3]) {
        evidence.expected = 1; // Expected rejection, observed success.
        evidence.observed = 0;
        evidence.comparison = true;
        return;
    }
    // Check the public protection boundary without attempting a destructive
    // operation on the image, even if the driver were to regress.
    evidence.stage = "image_guard";
    evidence.expected = scratch;
    evidence.observed = device.protected_end;
    evidence.comparison = true;
    passed[4] = device.allow_running_image == false and
        (microzig.config.ram_image or (device.protected_end > 0 and device.protected_end <= scratch));
    if (!passed[4]) return error.RunningImage;

    evidence.stage = "erase";
    evidence.comparison = false;
    try device.erase_sector(scratch);
    try device.read(scratch, &actual);
    passed[0] = std.mem.allEqual(u8, &actual, 0xff);
    if (!passed[0]) {
        for (actual, 0..) |byte, i| {
            if (byte != 0xff) {
                evidence.offset = scratch + i;
                evidence.expected = 0xff;
                evidence.observed = byte;
                evidence.comparison = true;
                return;
            }
        }
    }

    evidence.stage = "pattern";
    for (&pattern, 0..) |*byte, i| byte.* = @truncate((i *% 37) ^ (i >> 4) ^ 0xa5);
    try device.write(scratch, &pattern);
    try device.read(scratch, &actual);
    passed[1] = std.mem.eql(u8, &pattern, &actual);
    if (!passed[1]) {
        record_mismatch(evidence);
        return;
    }

    evidence.stage = "nor_and";
    // Includes attempts to set existing zero bits and clear existing one bits.
    // This source is const rodata in flash on both flash boot targets.
    const mask: [256]u8 = @splat(0x5a);
    var offset: u32 = 0;
    while (offset < pattern.len) : (offset += mask.len) {
        try device.write(scratch + offset, &mask);
    }
    for (&pattern) |*byte| byte.* &= 0x5a;
    try device.read(scratch, &actual);
    passed[2] = std.mem.eql(u8, &pattern, &actual);
    if (!passed[2]) record_mismatch(evidence);
    // No mmap API: the driver leaves all bootloader MMU mappings untouched.
}

fn record_mismatch(evidence: *Evidence) void {
    for (pattern, actual, 0..) |expected, observed, i| {
        if (expected != observed) {
            evidence.offset = scratch + i;
            evidence.expected = expected;
            evidence.observed = observed;
            evidence.comparison = true;
            return;
        }
    }
}
