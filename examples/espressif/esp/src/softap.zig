//! TCP echo peer: flash selftest_wifi_softap_echo on a C3 station for a C6 AP,
//! or on a C6 station for a C3 AP. Use identical -Dsoftap_ssid and
//! -Dsoftap_password options on both builds.
//! Start this AP first. TCP echo is at 192.168.4.1:7, no PC on the AP needed.
//! Station expects SELFTEST wifi_softap_echo DONE pass=13 fail=0.
const std = @import("std");

const microzig = @import("microzig");
const hal = microzig.hal;
const rtos = hal.rtos;
const radio = hal.radio;
const usb_serial_jtag = hal.usb_serial_jtag;

const options = @import("softap_options");
const dhcp = @import("softap_dhcp.zig");
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

comptime {
    _ = microzig.export_startup();
}

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
            },
        },
    },
};

// The netif is published before Wi-Fi starts; it lives for the firmware lifetime.
var ap_netif: lwip.c.netif = undefined;
var ap_started: std.atomic.Value(bool) = .init(false);
var serving: std.atomic.Value(bool) = .init(false);
var station_count: std.atomic.Value(u32) = .init(0);
// Accessed only with the lwIP core mutex held (including UDP callbacks/output).
var dhcp_server: dhcp.Server = .{};
var packet_buf: [1600]u8 = undefined;

extern fn netconn_new_with_proto_and_callback(t: lwip.c.enum_netconn_type, proto: lwip.c.u8_t, callback: ?*const anyopaque) [*c]lwip.c.struct_netconn;

pub fn main() !void {
    // lwIP and radio tasks allocate from this explicit application heap.
    var heap: microzig.Allocator = try .init_with_heap(32768);
    const gpa = heap.allocator();
    _ = try rtos.spawn(gpa, reporter, .{}, .{});
    @import("wifi_antenna.zig").apply();
    try radio.wifi.init(gpa, .{});
    exports.gpa = gpa;
    lwip.c.tcpip_init(null, null);
    const ip = ipv4(dhcp.gateway);
    const mask = ipv4(.{ 255, 255, 255, 0 });
    try lwip.c_err(lwip.c.netifapi_netif_add(
        &ap_netif,
        &ip.u_addr.ip4,
        &mask.u_addr.ip4,
        &ip.u_addr.ip4,
        null,
        netif_init,
        lwip.c.tcpip_input,
    ));
    try start_dhcp();
    try radio.wifi.apply(.{ .ap = .{
        .ssid = options.ssid,
        .password = options.password,
        .auth_method = .wpa2_personal,
        .channel = 6,
        .max_connections = dhcp.max_stations,
    } });
    try radio.wifi.start();
    const deadline = microzig.drivers.time.Deadline.init_relative(hal.time.get_time_since_boot(), .from_ms(10_000));
    while (!ap_started.load(.acquire)) {
        if (deadline.is_reached_by(hal.time.get_time_since_boot())) return error.ApStartTimeout;
        rtos.sleep(.from_ms(20));
    }
    try lwip.c_err(lwip.c.netifapi_netif_common(&ap_netif, lwip.c.netif_set_link_up, null));

    const listener = netconn_new_with_proto_and_callback(lwip.c.NETCONN_TCP, 0, null) orelse return error.OutOfMemory;
    defer delete_conn(listener);
    // Bind specifically to the AP address, not to any future STA interface.
    try lwip.c_err(lwip.c.netconn_bind(listener, &ip, 7));
    try lwip.c_err(lwip.c.netconn_listen(listener));
    serving.store(true, .release);
    report();
    while (true) {
        var client: ?*lwip.c.netconn = null;
        try lwip.c_err(lwip.c.netconn_accept(listener, &client));
        defer delete_conn(client);
        var echoed: usize = 0;
        defer std.log.info("SOFTAP tcp echoed={d}", .{echoed});
        echo(client, &echoed) catch |err| std.log.warn("SOFTAP tcp: {t}", .{err});
    }
}

fn delete_conn(conn: ?*lwip.c.netconn) void {
    lwip.c_err(lwip.c.netconn_close(conn)) catch |err| std.log.warn("SOFTAP close: {t}", .{err});
    lwip.c_err(lwip.c.netconn_delete(conn)) catch |err| std.log.err("SOFTAP delete: {t}", .{err});
}

fn echo(conn: ?*lwip.c.netconn, echoed: *usize) !void {
    while (true) {
        var buf: ?*lwip.c.netbuf = null;
        lwip.c_err(lwip.c.netconn_recv(conn, &buf)) catch |err| switch (err) {
            error.ConnectionClosed => return,
            else => return err,
        };
        defer lwip.c.netbuf_delete(buf);
        // A netbuf can contain a pbuf chain, including multiple TCP segments.
        while (true) {
            var data: ?*anyopaque = null;
            var len: u16 = 0;
            try lwip.c_err(lwip.c.netbuf_data(buf, &data, &len));
            var written: usize = 0;
            const result = lwip.c.netconn_write_partly(conn, data, len, lwip.c.NETCONN_COPY, &written);
            echoed.* += written;
            try lwip.c_err(result);
            if (lwip.c.netbuf_next(buf) < 0) break;
        }
    }
}

fn reporter() void {
    rtos.sleep(.from_ms(1500));
    while (true) : (rtos.sleep(.from_ms(3000))) report();
}

fn report() void {
    if (serving.load(.acquire) and ap_started.load(.acquire)) {
        std.log.info("SOFTAP up ssid={s} ip=192.168.4.1 stations={d} tcp=7", .{ options.ssid, station_count.load(.monotonic) });
    } else std.log.info("SOFTAP waiting ssid={s}", .{options.ssid});
}

fn on_wifi_event(event: radio.wifi.Event) void {
    switch (event) {
        .ApStart => ap_started.store(true, .release),
        .ApStop => ap_started.store(false, .release),
        inline .ApStaconnected, .ApStadisconnected => |station, tag| {
            if (tag == .ApStaconnected) {
                _ = station_count.fetchAdd(1, .monotonic);
            } else {
                _ = station_count.fetchSub(1, .monotonic);
            }
            std.log.info("SOFTAP {s} mac={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} aid={d}", .{
                if (tag == .ApStaconnected) "join" else "leave",
                station.mac[0],
                station.mac[1],
                station.mac[2],
                station.mac[3],
                station.mac[4],
                station.mac[5],
                station.aid,
            });
        },
        else => {},
    }
}

fn ipv4(bytes: [4]u8) lwip.c.ip_addr_t {
    return .{ .u_addr = .{ .ip4 = .{ .addr = @bitCast(bytes) } }, .type = lwip.c.IPADDR_TYPE_V4 };
}

fn start_dhcp() !void {
    // Raw UDP calls need lock_tcpip_core. exports.core_mutex is instead the
    // SYS_ARCH_PROTECT lock, which PCB allocation acquires internally.
    lwip.c.LOCK_TCPIP_CORE();
    defer lwip.c.UNLOCK_TCPIP_CORE();
    const pcb = lwip.c.udp_new_ip_type(lwip.c.IPADDR_TYPE_V4) orelse return error.OutOfMemory;
    errdefer lwip.c.udp_remove(pcb);
    const any = ipv4(.{ 0, 0, 0, 0 });
    try lwip.c_err(lwip.c.udp_bind(pcb, &any, 67));
    lwip.c.udp_bind_netif(pcb, &ap_netif);
    lwip.c.udp_recv(pcb, dhcp_receive, null);
}

fn dhcp_receive(_: ?*anyopaque, pcb: [*c]lwip.c.udp_pcb, p: [*c]lwip.c.pbuf, _: [*c]const lwip.c.ip_addr_t, port: u16) callconv(.c) void {
    defer _ = lwip.c.pbuf_free(p);
    if (port != 68 or p.*.tot_len > 1500) return;
    var input: [1500]u8 = undefined;
    const len = lwip.c.pbuf_copy_partial(p, &input, p.*.tot_len, 0);
    const reply = dhcp_server.receive(input[0..len], @truncate(hal.time.get_time_since_boot().to_us() / 1000)) orelse return;
    const out = lwip.c.pbuf_alloc(lwip.c.PBUF_TRANSPORT, reply.bytes.len, lwip.c.PBUF_RAM) orelse {
        std.log.err("SOFTAP DHCP: out of memory", .{});
        return;
    };
    defer _ = lwip.c.pbuf_free(out);
    lwip.c_err(lwip.c.pbuf_take(out, &reply.bytes, reply.bytes.len)) catch |err| {
        std.log.err("SOFTAP DHCP copy: {t}", .{err});
        return;
    };
    const dest = ipv4(reply.destination);
    lwip.c_err(lwip.c.udp_sendto_if(pcb, out, &dest, 68, &ap_netif)) catch |err| {
        std.log.err("SOFTAP DHCP send: {t}", .{err});
        return;
    };
    if (reply.leased_ip) |ip| std.log.info("SOFTAP lease mac={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} ip={d}.{d}.{d}.{d}", .{
        reply.mac[0], reply.mac[1], reply.mac[2], reply.mac[3], reply.mac[4], reply.mac[5], ip[0], ip[1], ip[2], ip[3],
    });
}

fn on_packet_received(comptime interface: radio.wifi.Interface, data: []const u8) void {
    if (interface != .ap or data.len > 1600) return;
    const p = lwip.c.pbuf_alloc(lwip.c.PBUF_RAW, @intCast(data.len), lwip.c.PBUF_POOL) orelse {
        std.log.warn("SOFTAP RX: out of memory", .{});
        return;
    };
    lwip.c_err(lwip.c.pbuf_take(p, data.ptr, @intCast(data.len))) catch |err| {
        _ = lwip.c.pbuf_free(p);
        std.log.warn("SOFTAP RX copy: {t}", .{err});
        return;
    };
    lwip.c_err(ap_netif.input.?(p, &ap_netif)) catch |err| {
        _ = lwip.c.pbuf_free(p);
        std.log.warn("SOFTAP RX input: {t}", .{err});
    };
}

fn netif_init(netif: [*c]lwip.c.netif) callconv(.c) lwip.c.err_t {
    @memcpy(&netif.*.name, "ap");
    netif.*.linkoutput = netif_output;
    netif.*.output = lwip.c.etharp_output;
    netif.*.mtu = 1500;
    netif.*.flags = lwip.c.NETIF_FLAG_BROADCAST | lwip.c.NETIF_FLAG_ETHARP | lwip.c.NETIF_FLAG_ETHERNET;
    @memcpy(&netif.*.hwaddr, &radio.read_mac(.ap));
    netif.*.hwaddr_len = 6;
    lwip.c.netif_set_default(netif);
    lwip.c.netif_set_up(netif);
    return lwip.c.ERR_OK;
}

fn netif_output(_: [*c]lwip.c.netif, p: [*c]lwip.c.pbuf) callconv(.c) lwip.c.err_t {
    if (p.*.tot_len > packet_buf.len) return lwip.c.ERR_BUF;
    const len = lwip.c.pbuf_copy_partial(p, &packet_buf, p.*.tot_len, 0);
    if (len != p.*.tot_len) return lwip.c.ERR_BUF;
    radio.wifi.send_packet(.ap, packet_buf[0..len]) catch |err| {
        std.log.warn("SOFTAP TX: {t}", .{err});
        return lwip.c.ERR_IF;
    };
    return lwip.c.ERR_OK;
}
