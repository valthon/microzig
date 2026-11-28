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

## IEEE 802.15.4 on nRF52840

Set `microzig_options.hal.ieee802154 = true` to install the RADIO and TIMER3
handlers. Initialize the HAL timebase, initialize a stationary
`hal.ieee802154.Radio` with `init(config)`, then call
`ieee802154_radio().enable()`. Use static storage for the handle: init
installs it as the owner before verifying the hardware, and if init returns
`HardwareFault` it keeps that ownership, so the handle and its DMA storage
must stay stationary until chip reset. Only one handle may own RADIO, TIMER3 and PPI
channels 17–19. Serialize foreground calls. TEMP is reserved for
compensation while the handle is active. Init seeds the CSMA-CA PRNG with
eight bias-corrected RNG bytes. Each byte gets its own 3,968 µs deadline,
16 times the sum of the typical 128 µs startup and 120 µs corrected-byte times
in the [nRF52840 Product Specification v1.11 RNG electrical table](https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/rng.html).
If any byte times out, init continues with a backoff seed that mixes FICR
`DEVICEID` with RTC-backed time since boot. The HFXO request stays active for
other users such as USB.

`disable()` synchronously seals event publication and leaves accepted results
available to poll. `deinit()` returns `Busy` while a result is unread. With an
empty backlog it tears down an enabled radio, then rechecks for saved results
before releasing the handle. Unverified hardware retirement returns
`HardwareFault` and retains ownership. Keep quarantined handle and DMA storage
stationary until chip reset.

`receive(channel)` arms RX on channels 11–26. RADIO and TIMER3 interrupts
handle frames, ACK turnaround, backoffs, retries and energy scans. With
RX-on-when-idle enabled, the radio returns to RX after foreground operations.
With it disabled, an explicit receive ends after one accepted frame and its
ACK, if needed. TX and its ACK wait use the TX request channel, then idle RX
resumes on the last receive channel. With RX-on-when-idle disabled, a matching
ACK with Frame Pending on a possible Data Request opens a 100 ms response
window on the TX channel. This uses the default
[`OPENTHREAD_CONFIG_MAC_DATA_POLL_TIMEOUT`](https://github.com/openthread/openthread/blob/main/src/core/config/mac.h).
The window starts at ACK reception and runs independently of polling the TX
completion. At expiry a qualified frame and any owed ACK finish on that channel.
A matching receive during the window defers a one-shot renewal until expiry.
The outstanding receive request or idle policy then selects what happens next.
A retune, Sleep or an admitted operation can retire the window early.

RSSI is a bounded diagnostic on an already settled RX arm. The RXREADY
capture gives the settle interval, and packet ADDRESS takes precedence over
a conflicting diagnostic.

`poll()` drains a 16-entry FIFO. The separate sticky fault is returned first.
Returned frame slices are valid until the next poll. TX reserves one slot for
each possible on-air attempt and one for `tx_done`. This is nine slots with
seven retries, and two for TX without an ACK request. ED and CCA each reserve
a terminal. TX, ED and CCA return `Busy` when admission capacity or an active
owner blocks the operation. An RX owner found after operation preflight can
complete on the old channel, including its owed ACK, before the admitted
operation starts. An admitted operation blocks Receive until its terminal.
Sleep can abort accepted work. Settings publish as one generation, and a
latched frame retains its END settings through its owed ACK.

With a full FIFO, the driver withholds packet START and waits for a poll to
free capacity. A witnessed drop produces an ordered, coalesced overrun.
`set_notify` installs a wake callback that can run under the driver’s interrupt
mask in either foreground or IRQ context. The callback must return quickly
and avoid calling back into the radio. Drain `poll()` until null before
waiting for another wake.

The driver supports energy scan, unslotted CSMA-CA, ACK timeout and frame
retries, sleep-to-TX, RX-on-when-idle, source match and bad-FCS delivery. The
default backoff exponents are 3 and 5, with four backoffs and three frame retries
by default. Requests may specify up to five backoffs when CSMA is enabled
and up to seven frame retries. Zero backoffs performs one CCA per attempt
without random delay. A busy CCA in that mode reports channel access failure.
Standalone CCA returns true for a clear channel. ED rounds up to a whole
eight-symbol interval and reports the strongest RSSI in dBm. Use
`hal.ieee802154.ed_level` for the IEEE 802.15.4-2006 §6.9.7 scale, from zero at
and below −75 dBm to 255 at −29 dBm. Enhanced ACK and TX security capability
bits are reserved. Scheduled TX/RX and slotted CSMA are outside this implementation.

TX input is the MAC frame without PHR or FCS. EasyDMA uses a private copy and
RADIO generates the FCS. Acknowledged TX returns the matching legacy ACK frame.
Ordinary RX filters IEEE 802.15.4-2003/2006 frames by clear PAN and short or
extended address, including broadcasts. Secured unicast frames can receive
legacy ACKs in either direction. The stack supplies secured TX bytes and
handles RX authentication and decryption. PAN ID 0xffff enables discovery of
beacons from any PAN. A configured node accepts beacons from its own PAN.
Coordinator mode also accepts destinationless frames from its own PAN.
Promiscuous mode accepts frames irrespective of addresses and suppresses
auto-ACKs. Bad-FCS delivery is optional and those frames are never ACKed. Each
received frame has the two FCS octets from RXCRC, LQI from EasyDMA, and RSSI
read at frame END before ACK or RX restarts.

The source-match tables hold 16 short and 16 extended addresses. With matching
enabled, the driver sets Frame Pending only in ACKs to possible Data Request
commands from a listed source. With matching disabled, all such requests get
Frame Pending. For unsecured commands the driver checks the command ID.
A secured legacy MAC command is treated as a possible Data Request because
the driver leaves the protected body opaque. The same classification selects
the sleepy TX response window. ACKs to data frames leave Frame Pending clear.

PPI captures TX ADDRESS and PHYEND, and RX ADDRESS, END and RXREADY on
the 1 MHz TIMER3 (nRF52840 PS v1.11 §§6.16, 6.20 and 6.30). TIMER3 drives
the public clock while enabled. The last valid reading is retained across
Disable and becomes the baseline for the next Enable. TX ADDRESS marks the
end of SFD. TX PHYEND supplies a fallback by subtracting PHR and PSDU
airtime, and starts the 54-symbol ACK wait. RX timestamp conversion also
subtracts the 23 µs RX END pipeline delay. A fault result has null timestamps.
Blocking waits leave the sticky reason and saved results pollable on fault.

RADIO transitions use bounded CPU checks. If TIMER3 appears stopped during
dispatch, the driver confirms the stall with independent RTC0 progress
(nRF52840 PS v1.11 §§6.20, 6.22 and 6.30). The fault path isolates the
producers, leaves the radio Disabled, queues each admitted terminal once
and preserves the first sticky reason and a saturating count.

TXREADY service launches foreground packets under the same mask as explicit
stops. A stop reports a proven TX start before aborting the operation. A sender
ACK wait ends with `no_ack`. A queued RX frame with its immediate ACK
abandoned has both ACK metadata bits clear.

PPI schedules immediate ACK TXEN 129 µs after captured RX END. Together
with the 23 µs RX END delay and 40 µs fast ramp-up, TXREADY→START targets the
12-symbol (192 µs) ACK turnaround. Keep interrupt latency short enough for
foreground TXREADY, ACK scheduling, and entering RX for a peer ACK after TX.
A missed ACK arm reports the received frame with `ack_sent = false`.

Register setup and timing follow the nRF52840 Product Specification v1.11
[RADIO §6.20](https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/radio.html),
PPI §6.16 and TIMER §6.30. The driver disables after RX (anomaly 110), checks
CRCSTATUS after END (112), compensates RSSI, LQI, ED and CCA for temperature
(153), crosses through DISABLED from TX to RX (204), and uses the corrected
ED/LQI conversions (236). It uses DISABLED interrupts in place of SYNC (228), leaves whitening off (245),
and writes DTX directly (248). See the
[nRF52840 Engineering A errata](https://docs.nordicsemi.com/r/bundle/errata_nrf52840_enga)
and [Revision 3 errata](https://docs.nordicsemi.com/r/bundle/errata_nrf52840_rev3).
Nordic's BSD-3-Clause
[nrf_802154_procedures_duration.h](https://github.com/zephyrproject-rtos/hal_nordic/blob/master/drivers/nrf_802154/driver/src/nrf_802154_procedures_duration.h)
and
[nrf_802154_rssi.c](https://github.com/zephyrproject-rtos/hal_nordic/blob/master/drivers/nrf_802154/driver/src/nrf_802154_rssi.c)
document the RX END offset and RSSI compensation. Nordic reports TX start
from ADDRESS in [nrf_802154_trx.c](https://github.com/zephyrproject-rtos/hal_nordic/blob/master/drivers/nrf_802154/driver/src/nrf_802154_trx.c).

Evidence: ran on a XIAO nRF52840 Sense against an ESP32-H2 peer running
ESP-IDF's `ieee802154_cli` commands on channel 25. The
`xiao_nrf52840_sense_selftest_ieee802154` self-test passes every case: init,
ED, CCA, RSSI, broadcast TX, RX timeout, RX while the foreground waits, data
ACKs with pending clear for the H2's frames, a TX the H2 ACKs, and a
three-second sniffer capture. The
port's host tests cover source matching and the driver’s register-boundary
dispatch, deadline and lifecycle regressions.
