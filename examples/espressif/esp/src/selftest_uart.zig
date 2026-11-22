//! External UART echo, baud timing and parity test with automatic route probing.
//! Pico 2 W: ESP C6 TX GPIO1 -> GP9 RX, RX GPIO0 <- GP8 TX;
//! ESP C3 TX GPIO1 -> GP1 RX, RX GPIO0 <- GP0 TX; connect common GND.
//! Load pico2_w_ram_esp_peer, then send `mode uart c6` or `mode uart c3`
//! on its USB CDC console before starting the ESP self-test.
//! XIAO ESP32-C6 alternative: TX D6/GPIO16 -> RP2040-GEEK GP5 RX,
//! RX D2/GPIO2 <- GEEK GP4 TX, GND -> GND. Keep debugprobe on the GEEK;
//! run `python geek_uart_peer.py --port <GEEK-port> --seconds 30`.
//! Connect only one route. The peer echoes 115200 8N1, then 1M 8N1, then
//! 115200 8E1. Each >=300-byte burst advances after 50 ms idle; probes do not.
//! Even-parity mode returns to 115200 8N1 after 2 s idle on the Pico.
//! UART is full duplex on separate pads, so TX stays driven while RX echoes.
//! PASS: SELFTEST uart DONE pass=7 fail=0, matching 300-byte echoes,
//! TX duration within 10%, odd-parity rejection and even-parity acceptance;
//! Also require PEER uart parity_rx: PASS and no peer FAIL verdicts;
//! with the Pico, request `status` and require PEER uart clk: PASS
//! (worst qualifying bit clock within 1% of the selected baud).
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const uart1 = hal.uart.instance.num(1);
const uart0 = hal.uart.instance.num(0);
const mtime = microzig.drivers.time;
const is_c6 = std.mem.eql(u8, microzig.config.chip_name, "ESP32-C6");
const TestError = hal.uart.Error || hal.uart.ConfigError || error{
    NoRoute,
    AmbiguousRoute,
    DataMismatch,
    BadTiming,
    ExpectedParityError,
};

// C6 datasheet v1.6 §2.3.5: GPIO0/1/2 are priority 2 (free);
// GPIO16 is priority 3 (UART0, use with caution). C3 datasheet v2.5
// §2.3.4: GPIO0/1 are priority 2. USB logging leaves UART0 available.
const Route = enum {
    pico,
    geek,

    fn tx(self: Route) hal.gpio.Pin {
        return hal.gpio.num(if (self == .pico) 1 else 16);
    }

    fn rx(self: Route) hal.gpio.Pin {
        return hal.gpio.num(if (self == .pico) 0 else 2);
    }

    fn release(self: Route) void {
        self.tx().apply(.{});
        self.rx().apply(.{});
    }
};

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_level = .info,
});
comptime {
    _ = microzig.export_startup();
}

const Result = struct {
    err: ?TestError = error.NoRoute,
    elapsed_us: u64 = 0,
    expected_us: u64 = 0,
};

fn probe(route: Route) TestError!bool {
    defer route.release();
    // Route and pull up RX before init: its FIFO reset then discards
    // anything latched while RX read the unrouted (low) matrix input.
    uart1.connect_pins(.{ .tx = route.tx(), .rx = route.rx() });
    // An absent peer must leave RX idle, rather than a floating break input.
    route.rx().apply(.{ .input_enable = true, .pull = .up });
    try uart1.init(.{});
    try uart1.write_blocking(&.{0x5a}, .from_ms(5));
    var byte: [1]u8 = undefined;
    // The GEEK echo crosses the host PC (USB CDC both ways); allow for that.
    uart1.read_blocking(&byte, .from_ms(100)) catch |err| return switch (err) {
        error.Timeout => false,
        else => err,
    };
    try uart1.flush_blocking(.from_ms(5));
    return byte[0] == 0x5a;
}

fn detect_route() TestError!Route {
    const pico = try probe(.pico);
    const geek = if (is_c6) try probe(.geek) else false;
    if (pico and geek) return error.AmbiguousRoute;
    if (pico) return .pico;
    if (geek) return .geek;
    return error.Timeout;
}

fn round_trip(route: Route, baud: u32, data: *Result, timing: *Result) TestError!void {
    defer route.release();
    uart1.connect_pins(.{ .tx = route.tx(), .rx = route.rx() });
    route.rx().apply(.{ .input_enable = true, .pull = .up });
    try uart1.init(.{ .baud_rate = baud });
    var tx: [300]u8 = undefined;
    var rx: [300]u8 = undefined;
    var state: u32 = 0x6d2b79f5;
    for (&tx) |*byte| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = @truncate(state);
    }
    var sent: usize = 0;
    var received: usize = 0;
    const start = hal.systimer.unit(0).read();
    const deadline = mtime.Deadline.init_relative(hal.time.get_time_since_boot(), .from_ms(500));
    var tx_done = false;
    timing.expected_us = 300 * @as(u64, 10) * 1_000_000 / baud;
    // Drain while refilling: both UARTs have 128-byte RX FIFOs (C3 TRM
    // v1.4 §26.4.2 / C6 TRM v1.2 §27.4.2). USB echo may lag TX.
    while (received < rx.len or !tx_done) {
        if (deadline.is_reached_by(hal.time.get_time_since_boot())) return error.Timeout;
        received += try uart1.try_read(rx[received..]);
        sent += uart1.try_write(tx[sent..]);
        if (!tx_done and sent == tx.len and uart1.is_tx_idle()) {
            try uart1.flush_blocking(.from_ms(5));
            timing.elapsed_us = (hal.systimer.unit(0).read() - start) / hal.systimer.ticks_per_us();
            const expected = timing.expected_us;
            timing.err = if (timing.elapsed_us >= expected * 9 / 10 and
                timing.elapsed_us <= expected * 11 / 10) null else error.BadTiming;
            tx_done = true;
        }
    }
    data.err = if (std.mem.eql(u8, &tx, &rx)) null else error.DataMismatch;
}

fn run_round_trip(route: Route, baud: u32, data: *Result, timing: *Result) void {
    round_trip(route, baud, data, timing) catch |err| {
        data.err = err;
        // A completed TX measurement remains valid even if the echo times out.
        if (timing.err) |previous| {
            if (previous == error.NoRoute) timing.err = err;
        }
    };
}

fn parity_test(route: Route, parity: hal.uart.Parity, value: u8) TestError!void {
    defer route.release();
    // PARITY controls TX and RX together (C3 TRM v1.4 §26.4.4 /
    // C6 TRM v1.2 §27.4.4). UART0 always sends even to the peer; UART1
    // receives its even echo, first with odd parity, then with even parity.
    uart1.connect_pins(.{ .rx = route.rx() });
    route.rx().apply(.{ .input_enable = true, .pull = .up });
    uart0.connect_pins(.{ .tx = route.tx() });
    try uart1.init(.{ .parity = parity });
    try uart0.init(.{ .parity = .even });
    uart1.clear_rx_errors();
    try uart0.write_blocking(&.{value}, .from_ms(100));
    try uart0.flush_blocking(.from_ms(100));
    var byte: [1]u8 = undefined;
    uart1.read_blocking(&byte, .from_ms(500)) catch |err| {
        if (parity == .odd and err == error.ParityError) return;
        return err;
    };
    if (parity == .odd) return error.ExpectedParityError;
    if (byte[0] != value) return error.DataMismatch;
}

const names = [_][]const u8{
    "route",          "roundtrip_115200", "timing_115200", "roundtrip_1000000",
    "timing_1000000", "parity_mismatch",  "parity_match",
};

pub fn main() void {
    var results: [names.len]Result = @splat(.{});
    var selected: ?Route = null;
    if (detect_route()) |route| {
        selected = route;
        results[0].err = null;
        run_round_trip(route, 115200, &results[1], &results[2]);
        hal.time.sleep_ms(100);
        run_round_trip(route, 1_000_000, &results[3], &results[4]);
        hal.time.sleep_ms(100);
        if (parity_test(route, .odd, 0x55)) |_| {
            results[5].err = null;
        } else |err| {
            results[5].err = err;
        }
        if (parity_test(route, .even, 0xaa)) |_| {
            results[6].err = null;
        } else |err| {
            results[6].err = err;
        }
    } else |err| {
        results[0].err = err;
    }
    var pass: u32 = 0;
    for (results) |result| pass += @intFromBool(result.err == null);
    hal.time.sleep_ms(1500);
    while (true) {
        for (names, results) |name, result| {
            std.log.info("SELFTEST uart {s}: {s} error={s} peer={s} us={} expected={}", .{
                name,                                              if (result.err == null) "PASS" else "FAIL",
                if (result.err) |err| @errorName(err) else "none", if (selected) |route| @tagName(route) else "none",
                result.elapsed_us,                                 result.expected_us,
            });
        }
        std.log.info("SELFTEST uart DONE pass={} fail={}", .{ pass, names.len - pass });
        hal.time.sleep_ms(1000);
    }
}
