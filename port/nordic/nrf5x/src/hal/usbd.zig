//! USB device implementation
//!
//! References:
//! * RP2XXX HAL (port/raspberrypi/rp2xxx/src/hal/usb.zig)
//! * https://github.com/nrf-rs/nrf-usbd

const std = @import("std");
const log = std.log.scoped(.usb_dev);
const microzig = @import("microzig");
const cpu = microzig.cpu;
const peripherals = microzig.chip.peripherals;
const usb = microzig.core.usb;

const errata = @import("./usbd/errata.zig");

// +++++++++++++++++++++++++++++++++++++++++++++++++
// Code
// +++++++++++++++++++++++++++++++++++++++++++++++++

const MAX_PACKET_SIZE = 64;
const NUM_EP = 8;
const EP0_IN_STATUS_TIMEOUT_FRAMES: u11 = 5;

/// How many times `wait_easydma` reads the end event before it gives up.
///
/// This bounds a wait on a peripheral that has stopped answering; it is not a timing figure.
/// The product specification gives no duration for an EasyDMA transfer: it says only that
/// ENDEPIN[n] / ENDEPOUT[n] "indicate that the entire buffer has been consumed" (nRF52840 PS,
/// USBD, "EasyDMA"). A transfer here copies at most `MAX_PACKET_SIZE` bytes between RAM and
/// the peripheral. One turn of the loop is a volatile load, a compare and a branch, so no
/// fewer than three cycles of the 64 MHz core clock, and 2^20 turns are never less than
/// 49 ms: orders of magnitude more than a 64 byte copy, and still a bounded stall. Counted
/// in turns and not in time because the HAL's clock (`time.zig`) only runs once the
/// application has started the RTC.
const EASYDMA_WAIT_TURNS: u32 = 1 << 20;

const PowerState = union(enum) {
    detached,
    enabling,
    waiting_pwrrdy,
    connected,
};

const EP0_State = struct {
    direction: usb.types.Dir = .out,
    remaining_size: u16 = 0,
    in_pending: bool = false,
    in_start_frame: u11 = 0,
};

const EP_Config = struct {
    max_packet_size: u16 = MAX_PACKET_SIZE,
};

pub const USBD = struct {
    power: PowerState = .detached,

    bufs_in: [NUM_EP][MAX_PACKET_SIZE]u8 align(4) = @splat(@splat(0)),
    bufs_out: [NUM_EP][MAX_PACKET_SIZE]u8 align(4) = @splat(@splat(0)),
    eps_in: [NUM_EP]EP_Config = @splat(.{}),
    eps_out: [NUM_EP]EP_Config = @splat(.{}),
    ep0_state: EP0_State = .{},
    /// A packet was handed to data IN endpoint n and the host has not taken it yet.
    in_busy: [NUM_EP]bool = @splat(false),

    interface: usb.DeviceInterface,

    pub const max_supported_packet_size = MAX_PACKET_SIZE;
    pub const max_supported_bcd_usb: usb.types.Version = .v1_10;
    pub const default_vendor_id: usb.Config.IdStringPair = .{ .id = 0x1209, .str = "pid.codes" };
    pub const default_product_id: usb.Config.IdStringPair = .{ .id = 0x0001, .str = "nRF5x test device" };

    const vtable: usb.DeviceInterface.VTable = .{
        .ep_writev = ep_writev,
        .ep_readv = ep_readv,
        .ep_listen = ep_listen,
        .ep_open = ep_open,
        .set_address = set_address,
    };

    const Self = @This();

    pub fn init() Self {
        peripherals.USBD.USBPULLUP.write_raw(0);
        peripherals.USBD.ENABLE.write_raw(0);
        peripherals.USBD.EPINEN.write_raw(0x01); // only EP0 IN by default
        peripherals.USBD.EPOUTEN.write_raw(0x01); // only EP0 OUT by default
        peripherals.USBD.EVENTCAUSE.write_raw(0xFFFFFFFF); // W1C all
        peripherals.USBD.EPSTATUS.write_raw(0xFFFFFFFF); // W1C all
        peripherals.USBD.EPDATASTATUS.write_raw(0xFFFFFFFF); // W1C all
        peripherals.USBD.EVENTS_USBRESET.write_raw(0);
        peripherals.USBD.EVENTS_EP0SETUP.write_raw(0);
        peripherals.USBD.EVENTS_EP0DATADONE.write_raw(0);
        peripherals.USBD.EVENTS_EPDATA.write_raw(0);
        peripherals.USBD.EVENTS_USBEVENT.write_raw(0);
        for (0..8) |i| {
            peripherals.USBD.EVENTS_ENDEPIN[i].write_raw(0);
            peripherals.USBD.EVENTS_ENDEPOUT[i].write_raw(0);
            peripherals.USBD.EPIN[i].PTR.write_raw(0);
            peripherals.USBD.EPIN[i].MAXCNT.write_raw(0);
            peripherals.USBD.EPOUT[i].PTR.write_raw(0);
            peripherals.USBD.EPOUT[i].MAXCNT.write_raw(0);
        }
        return .{
            .interface = .{ .vtable = &vtable },
        };
    }

    pub fn poll(self: *Self, controller: anytype) void {
        comptime usb.validate_controller(@TypeOf(controller));

        if (self.power != .detached and peripherals.POWER.USBREGSTATUS.read().VBUSDETECT == .NoVbus) {
            self.teardown();
            self.power = .detached;
            return;
        }

        switch (self.power) {
            .detached => {
                if (peripherals.POWER.USBREGSTATUS.read().VBUSDETECT == .VbusPresent) {
                    errata.pre_enable();
                    peripherals.USBD.ENABLE.write_raw(1);
                    self.power = .enabling;
                }
            },
            .enabling => {
                if (peripherals.USBD.EVENTCAUSE.read().READY == .Ready) {
                    peripherals.USBD.EVENTCAUSE.write(.{ .READY = .Ready }); // W1C
                    peripherals.USBD.EVENTS_USBEVENT.write_raw(0);
                    errata.post_enable();
                    self.power = .waiting_pwrrdy;
                }
            },
            .waiting_pwrrdy => {
                if (peripherals.POWER.USBREGSTATUS.read().OUTPUTRDY == .Ready) {
                    peripherals.USBD.USBPULLUP.write_raw(1);
                    self.power = .connected;
                }
            },
            .connected => {
                // Bus reset
                if (peripherals.USBD.EVENTS_USBRESET.raw != 0) {
                    peripherals.USBD.EVENTS_USBRESET.write_raw(0);

                    self.reset();
                    controller.on_bus_reset(&self.interface);
                    return;
                }

                // SETUP packet captured by hardware
                if (peripherals.USBD.EVENTS_EP0SETUP.raw != 0) {
                    peripherals.USBD.EVENTS_EP0SETUP.write_raw(0);
                    // Aborted control transfer: drop stale DATADONE so it can't
                    // trigger on_buffer for the next transfer.
                    peripherals.USBD.EVENTS_EP0DATADONE.write_raw(0);
                    self.ep0_state.in_pending = false;

                    const setup: usb.types.SetupPacket = .{
                        .request_type = @bitCast(@as(u8, @intCast(peripherals.USBD.BMREQUESTTYPE.raw))),
                        .request = @intCast(peripherals.USBD.BREQUEST.raw),
                        .value = .from(@as(u16, @intCast(peripherals.USBD.WVALUEH.raw)) << 8 | @as(u16, @intCast(peripherals.USBD.WVALUEL.raw))),
                        .index = .from(@as(u16, @intCast(peripherals.USBD.WINDEXH.raw)) << 8 | @as(u16, @intCast(peripherals.USBD.WINDEXL.raw))),
                        .length = .from(@as(u16, @intCast(peripherals.USBD.WLENGTHH.raw)) << 8 | @as(u16, @intCast(peripherals.USBD.WLENGTHL.raw))),
                    };
                    self.ep0_state.direction = switch (peripherals.USBD.BMREQUESTTYPE.read().DIRECTION) {
                        .HostToDevice => .out,
                        .DeviceToHost => .in,
                    };
                    self.ep0_state.remaining_size = setup.length.native();
                    controller.on_setup_req(&self.interface, &setup);
                }

                // EP0 data-phase completions
                if (peripherals.USBD.EVENTS_EP0DATADONE.raw != 0) {
                    // Here nrf-usbd doesn't clear OUT events
                    // (https://github.com/nrf-rs/nrf-usbd/blob/main/src/usbd.rs#L683)
                    // But this case is not handled in the controller yet
                    peripherals.USBD.EVENTS_EP0DATADONE.write_raw(0);
                    self.ep0_state.in_pending = false;
                    switch (self.ep0_state.direction) {
                        .in => controller.on_buffer(&self.interface, .in(.ep0)),
                        // Control-OUT with data-phase is unhandled in the controller
                        .out => peripherals.USBD.TASKS_EP0STATUS.write_raw(1),
                    }
                }

                // Data-endpoint completions
                if (peripherals.USBD.EVENTS_EPDATA.raw != 0) {
                    peripherals.USBD.EVENTS_EPDATA.write_raw(0);
                    const status = peripherals.USBD.EPDATASTATUS.raw;
                    peripherals.USBD.EPDATASTATUS.write_raw(status); // W1C handled bits
                    // Calling on_buffer() for each set bit
                    // IN endpoints (bits 1-7)
                    var status_in = status >> 1;
                    inline for (1..8) |i| {
                        if (status_in == 0) break;
                        // Only a packet this HAL is waiting on is reported. A bit for an
                        // endpoint that is not busy belongs to a packet that was loaded
                        // before the endpoint was opened again (see `ep_open`), and the
                        // driver that owns the endpoint now never wrote it.
                        if (status_in & 1 == 1 and self.in_busy[i]) {
                            self.in_busy[i] = false;
                            controller.on_buffer(&self.interface, .in(@fromBackingInt(i)));
                        }
                        status_in >>= 1;
                    }
                    // OUT endpoints (bits 17-23)
                    var status_out = status >> 17;
                    inline for (1..8) |i| {
                        if (status_out == 0) break;
                        if (status_out & 1 == 1) controller.on_buffer(&self.interface, .out(@fromBackingInt(i)));
                        status_out >>= 1;
                    }
                }

                // TODO: Implement `Suspend`
                if (peripherals.USBD.EVENTCAUSE.read().SUSPEND == .Detected) {
                    peripherals.USBD.EVENTCAUSE.write(.{ .SUSPEND = .Detected });
                    peripherals.USBD.EVENTS_USBEVENT.write_raw(0);
                }

                // TODO: Implement `Resume`
                if (peripherals.USBD.EVENTCAUSE.read().RESUME == .Detected) {
                    peripherals.USBD.EVENTCAUSE.write(.{ .RESUME = .Detected });
                    peripherals.USBD.EVENTS_USBEVENT.write_raw(0);
                }

                // TODO: ISO endpoints

                // EP0 IN data stage:
                // Host may jump to the status stage without acknowledging the data transfer
                // so the EP0DATADONE_EP0STATUS short may never fire and device will keep
                // NAKing the OUT tokens.
                // HACK: trigger status stage if the IN transfer is not acknowledged after a few frames
                if (self.ep0_state.in_pending) {
                    const now = peripherals.USBD.FRAMECNTR.read().FRAMECNTR;
                    if ((now -% self.ep0_state.in_start_frame) >= EP0_IN_STATUS_TIMEOUT_FRAMES) {
                        peripherals.USBD.TASKS_EP0STATUS.write_raw(1);
                        peripherals.USBD.EVENTS_EP0DATADONE.write_raw(0);
                        self.ep0_state.in_pending = false;
                    }
                }
            },
        }
    }

    fn teardown(_: *Self) void {
        // Upon VBUS removal detection, it is recommended to
        // let on-going EasyDMA transfers finish before disabling USBD
        //
        // But in this case it won't happen because
        // we busywait for ENDEP* with interrupts disabled
        peripherals.USBD.USBPULLUP.write_raw(0);
        peripherals.USBD.ENABLE.write_raw(0);
    }

    fn reset(self: *Self) void {
        peripherals.USBD.EPDATASTATUS.write_raw(0xFFFFFFFF); // W1C all
        peripherals.USBD.EPSTATUS.write_raw(0xFFFFFFFF); // W1C all
        peripherals.USBD.EVENTS_EP0SETUP.write_raw(0);
        peripherals.USBD.EVENTS_EP0DATADONE.write_raw(0);
        peripherals.USBD.EVENTS_EPDATA.write_raw(0);
        peripherals.USBD.SHORTS.write(.{ .EP0DATADONE_EP0STATUS = .Disabled });
        peripherals.USBD.EPINEN.write_raw(0x01); // only EP0 IN
        peripherals.USBD.EPOUTEN.write_raw(0x01); // only EP0 OUT

        for (1..NUM_EP) |i| {
            // NOTE: Data endpoints are automatically disabled on reset
            peripherals.USBD.EPIN[i].PTR.write_raw(0);
            peripherals.USBD.EPIN[i].MAXCNT.write_raw(0);
            peripherals.USBD.EPOUT[i].PTR.write_raw(0);
            peripherals.USBD.EPOUT[i].MAXCNT.write_raw(0);

            // When first enabled, bulk/interrupt endpoints
            // will return NAK until 0 is written to SIZE.EPOUT[n]
            peripherals.USBD.SIZE.EPOUT[i].write_raw(0);
        }

        self.eps_in = @splat(.{});
        self.eps_out = @splat(.{});
        self.ep0_state = .{};
        self.in_busy = @splat(false);
    }

    /// Busy-waits for the EasyDMA transfer just started on an endpoint to end, and clears
    /// its end event. Returns false if the event did not come within `EASYDMA_WAIT_TURNS`.
    ///
    /// The wait is here at all because "only a single EasyDMA transfer can take place in
    /// USBD at any time" and the next one may not be started before this one's end event
    /// (nRF52840 PS, USBD, "EasyDMA").
    fn wait_easydma(dir: usb.types.Dir, i: u4) bool {
        var turns: u32 = 0;
        while (turns < EASYDMA_WAIT_TURNS) : (turns += 1) {
            const ended = switch (dir) {
                .in => peripherals.USBD.EVENTS_ENDEPIN[i].raw,
                .out => peripherals.USBD.EVENTS_ENDEPOUT[i].raw,
            };
            if (ended != 0) {
                switch (dir) {
                    .in => peripherals.USBD.EVENTS_ENDEPIN[i].write_raw(0),
                    .out => peripherals.USBD.EVENTS_ENDEPOUT[i].write_raw(0),
                }
                return true;
            }
        }
        return false;
    }

    /// Turns the USBD interrupt off in the NVIC for the length of an EasyDMA transfer; the
    /// caller turns it on again if it was on. An application may run `poll` from the USBD
    /// interrupt, and `poll` starts transfers of its own through the controller and the
    /// drivers. One that came in between TASKS_STARTEPIN / TASKS_STARTEPOUT and the end event
    /// would start a second transfer while the first is running, which the peripheral does
    /// not allow (see `wait_easydma`).
    fn usbd_interrupt_off() void {
        cpu.interrupt.disable(.USBD);
        // The barriers CMSIS's `__NVIC_DisableIRQ` puts after the same write.
        cpu.dsb();
        cpu.isb();
    }

    fn ep_writev(
        itf: *usb.DeviceInterface,
        ep_num: usb.types.Endpoint.Num,
        data: []const []const u8,
    ) usb.types.Len {
        const self: *Self = @fieldParentPtr("interface", itf);
        log.debug("ep_writev {t}: ({} bytes) {X} ({s})", .{ ep_num, data[0].len, data[0], data[0] });

        // A zero-length write to EP0 asks for the status stage, with one exception: while a
        // control read still owes the host bytes of wLength, it is a packet of the data stage.
        // The controller sends one after a reply that ends on a full packet, to tell the host
        // that there is no more. That one goes out below like any other EP0 IN packet, with
        // MAXCNT 0, and being short it lets the status stage follow by itself. TASKS_EP0STATUS
        // instead would leave the host's next IN token without the packet it is waiting for.
        const ep0_data_stage = ep_num == .ep0 and
            self.ep0_state.direction == .in and self.ep0_state.remaining_size != 0;
        if (data[0].len == 0 and !ep0_data_stage) {
            if (ep_num == .ep0) peripherals.USBD.TASKS_EP0STATUS.write_raw(1);
            return 0;
        }

        const i = @backingInt(ep_num);

        // A data endpoint holds one packet until the host takes it (EPDATA, reported through
        // EPDATASTATUS in `poll`). Starting another EasyDMA transfer before that would
        // rewrite the packet the host may be reading, so the caller is told that nothing
        // was taken. EP0 is exempt: a new SETUP makes whatever it still held obsolete.
        if (ep_num != .ep0 and self.in_busy[i]) {
            log.warn("ep_writev {t}: the previous packet has not been sent", .{ep_num});
            return 0;
        }

        const scratch = &self.bufs_in[i];
        const scratch_cap = @min(self.eps_in[i].max_packet_size, scratch.len);
        var scratch_slice: []align(1) u8 = scratch[0..scratch_cap];

        for (data) |src| {
            const len = @min(src.len, scratch_slice.len);
            @memcpy(scratch_slice[0..len], src[0..len]);
            scratch_slice = scratch_slice[len..];
        }

        const len: usb.types.Len = @intCast(scratch_cap - scratch_slice.len);

        // Prepare DMA transfer
        peripherals.USBD.EPIN[i].PTR.write_raw(@intFromPtr(scratch));
        peripherals.USBD.EPIN[i].MAXCNT.write_raw(len);

        if (ep_num == .ep0) {
            // EPIN0: a short packet (len < max_packet_size) indicates the end of the data
            // stage and must be followed by us responding with an ACK token to an OUT token
            // sent from the host (AKA the status stage)
            // Also handle the case when it's the last packet with size 64
            self.ep0_state.remaining_size -|= len;
            const is_short_packet = len < self.eps_in[0].max_packet_size;
            const is_last_packet = is_short_packet or self.ep0_state.remaining_size == 0;
            if (is_last_packet) {
                peripherals.USBD.SHORTS.write(.{ .EP0DATADONE_EP0STATUS = .Enabled });
            } else {
                peripherals.USBD.SHORTS.write(.{ .EP0DATADONE_EP0STATUS = .Disabled });
            }

            // Saving current frame counter to start the timeout that will trigger
            // status stage if the IN transfer is not acknowledged after a few frames
            self.ep0_state.in_start_frame = peripherals.USBD.FRAMECNTR.read().FRAMECNTR;
            self.ep0_state.in_pending = true;
        }

        // Start DMA
        const was_enabled = cpu.interrupt.is_enabled(.USBD);
        defer if (was_enabled) cpu.interrupt.enable(.USBD);
        usbd_interrupt_off();
        // An end event left by a transfer that was given up on must not end this wait.
        peripherals.USBD.EVENTS_ENDEPIN[i].write_raw(0);
        // Nor may a completion from before be taken for this packet's. The endpoint is not
        // busy here, so a bit set now is that of a packet loaded before the endpoint was
        // opened again and taken by the host since (EPDATASTATUS is W1C, EPINn is bit n).
        if (ep_num != .ep0) peripherals.USBD.EPDATASTATUS.write_raw(@as(u32, 1) << i);
        // Busy from before the transfer starts: the host can take the packet as soon as it
        // is in the endpoint, and a `poll` that runs before this function returns (from an
        // interrupt) then clears the flag. Set after the wait, it would stay set for good.
        if (ep_num != .ep0) self.in_busy[i] = true;
        peripherals.USBD.TASKS_STARTEPIN[i].write_raw(1);
        if (!wait_easydma(.in, i)) {
            log.err("ep_writev {t}: EasyDMA did not finish", .{ep_num});
            if (ep_num == .ep0) self.ep0_state.in_pending = false else self.in_busy[i] = false;
            return 0;
        }

        return len;
    }

    fn ep_readv(
        itf: *usb.DeviceInterface,
        ep_num: usb.types.Endpoint.Num,
        data: []const []u8,
    ) usb.types.Len {
        var total_len: usize = data[0].len;
        for (data[1..]) |d| total_len += d.len;
        log.debug("ep_readv {t}: ({} bytes)", .{ ep_num, total_len });

        const self: *Self = @fieldParentPtr("interface", itf);
        const i = @backingInt(ep_num);
        const scratch_buf = &self.bufs_out[i];
        // SIZE.EPOUT[n] is a 7-bit field and can read up to 127; the buffer EasyDMA copies
        // into holds one 64-byte packet.
        const size: u32 = @min(peripherals.USBD.SIZE.EPOUT[i].raw, scratch_buf.len);

        // Prepare DMA transfer
        peripherals.USBD.EPOUT[i].PTR.write_raw(@intFromPtr(scratch_buf));
        peripherals.USBD.EPOUT[i].MAXCNT.write_raw(size);

        // Start DMA
        const was_enabled = cpu.interrupt.is_enabled(.USBD);
        defer if (was_enabled) cpu.interrupt.enable(.USBD);
        usbd_interrupt_off();
        // An end event left by a transfer that was given up on must not end this wait.
        peripherals.USBD.EVENTS_ENDEPOUT[i].write_raw(0);
        peripherals.USBD.TASKS_STARTEPOUT[i].write_raw(1);
        if (!wait_easydma(.out, i)) {
            log.err("ep_readv {t}: EasyDMA did not finish", .{ep_num});
            return 0;
        }

        var scratch_slice: []align(1) u8 = scratch_buf[0..size];

        for (data) |dst| {
            const len = @min(dst.len, scratch_slice.len);
            @memcpy(dst[0..len], scratch_slice[0..len]);
            scratch_slice = scratch_slice[len..];
            if (scratch_slice.len == 0)
                return @intCast(size);
        }

        log.warn("discarding rx data on ep {t}, {} bytes received", .{ ep_num, size });
        return @intCast(size - scratch_slice.len);
    }

    fn ep_listen(
        _: *usb.DeviceInterface,
        ep_num: usb.types.Endpoint.Num,
        len: usb.types.Len,
    ) void {
        log.debug("ep_listen {t}: ({} bytes)", .{ ep_num, len });

        if (ep_num == .ep0) {
            peripherals.USBD.TASKS_EP0RCVOUT.write_raw(1);
        }
    }

    /// Limitation: a packet that EasyDMA has already copied into a data IN endpoint when the
    /// endpoint is opened again is not withdrawn. It stays in the peripheral and the host can
    /// still take it. The product specification documents no register that discards it; nrfx
    /// does it through undocumented ones (USBD + 0x800 / 0x804), which this HAL does not use.
    /// Its completion is not reported: `poll` passes on only the completion of a packet
    /// written since the endpoint was opened, and `ep_writev` drops one that is still
    /// latched when it loads the next packet. What is left is the packet itself, and a
    /// completion that arrives between that drop and the load.
    /// The core's `ep_open` contract names this exception.
    fn ep_open(itf: *usb.DeviceInterface, desc: *const usb.descriptor.Endpoint) void {
        const self: *Self = @fieldParentPtr("interface", itf);
        const ep = desc.endpoint;
        const i = @backingInt(ep.num);
        const mask: u32 = @as(u32, 1) << i;

        // The endpoint may have been open in an earlier configuration (see `ep_open` in
        // core/usb.zig), and enabling an endpoint that is already enabled changes nothing,
        // so what that configuration left behind is undone here.
        if (ep.num != .ep0) {
            // Both sides start a configuration at DATA0 (USB 2.0, 9.1.1.5). "Controlling the
            // data toggle of data IN or OUT endpoint n (n=1..7) is done through register
            // DTOGGLE" (nRF52840 PS, USBD, "Bulk and interrupt transactions"): EP in bits
            // 0-2, IO in bit 7 (1 = IN), VALUE in bits 8-9 (0 = Nop, 1 = Data0). Like nrfx's
            // `nrf_usbd_dtoggle_set`, select the endpoint with a Nop write first.
            const select: u32 = @as(u32, i) | (@as(u32, @intFromBool(ep.dir == .in)) << 7);
            peripherals.USBD.DTOGGLE.write_raw(select);
            peripherals.USBD.DTOGGLE.write_raw(select | (1 << 8));
        }
        switch (ep.dir) {
            .in => {
                self.eps_in[i].max_packet_size = desc.max_packet_size.native();
                self.in_busy[i] = false;
                // A packet the earlier configuration sent must not be reported to this one.
                peripherals.USBD.EPDATASTATUS.write_raw(mask); // W1C, EPINn is bit n
                peripherals.USBD.EPINEN.write_raw(peripherals.USBD.EPINEN.raw | mask);
            },
            .out => {
                self.eps_out[i].max_packet_size = desc.max_packet_size.native();
                peripherals.USBD.EPOUTEN.write_raw(peripherals.USBD.EPOUTEN.raw | mask);
                // Nor one it received and never read. Dropping the report alone would leave
                // the endpoint answering NAK for good: "a NAK is returned until the software
                // writes any value to register SIZE.EPOUT[n]" (nRF52840 PS, USBD, "Bulk and
                // interrupt OUT transaction"). nrfx's `nrfx_usbd_ep_enable` does the same.
                peripherals.USBD.EPDATASTATUS.write_raw(mask << 16); // W1C, EPOUTn is bit 16+n
                if (ep.num != .ep0) peripherals.USBD.SIZE.EPOUT[i].write_raw(0);
            },
        }

        const attr = desc.attributes;
        log.debug(
            "ep_open {t} {t}: {{ type: {t}, sync: {t}, usage: {t}, size: {} }}",
            .{ ep.num, ep.dir, attr.transfer_type, attr.synchronisation, attr.usage, desc.max_packet_size.native() },
        );
    }

    /// No-op: the peripheral handles this
    fn set_address(_: *usb.DeviceInterface, _: u7) void {}
};
