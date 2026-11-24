//! Pico 2 W RAM peer for ESP32-C3/C6 peripheral self-tests.
//! Build target: pico2_w_ram_esp_peer. Load its RAM UF2 via BOOTSEL;
//! no flash writes. GPIO functions: RP2350 datasheet §1.2.3 Table 3.
//! Wire C6 GPIO0..7 to Pico GP8..15, GPIO18 to GP16, GPIO19 to GP17;
//! wire C3 GPIO0/1/3/10 to GP0/1/2/3. Connect all GNDs. Each board
//! uses its own USB supply; no supply wire between boards. The banks
//! can remain connected together; unused lines are inputs with no pulls.
//! C6 L0..7=GP8..15, CLK=GP16, VAL=GP17; C3 L0..3=GP0..3.
//! UART: L0 peer TX -> ESP RX, L1 peer RX <- ESP TX (pulled up). SPI: L0 MISO,
//! L1 MOSI, L2 SCLK, L3 CS (mode 0, MSB first, 1 MHz). I2S: L0 ESP DIN,
//! L1 ESP DOUT, L2 BCK, L3 WS (Philips stereo, 1 MHz BCK).
//! RMT: L1 capture, L0 replay. PARL: L0..7 bidirectional data,
//! CLK clock, VAL valid. LP UART: L4 TX -> ESP GPIO4 RX,
//! L5 RX <- ESP GPIO5 TX (pulled up), 115200 8N1. I2C: L6 SDA, L7 SCL,
//! target 0x42 at 100 kHz, internal pulls; optional 4.7 kohm to 3V3.
//! I2C pointer byte selects a register, subsequent bytes auto-increment;
//! STOP retains the pointer, 0xf2 reads 0xa5, 0xf3 reads version 1.
//!
//! USB CDC accepts newline-terminated commands:
//! `mode <idle|uart|spi|i2s|rmt|parl|lpuart|i2c> <c3|c6>` replies
//! `OK mode <mode> <bank>`; select before starting the ESP self-test.
//! `status` reports frames, bytes, line edges, errors and worst clock;
//! request it after ESP DONE. `boot` enters ROM USB boot, `reset` reboots
//! into the flash image. Host helper: pico_peer.py mode <mode> <bank>.
//! PASS requires no PEER FAIL, status errors=0, and ESP DONE fail=0
//! with pass counts: uart 7, spi_dma 8, i2s 8, rmt 3, parl_io 16,
//! lp_uart 5, lp_i2c 7. UART also requires parity_rx PASS; RMT requires
//! tx_widths_64 and tx_widths_137 PASS (width error <=2 us). UART,
//! LP UART, SPI, I2S and PARL require clk PASS (within 1% of baud or
//! 1 MHz). I2C checks scanning, pattern readback and NACK recovery.
//!
//! Protocol readings the ESP may rely on:
//! * SPI and I2S echo the previous frame DURING the next clocked frame,
//!   with ESP-provided clocks; the 20 ms replay delay is for RMT/PARL.
//!   The ESP must leave >=100 ms between frames: SPI CS stays high
//!   with SCLK idle; I2S BCK/WS stay idle. Early clocks during decode/rearm
//!   report FrameBeforeRearm; an earlier-than-100 ms restart reports
//!   InterframeGap. Both release the harness and enter idle, without waiting.
//! * I2S bit zero is the second BCK rising edge following the first WS fall:
//!   the Philips delay bit is skipped, so the capture holds the samples'
//!   bits exactly. Both directions preserve that position.
//! * RMT count excludes the 64/64 guard. Only its final low is unmeasurable;
//!   replay ends with a 256 us guard low, followed by released, low idle.
//! * `status` finalizes the worst qualifying clock verdict for this mode run.
//!   Later qualifying frames update the stored worst; another status reports it.
//!   PIO clock windows use a cycle counter calibrated against the RP2350
//!   timer over 10 ms, avoiding 1 us quantization on 64-clock PARL bursts.
//!   UART/LP UART use low-pulse widths, excluding inter-byte echo latency
//!   and idle-high gaps. RMT reports absolute widths instead of a bit clock.
//!   Status also repeats the UART parity and RMT width verdicts, preserving
//!   results when the host script closes and reopens the CDC port.
//! * edges are observed transition counts, not a glitch analyzer, counted from
//!   the pad state after mode entry has configured the peer's pads. Serial DMA
//!   samples data/WS on each rising clock; PARL samples data/VAL every falling
//!   clock. Raw pad rise/fall latches diagnose activity before capture and in
//!   UART/I2C modes; multiple edges between services coalesce. Clock counts
//!   during DMA are derived from actual captured samples.
//! * All buffers are bounded: SPI/I2S 16 KiB, PARL 32768 + 256 samples,
//!   RMT 512 half-widths. PARL headroom assumes the ESP stops its 1 MHz
//!   clock within 256 us of end of transfer. Overflow or a stuck active
//!   SPI CS fails and releases the pads.
//! * C3 accepts idle/uart/spi/i2s/rmt only. Other C3 combinations return ERR.
//! No flash writes, radio startup, or debug UART. Reset returns to flash.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const protocol = @import("esp_peer/protocol.zig");
const programs = @import("esp_peer/programs.zig");
const registers = @import("esp_peer/registers.zig");
const usb = microzig.core.usb;
const pio = hal.pio.num(0);
const sm: hal.pio.StateMachine = .sm0;
const rx_dma = hal.dma.channel(0);
const tx_dma = hal.dma.channel(1);
const meter_dma = hal.dma.channel(2);
const meter = hal.pio.num(1);
var meter_samples: [4097]u32 = undefined;
var meter_hz: u32 = 0;
const USB_Device = hal.usb.Polled(.{});
var usb_device: USB_Device = undefined;
var usb_controller: usb.DeviceController(.{
    .device_triple = .unspecified,
    .product = .{ .id = USB_Device.device_capabilities.default_product.?.id, .str = "MicroZig ESP peer" },
    .bcd_device = .v1_00,
    .serial = "ESPPEER",
    .device_capabilities = USB_Device.device_capabilities,
}, &.{usb.Configuration(
    .{ .attributes = .{ .self_powered = false }, .max_current_ma = 100 },
    .{ .serial = usb.drivers.CDC{ .itf_notifi_str = "ESP peer", .itf_data_str = "ESP peer data" } },
)}) = .init;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});
pub const microzig_options: microzig.Options = .{
    .interrupts = .{ .I2C1_IRQ = .{ .c = hal.i2c.slave.isr1 } },
};
comptime {
    _ = microzig.export_startup();
}
var mode: protocol.Mode = .idle;
var bank: protocol.Bank = .c6;
var phase: protocol.UartPhase = .{};
var parity_reported = false;
var previous: protocol.Replay = .{};
// The largest frame is 32768 PARL edges; the sender's clock runs on until
// it polls end of transfer. The 256-edge headroom assumes this polling
// latency is at most 256 us at 1 MHz (one trailing edge per microsecond).
var capture: [32768 + 256]u32 = undefined;
var output: [capture.len]u32 = @splat(0);
var frames: u64 = 0;
var bytes: u64 = 0;
var errors: u64 = 0;
var edges: [10]u64 = @splat(0);
var last_pads: u32 = 0;
var worst_hz: u32 = 0;
var expected_hz: u32 = 0;
var clock_available = false;
var armed = false;
var replaying = false;
var replay_dma_done = false;
var replay_due: ?u64 = null;
var replay_deadline: u64 = 0;
var replay_count: usize = 0;
var progress: usize = 0;
var last_us: u64 = 0;
var armed_us: u64 = 0;
var uart_bytes: usize = 0;
var uart_last_us: u64 = 0;
var cs_since: ?u64 = null;
var serial_timing: protocol.FrameTiming = .{};
var checking_rearm = false;
var rmt_high_since: ?u64 = null;
const WidthVerdict = struct { seen: bool = false, first_bad: ?usize = null };
var width_verdicts: [2]WidthVerdict = @splat(.{});

fn now_us() u64 {
    return hal.time.get_time_since_boot().to_us();
}
fn base() u6 {
    return if (bank == .c6) 8 else 0;
}
fn pin(line: u6) hal.gpio.Pin {
    return hal.gpio.num(base() + line);
}
fn uart() hal.uart.UART {
    return hal.uart.instance.num(if (mode == .lpuart or bank == .c3) 0 else 1);
}
var console_tx: [4096]u8 = undefined;
var console_head: usize = 0;
var console_len: usize = 0;
fn emit(comptime fmt: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    const text = std.mem.print(&buffer, fmt ++ "\r\n", args) catch {
        errors += 1;
        return;
    };
    if (text.len > console_tx.len - console_len) {
        errors += 1;
        return;
    }
    for (text) |byte| {
        console_tx[(console_head + console_len) % console_tx.len] = byte;
        console_len += 1;
    }
}
fn service_console() void {
    usb_device.poll(&usb_controller);
    const drivers = usb_controller.drivers() orelse return;
    if (console_len > 0) {
        const count = @min(console_len, console_tx.len - console_head);
        const sent = drivers.serial.write(console_tx[console_head .. console_head + count]);
        console_head = (console_head + sent) % console_tx.len;
        console_len -= sent;
    }
    _ = drivers.serial.flush();
}
fn fail(reason: []const u8) void {
    errors += 1;
    emit("PEER {s} frame: FAIL error={s}", .{ @tagName(mode), reason });
}
fn pads_input() void {
    for ([_]u6{ 0, 1, 2, 3, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 }) |n| {
        const p = hal.gpio.num(n);
        p.set_direction(.in);
        p.set_function(.sio);
        p.set_pull(.disabled);
    }
}
fn observed_edges() void {
    // RP2350 DS §§9.5, 9.11.1 IO_BANK0 INTR: rise/fall events are sticky W1C,
    // independent of interrupt masking. Read through Mmio, then clear only
    // the harness edge flags. No GPIO IRQ is enabled.
    const io = microzig.chip.peripherals.IO_BANK0;
    const raw: u64 = if (bank == .c3) io.INTR0.raw else @as(u64, io.INTR1.raw) | (@as(u64, io.INTR2.raw) << 32);
    if (bank == .c3) io.INTR0.write_raw(0xcccc) else {
        io.INTR1.write_raw(0xcccccccc);
        io.INTR2.write_raw(0xcc);
    }
    const mask: u32 = switch (mode) {
        .uart, .rmt => 3,
        .spi, .i2s => 15,
        .lpuart => 3 << 4,
        .i2c => 3 << 6,
        .parl => 0x3ff,
        .idle => 0,
    };
    for (&edges, 0..) |*count, i| {
        if (mask & (@as(u32, 1) << @intCast(i)) != 0)
            count.* += @popCount((raw >> @intCast(i * 4 + 2)) & 3);
    }
}
fn sample_edges(value: u32, mask: u32) void {
    var changed = (value ^ last_pads) & mask;
    while (changed != 0) {
        edges[@ctz(changed)] += 1;
        changed &= changed - 1;
    }
    last_pads = (last_pads & ~mask) | (value & mask);
}
fn clock_rise_pending() bool {
    // Both serial banks put L2 in slot 2 of their IO_BANK0 INTR register.
    return (if (bank == .c3) microzig.chip.peripherals.IO_BANK0.INTR0.raw else microzig.chip.peripherals.IO_BANK0.INTR1.raw) & (1 << 11) != 0;
}
fn clear_clock_rise() void {
    if (bank == .c3) microzig.chip.peripherals.IO_BANK0.INTR0.write_raw(1 << 11) else microzig.chip.peripherals.IO_BANK0.INTR1.write_raw(1 << 11);
}
fn reject_frame(reason: []const u8) !void {
    try stop();
    pads_input();
    fail(reason);
    mode = .idle;
    checking_rearm = false;
}
fn abort_dma() error{DmaTimeout}!void {
    // RP2350 DS §12.6.10 CHAN_ABORT: wait until abort bits clear before reusing.
    const dma_regs = microzig.chip.peripherals.DMA;
    dma_regs.CHAN_ABORT.write_raw(7);
    const deadline = now_us() + 1000;
    while (dma_regs.CHAN_ABORT.raw & 7 != 0) {
        if (now_us() >= deadline) return error.DmaTimeout;
    }
}
fn stop() !void {
    pio.sm_set_enabled(sm, false);
    meter.sm_set_enabled(sm, false);
    try abort_dma();
    pio.sm_clear_fifos(sm);
    pio.sm_restart(sm);
    armed = false;
}
fn dma_rx(count: usize) void {
    rx_dma.setup_transfer_raw(@intFromPtr(&capture), @intFromPtr(pio.sm_get_rx_fifo(sm)), @intCast(count), .{
        .data_size = .size_32,
        .enable = true,
        .read_increment = false,
        .write_increment = true,
        .dreq = pio.sm_dreq(sm, .rx),
    });
}
fn dma_tx(count: usize) void {
    tx_dma.setup_transfer_raw(@intFromPtr(pio.sm_get_tx_fifo(sm)), @intFromPtr(&output), @intCast(count), .{
        .data_size = .size_32,
        .enable = true,
        .read_increment = true,
        .write_increment = false,
        .dreq = pio.sm_dreq(sm, .tx),
    });
}
fn configure(program: hal.pio.Program, hz: u32, mappings: hal.pio.PinMappingOptions, shift: hal.pio.ShiftOptions) !void {
    pio.clear_instruction_memory();
    _ = try pio.sm_load_and_start_program(sm, program, .{
        .clkdiv = try hal.pio.clkdiv_from_hz(hal.clock_config.get_frequency(.clk_sys).?, hz),
        .pin_mappings = mappings,
        .shift = shift,
        .exec = .{ .jmp_pin = if (mode == .lpuart) hal.gpio.num(13) else pin(1) },
    });
    // Loader leaves SM stopped. Set directions and DMA before enabling it.
    pio.sm_set_pindirs_with_mask(sm, 0, 0x3ffff);
}
fn serial_program() hal.pio.Program {
    return switch (bank) {
        .c3 => if (mode == .spi) programs.serial(0, true) else programs.serial(0, false),
        .c6 => if (mode == .spi) programs.serial(8, true) else programs.serial(8, false),
    };
}
fn pack_previous() void {
    @memset(&output, 0);
    for (0..4096) |i| output[i] = previous.word(i);
}
fn calibrate_meter() !void {
    meter.clear_instruction_memory();
    _ = try meter.sm_load_and_start_program(sm, programs.calibration, .{});
    const start = now_us();
    meter.sm_set_enabled(sm, true);
    while (now_us() - start < 10_000) {}
    meter.sm_set_enabled(sm, false);
    const elapsed = now_us() - start;
    meter.sm_exec(sm, @bitCast(programs.calibration.instructions[2]));
    meter.sm_exec(sm, @bitCast(programs.calibration.instructions[3]));
    if (meter.sm_is_rx_fifo_empty(sm)) return error.MeterCalibration;
    meter_hz = protocol.clock_hz(meter.sm_read(sm), elapsed) orelse return error.MeterCalibration;
}
fn arm_meter() !void {
    const clock_pin: u6 = if (mode == .parl) 16 else base() + 2;
    const program = if (mode == .parl) programs.clock_meter(16) else if (bank == .c6) programs.clock_meter(10) else programs.clock_meter(2);
    meter.clear_instruction_memory();
    _ = try meter.sm_load_and_start_program(sm, program, .{ .exec = .{ .jmp_pin = hal.gpio.num(clock_pin) } });
    meter_dma.setup_transfer_raw(@intFromPtr(&meter_samples), @intFromPtr(meter.sm_get_rx_fifo(sm)), meter_samples.len, .{
        .data_size = .size_32,
        .enable = true,
        .read_increment = false,
        .write_increment = true,
        .dreq = meter.sm_dreq(sm, .rx),
    });
    meter.sm_set_enabled(sm, true);
}
const MeterSample = struct { count: usize, stalled: bool };
/// Stop the clock meter and sample its DMA progress before stop().
/// RP2350 datasheet §12.6.2.2: TRANS_COUNT reads the remaining transfers;
/// §12.6.8.3: CHAN_ABORT clears the transfer counter, so sample before aborting.
fn sample_meter() MeterSample {
    meter.sm_set_enabled(sm, false);
    return .{
        .count = meter_samples.len - @as(usize, @intCast(meter_dma.get_regs().trans_count & 0x0fff_ffff)),
        .stalled = meter.sm_fdebug(sm).rx_stall,
    };
}
fn frame_clock(meter_state: MeterSample) void {
    const count = meter_state.count;
    // Sample 0 starts at the first rising edge after arming, which can be
    // the sender's setup edge (PARL_IO gates its clock through one slow
    // phase before data); measure from sample 1, the data clock alone.
    if (count < 2 or count == meter_samples.len or meter_state.stalled) {
        fail("ClockMeterOverflowOrMissing");
        return;
    }
    var cycles: u64 = 0;
    for (meter_samples[1..count]) |sample| cycles += protocol.meter_cycles(sample);
    const hz: u32 = @intCast(@as(u64, meter_hz) * (count - 1) * 32 / cycles);
    record_hz(hz, 1_000_000);
}
fn arm() !void {
    try stop();
    progress = 0;
    last_us = now_us();
    armed_us = last_us;
    cs_since = null;
    replaying = false;
    switch (mode) {
        .spi, .i2s => {
            for (0..4) |i| pio.gpio_init(pin(@intCast(i)));
            // CS is active low: hold it deselected while the ESP resets or
            // sits in download mode, or the floating pad trips CsTimeout.
            if (mode == .spi) pin(3).set_pull(.up);
            try configure(serial_program(), hal.clock_config.get_frequency(.clk_sys).?, .{
                .in_base = pin(0),
                .out = .single(pin(0)),
            }, .{ .autopush = true, .push_threshold = 0, .in_shiftdir = .left, .autopull = true, .pull_threshold = 0, .out_shiftdir = .left });
            pio.sm_set_pindirs_with_mask(sm, @as(u32, 1) << @as(u5, @intCast(base())), @as(u32, 1) << @as(u5, @intCast(base())));
            pack_previous();
            dma_rx(16385);
            // 64 KiB of padded output also covers malformed overlong input until timeout.
            dma_tx(16385);
        },
        .parl => {
            for (0..10) |i| pio.gpio_init(pin(@intCast(i)));
            // Hold CLK and VAL low while the ESP resets or sits in download
            // mode; a floating CLK clocks noise until CaptureOverflow.
            pin(8).set_pull(.down);
            pin(9).set_pull(.down);
            try configure(programs.parl_capture, hal.clock_config.get_frequency(.clk_sys).?, .{ .in_base = pin(0) }, .{
                .autopush = true,
                .push_threshold = 16,
                .in_shiftdir = .left,
                .join_rx = true,
            });
            dma_rx(capture.len);
        },
        .rmt => {
            pio.gpio_init(pin(1));
            // Bias capture input L1 toward RMT idle low while the ESP pad floats.
            // RP2350 datasheet §D.5.1 (RP2350-E9): on A2 silicon, input leakage
            // can overpower this internal pull-down; it cannot guarantee low
            // during reset/download mode. The ESP RMT TX pad drives L1 during
            // the test; a floating high can trip RmtHighTimeout.
            pin(1).set_pull(.down);
            // L0 is replay output only. With its input buffer enabled, a pad
            // last driven high, such as UART idle, can hold the line high
            // against the ESP's internal pull-down. RP2350 datasheet §D.5.1
            // (RP2350-E9): disabling input enable removes the A2 leakage,
            // allowing the pull-down to establish idle low before the ESP
            // captures its first RX item. Replay's gpio_init re-enables input.
            pin(0).set_input_enabled(false);
            try configure(if (bank == .c3) programs.rmt_capture(0) else programs.rmt_capture(8), 20_000_000, .{}, .{ .join_rx = true });
            dma_rx(512);
        },
        else => return,
    }
    if (mode != .rmt) try arm_meter();
    if (checking_rearm) {
        checking_rearm = false;
        if (clock_rise_pending() or (mode == .spi and pin(3).read() == 0)) {
            try reject_frame("FrameBeforeRearm");
            return;
        }
    }
    armed = true;
    pio.sm_set_enabled(sm, true);
}
fn set_uart() !void {
    try uart().apply_runtime(.{ .clock_config = hal.clock_config, .baud_rate = if (mode == .lpuart) 115200 else phase.baud(), .parity = if (mode == .uart and phase.phase == .p2) .even else .none });
}
fn arm_uart_meter() !void {
    try stop();
    // PIO reads the pad independently of its UART function (RP2350 DS
    // §11.2.6). The selected PL011 remains the sole output driver.
    const program = if (mode == .lpuart) programs.rmt_capture(12) else if (bank == .c6) programs.rmt_capture(8) else programs.rmt_capture(0);
    try configure(program, 20_000_000, .{}, .{ .join_rx = true });
    dma_rx(4096);
    pio.sm_set_enabled(sm, true);
}
fn uart_clock() !void {
    // Sample before stop() clears the counter; see sample_meter().
    pio.sm_set_enabled(sm, false);
    const count = 4096 - @as(usize, @intCast(rx_dma.get_regs().trans_count & 0x0fff_ffff));
    const stalled = pio.sm_fdebug(sm).rx_stall;
    try stop();
    const sampler_hz: u32 = @intCast(@as(u64, meter_hz) * 20_000_000 / hal.clock_config.get_frequency(.clk_sys).?);
    if (count == 4096 or stalled) {
        fail("UartClockOverflow");
    } else if (protocol.uart_edge_baud(capture[0..count], sampler_hz, phase.baud())) |hz| {
        record_hz(hz, phase.baud());
    } else fail("UartClockMissing");
    try arm_uart_meter();
}
fn select(new_mode: protocol.Mode, new_bank: protocol.Bank) !void {
    try stop();
    if (mode == .i2c) registers.close();
    // Disable both PL011s before releasing their pins (RP2350 DS §12.1 UARTCR).
    microzig.chip.peripherals.UART0.UARTCR.write_raw(0);
    microzig.chip.peripherals.UART1.UARTCR.write_raw(0);
    pads_input();
    mode = new_mode;
    bank = new_bank;
    frames = 0;
    bytes = 0;
    errors = 0;
    previous.clear();
    phase = .{};
    parity_reported = false;
    width_verdicts = @splat(.{});
    clock_available = false;
    worst_hz = 0;
    expected_hz = 0;
    replay_due = null;
    uart_bytes = 0;
    serial_timing = .{};
    checking_rearm = false;
    rmt_high_since = null;
    // UART and LP UART: the peer's TX pad; the next pad is its RX.
    const uart_tx: u6 = if (mode == .lpuart) 12 else base();
    if (mode == .uart or mode == .lpuart) {
        // pads_input() leaves RX with no pull, and while the ESP is in
        // reset or download mode nothing drives its TX, so the RX line
        // floats and can sit low. An enabled PL011 reports a line held low
        // for a full word as a break (RP2350 DS §12.1.8 UARTDR BE). Pull RX
        // to the idle mark now; it settles during the 10 ms meter
        // calibration before the receiver is enabled.
        hal.gpio.num(uart_tx + 1).set_pull(.up);
    }
    if (mode == .spi or mode == .i2s or mode == .parl or mode == .lpuart or mode == .uart) try calibrate_meter();
    switch (mode) {
        .uart, .lpuart => {
            hal.gpio.num(uart_tx).set_function(.uart);
            hal.gpio.num(uart_tx + 1).set_function(.uart);
            uart().get_regs().UARTLCR_H.modify(.{ .FEN = 0 });
            try set_uart();
            try arm_uart_meter();
        },
        .i2c => {
            hal.gpio.num(14).set_function(.i2c);
            hal.gpio.num(15).set_function(.i2c);
            hal.gpio.num(14).set_pull(.up);
            hal.gpio.num(15).set_pull(.up);
            registers.open();
        },
        .idle => {},
        else => try arm(),
    }
    // Mode entry moves the peer's own pads (UART TX to idle high, pulls,
    // PIO outputs). Count edges and sample-level changes from that state.
    last_pads = microzig.chip.peripherals.SIO.GPIO_IN.raw >> @intCast(base());
    observed_edges();
    edges = @splat(0);
}
fn record_hz(hz: u32, expected: u32) void {
    if (!clock_available or @abs(@as(i64, hz) - expected) * @as(u64, expected_hz) >= @abs(@as(i64, worst_hz) - expected_hz) * @as(u64, expected)) {
        worst_hz = hz;
        expected_hz = expected;
    }
    clock_available = true;
}
fn clock_verdict() void {
    if (!clock_available) return;
    emit("PEER {s} clk: {s} hz={d} expected={d} tol=1%", .{ @tagName(mode), if (protocol.clock_pass(worst_hz, expected_hz)) "PASS" else "FAIL", worst_hz, expected_hz });
}
fn service_uart() !void {
    observed_edges();
    // One bounded FIFO batch, then let the main loop service USB and deadlines.
    for (0..32) |_| {
        const value = uart().read_word() catch |err| {
            uart().clear_errors();
            fail(@errorName(err));
            break;
        } orelse break;
        const now = now_us();
        uart_last_us = now;
        uart_bytes += 1;
        bytes += 1;
        if (mode == .uart) phase.receive(now);
        // TX FIFO write has a fixed deadline; do not wait for all TX to drain.
        const deadline = now + 1000;
        while (!uart().is_writeable() and now_us() < deadline) {}
        if (!uart().is_writeable()) {
            fail("UartTxTimeout");
            break;
        }
        uart().get_regs().UARTDR.write_raw(value);
        if (mode == .uart and phase.phase == .p2 and !parity_reported) {
            parity_reported = true;
            emit("PEER uart parity_rx: PASS", .{});
        }
    }
    const now = now_us();
    if (uart_bytes > 0 and now - uart_last_us >= 1000) {
        frames += 1;
        if (uart_bytes >= 64) try uart_clock() else try arm_uart_meter();
        uart_bytes = 0;
    }
    if (mode == .uart and phase.idle(now)) {
        try set_uart();
        try arm_uart_meter();
    }
}
fn serial_frame(count: usize) void {
    if (count > previous.bytes.len) {
        previous.clear();
        fail("FrameOverflow");
        return;
    }
    for (capture[0..count], 0..) |word, i| {
        for (0..8) |bit_index| {
            const sample = (word >> @intCast((7 - bit_index) * 4)) & 15;
            sample_edges(sample, 0b1011);
        }
        previous.bytes[i] = protocol.serial_byte(word);
    }
    previous.len = count;
    edges[2] += count * 16;
    if (mode == .spi) edges[3] += 2;
    bytes += count;
}
fn prepare_parl(count: usize) void {
    for (capture[0..count], 0..) |word, i| {
        const value = word & 0x3ff;
        sample_edges(value, 0x2ff);
        output[i] = (value | 0x100) << 22;
    }
    edges[8] += count * 2;
    bytes += count;
    replay_count = count;
}
fn prepare_rmt(count: usize) void {
    // 20 MHz, two-instruction loops => 0.1 us; compensate four setup cycles.
    for (capture[0..count]) |*width| width.* += 2;
    const items = if (count > 0) (count - 1) / 2 else 0;
    const bad = protocol.rmt_first_bad(capture[0..count], items);
    const valid_count = items == 64 or items == 137;
    const passed = bad == null and valid_count;
    if (!passed) errors += 1;
    const first_bad = bad orelse if (valid_count) @as(?usize, null) else count;
    if (valid_count) {
        const verdict = &width_verdicts[if (items == 64) @as(usize, 0) else 1];
        verdict.seen = true;
        if (verdict.first_bad == null) verdict.first_bad = first_bad;
    }
    report_widths(items, first_bad);
    for (capture[0..count], 0..) |width, i| output[i] = width -| 4;
    output[count] = 2560 - 4;
    replay_count = count + 1;
    edges[1] += count + 1;
    bytes += items * 4;
}
fn report_widths(items: usize, first_bad: ?usize) void {
    emit("PEER rmt tx_widths_{d}: {s} first_bad={d}", .{ items, if (first_bad == null) "PASS" else "FAIL", if (first_bad) |bad| @as(i64, @intCast(bad)) else -1 });
}
fn finish_frame(count: usize) !void {
    const meter_sample = sample_meter();
    try stop();
    if (mode == .spi or mode == .i2s) {
        serial_timing.last_end_us = last_us;
        clear_clock_rise();
        checking_rearm = true;
    }
    const debug = pio.sm_fdebug(sm);
    // A stalled RX FIFO loses timing even if memory has space.
    if (debug.rx_stall) {
        fail("RxFifoStall");
        try arm();
        return;
    }
    frames += 1;
    switch (mode) {
        .spi, .i2s => serial_frame(count),
        .parl => {
            if (count < 16) {
                try arm();
                return;
            }
            prepare_parl(count);
        },
        .rmt => prepare_rmt(count),
        else => return,
    }
    const frame_bytes = count;
    if ((mode == .spi or mode == .i2s or mode == .parl) and frame_bytes >= 64) frame_clock(meter_sample);
    if (mode == .parl or mode == .rmt) {
        if (replay_count > 0) replay_due = last_us + (if (mode == .rmt) @as(u64, 2000) else 1000) + 20_000 else try arm();
    } else try arm();
}
fn start_replay() !void {
    replay_due = null;
    try stop();
    if (mode == .parl) {
        try configure(programs.parl_replay, 10_000_000, .{
            .out = .{ .low = pin(0), .high = pin(9) },
            .set = .single(pin(8)),
        }, .{ .autopull = true, .pull_threshold = 16, .out_shiftdir = .left });
        pio.sm_set_pindirs_with_mask(sm, 0x3ff00, 0x3ff00);
    } else {
        pio.gpio_init(pin(0));
        try configure(programs.rmt_replay, 10_000_000, .{ .set = .single(pin(0)) }, .{});
        pio.sm_set_pins_with_mask(sm, 0, @as(u32, 1) << @as(u5, @intCast(base())));
        pio.sm_set_pindirs_with_mask(sm, @as(u32, 1) << @as(u5, @intCast(base())), @as(u32, 1) << @as(u5, @intCast(base())));
    }
    dma_tx(replay_count);
    pio.sm_set_enabled(sm, true);
    replaying = true;
    replay_dma_done = false;
    armed = false;
    replay_deadline = now_us() + 500_000;
}
fn service_pio() !void {
    const now = now_us();
    if (replay_due) |due| {
        if (now >= due) try start_replay();
        return;
    }
    if (replaying) {
        // TX DMA done means FIFO queued, not waveform complete. TXSTALL means
        // the final PULL ran out after consuming every queued sample.
        if (!tx_dma.is_busy() and !replay_dma_done) {
            // Discard any startup TXSTALL; only a fresh stall after the final
            // DMA write proves that the last waveform sample has completed.
            pio.sm_clear_debug(sm);
            replay_dma_done = true;
        } else if (replay_dma_done and pio.sm_fdebug(sm).tx_stall) {
            try stop();
            pads_input();
            try arm();
        } else if (now >= replay_deadline) {
            try stop();
            pads_input();
            fail("ReplayTimeout");
            try arm();
        }
        return;
    }
    if (!armed) return;
    if (progress == 0) observed_edges();
    const capacity: usize = if (mode == .rmt) 512 else if (mode == .parl) capture.len else 16385;
    const count = capacity - @as(usize, @intCast(rx_dma.get_regs().trans_count & 0x0fff_ffff));
    if (progress == 0 and count > 0 and (mode == .spi or mode == .i2s)) {
        serial_timing.check_start(now) catch {
            try reject_frame("InterframeGap");
            return;
        };
    }
    if (count != progress) {
        progress = count;
        last_us = now;
    }
    if (count == capacity) {
        try stop();
        pads_input();
        fail("CaptureOverflow");
        // Wait for the line to become idle before arming again.
        mode = .idle;
        return;
    }
    if (mode == .spi) {
        if (pin(3).read() == 1) {
            cs_since = null;
            if (count > 0) try finish_frame(count) else if (now - (serial_timing.last_end_us orelse armed_us) >= 500_000) {
                previous.clear();
                frames = 0;
                serial_timing = .{};
                try arm();
            }
        } else if (cs_since == null) {
            cs_since = now;
        } else if (now - cs_since.? >= 1_000_000) {
            try stop();
            pads_input();
            fail("CsTimeout");
            mode = .idle;
        }
    } else if (mode == .rmt and pin(1).read() == 1) {
        if (rmt_high_since == null) rmt_high_since = now;
        if (now - rmt_high_since.? >= 1_000_000) try reject_frame("RmtHighTimeout");
    } else if (count > 0 and now - last_us >= (if (mode == .rmt) @as(u64, 2000) else 1000)) {
        try finish_frame(count);
    } else rmt_high_since = null;
}
fn status() void {
    if (mode == .uart and parity_reported) emit("PEER uart parity_rx: PASS", .{});
    if (mode == .rmt) {
        for (width_verdicts, [_]usize{ 64, 137 }) |verdict, items| {
            if (verdict.seen) report_widths(items, verdict.first_bad);
        }
    }
    clock_verdict();
    emit("PEER {s} {s} frames={d} bytes={d} edges={d},{d},{d},{d},{d},{d},{d},{d},{d},{d} errors={d} clk_hz={d}", .{
        @tagName(mode), @tagName(bank), if (mode == .i2c) registers.frames else frames, if (mode == .i2c) registers.bytes else bytes,
        edges[0],       edges[1],       edges[2],                                       edges[3],
        edges[4],       edges[5],       edges[6],                                       edges[7],
        edges[8],       edges[9],       errors,                                         worst_hz,
    });
}
fn command(line: []const u8) !void {
    const cmd = protocol.parse(line) catch {
        emit("ERR command", .{});
        return;
    };
    switch (cmd) {
        .mode => |selection| {
            try select(selection.mode, selection.bank);
            emit("OK mode {s} {s}", .{ @tagName(mode), @tagName(bank) });
        },
        .status => status(),
        .reset, .boot => {
            try stop();
            pads_input();
            emit("OK {s}", .{if (cmd == .boot) "boot" else "reset"});
            const deadline = now_us() + 100_000;
            while (now_us() < deadline) service_console();
            if (cmd == .boot) hal.rom.reset_to_usb_boot() else {
                microzig.chip.peripherals.WATCHDOG.SCRATCH4.write_raw(0);
                hal.watchdog.force();
            }
        },
    }
}
pub fn main() !void {
    try rx_dma.claim();
    try tx_dma.claim();
    try meter_dma.claim();
    try pio.claim_state_machine(sm);
    try meter.claim_state_machine(sm);
    pads_input();
    usb_device = .init();
    var line: [96]u8 = undefined;
    var length: usize = 0;
    var overflow = false;
    var next_console_us: u64 = 0;
    while (true) {
        switch (mode) {
            .uart, .lpuart => try service_uart(),
            .spi, .i2s, .parl, .rmt => try service_pio(),
            .i2c => {
                observed_edges();
                registers.poll();
            },
            .idle => {},
        }
        // Keep USB responsive even to a continuously clocking/flooding ESP.
        // DMA owns PIO transfers; UART's 32-byte FIFO covers this cadence.
        const now = now_us();
        if (now < next_console_us) continue;
        next_console_us = now + 100;
        service_console();
        if (usb_controller.drivers()) |drivers| {
            var buffer: [64]u8 = undefined;
            const n = drivers.serial.read(&buffer);
            for (buffer[0..n]) |byte| {
                if (byte == '\n') {
                    if (overflow) emit("ERR line_too_long", .{}) else try command(line[0..length]);
                    length = 0;
                    overflow = false;
                } else if (length < line.len) {
                    line[length] = byte;
                    length += 1;
                } else overflow = true;
            }
        }
    }
}
