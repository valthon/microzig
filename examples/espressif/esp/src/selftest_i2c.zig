//! C3/C6 master against i2c_slave_peer on a Pico 2 W, address 0x42.
//! C3 / Super Mini ESP32-C6: SDA GPIO5, SCL GPIO6. XIAO ESP32-C6: use the
//! xiao_esp32_c6_selftest_i2c build, SDA D4/GPIO22, SCL D5/GPIO23;
//! GPIO5/6 are absent from its edges (board pin map: xiao_esp32_c6.zig).
//! Wire SDA to Pico GP4 (pin 6), SCL to GP5 (pin 7), and common GND.
//! Pull-ups: both ends enable their internal pull-ups; external 4.7 kohm
//! pull-ups to 3.3 V are recommended for longer wires or faster clocks.
//! Use an isolated bus, start the peer before this test. No other slaves.
//! Expected: SELFTEST i2c DONE pass=8 fail=0 with the supplied peer.
//! A protocol-compatible peer without stretch support gives pass=7 fail=0
//! plus clock_stretch: SKIP. Hardware results: port README.
//! ESP32-C3 TRM v1.4 ch.28 / ESP32-C6 TRM v1.2 ch.29: I2C commands,
//! open drain and timeouts (C6 sections 29.4.6, 29.4.8, 29.4.9).
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const Duration = microzig.drivers.time.Duration;
const peer: hal.i2c.Address = @fromBackingInt(0x42);
const timeout = Duration.from_ms(100);
const has_board_i2c = microzig.board != void and @hasDecl(microzig.board, "i2c");
const pattern = [_]u8{ 0x00, 0xff, 0x55, 0xaa, 0x81, 0x7e, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x01, 0x80 };
const names = [_][]const u8{ "init", "scan_nack", "peer_ack", "peer_protocol", "pattern_write", "readback", "repeated_start", "clock_stretch" };

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = hal.usb_serial_jtag.logger.log });
comptime {
    microzig.export_startup();
}

const Results = struct {
    checks: [names.len]bool = @splat(false),
    skip_stretch: bool = false,
    nacks: usize = 0,
    acks: usize = 0,
    faults: usize = 0,
    normal_us: u64 = 0,
    stretch_us: u64 = 0,
};

pub fn main() void {
    hal.time.sleep_ms(1500);
    const results = run();
    while (true) {
        std.log.info("I2C wiring: SDA GPIO{}, SCL GPIO{}, peer Pico GP4/GP5; internal pull-ups on", .{
            if (has_board_i2c) @as(u8, 22) else @as(u8, 5),
            if (has_board_i2c) @as(u8, 23) else @as(u8, 6),
        });
        var pass: usize = 0;
        for (results.checks, names, 0..) |ok, name, index| {
            if (index == 7 and results.skip_stretch) {
                std.log.info("SELFTEST i2c clock_stretch: SKIP peer capability=0", .{});
                continue;
            }
            if (ok) pass += 1;
            std.log.info("SELFTEST i2c {s}: {s}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL" });
        }
        std.log.info("I2C scan nack={} ack={} fault={}; read normal_us={} stretch_us={}", .{ results.nacks, results.acks, results.faults, results.normal_us, results.stretch_us });
        std.log.info("SELFTEST i2c DONE pass={} fail={}", .{ pass, names.len - @intFromBool(results.skip_stretch) - pass });
        hal.time.sleep_ms(1000);
    }
}

fn run() Results {
    var results: Results = .{};
    var bus = comptime hal.i2c.instance.num(0);
    bus.connect_pins(.{
        .sda = if (has_board_i2c) microzig.board.i2c.sda else hal.gpio.num(5),
        .scl = if (has_board_i2c) microzig.board.i2c.scl else hal.gpio.num(6),
        // Enable internal pull-ups at both ends of the peer connection.
        .pull_up = true,
    });
    bus.apply(100_000) catch |err| {
        std.log.err("I2C init: {t}", .{err});
        return results;
    };
    results.checks[0] = true;
    var found_peer = false;
    // Seven-bit, non-reserved addresses only. Only NoAcknowledge counts as NACK;
    // a timeout, arbitration loss, or incomplete command is a test fault.
    for (0x08..0x78) |address| {
        bus.write_blocking(@fromBackingInt(@as(u7, @intCast(address))), &.{}, timeout) catch |err| {
            if (err == error.NoAcknowledge) {
                results.nacks += 1;
            } else {
                results.faults += 1;
                std.log.err("I2C scan address=0x{x}: {t}", .{ address, err });
            }
            continue;
        };
        results.acks += 1;
        if (address == 0x42) found_peer = true;
    }
    results.checks[1] = results.nacks == 111 and results.faults == 0;
    results.checks[2] = found_peer and results.acks == 1;

    results.checks[3] = protocol(bus, &results) catch |err| blk: {
        std.log.err("I2C peer protocol: {t}", .{err});
        break :blk false;
    };
    results.checks[4] = write_pattern(bus) catch |err| blk: {
        std.log.err("I2C pattern write: {t}", .{err});
        break :blk false;
    };
    results.checks[5] = readback(bus) catch |err| blk: {
        std.log.err("I2C readback: {t}", .{err});
        break :blk false;
    };
    results.checks[5] = results.checks[4] and results.checks[5];
    var data: [8]u8 = undefined;
    results.checks[6] = blk: {
        bus.write_then_read_blocking(peer, &.{0x25}, &data, timeout) catch |err| {
            std.log.err("I2C repeated start: {t}", .{err});
            break :blk false;
        };
        break :blk results.checks[4] and std.mem.eql(u8, &data, pattern[5..13]);
    };
    if (results.checks[3] and !results.skip_stretch) {
        results.checks[7] = stretch(bus, &results) catch |err| blk: {
            std.log.err("I2C clock stretch: {t}", .{err});
            break :blk false;
        };
    }
    return results;
}

fn protocol(bus: hal.i2c.I2C, results: *Results) !bool {
    var data: [3]u8 = undefined;
    try bus.write_then_read_blocking(peer, &.{0xf1}, &data, timeout);
    if (data[0] > 1 or data[1] != 0xa5 or data[2] != 1) return false;
    results.skip_stretch = data[0] == 0;
    return true;
}

fn write_pattern(bus: hal.i2c.I2C) !bool {
    try bus.writev_blocking(peer, &.{ &.{0x20}, &pattern }, timeout);
    return true;
}

fn readback(bus: hal.i2c.I2C) !bool {
    try bus.write_blocking(peer, &.{0x20}, timeout);
    var data: [pattern.len]u8 = undefined;
    try bus.read_blocking(peer, &data, timeout);
    return std.mem.eql(u8, &data, &pattern);
}

fn timed_read(bus: hal.i2c.I2C, register: u8) !u64 {
    try bus.write_blocking(peer, &.{register}, timeout);
    // Allow the peer to process STOP and its pointer before timing the read.
    hal.time.sleep_us(100);
    var data: [1]u8 = undefined;
    const start = hal.time.get_time_since_boot().to_us();
    try bus.read_blocking(peer, &data, timeout);
    const elapsed = hal.time.get_time_since_boot().to_us() - start;
    if (data[0] != 0xa5) return error.ValueMismatch;
    return elapsed;
}

fn stretch(bus: hal.i2c.I2C, results: *Results) !bool {
    results.normal_us = try timed_read(bus, 0xf2);
    results.stretch_us = try timed_read(bus, 0xf0);
    // The peer delays RD_REQ servicing by 20 us. Require at least 8 us of
    // additional transaction time, allowing for target-service latency in
    // the normal read. The stretch fits the configured SCL timeout
    // (C6 TRM §29.4.8).
    return results.stretch_us >= results.normal_us + 8;
}
