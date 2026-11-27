const builtin = @import("builtin");
const microzig = @import("microzig");
const rtos = @import("../rtos.zig");

// Host lifecycle tests replace MMIO, task switching and the closed blob.
pub const host_test = builtin.is_test and @hasDecl(microzig, "radio_test");
pub threadlocal var host_current: ?*rtos.Task = null;
threadlocal var host_task: rtos.Task = .{ .context = undefined, .stack = &.{}, .priority = .lowest };

pub fn current_task() *rtos.Task {
    return if (host_test) host_current orelse &host_task else rtos.get_current_task();
}

fn in_isr() bool {
    return if (host_test) microzig.radio_test.in_isr else rtos.in_isr();
}

pub fn active() bool {
    return in_isr() or current_task().in_radio_callback;
}

pub const Scope = struct {
    task: ?*rtos.Task = null,
    previous: bool = false,

    pub inline fn enter() Scope {
        if (!@import("../radio.zig").coex_enabled or in_isr()) return .{};
        const task = current_task();
        const previous = task.in_radio_callback;
        task.in_radio_callback = true;
        return .{ .task = task, .previous = previous };
    }

    pub inline fn leave(self: Scope) void {
        if (@import("../radio.zig").coex_enabled) {
            if (self.task) |task| task.in_radio_callback = self.previous;
        }
    }
};
