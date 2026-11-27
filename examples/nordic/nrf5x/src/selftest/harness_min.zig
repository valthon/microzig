//! The harness with no cases: only the DONE line served over USB CDC.
const microzig = @import("microzig");
const harness = @import("harness.zig");

pub const panic = microzig.panic;
pub const init = harness.init;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    harness.finish("harness_min");
}
