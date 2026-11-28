# ESP Wi-Fi handle

Covers: port/espressif/esp/src/hal/radio/wifi.zig, port/espressif/esp/src/hal/radio/osi.zig, port/espressif/esp/src/hal/radio/espnow_session.zig, port/espressif/esp/src/hal/radio.zig

## Purpose

`radio.wifi.Wifi` is the caller-owned handle for the ESP32-C3/C6 Wi-Fi driver blob. It owns the
driver for one session, admits or refuses each call, and caches the station and AP state the blob
reports through events. The blob owns the protocol, its tasks and its buffers. Coexistence
scheduling, BLE and the OS adapter (`osi.zig`) are outside this doc; it covers only what the
handle relies on from them.

## Code map

All in `port/espressif/esp/src/hal/radio/`:

- `wifi.zig:Wifi`: the handle. `init`, `deinit`, `stop`, `connect` carry the full error contract
  in their doc comments.
- `wifi.zig:owner`: the routing pointer; `wifi.zig:on_event_post` routes blob events through it.
- `wifi.zig:release_single`, `wifi.zig:configure_single`: single-radio teardown and init steps.
- `osi.zig:WifiShutdown`: coexistence session stages, teardown resume and the packet worker join.
- `osi.zig:DisconnectGate`: refuses `disconnect` while a stop is stopping the driver.
- `espnow_session.zig:Session.init`: takes `*const Wifi` to check an interface is started.

## Invariants

- One owner. `owner` is set by `init` and cleared only by a `deinit` that returned success, both in
  a critical section. A second handle's `init` gets `AlreadyInitialized`; a call on a handle that
  does not own the driver gets `WifiNotInitialized`.
- Driver calls only after `init` succeeded. The `ready` flag is set when `init` succeeds and
  cleared with `owner`; until then driver calls return `WouldBlock`.
- The caller keeps the handle at one address, and the single-radio allocator given to `init`
  valid, until `deinit` succeeds and every call still running on the handle has returned. A coexistence image allocates from the attached
  `radio.SharedHeap`, which stays valid for the whole boot.
- No call overlaps `deinit` except `stop`, `deinit` and `connect`, which serialise as below.
- No event reaches a handle after its `deinit` returned. `deinit` deinitialises the driver and joins
  its packet worker before it clears `owner` (`release_single`, `osi.zig:WifiShutdown.deinit`,
  `Wifi.end_stop`), and events are posted from the blob's tasks.
- A failed `init` releases ownership unless it returns `WifiRollbackPending`; a failed `deinit`
  keeps it. Either way the caller retries with `deinit`.
- The globals left in `wifi.zig` are `owner` and what the blob holds the address of:
  `g_wifi_osi_funcs` and `boot_locks` (the blob keeps pointers to its API and global locks for
  the whole boot). The feature capabilities reach the blob by value, in the init configuration.

## Design tables

### Phases

| Phase | Entered by | Left by |
| --- | --- | --- |
| Free | boot, or a successful `deinit` | `init` claiming `owner` |
| Initializing | `init` claims `owner` | `init` returns: success → Ready; `WifiRollbackPending` → Rollback pending; other error → Free |
| Ready | `init` succeeded | `stop` or `deinit` counted |
| Stopping | a `stop` or `deinit` is counted in `calls.stops` | the last counted call returns |
| Rollback pending | `init` returned `WifiRollbackPending` (`ready` stays false) | a `deinit` that succeeds |

`calls.stops` counts each `stop` and `deinit` from its admission until it has unlocked and
returned, including one waiting for `stop_lock`. A waiter that gets the lock after another `deinit`
released the driver returns `WifiNotInitialized` (`Wifi.begin_stop`).

### Field ownership

| Field | Written by | Guard |
| --- | --- | --- |
| `owner`, `ready` | `init` (claim, finish), successful `deinit` | critical section |
| `calls` (stops, connects, give-ups) | `stop`, `deinit`, `connect` | critical section |
| `stop_lock` | `stop`, `deinit` | RTOS mutex, 5 s wait |
| `lifecycle_active` | coexistence lifecycle calls and `init` | atomic |
| `sta_state`, `ap_state`, `sta_disconnects` | `on_event_post` | atomics, under the routing critical section |
| `sta_connecting` | accepted `connect` (set, unless a stop gave up waiting for it), station events (clear) | atomic, both under a critical section |

`init` resets every field when it claims a free handle (`Wifi.claim_init`), after validating its
options and refusing a handle whose earlier calls have not all returned (`WifiSessionBusy`).

### Events × phases

| Event | Free | Any owned phase |
| --- | --- | --- |
| `StaStart`, `StaConnected`, `StaDisconnected`, `StaStop` | dropped, no listener call | set `sta_state`; count `StaDisconnected`; clear `sta_connecting` except on `StaStart` |
| `ApStart`, `ApStop` | dropped | set `ap_state` |
| other events | dropped | cache unchanged |

The cache update and the routing decision happen in one critical section. `Options.on_event` runs
afterwards, in the task that posted the event (observed to be the Wi-Fi task for station events), so it can still
run after `deinit` released the handle; it is given the event by value. Teardown from `on_event`
is refused or times out (see `Wifi.stop`): schedule it from an application task.

### Entry points × phases

| Call | Free | Initializing | Ready | Stopping | Rollback pending |
| --- | --- | --- | --- | --- | --- |
| `init` | runs | `AlreadyInitialized` (1) | `AlreadyInitialized` (1) | `AlreadyInitialized` (1) | `AlreadyInitialized` (1) |
| `deinit` | `WifiNotInitialized` | `WouldBlock` | runs | waits for the running stop (2) | runs |
| `stop` | `WifiNotInitialized` | `WouldBlock` | runs | waits for the running stop (2) | `WouldBlock` |
| `connect` | `WifiNotInitialized` | `WouldBlock` | runs | `WifiStopping` | `WouldBlock` |
| `disconnect` | `WifiNotInitialized` | `WouldBlock` | runs (3) | runs (3) | `WouldBlock` |
| `start`, `set_mode`, `apply`, `get_mode`, `scan`, `send_packet`, `get_sta_rssi`, `set_protocol`, `set_inactive_time`, `set_power_save_mode`, `apply_station_config`, `Interface.is_active`, `ScanResultsIterator.next`/`deinit` | `WifiNotInitialized` | `WouldBlock` | runs (4) | runs (4) | `WouldBlock` |
| `get_sta_state`, `get_ap_state` | last cached state | cached | cached | cached | cached |

1. In a coexistence image, `init` on the owning handle returns success without reading its
   configuration if the session is running and it gets the lifecycle claim, and `WifiSessionBusy`
   otherwise; `init` from a radio callback returns `WifiSessionBusy`, also on a free driver.
2. Single-radio: waits up to 5 s for `stop_lock`, then `Timeout`; `WifiStopping` from the task
   that holds it. Coexistence: `WouldBlock` while another lifecycle call holds the claim or from a
   radio callback. `deinit` returns `Timeout`, keeping everything, if a connect admitted before it
   is still in flight after 1 s; `stop` goes on without it.
3. Coexistence: `WouldBlock` while a `stop` or `deinit` is stopping the driver, which first waits
   for disconnects already admitted (`osi.zig:DisconnectGate`).
4. Coexistence: `start`, `set_mode`, `apply` and `stop` return `WouldBlock` while another
   lifecycle call holds the claim, from a radio callback, or while a teardown stage is pending.
   Scan iterators must be consumed or deinitialised before the next `scan` and before `deinit`.

### Timing budget

| Wait | Budget | Where |
| --- | --- | --- |
| Another stop or deinit (Wi-Fi-only; coexistence returns `WouldBlock`) | 5 s | `Wifi.begin_stop` |
| Connects admitted before a stop | 1 s | `Wifi.wait_for_connects` |
| `StaDisconnected` after the stop's `disconnect` | 1 s when connected, 100 ms when connecting; 100 ms more once it arrives | `Wifi.leave_ap` |
| Coexistence disconnects already admitted | no limit | `osi.zig:DisconnectGate.close` |
| C6 blob TX drain inside `esp_wifi_stop` | up to 500 retries 10 ms apart | `osi.zig:stop_driver` |

The 1 s and 100 ms deadlines are checked between sleeps, so a task above the caller's priority
can stretch them.

## Prior art

- `ieee802154.zig:Radio`: the same `owner` pattern; its operations are synchronous and its
  teardown cannot fail once it starts (a coexistence `deinit` from a callback returns
  `WouldBlock` before starting), so it needs no stop counting or retryable teardown.
- `espnow_session.zig:Session`: refuses `deinit` while a send completion can still arrive. Wi-Fi
  instead drains connects and keeps ownership on a failed teardown, because its events come from a
  vendor task and `connect` must stay callable from `on_event`.

## Shared patterns

- [Interrupt handling and ISR routing](interrupts.md): the singleton routing exception.

## Evidence

Host tests in `wifi.zig`; the port's test step runs them in a coexistence and a Wi-Fi-only
selection, and some skip in one of them:

- one owner: "a second Wi-Fi handle cannot change the running driver or its own state",
  "public Wi-Fi calls before init and after final deinit return WifiNotInitialized"
- calls only after init: "public Wi-Fi operations cannot enter the driver during init or rollback"
- no late events: "events posted with no Wi-Fi owner are dropped"
- serialised teardown: "a stop queued across single-radio teardown prevents reuse until it
  returns", "deinit times out with a counted connect and ordinary stop still gives up"
- rollback and retry: "single-radio init failure releases the driver and radio or leaves teardown
  retryable", "coex Wi-Fi init releases each acquired stage and only the owner retries rollback",
  "public Wi-Fi calls wait for a pending teardown or another lifecycle owner"
- worker teardown: "single-radio cleanup joins and reclaims both packet-worker deletion paths"
- partial-stop panics, coexistence only, one per process under `stop_panic_runner.zig`: "Wi-Fi stop panics when the PP queue rejects the interface stop", "… the
  hardware stop", "… both stops", "Wi-Fi stop panics when an allocation fails after the interfaces
  stopped"

On hardware, image boot: `selftest_wifi_modes` and `selftest_wifi_lifecycle` on an ESP32-C3, a
Super Mini ESP32-C6 and a XIAO ESP32-C6; `selftest_wifi_tx_done` and `selftest_espnow` on the
ESP32-C3 and Super Mini ESP32-C6; `selftest_wifi_softap_echo` between the ESP32-C3 and the XIAO
ESP32-C6 in both roles; `selftest_espnow_coex` between the two ESP32-C6 boards;
`selftest_coex_wifi_ble` on the Super Mini ESP32-C6 with a XIAO ESP32-C6 BLE central.

## Open questions

- Leaving the AP and `on_event` scheduling across owner release are not modelled by the host tests.
