//! Hardware-independent console, UART phases, replay storage and width checks.
const std = @import("std");
pub const Mode = enum { idle, uart, spi, i2s, rmt, parl, lpuart, i2c };
pub const Bank = enum { c3, c6 };
pub const Command = union(enum) {
    mode: struct { mode: Mode, bank: Bank },
    status,
    reset,
    boot,
};
pub fn parse(line: []const u8) error{InvalidCommand}!Command {
    var words = std.mem.tokenizeAny(u8, line, " \t\r");
    const verb = words.next() orelse return error.InvalidCommand;
    const cmd: Command = if (std.mem.eql(u8, verb, "mode")) blk: {
        const mode = std.meta.stringToEnum(Mode, words.next() orelse return error.InvalidCommand) orelse return error.InvalidCommand;
        const bank = std.meta.stringToEnum(Bank, words.next() orelse return error.InvalidCommand) orelse return error.InvalidCommand;
        if (bank == .c3 and (mode == .parl or mode == .lpuart or mode == .i2c)) return error.InvalidCommand;
        break :blk .{ .mode = .{ .mode = mode, .bank = bank } };
    } else if (std.mem.eql(u8, verb, "status")) .status else if (std.mem.eql(u8, verb, "reset")) .reset else if (std.mem.eql(u8, verb, "boot")) .boot else return error.InvalidCommand;
    if (words.next() != null) return error.InvalidCommand;
    return cmd;
}
pub const UartPhase = struct {
    phase: enum { p0, p1, p2 } = .p0,
    burst: usize = 0,
    last_us: ?u64 = null,
    pub fn receive(self: *UartPhase, now: u64) void {
        self.burst +|= 1;
        self.last_us = now;
    }
    pub fn idle(self: *UartPhase, now: u64) bool {
        const last = self.last_us orelse return false;
        if (now - last < (if (self.phase == .p2) @as(u64, 2_000_000) else 50_000)) return false;
        const old = self.phase;
        self.phase = switch (old) {
            .p0 => if (self.burst >= 300) .p1 else .p0,
            .p1 => if (self.burst >= 300) .p2 else .p1,
            .p2 => .p0,
        };
        self.burst = 0;
        // P2 must time out even if its parity transfer never arrives.
        self.last_us = if (self.phase == .p2) last else null;
        return old != self.phase;
    }
    pub fn baud(self: UartPhase) u32 {
        return if (self.phase == .p1) 1_000_000 else 115_200;
    }
};

pub const Replay = struct {
    bytes: [16384]u8 = @splat(0),
    len: usize = 0,
    pub fn clear(self: *Replay) void {
        self.len = 0;
    }
    pub fn get(self: *const Replay, index: usize) u8 {
        return if (index < self.len) self.bytes[index] else 0;
    }
    pub fn word(self: *const Replay, index: usize) u32 {
        return (@as(u32, self.get(index * 4)) << 24) | (@as(u32, self.get(index * 4 + 1)) << 16) |
            (@as(u32, self.get(index * 4 + 2)) << 8) | self.get(index * 4 + 3);
    }
};

pub fn serial_byte(word: u32) u8 {
    var byte: u8 = 0;
    for (0..8) |i| byte = (byte << 1) | @as(u8, @intCast((word >> @intCast((7 - i) * 4 + 1)) & 1));
    return byte;
}

test "serial DMA nibble extraction preserves MOSI MSB order" {
    try std.testing.expectEqual(@as(u8, 0xa5), serial_byte(0xf5e44f5e));
    try std.testing.expectEqual(@as(u8, 0), serial_byte(0x44444444));
    try std.testing.expectEqual(@as(u8, 255), serial_byte(0x66666666));
}

/// SPI CS/clock and I2S BCK/WS must remain idle
/// for at least 100 ms between transfers, allowing decode and rearming.
pub const FrameTiming = struct {
    last_end_us: ?u64 = null,
    pub fn check_start(self: FrameTiming, now: u64) error{InterframeGap}!void {
        if (self.last_end_us) |end| {
            if (now < end or now - end < 100_000) return error.InterframeGap;
        }
    }
};

test "serial frame gap rejects early restart and accepts exact boundary" {
    var timing: FrameTiming = .{};
    try timing.check_start(0);
    timing.last_end_us = 1234;
    try std.testing.expectError(error.InterframeGap, timing.check_start(1233));
    try std.testing.expectError(error.InterframeGap, timing.check_start(101233));
    try timing.check_start(101234);
    try timing.check_start(900000);
}

pub fn rmt_expected_us(half: usize, item_count: usize) u32 {
    return if (half / 2 == item_count) 256 else @intCast(4 * (1 + half % 127));
}
/// Widths include the guard high; the final low merges into idle and is absent.
/// PIO timer counts are in tenths of a microsecond.
pub fn rmt_first_bad(widths: []const u32, item_count: usize) ?usize {
    if (widths.len != item_count * 2 + 1) return @min(widths.len, item_count * 2 + 1);
    for (widths, 0..) |width, half| {
        const expected = rmt_expected_us(half, item_count) * 10;
        if (@abs(@as(i64, width) - expected) > 20) return half;
    }
    return null;
}
pub fn clock_hz(cycles: u64, elapsed_us: u64) ?u32 {
    if (elapsed_us == 0 or cycles > std.math.maxInt(u64) / 1_000_000) return null;
    return std.math.cast(u32, cycles * 1_000_000 / elapsed_us);
}
pub fn clock_pass(hz: u32, expected: u32) bool {
    return @abs(@as(i64, hz) - expected) * 100 <= expected;
}

/// UART idle/echo latency stretches high intervals. Only low runs measure
/// consecutive bits; an 8E1 low run spans at most 10 bits (8N1 at most 9).
/// The edge timer
/// uses two cycles per decrement plus four cycles between falling/rising
/// observations (RP2350 PIO instruction timing, programs.rmt_capture).
pub fn uart_edge_baud(widths: []const u32, sampler_hz: u32, expected: u32) ?u32 {
    if (sampler_hz == 0 or expected == 0) return null;
    var total_cycles: u64 = 0;
    var total_bits: u64 = 0;
    for (widths, 0..) |width, i| {
        if (i % 2 == 0) continue;
        const cycles = @as(u64, width) * 2 + 4;
        const bits = (cycles * expected + sampler_hz / 2) / sampler_hz;
        if (bits == 0 or bits > 10) continue;
        total_cycles += cycles;
        total_bits += bits;
    }
    if (total_bits == 0) return null;
    return std.math.cast(u32, total_bits * sampler_hz / total_cycles);
}

test "LP UART clock ignores inter-byte echo latency and idle high" {
    const widths = [_]u32{ 10000000, 85, 10000000, 172, 10000000, 259 };
    const hz = uart_edge_baud(&widths, 20_000_000, 115200).?;
    try std.testing.expect(clock_pass(hz, 115200));
    const slow = [_]u32{ 10000000, 94, 10000000, 190, 10000000, 286 };
    try std.testing.expect(!clock_pass(uart_edge_baud(&slow, 20_000_000, 115200).?, 115200));
    try std.testing.expectEqual(null, uart_edge_baud(&.{10000000}, 20_000_000, 115200));
    try std.testing.expectEqual(null, uart_edge_baud(&widths, 0, 115200));
}

test "strict command grammar and bank availability" {
    const t = std.testing;
    try t.expectEqual(Mode.spi, (try parse("mode spi c3\r")).mode.mode);
    try t.expectEqual(Command.status, try parse("status"));
    for ([_][]const u8{ "", "status extra", "mode spi", "mode spi c3 extra", "mode bad c6", "mode parl c3", "reset now" }) |line|
        try t.expectError(error.InvalidCommand, parse(line));
}
test "UART short probes, bursts, exact deadlines and parity idle return" {
    var phase: UartPhase = .{};
    phase.receive(0);
    try std.testing.expect(!phase.idle(50_000));
    for (0..300) |i| phase.receive(100_000 + i);
    try std.testing.expect(!phase.idle(150_298));
    try std.testing.expect(phase.idle(150_299));
    try std.testing.expectEqual(@as(u32, 1_000_000), phase.baud());
    for (0..300) |i| phase.receive(200_000 + i);
    try std.testing.expect(phase.idle(250_299));
    try std.testing.expectEqual(.p2, phase.phase);
    phase.receive(300_000);
    try std.testing.expect(!phase.idle(2_299_999));
    try std.testing.expect(phase.idle(2_300_000));
    try std.testing.expectEqual(.p0, phase.phase);
}
test "UART P2 timeout recovers when no parity transfer arrives" {
    for ([_]u64{ 2_100_299, 3_000_000 }) |timeout_poll| {
        var phase: UartPhase = .{};
        for (0..300) |i| phase.receive(i);
        try std.testing.expect(phase.idle(50_299));
        for (0..300) |i| phase.receive(100_000 + i);
        try std.testing.expect(phase.idle(150_299));
        try std.testing.expectEqual(.p2, phase.phase);
        // No receive() in P2: both the exact deadline and a delayed poll
        // must restore P0, using the last activity in P1 as the idle origin.
        try std.testing.expect(!phase.idle(2_100_298));
        try std.testing.expect(phase.idle(timeout_poll));
        try std.testing.expectEqual(.p0, phase.phase);
        try std.testing.expectEqual(@as(u32, 115200), phase.baud());
        try std.testing.expect(!phase.idle(timeout_poll + 1));
    }
}
test "RMT absolute widths, wrap, guard, tolerance and missing edges" {
    for ([_]usize{ 64, 137 }) |count| {
        var widths: [275]u32 = undefined;
        const frame = widths[0 .. 2 * count + 1];
        for (frame, 0..) |*width, i| width.* = rmt_expected_us(i, count) * 10;
        try std.testing.expectEqual(null, rmt_first_bad(frame, count));
        frame[4] += 20;
        try std.testing.expectEqual(null, rmt_first_bad(frame, count));
        frame[4] += 1;
        try std.testing.expectEqual(@as(?usize, 4), rmt_first_bad(frame, count));
        try std.testing.expect(rmt_first_bad(frame[0 .. frame.len - 1], count) != null);
    }
    try std.testing.expectEqual(@as(?u32, 1_000_000), clock_hz(80000, 80000));
    try std.testing.expect(clock_pass(990000, 1000000));
    try std.testing.expect(!clock_pass(989999, 1000000));
    try std.testing.expectEqual(null, clock_hz(1, 0));
}

/// Clock-meter two-cycle polls plus three branch cycles per period and two
/// setup cycles. The WAIT synchronizes the window's first rising edge.
pub fn meter_cycles(decrements: u32) u64 {
    return @as(u64, decrements) * 2 + 32 * 3 + 2;
}

test "clock meter detects common-mode 10 percent clock errors" {
    // 150 MHz calibration: 32 periods at 1 MHz occupy 4800 cycles.
    const nominal = meter_cycles((4800 - 98) / 2);
    try std.testing.expectEqual(@as(u64, 4800), nominal);
    try std.testing.expect(clock_pass(@intCast(150_000_000 * @as(u64, 32) / nominal), 1_000_000));
    try std.testing.expect(!clock_pass(@intCast(150_000_000 * @as(u64, 32) / meter_cycles((4364 - 98) / 2)), 1_000_000));
}
