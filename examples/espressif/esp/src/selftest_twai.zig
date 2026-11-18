//! C6 pad: GPIO3, ESP32-C6 datasheet v1.6 Table 2-5, §§2.3.4–2.3.5.
//! General-purpose pad, outside strapping, USB and flash restrictions.
//! No transceiver or wiring: C3 GPIO4 / C6 GPIO3 carries both TWAI TX and RX.
//! ESP32-C3 TRM v1.4 §5.3 (matrix), §§31.4.1.2, 31.4.4, 31.4.6.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const twai = hal.twai;
const time = microzig.drivers.time;
const pad = hal.gpio.num(if (std.mem.eql(u8, microzig.config.chip_name, "ESP32-C6")) 3 else 4);

pub const std_options = microzig.std_options(.{ .logFn = hal.usb_serial_jtag.logger.log, .log_level = .info });
pub const panic = microzig.panic;
comptime {
    _ = microzig.export_startup();
}
pub fn init() void {
    const config: hal.clocks.Config = comptime .init_comptime(40_000_000);
    hal.init_sequence(config);
}

fn deadline(us: u64) time.Deadline {
    return .init_relative(hal.time.get_time_since_boot(), .from_us(us));
}

const Result = struct {
    controller_index: usize = 0,
    name: []const u8,
    detail: []const u8,
    failure: ?anyerror = null,
    ticks: ?u52 = null,
    fn log(self: Result) void {
        if (self.failure) |err| {
            std.log.info("SELFTEST twai {s}: FAIL {s} {s} controller={d}", .{ self.name, @errorName(err), self.detail, self.controller_index });
        } else {
            if (self.ticks) |ticks| {
                std.log.info("SELFTEST twai {s}: PASS ticks={d} {s} controller={d}", .{ self.name, ticks, self.detail, self.controller_index });
            } else {
                std.log.info("SELFTEST twai {s}: PASS {s} controller={d}", .{ self.name, self.detail, self.controller_index });
            }
        }
    }
};

fn Suite(comptime index: usize) type {
    return struct {
        const Can = twai.Instance(index);
        fn controller(comptime rate: twai.Bitrate, filter: twai.Filter, mode: twai.Mode) Can.Controller {
            return .init(.{ .timing = .init(40_000_000, rate), .mode = mode, .filter = filter, .tx = pad, .rx = pad });
        }

        fn identical(expected: twai.Frame, actual: twai.Frame) bool {
            const same_id = switch (expected.id) {
                .standard => |id| switch (actual.id) {
                    .standard => |other| id == other,
                    else => false,
                },
                .extended => |id| switch (actual.id) {
                    .extended => |other| id == other,
                    else => false,
                },
            };
            return same_id and expected.rtr == actual.rtr and expected.dlc == actual.dlc and
                (expected.rtr or std.mem.eql(u8, expected.data[0..expected.dlc], actual.data[0..actual.dlc]));
        }

        fn roundtrips(comptime rate: twai.Bitrate) !void {
            var can = controller(rate, .{}, .self_test);
            defer can.deinit();
            for ([_]twai.Identifier{ .{ .standard = 0x555 }, .{ .extended = 0x12345678 } }) |id| {
                for (0..9) |len| {
                    for ([_]bool{ false, true }) |rtr| {
                        var frame: twai.Frame = .{ .id = id, .dlc = @intCast(len), .rtr = rtr };
                        for (&frame.data, 0..) |*byte, i| byte.* = @as(u8, @intCast(i * 29 + len)) ^ 0xa5;
                        try can.transmit(frame, true, deadline(20_000));
                        const actual = try can.receive(deadline(20_000));
                        if (!identical(frame, actual)) return error.FrameMismatch;
                    }
                }
            }
            try can.clear_receive(deadline(20_000));
            try can.recover(deadline(20_000));
            const counters = Can.error_counters();
            if (counters.tx != 0 or counters.rx != 0 or counters.bus_off) return error.BusErrors;
        }

        fn expect_drop(can: *Can.Controller, id: twai.Identifier) !void {
            try can.transmit(.{ .id = id }, true, deadline(20_000));
            _ = can.receive(deadline(2_000)) catch |err| switch (err) {
                error.Timeout => return,
                else => return err,
            };
            return error.FilterAcceptedWrongId;
        }
        // ESP32-C3 TRM v1.4 §31.4.4.4; ESP32-C6 TRM v1.2 §33.4.4.4:
        // DLC above eight retains eight payload bytes on both TX and RX.
        fn raw_dlc() !void {
            var can = controller(.kbps500, .{}, .self_test);
            defer can.deinit();
            for ([_]twai.Identifier{ .{ .standard = 0x555 }, .{ .extended = 0x12345678 } }) |id| {
                for (9..16) |dlc| {
                    var frame: twai.Frame = .{ .id = id, .dlc = @intCast(dlc) };
                    for (&frame.data, 0..) |*byte, i| byte.* = @as(u8, @intCast(i * 29 + dlc)) ^ 0xa5;
                    try can.transmit(frame, true, deadline(20_000));
                    const actual = try can.receive(deadline(20_000));
                    // Compare all eight bytes explicitly: raw DLC must never index data.
                    if (actual.dlc != dlc or actual.rtr or
                        !std.meta.eql(frame.id, actual.id) or
                        !std.mem.eql(u8, &frame.data, &actual.data)) return error.FrameMismatch;
                }
            }
        }
        fn expect_pass(can: *Can.Controller, id: twai.Identifier) !void {
            const frame: twai.Frame = .{ .id = id, .dlc = 2, .data = .{ 0x12, 0x34, 0, 0, 0, 0, 0, 0 } };
            try can.transmit(frame, true, deadline(20_000));
            if (!identical(frame, try can.receive(deadline(20_000)))) return error.FilterRejectedMatchingId;
        }
        fn single_filter() !void {
            var can = controller(.kbps500, .standard(0x123), .self_test);
            defer can.deinit();
            try expect_drop(&can, .{ .standard = 0x124 });
            try expect_pass(&can, .{ .standard = 0x123 });
        }
        fn extended_filter() !void {
            var can = controller(.kbps500, .extended(0x12345678), .self_test);
            defer can.deinit();
            try expect_drop(&can, .{ .extended = 0x12345679 });
            try expect_pass(&can, .{ .extended = 0x12345678 });
        }
        fn dual_filter() !void {
            var can = controller(.kbps500, .dual_standard(0x123, 0x456), .self_test);
            defer can.deinit();
            try expect_drop(&can, .{ .standard = 0x124 });
            try expect_pass(&can, .{ .standard = 0x123 });
            try expect_pass(&can, .{ .standard = 0x456 });
        }

        fn listen_only() !void {
            var can = controller(.kbps125, .{}, .listen_only);
            defer can.deinit();
            can.start_transmit(.{ .id = .{ .standard = 1 } }, false) catch |err| switch (err) {
                error.ListenOnly => return,
                else => return err,
            };
            return error.ListenOnlyTransmitted;
        }

        // Observe 40 bit periods within a real frame, independently of the timing registers.
        // TRM v1.4 §§31.2.1, 31.2.2.1: MSB-first, stuffing after five equal bits.
        // ID 0x555, RTR/IDE/r0 = 0, DLC 8, data 0x55 has seven rising edges before
        // its alternating payload. Rising edges 10 and 30 are both in that payload,
        // separated by exactly 40 bits. 125 kbit/s gives 320 us (5120 systimer ticks).
        // The slower bitrate lets software observe edges without a capture peripheral.
        fn measure_bit_time(measured: *u52) !void {
            var can = controller(.kbps125, .{}, .self_test);
            defer can.deinit();
            hal.time.sleep_us(200);
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            const end = deadline(20_000);
            try can.start_transmit(.{ .id = .{ .standard = 0x555 }, .dlc = 8, .data = @splat(0x55) }, true);
            // Wait for SOF, then count actual pad transitions.
            while (pad.read() != 0) {
                if (end.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
            }
            var previous: u1 = 0;
            var rises: u8 = 0;
            var start: u52 = 0;
            while (rises < 30) {
                const level = pad.read();
                if (previous == 0 and level == 1) {
                    rises += 1;
                    if (rises == 10) start = hal.systimer.unit(0).read();
                    if (rises == 30) measured.* = hal.systimer.unit(0).read() -% start;
                }
                previous = level;
                if (end.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
            }
            try can.wait_transmit(end);
            const expected: u52 = 40 * 8 * hal.systimer.ticks_per_us();
            const difference = if (measured.* > expected) measured.* - expected else expected - measured.*;
            if (difference * 100 > expected * 2) return error.BitrateMismatch;
            const actual = try can.receive(end);
            if (!identical(.{ .id = .{ .standard = 0x555 }, .dlc = 8, .data = @splat(0x55) }, actual)) return error.FrameMismatch;
        }

        pub fn run() [10]Result {
            var results = [_]Result{
                .{ .name = "frames_125k", .detail = "36 standard/extended data/RTR frames DLC 0..8; zero error counters" },
                .{ .name = "frames_250k", .detail = "36 standard/extended data/RTR frames DLC 0..8; zero error counters" },
                .{ .name = "frames_500k", .detail = "36 standard/extended data/RTR frames DLC 0..8; zero error counters" },
                .{ .name = "frames_1M", .detail = "36 standard/extended data/RTR frames DLC 0..8; zero error counters" },
                .{ .name = "filter_single", .detail = "drop 0x124; receive 0x123" },
                .{ .name = "filter_extended", .detail = "drop 0x12345679; receive 0x12345678" },
                .{ .name = "filter_dual", .detail = "drop 0x124; receive 0x123 and 0x456" },
                .{ .name = "listen_only", .detail = "transmission rejected" },
                .{ .name = "bit_time_125k", .detail = "40 observed bit periods; expected=5120 ticks tolerance=2%" },
                .{ .name = "raw_dlc", .detail = "DLC 9..15; standard and extended; eight payload bytes and raw DLC" },
            };
            inline for (.{ twai.Bitrate.kbps125, twai.Bitrate.kbps250, twai.Bitrate.kbps500, twai.Bitrate.mbps1 }, 0..) |rate, i| {
                roundtrips(rate) catch |err| {
                    results[i].failure = err;
                };
            }
            single_filter() catch |err| {
                results[4].failure = err;
            };
            extended_filter() catch |err| {
                results[5].failure = err;
            };
            dual_filter() catch |err| {
                results[6].failure = err;
            };
            listen_only() catch |err| {
                results[7].failure = err;
            };
            var measured: u52 = 0;
            measure_bit_time(&measured) catch |err| {
                results[8].failure = err;
            };
            results[8].ticks = measured;
            raw_dlc() catch |err| {
                results[9].failure = err;
            };
            for (&results) |*result| result.controller_index = index;
            return results;
        }
    };
}

pub fn main() void {
    var results: [twai.controller_count][10]Result = undefined;
    inline for (0..twai.controller_count) |index| results[index] = Suite(index).run();
    var failures: usize = 0;
    for (results) |checks| {
        for (checks) |result| {
            if (result.failure != null) {
                failures += 1;
            }
        }
    }
    hal.time.sleep_ms(1500);
    while (true) {
        for (results) |checks| for (checks) |result| result.log();
        std.log.info("SELFTEST twai DONE pass={d} fail={d}", .{ results.len * 10 - failures, failures });
        hal.time.sleep_ms(1000);
    }
}
