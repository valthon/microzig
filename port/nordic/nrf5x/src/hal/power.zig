//! Reset reason access for nRF52840.
const microzig = @import("microzig");
const power = microzig.chip.peripherals.POWER;

pub const ResetReason = @TypeOf(power.RESETREAS.read());

/// Read the cumulative reset flags (nRF52840 PS v1.11 §§5.3.6–5.3.7).
pub fn reset_reason() ResetReason {
    return power.RESETREAS.read();
}

/// Clear the selected flags with a write-one-to-clear operation.
pub fn clear_reset_reason(reasons: ResetReason) void {
    power.RESETREAS.write(reasons);
}
