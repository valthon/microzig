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
| `uart` (UART0/1)                              | yes | yes | `selftest_uart`                                    | 5/5       | 5/5       |
| `twai` (CAN)                                  | yes | yes | `selftest_twai`                                    | 10/10     | 20/20     |
| `rmt` (polling TX/RX)                         | yes | yes | `selftest_rmt`                                     | 3/3       | 3/3       |
| `timer`, `wdt` (timer groups, watchdogs)      | yes | yes | `selftest_timers`                                  | 6/6, 3 runs (24ebc5d1) | 6/6, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `usb_serial_jtag` (logging, RX, confirmed TX) | yes | yes | `selftest_usj`                                     | 9/9 echoes, 3 runs (24ebc5d1) | 9/9 echoes, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `gpio` pin interrupts                         | yes | yes | `selftest_gpio_irq`                                | 8/8       | 9/9       |
| `flash` (erase, write, read)                  | yes | yes | `selftest_flash`                                   | 5/5       | 5/5       |
| `adc` (ADC1), `temperature`                   | yes | yes | `selftest_adc`                                     | 10/10     | 10/10     |
| `ledc` PWM and fades (C6: single-range gamma) | yes | yes | `selftest_ledc_fade` (C3), `selftest_c6_ledc` (C6) | 4/4       | 7/7       |
| `i2c` master                                  | yes | yes | none                                               | see below | built     |
| `i2s` (Philips stereo 16/32-bit; master TX/RX, shared duplex clocks; integer PLL160M dividers; aligned frames ≤4092 bytes, 4088 for 32-bit; owns I2S0 and DMA pair) | yes | yes | `selftest_i2s`, pads 4/5/6, no wiring; EOF probe: RX_EOF_NUM counts bytes (TRM 30.10 says bits) | built only (prior 7/7) | built only (prior 7/7) |
| `parl_io` (1/2/4/8-bit; XTAL master TX, external-clock RX, optional valid; aligned 4..65532-byte frames; owns peripheral and DMA pair) | no | yes | `selftest_parl_io`, valid/software-enable loops, ordered byte comparisons, pads 0–7/10/11, no wiring | n/a | built only (prior 16/16) |
| `dedicated_gpio` (8 CPU signals; exclusive pad/signal ownership, CSR set/clear/read) | yes | yes | `selftest_dedicated_gpio`, pad 4, no wiring | 9/9 | 8/8 |
| `gdma` channel pairs 0–2, SRAM memory copy | yes | yes | `selftest_gdma`; exclusive channels, disjoint SRAM/descriptors, bounded wait | 15/15, 3 runs (24ebc5d1) | 16/16, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `spi` master (SPI2), GDMA channel 0 transfers | yes | yes | `selftest_spi_dma`                                 | 8/8       | 8/8       |
| `clocks.sleep` light sleep                    | yes | yes | `selftest_sleep_s*` (C3), `selftest_sleep_c6_s*` (C6) | see below | s1–s4, s6–s8 on XIAO (3 runs each); see "C6 light sleep and deep sleep" |
| `clocks.sleep` deep sleep                     | no  | yes | `selftest_sleep_c6_s5` (image boot) | n/a | 3/3 on XIAO; see "C6 light sleep and deep sleep" |
| `sigma_delta` (4 channels, signed density, divider 1–256) | yes | yes | `selftest_sigma_delta` | 3/3, 3 runs (24ebc5d1) | 3/3, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `pcnt` (4 units, channel 0, signed 16-bit, polling watchpoints, 10-bit filter) | no | yes | `selftest_pcnt` | n/a | 9/9, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `etm` (50 routes; 8 GPIO event/task groups, no interrupt allocation) | no | yes | `selftest_etm` | n/a | 5/5, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `mcpwm` (timer/operator 0, A/B complementary, count-up, symmetric dead time; owns group) | no | yes | `selftest_mcpwm` | n/a | 6/6, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `radio` (Wi-Fi station)                       | yes | yes | `tcp_server` (image boot)                          | TCP echo  | TCP echo  |
| `radio.ieee802154` (raw MAC, polling)          | no  | yes | `selftest_ieee802154` (image boot, no wiring)        | n/a       | 3/3, H2 and nRF52840 peers |
| `rtos`                                        | yes | yes | `rtos`: expected `DONE pass=6 fail=0`, five ordered items + empty-queue timeout | 6/6, 3 runs (24ebc5d1) | 6/6, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (24ebc5d1) |
| `systimer`                                    | yes | yes | `systimer`: expected `DONE pass=4 fail=0`, four IRQs + three 1 s intervals, TIMG0 reference, +/-100 us | 4/4, 3 runs (2026-11-20) | 4/4, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (2026-11-20) |
| custom CPU/APB clocks                         | yes | yes | `custom_clock_config`: expected `DONE pass=3 fail=0`, CPU/APB register readback at 20 MHz + 100 ms ROM busy delay vs systimer, +/-100 us | 3/3, 3 runs (2026-11-20) | 3/3, 3 runs each on Super Mini ESP32-C6 and XIAO ESP32-C6 (2026-11-20) |

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

I2S diagnostic `rx_eof_num` is a byte count, matching ESP-IDF and the prior
hardware EOF probe. Its bounds require that many RX bytes and duplex TX
bytes, without the obsolete sample-count alternative. The bounds change is
**built only**; prior 7/7 counts predate it.

The USB Serial/JTAG logger waits for the host with the caller's interrupt
state: it masks interrupts only to claim the writer and update its counters,
never while waiting. Each writer drain (64 bytes) waits at most 2 ms for the
host. Callers with interrupts masked and ordinary interrupt
handlers (identified by a nonzero priority threshold) share one 2 ms deadline
per line, plus formatting and FIFO writes. A line that starts while another
is being written (from an interrupt handler or a preempting task) is dropped
rather than interleaved. Once stalled, the logger drops lines immediately
until the FIFO is writable. The next written line reports **at most N** lost
or truncated lines **since the last confirmed report**. This saturating count
is an upper bound: committed packets, including reports, can arrive after a
timeout. Fatal panic/trap handling masks interrupts and takes over an abandoned
writer before logging; the old owner never resumes. Delivery remains best
effort. `write_blocking` confirms host consumption, but its caller must quiesce
logging first; masking interrupts cannot exclude a preempted logger owner.
The same limitation applies throughout `Disconnect.begin`/`finish`.
This logger is host-tested; on hardware it ran on a XIAO ESP32-C6 (rev v0.1),
2026-11-19, with `selftest_wifi_lifecycle` (logger: same code as this tree):
10 of 10 watchdog boots with the port opened 40 s late gave USB output, each
starting with an `at most 25 lines` report. With this logger, `selftest_usj`
(RAM image, host echo script) passed 9/9 echo cases on the C3, Super Mini ESP32-C6 and
XIAO ESP32-C6, 3 runs each, at 24ebc5d1 (2026-11-19). Radio evidence is documented in "BLE bench examples" and "IEEE 802.15.4 raw MAC (C6)".

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
(same code as this tree).

PARL_IO stretches every TX setup clock to factor 65535 before gating it low.
At a 40 MHz XTAL, allow about 2 ms of setup plus frame time in `timeout_us`;
shorter deadlines can expire before transmission. The low check and gating
write exclude interrupts; phase waits do not. `ClockGateFailed` reports a
pad still high after gating. Mid-count divider changes are a hardware
observation from the prior 16/16 tests at divider 40, not a TRM guarantee
(C6 §38.5.1 gives a maximum factor of 65535). The interrupt-safe gating
change is **built only**; those counts predate it.

Timer-group clock enable clears MWDT flash-boot mode only when releasing a
group held in reset, inside a critical section. Calls on an active group do
not unlock, relock or update the watchdog. With this change,
`selftest_timers` passed 6/6 on the C3, Super Mini ESP32-C6 and XIAO ESP32-C6, 3 runs each, at
24ebc5d1 (RAM images, 2026-11-19).

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

### Crypto accelerators

| Crypto driver | Chips | Limits | Evidence |
| --- | --- | --- | --- |
| `sha` | C3, C6 | SHA-1/224/256; CPU, no DMA; synchronous whole-message API, exclusive against DS/HMAC; TRM §23.4.2.1 | `selftest_sha` compares empty, abc, padding boundaries and multi-block input with std.crypto: 21/21 on the C3, Super Mini ESP32-C6 and XIAO ESP32-C6, 3 runs each, at 24ebc5d1 (RAM images, 2026-11-19) |
| `aes` | C3, C6 | AES-128/256 CPU ECB, software CBC/OFB/CTR/CFB8/CFB128 chaining; whole blocks except CFB8, no padding/authentication/DMA, exclusive against DS; TRM §§19.4–19.5 | host `aes/cfb128_vectors.zig` tests pin CFB128 to `std.crypto`; `selftest_aes` SP 800-38A encrypt/decrypt vectors: 24/24 on the C3, Super Mini ESP32-C6 and XIAO ESP32-C6, 3 runs each, at 24ebc5d1 (RAM images, 2026-11-19) |
| `rsa` | C3, C6 | Raw integer operations: modular exponent/multiply 32–3072 bits, multiply 32–1536 bits; odd modulus, caller supplies R², little-endian u32 limbs, bounded polling, exclusive against DS; TRM §§22.3.1–22.3.4 | `selftest_rsa` compares with std.crypto.ff and wide integer multiplication: 12/12 on the C3, Super Mini ESP32-C6 and XIAO ESP32-C6, 3 runs each, at 24ebc5d1 (RAM images, 2026-11-19) |
| `ecc` | C6 only (compile-time gate) | P-192/P-256 affine point verification and verified multiplication; big-endian fixed-size coordinates/scalars, nonzero scalar below group order; no ECDSA/ECDH protocol or Jacobian API; TRM §§20.3.2–20.7 | `selftest_ecc` compares with std.crypto P256 and ff P-192 doubling, including invalid inputs: 7/7 on the Super Mini ESP32-C6 and XIAO ESP32-C6, 3 runs each, at 24ebc5d1 (RAM images, 2026-11-19) |

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

Select `.hal.radio.protocol = .ieee802154` and enable RTOS. The image uses the
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
busy. The ACK watchdog follows IDF's 200 ms fallback. `energy_detect` averages
RSSI over 1–65535 us, and `cca` samples for 8 us.

Limits: no Wi-Fi/BLE coexistence scheduler, CSMA backoff/retries, security,
enhanced ACK generation, multi-PAN, scheduled operations or sleep retention.
Wi-Fi initialization in an IEEE802154 image (and IEEE802154 initialization in a
Wi-Fi image) returns `UnsupportedRadioProtocol`; the default Wi-Fi path retains
its existing behavior. Selecting both `hal.radio.ble` and `.ieee802154` is a
compile error in either init. Outgoing frames are legacy version 0/1 only; received
2015 frames may be inspected but receive no enhanced ACK. Promiscuous RX never
auto-ACKs. Polling has no background queue: the MAC is idle between calls and
frames arriving while the application prints or transmits can be missed.
Every `receive` ends with a stop, so keep windows long and the gaps between them
short; yield between windows so the PHY tracking task runs. With 10 ms windows
`selftest_ieee802154` missed 12 of 164 frames (about 1 in 14) sent every 0.6 s;
with 500 ms windows it missed none of 82.
Legacy ACKs always clear the pending bit; no indirect-data queue is maintained.
All MAC waits are bounded; a stop timeout resets the MAC to end DMA and marks
the handle faulted, requiring `deinit`/`init`. No PHY calibration is saved in NVS.

Evidence: host tests for malformed TX headers and power conversion, all eight
recoverable RX aborts, and a filtered-then-valid frame in one receive window.
On 2026-11-19, `selftest_ieee802154` ran as an uncommitted build on a
XIAO ESP32-C6 (rev v0.1), against an ESP32-H2 `ieee802154_cli` peer:
3/3 self-checks; both ACK-request frames to the H2 acknowledged; 82 of 82 H2
frames received (40 ACK-request, 40 without, 2 broadcast) and all 40 ACKed.
That run also counted 1 CRC error (a frame that failed FCS, not one of the 82).
Against a XIAO nRF52840 (Zephyr 4.5 nRF5 raw driver, standing in for short 0x0001 with the
H2 receiver off), two runs: all 5 C6 frames received by the nRF each run and 4/4 C6 ACK
requests acknowledged. The nRF sent 78 ACK-request frames (4 frames over both runs found
CCA busy at the nRF and were not sent): the C6 received 78 and the nRF saw 77 ACKs; the
missing one is `-35` at the nRF although `receive` returned that frame, which it does only
after ACK_TX_DONE. The C6 received 78 of 78 sent no-ACK and 4 of 4 broadcast frames.
The first of the two runs also counted 1 CRC error; the second counted none.
One run on an ESP32-C6 Super Mini (rev v0.2, generic C6 image) against the same nRF: all 5
C6 frames received and 2/2 ACK requests acknowledged; of 39 ACK-request frames the nRF sent,
the C6 received and acknowledged 38 (the missing one was not received; the run counted 1 CRC
error, so it may have arrived corrupted), and it received 36 of 36 sent no-ACK and 2 of 2
broadcast frames.
A second run set on 2026-11-19 used the same Super Mini ESP32-C6FH4
(rev v0.2, `esp32_c6` image boot; neither peer run counted a CRC error): 3/3 self-checks with no peer listening. Against the H2, 82 of 82 frames were received at -22 dBm, all 40
ACK requests were acknowledged, and the C6's two ACK-request frames were
acknowledged. The H2 received the C6 at -50 dBm; it had received the XIAO board
build at -48 dBm. Against an nRF52840 Zephyr `nrf_154` peer (short 0x0001):
the nRF's ACK-request frames to the C6 were acknowledged 39 of 40 times. The C6
did not log the unacknowledged frame, and logged 80 of the 81 frames the nRF
sent, at a median of -75 dBm (the nRF reported one more frame as channel busy).
The C6 counter `rx=81` includes one frame from another network (a foreign
76-byte broadcast in `hw6-154nrf-sm-n40.log`), in addition to those 80 peer frames.
The C6's two ACK-request frames to the nRF were acknowledged, and the nRF
received the C6 at -69 to -71 dBm.
A third run set on 2026-11-19 used the same Super Mini, `esp32_c6` image boot
with unmasked 2 ms logger drains (no CRC error in either run): 3/3 self-checks. Against the H2, 82 of 82
frames received at -21 to -19 dBm, all 40 ACK requests acknowledged, and the
C6's two ACK-request frames acknowledged. Against the nRF: of 40 ACK-request
frames, the nRF found the channel busy once (`-16`, not sent), 37 were
received and acknowledged, and 2 were neither (`-35` at the nRF, not logged by
the C6); the C6 received 38 of 39 sent no-ACK frames and 2 of 2 broadcasts, at
-84 to -75 dBm (median -79). The nRF received all four C6 frames, both ACK
requests acknowledged, at -74 to -73 dBm.

The uncommitted run has no verified equivalence to this tree. The second set
ran on an earlier version; radio/HAL guards and dependencies, antenna selection, logger
and LP_FAST startup changed since. The third set ran on an earlier version;
logger and LP_FAST startup changed since. The changes since are built only /
unit-tested; these counts do not establish radio behavior in this tree.

`selftest_ieee802154` builds the C6 image-boot target and the XIAO ESP32C6 board
target; on a XIAO use the board build, which powers the rf switch (about 20 dB);
`-Dantenna=external` selects the U.FL connector (default `internal`);
external selection is **built only**, with no hardware run (`antenna-ext.log` is empty).
Its NOTE constants select channel 25, PAN 0x1234, local short address 0x0002 and H2 peer 0x0001.
Configure the H2 IDF `ieee802154_cli` and nRF52840 Zephyr raw shell on that
channel/PAN with distinct addresses. The test first checks energy-detect
completion and a broadcast TX without ACK or CCA (no peer or quiet channel
required). It then listens promiscuously for five seconds and prints each
received frame as `FRAME len=.. lqi=.. rssi=.. <hex>` (MAC bytes without FCS).
Next it sends fixed data frames with/without ACK request to 0x0001, including
CCA, plus a broadcast, printing `TX_DONE`, `ACK_RECEIVED`, `NO_ACK` or `CCA_BUSY`.
It then receives with filtering/legacy auto-ACK enabled. Self-test case lines
and `SELFTEST ieee802154 DONE pass=N fail=M` appear after 1.5 s and repeat every
three seconds, with peer RX/CRC/ACK/CCA/error counters. Missing peers do not fail
the radio-only cases. The test reports only between 500 ms receive windows, so
a report can slip by up to 0.5 s and the interval between reports is 3 to 3.5 s.
The last promiscuous window may start just before the five seconds end, so the
promiscuous phase can overrun by up to 0.5 s.

### Wi-Fi station and RTOS

The optional TX-done callback is built only (host cross-compilation in `compile_wifi` for C3/C6); it has not been run on hardware.

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
passphrase is configured to reject an open AP of the same name. This authentication
policy is **built only**: the evidence logs show build rejections for an invalid auth
name and a missing passphrase, with no open-AP rejection run. A non-`none` value without a
passphrase is a build error. Credentials are embedded in the firmware; the examples do not
log them. The scan logs neighbouring APs' SSIDs, which they broadcast. `-D` values are
also kept in the shell's history and in the build cache (`.zig-cache`), so use a test
network's credentials or clear both. The standalone SoftAP example is described below.
For other build options, see "SoftAP (C3 and C6)", "BLE bench examples"
and "Boards and hardware validation".
On both boards the server scanned, associated with a WPA2 hotspot, got a DHCP
lease and echoed a TCP message on port 3333 (image boot behind the ESP-IDF v6.0.2 bootloader).
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
This self-test is built for C3 and C6 image boot (also C3 direct boot); the C6 rev v0.2 run is
still to do.

C3 rev v0.4, image boot, as a station on a Pico 2 W MicroPython AP (WPA2, channel 6,
CYW43 DHCP server), 2026-11-19:
- `tcp_server`: DHCP lease 192.168.4.16; the AP listed the C3's MAC as a station; the AP's
  first TCP connection after each boot echoed 10/10 lines on port 3333 in 8 of 8 boots.
- `selftest_wifi_lifecycle`: `DONE pass=8 fail=0` in 3 of 3 boots.

A diagnostic build without static RX management buffers (`rx_mgmt_buf_type`, the IDF
default) failed that first connection in 8 of 8 boots: the C3's ARP requests got no 802.11
ACK from about 20 s after boot and Wi-Fi TX later returned `WifiOther`. A diagnostic build with static RX management buffers
passed 4 of 5 boots.

XIAO ESP32-C6 (rev v0.1), `esp32_c6` image boot, 2026-11-19, same AP: `tcp_server` got a
lease and the AP's first TCP connection after each boot echoed 10/10 lines in 8 of 8 boots;
`selftest_wifi_lifecycle` `DONE pass=8 fail=0` in 3 of 3 boots. C6 rev v0.2 was not run.
This ran on an earlier version; Wi-Fi protocol/inactivity argument types and the
optional TX-done callback changed since; the changes since are built only.

#### SoftAP (C3 and C6)

`softap` is a standalone WPA2-PSK/CCMP AP on channel 6, limited to four associated
stations. It uses only WPA2 Personal; open, WEP, WPA/WPA2 mixed, WPA3 and enterprise
modes are not offered by this example. STA and `tcp_server` are unchanged.
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
server, so `src/softap_dhcp.zig` supplies an example-local minimal DHCPv4 server
using lwIP raw UDP on the AP netif. Its four MAC-keyed leases cover
`192.168.4.2`–`192.168.4.5`, last one hour, and advertise the AP as gateway.
Offers reserve a slot for 30 seconds; renew/rebind, INIT-REBOOT, release and decline
are supported (declined addresses are quarantined for one hour). Disconnecting does
not revoke a lease; four different clients can exhaust the pool until release or
expiry. Leases are volatile across reboot. Ethernet clients only: no relays, option
overload, DHCPINFORM, DNS service, routing/NAT or Internet access.

A station should join, acquire a lease, ping `192.168.4.1`, and connect to
`192.168.4.1:7` for TCP echo. Echo serves one connection at a time; an idle client
holds that slot until disconnect. `SOFTAP up ssid=... ip=192.168.4.1` announces
readiness, join/leave lines include MAC and AID, DHCP ACK lines include MAC and leased
IP, and each closed TCP connection reports bytes echoed. A reporter first runs after
1.5 seconds and repeats status every three seconds so late USB reattachment can see it.
Join/leave, lease and connection events themselves are not replayed.

Evidence: DHCP packet logic is host unit-tested. `softap` ran on hardware
(image boot, 2026-11-19) with an ESP32-S3 station using ESP-IDF v6.0.2 `esp_wifi` and the lwIP DHCP
client: on a XIAO ESP32-C6 (rev v0.1), a C6 Super Mini (rev v0.2) and an ESP32-C3 (rev v0.4) as AP, the S3 associated
(WPA2-PSK, channel 6), leased 192.168.4.2, and got 5/5 then 10/10 ping replies from
`192.168.4.1`. TCP echo was not run: the S3 peer image has no TCP client. The XIAO run
used the generic C6 image, not a XIAO board build. This ran on an earlier
version; radio lifecycle/ABI handling, logger and LP_FAST startup changed since;
the changes since are built only / unit-tested.

#### Wi-Fi initialization and limits

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
calibration timeout returns `SlowClockCalibrationTimeout`. These lifecycle changes are built only.
C6 startup follows ESP-IDF v6.0.2 `bootloader_init_mem`: it disables the HP_APM,
LP_APM0 and LP_APM access-path filters and puts all implemented HP masters and the
LP CPU in TEE mode (C6 TRM v1.2 §§16.3.1, 16.3.2.3, 16.4). This covers Wi-Fi M4
and SPI/GDMA M16; drivers no longer change their modes. Region permissions stay
unchanged. Modem ICG maps follow IDF v6.0.2 `initial_gating_mode`, with BT and
IEEE802154 enabled in ACTIVE only. These startup changes are built only. The Wi-Fi blobs take `vsnprintf` from
libprintf.a: the ROM's printf and stdio functions need a newlib syscall table that MicroZig does
not install. C6 links the unmodified IDF v6.0.2 `rom.libc` and
`rom.libc-suboptimal_for_misaligned_mem` scripts, excluding `rom.newlib` and
`rom.newlib-normal`. C3 maps only memory/string primitives and `abs` from libc,
with no reent-dependent libc bindings. The OS adapter uses an ASCII
comparison for `strcasecmp`. This linker split is built only.
The C6 radio ROM bindings follow ESP-IDF v6.0.2, including its disabled node-search
bindings so the matching blob supplies them. Both chips use the IDF 64-bit seconds
layout for the supplicant clock. These type/layout checks are built only.
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
`wait_for_host` true after 3 us. C6 evidence is recorded below.

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
  source, not EXT1. The HAL validates LP mux ownership, consumes EXT1 status,
  and restores the previous EXT1 selection. It does not reconfigure pads. An already asserted
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
raw source bits and EXT1 pin status. Boot wake flags are zero for other reset reasons. Reserve LP
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
SRAM recovery marker. This is a recovery provision, not hardware evidence that it works.
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
python3 examples/espressif/esp/tools/sleep_c6_idf_reference.py --check --idf /home/valthon/esp/esp-idf-v5.5.1
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
The marker and milestone record are diagnostic evidence only; verify retained bytes and reset recovery
on the boards before relying on the bench watchdog.

Hardware evidence, all on one ESP32-C6 XIAO (rev v0.1), image boot, with bench
recovery enabled, 2026-11-19, using `selftest_sleep_c6_s*` and
`selftest_sleep_c6_regs`. In the initial timer-measurement build, s2 returned in 4 of 4 runs with LP timer wake
**0x10**, no hang and no RWDT reset, but the old `timer_100ms` check failed in
all four: `ticks=31413, 31533, 31526, 31416` and `active_us=147366, 148139, 148020,
147253`. Three register-probe runs taken alongside them each matched compiled
ESP-IDF v5.5.1 on all 248 rows; a separate probe build reported
pass=253. With a timer check without the 99% bound and setup ceiling: s2 passed 2/2 in 2 of 2 runs (`setup_us` about
19.8 ms, `stopped_us` about 80.6 ms of a 100 ms request), and in 3 of 3 runs each
s1 (guards) 3/3, s3 (retention at 100/250/500 ms) 4/4, s4 (EXT1 GPIO wake via the
LP core) 2/2 and s6 (USB reconnect and nonce echo) 13/13.
Deep sleep (s5) hung with that build. These ran on earlier versions; timer
checks, PMU tables, LP_FAST startup and logger changed since; the changes
since are built only / unit-tested except where the matching-tree runs below
exercise them. The tightened timer check ran in those matching-tree runs.

In the initial timer-measurement build, `ticks` counts LP_SLOW_CLK over the
entire call, including restoration;
`active_us` is stall-sensitive SYSTIMER UNIT1 ticks divided by 16 over that same call,
including PMU initialization, calibration and USB reattachment. Neither value measures
only sleep; that output omits the measured LP frequency needed to convert ticks.
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
on XTAL as described above. Bench mode deliberately changes watchdog sleep policy. Evidence:
XIAO ESP32-C6 (rev v0.1), `esp32_c6` image boot, 2026-11-19,
same code as this tree, 3 runs per stage, armed
by the host: s1 3/3, s2 2/2, s3 4/4, s4 2/2, s5 (deep sleep: reset, timer wake, LP memory) 3/3,
s6 13/13, s7 (RWDT reset 3 s into a 10 s light sleep, `recovered_hang: PASS reset=0x10`) 1/1 and
s8 (XTAL-off light sleep with LP_FAST on RC_FAST) 4/4 in every run; no hang. The register probe
showed would-write equal to the IDF-derived value on all 284 rows in a
separate run on 2026-11-19. That probe ran on an earlier version; logger
and panic handling changed since; the changes since are built only / unit-tested.
Not run on the Super Mini or the C6 rev v0.2.

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
`selftest_lp_uart` verifies 64 looped-back bytes and empty-RX timeout on
both cores without touching pads. Evidence: **built only**.

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
External devices need suitable pullups. `selftest_lp_i2c` uses weak internal
pulls on an unwired bus, requires 112 NACKs on each core, exercises read/
write NACKs and checks the next probe recovers. Evidence recorded 2026-11-18:
`selftest_lp_i2c` passed 5/5 three times on each of the Super Mini
ESP32-C6FH4 (rev v0.2) and XIAO ESP32-C6 (rev v0.1). This ran on an earlier
version; preserving NACK on STOP timeout, rejecting unsent-TX completions,
LP_FAST startup and logger changed since; the changes since are built only.
The other LP examples above have build evidence only.

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
Limits: default table offset only, at most 95 entries, no decryption. Partition
flags are retained for callers to enforce. Evidence: built only, unit-tested;
no board execution. Format reference: ESP-IDF
`components/partition_table/gen_esp32part.py`.

## NVS format

`hal/nvs_format.zig` implements version 2 headers, entry layout, ROM-compatible
CRC32, span validation, bitmap iteration and a fixed-size page hash map. Bucket
collisions require a full key comparison. No allocation or target imports.
Evidence: built only, unit-tested, including an ESP-IDF-generated page image.
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
bytes without NULs. The store allocates nothing, owns a 4 KiB page buffer and a
page hash index, and must not be copied after handles are opened. Serialize all
calls in task context; do not use from interrupts. Reinitialize after flash I/O
errors. Initialization repairs interrupted writes/reclaims, discards invalid
entries and erases pages with invalid headers; it can write even if the next
namespace handle will be read-only. Preserve a backup of irreplaceable data.
Page sequence exhaustion reports `NotEnoughSpace` rather than wrapping.

Evidence: unit-tested, and on hardware as below. Host tests cover all integer widths, namespace
isolation, commit/reopen/erase, full partition and reclaimed space, multi-page
blobs, failed replacement preserving the old value, maximum strings, corrupt
payload CRC, and power loss after each operation in a rollover workload. The
ESP-IDF fixture is read, modified and reopened through the store. The board
self-test (below) ran on hardware on an earlier version of this store; the
changes since are unit-tested only. References: ESP-IDF `components/nvs_flash/src/nvs_types.*`,
`nvs_page.*` and `nvs_pagemanager.cpp`. Derived code credits
`totorototo`'s MicroZig implementation in source.

### NVS board self-test

Build `examples/espressif/esp` with `zig build -Doptimize=ReleaseSmall
-Dexample=selftest_nvs`. Outputs `esp32_c3_selftest_nvs.bin` and
`esp32_c6_selftest_nvs.bin` (and ELF files); only ESP-IDF image-boot targets are
registered. No external wiring is required. Use an existing ESP-IDF bootloader
and partition table at `0x8000` with an unencrypted writable data/NVS partition
labelled `nvs` (at least 12 KiB). Install the app at the table's app offset with
the usual image-boot procedure. This example neither installs a table nor
formats a missing partition; invalid/missing tables report failure before NVS
writes. Back up existing data before running a flash-write self-test.

The self-test reserves namespace `mz_selftest`; it writes all integer widths,
a string, a 6000-byte multi-page blob, and 300 counter updates, commits, reopens,
checks values, erases its test keys, then reopens to verify absence. A final
`boots_increment` case increments the u32 key `boots`, commits, reopens and reads it back;
This case checks the increment and same-boot reopen, not persistence across boots.
`boots` is never erased, so `SELFTEST nvs boots=N` must rise by one on each
reboot without reflashing (the host compares the two boots). Store initialization may repair pages and garbage
collection may move other keys **within the named NVS partition**; application,
bootloader and other partitions are never write targets. Keys in other
namespaces are preserved. If interrupted, test keys may remain until a successful
rerun. USB Serial/JTAG logs repeat `SELFTEST nvs <case>: PASS|FAIL` and
`SELFTEST nvs DONE pass=N fail=M`; the flash operations run once per boot.
Evidence: the 2026-11-19 run records show `selftest_nvs` ran by image boot
on an earlier version on a Super Mini ESP32-C6 (rev v0.2), a XIAO ESP32-C6 (rev v0.1) and an ESP32-C3 (rev
v0.4): 8/8 on each, with `boots=1` after flashing and `boots=2` after a
watchdog reset. The run records identify an uncommitted build; no equivalence
to this tree is claimed. That example called the boot-count case `persist`.
Open modes, blob/reclaim/recovery handling and the `boots_increment` case name
have changed since; the changes since are built only / unit-tested.

The board workload also runs twice against a simulated minimum 12 KiB partition
in host tests, with guard pages and an unrelated namespace checked after
reclaim and erase. This is unit-test evidence, not board execution.

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
Every case reopens, verifies all completed keys and permits only the old/new
value of the in-flight key, then writes another key, reopens again and verifies
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
tests only; no board execution.

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
check of `Page::mLoadEntryTable` (`nvs_page.cpp` 814-827) looks the new last
chunk up with any chunk index and erases the old blob's chunk. This is a
deliberate difference: this store does not repeat that loss and reads the old
blob, from ESP-IDF's partition and from its own crash images in the same state
(the 12 above, 6 per mode). The test `a rewrite's last chunk next to an old chunk keeps the
old blob, unlike ESP-IDF` pins it.

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
Init differs in the eight ways
listed here, each a class of `init_diff_idf.py` (above), and in no other way
that script finds.

`PageManager::load`: an item is written before the one it replaces is erased,
so the newest page's last item erases its older copy: on the first older
page where an item has its namespace, key and chunk index, that item if it
has its type too (`Page::findItem` stops at another type). One item at most,
a blob chunk included (`init erases the first older copy of the newest page's
last item, as ESP-IDF's PageManager::load does`). A page being freed is left
out of that search, as ESP-IDF leaves it out.

1. *Tail chunk.* On the active page, ESP-IDF's load erases the first chunk of
   the key of a last item that is a chunk (`nvs_page.cpp` 814-827), which loses
   both versions of a blob rewritten on one page and reset before its index.
   This store keeps the chunk and reads the old blob (`tail_chunk`, above).
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
5. *A key without a version 1 blob keeps its indexes*, whatever their state,
   and reads `Corrupt` from one that does not read. ESP-IDF's init erases an
   incomplete one and its read erases one with a missing or too long chunk.
   This store's own writes leave no such index, reset
   anywhere: chunks are written before their index and erased after it.
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
reopen. Evidence: built only, unit-tested; no board execution.

## ESP32-C6 BLE controller and HCI

`hal.radio.bluetooth.Controller.start(allocator)` ports the controller-only
lifecycle from **ESP-IDF v5.5.1**, `components/bt/controller/esp32c6/{bt,ble}.c`,
with NPL backed by `hal.rtos`. It uses the existing pinned `esp-wifi-sys`
revision `7623c8d746b55cd8d9f7473359069aef381b7d3b` (`libble_app.a`, `libbtbb.a`
and `libphy.a`). Its configuration ABI is `0x20250606`; v6.0.2 is incompatible.
The existing Wi-Fi ROM script is retained. No BLE ROM overrides are added.

Select `hal.radio.ble = true`, enable the RTOS and interrupt stack, and register
`bluetooth.interrupt_handler` on interrupt 29, plus the existing radio and RTOS
handlers. This mode rejects `wifi.init` at compile time: simultaneous Wi-Fi/BLE
is unsupported. Wi-Fi's default configuration and PHY lifecycle are unchanged.
Use a 160 MHz PLL CPU / 40 MHz crystal and C6 image-boot target. Startup
rejects other CPU clocks. MicroZig defaults to 80 MHz; these examples explicitly
apply a compile-time `hal.clocks.Config.init_comptime(160_000_000)` through their
`init` override.

The controller and allocator must stay at stable addresses for the whole boot.
The controller is a singleton with one connection. There is no shutdown/restart
API; a failed startup requires reboot. Controller tasks, NPL objects and PHY
tracking use the supplied allocator for this boot lifetime. NPL callouts use
millisecond resolution; modem sleep and pairing/secure-connections crypto are
disabled. This does not implement SMP or bonding.

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
little-endian 32-bit counter once a second when its CCCD is enabled. Call
`poll()` and `tick()` regularly. Disconnect clears the subscription and counter;
call `resume_advertising()` to accept another peer. CCCD state is per connection,
not persisted.

The central actively scans for an exact advertised name, connects, discovers
FFF0 and its FFF1/FFF2 declarations and FFF2's CCCD, then offers `read`, `write`
and `subscribe`. It does not assume peer handles. Discovery supports 16-bit
service/characteristic UUIDs and skips unrelated 128-bit UUID entries. The
host uses ATT MTU 23, one connection and one ATT bearer; values longer than 20
bytes, queued/reliable writes, dynamic L2CAP channels, extended advertising,
privacy/resolving lists, pairing/SMP, encryption and bonding are unsupported.
Pairing requests receive Pairing Not Supported. Connection-parameter update
requests on LE signaling are rejected, retaining the negotiated interval.
Notification payloads and counts are available in the host state.

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
`ble_peripheral` and `ble_central` also build for the XIAO ESP32C6 board as
`xiao_esp32_c6_ble_scan`, `xiao_esp32_c6_ble_peripheral` and
`xiao_esp32_c6_ble_central` (same commands). On a XIAO use those board
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
  connecting, discovers handles, reads FFF1, writes and verifies `MZ-C6`, sends
  and verifies a write command `MZ-C6-WNR`, subscribes to FFF2, requires two
  notifications within six seconds, unsubscribes, and disconnects. It leaves
  `MZ-C6-WNR` in the peer's FFF1 value. Each step prints
  `SELFTEST ble_central <step>: PASS|FAIL`; failures include HCI/ATT status.

The three role examples start a reporter before controller initialization. It
prints RUNNING or DONE after 1.5 seconds, then every three seconds, so opening
USB late still shows status. Completed tests print `SELFTEST <suite> DONE
pass=N fail=M`; no peer or a failed operation is a FAIL, not a successful empty
central run. A peripheral continues waiting for a peer without marking the
connection tests passed. The peer-free HCI test delays 1.5 seconds before its
checks and repeats DONE every three seconds.

Evidence on two C6 boards, a XIAO ESP32-C6 (rev v0.1) and a Super Mini
ESP32-C6FH4 (rev v0.2), against an ESP32-H2 NimBLE peer and a XIAO nRF52840
Zephyr peer. "Generic" is the `esp32_c6_*` chip build, "board" the
`xiao_esp32_c6_*` build (on the XIAO, only the board build powers the rf
switch). All runs below are dated 2026-11-19. A count is runs that printed `DONE`
with `fail=0`. The 0 dBm builds use the initial TX-power setting; the +9 dBm
builds use IDF v5.5.1's default (`BT_CONTROLLER_INIT_CONFIG_DEFAULT`).
"Initial" and "diagnostic" distinguish the recorded +9 dBm run sets.
Every committed build below ran on an earlier version. Since the 0 dBm runs,
TX power, controller interrupt/protocol guards, antenna selection/reporting,
logger and LP_FAST startup changed. Since the initial +9 dBm runs, the same
items except TX power changed. Since the diagnostic +9 dBm runs, logger and
LP_FAST startup changed. The changes since are built only / unit-tested.
Rows marked "an uncommitted build" have no verified equivalence to this tree.

XIAO ESP32-C6, all at 0 dBm:

| Example | Build (source) | Peer | Result |
| --- | --- | --- | --- |
| `selftest_ble_hci` | generic, an uncommitted build, two different images | none | debug image c6e74a305fa93b30: 4/4, 1 run; earlier a50cb04be3d6b298: `ControllerFailed` at init (0 pass, 1 fail), 1 run |
| `ble_scan` | generic, 0 dBm initial | advertisers incl. the H2/nRF | 4/4 checks, 2 of 2 runs |
| `ble_scan` | board, 0 dBm board | advertisers incl. the H2/nRF | 4/4 checks, 1 of 1 run |
| `ble_peripheral` | generic, 0 dBm initial | H2 central | 6/6, 1 of 1 run |
| `ble_peripheral` | generic, 0 dBm initial | nRF central | 6/6, 1 of 1 run |
| `ble_peripheral` | board, 0 dBm board | H2 central | 6/6, 1 of 1 run |
| `ble_central` | generic, 0 dBm initial | H2 peripheral | 13/13, 1 of 1 run |
| `ble_central` | generic, 0 dBm initial | nRF peripheral | 13/13 in 1 of 5 runs |
| `ble_central` | generic, an uncommitted build | nRF peripheral | 13/13 in 7 of 13 runs |
| `ble_central` | board, an uncommitted build | nRF peripheral | 13/13 in 8 of 8 runs |

Every failed central run against the nRF stopped at `discover` with
`Disconnected`. The first four failures came from a build that predates the
reason field; every later failure shows `disconnect_reason=3e`, Connection
Failed to be Established. The
current board build of `ble_central` has no committed-build hardware
evidence against the nRF. The central's nRF reliability with the generic build is a known
failure, not a pass.

Super Mini ESP32-C6FH4, generic build:

| Example | Build (source), TX power | Peer | Result |
| --- | --- | --- | --- |
| `selftest_ble_hci` | initial, 0 dBm | none | 4/4 checks, 1 run |
| `ble_scan` | initial, 0 dBm | advertisers incl. the H2/nRF | 4/4 checks, 1 run |
| `ble_central` | initial, 0 dBm | nRF, all advertising channels | 13/13 in 7 of 12 runs |
| `ble_central` | initial, 0 dBm | nRF on channel 37 / 38 / 39 only | 4 of 4 / 4 of 10 / 4 of 4 runs |
| `ble_central` | an uncommitted build with +9 dBm | nRF on channel 38 only | 9 of 10 runs |
| `ble_central` | initial, +9 dBm | nRF, all advertising channels | 6 of 6 runs |
| `ble_central` | initial, 0 dBm | H2 | 1 of 6 runs |
| `ble_central` | initial, +9 dBm | H2 | 1 of 6 runs |
| `ble_central` | an uncommitted build, image 055cb9e63773dc83, 0 dBm (riram set) | H2 | 3 of 6 runs |
| `ble_central` | an uncommitted build, image d062a24e16611a44, +9 dBm (rp9 set) | H2 | 3 of 6 runs |
| `ble_peripheral` | initial, 0 dBm | H2 central / nRF central | 6/6 in one C6 log; separate H2 run/connection not confirmed by that C6 evidence |
| `ble_peripheral` | initial, +9 dBm | H2 central / nRF central | 1 of 1 / 0 of 2 runs |
| `selftest_ble_hci` | diagnostic, +9 dBm | none | 4/4 checks, 1 run |
| `ble_scan` | diagnostic, +9 dBm | 10 advertisers incl. the H2 | 4/4 checks, 1 run |
| `ble_peripheral` | diagnostic, +9 dBm | H2 central / nRF central | 1 of 1 / 0 of 1 run |
| `ble_central` | diagnostic, +9 dBm | nRF, all advertising channels | 8 of 11 runs |
| `ble_central` | diagnostic, +9 dBm | H2 | 6 of 10 runs |

In the diagnostic +9 dBm run set, `ble_scan` counted 219 reports in 10 s, 83 of them from the H2
at a median of -36 dBm. In the `ble_peripheral` run with the nRF as central,
the nRF's first connect ended with 0x3e, so its GATT sequence found no link;
its scripted reconnect only reads, and the C6 stopped at 4/6 (connection
passed, no subscription). Of the three
failed central runs against the nRF, two ended in `discover` with 0x3e (in one
the nRF never received the CONNECT_IND, in the other it did) and one in
`discover: FAIL Timeout` with the link still up on both sides; that timeout
did not recur in the other ten runs. In every failed central run against the
H2, the H2 logged no connection and the C6 reported 0x3e.

At 0 dBm the nRF received the Super Mini's adverts at a median of -75 dBm,
against -65 dBm at +9 dBm. In each failed channel-38 run at 0 dBm the nRF
never accepted the CONNECT_IND, which is sent only once.

Open, not passes:

* `ble_central` against the H2 passed 1 of 6 on each committed build
  (initial 0 dBm and initial +9 dBm), with no H2 connection and C6
  reason 0x3e in their failed runs. Two uncommitted builds
  each passed 3 of 6: image 055cb9e63773dc83 at 0 dBm (riram set), and
  d062a24e16611a44 at +9 dBm (rp9 set). The latter's run rp9-1 connected
  but failed command readback with an ATT timeout, rather than 0x3e.
  A single nRF-central/H2-peripheral control set (`hw6-ble-ctrl-nrf2h2-nrf.log`)
  passed 6 of 10 (failed 4 of 10); the cause is not yet located on either side.
* With the diagnostic +9 dBm build `ble_central` against the H2 passed 6 of 10; in every
  failed run the H2 logged no connection and the C6 reported 0x3e. A second
  nRF-central/H2-peripheral control failed 3 of 10, so the cause is not located
  on the C6 side.
* With the Super Mini as peripheral, the nRF formed a link in 3 of 10 repeated
  connects at 0 dBm and 2 of 10 at +9 dBm; every other attempt ended with
  0x3e. Cause unknown.
  With the diagnostic +9 dBm build, two sets of
  10 gave 1 and 8, and the H2 as central 10 of 10. Every other attempt ended
  with 0x3e, a rate that varies between sets far more than between builds; the
  nRF-to-H2 control above fails at a similar rate. Setting the controller's LP
  timer divider to 4 on chip revisions above v0.0, as IDF's bt.c does with
  `SOC_BLE_USE_WIFI_PWR_CLK_WORKAROUND`, gave 7 and 8 of 10 in sets run
  alternately with the 1 and 8 above (uncommitted experiment): no measurable
  difference. The driver keeps divider 399.
* The +9 dBm default has run only on the Super Mini; the XIAO results above
  predate it.

### Known limits

The target is ESP-IDF v5.5.1. All fixture generation, crash cross-checks and
init differential runs described above used v6.0.2; none ran against v5.5.1.
Reading v5.5.1's `nvs_page.cpp`, `nvs_pagemanager.cpp` and `nvs_storage.cpp`
finds these differences from v6.0.2:

- v5.5.1 never zeroes erased entries; the purge comparisons above apply to
  v6.0.2 only.
- `PageManager::requestNewPage` activates the destination before marking the
  victim freeing. v6.0.2 and this store do the reverse. By source reading,
  the extra interrupted state (an empty active destination with no freeing
  victim yet) and the subsequent copy states are handled by init here;
  this has not been tested against v5.5.1.
- `Storage::writeItem` searches for an old item of another type by trying
  the possible types, rather than v6.0.2's `ANY` lookup, with the same result
  for states either writer leaves.

What the comparison with ESP-IDF v6.0.2 leaves open, each with the writer
that can leave the state: *own* (this store's writes, reset anywhere),
*ESP-IDF* (its writes, reset anywhere) or *other* (only another writer or
damaged flash). Where no test is named, the writer is argued from the write
order in `nvs.zig` and `nvs_storage.cpp`, not tested.

- This version has not run on a board: every reset test is a host test. *Own.*
- A blob rewritten on one page and reset before its index reads as the old
  blob here and is lost when ESP-IDF boots that image (rule 1; 12 images of
  the crash replay). *Own, ESP-IDF.*
- After a reset in a reclaim, the page copied to again keeps its sequence
  number here (`activate`); ESP-IDF gives it the next one. Page order is the
  same. Not compared: the fuzzer has another free page there. *Own, ESP-IDF.*
- A page whose header an interrupted sector erase damaged is erased at init;
  ESP-IDF erases it when it next uses the page. Not compared. *Own, ESP-IDF.*
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
- With the newest page full and an older copy on the page being freed,
  reclaim can copy stale `n=1` after live `n=3`. Both survive the first init,
  which reads 3, but the next init erases 3 and reads 1; even `set(n,4)` can
  succeed and then `get(n)` read 1 in the same session. The `page being freed:
  0` case of `init erases the first older copy…` constructs this state.
  Neither writer leaves it: replacements are erased before reclaim starts,
  and an interrupted copy's destination is active, not full. *Other.*
- An older page still marked active is marked full; ESP-IDF loads it as an
  active page. Unit-tested here, not compared. *Other.*
- With two pages being freed, init frees only the first. A later write can
  succeed, then the next init takes that active destination as an unfinished
  copy of the second reclaim and erases it, losing the namespace entry and
  keys (`open` returns `NotFound`). ESP-IDF v5.5.1 does the same by source
  reading (`nvs_pagemanager.cpp`, `PageManager::load`, lines 96–128);
  not tested against it. *Other.*
- A partition with no free page fails init with `NotEnoughSpace` (ESP-IDF:
  `ESP_ERR_NVS_NO_FREE_PAGES`); the fuzzer's model does not cover it. *Other.*
- A write over a blob index whose first chunk number is neither 0 nor 128
  answers `Corrupt`; erase the key first. *Other.*
- The init fuzzer writes whole items on at most three pages of four (its
  list is under "Exhaustive host crash replay"). Partly written items and
  damaged item headers are compared with ESP-IDF by the crash replay's
  cross-check and the `idf_state_*` and damaged-header fixtures only, two
  pages with one sequence number by a unit test only.
