//! One count per HP wake. No HP ROM or clock initialization on LP.
const microzig = @import("microzig");
const lp = microzig.hal.lp_core;
pub const panic = microzig.panic;
comptime {
    microzig.export_startup();
}
pub fn main() noreturn {
    lp.acknowledge_hp_wake();
    lp.Mailbox.write(.result, @intFromBool(lp.etm_wakeup_pending()));
    lp.acknowledge_etm_wake();
    const next = lp.Mailbox.read(.counter) +% 1;
    microzig.hal.lp_io.apply(0, .{ .output = true, .initial_level = @truncate(next) });
    // Let the input synchronizer observe the newly driven pad.
    for (0..32) |_| asm volatile ("nop");
    lp.Mailbox.write(.pad_level, microzig.hal.lp_io.read(0));
    lp.Mailbox.write(.counter, next);
    lp.Mailbox.write(.sequence, next);
    lp.halt();
}
