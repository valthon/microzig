//! ESP32-C3/C6 CAN 2.0 controller, polling interface.
//! Hardware layout and sequences: ESP32-C3 TRM v1.4, §§31.3.1, 31.4.1–31.4.7;
//! ESP32-C6 TRM v1.2, §§33.3–33.6 and PCR §8.5.1.
//! One owner must serialize access, including configuration and recovery. No IRQ handler is installed.

const chip_specific = switch (@import("compatibility.zig").chip) {
    .esp32_c3 => @import("twai/esp32_c3.zig"),
    .esp32_c6 => @import("twai/esp32_c6.zig"),
};
pub const controller_count = chip_specific.controller_count;

const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const Deadline = microzig.drivers.time.Deadline;

pub const Error = error{ Timeout, BusOff, Busy, ListenOnly, InvalidFrame, Overrun, NotTransmitting };
pub const Mode = enum { normal, listen_only, self_test };
pub const Bitrate = enum(u32) { kbps125 = 125_000, kbps250 = 250_000, kbps500 = 500_000, mbps1 = 1_000_000 };
pub const Identifier = union(enum) { standard: u11, extended: u29 };
pub const Frame = struct {
    id: Identifier,
    rtr: bool = false,
    /// Raw wire DLC. Data frames carry min(dlc, 8) bytes; remote frames carry none.
    /// ESP32-C3 TRM v1.4 §31.4.4.4; ESP32-C6 TRM v1.2 §33.4.4.4 (TX and RX).
    dlc: u4 = 0,
    data: [8]u8 = @splat(0),
};

pub const Timing = struct {
    prescaler: u13,
    /// Encoded segment lengths (actual length minus one).
    segment1: u4 = 14,
    segment2: u3 = 3,

    /// 20 Tq per bit, 80% sample point, SJW = 1 Tq (§31.4.2).
    /// Supply the source frequency: APB on C3, XTAL on C6. Keep it fixed while running.
    pub fn init(comptime source_hz: u32, comptime bitrate: Bitrate) Timing {
        const divisor = 2 * 20 * @backingInt(bitrate);
        if (source_hz % divisor != 0 or source_hz / divisor < 1 or source_hz / divisor > 8192)
            @compileError("TWAI bitrate cannot be represented at this source clock");
        return .{ .prescaler = source_hz / divisor - 1 };
    }
};

pub const Filter = struct {
    pub const FilterMode = enum { single, dual };
    mode: FilterMode = .single,
    /// TRM §31.4.6: code/mask bytes 0..3, most significant byte first.
    /// Mask bits set to one are ignored. Dual mode uses two 16-bit filters;
    /// extended IDs then match only their upper 16 bits. Frame format is not filtered.
    code: u32 = 0,
    mask: u32 = 0xffff_ffff,

    pub fn standard(id: u11) Filter {
        return .{ .code = @as(u32, id) << 21, .mask = 0x001f_ffff };
    }

    pub fn extended(id: u29) Filter {
        return .{ .code = @as(u32, id) << 3, .mask = 7 };
    }

    pub fn dual_standard(first: u11, second: u11) Filter {
        return .{
            .mode = .dual,
            .code = (@as(u32, first) << 21) | (@as(u32, second) << 5),
            .mask = 0x001f_001f,
        };
    }
};

pub const Config = struct {
    timing: Timing,
    mode: Mode = .normal,
    filter: Filter = .{},
    tx: hal.gpio.Pin,
    rx: hal.gpio.Pin,
};

pub const ErrorCounters = struct { tx: u8, rx: u8, bus_off: bool };
pub const Command = enum { abort_tx, release_rx, clear_overrun };
/// The original Controller and error_counters names select controller zero.
pub const Controller = Instance(0).Controller;
pub const error_counters = Instance(0).error_counters;

/// Independent controller namespace; C3 has index 0, C6 has indices 0 and 1.
/// Each controller exclusively owns its selected register bank and GPIO routes.
pub fn Instance(comptime controller_index: usize) type {
    return struct {
        const hw = chip_specific.Instance(controller_index);
        pub const Controller = struct {
            const Self = @This();
            mode: Mode,
            pending: bool = false,

            /// TX and RX may share a pad for self-test without a transceiver (TRM §5.3, Table 5.3-1).
            pub fn init(config: Config) Self {
                const cs = microzig.interrupt.enter_critical_section();
                defer cs.leave();
                hw.init(config);
                return .{ .mode = config.mode };
            }

            /// Nonblocking request; self_receive uses the self-reception command (§31.6, CMD).
            pub fn start_transmit(self: *Self, frame: Frame, self_receive: bool) Error!void {
                if (self.mode == .listen_only) return error.ListenOnly;
                if (hw.status().bus_off != 0) return error.BusOff;
                if (self.pending or hw.status().tx_free == 0) return error.Busy;
                const bytes = try encode(frame);
                inline for (0..13) |i| write_byte(i, bytes[i]);
                self.pending = true;
                hw.start_transmit(self_receive);
            }

            /// On timeout, cancel retries. An already active frame can finish (§31.4.4, §31.6 CMD).
            pub fn wait_transmit(self: *Self, deadline: Deadline) Error!void {
                if (!self.pending) return error.NotTransmitting;
                defer self.pending = false;
                while (true) {
                    const status = hw.status();
                    if (status.bus_off != 0) return error.BusOff;
                    if (status.tx_free != 0 and status.tx_complete != 0) return;
                    if (deadline.is_reached_by(hal.time.get_time_since_boot())) {
                        command(.abort_tx);
                        return error.Timeout;
                    }
                }
            }

            pub fn transmit(self: *Self, frame: Frame, self_receive: bool, deadline: Deadline) Error!void {
                // Waiting for a free buffer and transmission share the caller's deadline.
                while (true) {
                    self.start_transmit(frame, self_receive) catch |err| switch (err) {
                        error.Busy => {
                            if (self.pending) return error.Busy;
                            if (deadline.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
                            continue;
                        },
                        else => return err,
                    };
                    break;
                }
                return self.wait_transmit(deadline);
            }

            pub fn receive(_: *Self, deadline: Deadline) Error!Frame {
                while (true) {
                    const status = hw.status();
                    if (status.bus_off != 0) return error.BusOff;
                    if (status.rx_ready != 0) {
                        defer command(.release_rx);
                        if (status.miss != 0) return error.Overrun;
                        var bytes: [13]u8 = undefined;
                        inline for (0..13) |i| bytes[i] = read_byte(i);
                        return decode(bytes);
                    }
                    if (deadline.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
                }
            }

            /// Drain valid and incomplete RX messages after an overrun (§31.4.5).
            pub fn clear_receive(_: *Self, deadline: Deadline) Error!void {
                while (hw.message_count() != 0) {
                    if (deadline.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
                    command(.release_rx);
                }
                command(.clear_overrun);
            }

            /// Recovery observes 128 groups of 11 recessive bits; never resets TEC to skip recovery (§31.4.7.3).
            pub fn recover(self: *Self, deadline: Deadline) Error!void {
                if (hw.status().bus_off == 0) return;
                self.pending = false;
                hw.begin_recovery();
                while (hw.status().bus_off != 0) {
                    if (deadline.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
                }
            }

            pub fn deinit(self: *Self) void {
                hw.deinit();
                self.pending = false;
            }
        };

        pub fn error_counters() ErrorCounters {
            return .{ .tx = hw.regs.TX_ERR_CNT.read().TX_ERR_CNT, .rx = hw.regs.RX_ERR_CNT.read().RX_ERR_CNT, .bus_off = hw.status().bus_off != 0 };
        }
        const command = hw.command;
        fn write_byte(comptime index: usize, byte: u8) void {
            @field(hw.regs, std.fmt.comptimePrint("DATA_{d}", .{index})).write_raw(byte);
        }
        fn read_byte(comptime index: usize) u8 {
            return @truncate(@field(hw.regs, std.fmt.comptimePrint("DATA_{d}", .{index})).raw);
        }
    };
}

fn encode(frame: Frame) Error![13]u8 {
    var bytes: [13]u8 = @splat(0);
    bytes[0] = @as(u8, frame.dlc) | (if (frame.rtr) @as(u8, 0x40) else 0);
    var start: usize = undefined;
    switch (frame.id) {
        .standard => |id| {
            bytes[1] = @intCast(id >> 3);
            bytes[2] = (@as(u8, @truncate(id)) << 5) | (if (frame.rtr) @as(u8, 0x10) else 0);
            start = 3;
        },
        .extended => |id| {
            bytes[0] |= 0x80;
            bytes[1] = @intCast(id >> 21);
            bytes[2] = @truncate(id >> 13);
            bytes[3] = @truncate(id >> 5);
            bytes[4] = (@as(u8, @truncate(id)) << 3) | (if (frame.rtr) @as(u8, 4) else 0);
            start = 5;
        },
    }
    const len = @min(frame.dlc, 8);
    if (!frame.rtr) @memcpy(bytes[start..][0..len], frame.data[0..len]);
    return bytes;
}

fn decode(bytes: [13]u8) Error!Frame {
    const extended = bytes[0] & 0x80 != 0;
    var frame: Frame = .{
        .id = if (extended) .{ .extended = (@as(u29, bytes[1]) << 21) | (@as(u29, bytes[2]) << 13) | (@as(u29, bytes[3]) << 5) | (bytes[4] >> 3) } else .{ .standard = (@as(u11, bytes[1]) << 3) | (bytes[2] >> 5) },
        .rtr = bytes[0] & 0x40 != 0,
        .dlc = @truncate(bytes[0]),
    };
    const start: usize = if (extended) 5 else 3;
    const len = @min(frame.dlc, 8);
    if (!frame.rtr) @memcpy(frame.data[0..len], bytes[start..][0..len]);
    return frame;
}

test "CAN buffer wire layout and RTR payload" {
    const testing = std.testing;
    const standard = try encode(.{ .id = .{ .standard = 0x7ff }, .dlc = 2, .data = .{ 0xab, 0xcd, 0, 0, 0, 0, 0, 0 } });
    try testing.expectEqualSlices(u8, &.{ 2, 0xff, 0xe0, 0xab, 0xcd }, standard[0..5]);
    const extended = try encode(.{ .id = .{ .extended = 0x12345678 }, .rtr = true, .dlc = 8 });
    try testing.expectEqualSlices(u8, &.{ 0xc8, 0x91, 0xa2, 0xb3, 0xc4, 0 }, extended[0..6]);
    for ([_]Identifier{ .{ .standard = 0 }, .{ .standard = 0x7ff }, .{ .extended = 0 }, .{ .extended = 0x1fff_ffff } }) |id| {
        for (0..9) |len| {
            for ([_]bool{ false, true }) |rtr| {
                const frame: Frame = .{ .id = id, .dlc = @intCast(len), .rtr = rtr, .data = @splat(if (rtr) 0 else 0xa5) };
                const result = try decode(try encode(frame));
                try testing.expectEqualDeep(frame.id, result.id);
                try testing.expectEqual(frame.dlc, result.dlc);
                try testing.expectEqual(frame.rtr, result.rtr);
                try testing.expectEqualSlices(u8, frame.data[0..len], result.data[0..len]);
            }
        }
    }
}

test "DLC 9 through 15 preserves raw code and limits payload to eight bytes" {
    const payload = [8]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 };
    for (9..16) |dlc| {
        for ([_]bool{ false, true }) |extended| {
            for ([_]bool{ false, true }) |rtr| {
                // Construct RX bytes independently of encode, including nonzero RTR data.
                var wire: [13]u8 = @splat(0);
                wire[0] = @as(u8, @intCast(dlc)) | (if (extended) @as(u8, 0x80) else 0) | (if (rtr) @as(u8, 0x40) else 0);
                const start: usize = if (extended) 5 else 3;
                @memcpy(wire[start..][0..8], &payload);
                const frame = try decode(wire);
                try std.testing.expectEqual(dlc, frame.dlc);
                try std.testing.expectEqual(rtr, frame.rtr);
                const expected: [8]u8 = if (rtr) @splat(0) else payload;
                try std.testing.expectEqualSlices(u8, &expected, &frame.data);

                const encoded = try encode(.{
                    .id = if (extended) .{ .extended = 0 } else .{ .standard = 0 },
                    .dlc = @intCast(dlc),
                    .rtr = rtr,
                    .data = payload,
                });
                try std.testing.expectEqual(wire[0], encoded[0]);
                try std.testing.expectEqualSlices(u8, &expected, encoded[start..][0..8]);
            }
        }
    }
}

test "exact APB timing at 40 and 80 MHz" {
    inline for (.{ 40_000_000, 80_000_000 }) |apb| {
        inline for (std.enums.values(Bitrate)) |rate| {
            const timing = Timing.init(apb, rate);
            try std.testing.expectEqual(@backingInt(rate), apb / (2 * (@as(u32, timing.prescaler) + 1) * (1 + @as(u32, timing.segment1) + 1 + @as(u32, timing.segment2) + 1)));
        }
    }
}
