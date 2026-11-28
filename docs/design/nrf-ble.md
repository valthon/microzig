# nRF52840 Bluetooth LE over the SoftDevice Controller

Covers: port/nordic/nrf5x/build.zig, port/nordic/nrf5x/build.zig.zon, port/nordic/nrf5x/src/hal.zig, port/nordic/nrf5x/src/hal/time.zig, port/nordic/nrf5x/src/hal/clocks.zig, port/nordic/nrf5x/src/hal/timer.zig, port/nordic/nrf5x/src/hal/rtc.zig, port/nordic/nrf5x/src/hal/ppi.zig, port/nordic/nrf5x/src/hal/temp.zig, port/nordic/nrf5x/src/hal/nvmc.zig, port/nordic/nrf5x/src/hal/usbd.zig, port/nordic/nrf5x/src/hal/radio/ble/, drivers/src/base/HCI_Transport.zig, modules/ble/, port/espressif/esp/src/hal/radio/bluetooth.zig, port/espressif/esp/src/hal/radio/ble/

## Purpose

Bluetooth LE on the nRF52840 ([#101](https://github.com/valthon/microzig/issues/101)). Nordic's
SoftDevice Controller (SDC) runs the link layer and Nordic's Multiprotocol Service Layer (MPSL)
schedules the radio; both are prebuilt libraries from `sdk-nrfxlib`. Everything above HCI is ours:
the Zig host that the ESP port runs over Espressif's controller moves out of the ESP port and
becomes the host for both chips. The nRF glue is an HCI transport with a command dispatcher, the
MPSL plumbing (vectors, priorities, clocks, low-priority service) and a static memory pool.

It does not implement a link layer, run the SDC on any chip but the nRF52840, write internal flash
while MPSL runs, use extended advertising, or (in the first implementation) run BLE and the 802.15.4
driver in one image; the coexistence design is under its own heading below.

The SDC and MPSL are `LicenseRef-Nordic-5-Clause`: Nordic ICs only, no reverse engineering. The glue
is written from the public headers and integration notes of `sdk-nrfxlib` v3.4.2 (`mpsl/doc/mpsl.rst`,
`mpsl/doc/timeslot.rst`, `softdevice_controller/doc/softdevice_controller.rst`), never from the
binaries. Libraries and headers are a lazy build dependency, never committed. Nordic's glue in
`sdk-nrf` has the same licence, so it is read for behavior and cited, never copied.

## Code map

Planned layout; names bind the implementation unless a review changes this doc.

| Path | Role |
| --- | --- |
| `drivers/src/base/HCI_Transport.zig` | Port-agnostic HCI transport (pointer + vtable): send command, send ACL, receive one packet with a timeout, clock. Replaces `wire.Transport` in the host. Also `SMP_Crypto` (random, P-256 key pair, DH), lifted from `smp.Crypto` so ports implement it without depending on the host. |
| `modules/ble/` | The host, moved from `port/espressif/esp/src/hal/radio/ble/` (`host.zig`, `protocol.zig`, `gatt.zig`, `smp.zig`, `smp_bond.zig`, `smp_crypto.zig`, tests). Imports only `std` and `drivers`. |
| `port/espressif/esp/src/hal/radio/bluetooth.zig` | Keeps `Controller`; `transport()` returns an `HCI_Transport`. `smp_hardware.zig` implements `SMP_Crypto` on the C6 ECC block. |
| `port/nordic/nrf5x/src/hal/radio/ble.zig` | `Ble`: the caller-owned handle (state, SDC pool, reply slot), `init` (MPSL), `enable` (SDC), `service`, `transport()`, HFCLK and temperature. One routing pointer `owner: ?*Ble`. |
| `port/nordic/nrf5x/src/hal/radio/ble/hci_command.zig` | Pure: validate an HCI command packet, call the matching `sdc_hci_cmd_*` through a function table, encode Command Complete or Command Status. |
| `port/nordic/nrf5x/src/hal/radio/ble/memory.zig` | Pure: comptime pool bound for the role configuration. |
| `port/nordic/nrf5x/src/hal/radio/ble/crypto.zig` | `SMP_Crypto` for the nRF: RNG with bias correction, `std.crypto` P-256 in software. |
| `port/nordic/nrf5x/build.zig:with_ble` | Build-time opt-in: derives a target whose HAL imports the translated SDC/MPSL headers and links the libraries. |

## Invariants

### Opt-in

- **Two switches, both required.** A BLE image uses a target from `with_ble(target)`. It resolves
  the lazy `sdk-nrfxlib` dependency and translates the SDC/MPSL headers. The include paths come from
  the port's existing `nrfx` dependency (for `nrfx.h` and `hal/nrf_clock.h`), plus a config shim of
  ours with only the macros `nrfx.h` requires. It adds the result as a HAL import and links
  `libmpsl.a` and `libsoftdevice_controller_multirole.a`, from the soft-float directory the port's
  `eabi` target selects (nrfxlib `mpsl/Kconfig`); the build fails if the file is missing. Multirole
  is the only variant with both advertiser and central; the smaller variants are a later size
  option. The app also sets `microzig_options.hal.ble = true`, a new `HAL_Options` field. `hal.zig`
  checks both directions at compile time: the option without the import names `with_ble`, and the
  import without the option names `hal.ble`.
- **Off means unchanged.** With `hal.ble` false, `default_interrupts`, `hal.init`, `hal.time` and
  every API refused below compile as today, and targets not derived through `with_ble` carry no new
  import. The PR adds `scripts/image_compare.sh`: it builds every non-radio nRF and ESP example at
  the base and head commits and compares the SHA-256 of each image. The PR reports the result.
- **Undefined symbols.** The libraries' imports (libc and `__aeabi_*` helpers) cannot be read from
  the headers. The BLE example's link is the gate: a missing symbol fails the build, and the
  implementation lists what it provides.

### Lifetime and state

- **One handle, one routing pointer.** All state lives in a stationary caller-owned `Ble`. The
  SWI5 handler and the MPSL and SDC callbacks, which have no context argument, reach it through
  `owner: ?*Ble`. `Ble.init` sets `owner` under a critical section, and a second owner is rejected.
  Nothing is torn down (the handle is held for the boot, as ESP BLE is), so the pointer never
  clears. This is the singleton routing exception in `ARCHITECTURE.md`, as used by ESP BLE's
  `active` ([interrupts.md](interrupts.md)).
- **MPSL starts in `Ble.init`, not `hal.init`.** In a BLE image `hal.init` leaves CLOCK, RTC0 and
  `hal.time` alone. `Ble.init` does the whole bring-up, so it does not matter whether the app
  overrides `init` (`core/src/microzig.zig:microzig_main` runs `root.init` instead of `hal.init`
  when the app has one). Until `Ble.init` returns, `hal.time` is not running and returns 0. The
  order is:
  1. Write VTOR.
  2. Set all priorities (below).
  3. Clear pending on SWI5.
  4. `mpsl_init(&lfclk, SWI5_EGU5, assert_handler)`. It enables the reserved lines, POWER_CLOCK and
     SWI5 itself (`mpsl.rst`, Interrupt configuration), so the glue enables none of them.
  5. `mpsl_clock_hfclk_latency_set`.
  6. `hal.time` on RTC1.

  nrf-mpsl sets the low-priority line's priority and unpends it before `mpsl_init`
  (`nrf-mpsl/src/mpsl.rs:new`).
- **VTOR.** On boards linked behind a bootloader (XIAO nRF52840 Sense at 0x27000), interrupts reach
  the app through the MBR and the disabled SoftDevice's forwarding. `Ble.init` points VTOR at the
  image's own table, as Zephyr does for every image (`arch/arm/core/cortex_m/prep_c.c:relocate_vector_table`).

### Execution context

- **Every MPSL and SDC call runs in the foreground.** `mpsl.rst` (Scheduling) asks that
  `mpsl_low_priority_process` run in thread context, not in the software interrupt handler, and that
  MPSL APIs never run concurrently. `sdc_hci.h` asks that HCI APIs run at the priority of
  `mpsl_low_priority_process`. NCS's SWI handler only submits work to the "MPSL Work" thread
  (`subsys/mpsl/init/mpsl_init.c:mpsl_low_prio_irq_handler`). embassy's handler only wakes the task
  whose `run()` calls the process (`nrf-mpsl/src/mpsl.rs`). Here the SWI5 handler sets
  `owner.low_priority_pending` (atomic, release), executes `SEV` and returns. `Ble.service()` clears
  the flag before calling `mpsl_low_priority_process`, so a pend during the call is kept, and it
  makes the RC calibration call when due. Callbacks run "in the same execution priority as
  `mpsl_low_priority_process`" (`mpsl_clock.h`, `sdc.h`, `sdc_soc.h`); with one foreground context,
  that is the foreground.
- **Who calls `service`.** The nRF transport calls it before every `sdc_hci_get` and on every pass of
  its receive wait, and waits with `WFE` between passes (woken by SWI5's `SEV` or the clock). A host
  blocked in `poll`, `connect` or a GATT procedure therefore keeps MPSL serviced. An app doing other
  work calls `hal.ble.service()`. Interrupt handlers never call MPSL, the SDC or `service`; with one
  foreground context, that is the whole synchronization rule.
- **Latency target and the P-256 exception.** The two sources disagree: "as soon as possible (at
  least within a couple of ms)" (`mpsl.rst`) and "within reasonable time (a at least a few 100 ms)"
  (`mpsl.h:mpsl_low_priority_process`). The design takes 2 ms as the steady-state target and the
  header's few hundred ms as the hard limit. Software P-256 during pairing blocks `service` for its
  whole duration. trouble, embassy's BLE host, does the same over the SDC: its `security` feature
  runs RustCrypto P-256 in the host task, on the same thread-mode executor as `mpsl_task`
  (`trouble/host/src/security_manager/crypto.rs`, `examples/nrf52/src/bin/ble_bas_central_sec.rs`).
  **Gate before implementation:** the first task benchmarks `std.crypto` P-256 key generation and DH
  on the nRF52840 in ReleaseSmall. If either exceeds 100 ms, this design returns to review before
  host work starts.

### Interrupts

- **Priorities.** The nRF52840 has 3 priority bits (`nvicPrioBits` in the nRF52840 SVD, which regz
  carries into `interrupt_priority_bits`; the glue asserts the value at compile time). RADIO, RTC0
  and TIMER0 run at 0 (`MPSL_HIGH_IRQ_PRIORITY`, `mpsl.h`), unshared: "Interrupting or delaying these
  handlers leads to undefined behavior" (`mpsl.rst`). `Ble.init` sets every other line to 2. Zephyr
  likewise offsets every application IRQ below its reserved levels
  (`include/zephyr/arch/arm/cortex_m/exception.h`, `_IRQ_PRIO_OFFSET`). POWER_CLOCK and SWI5 go to 6:
  `mpsl.rst` requires both below 0, and neither does real-time work. ECB is also listed by `mpsl.rst`
  among the instances with interrupts, but neither NCS (`mpsl_init.c` connects TIMER, RTC and RADIO
  only) nor nrf-mpsl connects an ECB handler, so the glue leaves its vector default and its line
  disabled. An app that sets any line to 0 later breaks the contract; the doc comment on `hal.ble`
  says so.
- **Vectors.** Only when `hal.ble` is set, `default_interrupts` gains:
  - RADIO, RTC0 and TIMER0 → `MPSL_IRQ_*_Handler`;
  - POWER_CLOCK → `MPSL_IRQ_CLOCK_Handler` (MPSL ignores events it does not own, `mpsl.rst`);
  - SWI5_EGU5 → the signal handler.

  `hal.time`'s RTC0 entry moves to RTC1.
- **Critical sections.** MicroZig's critical section sets PRIMASK, which also masks MPSL. Zephyr's
  default (`ZERO_LATENCY_IRQS` off) masks MPSL in `irq_lock` too, so NCS relies on short sections.
  nrf-mpsl leaves RADIO, RTC0 and TIMER0 unmasked instead (`critical_section_impl.rs`) and warns that
  `cpsid` can disrupt timing. Neither Nordic document publishes a bound. This design keeps PRIMASK
  and refuses the one known long section (`hal.nvmc`, which spans a page erase). The self-test
  reports the longest masked interval, measured with the DWT cycle counter. A BASEPRI section that
  spares priority 0 is the fallback if a measurement fails.
- **Failures reset.** The MPSL assert and SDC fault handlers return at once. Both libraries disable
  interrupts before calling them and reset the chip on return (`mpsl.h`, `sdc.h`). A refused
  resource (below) and an RNG timeout inside `rand_poll` call `NVIC_SystemReset` for the same
  reason. The default `@panic` ends in `hang()` (`core/src/microzig.zig`), and a hung image keeps
  MPSL's radio timing undefined.

### Resource ownership

MPSL and the SDC own the resources below on the nRF52 (`mpsl.rst`, `softdevice_controller.rst`, and
`sdc_soc.h` `SDC_PPI_CHANNELS_USED_MASK`). The table says what the HAL does about each in a BLE
image, using two mechanisms:

- **Compile error:** a branch on `options.hal.ble` inside the function body, so it fires only if the
  app references the function.
- **Refused:** a check on a runtime argument. `Timer`, `Rtc`, `ppi.Channel` and group masks are
  runtime values, so the check fails at run time and resets as above.

This is the Zig form of nrf-mpsl's `Peripherals` ownership struct.

| Resource | Owner | BLE-image HAL behavior |
| --- | --- | --- |
| RTC0 | MPSL | `hal.time` moves to RTC1 and stops configuring LFCLK. |
| RTC1 | `hal.time` | `hal.rtc` refuses `.rtc1`. |
| TIMER0 | MPSL | `hal.timer` refuses `.timer0`. |
| RADIO | MPSL, or a timeslot owner | `hal.ieee802154` together with `hal.ble` is a compile error until coexistence lands. |
| CLOCK, POWER_CLOCK | MPSL | `clocks.hfxo.*` and `clocks.lfclk.*` are compile errors. `usbd` requests the crystal with `hal.ble.hfclk_request()`, which calls `mpsl_clock_hfclk_src_request` (the non-deprecated form, `mpsl_clock.h`), and waits by polling `mpsl_clock_hfclk_src_is_running` with `service` in the loop, as nrf-mpsl does (`hfclk.rs`). [usb-device.md](usb-device.md) gains this rule in the same PR; without BLE its "start HFXO before polling" rule is unchanged. |
| TEMP | MPSL | `hal.temp` is a compile error. `hal.ble.temperature()` calls `mpsl_temperature_get`, which takes about 50 µs (`mpsl_temp.h`). |
| ECB | MPSL | The host uses software AES (`std.crypto`). |
| CCM, AAR | SDC | Not exposed by the HAL; stays that way. |
| NVMC | SDC | `hal.nvmc` write and erase are compile errors (nrf-mpsl routes flash through timeslots, `flash.rs`). |
| PPI 17–31 | SDC (19, 30 and 31 also MPSL) | `ppi.Channel` operations refuse 17–31. `ppi.Group.set_channels` refuses masks with bits 17–31. |
| SWI5/EGU5 | MPSL low-priority signal | Not exposed by the HAL; the vector is taken. |
| RNG | shared, foreground only | `rand_poll` and the SMP provider use it from the foreground. Interrupt handlers must not use `hal.rng`. |

### Controller and HCI

- **Enable order** (`Ble.enable`), from the per-call notes in `sdc.h` and NCS
  `hci_driver.c:hci_driver_init` and `hci_driver_open`:
  1. `sdc_init(fault_handler)`.
  2. `sdc_support_helper(sdc_support_adv)`, `(sdc_support_peripheral)` and `(sdc_support_central)`,
     each checked. Every `sdc_support_*` must precede `sdc_cfg_set`. Central includes the scanner,
     and `sdc_support_scan` "shall not be called together with" `sdc_support_central` (`sdc.h`).
     NCS calls `sdc_support_scan` only without central. All three are legacy: the host sends only
     legacy advertising and scan commands.
  3. `sdc_cfg_set` for the counts and buffer sizes.
  4. `sdc_cfg_set(SDC_CFG_TYPE_NONE)` for the exact pool size.
  5. `sdc_rand_source_register`.
  6. `sdc_enable(host_callback, pool)`.

  Any error leaves the handle `failed`. The headers do not say that the sequence may be repeated
  after a partial run, so `failed` is terminal until reset. The causes are configuration errors,
  which the host tests and the example catch, not field conditions.
- **Memory is static and checked twice.** `memory.zig` computes the bound at comptime from the
  header's own `SDC_MEM_*` macros. Zig's translation of the headers provides them; a host test pins
  a translated copy so the formula is visible in review. It covers every term the configuration
  enables: one central and one peripheral link with their shared terms, one advertising set, the
  scan buffers, the initiator and the filter accept list (`SDC_MEM_FAL`). The header calls these
  "an upper limit" that "may change between minor releases" (`sdc.h`), so the step 4 return above the
  pool is `error.PoolTooSmall`. NCS checks the same way (`hci_driver.c:configure_memory_usage`). The
  pool is a field of `Ble`, 8-byte aligned (`sdc_enable`).
- **The SDC never sees a raw command packet.** This SDC exports one function per command and no
  packet entry point, so `hci_command.zig` handles each packet:
  1. Check the header length against the packet (Core v5.4 Vol 4 Part E §5.4.1).
  2. Check the parameter length against the opcode's fixed size. A mismatch returns status 0x12,
     Invalid HCI Command Parameters, without calling the SDC.
  3. Call the function and build the reply:
     - Command Complete (§7.7.14) with `Num_HCI_Command_Packets = 1`.
     - Command Status (§7.7.15) for commands completed by a later event. Of those the host sends,
       these are Disconnect, LE Create Connection and LE Enable Encryption, the same set as NCS
       `hci_internal.c:command_generates_command_complete_event`.
     - Command Status 0x01 for an unknown opcode, including Read Buffer Size (0x1005, not exported).
       The host uses 0x1005 only when LE Read Buffer Size reports zero buffers, and the example
       checks that it reports more.

  One comptime table lists the host's opcodes, so a new host command fails a host test until it is
  added.
- **Reply slot and ordering.** `send_command` dispatches synchronously and stores the encoded reply
  in the handle's one reply slot. `receive` returns the slot before calling `sdc_hci_get`, as NCS
  does (`hci_internal.c:hci_internal_msg_get`). So **a command's reply comes ahead of events the
  controller queued before it; all other packets keep controller order**. Two host races depend
  on this, and the host mishandles both today on either port, whichever order the replies arrive in:
  - `disconnect` after the peer already disconnected: the controller answers Disconnect with
    Unknown Connection Identifier (0x02), and `command` returns `CommandFailed` while the
    Disconnection Complete is still queued (`host.zig:disconnect`).
  - The connect-timeout cancel after the connection already completed: Create Connection Cancel
    fails with Command Disallowed (0x0C), and the `try` returns `CommandFailed` while an LE
    Connection Complete is queued, leaving a connection the caller does not know about
    (`host.zig:connect_address`).

  The move fixes both: on those two statuses the host keeps waiting for the queued event under the
  existing deadline. It adds a test for each race in both arrival orders.

  The single command credit means the slot is free whenever the host may send; a send while it is
  full returns `Busy`.
- **No intermediate buffer.** `receive` pulls one packet from `sdc_hci_get` per call, so packets the
  host has not asked for stay in the controller and the glue drops nothing. NCS has a buffer pool in
  between and drops advertising reports when it is empty (`hci_driver.c:event_packet_process`).
  ACL out goes through `sdc_hci_data_put`, which returns only 0 or `-NRF_EINVAL` (`sdc_hci.h`);
  `-NRF_EINVAL` maps to `InvalidPacket`. Flow control is the host's existing credit accounting
  (LE Read Buffer Size, Number Of Completed Packets).
- **Identity.** The nRF52840 has no public address. `Read BD_ADDR` returns zeros
  (`sdc_hci_cmd_info_params.h`), and FICR `DEVICEADDR` with `DEVICEADDRTYPE = Random` is meant as a
  static random address (nRF52840 PS v1.11, FICR). The host gains an identity setting:
  - **Public** is the ESP default and is unchanged.
  - **Random static** makes `initialize` send LE Set Random Address (0x2005) after Reset. It then
    uses own-address type 1 in Set Advertising Parameters, Set Scan Parameters and Create
    Connection, and type 1 with that address as the local `a1`/`a2` SMP input (Core Vol 3 Part H
    §2.2).

  The nRF port supplies the FICR address with the two top bits forced to `11` (Core Vol 6 Part B
  §1.3.2.1). The SDC's vendor command Zephyr Read Static Addresses (`sdc_hci_vs.h`) returns the same
  FICR-derived address for Zephyr hosts; reading FICR directly keeps the host free of vendor
  commands.

## Design tables

### 1. Phases (`Ble` handle)

| Phase | Libraries | Entered by | Left by | Owner |
| --- | --- | --- | --- | --- |
| `uninitialized` | nothing; `owner` null | boot | `Ble.init` | foreground |
| `mpsl_only` | MPSL running, SDC not initialized | `Ble.init` | `Ble.enable` | foreground |
| `enabled` | SDC scheduling; HCI flows | `Ble.enable` success | fault only | foreground |
| `failed` | SDC refused its sequence; MPSL running | `Ble.enable` error | reset only | foreground |
| `faulted` | interrupts off, chip resetting | MPSL assert, SDC fault, refused resource, RNG timeout | reset | library or glue |

### 2. Ownership

All fields are in `Ble` except `owner`.

| Field | Written by | Read by | Guard |
| --- | --- | --- | --- |
| `owner` (module) | `Ble.init` once | SWI5 handler, callbacks | critical section on write; never cleared |
| `low_priority_pending` | SWI5 handler (set), `service` (clear) | `service` | atomic; cleared before the process call |
| `phase` | foreground | foreground | foreground only |
| `calibration_due_us` | `service` | `service` | foreground only |
| `reply` (one encoded event) | `send_command` | `receive` | foreground only |
| `hfclk_requests` (count) | `hfclk_request` and `hfclk_release` | same | foreground only; the first request calls `_src_request`, the last release calls `_src_release` |
| `pool` | SDC after `sdc_enable` | SDC | owned by the SDC for the boot |

`low_priority_pending` is the only field the foreground shares with an interrupt.

### 3. Events × phases

| Event | `uninitialized` | `mpsl_only` | `enabled` | `failed` | `faulted` | Cleared |
| --- | --- | --- | --- | --- | --- | --- |
| SWI5 (low-priority work) | impossible (line disabled and unpended until `mpsl_init`) | set flag, `SEV` | same | same | impossible | NVIC on entry; the flag by `service` |
| SWI5 during the process call | n/a | flag set again; the next `service` runs the process again | same | same | n/a | same |
| SDC host callback | impossible | impossible | inside `service`: no action (the transport polls `sdc_hci_get`) | impossible | n/a | n/a |
| HFCLK callback | impossible | inside `service`: no action (the requester polls `_src_is_running`) | same | same | n/a | n/a |
| RADIO, RTC0, TIMER0, POWER_CLOCK | impossible (lines disabled) | MPSL handlers | same | same | n/a | MPSL |
| MPSL assert, SDC fault | impossible | reset | reset | reset | n/a | n/a |

### 4. Entry points × phases

| Call | `uninitialized` | `mpsl_only` | `enabled` | `failed` | `faulted` |
| --- | --- | --- | --- | --- | --- |
| `Ble.init` | run | `AlreadyInitialized` (second owner) | same | same | unreachable |
| `Ble.enable` | `NotInitialized` | run | `AlreadyEnabled` | `Failed` | unreachable |
| `transport.send_command` | `NotEnabled` | `NotEnabled` | run; `Busy` if `reply` is full | `NotEnabled` | unreachable |
| `transport.send_acl` | `NotEnabled` | `NotEnabled` | run | `NotEnabled` | unreachable |
| `transport.receive` | `NotEnabled` | `NotEnabled` | run (services MPSL while waiting) | `NotEnabled` | unreachable |
| `service` | no-op | run | run | run | unreachable |
| `hfclk_request`, `hfclk_release` | `NotInitialized` | run | run | run | unreachable |
| `temperature` | `NotInitialized` | run | run | run | unreachable |
| any of these from an interrupt handler | contract violation; unchecked | same | same | same | same |

The `uninitialized` column has a host test that calls every entry point before `Ble.init`.

### 5. Timing budget

| Quantity | Value | Source | Used in |
| --- | --- | --- | --- |
| `service` latency after SWI5 | target 2 ms; hard limit "a few 100 ms" | `mpsl.rst`; `mpsl.h` | the transport loop; measured by the self-test |
| P-256 key pair and DH | unmeasured; gate at 100 ms each | trouble prior art (above) | benchmark before host work |
| Priority of RADIO, RTC0, TIMER0 | 0, unshared | `mpsl.h`, `mpsl.rst` | `Ble.init` |
| Priority of POWER_CLOCK and SWI5 | 6 (must be below 0) | `mpsl.rst` | `Ble.init` |
| Priority of all other lines | 2 | design choice; Zephyr's offset is the prior art | `Ble.init` |
| LFCLK accuracy limit | 500 ppm or better, or `sdc_init` fails | `sdc.h:sdc_init` | config check |
| XIAO LF source and accuracy | crystal; `accuracy_ppm = 250` | Zephyr `xiao_ble` keeps the nRF default `K32SRC_XTAL`; 250 is `MPSL_DEFAULT_CLOCK_ACCURACY_PPM` (`mpsl_clock.h`) | board config; the first bench run checks `LFCLKSTAT` |
| RC boards | `rc_ctiv = 16`, `rc_temp_ctiv = 2`, `accuracy_ppm = 500`; `mpsl_calibration_timer_handle` every 4000 ms from `service` | `mpsl_clock.h` (`MPSL_RECOMMENDED_RC_CTIV`, `_TEMP_CTIV`, and its note: a 4 s interval, at least every 8 s for ±500 ppm) | board config |
| LFCLK running when `mpsl_init` returns | `skip_wait_lfclk_started = false` (default) | `mpsl_clock.h` | `hal.time` on RTC1 |
| HFXO ramp-up passed to MPSL | 1400 µs | `MPSL_CLOCK_HF_LATENCY_WORST_CASE` (`mpsl_clock.h`); NCS's `MPSL_HFCLK_LATENCY` default is the same | `mpsl_clock_hfclk_latency_set` |
| `rand_poll` per byte | typical 248 µs (t_RNG,START 128 µs plus t_RNG,BC 120 µs); no maximum published | nRF52840 PS v1.11 §6.21, as cited in `hal/radio/ieee802154.zig` | deadline 16 × typical per byte, as the 802.15.4 driver's seed; past it, reset |
| Bytes per `rand_poll` call | not documented | open question | logged by the self-test |
| `mpsl_temperature_get` | about 50 µs | `mpsl_temp.h` | `temperature` |
| Longest PRIMASK section | unmeasured | open question | self-test report |

The synthesized LF source is not offered.

### 6. Spec rules

| Clause | Rule | Host test |
| --- | --- | --- |
| Core v5.4 Vol 4 Part E §5.4.1 | Command packet: opcode (2), length (1), parameters; length matches the packet | `hci_command: header length disagrees with the packet` |
| Vol 4 Part E §7 (per-command sections) | Fixed parameter size per command; a mismatch returns 0x12 without calling the SDC | `hci_command: wrong parameter length for every table opcode` |
| Vol 4 Part E §7.7.14 | Command Complete: credits, opcode, then status and return parameters | `hci_command: command complete layout per opcode` |
| Vol 4 Part E §7.7.15 | Commands completed by a later event get Command Status, never Command Complete | `hci_command: disconnect, create connection and enable encryption get command status` |
| Vol 4 Part E §7.7.15 | Unknown opcode: Command Status 0x01 | `hci_command: unknown opcode` |
| Vol 4 Part E §4.1 | No ACL data beyond the controller's buffer count | existing host credit tests, moved with the host |
| Vol 6 Part B §1.3.2.1 | Static random address: top two bits 11; the rest not all 0 or all 1 | `identity: FICR address becomes a valid static address` |
| Vol 3 Part H §2.2 | SMP address inputs carry the address type used on air | `identity: random-static identity changes own-address fields and SMP inputs` |

### 7. Interface consumer trace (`HCI_Transport`)

Consumers: the host in `modules/ble/` on both ports. A later HCI bridge to a PC host would use the
same interface but needs more dispatcher entries (a PC host sends Read Local Supported Commands and
Features, which NCS synthesizes, `hci_internal.c`); that is its own issue.

- **Correlation:** one command in flight; the reply is matched by opcode.
- **Buffer lifetime:** `send_*` copies before returning; `receive` returns the packet by value.
- **Event completeness and order:** every controller event and ACL packet is delivered. A command
  reply comes ahead of earlier-queued controller packets (nRF; see Reply slot); everything else is
  in controller order. ESP's queue latches `ReceiveOverflow` when full; the nRF glue holds nothing.
- **Notification:** none; `receive(timeout)` blocks on the port's clock, servicing MPSL on the nRF.
- **Unavailable:** before enable, `NotEnabled`; the clock still advances, so a blocking caller times
  out rather than spinning.
- **Same meaning across ports:** packets exclude the H4 type byte; `Packet.kind` carries the type.

## Coexistence with the 802.15.4 driver

This is not in the first implementation: `hal.ble` with `hal.ieee802154` is a compile error. BLE
plus 802.15.4 is likewise a compile error on the ESP32-C6 without its coex scheduler
([interrupts.md](interrupts.md)). The design that removes the error gets its own review before
code:

- **MPSL arbitrates the radio.** The 802.15.4 driver opens a timeslot session
  (`mpsl_timeslot_session_open`) and touches RADIO only between `MPSL_TIMESLOT_SIGNAL_START` and the
  end of the granted slot. RADIO interrupts reach it as `MPSL_TIMESLOT_SIGNAL_RADIO` through MPSL's
  vector (`timeslot.rst`). It extends slots for continuous receive, and after a block or cancel it
  re-requests *earliest possible*: the pattern `timeslot.rst` gives for an always-on listener.
- **Its conflicts with the reserved list move:**
  - PPI 17–19 move below 17.
  - The direct HFCLK start becomes the slot's crystal guarantee
    (`MPSL_TIMESLOT_HFCLK_CFG_XTAL_GUARANTEED`).
  - TEMP sampling becomes `mpsl_temperature_get`.
  - RTC0 reads move to the `hal.time` RTC.
  - TIMER3 stays the driver's, at a priority below 0. Slot-bound deadlines use MPSL's TIMER0, which
    the slot owner gets for the slot (`timeslot.rst`, "Ending a timeslot in time").
- **The slot end is a new deadline phase** in the driver's tables. RX that cannot finish reports
  `aborted`, and TX starts only if its airtime and ACK wait fit the slot. This changes the phase,
  event and timing tables in [ieee802154.md](ieee802154.md).

Nordic's own multiprotocol 802.15.4 service layer is a closed library under the same licence, so it
is not prior art we can read. The public timeslot API is.

## Prior art

- ESP BLE host, `port/espressif/esp/src/hal/radio/ble/`: the host this design moves. Only its
  transport type, crypto provider type and identity setting change. ESP's controller takes raw HCI
  packets, so it needs no dispatcher.
- ESP `Controller` and `active`, `port/espressif/esp/src/hal/radio/bluetooth.zig`: one controller per
  boot behind a routing pointer, reused. ESP's callbacks push to an RTOS queue; the SDC is pulled
  from the foreground, so the nRF needs no queue.
- nRF 802.15.4 driver, `port/nordic/nrf5x/src/hal/radio/ieee802154.zig` and `hal.zig`: the comptime
  HAL option that adds vectors to `default_interrupts`, reused.
- nrf5x USB, `port/nordic/nrf5x/src/hal/usbd.zig`: "IRQ only as a wakeup; all work in foreground
  `poll`" ([interrupts.md](interrupts.md)), the same split as SWI5 and `service`.
- NCS v3.4.2 `subsys/mpsl/init/mpsl_init.c`, `subsys/bluetooth/controller/hci_driver.c` and
  `hci_internal.c`: init order, IRQ use, low-priority work in a thread, enable order, memory sizing
  and check, the reply slot, and the command-to-function dispatch. Read for behavior only.
- embassy `nrf-sdc`/`nrf-mpsl` and `trouble` (Apache-2.0/MIT): a non-Nordic host over the SDC
  without a preemptive kernel. Reused ideas: signal-then-run low-priority work, software P-256 in the
  host task, compile-time peripheral ownership, polled HFCLK, and timeslot flash. Its MPSL-preserving
  critical section is kept as our fallback.
- NimBLE: no public integration with the SDC was found; NimBLE ships its own controller for nRF5
  parts. Its host/transport split is the split `HCI_Transport` makes.

## Shared patterns

- [Interrupt handling and ISR routing](interrupts.md): HAL-owned vectors via `default_interrupts`,
  singleton routing, IRQ-as-wakeup with foreground work.
- [ESP radio stack and coexistence](esp-radio.md): BLE held for the boot; radio selection checked at
  compile time.
- [Base driver interfaces](base-interfaces.md): `HCI_Transport` and `SMP_Crypto` follow the pointer +
  vtable form.
- [USB device stack](usb-device.md): HFXO ownership rule updated for BLE images.

## Evidence

Planned; each item names the test the implementation adds.

- Dispatch, lengths, layouts and the Command Status set: `hci_command` host tests with a fake
  `sdc_hci_cmd_*` table.
- Pool bound: `memory` host test against the translated header macros.
- Phases, enable order, flag handling, reply slot and the `uninitialized` column: `ble` host tests
  with a fake MPSL and SDC that records call order and pends SWI5 during the process call.
- Refusals: host tests for `.timer0`, `.rtc1`, PPI channels 17–31 and group masks.
- Identity and the two reorder cases: host tests in `modules/ble/`.
- Moved host: its existing tests run from `modules/ble/`; the ESP BLE examples still build.
- Off means unchanged: `scripts/image_compare.sh` in the PR.
- On hardware (XIAO nRF52840 Sense):
  - P-256 benchmark (the gate).
  - Advertise and accept a connection from a PC.
  - Scan for and connect to an ESP32 peer running the existing ESP BLE self-test.
  - LE Secure Connections pairing.
  - Report the LFCLK source, longest masked interval, longest SWI5-to-`service` gap and `rand_poll`
    lengths.

## Open questions

- Flash writes while MPSL runs need a timeslot backend (nrf-mpsl `flash.rs` is the model). The KV
  store ([#45](https://github.com/valthon/microzig/issues/45)) depends on it.
- The bound MPSL tolerates on PRIMASK sections is unpublished. Measure first; a BASEPRI section is
  the fallback.
- Keeping a fault site across the reset needs a no-init RAM region, which the linker does not have
  yet.
- The largest `rand_poll` request is undocumented.
- 802.15.4 coexistence, as above, needs its own reviewed table changes.
