# RTT (SEGGER Real-Time Transfer)

Covers: modules/rtt/, port/raspberrypi/rp2xxx/src/cpus/hazard3.zig, port/espressif/esp/src/cpus/esp_riscv.zig, core/src/cpus/cortex_m.zig

## Purpose

A log and console channel that a debug probe reads straight out of target RAM while the CPU runs:
no UART, no USB stack on the target, and it keeps working while the target's own USB re-enumerates.
The target writes into ring buffers in a control block; the host finds the block, polls the
buffers' offsets over the debug port, and copies the bytes out. This doc covers the target side
(`modules/rtt`) and the contract with the host tools. It does not cover SEGGER SystemView, defmt
framing, or Espressif's `app_trace`, which is a different protocol.

## Code map

- `modules/rtt/src/rtt.zig:RTT(Config)`: one control block per instance, exported as the symbol
  `RttControlBlock`; `init`, `write`, `writer`, `read`, `reader`.
- `modules/rtt/src/rtt.zig:channel.Up` / `channel.Down`: the ring buffers (`write_available`,
  `available_space`, `read_available`, `bytes_available`).
- `modules/rtt/src/rtt.zig:Header.init`: writes the `"SEGGER RTT"` id last, behind a barrier.
- `modules/rtt/src/lock.zig:default`: the per-architecture lock chosen at compile time;
  `GenericLock`/`AnyLock` for a custom one, `empty` for none.
- `modules/rtt/src/memory_barrier.zig:resolve_memory_barrier`: the per-architecture barrier.
- CPU exports: `core/src/cpus/cortex_m.zig:rtt` (every Cortex-M port); this design adds
  `port/raspberrypi/rp2xxx/src/cpus/hazard3.zig:rtt` and
  `port/espressif/esp/src/cpus/esp_riscv.zig:rtt` (ESP32-C3, ESP32-C6 HP core), each wired by the
  port's `build.zig`/`build.zig.zon`. Applications use `microzig.cpu.rtt`.

## Invariants

- The id string `"SEGGER RTT"` appears in RAM only inside an initialised control block: it is
  stored reversed and copied in last, behind a barrier. `init` first clears the id's first byte,
  so a host never sees a valid id over descriptors that `init` is rewriting.
- Before `init` returns, `write` and `read` do nothing and return 0: they test a target-private
  flag, never the control block, which holds whatever RAM held at reset.
- Every target-side change to a ring buffer runs under `Config.exclusive_access`, and the lock
  excludes every other context on the same core that can call RTT, interrupt handlers included.
  `bytes_available` reads without the lock; its result is a snapshot.
- The target writes only `up.write_offset`, `down.read_offset` and, in `init`, the descriptors.
  It reads each host-owned offset (`up.read_offset`, `down.write_offset`) with one volatile load
  per call and uses that one value throughout the call.
- The control block lives in host-writable RAM, so the target never takes a channel's buffer
  address or size from it: it uses the comptime size and the address of its own buffer storage.
  Any offset loaded from the block (host-owned or its own) at or above that size means "no space"
  (up) or "no data" (down), never an index.
- The producer publishes data before the offset: copy, barrier, then store the new write offset.
  The consumer loads the write offset, barrier, copies, barrier, then stores the read offset.
- One byte always stays free: no write path stores a `write_offset` equal to `read_offset`, so
  equal offsets always mean empty.
- `flags` mode bits the target does not know (3) behave as `no_block_skip`.
- On the Cortex-M BASEPRI path (v7-M, v7E-M, v8-M Mainline) the lock masks only priorities
  numerically at or above `MAX_ISR_PRIORITY` (0x20): an interrupt with a higher urgency must not
  call RTT (SEGGER's rule for the same lock).
- A `block_if_full` write that runs with interrupts already masked (from an interrupt handler,
  inside a caller's critical section, or nested inside the RTT lock) spins with them masked until
  the host frees space; `block_if_full` up channels are for foreground callers only.
- The default lock is single-core. A target that calls RTT from two cores (RP2040, RP2350 in
  either architecture) supplies its own `exclusive_access`.
- Cortex-A/R has no default lock (the earlier one had invalid assembly and no target used it).
- On RISC-V the default lock needs `zicsr`; the barrier is base RV32I `fence`. Any other
  architecture is a compile error that names `Config.exclusive_access` /
  `Config.memory_barrier_fn`.

## Design tables

The shared state is the control block. The other party is the debug probe, which reads and writes
target RAM at any instant, between any two target instructions, with no interrupt to the target.

### Phases

| Phase | Host sees | Entered by | Left by | Owner |
| --- | --- | --- | --- | --- |
| `unset` | whatever RAM held; a stale block from before a warm reset is possible | reset | `init()` | target |
| `initialising` | id invalid (first byte cleared first); descriptors being written | `init()` | id written | target, under the lock |
| `live` | valid id, channel descriptors, buffers | id written | reset, or `init()` again (back to `initialising`) | shared, per the ownership table |

### Ownership (phase `live`)

| Field | Written by | Read by | Guard |
| --- | --- | --- | --- |
| `header.*`, channel `name`, `buffer`, `size` | target, in `init` only | host | written while the id is invalid; barrier before the id |
| `up.write_offset` | target | host | target: lock |
| `up.read_offset` | host | target | one volatile load per call, inside the lock; range-checked |
| `up` bytes from `read_offset` up to `write_offset` | target, before publishing | host | barrier before the `write_offset` store |
| `down.write_offset` | host | target | one volatile load per call, inside the lock; range-checked; barrier after the load |
| `down.read_offset` | target | host | target: lock; stored after the copy |
| `down` bytes from `read_offset` up to `write_offset` | host | target | the host writes data before its offset |
| `flags` | target in `init` (`flags = mode`, whole word) and `set_mode`; a host may write the mode bits | target | none; unknown mode bits behave as `no_block_skip` |
| lock save state (`lock.zig:default`) | the lock, with interrupts masked | the lock | outermost-only, see below |
| `initialised` flag | target, last step of `init` | `write`, `read` | target-private, not in the control block |

### Events × phases

| Event | `unset` | `initialising` | `live` | Cleared |
| --- | --- | --- | --- | --- |
| host scans RAM for the id | nothing, or a stale block | nothing (id invalid) | finds the block | n/a |
| host writes an offset of a stale block | harmless: `init` rewrites every offset | memory-safe; a host that cached the block's address may land a stale offset after `init` wrote it, and pass one burst of stale bytes (the host reads them on up, the application on down) | normal flow | by the next read of that channel |
| host advances `up.read_offset` | n/a | n/a | frees space at the target's next load | n/a |
| host writes into `down`, advances `down.write_offset` | n/a | n/a | data at the target's next `read` | by `read` |
| host writes `flags` | n/a | overwritten by `init` | mode change at the next call; 3 behaves as skip | n/a |
| host writes an offset at or above `size` | n/a | n/a | treated as full (up) or empty (down) | when the host writes a valid one |
| interrupt that calls RTT while foreground holds the lock | n/a (calls return 0) | held off by the lock | held off by the lock | at `unlock` |
| exception (fault, `ecall`) taken inside the lock whose handler calls RTT | n/a | nested lock; outermost unlock restores | nested lock; the interrupted call then stores its cached offset, so the two writes' bytes may be mixed or lost (up), or the same bytes delivered twice (down) | at the outermost `unlock` |
| debug halt inside the lock | n/a | harmless | harmless: offsets stay consistent | at resume |
| panic while the lock is held, panic handler logs through RTT | n/a | nested lock; data may interleave with the interrupted write | same; in `block_if_full` the handler may spin forever with no host | n/a |

### Entry points × phases

| Call | `unset` | `initialising` | `live` |
| --- | --- | --- | --- |
| `init` | run; sets the `initialised` flag inside the lock, before unlocking | n/a: only one context calls it | re-initialises under the lock: drops unread data |
| `write`, `writer` | return 0, drop data | an interrupt's call is held off by the lock | run, per channel mode |
| `read`, `reader` | return 0 | held off by the lock | `read` never blocks. `Reader.stream` returns 0 bytes when empty, which `std.Io.Reader` defines as "not end of stream", so `reader` calls that must fill (`take*`, `peek*`, `fill`) wait until the host sends data |

### Lock and nesting

`AnyLock.lock_fn` returns nothing, so the default lock keeps its save state in a global. Only the
outermost holder on a core saves and restores the interrupt state, counted by a depth field that
is changed only with interrupts already masked: an exception handler that calls RTT inside the
lock (interrupts stay masked across a trap) nests, and its unlock leaves the outer holder's state
alone. The depth count wraps every default lock (PRIMASK, BASEPRI, RISC-V `MIE`); it is correct
wherever the lock masks every context that calls RTT, which on the BASEPRI path holds under the
priority rule above.

### Timing budget

| Quantity | Value | Source | Used in |
| --- | --- | --- | --- |
| interrupts masked per `write` in `no_block_skip` / `no_block_trim` | one copy of at most the write length, bounded by the buffer size | `rtt.zig:channel.Up.write` | choose buffer and write sizes on targets with interrupt deadlines (radio) |
| interrupts masked per attempt in `block_if_full` | one copy; the lock is released between attempts, so interrupts run while it waits | `rtt.zig:channel.Up.write_blocking` | with no host attached the caller waits forever with interrupts enabled; an interrupt's write may land between two chunks of a foreground write |
| interrupts masked per `read` | one copy of at most the read length | `rtt.zig:channel.Down.read_available` | same as the first row |
| host polling interval | set by the host tool (OpenOCD `rtt polling_interval`, probe-rs) | tool docs | sizing the up buffer for the log rate |

### Spec rules

The implementation adds these host tests in `modules/rtt` (`zig build test`).

| Clause | Rule | Host test |
| --- | --- | --- |
| SEGGER RTT control block | 16-byte id, `MaxNumUpBuffers`, `MaxNumDownBuffers`, then the up and down descriptors (name, buffer, size, WrOff, RdOff, Flags) | `control block layout` |
| SEGGER RTT ring buffer | `WrOff == RdOff` means empty; the writer leaves one byte free, with `RdOff == 0` included, in every mode | `write never fills the last byte`, one per mode |
| SEGGER RTT ring buffer | only the producer writes `WrOff`, only the consumer writes `RdOff` | by inspection (ownership table) |
| SEGGER RTT flags | `Flags[1:0]` is the mode; `Flags[31:24]` is zero after `init` | `init writes flags` |
| this design | out-of-range offsets neither read nor write outside the buffer | `out-of-range host offset` |
| this design | a host-written `size` or `buffer` is ignored | `corrupted descriptor` |
| this design | mode bits 3 behave as `no_block_skip` | `unknown mode` |
| this design | `write`/`read` before `init` return 0 | `calls before init` |
| this design | nested lock restores at the outermost unlock only | `nested lock` |

## RISC-V lock and barrier

The lock saves and clears `mstatus.MIE` with one `csrrci` and sets `MIE` again at the outermost
unlock only if it was set before (`csrs` of the saved bit). `mstatus.MIE` is the global enable for
machine-mode interrupts while the hart runs in machine mode (The RISC-V Instruction Set Manual,
Volume II: Privileged Architecture, version 20211203, §3.1.6.1). MicroZig runs application code in machine mode on all three
targets: no startup path in `hazard3.zig` or `esp_riscv.zig` drops to a lower mode. This is what
`microzig.interrupt.enter_critical_section` already does on these CPUs
(`port/espressif/esp/src/cpus/esp_riscv.zig:interrupt.disable_interrupts`,
`modules/riscv32-common`). On the ESP32-C3/C6 it masks every CPU interrupt slot, RTOS and radio
included, for the copy only; the priority threshold is not touched.

None of the three cores documents an interrupt that `MIE` does not gate. Hazard3 takes an
interrupt only when "MSTATUS.MIE is set" and lists only the external, timer and soft interrupts
(RP2350 datasheet §3.8.4.2; the NMI of §3.2.1 is the Cortex-M33's). The ESP32-C3 and ESP32-C6
CPU chapters describe only the `MIE`-gated controller (ESP32-C3 TRM v1.4 §1.5; ESP32-C6 TRM v1.2
§1.6, §1.7). Both TRMs keep a GPIO "CPU non-maskable interrupt" enable bit
(`GPIO_PINn_INT_ENA` bit 14) while their revision histories delete the NMI map registers; RTT
assumes that bit stays clear.

The barrier is `fence` (all earlier memory and I/O accesses before all later ones). It orders the
buffer stores before the offset store, and the offset load before the buffer loads, for the hart.
That a debug module's system-bus access observes the hart's stores in that order is an inference,
not a sourced claim: none of the three cores documents a store buffer that `fence` does not
drain, and the bench run checks the data. As an `asm volatile` with a memory clobber, `fence` is
also a compiler barrier.

## Host side

The control block's address is the ELF symbol `RttControlBlock`. probe-rs reads it from the ELF
itself; with OpenOCD, pass it to `rtt setup <address> <size> "SEGGER RTT"`, then `rtt start` and
`rtt server start <port> 0`, and read the TCP port. OpenOCD's RTT needs background memory access,
"the target memory can be accessed by the debugger while the target is running"
([OpenOCD manual, General Commands](https://openocd.org/doc/html/General-Commands.html)). On these
RISC-V parts that path is the debug module's System Bus Access:

| Target | Background access | Source |
| --- | --- | --- |
| RP2350 (Hazard3) | SBA, "without halting either core … minimally intrusive debug techniques like Segger RTT" | RP2350 datasheet §3.5.3 |
| RP2350 caveat | an SBA transfer stalls while core 1 is in clock-gated sleep (`MSLEEP.DEEPSLEEP` + `wfi`) | RP2350 datasheet, erratum RP2350-E4 |
| ESP32-C3 | "Debugger direct system bus access (SBA) to memory and peripherals" | ESP32-C3 TRM v1.4, §1.2 |
| ESP32-C6 | "Debugger with a direct system bus access (SBA) to memory and peripherals" | ESP32-C6 TRM v1.2, §1.2 |

OpenOCD tries `progbuf` before `sysbus` unless told otherwise, and a program-buffer read needs the
hart halted, so an RTT session on RISC-V sets `riscv mem_access sysbus` first (an inference from
the manual's [`riscv mem_access`](https://openocd.org/doc/html/Architecture-and-Core-Commands.html)
entry, to be confirmed on the bench). Espressif's
[openocd-esp32](https://github.com/espressif/openocd-esp32) defaults to `sysbus progbuf`
(`tcl/target/esp_common.cfg`); Raspberry Pi's `rp2350-riscv.cfg` does not set it.
[probe-rs](https://github.com/probe-rs/probe-rs) uses SBA for RISC-V memory reads whenever the
debug module reports it (`probe-rs/src/architecture/riscv/communication_interface.rs`) and does
not halt the core for RTT.

## Prior art

- SEGGER [`RTT/SEGGER_RTT_ConfDefaults.h`](https://github.com/SEGGERMicro/RTT)
  (`SEGGER_RTT_LOCK` for `__riscv`): `csrr` then `csrci mstatus, 8` to save and clear `MIE`, and
  `csrs` of the saved bit to restore, with the state in a local of the calling function. This
  module does the same with one `csrrci`, and keeps the state in a global with a depth count
  because `AnyLock` has no return value. SEGGER's only word on multi-core is to define your own
  lock, which is this module's `Config.exclusive_access`. The reversed-id trick and the
  one-free-byte ring buffer are SEGGER's too; SEGGER also initialises lazily on every call, where
  this module drops calls made before `init`.
- Upstream MicroZig [PR #1143](https://github.com/ZigEmbeddedGroup/microzig/pull/1143): the same
  `csrrci`/`csrs` lock and `fence` barrier for Hazard3; this design ports those hunks and adds the
  ESP CPUs, the nesting depth, the ring-buffer fixes and host tests.
- `core/src/interrupt.zig:enter_critical_section`: the same save-and-restore of the global enable;
  the RTT module does not import MicroZig, so it carries its own copy.
- probe-rs and `rtt-target` (Rust): a host and target pair for the same control block.

## Shared patterns

- [interrupts.md](interrupts.md): critical sections and the ESP interrupt slots.
- [usb_serial_jtag_logger.md](usb_serial_jtag_logger.md): the ESP USB log that RTT complements.

## Evidence

- Ring-buffer, layout, flags, nesting and before-`init` rules: the host tests listed under Spec
  rules, in `modules/rtt` (`zig build test`). The nesting test drives the depth logic with an
  injected lock, since the CSR and PRIMASK code cannot run on the host.
- The id appears once: the example images contain the string `SEGGER RTT` only reversed (a
  strings search of each `rtt_log` ELF, recorded in the PR).
- RISC-V lock, barrier and SBA reads: the `rtt_log` example read through the probe on an ESP32-C3,
  an ESP32-C6 and an RP2350 in RISC-V mode (filled in with the board names once run).

## Open questions

- Logging from both RP2350 Hazard3 harts needs a lock built on the RP2xxx hardware spinlocks.
- On the ESP32-C3/C6 the probe and the USB Serial/JTAG console share one USB device; how probe
  attach and RTT polling interact with the console's re-enumeration (#42) is to be measured.
