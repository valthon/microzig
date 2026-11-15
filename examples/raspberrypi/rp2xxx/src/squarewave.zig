//! Generate a square wave on GPIO 2; observe it with a scope.
//! Build-only; not run on hardware.
const microzig = @import("microzig");
const rp2xxx = microzig.hal;
const gpio = rp2xxx.gpio;
const Pio = rp2xxx.pio.Pio;

const squarewave_program = blk: {
    @setEvalBranchQuota(3000);
    break :blk rp2xxx.pio.assemble(
        \\;
        \\; Copyright (c) 2020 Raspberry Pi (Trading) Ltd.
        \\;
        \\; SPDX-License-Identifier: BSD-3-Clause
        \\;
        \\.program squarewave
        \\    set pindirs, 1   ; Set pin to output
        \\again:
        \\    set pins, 1 [1]  ; Drive pin high and then delay for one cycle
        \\    set pins, 0      ; Drive pin low
        \\    jmp again        ; Set PC to label `again`
    , .{}).get_program_by_name("squarewave");
};

// Pick a PIO block; main claims an available state machine.
const pio: Pio = rp2xxx.pio.num(0);
const pin = gpio.num(2);

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    const sm = try pio.claim_unused_state_machine();
    pio.gpio_init(pin);
    _ = try pio.sm_load_and_start_program(sm, squarewave_program, .{
        .clkdiv = .from_float(125.0),
        .pin_mappings = .{
            .set = .single(pin),
        },
    });

    pio.sm_set_enabled(sm, true);

    while (true) {}
}
