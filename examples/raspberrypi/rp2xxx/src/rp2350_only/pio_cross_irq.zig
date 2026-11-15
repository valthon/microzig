//! Cross-PIO request/acknowledge with IRQ NEXT/PREV and MOV X, STATUS (IRQ).
//! Scope GPIO 2 (PIO0 request) and GPIO 3 (PIO1 acknowledge): expect recurring
//! pulses, with the short GPIO 3 pulse inside each GPIO 2 pulse. No input wiring.
//! Build-only; not run on hardware. RP2350 datasheet §11.4.11, §11.7 CTRL/SMx_EXECCTRL.
const microzig = @import("microzig");
const hal = microzig.hal;
const requester = hal.pio.num(0);
const responder = hal.pio.num(1);
const programs = blk: {
    @setEvalBranchQuota(10000);
    break :blk hal.pio.assemble(
        \\.program request
        \\.pio_version 1
        \\.mov_status irq set 0
        \\.set 1
        \\.wrap_target
        \\set pins, 1
        \\irq next set 0
        \\ack:
        \\mov x, status
        \\jmp !x ack
        \\irq clear 0
        \\set pins, 0 [31]
        \\.wrap
        \\.program respond
        \\.pio_version 1
        \\.set 1
        \\.wrap_target
        \\wait 1 irq 0
        \\set pins, 1
        \\irq prev set 0
        \\set pins, 0
        \\.wrap
    , .{});
};

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});
comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    // Fix the SM numbers so the cross-block masks below name the reserved SMs.
    try requester.claim_state_machine(.sm0);
    try responder.claim_state_machine(.sm0);
    const request_pin = hal.gpio.num(2);
    const ack_pin = hal.gpio.num(3);
    requester.gpio_init(request_pin);
    responder.gpio_init(ack_pin);
    _ = try requester.sm_load_and_start_program(.sm0, programs.get_program_by_name("request"), .{
        .clkdiv = .from_float(125.5),
        .pin_mappings = .{ .set = .single(request_pin) },
    });
    _ = try responder.sm_load_and_start_program(.sm0, programs.get_program_by_name("respond"), .{
        .clkdiv = .from_float(125.5),
        .pin_mappings = .{ .set = .single(ack_pin) },
    });
    try requester.sm_set_consecutive_pindirs(.sm0, request_pin, 1, .out);
    try responder.sm_set_consecutive_pindirs(.sm0, ack_pin, 1, .out);
    requester.clear_irq_flags(1);
    responder.clear_irq_flags(1);
    // Cross-PIO IRQs require equal, synchronized dividers and equal security
    // attribution. One CTRL write aligns both dividers and starts both SMs.
    requester.enable_in_sync(.{ .pio0 = 1, .pio1 = 1 });
    while (true) {}
}
