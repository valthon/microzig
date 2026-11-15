//! Buffer withdrawal order for controllers with an endpoint-abort handshake.
//! The IO adapter owns the bounded wait and the register encodings.
const std = @import("std");

pub fn withdraw(io: anytype) error{Timeout}!void {
    const aborting = io.begin_abort();
    if (aborting and !io.wait_abort()) return error.Timeout;
    io.withdraw();
    io.clear_completion();
    if (aborting) io.end_abort();
}

const Fake = struct {
    done: bool,
    aborting: bool = false,
    withdrawn: bool = false,
    completion: bool = true,

    pub fn begin_abort(self: *Fake) bool {
        self.aborting = true;
        return true;
    }
    pub fn wait_abort(self: *Fake) bool {
        return self.done;
    }
    pub fn withdraw(self: *Fake) void {
        std.debug.assert(self.aborting);
        self.withdrawn = true;
    }
    pub fn clear_completion(self: *Fake) void {
        std.debug.assert(self.withdrawn);
        self.completion = false;
    }
    pub fn end_abort(self: *Fake) void {
        std.debug.assert(self.withdrawn and !self.completion);
        self.aborting = false;
    }
};

test "abort timeout retains buffer ownership and pending completion" {
    var io: Fake = .{ .done = false };
    try std.testing.expectError(error.Timeout, withdraw(&io));
    try std.testing.expect(io.aborting);
    try std.testing.expect(!io.withdrawn);
    try std.testing.expect(io.completion);
}

test "successful abort withdraws the buffer before dropping its completion" {
    var io: Fake = .{ .done = true };
    try withdraw(&io);
    try std.testing.expect(io.withdrawn);
    try std.testing.expect(!io.completion);
    try std.testing.expect(!io.aborting);
}
