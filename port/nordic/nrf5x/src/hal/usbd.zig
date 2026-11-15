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
const ep0 = @import("./usbd/ep0.zig");

test {
    _ = ep0;
}

// +++++++++++++++++++++++++++++++++++++++++++++++++
// Code
// +++++++++++++++++++++++++++++++++++++++++++++++++

const MAX_PACKET_SIZE = 64;
const NUM_EP = 8;

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

/// How many times `leave_low_power` reads EVENTCAUSE for USBWUALLOWED before it goes on
/// without it. Like `EASYDMA_WAIT_TURNS` a bound, not a timing figure: the product
/// specification says that the bit is set "upon writing the ForceNormal in register
/// LOWPOWER" (nRF52840 PS v1.1, 6.35.7.3) and gives no duration. `poll` never waits this
/// out: it does not call `leave_low_power`.
const WAKE_WAIT_TURNS: u32 = 1 << 20;

// EVENTCAUSE (nRF52840 PS v1.1, 6.35.13.25); every bit is cleared by writing 1 to it.
const CAUSE_SUSPEND: u32 = 1 << 8;
const CAUSE_RESUME: u32 = 1 << 9;
const CAUSE_USBWUALLOWED: u32 = 1 << 10;

const PowerState = union(enum) {
    detached,
    enabling,
    waiting_pwrrdy,
    connected,
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
    /// Where the control transfer on endpoint 0 stands.
    control: ep0.Control = .{},
    /// A packet was handed to data IN endpoint n and the host has not taken it yet.
    in_busy: [NUM_EP]bool = @splat(false),
    /// The bus is suspended and the peripheral has been put in its low power mode (see
    /// `enter_low_power`). Tasks and the registers of 6.35.12 are then out of reach. `poll`
    /// clears it when it sees the host on the bus again.
    low_power: bool = false,
    /// The data endpoints `ep_open` was called for since the last SETUP packet, bit n for
    /// endpoint n. After a SET_CONFIGURATION these are the endpoints of the configuration
    /// the host selected, and all others are disabled (see `poll`).
    opened_in: u8 = 0,
    opened_out: u8 = 0,

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

    /// Nothing here touches USBPULLUP, EPINEN or EPOUTEN. They are among the registers that
    /// "cannot be accessed" while the peripheral "is not enabled (using the ENABLE register)
    /// and ready (signalled by the READY bit in EVENTCAUSE after a USBEVENT event)"
    /// (nRF52840 PS v1.1, 6.35.12), and it is disabled here. `poll` writes them when READY
    /// has come.
    pub fn init() Self {
        peripherals.USBD.ENABLE.write_raw(0);
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
                    // Enabled and ready: from here on the registers of 6.35.12 can be
                    // accessed. The pull-up stays off until the regulator is ready, and
                    // only endpoint 0 is enabled, whatever was left in the registers by
                    // an earlier connection or by the program that ran before this one.
                    peripherals.USBD.USBPULLUP.write_raw(0);
                    peripherals.USBD.EPINEN.write_raw(0x01); // only EP0 IN
                    peripherals.USBD.EPOUTEN.write_raw(0x01); // only EP0 OUT
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
                // In low power mode nothing below may be done: the SETUP registers, tasks
                // and the endpoint registers cannot be accessed "when USBD is in low power
                // mode while the USB bus is suspended" (nRF52840 PS v1.1, 6.35.12). The
                // events and EVENTCAUSE are not on that list, and they say when the host
                // is back.
                //
                // Nothing is written to bring the peripheral back then, and nothing is
                // waited for, because nrfx v3.9.0 does neither (drivers/src/nrfx_usbd.c).
                // Its handlers for RESUME and for a bus reset only note that the bus is no
                // longer suspended (`ev_usbevent_handler`, lines 1253-1261, and
                // `ev_usbreset_handler`, 885-895), and its handler for a SETUP packet reads
                // the SETUP registers as at any other time (`ev_setup_handler`,
                // 1200-1208). It writes ForceNormal in two places only: for a remote
                // wake-up (`nrfx_usbd_wakeup_req`, 1921), and when the host resumed while
                // LowPower was being written (`nrfx_usbd_suspend`, 1899-1902; see
                // `enter_low_power`). That the peripheral is back in normal mode by itself
                // once the host is on the bus is concluded from that code, and from the
                // words "while the USB bus is suspended" above. It has not been observed on
                // a board, and two sentences read the other way. The product specification
                // says of the value ForceNormal of LOWPOWER: "Software must write this value
                // to exit low power mode and before performing a remote wake-up"
                // (6.35.13.50). nrfx's header says of the write that the event "will be
                // generated and then the USBD registers can be accessed" (hal/nrf_usbd.h,
                // lines 1023-1025, on `nrf_usbd_lowpower_disable`).
                //
                // USBEVENT is cleared here because the return below comes before the place
                // where it is cleared otherwise. A driver's write during the suspend leaves
                // it set (the ForceNormal of `leave_low_power` raises it), and an
                // application that runs `poll` from the USBD interrupt would be back in the
                // interrupt at once, for as long as the bus is suspended. It is cleared
                // before the bus is looked at, so that a RESUME that comes after the look
                // raises it again.
                if (self.low_power) {
                    peripherals.USBD.EVENTS_USBEVENT.write_raw(0);
                    if (!bus_active()) return;
                    self.low_power = false;
                }

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

                    const setup: usb.types.SetupPacket = .{
                        .request_type = @bitCast(@as(u8, @intCast(peripherals.USBD.BMREQUESTTYPE.raw))),
                        .request = @intCast(peripherals.USBD.BREQUEST.raw),
                        .value = .from(@as(u16, @intCast(peripherals.USBD.WVALUEH.raw)) << 8 | @as(u16, @intCast(peripherals.USBD.WVALUEL.raw))),
                        .index = .from(@as(u16, @intCast(peripherals.USBD.WINDEXH.raw)) << 8 | @as(u16, @intCast(peripherals.USBD.WINDEXL.raw))),
                        .length = .from(@as(u16, @intCast(peripherals.USBD.WLENGTHH.raw)) << 8 | @as(u16, @intCast(peripherals.USBD.WLENGTHL.raw))),
                    };
                    self.control.setup(.{
                        .request_type = @bitCast(setup.request_type),
                        .request = setup.request,
                        .length = setup.length.native(),
                    });
                    self.opened_in = 0;
                    self.opened_out = 0;
                    controller.on_setup_req(&self.interface, &setup);
                    // The controller answers a request before it returns, or not at all.
                    ep0_trigger(self.control.setup_handled());

                    // The host selected a configuration, or none (value 0). The controller
                    // opened the endpoints of the one it selected and has no word for those
                    // of the one before, so they are closed here: an endpoint that stays
                    // enabled goes on answering the host, with the packet it still holds or
                    // with an ACK for one nobody will read, in a configuration that does
                    // not have it. nrfx offers its users `nrfx_usbd_ep_disable` for the
                    // same.
                    if (self.control.configured()) {
                        peripherals.USBD.EPINEN.write_raw(0x01 | @as(u32, self.opened_in));
                        peripherals.USBD.EPOUTEN.write_raw(0x01 | @as(u32, self.opened_out));
                        // Nor does a closed endpoint report the packet it was holding.
                        for (1..NUM_EP) |i| {
                            if (self.opened_in >> @intCast(i) & 1 == 0) self.in_busy[i] = false;
                        }
                    }
                }

                // EP0 data-phase completions
                //
                // Not while a SETUP packet waits that arrived after the check above. The
                // completion is then that of the transfer the packet ended, and acting on it
                // would have the controller load that transfer's next packet: once in the
                // endpoint, a packet "will trigger a valid, acknowledged (ACK) IN
                // transaction" (nRF52840 PS v1.1, 6.35.9.1), and the host would take it for
                // the answer to its new request. The event is left for the next `poll`,
                // which drops it when it takes up the SETUP packet.
                // For one that arrives after this check, `ep_writev` looks again before it loads
                // the packet.
                if (peripherals.USBD.EVENTS_EP0DATADONE.raw != 0 and
                    peripherals.USBD.EVENTS_EP0SETUP.raw == 0)
                {
                    peripherals.USBD.EVENTS_EP0DATADONE.write_raw(0);
                    switch (self.control.direction) {
                        .in => {
                            // The host has taken a packet of a control read. After the last
                            // one the status stage is started here, by the task and not by
                            // the shortcut EP0DATADONE -> EP0STATUS (see `ep0.Control.in_done`).
                            ep0_trigger(self.control.in_done());
                            controller.on_buffer(&self.interface, .in(.ep0));
                        },
                        // A packet of a control write's data stage is in the endpoint. The
                        // controller has no use for it (its `on_buffer` only logs a packet
                        // on EP0 OUT), so it is not told; but the packet has to be taken out
                        // before anything else may follow: the next packet or the status
                        // stage comes after ENDEPOUT[0] (nRF52840 PS v1.1, 6.35.9.2).
                        // Outside a data stage nothing let a packet in, so none is taken.
                        .out => if (self.control.out_data_stage()) {
                            if (self.easydma_out(0)) |size| {
                                ep0_trigger(self.control.out_packet(@intCast(size), self.eps_out[0].max_packet_size));
                            } else {
                                log.err("EP0: EasyDMA did not finish, control write stalled", .{});
                                ep0_trigger(self.control.out_failed());
                            }
                        },
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

                // Suspend and resume
                const cause = peripherals.USBD.EVENTCAUSE.raw &
                    (CAUSE_SUSPEND | CAUSE_RESUME | CAUSE_USBWUALLOWED);
                if (cause != 0) {
                    peripherals.USBD.EVENTCAUSE.write_raw(cause); // W1C
                    peripherals.USBD.EVENTS_USBEVENT.write_raw(0);
                    // USBWUALLOWED answers a ForceNormal (6.35.7.3). Nothing here waits for
                    // it, so it is only cleared: nrfx's handler acts on it for a remote
                    // wake-up alone (`ev_usbevent_handler`, 1262-1278), which this HAL
                    // does not request.
                    //
                    // With both bits set the bus went idle and came back between two calls
                    // of `poll`, or the other way round, which cannot be told apart. The
                    // peripheral is put in normal mode: it then answers the host in either
                    // case, at the price of the suspend current in the second.
                    //
                    // Put there, by a write: in the second case it may have been in low
                    // power mode until this call, which saw the RESUME, took the host
                    // to be back and wrote nothing. Left like that, with the bus suspended
                    // and `low_power` false, a driver's write would trigger a task the
                    // peripheral cannot take. Nothing is waited for, so a write that
                    // follows at once may still be too early for it.
                    if (cause & CAUSE_SUSPEND != 0) {
                        if (cause & CAUSE_RESUME == 0) self.enter_low_power() else force_normal();
                    }
                }

                // TODO: ISO endpoints
            },
        }
    }

    fn teardown(self: *Self) void {
        // Upon VBUS removal detection, it is recommended to
        // let on-going EasyDMA transfers finish before disabling USBD
        //
        // But in this case it won't happen because
        // we busywait for ENDEP* with interrupts disabled

        if (self.low_power) {
            // USBPULLUP cannot be accessed in low power mode either (6.35.12), so it is
            // left alone and disabling the peripheral has to take the pull-up off the bus.
            // LOWPOWER is written back to its reset value: the specification does not say
            // that ENABLE resets it, and a peripheral that came up in low power mode at
            // the next connection would be out of reach.
            peripherals.USBD.LOWPOWER.write_raw(0);
            self.low_power = false;
            peripherals.USBD.ENABLE.write_raw(0);
            return;
        }

        // USBPULLUP cannot be accessed before READY (nRF52840 PS v1.1, 6.35.12), and until
        // then nothing has turned the pull-up on: `poll` writes 0 at READY and 1 when the
        // regulator is ready.
        switch (self.power) {
            .detached, .enabling => {},
            .waiting_pwrrdy, .connected => peripherals.USBD.USBPULLUP.write_raw(0),
        }
        peripherals.USBD.ENABLE.write_raw(0);
    }

    /// The host is on the bus again, or was while the peripheral went to low power mode:
    /// "If the host resumes bus activity with or without a RESUME condition (in other
    /// words: bus activity is defined as any non-J state), the USBD peripheral will generate
    /// a USBEVENT event, with RESUME bit set in register EVENTCAUSE" (nRF52840 PS v1.1,
    /// 6.35.7.2). A bus reset or a SETUP packet that shows without the bit is taken for
    /// the same.
    ///
    /// Anomaly 211, "Device remains in SUSPEND too long when host resumes a bus activity
    /// (sending SOF packets) without a RESUME condition" (the title in nrfx_usbd.c, lines
    /// 89-90), is not worked around. nrfx v3.9.0 lists it for the nRF52820, for the
    /// nRF52833 and for every nRF52840 but the one whose variant word (0x10000134) reads 0
    /// (`nrf52_errata_211` in mdk/nrf52_erratas.h), so also for current silicon, and has
    /// its workaround off by default (`NRFX_USBD_USE_WORKAROUND_FOR_ANOMALY_211`, line 91).
    /// That workaround keeps the register write of anomaly 187 in place for as long as the
    /// peripheral is enabled (`nrfx_usbd_enable`, 1740-1783) instead of ending it at READY,
    /// as `errata.post_enable` does here. A host that resumes in that way may thus find the
    /// device late.
    fn bus_active() bool {
        return peripherals.USBD.EVENTCAUSE.raw & CAUSE_RESUME != 0 or
            peripherals.USBD.EVENTS_USBRESET.raw != 0 or
            peripherals.USBD.EVENTS_EP0SETUP.raw != 0;
    }

    /// The bus is suspended: "In order to reduce idle current of USBD, the software must
    /// explicitly place the USBD in low power mode through writing LowPower to register
    /// LOWPOWER" (nRF52840 PS v1.1, 6.35.7.1), "after DMA and software have finished
    /// interacting with the USB peripheral" (6.35.13.50). No EasyDMA transfer is running
    /// where this is called: each one is waited for where it is started.
    ///
    /// The checks for a host that resumed in the meantime, before and after the write, are
    /// those of nrfx's `nrfx_usbd_suspend` (v3.9.0, nrfx_usbd.c lines 1889-1912), and so is
    /// what follows the second: ForceNormal is written back, and nothing is waited for.
    /// The high frequency crystal oscillator is left running; an application that stops it
    /// for the suspend has to start it again before the host resumes.
    fn enter_low_power(self: *Self) void {
        if (peripherals.USBD.EVENTCAUSE.raw & CAUSE_RESUME != 0) return;
        peripherals.USBD.LOWPOWER.write_raw(1);
        _ = peripherals.USBD.LOWPOWER.raw; // read back, as nrfx's `nrf_usbd_lowpower_enable`
        if (peripherals.USBD.EVENTCAUSE.raw & CAUSE_RESUME != 0) {
            force_normal();
            return;
        }
        self.low_power = true;
    }

    /// Writes ForceNormal to LOWPOWER and waits for nothing, which is what nrfx does when
    /// the host resumed while it wrote LowPower (`nrfx_usbd_suspend`, v3.9.0, nrfx_usbd.c
    /// lines 1899-1902). The USBWUALLOWED that answers the write is cleared by the next
    /// `poll`.
    fn force_normal() void {
        peripherals.USBD.LOWPOWER.write_raw(0);
        _ = peripherals.USBD.LOWPOWER.raw; // read back, as nrfx's `nrf_usbd_lowpower_disable`
    }

    /// Brings the peripheral back to normal mode while the bus is still suspended, for an
    /// EasyDMA transfer of the software's own (see `easydma_out` and `ep_writev`), and waits
    /// until it can be used: "Upon writing the ForceNormal in register LOWPOWER, a USBEVENT
    /// event is generated with the USBWUALLOWED bit set in register EVENTCAUSE" (nRF52840
    /// PS v1.1, 6.35.7.3), described as "USB MAC has been woken up and operational"
    /// (6.35.13.25). nrfx's header says of the same write that the event "will be generated
    /// and then the USBD registers can be accessed" (hal/nrf_usbd.h,
    /// `nrf_usbd_lowpower_disable`).
    ///
    /// The bus is not driven: this is never a remote wake-up request. Nor is it what
    /// happens when the host resumes, which takes no write and no wait (see `poll`).
    ///
    /// The wait has no model in nrfx v3.9.0, where nothing looks at the mode before a
    /// transfer is started, and it is a busy one because the transfer's caller is waiting
    /// for the packet. `poll` does not get here: it runs the controller and the drivers
    /// only after it has seen the host on the bus and cleared `low_power`, so the caller is
    /// the application, writing or reading during a suspend.
    ///
    /// Around the wake-up goes the workaround for anomaly 171 of the nRF52840, "USB might
    /// not power up", which is said to apply to leaving low power mode as it does to
    /// ENABLE. nrfx v3.9.0 applies its first half in `nrfx_usbd_wakeup_req` and never the
    /// second there; the second half at USBWUALLOWED follows Nordic's online errata, which
    /// was not checked against the PDF. It is undone when the wait is given up, too, so
    /// that it does not outlast this function.
    fn leave_low_power(self: *Self) void {
        self.low_power = false;
        errata.pre_wakeup();
        // A bit left by an earlier ForceNormal must not end this wait.
        peripherals.USBD.EVENTCAUSE.write_raw(CAUSE_USBWUALLOWED); // W1C
        peripherals.USBD.LOWPOWER.write_raw(0);
        _ = peripherals.USBD.LOWPOWER.raw; // read back, as nrfx's `nrf_usbd_lowpower_disable`
        var turns: u32 = 0;
        while (turns < WAKE_WAIT_TURNS) : (turns += 1) {
            if (peripherals.USBD.EVENTCAUSE.raw & CAUSE_USBWUALLOWED != 0) {
                peripherals.USBD.EVENTCAUSE.write_raw(CAUSE_USBWUALLOWED); // W1C
                break;
            }
        } else {
            // Gone on without it: the transfer that follows may reach a peripheral that
            // is not ready, and then does not end (see `wait_easydma`).
            log.warn("USBWUALLOWED did not come after leaving low power mode", .{});
        }
        errata.post_wakeup();
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
        self.control = .{};
        self.in_busy = @splat(false);
        self.opened_in = 0;
        self.opened_out = 0;
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

    /// Runs the EasyDMA transfer that PTR and MAXCNT of an endpoint describe: starts it and
    /// waits for it to end. Returns false if it did not end (see `wait_easydma`). Every
    /// transfer of this HAL is started here.
    ///
    /// Around the transfer goes the workaround for anomaly 199 of the nRF52840, "USBD cannot
    /// receive tasks during DMA" (see `errata.dma_begin`). It is undone before this returns,
    /// so that the task a caller triggers next (EP0RCVOUT, EP0STATUS, EP0STALL) comes after
    /// it. That holds for a transfer that did not end, too: nothing else will end it, and
    /// the stall its caller answers it with is a task like any other. Whether the peripheral
    /// performs a task then is not known.
    fn run_easydma(dir: usb.types.Dir, i: u4) bool {
        errata.dma_begin();
        defer errata.dma_end();
        switch (dir) {
            .in => peripherals.USBD.TASKS_STARTEPIN[i].write_raw(1),
            .out => peripherals.USBD.TASKS_STARTEPOUT[i].write_raw(1),
        }
        return wait_easydma(dir, i);
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

    /// Triggers the task for the next stage of the control transfer `self.control` follows.
    ///
    /// Not if a SETUP packet has arrived since `poll` last looked: the task would be applied
    /// to the transfer that packet started, which `self.control` knows nothing of yet. The
    /// next `poll` takes that transfer up from its EP0SETUP. A SETUP packet that arrives
    /// between this check and the write is not caught.
    fn ep0_trigger(action: ep0.Action) void {
        if (action == .none or peripherals.USBD.EVENTS_EP0SETUP.raw != 0) return;
        switch (action) {
            .none => unreachable,
            .rcvout => peripherals.USBD.TASKS_EP0RCVOUT.write_raw(1),
            .status => peripherals.USBD.TASKS_EP0STATUS.write_raw(1),
            .stall => peripherals.USBD.TASKS_EP0STALL.write_raw(1),
        }
    }

    /// Copies the packet that OUT endpoint `i` holds into `bufs_out[i]` and returns its
    /// length, or null if EasyDMA did not finish.
    ///
    /// A driver may come for a packet after the bus was suspended. The peripheral is then
    /// woken for the copy, without a word to the host, and put back afterwards.
    fn easydma_out(self: *Self, i: u4) ?u32 {
        const was_enabled = cpu.interrupt.is_enabled(.USBD);
        defer if (was_enabled) cpu.interrupt.enable(.USBD);
        usbd_interrupt_off();

        // Neither SIZE.EPOUT[n] nor the task can be reached in low power mode (6.35.12).
        const was_low_power = self.low_power;
        if (was_low_power) self.leave_low_power();
        defer if (was_low_power) self.enter_low_power();

        const scratch_buf = &self.bufs_out[i];
        // SIZE.EPOUT[n] is a 7-bit field and can read up to 127; the buffer EasyDMA copies
        // into holds one 64-byte packet.
        const size: u32 = @min(peripherals.USBD.SIZE.EPOUT[i].raw, scratch_buf.len);

        // Prepare DMA transfer
        peripherals.USBD.EPOUT[i].PTR.write_raw(@intFromPtr(scratch_buf));
        peripherals.USBD.EPOUT[i].MAXCNT.write_raw(size);

        // An end event left by a transfer that was given up on must not end this wait.
        peripherals.USBD.EVENTS_ENDEPOUT[i].write_raw(0);
        return if (run_easydma(.out, i)) size else null;
    }

    fn ep_writev(
        itf: *usb.DeviceInterface,
        ep_num: usb.types.Endpoint.Num,
        data: []const []const u8,
    ) usb.types.Len {
        const self: *Self = @fieldParentPtr("interface", itf);
        log.debug("ep_writev {t}: ({} bytes) {X} ({s})", .{ ep_num, data[0].len, data[0], data[0] });

        // A zero-length write to EP0 accepts the request, with one exception: while a control
        // read still owes the host bytes of wLength, it is a packet of the data stage.
        // The controller sends one after a reply that ends on a full packet, to tell the host
        // that there is no more. That one goes out below like any other EP0 IN packet, with
        // MAXCNT 0, and being short it ends the data stage. TASKS_EP0STATUS instead would
        // leave the host's next IN token without the packet it is waiting for.
        //
        // Accepting a request starts its status stage, unless it is a control write whose
        // data the host has yet to send: then the data stage is let through, and `poll`
        // starts the status stage when the data has been taken (see `ep0.Control.ack`).
        const ep0_data_stage = ep_num == .ep0 and self.control.in_data_stage();
        if (data[0].len == 0 and !ep0_data_stage) {
            if (ep_num == .ep0) ep0_trigger(self.control.ack());
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

        // Start DMA
        const was_enabled = cpu.interrupt.is_enabled(.USBD);
        defer if (was_enabled) cpu.interrupt.enable(.USBD);
        usbd_interrupt_off();
        // A driver may write while the bus is suspended. The task that starts the copy
        // cannot be triggered in low power mode (6.35.12), so the peripheral is woken for
        // it, without a word to the host, and put back afterwards; the host finds the
        // packet when it resumes. Refusing the packet instead would break what drivers
        // rely on, that an idle endpoint takes a packet whole.
        const was_low_power = self.low_power;
        if (was_low_power) self.leave_low_power();
        defer if (was_low_power) self.enter_low_power();
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
        // An EP0 packet is not loaded if a SETUP packet has arrived since `poll` last looked,
        // while the controller was at work on the request before it or on that request's
        // EP0DATADONE. The packet belongs to the transfer the SETUP packet ended, and once
        // in the endpoint it would be the answer to the host's next IN token, which may be
        // one of the new transfer (see the EP0DATADONE branch of `poll`). The caller is told
        // that nothing was taken, the request stays as `self.control` has it, and the next
        // `poll` takes up the new transfer from its EP0SETUP. Like `ep0_trigger`: a SETUP
        // packet that arrives between this check and the write is not caught.
        if (ep_num == .ep0 and peripherals.USBD.EVENTS_EP0SETUP.raw != 0) {
            log.debug("ep_writev ep0: held back, a SETUP packet is waiting", .{});
            return 0;
        }
        if (!run_easydma(.in, i)) {
            log.err("ep_writev {t}: EasyDMA did not finish", .{ep_num});
            if (ep_num != .ep0) {
                self.in_busy[i] = false;
            } else {
                // No packet is in the endpoint, so none will be acknowledged and nothing
                // would move the control read on: it is stalled (see `ep0.Control.in_failed`).
                ep0_trigger(self.control.in_failed());
            }
            return 0;
        }

        if (ep_num == .ep0) {
            // A packet of a control read's data stage is in the endpoint; only now is it
            // counted, so that one that could not be loaded is not taken for an answer.
            // Every data stage ends on a packet that `in_packet` takes for the last: a
            // short one, the last byte of wLength, or the zero-length packet the controller
            // adds after a reply that is shorter than wLength and ends on a full packet.
            // When the host has acknowledged that one, `poll` starts the status stage. It
            // cannot run between the copy and this call: the USBD interrupt is still off.
            //
            // Nothing starts the status stage while a packet waits for the host. Until the
            // software has prepared the next stage the peripheral answers NAK (nRF52840 PS
            // v1.1, 6.35.9), and the specification offers no way to withdraw a packet or to
            // tell that the host has moved on; a host that gives up sends its next SETUP
            // packet, which ends the transfer.
            self.control.in_packet(len, self.eps_in[0].max_packet_size);
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
        const size = self.easydma_out(i) orelse {
            log.err("ep_readv {t}: EasyDMA did not finish", .{ep_num});
            return 0;
        };

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
                self.opened_in |= @intCast(mask);
                // A packet the earlier configuration sent must not be reported to this one.
                peripherals.USBD.EPDATASTATUS.write_raw(mask); // W1C, EPINn is bit n
                peripherals.USBD.EPINEN.write_raw(peripherals.USBD.EPINEN.raw | mask);
            },
            .out => {
                self.eps_out[i].max_packet_size = desc.max_packet_size.native();
                self.opened_out |= @intCast(mask);
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

    /// No-op: the peripheral handles this. It takes the address from the SET_ADDRESS
    /// transfer, which it also completes without the software (see `ep0.Control.set_address`).
    fn set_address(_: *usb.DeviceInterface, _: u7) void {}
};
