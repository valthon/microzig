//! DMA feeds the PIO TX FIFO via sm_dreq; MOV X, STATUS detects an empty FIFO.
//! Scope GPIO 2 for alternating-bit bursts every 500 ms; GPIO 3 is high while idle.
//! No input pins. Build-only; not run on hardware.
//! RP2040 datasheet §3.2.3.5 FIFOs / §3.7 SMx_EXECCTRL; RP2350 §11.2.4.4 / §11.7.
const microzig = @import("microzig");
const hal = microzig.hal;
const pio = hal.pio.num(0);
const data_pin = hal.gpio.num(2);
const idle_pin = hal.gpio.num(3);
const program = hal.pio.assemble(
    \\.program stream
    \\.mov_status txfifo < 1
    \\.out 1
    \\.set 1
    \\.wrap_target
    \\check:
    \\mov x, status
    \\jmp !x ready
    \\set pins, 1
    \\jmp check
    \\ready:
    \\set pins, 0
    \\pull block
    \\out pins, 1
    \\.wrap
, .{}).get_program_by_name("stream");
const samples: [64]u32 = blk: {
    var values: [64]u32 = undefined;
    for (&values, 0..) |*value, i| value.* = @intCast(i & 1);
    break :blk values;
};

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});
comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    const sm = try pio.claim_unused_state_machine();
    pio.gpio_init(data_pin);
    pio.gpio_init(idle_pin);
    _ = try pio.sm_load_and_start_program(sm, program, .{
        .clkdiv = .from_float(125.0),
        .pin_mappings = .{ .out = .single(data_pin), .set = .single(idle_pin) },
    });
    try pio.sm_set_consecutive_pindirs(sm, data_pin, 2, .out);
    const channel = hal.dma.claim_unused_channel() orelse return error.NoDmaChannel;
    pio.sm_set_enabled(sm, true);
    while (true) {
        try channel.setup_transfer(hal.dma.DMA_WriteTarget{
            .addr = @intFromPtr(pio.sm_get_tx_fifo(sm)),
            .dreq = pio.sm_dreq(sm, .tx),
        }, &samples, .{ .enable = true, .trigger = true });
        const deadline = hal.time.get_time_since_boot().add_duration(.from_ms(1000));
        while (channel.is_busy()) {
            if (deadline.is_reached_by(hal.time.get_time_since_boot())) return error.DmaTimeout;
        }
        // DMA completion means queued, not shifted out. Keep samples alive and
        // let the SM drain the FIFO during this pause before the next burst.
        hal.time.sleep_ms(500);
    }
}
