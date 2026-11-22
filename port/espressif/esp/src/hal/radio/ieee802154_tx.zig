//! Unslotted CSMA-CA and missing-ACK retries, IEEE 802.15.4-2015
//! §§6.2.5.1, 6.7.4.3. C6's 2.4 GHz PHY uses 16 us symbols.
const std = @import("std");

pub const Result = enum { tx_done, ack_received, no_ack, cca_busy };

pub const Config = struct {
    min_be: u4 = 3,
    max_be: u4 = 5,
    max_csma_backoffs: u8 = 4,
    max_frame_retries: u8 = 3,
    /// macAckWaitDuration, in symbols (54 symbols = 864 us at 2.4 GHz).
    ack_wait_symbols: u16 = 54,

    pub fn validate(self: Config) error{InvalidTxConfig}!void {
        if (self.max_be < 3 or self.max_be > 8 or self.min_be > self.max_be or
            self.max_csma_backoffs > 5 or self.max_frame_retries > 7 or self.ack_wait_symbols == 0)
            return error.InvalidTxConfig;
    }
};

pub const symbol_us = 16;
pub const unit_backoff_symbols = 20;

pub const Events = struct {
    done: bool = false,
    ack_done: bool = false,
    abort: ?u5 = null,
};

/// Poll completion before deciding that a software deadline has expired. Time
/// is sampled before the event read so preemption between these operations
/// cannot hide a latched ACK behind an expired deadline.
pub fn wait_for_completion(io: anytype, ack: bool, ack_wait_symbols: u16) error{ InvalidFrame, CcaFailed, TxAborted, Timeout }!Result {
    var deadline = io.now() + 10_000;
    var sent = false;
    while (true) {
        const current = io.now();
        const events = io.poll();
        if (events.ack_done and ack) {
            if (!sent) io.mark_sent();
            try io.validate_ack();
            return .ack_received;
        }
        if (events.abort) |reason| {
            switch (reason) {
                16 => {
                    if (!sent) io.mark_sent();
                    return .no_ack;
                },
                25 => return .cca_busy,
                24 => return error.CcaFailed,
                // IDF leaves invalid ACKs pending until its watchdog fires.
                2...9 => {},
                else => return error.TxAborted,
            }
        }
        if (events.done and !sent) {
            io.mark_sent();
            if (!ack) return .tx_done;
            sent = true;
            // Hardware handles turnaround/filtering and its own timeout
            // (IDF dev.c:613-617). Bound invalid-ACK paths with the configured
            // macAckWaitDuration rather than IDF's 200 ms watchdog.
            deadline = io.now() + @as(u64, ack_wait_symbols) * symbol_us;
        }
        if (current >= deadline) return if (sent and ack) .no_ack else error.Timeout;
        io.spin();
    }
}

/// Io supplies random(), wait(us), and attempt(use_cca). Every attempt must
/// leave the MAC idle before returning, including failures. Only NO_ACK spends
/// the frame retry budget; exhausted channel access is a terminal CCA_BUSY.
pub fn transmit(io: anytype, config: Config, use_cca: bool) !Result {
    try config.validate();
    var retries: u8 = 0;
    while (true) {
        // A retransmission starts a new CSMA-CA procedure (NB=0, BE=minBE).
        var backoffs: u8 = 0;
        var be = config.min_be;
        while (true) {
            if (use_cca) {
                const mask = (@as(u32, 1) << @as(u5, be)) - 1;
                io.wait((io.random() & mask) * unit_backoff_symbols * symbol_us);
            }
            const result = try io.attempt(use_cca);
            switch (result) {
                .cca_busy => {
                    if (!use_cca or backoffs == config.max_csma_backoffs) return .cca_busy;
                    backoffs += 1;
                    be = @min(be + 1, config.max_be);
                },
                .no_ack => {
                    if (retries == config.max_frame_retries) return .no_ack;
                    retries += 1;
                    break;
                },
                .tx_done, .ack_received => return result,
            }
        }
    }
}

const TestIo = struct {
    results: []const Result,
    delays: []const u32,
    calls: usize = 0,
    waits: usize = 0,
    use_cca: bool = true,
    random_word: u32 = 0xffff_ffff,

    fn random(self: *TestIo) u32 {
        return self.random_word;
    }

    fn wait(self: *TestIo, us: u32) void {
        std.debug.assert(self.waits < self.delays.len);
        std.debug.assert(us == self.delays[self.waits]);
        self.waits += 1;
    }

    fn attempt(self: *TestIo, use_cca: bool) error{Timeout}!Result {
        std.debug.assert(use_cca == self.use_cca);
        if (self.calls == self.results.len) return error.Timeout;
        const result = self.results[self.calls];
        self.calls += 1;
        return result;
    }
};

test "BE progresses 3 4 5 5 5; fifth busy CCA terminates without frame retries" {
    var io: TestIo = .{
        .results = &.{ .cca_busy, .cca_busy, .cca_busy, .cca_busy, .cca_busy, .ack_received },
        .delays = &.{ 2240, 4800, 9920, 9920, 9920 },
    };
    try std.testing.expectEqual(Result.cca_busy, try transmit(&io, .{}, true));
    try std.testing.expectEqual(@as(usize, 5), io.calls);
    try std.testing.expectEqual(@as(usize, 5), io.waits);
}

test "missing ACK allows four transmissions and resets BE and NB each time" {
    var io: TestIo = .{
        .results = &.{ .cca_busy, .no_ack, .cca_busy, .no_ack, .no_ack, .no_ack, .ack_received },
        .delays = &.{ 2240, 4800, 2240, 4800, 2240, 2240 },
    };
    try std.testing.expectEqual(Result.no_ack, try transmit(&io, .{}, true));
    try std.testing.expectEqual(@as(usize, 6), io.calls);
}

test "success on final retry, no ACK request, and disabled CCA" {
    var io: TestIo = .{
        .results = &.{ .no_ack, .no_ack, .no_ack, .ack_received },
        .delays = &.{},
        .use_cca = false,
    };
    try std.testing.expectEqual(Result.ack_received, try transmit(&io, .{}, false));
    try std.testing.expectEqual(@as(usize, 4), io.calls);
    io = .{ .results = &.{ .tx_done, .no_ack }, .delays = &.{2240} };
    try std.testing.expectEqual(Result.tx_done, try transmit(&io, .{}, true));
    try std.testing.expectEqual(@as(usize, 1), io.calls);
}

test "configured backoff budget resets after NO_ACK; random slot endpoints" {
    var io: TestIo = .{
        .results = &.{ .cca_busy, .no_ack, .cca_busy, .ack_received },
        .delays = &.{ 2240, 4800, 2240, 4800 },
    };
    try std.testing.expectEqual(Result.ack_received, try transmit(&io, .{ .max_csma_backoffs = 1 }, true));
    try std.testing.expectEqual(@as(usize, 4), io.calls);
    io = .{ .results = &.{.tx_done}, .delays = &.{81600} };
    try std.testing.expectEqual(Result.tx_done, try transmit(&io, .{ .min_be = 8, .max_be = 8 }, true));
    io = .{ .results = &.{.tx_done}, .delays = &.{0}, .random_word = 0 };
    try std.testing.expectEqual(Result.tx_done, try transmit(&io, .{}, true));
}

test "configured zero budgets, zero exponent and abort propagation" {
    var io: TestIo = .{ .results = &.{.cca_busy}, .delays = &.{0} };
    try std.testing.expectEqual(Result.cca_busy, try transmit(&io, .{ .min_be = 0, .max_csma_backoffs = 0 }, true));
    io = .{ .results = &.{.no_ack}, .delays = &.{2240} };
    try std.testing.expectEqual(Result.no_ack, try transmit(&io, .{ .max_frame_retries = 0 }, true));
    io = .{ .results = &.{}, .delays = &.{2240} };
    try std.testing.expectError(error.Timeout, transmit(&io, .{}, true));
}

test "invalid policy rejected before any IO" {
    for ([_]Config{
        .{ .min_be = 6 },            .{ .max_be = 9 },            .{ .max_be = 2 },
        .{ .max_csma_backoffs = 6 }, .{ .max_frame_retries = 8 }, .{ .ack_wait_symbols = 0 },
    }) |config| {
        var io: TestIo = .{ .results = &.{}, .delays = &.{} };
        try std.testing.expectError(error.InvalidTxConfig, transmit(&io, config, true));
        try std.testing.expectEqual(@as(usize, 0), io.calls);
    }
}

const CompletionIo = struct {
    clock: u64 = 0,
    polls: usize = 0,
    sent_count: usize = 0,
    ack_checks: usize = 0,
    latch_ack: bool = true,

    fn now(self: *CompletionIo) u64 {
        return self.clock;
    }

    fn poll(self: *CompletionIo) Events {
        self.polls += 1;
        return .{ .done = self.polls == 1, .ack_done = self.polls == 2 and self.latch_ack };
    }

    fn mark_sent(self: *CompletionIo) void {
        self.sent_count += 1;
    }

    fn validate_ack(self: *CompletionIo) error{InvalidFrame}!void {
        self.ack_checks += 1;
    }

    fn spin(self: *CompletionIo) void {
        // Task observes TX_DONE at 0 us, then is descheduled. A peer ACK
        // latches during the 864 us ACK window; the task resumes at 1000 us.
        self.clock = 1000;
    }
};

test "ACK latched while descheduled across deadline completes without retry" {
    var io: CompletionIo = .{};
    try std.testing.expectEqual(Result.ack_received, try wait_for_completion(&io, true, 54));
    try std.testing.expectEqual(@as(usize, 2), io.polls);
    try std.testing.expectEqual(@as(usize, 1), io.sent_count);
    try std.testing.expectEqual(@as(usize, 1), io.ack_checks);
    try std.testing.expectEqual(@as(u64, 1000), io.clock);
}

test "expired ACK deadline without latched completion returns NO_ACK" {
    var io: CompletionIo = .{ .latch_ack = false };
    try std.testing.expectEqual(Result.no_ack, try wait_for_completion(&io, true, 54));
    try std.testing.expectEqual(@as(usize, 2), io.polls);
    try std.testing.expectEqual(@as(usize, 1), io.sent_count);
    try std.testing.expectEqual(@as(usize, 0), io.ack_checks);
}
