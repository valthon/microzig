# nRF52840 Bluetooth LE over the SoftDevice Controller

Covers: port/nordic/nrf5x/build.zig, port/nordic/nrf5x/build.zig.zon, port/nordic/nrf5x/src/hal.zig, port/nordic/nrf5x/src/hal/time.zig, port/nordic/nrf5x/src/hal/clocks.zig, port/nordic/nrf5x/src/hal/radio/ble/, port/nordic/nrf5x/src/hal/radio/ieee802154.zig, drivers/src/base/HCI_Transport.zig, modules/ble/, port/espressif/esp/src/hal/radio/bluetooth.zig, port/espressif/esp/src/hal/radio/ble/

## Purpose

Bluetooth LE on the nRF52840 ([#101](https://github.com/valthon/microzig/issues/101)). Nordic's
SoftDevice Controller (SDC) runs the link layer and Nordic's Multiprotocol Service Layer (MPSL)
schedules the radio; both are prebuilt libraries from `sdk-nrfxlib`. Everything above HCI is ours:
the Zig host that the ESP port already runs over Espressif's controller moves out of the ESP port
and becomes the host for both chips. The nRF glue is an HCI transport, the MPSL plumbing
(interrupts, clocks, low-priority work) and a static memory pool.

It does not implement a link layer, run the SDC on any chip other than the nRF52840, write flash
while the controller is enabled, or (in the first implementation) run BLE and the 802.15.4 driver
in the same image; the coexistence design for that is below, under its own heading.

The SDC and MPSL are `LicenseRef-Nordic-5-Clause`: Nordic ICs only, no reverse engineering. The
glue is written from the public headers and the integration notes in `sdk-nrfxlib`
(`mpsl/doc/mpsl.rst`, `mpsl/doc/timeslot.rst`, `softdevice_controller/doc/softdevice_controller.rst`),
never from the binaries, and the libraries are fetched as a lazy build dependency, never
committed. Nordic's own glue in `sdk-nrf` carries the same licence, so it is read for behavior
and cited, never copied.

## Code map

Planned layout. Names are binding for the implementation unless a review changes this doc.

| Path | Role |
| --- | --- |
| `drivers/src/base/HCI_Transport.zig` | Port-agnostic HCI transport interface: send command, send ACL, receive packet with timeout, clock. Replaces `wire.Transport` in the ESP host. |
| `modules/ble/` | The host, moved from `port/espressif/esp/src/hal/radio/ble/` (`host.zig`, `protocol.zig`, `gatt.zig`, `smp.zig`, `smp_bond.zig`, `smp_crypto.zig` and their tests). Imports only `std` and `drivers.base`. |
| `port/espressif/esp/src/hal/radio/bluetooth.zig` | Keeps `Controller`; `Controller.transport()` returns an `HCI_Transport`. `smp_hardware.zig` stays in the ESP port and implements the host's crypto provider. |
| `port/nordic/nrf5x/src/hal/radio/ble/mpsl.zig` | `mpsl_init` at HAL init, the five MPSL vectors, the low-priority service ISR, HFCLK requests for other HAL users, temperature. |
| `port/nordic/nrf5x/src/hal/radio/ble/controller.zig` | `Controller`: `sdc_init`/`sdc_cfg_set`/`sdc_enable`, the command mailbox, the receive ring, `transport()`. |
| `port/nordic/nrf5x/src/hal/radio/ble/hci_command.zig` | Pure: decode an HCI command packet, call the matching `sdc_hci_cmd_*` through a function table, encode Command Complete or Command Status. Host-tested with a fake table. |
| `port/nordic/nrf5x/src/hal/radio/ble/memory.zig` | Pure: comptime upper bound of the SDC pool from the role configuration. |
| `port/nordic/nrf5x/build.zig:with_ble` | Build-time opt-in: derives a target whose HAL imports the translated SDC/MPSL headers and links the libraries. |

## Invariants

**Opt-in at build time and at comptime, both required.** A BLE image uses a target from
`with_ble(target, .{ .roles = ... })`, which resolves the lazy `nrfxlib` dependency, translates the
headers with a stub `nrfx.h` from our tree, and links `libmpsl.a` and one
`libsoftdevice_controller_{peripheral,central,multirole}.a` chosen from the roles (soft-float ABI
variant to match the port's `eabi` target). The app also sets `microzig_options.hal.ble = true`,
which adds the MPSL vectors to `hal.default_interrupts`. Either one without the other is a compile
error naming the missing half. Targets not derived through `with_ble` are the same objects as today,
so non-radio images stay byte-identical; the PR checks it with the existing image comparison.

**MPSL owns its peripherals from HAL init.** In a BLE image `hal.init` calls `mpsl_init` before
anything else touches CLOCK, so MPSL starts and calibrates the LF clock (NCS does the same at
`SYS_INIT`, `subsys/mpsl/init/mpsl_init.c`). The peripherals MPSL and the SDC own on the nRF52
(`mpsl.rst`, `softdevice_controller.rst`) and what the HAL does about each:

| Resource | Owner | BLE-image HAL behavior |
| --- | --- | --- |
| RTC0 | MPSL (IRQ) | `hal.time` moves to RTC1 and stops configuring LFCLK; the RTC0 vector goes to MPSL. |
| TIMER0 | MPSL (IRQ) | `hal.timer` refuses `.timer0` at compile time. |
| RADIO | MPSL (IRQ via MPSL) | Only MPSL or a timeslot owner touches it. `hal.ieee802154` is a compile error until coexistence lands. |
| CLOCK, POWER_CLOCK IRQ | MPSL | `clocks.hfxo.start` and `clocks.lfclk.*` are compile errors; USB and others use `ble.hfclk_request`/`release` (`mpsl_clock_hfclk_request`). |
| TEMP | MPSL | `hal.temp` is a compile error; `ble.temperature()` calls `mpsl_temperature_get`. |
| ECB | MPSL (IRQ) | The host's SMP uses software AES (`std.crypto`), so nothing else needs ECB. |
| CCM, AAR | SDC | Not exposed by the HAL today; stays that way. |
| NVMC | SDC | `hal.nvmc` erase/write are compile errors in a BLE image (flash writes stall the CPU; nrf-mpsl schedules them in timeslots, `nrf-mpsl/src/flash.rs`). A timeslot flash backend is an open question. |
| PPI 17–31 | SDC (19, 30, 31 also MPSL) | `ppi.Channel` values 17–31 are refused at compile time in a BLE image. |

Compile-time refusal is the Zig form of nrf-mpsl's `Peripherals` ownership struct
(`nrf-mpsl/src/mpsl.rs`): a branch on `options.hal.ble` inside the function body errors only if
the app references it.

**One execution priority for every MPSL and SDC call.** `sdc_hci.h` requires the HCI APIs to run at
the priority of `mpsl_low_priority_process`; `mpsl.rst` requires MPSL APIs not to run concurrently.
All of them run in one place: the low-priority service ISR (SWI5_EGU5, the NCS default
`MPSL_LOW_PRIO_IRQN` on nRF52, priority 4 as in NCS `MPSL_LOW_PRIO` and nrf-mpsl). Foreground code
never calls MPSL or the SDC. It writes a request into the controller handle and pends SWI5; the ISR
executes requests, then runs `mpsl_low_priority_process`, then drains `sdc_hci_get` into the
receive ring. MPSL's note that the process call belongs in thread context is satisfied by its stated
alternative ("ensure that no MPSL functions are called at the same time"): nothing else calls them.
This keeps MPSL serviced while the foreground runs a P-256 multiply or a QSPI erase, which a
foreground-polled design (nrf-mpsl's executor task) cannot promise on bare metal.

**Backpressure, never drop.** When the receive ring has no free slot the ISR stops calling
`sdc_hci_get` and leaves packets in the controller; the host's next receive frees a slot and pends
SWI5. NCS does the same on `-ENOBUFS` (`hci_driver.c:hci_driver_receive_process`). The host's HCI
command credit (one) and ACL credits (from LE Read Buffer Size) bound what the foreground can
submit, so the request mailbox never overflows; a request beyond them returns `Busy`.

**The SDC never sees a raw command packet.** This SDC version exports one function per command
(`sdc_hci_cmd_*`) and no packet entry point. `hci_command.zig` decodes the packet, calls the
function, and builds Command Complete (Core v5.4 Vol 4 Part E §7.7.14) with `Num_HCI_Command_Packets
= 1`, or Command Status (§7.7.15) for the commands whose completion is a later event (Disconnect,
LE Create Connection, LE Enable Encryption among those the host sends). An opcode not in the table
returns Command Status with Unknown HCI Command (0x01). NCS's `hci_internal.c` has the same shape;
ours covers only the commands the host sends and is generated from one comptime table, so a new
host command fails a host test until it is added.

**Memory is static and checked twice.** `memory.zig` computes the pool bound at comptime from the
`SDC_MEM_*` formulas for the configured roles (the header calls them upper limits). At
`Controller.init` the ISR's `sdc_cfg_set` returns the exact requirement; more than the pool is
`error.PoolTooSmall` before `sdc_enable`. NCS sizes `sdc_mempool` the same way and checks at
runtime (`hci_driver.c:configure_memory_usage`). The pool is 8-byte aligned (`sdc_enable`).

**Faults end in a reset.** The MPSL assert and SDC fault handlers record file and line in the
handle and call `@panic`; both libraries disable interrupts first and reset the chip if the handler
returns (`mpsl.h`, `sdc.h`). nrf-mpsl panics the same way.

**Identity.** The nRF52840 has no public address; FICR `DEVICEADDR` with `DEVICEADDRTYPE = Random`
is a static random address (nRF52840 PS v1.11, FICR). The host gains an identity setting: public
(the controller's BD_ADDR, the ESP default and unchanged) or random static, where the host sends LE
Set Random Address and uses own-address-type random in advertising, scanning and connection
parameters, and in the SMP `a1`/`a2` inputs (Core Vol 3 Part H §2.2). The nRF port supplies the
FICR address with the two top bits forced to `11` (Core Vol 6 Part B §1.3.2.1).

**Vector table.** On boards linked behind a bootloader (XIAO nRF52840 Sense at 0x27000), interrupts
arrive through the MBR and the disabled SoftDevice's forwarding. A BLE image writes VTOR to its own
table at HAL init so MPSL's priority-0 handlers do not pay the forwarding, as Zephyr does for every
image (`arch/arm/core/cortex_m/prep_c.c:relocate_vector_table`).

**Critical sections stay PRIMASK.** MicroZig's `enter_critical_section` masks everything, MPSL's
priority-0 handlers included. Zephyr's default (`ZERO_LATENCY_IRQS` off) does the same: MPSL's
priority 0 is offset to hardware priority 1 and `irq_lock` sets BASEPRI to that level
(`include/zephyr/arch/arm/cortex_m/exception.h`), so NCS ships with MPSL maskable by short critical
sections. nrf-mpsl offers the alternative, an NVIC-based section that leaves RADIO, RTC0 and TIMER0
running (`critical_section_impl.rs`). Neither Nordic document publishes a bound, so the self-test
measures the longest masked interval in a BLE image with the DWT cycle counter and the PR reports it.

## Design tables

### 1. Phases (controller handle)

| Phase | Hardware / libraries | Entered by | Left by | Owner |
| --- | --- | --- | --- | --- |
| `mpsl_only` | MPSL running, SDC not initialized | `hal.init` (BLE image) | `Controller.init` | foreground |
| `enabling` | ISR runs `sdc_init`, `sdc_rand_source_register`, `sdc_cfg_set`, `sdc_support_*`, `sdc_enable` | `Controller.init` posts the enable request | ISR posts `enabled` or `failed(code)` | ISR |
| `enabled` | SDC scheduling; HCI traffic flows | enable success | fault (never returns) | ISR moves packets; foreground submits |
| `failed` | SDC not enabled; MPSL still running | enable error | `Controller.init` again (retry) | foreground |
| `faulted` | interrupts off, chip about to reset | MPSL assert or SDC fault, any context | reset | library |

There is no disable phase: the host has no shutdown API (the ESP `Controller` holds BLE for the
boot for the same reason), and `sdc_disable` returns only when the build adds one.

### 2. Ownership

| Field | Written by | Read by | Guard |
| --- | --- | --- | --- |
| `request` (one command, or enable) | foreground when `request_state == .empty`; ISR sets `.done` | ISR, foreground | `request_state` atomic (release on publish, acquire on read) |
| `acl_tx` ring (≤ ACL credits) | foreground producer | ISR consumer | single-producer/single-consumer indices, atomics |
| `rx` ring (events, ACL in) | ISR producer | foreground consumer | SPSC indices, atomics |
| `rx_blocked` | ISR when the ring is full | ISR; foreground clears and pends SWI5 after consuming | atomic |
| `fault_site` | fault handlers | after reset, from no-init RAM | none (interrupts already off) |
| `hci_ready` | SDC callback (in the ISR) | ISR loop | ISR only |

The command reply travels in the `rx` ring like any event, so the host's existing ordering rule
(Command Complete matched by opcode) applies unchanged.

### 3. Events × phases

| Event | `mpsl_only` | `enabling` | `enabled` | Cleared |
| --- | --- | --- | --- | --- |
| SWI5 pended by MPSL (low-priority work) | run `mpsl_low_priority_process` | same, then continue enable | same, then drain | NVIC on entry |
| SWI5 pended by foreground (request, ring space) | nothing queued: run process only | execute enable | execute request, drain | NVIC on entry |
| SDC host callback (`hci_ready`) | impossible | possible after `sdc_enable` | drain until `-NRF_EAGAIN` or ring full | ISR, before draining |
| Pend latched while the ISR is draining | runs again on exit (NVIC pending bit) | same | same | NVIC |
| MPSL assert / SDC fault | reset | reset | reset | n/a |

The ISR loops "execute request; process; drain" until it does no work in a pass, so a pend that
arrives mid-pass costs one extra pass instead of a lost wakeup.

### 4. Entry points × phases

| Call | `mpsl_only` | `enabling` | `enabled` | `failed` |
| --- | --- | --- | --- | --- |
| `Controller.init` | run | `Busy` | `AlreadyStarted` | run (retry) |
| `transport.send_command` | `NotEnabled` | `NotEnabled` | run; `Busy` if a command is in flight | `NotEnabled` |
| `transport.send_acl` | `NotEnabled` | `NotEnabled` | run; `NoBuffer` if the ring is full | `NotEnabled` |
| `transport.receive` | `NotEnabled` | `NotEnabled` | run (waits on the ring with `hal.time`) | `NotEnabled` |
| `hfclk_request` / `hfclk_release` | run (via mailbox) | run | run | run |
| `temperature` | run (via mailbox) | run | run | run |

### 5. Timing budget

| Quantity | Value | Source | Used in |
| --- | --- | --- | --- |
| `mpsl_low_priority_process` latency after the IRQ | "as soon as possible (at least within a couple of ms)" in `mpsl.rst`; "at least a few 100 ms" in `mpsl.h` | both, nrfxlib v3.4.2 | the stricter one sizes the SWI5 priority: above every app IRQ that can run long |
| Priority of RADIO, RTC0, TIMER0 | 0 | `mpsl.rst`, `MPSL_HIGH_IRQ_PRIORITY` | `hal.init` |
| Priority of POWER_CLOCK and SWI5 | lower than 0; 4 | `mpsl.rst`; NCS and nrf-mpsl use 4 | `hal.init` |
| LFCLK accuracy | 500 ppm or better, or `sdc_init` fails | `sdc.h:sdc_init` | board config |
| RC calibration call period | 4000 ms | Zephyr `CLOCK_CONTROL_NRF_CALIBRATION_PERIOD` default, used by NCS `MPSL_CALIBRATION_PERIOD` | ISR timer, RC boards only |
| `rand_poll` | blocks until all bytes are written | `sdc_soc.h` | RNG with bias correction, polled in the ISR |
| Longest PRIMASK section in a BLE image | unmeasured | open question | self-test report |

The XIAO nRF52840 Sense is configured for the 32.768 kHz crystal: Zephyr's `xiao_ble` board
leaves the nRF default `CLOCK_CONTROL_NRF_K32SRC_XTAL`. The first bench run confirms `LFCLKSTAT`
reports the crystal before this is relied on.

### 6. Spec rules

| Clause | Rule | Host test |
| --- | --- | --- |
| Core Vol 4 Part E §5.4.1 | A command packet is opcode (2), length (1), parameters; length must match | `hci_command: rejects a length that disagrees with the packet` |
| Vol 4 Part E §7.7.14 | Command Complete carries credits, opcode, then return parameters starting with status | `hci_command: command complete layout per opcode` |
| Vol 4 Part E §7.7.15 | Commands completed by a later event get Command Status, never Command Complete | `hci_command: disconnect, create connection and enable encryption get command status` |
| Vol 4 Part E §7.7.15 | An unknown opcode gets Command Status 0x01 | `hci_command: unknown opcode` |
| Vol 4 Part E §4.1 | The host sends no ACL data beyond the controller's buffer count | existing host credit tests, moved with the host |
| Vol 6 Part B §1.3.2.1 | Static random address: top two bits 11, rest not all 0 or all 1 | `identity: FICR address becomes a valid static address` |

### 7. Interface consumer trace (`HCI_Transport`)

Consumers: the host in `modules/ble/` (both ports), and an HCI bridge that exposes the controller
over UART or USB to a PC host (a later issue; it needs no interface change).

- **Correlation:** one command in flight; the reply is matched by opcode in the event stream, as
  the host does today.
- **Buffer lifetime:** `send_*` copies before returning; `receive` returns a packet by value.
- **Event completeness:** every controller event and ACL packet is delivered, in controller order;
  backpressure replaces loss on both ports (ESP's queue latches `ReceiveOverflow`; that remains a
  difference, recorded as an open question).
- **Notification:** none; `receive(timeout)` blocks on the port's clock.
- **Unavailable:** before enable, `NotEnabled`; the clock still advances, so a blocking caller
  times out rather than spinning.
- **Same meaning across ports:** packets exclude the H4 type byte on both ports, as
  `wire.Packet.kind` already encodes the type.

## Coexistence with the 802.15.4 driver

Not in the first implementation; a BLE image that also sets `hal.ieee802154` is a compile error,
as BLE + 802.15.4 is on the ESP32-C6 without its coex scheduler. The design that removes the error:

- MPSL arbitrates the radio. The 802.15.4 driver opens a timeslot session
  (`mpsl_timeslot_session_open`) and touches RADIO only between `MPSL_TIMESLOT_SIGNAL_START` and the
  end of the granted slot; RADIO interrupts reach it as `MPSL_TIMESLOT_SIGNAL_RADIO` through MPSL's
  vector (`timeslot.rst`). It extends slots for continuous receive and re-requests *earliest
  possible* after a block or cancel, the pattern `timeslot.rst` gives for an always-on listener.
- The driver's hardware conflicts with the reserved list must move: PPI 17–19 (all SDC-owned)
  move below 17; direct HFCLK start becomes the slot's crystal guarantee
  (`MPSL_TIMESLOT_HFCLK_CFG_XTAL_GUARANTEED`); direct TEMP sampling becomes
  `mpsl_temperature_get`; RTC0 reads move to the `hal.time` RTC. TIMER3 stays the driver's, but
  its handler runs below priority 0 and its slot-bound work moves to MPSL's TIMER0, which a slot
  owner gets for the slot's length (`timeslot.rst`, "Ending a timeslot in time").
- A frame in progress at the slot's end is the new phase the driver tables need: the slot end is a
  deadline after which the driver must have stopped RADIO, so RX that cannot finish reports
  `aborted` and TX is not started unless its airtime and ACK wait fit. This changes the driver's
  phase, event and timing tables, so it gets its own design review before code.

Nordic's own multiprotocol 802.15.4 service layer is a closed library under the same licence, so it
is not prior art we can read; the public timeslot API is.

## Prior art

- ESP BLE host, `port/espressif/esp/src/hal/radio/ble/`: the host this design moves and reuses
  unchanged except for the transport type and the identity setting. ESP's controller takes raw HCI
  packets, so it needs no command dispatcher; the nRF needs one.
- ESP `Controller`, `port/espressif/esp/src/hal/radio/bluetooth.zig`: vendor callbacks copy packets
  into a queue the host blocks on. Reused as the shape; it differs by running every vendor call in
  one ISR and by backpressure instead of a latched overflow.
- nRF 802.15.4 driver, `port/nordic/nrf5x/src/hal/radio/ieee802154.zig`: the comptime HAL option
  that installs vectors (`hal.zig:default_interrupts`) and the singleton owner rule; reused as is.
- NCS v3.4.2 `subsys/mpsl/init/mpsl_init.c` and `subsys/bluetooth/controller/hci_driver.c`,
  `hci_internal.c`: init order, IRQ priorities, low-priority work, memory sizing and check,
  backpressure, and the command-to-function dispatch with Command Status for deferred commands.
  Read for behavior only (licence).
- embassy `nrf-sdc`/`nrf-mpsl` (Apache-2.0/MIT, `github.com/alexmoon/nrf-sdc`): the closest
  analogue, a non-Nordic host over SDC on bare metal; IRQ binding, priority 4 for low priority,
  compile-time peripheral ownership, timeslot flash, and the MPSL-preserving critical section we
  chose not to adopt.
- NimBLE: no public integration with the SDC was found; NimBLE ships its own controller for nRF5
  parts. Its host-over-HCI transport split is the same split as `HCI_Transport`.

## Shared patterns

- [Interrupt handling and ISR routing](interrupts.md): HAL-owned vectors through
  `default_interrupts`, singleton routing for the controller handle, "fixed ring in the handle,
  foreground polls".
- [ESP radio stack and coexistence](esp-radio.md): BLE held for the boot; selection checked at
  compile time.
- [Base driver interfaces](base-interfaces.md): `HCI_Transport` follows the pointer + vtable form.

## Evidence

Planned; each item names the test the implementation adds.

- Command dispatch, layouts and the Command Status set: `hci_command` host tests with a fake
  `sdc_hci_cmd_*` table.
- Pool bound covers the configured roles: `memory` host test against the header formulas.
- Ring backpressure and mailbox admission: `controller` host tests with a fake SDC that produces
  packets faster than the host reads.
- Identity: host tests that random-static identity changes own-address-type fields and SMP inputs.
- Moved host: its existing tests run from `modules/ble/`, and the ESP BLE self-tests still build.
- Non-radio images byte-identical: the PR's image comparison.
- On hardware (XIAO nRF52840 Sense): advertise and accept a connection from a PC; scan and connect
  to an ESP32 peer running the existing ESP self-test; LE Secure Connections pairing; LFCLK source
  and longest masked interval reported.

## Open questions

- Flash writes while BLE is enabled need a timeslot backend (nrf-mpsl's `flash.rs` is the model);
  the KV store ([#45](https://github.com/valthon/microzig/issues/45)) depends on it.
- The bound on PRIMASK sections that MPSL tolerates is unpublished; measure first.
- ESP's receive path latches `ReceiveOverflow` while the nRF path applies backpressure.
- 802.15.4 coexistence, as designed above, needs its own reviewed table changes.
