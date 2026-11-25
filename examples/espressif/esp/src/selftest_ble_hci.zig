//! No peer or external wiring; run on the C6 image-boot target.
//! Evidence: port README, "BLE bench examples".
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const ble = hal.radio.bluetooth;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .log_level = .info,
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_scope_levels = &.{ .{ .scope = .esp_radio_osi, .level = .err }, .{ .scope = .esp_radio_timer, .level = .err } },
});
pub const microzig_options: microzig.Options = .{
    .interrupts = .{ .interrupt29 = ble.interrupt_handler, .interrupt30 = hal.radio.interrupt_handler, .interrupt31 = hal.rtos.interrupt_handler },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{ .rtos = .{ .enable = true, .priority_bits = 5, .preempt_same_priority_tasks_on_tick = true }, .radio = .{ .radios = .{ .wifi = false, .ble = true } } },
};
const clock_config: hal.clocks.Config = .init_comptime(160_000_000);
pub fn init() void {
    hal.init_sequence(clock_config);
}
comptime {
    _ = microzig.export_startup();
}
pub fn main() !void {
    var heap: microzig.Allocator = try .init_with_heap(160 * 1024);
    var controller: ble.Controller = .{};
    hal.rtos.sleep(.from_ms(1500));
    var passed: u32 = 0;
    var failed: u32 = 0;
    controller.start(heap.allocator()) catch |err| {
        std.log.err("SELFTEST ble_hci init: FAIL {t}", .{err});
        while (true) {
            std.log.info("SELFTEST ble_hci DONE pass=0 fail=1", .{});
            hal.rtos.sleep(.from_ms(3000));
        }
    };
    const commands = [_]struct { name: []const u8, opcode: u16, len: u8 }{
        .{ .name = "reset", .opcode = 0x0c03, .len = 1 },
        .{ .name = "local_version", .opcode = 0x1001, .len = 9 },
        .{ .name = "bd_addr", .opcode = 0x1009, .len = 7 },
        .{ .name = "le_buffer_size", .opcode = 0x2002, .len = 4 },
    };
    for (commands) |command| {
        check(&controller, command.opcode, command.len) catch |err| {
            failed += 1;
            std.log.err("SELFTEST ble_hci {s}: FAIL {t}", .{ command.name, err });
            continue;
        };
        passed += 1;
        std.log.info("SELFTEST ble_hci {s}: PASS", .{command.name});
    }
    while (true) {
        std.log.info("SELFTEST ble_hci DONE pass={d} fail={d}", .{ passed, failed });
        hal.rtos.sleep(.from_ms(3000));
    }
}
fn check(controller: *ble.Controller, opcode: u16, expected_len: u8) !void {
    try controller.send_command(&.{ @truncate(opcode), @truncate(opcode >> 8), 0 });
    const end = hal.time.get_time_since_boot().to_us() + 2_000_000;
    while (hal.time.get_time_since_boot().to_us() < end) {
        const packet = try controller.receive(1000);
        const data = packet.data();
        if (packet.kind != .event or data.len < 6 or data[0] != 0x0e) continue;
        if (std.mem.readInt(u16, data[3..5], .little) != opcode) continue;
        if (data.len != @as(usize, expected_len) + 5 or data[5] != 0) return error.CommandFailed;
        return;
    }
    return error.Timeout;
}
