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

test "endpoint parsing stops at the slice boundary" {
    var ipv4 = "192.0.2.12".*;
    var ipv6 = "2001:DB8::12".*;
    const expected_v4 = try net.Endpoint.parse("192.0.2.1", 80);
    const expected_v6 = try net.Endpoint.parse("2001:DB8::1", 80);
    const actual_v4 = try net.Endpoint.parse(ipv4[0 .. ipv4.len - 1], 80);
    const actual_v6 = try net.Endpoint.parse(ipv6[0 .. ipv6.len - 1], 80);
    try testing.expectEqual(expected_v4.addr.u_addr.ip4.addr, actual_v4.addr.u_addr.ip4.addr);
    try testing.expectEqual(expected_v6.addr.u_addr.ip6.addr, actual_v6.addr.u_addr.ip6.addr);
    try testing.expectError(error.IpAddrParse, net.Endpoint.parse("192.0.2.1\x00suffix", 80));
}

test "fixed IPv4 options parse each bounded slice" {
    const Fixed = net.Interface.Options.Fixed;
    var ip = "192.0.2.12".*;
    var mask = "255.255.255.00".*;
    var gw = "192.0.2.23".*;
    const expected = try Fixed.init("192.0.2.1", "255.255.255.0", "192.0.2.2");
    const actual = try Fixed.init(ip[0 .. ip.len - 1], mask[0 .. mask.len - 1], gw[0 .. gw.len - 1]);
    try testing.expectEqual(expected, actual);
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

test "registering another interface preserves live lwIP allocations" {
    var test_link: TestLink = .{};
    var first: net.Interface = .{ .link = test_link.link() };
    try first.init(test_mac, no_ipv4);
    defer lwip.netif_remove(&first.netif);
    try testing.expectError(error.AlreadyInitialized, first.init(test_mac, no_ipv4));
    const pcb = lwip.udp_new() orelse return error.OutOfMemory;
    const pool = lwip.lwip_stats.memp[lwip.MEMP_UDP_PCB];
    const used = pool.*.used;
    defer lwip.udp_remove(pcb);

    var second: net.Interface = .{ .link = test_link.link() };
    try second.init(test_mac, no_ipv4);
    defer lwip.netif_remove(&second.netif);
    try testing.expectEqual(used, pool.*.used);
}

test "DHCP start failure preserves the default and unregisters the failed interface" {
    var test_link: TestLink = .{};
    var first: net.Interface = .{ .link = test_link.link() };
    try first.init(test_mac, no_ipv4);
    defer lwip.netif_remove(&first.netif);

    var pcbs: [lwip.MEMP_NUM_UDP_PCB]*lwip.udp_pcb = undefined;
    var count: usize = 0;
    defer for (pcbs[0..count]) |pcb| lwip.udp_remove(pcb);
    for (&pcbs) |*pcb| {
        pcb.* = lwip.udp_new() orelse return error.OutOfMemory;
        count += 1;
    }

    var failed: net.Interface = .{ .link = test_link.link() };
    try testing.expectError(error.OutOfMemory, failed.init(test_mac, .{}));
    try testing.expect(lwip.netif_default == &first.netif);
    try testing.expect(lwip.netif_list == &first.netif);
    try testing.expectEqual(null, lwip.netif_dhcp_data(&failed.netif));
    try failed.init(test_mac, no_ipv4);
    defer lwip.netif_remove(&failed.netif);
    try testing.expect(lwip.netif_default == &failed.netif);
}

test "RX driver errors return the allocated pbuf to the pool" {
    try init_stack();
    var test_link: TestLink = .{ .receive = error.TestReceiveFailed };
    var nic: net.Interface = .{ .link = test_link.link() };
    const pool = lwip.lwip_stats.memp[lwip.MEMP_PBUF_POOL];
    const used = pool.*.used;
    for (0..lwip.PBUF_POOL_SIZE + 1) |_| {
        try testing.expectError(error.TestReceiveFailed, nic.poll());
        try testing.expectEqual(used, pool.*.used);
    }
}

fn reject_input(_: [*c]lwip.pbuf, _: [*c]lwip.netif) callconv(.c) lwip.err_t {
    return lwip.ERR_IF;
}

test "RX rejects ranges that extend past the pbuf" {
    try init_stack();
    var test_link: TestLink = .{};
    var nic: net.Interface = .{ .link = test_link.link() };
    nic.netif.input = reject_input;
    const pool = lwip.lwip_stats.memp[lwip.MEMP_PBUF_POOL];
    const used = pool.*.used;

    test_link.receive = .{ .head = lwip.PBUF_POOL_BUFSIZE, .len = 1, .link_state = .down };
    try testing.expectError(error.InvalidPbufLength, nic.poll());
    try testing.expectEqual(used, pool.*.used);
    test_link.receive = .{ .head = lwip.PBUF_POOL_BUFSIZE + 1, .len = 1, .link_state = .down };
    try testing.expectError(error.InvalidPbufHead, nic.poll());
    try testing.expectEqual(used, pool.*.used);
}

fn fill_pattern(pbuf: *lwip.pbuf, start: u8) void {
    const bytes = @as([*]u8, @ptrCast(pbuf.payload.?))[0..pbuf.len];
    for (bytes, 0..) |*b, i| b.* = start +% @as(u8, @truncate(i));
}

fn expect_sent_frame(test_link: *const TestLink, frame: *lwip.pbuf, copied: bool) !void {
    var expected: [lwip.PBUF_POOL_BUFSIZE]u8 = undefined;
    const len = lwip.pbuf_copy_partial(frame, &expected, frame.tot_len, 0);
    try testing.expectEqual(@as(usize, headroom) + len, test_link.last_len);
    try testing.expectEqualSlices(u8, expected[0..len], test_link.last[headroom..test_link.last_len]);
    // The link driver's transfer needs a word-aligned copy.
    if (copied) try testing.expect(test_link.last_aligned);
}

const PbufView = struct { payload: ?*anyopaque, len: u16, tot_len: u16 };

fn view(pbuf: *const lwip.pbuf) PbufView {
    return .{ .payload = pbuf.payload, .len = pbuf.len, .tot_len = pbuf.tot_len };
}

test "TX returns the caller's pbuf unchanged" {
    try init_stack();
    var test_link: TestLink = .{};
    var nic: net.Interface = .{ .link = test_link.link() };
    try nic.init(test_mac, no_ipv4);
    defer lwip.netif_remove(&nic.netif);
    const linkoutput = nic.netif.linkoutput.?;
    const pool = lwip.lwip_stats.memp[lwip.MEMP_PBUF_POOL];
    const used = pool.*.used;

    // A single pbuf with headroom is sent in place.
    const roomy: *lwip.pbuf = lwip.pbuf_alloc(lwip.PBUF_RAW_TX, 60, lwip.PBUF_RAM) orelse return error.OutOfMemory;
    defer _ = lwip.pbuf_free(roomy);
    fill_pattern(roomy, 1);
    const roomy_before = view(roomy);
    try testing.expectEqual(lwip.ERR_OK, linkoutput(&nic.netif, roomy));
    try testing.expectEqual(roomy_before, view(roomy));
    try expect_sent_frame(&test_link, roomy, false);

    // A pbuf without headroom is copied.
    const tight: *lwip.pbuf = lwip.pbuf_alloc(lwip.PBUF_RAW, 60, lwip.PBUF_RAM) orelse return error.OutOfMemory;
    defer _ = lwip.pbuf_free(tight);
    fill_pattern(tight, 2);
    const tight_before = view(tight);
    try testing.expectEqual(lwip.ERR_OK, linkoutput(&nic.netif, tight));
    try testing.expectEqual(tight_before, view(tight));
    try expect_sent_frame(&test_link, tight, true);
    try testing.expectEqual(used, pool.*.used);

    // A chain is copied, and neither segment changes.
    const head: *lwip.pbuf = lwip.pbuf_alloc(lwip.PBUF_RAW_TX, 20, lwip.PBUF_RAM) orelse return error.OutOfMemory;
    const tail: *lwip.pbuf = lwip.pbuf_alloc(lwip.PBUF_RAW, 40, lwip.PBUF_RAM) orelse {
        _ = lwip.pbuf_free(head);
        return error.OutOfMemory;
    };
    lwip.pbuf_cat(head, tail);
    defer _ = lwip.pbuf_free(head);
    fill_pattern(head, 3);
    fill_pattern(tail, 4);
    const head_before = view(head);
    const tail_before = view(tail);
    try testing.expectEqual(lwip.ERR_OK, linkoutput(&nic.netif, head));
    try testing.expectEqual(head_before, view(head));
    try testing.expectEqual(tail_before, view(tail));
    try expect_sent_frame(&test_link, head, true);
    try testing.expectEqual(used, pool.*.used);

    // Copy allocation failure also leaves the chain unchanged.
    var held: [lwip.PBUF_POOL_SIZE]*lwip.pbuf = undefined;
    var count: usize = 0;
    defer for (held[0..count]) |pbuf| {
        _ = lwip.pbuf_free(pbuf);
    };
    while (count < held.len) : (count += 1) {
        held[count] = lwip.pbuf_alloc(lwip.PBUF_RAW, 1, lwip.PBUF_POOL) orelse break;
    }
    try testing.expectEqual(lwip.ERR_MEM, linkoutput(&nic.netif, head));
    try testing.expectEqual(head_before, view(head));
    try testing.expectEqual(tail_before, view(tail));
}

test "ready reports a routable IPv6 address without IPv4" {
    var nic: net.Interface = .{ .link = undefined };
    nic.netif.flags = lwip.NETIF_FLAG_UP | lwip.NETIF_FLAG_LINK_UP;
    try testing.expect(!nic.ready());

    // Link-local scope alone is not enough to reach a configured host.
    nic.netif.ip6_addr[0] = (try net.Endpoint.parse("fe80::1", 0)).addr;
    nic.netif.ip6_addr_state[0] = lwip.IP6_ADDR_PREFERRED;
    try testing.expect(!nic.ready());

    // A global address counts once duplicate detection has finished.
    nic.netif.ip6_addr[1] = (try net.Endpoint.parse("2001:DB8::2", 0)).addr;
    nic.netif.ip6_addr_state[1] = lwip.IP6_ADDR_TENTATIVE;
    try testing.expect(!nic.ready());
    nic.netif.ip6_addr_state[1] = lwip.IP6_ADDR_PREFERRED;
    try testing.expect(nic.ready());
    nic.netif.ip6_addr_state[1] = lwip.IP6_ADDR_DEPRECATED;
    try testing.expect(nic.ready());

    nic.netif.flags = lwip.NETIF_FLAG_UP;
    try testing.expect(!nic.ready());
}

/// One interface whose link delivers every sent frame back to it, so TCP
/// connections to its own address run through the whole stack.
const Loopback = struct {
    test_link: TestLink = .{ .loopback = true },
    nic: net.Interface = undefined,
    server: net.tcp.Server = undefined,

    /// `self` must stay at this address until `stop`.
    fn start(self: *Loopback, port: u16) !void {
        try init_stack();
        self.nic = .{ .link = self.test_link.link() };
        try self.nic.init(test_mac, .{ .fixed = try .init("192.0.2.1", "255.255.255.0", "192.0.2.254") });
        errdefer lwip.netif_remove(&self.nic.netif);
        self.server = .{ .nic = &self.nic, .on_accept = accept_next };
        try self.server.bind(port);
        // The first receive reports the link up.
        try self.pump();
    }

    fn stop(self: *Loopback) void {
        _ = lwip.tcp_close(self.server.pcb);
        lwip.netif_remove(&self.nic.netif);
        next_accept = null;
    }

    /// Deliver frames until the link is idle.
    fn pump(self: *Loopback) !void {
        for (0..64) |_| {
            try self.nic.poll();
            if (self.test_link.count == 0) return;
        }
        return error.LinkNeverIdle;
    }

    fn connect(self: *Loopback, peer: *Peer, port: u16) !void {
        var target = try net.Endpoint.parse("192.0.2.1", port);
        try net.tcp.connect(&self.nic, &peer.conn, &target);
    }
};

var next_accept: ?*net.tcp.Connection = null;

fn accept_next() ?*net.tcp.Connection {
    defer next_accept = null;
    return next_accept;
}

/// A connection that records what its callbacks see.
const Peer = struct {
    conn: net.tcp.Connection = .{
        .on_recv = on_recv,
        .on_close = on_close,
        .on_sent = on_sent,
    },
    received: [256]u8 = undefined,
    received_len: usize = 0,
    close_errors: [4]net.Error = undefined,
    close_count: usize = 0,
    sent: usize = 0,
    /// Sent and followed by `close` from inside `on_recv`.
    reply: ?[]const u8 = null,

    fn data(self: *const Peer) []const u8 {
        return self.received[0..self.received_len];
    }

    fn on_recv(conn: *net.tcp.Connection, bytes: []u8) void {
        const self: *Peer = @fieldParentPtr("conn", conn);
        @memcpy(self.received[self.received_len..][0..bytes.len], bytes);
        self.received_len += bytes.len;
        if (self.reply) |reply| {
            conn.send(reply) catch @panic("reply send failed");
            conn.close() catch @panic("close failed");
        }
    }

    fn on_close(conn: *net.tcp.Connection, err: net.Error) void {
        const self: *Peer = @fieldParentPtr("conn", conn);
        self.close_errors[self.close_count] = err;
        self.close_count += 1;
    }

    fn on_sent(conn: *net.tcp.Connection, n: u16) void {
        const self: *Peer = @fieldParentPtr("conn", conn);
        self.sent += n;
    }
};

test "close stops callbacks from the closing PCB" {
    var loop: Loopback = .{};
    try loop.start(9200);
    defer loop.stop();

    var server: Peer = .{};
    var client: Peer = .{};
    next_accept = &server.conn;
    try loop.connect(&client, 9200);
    try loop.pump();
    try testing.expectEqual(.open, client.conn.state);

    // The peer acknowledges these bytes after close returns.
    try client.conn.send("bye");
    try client.conn.close();
    try loop.pump();
    try testing.expectEqualStrings("bye", server.data());
    try testing.expectEqual(0, client.sent);
    try testing.expectEqual(0, client.close_count);
}

test "a closed connection can reconnect while its old PCB is closing" {
    var loop: Loopback = .{};
    try loop.start(9300);
    defer loop.stop();

    var server: Peer = .{};
    var client: Peer = .{};
    next_accept = &server.conn;
    try loop.connect(&client, 9300);
    try loop.pump();
    try testing.expectEqual(.open, client.conn.state);

    try client.conn.close();
    var second: Peer = .{};
    next_accept = &second.conn;
    try loop.connect(&client, 9300);
    // The reset reaches the old client PCB, which is still in FIN_WAIT_1.
    lwip.tcp_abort(server.conn.pcb.?);
    try loop.pump();
    try testing.expectEqual(.open, client.conn.state);
    try testing.expect(client.conn.pcb != null);
    try testing.expectEqual(0, client.close_count);
    try testing.expectEqual(.open, second.conn.state);
    try client.conn.close();
    try second.conn.close();
    try loop.pump();
}
