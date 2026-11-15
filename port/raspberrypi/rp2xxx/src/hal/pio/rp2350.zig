const microzig = @import("microzig");

const std = @import("std");
const runtime = @import("runtime.zig");

const common = @import("common.zig");

const gpio = @import("../gpio.zig");
const hw = @import("../hw.zig");

const PIO2 = microzig.chip.peripherals.PIO2;

pub const Pio = enum(u2) {
    pio0 = 0,
    pio1 = 1,
    pio2 = 2,

    const PioImpl = common.PioImpl(Pio, .RP2350);
    pub const has_rp2350b = @import("../compatibility.zig").has_rp2350b;

    pub fn get_regs(self: Pio) *volatile common.PIO {
        const regs = switch (self) {
            .pio0 => common.PIO0,
            .pio1 => common.PIO1,
            .pio2 => PIO2,
        };
        // 50DS §11.7 DBG_CFGINFO.VERSION, checked from the first register access.
        if (@import("builtin").mode == .debug) std.debug.assert(regs.DBG_CFGINFO.raw >> 28 == 1);
        return regs;
    }

    pub const add_program_at_offset = PioImpl.add_program_at_offset;
    pub const remove_program = PioImpl.remove_program;
    pub const clear_instruction_memory = PioImpl.clear_instruction_memory;
    pub const claim_state_machine = PioImpl.claim_state_machine;
    pub const claim_sm_mask = PioImpl.claim_sm_mask;
    pub const unclaim = PioImpl.unclaim;
    pub const is_claimed = PioImpl.is_claimed;
    pub const set_input_sync_bypass_mask = PioImpl.set_input_sync_bypass_mask;
    pub const irq_flags = PioImpl.irq_flags;
    pub const clear_irq_flags = PioImpl.clear_irq_flags;
    pub const force_irq_flags = PioImpl.force_irq_flags;
    pub const set_interrupt_enabled = PioImpl.set_interrupt_enabled;
    pub const set_interrupt_forced = PioImpl.set_interrupt_forced;
    pub const interrupt_status = PioImpl.interrupt_status;
    pub const irq_number = PioImpl.irq_number;
    pub const sm_dreq = PioImpl.sm_dreq;
    pub const set_sm_mask_enabled = PioImpl.set_sm_mask_enabled;
    pub const restart_sm_mask = PioImpl.restart_sm_mask;
    pub const clkdiv_restart_sm_mask = PioImpl.clkdiv_restart_sm_mask;
    pub const enable_sm_mask_in_sync = PioImpl.enable_sm_mask_in_sync;
    pub const sm_get_pc = PioImpl.sm_get_pc;
    pub const sm_is_exec_stalled = PioImpl.sm_is_exec_stalled;
    pub const sm_exec_wait_blocking = PioImpl.sm_exec_wait_blocking;
    pub const sm_is_rx_fifo_full = PioImpl.sm_is_rx_fifo_full;
    pub const sm_is_tx_fifo_empty = PioImpl.sm_is_tx_fifo_empty;
    pub const sm_drain_tx_fifo = PioImpl.sm_drain_tx_fifo;
    pub const sm_fdebug = PioImpl.sm_fdebug;
    pub const dbg_padout = PioImpl.dbg_padout;
    pub const dbg_padoe = PioImpl.dbg_padoe;
    pub const dbg_cfginfo = PioImpl.dbg_cfginfo;
    pub const sm_set_consecutive_pindirs = PioImpl.sm_set_consecutive_pindirs;
    pub const sm_set_pins_with_mask = PioImpl.sm_set_pins_with_mask;
    pub const sm_set_pindirs_with_mask = PioImpl.sm_set_pindirs_with_mask;
    pub const lock_resources = common.lock_resources;
    pub const unlock_resources = common.unlock_resources;

    pub const get_instruction_memory = PioImpl.get_instruction_memory;

    /// RP2350-E9 (50DS §D.5.1): Bank 0 inputs on A2 silicon leak current.
    /// PIO cannot toggle pad controls; inputs using pull-downs need an external
    /// resistor of at most 8.2 kΩ. GPIO 30–47 require a board declaring
    /// has_rp2350b; other boards are treated as RP2350A (GPIO 0–29).
    pub fn gpio_init(self: Pio, pin: gpio.Pin) void {
        if (!has_rp2350b and @backingInt(pin) >= 30) @panic("GPIO 30–47 require RP2350B");
        pin.set_function(switch (self) {
            .pio0 => .pio0,
            .pio1 => .pio1,
            .pio2 => .pio2,
        });
    }

    pub const can_add_program_at_offset = PioImpl.can_add_program_at_offset;
    pub const find_offset_for_program = PioImpl.find_offset_for_program;
    pub const add_program = PioImpl.add_program;
    pub const claim_unused_state_machine = PioImpl.claim_unused_state_machine;
    pub const set_input_sync_bypass = PioImpl.set_input_sync_bypass;
    pub const get_sm_regs = PioImpl.get_sm_regs;
    pub const get_irq_regs = PioImpl.get_irq_regs;
    pub const sm_set_clkdiv = PioImpl.sm_set_clkdiv;
    pub fn get_gpio_base(self: Pio) u32 {
        // Base is either 0 or 16
        return 0x10 & self.get_regs().GPIOBASE.raw;
    }
    pub const GpioBase = runtime.GpioBase;
    pub const BlockMasks = runtime.BlockMasks;

    /// Change the 32-pin window only with empty instruction memory and no claimed SMs.
    /// GPIOBASE affects pin mappings even for SMs driven through injected instructions
    /// (50DS §11.7 GPIOBASE, §11.5.7). Stop and release affected SMs first.
    pub fn set_gpio_base(self: Pio, base: GpioBase) !void {
        const cs = common.lock_resources();
        defer common.unlock_resources(cs);
        try runtime.validate_gpio_base(PioImpl.used_instruction_space(self), PioImpl.claimed_state_machines(self));
        self.get_regs().GPIOBASE.write_raw(@backingInt(base));
    }

    pub const ClaimedProgram = struct { pio: Pio, sm: common.StateMachine, offset: u5 };
    /// Atomically reserve an SM, a compatible GPIO window and program memory.
    /// Stop/reconfigure SMs before releasing the returned resources.
    pub fn claim_sm_and_add_program_for_gpio_range(program: common.Program, pin: u6, count: u6) !ClaimedProgram {
        if (!@import("../compatibility.zig").has_rp2350b and @as(u7, pin) + count > 30) return error.InvalidPin;
        const cs = common.lock_resources();
        defer common.unlock_resources(cs);
        var blocks: [3]runtime.BlockResources = undefined;
        for (&blocks, 0..) |*block, i| {
            const pio: Pio = @fromBackingInt(@as(u2, @intCast(i)));
            block.* = .{ .base = @fromBackingInt(@intCast(pio.get_gpio_base())), .used = PioImpl.used_instruction_space(pio), .claimed = PioImpl.claimed_state_machines(pio), .offset = PioImpl.program_offset_unlocked(pio, program) };
        }
        const selected = try runtime.select_gpio_program(blocks, program.used_gpio_ranges, pin, count);
        const pio: Pio = @fromBackingInt(selected.block);
        const sm: common.StateMachine = @fromBackingInt(@backingInt(selected.sm));
        const old_base = blocks[selected.block].base;
        if (old_base != selected.base) pio.get_regs().GPIOBASE.write_raw(@backingInt(selected.base));
        errdefer if (old_base != selected.base) {
            pio.get_regs().GPIOBASE.write_raw(@backingInt(old_base));
        };
        try PioImpl.add_program_unlocked(pio, program, selected.offset);
        PioImpl.claim_unlocked(pio, sm);
        return .{ .pio = pio, .sm = sm, .offset = selected.offset };
    }

    fn putget_register(self: Pio, sm: common.StateMachine, index: u2) *volatile @TypeOf(common.PIO0.RXF0_PUTGET0) {
        const regs: *volatile [16]@TypeOf(common.PIO0.RXF0_PUTGET0) = @ptrCast(&self.get_regs().RXF0_PUTGET0);
        return &regs[(runtime.putget_offset(@fromBackingInt(@backingInt(sm)), index) - 0x128) / 4];
    }
    /// System read: SM must be in PUT-only mode (50DS §11.4.8.2).
    pub fn sm_rxfifo_get(self: Pio, sm: common.StateMachine, index: u2) !u32 {
        try runtime.validate_putget(self.get_sm_regs(sm).shiftctrl.raw, false);
        return self.putget_register(sm, index).raw;
    }
    /// System write: SM must be in GET-only mode (50DS §11.4.9.2).
    pub fn sm_rxfifo_put(self: Pio, sm: common.StateMachine, index: u2, value: u32) !void {
        try runtime.validate_putget(self.get_sm_regs(sm).shiftctrl.raw, true);
        self.putget_register(sm, index).write_raw(value);
    }

    fn cross_control(self: Pio, masks: BlockMasks, action: runtime.CrossControl) void {
        const cs = common.lock_resources();
        defer common.unlock_resources(cs);
        // One CTRL write; preserve other local enables. Resource lock serializes
        // cooperating callers; callers must exclude concurrent SM_ENABLE writes.
        const ctrl = &self.get_regs().CTRL;
        ctrl.write_raw(runtime.cross_ctrl(@backingInt(self), masks, @truncate(ctrl.raw), action));
    }
    /// Synchronize dividers and enable selected SMs across all three blocks.
    /// Neighbours must have the same security attribution (50DS Table 1038).
    pub fn enable_in_sync(self: Pio, masks: BlockMasks) void {
        self.cross_control(masks, .enable_in_sync);
    }
    pub fn disable(self: Pio, masks: BlockMasks) void {
        self.cross_control(masks, .disable);
    }
    pub fn clkdiv_restart(self: Pio, masks: BlockMasks) void {
        self.cross_control(masks, .clkdiv_restart);
    }

    pub const sm_set_exec_options = PioImpl.sm_set_exec_options;

    pub fn sm_set_shift_options(self: Pio, sm: common.StateMachine, options: common.ShiftOptions(.RP2350)) void {
        runtime.validate_shift(options) catch @panic("autopush/FIFO join incompatible with RX random access (50DS §11.5.4.1)");
        const sm_regs = self.get_sm_regs(sm);
        sm_regs.shiftctrl.write(.{
            .AUTOPUSH = @intFromBool(options.autopush),
            .AUTOPULL = @intFromBool(options.autopull),

            .IN_SHIFTDIR = @backingInt(options.in_shiftdir),
            .OUT_SHIFTDIR = @backingInt(options.out_shiftdir),

            .PUSH_THRESH = options.push_threshold,
            .PULL_THRESH = options.pull_threshold,

            .FJOIN_TX = @intFromBool(options.join_tx),
            .FJOIN_RX = @intFromBool(options.join_rx),

            .FJOIN_RX_GET = @intFromBool(options.fjoin_rx_get),
            .FJOIN_RX_PUT = @intFromBool(options.fjoin_rx_put),
            .IN_COUNT = options.in_count,
        });
    }

    pub const sm_set_pin_mappings = PioImpl.sm_set_pin_mappings;
    pub const sm_set_pindir = PioImpl.sm_set_pindir;
    pub const sm_set_pin = PioImpl.sm_set_pin;
    pub const sm_get_rx_fifo = PioImpl.sm_get_rx_fifo;
    pub const sm_is_rx_fifo_empty = PioImpl.sm_is_rx_fifo_empty;
    pub const sm_blocking_read = PioImpl.sm_blocking_read;
    pub const sm_read = PioImpl.sm_read;
    pub const sm_is_tx_fifo_full = PioImpl.sm_is_tx_fifo_full;
    pub const sm_get_tx_fifo = PioImpl.sm_get_tx_fifo;
    pub const sm_write = PioImpl.sm_write;
    pub const sm_blocking_write = PioImpl.sm_blocking_write;
    pub const sm_set_enabled = PioImpl.sm_set_enabled;
    pub const sm_clear_debug = PioImpl.sm_clear_debug;

    /// changing the state of fifos will clear them
    pub fn sm_clear_fifos(self: Pio, sm: common.StateMachine) void {
        const sm_regs = self.get_sm_regs(sm);
        const xor_shiftctrl = hw.xor_alias(&sm_regs.shiftctrl);
        const mask = @TypeOf(common.PIO0.SM0_SHIFTCTRL).underlying_type{
            .FJOIN_TX = 1,
            .FJOIN_RX = 1,

            .AUTOPUSH = 0,
            .AUTOPULL = 0,
            .IN_SHIFTDIR = 0,
            .OUT_SHIFTDIR = 0,
            .PUSH_THRESH = 0,
            .PULL_THRESH = 0,

            .FJOIN_RX_GET = 0,
            .FJOIN_RX_PUT = 0,
            .IN_COUNT = 0,
        };

        xor_shiftctrl.write(mask);
        xor_shiftctrl.write(mask);
    }

    pub const sm_fifo_level = PioImpl.sm_fifo_level;
    pub const sm_restart = PioImpl.sm_restart;
    pub const sm_clkdiv_restart = PioImpl.sm_clkdiv_restart;
    pub const sm_init = PioImpl.sm_init;
    pub const sm_exec = PioImpl.sm_exec;
    pub const sm_load_and_start_program = PioImpl.sm_load_and_start_program;

    pub const sm_exec_set_x = PioImpl.sm_exec_set_x;
    pub const sm_exec_set_y = PioImpl.sm_exec_set_y;
    pub const sm_exec_set_pindir = PioImpl.sm_exec_set_pindir;
    pub const sm_exec_jmp = PioImpl.sm_exec_jmp;
};
