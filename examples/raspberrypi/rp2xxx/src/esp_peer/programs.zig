//! RP2350 datasheet §11.4: WAIT, IN, OUT, PUSH and JMP instruction semantics.
const std = @import("std");
const hal = @import("microzig").hal;

pub fn serial(comptime base: u6, comptime spi: bool) hal.pio.Program {
    // I2S skips the Philips delay BCK after the first WS fall, so bit 0 is the
    // first sample's MSB and the final LSB completes a word. Each OUT follows
    // the previous falling edge, so replay bit n is valid at sample edge n.
    const entry = if (spi) std.fmt.comptimePrint("wait 0 gpio {d}\n", .{base + 3}) else std.fmt.comptimePrint("wait 1 gpio {d}\nwait 0 gpio {d}\nwait 1 gpio {d}\nwait 0 gpio {d}\n", .{ base + 3, base + 3, base + 2, base + 2 });
    return comptime hal.pio.assemble(".program serial\n" ++ entry ++ std.fmt.comptimePrint(
        \\.wrap_target
        \\out pins, 1
        \\wait 1 gpio {d}
        \\in pins, 4
        \\wait 0 gpio {d}
        \\.wrap
        \\
    , .{ base + 2, base + 2 }), .{}).get_program_by_name("serial");
}
pub const parl_capture = hal.pio.assemble(
    \\.program capture
    \\.wrap_target
    \\wait 1 gpio 16
    \\wait 0 gpio 16
    \\in null, 6
    \\in pins, 10
    \\.wrap
, .{}).get_program_by_name("capture");
// C6 TRM §38.5.3 and §38.10 TX_SMP_EDGE_SEL/RX_CLK_EDGE_SEL:
// TX changes on rising, capture on falling. RX_CLK_EDGE_SEL=1 inverts
// RX clock, so replay changes data on rising and RX samples on falling.
// At 10 MHz: OUT + NOP[3] = 0.5 us, SET + NOP[3] = 0.5 us.
// OUT includes CLK=1, then SET lowers CLK. VAL is the tenth output bit.
pub const parl_replay = hal.pio.assemble(
    \\.program replay
    \\.wrap_target
    \\out pins, 10
    \\out null, 6 [3]
    \\set pins, 0
    \\nop [3]
    \\.wrap
, .{}).get_program_by_name("replay");

pub fn rmt_capture(comptime base: u6) hal.pio.Program {
    return comptime hal.pio.assemble(std.fmt.comptimePrint(
        \\.program widths
        \\wait 1 gpio {d}
        \\mov x, ~null
        \\high:
        \\jmp pin high_more
        \\mov isr, ~x
        \\push block
        \\mov x, ~null
        \\low:
        \\jmp pin low_done
        \\jmp x-- low
        \\low_done:
        \\mov isr, ~x
        \\push block
        \\mov x, ~null
        \\jmp high
        \\high_more:
        \\jmp x-- high
        \\
    , .{base + 1}), .{}).get_program_by_name("widths");
}
pub const rmt_replay = hal.pio.assemble(
    \\.program pulses
    \\.wrap_target
    \\pull block
    \\mov x, osr
    \\set pins, 1
    \\high:
    \\jmp x-- high
    \\pull block
    \\mov x, osr
    \\set pins, 0
    \\low:
    \\jmp x-- low
    \\.wrap
, .{}).get_program_by_name("pulses");

// RP2350 DS §§11.2.2, 11.4.2: one cycle per JMP; the two-instruction high/low
// polling loops count cycles, with three extra instructions per clock period.
// Each result spans 32 input periods. CPU timestamp quantization is avoided.
pub fn clock_meter(comptime clock_pin: u6) hal.pio.Program {
    return comptime hal.pio.assemble(std.fmt.comptimePrint(
        \\.program meter
        \\start:
        \\wait 1 gpio {d}
        \\set y, 31
        \\mov x, ~null
        \\high:
        \\jmp pin high_more
        \\low:
        \\jmp pin rising
        \\jmp x-- low
        \\rising:
        \\jmp y-- high
        \\mov isr, ~x
        \\push block
        \\jmp start
        \\high_more:
        \\jmp x-- high
        \\
    , .{clock_pin}), .{}).get_program_by_name("meter");
}
pub const calibration = hal.pio.assemble(
    \\.program calibration
    \\mov x, ~null
    \\.wrap_target
    \\spin:
    \\jmp x-- spin
    \\.wrap
    \\mov isr, ~x
    \\push block
, .{}).get_program_by_name("calibration");
