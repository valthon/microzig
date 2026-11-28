# ESP USB Serial/JTAG logger

Covers: port/espressif/esp/src/hal/usb_serial_jtag.zig, port/espressif/esp/src/hal/usb_serial_jtag/, examples/espressif/esp/src/selftest_usj_reenumerate.zig

## Purpose

The ESP32-C3/C6 `std.log` backend buffers lines from boot, after HAL reattach, and after a transmit
timeout. Output resumes after observed IN drain and a settle delay. Application capture remains
best effort.

The first unmasked boot log probes immediately. If the host is already reading, the same call
observes the drain, waits about 100 ms for settle, and sends the queued lines and its own line.
On C6, a commit during enumeration can stick, as observed in the Windows reconnect diagnostic.
At boot this can happen when the host enumerates a powered-on board, where the pre-PR logger lost
those lines. Later unmasked calls can re-commit the stuck probe at 500 ms intervals.

HAL reattach keeps the 100 ms probe delay. Lines logged only in that first 100 ms stay queued
until a later unmasked call. The pre-PR logger lost those lines. A replug on a self-powered board,
a port close and reopen, or a host-side reset can trigger a new hold when a direct send times out.
A replug on a bus-powered board starts a new boot hold.

## Code map

- `port/espressif/esp/src/hal/usb_serial_jtag.zig:Logger.log` drives the hold. `Writer` sends
  direct output and reports. `Disconnect.finish` and `Reenumeration.attach` restart the hold.
- `port/espressif/esp/src/hal/usb_serial_jtag/state.zig:State` tracks claims and losses.
- `port/espressif/esp/src/hal/usb_serial_jtag/test_host.zig` models FIFO, time and preemption.
- `examples/espressif/esp/src/selftest_usj_reenumerate.zig:main` logs a sequence across reconnects.

## Invariants

- Held calls append only complete lines. Overflow keeps earlier entries. On release, any loss
  report precedes the queued lines in FIFO order, followed by the releasing caller's line.
- With holding enabled, boot requires a fresh commit on the first unmasked call. An actual HAL
  reattach requires a fresh commit at least 100 ms after the hold starts. Settle starts at the
  protected observation of readiness after the commit, and any unmasked caller can complete it.
- Held masked calls leave the FIFO alone. A call that finds the writer busy counts a drop and
  leaves ownership with the active caller.
- The owner formats each accepted line once. Before sending a new line, it stages the bytes in
  the queue after any earlier lines have drained. If it outgrows the queue during formatting,
  the writer streams the staged prefix and the remaining bytes directly without restarting.
- A TX timeout re-holds during normal logging. Replay keeps the bytes and timestamp of each
  untouched line. It retires and counts a line once it commits any bytes and then times out.
  An oversized line streamed directly is counted on timeout, even before its first commit.
  If a report or an earlier line times out, the current line is appended if it fits. A confirmed
  report subtracts only its snapshotted count.
- Fatal takeover abandons the old writer's buffered bytes. With holding enabled it drops the RAM
  queue and suppresses reports. A pending FIFO commit can still block fatal output, and EP1 is not
  reset: bytes of a packet the old owner had started but not committed go out ahead of the fatal
  text (as before the hold queue).

## Design tables

### Phases

Zero hold size bypasses the hold phases. `masked` means global interrupts off or a nonzero ESP
interrupt priority threshold at `log` entry.

| Phase | FIFO and queue | Transition and owner |
| --- | --- | --- |
| No hold (`.inactive` or holding disabled) | Stage and send the current line with holding enabled. Otherwise use direct output or the stalled path below. | A TX timeout with holding enabled enters `.tx_pending`. With holding disabled, it sets `host_stalled` and a ready sample permits another send. |
| Hold without probe (`.probe(eligible_at)`) | RAM queue | At boot `eligible_at` is absent and the first unmasked `log` commits. After HAL reattach, queue without FIFO access or a wait until the deadline. The first eligible unmasked `log` writes `WR_DONE` under the critical section without sampling `DATA_FREE`. It commits an earlier packet if still present, otherwise an empty buffer. |
| Probe pending (`.probe_pending(last_commit)`) | Drain supplies evidence | At the start of an unmasked probe wait, re-commit under the critical section if at least 500 ms has elapsed and the FIFO still reads full. Poll outside the critical section and recheck readiness inside it. |
| Drained / settling (`.settling(until)`) | RAM queue, absolute deadline | Unmasked `log` records readiness. At expiry, its claim sets `.inactive`. |
| Replaying (`.inactive`, writer claimed) | Owner sends any loss report, earlier queued lines, then the newly staged or oversized current line. | Owner finishes sending or enters `.tx_pending` on a TX timeout at any of those stages. |
| Re-held (`.tx_pending(last_commit)`) | Retained queue, FIFO may be full | Unmasked `log` samples readiness and re-commits if still full and the retry interval has elapsed. Ready starts settle. |
| Panic (`panic_mode`, `.inactive` when enabled) | Direct fatal output, including the stalled path | `prepare_panic` takes over with interrupts masked. The old owner never resumes. |

### Field ownership

| Field | Writers and guard |
| --- | --- |
| `state.busy` | Callers claim and release in a critical section. Fatal takeover clears it with interrupts disabled. |
| `state.dropped_lines` | Claim rejection, owner drops and confirmed-report subtraction use a critical section. Fatal takeover updates it with interrupts disabled. |
| `state.host_stalled` | Owner sets/clears it directly. With holding enabled, `start_hold` clears it in a critical section. Fatal takeover always clears it with interrupts disabled. |
| `hold.phase` and its timestamps | Boot starts `.probe(null)`. Unmasked `log` records commit times and settle deadlines and releases under the critical section. On a TX timeout the owner records the re-commit time in `.tx_pending` before releasing the claim. Quiesced reattach records the probe deadline and fatal takeover ends the hold with interrupts masked. |
| `hold_bytes`, `hold.len`, `hold.lines` | Owner formats, appends and compacts. Fatal takeover clears lengths and makes bytes inaccessible. |
| `hold.panic_mode` | Fatal takeover sets it with interrupts disabled when holding is enabled. |
| `buffer`, `writer.interface`, `writer.timeout`, `writer.deadline`, `writer.err` | Owner only. The owner can point the interface at the queue while staging and restores the direct writer after staging or on overflow. Fatal discard also restores the direct writer. `writer.storage` is fixed. |
| `boot_tx_checked` | First sending logger or serialized `write_blocking` caller sets it in `release_stuck_tx_at_boot` under a critical section. |

### Events × phases

The host can drain during a critical section. The logger reads `DATA_FREE` as a level and clears
no drain interrupt. A drain after the last full sample, before recovery writes `WR_DONE`, can
leave a new empty commit pending for the next call. Direct, panic and replay waits still time out
in that race. The already-stalled fast path still drops the line.

| Event | No hold / panic | Probe | Pending | Settling | Replay | Re-held |
| --- | --- | --- | --- | --- | --- | --- |
| Host drains | Ready resumes TX or ends the stalled fast path | Fresh commit still required | Protected ready sample starts settle | Deadline stands | Ready resumes TX | Protected ready sample starts settle |
| Host drains between retry's full sample and `WR_DONE` | See recovery race above | n/a | Retry commits an empty packet. Poll for its drain. | n/a | See recovery race above | Retry commits an empty packet. Sample again for its drain. |
| First probe or retry is due | n/a | First eligible unmasked call commits | At entry to the poll, re-commit only if due and still full | n/a | n/a | Re-commit only if due and still full, then sample again |
| Poll or settle deadline expires | If still full, re-commit and re-hold during normal logging with holding enabled. At zero hold size or in panic, drop and mark stalled. | No poll before commit | Queue if still full at recheck | Unmasked caller can claim | If still full, re-commit and re-hold. | No poll wait while full |
| Masked or preempting log | See entry table. Any busy claim drops and counts. | Same | Writer free during wait | Writer free during wait | Busy-drop | See entry table |
| Reattach / fatal takeover | Reattach requires quiescence in every phase. Fatal takeover abandons any owner and discards any held lines. | Same | Same, pending commit may survive fatal takeover | Same as probe | Same as probe | Same as probe |

### Entry points × phases

| Call | No hold | Probe | Pending | Settling | Any busy writer | Re-held | Panic |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `log`, masked | Stage and send with one deadline when holding is enabled. Re-hold on TX timeout. At zero hold size use the direct or stalled path. | Queue | Queue | Queue | Drop and count | Queue | Direct or stalled |
| `log`, unmasked | Stage and send when holding is enabled. Re-hold on TX timeout. At zero hold size use the direct or stalled path. | Commit and poll immediately at boot. After reattach, queue until eligible. | Re-commit if due and full, poll, then settle or queue | Wait and claim | Drop and count | Sample, re-commit if due and full, then settle or queue | Fatal path stays masked |
| `write_blocking` | Raw TX with logging quiesced | Quiesce logging. A log call can probe. | Same as Probe | Quiesce logging. A log call can replay. | Caller must quiesce first | Quiesce logging. A log call can retry or replay. | Outside fatal path |
| `start_hold` | Reset if enabled and quiescent | Same | Same | Same | Caller must quiesce first | Same | Outside fatal path |
| `prepare_panic` | Take over | Take over | Take over | Take over | Abandon owner | Take over | Take over |
| `Disconnect.begin` | Detach if pads enabled | Same | Same | Same | Caller must quiesce first | Same | Outside fatal path |
| `Disconnect.finish` | Reattach if saved pads enabled. Start a fresh hold on return, after any reset wait. | Same | Same | Same | Caller must quiesce first | Same | Outside fatal path |
| `Reenumeration.attach` (C3) | Restore `CONF0` and reset hold if enabled. Holding requires running SYSTIMER unit 0. | Same | Same | Same | Caller must quiesce first | Same | Outside fatal path |

Stalled direct and panic calls that sample a full FIFO reissue `WR_DONE`, count the drop and
return without polling. A ready sample resumes sending, with any applicable loss report first.

Quiesce logging and other USB users across detach and reattach in every phase, including direct
writes and queue formatting. `begin` leaves logger state alone. `finish` returns `null` and skips
attach and hold reset when the saved pads were disabled. Otherwise it clears stale reset status,
reattaches, then returns `null` if no host was counted, `false` on wait expiry, or `true` on
observing reset. On all three paths, it starts a fresh hold after any wait and before returning.
Starting the hold records the probe deadline in `.probe`, clears `host_stalled` and keeps queued lines.
At zero hold size, `start_hold` is a no-op and reattach can leave the logger stalled.
Fatal takeover still clears the stall. `panic_mode` stays unset and loss reports remain eligible.

### Timing budget

| Path | Budget and source |
| --- | --- |
| First probe and retries | Immediate on the first unmasked boot log call. After HAL reattach, `probe_delay` (100 ms) starts at `Reenumeration.attach` or the end of `Disconnect.finish` after any bus-reset wait. `probe_retry_interval` (500 ms) runs from the last commit. The Windows diagnostic first committed 100 ms after `reconnect()` returned and retried every 500 ms. Both intervals are checked on unmasked log calls and add no waits. |
| Unmasked hold | Probe polls for `packet_timeout` (2 ms), then rechecks readiness in the critical section even at expiry. Re-held samples without polling and samples again after a retry. `open_settle` (100 ms) runs from the ready observation to an absolute deadline, allowing for the Windows receive purge seen on the C6 bench. |
| TX polling | `packet_timeout` (2 ms per packet) for unmasked report, replay and current line. Shorter waits lost lines on Windows C3/C6 (comment at `writer.timeout`). A call can spend probe, settle and multiple TX budgets plus formatting and FIFO work. |
| Masked TX | Held calls never wait. Sends share one 2 ms `writer.deadline` across report and line, including staged, oversized and panic sends. An already-free FIFO can still accept a packet after expiry. |
| TX expiry | `wait_for_tx` samples readiness again after sampling expiry. Probe and TX can both accept ready after the deadline sample. |

See the doc comments on `Disconnect.begin` and `Disconnect.finish` for SOF and bus-reset sampling.

### Spec rules

| Clause | Rule | Host test |
| --- | --- | --- |
| C3 TRM v1.4 §30.3.2 and §30.6 regs 30.1/30.6. C6 TRM v1.2 §32.3.2 and §32.7 regs 32.1/32.2. | Check `SERIAL_IN_EP_DATA_FREE` before writing EP1 and after committing. Byte 64 auto-commits. A shorter buffer uses `WR_DONE`. | `logger strings crossing the line buffer keep their fields`, `state.zig`'s `deadline recheck accepts a packet drained during preemption` |
| C3 TRM v1.4 Table 30.3-1 | The controller accepts and ignores `SET_LINE_CODING`. The logger gates on IN drain. | `logger holds through Linux enumeration until tty open submits IN reads` toggles IN reads in the seam. Control requests are outside the model. |

## Prior art

- `release_stuck_tx` supplies the `WR_DONE` precedent for an empty or occupied IN buffer.
- `Disconnect` and `Attachment` use SOF, pending reset and reset history to decide whether to
  wait for a bus reset. The ESP-IDF USJ connection monitor uses SOF to detect a connected host.
  A host can enumerate and send SOFs with no application reading.
  [ESP-IDF connection monitor](https://github.com/espressif/esp-idf/blob/v5.5.1/components/esp_driver_usb_serial_jtag/src/usb_serial_jtag_connection_monitor.c)
- Linux `acm_port_activate` submits bulk IN reads on tty open. Windows pyserial 3.5
  `Serial.open` clears RX after `SetCommState`, motivating the settle.
  [Linux cdc-acm](https://github.com/torvalds/linux/blob/master/drivers/usb/class/cdc-acm.c),
  [pyserial 3.5](https://github.com/pyserial/pyserial/blob/v3.5/serial/serialwin32.py)

## Shared patterns

- [Interrupt handling and ISR routing](interrupts.md) covers nested critical sections and queue overflow policy.

## Evidence

Host tests are in `usb_serial_jtag.zig` unless marked `state.zig`.

- Queue integrity and order: `logger counts hold overflow and keeps complete earlier lines`.
- Probe timing and recovery include
  `a single unmasked boot log reaches an already reading host before returning`,
  `logger flushes an early boot burst on its first unmasked call`,
  `logger queues before the reattach probe delay even with a free FIFO`, and
  `logger re-commits a stuck probe at 500 ms intervals and settles after drain`.
  `Disconnect finish starts the probe delay after a slow bus reset` covers a reset wait longer than
  the initial probe delay.
- Fresh commit and settle: `the first eligible unmasked log after reattach starts a fresh probe`,
  `logger keeps the first queued line when an earlier packet blocks the FIFO`,
  `destructive reattach probes again after the controller discards a pending probe`,
  `logger measures settle from observation even if the packet drained long ago`, and
  `preemption at settle entry or during settle does not extend the deadline`.
- Masking and ownership: `masked calls queue without FIFO access during the probe and settle waits`,
  `masked logger keeps one deadline for the entire line`, and `state.zig`'s
  `claim rejects a preempting caller without releasing the owner`.
- Re-hold and loss accounting: `logger keeps untouched queued lines when replay stalls and settles again`,
  `logger re-commits a stuck replay after the retry interval and settles after drain`,
  `logger keeps the queue when the loss report stalls before replay`, and `state.zig`'s
  `unconfirmed delivery remains an upper bound; confirmed reports preserve new drops`.
- Direct stalls include `logger re-holds when the host stops reading after boot` and
  `logger preserves the original formatted line when a pending packet prevents its first commit`
  (both masked and unmasked), `logger streams an oversized line without restarting its formatter`, and
  `zero hold size drops lines while a direct write or loss report is stalled`.
- Fatal takeover and FIFO contention: `state.zig`'s `fatal takeover discards buffered owner and permits panic output`,
  `logger panic commits fatal text first when the first data packet stalls`, and
  `a panic write times out within its packet budget when the probe is pending`.
- Windows bench coverage on an ESP32-C3, a Super Mini ESP32-C6 and a XIAO ESP32-C6 included
  `selftest_usj` for raw USB echo and `selftest_usj_reenumerate` for ordered logger replay after
  reconnect, including when the host reopened late.

## Open questions

- Can a host discard lines it consumed shortly before detach? [#42](https://github.com/valthon/microzig/issues/42)
- Hosts beyond Windows and Linux, including macOS, remain untested.
- Can a line that starts while another context owns the writer avoid a busy-drop?
- After a host-side reset with no HAL hook (a replug of a self-powered board), endpoint setup can
  free the IN buffer without a host read. The hold then replays early, and one line can be
  retired and counted before the next drain. Without a send timeout, such a replug is not seen at
  all and the lines are lost unreported: [#82](https://github.com/valthon/microzig/issues/82).
