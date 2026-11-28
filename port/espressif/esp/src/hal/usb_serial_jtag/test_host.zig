//! Deterministic FIFO/host seam; only selected by host unit tests.
var bytes: [16384]u8 = undefined;
var len: usize = 0;
var packet_len: usize = 0;
var ready_at: u64 = 0;
var committed = false;
var commit_stuck = false;
var now: u64 = 0;
var critical_depth: usize = 0;
pub var preemption: ?struct { at_us: u64, run: *const fn () void } = null;
pub var latency_us: u64 = 0;
var reading = true;
pub var masked = false;
pub var stall_packet: ?usize = null;
pub var stuck_at_boot = false;
pub var enumerating = false;
pub var bus_reset_at_us: ?u64 = null;
pub var fifo_accesses: usize = 0;
pub var status_reads: usize = 0;
pub var packet_count: usize = 0;
pub var packets_read: usize = 0;
pub var last_commit_us: u64 = 0;
pub var recommits: usize = 0;
pub fn reset() void {
    len = 0;
    reset_controller();
    now = 0;
    critical_depth = 0;
    preemption = null;
    latency_us = 0;
    reading = true;
    masked = false;
    stall_packet = null;
    enumerating = false;
    bus_reset_at_us = null;
    fifo_accesses = 0;
    status_reads = 0;
    packet_count = 0;
    packets_read = 0;
    last_commit_us = 0;
    recommits = 0;
}
pub fn reset_controller() void {
    packet_len = 0;
    ready_at = 0;
    committed = false;
    commit_stuck = false;
    stuck_at_boot = false;
}
pub fn output() []const u8 {
    return bytes[0..len];
}
pub fn get_time_since_boot() @import("microzig").drivers.time.Absolute {
    // A preemption at the sampling boundary can delay returning the sample.
    const sampled = now + 10;
    advance(10);
    return .from_us(sampled);
}
pub fn clock_us() u64 {
    return now;
}
pub fn bus_reset_pending() bool {
    const at = bus_reset_at_us orelse return false;
    return now >= at;
}
pub fn set_reading(active: bool) void {
    reading = active;
    consume();
}
pub fn advance(us: u64) void {
    const end = now + us;
    if (preemption) |event| {
        if (!masked and critical_depth == 0 and event.at_us <= end) {
            now = @max(now, event.at_us);
            consume();
            preemption = null;
            event.run();
        }
    }
    now = @max(now, end);
    consume();
}
pub fn full() bool {
    fifo_accesses += 1;
    status_reads += 1;
    return stuck_at_boot or committed;
}
fn consume() void {
    if (!committed or commit_stuck or !reading or now < ready_at) return;
    @memcpy(bytes[len..][0..packet_len], packet[0..packet_len]);
    len += packet_len;
    packet_len = 0;
    committed = false;
    packets_read += 1;
}
pub fn flush() void {
    fifo_accesses += 1;
    stuck_at_boot = false;
    if (committed) {
        recommits += 1;
        last_commit_us = now;
        if (commit_stuck and !enumerating) {
            commit_stuck = false;
            ready_at = now + latency_us;
            consume();
        }
        return;
    }
    committed = true;
    commit_stuck = enumerating;
    packet_count += 1;
    last_commit_us = now;
    ready_at = now + if (stall_packet == packet_count) @as(u64, 10_000) else latency_us;
    consume();
}
var packet: [64]u8 = undefined;
pub fn write(byte: u8) void {
    fifo_accesses += 1;
    @import("std").debug.assert(!committed);
    packet[packet_len] = byte;
    packet_len += 1;
    if (packet_len == 64) flush();
}
pub const interrupt = struct {
    const CriticalSection = struct {
        pub fn leave(_: @This()) void {
            critical_depth -= 1;
        }
    };
    pub fn enter_critical_section() CriticalSection {
        critical_depth += 1;
        return .{};
    }
};
