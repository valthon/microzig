# DHCPv4 server

Covers: modules/dhcp-server/, examples/espressif/esp/src/softap.zig, examples/raspberrypi/rp2xxx/src/net/access_point.zig

## Purpose

A small DHCPv4 server (RFC 2131, options from RFC 2132) for a device that runs its own access
point and hands addresses to the stations that join it. It parses one request datagram and
builds the reply. It owns no socket, task or clock: the caller receives on UDP port 67, passes
the bytes and a millisecond clock in, and sends the reply. That keeps it usable from the
bare-metal network module on the Pico W and from the RTOS lwIP glue on ESP.

It assumes it is the only server on its link, which is true of an access point's own network.
It serves directly attached Ethernet-type clients only. It does not do relay agents, option
overload, DHCPINFORM, static reservations, persistent leases or leases keyed on the client
identifier (option 61), and it does not probe an address before offering it (the ICMP echo that
RFC 2131 §3.1 step 2 and §4.3.1 say a server SHOULD send). The subnet is fixed at build time, so
a device that is also a station must pick one that cannot collide with its uplink.

A lease ends only by its holder's own message (RELEASE, DECLINE, or a REQUEST for another
address that the server ACKs) or by expiry, and a declined address only by expiry. The server
takes no input about stations joining or leaving the access point: a station that leaves
without RELEASE keeps its address until its lease runs out, and the caller sizes the pool for
that ([Pool sizing](#pool-sizing)). In exchange, within one run of the server, it does not hand
out an address while another client holds a lease on it. The lease table is volatile and there
is no probe, so after the access point restarts, an address a client still uses under an
earlier lease can be offered to another client until the first one renews or reboots.

## Code map

- `modules/dhcp-server/src/root.zig:Config`: server address, netmask, first pool address, pool
  size, lease and offer times, and whether to advertise a router and a DNS server. Checked at
  comptime.
- `modules/dhcp-server/src/root.zig:Server`: `Server(config)` returns a type that holds the
  lease table inline and exports `server_ip` and `netmask`.
  `receive(packet, now_ms)` returns `?Reply`; `address(index)` gives a pool entry's address.
- `modules/dhcp-server/src/root.zig:Reply`: the reply bytes, the destination address, the
  address just acknowledged (for logging) and the client MAC.
- `examples/espressif/esp/src/softap.zig:dhcp_receive`: lwIP raw UDP callback on ESP;
  `max_stations` and `Dhcp` size the pool against the access point's station limit.
- `examples/raspberrypi/rp2xxx/src/net/access_point.zig`: `net.Udp` callback on the Pico W.

## Invariants

Input:

- `receive` never reads past `packet.len` and never trusts a length it has not checked. It drops a
  datagram that is shorter than the fixed header and cookie, is not a BOOTREQUEST, has `htype`
  other than Ethernet or `hlen` other than six, has a non-zero `giaddr` (relayed), has a multicast
  or all-zero `chaddr`, has a magic cookie other than 99.130.83.99, carries option 52 (overload),
  has no option 53, has a duplicated or wrongly sized option 50, 53 or 54, or ends inside an
  option (a code with no length byte, or a length that runs past the end). Pad options are
  skipped. A datagram dropped by these checks changes nothing; one that passes them runs the
  expiry sweep, even when it gets no reply.
- An address a client names indexes the lease table only after a check that it lies in the
  pool; a REQUEST for an address outside it, the server's own included, is NAKed.

Leases:

- One entry per client MAC. A DISCOVER from a MAC that holds an offer or lease gets the same
  address back, and leaves a bound lease's start time alone. Otherwise it reserves a free address
  for `offer_ms`: the one this MAC held last, else the one freed earliest, never-held entries
  first, so a released or lapsed address is the last one reused. A freed entry remembers its last
  holder and the order of frees as the server saw them: a lapsed lease counts as freed when the
  next datagram arrives, not when it ran out. With no free address the DISCOVER gets no reply.
- REQUEST takes the address from option 50, or from `ciaddr` when option 50 is absent, and is
  dropped if neither is set (RFC 2131 §4.3.2 tells SELECTING and INIT-REBOOT, which carry option
  50, from RENEWING and REBINDING, which carry `ciaddr`). It is ACKed when that address is in the
  pool and free or already the client's, and NAKed otherwise. An ACK restarts the lease and frees
  any other entry the MAC held.
- Deliberate deviation from §4.3.2: an INIT-REBOOT from a client the server has no record of is
  ACKed when its address is free, rather than ignored. As the only server on the link, the server
  is authoritative, and a station keeps its address across an access point reboot. SELECTING is
  likewise not required to name the offered address, and a REQUEST may take any free pool
  address, including one that remembers another holder.
- Any message naming another server (option 54) is dropped. A REQUEST naming another server
  also frees an offer, not a lease, that the client held (§3.1 step 4). DECLINE takes the
  address out of the pool for one lease time, in an entry that holds no MAC; when that time has
  passed the entry counts as freed, so the declined address is the last one reused. RELEASE
  frees the address. Both act only when the address matches the client's own entry; neither
  requires option 54, though Table 5 makes it a MUST for the client.
- Nothing else frees a held entry: an offer lapses `offer_ms` after it was made or last renewed
  by a retransmitted DISCOVER, a lease `lease_ms` after its last ACK. A bound entry is freed only
  by its own holder (RELEASE, DECLINE, an ACK for another address) or by its lease running out,
  so within one run the server never offers or ACKs an address to a second client while the
  first holds a lease on it.
- Time is a wrapping `u32` millisecond count, compared by wrapping subtraction. Lease and offer
  times are below 2^31 ms. Expiry is evaluated inside `receive`, so an entry is only guaranteed to
  expire if `receive` runs at least once every 2^32 ms minus its duration.

Output (RFC 2131 §4.3.1, Table 3):

- Every reply is `reply_len` (300) bytes, the BOOTP minimum (RFC 1542 §2.1), zero-padded.
- `op` is BOOTREPLY; `htype`, `hlen`, `xid`, `flags` and the 16-byte `chaddr` are echoed; `hops`,
  `secs` and `giaddr` are zero. An OFFER has `ciaddr` zero; an ACK echoes it. `yiaddr` and
  `siaddr` are the leased and server addresses, and zero in a NAK.
- An OFFER or ACK carries options 53, 54, 51 (the full lease time) and 1, plus 3 and 6 when
  configured. T1 and T2 (58, 59) are omitted; clients default them to 0.5 and 0.875 of the lease.
  A NAK carries only 53 and 54.
- Destination: an ACK goes to `ciaddr` when `ciaddr` equals the acknowledged address; everything
  else, NAKs included, is broadcast. §4.1 would unicast to `chaddr` and `yiaddr` when the
  broadcast flag is clear, but neither caller can send to an address that has no ARP entry, so
  this server broadcasts instead.

Callers:

- Calls to one `Server` are serialized by the caller. `Reply` is returned by value (over 300
  bytes), so the receive context needs that much stack beyond its own input buffer.
- The pool is sized above the number of stations the access point admits
  ([Pool sizing](#pool-sizing)).

## Design tables

Consumer trace: every caller of `modules/dhcp-server`.

| Consumer | Receive path | Clock | Send path | Pool | Serialization |
| --- | --- | --- | --- | --- | --- |
| `examples/espressif/esp/src/softap.zig` | `udp_recv` callback on a PCB bound to port 67 and the AP netif; drops a source port other than 68; copies the pbuf chain into a 1500-byte stack buffer | `hal.time.get_time_since_boot`, truncated to ms | `pbuf_alloc` and `udp_sendto_if` on the AP netif to `Reply.destination`, port 68 | `lease_count` is twice `max_stations`, the access point's `max_connections`; one-hour leases | lwIP core lock: `tcpip_input` with locked input runs the receive callback in the Wi-Fi receive task holding it; nothing else calls the server |
| `examples/raspberrypi/rp2xxx/src/net/access_point.zig` | `net.Udp.bind(67, on_recv)`; drops a source port other than 68; reassembles the segments up to `last_fragment` into a static buffer | `time.get_time_since_boot`, truncated to ms | `net.Udp.send` to `Reply.destination`, port 68 | sixteen entries, one-hour leases; the CYW43439 driver has no station limit to size against | single foreground loop around `Interface.poll` |

### Pool sizing

Held entries are the offers and leases of associated stations, plus the leases of clients that
left without RELEASE and whose lease time has not passed, plus offers to clients that left
before requesting them, for `offer_ms`, plus declined addresses for one lease time. A station
that leaves and comes back with the same MAC finds its own entry and takes no second one.

On ESP the access point admits at most `max_stations` stations (`max_connections`), and the pool
holds twice that. Provided each associated station uses one `chaddr`, a joining station finds a
free address as long as departed clients' leases, their offers and declined addresses together
hold no more than `max_stations` entries. A station that changes its `chaddr` takes a second
entry (see Open questions), so the bound does not hold for it. When those entries exceed
`max_stations`, a DISCOVER gets no reply until the earliest of them expires, at most one lease
time later. A shorter `lease_ms` lets the pool absorb more departures per hour, at the cost of
more frequent renewals. `max_stations` is checked at comptime against the station list the blob
can report (`radio.wifi.max_ap_stations`), and `Wifi.apply` rejects a larger `max_connections`.

The CYW43439 driver sets no station limit and reports no station events, so the Pico W example
cannot tie the pool to a cap; it uses a pool larger than the stations it expects, and past that a
new client waits for a lease to expire as above.

## Prior art

- `ZigEmbeddedGroup/microzig#1147` (`modules/dhcp-server`, unmerged upstream): the module's place
  in the tree and its comptime `Server(config)` shape with a configurable subnet, and the rp2xxx
  access point example, come from here. Its parser is replaced. It NAKs every renewal (it
  requires option 50, which RENEWING clients omit) and every INIT-REBOOT after a server reboot;
  it slices the options before checking that the datagram is long enough; it reads the pad option
  as a tag with a length; and it advertises half the lease time it enforces. Its example always
  broadcasts, because the module returns no destination.
- `examples/espressif/esp/src/softap_dhcp.zig` (removed by this change): the fork's earlier
  example-local server. Its request handling, packet checks and tests move into the module; its
  fixed 192.168.4.0/24 pool of four, one per admitted station, becomes `Config`, and the ESP
  example doubles it. The move also zeroes `secs`, and `siaddr` in a NAK, as Table 3 requires,
  unicasts only to a configured `ciaddr`, and frees the offer of a client that chose another
  server.
- lwIP's `apps/dhcpserver` is not in the pinned lwIP tree, and ESP-IDF's `dhcpserver.c` is tied to
  its esp-netif and socket layers, so neither suits a caller-driven parser shared by two stacks.

## Shared patterns

- [Network and lwIP](network.md): netif registration, raw UDP callbacks and the lwIP core lock
  that both consumers rely on.
- [ESP Wi-Fi handle](esp-wifi-handle.md): the soft-AP station limit and the station count the ESP
  status report reads.

## Evidence

Tests in `modules/dhcp-server/src/root.zig`, run by `zig build test` in `modules/dhcp-server/` and
in `examples/espressif/esp/`:

- Leases, renewal without option 50, collision, RELEASE of the client's own address only,
  exhaustion and offer expiry: "DHCP allocation, renewal, collision, release, exhaustion and
  expiry".
- Each drop check listed under Input, each on a datagram that is otherwise answered, and that
  a dropped datagram leaves the server unchanged: "DHCP drops a datagram that fails each input
  check". A REQUEST with neither option 50 nor `ciaddr`: "DHCP drops a REQUEST that names no
  address". The pool check, on the addresses just below and just past the pool: "DHCP NAKs a
  REQUEST just outside the pool".
- A REQUEST naming another server frees the client's offer, and no other message naming another
  server does: "DHCP SELECTING another server frees the offer", "DHCP keeps an offer against
  messages naming another server other than REQUEST" and "DHCP REQUEST naming another server
  from a client with no entry changes nothing".
- A bound lease survives every path that frees an entry: a message naming another server,
  DECLINE or RELEASE of another address or from another client, another client's ACK and
  REQUEST, DISCOVERs filling the pool and the expiry sweep: "DHCP keeps a bound lease through
  every path that frees an entry". An ACK for another address frees the client's old entry:
  "DHCP ACK for another address frees the client's old entry".
- An offer reserves its address against another client's REQUEST until it lapses: "DHCP NAKs a
  REQUEST for an address offered to another client until the offer lapses"; also when the
  offered address was released or lapsed before: "DHCP reserves a released or lapsed address
  when it offers it again". RELEASE, DECLINE and an ACK for another address act on an offer as
  on a lease: "DHCP RELEASE, DECLINE and an ACK for another address act on an offer as on a
  lease".
- The no-second-holder invariant under random datagrams from several clients against a small
  pool, across the clock wrap, with a model of every offer, lease and quarantine: "DHCP model
  check: no address goes to a second client while it is held".
- Retransmission, DECLINE quarantine for exactly a lease time and clock wrap: "DHCP
  retransmission, selecting, decline quarantine and clock wrap"; a lease made before the clock
  wraps lasts its lease time across the wrap: "DHCP keeps a lease across the clock wrap until it
  expires"; a retransmitted DISCOVER restarts the offer: "DHCP DISCOVER retransmission restarts
  an offer"; a quarantine holds no MAC and is reused last once it expires: "DHCP quarantine
  holds no MAC and goes to the back of the reuse order when it expires".
- A bound lease lasts exactly its lease time, and a DISCOVER from its holder does not restart it:
  "DHCP keeps a lease until it expires when its holder sends DISCOVER".
- Address reuse order: "DHCP hands out the address freed earliest" and "DHCP gives a returning
  client its previous address and others an unused one".
- Reply header fields, options, pad skipping and destinations: "DHCP skips pad options and builds
  RFC 2131 reply fields", "DHCP reply address fields" and "DHCP unicasts only to a configured
  client address".
- Reply size with every option configured: "DHCP fits router and DNS options together".
- `Config`: "DHCP serves a non-default subnet and advertises DNS".
- `Wifi.apply` rejecting `max_connections` above `max_ap_stations`: "apply holds the lifecycle
  claim from the mode change through every interface configuration" in
  `port/espressif/esp/src/hal/radio/wifi.zig`; the station count it reports bounded by the same
  list: "the soft-AP station count must lie within the blob's station list" there.
- Pool sizing follows from the invariants above; no test runs an example with a full set of
  stations.

## Open questions

- No station limit in the CYW43439 driver, so a Pico W access point cannot cap stations below
  its pool size.
- `drivers/src/wireless/cyw43439/wifi.zig:join` does not undo the chip's access point settings
  (`apsta`, `set_ap`); call `stop_ap` before joining, including after a failed `start_ap`.
- `drivers/src/wireless/cyw43439/wifi.zig:response_poll` drops event frames, so if the chip sent
  the access point's link event before answering the last `start_ap` ioctl, the link would never
  report up. Hardware has to show which order the chip uses.
- Leases are keyed on `chaddr` only; a client that changes its MAC (randomization per connection)
  takes a new address each time until the old one expires, and uses up the pool's margin.
