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
| `timer`, `wdt` (timer groups, watchdogs)      | yes | yes | `selftest_timers`                                  | built only (prior 6/6) | built only (prior 6/6) |
| `usb_serial_jtag` (logging, RX, confirmed TX) | yes | yes | `selftest_usj`                                     | built only (prior 9/9) | built only (prior 9/9) |
| `gpio` pin interrupts                         | yes | yes | `selftest_gpio_irq`                                | 8/8       | 9/9       |
| `flash` (erase, write, read)                  | yes | yes | `selftest_flash`                                   | 5/5       | 5/5       |
| `adc` (ADC1), `temperature`                   | yes | yes | `selftest_adc`                                     | 10/10     | 10/10     |
| `ledc` PWM and fades (C6: single-range gamma) | yes | yes | `selftest_ledc_fade` (C3), `selftest_c6_ledc` (C6) | 4/4       | 7/7       |
| `i2c` master                                  | yes | yes | none                                               | see below | built     |
| `i2s` (Philips stereo 16/32-bit; master TX/RX, shared duplex clocks; integer PLL160M dividers; aligned frames ≤4092 bytes, 4088 for 32-bit; owns I2S0 and DMA pair) | yes | yes | `selftest_i2s`, pads 4/5/6, no wiring; EOF probe: RX_EOF_NUM counts bytes (TRM 30.10 says bits) | built only (prior 7/7) | built only (prior 7/7) |
| `parl_io` (1/2/4/8-bit; XTAL master TX, external-clock RX, optional valid; aligned 4..65532-byte frames; owns peripheral and DMA pair) | no | yes | `selftest_parl_io`, valid/software-enable loops, ordered byte comparisons, pads 0–7/10/11, no wiring | n/a | built only (prior 16/16) |
| `dedicated_gpio` (8 CPU signals; exclusive pad/signal ownership, CSR set/clear/read) | yes | yes | `selftest_dedicated_gpio`, pad 4, no wiring | 9/9 | 8/8 |
| `gdma` channel pairs 0–2, SRAM memory copy | yes | yes | `selftest_gdma`; exclusive channels, disjoint SRAM/descriptors, bounded wait | built only (prior 15/15) | built only (prior 16/16) |
| `spi` master (SPI2), GDMA channel 0 transfers | yes | yes | `selftest_spi_dma`                                 | 8/8       | 8/8       |
| `clocks.sleep` light sleep                    | yes | no  | `selftest_sleep_s*`                                | see below | n/a       |
| `sigma_delta` (4 channels, signed density, divider 1–256) | yes | yes | `selftest_sigma_delta` | built only | built only |
| `pcnt` (4 units, channel 0, signed 16-bit, polling watchpoints, 10-bit filter) | no | yes | `selftest_pcnt` | n/a | built only |
| `etm` (50 routes; 8 GPIO event/task groups, no interrupt allocation) | no | yes | `selftest_etm` | n/a | built only |
| `mcpwm` (timer/operator 0, A/B complementary, count-up, symmetric dead time; owns group) | no | yes | `selftest_mcpwm` | n/a | built only |
| `radio` (Wi-Fi station)                       | yes | yes | `tcp_server` (image boot)                          | TCP echo  | TCP echo  |
| `radio.ieee802154` (raw MAC, polling)          | no  | yes | `selftest_ieee802154` (image boot, no wiring)        | n/a       | 3/3, H2 and nRF52840 peers |
| `rtos`                                        | yes | yes | `rtos`                                             | built     | 5/5 items |

C3-only modules produce an explicit compile error on the C6. The C3 I2C master ran on hardware
through the `i2c_display_ssd1306_c3_oled_042` example. The C6 LEDC blocking fade helper takes a
timeout in microseconds.

GDMA `copy()` on C3 reserves peripheral selector 6 (AES) for pair 0, 7 (SHA)
for pair 1, or 8 (ADC) for pair 2 during the call. Concurrent drivers/channels
must not use the selected peripheral's GDMA selector. C6 uses Dummy selectors
1/4/5. Prior C3 tests observed descriptor errors with reserved selectors;
that is a hardware observation, not a specified guarantee (C3 Table 2.4-1).
The reservation documentation is **built only**; prior counts predate it.

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
starting with an `at most 25 lines` report. The 9/9 USB counts are from an
earlier logger. Radio evidence is documented in "BLE bench examples" and "IEEE 802.15.4 raw MAC (C6)".

A logger with unmasked 2 ms drains and no panic takeover ran on a Super
Mini ESP32-C6FH4 (rev v0.2, `esp32_c6` image boot), 2026-11-19
under `selftest_ieee802154`, which logs one 75-byte `FRAME` line per received
frame, while an nRF52840 sent no-ACK frames to it every 5 ms. With the host
reading, the C6 logged all 556 frames it counted (556 of 579 sent arrived;
the same burst with 100 ms masked drains: 565 of 584, all 565 logged). In three
runs of 1500 frames the host closed the port for 1, 2 and 3 s during the
burst; the C6 still counted 1438 to 1449 of 1472 to 1476 sent. In the third
run the host (pyserial) did not purge its receive buffer on reopening, and the
drop reports summed to 744: the 741 lines missing from the output plus the 3
lines cut short when each stall began. In the first two runs pyserial purged
the buffer on each reopen (`PurgeComm`, its default on Windows), and 3 of the
6 stalls left no drop report in the output. That the purge discarded those
reports is an inference from this one comparison, not a separate test.
This ran on an earlier version; logger ownership/loss accounting, panic takeover
and LP_FAST startup changed since; the changes since are built only / unit-tested.

On an ESP32-C6, SERIAL_IN_EP_DATA_FREE can read 0 at boot with nothing
committed: IN_EP1_ST (C6 TRM v1.2 register 32.19) idle and the host's IN
tokens NAKed, so a writer that only waits for DATA_FREE never sends again.
No TRM text describes this state; the cause is not known. On a C6 booted by
the RTC watchdog it read 0 before `hal.init` in 30 of 68 boots, and one
WR_DONE let the host read the buffer and set DATA_FREE again. Repeating
WR_DONE on a flushed packet the host had not read changed neither the
delivered log nor its order (C6, 24 runs). The driver therefore writes
WR_DONE when a wait times out, on every line dropped while stalled, and once
before the first write after boot. A host that reads the buffer between the
DATA_FREE read and WR_DONE receives a zero-length packet, which CDC ACM
ignores. The boot-time release is included in the tested XIAO logger above
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
not unlock, relock or update the watchdog. The prior timer hardware counts
predate this change; current evidence is **built only**.

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
| `sha` | C3, C6 | SHA-1/224/256; CPU, no DMA; synchronous whole-message API, exclusive against DS/HMAC; TRM §23.4.2.1 | built only; `selftest_sha` compares empty, abc, padding boundaries and multi-block input with std.crypto |
| `aes` | C3, C6 | AES-128/256 CPU ECB, software CBC/OFB/CTR/CFB8/CFB128 chaining; whole blocks except CFB8, no padding/authentication/DMA, exclusive against DS; TRM §§19.4–19.5 | built; host `aes/cfb128_vectors.zig` tests pin CFB128 to `std.crypto`; `selftest_aes` SP 800-38A encrypt/decrypt vectors; current vectors built and host unit-tested; no C3/C6 hardware run of these vectors |
| `rsa` | C3, C6 | Raw integer operations: modular exponent/multiply 32–3072 bits, multiply 32–1536 bits; odd modulus, caller supplies R², little-endian u32 limbs, bounded polling, exclusive against DS; TRM §§22.3.1–22.3.4 | built only; `selftest_rsa` compares with std.crypto.ff and wide integer multiplication |
| `ecc` | C6 only (compile-time gate) | P-192/P-256 affine point verification and verified multiplication; big-endian fixed-size coordinates/scalars, nonzero scalar below group order; no ECDSA/ECDH protocol or Jacobian API; TRM §§20.3.2–20.7 | built only; `selftest_ecc` compares with std.crypto P256 and ff P-192 doubling, including invalid inputs |

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
The C6 `rtos` RAM image received all five queue items, then returned `error.Timeout` as written.
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
and checks the efuse MAC. With `-Dexpected_mac=aa:bb:cc:dd:ee:ff` (the board's MAC, e.g.
`98:88:e0:7e:fc:74` for the Super Mini) the MAC must match, so another board fails that case.
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

Current core self-test reporting is **built only**. Historical results below
predate the SKIP change. Evidence: on the Super Mini ESP32-C6FH4 rev v0.2, from RAM, `selftest_c6_core` passed 85/85 and
`selftest_c6_ledc` passed 7/7. `selftest_c6_core` also passed 85/85 from RAM on the Super Mini and
on a XIAO ESP32-C6 rev v0.1, each with `-Dexpected_mac` set to its own MAC and without the option;
the Super Mini built with the XIAO's MAC failed only the `mac` case (84/85).

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
"BLE bench examples" below.

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
