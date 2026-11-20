//! Rearm RTC target 1 on every reset/wake; counter survives in the mailbox.
const microzig = @import("microzig");
const lp = microzig.hal.lp_core;
const timer = microzig.hal.lp_timer;
pub const panic = microzig.panic;
comptime {
    microzig.export_startup();
}
pub fn main() noreturn {
    lp.acknowledge_hp_wake();
    const timed = timer.pending();
    timer.disable();
    const next = lp.Mailbox.read(.counter) +% @intFromBool(timed);
    lp.Mailbox.write(.counter, next);
    // Fixed ticks intentionally avoid claiming an uncalibrated RC period.
    timer.arm_after(16384) catch {
        lp.Mailbox.write(.result, 1);
        lp.halt();
    };
    lp.Mailbox.write(.sequence, lp.Mailbox.read(.sequence) +% 1);
    lp.halt();
}
