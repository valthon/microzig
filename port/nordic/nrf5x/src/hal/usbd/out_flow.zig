//! Which packets received on the data OUT endpoints may be reported to the controller.
//!
//! A driver says with `ep_listen` that it is ready for a packet, and "after being called
//! it may not be called again until a packet is received" (core/usb.zig). So a packet is
//! reported only to a driver that listens, and once. The peripheral knows nothing of this:
//! an endpoint takes its next packet as soon as the one before it has been copied out
//! (nRF52840 PS v1.1, 6.35.10.2), whether or not the driver has listened again. That packet
//! stays in the endpoint, where it keeps the host's further packets off with NAK, until the
//! driver listens and is told of it.
//!
//! Nothing here reads or writes a register, which keeps this inside the port's host tests.
//! `listen` is called from wherever a driver runs and the other functions from `poll`, which
//! runs in foreground. `ep_listen` masks the notification IRQ while changing state.

const std = @import("std");

pub const Flow = struct {
    /// The driver of endpoint n has called `ep_listen` and has not been given a packet since.
    listening: [8]bool = @splat(false),
    /// Endpoint n holds a packet that has not been reported.
    waiting: [8]bool = @splat(false),

    /// The driver is ready for a packet. Returns true if one is waiting already: `poll`
    /// reports it the next time it runs, and the caller sees to it that it does.
    pub fn listen(self: *Flow, n: u3) bool {
        self.listening[n] = true;
        return self.waiting[n];
    }

    /// The host's packet is in the endpoint (EPDATA).
    pub fn arrived(self: *Flow, n: u3) void {
        self.waiting[n] = true;
    }

    /// Whether `poll` reports a packet on endpoint n now. If so, the driver has it: it
    /// listens again before it is told of the next one.
    pub fn report(self: *Flow, n: u3) bool {
        if (!self.waiting[n] or !self.listening[n]) return false;
        self.waiting[n] = false;
        self.listening[n] = false;
        return true;
    }

    /// The endpoint was opened or closed: what it held belongs to no driver.
    pub fn forget(self: *Flow, n: u3) void {
        self.waiting[n] = false;
        self.listening[n] = false;
    }
};

test "a packet is reported only to a driver that listens" {
    var flow: Flow = .{};

    // It arrives first: nothing until the driver listens, and `listen` says it is there.
    flow.arrived(1);
    try std.testing.expect(!flow.report(1));
    try std.testing.expect(flow.listen(1));
    try std.testing.expect(flow.report(1));

    // The driver listens first.
    try std.testing.expect(!flow.listen(1));
    try std.testing.expect(!flow.report(1));
    flow.arrived(1);
    try std.testing.expect(flow.report(1));
}

test "a packet is reported once, and the next one waits for the next listen" {
    var flow: Flow = .{};
    try std.testing.expect(!flow.listen(2));
    flow.arrived(2);
    try std.testing.expect(flow.report(2));
    try std.testing.expect(!flow.report(2));

    // The endpoint took another packet when the driver had read the first.
    flow.arrived(2);
    try std.testing.expect(!flow.report(2));
    try std.testing.expect(flow.listen(2));
    try std.testing.expect(flow.report(2));
    try std.testing.expect(!flow.report(2));
}

test "endpoints do not share their state" {
    var flow: Flow = .{};
    try std.testing.expect(!flow.listen(1));
    flow.arrived(7);
    try std.testing.expect(!flow.report(1));
    try std.testing.expect(!flow.report(7));
    flow.arrived(1);
    try std.testing.expect(flow.report(1));
    try std.testing.expect(flow.listen(7));
    try std.testing.expect(flow.report(7));
}

test "an endpoint that is opened again starts with nothing" {
    var flow: Flow = .{};

    // A packet the configuration before never read.
    flow.arrived(3);
    flow.forget(3);
    try std.testing.expect(!flow.listen(3));
    try std.testing.expect(!flow.report(3));

    // A listen of the driver before.
    flow.forget(3);
    flow.arrived(3);
    try std.testing.expect(!flow.report(3));
}
