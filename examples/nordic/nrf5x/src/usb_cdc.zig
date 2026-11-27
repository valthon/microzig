//! Adapted from
//! examples/raspberrypi/rp2xxx/src/usb_cdc.zig

const std = @import("std");
const console = @import("cdc_console");
const microzig = @import("microzig");
const nrf = microzig.hal;
const board = microzig.board;
const usb = microzig.core.usb;
const time = nrf.time;
const USBD = nrf.usbd.USBD;
const clocks = nrf.clocks;
const uart = nrf.uart.num(0);

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .usb_dev, .level = .warn },
        .{ .scope = .usb_ctrl, .level = .warn },
        .{ .scope = .usb_cdc, .level = .warn },
    },
    .logFn = nrf.uart.log,
});

comptime {
    _ = microzig.export_startup();
}

var usb_device: USBD = undefined;

// Generate a device controller with descriptor and handlers setup for CDC (usb.drivers.CDC)
var usb_controller: usb.DeviceController(.{
    .device_triple = .unspecified,
    .bcd_device = .v1_00,
    .serial = "someserial",
    .device_capabilities = USBD.device_capabilities,
}, &.{usb.Configuration(
    .{ .attributes = .{ .self_powered = false }, .max_current_ma = 50 },
    .{ .serial = usb.drivers.CDC{ .itf_notifi_str = "Board CDC", .itf_data_str = "Board CDC Data" } },
)}) = .init;

const has_fallback = @hasDecl(board, "arm_bootloader_fallback");

pub fn init() void {
    if (has_fallback) _ = board.arm_bootloader_fallback(20_000);
    nrf.init();
}

pub fn main() !void {
    board.init();

    uart.apply(.{
        .tx_pin = board.uart_tx,
        .rx_pin = board.uart_rx,
    });

    nrf.uart.init_logger(uart);

    clocks.hfxo.start();
    usb_device = .init();

    var last_us: u64 = 0;
    var i: u32 = 0;
    var lines: console.Lines = .{};
    var rx_buf: [64]u8 = undefined;

    while (true) {
        console.poll(&usb_device, &usb_controller);
        lines.sync_configuration(usb_device.get_configuration_generation());
        if (console.serial(&usb_device, &usb_controller) == null) {
            lines.clear();
            continue;
        }
        if (has_fallback) board.feed_bootloader_fallback();

        const now = time.get_time_since_boot().to_us();
        if (now - last_us >= 500_000) {
            last_us = now;
            board.led1.toggle();
            i += 1;
            std.log.info("cdc test: {}", .{i});
            if (!write("This is very very long text sent from nRF52 by USB CDC to your device: {}\r\n", .{i})) {
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
            if (!write("Your message to me was: {s}\r\n", .{line})) {
                lines.clear();
                break;
            }
        }
    }
}

var usb_tx_buff: [console.Lines.capacity + 64]u8 = undefined;

fn write(comptime fmt: []const u8, args: anytype) bool {
    const tx = std.fmt.bufPrint(&usb_tx_buff, fmt, args) catch {
        std.log.err("CDC response exceeds its TX buffer", .{});
        return true;
    };
    return console.write_all(&usb_device, &usb_controller, tx);
}
