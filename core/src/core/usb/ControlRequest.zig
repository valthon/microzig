//! Tracks whether software answered the current EP0 callback. Hardware-specific
//! packet arming stays in the HAL. USB 2.0, 9.2.7 and 8.5.3.4 require STALL for
//! unsupported requests; a control write is answered only after its data is accepted.
const types = @import("types.zig");
const Self = @This();

answered: bool = false,
direction: types.Dir = .out,
out_data: bool = false,

pub fn setup(self: *Self, packet: *const types.SetupPacket) void {
    self.* = .{ .direction = packet.request_type.direction, .out_data = packet.request_type.direction == .out and packet.length.native() != 0 };
}

pub fn reply(self: *Self) void {
    self.answered = true;
    self.out_data = false;
}

pub fn listen(self: *Self) void {
    if (self.out_data) self.answered = true;
}

/// A status OUT packet is not a request for a second response.
/// For a data OUT packet the controller must accept it or listen for the next one.
pub fn out_packet(self: *Self) bool {
    if (!self.out_data) return false;
    self.answered = false;
    return true;
}

pub fn needs_stall(self: *const Self) bool {
    return !self.answered;
}
