const microzig = @import("microzig");

pub const clocks = @import("hal/clocks.zig");
pub const compatibility = @import("hal/compatibility.zig");
pub const gpio = @import("hal/gpio.zig");
pub const gpiote = @import("hal/gpiote.zig");
pub const i2c = @import("hal/i2c.zig");
pub const i2cdma = @import("hal/i2cdma.zig");
pub const nvmc = @import("hal/nvmc.zig");
pub const pdm = @import("hal/pdm.zig");
pub const power = @import("hal/power.zig");
pub const ppi = @import("hal/ppi.zig");
pub const pwm = @import("hal/pwm.zig");
pub const qspi = @import("hal/qspi.zig");
pub const rng = @import("hal/rng.zig");
pub const rtc = @import("hal/rtc.zig");
pub const saadc = @import("hal/saadc.zig");
pub const spim = @import("hal/spim.zig");
pub const temp = @import("hal/temp.zig");
pub const time = @import("hal/time.zig");
pub const timer = @import("hal/timer.zig");
pub const uart = @import("hal/uart.zig");
pub const usbd = @import("hal/usbd.zig");
pub const wdt = @import("hal/wdt.zig");
pub const drivers = @import("hal/drivers.zig");
// TODO: interrupts, wifi, nfc, bt, zigbee

pub const default_interrupts: microzig.cpu.InterruptOptions = .{
    // Required for timekeeping longer than 512 seconds
    .RTC0 = .{ .c = time.rtc_interrupt },
};

pub fn init() void {
    time.init();
}

test "hal tests" {
    _ = @import("usb_tests.zig");
    _ = clocks;
    _ = gpio;
    _ = i2c;
    _ = i2cdma;
    _ = spim;
    _ = time;
    _ = uart;
    _ = usbd;

    _ = drivers;
}
