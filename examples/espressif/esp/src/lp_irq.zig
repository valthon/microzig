//! TRM v1.2 §§3.3.2, 3.11, 12.10.1: all LP sources share entry 30.
const microzig = @import("microzig");
const lp = microzig.hal.lp_core;
const pmu = microzig.chip.peripherals.PMU;
pub const panic = microzig.panic;
pub const microzig_options: microzig.Options = .{ .interrupts = .{ .handler = handle } };
comptime {
    microzig.export_startup();
}
fn handle(sources: u8) callconv(.c) void {
    // PMU is bit 5 of LPPERI_INTERRUPT_SOURCE; no other sources are enabled.
    const hit = sources & (1 << 5) != 0 and pmu.LP_INT_RAW.read().HP_SW_TRIGGER_INT_RAW != 0;
    lp.acknowledge_hp_wake();
    pmu.LP_INT_ENA.modify(.{ .HP_SW_TRIGGER_INT_ENA = 0 });
    lp.Mailbox.write(.result, @intFromBool(hit));
    lp.Mailbox.write(.counter, lp.Mailbox.read(.counter) +% 1);
    lp.Mailbox.write(.sequence, 2);
}
pub fn main() noreturn {
    lp.acknowledge_hp_wake();
    pmu.LP_INT_ENA.modify(.{ .HP_SW_TRIGGER_INT_ENA = 1 });
    microzig.cpu.interrupt.enable(.peripheral);
    microzig.cpu.interrupt.enable_interrupts();
    lp.Mailbox.write(.sequence, 1);
    // Keep LP awake so HP's second trigger exercises trap entry and mret.
    // Finite bound leaves HP able to report FAIL even if no interrupt arrives.
    var left: u32 = 100_000_000;
    while (lp.Mailbox.read(.command) == 0 and left != 0) : (left -= 1) {}
    microzig.cpu.interrupt.disable_interrupts();
    pmu.LP_INT_ENA.modify(.{ .HP_SW_TRIGGER_INT_ENA = 0 });
    lp.Mailbox.write(.sequence, 3); // proves execution resumed after mret
    lp.halt();
}
