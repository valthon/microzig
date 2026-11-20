//! No wiring: drive LP GPIO0 high after HP's sleep-request milestone.
//! HP configures the LP pad/mux. This image owns command consumption only.
const microzig = @import("microzig");
const hal = microzig.hal;
pub const panic = microzig.panic;
comptime {
    microzig.export_startup();
}
pub fn main() noreturn {
    hal.lp_core.acknowledge_hp_wake();
    hal.lp_timer.arm_after(16384) catch hal.lp_core.halt();
    hal.lp_core.Mailbox.write(.sequence, 1);
    // Bounded even if HP entry fails before publishing its request.
    for (0..10_000_000) |_| {
        if (hal.lp_core.Mailbox.read(.command) == 1) break;
    } else hal.lp_core.halt();
    // Target 1 was armed before publishing readiness. No LP software snapshot
    // runs while HP owns the shared snapshot trigger during sleep entry.
    for (0..10_000_000) |_| {
        if (hal.lp_timer.pending()) break;
    } else hal.lp_core.halt();
    hal.lp_timer.disable();
    hal.lp_core.Mailbox.write(.result, 1);
    hal.lp_io.put(0, 1);
    hal.lp_core.halt();
}
