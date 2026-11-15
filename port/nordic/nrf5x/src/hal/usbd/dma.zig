//! EasyDMA lifetime, separated from register encoding so a missing ENDEP can be
//! injected on the host. nRF52840 PS v1.1, USBD, "EasyDMA" permits one transfer;
//! nRF52840 Revision 3 Errata, anomaly 199, Workaround ends only on completion.
const std = @import("std");
const Self = @This();

faulted: bool = false,

pub fn run(self: *Self, io: anytype) bool {
    if (self.faulted) return false;
    io.begin();
    io.start();
    if (!io.wait()) {
        self.faulted = true;
        return false;
    }
    io.end();
    return true;
}

const Fake = struct {
    complete: bool,
    workaround: bool = false,
    starts: usize = 0,
    ends: usize = 0,

    pub fn begin(self: *Fake) void {
        std.debug.assert(!self.workaround);
        self.workaround = true;
    }
    pub fn start(self: *Fake) void {
        std.debug.assert(self.workaround);
        self.starts += 1;
    }
    pub fn wait(self: *Fake) bool {
        return self.complete;
    }
    pub fn end(self: *Fake) void {
        self.workaround = false;
        self.ends += 1;
    }
};

test "EasyDMA timeout retains workaround and quarantines subsequent transfers" {
    var state: Self = .{};
    var io: Fake = .{ .complete = false };
    try std.testing.expect(!state.run(&io));
    try std.testing.expect(state.faulted);
    try std.testing.expect(io.workaround);
    try std.testing.expectEqual(0, io.ends);
    // Even a late completion cannot make another transfer safe without recovery.
    io.complete = true;
    try std.testing.expect(!state.run(&io));
    try std.testing.expectEqual(1, io.starts);
}

test "completed EasyDMA releases the workaround and allows the next transfer" {
    var state: Self = .{};
    var io: Fake = .{ .complete = true };
    try std.testing.expect(state.run(&io));
    try std.testing.expect(!state.faulted);
    try std.testing.expect(!io.workaround);
    try std.testing.expect(state.run(&io));
    try std.testing.expectEqual(2, io.starts);
    try std.testing.expectEqual(2, io.ends);
}
