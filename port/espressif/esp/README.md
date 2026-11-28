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

Hardware results are from RAM images unless a boot mode is named, on an ESP32-C3 rev v0.4, a
Super Mini ESP32-C6 (ESP32-C6FH4 rev v0.2) and a XIAO ESP32-C6 rev v0.1, as
`passed/checks` of the named self-test in `examples/espressif/esp`, with `fail=0` in every run
counted. Results labelled "24ebc5d1" used that driver revision (2026-11-19/20).
Other results identify their boards and runs below; dates are included where recorded.

| Driver (`hal.*`)                              | C3  | C6  | Self-test                                          | C3 evidence | C6 evidence |
| --------------------------------------------- | --- | --- | -------------------------------------------------- | --------- | --------- |
| `uart` (UART0/1) | yes | yes | `selftest_uart`, external echo; Pico 2 W peer (C3), Pico 2 W or RP2040-GEEK peer (C6); expected `DONE pass=7 fail=0`; harness below | 3/3 runs, `DONE pass=7 fail=0`, Pico 2 W peer | 3/3 runs, `DONE pass=7 fail=0`, each on Super Mini ESP32-C6 (Pico 2 W peer) and XIAO ESP32-C6 (RP2040-GEEK peer) |
| `twai` (CAN) | yes | yes | `selftest_twai`, transceiver + SLCAN host echo; expected C3 `DONE pass=12 fail=0`, C6 both controllers `DONE pass=24 fail=0` | 3/3 runs, `DONE pass=12 fail=0`, WeAct USB2CANFD host | 3/3 runs, `DONE pass=24 fail=0`, Super Mini ESP32-C6, WeAct USB2CANFD host |
| `rmt` (polling TX/RX) | yes | yes | `selftest_rmt`, Pico edge timer/replay; requires external widths/replay, `DONE pass=3 fail=0` | 3/3 runs, `DONE pass=3 fail=0`, Pico 2 W peer | 3/3 runs, `DONE pass=3 fail=0`, Super Mini ESP32-C6, Pico 2 W peer |
| `timer`, `wdt` (timer groups, watchdogs)      | yes | yes | `selftest_timers`                                  | 6/6, 3 runs (24ebc5d1) | 6/6, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `wdt.Rtc` core reset, C6 USB recovery         | yes | yes | `selftest_rwdt` (from flash)                       | 1/1 in 3 of 3 boots, direct boot (2026-11-20) | 1/1 in 3 of 3 boots each on Super Mini ESP32-C6 (image boot) and XIAO ESP32-C6 (direct boot) (2026-11-20) |
| `usb_serial_jtag` (logging, RX, confirmed TX) | yes | yes | `selftest_usj`                                     | 9/9 echoes, 3 runs (24ebc5d1) | 9/9 echoes, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `gpio` pin interrupts                         | yes | yes | `selftest_gpio_irq`                                | 8/8       | 9/9       |
| `flash` (erase, write, read)                  | yes | yes | `selftest_flash`                                   | 5/5       | 5/5       |
| `adc` (ADC1), `temperature`                   | yes | yes | `selftest_adc`                                     | 10/10     | 10/10     |
| `ledc` PWM and fades (C6: single-range gamma) | yes | yes | `selftest_ledc_fade` (C3), `selftest_c6_ledc` (C6) | 4/4       | 7/7       |
| `i2c` master                                  | yes | yes | `selftest_i2c`, RP2350 peer; expected 8/8          | see below | 8/8 in 5 of 5 boots on Super Mini ESP32-C6 (image boot) |
| `i2s` (Philips stereo 16/32-bit; master TX/RX, shared duplex clocks; integer PLL160M dividers; aligned frames ≤4092 bytes, 4088 for 32-bit; owns I2S0 and DMA pair) | yes | yes | `selftest_i2s`, Pico PIO slave; harness below; requires external EOF/data/guards, `DONE pass=8 fail=0` | 3/3 runs, `DONE pass=8 fail=0`, Pico 2 W peer | 3/3 runs, `DONE pass=8 fail=0`, Super Mini ESP32-C6, Pico 2 W peer |
| `parl_io` (1/2/4/8-bit; XTAL master TX, external-clock RX, optional valid; aligned 4..65532-byte frames; owns peripheral and DMA pair) | no | yes | `selftest_parl_io`, Pico capture/replay, GPIO0–7/18/19; requires external data/guards, `DONE pass=16 fail=0` | n/a | 3/3 runs, `DONE pass=16 fail=0`, Super Mini ESP32-C6, Pico 2 W peer |
| `dedicated_gpio` (8 CPU signals; exclusive pad/signal ownership, CSR set/clear/read) | yes | yes | `selftest_dedicated_gpio`, pad 4, no wiring | 9/9 | 8/8 |
| `gdma` channel pairs 0–2, SRAM memory copy | yes | yes | `selftest_gdma`; exclusive channels, disjoint SRAM/descriptors, bounded wait | 15/15, 3 runs (24ebc5d1) | 16/16, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `spi` master (SPI2), GDMA channel 0 transfers | yes | yes | `selftest_spi_dma`, Pico PIO mode-0 slave; requires external previous-frame echo, `DONE pass=8 fail=0` | 3/3 runs, `DONE pass=8 fail=0`, Pico 2 W peer | 3/3 runs, `DONE pass=8 fail=0`, Super Mini ESP32-C6, Pico 2 W peer |
| `clocks.sleep` light sleep                    | yes | yes | `selftest_sleep_s*` (C3, OLED or beacon), `selftest_sleep_c6_s*` (C6) | see below | s1–s4, s6–s8 on Super Mini ESP32-C6 and XIAO ESP32-C6 (3 runs each); see "C6 light sleep and deep sleep" |
| `clocks.sleep` deep sleep                     | no  | yes | `selftest_sleep_c6_s5` (image boot) | n/a | 3/3 on Super Mini ESP32-C6 and XIAO ESP32-C6; see "C6 light sleep and deep sleep" |
| `sigma_delta` (4 channels, signed density, divider 1–256) | yes | yes | `selftest_sigma_delta` | 3/3, 3 runs (24ebc5d1) | 3/3, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `pcnt` (4 units, channel 0, signed 16-bit, polling watchpoints, 10-bit filter) | no | yes | `selftest_pcnt` | n/a | 9/9, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `etm` (50 routes; 8 GPIO event/task groups, no interrupt allocation) | no | yes | `selftest_etm` | n/a | 5/5, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `mcpwm` (timer/operator 0, A/B complementary, count-up, symmetric dead time; owns group) | no | yes | `selftest_mcpwm` | n/a | 6/6, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `radio` (Wi-Fi station)                       | yes | yes | `tcp_server`, `selftest_wifi_*` (image boot)       | see "Wi-Fi station and RTOS" | see "Wi-Fi station and RTOS" |
| `radio.espnow` (ESP-NOW, polling) | yes | yes | `selftest_espnow`, two boards, same image, no AP; expected `DONE pass=9 fail=0` | 6/6 runs with a C6 peer, `DONE pass=9 fail=0` (2026-11-23) | 11/11 runs on Super Mini ESP32-C6 and XIAO ESP32-C6 (2026-11-23); see "ESP-NOW (C3 and C6)" |
| `radio.ieee802154` (raw MAC, polling)          | no  | yes | `selftest_ieee802154` (image boot, H2 peer, no wiring) | n/a    | 4/4, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 alone and 3 runs with both (2026-11-20) |
| `radio.ieee802154` frame security (levels 1–7), enhanced ACKs | no | yes | `selftest_ieee802154_sec` (image boot, two C6 boards, no wiring); expected `DONE pass=11 fail=0` | n/a | 11/11 on both Super Mini ESP32-C6 and XIAO ESP32-C6, 3 runs booted together and 2 with an 8 s stagger (each board first once); ESP32-H2 (ESP-IDF v5.5.1) received the version-2 enhanced ACK (`Rx ack 10 bytes`) |
| `rtos`                                        | yes | yes | `rtos`: expected `DONE pass=6 fail=0`, five ordered items + empty-queue timeout | 6/6, 3 runs (24ebc5d1) | 6/6, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `systimer`                                    | yes | yes | `systimer`: expected `DONE pass=4 fail=0`, four IRQs + three 1 s intervals, TIMG0 reference, +/-100 us | 4/4, 3 runs (2026-11-20) | 4/4, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (2026-11-20) |
| custom CPU/APB clocks                         | yes | yes | `custom_clock_config`: expected `DONE pass=3 fail=0`, CPU/APB register readback at 20 MHz + 100 ms ROM busy delay vs systimer, +/-100 us | 3/3, 3 runs (2026-11-20) | 3/3, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (2026-11-20) |

### External self-test peers and harness

The UART, SPI DMA, I2S, RMT, PARL_IO and LP UART/I2C entries above and below
state the peer and required checks. Run each test with the external peer attached.
The Pico 2 W RAM firmware is
[`esp_peer.zig`](../../../examples/raspberrypi/rp2xxx/src/esp_peer.zig), built as
`pico2_w_ram_esp_peer` in `examples/raspberrypi/rp2xxx`. Its USB CDC console
accepts `mode <mode> <c3|c6>`, `status`, `reset` (return to flash) and `boot`
(ROM USB loader). Select the mode before starting the ESP image.

Connect common GND; power each board from its own USB. The C3 harness uses
L0/L1/L2/L3 = ESP GPIO0/1/3/10 to Pico GP0/1/2/3 respectively. The Super Mini ESP32-C6
harness uses L0–L7 = ESP GPIO0–7 to Pico GP8–15, GPIO18 clock to GP16 and
GPIO19 valid to GP17. The C6 bank also serves the fixed LP pins. These GPIO
numbers describe the generic harness; the XIAO ESP32-C6 UART uses the RP2040-GEEK route below.

| ESP test | Pico command | Signal roles and required checks |
| --- | --- | --- |
| `selftest_uart` | `mode uart c3` or `mode uart c6` | L1 ESP TX → peer RX, L0 ESP RX ← peer TX. Automatic route probe, 300-byte echoes at 115200 and 1 Mbaud, TX timing ±10%, parity rejection/acceptance; `SELFTEST uart DONE pass=7 fail=0`. |
| `selftest_spi_dma` | `mode spi c3` or `mode spi c6` | L0 MISO, L1 MOSI, L2 SCLK, L3 active-low CS. Mode 0, MSB first, 1 MHz; peer returns the previous frame, zero-padded. Five lengths 1/64/4092/4096/10000, TX-only then RX-only, FIFO after DMA, guards and throughput ±10%; `SELFTEST spi_dma DONE pass=8 fail=0`. Hold CS high/SCLK idle 110 ms between frames. |
| `selftest_i2s` | `mode i2s c3` or `mode i2s c6` | L0 DIN, L1 DOUT, L2 BCK, L3 WS. Philips stereo 16/32-bit at 1 MHz BCK; previous-transfer echo of the sample bits, starting one BCK after the first WS fall. EOF, six size/width pairs and separate directions with guards; `SELFTEST i2s DONE pass=8 fail=0`. Leave BCK/WS idle 110 ms between transfers. |
| `selftest_rmt` | `mode rmt c3` or `mode rmt c6` | L1 ESP TX capture, L0 peer replay to ESP RX. Peer measures 64/137-item absolute widths, ends after 2 ms low and replays after 20 ms. ESP checks levels, widths ±1 tick and TX duration ±100 us; `SELFTEST rmt DONE pass=3 fail=0`. Require `PEER rmt tx_widths_64: PASS` and `tx_widths_137: PASS` (±2 us, excluding final low). |
| `selftest_parl_io` | `mode parl c6` | L0–L7 data, GPIO18 clock, GPIO19 valid. Peer captures falling edges, discards setup bursts <16 edges, detects 1 ms idle, then replays after 20 ms at 1 MHz. ESP releases all ten pads before RX. Widths 1/2/4/8 × valid/software gating × 64/4096 bytes, data and guards; `SELFTEST parl_io DONE pass=16 fail=0`. |
| `selftest_lp_uart` | `mode lpuart c6` | GPIO4 RX ← GP12 TX, GPIO5 TX → GP13 RX, 115200 8N1. Load, echo and empty timeout on LP/HP; `SELFTEST lp_uart DONE pass=5 fail=0`. |
| `selftest_lp_i2c` | `mode i2c c6` | GPIO6 SDA ↔ GP14, GPIO7 SCL ↔ GP15, target 0x42 at 100 kHz. Load and LP/HP scan/readback/NACK recovery; `SELFTEST lp_i2c DONE pass=7 fail=0`. |

After ESP DONE, request `status`: require `errors=0` and no `PEER ... FAIL`.
Require clock PASS within 1% for UART/LP UART baud and SPI/I2S/PARL 1 MHz,
and `PEER uart parity_rx: PASS` for UART. SPI/I2S reply during the next
ESP-clocked transfer; RMT/PARL reply in a separate window. These tests release
their driven pads before asynchronous replay.

The host tools in [`examples/espressif/esp/tools/bench`](../../../examples/espressif/esp/tools/bench)
use pyserial and require explicit serial-port arguments:

- `python pico_peer.py load --port <MicroPython-port> <RAM-UF2>` enters the
  MicroPython raw REPL and loads the RAM UF2 through the Windows BOOTSEL drive.
  It discovers the new CDC port by USB VID:PID and product string. Use
  `python pico_peer.py mode --port <peer-port> <mode> <bank>` before the ESP
  test, then `python pico_peer.py status --port <peer-port>` and optionally
  `python pico_peer.py log --port <peer-port> <seconds>` to collect verdicts.
- For XIAO ESP32-C6 UART, keep debugprobe on the RP2040-GEEK: ESP TX D6/GPIO16 →
  GEEK GP5 RX, ESP RX D2/GPIO2 ← GP4 TX, plus GND. Connect only one UART
  route. `python geek_uart_peer.py --port <GEEK-port> --seconds 30` echoes
  the same baud/parity phases as the Pico and reports the parity verdict.
- TWAI uses an Adafruit CAN Pal TJA1051T/3 and a WeAct SLCAN adapter.
  C6 GPIO20 TX → CAN Pal TX, GPIO17 RX ← CAN Pal RX; C3 uses GPIO4 TX
  and GPIO7 RX. CAN Pal VCC goes to 3V3 and SLNT to GND, all grounds are
  common, CANH/CANL connect to the adapter, and both bus ends have 120 Ω
  termination. Start the ESP image, then
  `python can_echo.py --esp <ESP-port> --can <adapter-port>`. It owns both
  ports, opens each bitrate before releasing the ESP ready handshake and
  echoes frames with ID XOR 1 preserving format/RTR/raw DLC/data. A data
  frame with DLC 9..15 gets a DLC 8 reply carrying its first seven bytes
  and the received DLC, since not every adapter sends a classic DLC above
  8; the ESP self-receives the frame itself. The host sends listen-only
  traffic until the ESP reports `listen_done`, and coordinates bus-off
  recovery. Both ends use 500 kbit/s for bus-off. The ESP switches its RX
  input to constant dominant 90 us after the TX request: at 2 us/bit the
  data field spans bits 19–82, [38, 166) us. Bit framing/stuffing: ESP32-C3
  TRM v1.4 §§31.2.1, 31.2.2.1; ESP32-C6 TRM v1.2 §§33.2.1, 33.2.2.1.
  Fault confinement: ESP32-C3 TRM v1.4 §31.4.7; ESP32-C6 TRM v1.2 §33.4.7.
  Require
  `SELFTEST twai DONE pass=12 fail=0` (C3) or `pass=24 fail=0` (both C6
  controllers), plus host exit 0.
- `python ble_smp_user.py --reset-wdt --board <port>=<log> --board <port>=<log>`
  is the user of two `selftest_ble_smp` boards built with an authenticated
  `-Dsmp_method` (see BLE SMP below). It logs both consoles and types `yes`
  into each board only after both have shown equal comparison numbers, and
  types a passkey into one board only after the other has displayed it.
  With `--reset-wdt` both boards must be in ROM download mode; it starts them
  with an RTC watchdog system reset, and exits 3 before capturing if either
  reset fails. Exit 0 means both printed `DONE pass=N fail=0` after their
  second boot's `phase=1` line in this capture, exit 1 that either did not
  (exit 2 is a usage error). A `DONE` counts only after the board's phase
  line (`SELFTEST ble_smp phase=N`), which each boot prints after starting
  the controller and, in auto mode, about 6 s of role discovery; if a first
  boot fails before that line, the capture runs to `--max-seconds`. A later
  phase line discards an earlier `DONE`, and a partial line is dropped when
  a port is lost or reopened. `test_ble_smp_user.py` beside it tests this
  with fake ports (`python3 -I -m unittest discover -s <dir> -p 'test_*.py'`).

C3-only modules produce an explicit compile error on the C6. The C3 I2C master ran on hardware
through the `i2c_display_ssd1306_c3_oled_042` example. The C6 LEDC blocking fade helper takes a
timeout in microseconds.

GDMA `copy()` on C3 reserves peripheral selector 6 (AES) for pair 0, 7 (SHA)
for pair 1, or 8 (ADC) for pair 2 during the call. Concurrent drivers/channels
must not use the selected peripheral's GDMA selector. C6 uses Dummy selectors
1/4/5. Prior C3 tests observed descriptor errors with reserved selectors;
that is a hardware observation, not a specified guarantee (C3 Table 2.4-1).
With this reservation, `selftest_gdma` passed 15/15 on the C3 and 16/16 on the
Super Mini ESP32-C6 and XIAO ESP32-C6, 3 runs each, at 24ebc5d1 (RAM images, 2026-11-19).

I2S diagnostic `rx_eof_num` is a byte count, matching ESP-IDF v5.5.1
`components/hal/esp32c6/include/hal/i2s_ll.h::i2s_ll_rx_set_eof_num`.
Its bounds require that many RX bytes and duplex TX bytes.
The external `eof_num` case checks 64 received bytes, echoed data and guards.

The USB Serial/JTAG logger holds complete lines in RAM on both ESP32-C3 and
ESP32-C6 from boot, after each HAL reattach, and after a TX timeout.
At boot the first unmasked call probes immediately and can deliver a one-shot
log to an already reading host in the same call. A HAL reattach starts a
100 ms probe delay. `Disconnect.finish`, including `reconnect()` and sleep's
`.disconnect_and_reenumerate`, starts that delay after any bus-reset wait.
Lines logged only in that first 100 ms wait for a later unmasked call.
The probe commits the IN buffer, whether empty or holding an earlier
packet. Masked calls queue throughout a hold. While the probe is pending,
an unmasked call re-commits a still-full buffer once 500 ms have elapsed since
the last commit. Each unmasked probe poll gives it up to 2 ms to drain. Recording the drain
confirms the host is reading and starts a one-time 100 ms settle delay.
An unmasked call can finish the wait, replay the queued lines in order,
then send its own.
Both waits leave the writer free so masked calls can append without waiting
or touching the FIFO. An idle logger retains any pending lines until logging
resumes. Set `microzig_options.hal.usb_serial_jtag_log_hold_size` to
configure the RAM budget (2048 bytes by default, including line lengths).
Zero restores immediate writes.
See the [USB Serial/JTAG logger design](../../../docs/design/usb_serial_jtag_logger.md) for the hold and replay state machine.

In the earlier Windows diagnostic on ESP32-C3 and C6, delayed empty commits
stayed pending while the port was closed and drained promptly after it reopened.
With an immediate probe after reconnect, both C6 boards stopped delivering logs,
and the C3 released its hold while the port was still closed in the late-open run.
The logger commits with
EP1_CONF.WR_DONE and observes drain through SERIAL_IN_EP_DATA_FREE
(C3 TRM v1.4 §30.6 registers 30.1/30.6 and C6 TRM v1.2 §32.7 registers
32.1/32.2). The commit also clears the C6's stuck-at-boot condition described
below.

On Linux, `acm_port_activate` submits bulk IN read URBs when the tty opens.
Enumeration can configure line coding before any reader is active. See
[Linux cdc-acm.c](https://github.com/torvalds/linux/blob/master/drivers/usb/class/cdc-acm.c).
The settle delay gives pyserial 3.5 on Windows time to finish opening.
Its `Serial.open` calls SetCommState and then clears the receive buffer
with PurgeComm. On the C6 bench, immediate replay could lose lines to that
purge. See [pyserial 3.5 serialwin32.py](https://github.com/pyserial/pyserial/blob/v3.5/serial/serialwin32.py).
A hold covers lines logged after a reattach, not before the detach. On the
bench (Windows), lines logged shortly before `reconnect()` were sometimes
missing although the host had taken them; give the host time to read before
calling `reconnect()`.

The logger uses short critical sections for hold decisions, writer ownership
and counters. Waits for the host run with the caller's interrupt state.
Each writer drain (at most 64 bytes) waits at most 2 ms for
the host. Callers with interrupts masked and ordinary interrupt
handlers (identified by a nonzero priority threshold) share one 2 ms deadline
per direct write, plus formatting and FIFO writes. A line from an interrupt
handler or a preempting task is dropped and counted while another caller
holds the writer, including during queue formatting. With holding enabled,
a direct write, replay, or loss report that times out starts a new hold.
This can happen on a self-powered board during a physical replug, when the
host closes the port, or on a host-side reset. A bus-powered board restarts
at boot on replug. For sends with holding enabled, the logger formats the
current line once and stages it in the queue. If the first commit times out
while waiting for an older packet, it keeps the original bytes and timestamp.
Lines that outgrow the queue stream directly and count as lost on timeout.
Unmasked calls check for drain
without polling while full and re-commit at the same 500 ms interval.
The call that observes drain waits for settle before replay. When the queue
is full, excess lines are dropped and counted without waiting. At zero hold
size or in panic, subsequent stalled writes drop immediately until the FIFO
is writable.

The logger retires and counts a failed line if it committed any packet for that
line. Committed bytes, including those of a report, can still arrive after a
timeout. The next successful send reports **at most N** lost or truncated
lines **since the last confirmed report**. Across re-enumeration the host can
consume packets before an application is reading. The count only covers
losses the logger detects, and the host can consume the report itself.
Fatal panic/trap handling masks interrupts and takes over the writer. With
holding enabled, it discards held lines and suppresses loss reports to
prioritize fatal text. A pending probe occupies the FIFO like any committed
packet. The first fatal write can reach its 2 ms deadline before committing
text if the host leaves that packet pending. Delivery remains best effort.
`write_blocking` confirms host packet consumption, and its caller must quiesce
logging first; masking interrupts cannot exclude a preempted logger owner.
The same limitation applies throughout `Disconnect.begin`/`finish`.
This logger is host-tested; on hardware it ran on a XIAO ESP32-C6 (rev v0.1),
2026-11-19, with `selftest_wifi_lifecycle` (before the packet-bounded drain change):
10 of 10 watchdog boots with the port opened 40 s late gave USB output, each
starting with an `at most 25 lines` report. Before the packet-bounded drain change, `selftest_usj`
(RAM image, host echo script) passed 9/9 echo cases on the C3, Super Mini ESP32-C6 and
XIAO ESP32-C6, 3 runs each, at 24ebc5d1 (2026-11-19). The hold queue ran on the C3,
Super Mini ESP32-C6 and XIAO ESP32-C6 with `selftest_usj_reenumerate` under Windows
(2026-11-27, see below). Radio evidence is documented in "BLE bench examples" and "IEEE 802.15.4 raw MAC (C6)".

An argument longer than the buffer is written in packet-sized drains, each
with its own 2 ms timeout unless the caller needs the shared line deadline.
A single drain covering the buffered prefix and the whole argument would
truncate a long string whenever the host takes more than 2 ms to read two
packets. The host tests drive the real Writer, logger formatting and packet
loop through a deterministic FIFO/clock seam (hosted tests only), covering
boundary lengths, vectors/splats, `bytesToHex` slices, raw `{x}`, timeout
accounting/recovery, replay after a late tty open, the shared deadline, and
a large writer that drains in place and gets its full buffer back after a failed drain. When a reservation
needs room, the writer sends packets until the unsent bytes are no more than
the sent prefix before moving them down: in the host test, 64 successive
64-byte reservations on a full 4 KiB writer move 4,096 bytes, where moving
after every packet moved 258,048.

`selftest_usj_reenumerate` (C3 and C6, `-Dexample=selftest_usj_reenumerate`)
discards bytes already in its receive FIFO at boot (the port can survive
the reset that started it), waits for a newline from the host, prints
`SELFTEST usj_reenumerate START`,
then logs numbered `SEQ` lines at 20 ms intervals and reconnects between
cycles. Start capture before sending the newline, and keep reading while
sending it: once the test has started it no longer reads, so a later
newline can block, and a host that stops reading can lose output. After
each detach, reopen USB Serial/JTAG promptly and continue the same capture.
The test uses a 4 KiB queue to fit the lines logged during a reopen about 2.2 s
late and the subsequent settle delay. It passes when every SEQ number from 1 through the final
`seq` in the repeated `SELFTEST usj_reenumerate DONE` line arrives in order,
with no loss report after START.

`selftest_usj_log` (C3 and C6; `-Dexample=selftest_usj_log`) logs seven
`FIELD` lines of 31, 32, 63, 64, 65, 100 and 200 ASCII `h` characters and one
`HEX` line with the lowercase hex of bytes 0 through 31. Each payload is
followed by `len=<decimal> crc32=<eight hex digits>` of the logged text (for
`HEX`, the 64 hex characters: `len=64`)
(CRC-32/ISO-HDLC, `std.hash.Crc32`), then `SELFTEST usj_log DONE`. Start
reading within the three-second startup delay or reset with the port open.
After the startup delay, the first log call waits for the probe and the one-time 100 ms settle before
sending, so the burst completes within its own log calls. On the
ESP32-C3, Super Mini ESP32-C6 (rev v0.2) and XIAO ESP32-C6 (rev v0.1), all
eight payloads matched their length and CRC, with no loss report
(2026-11-23).

On an ESP32-C6, SERIAL_IN_EP_DATA_FREE can read 0 at boot with nothing
committed: IN_EP1_ST (C6 TRM v1.2 register 32.19) idle and the host's IN
tokens NAKed, so a writer that only waits for DATA_FREE never sends again.
On a C6 booted by the RTC watchdog it read 0 before `hal.init` in 30 of 68 boots, and one
WR_DONE let the host read the buffer and set DATA_FREE again. Repeating
WR_DONE on a flushed packet the host had not read changed neither the
delivered log nor its order (C6, 24 runs). The driver therefore writes
WR_DONE when a wait times out, on every line dropped while stalled, and once
before the first write after boot. A host that reads the buffer between the
DATA_FREE read and WR_DONE receives a zero-length packet, which CDC ACM
ignores. The boot-time release is included in the tested XIAO ESP32-C6 logger above
(the packet-bounded drain change does not touch it).

PARL_IO stretches every TX setup clock to factor 65535 before gating it low,
and routes the clock to its pad only after stretching, so a receiver sees
the gating edges and not the full-rate prime.
At a 40 MHz XTAL, allow about 2 ms of setup plus frame time in `timeout_us`;
shorter deadlines can expire before transmission. The low check and gating
write exclude interrupts; phase waits do not. `ClockGateFailed` reports a
pad still high after gating. Mid-count divider changes are a hardware
observation; C6 TRM v1.2 §38.5.1 specifies a maximum factor of 65535.
The external test covers valid/software gating at each supported width.

Timer-group clock enable clears MWDT flash-boot mode only when releasing a
group held in reset, inside a critical section. Calls on an active group do
not unlock, relock or update the watchdog. With this change,
`selftest_timers` passed 6/6 on the C3, Super Mini ESP32-C6 and XIAO ESP32-C6, 3 runs each, at
24ebc5d1 (RAM images, 2026-11-19).

The C3 RTC watchdog (`hal.wdt.Rtc.configure`) sets `WDT_SYS_RESET_LENGTH` and
`WDT_CPU_RESET_LENGTH` to 7 (3.2 us), as ESP-IDF v5.5.1 `wdt_hal_init` does
(`components/hal/wdt_hal_iram.c:57-58`; C3 TRM v1.4 Register 9.31). With the reset value 0
(100 ns) a stage-0 `reset_core` action did not reset the C3 rev v0.4. The C6 RTC watchdog
sets both lengths to 7 too (C6 TRM v1.2 §15.6 Register 15.1 `RTC_WDT_CONFIG0_REG`,
`LP_WDT.CONFIG0`; the same IDF lines above).

On the C6, an RWDT core reset (action 3, `reset_core`) reboots the app with cause 0x09 and
the retained journal, but USJ stops communicating without a host-visible disconnect; a system
reset (action 4, `reset_system`) reboots with cause 0x10 and USJ re-enumerates (XIAO ESP32-C6, direct
boot, UART0 and USJ captured together, 2026-11-20).
C6 TRM v1.2 §8.1.3 includes peripherals in core reset; §32.4 documents USJ's
BBPLL dependency. IDF v5.5.1
`components/esp_system/port/soc/esp32c6/system_internal.c::esp_restart_noos`
keeps BBPLL on for ROM USB logging and uses a CPU reset, with RWDT action 3
then action 4 as fallback. Its bootloader and sleep protection use action 4
(`bootloader_init.c::bootloader_config_wdt`, `sleep_modes.c`).

On C6, the default HAL `init_sequence` calls
`hal.wdt.Rtc.recover_usb_at_startup()` after clocks, system and time
initialization, before RTOS startup and application USB logging, interrupt
handlers or other USB users. SYSTIMER must be running for the reconnect's
bounded waits and detach delay. Applications managing USB themselves can set
`microzig_options.hal.recover_usb_at_startup = false` to omit the call;
the public helper remains available for manual use after clock/time setup and
before USB users start. C3 compiles out this call: it retains its USB connection
through RWDT core reset. C3 TRM v1.4 §30.3.4 states that USJ is not affected by
SRST. On C6, the helper handles RWDT core reset (0x09, TRM v1.2 Table 8.1-1),
after which USJ loses its connection, using the 10 ms soft disconnect/reconnect
with CONF0 pull override (TRM §32.7 Register 32.3). It preserves the reset
cause, leaves disabled pads alone, and discards pending USB transfers.
All other reset causes leave USB alone in this helper, including the USB UART
reset (0x15) used by the CDC-ACM RTS control (TRM Tables 32.3-2 and 32.4-2).
The host monitor must follow re-enumeration; no manual reset is required.
Receive the self-test's PASS over USJ after re-enumeration. With the default HAL
recovery, `selftest_rwdt`
reported `core_reset: PASS reset_cause=0x9 journal=true` and `DONE pass=1 fail=0`
over USJ after re-enumeration in 3 of 3 boots each on the C3 (direct boot), the
Super Mini ESP32-C6 (image boot) and the XIAO ESP32-C6 (direct boot), 2026-11-20.
Without the recovery the C6 host did not re-enumerate.

Build `-Dexample=selftest_rwdt` in `examples/espressif/esp` and run the selected
image from flash, keeping a USB monitor following re-enumeration with no host
reset between boots. C6 HAL initialization recovers before the first USB log;
C3 retains its existing path.
The test clears forced-download boot, journals in retained RTC/LP SRAM, and arms
stage 0 for a core reset after about two seconds using the measured slow-clock
rate and eFuse delay factor. The next boot consumes the journal and reports
`SELFTEST rwdt core_reset: PASS` only with both the pending journal and reset
cause 0x09 (C3 TRM v1.4 Table 6.1-1; C6 TRM v1.2 Table 8.1-1), followed by
`SELFTEST rwdt DONE pass=1 fail=0`. Other reset causes cannot pass; failure to
reset within 6.5 seconds disables the watchdog and reports `DONE pass=0 fail=1`.

The lifecycle test counts TCP bind/listen as an eighth check, publishing
success only after it completes. Setup, reporter-spawn and TCP setup failures
repeat from the main task, even when no reporter could be allocated. The
allocator and registered netif remain in that task's owning frame throughout
failure reporting, since lwIP still references them. The reporter's default
4096-byte stack shares the Wi-Fi/lwIP allocator, which uses the linker-defined
heap region minus a 16 KiB stack reserve (`core/src/allocator.zig`, `heap` and
`init_with_heap`). The heap is not fixed at 16 KiB.
Lifecycle evidence is under "Wi-Fi station and RTOS"; NVS evidence is under
"NVS board self-test".

### I2C master peer self-test

`selftest_i2c` on C3 and C6 expects `SELFTEST i2c DONE pass=8 fail=0`:
initialization, 111 absent-address NACKs, exactly one peer ACK at 0x42,
peer protocol identification, pattern write, separate STOP/start readback,
repeated-start register read, and clock-stretched read. Only `NoAcknowledge`
counts as NACK; timeouts and other transfer errors fail the scan. Use an
isolated bus with only the peer.

Build the ESP in `examples/espressif/esp` with
`zig build -Doptimize=ReleaseSmall -Dexample=selftest_i2c`. C3 and Super Mini ESP32-C6
use SDA GPIO5 / SCL GPIO6. The XIAO ESP32-C6 lacks these edge pads: use
`xiao_esp32_c6_selftest_i2c.bin`, which uses D4/GPIO22 / D5/GPIO23 per
`src/boards/xiao_esp32_c6.zig`'s pin map. Wire SDA to Pico 2 W GP4 (physical
pin 6), SCL to GP5 (pin 7), and connect grounds (e.g. Pico pin 8). Both ends
enable their internal pull-ups; the run below used them alone, with no
external resistors. External 4.7 kohm pull-ups to 3.3 V are recommended for
longer wires or faster clocks.

Build the peer in `examples/raspberrypi/rp2xxx` with
`zig build -Doptimize=ReleaseSmall -Dexample=pico2_w_ram_i2c_slave_peer`.
Load `pico2_w_ram_i2c_slave_peer.uf2` onto the Pico 2 W before starting the
ESP. This RAM image uses the HAL `i2c_slave` at 0x42 with an 8-bit register
pointer: first written byte selects the register; subsequent written/read
bytes increment it. STOP retains the pointer. Read-only registers are
0xf0 (delayed 0xa5), 0xf1 (stretch capability = 1), 0xf2 (immediate 0xa5),
and 0xf3 (protocol version = 1); all others are RAM.

The peer services the HAL slave handler by polling, with its NVIC IRQ masked;
register state belongs exclusively to the main loop. For 0xf0 it waits 20 us
before servicing RD_REQ, which holds SCL low (RP2350 Datasheet
§12.2.10.1.2). The ESP requires the same byte as the normal read and at least
8 us additional elapsed time. Transfers have a 100 ms software deadline and retain
the HAL's hardware SCL timeout (ESP32-C6 TRM v1.2 §29.4.8; command sequence
§29.4.9; ESP32-C3 TRM v1.4 ch.28). A protocol-compatible alternate peer may
advertise capability 0: then `clock_stretch: SKIP` is explicit and the expected
summary becomes `DONE pass=7 fail=0`. The supplied peer always advertises 1;
missing peers and failed capability reads fail rather than skip.

Evidence: Super Mini ESP32-C6 (GPIO5/6), image boot, to a Pico 2 W (GP4/GP5)
running the peer from RAM, jumper wires and common GND, internal pull-ups at
both ends, 100 kHz, 2026-11-20: 8/8 in 5 of 5 boots. With the peer's 20 us
stretch, the stretched read measured +14 to +17 us over normal reads of
214–215 us, hence the +8 us threshold.

### Crypto accelerators

| Crypto driver | Chips | Limits | Evidence |
| --- | --- | --- | --- |
| `sha` | C3, C6 | SHA-1/224/256; CPU, no DMA; synchronous whole-message API, exclusive against DS/HMAC; TRM §23.4.2.1 | `selftest_sha` compares empty, abc, padding boundaries and multi-block input with std.crypto: 21/21 on the C3, Super Mini ESP32-C6 and XIAO ESP32-C6, 3 runs each, at 24ebc5d1 (RAM images, 2026-11-19) |
| `aes` | C3, C6 | AES-128/256 CPU ECB, software CBC/OFB/CTR/CFB8/CFB128 chaining; whole blocks except CFB8, no padding/authentication/DMA, exclusive against DS; TRM §§19.4–19.5 | host `aes/cfb128_vectors.zig` tests pin CFB128 to `std.crypto`; `selftest_aes` SP 800-38A encrypt/decrypt vectors: 24/24 on the C3, Super Mini ESP32-C6 and XIAO ESP32-C6, 3 runs each, at 24ebc5d1 (RAM images, 2026-11-19) |
| `rsa` | C3, C6 | Raw integer operations: modular exponent/multiply 32–3072 bits, multiply 32–1536 bits; odd modulus, caller supplies R², little-endian u32 limbs, bounded polling, exclusive against DS; TRM §§22.3.1–22.3.4 | `selftest_rsa` compares with std.crypto.ff and wide integer multiplication: 12/12 on the C3, Super Mini ESP32-C6 and XIAO ESP32-C6, 3 runs each, at 24ebc5d1 (RAM images, 2026-11-19) |
| `ecc` | C6 only (compile-time gate) | P-192/P-256 affine point verification and verified multiplication; big-endian fixed-size coordinates/scalars, nonzero scalar below group order; no ECDSA/ECDH protocol or Jacobian API; TRM §§20.3.2–20.7 | `selftest_ecc` compares with std.crypto P256 and ff P-192 doubling, including invalid inputs: 7/7 on the Super Mini ESP32-C6 and XIAO ESP32-C6, one image boot each, with interrupts enabled during calculations (2026-11-23) |

AES CFB128 uses the forward block transform for encryption and decryption, with
ciphertext feedback. This matches ESP-IDF's `esp_aes_crypt_cfb128` CPU path in
`components/mbedtls/port/aes/esp_aes.c`; the HAL block sequence is in
`components/esp_hal_security/aes_hal.c` (formerly `components/hal/aes_hal.c`).
ESP32-C6 TRM v1.2 §19.3 Table 19.3-2 selects the block transform; §§19.4.2–19.4.3
specify little-endian CPU words, DMA disabled, TRIGGER=1, and STATE=0 before
reading TEXT_OUT. §19.5's BLOCK_MODE selection applies to DMA operations.
The shared answers come from [NIST SP 800-38A](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38a.pdf)
F.3.13–F.3.14 (AES-128) and F.3.17–F.3.18 (AES-256); F.3.15–F.3.16 are AES-192.
Run the host regression with `zig test src/hal/aes/cfb128_vectors.zig` from this
port directory. Firmware FAIL lines include expected/actual hex and driver errors.

### IEEE 802.15.4 raw MAC (C6)

Select `.hal.radio.radios = .{ .wifi = false, .ieee802154 = true }` and enable RTOS. The image uses the
existing PHY lifecycle, timer and pinned `esp-wifi-sys` blobs (ESP-IDF v5.5.1 ABI).
The MAC sequence and power conversion follow **v5.5.1**, rather than v6.0.2's
newer blob TX-power-table API. The existing v6.0.2 Wi-Fi ROM script is retained;
no new ROM scripts or blobs are added. MAC registers come from the generated SVD
definitions with a command-opcode enum patch. The public C6 TRM does not document
the MAC interface; the register protocol is sourced from v5.5.1's
`components/hal/include/hal/ieee802154_common_ll.h` and `components/ieee802154/driver/`.
Modem power/clock routing is covered by C6 TRM v1.2 §§8.2.4.4 and 12.4.2.5;
the ZB clock map is ACTIVE only, as in IDF `modem_clock.c`.

Initialize one `radio.ieee802154.Radio` in place and keep its address stable until
`deinit`. One task must serialize all calls. `configure` sets channel 11–26, TX
power (−15 to +20 dBm, IDF's clamping/three dB quantization), PAN, short/extended
address (extended octets in wire order), promiscuous RX, legacy auto-ACK and CCA
mode/threshold. `receive(timeout_us)` returns MAC bytes without FCS plus RSSI/LQI;
hardware verifies FCS. Recoverable RX aborts re-arm DMA and issue RX_START within
the same receive window, preserving its original deadline. CRC failures are
discarded; if no valid frame follows before the deadline, the call returns `Crc`
without bytes instead of `Timeout`. `transmit`
accepts 3–125 MAC bytes without length/FCS, supports CCA and automatically waits
for ACK-request frames. Results distinguish TX_DONE, ACK received, no ACK and CCA
busy, after the retry policy finishes. `last_tx_attempts` counts actual frame
transmissions, excluding busy CCAs. `Config.tx` defaults to minBE=3, maxBE=5,
maxCSMABackoffs=4, maxFrameRetries=3, and an ACK wait bound of 54 symbols
(864 us), per IEEE 802.15.4-2015 §§6.2.5.1, 6.7.4.3. Each CCA attempt waits a
uniform random number of 20-symbol (320 us) slots, including the first attempt.
Busy CCA increases BE up to maxBE; the fifth busy CCA returns CCA_BUSY.
Only missing ACK spends the frame retry budget (four transmissions total);
each retransmission restarts CSMA with minBE and preserves the sequence number.
`use_cca=false` retains immediate transmission for raw diagnostic frames, with
ACK retries still enabled. Setting maxFrameRetries=0 disables ACK retries.
Config accepts minBE 0–maxBE, maxBE 3–8, maxCSMABackoffs 0–5,
maxFrameRetries 0–7, and a nonzero u16 ACK wait in symbols. The ACK software
bound starts at TX_DONE; the MAC's hardware ACK timeout also applies.
For version-2 transmissions both software and hardware default to 108 symbols
(1728 µs), matching ESP-IDF v5.5.1. Version 0/1 retains the configured software
wait and a 108-symbol hardware floor. A peer with ACKs longer than that window
needs an explicitly larger `ack_wait_symbols`; the driver never widens it itself.
Latched completion events are consumed before declaring a software timeout, including
when the calling task resumes after the ACK deadline.
`energy_detect` averages
RSSI over 1–65535 us, and `cca` samples for 8 us.

The C6 public TRM v1.2 does not document the radio MAC register protocol.
IDF v5.5.1's [raw driver, lines 876–890](https://github.com/espressif/esp-idf/blob/v5.5.1/components/ieee802154/driver/esp_ieee802154_dev.c#L876-L890)
issues one hardware CCA_TX_START (8 us CCA) or TX_START; its
[abort handling, lines 613–635](https://github.com/espressif/esp-idf/blob/v5.5.1/components/ieee802154/driver/esp_ieee802154_dev.c#L613-L635)
reports missing ACK or busy CCA to the upper layer. The
[OpenThread adapter, lines 354–362](https://github.com/espressif/esp-idf/blob/v5.5.1/components/openthread/src/port/esp_openthread_radio.c#L354-L362)
advertises hardware ACK timeout but no CSMA-backoff or frame-retry capability.
We retain hardware CCA, ACK turnaround/filtering and timeout, and implement
backoff/retries in software. IDF uses a 200 ms software ACK watchdog
(`esp_ieee802154_dev.c:428`); ours bounds invalid/missing ACK paths at
the legacy ACK wait or the enhanced completion floor above instead. No
undocumented ACK_TIMEOUT register units are assumed.

IDF pins OpenThread at `b945928d722177cd9caeab2e1025499628c101ef`:
[`sub_mac.hpp:526–529`](https://github.com/openthread/openthread/blob/b945928d722177cd9caeab2e1025499628c101ef/src/core/mac/sub_mac.hpp#L526-L529)
uses BE 3–5 and 20-symbol slots;
[`config/mac.h:50–90`](https://github.com/openthread/openthread/blob/b945928d722177cd9caeab2e1025499628c101ef/src/core/config/mac.h#L50-L90)
defaults to four CSMA backoffs, but 15 direct/zero indirect frame retries.
This raw MAC uses the requested IEEE default of three frame retries instead.
The [IDF entropy adapter, lines 790–794](https://github.com/espressif/esp-idf/blob/v5.5.1/components/openthread/src/port/esp_openthread_radio.c#L790-L794)
calls esp_fill_random, whose
[`hw_random.c`](https://github.com/espressif/esp-idf/blob/v5.5.1/components/esp_hw_support/hw_random.c)
reads the C6 RNG and mixes an asynchronous timer. We use `hal.rng.random_u32`
directly and mask the low BE bits (a power-of-two range has no modulo bias).
C6 TRM v1.2 §§26.3–26.4 describe RNG entropy and read-rate limits; the HAL
ungates RC_FAST/RNG and spaces reads by at least 1 us. It does not enable SAR
ADC or claim cryptographic entropy from an 802.15.4-only PHY configuration.
The policy's exponent progression, backoff bounds, retry limits, reset after
NO_ACK, terminal busy CCA, and early success/error paths are host unit-tested.
Host completion tests also cover an ACK latched while the task is descheduled
across the deadline and an expired ACK window without a completion event.

The radio selection is `hal.radio.radios`. Wi-Fi defaults to true, BLE and
IEEE 802.15.4 to false. Set one flag, or `.{ .wifi = true, .ble = true }` on the
C6 for Wi-Fi + BLE coexistence. Every other multi-radio selection is a compile
error naming the radios. `hal.radio.wifi` configures
Wi-Fi and `hal.radio.interrupt` selects the interrupt line.
The C6 coexistence adapter provides shared clock and baseband ownership,
and higher-priority radio timer and BLE callout tasks for coexistence.

A coexistence image's radios share one heap: it backs the blob OSI adapter's
allocations and the radio HAL's own init allocations (the radio timer worker,
the PHY and coex timer nodes, and the Wi-Fi eloop reservation). In a
coexistence image the allocator argument of `radio.init` and `Wifi.init` is
not used; `Controller.start`'s allocator still backs the BLE controller's NPL
state. The application owns the shared heap and attaches it once, from task
context, before the first radio init:

```zig
const radio = microzig.hal.radio;

var radio_heap_buffer: [128 * 1024]u8 align(16) = undefined;
var radio_heap: radio.SharedHeap = undefined;

// In main, before the first radio init:
radio_heap = try radio.SharedHeap.init(&radio_heap_buffer);
try radio.attach_shared_heap(&radio_heap);
var wifi: radio.wifi.Wifi = .{};
try wifi.init(gpa, .{});
try controller.start(gpa);
```

`SharedHeap.init(buffer: []u8) error{BufferTooSmall}!SharedHeap` lays a
`microzig.Allocator` over the buffer; that allocator serializes with
`microzig.interrupt.Mutex`, so Wi-Fi and BLE can allocate from it concurrently.
`attach_shared_heap(heap: *SharedHeap) error{ SharedHeapAlreadyAttached, WouldBlock }!void`
stores a pointer to the handle. The buffer and the handle must stay valid,
unmoved and otherwise unused for the rest of the boot: the blobs keep
allocations from the heap after every radio has been deinitialized, and there
is no detach. Until the heap is attached, `Wifi.init` and `Controller.start`
return `error.SharedHeapNotAttached` and acquire nothing. A second attach returns `error.SharedHeapAlreadyAttached` and leaves
the first heap in use; an attach from an interrupt or a radio callback returns
`error.WouldBlock`. Single-radio images have no shared heap and no
`attach_shared_heap` (calling it is a compile error); there the radio
uses the first init's allocator, as before. The blobs' `malloc` and `free`
callbacks take no context argument (esp-wifi-sys
`wifi_os_adapter.h:73-74`), so in a coexistence image the attached handle's
address is the one routing pointer for the radio's allocations. Attach
writes it once, under the radio init lock; it is never changed or cleared.
The OSI callbacks (allocation, semaphores, mutexes, queues, tasks and
timers) read it on every call, as does the radio code that frees what those
callbacks allocated: Wi-Fi teardown for the blob's packet task, the
supplicant start for the eloop timer and mutex it reserves for the blob, and
the last radio deinit for the timer worker and its nodes. Radio init reads it
to allocate the timer worker and the PHY and coex timer nodes. The pointer
lives in an internal module that `hal.radio` does not export; applications
see only `SharedHeap` and `attach_shared_heap`. Single-radio images keep
their routing: the first `radio.init` stores its allocator for the callbacks.

Under Wi-Fi + BLE, BLE follows IDF v5.5.1 `bt/controller/esp32c6/bt.c`:
coex functions are registered, then `coex_init` (1032-1047); enable runs the
shared PHY as the BT modem, the baseband through coex, then `coex_enable`
(1185-1240). The modem reset arms the coex hardware timer (512-530). The PHY
records which modems use it (`esp_phy/src/phy_init.c:308-415`): the first
enable powers on and calibrates, the last disable powers off, and PLL tracking
runs once a second per modem group (`phy_common.c:53-155`). BLE-only and
Wi-Fi-only images keep their private PHY path. The coex preference stays at
the blob default; there is no `coex_preference_set` call. The coexistence
semaphore task slots and the four timer slots (`timer_disarm`, `timer_done`,
`timer_setfn`, `timer_arm_us`) are task-only: an interrupt entry into one
panics, and that panic is the check. `radio.coex_semaphore_stats()` counts take/give
calls on the task slots, which the coex scheme locks share with every Wi-Fi
driver semaphore, and calls of the from-ISR slots, which only the coex core
lock uses; `from_isr_calls=0` shows that lock was never taken from an
interrupt.
`selftest_coex_wifi_ble` (Super Mini ESP32-C6) with its BLE peer
`xiao_esp32_c6_selftest_coex_ble_peer` (XIAO ESP32-C6) and a WPA2 AP with a UDP
echo on 192.168.4.1:7 measures UDP loss, AP RSSI and BLE notification rate in
four interleaved modes (see the source header). In mode D Wi-Fi is torn down
under a streaming BLE link: deinit, 20 s with Wi-Fi off, an init that the
driver rejects (a country with zero channels) and that must roll back, a
fresh init, a second init on the running session, rejoin, DHCP and a UDP echo.
`-Dcoex_ble_first=true` starts the BLE controller before Wi-Fi.
Every Wi-Fi phase must send datagrams and get at least one echo back. Each
A phase (Wi-Fi alone) may lose at most 2% of the datagrams it sent, and each
Wi-Fi + BLE phase at most `max(2 × A-mode median loss, 2% of that phase's
datagrams sent)`; each 2% rounds down (12 of about 600 sent), and a send error
counts as a loss. Without the 2% floor, a lossless A median would allow no
loss at all; without the A bound, a dead echo server would raise the Wi-Fi +
BLE bound to every datagram. If the UDP task has not closed a phase 125 s
after it ended (the cycle's waits and retry sleeps, not the time inside driver
calls), the run stops there and the UDP loss and Wi-Fi cycle checks fail.
Expected `SELFTEST coex_wifi_ble DONE pass=8 fail=0 void=0`, repeated with
`COEX order=wifi_first` (or `ble_first`); the semaphore counters are printed,
not checked. Evidence: run on hardware with a Super Mini ESP32-C6 as the DUT,
a XIAO ESP32-C6 as the BLE peer and a Pico 2 W as the channel-6 AP and UDP
echo, one sitting in each start order. Both printed `pass=8 fail=0 void=0`.
In each, the phase AP RSSI medians stayed within 1 dB of each other, every
datagram of the Wi-Fi phases was echoed, BLE streamed about 40 notifications
a second with no disconnect, the peer saw no sequence gap, and
`from_isr_calls` stayed 0. Each Wi-Fi cycle finished inside its phase:
deinit took about 0.1 s, most of it the wait after leaving the AP (see
`Wifi.stop`), and never returned `WouldBlock`; the rejected init returned
`InvalidArg`; the station rejoined within about 12 s; the UDP probe came back;
and notifications kept going out while Wi-Fi was deinitialized. With the DUT
sending to a UDP port the AP does not echo, the same test printed
`udp_loss: FAIL NothingEchoed`, `wifi_cycle` failed on its UDP probe, and the
run printed `pass=6 fail=2 void=0`.

The adapter keeps both blob semaphore handles and the
52-byte ROM callback table for the lifetime of the boot. It reserves the
scheduler timer before pre-init and releases it on final radio deinit.
The C3 and C6 Wi-Fi blobs also retain their API and global recursive mutexes.
Wi-Fi supplies boot-lifetime storage for both, so these mutexes survive a
failed init or deinit followed by a session with a different allocator.
Coexistence images put the shared timer worker, timer nodes and allocations
through the blob OSI adapter on the attached `radio.SharedHeap` (see above);
the coex examples give it 128 KiB. The last radio owner releases the worker
and nodes. Wi-Fi can be shut down while BLE keeps running on the common
resources; the BLE controller has no shutdown. BLE controller
and NPL storage retain their documented controller lifetime.

Wi-Fi `init`, `deinit`, `start`, `stop`, `set_mode` and `apply` reject a
competing lifecycle operation immediately. `apply` holds its claim from the
mode change through the last interface configuration. From a
synchronous Wi-Fi event, receive, transmit or radio timer callback, schedule
lifecycle work on an application task after returning.
Wi-Fi init reports `WifiSessionBusy`, ESP-NOW reports `Busy`, and the other
coexistence lifecycle calls report `WouldBlock`.
With no session, `start`, `stop`, `set_mode`, `apply` and `deinit` return
`error.WifiNotInitialized`. While a teardown or init rollback is pending,
`start`, `stop`, `set_mode` and `apply` return `error.WouldBlock` until the
owner's retried deinit finishes. A failed teardown step stays pending until a
retry gets past it, so a step that keeps failing leaves init returning
`error.WifiSessionBusy` for the rest of the boot.
Coexistence Wi-Fi stop and deinit post their steps to the driver's
packet-processing (PP) task, which waits up to 10 ms for a slot in its
200-entry queue (C6 libpp.a `pp_post`). If the full queue rejects the driver
deinit step, `Wifi.deinit()` returns `error.WouldBlock`: the driver has
restored its initialized state, and a retry resumes at that step. If it
rejects a stop step, `Wifi.stop()` and `Wifi.deinit()` panic with a message
naming the rejected step, or both steps. The blob has
then either stopped the hardware with the interfaces still started or stopped
the interfaces with the hardware still running. In the disassembly of C6
libnet80211.a (see `osi.stop_driver`), a second stop then spins in
`wifi_hw_stop` on the stopped interface, or returns success without stopping
the hardware. ESP-IDF v5.5.1 links the same
`esp_wifi_stop`; in the first case its `esp_wifi_deinit` returns
`ESP_ERR_WIFI_NOT_STOPPED` (`esp_wifi/src/wifi_init.c:180-183`).
`esp_wifi_stop` also allocates a fresh ioctl for each of its three steps and
returns `ESP_ERR_NO_MEM` if the second or third allocation fails, after the
interfaces have stopped. Coexistence `Wifi.stop()` and `Wifi.deinit()` hand
those allocations the reserved ioctl buffer, and panic if an allocation still
fails after the interfaces stopped. The driver deinit allocates its ioctl from
the heap: if that fails, the driver restores its initialized state,
`Wifi.deinit()` returns `error.OutOfMemory`, and a retry resumes at that step.
While either is stopping the driver,
`Wifi.disconnect()` returns `error.WouldBlock`: the blob's disconnect tests
the started state (`g_ic+0x1f1`) without the driver lock, so a stop can
complete between that test and the post, and the disconnect would then mark the
stopped interfaces started.
Declare a caller-owned `radio.wifi.Wifi` and initialize it in place. Keep the
handle at that address until `Wifi.deinit` succeeds and any concurrent calls
have returned. Serialize operations with deinit, except for stop, deinit and
connect, which may overlap as documented by `Wifi`. Reinitializing a handle
while any of those calls from the previous session are still outstanding
returns `error.WifiSessionBusy`. The handle retains the last station and AP
event state after deinit and after an init rejected during option validation.
In either radio selection, a second handle's init returns
`error.AlreadyInitialized`. Driver operations on a handle without ownership
return `error.WifiNotInitialized` before any `error.WouldBlock` check. In both
radio selections, driver operations on the owner, including connect and
disconnect, return `error.WouldBlock` until the initial init succeeds.
The cached station and AP state accessors remain available. If init returns
`error.WifiRollbackPending`, the owner can call deinit to retry cleanup.

Deinit refuses new connects and waits up to 1 s for earlier connects to
finish, including on every coexistence deinit retry. If a connect is still
in flight, deinit returns retryable
`error.Timeout` before advancing teardown. An ordinary stop can proceed after
that wait.

`Options.on_event` is a process-global listener. An event posted before
`Wifi.deinit` returned can still reach the listener after deinit releases the
handle. The driver finishes updating handle state before invoking the
listener. Events that arrive with no owner are dropped.

A coexistence `Wifi.init` allocates from the attached `radio.SharedHeap`.
As in IDF v5.5.1 (`esp_wifi/src/wifi_init.c:343-345`), init on the running
owner succeeds without reading its `InitConfig`. It returns
`error.WifiSessionBusy` while another lifecycle call is in progress or a
teardown or init rollback is pending. In these cases the owning handle
returns `error.WifiSessionBusy` before validating the power-save mode. In a
single-radio image, init on the owner returns `error.AlreadyInitialized`.

In either selection, `error.WifiRollbackPending` means the handle still owns
Wi-Fi. Retry `Wifi.deinit` with that handle until cleanup succeeds. An init
that acquires ownership and fails with another error finishes cleanup before
returning. The [ESP-IDF v5.5.1 station example](https://github.com/espressif/esp-idf/blob/v5.5.1/examples/wifi/getting_started/station/main/station_example_main.c#L104-L105)
passes its Wi-Fi initialization configuration from the stack.
A sub-tick deadline lets the timer worker sleep until the next RTOS tick or
an earlier arm signal. Single-radio images retain their existing clock,
timer and PTI settings.

Limits include multi-PAN, scheduled operations and sleep retention. Wi-Fi
initialization in an IEEE 802.15.4 image and IEEE 802.15.4 initialization in a
Wi-Fi image return `UnsupportedRadioProtocol`. Legacy version 0/1 and 2015 version 2 frames are
supported; version 2 ACK generation is opt-in (see "Frame security and enhanced
ACKs" below). Promiscuous RX never auto-ACKs. Polling has no background queue: the MAC is idle between calls and
frames arriving while the application prints or transmits can be missed.
Every `receive` ends with a stop, so keep windows long and the gaps between them
short; yield between windows so the PHY tracking task runs. With 10 ms windows
`selftest_ieee802154` missed 12 of 164 frames (about 1 in 14) sent every 0.6 s;
with 500 ms windows it missed none of 82.
Legacy ACKs always clear the pending bit; no indirect-data queue is maintained.
All MAC waits are bounded; a stop timeout resets the MAC to end DMA and marks
the handle faulted, requiring `deinit`/`init`. No PHY calibration is saved in NVS.

Evidence: host tests for malformed TX headers and power conversion, all eight
recoverable RX aborts, a filtered-then-valid frame in one receive window, and
the CSMA/retry policy and ACK completion cases above. On hardware, 2026-11-20,
image boot, channel 25, `selftest_ieee802154` at +20 dBm against an
ESP32-H2 `ieee802154_cli` peer at +20 dBm: `DONE pass=4 fail=0` with `peer_ack`
2/2 in 3 of 3 runs each on the Super Mini ESP32-C6 (generic image) and the XIAO ESP32-C6 (board
build) alone, and in 3 of 3 runs with both booted at the same moment (6 of 6
board runs). In each of the 12 board runs the C6 received all 40 ACK-request and
40 no-ACK frames from the H2, and the H2 counted 40 of 40 ACKs. Two of the 48
C6 transmissions in those runs took a second attempt.

#### Frame security and enhanced ACKs

`ieee802154.security` implements the auxiliary security header, key identifier
modes 0–3, security levels 1–7 for frame versions 1/2, and explicit 32-bit
frame counters, per IEEE 802.15.4-2015 §9. Supply `Config.security = &context`,
where `security.Context` borrows a stationary `[]Key`, `[]Replay`, and optional
`[]const Peer` (PAN/short to extended-address mappings). Extended-address
sources need no peer mapping. Identifiers match mode, index, and the mode's
4/8 key-source octets; mode 0 selects the implicit key. Duplicate key
identifiers and duplicate AES key material are rejected (separate counters for
the same AES key could reuse a nonce). Keep table order and key material stable
for the lifetime of its replay state. This is a raw MAC key table, not a key
negotiation or device-admission service.

For `transmit`, set the FCF security bit and include an encoded
`security.Auxiliary` followed by plaintext; omit MIC/FCS. Its supplied counter
is replaced by `Key.reserve()`. Reserve is shared by outgoing data and enhanced
ACKs; retries preserve the reserved counter and sequence. The output including
MIC must fit 125 MAC octets; the caller buffer is never changed. `receive`
decrypts before returning (verifying the MIC at levels that carry one), removes
MIC/FCS, and retains the original auxiliary header. Use
`header.parse(frame.bytes()).payload_offset` to find plaintext, after checking
`Frame.protection`: `.unsecured` (security bit clear), `.authenticated` (MIC
verified, decrypted) and `.decrypted_unauthenticated` (level 4 under
`accept_unauthenticated`: decrypted, but no MIC, so nothing vouches for it)
frames hold plaintext there; `.raw_secured` ones (promiscuous, below) hold
ciphertext and MIC. Without `Config.security`, a secured frame returns
`UnknownKey` rather than unauthenticated bytes. With `Config.promiscuous`,
`receive` is a capture path instead: every frame, secured or not, is returned
exactly as received (auxiliary header, ciphertext and MIC; FCS removed),
whether or not a security context is configured, and receive never verifies it,
decrypts it, or touches replay slots or key counters. Such frames are
unauthenticated, and `Frame.protection` is `.raw_secured` for them. The rule is
`header.deliver`, host-tested. `last_ack` holds the received ACK, also without
MIC/FCS; for a secured ACK, `protection` is set the same way
(`header.receive_ack`). A secured version-2 exchange requires the matching
security level/key identifier in its ACK.

Transmit CCM* at levels 5–7, including secured enhanced ACKs, uses the C6 MAC's
security engine. Programming order follows IDF v5.5.1
[`esp_ieee802154_sec.c:16–29`](https://github.com/espressif/esp-idf/blob/v5.5.1/components/ieee802154/driver/esp_ieee802154_sec.c#L16-L29)
and [`ieee802154_common_ll.h:442–468`](https://github.com/espressif/esp-idf/blob/v5.5.1/components/hal/include/hal/ieee802154_common_ll.h#L442-L468):
extended nonce address, key, security payload offset, then security enable
immediately before transmission. The offset **excludes PHR**, as
[`frame.c:269–292`](https://github.com/espressif/esp-idf/blob/v5.5.1/components/ieee802154/driver/esp_ieee802154_frame.c#L269-L292)
shows; legacy command identifiers remain clear/authenticated. TX_DONE or abort
clears `SEC_EN` before ACK reception, following IDF `event_end_process`. The
public `esp_ieee802154_set_transmit_security` API does not enumerate supported
levels, and the MAC engine did not produce valid MIC-only (1–3) or
encryption-only (4) frames on the Super Mini ESP32-C6 or XIAO ESP32-C6, so
levels 1–4 are secured in software with `SEC_EN=0`: data frames use software
AES, MIC-only enhanced ACKs use the CPU AES accelerator (below).

IDF exposes no receive decrypt/authenticate operation, so RX uses bounded CCM*
over `std.crypto.core.aes.Aes128`, also exercised on the host, without
acquiring the AES peripheral. The nonce reverses the wire-order source
extended address, appends the big-endian counter, then the security level.
Levels 1–3 authenticate the clear MAC bytes as associated data; level 4
encrypts without authentication.

Receive checks run in the order of the incoming frame security procedure
(IEEE 802.15.4-2015 §9.2.4, with §9.2.5 security level checking). The
standard's text was not available to this port; the steps below are cited as
two public implementations perform them: Linux
[`net/mac802154/llsec.c` v6.12 `mac802154_llsec_decrypt`, lines 1025–1052](https://github.com/torvalds/linux/blob/v6.12/net/mac802154/llsec.c#L1025-L1052)
and OpenThread
[`src/core/mac/mac.cpp` `Mac::ProcessReceiveSecurity`, lines 1665–1773 at 938d74cf](https://github.com/openthread/openthread/blob/938d74cf766a4bbe88ec73155ebd508caf270b23/src/core/mac/mac.cpp#L1665-L1773).

1. A set security bit with level 0 is not a security level:
   `UnsupportedFrame`.
2. Security level policy: level 4 is the only level without a MIC, so anyone
   can send one, with any counter, without the key. It is rejected with
   `ImproperSecurityLevel` unless `Context.accept_unauthenticated` is set
   (default false). Linux checks the level against a configured set
   (llsec.c:1030); OpenThread accepts only level 5 (mac.cpp:1675).
   The policy also applies to received ACKs, so with it off a version-2
   level-4 transmit that requests an ACK cannot succeed (`last_ack_error` is
   `ImproperSecurityLevel`).
3. Counter 0xffffffff is rejected with `InvalidCounter` (llsec.c:1039), and
   `Key.reserve` never sends it (llsec.c:756 on transmit): `next_counter`
   reaching 0xffffffff returns `CounterExhausted`.
4. Key lookup (`UnknownKey`), sender lookup (`UnknownPeer`), then the counter
   must exceed the last committed one for that sender and key (`Replay`), and
   a sender with no slot for that key needs a free one (`ReplayTableFull`).
5. Unsecure (decrypt/verify). Only then is the replay slot committed, as
   OpenThread does after `ProcessReceiveAesCcm` (mac.cpp:1734, then 1746/1748). Linux
   commits before decrypting (llsec.c:1044, 1052); this port does not.

Replay slots are per extended sender and key and never evicted. A new sender
gets `ReplayTableFull` when no slot is free. That check runs before the MIC
(step 4), so the sender is still unverified: the error says only that a frame
claimed a new sender, not that the sender holds the key. Nothing is committed.
Authentication failure returns no plaintext and changes no state. A frame
accepted under `accept_unauthenticated` (level 4) is checked against the
committed counter read-only and **never** creates or advances a slot: it has
no replay protection of its own, and cannot move the state authenticated
traffic depends on. Do not treat level 4 as proof of sender identity or
integrity. The same checks apply to received enhanced ACKs. A CRC-valid
duplicate of an accepted frame can still receive an ACK, so a sender whose ACK
was lost and retries is acknowledged; `receive` then returns `Replay`.

The caller **must persist** transmit-counter reservations and receive replay
state across resets before reusing a key; reservation stops after 0xfffffffe
and returns `CounterExhausted` rather than wrapping. The library provides no NVS
persistence or key rotation. Its only receive security policy is the level-4
switch above: unsecured frames (security bit clear) remain allowed, and
accepted secured levels are 1–3 and 5–7, plus 4 when opted in. `transmit_wire` accepts a
complete pre-secured MPDU for diagnostics/interop without changing counter/MIC;
its caller owns nonce uniqueness. Do not use it instead of `transmit` in an
application that expects automatic counter allocation.

Set `Config.enhanced_ack = true` and install
`.interrupt29 = hal.radio.ieee802154.interrupt_handler` in `microzig_options`;
`init` returns `MissingAckInterrupt` otherwise. Legacy applications need no new
handler. Only IEEE802154 images selecting this handler contain the turnaround
ISR; Wi-Fi/BLE routes and handlers are unchanged. The driver maps ZB_MAC to
interrupt29 only during an enhanced-ACK receive, at **priority 15**,
level-triggered, then unmaps/disables it before returning. The application
still uses synchronous polling APIs. The ISR only snapshots events, builds and
arms the ACK and its security for RX_DONE, and publishes completion; it never
allocates, logs, decrypts incoming data, or updates replay slots. The sequence
follows IDF v5.5.1
[`dev.c:isr_handle_rx_done`](https://github.com/espressif/esp-idf/blob/v5.5.1/components/ieee802154/driver/esp_ieee802154_dev.c#L438-L495):
`ieee802154_inner_enh_ack_generator` → TXDMA address → security update →
`ieee802154_ll_enhack_generate_done_notify`. As in IDF, it runs for every
ACK-requested version-2 frame, secured or not; unsecured requests disable
`SEC_EN` and use no security context. IDF's
[`ack.c`](https://github.com/espressif/esp-idf/blob/v5.5.1/components/ieee802154/driver/esp_ieee802154_ack.c)
manages the pending bit/table, not CCM*: the application supplies the
enhanced-ACK generator. The hardware owns the 12-symbol (192 µs at 2.4 GHz)
turnaround in IEEE §6.7.4; the ISR issues no software TX_START. The
generator's decision (`ieee802154/ack_request.zig`, host-tested) either
refuses a request having reserved nothing, or reserves exactly one counter
for the ACK it builds. For a secured request it runs steps 1–4 above except
the replay check, plus the MIC length check, before reserving: no security
context (`UnknownKey`), level not accepted, counter 0xffffffff, unknown key,
no source address or an unknown short source (`UnknownPeer`), a frame too
short for its MIC (`InvalidFrame`), in the order the task-level check uses.
It then refuses a request it cannot answer (an ACK frame, a
sequence-suppressed request without a source) and a key whose counters are
exhausted (`CounterExhausted`), still before reserving. The ACK builder also
refuses an ACK that would not fit, a guard that cannot trigger with the
limits in force: the largest ACK is 122 of 125 octets. A refused request gets no
ACK, stops RX as IDF does, and `receive` returns the refusal error. For a
secured request refused by the incoming-security checks this is the error
the task-level check would return. Three cases differ: a key whose counters
are exhausted drops even a genuine authenticated frame
(`CounterExhausted`); a secured ACK-type frame with the ACK request bit set
returns `InvalidFrame` where the task would parse and authenticate it; and
an unsecured version-2 ACK request that fails to parse (for example an
unterminated header IE list) or cannot be answered also gets no ACK and
`receive` returns `InvalidFrame` or `UnsupportedFrame`, where without
enhanced ACKs the same frame is delivered. Failure to generate the ACK after
the reservation (`CryptoTimeout` from the AES accelerator), or an ACK-phase
abort, returns `AckTransmitFailed`; expiry without completion returns
`Timeout`. Legacy ACK generation/pending handling remains in the existing
hardware/polling path.

For level 1–3 ACKs, CCM* uses the C6 AES accelerator in Typical AES mode,
following [ESP32-C6 TRM v1.2 Chapter 19, §§19.4.2–19.4.3](https://www.espressif.com/sites/default/files/documentation/esp32-c6_technical_reference_manual_en.pdf).
The key/mode are loaded once per ACK, retained across blocks, then wiped/reset
on every exit. An ACK carries no payload, so a MIC-only ACK needs only B0, its
length-prefixed associated-data blocks and S0, independently of MIC length.
Each transform has a fixed 256-status-read bound; a stuck accelerator returns
`CryptoTimeout` and stops generation. Level 4 ACKs have neither payload nor MIC
and need no crypto. `hal.aes` masks interrupts throughout its operations, so
the ACK ISR cannot interrupt its key/block state. Other direct AES users and DS
must remain idle throughout enhanced-ACK receive.

Enhanced ACKs echo sequence suppression and use a fresh local counter and the
matching level/key identifier if the received frame was secured. ACKs with a
sequence number omit both addresses and PAN IDs; sequence-suppressed ACKs carry
the received source as destination (IEEE 802.15.4-2015 §7.3.2, enhanced
acknowledgment frame format). `Config.ack_header_ies` optionally borrows a
complete header-IE byte string ending with a zero-length HT2 terminator, its
only terminator (at most 80 IE octets). HT1 is refused (`InvalidFrame`): it
announces payload IEs, and the generator copies the list verbatim and appends
none (Wireshark `packet-ieee802154.c` sets `payload_ie_present` only after
HT1; IDF's frame parser and OpenThread's builder use HT2 to end the header
before the payload). With enhanced ACKs enabled, at most 16 keys and 16 peers
are allowed, to bound interrupt work. ACK generation precedes task-level
receive authentication, as in IDF's generator path; it is not an application
delivery receipt.

Residual: like IDF's generator, the ISR does not verify the request's MIC
before the 192 µs turnaround, so a forged request at an accepted level, with a
known key identifier, a counter below 0xffffffff and a sender that is either a
known short address or any extended address (the peer table is not consulted
for an extended source),
still gets a secured ACK, and each one consumes one transmit counter of that
key (`Key.reserve` is shared with data). Skipped counters do not desynchronize
peers, which accept any larger counter; they only bring `CounterExhausted`
closer. The replay check is left to the task, so a replayed genuine request
also consumes one: refusing duplicates would leave a sender whose ACK was
lost, and which retries, unacknowledged. The smallest request that reserves a
counter has a 2-octet frame control field, a short source, a 5-octet
auxiliary header (key identifier mode 0), a 4-octet MIC and no payload: 14
octets with a sequence number (12-octet ACK) or 13 without (13-octet ACK, which
carries the source back), as the host test "smallest requests that reserve a
counter" builds them. Each forged request therefore costs at least both frames
with a 2-octet FCS and 6 PHY octets each, plus the 192 µs turnaround: 1536 µs
at 250 kb/s (32 µs per octet), so exhausting 2^32−1 counters takes at least
76.35 days of continuous forged traffic. With `accept_unauthenticated`, a
level-4 request has no MIC: 1280 µs and 63.63 days. These figures are
computed from the frame sizes, not measured, and do not assume the MAC's
address filter drops frames without a destination address. Monitor
`next_counter` and rotate the key before it runs out.

The initiator programs `ACK_TIMEOUT` before each attempt (including retries).
[IDF v5.5.1 `esp_ieee802154.c:esp_ieee802154_set_ack_timeout`](https://github.com/espressif/esp-idf/blob/v5.5.1/components/ieee802154/esp_ieee802154.c#L217-L230)
rounds microseconds up to 16-µs register units; its getter multiplies by 16.
The [public API](https://github.com/espressif/esp-idf/blob/v5.5.1/components/ieee802154/include/esp_ieee802154.h)
documents the reset/default as 108 units = 1728 µs, which this driver keeps for
version 2 in hardware and software. IDF's
[`dev.c:isr_handle_tx_done`](https://github.com/espressif/esp-idf/blob/v5.5.1/components/ieee802154/driver/esp_ieee802154_dev.c)
adds a separate 200-ms software watchdog; it cannot extend the hardware's ACK
timeout. With five header-IE octets and key identifier mode 1, the unsecured
ACK is 8 MAC octets and levels 1–7 produce 18/22/30/14/18/22/30 MAC octets
(without FCS). At
250 kb/s the largest takes `12 + 2*(6 + 30 + 2) = 88` symbols including
turnaround, six PHY octets and FCS: 1408 µs, inside the 1728 µs window (a
size calculation, host-tested). A full 127-octet PSDU would take 278 symbols
and cannot finish within 108; as in IDF, a peer that sends such ACKs needs an
explicitly larger window (`Config.tx.ack_wait_symbols`).

`Frame.ack_transmitted` requires ACK_TX_DONE for that reception, not merely
RX_DONE. `Config.ack_diagnostics` (off by default) additionally records each
generated enhanced ACK in `Radio.last_ack_tx`: received level and counter, ACK
counter and length, any generation error, and the first terminal event
(ACK_TX_DONE or RX_ABORT, or a stop). `Ack.transmitted()` is true only for an
ACK_TX_DONE without RX_ABORT; generate-done notification alone does not count.

The task keeps the `Radio`, configuration, IE storage, and key table stationary
throughout each receive. Configuration changes and key reservations in TX run
while the MAC IRQ is unmapped. The ISR reserves ACK counters only during RX,
and only for requests `ack_request.prepare` accepts;
`receiving` and event-register snapshots are accessed with interrupts masked.
Atomic `pending_events` and `ack_failed` transfer completions to the task. RX
DMA is not rearmed until the task consumes the frame, and ACK DMA is separate
from task TX DMA. Keep all other interrupt handlers and interrupt-masked
sections shorter than turnaround; the driver cannot meet the deadline if the
application masks interrupts for longer. Do not perform concurrent flash
erases/cache-disabling operations.

Format limits: standard frame types 0–3, explicit counters only (no ASN
nonce/counter suppression), no anonymous secured sources, and explicitly
terminated header-IE lists. Legacy beacon encryption/superframe parsing is not
implemented. Security configuration is optional; legacy unsecured TX/RX/ACK
behavior is retained when it is absent.

Source caveat: the public
[ESP32-C6 TRM v1.2](https://www.espressif.com/sites/default/files/documentation/esp32-c6_technical_reference_manual_en.pdf)
has **no IEEE 802.15.4 MAC chapter or security/ACK register specification**.
Its §§8.2.4.4 and 12.4.2.5 cover the clock/power routing used here; MAC behavior
above is sourced from the pinned IDF driver.

Host tests include the published IEEE 802.15.4-2006 Annex C.2.1 beacon MIC and
C.2.3 command-encryption vectors, as reproduced in OpenThread's
[`test_aes.cpp`](https://github.com/openthread/openthread/blob/main/tests/unit/test_aes.cpp),
plus independent Python cryptography AESCCM/ECB vectors for all seven levels
(partial AD blocks, MIC-only empty message, M=0 CTR), software TX/ACK sealing
including empty ACK payloads, `SEC_EN` cleared at TX_DONE before ACK
validation, wrong keys/tampered MICs, auxiliary headers/truncation, every key
identifier mode, counter exhaustion, replay rejection without state changes on
failed authentication, `ReplayTableFull` for a new sender before its MIC is
checked (a bad MIC gets the same error and commits nothing), a forged
level-4 frame with counter 0xffffffff followed by a valid frame from the same
sender (still accepted), level-4 rejection by
default and opted-in level-4 frames never creating or advancing a slot,
counter 0xffffffff rejected at a MIC level, enhanced-ACK requests refused
before any counter is reserved (each refusal and its error, including a
sequence-suppressed request without a source and a request with no source)
and admitted ones reserving exactly one counter carried by the ACK,
enhanced ACK construction/addressing/IEs/sequence
suppression, complete secured/IE-bearing ACK reception at 1024 µs, a large ACK
requiring an explicitly extended wait, bounded missing enhanced ACKs, unsecured
H2 ACK bytes, ACK size budgets at every level, TX-ACK evidence (RX alone fails),
and legacy RX/ACK tests. Run `zig build test` in this port.

Two-board test: build in `examples/espressif/esp` with
`zig build -Doptimize=ReleaseSmall -Dexample=selftest_ieee802154_sec`, then flash
**the same** `esp32_c6_selftest_ieee802154_sec.bin` image-boot artifact to a
Super Mini ESP32-C6 and a XIAO ESP32-C6. Leave GPIO3/14 unconnected: the image
powers/selects the XIAO ESP32-C6 internal RF switch on both boards. Boot both
within 10 s; channel 25, PAN 0x3254, public test key c0…cf, identifier mode
1/index 1. Discovery uses full extended addresses, and their numeric order
assigns roles (`ROLE coordinator` or `ROLE responder`). No H2 or wiring is
needed. Its context sets `accept_unauthenticated` for the level-4 check.
Eleven PASS/FAIL lines cover delivery/decryption at levels 1–7,
enhanced ACKs (secured when data is secured) with header IEs, legacy unsecured
ACKs, tampered MIC rejection, and replay rejection. The responder's level 1–7,
`enhanced_ack` and `legacy_ack` checks require an ACK actually transmitted
(`Frame.ack_transmitted`, and for enhanced ACKs `Ack.transmitted()`) as well as
the expected received security level; RX_DONE alone cannot pass them. Both
boards emit `SELFTEST ieee802154_sec DONE pass=11 fail=0` on success, within a
45 s deadline after each boot (55 s from the first boot with a 10 s stagger).
Per-stage diagnostics print TX input/DMA bytes, software-derived expected wire
output, raw RX/ACK bytes (including MIC), decrypted data, auxiliary
header/counter/key identifier, MIC verification outcome, event bits, numeric
TX/RX abort reasons, the `ACK-TX transmitted=...` record, and
delivery/response/ACK decisions. Hardware TX DMA is labelled separately: it may
contain the plaintext and reserved MIC rather than the on-air output. No
logging runs in the ISR. Raw snapshots are taken before authentication, so
failed MICs and replay rejection remain inspectable. MIC `not_checked` means an
earlier error prevented verification; level 4 reports `absent`. The
key/counters are test-only and deliberately reset on every boot.

ESP32-H2 interop (enhanced ACK only): an ESP32-H2 running ESP-IDF v5.5.1's
`ieee802154_cli` console can inject version-2 frames with `tx` and prints the
ACK it receives. Its console has no key provisioning or decryption, so this
exercises the unsecured enhanced ACK, not frame security. `tx` takes the MPDU
octets followed by two placeholder FCS octets, which the H2 radio overwrites.
On the H2, run `channel -s 25`, then:

1. Boot one C6. Send discovery from a synthetic lower extended address
   `0100000000000000`: MPDU `41d8005432ffff01000000000000004d5a53434800`, four
   times about 0.7 s apart. The C6 prints `ROLE responder local=<C6>`; use that
   extended wire address as `<C6>` below.
2. Send the control MPDU `41dc005432<C6>01000000000000004d5a53434307`; this
   selects the `enhanced_ack` check.
3. Run `promisc -d` on the H2 before the ACK-requested frame. IDF
   `esp_ieee802154_set_promiscuous` disables RX auto-ACK while promiscuous, and
   `dev.c:isr_handle_tx_done` then skips the ACK wait, so a promiscuous H2
   never reports the ACK. Leave the ACK timeout at its default 108 symbols.
   Send `21ec015432<C6>01000000000000004d5a53434407`. The H2 prints
   `Rx ack 10 bytes`: FCF version 2, sequence 1, no addresses, and the
   configured header IE/HT2 (`022201010fee803f`, plus FCS), with no
   `Failure reason: 3`. The C6 prints `ACK-TX transmitted=true` with
   `finish_events` containing ACK_TX_DONE (bit 2), then `enhanced_ack: PASS`.
   The remaining self-test checks are not exercised by this run and report FAIL.

Evidence: on hardware, image boot, `selftest_ieee802154_sec` passed 11/11 on
both the Super Mini ESP32-C6 and the XIAO ESP32-C6 in 3 runs booted together
and 2 runs with boots staggered by 8 s (each board booting first once). With
the procedure above, an ESP32-H2 (ESP-IDF v5.5.1) received the C6's version-2
enhanced ACK (`Rx ack 10 bytes`).

`selftest_ieee802154` builds the C6 image-boot target and the XIAO ESP32-C6 board
target; on a XIAO ESP32-C6 use the board build, which powers the rf switch (about 20 dB);
`-Dantenna=external` selects the U.FL connector (default `internal`). The board's
`antenna.apply` moved the rf switch in a `xiao_esp32_c6_ble_scan` run (see the BLE
evidence). The self-test transmits at +20 dBm to match the H2 peer; at 0 dBm the C6's
auto-ACKs reach that peer about 20 dB below its own frames.
The self-test derives its short address from the factory MAC's final
two bytes, `(mac[4] << 8) | mac[5]`. Values 0x0001 (test peer), 0x0003 (nRF
default), 0xfffe and 0xffff are remapped by XOR with 0x8000. Its extended
address inserts ff:fe between MAC bytes 2 and 3, then reverses the eight bytes
into the HAL's wire order. The boot line `ADDRESS channel=25 pan=0x1234
short=0xHHHH extended_wire=<16 hex digits>` announces the configured addresses.
Before testing two C6s together, the host must verify their printed shorts
differ; 16-bit truncation cannot guarantee uniqueness. If equal, do not run
them together. Peer MPDUs address the printed short, low byte first (bytes 5/6
in a PAN-compressed short-address frame).

Configure exactly one ACK peer on channel 25 / PAN 0x1234, filtered RX with
auto-ACK, short 0x0001, before resetting the C6. When using nRF instead of H2,
disable H2 RX and set `wpan filter 0x1234 0x0001`, `wpan promisc off`, and
`wpan rx on` (its boot default is short 0x0003 and promiscuous RX).
The test first checks energy-detect
completion and a broadcast TX without ACK or CCA (no peer or quiet channel
required). It then listens promiscuously for five seconds and prints each
received frame as `FRAME len=.. lqi=.. rssi=.. <hex>` (MAC bytes without FCS).
Next it sends fixed data frames with/without ACK request to 0x0001, including
CCA, plus a broadcast, printing `TX_DONE`, `ACK_RECEIVED`, `NO_ACK` or `CCA_BUSY`.
It then receives with filtering/legacy auto-ACK enabled; send peer ACK-request
frames to the printed C6 address after its outgoing set finishes.
Radio-only case lines appear after 1.5 s. `DONE` is withheld until the outgoing
set finishes (or a fatal setup failure). The fourth case, `peer_ack`, requires
**2/2 ACK_REQUEST frames acknowledged**, seq 0x21 and 0x22 both using default
unslotted CSMA-CA and ACK retries. Final NO_ACK, CCA_BUSY or TX error on either fails that case;
missing peers fail it too. Success is `SELFTEST ieee802154 DONE pass=4 fail=0`.
Reports repeat every three seconds with peer RX/CRC/ACK/CCA/error counters.
The test reports only between 500 ms receive windows, so
a report can slip by up to 0.5 s and the interval between reports is 3 to 3.5 s.
The last promiscuous window may start just before the five seconds end, so the
promiscuous phase can overrun by up to 0.5 s.

### Wi-Fi station and RTOS

See the [ESP Wi-Fi handle design](../../../docs/design/esp-wifi-handle.md)
for ownership, lifecycle and callback routing.

The optional TX-done callback ran on hardware through `selftest_wifi_tx_done` (below):
10 of 10 callbacks, `DONE pass=3 fail=0` in 3 of 3 boots each on the C3, the Super Mini ESP32-C6 and
the XIAO ESP32-C6 (board build), 2026-11-20. It is also cross-compiled in `compile_wifi`
for C3/C6.

On the XIAO ESP32-C6, use the `xiao_esp32_c6_*.bin` image-boot builds for
`tcp_server`, `selftest_wifi_lifecycle`, `softap`, `selftest_wifi_tx_done`,
`selftest_wifi_open_ap`, `selftest_wifi_softap_echo` and `compile_wifi`.
`-Dexample=tcp_server`, for example, produces
`zig-out/firmware/xiao_esp32_c6_tcp_server.bin` alongside the generic images.
These builds reuse the board's `antenna.apply` RF-switch setup used by BLE and
802.15.4: `-Dantenna=internal` (default) or `-Dantenna=external` for U.FL
(Seeed Studio XIAO ESP32C6 Getting Started, “Hardware overview” and “Pin Map”;
see the references in `src/boards/xiao_esp32_c6.zig`).
Station `wifi_ssid`/`wifi_password`/`wifi_auth` and SoftAP
`softap_ssid`/`softap_password` options apply to the board builds too.
The generic `esp32_c6_*.bin` builds do not configure the XIAO ESP32-C6 RF switch: at one placement
the XIAO ESP32-C6 received the AP at -43/-44 dBm with the generic `tcp_server` and -21/-22 dBm with
the board build. `compile_wifi` covers compilation only and does not initialize the radio.

C6 `tcp_server` is built for the image-boot target. Set station credentials at build time
with `-Dwifi_ssid='bench-ap' -Dwifi_password='example-passphrase'`; these options also apply to
`selftest_wifi_lifecycle`. For example, from `examples/espressif/esp`:

```sh
zig build -Doptimize=ReleaseSmall -Dexample=tcp_server -Dwifi_ssid='bench-ap' -Dwifi_password='example-passphrase'
zig build -Doptimize=ReleaseSmall -Dexample=selftest_wifi_lifecycle -Dwifi_ssid='bench-ap' -Dwifi_password='example-passphrase'
```

Defaults remain SSID `SSID` and an empty password. `-Dwifi_auth` sets the weakest AP
authentication the station accepts, as a `hal.radio.wifi.AuthMethod` name; it defaults to
`wpa2_personal` when a passphrase is given and `none` without one, so a station with a
passphrase is configured to reject an open AP of the same name. `wpa3_personal` is a build
error, as the port has no WPA3 (see "Wi-Fi initialization and limits"). This authentication
policy has build-rejection logs for an invalid auth name and a missing passphrase, and
its runtime check ran on hardware: `selftest_wifi_open_ap` (below) passed 3/3 in 3 of 3
boots each on the C3, Super Mini ESP32-C6 and XIAO ESP32-C6 (board build), 2026-11-20. A non-`none` value without a
passphrase is a build error. Credentials are embedded in the firmware; the examples do not
log them. The scan logs neighbouring APs' SSIDs, which they broadcast. `-D` values are
also kept in the shell's history and in the build cache (`.zig-cache`), so use a test
network's credentials or clear both. The standalone SoftAP example is described below.
For other build options, see "SoftAP (C3 and C6)", "BLE bench examples"
and "Boards and hardware validation".
The `rtos` demo reports five ordered-delivery cases plus an empty-queue timeout case
after joining the producer (`SELFTEST rtos DONE pass=6 fail=0`). It passed 6/6 from RAM
on the C3, Super Mini ESP32-C6 and XIAO ESP32-C6, 3 runs each, at 24ebc5d1 (2026-11-19).

`systimer` observes four interrupts in at most five seconds of TIMG0 time (six of
TIMG1 time), then checks their three consecutive intervals against TIMG0's 1 MHz
counter (80 MHz APB on C3, PLL_F80M on C6, divider 80). Both counters derive from the
one 40 MHz crystal, so each interval must be 1 s +/-100 us: the margin covers timestamp
latency (measured 999,997 to 1,000,002 us) and still fails a wrong ticks-per-us value
(at least 6.25% off). An additional half-period observation rejects extra interrupts.
The first alarm's phase is not scored. The ISR only clears the alarm and increments a
volatile scalar counter; main captures timestamps with interrupts masked,
without logging during observation. The alarm clear is forced inline so the RAM ISR
avoids the C3's flash-resident atomic helpers. The six-second TIMG1 deadline and ROM report delays avoid
using the clock under test: a stopped systimer or TIMG0 produces FAIL lines within
7.5 seconds plus bounded TIMG read and reporting overhead, provided TIMG1 and the CPU run.
All demo logging, including observation errors, uses a local USB FIFO reporter with
one shared budget of 1,000,000 full-FIFO polls per line, including final-packet
consumption. It never calls the systimer-based logger or reads `hal.time`. A stalled
host may lose or truncate output; the saved PASS/FAIL lines repeat after the host
resumes, starting with a newline to separate any previous fragment. The poll budget
bounds CPU work, not guaranteed delivery to an absent or stalled host. See C3
TRM v1.4 sections 10.3, 11.2.1 and C6 TRM v1.2 sections 13.3, 13.5.3, 14.3.1.
`Unit.read` follows ESP-IDF v5.5.1 `components/hal/systimer_hal.c`
(`systimer_hal_get_counter_value`) and both chips' `systimer_ll.h`: request a
snapshot, poll `VALUE_VALID` without a software timeout, then retry LO/HI/LO if
an interrupt took another snapshot. Callers must keep the unit active, its clocks
enabled and reset released. C3 TRM v1.4 §10.4.1 and C6 TRM v1.2 §13.4.1 specify
that UPDATE latches the value and asserts VALID; §§10.5.1/13.5.1 prescribe polling
it. This handshake does not depend on elapsed counter ticks or an external event.
The TRMs give no numeric completion bound; this follows IDF's active-clock contract,
not a fault-recovery guarantee if SYSTIMER is unclocked or reset during a read.

`custom_clock_config` decodes the XTAL source and CPU/APB divider registers,
including C6's root/AHB/APB dividers and disabled automatic APB reduction
(C3 TRM v1.4 section 6.2; C6 TRM v1.2 section 8.2.4.1). Both frequencies must
match the configured 20 MHz. Its CPU-calibrated ROM busy delay requests 100 ms
and must measure 100 ms +/-100 us against systimer: CPU and systimer share the
crystal, call overhead measured 4 to 5 us, and a calibration one tick per us off
is 5% off. These are peripheral clock-ratio checks, not absolute oscillator
calibration. From RAM on the C3, Super Mini ESP32-C6 and XIAO ESP32-C6, 3 runs each, 2026-11-20,
`systimer` passed 4/4 and `custom_clock_config` passed 3/3 in every run. All three
demos repeat the saved case results and DONE line for late host attachment.
C3 Wi-Fi examples remain in the build.
`selftest_wifi_lifecycle` shares `tcp_server.zig`'s build-time station credentials and
TCP echo server. With the test hotspot present it starts, connects, waits through a PLL
tracking period, stops, starts and connects again, then switches the running STA to AP_STA
and waits for AP start and STA connectivity. C6 additionally checks MAC/APB/BB/FE clocks
remain enabled after stop. It logs `SELFTEST wifi_lifecycle <case>: PASS|FAIL` and
`SELFTEST wifi_lifecycle DONE pass=N fail=M` (success repeated every 3 s; failure
repeated every second from the main task, since USB output before the host
reopens the port is lost); DHCP is the seventh case and TCP bind/listen on
port 3333 is the eighth. State and DHCP waits time out after 30 seconds. The AP is
open with SSID `microzig-lifecycle`; the example has no AP network interface or DHCP server.
This self-test is built for C3 and C6 image boot (also C3 direct boot).

Evidence, image boot, as a station on a Pico 2 W MicroPython AP (WPA2, channel 6, CYW43
DHCP server); `tcp_server` counts the AP's first TCP connection after each boot echoing
10/10 lines on port 3333:
- C3, 24ebc5d1: `tcp_server` 6 of 6 boots, each started once the Pico listed no station
  (`stations=0`); `selftest_wifi_lifecycle` `DONE pass=8 fail=0` in 3 of 3 boots.
- Super Mini ESP32-C6, 24ebc5d1: `tcp_server` 3 of 3 boots; `selftest_wifi_lifecycle` 8/8 in 3 of 3
  boots.
- XIAO ESP32-C6 board build, 2026-11-20: `tcp_server` 3 of 3 boots;
  `selftest_wifi_lifecycle` 8/8 in 3 of 3 boots.
- With the status-error and `semphr_take` fixes, 2026-11-24, ReleaseSmall: `tcp_server`
  1 of 1 boot each on the C3, the Super Mini ESP32-C6 and the XIAO ESP32-C6 (board
  build), each started once the Pico listed `stations=0`.

A watchdog reset sends no deauthentication, so the AP keeps the old association: a station
booted again at once leases and listens, but its TCP connections time out until the AP
drops that association (2 to 58 s with the Pico).

On the C3, a diagnostic build without static RX management buffers (`rx_mgmt_buf_type`,
the IDF default) failed the first TCP connection in 8 of 8 boots: its ARP requests got no
802.11 ACK from about 20 s after boot and Wi-Fi TX later returned `WifiOther` (which then
covered every listed Wi-Fi code without its own error). A diagnostic build with static RX
management buffers passed 4 of 5 boots.

#### Wi-Fi self-tests (C3 and C6)

These image-boot self-tests print `SELFTEST <suite> <case>: PASS|FAIL` and repeat
`SELFTEST <suite> DONE pass=N fail=M` every three seconds after completion.
Hardware runs, 2026-11-19/20 (the AP for `wifi_tx_done` and `wifi_open_ap` is
the Pico 2 W above):

- `wifi_tx_done`: `pass=3 fail=0` with `sent=10 callbacks=10` in 3 of 3 boots each on
  the C3, the Super Mini ESP32-C6 and the XIAO ESP32-C6 (board build), each boot started once the Pico listed
  `stations=0`. Again with the status-error and `semphr_take` fixes (2026-11-24,
  ReleaseSmall): `pass=3 fail=0` with `sent=10 callbacks=10 failed=0` in 1 of 1 boot on
  each of the three boards.
- `wifi_open_ap` against an open Pico AP: `pass=3 fail=0` in 3 of 3 boots each on the
  C3, Super Mini ESP32-C6 and XIAO ESP32-C6 (board build); again with the status-error
  and `semphr_take` fixes (2026-11-24, ReleaseSmall) in 1 of 1 boot on each of the three
  boards.
- `wifi_softap_echo`: `pass=13 fail=0`, with the station's lease and `echoed=2570` in the
  AP's log, in 3 of 3 boots for each pairing: C3 AP with Super Mini ESP32-C6 or XIAO ESP32-C6 (generic image)
  station, Super Mini ESP32-C6 or XIAO ESP32-C6 (generic image) AP with C3 station, XIAO ESP32-C6 board-build AP with
  Super Mini ESP32-C6 station, and Super Mini ESP32-C6 AP with XIAO ESP32-C6 board-build station. Boards not taking
  part were stopped before each boot.
- `wifi_modes` (2026-11-24): `pass=11 fail=0` in 1 of 1 boot on each of the C3,
  the Super Mini ESP32-C6 and the XIAO ESP32-C6 (board build), in ReleaseSafe and in
  ReleaseSmall. In all six boots `set_protocol` in the null mode and `disconnect` and
  `connect` in the null and AP-only modes returned `error.WifiMode`, `get_mode` returned
  `.none` after `init`, and `WifiNotInitialized` after `deinit`. Before the fixes,
  ReleaseSafe builds panicked with `invalid enum value` at `get_mode` after `init`; with
  that case and `set_protocol` skipped, `disconnect` without a station returned success,
  and with only the `semphr_take` fix it panicked with `esp wifi returned unexpected error
  code`.

| Image / suite | Expected result | Peer setup and checks |
| --- | --- | --- |
| `selftest_wifi_tx_done` / `wifi_tx_done` | `pass=3 fail=0` | AP matching `-Dwifi_ssid`, `-Dwifi_password`, `-Dwifi_auth`; start, join, TX-done. No DHCP or PC needed. Sends ten 60-byte broadcast Ethernet frames with experimental EtherType 0x88b5 and unique sequence tags. Requires a successful callback for every queued frame, found by its tag inside the 802.11 frame the callback returns (not the Ethernet frame sent); prints sent, distinct callback and failed-status counts. Duplicate callbacks cannot cover a missing frame. |
| `selftest_wifi_open_ap` / `wifi_open_ap` | `pass=3 fail=0` | Open AP matching `-Dwifi_ssid`, with no protected AP of that SSID in range. Build the station with `-Dwifi_auth=wpa2_personal` and a dummy test `-Dwifi_password` of at least eight bytes. Checks start, scan presence, rejection. Requires an incompatible-security/auth-threshold disconnect (IDF reasons 210/211), no association throughout 30 seconds, and 210/211 still the last reason at the end. Missing AP, other disconnect reasons, or unprotected station configuration fail. |
| `selftest_wifi_modes` / `wifi_modes` | `pass=11 fail=0` | No peer. Checks `get_mode` is `.none` after `init`, `set_protocol` in that mode, and `disconnect` and `connect` without a station (null mode, then a hidden demo AP), return `error.WifiMode`, `start` works with no interface, `stop`, and that `deinit` leaves Wi-Fi uninitialized. |
| `selftest_wifi_softap_echo` / `wifi_softap_echo` | `pass=13 fail=0` | Run `softap` on the other chip first; matching `-Dsoftap_ssid` and `-Dsoftap_password` on both builds (demo defaults work). Checks start, join, DHCP, then ten 257-byte binary payload echoes at `192.168.4.1:7`. Handles partial writes and split/chained receives; checks lengths and every byte. No PC joined to the AP needed. |

Build from `examples/espressif/esp` using the pinned Zig. These commands use only
demonstration credentials:

```sh
zig build -Doptimize=ReleaseSmall -Dexample=selftest_wifi_tx_done \
  -Dwifi_ssid=bench-ap -Dwifi_password=example-passphrase
zig build -Doptimize=ReleaseSmall -Dexample=selftest_wifi_open_ap \
  -Dwifi_ssid=bench-open -Dwifi_password=example-passphrase -Dwifi_auth=wpa2_personal
zig build -Doptimize=ReleaseSmall -Dexample=softap
zig build -Doptimize=ReleaseSmall -Dexample=selftest_wifi_softap_echo
zig build -Doptimize=ReleaseSmall -Dexample=selftest_wifi_modes
```

Outputs are `esp32_c3_<image>` and `esp32_c6_<image>` under
`zig-out/firmware`, as `.bin` and `.elf`. For the echo test, flash the C6 `softap` image
and C3 `selftest_wifi_softap_echo` image, then swap roles and repeat with C3
as AP and C6 as station. Only one echo client should connect at a time.
Start the AP before resetting the station. The TCP connect is covered by the first
echo case. Station state, DHCP, each TX callback, TCP connect and each complete
write/echo exchange have 30-second deadlines. TCP uses nonblocking lwIP calls;
there are no retries that turn a failed test into a pass. Reset to run again.
Credentials use the existing build options and are embedded but never logged by
these self-tests. The open-AP test's dummy station password is never an AP credential.

#### SoftAP (C3 and C6)

`softap` is a standalone WPA2-PSK/CCMP AP on channel 6, limited to four associated
stations. It uses only WPA2 Personal; open, WEP, WPA/WPA2 mixed and enterprise modes are
not offered by this example, and WPA3 is not offered by the port (see "Wi-Fi initialization
and limits"). STA and `tcp_server` are unchanged.
Build from `examples/espressif/esp` with the pinned Zig:

```sh
zig build -Dexample=softap -Doptimize=ReleaseSmall \
  -Dsoftap_ssid=microzig-softap -Dsoftap_password=microzig-demo
zig build test # host-side DHCP packet tests
```

SSID and passphrase default to `microzig-softap` and `microzig-demo`. SSIDs must be
1–32 bytes; passphrases must be 8–63 printable ASCII bytes. The passphrase is embedded
in firmware and is not logged. Outputs are `esp32_c3_softap` and `esp32_c6_softap`
(image boot only, `.bin` and `.elf`, under `zig-out/firmware`); flash with the same
image-boot setup as `tcp_server`.

The AP is `192.168.4.1/24`. The vendored lwIP build has a DHCP **client**, not a
server, so the example runs the shared `modules/dhcp-server` module
([design](../../../docs/design/dhcp-server.md)) on lwIP raw UDP on the AP netif. The
AP admits four stations and has eight MAC-keyed leases, `192.168.4.2`–`192.168.4.9`,
which last one hour and advertise the AP as gateway. Offers reserve a slot for 30
seconds; renew/rebind, INIT-REBOOT, release and decline are supported (declined
addresses are quarantined for one hour). A lease ends only by its holder's own message
or by expiry: a station that leaves without releasing keeps its address for the rest of
the hour, and gets it back if it returns. If each station uses one MAC, the spare leases
let new stations join while departed clients' leases, offers they left before taking up
(30 seconds each) and declined addresses together hold up to four entries; past that, a new
station gets no offer until the earliest of them expires. A station that changes its MAC
on each join takes a new lease each time. The station count comes from the blob. Leases
are volatile across reboot, and the server does not probe an address before offering it,
so after an AP reboot an address a station still uses can be offered to another until
that station renews. Ethernet clients only: no relays, option overload, DHCPINFORM, DNS
service, routing/NAT or Internet access.

A station should join, acquire a lease, ping `192.168.4.1`, and connect to
`192.168.4.1:7` for TCP echo. Echo serves one connection at a time; an idle client
holds that slot until disconnect. `SOFTAP up ssid=... ip=192.168.4.1` announces
readiness (`stations=unknown`, after a `SOFTAP warning:` line, if the blob does not
answer), join/leave lines include MAC and AID (a leave also its reason), DHCP ACK lines
include MAC and leased IP, and each closed TCP connection reports bytes echoed. A reporter
first runs after 1.5 seconds and repeats status every three seconds so late USB
reattachment can see it.
Join/leave, lease and connection events themselves are not replayed.

Evidence: DHCP packet logic and the station count check are host unit-tested. A hardware
run of the shared DHCP module and the blob station count is pending; the run below
predates them and used the earlier example-local DHCP server. On hardware, image boot,
24ebc5d1 (2026-11-19/20), with an ESP32-S3 station using ESP-IDF v6.0.2 `esp_wifi` and
the lwIP DHCP client: with the C3, the Super Mini ESP32-C6 and the XIAO ESP32-C6 (generic image) as AP, the S3
associated (WPA2-PSK, channel 6), leased 192.168.4.2 and got 5/5 gateway pings and 10/10
pings in 3 of 3 boots each. TCP echo on port 7 ran through `selftest_wifi_softap_echo` above,
including the XIAO ESP32-C6 board build as AP.

#### Wi-Fi initialization and limits

There is no WPA3. The C3 and C6 `libwpa_supplicant.a` linked from `esp-wifi-sys` were built without
SAE (their `sae.c` and `esp_wpa3.c` objects are present but define no symbols, nothing defines a
`crypto_ec_*` function, and `esp_supplicant_init` registers no WPA3 callbacks), so the port does not
set `WIFI_ENABLE_WPA3_SAE` in the `feature_caps` it passes to `esp_wifi_init_internal`. An access
point with `wpa3_personal` or `wpa2_wpa3_personal` authentication, or a station threshold of
`wpa3_personal`, is `error.InvalidConfig`. A station threshold of `wpa2_wpa3_personal` is accepted,
since such an access point also offers WPA2. WPA3 needs a supplicant built with SAE and an
elliptic-curve crypto backend.

Only `.none` power save is supported on C6; modem/light sleep retention is not implemented.
Wi-Fi initialization returns `CpuClockNotPll` unless the hardware CPU source is PLL
(C6 TRM v1.2 §8.2.4.4), including when a custom HAL initialization selects clocks. Radio initialization restores MODEM_APB
access after `system.init` and configures the modem clock maps in the existing analog module.
Both PHYs keep the USB PLL enabled during calibration, calibrate fully once per boot/reset,
and use a task mutex and reference count for calibration/wakeup and final RF close. Calibration
allows interrupts, matching IDF's PHY access lock. Both run PLL tracking every second and on
enable when a tracking period elapsed. The pinned `esp-wifi-sys` C3/C6 blobs do not
export `phy_wait_freq_hw_hop_done`, so the IDF v6.0.2 hop-wait call is unavailable.
Every enable/disable updates the blob's Wi-Fi enabled flag, including an unbalanced disable,
which is tolerated. Calibration data is not stored in NVS.
C6 clocks follow IDF v6.0.2 reference/inited semantics: MAC/APB/BB/44M stay enabled while
Wi-Fi is initialized, including stop and STA-to-AP_STA changes; coexistence follows references.
Calibration temporarily owns APB/BB/44M clocks too. FE clocks are never disabled. The analog
I2C clock retains the SAR helpers' ownership after `analog.enable()`, so a later PHY stop
does not require re-enabling analog helpers. Concurrent PHY/SAR register access is unsupported.
C6 radio initialization measures its RC_SLOW source against XTAL using TIMG0 calibration
(C6 TRM v1.2 §14.3.6, registers 14.18–14.20), writes the resulting Q19 period to STORE1 and
keeps its own copy for Wi-Fi. It never trusts a retained value from another application;
calibration timeout returns `SlowClockCalibrationTimeout`. These lifecycle changes ran in the
Wi-Fi runs above.
C6 startup follows ESP-IDF v6.0.2 `bootloader_init_mem`: it disables the HP_APM,
LP_APM0 and LP_APM access-path filters and puts all implemented HP masters and the
LP CPU in TEE mode (C6 TRM v1.2 §§16.3.1, 16.3.2.3, 16.4). This covers Wi-Fi M4
and SPI/GDMA M16; drivers no longer change their modes. Region permissions stay
unchanged. Modem ICG maps follow IDF v6.0.2 `initial_gating_mode`, with BT and
IEEE802154 enabled in ACTIVE only. These startup changes ran in the C6 runs described above.
The Wi-Fi blobs take `vsnprintf` from
libprintf.a: the ROM's printf and stdio functions need a newlib syscall table that MicroZig does
not install. C6 links the unmodified IDF v6.0.2 `rom.libc` and
`rom.libc-suboptimal_for_misaligned_mem` scripts, excluding `rom.newlib` and
`rom.newlib-normal`. C3 maps only memory/string primitives and `abs` from libc,
with no reent-dependent libc bindings. The OS adapter uses an ASCII
comparison for `strcasecmp`. This linker split is in every Wi-Fi image of the
runs above.
The C6 radio ROM bindings follow ESP-IDF v6.0.2, including its disabled node-search
bindings so the matching blob supplies them. Both chips use the IDF 64-bit seconds
layout for the supplicant clock. The C3 and C6 Wi-Fi images with these bindings and this
layout ran in the Wi-Fi runs above.
Do not use the SAR analog helpers concurrently with the radio PHY.

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
`wait_for_host` keep their wait, not which rule kept it (the four cases above separate the two).

The s6 self-test lets the host speak first: after each re-enumeration the host reopens the
port and sends `USJ?` 1.5 s later; the device then sends `USJ nonce=<8 hex digits>` (again each
second until consumed) and passes `cdc_in` only when the host answers `ACK <same digits>`.

`selftest_sleep_s1` to `selftest_sleep_s6` stage the C3 sleep checks (`selftest_sleep` is s4); the
file header documents each stage and the result screen on the 0.42-inch SSD1306 panel (GPIO5 SDA,
GPIO6 SCL): stage, step or the first failed check, `CODE=`, pass/fail counts and an inverted
final PASS/FAIL. The counts include a latched `display` check. Build with
`-Dsleep_report=beacon` for the original analyser protocol on those same pins; the two reporters
are mutually exclusive. HAL trace codes are replayed after sleep and timing samples, because the
callback may not wait on sleep-affected peripherals, so the OLED cannot show where a sleep
halted; the beacon can. In s3 and s4 `cdc_in` is a note, not a check: `allow_usb_loss` leaves
the endpoints dead after wake by design, and the screen shows `DONE USBLOST` instead of `DONE`.
s2 runs as a direct-boot image from flash with USB attached and does not force download boot:
after the RTC watchdog core reset the same image boots again and passes `rwdt_recovery` only
for reset cause 0x9 with its journal pending. Keep USB pads attached: C3 retains its USB
connection through RWDT core reset. C3 TRM v1.4 §30.3.4 states that USJ is not
affected by SRST. s2 clears `RTC_CNTL.OPTION1.FORCE_DOWNLOAD_BOOT` itself before arming, including
state left by older RAM-load images (`OPTION1` 0x600080F4). The reset cause is
read from `RTC_CNTL_RESET_STATE_REG` 0x60008038 (C3 TRM v1.4 Register 9.12).

Results on the C3 rev v0.4, 2026-11-20, OLED reporter, one run each:

- s1: `DONE pass=4 fail=0` including `display`; the panel read `S1 SLEEP`, `DONE`, `CODE=63`,
  `P=4 F=0`, `PASS`. An earlier beacon build passed s1 in 3 of 3 runs.
- s2: `rwdt_recovery PASS reset_cause=0x9`, `DONE pass=2 fail=0`.
- s3: the panel read `DONE USBLOST`, `CODE=63`, `P=9 F=0`, `PASS`.
- s4: the panel read `DONE USBLOST`, `P=12 F=0`, `PASS`.
- s5: 5/5 (`detach_attach`, `host_sof`, `cdc_in`, `cdc_out`, `display`) in all 36 repeated
  reports.
- s6 (beacon reporter build, results read over USB): 12/12 with a Windows host
  (`wait_for_host` with the test's `Attachment`, then reconnect without sleep and a 100 ms
  and a 500 ms sleep, each checked for a bus reset, the nonce echoed back and the OUT string),
  `wait_for_host` true after 3 us.

### C6 light sleep and deep sleep

`hal.clocks.sleep` selects the C6 PMU implementation; the C3 code is unchanged.
The reference is **ESP-IDF v5.5.1**, matching the radio blobs. `pmu_c6.zig` cites the
source file/line for each table group and the TRM v1.2 ch. 12 section documenting its fields.
The v6.0.2 checkout serves only as a comparison (its optional PVT startup is not imported).

The first validated sleep request initializes all HP ACTIVE/MODEM/SLEEP and LP ACTIVE/SLEEP
state tables, hands regulator control to PMU through analog `ENIF_*`, then releases the domain
forces in IDF order. HP memory forced power-up and power masks are preserved: only memory
no-isolate is cleared (`pmu_init.c:135–167`). Active HP/LP bias follows the eFuse encoding version,
nonzero code + 2 saturated at 31, otherwise 25/26 (`pmu_param.c:418–466`). Power-on o-code setup
also follows IDF; parts without a burned code use bounded calibration. PMU initialization persists
across calls; applications and LP firmware must not overwrite these tables afterwards.

`enter_light_sleep(Config)` retains CPU context, HP SRAM and TOP/peripherals. No peripheral
retention DMA is available, so TOP/CPU/HP AON power-down flags are clear. The modem domain is
powered down; Wi-Fi and BT must be off. CPU switches to undivided XTAL before programming sleep,
and the previous source/dividers and ROM frequency bookkeeping are restored afterwards, including
rejection/timeout paths (`sleep_modes.c:1011–1014,1154–1162`, `rtc_clk.c:174–180,252–270`).
HP_SLEEP analog I2C uses isolation/retention **1/1**, with BBPLL and its I2C powered down.
Wake-up recalibrates the 480 MHz PLL from the 40 MHz XTAL before returning CPU to PLL.
Default light sleep keeps flash supply, LP peripherals, HP memory, LP oscillators and XTAL.
`power_down_xtal = true` selects the IDF XTAL-off light profile: RC_FAST stays on in HP_SLEEP,
then powers down in LP_SLEEP unless `lp_core` wake needs it. Unselected 32 kHz oscillators are
powered down too; LP peripheral power is retained for light-sleep users. Deep sleep powers down
XTAL, VDD_SPI, LP peripherals and unused RC_FAST/XTAL32K/RC32K by default, matching IDF v5.5.1
`sleep_modes.c:1262–1265,2573–2628`. LP SRAM remains retained. `lp_core` wake keeps RC_FAST and LP
peripherals; the selected LP slow oscillator is always kept (TRM §§12.4.2.3–7).
Both deep sleep and XTAL-off light sleep return `UnsupportedClock` before regulator handoff or
USB detachment if `LP_CLKRST.FAST_CLK_SEL` selects XTAL_D2. Change LP_FAST only with LP clients
quiescent; the sleep HAL never silently changes their clock source.

PMU waits are computed using measured Q13.19 slow/RC_FAST periods and IDF's 450 us minimum sleep,
154 us analog wait (LP deep: 500 us), 2 us digital supply/up waits, 250 us XTAL and 50 us PLL waits.
XTAL stabilization uses slow-clock cycles when XTAL is kept and fast-clock cycles when it is powered down (`pmu_sleep.c:209–212`); the reference periods give 37 versus 5000 cycles.
TIMG0 RTC calibration is exclusively owned during the call; temporary clock gates are restored.
The unused modem-wakeup wait is derived from IDF's hardware wait and software adjustment;
there is no modem wake source or RTOS software-overhead compensation. The relative timer target
is anchored to the API-entry LP-timer snapshot and armed after setup; requested raw ticks are
not reduced by an estimated wall-clock preparation overhead. The final request/poll/eFuse-IDLE
wait runs in RAM; light sleep suspends and resumes cache, while deep sleep leaves cache enabled.
IDLE is controller state **1**, including after rejection (`pmu_sleep.c:359–392`).

Applications must quiesce DMA and peripherals first. The HAL flushes UART output before deep
sleep, suspends UART transmission for light sleep and resumes it after clock restoration. It
releases SAR ADC PWDET power ownership during sleep and restores it afterwards. C6 MSPI timing
synchronization is a no-op in IDF (`clk_utils.c`, `FLASH_CPU_CLK_SRC_BINDED` is S3-only); no
peripheral retention or ADC monitor profile is installed. Interrupts remain masked through restoration.
SYSTIMER time is not compensated; `rtc_ticks()` counts LP_SLOW_CLK ticks through sleep (§12.4.3).
Calibrate that clock before converting ticks to a duration. Internal I2C writes use the ROM form
without read-back of self-clearing/write-only bits. A genuine PLL calibration timeout restores
the divider fields, keeps CPU on XTAL, updates ROM frequency bookkeeping and returns an error.
The modem clock maps are opened temporarily for analog transactions and then restored; permanent
clock-init map changes were avoided to keep Wi-Fi behavior identical.

Wake sources (TRM Table 12.4-1, with the EXT1 omission below):

- `timer_ticks`: HP wake target 0 of LP_TIMER; the LP firmware's target 1 is left available.
- `gpio = .{ .pin = 0..7, .level = 0..1 }`, or `ext1 = .{ .pins, .levels }`: any selected LP
  GPIO at its configured level. Use `hal.lp_io.apply` to configure the LP mux, input and pull
  before sleeping (§7.7). TRM v1.2 omits EXT1 from Table 12.4-1 and the LP_AON EXT1 field
  descriptions; the selector/levels and source bit 1 follow IDF v5.5.1
  `lp_aon_ll_ext1_set_wakeup_pins` and C6 `pmu_bit_defs.h`. Bit 2 is the separate HP GPIO
  source, not EXT1. The HAL validates LP mux ownership and rejects pre-held selected pads:
  a hold prevents its input setup from reaching the pad (§7.9), and sleep entry must not
  silently release an application-owned hold. It enables the independent LP IO clock and
  selects the LP GPIO input path, preserving pulls. The gate is a control bit, not a
  readiness flag; IDF `rtc_io_ll.h:59–65` polls that same writable bit. The HAL
  enables it without a readiness poll (TRM §8.2.4 defines no LP IO readiness condition).
  When deep sleep powers down LP peripherals, it holds the selected EXT1 pads through
  `LP_AON.GPIO_HOLD0` (TRM §§7.7,7.9; IDF v5.5.1 `sleep_modes.c:2037–2081`,
  `hal/esp32c6/include/hal/rtc_io_ll.h:59–65,79–87,136–139,271–285`).
  Light sleep and deep sleep with `lp_core` retain LP peripheral power and need no new hold.
  Return/error paths restore pad configuration, release sleep holds and restore the clock gate
  and previous EXT1 selection. Default C6 HAL `init_sequence` calls
  `hal.clocks.sleep.release_ext1_holds_at_startup()` alongside USB recovery, before RTOS or
  application pad users. It disables EXT1 selection before releasing only the selected
  holds, preserving latched wake status and other pads' holds. IDF v5.5.1
  `cpu_start.c:773–777` calls `sleep_gpio.c:188–201` for deep-sleep resets only; the HAL
  also cleans up after an interrupted sleep preparation. CPU and Core resets preserve
  LP_AON, whereas System and Chip resets reset the LP system (TRM v1.2 §8.1.3,
  Table 8.1-1; GPIO_HOLD0 register 12.60). Cleanup therefore runs regardless of reset cause.
  Set `microzig_options.hal.release_ext1_holds_at_startup = false` to manage these
  retained pads manually, and call the helper before reconfiguring them when release is
  wanted. `wake_cause()` only reads cause/status; it does not release holds.
  An already asserted
  source can return `Rejected`; no edge is required. HP-only GPIO wake is not implemented.
- Light sleep: `uart0`/`uart1` enable the UART edge wake detector. Configure that UART's
  `SLEEP_CONF2.WK_MODE_SEL=0` and `ACTIVE_THRESHOLD` before entry; threshold+3 rising edges wake
  the CPU (§27.4.8). Trigger bytes are lost. Other UART wake modes are refused. Transmit in active
  mode or reset that UART after wake to clear its wake signal before sleeping again (§27.4.8).
- `lp_core`: LP firmware triggers `PMU.HP_LP_CPU_COMM.LP_TRIGGER_HP` (§3.9.3). A pending LP
  request is preserved and may reject entry; the caller acknowledges it through
  `PMU.HP_INT_CLR.SW_INT_CLR` after consuming the event. LP firmware must not concurrently change
  sleep registers, software RTC snapshots, or analog/radio ownership.

An initialized Wi-Fi stack (including a stopped stack) or any outstanding Wi-Fi/BB/PHY clock
reference returns `error.RadioActive` before USB or sleep configuration changes. Deinitialize the
stack and release PHY references first. There is no automatic modem sleep or connected Wi-Fi
retention. The guard uses the ownership recorded by `hal/analog/esp32_c6.zig` and the OSI PHY
lifecycle; direct radio-register users must quiesce their hardware themselves.

The C3 USB policy shape applies on C6 too: default refuses enabled pads; `allow_usb_loss` accepts
endpoint loss; `.disconnect_and_reenumerate` uses the shared `usb_serial_jtag.Attachment`,
`wait_for_host`, and bounded host-reset wait. The host must reopen after each detach. A bus reset
alone does not prove CDC traffic. `Diagnostics` captures full C6 wake/reject/raw interrupt bits
and the optional USB bus-reset result; `Step` emits diagnostic milestones with interrupts masked.
Trace callbacks must be bounded and must not wait on sleep-gated peripherals.

`enter_deep_sleep(Config)` powers down HP CPU, TOP, modem and HP AON digital domains, retaining LP
SRAM; LP peripherals are off unless LP-core wake requires them (§12.4.2.4). Success never returns. UART wake is refused. Install an
**image-boot flash app**; RAM-loaded code cannot survive. No wake stub is installed; ROM reloads
flash through its reset path. Read `wake_cause()` before requesting another sleep: it returns
`reset` (including `.deep_sleep`, reset code 5, §8.2.2) and decoded timer/GPIO/UART/LP flags plus
raw source bits and EXT1 pin status, preserved by startup hold cleanup as described above.
Boot wake flags are zero for other reset reasons. Reserve LP
memory explicitly if using it as a reboot counter; HP startup does not initialize LP SRAM (§5.3.2).
Both entry calls own timer target 0 and PMU sleep/wake/reject flags, and must not share those with
another sleep manager. Once SLEEP_REQ is written, polling continues until wake or rejection,
matching IDF; software never disarms the timer while entry may still be pending.

Every sleep transaction installs IDF's one-second RWDT stage-0 `RESET_RTC` safety net around
hardware entry/exit if no application RWDT is enabled (`sleep_modes.c:1557–1565`). Default policy pauses
RWDT during sleep and preserves an already enabled application watchdog. `Config.bench_recovery`
is **off by default**. The C6 sleep self-tests enable it: a timer wake deadline is required, RWDT
gets the requested ticks plus five seconds (or the explicit bench-only `bench_reset_ticks`
deadline), both LP_WDT pause-in-sleep and HP_SLEEP's digital watchdog pause are cleared. An active application RWDT returns `WatchdogActive` in bench mode.
Stage 0 uses action 4, called `RESET_RTC` by IDF and **system reset** by TRM v1.2 §15.2.2.2,
Table 15.2-1: it resets PMU/RTC as well as HP, so a stalled PMU is reset rather than only the CPU.
Chip-reset mode remains off: system reset preserves internal memory (§8.1.1), including the LP
SRAM recovery marker. s7 below exercises this recovery on hardware.
A stopped LP slow clock or missing LP dynamic fast clock can defeat this watchdog
(§15.2.2.2, Register 15.1 reset lengths are in RTC_DYN_FAST_CLK). s7 below tests recovery with
XTAL kept on and an independent later timer wake; it deliberately avoids testing a hang.

Before attempting sleep, run **`selftest_sleep_c6_regs`** (no wiring, never sleeps). It prints
`current`, `would`, `idf`, and `mask` for each initialization, light/deep entry, timer, clock and
cleanup write. `current` is the hardware read; `would` simulates successive writes including the
initialization tables. `idf` is the expected word for this supported flag profile and eFuse bias.
Write-only command readbacks are not retained state. The `analog` phase uses slave:register
addresses (e.g. `0x6d05`) for bounded reads of regulator ownership; it never writes ENIF/XPD.
The probe temporarily routes clocks for TIMG calibration and analog reads, restores their gates,
and leaves the PMU state tables, power forces and sleep request untouched. A PASS means the plan
matches the reference encoding, **not** that reset/ROM values already match or sleep works.
Named-field table encodings are checked against literal IDF words at comptime. Calculated rows
receive an independent expected word rather than copying the HAL result. The probe starts with
`default_light`, `default_deep` and `default_light_xtal_off`: fixed reference inputs (Q13.19 slow period
3495253, fast period 26214, fallback biases 25/26) compared directly with checked-in literal words.
The later `light`/`deep`/`light_xtal_off` phases use measured clocks and burned biases; a separate raw-register
IDF implementation specializes the expected values for those inputs. The simulated expected state
is carried separately from the HAL state, so one wrong write cannot seed both columns.

`examples/espressif/esp/tools/sleep_c6_idf_reference.py` compiles unmodified ESP-IDF v5.5.1
`pmu_param.c`, `pmu_sleep.c`, `pmu_hal.c` and `pmu_init.c` on the host. RAM registers use IDF's
actual `pmu_ll.h` and `pmu_struct.h`; minimal shims supply platform plumbing and eFuse inputs.
Its checked-in output is `hal/pmu_c6_idf_vectors.zon`: all 60 initialization defaults plus nine
sleep profiles combining three fuse/period sets with XTAL-on light, timer-only default deep,
and XTAL-off light sleep, all with LP_FAST=RC_FAST. The former `deep_xtal` vectors were removed:
they reproduced IDF's bug, where `pmu_sleep.c:273–275` updates the local `power_default` after it
is copied to `config->power` at line 230. They are not safe operating profiles. Regenerate and verify byte identity with:

```sh
python3 examples/espressif/esp/tools/sleep_c6_idf_reference.py --check --idf <esp-idf-v5.5.1 checkout>
```

Run `zig build test-sleep-c6 -Dexample=selftest_sleep_c6_regs` in `examples/espressif/esp` to
compare the actual HAL plan, using generated register types, with every literal word and mask.
`zig build test` does not need IDF; the committed vectors supply the reference. Measured runtime
inputs still use the Zig specialization described above; the literal profiles are checked against
IDF's own C computation. Evidence: host comparisons, plus the hardware runs listed below.

Diagnostics do not require USB or a trace callback. Reserve **`0x50003fe0..0x50003fef`** in LP SRAM
(the mailbox's `0xe0..0xef`, separate from s5's `0xf0..0xff`). The low byte at **`0x50003fe0`** is
the latest milestone; the word at **`0x50003fe4`** is the pending MMIO address, or zero for a
non-register boundary. The words at **`0x50003fe8`** and **`0x50003fec`** hold the bench pending
marker `0xc651ee90` and its complement. They are written before entry and cleared after hardware
restoration, before the separately bounded USB reenumeration wait.
On reboot, the self-test consumes the marker before loading LP firmware or starting another sleep;
unexpected reset with a valid marker repeatedly reports `recovered_hang: FAIL` (s7 expects
`PASS` only for reset `0x10` at sleep-request milestone `0x41`) with reset reason,
marker, milestone and address. RWDT system reset is reset code `0x10` (TRM Table 8.1-1); reset code
5 is normal deep-sleep wake. Each write/poll boundary stores the record before accessing hardware.
Existing `Step` values `0x80..0x8a`, `0x91`, `0x92` still invoke trace callbacks.
Additional bytes: `0x10..0x19` analog bus/calibration; `0x20..0x29` CPU/LP clock calibration;
`0x30` PMU initialization; `0x31` sleep tables; `0x32` wake routing; `0x33` timer arming;
`0x34` flag/timer cleanup; `0x35` EXT1 restoration; `0x36` LP timer snapshot; `0x40` cache suspend; **`0x41` sleep request**;
`0x42` eFuse-IDLE wait; `0x43` cache resume. Use the recorded address to identify the particular
register within a phase. A stalled CPU cannot execute a software timeout; bench RWDT runs independently.

After a reset into the ROM downloader, read before loading an application/LP image, for example
`esptool --chip esp32c6 --before no_reset --after no_reset read_mem 0x50003fe0` and the same command
with `0x50003fe4` (newer esptool spells this `read-mem`). Avoid a power cycle; retention depends on
the reset domain (§§5.3.2,12.4.2.4). `lp_core.load()` clears LP SRAM, including this record.
The marker and milestone record are diagnostic evidence only.

IDF v5.5.1 `sleep_modes.c:1431,1501,1808–1809` anchors the timer before calibration/setup
and subtracts hardware/software overhead from the request. This HAL likewise anchors raw
ticks before setup, without IDF's estimated adjustment. Requiring 90% of the original
request to be spent stalled excludes setup time, which consumes part of that interval.

The timer check prints `requested_us`, `requested_ticks`, and awake-calibrated
`lp_hz` (LP ticks over a SYSTIMER-timed 100 ms, multiplied by ten). `setup_us` measures
LP time from just before the call to the request trace; `slept_ticks`/`slept_us` measure
the request-to-wake trace window, including cache/PMU transitions, before clock and USB
restoration. `call_lp_us` and `systimer_us` span the whole call. `sleep_active_us` counts
SYSTIMER time in the request-to-wake window; `stopped_us` is its LP time minus SYSTIMER
time (TRM §§12.4.3,13.3–13.4.1). The check requires entry-to-wake LP ticks within 99–120%
of the request (the timer is anchored at entry),
setup of at most 30 ms, and at least 1 ms and 90% of the request-to-wake window with
SYSTIMER stopped. Setup delays alone, immediate wake and busy waiting cannot satisfy
these checks.

External-wake stages, image boot:

| Image-boot example | Expected summary | Operator steps and pass criteria |
| --- | --- | --- |
| `selftest_sleep_c6_s9` | `SELFTEST sleep_c6_s9 DONE pass=3 fail=0` | Connect a **3.3 V** USB-UART adapter TX to GPIO17 (XIAO ESP32-C6 D7), RX to GPIO16 (XIAO ESP32-C6 D6), and common GND. The Super Mini ESP32-C6 exposes GPIO17/16 too. Use 115200 8N1, no flow control; keep TX idle high. Send `S` on native USB CDC at `ARMED?`. At `UART_WAKE`, wait **2 seconds**, then send sixteen ASCII `U` bytes once on the adapter. Reopen native CDC after detach to read results. Checks UART setup, UART0-only wake (`0x40`, no timer), and at least 100 ms / 90% CPU stall in the request-to-wake window. Wake bytes may be lost; no payload echo is required. |
| `selftest_sleep_c6_s10` | `SELFTEST sleep_c6_s10 DONE pass=4 fail=0` | Connect one jumper from **GPIO2** (XIAO ESP32-C6 **D2**, Super Mini ESP32-C6 **GPIO2**) to **3V3 before sending `S`** on native USB CDC at `ARMED?`. At `GPIO_WAKE`, wait **2 seconds**, then **move** the jumper to **GND** and hold through reboot. Never bridge the supply rails. Reopen CDC after reboot; remove the jumper after `DONE`. Checks deep-sleep reset, EXT1-only wake (`0x2`, no timer), GPIO2 status (`0x04`) and retained LP SRAM marker. An initially low pad fails before sleep. |

Install these with the generic **`esp32_c6` image-boot target**, as for s5; neither is
RAM-load runnable. Both have a 30-second LP timer fallback and bench watchdog recovery;
timer wake or watchdog reset fails. Do not resend `S` automatically after reconnect.
GPIO8 beacons HAL milestones and LP_AON.STORE0 records the latest callback, as in s1–s8.
Result lines repeat every three seconds after a 1.5-second reporting delay.
S9 uses the existing `clocks.sleep.Config.uart0` source with
`SLEEP_CONF2.WK_MODE_SEL=0`, `ACTIVE_THRESHOLD=2`: **five rising RX edges** wake the chip
(C6 TRM v1.2 §27.4.8; ESP-IDF v5.5.1
`components/hal/esp32c6/include/hal/uart_ll.h`, `uart_ll_set_wakeup_mode` and
`uart_ll_set_wakeup_edge_thrd(5)`). It resets UART0 after wake to clear the wake signal.
S10 may instead use a 3.3 V UART TX with common GND as the external level source:
idle high before `S`, then assert break (low) after the same two-second wait and hold through
reboot. S10 configures LP input GPIO2 and active-low EXT1 through `clocks.sleep`, then reads
`wake_cause()` before reconfiguring pads or requesting another sleep (TRM v1.2
§§7.7,12.4.2.2,12.10.2–3; deep-reset cause §8.2.2.7; LP SRAM retention §5.3.2).

C6 `selftest_sleep_c6_s1` checks awake counter and
validation/USB guards; s2 sleeps 100 ms; s3 checks 100/250/500 ms, runtime SRAM patterns and clock
restoration; s4 has the LP core drive GPIO0 high internally, with a one-second timer fallback and
separate GPIO cause/pin checks (no wiring); s5 detects timer/deep-reset plus a retained LP memory
counter on reboot and builds only for the `esp32_c6` image-boot target; s6 reconnects without
sleep and sleeps 100/500 ms, checking bus reset, register restoration and bidirectional CDC using
the C3 nonce protocol. s7 requests 10-second LP-timer light sleep with XTAL on and a three-second
bench RWDT deadline. **Install s7 in flash using the `esp32_c6` image-boot target**, as for s5.
RAM-loaded flashless code cannot restart itself after the intended watchdog reset; s7 therefore
builds only for image boot. Pass requires reboot with RWDT system-reset cause `0x10` and
`recovered_hang: PASS`; reaching the timer fallback reports FAIL. s8 checks 100/250/500 ms
retention/restoration with LP_FAST=RC_FAST and XTAL off in both sleep tables. After **each** detach reopen the port, send `USJ?` after 1.5 s, then echo
`USJ nonce=xxxxxxxx` as `ACK xxxxxxxx`. Summaries start after 1.5 s and repeat every three seconds.
Every C6 sleep stage waits for the single ASCII byte **`S`** over USB Serial/JTAG before its
first sleep, on every boot. Open the CDC port, wait for `ARMED? send S to start`, then send `S`
without needing a newline. For example, run pyserial's
`python3 -m serial.tools.miniterm /dev/ttyACM0 115200`, then type `S` (exit with Ctrl-]).
Do not configure a host to resend `S`
automatically on reconnect. Replugging a hung board leaves it waiting for a new byte, so normal
USB flashing works without BOOT. Deep-reset/recovery reports run before the arm wait and never
start a second sleep. The register probe never sleeps and needs no arm byte.

Remaining IDF differences: this subset keeps light-sleep CPU/TOP/HP memory and flash supply on,
has no peripheral retention, RTOS timing compensation or wake stub, uses bounded analog/calibration
and UART waits, and temporarily restores modem clock maps. A real PLL calibration failure returns
on XTAL as described above. Bench mode deliberately changes watchdog sleep policy.

Evidence, `esp32_c6` image boot, 3 runs per stage armed by the host, on the XIAO ESP32-C6 and the
Super Mini ESP32-C6: s1 3/3, s2 2/2, s3 4/4, s4 2/2, s5 (deep sleep: reset, timer wake, LP memory)
3/3, s6 13/13, s7 (RWDT reset 3 s into a 10 s light sleep,
`recovered_hang: PASS reset=0x10`) 1/1 and s8 (XTAL-off light sleep with LP_FAST on
RC_FAST) 4/4 in every run on both boards; no hang. The register probe, from RAM at
24ebc5d1 (2026-11-19), matched the IDF-derived value on all 284 rows in 3 runs each
on the Super Mini ESP32-C6 and the XIAO ESP32-C6.
External-wake stages on the XIAO ESP32-C6, `esp32_c6` image boot, with an RP2040-GEEK
running debugprobe v2.3.1 as the 3.3 V USB-UART (GP4 TX, GP5 RX, common GND):
s9 (GP4 to D7, GP5 to D6) passed 3/3 in 3 of 3 runs with UART wake `0x40`, sixteen `U`
bytes sent once per run; a control run without the `U` bytes failed `uart0_wake` with
`wake=0x10` (timer fallback) and reported `DONE pass=2 fail=1`. s10 used the
UART break as the level source (GP4 to D2): 4/4 in 3 of 3 runs, each waking about 0.3 s
after the break; a control run without the break woke on the timer (`0x10`) at about 30 s
and reported `DONE pass=2 fail=2` (`ext1_wake` and `gpio2_status` FAIL).

GPIO8/LP_AON.STORE0 carry HAL milestones. The tests reserve GPIO0 for s4 and the last 16 LP
mailbox bytes for s5; do not combine them with another LP-memory owner.

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

C6 application initialization enables RC_FAST, waits 50 µs, selects it for LP_FAST, then waits
3 µs, matching IDF v5.5.1 `rtc_clk.c:90–95,127–130` / `soc/rtc.h:62–64` and v6.0.2
`components/esp_system/port/soc/esp32c6/clk.c:55–56` (the local v5.5.1 checkout lacks that file).
TRM v1.2 §8.2.4.2 and Register 8.75 define RC_FAST vs XTAL_D2. LP CPU uses LP_FAST;
LP UART/I2C select LP_FAST or XTAL_D2 independently (Table 8.2-5, Register 8.84). Their LP_FAST
rate is the nominal 17.5 MHz RC oscillator instead of crystal-derived 20 MHz; supply a measured
`source_hz` for baud/SCL accuracy. Explicit XTAL_D2 peripheral selections remain crystal-based and
must be quiesced for XTAL-off sleep. LP_TIMER and RWDT count LP_SLOW, whose selection is unchanged
(§12.4.3, §15.2.2.2); LP firmware delay loops tied to LP_FAST change rate. Light sleep keeps the LP
peripheral domain; `lp_core` wake keeps RC_FAST in LP_SLEEP too. HP CPU/APB and radio PLL/XTAL,
modem clock maps and Wi-Fi/BLE/802.15.4 clock gates are unchanged by this startup selection, which
also matches IDF's radio environment. Wi-Fi's low-power clock remains RC_SLOW
(`analog/esp32_c6.zig`, `radio_init`); Wi-Fi/BLE still require the PLL CPU source
(TRM §8.2.4.4). The LP self-tests and the radio examples ran with this startup selection on
the Super Mini ESP32-C6 and XIAO ESP32-C6 (results in their sections).

With the reset value XTAL_D2 (Register 8.75), LP_FAST would stop when XTAL is powered down,
while PMU HP-state XTAL/PLL waits use LP_DYN_FAST=LP_FAST (§12.4.2.3, §12.4.2.5) and watchdog
reset lengths need RTC_DYN_FAST (Register 15.1). With LP_FAST on RC_FAST and unsafe XTAL-off
profiles refused, the deep-sleep (s5), watchdog (s7) and XTAL-off (s8) stages pass (above).

RNG reads enable the asynchronous RC_FAST path and are serialized below 1 MHz. On C6, an active
SAR ADC or radio ADC is required for true randomness (TRM §26.3–26.4). The HAL does not enable an
ADC implicitly; without ADC entropy its output is pseudo-random and unsuitable for cryptography.

### Boards and hardware validation

The upstream XIAO ESP32-C6 target is retained as `boards.seeedstudio.xiao_esp32_c6`. Its pads, bus assignments,
GPIO15 LED, and GPIO3/GPIO14 RF switch match Seeed's
[Pin Map and Hardware overview](https://wiki.seeedstudio.com/xiao_esp32c6_getting_started/).
The [Seeed schematic, sheet 04 ESP32 C6](https://files.seeedstudio.com/wiki/SeeedStudio-XIAO-ESP32C6/XIAO_ESP32_C6_v1.0_SCH_260114.pdf)
shows the 40 MHz crystal and LED connected from 3V3 through R25/D4 to GPIO15 (active low).

The Super Mini ESP32-C6 has no board target: use the bare-chip C6 targets; there is no Super
Mini ESP32-C6 pin map or LED assumption in this package.

Build the no-wiring core self-test from `examples/espressif/esp` with
`zig build -Doptimize=ReleaseSmall -Dexample=selftest_c6_core`. It builds in all three C6 boot modes.
It checks the 16 MHz systimer against the HP CPU cycle counter, measures the CPU frequency after
each of the 81 ordered transitions between the nine supported frequencies (1.25 MHz to 160 MHz)
with 1% tolerance, exercises GPIO0's output/input path and systimer LOAD_HI,
and checks the efuse MAC. With `-Dexpected_mac=aa:bb:cc:dd:ee:ff` (the board's MAC, e.g.
`98:88:e0:7e:fc:74` for the Super Mini ESP32-C6) the MAC must match, so another board fails that case.
Without the option the MAC is reported as `SKIP` and excluded from both pass
and fail counts (84 checks instead of 85). Octets must be two hex digits; signs
are rejected. Clock measurements are relative to the common crystal; they do not establish its
absolute accuracy. It runs once, waits 1500 ms, then repeats saved `SELFTEST c6_core` results and a
`DONE pass=... fail=...` line every second through USB-serial-JTAG.

The additional `selftest_c6_ledc` example samples a 1 kHz PWM through GPIO0, checks 25% and 75%
duty cycles and their active-duty readbacks, measures both XTAL and PLL_F80M clock paths, and
verifies a gamma fade reaches its expected final duty. It also needs no wiring. Fixed-duty updates
use a zero-scale gamma range with DUTY_START and PARA_UP, rather than leaving the duty engine
stopped (TRM §35.3.4.1 and §35.5, registers 35.1–35.2).

Evidence, from RAM: `selftest_c6_core` at 24ebc5d1 (2026-11-19), 3 runs each on the Super
Mini ESP32-C6 and the XIAO ESP32-C6: without the option 84 passed with `mac: SKIP`; with `-Dexpected_mac` set
to the board's own MAC 85/85. An earlier Super Mini ESP32-C6 build with the XIAO ESP32-C6's MAC failed only
the `mac` case (84/85). `selftest_c6_ledc` passed 7/7 on the Super Mini ESP32-C6.

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

## ESP32-C6 LP core

`chips.esp32_c6_lp` builds RV32IMAC raw binaries for the 16 KiB LP SRAM
(TRM v1.2 §§3.3, 3.7.1). The reset entry is at 0x50000080; the vector
table starts at 0x50000000. The linker reserves 1 KiB for stack and the
top 256 bytes for a mailbox. Oversized images fail to link. LP startup
initializes BSS on each reset; initialized data is loaded by HP once.
An application interrupt callback receives the LP peripheral source mask
and must acknowledge each source before returning. Interrupts default to
disabled; exceptions and unhandled interrupts halt. HP clock/ROM init is
not used. `esp32_c6_lp_counter.bin` is built with the examples. Evidence:
`lp_counter` runs inside `selftest_lp_core` (7/7, below); LP I2C board evidence is listed below.

`hal.lp_core` loads a raw binary and starts/stops/wakes the LP CPU. Load at
cold boot or after the asynchronous stop flow completes, with HP active;
there is no live-image replacement or debugger-aware reset support. The
caller owns all LP SRAM and must serialize configuration between cores.
HP, timer and ETM wake masks are supported; ETM routing belongs to `hal.etm`.
The first wake is HP-initiated. `Mailbox` reserves aligned single-writer words
at 0x50003f00 with fences, never LP SRAM AMOs (§3.7.1). HP owns `command`;
LP owns payload and `sequence`, which it publishes last. Treat payload as
stable only while LP sleeps; this is not a multi-writer queue.
`selftest_lp_core` embeds the generated LP image, checks the counter and a
second HP wake. Evidence: 7/7 from RAM in 3 runs each on the Super Mini ESP32-C6 and the
XIAO ESP32-C6, at 24ebc5d1 (2026-11-19).

`hal.lp_io` configures LP GPIO0–7 (TRM §§7.7, 7.13, 7.16.4), reads pads,
and uses write-one set/clear for outputs. Function 1 selects the fixed LP
UART/I2C pins; this chip has no LP GPIO matrix. HP and LP may both call it
with exclusive ownership. It does not release pad holds or configure sleep
pad overrides. `selftest_lp_core` toggles GPIO0 on successive LP wakes,
checks LP input and HP GPIO matrix input, then drives it from HP. No wiring;
GPIO0 must be free. Evidence: its `lp_io_high`, `lp_io_low` and `hp_lp_io` cases are
part of the `selftest_lp_core` 7/7 runs above.

`hal.lp_timer` snapshots the 48-bit RTC timer and arms/acknowledges/disables
target 1 (TRM §§12.4.3, 12.10.3). HP or LP may own it, never concurrently.
Intervals are LP_SLOW_CLK ticks; no RC calibration, wall-time precision or
deep-sleep power validation is claimed. Target 0 is preserved. Periodicity
is implemented by rearming on every LP reset/wake. `selftest_lp_timer`
embeds its own LP program, counts repeated timer wakes from HP and checks
stop. Evidence: 4/4 from RAM in 3 runs each on the Super Mini ESP32-C6 and the XIAO ESP32-C6,
at 24ebc5d1 (2026-11-19).

`hal.lp_uart` provides bounded polling 8N1 byte I/O, error reporting,
register synchronization and internal loopback (TRM §§27.4, 27.7.2).
It uses LP_FAST or XTAL/2 with an explicit source frequency; calibrate RC
for an accurate external baud and keep XTAL powered if selecting XTAL/2.
External I/O uses fixed GPIO4 RX/GPIO5 TX (Table 7.13-1). No DMA, flow
control or interrupt buffering. HP/LP must transfer controller ownership.
`selftest_lp_uart` uses XTAL/2 at 115200 8N1 with HP awake. Wire GPIO4 RX
from Pico GP12 TX and GPIO5 TX to GP13 RX, plus common GND. Select
`mode lpuart c6` before starting. It checks load, a 64-byte external echo and
empty-RX timeout on LP and HP: expected `SELFTEST lp_uart DONE pass=5 fail=0`.
Require `PEER lpuart clk: PASS`, status `errors=0` and no peer FAIL verdicts.
Evidence: 3/3 runs, `DONE pass=5 fail=0`, on the Super Mini ESP32-C6 against
the Pico 2 W peer, with peer `errors=0` and its clock check passing.

`hal.lp_i2c` provides polling 7-bit master address probes, writes of up to
15 data bytes and reads of 1–16 bytes (TRM §§29.4–29.6, 29.11.1). GPIO6 is
SDA, GPIO7 SCL; both must be free. Select LP_FAST or powered XTAL/2 with
an explicit source frequency. Timing ranges are checked; the LP path does
not use the HP PCR prescaler. NACK, arbitration, FIFO and timeout failures
are returned; every poll is bounded and the FSM is reset after failure.
A detected NACK remains `Nack` even if its STOP outlasts the poll budget.
Completion with unsent TX bytes is rejected as `Fifo`, including stale
completion after an aborted STOP.
No slave mode, DMA, interrupt servicing, 10-bit addresses, repeated-START
combined transfers or GPIO recovery of a physically stuck external bus.
External devices need suitable pullups. For `selftest_lp_i2c`, connect GPIO6 SDA
to Pico GP14 and GPIO7 SCL to GP15, plus common GND; both ends enable internal
pull-ups at 100 kHz (external 4.7 kΩ pull-ups may be added). Select `mode i2c c6`.
The Pico I2C1 target at 0x42 implements the register-file protocol from
`examples/raspberrypi/rp2xxx/src/i2c_slave_peer.zig`: pointer byte, auto-increment,
STOP retains the pointer, 0xf2=0xa5 and version 1 at 0xf3. On LP and then HP,
the test requires one ACK at 0x42 and 111 NACKs in 0x08–0x77, a 14-byte
write/readback plus version check, and NACK at 0x55 followed by ACK at 0x42.
Together with load, expect `SELFTEST lp_i2c DONE pass=7 fail=0` and peer `errors=0`.
Evidence: 3/3 runs, `DONE pass=7 fail=0`, on the Super Mini ESP32-C6 against
the Pico 2 W peer, with peer `errors=0`.

The named ETM task `hal.etm.Task.lp_cpu_wake` is ID 154 (Table 11.3-2).
`selftest_lp_core` also routes an unwired GPIO1 edge to that task and checks
the LP wake flag and next count; GPIO0/1 must be free. `selftest_lp_irq`
interrupts an already-running LP CPU from HP, checks source decoding at
vector 30 and continuation after `mret`. Each self-test waits at least
1.5 s before reporting, then repeats cases and summary every second.
At 24ebc5d1 (2026-11-19), from RAM, 3 runs each on the Super Mini ESP32-C6 and the XIAO ESP32-C6:
`selftest_lp_core` 7/7, including `etm_wake`, and `selftest_lp_irq` 4/4.

## Partition table

`hal.partition_table.read(device)` reads the ESP-IDF table at `0x8000` without
modifying flash. `Table.decode` is also usable on host byte images. The whole
table is checked for magic, flash bounds, partition overlap, duplicate labels,
and MD5 when present before `find_data(.nvs, "nvs")` returns a partition.
`hal.partition_table.find_data(device, .nvs, "nvs")` applies the same checks
while streaming the entries and keeps only the match (see "NVS store").
Limits: default table offset only, at most 95 entries, no decryption. Partition
flags are retained for callers to enforce. `selftest_nvs` lists all decoded
partitions, requires every entry of ESP-IDF's default single-app table (`nvs`,
`phy_init`, `factory` at 0x9000, 0xf000, 0x10000) and requires the MD5 entry to match
the bytes read from flash; it also checks rejection of a digest corrupted in RAM.
These cases passed as part of `selftest_nvs` 12/12 on the C3, Super Mini ESP32-C6 and XIAO ESP32-C6
(2026-11-20, see "NVS board self-test"). The decoder is unit-tested. Format reference: ESP-IDF
`components/partition_table/gen_esp32part.py`.

## NVS format

`hal/nvs_format.zig` implements version 2 headers, entry layout, ROM-compatible
CRC32, span validation, bitmap iteration and a fixed-size page hash map. Bucket
collisions require a full key comparison. No allocation or target imports.
Evidence: unit-tested, including an ESP-IDF-generated page image, and on boards
through `selftest_nvs` (see "NVS board self-test").
The fixture `src/hal/nvs_testdata/idf.bin` was generated offline from the CSV
beside it with ESP-IDF's `components/nvs_flash/nvs_partition_generator/`
`nvs_partition_gen.py generate <absolute-idf.csv> <absolute-idf.bin> 0x3000
--version 2` (installed `esp-idf-nvs-partition-gen` 0.1.9). The fixture contains
one namespace, unsigned/signed integers, a string and a v2 blob chunk/index.

## NVS store

`hal.nvs.Storage(Backend)` provides namespaces, all 8/16/32/64-bit signed and
unsigned integers, NUL-terminated ESP-IDF strings, v2 chunked blobs, key erase,
and `Handle.commit()`. Writes are synchronous: successful setters/erase calls
are already durable, so commit is a barrier and does not group keys atomically.
Read values with the same type they were written with. Erase first to change a
key's type. Handles open in ESP-IDF's three modes (`nvs_open_mode_t`):
`.read_only` rejects changes; `.read_write` (`NVS_READWRITE`) marks a replaced
or erased value's entries erased, and its bytes stay in flash until its page is
reclaimed; `.read_write_purge` (`NVS_READWRITE_PURGE`) also overwrites them
with zeros. Init's repairs always zero, as ESP-IDF's do
with `Page::DEFAULT_PURGE_AFTER_ERASE`. No Wi-Fi or PHY integration.

Where ESP-IDF v6.0.2 (`nvs_storage.cpp`, `nvs_page.cpp`) answers with a
generic code or quietly repairs, this store keeps distinct errors and erases
nothing on a read:

| Situation | ESP-IDF | This store |
| --- | --- | --- |
| Key absent; namespace absent when opened read only | `ESP_ERR_NVS_NOT_FOUND` | `NotFound` |
| Read as another type than stored (integer width or sign, string, blob) | `ESP_ERR_NVS_NOT_FOUND`: `Storage::findItem` skips the page's `ESP_ERR_NVS_TYPE_MISMATCH` | `TypeMismatch` |
| Write of another type than stored | replaces the old item (`Storage::writeItem` looks the key up as `ItemType::ANY`, `nvs_storage.cpp` 445-461), unless built with `CONFIG_NVS_LEGACY_DUP_KEYS_COMPATIBILITY` (Kconfig default `n`), which keeps both | `TypeMismatch`; erase first |
| String or blob payload fails its CRC | `ESP_ERR_NVS_NOT_FOUND`, and the item is erased (`Page::readVariableLengthItemData`) | `Corrupt` |
| Blob index whose chunks are missing or too long | erased at init with its chunks if the chunks do not add up to its size and count (`Storage::eraseMismatchedBlobIndexes`, `nvs_storage.cpp` 90-152, and `Storage::eraseOrphanDataBlobs`); else the read answers `ESP_FAIL` or `ESP_ERR_NVS_INVALID_LENGTH` and erases the blob (`Storage::readMultiPageBlob`) | `Corrupt`, and the index stays, unless its key also has a version 1 blob (see "Init and ESP-IDF's") |
| String without its terminating NUL, or with an embedded one | the stored bytes | `Corrupt` |

A blob written over a format version 1 blob is not a type change (below). The
test `type and payload errors stay distinct from NotFound and a read erases
nothing` pins every row: a read-only open of a missing namespace, each type
mismatch, a payload CRC failure, chunks missing and chunks longer than the
index says, a string without its NUL and one with an embedded NUL.

For C3/C6 flash, initialize `hal.flash.Flash`, call
`hal.nvs_flash.open(device, "nvs")`, then initialize a caller-owned
`hal.nvs_flash.Store` with that backend and `backend.region.size`. This reads
and validates the entire table, rejects flags (including encryption/read-only),
and bounds every access to that named NVS partition. `Flash.data_region` is the
only flash API extension: the original guard conservatively protects all bytes
below the running image end, which includes the usual NVS location. The bounded
API checks the actual image interval (including OTA copies), protects low boot
metadata through `0x9000`, and retains the raw API's existing default protection.
Unknown image layouts fail closed. Direct-boot/RAM-boot applications must supply
a real, disjoint partition table; the self-test uses image boot only.

Partition lookup streams 32-byte entries and rereads earlier entries to check
overlaps and duplicate labels, keeping full-table buffers off the stack of the
open path. A lookup costs 96 + n(n-1)/2 32-byte flash reads for an n-entry
table. Serialize access with partition-table writers.

Limits (what differs from ESP-IDF in damaged or foreign states is listed
under "Known limits"): unencrypted version 2 pages only; no iteration, no key-type conversion,
no multi-key atomic transaction. Format version 1 blobs (a single item of type
`0x41`) that ESP-IDF left in version 2 pages are read, replaced and erased as
ESP-IDF v6 does (see the `legacy_*` fixtures below), except that init erases one
whose key also has a blob index that reads, which ESP-IDF can keep (see "Init
and ESP-IDF's").
Partitions must have 3–64 sectors (12–256 KiB). One sector stays free for garbage
collection; replacement blobs temporarily need room for both versions. Strings
are at most 3999 bytes plus NUL and cannot contain embedded NULs. Names are 1–15
bytes without NULs. The store allocates nothing, owns two 4 KiB page buffers
(scan cache and reclaim snapshot) and a page hash index, and must not be copied
after handles are opened. Serialize all calls in task context; do not use from
interrupts. Reinitialize after flash I/O errors. Initialization repairs
interrupted writes/reclaims, discards invalid entries and erases pages with
invalid headers; it can write even if the next namespace handle will be
read-only. Preserve a backup of irreplaceable data.
Page sequence exhaustion reports `NotEnoughSpace` rather than wrapping.

Evidence: unit-tested, and on hardware as below. Host tests cover all integer widths, namespace
isolation, commit/reopen/erase, full partition and reclaimed space, multi-page
blobs, failed replacement preserving the old value, maximum strings, corrupt
payload CRC, and power loss after each operation in a rollover workload. The
ESP-IDF fixture is read, modified and reopened through the store. The board
self-test (below) passed 12/12 on the C3, Super Mini ESP32-C6 and XIAO ESP32-C6 (2026-11-20).
References: ESP-IDF `components/nvs_flash/src/nvs_types.*`,
`nvs_page.*` and `nvs_pagemanager.cpp`. Derived code credits
`totorototo`'s MicroZig implementation in source.

### NVS board self-test

Build `examples/espressif/esp` with `zig build -Doptimize=ReleaseSmall
-Dexample=selftest_nvs`. Outputs `esp32_c3_selftest_nvs.bin` and
`esp32_c6_selftest_nvs.bin` (and ELF files); only ESP-IDF image-boot targets are
registered. No external wiring is required. Use an existing ESP-IDF bootloader
and ESP-IDF's default single-app partition table (`partitions_singleapp.csv`: `nvs`
0x9000/0x6000, `phy_init` 0xf000/0x1000, `factory` 0x10000/1 MiB, with its MD5 entry) at
`0x8000`; `partition_list` fails on any other layout. Install the app at 0x10000 with
the usual image-boot procedure. This example neither installs a table nor
formats a missing partition; invalid/missing tables report failure before NVS
writes. Back up existing data before running a flash-write self-test.

Expected result: `SELFTEST nvs DONE pass=12 fail=0` (the original eight cases
plus `read_only`, `purge`, `partition_list` and `partition_md5`). With image boot
behind an ESP-IDF second-stage bootloader: `DONE pass=12 fail=0`
in 3 of 3 boots each on the C3, the Super Mini ESP32-C6 and the XIAO ESP32-C6, with `boots` rising by one on
each boot without reflashing.

The self-test reserves namespaces `mz_selftest` and `mz_purge`; it writes all integer widths,
a string, a 6000-byte multi-page blob, and 300 counter updates, commits, reopens,
checks values, erases its test keys, then reopens to verify absence. The
read-only case rejects integer/string/blob writes, key erasure and commit, then
re-initializes and verifies the committed values remain. In `mz_purge`, a
`read_write_purge` handle erases all three test keys (integer, string and blob);
raw flash reads verify the string/blob payloads were zeroed. Re-initialization
finds those keys absent, and a new write survives commit and re-initialization
before cleanup. This empties the test namespace, not the whole partition. A final
`boots_increment` case increments the u32 key `boots`, commits, reopens and reads it back;
This case checks the increment and same-boot reopen, not persistence across boots.
`boots` is never erased, so `SELFTEST nvs boots=N` must rise by one on each
reboot without reflashing (the host compares the two boots). Store initialization may repair pages and garbage
collection may move other keys **within the named NVS partition**; application,
bootloader and other partitions are never write targets. Keys in other
namespaces are preserved. If interrupted, test keys may remain until a successful
rerun. USB Serial/JTAG logs repeat `SELFTEST nvs <case>: PASS|FAIL` and
`SELFTEST nvs DONE pass=N fail=M`; the flash operations run once per boot.

The board workload also runs twice against a simulated minimum 12 KiB partition
in host tests, with guard pages and an unrelated namespace checked after
reclaim and erase.

Reclaim persists the victim's `freeing` state before activating the reserve
page, matching ESP-IDF v6.0.2 `nvs_pagemanager.cpp::requestNewPage`
(v5.5.1 activates the destination first; see "Known limits"). Host crash tests
reset between every completed reclaim write/erase (including before and after
bitmap publication), reopen and check every scalar, string, blob and namespace.
They also reset during each recovery write/erase and reopen again. The general
rollover workload tests both resets between operations and partial operations.

Every walk of a page (lookup, hash index, recovery, reclaim) reads it as
ESP-IDF's `Page::mLoadEntryTable` and `Page::findItem` do: an entry not marked
written, or marked written with a header `Item::checkHeaderConsistency` rejects,
is stepped over alone; a consistent string, blob chunk or legacy blob header
is stepped over with its span, and is an item only if all of its entries are
marked written; the active page is read up to its first free entry only.
Interrupted multi-entry items are discarded as whole extents. An item is
published by one bitmap write from its header to its last entry, and erased
from its last bitmap word to its first, as ESP-IDF's
`Page::alterEntryRangeState` does: an interrupted erase leaves the header
marked written over a partly erased extent, which init then erases whole, so
neither this store nor ESP-IDF ever reads the payload of an item this store was
writing or erasing as headers. Once its entries are marked erased, an item
erased by init's repairs or through a `.read_write_purge` handle is overwritten
with zeros, as ESP-IDF's `Page::eraseItem` does with `purgeAfterErase` set; a
`.read_write` handle leaves it marked erased only, as `NVS_READWRITE` does.
The same holds, per handle, for a value a write replaces and for both items of
a key with a blob index and a version 1 blob that an erase takes: zeroed
through a purging handle, only marked through a `.read_write` one (`a write
replaces through a purging handle by zeroing the old entries, through a
read_write one by marking them`). In
either mode a page this store erased from holds the bytes ESP-IDF's erase in
the same mode would leave (see below). Tests embed a valid encoded replacement key inside
blob payload, interrupt bitmap publication, erasure and recovery, and verify the
untouched key stays unchanged across reopen. A published header that is damaged
is different, see below.

### Exhaustive host crash replay

`zig build test` also runs `nvs_crash_test.zig`, which records every program and
sector erase in a 638-action workload, then replays its physical-operation
prefixes from erased flash. It covers all integer types, two namespaces,
strings, multi-page blobs, overwrites, key erases and five page reclaims. Blob
payload entries contain CRC-valid encoded replacements for an unrelated key.
Strings exercise multiple entries but cannot contain these binary headers:
the string API rejects embedded NUL bytes required by encoded key names.

The workload runs once through `.read_write` and once through
`.read_write_purge` handles. The purging trace has 2590 program operations (627
of them the zeroing of erased items, each after its bitmap update) and 5 sector
erases; the other has 1963 programs, none of them zeroing, and the same 5
erases. The harness checks **10359 and 17658 crash points**: after every
completed operation and at every 4-byte program-prefix boundary (including zero
bytes). NOR programming preserves
the pre-operation bytes after the torn prefix, including earlier bitmap bits.
Every case reopens and verifies all completed keys. The in-flight key may
read old or new; an interrupted same-page blob rewrite may also be absent,
as in ESP-IDF v5.5.1. It then writes another key, reopens again and verifies
that recovery's chosen values remain durable. Sector erase interruptions are
also covered separately by the older partial-operation tests.

A second replay, `a reset at every word of a write over or an erase of a version
1 blob leaves the old or the new value`, starts from the `idf_state_legacy_blob`
partitions (below) and records, in both modes, a write over and an erase of the
version 1 blob on its active and on its full page, and a write over it on the
full page once the active page is nearly full of other keys, so that the write
itself reclaims the version 1 blob's page, copying that item to another page
and erasing the sector (the test checks both). It checks **819 crash points**
(307 without purging, 512 with) at the same granularity: every key keeps its
value, the blob reads old or new, the version 1 item is gone exactly when the
new value is read, and the choice holds after another write and a reopen.

From the active page's first entry marked empty, ESP-IDF erases and zeroes
each entry whose first word is programmed, one at a time, until a blank one.
Recovery here goes on while any byte is programmed, so that the next item is
written on blank flash, and over the whole extent an unpublished
variable-length header there claims (its first word holds the span; key, data
length and CRC need not have reached flash yet, and payload may be blank
0xff). That extent is erased from its last entry back to its header, so a reset
in between leaves the header that claims the rest. ESP-IDF reads none of these
entries either way.

`python3 src/hal/nvs_testdata/crosscheck_idf.py <esp-idf checkout> [zig]`
(not run by `zig build test`) has the crash replay write every image it checks,
as the crash left it and once this store had recovered it, with the values
allowed there (`zig build test -Dnvs-crash-dump=<file>`), and boots unmodified
ESP-IDF `Storage` on each, compiled for the host as on a target (without the
host-only `Storage::debugCheck`). ESP-IDF must read every completed key and the
in-flight key's old or new value, and keep that choice after a second boot and
after writing another key. Result with ESP-IDF v6.0.2, both replays and both
modes (10359 + 17658 + 819 points): 28836 crashed and 28836 recovered images,
no failures; 12 crashed images (6 per mode) are read with ESP-IDF's tail chunk
loss (below), checked as such and not counted as failures. Evidence: host
tests.

`python3 src/hal/nvs_testdata/init_diff_idf.py <esp-idf checkout> [--zig zig]
[--seed 1] [--count 3000] [partition.bin ...]` (not run by `zig build test`)
covers the states only damage or another writer leaves. Unmodified ESP-IDF
`Page` code writes `--count` random four-page partitions from `--seed`: blob
chunks, blob indexes and version 1 blobs of three keys in two namespaces,
complete or not, short, overlapping, out of order, from any first chunk number,
some with a damaged payload, between other keys; in some, an integer or a
string that is the newest page's last item, with older items of its key, of its
type or another. They lie on one to three pages, in any physical order; in one
partition in six a page is marked as being freed. Unmodified `Storage` boots
each twice, the second time on what the first left; a boot is init and then
four reads of each key. `zig build nvs-init-diff` does the same with this
store. The script holds a model of ESP-IDF's rules, item by item, with one
switch for each difference listed under "Init and ESP-IDF's" below. ESP-IDF and
the store must each match the model exactly at every step: the items each init
leaves, every read's status and bytes, and the items the reads leave (none
erased by a read here). A case is counted under the switches it used; one where
either side departs from the model, or where the two differ and no switch was
used, is UNEXPLAINED, which fails the run. Not generated: a partly written
item, a damaged item or page header, a stray entry; a partition without a free
page, or of another size; two pages being freed, two active pages, two pages
with one sequence number. Only the blob keys are read; of the other keys, the
items each init leaves are compared. Given partition files (16384 bytes), it
boots those instead. Result with ESP-IDF v6.0.2 and the defaults: 3000
partitions, 931 the same, 0 UNEXPLAINED; seeds 1 to 8 with `--count 10000` also
leave 0 UNEXPLAINED. Evidence: host only.

### ESP-IDF erased and zero-purged entries

ESP-IDF v6.0.2 erases an item by marking its entries erased and, when purging,
then overwriting them with zeros (`Page::eraseEntryAndSpan`,
`Page::purgeEntryRange`). Its repairs purge (`Page::DEFAULT_PURGE_AFTER_ERASE`
is true); a handle's erases and replacements purge only if it was opened
`NVS_READWRITE_PURGE` (`nvs_handle_simple.cpp` passes `mPurgeAfterErase`). A
zeroed header no longer records
the item's span, and a purge interrupted after its first entry leaves the rest
of the payload erased but not zeroed. ESP-IDF never parses erased entries:
`Page::mLoadEntryTable` and `Page::findItem` step over them one at a time.
Every walk of a page here does the same, so a purge's leftover payload is never
read as a header. This store purges the same way, in the same cases (init's
repairs, `.read_write_purge` handles): the bitmap first, then zeros over the
whole extent in one write, so a reset in between leaves erased entries that are
never zeroed, which nothing reads. Tests erase keys from purge_fixture.cpp's
page (below) and from `idf_blob_rewritten.bin` and compare the result byte for
byte with ESP-IDF's own erase: through a purging handle with `idf_purged_*.bin`
and `idf_blob_erased.bin`, through a `.read_write` handle with
`idf_erased_*.bin` (`an erase leaves the page byte for byte as ESP-IDF's erase,
with and without purging`); ESP-IDF's unpurged pages are also read, kept and
reclaimed (`ESP-IDF erased but not purged items are read, kept and
reclaimed`). A programmed entry marked empty is stepped over alone too on
a full page, where ESP-IDF reads only entries marked written, and reclaim
copies every item after it; at the active page's first free entry it is
erased and zeroed, as ESP-IDF does.

### ESP-IDF damaged headers

An entry marked written whose header fails ESP-IDF's
`Item::checkHeaderConsistency` (CRC, type, span and chunk fields), blank ones
included, or any entry marked illegal, is a *stray entry*. `Page::mLoadEntryTable`
(active and full pages) and `Page::findItem` erase and zero a written stray
entry alone with `Page::eraseEntryAndSpan`, without trusting the span it claims,
and read on from the next entry, so the damaged item's payload entries are each
checked as headers and, failing, erased in turn. An illegal entry is erased and
zeroed only by the active-page load; elsewhere it is stepped over. Every walk
here steps over a stray entry alone too, and init erases and zeroes the same
stray entries ESP-IDF's load does (on the active page all of them, on full pages
the written ones), zeroing before the bitmap update so that an interrupted
repair is picked up again. Neither this store's writes nor its erases leave a stray
entry, interrupted or not: a header is complete before its bitmap marks it
written, and illegal is never written. So damage no longer hides the keys after
it or makes reclaim refuse the page. As in ESP-IDF, a damaged header's payload
that happens to be a consistent header is read as an item; only damage leaves
that state, never this store's writes or erases. Recovery also follows ESP-IDF
in erasing a published item, on active and full pages, only if its extent is
not wholly marked written: one whose header ESP-IDF accepts but this store does
not serve (an integer with a chunk index, say) is kept, not erased.

Twelve one-page fixtures in `src/hal/nvs_testdata/idf_purged_*.bin` were
written by ESP-IDF's own `Page` code compiled for the host, not by the Zig
encoder. Starting from `idf.bin`, `purge_fixture.cpp` adds a 100-byte string, a
96-byte blob (data chunk and index) whose first payload entry is a CRC-valid
string header spanning the two tail keys after it, and those tail keys. It then
erases the integer, the string, the blob or all three with `Page::eraseItem` and
`DEFAULT_PURGE_AFTER_ERASE`, and saves each page active and after
`Page::markFull`. The `_partial_` pages are the flash contents at the moment the
string's or blob data's purge had zeroed only its header. Eight
`idf_erased_*.bin` pages are the same erases with purging off, as through an
`NVS_READWRITE` handle: the entries marked erased, their bytes kept.

Eight more, `idf_corrupt_*.bin`, start from the same page with the string's
header damaged after it was written, as a bit flip would: `_crc_` flips a CRC
bit, `_span_` changes its span from 5 to 4. ESP-IDF's `Page::load` then repairs
the page; `_repairing_` is the flash at the moment it had erased and zeroed only
the header, its payload still written, and `_repaired_` the page once it
returned. The generator checks that ESP-IDF still reads the tail key, no longer
finds the string, and finishes the interrupted repair with the same bytes.

Five five-page partitions, `idf_blob_*.bin`, come from `blob_fixture.cpp`,
which drives ESP-IDF's `Storage` and `PageManager` on a blank partition: a key,
a 9000-byte blob (format version 2: `BLOB_DATA` chunks 0, 1 and 2 on pages 0, 1
and 2, and a `BLOB_IDX`) and another key (`_written_`); the blob rewritten with
6000 bytes, chunks 128 and 129 on pages 2 and 3 (`_rewritten_`, the old
version erased and purged), and the flash just before that rewrite's index was
written (`_rewriting_`: the old blob intact, the new chunks orphans); then the
blob erased with purging (`_erased_`), and the flash once
`Storage::eraseMultiPageBlob` had erased and zeroed only the index
(`_erasing_`: the chunks orphans). For each partition the generator opens a
fresh ESP-IDF `Storage` on it and checks both keys and the blob it reads (the
first blob for `_rewriting_`, none after the erase).

Twenty-one three-page partitions, `idf_state_*.bin`, come from `state_fixture.cpp`,
each with the `_loaded` partition a fresh ESP-IDF `Storage::init` makes of it.
Seven are in states interrupted ESP-IDF writes leave: a key's entry written but not yet
marked (`torn_entry`); a string's header written and marked, its payload
written but still marked empty (`torn_string`); the same with the page marked
full afterwards by the generator (`full_partial`); a version 1 blob written
with `Page::writeItem` between two keys, active and full (`legacy_blob`,
`legacy_blob_full`); a blob rewritten across pages and reset after the new
index, with another key then written by `Page::writeItem` so that both indexes
stay (`two_indexes`); and a blob rewritten on its own page, reset before the new
index (`tail_chunk`). Init here leaves the first five byte for byte as their
`_loaded` partition and reads what ESP-IDF read. In `two_indexes` both read the
blob the index on the oldest page names: lookups go through pages in sequence
order and take the first match on a page, as `Storage::findItem` and
`Page::findItem` do. A write over or an erase of that key here first erases the
index not read and its chunks, which changes no read, so that new chunks reuse
no live chunk number, and then works on the index read; both are reset after
every flash operation in both modes (`a write or an erase of a key with two blob
indexes takes both, reset anywhere`). Chunks the index read also claims are left
to it (`a write or an erase over two blob indexes that claim the same chunk keeps
the read one's chunk until its turn, reset anywhere`), and an erase of chunks
takes every copy of a chunk number, which only damage or another writer leaves,
so that no copy outlives its index and is read in place of a later write's
chunk (`two blob indexes, each with its own copy of chunk 0: a write or an
erase takes both copies`). In `tail_chunk` ESP-IDF reads neither version: the last
check of `Page::mLoadEntryTable` looks the new last chunk up with any chunk
index and erases the old blob's chunk. This store matches ESP-IDF v5.5.1 for
that state (`components/nvs_flash/src/nvs_page.cpp:697–709`): the old index
becomes incomplete and is erased, then both versions' chunks are removed.
The source-derived host fixture `v5.5.1 loses a same-page blob rewrite reset
before its index` checks absence, the neighboring scalar, and recovery resets.
The committed v6.0.2 binary fixtures retain their original provenance.

Fourteen more start from the version 1 blob: eight `idf_state_legacy_*.bin`
partitions come from ESP-IDF's `Storage` (`write_over_legacy` in
`state_fixture.cpp`), `index_then_legacy` and five more `legacy_*` ones from
`Page::writeItem` (described below).
`Storage::writeItem` looks a blob up by its index, and, finding none, takes
whatever item the key has; it writes a version 2 blob (chunks from 0) and then
erases and zeroes that item. `legacy_blob_rewritten` and
`legacy_blob_full_rewritten` hold the result, on the version 1 blob's active
page or on the page after its full one; `_rewriting` is the flash once the new
index was marked written, before that erase, which ESP-IDF's load then
finishes (on the active page as an earlier item with the same key, on the full
page by `PageManager::load`'s check of the last item, as init here does).
`legacy_blob_erased` is the key erased. `legacy_and_index` is the full-page
`_rewriting` state with another key written after the index, as in
`two_indexes`, so that both versions stay; `legacy_and_index_erased` is that
after one `Storage::eraseItem`, and `legacy_and_broken_index` is
`legacy_and_index` with the index's chunk erased by `Page::eraseItem`, as
damage would lose it. `index_then_legacy` holds a version 2 blob written by
`Storage` and then a version 1 blob of its key written by `Page::writeItem`
after it on the active page. ESP-IDF reads a key's blob index first
(`Storage::getItemDataSize`, `Storage::readItem`) and the version 1 blob only if
there is none, and an erase takes the key's first item, here the version 1
blob on the older page, leaving the index. As with `Page::findItem`
(`nvs_page.cpp` 1128-1134), a blob lookup here that meets another item of the
key first on a page finds nothing on that page and goes on to the next (`a blob
lookup takes a page's first item of the key, as ESP-IDF's Page::findItem does`),
and of two version 1 blobs of a key on different pages it reads the one on the
older page (`the first of two version 1 blobs of a key is read, as ESP-IDF's
Storage::findItem finds it`).

### Init and ESP-IDF's

Init does what ESP-IDF's does, in its order: each page's own repair
(`Page::load`), the newest page's last item against the older pages
(`PageManager::load`), the interrupted reclaim, then the blob checks of
`Storage::init`. Pages are taken oldest first by sequence number, wherever
they lie, and of two with one number the later one in the partition is the
newer (`init orders pages by sequence number, the later of two equal ones
last, as ESP-IDF's PageManager::load does`). The blob cases of `init erases what
the last write replaced, then finishes a reclaim, then judges blobs, in
ESP-IDF's order` catch judging blobs before erasing replacements or finishing
reclaim. Finishing reclaim before erasing replacements is caught by
`init erases the first older copy of the newest page's last item, as
ESP-IDF's PageManager::load does`, case `page being freed: 0`.
The historical v6.0.2 differential results above predate the v5.5.1 tail-chunk
change. The remaining differences are described below and modeled by
`init_diff_idf.py`; those historical runs do not validate the current model.

`PageManager::load`: an item is written before the one it replaces is erased,
so the newest page's last item erases its older copy: on the first older
page where an item has its namespace, key and chunk index, that item if it
has its type too (`Page::findItem` stops at another type). One item at most,
a blob chunk included (`init erases the first older copy of the newest page's
last item, as ESP-IDF's PageManager::load does`). A page being freed is left
out of that search, as ESP-IDF leaves it out.

1. *Tail chunk.* The active-page final-chunk check and subsequent incomplete
   index cleanup match v5.5.1 for a same-page rewrite interrupted before its
   index, as described above. This state is no longer a differential class.
2. *The last index's version 1 blob.* For a last item that is a blob index,
   ESP-IDF's `PageManager::load` also erases a version 1 blob of its key
   (`nvs_pagemanager.cpp` 82-91), whether or not the index reads. Here rules
   3 and 4 decide.
3. *A version 1 blob beside an index that reads* is erased by init. First,
   every index of the key that `Storage::eraseMismatchedBlobIndexes` counts
   incomplete is erased, as ESP-IDF's init does. Then, if the first index
   left reads (each chunk it names, by the first copy of its number, with a
   good CRC, adding up to its size), each version 1 blob of the key is
   erased. ESP-IDF keeps it there and reads the index, until a write or an
   erase of the key takes only the index and the version 1 value comes back;
   it reads the version 1 value at once where that item comes first on the
   index's own page. Only ESP-IDF older than v3.3 wrote version 1 blobs, so
   one is always older than any index of its key.
4. *A version 1 blob beside an index that does not read* (a chunk with a bad
   CRC, or two copies of one chunk number and none of another): init erases
   every index of the key, and the version 1 value is read. ESP-IDF leaves
   it to its reads, which fail and erase what they could not read: the chunk
   with the bad CRC, or the indexes and their chunks.
5. *A key without a version 1 blob keeps its indexes*, except for the active
   page's final-chunk key, whose incomplete indexes are judged as in rule 1.
   A retained index that does not read answers `Corrupt`. ESP-IDF's init
   erases incomplete indexes of every key, and its reads erase failed blobs.
6. *Shared start.* Two indexes of a key with one first chunk number: ESP-IDF
   erases an incomplete one by key and first chunk number, which takes the
   first index with that number, complete or not. Init here erases the
   incomplete one, and by rule 5 only beside a version 1 blob. In
   `legacy_shared_start` both read the same value from other bytes; in other
   such states the values differ.

7. *Unfinished reclaim.* While a page is being freed and the newest page is
   active, this store takes the newest page for that reclaim's unfinished
   copy and skips the `PageManager::load` check above. ESP-IDF runs it,
   erasing what the newest page's last item replaced on a third page, and
   then erases the newest page with that item (`nvs_pagemanager.cpp`
   95-128): both values are lost. No reset in either writer's reclaim
   leaves that state: until the reclaim's destination is activated the
   newest page is full, and both run the check; from then on the newest
   page holds only copies of items on the page being freed, which has no
   older copy on a third page. The script generates it.
8. *Reclaim destination.* In that state both erase the newest page and copy
   the whole page being freed again: this store to the page just erased,
   ESP-IDF to its first free page, the erased one being its last. The same
   pages are left, at other places. Both rules are also pinned by a case of
   `init erases the first older copy of the newest page's last item, as
   ESP-IDF's PageManager::load does`.

Last, as ESP-IDF's `Storage::eraseOrphanDataBlobs` does, init erases every
chunk that no index of its key names.

A read erases nothing here (the table under "NVS store"); an ESP-IDF read
that fails erases what it could not read, which the script counts as a
ninth class. A blob index whose first chunk number is neither 0 nor 128,
which no ESP-IDF writer makes, is read and erased like any other; a write
over it answers `Corrupt` (ESP-IDF: `ESP_FAIL`), since the new blob's chunk
numbers come from the other half of 0 and 128 (`a blob index from another
chunk number than 0 or 128 is read and erased, not written over, and costs no
other item`). A page whose header is damaged is erased at init here; ESP-IDF
leaves it unerased on its free list.

Completeness is ESP-IDF's: each chunk counts for the first index of its key,
in page order and then entry order, whose range holds its number (from its
first chunk number to 127 if that is 0, else to 254), and an index is complete
with as many chunks as it says, adding up to its size. Each index is judged
with every index before it still there, and a key's indexes once, however
many version 1 blobs it has (`init judges a key's blob indexes once, beside
one or two version 1 blobs, reset anywhere`).

The `Page::writeItem` fixtures pin these rules against ESP-IDF's bytes.
`legacy_and_index` loads to the bytes of `legacy_and_index_erased` (rule 3).
`legacy_and_broken_index` and `legacy_two_broken_indexes` (indexes from chunk
128 and from chunk 0, neither with a chunk) load to ESP-IDF's bytes and read
the version 1 value. `legacy_complete_and_broken_index` and
`legacy_broken_then_empty_index` (chunks 0 and 1 and an index of chunk 0, then
an empty blob's index: both chunks count for the first index, none for the
second, which is complete) load to ESP-IDF's bytes with the version 1 item
then erased (their `_v1_erased` partitions) and read the complete index. In
`legacy_overlapping_indexes` (chunk 0 with its index, then chunk 1 with an
index of chunks 0 and 1) both chunks count for the first index, so neither is
complete, though each reads: both go, and the version 1 value is read. In
`index_then_legacy` the active page's repair erases the earlier of two items
of a key, whatever their types (`Page::mLoadEntryTable`, `nvs_page.cpp`
782-811): the index goes and the version 1 value is read.

Tests, beside those named above: `a version 1 blob next to a complete blob
index of its key is erased at init, unlike ESP-IDF` (also after a reclaim);
`beside a version 1 blob, init erases the key's indexes if the first does not
read, and else the version 1 blobs` (rule 4 with a missing chunk and with a
bad chunk CRC, rule 3 with two version 1 blobs); `init keeps a version 1 blob
beside an incomplete blob index and erases the index, reset anywhere`; `a blob
index is complete with its chunk on another page, and init then erases the
version 1 blob`; `beside a version 1 blob, init erases the indexes ESP-IDF's
load erases, judged as ESP-IDF judges them` (the fixtures above, one reset
after each of init's flash operations); `init judges a version 1 blob's index
by the chunks of its key, namespace and half only`; `init adds a version 1
blob's chunk sizes beyond 16 bits`; `init credits a chunk to the first blob
index whose range holds it, to the end of its half, on the active page up to
its first blank entry`. A write or an erase takes every index and every
version 1 blob of its key (`a write or an erase of a key with three blob
indexes takes all three`; `a write or an erase takes every version 1 blob of
a key, the one read last, reset anywhere`).

Tests check that init leaves each other partition as its `_loaded` one and
reads what ESP-IDF read (`legacy_complete_and_broken_index`,
`legacy_broken_then_empty_index` and `legacy_shared_start` as above), that this
store's own write over and erase of the
version 1 blob leave ESP-IDF's `_rewritten` and `_erased` bytes (through a
purging handle, as `Storage` with its default purge), and reset that write and
that erase after every flash operation, whole or cut short, in both modes: the
old or the new value is read, and once the new one is, the version 1 item is
gone.

Regenerate all of them with
`python3 src/hal/nvs_testdata/generate_fixtures.py <esp-idf checkout> [output-dir]`: it compiles
unmodified `nvs_page.cpp`, `nvs_types.cpp`, `nvs_item_hash_list.cpp` and the
Linux ROM CRC (with `nvs_pagemanager.cpp` and `nvs_storage.cpp` for the blob
and state partitions, the latter without the host-only `Storage::debugCheck`)
with three host-only header shims, in a temporary directory under
the port's `.zig-cache`; ESP-IDF is only read. ESP-IDF v6.0.2 with
g++ 15.2.0 reproduces the committed files byte for byte. `zig build test` needs
neither: it embeds the pages.

Tests open every fixture as the active and as a full page, check every
surviving value and the erased keys' absence, and check that recovery wrote
nothing to the purge fixtures and left each damaged-header fixture byte for byte
as `_repaired_`, ESP-IDF's own repair. They then reclaim each page into the
reserve page, check that the fixture's sector was erased, and reopen, write and
reopen again keeping every live key.

The blob partitions are opened and reopened, and must read what ESP-IDF read:
both keys, the blob byte for byte (the 6000-byte one from the chunk numbers its
index starts at, 128) or none, and only the chunks its index names: init drops
the orphans of the interrupted rewrite and erase, as ESP-IDF's
`Storage::eraseOrphanDataBlobs` does. The three that hold a blob are then
filled with live keys until full; in `_rewriting_` and `_rewritten_` that
reclaims pages holding erased entries beside chunks and copies those chunks
(`_written_` has no erased entry to reclaim). The blob still reads back after a
reopen, and is then rewritten by this store and erased, each checked after a
reopen. Evidence: unit tests.

## ESP32-C6 BLE controller and HCI

`hal.radio.bluetooth.Controller.start(allocator)` ports the controller-only
lifecycle from **ESP-IDF v5.5.1**, `components/bt/controller/esp32c6/{bt,ble}.c`,
with NPL backed by `hal.rtos`. It uses the existing pinned `esp-wifi-sys`
revision `7623c8d746b55cd8d9f7473359069aef381b7d3b` (`libble_app.a`, `libbtbb.a`
and `libphy.a`). Its configuration ABI is `0x20250606`; v6.0.2 is incompatible.
The existing Wi-Fi ROM script is retained. No BLE ROM overrides are added.

Select `hal.radio.radios = .{ .wifi = false, .ble = true }`, enable the RTOS and interrupt stack, and register
`bluetooth.interrupt_handler` on interrupt 29, plus the existing radio and RTOS
handlers. This mode rejects `Wifi.init` at compile time; for Wi-Fi and BLE
together select `.{ .wifi = true, .ble = true }` (see the radio selection above).
Wi-Fi's default configuration and PHY lifecycle are unchanged.
Use a 160 MHz PLL CPU / 40 MHz crystal and C6 image-boot target. Startup
rejects other CPU clocks. MicroZig defaults to 80 MHz; these examples explicitly
apply a compile-time `hal.clocks.Config.init_comptime(160_000_000)` through their
`init` override.

The controller and allocator must stay at stable addresses for the whole boot.
The controller is a singleton with one connection. There is no shutdown/restart
API; a failed startup requires reboot. In a BLE-only image the controller
tasks, NPL objects and the `ble_phy` PHY tracking task use the supplied
allocator for this boot lifetime. In a coexistence image only the NPL state
does: the controller tasks and the shared PHY timer node, which does the PHY
tracking, live on the shared heap, and no `ble_phy` task is spawned. NPL
callouts use millisecond resolution; modem sleep remains disabled. The Zig
host implements LE Secure Connections and bonding as described below. The
controller's LP timer runs at 100 kHz; as in IDF's `bt.c` (612-628) its
divider is 399 on chip revision v0.0 and 4 on later revisions, which clock it
from the 500 kHz Wi-Fi power clock (`SOC_BLE_USE_WIFI_PWR_CLK_WORKAROUND`).

`send_command` takes an HCI command header and parameters; `send_acl` takes the
ACL header and payload. Neither includes an H4 packet-type byte. Both copy their
input into controller-owned buffers. `receive(timeout_ms)` returns an owned
packet copy from a 16-packet queue; the C callback releases the controller buffer
immediately. Queue overflow is latched and reported as `ReceiveOverflow`, never
silently dropped. Commands and ACL traffic must obey HCI credits in the host.
Transport calls and receive have a single host owner; packet callbacks never log
or block. Buffers support 255-byte ACL payloads and full-length HCI events.

`selftest_ble_hci` needs no peer or wiring. It checks HCI Reset, Read Local Version,
Read BD_ADDR and LE Read Buffer Size, including completion status and response
length. Output starts after 1.5 seconds and repeats `SELFTEST ble_hci DONE
pass=N fail=M` every three seconds. Evidence: see the per-build counts under
"BLE bench examples" below (at 24ebc5d1: 4/4 in 3 of 3 boots each on the Super Mini ESP32-C6
and XIAO ESP32-C6).

## Minimal Zig BLE host

`bluetooth.host.Host.init(controller.transport())` owns all host state and
allocates nothing. `initialize()` resets HCI, enables the event masks, and
obtains ACL buffer credits. HCI commands and ATT requests are serialized with
two-second procedure deadlines. Longer named-peer scan/connection deadlines
are caller supplied. Number Of Completed Packets replenishes outbound ACL
credits; incoming ACL fragments are reassembled before fixed-channel dispatch.
One task owns the host, including callbacks. Do not reenter the host from its
advertiser callback. A protocol, transport, overflow or procedure error aborts
the application session; reboot before attempting another session.

The observer supports active legacy LE scanning (including scan responses),
public/random addresses, RSSI and complete/short local names from AD structures.
`advertise(name)` exposes GAP Device Name plus service FFF0: FFF1 is a mutable
0–20-byte value with read/write/write-command properties; FFF2 notifies a
little-endian 32-bit counter once a second when its CCCD is enabled.
`notify()` sends one notification on demand under the same permission check
and returns false when it withholds it. Call
`poll()` and `tick()` regularly. Disconnect clears the subscription and counter;
call `resume_advertising()` to accept another peer. CCCD state is per connection,
not persisted.

The central actively scans for an exact advertised name, connects, discovers
FFF0 and its FFF1/FFF2 declarations and FFF2's CCCD, then offers `read`, `write`
and `subscribe`. It does not assume peer handles. Discovery supports 16-bit
service/characteristic UUIDs and skips unrelated 128-bit UUID entries. The
host uses ATT MTU 23, one connection and one ATT bearer; values longer than 20
bytes, queued/reliable writes, dynamic L2CAP channels, extended advertising,
controller privacy/resolving lists are unsupported. Security is opt-in; without
`configure_security`, pairing requests receive Pairing Not Supported and no
encryption is initiated. Connection-parameter update
requests on LE signaling are rejected, retaining the negotiated interval.
Notification payloads and counts are available in the host state.

### Pairing, encryption and bonds (SMP)

`bluetooth.host.smp` implements the fixed L2CAP SMP channel (CID 6), LE Secure
Connections in both roles, Just Works, Numeric Comparison and 20-round Passkey
Entry. It requires 128-bit encryption keys. Legacy pairing (SC bit clear) is
rejected with Pairing Failed / Pairing Not Supported (0x05); there is no silent
legacy fallback. OOB, debug keys, CTKD, signing, keypress notifications and
pairing over an already encrypted link are unsupported. Unsupported OOB or
unavailable required authentication returns Authentication Requirements (0x03).
A failed or timed-out procedure requires disconnect before retrying. A 30 s
SMP timeout poisons that SMP bearer until reconnect. One procedure runs per
connection. Before it starts, with or without a restored bond, a Pairing
Request to the peripheral starts pairing and retires the restored key, and a
Security Request to the central starts encryption with a restored key that
meets the required authentication, otherwise pairing (reserved bonding flags
abort). Once it completes, a Security Request to the central is ignored. A
peer's Pairing Failed is ignored in both cases. Any other SMP PDU while no
procedure is outstanding is answered with Pairing Failed and the session keeps
its keys and state: Pairing Not Supported for a Pairing Request to a completed
peripheral, Invalid Parameters for a wrong length, otherwise Command Not
Supported (reason codes: Core v5.4 Vol 3 Part H §3.5.5).

Configure before connecting, after `host.initialize()`:

```zig
const smp = bluetooth.host.smp;
// Keep storage, adapter and all callback contexts alive for the whole session.
var adapter: smp.bonds.Nvs(hal.nvs_flash.Store.Handle) = .{
    .handle = try storage.open("ble_bonds", .read_write_purge),
};
try host.configure_security(.{
    .crypto = bluetooth.security_crypto,
    .store = adapter.interface(),
    .irk = local_irk, // Generate once, persist separately in NVS, reuse on reboot.
});
// Central: uses a bond if present, otherwise pairs. Peripheral: requests security.
try host.secure();
```

`storage` is an initialized `hal.nvs_flash.Store` on a validated named partition
(see NVS above). Store errors propagate as `StorageFailed`; a missing record is
normal. A completed bond is saved once, from the next `poll()`/`secure()`: if the
save fails or is refused, that call returns `StorageFailed`, the link stays
encrypted but unbonded, and later polls process packets normally. If loading
the peer's bond fails at connection, the connection event returns
`StorageFailed` and that connection requires authenticated pairing (fail closed:
the unreadable record may be an authenticated bond). The adapter atomically replaces one versioned NVS blob holding at most
eight bonds. It requires a purging handle, never evicts a peer implicitly, and
reports full/corrupt/unwritable storage as `StorageFailed`. Records contain LTK,
authentication status, peer connection address, identity address and IRK. Local
IRK is application-owned; omitting it disables local identity distribution.
An authenticated bond cannot be replaced by an unauthenticated bond without
explicit removal. A save checks every record whose connection or identity
address matches either address of the new bond; if any is authenticated and the
new bond is not, the save is refused. A save that would merge two
authenticated bonds (its addresses match two different authenticated records)
is refused too, and neither record changes. Otherwise the first match is
replaced and other matches are purged, so no older record can shadow it in a
load. Flash encryption is not supplied by this adapter.

In Secure Connections the LTK is derived with f5 on both sides, **not sent in
Encryption Information / Master Identification PDUs**. Only negotiated identity
keys are sent, over the encrypted link, responder first. HCI LE Enable
Encryption (formerly LE Start Encryption), LTK Request/Reply/Negative Reply,
Encryption Change and Encryption Key Refresh Complete drive the link state.
Secure Connections uses zero Rand/EDIV; other requests get a negative reply.
`host.security` exposes encrypted/authenticated/bonded state and pairing count.
A peripheral loads a bond on connection and answers the controller's LTK
request; a central calls `secure()` to re-encrypt without another SMP exchange.
The adapter also resolves a peer's RPA with stored IRKs using ah; local addresses
remain public, and controller resolving lists/local privacy are not enabled.
The application remains responsible for discovering/connecting to that peer.
When no security procedure is outstanding, a peer Security Request reuses a
cached key only if it satisfies the requested authentication. A MITM request
upgrades a Just Works bond through fresh authenticated pairing; unavailable IO
authentication fails closed. Crossing requests during pairing or pending
encryption are ignored, preserving the outstanding procedure's requirements,
key material and timeout.

Use `host.remove_bond(peer_address)` to purge a bond by connection address,
identity address or matching RPA. Removing a bond does not terminate the current
encrypted link; disconnect afterwards. If only one side removes it, the next
encryption attempt fails (`SecurityFailed`, controller error or disconnect).
There is no automatic re-pairing on missing keys. Remove the remaining side's
bond, disconnect and call `secure()` on a fresh connection to pair explicitly.

For authenticated pairing, supply `io`, `io_fn`, `io_context` and set
`require_authenticated = true`. The IO hook receives `.display` (fresh six-digit
passkey, a notification; the answer is ignored), `.compare` (six-digit number:
answer `.accept` or `.reject`) or `.input` (answer `.passkey` 0..999999 or
`.reject`). Format six digits including leading zeros. The hook runs on the host
task, must not block and cannot call back into the host. Answer `.pending` while
the user decides; the host keeps exchanging packets and asks again on every
`poll()` (at most 20 ms apart while an answer is outstanding, including inside
`secure()`). The peer may need this side's next PDU before its user sees
anything: a Numeric Comparison responder's Pairing Random, or a keyboard
peripheral's Pairing Response, after which the display central chooses the
passkey (Core v5.4 Vol 3 Part H §§2.3.5.6.2–2.3.5.6.3). That reply is queued
before the hook is first asked and transmitted after the hook returns, so the
prompt may appear before the peer has received it. A responder holds an early
DHKey Check until its user accepts (§2.3.5.6.5). The 30 s SMP timeout (§3.4)
keeps running while an answer is pending. If the procedure ends before an asked
`.compare` or `.input` is answered (SMP timeout, the peer's Pairing Failed, a
local abort, an encryption failure or disconnect), the hook receives one
`.cancel` and is not asked that request again: take the prompt down and
discard input typed for it. A request asked after an answer or a `.cancel` is
a new one. `.display` has no withdrawal; follow `host.security` for the
procedure's outcome.
The IO-capability table chooses Numeric Comparison or Passkey Entry; unavailable
required authentication fails closed. Just Works encrypts without MITM
protection and never grants authenticated ATT permissions.

Each server attribute has `server.permissions[handle - 1]`:
`.open` (default), `.encrypted` or `.authenticated`. For example, set
`host.server.?.permissions[bluetooth.host.gatt.value_handle - 1] = .encrypted`
after `advertise()`. Reads, Read Blob, Read By Type and writes enforce permissions
before accessing the value. Insufficient encryption returns ATT 0x0f;
insufficient authentication returns 0x05 (Core Vol 3 Part F §3.2.5).
Write Commands remain response-free and cannot change a protected value.
Encryption loss/disconnect immediately revoke access. Notification permissions
are also checked before emission; discovery of handles and UUIDs remains open.
A frame waiting for ACL credits keeps the security it needs: identity keys
(only sent over the link encrypted with the new key, §2.4.3.2), and ATT
responses or notifications carrying a protected attribute's value. Such a
frame fits in one ACL fragment; after the credit wait, before the frame is
handed to the controller, the host rechecks the link and, if encryption or
authentication was lost during the wait, withholds it
(`host.withheld_protected` counts them). A withheld ATT response is replaced
by an Error Response naming the strictest protected attribute it would have
disclosed (0x0f, or 0x05 for an authenticated attribute); for Read By Type or
Read By Group Type a new request could instead list the open entries before
that attribute. Either way the peer's request is still answered
(Vol 3 Part F §3.3.3); a notification needs no answer and is dropped. Encryption
loss also drops queued SMP PDUs other than Pairing Failed.

Crypto choices: `smp_hardware.zig` uses `hal.ecc` P-256 verify-and-multiply on C6
for fresh public keys and ECDH, with hardware point validation and bounded waits.
`hal.ecc` holds an ownership flag, not a critical section, during the
calculation: controller interrupts stay enabled through each P-256 multiply,
and a concurrent ECC caller receives `error.Busy` (pairing then fails with
`CryptoFailed`).
Private scalars exclude zero, out-of-range values and the debug scalar. Entropy
comes from `hal.rng` through `osi.rand`. C6 TRM v1.2 §26.4 requires an active
SAR ADC or radio ADC for true randomness (see `hal.rng`). ESP-IDF v5.5.1's
[Random Number Generation](https://docs.espressif.com/projects/esp-idf/en/v5.5.1/esp32c6/api-reference/system/random.html)
page for the ESP32-C6 states: "The hardware RNG produces true random numbers so
long as one or more of the following conditions are met: RF subsystem is
enabled. i.e., Wi-Fi or Bluetooth or 802.15.4 Thread/Zigbee are enabled. [...]
If none of the above conditions are true, the output of the RNG should be
considered as pseudo-random only." SMP draws randomness only on a live
connection, after `Controller.enable` has run IDF's BLE PHY bring-up
(`register_chipv7_phy`, full calibration) with modem sleep disabled; this
relies on IDF's documented "Bluetooth enabled" condition and has not been
measured on our boards. The 802.15.4 raw MAC above still makes no entropy claim
for its own hand-ported PHY configuration.
AES-CMAC, f4/f5/f6/g2 and ah use `std.crypto` AES-128/CMAC: this reuses the standard
CMAC construction and portable host-test implementation without repeatedly
masking interrupts and acquiring the hardware AES peripheral for small blocks.
The SMP engine explicitly converts between big-endian crypto inputs (Appendix D)
and little-endian SMP/HCI fields. Secrets are wiped on failure/disconnect;
constant-time MAC comparison is used. Host-side copies are wiped after use: the
TX frame queue and its stack copies, the HCI command buffer (LE Enable
Encryption and LTK Reply carry the LTK), the SMP send queue and popped PDUs, the
reassembled L2CAP SDU and the received transport packet. The controller's own
buffers and the RTOS queue slots in `bluetooth.Controller` still hold transient
copies until reused. The existing `hal.ecc` driver makes no
fault-resistance or constant-time hardware claim.

Controller source/settings are pinned to ESP-IDF **v5.5.1**:

- [`bt.c`, `esp_ecc_gen_key_pair`, `esp_ecc_gen_dh_key`, `s_ext_funcs`,
  `ble_sm_alg_gen_key_pair`, `ble_sm_alg_gen_dhkey`](https://github.com/espressif/esp-idf/blob/v5.5.1/components/bt/controller/esp32c6/bt.c):
  IDF's wrappers gate ECC with `CONFIG_BT_LE_SM_LEGACY || CONFIG_BT_LE_SM_SC`.
  Our `ExtFuncs.ecc_key/ecc_dh` are real C6 hardware implementations with the
  same little-endian ABI. Legacy pairing
  remains disabled in the host. Host SMP computes ECDH directly; it does not
  require HCI Read Local P-256 Public Key / Generate DHKey.
- [`esp_bt_cfg.h`](https://github.com/espressif/esp-idf/blob/v5.5.1/components/bt/controller/esp32c6/esp_bt_cfg.h)
  and [`esp_bt.h`, `esp_bt_controller_config_t`, `BT_CONTROLLER_INIT_CONFIG_DEFAULT`](https://github.com/espressif/esp-idf/blob/v5.5.1/components/bt/include/esp32c6/include/esp_bt.h):
  this ABI has no runtime pairing/SC enable field. No invented config bit or blob
  rebuild is needed. Existing `vhci_enabled = 1`, one connection, ACL buffers,
  3000 authentication-payload timeout and no modem sleep are retained.
- Host HCI event masks now include Encryption Change, Encryption Key Refresh
  Complete and LE LTK Request. These are HCI settings, not `esp_bt_cfg.h` fields;
  see [Core v5.4 Vol 4 Part E](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-54/out/en/host-controller-interface/host-controller-interface-functional-specification.html)
  §§7.3.1, 7.8.1, 7.8.24–7.8.26 and §§7.7.8, 7.7.39, 7.7.65.5.

Evidence: host tests exercise both roles, all three methods, twenty passkey
rounds, IO hooks that answer only after the peer's display (Numeric Comparison
responder, keyboard peripheral or central, early DHKey Check), encryption loss
during an ACL credit wait with identity keys or a protected read response queued,
identity distribution, timeout, malformed/unsupported pairing, confirm
mismatch, DHKey-check failure, HCI encryption/key refresh, LTK replies/negative
replies, and SMP ACL fragmentation under credit pressure. Crypto results match
[Core v5.4 Vol 3 Part H Appendix D](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-54/out/en/host/security-manager-specification.html):
AES-CMAC (all four vectors), f4, f5, f6, g2 and ah. Bond tests use the actual
`hal.nvs.Storage` against in-memory flash, reopen after writes/removal, verify
purging and error propagation, and resolve a changed RPA.

`esp32_c6_selftest_ble_smp` is an image-boot, two-board test. Flash **the same
image** and a valid partition table with a writable named `nvs` partition on both
boards; boot them within 3 s. No wiring. The image holds GPIO3/14 low to power
and select the XIAO's internal RF path (the same assignments as the XIAO board
module / [Seeed hardware overview](https://wiki.seeedstudio.com/xiao_esp32c6_getting_started/));
leave those pins unconnected on the Super Mini. The lower public address becomes
central after both advertise/scan. It checks encrypted-only ATT refusal before
pairing, Just Works encryption, read access afterwards and both stored bonds;
then checkpoints the result in `smp_selftest`, software-resets both boards and
re-encrypts from NVS without pairing. It removes the peripheral's bond, checks
clean encryption failure, removes the remaining bond and pairs on another
connection. `smp_bonds` holds its test bonds; other namespaces are untouched.
A phase marker resumes the second boot; successful completion clears it.
Keep USB Serial/JTAG capture through both boots. Failures also print `diag`
lines with the current step, connection handle/completion status/disconnect
reason, SMP state, encryption/authentication/bond flags, raw HCI encryption
status/enabled byte, and the last ATT RX/TX PDUs and counts. TX records a queued
PDU, not peer acknowledgement. The last transport packet's type, length and
first eight header bytes help identify failures before ATT decoding; for an ACL
continuation fragment only its 4-byte HCI header is kept, so no SMP payload or
key material is logged. Deadline diagnostics copy the fields with scheduling
excluded, then log with interrupts restored. The copy is best-effort: the host
task may have been preempted midway through updating several fields, so
fields can mix two consecutive host states. Peripheral wait steps identify
which central action it awaits. Unexpected read errors retain their original
Zig error rather than being replaced by `Mismatch`.

After automatic role discovery, both boards stop scanning and discovery
advertising. The peripheral configures its encrypted-only GATT permission
before advertising `MZ-SMP-READY`. The central waits for a fresh readiness
report from the selected peer before initiating.

The self-test allows three total attempts per connection, with a 250 ms backoff
only for HCI `0x3e` (Connection Failed to be Established) at Connection Complete
or during the initial ATT probe. ESP-IDF v5.5.1 NimBLE enables connection
reattempts by default on C6 and sets `CONFIG_BT_NIMBLE_MAX_CONN_REATTEMPT` to 3
([components/bt/host/nimble/Kconfig.in:574–585](https://github.com/espressif/esp-idf/blob/v5.5.1/components/bt/host/nimble/Kconfig.in#L574-L585)).
The self-test counts the initial attempt toward its limit to fit the per-boot
deadline. Each retry reports the failed step and HCI status or disconnect
reason. After the probe succeeds, subsequent failures end the test.

Use `-Dsmp_role=auto|central|peripheral` (default `auto`). Forced roles skip the
six-second discovery. Build from `examples/espressif/esp`:

```sh
zig build -Doptimize=ReleaseSmall -Dexample=selftest_ble_smp -Dsmp_role=peripheral
# Flash the XIAO, then build/flash the Super Mini central separately:
zig build -Doptimize=ReleaseSmall -Dexample=selftest_ble_smp -Dsmp_role=central -Dsmp_peer_address=aa:bb:cc:dd:ee:ff
```

`-Dsmp_method=just_works|numeric_comparison|passkey_peripheral_input|passkey_central_input`
(default `just_works`; build both boards with the same value) selects the
pairing method through the IO capabilities: DisplayYesNo on both sides, or
DisplayOnly against KeyboardOnly with the named side typing. Authenticated
methods require MITM, check that pairing, re-encryption and both stored bonds
are authenticated, and print `SELFTEST ble_smp io compare=NNNNNN`,
`io display=NNNNNN` or `io input` on USB Serial/JTAG. Answer each prompt with
a line on that board's console: `yes`/`no`, or the six digits the other board
displayed. Both pairings of a run (first boot and after bond removal) prompt.
A prompt the board withdraws prints `io cancel`; input already received for it
is discarded.
`tools/bench/ble_smp_user.py` (above) answers like such a user.

Use the peripheral's printed public address for `smp_peer_address`; it is optional
in forced mode. Both boards must run this self-test protocol. Start forced-role
runs with fresh `smp_selftest` and `smp_bonds` namespaces on both boards. Auto mode still requires
booting both boards within 3 s.

Discovery uses nonconnectable undirected advertisements (`ADV_NONCONN_IND`) so
both boards can elect their roles before either accepts a connection. Readiness
uses connectable undirected advertisements (`ADV_IND`). Each phase accepts only
its own report type and requires experimental manufacturer ID `0xffff`, magic
`MZSM`, a four-byte random boot nonce and the corresponding readiness byte.
The name is diagnostic only. Auto mode elects using public addresses and retains
the discovery peer's address, exact type and boot nonce for the rest of the boot.
The central rescans before every initiation and requires a fresh ready report
with that identity. Forced mode accepts this payload (optionally also constrained
to `smp_peer_address`, which denotes a public address), then pins its address,
type and nonce for subsequent reconnects. A peer reset during a boot is rejected;
restart both tests. The discriminator prevents accidental bench-peer selection,
not deliberate impersonation. AD payloads include the full diagnostic name.

The connection probe checks the open FFF1 declaration at handle 5 (value
handle 6), then requires ATT `0x0f` (Insufficient Encryption) when reading handle
6. A foreign declaration or unexpected access reports `WrongSelftestGatt`
before security starts. Host tests cover the role handoff, permission setup,
peer selection, HCI initiation parameters, fragmented ATT refusal decoding and
retry limits.

Each check prints PASS/FAIL;
final output is `SELFTEST ble_smp DONE pass=N fail=0` (central N=10, peripheral
N=7). Each boot has a 40 s failure-report deadline, for a total below 90 s.

On hardware on 2026-11-24, a Super Mini ESP32-C6 and a XIAO ESP32-C6 with forced roles
and erased `nvs` before each run, `ble_smp_user.py` answering: each of the four `-Dsmp_method`
values passed 2/2 runs with each board as central (16 runs, `DONE pass=10 fail=0` on the central
and `pass=7 fail=0` on the peripheral). In each of the 16 Passkey Entry pairings the harness typed
the passkey only after it had read the other board's `io display` line.

Central connection creation matches ESP-IDF v5.5.1's pinned NimBLE
[`ble_gap_conn_params_dflt`](https://github.com/espressif/esp-nimble/blob/b45dcedcafb7888174c3567002c36b342ec0b723/nimble/host/src/ble_gap.c)
and [`BLE_GAP_INITIAL_*`](https://github.com/espressif/esp-nimble/blob/b45dcedcafb7888174c3567002c36b342ec0b723/nimble/host/include/host/ble_gap.h):
10 ms continuous initiating scan, 30–50 ms connection interval, zero latency,
2.56 s supervision timeout and zero connection-event length hints.

ATT transactions use the 30 s deadline required by Bluetooth Core v6.0
[Vol 3 Part F §3.3.3](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-60/out/en/host/attribute-protocol--att-.html),
separate from the 2 s HCI command deadline. After an ATT timeout the host rejects
further ATT traffic until a new connection; the caller must disconnect the
fixed bearer. A write may already have taken effect: do not resend it on the
expired bearer. IDF's pinned NimBLE
[`ble_gattc_timer`](https://github.com/espressif/esp-nimble/blob/b45dcedcafb7888174c3567002c36b342ec0b723/nimble/host/src/ble_gattc.c)
also terminates the link after its 30 s timeout. Disconnect waits allow the
negotiated supervision timeout in addition to the HCI command deadline.

Evidence: desktop unit tests of HCI status and credit handling, multi-report
AD parsing, fragmented ATT responses, discovery with non-default handles,
notifications, server permissions, CCCD validation and write commands; the
on-board runs are listed per build under "BLE bench examples" below.

### BLE bench examples

From `examples/espressif/esp`, with the pinned Zig toolchain:

```sh
zig build -Doptimize=ReleaseSmall -Dexample=selftest_ble_hci
zig build -Doptimize=ReleaseSmall -Dexample=ble_scan -Dble_scan_seconds=10
zig build -Doptimize=ReleaseSmall -Dexample=ble_peripheral
zig build -Doptimize=ReleaseSmall -Dexample=ble_central -Dble_peer_name=H2-PEER
```

Each command builds the C6 image-boot target, installed as
`esp32_c6_<example>.bin` and `.elf` under `zig-out/firmware`. `ble_scan`,
`ble_peripheral` and `ble_central` also build for the XIAO ESP32-C6 board as
`xiao_esp32_c6_ble_scan`, `xiao_esp32_c6_ble_peripheral` and
`xiao_esp32_c6_ble_central` (same commands). On a XIAO ESP32-C6 use those board
builds: they power the rf switch in front of the antenna (GPIO3 low, GPIO14
selects the antenna; `boards/xiao_esp32_c6.zig`). `-Dantenna=external` selects
the U.FL connector instead of the ceramic antenna (default `internal`). They use USB Serial
JTAG logging, interrupt 29 for BLE, 30 for shared radio, 31 for RTOS, an 8 KiB
interrupt stack, 32 RTOS priorities with time slicing, and a 160 KiB explicit
controller heap. No GPIO wiring is needed. Run one role at a time.

* `ble_scan` actively scans for N seconds (default 10, range 1–3600), printing
  address, address type, RSSI and AD name for each report. Non-printable name
  bytes become dots. Its count is advertising reports, including duplicates,
  rather than distinct devices. It stops scanning and repeats its summary.
* `ble_peripheral` advertises **MZ-C6**, serves FFF0, and stays running across
  connections. Its self-test marks setup, the first accepted connection, CCCD
  subscription and first notification; then repeats DONE while continuing to
  serve. The notification counter is per connection and encoded little-endian.
* `ble_central` targets **H2-PEER** by default. `-Dble_peer_name` can select the
  Zephyr peer's configured name. It allows 15 seconds each for scanning and
  connecting per attempt, with **three attempts total** and a **250 ms backoff**
  only for 0x3e establishment failures. This includes a 0x3e disconnect during
  initial discovery after the controller reports a handle. Bluetooth Core v6.0
  [Vol 1 Part F §2.59](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-60/out/en/architecture%2C-change-history%2C-and-conventions/controller-error-codes.html)
  defines 0x3e; [Vol 6 Part B §4.5 and §4.5.2](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-60/out/en/low-energy-controller/link-layer-specification.html)
  distinguish connection creation from establishment and specify the initial
  supervision timeout. The retry count and backoff are this bench's policy.
  Other errors (including scan/host timeouts, 0x08 disconnects and ATT errors)
  fail immediately. After discovery it never retries. It reads FFF1, writes and verifies `MZ-C6`, sends
  and verifies a write command `MZ-C6-WNR`, subscribes to FFF2, requires two
  notifications within six seconds, unsubscribes, and disconnects. It leaves
  `MZ-C6-WNR` in the peer's FFF1 value. Each step prints
  `SELFTEST ble_central <step>: PASS|FAIL`; failures include HCI/ATT status.
  Each attempt is logged; the repeated `BLE ble_central attempts=N` info line
  reports attempts used without adding a check. Success still requires all 13
  checks, including discovery and the full GATT sequence on the successful link.
  Before DONE, both success and failure paths close any remaining connection
  and wait one negotiated supervision timeout plus 100 ms with the local link
  stopped, allowing a peer that missed termination to release its link. A
  teardown error prints FAIL and withholds DONE; reset both peers before the
  next run in that case. The original failure diagnostics survive cleanup.

The three role examples start a reporter before controller initialization. It
prints RUNNING or DONE after 1.5 seconds, then every three seconds, so opening
USB late still shows status. Completed tests print `SELFTEST <suite> DONE
pass=N fail=M`; no peer or a failed operation is a FAIL, not a successful empty
central run. A peripheral continues waiting for a peer without marking the
connection tests passed. The peer-free HCI test delays 1.5 seconds before its
checks and repeats DONE every three seconds.

Evidence, image boot, +9 dBm TX power (the IDF v5.5.1 `BT_CONTROLLER_INIT_CONFIG_DEFAULT`
value), against an ESP32-H2 NimBLE peer; the Super Mini ESP32-C6 ran the generic `esp32_c6_*` build
and the XIAO ESP32-C6 the `xiao_esp32_c6_*` board build, except `selftest_ble_hci`, which has no
board build. A count is runs that printed `DONE` with `fail=0`.

| Example | Code | Super Mini ESP32-C6 | XIAO ESP32-C6 |
| --- | --- | --- | --- |
| `selftest_ble_hci` (no peer) | 24ebc5d1 | 4/4 in 3 of 3 boots | 4/4 in 3 of 3 boots |
| `ble_scan` | 24ebc5d1 | 4/4 in 3 of 3 runs | 4/4 in 3 of 3 runs |
| `ble_peripheral`, H2 central | 24ebc5d1 | 6/6 in 3 of 3 runs | 6/6 in 3 of 3 runs |
| `ble_central`, H2 peripheral | 2026-11-20 | 13/13 in 20 of 20 boots | 13/13 in 20 of 20 boots |

In the 40 `ble_central` boots the H2 held no link before each boot and logged one
connection and one disconnect per boot. Three boots (two on the Super Mini ESP32-C6, one on the
XIAO ESP32-C6) used the 0x3e establishment retry, passing on attempt 2 or 3.

Against a XIAO nRF52840 Zephyr peer, Super Mini ESP32-C6, generic build, 2026-11-20:
`ble_peripheral` with the nRF as GATT central passed 6/6 in 3 of 3 runs (the nRF counted
2 connections and 0 failures in each); `ble_central` with `-Dble_peer_name=NRF-PEER` passed
13/13 in 3 of 3 runs, each on the first attempt. In a peer control without a C6, the nRF as central connected to the
H2 peripheral 20 times: all 20 connected, and the disconnect reasons were 0x16 in 18 and
0x3e in 2.

Antenna switch on the XIAO ESP32-C6, `xiao_esp32_c6_ble_scan` with `-Dantenna`, 15 s per
run, counting the H2's adverts, with no U.FL antenna fitted: `internal`
gave medians of -37 and -36 dBm (n=40 and 42) in two runs; `external` gave
-59 and -57 dBm (n=47 and 45). The scans received 462 and 424 adverts from all
advertisers with `internal`, 254 and 247 with `external`. The drop of about
21 dB shows that the option moves the rf switch.

### Known limits

The target is ESP-IDF v5.5.1. The stale-blob state has v5.5.1 parity pinned
by a source-derived host fixture in `nvs.zig`. A stale-copy reclaim
state is handled here: with the newest page full, live `n=3` wins over
`n=1` on the page being freed. Reclaim skips a source item when a newer
page holds its namespace, type, key and chunk index, so the stale value
cannot move after the live one. `reclaim never resurrects a stale scalar
after replacement or reboot` checks the first read, `set(n,4)` followed
by `get(n) == 4`, and repeated boots with and without that replacement.
It also resets recovery at every flash operation, both before the operation
and after a partial write or erase, then checks the live and replaced values.

This deliberately differs from v5.5.1's stale-copy behavior. The recovery
order still follows `PageManager::load`: replacement cleanup, copy, then
source erase (`nvs_pagemanager.cpp:59–118`). v5.5.1 skips the freeing page during replacement cleanup
(`components/nvs_flash/src/nvs_pagemanager.cpp:75–79`), copies its written
items (`nvs_page.cpp:484–523`), and erases only the located old value on a
later write (`nvs_storage.cpp:581–582`), allowing stale `n=1` to resurface.
The copy filter prevents that even for a constructed image of that state.
These are host-unit-test results.

The generated fixtures and the crash/init comparisons above are ESP-IDF v6.0.2
evidence; v5.5.1 parity is pinned by the source-derived host fixtures named here.
Reading v5.5.1's `nvs_page.cpp`, `nvs_pagemanager.cpp` and `nvs_storage.cpp`
finds these differences from v6.0.2:

- v5.5.1 never zeroes erased entries; the purge comparisons above apply to
  v6.0.2 only.
- `PageManager::requestNewPage` activates the destination before marking the
  victim freeing. v6.0.2 and this store do the reverse. By source reading,
  the extra interrupted state (an empty active destination with no freeing
  victim yet) is covered by the source-derived host fixture `v5.5.1 empty
  reclaim destination keeps the source before freeing`
  (`nvs_pagemanager.cpp:166–178`). The copy states are covered by the host
  reclaim reset tests above.
- `Storage::writeItem` searches for an old item of another type by trying
  the possible types, rather than v6.0.2's `ANY` lookup, with the same result
  for states either writer leaves.

What the comparison with ESP-IDF v6.0.2 leaves open, each with the writer
that can leave the state: *own* (this store's writes, reset anywhere),
*ESP-IDF* (its writes, reset anywhere) or *other* (only another writer or
damaged flash). Where no test is named, the writer is argued from the write
order in `nvs.zig` and `nvs_storage.cpp`, not tested.

- Every reset test is a host test; on boards, `selftest_nvs` (12/12 on the C3, Super Mini ESP32-C6
  and XIAO ESP32-C6, 2026-11-20) does not reset during a write. *Own.*
- After a reset in a reclaim, the page copied to again keeps its sequence
  number here (`activate`); ESP-IDF gives it the next one. Page order is the
  same; v5.5.1 `nvs_pagemanager.cpp:202–218` assigns the next sequence.
  The fuzzer has another free page there. *Own, ESP-IDF.*
- A page whose header an interrupted sector erase damaged is erased at init;
  v5.5.1 retains it as corrupt (`nvs_page.cpp:44–79`) and erases it on
  activation (`nvs_pagemanager.cpp:208–212`). *Own, ESP-IDF.*
- A key without a version 1 blob keeps a blob index that is incomplete or
  does not read, and reads `Corrupt` until it is written or erased; ESP-IDF's
  init or read erases it (rule 5). *Other.*
- A version 1 blob beside a blob index of its key is settled at init: erased
  if the index reads, else read and the indexes erased. ESP-IDF keeps it or
  leaves it to its reads (rules 2, 3, 4 and 6). *Other.*
- A read that fails erases nothing; ESP-IDF's erases what it could not read
  (the table under "NVS store"). *Other.*
- With a page being freed and the newest page active, an older copy of the
  newest page's last item is kept, and the reclaim is copied again to the
  page it was using, not to the first free one (rules 7 and 8). *Other.*
- An older page still marked active is marked full; ESP-IDF loads it as an
  active page (`nvs_page.cpp:81–88`). The local rule is unit-tested. *Other.*
- With two pages being freed, init frees only the first. A later write can
  succeed, then the next init takes that active destination as an unfinished
  copy of the second reclaim and erases it, losing the namespace entry and
  keys (`open` returns `NotFound`). ESP-IDF v5.5.1 does the same by source
  reading (`nvs_pagemanager.cpp`, `PageManager::load`, lines 96–128);
  pinned by the source-derived host fixture `v5.5.1 two freeing pages
  complete one per boot`. *Other.*
- A partition with no free page fails init with `NotEnoughSpace` (ESP-IDF:
  `ESP_ERR_NVS_NO_FREE_PAGES`, `nvs_pagemanager.cpp:130–132`); the source-derived
  fixture `v5.5.1 init requires a free page after recovery` covers it. *Other.*
- A write over a blob index whose first chunk number is neither 0 nor 128
  answers `Corrupt`; erase the key first. *Other.*
- The init fuzzer writes whole items on at most three pages of four (its
  list is under "Exhaustive host crash replay"). Partly written items and
  damaged item headers are compared with ESP-IDF by the crash replay's
  cross-check and the `idf_state_*` and damaged-header fixtures only, two
  pages with one sequence number by a unit test only.


### ESP-NOW (C3 and C6)

`hal.radio.espnow` uses the already-linked `libespnow` from pinned
`esp-wifi-sys` revision `7623c8d746b55cd8d9f7473359069aef381b7d3b`.
The reference is [ESP-IDF v5.5.1 esp_now.h](https://github.com/espressif/esp-idf/blob/v5.5.1/components/esp_wifi/include/esp_now.h)
and the [v5.5.1 ESP-NOW guide](https://docs.espressif.com/projects/esp-idf/en/v5.5.1/esp32c6/api-reference/network/esp_now.html)
(sections Security, Initialization and Deinitialization, Add Paired Device,
Send/Receiving ESP-NOW Data, and Config ESP-NOW Power-saving Parameter).
The C bindings supply the receive-info and send-info callback ABI from that header.

Start an enabled Wi-Fi station or SoftAP interface first, with RTOS and the radio
interrupt installed as in the Wi-Fi examples. An AP connection is unnecessary.
Pass the Wi-Fi handle to `Session.init`. It returns `WifiNotStarted` until a start event arrives,
`UnsupportedRadioProtocol` in an IEEE 802.15.4 image, and produces a compile error
in a BLE-only image. In a C6 Wi-Fi + BLE image ESP-NOW runs over Wi-Fi. ESP-IDF
v5.5.1 rates ESP-NOW transmit beside BLE as stable and receive as stable only in
STA mode (`docs/en/api-guides/coexist.rst:38-40, 116-119`), so use the station
interface there. Use one stationary, caller-owned `Session`, from one task;
do not move/copy it, call the vendor ESP-NOW API directly, or stop/reconfigure
Wi-Fi while it owns the radio. `deinit` precedes Wi-Fi stop/deinit, discards the
queues, and removes the vendor peer table. It returns `Busy` without changing
ownership or callbacks while a send awaits completion; it cannot cancel that send.
An already completed delivery may be discarded without polling it.

```zig
const espnow = hal.radio.espnow;
var session: espnow.Session = .{}; // keep at this address until deinit
try session.init(&wifi);
try session.add_peer(.{ .address = espnow.broadcast, .channel = 1 });
try session.send(espnow.broadcast, "hello");
// In the application loop (sleep/yield between polls as appropriate):
if (try session.poll_delivery()) |status| {
    std.log.info("ESP-NOW delivery: {t}", .{status});
}
var frame: espnow.Frame = undefined;
if (try session.poll_receive(&frame)) {
    // frame.source, frame.destination, optional frame.rssi, frame.payload()
}
// Eventually: try session.deinit();
```

The wrapper allocates nothing in send, receive, or polling. Vendor buffer management
can return `OutOfMemory`; Wi-Fi/ESP-NOW initialization still uses the vendor heap.
The session reserves eight 1470-byte receive slots (about 12 KiB including metadata).
Callbacks copy their transient metadata and payload under a critical section.
`poll_receive` copies one frame into caller storage. Overflow drops the **newest**
frame, preserving FIFO order; `dropped_frames` is a saturating counter, reset on init.
Oversized incoming frames are also dropped and counted. RSSI is optional because
`rx_ctrl` may be null; the C3/C6 v5.5.1 `wifi_pkt_rx_ctrl_t` starts with signed
`rssi:8`, which the adapter reads even though Translate-C leaves the bitfields opaque.

`send` accepts one explicit destination, including the broadcast address. It
returns a Zig error for submission failure. One send may be outstanding;
`Busy` persists until `poll_delivery` consumes its separate success/failure slot.
Receive overflow cannot discard a delivery status. The payload may be reused once
`send` returns. A successful delivery is a MAC acknowledgement, not proof of
application receipt or successful decryption; add application acknowledgements
when needed. Poll from a task with an application deadline. If it expires, keep the
session at its original address and Wi-Fi running: `deinit` returns `Busy` until
the completion arrives. Continue polling later, then retry teardown if needed.
If completion never arrives, the radio cannot safely be reused through this API;
reset the device for recovery. The pinned esp-wifi-sys `7623c8d` blob's `mt_deinit`
unregisters callbacks, but `ppUnregisterTxCallback` does not drain transmissions,
so unregistering is not a cancellation boundary.

Peer operations are `add_peer`, `modify_peer`, `remove_peer`, `get_peer`,
`has_peer`, and `peer_count` (total/encrypted). The blob owns the authoritative
table; the wrapper keeps no second copy. Each peer selects `.sta` or `.ap` and
channel 0 (current) or 1–14 (must match the interface channel and country policy).
Add the broadcast peer before broadcasting. There are at most 20 peers; encrypted
capacity follows the Wi-Fi init configuration's `espnow_max_encrypt_num`, currently the pinned
SDK's `CONFIG_ESP_WIFI_ESPNOW_MAX_ENCRYPT_NUM` (7 on C3/C6). The header's legacy
`ESP_NOW_MAX_ENCRYPT_PEER_NUM` macro says 6; the wrapper leaves capacity enforcement
to the blob and propagates `PeerTableFull`.

`set_pmk` takes a 16-byte primary master key. `Peer.lmk` takes an optional 16-byte
local master key: null disables encryption, a key enables it. Both ends need a
peer entry with matching LMKs for encrypted unicast. Broadcast encryption is
rejected. The PMK protects LMKs; applications should provision their own keys.
`Session.version` records the blob's version; `max_payload_len` and
`payload_limit(version)` give 250 bytes for v1 or 1470 for v2. Unknown versions
return `UnsupportedVersion`; empty or oversized sends return `InvalidArgument`.
A local v2 maximum does not establish a remote peer's capability; keep payloads
at most 250 bytes for v1 interoperability.

`set_wake_window(u16)` forwards the header's millisecond wake window setting.
It does not enable modem sleep or establish a wake interval. Other power controls
remain in Wi-Fi; C6 modem sleep is unsupported by this port, as documented above.
No additional ESP-NOW power knob is exposed by this wrapper.

#### Two-board self-test

From `examples/espressif/esp`, build with
`zig build -Doptimize=ReleaseSmall -Dexample=selftest_espnow`.
Image-boot outputs are `esp32_c3_selftest_espnow.bin`,
`esp32_c6_selftest_espnow.bin`, and `xiao_esp32_c6_selftest_espnow.bin`, plus ELFs.
`-Dexample` matches by substring, so the same command also builds the two
`selftest_espnow_coex` images described below.
Use the XIAO board image for its RF switch; `-Dantenna=internal` is the default,
`-Dantenna=external` selects U.FL. Flash the same test to exactly two boards
(chip-specific binary when mixing C3/C6), boot them within ten seconds, and read
both USB Serial/JTAG consoles. No wiring or access point is required.

Discovery broadcasts on channel 1. The lower factory station MAC coordinates
phase changes over broadcast; the other keeps announcing until phase 1 proves
that the coordinator heard it. Discovery allows 22 seconds, including the ten-second
boot gap. Phase requests retry for up to eight seconds, and data/echo exchanges
retry for up to four seconds. Duplicate data requests are echoed again; the follower
stays available for eight seconds after the final phase to repeat a lost ACK.
The mismatched-key probe is sent once in each direction. Each board checks
init, peer add/duplicate/query/modify/count/remove, broadcast receipt,
MAC-delivery failure to an absent locally administered peer, unicast delivery and
application echo, matching-key encrypted unicast and echo, mismatched-key
non-delivery in both directions during a bounded 1.8-second observation,
byte-for-byte maximum payload and echo, and deinit. Encrypted counts and key
round-trips are checked. Demo keys are compiled into this test only.
The two devices must report the same ESP-NOW version to exercise that version's
maximum. Receiver evidence, rather than MAC status, scores the mismatched-key
check. Both the leader and follower must pass; either console alone is insufficient.

The run has a 55-second deadline from each board's entry to main. Results repeat
for late USB attachment, with one `SELFTEST espnow <check>: PASS|FAIL` line per
check and `SELFTEST espnow DONE pass=9 fail=0` on success. Reset both boards for
another run. Host tests exercise FIFO/overflow, send reservations and completions,
peer bookkeeping via a deterministic blob substitute, lifecycle rollback,
argument validation and error mapping. The standalone host test
`zig test examples/espressif/esp/src/selftest_espnow_protocol.zig` exercises
rendezvous with either boot order, a ten-second gap and dropped announcements
and phase requests. Cross-compilation is build evidence only.

| `selftest_espnow` pairing (2026-11-23) | Runs | Result |
| --- | --- | --- |
| Super Mini ESP32-C6 rev v0.2 + XIAO ESP32-C6 rev v0.1, booted together | 3 | `DONE pass=9 fail=0` on both boards |
| Same pair, second board booted 8 s after the first (each board first once) | 2 | `DONE pass=9 fail=0` on both boards |
| ESP32-C3 rev v0.4 + Super Mini ESP32-C6 (C3 follower) | 3 | `DONE pass=9 fail=0` on both boards |
| ESP32-C3 rev v0.4 + XIAO ESP32-C6 (C3 leader) | 3 | `DONE pass=9 fail=0` on both boards |

All runs used the image-boot builds (`esp32_c3_`, `esp32_c6_` and `xiao_esp32_c6_selftest_espnow.bin`,
internal antenna) behind the ESP-IDF bootloader.

`-Dexample=selftest_espnow_coex` builds the same test for the C6 as a Wi-Fi + BLE
image (`esp32_c6_selftest_espnow_coex.bin`, `xiao_esp32_c6_selftest_espnow_coex.bin`).
Each board starts the BLE controller at 160 MHz and advertises `MZ-ESPNOW`,
non-connectable, before Wi-Fi starts. After its ESP-NOW exchange each board
scans for up to 5 s for that name from the peer's public address (the peer's
station MAC plus two in the last octet, IDF v5.5.1
`esp_hw_support/mac_addr.c:16-17,391-397` under the C6 default of four
universal addresses, `port/esp32c6/Kconfig.mac:3,33-40`). The leader finishes
first, so it hears the follower while the follower is still in its final
eight-second ESP-NOW window; the follower then hears the leader, which keeps
advertising for 14 s after its exchange. The follower advertises for 6 s after
its exchange, as long as the leader's scan can last. Each board then stops
advertising with an HCI command; if the test's 55 s run limit ends a board's
advertising early, it logs `run limit cut the advertising hold short`.
Hearing the peer and stopping are the tenth check, `ble_advertising`; the
expected result is `SELFTEST espnow DONE pass=10 fail=0`. A Super Mini
ESP32-C6 (leader) and a XIAO ESP32-C6 (follower) booted together printed
`DONE pass=10 fail=0` on both boards in every run; each board heard the peer
within a fraction of a second of starting its scan, and no board logged a cut
hold. With the
XIAO ESP32-C6 running the Wi-Fi-only `selftest_espnow`, which does not
advertise, the Super Mini ESP32-C6 printed `ble_advertising: FAIL` and `DONE pass=9 fail=1`, and the
XIAO ESP32-C6 `DONE pass=9 fail=0`.
