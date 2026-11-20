//! ESP32-C6 TRM v1.2 §§3.2, 3.3: LP has a single interrupt entry (30),
//! not the HP interrupt matrix. No nested interrupts. Clear sources in handler.
const microzig = @import("microzig");

pub const InterruptOptions = struct {
    handler: ?*const fn (sources: u8) callconv(.c) void = null,
    exception: ?*const fn (cause: u32, pc: u32) callconv(.c) noreturn = null,
};

pub const interrupt = struct {
    pub fn globally_enabled() bool {
        return asm volatile ("csrr %[v], mstatus"
            : [v] "=r" (-> u32),
        ) & 8 != 0;
    }
    pub fn enable_interrupts() void {
        asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    }
    pub fn disable_interrupts() void {
        asm volatile ("csrci mstatus, 8" ::: .{ .memory = true });
    }
    pub fn enable(_: enum { peripheral }) void {
        asm volatile ("csrs mie, %[v]"
            :
            : [v] "r" (@as(u32, 1 << 30)),
            : .{ .memory = true });
    }
    pub fn disable(_: enum { peripheral }) void {
        asm volatile ("csrc mie, %[v]"
            :
            : [v] "r" (@as(u32, 1 << 30)),
            : .{ .memory = true });
    }
};

pub fn export_startup_logic() void {
    @export(&start, .{ .name = "_start" });
    @export(&start_c, .{ .name = "lp_start_c" });
    @export(&trap, .{ .name = "lp_trap" });
    @export(&dispatch, .{ .name = "lp_dispatch" });
}

comptime {
    asm (
        \\.section .lp_vectors,"ax"
        \\.balign 256
        \\.option push
        \\.option norvc
        \\.rept 32
        \\j lp_trap
        \\.endr
        \\.option pop
    );
}

fn start() linksection(".lp_start") callconv(.naked) noreturn {
    asm volatile (
        \\csrci mstatus, 8
        \\csrw mie, zero
        \\.option push
        \\.option norelax
        \\la gp, __global_pointer$
        \\.option pop
        \\la sp, __lp_stack_top
        \\li t0, 0x50000000
        \\csrw mtvec, t0
        \\fence.i
        \\tail lp_start_c
    );
}

fn start_c() callconv(.c) noreturn {
    // Each wake resets the CPU. Mailbox lies outside .bss and survives.
    microzig.utilities.initialize_system_memories(.bss_only);
    const entry = @extern(*const fn () callconv(.c) noreturn, .{ .name = "microzig_main" });
    entry();
}

// Preserve every caller-saved register before calling the C ABI dispatcher.
// Callee-saved registers are preserved by dispatch; interrupts stay masked.
fn trap() callconv(.naked) noreturn {
    asm volatile (
        \\addi sp, sp, -64
        \\sw ra, 0(sp)
        \\sw t0, 4(sp)
        \\sw t1, 8(sp)
        \\sw t2, 12(sp)
        \\sw a0, 16(sp)
        \\sw a1, 20(sp)
        \\sw a2, 24(sp)
        \\sw a3, 28(sp)
        \\sw a4, 32(sp)
        \\sw a5, 36(sp)
        \\sw a6, 40(sp)
        \\sw a7, 44(sp)
        \\sw t3, 48(sp)
        \\sw t4, 52(sp)
        \\sw t5, 56(sp)
        \\sw t6, 60(sp)
        \\call lp_dispatch
        \\lw ra, 0(sp)
        \\lw t0, 4(sp)
        \\lw t1, 8(sp)
        \\lw t2, 12(sp)
        \\lw a0, 16(sp)
        \\lw a1, 20(sp)
        \\lw a2, 24(sp)
        \\lw a3, 28(sp)
        \\lw a4, 32(sp)
        \\lw a5, 36(sp)
        \\lw a6, 40(sp)
        \\lw a7, 44(sp)
        \\lw t3, 48(sp)
        \\lw t4, 52(sp)
        \\lw t5, 56(sp)
        \\lw t6, 60(sp)
        \\addi sp, sp, 64
        \\mret
    );
}

fn dispatch() callconv(.c) void {
    const cause = asm volatile ("csrr %[v], mcause"
        : [v] "=r" (-> u32),
    );
    if (cause == 0x8000001e) {
        if (microzig.options.interrupts.handler) |handler| {
            handler(microzig.chip.peripherals.LP_PERI.INTERRUPT_SOURCE.read().LP_INTERRUPT_SOURCE);
            return;
        }
    }
    const pc = asm volatile ("csrr %[v], mepc"
        : [v] "=r" (-> u32),
    );
    if (microzig.options.interrupts.exception) |handler| handler(cause, pc);
    // Fail closed for unhandled traps; no HP ROM/logger is available.
    interrupt.disable_interrupts();
    while (true) asm volatile ("wfi");
}
