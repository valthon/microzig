//! Self-test policy, matching ble_central: retry only failed establishment.
//! Core v6.0 Vol 1 Part F §2.59; Vol 6 Part B §§4.5, 4.5.2.
const std = @import("std");
pub const Role = enum { central, peripheral, auto };

/// Forced roles need neither a discovery peer nor address-order election.
pub fn is_central(role: Role, local: [6]u8, peer: ?[6]u8) error{PeerNotFound}!bool {
    return switch (role) {
        .central => true,
        .peripheral => false,
        .auto => std.mem.order(u8, &local, &(peer orelse return error.PeerNotFound)) == .lt,
    };
}

// ESP-IDF v5.5.1 NimBLE enables establishment reattempts on C6 and defaults
// CONFIG_BT_NIMBLE_MAX_CONN_REATTEMPT to 3 (components/bt/host/nimble/Kconfig.in:574-585).
// Use three total attempts for this self-test's per-boot deadline.
pub const max_attempts = 3;
pub const backoff_ms = 250;

pub fn retry(err: anyerror, attempt: u8, connection: ?u16, status: ?u8, reason: ?u8) bool {
    if (connection != null or attempt >= max_attempts) return false;
    return switch (err) {
        error.ConnectionFailed => status == 0x3e,
        error.Disconnected, error.NoConnection => reason == 0x3e,
        else => false,
    };
}

test "retry establishment failure before or after handle creation, at most three attempts" {
    for (1..max_attempts + 1) |attempt| {
        const expected = attempt < max_attempts;
        try std.testing.expectEqual(expected, retry(error.ConnectionFailed, @intCast(attempt), null, 0x3e, null));
        try std.testing.expectEqual(expected, retry(error.Disconnected, @intCast(attempt), null, 0, 0x3e));
        try std.testing.expectEqual(expected, retry(error.NoConnection, @intCast(attempt), null, 0, 0x3e));
    }
}

test "live links, other statuses and unrelated errors never retry" {
    try std.testing.expect(!retry(error.Disconnected, 1, 7, 0, 0x3e));
    try std.testing.expect(!retry(error.ConnectionFailed, 1, null, null, 0x3e));
    try std.testing.expect(!retry(error.Disconnected, 1, null, 0x3e, null));
    try std.testing.expect(!retry(error.Disconnected, 1, null, 0, 0x08));
    try std.testing.expect(!retry(error.ConnectionFailed, 1, null, 0x0c, null));
    // Stale establishment diagnostics cannot turn an ATT/transport failure or
    // a host timeout into permission to retry.
    for ([_]anyerror{ error.Timeout, error.AttError, error.TransportFailed, error.SecurityFailed }) |err| {
        try std.testing.expect(!retry(err, 1, null, 0x3e, 0x3e));
    }
}

test "forced roles work without discovery; auto uses public address order" {
    const low = [6]u8{ 1, 2, 3, 4, 5, 6 };
    const high = [6]u8{ 2, 2, 3, 4, 5, 6 };
    try std.testing.expect(try is_central(.central, high, null));
    try std.testing.expect(!try is_central(.peripheral, low, null));
    try std.testing.expect(try is_central(.central, high, low));
    try std.testing.expect(!try is_central(.peripheral, low, high));
    try std.testing.expect(try is_central(.auto, low, high));
    try std.testing.expect(!try is_central(.auto, high, low));
    try std.testing.expectError(error.PeerNotFound, is_central(.auto, low, null));
}

// Experimental manufacturer ID 0xffff, magic MZSM, boot nonce, readiness byte.
// This is a test discriminator, not authentication against a malicious advertiser.
pub const Identity = struct { address: [6]u8, address_type: u8, nonce: [4]u8 };
pub fn advertising_data(name: []const u8, nonce: [4]u8, ready: bool) [32]u8 {
    std.debug.assert(name.len <= 13);
    var data: [32]u8 = @splat(0);
    data[0] = @intCast(18 + name.len);
    data[1..12].* = .{ 2, 1, 6, 12, 0xff, 0xff, 0xff, 'M', 'Z', 'S', 'M' };
    @memcpy(data[12..16], &nonce);
    data[16] = @intFromBool(ready);
    data[17] = @intCast(name.len + 1);
    data[18] = 9;
    @memcpy(data[19..][0..name.len], name);
    return data;
}
pub fn select(address: [6]u8, address_type: u8, event_type: u8, data: []const u8, ready: bool, expected: ?Identity, configured: ?u48) ?Identity {
    // Legacy LE Advertising Report: ADV_NONCONN_IND for election, ADV_IND for initiation.
    const expected_event: u8 = if (ready) 0 else 3;
    if (event_type != expected_event or address_type > 1) return null;
    if (configured) |mac| {
        if (address_type != 0) return null;
        for (address, 0..) |byte, i| if (byte != @as(u8, @truncate(mac >> @as(u6, @intCast(i * 8))))) return null;
    }
    var nonce: ?[4]u8 = null;
    var offset: usize = 0;
    while (offset < data.len) {
        const len = data[offset];
        if (len == 0) break;
        if (len > data.len - offset - 1) return null;
        const field = data[offset + 1 .. offset + 1 + len];
        if (field.len == 12 and std.mem.eql(u8, field[0..7], &.{ 0xff, 0xff, 0xff, 'M', 'Z', 'S', 'M' }) and field[11] == @intFromBool(ready)) {
            nonce = field[7..11].*;
        }
        offset += @as(usize, len) + 1;
    }
    const identity: Identity = .{ .address = address, .address_type = address_type, .nonce = nonce orelse return null };
    if (expected) |old| {
        if (old.address_type != address_type or !std.mem.eql(u8, &old.address, &address) or !std.mem.eql(u8, &old.nonce, &identity.nonce)) return null;
    }
    return identity;
}

test "self-test selection pins address, type, boot nonce and readiness, never a name" {
    const address = [6]u8{ 6, 5, 4, 3, 2, 1 };
    const nonce = [4]u8{ 1, 2, 3, 4 };
    const discovery = advertising_data("MZ-SMP-TEST", nonce, false);
    const ready = advertising_data("MZ-SMP-READY", nonce, true);
    const discovery_payload = discovery[1 .. discovery[0] + 1];
    const identity = select(address, 0, 3, discovery_payload, false, null, null).?;
    try std.testing.expect(select(address, 0, 0, discovery_payload, false, null, null) == null);
    try std.testing.expect(select(address, 0, 4, discovery_payload, false, null, null) == null);
    const payload = ready[1 .. ready[0] + 1];
    try std.testing.expect(select(address, 0, 0, payload, true, identity, 0x010203040506) != null);
    try std.testing.expect(select(address, 0, 0, payload, true, null, null) != null);
    try std.testing.expect(select(address, 1, 0, payload, true, identity, null) == null);
    try std.testing.expect(select(address, 0, 4, payload, true, identity, null) == null);
    try std.testing.expect(select(address, 0, 3, payload, true, identity, null) == null);
    try std.testing.expect(select(address, 0, 3, payload, false, identity, null) == null);
    try std.testing.expect(select(address, 0, 0, discovery_payload, true, identity, null) == null);
    try std.testing.expect(select(address, 0, 0, payload, true, identity, 0x010203040507) == null);
    try std.testing.expect(select(.{ 7, 5, 4, 3, 2, 1 }, 0, 0, payload, true, identity, null) == null);
    const reboot = advertising_data("MZ-SMP-READY", .{ 2, 3, 4, 5 }, true);
    try std.testing.expect(select(address, 0, 0, reboot[1 .. reboot[0] + 1], true, identity, null) == null);
    try std.testing.expect(select(address, 0, 0, &.{ 13, 9, 'M' }, true, null, null) == null);
    try std.testing.expect(select(address, 0, 0, &.{ 3, 9, 'M', 'Z' }, true, null, null) == null);
}

pub fn selftest_declaration(value: []const u8) bool {
    return std.mem.eql(u8, value, &.{ 0x0e, 6, 0, 0xf1, 0xff });
}
test "reject foreign GATT declarations and Generic Attribute service value" {
    try std.testing.expect(selftest_declaration(&.{ 0x0e, 6, 0, 0xf1, 0xff }));
    try std.testing.expect(!selftest_declaration(&.{ 1, 0x18 }));
    try std.testing.expect(!selftest_declaration(&.{ 0x0e, 7, 0, 0xf1, 0xff }));
    try std.testing.expect(!selftest_declaration(&.{}));
}

/// The pairing method a two-board run exercises; both images use the same one.
pub const Method = enum { just_works, numeric_comparison, passkey_peripheral_input, passkey_central_input };
/// Names of `smp.IoCapability` values (this module stays host-testable).
pub const Capability = enum { display_only, display_yes_no, keyboard_only, no_input_output };
/// Core v5.4 Vol 3 Part H §2.3.5.1 Table 2.8 selects the intended method from
/// these pairs once MITM is requested.
pub fn capability(method: Method, central: bool) Capability {
    return switch (method) {
        .just_works => .no_input_output,
        .numeric_comparison => .display_yes_no,
        .passkey_peripheral_input => if (central) .display_only else .keyboard_only,
        .passkey_central_input => if (central) .keyboard_only else .display_only,
    };
}

/// A line the operator typed on USB Serial/JTAG: `yes`, `no` or six digits.
pub const Reply = union(enum) { yes, no, passkey: u32, invalid };
pub fn parse_reply(line: []const u8) Reply {
    if (std.mem.eql(u8, line, "yes")) return .yes;
    if (std.mem.eql(u8, line, "no")) return .no;
    if (line.len != 6) return .invalid;
    var value: u32 = 0;
    for (line) |ch| {
        if (ch < '0' or ch > '9') return .invalid;
        value = value * 10 + (ch - '0');
    }
    return .{ .passkey = value };
}
/// Collects console bytes into lines. CR is dropped; an overlong line is
/// discarded up to its newline.
pub const LineReader = struct {
    bytes: [8]u8 = undefined,
    len: u8 = 0,
    overflow: bool = false,
    pub fn feed(self: *LineReader, byte: u8) ?[]const u8 {
        if (byte == '\r') return null;
        if (byte == '\n') {
            const len = self.len;
            const overflow = self.overflow;
            self.len = 0;
            self.overflow = false;
            return if (overflow) "" else self.bytes[0..len];
        }
        if (self.len == self.bytes.len) {
            self.overflow = true;
        } else {
            self.bytes[self.len] = byte;
            self.len += 1;
        }
        return null;
    }
};
/// The operator's console for one SMP IO request at a time, read without
/// blocking. Bytes read past an answered line stay buffered for the next
/// request; a withdrawn request discards the bytes already received for it.
pub const Console = struct {
    reader: LineReader = .{},
    inbox: [8]u8 = undefined,
    head: u8 = 0,
    len: u8 = 0,
    prompted: bool = false,
    pub const Read = *const fn ([]u8) usize;
    /// True on a request's first poll: print its prompt then.
    pub fn prompt(self: *Console) bool {
        defer self.prompted = true;
        return !self.prompted;
    }
    /// Read once from the console, only when every buffered byte is used.
    pub fn refill(self: *Console, read: Read) void {
        if (self.head != self.len) return;
        self.head = 0;
        self.len = @intCast(read(&self.inbox));
    }
    /// The next complete line in the buffered bytes, valid until the next call.
    pub fn line(self: *Console) ?[]const u8 {
        while (self.head < self.len) {
            const byte = self.inbox[self.head];
            self.head += 1;
            if (self.reader.feed(byte)) |complete| return complete;
        }
        return null;
    }
    /// The request was answered; the next one prompts again.
    pub fn answered(self: *Console) void {
        self.prompted = false;
    }
    /// The request was withdrawn (`smp.IoRequest.cancel`): forget its prompt,
    /// the partial line and buffered bytes, and drain up to 64 bytes the
    /// console already holds. Only bytes already received are discarded; bytes
    /// still in flight or typed after `io cancel` are read by the next request.
    pub fn cancel(self: *Console, read: Read) void {
        self.* = .{};
        var scratch: [8]u8 = undefined;
        for (0..8) |_| if (read(&scratch) == 0) break;
    }
};

test "console keeps bytes after an answer and drops those of a withdrawn request" {
    const Fifo = struct {
        var bytes: []const u8 = "";
        fn read(out: []u8) usize {
            const count = @min(out.len, bytes.len);
            @memcpy(out[0..count], bytes[0..count]);
            bytes = bytes[count..];
            return count;
        }
    };
    var console: Console = .{};
    try std.testing.expect(console.prompt());
    try std.testing.expect(!console.prompt());
    // One read carries the answer and the start of the next one.
    Fifo.bytes = "yes\n1234";
    console.refill(Fifo.read);
    try std.testing.expectEqualStrings("yes", console.line().?);
    console.answered();
    try std.testing.expect(console.prompt());
    try std.testing.expectEqual(@as(?[]const u8, null), console.line());
    Fifo.bytes = "56\n";
    console.refill(Fifo.read);
    try std.testing.expectEqual(Reply{ .passkey = 123456 }, parse_reply(console.line().?));
    console.answered();
    // A request withdrawn while its answer is half typed or still queued.
    try std.testing.expect(console.prompt());
    Fifo.bytes = "no\n123456\n";
    console.refill(Fifo.read);
    console.cancel(Fifo.read);
    try std.testing.expectEqual(@as(usize, 0), Fifo.bytes.len);
    try std.testing.expect(console.prompt());
    console.refill(Fifo.read);
    try std.testing.expectEqual(@as(?[]const u8, null), console.line());
}

test "method capabilities, operator replies and console lines" {
    try std.testing.expectEqual(Capability.display_only, capability(.passkey_peripheral_input, true));
    try std.testing.expectEqual(Capability.keyboard_only, capability(.passkey_peripheral_input, false));
    try std.testing.expectEqual(Capability.keyboard_only, capability(.passkey_central_input, true));
    try std.testing.expectEqual(Capability.display_yes_no, capability(.numeric_comparison, false));
    try std.testing.expectEqual(Reply.yes, parse_reply("yes"));
    try std.testing.expectEqual(Reply.no, parse_reply("no"));
    try std.testing.expectEqual(Reply{ .passkey = 42 }, parse_reply("000042"));
    try std.testing.expectEqual(Reply.invalid, parse_reply("42"));
    try std.testing.expectEqual(Reply.invalid, parse_reply("12a456"));
    var reader: LineReader = .{};
    var line: ?[]const u8 = null;
    for ("yes\r\n") |byte| line = reader.feed(byte) orelse line;
    try std.testing.expectEqualStrings("yes", line.?);
    line = null;
    for ("0123456789\n") |byte| line = reader.feed(byte) orelse line;
    try std.testing.expectEqualStrings("", line.?);
    line = null;
    for ("999999\n") |byte| line = reader.feed(byte) orelse line;
    try std.testing.expectEqual(Reply{ .passkey = 999999 }, parse_reply(line.?));
}
