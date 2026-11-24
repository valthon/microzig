//! Deterministic FIFO/host seam; only selected by host unit tests.
var bytes: [16384]u8 = undefined;
var len: usize = 0;
var packet_len: usize = 0;
var ready_at: u64 = 0;
var committed = false;
var now: u64 = 0;
pub var latency_us: u64 = 0;
pub var masked = false;
pub var stall_packet: ?usize = null;
var packet_count: usize = 0;
pub fn reset() void {
    len = 0;
    packet_len = 0;
    ready_at = 0;
    committed = false;
    now = 0;
    latency_us = 0;
    masked = false;
    stall_packet = null;
    packet_count = 0;
}
pub fn output() []const u8 {
    return bytes[0..len];
}
pub fn get_time_since_boot() @import("microzig").drivers.time.Absolute {
    now += 10;
    return .from_us(now);
}
pub fn advance(us: u64) void {
    now += us;
}
pub fn full() bool {
    if (!committed) return false;
    if (now < ready_at) return true;
    @memcpy(bytes[len..][0..packet_len], packet[0..packet_len]);
    len += packet_len;
    packet_len = 0;
    committed = false;
    return false;
}
pub fn flush() void {
    if (committed or packet_len == 0) return;
    committed = true;
    packet_count += 1;
    ready_at = now + if (stall_packet == packet_count) @as(u64, 10_000) else latency_us;
}
var packet: [64]u8 = undefined;
pub fn write(byte: u8) void {
    @import("std").debug.assert(!committed);
    packet[packet_len] = byte;
    packet_len += 1;
    if (packet_len == 64) flush();
}
pub const interrupt = struct {
    const CriticalSection = struct {
        pub fn leave(_: @This()) void {}
    };
    pub fn enter_critical_section() CriticalSection {
        return .{};
    }
};
