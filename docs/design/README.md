# Design docs

One short document per subsystem: what it is for, where the code is, what must stay true, and
which other parts of the tree solve the same problem. They exist so that a new feature can reuse a
pattern by reading a page instead of re-reading the source.

A design doc describes the code; it never replaces it. It points at files and symbols instead of
copying them, and it stays short (one to three screens). It holds only what stays true until the
design changes: no commit ids, test counts, run results or timings, which belong in git and CI.

## Keeping a doc current

One rule: **if a PR changes a documented behavior or contract, it updates the design doc in the
same PR.** If the doc still describes the code accurately, leave it alone; git records when the
doc changed.

For example, a Wi-Fi logging change leaves [`interrupts.md`](interrupts.md) alone. A change to when
ESP-NOW releases its routing owner during teardown updates the ownership rule there and names the
test that protects the new behavior.

To help reviewers find these, the Lint workflow lists in the job summary every doc whose
`Covers:` paths a PR touches
([`scripts/design_docs/touched_docs.py`](../../scripts/design_docs/touched_docs.py)). A match
says where to look; the reviewer decides whether a documented claim needs updating.

## Design first

An interrupt-driven driver, a new `drivers/src/base/` interface, or any feature where foreground
code and an ISR or the hardware share a state machine, polled drivers included, gets its design
reviewed before the code ([`AGENTS.md`](../../AGENTS.md) rule 8): the tables from
[`DRIVER_DESIGN.md`](../../DRIVER_DESIGN.md) and the prior art in this tree. The PR records that
review. The design sketch becomes a maintained doc here once it holds decisions future
contributors will need; until then it can live in the PR.

## Format

Copy [`TEMPLATE.md`](TEMPLATE.md). Under the title, a `Covers:` line lists every file or
directory (trailing `/`, comma-separated plain paths) the doc makes claims about:

```
Covers: core/src/interrupt.zig, port/espressif/esp/src/hal/radio/
```

Sections, in order (leave out a section that does not apply; never leave a heading empty):

1. **Purpose**: what the subsystem does and what it does not, in a few lines.
2. **Code map**: `path:symbol` pointers to the entry points and the main types.
3. **Invariants**: what must stay true, as rules a reviewer can check.
4. **Design tables**: for a state machine shared by foreground code and an ISR or the hardware
   (polled included), the tables from `DRIVER_DESIGN.md` (phases, ownership, events × phases,
   entry points × phases, timing budget, spec rules); for an interface, the consumer trace.
   Hardware numbers cite the datasheet (document and section).
5. **Prior art**: other code in this tree, or a vendor reference whose licence allows reading,
   that solves the same problem; what this design reuses from it and why it differs.
6. **Shared patterns**: links to the docs below that this subsystem uses, instead of restating them.
7. **Evidence**: durable evidence only. Name the test that protects each invariant, or the board
   and self-test that validated a hardware behavior. Totals and per-run results stay in CI.
8. **Open questions**: known gaps, each one line, with an issue link where one exists.

## Index

| Doc | Covers |
| --- | --- |
| [Interrupt handling and ISR routing](interrupts.md) | core interrupt API, vector tables, singleton routing |
| [ESP Wi-Fi handle](esp-wifi-handle.md) | Wi-Fi ownership, lifecycle and vendor event routing |
| [ESP USB Serial/JTAG logger](usb_serial_jtag_logger.md) | logger queue, reattach hold, and replay |
| [ESP radio stack and coexistence](esp-radio.md) | common radio lifetime, coexistence adapter, blob OS interface |
| [USB device stack](usb-device.md) | portable USB device core, controller ports, and class drivers |
| [Network and lwIP](network.md) | lwIP build, Ethernet netifs, buffer ownership and execution context |
| [DHCPv4 server](dhcp-server.md) | the shared access point DHCP server module and its two callers |
| [Base driver interfaces](base-interfaces.md) | portable driver contracts, HAL adapters and consumers |
| [nRF52840 IEEE 802.15.4 radio](ieee802154.md) | portable 802.15.4 interface and nRF52840 driver |

Planned backfills, in the order upcoming work needs them: the ESP IEEE 802.15.4 MAC
(`esp-ieee802154.md`).
