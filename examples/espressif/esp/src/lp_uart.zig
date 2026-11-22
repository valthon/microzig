//! LP half of the external Pico UART echo; HP owns the pads after completion.
const microzig = @import("microzig");
const lp = microzig.hal.lp_core;
pub const panic = microzig.panic;
comptime {
    microzig.export_startup();
}
pub fn main() noreturn {
    lp.acknowledge_hp_wake();
    lp.Mailbox.write(.result, @bitCast(@import("lp_uart_check.zig").run()));
    lp.Mailbox.write(.sequence, 1);
    lp.halt();
}
