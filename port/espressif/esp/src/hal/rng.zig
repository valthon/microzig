const std = @import("std");
const microzig = @import("microzig");
const RNG = microzig.chip.peripherals.RNG;
const RTC_CNTL = microzig.chip.peripherals.RTC_CNTL;
const time = @import("time.zig");

/// Reads a random word with RC_FAST enabled as an entropy source, even without radio or ADC use.
/// CK8M_FORCE_PU keeps RC_FAST on through Light-sleep and Deep-sleep
/// (ESP32-C3 TRM v1.4 section 9.3, xpd_rc_oscilator). Per section 24.4, an ADC source is
/// recommended as well for maximum entropy; RC_FAST alone does not guarantee that.
/// Requires HAL initialization and its monotonic system timer to remain running.
/// Reads are serialized against interrupts and limited to at most 1 MHz (section 24.3).
pub fn random_u32() u32 {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();

    const clock = RTC_CNTL.CLK_CONF.read();
    const enabling = clock.ENB_CK8M != 0 or clock.CK8M_FORCE_PD != 0 or clock.CK8M_FORCE_PU == 0;

    // TRM sections 24.4 and 9.8, RTC_CNTL_CLK_CONF_REG. The SVD uses CK8M
    // names for FOSC; DIG_CLK8M_EN is the TRM's DIG_FOSC_EN (bit 10).
    RTC_CNTL.CLK_CONF.modify(.{
        .ENB_CK8M = 0,
        .CK8M_FORCE_PD = 0,
        .CK8M_FORCE_PU = 1,
        .DIG_CLK8M_EN = 1,
    });

    // C3 TRM section 24.4 recommends an ADC source for maximum entropy; it does not
    // require an ADC when RC_FAST is enabled. Section 24.3 calls 1 MHz advisable.
    // Neither specifies a direct-enable settling interval. FOSC_WAIT (9.8,
    // TIMER1) configures the PMU's wait in RTC slow cycles, not a fixed delay
    // for this software sequence. Allow 50 us when first forcing RC_FAST on;
    // this is a software startup allowance, not a TRM-specified minimum.
    if (enabling)
        time.sleep_us(50);

    // sleep_us truncates the initial timestamp to microseconds. Waiting for two
    // timestamp increments guarantees at least one full microsecond before each
    // read, including the first. Keep interrupts masked through the read so a
    // nested caller cannot consume the accumulated entropy during this wait.
    time.sleep_us(2);
    return RNG.DATA;
}

/// Fills a buffer using random_u32(), with the same entropy and initialization requirements.
pub fn read(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        const count = @min(buf.len - i, 4);
        const value = random_u32();
        @memcpy(buf[i .. i + count], std.mem.asBytes(&value)[0..count]);
    }
}
