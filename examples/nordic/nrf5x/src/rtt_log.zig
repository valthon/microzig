const std = @import("std");
const microzig = @import("microzig");
const mdf = microzig.drivers;
const board = microzig.board;
const nrf = microzig.hal;
const time = nrf.time;

const rtt = microzig.cpu.rtt;
// Configure RTT with all default settings:
const rtt_instance = rtt.RTT(.{});

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .log_level = .debug,
    .logFn = log,
});

comptime {
    _ = microzig.export_startup();
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_prefix = comptime "[{}.{:0>6}] " ++ level.asText();
    const prefix = comptime level_prefix ++ switch (scope) {
        .default => ": ",
        else => " (" ++ @tagName(scope) ++ "): ",
    };
    const timestamp = time.get_time_since_boot().to_us();
    const seconds = timestamp / std.time.us_per_s;
    const microseconds = timestamp % std.time.us_per_s;
    var buffer: [256]u8 = undefined;
    const line = std.mem.print(&buffer, prefix ++ format ++ "\r\n", .{ seconds, microseconds } ++ args) catch
        "RTT log line too long\r\n";
    _ = rtt_instance.write(0, line);
}

pub fn main() !void {
    board.init();

    // Nothing will work if you don't initialize the RTT control block first!
    rtt_instance.init();
    // Manually write some bytes to RTT up channel 0 so that it shows up in RTT Viewer
    _ = rtt_instance.write(0, "Hello RTT!\n");
    var input: [16]u8 = undefined;

    // For blinking our LED on a timeout without blocking
    var blink_deadline = mdf.time.make_timeout_us(time.get_time_since_boot(), 500_000);
    var hello_deadline = mdf.time.make_timeout_us(time.get_time_since_boot(), 2_000_000);

    while (true) {
        const now = time.get_time_since_boot();

        // Toggle LED every 500 msec
        if (blink_deadline.is_reached_by(now)) {
            board.led1.toggle();
            blink_deadline = mdf.time.make_timeout_us(now, 500_000);
        }
        // Say hello every 2 seconds
        if (hello_deadline.is_reached_by(now)) {
            std.log.info("Hello!", .{});
            hello_deadline = mdf.time.make_timeout_us(now, 2_000_000);
        }
        const n = rtt_instance.read(0, &input);
        if (n > 0) std.log.info("RTT echo {f}", .{std.zig.fmtString(input[0..n])});
    }
}
