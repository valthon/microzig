const std = @import("std");
const wifi_options = @import("wifi_options");

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

/// From -Dwifi_auth; build.zig derives wpa2_personal from a non-empty passphrase.
const AUTH_METHOD = std.meta.stringToEnum(radio.wifi.AuthMethod, wifi_options.auth) orelse
    @compileError("wifi_options.auth is not a hal.radio.wifi.AuthMethod name");
const SERVER_PORT = 3333;

var maybe_netif: ?*lwip.c.netif = null;

var wifi_ready_signal: rtos.Signal(void) = .{};
var ap_started: std.atomic.Value(bool) = .init(false);
/// Count of StaDisconnected events and the reason of the latest, stored together so a
/// reader never pairs a count with another event's reason. Only `on_wifi_event` writes it,
/// which the port calls in whichever task posts the event (osi.zig `esp_event_post`).
var sta_disconnect: std.atomic.Value(StaDisconnect) = .init(.{ .count = 0, .reason = 0 });

const StaDisconnect = packed struct(u32) { count: u16, reason: u16 };

// Lifecycle self-test result, repeated by `lifecycle_reporter` because USB
// output before the host reopens the port after reset is lost.
const lifecycle_checks = 8;
var lifecycle_step: []const u8 = "setup";
var lifecycle_passed: u32 = 0;
var lifecycle_error: ?anyerror = null;
var lifecycle_done: std.atomic.Value(bool) = .init(false);

extern fn netconn_new_with_proto_and_callback(t: lwip.c.enum_netconn_type, proto: lwip.c.u8_t, callback: ?*const anyopaque) [*c]lwip.c.struct_netconn;
pub fn main() !void {
    try run(false);
}

/// Shared entry point so the lifecycle test uses the same build-time credentials
/// and the same lwIP/DHCP/TCP echo implementation as the ordinary server.
pub fn run(comptime lifecycle_selftest: bool) !void {
    var heap_allocator = microzig.Allocator.init_with_heap(16384) catch |err| {
        if (lifecycle_selftest) lifecycle_fail(err);
        return err;
    };
    var netif: lwip.c.netif = undefined;
    run_server(lifecycle_selftest, heap_allocator.allocator(), &netif) catch |err| {
        // lwIP retains the allocator and registered netif. Park inside their
        // owning frame so callbacks and allocations remain valid during FAIL.
        if (lifecycle_selftest) lifecycle_fail(err);
        return err;
    };
}

fn run_server(comptime lifecycle_selftest: bool, gpa: std.mem.Allocator, netif: *lwip.c.netif) !void {
    @import("wifi_antenna.zig").apply();
    wifi.init(gpa, .{}) catch |err| {
        if (err == error.WifiRollbackPending) {
            wifi.deinit() catch |cleanup_err| {
                std.log.err("Wi-Fi init rollback failed ({t}); keeping its memory", .{cleanup_err});
                if (lifecycle_selftest) lifecycle_fail(err);
                while (true) rtos.sleep(.from_ms(1000));
            };
        }
        return err;
    };
    const result = serve(lifecycle_selftest, gpa, netif);
    // The driver keeps allocating from `gpa` until a deinit succeeds, so after a failed one
    // this parks, and the frame that owns the heap and the netif never returns.
    wifi.deinit() catch |err| {
        if (result) |_| {} else |served_err| std.log.err("server failed ({t})", .{served_err});
        std.log.err("Wi-Fi deinit failed ({t}); keeping its memory", .{err});
        if (lifecycle_selftest) {
            lifecycle_step = "deinit";
            lifecycle_fail(err);
        }
        while (true) rtos.sleep(.from_ms(1000));
    };
    return result;
}

fn serve(comptime lifecycle_selftest: bool, gpa: std.mem.Allocator, netif: *lwip.c.netif) !void {
    exports.gpa = gpa;
    lwip.c.tcpip_init(null, null);

    try lwip.c_err(lwip.c.netifapi_netif_add(
        netif,
        @ptrCast(lwip.c.IP4_ADDR_ANY),
        @ptrCast(lwip.c.IP4_ADDR_ANY),
        @ptrCast(lwip.c.IP4_ADDR_ANY),
        null,
        netif_init,
        lwip.c.tcpip_input,
    ));
    maybe_netif = netif;
    try lwip.c_err(lwip.c.netifapi_netif_common(netif, null, lwip.c.dhcp_start));

    const station: radio.wifi.Config.Station = .{
        .ssid = wifi_options.ssid,
        .password = wifi_options.password,
        .auth_method = AUTH_METHOD,
    };
    if (lifecycle_selftest) {
        // Configure a deterministic AP while stopped, then enter STA for the test.
        // The running STA->AP_STA transition below changes only the mode.
        try wifi.apply(.{ .ap_sta = .{
            .sta = station,
            .ap = .{ .ssid = "microzig-lifecycle", .channel = 1, .max_connections = 2 },
        } });
    }
    try wifi.apply(.{ .sta = station });

    if (lifecycle_selftest) {
        // Default 4096-byte reporter stack shares the Wi-Fi/lwIP allocator:
        // linker-defined heap region minus the 16 KiB stack reserve above.
        // Spawn failure uses the main task to repeat FAIL.
        lifecycle_step = "reporter_spawn";
        _ = try rtos.spawn(gpa, lifecycle_reporter, .{}, .{});
        lifecycle_step = "start";
        try run_lifecycle(station);
    } else {
        try wifi.start();
        while (!wifi.get_sta_state().is_started()) {
            rtos.sleep(.from_ms(100));
        }

        {
            std.log.info("Scanning for access points...", .{});
            var scan_iter = try wifi.scan(.{});
            defer scan_iter.deinit() catch |err| std.log.warn("Wi-Fi scan cleanup failed ({t})", .{err});
            while (try scan_iter.next()) |record| {
                // Neighbour SSIDs are broadcast, not credentials.
                std.log.info("Found ap `{s}` RSSI: {} Channel: {}, Auth: {?t}", .{
                    record.ssid,
                    record.rssi,
                    record.primary_channel,
                    record.auth_mode,
                });
            }
        }

        try connect_sta(station);
    }
    try lwip.c_err(lwip.c.netifapi_netif_common(maybe_netif.?, lwip.c.netif_set_link_up, null));

    if (lifecycle_selftest) {
        lifecycle_step = "dhcp";
        wifi_ready_signal.wait_with_timeout(.{ .after = .from_ms(30_000) }) catch |err| lifecycle_fail(err);
        lifecycle_pass();
        lifecycle_step = "tcp_listen";
    } else {
        wifi_ready_signal.wait();
    }

    std.log.info("Listening on {f}:{}", .{ IP_Formatter.init(netif.ip_addr), SERVER_PORT });

    const server_conn = netconn_new_with_proto_and_callback(lwip.c.NETCONN_TCP, 0, null) orelse {
        std.log.err("Failed to create netconn", .{});
        return error.FailedToCreateNetconn;
    };
    defer {
        _ = lwip.c.netconn_close(server_conn);
        _ = lwip.c.netconn_delete(server_conn);
    }

    try lwip.c_err(lwip.c.netconn_bind(server_conn, null, SERVER_PORT));

    try lwip.c_err(lwip.c.netconn_listen(server_conn));
    std.log.info("TCP Server listening...", .{});
    if (lifecycle_selftest) {
        lifecycle_pass();
        lifecycle_done.store(true, .release);
        lifecycle_report();
    }

    while (true) : (rtos.sleep(.from_ms(200))) {
        var client_conn: ?*lwip.c.netconn = null;

        lwip.c_err(lwip.c.netconn_accept(server_conn, &client_conn)) catch |err| {
            std.log.err("failed to accept connection: {t}", .{err});
            continue;
        };
        defer {
            _ = lwip.c.netconn_close(client_conn);
            _ = lwip.c.netconn_delete(client_conn);
        }

        std.log.info("New client connected!", .{});
        defer std.log.info("Client disconnected.", .{});
        handle_client(client_conn) catch |err| {
            std.log.err("error while connected to client: {t}", .{err});
            continue;
        };
    }
}

fn on_wifi_event(event: radio.wifi.Event) void {
    switch (event) {
        .ApStart => ap_started.store(true, .monotonic),
        .ApStop => ap_started.store(false, .monotonic),
        .StaDisconnected => |info| {
            const count = sta_disconnect.load(.monotonic).count;
            sta_disconnect.store(.{ .count = count +% 1, .reason = info.reason }, .release);
        },
        else => {},
    }
}

fn wait_sta(comptime expected: radio.wifi.StaState) error{Timeout}!void {
    const deadline = microzig.drivers.time.Deadline.init_relative(hal.time.get_time_since_boot(), .from_ms(30_000));
    while (wifi.get_sta_state() != expected) {
        if (deadline.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
        rtos.sleep(.from_ms(20));
    }
}

/// Connects the station and, as ESP-IDF directs applications, connects again on
/// StaDisconnected: "It is the application's responsibility to reconnect. The recommended
/// reconnection strategy is to call esp_wifi_connect() on receiving event
/// WIFI_EVENT_STA_DISCONNECTED" (IDF v5.5.1 docs/en/api-guides/wifi.rst, "Wi-Fi Reconnect").
/// Each call allows 5 retries, the IDF station example's CONFIG_ESP_MAXIMUM_RETRY default, and
/// 30 s in all.
///
/// Before a retry it applies the station configuration again, without changing the mode, and
/// waits 100 ms. A connect refused during authentication (reason 202) puts the AP on the blob's
/// station blacklist; the next connect's scan then skips the AP, scans every channel (over 2 s)
/// and fails with reason 205. `esp_wifi_set_config` clears the blacklist
/// (`wifi_set_config_process+0x78`). It refuses a configuration while the station is
/// connecting (`error.WifiState`, `wifi_set_config_process+0x36..0x58`): measured right after
/// `connect` and 50 ms later, and not after a StaDisconnected, which every retry here follows.
/// Should it come, the retry goes ahead without the configuration. A Pico 2 W AP refused
/// connects with deauthentications for over 100 ms after a station left it without
/// disconnecting first. Where retries applied the configuration again with no wait, the first
/// retry was sometimes refused again (reason 202) within tens of ms, once the second too.
fn connect_sta(station: radio.wifi.Config.Station) !void {
    const max_retries = 5;
    const deadline = microzig.drivers.time.Deadline.init_relative(hal.time.get_time_since_boot(), .from_ms(30_000));
    var seen = sta_disconnect.load(.acquire).count;
    var retries: u32 = 0;
    try wifi.connect();
    while (wifi.get_sta_state() != .connected) {
        if (deadline.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
        const latest = sta_disconnect.load(.acquire);
        if (latest.count != seen) {
            seen = latest.count;
            if (retries == max_retries) return error.StaConnectFailed;
            retries += 1;
            std.log.info("Wi-Fi: disconnected (reason {d}), connect again ({d}/{d})", .{ latest.reason, retries, max_retries });
            wifi.apply_station_config(station) catch |err| switch (err) {
                error.WifiState => std.log.warn(
                    "Wi-Fi: station configuration not applied again ({t})",
                    .{err},
                ),
                else => return err,
            };
            rtos.sleep(.from_ms(100));
            try wifi.connect();
        }
        rtos.sleep(.from_ms(20));
    }
}

fn run_lifecycle(station: radio.wifi.Config.Station) !void {
    std.log.info("Wi-Fi lifecycle: start", .{});
    try wifi.start();
    try wait_sta(.started);
    lifecycle_pass();

    lifecycle_step = "connect";
    std.log.info("Wi-Fi lifecycle: connect", .{});
    try connect_sta(station);
    // Keep the PHY active through a tracking period before closing it.
    rtos.sleep(.from_ms(1100));
    lifecycle_pass();

    lifecycle_step = "stop";
    std.log.info("Wi-Fi lifecycle: stop", .{});
    try wifi.stop();
    try wait_sta(.stopped);
    if (hal.compatibility.chip == .esp32_c6) {
        // N2: initialized Wi-Fi keeps MAC/APB/BB clocks; IDF never gates FE.
        const clocks = microzig.chip.peripherals.MODEM_SYSCON.CLK_CONF1.read();
        if (clocks.CLK_WIFIMAC_EN == 0 or clocks.CLK_WIFI_APB_EN == 0 or
            clocks.CLK_WIFIBB_22M_EN == 0 or clocks.CLK_WIFIBB_40M_EN == 0 or
            clocks.CLK_WIFIBB_44M_EN == 0 or clocks.CLK_WIFIBB_80M_EN == 0 or
            clocks.CLK_WIFIBB_40X_EN == 0 or clocks.CLK_WIFIBB_80X_EN == 0 or
            clocks.CLK_WIFIBB_40X1_EN == 0 or clocks.CLK_WIFIBB_80X1_EN == 0 or
            clocks.CLK_WIFIBB_160X1_EN == 0 or clocks.CLK_FE_APB_EN == 0 or
            clocks.CLK_FE_80M_EN == 0 or clocks.CLK_FE_160M_EN == 0 or
            clocks.CLK_FE_CAL_160M_EN == 0) return error.ClockGatedAfterStop;
    }
    lifecycle_pass();

    lifecycle_step = "restart";
    std.log.info("Wi-Fi lifecycle: start again", .{});
    try wifi.start();
    try wait_sta(.started);
    lifecycle_pass();

    lifecycle_step = "reconnect";
    std.log.info("Wi-Fi lifecycle: connect again", .{});
    try connect_sta(station);
    lifecycle_pass();

    lifecycle_step = "sta_to_ap_sta";
    std.log.info("Wi-Fi lifecycle: STA -> AP_STA", .{});
    ap_started.store(false, .monotonic);
    try wifi.set_mode(.ap_sta);
    const deadline = microzig.drivers.time.Deadline.init_relative(hal.time.get_time_since_boot(), .from_ms(30_000));
    while (!ap_started.load(.monotonic)) {
        if (deadline.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
        rtos.sleep(.from_ms(20));
    }
    if (try wifi.get_mode() != .ap_sta) return error.WrongWifiMode;
    rtos.sleep(.from_ms(1100));
    try wait_sta(.connected);
    lifecycle_pass();
}

fn lifecycle_pass() void {
    lifecycle_passed += 1;
    std.log.info("SELFTEST wifi_lifecycle {s}: PASS", .{lifecycle_step});
}

/// Repeat failures from the main task even if reporter allocation failed.
fn lifecycle_fail(err: anyerror) noreturn {
    lifecycle_error = err;
    lifecycle_done.store(true, .release);
    while (true) {
        lifecycle_report();
        rtos.sleep(.from_ms(1000));
    }
}

fn lifecycle_report() void {
    if (lifecycle_error) |err| std.log.err("SELFTEST wifi_lifecycle {s}: FAIL {t}", .{ lifecycle_step, err });
    std.log.info("SELFTEST wifi_lifecycle DONE pass={d} fail={d}", .{ lifecycle_passed, lifecycle_checks - lifecycle_passed });
}

fn lifecycle_reporter() void {
    while (true) {
        rtos.sleep(.from_ms(3000));
        if (lifecycle_done.load(.acquire) and lifecycle_error == null) lifecycle_report();
    }
}

fn handle_client(conn: ?*lwip.c.netconn) !void {
    var buf: ?*lwip.c.netbuf = null;
    while (true) {
        lwip.c_err(lwip.c.netconn_recv(conn, &buf)) catch |err| switch (err) {
            error.ConnectionClosed => break,
            else => return err,
        };
        defer lwip.c.netbuf_delete(buf);

        var data_ptr: ?*anyopaque = null;
        var len: u16 = 0;
        try lwip.c_err(lwip.c.netbuf_data(buf, &data_ptr, &len));

        const slice = @as([*]u8, @ptrCast(data_ptr))[0..len];
        std.log.info("Received {} bytes: {s}", .{ len, slice });

        // Echo back to client
        try lwip.c_err(lwip.c.netconn_write_partly(conn, data_ptr, len, lwip.c.NETCONN_COPY, null));
    }
}

fn netif_status_callback(netif_ptr: [*c]lwip.c.netif) callconv(.c) void {
    const netif = &netif_ptr[0];
    if (netif.ip_addr.u_addr.ip4.addr != 0) {
        wifi_ready_signal.put({});
    }
}

fn on_packet_received(comptime _: radio.wifi.Interface, data: []const u8) void {
    const pbuf: *lwip.c.struct_pbuf = lwip.c.pbuf_alloc(lwip.c.PBUF_RAW, @intCast(data.len), lwip.c.PBUF_POOL) orelse {
        std.log.err("failed to allocate receive pbuf", .{});
        return;
    };
    lwip.c_err(lwip.c.pbuf_take(pbuf, data.ptr, @intCast(data.len))) catch unreachable;
    if (maybe_netif) |netif| {
        lwip.c_err(netif.input.?(pbuf, netif)) catch |err| {
            _ = lwip.c.pbuf_free(pbuf);
            std.log.warn("tcpip_input failed: {t}", .{err});
        };
    } else {
        _ = lwip.c.pbuf_free(pbuf);
    }
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
    std.debug.assert(pbuf.tot_len < packet_buf.len);

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

const IP_Formatter = struct {
    addr: lwip.c.ip_addr_t,

    pub fn init(addr: lwip.c.ip_addr_t) IP_Formatter {
        return .{ .addr = addr };
    }

    pub fn format(addr: IP_Formatter, writer: *std.Io.Writer) !void {
        try writer.writeAll(std.mem.sliceTo(lwip.c.ip4addr_ntoa(@as(*const lwip.c.ip4_addr_t, @ptrCast(&addr.addr))), 0));
    }
};
