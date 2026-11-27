//! Board-only checks for the XIAO nRF52840 Sense. No external wiring is needed.
const std = @import("std");
const microzig = @import("microzig");
const nrf = microzig.hal;
const board = microzig.board;
const harness = @import("harness.zig");
const time = nrf.time;
const I2C_Device = microzig.drivers.base.I2C_Device;
const LSM6DS3TR_C = microzig.drivers.sensor.LSM6DS3TR_C;

pub const panic = microzig.panic;
pub const init = harness.init;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

const suite = "sense";
const led = board.led_r;
const pwm: nrf.pwm.Pwm = .pwm0;
const countertop = 2000;
// Static EasyDMA storage stays valid even if a STOPPED wait expires.
var pwm_words: [4]u16 align(4) = undefined;
var duty_storage: [1]u16 align(4) = undefined;
var mic_samples: [1024]i16 align(4) = undefined;
var mic_sink: [1024]i16 align(4) = undefined;

pub fn main() void {
    check_pwm() catch |err| harness.check(suite, "pwm", false, "{s}", .{@errorName(err)});
    check_pwm_shortcut(.seq1, "pwm_seq1_loop") catch |err| harness.check(suite, "pwm_seq1_loop", false, "{s}", .{@errorName(err)});
    check_pwm_shortcut(.seq0, "pwm_seq0_early_stop") catch |err| harness.check(suite, "pwm_seq0_early_stop", false, "{s}", .{@errorName(err)});
    check_imu() catch |err| harness.check(suite, "imu", false, "{s}", .{@errorName(err)});
    check_mic() catch |err| harness.check(suite, "pdm", false, "{s}", .{@errorName(err)});
    harness.finish(suite);
}

fn now_us() u64 {
    return time.get_time_since_boot().to_us();
}

fn near(actual: u64, expected: u64, tolerance: u64) bool {
    return actual >= expected - tolerance and actual <= expected + tolerance;
}

fn wait_pwm(comptime event: nrf.pwm.Event) bool {
    const deadline = now_us() + 20_000;
    while (now_us() < deadline) {
        if (pwm.take_event(event)) return true;
    }
    return false;
}

fn wait_pwm_stopped_latched() bool {
    const event = &microzig.chip.peripherals.PWM0.EVENTS_STOPPED;
    const deadline = now_us() + 20_000;
    while (now_us() < deadline) {
        if (event.read().EVENTS_STOPPED == .Generated) return true;
    }
    return false;
}

fn check_pwm() !void {
    // Keep the GPIO input buffer connected for the output readback. See nRF52840
    // PS v1.11 §6.9 GPIO and §6.17.4 PWM pin configuration.
    try pwm.init(.{
        .outputs = .{ .{ .pin = led, .idle = 1 }, null, null, null },
        .prescaler = .DIV_16,
        .countertop = countertop,
    });
    led.set_input_buffer(.connect);
    defer led.set_input_buffer(.disconnect);
    var running = false;
    defer {
        if (running) {
            pwm.request_stop();
            const stopped = wait_pwm(.stopped);
            harness.check(suite, "pwm_stop", stopped, "STOPPED={}", .{stopped});
            if (stopped) pwm.deinit();
        } else {
            pwm.deinit();
        }
    }

    for (&pwm_words, [_]u8{ 25, 50, 75, 50 }) |*word, percent|
        word.* = try nrf.pwm.duty_word(countertop, percent, false);
    try pwm.set_sequence(.seq0, .{ .words = &pwm_words, .refresh = 1 });
    try pwm.start(.seq0);
    running = true;
    if (!wait_pwm(.seq0_started)) return error.PwmStartTimeout;
    const started_at = now_us();

    // PS §6.17.1–2. At 1 MHz the period is 2000 us. REFRESH=1 holds each
    // entry for two periods. SEQEND fires as the fourth entry takes effect,
    // then the last value keeps running. Observe eight periods in all.
    var seqends: u32 = 0;
    var periods: u32 = 0;
    var seqend_at: u64 = 0;
    var first_period_at: u64 = 0;
    var last_period_at: u64 = 0;
    while (now_us() - started_at < 17_000) {
        if (pwm.take_event(.seq0_end)) {
            seqends += 1;
            seqend_at = now_us() - started_at;
        }
        if (pwm.take_event(.period_end)) {
            last_period_at = now_us();
            if (periods == 0) first_period_at = last_period_at;
            periods += 1;
        }
    }
    harness.check(suite, "pwm_seqend", seqends == 1 and near(seqend_at, 12_000, 300), "count={d} elapsed_us={d}", .{ seqends, seqend_at });
    const period_span = last_period_at - first_period_at;
    harness.check(suite, "pwm_periodend", periods == 8 and near(period_span, 14_000, 300), "count={d} first_to_last_us={d}", .{ periods, period_span });
    if (seqends == 0) return error.PwmSequenceTimeout;

    try check_pwm_level("pwm_zero", 0, 0);
    try check_pwm_level("pwm_full", 100, 1);
}

fn check_pwm_level(case: []const u8, percent: u8, expected: u1) !void {
    try pwm.play_duty(&duty_storage, percent, false);
    if (!wait_pwm(.seq0_end)) return error.PwmDutyTimeout;
    time.sleep_us(100);
    const level = led.read();
    harness.check(suite, case, level == expected, "pin={d} expected={d}", .{ level, expected });
}

fn check_pwm_shortcut(comptime slot: nrf.pwm.Slot, case: []const u8) !void {
    try pwm.init(.{
        .prescaler = .DIV_16,
        .countertop = countertop,
        .loops = 1,
        .shortcuts = switch (slot) {
            .seq0 => .{ .SEQEND0_STOP = .Enabled },
            .seq1 => .{ .LOOPSDONE_STOP = .Enabled },
        },
    });
    errdefer pwm.deinit(); // Errors before start leave DMA idle.

    pwm_words = @splat(try nrf.pwm.duty_word(countertop, 50, false));
    try pwm.set_sequence(slot, .{ .words = &pwm_words, .end_delay = if (slot == .seq0) 3 else 0 });
    try pwm.start(slot);
    // For SEQ0, leave STOPPED latched to check that start clears it.
    var stopped = if (slot == .seq0) wait_pwm_stopped_latched() else wait_pwm(.stopped);
    const configured_event = pwm.take_event(if (slot == .seq0) .seq0_end else .loops_done);
    const other_started = pwm.take_event(if (slot == .seq0) .seq1_started else .seq0_started);
    harness.check(suite, case, stopped and configured_event and !other_started, "STOPPED={} shortcut_event={} other_started={}", .{ stopped, configured_event, other_started });
    if (slot == .seq0 and stopped) {
        try pwm.start(slot);
        const stale_stop = pwm.take_event(.stopped);
        stopped = wait_pwm(.stopped);
        harness.check(suite, "pwm_restart", !stale_stop and stopped, "stale_stop={} new_stop={}", .{ stale_stop, stopped });
    }
    if (!stopped) pwm.request_stop();
    if (stopped or wait_pwm(.stopped)) pwm.deinit();
}

fn enable_sensor(power: nrf.gpio.Pin) void {
    power.set_drive_strength(.SOH1);
    power.put(1);
    power.set_direction(.out);
}

fn check_imu() !void {
    enable_sensor(board.imu_power_enable);
    defer board.imu_power_enable.put(0);
    // ST DocID030071 Rev 3 §4.2 Table 4 gives a 35 ms power-up time.
    time.sleep_ms(40);

    try ImuBus.bus.apply(.{ .scl_pin = board.imu_scl, .sda_pin = board.imu_sda });
    defer ImuBus.bus.reset();
    board.imu_scl.set_input_buffer(.connect);
    board.imu_sda.set_input_buffer(.connect);

    const imu: LSM6DS3TR_C = .{
        .bus = .{ .ptr = undefined, .vtable = &ImuBus.vtable },
        .address = board.imu_address,
    };
    const id = try imu.who_am_i();
    harness.check(suite, "imu_who_am_i", id == LSM6DS3TR_C.device_id, "id=0x{x:0>2}", .{id});
    if (id != LSM6DS3TR_C.device_id) return;

    try imu.configure();
    time.sleep_ms(150);
    const deadline = now_us() + 100_000;
    while (!try imu.data_ready()) {
        if (now_us() >= deadline) return error.ImuDataTimeout;
        time.sleep_ms(1);
    }
    const sample = try imu.read_sample();

    // ST §4.1 Table 3 gives 0.061 mg/LSB and 8.75 mdps/LSB. Use vector
    // magnitudes so the checks do not depend on which way the board is lying.
    const accel_mg = magnitude(sample.accel) * LSM6DS3TR_C.accel_mg_per_lsb;
    const gyro_mdps = magnitude(sample.gyro) * LSM6DS3TR_C.gyro_mdps_per_lsb;
    harness.check(suite, "imu_accel", accel_mg >= 700 and accel_mg <= 1300, "mg={d:.1}", .{accel_mg});
    harness.check(suite, "imu_gyro", gyro_mdps <= 15_000, "mdps={d:.1}", .{gyro_mdps});
}

fn magnitude(vector: [3]i16) f32 {
    var squares: f32 = 0;
    for (vector) |axis| {
        const value: f32 = @floatFromInt(axis);
        squares += value * value;
    }
    return @sqrt(squares);
}

// Stage register transactions in DMA-safe RAM. The register read uses
// a repeated START. A timeout requests STOP and may leave DMA in flight,
// so the storage stays allocated after the adapter returns.
const ImuBus = struct {
    const bus = nrf.i2cdma.num(0);
    const timeout: microzig.drivers.time.Duration = .from_ms(20);
    var tx: [4]u8 align(4) = undefined;
    var rx: [12]u8 align(4) = undefined;

    const vtable: I2C_Device.VTable = .{
        .writev_fn = writev,
        .readv_fn = null,
        .writev_then_readv_fn = writev_then_readv,
    };

    fn writev(_: *anyopaque, address: I2C_Device.Address, writes: []const []const u8) I2C_Device.InterfaceError!void {
        const buffer = try stage_write(writes);
        bus.write_blocking(address, buffer, timeout) catch |err| return bus_error(err);
    }

    fn writev_then_readv(_: *anyopaque, address: I2C_Device.Address, writes: []const []const u8, reads: []const []u8) I2C_Device.InterfaceError!void {
        if (reads.len != 1 or reads[0].len > rx.len) return error.Unsupported;
        const buffer = try stage_write(writes);
        const receive = rx[0..reads[0].len];
        bus.write_then_read_blocking(address, buffer, receive, timeout) catch |err| return bus_error(err);
        asm volatile ("dmb" ::: .{ .memory = true });
        @memcpy(reads[0], receive);
    }

    fn stage_write(writes: []const []const u8) I2C_Device.InterfaceError![]const u8 {
        if (writes.len != 1 or writes[0].len > tx.len) return error.Unsupported;
        const buffer = tx[0..writes[0].len];
        @memcpy(buffer, writes[0]);
        asm volatile ("dmb" ::: .{ .memory = true });
        return buffer;
    }

    fn bus_error(err: nrf.i2cdma.Error) I2C_Device.InterfaceError {
        return switch (err) {
            error.Overrun, error.Receive, error.TooMuchData, error.Transmit => error.UnknownAbort,
            else => |other| other,
        };
    }
};

fn wait_pdm(pdm: *nrf.pdm.Pdm, comptime event: nrf.pdm.Event) bool {
    const deadline = now_us() + 100_000;
    while (now_us() < deadline) {
        if (pdm.take_event(event)) return true;
    }
    return false;
}

fn fill_mic_buffer(pdm: *nrf.pdm.Pdm) !void {
    if (!wait_pdm(pdm, .started)) return error.PdmStartTimeout;
    // Use a shorter view of a full-sized allocation so a regression cannot
    // make DMA overwrite adjacent storage.
    if (pdm.queue_buffer(mic_sink[0 .. mic_sink.len / 2])) |_| {
        return error.PdmAcceptedShortBuffer;
    } else |err| {
        if (err != error.InvalidBufferLength) return err;
    }
    try pdm.queue_buffer(&mic_sink);
    if (!wait_pdm(pdm, .end)) return error.PdmEndTimeout;
    harness.check(suite, "pdm_buffer_length", true, "short replacement rejected", .{});
}

fn check_mic() !void {
    enable_sensor(board.mic_power_enable);
    defer board.mic_power_enable.put(0);
    // MSM261D3526H1CPM v1.2 p. 3. Allow 20 ms for power-up and choose a
    // 1.28 MHz clock within the microphone's standard performance range.
    time.sleep_ms(25);
    board.mic_data.set_pull(.down);
    defer board.mic_data.set_pull(.disabled);
    var pdm = try nrf.pdm.Pdm.init(.{
        .clk = board.mic_clk,
        .din = board.mic_data,
        .frequency = .@"1280K",
        .ratio = .Ratio80,
        .operation = .Stereo,
    });
    var dma_idle = true;
    defer if (dma_idle) {
        pdm.deinit() catch |err| harness.check(suite, "pdm_deinit", false, "{s}", .{@errorName(err)});
    };

    try pdm.start(&mic_samples);
    const filled = fill_mic_buffer(&pdm);
    // STOPPED confirms DMA is done even if the replacement missed its boundary.
    pdm.request_stop();
    dma_idle = wait_pdm(&pdm, .stopped);
    harness.check(suite, "pdm_stop", dma_idle, "STOPPED={}", .{dma_idle});
    try filled;
    if (!dma_idle) return;

    // Check both sampling edges separately. Stereo stores alternating samples
    // from the two edges, and the board has one mic. Drop 12 ms for the mic
    // mode-change time and decimator startup (MSM261D3526H1CPM v1.2 p. 3
    // and nRF52840 PS §6.15.4).
    const settled = mic_samples[384..];
    var min = [2]i16{ std.math.maxInt(i16), std.math.maxInt(i16) };
    var max = [2]i16{ std.math.minInt(i16), std.math.minInt(i16) };
    for (settled, 0..) |sample, i| {
        const channel = i % 2;
        min[channel] = @min(min[channel], sample);
        max[channel] = @max(max[channel], sample);
    }
    harness.check(suite, "pdm_samples", min[0] < max[0] or min[1] < max[1], "left={d}..{d} right={d}..{d}", .{ min[0], max[0], min[1], max[1] });
    // With EDGE = LeftFalling the right slot holds the rising-edge sample. The
    // board's mic has L/R tied to ground and drives the rising edge (measured
    // on this board: board.mic_edge); the falling-edge slot reads the
    // pulled-down data line, a constant near negative full scale.
    const mic = 1 - @as(usize, @intFromBool(board.mic_edge == .LeftFalling));
    const idle = 1 - mic;
    const mic_moves = @as(i32, max[mic]) - min[mic] > 100 and min[mic] > -25_000;
    const idle_low = max[idle] < -25_000;
    harness.check(suite, "pdm_mic_edge", mic_moves and idle_low, "mic={d}..{d} idle={d}..{d}", .{ min[mic], max[mic], min[idle], max[idle] });
}
