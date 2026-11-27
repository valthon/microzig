//! Checks the self-test harness itself: one case on the uptime, and the
//! report served over USB CDC with `uf2` support.
const microzig = @import("microzig");
const nrf = microzig.hal;
const harness = @import("harness.zig");

pub const panic = microzig.panic;
pub const init = harness.init;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    // The RTC behind hal.time starts at zero in hal.init, just before main,
    // and ticks every 30.5 us, so read it after a known wait.
    nrf.time.sleep_ms(50);
    const t = nrf.time.get_time_since_boot().to_us();
    harness.check("harness", "uptime", t >= 50_000 and t < 1_000_000, "t_us={d}", .{t});
    harness.finish("harness");
}
