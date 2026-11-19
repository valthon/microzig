//! CPU SHA, ESP32-C6 TRM v1.2 §§23.4.1–23.4.2.1 (same CPU interface on C3).
//! Synchronous, no allocation. Do not use from interrupts or concurrently with DS/HMAC.
const std = @import("std");
const microzig = @import("microzig");
const system = @import("system.zig");
const SHA = microzig.chip.peripherals.SHA;
const CPU = microzig.chip.peripherals.SHA_CPU;
pub const Algorithm = enum(u2) {
    sha1 = 0,
    sha224 = 1,
    sha256 = 2,

    pub fn digest_length(a: Algorithm) usize {
        return switch (a) {
            .sha1 => 20,
            .sha224 => 28,
            .sha256 => 32,
        };
    }
};
pub const Error = error{ Timeout, InvalidOutput };

/// Output must have exactly algorithm.digest_length() bytes. A timeout resets the engine.
pub fn hash(algorithm: Algorithm, input: []const u8, output: []u8) Error!void {
    if (output.len != algorithm.digest_length()) return error.InvalidOutput;
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    system.enable_clocks_and_release_reset(.{ .crypto_sha = true });
    // ESP-IDF sha_ll_reset_register: these parent reset lines also hold SHA in reset.
    system.peripheral_reset_clear(.{ .crypto_ds = true, .crypto_hmac = true });
    system.peripheral_reset(.{ .crypto_sha = true });
    defer system.peripheral_reset(.{ .crypto_sha = true });
    SHA.MODE.write(.{ .MODE = @backingInt(algorithm) });
    var offset: usize = 0;
    var first = true;
    while (input.len - offset >= 64) : (offset += 64) {
        try block(input[offset..][0..64], first);
        first = false;
    }
    var tail: [64]u8 = @splat(0);
    const remainder = input.len - offset;
    @memcpy(tail[0..remainder], input[offset..]);
    tail[remainder] = 0x80;
    if (remainder >= 56) {
        try block(&tail, first);
        first = false;
        tail = @splat(0);
    }
    std.mem.writeInt(u64, tail[56..64], @as(u64, input.len) * 8, .big);
    try block(&tail, first);
    inline for (0..8) |i| {
        if (i * 4 < output.len)
            std.mem.writeInt(u32, output[i * 4 ..][0..4], @field(CPU, "H" ++ std.fmt.comptimePrint("{d}", .{i})).read().VALUE, .little);
    }
}

fn block(data: *const [64]u8, first: bool) Error!void {
    inline for (0..16) |i| {
        @field(CPU, "M" ++ std.fmt.comptimePrint("{d}", .{i})).write(.{ .VALUE = std.mem.readInt(u32, data[i * 4 ..][0..4], .little) });
    }
    if (first) CPU.START.write(.{ .VALUE = 1 }) else CPU.CONTINUE.write(.{ .VALUE = 1 });
    for (0..100_000) |_| {
        if (SHA.BUSY.read().STATE == 0) return;
    }
    return error.Timeout;
}
