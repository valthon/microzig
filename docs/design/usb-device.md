# USB device stack

Covers: core/build.zig, core/src/microzig.zig, core/src/core/usb.zig, core/src/core/usb/, port/nordic/nrf5x/build.zig, port/nordic/nrf5x/src/hal.zig, port/nordic/nrf5x/src/hal/usbd.zig, port/nordic/nrf5x/src/hal/usbd/, port/nordic/nrf5x/src/usb_tests.zig, port/raspberrypi/rp2xxx/src/hal/usb.zig, port/raspberrypi/rp2xxx/src/hal/clocks/, port/wch/ch32v/build.zig, port/wch/ch32v/src/hals/clocks.zig, port/wch/ch32v/src/hals/time.zig, port/wch/ch32v/src/hals/usbd.zig, port/wch/ch32v/src/hals/usbfs.zig, port/wch/ch32v/src/hals/usbhs.zig, port/wch/ch32v/src/usb_tests.zig, port/stmicro/stm32/src/hals/STM32F103/usb.zig, port/stmicro/stm32/src/hals/STM32F103/time.zig, port/stmicro/stm32/src/hals/STM32F103/usb_internals/, examples/stmicro/stm32/src/stm32f1xx/usb_cdc.zig, examples/stmicro/stm32/src/stm32f1xx/usb_hid.zig, port/espressif/esp/src/hal/usb_serial_jtag.zig, examples/nordic/nrf5x/src/cdc_console.zig, examples/nordic/nrf5x/src/usb_hid.zig, examples/raspberrypi/rp2xxx/src/pio_selftest/selftest.zig, examples/raspberrypi/rp2xxx/src/usb_cdc.zig, examples/wch/ch32v/src/usb_cdc.zig

## Purpose

Core builds descriptors and handles device requests. Classes receive interface requests and completions.

ESP USB-Serial-JTAG provides fixed-function FIFO I/O outside this stack (`port/espressif/esp/src/hal/usb_serial_jtag.zig:read`).
The logger built on it is described in [usb_serial_jtag_logger.md](usb_serial_jtag_logger.md).

## Code map

- `core/src/core/usb.zig:DeviceController` takes the port's `DeviceCapabilities` and one
  configuration. Ports dispatch `on_setup_req`, `on_buffer` and `on_bus_reset` from poll.
- `core/src/core/usb.zig:DeviceInterface.VTable` supplies packet I/O, endpoint control and address updates.
- `core/src/core/usb/configuration.zig:Configuration` binds descriptors to runtime handlers at compile time.
- `core/src/core/usb/types.zig:SetupPacket` defines the SETUP wire layout.

## Invariants

- **Configuration lifetime.** Zero deselects. Selecting the configuration recreates its classes, even
  when it is already active. (Core today accepts any nonzero value, including one the descriptor
  does not advertise; that is a defect, see Open questions.)
  Use `ep_close_all` to retire endpoints and completions before replacement. For each class in turn,
  core opens OUT, initializes the runtime, then opens IN. Data endpoints open at DATA0.
- **Class lifetime.** Keep the port and controller at fixed addresses while classes borrow their storage.
  After poll, reacquire runtimes through `drivers()` and discard old state even if addresses match.
- **Nordic lifetime.** Invalidate the runtime on detach and wait for a fresh configuration before
  resuming I/O. `examples/nordic/nrf5x/src/cdc_console.zig:poll` clears the controller when
  `is_connected()` is false. Detect replacement across polls with `get_configuration_generation()`.
- **Packet lifetime.** An open, healthy, idle IN endpoint must copy and accept the whole submission
  before returning when it fits within the endpoint's maximum packet size; it never takes only a
  prefix. Class drivers rely on this (`core/src/core/usb.zig:DeviceInterface`). Publish busy before submission. Use nonempty vectors with payload in the first write
  slice or `&.{""}` for a zero-length packet (ZLP). A zero return can mean acceptance or refusal.
- **Control lifetime.** A fresh SETUP replaces pending control data and address changes.
  Retire stale EP0 packets and completions before dispatch. Suspend has no portable class callback.

To add a class, supply a `driver_info` factory returning `core/src/core/usb.zig:DriverInfo`.
Use the descriptor allocator within port limits, start with an interface or association,
and match `Runtime.handlers` names to endpoint descriptor fields. In `Runtime.init`, rely only on
your own OUT endpoints being open and use any supplied `Alloc` storage. An optional IN-open
callback can run before other IN endpoints open or a later class's runtime exists.

Return null from `class_request` to refuse SETUP, an empty slice to accept, or a nonempty IN reply.
Keep replies stable until copied or abandoned. A class that consumes control-write payloads
declares both `class_data` and its length bound, `class_data_len` (one without the other is a
compile error). A class that ignores accepted payloads omits both; on a port with
`control_out_data`, core then drains the data before the status stage.
If a payload is required, reject invalid announced lengths at SETUP because zero bypasses
`class_data`. Validate the assembled payload before committing changes.

## Design tables

### Phases

| Phase | Core or class action | Port action |
| --- | --- | --- |
| EP0 SETUP | Core drops the previous transfer and dispatches the request. | Replace the old EP0 decision and recover from any STALL. |
| EP0 IN data | Core caps the reply at `wLength` and advances it on IN completions. | Take one packet per write and keep status OUT receivable after the last IN. |
| EP0 OUT data | Core listens, reads each packet, and collects or discards the data. | With `control_out_data` set, withhold each data OUT ACK until `ep_listen(.ep0, len)`. |
| EP0 status IN | Core requests status after acceptance and applies a pending nonzero address on EP0 IN completion. | For software SET_ADDRESS, send status at the old address and apply the new one when core calls `set_address`. |
| EP0 STALL | Core leaves a refused request unanswered. | After SETUP or data OUT, STALL if core neither listened nor replied, subject to hardware-owned SET_ADDRESS. |
| Data IN idle → armed → idle | The class marks busy before submitting and handles completion. | Release the buffer before notifying core. |
| Data OUT idle → listening → reported | The class keeps at most one listen outstanding per endpoint. | Keep the reported packet available until the read. |

All portable ports supply `ep_close_all` and set `control_out_data`. Core refuses overruns and requests
status after data acceptance or discard. With the flag clear, the port handles data after SETUP.

Core uses `ep_writev` with `&.{""}` for status and when a reply short of `wLength` ends on a full packet.
Interpret the write by phase and start software EP0 at DATA1 after SETUP (USB 2.0 §5.5.5, as
cited at `port/raspberrypi/rp2xxx/src/hal/usb.zig:Polled.poll`).

### Ownership

| State | Owner | Handoff |
| --- | --- | --- |
| Class runtime and `driver_alloc` | Core | `Configuration.init` lends stable allocation storage through the configured lifetime. |
| EP0 payload | IN reply provider and core | Core borrows the reply through its last copy or abandonment, and lends assembled OUT data for one callback. |
| Class data and readiness | Class | Readiness authorizes a packet operation and lasts only within the current configuration. |
| Armed IN or OUT storage | Port hardware | Establish completion or withdrawal before reusing storage. See [Open questions](#open-questions) for RP2040 B0/B1. |
| Completed OUT packet | Port | The class copies it with `ep_readv` before rearming. |

### Events × phases

| Event | Unconfigured | EP0 active or stalled | Data endpoints active |
| --- | --- | --- | --- |
| SETUP | Core can serve device requests. | The port replaces the transfer before dispatch. | Selecting a configuration retires the old endpoints. |
| IN completion | EP0 completions still run. | Advance IN data or commit the pending address. | Report completion against the current endpoint and direction. |
| OUT arrival | Core drops data-endpoint callbacks. | Expose one listened-for packet to `ep_readv` during `on_buffer(.out(.ep0))` or consume status OUT locally. | Report one packet per listen. |
| Bus reset | The port handles the hardware reset and reports it to core. | Core abandons data and pending address. | Core drops the runtime after calling the port's endpoint retirement hook if supplied. |

### Entry points × phases

| Call | Before an operation | During or after an operation |
| --- | --- | --- |
| `poll` | Initialize the port and follow its timing budget. | Dispatch in foreground, serialized with class access. |
| `ep_writev` | On an open, idle data IN endpoint, keep the total vector length within its advertised maximum packet size. | Wait for completion before submitting another packet. |
| `ep_listen` / `ep_readv` | Listen on an open OUT endpoint with no outstanding listen. | Read once with capacity for the whole packet, before relistening or requesting EP0 status. |
| `ep_close_all` / `ep_open` | Retire the old endpoints before opening replacements. | Drop old completions before an endpoint number and direction can be reused. |
| STM32F103 `EpControl` | Match each `Config.endpoints` entry's `endpoint` and `ep_control` numbers so I/O uses the PMA entry assigned during init. | Wait for TX completion before reusing armed PMA because `write_buffer`, `USB_send` and `ZLP` lack busy checks. |
| STM32F103 `USB_read` | Keep the caller-provided `Config.RX_buffer` alive while USB uses it. | The call rearms RX, so consume or copy the borrowed bytes before the next read replaces them. |

### Timing budget

| Path | Requirement or bound |
| --- | --- |
| RP2xxx startup and poll | When supplying a custom clock configuration, enable `clk_usb` before `Polled.init` by applying the USB generator settings in `port/raspberrypi/rp2xxx/src/hal/clocks/rp2040.zig:config.Global` or `port/raspberrypi/rp2xxx/src/hal/clocks/rp2350.zig:config.Global`. Keep foreground polls less than 10 ms apart, the interval `port/raspberrypi/rp2xxx/src/hal/usb.zig:Polled.poll` assumes when servicing reset after packet events. |
| Nordic startup and power | Start HFXO before polling and keep it running (nRF52840 PS v1.1 §6.35.7.1, as cited at `port/nordic/nrf5x/src/hal/usbd.zig:USBD`). Poll regularly in foreground even without a USBD IRQ so attachment and detachment can advance. |
| RP2xxx withdrawal | `port/raspberrypi/rp2xxx/src/hal/usb.zig:Polled.withdraw_buffer` panics if its abort wait expires. See [Open questions](#open-questions) for RP2040 B0/B1. |
| WCH startup | Configure and enable the chosen USB peripheral clock before `Polled.init` using `enable_usbd_clock`, `enable_usbfs_clock` or `enable_usbhs_clock` in `port/wch/ch32v/src/hals/clocks.zig`. For USBD, start SysTick with `port/wch/ch32v/src/hals/time.zig:init` before `Polled.init` because its delays wait on that counter. |
| STM32F103 startup | Configure and enable the USB clock and start HAL time before `usb_init` or `usb_runtime_init`, as both examples do with `time.init_timer(.TIM2)`. A positive startup delay cannot expire while `port/stmicro/stm32/src/hals/STM32F103/time.zig:get_time_since_boot` returns zero for an uninitialized source. Provide the external D+ pull-up required by both STM32F103 examples. |
| Nordic DMA and wake | `port/nordic/nrf5x/src/hal/usbd.zig:USBD` bounds wake and EasyDMA waits in iterations. An EasyDMA timeout quarantines the instance until system reset. |

### Spec rules

| Clause and code citation | Rule |
| --- | --- |
| USB 2.0 §5.5.5 in `core/src/core/usb.zig:DeviceController.on_setup_req` | A new SETUP ends the old transfer. |
| USB 2.0 §5.5.3 and §8.5.3 in `core/src/core/usb.zig:DeviceController` | End data on a short packet or at the requested length. |
| USB 2.0 §9.2.7 and §8.5.3.4 in the header of `core/src/core/usb/ControlRequest.zig` | Stall an unsupported control request. |
| USB 2.0 §9.4.2, §9.4.7 and §9.1.1.5 in `core/src/core/usb.zig:DeviceController` | GET_CONFIGURATION returns the selected descriptor's value or zero. The port reopens data endpoints at DATA0 on each selection. |
| USB 2.0 §5.8.3 in `core/src/core/usb/drivers/CDC.zig:Runtime` | CDC uses a ZLP when a full bulk packet completes and no further data has been queued. |

### Consumer trace

| Port | Context | Controller-specific handoff |
| --- | --- | --- |
| `port/nordic/nrf5x/src/hal/usbd.zig:USBD.poll` | For IRQ wakeups, configure peripheral interrupt sources and explicitly enable the NVIC USBD line that init masks. Mask the line in the handler and signal foreground to poll before re-enabling it. | Foreground polling works without IRQs and is required for VBUS changes even with wakeups. OUT listen gates notification and can pend the IRQ for a waiting packet. |
| `port/raspberrypi/rp2xxx/src/hal/usb.zig:Polled.poll` | Follow the foreground polling interval above. | Withdraw both EP0 buffers at SETUP and service reset after packet events. A longer poll gap can let an earlier reset erase a later SETUP's state. |
| `port/wch/ch32v/src/hals/usbd.zig:Polled.handle_out` | Foreground via `poll(false, controller)`. | Stage EP0 OUT from PMA and set RX to NAK before handing the data to core. |
| `port/wch/ch32v/src/hals/usbfs.zig:Polled.ep_writev` | Keep the CPU IRQ disabled and call `poll(false, controller)`. | Arm status OUT at the current toggle when writing control IN. |
| `port/wch/ch32v/src/hals/usbhs.zig:Polled.poll` | Keep the CPU IRQ disabled and call `poll(false, controller)`. | Drop a co-latched transfer event when processing SETUP and leave status OUT armed by the IN write. |
| `port/stmicro/stm32/src/hals/STM32F103/usb_internals/usb_ll.zig:usb_handler` | Install this handler on `USB_LP_CAN1_RX0` before USB init and serialize foreground calls with its callbacks. | With `port/stmicro/stm32/src/hals/STM32F103/usb.zig:usb_ll`, the app owns EP0 sequencing and address timing and must discard the old transfer's state at each SETUP. On reset, clear application configuration and pending control state and release transfer waiters. A custom `Config.reset_callback` must also restore address zero and reset endpoints or call `port/stmicro/stm32/src/hals/STM32F103/usb_internals/usb_ll.zig:default_reset_handler`. |

Nordic's `port/nordic/nrf5x/src/hal/usbd/ep0.zig:Control` starts read status after the last IN completion.
Hardware handles SET_ADDRESS and its status (nRF52840 PS v1.1 §6.35.9, as cited there). RP2xxx and WCH filter status OUT via `core/src/core/usb/ControlRequest.zig:out_packet`.

| Class | OUT and IN readiness | Interface requests |
| --- | --- | --- |
| `core/src/core/usb/drivers/CDC.zig:Runtime` | Init listens and starts IN ready. A terminating ZLP holds IN busy until completion. | SET_LINE_CODING validates the delivered payload in `class_data`. |
| `core/src/core/usb/drivers/HID.zig:Runtime` | Init listens and starts IN ready, and each IN completion restores readiness. | Serves HID and report descriptors and accepts writes without a data hook. |
| `core/src/core/usb/drivers/EchoExample.zig:Runtime` | The OUT handler reads and rearms, and echoes only after IN readiness is signalled. | Accepts interface requests without a data hook. |
| `port/raspberrypi/rp2xxx/src/hal/usb.zig:ResetDriver` | Interface only. | Handles RP2xxx vendor reset requests. |

## Endpoint halt

USB 2.0 §9.4.5 gives every bulk and interrupt endpoint a Halt feature. The host sets and clears it
with SET_FEATURE and CLEAR_FEATURE(ENDPOINT_HALT) (§9.4.9, §9.4.1) and reads it with GET_STATUS. A
halted endpoint answers its tokens with STALL. A class may halt its own endpoint (a functional
stall, §8.4.5), and the host clears it.

**The halt is invisible to class state.** A halt neither cancels nor completes anything a class has
armed. An IN packet submitted before or during the halt stays armed and goes out after the clear, as
DATA0. An outstanding OUT listen stays outstanding and receives the first packet after the clear. A
completion that happened before the halt is still reported, possibly by a poll after the halt. No
data moves while the endpoint is halted. The existing classes (CDC, HID, Echo) know nothing of halt,
and a host that clears the halt on a CDC bulk endpoint must not leave CDC waiting for a completion
that was dropped.

Out of scope: a halt that must survive the host's CLEAR_FEATURE (mass-storage Bulk-Only Transport
keeps its pipes halted until Reset Recovery). Core clears on every host request and tells no class.
That needs a class hook on the host's clear, added with its first user.

**Interface.**

- The optional vtable entry `ep_set_stall(ep, bool) error{ NotSupported, Timeout, Unavailable }!void` lets
  a port report an unsupported chip revision, a wake timeout, or a controller unavailable for stall operations. An absent entry yields
  `error.NotSupported`.
- `DeviceInterface` gains `halted`, a bit set with one bit per endpoint number and direction. Core
  owns it, and the port clears it where the port drops the configuration on its own (Nordic detach).
- `DeviceInterface` also gains `opened`, the same shape, set by the `DeviceInterface.ep_open` wrapper
  and cleared by core with `halted`, and by the port where it clears `halted`. It lets `ep_halt` and the endpoint requests tell an open data
  endpoint from one that is not.
- Classes call `DeviceInterface.ep_halt(ep) error{ NotSupported, NotOpen, Timeout, Unavailable }!void`. For an
  open data endpoint after configuration init, it calls `ep_set_stall(ep, true)` if the endpoint
  is not already halted and sets the bit after success. Calls during init, for EP0, or for endpoints
  that are not open return `error.NotOpen`. A port error leaves the bit clear and reaches the caller.
  Only the host clears the halt.
- Core uses `set_halt(ep, bool)` for host set and clear. A port error leaves the bit unchanged and
  produces a request error.

`ep_set_stall(ep, true)` makes the port answer the endpoint's tokens with STALL and keep any armed
buffer armed. `ep_set_stall(ep, false)` stops the STALL and puts the endpoint's data toggle at DATA0,
whether or not it was stalled. §9.4.5: "regardless of whether an endpoint has the Halt feature set, a
ClearFeature(ENDPOINT_HALT) request always results in the data toggle being reinitialized to DATA0".
Both are idempotent and are called only for a data endpoint open in the active configuration, after
`Configuration.init` has opened all of them.

### Halt phases

| Phase | Hardware doing | Entered by | Left by | Owner |
| --- | --- | --- | --- | --- |
| `active` | normal transfers | `ep_open`, successful CLEAR_FEATURE(ENDPOINT_HALT) | successful SET_FEATURE(ENDPOINT_HALT) or `ep_halt` | foreground |
| `halted, nothing armed` | STALL on IN tokens; on OUT, see the rp2xxx row of Halt in the ports | halt with no buffer armed | successful CLEAR_FEATURE (a port refusal is a request error and keeps the halt), `ep_close_all`, bus reset, Nordic detach | foreground |
| `halted, armed` | STALL on every token; the armed buffer is held | halt with a buffer armed, or `ep_writev`/`ep_listen` while halted | as above | foreground |

### Halt ownership

| State | Written by | Read by | Handoff |
| --- | --- | --- | --- |
| `DeviceInterface.halted` | core (host requests, `ep_open`, `process_set_config`, `on_bus_reset`), classes (`ep_halt`), the Nordic port at detach | core for GET_STATUS, Nordic close, rp2xxx completion handling | Core updates the bit after the port call succeeds. Every writer runs from the port's foreground poll or from class code serialized with it. |
| `DeviceInterface.opened` | the `DeviceInterface.ep_open` wrapper, which skips endpoint 0 by number (ports open EP0 through the same wrapper, e.g. `port/raspberrypi/rp2xxx/src/hal/usb.zig:Polled.init`) | `ep_halt`, core's endpoint requests | Cleared in `process_set_config` before `Configuration.init` (bus reset reaches it through `process_set_config(0)`), and by the Nordic port at detach alongside `halted`. |
| Port stall state (rp2xxx buffer-control STALL, Nordic EPSTALL) | port, from `ep_set_stall`, `ep_open`, `ep_close_all` and reset | hardware | `ep_open` and `ep_close_all` leave the endpoint not stalled. |
| `DeviceInterface.configuring` (new) | core, set around `Configuration.init` in `process_set_config` | `ep_halt` | `ep_halt` returns `error.NotOpen` during init, including the IN-open callback. |
| Armed buffer while halted | port hardware | class, via the completion after the clear | Unchanged by halt; see the Ownership table above. |

### Halt events × phases

| Event | `active` | `halted, nothing armed` | `halted, armed` |
| --- | --- | --- | --- |
| SET_FEATURE(ENDPOINT_HALT) for an open data endpoint | `ep_set_stall(true)`, then set the bit and ACK on success. Otherwise request error | idempotent, ACK | idempotent, ACK |
| CLEAR_FEATURE(ENDPOINT_HALT) for an open data endpoint | `ep_set_stall(false)` resets the toggle to DATA0. Clear the bit and ACK on success. Otherwise request error | as `active` | as `active`; the armed packet is the next one, at DATA0 |
| GET_STATUS(endpoint) | two bytes, bit 0 clear | bit 0 set | bit 0 set |
| Completion latched before the halt | reported by the next poll that services the endpoint. During Nordic suspend this is the first poll after host activity, as with any late listen | same. The class may arm again, and that buffer is held. In the H8 fallback read-modify-write race listed under Open questions, the completion can stay pending until the clear | n/a |
| rp2xxx completion on an endpoint whose bit is set (H8 fallback below) | n/a | write STALL again before reporting | same |
| SET_CONFIGURATION, deconfiguration, bus reset | `ep_close_all` leaves the port not stalled and core clears every bit (§9.4.5: the Halt feature "is reset to zero after either a SetConfiguration() or SetInterface() request"; a bus reset returns the device to the Default state, §9.1.1.3) | same | same; the buffer is withdrawn as in any reconfiguration |
| Nordic detach (VBUS loss, `teardown`) | the port clears `halted` and `opened` | same | same |

SET_INTERFACE is not handled by core today (it reaches no standard handler), so its halt reset has no
cell here; whoever adds alternate settings adds it.

Endpoint-recipient requests by endpoint:

| Request | EP0 | Open data endpoint with halt unsupported (absent entry or RP2040 B0/B1) | Data endpoint in Address state or not in the active configuration |
| --- | --- | --- | --- |
| GET_STATUS | two bytes, zero | two bytes, zero | request error (§9.4.5, Address state; §9.4: a request to an endpoint that does not exist is a Request Error) |
| SET_FEATURE(ENDPOINT_HALT) | request error (§9.4.5: halt "is neither required nor recommended" for the Default Control Pipe) | request error | request error |
| CLEAR_FEATURE(ENDPOINT_HALT) | ACK, no effect | request error | request error |
| any other selector, wValue other than a selector, or wLength out of range | request error | request error | request error |

The feature selector is the whole of wValue (§9.4.1, §9.4.9). This replaces today's decode from
wValue's high byte (issue #70). ENDPOINT_HALT sent to the device recipient is a request error.

### Halt entry points × phases

| Call | `active` | `halted, nothing armed` | `halted, armed` |
| --- | --- | --- | --- |
| `ep_halt(ep)` from a class for an open data endpoint on a supporting port | set halt after the port succeeds. On Nordic wake timeout return `error.Timeout`. A pending Nordic reset or DMA quarantine returns `error.Unavailable`. Both leave the bit clear | return success | return success |
| `ep_halt(ep)` from `Runtime.init` or the IN-open callback | `error.NotOpen` through `configuring`. IN endpoints open after init, and `ep_open` clears the halt. | same | same |
| `ep_halt(ep)` for EP0 or an endpoint not in `opened` | `error.NotOpen`. Classes may halt only their own endpoints. `DeviceInterface` has no caller identity to check ownership. | same | same |
| `ep_halt(ep)` for an open data endpoint after init with halt unsupported (absent entry or RP2040 B0/B1) | `error.NotSupported` | n/a | n/a |
| `ep_writev` (IN) | run | accept the whole packet and hold it armed (the Packet lifetime invariant holds) | not allowed, as for any IN endpoint that is not idle (rp2xxx overwrites the armed packet then asserts, #65) |
| `ep_listen` (OUT) | run | arm and hold. On Nordic, a packet acknowledged before the halt is reported by the next poll that services the endpoint, as described above | not allowed, as today |
| `ep_readv` | after a reported OUT packet only, as today | same | same |
| `ep_close_all` / `ep_open` | run | run; leaves the endpoint not stalled | run; withdraws the buffer, leaves the endpoint not stalled |

### Halt in the ports

| Port | `ep_set_stall(ep, true)` | `ep_set_stall(ep, false)` |
| --- | --- | --- |
| rp2xxx (`Polled`) | On RP2040 B0/B1 return `error.NotSupported` before touching buffer control (erratum RP2040-E2 rules out EP_ABORT). On RP2040 B2 and RP2350, if AVAILABLE is set, take ownership with the EP_ABORT handshake first: at a transaction's STATUS phase the controller rewrites the buffer-control half, "Everything else is written to zero" (RP2040 datasheet §4.1.2.8.2; RP2350 §12.7.3.8.2), which would erase a STALL written during the transaction. Then write the register back with STALL set and every other bit kept, so an armed buffer stays AVAILABLE and a completed one keeps its BUFF_STATUS bit for the next poll, and release EP_ABORT after that write. If H8 shows EP_ABORT_DONE does not come on a suspended bus, then while the bus is idle (a port flag that suspend support, #44, adds) the stall is written without the handshake instead: no transaction can be in progress on an idle bus, so nothing can erase the write (the premise of the Halt timing budget row). That flag can outlast the idle bus (until the next resume event, SETUP, reset or dispatched completion); a transaction that erases the STALL completes on that endpoint, and the "write STALL again before reporting" row covers it. IN checks STALL before AVAILABLE ("If STALL is set in the buffer control register ... then send a STALL response", §4.1.2.8.2), so a held IN buffer is not sent. OUT checks STALL inside the AVAILABLE branch ("Is the AVAILABLE bit set and the FULL bit unset. If so go to the data phase, unless the STALL bit is set", §4.1.2.8.3), so a held OUT buffer is not filled. An OUT endpoint halted with nothing armed is not covered by that text and may answer NAK; TinyUSB's `dcd_edpt_stall` writes STALL alone and relies on it (unverified here: hardware test H3). EP_STALL_ARM gates EP0 only (§4.1.2.8.1) and is not written. | On RP2040 B0/B1 return `error.NotSupported` before touching buffer control. On RP2040 B2 and RP2350, if the endpoint is not stalled and AVAILABLE is set, take ownership as for a stall. If a buffer is armed, set its PID to DATA0; if not, set PID to DATA1 so that the flip in the next `ep_writev`/`ep_listen` arms DATA0. LENGTH and FULL are kept, so a completed OUT packet not yet read stays readable. That write leaves STALL as read; after the `config.sync_noops` gap that `ep_writev` uses, a second write clears STALL, and EP_ABORT, if taken, is released after it. The controller reads the register at every token, stalled or not, and the datasheet's warning under §4.1.2.7.4 (RP2350 §12.7.3.7.4) is that "the available and stall bits should be set after the other data", so the PID change must be visible before the endpoint stops stalling. |
| nrf5x (`USBD`) | If EasyDMA is quarantined (`dma.faulted`) or USBRESET is pending, return `error.Unavailable`. If `low_power`, first call `leave_low_power` as a class write does. Return `error.Timeout` on wake timeout, or `error.Unavailable` if USBRESET is pending after wake. These errors leave EPSTALL untouched. Host activity can wake the peripheral and reach an armed endpoint before `poll`, so the halt must succeed during the call. On success write EPSTALL with IO, STALL and the endpoint number (nRF52840 PS, USBD, "Bulk and interrupt transactions": "It is also possible to stall or resume communication on an endpoint through the EPSTALL register"; register layout from the MDK header). After a successful wake and the write, return to low power if `!bus_active()` (no resume, reset or SETUP observed). Stall needs only a register write, so it can leave the peripheral awake for activity already signaled by the host. `ep_writev` defers `enter_low_power` whenever it woke the peripheral, after its EasyDMA path, and relies on that helper's resume check. The HAL's armed state (`out_flow`, the IN busy state) is left alone. | Called only from the host's CLEAR_FEATURE, which arrives as a SETUP that has already ended `low_power` (`USBD.poll`), so `low_power` is false here (asserted). If EasyDMA is quarantined or USBRESET is pending, return `error.Unavailable` without writing DTOGGLE or EPSTALL. For an OUT endpoint that is stalled (HALTED.EPOUT[n]), with no packet waiting in `out_flow` and its EPDATASTATUS bit clear, write SIZE.EPOUT[n] first, while it still stalls and no packet can arrive; nrfx releases the buffer at the same point (`nrfx_usbd_ep_stall_clear`, `nrfx_usbd.c` 2253-2260, which drops a waiting packet where this design keeps it reported through `out_flow`). Then write DTOGGLE to DATA0 the way `ep_open` does (same section: "Controlling the data toggle ... is done through register DTOGGLE", naming ClearFeature as a use), and only then write EPSTALL with STALL clear, so that a held IN packet cannot go out with the old toggle; that DTOGGLE takes effect on a stalled endpoint is checked by H4. |
| WCH, STM32F103 | No `ep_set_stall`. | — |

What the PS text available here does not settle, and the hardware test must: that an IN packet
already loaded by EasyDMA before EPSTALL is sent after the unstall, that `load_in` works on a
stalled IN endpoint, and that an OUT packet acknowledged before the halt can be read by EasyDMA
(`easydma_out`) while the endpoint is stalled (all H4). nrfx is no prior art for the last: it drops
that packet. The PS PDF was not available to this design; the quotes above come from
Nordic's HTML edition of the USBD chapter, and register fields from `mdk/nrf52840_bitfields.h`.

### Halt timing budget

| Quantity | Value | Source | Used in |
| --- | --- | --- | --- |
| rp2xxx EP_ABORT_DONE wait (RP2040 B2 and RP2350) | one full-speed frame, then panic | existing bound, `port/raspberrypi/rp2xxx/src/hal/usb.zig:Polled.BufferWithdrawal` | `ep_set_stall` on an armed endpoint, inside SETUP handling or from a class; same panic as `withdraw_buffer`, since ownership was not established. On a suspended bus no transaction is in progress, so DONE is expected at once; that is an assumption (H8) |
| Nordic stall during suspend | bounded by `WAKE_WAIT_TURNS` reads of EVENTCAUSE plus the wake and register writes. On timeout return `error.Timeout` to the class | `USBD.leave_low_power` | `ep_set_stall` |

### Halt spec rules

| Clause | Rule | Host test |
| --- | --- | --- |
| USB 2.0 §9.4.9, §9.4.1 | Set/clear ENDPOINT_HALT on an open data endpoint updates the bit after the port succeeds. | `endpoint halt requests change only the addressed endpoint and always clear its toggle` |
| USB 2.0 §9.4.5 | A successful CLEAR_FEATURE(ENDPOINT_HALT) resets the toggle even when the endpoint was not halted. | `endpoint halt requests change only the addressed endpoint and always clear its toggle`, `clearing a Nordic OUT halt resets DATA0 and releases only an empty stalled slot` |
| USB 2.0 §9.4.5 | GET_STATUS(endpoint) returns two bytes, bit 0 = halted. | `endpoint halt requests change only the addressed endpoint and always clear its toggle` |
| USB 2.0 §9.4, §9.4.5 | Endpoint requests to an endpoint not in the active configuration, or in Address state, are a request error. | `endpoint requests reject unopened addresses and validate EP0 and legacy port requests` |
| USB 2.0 §9.4.5, §9.1.1.3 | SET_CONFIGURATION and bus reset clear every halt. | `configuration selection and bus reset retire endpoint halts` |
| USB 2.0 §9.4.1, §9.4.9 | The selector is wValue; ENDPOINT_HALT to the device is a request error. | `device feature requests use all of wValue and report the remote wakeup enable bit` |
| — (contract) | A completion latched before the halt is reported; an armed buffer survives the clear. | Hardware H2/H4 cover packet lifetime. `a class halt calls only ep_set_stall and leaves CDC awaiting completion` checks the class-facing part in core. |
| — (contract) | A failed port set or clear is a request error and preserves the bit. | `endpoint halt requests report a port failure as a request error` |
| — (port) | RP2040 B0/B1 reject data-endpoint set and clear with `error.NotSupported`. | Core tests the error path. The RP2xxx host harness has no SYSINFO register mock. |
| — (port) | Nordic wake timeout fails a class halt with the bit clear and no EPSTALL write. | `Nordic halt wake timeout leaves the Halt bit clear and does not write EPSTALL` |
| — (port) | RP2040 B2 and RP2350 stall and clear keep LENGTH/FULL/AVAILABLE and set the documented PID. | Hardware H1–H3 |
| — (port) | Nordic DMA quarantine and pending USBRESET reject set and clear, including a reset detected after wake. | `Nordic reset, close and detach retire endpoint halts` |
| — (port) | Nordic clears a held IN endpoint's halt after setting DATA0. | `clearing a Nordic IN halt resets DATA0 before clearing EPSTALL` |

### Halt consumer trace

| Consumer | Uses | Notes |
| --- | --- | --- |
| `core/src/core/usb/drivers/CDC.zig:Runtime` | nothing new | A host clear on its bulk endpoints leaves CDC's readiness correct: nothing is dropped. |
| `core/src/core/usb/drivers/HID.zig:Runtime` | nothing new | Same. |
| `core/src/core/usb/drivers/EchoExample.zig:Runtime` | nothing new | Same. |
| Host test (bench) | SET_FEATURE, GET_STATUS, CLEAR_FEATURE on a CDC bulk endpoint, then loopback | Checks that the first packet after the clear arrives (#43's toggle risk). |

### Halt hardware tests

| Id | Board | Check |
| --- | --- | --- |
| H1 | Pico 2 W, XIAO nRF52840 | Host SET_FEATURE(ENDPOINT_HALT) on CDC bulk IN and OUT, GET_STATUS reads 1, transfers STALL. |
| H2 | same | CLEAR_FEATURE, GET_STATUS reads 0, CDC loopback passes, the first packet after the clear arrives. |
| H3 | Pico 2 W | OUT halted with no listen outstanding answers STALL, not NAK. If it answers NAK, that is recorded under Open questions as a deviation (the host sees NAK until the class listens); no workaround is designed. |
| H4 | XIAO nRF52840 | An IN packet queued before and one queued during a halt both arrive after the clear, with the right toggle; an OUT packet acknowledged before the halt and read during it arrives intact, and the next packet after the clear arrives. Any failure returns the nrf5x stall and clear cells to design (the likely change is nrfx's: drop the held packet at the clear and tell the class). |
| H8 | Pico 2 W | A class halts an armed IN endpoint while the bus is suspended: EP_ABORT_DONE comes, no panic. If not, the handshake-free write in the rp2xxx stall cell applies. |

## Prior art

- Upstream issue #1144 for halt.
- TinyUSB's `dcd_rp2040.c` `dcd_edpt_stall` replaces the whole buffer-control register with STALL, cancelling the armed
  transfer. TinyUSB's device core then marks the endpoint idle. This design keeps the buffer instead,
  because this tree's classes do not re-arm after a halt.
- nrfx's `nrfx_usbd_ep_stall`, `nrfx_usbd_ep_stall_clear`, and `nrfx_usbd_ep_dtoggle_clear`
  (v3.9.0, `drivers/src/nrfx_usbd.c`) for the Nordic register sequences.
- Nordic's `port/nordic/nrf5x/src/hal/usbd.zig:USBD` follows the RP2xxx interface and cites nrf-rs/nrf-usbd.
  `port/raspberrypi/rp2xxx/src/hal/usb.zig:Polled.poll` follows TinyUSB and pico-examples in servicing reset last.

## Shared patterns

- [Interrupt handling and ISR routing](interrupts.md) covers vector hookup and Nordic's IRQ-to-foreground handoff.

## Evidence

Run `zig build test` in each package. `core/build.zig:build` reaches USB via `core/src/microzig.zig`.
`port/nordic/nrf5x/build.zig:build` imports USB tests via `port/nordic/nrf5x/src/hal.zig`, and
`port/wch/ch32v/build.zig:build` runs `usb-hal-tests`.

- **`core/`** exercises configuration with `core/src/core/usb.zig` tests "completions and interface requests without a configuration reach no driver", "reconfiguration and deconfiguration close the old endpoints before reuse", "SET_CONFIGURATION with the current value opens the endpoints again" and "GET_CONFIGURATION returns the selected configuration, or 0 without one".
- **`core/`** exercises EP0 replacement in `core/src/core/usb.zig` with "a new setup request drops the rest of an abandoned control read", "a new setup request drops a control write whose data had not all arrived" and "a bus reset drops a control write whose data had not all arrived".
- **`core/`** checks software SET_ADDRESS timing in the first case of "a new setup request drops an address whose status packet the host never took" in `core/src/core/usb.zig`, and abandonment in the second.
- **`core/`** checks EP0 IN and STALL in `core/src/core/usb.zig` with "a control read that ends on a packet boundary short of wLength ends with a zero-length packet" and "software EP0 stalls unhandled requests and clears the decision at SETUP".
- **`core/`** checks halt and device features in `core/src/core/usb.zig` with "endpoint halt requests change only the addressed endpoint and always clear its toggle", "endpoint requests reject unopened addresses and validate EP0 and legacy port requests", "configuration selection and bus reset retire endpoint halts", "device feature requests use all of wValue and report the remote wakeup enable bit", "class halt rejects unopened endpoints, EP0 and calls during configuration init" and "a class halt calls only ep_set_stall and leaves CDC awaiting completion".
- **`core/`** checks direct reopen in `core/src/core/usb.zig` with "reopening a halted endpoint in the active configuration clears its halt" and checks port failures with "endpoint halt requests report a port failure as a request error".
- **`core/`** checks EP0 writes in `core/src/core/usb.zig` with "software EP0 delivers a control write before acknowledging it", "the data stage of a control write is collected over its packets", "SET_REPORT without class_data drains multiple packets before status", "SET_REPORT without class_data keeps immediate status on a legacy HAL" and "SET_LINE_CODING reaches the CDC driver on a device that hands over the data stage".
- **`core/`** checks the abort handshake path in `core/src/core/usb/endpoint_buffer.zig` with "abort timeout retains buffer ownership and pending completion" and "successful abort withdraws the buffer before dropping its completion".
- **`core/`** checks Echo's initial listen and rearm after OUT notification in `core/src/core/usb.zig` with "the controller configures the echo example driver".
- **`core/`** checks CDC readiness in `core/src/core/usb/drivers/CDC.zig` with "full CDC packets terminate with a ZLP before making the endpoint writable", "CDC queued data continues a transfer and terminates its final full packet" and "CDC short final packets end transfers without an extra ZLP".
- **`port/nordic/nrf5x/`** checks IRQ startup and wakeup in `port/nordic/nrf5x/src/usb_tests.zig` with "init masks and clears a bootloader's USBD interrupt before late OUT listen" and "late OUT listen pends the previously enabled USBD interrupt".
- **`port/nordic/nrf5x/`** checks foreground dispatch, suspend and reselection in `port/nordic/nrf5x/src/usb_tests.zig` with "ISR poll leaves control OUT DMA for foreground", "CDC reads notified OUT across suspend without a successful wake", "CDC IN survives wake timeout and completes after host resume", "reselecting the active USB configuration invalidates the previous CDC lifetime" and "failed wake prevents OUT and IN DMA without quarantine".
- **`port/nordic/nrf5x/`** checks halt register writes and lifecycle in `port/nordic/nrf5x/src/usb_tests.zig` with "clearing a Nordic OUT halt resets DATA0 and releases only an empty stalled slot", "clearing a Nordic IN halt resets DATA0 before clearing EPSTALL", "Nordic halt wakes the peripheral before writing EPSTALL", "Nordic halt wake timeout leaves the Halt bit clear and does not write EPSTALL" and "Nordic reset, close and detach retire endpoint halts".
- **`port/nordic/nrf5x/`** checks early arrival, listen and retirement in `port/nordic/nrf5x/src/hal/usbd/out_flow.zig` with "a packet is reported only to a driver that listens", "a packet is reported once, and the next one waits for the next listen" and "an endpoint that is opened again starts with nothing".
- **`port/nordic/nrf5x/`** checks DMA release and timeout in `port/nordic/nrf5x/src/hal/usbd/dma.zig` with "completed EasyDMA releases the workaround and allows the next transfer" and "EasyDMA timeout retains workaround and quarantines subsequent transfers".
- **`port/nordic/nrf5x/`** checks EP0 in `port/nordic/nrf5x/src/hal/usbd/ep0.zig` with "a control read gets its status stage when the host has taken the last packet", "a control write whose data the controller refuses is stalled" and "SET_ADDRESS gets neither a status stage nor a stall".
- **`port/nordic/nrf5x/`** checks EP0 OUT listen and termination in `port/nordic/nrf5x/src/hal/usbd/ep0.zig` with "a control write the controller listens for runs packet by packet" and "a control write's data stage runs until wLength or a short packet".
- **`port/wch/ch32v/`** checks wrong-toggle OUT in `port/wch/ch32v/src/usb_tests.zig` with "USBFS EP0 discards retransmitted OUT without advancing state" and "USBHS EP0 discards retransmitted OUT without advancing state".
- Dedicated tests are absent for stationary handles, descriptor and handler rules, synchronous callbacks,
  packet and read capacities, clock and IRQ setup, Nordic attach/detach, physical toggles, RP2xxx and
  WCH USBD register paths, STM32F103 startup and PMA mapping, reset ordering and callbacks, HID I/O,
  Echo's first IN readiness and ROM reset effects.

## Open questions

- `core/src/core/usb.zig:DeviceController.on_buffer` treats address zero as no pending update. ([#70](https://github.com/valthon/microzig/issues/70))
- `core/src/core/usb/descriptor.zig:BOS` has an empty capability type and `core/src/core/usb.zig:DeviceController.get_descriptor` has no BOS dispatch.
- `core/src/core/usb/configuration.zig:Configuration.deinit` has no class cleanup hook.
- `core/src/core/usb/drivers/CDC.zig:Runtime.class_request` accepts zero-length SET_LINE_CODING, so core ACKs it without calling `class_data`. ([#70](https://github.com/valthon/microzig/issues/70))
- `core/src/core/usb/drivers/HID.zig:Runtime.send_report` reports success on a short write, and `core/src/core/usb/drivers/HID.zig:Runtime.class_request` accepts SetIdle, SetProtocol and SetReport without implementing their effects. ([#70](https://github.com/valthon/microzig/issues/70))
- `core/src/core/usb/drivers/HID.zig:Runtime.receive_report` logs the byte count but returns a partially undefined report after a short read, with no length or error for the caller. ([#70](https://github.com/valthon/microzig/issues/70))
- `core/src/core/usb/drivers/EchoExample.zig:Runtime.on_tx_ready` is never called on IN open by Nordic, RP2xxx, WCH USBD, USBFS or USBHS, so Echo starts busy and cannot send its first packet. ([#68](https://github.com/valthon/microzig/issues/68))
- `port/wch/ch32v/src/hals/usbfs.zig:Polled.poll` uses the saved transfer flag after reset and can dispatch a SETUP from before the reset. ([#72](https://github.com/valthon/microzig/issues/72))
- `port/wch/ch32v/src/hals/usbhs.zig:Polled.poll` can use saved SETUP_ACT or a SETUP token via TRANSFER after reset, so a stale SET_CONFIGURATION can recreate the runtime. ([#72](https://github.com/valthon/microzig/issues/72))
- `port/wch/ch32v/src/hals/usbfs.zig:Polled.handle_in` rearms OUT at DATA0 after each EP0 IN completion, overwriting the OUT toggle set for the control read's status stage. ([#72](https://github.com/valthon/microzig/issues/72))
- `port/raspberrypi/rp2xxx/src/hal/usb.zig:ResetDriver` calls USB boot reset in the flash-reset branch and logs the BOOTSEL LED and interface masks without passing them to the reset helper. ([#66](https://github.com/valthon/microzig/issues/66))
- On RP2040 B2 and RP2350 if hardware test H8 fails, `port/raspberrypi/rp2xxx/src/hal/usb.zig:Polled.ep_set_stall` sets STALL by a read-modify-write without EP_ABORT. A STATUS-phase rewrite landing between the read and the write would be undone, leaving the already-sent buffer AVAILABLE and STALL set until the clear.
- `port/raspberrypi/rp2xxx/src/hal/usb.zig:Polled.BufferWithdrawal.begin_abort` skips the abort handshake on RP2040 B0/B1 even with AVAILABLE set, so `core/src/core/usb/endpoint_buffer.zig:withdraw` rewrites buffer control and clears completion without hardware confirmation of ownership.
- `port/raspberrypi/rp2xxx/src/hal/usb.zig:Polled.ep_writev`, `port/wch/ch32v/src/hals/usbfs.zig:Polled.ep_writev` and `port/wch/ch32v/src/hals/usbhs.zig:Polled.ep_writev` cap writes by buffer capacity, which can exceed the advertised packet size. ([#65](https://github.com/valthon/microzig/issues/65))
- `port/raspberrypi/rp2xxx/src/hal/usb.zig:Polled.ep_writev` copies before checking AVAILABLE, so writing while busy can overwrite an armed packet. ([#65](https://github.com/valthon/microzig/issues/65))
- `port/raspberrypi/rp2xxx/src/hal/usb.zig:Polled.poll` orders co-latched events using a reset interval cited to TinyUSB without a datasheet section. Its reset branch leaves EP0 buffer retirement to the next SETUP.
- `port/nordic/nrf5x/src/hal/usbd.zig:USBD.poll` leaves the core runtime intact on VBUS loss and marks the next connection live at pull-up enable, before the next bus reset. ([#71](https://github.com/valthon/microzig/issues/71))
- `examples/raspberrypi/rp2xxx/src/usb_cdc.zig:usb_cdc_write` and `examples/wch/ch32v/src/usb_cdc.zig:usb_cdc_write` retain a class pointer across polls that can retire it or replace its runtime mid-write. ([#74](https://github.com/valthon/microzig/issues/74))
- `examples/raspberrypi/rp2xxx/src/pio_selftest/selftest.zig:emit` retains its CDC borrow across polls in both its write and flush loops, so reset or reselection can invalidate it. ([#74](https://github.com/valthon/microzig/issues/74))
- `examples/nordic/nrf5x/src/usb_hid.zig:main` checks only `drivers()`, so it can use the retained HID runtime during detach or after reattachment before a new configuration. ([#74](https://github.com/valthon/microzig/issues/74))
- `port/nordic/nrf5x/src/hal/usbd.zig:USBD.ep0_trigger` can issue an old transfer's task if a new SETUP arrives after the guard. ([#71](https://github.com/valthon/microzig/issues/71))
- `port/nordic/nrf5x/src/hal/usbd.zig:USBD.load_in` can arm old EP0 IN data if SETUP arrives between its check and `TASKS_STARTEPIN`. ([#71](https://github.com/valthon/microzig/issues/71))
- `examples/stmicro/stm32/src/stm32f1xx/usb_cdc.zig:USB_conf` relies on the default reset handler, which leaves `config`, `device_addr`, `remain_pkg`, `CDC_coding` and a pending `CDC_send` unchanged, so the app can use stale control state or wait for a discarded TX completion. ([#73](https://github.com/valthon/microzig/issues/73))
- `examples/stmicro/stm32/src/stm32f1xx/usb_hid.zig:USB_conf` relies on the default reset handler, which leaves `config`, `device_addr` and `to_report` unchanged, so the app can send before reconfiguration, wait for a discarded report completion or apply a stale address. ([#73](https://github.com/valthon/microzig/issues/73))
- `examples/stmicro/stm32/src/stm32f1xx/usb_cdc.zig:ep0_setup` leaves `device_addr`, `remain_pkg` and `CDC_coding` pending, so later callbacks can apply an abandoned address or use stale control data. ([#73](https://github.com/valthon/microzig/issues/73))
- `examples/stmicro/stm32/src/stm32f1xx/usb_hid.zig:ep0_setup` leaves `device_addr` pending, and `examples/stmicro/stm32/src/stm32f1xx/usb_hid.zig:ep0_tx` can reapply it because it never clears it. ([#73](https://github.com/valthon/microzig/issues/73))
- `core/src/core/usb.zig:DeviceController.process_device_setup` accepts a nonzero SET_CONFIGURATION value the descriptor does not define, where USB 2.0 §9.4.7 calls for a request error. ([#70](https://github.com/valthon/microzig/issues/70))
- `port/stmicro/stm32/src/hals/STM32F103/usb_internals/usb_ll.zig:usb_handler` dispatches the previous transfer's TX completion after the new SETUP callback when both are pending in one snapshot, so it can apply a newly pending address before its status packet completes even if the application clears old state at SETUP. ([#73](https://github.com/valthon/microzig/issues/73))
- `port/stmicro/stm32/src/hals/STM32F103/usb_internals/usb_ll.zig:usb_check` accepts mismatched endpoint and controller slot numbers, so endpoint I/O can use the wrong PMA entry. ([#73](https://github.com/valthon/microzig/issues/73))
- `port/stmicro/stm32/src/hals/STM32F103/usb_internals/usb_ll.zig:inner_init` waits for RESET without a deadline.
- `port/stmicro/stm32/src/hals/STM32F103/usb_internals/usb_ll.zig:get_epc_from_ep` reads the nonexistent `Endpoint.EpControl` field. ([#59](https://github.com/valthon/microzig/issues/59))
- `port/stmicro/stm32/src/hals/STM32F103/usb_internals/usb_ll.zig:usb_runtime_init` instantiates `usb_check` at runtime, where calls to `comptime_or_runtime_err` leave error unions unhandled. ([#73](https://github.com/valthon/microzig/issues/73))
