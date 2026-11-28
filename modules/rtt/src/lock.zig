const std = @import("std");
const builtin = @import("builtin");

/// A generic struct that provides exclusive access to the RTT control block
pub fn GenericLock(
    comptime Context: type,
    comptime lock_fn: fn (context: Context) void,
    comptime unlock_fn: fn (context: Context) void,
) type {
    return struct {
        const Self = @This();
        context: Context,

        pub inline fn lock(self: Self) void {
            return lock_fn(self.context);
        }

        fn type_erased_lock(context: *anyopaque) void {
            const ptr: *const Context = @ptrCast(@alignCast(context));
            return lock_fn(ptr.*);
        }

        pub inline fn unlock(self: Self) void {
            return unlock_fn(self.context);
        }

        fn type_erased_unlock(context: *anyopaque) void {
            const ptr: *const Context = @ptrCast(@alignCast(context));
            return unlock_fn(ptr.*);
        }

        pub inline fn any(self: *Self) AnyLock {
            return .{
                .context = @ptrCast(&self.context),
                .lock_fn = type_erased_lock,
                .unlock_fn = type_erased_unlock,
            };
        }
    };
}

/// A type erased version of GenericLock that serves as a concrete type to pass into Config
pub const AnyLock = struct {
    context: *anyopaque,
    lock_fn: fn (context: *anyopaque) void,
    unlock_fn: fn (context: *anyopaque) void,
};

const EnterStep = enum { masked, depth_loaded, depth_claimed, mask_saved };

/// The mask operation must exclude all interrupt handlers that use this lock.
fn NestedLock(comptime Mask: type) type {
    const Context = struct {
        depth: usize = 0,
        saved: usize = 0,
    };

    return struct {
        var context: Context = .{};
        var generic_lock: GenericLock(*Context, enter, leave) = .{ .context = &context };

        inline fn after_enter_step(step: EnterStep) void {
            if (@hasDecl(Mask, "after_enter_step")) Mask.after_enter_step(step);
        }

        fn enter(ctx: *Context) void {
            const saved = Mask.disable();
            after_enter_step(.masked);
            const state: *volatile Context = ctx;
            const depth = state.depth;
            after_enter_step(.depth_loaded);
            // A returning exception before the claim can restore only the
            // already-masked state. After the claim it sees a nested entry
            // and leaves the outer saved mask alone, even before it is stored.
            state.depth = depth + 1;
            after_enter_step(.depth_claimed);
            if (depth == 0) state.saved = saved;
            after_enter_step(.mask_saved);
        }

        fn leave(ctx: *Context) void {
            const state: *volatile Context = ctx;
            // Cache the mask before releasing the claim. A returning exception
            // after the release can use the shared save slot for its own entry.
            const saved = state.saved;
            const depth = state.depth - 1;
            state.depth = depth;
            if (depth == 0) Mask.restore(saved);
        }

        fn get() AnyLock {
            return generic_lock.any();
        }
    };
}

test "nested lock during outer entry" {
    const Mask = struct {
        var enabled: bool = true;
        var inject_at: ?EnterStep = null;

        fn disable() usize {
            const saved = enabled;
            enabled = false;
            return @intFromBool(saved);
        }

        fn restore(saved: usize) void {
            enabled = saved != 0;
        }

        pub fn after_enter_step(step: EnterStep) void {
            if (inject_at != step) return;
            inject_at = null;
            const access = NestedLock(@This()).get();
            access.lock_fn(access.context);
            access.unlock_fn(access.context);
            std.debug.assert(!enabled);
        }
    };
    const access = NestedLock(Mask).get();

    for ([_]bool{ true, false }) |initial_state| {
        for (std.enums.values(EnterStep)) |step| {
            Mask.enabled = initial_state;
            Mask.inject_at = step;
            access.lock_fn(access.context);
            try std.testing.expect(!Mask.enabled);
            try std.testing.expectEqual(null, Mask.inject_at);
            access.unlock_fn(access.context);
            try std.testing.expectEqual(initial_state, Mask.enabled);
        }
    }
}

/// Single-core default locking. The BASEPRI path requires RTT callers to run
/// at priorities numerically at or above MAX_ISR_PRIORITY.
pub const default = struct {
    const Primask = struct {
        fn disable() usize {
            return asm volatile (
                \\mrs %[saved], primask
                \\cpsid i
                : [saved] "=r" (-> usize),
                :
                : .{ .memory = true });
        }

        fn restore(saved: usize) void {
            asm volatile ("msr primask, %[saved]"
                :
                : [saved] "r" (saved),
                : .{ .memory = true });
        }
    };

    const Basepri = struct {
        const MAX_ISR_PRIORITY: usize = 0x20;

        fn disable() usize {
            return asm volatile (
                \\mrs %[saved], basepri
                \\msr basepri_max, %[threshold]
                : [saved] "=&r" (-> usize),
                : [threshold] "r" (MAX_ISR_PRIORITY),
                : .{ .memory = true });
        }

        fn restore(saved: usize) void {
            asm volatile ("msr basepri, %[saved]"
                :
                : [saved] "r" (saved),
                : .{ .memory = true });
        }
    };

    const RiscV = struct {
        // RISC-V Privileged Architecture v20211203, section 3.1.6.1.
        const MSTATUS_MIE: usize = 1 << 3;

        fn disable() usize {
            return asm volatile ("csrrci %[saved], mstatus, 8"
                : [saved] "=r" (-> usize),
                :
                : .{ .memory = true });
        }

        fn restore(saved: usize) void {
            asm volatile ("csrs mstatus, %[mask]"
                :
                : [mask] "r" (saved & MSTATUS_MIE),
                : .{ .memory = true });
        }
    };

    const Unsupported = struct {
        fn fail(_: *anyopaque) void {
            @compileError(std.fmt.comptimePrint("Unsupported architecture for built in lock support: {any}, please provide custom locking support via Config.exclusive_access field", .{builtin.target.cpu.arch}));
        }
    };

    pub fn get() AnyLock {
        const cpu = builtin.target.cpu;
        switch (cpu.arch) {
            .arm, .armeb, .thumb, .thumbeb => {
                if (std.Target.arm.featureSetHasAny(cpu.features, .{ .v7m, .v7em, .v8m_main }))
                    return NestedLock(Basepri).get();
                if (std.Target.arm.featureSetHasAny(cpu.features, .{ .v6m, .v8m }))
                    return NestedLock(Primask).get();
            },
            .riscv32, .riscv64 => {
                if (std.Target.riscv.featureSetHas(cpu.features, .zicsr))
                    return NestedLock(RiscV).get();
            },
            else => {},
        }

        return .{ .context = undefined, .lock_fn = Unsupported.fail, .unlock_fn = Unsupported.fail };
    }
};

/// Empty lock implementation that allows RTT to be used without lock protection
pub const empty = struct {
    const Context = @TypeOf({});
    fn lock(_: Context) void {}
    fn unlock(_: Context) void {}
    var generic_lock: GenericLock(Context, lock, unlock) = .{ .context = {} };

    pub fn get() AnyLock {
        return generic_lock.any();
    }
};

test "nested lock" {
    const Mask = struct {
        var enabled: bool = true;
        var restores: usize = 0;

        fn disable() usize {
            const saved = enabled;
            enabled = false;
            return @intFromBool(saved);
        }

        fn restore(saved: usize) void {
            restores += 1;
            enabled = saved != 0;
        }
    };
    const access = NestedLock(Mask).get();

    for ([_]bool{ true, false }) |initial_state| {
        Mask.enabled = initial_state;
        Mask.restores = 0;
        access.lock_fn(access.context);
        try std.testing.expect(!Mask.enabled);
        access.lock_fn(access.context);
        access.unlock_fn(access.context);
        try std.testing.expect(!Mask.enabled);
        try std.testing.expectEqual(0, Mask.restores);
        access.unlock_fn(access.context);
        try std.testing.expectEqual(initial_state, Mask.enabled);
        try std.testing.expectEqual(1, Mask.restores);
    }
}
