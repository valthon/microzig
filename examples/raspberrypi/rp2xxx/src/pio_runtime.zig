//! Exercise the shared PIO runtime surface without external wiring.
//! Also compiled for RP2040, RP2350 ARM and RP2350 RISC-V by the example gate.
const microzig = @import("microzig");
const hal = microzig.hal;
const pio = hal.pio.num(0);
const program = hal.pio.assemble(
    \\.program idle
    \\.clock_div 2
    \\.mov_status txfifo < 1
    \\nop
, .{}).get_program_by_name("idle");

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});
comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    if (comptime hal.compatibility.chip == .RP2350) try exercise_rp2350();
    const sm: hal.pio.StateMachine = .sm0;
    pio.clear_instruction_memory();
    try pio.claim_state_machine(sm);
    defer pio.unclaim(sm);
    try pio.claim_sm_mask(0b0110);
    pio.unclaim(.sm1);
    pio.unclaim(.sm2);
    if (!pio.is_claimed(sm)) @panic("claim lost");
    const offset = try pio.sm_load_and_start_program(sm, program, .{
        .exec = .{ .status = .{ .rx_level = 2 }, .out_sticky = true, .inline_out_en = true, .out_en_sel = 3, .jmp_pin = hal.gpio.num(0), .wrap = 0, .wrap_target = 0, .side_pindir = false, .side_set_optional = false },
        .clkdiv = try hal.pio.clkdiv_from_hz(125_000_000, 50_000_000),
    });
    defer pio.remove_program(program, offset) catch @panic("reservation lost");
    var config = try hal.pio.default_config(program);
    config.exec.out_sticky = false;
    try pio.sm_init(sm, offset, config);
    pio.sm_set_pins_with_mask(sm, 0, 0);
    pio.sm_set_pindirs_with_mask(sm, 0, 0);
    try pio.sm_set_consecutive_pindirs(sm, hal.gpio.num(0), 0, .in);
    pio.set_input_sync_bypass_mask(0, true);
    pio.set_input_sync_bypass_mask(0, false);
    pio.restart_sm_mask(1);
    pio.clkdiv_restart_sm_mask(1);
    pio.enable_sm_mask_in_sync(1);
    pio.set_sm_mask_enabled(1, false);
    const source: hal.pio.InterruptSource = .{ .flag = 0 };
    inline for (.{ hal.pio.InterruptLine.irq0, hal.pio.InterruptLine.irq1 }) |line| {
        try pio.set_interrupt_enabled(line, source, false);
        try pio.set_interrupt_enabled(line, .{ .rx_not_empty = sm }, false);
        try pio.set_interrupt_enabled(line, .{ .tx_not_full = sm }, false);
        try pio.set_interrupt_forced(line, source, true);
        if (!try pio.interrupt_status(line, source)) @panic("forced source absent");
        try pio.set_interrupt_forced(line, source, false);
        microzig.cpu.interrupt.disable(pio.irq_number(line));
    }
    pio.force_irq_flags(1);
    if (pio.irq_flags() & 1 == 0) @panic("forced flag absent");
    pio.clear_irq_flags(1);
    pio.sm_clear_debug(sm);
    _ = pio.sm_fdebug(sm);
    _ = pio.dbg_padout();
    _ = pio.dbg_padoe();
    _ = pio.dbg_cfginfo();
    _ = pio.sm_get_pc(sm);
    _ = pio.sm_is_exec_stalled(sm);
    _ = pio.sm_is_rx_fifo_full(sm);
    _ = pio.sm_is_tx_fifo_empty(sm);
    _ = pio.sm_dreq(sm, .tx);
    _ = pio.sm_dreq(sm, .rx);
    pio.sm_drain_tx_fifo(sm);
    pio.sm_exec_wait_blocking(sm, @bitCast(@as(u16, 0xa042))); // MOV Y, Y (NOP)
}

fn exercise_rp2350() !void {
    try pio.set_gpio_base(.gpio0);
    const loaded = try hal.pio.Pio.claim_sm_and_add_program_for_gpio_range(program, 0, 1);
    defer loaded.pio.unclaim(loaded.sm);
    defer loaded.pio.remove_program(program, loaded.offset) catch @panic("reservation lost");
    const sm = loaded.sm;
    try loaded.pio.sm_set_exec_options(sm, .{ .status = .{ .irq = .{ .flag = 7, .block = .prev } } });
    try loaded.pio.set_interrupt_enabled(.irq0, .{ .flag = 7 }, false);
    loaded.pio.sm_set_shift_options(sm, .{ .fjoin_rx_get = true });
    try loaded.pio.sm_rxfifo_put(sm, 3, 42);
    loaded.pio.sm_set_shift_options(sm, .{ .fjoin_rx_put = true });
    _ = try loaded.pio.sm_rxfifo_get(sm, 3);
    loaded.pio.sm_set_shift_options(sm, .{});
    // Empty masks exercise control composition without starting another SM.
    pio.enable_in_sync(.{});
    pio.disable(.{});
    pio.clkdiv_restart(.{});
}
