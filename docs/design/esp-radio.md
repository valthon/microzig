# ESP radio stack and coexistence

Covers: port/espressif/esp/README.md, port/espressif/esp/build.zig, port/espressif/esp/src/hal.zig, port/espressif/esp/src/hal/radio.zig, port/espressif/esp/src/hal/radio/, port/espressif/esp/src/hal/rtos.zig, port/espressif/esp/src/hal/analog/esp32_c6.zig, port/espressif/esp/src/hal/coex_callback_test.zig

## Purpose

The C3 and C6 radio HAL connects vendor libraries to MicroZig's RTOS and keeps the timer worker
live while a radio holds a reference. In C6 Wi-Fi + BLE images the HAL installs the coexistence
adapter for the vendor RF arbiter. The IEEE 802.15.4 MAC has its own state machine.

## Code map

- `port/espressif/esp/src/hal.zig:HAL_Options` carries the radio selection, checked at compile
  time against `port/espressif/esp/src/hal/radio/radios.zig:supported_coex_sets`.
- `port/espressif/esp/src/hal/radio.zig:init` takes a common reference and
  `port/espressif/esp/src/hal/radio.zig:deinit` releases it.
- `port/espressif/esp/src/hal/radio/coex.zig:init` installs the coexistence adapter and runs pre-init.
- `port/espressif/esp/src/hal/radio/osi.zig:export_symbols` exports C shims, and
  `port/espressif/esp/src/hal/radio/wifi.zig:g_wifi_osi_funcs` is the Wi-Fi callback table.
- `port/espressif/esp/src/hal/radio/osi.zig:phy` holds shared PHY state.
  `port/espressif/esp/src/hal/radio/timer.zig:task_fn` dispatches PHY and blob timers.

## Invariants

**Select the image first.** Validation accepts one radio or Wi-Fi + BLE. Wi-Fi is the default and
supplies ESP-NOW. The BLE controller and IEEE 802.15.4 HAL are C6-only. The 802.15.4 coexistence
branches have no supported image selection.

**Acquire from a task.** Enable the RTOS and install the radio handler. Each acquire checks for
the PLL CPU clock (C6 TRM v1.2 §8.2.4.4, as cited at `port/espressif/esp/src/hal/radio.zig:init`).
The first starts the timer worker, installs a reserved PHY timer, sets up power and clocks, maps
interrupts and calibrates the slow clock on C6. Coex startup registers the adapter and reserves
its scheme timer before calling pre-init, whose synchronous `setfn` takes the reservation.

**Keep the allocation route live.** In coexistence, call
`port/espressif/esp/src/hal/radio.zig:attach_shared_heap` once before init. Keep the heap handle
and backing buffer stationary and dedicated for the boot. The heap backs the timer worker,
timer nodes, Wi-Fi eloop reservations and heap-backed OSI allocations for both radios. BLE NPL uses
the controller allocator. Before attach, a valid common init returns `SharedHeapNotAttached` and OSI
allocations fail. A second attach from a task returns `SharedHeapAlreadyAttached` and keeps the first heap.
In single-radio images, serialize common acquire and release and keep the first acquire's
allocator and storage live through final release. Later acquires reuse that allocator.

**Keep the counts separate.** The common count tracks successful acquires. The coexistence PHY
uses per-modem flags under its mutex. The first enable opens the PHY, runs calibration on first
use or restores it on wake, and arms tracking. Only the last enabled modem's disable disarms
tracking and closes the PHY. Wi-Fi and BT/802.15.4 have separate tracking timestamps. Update C6
coexistence clock counts for Wi-Fi, BLE, 802.15.4 and calibration in the same critical section
that applies the gates (`port/espressif/esp/src/hal/analog/esp32_c6.zig:shared_clocks_set_enabled`).
The coexistence BT baseband has its own mutex and runs blob init on the first acquire.

**Keep timer keys and callback arguments live.** Call timer hooks from a task. Register a stable
key with `setfn` before arming and keep it stable while registered. The blob's void registration hook
panics if it cannot allocate a new timer. Millisecond arms accept the full `u32` range. Under the list mutex the worker
disarms a one-shot or advances a repeating timer, then invokes the callback outside the mutex.
Keep the argument valid until the selected callback returns, even after re-registration, disarm or removal.
Quiesce timer producers before final release. Run final release from another task. A single-radio
final release from the timer worker panics before attempting the join.
In either image, timer callbacks must return without waiting for deferred work that can trigger final release.
In a coexistence image they must also not wait for work that takes the common lifecycle mutex, even
work that only acquires a reference: final release holds `coex_init_mutex` while it joins the timer
worker (`port/espressif/esp/src/hal/radio.zig:deinit`), so a callback waiting on a task blocked in
`radio.init` deadlocks teardown.

**Respect the ABI at the adapter boundary.** Pass a non-returning C entry point and a non-null,
aligned, writable `usize` handle slot to both task-create hooks
(`port/espressif/esp/src/hal/radio/osi.zig:task_create_common`). Keep the C task-name storage valid
for the life of the task because `port/espressif/esp/src/hal/rtos.zig:spawn` stores the slice by reference.
Creation ignores core affinity and returns 1 on success or 0 on spawn failure. The delete slot
exits the calling task for a null or current-task handle. Given another quiesced blob task's
handle, it removes that task from the scheduler and frees it through the callback allocation route.
Wi-Fi teardown retains ownership of the packet worker's allocation until it joins the worker.
Task queue send and
receive return 1 or −1. A queue requested as three four-byte entries uses eight-byte items for
the legacy supplicant workaround (esp-wifi 0.14.1, WIFI-6676). Size the send and receive buffers
for the stored item width. Other requests retain both dimensions. The OSI allocators reject
zero-sized or overflowing allocations before reaching the allocator. The static Wi-Fi queue also
rejects negative dimensions.
Pass an initialized, aligned, writable `u32` wake flag to
`port/espressif/esp/src/hal/radio/osi.zig:queue_send_from_isr`, which ORs the result into it.
Task queue operations and semaphore take use zero ticks to probe and the blocking sentinel to
wait indefinitely. BLE's void NPL event and event-queue init hooks panic on exhaustion. Coex NPL
callout init can return `ENOMEM` for either object allocation. Wi-Fi event-group and NVS slots panic.
The C6 Wi-Fi modem-sleep retention hooks are unimplemented.

### Protocols

**Wi-Fi** takes a common reference before driver init and calls the blob's coex init in a
coexistence image. Both selections install the OSI table and boot locks before driver init
(`port/espressif/esp/src/hal/radio/wifi.zig:install_boot_locks`). The blob calls the PHY and clock hooks.
Coex Wi-Fi reserves the eloop timer and mutex before supplicant init and an ioctl for stop.
Driver deinit can still fail to allocate its own ioctl. The [ESP Wi-Fi handle](esp-wifi-handle.md)
describes packet worker cleanup before common release.

**ESP-NOW** borrows Wi-Fi's common reference. Give
`port/espressif/esp/src/hal/radio/espnow.zig:Session` a Wi-Fi handle with a started STA or AP.
Use one calling task and keep the session stationary. Wait for session deinit to succeed before
stopping or reconfiguring Wi-Fi. Use only the wrapper to call ESP-NOW while the session is active.
An outstanding send completion makes deinit return `Busy` in either image.

**BLE** starts from a task and checks the CPU clock configuration (C6 TRM §8.2.4.1, as cited at
`port/espressif/esp/src/hal/radio/bluetooth.zig:Controller.start`). It acquires a common reference before
starting NPL and enabling controller clocks. In coexistence it registers status callbacks before
coex init, then initializes the controller and stack. It enables the BT PHY modem, baseband and coex
before enabling the stack and controller. The higher-priority coex NPL callout worker must block
for at least one RTOS tick between polls so startup can resume after spawn. BLE-only uses a private
PHY and tracking task. Keep the controller and allocator live and stationary for the boot. BLE
holds its reference for the boot because it has no shutdown API. A failure after claim requires reboot.

**IEEE 802.15.4** acquires the common layer before clocks, PHY, baseband and MAC setup. Serialize calls
on one task and keep the handle and DMA buffers stationary through teardown. Teardown stops and
resets the MAC before releasing PHY, clocks and the common reference (`port/espressif/esp/src/hal/radio/ieee802154.zig:Radio`).

## Design tables

| Phase | Owners and transitions |
| --- | --- |
| No references | The first acquire starts common setup. |
| Starting | A failure drops the reference and joins any worker it started. Earlier clock and interrupt setup is left in place. |
| In use | Wi-Fi and 802.15.4 release their own references at teardown. Call `radio.deinit` only for a reference you acquired directly. Later acquires and nonfinal releases leave the worker running. |
| Final release | The releasing task sets the atomic exit flag and gives the reload semaphore to wake a worker waiting on it. During an overdue timer sleep the worker checks the flag when the sleep ends at the next RTOS tick. If a callback is running, the worker checks the flag when the callback returns. The releasing task joins the worker, then frees it and the timer nodes through the original route. |

The coex init mutex serializes heap attachment, acquire and release. The timer list mutex
serializes hooks and worker scans. The static coex adapter, semaphore slots and ROM table survive
final release. The blob can reuse the core semaphore on retry after calling the delete hook during
failed pre-init. Preserve the slot's state and ownership in `port/espressif/esp/src/hal/radio/coex.zig:keep_semaphore`.
The core lock uses the RTOS context query to select task or ISR slots. The scheme lock and coex
Wi-Fi use task slots. See `port/espressif/esp/src/hal/radio/coex.zig:adapter`.

| Entry or event | Context and contract |
| --- | --- |
| Heap attach, common acquire and release, and BLE start | In coexistence they return `WouldBlock` in ISRs or callbacks marked by `port/espressif/esp/src/hal/radio/callback_context.zig:Scope`. Defer these calls to an application task. ESP-NOW init and deinit return `Busy` in these contexts. |
| Coex task semaphore slots | They panic on ISR entry. Take forwards the timeout and give returns 0 when full. |
| Coex ISR semaphore slots | Take polls and ignores its wake pointer. Give returns 0 when full and sets the optional wake flag on a higher-priority wake. |
| Coex scheme timer slots | They panic on ISR entry. Scheme `setfn` requires the pre-init reservation. |
| ISR queue send and yield | These hooks are silent in all images. Coex BLE status set/clear hooks are also silent. |
| Wi-Fi interrupt dispatch | The initial callback slot is empty. Registration and removal publish the callback and argument together with interrupts masked. Dispatch calls an installed handler. |
| Wi-Fi ISR context query | Reports the RTOS interrupt context, including false from tasks. |
| Timer deadline | The worker treats a zero repeat period as one microsecond and checks for exit between callbacks. It samples the clock again after callbacks and immediately rescans if a one-shot or repeat that has yet to run in this pass is due. Each timer runs at most once per pass, including a one-shot that rearms itself. If only timers that already ran are overdue, the worker sleeps until the next RTOS tick even when a reload is pending. Timers armed during that sleep are checked in the next pass. Other finite waits request at least one RTOS tick and can wake on reload. |

## Prior art

The HAL credits esp-rs esp-radio. The coex layout and PHY bookkeeping follow IDF v5.5.1 as cited
at `port/espressif/esp/src/hal/radio/coex_abi.zig:Adapter` and `port/espressif/esp/src/hal/radio/phy_modems.zig:State`.

## Shared patterns

[Interrupt handling and ISR routing](interrupts.md) covers slot routing, singleton owners and
handoff, including the ESP-NOW session.

## Evidence

The ESP port's `test` step (`port/espressif/esp/build.zig:build`) runs these host checks. Paths starting with `radio/` are relative to `port/espressif/esp/src/hal/`.

- `hal-host-coex` imports the shared tests via the HAL. Selection is checked by “each single radio is accepted and Wi-Fi is the default” and “Wi-Fi + BLE is the supported coexistence set” in `radio/radios.zig`. The `invalid-radio-selection` builds check rejected selections.
- Common lifetime, allocation and entry guards are checked by “coexistence radio allocations come from the shared heap and survive release of the first radio owner”, “a coexistence radio init before attach_shared_heap returns SharedHeapNotAttached and acquires nothing”, “attach_shared_heap attaches once; a second attach is rejected and keeps the first heap” and “host radio rejects interrupt entry and a non-PLL clock before acquiring resources” in `port/espressif/esp/src/hal/radio.zig`.
- “deinit returns every node to the allocator it is given” in `radio/timer.zig` checks list reclamation. “high priority repeating 500 us timer lets a lower priority task run” in `radio/coex_timer_wait.zig` models the shared wait policy. The timer worker tests exercise deadline crossings during callbacks, self-rearming one-shots, and exit between callbacks.
- “first enable powers on and only the last modem's disable powers off”, “tracking groups Wi-Fi apart from BT and 802.15.4 with separate stamps” and “802.15.4 shares the BT tracking group” in `radio/phy_modems.zig` check bookkeeping. “calibration and 802.15.4 release only their own references” and “baseband init runs only on transition from zero users” in `radio/shared_clocks.zig` check the counter rules.
- `coex-layout` compiles the adapter layout assertions for RV32. `coex-callback-test` checks silent status/yield, task semaphore panics, the timer guards with a stub target, and BLE start resuming after spawn in a 100 Hz scheduler model where a one-millisecond wait would round down to zero. “core ISR slots report a wake and ordinary scheme slots forward the task timeout” and “coex and Wi-Fi retain boot locks and ROM callbacks across fresh radio arenas” in `radio/coex.zig` check slot behavior and boot storage with fakes, including core semaphore reuse after failed pre-init.
- “public Wi-Fi deinit completes when StaStop calls public init” checks common lifecycle refusal from a Wi-Fi callback. “public Wi-Fi stop hands every stop step the reserved ioctl” checks the coex stop allocation. `hal-host-wifi_only` runs “single-radio adapter runs before driver init and releases the radio on failure”. All three are in `radio/wifi.zig`. See the [Wi-Fi evidence](esp-wifi-handle.md#evidence) for the other handle and cleanup tests.
- “a driver deinit without heap for its ioctl stays pending and is retried” and “a deleted blob task is freed into the callback route, the PP task only by teardown” in `radio/osi.zig` check deinit allocation and worker reclamation.
- The separate ESP-NOW host test artifact runs “ownership, start requirement, init rollback, and late callback after deinit”, “delayed completion prevents teardown and reuse until the old send completes”, “ESP-NOW rejects lifecycle re-entry before changing ownership” and “a Wi-Fi + BLE selection runs ESP-NOW over Wi-Fi” in `radio/espnow_session.zig`. These tests exercise the wrapper and leave Wi-Fi ordering and vendor API exclusivity to callers.
- “callout init returns ENOMEM and can retry after its event allocation fails” in `radio/ble/npl.zig` covers coex NPL callout rollback. There is no direct test for void-hook exhaustion.
- The port records both start orders and Wi-Fi cycling under a live BLE link with
  `selftest_coex_wifi_ble` on Super Mini ESP32-C6. [Port README](../../port/espressif/esp/README.md)
- There are no direct tests of common hardware bring-up and rollback, hardware PHY or clock
  updates, worker join or timer key and argument lifetime, or single-radio allocator
  routing across overlapping references. Blob core lock routing, the general OSI task and queue
  contracts, Wi-Fi timer slot context, BLE start admission and post-claim failure, and
  802.15.4 teardown order also lack direct tests.

## Open questions

- `port/espressif/esp/src/hal/radio/osi.zig:WifiShutdown.delete_task` leaves a self-deleting task's stack and control block allocated, and Wi-Fi teardown reclaims only the packet worker.
