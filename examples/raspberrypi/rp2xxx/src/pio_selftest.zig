//! On-target PIO self-test over USB CDC; see pio_selftest/selftest.zig.
//! Run it with port/raspberrypi/rp2xxx/tools/pio-hwtest/run.sh.
const microzig = @import("microzig");
const selftest = @import("pio_selftest/selftest.zig");

pub const panic = selftest.panic;
pub const std_options = selftest.std_options;
pub const microzig_options = selftest.microzig_options;
comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    selftest.run(true);
}
