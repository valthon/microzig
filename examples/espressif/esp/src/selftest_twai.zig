//! External CAN test through an Adafruit CAN Pal and WeAct SLCAN adapter.
//! ESP C6 GPIO20 TX -> CAN Pal TX, GPIO17 RX <- CAN Pal RX;
//! ESP C3 uses GPIO4 TX and GPIO7 RX instead. Wire CAN Pal VCC to 3V3,
//! GND to ESP GND; CANH/CANL to the adapter's CANH/CANL, common GND.
//! Enable 120-ohm termination at both ends. Start this image, then run
//! `python can_echo.py --esp <ESP-port> --can <adapter-port>`.
//! PASS: SELFTEST twai DONE pass=12 fail=0 on C3, pass=24 fail=0 on C6
//! (both controllers), and host exit 0. DLC 0..8 echoes preserve format, DLC,
//! RTR and payload with ID XOR 1. DLC 9..15 data frames use self-reception
//! and a DLC 8 host reply: ID XOR 1, first seven bytes, then the raw DLC.
//! Checks also cover filters, listen-only, bit timing, bus-off and recovery.
//! ESP32-C3 TRM v1.4 §31; ESP32-C6 TRM v1.2 §33.
//! Protocol: info listen_done and recover_ready repeat until a host byte
//! (120 s limit), allowing the adapter to close/reopen after listen-only
//! traffic and bus_off before the next test starts.
//! Recovery re-initializes the controller at 500k: this tests recover() after
//! re-init, not recovery of a controller left in bus-off.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const twai = hal.twai;
const time = microzig.drivers.time;
const is_c6 = std.mem.eql(u8, microzig.config.chip_name, "ESP32-C6");
const tx = hal.gpio.num(if (is_c6) 20 else 4);
const rx = hal.gpio.num(if (is_c6) 17 else 7);

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
            if (self.ticks) |ticks| {
                std.log.info("SELFTEST twai {s}: FAIL error={s} ticks={d} {s} controller={d}", .{ self.name, @errorName(err), ticks, self.detail, self.controller_index });
            } else {
                std.log.info("SELFTEST twai {s}: FAIL error={s} {s} controller={d}", .{ self.name, @errorName(err), self.detail, self.controller_index });
            }
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
            return .init(.{ .timing = .init(40_000_000, rate), .mode = mode, .filter = filter, .tx = tx, .rx = rx });
        }

        fn stop(can: *Can.Controller) void {
            can.deinit();
            tx.apply(.{});
            rx.apply(.{});
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
                (expected.rtr or std.mem.eql(u8, expected.data[0..@min(expected.dlc, 8)], actual.data[0..@min(actual.dlc, 8)]));
        }

        fn roundtrips(comptime rate: twai.Bitrate) !void {
            var can = controller(rate, .{}, .normal);
            defer stop(&can);
            for ([_]twai.Identifier{ .{ .standard = 0x555 }, .{ .extended = 0x12345678 } }) |id| {
                for (0..9) |len| {
                    for ([_]bool{ false, true }) |rtr| {
                        var frame: twai.Frame = .{ .id = id, .dlc = @intCast(len), .rtr = rtr };
                        for (&frame.data, 0..) |*byte, i| byte.* = @as(u8, @intCast(i * 29 + len)) ^ 0xa5;
                        try can.transmit(frame, false, deadline(500_000));
                        const actual = try can.receive(deadline(500_000));
                        if (!identical(echo(frame), actual)) return error.FrameMismatch;
                    }
                }
            }
            try can.clear_receive(deadline(500_000));
            const counters = Can.error_counters();
            if (counters.tx != 0 or counters.rx != 0 or counters.bus_off) return error.BusErrors;
        }

        fn expect_drop(can: *Can.Controller, id: twai.Identifier) !void {
            try can.transmit(.{ .id = id }, false, deadline(500_000));
            _ = can.receive(deadline(100_000)) catch |err| switch (err) {
                error.Timeout => return,
                else => return err,
            };
            return error.FilterAcceptedWrongId;
        }
        // ESP32-C3 TRM v1.4 §31.4.4.4; ESP32-C6 TRM v1.2 §33.4.4.4:
        // DLC above eight retains eight payload bytes on both TX and RX.
        // Self-reception (§31.6 / §33.6 CMD) reads the frame back from the bus. The host
        // confirms what crossed the wire with a DLC 8 reply: ID ^ 1, the first seven
        // bytes, then the raw DLC it received.
        fn raw_dlc() !void {
            var can = controller(.kbps500, .{}, .normal);
            defer stop(&can);
            for ([_]twai.Identifier{ .{ .standard = 0x555 }, .{ .extended = 0x12345678 } }) |id| {
                for (9..16) |dlc| {
                    var frame: twai.Frame = .{ .id = id, .dlc = @intCast(dlc) };
                    for (&frame.data, 0..) |*byte, i| byte.* = @as(u8, @intCast(i * 29 + dlc)) ^ 0xa5;
                    try can.transmit(frame, true, deadline(500_000));
                    const own = try can.receive(deadline(500_000));
                    // Compare all eight bytes explicitly: raw DLC must never index data.
                    if (own.dlc != dlc or own.rtr or !std.meta.eql(frame.id, own.id) or
                        !std.mem.eql(u8, &frame.data, &own.data)) return error.FrameMismatch;
                    const reply = try can.receive(deadline(500_000));
                    if (reply.dlc != 8 or reply.rtr or !std.meta.eql(echo(frame).id, reply.id) or
                        !std.mem.eql(u8, frame.data[0..7], reply.data[0..7]) or
                        reply.data[7] != dlc) return error.HostSawWrongFrame;
                }
            }
        }
        fn expect_pass(can: *Can.Controller, id: twai.Identifier) !void {
            const frame: twai.Frame = .{ .id = id, .dlc = 2, .data = .{ 0x12, 0x34, 0, 0, 0, 0, 0, 0 } };
            try can.transmit(frame, false, deadline(500_000));
            if (!identical(echo(frame), try can.receive(deadline(500_000)))) return error.FilterRejectedMatchingId;
        }
        fn single_filter() !void {
            var can = controller(.kbps500, .standard(0x123), .normal);
            defer stop(&can);
            try expect_drop(&can, .{ .standard = 0x125 });
            try expect_pass(&can, .{ .standard = 0x122 });
        }
        fn extended_filter() !void {
            var can = controller(.kbps500, .extended(0x12345678), .normal);
            defer stop(&can);
            try expect_drop(&can, .{ .extended = 0x1234567a });
            try expect_pass(&can, .{ .extended = 0x12345679 });
        }
        fn dual_filter() !void {
            var can = controller(.kbps500, .dual_standard(0x123, 0x456), .normal);
            defer stop(&can);
            try expect_drop(&can, .{ .standard = 0x125 });
            try expect_pass(&can, .{ .standard = 0x122 });
            try expect_pass(&can, .{ .standard = 0x457 });
        }

        fn listen_only() !void {
            var can = controller(.kbps500, .{}, .normal);
            defer stop(&can);
            defer wait_host(.kbps500, "listen_done") catch {};
            try can.transmit(.{ .id = .{ .standard = 0x7e0 }, .dlc = 1, .data = .{ 1, 0, 0, 0, 0, 0, 0, 0 } }, false, deadline(500_000));
            stop(&can);
            can = controller(.kbps500, .{}, .listen_only);
            // ESP32-C3 TRM v1.4 §31.4.7 / ESP32-C6 TRM v1.2 §33.4.7:
            // Nothing acknowledges the host's frames. A one-shot adapter becomes
            // error passive after 16 of them (TEC 128) and its recessive error flags
            // then leave the following frames valid here, so the host keeps sending
            // until listen_done. Its close/reopen ends before it acknowledges.
            var received: usize = 0;
            const end = deadline(2_000_000);
            while (received < 3) {
                const frame = try can.receive(end);
                if (!std.meta.eql(frame.id, twai.Identifier{ .standard = 0x7e1 })) return error.FrameMismatch;
                received += 1;
            }
            can.start_transmit(.{ .id = .{ .standard = 1 } }, false) catch |err| switch (err) {
                error.ListenOnly => return,
                else => return err,
            };
            return error.ListenOnlyTransmitted;
        }

        fn echo(frame: twai.Frame) twai.Frame {
            var result = frame;
            result.id = switch (frame.id) {
                .standard => |id| .{ .standard = id ^ 1 },
                .extended => |id| .{ .extended = id ^ 1 },
            };
            return result;
        }

        fn wait_host(comptime rate: twai.Bitrate, comptime info: ?[]const u8) !void {
            var byte: [1]u8 = undefined;
            const end = deadline(120_000_000);
            while (!end.is_reached_by(hal.time.get_time_since_boot())) {
                if (info) |what| {
                    std.log.info("SELFTEST twai info " ++ what, .{});
                } else {
                    std.log.info("SELFTEST twai ready {d} controller={d} controllers={d}", .{ @backingInt(rate), index, twai.controller_count });
                }
                const next = time.Deadline.init_absolute(.from_us(@min(
                    end.timeout.to_us(),
                    hal.time.get_time_since_boot().to_us() + 1_000_000,
                )));
                _ = hal.usb_serial_jtag.read_blocking(&byte, next) catch continue;
                return;
            }
            return error.NoHost;
        }

        const rx_signal = @field(hal.gpio.InputSignal, if (!is_c6) "twai_rx" else if (index == 0) "twai0_rx" else "twai1_rx");

        // Error confinement: C3 TRM v1.4 §31.4.7 / C6 TRM v1.2 §33.4.7. In the data field,
        // RX is switched to a constant dominant level (GPIO matrix, C3 TRM §5.4.3 / C6 TRM
        // §7.4.3): the next recessive bit is a bit error, and each further eight dominant
        // bits add 8 to TEC, so the controller must reach bus-off within one second.
        // A dominant read in the arbitration field only loses arbitration, and
        // before SOF the controller would wait for bus idle. ID 0x555, DLC 8 has no stuff
        // bits before its data field, which spans bits 19-82: [38, 166) us at
        // 500 kbit/s (2 us/bit). Switch at 90 us, 45 bits after the TX request,
        // inside the data field. The host also runs at 500 kbit/s, so its active
        // error flags cannot disrupt the frame through a bitrate mismatch.
        fn bus_off() !void {
            var can = controller(.kbps500, .{}, .normal);
            defer stop(&can);
            hal.time.sleep_us(200); // bus idle: 11 recessive bits are 22 us at 500 kbit/s
            {
                const cs = microzig.interrupt.enter_critical_section();
                defer cs.leave();
                try can.start_transmit(.{ .id = .{ .standard = 0x555 }, .dlc = 8, .data = @splat(0x55) }, false);
                hal.time.sleep_us(90);
                hal.gpio.connect_constant_to_peripheral(rx_signal, 0);
            }
            can.wait_transmit(deadline(1_000_000)) catch |err| switch (err) {
                error.BusOff => {
                    if (!Can.error_counters().bus_off) return error.ExpectedBusOff;
                    return;
                },
                else => return err,
            };
            return error.ExpectedBusOff;
        }

        fn recover() !void {
            try wait_host(.kbps500, "recover_ready");
            var can = controller(.kbps500, .{}, .normal);
            defer stop(&can);
            try can.recover(deadline(1_000_000));
            try expect_pass(&can, .{ .standard = 0x122 });
            const counters = Can.error_counters();
            if (counters.tx != 0 or counters.rx != 0 or counters.bus_off) return error.BusErrors;
        }

        // Observe 40 bit periods within a real frame, independently of the timing registers.
        // TRM v1.4 §§31.2.1, 31.2.2.1: MSB-first, stuffing after five equal bits.
        // ID 0x555, RTR/IDE/r0 = 0, DLC 8, data 0x55 has seven rising edges before
        // its alternating payload. Rising edges 10 and 30 are both in that payload,
        // separated by exactly 40 bits. 125 kbit/s gives 320 us (5120 systimer ticks).
        // The slower bitrate lets software observe edges without a capture peripheral.
        fn measure_bit_time(measured: *u52) !void {
            var can = controller(.kbps125, .{}, .normal);
            defer stop(&can);
            hal.time.sleep_us(200);
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            const end = deadline(500_000);
            try can.start_transmit(.{ .id = .{ .standard = 0x555 }, .dlc = 8, .data = @splat(0x55) }, false);
            // Wait for SOF, then count actual pad transitions.
            while (rx.read() != 0) {
                if (end.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
            }
            // Stamp every rising edge the same way, so no code path runs for the first
            // time (a flash cache miss, several microseconds) between edges 10 and 30.
            var stamps: [30]u52 = undefined;
            var previous: u1 = 0;
            var rises: u8 = 0;
            while (rises < stamps.len) {
                const level = rx.read();
                if (previous == 0 and level == 1) {
                    stamps[rises] = hal.systimer.unit(0).read();
                    rises += 1;
                }
                previous = level;
                if (end.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
            }
            measured.* = stamps[29] -% stamps[9];
            try can.wait_transmit(end);
            const expected: u52 = 40 * 8 * hal.systimer.ticks_per_us();
            const difference = if (measured.* > expected) measured.* - expected else expected - measured.*;
            if (difference * 100 > expected * 2) return error.BitrateMismatch;
            const actual = try can.receive(end);
            if (!identical(echo(.{ .id = .{ .standard = 0x555 }, .dlc = 8, .data = @splat(0x55) }), actual)) return error.FrameMismatch;
        }

        pub fn run() [12]Result {
            var results = [_]Result{
                .{ .name = "frames_125k", .detail = "36 external echoes; zero error counters" },
                .{ .name = "frames_250k", .detail = "36 external echoes; zero error counters" },
                .{ .name = "frames_500k", .detail = "36 external echoes; zero error counters" },
                .{ .name = "frames_1M", .detail = "36 external echoes; zero error counters" },
                .{ .name = "filter_single", .detail = "drop echo 0x124; receive 0x123" },
                .{ .name = "filter_extended", .detail = "drop echo 0x1234567b; receive 0x12345678" },
                .{ .name = "filter_dual", .detail = "drop echo 0x124; receive 0x123 and 0x456" },
                .{ .name = "listen_only", .detail = "three external frames; transmission rejected" },
                .{ .name = "bit_time_125k", .detail = "40 RX pad bit periods; tolerance=2%" },
                .{ .name = "raw_dlc", .detail = "std/ext DLC 9..15 self-received; host saw raw DLC" },
                .{ .name = "bus_off", .detail = "RX held dominant in data field; deadline=1s" },
                .{ .name = "recover", .detail = "re-init 500k; recover; clean echo" },
            };
            inline for (.{ twai.Bitrate.kbps125, twai.Bitrate.kbps250, twai.Bitrate.kbps500, twai.Bitrate.mbps1 }, 0..) |rate, i| {
                const host_error: ?anyerror = blk: {
                    wait_host(rate, null) catch |err| break :blk err;
                    break :blk null;
                };
                if (host_error) |err| {
                    results[i].failure = err;
                    if (rate == .kbps125) results[8].failure = err;
                    if (rate == .kbps500) {
                        for ([_]usize{ 4, 5, 6, 7, 9, 10, 11 }) |n| results[n].failure = err;
                    }
                } else {
                    roundtrips(rate) catch |err| {
                        results[i].failure = err;
                    };
                    if (rate == .kbps125) {
                        var measured: u52 = 0;
                        measure_bit_time(&measured) catch |err| {
                            results[8].failure = err;
                        };
                        results[8].ticks = measured;
                    }
                    if (rate == .kbps500) {
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
                        raw_dlc() catch |err| {
                            results[9].failure = err;
                        };
                        bus_off() catch |err| {
                            results[10].failure = err;
                        };
                        recover() catch |err| {
                            results[11].failure = err;
                        };
                    }
                }
                std.log.info("SELFTEST twai info rate_done {d}", .{@backingInt(rate)});
            }
            for (&results) |*result| result.controller_index = index;
            return results;
        }
    };
}

pub fn main() void {
    var results: [twai.controller_count][12]Result = undefined;
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
        std.log.info("SELFTEST twai DONE pass={d} fail={d}", .{ results.len * 12 - failures, failures });
        hal.time.sleep_ms(1000);
    }
}
