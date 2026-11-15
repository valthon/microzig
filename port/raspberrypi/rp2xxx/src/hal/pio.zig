//! A PIO instance can load a single `Bytecode`, it has to be loaded into memory
const std = @import("std");

const chip = @import("compatibility.zig").chip;

// Re-export of platform rectified pio implementation
const common = @import("pio/common.zig");
const chip_specific = switch (chip) {
    .RP2040 => @import("pio/rp2040.zig"),
    .RP2350 => @import("pio/rp2350.zig"),
};
pub const StateMachine = common.StateMachine;
pub const Instruction = common.Instruction(chip);
pub const PinMapping = common.PinMapping;
pub const PinMappingOptions = common.PinMappingOptions;
pub const StateMachineInitOptions = common.StateMachineInitOptions(chip);
pub const LoadAndStartProgramOptions = common.LoadAndStartProgramOptions(chip);
pub const ClkDivOptions = common.ClkDivOptions;
pub const ShiftOptions = common.ShiftOptions(chip);

pub const Fifo = common.Fifo;
pub const ExecOptions = common.ExecOptions;
pub const ExecOverrides = common.ExecOverrides;
pub const Status = common.Status;
pub const InterruptSource = common.InterruptSource;
pub const InterruptLine = common.InterruptLine;
pub const Fdebug = common.Fdebug;
pub const DebugConfig = common.DebugConfig;
pub const clkdiv_from_hz = common.clkdiv_from_hz;
pub const ProgramConfig = assembler.Config;
pub fn default_config(program: Program) !StateMachineInitOptions {
    return common.default_config(chip, program);
}

pub const assembler = @import("pio/assembler.zig");

pub const Program = assembler.Program;
pub inline fn assemble(comptime source: []const u8, comptime options: assembler.AssembleOptions) assembler.Output {
    return assembler.assemble(chip, source, options);
}

pub fn num(n: u2) Pio {
    switch (chip) {
        .RP2040 => {
            if (n > 1)
                @panic("the RP2040 only has PIO0 and PIO1");
        },
        .RP2350 => {
            if (n > 2)
                @panic("the RP2350 only has PIO0-2");
        },
    }

    return @as(Pio, @fromBackingInt(@intCast(n)));
}

pub const Pio = chip_specific.Pio;

test "pio" {
    _ = common;
    _ = @import("pio/runtime.zig");
    _ = @import("pio/registers.zig");
    _ = @import("pio/exec.zig");
    std.testing.refAllDecls(assembler);
}
