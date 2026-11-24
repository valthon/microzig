//! IEEE 802.15.4-2015 §9: explicit frame counters (no ASN nonce).
//! Software receive CCM* uses std.crypto's AES block primitive. The C6 MAC
//! accelerator exposed by IDF v5.5.1 sec.c is transmit-only.
const std = @import("std");
pub const Error = error{
    CryptoTimeout,
    InvalidSecurityConfig,
    InvalidFrame,
    UnsupportedFrame,
    UnknownKey,
    UnknownPeer,
    ImproperSecurityLevel,
    InvalidCounter,
    Replay,
    /// A frame names a sender with no replay slot for its key, and none is
    /// free. Returned before the MIC is checked: the sender is unverified.
    ReplayTableFull,
    CounterExhausted,
    AuthenticationFailed,
};
/// What the receive path did about a frame's security (FCF bit 3).
pub const Protection = enum {
    /// Security bit clear: there is no auxiliary header, MIC or ciphertext.
    unsecured,
    /// Security bit set and the MIC verified (levels 1-3, 5-7). The payload
    /// is plaintext and the MIC is removed; the auxiliary header is kept.
    authenticated,
    /// Security bit set at level 4 (ENC, no MIC), accepted only under
    /// `Context.accept_unauthenticated`. The payload is decrypted, but
    /// nothing proves who sent it or that it was not altered: anyone can
    /// flip ciphertext bits (IEEE 802.15.4-2015 §9.2.5).
    decrypted_unauthenticated,
    /// Security bit set, but delivered exactly as received (promiscuous
    /// capture): auxiliary header, ciphertext and MIC, none of it verified.
    raw_secured,

    /// The state of bytes as they came off the air, from FCF octet 0.
    pub fn of_wire(fcf0: u8) Protection {
        return if (fcf0 & 8 != 0) .raw_secured else .unsecured;
    }
};
pub const KeyId = struct {
    mode: u2 = 0,
    source: [8]u8 = @splat(0),
    index: u8 = 0,

    pub fn size(self: KeyId) usize {
        return switch (self.mode) {
            0 => 0,
            1 => 1,
            2 => 5,
            3 => 9,
        };
    }

    pub fn eql(a: KeyId, b: KeyId) bool {
        if (a.mode != b.mode) return false;
        if (a.mode == 0) return true;
        if (a.index != b.index) return false;
        const n: usize = switch (a.mode) {
            2 => 4,
            3 => 8,
            else => 0,
        };
        return std.mem.eql(u8, a.source[0..n], b.source[0..n]);
    }
};
pub const Auxiliary = struct {
    level: u3,
    counter: u32,
    id: KeyId = .{},

    pub fn size(self: Auxiliary) usize {
        return 5 + self.id.size();
    }

    pub fn encode(self: Auxiliary, out: []u8) Error!usize {
        if (self.level == 0) return error.UnsupportedFrame;
        if (out.len < self.size()) return error.InvalidFrame;
        out[0] = @as(u8, self.level) | (@as(u8, self.id.mode) << 3);
        std.mem.writeInt(u32, out[1..5], self.counter, .little);
        const n = self.id.size();
        if (n != 0) {
            @memcpy(out[5..][0 .. n - 1], self.id.source[0 .. n - 1]);
            out[4 + n] = self.id.index;
        }
        return self.size();
    }

    pub fn decode(input: []const u8) Error!Auxiliary {
        if (input.len < 5) return error.InvalidFrame;
        if (input[0] & 0xe0 != 0 or input[0] & 7 == 0) return error.UnsupportedFrame;
        var result: Auxiliary = .{ .level = @truncate(input[0]), .counter = std.mem.readInt(u32, input[1..5], .little), .id = .{ .mode = @truncate(input[0] >> 3) } };
        if (input.len < result.size()) return error.InvalidFrame;
        const n = result.id.size();
        if (n != 0) {
            @memcpy(result.id.source[0 .. n - 1], input[5..][0 .. n - 1]);
            result.id.index = input[4 + n];
        }
        return result;
    }
};
pub fn mic_len(level: u3) usize {
    return switch (level) {
        1, 5 => 4,
        2, 6 => 8,
        3, 7 => 16,
        else => 0,
    };
}

pub const Key = struct {
    id: KeyId = .{},
    value: [16]u8,
    /// Next counter, shared by data and ACKs; 0xffffffff means exhausted.
    /// Persist this across reboot BEFORE using the key again. Never reset on configure.
    next_counter: u32 = 0,

    /// 0xffffffff is never sent: receivers reject it (Context.admit), as
    /// Linux net/mac802154/llsec.c does on both TX and RX.
    pub fn reserve(self: *Key) Error!u32 {
        if (self.next_counter == std.math.maxInt(u32)) return error.CounterExhausted;
        defer self.next_counter += 1;
        return self.next_counter;
    }
};
pub const Peer = struct {
    extended: [8]u8,
    pan: u16,
    short: u16,
};
pub const Replay = struct {
    used: bool = false,
    extended: [8]u8 = @splat(0),
    key: usize = 0,
    counter: u32 = 0,
};
pub const Context = struct {
    keys: []Key,
    peers: []const Peer = &.{},
    replay: []Replay,
    /// Receive policy for level 4 (ENC), the only level without a MIC. Off:
    /// level-4 frames and ACKs are rejected with ImproperSecurityLevel and
    /// get no enhanced ACK. On: they are decrypted and delivered as
    /// `.decrypted_unauthenticated`, but their counter is checked read-only
    /// and never committed, since anyone can forge it; they get no replay
    /// protection of their own.
    accept_unauthenticated: bool = false,

    pub fn validate(self: *const Context) Error!void {
        for (self.keys, 0..) |key, i| {
            for (self.keys[0..i]) |previous| {
                // Identifiers are not part of the nonce. Independent counters
                // for identical AES keys could reuse the same nonce.
                if (key.id.eql(previous.id) or std.mem.eql(u8, &key.value, &previous.value)) return error.InvalidSecurityConfig;
            }
        }
    }

    pub fn lookup(self: *const Context, id: KeyId) Error!usize {
        for (self.keys, 0..) |key, i| if (key.id.eql(id)) return i;
        return error.UnknownKey;
    }

    /// Checks that need neither the sender nor any key material, in the order
    /// of the incoming frame security procedure (IEEE 802.15.4-2015 §9.2.4,
    /// with §9.2.5 level checking): security level policy, the counter value
    /// 0xffffffff, then key lookup. Changes no state; returns the key index.
    pub fn admit(self: *const Context, aux: Auxiliary) Error!usize {
        // Level 0 with security enabled never reaches here: Auxiliary.decode
        // rejects it as UnsupportedFrame.
        if (mic_len(aux.level) == 0 and !self.accept_unauthenticated) return error.ImproperSecurityLevel;
        if (aux.counter == std.math.maxInt(u32)) return error.InvalidCounter;
        return self.lookup(aux.id);
    }

    fn committed(self: *Context, extended: [8]u8, key: usize) ?*Replay {
        for (self.replay) |*entry| {
            if (entry.used and entry.key == key and std.mem.eql(u8, &entry.extended, &extended)) return entry;
        }
        return null;
    }

    /// Read-only freshness check against authenticated state.
    pub fn check_counter(self: *Context, extended: [8]u8, key: usize, counter: u32) Error!void {
        if (self.committed(extended, key)) |entry| if (counter <= entry.counter) return error.Replay;
    }

    /// Check before crypto, commit only after authentication: the caller
    /// writes the returned slot once the MIC verifies. Slots are never
    /// evicted: eviction would admit replays from a forgotten sender. So
    /// `Replay` and `ReplayTableFull` both come from an unverified frame.
    pub fn replay_slot(self: *Context, extended: [8]u8, key: usize, counter: u32) Error!*Replay {
        try self.check_counter(extended, key, counter);
        if (self.committed(extended, key)) |entry| return entry;
        for (self.replay) |*entry| if (!entry.used) return entry;
        return error.ReplayTableFull;
    }
};

/// Extended address and counter in most-significant-octet order (§9.3.2).
/// Addresses elsewhere in this API are in wire order.
pub fn nonce(extended_wire: [8]u8, counter: u32, level: u3) [13]u8 {
    var result: [13]u8 = undefined;
    for (extended_wire, 0..) |byte, i| result[7 - i] = byte;
    std.mem.writeInt(u32, result[8..12], counter, .big);
    result[12] = level;
    return result;
}

const Aes = std.crypto.core.aes.Aes128;
const Cipher = @TypeOf(Aes.initEnc(@as([16]u8, @splat(0))));

const SoftwareCipher = struct {
    cipher: Cipher,

    pub fn encrypt(self: SoftwareCipher, out: *[16]u8, in: *const [16]u8) Error!void {
        self.cipher.encrypt(out, in);
    }
};

fn ctr(cipher: anytype, n: [13]u8, bytes: []u8, start: u16) Error!void {
    var pos: usize = 0;
    var count = start;
    while (pos < bytes.len) : (count += 1) {
        var block: [16]u8 = undefined;
        block[0] = 1;
        @memcpy(block[1..14], &n);
        std.mem.writeInt(u16, block[14..16], count, .big);
        var stream: [16]u8 = undefined;
        try cipher.encrypt(&stream, &block);
        const size = @min(16, bytes.len - pos);
        for (bytes[pos..][0..size], stream[0..size]) |*byte, mask| byte.* ^= mask;
        pos += size;
    }
}

fn mac_blocks(cipher: anytype, state: *[16]u8, bytes: []const u8, prefix: bool) Error!void {
    var offset: usize = 0;
    var block: [16]u8 = @splat(0);
    var used: usize = 0;
    if (prefix) {
        std.mem.writeInt(u16, block[0..2], @intCast(bytes.len), .big);
        used = 2;
    }
    while (offset < bytes.len or used != 0) {
        const size = @min(16 - used, bytes.len - offset);
        @memcpy(block[used..][0..size], bytes[offset..][0..size]);
        for (state, block) |*byte, value| byte.* ^= value;
        try cipher.encrypt(state, state);
        offset += size;
        used = 0;
        block = @splat(0);
    }
}

/// In-place CCM*, bounded to one PHY frame. For levels 1–3 all clear bytes
/// are associated data and the CCM message is empty (IEEE §9.3.4).
/// `bytes` excludes the MIC; tag points to exactly mic_len(level) octets.
pub fn seal(key: [16]u8, n: [13]u8, level: u3, bytes: []u8, payload_offset: usize, tag: []u8) Error!void {
    if (level == 0 or bytes.len > 125 or payload_offset > bytes.len or tag.len != mic_len(level)) return error.InvalidFrame;
    return seal_with_cipher(SoftwareCipher{ .cipher = Aes.initEnc(key) }, n, level, bytes, payload_offset, tag);
}

/// The block provider may use a separately owned accelerator. It must permit
/// identical input/output buffers and propagate bounded hardware failures.
pub fn seal_with_cipher(cipher: anytype, n: [13]u8, level: u3, bytes: []u8, payload_offset: usize, tag: []u8) Error!void {
    if (level == 0 or bytes.len > 125 or payload_offset > bytes.len or tag.len != mic_len(level)) return error.InvalidFrame;
    if (tag.len != 0) {
        const ad = if (level < 4) bytes else bytes[0..payload_offset];
        const message = if (level < 4) bytes[bytes.len..] else bytes[payload_offset..];
        var state: [16]u8 = @splat(0);
        state[0] = 1 | (@as(u8, @intFromBool(ad.len != 0)) << 6) | (@as(u8, @intCast((tag.len - 2) / 2)) << 3);
        @memcpy(state[1..14], &n);
        std.mem.writeInt(u16, state[14..16], @intCast(message.len), .big);
        try cipher.encrypt(&state, &state);
        if (ad.len != 0) try mac_blocks(cipher, &state, ad, true);
        if (message.len != 0) try mac_blocks(cipher, &state, message, false);
        try ctr(cipher, n, state[0..tag.len], 0);
        @memcpy(tag, state[0..tag.len]);
    }
    if (level >= 4) try ctr(cipher, n, bytes[payload_offset..], 1);
}

/// Caller must not expose plaintext on failure. No replay state is changed here.
pub fn open(key: [16]u8, n: [13]u8, level: u3, bytes: []u8, payload_offset: usize, tag: []const u8) Error!void {
    if (level == 0 or bytes.len > 125 or payload_offset > bytes.len or tag.len != mic_len(level)) return error.InvalidFrame;
    if (level >= 4) try ctr(SoftwareCipher{ .cipher = Aes.initEnc(key) }, n, bytes[payload_offset..], 1);
    // seal() produces the expected MIC; use scratch so plaintext stays plaintext.
    var scratch: [125]u8 = undefined;
    @memcpy(scratch[0..bytes.len], bytes);
    var expected: [16]u8 = undefined;
    try seal(key, n, level, scratch[0..bytes.len], payload_offset, expected[0..tag.len]);
    var difference: u8 = 0;
    for (tag, expected[0..tag.len]) |a, b| difference |= a ^ b;
    if (difference != 0) {
        std.crypto.secureZero(u8, bytes);
        return error.AuthenticationFailed;
    }
}

test "Annex C.2.1 beacon MIC and C.2.3 command encryption (802.15.4-2006)" {
    // Published in OpenThread tests/unit/test_aes.cpp, TestMacBeaconFrame and
    // TestMacCommandFrame; https://github.com/openthread/openthread/blob/main/tests/unit/test_aes.cpp
    const key = hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecf");
    var beacon = hex("08d0842143010000000048deac020500000055cf000051525354");
    var tag: [8]u8 = undefined;
    try seal(key, hex("acde4800000000010000000502"), 2, &beacon, 18, &tag);
    try std.testing.expectEqualSlices(u8, &hex("223bc1ec841ab553"), &tag);
    var command = hex("2bdc842143020000000048deacffff010000000048deac060500000001ce");
    const n = nonce(hex("010000000048deac"), 5, 6);
    try seal(key, n, 6, &command, 29, &tag);
    try std.testing.expectEqual(@as(u8, 0xd8), command[29]);
    try std.testing.expectEqualSlices(u8, &hex("4fde529061f9c6f1"), &tag);
    try open(key, n, 6, &command, 29, &tag);
    try std.testing.expectEqual(@as(u8, 0xce), command[29]);
}

pub fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var result: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, text) catch unreachable;
    return result;
}

test "auxiliary header modes, truncation, counter exhaustion, replay slots" {
    inline for (0..4) |mode| {
        const aux: Auxiliary = .{ .level = 5, .counter = 0x12345678, .id = .{ .mode = mode, .source = hex("0102030405060708"), .index = 9 } };
        var buffer: [14]u8 = undefined;
        const len = try aux.encode(&buffer);
        const parsed = try Auxiliary.decode(buffer[0..len]);
        try std.testing.expect(aux.id.eql(parsed.id));
        try std.testing.expectEqual(aux.counter, parsed.counter);
        for (0..len) |i| try std.testing.expectError(error.InvalidFrame, Auxiliary.decode(buffer[0..i]));
    }
    var keys = [_]Key{.{ .value = @splat(0), .next_counter = 0xfffffffe }};
    try std.testing.expectEqual(@as(u32, 0xfffffffe), try keys[0].reserve());
    try std.testing.expectError(error.CounterExhausted, keys[0].reserve());
    try std.testing.expectError(error.CounterExhausted, keys[0].reserve());
    try std.testing.expectEqual(@as(u32, 0xffffffff), keys[0].next_counter);
    var slots = [_]Replay{.{}};
    var ctx: Context = .{ .keys = &keys, .replay = &slots };
    const slot = try ctx.replay_slot(@splat(1), 0, 0);
    slot.* = .{ .used = true, .extended = @splat(1), .key = 0, .counter = 0 };
    try std.testing.expectError(error.Replay, ctx.replay_slot(@splat(1), 0, 0));
    _ = try ctx.replay_slot(@splat(1), 0, 1);
    try std.testing.expectError(error.ReplayTableFull, ctx.replay_slot(@splat(2), 0, 1));
}

test "all levels decrypt; MIC or wrong key cannot release plaintext" {
    for (1..8) |l| {
        const level: u3 = @intCast(l);
        var bytes = [_]u8{ 1, 2, 3, 4, 5, 6, 7 };
        var tag: [16]u8 = undefined;
        const n = nonce(@splat(0), 1, level);
        try seal(@splat(0), n, level, &bytes, 3, tag[0..mic_len(level)]);
        const encrypted = bytes;
        try open(@splat(0), n, level, &bytes, 3, tag[0..mic_len(level)]);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7 }, &bytes);
        if (mic_len(level) != 0) {
            bytes = encrypted;
            try std.testing.expectError(error.AuthenticationFailed, open(@splat(1), n, level, &bytes, 3, tag[0..mic_len(level)]));
            bytes = encrypted;
            tag[0] ^= 1;
            try std.testing.expectError(error.AuthenticationFailed, open(@splat(0), n, level, &bytes, 3, tag[0..mic_len(level)]));
        }
    }
}

test "key aliases cannot introduce independent counters for the same AES key" {
    var keys = [_]Key{
        .{ .id = .{ .mode = 1, .index = 1 }, .value = @splat(0) },
        .{ .id = .{ .mode = 2, .index = 2 }, .value = @splat(0) },
    };
    const ctx: Context = .{ .keys = &keys, .replay = &.{} };
    try std.testing.expectError(error.InvalidSecurityConfig, ctx.validate());
    keys[1].value = @splat(1);
    try ctx.validate();
    keys[1].id = keys[0].id;
    try std.testing.expectError(error.InvalidSecurityConfig, ctx.validate());
}

test "CCM star independent all-level vectors with partial associated-data block" {
    // Python cryptography AESCCM: levels 1–3 use empty message and all 33
    // octets as AD; levels 5–7 use 27 AD + 6 message octets. Level 4 uses
    // AES-ECB(01 || nonce || 0001) as the payload keystream, no CBC-MAC/S0.
    const vectors = [_][]const u8{
        &hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f207ad45160"),
        &hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20f1ca2811f8936483"),
        &hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2027b9e587adf23e8be30ac674f9bad024"),
        &hex("000102030405060708090a0b0c0d0e0f101112131415161718191aae407c51b9ab"),
        &hex("000102030405060708090a0b0c0d0e0f101112131415161718191a4f18c308cb4b2bbb12cc"),
        &hex("000102030405060708090a0b0c0d0e0f101112131415161718191a0db57aaa10d924595a63b49bfb86"),
        &hex("000102030405060708090a0b0c0d0e0f101112131415161718191a34f51ea04ade10b3d0b9262509fe36111ce924a4a0a3"),
    };
    for (vectors, 1..) |vector, l| {
        const level: u3 = @intCast(l);
        var bytes: [49]u8 = @splat(0);
        for (bytes[0..33], 0..) |*b, i| b.* = @intCast(i);
        const n = nonce(hex("010000000048deac"), 5, level);
        try seal(hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"), n, level, bytes[0..33], 27, bytes[33..][0..mic_len(level)]);
        try std.testing.expectEqualSlices(u8, vector, bytes[0..vector.len]);
    }
}

const CountingCipher = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    cipher: SoftwareCipher,

    pub fn encrypt(self: *CountingCipher, output: *[16]u8, input: *const [16]u8) Error!void {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.CryptoTimeout;
        try self.cipher.encrypt(output, input);
    }
};

test "MIC-only ACK takes four AES blocks, empty encryption-only ACK takes none" {
    inline for (1..5) |level| {
        // 24 clear octets: B0, two AD blocks and S0, regardless of MIC length.
        var bytes: [24]u8 = @splat(0x42);
        const original = bytes;
        var tag: [16]u8 = @splat(0);
        var expected: [16]u8 = @splat(0);
        const n = nonce(@splat(3), 42, level);
        var cipher: CountingCipher = .{ .cipher = .{ .cipher = Aes.initEnc(@splat(0)) } };
        try seal_with_cipher(&cipher, n, level, &bytes, bytes.len, tag[0..mic_len(level)]);
        try std.testing.expectEqual(@as(usize, if (level == 4) 0 else 4), cipher.calls);
        try std.testing.expectEqualSlices(u8, &original, &bytes);
        try seal(@splat(0), n, level, &bytes, bytes.len, expected[0..mic_len(level)]);
        try std.testing.expectEqualSlices(u8, &expected, &tag);
    }
}

test "ACK block failure propagates before publishing a MIC" {
    for (1..5) |fail_at| {
        var cipher: CountingCipher = .{ .fail_at = fail_at, .cipher = .{ .cipher = Aes.initEnc(@splat(0)) } };
        var bytes: [24]u8 = @splat(0);
        var tag: [16]u8 = @splat(0xa5);
        try std.testing.expectError(error.CryptoTimeout, seal_with_cipher(&cipher, nonce(@splat(0), 1, 3), 3, &bytes, bytes.len, &tag));
        try std.testing.expectEqual(fail_at, cipher.calls);
        try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xa5)), &tag);
    }
}

test "admit rejects unauthenticated levels by default and counter 0xffffffff" {
    var keys = [_]Key{.{ .id = .{ .mode = 1, .index = 1 }, .value = @splat(0) }};
    var ctx: Context = .{ .keys = &keys, .replay = &.{} };
    for (1..8) |l| {
        const level: u3 = @intCast(l);
        const aux: Auxiliary = .{ .level = level, .counter = 5, .id = keys[0].id };
        if (level == 4) {
            try std.testing.expectError(error.ImproperSecurityLevel, ctx.admit(aux));
        } else try std.testing.expectEqual(@as(usize, 0), try ctx.admit(aux));
        var exhausted = aux;
        exhausted.counter = 0xffffffff;
        try std.testing.expectError(if (level == 4) error.ImproperSecurityLevel else error.InvalidCounter, ctx.admit(exhausted));
    }
    ctx.accept_unauthenticated = true;
    try std.testing.expectEqual(@as(usize, 0), try ctx.admit(.{ .level = 4, .counter = 5, .id = keys[0].id }));
    try std.testing.expectError(error.InvalidCounter, ctx.admit(.{ .level = 4, .counter = 0xffffffff, .id = keys[0].id }));
    try std.testing.expectError(error.UnknownKey, ctx.admit(.{ .level = 5, .counter = 5, .id = .{ .mode = 1, .index = 2 } }));
    // Security enabled with level 0 is not a security level (§9.2.4).
    try std.testing.expectError(error.UnsupportedFrame, Auxiliary.decode(&.{ 0x08, 0, 0, 0, 0, 1 }));
}
