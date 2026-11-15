//! The PIO self-test with USB never started: proves that a board whose USB does
//! not enumerate reboots into BOOTSEL by itself within 10 s.
const microzig = @import("microzig");
const selftest = @import("pio_selftest/selftest.zig");

pub const panic = selftest.panic;
pub const std_options = selftest.std_options;
pub const microzig_options = selftest.microzig_options;
comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    selftest.run(false);
}
