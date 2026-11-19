const builtin = @import("builtin");
const std = @import("std");

pub const esp_image = @import("esp_image");
const microzig = @import("microzig");

pub const cache = @import("hal/cache.zig");
pub const adc = @import("hal/adc.zig");
pub const clocks = @import("hal/clocks.zig");
pub const compatibility = @import("hal/compatibility.zig");
pub const drivers = @import("hal/drivers.zig");
pub const efuse = @import("hal/efuse.zig");
pub const flash = @import("hal/flash.zig");
pub const parl_io = if (compatibility.chip == .esp32_c6) @import("hal/parl_io.zig") else void;
pub const dedicated_gpio = @import("hal/dedicated_gpio.zig");
pub const gdma = @import("hal/gdma.zig");
pub const gpio = @import("hal/gpio.zig");
pub const i2s = @import("hal/i2s.zig");
pub const i2c = @import("hal/i2c.zig");
pub const ledc = switch (compatibility.chip) {
    .esp32_c3 => @import("hal/ledc.zig"),
    .esp32_c6 => @import("hal/ledc/esp32_c6.zig"),
};
pub const radio = @import("hal/radio.zig");
pub const rmt = @import("hal/rmt.zig");
pub const rng = @import("hal/rng.zig");
pub const rom = @import("hal/rom.zig");
pub const rtos = @import("hal/rtos.zig");
pub const spi = @import("hal/spi.zig");
pub const system = @import("hal/system.zig");
pub const systimer = @import("hal/systimer.zig");
pub const timer = @import("hal/timer.zig");
pub const wdt = @import("hal/wdt.zig");
pub const time = @import("hal/time.zig");
pub const twai = @import("hal/twai.zig");
pub const temperature = @import("hal/temperature.zig");
pub const uart = @import("hal/uart.zig");
pub const usb_serial_jtag = @import("hal/usb_serial_jtag.zig");

comptime {
    if (!builtin.is_test) {
        // Keep otherwise unused register accessors in firmware compile coverage.
        @export(&compile_check_accessors, .{ .name = "esp_compile_check_accessors" });

        // export atomic intrinsics
        _ = @import("hal/atomic.zig");

        @export(&app_desc, .{
            .name = "esp_app_desc",
            .section = ".app_desc",
        });
    }
}

pub const HAL_Options = struct {
    info: struct {
        project_name: []const u8 = "Untitled Project",
        secure_version: u32 = 0,
        version: []const u8 = "0.0.0",
    } = .{},
    rtos: rtos.Options = .{},
    radio: radio.Options = .{},
};

/// Clock config applied by the default `init()` function of the hal.
pub const clock_config: clocks.Config = .default;

pub fn init() void {
    init_sequence(clock_config);
}

/// Allows you to easily swap the clock config while using the recommended init sequence. To be used
/// with a custom `init()` function.
pub fn init_sequence(clock_cfg: clocks.Config) void {
    cache.init();

    disable_watchdogs();

    clock_cfg.apply();

    system.init();

    time.init();

    if (microzig.options.hal.rtos.enable)
        rtos.init();
}

fn disable_watchdogs() void {
    switch (compatibility.chip) {
        .esp32_c3 => wdt.disable_at_boot(),
        // `hal.wdt` drives the esp32c3 register layout only. The esp32c6 moved the rtc watchdogs
        // into the low power domain and has a second timer group whose watchdog the rom
        // bootloader may have armed as well.
        .esp32_c6 => {
            const peripherals = microzig.chip.peripherals;
            const TIMG0 = peripherals.TIMG0;
            const TIMG1 = peripherals.TIMG1;
            const LP_WDT = peripherals.LP_WDT;

            const dogfood = 0x50D83AA1;

            TIMG0.WDTWPROTECT.raw = dogfood;
            TIMG0.WDTCONFIG0.raw = 0;
            // C6 TRM v1.2 §14.6, TIMG_WDTCONFIG0_REG: latch the change.
            TIMG0.WDTCONFIG0.modify(.{ .WDT_CONF_UPDATE_EN = 1 });
            TIMG0.WDTWPROTECT.raw = 0;

            TIMG1.WDTWPROTECT.raw = dogfood;
            TIMG1.WDTCONFIG0.raw = 0;
            // C6 TRM v1.2 §14.6, TIMG_WDTCONFIG0_REG: latch the change.
            TIMG1.WDTCONFIG0.modify(.{ .WDT_CONF_UPDATE_EN = 1 });
            TIMG1.WDTWPROTECT.raw = 0;

            LP_WDT.WPROTECT.raw = dogfood;
            LP_WDT.CONFIG0.raw = 0;
            LP_WDT.WPROTECT.raw = 0;

            // C6 TRM v1.2 §15.6, register 15.9: unlike C3, SWD uses
            // the same unlock key as the other watchdogs.
            LP_WDT.SWD_WPROTECT.raw = dogfood;
            LP_WDT.SWD_CONFIG.modify(.{ .SWD_DISABLE = 1 });
            LP_WDT.SWD_WPROTECT.raw = 0;
        },
    }
}

// Don't change the name of this export, it is checked by espflash tool. Only
// these fields are populated here. The others will be set by elf2image.
const app_desc: esp_image.AppDesc = .{
    .secure_version = microzig.options.hal.info.secure_version,
    .version = str(32, microzig.options.hal.info.version),
    .project_name = str(32, microzig.options.hal.info.project_name),
};

fn str(comptime l: usize, comptime s: []const u8) [l]u8 {
    // l - 1 because we need to add a null byte at the end
    if (s.len > l - 1) {
        @compileError(std.fmt.comptimePrint("string `{s}` doesn't fit in buffer with len {d}", .{ s, l }));
    }

    var buf = std.mem.zeroes([l]u8);
    std.mem.copyForwards(u8, buf[0..s.len], s);
    return buf;
}

test {
    _ = twai;
    _ = rmt;
    _ = flash;
    _ = adc;
    _ = efuse;
    _ = temperature;
    _ = rtos;
    _ = radio;
    _ = usb_serial_jtag;
    _ = @import("hal/usb_serial_jtag/state.zig");
    _ = @import("hal/gpio_encoding.zig");
    _ = @import("hal/gpio/esp32_c6.zig");
    _ = @import("hal/i2c_logic.zig");
    _ = @import("interrupt-encoding");
}

// Never called: exporting forces body analysis for the real chip register types.
// A host test cannot validate these MMIO layouts or RISC-V interrupt accessors.
fn compile_check_accessors(index: u32) callconv(.c) void {
    const pin = gpio.num(@intCast(index % gpio.pin_count));
    const unit_index: u1 = @truncate(index);
    const int: microzig.cpu.Interrupt = @fromBackingInt(@as(u5, @intCast(index % 31 + 1)));
    systimer.unit(unit_index).write(0);
    pin.set_drive_strength(.@"10mA");
    pin.set_input_filter_enabled(false);
    gpio.InputSignal.i2cext0_sda.set_input_invert(false);
    pin.set_output_invert(false);
    microzig.cpu.interrupt.clear_pending(int);
    std.mem.doNotOptimizeAway(microzig.cpu.interrupt.get_type(int));
    std.mem.doNotOptimizeAway(microzig.cpu.interrupt.get_mapped_interrupt(.i2c_ext0));
}

test {
    _ = @import("hal/uart/timing.zig");
    _ = @import("hal/radio/ieee802154_frame.zig");
    _ = @import("hal/radio/ieee802154_rx.zig");
}

pub const sigma_delta = @import("hal/sigma_delta.zig");

pub const pcnt = @import("hal/pcnt.zig");

pub const etm = @import("hal/etm.zig");

pub const mcpwm = @import("hal/mcpwm.zig");

pub const sha = @import("hal/sha.zig");

pub const aes = @import("hal/aes.zig");

pub const rsa = @import("hal/rsa.zig");

pub const ecc = @import("hal/ecc.zig");
