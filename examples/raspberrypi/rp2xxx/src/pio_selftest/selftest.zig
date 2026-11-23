//! On-target PIO self-test, reported over USB CDC.
//!
//! Commands (one byte): `r` runs every test, `i` prints the board line,
//! `b` reboots into BOOTSEL, `q` reboots normally (into the firmware in flash).
//! `P`, `H` and `F` exercise the recovery paths: a panic, a hang that the
//! watchdog ends, and a hard fault. A panic and a fault reboot into BOOTSEL on
//! both chips. The hang ends in BOOTSEL only on RP2350, whose bootrom has a
//! one-shot BOOTSEL watchdog boot type (50DS §5.2.4.1); on RP2040 the watchdog
//! reset boots the firmware in flash.
//!
//! Output is one line per test, `TEST <name> PASS|FAIL|SKIP <detail>`, then
//! `SUMMARY pass=N fail=N skip=N board=<name>`. A test that does not return
//! within `hang_guard_us` is reported as `TEST <name> FAIL hung ...` by a timer
//! interrupt, which then reboots into BOOTSEL without a SUMMARY line.
//!
//! Every test is self-contained on the chip: a PIO program drives a pin and the
//! same or another state machine, or the CPU, reads it back through the pad input.
//! Only `free_pins` and, on PiZero, HDMI TMDS GPIO 32-39 are driven.
//! On Pico 2 W, hal.cyw43 alone also owns GPIO 23, 24, 25 and 29.
//! Reload its RAM image before repeating a run: the HAL has no CYW43 deinit.
//! GPIO 28-31 and 40-47 on PiZero retain their reset function and output disable.
//! Recovery without a button press: panics and faults reboot into BOOTSEL via
//! the ROM, the watchdog is armed for the BOOTSEL watchdog boot type on RP2350,
//! and a board whose USB is not configured 10 s after boot reboots into BOOTSEL.
const std = @import("std");
const microzig = @import("microzig");

const hal = microzig.hal;
const chip = hal.compatibility.chip;
const has_rp2350b = hal.compatibility.has_rp2350b;
const pio = hal.pio;
const gpio = hal.gpio;
const time = hal.time;
const usb = microzig.core.usb;

const Pio = pio.Pio;
const Sm = pio.StateMachine;

const has_cyw43 = @hasDecl(microzig.board, "has_cyw43") and microzig.board.has_cyw43;

pub const board_name = microzig.config.board_name orelse "unknown";

/// GPIOs that nothing outside the module is connected to.
/// XIAO RP2350 on the FRC Sensor Hub Mini: the carrier's XIAO footprint has
/// only the 14 castellated pads (D0–D10 = GPIO 26, 27, 28, 5, 6, 7, 0, 1, 2, 4,
/// 3), so the back pads are open: GPIO 9–12 (SPI1), 16/17 (I2C0) and 20/21
/// (UART1) per pico-sdk 2.1.1 boards/seeed_xiao_rp2350.h.
/// XIAO RP2040: it fits the same carrier footprint, so none of its pads may be
/// used. Its pads are D0–D10 = GPIO 26, 27, 28, 29, 6, 7, 0, 1, 2, 4, 3; the
/// module drives the RGB LED on 16, 17, 25 and the NeoPixel on 12 with its
/// supply switched by 11 (arduino-pico 5.4.2 variants/seeed_xiao_rp2040/
/// pins_arduino.h; pico-sdk boards/seeed_xiao_rp2040.h agrees on 0–4, 6, 7,
/// 11, 12, 25). GPIO 18–24 and 15 are named by neither source.
///
/// Pico 2 W uses the same RP2350 set, all bare header pins; GPIO 23, 24,
/// 25 and 29 are reserved for CYW43 (pico-sdk 2.1.1 boards/pico2_w.h).
///
/// The tests need pin(0), pin(1) and pin(2), pin(3) to be consecutive GPIOs.
const free_pins: [8]u6 = switch (chip) {
    .RP2350 => .{ 9, 10, 11, 12, 16, 17, 20, 21 },
    .RP2040 => .{ 18, 19, 20, 21, 22, 23, 24, 15 },
};
comptime {
    if (free_pins[1] != free_pins[0] + 1 or free_pins[3] != free_pins[2] + 1)
        @compileError("pin(0), pin(1) and pin(2), pin(3) must be consecutive GPIOs");
}
fn pin(i: usize) gpio.Pin {
    return gpio.num(free_pins[i]);
}
fn bit(i: usize) u32 {
    return @as(u32, 1) << @intCast(free_pins[i]);
}

const sys_hz: u32 = hal.clock_config.get_frequency(.clk_sys).?;
const block_count = if (chip == .RP2040) 2 else 3;
const pio0 = pio.num(0);
const pio1 = pio.num(1);

// ---------------------------------------------------------------- recovery

const watchdog_us = 3_000_000;
const usb_deadline_us = 10_000_000;

/// Reboot into the USB bootloader through the ROM.
pub fn reboot_to_bootsel() noreturn {
    microzig.cpu.interrupt.disable_interrupts();
    hal.rom.reset_to_usb_boot();
    while (true) {}
}

fn arm_watchdog() void {
    hal.watchdog.apply(.{ .duration_us = watchdog_us, .pause_during_debug = true });
    if (chip == .RP2350) {
        // 50DS §5.2.4 / §5.2.4.1: on a watchdog reset the bootrom reads
        // SCRATCH4 = 0xb007c0d3, SCRATCH5 = pc ^ -0xb007c0d3, SCRATCH6 = sp,
        // SCRATCH7 = pc; pc = 0xb007c0d3 with sp = 2 selects BOOTSEL.
        const wd = microzig.chip.peripherals.WATCHDOG;
        wd.SCRATCH2.raw = 0;
        wd.SCRATCH3.raw = 0;
        wd.SCRATCH5.raw = 0xb007c0d3 ^ 0x4ff83f2d;
        wd.SCRATCH6.raw = 2;
        wd.SCRATCH7.raw = 0xb007c0d3;
        wd.SCRATCH4.raw = 0xb007c0d3;
    }
}

fn feed() void {
    hal.watchdog.update(null);
}

pub fn reboot_normal() noreturn {
    microzig.cpu.interrupt.disable_interrupts();
    // A cleared SCRATCH4 makes the bootrom take the normal (flash) boot path.
    microzig.chip.peripherals.WATCHDOG.SCRATCH4.raw = 0;
    hal.watchdog.force();
    while (true) {}
}

pub const std_options = microzig.std_options(.{});

pub const panic = std.debug.FullPanic(struct {
    fn panic_fn(message: []const u8, _: ?usize) noreturn {
        if (usb_ready) {
            // Best effort: the watchdog still bounds this.
            emit_last("PANIC {s}", .{message});
        }
        reboot_to_bootsel();
    }
}.panic_fn);

fn fault_handler() callconv(.c) void {
    reboot_to_bootsel();
}

// ---------------------------------------------------------------- hang guard

/// Ordinary PIO tests take well under 100 ms and must return within this. It is
/// below `watchdog_us`, so a test stuck in an unbounded HAL wait is named
/// before the watchdog would end it anonymously.
const hang_guard_us = 1_000_000;
const guard_timer = hal.system_timer.num(0);
const guard_irq = if (chip == .RP2040) .TIMER_IRQ_0 else .TIMER0_IRQ_0;
var guarded_test: []const u8 = "";
var guarded_deadline: u64 = 0;
var guarded_timeout_us: u32 = hang_guard_us;

fn arm_hang_guard(name: []const u8, timeout_us: u32) void {
    guarded_test = name;
    guarded_timeout_us = timeout_us;
    guarded_deadline = now_us() + timeout_us;
    guard_timer.clear_interrupt(.alarm0);
    guard_timer.schedule_alarm(.alarm0, guard_timer.read_low() +% @min(timeout_us, hang_guard_us));
    guard_timer.set_interrupt_enabled(.alarm0, true);
    microzig.cpu.interrupt.enable(guard_irq);
    microzig.cpu.interrupt.enable_interrupts();
}

fn disarm_hang_guard() void {
    microzig.cpu.interrupt.disable_interrupts();
    guard_timer.stop_alarm(.alarm0);
    guard_timer.set_interrupt_enabled(.alarm0, false);
    guard_timer.clear_interrupt(.alarm0);
    microzig.cpu.interrupt.disable(guard_irq);
    microzig.cpu.interrupt.clear_pending(guard_irq);
}

/// Terminal: names the stuck test, then leaves for BOOTSEL like a panic does.
/// The test it interrupted never uses USB, so emitting from here is safe.
fn hang_guard_handler() callconv(.c) void {
    if (now_us() < guarded_deadline) {
        // Firmware upload, WiFi enable and scan may outlast the watchdog.
        // Feed only while the test's fixed deadline has not expired.
        feed();
        guard_timer.clear_interrupt(.alarm0);
        guard_timer.schedule_alarm(.alarm0, guard_timer.read_low() +% hang_guard_us);
        return;
    }
    emit_last("TEST {s} FAIL hung: no return within {} ms", .{ guarded_test, guarded_timeout_us / 1000 });
    reboot_to_bootsel();
}

// ---------------------------------------------------------------- interrupts

var line_hits: [3][2]u32 = @splat(@splat(0));
var flag_hits: [3][8]u32 = @splat(@splat(0));
var fifo_hits: [3][2]u32 = @splat(@splat(0));

fn vol(comptime T: type, p: *T) *volatile T {
    return @ptrCast(p);
}

fn PioIsr(comptime block: u2, comptime line: pio.InterruptLine) type {
    return struct {
        fn handler() callconv(.c) void {
            const p = pio.num(block);
            const regs = p.get_irq_regs(line);
            const status = regs.status.raw;
            const l = @backingInt(line);
            vol(u32, &line_hits[block][l]).* += 1;
            const flags: u8 = @truncate(status >> 8);
            for (0..8) |f| {
                if (flags & (@as(u8, 1) << @intCast(f)) != 0) vol(u32, &flag_hits[block][f]).* += 1;
            }
            p.clear_irq_flags(flags);
            if (status & 0xff != 0) {
                // FIFO sources stay asserted until the FIFO changes; count once and mask them.
                vol(u32, &fifo_hits[block][l]).* += 1;
                hal.hw.clear_alias(&regs.enable).write_raw(status & 0xff);
            }
        }
    };
}

pub const microzig_options: microzig.Options = .{
    .interrupts = switch (chip) {
        .RP2040 => .{
            .HardFault = .{ .c = fault_handler },
            .TIMER_IRQ_0 = .{ .c = hang_guard_handler },
            .PIO0_IRQ_0 = .{ .c = PioIsr(0, .irq0).handler },
            .PIO0_IRQ_1 = .{ .c = PioIsr(0, .irq1).handler },
            .PIO1_IRQ_0 = .{ .c = PioIsr(1, .irq0).handler },
            .PIO1_IRQ_1 = .{ .c = PioIsr(1, .irq1).handler },
        },
        .RP2350 => .{
            .HardFault = .{ .c = fault_handler },
            .MemManageFault = .{ .c = fault_handler },
            .BusFault = .{ .c = fault_handler },
            .UsageFault = .{ .c = fault_handler },
            .TIMER0_IRQ_0 = .{ .c = hang_guard_handler },
            .PIO0_IRQ_0 = .{ .c = PioIsr(0, .irq0).handler },
            .PIO0_IRQ_1 = .{ .c = PioIsr(0, .irq1).handler },
            .PIO1_IRQ_0 = .{ .c = PioIsr(1, .irq0).handler },
            .PIO1_IRQ_1 = .{ .c = PioIsr(1, .irq1).handler },
            .PIO2_IRQ_0 = .{ .c = PioIsr(2, .irq0).handler },
            .PIO2_IRQ_1 = .{ .c = PioIsr(2, .irq1).handler },
        },
    },
};

fn nvic(comptime block: u2, comptime line: pio.InterruptLine, on: bool) void {
    const irq = comptime pio.num(block).irq_number(line);
    if (on) microzig.cpu.interrupt.enable(irq) else microzig.cpu.interrupt.disable(irq);
}

fn nvic_all_off() void {
    inline for (0..block_count) |b| {
        nvic(b, .irq0, false);
        nvic(b, .irq1, false);
    }
}

// ---------------------------------------------------------------- USB

const USB_Device = hal.usb.Polled(.{});
const USB_Serial = usb.drivers.CDC.Runtime;
var usb_device: USB_Device = undefined;
var usb_ready = false;
var usb_controller: usb.DeviceController(.{
    .device_triple = .unspecified,
    .bcd_device = .v1_00,
    .serial = "PIOSELFTEST",
    .device_capabilities = USB_Device.device_capabilities,
}, &.{usb.Configuration(
    .{ .attributes = .{ .self_powered = false }, .max_current_ma = 100 },
    .{ .serial = usb.drivers.CDC{ .itf_notifi_str = "PIO selftest", .itf_data_str = "PIO selftest data" } },
)}) = .init;

fn serial() ?*USB_Serial {
    return if (usb_controller.drivers()) |d| &d.serial else null;
}

var line_buf: [256]u8 = undefined;

/// Write one CRLF-terminated line; gives up after 500 ms so a host that stops
/// reading cannot wedge the test (the watchdog would otherwise end it).
fn emit(comptime fmt: []const u8, args: anytype) void {
    const s = serial() orelse return;
    var tx = std.mem.print(&line_buf, fmt ++ "\r\n", args) catch line_buf[0..0];
    const start = now_us();
    while (tx.len > 0 and now_us() - start < 500_000) {
        tx = tx[s.write(tx)..];
        usb_device.poll(&usb_controller);
    }
    while (!s.flush() and now_us() - start < 500_000) usb_device.poll(&usb_controller);
    feed();
}

/// For the last line before a reboot: keep servicing USB for 100 ms so the
/// host collects it before the device disappears.
fn emit_last(comptime fmt: []const u8, args: anytype) void {
    if (serial() == null) return;
    emit(fmt, args);
    const start = now_us();
    while (now_us() - start < 100_000) usb_device.poll(&usb_controller);
}

fn now_us() u64 {
    return time.get_time_since_boot().to_us();
}

// ---------------------------------------------------------------- test plumbing

const Outcome = enum(u2) { PASS, FAIL, SKIP };
const Result = struct { outcome: Outcome, detail: []const u8 };
var detail_buf: [200]u8 = undefined;

fn result(outcome: Outcome, comptime fmt: []const u8, args: anytype) Result {
    return .{ .outcome = outcome, .detail = std.mem.print(&detail_buf, fmt, args) catch "detail too long" };
}
fn pass(comptime fmt: []const u8, args: anytype) Result {
    return result(.PASS, fmt, args);
}
fn fail(comptime fmt: []const u8, args: anytype) Result {
    return result(.FAIL, fmt, args);
}

fn insn(comptime src: []const u8) pio.Instruction {
    const program = comptime pio.assemble(".program i\n.pio_version " ++ (if (chip == .RP2040) "0" else "1") ++ "\n" ++ src, .{}).get_program_by_name("i");
    return @bitCast(program.instructions[0]);
}

fn read_rx(p: Pio, sm: Sm, timeout_us: u32) ?u32 {
    const start = now_us();
    while (p.sm_is_rx_fifo_empty(sm)) {
        if (now_us() - start > timeout_us) return null;
    }
    return p.sm_read(sm);
}

fn spin_us(us: u32) void {
    const start = now_us();
    while (now_us() - start < us) {}
}

/// Read X through the RX FIFO with the SM stopped. The pushed word is waited
/// for, as an exec'd push can lag the write (see interrupt_sources).
fn read_x(p: Pio, sm: Sm) !u32 {
    p.sm_exec(sm, insn("mov isr, x"));
    p.sm_exec(sm, insn("push noblock"));
    return read_rx(p, sm, 100) orelse error.NoWordFromX;
}

fn pio_reset_mask() hal.resets.Mask {
    var m = std.mem.zeroes(hal.resets.Mask);
    m.pio0 = true;
    m.pio1 = true;
    if (chip == .RP2350) m.pio2 = true;
    return m;
}

/// Put every PIO block, the HAL's bookkeeping and the free pins back to reset state.
fn reset_all() void {
    nvic_all_off();
    hal.resets.reset_block(pio_reset_mask());
    hal.resets.unreset_block_wait(pio_reset_mask());
    // A line a test left asserted is latched pending in the NVIC even while
    // disabled; with the blocks reset the lines are low, so drop it now or the
    // next test that enables the line takes one extra interrupt.
    inline for (0..block_count) |b| {
        microzig.cpu.interrupt.clear_pending(comptime pio.num(b).irq_number(.irq0));
        microzig.cpu.interrupt.clear_pending(comptime pio.num(b).irq_number(.irq1));
    }
    inline for (0..block_count) |b| {
        const p = pio.num(b);
        p.clear_instruction_memory();
        inline for (.{ Sm.sm0, Sm.sm1, Sm.sm2, Sm.sm3 }) |sm| p.unclaim(sm);
    }
    for (0..free_pins.len) |i| {
        const p = pin(i);
        p.set_function(.sio);
        p.set_direction(.in);
        p.put(0);
        p.set_pull(.up);
    }
    if (has_rp2350b) {
        for (32..40) |n| {
            const p = gpio.num(@intCast(n));
            p.set_direction(.in);
            p.set_function(.sio);
            p.put(0);
            p.set_pull(.up);
        }
    }
    line_hits = @splat(@splat(0));
    flag_hits = @splat(@splat(0));
    fifo_hits = @splat(@splat(0));
}

fn abort_dma(mask: u32) void {
    microzig.chip.peripherals.DMA.CHAN_ABORT.write_raw(mask);
    while (microzig.chip.peripherals.DMA.CHAN_ABORT.raw & mask != 0) {}
}

// ---------------------------------------------------------------- programs

const common_programs = blk: {
    @setEvalBranchQuota(100_000);
    break :blk pio.assemble(
        \\.program filler
        \\nop
        \\nop
        \\nop
        \\nop
        \\nop
        \\
        \\.program seq
        \\    set y, 3
        \\.wrap_target
        \\top:
        \\    mov isr, y
        \\    push block
        \\    jmp y-- top
        \\    set y, 5
        \\.wrap
        \\
        \\.program origin
        \\.origin 7
        \\.wrap_target
        \\    mov isr, ~null
        \\    push block
        \\.wrap
        \\
        \\.program word
        \\    .word 0xe02a
        \\    mov isr, x
        \\    push block
        \\hang:
        \\    jmp hang
        \\
        \\.program waitrel
        \\    wait 1 irq 0 rel
        \\    mov isr, ~null
        \\    push block
        \\hang:
        \\    jmp hang
        \\
        \\.program irqrel
        \\    irq set 0 rel
        \\hang:
        \\    jmp hang
        \\
        \\.program irqloop
        \\    set x, 4
        \\loop:
        \\    irq wait 0 rel
        \\    jmp x-- loop
        \\hang:
        \\    jmp hang
        \\
        \\.program invert
        \\.wrap_target
        \\    pull block
        \\    mov isr, ~osr
        \\    push block
        \\.wrap
        \\
        \\.program counter
        \\.wrap_target
        \\loop:
        \\    jmp x-- loop
        \\.wrap
        \\
        \\.program pullstall
        \\.wrap_target
        \\    pull block
        \\.wrap
        \\
        \\.program pushstall
        \\.wrap_target
        \\    push block
        \\.wrap
        \\
        \\.program idle
        \\hang:
        \\    jmp hang
        \\
        \\.program late6
        \\    nop [31]
        \\    irq set 6
        \\hang:
        \\    jmp hang
        \\
        \\.program latency
        \\.set 1
        \\    set pins, 0 [7]
        \\    set pins, 1
        \\    in pins, 1
        \\    in pins, 1
        \\    in pins, 1
        \\    in pins, 1
        \\    in pins, 1
        \\    in pins, 1
        \\    in pins, 1
        \\    in pins, 1
        \\    push block
        \\hang:
        \\    jmp hang
        \\
        \\.program cfg
        \\.clock_div 4
        \\.fifo tx
        \\.wrap_target
        \\loop:
        \\    jmp x-- loop
        \\.wrap
        \\
        \\.program loopback
        \\.set 1
        \\.wrap_target
        \\    pull block
        \\    out x, 1
        \\    jmp !x low
        \\    set pins, 1 [3]
        \\    jmp sample
        \\low:
        \\    set pins, 0 [3]
        \\sample:
        \\    in pins, 1
        \\    push block
        \\.wrap
    , .{});
};
fn common(comptime name: []const u8) pio.Program {
    return comptime common_programs.get_program_by_name(name);
}

/// 32 instructions: 16 × (`set x, b` ; `in x, 1`) shifting in 0xa5c3, MSB first.
const full_pattern: u16 = 0xa5c3;
const full_program = blk: {
    @setEvalBranchQuota(200_000);
    var src: []const u8 = ".program full\n";
    for (0..16) |i| {
        const b = (full_pattern >> (15 - i)) & 1;
        src = src ++ std.fmt.comptimePrint("set x, {}\nin x, 1\n", .{b});
    }
    break :blk pio.assemble(src, .{}).get_program_by_name("full");
};

// ---------------------------------------------------------------- tests: #1 loader and exec

fn t_offset_jumps_wrap() !Result {
    try pio0.claim_state_machine(.sm0);
    const filler_offset = try pio0.add_program(common("filler"));
    const offset = try pio0.sm_load_and_start_program(.sm0, common("seq"), .{});
    if (filler_offset != 0 or offset != 5) return fail("filler at {} seq at {}, want 0 and 5", .{ filler_offset, offset });
    pio0.sm_set_enabled(.sm0, true);
    const want = [_]u32{ 3, 2, 1, 0, 5, 4, 3, 2 };
    for (want, 0..) |w, i| {
        const got = read_rx(pio0, .sm0, 10_000) orelse return fail("word {} timed out, pc={}", .{ i, pio0.sm_get_pc(.sm0) });
        if (got != w) return fail("word {}: got {} want {}", .{ i, got, w });
    }
    const pc = pio0.sm_get_pc(.sm0);
    if (pc < 5 or pc > 8) return fail("pc {} outside 5..8", .{pc});
    return pass("offset 5, jumps and wrap relocated, pc {}", .{pc});
}

fn t_full_32() !Result {
    try pio0.claim_state_machine(.sm1);
    const offset = try pio0.sm_load_and_start_program(.sm1, full_program, .{
        .shift = .{ .autopush = true, .push_threshold = 16, .in_shiftdir = .left },
    });
    if (offset != 0) return fail("offset {}", .{offset});
    if (pio0.add_program(common("idle"))) |o| return fail("a 33rd instruction loaded at {}", .{o}) else |_| {}
    pio0.sm_set_enabled(.sm1, true);
    for (0..3) |i| {
        const got = read_rx(pio0, .sm1, 10_000) orelse return fail("word {} timed out", .{i});
        if (got != full_pattern) return fail("word {}: 0x{x} want 0x{x}", .{ i, got, full_pattern });
    }
    return pass("32 instructions ran and wrapped; 0x{x} x3; memory full", .{full_pattern});
}

fn t_origin() !Result {
    try pio0.claim_state_machine(.sm0);
    const offset = try pio0.sm_load_and_start_program(.sm0, common("origin"), .{});
    if (offset != 7) return fail("loaded at {} want 7", .{offset});
    pio0.sm_set_enabled(.sm0, true);
    const got = read_rx(pio0, .sm0, 10_000) orelse return fail("no push", .{});
    const pc = pio0.sm_get_pc(.sm0);
    if (got != 0xffffffff or pc < 7 or pc > 8) return fail("got 0x{x} pc {}", .{ got, pc });
    if (pio0.can_add_program_at_offset(common("origin"), 0)) return fail(".origin program accepted at 0", .{});
    return pass("loaded at 7, pc {}", .{pc});
}

fn t_word() !Result {
    try pio0.claim_state_machine(.sm0);
    _ = try pio0.sm_load_and_start_program(.sm0, common("word"), .{});
    pio0.sm_set_enabled(.sm0, true);
    const got = read_rx(pio0, .sm0, 10_000) orelse return fail("no push", .{});
    if (got != 10) return fail("x = {} want 10", .{got});
    return pass(".word 0xe02a executed as set x, 10", .{});
}

fn t_wait_irq_rel() !Result {
    try pio0.claim_sm_mask(0b0110);
    _ = try pio0.sm_load_and_start_program(.sm1, common("waitrel"), .{});
    pio0.sm_set_enabled(.sm1, true);
    pio0.force_irq_flags(0b0001);
    spin_us(200);
    if (!pio0.sm_is_rx_fifo_empty(.sm1)) return fail("SM1 woke on flag 0", .{});
    pio0.force_irq_flags(0b0010);
    _ = read_rx(pio0, .sm1, 10_000) orelse return fail("SM1 did not wake on flag 1", .{});
    if (pio0.irq_flags() & 0b0011 != 0b0001) return fail("flags 0x{x}: want flag 1 cleared by WAIT, flag 0 kept", .{pio0.irq_flags()});
    pio0.clear_irq_flags(0xff);
    _ = try pio0.sm_load_and_start_program(.sm2, common("irqrel"), .{});
    pio0.sm_set_enabled(.sm2, true);
    spin_us(50);
    if (pio0.irq_flags() != 0b0100) return fail("irq set 0 rel on SM2 set flags 0x{x}, want 0x4", .{pio0.irq_flags()});
    return pass("wait 1 irq 0 rel on SM1 waits on flag 1; irq set 0 rel on SM2 sets flag 2", .{});
}

fn t_exec_set_xy() !Result {
    try pio0.claim_state_machine(.sm0);
    _ = try pio0.sm_load_and_start_program(.sm0, common("idle"), .{
        .shift = .{ .autopull = true, .pull_threshold = 0 },
    });
    // Leave a stale word in OSR first: a PULL that does not replace it would show.
    pio0.sm_write(.sm0, 0x11111111);
    pio0.sm_exec(.sm0, insn("pull block"));
    pio0.sm_exec_set_x(.sm0, 0xdeadbeef);
    pio0.sm_exec_set_y(.sm0, 0x12345678);
    const x = try read_x(pio0, .sm0);
    pio0.sm_exec(.sm0, insn("mov isr, y"));
    pio0.sm_exec(.sm0, insn("push noblock"));
    const y = read_rx(pio0, .sm0, 100) orelse return fail("no word from Y", .{});
    if (x != 0xdeadbeef or y != 0x12345678) return fail("x 0x{x} y 0x{x}", .{ x, y });
    if (pio0.get_sm_regs(.sm0).shiftctrl.read().AUTOPULL != 1) return fail("AUTOPULL not restored", .{});
    // OSR was left empty: the next OUT autopulls the FIFO word.
    pio0.sm_write(.sm0, 0xcafef00d);
    pio0.sm_exec(.sm0, insn("out x, 32"));
    spin_us(10);
    if (pio0.sm_is_exec_stalled(.sm0)) return fail("OUT stalled after set_x", .{});
    const x2 = try read_x(pio0, .sm0);
    if (x2 != 0xcafef00d) return fail("OUT after set_x read 0x{x}", .{x2});
    return pass("x, y set with autopull on; next OUT pulled 0xcafef00d", .{});
}

// ---------------------------------------------------------------- tests: #4 runtime

fn t_irq_flags() !Result {
    pio0.force_irq_flags(0b1010_0101);
    const forced = pio0.irq_flags();
    pio0.clear_irq_flags(0b0000_0001);
    const after = pio0.irq_flags();
    pio0.clear_irq_flags(0xff);
    const cleared = pio0.irq_flags();
    if (forced != 0b1010_0101 or after != 0b1010_0100 or cleared != 0)
        return fail("forced 0x{x} after clear(1) 0x{x} after clear(ff) 0x{x}", .{ forced, after, cleared });
    return pass("force 0xa5, clear 0x01 -> 0xa4, clear all -> 0", .{});
}

fn t_system_irq_lines() !Result {
    var details: [block_count][2]u32 = undefined;
    inline for (0..block_count) |b| {
        const p = pio.num(b);
        try p.claim_sm_mask(0b0011);
        _ = try p.sm_load_and_start_program(.sm0, common("irqloop"), .{ .clkdiv = .from_float(100.0) });
        _ = try p.sm_load_and_start_program(.sm1, common("irqloop"), .{ .clkdiv = .from_float(100.0) });
        try p.set_interrupt_enabled(.irq0, .{ .flag = 0 }, true);
        try p.set_interrupt_enabled(.irq1, .{ .flag = 1 }, true);
        nvic(b, .irq0, true);
        nvic(b, .irq1, true);
        microzig.cpu.interrupt.enable_interrupts();
        p.set_sm_mask_enabled(0b0011, true);
        spin_us(5_000);
        p.set_sm_mask_enabled(0b0011, false);
        nvic(b, .irq0, false);
        nvic(b, .irq1, false);
        details[b] = .{ vol(u32, &line_hits[b][0]).*, vol(u32, &line_hits[b][1]).* };
        if (details[b][0] != 5 or details[b][1] != 5 or vol(u32, &flag_hits[b][0]).* != 5 or vol(u32, &flag_hits[b][1]).* != 5)
            return fail("PIO{}: irq0 {} irq1 {} (flag0 {} flag1 {}), want 5 each", .{ b, details[b][0], details[b][1], flag_hits[b][0], flag_hits[b][1] });
    }
    return pass("every PIO block (PIO0..PIO{}): irq0 ISR 5x for flag 0, irq1 ISR 5x for flag 1", .{block_count - 1});
}

fn t_interrupt_sources() !Result {
    try pio0.claim_state_machine(.sm2);
    _ = try pio0.sm_load_and_start_program(.sm2, common("idle"), .{});
    // INTF forces the line's status without touching the SM flag.
    try pio0.set_interrupt_forced(.irq0, .{ .flag = 2 }, true);
    const forced = try pio0.interrupt_status(.irq0, .{ .flag = 2 });
    const flags = pio0.irq_flags();
    try pio0.set_interrupt_forced(.irq0, .{ .flag = 2 }, false);
    const unforced = try pio0.interrupt_status(.irq0, .{ .flag = 2 });
    if (!forced or flags != 0 or unforced) return fail("INTF: forced {} flags 0x{x} unforced {}", .{ forced, flags, unforced });
    // A TX FIFO with room asserts tx_not_full; an RX FIFO with data asserts rx_not_empty.
    try pio0.set_interrupt_enabled(.irq1, .{ .tx_not_full = .sm2 }, true);
    const txnf = try pio0.interrupt_status(.irq1, .{ .tx_not_full = .sm2 });
    // The raw source stays asserted; disabling it must drop it from the line's status.
    try pio0.set_interrupt_enabled(.irq1, .{ .tx_not_full = .sm2 }, false);
    const txnf_off = try pio0.interrupt_status(.irq1, .{ .tx_not_full = .sm2 });
    try pio0.set_interrupt_enabled(.irq1, .{ .rx_not_empty = .sm2 }, true);
    const rx_before = try pio0.interrupt_status(.irq1, .{ .rx_not_empty = .sm2 });
    pio0.sm_exec(.sm2, insn("push noblock"));
    // The status lags the exec'd push: on an RP2040 at 125 MHz a read straight
    // after the write still sees it clear, and one 10 us later sees it set.
    const start = now_us();
    const rx_after = while (now_us() - start < 10) {
        if (try pio0.interrupt_status(.irq1, .{ .rx_not_empty = .sm2 })) break true;
    } else false;
    if (!txnf or txnf_off or rx_before or !rx_after)
        return fail("tx_not_full {} after disable {}; rx_not_empty before {} after {}", .{ txnf, txnf_off, rx_before, rx_after });
    nvic(0, .irq1, true);
    microzig.cpu.interrupt.enable_interrupts();
    spin_us(100);
    nvic(0, .irq1, false);
    const hits = vol(u32, &fifo_hits[0][1]).*;
    if (hits != 1) return fail("rx_not_empty ISR ran {} times", .{hits});
    // 40DS §2.3.2 / 50DS §3.2: PIO0_IRQ_0 is IRQ 7 / 15; each block adds two.
    const want0 = if (chip == .RP2040) 7 else 15;
    const n0 = @backingInt(pio0.irq_number(.irq0));
    const n3 = @backingInt(pio.num(block_count - 1).irq_number(.irq1));
    if (n0 != want0 or n3 != want0 + 2 * block_count - 1) return fail("irq numbers {} {}", .{ n0, n3 });
    return pass("INTF, tx_not_full on then off, rx_not_empty (ISR on irq1); irq_number {} and {}", .{ n0, n3 });
}

fn dma_roundtrip(p: Pio, sm: Sm) !?Result {
    try p.claim_state_machine(sm);
    _ = try p.sm_load_and_start_program(sm, common("invert"), .{});
    p.sm_set_enabled(sm, true);
    var src: [32]u32 = undefined;
    var dst: [32]u32 = @splat(0);
    for (&src, 0..) |*s, i| s.* = @as(u32, @intCast(i)) *% 0x01020304 +% 0x55aa +% @backingInt(p);
    const tx = hal.dma.claim_unused_channel() orelse return error.NoDmaChannel;
    defer tx.unclaim();
    const rx = hal.dma.claim_unused_channel() orelse return error.NoDmaChannel;
    defer rx.unclaim();
    try rx.setup_transfer(&dst, hal.dma.DMA_ReadTarget{
        .addr = @intFromPtr(p.sm_get_rx_fifo(sm)),
        .dreq = p.sm_dreq(sm, .rx),
    }, .{ .enable = true, .trigger = true });
    try tx.setup_transfer(hal.dma.DMA_WriteTarget{
        .addr = @intFromPtr(p.sm_get_tx_fifo(sm)),
        .dreq = p.sm_dreq(sm, .tx),
    }, &src, .{ .enable = true, .trigger = true });
    const start = now_us();
    while (tx.is_busy() or rx.is_busy()) {
        if (now_us() - start > 50_000) {
            abort_dma(@as(u32, tx.mask()) | rx.mask());
            return fail("PIO{} SM{}: DMA timed out", .{ @backingInt(p), @backingInt(sm) });
        }
    }
    for (src, dst, 0..) |s, d, i| if (d != ~s) return fail("PIO{} SM{} word {}: 0x{x} want 0x{x}", .{ @backingInt(p), @backingInt(sm), i, d, ~s });
    return null;
}

fn t_dma_dreq() !Result {
    if (try dma_roundtrip(pio0, .sm3)) |r| return r;
    if (chip == .RP2350) if (try dma_roundtrip(pio.num(2), .sm1)) |r| return r;
    // 40DS §2.5.3.1 / 50DS §12.6.4.1: PIOn TX0..3 then RX0..3, eight per block.
    const dreqs = .{ @backingInt(pio0.sm_dreq(.sm3, .tx)), @backingInt(pio1.sm_dreq(.sm0, .rx)), @backingInt(pio.num(block_count - 1).sm_dreq(.sm1, .rx)) };
    const want = .{ 3, 12, 8 * (block_count - 1) + 5 };
    if (dreqs[0] != want[0] or dreqs[1] != want[1] or dreqs[2] != want[2]) return fail("dreq numbers {} {} {}", dreqs);
    return pass("32 words through TX and RX by DMA on sm_dreq: PIO0 SM3{s}", .{if (chip == .RP2350) ", PIO2 SM1" else ""});
}

fn counter_setup(p: Pio, sm: Sm, clkdiv: pio.ClkDivOptions) !void {
    try p.claim_state_machine(sm);
    _ = try p.sm_load_and_start_program(sm, common("counter"), .{ .clkdiv = clkdiv });
}

// Dividers free-run, and SM_ENABLE alone neither stops nor restarts them
// (40DS §3.7 / 50DS §11.7, CTRL.CLKDIV_RESTART). With a divider period of T
// and SMs whose divider phases are spread a quarter of T apart, a window of
// 4.5 T between one enabling and one disabling CTRL write gives some SMs four
// ticks and others five. Only a divider restart in the enabling write itself
// makes the counts equal.
const phase_div_int = 60_000;
const phase_div: pio.ClkDivOptions = .{ .int = phase_div_int, .frac = 0 };
const phase_tick_us: u32 = @intCast(@as(u64, phase_div_int) * 1_000_000 / sys_hz);
const phase_window_us = phase_tick_us * 9 / 2;

/// Restart each divider in turn, a quarter period apart.
fn stagger(p: Pio, comptime sms: []const Sm) void {
    inline for (sms) |sm| {
        p.sm_clkdiv_restart(sm);
        spin_us(phase_tick_us / 4);
    }
}

/// Count ticks over `phase_window_us` between `start` and one disabling write.
fn phase_counts(p: Pio, comptime sms: []const Sm, comptime start: type) ![sms.len]u32 {
    var x: [sms.len]u32 = undefined;
    inline for (sms) |sm| p.sm_exec_set_x(sm, 0xffffffff);
    var mask: u4 = 0;
    inline for (sms) |sm| mask |= @as(u4, 1) << @backingInt(sm);
    const t0 = now_us();
    start.go(p, mask);
    while (now_us() - t0 < phase_window_us) {}
    p.set_sm_mask_enabled(mask, false);
    inline for (sms, 0..) |sm, i| x[i] = 0xffffffff - try read_x(p, sm);
    return x;
}

fn all_equal(x: anytype) bool {
    for (x) |v| if (v != x[0]) return false;
    return x[0] != 0;
}

const EnableOnly = struct {
    fn go(p: Pio, mask: u4) void {
        p.set_sm_mask_enabled(mask, true);
    }
};
const EnableInSync = struct {
    fn go(p: Pio, mask: u4) void {
        p.enable_sm_mask_in_sync(mask);
    }
};

fn t_enable_in_sync() !Result {
    const sms = [_]Sm{ .sm0, .sm1, .sm2, .sm3 };
    inline for (sms) |sm| try counter_setup(pio0, sm, phase_div);
    // Control: staggered dividers, one enable-only write: the counts differ.
    // (A no-op sm_clkdiv_restart leaves the dividers in step and fails here.)
    stagger(pio0, &sms);
    const control = try phase_counts(pio0, &sms, EnableOnly);
    if (all_equal(control)) return fail("control: staggered dividers gave equal counts {any}", .{control});
    // clkdiv_restart_sm_mask puts them back in step for an enable-only write.
    pio0.clkdiv_restart_sm_mask(0b1111);
    const restarted = try phase_counts(pio0, &sms, EnableOnly);
    if (!all_equal(restarted)) return fail("after clkdiv_restart_sm_mask: counts {any}", .{restarted});
    stagger(pio0, &sms);
    const synced = try phase_counts(pio0, &sms, EnableInSync);
    if (!all_equal(synced)) return fail("enable_sm_mask_in_sync on staggered dividers: counts {any}", .{synced});
    return pass("div {}: staggered {any}; clkdiv_restart {any}; enable_in_sync {any}", .{ phase_div_int, control, restarted, synced });
}

fn t_clkdiv_rate() !Result {
    const target_hz = 700_000;
    const div = try pio.clkdiv_from_hz(sys_hz, target_hz);
    // The divider itself: sys_hz * 256 / (int * 256 + frac) within one
    // fractional step of the target, i.e. |fixed * target - sys_hz * 256| <= target.
    const fixed: u64 = @as(u64, div.int) * 256 + div.frac;
    const scaled = fixed * target_hz;
    const ideal = @as(u64, sys_hz) * 256;
    if ((if (scaled > ideal) scaled - ideal else ideal - scaled) > target_hz)
        return fail("div {}+{}/256 is more than 1/256 from {} Hz", .{ div.int, div.frac, target_hz });
    try counter_setup(pio0, .sm0, div);
    pio0.sm_exec_set_x(.sm0, 0xffffffff);
    const t0 = now_us();
    pio0.sm_set_enabled(.sm0, true);
    while (now_us() - t0 < 50_000) {}
    pio0.sm_set_enabled(.sm0, false);
    const t1 = now_us();
    const counts: u64 = 0xffffffff - try read_x(pio0, .sm0);
    // Measured against the requested rate, not the divider's own: a dropped
    // fraction (214 for 214+73/256 at 150 MHz) is 1335 ppm off.
    const want = @as(u64, target_hz) * (t1 - t0) / 1_000_000;
    const err_ppm = (if (counts > want) counts - want else want - counts) * 1_000_000 / want;
    if (err_ppm > 300) return fail("div {}+{}/256: {} counts in {} us, want {} ({} ppm)", .{ div.int, div.frac, counts, t1 - t0, want, err_ppm });
    return pass("div {}+{}/256: {} counts in {} us, want {} at {} Hz ({} ppm)", .{ div.int, div.frac, counts, t1 - t0, want, target_hz, err_ppm });
}

fn t_default_config() !Result {
    try pio0.claim_state_machine(.sm1);
    _ = try pio0.sm_load_and_start_program(.sm1, common("cfg"), .{});
    // .fifo tx joins the FIFOs: eight TX words fit.
    for (0..8) |i| {
        if (pio0.sm_is_tx_fifo_full(.sm1)) return fail("TX full after {} words", .{i});
        pio0.sm_write(.sm1, @intCast(i));
    }
    if (!pio0.sm_is_tx_fifo_full(.sm1) or pio0.sm_fifo_level(.sm1, .tx) != 8) return fail("TX level {}", .{pio0.sm_fifo_level(.sm1, .tx)});
    pio0.sm_drain_tx_fifo(.sm1);
    if (!pio0.sm_is_tx_fifo_empty(.sm1)) return fail("drain left {} words", .{pio0.sm_fifo_level(.sm1, .tx)});
    // .clock_div 4: the counter runs at sys/4.
    pio0.sm_exec_set_x(.sm1, 0xffffffff);
    const t0 = now_us();
    pio0.sm_set_enabled(.sm1, true);
    while (now_us() - t0 < 10_000) {}
    pio0.sm_set_enabled(.sm1, false);
    const t1 = now_us();
    // A joined TX FIFO leaves no RX FIFO to read X through; unjoining keeps X.
    pio0.sm_set_shift_options(.sm1, .{});
    const counts: u64 = 0xffffffff - try read_x(pio0, .sm1);
    const want = @as(u64, sys_hz / 4) * (t1 - t0) / 1_000_000;
    const err_ppm = (if (counts > want) counts - want else want - counts) * 1_000_000 / want;
    if (err_ppm > 2_000) return fail(".clock_div 4: {} counts want {}", .{ counts, want });
    return pass(".fifo tx: 8-deep TX, drained; .clock_div 4: {} counts want {}", .{ counts, want });
}

fn t_fdebug() !Result {
    try pio0.claim_sm_mask(0b1111);
    _ = try pio0.sm_load_and_start_program(.sm0, common("pullstall"), .{});
    _ = try pio0.sm_load_and_start_program(.sm1, common("pushstall"), .{});
    _ = try pio0.sm_load_and_start_program(.sm2, common("idle"), .{});
    _ = try pio0.sm_load_and_start_program(.sm3, common("idle"), .{});
    pio0.set_sm_mask_enabled(0b0011, true);
    for (0..5) |i| pio0.sm_write(.sm2, @intCast(i));
    _ = pio0.sm_read(.sm3);
    spin_us(50);
    pio0.set_sm_mask_enabled(0b0011, false);
    const want = [4]pio.Fdebug{
        .{ .rx_stall = false, .rx_under = false, .tx_over = false, .tx_stall = true },
        .{ .rx_stall = true, .rx_under = false, .tx_over = false, .tx_stall = false },
        .{ .rx_stall = false, .rx_under = false, .tx_over = true, .tx_stall = false },
        .{ .rx_stall = false, .rx_under = true, .tx_over = false, .tx_stall = false },
    };
    for ([_]Sm{ .sm0, .sm1, .sm2, .sm3 }, want, 0..) |sm, w, i| {
        const got = pio0.sm_fdebug(sm);
        if (!std.meta.eql(got, w)) return fail("SM{} {any} want {any}", .{ i, got, w });
    }
    const raw = pio0.get_regs().FDEBUG.raw;
    pio0.sm_clear_debug(.sm1);
    const after = pio0.get_regs().FDEBUG.raw;
    if (raw != 0x01040802 or after != 0x01040800) return fail("FDEBUG 0x{x} after clearing SM1 0x{x}", .{ raw, after });
    return pass("each SM shows only its own flag; FDEBUG 0x{x}; SM1 clear -> 0x{x}", .{ raw, after });
}

const late6_div = 10_000;
/// `nop [31]` takes 32 ticks before `irq set 6` runs.
const late6_us: u32 = @intCast(@as(u64, 32) * late6_div * 1_000_000 / sys_hz);

fn t_pc_exec_stalled() !Result {
    try pio0.claim_state_machine(.sm0);
    _ = try pio0.sm_load_and_start_program(.sm0, common("idle"), .{});
    pio0.sm_exec_jmp(.sm0, 13);
    const pc_stopped = pio0.sm_get_pc(.sm0);
    if (pc_stopped != 13) return fail("pc {} after exec jmp 13", .{pc_stopped});
    pio0.sm_exec_jmp(.sm0, 0);
    pio0.sm_set_enabled(.sm0, true);
    pio0.sm_exec(.sm0, insn("wait 1 irq 7"));
    spin_us(20);
    const stalled = pio0.sm_is_exec_stalled(.sm0);
    pio0.force_irq_flags(0x80);
    spin_us(20);
    const released = !pio0.sm_is_exec_stalled(.sm0);
    const flags = pio0.irq_flags();
    if (!stalled or !released or flags != 0) return fail("stalled {} released {} flags 0x{x}", .{ stalled, released, flags });
    // SM1 sets flag 6 32 to 33 divider ticks after it is enabled (the first
    // tick comes up to one period after the enable); the blocking exec must
    // not return before 31 ticks have passed.
    try pio0.claim_state_machine(.sm1);
    _ = try pio0.sm_load_and_start_program(.sm1, common("late6"), .{ .clkdiv = .{ .int = late6_div, .frac = 0 } });
    const t0 = now_us();
    pio0.sm_set_enabled(.sm1, true);
    pio0.sm_exec_wait_blocking(.sm0, insn("wait 1 irq 6"));
    const waited = now_us() - t0;
    if (waited < late6_us / 32 * 31 or pio0.irq_flags() != 0)
        return fail("exec_wait_blocking returned after {} us (flag 6 set at {} us), flags 0x{x}", .{ waited, late6_us, pio0.irq_flags() });
    return pass("pc 13 after exec jmp; EXEC_STALLED set on wait, cleared by flag 7; blocking exec returned after {} us", .{waited});
}

fn t_pins_masks() !Result {
    try pio0.claim_state_machine(.sm0);
    _ = try pio0.sm_load_and_start_program(.sm0, common("idle"), .{});
    for (0..4) |i| pio0.gpio_init(pin(i));
    const regs = pio0.get_sm_regs(.sm0);
    const pinctrl = regs.pinctrl.raw;
    const execctrl = regs.execctrl.raw;
    const four = bit(0) | bit(1) | bit(2) | bit(3);
    pio0.sm_set_pins_with_mask(.sm0, 0, four);
    pio0.sm_set_pindirs_with_mask(.sm0, bit(0) | bit(1), four);
    const oe = pio0.dbg_padoe() & four;
    pio0.sm_set_pins_with_mask(.sm0, bit(0), bit(0) | bit(1));
    spin_us(5);
    const in1 = gpio.num(free_pins[0]).read() == 1 and gpio.num(free_pins[1]).read() == 0;
    pio0.sm_set_pins_with_mask(.sm0, bit(1), bit(1));
    spin_us(5);
    const in2 = gpio.num(free_pins[0]).read() == 1 and gpio.num(free_pins[1]).read() == 1;
    const out = pio0.dbg_padout() & four;
    if (oe != bit(0) | bit(1) or !in1 or !in2 or out != bit(0) | bit(1))
        return fail("padoe 0x{x} padout 0x{x} readback {} {}", .{ oe, out, in1, in2 });
    if (regs.pinctrl.raw != pinctrl or regs.execctrl.raw != execctrl) return fail("pinctrl/execctrl not restored", .{});
    // PiZero sweeps only HDMI TMDS GPIO 32-39 (schematic sheet 1).
    // The XIAO sweep retains its original range and GPIO functions.
    const sweep_pio = if (has_rp2350b) pio.num(2) else pio0;
    const sweep_pin = if (has_rp2350b) gpio.num(32) else pin(0);
    const sweep_mask: u32 = if (has_rp2350b) 0xff << 16 else 0xff << @intCast(free_pins[0]);
    if (has_rp2350b) try sweep_pio.set_gpio_base(.gpio16);
    try sweep_pio.sm_set_consecutive_pindirs(.sm0, sweep_pin, 8, .out);
    const oe8 = sweep_pio.dbg_padoe() & sweep_mask;
    try sweep_pio.sm_set_consecutive_pindirs(.sm0, sweep_pin, 8, .in);
    const oe0 = sweep_pio.dbg_padoe() & sweep_mask;
    if (oe8 != sweep_mask or oe0 != 0) return fail("consecutive pindirs: out 0x{x} in 0x{x}", .{ oe8, oe0 });
    const eight = (@as(u32, 0xff) << @intCast(free_pins[0]));
    // sm_set_pin sets `count` consecutive GPIOs from its base: pin(2) and the
    // GPIO after it, and nothing else in the 8-pin window.
    try pio0.sm_set_pin(.sm0, pin(2), 2, 1);
    const set_two = pio0.dbg_padout() & eight;
    const want_two = bit(0) | bit(1) | (@as(u32, 0b11) << @intCast(free_pins[2]));
    if (set_two != want_two) return fail("sm_set_pin: padout 0x{x} want 0x{x}", .{ set_two, want_two });
    return pass("mask writes touch only masked pins, read back on the pads; 8-pin pindirs", .{});
}

fn t_claims_remove() !Result {
    try pio1.claim_sm_mask(0b0011);
    if (try pio1.claim_unused_state_machine() != .sm2) return fail("claim_unused did not return sm2", .{});
    if (pio1.claim_state_machine(.sm1)) |_| return fail("double claim accepted", .{}) else |_| {}
    pio1.unclaim(.sm1);
    if (pio1.is_claimed(.sm1) or !pio1.is_claimed(.sm2)) return fail("is_claimed wrong after unclaim", .{});
    const a = try pio1.add_program(common("seq"));
    const b = try pio1.add_program(common("filler"));
    try pio1.remove_program(common("seq"), a);
    if (pio1.remove_program(common("seq"), a)) |_| return fail("second remove accepted", .{}) else |_| {}
    const a2 = try pio1.add_program(common("word"));
    if (a != 0 or b != 5 or a2 != 0) return fail("offsets seq {} filler {} word-after-remove {}", .{ a, b, a2 });
    // The reloaded memory runs the new program.
    try pio1.sm_init(.sm0, a2, .{ .exec = .{ .wrap = a2 + 3, .wrap_target = a2 + 3 } });
    pio1.sm_set_enabled(.sm0, true);
    const got = read_rx(pio1, .sm0, 10_000) orelse return fail("reloaded program did not push", .{});
    if (got != 10) return fail("reloaded program pushed {}", .{got});
    return pass("claims, unclaim, remove and reload at offset 0 run", .{});
}

fn latency_ones(bypass: bool) !u32 {
    reset_all();
    try pio0.claim_state_machine(.sm0);
    pio0.gpio_init(pin(0));
    _ = try pio0.sm_load_and_start_program(.sm0, common("latency"), .{
        .pin_mappings = .{ .set = .single(pin(0)), .in_base = pin(0) },
        .shift = .{ .in_shiftdir = .left },
    });
    try pio0.sm_set_consecutive_pindirs(.sm0, pin(0), 1, .out);
    if (bypass) try pio0.set_input_sync_bypass(pin(0));
    pio0.sm_set_enabled(.sm0, true);
    const v = read_rx(pio0, .sm0, 10_000) orelse return error.NoSample;
    return @popCount(v & 0xff);
}

fn t_sync_bypass() !Result {
    const synced = try latency_ones(false);
    const bypassed = try latency_ones(true);
    const reg = pio0.get_regs().INPUT_SYNC_BYPASS.raw;
    pio0.set_input_sync_bypass_mask(bit(0), false);
    const reg_off = pio0.get_regs().INPUT_SYNC_BYPASS.raw;
    if (reg != bit(0) or reg_off != 0) return fail("INPUT_SYNC_BYPASS 0x{x} then 0x{x}", .{ reg, reg_off });
    if (bypassed != synced + 2) return fail("ones in 8 samples: synced {} bypassed {}, want +2", .{ synced, bypassed });
    return pass("pad seen 2 cycles earlier with bypass ({} vs {} of 8 samples)", .{ bypassed, synced });
}

fn t_pad_loopback() !Result {
    // SM0 drives pin 0 and reads it back through the pad; the delay after each
    // `set` covers the 2-cycle input synchroniser (input_sync_bypass measures it).
    try pio0.claim_state_machine(.sm0);
    pio0.gpio_init(pin(0));
    _ = try pio0.sm_load_and_start_program(.sm0, common("loopback"), .{
        .pin_mappings = .{ .set = .single(pin(0)), .in_base = pin(0) },
        .shift = .{ .in_shiftdir = .left },
    });
    try pio0.sm_set_consecutive_pindirs(.sm0, pin(0), 1, .out);
    pio0.sm_set_enabled(.sm0, true);
    for ([_]u32{ 1, 0, 1, 1, 0 }) |v| {
        pio0.sm_write(.sm0, v);
        const got = read_rx(pio0, .sm0, 10_000) orelse return fail("no sample", .{});
        spin_us(2);
        const sio = gpio.num(free_pins[0]).read();
        if (got & 1 != v or sio != v) return fail("drove {} read {} (sio {})", .{ v, got & 1, sio });
    }
    return pass("SM drove 1,0,1,1,0 and read each back through the pad (and SIO)", .{});
}

fn t_cfginfo() !Result {
    var raw: [3]u32 = undefined;
    inline for (0..block_count) |b| {
        const p = pio.num(b);
        const c = p.dbg_cfginfo();
        raw[b] = p.get_regs().DBG_CFGINFO.raw;
        // FIFO depth and SM count are both 4, so a decoder that swaps them
        // passes here; runtime.zig's host test decodes distinct field values.
        if (c.fifo_depth != 4 or c.sm_count != 4 or c.instruction_count != 32)
            return fail("PIO{}: {any}", .{ b, c });
        // 50DS §11.7 DBG_CFGINFO: IMEM_SIZE 21:16, SM_COUNT 11:8, FIFO_DEPTH 5:0.
        if (raw[b] & 0x003f_0f3f != 0x0020_0404) return fail("PIO{} DBG_CFGINFO 0x{x}", .{ b, raw[b] });
        if (raw[b] >> 28 != @as(u32, if (chip == .RP2040) 0 else 1)) return fail("PIO{} VERSION {}", .{ b, raw[b] >> 28 });
    }
    return pass("fifo 4, 4 SMs, 32 instructions; DBG_CFGINFO 0x{x}", .{raw[0]});
}

// ---------------------------------------------------------------- tests: RP2350 (#3, #5)

const v1 = if (chip == .RP2350) blk: {
    @setEvalBranchQuota(200_000);
    break :blk pio.assemble(
        \\.program flags47
        \\.pio_version 1
        \\    irq set 4
        \\    irq set 5
        \\    irq set 6
        \\    irq set 7
        \\hang:
        \\    jmp hang
        \\
        \\.program status_this
        \\.pio_version 1
        \\.mov_status irq set 2
        \\.wrap_target
        \\    mov x, status
        \\    mov isr, x
        \\    push block
        \\.wrap
        \\
        \\.program status_prev
        \\.pio_version 1
        \\.mov_status irq prev set 3
        \\.wrap_target
        \\    mov x, status
        \\    mov isr, x
        \\    push block
        \\.wrap
        \\
        \\.program low_high
        \\.pio_version 1
        \\.set 1
        \\    wait 1 gpio 21
        \\    set pins, 0 [3]
        \\    in pins, 1
        \\    push block
        \\    wait 0 gpio 21
        \\    set pins, 1 [3]
        \\    in pins, 1
        \\    push block
        \\hang:
        \\    jmp hang
        \\
        \\.program putter
        \\.pio_version 1
        \\.fifo txput
        \\    set x, 5
        \\    mov isr, x
        \\    mov rxfifo[0], isr
        \\    set y, 3
        \\    mov isr, ~null
        \\    mov rxfifo[y], isr
        \\hang:
        \\    jmp hang
        \\
        \\.program get_y
        \\.pio_version 1
        \\.fifo txget
        \\.out 2
        \\    set y, 2
        \\.wrap_target
        \\    mov osr, rxfifo[y]
        \\    out pins, 2
        \\.wrap
        \\
        \\.program get_1
        \\.pio_version 1
        \\.fifo txget
        \\.out 2
        \\.wrap_target
        \\    mov osr, rxfifo[1]
        \\    out pins, 2
        \\.wrap
        \\
        \\.program ring0
        \\.pio_version 1
        \\    irq set 0
        \\    wait 1 irq 3
        \\    mov isr, ~null
        \\    push block
        \\    irq set 4
        \\hang:
        \\    jmp hang
        \\
        \\.program ring1
        \\.pio_version 1
        \\    wait 1 irq prev 0
        \\    irq next set 1
        \\    mov isr, ~null
        \\    push block
        \\hang:
        \\    jmp hang
        \\
        \\.program ring2
        \\.pio_version 1
        \\    wait 1 irq 1
        \\    irq next set 3
        \\    wait 1 irq next 4
        \\    mov isr, ~null
        \\    push block
        \\    irq prev set 5
        \\hang:
        \\    jmp hang
        \\
        \\.program jmppin
        \\.pio_version 1
        \\    wait 1 jmppin
        \\    mov isr, ~null
        \\    push block
        \\    wait 1 jmppin + 1
        \\    mov isr, null
        \\    push block
        \\hang:
        \\    jmp hang
        \\
        \\.program prevnext
        \\.pio_version 1
        \\.in 1 left
        \\.out 2 right
        \\.fifo putget
        \\    irq next wait 2
        \\    irq prev clear 3
        \\    in pins, 32
        \\    mov rxfifo[3], isr
        \\    mov osr, rxfifo[3]
        \\    out pins, 2
        \\hang:
        \\    jmp hang
        \\
        \\.program movpindirs
        \\.pio_version 1
        \\.out 2
        \\    mov pindirs, x
        \\hang:
        \\    jmp hang
    , .{});
} else undefined;
fn v1p(comptime name: []const u8) pio.Program {
    return comptime v1.get_program_by_name(name);
}

fn t_flags_4_7_isr() !Result {
    try pio1.claim_state_machine(.sm0);
    _ = try pio1.sm_load_and_start_program(.sm0, v1p("flags47"), .{});
    try pio1.set_interrupt_enabled(.irq0, .{ .flag = 4 }, true);
    try pio1.set_interrupt_enabled(.irq0, .{ .flag = 5 }, true);
    try pio1.set_interrupt_enabled(.irq1, .{ .flag = 6 }, true);
    try pio1.set_interrupt_enabled(.irq1, .{ .flag = 7 }, true);
    nvic(1, .irq0, true);
    nvic(1, .irq1, true);
    microzig.cpu.interrupt.enable_interrupts();
    pio1.sm_set_enabled(.sm0, true);
    spin_us(200);
    nvic(1, .irq0, false);
    nvic(1, .irq1, false);
    const f = vol([8]u32, &flag_hits[1]).*;
    if (f[4] != 1 or f[5] != 1 or f[6] != 1 or f[7] != 1 or pio1.irq_flags() != 0)
        return fail("flag ISR counts 4..7 = {} {} {} {}, flags left 0x{x}", .{ f[4], f[5], f[6], f[7], pio1.irq_flags() });
    return pass("flags 4,5 on irq0 and 6,7 on irq1 each ran the ISR once (lines {} {})", .{ line_hits[1][0], line_hits[1][1] });
}

fn status_word(p: Pio, sm: Sm) ?u32 {
    // The SM keeps pushing; drop what was queued before the change.
    var last: ?u32 = null;
    for (0..6) |_| last = read_rx(p, sm, 1_000) orelse return null;
    return last;
}

fn t_status_irq() !Result {
    try pio0.claim_state_machine(.sm0);
    try pio1.claim_state_machine(.sm0);
    _ = try pio0.sm_load_and_start_program(.sm0, v1p("status_this"), .{});
    _ = try pio1.sm_load_and_start_program(.sm0, v1p("status_prev"), .{});
    pio0.enable_in_sync(.{ .pio0 = 1, .pio1 = 1 });
    // PIO0's flags 2 and 3 one at a time: each status must follow its own flag only.
    var got: [3][2]u32 = undefined;
    for ([_]u8{ 0, 1 << 2, 1 << 3 }, 0..) |flags, i| {
        pio0.clear_irq_flags(0xff);
        pio0.force_irq_flags(flags);
        got[i] = .{
            status_word(pio0, .sm0) orelse return fail("no status push", .{}),
            status_word(pio1, .sm0) orelse return fail("no prev status push", .{}),
        };
    }
    const want = [3][2]u32{ .{ 0, 0 }, .{ 0xffffffff, 0 }, .{ 0, 0xffffffff } };
    if (!std.meta.eql(got, want))
        return fail("this/prev with no flag {x}/{x}, flag 2 {x}/{x}, flag 3 {x}/{x}", .{ got[0][0], got[0][1], got[1][0], got[1][1], got[2][0], got[2][1] });
    return pass("mov x, status follows own flag 2 alone, and PIO0's flag 3 alone from PIO1 (prev)", .{});
}

fn t_gpiobase16() !Result {
    const p = pio.num(2);
    try p.set_gpio_base(.gpio16);
    if (p.get_gpio_base() != 16) return fail("GPIOBASE reads {}", .{p.get_gpio_base()});
    try p.claim_state_machine(.sm0);
    const out = gpio.num(20);
    const trigger = gpio.num(21);
    p.gpio_init(out);
    trigger.set_function(.sio);
    trigger.put(0);
    trigger.set_direction(.out);
    _ = try p.sm_load_and_start_program(.sm0, v1p("low_high"), .{
        .pin_mappings = .{ .set = .single(out), .in_base = out },
        .shift = .{ .in_shiftdir = .left },
    });
    try p.sm_set_consecutive_pindirs(.sm0, out, 1, .out);
    const pinctrl = p.get_sm_regs(.sm0).pinctrl.read();
    p.sm_set_enabled(.sm0, true);
    spin_us(200);
    if (!p.sm_is_rx_fifo_empty(.sm0)) return fail("WAIT GPIO 21 passed with GPIO 21 low", .{});
    // GPIO 20 has a pull-up (reset_all): only PIO driving it reads 0.
    trigger.put(1);
    const low = read_rx(p, .sm0, 10_000) orelse return fail("WAIT 1 GPIO 21 never passed (fixup?)", .{});
    spin_us(2);
    const sio_low = out.read();
    trigger.put(0);
    const high = read_rx(p, .sm0, 10_000) orelse return fail("WAIT 0 GPIO 21 never passed", .{});
    spin_us(2);
    const sio_high = out.read();
    if (low & 1 != 0 or sio_low != 0 or high & 1 != 1 or sio_high != 1 or pinctrl.SET_BASE != 4)
        return fail("in {} then {}, sio {} then {}, SET_BASE {}; want 0, 1", .{ low & 1, high & 1, sio_low, sio_high, pinctrl.SET_BASE });
    if (p.set_gpio_base(.gpio0)) |_| return fail("base change accepted with memory in use", .{}) else |_| {}
    return pass("PIO2 base 16: GPIO 20 is PIO pin 4, driven 0 then 1 against its pull-up and read back; WAIT GPIO 21 fixed up", .{});
}

fn t_claim_for_gpio_range() !Result {
    // PIO0 at base 16 cannot reach GPIO 2: the claim must move it to base 0.
    try pio0.set_gpio_base(.gpio16);
    const c = try Pio.claim_sm_and_add_program_for_gpio_range(v1p("low_high"), 2, 2);
    if (c.pio != pio0 or pio0.get_gpio_base() != 0) return fail("claim went to PIO{} with PIO0 base {}, want PIO0 moved to base 0", .{ @backingInt(c.pio), pio0.get_gpio_base() });
    if (!c.pio.is_claimed(c.sm)) return fail("returned SM not claimed", .{});
    if (c.pio.can_add_program_at_offset(v1p("low_high"), c.offset)) return fail("program memory not reserved", .{});
    // With every SM of PIO0 claimed the next claim must go elsewhere.
    try pio0.claim_sm_mask(~(@as(u4, 1) << @backingInt(c.sm)));
    const d = try Pio.claim_sm_and_add_program_for_gpio_range(v1p("low_high"), 2, 2);
    if (d.pio == pio0) return fail("claimed a fifth PIO0 SM", .{});
    return pass("PIO0 base 16 -> 0 for GPIO 2-3: SM{} at {}, then PIO{} SM{} at {}", .{ @backingInt(c.sm), c.offset, @backingInt(d.pio), @backingInt(d.sm), d.offset });
}

fn t_rx_putget() !Result {
    try pio0.claim_sm_mask(0b0111);
    _ = try pio0.sm_load_and_start_program(.sm0, v1p("putter"), .{});
    pio0.sm_set_enabled(.sm0, true);
    spin_us(20);
    const e0 = try pio0.sm_rxfifo_get(.sm0, 0);
    const e3 = try pio0.sm_rxfifo_get(.sm0, 3);
    if (e0 != 5 or e3 != 0xffffffff) return fail("PUT entries 0x{x} 0x{x}", .{ e0, e3 });
    if (pio0.sm_rxfifo_put(.sm0, 0, 1)) |_| return fail("system write accepted in PUT mode", .{}) else |_| {}
    for (0..4) |i| pio0.gpio_init(pin(i));
    _ = try pio0.sm_load_and_start_program(.sm1, v1p("get_y"), .{ .pin_mappings = .{ .out = .{ .low = pin(0), .high = pin(1) } } });
    _ = try pio0.sm_load_and_start_program(.sm2, v1p("get_1"), .{ .pin_mappings = .{ .out = .{ .low = pin(2), .high = pin(3) } } });
    try pio0.sm_set_consecutive_pindirs(.sm1, pin(0), 2, .out);
    try pio0.sm_set_consecutive_pindirs(.sm2, pin(2), 2, .out);
    pio0.set_sm_mask_enabled(0b0110, true);
    for ([_]u32{ 1, 2, 3, 0 }) |v| {
        try pio0.sm_rxfifo_put(.sm1, 2, v);
        try pio0.sm_rxfifo_put(.sm2, 1, 3 - v);
        spin_us(5);
        const a = gpio.num(free_pins[0]).read() | @as(u32, gpio.num(free_pins[1]).read()) << 1;
        const b = gpio.num(free_pins[2]).read() | @as(u32, gpio.num(free_pins[3]).read()) << 1;
        if (a != v or b != 3 - v) return fail("put {} / {}: pins read {} / {}", .{ v, 3 - v, a, b });
    }
    return pass("mov rxfifo[0]/[y] read by CPU; CPU puts read by mov osr, rxfifo[y]/[1] onto pads", .{});
}

fn t_cross_pio_ring() !Result {
    inline for (0..3) |b| try pio.num(b).claim_state_machine(.sm0);
    _ = try pio.num(0).sm_load_and_start_program(.sm0, v1p("ring0"), .{});
    _ = try pio.num(1).sm_load_and_start_program(.sm0, v1p("ring1"), .{});
    _ = try pio.num(2).sm_load_and_start_program(.sm0, v1p("ring2"), .{});
    pio0.enable_in_sync(.{ .pio0 = 1, .pio1 = 1, .pio2 = 1 });
    inline for (0..3) |b| {
        _ = read_rx(pio.num(b), .sm0, 10_000) orelse return fail("PIO{} did not finish (flags {x} {x} {x})", .{ b, pio.num(0).irq_flags(), pio.num(1).irq_flags(), pio.num(2).irq_flags() });
    }
    const f0 = pio.num(0).irq_flags();
    const f1 = pio.num(1).irq_flags();
    const f2 = pio.num(2).irq_flags();
    if (f0 != 0 or f1 != 0x20 or f2 != 0) return fail("flags left {x} {x} {x}, want 0 20 0", .{ f0, f1, f2 });
    // Cross-block disable from PIO0 stops PIO1 and PIO2 SM0, leaving PIO0's.
    pio.num(0).sm_set_enabled(.sm1, true);
    pio.num(0).disable(.{ .pio1 = 1, .pio2 = 1 });
    const e0 = pio.num(0).get_regs().CTRL.raw & 0xf;
    const e1 = pio.num(1).get_regs().CTRL.raw & 0xf;
    const e2 = pio.num(2).get_regs().CTRL.raw & 0xf;
    if (e0 != 0b0011 or e1 != 0 or e2 != 0) return fail("after cross disable: enables {b} {b} {b}", .{ e0, e1, e2 });
    return pass("irq set/next/prev and wait irq prev/next across PIO0-1-2; cross disable", .{});
}

/// SM1 of every block counts over `phase_window_us` between `start` and one
/// cross-block disabling write from PIO1.
fn cross_phase_counts(comptime start: type) ![3]u32 {
    var x: [3]u32 = undefined;
    inline for (0..3) |b| pio.num(b).sm_exec_set_x(.sm1, 0xffffffff);
    const t0 = now_us();
    start.go();
    while (now_us() - t0 < phase_window_us) {}
    pio1.disable(.{ .pio0 = 2, .pio1 = 2, .pio2 = 2 });
    inline for (0..3) |b| x[b] = 0xffffffff - try read_x(pio.num(b), .sm1);
    return x;
}

fn cross_stagger() void {
    inline for (0..3) |b| {
        pio.num(b).sm_clkdiv_restart(.sm1);
        spin_us(phase_tick_us / 3);
    }
}

/// Separate per-block writes, a few cycles apart: the control.
const SeparateEnables = struct {
    fn go() void {
        inline for (0..3) |b| pio.num(b).sm_set_enabled(.sm1, true);
    }
};
/// Cross-block clkdiv_restart from PIO1, then the separate enables half a
/// divider period later. The restarted dividers tick together every period, so
/// the enables, a few cycles apart, never straddle a tick and the counts must
/// match. Enabling straight after the restart could straddle the first tick.
const CrossRestartThenSeparateEnables = struct {
    fn go() void {
        pio1.clkdiv_restart(.{ .pio0 = 2, .pio1 = 2, .pio2 = 2 });
        spin_us(phase_tick_us / 2);
        SeparateEnables.go();
    }
};
const CrossEnableInSync = struct {
    fn go() void {
        pio1.enable_in_sync(.{ .pio0 = 2, .pio1 = 2, .pio2 = 2 });
    }
};

fn t_cross_sync_counters() !Result {
    inline for (0..3) |b| try counter_setup(pio.num(b), .sm1, phase_div);
    // Control: staggered dividers, separate enables: the counts differ.
    cross_stagger();
    const control = try cross_phase_counts(SeparateEnables);
    if (all_equal(control)) return fail("control: staggered dividers gave equal counts {any}", .{control});
    // Cross-block clkdiv_restart from PIO1 puts all three back in step.
    const restarted = try cross_phase_counts(CrossRestartThenSeparateEnables);
    if (!all_equal(restarted)) return fail("after cross clkdiv_restart: counts {any}", .{restarted});
    cross_stagger();
    const synced = try cross_phase_counts(CrossEnableInSync);
    if (!all_equal(synced)) return fail("enable_in_sync on staggered dividers: counts {any}", .{synced});
    // clkdiv_restart across blocks leaves every enable bit as it was.
    pio0.sm_set_enabled(.sm1, true);
    pio1.clkdiv_restart(.{ .pio0 = 2, .pio2 = 2 });
    const en = .{ pio.num(0).get_regs().CTRL.raw & 0xf, pio.num(1).get_regs().CTRL.raw & 0xf, pio.num(2).get_regs().CTRL.raw & 0xf };
    if (en[0] != 2 or en[1] != 0 or en[2] != 0) return fail("clkdiv_restart changed enables {b} {b} {b}", .{ en[0], en[1], en[2] });
    return pass("from PIO1 over 3 blocks: staggered {any}; clkdiv_restart {any}; enable_in_sync {any}", .{ control, restarted, synced });
}

fn t_wait_jmppin() !Result {
    try pio0.claim_state_machine(.sm0);
    const a = gpio.num(free_pins[0]);
    const b = gpio.num(free_pins[0] + 1);
    for ([_]gpio.Pin{ a, b }) |p| {
        p.set_function(.sio);
        p.put(0);
        p.set_direction(.out);
    }
    _ = try pio0.sm_load_and_start_program(.sm0, v1p("jmppin"), .{ .exec = .{ .jmp_pin = a } });
    pio0.sm_set_enabled(.sm0, true);
    spin_us(100);
    if (!pio0.sm_is_rx_fifo_empty(.sm0)) return fail("passed with jmppin low", .{});
    a.put(1);
    const first = read_rx(pio0, .sm0, 10_000) orelse return fail("wait 1 jmppin did not pass", .{});
    spin_us(100);
    if (!pio0.sm_is_rx_fifo_empty(.sm0)) return fail("jmppin + 1 passed while low", .{});
    b.put(1);
    const second = read_rx(pio0, .sm0, 10_000) orelse return fail("wait 1 jmppin + 1 did not pass", .{});
    if (first != 0xffffffff or second != 0) return fail("pushed {x} {x}", .{ first, second });
    return pass("wait jmppin on GPIO {} and jmppin + 1 on GPIO {}", .{ free_pins[0], free_pins[0] + 1 });
}

fn t_mov_pindirs() !Result {
    try pio0.claim_state_machine(.sm0);
    const lo = pin(4);
    const hi = pin(5);
    pio0.gpio_init(lo);
    pio0.gpio_init(hi);
    _ = try pio0.sm_load_and_start_program(.sm0, v1p("movpindirs"), .{ .pin_mappings = .{ .out = .{ .low = lo, .high = hi } } });
    const both = bit(4) | bit(5);
    pio0.sm_exec_set_x(.sm0, 0b10);
    pio0.sm_set_enabled(.sm0, true);
    spin_us(10);
    const oe1 = pio0.dbg_padoe() & both;
    pio0.sm_set_enabled(.sm0, false);
    pio0.sm_exec_set_x(.sm0, 0b01);
    pio0.sm_exec(.sm0, insn("mov pindirs, x"));
    const oe2 = pio0.dbg_padoe() & both;
    if (oe1 != bit(5) or oe2 != bit(4)) return fail("PADOE 0x{x} then 0x{x}", .{ oe1, oe2 });
    return pass("mov pindirs, x set OE from X over the OUT pins", .{});
}

fn t_irq_prevnext_putget_in() !Result {
    const pio2 = pio.num(2);
    // pin(0) and pin(0)+1 high: `.in 1` must mask every IN bit but IN_BASE.
    for (0..2) |i| {
        const g = gpio.num(free_pins[0] + @as(u6, @intCast(i)));
        g.put(1);
        g.set_direction(.out);
    }
    pio0.force_irq_flags(1 << 3);
    try pio1.claim_state_machine(.sm0);
    pio1.gpio_init(pin(2));
    pio1.gpio_init(pin(3));
    _ = try pio1.sm_load_and_start_program(.sm0, v1p("prevnext"), .{ .pin_mappings = .{
        .in_base = pin(0),
        .out = .{ .low = pin(2), .high = pin(3) },
    } });
    try pio1.sm_set_consecutive_pindirs(.sm0, pin(2), 2, .out);
    // FJOIN_RX_PUT and FJOIN_RX_GET together: the SM owns the RX storage and the
    // processor has no access (SHIFTCTRL field description, RP2350 regs/pio.h).
    if (pio1.sm_rxfifo_get(.sm0, 3)) |_| return fail("system read accepted in putget mode", .{}) else |_| {}
    pio1.sm_set_enabled(.sm0, true);
    spin_us(50);
    const waiting = .{ pio2.irq_flags(), pio0.irq_flags(), pio1.irq_flags(), pio1.sm_get_pc(.sm0) };
    if (waiting[0] != 1 << 2 or waiting[1] != 1 << 3 or waiting[2] != 0)
        return fail("irq next wait 2: flags PIO2 {x} PIO0 {x} PIO1 {x}, pc {}", waiting);
    pio2.clear_irq_flags(1 << 2);
    spin_us(50);
    if (pio0.irq_flags() != 0) return fail("irq prev clear 3 left PIO0 flags {x}", .{pio0.irq_flags()});
    // The sample went IN -> rxfifo[3] -> OSR -> OUT onto pin(2), pin(3): 0b01.
    // pin(2) has a pull-up (reset_all), so its 1 alone does not show that PIO1
    // drives it: PIO1's own output enable and level must say so too.
    const out = gpio.num(free_pins[2]).read() | @as(u32, gpio.num(free_pins[3]).read()) << 1;
    const both = bit(2) | bit(3);
    const oe = pio1.dbg_padoe() & both;
    const level = pio1.dbg_padout() & both;
    if (out != 0b01 or oe != both or level != bit(2))
        return fail("in pins, 32 under .in 1, via rxfifo[3]: pads 0b{b:0>2}, PIO1 padoe 0x{x} padout 0x{x}", .{ out, oe, level });
    return pass("irq next wait / irq prev clear across blocks; .in 1 masks IN; .fifo putget SM-only", .{});
}

// RP2350B tests use only HDMI TMDS GPIO 32-39, never SD/USB/control/PSRAM.
// Masks and debug registers use PIO-relative bits (50DS §11.5.7).
fn t_high_drive() !Result {
    try pio0.set_gpio_base(.gpio16);
    try pio0.claim_state_machine(.sm0);
    const offset = try pio0.add_program(common("idle"));
    for (32..40) |n| {
        const g = gpio.num(@intCast(n));
        pio0.gpio_init(g);
        try pio0.sm_init(.sm0, offset, .{
            .pin_mappings = .{ .set = .single(g), .in_base = g },
            .shift = .{ .in_shiftdir = .left },
        });
        try pio0.sm_set_consecutive_pindirs(.sm0, g, 1, .out);
        inline for (.{ 0, 1 }) |level| {
            pio0.sm_exec(.sm0, insn(if (level == 0) "set pins, 0" else "set pins, 1"));
            spin_us(5);
            pio0.sm_exec(.sm0, insn("mov isr, null"));
            pio0.sm_exec(.sm0, insn("in pins, 1"));
            pio0.sm_exec(.sm0, insn("push block"));
            const sample = read_rx(pio0, .sm0, 1_000) orelse return fail("GPIO {} no sample", .{n});
            if (sample != level or g.read() != level)
                return fail("GPIO {} drive {}: PIO {} SIO {}", .{ n, level, sample, g.read() });
        }
        try pio0.sm_set_consecutive_pindirs(.sm0, g, 1, .in);
    }
    return pass("GPIO 32-39 each driven 0 then 1, read through PIO IN and SIO", .{});
}

fn t_high_wait_gpio() !Result {
    const program = comptime pio.assemble(
        \\.program high_wait
        \\.pio_version 1
        \\wait 1 gpio 35
        \\mov isr, ~null
        \\push block
        \\wait 0 gpio 35
        \\mov isr, null
        \\push block
        \\hang:
        \\jmp hang
    , .{}).get_program_by_name("high_wait");
    const g = gpio.num(35);
    g.put(0);
    g.set_direction(.out);
    try pio0.set_gpio_base(.gpio16);
    try pio0.claim_state_machine(.sm0);
    _ = try pio0.sm_load_and_start_program(.sm0, program, .{});
    pio0.sm_set_enabled(.sm0, true);
    spin_us(100);
    if (!pio0.sm_is_rx_fifo_empty(.sm0)) return fail("WAIT 1 GPIO 35 passed while low", .{});
    g.put(1);
    const high = read_rx(pio0, .sm0, 10_000) orelse return fail("WAIT 1 GPIO 35 stuck", .{});
    spin_us(100);
    if (!pio0.sm_is_rx_fifo_empty(.sm0)) return fail("WAIT 0 GPIO 35 passed while high", .{});
    g.put(0);
    const low = read_rx(pio0, .sm0, 10_000) orelse return fail("WAIT 0 GPIO 35 stuck", .{});
    if (high != 0xffffffff or low != 0) return fail("WAIT markers {x} {x}", .{ high, low });
    return pass("loader fixes both polarities of absolute WAIT GPIO 35 to PIO pin 19", .{});
}

fn t_high_jmp_pin() !Result {
    const program = comptime pio.assemble(
        \\.program high_jmp
        \\.pio_version 1
        \\set x, 0
        \\jmp pin high
        \\jmp sample
        \\high:
        \\set x, 1
        \\sample:
        \\mov isr, x
        \\push block
        \\hang:
        \\jmp hang
    , .{}).get_program_by_name("high_jmp");
    try pio0.set_gpio_base(.gpio16);
    try pio0.claim_state_machine(.sm0);
    const offset = try pio0.add_program(program);
    const g = gpio.num(35);
    g.set_direction(.out);
    for ([_]u1{ 0, 1, 0 }) |level| {
        g.put(level);
        spin_us(5);
        try pio0.sm_init(.sm0, offset, .{ .exec = .{ .jmp_pin = g } });
        pio0.sm_set_enabled(.sm0, true);
        const got = read_rx(pio0, .sm0, 10_000) orelse return fail("JMP PIN no sample", .{});
        pio0.sm_set_enabled(.sm0, false);
        if (got != level) return fail("JMP GPIO 35 at {} gave {}", .{ level, got });
    }
    return pass("JMP PIN branches on GPIO 35 at 0, 1, 0", .{});
}

fn high_latency_ones(bypass: bool) !u32 {
    reset_all();
    try pio0.set_gpio_base(.gpio16);
    try pio0.claim_state_machine(.sm0);
    const g = gpio.num(34);
    pio0.gpio_init(g);
    _ = try pio0.sm_load_and_start_program(.sm0, common("latency"), .{
        .pin_mappings = .{ .set = .single(g), .in_base = g },
        .shift = .{ .in_shiftdir = .left },
    });
    try pio0.sm_set_consecutive_pindirs(.sm0, g, 1, .out);
    if (bypass) try pio0.set_input_sync_bypass(g);
    pio0.sm_set_enabled(.sm0, true);
    const v = read_rx(pio0, .sm0, 10_000) orelse return error.NoSample;
    return @popCount(v & 0xff);
}

fn t_high_sync_bypass() !Result {
    const synced = try high_latency_ones(false);
    const bypassed = try high_latency_ones(true);
    const mask: u32 = 1 << 18; // GPIO 34 minus GPIOBASE 16.
    const on = pio0.get_regs().INPUT_SYNC_BYPASS.raw;
    pio0.set_input_sync_bypass_mask(mask, false);
    const off = pio0.get_regs().INPUT_SYNC_BYPASS.raw;
    if (on != mask or off != 0 or bypassed != synced + 2)
        return fail("GPIO 34 bypass bits {x}->{x}, samples {}->{}", .{ on, off, synced, bypassed });
    return pass("GPIO 34 bypass sees the pad two cycles earlier ({} vs {}); mask clears bit 18", .{ bypassed, synced });
}

fn t_high_masks() !Result {
    try pio0.set_gpio_base(.gpio16);
    try pio0.claim_state_machine(.sm0);
    _ = try pio0.sm_load_and_start_program(.sm0, common("idle"), .{});
    const regs = pio0.get_sm_regs(.sm0);
    const pinctrl = regs.pinctrl.raw;
    const execctrl = regs.execctrl.raw;
    const a: u32 = 1 << 20; // GPIO 36.
    const b: u32 = 1 << 21; // GPIO 37.
    const both = a | b;
    pio0.gpio_init(gpio.num(36));
    pio0.gpio_init(gpio.num(37));
    pio0.sm_set_pins_with_mask(.sm0, 0, both);
    pio0.sm_set_pindirs_with_mask(.sm0, both, both);
    for ([_]u32{ a, b, 0, both }) |value| {
        pio0.sm_set_pins_with_mask(.sm0, value, both);
        spin_us(5);
        const pads = @as(u32, gpio.num(36).read()) << 20 | @as(u32, gpio.num(37).read()) << 21;
        if (pads != value or pio0.dbg_padout() & both != value or pio0.dbg_padoe() & both != both)
            return fail("high mask {x}: pads {x}, OUT {x}, OE {x}", .{ value, pads, pio0.dbg_padout(), pio0.dbg_padoe() });
    }
    // A partial write must leave the other output and direction untouched.
    pio0.sm_set_pins_with_mask(.sm0, 0, a);
    pio0.sm_set_pindirs_with_mask(.sm0, 0, a);
    spin_us(5);
    if (pio0.dbg_padout() & both != b or pio0.dbg_padoe() & both != b or gpio.num(36).read() != 1 or gpio.num(37).read() != 1)
        return fail("partial high masks changed neighbour or failed to release pulled-up GPIO 36", .{});
    if (regs.pinctrl.raw != pinctrl or regs.execctrl.raw != execctrl) return fail("high masks changed SM config", .{});
    return pass("relative mask bits 20/21 drive GPIO 36/37 low/high, preserve neighbour and release OE", .{});
}

fn t_high_claim_range() !Result {
    const program = common("idle");
    const c = try Pio.claim_sm_and_add_program_for_gpio_range(program, 32, 8);
    if (c.pio != pio0 or c.pio.get_gpio_base() != 16 or !c.pio.is_claimed(c.sm) or c.pio.can_add_program_at_offset(program, c.offset))
        return fail("high range claim: PIO{} base {} SM{} offset {}", .{ @backingInt(c.pio), c.pio.get_gpio_base(), @backingInt(c.sm), c.offset });
    // Exercise the returned SM and reserved program at the selected base.
    const g = gpio.num(39);
    c.pio.gpio_init(g);
    try c.pio.sm_init(c.sm, c.offset, .{});
    try c.pio.sm_set_consecutive_pindirs(c.sm, g, 1, .out);
    for ([_]u1{ 0, 1 }) |v| {
        try c.pio.sm_set_pin(c.sm, g, 1, v);
        spin_us(5);
        if (g.read() != v) return fail("claimed range GPIO 39 drive {} read {}", .{ v, g.read() });
    }
    return pass("GPIO 32-39 claim chose PIO0 base 16, reserved memory and SM, drove GPIO 39", .{});
}

fn t_base_memory_busy() !Result {
    try pio0.set_gpio_base(.gpio16);
    const offset = try pio0.add_program(common("idle"));
    // No SM is claimed: only instruction memory can cause this refusal.
    if (pio0.set_gpio_base(.gpio0)) |_| return fail("base changed with instruction memory in use", .{}) else |_| {}
    if (pio0.get_gpio_base() != 16) return fail("refused memory-busy change still wrote GPIOBASE", .{});
    try pio0.remove_program(common("idle"), offset);
    try pio0.set_gpio_base(.gpio0);
    if (pio0.get_gpio_base() != 0) return fail("base did not change after program removal", .{});
    return pass("instruction memory alone prevents base change; removal permits it", .{});
}

fn t_base_sm_busy() !Result {
    try pio0.set_gpio_base(.gpio16);
    try pio0.claim_state_machine(.sm2);
    // Instruction memory is empty: only the claim can cause this refusal.
    if (pio0.set_gpio_base(.gpio0)) |_| return fail("base changed with an SM claimed", .{}) else |_| {}
    if (pio0.get_gpio_base() != 16) return fail("refused SM-busy change still wrote GPIOBASE", .{});
    pio0.unclaim(.sm2);
    try pio0.set_gpio_base(.gpio0);
    if (pio0.get_gpio_base() != 0) return fail("base did not change after unclaim", .{});
    return pass("SM claim alone prevents base change; unclaim permits it", .{});
}

// ---------------------------------------------------------------- CYW43

var cyw43_attempted = false;

fn t_cyw43() !Result {
    // Force relocation and SM1 DREQs rather than testing only offset 0/SM0.
    // No GPIO is touched by this reservation. All earlier DMA claims have
    // been released, and no reset_all() may follow CYW43 initialization.
    cyw43_attempted = true;
    try pio0.claim_state_machine(.sm0);
    _ = try pio0.add_program(common("filler"));
    try hal.cyw43.init();
    const wifi = hal.cyw43.wifi();
    try wifi.enable("GB");
    const mac = try wifi.get_mac_address();
    const fallback = [_]u8{ 0x28, 0xcd, 0xc1, 0, 0, 0 };
    // ioctl() can succeed without a reply, and wifi.zig then marks the
    // fallback 28:cd:c1:00:00:00 valid. Reject it and every zero suffix so
    // missing replies cannot masquerade as a real chip MAC readback.
    if (std.mem.eql(u8, &mac, &fallback) or
        std.mem.allEqual(u8, mac[3..], 0) or
        std.mem.allEqual(u8, &mac, 0) or
        std.mem.allEqual(u8, &mac, 0xff))
        return fail("invalid/fallback MAC {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] });

    // Use the error-returning WiFi API; hal.cyw43.gpio.put hides errors.
    // Neither API exposes GPIO readback. Successful ioctls alone are weak
    // evidence until the separate missing-reply driver fix lands.
    const led = @backingInt(hal.cyw43.gpio.Pin.led);
    try wifi.gpio_set(led, true);
    time.sleep_ms(100);
    try wifi.gpio_set(led, false);

    var bsss: [16]hal.cyw43.Wifi.BSS_Info = undefined;
    const scan = try wifi.scan(.{ .active_time = 200, .nprobes = 6 }, &.{}, &bsss);
    // An empty RF environment is a valid successful scan.
    return pass("init, MAC {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}, LED on/off (no readback API), scan seen={}", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], scan.seen });
}

fn cyw43_test() anyerror!Result {
    if (has_cyw43) return t_cyw43();
    return result(.SKIP, "CYW43 board only", .{});
}

// ---------------------------------------------------------------- runner

fn skipped() anyerror!Result {
    return result(.SKIP, "RP2350 only", .{});
}
fn rp2350(comptime f: fn () anyerror!Result) *const fn () anyerror!Result {
    return if (chip == .RP2350) f else skipped;
}

fn skipped_b() anyerror!Result {
    return result(.SKIP, "RP2350B only", .{});
}
fn rp2350b(comptime f: fn () anyerror!Result) *const fn () anyerror!Result {
    return if (has_rp2350b) f else skipped_b;
}

const Test = struct { name: []const u8, run: *const fn () anyerror!Result, rp2350_only: bool = false, cyw43: bool = false };
const tests = [_]Test{
    .{ .name = "load_offset_jumps_wrap", .run = t_offset_jumps_wrap },
    .{ .name = "program_32_instructions", .run = t_full_32 },
    .{ .name = "origin", .run = t_origin },
    .{ .name = "word_directive", .run = t_word },
    .{ .name = "wait_irq_rel", .run = t_wait_irq_rel },
    .{ .name = "exec_set_x_y", .run = t_exec_set_xy },
    .{ .name = "irq_flags_force_clear", .run = t_irq_flags },
    .{ .name = "system_irq_lines_isr", .run = t_system_irq_lines },
    .{ .name = "interrupt_sources", .run = t_interrupt_sources },
    .{ .name = "dma_dreq_tx_rx", .run = t_dma_dreq },
    .{ .name = "enable_in_sync", .run = t_enable_in_sync },
    .{ .name = "clkdiv_rate", .run = t_clkdiv_rate },
    .{ .name = "default_config_fifo_clockdiv", .run = t_default_config },
    .{ .name = "fdebug", .run = t_fdebug },
    .{ .name = "pc_exec_stalled", .run = t_pc_exec_stalled },
    .{ .name = "pins_pindirs_masks", .run = t_pins_masks },
    .{ .name = "claims_remove_program", .run = t_claims_remove },
    .{ .name = "input_sync_bypass", .run = t_sync_bypass },
    .{ .name = "pad_loopback", .run = t_pad_loopback },
    .{ .name = "dbg_cfginfo", .run = t_cfginfo },
    .{ .name = "rp2350_flags_4_7_isr", .run = rp2350(t_flags_4_7_isr), .rp2350_only = true },
    .{ .name = "rp2350_status_sel_irq", .run = rp2350(t_status_irq), .rp2350_only = true },
    .{ .name = "rp2350_gpiobase_16", .run = rp2350(t_gpiobase16), .rp2350_only = true },
    .{ .name = "rp2350_claim_for_gpio_range", .run = rp2350(t_claim_for_gpio_range), .rp2350_only = true },
    .{ .name = "rp2350_rx_putget", .run = rp2350(t_rx_putget), .rp2350_only = true },
    .{ .name = "rp2350_cross_pio_irq_ring", .run = rp2350(t_cross_pio_ring), .rp2350_only = true },
    .{ .name = "rp2350_cross_enable_in_sync", .run = rp2350(t_cross_sync_counters), .rp2350_only = true },
    .{ .name = "rp2350_wait_jmppin", .run = rp2350(t_wait_jmppin), .rp2350_only = true },
    .{ .name = "rp2350_mov_pindirs", .run = rp2350(t_mov_pindirs), .rp2350_only = true },
    .{ .name = "rp2350_irq_prevnext_putget_in", .run = rp2350(t_irq_prevnext_putget_in), .rp2350_only = true },
    .{ .name = "rp2350b_drive", .run = rp2350b(t_high_drive) },
    .{ .name = "rp2350b_wait_gpio", .run = rp2350b(t_high_wait_gpio) },
    .{ .name = "rp2350b_jmp_pin", .run = rp2350b(t_high_jmp_pin) },
    .{ .name = "rp2350b_input_sync_bypass", .run = rp2350b(t_high_sync_bypass) },
    .{ .name = "rp2350b_pins_pindirs_masks", .run = rp2350b(t_high_masks) },
    .{ .name = "rp2350b_claim_gpio_range", .run = rp2350b(t_high_claim_range) },
    .{ .name = "rp2350_base_memory_busy", .run = rp2350(t_base_memory_busy), .rp2350_only = true },
    .{ .name = "rp2350_base_sm_busy", .run = rp2350(t_base_sm_busy), .rp2350_only = true },
    // Last: reset_all invalidates the HAL's static CYW43 state. Keep init,
    // MAC, LED and scan in one guarded case with no resets between them.
    .{ .name = "cyw43_init_mac_led_scan", .run = cyw43_test, .cyw43 = true },
};

// RP2350 datasheet section 12.15.1.2, SYSINFO: PACKAGE_SEL (offset 0x004):
// bit 0 is 0 for QFN80 (RP2350B), 1 for QFN60 (RP2350A).
// https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
// pico-sdk 2.1.1 hardware/regs/sysinfo.h confirms the offset and bit mask.
// SYSINFO reads 0 (QFN80) while held in reset (erratum RP2350-E23), so this
// relies on hal.init having released every block, SYSINFO included, before main.
fn silicon_has_rp2350b() bool {
    if (chip == .RP2040) return false;
    return microzig.chip.peripherals.SYSINFO.PACKAGE_SEL.read().PACKAGE_SEL == 0;
}

fn package_name() []const u8 {
    if (chip == .RP2040) return "RP2040";
    return if (silicon_has_rp2350b()) "RP2350B" else "RP2350A";
}

fn run_all() void {
    // Refuse the whole run before reset_all() can touch high GPIOs.
    if (chip == .RP2350 and silicon_has_rp2350b() != has_rp2350b) {
        emit("TEST package_match FAIL silicon={s} build={s}; run refused", .{ package_name(), if (has_rp2350b) "RP2350B" else "RP2350A" });
        emit("SUMMARY pass=0 fail=1 skip=0 board={s}", .{board_name});
        return;
    }
    if (has_cyw43 and cyw43_attempted) {
        emit("TEST cyw43_init_mac_led_scan FAIL reload RAM image before another run", .{});
        emit("SUMMARY pass=0 fail=1 skip=0 board={s}", .{board_name});
        return;
    }
    var counts = [_]u32{ 0, 0, 0 };
    inline for (tests) |t| {
        feed();
        const r: Result = if (t.rp2350_only and chip != .RP2350)
            result(.SKIP, "RP2350 only", .{})
        else blk: {
            reset_all();
            arm_hang_guard(t.name, if (t.cyw43) 30_000_000 else hang_guard_us);
            const got = t.run() catch |e| result(.FAIL, "error.{s}", .{@errorName(e)});
            disarm_hang_guard();
            if (!t.cyw43) reset_all();
            break :blk got;
        };
        counts[@backingInt(r.outcome)] += 1;
        emit("TEST {s} {s} {s}", .{ t.name, @tagName(r.outcome), r.detail });
    }
    emit("SUMMARY pass={} fail={} skip={} board={s}", .{ counts[0], counts[1], counts[2], board_name });
}

fn handle(cmd: u8) void {
    switch (cmd) {
        'r' => run_all(),
        'i' => emit("BOARD {s} chip={s} package={s} sys_hz={} pins={any}", .{ board_name, @tagName(chip), package_name(), sys_hz, free_pins }),
        'b' => {
            emit_last("BOOTSEL", .{});
            reboot_to_bootsel();
        },
        'q' => {
            emit_last("REBOOT", .{});
            reboot_normal();
        },
        'P' => @panic("requested panic"),
        'H' => {
            if (chip == .RP2350) {
                // Hang only when the watchdog is seen counting down: nothing
                // else would end the hang. (RP2040-E1: TIME does not read back.)
                const before = hal.watchdog.remaining_us();
                spin_us(2000);
                const after = hal.watchdog.remaining_us();
                if (after >= before) return emit("HANG refused: watchdog TIME {} then {}", .{ before, after });
            }
            emit_last("HANG", .{});
            while (true) {}
        },
        'F' => {
            emit_last("FAULT", .{});
            asm volatile ("udf #0");
        },
        else => {},
    }
}

pub fn run(comptime with_usb: bool) noreturn {
    arm_watchdog();
    const boot = now_us();
    if (with_usb) usb_device = .init();
    while (true) {
        feed();
        if (with_usb) usb_device.poll(&usb_controller);
        if (serial()) |s| {
            usb_ready = true;
            var buf: [64]u8 = undefined;
            const n = s.read(&buf);
            for (buf[0..n]) |c| handle(c);
        } else if (!usb_ready and now_us() - boot > usb_deadline_us) {
            reboot_to_bootsel();
        }
    }
}
