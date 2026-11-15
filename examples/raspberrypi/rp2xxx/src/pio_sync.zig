//! Start two SMs with aligned clock dividers; scope GPIO 2 and 3 for matching edges.
//! No external connections except scope ground. Build-only; not run on hardware.
//! See RP2040 datasheet §3.7 CTRL, RP2350 datasheet §11.7 CTRL.
const microzig = @import("microzig");
const hal = microzig.hal;
const pio = hal.pio.num(0);
const program = hal.pio.assemble(
    \\.program square
    \\.set 1
    \\.wrap_target
    \\set pins, 1 [31]
    \\set pins, 0 [31]
    \\.wrap
, .{}).get_program_by_name("square");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});
comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    // Reserve the mask before configuring any of its machines.
    const mask = 0b0011;
    try pio.claim_sm_mask(mask);
    inline for (.{ hal.pio.StateMachine.sm0, .sm1 }, .{ 2, 3 }) |sm, pin_number| {
        const pin = hal.gpio.num(pin_number);
        pio.gpio_init(pin);
        _ = try pio.sm_load_and_start_program(sm, program, .{
            .clkdiv = .from_float(125.5),
            .pin_mappings = .{ .set = .single(pin) },
        });
        try pio.sm_set_consecutive_pindirs(sm, pin, 1, .out);
    }
    // sm_init has already positioned each PC at its own relocated program entry.
    // A single CTRL write restarts both dividers and enables both SMs.
    pio.enable_sm_mask_in_sync(mask);
    while (true) {}
}
