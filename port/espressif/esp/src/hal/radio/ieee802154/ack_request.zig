//! Enhanced-ACK generator decision for one received ACK request, run by the
//! RX_DONE ISR before the 192 µs turnaround. No hardware access: the ISR
//! copies the request out of DMA, calls `prepare`, then seals and arms the
//! ACK it returns.
const std = @import("std");
const header = @import("header.zig");
const security = header.security;
const ack_diagnostics = @import("ack_diagnostics.zig");
const rx = @import("../ieee802154_rx.zig");
pub const Error = security.Error;

/// With enhanced ACKs the ISR walks the key and peer tables, so both are
/// bounded independently of caller storage.
pub const max_keys = 16;
pub const max_peers = 16;

pub fn within_table_limits(keys: usize, peers: usize) bool {
    return keys <= max_keys and peers <= max_peers;
}

pub const Prepared = struct {
    /// ACK MPDU length, including reserved MIC space, excluding the FCS.
    len: usize,
    /// Present for a secured request: the key and the reserved counter.
    key: ?usize = null,
    auxiliary: ?security.Auxiliary = null,
};

/// Build the enhanced ACK for `received` into `out`. Either returns an error
/// having reserved no counter, or reserves exactly one counter of the
/// request's key and returns an ACK carrying it.
///
/// A secured request runs every incoming-security check that needs no crypto
/// before the reservation: level policy, counter 0xffffffff and key lookup
/// (Context.admit), the sender lookup and the MIC length, in the order
/// header.receive_from checks them, then every check the ACK builder makes.
/// The task repeats them after turnaround, with MIC verification and the
/// replay check. The replay check is deliberately not
/// run here: a sender retrying after a lost ACK repeats its counter and must
/// still be acknowledged.
pub fn prepare(ctx: ?*security.Context, out: []u8, received: []const u8, ies: []const u8, pan: u16, trace: ?*ack_diagnostics.Ack) Error!Prepared {
    const h = try header.parse(received);
    const aux = h.auxiliary orelse {
        const len = try header.ack(out, received, null, ies);
        if (trace) |t| t.ack_len = @intCast(len);
        return .{ .len = len };
    };
    if (trace) |t| {
        t.level = aux.level;
        t.received_counter = aux.counter;
    }
    const context = ctx orelse return error.UnknownKey;
    const key = try context.admit(aux);
    _ = try header.sender(context, h, pan);
    if (received.len < h.payload_offset + security.mic_len(aux.level)) return error.InvalidFrame;
    // Build with a placeholder counter, so every refusal the builder can
    // make happens before the reservation; then write the reserved counter.
    var reply: security.Auxiliary = .{ .level = aux.level, .id = aux.id, .counter = 0 };
    const len = try header.ack(out, received, reply, ies);
    reply.counter = try context.keys[key].reserve();
    // header.ack ends with auxiliary header, IEs, MIC; the counter follows
    // the security control octet.
    const counter_offset = len - security.mic_len(aux.level) - ies.len - reply.size() + 1;
    std.mem.writeInt(u32, out[counter_offset..][0..4], reply.counter, .little);
    if (trace) |t| {
        t.ack_counter = reply.counter;
        t.ack_len = @intCast(len);
    }
    return .{ .len = len, .key = key, .auxiliary = reply };
}

/// rx.receive reports a request the generator refused as AckTransmitFailed:
/// no ACK went out. Return why it was refused instead.
pub fn receive_error(err: rx.Error, rejection: ?Error) (rx.Error || Error) {
    if (err == error.AckTransmitFailed) if (rejection) |reason| return reason;
    return err;
}

const Bench = struct {
    keys: [1]security.Key = .{.{ .value = @splat(0) }},
    peers: [1]security.Peer = .{.{ .extended = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .pan = 0x1234, .short = 0x0001 }},
    ctx: security.Context = undefined,
    out: [125]u8 = undefined,

    fn init(self: *Bench) void {
        self.ctx = .{ .keys = &self.keys, .peers = &self.peers, .replay = &.{} };
    }

    fn run(self: *Bench, received: []const u8) Error!Prepared {
        return prepare(&self.ctx, &self.out, received, &.{}, 0x1234, null);
    }
};

// Requests below: v2 data frames with AR set. The key is identifier mode 0;
// the only peer is short 0x0001 on PAN 0x1234.
const admitted = security.hex("69a8" ++ "07" ++ "3412" ++ "0200" ++ "0100" ++ "0105000000" ++ "aabbccdd");

const Refusal = struct { frame: []const u8, err: Error };

fn expect_refusals(cases: []const Refusal) !void {
    var bench: Bench = .{};
    bench.init();
    for (cases) |case| {
        const result = bench.run(case.frame);
        try std.testing.expectEqual(@as(u32, 0), bench.keys[0].next_counter);
        try std.testing.expectError(case.err, result);
    }
}

test "a request that cannot be answered reserves no counter" {
    try expect_refusals(&.{
        // Sequence suppressed, destination but no source, level 1: the
        // sender lookup refuses it before the ACK is built.
        .{ .frame = &security.hex("2929" ++ "3412" ++ "0200" ++ "0105000000" ++ "aabbccdd"), .err = error.UnknownPeer },
        // ACK frame type with AR set: the sender is known, the ACK builder
        // refuses.
        .{ .frame = &security.hex("6aa8" ++ "07" ++ "3412" ++ "0200" ++ "0100" ++ "0105000000" ++ "aabbccdd"), .err = error.InvalidFrame },
        // Unsecured with the first request's addressing: no ACK possible.
        .{ .frame = &security.hex("2129" ++ "3412" ++ "0200" ++ "4d5a"), .err = error.UnsupportedFrame },
    });
}

test "a request too short for its MIC or without a known sender reserves no counter" {
    try expect_refusals(&.{
        // Sequence number, destination, no source: the ACK could be
        // addressed, but the task cannot name the sender.
        .{ .frame = &security.hex("2928" ++ "07" ++ "3412" ++ "0200" ++ "0105000000" ++ "aabbccdd"), .err = error.UnknownPeer },
        // A short source the peer table does not know.
        .{ .frame = &security.hex("69a8" ++ "07" ++ "3412" ++ "0200" ++ "0200" ++ "0105000000" ++ "aabbccdd"), .err = error.UnknownPeer },
        // The sender is checked before the MIC length, as receive_from does:
        // an unknown short source with a truncated MIC is UnknownPeer.
        .{ .frame = &security.hex("69a8" ++ "07" ++ "3412" ++ "0200" ++ "0200" ++ "0105000000" ++ "aabbcc"), .err = error.UnknownPeer },
        // MIC truncated to three of four octets.
        .{ .frame = &security.hex("69a8" ++ "07" ++ "3412" ++ "0200" ++ "0100" ++ "0105000000" ++ "aabbcc"), .err = error.InvalidFrame },
    });
}

test "requests refused by policy, key or parse reserve no counter" {
    try expect_refusals(&.{
        // Level 4 under the default policy.
        .{ .frame = &security.hex("69a8" ++ "07" ++ "3412" ++ "0200" ++ "0100" ++ "0405000000"), .err = error.ImproperSecurityLevel },
        // Counter 0xffffffff.
        .{ .frame = &security.hex("69a8" ++ "07" ++ "3412" ++ "0200" ++ "0100" ++ "01ffffffff" ++ "aabbccdd"), .err = error.InvalidCounter },
        // Unknown key: identifier mode 1, index 9.
        .{ .frame = &security.hex("69a8" ++ "07" ++ "3412" ++ "0200" ++ "0100" ++ "090500000009" ++ "aabbccdd"), .err = error.UnknownKey },
        // Unterminated header IE list, secured and unsecured.
        .{ .frame = &security.hex("69aa" ++ "07" ++ "3412" ++ "0200" ++ "0100" ++ "0105000000" ++ "0f01"), .err = error.InvalidFrame },
        .{ .frame = &security.hex("61aa" ++ "07" ++ "3412" ++ "0200" ++ "0100" ++ "0f01"), .err = error.InvalidFrame },
    });
    var bench: Bench = .{};
    bench.init();
    try std.testing.expectError(error.UnknownKey, prepare(null, &bench.out, &admitted, &.{}, 0x1234, null));
    bench.keys[0].next_counter = 0xffffffff;
    try std.testing.expectError(error.CounterExhausted, bench.run(&admitted));
    try std.testing.expectEqual(@as(u32, 0xffffffff), bench.keys[0].next_counter);
}

test "an admitted request reserves exactly one counter, carried by its ACK" {
    var bench: Bench = .{};
    bench.init();
    var trace: ack_diagnostics.Ack = .{ .level = 0, .received_counter = 0 };
    for (0..2) |i| {
        const expected: u32 = @intCast(i);
        const result = try prepare(&bench.ctx, &bench.out, &admitted, &.{}, 0x1234, &trace);
        try std.testing.expectEqual(expected + 1, bench.keys[0].next_counter);
        const a = try header.parse(bench.out[0..result.len]);
        try std.testing.expectEqual(expected, a.auxiliary.?.counter);
        try std.testing.expectEqual(expected, result.auxiliary.?.counter);
        try std.testing.expectEqual(@as(?usize, 0), result.key);
        try std.testing.expectEqual(@as(?u32, expected), trace.ack_counter);
        try std.testing.expectEqual(@as(u32, 5), trace.received_counter);
    }
    // The counter also lands in place when IEs follow the auxiliary header.
    const ies = security.hex("010fee803f");
    const result = try prepare(&bench.ctx, &bench.out, &admitted, &ies, 0x1234, null);
    const a = try header.parse(bench.out[0..result.len]);
    try std.testing.expectEqual(@as(u32, 2), a.auxiliary.?.counter);
    try std.testing.expectEqualSlices(u8, &ies, bench.out[a.payload_offset - ies.len .. a.payload_offset]);
    // An unsecured request reserves nothing.
    trace = .{ .level = 0, .received_counter = 0 };
    const unsecured = try prepare(&bench.ctx, &bench.out, &security.hex("61a8" ++ "07" ++ "3412" ++ "0200" ++ "0100" ++ "4d5a"), &.{}, 0x1234, &trace);
    try std.testing.expectEqual(@as(?usize, null), unsecured.key);
    try std.testing.expectEqual(@as(?u7, 3), trace.ack_len);
    try std.testing.expectEqual(@as(?u32, null), trace.ack_counter);
    try std.testing.expectEqual(@as(u32, 3), bench.keys[0].next_counter);
}

test "smallest requests that reserve a counter, and their ACKs" {
    var bench: Bench = .{};
    bench.init();
    // A source is required for the sender lookup; PAN compressed, no
    // destination, key identifier mode 0, empty payload. Sequence suppressed:
    // the ACK carries the source back as its destination.
    const suppressed = security.hex("69a1" ++ "0100" ++ "0105000000" ++ "aabbccdd");
    try std.testing.expectEqual(@as(usize, 13), suppressed.len);
    try std.testing.expectEqual(@as(usize, 13), (try bench.run(&suppressed)).len);
    // With a sequence number the ACK has no destination instead.
    const sequenced = security.hex("69a0" ++ "07" ++ "0100" ++ "0105000000" ++ "aabbccdd");
    try std.testing.expectEqual(@as(usize, 14), sequenced.len);
    try std.testing.expectEqual(@as(usize, 12), (try bench.run(&sequenced)).len);
    // Level 4, when the context opts in, carries no MIC.
    bench.ctx.accept_unauthenticated = true;
    const unauthenticated = security.hex("69a1" ++ "0100" ++ "0405000000");
    try std.testing.expectEqual(@as(usize, 9), unauthenticated.len);
    try std.testing.expectEqual(@as(usize, 9), (try bench.run(&unauthenticated)).len);
    try std.testing.expectEqual(@as(u32, 3), bench.keys[0].next_counter);
}

test "a refused request reports its refusal; other ACK failures do not change" {
    try std.testing.expectEqual(error.UnknownPeer, receive_error(error.AckTransmitFailed, error.UnknownPeer));
    try std.testing.expectEqual(error.AckTransmitFailed, receive_error(error.AckTransmitFailed, null));
    try std.testing.expectEqual(error.Timeout, receive_error(error.Timeout, error.UnknownPeer));
}

test "the reserved counter lands in the ACK for every key identifier mode and MIC length" {
    const source: [8]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    var keys = [4]security.Key{
        .{ .id = .{ .mode = 0 }, .value = @splat(0) },
        .{ .id = .{ .mode = 1, .index = 1 }, .value = @splat(0) },
        .{ .id = .{ .mode = 2, .source = source, .index = 1 }, .value = @splat(0) },
        .{ .id = .{ .mode = 3, .source = source, .index = 1 }, .value = @splat(0) },
    };
    var peers = [1]security.Peer{.{ .extended = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .pan = 0x1234, .short = 0x0001 }};
    var ctx: security.Context = .{ .keys = &keys, .peers = &peers, .replay = &.{} };
    var out: [125]u8 = undefined;
    // Security control without the level, then the counter and the key
    // identifier: source (4 or 8 octets), then index.
    const ids = [_][]const u8{
        &security.hex("00" ++ "05000000"),
        &security.hex("08" ++ "05000000" ++ "01"),
        &security.hex("10" ++ "05000000" ++ "11223344" ++ "01"),
        &security.hex("18" ++ "05000000" ++ "1122334455667788" ++ "01"),
    };
    // Levels 5, 6 and 7 carry a 4, 8 and 16 octet MIC.
    for (ids, 0..) |aux, mode| {
        for ([_]u3{ 5, 6, 7 }) |level| {
            const reserved: u32 = 0x01020300 + @as(u32, level);
            keys[mode].next_counter = reserved;
            var frame: [64]u8 = undefined;
            const head = security.hex("69a8" ++ "07" ++ "3412" ++ "0200" ++ "0100");
            @memcpy(frame[0..head.len], &head);
            @memcpy(frame[head.len..][0..aux.len], aux);
            frame[head.len] |= level;
            const mic = security.mic_len(level);
            const n = head.len + aux.len + mic;
            @memset(frame[n - mic .. n], 0xaa);
            const result = try prepare(&ctx, &out, frame[0..n], &.{}, 0x1234, null);
            const a = try header.parse(out[0..result.len]);
            try std.testing.expectEqual(level, a.auxiliary.?.level);
            try std.testing.expectEqual(@as(u2, @intCast(mode)), a.auxiliary.?.id.mode);
            try std.testing.expectEqual(reserved, a.auxiliary.?.counter);
            try std.testing.expectEqual(reserved, result.auxiliary.?.counter);
            try std.testing.expectEqual(reserved + 1, keys[mode].next_counter);
        }
    }
}

test "table limits bound the ISR's key and peer walks" {
    try std.testing.expect(within_table_limits(16, 16));
    try std.testing.expect(!within_table_limits(17, 0));
    try std.testing.expect(!within_table_limits(0, 17));
}
