//! Shared bounded TX completion, open-AP rejection and SoftAP echo checks; see the three selftest entry-point headers.
const std = @import("std");
const wifi_options = @import("wifi_options");
// Only the softap_echo build receives this module (build.zig `softap_options`).
const softap_options = if (mode == .softap_echo) @import("softap_options") else struct {};

const microzig = @import("microzig");
const hal = microzig.hal;
const rtos = hal.rtos;
const radio = hal.radio;

var wifi: radio.wifi.Wifi = .{};
const usb_serial_jtag = hal.usb_serial_jtag;

const exports = @import("lwip/exports.zig");
const lwip = @import("lwip/include.zig");

comptime {
    _ = exports;
}

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .esp_radio, .level = .err },
        .{ .scope = .esp_radio_timer, .level = .err },
        .{ .scope = .esp_radio_wifi, .level = .err },
        .{ .scope = .esp_radio_osi, .level = .err },
    },
    .logFn = usb_serial_jtag.logger.log,
});

pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt30 = radio.interrupt_handler,
        .interrupt31 = rtos.interrupt_handler,
    },
    .cpu = .{
        .interrupt_stack = .{
            .enable = true,
            .size = 8192,
        },
    },
    .hal = .{
        .rtos = .{
            .enable = true,
        },
        .radio = .{
            .wifi = .{
                .on_packet_received = on_packet_received,
                .on_event = on_wifi_event,
                .on_packet_transmitted = on_packet_transmitted,
            },
        },
    },
};

pub const Mode = enum { tx_done, open_ap, softap_echo };
const mode: Mode = @import("root").mode;
const suite = switch (mode) {
    .tx_done => "wifi_tx_done",
    .open_ap => "wifi_open_ap",
    .softap_echo => "wifi_softap_echo",
};
const checks: u32 = switch (mode) {
    .tx_done => 3,
    .open_ap => 3,
    .softap_echo => 13,
};
const auth = std.meta.stringToEnum(radio.wifi.AuthMethod, wifi_options.auth) orelse
    @compileError("wifi_auth must name a hal.radio.wifi.AuthMethod");
var step: []const u8 = "setup";
var passed: u32 = 0;
var maybe_netif: std.atomic.Value(?*lwip.c.netif) = .init(null);
var wifi_ready_signal: rtos.Signal(void) = .{};
var connected_once: std.atomic.Value(bool) = .init(false);
var disconnect_reason: std.atomic.Value(u32) = .init(0);
var tcp_connected: std.atomic.Value(bool) = .init(false);
var tx_seen: std.atomic.Value(u32) = .init(0);
var tx_failed: std.atomic.Value(u32) = .init(0);
const frame_count = 10;
const marker = "microzig-tx-done";
// Retained through a timeout too, in case a late TX callback still references it.
var frame: [60]u8 = @splat(0);

pub fn run() noreturn {
    var heap = microzig.Allocator.init_with_heap(32768) catch |err| report_loop(err);
    // Keep the allocator and netif alive even after a failed check: lwIP owns
    // references to them until reset. Results repeat for late USB attachment.
    var netif: lwip.c.netif = undefined;
    exercise(heap.allocator(), &netif) catch |err| report_loop(err);
    report_loop(null);
}

fn pass() void {
    passed += 1;
    std.log.info("SELFTEST {s} {s}: PASS", .{ suite, step });
}

fn report_loop(err: ?anyerror) noreturn {
    while (true) {
        if (err) |failure| std.log.err("SELFTEST {s} {s}: FAIL {t}", .{ suite, step, failure });
        std.log.info("SELFTEST {s} DONE pass={d} fail={d}", .{ suite, passed, checks - passed });
        rtos.sleep(.from_ms(3000));
    }
}

fn deadline() microzig.drivers.time.Deadline {
    return .init_relative(hal.time.get_time_since_boot(), .from_ms(30_000));
}

fn wait_sta(expected: radio.wifi.StaState) !void {
    const limit = deadline();
    while (wifi.get_sta_state() != expected) {
        if (limit.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
        rtos.sleep(.from_ms(20));
    }
}

fn exercise(gpa: std.mem.Allocator, netif: *lwip.c.netif) !void {
    if (mode == .open_ap and (auth == .none or wifi_options.password.len == 0))
        return error.ProtectedAuthRequired;
    @import("wifi_antenna.zig").apply();
    try wifi.init(gpa, .{});
    const station: radio.wifi.Config.Station = if (mode == .softap_echo) .{
        .ssid = softap_options.ssid,
        .password = softap_options.password,
        .auth_method = .wpa2_personal,
    } else .{ .ssid = wifi_options.ssid, .password = wifi_options.password, .auth_method = auth };
    try wifi.apply(.{ .sta = station });
    step = "start";
    try wifi.start();
    try wait_sta(.started);
    pass();
    if (mode == .open_ap) return reject_open_ap();

    if (mode == .softap_echo) {
        step = "netif";
        exports.gpa = gpa;
        lwip.c.tcpip_init(null, null);
        try lwip.c_err(lwip.c.netifapi_netif_add(netif, @ptrCast(lwip.c.IP4_ADDR_ANY), @ptrCast(lwip.c.IP4_ADDR_ANY), @ptrCast(lwip.c.IP4_ADDR_ANY), null, netif_init, lwip.c.tcpip_input));
        maybe_netif.store(netif, .release);
        try lwip.c_err(lwip.c.netifapi_netif_common(netif, null, lwip.c.dhcp_start));
    }
    step = "join";
    try wifi.connect();
    try wait_sta(.connected);
    pass();
    if (mode == .tx_done) return check_tx_done();
    step = "dhcp";
    try lwip.c_err(lwip.c.netifapi_netif_common(netif, lwip.c.netif_set_link_up, null));
    try wifi_ready_signal.wait_with_timeout(.{ .after = .from_ms(30_000) });
    pass();
    try check_echo();
}

fn reject_open_ap() !void {
    step = "open_peer_present";
    var scan = try wifi.scan(.{});
    var found = false;
    {
        defer scan.deinit() catch |err| std.log.warn("Wi-Fi scan cleanup failed ({t})", .{err});
        while (try scan.next()) |record| {
            if (!std.mem.eql(u8, record.ssid, wifi_options.ssid)) continue;
            if (record.auth_mode != .none) return error.ProtectedPeerAlsoPresent;
            found = true;
        }
    }
    if (!found) return error.OpenPeerMissing;
    pass();
    step = "reject_open_join";
    try wifi.connect();
    const limit = deadline();
    while (!limit.is_reached_by(hal.time.get_time_since_boot())) {
        if (connected_once.load(.acquire)) return error.OpenPeerAccepted;
        const reason = disconnect_reason.load(.acquire);
        // ESP-IDF v5.5.1 esp_wifi_types_generic.h: incompatible security (210)
        // or below the configured auth threshold (211), not generic NO_AP_FOUND.
        if (reason != 0 and reason != 210 and reason != 211) return error.UnexpectedDisconnectReason;
        rtos.sleep(.from_ms(20));
    }
    if (connected_once.load(.acquire)) return error.OpenPeerAccepted;
    // The last reported reason must still be a security rejection.
    switch (disconnect_reason.load(.acquire)) {
        0 => return error.NoRejectionEvent,
        210, 211 => {},
        else => return error.UnexpectedDisconnectReason,
    }
    pass();
}

fn on_wifi_event(event: radio.wifi.Event) void {
    switch (event) {
        .StaConnected => connected_once.store(true, .release),
        .StaDisconnected => |data| disconnect_reason.store(data.reason, .release),
        else => {},
    }
}

fn on_packet_transmitted(iface: radio.wifi.Interface, data: []const u8, status: bool) void {
    // The driver hands back the 802.11 frame (see the hook's doc comment), so the
    // Ethernet offsets of `frame` do not apply. Find the marker instead; that also
    // skips unrelated traffic such as the EAPOL handshake.
    if (iface != .sta) return;
    const at = std.mem.find(u8, data, marker) orelse return;
    if (at + marker.len >= data.len) return;
    const seq = data[at + marker.len];
    if (seq >= frame_count) return;
    if (!status) _ = tx_failed.fetchAdd(1, .monotonic);
    _ = tx_seen.fetchOr(@as(u32, 1) << @intCast(seq), .release);
}

fn check_tx_done() !void {
    step = "callbacks";
    // Locally experimental EtherType 0x88b5. Broadcast needs no IP peer;
    // each successfully queued Ethernet frame must reach the TX-done hook.
    @memset(frame[0..6], 0xff);
    @memcpy(frame[6..12], &radio.read_mac(.sta));
    frame[12] = 0x88;
    frame[13] = 0xb5;
    @memcpy(frame[14..][0..marker.len], marker);
    var sent: u32 = 0;
    for (0..frame_count) |seq| {
        frame[14 + marker.len] = @intCast(seq);
        try wifi.send_packet(.sta, &frame);
        sent += 1;
        // Keep this buffer unchanged until its callback, also bounding in-flight
        // frames to one. A duplicate callback cannot hide a missing sequence.
        const limit = deadline();
        while (tx_seen.load(.acquire) & (@as(u32, 1) << @intCast(seq)) == 0) {
            if (limit.is_reached_by(hal.time.get_time_since_boot())) {
                std.log.err("TX sent={d} callbacks={d}", .{ sent, @popCount(tx_seen.load(.acquire)) });
                return error.TxDoneTimeout;
            }
            rtos.sleep(.from_ms(20));
        }
    }
    const callbacks = @popCount(tx_seen.load(.acquire));
    std.log.info("TX sent={d} callbacks={d} failed={d}", .{ sent, callbacks, tx_failed.load(.monotonic) });
    if (callbacks < sent or tx_failed.load(.monotonic) != 0) return error.TxDoneFailed;
    pass();
}

fn tcp_event(_: [*c]lwip.c.netconn, event: lwip.c.enum_netconn_evt, _: u16) callconv(.c) void {
    if (event == lwip.c.NETCONN_EVT_SENDPLUS) tcp_connected.store(true, .release);
}

extern fn netconn_new_with_proto_and_callback(t: lwip.c.enum_netconn_type, proto: lwip.c.u8_t, callback: ?*const anyopaque) [*c]lwip.c.struct_netconn;

fn check_echo() !void {
    // Nonblocking connect/read/write plus explicit deadlines; lwIP's default
    // configuration has no socket receive/send timeout fields.
    step = "tcp_connect";
    const conn = netconn_new_with_proto_and_callback(lwip.c.NETCONN_TCP, 0, @ptrCast(&tcp_event)) orelse return error.OutOfMemory;
    defer {
        lwip.c_err(lwip.c.netconn_delete(conn)) catch |err| std.log.err("TCP delete: {t}", .{err});
    }
    conn.*.flags |= lwip.c.NETCONN_FLAG_NON_BLOCKING;
    var ip: lwip.c.ip_addr_t = std.mem.zeroes(lwip.c.ip_addr_t);
    ip.u_addr.ip4.addr = @bitCast([4]u8{ 192, 168, 4, 1 });
    lwip.c_err(lwip.c.netconn_connect(conn, &ip, 7)) catch |err| switch (err) {
        error.InProgress => {},
        else => return err,
    };
    const connect_limit = deadline();
    while (!tcp_connected.load(.acquire)) {
        try lwip.c_err(lwip.c.netconn_err(conn));
        if (connect_limit.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
        rtos.sleep(.from_ms(20));
    }
    try lwip.c_err(lwip.c.netconn_err(conn));
    // TCP connect is checked with the first echo, so total is 3 + 10 cases.
    for (0..10) |seq| {
        step = "echo";
        var payload: [257]u8 = undefined;
        for (&payload, 0..) |*byte, i| byte.* = @truncate(i + seq * 31);
        const limit = deadline();
        var written: usize = 0;
        while (written < payload.len) {
            var n: usize = 0;
            lwip.c_err(lwip.c.netconn_write_partly(conn, payload[written..].ptr, payload.len - written, lwip.c.NETCONN_COPY | lwip.c.NETCONN_DONTBLOCK, &n)) catch |err| switch (err) {
                error.WouldBlock => {},
                else => return err,
            };
            written += n;
            if (limit.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
            if (n == 0) rtos.sleep(.from_ms(20));
        }
        var received: usize = 0;
        while (received < payload.len) {
            var p: [*c]lwip.c.pbuf = null;
            lwip.c_err(lwip.c.netconn_recv_tcp_pbuf_flags(conn, &p, lwip.c.NETCONN_DONTBLOCK)) catch |err| switch (err) {
                error.WouldBlock => {
                    if (limit.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
                    rtos.sleep(.from_ms(20));
                    continue;
                },
                else => return err,
            };
            if (p == null) return error.EchoLength;
            defer _ = lwip.c.pbuf_free(p);
            if (p.*.tot_len == 0 or p.*.tot_len > payload.len - received) return error.EchoLength;
            var actual: [257]u8 = undefined;
            const n = lwip.c.pbuf_copy_partial(p, &actual, p.*.tot_len, 0);
            if (n != p.*.tot_len or !std.mem.eql(u8, actual[0..n], payload[received..][0..n])) return error.EchoMismatch;
            received += n;
            if (limit.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
        }
        std.log.info("TCP echo payload={d} bytes={d}", .{ seq, received });
        pass();
    }
}

fn netif_status_callback(netif_ptr: [*c]lwip.c.netif) callconv(.c) void {
    const netif = &netif_ptr[0];
    if (netif.ip_addr.u_addr.ip4.addr != 0) {
        wifi_ready_signal.put({});
    }
}

fn on_packet_received(comptime _: radio.wifi.Interface, data: []const u8) void {
    // The other two checks never start lwIP. Publish the netif only after its
    // initialization, before connecting; acquire pairs with the main task.
    const netif = maybe_netif.load(.acquire) orelse return;
    const pbuf = lwip.c.pbuf_alloc(lwip.c.PBUF_RAW, @intCast(data.len), lwip.c.PBUF_POOL) orelse {
        std.log.err("failed to allocate receive pbuf", .{});
        return;
    };
    lwip.c_err(lwip.c.pbuf_take(pbuf, data.ptr, @intCast(data.len))) catch |err| {
        _ = lwip.c.pbuf_free(pbuf);
        std.log.err("pbuf_take failed: {t}", .{err});
        return;
    };
    lwip.c_err(netif.input.?(pbuf, netif)) catch |err| {
        _ = lwip.c.pbuf_free(pbuf);
        std.log.warn("tcpip_input failed: {t}", .{err});
    };
}

fn netif_init(netif_ptr: [*c]lwip.c.struct_netif) callconv(.c) lwip.c.err_t {
    const netif = &netif_ptr[0];
    @memcpy(&netif.name, "w0");
    netif.linkoutput = netif_output;
    netif.output = lwip.c.etharp_output;
    netif.output_ip6 = lwip.c.ethip6_output;
    netif.mtu = 1500;
    netif.flags = lwip.c.NETIF_FLAG_BROADCAST | lwip.c.NETIF_FLAG_ETHARP | lwip.c.NETIF_FLAG_ETHERNET | lwip.c.NETIF_FLAG_IGMP | lwip.c.NETIF_FLAG_MLD6;
    @memcpy(&netif.hwaddr, &radio.read_mac(.sta));
    netif.hwaddr_len = 6;
    lwip.c.netif_create_ip6_linklocal_address(netif, 1);
    lwip.c.netif_set_status_callback(netif, netif_status_callback);
    lwip.c.netif_set_default(netif);
    lwip.c.netif_set_up(netif);
    return lwip.c.ERR_OK;
}

var packet_buf: [1600]u8 = undefined;

fn netif_output(_: [*c]lwip.c.struct_netif, pbuf_c: [*c]lwip.c.struct_pbuf) callconv(.c) lwip.c.err_t {
    const pbuf: *lwip.c.struct_pbuf = pbuf_c;
    if (pbuf.tot_len > packet_buf.len) return lwip.c.ERR_BUF;

    var off: usize = 0;
    while (off < pbuf.tot_len) {
        const cnt = lwip.c.pbuf_copy_partial(pbuf, packet_buf[off..].ptr, @as(u15, @intCast(pbuf.tot_len - off)), @as(u15, @intCast(off)));
        if (cnt == 0) {
            std.log.err("failed to copy network packet", .{});
            return lwip.c.ERR_BUF;
        }
        off += cnt;
    }

    wifi.send_packet(.sta, packet_buf[0..pbuf.tot_len]) catch |err| {
        std.log.err("failed to send packet: {}", .{err});
        return lwip.c.ERR_IF;
    };

    return lwip.c.ERR_OK;
}
