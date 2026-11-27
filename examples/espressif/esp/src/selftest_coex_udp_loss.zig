//! The udp_loss verdict of selftest_coex_wifi_ble, shared by the firmware and
//! the host tests.
const std = @import("std");

pub const Mode = enum { A, B, C, D };
pub const modes = [_]Mode{ .A, .B, .C, .D };
pub const rounds = 3;
pub const phase_count = modes.len * rounds;

/// One phase's datagrams. `sent` counts every send attempt, so a datagram
/// that failed to send counts as lost.
pub const Counts = struct { sent: u32, echoed: u32 };

pub const Error = error{ NothingSent, NothingEchoed, BaselineLossAboveThreshold, LossAboveThreshold };

pub fn lost(counts: Counts) u32 {
    return counts.sent -| counts.echoed;
}

/// Phase `i` runs `modes[i % modes.len]`; D phases send no UDP and are
/// skipped. Every A, B and C phase must send a datagram and get an echo back.
/// An A phase may lose at most 2% of what it sent, so the baseline is bounded
/// even with the echo server down. A B or C phase may lose at most
/// max(2 x the A-mode median loss, 2% of what it sent). Each 2% rounds down.
pub fn check(phases: *const [phase_count]Counts) Error!void {
    for (phases, 0..) |counts, phase| {
        const mode = modes[phase % modes.len];
        if (mode == .D) continue;
        if (counts.sent == 0) return error.NothingSent;
        if (counts.echoed == 0) return error.NothingEchoed;
        if (mode == .A and lost(counts) > counts.sent / 50) return error.BaselineLossAboveThreshold;
    }
    const a_lost = a_median(phases);
    for (phases, 0..) |counts, phase| {
        const mode = modes[phase % modes.len];
        if (mode != .B and mode != .C) continue;
        if (lost(counts) > @max(2 * a_lost, counts.sent / 50)) return error.LossAboveThreshold;
    }
}

/// The median datagram loss of the A phases.
pub fn a_median(phases: *const [phase_count]Counts) u32 {
    var a_losses: [rounds]u32 = undefined;
    for (&a_losses, 0..) |*loss, round| loss.* = lost(phases[round * modes.len + @backingInt(Mode.A)]);
    std.mem.sort(u32, &a_losses, {}, std.sort.asc(u32));
    return a_losses[rounds / 2];
}

fn run(a: Counts, b: Counts, c: Counts) [phase_count]Counts {
    return run_rounds(@splat(a), b, c);
}

// Round `r` runs `a[r]`; every B and C phase runs `b` and `c`.
fn run_rounds(a: [rounds]Counts, b: Counts, c: Counts) [phase_count]Counts {
    var phases: [phase_count]Counts = undefined;
    for (&phases, 0..) |*counts, phase| counts.* = switch (modes[phase % modes.len]) {
        .A => a[phase / modes.len],
        .B => b,
        .C => c,
        .D => .{ .sent = 0, .echoed = 0 },
    };
    return phases;
}

test "a lossless run passes, and a B or C phase may lose 2% of what it sent" {
    try check(&run(.{ .sent = 600, .echoed = 600 }, .{ .sent = 600, .echoed = 600 }, .{ .sent = 600, .echoed = 600 }));
    try check(&run(.{ .sent = 600, .echoed = 600 }, .{ .sent = 600, .echoed = 588 }, .{ .sent = 601, .echoed = 589 }));
    try std.testing.expectError(error.LossAboveThreshold, check(&run(.{ .sent = 600, .echoed = 600 }, .{ .sent = 600, .echoed = 587 }, .{ .sent = 600, .echoed = 600 })));
}

test "a B or C phase may lose twice the A-mode median" {
    try check(&run(.{ .sent = 600, .echoed = 590 }, .{ .sent = 600, .echoed = 580 }, .{ .sent = 600, .echoed = 580 }));
    try std.testing.expectError(error.LossAboveThreshold, check(&run(.{ .sent = 600, .echoed = 590 }, .{ .sent = 600, .echoed = 579 }, .{ .sent = 600, .echoed = 600 })));
}

test "with the echo server down every phase fails, however much A lost" {
    try std.testing.expectError(error.NothingEchoed, check(&run(.{ .sent = 600, .echoed = 0 }, .{ .sent = 600, .echoed = 0 }, .{ .sent = 600, .echoed = 0 })));
}

test "the B and C bound is twice the median A loss, not the least or the most" {
    // A losses 100, 30, 110 (median 100) of 6000; the 2% floor is 120.
    const a: [rounds]Counts = .{ .{ .sent = 6000, .echoed = 5900 }, .{ .sent = 6000, .echoed = 5970 }, .{ .sent = 6000, .echoed = 5890 } };
    const clean: Counts = .{ .sent = 6000, .echoed = 6000 };
    try std.testing.expectEqual(100, a_median(&run_rounds(a, clean, clean)));
    try check(&run_rounds(a, .{ .sent = 6000, .echoed = 5800 }, .{ .sent = 6000, .echoed = 5800 }));
    try std.testing.expectError(error.LossAboveThreshold, check(&run_rounds(a, .{ .sent = 6000, .echoed = 5799 }, clean)));
    try std.testing.expectError(error.LossAboveThreshold, check(&run_rounds(a, clean, .{ .sent = 6000, .echoed = 5799 })));
}

test "an A phase may lose 2% of what it sent" {
    try check(&run(.{ .sent = 600, .echoed = 588 }, .{ .sent = 600, .echoed = 600 }, .{ .sent = 600, .echoed = 600 }));
    try check(&run_rounds(.{ .{ .sent = 600, .echoed = 600 }, .{ .sent = 600, .echoed = 588 }, .{ .sent = 600, .echoed = 600 } }, .{ .sent = 600, .echoed = 600 }, .{ .sent = 600, .echoed = 600 }));
}

test "an A phase that loses more than 2% fails instead of raising the B and C bound" {
    try std.testing.expectError(error.BaselineLossAboveThreshold, check(&run_rounds(.{ .{ .sent = 600, .echoed = 600 }, .{ .sent = 600, .echoed = 600 }, .{ .sent = 600, .echoed = 587 } }, .{ .sent = 600, .echoed = 600 }, .{ .sent = 600, .echoed = 600 })));
    try std.testing.expectError(error.BaselineLossAboveThreshold, check(&run(.{ .sent = 600, .echoed = 300 }, .{ .sent = 600, .echoed = 1 }, .{ .sent = 600, .echoed = 1 })));
    try std.testing.expectError(error.BaselineLossAboveThreshold, check(&run(.{ .sent = 600, .echoed = 587 }, .{ .sent = 600, .echoed = 600 }, .{ .sent = 600, .echoed = 600 })));
}

test "a phase that sent nothing fails" {
    try std.testing.expectError(error.NothingSent, check(&run(.{ .sent = 600, .echoed = 600 }, .{ .sent = 0, .echoed = 0 }, .{ .sent = 600, .echoed = 600 })));
}
