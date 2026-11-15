//! The order of the stages of a control transfer on endpoint 0.
//!
//! Nothing here reads or writes a register: `usbd.zig` reports what happened on the bus and
//! triggers the task it is handed back. That keeps the sequencing inside the port's host tests.
//!
//! Reference: nRF52840 Product Specification v1.1, 6.35.9 "Control transfers".

const std = @import("std");

/// Direction of the data stage, bit 7 of bmRequestType.
pub const Dir = enum { in, out };

/// What `usbd.zig` reads of a SETUP packet for this file.
pub const Setup = struct {
    /// bmRequestType
    request_type: u8,
    /// bRequest
    request: u8,
    /// wLength
    length: u16,
};

/// What `usbd.zig` triggers next on endpoint 0.
pub const Action = enum {
    none,
    /// TASKS_EP0RCVOUT: acknowledge the next OUT packet of the data stage.
    rcvout,
    /// TASKS_EP0STATUS: let the status stage through.
    status,
    /// TASKS_EP0STALL: answer the data and status stages with STALL.
    stall,
};

pub const Control = struct {
    direction: Dir = .out,
    /// Bytes of wLength that the data stage has not carried yet. Zero once the data stage
    /// has ended, also when a short packet ended it early.
    remaining: u16 = 0,
    /// The packet loaded into the endpoint ends the data stage of a control read.
    in_last: bool = false,
    /// The request has its answer: the controller's, a packet for the data stage or its
    /// acceptance, or the stall for a packet of the controller's that could not be loaded.
    answered: bool = false,
    /// The request is SET_ADDRESS (see `is_set_address`), which is not the software's to
    /// answer: "The USBD peripheral handles the SetAddress transfer by itself. As a
    /// consequence, the software shall not process this command other than updating its
    /// state machine [...], nor initiate a status stage" (6.35.9).
    set_address: bool = false,
    /// The request is SET_CONFIGURATION (see `is_set_configuration`).
    set_configuration: bool = false,

    /// A SETUP packet arrived. It ends the transfer before it, finished or not.
    pub fn setup(self: *Control, packet: Setup) void {
        self.* = .{
            .direction = if (packet.request_type & 0x80 != 0) .in else .out,
            .remaining = packet.length,
            .set_address = is_set_address(packet),
            .set_configuration = is_set_configuration(packet),
        };
    }

    /// The controller has accepted a SET_CONFIGURATION: the endpoints it opened while it
    /// handled the request are those of the configuration the host selected, and no others
    /// belong to it. Not for a request the controller refused, which changes nothing.
    pub fn configured(self: *const Control) bool {
        return self.set_configuration and self.answered;
    }

    /// A control read still owes the host bytes of wLength: a zero-length write is then a
    /// packet of the data stage, not the request for the status stage.
    pub fn in_data_stage(self: *const Control) bool {
        return self.direction == .in and self.remaining != 0;
    }

    /// A control write still expects bytes of wLength from the host. Only then is an
    /// EP0DATADONE a packet to take out of the endpoint.
    pub fn out_data_stage(self: *const Control) bool {
        return self.direction == .out and self.remaining != 0;
    }

    /// A packet of `len` bytes has been loaded for the data stage of a control read.
    /// It is the last one if it is shorter than the endpoint's maximum or carries the last
    /// byte the host asked for; `in_done` then starts the status stage.
    pub fn in_packet(self: *Control, len: u16, max_packet_size: u16) void {
        self.answered = true;
        self.remaining = if (len < max_packet_size) 0 else self.remaining -| len;
        self.in_last = self.remaining == 0;
    }

    /// A packet of a control read's data stage could not be loaded into the endpoint.
    /// The host's IN tokens would be answered NAK until its next SETUP packet: only "the
    /// data [transferred] from Data RAM memory into USBD will trigger a valid, acknowledged
    /// (ACK) IN transaction" (6.35.9.1). So the transfer is given up, like a control write
    /// in `out_failed`: "The software can choose to stall a command (in both data and status
    /// stages) through the EP0STALL task" (6.35.9).
    ///
    /// The stall is the answer the request gets, also when the packet was the first:
    /// `setup_handled` has nothing to add to it.
    pub fn in_failed(self: *Control) Action {
        self.answered = true;
        self.remaining = 0;
        self.in_last = false;
        return .stall;
    }

    /// EP0DATADONE in a control read: the host has taken the packet and acknowledged it.
    /// After the last packet of the data stage the status stage is started: "The software
    /// can then either prepare and transmit the next data transaction by repeating the above
    /// sequence, or initiate the status stage through the EP0STATUS task" (6.35.9.1).
    ///
    /// The same section notes "the possibility to enable a shortcut from the EP0DATADONE
    /// event to the EP0STATUS task", which starts the status stage without the software.
    /// It is not used. Anomaly 199 of the nRF52840, "USBD cannot receive tasks during DMA",
    /// is in substance that USB tasks cannot be used while an EasyDMA transfer is in
    /// progress (a paraphrase; `dma_begin` in errata.zig names the sources). It leaves open
    /// whether a task the shortcut triggers while a data endpoint's packet is being copied
    /// is performed, and nothing starts a status stage that was lost that way. `usbd.zig`
    /// waits for each of its EasyDMA transfers to end and undoes the anomaly's workaround
    /// before it goes on, so none is running where it triggers the task this returns.
    pub fn in_done(self: *Control) Action {
        if (!self.in_last) return .none;
        self.in_last = false;
        return .status;
    }

    /// The controller accepted the request (a zero-length write outside a data stage).
    ///
    /// For a control write that is before the host has sent its data. The status stage has
    /// to wait: "The software can then either prepare to receive the next data transaction
    /// [...] or initiate the status stage through the EP0STATUS task", once ENDEPOUT[0] has
    /// said that the data is in RAM (6.35.9.2). So the data stage is let through first.
    pub fn ack(self: *Control) Action {
        self.answered = true;
        // The controller still sees SET_ADDRESS and accepts it: that is its state machine.
        if (self.set_address) return .none;
        return if (self.out_data_stage()) .rcvout else .status;
    }

    /// The controller has returned from the SETUP packet. A request it did not answer, by
    /// a packet for the data stage or by accepting it, is one it does not support, and
    /// such a request is stalled: "The software can choose to stall a command (in both data
    /// and status stages) through the EP0STALL task, for instance if the command is not
    /// supported, or its wValue, wIndex or wLength parameters are wrong" (6.35.9). Left
    /// alone, the peripheral answers NAK for as long as the host cares to ask.
    pub fn setup_handled(self: *const Control) Action {
        if (self.answered) return .none;
        if (self.set_address) return .none;
        return .stall;
    }

    /// A packet of `len` bytes of a control write's data stage was taken out of the endpoint.
    /// The data stage ends with the last byte of wLength or with a packet shorter than the
    /// endpoint's maximum; until then the next packet is let through.
    pub fn out_packet(self: *Control, len: u16, max_packet_size: u16) Action {
        self.remaining = if (len < max_packet_size) 0 else self.remaining -| len;
        return if (self.remaining == 0) .status else .rcvout;
    }

    /// A packet of a control write's data stage could not be taken out of the endpoint.
    /// Neither the next packet nor the status stage may follow a copy that did not end
    /// (6.35.9.2), so the transfer is given up: "The software can choose to stall a command
    /// (in both data and status stages) through the EP0STALL task" (6.35.9).
    pub fn out_failed(self: *Control) Action {
        self.remaining = 0;
        return .stall;
    }
};

/// Whether a SETUP packet is SET_ADDRESS: a standard request to the device, host to device
/// (bmRequestType 0x00), with bRequest 5.
fn is_set_address(packet: Setup) bool {
    return packet.request_type == 0x00 and packet.request == 0x05;
}

/// Whether a SETUP packet is SET_CONFIGURATION: a standard request to the device, host to
/// device (bmRequestType 0x00), with bRequest 9.
fn is_set_configuration(packet: Setup) bool {
    return packet.request_type == 0x00 and packet.request == 0x09;
}

// CDC SET_LINE_CODING: class request to an interface, host to device, 7 bytes of data.
fn set_line_coding(length: u16) Setup {
    return .{ .request_type = 0x21, .request = 0x20, .length = length };
}

// GET_DESCRIPTOR: standard request to the device, device to host.
fn get_descriptor(length: u16) Setup {
    return .{ .request_type = 0x80, .request = 0x06, .length = length };
}

test "a control write gets its status stage after its data, not before" {
    var ep0: Control = .{};
    ep0.setup(set_line_coding(7));
    // The controller accepts the request while the 7 bytes are still with the host.
    try std.testing.expectEqual(Action.rcvout, ep0.ack());
    try std.testing.expect(ep0.out_data_stage());
    try std.testing.expectEqual(Action.status, ep0.out_packet(7, 64));
    try std.testing.expect(!ep0.out_data_stage());
}

test "a control write's data stage runs until wLength or a short packet" {
    var ep0: Control = .{};

    // 130 bytes: two full packets and one of 2.
    ep0.setup(set_line_coding(130));
    try std.testing.expectEqual(Action.rcvout, ep0.ack());
    try std.testing.expectEqual(Action.rcvout, ep0.out_packet(64, 64));
    try std.testing.expectEqual(Action.rcvout, ep0.out_packet(64, 64));
    try std.testing.expect(ep0.out_data_stage());
    try std.testing.expectEqual(Action.status, ep0.out_packet(2, 64));
    try std.testing.expect(!ep0.out_data_stage());

    // 128 bytes end on a full packet.
    ep0.setup(set_line_coding(128));
    try std.testing.expectEqual(Action.rcvout, ep0.ack());
    try std.testing.expectEqual(Action.rcvout, ep0.out_packet(64, 64));
    try std.testing.expectEqual(Action.status, ep0.out_packet(64, 64));
    try std.testing.expect(!ep0.out_data_stage());

    // The host sends less than it announced: a short packet ends the data stage, and what
    // is left of wLength is not waited for.
    ep0.setup(set_line_coding(130));
    try std.testing.expectEqual(Action.rcvout, ep0.ack());
    try std.testing.expectEqual(Action.status, ep0.out_packet(10, 64));
    try std.testing.expect(!ep0.out_data_stage());

    // A zero-length packet is a short one.
    ep0.setup(set_line_coding(7));
    try std.testing.expectEqual(Action.rcvout, ep0.ack());
    try std.testing.expectEqual(Action.status, ep0.out_packet(0, 64));
    try std.testing.expect(!ep0.out_data_stage());
}

test "a control write whose packet could not be taken is stalled" {
    var ep0: Control = .{};
    ep0.setup(set_line_coding(130));
    try std.testing.expectEqual(Action.rcvout, ep0.ack());
    try std.testing.expectEqual(Action.rcvout, ep0.out_packet(64, 64));
    try std.testing.expectEqual(Action.stall, ep0.out_failed());
    try std.testing.expect(!ep0.out_data_stage());
}

test "a transfer without a data stage gets its status stage at once" {
    var ep0: Control = .{};
    ep0.setup(set_line_coding(0));
    try std.testing.expectEqual(Action.status, ep0.ack());
    ep0.setup(get_descriptor(0));
    try std.testing.expectEqual(Action.status, ep0.ack());
}

test "a SETUP packet ends a control write whose data never came" {
    var ep0: Control = .{};
    ep0.setup(set_line_coding(7));
    try std.testing.expectEqual(Action.rcvout, ep0.ack());
    ep0.setup(set_line_coding(0));
    try std.testing.expectEqual(Action.status, ep0.ack());
    try std.testing.expect(!ep0.out_data_stage());
}

test "a control read gets its status stage when the host has taken the last packet" {
    var ep0: Control = .{};

    // 18 bytes of 255 asked for: one short packet.
    ep0.setup(get_descriptor(255));
    ep0.in_packet(18, 64);
    try std.testing.expectEqual(Action.status, ep0.in_done());
    // Only once.
    try std.testing.expectEqual(Action.none, ep0.in_done());

    // 64 bytes of 64 asked for: full, and all the host wants.
    ep0.setup(get_descriptor(64));
    ep0.in_packet(64, 64);
    try std.testing.expectEqual(Action.status, ep0.in_done());

    // 130 bytes of 255 asked for: nothing after the full packets, the status stage after
    // the short one.
    ep0.setup(get_descriptor(255));
    ep0.in_packet(64, 64);
    try std.testing.expectEqual(Action.none, ep0.in_done());
    ep0.in_packet(64, 64);
    try std.testing.expectEqual(Action.none, ep0.in_done());
    ep0.in_packet(2, 64);
    try std.testing.expectEqual(Action.status, ep0.in_done());

    // 64 bytes of 255 asked for: the host expects more, so a zero-length packet follows,
    // and the status stage comes after that one.
    ep0.setup(get_descriptor(255));
    ep0.in_packet(64, 64);
    try std.testing.expectEqual(Action.none, ep0.in_done());
    ep0.in_packet(0, 64);
    try std.testing.expectEqual(Action.status, ep0.in_done());
}

test "a control read owes the host nothing after its last packet" {
    var ep0: Control = .{};

    // 18 bytes of 255 asked for: the short packet ends the data stage.
    ep0.setup(get_descriptor(255));
    try std.testing.expect(ep0.in_data_stage());
    ep0.in_packet(18, 64);
    try std.testing.expect(!ep0.in_data_stage());

    // 64 bytes of 64 asked for.
    ep0.setup(get_descriptor(64));
    ep0.in_packet(64, 64);
    try std.testing.expect(!ep0.in_data_stage());

    // 64 bytes of 255 asked for: a zero-length packet is still owed, and ends it.
    ep0.setup(get_descriptor(255));
    ep0.in_packet(64, 64);
    try std.testing.expect(ep0.in_data_stage());
    ep0.in_packet(0, 64);
    try std.testing.expect(!ep0.in_data_stage());
}

test "a SETUP packet ends a control read whose last packet the host never took" {
    var ep0: Control = .{};
    ep0.setup(get_descriptor(255));
    ep0.in_packet(18, 64);
    ep0.setup(get_descriptor(255));
    try std.testing.expectEqual(Action.none, ep0.in_done());
}

test "a control read whose packet could not be loaded is stalled" {
    var ep0: Control = .{};

    // The first packet. The stall is the answer the request gets: the controller's return
    // does not add a second one.
    ep0.setup(get_descriptor(255));
    try std.testing.expectEqual(Action.stall, ep0.in_failed());
    try std.testing.expectEqual(Action.none, ep0.setup_handled());
    try std.testing.expect(!ep0.in_data_stage());

    // A later packet, after the host has taken the first.
    ep0.setup(get_descriptor(255));
    ep0.in_packet(64, 64);
    try std.testing.expectEqual(Action.none, ep0.setup_handled());
    try std.testing.expectEqual(Action.none, ep0.in_done());
    try std.testing.expectEqual(Action.stall, ep0.in_failed());
    try std.testing.expect(!ep0.in_data_stage());

    // The last packet: no status stage follows the stall.
    ep0.setup(get_descriptor(255));
    ep0.in_packet(64, 64);
    try std.testing.expectEqual(Action.none, ep0.in_done());
    try std.testing.expectEqual(Action.stall, ep0.in_failed());
    try std.testing.expectEqual(Action.none, ep0.in_done());

    // The failure does not carry over to the next request.
    ep0.setup(get_descriptor(255));
    try std.testing.expectEqual(Action.stall, ep0.setup_handled());
    ep0.setup(get_descriptor(255));
    ep0.in_packet(18, 64);
    try std.testing.expectEqual(Action.status, ep0.in_done());
}

test "a request the controller did not answer is stalled" {
    var ep0: Control = .{};

    // Unsupported: the controller returns without a word, for a read and for a write.
    ep0.setup(get_descriptor(255));
    try std.testing.expectEqual(Action.stall, ep0.setup_handled());
    ep0.setup(set_line_coding(7));
    try std.testing.expectEqual(Action.stall, ep0.setup_handled());

    // Answered with the first packet of the data stage.
    ep0.setup(get_descriptor(255));
    ep0.in_packet(18, 64);
    try std.testing.expectEqual(Action.none, ep0.setup_handled());

    // Accepted, without and with a data stage to come.
    ep0.setup(set_line_coding(0));
    _ = ep0.ack();
    try std.testing.expectEqual(Action.none, ep0.setup_handled());
    ep0.setup(set_line_coding(7));
    _ = ep0.ack();
    try std.testing.expectEqual(Action.none, ep0.setup_handled());

    // An answer does not carry over to the next request.
    ep0.setup(get_descriptor(255));
    try std.testing.expectEqual(Action.stall, ep0.setup_handled());
}

test "SET_ADDRESS gets neither a status stage nor a stall" {
    const set_address: Setup = .{ .request_type = 0x00, .request = 5, .length = 0 };
    var ep0: Control = .{};

    // The controller accepts it like any other request without data.
    ep0.setup(set_address);
    try std.testing.expectEqual(Action.none, ep0.ack());
    try std.testing.expectEqual(Action.none, ep0.setup_handled());

    // And if it were not to answer, the transfer is still the peripheral's own.
    ep0.setup(set_address);
    try std.testing.expectEqual(Action.none, ep0.setup_handled());

    // Only the standard request to the device is SET_ADDRESS: not request 5 of a class, not
    // SET_CONFIGURATION (9), and not request 5 in the other direction. Each of those gets
    // its status stage, also right after a SET_ADDRESS.
    ep0.setup(.{ .request_type = 0x21, .request = 5, .length = 0 });
    try std.testing.expectEqual(Action.status, ep0.ack());
    ep0.setup(.{ .request_type = 0x00, .request = 9, .length = 0 });
    try std.testing.expectEqual(Action.status, ep0.ack());
    ep0.setup(.{ .request_type = 0x80, .request = 5, .length = 0 });
    try std.testing.expectEqual(Action.status, ep0.ack());
    ep0.setup(.{ .request_type = 0x21, .request = 5, .length = 0 });
    try std.testing.expectEqual(Action.stall, ep0.setup_handled());
}

test "only an accepted SET_CONFIGURATION changes the configuration" {
    const set_configuration: Setup = .{ .request_type = 0x00, .request = 9, .length = 0 };
    var ep0: Control = .{};

    // Not before the controller has answered, and not if it does not.
    ep0.setup(set_configuration);
    try std.testing.expect(!ep0.configured());
    try std.testing.expectEqual(Action.stall, ep0.setup_handled());
    try std.testing.expect(!ep0.configured());

    ep0.setup(set_configuration);
    try std.testing.expectEqual(Action.status, ep0.ack());
    try std.testing.expect(ep0.configured());

    // No other request does, accepted or not: request 9 of a class, SET_ADDRESS, and
    // GET_CONFIGURATION (8), which is answered with a packet.
    ep0.setup(.{ .request_type = 0x21, .request = 9, .length = 0 });
    _ = ep0.ack();
    try std.testing.expect(!ep0.configured());
    ep0.setup(.{ .request_type = 0x00, .request = 5, .length = 0 });
    _ = ep0.ack();
    try std.testing.expect(!ep0.configured());
    ep0.setup(.{ .request_type = 0x80, .request = 8, .length = 1 });
    ep0.in_packet(1, 64);
    try std.testing.expect(!ep0.configured());
}
