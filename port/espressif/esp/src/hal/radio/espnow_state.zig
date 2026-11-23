//! Allocation-free ESP-NOW values and callback handoff. External synchronization required.
const std = @import("std");
pub const Mac = [6]u8;
pub const Key = [16]u8;
pub const broadcast: Mac = @splat(0xff);
pub const capacity = 8;
pub const max_payload = 1470;
pub const Error = error{ NotInitialized, AlreadyInitialized, InvalidArgument, OutOfMemory, PeerTableFull, PeerNotFound, Internal, PeerExists, InterfaceMismatch, ChannelMismatch, UnsupportedRadioProtocol, WifiNotStarted, UnsupportedVersion, Busy };
pub const Interface = enum { sta, ap };
pub const Peer = struct {
    address: Mac,
    channel: u8 = 0,
    interface: Interface = .sta,
    /// Null disables encryption; broadcast encryption is unsupported.
    lmk: ?Key = null,

    pub fn validate(self: Peer) Error!void {
        if (self.channel > 14 or std.mem.allEqual(u8, &self.address, 0)) return error.InvalidArgument;
        if (self.address[0] & 1 != 0 and !std.mem.eql(u8, &self.address, &broadcast)) return error.InvalidArgument;
        if (self.lmk != null and std.mem.eql(u8, &self.address, &broadcast)) return error.InvalidArgument;
    }
};
pub const Frame = struct {
    source: Mac,
    destination: Mac,
    rssi: ?i8,
    len: usize,
    data: [max_payload]u8,
    pub fn payload(self: *const Frame) []const u8 {
        return self.data[0..self.len];
    }
};
pub const Delivery = enum { success, failure };
pub const State = struct {
    frames: [capacity]Frame = undefined,
    head: usize = 0,
    len: usize = 0,
    dropped: u32 = 0,
    pending: bool = false,
    completion: ?Delivery = null,

    pub fn receive(self: *State, source: Mac, destination: Mac, rssi: ?i8, data: []const u8) void {
        if (self.len == capacity or data.len > max_payload) {
            self.dropped +|= 1;
            return;
        }
        const frame = &self.frames[(self.head + self.len) % capacity];
        frame.source = source;
        frame.destination = destination;
        frame.rssi = rssi;
        frame.len = data.len;
        @memcpy(frame.data[0..data.len], data);
        self.len += 1;
    }
    pub fn pop(self: *State, out: *Frame) bool {
        if (self.len == 0) return false;
        out.* = self.frames[self.head];
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        return true;
    }
    pub fn begin_send(self: *State, len: usize, limit: usize) Error!void {
        if (len == 0 or len > limit) return error.InvalidArgument;
        if (self.pending) return error.Busy;
        self.pending = true;
    }
    pub fn take_delivery(self: *State) ?Delivery {
        const result = self.completion orelse return null;
        self.completion = null;
        self.pending = false;
        return result;
    }
};

// ESP-IDF v5.5.1 esp_err.h / esp_now.h: ESP_ERR_WIFI_BASE + 100.
pub fn check(code: i32) Error!void {
    return switch (code) {
        0 => {},
        0x3065 => error.NotInitialized,
        0x3066, 0x102 => error.InvalidArgument,
        0x3067, 0x101 => error.OutOfMemory,
        0x3068 => error.PeerTableFull,
        0x3069 => error.PeerNotFound,
        0x306b => error.PeerExists,
        0x306c => error.InterfaceMismatch,
        0x306d => error.ChannelMismatch,
        else => error.Internal,
    };
}
pub fn payload_limit(version: u32) Error!usize {
    return switch (version) {
        1 => 250,
        2 => max_payload,
        else => error.UnsupportedVersion,
    };
}

test "receive FIFO wraps, copies callback memory, drops newest and counts overflow" {
    var state: State = .{};
    var bytes = [_]u8{42};
    for (0..capacity) |i| {
        bytes[0] = @intCast(i);
        state.receive(broadcast, broadcast, -60, &bytes);
    }
    state.receive(broadcast, broadcast, null, &bytes);
    try std.testing.expectEqual(@as(u32, 1), state.dropped);
    var frame: Frame = undefined;
    for (0..capacity) |i| {
        try std.testing.expect(state.pop(&frame));
        try std.testing.expectEqual(@as(u8, @intCast(i)), frame.payload()[0]);
        try std.testing.expectEqual(@as(?i8, -60), frame.rssi);
        state.receive(broadcast, broadcast, null, "x");
    }
    for (0..capacity) |_| {
        try std.testing.expect(state.pop(&frame));
        try std.testing.expectEqualStrings("x", frame.payload());
    }
    try std.testing.expect(!state.pop(&frame));
    const large: [max_payload + 1]u8 = @splat(0);
    state.receive(broadcast, broadcast, null, &large);
    try std.testing.expectEqual(@as(u32, 2), state.dropped);
}
test "completion is retained independently of a full receive queue" {
    var state: State = .{};
    try state.begin_send(250, 250);
    try std.testing.expectError(error.Busy, state.begin_send(1, 250));
    state.completion = .failure;
    try std.testing.expectError(error.Busy, state.begin_send(1, 250));
    try std.testing.expectEqual(Delivery.failure, state.take_delivery().?);
    try std.testing.expect(state.take_delivery() == null);
    try std.testing.expectError(error.InvalidArgument, state.begin_send(251, 250));
    try std.testing.expectError(error.InvalidArgument, state.begin_send(0, 250));
    try state.begin_send(max_payload, try payload_limit(2));
    state.completion = .success;
    try std.testing.expectEqual(Delivery.success, state.take_delivery().?);
}
test "peer validation, key lengths, and version limits" {
    try (Peer{ .address = broadcast }).validate();
    try (Peer{ .address = .{ 2, 0, 0, 0, 0, 1 }, .channel = 14, .interface = .ap, .lmk = @splat(1) }).validate();
    try std.testing.expectError(error.InvalidArgument, (Peer{ .address = broadcast, .lmk = @splat(1) }).validate());
    try std.testing.expectError(error.InvalidArgument, (Peer{ .address = broadcast, .channel = 15 }).validate());
    try std.testing.expectError(error.InvalidArgument, (Peer{ .address = @splat(0) }).validate());
    try std.testing.expectError(error.InvalidArgument, (Peer{ .address = .{ 1, 0, 0, 0, 0, 1 } }).validate());
    try std.testing.expectEqual(@as(usize, 250), try payload_limit(1));
    try std.testing.expectEqual(@as(usize, 1470), try payload_limit(2));
    try std.testing.expectError(error.UnsupportedVersion, payload_limit(3));
}
test "all vendor errors and unknown errors are mapped" {
    try check(0);
    const errors = [_]Error{ error.NotInitialized, error.InvalidArgument, error.OutOfMemory, error.PeerTableFull, error.PeerNotFound, error.Internal, error.PeerExists, error.InterfaceMismatch, error.ChannelMismatch };
    for (errors, 0..) |err, i| try std.testing.expectError(err, check(@as(i32, @intCast(i)) + 0x3065));
    try std.testing.expectError(error.Internal, check(-1));
}
