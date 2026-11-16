//! Host register boundary for USB HAL regression tests. No target MMIO is accessed.
pub const core = struct {
    pub const usb = @import("usb").core.usb;
};
pub const mmio = @import("usb").mmio;
pub const testing_io = struct {
    pub var fs_ep_regs: [32]u8 align(4) = @splat(0);
    pub var hs_ep_regs: [64]u8 align(4) = @splat(0);
};
pub const chip = struct {
    pub const peripherals = struct {
        pub const USB_OTG_FS = &fs;
        pub const USBHS = &hs;
    };
};
const WchStatus = struct {
    raw: u8 = 0,
    pub fn read(self: *const @This()) struct { RB_UIS_TOG_OK: u1 } {
        return .{ .RB_UIS_TOG_OK = @truncate(self.raw) };
    }
};
const WchLength = struct {
    raw: u16 = 0,
    pub fn read(self: *const @This()) struct { R16_USB_RX_LEN: u16 } {
        return .{ .R16_USB_RX_LEN = self.raw };
    }
};
var fs: struct { R16_USB_RX_LEN: u16 = 0, R8_USB_INT_ST: WchStatus = .{} } = .{};
var hs: struct { USB_RX_LEN: WchLength = .{}, USB_INT_ST: WchStatus = .{} } = .{};
