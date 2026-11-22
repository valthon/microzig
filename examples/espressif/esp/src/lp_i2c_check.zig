//! External Pico 2 W register-file peer at 0x42, shared by HP and LP.
//! Load pico2_w_ram_esp_peer and send `mode i2c c6` over Pico USB CDC.
//! Scan expects only 0x42 to ACK; check 14-byte readback and version 1 at
//! 0xf3, then NACK at 0x55 followed by ACK at 0x42.
//! GPIO6 SDA / GPIO7 SCL (ESP32-C6 datasheet v1.6 Table 2-7) connect to
//! Pico GP14 / GP15, with common GND and internal pull-ups at 100 kHz.
//! Peer protocol: i2c_slave_peer.zig, moved to I2C1 GP14/15. Pointer writes
//! and reads use separate STOP-terminated transactions; no repeated START.
const i2c = @import("microzig").hal.lp_i2c;
const peer: u7 = 0x42;
const poll_limit = 200000;

// Packed into the existing pad_level mailbox word by the LP image.
pub const Bits = packed struct(u32) {
    peer_found: bool = false,
    write_read: bool = false,
    nack: bool = false,
    recovered: bool = false,
    reserved: u28 = 0,
};
pub const Result = struct {
    nacks: u32 = 0,
    acks: u32 = 0,
    faults: u32 = 0,
    bits: Bits = .{},

    pub fn scan_ok(self: Result) bool {
        return self.acks == 1 and self.nacks == 111 and self.faults == 0 and self.bits.peer_found;
    }

    pub fn recovery_ok(self: Result) bool {
        return self.bits.nack and self.bits.recovered;
    }
};

pub fn run() Result {
    var result: Result = .{};
    i2c.apply(.{ .source_hz = 16_000_000, .bus_hz = 100000, .internal_pullups = true }) catch {
        result.faults = 1;
        return result;
    };
    for (0x08..0x78) |address| {
        if (i2c.probe(@intCast(address), poll_limit)) {
            result.acks += 1;
            if (address == peer) result.bits.peer_found = true;
        } else |err| {
            if (err == error.Nack) result.nacks += 1 else result.faults += 1;
        }
    }
    result.bits.write_read = write_read() catch false;
    if (i2c.write(0x55, &.{0xa5}, poll_limit)) {} else |err| {
        result.bits.nack = err == error.Nack;
    }
    // Always attempt the next valid transaction, including after a timeout.
    if (i2c.probe(peer, poll_limit)) {
        result.bits.recovered = true;
    } else |_| {
        result.bits.recovered = false;
    }
    return result;
}

fn write_read() i2c.Error!bool {
    // Pointer plus 14 pattern bytes fills the HAL's 15-data-byte write limit.
    const data = [_]u8{ 0x10, 0x00, 0xff, 0xa5, 0x5a, 0x01, 0x80, 0x7f, 0x55, 0xaa, 0x12, 0x34, 0x56, 0x78, 0x9b };
    try i2c.write(peer, &data, poll_limit);
    try i2c.write(peer, &.{0x10}, poll_limit);
    var received: [14]u8 = undefined;
    try i2c.read(peer, &received, poll_limit);
    var matches = true;
    for (received, data[1..]) |actual, expected| {
        if (actual != expected) matches = false;
    }
    try i2c.write(peer, &.{0xf3}, poll_limit);
    var version: [1]u8 = undefined;
    try i2c.read(peer, &version, poll_limit);
    return matches and version[0] == 1;
}
