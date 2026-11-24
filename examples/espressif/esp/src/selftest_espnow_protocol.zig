//! Rendezvous shared by the firmware and the deterministic host simulation.
const std = @import("std");

pub const discovery_ms = 22000;
pub const phase_ms = 8000;
pub const exchange_ms = 4000;

pub const Discovery = struct {
    own: [6]u8,
    peer: ?[6]u8 = null,

    pub fn receive(self: *Discovery, source: [6]u8, kind: u8, phase: u8) bool {
        if (std.mem.eql(u8, &source, &self.own)) return false;
        if (kind != 0 and !(kind == 1 and phase == 1)) return false;
        if (self.peer) |peer| {
            if (!std.mem.eql(u8, &source, &peer)) return false;
        } else self.peer = source;
        // Only the coordinator can leave on a hello. The follower keeps sending
        // hellos until a phase request proves that the coordinator knows its MAC.
        // The coordinator repeats phase 1 while the follower checks its peer table.
        return std.mem.order(u8, &self.own, &source) == .lt or kind == 1;
    }
};

test "rendezvous ignores self, unrelated packets and a third board" {
    var discovery: Discovery = .{ .own = .{ 2, 0, 0, 0, 0, 2 } };
    const peer = [6]u8{ 2, 0, 0, 0, 0, 1 };
    try std.testing.expect(!discovery.receive(discovery.own, 0, 0));
    try std.testing.expect(!discovery.receive(peer, 3, 1));
    try std.testing.expect(discovery.peer == null);
    try std.testing.expect(!discovery.receive(peer, 0, 0));
    try std.testing.expect(!discovery.receive(.{ 2, 0, 0, 0, 0, 3 }, 1, 1));
    try std.testing.expect(!discovery.receive(peer, 1, 2));
    try std.testing.expect(discovery.receive(peer, 1, 1));
}

test "either boot order and lost hellos, phase requests and acknowledgments converge" {
    // 50 ms steps. Table checks deliberately take two seconds on each side.
    // Drop the first follower hello (the hardware failure), then bursts of three
    // frames and every fifth later frame. Sweep the boot gap through ten seconds.
    for (0..2) |first| {
        for (0..201) |gap| {
            const Board = struct {
                discovery: Discovery,
                boot: usize,
                stage: enum { discovering, table, phases, done } = .discovering,
                until: usize = 0,
                next_send: usize = 0,
                sent: usize = 0,
                discovered_at: ?usize = null,
                pending_ack: bool = false,
            };
            var boards = [_]Board{
                .{ .discovery = .{ .own = .{ 2, 0, 0, 0, 0, 1 } }, .boot = if (first == 0) 0 else gap * 50 },
                .{ .discovery = .{ .own = .{ 2, 0, 0, 0, 0, 2 } }, .boot = if (first == 1) 0 else gap * 50 },
            };
            var requests: usize = 0;
            var acks: usize = 0;
            var time: usize = 0;
            while (time < 30000) : (time += 50) {
                for (&boards, 0..) |*board, index| {
                    if (time < board.boot or board.stage == .done) continue;
                    if (board.stage == .table) {
                        if (time < board.until) continue;
                        board.stage = .phases;
                        board.until = time + phase_ms;
                    }
                    if (board.stage == .discovering)
                        try std.testing.expect(time - board.boot < discovery_ms);
                    if (index == 0 and board.stage == .phases)
                        try std.testing.expect(time < board.until);
                    if (index == 1 and board.stage == .phases and !board.pending_ack) continue;
                    if (time < board.next_send) continue;
                    board.pending_ack = false;
                    board.next_send = time + 250;
                    board.sent += 1;
                    if (board.sent <= 3 or board.sent % 5 == 0) continue;
                    const kind: u8 = if (board.stage == .discovering) 0 else if (index == 0) 1 else 2;
                    if (kind == 1) {
                        requests += 1;
                        if (requests <= 3) continue;
                    }
                    if (kind == 2) {
                        acks += 1;
                        if (acks <= 3) continue;
                    }
                    const receiver = &boards[1 - index];
                    if (time < receiver.boot) continue;
                    if (receiver.stage == .discovering) {
                        if (receiver.discovery.receive(board.discovery.own, kind, if (kind == 0) 0 else 1)) {
                            receiver.stage = .table;
                            receiver.until = time + 2000;
                            receiver.discovered_at = time;
                        }
                    } else if (receiver.stage == .phases and kind == 1 and index == 0) {
                        receiver.pending_ack = true;
                    } else if (receiver.stage == .phases and kind == 2 and index == 1) {
                        boards[0].stage = .done;
                        boards[1].stage = .done;
                    }
                }
                if (boards[0].stage == .done) break;
            }
            try std.testing.expect(boards[0].stage == .done and boards[1].stage == .done);
            try std.testing.expect(boards[0].discovered_at != null and boards[1].discovered_at != null);
        }
    }
}
