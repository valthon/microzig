//! DHCPv4 server for an access point (RFC 2131, options from RFC 2132).
//!
//! The server parses one request datagram and builds the reply; the caller owns the UDP
//! socket and the clock. Ethernet clients on the local link only: no relay agents, option
//! overload, DHCPINFORM, client-identifier keyed leases or persistent leases.
const std = @import("std");

/// UDP port the server receives on.
pub const server_port = 67;
/// UDP port replies are sent to.
pub const client_port = 68;
/// Every reply is this long: the fixed BOOTP header, the options and zero padding up to the
/// BOOTP minimum message size (RFC 1542 §2.1).
pub const reply_len = 300;

const cookie = [4]u8{ 99, 130, 83, 99 };
const header_len = 236;
const options_start = header_len + cookie.len;

const Option = struct {
    const pad = 0;
    const subnet_mask = 1;
    const router = 3;
    const dns = 6;
    const requested_address = 50;
    const lease_time = 51;
    const overload = 52;
    const message_type = 53;
    const server_id = 54;
    const end = 255;
};

const MessageType = struct {
    const discover = 1;
    const offer = 2;
    const request = 3;
    const decline = 4;
    const ack = 5;
    const nak = 6;
    const release = 7;
};

pub const Config = struct {
    /// The server's own address on the access point interface.
    server: [4]u8 = .{ 192, 168, 4, 1 },
    netmask: [4]u8 = .{ 255, 255, 255, 0 },
    /// First address handed out; the pool is `lease_count` consecutive addresses from here.
    pool_start: [4]u8 = .{ 192, 168, 4, 2 },
    /// A lease ends only by its holder's own message or by expiry; a station that leaves without
    /// RELEASE keeps its address for up to `lease_ms`, and DECLINE takes an address out for as
    /// long. Size the pool above the number of stations the access point admits.
    lease_count: u8 = 4,
    lease_ms: u32 = 3600 * std.time.ms_per_s,
    /// How long an offer reserves its address for a client that has not yet requested it.
    offer_ms: u32 = 30 * std.time.ms_per_s,
    /// Advertise the server as the router (option 3).
    advertise_router: bool = true,
    /// DNS server to advertise (option 6), if any.
    dns: ?[4]u8 = null,
};

pub const Reply = struct {
    bytes: [reply_len]u8,
    /// Send `bytes` here, to `client_port`.
    destination: [4]u8,
    /// The address just acknowledged, for logging; null for an offer or a NAK.
    leased_ip: ?[4]u8,
    mac: [6]u8,
};

const Lease = struct {
    /// The holder; a free entry remembers its last holder, so that client gets its old
    /// address back. All zero for a quarantined or never used entry.
    mac: [6]u8 = @splat(0),
    /// When the offer or lease was made; it expires `duration` later.
    since: u32 = 0,
    /// Zero marks a free entry.
    duration: u32 = 0,
    /// Acknowledged, as opposed to only offered or declined.
    bound: bool = false,
    /// When the entry was last freed, in `Server.frees` order; zero if never held.
    freed: u32 = 0,
};

fn to_int(address: [4]u8) u32 {
    return std.mem.readInt(u32, &address, .big);
}

fn from_int(value: u32) [4]u8 {
    var address: [4]u8 = undefined;
    std.mem.writeInt(u32, &address, value, .big);
    return address;
}

pub fn Server(comptime config: Config) type {
    const mask = to_int(config.netmask);
    const network = to_int(config.server) & mask;
    const broadcast = network | ~mask;
    const first = to_int(config.pool_start);
    comptime {
        if (mask == 0 or ~mask == 0 or ~mask & (~mask +% 1) != 0)
            @compileError("netmask must be a contiguous prefix shorter than 32 bits");
        if (config.lease_count == 0) @compileError("lease_count must be at least 1");
        const server = to_int(config.server);
        if (server == network or server == broadcast)
            @compileError("server must be a host address of its subnet");
        if (first & mask != network or first == network or first == broadcast or
            config.lease_count - 1 > broadcast - 1 - first)
            @compileError("pool must lie between the network and broadcast addresses of the server's subnet");
        if (server >= first and server - first < config.lease_count)
            @compileError("pool must not contain the server address");
        const half_range = std.math.maxInt(u32) / 2;
        if (config.offer_ms == 0 or config.offer_ms > config.lease_ms or config.lease_ms > half_range)
            @compileError("need 0 < offer_ms <= lease_ms < 2^31 for the wrapping clock");
        if (config.lease_ms < std.time.ms_per_s)
            @compileError("lease_ms must be at least one second, the unit of option 51");
    }

    return struct {
        const Self = @This();

        const lease_count = config.lease_count;
        pub const server_ip = config.server;
        pub const netmask = config.netmask;

        leases: [lease_count]Lease = @splat(.{}),
        /// Counts frees, to hand out the address freed earliest first.
        frees: u32 = 0,

        fn vacate(self: *Self, lease: *Lease) void {
            self.frees +%= 1; // wraps after 2^32 frees, only misordering picks
            lease.duration = 0;
            lease.bound = false;
            lease.freed = self.frees;
        }

        /// The address of pool entry `index`.
        pub fn address(index: usize) [4]u8 {
            return from_int(first + @as(u32, @intCast(index)));
        }

        fn pool_index(ip: [4]u8) ?usize {
            const value = to_int(ip);
            if (value < first or value - first >= lease_count) return null;
            return value - first;
        }

        /// Handle one datagram received on `server_port`. `now` is a wrapping millisecond
        /// clock. Returns the reply to send, or null when the datagram needs none.
        pub fn receive(self: *Self, packet: []const u8, now: u32) ?Reply {
            // BOOTREQUEST, Ethernet, six-byte hardware address, no relay agent, DHCP cookie.
            if (packet.len < options_start or packet[0] != 1 or packet[1] != 1 or packet[2] != 6 or
                !std.mem.allEqual(u8, packet[24..28], 0) or
                !std.mem.eql(u8, packet[header_len..options_start], &cookie)) return null;
            const mac: [6]u8 = packet[28..34].*;
            if (mac[0] & 1 != 0 or std.mem.allEqual(u8, &mac, 0)) return null;

            var kind: ?u8 = null;
            var requested: ?[4]u8 = null;
            var server_id: ?[4]u8 = null;
            var pos: usize = options_start;
            while (pos < packet.len) {
                const code = packet[pos];
                pos += 1;
                if (code == Option.end) break;
                if (code == Option.pad) continue;
                if (pos == packet.len) return null;
                const len = packet[pos];
                pos += 1;
                if (len > packet.len - pos) return null;
                const value = packet[pos..][0..len];
                switch (code) {
                    Option.message_type => {
                        if (len != 1 or kind != null) return null;
                        kind = value[0];
                    },
                    Option.requested_address => {
                        if (len != 4 or requested != null) return null;
                        requested = value[0..4].*;
                    },
                    Option.server_id => {
                        if (len != 4 or server_id != null) return null;
                        server_id = value[0..4].*;
                    },
                    Option.overload => return null,
                    else => {},
                }
                pos += len;
            }
            const message = kind orelse return null;

            var own: ?usize = null;
            var previous: ?usize = null;
            var oldest: ?usize = null;
            for (&self.leases, 0..) |*lease, i| {
                // An expired quarantine has no holder to remember and, like any freed entry,
                // goes to the back of the reuse order.
                if (lease.duration != 0 and now -% lease.since >= lease.duration) self.vacate(lease);
                const same = std.mem.eql(u8, &lease.mac, &mac);
                if (lease.duration != 0) {
                    if (same) own = i;
                } else if (same) {
                    previous = i;
                } else if (oldest == null or lease.freed < self.leases[oldest.?].freed) {
                    oldest = i;
                }
            }
            if (server_id) |id| if (!std.mem.eql(u8, &id, &config.server)) {
                // The client chose another server: drop an offer we made it (RFC 2131 §4.3.2).
                if (message == MessageType.request) if (own) |i| if (!self.leases[i].bound) {
                    self.vacate(&self.leases[i]);
                };
                return null;
            };

            const ciaddr: [4]u8 = packet[12..16].*;
            const wanted = requested orelse ciaddr;
            var index: usize = undefined;
            var response: u8 = undefined;
            switch (message) {
                MessageType.discover => {
                    // Keep an existing lease; otherwise reserve a free address briefly: the
                    // client's previous one, else the one freed earliest (never held first).
                    index = own orelse previous orelse oldest orelse return null;
                    if (!self.leases[index].bound)
                        self.leases[index] = .{ .mac = mac, .since = now, .duration = config.offer_ms };
                    response = MessageType.offer;
                },
                MessageType.request => {
                    // SELECTING and INIT-REBOOT carry option 50; RENEWING and REBINDING carry
                    // ciaddr instead (RFC 2131 §4.3.2).
                    if (std.mem.allEqual(u8, &wanted, 0)) return null;
                    const candidate = pool_index(wanted);
                    if (candidate != null and (self.leases[candidate.?].duration == 0 or own == candidate)) {
                        index = candidate.?;
                        // A MAC holds at most one address, even after INIT-REBOOT.
                        if (own) |old| if (old != index) {
                            self.vacate(&self.leases[old]);
                        };
                        self.leases[index] = .{ .mac = mac, .since = now, .duration = config.lease_ms, .bound = true };
                        response = MessageType.ack;
                    } else response = MessageType.nak;
                },
                MessageType.decline, MessageType.release => {
                    // DECLINE quarantines the address for a lease time; RELEASE frees it.
                    const i = own orelse return null;
                    if (!std.mem.eql(u8, &wanted, &address(i))) return null;
                    if (message == MessageType.decline) {
                        self.leases[i] = .{ .since = now, .duration = config.lease_ms };
                    } else self.vacate(&self.leases[i]);
                    return null;
                },
                else => return null,
            }

            var reply: Reply = .{
                .bytes = @splat(0),
                // Unicast only to an address the client has configured (RFC 2131 §4.1); the
                // chaddr unicast §4.1 also allows needs an ARP entry the caller cannot add.
                .destination = if (response == MessageType.ack and std.mem.eql(u8, &ciaddr, &address(index)))
                    ciaddr
                else
                    @splat(255),
                .leased_ip = if (response == MessageType.ack) address(index) else null,
                .mac = mac,
            };
            const out = &reply.bytes;
            out[0..3].* = .{ 2, 1, 6 }; // BOOTREPLY, Ethernet, hlen
            out[4..8].* = packet[4..8].*; // xid
            out[10..12].* = packet[10..12].*; // flags
            if (response == MessageType.ack) out[12..16].* = ciaddr;
            if (response != MessageType.nak) {
                out[16..20].* = address(index);
                out[20..24].* = config.server;
            }
            out[28..44].* = packet[28..44].*;
            out[header_len..options_start].* = cookie;

            var w: std.Io.Writer = .fixed(out[options_start..]);
            // A NAK carries no lease options (RFC 2131 §4.3.1, table 3).
            put(&w, Option.message_type, &.{response});
            put(&w, Option.server_id, &config.server);
            if (response != MessageType.nak) {
                var seconds: [4]u8 = undefined;
                std.mem.writeInt(u32, &seconds, config.lease_ms / std.time.ms_per_s, .big);
                put(&w, Option.lease_time, &seconds);
                put(&w, Option.subnet_mask, &config.netmask);
                if (config.advertise_router) put(&w, Option.router, &config.server);
                if (config.dns) |dns| put(&w, Option.dns, &dns);
            }
            w.writeByte(Option.end) catch unreachable;
            return reply;
        }

        fn put(w: *std.Io.Writer, code: u8, value: []const u8) void {
            // At most 34 option bytes follow the cookie, well inside the reply.
            w.writeAll(&.{ code, @intCast(value.len) }) catch unreachable;
            w.writeAll(value) catch unreachable;
        }
    };
}

const testing = std.testing;
const Default = Server(.{});

fn request(mac: u8, kind: u8, ip: u8) [256]u8 {
    var packet: [256]u8 = @splat(0);
    packet[0..3].* = .{ 1, 1, 6 };
    packet[28..34].* = .{ 2, 0, 0, 0, 0, mac };
    packet[header_len..options_start].* = cookie;
    packet[options_start..][0..10].* = .{ 53, 1, kind, 50, 4, 192, 168, 4, ip, 255 };
    return packet;
}

fn message_type(reply: Reply) u8 {
    return reply.bytes[options_start + 2];
}

test "DHCP allocation, renewal, collision, release, exhaustion and expiry" {
    var server: Default = .{};
    var discover = request(1, 1, 0);
    const offer = server.receive(&discover, 0).?;
    try testing.expectEqual(MessageType.offer, message_type(offer));
    try testing.expectEqualSlices(u8, &.{ 192, 168, 4, 2 }, offer.bytes[16..20]);
    var req = request(1, 3, 2);
    const ack = server.receive(&req, 1).?;
    try testing.expectEqual(MessageType.ack, message_type(ack));
    try testing.expectEqualSlices(u8, &Default.address(0), &ack.leased_ip.?);
    var other = request(2, 3, 2);
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&other, 2).?));
    req[12..16].* = Default.address(0);
    req[options_start + 3] = 255; // renewal has ciaddr and no requested-address option
    const renewed = server.receive(&req, 100).?;
    try testing.expectEqual(MessageType.ack, message_type(renewed));
    try testing.expectEqualSlices(u8, &Default.address(0), &renewed.destination);
    for (2..5) |n| {
        discover = request(@intCast(n), 1, 0);
        try testing.expect(server.receive(&discover, 101) != null);
    }
    discover = request(5, 1, 0);
    try testing.expect(server.receive(&discover, 102) == null);
    try testing.expect(server.receive(&discover, 30_102) != null);
    var wrong_release = request(1, 7, 3); // names an address the client does not hold
    try testing.expect(server.receive(&wrong_release, 30_103) == null);
    try testing.expect(server.leases[0].duration != 0);
    var release = request(1, 7, 2);
    _ = server.receive(&release, 30_103);
    try testing.expectEqual(@as(u32, 0), server.leases[0].duration);
}

test "DHCP retransmission, selecting, decline quarantine and clock wrap" {
    var server: Default = .{};
    var packet = request(1, 1, 0);
    const before_wrap = std.math.maxInt(u32) - 100;
    const first_offer = server.receive(&packet, before_wrap).?;
    const second_offer = server.receive(&packet, 10).?;
    try testing.expectEqualSlices(u8, first_offer.bytes[16..20], second_offer.bytes[16..20]);
    packet = request(1, 3, 2);
    packet[options_start + 9 ..][0..7].* = .{ 54, 4, 192, 168, 4, 1, 255 };
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 20).?));
    packet = request(1, 4, 2);
    _ = server.receive(&packet, 30);
    packet = request(2, 3, 2);
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&packet, 40).?));
    // The quarantine lasts a lease time from the DECLINE.
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&packet, 30 + 3_600_000 - 1).?));
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 30 + 3_600_000).?));
    packet = request(3, 3, 99);
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&packet, 3_600_000 + 32).?));
}

test "DHCP keeps a lease until it expires when its holder sends DISCOVER" {
    var server: Default = .{};
    var packet = request(1, 3, 2);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 10).?));
    // A DISCOVER from the holder is answered from the bound lease and does not restart it.
    var discover = request(1, 1, 0);
    try testing.expectEqualSlices(u8, &Default.address(0), server.receive(&discover, 20).?.bytes[16..20]);
    try testing.expect(server.leases[0].bound);
    var other = request(2, 3, 2);
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&other, 10 + 3_600_000 - 1).?));
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&other, 10 + 3_600_000).?));
}

test "DHCP keeps a lease across the clock wrap until it expires" {
    var server: Default = .{};
    const since: u32 = std.math.maxInt(u32) - 100;
    var packet = request(1, 3, 2);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, since).?));
    var other = request(2, 3, 2);
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&other, since + 50).?));
    // After the wrap `now` is below `since`, but only 111 ms of the lease have passed.
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&other, 10).?));
    const expiry = since +% 3_600_000;
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&other, expiry - 1).?));
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&other, expiry).?));
}

test "DHCP SELECTING another server frees the offer" {
    var server: Default = .{};
    var packet = request(1, 1, 0);
    _ = server.receive(&packet, 0).?;
    try testing.expect(server.leases[0].duration != 0);
    packet = request(1, 3, 2);
    packet[options_start + 9 ..][0..7].* = .{ 54, 4, 192, 168, 4, 99, 255 };
    try testing.expect(server.receive(&packet, 1) == null);
    try testing.expectEqual(@as(u32, 0), server.leases[0].duration);
}

test "DHCP skips pad options and builds RFC 2131 reply fields" {
    var server: Default = .{};
    var packet = request(1, 1, 0);
    packet[4..8].* = .{ 0xde, 0xad, 0xbe, 0xef }; // xid
    packet[8..10].* = .{ 0, 9 }; // secs
    packet[10] = 0x80; // broadcast flag
    packet[3] = 2; // hops
    for (packet[34..44], 0..) |*b, i| b.* = @intCast(0xa0 + i); // chaddr past hlen
    packet[options_start..][0..12].* = .{ 0, 0, 53, 1, 1, 0, 50, 4, 192, 168, 4, 2 };
    packet[options_start + 12] = 255;
    const offer = server.receive(&packet, 0).?;
    try testing.expectEqualSlices(u8, &.{ 2, 1, 6, 0 }, offer.bytes[0..4]); // op, htype, hlen, hops
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, offer.bytes[4..8]);
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, offer.bytes[8..10]);
    try testing.expectEqual(@as(u8, 0x80), offer.bytes[10]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, offer.bytes[12..16]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, offer.bytes[24..28]); // giaddr
    try testing.expectEqualSlices(u8, packet[28..44], offer.bytes[28..44]); // all 16 chaddr bytes
    try testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 0, 1 }, &offer.mac);
    try testing.expectEqualSlices(u8, &cookie, offer.bytes[header_len..options_start]);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, &offer.destination);
    try testing.expectEqualSlices(u8, &.{
        53, 1, 2, 54, 4, 192, 168, 4, 1, 51, 4, 0, 0, 14, 16, 1, 4, 255, 255, 255, 0, 3, 4, 192, 168, 4, 1, 255,
    }, offer.bytes[options_start..][0..28]);

    // A NAK carries only the message type and server identifier.
    packet = request(2, 3, 99);
    const nak = server.receive(&packet, 1).?;
    try testing.expectEqualSlices(u8, &.{ 2, 1, 6, 0 }, nak.bytes[0..4]);
    try testing.expectEqualSlices(u8, packet[28..44], nak.bytes[28..44]);
    try testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 0, 2 }, &nak.mac);
    try testing.expectEqualSlices(u8, &cookie, nak.bytes[header_len..options_start]);
    try testing.expectEqualSlices(u8, &.{ 53, 1, 6, 54, 4, 192, 168, 4, 1, 255 }, nak.bytes[options_start..][0..10]);
    try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), nak.bytes[16..24]);
}

test "DHCP unicasts only to a configured client address" {
    var server: Default = .{};
    var packet = request(1, 1, 0);
    packet[12..16].* = .{ 192, 168, 4, 2 }; // ciaddr on a DISCOVER
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, &server.receive(&packet, 0).?.destination);
    packet = request(1, 3, 2);
    packet[12..16].* = .{ 192, 168, 4, 3 }; // ciaddr other than the requested address
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, &server.receive(&packet, 1).?.destination);
    packet = request(1, 3, 2);
    packet[12..16].* = .{ 192, 168, 4, 2 };
    try testing.expectEqualSlices(u8, &.{ 192, 168, 4, 2 }, &server.receive(&packet, 2).?.destination);
}

test "DHCP hands out the address freed earliest" {
    var server: Default = .{};
    for (1..5) |n| {
        var packet = request(@intCast(n), 3, @intCast(n + 1));
        try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 0).?));
    }
    for ([_]u8{ 2, 3, 4, 1 }) |n| {
        var release = request(n, 7, n + 1);
        try testing.expect(server.receive(&release, 1) == null);
    }
    var discover = request(9, 1, 0);
    try testing.expectEqualSlices(u8, &.{ 192, 168, 4, 3 }, server.receive(&discover, 2).?.bytes[16..20]);
}

test "DHCP gives a returning client its previous address and others an unused one" {
    var server: Default = .{};
    var packet = request(1, 3, 2);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 0).?));
    var release = request(1, 7, 2);
    try testing.expect(server.receive(&release, 1) == null);
    try testing.expectEqual(@as(u32, 0), server.leases[0].duration);
    var discover = request(2, 1, 0);
    try testing.expectEqualSlices(u8, &.{ 192, 168, 4, 3 }, server.receive(&discover, 1).?.bytes[16..20]);
    discover = request(1, 1, 0);
    try testing.expectEqualSlices(u8, &.{ 192, 168, 4, 2 }, server.receive(&discover, 2).?.bytes[16..20]);
}

test "DHCP fits router and DNS options together" {
    const Both = Server(.{ .dns = .{ 192, 168, 4, 1 } });
    var server: Both = .{};
    var packet = request(1, 1, 0);
    const offer = server.receive(&packet, 0).?;
    try testing.expectEqualSlices(u8, &.{ 3, 4, 192, 168, 4, 1, 6, 4, 192, 168, 4, 1, 255 }, offer.bytes[options_start + 21 ..][0..13]);
}

test "DHCP serves a non-default subnet and advertises DNS" {
    const Wide = Server(.{
        .server = .{ 10, 1, 0, 1 },
        .netmask = .{ 255, 255, 0, 0 },
        .pool_start = .{ 10, 1, 0, 250 },
        .lease_count = 16,
        .advertise_router = false,
        .dns = .{ 10, 1, 0, 1 },
    });
    try testing.expectEqualSlices(u8, &.{ 10, 1, 1, 9 }, &Wide.address(15));
    var server: Wide = .{};
    var packet = request(1, 1, 0);
    packet[options_start + 3] = 255;
    const offer = server.receive(&packet, 0).?;
    try testing.expectEqualSlices(u8, &.{ 10, 1, 0, 250 }, offer.bytes[16..20]);
    try testing.expectEqualSlices(u8, &.{
        53, 1, 2, 54, 4, 10, 1, 0, 1, 51, 4, 0, 0, 14, 16, 1, 4, 255, 255, 0, 0, 6, 4, 10, 1, 0, 1, 255,
    }, offer.bytes[options_start..][0..28]);
    packet = request(1, 3, 0);
    packet[options_start + 3 ..][0..7].* = .{ 50, 4, 10, 1, 1, 9, 255 };
    try testing.expectEqualSlices(u8, &.{ 10, 1, 1, 9 }, &server.receive(&packet, 1).?.leased_ip.?);
}

/// Option 54 naming the server at 192.168.4.`last`, after the options `request` writes.
fn name_server(packet: *[256]u8, last: u8) void {
    packet[options_start + 9 ..][0..7].* = .{ 54, 4, 192, 168, 4, last, 255 };
}

/// `packet` is dropped and leaves a fresh server as it was.
fn expect_dropped(packet: []const u8) !void {
    var server: Default = .{};
    try testing.expect(server.receive(packet, 0) == null);
    try testing.expectEqual(@as(u32, 0), server.frees);
    for (server.leases) |lease| try testing.expectEqual(Lease{}, lease);
}

test "DHCP drops a datagram that fails each input check" {
    // The unmodified datagrams are answered.
    var fresh: Default = .{};
    var discover = request(1, 1, 0);
    try testing.expect(fresh.receive(&discover, 0) != null);
    var own = request(2, 3, 3);
    name_server(&own, 1);
    try testing.expectEqual(MessageType.ack, message_type(fresh.receive(&own, 0).?));

    try expect_dropped(discover[0 .. options_start - 1]); // shorter than header and cookie
    var p = discover;
    p[0] = 2; // BOOTREPLY
    try expect_dropped(&p);
    p = discover;
    p[1] = 6; // htype other than Ethernet
    try expect_dropped(&p);
    p = discover;
    p[2] = 16; // hlen other than six
    try expect_dropped(&p);
    p = discover;
    p[24] = 1; // giaddr: relayed
    try expect_dropped(&p);
    p = discover;
    p[28] = 1; // multicast chaddr
    try expect_dropped(&p);
    p = discover;
    p[28..34].* = @splat(0); // all-zero chaddr, which a quarantined entry also has
    try expect_dropped(&p);
    p = discover;
    p[header_len] = 0; // cookie
    try expect_dropped(&p);
    p = discover;
    p[options_start + 3 ..][0..4].* = .{ 52, 1, 1, 255 }; // overload
    try expect_dropped(&p);
    p = discover;
    p[options_start] = 255; // no option 53
    try expect_dropped(&p);
    p = discover;
    p[options_start + 3 ..][0..4].* = .{ 53, 1, 1, 255 }; // option 53 twice
    try expect_dropped(&p);
    p = discover;
    p[options_start..][0..5].* = .{ 53, 2, 1, 1, 255 }; // option 53 of two bytes
    try expect_dropped(&p);
    p = own;
    p[options_start + 9 ..][0..7].* = .{ 50, 4, 192, 168, 4, 3, 255 }; // option 50 twice
    try expect_dropped(&p);
    p = own;
    p[options_start + 3 ..][0..6].* = .{ 50, 3, 192, 168, 4, 255 }; // option 50 of three bytes
    try expect_dropped(&p);
    p = own;
    p[options_start + 3 ..][0..8].* = .{ 50, 5, 192, 168, 4, 3, 0, 255 }; // option 50 of five bytes
    try expect_dropped(&p);
    // The next three use ciaddr in place of option 50, to make room.
    p = own;
    p[12..16].* = .{ 192, 168, 4, 3 };
    p[options_start + 3 ..][0..13].* = .{ 54, 4, 192, 168, 4, 1, 54, 4, 192, 168, 4, 1, 255 }; // option 54 twice
    try expect_dropped(&p);
    p = own;
    p[12..16].* = .{ 192, 168, 4, 3 };
    p[options_start + 3 ..][0..6].* = .{ 54, 3, 192, 168, 4, 255 }; // option 54 of three bytes
    try expect_dropped(&p);
    p = own;
    p[12..16].* = .{ 192, 168, 4, 3 };
    p[options_start + 3 ..][0..8].* = .{ 54, 5, 192, 168, 4, 1, 0, 255 }; // option 54 of five bytes
    try expect_dropped(&p);
    p = discover;
    p[options_start + 4] = 200; // option 50's length runs past the end
    try expect_dropped(&p);
    try expect_dropped(discover[0 .. options_start + 4]); // ends on an option code
}

test "DHCP keeps a bound lease through every path that frees an entry" {
    var server: Default = .{};
    var packet = request(1, 3, 2);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 0).?));
    const held = server.leases[0];
    try testing.expect(held.bound);

    // Option 54 naming another server, on any message from the holder.
    for ([_]u8{ 1, 3, 4, 7 }) |kind| {
        packet = request(1, kind, 2);
        name_server(&packet, 99);
        try testing.expect(server.receive(&packet, 1) == null);
        try testing.expectEqual(held, server.leases[0]);
    }
    // DECLINE or RELEASE from the holder naming another address.
    for ([_]u8{ 4, 7 }) |kind| {
        packet = request(1, kind, 3);
        try testing.expect(server.receive(&packet, 2) == null);
        try testing.expectEqual(held, server.leases[0]);
    }
    // DECLINE or RELEASE of the address from another client.
    for ([_]u8{ 4, 7 }) |kind| {
        packet = request(2, kind, 2);
        try testing.expect(server.receive(&packet, 3) == null);
        try testing.expectEqual(held, server.leases[0]);
    }
    // Another client's ACK for another address, and its REQUEST for this one.
    packet = request(2, 3, 3);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 4).?));
    packet = request(2, 3, 2);
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&packet, 5).?));
    try testing.expectEqual(held, server.leases[0]);
    // DISCOVERs filling the rest of the pool.
    for (3..6) |n| {
        packet = request(@intCast(n), 1, 0);
        const offer = server.receive(&packet, 6);
        if (n < 5) try testing.expect(!std.mem.eql(u8, &Default.address(0), offer.?.bytes[16..20])) else try testing.expect(offer == null);
    }
    // The expiry sweep, until the lease time has passed.
    packet = request(2, 3, 2);
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&packet, 3_600_000 - 1).?));
    try testing.expectEqual(held, server.leases[0]);
}

test "DHCP REQUEST naming another server from a client with no entry changes nothing" {
    var server: Default = .{};
    var packet = request(1, 3, 2);
    name_server(&packet, 99);
    try testing.expect(server.receive(&packet, 0) == null);
    try testing.expectEqual(Default{}, server);
}

test "DHCP keeps an offer against messages naming another server other than REQUEST" {
    var server: Default = .{};
    var packet = request(1, 1, 0);
    _ = server.receive(&packet, 0).?;
    const offered = server.leases[0];
    for ([_]u8{ 1, 4, 7 }) |kind| {
        packet = request(1, kind, 2);
        name_server(&packet, 99);
        try testing.expect(server.receive(&packet, 1) == null);
        try testing.expectEqual(offered, server.leases[0]);
    }
}

test "DHCP ACK for another address frees the client's old entry" {
    var server: Default = .{};
    var packet = request(1, 3, 2);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 0).?));
    packet = request(1, 3, 3);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 1).?));
    try testing.expectEqual(@as(u32, 0), server.leases[0].duration);
    packet = request(2, 3, 2);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 2).?));
}

test "DHCP drops a REQUEST that names no address" {
    var server: Default = .{};
    var packet = request(1, 3, 2);
    packet[options_start + 3] = 255; // no option 50, and ciaddr is zero
    try testing.expect(server.receive(&packet, 0) == null);
    try testing.expectEqual(Lease{}, server.leases[0]);
}

test "DHCP quarantine holds no MAC and goes to the back of the reuse order when it expires" {
    const Two = Server(.{ .lease_count = 2 });
    var server: Two = .{};
    var packet = request(1, 3, 2);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 0).?));
    packet = request(1, 4, 2);
    try testing.expect(server.receive(&packet, 1) == null);
    // The decliner is not offered the quarantined address as its own.
    packet = request(1, 1, 0);
    try testing.expectEqualSlices(u8, &Two.address(1), server.receive(&packet, 2).?.bytes[16..20]);
    packet = request(1, 3, 3);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 3).?));
    packet = request(1, 7, 3);
    try testing.expect(server.receive(&packet, 4) == null);
    // The quarantine expires after that release, so the released address goes out first.
    packet = request(9, 1, 0);
    try testing.expectEqualSlices(u8, &Two.address(1), server.receive(&packet, 1 + 3_600_000).?.bytes[16..20]);
    try testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), &server.leases[0].mac);
    try testing.expectEqual(@as(u32, 0), server.leases[0].duration);
}

test "DHCP DISCOVER retransmission restarts an offer" {
    const One = Server(.{ .lease_count = 1 });
    var server: One = .{};
    var packet = request(1, 1, 0);
    _ = server.receive(&packet, 0).?;
    _ = server.receive(&packet, 20_000).?;
    packet = request(2, 1, 0);
    try testing.expect(server.receive(&packet, 40_000) == null);
    try testing.expect(server.receive(&packet, 50_000) != null);
}

test "DHCP reply address fields" {
    var server: Default = .{};
    var packet = request(1, 1, 0);
    packet[12..16].* = .{ 192, 168, 4, 7 }; // ciaddr on a DISCOVER
    const offer = server.receive(&packet, 0).?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 192, 168, 4, 2, 192, 168, 4, 1 }, offer.bytes[12..24]);
    try testing.expect(offer.leased_ip == null);
    packet = request(1, 3, 2);
    packet[12..16].* = .{ 192, 168, 4, 2 };
    packet[options_start + 3] = 255; // renewal: ciaddr, no option 50
    const ack = server.receive(&packet, 1).?;
    try testing.expectEqualSlices(u8, &.{ 192, 168, 4, 2, 192, 168, 4, 2, 192, 168, 4, 1 }, ack.bytes[12..24]);
    try testing.expectEqualSlices(u8, &.{ 192, 168, 4, 2 }, &ack.leased_ip.?);
}

test "DHCP NAKs a REQUEST for an address offered to another client until the offer lapses" {
    var server: Default = .{};
    var packet = request(1, 1, 0);
    try testing.expectEqualSlices(u8, &Default.address(0), server.receive(&packet, 0).?.bytes[16..20]);
    packet = request(2, 3, 2);
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&packet, 30_000 - 1).?));
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 30_000).?));
}

test "DHCP reserves a released or lapsed address when it offers it again" {
    // Released, then offered to its last holder.
    var server: Default = .{};
    var packet = request(1, 3, 2);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 0).?));
    packet = request(1, 7, 2);
    try testing.expect(server.receive(&packet, 1) == null);
    packet = request(1, 1, 0);
    try testing.expectEqualSlices(u8, &Default.address(0), server.receive(&packet, 2).?.bytes[16..20]);
    packet = request(2, 3, 2);
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&packet, 3).?));

    // Lapsed, then offered to its last holder.
    server = .{};
    packet = request(1, 3, 2);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 0).?));
    packet = request(1, 1, 0);
    try testing.expectEqualSlices(u8, &Default.address(0), server.receive(&packet, 3_600_000).?.bytes[16..20]);
    packet = request(2, 3, 2);
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&packet, 3_600_001).?));
}

test "DHCP NAKs a REQUEST just outside the pool" {
    var server: Default = .{};
    // The server address just below the pool, and the address just past it.
    for ([_]u8{ 1, 6 }) |ip| {
        var packet = request(1, 3, ip);
        try testing.expectEqual(MessageType.nak, message_type(server.receive(&packet, 0).?));
    }
    var packet = request(1, 3, 5);
    try testing.expectEqualSlices(u8, &Default.address(3), &server.receive(&packet, 0).?.leased_ip.?);
}

test "DHCP RELEASE, DECLINE and an ACK for another address act on an offer as on a lease" {
    // RELEASE frees the offered address at once.
    var server: Default = .{};
    var packet = request(1, 1, 0);
    _ = server.receive(&packet, 0).?;
    packet = request(1, 7, 2);
    try testing.expect(server.receive(&packet, 1) == null);
    packet = request(2, 3, 2);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 2).?));

    // An ACK for another address frees the offered one at once.
    server = .{};
    packet = request(1, 1, 0);
    _ = server.receive(&packet, 0).?;
    packet = request(1, 3, 3);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 1).?));
    packet = request(2, 3, 2);
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 2).?));

    // DECLINE quarantines the offered address for a lease time, well past the offer's expiry.
    server = .{};
    packet = request(1, 1, 0);
    _ = server.receive(&packet, 0).?;
    packet = request(1, 4, 2);
    try testing.expect(server.receive(&packet, 1) == null);
    packet = request(2, 3, 2);
    try testing.expectEqual(MessageType.nak, message_type(server.receive(&packet, 1 + 3_600_000 - 1).?));
    try testing.expectEqual(MessageType.ack, message_type(server.receive(&packet, 1 + 3_600_000).?));
}

test "DHCP model check: no address goes to a second client while it is held" {
    // Random datagrams from five MACs against a pool of three, checked against a model of what
    // each client was told. The server must never OFFER or ACK an address while another
    // client's offer or lease, or a quarantine, holds it; must NAK a pool address only while
    // one of those holds it; must answer only with pool addresses;
    // must ACK only the address asked for; and must OFFER a client that holds an address that
    // address. Each seed starts within 2^17 ms of the u32 clock wrap and runs past it. The run
    // must not pass by answering nothing: it must see ACKs, OFFERs, NAKs of an address another
    // client or a quarantine holds, accepted DECLINEs, and NAKs after the wrap of a hold made
    // before it. An out-of-bounds lease index panics the test.
    const seeds = 100;
    const steps = 500;
    const lease_ms = 100_000;
    const offer_ms = 30_000;
    const wrap = 1 << 32;
    const Three = Server(.{ .lease_count = 3, .lease_ms = lease_ms, .offer_ms = offer_ms });
    const quarantined = 255; // the model's holder of a declined address; MACs end in 1 to 5
    const Hold = struct { mac: u8 = 0, since: u64 = 0, until: u64 = 0, lease: bool = false };
    var acks: u32 = 0;
    var offers: u32 = 0;
    var refusals: u32 = 0; // NAKs of an address held by another client or a quarantine
    var quarantines: u32 = 0;
    var refusals_across_wrap: u32 = 0; // of those, a hold made before the wrap and NAKed after it
    var seed: u64 = 1;
    while (seed <= seeds) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        var server: Three = .{};
        var holds: [3]Hold = @splat(.{}); // pool .2 to .4
        var now: u64 = wrap - @as(u64, r.uintLessThan(u32, 1 << 17));
        for (0..steps) |_| {
            now += switch (r.uintLessThan(u8, 10)) {
                0 => r.uintLessThan(u32, 120_000),
                1, 2 => r.uintLessThan(u32, 35_000),
                // To the last millisecond of a hold or the first after it, where an expiry one
                // millisecond early or late shows.
                3 => boundary: {
                    const end = holds[r.uintLessThan(u8, 3)].until -| r.uintLessThan(u8, 2);
                    break :boundary if (end > now) end - now else 0;
                },
                else => r.uintLessThan(u32, 50),
            };
            const mac: u8 = 1 + r.uintLessThan(u8, 5);
            const kind: u8 = ([_]u8{ 1, 1, 3, 3, 3, 4, 7, 8 })[r.uintLessThan(u8, 8)];
            var wanted: u8 = r.uintLessThan(u8, 7); // .0 to .6: below, in and past the pool
            var packet = request(mac, kind, wanted);
            if (r.uintLessThan(u8, 4) == 0) {
                packet[options_start + 3] = 255; // ciaddr in place of option 50
                wanted = r.uintLessThan(u8, 7);
                packet[12..16].* = if (wanted == 0) @splat(0) else .{ 192, 168, 4, wanted };
            }
            var other_server = false;
            if (packet[options_start + 3] != 255 and r.uintLessThan(u8, 6) == 0) {
                other_server = r.boolean();
                name_server(&packet, if (other_server) 99 else 1);
            }
            const reply = server.receive(&packet, @truncate(now));

            // What the client gave up by sending this.
            const in_pool = wanted >= 2 and wanted <= 4;
            if (!other_server and (kind == 4 or kind == 7) and in_pool) {
                const h = &holds[wanted - 2];
                if (h.mac == mac) h.* = if (kind == 4 and h.until > now) quarantine: {
                    quarantines += 1;
                    break :quarantine .{ .mac = quarantined, .since = now, .until = now + lease_ms };
                } else .{};
            } else if (other_server and kind == 3) {
                for (&holds) |*h| if (h.mac == mac and !h.lease) {
                    h.* = .{};
                };
            }

            const got = reply orelse continue;
            try testing.expectEqualSlices(u8, packet[28..44], got.bytes[28..44]);
            try testing.expectEqualSlices(u8, packet[28..34], &got.mac);
            const response = message_type(got);
            if (response == MessageType.nak) {
                if (in_pool) {
                    const h = holds[wanted - 2];
                    if (h.mac != 0 and h.mac != mac and h.until > now) {
                        refusals += 1;
                        if (h.since < wrap and now >= wrap) refusals_across_wrap += 1;
                    } else {
                        std.debug.print("seed {d}: .{d} NAKed for MAC {d} while it is free or its own\n", .{ seed, wanted, mac });
                        return error.TestUnexpectedResult;
                    }
                }
                continue;
            }
            try testing.expectEqualSlices(u8, &.{ 192, 168, 4 }, got.bytes[16..19]);
            const last = got.bytes[19];
            try testing.expect(last >= 2 and last <= 4);
            const index: usize = last - 2;
            if (response == MessageType.ack) {
                acks += 1;
                try testing.expectEqual(wanted, last);
            } else {
                offers += 1;
                for (holds, 0..) |o, j| if (o.mac == mac and o.until > now) {
                    try testing.expectEqual(j, index);
                };
            }
            const h = &holds[index];
            if (h.mac != 0 and h.mac != mac and h.until > now) {
                std.debug.print("seed {d}: .{d} given to MAC {d} (type {d}) while {d} holds it for {d} more ms\n", .{ seed, last, mac, response, h.mac, h.until - now });
                return error.AddressHandedOutTwice;
            }
            if (response == MessageType.ack) {
                // The client now uses this address and no other.
                for (&holds) |*o| if (o.mac == mac) {
                    o.* = .{};
                };
                h.* = .{ .mac = mac, .since = now, .until = now + lease_ms, .lease = true };
            } else if (!(h.mac == mac and h.lease and h.until > now)) {
                h.* = .{ .mac = mac, .since = now, .until = now + offer_ms };
            }
        }
        try testing.expect(now > wrap);
    }
    try testing.expect(acks != 0);
    try testing.expect(offers != 0);
    try testing.expect(refusals != 0);
    try testing.expect(quarantines != 0);
    try testing.expect(refusals_across_wrap != 0);
}
