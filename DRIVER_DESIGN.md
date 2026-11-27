# Designing interrupt-driven drivers and interfaces

> **When this applies:** an interrupt-driven driver (a radio, a USB stack, a DMA engine, a CAN
> controller), a new `drivers/src/base/` interface, or any feature where foreground code and an ISR
> or the hardware share a state machine, polled drivers included.
>
> **What it asks for:** a design, reviewed **before** the code, with the six kinds of table below
> (the examples show their shape; they are not a real driver). Code review then checks the code
> against the tables, instead of rediscovering the state space one path per review round.

The hard bugs in these drivers are rarely data races on a variable; [`NO_SLOP.md`](NO_SLOP.md) §2.3
covers those. They are races between *states*: the hardware latches an event while the foreground
holds a critical section and changes phase; a public call is accepted in a phase that an interrupt
owns; a deadline is judged by when software looked rather than when the hardware acted. Reviewers
find these one at a time. Tables find them as a class.

The design also cites prior art: the code in this tree that already solves the same problem. The
PR records its review; the tables move into the subsystem's doc in
[`docs/design/`](docs/design/README.md) once they hold decisions future contributors will need.
Reviewed tables bind the code: an implementation that departs from them is a finding, and a
deliberate change of design updates the tables in the same PR.

## 1. Phases

One row per phase of the state machine. Name who may change the phase and how the driver leaves it.

| Phase | Hardware doing | Entered by | Left by (event or call) | Owner of the transition |
| --- | --- | --- | --- | --- |
| `idle` | off | init, completion | `transmit`, `receive` | foreground |
| `rx` | receiving | `receive`, idle policy | frame end (ISR), `transmit`, any call that retunes | both: say which wins |
| `auto_ack` | sending our ACK | frame end with ACK requested (ISR) | ACK end (ISR) | ISR only |
| `tx` | transmitting, then waiting for an ACK | `transmit` | TX done or ACK timeout (ISR) | ISR leaves it |

A phase that the ISR enters and leaves on its own (like `auto_ack`) must still appear: it is the
phase foreground calls most often forget.

## 2. Ownership

One row per mutable field. A field written by both sides names its guard. A field that encodes a
*request* (the channel the user asked for) is never reused for *current* state (the channel the
hardware is on now), because one operation overwrites the other's value.

| Field | Written by | Read by | Guard |
| --- | --- | --- | --- |
| `phase` | foreground, ISR | both | critical section |
| `requested_rx_channel` | foreground | ISR | critical section |
| `active_channel` | ISR | ISR | none (ISR only) |

## 3. Events × phases

For every hardware event the driver enables (or that a shortcut can trigger), and every phase: what
happens. Include the cell nobody writes by default: **the event latched while the foreground was in
a critical section and is about to change phase.** Before any transition hands a buffer or the
hardware to the next phase, the driver reconciles events already latched (a received frame that
reached its end, a transmission that already started) and reports them, in order, before the
transition's own result.

Also say, for each event, where it is cleared. Clear an event before the action that will set it
again, never only after, or a stale latch completes the next wait early.

| Event | `idle` | `rx` | `auto_ack` | `tx` | Cleared |
| --- | --- | --- | --- | --- | --- |
| frame end | impossible (RX off) | deliver; start ACK if requested | impossible | ACK candidate | in ISR, before re-arming RX |
| frame end latched during a foreground transition | n/a | reconcile: deliver before the transition's result | n/a | reconcile before `tx` reports | by the transition, after reconciling |
| TX started | impossible | impossible | ours (the ACK) | report attempt start | before triggering TX |

## 4. Entry points × phases

For every public function (including configuration setters) and every phase: **run**, **`Busy`**, or
**defer until phase X ends**. No empty cells. When a review finds one wrong cell, re-check the whole
row and the whole column in the same fix.

| Call | `idle` | `rx` | `auto_ack` | `tx` |
| --- | --- | --- | --- | --- |
| `transmit` | run | run (stops RX) | `Busy` | `Busy` |
| `receive` | run | run (retunes) | `Busy` | `Busy` |
| `configure` | run | run (retunes) | `Busy` | `Busy` |

## 5. Timing budget

Every deadline, latency, settle time, throughput and counter range the driver relies on, with its
source. A number with no datasheet citation is an open question, not a constant
([`AGENTS.md`](AGENTS.md) rule 7).

| Quantity | Value | Source (document, section) | Used in |
| --- | --- | --- | --- |
| event latency after the last bit | | | deadline check |
| settle time before a measurement | | | sampling |
| timer range at the largest accepted argument | | | timeout validation |

Rules that follow from the table:

- A decision about *when something happened* (in a window, late, timed out) uses a hardware
  timestamp captured at the event (a PPI/ETM capture into a timer), corrected by the documented
  latency. The order in which a poll or an ISR *notices* two events says nothing about the order
  they happened in.
- A wait guarantees only its worst-case minimum, not the value requested. When a `sleep_us` polls a
  tick-quantized clock, the call can start just before a tick, so the elapsed time can fall short of
  the request by up to one tick period plus any rounding in the tick-to-microsecond conversion.
  Check that bound against the settle time, for every request length, not only short ones; when it
  falls short, use a free-running microsecond timer or pad the request by the shortfall.
- Reject arguments the budget cannot serve (a timeout that leaves no room to capture the end event
  before the timer saturates) with an error, and test the boundary on the host.

## 6. Spec rules

For a driver that implements a standard (IEEE 802.15.4, USB, CAN), one row per rule the driver
enforces: the clause, the rule in one line, and the host test that covers it. Rules come from the
clause, not from memory. Include malformed and unusual-but-legal inputs (a broadcast PAN with a
unicast address, a secured frame, a frame version the driver does not fully parse).

| Clause | Rule | Host test |
| --- | --- | --- |
| <standard, clause> | <the rule in one line> | <test name> |

Factor these rules into pure functions so the tests run on the host.

## 7. Interfaces: trace every consumer

A new interface in `drivers/src/base/` is checked against the code that will call it, before any
port implements it. For each consumer the interface claims to serve (for a radio: OpenThread's
`otPlatRadio*`, a Zigbee MAC, a sniffer), map every consumer call and callback onto interface calls
and events, and answer:

- **Correlation:** how does a caller tell its own completion from an earlier one still queued?
- **Buffer lifetime:** until when may the caller reuse a buffer it passed in, or one it received?
- **Event completeness:** does every event the consumer expects exist, once per occurrence (per
  attempt, not per request), with the fields it needs (timestamps)? Is queue space reserved for every
  event an accepted operation can emit?
- **Notification:** one notification per event, or coalesced with a documented "drain until empty"
  rule?
- **Argument rules:** which fields are ignored in which modes (a backoff count with CSMA off)?
- **Unavailable:** what does each call do before init and after deinit? A blocking wrapper must not
  spin on a clock that never advances.
- **Same meaning across ports:** a boolean or enum with the same name means the same thing in every
  port (`cca() == true` is either "clear" everywhere or "busy" everywhere).

## Review

A reviewer checks the code against these tables, cell by cell, and states coverage: which entry
points and which phases were checked. A finding names its class (phase, ownership, latched event,
entry point, timing, spec rule, contract), and its fix covers every instance of that class, not only
the one found.
