//! Addressing/PAN presence follows IEEE 802.15.4-2015 Table 7-2, also
//! ESP-IDF v5.5.1 esp_ieee802154_frame.c:40–117. No PHR/FCS in these slices.
const std = @import("std");
test {
    _ = @import("ack_diagnostics.zig");
    _ = @import("ack_request.zig");
}
pub const security = @import("security.zig");
pub const Error = security.Error;

pub const Header = struct {
    version: u2,
    sequence: ?u8,
    destination: []const u8,
    source: []const u8,
    destination_pan: ?u16,
    source_pan: ?u16,
    auxiliary_offset: usize,
    auxiliary: ?security.Auxiliary,
    payload_offset: usize,
};

fn take(bytes: []const u8, offset: *usize, n: usize) Error![]const u8 {
    if (offset.* > bytes.len or bytes.len - offset.* < n) return error.InvalidFrame;
    const result = bytes[offset.*..][0..n];
    offset.* += n;
    return result;
}

fn address_len(mode: u8) usize {
    return switch (mode) {
        2 => 2,
        3 => 8,
        else => 0,
    };
}

pub fn parse(bytes: []const u8) Error!Header {
    if (bytes.len < 2 or bytes.len > 125) return error.InvalidFrame;
    const version: u2 = @truncate(bytes[1] >> 4);
    if (version == 0 and bytes[0] & 8 != 0) return error.UnsupportedFrame;
    if (version == 3 or bytes[0] & 0x80 != 0 or bytes[0] & 7 > 3) return error.UnsupportedFrame;
    const dst = bytes[1] >> 2 & 3;
    const src = bytes[1] >> 6;
    if (dst == 1 or src == 1) return error.InvalidFrame;
    const compressed = bytes[0] & 0x40 != 0;
    const suppressed = bytes[1] & 1 != 0;
    // FCF octet 1: bit 0 sequence suppression; bit 1 IE present.
    // Legacy frames cannot use either feature.
    if (version < 2 and (bytes[1] & 3 != 0 or (compressed and (dst == 0 or src == 0)))) return error.UnsupportedFrame;
    var offset: usize = 2;
    const seq: ?u8 = if (!suppressed) (try take(bytes, &offset, 1))[0] else null;
    const dst_pan_present = if (version < 2) dst != 0 else if (dst == 0) src == 0 and compressed else !((src == 0 or (src == 3 and dst == 3)) and compressed);
    const src_pan_present = src != 0 and !compressed and !(version == 2 and src == 3 and dst == 3);
    const dst_pan: ?u16 = if (dst_pan_present) std.mem.readInt(u16, (try take(bytes, &offset, 2))[0..2], .little) else null;
    const destination = try take(bytes, &offset, address_len(dst));
    const src_pan: ?u16 = if (src_pan_present) std.mem.readInt(u16, (try take(bytes, &offset, 2))[0..2], .little) else dst_pan;
    const source = try take(bytes, &offset, address_len(src));
    const aux_offset = offset;
    const aux: ?security.Auxiliary = if (bytes[0] & 8 != 0) try security.Auxiliary.decode(bytes[offset..]) else null;
    if (aux) |a| {
        if (version < 2 and bytes[0] & 7 == 0 and a.level >= 4) return error.UnsupportedFrame;
        offset += a.size();
    }
    if (bytes[1] & 2 != 0) offset = try header_ies_end(bytes, offset);
    // Legacy command identifier stays clear/authenticated (IDF frame.c:285–287).
    if (version < 2 and bytes[0] & 7 == 3 and aux != null) _ = try take(bytes, &offset, 1);
    return .{ .version = version, .sequence = seq, .destination = destination, .source = source, .destination_pan = dst_pan, .source_pan = src_pan, .auxiliary_offset = aux_offset, .auxiliary = aux, .payload_offset = offset };
}

/// Header IE list must terminate explicitly (HT1/HT2, zero length).
pub fn header_ies_end(bytes: []const u8, start: usize) Error!usize {
    var offset = start;
    while (true) {
        const descriptor = std.mem.readInt(u16, (try take(bytes, &offset, 2))[0..2], .little);
        if (descriptor & 0x8000 != 0) return error.InvalidFrame;
        const id = descriptor >> 7 & 0xff;
        const len = descriptor & 0x7f;
        if (id == 0x7e or id == 0x7f) {
            if (len != 0) return error.InvalidFrame;
            return offset;
        }
        _ = try take(bytes, &offset, len);
    }
}

/// Header Termination 2 IE: the MAC payload follows. Header Termination 1
/// (0x7e) instead announces payload IEs; Wireshark bbfe4b3b
/// packet-ieee802154.c:4572-4573 sets payload_ie_present only for HT1.
/// HT2 is IDF v6.0.2 esp_ieee802154_frame.h IEEE802154_IE_TYPE_HT2 (0x3f80)
/// and OpenThread mac_header_ie.hpp Termination2Ie::kHeaderIeId.
const ht2_id = 0x7f;

/// A generated ACK's header IE list: empty, or a complete list whose only
/// terminator is a zero-length HT2 at its end. The generator copies the list
/// verbatim and appends no payload IEs, so an HT1 terminator would advertise
/// payload IEs the ACK does not contain.
pub fn validate_ack_ies(ies: []const u8) Error!void {
    if (ies.len == 0) return;
    if (try header_ies_end(ies, 0) != ies.len) return error.InvalidFrame;
    const terminator = std.mem.readInt(u16, ies[ies.len - 2 ..][0..2], .little);
    if (terminator >> 7 & 0xff != ht2_id) return error.InvalidFrame;
}

/// Receive-path security gate. Promiscuous capture returns every frame as
/// received: secured frames keep their auxiliary header, ciphertext and MIC,
/// and neither replay state nor key counters are read or changed, whether or
/// not a context is configured. Otherwise a frame with the security bit set
/// is unsecured through `ctx`, or refused with UnknownKey when there is none,
/// so a node without keys never delivers an unauthenticated secured frame.
/// Returns the delivered length and what that delivery is: `.unsecured`
/// (bit clear, either mode), `.authenticated` or `.decrypted_unauthenticated`
/// (unsecured through `ctx`, by `receive_from`) or `.raw_secured`
/// (promiscuous capture of a secured frame, unverified).
pub fn deliver(ctx: ?*security.Context, promiscuous: bool, bytes: []u8, pan: u16) Error!Delivered {
    const wire = security.Protection.of_wire(if (bytes.len == 0) 0 else bytes[0]);
    if (wire == .unsecured or promiscuous) return .{ .len = bytes.len, .protection = wire };
    return receive_from(ctx orelse return error.UnknownKey, bytes, pan, null);
}

pub const Delivered = struct { len: usize, protection: security.Protection };

pub fn sender(ctx: *security.Context, h: Header, fallback_pan: u16) Error![8]u8 {
    if (h.source.len == 8) return h.source[0..8].*;
    if (h.source.len == 2) {
        const short = std.mem.readInt(u16, h.source[0..2], .little);
        for (ctx.peers) |peer| if (peer.short == short and peer.pan == (h.source_pan orelse fallback_pan)) return peer.extended;
    }
    return error.UnknownPeer;
}

/// Complete levels 1–4 in software with the radio security engine disabled.
/// `bytes` includes reserved MIC space, but excludes PHR/FCS. Both data and
/// enhanced ACKs use this path: MIC-only authenticates the entire clear MPDU;
/// M=0 applies CTR only to the payload (an ACK can have no payload at all).
/// Return false for levels 5–7, which the caller sends through the accelerator.
pub fn seal_software(key: [16]u8, extended: [8]u8, bytes: []u8) Error!bool {
    const h = try parse(bytes);
    const aux = h.auxiliary orelse return false;
    if (aux.level >= 5) return false;
    const mic = security.mic_len(aux.level);
    if (bytes.len < h.payload_offset + mic) return error.InvalidFrame;
    const end = bytes.len - mic;
    try security.seal(key, security.nonce(extended, aux.counter, aux.level), aux.level, bytes[0..end], h.payload_offset, bytes[end..]);
    return true;
}

pub fn receive(ctx: *security.Context, bytes: []u8, pan: u16) Error!usize {
    return (try receive_from(ctx, bytes, pan, null)).len;
}

/// Incoming frame security (IEEE 802.15.4-2015 §9.2.4). Replay state is
/// committed only after a MIC verifies; an opted-in level-4 frame is checked
/// against it read-only, never changes it, and is reported as
/// `.decrypted_unauthenticated`, since it has no MIC. The replay slot is
/// found before the MIC is checked, so `Replay` and `ReplayTableFull` say
/// nothing about whether the sender holds the key.
pub fn receive_from(ctx: *security.Context, bytes: []u8, pan: u16, known_sender: ?[8]u8) Error!Delivered {
    const h = try parse(bytes);
    const aux = h.auxiliary orelse return .{ .len = bytes.len, .protection = .unsecured };
    const key_index = try ctx.admit(aux);
    const extended = known_sender orelse try sender(ctx, h, pan);
    const mic = security.mic_len(aux.level);
    if (bytes.len < h.payload_offset + mic) return error.InvalidFrame;
    const end = bytes.len - mic;
    const n = security.nonce(extended, aux.counter, aux.level);
    if (mic == 0) {
        try ctx.check_counter(extended, key_index, aux.counter);
        try security.open(ctx.keys[key_index].value, n, aux.level, bytes[0..end], h.payload_offset, bytes[end..]);
        return .{ .len = end, .protection = .decrypted_unauthenticated };
    }
    const slot = try ctx.replay_slot(extended, key_index, aux.counter);
    try security.open(ctx.keys[key_index].value, n, aux.level, bytes[0..end], h.payload_offset, bytes[end..]);
    slot.* = .{ .used = true, .key = key_index, .extended = extended, .counter = aux.counter };
    return .{ .len = end, .protection = .authenticated };
}

/// Unsecure an enhanced ACK received for the frame `sent`. The ACK may omit
/// its source; its sender is `sent`'s destination.
pub fn receive_ack(ctx: *security.Context, sent: Header, ack_bytes: []u8, pan: u16) Error!Delivered {
    var peer = sent;
    peer.source = sent.destination;
    peer.source_pan = sent.destination_pan;
    const extended = sender(ctx, peer, pan) catch return error.InvalidFrame;
    return receive_from(ctx, ack_bytes, pan, extended);
}

/// IEEE 802.15.4-2015 §7.3.2: match by sequence when present; only a
/// sequence-suppressed ACK needs the received source as destination. Omitting
/// redundant addressing leaves airtime for security within IDF's ACK window.
/// IEs end with HT2 (validate_ack_ies).
pub fn ack(out: []u8, received: []const u8, aux: ?security.Auxiliary, ies: []const u8) Error!usize {
    const h = try parse(received);
    if (h.version != 2 or received[0] & 0x20 == 0 or received[0] & 7 == 2) return error.InvalidFrame;
    if (h.source.len == 0 and h.sequence == null) return error.UnsupportedFrame;
    try validate_ack_ies(ies);
    const destination = if (h.sequence == null) h.source else &.{};
    const mode: u8 = switch (destination.len) {
        2 => 2,
        8 => 3,
        else => 0,
    };
    // Suppress destination PAN when it was absent on the incoming frame.
    const pan = h.source_pan;
    const compressed = mode != 0 and pan == null;
    const needed = 2 + @as(usize, @intFromBool(h.sequence != null)) + @as(usize, if (mode != 0 and pan != null) 2 else 0) + destination.len + (if (aux) |a| a.size() + security.mic_len(a.level) else 0) + ies.len;
    if (needed > out.len or needed > 125) return error.InvalidFrame;
    out[0] = 2 | (if (aux != null) @as(u8, 8) else 0) | (if (compressed) @as(u8, 0x40) else 0);
    out[1] = 0x20 | (mode << 2) | @as(u8, @intFromBool(h.sequence == null)) | (if (ies.len != 0) @as(u8, 2) else 0);
    var offset: usize = 2;
    if (h.sequence) |seq| {
        out[offset] = seq;
        offset += 1;
    }
    if (mode != 0) {
        if (pan) |p| {
            std.mem.writeInt(u16, out[offset..][0..2], p, .little);
            offset += 2;
        }
        @memcpy(out[offset..][0..destination.len], destination);
        offset += destination.len;
    }
    if (aux) |a| offset += try a.encode(out[offset..]);
    @memcpy(out[offset..][0..ies.len], ies);
    offset += ies.len;
    if (aux) |a| {
        @memset(out[offset..][0..security.mic_len(a.level)], 0);
        offset += security.mic_len(a.level);
    }
    return offset;
}

test "v2 PAN compression, sequence suppression, and enhanced ACK addressing" {
    const frame = security.hex("61a85a341201000200abcd");
    const h = try parse(&frame);
    try std.testing.expectEqual(@as(usize, 9), h.payload_offset);
    var buffer: [125]u8 = undefined;
    const len = try ack(&buffer, &frame, null, &.{});
    try std.testing.expectEqualSlices(u8, &security.hex("02205a"), buffer[0..len]);
    const suppressed = security.hex("61a9341201000200");
    const suppressed_len = try ack(&buffer, &suppressed, null, &.{});
    try std.testing.expectEqualSlices(u8, &security.hex("022934120200"), buffer[0..suppressed_len]);
    for (0..9) |n| try std.testing.expectError(error.InvalidFrame, parse(frame[0..n]));
}

test "key lookup matches every identifier mode and source octet" {
    var keys: [4]security.Key = undefined;
    for (&keys, 0..) |*key, i| key.* = .{ .id = .{ .mode = @intCast(i), .source = @splat(1), .index = 7 }, .value = @splat(0) };
    var ctx: security.Context = .{ .keys = &keys, .replay = &.{} };
    for (keys, 0..) |key, i| try std.testing.expectEqual(i, try ctx.lookup(key.id));
    var wrong = keys[2].id;
    wrong.source[3] = 2;
    try std.testing.expectError(error.UnknownKey, ctx.lookup(wrong));
    wrong = keys[1].id;
    wrong.index = 8;
    try std.testing.expectError(error.UnknownKey, ctx.lookup(wrong));
}

test "authenticate before committing replay state; distinct peer and key counters" {
    var keys = [_]security.Key{.{ .id = .{ .mode = 1, .index = 7 }, .value = @splat(0) }};
    var slots: [2]security.Replay = @splat(.{});
    var ctx: security.Context = .{ .keys = &keys, .replay = &slots };
    var bytes: [64]u8 = undefined;
    // Legacy compressed extended addressing, source wire 01:00:00:00:00:00:00:00.
    const prefix = security.hex("49dc01341202000000000000000100000000000000");
    @memcpy(bytes[0..prefix.len], &prefix);
    const aux: security.Auxiliary = .{ .level = 5, .counter = 10, .id = keys[0].id };
    const offset = prefix.len + try aux.encode(bytes[prefix.len..]);
    @memcpy(bytes[offset..][0..4], "test");
    const len = offset + 4;
    const n = security.nonce(.{ 1, 0, 0, 0, 0, 0, 0, 0 }, 10, 5);
    try security.seal(keys[0].value, n, 5, bytes[0..len], offset, bytes[len..][0..4]);
    const encrypted = bytes;
    bytes[len] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, receive(&ctx, bytes[0 .. len + 4], 0x1234));
    try std.testing.expect(!slots[0].used);
    bytes = encrypted;
    try std.testing.expectEqual(len, try receive(&ctx, bytes[0 .. len + 4], 0x1234));
    try std.testing.expectEqualSlices(u8, "test", bytes[offset..len]);
    bytes = encrypted;
    try std.testing.expectError(error.Replay, receive(&ctx, bytes[0 .. len + 4], 0x1234));
    _ = try ctx.replay_slot(@splat(2), 0, 0);
    _ = try ctx.replay_slot(.{ 1, 0, 0, 0, 0, 0, 0, 0 }, 1, 0);
}

test "full replay table refuses a new sender before its MIC, committing nothing" {
    var keys = [_]security.Key{.{ .id = .{ .mode = 1, .index = 7 }, .value = @splat(0) }};
    const other: security.Replay = .{ .used = true, .extended = @splat(2), .key = 0, .counter = 5 };
    var slots = [_]security.Replay{other};
    var ctx: security.Context = .{ .keys = &keys, .replay = &slots };
    // Legacy compressed extended addressing, source wire 01:00:00:00:00:00:00:00.
    const prefix = security.hex("49dc01341202000000000000000100000000000000");
    var bytes: [64]u8 = undefined;
    @memcpy(bytes[0..prefix.len], &prefix);
    const offset = prefix.len + try (security.Auxiliary{ .level = 5, .counter = 10, .id = keys[0].id }).encode(bytes[prefix.len..]);
    @memcpy(bytes[offset..][0..4], "test");
    const len = offset + 4;
    try security.seal(keys[0].value, security.nonce(.{ 1, 0, 0, 0, 0, 0, 0, 0 }, 10, 5), 5, bytes[0..len], offset, bytes[len..][0..4]);
    const sealed = bytes;
    // A bad MIC gets the same error as a good one: the table is checked first.
    bytes[len] ^= 1;
    try std.testing.expectError(error.ReplayTableFull, receive(&ctx, bytes[0 .. len + 4], 0x1234));
    try std.testing.expectEqualDeep(other, slots[0]);
    bytes = sealed;
    try std.testing.expectError(error.ReplayTableFull, receive(&ctx, bytes[0 .. len + 4], 0x1234));
    try std.testing.expectEqualDeep(other, slots[0]);
    try std.testing.expectEqualSlices(u8, sealed[0 .. len + 4], bytes[0 .. len + 4]);
}

test "forged level-4 frame cannot advance authenticated replay state" {
    // Level 4 carries no MIC, so anyone can send one with any counter and no
    // key. Whatever receive returns for it, a later authenticated frame from
    // the same sender and key must still be accepted.
    var keys = [_]security.Key{.{ .id = .{ .mode = 1, .index = 7 }, .value = @splat(0) }};
    var slots: [2]security.Replay = @splat(.{});
    var ctx: security.Context = .{ .keys = &keys, .replay = &slots };
    // Legacy compressed extended addressing, source wire 01:00:00:00:00:00:00:00.
    const prefix = security.hex("49dc01341202000000000000000100000000000000");
    var forged: [64]u8 = undefined;
    @memcpy(forged[0..prefix.len], &prefix);
    const forged_offset = prefix.len + try (security.Auxiliary{ .level = 4, .counter = 0xffffffff, .id = keys[0].id }).encode(forged[prefix.len..]);
    @memcpy(forged[forged_offset..][0..4], "evil");
    const forged_result = receive(&ctx, forged[0 .. forged_offset + 4], 0x1234);

    var valid: [64]u8 = undefined;
    @memcpy(valid[0..prefix.len], &prefix);
    const offset = prefix.len + try (security.Auxiliary{ .level = 5, .counter = 10, .id = keys[0].id }).encode(valid[prefix.len..]);
    @memcpy(valid[offset..][0..4], "test");
    const len = offset + 4;
    try security.seal(keys[0].value, security.nonce(.{ 1, 0, 0, 0, 0, 0, 0, 0 }, 10, 5), 5, valid[0..len], offset, valid[len..][0..4]);
    try std.testing.expectEqual(len, try receive(&ctx, valid[0 .. len + 4], 0x1234));
    try std.testing.expectEqualSlices(u8, "test", valid[offset..len]);
    // Unauthenticated levels are rejected unless the context opts in.
    try std.testing.expect(std.meta.isError(forged_result));
}

test "level-4 policy: rejected by default, opted-in frames never touch replay state" {
    var keys = [_]security.Key{.{ .id = .{ .mode = 1, .index = 7 }, .value = @splat(0) }};
    var slots: [1]security.Replay = @splat(.{});
    var ctx: security.Context = .{ .keys = &keys, .replay = &slots };
    const Builder = struct {
        const prefix = security.hex("49dc01341202000000000000000100000000000000");
        const source: [8]u8 = .{ 1, 0, 0, 0, 0, 0, 0, 0 };
        fn frame(out: *[64]u8, level: u3, counter: u32) !usize {
            @memcpy(out[0..prefix.len], &prefix);
            const offset = prefix.len + try (security.Auxiliary{ .level = level, .counter = counter, .id = .{ .mode = 1, .index = 7 } }).encode(out[prefix.len..]);
            @memcpy(out[offset..][0..4], "data");
            const end = offset + 4;
            const mic = security.mic_len(level);
            try security.seal(@splat(0), security.nonce(source, counter, level), level, out[0..end], offset, out[end..][0..mic]);
            return end + mic;
        }
    };
    var bytes: [64]u8 = undefined;
    var len = try Builder.frame(&bytes, 4, 0xfffffffe);
    try std.testing.expectError(error.ImproperSecurityLevel, receive(&ctx, bytes[0..len], 0x1234));
    try std.testing.expect(!slots[0].used);

    ctx.accept_unauthenticated = true;
    // A genuine level-4 frame decrypts and is delivered without a slot,
    // labelled unauthenticated: it has no MIC.
    len = try Builder.frame(&bytes, 4, 3);
    const genuine = try deliver(&ctx, false, bytes[0..len], 0x1234);
    try std.testing.expectEqualSlices(u8, "data", bytes[genuine.len - 4 .. genuine.len]);
    try std.testing.expectEqual(security.Protection.decrypted_unauthenticated, genuine.protection);
    try std.testing.expect(!slots[0].used);
    // So is a forgery: flipped ciphertext bits decrypt to altered bytes.
    len = try Builder.frame(&bytes, 4, 4);
    bytes[len - 4] ^= 0xff;
    const forged = try deliver(&ctx, false, bytes[0..len], 0x1234);
    try std.testing.expect(!std.mem.eql(u8, "data", bytes[forged.len - 4 .. forged.len]));
    try std.testing.expectEqual(security.Protection.decrypted_unauthenticated, forged.protection);
    try std.testing.expect(!slots[0].used);
    // Forged counters change nothing: 0xffffffff is refused, others pass.
    len = try Builder.frame(&bytes, 4, 0xffffffff);
    try std.testing.expectError(error.InvalidCounter, receive(&ctx, bytes[0..len], 0x1234));
    len = try Builder.frame(&bytes, 4, 0xfffffffe);
    _ = try receive(&ctx, bytes[0..len], 0x1234);
    try std.testing.expect(!slots[0].used);
    // Authenticated traffic commits; a later level-4 frame is checked
    // read-only against it and cannot move it.
    len = try Builder.frame(&bytes, 5, 10);
    _ = try receive(&ctx, bytes[0..len], 0x1234);
    try std.testing.expectEqual(@as(u32, 10), slots[0].counter);
    len = try Builder.frame(&bytes, 4, 10);
    try std.testing.expectError(error.Replay, receive(&ctx, bytes[0..len], 0x1234));
    len = try Builder.frame(&bytes, 4, 0xfffffffe);
    _ = try receive(&ctx, bytes[0..len], 0x1234);
    try std.testing.expectEqual(@as(u32, 10), slots[0].counter);
    len = try Builder.frame(&bytes, 5, 11);
    _ = try receive(&ctx, bytes[0..len], 0x1234);
    try std.testing.expectEqual(@as(u32, 11), slots[0].counter);
    // A level-4 frame from an unknown sender with the table full is not
    // refused for want of a slot: it needs none.
    var other = bytes;
    len = try Builder.frame(&other, 4, 1);
    other[13] = 2;
    _ = try receive(&ctx, other[0..len], 0x1234);
}

test "received ACK protection: MIC levels authenticate, level 4 only decrypts" {
    // Version-2 data frame with ACK request, destination 02:00:..:00.
    const prefix = security.hex("29ec01341202000000000000000100000000000000");
    const id: security.KeyId = .{ .mode = 1, .index = 1 };
    for ([_]u3{ 4, 5 }) |level| {
        var sent_bytes: [64]u8 = undefined;
        @memcpy(sent_bytes[0..prefix.len], &prefix);
        const sent_len = prefix.len + try (security.Auxiliary{ .level = level, .counter = 9, .id = id }).encode(sent_bytes[prefix.len..]);
        const sent = try parse(sent_bytes[0..sent_len]);
        var keys = [_]security.Key{.{ .id = id, .value = @splat(0) }};
        var slots: [1]security.Replay = @splat(.{});
        var ctx: security.Context = .{ .keys = &keys, .replay = &slots };
        var ack_bytes: [125]u8 = undefined;
        const ack_len = try ack(&ack_bytes, sent_bytes[0..sent_len], .{ .level = level, .counter = 5, .id = id }, &.{});
        const a = try parse(ack_bytes[0..ack_len]);
        const end = ack_len - security.mic_len(level);
        try security.seal(@splat(0), security.nonce(.{ 2, 0, 0, 0, 0, 0, 0, 0 }, 5, level), level, ack_bytes[0..end], a.payload_offset, ack_bytes[end..ack_len]);
        const wire = ack_bytes;
        if (level == 4) {
            try std.testing.expectError(error.ImproperSecurityLevel, receive_ack(&ctx, sent, ack_bytes[0..ack_len], 0x1234));
            ctx.accept_unauthenticated = true;
        }
        const got = try receive_ack(&ctx, sent, ack_bytes[0..ack_len], 0x1234);
        try std.testing.expectEqual(end, got.len);
        try std.testing.expectEqual(if (level == 4) security.Protection.decrypted_unauthenticated else .authenticated, got.protection);
        // Only a verified MIC commits replay state.
        try std.testing.expectEqual(level != 4, slots[0].used);
        if (level == 4) continue;
        var tampered = wire;
        tampered[ack_len - 1] ^= 1;
        slots[0] = .{};
        try std.testing.expectError(error.AuthenticationFailed, receive_ack(&ctx, sent, tampered[0..ack_len], 0x1234));
        try std.testing.expect(!slots[0].used);
    }
}

test "authenticated frame with counter 0xffffffff is rejected before crypto" {
    var keys = [_]security.Key{.{ .id = .{ .mode = 1, .index = 7 }, .value = @splat(0) }};
    var slots: [1]security.Replay = @splat(.{});
    var ctx: security.Context = .{ .keys = &keys, .replay = &slots };
    const prefix = security.hex("49dc01341202000000000000000100000000000000");
    var bytes: [64]u8 = undefined;
    @memcpy(bytes[0..prefix.len], &prefix);
    const offset = prefix.len + try (security.Auxiliary{ .level = 5, .counter = 0xffffffff, .id = keys[0].id }).encode(bytes[prefix.len..]);
    @memcpy(bytes[offset..][0..4], "data");
    const len = offset + 4;
    try security.seal(@splat(0), security.nonce(.{ 1, 0, 0, 0, 0, 0, 0, 0 }, 0xffffffff, 5), 5, bytes[0..len], offset, bytes[len..][0..4]);
    try std.testing.expectError(error.InvalidCounter, receive(&ctx, bytes[0 .. len + 4], 0x1234));
    try std.testing.expect(!slots[0].used);
}

test "promiscuous receive delivers secured frames raw; filtered receive needs keys" {
    var keys = [_]security.Key{.{ .id = .{ .mode = 1, .index = 7 }, .value = @splat(0), .next_counter = 3 }};
    var slots: [1]security.Replay = @splat(.{});
    var ctx: security.Context = .{ .keys = &keys, .replay = &slots };
    // Legacy compressed extended addressing, source wire 01:00:00:00:00:00:00:00.
    const prefix = security.hex("49dc01341202000000000000000100000000000000");
    var wire: [64]u8 = undefined;
    @memcpy(wire[0..prefix.len], &prefix);
    const offset = prefix.len + try (security.Auxiliary{ .level = 5, .counter = 10, .id = keys[0].id }).encode(wire[prefix.len..]);
    @memcpy(wire[offset..][0..4], "test");
    const len = offset + 4;
    try security.seal(keys[0].value, security.nonce(.{ 1, 0, 0, 0, 0, 0, 0, 0 }, 10, 5), 5, wire[0..len], offset, wire[len..][0..4]);
    const captured = wire;

    // A monitor with or without keys gets the MPDU exactly as received.
    for ([_]?*security.Context{ null, &ctx }) |context| {
        const out = try deliver(context, true, wire[0 .. len + 4], 0x1234);
        try std.testing.expectEqual(len + 4, out.len);
        try std.testing.expectEqual(security.Protection.raw_secured, out.protection);
        try std.testing.expectEqualSlices(u8, captured[0 .. len + 4], wire[0 .. len + 4]);
    }
    try std.testing.expect(!slots[0].used);
    try std.testing.expectEqual(@as(u32, 3), keys[0].next_counter);

    // Filtered receive: no keys refuses it; keys unsecure it and commit.
    try std.testing.expectError(error.UnknownKey, deliver(null, false, wire[0 .. len + 4], 0x1234));
    const filtered = try deliver(&ctx, false, wire[0 .. len + 4], 0x1234);
    try std.testing.expectEqual(len, filtered.len);
    try std.testing.expectEqual(security.Protection.authenticated, filtered.protection);
    try std.testing.expectEqualSlices(u8, "test", wire[offset..len]);
    try std.testing.expectEqual(@as(u32, 10), slots[0].counter);

    // A captured replay is still delivered raw and moves nothing.
    wire = captured;
    const replayed = try deliver(&ctx, true, wire[0 .. len + 4], 0x1234);
    try std.testing.expectEqual(len + 4, replayed.len);
    try std.testing.expectEqual(security.Protection.raw_secured, replayed.protection);
    try std.testing.expectEqualSlices(u8, captured[0 .. len + 4], wire[0 .. len + 4]);
    try std.testing.expectError(error.Replay, deliver(&ctx, false, wire[0 .. len + 4], 0x1234));
    try std.testing.expectEqual(@as(u32, 10), slots[0].counter);
    try std.testing.expectEqual(@as(u32, 3), keys[0].next_counter);

    // Unsecured frames need no keys in either mode.
    var plain = security.hex("4188013412ffff0100");
    for ([_]bool{ false, true }) |promiscuous| {
        const out = try deliver(null, promiscuous, &plain, 0x1234);
        try std.testing.expectEqual(plain.len, out.len);
        try std.testing.expectEqual(security.Protection.unsecured, out.protection);
    }
}

test "generated ACKs refuse a header IE list ended by HT1" {
    const request = security.hex("61a85a341201000200abcd");
    var buffer: [125]u8 = undefined;
    // Vendor IE 0x1e of length 1, then HT1 (ID 0x7e): payload IEs would follow.
    try std.testing.expectError(error.InvalidFrame, ack(&buffer, &request, null, &security.hex("010fee003f")));
    try std.testing.expectEqual(@as(usize, 8), try ack(&buffer, &request, null, &security.hex("010fee803f")));
}

test "ACK header IE validator requires HT2 as the only terminator" {
    try validate_ack_ies(&.{});
    try validate_ack_ies(&security.hex("803f"));
    try validate_ack_ies(&security.hex("010fee803f"));
    try std.testing.expectError(error.InvalidFrame, validate_ack_ies(&security.hex("003f")));
    try std.testing.expectError(error.InvalidFrame, validate_ack_ies(&security.hex("010fee003f")));
    // HT1 then HT2: HT1 ends the walk first.
    try std.testing.expectError(error.InvalidFrame, validate_ack_ies(&security.hex("003f803f")));
    // Unterminated, and HT2 with a nonzero length.
    try std.testing.expectError(error.InvalidFrame, validate_ack_ies(&security.hex("010fee")));
    try std.testing.expectError(error.InvalidFrame, validate_ack_ies(&security.hex("813f00")));
    // Anything after HT2 is refused, whether or not it parses as an IE.
    try std.testing.expectError(error.InvalidFrame, validate_ack_ies(&security.hex("803f010fee")));
    try std.testing.expectError(error.InvalidFrame, validate_ack_ies(&security.hex("803f803f")));
}

test "secured enhanced ACK construction with IEs and suppressed sequence" {
    const received = security.hex("69ed020000000000000001000000000000000d0500000007");
    const h = try parse(&received);
    try std.testing.expectEqual(@as(?u8, null), h.sequence);
    var bytes: [125]u8 = undefined;
    const aux: security.Auxiliary = .{ .level = 5, .counter = 42, .id = h.auxiliary.?.id };
    const ies = security.hex("010fee803f");
    const len = try ack(&bytes, &received, aux, &ies);
    const a = try parse(bytes[0..len]);
    try std.testing.expectEqual(@as(u2, 2), a.version);
    try std.testing.expectEqual(@as(?u8, null), a.sequence);
    try std.testing.expectEqualSlices(u8, h.source, a.destination);
    try std.testing.expectEqual(@as(u32, 42), a.auxiliary.?.counter);
    try std.testing.expectEqual(len - 4, a.payload_offset);
    try std.testing.expectEqualSlices(u8, &ies, bytes[a.payload_offset - ies.len .. a.payload_offset]);
    try std.testing.expectError(error.InvalidFrame, ack(&bytes, &received, aux, &.{ 1, 0x0f, 1 }));
    try std.testing.expectError(error.InvalidFrame, ack(bytes[0..3], &received, aux, &ies));
}

test "generated secured ACK offset excludes only the MIC at every level" {
    const received = security.hex("61a85a341201000200abcd");
    const ies = security.hex("010fee803f");
    var bytes: [125]u8 = undefined;
    for (1..8) |value| {
        const level: u3 = @intCast(value);
        for ([_][]const u8{ &.{}, &ies }) |header_ies| {
            const len = try ack(&bytes, &received, .{ .level = level, .counter = 0 }, header_ies);
            const h = try parse(bytes[0..len]);
            try std.testing.expectEqual(len - security.mic_len(level), h.payload_offset);
        }
    }
}

test "software TX fallback covers MIC-only data and empty encrypted ACKs" {
    for (1..8) |l| {
        const level: u3 = @intCast(l);
        var bytes: [125]u8 = undefined;
        const prefix = security.hex("29ec01341202000000000000000100000000000000");
        @memcpy(bytes[0..prefix.len], &prefix);
        const aux: security.Auxiliary = .{ .level = level, .counter = 5, .id = .{ .mode = 1, .index = 1 } };
        const offset = prefix.len + try aux.encode(bytes[prefix.len..]);
        @memcpy(bytes[offset..][0..6], "MZSCxx");
        const end = offset + 6;
        const len = end + security.mic_len(level);
        @memset(bytes[end..len], 0);
        const handled = try seal_software(@splat(0), prefix[13..21].*, bytes[0..len]);
        try std.testing.expectEqual(level < 5, handled);
        if (!handled) continue;
        if (level < 4) try std.testing.expectEqualSlices(u8, "MZSCxx", bytes[offset..end]);
        try security.open(@splat(0), security.nonce(prefix[13..21].*, 5, level), level, bytes[0..end], offset, bytes[end..len]);
        try std.testing.expectEqualSlices(u8, "MZSCxx", bytes[offset..end]);
        var ack_bytes: [125]u8 = undefined;
        const ack_len = try ack(&ack_bytes, bytes[0..len], aux, &security.hex("010fee803f"));
        const a = try parse(ack_bytes[0..ack_len]);
        try std.testing.expectEqual(ack_len - security.mic_len(level), a.payload_offset);
        try std.testing.expect(try seal_software(@splat(0), @splat(2), ack_bytes[0..ack_len]));
        try security.open(@splat(0), security.nonce(@splat(2), 5, level), level, ack_bytes[0..a.payload_offset], a.payload_offset, ack_bytes[a.payload_offset..ack_len]);
    }
}

test "H2 unsecured request gets sequence-only enhanced ACK with configured IEs" {
    const request = security.hex("21ec015432020000000000000001000000000000004d5a53434407");
    var buffer: [125]u8 = undefined;
    const len = try ack(&buffer, &request, null, &security.hex("010fee803f"));
    try std.testing.expectEqualSlices(u8, &security.hex("022201010fee803f"), buffer[0..len]);
    const h = try parse(buffer[0..len]);
    try std.testing.expect(h.auxiliary == null);
    try std.testing.expectEqual(@as(?u8, 1), h.sequence);
}

test "all bench ACK sizes leave preparation margin in IDF default window" {
    const request = security.hex("21ec015432020000000000000001000000000000004d5a53434407");
    var buffer: [125]u8 = undefined;
    for (0..8) |level| {
        const aux: ?security.Auxiliary = if (level == 0) null else .{ .level = @intCast(level), .counter = 42, .id = .{ .mode = 1, .index = 1 } };
        const len = try ack(&buffer, &request, aux, &security.hex("010fee803f"));
        // 12-symbol turnaround + six PHY octets + MAC/FCS; 16 us/symbol.
        // Worst case is 30 MAC octets: 88 symbols, 320 us remaining.
        try std.testing.expect(len <= 30);
        try std.testing.expect(12 + (6 + len + 2) * 2 <= 88);
    }
}
