//! Probes reset behaviour on the XIAO nRF52840 Sense. A hang or failure to
//! enumerate lets the watchdog reset the board and request UF2 mode.
//!
//! Every 2 s it prints RESETREAS, GPREGRET, GPREGRET2 and the watchdog state
//! as they were at boot, and feeds the watchdog while USB is configured.
//! End each command with CR or LF:
//!   uf2   reboot into the UF2 bootloader (GPREGRET 0x57, soft reset)
//!   dog   GPREGRET2 = 0xA5, stop feeding the watchdog: it resets the board
//!         at expiry (nominally 20 s for a fresh watchdog), and the next
//!         boot requests UF2 mode
//!   fall  GPREGRET = 0x57, then as `dog`
//!   soft  feed the watchdog, soft reset
//!   lockup  lock the CPU up (a fault with FAULTMASK set)
//! The boot line also shows the breadcrumb word another image left behind.
//! At boot it calls the board's `arm_bootloader_fallback`.

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

const Boot = struct { resetreas: u32, gpregret: u32, gpregret2: u32, wdt_running: bool, wdt_crv: u32, crumb: u32 };
var boot: Boot = undefined;

const p = microzig.chip.peripherals;

fn wdt_running() bool {
    return nrf.wdt.is_running();
}

fn feed() void {
    board.feed_bootloader_fallback();
}

fn starve() noreturn {
    while (true) {}
}

pub fn init() void {
    boot = .{
        .crumb = board.breadcrumb.*,
        .resetreas = undefined,
        .gpregret = p.POWER.GPREGRET.raw,
        .gpregret2 = p.POWER.GPREGRET2.raw,
        .wdt_running = wdt_running(),
        .wdt_crv = p.WDT.CRV.raw,
    };
    // After a watchdog reset this reboots into the UF2 bootloader; otherwise
    // it starts the watchdog, which the loop below feeds.
    board.breadcrumb.* = 0;
    boot.resetreas = @bitCast(board.arm_bootloader_fallback(20_000));
    p.POWER.GPREGRET2.raw = 0;
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
        feed();

        const now = time.get_time_since_boot().to_us();
        if (now - last_us >= 2_000_000) {
            last_us = now;
            i += 1;
            if (!write("PROBE {d} boot: RESETREAS=0x{x:0>8} GPREGRET=0x{x:0>2} GPREGRET2=0x{x:0>2} WDT_RUNNING={} CRV=0x{x:0>8} CRUMB=0x{x:0>8}; now WDT_RUNNING={}\r\n", .{ i, boot.resetreas, boot.gpregret, boot.gpregret2, boot.wdt_running, boot.wdt_crv, boot.crumb, wdt_running() })) {
                lines.clear();
                continue;
            }
        }

        const serial = console.serial(&usb_device, &usb_controller) orelse continue;
        const n = serial.read(&rx_buf);
        for (rx_buf[0..n]) |byte| {
            const line = lines.push(byte) orelse continue;
            if (!command(std.mem.trim(u8, line, " "))) {
                lines.clear();
                break;
            }
        }
    }
}

fn command(cmd: []const u8) bool {
    if (std.mem.eql(u8, cmd, "uf2")) {
        board.reboot_to_bootloader();
    } else if (std.mem.eql(u8, cmd, "dog")) {
        _ = write("PROBE dog: GPREGRET2=0xA5, starving the watchdog\r\n", .{});
        p.POWER.GPREGRET2.raw = 0xA5;
        starve();
    } else if (std.mem.eql(u8, cmd, "fall")) {
        _ = write("PROBE fall: GPREGRET=0x57, starving the watchdog\r\n", .{});
        p.POWER.GPREGRET.raw = 0x57;
        starve();
    } else if (std.mem.eql(u8, cmd, "soft")) {
        _ = write("PROBE soft: fed, soft reset\r\n", .{});
        feed();
        microzig.cpu.peripherals.scb.AIRCR.write(.{ .VECTRESET = 0, .VECTCLRACTIVE = 0, .SYSRESETREQ = 1, .PRIGROUP = 0, .ENDIANNESS = 0, .VECTKEY = 0x05FA });
        starve();
    } else if (std.mem.eql(u8, cmd, "lockup")) {
        _ = write("PROBE lockup: fault with FAULTMASK set\r\n", .{});
        // A fault that cannot escalate locks the core up (ARMv7-M ARM, B1.5.15).
        asm volatile ("cpsid f\n udf #0");
        starve();
    }
    return write("PROBE unknown command: {s}\r\n", .{cmd});
}

var usb_tx_buff: [console.Lines.capacity + 64]u8 = undefined;

fn write(comptime fmt: []const u8, args: anytype) bool {
    const tx = std.fmt.bufPrint(&usb_tx_buff, fmt, args) catch {
        std.log.err("probe CDC response exceeds its TX buffer", .{});
        return true;
    };
    return console.write_all(&usb_device, &usb_controller, tx);
}
