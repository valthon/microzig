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
const DMA = @import("./usbd/dma.zig");
const out_flow = @import("./usbd/out_flow.zig");

test {
    _ = ep0;
    _ = DMA;
    _ = out_flow;
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

/// How many times `leave_low_power` reads EVENTCAUSE for USBWUALLOWED before failing. Like `EASYDMA_WAIT_TURNS` a bound, not a timing figure: the product
/// specification says that the bit is set "upon writing the ForceNormal in register
/// LOWPOWER" (nRF52840 PS v1.1, 6.35.7.3) and gives no duration. `poll` never waits this
/// out: it does not call `leave_low_power`.
const WAKE_WAIT_TURNS: u32 = 1 << 20;

// EVENTCAUSE (nRF52840 PS v1.1, 6.35.13.25); every bit is cleared by writing 1 to it.
const CAUSE_SUSPEND: u32 = 1 << 8;
const CAUSE_RESUME: u32 = 1 << 9;
const CAUSE_USBWUALLOWED: u32 = 1 << 10;

// CLOCK's HFCLKSTAT (nRF52840 PS v1.1, 5.4.3.17): SRC = Xtal in bit 0, STATE = Running in
// bit 16.
const HFCLK_XTAL_RUNNING: u32 = 1 << 16 | 1 << 0;

const PowerState = union(enum) {
    detached,
    enabling,
    waiting_pwrrdy,
    connected,
};

const EP_Config = struct {
    max_packet_size: u16 = MAX_PACKET_SIZE,
};

/// The application starts the high frequency crystal oscillator before it calls `poll`,
/// with `clocks.hfxo.start()`, and keeps it running: "The USBD will not be able to respond
/// to USB traffic unless HFXO is enabled and stable" (nRF52840 PS v1.1, 6.35.7.1). The
/// same section allows it to be stopped "during the USB suspend, while the USB pull-up is
/// disconnected, or when VBUS is not present", and "software must explicitly enable it at
/// any other time". This HAL neither starts nor stops it (nrfx_usbd.c of nrfx v3.9.0 does
/// not touch the oscillator either); it logs a warning if the oscillator is not running
/// when it connects the pull-up.
pub const USBD = struct {
    const Self = @This();

    power: PowerState = .detached,
    configuration_generation: u32 = 0,
    /// A timed-out DMA still owns its buffer and anomaly 199 workaround. Only a system
    /// reset may recover this instance; no further peripheral tasks or buffer reuse.
    dma: DMA = .{},

    bufs_in: [NUM_EP][MAX_PACKET_SIZE]u8 align(4) = @splat(@splat(0)),
    bufs_out: [NUM_EP][MAX_PACKET_SIZE]u8 align(4) = @splat(@splat(0)),
    eps_in: [NUM_EP]EP_Config = @splat(.{}),
    eps_out: [NUM_EP]EP_Config = @splat(.{}),
    /// Where the control transfer on endpoint 0 stands.
    control: ep0.Control = .{},
    /// The length of the packet of a control write's data stage that `poll` copied into
    /// `bufs_out[0]` and told the controller of.
    control_out_len: u32 = 0,
    /// Data OUT packets are copied before notifying the driver, just like EP0.
    out_len: [NUM_EP]u32 = @splat(0),
    /// A packet was handed to data IN endpoint n and the host has not taken it yet.
    in_busy: [NUM_EP]bool = @splat(false),
    /// Accepted into bufs_in, but not loaded because waking timed out.
    in_pending: [NUM_EP]?usb.types.PacketLength = @splat(null),
    /// The bus is suspended and the peripheral has been put in its low power mode (see
    /// `enter_low_power`). Tasks and the registers of 6.35.12 are then out of reach. `poll`
    /// clears it when it sees the host on the bus again.
    low_power: bool = false,
    /// The data endpoints `ep_open` was called for since the last SETUP packet, bit n for
    /// endpoint n. After a SET_CONFIGURATION these are the endpoints of the configuration
    /// the host selected, and all others are disabled (see `poll`).
    opened_in: u8 = 0,
    opened_out: u8 = 0,
    /// Which packets on the data OUT endpoints the controller may be told of.
    out: out_flow.Flow = .{},

    interface: usb.DeviceInterface,

    pub const device_capabilities: usb.DeviceCapabilities = .{
        .max_supported_bcd_usb = .v1_10,
        .max_packet_size0 = MAX_PACKET_SIZE,
        .max_packet_size = MAX_PACKET_SIZE,
        .default_vendor = .{ .id = 0x1209, .str = "pid.codes" },
        .default_product = .{ .id = 0x0001, .str = "nRF5x test device" },
    };

    comptime {
        usb.validate_device(Self);
    }

    const vtable: usb.DeviceInterface.VTable = .{
        .ep_writev = ep_writev,
        .ep_readv = ep_readv,
        .ep_listen = ep_listen,
        .ep_open = ep_open,
        .ep_close_all = ep_close_all,
        .ep_set_stall = ep_set_stall,
        .set_address = set_address,
        // The data stage of a control write goes to the controller (see `poll`).
        .control_out_data = true,
    };

    /// Mask and clear the USBD interrupt in the NVIC: a bootloader may leave it enabled.
    /// An application using the USBD interrupt enables it after `init`.
    ///
    /// Nothing here touches USBPULLUP, EPINEN or EPOUTEN. They are among the registers that
    /// "cannot be accessed" while the peripheral "is not enabled (using the ENABLE register)
    /// and ready (signalled by the READY bit in EVENTCAUSE after a USBEVENT event)"
    /// (nRF52840 PS v1.1, 6.35.12), and it is disabled here. `poll` writes them when READY
    /// has come.
    pub fn init() Self {
        // The EasyDMA registers, against the register table (nRF52840 PS v1.1, 6.35.13). A
        // buffer pointer written anywhere else leaves the endpoint's real PTR as it was
        // found, and a transfer then copies to or from wherever that points. Host tests
        // run on a mock register block with its own layout.
        comptime if (!@import("builtin").is_test) {
            const Regs = @TypeOf(peripherals.USBD.*);
            std.debug.assert(@offsetOf(Regs, "EPIN") == 0x600);
            std.debug.assert(@offsetOf(Regs, "ISOIN") == 0x6A0);
            std.debug.assert(@offsetOf(Regs, "EPOUT") == 0x700);
            std.debug.assert(@offsetOf(Regs, "ISOOUT") == 0x7A0);
            std.debug.assert(@sizeOf(@TypeOf(peripherals.USBD.EPIN[0])) == 0x14);
            std.debug.assert(@sizeOf(@TypeOf(peripherals.USBD.EPOUT[0])) == 0x14);
        };

        cpu.interrupt.disable(.USBD);
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
        cpu.interrupt.clear_pending(.USBD);
        return .{
            .interface = .{ .vtable = &vtable },
        };
    }

    /// The pull-up is active and USB service has no latched EasyDMA fault.
    /// Check the controller separately for an active configuration.
    pub fn is_connected(self: *const Self) bool {
        return self.power == .connected and !self.dma.faulted;
    }

    /// Identifies the current endpoint lifetime. It changes on bus reset,
    /// detach, or when the controller closes the old configuration.
    pub fn get_configuration_generation(self: *const Self) u32 {
        return self.configuration_generation;
    }

    /// Run from foreground only: control OUT and controller callbacks perform synchronous
    /// EasyDMA and may wait up to EASYDMA_WAIT_TURNS (wake waits are bounded too).
    /// Calls from an ISR leave all events pending and do no work. If using the USBD IRQ
    /// to notify foreground, its handler must mask the IRQ and signal the main loop;
    /// foreground calls poll before re-enabling the IRQ. Poll regularly for power changes.
    pub fn poll(self: *Self, controller: anytype) void {
        comptime usb.validate_controller(@TypeOf(controller));
        if (cpu.executing_isr()) return;
        if (self.dma.faulted) return;

        if (self.power != .detached and peripherals.POWER.USBREGSTATUS.read().VBUSDETECT == .NoVbus) {
            self.teardown();
            self.power = .detached;
            self.configuration_generation +%= 1;
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
                    // The host is about to talk to a device that cannot answer.
                    if (peripherals.CLOCK.HFCLKSTAT.raw & HFCLK_XTAL_RUNNING != HFCLK_XTAL_RUNNING)
                        log.warn("the crystal oscillator (HFXO) is not running: start it before USB", .{});
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
                // words "while the USB bus is suspended" above. Two sentences read the
                // other way. The product specification
                // says of the value ForceNormal of LOWPOWER: "Software must write this value
                // to exit low power mode and before performing a remote wake-up"
                // (6.35.13.50). nrfx's header says of the write that the event "will be
                // generated and then the USBD registers can be accessed" (hal/nrf_usbd.h,
                // lines 1023-1025, on `nrf_usbd_lowpower_disable`).
                //
                // Hardware evidence settles the host-initiated case here. On a Seeed XIAO
                // nRF52840 (S140 7.3.0, Adafruit UF2 bootloader 0.6.1) running a CDC
                // loopback on Windows, a version of this code that wrote ForceNormal and
                // waited for USBWUALLOWED on host activity did not enumerate ("Unknown
                // USB Device (Device Descriptor Request Failed)"); this nrfx-style code
                // enumerates and passes the loopback. A missing USBWUALLOWED after the
                // hardware already left low power on bus activity is a possible
                // mechanism, not an observed one.
                //
                // USBEVENT is cleared here because the return below comes before the place
                // where it is cleared otherwise. A driver's write during the suspend leaves
                // it set (the ForceNormal of `leave_low_power` raises it), so a USBD IRQ
                // handler that signals foreground would be notified repeatedly for as
                // long as the bus is suspended. It is cleared
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
                    self.configuration_generation +%= 1;
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
                    if (self.dma.faulted) return;
                    // The controller answers a request before it returns, or not at all.
                    self.ep0_trigger(self.control.setup_handled());

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
                            if (self.opened_in >> @intCast(i) & 1 == 0) {
                                self.in_busy[i] = false;
                                self.in_pending[i] = null;
                            }
                            if (self.opened_out >> @intCast(i) & 1 == 0) self.out.forget(@intCast(i));
                        }
                    }
                }

                // A wake timeout left these packets in HAL RAM. Host activity above has
                // restored register access; load them before reporting any completions.
                for (1..NUM_EP) |i| {
                    if (self.in_pending[i]) |len| {
                        if (!self.load_in(@intCast(i), len)) return;
                        self.in_pending[i] = null;
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
                            self.ep0_trigger(self.control.in_done());
                            controller.on_buffer(&self.interface, .in(.ep0));
                            if (self.dma.faulted) return;
                        },
                        // A packet of a control write's data stage is in the endpoint.
                        // Outside a data stage nothing let a packet in, so none is taken.
                        //
                        // The packet is taken out before anything else may follow: "The
                        // software can then either prepare to receive the next data
                        // transaction [...] or initiate the status stage through the
                        // EP0STATUS task" once ENDEPOUT[0] has come (nRF52840 PS v1.1,
                        // 6.35.9.2). If the copy does not end, USBD is quarantined and
                        // the controller hears nothing: a packet it were told of and then
                        // could not read would look to it like an empty one, which ends
                        // the data stage and goes to the driver.
                        .out => if (self.control.out_data_stage()) {
                            if (self.easydma_out(0)) |size| {
                                if (self.control.deliver) {
                                    // The controller listened for it. It reads the packet
                                    // (`ep_readv`) and asks for the next one or for the
                                    // status stage; if it does neither, the request is
                                    // stalled.
                                    self.control_out_len = size;
                                    self.control.out_arrived();
                                    controller.on_buffer(&self.interface, .out(.ep0));
                                    self.ep0_trigger(self.control.out_handled());
                                } else {
                                    // The controller accepted the request unseen and is
                                    // not told of its data.
                                    self.ep0_trigger(self.control.out_packet(@intCast(size), self.eps_out[0].max_packet_size));
                                }
                            } else {
                                log.err("EP0: EasyDMA timeout, system reset required", .{});
                                self.ep0_trigger(self.control.out_failed());
                                if (self.dma.faulted) return;
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
                            if (self.dma.faulted) return;
                        }
                        status_in >>= 1;
                    }
                    // OUT endpoints (bits 17-23): the packet is noted, and reported below.
                    var status_out = status >> 17;
                    for (1..8) |i| {
                        if (status_out == 0) break;
                        if (status_out & 1 == 1) self.out.arrived(@intCast(i));
                        status_out >>= 1;
                    }
                }

                // A received packet is reported when the driver listens, which may be long
                // after it arrived (see out_flow.zig), so this is looked at on every call.
                inline for (1..8) |i| {
                    if (self.out.waiting[i] and self.out.listening[i]) {
                        self.out_len[i] = self.easydma_out(i) orelse return;
                        std.debug.assert(self.out.report(i));
                        controller.on_buffer(&self.interface, .out(@fromBackingInt(i)));
                        if (self.dma.faulted) return;
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
        self.interface.halted = .{};
        self.interface.opened = .{};

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
        if (self.dma.faulted) return;
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

    /// ForceNormal must establish readiness before accessing the restricted registers or
    /// starting DMA (nRF52840 PS v1.1, 6.35.7.3, 6.35.12 and 6.35.13.25).
    /// A timeout retains the conservative software low-power state and returns failure;
    /// callers may retry, but must not touch those registers or start a transfer.
    fn leave_low_power(self: *Self) bool {
        errata.pre_wakeup();
        defer errata.post_wakeup();
        // A bit left by an earlier ForceNormal must not end this wait.
        peripherals.USBD.EVENTCAUSE.write_raw(CAUSE_USBWUALLOWED); // W1C
        force_normal();
        var turns: u32 = 0;
        while (turns < WAKE_WAIT_TURNS) : (turns += 1) {
            if (peripherals.USBD.EVENTCAUSE.raw & CAUSE_USBWUALLOWED != 0) {
                peripherals.USBD.EVENTCAUSE.write_raw(CAUSE_USBWUALLOWED); // W1C
                self.low_power = false;
                return true;
            }
        }
        log.warn("USBWUALLOWED did not come after leaving low power mode", .{});
        return false;
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
        self.in_pending = @splat(null);
        self.opened_in = 0;
        self.opened_out = 0;
        self.out = .{};
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
    /// nRF52840 Revision 3 Errata, anomaly 199, Workaround: clear only after DMA
    /// completion. nRF52840 PS v1.1, USBD, "EasyDMA" allows one transfer at a time.
    /// On timeout quarantine the instance, its buffers and the workaround until system
    /// reset. Returning an error must not make a possibly active DMA's buffer reusable.
    fn run_easydma(self: *Self, dir: usb.types.Dir, i: u4) bool {
        var io: DMA_IO = .{ .dir = dir, .i = i };
        return self.dma.run(&io);
    }

    const DMA_IO = struct {
        dir: usb.types.Dir,
        i: u4,

        pub fn begin(_: *@This()) void {
            errata.dma_begin();
        }
        pub fn start(io: *@This()) void {
            switch (io.dir) {
                .in => peripherals.USBD.TASKS_STARTEPIN[io.i].write_raw(1),
                .out => peripherals.USBD.TASKS_STARTEPOUT[io.i].write_raw(1),
            }
        }
        pub fn wait(io: *@This()) bool {
            return wait_easydma(io.dir, io.i);
        }
        pub fn end(_: *@This()) void {
            errata.dma_end();
        }
    };

    /// Mask the USBD notification IRQ while manipulating endpoint ownership. Foreground
    /// callers restore its previous enable state; the ISR only signals foreground work.
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
    /// next `poll` takes that transfer up from its EP0SETUP. The USBD IRQ is masked by
    /// foreground callers, but this cannot stop bus traffic. nRF52840 PS v1.1, 6.35.9
    /// provides no atomic SETUP-generation check plus task. A SETUP arriving between
    /// the check and the task still needs board investigation.
    fn ep0_trigger(self: *Self, action: ep0.Action) void {
        if (self.dma.faulted) return;
        if (action == .none or peripherals.USBD.EVENTS_EP0SETUP.raw != 0 or
            peripherals.USBD.EVENTS_USBRESET.raw != 0) return;
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
        defer if (was_enabled and !self.dma.faulted) cpu.interrupt.enable(.USBD);
        usbd_interrupt_off();

        // Neither SIZE.EPOUT[n] nor the task can be reached in low power mode (6.35.12).
        const was_low_power = self.low_power;
        if (was_low_power and !self.leave_low_power()) return null;
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
        return if (self.run_easydma(.out, i)) size else null;
    }

    /// The length of the packet of a control write's data stage that `poll` told the
    /// controller of, which is in `bufs_out[0]`. Null if there is none, or if it was taken
    /// before: a packet is handed out once. Nothing is copied here, so nothing can fail:
    /// `poll` took the packet out of the endpoint before it reported it.
    fn ep0_take(self: *Self) ?u32 {
        if (!self.control.out_take()) return null;
        self.control.out_read(@intCast(self.control_out_len), self.eps_out[0].max_packet_size);
        return self.control_out_len;
    }

    fn ep_writev(
        itf: *usb.DeviceInterface,
        ep_num: usb.types.Endpoint.Num,
        data: []const []const u8,
    ) usb.types.PacketLength {
        const self: *Self = @fieldParentPtr("interface", itf);
        const was_enabled = cpu.interrupt.is_enabled(.USBD);
        defer if (was_enabled and !self.dma.faulted) cpu.interrupt.enable(.USBD);
        usbd_interrupt_off();
        if (self.dma.faulted) return 0;
        // A pending reset/reconfiguration invalidates the caller's endpoint state.
        // nRF52840 PS v1.1, USBD, "Bulk and interrupt transactions":
        // a bus reset disables the data endpoints.
        if (peripherals.USBD.EVENTS_USBRESET.raw != 0) return 0;

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
        //
        // On a data endpoint a zero-length write is a zero-length packet, which ends a
        // transfer whose last packet was full (USB 2.0, 5.8.3). It is loaded below with
        // MAXCNT 0 and reported through `on_buffer` when the host has taken it, like any
        // other packet. Its return value is 0 either way: a caller cannot tell from it
        // whether the packet was taken or the endpoint was busy.
        if (ep_num == .ep0 and data[0].len == 0 and !self.control.in_data_stage()) {
            // A packet the controller was told of and did not read is passed over.
            _ = self.ep0_take();
            self.ep0_trigger(self.control.ack());
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

        const len: usb.types.PacketLength = @intCast(scratch_cap - scratch_slice.len);

        // A driver may write while the bus is suspended. The task that starts the copy
        // cannot be triggered in low power mode (6.35.12), so the peripheral is woken for
        // it, without a word to the host, and put back afterwards; the host finds the
        // packet when it resumes. Refusing the packet instead would break what drivers
        // rely on, that an idle endpoint takes a packet whole.
        const was_low_power = self.low_power;
        if (was_low_power and !self.leave_low_power()) {
            if (ep_num == .ep0) return 0;
            // Idle IN must accept a whole packet (DeviceInterface.ep_open). Keep
            // ownership in HAL RAM until poll can load it after host activity.
            self.in_pending[i] = len;
            self.in_busy[i] = true;
            return len;
        }
        defer if (was_low_power) self.enter_low_power();
        if (peripherals.USBD.EVENTS_USBRESET.raw != 0) return 0;
        if (ep_num != .ep0 and peripherals.USBD.EPINEN.raw &
            (@as(u32, 1) << @backingInt(ep_num)) == 0) return 0;
        if (!self.load_in(i, len)) return 0;

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

    fn load_in(self: *Self, i: u4, len: usb.types.PacketLength) bool {
        // Prepare DMA transfer
        peripherals.USBD.EPIN[i].PTR.write_raw(@intFromPtr(&self.bufs_in[i]));
        peripherals.USBD.EPIN[i].MAXCNT.write_raw(len);

        // An end event left by a transfer that was given up on must not end this wait.
        peripherals.USBD.EVENTS_ENDEPIN[i].write_raw(0);
        // ep_open disarmed the preceding packet before releasing ownership. Clear any
        // latched completion before publishing this packet (EPDATASTATUS is W1C;
        // nRF52840 PS v1.1, USBD, EPDATASTATUS).
        if (i != 0) peripherals.USBD.EPDATASTATUS.write_raw(@as(u32, 1) << i);
        // Busy from before the transfer starts: the host can take the packet as soon as it
        // is in the endpoint. Publish ownership before starting the task; foreground
        // `poll` will clear it when it observes the host's completion.
        if (i != 0) self.in_busy[i] = true;
        // An EP0 packet is not loaded if a SETUP packet has arrived since `poll` last looked,
        // while the controller was at work on the request before it or on that request's
        // EP0DATADONE. The packet belongs to the transfer the SETUP packet ended, and once
        // in the endpoint it would be the answer to the host's next IN token, which may be
        // one of the new transfer (see the EP0DATADONE branch of `poll`). The caller is told
        // that nothing was taken, the request stays as `self.control` has it, and the next
        // `poll` takes up the new transfer from its EP0SETUP. Like `ep0_trigger`: a SETUP
        // packet that arrives between this check and the write is not caught.
        if (i == 0 and peripherals.USBD.EVENTS_EP0SETUP.raw != 0) {
            log.debug("ep_writev ep0: held back, a SETUP packet is waiting", .{});
            return false;
        }
        if (!self.run_easydma(.in, i)) {
            log.err("USBD EasyDMA timeout: system reset required", .{});
            return false;
        }

        return true;
    }

    fn ep_readv(
        itf: *usb.DeviceInterface,
        ep_num: usb.types.Endpoint.Num,
        data: []const []u8,
    ) usb.types.PacketLength {
        var total_len: usize = data[0].len;
        for (data[1..]) |d| total_len += d.len;
        log.debug("ep_readv {t}: ({} bytes)", .{ ep_num, total_len });

        const self: *Self = @fieldParentPtr("interface", itf);
        const was_enabled = cpu.interrupt.is_enabled(.USBD);
        defer if (was_enabled and !self.dma.faulted) cpu.interrupt.enable(.USBD);
        usbd_interrupt_off();
        if (self.dma.faulted) return 0;
        const i = @backingInt(ep_num);
        const scratch_buf = &self.bufs_out[i];
        // On endpoint 0 there is a packet only when `poll` has just reported one.
        const size = if (ep_num == .ep0)
            self.ep0_take() orelse return 0
        else
            self.out_len[i];

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

    /// On a data endpoint this lets `poll` report the next packet, and that is all: the
    /// endpoint takes a packet whenever it is empty (see out_flow.zig).
    fn ep_listen(
        itf: *usb.DeviceInterface,
        ep_num: usb.types.Endpoint.Num,
        len: usb.types.PacketLength,
    ) void {
        const self: *Self = @fieldParentPtr("interface", itf);
        const was_enabled = cpu.interrupt.is_enabled(.USBD);
        defer if (was_enabled and !self.dma.faulted) cpu.interrupt.enable(.USBD);
        usbd_interrupt_off();
        if (self.dma.faulted) return;
        log.debug("ep_listen {t}: ({} bytes)", .{ ep_num, len });

        if (ep_num == .ep0) {
            // The controller wants the next packet of a control write's data stage (see
            // `VTable.control_out_data` in core/usb.zig). One it did not read is passed
            // over; outside such a data stage nothing is let in.
            _ = self.ep0_take();
            self.ep0_trigger(self.control.listen());
            return;
        }
        // A packet that is waiting already raised its event long ago. An application that
        // uses the USBD interrupt to notify foreground would not hear of it until some
        // other event came, so pend that notification using the saved enable state.
        // With the IRQ disabled, foreground polling finds it on the next turn.
        if (self.out.listen(@intCast(@backingInt(ep_num))) and was_enabled)
            cpu.interrupt.set_pending(.USBD);
    }

    // mdk/nrf52840_bitfields.h: USBD_EPSTALL_IO_Pos and USBD_DTOGGLE_IO_Pos
    // share the same position. Both registers put EP at bit 0.
    const endpoint_io_pos = 7;
    // mdk/nrf52840_bitfields.h: USBD_DTOGGLE_VALUE_Pos and USBD_DTOGGLE_VALUE_Data0.
    const dtoggle_data0 = @as(u32, 1) << 8;
    // mdk/nrf52840_bitfields.h: USBD_EPSTALL_STALL_Pos.
    const epstall_stall_pos = 8;
    // mdk/nrf52840_bitfields.h: USBD_HALTED_EPOUT_GETSTATUS_Halted.
    const epout_halted = 1;

    fn select_endpoint(ep: usb.types.Endpoint) u32 {
        return @as(u32, @backingInt(ep.num)) | (@as(u32, @backingInt(ep.dir)) << endpoint_io_pos);
    }

    fn reset_data_toggle(ep: usb.types.Endpoint) void {
        // nRF52840 PS, USBD, "Bulk and interrupt transactions". Select the
        // endpoint with Nop first, as nrfx's nrf_usbd_dtoggle_set does.
        const select = select_endpoint(ep);
        peripherals.USBD.DTOGGLE.write_raw(select);
        peripherals.USBD.DTOGGLE.write_raw(select | dtoggle_data0);
    }

    fn write_endpoint_stall(ep: usb.types.Endpoint, stalled: bool) void {
        // nRF52840 PS, USBD, "Bulk and interrupt transactions" (EPSTALL).
        peripherals.USBD.EPSTALL.write_raw(select_endpoint(ep) | (@as(u32, @intFromBool(stalled)) << epstall_stall_pos));
    }

    fn ep_set_stall(itf: *usb.DeviceInterface, ep: usb.types.Endpoint, stalled: bool) usb.DeviceInterface.StallError!void {
        const self: *Self = @fieldParentPtr("interface", itf);
        const was_enabled = cpu.interrupt.is_enabled(.USBD);
        defer if (was_enabled and !self.dma.faulted) cpu.interrupt.enable(.USBD);
        usbd_interrupt_off();
        if (self.dma.faulted or peripherals.USBD.EVENTS_USBRESET.raw != 0)
            return error.Unavailable;

        if (stalled) {
            // EPSTALL cannot be written in low power mode (nRF52840 PS, USBD, "USB register
            // access limitations"), so wake the peripheral first, as a class write does.
            const was_low_power = self.low_power;
            if (was_low_power and !self.leave_low_power()) return error.Timeout;
            if (peripherals.USBD.EVENTS_USBRESET.raw != 0) return error.Unavailable;
            write_endpoint_stall(ep, true);
            if (was_low_power and !bus_active()) self.enter_low_power();
            return;
        }

        // Host CLEAR_FEATURE arrives in SETUP, after poll has left low power.
        std.debug.assert(!self.low_power);
        const i = @backingInt(ep.num);
        const out_status = @as(u32, 1) << @intCast(16 + @as(u5, i)); // EPDATASTATUS.EPOUTn is bit 16+n
        if (ep.dir == .out and peripherals.USBD.HALTED.EPOUT[i].raw & epout_halted != 0 and
            !self.out.waiting[i] and peripherals.USBD.EPDATASTATUS.raw & out_status == 0)
        {
            // nRF52840 PS, USBD, "Bulk and interrupt transactions" (SIZE, EPDATASTATUS).
            // Release an empty OUT slot before unstalling, as in nrfx_usbd_ep_stall_clear.
            peripherals.USBD.SIZE.EPOUT[i].write_raw(0);
        }
        reset_data_toggle(ep);
        write_endpoint_stall(ep, false);
    }

    fn ep_open(itf: *usb.DeviceInterface, desc: *const usb.descriptor.Endpoint) void {
        const self: *Self = @fieldParentPtr("interface", itf);
        // Configuration init opens endpoints after poll has left low power for SETUP or reset.
        std.debug.assert(!self.low_power);
        const was_enabled = cpu.interrupt.is_enabled(.USBD);
        defer if (was_enabled and !self.dma.faulted) cpu.interrupt.enable(.USBD);
        usbd_interrupt_off();
        if (self.dma.faulted) return;

        const ep = desc.endpoint;
        const i = @backingInt(ep.num);
        const mask: u32 = @as(u32, 1) << i;

        // The endpoint may have been open in an earlier configuration (see `ep_open` in
        // core/usb.zig), and enabling an endpoint that is already enabled changes nothing,
        // so what that configuration left behind is undone here.
        if (ep.num != .ep0) {
            // Both sides start a configuration at DATA0 (USB 2.0, 9.1.1.5).
            reset_data_toggle(ep);
        }
        switch (ep.dir) {
            .in => {
                // Withdraw the old packet before clearing its completion/ownership.
                if (ep.num != .ep0) errata.disarm_in(@intCast(i));
                self.eps_in[i].max_packet_size = desc.max_packet_size.native();
                self.in_busy[i] = false;
                self.in_pending[i] = null;
                self.opened_in |= @intCast(mask);
                // A packet the earlier configuration sent must not be reported to this one.
                peripherals.USBD.EPDATASTATUS.write_raw(mask); // W1C, EPINn is bit n
                peripherals.USBD.EPINEN.write_raw(peripherals.USBD.EPINEN.raw | mask);
            },
            .out => {
                self.eps_out[i].max_packet_size = desc.max_packet_size.native();
                self.opened_out |= @intCast(mask);
                if (ep.num != .ep0) self.out.forget(@intCast(i));
                peripherals.USBD.EPOUTEN.write_raw(peripherals.USBD.EPOUTEN.raw | mask);
                // Nor one it received and never read. Dropping the report alone would leave
                // the endpoint answering NAK for good: "a NAK is returned until the software
                // writes any value to register SIZE.EPOUT[n]" (nRF52840 PS, USBD, "Bulk and
                // interrupt OUT transaction"). nrfx's `nrfx_usbd_ep_enable` does the same.
                peripherals.USBD.EPDATASTATUS.write_raw(mask << 16); // W1C, EPOUTn is bit 16+n
                if (ep.num != .ep0) peripherals.USBD.SIZE.EPOUT[i].write_raw(0);
            },
        }
        if (ep.num != .ep0) write_endpoint_stall(ep, false);

        const attr = desc.attributes;
        log.debug(
            "ep_open {t} {t}: {{ type: {t}, sync: {t}, usage: {t}, size: {} }}",
            .{ ep.num, ep.dir, attr.transfer_type, attr.synchronisation, attr.usage, desc.max_packet_size.native() },
        );
    }

    fn ep_close_all(itf: *usb.DeviceInterface) void {
        const self: *Self = @fieldParentPtr("interface", itf);
        // The controller is discarding its active runtime, even if EP0 did
        // not recognize the request or the hardware can no longer be used.
        self.configuration_generation +%= 1;
        const was_enabled = cpu.interrupt.is_enabled(.USBD);
        defer if (was_enabled and !self.dma.faulted) cpu.interrupt.enable(.USBD);
        usbd_interrupt_off();
        if (self.dma.faulted) return;
        // nRF52840 PS v1.1, USBD, "Bulk and interrupt transactions": disabled
        // endpoints do not respond. Disarm via the approved nrfx sequence as well.
        peripherals.USBD.EPINEN.write_raw(1);
        peripherals.USBD.EPOUTEN.write_raw(1);
        for (1..NUM_EP) |i| {
            errata.disarm_in(@intCast(i));
            const num: usb.types.Endpoint.Num = @fromBackingInt(@as(u4, @intCast(i)));
            for ([_]usb.types.Endpoint{ .in(num), .out(num) }) |ep| {
                if (itf.halted.contains(ep)) write_endpoint_stall(ep, false);
            }
        }
        peripherals.USBD.EPDATASTATUS.write_raw(0xFFFEFFFE);
        self.in_busy = @splat(false);
        self.in_pending = @splat(null);
        self.out = .{};
    }

    /// No-op: the peripheral handles this. It takes the address from the SET_ADDRESS
    /// transfer, which it also completes without the software (see `ep0.Control.set_address`).
    fn set_address(_: *usb.DeviceInterface, _: u7) void {}
};

pub const testing = if (@import("builtin").is_test) struct {
    const cdc_desc = blk: {
        var alloc: usb.DescriptorAllocator = .init(false, &.{});
        break :blk (usb.drivers.CDC{}).driver_info(.{ .max_packet_size0 = 64, .max_packet_size = 64 }, &alloc).descriptor;
    };
    const CDC_Controller = struct {
        cdc: usb.drivers.CDC.Runtime = undefined,
        pub fn on_bus_reset(_: *@This(), _: *usb.DeviceInterface) void {}
        pub fn on_setup_req(_: *@This(), _: *usb.DeviceInterface, _: *const usb.types.SetupPacket) void {}
        pub fn on_buffer(ctl: *@This(), _: *usb.DeviceInterface, comptime ep: usb.types.Endpoint) void {
            if (ep == cdc_desc.ep_out.endpoint) ctl.cdc.on_rx(ep.num);
            if (ep == cdc_desc.ep_in.endpoint) ctl.cdc.on_tx_ready(ep.num);
        }
    };
    pub fn cdc_out_suspend() !void {
        const io = microzig.testing_io;
        io.reset();
        io.dma_ready = true;
        io.out_packet = "pending OUT";
        var dev: USBD = .{ .interface = .{ .vtable = &USBD.vtable }, .power = .connected };
        var ctl: CDC_Controller = .{};
        var storage: [128]u8 = undefined;
        ctl.cdc.init(.{}, &cdc_desc, &dev.interface, &storage);
        const n = @backingInt(cdc_desc.ep_out.endpoint.num);
        peripherals.USBD.SIZE.EPOUT[n].raw = @intCast(io.out_packet.len);
        dev.out.arrived(n);
        dev.poll(&ctl);
        try std.testing.expect(ctl.cdc.rx_ready.load(.seq_cst));
        // Suspend between notification and CDC's foreground read; no wake answer.
        dev.low_power = true;
        var received: [64]u8 = undefined;
        try std.testing.expectEqual(0, ctl.cdc.read(&received));
        const len = ctl.cdc.read(&received);
        try std.testing.expectEqualSlices(u8, io.out_packet, received[0..len]);
        try std.testing.expect(!dev.dma.faulted);
        try std.testing.expectEqual(0, io.force_normal_writes);
        // The next packet can notify CDC after the host resumes.
        peripherals.USBD.EVENTCAUSE.raw = CAUSE_RESUME;
        dev.out.arrived(n);
        dev.poll(&ctl);
        try std.testing.expect(ctl.cdc.rx_ready.load(.seq_cst));
    }
    pub fn cdc_in_wake_timeout() !void {
        const io = microzig.testing_io;
        // A short and a full packet: either is sent whole once the wake succeeds. (The
        // later write of "x" cancels the full packet's ZLP, so no ZLP is checked here.)
        for ([_]usize{ 11, 64 }) |len| {
            io.reset();
            var dev: USBD = .{ .interface = .{ .vtable = &USBD.vtable }, .power = .connected, .low_power = true };
            var ctl: CDC_Controller = .{};
            var storage: [128]u8 = undefined;
            ctl.cdc.init(.{}, &cdc_desc, &dev.interface, &storage);
            const n = @backingInt(cdc_desc.ep_in.endpoint.num);
            peripherals.USBD.EPINEN.raw = @as(u32, 1) << n;
            const payload: [64]u8 = @splat(0x5a);
            try std.testing.expectEqual(len, ctl.cdc.write(payload[0..len]));
            try std.testing.expect(ctl.cdc.flush());
            try std.testing.expect(dev.in_busy[n]);
            try std.testing.expect(!ctl.cdc.tx_ready.load(.seq_cst));
            try std.testing.expectEqual(0, peripherals.USBD.TASKS_STARTEPIN[n].raw);
            // A second packet cannot overwrite the accepted one while suspended.
            try std.testing.expectEqual(1, ctl.cdc.write("x"));
            try std.testing.expect(!ctl.cdc.flush());
            io.dma_ready = true;
            peripherals.USBD.EVENTCAUSE.raw = CAUSE_RESUME;
            dev.poll(&ctl);
            try std.testing.expectEqualSlices(u8, payload[0..len], io.in_packet[0..io.in_len]);
            try std.testing.expectEqual(@as(?usb.types.PacketLength, null), dev.in_pending[n]);
            peripherals.USBD.EVENTS_EPDATA.raw = 1;
            peripherals.USBD.EPDATASTATUS.raw = @as(u32, 1) << n;
            dev.poll(&ctl);
            try std.testing.expect(ctl.cdc.tx_ready.load(.seq_cst));
            try std.testing.expect(ctl.cdc.flush());
            try std.testing.expectEqualSlices(u8, "x", io.in_packet[0..io.in_len]);
            try std.testing.expect(!dev.dma.faulted);
        }
    }
    pub fn init_interrupt() !void {
        const io = microzig.testing_io;
        io.reset();
        io.irq_enabled = true;
        io.irq_pending = true;
        var dev = USBD.init();
        try std.testing.expect(!io.irq_enabled);
        try std.testing.expect(!io.irq_pending);

        dev.out.arrived(1);
        USBD.ep_listen(&dev.interface, .ep1, 64);
        try std.testing.expect(!io.irq_pending);
        try std.testing.expect(!io.irq_enabled);
        try std.testing.expect(dev.out.report(1));
    }
    pub fn late_listen() !void {
        const io = microzig.testing_io;
        io.reset();
        var dev: USBD = .{ .interface = .{ .vtable = &USBD.vtable } };
        dev.out.arrived(1);
        io.irq_enabled = true;
        USBD.ep_listen(&dev.interface, .ep1, 64);
        try std.testing.expect(io.irq_pending);
        try std.testing.expect(io.irq_enabled);
        try std.testing.expect(dev.out.report(1));
        io.irq_pending = false;
        io.irq_enabled = false;
        dev.out.arrived(1);
        USBD.ep_listen(&dev.interface, .ep1, 64);
        try std.testing.expect(!io.irq_pending);
        try std.testing.expect(dev.out.report(1));
    }
    pub fn wake_timeout() !void {
        const io = microzig.testing_io;
        io.reset();
        var dev: USBD = .{ .interface = .{ .vtable = &USBD.vtable }, .low_power = true };
        // A stale readiness bit must not authorize this wake.
        peripherals.USBD.EVENTCAUSE.raw = CAUSE_USBWUALLOWED;
        try std.testing.expectEqual(null, dev.easydma_out(1));
        try std.testing.expect(dev.low_power);
        try std.testing.expect(!dev.dma.faulted);
        try std.testing.expectEqual(0, peripherals.USBD.EPOUT[1].PTR.raw);
        try std.testing.expectEqual(0, peripherals.USBD.TASKS_STARTEPOUT[1].raw);
        peripherals.USBD.EPINEN.raw = 2;
        try std.testing.expectEqual(6, USBD.ep_writev(&dev.interface, .ep1, &.{"packet"}));
        try std.testing.expect(dev.low_power);
        try std.testing.expect(!dev.dma.faulted);
        try std.testing.expect(dev.in_busy[1]);
        try std.testing.expectEqual(@as(?usb.types.PacketLength, 6), dev.in_pending[1]);
        try std.testing.expectEqual(0, peripherals.USBD.EPIN[1].PTR.raw);
        try std.testing.expectEqual(0, peripherals.USBD.TASKS_STARTEPIN[1].raw);
        // A later successful wake can still establish readiness, without quarantine.
        io.wake_ready = true;
        try std.testing.expect(dev.leave_low_power());
        try std.testing.expect(!dev.low_power);
        try std.testing.expectEqual(0, peripherals.USBD.EVENTCAUSE.raw & CAUSE_USBWUALLOWED);
    }
    pub fn host_activity() !void {
        const io = microzig.testing_io;
        const Controller = struct {
            resets: usize = 0,
            setups: usize = 0,
            pub fn on_bus_reset(ctl: *@This(), _: *usb.DeviceInterface) void {
                ctl.resets += 1;
            }
            pub fn on_setup_req(ctl: *@This(), _: *usb.DeviceInterface, setup: *const usb.types.SetupPacket) void {
                std.debug.assert(setup.request == 0x42);
                ctl.setups += 1;
            }
            pub fn on_buffer(_: *@This(), _: *usb.DeviceInterface, comptime _: usb.types.Endpoint) void {}
        };
        // No USBWUALLOWED is supplied: host activity must clear the software suspend
        // state and dispatch reset/SETUP immediately. Only combined causes write
        // ForceNormal, without waiting for its answer.
        for (0..4) |event| {
            io.reset();
            var dev: USBD = .{ .interface = .{ .vtable = &USBD.vtable }, .power = .connected, .low_power = true };
            var ctl: Controller = .{};
            switch (event) {
                0 => peripherals.USBD.EVENTCAUSE.raw = CAUSE_RESUME,
                1 => peripherals.USBD.EVENTS_USBRESET.raw = 1,
                2 => {
                    peripherals.USBD.EVENTS_EP0SETUP.raw = 1;
                    peripherals.USBD.BREQUEST.raw = 0x42;
                },
                3 => peripherals.USBD.EVENTCAUSE.raw = CAUSE_SUSPEND | CAUSE_RESUME,
                else => unreachable,
            }
            dev.poll(&ctl);
            try std.testing.expect(!dev.low_power);
            try std.testing.expectEqual(@as(usize, if (event == 3) 1 else 0), io.force_normal_writes);
            try std.testing.expect(!dev.dma.faulted);
            try std.testing.expectEqual(@as(usize, if (event == 1) 1 else 0), ctl.resets);
            try std.testing.expectEqual(@as(usize, if (event == 2) 1 else 0), ctl.setups);
            try std.testing.expectEqual(0, peripherals.USBD.EVENTS_USBRESET.raw);
            try std.testing.expectEqual(0, peripherals.USBD.EVENTS_EP0SETUP.raw);
            try std.testing.expectEqual(0, peripherals.USBD.EVENTCAUSE.raw & CAUSE_USBWUALLOWED);
        }
    }

    pub fn halt_out_clear() !void {
        microzig.testing_io.reset();
        const regs = peripherals.USBD;
        const ep: usb.types.Endpoint = .out(.ep2);
        var dev: USBD = .{ .interface = .{ .vtable = &USBD.vtable }, .power = .connected };
        dev.interface.opened.set(ep, true);
        _ = dev.out.listen(2);

        // Empty stalled slot, arrived but unprocessed event, waiting packet, then
        // unconditional toggle reset on an endpoint that was never stalled.
        for (0..4) |scenario| {
            if (scenario != 3) {
                try dev.interface.ep_halt(ep);
                try std.testing.expectEqual(0x102, regs.EPSTALL.raw);
            }
            dev.out.waiting[2] = scenario == 2;
            regs.EPDATASTATUS.raw = if (scenario == 1) 1 << 18 else 0;
            regs.SIZE.EPOUT[2].raw = 7;
            regs.DTOGGLE.raw = 0;
            regs.EPSTALL.raw = 0;
            microzig.testing_io.toggle_at_stall_write = 0;
            const stall_writes = microzig.testing_io.stall_writes;
            try USBD.ep_set_stall(&dev.interface, ep, false);
            // Each clear writes DTOGGLE and EPSTALL afresh, halted or not.
            try std.testing.expectEqual(stall_writes + 1, microzig.testing_io.stall_writes);
            try std.testing.expectEqual(0x102, regs.DTOGGLE.raw);
            try std.testing.expectEqual(0x002, regs.EPSTALL.raw);
            try std.testing.expectEqual(0x102, microzig.testing_io.toggle_at_stall_write);
            try std.testing.expectEqual(@as(u32, if (scenario == 0) 0 else 7), microzig.testing_io.out_size_at_stall_write);
            try std.testing.expectEqual(scenario == 2, dev.out.waiting[2]);
            try std.testing.expectEqual(@as(u32, if (scenario == 1) 1 << 18 else 0), regs.EPDATASTATUS.raw);
            try std.testing.expect(dev.out.listening[2]);
            dev.interface.halted.set(ep, false);
        }
    }

    pub fn halt_in_clear() !void {
        microzig.testing_io.reset();
        const regs = peripherals.USBD;
        const ep: usb.types.Endpoint = .in(.ep2);
        var dev: USBD = .{ .interface = .{ .vtable = &USBD.vtable }, .power = .connected };
        dev.interface.opened.set(ep, true);
        dev.in_busy[2] = true;
        try dev.interface.ep_halt(ep);
        try std.testing.expectEqual(0x182, regs.EPSTALL.raw);

        regs.DTOGGLE.raw = 0x282; // IN EP2, DATA1
        try USBD.ep_set_stall(&dev.interface, ep, false);
        try std.testing.expectEqual(0x082, regs.EPSTALL.raw);
        try std.testing.expectEqual(0x182, microzig.testing_io.toggle_at_stall_write); // IN EP2, DATA0
        try std.testing.expect(dev.in_busy[2]);
    }

    pub fn halt_wake() !void {
        const io = microzig.testing_io;
        io.reset();
        const ep: usb.types.Endpoint = .in(.ep1);
        var dev: USBD = .{ .interface = .{ .vtable = &USBD.vtable }, .power = .connected, .low_power = true };
        dev.interface.opened.set(ep, true);
        io.wake_ready = true;

        try dev.interface.ep_halt(ep);
        try std.testing.expect(dev.interface.halted.contains(ep));
        try std.testing.expectEqual(1, io.stall_writes);
        try std.testing.expectEqual(1, io.force_normal_writes_at_stall);
        try std.testing.expectEqual(0x181, peripherals.USBD.EPSTALL.raw);
    }

    pub fn halt_wake_timeout() !void {
        const io = microzig.testing_io;
        io.reset();
        const ep: usb.types.Endpoint = .in(.ep1);
        var dev: USBD = .{ .interface = .{ .vtable = &USBD.vtable }, .power = .connected, .low_power = true };
        dev.interface.opened.set(ep, true);
        dev.in_busy[1] = true; // Already loaded before suspend.

        try std.testing.expectError(error.Timeout, dev.interface.ep_halt(ep));
        try std.testing.expectEqual(1, io.force_normal_writes);
        try std.testing.expect(dev.low_power);
        try std.testing.expect(!dev.interface.halted.contains(ep));
        try std.testing.expectEqual(0, io.stall_writes);

        peripherals.USBD.EVENTCAUSE.raw = CAUSE_RESUME;
        var ctl: CDC_Controller = .{};
        dev.poll(&ctl);
        try std.testing.expect(!dev.low_power);
        try std.testing.expect(dev.in_busy[1]);
        try std.testing.expect(!dev.interface.halted.contains(ep));
        try std.testing.expectEqual(0, io.stall_writes);
    }

    pub fn halt_retirement() !void {
        const io = microzig.testing_io;
        io.reset();
        const regs = peripherals.USBD;
        const ep: usb.types.Endpoint = .out(.ep2);
        var dev: USBD = .{ .interface = .{ .vtable = &USBD.vtable }, .power = .connected };
        dev.interface.opened.set(ep, true);

        regs.EVENTS_USBRESET.raw = 1;
        try std.testing.expectError(error.Unavailable, dev.interface.ep_halt(ep));
        try std.testing.expectError(error.Unavailable, USBD.ep_set_stall(&dev.interface, ep, false));
        try std.testing.expect(!dev.interface.halted.contains(ep));

        regs.EVENTS_USBRESET.raw = 0;
        dev.dma.faulted = true;
        try std.testing.expectError(error.Unavailable, dev.interface.ep_halt(ep));
        try std.testing.expectError(error.Unavailable, USBD.ep_set_stall(&dev.interface, ep, false));
        try std.testing.expect(!dev.interface.halted.contains(ep));
        dev.dma.faulted = false;

        dev.low_power = true;
        io.wake_ready = true;
        io.reset_on_wake = true;
        try std.testing.expectError(error.Unavailable, dev.interface.ep_halt(ep));
        try std.testing.expect(!dev.low_power);
        try std.testing.expect(!dev.interface.halted.contains(ep));
        try std.testing.expectEqual(0, io.stall_writes);
        try std.testing.expectEqual(0, regs.DTOGGLE.raw);

        var ctl: CDC_Controller = .{};
        dev.poll(&ctl);
        try std.testing.expectEqual(0, regs.EVENTS_USBRESET.raw);
        try std.testing.expectEqual(0, io.stall_writes);

        try dev.interface.ep_halt(ep);
        USBD.ep_close_all(&dev.interface);
        try std.testing.expectEqual(0, regs.HALTED.EPOUT[2].raw);

        dev.interface.halted.set(ep, true);
        dev.low_power = true;
        dev.teardown();
        try std.testing.expectError(error.NotOpen, dev.interface.ep_halt(ep));
        try std.testing.expect(!dev.interface.opened.contains(ep));
        try std.testing.expect(!dev.interface.halted.contains(ep));
    }

    pub fn configuration_reselection() !void {
        microzig.testing_io.reset();
        var dev: USBD = .{ .interface = .{ .vtable = &USBD.vtable }, .power = .connected };
        var ctl: usb.DeviceController(.{
            .device_triple = .unspecified,
            .bcd_device = .v1_00,
            .serial = "test",
            .device_capabilities = USBD.device_capabilities,
        }, &.{usb.Configuration(
            .{ .attributes = .{ .self_powered = false }, .max_current_ma = 50 },
            .{ .serial = usb.drivers.CDC{} },
        )}) = .init;

        const regs = peripherals.USBD;
        regs.BREQUEST.raw = @backingInt(usb.types.SetupRequest.set_configuration);
        regs.WVALUEL.raw = 1;
        regs.EVENTS_EP0SETUP.raw = 1;
        dev.poll(&ctl);
        const drivers = ctl.drivers() orelse return error.ExpectedConfiguration;
        const generation = dev.get_configuration_generation();

        // SET_CONFIGURATION(1) again rebuilds CDC at the same address.
        regs.EVENTS_EP0SETUP.raw = 1;
        dev.poll(&ctl);
        try std.testing.expect(ctl.drivers() == drivers);
        try std.testing.expectEqual(generation +% 1, dev.get_configuration_generation());

        // Polling the completed setup again does not count a new change.
        dev.poll(&ctl);
        try std.testing.expectEqual(generation +% 1, dev.get_configuration_generation());

        // Core still replaces CDC for a device-to-host SET_CONFIGURATION.
        // EP0 does not recognize it as a configuration change.
        drivers.serial.tx_end = 1;
        regs.BMREQUESTTYPE.raw = 0x80;
        regs.EVENTS_EP0SETUP.raw = 1;
        dev.poll(&ctl);
        try std.testing.expect(ctl.drivers() == drivers);
        try std.testing.expectEqual(0, drivers.serial.tx_end);
        try std.testing.expectEqual(generation +% 2, dev.get_configuration_generation());

        const before_reset = dev.get_configuration_generation();
        regs.EVENTS_USBRESET.raw = 1;
        dev.poll(&ctl);
        try std.testing.expect(ctl.drivers() == null);
        try std.testing.expect(dev.get_configuration_generation() != before_reset);
    }

    pub fn foreground_poll() !void {
        const io = microzig.testing_io;
        io.reset();
        const Controller = struct {
            pub fn on_bus_reset(_: *@This(), _: *usb.DeviceInterface) void {}
            pub fn on_setup_req(_: *@This(), _: *usb.DeviceInterface, _: *const usb.types.SetupPacket) void {}
            pub fn on_buffer(_: *@This(), _: *usb.DeviceInterface, comptime _: usb.types.Endpoint) void {}
        };
        var ctl: Controller = .{};
        var dev: USBD = .{ .interface = .{ .vtable = &USBD.vtable }, .power = .connected };
        dev.control.setup(.{ .request_type = 0x21, .request = 1, .length = 64 });
        peripherals.USBD.EVENTS_EP0DATADONE.raw = 1;
        peripherals.USBD.SIZE.EPOUT[0].raw = 64;
        io.in_isr = true;
        dev.poll(&ctl);
        try std.testing.expectEqual(1, peripherals.USBD.EVENTS_EP0DATADONE.raw);
        try std.testing.expectEqual(0, peripherals.USBD.TASKS_STARTEPOUT[0].raw);
        try std.testing.expect(!dev.dma.faulted);
        io.in_isr = false;
        io.dma_ready = true;
        dev.poll(&ctl);
        try std.testing.expectEqual(0, peripherals.USBD.EVENTS_EP0DATADONE.raw);
        try std.testing.expectEqual(1, peripherals.USBD.TASKS_STARTEPOUT[0].raw);
        try std.testing.expectEqual(1, peripherals.USBD.TASKS_EP0STATUS.raw);
        try std.testing.expect(!dev.dma.faulted);
    }
} else struct {};
