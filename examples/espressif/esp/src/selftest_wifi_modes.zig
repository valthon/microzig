//! Wi-Fi calls in modes without a station: no AP, peer or wiring needed.
//! Starts a hidden soft-AP for about a second (demonstration passphrase).
//! Expected: SELFTEST wifi_modes DONE pass=11 fail=0. Every case line and the
//! DONE line repeat every 3 s, so a late console still sees all of them.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const rtos = hal.rtos;
const wifi = hal.radio.wifi;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .log_level = .info,
    .logFn = hal.usb_serial_jtag.logger.log,
});
pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt30 = hal.radio.interrupt_handler,
        .interrupt31 = rtos.interrupt_handler,
    },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{ .rtos = .{ .enable = true } },
};

comptime {
    _ = microzig.export_startup();
}

const suite = "wifi_modes";
const names = [_][]const u8{
    "init",            "mode_after_init", "protocol_null", "start_null",
    "disconnect_null", "connect_null",    "ap_start",      "disconnect_ap",
    "connect_ap",      "stop",            "deinit",
};
const Result = struct {
    passed: bool = false,
    /// What the call returned: an error or mode name, or "ok".
    observed: []const u8 = "not run",
};
var results: [names.len]Result = @splat(.{});
var current: usize = 0;

pub fn main() void {
    // A console opened after the reset still sees the first case run, and a
    // panic message, live.
    rtos.sleep(.from_ms(4000));
    var heap = microzig.Allocator.init_with_heap(65536) catch |err| report_loop(err);
    exercise(heap.allocator()) catch |err| report_loop(err);
    report_loop(null);
}

fn pass(observed: []const u8) void {
    results[current] = .{ .passed = true, .observed = observed };
    std.log.info("SELFTEST {s} {s}: PASS {s}", .{ suite, names[current], observed });
    current += 1;
}

fn report_loop(err: ?anyerror) noreturn {
    if (err) |failure| {
        if (std.mem.eql(u8, results[current].observed, "not run")) results[current].observed = @errorName(failure);
        std.log.err("SELFTEST {s} {s}: FAIL {t}", .{ suite, names[current], failure });
    }
    var passed: u32 = 0;
    for (results) |result| passed += @intFromBool(result.passed);
    while (true) {
        for (names, results) |name, result|
            std.log.info("SELFTEST {s} {s}: {s} {s}", .{ suite, name, if (result.passed) "PASS" else "FAIL", result.observed });
        std.log.info("SELFTEST {s} DONE pass={d} fail={d}", .{ suite, passed, names.len - passed });
        rtos.sleep(.from_ms(3000));
    }
}

fn expect_mode(expected: wifi.WifiMode) ![]const u8 {
    const mode = try wifi.get_mode();
    results[current].observed = @tagName(mode);
    if (mode != expected) return error.UnexpectedMode;
    return @tagName(mode);
}

/// `result` must be the error `expected`; success or another error fails.
fn expect_error(expected: anyerror, result: anytype) ![]const u8 {
    if (result) |_| {
        results[current].observed = "ok";
        return error.UnexpectedSuccess;
    } else |err| {
        results[current].observed = @errorName(err);
        if (err != expected) return error.UnexpectedError;
        return @errorName(err);
    }
}

fn wait_ap_started() !void {
    const limit: microzig.drivers.time.Deadline = .init_relative(hal.time.get_time_since_boot(), .from_ms(5000));
    while (wifi.get_ap_state() != .started) {
        if (limit.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
        rtos.sleep(.from_ms(20));
    }
}

fn exercise(gpa: std.mem.Allocator) !void {
    @import("wifi_antenna.zig").apply();
    try wifi.init(gpa, .{});
    pass("ok");

    // init selects the null mode.
    pass(try expect_mode(.none));

    pass(try expect_error(error.WifiMode, wifi.set_protocol(&.{.P802D11BGN})));

    try wifi.start();
    pass("ok");

    pass(try expect_error(error.WifiMode, wifi.disconnect()));

    pass(try expect_error(error.WifiMode, wifi.connect()));

    // Adding the soft-AP to a started session starts it.
    try wifi.apply(.{ .ap = .{
        .ssid = "mz-wifi-modes",
        .password = "demo-passphrase",
        .auth_method = .wpa2_personal,
        .ssid_hidden = true,
        .channel = 1,
        .max_connections = 1,
    } });
    _ = try expect_mode(.ap);
    try wait_ap_started();
    if (try wifi.Interface.sta.is_active()) return error.StationActive;
    if (!try wifi.Interface.ap.is_active()) return error.AccessPointInactive;
    pass("ap");

    pass(try expect_error(error.WifiMode, wifi.disconnect()));

    pass(try expect_error(error.WifiMode, wifi.connect()));

    try wifi.stop();
    pass("ok");

    wifi.deinit();
    pass(try expect_error(error.WifiNotInitialized, wifi.get_mode()));
}
