//! USB device implementation
//!
//! Initial inspiration: cbiffle's Rust [implementation](https://github.com/cbiffle/rp2040-usb-device-in-one-file/blob/main/src/main.rs)
//! Currently progressing towards adopting the TinyUSB like API

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.usb_dev);

const microzig = @import("microzig");
const peripherals = microzig.chip.peripherals;
const chip = microzig.hal.compatibility.chip;
const usb = microzig.core.usb;
const time = @import("time.zig");

pub const RP2XXX_MAX_ENDPOINTS_COUNT = 16;

pub const Config = struct {
    // Comptime defined supported max endpoints number, can be reduced to save RAM space
    max_endpoints_count: comptime_int = RP2XXX_MAX_ENDPOINTS_COUNT,
    max_interfaces_count: comptime_int = 16,
    sync_noops: comptime_int = 3,
};

const HardwareEndpointData = struct {
    data_buffer: []align(64) u8,
};

const rp2xxx_buffers = struct {
    // Address 0x100-0xfff (3840 bytes) can be used for data buffers.
    // The first 0x100 bytes are registers (last one at offset 0xfc), the rest is available for
    // endpoint data buffers.
    const USB_DPRAM_DATA_BUFFER_BASE = @intFromPtr(peripherals.USB_DPRAM) + 0x100;

    const CTRL_EP_BUFFER_SIZE = 64;

    const USB_EP0_BUFFER0 = USB_DPRAM_DATA_BUFFER_BASE;
    const USB_EP0_BUFFER1 = USB_DPRAM_DATA_BUFFER_BASE + CTRL_EP_BUFFER_SIZE;

    const USB_DATA_BUFFER = USB_DPRAM_DATA_BUFFER_BASE + (2 * CTRL_EP_BUFFER_SIZE);
    const USB_DATA_BUFFER_SIZE = 3840 - (2 * CTRL_EP_BUFFER_SIZE);

    const ep0_buffer0: *align(64) [CTRL_EP_BUFFER_SIZE]u8 = @ptrFromInt(USB_EP0_BUFFER0);
    const ep0_buffer1: *align(64) [CTRL_EP_BUFFER_SIZE]u8 = @ptrFromInt(USB_EP0_BUFFER1);
    const data_buffer: *align(64) [USB_DATA_BUFFER_SIZE]u8 = @ptrFromInt(USB_DATA_BUFFER);

    fn data_offset(ep_data_buffer: []u8) u16 {
        const buf_base = @intFromPtr(&ep_data_buffer[0]);
        const dpram_base = @intFromPtr(peripherals.USB_DPRAM);
        return @as(u16, @intCast(buf_base - dpram_base));
    }
};

fn PerEndpoint(T: type) type {
    return extern struct {
        in: T,
        out: T,

        fn get(self: *volatile @This(), dir: usb.types.Dir) *volatile T {
            return switch (dir) {
                .in => &self.in,
                .out => &self.out,
            };
        }
    };
}

// It would be nice to instead generate those arrays automatically with a regz patch.
const BufferControlMmio = microzig.mmio.Mmio(@TypeOf(peripherals.USB_DPRAM.EP0_IN_BUFFER_CONTROL).underlying_type);
const buffer_control: *volatile [16]PerEndpoint(BufferControlMmio) = @ptrCast(&peripherals.USB_DPRAM.EP0_IN_BUFFER_CONTROL);

const EndpointControlMmio = microzig.mmio.Mmio(@TypeOf(peripherals.USB_DPRAM.EP1_IN_CONTROL).underlying_type);
const endpoint_control: *volatile [15]PerEndpoint(EndpointControlMmio) = @ptrCast(&peripherals.USB_DPRAM.EP1_IN_CONTROL);

// +++++++++++++++++++++++++++++++++++++++++++++++++
// Code
// +++++++++++++++++++++++++++++++++++++++++++++++++

/// A set of functions required by the abstract USB impl to
/// create a concrete one.
pub fn Polled(config: Config) type {
    comptime {
        if (config.max_endpoints_count > RP2XXX_MAX_ENDPOINTS_COUNT)
            @compileError("RP2XXX USB endpoints number can't be grater than RP2XXX_MAX_ENDPOINTS_COUNT");
    }

    return struct {
        pub const max_supported_packet_size = 64;
        pub const max_supported_bcd_usb: usb.types.Version = .v1_10;
        pub const default_vendor_id: usb.Config.IdStringPair = .{ .id = 0x2E8A, .str = "Raspberry Pi" };
        pub const default_product_id: usb.Config.IdStringPair = switch (chip) {
            .RP2040 => .{ .id = 0x000A, .str = "Pico test device" },
            .RP2350 => .{ .id = 0x000F, .str = "Pico 2 test device" },
        };

        const vtable: usb.DeviceInterface.VTable = .{
            .ep_writev = ep_writev,
            .ep_readv = ep_readv,
            .ep_listen = ep_listen,
            .ep_open = ep_open,
            .ep_close_all = ep_close_all,
            .control_out_data = true,
            .set_address = set_address,
        };

        endpoints: [config.max_endpoints_count][2]HardwareEndpointData,
        control: usb.ControlRequest = .{},
        data_buffer: []align(64) u8,
        interface: usb.DeviceInterface,

        /// Poll to see if the host has sent anything. Delegate to the appropriate handler in the
        /// controller based on the interrupt field set.
        ///
        /// For polled use only, not for the USB interrupt handler: a completion whose buffer
        /// still reads AVAILABLE is left in BUFF_STATUS for a later call, INTS.BUFF_STATUS
        /// stays set for as long as it is, and an interrupt handler that returned with it set
        /// would be entered again at once.
        pub fn poll(self: *@This(), controller: anytype) void {
            comptime usb.validate_controller(@TypeOf(controller));

            // Check which interrupt flags are set.
            const ints = peripherals.USB.INTS.read();

            // Setup request received?
            if (ints.SETUP_REQ != 0) {
                log.debug("-- setup request --", .{});

                // Withdraw data, stale completions and STALL from the old transfer.
                // USB 2.0, 5.5.5; RP2040 datasheet 4.1.4, EP_STALL_ARM;
                // RP2350 datasheet 12.7.5, EP_STALL_ARM. Next packet is DATA1.
                withdraw_buffer(.in(.ep0), 0);

                // A new SETUP cancels the preceding OUT data/status buffer too
                // (USB 2.0, 5.5.5). The next OUT data packet starts at DATA1.
                withdraw_buffer(.out(.ep0), 0);
                // Clear this status flag only (RP2040 datasheet 4.1.4, SIE_STATUS).
                peripherals.USB.SIE_STATUS.write(.{ .SETUP_REC = 1 });

                // The SVD exposes this buffer as two 32-bit registers.
                const setup: usb.types.SetupPacket = @bitCast([2]u32{
                    peripherals.USB_DPRAM.SETUP_PACKET_LOW.raw,
                    peripherals.USB_DPRAM.SETUP_PACKET_HIGH.raw,
                });

                log.debug("setup {any}", .{setup});
                self.control.setup(&setup);
                controller.on_setup_req(&self.interface, &setup);
                if (self.control.needs_stall()) self.stall_control();
            }

            // Events on one or more buffers?
            if (ints.BUFF_STATUS != 0) {
                log.debug("-- buffer status --", .{});

                const buff_status = peripherals.USB.BUFF_STATUS.raw;

                inline for (0..2 * config.max_endpoints_count) |shift| {
                    const bit = @as(u32, 1) << shift;
                    if (buff_status & bit != 0) {
                        // Here we exploit knowledge of the ordering of buffer control
                        // registers in the peripheral. Each endpoint has a pair of
                        // registers, IN being first
                        const ep_num = shift / 2;
                        const ep: usb.types.Endpoint = comptime .{
                            .num = @fromBackingInt(ep_num),
                            .dir = if (shift % 2 == 0) .in else .out,
                        };

                        // The buffer is ours again once the hardware has cleared AVAILABLE.
                        // It sets the BUFF_STATUS bit first and updates the buffer control
                        // register after that (RP2040 datasheet 4.1.2.8.2, STATUS phase; the
                        // RP2350's 12.7.3.8.2 says the same), so AVAILABLE may still read 1
                        // here. Then leave the bit set and take the buffer on a later poll
                        // rather than wait for it: the bit can also belong to an earlier
                        // buffer, when the handler of a setup request seen by this same poll
                        // has just armed the endpoint again (EP0 IN, typically), and that
                        // buffer stays AVAILABLE until the host takes it, if it ever does.
                        if (buffer_control[ep_num].get(ep.dir).read().AVAILABLE_0 == 0) {
                            // Acknowledge this one completion (write-one-to-clear) before
                            // its handler runs. The handler may arm the endpoint again, and
                            // the bit set when that buffer completes must survive this poll.
                            peripherals.USB.BUFF_STATUS.write_raw(bit);

                            log.debug("buffer ep{} {t}", .{ ep_num, ep.dir });
                            if (ep.num == .ep0 and ep.dir == .out) {
                                if (self.control.out_packet()) {
                                    controller.on_buffer(&self.interface, ep);
                                    if (self.control.needs_stall()) self.stall_control();
                                }
                            } else controller.on_buffer(&self.interface, ep);
                        }
                    }
                }
            }

            // Has the host signaled a bus reset?
            // Checked last on purpose. A reset holds the bus for at least 10 ms (TinyUSB's
            // dcd_rp2040.c notes the same where it handles BUS_RESET), and nothing reaches
            // the device meanwhile, so a setup request or a completion that the same poll
            // finds came before the reset as long as `poll` runs more often than that.
            // Handling those first and the reset last is their order on the bus, and it
            // leaves the device unconfigured at address 0. With the reset first the
            // controller would act on a request the reset had cancelled: a
            // SET_CONFIGURATION seen together with the reset would leave the device
            // configured. The datasheet's example (pico-examples, dev_lowlevel.c) and
            // TinyUSB check the reset last as well.
            if (ints.BUS_RESET != 0) {
                log.debug("-- bus reset --", .{});

                peripherals.USB.SIE_STATUS.write(.{ .BUS_RESET = 1 });
                set_address(&self.interface, 0);
                self.control = .{};
                controller.on_bus_reset(&self.interface);
            }
        }

        pub fn init() @This() {
            if (chip == .RP2350)
                peripherals.USB.MAIN_CTRL.write(.{ .PHY_ISO = 0 });

            peripherals.USB.SIE_CTRL.modify(.{ .PULLUP_EN = 0 });

            // Clear the control portion of DPRAM. This may not be necessary -- the
            // datasheet is ambiguous -- but the C examples do it, and so do we.
            peripherals.USB_DPRAM.SETUP_PACKET_LOW.write_raw(0);
            peripherals.USB_DPRAM.SETUP_PACKET_HIGH.write_raw(0);

            for (1..config.max_endpoints_count) |i| {
                endpoint_control[i - 1].in.write_raw(0);
                endpoint_control[i - 1].out.write_raw(0);
            }

            for (0..config.max_endpoints_count) |i| {
                buffer_control[i].in.write_raw(0);
                buffer_control[i].out.write_raw(0);
            }

            // Mux the controller to the onboard USB PHY. I was surprised that there are
            // alternatives to this, but, there are.
            peripherals.USB.USB_MUXING.modify(.{
                .TO_PHY = 1,
                // This bit is also set in the SDK example, without any discussion. It's
                // undocumented (being named does not count as being documented).
                .SOFTCON = 1,
            });

            // Force VBUS detect. Not all RP2040 boards wire up VBUS detect, which would
            // let us detect being plugged into a host (the Pi Pico, to its credit,
            // does). For maximum compatibility, we'll set the hardware to always
            // pretend VBUS has been detected.
            peripherals.USB.USB_PWR.modify(.{
                .VBUS_DETECT = 1,
                .VBUS_DETECT_OVERRIDE_EN = 1,
            });

            // Enable controller in device mode.
            peripherals.USB.MAIN_CTRL.modify(.{
                .CONTROLLER_EN = 1,
                .HOST_NDEVICE = 0,
            });

            // Request to have an interrupt (which really just means setting a bit in
            // the `buff_status` register) every time a buffer moves through EP0.
            peripherals.USB.SIE_CTRL.modify(.{
                .EP0_INT_1BUF = 1,
            });

            // Enable interrupts (bits set in the `ints` register) for other conditions
            // we use:
            peripherals.USB.INTE.modify(.{
                // A buffer is done
                .BUFF_STATUS = 1,
                // The host has reset us
                .BUS_RESET = 1,
                // We've gotten a setup request on EP0
                .SETUP_REQ = 1,
            });

            var self: @This() = .{
                .endpoints = undefined,
                .data_buffer = rp2xxx_buffers.data_buffer,
                .interface = .{ .vtable = &vtable },
            };

            @memset(std.mem.asBytes(&self.endpoints), 0);

            // Set up endpoints.
            self.interface.ep_open(&.control(.in(.ep0), max_supported_packet_size));
            self.interface.ep_open(&.control(.out(.ep0), max_supported_packet_size));

            // Present full-speed device by enabling pullup on DP. This is the point
            // where the host will notice our presence.
            peripherals.USB.SIE_CTRL.modify(.{ .PULLUP_EN = 1 });

            // Listen for ACKs
            self.interface.ep_listen(.ep0, max_supported_packet_size);

            return self;
        }

        /// Configures a given IN endpoint to send data when the host next asks for it.
        ///
        /// The contents of `buffer` will be _copied_ into USB SRAM, so you can
        /// reuse `buffer` immediately after this returns. No need to wait for the
        /// packet to be sent.
        fn ep_writev(
            itf: *usb.DeviceInterface,
            ep_num: usb.types.Endpoint.Num,
            data: []const []const u8,
        ) usb.types.Len {
            log.debug("writev {t} {}: {any}", .{ ep_num, data[0].len, data[0] });

            const self: *@This() = @fieldParentPtr("interface", itf);

            if (ep_num == .ep0) {
                self.control.reply();
                // A control read's status OUT can arrive after its final IN packet.
                // USB 2.0, 8.5.3.3 (Control Read).
                if (self.control.direction == .in and buffer_control[0].out.read().AVAILABLE_0 == 0)
                    ep_listen(itf, .ep0, max_supported_packet_size);
            }

            const bufctrl_ptr = &buffer_control[@backingInt(ep_num)].in;
            const ep = self.hardware_endpoint_get_by_address(.in(ep_num));
            var hw_buf: []align(1) u8 = ep.data_buffer;

            for (data) |src| {
                const len = @min(src.len, hw_buf.len);
                dpram_memcpy(hw_buf[0..len], src[0..len]);
                hw_buf = hw_buf[len..];
            }

            const len: usb.types.Len = @intCast(ep.data_buffer.len - hw_buf.len);

            var bufctrl = bufctrl_ptr.read();
            assert(bufctrl.AVAILABLE_0 == 0);
            // Write the buffer information to the buffer control register
            bufctrl.PID_0 ^= 1; // flip DATA0/1
            bufctrl.FULL_0 = 1; // We have put data in
            bufctrl.LENGTH_0 = @intCast(len); // There are this many bytes

            if (config.sync_noops != 0) {
                bufctrl_ptr.write(bufctrl);
                // The AVAILABLE bit in the buffer control register should be set
                // separately to the rest of the data in the buffer control register,
                // so that the rest of the data in the buffer control register is
                // accurate when the AVAILABLE bit is set.
                inline for (0..config.sync_noops) |_|
                    asm volatile ("nop");
            }
            // Set available bit
            bufctrl.AVAILABLE_0 = 1;
            bufctrl_ptr.write(bufctrl);

            return len;
        }

        /// Copies the last sent packet from USB SRAM into the provided buffer.
        /// Slices in `data` must collectively be long enough to store the full packet.
        fn ep_readv(
            itf: *usb.DeviceInterface,
            ep_num: usb.types.Endpoint.Num,
            data: []const []u8,
        ) usb.types.Len {
            var total_len: usize = data[0].len;
            for (data[1..]) |d| total_len += d.len;
            log.debug("readv {t} {}", .{ ep_num, total_len });

            const self: *@This() = @fieldParentPtr("interface", itf);
            assert(data.len > 0);

            const bufctrl = buffer_control[@backingInt(ep_num)].out.read();
            const ep = self.hardware_endpoint_get_by_address(.out(ep_num));
            var hw_buf: []align(1) u8 = ep.data_buffer[0..bufctrl.LENGTH_0];
            for (data) |dst| {
                const len = @min(dst.len, hw_buf.len);
                dpram_memcpy(dst[0..len], hw_buf[0..len]);

                hw_buf = hw_buf[len..];
                if (hw_buf.len == 0)
                    return @intCast(hw_buf.ptr - ep.data_buffer.ptr);
            }
            log.warn("discarding rx data on ep {t}, {} bytes received", .{ ep_num, bufctrl.LENGTH_0 });
            return @intCast(total_len);
        }

        fn ep_listen(
            itf: *usb.DeviceInterface,
            ep_num: usb.types.Endpoint.Num,
            len: usb.types.Len,
        ) void {
            log.debug("listen {t} {}", .{ ep_num, len });

            const self: *@This() = @fieldParentPtr("interface", itf);
            if (ep_num == .ep0) self.control.listen();
            const bufctrl_ptr = &buffer_control[@backingInt(ep_num)].out;

            var bufctrl = bufctrl_ptr.read();
            const ep = self.hardware_endpoint_get_by_address(.out(ep_num));
            assert(bufctrl.AVAILABLE_0 == 0);
            // Configure the OUT:
            bufctrl.PID_0 ^= 1; // Flip DATA0/1
            bufctrl.FULL_0 = 0; // Buffer is NOT full, we want the computer to fill it
            bufctrl.LENGTH_0 = @intCast(@min(len, ep.data_buffer.len)); // Up tho this many bytes

            if (config.sync_noops != 0) {
                bufctrl_ptr.write(bufctrl);
                // The AVAILABLE bit in the buffer control register should be set
                // separately to the rest of the data in the buffer control register,
                // so that the rest of the data in the buffer control register is
                // accurate when the AVAILABLE bit is set.
                inline for (0..config.sync_noops) |_|
                    asm volatile ("nop");
            }
            // Set available bit
            bufctrl.AVAILABLE_0 = 1;
            bufctrl_ptr.write(bufctrl);
        }

        fn set_address(_: *usb.DeviceInterface, addr: u7) void {
            log.debug("set addr {}", .{addr});

            peripherals.USB.ADDR_ENDP.write(.{ .ADDRESS = addr });
        }

        /// On the RP2350 @memcpy uses unaligned accesses,
        /// which only work on SRAM and fault on peripheral memory.
        fn dpram_memcpy(dst: []u8, src: []const u8) void {
            switch (chip) {
                .RP2040 => @memcpy(dst, src),
                .RP2350 => {
                    assert(dst.len == src.len);
                    // Could be optimized for aligned data, for now just copy
                    // byte by byte. Atomic operations are used so that
                    // the compiler does not try to optimize this.
                    for (dst, src) |*d, *s| {
                        const tmp = @atomicLoad(u8, s, .unordered);
                        @atomicStore(u8, d, tmp, .unordered);
                    }
                },
            }
        }

        fn hardware_endpoint_get_by_address(self: *@This(), ep: usb.types.Endpoint) *HardwareEndpointData {
            return &self.endpoints[@backingInt(ep.num)][@backingInt(ep.dir)];
        }

        fn stall_control(self: *@This()) void {
            // USB 2.0, 9.2.7 / 8.5.3.4; RP2040 datasheet 4.1.4 and RP2350
            // datasheet 12.7.5, EP_STALL_ARM / buffer control STALL.
            self.control = .{};
            peripherals.USB.EP_STALL_ARM.write_raw(3);
            buffer_control[0].in.modify(.{ .STALL = 1 });
            buffer_control[0].out.modify(.{ .STALL = 1 });
        }

        fn ep_close_all(itf: *usb.DeviceInterface) void {
            _ = itf;
            for (1..config.max_endpoints_count) |i| {
                const num: usb.types.Endpoint.Num = @fromBackingInt(@as(u4, @intCast(i)));
                withdraw_buffer(.in(num), 1);
                withdraw_buffer(.out(num), 1);
                endpoint_control[i - 1].in.write_raw(0);
                endpoint_control[i - 1].out.write_raw(0);
            }
        }

        fn ep_open(itf: *usb.DeviceInterface, desc: *const usb.descriptor.Endpoint) void {
            const ep = desc.endpoint;
            const attr = desc.attributes;
            log.debug(
                "ep open {t} {t} {{ type: {t}, sync: {t}, usage: {t}, size: {} }}",
                .{ ep.num, ep.dir, attr.transfer_type, attr.synchronisation, attr.usage, desc.max_packet_size.native() },
            );

            const self: *@This() = @fieldParentPtr("interface", itf);

            assert(@backingInt(desc.endpoint.num) < config.max_endpoints_count);

            const ep_hard = self.hardware_endpoint_get_by_address(ep);

            assert(desc.max_packet_size.native() <= max_supported_packet_size);

            // The host can configure again without a bus reset (SET_CONFIGURATION), and `poll`
            // does not write the buffer control register on a bus reset either, so the endpoint
            // may be opened while a buffer from its previous configuration is still AVAILABLE,
            // or has completed without `poll` having seen it. Take it back, and set the PID so
            // that the first packet is DATA0.
            withdraw_buffer(ep, 1);

            if (ep.num == .ep0) {
                // ep0 has fixed data buffer
                ep_hard.data_buffer = rp2xxx_buffers.ep0_buffer0;
            } else {
                // An endpoint keeps its buffer for as long as the device runs. It is opened
                // again every time the host selects the configuration, and nothing ever
                // returns DPRAM, so allocating on every open would use it up.
                const size = endpoint_buffer_size(desc);
                if (ep_hard.data_buffer.len == 0)
                    ep_hard.data_buffer = self.endpoint_alloc(size)
                else if (ep_hard.data_buffer.len < size)
                    @panic("USB endpoint reopened with a larger buffer");
                endpoint_control[@backingInt(ep.num) - 1].get(ep.dir).write(.{
                    .ENABLE = 1,
                    .INTERRUPT_PER_BUFF = 1,
                    .ENDPOINT_TYPE = @fromBackingInt(@backingInt(attr.transfer_type)),
                    .BUFFER_ADDRESS = rp2xxx_buffers.data_offset(ep_hard.data_buffer),
                });
            }
            @memset(ep_hard.data_buffer, 0);
        }

        /// Takes an endpoint's buffer back from the controller, armed or not: afterwards the
        /// buffer control register holds `pid` and nothing else, as `ep_listen` and
        /// `ep_writev` require, and `poll` reports no completion from before.
        fn withdraw_buffer(ep: usb.types.Endpoint, pid: u1) void {
            var io: BufferWithdrawal = .{ .ep = ep, .pid = pid };
            usb.endpoint_buffer.withdraw(&io) catch {
                // Retain EP_ABORT and DPRAM ownership until a reset. RP2040 datasheet
                // 4.1.4 and RP2350 datasheet 12.7.5, EP_ABORT_DONE: only DONE establishes
                // that software can modify the buffer control register.
                @panic("USB endpoint abort timed out: reset required");
            };
        }

        const BufferWithdrawal = struct {
            ep: usb.types.Endpoint,
            pid: u1,

            fn bit(self: *const @This()) u32 {
                return @as(u32, 1) << (2 * @as(u5, @backingInt(self.ep.num)) +
                    @as(u5, @intFromBool(self.ep.dir == .out)));
            }

            pub fn begin_abort(self: *@This()) bool {
                const ctrl = buffer_control[@backingInt(self.ep.num)].get(self.ep.dir);
                if (ctrl.read().AVAILABLE_0 == 0 or !ep_abort_usable()) return false;
                // RP2040 datasheet 4.1.4 / RP2350 datasheet 12.7.5, EP_ABORT:
                // hold the endpoint at NAK until DONE grants access to its buffer.
                peripherals.USB.EP_ABORT.write_raw(self.bit());
                return true;
            }

            pub fn wait_abort(self: *@This()) bool {
                const deadline = time.deadline_in_us(ep_abort_timeout_us);
                while (peripherals.USB.EP_ABORT_DONE.raw & self.bit() == 0) {
                    if (deadline.is_reached_by(time.get_time_since_boot())) return false;
                }
                return true;
            }

            pub fn withdraw(self: *@This()) void {
                buffer_control[@backingInt(self.ep.num)].get(self.ep.dir).write(.{ .PID_0 = self.pid });
            }

            pub fn clear_completion(self: *@This()) void {
                peripherals.USB.BUFF_STATUS.write_raw(self.bit()); // W1C
            }

            pub fn end_abort(self: *@This()) void {
                peripherals.USB.EP_ABORT_DONE.write_raw(self.bit()); // W1C
                peripherals.USB.EP_ABORT.write_raw(0);
            }
        };

        /// How long `withdraw_buffer` waits for EP_ABORT_DONE: one full-speed frame. The controller
        /// reports the endpoint idle once a transaction in progress on it has ended, and
        /// a transaction ends within the frame it started in.
        const ep_abort_timeout_us = 1000;

        /// Erratum RP2040-E2: on RP2040 B0 and B1 the controller NAKs every endpoint forever
        /// once a transaction starts on an endpoint whose EP_ABORT bit is set, and the
        /// workaround is not to use EP_ABORT. Fixed in B2, and in the RP2350 (its datasheet,
        /// 12.7.2.1: "RP2350 fixes all RP2040 USB errata"). CHIP_ID.REVISION is 1 for B0
        /// and B1 and 2 for B2 (pico-sdk, `rp2040_chip_version`).
        fn ep_abort_usable() bool {
            return switch (chip) {
                .RP2040 => peripherals.SYSINFO.CHIP_ID.read().REVISION >= 2,
                .RP2350 => true,
            };
        }

        fn endpoint_buffer_size(desc: *const usb.descriptor.Endpoint) u16 {
            // round up size to multiple of 64
            const size = std.mem.alignForward(u16, desc.max_packet_size.native(), 64);
            // double buffered Bulk endpoint
            return if (desc.attributes.transfer_type == .Bulk) 2 * size else size;
        }

        fn endpoint_alloc(self: *@This(), size: u16) []align(64) u8 {
            // Checked in every build mode: past this point the endpoint's buffer would lie
            // outside the DPRAM.
            if (self.data_buffer.len < size)
                @panic("USB DPRAM exhausted");

            defer self.data_buffer = @alignCast(self.data_buffer[size..]);
            return self.data_buffer[0..size];
        }
    };
}

pub fn ResetDriver(bootsel_activity_led: ?u5, interface_disable_mask: u32) type {
    return struct {
        const log_drv = std.log.scoped(.pico_reset);

        pub const Descriptor = extern struct {
            reset_interface: usb.descriptor.Interface,

            pub fn create(
                alloc: *usb.DescriptorAllocator,
                _: usb.types.Len,
                interface_str: []const u8,
            ) usb.DescriptorCreateResult(@This()) {
                return .{ .descriptor = .{ .reset_interface = .{
                    .interface_number = alloc.next_itf(),
                    .alternate_setting = 0,
                    .num_endpoints = 0,
                    .interface_triple = .from(
                        .VendorSpecific,
                        @fromBackingInt(0x00),
                        @fromBackingInt(0x01),
                    ),
                    .interface_s = alloc.string(interface_str),
                } } };
            }
        };

        pub fn init(self: *@This(), desc: *const Descriptor, device: *usb.DeviceInterface) void {
            _ = desc;
            _ = device;
            self.* = .{};
        }

        pub fn class_request(self: *@This(), setup: *const usb.types.SetupPacket) ?[]const u8 {
            _ = self;
            switch (setup.request) {
                0x01 => {
                    const value = setup.value.native();
                    const mask = @as(u32, 1) << if (value & 0x100 != 0)
                        @intCast(value >> 9)
                    else
                        bootsel_activity_led orelse 0;
                    const itf_disable = (value & 0x7F) | interface_disable_mask;
                    log_drv.debug("Resetting to bootsel. Mask: {} Itf disable: {}", .{ mask, itf_disable });
                    microzig.hal.rom.reset_to_usb_boot();
                },
                0x02 => {
                    log_drv.debug("Resetting to flash", .{});
                    // Not implemented yet
                    microzig.hal.rom.reset_to_usb_boot();
                },
                else => return usb.nak,
            }
            return usb.ack;
        }
    };
}
