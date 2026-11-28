//! Legacy IEEE 802.15.4-2003/2006 clear MAC addressing. Slices exclude the PHR and FCS.
const std = @import("std");

pub const max_frame_len = 125;
pub const Reception = enum { reject, accept, ack };

pub const Header = struct {
    frame_type: enum(u2) { beacon, data, ack, command },
    ack_requested: bool,
    security_enabled: bool,
    sequence: u8,
    destination_pan: ?u16,
    destination: []const u8,
    source_pan: ?u16,
    source: []const u8,
    address_end: usize,

    /// IEEE 802.15.4-2006 §7.2.1.1.4 and §7.5.6.4. Only a unicast data
    /// or MAC command frame can request an immediate acknowledgment.
    pub fn requests_ack(self: Header) bool {
        if (!self.ack_requested or (self.frame_type != .data and self.frame_type != .command)) return false;
        return switch (self.destination.len) {
            8 => true,
            // 0xfffe denotes an unassigned short address, 0xffff a broadcast.
            2 => std.mem.readInt(u16, self.destination[0..2], .little) < 0xfffe,
            else => false,
        };
    }

    /// IEEE 802.15.4-2006 §7.3.4: unprotected Data Request has command ID 0x04.
    /// Without security offload the protected command ID is opaque, so a
    /// secured MAC command is a possible Data Request.
    pub fn possible_data_request(self: Header, bytes: []const u8) bool {
        if (self.frame_type != .command) return false;
        return self.security_enabled or
            (self.address_end < bytes.len and bytes[self.address_end] == 0x04);
    }

    /// Third-level filtering for a node or PAN coordinator (IEEE 802.15.4-2006 §7.5.6.2).
    /// The driver handles promiscuous capture and receipt of outstanding ACKs.
    pub fn filter(self: Header, local_pan: u16, short: u16, extended: *const [8]u8, auto_ack: bool, pan_coordinator: bool) Reception {
        switch (self.frame_type) {
            .ack => return .reject,
            .beacon => {
                // §7.2.2.1.1: legacy beacons carry only source addressing.
                if (self.destination_pan != null or self.destination.len != 0) return .reject;
                const source_pan = self.source_pan orelse return .reject;
                return if (local_pan == 0xffff or source_pan == local_pan) .accept else .reject;
            },
            .data, .command => {},
        }
        const pan = self.destination_pan orelse {
            return if (pan_coordinator and self.source_pan == local_pan) .accept else .reject;
        };
        if (pan != local_pan and pan != 0xffff) return .reject;
        switch (self.destination.len) {
            2 => {
                const addr = std.mem.readInt(u16, self.destination[0..2], .little);
                if (addr == 0xffff) return .accept;
                if (addr != short or addr == 0xfffe) return .reject;
            },
            8 => if (!std.mem.eql(u8, self.destination, extended)) return .reject,
            else => return .reject,
        }
        return if (auto_ack and self.requests_ack()) .ack else .accept;
    }
};

pub fn parse(bytes: []const u8) error{ InvalidFrame, UnsupportedFrame }!Header {
    if (bytes.len < 3 or bytes.len > max_frame_len) return error.InvalidFrame;
    // IEEE 802.15.4-2006 §7.2.1. Legacy versions 0 and 1 always carry a DSN.
    const fcf = std.mem.readInt(u16, bytes[0..2], .little);
    // The legacy reserved bits 7–9 are ignored on RX (§7.2.2).
    if (fcf & 7 > 3 or (fcf >> 12) & 3 > 1)
        return error.UnsupportedFrame;
    const dst_len = try address_len(@truncate(fcf >> 10));
    const src_len = try address_len(@truncate(fcf >> 14));
    const compressed = fcf & 0x40 != 0;
    if (compressed and (dst_len == 0 or src_len == 0)) return error.InvalidFrame;

    var rest = bytes[3..];
    const dst_pan = if (dst_len != 0) try take_pan(&rest) else null;
    const dst = try take(&rest, dst_len);
    const src_pan = if (src_len == 0) null else if (compressed) dst_pan else try take_pan(&rest);
    const src = try take(&rest, src_len);
    return .{
        .frame_type = @fromBackingInt(@as(u2, @truncate(fcf))),
        .ack_requested = fcf & 0x20 != 0,
        .security_enabled = fcf & 8 != 0,
        .sequence = bytes[2],
        .destination_pan = dst_pan,
        .destination = dst,
        .source_pan = src_pan,
        .source = src,
        .address_end = bytes.len - rest.len,
    };
}

/// Legacy ACK matching only needs the transmitted clear Frame Control,
/// DSN and addresses. Security fields and payload belong to the stack.
pub fn tx_ack_header(bytes: []const u8) error{InvalidFrame}!?Header {
    if (bytes.len < 3 or bytes.len > max_frame_len) return error.InvalidFrame;
    if (bytes[0] & 0x20 == 0) return null;
    const h = parse(bytes) catch return error.InvalidFrame;
    if (!h.requests_ack()) return error.InvalidFrame;
    return h;
}

fn address_len(mode: u2) error{InvalidFrame}!usize {
    return switch (mode) {
        0 => 0,
        1 => error.InvalidFrame,
        2 => 2,
        3 => 8,
    };
}

fn take(rest: *[]const u8, len: usize) error{InvalidFrame}![]const u8 {
    if (rest.len < len) return error.InvalidFrame;
    const bytes = rest.*[0..len];
    rest.* = rest.*[len..];
    return bytes;
}

fn take_pan(rest: *[]const u8) error{InvalidFrame}!u16 {
    return std.mem.readInt(u16, (try take(rest, 2))[0..2], .little);
}

/// An ACK for a different DSN ends the attempt (§7.5.6.4.3). Other frames
/// return null so the caller can keep waiting within the same ACK window.
pub fn ack_matches(bytes: []const u8, sequence: u8) ?bool {
    if (bytes.len != 3) return null;
    const fcf = std.mem.readInt(u16, bytes[0..2], .little);
    // §7.2.2.3.1: legacy ACKs carry no addresses or auxiliary header.
    // Ignore frame pending and the other unused bits on reception.
    if (fcf & 0xcc0f != 2 or (fcf >> 12) & 3 > 1) return null;
    return bytes[2] == sequence;
}

test "compressed short and extended addressing preserves wire order and rejects truncation" {
    const bytes = [_]u8{ 0x61, 0x8c, 9, 0x34, 0x12, 1, 2, 3, 4, 5, 6, 7, 8, 0x03, 0x00 };
    for (0..bytes.len) |len| try std.testing.expectError(error.InvalidFrame, parse(bytes[0..len]));
    const h = try parse(&bytes);
    try std.testing.expect(h.ack_requested);
    try std.testing.expectEqual(@as(?u16, 0x1234), h.destination_pan);
    try std.testing.expectEqual(h.destination_pan, h.source_pan);
    try std.testing.expectEqualSlices(u8, bytes[5..13], h.destination);
    try std.testing.expectEqualSlices(u8, bytes[13..15], h.source);
    try std.testing.expectEqual(bytes.len, h.address_end);
}

test "ACK wait distinguishes a different DSN from other or malformed frames" {
    try std.testing.expectEqual(@as(?bool, true), ack_matches(&.{ 0x12, 0x00, 9 }, 9));
    try std.testing.expectEqual(@as(?bool, false), ack_matches(&.{ 0x02, 0x00, 10 }, 9));
    try std.testing.expectEqual(@as(?bool, true), ack_matches(&.{ 0xf2, 0x13, 9 }, 9));
    try std.testing.expectEqual(null, ack_matches(&.{ 0x01, 0x00, 9 }, 9));
    try std.testing.expectEqual(null, ack_matches(&.{ 0x0a, 0x00, 9 }, 9));
    try std.testing.expectEqual(null, ack_matches(&.{ 0x02, 0x08, 9 }, 9));
    try std.testing.expectEqual(null, ack_matches(&.{ 0x02, 0x20, 9 }, 9));
    try std.testing.expectEqual(null, ack_matches(&.{ 0x02, 0x00, 9, 0 }, 9));
}

test "unassociated nodes discover beacons and configured nodes match the source PAN" {
    const beacon = try parse(&.{ 0x00, 0x80, 9, 0x34, 0x12, 0x01, 0x00, 0xff, 0x4f, 0, 0 });
    try std.testing.expectEqual(.accept, beacon.filter(0xffff, 3, &@splat(0), true, false));
    try std.testing.expectEqual(.accept, beacon.filter(0x1234, 3, &@splat(0), true, false));
    try std.testing.expectEqual(.reject, beacon.filter(0x5678, 3, &@splat(0), true, false));

    const addressed = try parse(&.{ 0x00, 0x88, 9, 0x34, 0x12, 3, 0, 0x78, 0x56, 1, 0, 0xff, 0x4f, 0, 0 });
    try std.testing.expectEqual(.reject, addressed.filter(0x1234, 3, &@splat(0), true, false));
    const no_source = try parse(&.{ 0x00, 0x00, 9, 0xff, 0x4f, 0, 0 });
    try std.testing.expectEqual(.reject, no_source.filter(0xffff, 3, &@splat(0), true, false));
    const data = try parse(&.{ 0x21, 0x80, 9, 0x34, 0x12, 1, 0 });
    try std.testing.expectEqual(.reject, data.filter(0x1234, 3, &@splat(0), true, false));
    try std.testing.expect(!data.requests_ack());
}

test "unicast ACK eligibility is independent of the PAN filter" {
    const extended = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var bytes = [_]u8{ 0x61, 0x8c, 9, 0xff, 0xff, 1, 2, 3, 4, 5, 6, 7, 8, 1, 0 };
    const frame = try parse(&bytes);
    try std.testing.expect(frame.requests_ack());
    try std.testing.expectEqual(.ack, frame.filter(0x1234, 3, &extended, true, false));
    try std.testing.expectEqual(.accept, frame.filter(0x1234, 3, &extended, false, false));
    try std.testing.expectEqual(.reject, frame.filter(0x1234, 3, &@splat(0), true, false));

    bytes[3..5].* = .{ 0x78, 0x56 };
    const other_pan = try parse(&bytes);
    try std.testing.expect(other_pan.requests_ack());
    try std.testing.expectEqual(.reject, other_pan.filter(0x1234, 3, &extended, true, false));

    const broadcast = try parse(&.{ 0x61, 0x88, 9, 0xff, 0xff, 0xff, 0xff, 1, 0 });
    try std.testing.expect(!broadcast.requests_ack());
    try std.testing.expectEqual(.accept, broadcast.filter(0x1234, 3, &extended, true, false));
    const unassigned = try parse(&.{ 0x61, 0x88, 9, 0xff, 0xff, 0xfe, 0xff, 1, 0 });
    try std.testing.expect(!unassigned.requests_ack());
    try std.testing.expectEqual(.reject, unassigned.filter(0x1234, 0xfffe, &extended, true, false));
}

test "legacy RX ignores reserved FCF bits and rejects a reserved version" {
    var bytes = [9]u8{ 0xe1, 0x8b, 9, 0xff, 0xff, 3, 0, 1, 0 };
    const legacy = try parse(&bytes);
    try std.testing.expectEqual(.ack, legacy.filter(0x1234, 3, &@splat(0), true, false));
    bytes[1] |= 0x20;
    try std.testing.expectError(error.UnsupportedFrame, parse(&bytes));
}

test "legacy parse rejects every reserved frame type and newer frame version" {
    var bytes = [9]u8{ 0x41, 0x88, 9, 0x34, 0x12, 3, 0, 1, 0 };
    // IEEE 802.15.4-2006 §7.2.1.1.1: frame types 0b100–0b111 are reserved.
    for (0..8) |frame_type| {
        bytes[0] = 0x40 | @as(u8, @intCast(frame_type));
        if (frame_type < 4) {
            _ = try parse(&bytes);
        } else {
            try std.testing.expectError(error.UnsupportedFrame, parse(&bytes));
        }
    }
    // §7.2.1.1.7: versions 0 and 1 are legacy, 2 and 3 are newer.
    bytes[0] = 0x41;
    for ([_]u8{ 0x88, 0x98, 0xa8, 0xb8 }, 0..) |version_and_addresses, version| {
        bytes[1] = version_and_addresses;
        if (version < 2) {
            try std.testing.expectEqual(.data, (try parse(&bytes)).frame_type);
        } else {
            try std.testing.expectError(error.UnsupportedFrame, parse(&bytes));
        }
    }
}

test "PAN coordinator accepts destinationless data on its own PAN without ACK" {
    const frame = try parse(&.{ 0x21, 0x80, 9, 0x34, 0x12, 1, 0 });
    try std.testing.expectEqual(.accept, frame.filter(0x1234, 3, &@splat(0), true, true));
    try std.testing.expectEqual(.reject, frame.filter(0x5678, 3, &@splat(0), true, true));
    try std.testing.expectEqual(.reject, frame.filter(0x1234, 3, &@splat(0), true, false));
}

test "software-secured legacy unicast filters and matches ACKs using its clear header" {
    var bytes = [_]u8{ 0x69, 0x98, 9, 0x34, 0x12, 3, 0, 1, 0, 0x0d, 0, 0, 0, 0, 1, 0x84, 0, 0, 0, 0 };
    for ([_]u8{ 0x88, 0x98 }) |version_and_addresses| {
        bytes[1] = version_and_addresses;
        const h = try parse(&bytes);
        try std.testing.expect(h.security_enabled);
        try std.testing.expect(h.requests_ack());
        try std.testing.expect(!h.possible_data_request(&bytes));
        try std.testing.expectEqual(.ack, h.filter(0x1234, 3, &@splat(0), true, false));
        try std.testing.expectEqual(.accept, h.filter(0x1234, 3, &@splat(0), false, false));
        try std.testing.expectEqual(.reject, h.filter(0x1234, 4, &@splat(0), true, false));

        const outgoing = (try tx_ack_header(&bytes)).?;
        try std.testing.expectEqual(@as(?bool, true), ack_matches(&.{ 0x02, 0x00, 9 }, outgoing.sequence));
        try std.testing.expectEqual(@as(?bool, false), ack_matches(&.{ 0x02, 0x00, 10 }, outgoing.sequence));
    }
}

test "reserved address mode and compression without both addresses are rejected" {
    try std.testing.expectError(error.InvalidFrame, parse(&.{ 0x01, 0x04, 9, 0, 0, 1, 0 }));
    try std.testing.expectError(error.InvalidFrame, parse(&.{ 0x01, 0x40, 9, 0, 0, 1, 0 }));
    try std.testing.expectError(error.InvalidFrame, parse(&.{ 0x41, 0x08, 9, 0, 0, 1, 0 }));
    try std.testing.expectError(error.InvalidFrame, parse(&.{ 0x41, 0x80, 9, 0, 0, 1, 0 }));
    try std.testing.expectError(error.UnsupportedFrame, parse(&.{ 0x05, 0, 9 }));
}

test "PAN coordinator accepts same-PAN destinationless commands without ACK" {
    const frame = try parse(&.{ 0x23, 0x80, 9, 0x34, 0x12, 1, 0, 0x04 });
    try std.testing.expectEqual(.accept, frame.filter(0x1234, 3, &@splat(0), true, true));
    try std.testing.expectEqual(.reject, frame.filter(0x5678, 3, &@splat(0), true, true));
    try std.testing.expectEqual(.reject, frame.filter(0x1234, 3, &@splat(0), true, false));
}

test "TX rejects malformed or ineligible legacy ACK requests" {
    for ([_][]const u8{
        &.{ 0x61, 0x88 },
        &.{ 0x61, 0x88, 9 },
        &.{ 0x21, 0x00, 9 },
        &.{ 0x20, 0x80, 9, 0x34, 0x12, 1, 0 },
        &.{ 0x61, 0x88, 9, 0x34, 0x12, 0xff, 0xff, 1, 0 },
        &.{ 0x61, 0xa8, 9, 0x34, 0x12, 3, 0, 1, 0 },
    }) |bytes| try std.testing.expectError(error.InvalidFrame, tx_ack_header(bytes));
    try std.testing.expectEqual(null, try tx_ack_header(&.{ 0x05, 0x20, 9 }));
}
