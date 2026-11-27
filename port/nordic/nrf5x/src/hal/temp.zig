//! Blocking die-temperature measurements for nRF52840. Serialize TEMP access.
const microzig = @import("microzig");
const temp = microzig.chip.peripherals.TEMP;
const factory = &microzig.chip.peripherals.FICR.TEMP;
const time = microzig.hal.time;

/// Load the factory linearization coefficients while TEMP is idle after reset.
/// This implements nRF52840 anomaly 66 (including revision 3).
pub fn init() void {
    temp.A0.write(.{ .A0 = factory.A0.read().A });
    temp.A1.write(.{ .A1 = factory.A1.read().A });
    temp.A2.write(.{ .A2 = factory.A2.read().A });
    temp.A3.write(.{ .A3 = factory.A3.read().A });
    temp.A4.write(.{ .A4 = factory.A4.read().A });
    temp.A5.write(.{ .A5 = factory.A5.read().A });
    temp.B0.write(.{ .B0 = factory.B0.read().B });
    temp.B1.write(.{ .B1 = factory.B1.read().B });
    temp.B2.write(.{ .B2 = factory.B2.read().B });
    temp.B3.write(.{ .B3 = factory.B3.read().B });
    temp.B4.write(.{ .B4 = factory.B4.read().B });
    temp.B5.write(.{ .B5 = factory.B5.read().B });
    temp.T0.write(.{ .T0 = factory.T0.read().T });
    temp.T1.write(.{ .T1 = factory.T1.read().T });
    temp.T2.write(.{ .T2 = factory.T2.read().T });
    temp.T3.write(.{ .T3 = factory.T3.read().T });
    temp.T4.write(.{ .T4 = factory.T4.read().T });
}

/// Return signed quarter-degrees Celsius. Run HFCLK from the crystal for the
/// specified measurement accuracy (nRF52840 PS v1.11 §6.28).
pub fn read(deadline: microzig.drivers.time.Absolute) error{Timeout}!i32 {
    temp.EVENTS_DATARDY.write_raw(0);
    temp.TASKS_START.write_raw(1);
    defer temp.TASKS_STOP.write_raw(1);
    while (temp.EVENTS_DATARDY.raw == 0) {
        if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
    }
    return @bitCast(temp.TEMP.read().TEMP);
}
