const std = @import("std");

// A slow callback can leave both kinds overdue. A periodic overrun must
// yield to lower-priority tasks, but must not hide a due one-shot.
pub const Deadlines = struct {
    one_shot: ?u64 = null,
    periodic: ?u64 = null,

    pub fn include(self: *Deadlines, deadline_us: u64, repeats: bool) void {
        const earliest = if (repeats) &self.periodic else &self.one_shot;
        earliest.* = @min(earliest.* orelse deadline_us, deadline_us);
    }

    pub fn wait(self: Deadlines, signal: anytype, now_us: u64, us_per_tick: u32) void {
        if (self.one_shot) |one_shot| {
            if (one_shot <= now_us) return;
        }
        const next = if (self.periodic) |periodic|
            @min(periodic, self.one_shot orelse periodic)
        else
            self.one_shot;
        if (next) |deadline| {
            const remaining = deadline -| now_us;
            const ticks: u32 = @intCast(std.math.clamp(remaining / us_per_tick, 1, std.math.maxInt(u32)));
            signal.take_with_timeout(.{ .after = .from_ticks(ticks) }) catch {};
        } else {
            signal.take_with_timeout(.never) catch {};
        }
    }
};

test "high priority repeating 500 us timer lets a lower priority task run" {
    const Scheduler = struct {
        us_per_tick: u32,
        now_us: u64 = 0,
        worker_ready_us: u64 = 0,
        pending_arm_signal: bool = true,
        worker_runs: usize = 0,
        callback_runs: usize = 0,
        application_runs: usize = 0,

        pub fn take_with_timeout(self: *@This(), timeout: TestTimeout) error{Timeout}!void {
            if (self.pending_arm_signal) {
                self.pending_arm_signal = false;
                return;
            }
            self.worker_ready_us = (self.now_us / self.us_per_tick + @backingInt(timeout.after)) * self.us_per_tick;
            return error.Timeout;
        }

        // Dispatch the timer worker whenever ready. Only blocking it allows
        // the application to run. Advance the simulated clock independently.
        fn run(self: *@This()) void {
            var deadline: u64 = 500;
            while (self.now_us < 10 * self.us_per_tick) : (self.now_us += 100) {
                if (self.worker_ready_us > self.now_us) {
                    self.application_runs += 1;
                    continue;
                }
                self.worker_runs += 1;
                if (deadline <= self.now_us) {
                    self.callback_runs += 1;
                    deadline = self.now_us + 500;
                }
                const next: Deadlines = .{ .periodic = deadline };
                next.wait(self, self.now_us, self.us_per_tick);
            }
        }
    };
    for ([_]u32{ 1000, 10_000 }) |us_per_tick| {
        var scheduler: Scheduler = .{ .us_per_tick = us_per_tick };
        scheduler.run();
        try std.testing.expect(scheduler.callback_runs >= 9);
        try std.testing.expect(scheduler.application_runs > scheduler.worker_runs);
    }
}

const TestTimeout = union(enum) {
    after: enum(u32) {
        _,
        pub fn from_ticks(ticks: u32) @This() {
            return @fromBackingInt(ticks);
        }
    },
    never,
};

test "one-shot that becomes due during another callback dispatches on the next scan" {
    const Clock = struct {
        now_us: u64 = 0,
        waits: u32 = 0,

        pub fn take_with_timeout(self: *@This(), timeout: TestTimeout) error{Timeout}!void {
            self.waits += 1;
            self.now_us += @as(u64, @backingInt(timeout.after)) * 1000;
            return error.Timeout;
        }
    };
    for ([_]u64{ 499, 500 }) |second_deadline| {
        var clock: Clock = .{};
        var first_pending = true;
        while (true) {
            const scan_us = clock.now_us;
            if (first_pending) {
                first_pending = false;
                clock.now_us += 500; // time spent in the first callback
            }
            if (second_deadline <= scan_us) break; // dispatch the second callback
            var next: Deadlines = .{};
            next.include(second_deadline, false);
            next.include(300, true); // an earlier periodic overrun must not mask the one-shot
            next.wait(&clock, clock.now_us, 1000);
        }
        try std.testing.expectEqual(500, clock.now_us);
        try std.testing.expectEqual(0, clock.waits);

        const overrunning: Deadlines = .{ .periodic = 300 };
        overrunning.wait(&clock, clock.now_us, 1000);
        try std.testing.expectEqual(1, clock.waits);
    }
}
