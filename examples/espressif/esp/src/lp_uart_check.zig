//! External 115200 8N1 echo, compiled for HP and LP.
//! Wire ESP32-C6 GPIO4 RX <- Pico 2 W GP12 TX, GPIO5 TX -> GP13 RX,
//! and GND -> GND. Load pico2_w_ram_esp_peer and send `mode lpuart c6`
//! on Pico USB CDC. Success means all 64 pattern bytes echo unchanged,
//! followed by a timeout when reading the empty receive FIFO.
const uart = @import("microzig").hal.lp_uart;

pub const Result = packed struct(u32) {
    echo: bool = false,
    empty_timeout: bool = false,
    echo_error: enum(u30) { none, Timeout, RxFault, InvalidBaud, Mismatch } = .none,
};

// 8N1 takes 10/115200 = 86.8 us per byte. Allow both TX and echoed RX
// plus 1 ms peer latency (<1.174 ms). At the fastest core clock, 160 MHz
// (C6 TRM v1.2 §1.2), 400000 polls take at least 2.5 ms even at one cycle
// per poll; LP and MMIO overhead only increase that budget.
const poll_limit = 400_000;

pub fn run() Result {
    var result: Result = .{};
    echo() catch |err| {
        result.echo_error = switch (err) {
            error.Timeout => .Timeout,
            error.RxFault => .RxFault,
            error.InvalidBaud => .InvalidBaud,
            error.Mismatch => .Mismatch,
        };
    };
    result.echo = result.echo_error == .none;
    if (uart.read_byte(poll_limit)) |_| {} else |err| {
        result.empty_timeout = err == error.Timeout;
    }
    return result;
}

fn echo() (uart.Error || error{Mismatch})!void {
    // TRM v1.2 §8.2.4: XTAL_D2 is 20 MHz. HP remains awake to keep XTAL on.
    try uart.apply(.{ .baud = 115200, .clock = .xtal_d2, .source_hz = 20_000_000, .loopback = false }, poll_limit);
    for (0..64) |i| {
        const byte: u8 = @as(u8, @intCast(i)) *% 37;
        try uart.write_byte(byte, poll_limit);
        const received = try uart.read_byte(poll_limit);
        if (received != byte) return error.Mismatch;
    }
}
