//! Seeed XIAO RP2040: 12 MHz crystal (the pico-sdk default) with a 64x start-up
//! delay; user LED on GPIO 25 (active low), WS2812 data on GPIO 12 with its
//! supply switched by GPIO 11 (pico-sdk 2.1.1 src/boards/include/boards/seeed_xiao_rp2040.h).
pub const xosc_freq = 12_000_000;
pub const xosc_startup_delay_multiplier = 64;
