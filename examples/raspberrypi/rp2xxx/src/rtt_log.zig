const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const time = hal.time;

const rtt = microzig.cpu.rtt.RTT(.{});

// On boards with a CYW43 (Pico W, Pico 2 W) GPIO25 is the radio's SPI chip select and the
// LED hangs off the CYW43, so this example blinks nothing there.
const has_gpio_led = !@hasDecl(microzig.board, "has_cyw43");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .log_level = .debug,
    .logFn = log,
});

comptime {
    _ = microzig.export_startup();
}

fn log(
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
    _ = rtt.write(0, line);
}

pub fn main() void {
    const led = hal.gpio.num(25);
    var led_on: u1 = 1;
    if (has_gpio_led) {
        led.set_direction(.out);
        led.set_function(.sio);
        led.put(led_on);
    }

    rtt.init();
    _ = rtt.write(0, "Hello RTT!\n");
    std.log.info("Hello from std.log!", .{});

    var blink_deadline = time.deadline_in_ms(500);
    var ticks: u32 = 0;
    var input: [16]u8 = undefined;
    while (true) {
        if (blink_deadline.is_reached_by(time.get_time_since_boot())) {
            led_on ^= 1;
            if (has_gpio_led) led.put(led_on);
            blink_deadline = time.deadline_in_ms(500);
            if (led_on == 1) {
                std.log.info("RTT tick {d}", .{ticks});
                ticks +%= 1;
            }
        }
        // Poll without waiting for a newline so the LED keeps blinking.
        const n = rtt.read(0, &input);
        if (n > 0) std.log.info("RTT echo {f}", .{std.zig.fmtString(input[0..n])});
    }
}
