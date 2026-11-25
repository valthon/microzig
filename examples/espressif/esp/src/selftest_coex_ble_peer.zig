//! BLE central peer for selftest_coex_wifi_ble, for a XIAO ESP32-C6 (the
//! xiao_esp32_c6_selftest_coex_ble_peer build). It connects to "MZ-COEX",
//! subscribes to its notifications and reconnects whenever the link drops: the
//! DUT drops it itself for each Wi-Fi-only phase. Every 5 s it logs on the USB
//! serial port whether the link is up, the notifications received in that window,
//! counter gaps (notifications lost or skipped), links made and the last
//! disconnect reason. It has no verdict of its own; the DUT reports the result.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const rtos = hal.rtos;
const ble = hal.radio.bluetooth;
const Host = ble.host.Host;
const antenna = @import("antenna_options").antenna;

comptime {
    _ = microzig.export_startup();
}

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .log_level = .info,
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_scope_levels = &.{ .{ .scope = .esp_radio_osi, .level = .err }, .{ .scope = .esp_radio_timer, .level = .err } },
});
pub const microzig_options: microzig.Options = .{
    .interrupts = .{ .interrupt29 = ble.interrupt_handler, .interrupt30 = hal.radio.interrupt_handler, .interrupt31 = rtos.interrupt_handler },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{
        .rtos = .{ .enable = true, .priority_bits = 5, .preempt_same_priority_tasks_on_tick = true },
        .radio = .{ .radios = .{ .wifi = false, .ble = true } },
    },
};
const clock_config: hal.clocks.Config = .init_comptime(160_000_000);
pub fn init() void {
    hal.init_sequence(clock_config);
}

const peer_name = "MZ-COEX";
const window_ms = 5000;

var controller: ble.Controller = .{};
var host: Host = undefined;

const Window = struct {
    received: u32 = 0,
    gaps: u32 = 0,
    last_counter: ?u32 = null,
    links: u32 = 0,
};

fn now_ms() u64 {
    return hal.time.get_time_since_boot().to_us() / 1000;
}

pub fn main() void {
    if (@hasDecl(microzig.board, "antenna"))
        microzig.board.antenna.apply(@field(microzig.board.antenna.Selection, @tagName(antenna)));
    host = .init(controller.transport());
    var heap = microzig.Allocator.init_with_heap(160 * 1024) catch |err| fatal("heap", err);
    controller.start(heap.allocator()) catch |err| fatal("controller", err);
    host.initialize() catch |err| fatal("hci", err);
    std.log.info("COEX peer ready, looking for {s}", .{peer_name});

    var window: Window = .{};
    var total: u64 = 0;
    var next_report = now_ms() + window_ms;
    while (true) {
        if (host.connection == null) {
            link() catch |err| std.log.info("COEX peer link attempt: {t} disconnect_reason={?x}", .{ err, host.disconnect_reason });
            if (host.connection != null) {
                window.links += 1;
                window.last_counter = null;
            }
        } else {
            const before = host.notifications;
            host.poll(100) catch |err| switch (err) {
                error.Timeout => {},
                else => if (host.connection != null) std.log.warn("COEX peer poll: {t}", .{err}),
            };
            if (host.notifications != before and host.notification_len >= 4) {
                const counter = std.mem.readInt(u32, host.notification[0..4], .little);
                if (window.last_counter) |last| {
                    if (counter != last +% 1) window.gaps += 1;
                }
                window.last_counter = counter;
                window.received += 1;
                total += 1;
            }
        }
        if (now_ms() >= next_report) {
            next_report += window_ms;
            std.log.info("COEX peer link={} window_ms={d} received={d} gaps={d} links={d} total={d} disconnect_reason={?x}", .{
                host.connection != null, window_ms, window.received, window.gaps, window.links, total, host.disconnect_reason,
            });
            window.received = 0;
            window.gaps = 0;
            window.links = 0;
        }
    }
}

/// Connect, discover and subscribe; a link left half set up is dropped.
fn link() ble.host.Error!void {
    try host.connect_named(peer_name, 5000);
    errdefer host.disconnect() catch {};
    const peer = try host.discover();
    try host.subscribe(peer);
}

fn fatal(step: []const u8, err: anyerror) noreturn {
    while (true) {
        std.log.err("COEX peer {s}: FAIL {t}", .{ step, err });
        rtos.sleep(.from_ms(3000));
    }
}
