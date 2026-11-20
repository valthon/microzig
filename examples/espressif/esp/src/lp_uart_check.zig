//! Same bounded polling exercise compiled for HP and LP.
const uart = @import("microzig").hal.lp_uart;
pub fn run() u32 {
    uart.apply(.{ .source_hz = 16_000_000, .loopback = true }, 200000) catch return 0;
    var bits: u32 = 0;
    for (0..64) |i| {
        const byte: u8 = @as(u8, @intCast(i)) *% 37;
        uart.write_byte(byte, 200000) catch return bits;
        const received = uart.read_byte(200000) catch return bits;
        if (received != byte) return bits;
    }
    bits |= 1;
    if (uart.read_byte(1000)) |_| {} else |err| {
        if (err == error.Timeout) bits |= 2;
    }
    return bits;
}
