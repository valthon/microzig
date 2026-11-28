//! Host register boundary for USB HAL regression tests. No target MMIO is accessed.
pub const core = struct {
    pub const usb = @import("usb").core.usb;
};
pub const mmio = @import("usb").mmio;
pub const hal = struct {
    pub const compatibility = struct {
        pub const chip = .nrf52833;
    };
};
pub const cpu = struct {
    pub fn executing_isr() bool {
        return testing_io.in_isr;
    }
    pub fn dsb() void {}
    pub fn isb() void {}
    pub const interrupt = struct {
        pub fn is_enabled(_: enum { USBD }) bool {
            return testing_io.irq_enabled;
        }
        pub fn enable(_: enum { USBD }) void {
            testing_io.irq_enabled = true;
        }
        pub fn disable(_: enum { USBD }) void {
            testing_io.irq_enabled = false;
        }
        pub fn set_pending(_: enum { USBD }) void {
            testing_io.irq_pending = true;
        }
        pub fn clear_pending(_: enum { USBD }) void {
            testing_io.irq_pending = false;
        }
    };
};
pub const testing_io = struct {
    pub var out_packet: []const u8 = "";
    pub var in_packet: [64]u8 = undefined;
    pub var in_len: usize = 0;
    pub var in_isr = false;
    pub var dma_ready = false;
    pub var irq_enabled = false;
    pub var irq_pending = false;
    pub var wake_ready = false;
    pub var force_normal_writes: usize = 0;
    pub fn reset() void {
        out_packet = "";
        in_len = 0;
        in_isr = false;
        dma_ready = false;
        irq_enabled = false;
        irq_pending = false;
        wake_ready = false;
        force_normal_writes = 0;
        usbd = .{};
    }
};
const Register = extern struct {
    raw: u32 = 0,
    full_value: usize = 0,
    kind: enum(u8) { normal, lowpower, cause, out_task, in_task } = .normal,
    pub fn write_raw(self: *Register, value: anytype) void {
        const v: u32 = @truncate(@as(u64, value));
        if (self.kind == .cause) {
            self.raw &= ~v;
            return;
        }
        self.raw = v;
        self.full_value = @intCast(value);
        if (v == 1 and testing_io.dma_ready) {
            for (0..8) |i| {
                if (self == &usbd.TASKS_STARTEPOUT[i]) {
                    const dst: [*]u8 = @ptrFromInt(usbd.EPOUT[i].PTR.full_value);
                    const len = @min(testing_io.out_packet.len, usbd.EPOUT[i].MAXCNT.raw);
                    @memcpy(dst[0..len], testing_io.out_packet[0..len]);
                    usbd.EVENTS_ENDEPOUT[i].raw = 1;
                }
                if (self == &usbd.TASKS_STARTEPIN[i]) {
                    const src: [*]const u8 = @ptrFromInt(usbd.EPIN[i].PTR.full_value);
                    testing_io.in_len = usbd.EPIN[i].MAXCNT.raw;
                    @memcpy(testing_io.in_packet[0..testing_io.in_len], src[0..testing_io.in_len]);
                    usbd.EVENTS_ENDEPIN[i].raw = 1;
                }
            }
        }
        if (self.kind == .lowpower and v == 0) {
            testing_io.force_normal_writes += 1;
            if (testing_io.wake_ready) usbd.EVENTCAUSE.raw |= 1 << 10;
        }
    }
    pub fn write(self: *Register, value: anytype) void {
        _ = value;
        self.raw = 0;
    }
    pub fn read(_: *const Register) struct {
        VBUSDETECT: enum { NoVbus, VbusPresent } = .VbusPresent,
        OUTPUTRDY: enum { Ready, NotReady } = .Ready,
        READY: enum { Ready, NotReady } = .Ready,
    } {
        return .{};
    }
};
const Endpoint = extern struct { PTR: Register = .{}, MAXCNT: Register = .{} };
/// Extern, so that `disarm_area` stays at offset 0.
const Usbd = extern struct {
    /// `hal/usbd/errata.zig:disarm_in` writes nrfx's undocumented registers at USBD + 0x800 and
    /// + 0x804. Without this area those writes landed past the end of the mock, in whatever global
    /// followed it (the test allocator's state on Windows).
    disarm_area: [0x808]u8 = @splat(0),
    BMREQUESTTYPE: Register = .{},
    BREQUEST: Register = .{},
    DTOGGLE: Register = .{},
    ENABLE: Register = .{},
    EPDATASTATUS: Register = .{ .kind = .cause },
    EPIN: [8]Endpoint = @splat(.{}),
    EPINEN: Register = .{},
    EPOUT: [8]Endpoint = @splat(.{}),
    EPOUTEN: Register = .{},
    EPSTATUS: Register = .{},
    EVENTCAUSE: Register = .{ .kind = .cause },
    EVENTS_ENDEPIN: [8]Register = @splat(.{}),
    EVENTS_ENDEPOUT: [8]Register = @splat(.{}),
    EVENTS_EP0DATADONE: Register = .{},
    EVENTS_EP0SETUP: Register = .{},
    EVENTS_EPDATA: Register = .{},
    EVENTS_USBEVENT: Register = .{},
    EVENTS_USBRESET: Register = .{},
    LOWPOWER: Register = .{ .kind = .lowpower },
    SHORTS: Register = .{},
    SIZE: extern struct { EPOUT: [8]Register = @splat(.{}) } = .{},
    TASKS_EP0RCVOUT: Register = .{},
    TASKS_EP0STALL: Register = .{},
    TASKS_EP0STATUS: Register = .{},
    TASKS_STARTEPIN: [8]Register = @splat(.{ .kind = .in_task }),
    TASKS_STARTEPOUT: [8]Register = @splat(.{ .kind = .out_task }),
    USBPULLUP: Register = .{},
    WINDEXH: Register = .{},
    WINDEXL: Register = .{},
    WLENGTHH: Register = .{},
    WLENGTHL: Register = .{},
    WVALUEH: Register = .{},
    WVALUEL: Register = .{},
};
comptime {
    if (@offsetOf(Usbd, "disarm_area") != 0)
        @compileError("the USBD mock must keep USBD + 0x800 .. + 0x808 inside disarm_area");
}
var usbd: Usbd = .{};
pub const chip = struct {
    pub const peripherals = struct {
        pub const USBD = &usbd;
        pub const POWER = &power;
        pub const CLOCK = &clock;
    };
};
var power: struct { USBREGSTATUS: Register = .{} } = .{};
var clock: struct { HFCLKSTAT: Register = .{} } = .{};
