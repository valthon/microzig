# Interrupt handling and ISR routing

Covers: core/src/interrupt.zig, core/src/microzig.zig, core/src/utilities.zig, core/src/cpus/cortex_m.zig, port/espressif/esp/src/cpus/esp_riscv.zig, port/espressif/esp/src/cpus/esp_riscv/esp32_c6.zig, port/espressif/esp/src/hal/interrupt_encoding.zig, port/espressif/esp/src/hal/rtos.zig, port/espressif/esp/src/hal/radio.zig, port/espressif/esp/src/hal/radio/, port/raspberrypi/rp2xxx/src/cpus/hazard3.zig, port/wch/ch32v/src/cpus/main.zig, port/nordic/nrf5x/src/hal/usbd.zig, port/nordic/nrf5x/src/usb_test_microzig.zig, port/stmicro/stm32/src/hals/common/systick.zig

## Purpose

How an application installs interrupt handlers, how masking, priority and critical sections work,
and how a HAL driver whose vendor callback or vector has no context argument reaches its handle
(the singleton routing exception in [`ARCHITECTURE.md`](../../ARCHITECTURE.md)). It also lists the
ways drivers hand interrupt-time events to the foreground today, so a new driver picks one on
purpose. It does not cover RTOS scheduling (`hal/rtos.zig`) or the radio blobs' own tasks.

## Code map

- `core/src/microzig.zig:Options.interrupts`: the root file's `microzig_options.interrupts` fixes
  handlers at compile time; `overwrite_hal_interrupts` allows replacing a HAL vector.
- `core/src/utilities.zig:GenerateInterruptOptions`: one optional field per vector, typed by the
  CPU's handler type.
- `core/src/interrupt.zig`: the portable facade: `enable`/`disable` (comptime IRQ),
  `enable_interrupts`/`disable_interrupts`/`globally_enabled`, `enter_critical_section` →
  `CriticalSection.leave()` (restores the previous state, so sections nest), `Mutex`
  (HAL's `hal.mutex.Mutex`, else `CriticalSectionMutex`; `TestMutex` in host tests).
- `core/src/cpus/cortex_m.zig:generate_vector_table`: user handler, else
  `hal.default_interrupts`, else a panicking default; overriding a HAL vector is a compile error
  without `overwrite_hal_interrupts`. With a RAM vector table, `ram_vector_table` can be written at
  run time (`stm32/src/hals/common/systick.zig:init` installs SysTick that way). NVIC
  `set_priority` (`highest = 0`), `executing_isr()`.
- `port/espressif/esp/src/cpus/esp_riscv.zig`: ESP32-C3/C6 vectors are the CPU interrupt slots
  `interrupt1` to `interrupt31`; `map(source, slot)` routes a peripheral through the interrupt
  matrix. On the C6, IDs 3, 4 and 7 are local CLINT interrupts, not peripheral slots: `map` and
  `enable` panic for them (`esp_riscv/esp32_c6.zig:is_peripheral_interrupt`; C6 TRM v1.2 §1.6.2, as
  cited at `esp_riscv.zig:Interrupt`). Slot 29 is hard-coded by the HAL for BLE and for 802.15.4
  (without the coex scheduler, enabling both is a compile error); 30 (Wi-Fi) and 31 (RTOS) are the
  defaults of the `radio` and `rtos` HAL options. `Status.is_set` demuxes a shared slot,
  `set_priority` (`zero` masks, `lowest = 1`, `highest = 15`) plus a threshold; `_handle_interrupt`
  nests by raising the threshold. HAL vectors are not merged: the app installs the HAL's handler,
  and `expect_handler` checks it at compile time where a HAL calls it (`rtos.zig`, `radio.zig`,
  `radio/bluetooth.zig`).
- `port/raspberrypi/rp2xxx/src/cpus/hazard3.zig`: peripheral IRQs use core `Handler`; exceptions
  and core interrupts use Hazard3's own `InterruptHandler`.
- `port/wch/ch32v/src/cpus/main.zig`: a bare function-pointer handler; merges
  `default_interrupts` like Cortex-M.

## Invariants

- Handlers are chosen at compile time, with two run-time routes: the Cortex-M RAM vector table,
  and vendor blob callback tables (ESP Wi-Fi `osi.set_isr`, BLE `intr_alloc`). A HAL that writes a
  vector at run time documents it at the write.
- A critical section is `const cs = enter_critical_section(); defer cs.leave();` with nothing
  between ([`NO_SLOP.md`](../../NO_SLOP.md) §2.3).
- A HAL that owns a vector declares it: `hal.default_interrupts` on Cortex-M and WCH installs the
  HAL's handler (and an app override is a compile error); `expect_handler` on ESP makes a missing
  app handler a compile error. Exceptions today: ESP 802.15.4 checks its ACK handler in
  `validate_config` and returns `error.MissingAckInterrupt` at run time, only with enhanced ACK;
  stm32 `systick.zig:init` writes SysTick at run time and checks the flash-table case only with a
  `std.debug.assert`, which ReleaseFast and ReleaseSmall builds do not check. New HAL code uses a
  compile-time mechanism.
- Singleton routing, for new drivers: one `var owner: ?*Handle = null`, set under a critical
  section at init; a second init returns an error; every ISR or callback does
  `owner orelse return`; teardown clears `owner` under a critical section only when no completion
  can still arrive, and returns `error.Busy` otherwise (ESP-NOW's rule). The handle the caller owns
  holds all queues and operation state. `ARCHITECTURE.md` names ESP-NOW and 802.15.4 as users of
  the exception; BLE's `active` pointer and the Wi-Fi blob hooks in `radio/osi.zig` (`gpa`,
  `wifi_interrupt_handler`) are module-level state it does not name.

## Prior art: singleton routing

| Driver | Routing pointer | Second owner | Teardown with work in flight |
| --- | --- | --- | --- |
| ESP-NOW `radio/espnow_session.zig` | `owner: ?*Session` | `AlreadyInitialized` | `Busy` while a send completion is outstanding |
| ESP 802.15.4 `radio/ieee802154.zig` | `owner: ?*Radio` | `AlreadyInitialized` | no refusal: stops the MAC synchronously (operations are synchronous); `WouldBlock` from a coex callback; silent for a non-owner |
| ESP BLE `radio/bluetooth.zig` | `active: ?*Controller` | `AlreadyStarted` | none: one controller per boot |

ESP-NOW is the reference for a driver with asynchronous completions: read its `deinit` and the
test "delayed completion prevents teardown and reuse until the old send completes" before writing
a new one.

## Prior art: interrupt-time events to the foreground

| Pattern | Where | Use when |
| --- | --- | --- |
| Fixed ring in the handle, foreground polls | ESP-NOW `radio/espnow_state.zig` | bare metal, no RTOS, bounded backlog |
| Mostly polled: the foreground poll services hardware events itself under a critical section; the ISR runs only for enhanced-ACK turnaround and posts to atomics (`pending_events`, `ack_failed`) | ESP 802.15.4 `radio/ieee802154.zig` (`RxIo.poll`, `interrupt_handler`); the poll loops in `radio/ieee802154_rx.zig`, `radio/ieee802154_tx.zig` | operations short enough to block on |
| RTOS queue, `put_one_from_isr` + yield | ESP BLE `radio/bluetooth.zig` | RTOS present; consumer blocks |
| IRQ only as a wakeup; all work in foreground `poll` | nrf5x `hal/usbd.zig` | complex state better kept out of the ISR |
| Direct callbacks from the vendor task | ESP Wi-Fi `radio/wifi.zig` | vendor blob owns the thread; callback must not tear down |

The two queues here state an overflow policy: the ESP-NOW ring drops the newest frame and counts
it; the BLE queue latches an overflow error. A new queue states its policy too.

## Prior art: host tests that inject interrupts

- ESP-NOW: `radio/espnow_test_backend.zig` replaces the blob and calls the captured callbacks
  directly; the late-completion case is the test in `radio/espnow_session.zig` that calls
  `Driver(mock).send_callback` after `deinit`.
- ESP 802.15.4: `Mock`/`TestIo` in `radio/ieee802154_rx.zig` and `radio/ieee802154_tx.zig` script
  event sequences and a fake clock; the ISR body `service_events` itself has no host test.
- nrf5x USB: `port/nordic/nrf5x/src/usb_test_microzig.zig` fakes the CPU interrupt API and a USBD
  register block; tests set event registers and call `poll`.
- ESP coex: `radio/test_coex_host.zig` is the fake `microzig` of the `coex-callback-test`
  executable; it makes `mscratch` read non-zero (so `rtos.in_isr()` is true) and makes
  `enter_critical_section` unreachable, so a probed path that takes one traps.

None injects a hardware event *between* two steps of a foreground call. That is the gap the
interleaving harness planned for the ESP 802.15.4 interface driver fills
([#49 comment](https://github.com/valthon/microzig/issues/49#issuecomment-7225170964)).

## Evidence

- C6 CLINT IDs excluded from the peripheral mask that `map` and `enable` check:
  `esp_riscv/esp32_c6.zig`, test "C6 matrix interrupts exclude all four CLINT IDs". No test covers
  the panic wiring in `map` and `enable` itself.
- ESP-NOW teardown refuses `deinit` while a send completion is outstanding:
  `radio/espnow_session.zig`, test "delayed completion prevents teardown and reuse until the old
  send completes".
- ESP-NOW second owner rejected, and a callback after `deinit` reaches no owner:
  `radio/espnow_session.zig`, test "ownership, start requirement, init rollback, and late callback
  after deinit".
- No test protects the ESP 802.15.4 or BLE owner rules, or the Cortex-M `default_interrupts`
  override error; they rest on reading the code.

## Open questions

- Handler value shapes differ by CPU (core `extern union`; ESP `union(enum)` with a `*TrapFrame`
  argument; Hazard3's own union for core interrupts; WCH a bare function pointer), so
  `.interrupts = .{ .X = h }` is not portable.
- HAL-owned vectors: Cortex-M and WCH merge `default_interrupts`; ESP uses `expect_handler`;
  Hazard3 consults neither. One convention would let drivers move between ports.
- The core facade has no `set_priority`, and `is_enabled` is a `@compileError` stub although the
  CPUs implement it; drivers call `microzig.cpu.interrupt` directly. Priority enums run in
  opposite directions (Cortex-M `highest = 0`, ESP and Hazard3 `highest = 15`).
- No portable "in ISR" query: `executing_isr()` on Cortex-M, `rtos.in_isr()` on ESP.
- Second-owner errors differ (`AlreadyInitialized`, `AlreadyStarted`).
- `radio/osi.zig:wifi_interrupt_handler` is an optional initialised to `undefined`, then tested
  with `if`.
- `hazard3.zig:set_priority` and `get_priority` compute the shift as `4 * (num & 0x4)`, which is 0
  or 16; 16 does not fit the `u4`, so IRQs with bit 2 set hit a safety-checked `@intCast`. Four
  4-bit fields per window suggests `num & 0x3`. Not checked against the RP2350 datasheet or on
  hardware ([#56](https://github.com/valthon/microzig/issues/56)).
