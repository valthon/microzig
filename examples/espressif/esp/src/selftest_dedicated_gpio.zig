const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const dedicated = hal.dedicated_gpio;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .logFn = hal.usb_serial_jtag.logger.log, .log_level = .info });
comptime {
    _ = microzig.export_startup();
}

pub fn main() void {
    const pin = hal.gpio.num(4);
    const c3 = hal.compatibility.chip == .esp32_c3;
    const clock_before: u32 = if (c3) @bitCast(microzig.chip.peripherals.SYSTEM.CPU_PERI_CLK_EN.read()) else 0;
    const reset_before: u32 = if (c3) @bitCast(microzig.chip.peripherals.SYSTEM.CPU_PERI_RST_EN.read()) else 0;
    var pass: usize = 0;
    var fail: usize = 0;
    var channels: [8]bool = undefined;
    var clock_reset: ?bool = null;
    for (0..8) |index| {
        const channel: u3 = @intCast(index);
        const mask = @as(u8, 1) << channel;
        dedicated.connect(channel, pin);
        var ok = true;
        for ([_]bool{ false, true, false, true, false }) |high| {
            if (high) dedicated.set(mask) else dedicated.clear(mask);
            // Reinitializing must not reset already configured output latches.
            if (high) dedicated.init();
            hal.time.sleep_us(2);
            ok = ok and (dedicated.read() & mask != 0) == high and
                (dedicated.read_output() & mask != 0) == high and (pin.read() != 0) == high;
        }
        dedicated.disable_output(mask);
        pin.apply(.{});
        channels[index] = ok;
        if (ok) pass += 1 else fail += 1;
    }
    if (c3) {
        const system = microzig.chip.peripherals.SYSTEM;
        const clock_after: u32 = @bitCast(system.CPU_PERI_CLK_EN.read());
        const reset_after: u32 = @bitCast(system.CPU_PERI_RST_EN.read());
        // C3 SYSTEM_CPU_PERI_*_REG bit 7 is dedicated GPIO. Other bits
        // must match their values before connect() initialized the peripheral.
        const mask: u32 = 1 << 7;
        const ok = clock_after == clock_before | mask and reset_after == reset_before & ~mask;
        clock_reset = ok;
        if (ok) pass += 1 else fail += 1;
    }
    // The whole test takes well under a millisecond, so lines logged right
    // away reach the USB Serial/JTAG FIFO before the host has reopened the
    // port after the RAM load and are lost. Report after the host is back,
    // and repeat, like the other self-tests.
    hal.time.sleep_ms(1500);
    while (true) {
        for (channels, 0..) |ok, index| {
            std.log.info("SELFTEST dedicated_gpio ch{d}: {s}", .{ index, if (ok) "PASS" else "FAIL" });
        }
        if (clock_reset) |ok| std.log.info("SELFTEST dedicated_gpio clock_reset: {s}", .{if (ok) "PASS" else "FAIL"});
        std.log.info("SELFTEST dedicated_gpio DONE pass={d} fail={d}", .{ pass, fail });
        hal.time.sleep_ms(1000);
    }
}
