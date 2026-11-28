const std = @import("std");
const Radio = @import("IEEE802154_Radio.zig");

const Fake = struct {
    events: []const Radio.Event = &.{},
    background_event: ?Radio.Event = null,
    after_submit: []const Radio.Event = &.{},
    submitted_events: []const Radio.Event = &.{},
    time: u64 = 0,
    enabled: bool = false,
    disable_fault: bool = false,
    fault: ?Radio.Fault = null,
    fail_at: enum { never, state, clock, submit, after_query, poll_prologue } = .never,
    fault_queries: usize = 0,
    fault_query_trigger: usize = 3,
    busy_submissions: u8 = 0,
    events_on_busy: []const Radio.Event = &.{},
    channel: u8 = 0,
    short_address: u16 = 0,
    rx_bytes: [Radio.max_frame_len]u8 = undefined,
    tx_bytes: [Radio.max_frame_len]u8 = undefined,
    tx_len: usize = 0,
    scan_duration: u32 = 0,
    other_count: usize = 0,
    starts: [2]Radio.TxStarted = undefined,
    start_count: usize = 0,
    wakeup: ?Radio.Notify = null,
    software_ack_reply: ?SoftwareAckReply = null,

    const SoftwareAckReply = struct {
        ready_at: ?u64 = null,
        channel: u8 = 0,
        queued: [2]Radio.Event = undefined,
        count: usize = 0,
    };

    fn radio(self: *Fake) Radio {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn get(ptr: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ptr));
    }

    fn capabilities(_: *anyopaque) Radio.Capabilities {
        return .{ .energy_scan = true };
    }

    fn now_us(ptr: *anyopaque) u64 {
        const self = get(ptr);
        defer self.time += 1;
        if (self.fail_at == .clock) self.inject_fault();
        return self.time;
    }

    fn state(ptr: *anyopaque) Radio.State {
        const self = get(ptr);
        if (self.fail_at == .state) self.inject_fault();
        return if (self.enabled) .receive else .disabled;
    }

    fn sensitivity(_: *anyopaque) i8 {
        return -99;
    }

    fn enable(ptr: *anyopaque) Radio.Error!void {
        get(ptr).enabled = true;
    }

    fn disable(ptr: *anyopaque) Radio.Error!void {
        const self = get(ptr);
        self.enabled = false;
        if (self.disable_fault) {
            self.fault = .{ .reason = .radio_timeout };
            return error.HardwareFault;
        }
    }

    fn sleep(_: *anyopaque) Radio.Error!void {}

    fn receive(ptr: *anyopaque, channel: u8) Radio.Error!void {
        get(ptr).channel = channel;
    }

    fn transmit(ptr: *anyopaque, request: *const Radio.TxRequest) Radio.Error!void {
        const self = get(ptr);
        if (!self.enabled) return error.InvalidState;
        try self.submit(.tx_done);
        self.tx_len = request.bytes.len;
        @memcpy(self.tx_bytes[0..self.tx_len], request.bytes);
        if (self.software_ack_reply) |*reply| {
            // The fake begins its turnaround at TX completion independently
            // of when the portable caller dequeues the sent result.
            if (request.bytes[0] & 0x20 != 0) {
                reply.ready_at = self.time + 40;
                reply.channel = request.channel;
            }
            reply.queued[0] = .{ .tx_done = .{ .status = .sent, .timestamp_us = self.time } };
            reply.count = 1;
            self.submitted_events = reply.queued[0..reply.count];
        }
    }

    fn inject_software_ack(self: *Fake, channel: u8, at: u64) void {
        const reply = if (self.software_ack_reply) |*value| value else unreachable;
        const ready_at = reply.ready_at orelse return;
        if (channel != reply.channel or at < ready_at) return;
        reply.queued[reply.count] = .{ .rx = .{
            .bytes = &.{ 0x02, 0, 1 },
            .fcs = .{ 0, 0 },
            .channel = channel,
            .timestamp_us = at,
            .rssi = -70,
            .lqi = 100,
        } };
        reply.count += 1;
        self.submitted_events = reply.queued[0..reply.count];
    }

    fn scan(ptr: *anyopaque, channel: u8, duration: u32) Radio.Error!void {
        const self = get(ptr);
        try self.submit(.energy_scan_done);
        self.channel = channel;
        self.scan_duration = duration;
    }

    fn cca(ptr: *anyopaque) Radio.Error!void {
        try get(ptr).submit(.cca_done);
    }

    fn submit(self: *Fake, completion: std.meta.Tag(Radio.Event)) Radio.Error!void {
        if (self.fail_at == .submit) self.inject_fault();
        if (!self.enabled) return error.InvalidState;
        for (self.events) |event| {
            if (event == completion or (completion == .energy_scan_done and event == .energy_scan_failed))
                return error.Busy;
        }
        if (self.busy_submissions != 0) {
            self.busy_submissions -= 1;
            self.events = self.events_on_busy;
            self.events_on_busy = &.{};
            return error.Busy;
        }
        self.submitted_events = self.after_submit;
    }

    fn rssi(_: *anyopaque) Radio.Error!i8 {
        return -60;
    }

    fn inject_fault(self: *Fake) void {
        self.fault = .{ .reason = .clock_stalled, .count = 2 };
        self.enabled = false;
        self.fail_at = .never;
    }

    fn fault_pending(ptr: *anyopaque) Radio.FaultPending {
        const self = get(ptr);
        self.fault_queries += 1;
        const fault = self.fault;
        // The snapshot was fault-free, but the IRQ ran as its mask lifted.
        if (self.fail_at == .after_query and self.fault_queries == self.fault_query_trigger) self.inject_fault();
        const pending = fault orelse return .{};
        return .{ .pending = true, .reason = pending.reason, .count = pending.count };
    }

    fn poll(ptr: *anyopaque, mode: Radio.PollMode) ?Radio.Event {
        const self = get(ptr);
        if (mode == .preserve_fault) {
            if (self.fail_at == .poll_prologue) self.inject_fault();
            if (self.fault != null or !self.enabled) return null;
        }
        if (self.fault) |fault| {
            self.fault = null;
            return .{ .fault = fault };
        }
        var event = take_event(&self.events) orelse take_event(&self.submitted_events) orelse self.background_event orelse return null;
        if (event == .rx) {
            const bytes = self.rx_bytes[0..event.rx.bytes.len];
            @memcpy(bytes, event.rx.bytes);
            event.rx.bytes = bytes;
        }
        return event;
    }

    fn take_event(events: *[]const Radio.Event) ?Radio.Event {
        if (events.len == 0) return null;
        defer events.* = events.*[1..];
        return events.*[0];
    }

    fn notify(ptr: *anyopaque, wakeup: ?Radio.Notify) void {
        get(ptr).wakeup = wakeup;
    }

    fn signal(self: *Fake, events: []const Radio.Event) void {
        self.events = events;
        if (self.wakeup) |wakeup| wakeup.call(wakeup.context);
    }

    fn count_wake(context: ?*anyopaque) void {
        const count: *usize = @ptrCast(@alignCast(context.?));
        count.* += 1;
    }
    fn set_short(ptr: *anyopaque, address: u16) void {
        get(ptr).short_address = address;
    }

    fn get_promiscuous(_: *anyopaque) bool {
        return false;
    }

    fn set_pan(_: *anyopaque, _: u16) void {}
    fn set_ext(_: *anyopaque, _: [8]u8) void {}
    fn set_flag(_: *anyopaque, _: bool) void {}
    fn set_dbm(_: *anyopaque, _: i8) Radio.Error!void {}
    fn power(_: *anyopaque) i8 {
        return 3;
    }

    fn threshold(_: *anyopaque) Radio.Error!i8 {
        return -75;
    }

    fn other(context: ?*anyopaque, event: Radio.Event) void {
        const self = get(context.?);
        self.other_count += 1;
        if (event == .tx_started) {
            self.starts[self.start_count] = event.tx_started;
            self.start_count += 1;
        }
    }

    const vtable: Radio.VTable = .{
        .capabilities = capabilities,
        .now_us = now_us,
        .state = state,
        .receive_sensitivity = sensitivity,
        .enable = enable,
        .disable = disable,
        .sleep = sleep,
        .receive = receive,
        .transmit = transmit,
        .energy_scan = scan,
        .cca = cca,
        .rssi = rssi,
        .poll = poll,
        .fault_pending = fault_pending,
        .set_notify = notify,
        .set_pan_id = set_pan,
        .set_short_address = set_short,
        .set_extended_address = set_ext,
        .set_pan_coordinator = set_flag,
        .set_promiscuous = set_flag,
        .get_promiscuous = get_promiscuous,
        .set_tx_power = set_dbm,
        .get_tx_power = power,
        .set_cca_threshold = set_dbm,
        .get_cca_threshold = threshold,
    };
};

test "radio dispatch forwards context, arguments and results" {
    var fake: Fake = .{};
    const radio = fake.radio();
    try std.testing.expectEqual(Radio.State.disabled, radio.state());
    try radio.enable();
    try std.testing.expect(radio.capabilities().energy_scan);
    try std.testing.expectEqual(Radio.State.receive, radio.state());
    try std.testing.expectEqual(@as(i8, -99), radio.receive_sensitivity());
    try std.testing.expectEqual(@as(i8, -60), try radio.rssi());
    try std.testing.expect(!radio.get_promiscuous());
    try std.testing.expectEqual(@as(i8, -75), try radio.get_cca_threshold());
    try radio.receive(25);
    radio.set_short_address(0x1234);
    try std.testing.expectEqual(@as(u8, 25), fake.channel);
    try std.testing.expectEqual(@as(u16, 0x1234), fake.short_address);
    try radio.disable();
    try std.testing.expectEqual(Radio.State.disabled, radio.state());
    try radio.enable();
    fake.events = &.{.{ .cca_done = error.Aborted }};
    fake.disable_fault = true;
    try std.testing.expectError(error.HardwareFault, radio.disable());
    try std.testing.expectEqual(Radio.State.disabled, radio.state());
    try std.testing.expectEqual(Radio.FaultReason.radio_timeout, radio.poll().?.fault.reason);
    try std.testing.expectError(error.Aborted, radio.poll().?.cca_done);
    try std.testing.expectError(error.InvalidState, radio.transmit(&.{ .bytes = &.{}, .channel = 25 }));
}

test "missing optional entries return Unsupported, including void hooks" {
    var fake: Fake = .{};
    const radio = fake.radio();
    try std.testing.expectError(error.Unsupported, radio.receive_at(25, 0, 40));
    try std.testing.expectError(error.Unsupported, radio.set_deliver_bad_fcs(true));
    try std.testing.expectError(error.Unsupported, radio.set_rx_on_when_idle(false));
    try std.testing.expectError(error.Unsupported, radio.set_src_match_enabled(true));
    try std.testing.expectError(error.Unsupported, radio.add_src_match(.{ .short = 1 }));
    try std.testing.expectError(error.Unsupported, radio.remove_src_match(.{ .short = 1 }));
    try std.testing.expectError(error.Unsupported, radio.clear_src_match(.short));
    var vtable = Fake.vtable;
    vtable.energy_scan = null;
    vtable.cca = null;
    const no_scan: Radio = .{ .ptr = &fake, .vtable = &vtable };
    try std.testing.expectError(error.Unsupported, no_scan.energy_scan(25, 128));
    try std.testing.expectError(error.Unsupported, no_scan.cca());
}

test "blocking wrappers consume completions and forward or drop interleaved events" {
    const frame: Radio.RxFrame = .{
        .bytes = &.{ 1, 2, 3 },
        .fcs = .{ 4, 5 },
        .channel = 25,
        .rssi = -50,
        .lqi = 120,
        .timestamp_us = 7,
    };
    var fake: Fake = .{ .after_submit = &.{
        .{ .tx_started = .{ .attempt = 1, .timestamp_us = 4 } },
        .{ .rx = frame },
        .{ .tx_started = .{ .attempt = 2, .timestamp_us = 8 } },
        .{ .tx_done = .{ .status = .acked, .ack = frame, .timestamp_us = 8 } },
        .{ .rx_error = .overrun },
        .{ .rx = frame },
    } };
    const radio = fake.radio();
    const other: Radio.OtherEvent = .{ .context = &fake, .call = Fake.other };
    try radio.enable();
    const done = try radio.transmit_blocking(&.{ .bytes = frame.bytes, .channel = 25 }, 10, other);
    try std.testing.expectEqual(Radio.TxStatus.acked, done.status);
    try std.testing.expectEqualSlices(Radio.TxStarted, &.{
        .{ .attempt = 1, .timestamp_us = 4 },
        .{ .attempt = 2, .timestamp_us = 8 },
    }, fake.starts[0..fake.start_count]);
    try std.testing.expectEqual(fake.starts[1].timestamp_us, done.timestamp_us);
    try std.testing.expectEqualSlices(u8, frame.bytes, done.ack.?.bytes);
    try std.testing.expectEqual(frame.bytes.len, fake.tx_len);
    try std.testing.expectEqual(frame.timestamp_us, (try radio.receive_blocking(10, null)).timestamp_us);
    fake.after_submit = &.{ .{ .rx = frame }, .{ .energy_scan_done = -70 } };
    try std.testing.expectEqual(@as(i8, -70), try radio.energy_scan_blocking(26, 128, 10, other));
    try std.testing.expectEqual(@as(u8, 26), fake.channel);
    try std.testing.expectEqual(@as(u32, 128), fake.scan_duration);
    try std.testing.expectEqual(@as(usize, 4), fake.other_count);
    fake.after_submit = &.{.{ .energy_scan_failed = error.Aborted }};
    try std.testing.expectError(error.Aborted, radio.energy_scan_blocking(26, 128, 10, null));
}

test "blocking wrappers time out even when unrelated events keep arriving" {
    const event: Radio.Event = .{ .tx_started = .{ .attempt = 1, .timestamp_us = 8 } };
    var fake: Fake = .{ .events = &.{ event, event, event } };
    const radio = fake.radio();
    try radio.enable();
    try std.testing.expectError(error.Timeout, radio.receive_blocking(2, null));
    try std.testing.expectEqual(@as(usize, 2), fake.events.len);
    try std.testing.expectError(error.Timeout, radio.transmit_blocking(&.{ .bytes = &.{}, .channel = 25 }, 4, null));
    try std.testing.expectError(error.Timeout, radio.energy_scan_blocking(25, 128, 4, null));
}

test "blocking wrappers time out when an accepted operation never completes" {
    var fake: Fake = .{ .enabled = true };
    const radio = fake.radio();

    try radio.receive(25);
    try std.testing.expectError(error.Timeout, radio.receive_blocking(4, null));
    try std.testing.expectError(error.Timeout, radio.transmit_blocking(&.{ .bytes = &.{0x42}, .channel = 25 }, 4, null));
    try std.testing.expectEqualSlices(u8, &.{0x42}, fake.tx_bytes[0..fake.tx_len]);
    try std.testing.expectError(error.Timeout, radio.energy_scan_blocking(25, 128, 4, null));
    try std.testing.expectEqual(@as(u32, 128), fake.scan_duration);
    try std.testing.expectError(error.Timeout, radio.cca_blocking(4, null));

    fake.busy_submissions = 255;
    try std.testing.expectError(error.Timeout, radio.transmit_blocking(&.{ .bytes = &.{0x43}, .channel = 25 }, 4, null));
    try std.testing.expectEqualSlices(u8, &.{0x42}, fake.tx_bytes[0..fake.tx_len]);
    try std.testing.expect(fake.busy_submissions < 255);
}

test "blocking submissions retry after polling an unread completion" {
    var fake: Fake = .{ .enabled = true };
    const radio = fake.radio();
    const other: Radio.OtherEvent = .{ .context = &fake, .call = Fake.other };

    fake.events = &.{.{ .tx_done = .{ .status = .no_ack, .timestamp_us = 4 } }};
    fake.after_submit = &.{.{ .tx_done = .{ .status = .sent, .timestamp_us = 9 } }};
    const tx = try radio.transmit_blocking(&.{ .bytes = &.{ 1, 2, 3 }, .channel = 25 }, 10, other);
    try std.testing.expectEqual(Radio.TxStatus.sent, tx.status);
    try std.testing.expectEqual(@as(?u64, 9), tx.timestamp_us);

    fake.events = &.{.{ .energy_scan_failed = error.Aborted }};
    fake.after_submit = &.{.{ .energy_scan_done = -70 }};
    try std.testing.expectEqual(@as(i8, -70), try radio.energy_scan_blocking(26, 128, 10, other));

    fake.events = &.{.{ .cca_done = false }};
    fake.after_submit = &.{.{ .cca_done = true }};
    try std.testing.expect(try radio.cca_blocking(10, other));
    try std.testing.expectEqual(@as(usize, 3), fake.other_count);
}

test "continuous unrelated traffic does not starve a submission or Busy retry" {
    var fake: Fake = .{
        .enabled = true,
        .background_event = .{ .rx_error = .overrun },
        .busy_submissions = 1,
        .after_submit = &.{.{ .tx_done = .{ .status = .sent, .timestamp_us = 9 } }},
    };
    const radio = fake.radio();
    const other: Radio.OtherEvent = .{ .context = &fake, .call = Fake.other };
    const done = try radio.transmit_blocking(&.{ .bytes = &.{1}, .channel = 25 }, 10, other);
    try std.testing.expectEqual(Radio.TxStatus.sent, done.status);
    try std.testing.expectEqual(@as(usize, 1), fake.other_count);
}

test "blocking TX can forward an RX frame whose storage is reused by poll" {
    const first: Radio.RxFrame = .{
        .bytes = &.{ 0x41, 0x88, 1 },
        .fcs = .{ 0, 0 },
        .channel = 25,
        .rssi = -50,
        .lqi = 120,
        .timestamp_us = 5,
    };
    var second = first;
    second.bytes = &.{ 0x41, 0x88, 2 };
    second.timestamp_us = 6;
    var fake: Fake = .{
        .enabled = true,
        .events = &.{.{ .rx = first }},
        .busy_submissions = 1,
        .events_on_busy = &.{.{ .rx = second }},
        .after_submit = &.{.{ .tx_done = .{ .status = .sent, .timestamp_us = 10 } }},
    };

    const radio = fake.radio();
    const received = radio.poll().?.rx;
    const done = try radio.transmit_blocking(&.{ .bytes = received.bytes, .channel = 25 }, 10, null);
    try std.testing.expectEqual(Radio.TxStatus.sent, done.status);
    try std.testing.expectEqualSlices(u8, second.bytes, fake.rx_bytes[0..second.bytes.len]);
    try std.testing.expectEqualSlices(u8, first.bytes, fake.tx_bytes[0..fake.tx_len]);
}

test "blocking wrappers reject a disabled radio before touching its queue or clock" {
    var fake: Fake = .{ .events = &.{.{ .rx_error = .overrun }} };
    const radio = fake.radio();
    try std.testing.expectError(error.InvalidState, radio.receive_blocking(10, null));
    try std.testing.expectError(error.InvalidState, radio.transmit_blocking(&.{ .bytes = &.{}, .channel = 25 }, 10, null));
    try std.testing.expectError(error.InvalidState, radio.energy_scan_blocking(25, 128, 10, null));
    try std.testing.expectError(error.InvalidState, radio.cca_blocking(10, null));
    try std.testing.expectEqual(@as(usize, 4), fake.fault_queries);
    try std.testing.expectEqual(@as(u64, 0), fake.time);
    try std.testing.expectEqual(@as(usize, 1), fake.events.len);
    fake.fault = .{ .reason = .radio_timeout };
    try std.testing.expectError(error.Aborted, radio.receive_blocking(10, null));
    try std.testing.expectError(error.Aborted, radio.transmit_blocking(&.{ .bytes = &.{}, .channel = 25 }, 10, null));
    try std.testing.expectError(error.Aborted, radio.energy_scan_blocking(25, 128, 10, null));
    try std.testing.expectError(error.Aborted, radio.cca_blocking(10, null));
    try std.testing.expectEqual(@as(u64, 0), fake.time);
    try std.testing.expectEqual(@as(usize, 1), fake.events.len);
    try std.testing.expectEqual(Radio.FaultReason.radio_timeout, radio.poll().?.fault.reason);
}

test "one coalesced notification wakes a drain for both queued events" {
    var fake: Fake = .{};
    const radio = fake.radio();
    var wakes: usize = 0;
    radio.set_notify(.{ .context = &wakes, .call = Fake.count_wake });
    fake.signal(&.{
        .{ .tx_started = .{ .timestamp_us = 5, .attempt = 1 } },
        .{ .tx_done = .{ .status = .sent, .timestamp_us = 5 } },
    });

    try std.testing.expectEqual(@as(usize, 1), wakes);
    var drained: [2]Radio.Event = undefined;
    var count: usize = 0;
    while (radio.poll()) |event| {
        try std.testing.expect(count < drained.len);
        drained[count] = event;
        count += 1;
    }
    try std.testing.expectEqual(drained.len, count);
    try std.testing.expectEqual(drained[0].tx_started.timestamp_us, drained[1].tx_done.timestamp_us);
    try std.testing.expectEqual(Radio.TxStatus.sent, drained[1].tx_done.status);
    try std.testing.expectEqual(@as(usize, 1), wakes);
}

test "blocking submissions drain raced events and retry Busy within the original timeout" {
    var fake: Fake = .{ .enabled = true };
    const radio = fake.radio();
    const other: Radio.OtherEvent = .{ .context = &fake, .call = Fake.other };

    fake.busy_submissions = 1;
    fake.events_on_busy = &.{.{ .tx_done = .{ .status = .aborted, .timestamp_us = 0 } }};
    fake.after_submit = &.{.{ .tx_done = .{ .status = .sent, .timestamp_us = 6 } }};
    const done = try radio.transmit_blocking(&.{ .bytes = &.{ 1, 2, 3 }, .channel = 25 }, 10, other);
    try std.testing.expectEqual(Radio.TxStatus.sent, done.status);
    try std.testing.expectEqual(@as(usize, 1), fake.other_count);

    fake.busy_submissions = 1;
    fake.after_submit = &.{.{ .energy_scan_done = -60 }};
    try std.testing.expectEqual(@as(i8, -60), try radio.energy_scan_blocking(25, 128, 10, null));

    fake.busy_submissions = 1;
    fake.after_submit = &.{.{ .cca_done = true }};
    try std.testing.expect(try radio.cca_blocking(10, null));
    fake.busy_submissions = 10;
    try std.testing.expectError(error.Timeout, radio.cca_blocking(4, null));
    try std.testing.expect(fake.busy_submissions != 0);
}

test "blocking polls preserve faults and the FIFO at both sides of the poll boundary" {
    const terminal: Radio.Event = .{ .tx_done = .{ .status = .aborted, .timestamp_us = null } };
    for ([_]bool{ false, true }) |with_handler| {
        for ([_]bool{ false, true }) |busy| {
            for ([_]bool{ false, true }) |during_prologue| {
                inline for (.{ .rx, .tx_done, .energy_scan_done, .cca_done }) |kind| {
                    var fake: Fake = .{
                        .enabled = true,
                        .busy_submissions = @intFromBool(busy),
                        .events_on_busy = &.{terminal},
                        .after_submit = &.{terminal},
                        .fail_at = if (during_prologue) .poll_prologue else .after_query,
                        // Receive checks entry and the first wait budget. An
                        // admitted submission also checks its admission budget.
                        // Busy queries the fault immediately before draining.
                        .fault_query_trigger = if (kind == .rx) 3 else if (busy) 4 else 5,
                    };
                    if (kind == .rx) fake.events = &.{terminal};
                    const radio = fake.radio();
                    const handler: ?Radio.OtherEvent = if (with_handler) .{ .context = &fake, .call = Fake.other } else null;
                    switch (kind) {
                        .rx => try std.testing.expectError(error.Aborted, radio.receive_blocking(10, handler)),
                        .tx_done => try std.testing.expectError(error.Aborted, radio.transmit_blocking(&.{ .bytes = &.{1}, .channel = 25 }, 10, handler)),
                        .energy_scan_done => try std.testing.expectError(error.Aborted, radio.energy_scan_blocking(25, 128, 10, handler)),
                        .cca_done => try std.testing.expectError(error.Aborted, radio.cca_blocking(10, handler)),
                        else => unreachable,
                    }
                    try std.testing.expectEqual(Radio.FaultPending{ .pending = true, .reason = .clock_stalled, .count = 2 }, radio.fault_pending());
                    try std.testing.expectEqual(@as(usize, 0), fake.other_count);
                    try std.testing.expectEqual(Radio.Fault{ .reason = .clock_stalled, .count = 2 }, radio.poll().?.fault);
                    try std.testing.expectEqual(Radio.TxStatus.aborted, radio.poll().?.tx_done.status);
                    try std.testing.expectEqual(Radio.FaultPending{}, radio.fault_pending());
                    try std.testing.expect(radio.poll() == null);
                }
            }
        }
    }
}

test "blocking wait preserves unrelated work on state, clock and submission faults" {
    const terminal: Radio.Event = .{ .tx_done = .{ .status = .aborted, .timestamp_us = null } };
    for ([_]bool{ false, true }) |with_handler| {
        inline for (.{ .state, .clock, .submit, .after_query }) |when| {
            inline for (.{ .rx, .tx_done, .energy_scan_done, .cca_done }) |kind| {
                if (when == .submit and kind == .rx) continue;
                var fake: Fake = .{ .enabled = true, .events = &.{terminal}, .fail_at = when };
                const radio = fake.radio();
                const handler: ?Radio.OtherEvent = if (with_handler) .{ .context = &fake, .call = Fake.other } else null;
                switch (kind) {
                    .rx => try std.testing.expectError(error.Aborted, radio.receive_blocking(10, handler)),
                    .tx_done => try std.testing.expectError(error.Aborted, radio.transmit_blocking(&.{ .bytes = &.{1}, .channel = 25 }, 10, handler)),
                    .energy_scan_done => try std.testing.expectError(error.Aborted, radio.energy_scan_blocking(25, 128, 10, handler)),
                    .cca_done => try std.testing.expectError(error.Aborted, radio.cca_blocking(10, handler)),
                    else => unreachable,
                }
                if (when == .state) try std.testing.expectEqual(@as(u64, 0), fake.time);
                try std.testing.expectEqual(@as(usize, 0), fake.other_count);
                try std.testing.expectEqual(Radio.Fault{ .reason = .clock_stalled, .count = 2 }, radio.poll().?.fault);
                try std.testing.expectEqual(Radio.TxStatus.aborted, radio.poll().?.tx_done.status);
            }
        }
    }
}

test "software ACK fallback receives on the TX channel before a delayed drain" {
    for ([_]bool{ false, true }) |request_ack| {
        var fake: Fake = .{ .enabled = true, .software_ack_reply = .{}, .time = 100 };
        const radio = fake.radio();
        try radio.receive(11);
        try std.testing.expect(!radio.capabilities().ack_timeout);
        try radio.transmit(&.{
            .bytes = &.{ if (request_ack) 0x61 else 0x41, 0x88, 1 },
            .channel = 25,
        });
        const peer_start = fake.time + 192;
        fake.inject_software_ack(25, peer_start);
        fake.time = peer_start + 500;
        const sent = radio.poll().?.tx_done;
        try std.testing.expectEqual(Radio.TxStatus.sent, sent.status);
        try std.testing.expect(sent.ack == null);
        if (request_ack) {
            const ack = radio.poll().?.rx;
            try std.testing.expectEqualSlices(u8, &.{ 0x02, 0, 1 }, ack.bytes);
            try std.testing.expectEqual(@as(u8, 25), ack.channel);
            try std.testing.expectEqual(@as(?u64, peer_start), ack.timestamp_us);
        } else {
            try std.testing.expect(fake.software_ack_reply.?.ready_at == null);
        }
        try std.testing.expectEqual(@as(u8, 11), fake.channel);
        try std.testing.expect(radio.poll() == null);
    }
}
