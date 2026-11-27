//! Destructive storage checks on the XIAO nRF52840 Sense scratch pages.
const std = @import("std");
const microzig = @import("microzig");
const board = microzig.board;
const nvmc = microzig.hal.nvmc;
const qspi = microzig.hal.qspi;
const harness = @import("harness.zig");

pub const panic = microzig.panic;
pub const init = harness.init;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

extern const microzig_flash_end: u8;
extern const microzig_data_load_start: u8;
extern const microzig_data_start: u8;
extern const microzig_data_end: u8;

const suite = "storage";
const app_start = 0x27000;
const app_end = 0xed000;
const scratch_page = app_end - nvmc.page_size;

comptime {
    if (scratch_page < app_start or scratch_page % nvmc.page_size != 0)
        @compileError("NVMC scratch page must be wholly inside the XIAO application region");
}

fn check_nvmc() !void {
    const data_size = @intFromPtr(&microzig_data_end) - @intFromPtr(&microzig_data_start);
    const data_end = @intFromPtr(&microzig_data_load_start) + data_size;
    const image_end = @max(@intFromPtr(&microzig_flash_end), data_end);
    if (image_end < app_start or image_end > scratch_page) return error.ImageOverlapsScratchPage;

    const region: nvmc.Region = .{ .start = scratch_page, .end = app_end };
    const pattern = [_]u32{ 0x12345678, 0xa55aa55a, 0xdeadbeef, 0 };
    try region.erase_page(scratch_page);
    for (pattern, 0..) |value, i| try region.write_word(scratch_page + i * 4, value);
    var matches = true;
    for (pattern, 0..) |value, i| {
        if (try region.read_word(scratch_page + i * 4) != value) matches = false;
    }
    try region.erase_page(scratch_page);
    if (!matches) return error.ReadbackMismatch;
}

var flash: qspi.QSPI = .{};

fn check_qspi_deep_power_down() !void {
    try flash.init(board.flash_qspi_config);
    // P25Q16H v2.1 §10.30 (B9h) and §5.3 (tDP max 3 µs).
    try flash.custom_instruction(0xb9, &.{});
    // Allow for one tick of quantization in the 32.768 kHz HAL timebase.
    microzig.hal.time.sleep_us(3 + 32);
    try flash.deinit();

    try flash.init(board.flash_qspi_config);
    const id = try flash.read_jedec_id();
    try flash.deinit();
    if (!std.mem.eql(u8, &id, &board.flash_jedec_id)) return error.UnexpectedJedecId;
}

fn check_qspi() !void {
    const id = try flash.read_jedec_id();
    const expected = board.flash_jedec_id;
    const matches = std.mem.eql(u8, &id, &expected);
    harness.check(suite, "qspi_jedec_id", matches, "got={x:0>2}{x:0>2}{x:0>2} expected={x:0>2}{x:0>2}{x:0>2}", .{
        id[0], id[1], id[2], expected[0], expected[1], expected[2],
    });
    if (!matches) return error.UnexpectedJedecId;
    try board.enable_flash_quad(&flash);

    const sector = board.flash_qspi_config.capacity - qspi.sector_size;
    const pattern: [16]u8 = .{ 0x12, 0x34, 0x56, 0x78, 0xa5, 0x5a, 0x00, 0xff, 1, 2, 4, 8, 16, 32, 64, 128 };
    var observed: [pattern.len]u8 = undefined;
    try flash.erase(sector, .sector);
    try flash.read(sector, &observed);
    if (!std.mem.allEqual(u8, &observed, 0xff)) return error.EraseMismatch;
    try flash.program(sector, &pattern);
    try flash.read(sector, &observed);
    if (!std.mem.eql(u8, &observed, &pattern)) return error.ReadbackMismatch;
}

fn run_qspi() void {
    flash.init(board.flash_qspi_config) catch |err| {
        harness.check(suite, "qspi_init", false, "{s}", .{@errorName(err)});
        return;
    };
    if (check_qspi()) |_| {
        harness.check(suite, "qspi_sector", true, "offset=0x{x}", .{board.flash_qspi_config.capacity - qspi.sector_size});
    } else |err| {
        harness.check(suite, "qspi_sector", false, "{s}", .{@errorName(err)});
    }
    if (flash.deinit()) |_| {
        harness.check(suite, "qspi_deactivate", true, "", .{});
    } else |err| {
        harness.check(suite, "qspi_deactivate", false, "{s}", .{@errorName(err)});
    }
}

pub fn main() void {
    if (check_nvmc()) |_| {
        harness.check(suite, "nvmc", true, "page=0x{x}", .{scratch_page});
    } else |err| {
        harness.check(suite, "nvmc", false, "{s}", .{@errorName(err)});
    }
    if (check_qspi_deep_power_down()) |_| {
        harness.check(suite, "qspi_deep_power_down", true, "", .{});
    } else |err| {
        harness.check(suite, "qspi_deep_power_down", false, "{s}", .{@errorName(err)});
    }
    run_qspi();
    harness.finish(suite);
}
