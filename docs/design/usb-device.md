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

USBFS acknowledges reset and discards co-latched packet events before the controller callback.
A reset latched during the callback takes priority in the next snapshot.

USBHS acknowledges reset and discards co-latched packet events before the controller callback.
A reset latched during the callback takes priority in the next snapshot.

USBFS and USBHS leave EP0 OUT able to ACK a retried control-read status packet and discard the duplicate using the receive-toggle match flag.

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
| USB 2.0 §5.8.3 in `port/wch/ch32v/src/hals/usbhs.zig:Polled.device_capabilities` | Report 64 bytes for bulk endpoints in full-speed mode and 512 bytes when high speed is selected. |
| USB 2.0 §5.8.3 in `core/src/core/usb/drivers/CDC.zig:Runtime` | CDC uses a ZLP when a full bulk packet completes and no further data has been queued. |

### Consumer trace

| Port | Context | Controller-specific handoff |
| --- | --- | --- |
| `port/nordic/nrf5x/src/hal/usbd.zig:USBD.poll` | For IRQ wakeups, configure peripheral interrupt sources and explicitly enable the NVIC USBD line that init masks. Mask the line in the handler and signal foreground to poll before re-enabling it. | Foreground polling works without IRQs and is required for VBUS changes even with wakeups. OUT listen gates notification and can pend the IRQ for a waiting packet. |
| `port/raspberrypi/rp2xxx/src/hal/usb.zig:Polled.poll` | Follow the foreground polling interval above. | Withdraw both EP0 buffers at SETUP and service reset after packet events. A longer poll gap can let an earlier reset erase a later SETUP's state. |
| `port/wch/ch32v/src/hals/usbd.zig:Polled.handle_out` | Foreground via `poll(false, controller)`. | Stage EP0 OUT from PMA and set RX to NAK before handing the data to core. |
| `port/wch/ch32v/src/hals/usbfs.zig:Polled.ep_writev` | Keep the CPU IRQ disabled and call `poll(false, controller)`. | Arm status OUT at DATA1 when writing control IN and preserve it across each IN completion. |
| `port/wch/ch32v/src/hals/usbhs.zig:Polled.poll` | Keep the CPU IRQ disabled and call `poll(false, controller)`. | Copy the SETUP packet out of DMA before calling core. Acknowledge SETUP_ACT before the callback and keep any co-latched TRANSFER busy through reply publication. |
| `port/stmicro/stm32/src/hals/STM32F103/usb_internals/usb_ll.zig:usb_handler` | Install this handler on `USB_LP_CAN1_RX0` before USB init and serialize foreground calls with its callbacks. | With `port/stmicro/stm32/src/hals/STM32F103/usb.zig:usb_ll`, the app owns EP0 sequencing and address timing and must discard the old transfer's state at each SETUP. On reset, clear application configuration and pending control state and release transfer waiters. A custom `Config.reset_callback` must also restore address zero and reset endpoints or call `port/stmicro/stm32/src/hals/STM32F103/usb_internals/usb_ll.zig:default_reset_handler`. |

USBHS shares one EP0 DMA buffer between RX and TX. SETUP_ACT can latch without the TRANSFER busy
interlock. If a SETUP is pending after a nonempty reply copy, the HAL discards the suspect request and
leaves the reply unarmed. The host can retry the control transfer by sending a fresh SETUP. A new
SETUP can still latch between the final SETUP_ACT check and the separate TX arm write.

When polling SETUP_ACT, USBHS retires a co-latched EP0 transaction and leaves data endpoint
completions pending
for normal TRANSFER handling while their endpoint ownership persists. If the SETUP callback closes
or reopens the completed endpoint direction, USBHS retires that completion after the callback so
it cannot reach the new owner. USBFS dispatches SETUP from TRANSFER and holds that interlock through
reply publication.

Nordic's `port/nordic/nrf5x/src/hal/usbd/ep0.zig:Control` starts read status after the last IN completion.
Hardware handles SET_ADDRESS and its status (nRF52840 PS v1.1 §6.35.9, as cited there). RP2xxx and WCH filter status OUT via `core/src/core/usb/ControlRequest.zig:out_packet`.

| Class | OUT and IN readiness | Interface requests |
| --- | --- | --- |
| `core/src/core/usb/drivers/CDC.zig:Runtime` | Init listens and starts IN ready. A terminating ZLP holds IN busy until completion. | SET_LINE_CODING validates the delivered payload in `class_data`. |
| `core/src/core/usb/drivers/HID.zig:Runtime` | Init listens and starts IN ready, and each IN completion restores readiness. | Serves HID and report descriptors and accepts writes without a data hook. |
| `core/src/core/usb/drivers/EchoExample.zig:Runtime` | The OUT handler reads and rearms, and echoes only after IN readiness is signalled. | Accepts interface requests without a data hook. |
| `port/raspberrypi/rp2xxx/src/hal/usb.zig:ResetDriver` | Interface only. | Handles RP2xxx vendor reset requests. |

## Prior art

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
- **`core/`** checks EP0 writes in `core/src/core/usb.zig` with "software EP0 delivers a control write before acknowledging it", "the data stage of a control write is collected over its packets", "SET_REPORT without class_data drains multiple packets before status", "SET_REPORT without class_data keeps immediate status on a legacy HAL" and "SET_LINE_CODING reaches the CDC driver on a device that hands over the data stage".
- **`core/`** checks the abort handshake path in `core/src/core/usb/endpoint_buffer.zig` with "abort timeout retains buffer ownership and pending completion" and "successful abort withdraws the buffer before dropping its completion".
- **`core/`** checks Echo's initial listen and rearm after OUT notification in `core/src/core/usb.zig` with "the controller configures the echo example driver".
- **`core/`** checks CDC readiness in `core/src/core/usb/drivers/CDC.zig` with "full CDC packets terminate with a ZLP before making the endpoint writable", "CDC queued data continues a transfer and terminates its final full packet" and "CDC short final packets end transfers without an extra ZLP".
- **`port/nordic/nrf5x/`** checks IRQ startup and wakeup in `port/nordic/nrf5x/src/usb_tests.zig` with "init masks and clears a bootloader's USBD interrupt before late OUT listen" and "late OUT listen pends the previously enabled USBD interrupt".
- **`port/nordic/nrf5x/`** checks foreground dispatch, suspend and reselection in `port/nordic/nrf5x/src/usb_tests.zig` with "ISR poll leaves control OUT DMA for foreground", "CDC reads notified OUT across suspend without a successful wake", "CDC IN survives wake timeout and completes after host resume", "reselecting the active USB configuration invalidates the previous CDC lifetime" and "failed wake prevents OUT and IN DMA without quarantine".
- **`port/nordic/nrf5x/`** checks early arrival, listen and retirement in `port/nordic/nrf5x/src/hal/usbd/out_flow.zig` with "a packet is reported only to a driver that listens", "a packet is reported once, and the next one waits for the next listen" and "an endpoint that is opened again starts with nothing".
- **`port/nordic/nrf5x/`** checks DMA release and timeout in `port/nordic/nrf5x/src/hal/usbd/dma.zig` with "completed EasyDMA releases the workaround and allows the next transfer" and "EasyDMA timeout retains workaround and quarantines subsequent transfers".
- **`port/nordic/nrf5x/`** checks EP0 in `port/nordic/nrf5x/src/hal/usbd/ep0.zig` with "a control read gets its status stage when the host has taken the last packet", "a control write whose data the controller refuses is stalled" and "SET_ADDRESS gets neither a status stage nor a stall".
- **`port/nordic/nrf5x/`** checks EP0 OUT listen and termination in `port/nordic/nrf5x/src/hal/usbd/ep0.zig` with "a control write the controller listens for runs packet by packet" and "a control write's data stage runs until wLength or a short packet".
- **`port/wch/ch32v/`** checks wrong-toggle OUT in `port/wch/ch32v/src/usb_tests.zig` with "USBFS EP0 discards retransmitted OUT without advancing state" and "USBHS EP0 discards retransmitted OUT without advancing state".
- **`port/wch/ch32v/`** checks USBFS reset priority in `port/wch/ch32v/src/hals/usbfs.zig`.
- **`port/wch/ch32v/`** checks USBHS reset priority in `port/wch/ch32v/src/hals/usbhs.zig`.
- **`port/wch/ch32v/`** checks the USBFS EP0 status OUT toggle in `port/wch/ch32v/src/hals/usbfs.zig`.
- **`port/wch/ch32v/`** checks the EP0 receive toggle on retried status OUT in `port/wch/ch32v/src/hals/usbfs.zig` and `port/wch/ch32v/src/hals/usbhs.zig`.
- **`port/wch/ch32v/`** checks USBHS bulk packet size in `port/wch/ch32v/src/hals/usbhs.zig`.
- Dedicated tests are absent for stationary handles, descriptor and handler rules, synchronous callbacks,
  packet and read capacities, clock and IRQ setup, Nordic attach/detach, physical toggles, RP2xxx and
  WCH USBD register paths, STM32F103 startup and PMA mapping, hardware reset timing, HID I/O,
  Echo's first IN readiness and ROM reset effects.

## Open questions

- `core/src/core/usb.zig:DeviceController.on_buffer` treats address zero as no pending update. ([#70](https://github.com/valthon/microzig/issues/70))
- `core/src/core/usb.zig:DeviceController.process_device_setup` decodes SET_FEATURE from the high byte of `wValue` and can ACK it without applying a feature. ([#70](https://github.com/valthon/microzig/issues/70))
- `core/src/core/usb/descriptor.zig:BOS` has an empty capability type and `core/src/core/usb.zig:DeviceController.get_descriptor` has no BOS dispatch.
- `core/src/core/usb/configuration.zig:Configuration.deinit` has no class cleanup hook.
- `core/src/core/usb/drivers/CDC.zig:Runtime.class_request` accepts zero-length SET_LINE_CODING, so core ACKs it without calling `class_data`. ([#70](https://github.com/valthon/microzig/issues/70))
- `core/src/core/usb/drivers/HID.zig:Runtime.send_report` reports success on a short write, and `core/src/core/usb/drivers/HID.zig:Runtime.class_request` accepts SetIdle, SetProtocol and SetReport without implementing their effects. ([#70](https://github.com/valthon/microzig/issues/70))
- `core/src/core/usb/drivers/HID.zig:Runtime.receive_report` logs the byte count but returns a partially undefined report after a short read, with no length or error for the caller. ([#70](https://github.com/valthon/microzig/issues/70))
- `core/src/core/usb/drivers/EchoExample.zig:Runtime.on_tx_ready` is never called on IN open by Nordic, RP2xxx, WCH USBD, USBFS or USBHS, so Echo starts busy and cannot send its first packet. ([#68](https://github.com/valthon/microzig/issues/68))
- `port/raspberrypi/rp2xxx/src/hal/usb.zig:ResetDriver` calls USB boot reset in the flash-reset branch and logs the BOOTSEL LED and interface masks without passing them to the reset helper. ([#66](https://github.com/valthon/microzig/issues/66))
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
