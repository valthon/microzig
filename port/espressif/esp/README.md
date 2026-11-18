# ESP MicroZig Package

[WIP]

SVD is copied from https://github.com/esp-rs/esp-pacs

## Supported chips

| Chip     | Targets                                                     |
| -------- | ----------------------------------------------------------- |
| ESP32-C3 | `esp32_c3`, `esp32_c3_direct_boot`, `esp32_c3_flashless`    |
| ESP32-C6 | `esp32_c6`, `esp32_c6_direct_boot`, `esp32_c6_flashless`    |

The esp32c6 port covers the chip bring up (clocks, cache, watchdogs, interrupt controller), gpio,
the system timer and the usb serial/jtag logger. `hal.i2c`, `hal.spi`, `hal.ledc`, `hal.rtos` and
`hal.radio` have not been ported to it yet and still speak to esp32c3 registers, so they only
compile when their chip supports them.

RNG reads enable the asynchronous RC_FAST path and are serialized below 1 MHz. On C6, an active
SAR ADC or radio ADC is required for true randomness (TRM §26.3–26.4). The HAL does not enable an
ADC implicitly; without ADC entropy its output is pseudo-random and unsuitable for cryptography.

## Boards

| Board                                                                       | Target                              |
| --------------------------------------------------------------------------- | ----------------------------------- |
| [Seeed Studio XIAO ESP32C6](https://wiki.seeedstudio.com/xiao_esp32c6_getting_started/) | `boards.seeedstudio.xiao_esp32_c6` |

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
- The interrupt matrix (INTERRUPT_CORE0) and the cpu interrupt controller (INTPRI) are two
  separate peripherals.
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
