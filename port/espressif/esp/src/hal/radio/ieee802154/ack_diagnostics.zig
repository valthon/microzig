//! Optional, caller-owned enhanced-ACK record. No logging or hardware access.
const std = @import("std");

pub const Ack = struct {
    level: u3,
    received_counter: u32,
    ack_counter: ?u32 = null,
    ack_len: ?u7 = null,
    generation_error: ?[]const u8 = null,
    finish_reason: ?enum { event, stopped } = null,
    finish_events: u13 = 0,

    /// Generate-done notification is not proof of transmission.
    pub fn transmitted(self: Ack) bool {
        return self.generation_error == null and self.finish_reason == .event and
            self.finish_events & (1 << 2) != 0 and self.finish_events & (1 << 4) == 0;
    }

    pub fn finish(self: *Ack, reason: @FieldType(Ack, "finish_reason"), events: u13) void {
        // Preserve the first terminal event, before STOP changes the status.
        if (self.finish_reason != null) return;
        self.finish_reason = reason;
        self.finish_events = events;
    }
};

test "terminal event survives STOP" {
    var ack: Ack = .{ .level = 7, .received_counter = 9 };
    ack.finish(.event, 1 << 4);
    ack.finish(.stopped, 0);
    try std.testing.expectEqual(@as(u13, 1 << 4), ack.finish_events);
    try std.testing.expectEqual(.event, ack.finish_reason.?);
}

test "failed ACK generation is not a transmission" {
    var ack: Ack = .{ .level = 1, .received_counter = 2, .generation_error = "UnknownKey" };
    ack.finish(.stopped, 0);
    try std.testing.expect(!ack.transmitted());
}

test "ACK success requires TX-ACK event, not RX or generation notification" {
    var ack: Ack = .{ .level = 0, .received_counter = 0 };
    try std.testing.expect(!ack.transmitted());
    for ([_]u13{ 0, 1 << 1, 1 << 4, (1 << 2) | (1 << 4) }) |events| {
        var failed = ack;
        failed.finish(.event, events);
        try std.testing.expect(!failed.transmitted());
    }
    var stopped = ack;
    stopped.finish(.stopped, 1 << 2);
    try std.testing.expect(!stopped.transmitted());
    ack.finish(.event, 1 << 2);
    try std.testing.expect(ack.transmitted());
    ack.generation_error = "InvalidFrame";
    try std.testing.expect(!ack.transmitted());
}
