//! Minimal single-link BLE host. Bluetooth Core Vol 4 Part E (HCI),
//! Vol 3 Parts A/F/G (L2CAP/ATT/GATT). No allocation, SMP or bonding.
const std = @import("std");
pub const wire = @import("protocol.zig");
pub const gatt = @import("gatt.zig");
pub const Error = wire.Error;
pub const Advertisement = wire.Advertisement;
const read16 = wire.read16;
const write16 = wire.write16;
const procedure_timeout_ms = 2000;
// Core Vol 3 Part F §3.3.3; IDF v5.5.1 NimBLE ble_gattc.c uses 30 s too.
const att_timeout_ms = 30_000;
const Response = struct {
    len: u8,
    bytes: [255]u8,
    fn data(self: *const Response) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Peer = struct {
    service_start: u16,
    service_end: u16,
    read_write: u16 = 0,
    notify: u16 = 0,
    cccd: u16 = 0,
};

/// All methods and callbacks run on one host task. Callbacks must not call back
/// into the host. Controller callbacks only copy packets into the transport.
pub const Host = struct {
    transport: wire.Transport,
    on_advertisement: ?*const fn (?*anyopaque, *const Advertisement) void = null,
    advertisement_context: ?*anyopaque = null,
    connection: ?u16 = null,
    connection_status: ?u8 = null,
    disconnect_reason: ?u8 = null,
    supervision_timeout_ms: u32 = 2560,
    last_hci_status: u8 = 0,
    last_att_error: u8 = 0,
    server: ?gatt.Server = null,
    notifications: u32 = 0,
    notification: [20]u8 = @splat(0),
    notification_len: u8 = 0,
    peer_notify: u16 = 0,
    command_credits: u8 = 1,
    acl_capacity: u16 = 0,
    acl_credits: u16 = 0,
    command_pending: ?u16 = null,
    command_reply: ?Response = null,
    att_pending: ?u8 = null,
    att_reply: ?Response = null,
    // An expired request makes this fixed ATT bearer unusable until reconnect.
    att_timed_out: bool = false,
    rx: [260]u8 = undefined,
    rx_len: usize = 0,
    rx_expected: usize = 0,
    target_name: ?[]const u8 = null,
    found: ?Advertisement = null,
    last_notify_ms: u64 = 0,

    pub fn init(transport: wire.Transport) Host {
        return .{ .transport = transport };
    }
    fn now(self: *const Host) u64 {
        return self.transport.now_ms_fn(self.transport.context);
    }
    fn wait(self: *Host, deadline: u64) Error!void {
        const current = self.now();
        if (current >= deadline) return error.Timeout;
        self.poll(@intCast(@min(deadline - current, procedure_timeout_ms))) catch |err| {
            if (err != error.Timeout) return err;
            if (self.now() >= deadline) return error.Timeout;
        };
    }

    /// Reset and configure event delivery, then obtain controller ACL credits.
    pub fn initialize(self: *Host) Error!void {
        _ = try self.command(0x0c03, &.{});
        _ = try self.command(0x0c01, &.{ 0x10, 0xe0, 0x04, 0, 0, 0, 0, 0x20 });
        _ = try self.command(0x2001, &.{ 7, 0, 0, 0, 0, 0, 0, 0 });
        const response = try self.command(0x2002, &.{});
        if (response.len != 4) return error.InvalidPacket;
        var size = read16(response.bytes[1..3]);
        var count: u16 = response.bytes[3];
        if (count == 0) {
            const shared = try self.command(0x1005, &.{});
            if (shared.len != 8) return error.InvalidPacket;
            size = read16(shared.bytes[1..3]);
            count = read16(shared.bytes[4..6]);
        }
        if (size < 27 or count == 0) return error.Unsupported;
        self.acl_capacity = count;
        self.acl_credits = count;
    }
    fn command(self: *Host, opcode: u16, parameters: []const u8) Error!Response {
        if (self.command_pending != null or parameters.len > 255) return error.Busy;
        const deadline = self.now() + procedure_timeout_ms;
        while (self.command_credits == 0) try self.wait(deadline);
        var buf: [258]u8 = undefined;
        write16(&buf, opcode);
        buf[2] = @intCast(parameters.len);
        @memcpy(buf[3..][0..parameters.len], parameters);
        self.command_pending = opcode;
        defer self.command_pending = null;
        self.command_reply = null;
        self.command_credits -= 1;
        self.transport.send_command_fn(self.transport.context, buf[0 .. parameters.len + 3]) catch |err| {
            self.command_credits += 1;
            return err;
        };
        while (self.command_reply == null) try self.wait(deadline);
        const response = self.command_reply.?;
        self.command_reply = null;
        self.last_hci_status = response.bytes[0];
        if (self.last_hci_status != 0) return error.CommandFailed;
        return response;
    }

    pub fn scan(self: *Host, enabled: bool) Error!void {
        if (enabled) _ = try self.command(0x200b, &.{ 1, 0x60, 0, 0x30, 0, 0, 0 });
        _ = try self.command(0x200c, &.{ @intFromBool(enabled), 0 });
    }
    pub fn advertise(self: *Host, name: []const u8) Error!void {
        self.server = try gatt.Server.init(name);
        // 100 ms, connectable undirected, public address, all primary channels.
        _ = try self.command(0x2006, &.{ 0xa0, 0, 0xa0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0 });
        var data: [32]u8 = @splat(0);
        data[0] = @intCast(name.len + 9);
        data[1..8].* = .{ 2, 1, 6, 3, 3, 0xf0, 0xff };
        data[8] = @intCast(name.len + 1);
        data[9] = 9;
        @memcpy(data[10..][0..name.len], name);
        _ = try self.command(0x2008, &data);
        try self.resume_advertising();
    }
    pub fn resume_advertising(self: *Host) Error!void {
        if (self.server == null or self.connection != null) return error.Busy;
        _ = try self.command(0x200a, &.{1});
    }

    /// Active scan so a name carried in a scan response is also visible.
    pub fn connect_named(self: *Host, name: []const u8, timeout_ms: u32) Error!void {
        if (name.len == 0 or name.len > 31) return error.InvalidName;
        if (self.connection != null) return error.Busy;
        self.target_name = name;
        defer self.target_name = null;
        self.found = null;
        try self.scan(true);
        const deadline = self.now() + timeout_ms;
        while (self.found == null) self.wait(deadline) catch |err| {
            try self.scan(false);
            return err;
        };
        const peer = self.found.?;
        try self.scan(false);
        // IDF v5.5.1 NimBLE ble_gap_conn_params_dflt: continuous 10 ms
        // initiating scan, 30–50 ms interval, latency 0, supervision 2.56 s.
        var parameters: [25]u8 = .{ 0x10, 0, 0x10, 0, 0, peer.address_type, 0, 0, 0, 0, 0, 0, 0, 0x18, 0, 0x28, 0, 0, 0, 0, 1, 0, 0, 0, 0 };
        @memcpy(parameters[6..12], &peer.address);
        self.connection_status = null;
        _ = try self.command(0x200d, &parameters);
        const connect_deadline = self.now() + timeout_ms;
        while (self.connection_status == null) self.wait(connect_deadline) catch |err| {
            if (err == error.Timeout) {
                // Cancel the outstanding procedure and consume its completion.
                _ = try self.command(0x200e, &.{});
                const cancel_deadline = self.now() + procedure_timeout_ms;
                while (self.connection_status == null) try self.wait(cancel_deadline);
                if (self.connection != null) try self.disconnect();
            }
            return err;
        };
        if (self.connection_status.? != 0 or self.connection == null) return error.ConnectionFailed;
    }
    pub fn disconnect(self: *Host) Error!void {
        const handle = self.connection orelse return error.NoConnection;
        _ = try self.command(0x0406, &.{ @truncate(handle), @truncate(handle >> 8), 0x13 });
        // The controller may need the supervision timeout to terminate a
        // silent peer; the HCI command deadline alone can expire too soon.
        const deadline = self.now() + self.supervision_timeout_ms + procedure_timeout_ms;
        while (self.connection != null) try self.wait(deadline);
    }

    /// Process one transport packet. Timeout is a normal idle result.
    pub fn poll(self: *Host, timeout_ms: u32) Error!void {
        const packet = try self.transport.receive_fn(self.transport.context, timeout_ms);
        if (packet.len > packet.bytes.len) return error.InvalidPacket;
        switch (packet.kind) {
            .event => try self.event(packet.data()),
            .acl => try self.acl(packet.data()),
        }
    }
    /// Call regularly in the peripheral loop, even while traffic is arriving.
    pub fn tick(self: *Host) Error!void {
        const server = if (self.server) |*s| s else return;
        const current = self.now();
        if (self.connection == null or !server.subscribed or current - self.last_notify_ms < 1000) return;
        const notification = server.notification();
        try self.send_fixed(4, &notification);
        self.last_notify_ms = current;
    }
    fn event(self: *Host, data: []const u8) Error!void {
        if (data.len < 2 or data.len != @as(usize, data[1]) + 2) return error.InvalidPacket;
        switch (data[0]) {
            0x0e => {
                if (data.len < 5) return error.InvalidPacket;
                self.command_credits = data[2];
                // Opcode 0x0000 (NOP) only reports command credits and has no
                // status byte. The C6 controller sends one when it becomes
                // ready, while the first command is outstanding; NimBLE's
                // controller does the same (ble_ll_hci.c ble_ll_hci_send_noop)
                // and its host accepts it without a status (ble_hs_hci.c).
                if (read16(data[3..5]) == 0) return;
                if (data.len < 6) return error.InvalidPacket;
                if (self.command_pending == null or read16(data[3..5]) != self.command_pending.?) return error.InvalidPacket;
                if (self.command_reply != null) return error.InvalidPacket;
                var response: Response = .{ .len = @intCast(data.len - 5), .bytes = undefined };
                @memcpy(response.bytes[0..response.len], data[5..]);
                self.command_reply = response;
            },
            0x0f => {
                if (data.len != 6) return error.InvalidPacket;
                self.command_credits = data[3];
                if (read16(data[4..6]) == 0) return; // NOP: credits only
                if (self.command_pending == null or read16(data[4..6]) != self.command_pending.?) return error.InvalidPacket;
                if (self.command_reply != null) return error.InvalidPacket;
                var response: Response = .{ .len = 1, .bytes = undefined };
                response.bytes[0] = data[2];
                self.command_reply = response;
            },
            0x13 => {
                if (data.len < 3 or data.len != 3 + @as(usize, data[2]) * 4) return error.InvalidPacket;
                var offset: usize = 3;
                while (offset < data.len) : (offset += 4) {
                    if (self.connection != read16(data[offset..])) continue;
                    const count = read16(data[offset + 2 ..]);
                    if (count > self.acl_capacity - self.acl_credits) return error.InvalidPacket;
                    self.acl_credits += count;
                }
            },
            5 => {
                if (data.len != 6) return error.InvalidPacket;
                if (data[2] == 0 and self.connection == read16(data[3..5])) {
                    self.connection = null;
                    self.disconnect_reason = data[5];
                    self.rx_len = 0;
                    self.rx_expected = 0;
                    self.acl_credits = self.acl_capacity;
                    self.att_reply = null;
                    if (self.server) |*server| server.disconnected();
                }
            },
            0x10 => return error.HardwareError,
            0x3e => {
                if (data.len < 3) return error.InvalidPacket;
                switch (data[2]) {
                    1, 0x0a => {
                        if (data.len != (if (data[2] == 1) @as(usize, 21) else 33)) return error.InvalidPacket;
                        self.connection_status = data[3];
                        if (data[3] == 0) {
                            const handle = read16(data[4..6]);
                            if (handle > 0x0eff or self.connection != null) return error.InvalidPacket;
                            self.connection = handle;
                            self.supervision_timeout_ms = @as(u32, read16(data[data.len - 3 ..][0..2])) * 10;
                            self.disconnect_reason = null;
                            self.att_timed_out = false;
                            self.acl_credits = self.acl_capacity;
                            self.peer_notify = 0;
                            self.notifications = 0;
                            self.rx_len = 0;
                            self.rx_expected = 0;
                            if (self.server) |*server| server.disconnected();
                        }
                    },
                    3 => {
                        if (data.len != 12) return error.InvalidPacket;
                        if (data[3] == 0 and self.connection == read16(data[4..6]))
                            self.supervision_timeout_ms = @as(u32, read16(data[10..12])) * 10;
                    },
                    2 => {
                        var reports = try wire.Reports.init(data[2..]);
                        while (try reports.next()) |ad| {
                            if (self.on_advertisement) |callback| callback(self.advertisement_context, &ad);
                            if (self.target_name) |target| {
                                if (ad.address_type > 1 or (ad.event_type != 0 and ad.event_type != 1 and ad.event_type != 4)) continue;
                                if (ad.name()) |name| if (std.mem.eql(u8, name, target)) {
                                    self.found = ad;
                                };
                            }
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    fn acl(self: *Host, data: []const u8) Error!void {
        if (data.len < 4 or data.len != @as(usize, read16(data[2..4])) + 4) return error.InvalidPacket;
        const flags = read16(data[0..2]);
        if (self.connection != flags & 0x0fff) return;
        if (flags & 0xc000 != 0) return error.InvalidPacket;
        const pb = flags >> 12 & 3;
        const fragment = data[4..];
        if (pb != 1) {
            if (self.rx_len != 0 or fragment.len < 4) return error.InvalidPacket;
            self.rx_expected = @as(usize, read16(fragment[0..2])) + 4;
            if (self.rx_expected > self.rx.len) return error.InvalidPacket;
        } else if (self.rx_len == 0) return error.InvalidPacket;
        if (fragment.len == 0 or fragment.len > self.rx_expected - self.rx_len) return error.InvalidPacket;
        @memcpy(self.rx[self.rx_len..][0..fragment.len], fragment);
        self.rx_len += fragment.len;
        if (self.rx_len != self.rx_expected) return;
        // Response transmission can pump more packets. Detach this reassembly
        // before dispatch so nested receive cannot overwrite the current PDU.
        const packet = self.rx;
        const len = self.rx_len;
        self.rx_len = 0;
        self.rx_expected = 0;
        const cid = read16(packet[2..4]);
        switch (cid) {
            4 => try self.att(packet[4..len]),
            5 => {
                const signal = packet[4..len];
                if (signal.len < 4 or signal.len != @as(usize, read16(signal[2..4])) + 4 or signal[1] == 0) return error.InvalidPacket;
                // Reject connection parameter updates; keep the negotiated
                // interval. Other requests receive Command Not Understood.
                if (signal[0] == 0x12 and signal.len == 12) {
                    try self.send_fixed(5, &.{ 0x13, signal[1], 2, 0, 1, 0 });
                } else if (signal[0] != 1) {
                    try self.send_fixed(5, &.{ 1, signal[1], 2, 0, 0, 0 });
                }
            },
            6 => {
                // Pairing Request -> Pairing Failed, Pairing Not Supported.
                if (len > 4 and packet[4] == 1) try self.send_fixed(6, &.{ 5, 5 });
            },
            else => {},
        }
    }
    fn send_fixed(self: *Host, cid: u16, payload: []const u8) Error!void {
        if (cid == 4 and self.att_timed_out) return error.Timeout;
        if (payload.len > gatt.mtu) return error.Unsupported;
        const deadline = self.now() + procedure_timeout_ms;
        while (self.acl_credits == 0) {
            if (self.connection == null) return error.Disconnected;
            try self.wait(deadline);
        }
        const handle = self.connection orelse return error.Disconnected;
        var data: [31]u8 = undefined;
        // LE Host -> Controller starts are non-flushable (PB=00), unlike
        // Controller -> Host starts (PB=10). IDF v5.5.1 l2c_utils.c,
        // l2cu_set_acl_hci_header uses L2CAP_PKT_START_NON_FLUSHABLE for LE.
        write16(&data, handle);
        write16(data[2..], @intCast(payload.len + 4));
        write16(data[4..], @intCast(payload.len));
        write16(data[6..], cid);
        @memcpy(data[8..][0..payload.len], payload);
        self.acl_credits -= 1;
        self.transport.send_acl_fn(self.transport.context, data[0 .. payload.len + 8]) catch |err| {
            self.acl_credits += 1;
            return err;
        };
    }
    fn att(self: *Host, data: []const u8) Error!void {
        if (data.len == 0 or data.len > gatt.mtu) return error.InvalidPacket;
        if (self.att_timed_out) return;
        if (data[0] == 0x1b or data[0] == 0x1d) {
            if (data.len < 3) return error.InvalidPacket;
            if (read16(data[1..3]) == self.peer_notify and self.peer_notify != 0) {
                self.notifications +%= 1;
                self.notification_len = @intCast(data.len - 3);
                @memcpy(self.notification[0..self.notification_len], data[3..]);
            }
            if (data[0] == 0x1d) try self.send_fixed(4, &.{0x1e});
            return;
        }
        if (data[0] & 1 != 0) {
            const pending = self.att_pending orelse return error.InvalidPacket;
            if (data[0] == 1) {
                if (data.len != 5 or data[1] != pending) return error.InvalidPacket;
                self.last_att_error = data[4];
            } else if (data[0] != pending + 1) return error.InvalidPacket;
            if (self.att_reply != null) return error.InvalidPacket;
            var response: Response = .{ .len = @intCast(data.len), .bytes = undefined };
            @memcpy(response.bytes[0..data.len], data);
            self.att_reply = response;
            return;
        }
        var out: [gatt.mtu]u8 = undefined;
        if (self.server) |*server| {
            const was_subscribed = server.subscribed;
            const response = server.respond(data, &out);
            if (!was_subscribed and server.subscribed) self.last_notify_ms = self.now();
            if (response.len != 0) try self.send_fixed(4, response);
        } else if (data[0] == 2 and data.len == 3 and read16(data[1..3]) >= 23) {
            try self.send_fixed(4, &.{ 3, 23, 0 });
        } else if (data[0] & 0x40 == 0) {
            try self.send_fixed(4, &.{ 1, data[0], if (data.len >= 3) data[1] else 0, if (data.len >= 3) data[2] else 0, 6 });
        }
    }
    fn exchange(self: *Host, pdu: []const u8) Error!Response {
        if (self.connection == null) return error.NoConnection;
        if (self.att_timed_out) return error.Timeout;
        if (self.att_pending != null) return error.Busy;
        self.att_pending = pdu[0];
        defer self.att_pending = null;
        self.att_reply = null;
        self.last_att_error = 0;
        try self.send_fixed(4, pdu);
        const deadline = self.now() + att_timeout_ms;
        while (self.att_reply == null) {
            if (self.connection == null) return error.Disconnected;
            self.wait(deadline) catch |err| {
                // Requests have no transaction ID. A late response must never
                // satisfy a later request. The caller must disconnect, as
                // NimBLE ble_gattc_timer does for its fixed ATT bearer.
                if (err == error.Timeout) self.att_timed_out = true;
                return err;
            };
        }
        const response = self.att_reply.?;
        self.att_reply = null;
        return response;
    }
    fn request(self: *Host, data: []const u8) Error!Response {
        const response = try self.exchange(data);
        if (response.bytes[0] == 1) return error.AttError;
        return response;
    }
    pub fn read(self: *Host, handle: u16, out: []u8) Error!usize {
        const response = try self.request(&.{ 0x0a, @truncate(handle), @truncate(handle >> 8) });
        const len = @as(usize, response.len) - 1;
        if (len > out.len) return error.NoBuffer;
        @memcpy(out[0..len], response.bytes[1..][0..len]);
        return len;
    }
    pub fn write(self: *Host, handle: u16, value: []const u8, without_response: bool) Error!void {
        if (value.len > 20) return error.Unsupported;
        var pdu: [23]u8 = undefined;
        pdu[0] = if (without_response) 0x52 else 0x12;
        write16(pdu[1..3], handle);
        @memcpy(pdu[3..][0..value.len], value);
        if (without_response) try self.send_fixed(4, pdu[0 .. value.len + 3]) else {
            const response = try self.request(pdu[0 .. value.len + 3]);
            if (response.len != 1) return error.InvalidPacket;
        }
    }
    pub fn subscribe(self: *Host, peer: Peer) Error!void {
        if (peer.notify == 0 or peer.cccd == 0) return error.NotFound;
        self.peer_notify = peer.notify;
        self.notifications = 0;
        try self.write(peer.cccd, &.{ 1, 0 }, false);
    }

    /// Discover the primary FFF0 service, its 16-bit characteristics, and the
    /// CCCD within FFF2's descriptor range. Handles are never assumed.
    pub fn discover(self: *Host) Error!Peer {
        var start: u16 = 1;
        var peer: ?Peer = null;
        while (true) {
            const response = try self.exchange(&.{ 0x10, @truncate(start), @truncate(start >> 8), 0xff, 0xff, 0, 0x28 });
            const data = response.data();
            if (data[0] == 1) {
                if (data[4] != 0x0a) return error.AttError;
                break;
            }
            if (data.len < 2 or (data[1] != 6 and data[1] != 20) or data.len < 2 + @as(usize, data[1]) or (data.len - 2) % data[1] != 0) return error.InvalidPacket;
            var offset: usize = 2;
            var last: u16 = start - 1;
            while (offset < data.len) : (offset += data[1]) {
                const first = read16(data[offset..]);
                const end = read16(data[offset + 2 ..]);
                if (first <= last or end < first) return error.InvalidPacket;
                last = end;
                if (data[1] == 6 and read16(data[offset + 4 ..]) == 0xfff0) peer = .{ .service_start = first, .service_end = end };
            }
            if (peer != null or last == 0xffff) break;
            start = last + 1;
        }
        var result = peer orelse return error.NotFound;
        start = result.service_start;
        var notify_end = result.service_end;
        var last_decl: u16 = start - 1;
        while (true) {
            const response = try self.exchange(&.{ 8, @truncate(start), @truncate(start >> 8), @truncate(result.service_end), @truncate(result.service_end >> 8), 3, 0x28 });
            const data = response.data();
            if (data[0] == 1) {
                if (data[4] != 0x0a) return error.AttError;
                break;
            }
            if (data.len < 2 or (data[1] != 7 and data[1] != 21) or data.len < 2 + @as(usize, data[1]) or (data.len - 2) % data[1] != 0) return error.InvalidPacket;
            var offset: usize = 2;
            while (offset < data.len) : (offset += data[1]) {
                const decl = read16(data[offset..]);
                const value = read16(data[offset + 3 ..]);
                if (decl < start or decl <= last_decl or value <= decl or value > result.service_end) return error.InvalidPacket;
                last_decl = decl;
                if (result.notify != 0 and decl > result.notify and notify_end == result.service_end) notify_end = decl - 1;
                if (data[1] == 7) switch (read16(data[offset + 5 ..])) {
                    0xfff1 => {
                        if (data[offset + 2] & 0x0e != 0x0e) return error.Unsupported;
                        result.read_write = value;
                    },
                    0xfff2 => {
                        if (data[offset + 2] & 0x10 == 0) return error.Unsupported;
                        result.notify = value;
                    },
                    else => {},
                };
            }
            if (last_decl == result.service_end) break;
            start = last_decl + 1;
        }
        if (result.read_write == 0 or result.notify == 0 or result.notify >= notify_end) return error.NotFound;
        start = result.notify + 1;
        while (start <= notify_end) {
            const response = try self.exchange(&.{ 4, @truncate(start), @truncate(start >> 8), @truncate(notify_end), @truncate(notify_end >> 8) });
            const data = response.data();
            if (data[0] == 1) {
                if (data[4] != 0x0a) return error.AttError;
                break;
            }
            if (data.len < 2 or (data[1] != 1 and data[1] != 2)) return error.InvalidPacket;
            const width: usize = if (data[1] == 1) 4 else 18;
            if (data.len < width + 2 or (data.len - 2) % width != 0) return error.InvalidPacket;
            var offset: usize = 2;
            var last: u16 = start - 1;
            while (offset < data.len) : (offset += width) {
                const handle = read16(data[offset..]);
                if (handle <= last or handle < start or handle > notify_end) return error.InvalidPacket;
                last = handle;
                if (width == 4 and read16(data[offset + 2 ..]) == 0x2902) result.cccd = handle;
            }
            if (result.cccd != 0 or last == notify_end) break;
            start = last + 1;
        }
        if (result.cccd == 0) return error.NotFound;
        return result;
    }
};

test {
    _ = gatt;
    _ = wire;
}

// Scripted controller responses with non-default peer handles. These fixtures
// exercise command/event interleaving, ACL credits and L2CAP fragmentation.
const Fixture = struct {
    queue: [8]wire.Packet = undefined,
    head: usize = 0,
    len: usize = 0,
    commands: usize = 0,
    acl_step: usize = 0,
    reject_command: bool = false,
    // Send a credits-only NOP completion ahead of the next command's reply.
    nop_first: bool = false,
    capture_only: bool = false,
    delayed_response_ms: u32 = 0,
    captured: [31]u8 = undefined,
    captured_len: usize = 0,
    clock_ms: u64 = 1000,

    fn transport(self: *Fixture) wire.Transport {
        return .{ .context = self, .send_command_fn = send_command, .send_acl_fn = send_acl, .receive_fn = receive, .now_ms_fn = now_ms };
    }
    fn now_ms(context: *anyopaque) u64 {
        const self: *Fixture = @ptrCast(@alignCast(context));
        return self.clock_ms;
    }
    fn enqueue(self: *Fixture, kind: wire.PacketKind, data: []const u8) Error!void {
        if (self.len == self.queue.len or data.len > 260) return error.ReceiveOverflow;
        const dest = &self.queue[(self.head + self.len) % self.queue.len];
        dest.* = .{ .kind = kind, .len = @intCast(data.len), .bytes = undefined };
        @memcpy(dest.bytes[0..data.len], data);
        self.len += 1;
    }
    fn receive(context: *anyopaque, timeout_ms: u32) Error!wire.Packet {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (self.len == 0) {
            if (self.delayed_response_ms != 0) {
                const delay = @min(timeout_ms, self.delayed_response_ms);
                self.clock_ms += delay;
                self.delayed_response_ms -= delay;
                if (self.delayed_response_ms == 0) {
                    try self.acl_response(&.{0x13}, false);
                    return receive(context, 0);
                }
                return error.Timeout;
            }
            self.clock_ms += timeout_ms;
            return error.Timeout;
        }
        const packet = self.queue[self.head];
        self.head = (self.head + 1) % self.queue.len;
        self.len -= 1;
        return packet;
    }
    fn send_command(context: *anyopaque, data: []const u8) Error!void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (data.len < 3 or data.len != 3 + @as(usize, data[2])) return error.InvalidPacket;
        self.commands += 1;
        const opcode = read16(data);
        if (self.nop_first) {
            self.nop_first = false;
            try self.enqueue(.event, &.{ 0x0e, 3, 1, 0, 0 });
        }
        if (opcode == 0x200d) {
            if (!std.mem.eql(u8, data[3..7], &.{ 0x10, 0, 0x10, 0 }) or
                !std.mem.eql(u8, data[16..], &.{ 0x18, 0, 0x28, 0, 0, 0, 0, 1, 0, 0, 0, 0 })) return error.InvalidPacket;
            try self.enqueue(.event, &.{ 0x0f, 4, 0, 1, 0x0d, 0x20 });
            try self.enqueue(.event, &.{ 0x3e, 19, 1, 0, 7, 0, 0, 0, 1, 2, 3, 4, 5, 6, 24, 0, 0, 0, 0, 1, 0 });
        } else if (opcode == 0x0406) {
            try self.enqueue(.event, &.{ 0x0f, 4, 0, 1, 6, 4 });
            try self.enqueue(.event, &.{ 5, 4, 0, 7, 0, 0x16 });
        } else {
            var reply: [9]u8 = .{ 0x0e, 4, 1, data[0], data[1], if (self.reject_command) 0x0c else 0, 27, 0, 1 };
            const len: usize = if (opcode == 0x2002) 9 else 6;
            reply[1] = @intCast(len - 2);
            try self.enqueue(.event, reply[0..len]);
            if (opcode == 0x200c and data[3] == 1) {
                try self.enqueue(.event, &.{ 0x3e, 21, 2, 1, 4, 0, 1, 2, 3, 4, 5, 6, 9, 8, 9, 'H', '2', '-', 'P', 'E', 'E', 'R', 0xc4 });
            }
        }
    }
    fn acl_response(self: *Fixture, pdu: []const u8, fragmented: bool) Error!void {
        var first: [31]u8 = undefined;
        first[0..4].* = .{ 7, 0x20, 0, 0 };
        write16(first[4..], @intCast(pdu.len));
        write16(first[6..], 4);
        const take: usize = if (fragmented) 2 else pdu.len;
        write16(first[2..], @intCast(take + 4));
        @memcpy(first[8..][0..take], pdu[0..take]);
        try self.enqueue(.acl, first[0 .. 8 + take]);
        if (fragmented) {
            var second: [31]u8 = undefined;
            second[0..4].* = .{ 7, 0x10, 0, 0 };
            write16(second[2..], @intCast(pdu.len - take));
            @memcpy(second[4..][0 .. pdu.len - take], pdu[take..]);
            try self.enqueue(.acl, second[0 .. 4 + pdu.len - take]);
        }
    }
    fn send_acl(context: *anyopaque, data: []const u8) Error!void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (self.capture_only) {
            if (data.len > self.captured.len) return error.InvalidPacket;
            @memcpy(self.captured[0..data.len], data);
            self.captured_len = data.len;
            try self.enqueue(.event, &.{ 0x13, 5, 1, 7, 0, 1, 0 });
            return;
        }
        const requests = [_][]const u8{
            &.{ 0x10, 1, 0, 0xff, 0xff, 0, 0x28 },
            &.{ 8, 0x20, 0, 0x2f, 0, 3, 0x28 },
            &.{ 8, 0x26, 0, 0x2f, 0, 3, 0x28 },
            &.{ 4, 0x27, 0, 0x2f, 0 },
            &.{ 0x0a, 0x22, 0 },
        };
        const responses = [_][]const u8{
            &.{ 0x11, 6, 0x20, 0, 0x2f, 0, 0xf0, 0xff },
            &.{ 9, 7, 0x21, 0, 0x0e, 0x22, 0, 0xf1, 0xff, 0x25, 0, 0x10, 0x26, 0, 0xf2, 0xff },
            &.{ 1, 8, 0x26, 0, 0x0a },
            &.{ 5, 1, 0x27, 0, 1, 0x29, 0x28, 0, 2, 0x29 },
            &.{ 0x0b, 'O', 'K' },
        };
        if (self.acl_step >= requests.len or data.len < 8 or !std.mem.eql(u8, data[8..], requests[self.acl_step])) return error.InvalidPacket;
        if (read16(data) != 0x0007 or read16(data[2..]) != data.len - 4 or read16(data[4..]) != data.len - 8 or read16(data[6..]) != 4) return error.InvalidPacket;
        try self.enqueue(.event, &.{ 0x13, 5, 1, 7, 0, 1, 0 });
        if (self.acl_step == 4) try self.acl_response(&.{ 0x1b, 0x26, 0, 1, 2, 3, 4 }, false);
        try self.acl_response(responses[self.acl_step], true);
        self.acl_step += 1;
    }
};

test "host commands, named scan response, fragmented GATT and interleaved notification" {
    var fixture: Fixture = .{};
    var host = Host.init(fixture.transport());
    try host.initialize();
    try std.testing.expectEqual(@as(u16, 1), host.acl_credits);
    try host.connect_named("H2-PEER", 1000);
    try std.testing.expectEqual(@as(?u16, 7), host.connection);
    const peer = try host.discover();
    try std.testing.expectEqual(Peer{ .service_start = 0x20, .service_end = 0x2f, .read_write = 0x22, .notify = 0x26, .cccd = 0x28 }, peer);
    host.peer_notify = peer.notify;
    var value: [20]u8 = undefined;
    const len = try host.read(peer.read_write, &value);
    try std.testing.expectEqualStrings("OK", value[0..len]);
    try std.testing.expectEqual(@as(u32, 1), host.notifications);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, host.notification[0..host.notification_len]);
    try std.testing.expectEqual(@as(usize, 5), fixture.acl_step);
    try std.testing.expectEqual(@as(u16, 1), host.acl_credits);
}
test "a NOP command completion only updates credits" {
    var fixture: Fixture = .{ .nop_first = true };
    var host = Host.init(fixture.transport());
    try host.initialize();
    try std.testing.expectEqual(@as(u16, 1), host.acl_credits);
    try std.testing.expectEqual(@as(u8, 1), host.command_credits);
    // A different credit count shows the NOP's credits are taken.
    try host.event(&.{ 0x0e, 3, 3, 0, 0 });
    try std.testing.expectEqual(@as(u8, 3), host.command_credits);
    try std.testing.expectEqual(@as(?Response, null), host.command_reply);
    try host.event(&.{ 0x0f, 4, 0, 2, 0, 0 });
    try std.testing.expectEqual(@as(u8, 2), host.command_credits);
    try std.testing.expectEqual(@as(?Response, null), host.command_reply);
}
test "host rejects invalid completions and fails bounded waits" {
    var fixture: Fixture = .{};
    var host = Host.init(fixture.transport());
    try host.initialize();
    host.connection = 7;
    try std.testing.expectError(error.InvalidPacket, host.event(&.{ 0x13, 5, 1, 7, 0, 1, 0 }));
    try std.testing.expectError(error.InvalidPacket, host.acl(&.{ 7, 0x10, 1, 0, 1 }));
    try std.testing.expectError(error.Busy, host.connect_named("other", 1000));
    host.connection = null;
    try std.testing.expectError(error.Timeout, host.connect_named("other", 1000));
    const before = fixture.clock_ms;
    try std.testing.expectError(error.Timeout, host.connect_named("other", 5000));
    try std.testing.expectEqual(before + 5000, fixture.clock_ms);
    fixture.reject_command = true;
    try std.testing.expectError(error.CommandFailed, host.scan(false));
    try std.testing.expectEqual(@as(u8, 0x0c), host.last_hci_status);
}

test "peripheral answers CCCD writes, ticks a counter and clears subscription on disconnect" {
    var fixture: Fixture = .{ .capture_only = true };
    var host = Host.init(fixture.transport());
    try host.initialize();
    try host.advertise("MZ-C6");
    host.connection = 7;
    try fixture.acl_response(&.{ 0x12, 9, 0, 1, 0 }, false);
    try host.poll(1);
    try std.testing.expect(host.server.?.subscribed);
    try std.testing.expectEqualSlices(u8, &.{0x13}, fixture.captured[8..fixture.captured_len]);
    try host.poll(1); // Number Of Completed Packets restores the single credit.
    host.last_notify_ms = 0;
    try host.tick();
    try std.testing.expectEqualSlices(u8, &.{ 0x1b, 8, 0, 1, 0, 0, 0 }, fixture.captured[8..fixture.captured_len]);
    try host.event(&.{ 5, 4, 0, 7, 0, 0x13 });
    try std.testing.expect(!host.server.?.subscribed);
    try host.resume_advertising();
}
test "client write command is response-free and subscribe uses the discovered CCCD" {
    var fixture: Fixture = .{ .capture_only = true };
    var host = Host.init(fixture.transport());
    try host.initialize();
    host.connection = 7;
    try host.write(0x22, "C6", true);
    try std.testing.expectEqualSlices(u8, &.{ 0x52, 0x22, 0, 'C', '6' }, fixture.captured[8..fixture.captured_len]);
    try host.poll(1);
    try fixture.acl_response(&.{0x13}, false);
    try host.subscribe(.{ .service_start = 0x20, .service_end = 0x2f, .notify = 0x26, .cccd = 0x28 });
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x28, 0, 1, 0 }, fixture.captured[8..fixture.captured_len]);
    try std.testing.expectEqual(@as(u16, 0x26), host.peer_notify);
}

test "a write response after two seconds still completes the ATT transaction" {
    var fixture: Fixture = .{ .capture_only = true, .delayed_response_ms = 3000 };
    var host = Host.init(fixture.transport());
    try host.initialize();
    host.connection = 7;
    const before = fixture.clock_ms;
    try host.write(0x22, "C6", false);
    try std.testing.expectEqual(before + 3000, fixture.clock_ms);
    try std.testing.expect(!host.att_timed_out);
}

test "ATT timeout forbids bearer reuse and late responses but allows disconnect" {
    var fixture: Fixture = .{ .capture_only = true };
    var host = Host.init(fixture.transport());
    try host.initialize();
    host.connection = 7;
    const before = fixture.clock_ms;
    try std.testing.expectError(error.Timeout, host.write(0x22, "C6", false));
    try std.testing.expectEqual(before + 30_000, fixture.clock_ms);
    try fixture.acl_response(&.{0x13}, false);
    try host.poll(1); // A late write response cannot revive this bearer.
    try std.testing.expectError(error.Timeout, host.write(0x22, "again", false));
    try std.testing.expectError(error.Timeout, host.write(0x22, "command", true));
    try host.disconnect();
    try std.testing.expectEqual(@as(?u16, null), host.connection);
    // Only a fresh connection makes ATT usable again.
    try host.connect_named("H2-PEER", 1000);
    try std.testing.expect(!host.att_timed_out);
    try std.testing.expectEqual(@as(u32, 2560), host.supervision_timeout_ms);
    try host.event(&.{ 0x3e, 10, 3, 0, 7, 0, 40, 0, 0, 0, 0xf4, 1 });
    try std.testing.expectEqual(@as(u32, 5000), host.supervision_timeout_ms);
}
