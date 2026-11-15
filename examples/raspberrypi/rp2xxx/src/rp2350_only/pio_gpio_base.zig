//! GPIOBASE 16 drives GPIO 46 (A5 on Adafruit Metro RP2350, an RP2350B board).
//! Scope A5/GPIO 46 for a square wave. Leave A5 disconnected from other circuits.
//! Requires RP2350B; registered only for Metro RP2350. Build-only; not run on hardware.
//! RP2350 datasheet §11.7 GPIOBASE: PIO's 32-pin window becomes GPIO 16 through 47.
const microzig = @import("microzig");
const hal = microzig.hal;
const pio = hal.pio.num(0);
const pin = hal.gpio.num(46);
const program = hal.pio.assemble(
    \\.program high_gpio
    \\.pio_version 1
    \\.set 1
    \\.wrap_target
    \\set pins, 1 [31]
    \\set pins, 0 [31]
    \\.wrap
, .{}).get_program_by_name("high_gpio");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});
comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    // Select the window before claiming SMs or loading instruction memory.
    try pio.set_gpio_base(.gpio16);
    const sm = try pio.claim_unused_state_machine();
    pio.gpio_init(pin);
    _ = try pio.sm_load_and_start_program(sm, program, .{
        .clkdiv = .from_float(125.0),
        // Pass system GPIO numbers; the HAL maps GPIO 46 to PIO pin 30.
        .pin_mappings = .{ .set = .single(pin) },
    });
    try pio.sm_set_consecutive_pindirs(sm, pin, 1, .out);
    pio.sm_set_enabled(sm, true);
    while (true) {}
}
