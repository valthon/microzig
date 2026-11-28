const std = @import("std");
const microzig = @import("microzig");
const time = microzig.hal.time;

const rtt = microzig.cpu.rtt.RTT(.{});

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .logFn = log });

comptime {
    _ = microzig.export_startup();
}

fn log(
    comptime _: std.log.Level,
    comptime _: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [128]u8 = undefined;
    const line = std.mem.print(&buffer, format ++ "\n", args) catch "RTT log line too long\n";
    _ = rtt.write(0, line);
}

pub fn main() void {
    rtt.init();
    var counter: u32 = 0;
    var next_tick = microzig.drivers.time.make_timeout_us(time.get_time_since_boot(), std.time.us_per_s);
    var input: [16]u8 = undefined;
    while (true) {
        const now = time.get_time_since_boot();
        if (next_tick.is_reached_by(now)) {
            std.log.info("RTT tick {d}", .{counter});
            counter +%= 1;
            next_tick = microzig.drivers.time.make_timeout_us(now, std.time.us_per_s);
        }

        const n = rtt.read(0, &input);
        if (n > 0) std.log.info("RTT echo {f}", .{std.zig.fmtString(input[0..n])});
        time.sleep_ms(1);
    }
}
