# Network and lwIP

Covers: modules/network/, modules/lwip/, modules/foundation-libc/, drivers/build.zig, drivers/src/root.zig, drivers/src/wireless/cyw43439.zig, drivers/src/wireless/cyw43439/, port/raspberrypi/rp2xxx/build.zig, port/raspberrypi/rp2xxx/src/hal/drivers.zig, examples/raspberrypi/rp2xxx/build.zig, examples/raspberrypi/rp2xxx/src/net/, examples/espressif/esp/build.zig, examples/espressif/esp/src/lwip/, examples/espressif/esp/src/tcp_server.zig, examples/espressif/esp/src/softap.zig, examples/espressif/esp/src/softap_dhcp.zig, examples/espressif/esp/src/selftest_wifi_checks.zig, examples/espressif/esp/src/selftest_wifi_softap_echo.zig, examples/espressif/esp/src/selftest_coex_wifi_ble.zig, port/espressif/esp/src/hal/rtos.zig, port/espressif/esp/src/hal/radio.zig, port/espressif/esp/src/hal/radio/, port/espressif/esp/README.md

## Purpose

A link driver moves Ethernet frames. A netif registers that link with lwIP, which handles
Ethernet input, IP and transport protocols. Pico W uses the network module to turn a
`Link` into a netif and expose raw UDP and TCP to Zig. The ESP examples use the lwIP
package directly and supply their own netif and RTOS glue.

## Code map

- `modules/lwip/build.zig:build` compiles the pinned upstream C sources and translates the
  umbrella header with the same port include directory and configured macros. `modules/lwip/src/root.zig:c`
  exports the translated bindings.
- `modules/network/build.zig:add_network_module` (called from `build`) links foundation libc and sizes the internal lwIP heap
  and packet buffer (pbuf) pool at build time. MTU counts IP bytes. Size the pool buffer
  for the Ethernet header, driver headroom and any extra receive storage.
- `modules/network/src/include/lwipopts.h:NO_SYS` selects the bare-metal raw API and
  disables sockets and netconn. `modules/network/src/include/arch/cc.h:sys_now` aliases the
  clock to `lwip_sys_now`. Pico supplies the clock and RNG in
  `examples/raspberrypi/rp2xxx/src/net/lwip_exports.zig:lwip_sys_now` and
  `examples/raspberrypi/rp2xxx/src/net/lwip_exports.zig:lwip_rand`.
- `examples/espressif/esp/build.zig:build` selects the ESP headers.
  `examples/espressif/esp/src/lwip/include/lwipopts.h:NO_SYS` selects RTOS mode. The header
  enables netifapi, core locking and locked input. `examples/espressif/esp/src/lwip/exports.zig:sys_thread_new`
  starts the TCP/IP task.

## Invariants

### Bare metal

Keep the link context and the caller-owned `Interface` at stable addresses.
`modules/network/src/root.zig:Interface.init` initializes global lwIP state, registers
the embedded netif with `netif_input`, and makes it the default. It installs ARP and
IPv6 output, sets the MAC and creates an IPv6 link-local address. Choose fixed IPv4 or
let the interface supply its embedded DHCP state. The wrapper has no teardown API,
so reserve these objects for the registered lifetime and treat initialization as one-time.

Run raw API calls, RX, TX and timers in one foreground context. From a callback,
defer `Interface.poll` and `Interface.tick` until the current stack call returns.
Both service lwIP timeouts, so schedule `tick` if RX wakes are the only reason to
poll. The clock supplies wrapping milliseconds since boot. The protection hooks
do nothing, so keep bus transfers, allocation and lwIP calls in the foreground.

Raw UDP and TCP receive callbacks borrow one pbuf segment at a time. UDP marks the
last with `last_fragment`. Copy data you need after return. UDP and TCP copy outgoing
data, and TCP `on_sent` reports acknowledged bytes. Retry `tcp.Connection.send` only
if the bytes were never queued, since `tcp_output` can fail after `tcp_write` succeeds.
Defer a graceful close requested by `on_recv` until the stack call returns so the
wrapper can credit the received bytes. Keep callback contexts stationary and TCP
connection wrappers reserved until lwIP can no longer call them, even after `close`.
The UDP and TCP listener wrappers have no close API.

### ESP tasks

Set `examples/espressif/esp/src/lwip/exports.zig:gpa` before `tcpip_init` and keep its
backing allocator alive while the task, queue storage, mutexes or semaphores can use
it. The configured heap and pools use C allocation. The radio exports weak C allocation
symbols in `port/espressif/esp/src/hal/radio/osi.zig:export_symbols`. The route in
`port/espressif/esp/src/hal/radio/osi.zig:callback_allocator` uses the single-radio
allocator or the boot-lifetime shared heap attached by coexistence applications.
Keep the C allocator route and its backing storage valid for all live lwIP allocations,
including across Wi-Fi deinit and reinit. Vendor RX allocates a pbuf before taking the
TCP/IP core lock, so both allocator routes must be safe across their calling tasks.
Keep the netif and its context alive while registered or reachable by callbacks.

The TCP/IP task services lwIP timeouts using a wrapping millisecond clock. The
sys_arch mailbox and semaphore waits take milliseconds. Zero waits indefinitely,
and expiry returns `SYS_ARCH_TIMEOUT`. The port uses a separate task mutex for
lightweight protection (`examples/espressif/esp/src/lwip/exports.zig:core_mutex`).

`tcpip_input`, netifapi and netconn API-message calls such as `netconn_bind`,
`netconn_listen` and `netconn_write_partly` acquire the non-recursive core mutex
(`port/espressif/esp/src/hal/rtos.zig:Mutex`). Enter `tcpip_input` with the lock released.
Raw callbacks hold the lock, so defer netifapi and netconn API-message calls to an
application task that calls them with the lock released. For raw calls from application
tasks, take `LOCK_TCPIP_CORE` as in `examples/espressif/esp/src/softap.zig:start_dhcp`.

Vendor RX runs inline on the vendor task. Locked input can call `linkoutput` there
before RX returns, and TX can also run on the TCP/IP task or a caller holding the lock.
Keep `linkoutput` from waiting for vendor work that could be blocked on that lock.
Publish the registered netif before RX uses it. Keep the caller-owned `Wifi` stationary
and quiesce calls into it, including TX through `linkoutput`, before deinit.
Run lifecycle waits in the application task outside the lwIP lock.

## Design tables

### Frame handoff

The bare-metal link in `modules/network/link/link.zig:vtable` holds an erased context and a
by-value table for `recv` and `send`. The ESP examples register `tcpip_input` through
`netifapi_netif_add` and implement `linkoutput` themselves. Both input functions
select `ethernet_input` by netif flags. With neither Ethernet flag, they pass the
Ethernet header to the IP parser.

| Step | Bare-metal Link | ESP netif |
| --- | --- | --- |
| Ethernet dispatch | Set `NETIF_FLAG_ETHERNET` or `NETIF_FLAG_ETHARP` for `netif_input`. | Set either flag for `tcpip_input`. |
| Receive | Finish all writes, including DMA, and release the borrowed pool buffer before `recv` returns, including on error. | Copy the borrowed vendor frame into a pool pbuf before returning. |
| Frame range | Return `head` and `len` for the Ethernet bytes within the supplied slice. | Start the pbuf payload at the Ethernet header. |
| Empty or down | Return zero length if empty and set link state even then, since it defaults to up. | Drop RX until the netif is published and on allocation failure. |
| Drain | Zero length or `next_packet_available = false` ends the poll, and a frame with true or null triggers another receive. | `port/espressif/esp/src/hal/radio/wifi.zig:recv_cb_sta` and `port/espressif/esp/src/hal/radio/wifi.zig:recv_cb_ap` free the vendor buffer after the callback returns. |
| Link state | The receive result drives link up and down. | The application task reports link changes through netifapi. |
| Input | `Interface.poll` adjusts the pbuf and passes the frame to the stack. | Call the registered input function with the copy. |
| Ownership | The wrapper frees an empty pbuf or one rejected by input. Successful input transfers ownership to lwIP. | lwIP takes the pbuf on successful input, and the adapter frees it on copy or input error. |
| Transmit | `Interface.c_netif_linkoutput` exposes headroom in the original first pbuf before cloning a chain. | Flatten the whole chain into transmit scratch without freeing or modifying the input pbuf. |
| TX lifetime | `send` may fill the reserved prefix and borrows the slice until return. | Reuse scratch only once the driver releases its borrow. A new asynchronous adapter must copy into owned storage or retain a buffer until completion. |
| TX failure | `OutOfMemory`, `LinkDown` and `InternalError` become `ERR_MEM`, `ERR_IF` and `ERR_ARG`. | The examples map `send_packet` failure to `ERR_IF`. |

ESP registration and `netif_set_up` leave the link down. The application calls
`netif_set_link_up` through `netifapi_netif_common` after station association or AP
start. This releases a DHCP client waiting for link up. The coexistence example
releases DHCP and calls `netif_set_link_down` before tearing Wi-Fi down.

On bare metal, TX can run during a send, while input is processed or when timers
are serviced. If the first TX pbuf cannot expose the configured headroom,
`linkoutput` returns `ERR_ARG` before cloning or calling `send`, even if a clone would
fit in the pool buffer. The wrapper frees its temporary clone. Preserve the Ethernet
bytes and release the driver's borrow before returning from `send`.
For RX, keep `head` representable as a signed 16-bit header adjustment and `len`
within the remaining buffer.

## Prior art

- For a polled link that can use the stack's storage, start with
  `drivers/src/wireless/cyw43439.zig:link` and `examples/raspberrypi/rp2xxx/src/net/udp.zig:main`.
  `port/raspberrypi/rp2xxx/src/hal/drivers.zig:WiFi.init` supplies PIO SPI. The RP2xxx
  example build reserves 22 bytes of headroom and a 1540-byte RX buffer, including the
  bus status word. Preserve the four-byte alignment and accessible tail padding
  for the TX adapter's word-rounded transfer. The driver reports association as
  link state and checks firmware credit before writing TX.
- In `examples/raspberrypi/rp2xxx/src/net/irq.zig:main`, GPIO masks the source and posts a wake.
  The HAL also masks the pin around SPI transfers and restores its previous state. Foreground drains RX, and
  `drivers/src/wireless/cyw43439/wifi.zig:read` asks the HAL to re-arm when the interrupt
  is set, no packet remains and join state is other than `.none`.
- For RTOS station RX, use `examples/espressif/esp/src/selftest_wifi_checks.zig:on_packet_received`
  and `examples/espressif/esp/src/selftest_wifi_checks.zig:exercise`. They use release/acquire
  to publish the registered netif across tasks. `examples/espressif/esp/src/tcp_server.zig:serve` shows
  station DHCP. `examples/espressif/esp/src/softap.zig:main` registers the AP with a
  static IPv4 address, mask and gateway. `examples/espressif/esp/src/selftest_coex_wifi_ble.zig:cycle_wifi` keeps the
  registered netif alive, gates TX with `wifi_live`, and reinitializes the same `Wifi` handle.

## Shared patterns

- [Interrupt handling and ISR routing](interrupts.md) covers the ISR-to-foreground handoff.
- [Base driver interfaces](base-interfaces.md) describes device vtables for portable drivers.
- [ESP Wi-Fi handle](esp-wifi-handle.md) covers Wi-Fi ownership and lifecycle.

## Evidence

- `drivers/src/wireless/cyw43439/wifi.zig` defines "events to join_state" for association
  state and "receive capacity rejects oversized packets and polls full Ethernet frames"
  for checking RX capacity before the bus read. No build test step includes these tests.
- `zig build test` in `examples/espressif/esp/` runs "DHCP allocation, renewal, collision, release, exhaustion and expiry"
  in `examples/espressif/esp/src/softap_dhcp.zig`, covering the AP's lease logic.
- The ESP port README records station DHCP and TCP echo between an ESP32-C3 and a XIAO ESP32-C6
  in both roles. Build the images in `examples/espressif/esp/` with `-Dexample=selftest_wifi_softap_echo` and `-Dexample=softap`.
  [ESP Wi-Fi self-tests](../../port/espressif/esp/README.md#wi-fi-station-and-rtos)
- The network host tests check TCP send limits against the compiled lwIP configuration.
- No host test checks build configuration, pbuf failure ownership, TX headroom and
  scratch lifetime, core-lock use, callback and close ordering, netif flags and link handoff,
  allocator lifetime and concurrency, timers, sys_arch waits or Pico ISR handoff and re-arm.

## Open questions

- `modules/network/src/root.zig:Interface.poll` can return on a receive error before installing pbuf cleanup. ([#80](https://github.com/valthon/microzig/issues/80))
- `modules/network/src/root.zig:Interface.poll` trusts the frame length without checking it against the remaining pbuf. ([#80](https://github.com/valthon/microzig/issues/80))
- `modules/network/src/root.zig:Interface.c_netif_linkoutput` extends the original pbuf for headroom without restoring it. ([#80](https://github.com/valthon/microzig/issues/80))
- `modules/network/src/root.zig:Interface.init` reinitializes global lwIP on each call and leaves the interface registered on a DHCP start error. ([#80](https://github.com/valthon/microzig/issues/80))
- `modules/network/src/root.zig:Interface.ready` checks a word of the primary address union and misses the separate IPv6 slots. ([#80](https://github.com/valthon/microzig/issues/80))
- `modules/network/src/root.zig:tcp.Connection.c_on_recv` calls `on_recv` before `tcp_recved`, so a close there can discard queued output and send RST. ([#80](https://github.com/valthon/microzig/issues/80))
- `modules/network/src/root.zig:tcp.Connection.close` sets `.closed` while the old PCB can still call the wrapper on data ACKs or reset during FIN processing, so `.closed` is unsafe as a reuse signal. ([#80](https://github.com/valthon/microzig/issues/80))
- `examples/raspberrypi/rp2xxx/src/net/tcp_client.zig:Client.tick` reconnects on `.closed`, and `examples/raspberrypi/rp2xxx/src/net/tcp_server.zig:on_accept` recycles session slots on the same state. ([#80](https://github.com/valthon/microzig/issues/80))
- `modules/network/src/root.zig:Endpoint.parse` and `Interface.Options.Fixed.init` pass slice pointers to C parsers that expect NUL termination. ([#80](https://github.com/valthon/microzig/issues/80))
- `modules/network/src/root.zig:Endpoint.format` always formats the address as IPv4. ([#64](https://github.com/valthon/microzig/issues/64))
- `examples/raspberrypi/rp2xxx/src/net/irq.zig:main` can lose a wake posted between reading and clearing the flags. ([#80](https://github.com/valthon/microzig/issues/80))
- `examples/espressif/esp/src/tcp_server.zig:run` can return from an ordinary server error even after successful Wi-Fi teardown, while lwIP still references the stack-local netif and allocator. ([#81](https://github.com/valthon/microzig/issues/81))
- `examples/espressif/esp/src/tcp_server.zig:run_server` can deinitialize Wi-Fi after a server error with the netif still up and registered, allowing TX to overlap teardown. ([#81](https://github.com/valthon/microzig/issues/81))
- `examples/espressif/esp/src/tcp_server.zig:maybe_netif` is shared with the vendor task without synchronized publication. ([#81](https://github.com/valthon/microzig/issues/81))
- `examples/espressif/esp/src/softap.zig:main` can return while the reporter, Wi-Fi or lwIP still uses its stack-local allocator. ([#81](https://github.com/valthon/microzig/issues/81))
- `examples/espressif/esp/src/lwip/exports.zig:sys_mbox_trypost` exports a from-ISR alias that uses the task queue API. ([#81](https://github.com/valthon/microzig/issues/81))
- `examples/espressif/esp/src/lwip/exports.zig:lwip_assert_core_locked` checks for a lock holder without checking that it is the calling task. ([#81](https://github.com/valthon/microzig/issues/81))
- `examples/espressif/esp/src/selftest_coex_wifi_ble.zig:cycle_wifi` clears the TX gate without synchronizing with a `linkoutput` already inside that gate before deinit. ([#81](https://github.com/valthon/microzig/issues/81))
