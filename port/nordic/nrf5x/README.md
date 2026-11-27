# Nordic nrf5x

HALs and register definitions for nrf5x devices

## Renode supports:

- nrf52840 development kit

## TIMER

`hal.timer.Timer` supports the nRF52840's five TIMER instances. TIMER0–2 have
four capture/compare channels each and TIMER3–4 have six. Each instance supports
8-, 16-, 24- and 32-bit widths, timer and low-power counter modes, and prescalers
0–9. Configure a stopped instance. Capture repurposes its CC register, so use
a separate channel for an active compare. Compare events can be polled, enable
clear/stop shortcuts, or raise an interrupt. Install the handler and enable
the instance IRQ through MicroZig. See the nRF52840 Product Specification v1.11,
§6.30.

Evidence: ran on a XIAO nRF52840 Sense. The XIAO nRF52840 Sense timing self-test compares TIMER1
ticks with `hal.time` and checks the compare-to-stop shortcut.

## RTC compare

`hal.rtc.Rtc` supports RTC1 and RTC2 on nRF52840. RTC0 is reserved for
`hal.time`. Both exposed instances have a 24-bit counter, a 12-bit prescaler,
four compare channels, and separate event and interrupt controls for compare,
tick, and overflow. They use the system LFCLK. Set the prescaler while stopped
and account for the asynchronous START, STOP, and CLEAR tasks. A compare
matches again after counter wrap if left enabled. While running, write a new
compare at least two ticks before the target and account for possible matches
against the old value during the transition. See the nRF52840 Product
Specification v1.11, §6.22.

Evidence: ran on a XIAO nRF52840 Sense. The timing self-test checks that RTC1 delivers one
compare interrupt at the programmed tick, allowing two ticks for ISR latency.

## GPIOTE

`hal.gpiote.Channel` exposes eight nRF52840 channels, with one channel per pin.
Event mode takes over the pin direction and detects rising, falling, or both
edges with the input buffer connected. Task mode takes over direction and
output level and supports SET, CLR, and configurable OUT tasks. Use
`hal.gpiote` PORT helpers with GPIO SENSE for a shared port event. Clear the
DETECT sources to allow another rising edge. The application owns the shared
GPIOTE IRQ and any GPIO configuration that should apply after channel release.
See the nRF52840 Product Specification v1.11, §6.10.

Evidence: ran on a XIAO nRF52840 Sense. The timing self-test uses internal pulls to generate a
channel event on an input and software toggles an LED output to check PORT.

## PPI

`hal.ppi.Channel` exposes twenty programmable event/task channels and twelve
pre-programmed channels on nRF52840. Either kind accepts an optional fork
task and can belong to any of the six groups. Configure channel endpoints
while the channel is disabled and keep hardware group triggers quiescent
while changing routes. Only use addresses of generated event/task registers
for endpoints. The fixed routes are listed in the nRF52840 Product
Specification v1.11, §6.16.1. Fixed channels 28–31 use RTC0 COMPARE0. The HAL
timekeeper owns RTC0, so applications using it must leave that RTC unchanged.
Applications allocate their channels and groups and coordinate any other
firmware's ownership.

Evidence: ran on a XIAO nRF52840 Sense. The timing self-test routes TIMER4 COMPARE5 to two
GPIOTE toggle tasks, checks both pins by readback, then disables the group
and confirms the same compare leaves both pins high.

## NVMC

The nRF52840 HAL accepts a caller-owned flash region and absolute byte
addresses for word reads, programming erased words, and whole-page erase.
Every operation checks alignment and containment before touching flash.
Reserve the writable region in the application layout. Page erase stalls
flash execution and the HAL masks interrupts during each operation. Use it
from foreground code with the SoftDevice disabled. Partial erase and UICR
are outside this API.

See nRF52840 Product Specification v1.11 §4.3. Anomaly 184 applies to
external debugger writes and erases while the CPU is running. This driver
accesses flash from the CPU.

Evidence: ran on a XIAO nRF52840 Sense.

## QSPI

The nRF52840 QSPI HAL provides blocking EasyDMA reads and programs, JEDEC ID
and custom commands, and 4 KiB sector, 64 KiB block and chip erase. The
device must use the controller's SPI NOR command set, including RDSR
(0x05) with WIP at bit 0. The caller configures the clock, opcodes, address
mode, capacity and timeouts, and enables quad mode on the flash before
using quad data commands. Erase before programming and verify mutations
by reading back the data.

For flash that supports release from deep power-down with ABh, set
`deep_power_down_release_us` to the device's tRES1. Initialization sends
ABh using GPIO and waits for the flash to settle before QSPI activation.
The nRF52840 requires READY before a controller-managed power-down exit
(Product Specification v1.11 §6.19, STATUS.READY).

Transfers use word-aligned offsets and nonempty word-multiple lengths of
up to 256 bytes. Keep a stationary, caller-owned handle in static RAM and
use it from one foreground context with the HAL timebase running. A
peripheral transaction timeout retains the handle and its DMA buffer
until system reset. A flash WIP timeout allows retrying the WIP poll
before issuing another flash command.

See nRF52840 Product Specification v1.11 §6.19. The HAL deactivates via
software (anomaly 208) and applies the anomaly 122 workaround before
disabling the peripheral. XIP is outside this API, avoiding the
register-access hazard in anomaly 215.

The XIAO nRF52840 Sense storage self-test uses internal page `0xEC000`
after checking the linked image extent. Its first QSPI case sends B9h to
put the onboard Puya P25Q16H into deep power-down (datasheet v2.1 §10.30),
deinitializes QSPI, then reinitializes and checks the JEDEC ID. The sector
case erases the final 4 KiB sector at offset `0x1FF000` and leaves its test
pattern there. Keep both locations free of application data when running
the self-test.

The existing storage cases ran on a XIAO nRF52840 Sense. The deep
power-down recovery case was built only.

## SAADC

The blocking nRF52840 HAL samples one configured channel at a time and supports
single-ended or differential inputs, AIN0–AIN7, VDD, VDDH/5, burst oversampling
and sticky limit events. Select gain, reference and acquisition time for the
source impedance and voltage range. The 14-bit setting requires oversampling.
Calibrate before first use and after a
temperature change greater than 10 °C. Provide a word-aligned Data RAM buffer
of 1–32767 signed samples and serialize peripheral access. If a conversion
returns `StopTimeout`, reserve its DMA buffer until reset.

The USB-powered XIAO nRF52840 Sense self-test checks VDD at 3.00–3.55 V, single
and buffered with oversampling, plus offset calibration and limit events.

VDDH/5 does not measure the supply on this board. VDDH is tied to the 3.3 V
rail with VDD ([Seeed schematic v1.2, sheet 3](https://files.seeedstudio.com/wiki/XIAO-BLE/Res/260828_XIAO_nRF52840.pdf)),
yet VDDH/5 read well below a fifth of it, by an amount that changed with gain,
while a longer acquisition time changed nothing. Use VDD for the supply. See
[nRF52840 PS v1.11 §§5.3.1 and 6.23](https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/saadc.html).

Evidence: ran on a XIAO nRF52840 Sense.

## TEMP

The nRF52840 TEMP HAL reports die temperature in signed 0.25 °C steps. Run
`temp.init()` after reset to load the FICR factory linearization coefficients
as required by [nRF52840 anomaly 66](https://docs.nordicsemi.com/r/bundle/errata_nrf52840_rev3/page/err/nrf52840/rev3/latest/anomaly_840_66.html).
Keep HFCLK on the crystal for rated accuracy. The specified measurement range
is −40 to +85 °C. The XIAO Sense self-test uses a 10–50 °C die-temperature
window on a room-temperature bench.
See the [nRF52840 PS v1.11 §6.28](https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/temp.html).

Evidence: ran on a XIAO nRF52840 Sense.

## RNG

The blocking nRF52840 RNG HAL fills a caller's buffer with DERCEN enabled or
disabled. Bias correction improves bit uniformity and reduces throughput.
Byte generation time varies, so callers supply a deadline and discard the
buffer on timeout unless they can account for the partial write. The XIAO
Sense self-test checks variation and a coarse count of set bits in each mode.
See the [nRF52840 PS v1.11 §6.21](https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/rng.html).

Evidence: ran on a XIAO nRF52840 Sense.

## POWER reset reason

Read RESETREAS early and write back the flags to clear them. The flags
accumulate across resets. An all-zero snapshot can indicate power-on or
brownout. The HAL exposes the register as read. On parts affected by
[nRF52840 anomaly 136](https://docs.nordicsemi.com/r/bundle/errata_nrf52840_rev3/page/err/nrf52840/rev3/latest/anomaly_840_136.html),
give RESETPIN precedence when interpreting other flags. The XIAO Sense
self-test reads back the register after clearing it.
See the [nRF52840 PS v1.11 §§5.3.6–5.3.7](https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/power.html).

Evidence: ran on a XIAO nRF52840 Sense.

## WDT

Configure the nRF52840 watchdog before starting it. The supported nominal
timeout is 16 through 2^32 cycles of the 32.768 kHz clock. Sleep and debug
halt can each pause counting. Every enabled reload register must request
a reload. Starting the watchdog locks the configuration and there is no
stop task. See the [nRF52840 PS v1.11 §6.36](https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/wdt.html).

The XIAO Sense harness requests a nominal 20 s timeout when it starts a
fresh watchdog. An inherited watchdog keeps its existing configuration.
The analog self-test reports whether the watchdog is running (RUNSTATUS) and
whether RR0 is enabled (RREN.RR0). Measuring the reload interval or verifying
expiry requires a separate test.

Measured on the XIAO nRF52840 Sense, a watchdog reset clears GPREGRET and
GPREGRET2, sets RESETREAS.DOG, and stops the watchdog. The watchdog keeps
running through a soft reset.

Evidence: ran on a XIAO nRF52840 Sense.

## PWM

The nRF52840 HAL exposes PWM0–3 with up and up/down counting, all decoder
load modes, two EasyDMA sequences, refresh and end delay, loop counts, shortcuts,
and polled events. Use `duty_word` with a common-load sequence for a fixed
whole-percent duty cycle. Each instance shares one period across its channels.
Waveform mode uses the fourth word of each step for COUNTERTOP and drives up
to three channels.

Place sequences in aligned data RAM and keep them alive and unchanged until
DMA has finished with them, including any automatic replay. STOPPED confirms a
stop. At very short periods, EasyDMA may repeat the previous sample. Poll
events at least once per period to count them. On revisions affected by
anomaly 183, avoid LOOPSDONE restart shortcuts with nonzero LOOP and a
one-step sequence 1. See the nRF52840 Product Specification v1.11 §6.17 and
nRF52840 Revision 1 Errata §183.

Evidence: ran on a XIAO nRF52840 Sense.

## PDM

The nRF52840 PDM HAL supports the hardware clock frequencies and decimation
ratios, mono or stereo with selectable sampling edge, independent gain offsets,
and polled STARTED, END and STOPPED events. The application owns the clock
source and sample buffers. Queue a disjoint, same-length buffer after STARTED
and before END for continuous capture. The sample count can change between
captures. A live handoff writes only the address. With separate pointer and
count registers, changing both could pair a new address with an old count.
EasyDMA can reuse the current buffer if the replacement misses the boundary.
Access or reuse a buffer only after END
and a confirmed STARTED for a disjoint replacement. When the switch is
uncertain, wait for STOPPED, which confirms all writes have finished.
END during a stop can represent a partial buffer. Buffers must be word-aligned
data RAM and contain an even number of signed 16-bit samples. Stereo samples
are interleaved L/R. Discard startup transients. See the nRF52840 Product
Specification v1.11 §6.15. Engineering A silicon is affected by anomaly 128
(RATIO is inoperative).

Evidence: ran on a XIAO nRF52840 Sense.

## XIAO nRF52840 Sense sensors

The LSM6DS3TR-C uses SDA P0.07 and SCL P0.27 at 7-bit address `0x6a`,
with INT1 on P0.11 and active-high power enable on P1.08. The
MSM261D3526H1CPM uses CLK P1.00 and DATA P0.16, with active-high power
enable on P1.10. Both power pins use S0H1 (standard low drive, high drive
for logic 1). [Seeed Arduino Sense variant, D15–D21](https://github.com/Seeed-Studio/Adafruit_nRF52_Arduino/blob/master/variants/Seeed_XIAO_nRF52840_Sense/variant.cpp#L24-L33)
and [Zephyr Sense devicetree](https://github.com/zephyrproject-rtos/zephyr/blob/main/boards/seeed/xiao_ble/xiao_ble_nrf52840_sense.dts).

Evidence: ran on a XIAO nRF52840 Sense.

### LSM6DS3TR-C driver

The portable I²C driver probes WHO_AM_I, configures both sensors at 104 Hz,
and reads signed XYZ counts in one burst. It uses the fixed ±2 g and ±250 dps
ranges (0.061 mg/LSB and 8.75 mdps/LSB). Configure after a sensor reset or
power-on and let the sensors settle before reading. [ST LSM6DS3TR-C datasheet,
DocID030071 Rev 3, §4.1 Table 3 and §9](https://www.st.com/resource/en/datasheet/lsm6ds3tr-c.pdf).

Hardware evidence: ran on a XIAO nRF52840 Sense (identity, accelerometer and
gyroscope at rest). The host driver test covers register commands and signed
sample decoding.

### Sense self-test

Build `xiao_nrf52840_sense_selftest_sense` from `examples/nordic/nrf5x`.
With the board at rest, the USB CDC harness reports PWM event counts and
timing, GPIO readback at both duty endpoints, IMU identity and motion
magnitudes, and PDM sample variation. The microphone check accepts quiet-room
noise. The board needs only its USB connection.

Evidence: ran on a XIAO nRF52840 Sense.
