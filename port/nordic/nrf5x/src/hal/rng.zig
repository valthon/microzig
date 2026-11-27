//! Blocking hardware RNG for nRF52840. Serialize access to the peripheral.
const microzig = @import("microzig");
const time = microzig.hal.time;
const rng = microzig.chip.peripherals.RNG;

pub const BiasCorrection = enum { enabled, disabled };

/// Fill bytes by the deadline. On timeout, only the completed prefix is written.
/// With VALRDY_STOP, VALUE stays valid until the next START (PS v1.11 §6.21).
pub fn fill(buffer: []u8, correction: BiasCorrection, deadline: microzig.drivers.time.Absolute) error{Timeout}!void {
    if (buffer.len == 0) return;
    rng.CONFIG.write(.{ .DERCEN = if (correction == .enabled) .Enabled else .Disabled });
    rng.SHORTS.write(.{ .VALRDY_STOP = .Enabled });
    defer rng.SHORTS.write(.{ .VALRDY_STOP = .Disabled });
    errdefer rng.TASKS_STOP.write_raw(1);

    for (buffer) |*byte| {
        rng.EVENTS_VALRDY.write_raw(0);
        if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
        rng.TASKS_START.write_raw(1);
        while (rng.EVENTS_VALRDY.raw == 0) {
            if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
        }
        if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
        byte.* = rng.VALUE.read().VALUE;
    }
}
