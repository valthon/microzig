//! Repurpose RX FIFO entries as CPU-written configuration and SM-written status.
//! GPIO 2 follows configuration bit 0, toggled every 500 ms; GPIO 3 toggles when
//! the CPU observes a changed counter. Scope both pins. No external input pins.
//! Build-only; not run on hardware. RP2350 datasheet §11.4.8.2 / §11.4.9.2.
const microzig = @import("microzig");
const hal = microzig.hal;
const pio = hal.pio.num(0);
const output = hal.gpio.num(2);
const heartbeat = hal.gpio.num(3);
const programs = hal.pio.assemble(
    \\.program config
    \\.pio_version 1
    \\.fifo txget
    \\.out 1
    \\.wrap_target
    \\mov osr, rxfifo[0]
    \\out pins, 1
    \\.wrap
    \\.program counter
    \\.pio_version 1
    \\.fifo txput
    \\set x, 0
    \\.wrap_target
    \\count:
    \\mov isr, x
    \\mov rxfifo[0], isr
    \\jmp x-- count
    \\.wrap
, .{});

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});
comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    const config_sm = try pio.claim_unused_state_machine();
    const counter_sm = try pio.claim_unused_state_machine();
    pio.gpio_init(output);
    heartbeat.set_function(.sio);
    heartbeat.put(0);
    heartbeat.set_direction(.out);
    _ = try pio.sm_load_and_start_program(config_sm, programs.get_program_by_name("config"), .{
        .clkdiv = .from_float(125.0),
        .pin_mappings = .{ .out = .single(output) },
    });
    try pio.sm_set_consecutive_pindirs(config_sm, output, 1, .out);
    _ = try pio.sm_load_and_start_program(counter_sm, programs.get_program_by_name("counter"), .{
        .clkdiv = .from_float(125.0),
    });
    // GET-only gives the system the write port; PUT-only gives it the read port.
    // Setting both modes would give both ports to the SM, excluding the CPU.
    var config: u32 = 0;
    try pio.sm_rxfifo_put(config_sm, 0, config);
    pio.sm_set_enabled(config_sm, true);
    pio.sm_set_enabled(counter_sm, true);
    var previous: u32 = 0;
    while (true) {
        hal.time.sleep_ms(500);
        const count = try pio.sm_rxfifo_get(counter_sm, 0);
        if (count == previous) return error.CounterStopped;
        previous = count;
        heartbeat.toggle();
        config ^= 1;
        try pio.sm_rxfifo_put(config_sm, 0, config);
    }
}
