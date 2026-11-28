//! Host bindings for STM32F103 USB tests, run by the STM32 port test step.

const std = @import("std");

const core_support = @import("core_support");
pub const mmio = core_support.mmio;
pub const drivers = @import("drivers");

const generated_chip = @import("chip");
var usb_registers: generated_chip.types.peripherals.usb_v1.USB = undefined;

pub const chip = struct {
    pub const types = generated_chip.types;
    pub const peripherals = struct {
        pub const USB = &usb_registers;
    };
};

pub const utilities = core_support.utilities;
pub const core = core_support.core;

pub const panic = std.debug.FullPanic(std.debug.defaultPanic);
pub fn std_options(_: struct {}) std.Options {
    return .{};
}
pub const Options = struct {
    interrupts: struct {
        USB_LP_CAN1_RX0: struct { c: *const fn () callconv(.c) void },
    },
};
pub fn export_startup() void {}

pub const hal = struct {
    pub const usb = struct {
        pub const usb_ll = @import("usb_ll");
    };
    pub const time = struct {
        pub fn get_time_since_boot() drivers.time.Absolute {
            std.debug.assert(prepared);
            return .from_us(0);
        }
    };
};

pub const interrupt = struct {
    pub const CriticalSection = struct {
        pub fn leave(_: CriticalSection) void {
            const pending = if (pending_interrupt) |*value| value else return;
            pending.sections_left -= 1;
            if (pending.sections_left != 0) return;

            const handler = pending.handler;
            pending_interrupt = null;
            handler();
        }
    };

    pub fn enter_critical_section() CriticalSection {
        std.debug.assert(prepared);
        return .{};
    }

    pub fn enable(_: enum { USB_LP_CAN1_RX0 }) void {
        std.debug.assert(prepared);
    }
};

// EPR RAM captures register writes without emulating peripheral side effects.
var prepared = false;
var pending_interrupt: ?struct {
    sections_left: usize,
    handler: *const fn () void,
} = null;

pub const testing_usb = struct {
    const usb_ll = hal.usb.usb_ll;
    pub var pma_words: [256]u32 = undefined;

    pub fn prepare() void {
        prepared = true;
        pma_words = @splat(0);
        usb_registers = std.mem.zeroes(@TypeOf(usb_registers));
        usb_registers.ISTR.modify(.{ .RESET = 1 });
    }

    pub fn start(config: usb_ll.Config) !void {
        prepare();
        errdefer stop();
        try usb_ll.usb_runtime_init(config, .from_us(0));
    }

    pub fn stop() void {
        prepared = false;
        pending_interrupt = null;
    }

    pub fn interrupt_after_critical_sections(sections: usize, handler: *const fn () void) void {
        std.debug.assert(prepared and sections > 0 and pending_interrupt == null);
        pending_interrupt = .{ .sections_left = sections, .handler = handler };
    }

    pub fn raise_reset() void {
        usb_registers.ISTR.modify(.{ .RESET = 1 });
    }

    pub fn raise_ep0_setup() void {
        usb_registers.EPR[0].modify(.{ .SETUP = 1, .CTR_RX = 1, .CTR_TX = 0 });
        usb_registers.ISTR.modify(.{ .CTR = 1, .EP_ID = 0 });
    }

    pub fn load_ep0(data: []const u8) void {
        const offset = pma_words[2] / 2;
        for (0..data.len / 2) |i| {
            pma_words[offset + i] = @as(u32, data[2 * i]) | (@as(u32, data[2 * i + 1]) << 8);
        }
        // An odd final byte occupies the low half of the next PMA word.
        if (data.len % 2 == 1) pma_words[offset + data.len / 2] = data[data.len - 1];
        pma_words[3] = @intCast(data.len);
    }

    pub fn address() u7 {
        return usb_registers.DADDR.read().ADD;
    }
};
