//! Leaves a RAM-loaded self-test: reboots straight into the firmware in flash.
//! Copy it to a BOOTSEL drive to return a board to its own firmware without
//! writing flash.
const microzig = @import("microzig");
const selftest = @import("pio_selftest/selftest.zig");

pub const panic = selftest.panic;
pub const std_options = selftest.std_options;
pub const microzig_options = selftest.microzig_options;
comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    selftest.reboot_normal();
}
