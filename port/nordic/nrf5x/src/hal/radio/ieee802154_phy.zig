const std = @import("std");

// PS v1.11 §6.20.12, Receive sequence: END follows the last octet becoming
// available in RAM. Nordic's nrf_802154_procedures_duration.h and
// nrf_802154_trx_transmit_ack specify 23 µs for the nRF52 RX END pipeline.
pub const rx_end_delay_us = 23;

pub const symbol_us = 16;
const turnaround_us = 12 * symbol_us; // IEEE 802.15.4-2006 aTurnaroundTime.
const tx_ramp_us = 40; // PS v1.11 RADIO, Radio timing, fast ramp-up.
pub const ack_txen_us = turnaround_us - rx_end_delay_us - tx_ramp_us;

// PS v1.11 §6.20, IEEE 802.15.4 energy detection constants.
pub const ed_offset_dbm = -92;
const ed_hardware_scale = 4;

/// TIMER3 runs modulo 2^32. Scheduled hardware deadlines are less than
/// half that range ahead of the current tick.
pub fn tick_reached(now: u32, deadline: u32) bool {
    return @as(i32, @bitCast(now -% deadline)) >= 0;
}

/// PS v1.11 RADIO, IEEE 802.15.4 packet layout and 250 kbit/s mode.
/// The PHR is one octet, followed by the PSDU (including FCS).
pub fn sfd_to_frame_end_us(psdu_len: u8) u32 {
    return (@as(u32, psdu_len) + 1) * 2 * symbol_us;
}

/// The deadline applies to the final on-air bit, after correcting the
/// TIMER3 capture for the RX END pipeline. Capture is relative to window start.
pub fn completed_before(captured_us: u32, on_air_deadline_us: u32) bool {
    return captured_us >= rx_end_delay_us and captured_us - rx_end_delay_us < on_air_deadline_us;
}

pub fn valid_csma_backoffs(csma_ca: bool, backoffs: u8) bool {
    // IEEE 802.15.4-2006 MAC PIB, macMaxCSMABackoffs.
    return !csma_ca or backoffs <= 5;
}

test "maximum CSMA backoffs applies only when CSMA is enabled" {
    try std.testing.expect(valid_csma_backoffs(false, 255));
    try std.testing.expect(valid_csma_backoffs(true, 5));
    try std.testing.expect(!valid_csma_backoffs(true, 6));
}

pub fn ed_level(dbm: i8) u8 {
    // IEEE 802.15.4-2006 §6.9.7 and §6.8.3.4 set the ED floor 10 dB
    // above the PHY's -85 dBm sensitivity requirement. Nordic's
    // nrf_802154_rssi_ed_sample_convert uses the top of the linear
    // hardware range as full scale, giving a 46 dB span on nRF52840.
    const floor_dbm = -85 + 10;
    const ceiling_dbm = ed_offset_dbm + @divTrunc(255, ed_hardware_scale);
    const span_db = ceiling_dbm - floor_dbm;
    const above_floor = std.math.clamp(@as(i16, dbm) - floor_dbm, 0, span_db);
    return @intCast(@divTrunc(above_floor * 255, span_db));
}

test "ACK deadline admits a frame based on corrected on-air completion" {
    try std.testing.expect(completed_before(873, 864)); // Final on-air bit at 850 µs.
    try std.testing.expect(completed_before(886, 864));
    try std.testing.expect(!completed_before(887, 864));
    try std.testing.expect(!completed_before(888, 864));
    try std.testing.expect(!completed_before(22, 864));
}

test "TIMER deadlines and elapsed captures cross rollover" {
    const start: u32 = std.math.maxInt(u32) - 100;
    const deadline = start +% (864 + rx_end_delay_us);
    try std.testing.expect(!tick_reached(start, deadline));
    try std.testing.expect(!tick_reached(deadline -% 1, deadline));
    try std.testing.expect(tick_reached(deadline, deadline));
    try std.testing.expect(completed_before(deadline -% 1 -% start, 864));
    try std.testing.expectEqual(@as(u32, 192), sfd_to_frame_end_us(5));
}

test "ED scale floors weak signals and saturates at the top of the linear range" {
    try std.testing.expectEqual(@as(u8, 0), ed_level(-85));
    try std.testing.expectEqual(@as(u8, 0), ed_level(-75));
    try std.testing.expectEqual(@as(u8, 127), ed_level(-52));
    try std.testing.expectEqual(@as(u8, 255), ed_level(-29));
    try std.testing.expectEqual(@as(u8, 255), ed_level(0));
}
