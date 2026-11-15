const std = @import("std");

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
const runtime = @import("runtime.zig");
const hw = @import("../hw.zig");

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

pub const Fifo = runtime.Fifo;
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
};
pub const InterruptLine = runtime.InterruptLine;
pub const InterruptSource = union(enum) {
    rx_not_empty: StateMachine,
    tx_not_full: StateMachine,
    flag: u3,
};
pub const InterruptRegs = extern struct {
    enable: @TypeOf(PIO0.IRQ0_INTE),
    force: @TypeOf(PIO0.IRQ0_INTF),
    status: @TypeOf(PIO0.IRQ0_INTS),
};
pub const Status = runtime.Status;
pub const Fdebug = runtime.Fdebug;
pub const DebugConfig = runtime.DebugConfig;

// This spinlock is held only for short resource bookkeeping / instruction-memory
// writes. Disable local IRQs before taking it so an ISR cannot deadlock its core.
const resource_lock = @import("../multicore.zig").Spinlock.pio;
pub fn lock_resources() microzig.interrupt.CriticalSection {
    return resource_lock.lock_irq();
}
pub fn unlock_resources(cs: microzig.interrupt.CriticalSection) void {
    resource_lock.unlock_irq(cs);
}

pub const ExecOptions = struct {
    status: Status = .{ .tx_level = 0 },
    out_sticky: bool = false,
    inline_out_en: bool = false,
    out_en_sel: u5 = 0,
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

        pub fn with_base(mapping: @This(), base: gpio.Pin) @This() {
            return .{ .low = base, .high = @fromBackingInt(@as(u5, @truncate(@backingInt(base) + @as(u8, mapping.count()) - 1))) };
        }

        low: gpio.Pin,
        high: gpio.Pin,

        pub fn count(range: @This()) u6 {
            return @intCast((@as(u8, @intCast(@backingInt(range.high))) + 64 - @as(u8, @intCast(@backingInt(range.low)))) % 32 + 1);
        }
    };
}

pub const PinMappingOptions = struct {
    out: ?PinMapping(u6) = null,
    set: ?PinMapping(u3) = null,
    side_set: ?PinMapping(u3) = null,
    in_base: ?gpio.Pin = null,
    /// Optional input range, used to validate a program's .in pin count.
    in: ?PinMapping(u6) = null,
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
    const offset = try pio.add_program(program);
    errdefer pio.remove_program(program, offset) catch @panic("loader reservation lost");
    var exec_options = options.exec;
    if (@as(u6, exec_options.wrap) + offset > 31 or @as(u6, exec_options.wrap_target) + offset > 31) return error.InvalidWrap;
    exec_options.wrap += offset;
    exec_options.wrap_target += offset;
    try pio.sm_init(sm, offset, .{
        .clkdiv = options.clkdiv,
        .shift = options.shift,
        .pin_mappings = options.pin_mappings,
        .exec = exec_options,
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
            const cs = EnumType.lock_resources();
            defer EnumType.unlock_resources(cs);
            return can_add_program_at_offset_mask(UsedInstructionSpace(chip).val[@backingInt(self)], program, offset);
        }

        pub fn find_offset_for_program(self: EnumType, program: Program) !u5 {
            const cs = EnumType.lock_resources();
            defer EnumType.unlock_resources(cs);
            return find_offset_for_program_mask(UsedInstructionSpace(chip).val[@backingInt(self)], program);
        }

        fn add_program_unlocked(self: EnumType, program: Program, offset: u5) !void {
            if (!can_add_program_at_offset_mask(UsedInstructionSpace(chip).val[@backingInt(self)], program, offset)) return error.NoSpace;
            if (program.pio_version > @as(u1, if (chip == .RP2040) 0 else 1)) return error.UnsupportedProgramVersion;
            const memory = self.get_instruction_memory();
            for (program.instructions, program.relocations, offset..) |insn, reloc, i|
                memory[i] = relocate_instruction(chip, insn, reloc, offset);
            UsedInstructionSpace(chip).val[@backingInt(self)] |= program.get_mask() << offset;
        }

        pub fn add_program_at_offset(self: EnumType, program: Program, offset: u5) !void {
            const cs = EnumType.lock_resources();
            defer EnumType.unlock_resources(cs);
            try add_program_unlocked(self, program, offset);
        }

        pub fn add_program(self: EnumType, program: Program) !u5 {
            const cs = EnumType.lock_resources();
            defer EnumType.unlock_resources(cs);
            const offset = try find_offset_for_program_mask(UsedInstructionSpace(chip).val[@backingInt(self)], program);
            try add_program_unlocked(self, program, offset);
            return offset;
        }

        /// Stop every SM using this program before releasing its memory.
        pub fn remove_program(self: EnumType, program: Program, offset: u5) !void {
            const cs = EnumType.lock_resources();
            defer EnumType.unlock_resources(cs);
            if (program.instructions.len == 0 or program.instructions.len > 32 - @as(usize, offset)) return error.InvalidProgram;
            const mask = program.get_mask() << offset;
            const used = &UsedInstructionSpace(chip).val[@backingInt(self)];
            if (used.* & mask != mask) return error.ProgramNotLoaded;
            used.* &= ~mask;
        }

        /// Stop all SMs first. Fill memory with self-jumps, like pico-sdk.
        pub fn clear_instruction_memory(self: EnumType) void {
            const cs = EnumType.lock_resources();
            defer EnumType.unlock_resources(cs);
            for (0..32) |i| self.get_instruction_memory()[i] = @intCast(i);
            UsedInstructionSpace(chip).val[@backingInt(self)] = 0;
        }

        pub fn claim_sm_mask(self: EnumType, mask: u4) !void {
            const cs = EnumType.lock_resources();
            defer EnumType.unlock_resources(cs);
            const claimed = &ClaimedStateMachines(chip).val[@backingInt(self)];
            claimed.* = try runtime.claim_mask(claimed.*, mask);
        }
        pub fn claim_state_machine(self: EnumType, sm: StateMachine) !void {
            try self.claim_sm_mask(@as(u4, 1) << @backingInt(sm));
        }
        pub fn unclaim(self: EnumType, sm: StateMachine) void {
            const cs = EnumType.lock_resources();
            defer EnumType.unlock_resources(cs);
            ClaimedStateMachines(chip).val[@backingInt(self)] &= ~(@as(u4, 1) << @backingInt(sm));
        }
        pub fn is_claimed(self: EnumType, sm: StateMachine) bool {
            const cs = EnumType.lock_resources();
            defer EnumType.unlock_resources(cs);
            return ClaimedStateMachines(chip).val[@backingInt(self)] & (@as(u4, 1) << @backingInt(sm)) != 0;
        }
        pub fn claim_unused_state_machine(self: EnumType) !StateMachine {
            const cs = EnumType.lock_resources();
            defer EnumType.unlock_resources(cs);
            const claimed = &ClaimedStateMachines(chip).val[@backingInt(self)];
            const sm = try runtime.first_unused(claimed.*);
            claimed.* = try runtime.claim_mask(claimed.*, @as(u4, 1) << @backingInt(sm));
            return @fromBackingInt(@backingInt(sm));
        }

        pub fn set_input_sync_bypass(self: EnumType, pin: gpio.Pin) !void {
            const index = try pin_to_index(self, pin);
            const mask = @as(u32, 1) << index;
            self.set_input_sync_bypass_mask(mask, true);
        }

        /// Mask bits are relative to this PIO's GPIO base.
        pub fn set_input_sync_bypass_mask(self: EnumType, mask: u32, bypass: bool) void {
            const reg = &self.get_regs().INPUT_SYNC_BYPASS;
            (if (bypass) hw.set_alias(reg) else hw.clear_alias(reg)).write_raw(mask);
        }

        pub fn get_sm_regs(self: EnumType, sm: StateMachine) *volatile StateMachine.Regs {
            const pio_regs = self.get_regs();
            // SM0_CLKDIV is the first one, which is why we are taking its address
            const sm_regs = @as(*volatile [4]StateMachine.Regs, @ptrCast(&pio_regs.SM0_CLKDIV));
            return &sm_regs[@backingInt(sm)];
        }

        pub fn get_irq_regs(self: EnumType, irq: InterruptLine) *volatile InterruptRegs {
            const pio_regs = self.get_regs();
            const irq_regs = @as(*volatile [2]InterruptRegs, @ptrCast(&pio_regs.IRQ0_INTE));
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
            // EXEC_STALLED is read-only; write only the configured fields.
            // 40DS §3.7 / 50DS §11.7 SMx_EXECCTRL.
            sm_regs.execctrl.write_raw(runtime.exec_bits(options, if (options.jmp_pin) |pin| try pin_to_index(self, pin) else 0));
        }

        pub fn sm_set_pin_mappings(self: EnumType, sm: StateMachine, options: PinMappingOptions, side_set_optional: bool) !void {
            try validate_pin_mappings(options, side_set_optional);
            inline for (.{ "out", "set", "side_set", "in" }) |field| {
                if (@field(options, field)) |pins| {
                    _ = try pin_to_index(self, pins.low);
                    _ = try pin_to_index(self, pins.high);
                }
            }
            const sm_regs = self.get_sm_regs(sm);
            sm_regs.pinctrl.modify(.{
                .OUT_BASE = if (options.out) |out| try pin_to_index(self, out.low) else 0,
                .OUT_COUNT = if (options.out) |out| out.count() else 0,

                .SET_BASE = if (options.set) |set| try pin_to_index(self, set.low) else 0,
                .SET_COUNT = if (options.set) |set| @as(u3, @intCast(set.count())) else 0,

                .SIDESET_BASE = if (options.side_set) |side_set| try pin_to_index(self, side_set.low) else 0,
                // If side set is set, but optional, we have to account for the 'enable' bit here.
                .SIDESET_COUNT = @as(u3, @intCast((if (options.side_set) |pins| pins.count() else @as(u6, 0)) + @intFromBool(side_set_optional))),

                .IN_BASE = if (options.in) |input| try pin_to_index(self, input.low) else if (options.in_base) |in_base| try pin_to_index(self, in_base) else 0,
            });
        }

        /// SM must be stopped; pin/exec configuration is restored after injection.
        pub fn sm_set_consecutive_pindirs(self: EnumType, sm: StateMachine, base: gpio.Pin, count: u6, dir: gpio.Direction) !void {
            if (count > 32) return error.InvalidPinCount;
            exec.set_consecutive_pindirs(chip, self, sm, try pin_to_index(self, base), count, dir == .out);
        }
        pub fn sm_set_pindir(self: EnumType, sm: StateMachine, base: gpio.Pin, count: u5, dir: gpio.Direction) !void {
            try self.sm_set_consecutive_pindirs(sm, base, count, dir);
        }
        /// Mask bits are relative to this PIO's GPIO base. SM must be stopped.
        pub fn sm_set_pins_with_mask(self: EnumType, sm: StateMachine, values: u32, mask: u32) void {
            exec.set_with_mask(chip, self, sm, values, mask, .pins);
        }
        pub fn sm_set_pindirs_with_mask(self: EnumType, sm: StateMachine, dirs: u32, mask: u32) void {
            exec.set_with_mask(chip, self, sm, dirs, mask, .pindirs);
        }
        pub fn sm_set_pin(self: EnumType, sm: StateMachine, base: gpio.Pin, count: u5, value: u1) !void {
            const index = try pin_to_index(self, base);
            var mask: u32 = 0;
            for (0..count) |i| mask |= @as(u32, 1) << (index +% @as(u5, @intCast(i)));
            self.sm_set_pins_with_mask(sm, if (value == 1) mask else 0, mask);
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

        pub fn irq_flags(self: EnumType) u8 {
            return @truncate(self.get_regs().IRQ.raw);
        }
        pub fn clear_irq_flags(self: EnumType, mask: u8) void {
            // IRQ is W1C; never read-modify-write (40DS §3.7, 50DS §11.7).
            registers.clear_irq_flags(&self.get_regs().IRQ, mask);
        }
        pub fn force_irq_flags(self: EnumType, mask: u8) void {
            self.get_regs().IRQ_FORCE.write_raw(mask);
        }
        fn source_mask(source: InterruptSource) !u32 {
            return runtime.interrupt_mask(chip, switch (source) {
                .rx_not_empty => |sm| .{ .rx_not_empty = @fromBackingInt(@backingInt(sm)) },
                .tx_not_full => |sm| .{ .tx_not_full = @fromBackingInt(@backingInt(sm)) },
                .flag => |flag| .{ .flag = flag },
            });
        }
        pub fn set_interrupt_enabled(self: EnumType, line: InterruptLine, source: InterruptSource, enabled: bool) !void {
            const reg = &self.get_irq_regs(line).enable;
            (if (enabled) hw.set_alias(reg) else hw.clear_alias(reg)).write_raw(try source_mask(source));
        }
        /// INTF forces a system interrupt source, independently of SM IRQ flags.
        pub fn set_interrupt_forced(self: EnumType, line: InterruptLine, source: InterruptSource, forced: bool) !void {
            const reg = &self.get_irq_regs(line).force;
            (if (forced) hw.set_alias(reg) else hw.clear_alias(reg)).write_raw(try source_mask(source));
        }
        pub fn interrupt_status(self: EnumType, line: InterruptLine, source: InterruptSource) !bool {
            return self.get_irq_regs(line).status.raw & try source_mask(source) != 0;
        }
        pub fn irq_number(self: EnumType, line: InterruptLine) microzig.cpu.Interrupt {
            return @fromBackingInt(runtime.irq_number(chip, @intCast(@backingInt(self)), line) catch unreachable);
        }
        pub fn sm_dreq(self: EnumType, sm: StateMachine, fifo: Fifo) @import("../dma.zig").Dreq {
            return @fromBackingInt(runtime.dreq_number(chip, @intCast(@backingInt(self)), @fromBackingInt(@backingInt(sm)), fifo) catch unreachable);
        }
        pub fn set_sm_mask_enabled(self: EnumType, mask: u4, enabled: bool) void {
            const reg = &self.get_regs().CTRL;
            (if (enabled) hw.set_alias(reg) else hw.clear_alias(reg)).write_raw(runtime.ctrl_mask(mask, .enable));
        }
        pub fn restart_sm_mask(self: EnumType, mask: u4) void {
            hw.set_alias(&self.get_regs().CTRL).write_raw(runtime.ctrl_mask(mask, .restart));
        }
        pub fn clkdiv_restart_sm_mask(self: EnumType, mask: u4) void {
            hw.set_alias(&self.get_regs().CTRL).write_raw(runtime.ctrl_mask(mask, .clkdiv_restart));
        }
        pub fn enable_sm_mask_in_sync(self: EnumType, mask: u4) void {
            // One SET-alias store enables and restarts dividers on the same cycle.
            // 40DS §3.2.4, 50DS §11.2.4 and CTRL register description.
            hw.set_alias(&self.get_regs().CTRL).write_raw(runtime.ctrl_mask(mask, .enable_in_sync));
        }
        pub fn sm_restart(self: EnumType, sm: StateMachine) void {
            self.restart_sm_mask(@as(u4, 1) << @backingInt(sm));
        }
        pub fn sm_clkdiv_restart(self: EnumType, sm: StateMachine) void {
            self.clkdiv_restart_sm_mask(@as(u4, 1) << @backingInt(sm));
        }
        pub fn sm_get_pc(self: EnumType, sm: StateMachine) u5 {
            return @truncate(self.get_sm_regs(sm).addr.raw);
        }
        pub fn sm_is_exec_stalled(self: EnumType, sm: StateMachine) bool {
            return self.get_sm_regs(sm).execctrl.read().EXEC_STALLED != 0;
        }
        /// Explicitly blocking: the caller must arrange for the instruction to
        /// complete (e.g. an external WAIT input or FIFO consumer).
        pub fn sm_exec_wait_blocking(self: EnumType, sm: StateMachine, instruction: Instruction(chip)) void {
            self.sm_exec(sm, instruction);
            while (self.sm_is_exec_stalled(sm)) {}
        }
        pub fn sm_is_rx_fifo_full(self: EnumType, sm: StateMachine) bool {
            return self.get_regs().FSTAT.read().RXFULL & (@as(u4, 1) << @backingInt(sm)) != 0;
        }
        pub fn sm_is_tx_fifo_empty(self: EnumType, sm: StateMachine) bool {
            return self.get_regs().FSTAT.read().TXEMPTY & (@as(u4, 1) << @backingInt(sm)) != 0;
        }
        /// Stop the SM and DMA producer first. Discards TX data, leaves RX intact
        /// and clobbers OSR (40DS §3.4.5/§3.4.7, 50DS §11.4.5/§11.4.7).
        pub fn sm_drain_tx_fifo(self: EnumType, sm: StateMachine) void {
            const autopull = self.get_sm_regs(sm).shiftctrl.read().AUTOPULL != 0;
            // Each injection consumes a word; at most eight FIFO words exist.
            while (!self.sm_is_tx_fifo_empty(sm)) self.sm_exec(sm, exec.drain_instruction(chip, autopull));
        }
        pub fn sm_fdebug(self: EnumType, sm: StateMachine) Fdebug {
            return runtime.fdebug(self.get_regs().FDEBUG.raw, @fromBackingInt(@backingInt(sm)));
        }
        pub fn dbg_padout(self: EnumType) u32 {
            return self.get_regs().DBG_PADOUT.raw;
        }
        pub fn dbg_padoe(self: EnumType) u32 {
            return self.get_regs().DBG_PADOE.raw;
        }
        pub fn dbg_cfginfo(self: EnumType) DebugConfig {
            return runtime.debug_config(self.get_regs().DBG_CFGINFO.raw);
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
            var config = try default_config(chip, program);
            config.pin_mappings = options.pin_mappings;
            if (options.clkdiv) |clkdiv| config.clkdiv = clkdiv;
            if (options.shift) |shift| config.shift = shift;
            config.exec = runtime.apply_exec_overrides(config.exec, options.exec);
            try validate_program_mappings(program, config.pin_mappings, config.exec.side_set_optional);
            return load_and_init_program(self, sm, program, config);
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

pub const ShiftOptions = runtime.ShiftOptions;

pub fn StateMachineInitOptions(chip: Chip) type {
    return struct {
        clkdiv: ClkDivOptions = .from_float(1.0),
        pin_mappings: PinMappingOptions = .{},
        exec: ExecOptions = .{},
        shift: ShiftOptions(chip) = .{},
    };
}

/// Null fields retain the defaults derived from the assembled program.
/// Wrap addresses are relative to the program's load offset.
pub const ExecOverrides = struct {
    jmp_pin: ?gpio.Pin = null,
    wrap: ?u5 = null,
    wrap_target: ?u5 = null,
    side_pindir: ?bool = null,
    side_set_optional: ?bool = null,
    status: ?Status = null,
    out_sticky: ?bool = null,
    inline_out_en: ?bool = null,
    out_en_sel: ?u5 = null,
};
pub fn LoadAndStartProgramOptions(chip: Chip) type {
    return struct {
        clkdiv: ?ClkDivOptions = null,
        shift: ?ShiftOptions(chip) = null,
        pin_mappings: PinMappingOptions = .{},
        exec: ExecOverrides = .{},
    };
}

pub fn clkdiv_from_hz(sys_hz: u32, sm_hz: u32) !ClkDivOptions {
    const div = try runtime.clkdiv_from_hz(sys_hz, sm_hz);
    return .{ .int = div.int, .frac = div.frac };
}

/// Derive all program defaults, with pin ranges initially based at GPIO 0.
/// Rebase those ranges with PinMapping.with_base before initializing hardware.
pub fn default_config(comptime chip: Chip, program: Program) !StateMachineInitOptions(chip) {
    const defaults = try runtime.default_config(program);
    var config: StateMachineInitOptions(chip) = .{};
    const divider = try runtime.clkdiv_from_float(defaults.clock_div);
    config.clkdiv = .{ .int = divider.int, .frac = divider.frac };
    config.exec.wrap = defaults.wrap;
    config.exec.wrap_target = defaults.wrap_target;
    config.exec.side_pindir = defaults.side_pindir;
    config.exec.side_set_optional = defaults.side_set_optional;
    config.exec.status = defaults.status;
    config.shift = runtime.default_shift_config(chip, defaults);
    if (defaults.out_shift) |output| if (output.count > 0) {
        config.pin_mappings.out = mapping_from_count(u6, output.count);
    };
    if (defaults.in_shift) |input| if (input.count > 0) {
        config.pin_mappings.in = mapping_from_count(u6, input.count);
    };
    if (defaults.set_count) |count| if (count > 0) {
        config.pin_mappings.set = mapping_from_count(u3, count);
    };
    if (defaults.side_set_count > 0) config.pin_mappings.side_set = mapping_from_count(u3, defaults.side_set_count);
    return config;
}

fn mapping_from_count(comptime Count: type, count: u6) PinMapping(Count) {
    return .{ .low = @fromBackingInt(0), .high = @fromBackingInt(@as(u5, @intCast(count - 1))) };
}

fn mapping_counts(mapping: PinMappingOptions) runtime.PinCounts {
    return .{
        .out = if (mapping.out) |pins| pins.count() else 0,
        .set = if (mapping.set) |pins| pins.count() else 0,
        .side_set = if (mapping.side_set) |pins| pins.count() else 0,
        .in = if (mapping.in) |pins| pins.count() else null,
    };
}
fn validate_pin_mappings(mapping: PinMappingOptions, optional: bool) !void {
    try runtime.validate_pin_counts(mapping_counts(mapping), optional);
    if (mapping.in != null and mapping.in_base != null) return error.AmbiguousInputMapping;
}
fn validate_program_mappings(program: Program, mapping: PinMappingOptions, optional: bool) !void {
    try validate_pin_mappings(mapping, optional);
    try runtime.validate_program_counts(program, mapping_counts(mapping), mapping.in_base != null);
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
    const TestExec = struct { wrap: u5, wrap_target: u5 };
    const TestPio = struct {
        initial_pc: u5 = 0,
        wrap: u5 = 0,
        wrap_target: u5 = 0,
        fn add_program(_: *@This(), program: Program) !u5 {
            return find_offset_for_program_mask(0xf, program);
        }
        fn remove_program(_: *@This(), _: Program, _: u5) !void {}
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
            .pin_mappings = .{},
            .clkdiv = {},
            .shift = {},
            .exec = TestExec{ .wrap = program_wrap(program, 0), .wrap_target = program.wrap_target orelse 0 },
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
        fn lock_resources() void {
            std.debug.assert(lock_depth == 0);
            lock_depth += 1;
            lock_count += 1;
        }
        fn unlock_resources(_: void) void {
            std.debug.assert(lock_depth == 1);
            lock_depth -= 1;
        }
        var lock_depth: u8 = 0;
        var lock_count: usize = 0;
        const add_program_at_offset = Impl.add_program_at_offset;
        const add_program = Impl.add_program;
        const remove_program = Impl.remove_program;
        const clear_instruction_memory = Impl.clear_instruction_memory;
        const claim_sm_mask = Impl.claim_sm_mask;
        const claim_state_machine = Impl.claim_state_machine;
        const claim_unused_state_machine = Impl.claim_unused_state_machine;
        const is_claimed = Impl.is_claimed;
        const unclaim = Impl.unclaim;
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

test "loads removals clears and claims each hold one resource lock" {
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        const Loader = TestLoader(chip);
        const pio: Loader = .pio1;
        const program = comptime assembler.assemble(chip, ".program p\nnop\nnop", .{}).get_program_by_name("p");
        const used = UsedInstructionSpace(chip).val[1];
        const claimed = ClaimedStateMachines(chip).val[1];
        defer UsedInstructionSpace(chip).val[1] = used;
        defer ClaimedStateMachines(chip).val[1] = claimed;
        UsedInstructionSpace(chip).val[1] = 0;
        ClaimedStateMachines(chip).val[1] = 0;
        Loader.lock_count = 0;
        try pio.add_program_at_offset(program, 30);
        try std.testing.expectEqual(@as(usize, 1), Loader.lock_count);
        try std.testing.expectError(error.NoSpace, pio.add_program_at_offset(program, 30));
        try std.testing.expectEqual(@as(u8, 0), Loader.lock_depth);
        try pio.remove_program(program, 30);
        try std.testing.expectEqual(@as(u32, 0), UsedInstructionSpace(chip).val[1]);
        try std.testing.expectError(error.ProgramNotLoaded, pio.remove_program(program, 30));
        try pio.add_program_at_offset(program, 0);
        pio.clear_instruction_memory();
        try std.testing.expectEqual(@as(u32, 0), UsedInstructionSpace(chip).val[1]);
        for (Loader.memory, 0..) |word, i| try std.testing.expectEqual(@as(u32, @intCast(i)), word);
        try pio.claim_sm_mask(0b1010);
        try std.testing.expect(pio.is_claimed(.sm1) and pio.is_claimed(.sm3));
        try std.testing.expectError(error.AlreadyClaimed, pio.claim_sm_mask(0b0110));
        try std.testing.expect(!pio.is_claimed(.sm2));
        try std.testing.expectEqual(StateMachine.sm0, try pio.claim_unused_state_machine());
        try pio.claim_state_machine(.sm2);
        try std.testing.expectError(error.NoSpace, pio.claim_unused_state_machine());
        pio.unclaim(.sm1);
        try std.testing.expectEqual(StateMachine.sm1, try pio.claim_unused_state_machine());
        try std.testing.expectEqual(@as(u8, 0), Loader.lock_depth);
    }
}

test "failed initialization releases instruction memory" {
    const TestPio = struct {
        removed: bool = false,
        fn add_program(_: *@This(), _: Program) !u5 {
            return 1;
        }
        fn remove_program(self: *@This(), _: Program, offset: u5) !void {
            try std.testing.expectEqual(@as(u5, 1), offset);
            self.removed = true;
        }
        fn sm_init(_: *@This(), _: u2, _: u5, _: anytype) !void {
            return error.InvalidPin;
        }
    };
    const Exec = struct { wrap: u5 = 0, wrap_target: u5 = 0 };
    const program = comptime assembler.assemble(.RP2040, ".program p\nnop", .{}).get_program_by_name("p");
    var pio: TestPio = .{};
    try std.testing.expectError(error.InvalidPin, load_and_init_program(&pio, @as(u2, 0), program, .{ .clkdiv = {}, .shift = {}, .pin_mappings = {}, .exec = Exec{} }));
    try std.testing.expect(pio.removed);
    pio.removed = false;
    try std.testing.expectError(error.InvalidWrap, load_and_init_program(&pio, @as(u2, 0), program, .{ .clkdiv = {}, .shift = {}, .pin_mappings = {}, .exec = Exec{ .wrap = 31 } }));
    try std.testing.expect(pio.removed);
}
