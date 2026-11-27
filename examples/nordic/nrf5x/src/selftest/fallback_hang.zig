//! Checks the bootloader fallback: arms it and then hangs, so the board
//! should come back in its UF2 bootloader after the fallback timeout.
const microzig = @import("microzig");
const harness = @import("harness.zig");

pub const panic = microzig.panic;
pub const init = harness.init;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    microzig.hang();
}
