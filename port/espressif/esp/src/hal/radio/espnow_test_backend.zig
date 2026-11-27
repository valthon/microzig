//! Host-only deterministic substitute for the blob, for session contract tests.
const std = @import("std");
pub const c = @This();
pub const microzig = struct {
    pub const options = .{ .hal = .{ .radio = .{ .radios = .{ .ble = false, .wifi = true } } } };
    pub const interrupt = struct {
        pub fn enter_critical_section() Section {
            return .{};
        }
        const Section = struct {
            pub fn leave(_: Section) void {}
        };
    };
};
pub const wifi = struct {
    const Sta = enum {
        stopped,
        started,
        pub fn is_started(self: @This()) bool {
            return self == .started;
        }
    };
    pub const Wifi = struct {
        started: bool,

        pub fn get_sta_state(self: *const Wifi) Sta {
            return if (self.started) .started else .stopped;
        }

        pub fn get_ap_state(_: *const Wifi) enum { stopped, started } {
            return .stopped;
        }
    };
};
pub const WIFI_IF_STA = 0;
pub const WIFI_IF_AP = 1;
pub const ESP_NOW_SEND_SUCCESS = 0;
pub const esp_now_send_status_t = c_uint;
pub const esp_now_send_info_t = extern struct { unused: u8 };
pub const esp_now_recv_info_t = extern struct { src_addr: [*c]u8, des_addr: [*c]u8, rx_ctrl: ?*anyopaque };
pub const esp_now_peer_info_t = extern struct { peer_addr: [6]u8, lmk: [16]u8, channel: u8, ifidx: c_uint, encrypt: bool, priv: ?*anyopaque };
pub const esp_now_peer_num_t = extern struct { total_num: c_int, encrypt_num: c_int };
const Receive = *const fn ([*c]const esp_now_recv_info_t, [*c]const u8, c_int) callconv(.c) void;
const Send = *const fn ([*c]const esp_now_send_info_t, esp_now_send_status_t) callconv(.c) void;
var peers: [20]?esp_now_peer_info_t = @splat(null);
pub var initialized = false;
pub var register_error: i32 = 0;
pub var delivery: c_uint = 0;
pub var delay_completion = false;
var pending_delivery: ?c_uint = null;
var send_cb: ?Send = null;
var receive_cb: ?Receive = null;
pub var in_callback = false;
pub fn reset() void {
    peers = @splat(null);
    initialized = false;
    register_error = 0;
    delivery = 0;
    delay_completion = false;
    pending_delivery = null;
    in_callback = false;
    receive_cb = null;
    send_cb = null;
}
pub fn esp_now_init() i32 {
    initialized = true;
    return 0;
}
pub fn esp_now_deinit() i32 {
    peers = @splat(null);
    initialized = false;
    receive_cb = null;
    send_cb = null;
    return 0;
}
pub fn esp_now_get_version(version: *u32) i32 {
    version.* = 2;
    return 0;
}
pub fn esp_now_register_recv_cb(cb: Receive) i32 {
    if (register_error == 0) receive_cb = cb;
    return register_error;
}
pub fn esp_now_register_send_cb(cb: Send) i32 {
    if (register_error == 0) send_cb = cb;
    return register_error;
}
pub fn esp_now_set_pmk(_: *const [16]u8) i32 {
    return 0;
}
pub fn esp_now_set_wake_window(_: u16) i32 {
    return 0;
}
fn index(address: *const [6]u8) ?usize {
    for (peers, 0..) |peer, i| if (peer) |value| {
        if (std.mem.eql(u8, &value.peer_addr, address)) return i;
    };
    return null;
}
pub fn esp_now_add_peer(peer: *const esp_now_peer_info_t) i32 {
    if (index(&peer.peer_addr) != null) return 0x306b;
    for (&peers) |*entry| if (entry.* == null) {
        entry.* = peer.*;
        return 0;
    };
    return 0x3068;
}
pub fn esp_now_mod_peer(peer: *const esp_now_peer_info_t) i32 {
    const i = index(&peer.peer_addr) orelse return 0x3069;
    peers[i] = peer.*;
    return 0;
}
pub fn esp_now_del_peer(address: *const [6]u8) i32 {
    const i = index(address) orelse return 0x3069;
    peers[i] = null;
    return 0;
}
pub fn esp_now_get_peer(address: *const [6]u8, out: *esp_now_peer_info_t) i32 {
    const i = index(address) orelse return 0x3069;
    out.* = peers[i].?;
    return 0;
}
pub fn esp_now_is_peer_exist(address: *const [6]u8) bool {
    return index(address) != null;
}
pub fn esp_now_get_peer_num(out: *esp_now_peer_num_t) i32 {
    out.* = .{ .total_num = 0, .encrypt_num = 0 };
    for (peers) |peer| if (peer) |value| {
        out.total_num += 1;
        out.encrypt_num += @intFromBool(value.encrypt);
    };
    return 0;
}
pub fn esp_now_send(address: *const [6]u8, _: [*]const u8, _: usize) i32 {
    if (index(address) == null) return 0x3069;
    pending_delivery = delivery;
    if (!delay_completion) complete_send();
    return 0;
}

// Like the blob, unregistering does not drain a transmission. Delivery uses the
// current registration, exposing misrouting if the wrapper allows early reuse.
pub fn complete_send() void {
    const status = pending_delivery orelse return;
    pending_delivery = null;
    if (send_cb) |cb| cb(null, status);
}

pub fn receive(info: *const esp_now_recv_info_t, payload: []const u8) void {
    if (receive_cb) |cb| cb(info, payload.ptr, @intCast(payload.len));
}

pub fn lifecycle_busy() bool {
    return in_callback;
}
