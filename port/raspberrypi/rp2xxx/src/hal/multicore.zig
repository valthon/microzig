const std = @import("std");

const microzig = @import("microzig");
const interrupt = microzig.interrupt;
const peripherals = microzig.chip.peripherals;

const CriticalSection = interrupt.CriticalSection;
const SIO = peripherals.SIO;
const PSM = peripherals.PSM;

pub const fifo = struct {
    /// Check if the FIFO has valid data for reading.
    pub fn is_read_ready() bool {
        return SIO.FIFO_ST.read().VLD == 1;
    }

    /// Read from the FIFO
    /// Will return null if it is empty.
    pub fn read() ?u32 {
        if (!is_read_ready())
            return null;

        return SIO.FIFO_RD.read().FIFO_RD;
    }

    /// Read from the FIFO, waiting for data if there is none.
    pub fn read_blocking() u32 {
        while (true) {
            if (read()) |value| return value;
            microzig.cpu.wfe();
        }
    }

    /// Read from the FIFO, and throw everything away.
    pub fn drain() void {
        while (read()) |_| {}
    }

    /// Check if the FIFO is ready to receive data.
    pub fn is_write_ready() bool {
        return SIO.FIFO_ST.read().RDY == 1;
    }

    /// Write to the FIFO
    /// You must check if there is space by calling is_write_ready
    pub fn write(value: u32) void {
        SIO.FIFO_WR.write(.{ .FIFO_WR = value });
        microzig.cpu.sev();
    }

    /// Write to the FIFO, waiting for room if it is full.
    pub fn write_blocking(value: u32) void {
        while (!is_write_ready())
            std.mem.doNotOptimizeAway(value);

        write(value);
    }
};

var core1_stack: [128]u32 = undefined;

/// Runs `entrypoint` on the second core.
pub fn launch_core1(entrypoint: *const fn () void) void {
    launch_core1_with_stack(entrypoint, &core1_stack);
}

extern const _external_interrupt_table: usize; // For riscv only

pub fn launch_core1_with_stack(entrypoint: *const fn () void, stack: []u32) void {
    // TODO: disable SIO interrupts

    const wrapper = if (microzig.hal.compatibility.arch != .riscv) &struct {
        // Account for the four arguments that are passed to the wrapper in registers so
        // we can get the three we put on the stack.
        fn _wrapper(_: u32, _: u32, _: u32, _: u32, entry: u32, stack_base: [*]u32, stack_top: usize) callconv(.c) void {
            // Reserve any MPU guard inside the caller's buffer. A very small
            // buffer may not fit a guard plus the active wrapper frames.
            if (@hasDecl(microzig.cpu, "protect_main_stack")) {
                _ = microzig.cpu.protect_main_stack(@intFromPtr(stack_base), stack_top);
            }
            if (microzig.hal.compatibility.chip == .RP2350) {
                if (microzig.options.cpu.enable_fpu) {
                    microzig.cpu.enable_fpu();
                }

                if (microzig.options.hal.use_dcp) {
                    microzig.hal.enable_dcp();
                }
            }
            @as(*const fn () void, @ptrFromInt(entry))();
        }
    }._wrapper else &struct {
        // Account for the eight arguments that are passed to the wrapper in registers so
        // we can get the two we put on the stack,
        fn _wrapper(_: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, entry: u32, stack_base: [*]u32) callconv(.c) void {
            // TODO: protect stack using MPU
            _ = stack_base;
            @as(*const fn () void, @ptrFromInt(entry))();
        }
    }._wrapper;

    // reset the second core
    PSM.FRCE_OFF.modify(.{ .PROC1 = 1 });
    while (PSM.FRCE_OFF.read().PROC1 != 1) microzig.cpu.nop();
    PSM.FRCE_OFF.modify(.{ .PROC1 = 0 });

    // Keep SP eight-byte aligned when adding the ARM wrapper's third argument.
    const argument_words: usize = if (microzig.hal.compatibility.arch == .riscv) 2 else 4;
    stack[stack.len - argument_words] = @intFromPtr(entrypoint);
    stack[stack.len - argument_words + 1] = @intFromPtr(stack.ptr);
    if (microzig.hal.compatibility.arch != .riscv)
        stack[stack.len - argument_words + 2] = @intFromPtr(stack.ptr) + stack.len * @sizeOf(u32);

    // calculate top of the stack
    const stack_ptr: u32 =
        @intFromPtr(stack.ptr) +
        (stack.len - argument_words) * @sizeOf(u32); // account for wrapper arguments

    // after resetting core1 is waiting for this specific sequence

    const cmds: [6]u32 = .{
        0,
        0,
        1,
        if (microzig.hal.compatibility.arch == .riscv)
            microzig.cpu.csr.mtvec.read_raw()
        else
            microzig.cpu.peripherals.scb.VTOR,
        stack_ptr,
        @intFromPtr(wrapper),
    };

    var seq: usize = 0;
    while (seq < cmds.len) {
        const cmd = cmds[seq];
        if (cmd == 0) {
            // always drain the fifo before sending zero
            fifo.drain();
            microzig.cpu.sev();
        }

        fifo.write_blocking(cmd);
        // the second core should respond with the same value, if it doesn't lets start over
        seq = if (cmd == fifo.read_blocking()) seq + 1 else 0;
    }
}

/// Manage the state of hardware spinlocks.
/// Usage example:
///     var lock = Spinlock.init(5);
///     . . .
///     {
///         lock.lock();
///         defer lock.unlock();
///         . . .
///     }
///
pub const Spinlock = struct {
    // Reserved spinlocks
    pub const pio = init(29);
    pub const atomics = init(30);
    pub const mutexes = init(31);

    lock_reg: *volatile u32,

    const spinlock_base: usize = @intFromPtr(&SIO.SPINLOCK0.raw);

    /// Returns an initialized Spinlock struct.
    /// Parameters:
    ///   lock_num - the index of the hardware spinlock to use
    ///
    /// Note: Spinlocks 26 through 31 are reserved for use by microzig.
    pub fn init(lock_num: u5) Spinlock {
        return .{ .lock_reg = @ptrFromInt(spinlock_base + 4 * @as(usize, @intCast(lock_num))) };
    }

    /// Returns the index of the spinlock.
    pub fn number(self: Spinlock) u5 {
        return @intCast((@intFromPtr(self.lock_reg) - spinlock_base) / 4);
    }

    /// Try to lock the spinlock. If the spinlock is already locked, returns false
    /// otherwise locks the spinlock and returns true.
    pub inline fn try_lock(self: Spinlock) bool {
        return self.lock_reg.* != 0;
    }

    /// Lock the spinlock. If the spinlock is already locked, busy wait until
    pub fn lock(self: Spinlock) void {
        while (!self.try_lock()) {}
    }

    /// Returns true if the spinlock is locked
    pub fn is_locked(self: Spinlock) bool {
        const bit = @as(u32, 1) << self.number();
        return (Spinlock.lock_status() & bit) != 0;
    }

    /// Unlock the spinlock
    pub fn unlock(self: Spinlock) void {
        self.lock_reg.* = 0;
    }

    /// Returns bitmap of currently locked spinlocks
    pub fn lock_status() u32 {
        return SIO.SPINLOCK_ST.read().SPINLOCK_ST;
    }

    /// Disable interrupts and lock the spinlock.
    pub fn lock_irq(self: Spinlock) CriticalSection {
        const critical_section = interrupt.enter_critical_section();
        self.lock();
        return critical_section;
    }

    /// Unlock the spinlock and restore interrupts.
    pub fn unlock_irq(self: Spinlock, critical_section: CriticalSection) void {
        self.unlock();
        critical_section.leave();
    }
};
