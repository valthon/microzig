const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");

const Chip = @import("../chip.zig").Chip;

pub const PIO = microzig.chip.types.peripherals.PIO0;
pub const PIO0 = microzig.chip.peripherals.PIO0;
pub const PIO1 = microzig.chip.peripherals.PIO1;

pub const assembler = @import("assembler.zig");
const encoder = @import("assembler/encoder.zig");
const gpio = @import("../gpio.zig");
const registers = @import("registers.zig");
const exec = @import("exec.zig");

pub const ClkDivOptions = microzig.utilities.IntFracDiv(16, 8);
pub const Instruction = encoder.Instruction;
pub const Program = assembler.Program;

// global state for keeping track of used things
fn UsedInstructionSpace(chip: Chip) type {
    switch (chip) {
        .RP2040 => return struct {
            pub var val = [_]u32{ 0, 0 };
        },
        .RP2350 => return struct {
            pub var val = [_]u32{ 0, 0, 0 };
        },
    }
}
fn ClaimedStateMachines(chip: Chip) type {
    switch (chip) {
        .RP2040 => return struct {
            pub var val = [_]u4{ 0, 0 };
        },
        .RP2350 => return struct {
            pub var val = [_]u4{ 0, 0, 0 };
        },
    }
}

pub const Fifo = enum {
    tx,
    rx,
};

pub const StateMachine = enum(u2) {
    sm0,
    sm1,
    sm2,
    sm3,

    pub const Regs = extern struct {
        clkdiv: @TypeOf(PIO0.SM0_CLKDIV),
        execctrl: @TypeOf(PIO0.SM0_EXECCTRL),
        shiftctrl: @TypeOf(PIO0.SM0_SHIFTCTRL),
        addr: @TypeOf(PIO0.SM0_ADDR),
        instr: @TypeOf(PIO0.SM0_INSTR),
        pinctrl: @TypeOf(PIO0.SM0_PINCTRL),
    };

    comptime {
        assert(@sizeOf([2]Regs) == (4 * 6 * 2));
    }
};

pub const Irq = enum {
    irq0,
    irq1,

    pub const Regs = extern struct {
        enable: @TypeOf(PIO0.IRQ0_INTE),
        force: @TypeOf(PIO0.IRQ0_INTF),
        status: @TypeOf(PIO0.IRQ0_INTS),
    };

    comptime {
        assert(@sizeOf([2]Regs) == (3 * 4 * 2));
    }

    pub const Source = enum {
        rx_not_empty,
        tx_not_full,
        // TODO: determine what this does, is it just a combination of the
        // first two, or is it other things?
        statemachine,
    };
};

pub const ExecOptions = struct {
    jmp_pin: ?gpio.Pin = null,
    wrap: u5 = 31,
    wrap_target: u5 = 0,
    side_pindir: bool = false,
    side_set_optional: bool = false,
};

pub fn PinMapping(comptime Count: type) type {
    return struct {
        /// Creates a mapping with a single pin, length 1
        pub fn single(pin: gpio.Pin) PinMapping(Count) {
            return .{ .low = pin, .high = pin };
        }

        low: gpio.Pin,
        high: gpio.Pin,

        pub fn count(range: @This()) Count {
            return @intCast(@backingInt(range.high) - @backingInt(range.low) + 1);
        }
    };
}

pub const PinMappingOptions = struct {
    out: ?PinMapping(u6) = null,
    set: ?PinMapping(u3) = null,
    side_set: ?PinMapping(u3) = null,
    in_base: ?gpio.Pin = null,
};

fn can_add_program_at_offset_mask(used_mask: u32, program: Program, offset: u5) bool {
    if (program.origin) |origin|
        if (origin != offset) return false;
    if (program.instructions.len == 0 or program.instructions.len > 32 - @as(usize, offset)) return false;
    return (used_mask & (program.get_mask() << offset)) == 0;
}

fn find_offset_for_program_mask(used_mask: u32, program: Program) error{NoSpace}!u5 {
    if (program.instructions.len == 0 or program.instructions.len > 32) return error.NoSpace;
    return if (program.origin) |origin| fixed: {
        if (origin < 0 or origin > 31) break :fixed error.NoSpace;
        const offset: u5 = @intCast(origin);
        break :fixed if (can_add_program_at_offset_mask(used_mask, program, offset)) offset else error.NoSpace;
    } else for (0..(33 - program.instructions.len)) |i| {
        const offset: u5 = @intCast(i);
        if (can_add_program_at_offset_mask(used_mask, program, offset)) break offset;
    } else error.NoSpace;
}

fn program_wrap(program: Program, offset: u5) u5 {
    return if (program.wrap) |wrap| wrap + offset else offset + @as(u5, @intCast(program.instructions.len - 1));
}

fn relocate_instruction(comptime chip: Chip, insn: u16, reloc: assembler.Relocation, offset: u5) u16 {
    return switch (reloc) {
        .none => insn,
        .jmpslot => blk: {
            var jmp: Instruction(chip) = @bitCast(insn);
            jmp.payload.jmp.address += offset;
            break :blk @bitCast(jmp);
        },
    };
}

// Keep the load/init sequence independent of MMIO so host tests can retain
// and check the returned offset alongside the configured addresses.
fn load_and_init_program(pio: anytype, sm: anytype, program: Program, options: anytype) !u5 {
    // We don't account for the optional bit here because it's not known to the pin_mappings
    const expected_side_set_pins = if (program.side_set) |side_set|
        side_set.count
    else
        0;

    const config_count = if (options.pin_mappings.side_set) |side_set| side_set.count() else 0;
    assert(expected_side_set_pins == config_count);

    // TODO: check program settings vs pin mapping
    const offset = try pio.add_program(program);

    try pio.sm_init(sm, offset, .{
        .clkdiv = options.clkdiv,
        .shift = options.shift,
        .pin_mappings = options.pin_mappings,
        .exec = .{
            .wrap = program_wrap(program, offset),

            .wrap_target = if (program.wrap_target) |wrap_target|
                wrap_target + offset // program.wrap_target is relative but actual wrap is absolute
            else
                offset,

            .side_pindir = if (program.side_set) |side_set|
                side_set.pindir
            else
                false,

            .side_set_optional = if (program.side_set) |side_set|
                side_set.optional
            else
                false,

            .jmp_pin = options.exec.jmp_pin,
        },
    });
    return offset;
}

pub fn PioImpl(EnumType: type, chip: Chip) type {
    return struct {
        pub fn get_instruction_memory(self: EnumType) *volatile [32]u32 {
            const regs = self.get_regs();
            return @as(*volatile [32]u32, @ptrCast(&regs.INSTR_MEM0));
        }

        pub fn can_add_program_at_offset(self: EnumType, program: Program, offset: u5) bool {
            return can_add_program_at_offset_mask(UsedInstructionSpace(chip).val[@backingInt(self)], program, offset);
        }

        pub fn find_offset_for_program(self: EnumType, program: Program) !u5 {
            return find_offset_for_program_mask(UsedInstructionSpace(chip).val[@backingInt(self)], program);
        }

        pub fn add_program_at_offset_unlocked(self: EnumType, program: Program, offset: u5) !void {
            if (!self.can_add_program_at_offset(program, offset))
                return error.NoSpace;

            const instruction_memory = self.get_instruction_memory();
            for (program.instructions, program.relocations, offset..) |insn, reloc, i|
                instruction_memory[i] = relocate_instruction(chip, insn, reloc, offset);

            const program_mask = program.get_mask();
            UsedInstructionSpace(chip).val[@backingInt(self)] |= program_mask << offset;
        }

        /// Public functions will need to lock independently, so only exposing this function for now
        pub fn add_program(self: EnumType, program: Program) !u5 {
            //const lock = hw.Lock.claim();
            //defer lock.unlock();

            const offset = try self.find_offset_for_program(program);
            try self.add_program_at_offset_unlocked(program, offset);
            return offset;
        }

        pub fn claim_unused_state_machine(self: EnumType) !StateMachine {
            // TODO: const lock = hw.Lock.claim()
            // defer lock.unlock();

            const claimed_mask = ClaimedStateMachines(chip).val[@backingInt(self)];
            return for (0..4) |i| {
                const sm_mask = (@as(u4, 1) << @as(u2, @intCast(i)));
                if (0 == (claimed_mask & sm_mask)) {
                    ClaimedStateMachines(chip).val[@backingInt(self)] |= sm_mask;
                    break @as(StateMachine, @fromBackingInt(@intCast(i)));
                }
            } else error.NoSpace;
        }

        pub fn set_input_sync_bypass(self: EnumType, pin: gpio.Pin) !void {
            const index = try pin_to_index(self, pin);
            const mask = @as(u32, 1) << index;
            var val = self.get_regs().INPUT_SYNC_BYPASS.raw;
            val |= mask;
            self.get_regs().INPUT_SYNC_BYPASS.write_raw(val);
        }

        pub fn get_sm_regs(self: EnumType, sm: StateMachine) *volatile StateMachine.Regs {
            const pio_regs = self.get_regs();
            // SM0_CLKDIV is the first one, which is why we are taking its address
            const sm_regs = @as(*volatile [4]StateMachine.Regs, @ptrCast(&pio_regs.SM0_CLKDIV));
            return &sm_regs[@backingInt(sm)];
        }

        pub fn get_irq_regs(self: EnumType, irq: Irq) *volatile Irq.Regs {
            const pio_regs = self.get_regs();
            const irq_regs = @as(*volatile [2]Irq.Regs, @ptrCast(&pio_regs.IRQ0_INTE));
            return &irq_regs[@backingInt(irq)];
        }

        pub fn sm_set_clkdiv(self: EnumType, sm: StateMachine, options: ClkDivOptions) void {
            if (options.int == 0 and options.frac != 0)
                @panic("invalid params");

            const sm_regs = self.get_sm_regs(sm);
            sm_regs.clkdiv.write(.{
                .INT = options.int,
                .FRAC = options.frac,
            });
        }

        fn pin_to_index(self: EnumType, pin: gpio.Pin) error{InvalidPin}!u5 {
            const index = @backingInt(pin);
            const base = self.get_gpio_base();
            if (index < base or index >= base + 32) {
                return error.InvalidPin;
            }
            return @intCast(index - base);
        }

        pub fn sm_set_exec_options(self: EnumType, sm: StateMachine, options: ExecOptions) !void {
            const sm_regs = self.get_sm_regs(sm);
            sm_regs.execctrl.modify(.{
                // NOTE: EXEC_STALLED is RO
                .WRAP_BOTTOM = options.wrap_target,
                .WRAP_TOP = options.wrap,
                .SIDE_PINDIR = @intFromBool(options.side_pindir),
                .SIDE_EN = @intFromBool(options.side_set_optional),
                .JMP_PIN = if (options.jmp_pin) |jmp_pin| try pin_to_index(self, jmp_pin) else 0,

                // TODO: plug in rest of the options
                // STATUS_N
                // STATUS_SEL
                // OUT_STICKY
                // INLINE_OUT_EN
                // OUT_EN_SEL
                // EXEC_STALLED
            });
        }

        pub fn sm_set_pin_mappings(self: EnumType, sm: StateMachine, options: PinMappingOptions, side_set_optional: bool) !void {
            const sm_regs = self.get_sm_regs(sm);
            sm_regs.pinctrl.modify(.{
                .OUT_BASE = if (options.out) |out| try pin_to_index(self, out.low) else 0,
                .OUT_COUNT = if (options.out) |out| out.count() else 0,

                .SET_BASE = if (options.set) |set| try pin_to_index(self, set.low) else 0,
                .SET_COUNT = if (options.set) |set| set.count() else 0,

                .SIDESET_BASE = if (options.side_set) |side_set| try pin_to_index(self, side_set.low) else 0,
                // If side set is set, but optional, we have to account for the 'enable' bit here.
                .SIDESET_COUNT = if (options.side_set) |side_set|
                    side_set.count() + @intFromBool(side_set_optional)
                else
                    0,

                .IN_BASE = if (options.in_base) |in_base| try pin_to_index(self, in_base) else 0,
            });
        }

        pub fn sm_set_pindir(self: EnumType, sm: StateMachine, base: gpio.Pin, count: u5, dir: gpio.Direction) !void {
            const sm_regs = self.get_sm_regs(sm);
            const reg_pinctrl__copy = sm_regs.pinctrl;
            const reg_execctrl__copy = sm_regs.execctrl;

            for (0..count) |counter| {
                const pin_config: PinMappingOptions = .{
                    .set = .single(@fromBackingInt(@intCast(@backingInt(base) + counter))),
                };
                try sm_set_pin_mappings(self, sm, pin_config, false);

                self.sm_exec(sm, .{
                    .payload = .{
                        .set = .{
                            .data = @backingInt(dir),
                            .destination = .pindirs,
                        },
                    },
                    .delay_side_set = 0,
                    .tag = .set,
                });
            }
            sm_regs.pinctrl = reg_pinctrl__copy;
            sm_regs.execctrl = reg_execctrl__copy;
        }

        pub fn sm_set_pin(self: EnumType, sm: StateMachine, base: gpio.Pin, count: u5, value: u1) !void {
            const sm_regs = self.get_sm_regs(sm);
            const reg_pinctrl__copy = sm_regs.pinctrl;
            const reg_execctrl__copy = sm_regs.execctrl;

            for (0..count) |counter| {
                const pin_config: PinMappingOptions = .{
                    .set = .single(@fromBackingInt(@intCast(@backingInt(base) + counter))),
                };
                try sm_set_pin_mappings(self, sm, pin_config, false);
                self.sm_exec(sm, .{
                    .payload = .{
                        .set = .{
                            .data = value,
                            .destination = .pins,
                        },
                    },
                    .delay_side_set = 0,
                    .tag = .set,
                });
            }
            sm_regs.pinctrl = reg_pinctrl__copy;
            sm_regs.execctrl = reg_execctrl__copy;
        }

        pub fn sm_get_rx_fifo(self: EnumType, sm: StateMachine) *volatile u32 {
            const regs = self.get_regs();
            const fifos = @as(*volatile [4]u32, @ptrCast(&regs.RXF0));
            return &fifos[@backingInt(sm)];
        }

        pub fn sm_is_rx_fifo_empty(self: EnumType, sm: StateMachine) bool {
            const regs = self.get_regs();
            const rxempty = regs.FSTAT.read().RXEMPTY;
            return (rxempty & (@as(u4, 1) << @backingInt(sm))) != 0;
        }

        pub fn sm_blocking_read(self: EnumType, sm: StateMachine) u32 {
            while (self.sm_is_rx_fifo_empty(sm)) {}
            return self.sm_read(sm);
        }

        pub fn sm_read(self: EnumType, sm: StateMachine) u32 {
            const fifo_ptr = self.sm_get_rx_fifo(sm);
            return fifo_ptr.*;
        }

        pub fn sm_is_tx_fifo_full(self: EnumType, sm: StateMachine) bool {
            const regs = self.get_regs();
            const txfull = regs.FSTAT.read().TXFULL;
            return (txfull & (@as(u4, 1) << @backingInt(sm))) != 0;
        }

        pub fn sm_get_tx_fifo(self: EnumType, sm: StateMachine) *volatile u32 {
            const regs = self.get_regs();
            const fifos = @as(*volatile [4]u32, @ptrCast(&regs.TXF0));
            return &fifos[@backingInt(sm)];
        }

        /// this function writes to the TX FIFO without checking that it's
        /// writable, if it's not then the value is ignored
        pub fn sm_write(self: EnumType, sm: StateMachine, value: u32) void {
            const fifo_ptr = self.sm_get_tx_fifo(sm);
            fifo_ptr.* = value;
        }

        pub fn sm_blocking_write(self: EnumType, sm: StateMachine, value: u32) void {
            while (self.sm_is_tx_fifo_full(sm)) {}

            self.sm_write(sm, value);
        }

        pub fn sm_set_enabled(self: EnumType, sm: StateMachine, enabled: bool) void {
            registers.sm_set_enabled(&self.get_regs().CTRL, @backingInt(sm), enabled);
        }

        pub fn sm_clear_debug(self: EnumType, sm: StateMachine) void {
            registers.sm_clear_debug(&self.get_regs().FDEBUG, @backingInt(sm));
        }

        pub fn sm_fifo_level(self: EnumType, sm: StateMachine, fifo: Fifo) u4 {
            const snum = @backingInt(sm);
            const offset: u5 = switch (fifo) {
                .tx => 0,
                .rx => 4,
            };

            const regs = self.get_regs();
            const levels = regs.FLEVEL.raw;

            return @as(u4, @truncate(levels >> (@as(u5, 8) * snum) + offset));
        }

        /// Clear this SM's IRQ flag. The flag is shared by both system IRQ lines.
        /// FIFO sources are level-sensitive and must be cleared by servicing the FIFO.
        pub fn sm_clear_interrupt(
            self: EnumType,
            sm: StateMachine,
            irq: Irq,
            source: Irq.Source,
        ) void {
            _ = irq;
            if (source != .statemachine) return;
            const regs = self.get_regs();
            registers.sm_clear_interrupt(&regs.IRQ, @backingInt(sm));
        }

        // TODO: be able to disable an interrupt
        pub fn sm_enable_interrupt(
            self: EnumType,
            sm: StateMachine,
            irq: Irq,
            source: Irq.Source,
        ) void {
            const irq_regs = self.get_irq_regs(irq);
            registers.sm_enable_interrupt(&irq_regs.enable, @backingInt(sm), @backingInt(source));
        }

        pub fn sm_restart(self: EnumType, sm: StateMachine) void {
            const mask: u4 = (@as(u4, 1) << @backingInt(sm));
            const regs = self.get_regs();
            regs.CTRL.modify(.{
                .SM_RESTART = mask,
            });
        }

        pub fn sm_clkdiv_restart(self: EnumType, sm: StateMachine) void {
            const mask: u4 = (@as(u4, 1) << @backingInt(sm));
            const regs = self.get_regs();
            regs.CTRL.modify(.{
                .CLKDIV_RESTART = mask,
            });
        }

        pub fn sm_init(
            self: EnumType,
            sm: StateMachine,
            initial_pc: u5,
            options: StateMachineInitOptions(chip),
        ) !void {
            // Halt the machine, set some sensible defaults
            self.sm_set_enabled(sm, false);
            self.sm_set_clkdiv(sm, options.clkdiv);
            try self.sm_set_exec_options(sm, options.exec);
            self.sm_set_shift_options(sm, options.shift);
            try self.sm_set_pin_mappings(sm, options.pin_mappings, options.exec.side_set_optional);

            self.sm_clear_fifos(sm);
            self.sm_clear_debug(sm);

            // Finally, clear some internal SM state
            self.sm_restart(sm);
            self.sm_clkdiv_restart(sm);
            self.sm_exec(sm, Instruction(chip){
                .tag = .jmp,

                .delay_side_set = 0,
                .payload = .{
                    .jmp = .{
                        .address = initial_pc,
                        .condition = .always,
                    },
                },
            });
        }

        pub fn sm_exec(self: EnumType, sm: StateMachine, instruction: Instruction(chip)) void {
            const sm_regs = self.get_sm_regs(sm);
            sm_regs.instr.raw = @as(u16, @bitCast(instruction));
        }

        pub fn sm_load_and_start_program(
            self: EnumType,
            sm: StateMachine,
            program: Program,
            options: LoadAndStartProgramOptions(chip),
        ) !u5 {
            return load_and_init_program(self, sm, program, options);
        }

        /// Set X with the SM stopped and TX FIFO empty.
        /// Leaves OSR empty (shift count 32); its previous value is lost.
        pub fn sm_exec_set_x(self: EnumType, sm: StateMachine, value: u32) void {
            exec.set_scratch(chip, self, sm, .x, value);
        }

        /// Set Y with the SM stopped and TX FIFO empty.
        /// Leaves OSR empty (shift count 32); its previous value is lost.
        pub fn sm_exec_set_y(self: EnumType, sm: StateMachine, value: u32) void {
            exec.set_scratch(chip, self, sm, .y, value);
        }

        pub fn sm_exec_set_pindir(self: EnumType, sm: StateMachine, data: u5) void {
            const inst = Instruction(chip){ .tag = .set, .delay_side_set = 0, .payload = .{ .set = .{ .destination = .pindirs, .data = data } } };
            sm_exec(self, sm, inst);
        }

        pub fn sm_exec_jmp(self: EnumType, sm: StateMachine, to_addr: u5) void {
            const inst = Instruction(chip){ .tag = .jmp, .delay_side_set = 0, .payload = .{ .jmp = .{ .address = to_addr, .condition = .always } } };
            sm_exec(self, sm, inst);
        }
    };
}

pub fn ShiftOptions(chip: Chip) type {
    return switch (chip) {
        .RP2040 => struct {
            autopush: bool = false,
            autopull: bool = false,
            in_shiftdir: Direction = .right,
            out_shiftdir: Direction = .right,
            /// 0 means full 32-bits
            push_threshold: u5 = 0,
            /// 0 means full 32-bits
            pull_threshold: u5 = 0,
            join_tx: bool = false,
            join_rx: bool = false,

            pub const Direction = enum(u1) {
                left,
                right,
            };
        },
        .RP2350 => struct {
            autopush: bool = false,
            autopull: bool = false,
            in_shiftdir: Direction = .right,
            out_shiftdir: Direction = .right,
            /// 0 means full 32-bits
            push_threshold: u5 = 0,
            /// 0 means full 32-bits
            pull_threshold: u5 = 0,
            join_tx: bool = false,
            join_rx: bool = false,

            fjoin_rx_get: bool = false,
            fjoin_rx_put: bool = false,
            in_count: u5 = 0,

            pub const Direction = enum(u1) {
                left,
                right,
            };
        },
    };
}

pub fn StateMachineInitOptions(chip: Chip) type {
    return struct {
        clkdiv: ClkDivOptions = .from_float(1.0),
        pin_mappings: PinMappingOptions = .{},
        exec: ExecOptions = .{},
        shift: ShiftOptions(chip) = .{},
    };
}

pub fn LoadAndStartProgramOptions(chip: Chip) type {
    return struct {
        clkdiv: ClkDivOptions = .from_float(1.0),
        shift: ShiftOptions(chip) = .{},
        pin_mappings: PinMappingOptions = .{},
        exec: ExecOptions = .{},
    };
}

test "loader searches final slot and whole instruction memory" {
    const one = comptime assembler.assemble(.RP2040, ".program one\nnop", .{}).get_program_by_name("one");
    try std.testing.expectEqual(@as(u5, 31), try find_offset_for_program_mask(0x7fffffff, one));
    var full = one;
    const instructions: [32]u16 = @splat(0xa042);
    full.instructions = &instructions;
    try std.testing.expectEqual(@as(u5, 0), try find_offset_for_program_mask(0, full));
    try std.testing.expectError(error.NoSpace, find_offset_for_program_mask(1, full));
}

test "loader wrap ends at last instruction" {
    const program = comptime assembler.assemble(.RP2040, ".program two\nnop\nnop", .{}).get_program_by_name("two");
    try std.testing.expectEqual(@as(u5, 1), program_wrap(program, 0));
    try std.testing.expectEqual(@as(u5, 31), program_wrap(program, 30));
}

test "loader origin relocation and raw words" {
    @setEvalBranchQuota(100_000);
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        const program = comptime assembler.assemble(chip,
            \\.program relocated
            \\.origin 4
            \\nop
            \\.wrap_target
            \\target:
            \\jmp target
            \\.word 0
            \\.wrap
        , .{}).get_program_by_name("relocated");
        const offset = try find_offset_for_program_mask(0, program);
        try std.testing.expectEqual(@as(u5, 4), offset);
        try std.testing.expect(!can_add_program_at_offset_mask(0, program, 0));
        try std.testing.expectError(error.NoSpace, find_offset_for_program_mask(0x10, program));
        try std.testing.expectEqual(@as(u16, 5), relocate_instruction(chip, program.instructions[1], program.relocations[1], offset));
        try std.testing.expectEqual(@as(u16, 0), relocate_instruction(chip, program.instructions[2], program.relocations[2], offset));
        try std.testing.expectEqual(@as(u5, 6), program_wrap(program, offset));
        try std.testing.expectEqual(@as(u5, 5), offset + program.wrap_target.?);
    }
}

test "load and init returns the offset used for subsequent program jumps" {
    const TestMapping = struct {
        fn count(_: @This()) u3 {
            return 0;
        }
    };
    const TestPio = struct {
        initial_pc: u5 = 0,
        wrap: u5 = 0,
        wrap_target: u5 = 0,
        fn add_program(_: *@This(), program: Program) !u5 {
            return find_offset_for_program_mask(0xf, program);
        }
        fn sm_init(self: *@This(), _: u2, pc: u5, options: anytype) !void {
            self.initial_pc = pc;
            self.wrap = options.exec.wrap;
            self.wrap_target = options.exec.wrap_target;
        }
    };
    @setEvalBranchQuota(100_000);
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        const program = comptime assembler.assemble(chip,
            \\.program resume
            \\nop
            \\.wrap_target
            \\nop
            \\.wrap
        , .{}).get_program_by_name("resume");
        var pio: TestPio = .{};
        const offset = try load_and_init_program(&pio, @as(u2, 0), program, .{
            .pin_mappings = .{ .side_set = @as(?TestMapping, null) },
            .clkdiv = {},
            .shift = {},
            .exec = .{ .jmp_pin = null },
        });
        try std.testing.expectEqual(@as(u5, 4), offset);
        try std.testing.expectEqual(offset, pio.initial_pc);
        try std.testing.expectEqual(@as(u5, 5), pio.wrap);
        try std.testing.expectEqual(@as(u5, 5), offset + program.wrap_target.?);
        try std.testing.expectEqual(pio.wrap_target, offset + program.wrap_target.?);
    }
}

fn TestLoader(comptime chip: Chip) type {
    return enum(u1) {
        pio0,
        pio1,
        const Self = @This();
        const Impl = PioImpl(Self, chip);
        var memory: [32]u32 = @splat(0);
        fn get_instruction_memory(_: Self) *volatile [32]u32 {
            return &memory;
        }
        const can_add_program_at_offset = Impl.can_add_program_at_offset;
        const find_offset_for_program = Impl.find_offset_for_program;
        const add_program_at_offset_unlocked = Impl.add_program_at_offset_unlocked;
        const add_program = Impl.add_program;
    };
}

test "loader writes all 32 instructions and reserves the whole memory" {
    @setEvalBranchQuota(100_000);
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        const program = comptime assembler.assemble(chip, ".program full\n" ++ "nop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\n", .{}).get_program_by_name("full");
        const pio: TestLoader(chip) = .pio0;
        const previous = UsedInstructionSpace(chip).val[0];
        UsedInstructionSpace(chip).val[0] = 0;
        defer UsedInstructionSpace(chip).val[0] = previous;
        TestLoader(chip).memory = @splat(0xffffffff);
        try std.testing.expectEqual(@as(u5, 0), try pio.add_program(program));
        for (TestLoader(chip).memory) |word| try std.testing.expectEqual(@as(u32, 0xa042), word);
        try std.testing.expectEqual(@as(u32, 0xffffffff), UsedInstructionSpace(chip).val[0]);
        try std.testing.expectError(error.NoSpace, pio.add_program(program));
        try std.testing.expectEqual(@as(u5, 31), program_wrap(program, 0));
    }
}

test "pioasm origins outside instruction memory cannot load" {
    inline for (.{ 32, -2, 2147483647 }) |origin| {
        const program = comptime assembler.assemble(.RP2040, std.fmt.comptimePrint(".program p\n.origin ({})\nnop\n", .{origin}), .{}).get_program_by_name("p");
        try std.testing.expectEqual(@as(?i32, origin), program.origin);
        try std.testing.expectError(error.NoSpace, find_offset_for_program_mask(0, program));
    }
    const automatic = comptime assembler.assemble(.RP2040, ".program p\n.origin (-1)\nnop\n", .{}).get_program_by_name("p");
    try std.testing.expectEqual(@as(?i32, null), automatic.origin);
    try std.testing.expectEqual(@as(u5, 0), try find_offset_for_program_mask(0, automatic));
}
