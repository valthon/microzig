//! Example-local DHCPv4 server (RFC 2131 §§4.3.1–4.3.4, RFC 2132).
//! Ethernet clients only; no relay, option overload, DNS or persistent leases.
const std = @import("std");

pub const gateway = [4]u8{ 192, 168, 4, 1 };
pub const max_stations = 4;
const lease_ms = 3600 * 1000;
const cookie = [4]u8{ 99, 130, 83, 99 };

const Lease = struct {
    mac: [6]u8 = @splat(0),
    since: u32 = 0,
    duration: u32 = 0,
};

pub const Reply = struct {
    bytes: [300]u8,
    destination: [4]u8,
    leased_ip: ?[4]u8,
    mac: [6]u8,
};

pub const Server = struct {
    leases: [max_stations]Lease = @splat(.{}),

    pub fn receive(self: *Server, packet: []const u8, now: u32) ?Reply {
        if (packet.len < 240 or packet[0] != 1 or packet[1] != 1 or packet[2] != 6 or
            !std.mem.eql(u8, packet[24..28], &.{ 0, 0, 0, 0 }) or
            !std.mem.eql(u8, packet[236..240], &cookie)) return null;
        const mac: [6]u8 = packet[28..34].*;
        if (mac[0] & 1 != 0 or std.mem.allEqual(u8, &mac, 0)) return null;
        var kind: ?u8 = null;
        var requested: ?[4]u8 = null;
        var server: ?[4]u8 = null;
        var pos: usize = 240;
        while (pos < packet.len) {
            const code = packet[pos];
            pos += 1;
            if (code == 255) break;
            if (code == 0) continue;
            if (pos == packet.len) return null;
            const len = packet[pos];
            pos += 1;
            if (len > packet.len - pos) return null;
            const value = packet[pos..][0..len];
            switch (code) {
                53 => {
                    if (len != 1 or kind != null) return null;
                    kind = value[0];
                },
                50 => {
                    if (len != 4 or requested != null) return null;
                    requested = value[0..4].*;
                },
                54 => {
                    if (len != 4 or server != null) return null;
                    server = value[0..4].*;
                },
                52 => return null, // option overload is not supported
                else => {},
            }
            pos += len;
        }
        if (server) |id| {
            if (!std.mem.eql(u8, &id, &gateway)) return null;
        }
        var own: ?usize = null;
        var free: ?usize = null;
        for (&self.leases, 0..) |*lease, i| {
            if (now -% lease.since >= lease.duration) lease.duration = 0;
            if (lease.duration == 0) {
                if (free == null) free = i;
            } else if (std.mem.eql(u8, &lease.mac, &mac)) own = i;
        }
        const ciaddr: [4]u8 = packet[12..16].*;
        const wanted = requested orelse ciaddr;
        var index: ?usize = own;
        var response_kind: u8 = 0;
        switch (kind orelse return null) {
            1 => { // DISCOVER: reserve an offer briefly, preserving an existing lease.
                index = own orelse free orelse return null;
                if (own == null) self.leases[index.?] = .{ .mac = mac, .since = now, .duration = 30_000 };
                response_kind = 2;
            },
            3 => { // REQUEST: selecting, INIT-REBOOT, or renewing/rebinding.
                if (std.mem.eql(u8, &wanted, &.{ 0, 0, 0, 0 })) return null;
                if (wanted[0] == 192 and wanted[1] == 168 and wanted[2] == 4 and
                    wanted[3] >= 2 and wanted[3] < 2 + max_stations)
                {
                    const candidate = wanted[3] - 2;
                    if (self.leases[candidate].duration == 0 or own == candidate) index = candidate else index = null;
                } else index = null;
                if (index) |i| {
                    // A MAC has at most one address, even after INIT-REBOOT.
                    if (own) |old| if (old != i) {
                        self.leases[old].duration = 0;
                    };
                    self.leases[i] = .{ .mac = mac, .since = now, .duration = lease_ms };
                    response_kind = 5;
                } else response_kind = 6;
            },
            4, 7 => { // DECLINE quarantines the address; RELEASE frees it.
                if (own) |i| {
                    const ip = address(i);
                    if (std.mem.eql(u8, &wanted, &ip)) {
                        self.leases[i].duration = if (kind.? == 4) lease_ms else 0;
                        self.leases[i].since = now;
                        if (kind.? == 4) self.leases[i].mac = @splat(0);
                    }
                }
                return null;
            },
            else => return null,
        }
        var reply: Reply = .{
            .bytes = @splat(0),
            .destination = if (response_kind != 6 and !std.mem.allEqual(u8, &ciaddr, 0) and packet[10] & 0x80 == 0) ciaddr else @splat(255),
            .leased_ip = if (response_kind == 5) address(index.?) else null,
            .mac = mac,
        };
        reply.bytes[0] = 2; // BOOTREPLY
        reply.bytes[1] = 1;
        reply.bytes[2] = 6;
        @memcpy(reply.bytes[4..12], packet[4..12]); // xid, secs, flags
        if (response_kind != 6) {
            @memcpy(reply.bytes[12..16], &ciaddr);
            @memcpy(reply.bytes[16..20], &address(index.?));
        }
        @memcpy(reply.bytes[20..24], &gateway);
        @memcpy(reply.bytes[28..44], packet[28..44]);
        @memcpy(reply.bytes[236..240], &cookie);
        // message type, server identifier; NAK must not contain lease options.
        @memcpy(reply.bytes[240..249], &[_]u8{ 53, 1, response_kind, 54, 4, 192, 168, 4, 1 });
        if (response_kind == 6) {
            reply.bytes[249] = 255;
        } else {
            @memcpy(reply.bytes[249..268], &[_]u8{
                51, 4, 0, 0, 14, 16, // 3600 seconds
                1, 4, 255, 255, 255, 0, // subnet mask
                3,   4, 192, 168, 4, 1, // router
                255,
            });
        }
        return reply;
    }
};

fn address(index: usize) [4]u8 {
    return .{ 192, 168, 4, @intCast(index + 2) };
}

fn request(mac: u8, kind: u8, ip: u8) [256]u8 {
    var packet: [256]u8 = @splat(0);
    packet[0..3].* = .{ 1, 1, 6 };
    packet[28..34].* = .{ 2, 0, 0, 0, 0, mac };
    packet[236..240].* = cookie;
    packet[240..250].* = .{ 53, 1, kind, 50, 4, 192, 168, 4, ip, 255 };
    return packet;
}

test "DHCP allocation, renewal, collision, release, exhaustion and expiry" {
    var server: Server = .{};
    var discover = request(1, 1, 0);
    const offer = server.receive(&discover, 0).?;
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 4, 2 }, offer.bytes[16..20]);
    var req = request(1, 3, 2);
    const ack = server.receive(&req, 1).?;
    try std.testing.expectEqual(@as(u8, 5), ack.bytes[242]);
    try std.testing.expectEqualSlices(u8, &address(0), &ack.leased_ip.?);
    var other = request(2, 3, 2);
    try std.testing.expectEqual(@as(u8, 6), server.receive(&other, 2).?.bytes[242]);
    req[12..16].* = address(0);
    req[243] = 255; // renewal has ciaddr and no requested-IP option
    try std.testing.expectEqualSlices(u8, &address(0), &server.receive(&req, 100).?.destination);
    for (2..5) |n| {
        discover = request(@intCast(n), 1, 0);
        try std.testing.expect(server.receive(&discover, 101) != null);
    }
    discover = request(5, 1, 0);
    try std.testing.expect(server.receive(&discover, 102) == null);
    try std.testing.expect(server.receive(&discover, 30_102) != null);
    var release = request(1, 7, 2);
    _ = server.receive(&release, 30_103);
    try std.testing.expectEqual(@as(u32, 0), server.leases[0].duration);
}

test "DHCP rejects malformed options, relays and requests for another server" {
    var server: Server = .{};
    var packet = request(1, 1, 0);
    try std.testing.expect(server.receive(packet[0..239], 0) == null);
    packet[241] = 200;
    try std.testing.expect(server.receive(&packet, 0) == null);
    packet = request(1, 1, 0);
    packet[24] = 1;
    try std.testing.expect(server.receive(&packet, 0) == null);
    packet = request(1, 3, 2);
    packet[249..256].* = .{ 54, 4, 192, 168, 4, 99, 255 };
    try std.testing.expect(server.receive(&packet, 0) == null);
    try std.testing.expectEqual(@as(u32, 0), server.leases[0].duration);
}

test "DHCP retransmission, selecting, decline quarantine and clock wrap" {
    var server: Server = .{};
    var packet = request(1, 1, 0);
    const before_wrap = std.math.maxInt(u32) - 100;
    const first = server.receive(&packet, before_wrap).?;
    const second = server.receive(&packet, 10).?;
    try std.testing.expectEqualSlices(u8, first.bytes[16..20], second.bytes[16..20]);
    packet = request(1, 3, 2);
    packet[249..256].* = .{ 54, 4, 192, 168, 4, 1, 255 };
    try std.testing.expectEqual(@as(u8, 5), server.receive(&packet, 20).?.bytes[242]);
    packet = request(1, 4, 2);
    _ = server.receive(&packet, 30);
    packet = request(2, 3, 2);
    try std.testing.expectEqual(@as(u8, 6), server.receive(&packet, 40).?.bytes[242]);
    try std.testing.expectEqual(@as(u8, 5), server.receive(&packet, lease_ms + 31).?.bytes[242]);
    packet = request(3, 3, 99);
    try std.testing.expectEqual(@as(u8, 6), server.receive(&packet, lease_ms + 32).?.bytes[242]);
}
