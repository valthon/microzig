//! Polling RX flow from ESP-IDF v5.5.1 esp_ieee802154_dev.c:
//! isr_handle_rx_phase_rx_abort -> NEEDS_NEXT_OPT -> enable_rx.
const std = @import("std");

pub const Error = error{ InvalidDuration, InvalidFrame, Timeout, Crc, RxAborted, AckTransmitFailed };
pub const Frame = struct {
    /// FCS is checked by hardware and omitted. RSSI/LQI occupy its DMA slots.
    data: [125]u8,
    len: u7,
    rssi: i8,
    lqi: u8,

    pub fn bytes(self: *const Frame) []const u8 {
        return self.data[0..self.len];
    }
};

pub const Events = struct {
    abort: ?u5 = null,
    done: bool = false,
    ack_done: bool = false,
};

/// The hardware adapter supplies time, event snapshots, RX_START, volatile
/// DMA reads and pending-bit writes. Tests supply a stopped-on-abort MAC.
pub fn receive(io: anytype, timeout_us: u32) Error!Frame {
    if (timeout_us == 0) return error.InvalidDuration;
    const deadline = io.now() + timeout_us;
    io.start();
    var received = false;
    var crc_seen = false;
    while (io.now() < deadline) {
        const events = io.poll();
        if (events.abort) |reason| {
            switch (reason) {
                // SFD timeout, CRC, invalid length, filter failure, no RSS,
                // coexistence break, unexpected ACK, RX restart. IDF marks
                // all of these NEEDS_NEXT_OPT(true) while in STATE_RX.
                2...9 => {
                    crc_seen = crc_seen or reason == 3;
                    received = false;
                    io.start();
                    // Discard completion bits/data belonging to the aborted
                    // frame. Restart never extends the caller's deadline.
                    continue;
                },
                else => return if (received) error.AckTransmitFailed else error.RxAborted,
            }
        }
        if (events.done) received = true;
        if (received) {
            const len = io.load(0) & 0x7f;
            if (len < 5) return error.InvalidFrame;
            const needs_ack = io.auto_ack() and io.load(1) & 0x20 != 0 and io.load(2) & 0x30 <= 0x10;
            if (needs_ack and events.done) io.set_pending();
            if (!needs_ack or events.ack_done) {
                var result: Frame = .{
                    .data = undefined,
                    .len = @intCast(len - 2),
                    .rssi = @bitCast(io.load(len - 1)),
                    .lqi = io.load(len),
                };
                for (result.data[0..result.len], 1..) |*byte, i| byte.* = io.load(i);
                return result;
            }
        }
        io.spin();
    }
    return if (crc_seen) error.Crc else error.Timeout;
}

const Mock = struct {
    events: []const Events,
    index: usize = 0,
    clock: u64 = 0,
    starts: usize = 0,
    active: bool = false,
    ack_enabled: bool = false,
    pending_writes: usize = 0,
    frame: [6]u8 = .{ 5, 1, 0, 42, 0xd6, 99 },

    fn now(self: *Mock) u64 {
        return self.clock;
    }

    fn start(self: *Mock) void {
        self.starts += 1;
        self.active = true;
    }

    fn poll(self: *Mock) Events {
        // Event reads advance fake time even on the abort/continue path.
        self.clock += 1;
        if (!self.active or self.index == self.events.len) return .{};
        const event = self.events[self.index];
        self.index += 1;
        if (event.abort != null or (event.done and !self.ack_enabled)) self.active = false;
        return event;
    }

    fn auto_ack(self: *Mock) bool {
        return self.ack_enabled;
    }

    fn set_pending(self: *Mock) void {
        self.pending_writes += 1;
    }

    fn load(self: *Mock, index: usize) u8 {
        return self.frame[index];
    }

    fn spin(_: *Mock) void {}
};

test "each recoverable RX abort restarts stopped MAC before next valid frame" {
    for (2..10) |reason| {
        const events = [_]Events{ .{ .abort = @intCast(reason) }, .{ .done = true } };
        var io: Mock = .{ .events = &events };
        const frame = try receive(&io, 10);
        try std.testing.expectEqual(@as(usize, 2), io.starts);
        try std.testing.expectEqual(@as(usize, 2), io.index);
        try std.testing.expectEqualSlices(u8, &.{ 1, 0, 42 }, frame.bytes());
        try std.testing.expectEqual(@as(i8, -42), frame.rssi);
        try std.testing.expectEqual(@as(u8, 99), frame.lqi);
    }
}

test "filtered frame then valid frame completes within original receive window" {
    // Include stale completion bits on the rejected frame: only the later
    // valid frame may complete the receive call.
    const events = [_]Events{ .{ .abort = 5, .done = true, .ack_done = true }, .{}, .{ .done = true } };
    var io: Mock = .{ .events = &events };
    _ = try receive(&io, 4);
    try std.testing.expectEqual(@as(usize, 2), io.starts);
    try std.testing.expectEqual(@as(usize, 3), io.index);

    var late: Mock = .{ .events = &events };
    try std.testing.expectError(error.Timeout, receive(&late, 2));
    try std.testing.expectEqual(@as(u64, 2), late.clock);
    try std.testing.expectEqual(@as(usize, 2), late.starts);
    try std.testing.expectEqual(@as(usize, 2), late.index);
}

test "CRC restarts RX and remains visible if no valid frame arrives" {
    const events = [_]Events{.{ .abort = 3 }};
    var io: Mock = .{ .events = &events };
    try std.testing.expectError(error.Crc, receive(&io, 3));
    try std.testing.expectEqual(@as(usize, 2), io.starts);
    try std.testing.expectEqual(@as(u64, 3), io.clock);
}

test "stop and ACK-phase aborts do not restart RX" {
    for ([_]u5{ 1, 16, 17, 18, 19, 24, 25, 26 }) |reason| {
        const events = [_]Events{.{ .abort = reason }};
        var io: Mock = .{ .events = &events };
        try std.testing.expectError(error.RxAborted, receive(&io, 3));
        try std.testing.expectEqual(@as(usize, 1), io.starts);
    }
}

test "legacy auto-ACK still waits for completion and reports ACK-phase abort" {
    const events = [_]Events{ .{ .done = true }, .{ .ack_done = true } };
    var io: Mock = .{ .events = &events, .ack_enabled = true };
    io.frame[1] |= 0x20;
    _ = try receive(&io, 4);
    try std.testing.expectEqual(@as(usize, 2), io.index);
    try std.testing.expectEqual(@as(usize, 1), io.pending_writes);
    try std.testing.expectEqual(@as(usize, 1), io.starts);

    const aborted = [_]Events{ .{ .done = true }, .{ .abort = 16 } };
    var failed: Mock = .{ .events = &aborted, .ack_enabled = true };
    failed.frame[1] |= 0x20;
    try std.testing.expectError(error.AckTransmitFailed, receive(&failed, 4));
    try std.testing.expectEqual(@as(usize, 1), failed.starts);
}
