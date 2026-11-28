# Zig RTT

An implementation of [Segger's RTT protocol](https://wiki.segger.com/RTT) in pure Zig.

## Installation

MicroZig includes RTT on Cortex-M and on RISC-V targets with a CPU export for RTT.
The RISC-V exports cover RP2350 Hazard3 and ESP32-C3/C6 (the C6 HP core).
Applications import it from the CPU namespace.

```zig
const microzig = @import("microzig");
const rtt = microzig.cpu.rtt;
```

## Configuration

Create one RTT instance per image, and do not link another RTT implementation (such as SEGGER's
`SEGGER_RTT.c`) into the same image: both define the `_SEGGER_RTT` symbol.

RTT is configured by creating the RTT "type" at `comptime` like so:
```zig
// rtt.RTT takes an rtt.Config
const rtt_instance = rtt.RTT(.{
    // A slice of rtt.channel.Config for target -> probe communication
    .up_channels = &.{
        .{ .name = "Terminal", .mode = .no_block_skip, .buffer_size = 128 },
        .{ .name = "Up2", .mode = .no_block_skip, .buffer_size = 256 },
    },
    // A slice of rtt.channel.Config for probe -> target communication
    .down_channels = &.{
        .{ .name = "Terminal", .mode = .block_if_full, .buffer_size = 512 },
        .{ .name = "Down2", .mode = .block_if_full, .buffer_size = 1024 },
    },
    // Optional override of lock/unlock functionality for thread safe RTT
    .exclusive_access = your_lock_struct,
    // Optional placement in specific linker section for a fixed address control block
    .linker_section = ".rtt_cb",
});
```

This mirrors the functionality presented in the original `SEGGER_RTT_Conf.h` file, except you
can specify a compile time configuration for _every_ up and down channel as opposed to just
up/down channel 0!

An empty `Config` uses one 1024-byte up channel in `.no_block_skip` mode and one
16-byte down channel. Every up and down channel needs a `buffer_size` of at least
two bytes. One byte is reserved to distinguish full from empty, leaving at least
one usable byte even if the probe switches the channel into blocking mode.

### Locking

The default lock saves the interrupt mask at the outermost entry and restores
it on the final exit. It protects calls on a single core. Supply
`Config.exclusive_access` if more than one core calls RTT.

On Cortex-M targets that use BASEPRI (Armv7-M, Armv7E-M and Armv8-M Mainline),
RTT callers in interrupt handlers must have priority values numerically at or
above `0x20`. Higher-urgency handlers must leave RTT to a lower-urgency context.

Use `.block_if_full` up channels only from foreground code with interrupts
enabled. A blocking write releases the RTT lock between attempts, but a caller
that already masked interrupts will keep them masked until the probe frees space.

### Custom Thread Safety

This package exposes a `GenericLock` function that creates a type given lock/unlock functions and a
type for "context" to pass to each function. This type has a method `any()`, that returns a type
erased `AnyLock` that can be passed to a `rtt.Config`. Users can utilize this API to specify their
own custom lock/unlock behavior for RTT to use if the default behavior isn't desired. Assigning
`null` to `.exclusive_access` disables thread safety entirely.

## Usage

Call channel operations on the `RTT(config)` namespace with a comptime channel
number. `Writer` and `Reader` are `std.Io` adapters. Use their `interface` field
for I/O. Their remaining fields are implementation details. When migrating from
an adapter channel field, use the corresponding function below.

- `init()` publishes the control block. Calling it again discards unread data in
  the rings. A later flush writes any bytes still buffered by a Writer to the
  new block, and bytes prefetched by a Reader stay readable.
  A Writer flush before the first `init` drops its bytes.
- `write(channel_number, bytes)` returns the number of bytes written. Skip mode drops
  a write that cannot fit in full, trim mode writes as much as fits, and block mode
  waits for room.
- `writer(channel_number, buf)` provides a `std.Io.Writer`. In skip and trim modes
  it consumes input even when the RTT ring drops bytes. In block mode it waits.
  Flush a buffered writer to publish pending output.
- `read(channel_number, bytes)` polls for down-channel input and returns the number
  of bytes read, which may be zero. Use it in a main loop that also has work to
  do while the probe is idle. This replaces the channel's `read_available`.
- `reader(channel_number, buf)` provides a `std.Io.Reader`. Its `stream` operation
  returns zero when the channel is empty. Calls that fill the reader's buffer, such
  as `take` and `peek`, wait for data, also before `init`: never call them from the
  context that is responsible for calling `init`.
- `bytes_available(channel_number)` reports how many bytes are in the down ring
  without consuming them. It returns zero before `init` and excludes bytes
  already prefetched by a Reader. The count can change before the next read.
- `mode(direction, channel_number)` reports the current mode, or `null` before
  `init`. Pass `.up` or `.down` as the direction.
- `set_mode(direction, channel_number, mode)` updates only the mode bits under
  the lock. Calls before `init` have no effect.

See the [RP2xxx `rtt-log` example](../../examples/raspberrypi/rp2xxx/src/rtt_log.zig)
and the [ESP32-C3/C6 `rtt_log` example](../../examples/espressif/esp/src/rtt_log.zig).
Both examples emit an `RTT tick <n>` line once a second. Each echo chunk has its own
`RTT echo` line, with input line breaks escaped.

## Attach a host

With the firmware running and a supported probe connected, pass the ELF to
probe-rs so it can locate the control block.

```sh
probe-rs attach --chip <chip> <elf>
```

For OpenOCD, get the address and size of the control block from the first two
columns of the ELF symbol listing. Prefix the hexadecimal values with `0x`.

```sh
nm -S <elf> | grep ' _SEGGER_RTT$'
```

The same object is also exported as `RttControlBlock`.

With OpenOCD configured for the board and the target running, select System Bus
Access on RISC-V before starting RTT. These commands expose channel 0 over TCP.

```text
riscv mem_access sysbus
rtt setup <_SEGGER_RTT address> <size> "SEGGER RTT"
rtt start
rtt server start <port> 0
```

Connect a TCP client to that port, for example `nc localhost <port>`.

Espressif's OpenOCD build (seen with v0.12.0-esp32-20260831) has no `rtt setup`/`rtt start` for
the ESP32-C3/C6, so use probe-rs there. probe-rs finds the block by the `_SEGGER_RTT` symbol; on
these chips (probe-rs 0.32) it does not scan RAM for it.

## TODO:
- Support for CPUs with caches (cache alignment + cache access considerations) to mirror the
  `SEGGER_RTT_CPU_CACHE_LINE_SIZE` and `SEGGER_RTT_UNCACHED_OFF` macros in original Segger source
- Support for virtual terminals supported by RTT viewer
- Support for ANSI terminal color escape codes supported by RTT viewer
- Compile time option for returning a `WriteError` from `Writer` when attempting to write a full RTT
  buffer
