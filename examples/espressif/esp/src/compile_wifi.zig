//! Compile coverage only: never initializes or exercises the radio.
const std = @import("std");
const microzig = @import("microzig");
const radio = microzig.hal.radio;
const wifi = radio.wifi;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = microzig.hal.usb_serial_jtag.logger.log,
});
pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt30 = radio.interrupt_handler,
        .interrupt31 = microzig.hal.rtos.interrupt_handler,
    },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{
        .rtos = .{ .enable = true },
        .radio = .{ .wifi = .{
            .on_event = on_event,
            .on_packet_received = on_packet_received,
            .on_packet_transmitted = on_packet_transmitted,
        } },
    },
};

comptime {
    _ = microzig.export_startup();
}

pub fn main() void {
    @import("wifi_antenna.zig").apply();
}

fn on_event(_: wifi.Event) void {}
fn on_packet_received(comptime _: wifi.Interface, _: []const u8) void {}
fn on_packet_transmitted(_: wifi.Interface, _: []const u8, _: bool) void {}

// Exporting forces body analysis even though main never calls this function.
// Runtime references force analysis of the functions, not just their types.
export fn compile_wifi_references() void {
    reference_functions(wifi);
    inline for (.{ wifi.WifiMode, wifi.StaState, wifi.Interface, wifi.ScanResultsIterator }) |T|
        reference_functions(T);
}

fn reference_functions(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |name| {
        if (comptime @typeInfo(@TypeOf(@field(T, name))) == .@"fn")
            std.mem.doNotOptimizeAway(&@field(T, name));
    }
}
