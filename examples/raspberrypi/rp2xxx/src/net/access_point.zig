//! Access point with a DHCP server and a TCP echo on port 7.
//!
//! The defaults match the ESP SoftAP example, so the ESP `selftest_wifi_softap_echo` station
//! joins this access point unchanged and reports `SELFTEST wifi_softap_echo DONE pass=13 fail=0`.
//! Choose the security with `-Dap_security=wpa2_psk|wpa3_sae|wpa_psk|open`; the ESP station has no
//! SAE, so `wpa3_sae` needs another station (a phone or a PC). With `-Dap_run_s=N` it reboots
//! into the firmware in flash after N seconds, so a RAM image (`pico2_w_ram_net-access_point`)
//! hands the board back to its own firmware without a BOOTSEL press.
const std = @import("std");
const microzig = @import("microzig");
const rp2xxx = microzig.hal;
const time = rp2xxx.time;
const gpio = rp2xxx.gpio;
const drivers = rp2xxx.drivers;

const uart = rp2xxx.uart.instance.num(0);
const uart_tx_pin = gpio.num(0);
pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .log_level = .debug,
    .logFn = rp2xxx.uart.log,
});

comptime {
    _ = microzig.export_startup();
}

const log = std.log.scoped(.main);

comptime {
    _ = @import("lwip_exports.zig");
}
const net = @import("net");
const dhcp = @import("dhcp_server");
const ap_options = @import("ap_options");
const security = @field(drivers.WiFi.Chip.ApOptions.Security, ap_options.security);

// A lease ends only by its holder's own message or by expiry (one hour). The CYW43439 driver
// sets no station limit, so the pool cannot be sized against one: sixteen leases cover more
// stations, present and departed within the lease time, than this example expects. Past that,
// a new client gets no offer until a lease runs out. docs/design/dhcp-server.md (Pool sizing).
const Dhcp = dhcp.Server(.{ .lease_count = 16 });

const ssid = "microzig-softap";
const password = "microzig-demo";
const echo_port = 7;

pub fn main() !void {
    uart_tx_pin.set_function(.uart);
    uart.apply(.{ .clock_config = rp2xxx.clock_config });
    rp2xxx.uart.init_logger(uart);

    var wifi_driver: drivers.WiFi = .{};
    var wifi = try wifi_driver.init(.{});
    var led = wifi.gpio(0);

    log.info("starting access point ssid={s} security={t}", .{ ssid, security });
    try wifi.start_ap(ssid, password, .{ .security = security, .channel = 6 });

    var nic: net.Interface = .{ .link = wifi.link() };
    try nic.init(wifi.mac, .{ .fixed = .{
        .ip = .{ .addr = @bitCast(Dhcp.server_ip) },
        .netmask = .{ .addr = @bitCast(Dhcp.netmask) },
        .gw = .{ .addr = 0 },
    } });

    try dhcp_context.init(&nic);

    var echo_server: net.tcp.Server = .{ .nic = &nic, .on_accept = on_accept };
    try echo_server.bind(echo_port);
    log.info("serving DHCP and TCP echo on {d}.{d}.{d}.{d}:{d}", .{
        Dhcp.server_ip[0], Dhcp.server_ip[1], Dhcp.server_ip[2], Dhcp.server_ip[3], echo_port,
    });

    const started = time.get_time_since_boot();
    var ts = started;
    while (true) {
        nic.poll() catch |err| log.err("net poll {}", .{err});

        const now = time.get_time_since_boot();
        if (ap_options.run_s != 0 and now.diff(started).to_us() >= @as(u64, ap_options.run_s) * std.time.us_per_s) {
            log.info("run time over, rebooting into the flash firmware", .{});
            reboot_to_flash();
        }
        if (now.diff(ts).to_us() > 500_000) {
            ts = now;
            led.toggle();
        }
    }
}

fn reboot_to_flash() noreturn {
    microzig.cpu.interrupt.disable_interrupts();
    // A cleared SCRATCH4 makes the bootrom take the normal (flash) boot path.
    microzig.chip.peripherals.WATCHDOG.SCRATCH4.raw = 0;
    rp2xxx.watchdog.force();
    while (true) {}
}

// Lives for the firmware lifetime: lwIP keeps pointers to the UDP wrapper.
var dhcp_context: DhcpContext = undefined;

// on_recv finds this struct from its udp field, so the struct must not need more alignment
// than net.Udp has.
const DhcpContext = struct {
    udp: net.Udp,
    server: Dhcp,
    // A DHCP request fits in one Ethernet frame; reassemble its pbuf segments here.
    packet: [1500]u8,
    len: usize,
    overflow: bool,

    fn init(self: *DhcpContext, nic: *net.Interface) !void {
        self.* = .{ .udp = try .init(nic), .server = .{}, .packet = undefined, .len = 0, .overflow = false };
        try self.udp.bind(dhcp.server_port, on_recv);
    }

    fn on_recv(udp: *net.Udp, data: []u8, opt: net.Udp.RecvOptions) void {
        const self: *DhcpContext = @fieldParentPtr("udp", udp);
        defer if (opt.last_fragment) {
            self.len = 0;
            self.overflow = false;
        };
        if (opt.src.port != dhcp.client_port) return;
        if (data.len > self.packet.len - self.len) self.overflow = true;
        if (self.overflow) return;
        @memcpy(self.packet[self.len..][0..data.len], data);
        self.len += data.len;
        if (!opt.last_fragment) return;

        const now_ms: u32 = @truncate(time.get_time_since_boot().to_us() / std.time.us_per_ms);
        const reply = self.server.receive(self.packet[0..self.len], now_ms) orelse return;
        const destination: net.Endpoint = .{
            .addr = .{ .u_addr = .{ .ip4 = .{ .addr = @bitCast(reply.destination) } }, .type = 0 },
            .port = dhcp.client_port,
        };
        udp.send(&reply.bytes, destination) catch |err| {
            log.err("DHCP send: {}", .{err});
            return;
        };
        if (reply.leased_ip) |ip| log.info("lease mac={x} ip={d}.{d}.{d}.{d}", .{ reply.mac, ip[0], ip[1], ip[2], ip[3] });
    }
};

var sessions: [2]net.tcp.Connection = @splat(.{});

fn on_accept() ?*net.tcp.Connection {
    for (&sessions) |*conn| {
        if (conn.state != .closed) continue;
        conn.* = .{ .on_recv = echo, .on_close = on_close };
        return conn;
    }
    return null;
}

fn echo(conn: *net.tcp.Connection, bytes: []u8) void {
    conn.send(bytes) catch |err| {
        log.err("echo send: {}", .{err});
        conn.close() catch {};
    };
}

fn on_close(_: *net.tcp.Connection, err: net.Error) void {
    log.info("echo connection closed {}", .{err});
}
