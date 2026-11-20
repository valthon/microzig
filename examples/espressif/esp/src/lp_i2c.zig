const microzig = @import("microzig");
const lp = microzig.hal.lp_core;
pub const panic = microzig.panic;
comptime {
    microzig.export_startup();
}
pub fn main() noreturn {
    lp.acknowledge_hp_wake();
    const result = @import("lp_i2c_check.zig").run();
    lp.Mailbox.write(.counter, result.nacks);
    lp.Mailbox.write(.detail, result.acks);
    lp.Mailbox.write(.pad_level, result.bits);
    lp.Mailbox.write(.result, result.faults);
    lp.Mailbox.write(.sequence, 1);
    lp.halt();
}
