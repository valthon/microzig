//! WCH USBHD/USBHS device backend
//!

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.usb_dev);

const microzig = @import("microzig");
const peripherals = microzig.chip.peripherals;
const usb = microzig.core.usb;
const types = usb.types;
const descriptor = usb.descriptor;

pub const USBHD_MAX_ENDPOINTS_COUNT = 16;

const max_buffer_pool_size = USBHD_MAX_ENDPOINTS_COUNT * 2 * 512 + 64;

/// Physical-layer USB setup (placeholder for API compatibility with USBD).
/// USBHS pins are fixed by the peripheral and not configurable.
pub const Setup = struct {};

pub const Config = struct {
    max_endpoints_count: comptime_int = USBHD_MAX_ENDPOINTS_COUNT,

    prefer_high_speed: bool = true,

    /// Static buffer pool in SRAM, bump-allocated
    buffer_bytes: comptime_int = max_buffer_pool_size,

    /// not implemented yet
    use_interrupts: bool = false,
};

const Regs = peripherals.USBHS;

// The host model implements write-one-to-clear poll flags and backs endpoint configuration.
const PollRegs = if (@import("builtin").is_test) &test_poll_regs else Regs;
const TestFlags = packed struct(u8) {
    RB_UIF_BUS_RST__RB_UIF_DETECT: u1 = 0,
    RB_UIF_TRANSFER: u1 = 0,
    RB_UIF_SUSPEND: u1 = 0,
    RB_UIF_HST_SOF: u1 = 0,
    RB_UIF_FIFO_OV: u1 = 0,
    // Match the generated register default so omitted writes are visible.
    RB_UIF_SETUP_ACT: u1 = 1,
    reserved: u2 = 0,
};
const TestStatus = packed struct(u8) {
    MASK_UIS_H_RES__MASK_UIS_ENDP: u4 = 0,
    MASK_UIS_TOKEN: u2 = 0,
    reserved: u2 = 0,
};
var test_poll_regs: struct {
    USB_INT_FG: struct {
        pending: TestFlags = .{ .RB_UIF_SETUP_ACT = 0 },
        reads_until_setup: u2 = 0,

        fn read(self: *@This()) TestFlags {
            if (self.reads_until_setup != 0) {
                self.reads_until_setup -= 1;
                if (self.reads_until_setup == 0) self.pending.RB_UIF_SETUP_ACT = 1;
            }
            return self.pending;
        }

        fn write(self: *@This(), clear: TestFlags) void {
            self.pending = @bitCast(@as(u8, @bitCast(self.pending)) & ~@as(u8, @bitCast(clear)));
        }
    } = .{},
    USB_INT_ST: microzig.mmio.Mmio(TestStatus) = .{ .raw = 0 },
    USB_DEV_AD: microzig.mmio.Mmio(packed struct(u8) {
        MASK_USB_ADDR: u7 = 0,
        reserved: u1 = 0,
    }) = .{ .raw = 0 },
    UEP_CONFIG__UHOST_CTRL: Reg_U32 = .{ .raw = 0 },
    UEP_TYPE: Reg_U32 = .{ .raw = 0 },
    rx_dma: [15]Reg_U32 = @splat(.{ .raw = 0 }),
    tx_dma: [15]Reg_U32 = @splat(.{ .raw = 0 }),
    max_len: [15]Reg_U16 = @splat(.{ .raw = 0 }),
} = .{};

const EP_State = struct {
    buf: []align(4) u8 = &[_]u8{},
    // OUT:
    rx_armed: bool = false,
    rx_limit: u16 = 0,
    rx_last_len: u16 = 0, // valid until ep_readv() consumes it
    // IN:
    tx_busy: bool = false,
};

fn PerEndpointArray(comptime N: comptime_int) type {
    return [N][2]EP_State; // [ep][dir]
}

fn epn(ep: types.Endpoint.Num) u4 {
    return @backingInt(ep);
}
fn speed_type(comptime cfg: Config) u2 {
    if (!cfg.prefer_high_speed) return 0; // FS
    return 1;
}

// --- USBHD token encodings ---
const TOKEN_OUT: u2 = 0;
const TOKEN_SOF: u2 = 1;
const TOKEN_IN: u2 = 2;
const TOKEN_SETUP: u2 = 3;

// --- endpoint response encodings ---
const RES_ACK: u2 = 0;
const RES_NAK: u2 = 2;
const RES_STALL: u2 = 3;

const TOG_DATA0: u2 = 0;
const TOG_DATA1: u2 = 1;

fn toggle_next(tog: u2) u2 {
    return if (tog == TOG_DATA0) TOG_DATA1 else TOG_DATA0;
}

// We use offset-based access for per-EP regs to keep helpers compact.
const Reg_U32 = microzig.mmio.Mmio(packed struct(u32) { v: u32 = 0 });
const Reg_U16 = microzig.mmio.Mmio(packed struct(u16) { v: u16 = 0 });
pub const RegCtrl = microzig.mmio.Mmio(packed struct(u8) {
    RES: u2 = 0,
    _reserved0: u1 = 0,
    TOG: u2 = 0,
    AUTO: bool = false,
    _reserved1: u2 = 0,
});

// RX DMA: 0x20 + (ep-1)*4  (EP1..EP15)
// EP0 has its own dedicated DMA reg.
const EP0_DMA: *Reg_U32 = @ptrFromInt(0x4002341c);
const UEP_RX_DMA: *volatile [15]Reg_U32 = if (@import("builtin").is_test) &test_poll_regs.rx_dma else @ptrFromInt(0x40023420);
const UEP_TX_DMA: *volatile [15]Reg_U32 = if (@import("builtin").is_test) &test_poll_regs.tx_dma else @ptrFromInt(0x4002345c);
const UEP_MAX_LEN: *volatile [15]Reg_U16 = if (@import("builtin").is_test) &test_poll_regs.max_len else @ptrFromInt(0x40023498);
const EP_Regs: *volatile [16]extern struct {
    UEP_T_LEN: Reg_U16,
    UEP_TX_CTRL: RegCtrl,
    UEP_RX_CTRL: RegCtrl,
} = if (@import("builtin").is_test) @ptrCast(&microzig.testing_io.hs_ep_regs) else @ptrFromInt(0x400234d8);

fn set_tx_ctrl(ep: u4, res: u2, tog: u2, auto: bool) void {
    // [1:0]=RES, [4:3]=TOG, [5]=AUTO
    const tx_ctrl: *volatile RegCtrl = &EP_Regs[ep].UEP_TX_CTRL;
    tx_ctrl.write(.{
        .RES = res,
        .TOG = tog,
        .AUTO = auto,
    });
}
fn set_rx_ctrl(ep: u4, res: u2, tog: u2, auto: bool) void {
    // std.log.debug("ch32: set_rx_ctrl ep={} res={} tog={} auto={}", .{ ep, res, tog, auto });
    const ctrl: *volatile RegCtrl = &EP_Regs[ep].UEP_RX_CTRL;
    ctrl.write(.{
        .RES = res,
        .TOG = tog,
        .AUTO = auto,
    });
}

fn current_rx_tog(ep: u4) u2 {
    const rx_ctrl: *volatile RegCtrl = &EP_Regs[ep].UEP_RX_CTRL;
    return rx_ctrl.read().TOG;
}
fn current_tx_tog(ep: u4) u2 {
    const tx_ctrl: *volatile RegCtrl = &EP_Regs[ep].UEP_TX_CTRL;
    return tx_ctrl.read().TOG;
}

/// Polled USBHS device backend for the MicroZig core USB controller.
pub fn Polled(comptime _: Setup, comptime cfg: Config) type {
    comptime {
        if (cfg.max_endpoints_count < 1)
            @compileError("USBHD max_endpoints_count must include endpoint 0");
        if (cfg.max_endpoints_count > USBHD_MAX_ENDPOINTS_COUNT)
            @compileError("USBHD max_endpoints_count cannot exceed 16");
        if (cfg.buffer_bytes < 128)
            @compileError("USBHD buffer_bytes must be at least 128");
        if (cfg.use_interrupts)
            @compileError("USBHD interrupt-driven operation is not supported");
    }

    return struct {
        const Self = @This();

        pub const device_capabilities: usb.DeviceCapabilities = .{
            .max_supported_bcd_usb = .v2_00,
            .max_packet_size0 = 64,
            .max_packet_size = 512,
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
            .control_out_data = true,
            .set_address = set_address,
        };

        endpoints: PerEndpointArray(cfg.max_endpoints_count),
        control: usb.ControlRequest = .{},
        discard_ep0_setup: bool = false,
        setup_data_transfer: enum { inactive, watching, retire } = .inactive,
        // USB DMA addresses must be 4-byte aligned.
        pool: [cfg.buffer_bytes]u8 align(4) = undefined,

        buffer_pool: []align(4) u8,

        interface: usb.DeviceInterface,

        pub fn init(self: *Self) void {
            log.info("USBHS init starting", .{});
            self.interface = .{ .vtable = &vtable };
            self.endpoints = @splat(@splat(.{}));
            self.discard_ep0_setup = false;
            self.setup_data_transfer = .inactive;
            @memset(self.pool[0..64], 0x7e);
            @memset(self.pool[64..], 0);

            self.buffer_pool = @alignCast(self.pool[64..]);

            usbhs_hw_init();

            // EP0 is required; open OUT then IN (or vice versa), we will share buffer.
            self.interface.ep_open(&.{
                .endpoint = .out(.ep0),
                .max_packet_size = .from(device_capabilities.max_packet_size0),
                .attributes = .{ .transfer_type = .Control, .usage = .data },
                .interval = 0,
            });
            self.interface.ep_open(&.{
                .endpoint = .in(.ep0),
                .max_packet_size = .from(device_capabilities.max_packet_size0),
                .attributes = .{ .transfer_type = .Control, .usage = .data },
                .interval = 0,
            });

            // EP0 OUT should always be able to accept status-stage OUT ZLP.
            // So keep EP0 RX in ACK state permanently.
            self.arm_ep0_out_always();

            // Connect pull-up to signal device ready
            Regs.USB_CTRL.modify(.{ .RB_UC_DEV_PU_EN = 1 });

            Regs.USB_CTRL.modify(.{
                .RB_UC_CLR_ALL = 0,
            });
        }

        // TODO: replace with fixedbuffer allocator?
        fn endpoint_alloc(self: *Self, size: usize) []align(4) u8 {
            assert(self.buffer_pool.len >= size);
            const out = self.buffer_pool[0..size];
            self.buffer_pool = @alignCast(self.buffer_pool[size..]);
            return out;
        }

        fn st(self: *Self, ep_num: types.Endpoint.Num, dir: types.Dir) *EP_State {
            return &self.endpoints[@backingInt(ep_num)][@backingInt(dir)];
        }

        fn arm_ep0_out_always(self: *Self) void {
            _ = self;
            // EP0 OUT is always ACK.
            set_rx_ctrl(0, RES_ACK, TOG_DATA0, false);
            // EP0 IN remains NAK until data is queued.
            // set_tx_ctrl(0, RES_NAK, TOG_DATA0, false);
        }

        fn on_bus_reset_local(self: *Self) void {
            self.control = .{};
            self.discard_ep0_setup = false;
            // Clear state
            inline for (0..cfg.max_endpoints_count) |i| {
                self.endpoints[i][@backingInt(types.Dir.out)].rx_armed = false;
                self.endpoints[i][@backingInt(types.Dir.out)].rx_last_len = 0;
                self.endpoints[i][@backingInt(types.Dir.in)].tx_busy = false;
            }

            // Default: NAK all non-EP0 endpoints.
            for (1..cfg.max_endpoints_count) |i| {
                const e: u4 = @as(u4, @intCast(i));
                set_rx_ctrl(e, RES_NAK, TOG_DATA0, false);
                set_tx_ctrl(e, RES_NAK, TOG_DATA0, false);
            }

            set_tx_ctrl(0, RES_NAK, TOG_DATA0, false);
            self.arm_ep0_out_always();
        }

        fn read_setup_from_ep0(self: *Self) types.SetupPacket {
            const ep0 = self.st(.ep0, .out);
            assert(ep0.buf.len >= 8);
            const words_ptr: *align(4) const volatile [2]u32 = @ptrCast(ep0.buf.ptr);
            return @bitCast(words_ptr.*);
        }

        // ---- comptime dispatch helpers (required by DeviceController API) ----

        fn call_on_buffer(self: *Self, dir: types.Dir, ep: u4, controller: anytype) void {
            // controller.on_buffer requires comptime ep parameter
            switch (dir) {
                .in => switch (ep) {
                    inline 0...15 => |i| {
                        const num: types.Endpoint.Num = @fromBackingInt(i);
                        controller.on_buffer(&self.interface, .{ .num = num, .dir = .in });
                    },
                },
                .out => switch (ep) {
                    inline 0...15 => |i| {
                        const num: types.Endpoint.Num = @fromBackingInt(i);
                        controller.on_buffer(&self.interface, .{ .num = num, .dir = .out });
                    },
                },
            }
        }

        // ---- Poll loop -------------------------------------------------------

        pub fn poll(self: *Self, in_isr: bool, controller: anytype) void {
            _ = in_isr;

            while (true) {
                const flags = PollRegs.USB_INT_FG.read();
                if (flags.RB_UIF_HST_SOF == 0 and flags.RB_UIF_SUSPEND == 0 and
                    flags.RB_UIF_FIFO_OV == 0 and flags.RB_UIF_BUS_RST__RB_UIF_DETECT == 0 and
                    flags.RB_UIF_SETUP_ACT == 0 and flags.RB_UIF_TRANSFER == 0)
                    break;

                if (flags.RB_UIF_HST_SOF != 0) {
                    // acknowledge SOF but ignore
                    PollRegs.USB_INT_FG.write(.{
                        .RB_UIF_HST_SOF = 1,
                        .RB_UIF_SETUP_ACT = 0,
                    });
                }
                if (flags.RB_UIF_SUSPEND != 0) {
                    // acknowledge SUSPEND but ignore
                    PollRegs.USB_INT_FG.write(.{
                        .RB_UIF_SUSPEND = 1,
                        .RB_UIF_SETUP_ACT = 0,
                    });
                }

                if (flags.RB_UIF_FIFO_OV != 0) {
                    log.warn("FIFO overflow!", .{});
                    PollRegs.USB_INT_FG.write(.{
                        .RB_UIF_FIFO_OV = 1,
                        .RB_UIF_SETUP_ACT = 0,
                    });
                }

                if (flags.RB_UIF_BUS_RST__RB_UIF_DETECT != 0) {
                    // Reset and SETUP_ACT can latch independently of the
                    // TRANSFER busy interlock (CH32FV2x_V3x RM v2.5,
                    // §22.2.1.1, §22.2.1.8–9). Retire them before reopening EP0.
                    PollRegs.USB_INT_FG.write(.{
                        .RB_UIF_BUS_RST__RB_UIF_DETECT = 1,
                        .RB_UIF_SETUP_ACT = flags.RB_UIF_SETUP_ACT,
                    });
                    self.on_bus_reset_local();
                    set_address(&self.interface, 0);
                    if (flags.RB_UIF_TRANSFER != 0) {
                        PollRegs.USB_INT_FG.write(.{
                            .RB_UIF_TRANSFER = 1,
                            .RB_UIF_SETUP_ACT = 0,
                        });
                    }
                    log.debug("bus reset", .{});
                    controller.on_bus_reset(&self.interface);
                    continue;
                }

                if (flags.RB_UIF_SETUP_ACT != 0) {
                    // SETUP supersedes EP0 transactions. A data endpoint's
                    // completion stays pending for the normal transfer path.
                    // CH32FV2x_V3x RM v2.5, §22.2.1.8–9 (USB_INT_FG/USB_INT_ST).
                    const retire_ep0_transfer = flags.RB_UIF_TRANSFER != 0 and blk: {
                        const status = PollRegs.USB_INT_ST.read();
                        break :blk status.MASK_UIS_H_RES__MASK_UIS_ENDP == 0 and status.MASK_UIS_TOKEN != TOKEN_SOF;
                    };
                    if (self.discard_ep0_setup) {
                        self.discard_ep0_setup = false;
                        self.control = .{};
                        PollRegs.USB_INT_FG.write(.{
                            .RB_UIF_SETUP_ACT = 1,
                            .RB_UIF_TRANSFER = @intFromBool(retire_ep0_transfer),
                        });
                        continue;
                    }
                    const setup = self.read_setup_from_ep0();
                    // SETUP_ACT can latch without TRANSFER holding the SIE
                    // busy. Acknowledge the copied SETUP before dispatch.
                    PollRegs.USB_INT_FG.write(.{ .RB_UIF_SETUP_ACT = 1 });
                    self.setup_data_transfer = .watching;
                    self.handle_setup(&setup, controller);

                    // Hold TRANSFER through reply publication, including when
                    // the callback retires the endpoint that owns it.
                    const retire_transfer = retire_ep0_transfer or self.setup_data_transfer == .retire;
                    self.setup_data_transfer = .inactive;
                    if (retire_transfer) {
                        PollRegs.USB_INT_FG.write(.{
                            .RB_UIF_SETUP_ACT = 0,
                            .RB_UIF_TRANSFER = 1,
                        });
                    }
                    continue;
                }

                if (flags.RB_UIF_TRANSFER != 0) {
                    const stv = PollRegs.USB_INT_ST.read();
                    const ep: u4 = @as(u4, stv.MASK_UIS_H_RES__MASK_UIS_ENDP);
                    const token: u2 = @as(u2, stv.MASK_UIS_TOKEN);
                    // INT_BUSY holds the transaction and DMA buffer until W1C.
                    self.handle_transfer(ep, token, controller);
                    PollRegs.USB_INT_FG.write(.{
                        .RB_UIF_TRANSFER = 1,
                        .RB_UIF_SETUP_ACT = 0,
                    });
                }
            }
        }

        fn handle_setup(self: *Self, setup: *const types.SetupPacket, controller: anytype) void {
            set_tx_ctrl(0, RES_NAK, TOG_DATA1, false);
            set_rx_ctrl(0, RES_NAK, TOG_DATA1, false);
            self.st(.ep0, .in).tx_busy = false;
            self.control.setup(setup);
            controller.on_setup_req(&self.interface, setup);
            if (self.control.needs_stall()) self.stall_control();
        }

        fn handle_transfer(self: *Self, ep: u4, token: u2, controller: anytype) void {
            if (ep >= cfg.max_endpoints_count) return;
            switch (token) {
                TOKEN_OUT => self.handle_out(ep, controller),
                TOKEN_SOF => {},
                TOKEN_IN => self.handle_in(ep, controller),
                TOKEN_SETUP => {
                    // SETUP can also be reported through TRANSFER alone.
                    if (ep == 0) {
                        const setup = self.read_setup_from_ep0();
                        self.handle_setup(&setup, controller);
                    }
                },
            }
        }

        pub const testing = if (@import("builtin").is_test) struct {
            pub fn duplicate_out() !void {
                const FakeController = struct {
                    data: [128]u8 = undefined,
                    len: usize = 0,
                    calls: usize = 0,
                    pub fn on_buffer(ctl: *@This(), itf: *usb.DeviceInterface, comptime ep: types.Endpoint) void {
                        const dev: *Self = @fieldParentPtr("interface", itf);
                        ctl.calls += 1;
                        ctl.len += Self.ep_readv(itf, ep.num, &.{ctl.data[ctl.len..]});
                        if (ctl.len < 128) Self.ep_listen(itf, .ep0, 64) else dev.control.reply();
                    }
                };
                var buf: [64]u8 align(4) = @splat(0xA1);
                var dev: Self = undefined;
                dev.endpoints = @splat(@splat(.{}));
                dev.control = .{ .direction = .out, .out_data = true };
                dev.st(.ep0, .out).buf = &buf;
                var ctl: FakeController = .{};
                set_rx_ctrl(0, RES_ACK, TOG_DATA1, false);
                dev.control.listen();
                Regs.USB_RX_LEN.raw = 64;
                Regs.USB_INT_ST.raw = 1;
                dev.handle_out(0, &ctl);
                try std.testing.expectEqual(64, ctl.len);
                const rx = EP_Regs[0].UEP_RX_CTRL.raw;
                const answered = dev.control.answered;
                Regs.USB_INT_ST.raw = 0;
                dev.handle_out(0, &ctl); // ACK for A was lost: A is retransmitted.
                try std.testing.expectEqual(1, ctl.calls);
                try std.testing.expectEqual(64, ctl.len);
                try std.testing.expectEqual(0, dev.st(.ep0, .out).rx_last_len);
                try std.testing.expectEqual(rx, EP_Regs[0].UEP_RX_CTRL.raw);
                try std.testing.expectEqual(answered, dev.control.answered);
                @memset(&buf, 0xB2);
                Regs.USB_INT_ST.raw = 1;
                dev.handle_out(0, &ctl);
                try std.testing.expectEqual(2, ctl.calls);
                try std.testing.expectEqual(128, ctl.len);
                try std.testing.expectEqualSlices(u8, &@as([64]u8, @splat(0xA1)), ctl.data[0..64]);
                try std.testing.expectEqualSlices(u8, &@as([64]u8, @splat(0xB2)), ctl.data[64..]);
            }
        } else struct {};

        fn handle_out(self: *Self, ep: u4, controller: anytype) void {
            const len: u16 = Regs.USB_RX_LEN.read().R16_USB_RX_LEN;
            const stv = Regs.USB_INT_ST.read();
            const rx_ctrl_reg: *volatile RegCtrl = &EP_Regs[ep].UEP_RX_CTRL;
            const rx_ctrl = rx_ctrl_reg.read();
            log.debug(
                "OUT ep{} len={} tog_ok={} rx_res={} rx_tog={}",
                .{ ep, len, stv.RB_UIS_TOG_OK, rx_ctrl.RES, rx_ctrl.TOG },
            );
            // CH32FV2x_V3x RM v2.2, 22.2.2 / 23.2.2: a duplicate OUT
            // must not consume data or advance the expected toggle, including EP0.
            if (stv.RB_UIS_TOG_OK == 0) return;

            if (ep == 0) {
                const next = toggle_next(rx_ctrl.TOG);
                if (!self.control.out_packet()) {
                    // ACK a control-read status retry, and let TOG_OK filter
                    // the duplicate (USB 2.0 §8.6.4, CH32FV2x_V3x RM
                    // v2.5 §22.2.2.10, UEP_R_RES and UEP_R_TOG).
                    const status_out = self.control.direction == .in and self.control.answered;
                    set_rx_ctrl(0, if (status_out) RES_ACK else RES_NAK, next, false);
                    return;
                }

                // Data OUT waits for the controller to accept or rearm it.
                self.st(.ep0, .out).rx_last_len = len;
                set_rx_ctrl(0, RES_NAK, next, false);
                self.call_on_buffer(.out, 0, controller);
                if (self.control.needs_stall()) self.stall_control();
                return;
            }

            const num: types.Endpoint.Num = @fromBackingInt(ep);
            const st_out = self.st(num, .out);

            // Only read if previously armed (ep_listen)
            if (!st_out.rx_armed) {
                // set_rx_ctrl(ep, RES_NAK, TOG_DATA0, true);
                return;
            }

            // Disarm immediately (NAK) to regain ownership.
            st_out.rx_armed = false;
            const next = toggle_next(current_rx_tog(ep));
            set_rx_ctrl(ep, RES_NAK, next, false);

            const n = @min(@as(usize, len), st_out.buf.len);
            st_out.rx_last_len = @as(u16, @intCast(n));

            self.call_on_buffer(.out, ep, controller);
        }

        // IN => into host from device
        fn handle_in(self: *Self, ep: u4, controller: anytype) void {
            const num: types.Endpoint.Num = @fromBackingInt(ep);
            const st_in = self.st(num, .in);

            if (!st_in.tx_busy) {
                set_tx_ctrl(ep, RES_NAK, current_tx_tog(ep), false);
                return;
            }

            // Mark free before calling on_buffer(), so EP0_IN logic can immediately queue next chunk.
            st_in.tx_busy = false;
            const next = toggle_next(current_tx_tog(ep));
            set_tx_ctrl(ep, RES_NAK, next, false);

            // Notify controller/drivers of IN completion.
            self.call_on_buffer(.in, ep, controller);
        }

        // ---- VTable functions ------------------------------------------------

        fn set_address(_: *usb.DeviceInterface, addr: u7) void {
            log.info("set_address {}", .{addr});
            PollRegs.USB_DEV_AD.modify(.{ .MASK_USB_ADDR = addr });
        }

        fn stall_control(self: *Self) void {
            // USB 2.0, 9.2.7 / 8.5.3.4; CH32FV2x_V3x RM v2.2,
            // 22.2.2.9-10, UEP_T_RES / UEP_R_RES.
            self.control = .{};
            set_tx_ctrl(0, RES_STALL, current_tx_tog(0), false);
            set_rx_ctrl(0, RES_STALL, current_rx_tog(0), false);
        }

        fn retire_setup_data_transfer(self: *Self, endpoint: ?types.Endpoint) void {
            if (self.setup_data_transfer != .watching or PollRegs.USB_INT_FG.read().RB_UIF_TRANSFER == 0) return;
            const status = PollRegs.USB_INT_ST.read();
            const ep = status.MASK_UIS_H_RES__MASK_UIS_ENDP;
            if (ep == 0) return;
            const dir: types.Dir = switch (status.MASK_UIS_TOKEN) {
                TOKEN_OUT => .out,
                TOKEN_IN => .in,
                else => return,
            };
            if (endpoint) |e| {
                if (ep != epn(e.num) or dir != e.dir) return;
            }
            self.setup_data_transfer = .retire;
        }

        fn ep_close_all(itf: *usb.DeviceInterface) void {
            const self: *Self = @fieldParentPtr("interface", itf);
            for (1..cfg.max_endpoints_count) |i| {
                const ep: u4 = @intCast(i);
                set_tx_ctrl(ep, RES_NAK, TOG_DATA0, false);
                set_rx_ctrl(ep, RES_NAK, TOG_DATA0, false);
                self.st(@fromBackingInt(ep), .in).tx_busy = false;
                self.st(@fromBackingInt(ep), .out).rx_armed = false;
                self.st(@fromBackingInt(ep), .out).rx_last_len = 0;
            }
            // CH32FV2x_V3x RM v2.2, 22.2.2.1, UEP_CONFIG: EP0 remains
            // available for the next SETUP; all data endpoint directions are disabled.
            PollRegs.UEP_CONFIG__UHOST_CTRL.write_raw(0);
            PollRegs.UEP_TYPE.write_raw(0);
            self.retire_setup_data_transfer(null);
        }

        fn ep_open(itf: *usb.DeviceInterface, desc_ptr: *const descriptor.Endpoint) void {
            const self: *Self = @fieldParentPtr("interface", itf);
            const desc = desc_ptr.*;

            const e = desc.endpoint;
            const ep_i: u4 = epn(e.num);
            assert(ep_i < cfg.max_endpoints_count);
            log.info("ep_open called for ep{}", .{ep_i});

            const mps: u16 = desc.max_packet_size.native();
            assert(mps > 0 and mps <= 2047);

            // EP0 shares a single DMA buffer for both directions.
            if (e.num == .ep0) {
                const out_st = self.st(.ep0, .out);
                const in_st = self.st(.ep0, .in);
                const dma: *volatile Reg_U32 = EP0_DMA;
                if (dma.raw == 0) {
                    log.warn("EP0 DMA is null!", .{});
                }
                if (out_st.buf.len == 0 and in_st.buf.len == 0) {
                    // this should probably be fixed at 64 bytes for EP0 for HS?
                    const buf = self.endpoint_alloc(64);
                    out_st.buf = buf;
                    in_st.buf = buf;

                    const ptr_val = @as(u32, @intCast(@intFromPtr(buf.ptr)));
                    log.debug("Setting EP0 DMA buffer at {x}, len={}", .{ ptr_val, buf.len });
                    dma.raw = ptr_val;
                    const max_len: *volatile Reg_U16 = &UEP_MAX_LEN[0];
                    max_len.raw = @intCast(64);
                } else {
                    // Ensure both directions point at the same backing buffer.
                    if (out_st.buf.len == 0) out_st.buf = in_st.buf;
                    if (in_st.buf.len == 0) in_st.buf = out_st.buf;
                }
            } else {
                log.debug("ep_open ep{} dir={}", .{ ep_i, e.dir });
                // Non-EP0: separate DMA buffers per direction
                const st_ep = self.st(e.num, e.dir);

                if (st_ep.buf.len == 0) {
                    st_ep.buf = self.endpoint_alloc(@as(usize, 512));
                }

                const ptr_val: u32 = @truncate(@intFromPtr(st_ep.buf.ptr));

                // The host can configure again without a bus reset (SET_CONFIGURATION), so an
                // endpoint may be opened while a packet from its previous configuration is still
                // armed. Withdraw the packet and retire any latched completion before reuse.
                switch (e.dir) {
                    .out => set_rx_ctrl(ep_i, RES_NAK, TOG_DATA0, false),
                    .in => set_tx_ctrl(ep_i, RES_NAK, TOG_DATA0, false),
                }
                self.retire_setup_data_transfer(e);
                if (e.dir == .out) {
                    const rx_dma: *volatile Reg_U32 = &UEP_RX_DMA[ep_i - 1];
                    rx_dma.raw = ptr_val;
                    const max_len: *volatile Reg_U16 = &UEP_MAX_LEN[ep_i];
                    max_len.raw = mps;
                    st_ep.rx_armed = false;
                    st_ep.rx_last_len = 0;
                } else {
                    const tx_dma: *volatile Reg_U32 = &UEP_TX_DMA[ep_i - 1];
                    tx_dma.raw = ptr_val;
                    st_ep.tx_busy = false;
                }
            }
            log.debug("allocation and DMA setup done for ep{}", .{ep_i});

            const tx_len: *volatile Reg_U16 = &EP_Regs[ep_i].UEP_T_LEN;
            tx_len.raw = 0;

            // Enable endpoint direction in UEP_CONFIG bitmaps.
            // TODO: make this a function, too ugly here
            var cfg_raw: u32 = PollRegs.UEP_CONFIG__UHOST_CTRL.raw;
            if (e.num != .ep0) {
                if (e.dir == .in) cfg_raw |= (@as(u32, 1) << ep_i) else cfg_raw |= (@as(u32, 1) << (16 + @as(u5, ep_i)));
            }
            PollRegs.UEP_CONFIG__UHOST_CTRL.raw = cfg_raw;

            // Endpoint type ISO marking (only for ISO endpoints).
            if (e.num != .ep0 and desc.attributes.transfer_type == .Isochronous) {
                var type_raw: u32 = PollRegs.UEP_TYPE.raw;
                if (e.dir == .in) type_raw |= (@as(u32, 1) << ep_i) else type_raw |= (@as(u32, 1) << (16 + @as(u5, ep_i)));
                PollRegs.UEP_TYPE.raw = type_raw;
            }

            // EP0 OUT always ACK
            if (e.num == .ep0 and e.dir == .out) {
                self.arm_ep0_out_always();
            }

            log.debug("ep_open completed for ep{}", .{ep_i});
        }

        fn ep_listen(itf: *usb.DeviceInterface, ep_num: types.Endpoint.Num, len: types.PacketLength) void {
            log.info("ep_listen called for ep{} len={}", .{ ep_num, len });
            const self: *Self = @fieldParentPtr("interface", itf);

            // EP0 data OUT is armed only when the controller asks for it.
            if (ep_num == .ep0) {
                const st0 = self.st(.ep0, .out);
                st0.rx_limit = @as(u16, @intCast(len));
                self.control.listen();
                set_rx_ctrl(0, RES_ACK, current_rx_tog(0), false);
                // set_rx_ctrl(0, RES_ACK, TOG_DATA0, true);
                return;
            }

            const ep_i: u4 = epn(ep_num);
            if (ep_i >= cfg.max_endpoints_count)
                @panic("ep_listen called for invalid endpoint");

            const st_out = self.st(ep_num, .out);
            if (st_out.buf.len == 0)
                @panic("ep_listen called for endpoint with no buffer allocated");

            // Must not be called again until packet received.
            if (st_out.rx_armed)
                @panic("ep_listen called while OUT endpoint already armed");

            const limit = @min(st_out.buf.len, @as(usize, @intCast(len)));
            st_out.rx_limit = @as(u16, @intCast(limit));
            st_out.rx_armed = true;
            st_out.rx_last_len = 0;

            const max_len: *volatile Reg_U16 = &UEP_MAX_LEN[ep_i];
            max_len.raw = @as(u16, @intCast(limit));

            asm volatile ("");
            set_rx_ctrl(ep_i, RES_ACK, current_rx_tog(ep_i), false);
        }

        fn ep_readv(itf: *usb.DeviceInterface, ep_num: types.Endpoint.Num, data: []const []u8) types.PacketLength {
            const self: *Self = @fieldParentPtr("interface", itf);

            const st_out = self.st(ep_num, .out);
            assert(st_out.buf.len != 0);

            const want: usize = @as(usize, st_out.rx_last_len);
            assert(want <= st_out.buf.len);

            // Must be called exactly once per received packet.
            // Enforce by clearing rx_last_len after consumption.
            defer st_out.rx_last_len = 0;

            var remaining: []u8 = st_out.buf[0..want];
            var copied: usize = 0;

            for (data) |dst| {
                if (remaining.len == 0) break;
                const n = @min(dst.len, remaining.len);
                @memcpy(dst[0..n], remaining[0..n]);
                remaining = remaining[n..];
                copied += n;
            }

            // Driver is responsible for re-arming via ep_listen().
            return @intCast(copied);
        }

        fn ep_writev(itf: *usb.DeviceInterface, ep_num: types.Endpoint.Num, vec: []const []const u8) types.PacketLength {
            const self: *Self = @fieldParentPtr("interface", itf);
            assert(vec.len > 0);

            const ep_i: u4 = epn(ep_num);
            assert(ep_i < cfg.max_endpoints_count);

            const st_in = self.st(ep_num, .in);
            assert(st_in.buf.len != 0);

            if (st_in.tx_busy) {
                log.warn("ep_writev called while {} IN endpoint busy, returning 0", .{ep_num});
                return 0;
            }

            if (ep_num == .ep0) {
                self.control.reply();
                // Preserve an intact SETUP and its latch for the next poll.
                if (PollRegs.USB_INT_FG.read().RB_UIF_SETUP_ACT != 0) return 0;
            }

            // Copy vector into DMA buffer (up to MPS/buffer size)
            var w: usize = 0;
            for (vec) |chunk| {
                if (w >= st_in.buf.len) break;
                const n = @min(chunk.len, st_in.buf.len - w);
                @memcpy(st_in.buf[w .. w + n], chunk[0..n]);
                w += n;
            }

            if (ep_num == .ep0) {
                // USBHS uses one EP0 DMA address for both directions
                // (CH32FV2x_V3x RM v2.5, §22.2.2). SETUP_ACT can latch
                // independently of the TRANSFER interlock (§22.2.1.1, §22.2.1.8).
                // A SETUP accepted during this copy may no longer
                // contain a valid request. Drop the reply and let the host retry.
                // A new SETUP can still latch between this final check and
                // the TX arm because the register operations are separate.
                if (PollRegs.USB_INT_FG.read().RB_UIF_SETUP_ACT != 0) {
                    if (w != 0) self.discard_ep0_setup = true;
                    set_tx_ctrl(0, RES_NAK, TOG_DATA0, false);
                    self.arm_ep0_out_always();
                    return 0;
                }
                if (self.control.direction == .in)
                    set_rx_ctrl(0, RES_ACK, current_rx_tog(0), false);
            }

            const tx_len: *volatile Reg_U16 = &EP_Regs[ep_i].UEP_T_LEN;
            tx_len.raw = @as(u16, @intCast(w));

            st_in.tx_busy = true;
            // Arm IN

            set_tx_ctrl(ep_i, RES_ACK, current_tx_tog(ep_i), false);

            // For ZLP ACK, usb.DeviceInterface.ep_ack() expects ep_writev() returns 0.
            return @intCast(w);
        }

        // ---- HW init ---------------------------------------------------------

        fn usbhs_hw_init() void {
            log.info("USBHS hw_init starting", .{});

            // Reset SIE and clear FIFO
            Regs.UHOST_CTRL.raw = 0;
            Regs.UHOST_CTRL.modify(.{ .RB_UH_PHY_SUSPENDM = 1 });
            Regs.USB_CTRL.raw = 0; // not sure if writing zero then val is ok?
            Regs.USB_CTRL.modify(.{
                .RB_UC_CLR_ALL = 1,
                .RB_UC_RST_SIE = 1,
                .RB_UC_INT_BUSY = 1,
            });
            // wait 10us, TODO: replace with timer delay
            var i: u32 = 0;
            while (i < 1440) : (i += 1) {
                asm volatile ("nop");
            }

            Regs.USB_CTRL.modify(.{
                .RB_UC_RST_SIE = 0,
            });

            Regs.USB_CTRL.modify(.{
                .RB_UC_DMA_EN = 1,
                .RB_UC_INT_BUSY = 1,
                .RB_UC_SPEED_TYPE = speed_type(cfg),
            });

            // Enable source interrupts (we poll these flags, interrupt disabled)
            Regs.USB_INT_EN.modify(.{
                .RB_U_1WIRE_MODE = 1, // actually SETUP_ACT?
                .RB_UIE_BUS_RST__RB_UIE_DETECT = 1,
                .RB_UIE_TRANSFER = 1,
                .RB_UIE_SUSPEND = 1,
                .RB_UIE_FIFO_OV = 1,
                // .RB_UIE_HST_SOF = 1,
            });
        }
    };
}

///! Skeleton ISR
pub fn usbhs_interrupt_handler() callconv(microzig.cpu.riscv_calling_convention) void {
    Regs.USB_INT_FG.write(Regs.USB_INT_FG.read());
    @panic("Don't Enable USBHS Interrupt, Not yet supported!");
}

test "USBHS bus reset discards pending SETUP" {
    const Device = Polled(.{}, .{});
    const Controller = struct {
        resets: usize = 0,
        setups: usize = 0,
        setup_during_reset: bool = false,
        second_reset: bool = false,

        pub fn on_bus_reset(self: *@This(), _: *usb.DeviceInterface) void {
            self.resets += 1;
            if (self.setup_during_reset) {
                self.setup_during_reset = false;
                test_poll_regs.USB_INT_FG.pending.RB_UIF_SETUP_ACT = 1;
            }
            if (self.second_reset) {
                self.second_reset = false;
                test_poll_regs.USB_INT_FG.pending.RB_UIF_BUS_RST__RB_UIF_DETECT = 1;
            }
        }

        pub fn on_setup_req(self: *@This(), _: *usb.DeviceInterface, _: *const types.SetupPacket) void {
            self.setups += 1;
        }

        pub fn on_buffer(_: *@This(), _: *usb.DeviceInterface, comptime _: types.Endpoint) void {
            unreachable;
        }
    };
    var dev: Device = undefined;
    dev.endpoints = @splat(@splat(.{}));
    dev.discard_ep0_setup = false;
    var setup: [8]u8 align(4) = .{ 0, 9, 1, 0, 0, 0, 0, 0 }; // SET_CONFIGURATION(1)
    dev.st(.ep0, .out).buf = &setup;
    var ctl: Controller = .{};
    test_poll_regs.USB_INT_ST.write(.{ .MASK_UIS_TOKEN = TOKEN_SETUP });

    for ([_]TestFlags{
        .{ .RB_UIF_BUS_RST__RB_UIF_DETECT = 1, .RB_UIF_SETUP_ACT = 0, .RB_UIF_TRANSFER = 1 },
        .{ .RB_UIF_BUS_RST__RB_UIF_DETECT = 1, .RB_UIF_SETUP_ACT = 1 },
        .{ .RB_UIF_BUS_RST__RB_UIF_DETECT = 1, .RB_UIF_SETUP_ACT = 1, .RB_UIF_TRANSFER = 1 },
    }, 1..) |pending, resets| {
        set_tx_ctrl(0, RES_ACK, TOG_DATA1, false);
        test_poll_regs.USB_INT_FG.pending = pending;
        dev.poll(false, &ctl);
        try std.testing.expectEqual(resets, ctl.resets);
        try std.testing.expectEqual(RES_NAK, EP_Regs[0].UEP_TX_CTRL.read().RES);
        try std.testing.expectEqual(0, ctl.setups);
        try std.testing.expectEqual(TestFlags{ .RB_UIF_SETUP_ACT = 0 }, test_poll_regs.USB_INT_FG.pending);
    }

    test_poll_regs.USB_INT_FG.pending = .{ .RB_UIF_SETUP_ACT = 1 };
    dev.poll(false, &ctl);
    test_poll_regs.USB_INT_FG.pending = .{ .RB_UIF_SETUP_ACT = 0, .RB_UIF_TRANSFER = 1 };
    dev.poll(false, &ctl);
    try std.testing.expectEqual(2, ctl.setups);
    // A flag outside the reset snapshot remains pending.
    ctl.setup_during_reset = true;
    test_poll_regs.USB_INT_FG.pending = .{ .RB_UIF_BUS_RST__RB_UIF_DETECT = 1, .RB_UIF_SETUP_ACT = 0 };
    dev.poll(false, &ctl);
    try std.testing.expectEqual(3, ctl.setups);

    // A SETUP that arrived before a second reset must be discarded.
    const resets = ctl.resets;
    const setups = ctl.setups;
    ctl.setup_during_reset = true;
    ctl.second_reset = true;
    test_poll_regs.USB_INT_FG.pending = .{ .RB_UIF_BUS_RST__RB_UIF_DETECT = 1, .RB_UIF_SETUP_ACT = 0 };
    dev.poll(false, &ctl);
    dev.poll(false, &ctl);
    try std.testing.expectEqual(resets + 2, ctl.resets);
    try std.testing.expectEqual(setups, ctl.setups);
}

fn expect_setup_during_callback(comptime reset: bool, comptime reply: enum { none, pending_setup, racing_setup }) !void {
    const Device = Polled(.{}, .{});
    const get_descriptor = [8]u8{ 0x80, 6, 0, 1, 0, 0, 18, 0 };
    const set_address_request = [8]u8{ 0, 5, 2, 0, 0, 0, 0, 0 };
    const Controller = struct {
        requests: [3][8]u8 = undefined,
        count: usize = 0,

        pub fn on_bus_reset(_: *@This(), itf: *usb.DeviceInterface) void {
            latch_setup(itf);
        }

        pub fn on_setup_req(self: *@This(), itf: *usb.DeviceInterface, packet: *const types.SetupPacket) void {
            const raw: [8]u8 = @bitCast(packet.*);
            if (std.mem.eql(u8, &raw, &get_descriptor)) {
                if (reply == .racing_setup) {
                    // Surface the event on the post-copy read.
                    test_poll_regs.USB_INT_FG.reads_until_setup = 2;
                } else {
                    latch_setup(itf);
                }
                if (reply != .none) {
                    const dev: *Device = @fieldParentPtr("interface", itf);
                    const written = Device.ep_writev(itf, .ep0, &.{"\x12\x01\x00\x02\x00\x00\x00\x40"});
                    assert(written == 0);
                    assert(test_poll_regs.USB_INT_FG.pending.RB_UIF_SETUP_ACT == 1);
                    assert(!dev.st(.ep0, .in).tx_busy);
                }
            }
            self.requests[self.count] = @bitCast(packet.*);
            self.count += 1;
        }

        fn latch_setup(itf: *usb.DeviceInterface) void {
            const dev: *Device = @fieldParentPtr("interface", itf);
            dev.st(.ep0, .out).buf[0..8].* = set_address_request;
            test_poll_regs.USB_INT_FG.pending.RB_UIF_SETUP_ACT = 1;
        }

        pub fn on_buffer(_: *@This(), _: *usb.DeviceInterface, comptime _: types.Endpoint) void {
            unreachable;
        }
    };
    var dev: Device = undefined;
    dev.endpoints = @splat(@splat(.{}));
    dev.discard_ep0_setup = false;
    var dma: [64]u8 align(4) = undefined;
    dma[0..8].* = get_descriptor;
    dev.st(.ep0, .out).buf = &dma;
    dev.st(.ep0, .in).buf = &dma;

    var ctl: Controller = .{};
    test_poll_regs.USB_INT_FG.pending = .{ .RB_UIF_BUS_RST__RB_UIF_DETECT = @intFromBool(reset), .RB_UIF_SETUP_ACT = 1 };
    dev.poll(false, &ctl);
    const expected: []const [8]u8 = if (reset) &.{set_address_request} else if (reply == .racing_setup) &.{get_descriptor} else &.{ get_descriptor, set_address_request };
    try std.testing.expectEqualSlices([8]u8, expected, ctl.requests[0..ctl.count]);
    if (reply == .racing_setup) {
        try std.testing.expectEqual(0, test_poll_regs.USB_INT_FG.pending.RB_UIF_SETUP_ACT);
        try std.testing.expectEqual(RES_NAK, EP_Regs[0].UEP_TX_CTRL.read().RES);
        try std.testing.expectEqual(RES_ACK, EP_Regs[0].UEP_RX_CTRL.read().RES);
        try std.testing.expect(!dev.st(.ep0, .in).tx_busy);

        Controller.latch_setup(&dev.interface);
        dev.poll(false, &ctl);
        try std.testing.expectEqualSlices([8]u8, &.{ get_descriptor, set_address_request }, ctl.requests[0..ctl.count]);
    }
}

test "USBHS preserves a SETUP accepted during a reset callback" {
    try expect_setup_during_callback(true, .none);
}

test "USBHS preserves a SETUP accepted during a SETUP callback" {
    try expect_setup_during_callback(false, .none);
}

test "USBHS preserves a pending SETUP when the previous reply starts" {
    try expect_setup_during_callback(false, .pending_setup);
}

test "USBHS drops SETUP bytes overwritten by a control reply and accepts the retry" {
    try expect_setup_during_callback(false, .racing_setup);
}

fn expect_transfer_co_latched_with_setup(discard: bool) !void {
    const Device = Polled(.{}, .{});
    const Controller = struct {
        setups: usize = 0,
        completions: usize = 0,

        pub fn on_bus_reset(_: *@This(), _: *usb.DeviceInterface) void {
            unreachable;
        }

        pub fn on_setup_req(self: *@This(), _: *usb.DeviceInterface, _: *const types.SetupPacket) void {
            self.setups += 1;
        }

        pub fn on_buffer(self: *@This(), _: *usb.DeviceInterface, comptime ep: types.Endpoint) void {
            assert(ep.num == .ep1 and ep.dir == .in);
            self.completions += 1;
        }
    };
    var setup: [8]u8 align(4) = .{ 0x80, 6, 0, 1, 0, 0, 18, 0 }; // GET_DESCRIPTOR
    for ([_]TestStatus{
        .{ .MASK_UIS_TOKEN = TOKEN_IN, .MASK_UIS_H_RES__MASK_UIS_ENDP = 1 },
        .{ .MASK_UIS_TOKEN = TOKEN_SETUP },
    }) |status| {
        var dev: Device = undefined;
        dev.endpoints = @splat(@splat(.{}));
        dev.control = .{};
        dev.discard_ep0_setup = discard;
        dev.st(.ep0, .out).buf = &setup;
        const data_in = status.MASK_UIS_TOKEN == TOKEN_IN;
        dev.st(.ep1, .in).tx_busy = data_in;
        var ctl: Controller = .{};

        test_poll_regs.USB_INT_ST.write(status);
        test_poll_regs.USB_INT_FG.pending = .{ .RB_UIF_SETUP_ACT = 1, .RB_UIF_TRANSFER = 1 };
        dev.poll(false, &ctl);

        try std.testing.expectEqual(@as(usize, @intFromBool(!discard)), ctl.setups);
        try std.testing.expectEqual(@as(usize, @intFromBool(data_in)), ctl.completions);
        try std.testing.expect(!dev.st(.ep1, .in).tx_busy);
        try std.testing.expectEqual(TestFlags{ .RB_UIF_SETUP_ACT = 0 }, test_poll_regs.USB_INT_FG.pending);
    }
}

test "USBHS preserves a data IN completion alongside SETUP" {
    try expect_transfer_co_latched_with_setup(false);
}

test "USBHS preserves a data IN completion when discarding SETUP" {
    try expect_transfer_co_latched_with_setup(true);
}

fn expect_reopened_endpoint_drops_old_completion(comptime dir: types.Dir) !void {
    const Device = Polled(.{}, .{});
    const Controller = struct {
        close_first: bool,
        completions: usize = 0,

        pub fn on_bus_reset(_: *@This(), _: *usb.DeviceInterface) void {
            unreachable;
        }

        pub fn on_setup_req(self: *@This(), itf: *usb.DeviceInterface, _: *const types.SetupPacket) void {
            if (self.close_first) itf.vtable.ep_close_all.?(itf);
            itf.ep_open(&.{
                .endpoint = .{ .num = .ep1, .dir = dir },
                .attributes = .{ .transfer_type = .Bulk, .usage = .data },
                .max_packet_size = .from(64),
                .interval = 0,
            });
            switch (dir) {
                .out => itf.ep_listen(.ep1, 64),
                .in => assert(itf.ep_writev(.ep1, &.{"new"}) == 3),
            }
        }

        pub fn on_buffer(self: *@This(), _: *usb.DeviceInterface, comptime ep: types.Endpoint) void {
            assert(ep.num == .ep1 and ep.dir == dir);
            self.completions += 1;
        }
    };
    var setup: [8]u8 align(4) = .{ 0, 9, 1, 0, 0, 0, 0, 0 }; // SET_CONFIGURATION(1)
    var data: [64]u8 align(4) = @splat(0xA1);
    for ([_]bool{ false, true }) |close_first| {
        var dev: Device = undefined;
        dev.interface = .{ .vtable = &Device.vtable };
        dev.endpoints = @splat(@splat(.{}));
        dev.discard_ep0_setup = false;
        dev.st(.ep0, .out).buf = &setup;
        const ep = dev.st(.ep1, dir);
        ep.buf = &data;
        ep.rx_armed = dir == .out;
        ep.tx_busy = dir == .in;
        var ctl: Controller = .{ .close_first = close_first };

        const token = if (dir == .out) TOKEN_OUT else TOKEN_IN;
        test_poll_regs.USB_INT_ST.write(.{ .MASK_UIS_TOKEN = token, .MASK_UIS_H_RES__MASK_UIS_ENDP = 1 });
        Regs.USB_RX_LEN.raw = 4;
        Regs.USB_INT_ST.raw = 1; // TOG_OK
        test_poll_regs.USB_INT_FG.pending = .{ .RB_UIF_SETUP_ACT = 1, .RB_UIF_TRANSFER = 1 };
        dev.poll(false, &ctl);

        try std.testing.expectEqual(0, ctl.completions);
        try std.testing.expectEqual(0, ep.rx_last_len);
        try std.testing.expect(if (dir == .out) ep.rx_armed else ep.tx_busy);
        try std.testing.expectEqual(TOG_DATA0, if (dir == .out) current_rx_tog(1) else current_tx_tog(1));
        try std.testing.expectEqual(TestFlags{ .RB_UIF_SETUP_ACT = 0 }, test_poll_regs.USB_INT_FG.pending);

        test_poll_regs.USB_INT_FG.pending.RB_UIF_TRANSFER = 1;
        dev.poll(false, &ctl);
        try std.testing.expectEqual(1, ctl.completions);
    }
}

test "USBHS drops the old OUT completion when SETUP reopens and rearms the endpoint" {
    try expect_reopened_endpoint_drops_old_completion(.out);
}

test "USBHS drops the old IN completion when SETUP reopens and rearms the endpoint" {
    try expect_reopened_endpoint_drops_old_completion(.in);
}

test "USBHS acknowledges a retried control read status OUT" {
    const Device = Polled(.{}, .{});
    const Controller = struct {
        completions: usize = 0,

        pub fn on_buffer(self: *@This(), _: *usb.DeviceInterface, comptime ep: types.Endpoint) void {
            std.debug.assert(ep.dir == .in and ep.num == .ep0);
            self.completions += 1;
        }
    };
    var dev: Device = undefined;
    dev.endpoints = @splat(@splat(.{}));
    dev.discard_ep0_setup = false;
    dev.control = .{ .direction = .in };
    var tx: [64]u8 align(4) = undefined;
    dev.st(.ep0, .in).buf = &tx;
    set_rx_ctrl(0, RES_NAK, TOG_DATA1, false);
    _ = Device.ep_writev(&dev.interface, .ep0, &.{"response"});

    var ctl: Controller = .{};
    dev.handle_in(0, &ctl);
    Regs.USB_RX_LEN.raw = 0;
    Regs.USB_INT_ST.raw = 1;
    dev.handle_out(0, &ctl);
    const rx = EP_Regs[0].UEP_RX_CTRL.read();
    try std.testing.expectEqual(RES_ACK, rx.RES);
    try std.testing.expectEqual(TOG_DATA0, rx.TOG);

    Regs.USB_INT_ST.raw = 0; // The host repeats DATA1 after losing the ACK.
    dev.handle_out(0, &ctl);
    try std.testing.expectEqual(rx, EP_Regs[0].UEP_RX_CTRL.read());
    try std.testing.expectEqual(1, ctl.completions);
}
