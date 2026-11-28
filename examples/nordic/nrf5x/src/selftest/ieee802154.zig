//! XIAO nRF52840 Sense, IEEE 802.15.4 channel 25, PAN 0x1234, short 0x0003.
//!
//! On the ESP32-H2 bench console (COM40, ieee802154_cli), run these commands.
//! Enable the subsystem with esp154 -e if it is disabled.
//!
//!   shortaddr 0x0001
//!   panid 0x1234
//!   channel -s 25
//!   promisc -d
//!   rx -r 1
//!
//! Repeat these three TX commands in order, about 300 ms between sends.
//! Issue rx -r 1 after each TX completes or fails so the H2 can ACK XIAO TX.
//! The final two bytes in each command reserve FCS.
//!
//!   tx 0x61 0x88 0x01 0x34 0x12 0x03 0x00 0x01 0x00 0x48 0x32 0x00 0x00
//!   tx 0x61 0x88 0x02 0x34 0x12 0x03 0x00 0x01 0x00 0x48 0x32 0x00 0x00
//!   tx 0x61 0x88 0x03 0x34 0x12 0x03 0x00 0x01 0x00 0x48 0x32 0x00 0x00
//!
//! Run the H2 loop independently of XIAO boot until the XIAO CDC report appears.
//! The XIAO starts RX and lets frames queue for 2 s before polling. It waits up
//! to 60 s for a matching frame and then up to 5 s for the remaining DSNs.
//! It tries up to five AR sends to 0x0001 at 200 ms intervals, then sniffs
//! channel 25 for 3 s. The H2 automatically ACKs in filtered RX. With no
//! peer the peer and idle RX cases report FAIL.
const std = @import("std");
const builtin = @import("builtin");
const microzig = @import("microzig");
const harness = @import("harness.zig");
const ieee802154 = microzig.hal.ieee802154;
const Radio = if (builtin.is_test) @import("radio_interface") else microzig.drivers.base.IEEE802154_Radio;
const channel = 25;
const time = microzig.hal.time;

pub const panic = microzig.panic;
pub const init = harness.init;
pub const microzig_options: microzig.Options = .{ .hal = .{ .ieee802154 = true } };
pub const std_options = microzig.std_options(.{});

comptime {
    if (!builtin.is_test) _ = microzig.export_startup();
}

const suite = "ieee802154";
const first_peer_frame_us = 60_000_000;
const remaining_peer_frames_us = 5_000_000;
const peer_poll_us = 1_000_000;
const peer_count = 3;
const peer_tx_attempts = 5;
const peer_tx_interval_us = 200_000;
// Two frames make the monotonic check meaningful.
const sniffer_min_frames = 2;

var hardware: ieee802154.Radio = undefined;

pub fn main() void {
    hardware.init(.{
        .channel = channel,
        .pan_id = 0x1234,
        .short_address = 0x0003,
    }) catch |err| {
        fail("init", err);
        harness.finish(suite);
    };
    const radio = hardware.ieee802154_radio();
    radio.enable() catch |err| {
        drain(radio, "init");
        fail("init", err);
        hardware.deinit() catch |deinit_err| fail("deinit", deinit_err);
        harness.finish(suite);
    };
    harness.check(suite, "init", true, "channel=25 pan=0x1234 short=0x0003", .{});

    radio.set_rx_on_when_idle(false) catch |err| stop_case(radio, "init", err);
    check_ed(radio);
    check_cca(radio);
    check_rssi(radio);
    check_broadcast_tx(radio);
    check_rx_timeout(radio);

    check_peer_rx(radio);
    check_peer_tx_ack(radio);
    check_sniffer(radio);
    radio.set_promiscuous(true); // Prevent a new ACK while the last one finishes.
    sleep_when_ready(radio) catch |err| stop_case(radio, "sleep", err);
    drain(radio, "deinit");
    deinit_when_ready(radio) catch |err| stop_case(radio, "deinit", err);
    harness.finish(suite);
}

fn fail(case: []const u8, err: Radio.Error) void {
    harness.check(suite, case, false, "{s}", .{@errorName(err)});
}

const FaultDrain = struct {
    fault: ?Radio.Fault = null,

    fn check_fault(self: *FaultDrain, event: Radio.Event) void {
        if (event == .fault and self.fault == null) self.fault = event.fault;
    }

    fn finish_failed(self: FaultDrain, case: []const u8, reporter: anytype) void {
        if (self.fault) |fault| reporter.fail_case(case, fault);
    }
};

const HarnessFaultReporter = struct {
    fn fail_case(_: @This(), case: []const u8, fault: Radio.Fault) void {
        harness.check(suite, case, false, "radio fault {s} (count={d})", .{ @tagName(fault.reason), fault.count });
        harness.finish(suite);
    }
};

fn other_event(context: ?*anyopaque, event: Radio.Event) void {
    const faults: *FaultDrain = @ptrCast(@alignCast(context.?));
    faults.check_fault(event);
}

fn handler(faults: *FaultDrain) Radio.OtherEvent {
    return .{ .context = faults, .call = other_event };
}

fn drain_and_report(radio: Radio, case: []const u8, faults: *FaultDrain, reporter: anytype) void {
    while (radio.poll()) |event| faults.check_fault(event);
    faults.finish_failed(case, reporter);
}

fn drain_with_faults(radio: Radio, case: []const u8, faults: *FaultDrain) void {
    drain_and_report(radio, case, faults, HarnessFaultReporter{});
}

fn drain(radio: Radio, case: []const u8) void {
    var faults: FaultDrain = .{};
    drain_with_faults(radio, case, &faults);
}

fn stop_case(radio: Radio, case: []const u8, err: Radio.Error) noreturn {
    drain(radio, case);
    fail(case, err);
    harness.finish(suite);
}

fn fail_untimed(case: []const u8) noreturn {
    harness.check(suite, case, false, "fault-path frame", .{});
    harness.finish(suite);
}

fn sleep_when_ready(radio: Radio) Radio.Error!void {
    const end = time.get_time_since_boot().to_us() + 10_000;
    while (true) {
        radio.sleep() catch |err| {
            if (err != error.Busy or time.get_time_since_boot().to_us() >= end) return err;
            drain(radio, "sleep");
            continue;
        };
        return;
    }
}

fn deinit_when_ready(radio: Radio) Radio.Error!void {
    const end = time.get_time_since_boot().to_us() + 10_000;
    while (true) {
        hardware.deinit() catch |err| {
            if (err != error.Busy or time.get_time_since_boot().to_us() >= end) return err;
            drain(radio, "deinit");
            continue;
        };
        return;
    }
}

fn check_ed(radio: Radio) void {
    var faults: FaultDrain = .{};
    const case = "ed";
    const result = radio.energy_scan_blocking(channel, 128, 10_000, handler(&faults));
    drain_with_faults(radio, case, &faults);
    const energy = result catch |err| return fail(case, err);
    harness.check(suite, case, energy >= -92 and energy <= 0, "EDEND level={d} rssi={d} dBm", .{ ieee802154.ed_level(energy), energy });
}

fn check_cca(radio: Radio) void {
    var faults: FaultDrain = .{};
    const case = "cca";
    const result = radio.cca_blocking(10_000, handler(&faults));
    drain_with_faults(radio, case, &faults);
    const clear = result catch |err| return fail(case, err);
    harness.check(suite, case, true, "{s}", .{if (clear) "idle (CCAIDLE)" else "busy (CCABUSY)"});
}

fn check_rssi(radio: Radio) void {
    const before_arm = radio.rssi();
    drain(radio, "rssi_before_rx");
    const invalid_state = if (before_arm) |_| false else |err| err == error.InvalidState;
    harness.check(suite, "rssi_before_rx", invalid_state, "expect InvalidState before RX is armed", .{});

    const case = "rssi";
    radio.set_rx_on_when_idle(true) catch |err| stop_case(radio, case, err);
    receive_when_ready(radio) catch |err| stop_case(radio, case, err);
    const end = time.get_time_since_boot().to_us() + 10_000;
    const rssi = while (time.get_time_since_boot().to_us() < end) {
        const result = radio.rssi() catch |err| switch (err) {
            error.Busy, error.InvalidState => continue,
            else => stop_case(radio, case, err),
        };
        break result;
    } else stop_case(radio, case, error.Timeout);
    harness.check(suite, case, rssi < 0, "RSSIEND rssi={d} dBm", .{rssi});
    radio.set_rx_on_when_idle(false) catch |err| stop_case(radio, case, err);
    sleep_when_ready(radio) catch |err| stop_case(radio, case, err);
    drain(radio, case);
}

fn check_broadcast_tx(radio: Radio) void {
    var faults: FaultDrain = .{};
    const case = "broadcast_tx";
    const bytes: []const u8 = &.{ 0x41, 0x88, 0x10, 0x34, 0x12, 0xff, 0xff, 0x03, 0x00, 'N', 'R', 'F' };
    const outcome = radio.transmit_blocking(&.{
        .bytes = bytes,
        .channel = channel,
        .csma_ca = false,
        .max_frame_retries = 0,
    }, 20_000, handler(&faults));
    drain_with_faults(radio, case, &faults);
    const result = outcome catch |err| return fail(case, err);
    harness.check(suite, case, result.status == .sent, "{s}", .{@tagName(result.status)});
}

fn check_rx_timeout(radio: Radio) void {
    var faults: FaultDrain = .{};
    const case = "rx_timeout";
    // The H2 script transmits on channel 25. Arm a different channel.
    radio.receive(26) catch |err| stop_case(radio, case, err);
    const result = radio.receive_blocking(200, handler(&faults));
    drain_with_faults(radio, case, &faults);
    if (result) |_| {
        harness.check(suite, case, false, "unexpected frame", .{});
    } else |err| {
        harness.check(suite, case, err == error.Timeout, "{s}", .{@errorName(err)});
    }
}

const PeerObservations = struct {
    seen: u3 = 0,
    min_rssi: i8 = 127,
    max_rssi: i8 = -128,
    pending_clear: bool = true,

    fn record(self: *PeerObservations, frame: Radio.RxFrame) void {
        if (!frame.ack_sent) return;
        self.pending_clear = self.pending_clear and !frame.acked_with_frame_pending;
        const bit = @as(u3, 1) << @as(u2, @intCast(frame.bytes[2] - 1));
        self.seen |= bit;
        self.min_rssi = @min(self.min_rssi, frame.rssi);
        self.max_rssi = @max(self.max_rssi, frame.rssi);
    }
};

fn is_h2_frame(frame: Radio.RxFrame) bool {
    const bytes = frame.bytes;
    return frame.fcs_ok and bytes.len == 11 and
        bytes[2] >= 1 and bytes[2] <= peer_count and
        std.mem.eql(u8, bytes[0..2], &.{ 0x61, 0x88 }) and
        std.mem.eql(u8, bytes[3..], &.{ 0x34, 0x12, 0x03, 0x00, 0x01, 0x00, 'H', '2' });
}

fn receive_when_ready(radio: Radio) Radio.Error!void {
    const end = time.get_time_since_boot().to_us() + 10_000;
    while (true) {
        radio.receive(channel) catch |err| {
            if (err != error.Busy or time.get_time_since_boot().to_us() >= end) return err;
            drain(radio, "receive");
            continue;
        };
        return;
    }
}

fn check_peer_rx(radio: Radio) void {
    const case = "peer_rx_h2";
    sleep_when_ready(radio) catch |err| stop_case(radio, case, err);
    drain(radio, case);

    radio.set_src_match_enabled(true) catch |err| return fail(case, err);
    radio.add_src_match(.{ .short = 0x0001 }) catch |err| return fail(case, err);

    // The host test for ieee802154_src_match covers a Data Request with an
    // empty table. These H2 data frames must keep pending clear even on a hit.
    var observations: PeerObservations = .{};
    var end = time.get_time_since_boot().to_us() + first_peer_frame_us;
    radio.set_rx_on_when_idle(true) catch |err| stop_case(radio, case, err);
    receive_when_ready(radio) catch |err| stop_case(radio, case, err);
    // Exclude frames from the old RX phase and its source-match policy.
    const idle_start = radio.now_us();
    time.sleep_us(2_000_000);
    const queued_during_sleep = hardware.queued_event_count();

    const idle_count = drain_peer(radio, case, idle_start, queued_during_sleep, &observations);
    harness.check(suite, "rx_on_when_idle", idle_count >= 2, "H2 frames in queue after 2 s sleep={d} (need at least 2)", .{idle_count});

    if (observations.seen != 0) end = time.get_time_since_boot().to_us() + remaining_peer_frames_us;
    while (@popCount(observations.seen) != peer_count) {
        const remaining = end -| time.get_time_since_boot().to_us();
        if (remaining == 0) break;
        microzig.board.feed_bootloader_fallback();
        const first = observations.seen == 0;
        var faults: FaultDrain = .{};
        var untimed = false;
        const result = radio.receive_blocking(@intCast(@min(remaining, peer_poll_us)), handler(&faults));
        const wait_error: ?Radio.Error = if (result) |frame| received: {
            if (classify_peer(idle_start, frame)) |qualifies| {
                if (qualifies) observations.record(frame);
            } else |_| untimed = true;
            break :received null;
        } else |err| err;
        _ = drain_peer_with_faults(radio, case, idle_start, 0, &observations, &faults, untimed);
        if (wait_error) |err| {
            if (err != error.Timeout) {
                fail(case, err);
                harness.finish(suite);
            }
        }
        if (first and observations.seen != 0) end = time.get_time_since_boot().to_us() + remaining_peer_frames_us;
    }
    const count = @popCount(observations.seen);
    const plausible = observations.min_rssi >= -90 and observations.max_rssi < 0;
    harness.check(suite, case, count == peer_count and plausible and observations.pending_clear, "FCS-ok and ACK-sent count={d}/{d} RSSISAMPLE range={d}..{d} dBm pending_clear={}", .{
        count, peer_count, observations.min_rssi, observations.max_rssi, observations.pending_clear,
    });
}

fn classify_peer(start: u64, frame: Radio.RxFrame) error{Untimed}!bool {
    const tick = frame.timestamp_us orelse return error.Untimed;
    return tick >= start and is_h2_frame(frame);
}

const PeerDrain = struct {
    start: u64,
    sampled: usize,
    fifo: usize = 0,
    qualifying: usize = 0,

    fn observe(self: *PeerDrain, event: Radio.Event, observations: *PeerObservations) error{ Fault, Untimed }!void {
        switch (event) {
            .fault => return error.Fault,
            .rx_error => |rx_error| if (rx_error == .overrun) return,
            else => {},
        }
        self.fifo += 1;
        if (event != .rx) return;
        const frame = event.rx;
        if (try classify_peer(self.start, frame)) {
            if (self.fifo <= self.sampled) self.qualifying += 1;
            observations.record(frame);
        }
    }
};

fn drain_peer(radio: Radio, case: []const u8, start: u64, sampled: usize, observations: *PeerObservations) usize {
    var faults: FaultDrain = .{};
    return drain_peer_with_faults(radio, case, start, sampled, observations, &faults, false);
}

fn drain_peer_with_faults(
    radio: Radio,
    case: []const u8,
    start: u64,
    sampled: usize,
    observations: *PeerObservations,
    faults: *FaultDrain,
    first_untimed: bool,
) usize {
    var sampling: PeerDrain = .{ .start = start, .sampled = sampled };
    var untimed = first_untimed;
    while (radio.poll()) |event| {
        sampling.observe(event, observations) catch |err| switch (err) {
            error.Fault => faults.check_fault(event),
            error.Untimed => untimed = true,
        };
    }
    faults.finish_failed(case, HarnessFaultReporter{});
    if (untimed) fail_untimed(case);
    return sampling.qualifying;
}

fn check_peer_tx_ack(radio: Radio) void {
    const case = "peer_tx_ack";
    const bytes: []const u8 = &.{ 0x61, 0x88, 0x20, 0x34, 0x12, 0x01, 0x00, 0x03, 0x00, 'N', 'R', 'F' };
    for (1..peer_tx_attempts + 1) |attempt| {
        const next_start = time.get_time_since_boot().to_us() + peer_tx_interval_us;
        var faults: FaultDrain = .{};
        const outcome = radio.transmit_blocking(&.{
            .bytes = bytes,
            .channel = channel,
            .max_frame_retries = 0, // One over-the-air send per test attempt.
        }, 100_000, handler(&faults));
        const result = outcome catch |err| {
            drain_with_faults(radio, case, &faults);
            if (err == error.Busy and attempt < peer_tx_attempts) {
                time.sleep_us(next_start -| time.get_time_since_boot().to_us());
                continue;
            }
            harness.check(suite, case, false, "{s} attempts={d}/{d}", .{ @errorName(err), attempt, peer_tx_attempts });
            return;
        };
        const acked = result.status == .acked and result.ack != null;
        drain_with_faults(radio, case, &faults);
        if (acked or attempt == peer_tx_attempts) {
            harness.check(suite, case, acked, "{s} attempts={d}/{d}", .{ @tagName(result.status), attempt, peer_tx_attempts });
            return;
        }
        time.sleep_us(next_start -| time.get_time_since_boot().to_us());
    }
}

fn check_sniffer(radio: Radio) void {
    const case = "sniffer";
    sleep_when_ready(radio) catch |err| stop_case(radio, case, err);
    drain(radio, case);
    radio.set_promiscuous(true);
    radio.set_deliver_bad_fcs(true) catch |err| return fail(case, err);
    radio.set_rx_on_when_idle(true) catch |err| stop_case(radio, case, err);
    receive_when_ready(radio) catch |err| stop_case(radio, case, err);
    const capture_start = radio.now_us();

    var count: usize = 0;
    var bad_fcs: usize = 0;
    var first: u64 = 0;
    var last: u64 = 0;
    var monotonic = true;
    const end = time.get_time_since_boot().to_us() + 3_000_000;
    while (time.get_time_since_boot().to_us() < end) {
        var faults: FaultDrain = .{};
        var untimed = false;
        while (radio.poll()) |event| {
            faults.check_fault(event);
            if (event != .rx) continue;
            const frame = event.rx;
            const timestamp_us = frame.timestamp_us orelse {
                untimed = true;
                continue;
            };
            if (timestamp_us < capture_start) continue;
            if (count == 0) first = timestamp_us;
            monotonic = monotonic and timestamp_us >= last;
            last = timestamp_us;
            count += 1;
            if (!frame.fcs_ok) bad_fcs += 1;
        }
        faults.finish_failed(case, HarnessFaultReporter{});
        if (untimed) fail_untimed(case);
    }
    // The H2 transmits throughout the capture, so too few frames means
    // promiscuous RX is broken even though the timestamps never went backwards.
    harness.check(suite, case, count >= sniffer_min_frames and monotonic, "frames={d} bad_fcs={d} spread_us={d} monotonic={}", .{
        count, bad_fcs, last -| first, monotonic,
    });
}

fn fixture_frame(bytes: []const u8) Radio.RxFrame {
    return .{
        .bytes = bytes,
        .fcs = .{ 0x12, 0x34 },
        .channel = channel,
        .rssi = -50,
        .lqi = 100,
        .timestamp_us = 7,
        .ack_sent = true,
    };
}

test "fault-only or fault ahead of queued RX fails the peer drain" {
    for ([_]usize{ 0, 1 }) |sampled| {
        var observations: PeerObservations = .{};
        var drain_state: PeerDrain = .{ .start = 0, .sampled = sampled };
        try std.testing.expectError(error.Fault, drain_state.observe(.{
            .fault = .{ .reason = .missing_capture },
        }, &observations));
        try std.testing.expectEqual(@as(usize, 0), drain_state.fifo);
        try std.testing.expectEqual(@as(u3, 0), observations.seen);
    }
}

test "late H2 results count toward sequence coverage but not the sampled backlog" {
    const mac = [_]u8{ 0x61, 0x88, 1, 0x34, 0x12, 3, 0, 1, 0, 'H', '2' };
    for ([_]usize{ 0, 1 }) |sampled| {
        var observations: PeerObservations = .{};
        var drain_state: PeerDrain = .{ .start = 1, .sampled = sampled };
        try drain_state.observe(.{ .rx_error = .overrun }, &observations);
        try drain_state.observe(.{ .rx = fixture_frame(&mac) }, &observations);
        try std.testing.expectEqual(sampled, drain_state.qualifying);
        try std.testing.expectEqual(@as(u3, 1), observations.seen);
        try std.testing.expectEqual(@as(usize, 1), drain_state.fifo);
    }
}

const DeliveryFixture = struct {
    delivery: [11]u8 = .{ 0x61, 0x88, 0, 0x34, 0x12, 3, 0, 1, 0, 'H', '2' },

    fn poll(ptr: *anyopaque, _: Radio.PollMode) ?Radio.Event {
        const self: *DeliveryFixture = @ptrCast(ptr);
        if (self.delivery[2] == 2) return null;
        self.delivery[2] += 1;
        return .{ .rx = fixture_frame(&self.delivery) };
    }

    fn state(_: *anyopaque) Radio.State {
        return .receive;
    }

    fn fault_pending(_: *anyopaque) Radio.FaultPending {
        return .{};
    }

    fn now_us(_: *anyopaque) u64 {
        return 1;
    }
};

test "borrowed delivery bytes are classified before direct or blocking poll reuses them" {
    var vtable: Radio.VTable = undefined;
    vtable.poll = DeliveryFixture.poll;
    vtable.state = DeliveryFixture.state;
    vtable.fault_pending = DeliveryFixture.fault_pending;
    vtable.now_us = DeliveryFixture.now_us;
    for ([_]bool{ false, true }) |from_blocking_wait| {
        var fixture: DeliveryFixture = .{};
        const radio: Radio = .{ .ptr = &fixture, .vtable = &vtable };
        var observations: PeerObservations = .{};
        var drain_state: PeerDrain = .{ .start = 1, .sampled = 2 };
        if (from_blocking_wait) {
            const frame = try radio.receive_blocking(50, null);
            if (try classify_peer(1, frame)) observations.record(frame);
        } else {
            try drain_state.observe(radio.poll().?, &observations);
        }
        try std.testing.expectEqual(@as(u3, 1), observations.seen);
        try drain_state.observe(radio.poll().?, &observations);
        try std.testing.expectEqual(@as(u3, 3), observations.seen);
        try std.testing.expect(radio.poll() == null);
    }
}

test "untimed frames fail before timestamp and payload filtering" {
    var observations: PeerObservations = .{};
    var drain_state: PeerDrain = .{ .start = 100, .sampled = 1 };
    var frame = fixture_frame(&.{});
    frame.timestamp_us = null;
    try std.testing.expectError(error.Untimed, drain_state.observe(.{ .rx = frame }, &observations));
}

test "fault drain reports case failure only after null, with or without saved results" {
    const Fixture = struct {
        events: []const Radio.Event,
        reads: usize = 0,
        reported: ?Radio.Fault = null,
        reported_after_reads: usize = 0,

        fn poll(ptr: *anyopaque, _: Radio.PollMode) ?Radio.Event {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            defer self.reads += 1;
            return if (self.reads == self.events.len) null else self.events[self.reads];
        }

        fn fail_case(self: *@This(), case: []const u8, fault: Radio.Fault) void {
            std.debug.assert(std.mem.eql(u8, case, "receive"));
            std.debug.assert(self.reported == null);
            self.reported = fault;
            self.reported_after_reads = self.reads;
        }
    };
    const fault: Radio.Fault = .{ .reason = .missing_capture, .count = 2 };
    const events = [_]Radio.Event{
        .{ .fault = fault },
        .{ .rx_error = .aborted },
        .{ .tx_done = .{ .status = .aborted, .timestamp_us = null } },
    };
    var vtable: Radio.VTable = undefined;
    vtable.poll = Fixture.poll;
    for ([_]usize{ 1, events.len }) |count| {
        var fixture: Fixture = .{ .events = events[0..count] };
        const radio: Radio = .{ .ptr = &fixture, .vtable = &vtable };
        var faults: FaultDrain = .{};
        drain_and_report(radio, "receive", &faults, &fixture);
        try std.testing.expectEqual(@as(?Radio.Fault, fault), fixture.reported);
        try std.testing.expectEqual(count + 1, fixture.reported_after_reads);
        try std.testing.expectEqual(count + 1, fixture.reads);
    }
}
