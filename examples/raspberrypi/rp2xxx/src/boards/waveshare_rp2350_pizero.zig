//! Waveshare RP2350-PiZero, RP2350B and 12 MHz Y1 crystal.
//! Schematic: RP2350-PiZero.pdf, sheet 1 (RP2350B, Y1 "12MHz(3.2*2.5) 20PF", HDMI):
//! Only bare header GPIO 9-12, 16-17, 20-21 and HDMI TMDS GPIO 32-39
//! are available to the self-test. SD, PIO-USB, HDMI control and PSRAM
//! GPIO 28-31 and 40-47 must retain their reset function and output disable.
pub const xosc_freq = 12_000_000;
pub const has_rp2350b = true;
