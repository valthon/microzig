# ESP MicroZig Package

[WIP]

SVD is copied from https://github.com/esp-rs/esp-pacs

## Supported chips

| Chip     | Targets                                                     |
| -------- | ----------------------------------------------------------- |
| ESP32-C3 | `esp32_c3`, `esp32_c3_direct_boot`, `esp32_c3_flashless`    |
| ESP32-C6 | `esp32_c6`, `esp32_c6_direct_boot`, `esp32_c6_flashless`    |

Both chips share clocks, cache, watchdog disable, interrupts, GPIO/IO MUX, systimer/time,
efuse/MAC reads and RNG. On the C6, peripheral interrupts are routed by the interrupt matrix
(INTERRUPT_CORE0) to the CPU-local machine-mode PLIC (`PLIC_MX`), which holds their enable, type,
priority and threshold; INTPRI is used only for the four CPU software interrupts.

## Drivers

Hardware results are from RAM images on an ESP32-C3 rev v0.4 and a Super Mini ESP32-C6FH4 rev
v0.2, as `passed/checks` of the named self-test in `examples/espressif/esp`.

| Driver (`hal.*`)                              | C3  | C6  | Self-test                                          | C3 result | C6 result |
| --------------------------------------------- | --- | --- | -------------------------------------------------- | --------- | --------- |
| `uart` (UART0/1)                              | yes | yes | `selftest_uart`                                    | 5/5       | 5/5       |
| `twai` (CAN)                                  | yes | yes | `selftest_twai`                                    | 10/10     | 20/20     |
| `rmt` (polling TX/RX)                         | yes | yes | `selftest_rmt`                                     | 3/3       | 3/3       |
| `timer`, `wdt` (timer groups, watchdogs)      | yes | yes | `selftest_timers`                                  | 6/6       | 6/6       |
| `usb_serial_jtag` (logging, RX, confirmed TX) | yes | yes | `selftest_usj`                                     | 9/9       | 9/9       |
| `gpio` pin interrupts                         | yes | yes | `selftest_gpio_irq`                                | 8/8       | 9/9       |
| `flash` (erase, write, read)                  | yes | yes | `selftest_flash`                                   | 5/5       | 5/5       |
| `adc` (ADC1), `temperature`                   | yes | yes | `selftest_adc`                                     | 10/10     | 10/10     |
| `ledc` PWM and fades (C6: single-range gamma) | yes | yes | `selftest_ledc_fade` (C3), `selftest_c6_ledc` (C6) | 4/4       | 7/7       |
| `i2c` master                                  | yes | yes | none                                               | see below | built     |
| `spi` master (SPI2), GDMA channel 0 transfers | yes | yes | `selftest_spi_dma`                                 | 8/8       | 8/8       |
| `clocks.sleep` light sleep                    | yes | no  | `selftest_sleep_s*`                                | see below | n/a       |
| `radio`, `rtos`                               | yes | no  | none                                               |           | n/a       |

C3-only modules produce an explicit compile error on the C6. The C3 I2C master ran on hardware
through the `i2c_display_ssd1306_c3_oled_042` example. The C6 LEDC blocking fade helper takes a
timeout in microseconds.

### C3 light sleep and USB-Serial-JTAG

`hal.clocks.sleep.enter_light_sleep` keeps the CPU, SRAM, XTAL and PLL powered and wakes on an RTC
timer deadline or a GPIO level. USB-Serial-JTAG cannot run during this sleep: its APB and 48 MHz
PHY clocks are gated (C3 TRM v1.4 §30.4), and with D+ still pulled up the host never sees a detach,
so the endpoints stay dead after wake. `Config` selects how USB is handled:

- default: entry with the USB pads enabled fails with `error.UsbSerialJtagActive`;
- `allow_usb_loss = true`: sleep anyway, with no recovery attempt;
- `usb_policy = .disconnect_and_reenumerate`: release the D+ pull-up for the sleep (pull override
  with D+ pulled down, pads disabled, held 10 ms; C3 TRM v1.4 Table 5.12-1 USB note and §30.6
  register 30.2), re-attach after wake with the steps of Espressif's
  [Using USB-Serial-JTAG pins as normal GPIO](https://docs.espressif.com/projects/esp-iot-solution/en/latest/usb/usb_overview/usb_serial_jtag.html)
  (pad enable, D+ pull-down off, D+ pull-up on) folded into one CONF0 write, then restore the saved
  CONF0, and report in `Diagnostics.usb_bus_reset` whether the host reset the bus within
  `Config.usb_reattach.bus_reset_timeout` (one second by default). That wait runs only if a host
  counts as attached: a bus reset is pending, or the caller-owned history in
  `Config.usb_reattach.attachment` (a `*usb_serial_jtag.Attachment`) records that the last wait saw
  a reset, or else the SOF frame index advances while it is sampled for up to 3 ms before the
  detach; the sampling is skipped when either of the first two holds. Pass the same `Attachment` to
  every sleep: back-to-back sleeps, with the host still re-enumerating, then keep their wait, and an
  unplugged host costs one timeout. Without it (`null`, the default) only the SOF sample and a
  pending reset count: back-to-back sleeps keep their wait only while the bus reset stays latched in
  `INT_RAW`, and once an application USB interrupt handler clears `USB_BUS_RESET`, or one sleep
  skips its wait, every later one skips. With no host counted, or with the pads disabled by the
  application (left untouched), the wait is skipped and the field stays null. The host must reopen
  its port. `usb_serial_jtag.reconnect()` does the same without sleeping.

Limitation of `.disconnect_and_reenumerate`: the first sleep after power-up, or after the host
attaches, counts no host that is still in its attach debounce (no SOF, no pending reset, empty
history), so it neither waits nor records a result, and sleeping again right away can keep the host
from ever resetting the bus. Before sleeping back-to-back, call
`usb_serial_jtag.wait_for_host(timeout, &attachment)` with the same `Attachment`: it returns true
once the SOF frame index advances or a bus reset is pending (C3 TRM v1.4 §30.6 registers 30.8 and
30.16) and records the host, so the next sleep waits for its bus reset; it returns false on timeout,
and at once with the pads disabled.

Measured on the C3 rev v0.4 with a Windows host, ten back-to-back 200 ms sleeps per case, firmware
without a USB interrupt handler, after `wait_for_host`: with an `Attachment`, and `USB_BUS_RESET`
cleared after each sleep as an application handler would, 10/10 waited and saw a bus reset; without
one, run first and with nothing clearing the reset, 10/10; without one and cleared after each sleep,
0/10 (every wait skipped); without one and not cleared, run right after that, 0/10. After power-up
by plugging into the PC, `wait_for_host` with an `Attachment` saw the host after about 57 ms and the
ten sleeps that followed all saw a bus reset; after an RTC watchdog reset with the PC attached it
saw the host after 67 us, and again 10/10. In those two runs the `Attachment` was passed and nothing
cleared `USB_BUS_RESET`, so both rules counted the host: they show that the sleeps after
`wait_for_host` keep their wait, not which rule kept it (the four cases above separate the two). An
earlier version of this series without `wait_for_host`, right after power-up, skipped all ten waits.

Observed with a Windows host: IN bytes the device sent right after re-enumeration, before the host
reopened the port, did not reach the host application; the cause is not established. The s6
self-test therefore lets the host speak first: after each re-enumeration the host reopens the
port and sends `USJ?` 1.5 s later; the device then sends `USJ nonce=<8 hex digits>` (again each
second until consumed) and passes `cdc_in` only when the host answers `ACK <same digits>`.

`selftest_sleep_s1` to `selftest_sleep_s6` stage the C3 sleep checks (`selftest_sleep` is s4); the
file header documents each stage and the GPIO beacon. Results on the C3 rev v0.4: s1 3/3; s4 passes
every check except `cdc_in`, which fails by design without the reconnect policy; s6 (`wait_for_host`
with the test's `Attachment`, then reconnect without sleep and a 100 ms and a 500 ms sleep, each
checked for a bus reset, the nonce echoed back and the OUT string): 12/12 with a Windows host,
`wait_for_host` true after 3 us. Light sleep has not run on the C6.

## ESP32-C6 boot modes and clocks

C6 boot modes (ESP32-C6 TRM v1.2 §9.2):

- `esp32_c6`: ROM-loadable Espressif image, chip ID 13, normally flashed at offset zero.
- `esp32_c6_direct_boot`: raw flash image with the two `0xaedb041d` magic words. The ROM supports
  direct boot unless `EFUSE_DIS_DIRECT_BOOT` disables it; Secure Boot is not supported in this mode.
- `esp32_c6_flashless`: RAM image loaded and executed through ROM download mode, requiring no
  flash installation.

Flash targets use the ROM's initial flash mapping/cache configuration (TRM §5.3.3 and §9.2).
PLL setup retains ROM analog calibration; this port does not recalibrate or power-cycle the PLL.
CPU frequencies are 80/120/160 MHz from PLL or 40 MHz XTAL divided by 1/2/4/8/16/32; APB is
40 MHz with PLL and follows the divided XTAL otherwise (TRM §8.2.4.1).

RNG reads enable the asynchronous RC_FAST path and are serialized below 1 MHz. On C6, an active
SAR ADC or radio ADC is required for true randomness (TRM §26.3–26.4). The HAL does not enable an
ADC implicitly; without ADC entropy its output is pseudo-random and unsuitable for cryptography.

### Boards and hardware validation

The upstream XIAO target is retained as `boards.seeedstudio.xiao_esp32_c6`. Its pads, bus assignments,
GPIO15 LED, and GPIO3/GPIO14 RF switch match Seeed's
[Pin Map and Hardware overview](https://wiki.seeedstudio.com/xiao_esp32c6_getting_started/).
The [Seeed schematic, sheet 04 ESP32 C6](https://files.seeedstudio.com/wiki/SeeedStudio-XIAO-ESP32C6/XIAO_ESP32_C6_v1.0_SCH_260114.pdf)
shows the 40 MHz crystal and LED connected from 3V3 through R25/D4 to GPIO15 (active low).

The attached validation board is a **Super Mini ESP32-C6**, not a XIAO. Use the bare-chip C6 targets;
there is no Super Mini pin map or LED assumption in this package.

Build the no-wiring core self-test from `examples/espressif/esp` with
`zig build -Doptimize=ReleaseSmall -Dexample=selftest_c6_core`. It builds in all three C6 boot modes.
It checks the 16 MHz systimer against the HP CPU cycle counter, measures the CPU frequency after
each of the 81 ordered transitions between the nine supported frequencies (1.25 MHz to 160 MHz)
with 1% tolerance, exercises GPIO0's output/input path and systimer LOAD_HI,
and compares efuse MAC against the attached board's `98:88:e0:7e:fc:74`. Another board should fail
that MAC check. Clock measurements are relative to the common crystal; they do not establish its
absolute accuracy. It runs once, waits 1500 ms, then repeats saved `SELFTEST c6_core` results and a
`DONE pass=... fail=...` line every second through USB-serial-JTAG.

The additional `selftest_c6_ledc` example samples a 1 kHz PWM through GPIO0, checks 25% and 75%
duty cycles and their active-duty readbacks, measures both XTAL and PLL_F80M clock paths, and
verifies a gamma fade reaches its expected final duty. It also needs no wiring. Fixed-duty updates
use a zero-scale gamma range with DUTY_START and PARA_UP, rather than leaving the duty engine
stopped (TRM §35.3.4.1 and §35.5, registers 35.1–35.2).

Evidence: on the Super Mini ESP32-C6FH4 rev v0.2, from RAM, `selftest_c6_core` passed 85/85 and
`selftest_c6_ledc` passed 7/7.

## Chip specific code

Most of the hal is shared. Where a peripheral differs between chips, the module either switches on
`compatibility.chip` inline (`cache.zig`, `rom.zig`) or forwards to a per chip implementation:

- `hal/clocks.zig` -> `hal/clocks/<chip>.zig`
- `hal/system.zig` -> `hal/system/<chip>.zig`
- `hal/gpio.zig` -> `hal/gpio/<chip>.zig`
- `cpus/esp_riscv.zig` -> `cpus/esp_riscv/<chip>.zig`, selected through the `cpu-config` module

The main differences between the two chips:

- The esp32c6 gates every peripheral from its own PCR configuration register instead of the two
  PERIP_CLK_ENx bitmasks of the esp32c3.
- Its pll is fixed at 480 MHz and the cpu frequency comes from a divider, and its apb clock stays
  at 40 MHz instead of following the cpu.
- The interrupt matrix (INTERRUPT_CORE0) and the cpu interrupt controller (the machine-mode PLIC,
  `PLIC_MX`) are two separate peripherals; cpu interrupts 0, 3, 4 and 7 belong to the local CLINT.
- Its rtc watchdogs live in the low power domain (LP_WDT).
- It has 31 pads instead of 22, the usb serial/jtag pins are GPIO12 and GPIO13 instead of GPIO18
  and GPIO19, and every drive strength maps straight onto its register value.
- Instruction and data share one address space, both for flash (IROM and DROM at 0x42000000) and
  for sram (IRAM and DRAM at 0x40800000), which is why `ld/esp32_c6/image_boot_sections.ld` places
  the rodata first and walks a single region instead of offsetting the two views against each
  other with dummy sections.

## Register patches

`src/chips/ESP32-C6.svd` is byte-for-byte the upstream
[esp-pacs base SVD](https://github.com/esp-rs/esp-pacs/blob/main/esp32c6/svd/esp32c6.base.svd),
SHA256 `b7f76c1779e0154bfb4d94e71344a9abfd71506a20d73cf8a53dd7c60d7b2de0`.
Its `DMA.OUT_CONF0_CH%s` omits `dimIndex`, so the expanded names CH0/CH1 collide with the
explicit CH0 at offset 0xD0. `patches/esp32_c6.zon`, wired through `chip.patch_files`, renames
only the registers at 0x190 and 0x250 to CH1 and CH2 after loading. It leaves addresses, fields,
and the vendored input unchanged; expected-name checks detect incompatible vendor updates.
