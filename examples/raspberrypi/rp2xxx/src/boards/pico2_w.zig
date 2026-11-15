//! Raspberry Pi Pico 2 W: RP2350A, 12 MHz crystal.
//! CYW43 wiring: pico-sdk 2.1.1 src/boards/include/boards/pico2_w.h,
//! CYW43_DEFAULT_PIN_WL_*: REG_ON=23, DATA_IN/OUT/HOST_WAKE=24,
//! CS=25, CLOCK=29. These pins belong exclusively to hal.cyw43.
//! The LED is CYW43_WL_GPIO_LED_PIN=0, not an RP2350 GPIO.
pub const xosc_freq = 12_000_000;
pub const has_cyw43 = true;
