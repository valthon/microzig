//! Compile-only coverage of the C6 multi-radio paths: Wi-Fi, BLE, ESP-NOW and
//! 802.15.4 lifecycle calls in one coexistence image. The port's host tests exercise
//! registration and ownership without executing radio MMIO or vendor blobs.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const radio = hal.radio;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .logFn = hal.usb_serial_jtag.logger.log });

pub const microzig_options: microzig.Options = .{
    .cpu = .{ .interrupt_stack = .{ .enable = true } },
    .hal = .{ .rtos = .{ .enable = true }, .radio = .{ .radios = .{ .ble = true, .ieee802154 = true }, .wifi = .{ .on_packet_received = received, .on_packet_transmitted = transmitted, .on_event = event } } },
    .interrupts = .{ .interrupt29 = radio.bluetooth.interrupt_handler, .interrupt30 = radio.interrupt_handler, .interrupt31 = hal.rtos.interrupt_handler },
};

fn received(comptime _: radio.wifi.Interface, _: []const u8) void {}
fn transmitted(_: radio.wifi.Interface, _: []const u8, _: bool) void {}
fn event(_: radio.wifi.Event) void {}

pub fn main() void {}

comptime {
    if (!radio.coex_enabled) @compileError("the coex compile test requires multiple radios");
    @export(&check, .{ .name = "check_coex_plumbing" });
}

fn check(shared: *radio.SharedHeap, heap: *std.mem.Allocator, ble: *radio.bluetooth.Controller, mac: *radio.ieee802154.Radio, config: *radio.ieee802154.Config, espnow: *radio.espnow.Session) callconv(.c) void {
    radio.attach_shared_heap(shared) catch return;
    radio.wifi.init(heap.*, .{}) catch return;
    ble.start(heap.*) catch return;
    espnow.init() catch return;
    espnow.deinit() catch return;
    mac.init(heap.*, config.*) catch return;
    mac.deinit() catch return;
    radio.wifi.deinit() catch return;
}
