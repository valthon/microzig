# nRF52840 Bluetooth LE over the SoftDevice Controller

Covers: port/nordic/nrf5x/build.zig, port/nordic/nrf5x/build.zig.zon, port/nordic/nrf5x/src/hal.zig, port/nordic/nrf5x/src/hal/time.zig, port/nordic/nrf5x/src/hal/clocks.zig, port/nordic/nrf5x/src/hal/timer.zig, port/nordic/nrf5x/src/hal/rtc.zig, port/nordic/nrf5x/src/hal/ppi.zig, port/nordic/nrf5x/src/hal/temp.zig, port/nordic/nrf5x/src/hal/nvmc.zig, port/nordic/nrf5x/src/hal/usbd.zig, port/nordic/nrf5x/src/hal/radio/ble/, drivers/src/base/HCI_Transport.zig, modules/ble/, port/espressif/esp/src/hal/radio/bluetooth.zig, port/espressif/esp/src/hal/radio/ble/

## Purpose

Bluetooth LE on the nRF52840 ([#101](https://github.com/valthon/microzig/issues/101)). Nordic's
SoftDevice Controller (SDC) runs the link layer and Nordic's Multiprotocol Service Layer (MPSL)
schedules the radio; both are prebuilt libraries from `sdk-nrfxlib`. Everything above HCI is ours:
the Zig host that the ESP port already runs over Espressif's controller moves out of the ESP port
and becomes the host for both chips. The nRF glue is an HCI transport with a command dispatcher,
the MPSL plumbing (vectors, priorities, clocks, low-priority service) and a static memory pool.

It does not implement a link layer, run the SDC on any chip other than the nRF52840, write internal
flash while MPSL runs, use extended advertising, or (in the first implementation) run BLE and the
802.15.4 driver in one image; the coexistence design is under its own heading below.

The SDC and MPSL are `LicenseRef-Nordic-5-Clause`: Nordic ICs only, no reverse engineering. The
glue is written from the public headers and integration notes of `sdk-nrfxlib` v3.4.2
(`mpsl/doc/mpsl.rst`, `mpsl/doc/timeslot.rst`, `softdevice_controller/doc/softdevice_controller.rst`),
never from the binaries. The libraries and headers are a lazy build dependency, never committed.
Nordic's glue in `sdk-nrf` carries the same licence, so it is read for behavior and cited, never
copied.

## Code map

Planned layout; names bind the implementation unless a review changes this doc.

| Path | Role |
| --- | --- |
| `drivers/src/base/HCI_Transport.zig` | Port-agnostic HCI transport interface (pointer + vtable): send command, send ACL, receive one packet with a timeout, clock. Replaces `wire.Transport` in the ESP host. |
| `drivers/src/base/` (same file) | `SMP_Crypto` provider interface (random, P-256 key pair, DH), lifted from `smp.Crypto` so ports implement it without depending on the host. |
| `modules/ble/` | The host, moved from `port/espressif/esp/src/hal/radio/ble/` (`host.zig`, `protocol.zig`, `gatt.zig`, `smp.zig`, `smp_bond.zig`, `smp_crypto.zig`, tests). Imports only `std` and `drivers`. |
| `port/espressif/esp/src/hal/radio/bluetooth.zig` | Keeps `Controller`; `Controller.transport()` returns an `HCI_Transport`. `smp_hardware.zig` implements `SMP_Crypto` on the C6 ECC block. |
| `port/nordic/nrf5x/src/hal/radio/ble/mpsl.zig` | `mpsl_init` at HAL init, the MPSL vectors, the SWI5 signal handler, `service`, HFCLK requests for other HAL users, temperature. |
| `port/nordic/nrf5x/src/hal/radio/ble/controller.zig` | `Controller`: enable sequence, `transport()`, the one-slot command reply. |
| `port/nordic/nrf5x/src/hal/radio/ble/hci_command.zig` | Pure: validate an HCI command packet, call the matching `sdc_hci_cmd_*` through a function table, encode Command Complete or Command Status. |
| `port/nordic/nrf5x/src/hal/radio/ble/memory.zig` | Pure: comptime upper bound of the SDC pool for the role configuration. |
| `port/nordic/nrf5x/src/hal/radio/ble/crypto.zig` | `SMP_Crypto` for the nRF: RNG for randomness, `std.crypto` P-256 in software. |
| `port/nordic/nrf5x/build.zig:with_ble` | Build-time opt-in: derives a target whose HAL imports the translated SDC/MPSL headers and links the libraries. |

## Invariants

### Opt-in

- **Two switches, both required.** A BLE image uses a target from `with_ble(target)`, which
  resolves the lazy `sdk-nrfxlib` dependency, translates the SDC/MPSL headers (include paths from
  the port's existing `nrfx` dependency for `nrfx.h` and `hal/nrf_clock.h`, plus a config shim of
  our own with only the macros `nrfx.h` requires), adds the result as a HAL import, and links
  `libmpsl.a` and `libsoftdevice_controller_multirole.a` (the self-test needs all four roles; the
  peripheral-only and central-only variants are a later size optimization). The ABI variant matches
  the port's `eabi` target and is chosen by the build, which fails if the file is missing. The app
  also sets `microzig_options.hal.ble = true`, a new `HAL_Options` field. `hal.zig` checks both
  directions at compile time: the option without the import names `with_ble`; a BLE-import target
  without the option names `hal.ble`.
- **Off means unchanged.** With `hal.ble` false, `default_interrupts`, `hal.init`, `hal.time` and
  every refused API compile exactly as today, and targets not derived through `with_ble` carry no
  new import. The PR adds `scripts/image_compare.sh`, which builds every non-radio nRF and ESP
  example at the base and head commits and compares SHA-256 of each image; the PR reports its
  result.

### Execution context

- **Every MPSL and SDC call runs in the foreground.** `mpsl.rst` (Scheduling) asks that
  `mpsl_low_priority_process` run in thread context, not in the software interrupt handler, and
  that MPSL APIs never run concurrently; `sdc_hci.h` asks that HCI APIs run at the priority of
  `mpsl_low_priority_process`. Both prior arts do this: NCS's SWI handler only submits work to the
  "MPSL Work" thread (`subsys/mpsl/init/mpsl_init.c:mpsl_low_prio_irq_handler`), and embassy's
  handler only wakes the task whose `run()` calls the process (`nrf-mpsl/src/mpsl.rs`). Here the
  SWI5 handler stores `low_priority_pending = true` (atomic, release) and returns. `mpsl.service()`
  runs in the foreground: if the flag is set it clears it, calls `mpsl_low_priority_process`, and
  runs the RC calibration call when due. The SDC's host callback, `rand_poll` and the HFCLK
  callbacks run inside that call, so they run in the foreground too.
- **Who calls `service`.** The nRF transport calls it before every `sdc_hci_get` and on every pass
  of its receive wait, so a host blocked in `poll`, `connect` or a GATT procedure keeps MPSL
  serviced. An app doing other work calls `hal.ble.service()` at least every 2 ms, the "couple of
  ms" in `mpsl.rst`. Interrupt handlers never call MPSL, SDC or `service`; with one foreground
  context that is the whole synchronization rule.
- **Long foreground work is the app's budget.** A software P-256 multiply during pairing, or any
  long app computation, delays `service`. embassy has the same property (a task that does not yield
  delays `run()`). The self-test measures the longest gap between SWI5 and `service` during
  pairing and reports it; a gap that breaks the link is a finding against this design, not against
  the app.

### Interrupts

- **Priorities.** The nRF52840 has 3 priority bits (`nvicPrioBits` in the nRF52840 SVD, carried by
  regz into `interrupt_priority_bits`); the implementation asserts the value at compile time.
  RADIO, RTC0 and TIMER0 run at 0 (`MPSL_HIGH_IRQ_PRIORITY`, `mpsl.h`). Nothing else may share 0:
  "Interrupting or delaying these handlers leads to undefined behavior" (`mpsl.rst`). In a BLE image
  `hal.init` sets every other NVIC line to 2 before enabling any, as Zephyr offsets every
  application IRQ below its reserved levels (`include/zephyr/arch/arm/cortex_m/exception.h`,
  `_IRQ_PRIO_OFFSET`). POWER_CLOCK and SWI5 go to 6: `mpsl.rst` requires them below 0 and they do
  no real-time work. An app that later sets an IRQ to 0 breaks the contract; the doc comment on
  `hal.ble` says so.
- **Order in `hal.init`.** VTOR (below), all priorities, SWI5 and POWER_CLOCK enabled, then
  `mpsl_init(&lfclk_config, SWI5_EGU5, assert_handler)`, then `mpsl_clock_hfclk_latency_set`, then
  `hal.time` on RTC1. nrf-mpsl sets the low-priority IRQ before `mpsl_init` and the high ones after;
  MPSL enables the reserved lines itself (`mpsl.rst`, Interrupt configuration).
- **Vectors.** `default_interrupts` gains, only when `hal.ble` is set: RADIO, RTC0, TIMER0 to
  `MPSL_IRQ_*_Handler`, POWER_CLOCK to `MPSL_IRQ_CLOCK_Handler` (MPSL ignores events it does not
  own, `mpsl.rst`), SWI5_EGU5 to the signal handler. `hal.time`'s RTC0 entry moves to RTC1.
- **VTOR.** On boards linked behind a bootloader (XIAO nRF52840 Sense at 0x27000) interrupts reach
  the app through the MBR and the disabled SoftDevice's forwarding. A BLE image writes VTOR to its
  own table first in `hal.init`, as Zephyr does for every image
  (`arch/arm/core/cortex_m/prep_c.c:relocate_vector_table`).
- **Critical sections.** MicroZig's critical section sets PRIMASK and so also masks MPSL. Zephyr's
  default (`ZERO_LATENCY_IRQS` off) masks MPSL in `irq_lock` too, so NCS relies on short sections;
  nrf-mpsl instead leaves RADIO, RTC0 and TIMER0 unmasked (`critical_section_impl.rs`) and warns
  that `cpsid` "can disrupt timing". Neither Nordic document publishes a bound. This design keeps
  PRIMASK, refuses the one known long section (`hal.nvmc`, which spans a page erase), and the
  self-test reports the longest masked interval measured with the DWT cycle counter. Switching to
  a BASEPRI section that spares priority 0 is the fallback if a measurement fails.

### Resource ownership

MPSL and the SDC own these on the nRF52 (`mpsl.rst`; `softdevice_controller.rst`; `sdc_soc.h`
`SDC_PPI_CHANNELS_USED_MASK`). In a BLE image the HAL behaves as follows. "Compile error" means a
branch on `options.hal.ble` inside the function body, so it fires only if the app references the
function; "refused" means a check on a runtime argument that panics with the owner's name, since
`Timer`, `Rtc` and `ppi.Channel` are runtime values. This is the Zig form of nrf-mpsl's
`Peripherals` ownership struct.

| Resource | Owner | BLE-image HAL behavior |
| --- | --- | --- |
| RTC0 | MPSL | `hal.time` moves to RTC1 and stops configuring LFCLK. |
| RTC1 | `hal.time` | `hal.rtc` refuses `.rtc1`. |
| TIMER0 | MPSL | `hal.timer` refuses `.timer0`. |
| RADIO | MPSL, or a timeslot owner | `hal.ieee802154` with `hal.ble` is a compile error until coexistence lands. |
| CLOCK, POWER_CLOCK IRQ | MPSL | `clocks.hfxo.*` and `clocks.lfclk.*` are compile errors. `usbd` requests the crystal with `mpsl_clock_hfclk_src_request` (the non-deprecated form, `mpsl_clock.h`) and waits for its callback via `service`. |
| TEMP | MPSL | `hal.temp` is a compile error; `hal.ble.temperature()` calls `mpsl_temperature_get` (about 50 µs, `mpsl_temp.h`). |
| ECB | MPSL | The host uses software AES (`std.crypto`). |
| CCM, AAR | SDC | Not exposed by the HAL; stays that way. |
| NVMC | SDC | `hal.nvmc` write and erase are compile errors (nrf-mpsl routes flash through timeslots, `flash.rs`). |
| PPI 17–31 | SDC; 19, 30, 31 also MPSL | `ppi.Channel` operations refuse 17–31. |
| SWI5/EGU5 | MPSL low-priority signal | Not exposed by the HAL; the vector is taken. |
| RNG | shared, foreground only | `rand_poll` and the SMP provider fill from RNG with bias correction, in the foreground. Interrupt handlers must not use `hal.rng`. |

### Controller and HCI

- **Enable order** (`sdc.h` notes on each call; `softdevice_controller.rst` sequence chart; NCS
  `hci_driver.c:hci_driver_open`): `sdc_init(fault_handler)`; `sdc_support_adv`,
  `sdc_support_peripheral`, `sdc_support_scan`, `sdc_support_central` (legacy only: the host sends
  only legacy advertising and scan commands, and every `sdc_support_*` must precede `sdc_cfg_set`);
  `sdc_cfg_set` for the counts and buffer sizes; `sdc_cfg_set(SDC_CFG_TYPE_NONE)` for the exact
  pool size; `sdc_rand_source_register`; `sdc_enable(host_callback, pool)`.
- **Memory is static and checked twice.** `memory.zig` computes the pool bound at comptime from
  the `SDC_MEM_*` formulas for one central, one peripheral, one advertising set and the scan
  buffers (the header calls them upper limits). The last `sdc_cfg_set` return above the pool is
  `error.PoolTooSmall` before `sdc_enable`. NCS sizes `sdc_mempool` the same way and checks at run
  time (`hci_driver.c:configure_memory_usage`). The pool is 8-byte aligned (`sdc_enable`).
- **The SDC never sees a raw command packet.** This SDC exports one function per command and no
  packet entry point. `hci_command.zig` checks the header length against the packet (Core v5.4 Vol 4
  Part E §5.4.1) and the parameter length against the opcode's fixed size; a mismatch never reaches
  the SDC and returns status 0x12, Invalid HCI Command Parameters (Vol 1 Part F). It then calls the
  function and builds Command Complete (Vol 4 Part E §7.7.14) with `Num_HCI_Command_Packets = 1`, or
  Command Status (§7.7.15) for commands completed by a later event: of those the host sends,
  Disconnect, LE Create Connection and LE Enable Encryption, the same set as NCS
  `hci_internal.c:command_generates_command_complete_event`. Unknown opcodes, including Read Buffer
  Size (0x1005, not exported), return Command Status 0x01. One comptime table lists the host's
  opcodes, so a new host command fails a host test until it is added.
- **Reply slot.** `send_command` dispatches synchronously and stores the encoded reply in the
  handle's one reply slot; `receive` returns the slot before calling `sdc_hci_get`, as NCS does
  (`hci_internal.c:hci_internal_msg_get`). The host's single command credit means the slot is free
  whenever the host may send; a send while it is full returns `Busy`.
- **No intermediate buffer.** `receive` pulls one packet from `sdc_hci_get` per call, so packets the
  host has not asked for stay in the controller and nothing is dropped in the glue. (NCS has a
  buffer pool in between and drops advertising reports when it is empty,
  `hci_driver.c:event_packet_process`; with no pool there is no such choice to make.) ACL out goes
  through `sdc_hci_data_put` under the host's existing credit accounting (LE Read Buffer Size).
- **Faults reset.** The MPSL assert and SDC fault handlers return at once; both libraries disable
  interrupts before calling them and reset the chip when they return (`mpsl.h`, `sdc.h`). They do
  not call `@panic`, whose default ends in `hang()` (`core/src/microzig.zig`) rather than a reset.
  Keeping the fault site across the reset needs a no-init RAM region, an open question.
- **Identity.** The nRF52840 has no public address: `Read BD_ADDR` returns zeros, and FICR
  `DEVICEADDR` with `DEVICEADDRTYPE = Random` is meant as a static random address (nRF52840 PS
  v1.11, FICR). The host gains an identity setting. Public (the ESP default) is unchanged. Random
  static makes `initialize` send LE Set Random Address (0x2005) after Reset, use own-address type 1
  in Set Advertising Parameters, Set Scan Parameters and Create Connection, and use type 1 with
  that address as the local `a1`/`a2` input of SMP (Core Vol 3 Part H §2.2). The nRF port supplies
  the FICR address with the two top bits forced to `11` (Core Vol 6 Part B §1.3.2.1).

## Design tables

### 1. Phases (controller handle)

| Phase | Libraries | Entered by | Left by | Owner |
| --- | --- | --- | --- | --- |
| `mpsl_only` | MPSL running, SDC not initialized | `hal.init` (BLE image) | `Controller.init` | foreground |
| `enabled` | SDC scheduling; HCI flows | `Controller.init` success | fault only | foreground |
| `failed` | SDC init or config refused; MPSL running | `Controller.init` error | reset only | foreground |
| `faulted` | interrupts off, chip resetting | MPSL assert or SDC fault, any context | reset | library |

`Controller.init` runs the whole enable sequence synchronously in the foreground, so there is no
`enabling` phase visible to another caller. `failed` is terminal: after a `cfg_set`, the
`sdc_support_*` calls return `-NRF_EPERM` (`sdc.h`), and a comptime-sized pool cannot grow. There is
no disable phase: the host has no shutdown API, as on ESP (BLE held for the boot).

### 2. Ownership

| Field | Written by | Read by | Guard |
| --- | --- | --- | --- |
| `low_priority_pending` | SWI5 handler (set), `service` (clear) | `service` | atomic; clear before calling the process, so a pend during the call is kept |
| `calibration_due_us` | `service` | `service` | foreground only |
| `phase` | foreground | foreground | foreground only |
| `reply` (one encoded event) | `send_command` | `receive` | foreground only |
| `hfclk_requests` count | foreground (`hfclk_request`/`release`) | foreground | foreground only; first request calls `_src_request`, last release `_src_release` |
| `hfclk_running` | HFCLK callback (inside `service`) | `usbd` wait | foreground only |

The only field the foreground shares with an interrupt is `low_priority_pending`.

### 3. Events × phases

| Event | `mpsl_only` | `enabled` | `failed` | `faulted` | Cleared |
| --- | --- | --- | --- | --- | --- |
| SWI5 (MPSL signals low-priority work) | set flag | set flag | set flag | impossible (interrupts off) | NVIC on entry; flag by `service` |
| SWI5 while `service` is inside the process | flag set again; next `service` runs the process again | same | same | n/a | same |
| SDC host callback | impossible | inside `service`: no action (the transport polls `sdc_hci_get`) | impossible | n/a | n/a |
| HFCLK started callback | inside `service`: set `hfclk_running` | same | same | n/a | on last release |
| RADIO, RTC0, TIMER0, POWER_CLOCK | MPSL handlers | MPSL handlers | MPSL handlers | n/a | MPSL |
| MPSL assert / SDC fault | reset | reset | reset | n/a | n/a |

### 4. Entry points × phases

| Call | `mpsl_only` | `enabled` | `failed` | `faulted` |
| --- | --- | --- | --- | --- |
| `Controller.init` | run | `AlreadyStarted` | `Failed` | unreachable |
| `transport.send_command` | `NotEnabled` | run; `Busy` if `reply` is full | `NotEnabled` | unreachable |
| `transport.send_acl` | `NotEnabled` | run; `NoBuffer` if the SDC refuses | `NotEnabled` | unreachable |
| `transport.receive` | `NotEnabled` | run (services MPSL while waiting) | `NotEnabled` | unreachable |
| `hal.ble.service` | run | run | run | unreachable |
| `hfclk_request` / `hfclk_release` | run | run | run | unreachable |
| `temperature` | run | run | run | unreachable |
| any of the above from an interrupt handler | contract violation, unchecked | same | same | same |

### 5. Timing budget

| Quantity | Value | Source | Used in |
| --- | --- | --- | --- |
| `service` latency after SWI5 | within "a couple of ms" | `mpsl.rst`, Interrupt configuration | the 2 ms rule above; measured by the self-test |
| Priority of RADIO, RTC0, TIMER0 | 0, unshared | `mpsl.h`, `mpsl.rst` | `hal.init` |
| Priority of POWER_CLOCK, SWI5 | below 0; 6 chosen | `mpsl.rst` | `hal.init` |
| Priority of all other lines | 2 | design choice, Zephyr offset as prior art | `hal.init` |
| LFCLK accuracy | 500 ppm or better, or `sdc_init` fails | `sdc.h:sdc_init` | board config |
| LFCLK started before `mpsl_init` returns | `skip_wait_lfclk_started = false` (default) | `mpsl_clock.h` | `hal.time` on RTC1 needs it running |
| RC calibration interval | `rc_ctiv = 16` (`MPSL_RECOMMENDED_RC_CTIV`); `mpsl_calibration_timer_handle` every 4000 ms from `service` | `mpsl_clock.h`, `mpsl.h`; 4000 ms is Zephyr's `CLOCK_CONTROL_NRF_CALIBRATION_PERIOD` default | RC boards only |
| HFXO ramp-up passed to MPSL | 1400 µs | NCS `MPSL_HFCLK_LATENCY` default (`subsys/mpsl/init/Kconfig`) | `mpsl_clock_hfclk_latency_set`; a board with a measured value overrides it |
| `rand_poll` per byte | typical 248 µs (t_RNG,START 128 µs + t_RNG,BC 120 µs); no maximum published | nRF52840 PS v1.11 §6.21, as cited in `hal/radio/ieee802154.zig` | blocks inside `service` |
| `mpsl_temperature_get` | about 50 µs | `mpsl_temp.h` | `temperature` |
| Longest PRIMASK section | unmeasured | open question | self-test report |
| Longest gap SWI5 → `service` during pairing | unmeasured | open question | self-test report |

The XIAO nRF52840 Sense is configured for its 32.768 kHz crystal: Zephyr's `xiao_ble` board keeps
the nRF default `CLOCK_CONTROL_NRF_K32SRC_XTAL`. The first bench run checks that `LFCLKSTAT`
reports the crystal before anything relies on it. The synthesized LF source is not offered.

### 6. Spec rules

| Clause | Rule | Host test |
| --- | --- | --- |
| Core v5.4 Vol 4 Part E §5.4.1 | Command packet: opcode (2), length (1), parameters; length must match the packet | `hci_command: header length disagrees with the packet` |
| Vol 4 Part E §7.8 and §7.4 (per-command sections) | Each command's parameters have a fixed size; a mismatch returns 0x12 without calling the SDC | `hci_command: wrong parameter length for every table opcode` |
| Vol 4 Part E §7.7.14 | Command Complete carries credits, opcode, then status and return parameters | `hci_command: command complete layout per opcode` |
| Vol 4 Part E §7.7.15 | Commands completed by a later event get Command Status, never Command Complete | `hci_command: disconnect, create connection and enable encryption get command status` |
| Vol 4 Part E §7.7.15 | Unknown opcode: Command Status 0x01 | `hci_command: unknown opcode` |
| Vol 4 Part E §4.1 | No ACL data beyond the controller's buffer count | existing host credit tests, moved with the host |
| Vol 6 Part B §1.3.2.1 | Static random address: top two bits 11; the rest not all 0 or all 1 | `identity: FICR address becomes a valid static address` |
| Vol 3 Part H §2.2 | SMP address inputs carry the address type actually used on air | `identity: random-static identity changes own-address fields and SMP inputs` |

### 7. Interface consumer trace (`HCI_Transport`)

Consumers: the host in `modules/ble/` on both ports, and later an HCI bridge exposing the
controller over UART or USB to a PC host (no interface change needed).

- **Correlation:** one command in flight; the reply is matched by opcode, as the host does today.
- **Buffer lifetime:** `send_*` copies before returning; `receive` returns the packet by value.
- **Event completeness:** every controller event and ACL packet is delivered, in controller order.
  The nRF glue holds nothing; ESP's queue latches `ReceiveOverflow` when full, a difference recorded
  under Open questions.
- **Notification:** none; `receive(timeout)` blocks on the port's clock (on the nRF, while
  servicing MPSL).
- **Unavailable:** before enable, `NotEnabled`; the clock still advances, so a blocking caller times
  out rather than spinning.
- **Same meaning across ports:** packets exclude the H4 type byte; `Packet.kind` carries the type.

## Coexistence with the 802.15.4 driver

Not in the first implementation: `hal.ble` with `hal.ieee802154` is a compile error, as BLE +
802.15.4 is on the ESP32-C6 without its coex scheduler ([interrupts.md](interrupts.md)). The design
that removes the error, to be reviewed on its own before code:

- MPSL arbitrates the radio. The 802.15.4 driver opens a timeslot session
  (`mpsl_timeslot_session_open`) and touches RADIO only between `MPSL_TIMESLOT_SIGNAL_START` and the
  end of the granted slot; RADIO interrupts reach it as `MPSL_TIMESLOT_SIGNAL_RADIO` through MPSL's
  vector (`timeslot.rst`). It extends slots for continuous receive and re-requests *earliest
  possible* after a block or cancel, the pattern `timeslot.rst` gives for an always-on listener.
- Its conflicts with the reserved list move: PPI 17–19 (SDC-owned) move below 17; the direct HFCLK
  start becomes the slot's crystal guarantee (`MPSL_TIMESLOT_HFCLK_CFG_XTAL_GUARANTEED`); TEMP
  sampling becomes `mpsl_temperature_get`; RTC0 reads move to the `hal.time` RTC. TIMER3 stays the
  driver's at a priority below 0; slot-bound deadlines use MPSL's TIMER0, which the slot owner gets
  for the slot (`timeslot.rst`, "Ending a timeslot in time").
- The slot end is a new deadline phase in the driver's tables: RX that cannot finish reports
  `aborted`, and TX starts only if its airtime and ACK wait fit the slot. That changes the driver's
  phase, event and timing tables in [ieee802154.md](ieee802154.md).

Nordic's own multiprotocol 802.15.4 service layer is a closed library under the same licence, so it
is not prior art we can read; the public timeslot API is.

## Prior art

- ESP BLE host, `port/espressif/esp/src/hal/radio/ble/`: the host this design moves, changed only
  in its transport type, crypto provider type and identity setting. ESP's controller takes raw HCI
  packets, so it needs no command dispatcher.
- ESP `Controller`, `port/espressif/esp/src/hal/radio/bluetooth.zig`: vendor callbacks copy packets
  into an RTOS queue the host blocks on. The nRF differs because the SDC is pulled (`sdc_hci_get`)
  from the foreground, so it needs no queue.
- nRF 802.15.4 driver, `port/nordic/nrf5x/src/hal/radio/ieee802154.zig` and `hal.zig`: the comptime
  HAL option that adds vectors to `default_interrupts`; reused.
- nrf5x USB, `port/nordic/nrf5x/src/hal/usbd.zig`: "IRQ only as a wakeup; all work in foreground
  `poll`" ([interrupts.md](interrupts.md)), the same split as SWI5 and `service`.
- NCS v3.4.2 `subsys/mpsl/init/mpsl_init.c`, `subsys/bluetooth/controller/hci_driver.c`,
  `hci_internal.c`: init order, IRQ use, low-priority work in a thread, memory sizing and check,
  enable order, the reply slot, and the command-to-function dispatch. Read for behavior only.
- embassy `nrf-sdc`/`nrf-mpsl` (Apache-2.0/MIT, `github.com/alexmoon/nrf-sdc`): a non-Nordic host
  over the SDC without an RTOS kernel; signal-then-run low-priority work, compile-time peripheral
  ownership, timeslot flash, and the MPSL-preserving critical section kept as our fallback.
- NimBLE: no public integration with the SDC was found; NimBLE ships its own controller for nRF5
  parts. Its host/transport split is the split `HCI_Transport` makes.

## Shared patterns

- [Interrupt handling and ISR routing](interrupts.md): HAL-owned vectors via `default_interrupts`,
  singleton routing for the controller handle, IRQ-as-wakeup with foreground work.
- [ESP radio stack and coexistence](esp-radio.md): BLE held for the boot; radio selection checked at
  compile time.
- [Base driver interfaces](base-interfaces.md): `HCI_Transport` and `SMP_Crypto` follow the pointer +
  vtable form.

## Evidence

Planned; each item names the test the implementation adds.

- Dispatch, lengths, layouts and the Command Status set: `hci_command` host tests with a fake
  `sdc_hci_cmd_*` table.
- Pool bound: `memory` host test against the header formulas for the configured roles.
- `service` flag handling, reply slot admission and enable order: `controller` host tests with a
  fake MPSL/SDC that records call order and pends SWI5 during the process call.
- Identity: host tests for random-static own-address fields and SMP inputs.
- Moved host: its existing tests run from `modules/ble/`; the ESP BLE examples still build.
- Off means unchanged: `scripts/image_compare.sh` in the PR.
- On hardware (XIAO nRF52840 Sense): advertise and accept a connection from a PC; scan for and
  connect to an ESP32 peer running the existing ESP BLE self-test; LE Secure Connections pairing;
  LFCLK source, longest masked interval and longest SWI5-to-`service` gap reported.

## Open questions

- Flash writes while MPSL runs need a timeslot backend (nrf-mpsl `flash.rs` is the model); the KV
  store ([#45](https://github.com/valthon/microzig/issues/45)) depends on it.
- The bound on PRIMASK sections and on `service` latency that MPSL tolerates is unpublished;
  measure first, BASEPRI section as fallback.
- Keeping the fault site across the reset needs a no-init RAM region the linker does not have yet.
- ESP's receive path latches `ReceiveOverflow`; the nRF path cannot overflow.
- 802.15.4 coexistence, as above, needs its own reviewed table changes.
