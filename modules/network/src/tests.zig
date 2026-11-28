const std = @import("std");
const net = @import("net");
const lwip = net.lwip;
const testing = std.testing;

/// Milliseconds reported to lwIP; tests advance it to run lwIP timers.
var now_ms: u32 = 0;

export fn lwip_sys_now() u32 {
    return now_ms;
}

export fn lwip_rand() u32 {
    return 0x12345678;
}

test "TCP send limits match the compiled lwIP configuration" {
    try init_stack();
    const pcb: *lwip.tcp_pcb = lwip.tcp_new() orelse return error.OutOfMemory;
    defer _ = lwip.tcp_close(pcb);
    var conn: net.tcp.Connection = .{};
    try testing.expectEqual(@as(u16, 1440), lwip.TCP_MSS);
    try testing.expectEqual(pcb.snd_buf, conn.send_buffer());
}

fn recv_udp(_: *net.Udp, _: []u8, _: net.Udp.RecvOptions) void {}

test "UDP bind can retry after a port collision" {
    try init_stack();
    var nic: net.Interface = .{ .link = undefined };
    var first = try net.Udp.init(&nic);
    defer lwip.udp_remove(first.pcb);
    var second = try net.Udp.init(&nic);
    defer lwip.udp_remove(second.pcb);

    try first.bind(8000, recv_udp);
    try testing.expectEqual(null, second.on_recv);
    try testing.expectError(error.AddressInUse, second.bind(8000, recv_udp));
    try testing.expectEqual(null, second.on_recv);
    try second.bind(8001, recv_udp);
    try testing.expect(second.on_recv != null);
}

var stack_initialized = false;

fn init_stack() !void {
    if (!stack_initialized) {
        var test_link: TestLink = .{};
        var nic: net.Interface = .{ .link = test_link.link() };
        try nic.init(test_mac, no_ipv4);
        lwip.netif_remove(&nic.netif);
        stack_initialized = true;
    }
}

fn reject_tcp() ?*net.tcp.Connection {
    return null;
}

test "TCP bind releases its PCB when the listener pool is exhausted" {
    try init_stack();
    var nic: net.Interface = .{ .link = undefined };
    var listeners: [lwip.MEMP_NUM_TCP_PCB_LISTEN]net.tcp.Server = undefined;
    var count: usize = 0;
    defer for (listeners[0..count]) |listener| {
        _ = lwip.tcp_close(listener.pcb);
    };
    for (&listeners, 8100..) |*listener, port| {
        listener.* = .{ .nic = &nic, .on_accept = reject_tcp };
        try listener.bind(@intCast(port));
        count += 1;
    }

    var retry: net.tcp.Server = .{ .nic = &nic, .on_accept = reject_tcp };
    defer if (retry.pcb) |pcb| {
        _ = lwip.tcp_close(pcb);
    };
    const port = 8100 + listeners.len;
    const pcb_pool = lwip.lwip_stats.memp[lwip.MEMP_TCP_PCB];
    const used = pcb_pool.*.used;
    try testing.expectError(error.OutOfMemory, retry.bind(port));
    try testing.expectEqual(null, retry.pcb);
    try testing.expectEqual(used, pcb_pool.*.used);

    count -= 1;
    _ = lwip.tcp_close(listeners[count].pcb);
    try retry.bind(port);
    try testing.expect(retry.pcb != null);
}

test "endpoint formatting uses the address family" {
    var buf: [64]u8 = undefined;
    const ipv4 = try net.Endpoint.parse("192.0.2.1", 80);
    const ipv6 = try net.Endpoint.parse("2001:DB8::1", 443);
    try testing.expectEqualStrings("192.0.2.1:80", try std.fmt.bufPrint(&buf, "{f}", .{ipv4}));
    try testing.expectEqualStrings("[2001:DB8::1]:443", try std.fmt.bufPrint(&buf, "{f}", .{ipv6}));
}

const Link = @FieldType(net.Interface, "link");

/// Records each frame passed to `send`. With `loopback` set, `recv` returns
/// the recorded frames in order, so the interface receives what it sent.
const TestLink = struct {
    receive: anyerror!Link.RecvResponse = .{ .link_state = .down },
    send_error: ?Link.Error = null,
    loopback: bool = false,
    frames: [16][lwip.PBUF_POOL_BUFSIZE]u8 = undefined,
    lens: [16]usize = undefined,
    first: usize = 0,
    count: usize = 0,
    /// Copy of the last buffer passed to `send`, which borrows it only until return.
    last: [lwip.PBUF_POOL_BUFSIZE]u8 = undefined,
    last_len: usize = 0,
    last_aligned: bool = false,

    fn link(self: *TestLink) Link {
        return .{ .ptr = self, .vtable = .{ .send = send, .recv = recv } };
    }

    fn send(context: *anyopaque, buffer: []u8) Link.Error!void {
        const self: *TestLink = @ptrCast(@alignCast(context));
        @memcpy(self.last[0..buffer.len], buffer);
        self.last_len = buffer.len;
        self.last_aligned = std.mem.isAligned(@intFromPtr(buffer.ptr), 4);
        if (self.send_error) |err| return err;
        if (self.count == self.frames.len) return error.OutOfMemory;
        const slot = (self.first + self.count) % self.frames.len;
        @memcpy(self.frames[slot][0..buffer.len], buffer);
        self.lens[slot] = buffer.len;
        self.count += 1;
    }

    fn recv(context: *anyopaque, buffer: []u8) anyerror!Link.RecvResponse {
        const self: *TestLink = @ptrCast(@alignCast(context));
        if (!self.loopback) return self.receive;
        if (self.count == 0) return .{};
        const frame = self.frames[self.first][headroom..self.lens[self.first]];
        self.first = (self.first + 1) % self.frames.len;
        self.count -= 1;
        @memcpy(buffer[0..frame.len], frame);
        return .{ .len = frame.len, .next_packet_available = self.count > 0 };
    }
};

const headroom = lwip.PBUF_LINK_ENCAPSULATION_HLEN;

const no_ipv4: net.Interface.Options = .{ .fixed = .{ .ip = .{}, .netmask = .{}, .gw = .{} } };
const test_mac = [6]u8{ 0x02, 0, 0, 0, 0, 1 };
