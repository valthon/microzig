# <Subsystem name>

Covers: <path/to/file.zig>, <path/to/dir/>

## Purpose

<What it does, for whom, and what it deliberately does not do. Three to five lines.>

## Code map

- `<path>:<symbol>`: <one line>

## Invariants

- <A rule a reviewer can check against the code.>

## Design tables

<For a state machine shared by foreground code and an ISR or the hardware (polled included): the
tables from DRIVER_DESIGN.md. For an interface: the consumer trace.
Leave this section out for code with neither.>

## Prior art

- `<path or doc>`: <what it solves, what this reuses, why this differs>

## Shared patterns

- [<doc>](<doc>.md): <how this subsystem uses it>

## Evidence

- <invariant>: protected by `<test name>` in `<path>`
- <hardware behavior>: validated on <board> by the `<self-test>` self-test

## Open questions

- <one line each, with an issue link where one exists>
