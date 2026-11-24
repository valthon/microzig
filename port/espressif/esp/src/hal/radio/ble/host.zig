//! Minimal single-link BLE host. Bluetooth Core Vol 4 Part E (HCI),
//! Vol 3 Parts A/F/G/H (L2CAP/ATT/GATT/SMP). No allocation.
const std = @import("std");
pub const wire = @import("protocol.zig");
pub const gatt = @import("gatt.zig");
pub const smp = @import("smp.zig");
pub const Error = wire.Error;
pub const Advertisement = wire.Advertisement;
const read16 = wire.read16;
const write16 = wire.write16;
const procedure_timeout_ms = 2000;
// Core Vol 3 Part F §3.3.3; IDF v5.5.1 NimBLE ble_gattc.c uses 30 s too.
const att_timeout_ms = 30_000;
// Receive wait while an SMP IO hook answer is outstanding: the hook is asked
// again after each wait.
const io_poll_ms = 20;
const Response = struct {
    len: u8,
    bytes: [255]u8,
    fn data(self: *const Response) []const u8 {
        return self.bytes[0..self.len];
    }
};
/// The link security a frame needs when it is handed to the controller.
/// `refusal` replaces a withheld ATT response; other protected frames are
/// dropped.
const Guard = struct { permission: gatt.Permission = .open, refusal: ?[5]u8 = null };
const Tx = struct { len: u8, bytes: [69]u8, guard: Guard };
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
    last_encryption_status: ?u8 = null,
    last_encryption_enabled: ?u8 = null,
    /// Optional ATT diagnostics on the host task. TX means handed to the
    /// controller, not acknowledged by the peer; a withheld protected frame is
    /// not reported (its Error Response is). The borrowed PDU expires on return.
    on_att_packet: ?*const fn (*const Host, bool, []const u8) void = null,
    // Header only: never retain SMP key material for diagnostics.
    last_packet: ?struct { kind: wire.PacketKind, len: u16, header: [8]u8 } = null,
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
    acl_packet_size: u16 = 27,
    security_config: ?smp.Config = null,
    security: ?smp.Session = null,
    local_address: smp.crypto.Address = @splat(0),
    ltk_request: ?struct { handle: u16, valid: bool } = null,
    servicing_security: bool = false,
    tx: [8]Tx = undefined,
    tx_count: u4 = 0,
    transmitting: bool = false,
    negative_ltk_replies: u32 = 0,
    /// Frames withheld because the link lost the security they needed while
    /// they waited for ACL credits: dropped, or for an ATT response, replaced
    /// by an Error Response.
    withheld_protected: u32 = 0,

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
        // Vol 4 Part E: Encryption Change (bit 7), Key Refresh (bit 47),
        // and LE LTK Request (LE bit 4), as well as existing host events.
        _ = try self.command(0x0c01, &.{ 0x90, 0xe0, 0x04, 0, 0, 0x80, 0, 0x20 });
        _ = try self.command(0x2001, &.{ 0x17, 0, 0, 0, 0, 0, 0, 0 });
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
        self.acl_packet_size = @min(size, 255);
        self.acl_capacity = count;
        self.acl_credits = count;
        const address = try self.command(0x1009, &.{});
        if (address.len != 7) return error.InvalidPacket;
        self.local_address = [1]u8{0} ++ smp.crypto.reverse(6, address.bytes[1..7].*);
    }

    /// Configure before connecting. Store, crypto and IO contexts outlive Host.
    pub fn configure_security(self: *Host, config: smp.Config) Error!void {
        if (self.connection != null) return error.Busy;
        self.security_config = config;
    }
    /// Central starts encryption from a bond when available, otherwise pairs.
    /// A peripheral sends Security Request and processes the central's exchange.
    pub fn secure(self: *Host) Error!void {
        const security = if (self.security) |*s| s else return error.Unsupported;
        if (security.encrypted and security.state == .complete) return;
        if (security.state == .timed_out) return error.Timeout;
        if (security.state != .idle) return error.Busy;
        if (security.central and security.bonded) {
            security.state = .complete;
            security.start_encryption = true;
        } else try security.start(self.now());
        try self.service_security();
        const deadline = self.now() + 30_000;
        while (true) {
            if (self.connection == null) return error.Disconnected;
            if (security.encrypted and security.state == .complete) break;
            if (security.state == .failed) return error.SecurityFailed;
            if (security.state == .timed_out) return error.Timeout;
            const smp_deadline = if (security.state == .complete) deadline else security.deadline;
            self.wait(smp_deadline) catch |err| {
                if (err == error.Timeout) security.tick(self.now());
                return err;
            };
        }
        try self.service_security();
    }
    /// Remove persisted key material. Disconnect before pairing again.
    pub fn remove_bond(self: *Host, peer: smp.crypto.Address) Error!void {
        const config = self.security_config orelse return error.Unsupported;
        const store = config.store orelse return error.Unsupported;
        try store.remove(peer);
        if (self.security) |*security| {
            if (try store.load(security.peer) == null) {
                security.bonded = false;
                // Do not erase a key while its encryption procedure is in flight.
                // It is discarded with the Session on disconnect.
            }
        }
    }
    fn service_security(self: *Host) Error!void {
        if (self.servicing_security or self.command_pending != null) return;
        self.servicing_security = true;
        defer self.servicing_security = false;
        // One slot: the controller raises LE LTK Request from the peer's
        // LL_ENC_REQ in the encryption start procedure (Core v5.4 Vol 6 Part B
        // §5.1.3.1), which waits for this reply before the link encrypts, so a
        // second request on one connection is not expected before the first is
        // answered. A request for another handle is stale (disconnect clears
        // the slot) and is dropped without holding back the SMP queue.
        if (self.ltk_request) |ltk| {
            self.ltk_request = null;
            if (self.connection == ltk.handle) {
                const have_key = if (self.security) |s| ltk.valid and (s.state == .encryption or s.bonded) else false;
                const handle = [2]u8{ @truncate(ltk.handle), @truncate(ltk.handle >> 8) };
                if (have_key) {
                    var params = handle ++ smp.crypto.reverse(16, self.security.?.derived.ltk);
                    defer std.crypto.secureZero(u8, &params);
                    _ = try self.command(0x201a, &params);
                } else {
                    _ = try self.command(0x201b, &handle);
                    self.negative_ltk_replies +%= 1;
                }
            }
        }
        const security = if (self.security) |*s| s else return;
        security.tick(self.now());
        try security.poll_io();
        while (security.pop()) |popped| {
            var pdu = popped;
            defer std.crypto.secureZero(u8, &pdu.bytes);
            try self.send_fixed(6, pdu.data());
            if (self.connection == null) return error.Disconnected;
            security.sent(self.now());
        }
        if (security.start_encryption) {
            security.start_encryption = false;
            const handle = self.connection orelse return error.NoConnection;
            var params = [2]u8{ @truncate(handle), @truncate(handle >> 8) } ++ @as([10]u8, @splat(0)) ++ smp.crypto.reverse(16, security.derived.ltk);
            defer std.crypto.secureZero(u8, &params);
            _ = self.command(0x2019, &params) catch |err| {
                if (self.connection == null) return error.Disconnected;
                try security.encryption_changed(false, self.now());
                self.sync_server();
                return err;
            };
            if (self.connection == null) return error.Disconnected;
        }
        self.sync_server();
        if (security.save_bond) {
            // Attempt each completed bond once. A refused or failed save is
            // reported to this poll's caller; the link keeps working
            // unbonded and later polls still receive packets.
            security.save_bond = false;
            const store = security.config.store orelse return error.StorageFailed;
            var bond = security.bond();
            defer std.crypto.secureZero(u8, std.mem.asBytes(&bond));
            try store.save(bond);
            security.bonded = true;
        }
    }
    fn sync_server(self: *Host) void {
        const security = if (self.security) |*s| s else return;
        if (self.server) |*server| {
            server.encrypted = security.encrypted;
            server.authenticated = security.encrypted and security.authenticated;
        }
    }
    fn command(self: *Host, opcode: u16, parameters: []const u8) Error!Response {
        if (self.command_pending != null or parameters.len > 255) return error.Busy;
        const deadline = self.now() + procedure_timeout_ms;
        while (self.command_credits == 0) try self.wait(deadline);
        var buf: [258]u8 = undefined;
        // Parameters can carry an LTK (LE Enable Encryption, LTK Request Reply).
        defer std.crypto.secureZero(u8, &buf);
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
        try self.configure_advertising(name);
        try self.resume_advertising();
    }
    /// Broadcast legacy AD bytes without accepting connections. Call with advertising disabled.
    pub fn advertise_nonconnectable(self: *Host, data: []const u8) Error!void {
        if (self.connection != null) return error.Busy;
        try self.set_advertising_parameters(.nonconnectable);
        try self.set_advertising_data(data);
        _ = try self.command(0x200a, &.{1});
    }
    /// Configure with advertising disabled. Set server permissions before
    /// resume_advertising() makes this server reachable by a peer.
    pub fn configure_advertising(self: *Host, name: []const u8) Error!void {
        self.server = try gatt.Server.init(name);
        try self.set_advertising_parameters(.connectable);
        try self.set_advertising_name(name);
    }
    const AdvertisingType = enum(u8) { connectable = 0, nonconnectable = 3 };
    fn set_advertising_parameters(self: *Host, kind: AdvertisingType) Error!void {
        // 100 ms, undirected, public address, all primary channels.
        _ = try self.command(0x2006, &.{ 0xa0, 0, 0xa0, 0, @backingInt(kind), 0, 0, 0, 0, 0, 0, 0, 0, 7, 0 });
    }
    /// Change the advertised local name while advertising is disabled. Does
    /// not recreate the GATT server or change its permissions or GAP name.
    pub fn set_advertising_name(self: *Host, name: []const u8) Error!void {
        if (name.len == 0 or name.len > 20) return error.InvalidName;
        var data: [32]u8 = @splat(0);
        data[0] = @intCast(name.len + 9);
        data[1..8].* = .{ 2, 1, 6, 3, 3, 0xf0, 0xff };
        data[8] = @intCast(name.len + 1);
        data[9] = 9;
        @memcpy(data[10..][0..name.len], name);
        _ = try self.command(0x2008, &data);
    }
    /// Replace legacy AD bytes while advertising is disabled.
    pub fn set_advertising_data(self: *Host, data: []const u8) Error!void {
        if (data.len > 31) return error.InvalidPacket;
        var parameters: [32]u8 = @splat(0);
        parameters[0] = @intCast(data.len);
        @memcpy(parameters[1..][0..data.len], data);
        _ = try self.command(0x2008, &parameters);
    }
    pub fn resume_advertising(self: *Host) Error!void {
        if (self.server == null or self.connection != null) return error.Busy;
        _ = try self.command(0x200a, &.{1});
    }
    pub fn stop_advertising(self: *Host) Error!void {
        _ = try self.command(0x200a, &.{0});
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
        try self.connect_address(peer, timeout_ms);
    }

    /// Initiate to the exact address and type from a fresh advertising report.
    /// Caller must stop scanning first; no name-based reselection takes place.
    pub fn connect_address(self: *Host, peer: Advertisement, timeout_ms: u32) Error!void {
        if (self.connection != null) return error.Busy;
        if (peer.address_type > 1) return error.InvalidPacket;
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
        try self.service_security();
        const awaiting_io = if (self.security) |*s| s.awaiting_io() else false;
        const receive_ms = if (awaiting_io) @min(timeout_ms, io_poll_ms) else timeout_ms;
        var packet = self.transport.receive_fn(self.transport.context, receive_ms) catch |err| {
            if (self.security) |*s| s.tick(self.now());
            return err;
        };
        defer std.crypto.secureZero(u8, &packet.bytes);
        // An ACL continuation fragment (PB=01) has no L2CAP header: keep only
        // its 4-byte HCI header, so no SMP payload byte reaches diagnostics.
        const continuation = packet.kind == .acl and packet.len >= 2 and read16(packet.bytes[0..2]) >> 12 & 3 == 1;
        var header: [8]u8 = @splat(0);
        const header_len = @min(packet.len, if (continuation) @as(usize, 4) else header.len);
        @memcpy(header[0..header_len], packet.bytes[0..header_len]);
        self.last_packet = .{ .kind = packet.kind, .len = packet.len, .header = header };
        if (packet.len > packet.bytes.len) return error.InvalidPacket;
        switch (packet.kind) {
            .event => try self.event(packet.data()),
            .acl => try self.acl(packet.data()),
        }
        try self.service_security();
    }
    /// Call regularly in the peripheral loop, even while traffic is arriving.
    pub fn tick(self: *Host) Error!void {
        const server = if (self.server) |*s| s else return;
        const current = self.now();
        if (self.connection == null or !server.subscribed or current - self.last_notify_ms < 1000) return;
        if (server.permission_error(gatt.notify_handle) != null) return;
        const notification = server.notification();
        // A notification has no response (Core v5.4 Vol 3 Part F §3.4.7.1), so
        // one withheld for lost security is dropped without a replacement.
        try self.send_frame(4, &notification, .{ .permission = server.permissions[gatt.notify_handle - 1] });
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
                    if (self.security) |*s| s.disconnected();
                    self.security = null;
                    self.ltk_request = null;
                    for (&self.tx) |*frame| std.crypto.secureZero(u8, &frame.bytes);
                    self.tx_count = 0;
                    if (self.server) |*server| server.disconnected();
                }
            },
            0x10 => return error.HardwareError,
            8, 0x30 => {
                if (data.len != (if (data[0] == 8) @as(usize, 6) else 5)) return error.InvalidPacket;
                if (self.connection != read16(data[3..5])) return;
                self.last_encryption_status = data[2];
                self.last_encryption_enabled = if (data[0] == 8) data[5] else null;
                if (self.security) |*security| {
                    const enabled = data[2] == 0 and (data[0] == 0x30 or data[5] == 1);
                    try security.encryption_changed(enabled, self.now());
                    self.sync_server();
                }
            },
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
                            self.last_encryption_status = null;
                            self.last_encryption_enabled = null;
                            self.att_timed_out = false;
                            self.acl_credits = self.acl_capacity;
                            self.peer_notify = 0;
                            self.notifications = 0;
                            self.rx_len = 0;
                            self.rx_expected = 0;
                            if (self.server) |*server| server.disconnected();
                            self.security = null;
                            if (self.security_config) |config| {
                                // Resolved-address types (2, 3) need controller privacy,
                                // which is not enabled; SMP stays unconfigured and refuses.
                                if (data[7] > 1) return error.Unsupported;
                                const peer = [1]u8{data[7]} ++ smp.crypto.reverse(6, data[8..14].*);
                                self.security = smp.Session.init(config, data[6] == 0, self.local_address, peer);
                                const security = &self.security.?;
                                if (config.store) |store| {
                                    const loaded = store.load(peer) catch |err| {
                                        // Fail closed: an unreadable store may hold an
                                        // authenticated bond that Just Works must not replace.
                                        security.config.require_authenticated = true;
                                        return err;
                                    };
                                    if (loaded) |found| {
                                        var bond = found;
                                        defer std.crypto.secureZero(u8, std.mem.asBytes(&bond));
                                        _ = security.restore(bond);
                                    }
                                }
                            }
                        }
                    },
                    3 => {
                        if (data.len != 12) return error.InvalidPacket;
                        if (data[3] == 0 and self.connection == read16(data[4..6]))
                            self.supervision_timeout_ms = @as(u32, read16(data[10..12])) * 10;
                    },
                    5 => {
                        if (data.len != 15) return error.InvalidPacket;
                        const handle = read16(data[3..5]);
                        if (self.connection != handle) return;
                        // Secure Connections always uses zero Rand and EDIV.
                        self.ltk_request = .{ .handle = handle, .valid = std.mem.allEqual(u8, data[5..15], 0) };
                        if (self.security == null) {
                            // Unconfigured hosts still reject the controller's request.
                            // Defer until no synchronous HCI command is outstanding.
                            return;
                        }
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
        var packet = self.rx;
        const len = self.rx_len;
        defer std.crypto.secureZero(u8, packet[0..len]);
        std.crypto.secureZero(u8, self.rx[0..len]);
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
                if (self.security) |*security| {
                    try security.receive(packet[4..len], self.now());
                } else if (len > 4 and (packet[4] == 1 or packet[4] == 0x0b)) try self.send_fixed(6, &.{ 5, 5 });
            },
            else => {},
        }
    }
    /// SMP key distribution (Encryption Information through Signing
    /// Information) needs an encrypted link, Core v5.4 Vol 3 Part H §2.4.3.2.
    fn send_fixed(self: *Host, cid: u16, payload: []const u8) Error!void {
        const key = cid == 6 and payload.len != 0 and payload[0] >= 6 and payload[0] <= 0x0a;
        return self.send_frame(cid, payload, .{ .permission = if (key) .encrypted else .open });
    }
    fn link_meets(self: *const Host, permission: gatt.Permission) bool {
        const security = self.security orelse return permission == .open;
        return switch (permission) {
            .open => true,
            .encrypted => security.encrypted,
            .authenticated => security.encrypted and security.authenticated,
        };
    }
    fn send_frame(self: *Host, cid: u16, payload: []const u8, guard: Guard) Error!void {
        if (cid == 4 and self.att_timed_out) return error.Timeout;
        if (payload.len > (if (cid == 6) @as(usize, 65) else gatt.mtu)) return error.Unsupported;
        // Protected frames (ATT at MTU 23, SMP keys of 17 bytes) fit in one
        // fragment, as initialize() requires 27-byte ACL buffers: the security
        // check before the first fragment covers the whole frame.
        if (guard.permission != .open and payload.len + 4 > self.acl_packet_size) return error.Unsupported;
        if (self.connection == null) return error.Disconnected;
        if (self.tx_count == self.tx.len) return error.NoBuffer;
        const slot = &self.tx[self.tx_count];
        slot.len = @intCast(payload.len + 4);
        slot.guard = guard;
        write16(&slot.bytes, @intCast(payload.len));
        write16(slot.bytes[2..], cid);
        @memcpy(slot.bytes[4..][0..payload.len], payload);
        self.tx_count += 1;
        // Credit waits pump RX. A nested response is queued behind the entire
        // current L2CAP SDU, never between its ACL continuation fragments.
        if (self.transmitting) return;
        self.transmitting = true;
        defer self.transmitting = false;
        // Frames can carry the local IRK: wipe every copy once it is sent or dropped.
        errdefer {
            for (&self.tx) |*slot_bytes| std.crypto.secureZero(u8, &slot_bytes.bytes);
            self.tx_count = 0;
        }
        var data: [259]u8 = undefined;
        defer std.crypto.secureZero(u8, &data);
        while (self.tx_count != 0) {
            var frame = self.tx[0];
            defer std.crypto.secureZero(u8, &frame.bytes);
            self.tx_count -= 1;
            std.mem.copyForwards(Tx, self.tx[0..self.tx_count], self.tx[1..][0..self.tx_count]);
            std.crypto.secureZero(u8, &self.tx[self.tx_count].bytes);
            const frame_cid = read16(frame.bytes[2..4]);
            var offset: usize = 0;
            const deadline = self.now() + procedure_timeout_ms;
            while (offset < frame.len) {
                while (self.acl_credits == 0) {
                    if (self.connection == null) return error.Disconnected;
                    try self.wait(deadline);
                }
                const handle = self.connection orelse return error.Disconnected;
                // A credit wait can process an encryption loss. A protected
                // frame is one fragment (checked when queued), so none of it
                // has been sent yet. An ATT response is still owed to its
                // request (Core v5.4 Vol 3 Part F §3.3.3): answer it with an
                // Error Response naming the strictest protected attribute it
                // would have disclosed.
                if (offset == 0 and !self.link_meets(frame.guard.permission)) {
                    self.withheld_protected +%= 1;
                    const refusal = frame.guard.refusal orelse break;
                    frame.len = 4 + refusal.len;
                    write16(&frame.bytes, refusal.len);
                    frame.bytes[4..][0..refusal.len].* = refusal;
                    frame.guard = .{};
                }
                // LE Host -> Controller starts are non-flushable (PB=00), unlike
                // Controller -> Host starts (PB=10). IDF v5.5.1 l2c_utils.c,
                // l2cu_set_acl_hci_header uses L2CAP_PKT_START_NON_FLUSHABLE for LE.
                const count = @min(self.acl_packet_size, frame.len - offset);
                write16(&data, handle | (if (offset == 0) @as(u16, 0) else 0x1000));
                write16(data[2..], @intCast(count));
                @memcpy(data[4..][0..count], frame.bytes[offset..][0..count]);
                self.acl_credits -= 1;
                self.transport.send_acl_fn(self.transport.context, data[0 .. count + 4]) catch |err| {
                    self.acl_credits += 1;
                    return err;
                };
                offset += count;
            }
            // Report only frames handed to the controller in full.
            if (frame_cid == 4 and offset == frame.len) if (self.on_att_packet) |callback| callback(self, true, frame.bytes[4..frame.len]);
        }
    }
    fn att(self: *Host, data: []const u8) Error!void {
        if (self.on_att_packet) |callback| callback(self, false, data);
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
            const disclosure = server.disclosure;
            if (response.len != 0) try self.send_frame(4, response, .{ .permission = disclosure.permission, .refusal = if (disclosure.permission == .open) null else disclosure.refusal() });
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
    att_server: ?gatt.Server = null,
    scanning: bool = false,
    advertising: bool = false,
    advertising_type: ?u8 = null,
    delayed_response_ms: u32 = 0,
    captured: [31]u8 = undefined,
    captured_len: usize = 0,
    last_command: [258]u8 = undefined,
    last_command_len: usize = 0,
    encryption_status: ?u8 = null,
    crossing_auth_req: ?u8 = null,
    bond_security_request: bool = false,
    fragments: [4][31]u8 = undefined,
    fragment_lengths: [4]usize = @splat(0),
    fragment_count: usize = 0,
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
        @memcpy(self.last_command[0..data.len], data);
        self.last_command_len = data.len;
        const opcode = read16(data);
        if (self.nop_first) {
            self.nop_first = false;
            try self.enqueue(.event, &.{ 0x0e, 3, 1, 0, 0 });
        }
        if (opcode == 0x1009) {
            try self.enqueue(.event, &.{ 0x0e, 10, 1, 9, 0x10, 0, 1, 2, 3, 4, 5, 6 });
            return;
        }
        if (opcode == 0x2019) {
            try self.enqueue(.event, &.{ 0x0f, 4, 0, 1, 0x19, 0x20 });
            if (self.crossing_auth_req) |auth_req| try self.enqueue(.acl, &.{ 7, 0x20, 6, 0, 2, 0, 6, 0, 0x0b, auth_req });
            if (self.encryption_status) |status| try self.enqueue(.event, &.{ 8, 4, status, 7, 0, if (status == 0) @as(u8, 1) else 0 });
            return;
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
            if (!self.reject_command) switch (opcode) {
                0x2006 => self.advertising_type = data[7],
                0x200c => self.scanning = data[3] == 1,
                0x200a => self.advertising = data[3] == 1,
                else => {},
            };
            var reply: [9]u8 = .{ 0x0e, 4, 1, data[0], data[1], if (self.reject_command) 0x0c else 0, 27, 0, 1 };
            const len: usize = if (opcode == 0x2002) 9 else 6;
            reply[1] = @intCast(len - 2);
            try self.enqueue(.event, reply[0..len]);
            if (opcode == 0x201a) {
                if (self.encryption_status) |status| try self.enqueue(.event, &.{ 8, 4, status, 7, 0, if (status == 0) @as(u8, 1) else 0 });
            }
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
            if (self.fragment_count < self.fragments.len) {
                @memcpy(self.fragments[self.fragment_count][0..data.len], data);
                self.fragment_lengths[self.fragment_count] = data.len;
                self.fragment_count += 1;
            }
            try self.enqueue(.event, &.{ 0x13, 5, 1, 7, 0, 1, 0 });
            if (self.bond_security_request and data.len == 10 and read16(data[6..8]) == 6 and data[8] == 0x0b)
                try self.enqueue(.event, &.{ 0x3e, 13, 5, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
            return;
        }
        if (self.att_server) |*server| {
            if (data.len < 8 or read16(data[6..8]) != 4) return error.InvalidPacket;
            var out: [gatt.mtu]u8 = undefined;
            const response = server.respond(data[8..], &out);
            try self.enqueue(.event, &.{ 0x13, 5, 1, 7, 0, 1, 0 });
            try self.acl_response(response, response.len > 2);
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

test "peripheral handoff disables scanning and restarts advertising without opening ATT" {
    var fixture: Fixture = .{};
    var host = Host.init(fixture.transport());
    try host.initialize();
    try host.advertise("MZ-SMP-TEST");
    host.server.?.permissions[gatt.value_handle - 1] = .encrypted;
    try host.scan(true);
    try std.testing.expect(fixture.scanning and fixture.advertising);
    try host.scan(false);
    try host.stop_advertising();
    try std.testing.expect(!fixture.scanning and !fixture.advertising);
    try host.set_advertising_name("MZ-SMP-READY");
    try std.testing.expectEqual(@as(u16, 0x2008), read16(&fixture.last_command));
    try std.testing.expectEqual(@as(u8, 9), fixture.last_command[12]); // complete local name
    try std.testing.expectEqualStrings("MZ-SMP-READY", fixture.last_command[13..25]);
    try std.testing.expectEqual(@as(?u8, 0x0f), host.server.?.permission_error(gatt.value_handle));
    try host.resume_advertising();
    try std.testing.expect(!fixture.scanning and fixture.advertising);
    try std.testing.expectEqual(@as(?u8, 0x0f), host.server.?.permission_error(gatt.value_handle));
    const commands = fixture.commands;
    try std.testing.expectError(error.InvalidName, host.set_advertising_name(""));
    try std.testing.expectError(error.InvalidName, host.set_advertising_name("this name is too long!"));
    try std.testing.expectEqual(commands, fixture.commands);
}

test "nonconnectable discovery hands off to protected connectable advertising" {
    var fixture: Fixture = .{};
    var host = Host.init(fixture.transport());
    try host.initialize();
    try host.advertise_nonconnectable(&.{ 2, 1, 6 });
    try host.scan(true);
    try std.testing.expect(fixture.scanning and fixture.advertising);
    try std.testing.expectEqual(@as(?u8, 3), fixture.advertising_type); // ADV_NONCONN_IND
    try std.testing.expect(host.server == null);
    try host.scan(false);
    try host.stop_advertising();
    try std.testing.expect(!fixture.scanning and !fixture.advertising);
    try host.configure_security(UnusedCrypto.config);
    try host.configure_advertising("MZ-SMP-READY");
    try std.testing.expect(!fixture.advertising);
    try std.testing.expectEqual(@as(?u8, 0), fixture.advertising_type); // ADV_IND
    host.server.?.permissions[gatt.value_handle - 1] = .encrypted;
    try host.resume_advertising();
    try std.testing.expect(!fixture.scanning and fixture.advertising);
    try std.testing.expectEqual(@as(?u8, 0x0f), host.server.?.permission_error(gatt.value_handle));
}

test "protected read decodes the server's unencrypted refusal, then permits encryption" {
    var fixture: Fixture = .{ .att_server = try gatt.Server.init("secure") };
    fixture.att_server.?.permissions[gatt.value_handle - 1] = .encrypted;
    var host = Host.init(fixture.transport());
    try host.initialize();
    host.connection = 7;
    const Trace = struct {
        fn packet(h: *const Host, tx: bool, pdu: []const u8) void {
            // Exercise the diagnostic callback with the original wire bytes,
            // including the ATT error rather than its mapped Zig error.
            if (tx) {
                std.testing.expectEqualSlices(u8, &.{ 0x0a, 6, 0 }, pdu) catch @panic("bad ATT TX trace");
            } else if (pdu[0] == 1) {
                std.testing.expectEqualSlices(u8, &.{ 1, 0x0a, 6, 0, 0x0f }, pdu) catch @panic("bad ATT RX trace");
            } else {
                std.testing.expectEqualSlices(u8, &.{0x0b}, pdu) catch @panic("bad ATT RX trace");
            }
            std.testing.expect(h.connection != null) catch @panic("missing trace connection");
        }
    };
    host.on_att_packet = Trace.packet;
    var out: [20]u8 = undefined;
    try std.testing.expectError(error.AttError, host.read(gatt.value_handle, &out));
    try std.testing.expectEqual(@as(u8, 0x0f), host.last_att_error);
    try std.testing.expectEqual(@as(u8, 0), host.last_hci_status);
    try std.testing.expectEqual(@as(?u16, 7), host.connection);
    fixture.att_server.?.encrypted = true;
    try std.testing.expectEqual(@as(usize, 0), try host.read(gatt.value_handle, &out));
    try std.testing.expectEqual(@as(u8, 0), host.last_att_error);
    try host.event(&.{ 8, 4, 0x06, 7, 0, 0 });
    try std.testing.expectEqual(@as(?u8, 0x06), host.last_encryption_status);
    try std.testing.expectEqual(@as(?u8, 0), host.last_encryption_enabled);
    // Preserve a malformed packet's header before parsing fails.
    try fixture.enqueue(.acl, &.{ 7, 0x20, 9, 0, 5, 0, 4, 0 });
    try std.testing.expectError(error.InvalidPacket, host.poll(1));
    try std.testing.expectEqual(wire.PacketKind.acl, host.last_packet.?.kind);
    try std.testing.expectEqualSlices(u8, &.{ 7, 0x20, 9, 0, 5, 0, 4, 0 }, &host.last_packet.?.header);
}

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

const UnusedCrypto = struct {
    fn random(_: ?*anyopaque, _: []u8) smp.Error!void {
        return error.CryptoFailed;
    }
    fn pair(_: ?*anyopaque) smp.Error!smp.KeyPair {
        return error.CryptoFailed;
    }
    fn dh(_: ?*anyopaque, _: [32]u8, _: smp.Point) smp.Error![32]u8 {
        return error.CryptoFailed;
    }
    const config: smp.Config = .{ .crypto = .{ .random_fn = random, .key_pair_fn = pair, .dh_fn = dh } };
};
const test_bond: smp.bonds.Bond = .{
    .peer = .{ 0, 6, 5, 4, 3, 2, 1 },
    .identity = .{ 0, 6, 5, 4, 3, 2, 1 },
    .ltk = smp.crypto.hex("0123456789abcdef0123456789abcdef"),
    .authenticated = true,
};
test "LTK Request replies and negative replies validate handle, Rand and EDIV" {
    var fixture: Fixture = .{};
    var host = Host.init(fixture.transport());
    host.connection = 7;
    host.security = smp.Session.init(UnusedCrypto.config, false, @splat(0), test_bond.peer);
    try std.testing.expect(host.security.?.restore(test_bond));
    const ltk_event = [_]u8{ 0x3e, 13, 5, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try host.event(&ltk_event);
    try host.service_security();
    try std.testing.expectEqual(@as(u16, 0x201a), read16(&fixture.last_command));
    try std.testing.expectEqualSlices(u8, &smp.crypto.reverse(16, test_bond.ltk), fixture.last_command[5..21]);
    var invalid = ltk_event;
    invalid[5] = 1;
    try host.event(&invalid);
    try host.service_security();
    try std.testing.expectEqual(@as(u16, 0x201b), read16(&fixture.last_command));
    invalid = ltk_event;
    invalid[13] = 1;
    try host.event(&invalid);
    try host.service_security();
    try std.testing.expectEqual(@as(u32, 2), host.negative_ltk_replies);
    invalid = ltk_event;
    invalid[3] = 8;
    const commands = fixture.commands;
    try host.event(&invalid);
    try host.service_security();
    try std.testing.expectEqual(commands, fixture.commands);
    host.security = null;
    try host.event(&ltk_event);
    try host.service_security();
    try std.testing.expectEqual(@as(u32, 3), host.negative_ltk_replies);
}
test "stored LTK reencrypts without SMP; encryption refresh failure revokes ATT access" {
    var fixture: Fixture = .{ .encryption_status = 0 };
    var host = Host.init(fixture.transport());
    host.connection = 7;
    host.server = try gatt.Server.init("secure");
    host.server.?.permissions[gatt.value_handle - 1] = .authenticated;
    host.security = smp.Session.init(UnusedCrypto.config, true, @splat(0), test_bond.peer);
    _ = host.security.?.restore(test_bond);
    try host.secure();
    try std.testing.expectEqual(@as(u16, 0x2019), read16(&fixture.last_command));
    try std.testing.expectEqualSlices(u8, &(@as([10]u8, @splat(0))), fixture.last_command[5..15]);
    try std.testing.expectEqualSlices(u8, &smp.crypto.reverse(16, test_bond.ltk), fixture.last_command[15..31]);
    try std.testing.expectEqual(@as(u32, 0), host.security.?.pairing_count);
    try std.testing.expectEqual(@as(?u8, null), host.server.?.permission_error(gatt.value_handle));
    try host.event(&.{ 0x30, 3, 0, 7, 0 });
    try std.testing.expect(host.server.?.encrypted);
    try host.event(&.{ 0x30, 3, 6, 7, 0 });
    try std.testing.expect(!host.server.?.encrypted and !host.server.?.authenticated);
    try std.testing.expectEqual(@as(?u8, 5), host.server.?.permission_error(gatt.value_handle));
    fixture.encryption_status = 6;
    host.security = smp.Session.init(UnusedCrypto.config, true, @splat(0), test_bond.peer);
    _ = host.security.?.restore(test_bond);
    try std.testing.expectError(error.SecurityFailed, host.secure());
}
test "bonded peripheral secure requests cached-key encryption and restores ATT access" {
    for ([_]bool{ false, true }) |authenticated| {
        var fixture: Fixture = .{ .capture_only = true, .bond_security_request = true, .encryption_status = 0 };
        var host = Host.init(fixture.transport());
        host.connection = 7;
        host.acl_capacity = 1;
        host.acl_credits = 1;
        host.server = try gatt.Server.init("secure");
        host.server.?.permissions[gatt.value_handle - 1] = .encrypted;
        host.security = smp.Session.init(UnusedCrypto.config, false, @splat(0), test_bond.peer);
        var saved = test_bond;
        saved.authenticated = authenticated;
        try std.testing.expect(host.security.?.restore(saved));
        try std.testing.expectEqual(@as(?u8, 0x0f), host.server.?.permission_error(gatt.value_handle));
        try host.secure();
        try std.testing.expectEqual(smp.State.complete, host.security.?.state);
        try std.testing.expect(host.security.?.encrypted and host.security.?.bonded);
        try std.testing.expectEqual(authenticated, host.security.?.authenticated);
        try std.testing.expectEqualSlices(u8, &saved.ltk, &host.security.?.derived.ltk);
        try std.testing.expectEqual(@as(u32, 0), host.security.?.pairing_count);
        try std.testing.expect(!host.security.?.save_bond);
        try std.testing.expectEqual(@as(usize, 1), fixture.fragment_count);
        try std.testing.expectEqual(@as(u8, 0x0b), fixture.captured[8]);
        try std.testing.expectEqual(@as(u16, 0x201a), read16(&fixture.last_command));
        try std.testing.expectEqual(@as(?u8, null), host.server.?.permission_error(gatt.value_handle));
        host.server.?.permissions[gatt.value_handle - 1] = .authenticated;
        try std.testing.expectEqual(@as(?u8, if (authenticated) null else 5), host.server.?.permission_error(gatt.value_handle));
    }
}
test "65-byte SMP public key fragments with credits and LE continuation flags" {
    var fixture: Fixture = .{ .capture_only = true };
    var host = Host.init(fixture.transport());
    host.connection = 7;
    host.acl_capacity = 1;
    host.acl_credits = 1;
    var payload: [65]u8 = @splat(0x5a);
    payload[0] = 0x0c;
    try host.send_fixed(6, &payload);
    try std.testing.expectEqual(@as(usize, 3), fixture.fragment_count);
    try std.testing.expectEqual(@as(u16, 7), read16(&fixture.fragments[0]));
    try std.testing.expectEqual(@as(u16, 0x1007), read16(&fixture.fragments[1]));
    try std.testing.expectEqual(@as(u16, 0x1007), read16(&fixture.fragments[2]));
    try std.testing.expectEqual(@as(u16, 65), read16(fixture.fragments[0][4..]));
    try std.testing.expectEqual(@as(u16, 6), read16(fixture.fragments[0][6..]));
    var reassembled: [69]u8 = undefined;
    var offset: usize = 0;
    for (0..3) |i| {
        const len = fixture.fragment_lengths[i] - 4;
        @memcpy(reassembled[offset..][0..len], fixture.fragments[i][4..][0..len]);
        offset += len;
    }
    try std.testing.expectEqualSlices(u8, &payload, reassembled[4..69]);
}

test "Security Request AuthReq controls cached bond reuse and authenticated upgrade" {
    for ([_]bool{ false, true }) |authenticated| {
        for ([_]u8{ 0x09, 0x0d }) |auth_req| {
            var fixture: Fixture = .{};
            var host = Host.init(fixture.transport());
            host.connection = 7;
            host.security = smp.Session.init(UnusedCrypto.config, true, @splat(0), test_bond.peer);
            var saved = test_bond;
            saved.authenticated = authenticated;
            try std.testing.expect(host.security.?.restore(saved));
            try host.acl(&.{ 7, 0x20, 6, 0, 2, 0, 6, 0, 0x0b, auth_req });
            const security = &host.security.?;
            if (auth_req & 4 != 0 and !authenticated) {
                try std.testing.expect(!security.start_encryption);
                try std.testing.expectEqual(smp.State.response, security.state);
                try std.testing.expect(security.config.require_authenticated);
                try std.testing.expect(!security.bonded and !security.authenticated);
                try std.testing.expect(std.mem.allEqual(u8, &security.derived.ltk, 0));
                const request = security.pop().?;
                try std.testing.expectEqual(@as(u8, 1), request.bytes[0]);
                try std.testing.expectEqual(@as(u8, 4), request.bytes[3] & 4);
            } else {
                try std.testing.expect(security.start_encryption);
                try std.testing.expectEqual(smp.State.complete, security.state);
                try std.testing.expectEqualSlices(u8, &saved.ltk, &security.derived.ltk);
                try std.testing.expectEqual(@as(u3, 0), security.queued);
            }
        }
    }
}

test "central secure survives crossing Security Request before Encryption Change" {
    for ([_]bool{ false, true }) |authenticated| {
        var fixture: Fixture = .{ .encryption_status = 0, .crossing_auth_req = if (authenticated) 0x0d else 0x09 };
        var host = Host.init(fixture.transport());
        host.connection = 7;
        host.server = try gatt.Server.init("secure");
        host.server.?.permissions[gatt.value_handle - 1] = .encrypted;
        host.security = smp.Session.init(UnusedCrypto.config, true, @splat(0), test_bond.peer);
        var saved = test_bond;
        saved.authenticated = authenticated;
        try std.testing.expect(host.security.?.restore(saved));
        try host.secure();
        try std.testing.expectEqual(smp.State.complete, host.security.?.state);
        try std.testing.expect(host.security.?.encrypted and host.security.?.bonded);
        try std.testing.expectEqual(authenticated, host.security.?.authenticated);
        try std.testing.expectEqualSlices(u8, &saved.ltk, &host.security.?.derived.ltk);
        try std.testing.expectEqual(@as(u32, 0), host.security.?.pairing_count);
        try std.testing.expectEqual(@as(?u8, null), host.server.?.permission_error(gatt.value_handle));
        try std.testing.expectEqual(@as(usize, 1), fixture.commands);
    }
}

test "address connection preserves selected wire address and exact address type" {
    for ([_]u8{ 0, 1 }) |address_type| {
        var fixture: Fixture = .{};
        var host = Host.init(fixture.transport());
        try host.initialize();
        const selected: Advertisement = .{ .event_type = 0, .address_type = address_type, .address = .{ 9, 8, 7, 6, 5, 4 }, .rssi = -25, .len = 0, .bytes = @splat(0) };
        try host.connect_address(selected, 1000);
        try std.testing.expectEqual(@as(u16, 0x200d), read16(&fixture.last_command));
        try std.testing.expectEqual(address_type, fixture.last_command[8]);
        try std.testing.expectEqualSlices(u8, &selected.address, fixture.last_command[9..15]);
        try std.testing.expectEqual(@as(u8, 0), fixture.last_command[15]); // own public address
    }
}

const FailingStore = struct {
    fail_load: bool = false,
    saves: u32 = 0,
    fn load(context: *anyopaque, _: smp.crypto.Address) smp.bonds.Error!?smp.bonds.Bond {
        const self: *FailingStore = @ptrCast(@alignCast(context));
        if (self.fail_load) return error.StorageFailed;
        return null;
    }
    fn save(context: *anyopaque, _: smp.bonds.Bond) smp.bonds.Error!void {
        const self: *FailingStore = @ptrCast(@alignCast(context));
        self.saves += 1;
        return error.StorageFailed;
    }
    fn remove(_: *anyopaque, _: smp.crypto.Address) smp.bonds.Error!void {}
    fn config(self: *FailingStore) smp.Config {
        var result = UnusedCrypto.config;
        result.store = .{ .context = self, .load_fn = load, .save_fn = save, .remove_fn = remove };
        return result;
    }
};
test "a failed bond save is reported once and never stalls packet processing" {
    var store: FailingStore = .{};
    var fixture: Fixture = .{ .capture_only = true };
    var host = Host.init(fixture.transport());
    host.connection = 7;
    host.server = try gatt.Server.init("secure");
    host.security = smp.Session.init(store.config(), false, @splat(0), test_bond.peer);
    try std.testing.expect(host.security.?.restore(test_bond));
    try host.security.?.encryption_changed(true, 0);
    host.security.?.bonded = false;
    host.security.?.save_bond = true;
    try fixture.enqueue(.event, &.{ 5, 4, 0, 7, 0, 0x13 });
    try std.testing.expectError(error.StorageFailed, host.poll(1));
    try std.testing.expectEqual(@as(u32, 1), store.saves);
    try std.testing.expect(host.server.?.encrypted and host.server.?.authenticated);
    try std.testing.expect(!host.security.?.bonded);
    try host.poll(1); // The queued disconnect is consumed on the next poll.
    try std.testing.expectEqual(@as(?u16, null), host.connection);
    try std.testing.expectEqual(@as(?u8, 0x13), host.disconnect_reason);
    try std.testing.expectEqual(@as(u32, 1), store.saves);
}
test "an unreadable bond store fails the connection's pairing policy closed" {
    var store: FailingStore = .{ .fail_load = true };
    var fixture: Fixture = .{ .capture_only = true };
    var host = Host.init(fixture.transport());
    try host.configure_security(store.config());
    host.server = try gatt.Server.init("secure");
    host.server.?.subscribed = true;
    // LE Connection Complete as peripheral (role 1) from a public address.
    try std.testing.expectError(error.StorageFailed, host.event(&.{ 0x3e, 19, 1, 0, 7, 0, 1, 0, 1, 2, 3, 4, 5, 6, 24, 0, 0, 0, 0, 1, 0 }));
    try std.testing.expectEqual(@as(?u16, 7), host.connection);
    try std.testing.expect(!host.server.?.subscribed);
    const security = &host.security.?;
    try std.testing.expect(security.config.require_authenticated and !security.bonded);
    // A Just Works Pairing Request is refused rather than accepted in RAM.
    try host.acl(&.{ 7, 0x20, 11, 0, 7, 0, 6, 0, 1, 3, 0, 8, 16, 0, 0 });
    try std.testing.expectEqual(smp.State.failed, security.state);
    try std.testing.expectEqual(@as(?u8, 3), security.failure);
}
test "a stale LTK Request does not hold back queued SMP PDUs" {
    var fixture: Fixture = .{ .capture_only = true };
    var host = Host.init(fixture.transport());
    host.connection = 7;
    host.acl_capacity = 1;
    host.acl_credits = 1;
    host.security = smp.Session.init(UnusedCrypto.config, true, @splat(0), test_bond.peer);
    try host.security.?.start(0);
    host.ltk_request = .{ .handle = 8, .valid = true };
    try host.service_security();
    try std.testing.expectEqual(@as(?@TypeOf(host.ltk_request.?), null), host.ltk_request);
    try std.testing.expectEqual(@as(usize, 1), fixture.fragment_count);
    try std.testing.expectEqual(@as(u8, 1), fixture.captured[8]); // Pairing Request
    try std.testing.expectEqual(@as(usize, 0), fixture.commands);
}
test "ACL continuation diagnostics and sent SMP frames retain no payload bytes" {
    var fixture: Fixture = .{ .capture_only = true };
    var host = Host.init(fixture.transport());
    host.connection = 7;
    try fixture.enqueue(.acl, &.{ 7, 0x10, 4, 0, 0xaa, 0xbb, 0xcc, 0xdd });
    try std.testing.expectError(error.InvalidPacket, host.poll(1));
    try std.testing.expectEqualSlices(u8, &.{ 7, 0x10, 4, 0, 0, 0, 0, 0 }, &host.last_packet.?.header);
    host.acl_capacity = 1;
    host.acl_credits = 1;
    const irk: smp.crypto.Key = @splat(0x5a);
    try host.send_fixed(6, &([1]u8{8} ++ irk));
    try host.send_fixed(6, &([1]u8{8} ++ irk));
    for (host.tx) |slot| try std.testing.expect(std.mem.indexOf(u8, &slot.bytes, &irk) == null);
}
test "encryption lost during an ACL credit wait drops queued identity keys" {
    var fixture: Fixture = .{ .capture_only = true };
    var host = Host.init(fixture.transport());
    host.connection = 7;
    // One packet is still in the controller: no credit until it completes.
    host.acl_capacity = 1;
    host.acl_credits = 0;
    var config = UnusedCrypto.config;
    config.irk = @splat(0x5a);
    host.security = smp.Session.init(config, false, @splat(0), test_bond.peer);
    const security = &host.security.?;
    // A responder after both DHKey checks, owing its IRK and identity address.
    security.state = .encryption;
    security.request = .{ 1, 3, 0, 9, 16, 0, 2 };
    security.response = .{ 2, 3, 0, 9, 16, 0, 2 };
    security.deadline = fixture.clock_ms + 30_000;
    try fixture.enqueue(.event, &.{ 8, 4, 0, 7, 0, 1 }); // encryption on
    try fixture.enqueue(.event, &.{ 8, 4, 0, 7, 0, 0 }); // lost while waiting
    try fixture.enqueue(.event, &.{ 0x13, 5, 1, 7, 0, 1, 0 }); // credit returns
    try host.poll(1);
    try std.testing.expectEqual(smp.State.failed, security.state);
    try std.testing.expectEqual(@as(u3, 0), security.queued);
    try std.testing.expectEqual(@as(usize, 0), fixture.fragment_count);
    try std.testing.expectEqual(@as(u32, 1), host.withheld_protected);
    try std.testing.expectEqual(@as(u16, 1), host.acl_credits);
}
/// ATT packets the host reported sending, for the diagnostics callback tests.
const TxTrace = struct {
    var count: usize = 0;
    var last: [gatt.mtu]u8 = undefined;
    var len: usize = 0;
    fn packet(_: *const Host, tx: bool, pdu: []const u8) void {
        if (!tx) return;
        count += 1;
        len = pdu.len;
        @memcpy(last[0..pdu.len], pdu);
    }
};
test "security lost during an ACL credit wait answers a protected ATT read with an Error Response" {
    // The link stays up in both cases: a failed encryption event, and an
    // Encryption Change the session does not expect (an old-key completion
    // racing a fresh pairing), which revokes encryption.
    const Loss = enum { failed, unexpected };
    for ([_]Loss{ .failed, .unexpected }) |loss| {
        for ([_]gatt.Permission{ .encrypted, .authenticated }) |permission| {
            var fixture: Fixture = .{ .capture_only = true };
            var host = Host.init(fixture.transport());
            host.connection = 7;
            host.acl_capacity = 1;
            host.acl_credits = 0;
            host.on_att_packet = TxTrace.packet;
            TxTrace.count = 0;
            host.server = try gatt.Server.init("secure");
            host.server.?.permissions[gatt.value_handle - 1] = permission;
            host.server.?.value_len = 2;
            host.server.?.value[0..2].* = .{ 0xa5, 0x5a };
            host.security = smp.Session.init(UnusedCrypto.config, false, @splat(0), test_bond.peer);
            var bond = test_bond;
            bond.authenticated = true;
            try std.testing.expect(host.security.?.restore(bond));
            try host.security.?.encryption_changed(true, 0);
            if (loss == .unexpected) {
                // A fresh pairing has retired the restored key.
                host.security.?.state = .public_key;
                host.security.?.bonded = false;
                host.security.?.deadline = fixture.clock_ms + 30_000;
            }
            host.sync_server();
            try fixture.acl_response(&.{ 0x0a, gatt.value_handle, 0 }, false);
            try fixture.enqueue(.event, &.{ 8, 4, 0, 7, 0, if (loss == .failed) 0 else 1 });
            try fixture.enqueue(.event, &.{ 0x13, 5, 1, 7, 0, 1, 0 });
            try host.poll(1);
            try std.testing.expect(!host.server.?.encrypted);
            try std.testing.expectEqual(@as(?u16, 7), host.connection);
            try std.testing.expectEqual(@as(u32, 1), host.withheld_protected);
            // The request is answered, so the peer's ATT bearer stays usable.
            const code: u8 = if (permission == .authenticated) 0x05 else 0x0f;
            const refusal = [_]u8{ 1, 0x0a, gatt.value_handle, 0, code };
            try std.testing.expectEqual(@as(usize, 1), fixture.fragment_count);
            try std.testing.expectEqualSlices(u8, &(.{ 7, 0, 9, 0, 5, 0, 4, 0 } ++ refusal), fixture.captured[0..13]);
            try std.testing.expectEqual(@as(usize, 1), TxTrace.count);
            try std.testing.expectEqualSlices(u8, &refusal, TxTrace.last[0..TxTrace.len]);
            // An open attribute's response still goes out on the unencrypted link.
            try fixture.acl_response(&.{ 0x0a, 5, 0 }, false);
            try host.poll(1); // the credit for the Error Response
            try host.poll(1);
            try std.testing.expectEqual(@as(usize, 2), fixture.fragment_count);
            try std.testing.expectEqual(@as(u8, 0x0b), fixture.captured[8]);
        }
    }
}
test "security lost during an ACL credit wait drops a protected notification unreported" {
    var fixture: Fixture = .{ .capture_only = true };
    var host = Host.init(fixture.transport());
    host.connection = 7;
    host.acl_capacity = 1;
    host.acl_credits = 0;
    host.on_att_packet = TxTrace.packet;
    TxTrace.count = 0;
    host.security = smp.Session.init(UnusedCrypto.config, false, @splat(0), test_bond.peer);
    try std.testing.expect(host.security.?.restore(test_bond));
    try host.security.?.encryption_changed(true, 0);
    try fixture.enqueue(.event, &.{ 8, 4, 0, 7, 0, 0 });
    try fixture.enqueue(.event, &.{ 0x13, 5, 1, 7, 0, 1, 0 });
    try host.send_frame(4, &.{ 0x1b, gatt.notify_handle, 0, 1, 0, 0, 0 }, .{ .permission = .encrypted });
    try std.testing.expectEqual(@as(usize, 0), fixture.fragment_count);
    try std.testing.expectEqual(@as(u32, 1), host.withheld_protected);
    try std.testing.expectEqual(@as(usize, 0), TxTrace.count);
    try std.testing.expectEqual(@as(u16, 1), host.acl_credits);
    // A protected frame longer than one fragment is refused when queued.
    try std.testing.expectError(error.Unsupported, host.send_frame(6, &([1]u8{0x0c} ++ @as([64]u8, @splat(0))), .{ .permission = .encrypted }));
}
