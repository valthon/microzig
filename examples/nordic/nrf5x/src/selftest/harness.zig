//! Self-test harness for boards with native USB (XIAO nRF52840 Sense).
//!
//! A self-test runs its cases first, recording each result in a buffer, and
//! then calls `finish`, which brings up USB CDC and repeats the whole report
//! every two seconds, so a host that opens the port late still reads all of
//! it. Lines have the form
//!
//!   SELFTEST <suite> <case>: PASS|FAIL <detail>
//!   SELFTEST <suite> DONE pass=N fail=M
//!
//! Send `uf2` followed by CR or LF to reboot into the UF2 bootloader on
//! boards that provide `reboot_to_bootloader`.
const std = @import("std");
const console = @import("cdc_console");
const microzig = @import("microzig");
const nrf = microzig.hal;
const board = microzig.board;
const usb = microzig.core.usb;
const time = nrf.time;
const USBD = nrf.usbd.USBD;

var report_buf: [4096]u8 = undefined;
var report_len: usize = 0;
var pass_count: u32 = 0;
var fail_count: u32 = 0;

fn append(comptime fmt: []const u8, args: anytype) void {
    const out = std.fmt.bufPrint(report_buf[report_len..], fmt, args) catch {
        // Keep the report bounded; mark that it was cut.
        const cut = "...report truncated\r\n";
        @memcpy(report_buf[report_buf.len - cut.len ..], cut);
        report_len = report_buf.len;
        return;
    };
    report_len += out.len;
}

const has_fallback = @hasDecl(board, "arm_bootloader_fallback");

pub const fallback_ms = 20_000;
pub var boot_reset_reason: nrf.power.ResetReason = undefined;

/// Root init hook. Start recovery before HAL clock and timebase setup.
pub fn init() void {
    if (has_fallback) boot_reset_reason = board.arm_bootloader_fallback(fallback_ms);
    mark(1);
    nrf.init();
    board.init();
    mark(2);
}

/// Progress marker that survives a reset, for boards that have one.
fn mark(stage: u16) void {
    if (@hasDecl(board, "mark")) board.mark(stage);
}

fn feed() void {
    if (has_fallback) board.feed_bootloader_fallback();
}

/// Records one case. `ok` decides PASS or FAIL; `fmt`/`args` give the detail.
pub fn check(suite: []const u8, case: []const u8, ok: bool, comptime fmt: []const u8, args: anytype) void {
    feed();
    if (ok) pass_count += 1 else fail_count += 1;
    append("SELFTEST {s} {s}: {s} ", .{ suite, case, if (ok) "PASS" else "FAIL" });
    append(fmt ++ "\r\n", args);
}

var usb_device: USBD = undefined;
var usb_controller: usb.DeviceController(.{
    .device_triple = .unspecified,
    .bcd_device = .v1_00,
    .serial = "selftest",
    .device_capabilities = USBD.device_capabilities,
}, &.{usb.Configuration(
    .{ .attributes = .{ .self_powered = false }, .max_current_ma = 100 },
    .{ .serial = usb.drivers.CDC{ .itf_notifi_str = "Selftest CDC", .itf_data_str = "Selftest CDC Data" } },
)}) = .init;

/// Appends the DONE line, then serves the report over USB CDC forever.
pub fn finish(suite: []const u8) noreturn {
    mark(3);
    append("SELFTEST {s} DONE pass={d} fail={d}\r\n", .{ suite, pass_count, fail_count });
    mark(4);
    nrf.clocks.hfxo.start();
    mark(5);
    usb_device = .init();
    mark(6);

    // The watchdog is fed only while USB is up, so an image that never
    // enumerates falls back to the bootloader.
    var lines: console.Lines = .{};
    var rx_buf: [64]u8 = undefined;
    var last_us: u64 = 0;
    var polled = false;
    while (true) {
        console.poll(&usb_device, &usb_controller);
        lines.sync_configuration(usb_device.get_configuration_generation());
        if (!polled) {
            polled = true;
            mark(7);
        }
        if (console.serial(&usb_device, &usb_controller) == null) {
            lines.clear();
            continue;
        }
        mark(8);
        feed();

        const now_us = time.get_time_since_boot().to_us();
        if (now_us - last_us >= 2_000_000) {
            last_us = now_us;
            if (!console.write_all(&usb_device, &usb_controller, report_buf[0..report_len])) {
                lines.clear();
                continue;
            }
        }

        const serial = console.serial(&usb_device, &usb_controller) orelse continue;
        const n = serial.read(&rx_buf);
        for (rx_buf[0..n]) |byte| {
            const line = lines.push(byte) orelse continue;
            if (@hasDecl(board, "reboot_to_bootloader") and
                std.mem.eql(u8, std.mem.trim(u8, line, " "), "uf2"))
                board.reboot_to_bootloader();
        }
    }
}
