const std = @import("std");

pub const Deadlines = struct {
    pending: ?u64 = null,
    dispatched: ?u64 = null,

    pub fn include(self: *Deadlines, deadline_us: u64, dispatched: bool) void {
        const earliest = if (dispatched) &self.dispatched else &self.pending;
        earliest.* = @min(earliest.* orelse deadline_us, deadline_us);
    }

    /// Returns true when a timer still needs dispatch in this pass.
    pub fn wait(self: Deadlines, signal: anytype, now_us: u64, us_per_tick: u32) bool {
        if (self.pending) |pending| {
            if (pending <= now_us) return true;
        }
        if (self.dispatched) |dispatched| {
            if (dispatched <= now_us) {
                // A pending reload would make a semaphore take return immediately.
                signal.sleep_one_tick();
                return false;
            }
        }
        const next = if (self.dispatched) |dispatched|
            @min(dispatched, self.pending orelse dispatched)
        else
            self.pending;
        if (next) |deadline| {
            const remaining = deadline - now_us;
            const ticks: u32 = @intCast(std.math.clamp(remaining / us_per_tick, 1, std.math.maxInt(u32)));
            signal.take_with_timeout(.{ .after = .from_ticks(ticks) }) catch {};
        } else {
            signal.take_with_timeout(.never) catch {};
        }
        return false;
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

        pub fn sleep_one_tick(self: *@This()) void {
            self.worker_ready_us = (self.now_us / self.us_per_tick + 1) * self.us_per_tick;
        }

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
                const due = deadline <= self.now_us;
                if (due) {
                    self.callback_runs += 1;
                    deadline = self.now_us + 500;
                }
                var next: Deadlines = .{};
                next.include(deadline, due);
                _ = next.wait(self, self.now_us, self.us_per_tick);
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
