//! Polling RX flow from ESP-IDF v5.5.1 esp_ieee802154_dev.c:
//! isr_handle_rx_phase_rx_abort -> NEEDS_NEXT_OPT -> enable_rx.
const std = @import("std");
const Protection = @import("ieee802154/security.zig").Protection;

pub const Error = error{ InvalidDuration, InvalidFrame, Timeout, Crc, RxAborted, AckTransmitFailed };
pub const Frame = struct {
    /// FCS is checked by hardware and omitted. RSSI/LQI occupy its DMA slots.
    data: [125]u8,
    len: u7,
    rssi: i8,
    lqi: u8,
    /// Observed ACK_TX_DONE for this reception, not merely RX_DONE.
    ack_transmitted: bool = false,
    /// Whether `bytes()` is verified plaintext. Test it before applying
    /// `header.parse(...).payload_offset`: `.unsecured` (no auxiliary
    /// header), `.authenticated` (MIC verified and removed, payload
    /// decrypted) and `.decrypted_unauthenticated` (level 4: decrypted, no
    /// MIC, so not proof of sender or integrity) frames hold a payload at
    /// that offset; `.raw_secured` holds ciphertext+MIC. The receive path
    /// sets one of the decrypted values or leaves the as-received value.
    protection: Protection,

    pub fn bytes(self: *const Frame) []const u8 {
        return self.data[0..self.len];
    }
};

pub const Events = struct {
    abort: ?u5 = null,
    done: bool = false,
    ack_done: bool = false,
    ack_failed: bool = false,
};

/// The hardware adapter supplies time, event snapshots, RX_START, volatile
/// DMA reads and pending-bit writes. Tests supply a stopped-on-abort MAC.
pub fn receive(io: anytype, timeout_us: u32) Error!Frame {
    if (timeout_us == 0) return error.InvalidDuration;
    const deadline = io.now() + timeout_us;
    io.start();
    var received = false;
    var ack_transmitted = false;
    var crc_seen = false;
    while (io.now() < deadline) {
        const events = io.poll();
        if (events.ack_failed) return error.AckTransmitFailed;
        if (events.abort) |reason| {
            switch (reason) {
                // SFD timeout, CRC, invalid length, filter failure, no RSS,
                // coexistence break, unexpected ACK, RX restart. IDF marks
                // all of these NEEDS_NEXT_OPT(true) while in STATE_RX.
                2...9 => {
                    crc_seen = crc_seen or reason == 3;
                    received = false;
                    ack_transmitted = false;
                    io.start();
                    // Discard completion bits/data belonging to the aborted
                    // frame. Restart never extends the caller's deadline.
                    continue;
                },
                else => return if (received) error.AckTransmitFailed else error.RxAborted,
            }
        }
        if (events.done) received = true;
        ack_transmitted = ack_transmitted or events.ack_done;
        if (received) {
            const len = io.load(0) & 0x7f;
            if (len < 5) return error.InvalidFrame;
            const needs_ack = io.auto_ack() and io.load(1) & 0x20 != 0 and (io.load(2) & 0x30 <= 0x10 or (io.load(2) & 0x30 == 0x20 and io.enhanced_ack()));
            if (needs_ack and events.done and io.load(2) & 0x30 <= 0x10) io.set_pending();
            if (!needs_ack or ack_transmitted) {
                var result: Frame = .{
                    .data = undefined,
                    .ack_transmitted = needs_ack and ack_transmitted,
                    .protection = .of_wire(io.load(1)),
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
    enhanced_enabled: bool = false,
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

    fn enhanced_ack(self: *Mock) bool {
        return self.enhanced_enabled;
    }

    fn set_pending(self: *Mock) void {
        self.pending_writes += 1;
    }

    fn load(self: *Mock, index: usize) u8 {
        return self.frame[index];
    }

    fn spin(_: *Mock) void {}
};

test "RX frames report the security bit they arrived with" {
    const events = [_]Events{.{ .done = true }};
    var io: Mock = .{ .events = &events, .frame = .{ 5, 9, 0, 42, 0xd6, 99 } };
    try std.testing.expectEqual(Protection.raw_secured, (try receive(&io, 10)).protection);
}

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
        try std.testing.expectEqual(Protection.unsecured, frame.protection);
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

test "enhanced ACK completion and generator failure are handed to polling" {
    const events = [_]Events{ .{ .done = true }, .{ .ack_done = true } };
    var io: Mock = .{ .events = &events, .ack_enabled = true, .enhanced_enabled = true };
    io.frame[1] |= 0x20;
    io.frame[2] = 0x20;
    _ = try receive(&io, 4);
    try std.testing.expectEqual(@as(usize, 2), io.index);
    try std.testing.expectEqual(@as(usize, 0), io.pending_writes);
    const failed = [_]Events{.{ .done = true, .ack_failed = true }};
    io = .{ .events = &failed };
    try std.testing.expectError(error.AckTransmitFailed, receive(&io, 4));
}

test "unsecured v2 reception alone cannot count as transmitted ACK" {
    const events = [_]Events{.{ .done = true }};
    var io: Mock = .{ .events = &events, .ack_enabled = true, .enhanced_enabled = true };
    io.frame[1] = 0x21; // ACK request, security disabled.
    io.frame[2] = 0x20;
    try std.testing.expectError(error.Timeout, receive(&io, 4));
    const completed = [_]Events{ .{ .done = true }, .{ .ack_done = true } };
    io = .{ .events = &completed, .ack_enabled = true, .enhanced_enabled = true };
    io.frame[1] = 0x21;
    io.frame[2] = 0x20;
    try std.testing.expect((try receive(&io, 4)).ack_transmitted);
    io = .{ .events = &events, .ack_enabled = true, .enhanced_enabled = false };
    io.frame[1] = 0x21;
    io.frame[2] = 0x20;
    try std.testing.expect(!(try receive(&io, 4)).ack_transmitted);
}
