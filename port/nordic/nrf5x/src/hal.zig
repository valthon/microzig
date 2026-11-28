const microzig = @import("microzig");

pub const clocks = @import("hal/clocks.zig");
pub const compatibility = @import("hal/compatibility.zig");
pub const gpio = @import("hal/gpio.zig");
pub const gpiote = @import("hal/gpiote.zig");
pub const i2c = @import("hal/i2c.zig");
pub const ieee802154 = if (microzig.options.hal.ieee802154 and compatibility.chip == .nrf52840)
    @import("hal/radio/ieee802154.zig")
else
    struct {};
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

pub const HAL_Options = struct {
    /// Reserve the nRF52840 RADIO and TIMER3 interrupt vectors for the radio driver.
    ieee802154: bool = false,
};

pub const default_interrupts: microzig.cpu.InterruptOptions = interrupts: {
    var handlers: microzig.cpu.InterruptOptions = .{
        // Required for timekeeping longer than 512 seconds.
        .RTC0 = .{ .c = time.rtc_interrupt },
    };
    if (microzig.options.hal.ieee802154) {
        if (compatibility.chip != .nrf52840) compatibility.unsupported_chip("IEEE 802.15.4");
        handlers.RADIO = .{ .c = ieee802154.radio_interrupt };
        handlers.TIMER3 = .{ .c = ieee802154.timer_interrupt };
    }
    break :interrupts handlers;
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
