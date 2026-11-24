//! ESP-NOW session implementation. Target and host tests supply the blob/platform.
const std = @import("std");
const mock = @import("espnow_test_backend.zig");
const state = @import("espnow_state.zig");
pub const Error = state.Error;
pub const Mac = state.Mac;
pub const Key = state.Key;
pub const Peer = state.Peer;
pub const Frame = state.Frame;
pub const Delivery = state.Delivery;
pub const broadcast = state.broadcast;
pub const max_payload = state.max_payload;
pub const receive_capacity = state.capacity;
pub const payload_limit = state.payload_limit;
pub const Counts = struct { total: usize, encrypted: usize };

pub fn Driver(comptime platform: type) type {
    return struct {
        const microzig = platform.microzig;
        const c = platform.c;
        const wifi = platform.wifi;
        // C callbacks have no context argument. Only this routing pointer is global;
        // all queues and completion state belong to the caller. Protected by critical sections.
        // See ARCHITECTURE.md: the context-free callback ABI singleton exception
        // also covers the neighboring IEEE 802.15.4 radio owner.
        var owner: ?*Session = null;

        pub const Session = struct {
            queue: state.State = .{},
            version: u32 = 0,
            max_payload_len: usize = 0,

            /// Initialize in place, keeping this address valid until deinit succeeds.
            pub fn init(self: *Session) Error!void {
                if (comptime microzig.options.hal.radio.ble)
                    @compileError("ESP-NOW requires Wi-Fi; exclusive BLE mode is selected");
                if (microzig.options.hal.radio.protocol != .wifi) return error.UnsupportedRadioProtocol;
                if (!wifi.get_sta_state().is_started() and wifi.get_ap_state() != .started) return error.WifiNotStarted;
                {
                    const cs = microzig.interrupt.enter_critical_section();
                    defer cs.leave();
                    if (owner != null) return error.AlreadyInitialized;
                    self.* = .{};
                    owner = self;
                }
                errdefer {
                    const cs = microzig.interrupt.enter_critical_section();
                    defer cs.leave();
                    owner = null;
                }
                try state.check(c.esp_now_init());
                errdefer rollback_init();
                try state.check(c.esp_now_get_version(&self.version));
                self.max_payload_len = try payload_limit(self.version);
                try state.check(c.esp_now_register_recv_cb(receive_callback));
                try state.check(c.esp_now_register_send_cb(send_callback));
            }

            /// Returns Busy without changing ownership until an outstanding send completes.
            /// Then discards queued frames and any unpolled delivery. The handle remains
            /// valid if teardown fails. Call from the single owning task, as for send.
            pub fn deinit(self: *Session) Error!void {
                try self.require_owner();
                {
                    const cs = microzig.interrupt.enter_critical_section();
                    defer cs.leave();
                    // esp-wifi-sys 7623c8d: mt_deinit unregisters callbacks, but
                    // ppUnregisterTxCallback does not drain outstanding transmissions.
                    // The callback has no session token: retain routing until completion
                    // so an old send can never complete a new owner's send.
                    if (self.queue.pending and self.queue.completion == null) return error.Busy;
                    owner = null;
                }
                state.check(c.esp_now_deinit()) catch |err| {
                    const cs = microzig.interrupt.enter_critical_section();
                    defer cs.leave();
                    owner = self;
                    return err;
                };
                self.* = .{};
            }

            fn require_owner(self: *Session) Error!void {
                const cs = microzig.interrupt.enter_critical_section();
                defer cs.leave();
                if (owner != self) return error.NotInitialized;
            }

            pub fn set_pmk(self: *Session, key: Key) Error!void {
                try self.require_owner();
                try state.check(c.esp_now_set_pmk(&key));
            }
            pub fn set_wake_window(self: *Session, milliseconds: u16) Error!void {
                try self.require_owner();
                try state.check(c.esp_now_set_wake_window(milliseconds));
            }
            pub fn add_peer(self: *Session, peer: Peer) Error!void {
                try self.require_owner();
                var raw = try encode_peer(peer);
                try state.check(c.esp_now_add_peer(&raw));
            }
            pub fn modify_peer(self: *Session, peer: Peer) Error!void {
                try self.require_owner();
                var raw = try encode_peer(peer);
                try state.check(c.esp_now_mod_peer(&raw));
            }
            pub fn remove_peer(self: *Session, address: Mac) Error!void {
                try self.require_owner();
                try state.check(c.esp_now_del_peer(&address));
            }
            pub fn get_peer(self: *Session, address: Mac) Error!Peer {
                try self.require_owner();
                var raw: c.esp_now_peer_info_t = undefined;
                try state.check(c.esp_now_get_peer(&address, &raw));
                return decode_peer(raw);
            }
            pub fn has_peer(self: *Session, address: Mac) Error!bool {
                try self.require_owner();
                return c.esp_now_is_peer_exist(&address);
            }
            pub fn peer_count(self: *Session) Error!Counts {
                try self.require_owner();
                var raw: c.esp_now_peer_num_t = undefined;
                try state.check(c.esp_now_get_peer_num(&raw));
                if (raw.total_num < 0 or raw.encrypt_num < 0) return error.Internal;
                return .{ .total = @intCast(raw.total_num), .encrypted = @intCast(raw.encrypt_num) };
            }

            /// Nonblocking, one destination (including broadcast). Busy until the previous
            /// delivery is polled. The blob copies payload before returning. Its success
            /// callback confirms MAC delivery, not application acceptance or decryption.
            pub fn send(self: *Session, address: Mac, payload: []const u8) Error!void {
                try self.require_owner();
                {
                    const cs = microzig.interrupt.enter_critical_section();
                    defer cs.leave();
                    try self.queue.begin_send(payload.len, self.max_payload_len);
                }
                state.check(c.esp_now_send(&address, payload.ptr, payload.len)) catch |err| {
                    const cs = microzig.interrupt.enter_critical_section();
                    defer cs.leave();
                    self.queue.pending = false;
                    self.queue.completion = null;
                    return err;
                };
            }
            pub fn poll_delivery(self: *Session) Error!?Delivery {
                try self.require_owner();
                const cs = microzig.interrupt.enter_critical_section();
                defer cs.leave();
                return self.queue.take_delivery();
            }
            /// Copies into caller storage. Full queue drops newest; existing frames survive.
            pub fn poll_receive(self: *Session, out: *Frame) Error!bool {
                try self.require_owner();
                const cs = microzig.interrupt.enter_critical_section();
                defer cs.leave();
                return self.queue.pop(out);
            }
            pub fn dropped_frames(self: *Session) Error!u32 {
                try self.require_owner();
                const cs = microzig.interrupt.enter_critical_section();
                defer cs.leave();
                return self.queue.dropped;
            }
        };

        fn rollback_init() void {
            // IDF documents deinit as infallible; retain diagnostics if the blob disagrees.
            state.check(c.esp_now_deinit()) catch |err| std.log.err("ESP-NOW init rollback: {t}", .{err});
        }
        fn encode_peer(peer: Peer) Error!c.esp_now_peer_info_t {
            try peer.validate();
            return .{ .peer_addr = peer.address, .channel = peer.channel, .ifidx = if (peer.interface == .sta) c.WIFI_IF_STA else c.WIFI_IF_AP, .lmk = peer.lmk orelse @splat(0), .encrypt = peer.lmk != null, .priv = null };
        }
        fn decode_peer(raw: c.esp_now_peer_info_t) Error!Peer {
            return .{ .address = raw.peer_addr, .channel = raw.channel, .interface = switch (raw.ifidx) {
                c.WIFI_IF_STA => .sta,
                c.WIFI_IF_AP => .ap,
                else => return error.Internal,
            }, .lmk = if (raw.encrypt) raw.lmk else null };
        }
        fn receive_callback(info: [*c]const c.esp_now_recv_info_t, data: [*c]const u8, len: c_int) callconv(.c) void {
            if (info == null or data == null or len < 0 or info.*.src_addr == null or info.*.des_addr == null) return;
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            const session = owner orelse return;
            // IDF v5.5.1 wifi_pkt_rx_ctrl_t on C3/C6 starts with signed rssi:8.
            // Translate-C makes the bitfield struct opaque; read that first octet only.
            const rssi: ?i8 = if (info.*.rx_ctrl != null) @as(*const i8, @ptrCast(info.*.rx_ctrl)).* else null;
            session.queue.receive(info.*.src_addr[0..6].*, info.*.des_addr[0..6].*, rssi, data[0..@intCast(len)]);
        }
        fn send_callback(_: [*c]const c.esp_now_send_info_t, status: c.esp_now_send_status_t) callconv(.c) void {
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            if (owner) |session| {
                if (session.queue.pending) session.queue.completion = if (status == c.ESP_NOW_SEND_SUCCESS) .success else .failure;
            }
        }
    };
}

test "peer CRUD uses the authoritative blob table and preserves interface, channel, keys" {
    mock.reset();
    var session: Driver(mock).Session = .{};
    try session.init();
    defer session.deinit() catch unreachable;
    try session.add_peer(.{ .address = broadcast });
    try std.testing.expectError(error.InvalidArgument, session.add_peer(.{ .address = broadcast, .lmk = @splat(1) }));
    const address: Mac = .{ 2, 1, 2, 3, 4, 5 };
    try session.add_peer(.{ .address = address });
    try std.testing.expectError(error.PeerExists, session.add_peer(.{ .address = address }));
    try session.modify_peer(.{ .address = address, .channel = 11, .interface = .ap, .lmk = @splat(42) });
    const peer = try session.get_peer(address);
    try std.testing.expectEqual(@as(u8, 11), peer.channel);
    try std.testing.expectEqual(state.Interface.ap, peer.interface);
    try std.testing.expectEqual(@as(Key, @splat(42)), peer.lmk.?);
    try std.testing.expect(try session.has_peer(broadcast));
    try std.testing.expectEqualDeep(Counts{ .total = 2, .encrypted = 1 }, try session.peer_count());
    try session.remove_peer(address);
    try std.testing.expect(!try session.has_peer(address));
    try std.testing.expectError(error.PeerNotFound, session.get_peer(address));
    try std.testing.expectError(error.PeerNotFound, session.remove_peer(address));
    try std.testing.expectError(error.PeerNotFound, session.modify_peer(.{ .address = address }));
    try std.testing.expectEqualDeep(Counts{ .total = 1, .encrypted = 0 }, try session.peer_count());
    for (0..19) |i| try session.add_peer(.{ .address = .{ 2, 0, 0, 0, 0, @intCast(i + 1) } });
    try std.testing.expectError(error.PeerTableFull, session.add_peer(.{ .address = address }));
}

test "ownership, start requirement, init rollback, and late callback after deinit" {
    mock.reset();
    var session: Driver(mock).Session = .{};
    try std.testing.expectError(error.NotInitialized, session.peer_count());
    mock.started = false;
    try std.testing.expectError(error.WifiNotStarted, session.init());
    mock.started = true;
    mock.register_error = 0x306a;
    try std.testing.expectError(error.Internal, session.init());
    try std.testing.expect(!mock.initialized);
    mock.register_error = 0;
    try session.init();
    var second: Driver(mock).Session = .{};
    try std.testing.expectError(error.AlreadyInitialized, second.init());
    try std.testing.expectError(error.AlreadyInitialized, session.init());
    try session.add_peer(.{ .address = broadcast });
    try session.deinit();
    Driver(mock).send_callback(null, mock.ESP_NOW_SEND_SUCCESS);
    try std.testing.expectError(error.NotInitialized, session.poll_delivery());
    try second.init();
    try std.testing.expectEqualDeep(Counts{ .total = 0, .encrypted = 0 }, try second.peer_count());
    try second.deinit();
}

test "send immediate errors release reservation; callback result survives receive overflow" {
    mock.reset();
    var session: Driver(mock).Session = .{};
    try session.init();
    defer session.deinit() catch unreachable;
    try std.testing.expectError(error.PeerNotFound, session.send(broadcast, "x"));
    try session.add_peer(.{ .address = broadcast });
    try std.testing.expectError(error.InvalidArgument, session.send(broadcast, ""));
    try session.send(broadcast, "x");
    try std.testing.expectError(error.Busy, session.send(broadcast, "x"));
    var source: Mac = .{ 2, 0, 0, 0, 0, 1 };
    var destination = broadcast;
    var info: mock.esp_now_recv_info_t = .{ .src_addr = &source, .des_addr = &destination, .rx_ctrl = null };
    for (0..receive_capacity + 1) |_| Driver(mock).receive_callback(&info, "payload", 7);
    try std.testing.expectEqual(@as(u32, 1), try session.dropped_frames());
    try std.testing.expectEqual(Delivery.success, (try session.poll_delivery()).?);
    mock.delivery = 1;
    try session.send(broadcast, "x");
    try std.testing.expectEqual(Delivery.failure, (try session.poll_delivery()).?);
    var out: Frame = undefined;
    try std.testing.expect(try session.poll_receive(&out));
    try std.testing.expectEqual(source, out.source);
    try std.testing.expectEqual(destination, out.destination);
    try std.testing.expect(out.rssi == null);
    try std.testing.expectEqualStrings("payload", out.payload());
    while (try session.poll_receive(&out)) {}
    var rssi: i8 = -73;
    info.rx_ctrl = &rssi;
    const maximum: [max_payload]u8 = @splat(0xa5);
    Driver(mock).receive_callback(&info, &maximum, maximum.len);
    try std.testing.expect(try session.poll_receive(&out));
    try std.testing.expectEqual(@as(?i8, -73), out.rssi);
    try std.testing.expectEqualSlices(u8, &maximum, out.payload());
}

test "IEEE 802.15.4 selection rejects ESP-NOW before touching the blob" {
    const platform = struct {
        pub const c = mock;
        pub const wifi = mock.wifi;
        pub const microzig = struct {
            pub const interrupt = mock.microzig.interrupt;
            pub const options = .{ .hal = .{ .radio = .{ .ble = false, .protocol = .ieee802154 } } };
        };
    };
    mock.reset();
    var session: Driver(platform).Session = .{};
    try std.testing.expectError(error.UnsupportedRadioProtocol, session.init());
    try std.testing.expect(!mock.initialized);
}

test "delayed completion prevents teardown and reuse until the old send completes" {
    mock.reset();
    mock.delay_completion = true;
    var first: Driver(mock).Session = .{};
    var second: Driver(mock).Session = .{};
    try first.init();
    try first.add_peer(.{ .address = broadcast });
    mock.delivery = 1;
    try first.send(broadcast, "A");
    try std.testing.expectError(error.Busy, first.deinit());
    try std.testing.expect(mock.initialized);
    try std.testing.expectError(error.AlreadyInitialized, second.init());
    try std.testing.expectError(error.NotInitialized, second.send(broadcast, "B"));
    try std.testing.expectError(error.Busy, first.send(broadcast, "A again"));
    try std.testing.expect(try first.poll_delivery() == null);

    // The delayed A completion must still reach A, not a new owner.
    mock.complete_send();
    try std.testing.expectEqual(Delivery.failure, (try first.poll_delivery()).?);
    try first.deinit();
    try second.init();
    try second.add_peer(.{ .address = broadcast });
    mock.delivery = 0;
    try second.send(broadcast, "B");
    try std.testing.expect(try second.poll_delivery() == null);
    try std.testing.expectError(error.Busy, second.send(broadcast, "B again"));
    try std.testing.expectError(error.Busy, second.deinit());
    mock.complete_send();
    try std.testing.expectEqual(Delivery.success, (try second.poll_delivery()).?);

    // A completed delivery need not be polled before teardown.
    try second.send(broadcast, "last");
    mock.complete_send();
    try second.deinit();
}
