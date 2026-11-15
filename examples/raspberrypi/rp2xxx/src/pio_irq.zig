//! PIO flag 0 drives system IRQ0; its handler toggles GPIO 2 (scope or external LED).
//! Expect a toggle roughly every half second. Build-only; not run on hardware.
//! RP2040 datasheet §3.4.9 IRQ / §3.7 IRQ0_INTE; RP2350 §11.4.11 / §11.7.
const microzig = @import("microzig");
const hal = microzig.hal;
const pio = hal.pio.num(0);
const pin = hal.gpio.num(2);
const program = hal.pio.assemble(
    \\.program tick
    \\.wrap_target
    \\set x, 31
    \\delay:
    \\jmp x-- delay [31]
    \\irq wait 0
    \\.wrap
, .{}).get_program_by_name("tick");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});
comptime {
    _ = microzig.export_startup();
}

pub const microzig_options: microzig.Options = .{
    .interrupts = .{ .PIO0_IRQ_0 = .{ .c = &pio_irq } },
};

fn pio_irq() callconv(.c) void {
    // Only flag 0 is routed to this line. Clear the flag, not the system-line force.
    pio.clear_irq_flags(1);
    pin.toggle();
}

pub fn main() !void {
    pin.set_function(.sio);
    pin.put(0);
    pin.set_direction(.out);
    const sm = try pio.claim_unused_state_machine();
    _ = try pio.sm_load_and_start_program(sm, program, .{ .clkdiv = .from_float(65535.0) });
    pio.clear_irq_flags(1);
    try pio.set_interrupt_enabled(.irq0, .{ .flag = 0 }, true);
    microzig.cpu.interrupt.enable(pio.irq_number(.irq0));
    microzig.interrupt.enable_interrupts();
    pio.sm_set_enabled(sm, true);
    // The ISR owns the output pin; main shares no mutable state with it.
    while (true) {}
}
