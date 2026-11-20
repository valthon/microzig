//! Pure logger state. Firmware callers serialize every access with a critical section.
const std = @import("std");

pub const State = struct {
    busy: bool = false,
    /// Upper bound on lost/truncated lines since the last confirmed report.
    dropped_lines: usize = 0,
    host_stalled: bool = false,

    pub fn claim(self: *State) ?usize {
        if (self.busy) {
            self.count_dropped();
            return null;
        }
        self.busy = true;
        return self.dropped_lines;
    }

    pub fn release(self: *State) void {
        self.busy = false;
    }

    pub fn count_dropped(self: *State) void {
        self.dropped_lines +|= 1;
    }

    /// Fatal context only: interrupts stay masked and the old owner never resumes.
    pub fn takeover(self: *State, buffered_end: *usize) void {
        if (self.busy) self.count_dropped();
        self.busy = false;
        self.host_stalled = false;
        buffered_end.* = 0;
    }

    pub fn confirm_report(self: *State, reported: usize) void {
        self.dropped_lines -|= reported;
    }
};

/// Recheck readiness after sampling the deadline: the caller may have been
/// preempted while the host consumed the packet. Only a still-full FIFO times out.
pub fn wait_for_tx(io: anytype) error{Timeout}!void {
    while (io.full()) {
        if (io.expired() and io.full()) {
            io.release_stuck();
            return error.Timeout;
        }
    }
}

test "fatal takeover discards buffered owner and permits panic output" {
    var state: State = .{};
    try std.testing.expectEqual(@as(?usize, 0), state.claim());
    state.host_stalled = true;
    var end: usize = 42;
    state.takeover(&end);
    try std.testing.expectEqual(@as(usize, 0), end);
    try std.testing.expect(!state.host_stalled);
    try std.testing.expectEqual(@as(?usize, 1), state.claim());
}

test "claim rejects a preempting caller without releasing the owner" {
    var state: State = .{};
    _ = state.claim();
    try std.testing.expectEqual(@as(?usize, null), state.claim());
    try std.testing.expect(state.busy);
    state.release();
    try std.testing.expectEqual(@as(?usize, 1), state.claim());
}

test "unconfirmed delivery remains an upper bound; confirmed reports preserve new drops" {
    var state: State = .{};
    state.count_dropped(); // A committed packet may still be delivered after timeout.
    const reported = state.claim().?;
    state.count_dropped(); // Another caller loses a line during the report.
    // A timed-out report does not confirm anything, even if delivered later.
    try std.testing.expectEqual(@as(usize, 2), state.dropped_lines);
    state.confirm_report(reported);
    try std.testing.expectEqual(@as(usize, 1), state.dropped_lines);
    state.dropped_lines = std.math.maxInt(usize);
    state.count_dropped();
    try std.testing.expectEqual(std.math.maxInt(usize), state.dropped_lines);
}

test "deadline recheck accepts a packet drained during preemption" {
    const Io = struct {
        reads: usize = 0,
        drained: bool,
        released: bool = false,
        fn full(self: *@This()) bool {
            self.reads += 1;
            return self.reads == 1 or !self.drained;
        }
        fn expired(_: *@This()) bool {
            return true;
        }
        fn release_stuck(self: *@This()) void {
            self.released = true;
        }
    };
    var drained: Io = .{ .drained = true };
    try wait_for_tx(&drained);
    try std.testing.expect(!drained.released);
    var stalled: Io = .{ .drained = false };
    try std.testing.expectError(error.Timeout, wait_for_tx(&stalled));
    try std.testing.expect(stalled.released);
}
