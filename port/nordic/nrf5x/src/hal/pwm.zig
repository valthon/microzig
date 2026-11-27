//! nRF52840 Product Specification v1.11 §6.17, PWM.
const std = @import("std");
const microzig = @import("microzig");
const gpio = @import("gpio.zig");
const compatibility = @import("compatibility.zig");

const peripherals = microzig.chip.peripherals;
const Regs = microzig.chip.types.peripherals.PWM0;
const Decoder = @FieldType(Regs, "DECODER").underlying_type;

pub const CounterMode = @FieldType(@FieldType(Regs, "MODE").underlying_type, "UPDOWN");
pub const Prescaler = @FieldType(@FieldType(Regs, "PRESCALER").underlying_type, "PRESCALER");
pub const Load = @FieldType(Decoder, "LOAD");
pub const Advance = @FieldType(Decoder, "MODE");
pub const Shortcuts = @FieldType(Regs, "SHORTS").underlying_type;

pub const Output = struct {
    pin: gpio.Pin,
    idle: u1 = 0,
};

pub const Config = struct {
    outputs: [4]?Output = @splat(null),
    mode: CounterMode = .Up,
    prescaler: Prescaler = .DIV_1,
    countertop: u15,
    load: Load = .Common,
    advance: Advance = .RefreshCount,
    loops: u16 = 0,
    shortcuts: Shortcuts = .{},
};

pub const Slot = enum(u1) { seq0, seq1 };

pub const Sequence = struct {
    /// EasyDMA expects data RAM. Keep the words alive and immutable while the slot
    /// can be read, including on automatic loop restarts.
    words: []align(4) const u16,
    refresh: u24 = 0,
    end_delay: u24 = 0,
};

pub const Event = enum { stopped, seq0_started, seq1_started, seq0_end, seq1_end, period_end, loops_done };

/// High time in whole percent, or low time with active_low set. Falling-edge
/// polarity gives 0 and COUNTERTOP as the constant-low and constant-high limits.
pub fn duty_word(countertop: u15, percent: u8, active_low: bool) error{InvalidDuty}!u16 {
    if (percent > 100) return error.InvalidDuty;
    const compare: u16 = @intCast((@as(u32, countertop) * percent + 50) / 100);
    return compare | (if (active_low) @as(u16, 0) else 0x8000);
}

/// Use one owner per instance. Serialize calls and event consumption with any ISR
/// using the same peripheral.
pub const Pwm = enum {
    pwm0,
    pwm1,
    pwm2,
    pwm3,

    fn regs(pwm: Pwm) *volatile Regs {
        if (comptime compatibility.chip != .nrf52840)
            compatibility.unsupported_chip("PWM");
        return switch (pwm) {
            .pwm0 => peripherals.PWM0,
            .pwm1 => peripherals.PWM1,
            .pwm2 => peripherals.PWM2,
            .pwm3 => peripherals.PWM3,
        };
    }

    /// Initialize a disabled instance. GPIO input buffers keep their prior settings.
    pub fn init(pwm: Pwm, config: Config) error{ Busy, InvalidConfig }!void {
        const r = pwm.regs();
        if (r.ENABLE.read().ENABLE == .Enabled) return error.Busy;
        if (config.countertop < 3 or (config.load == .WaveForm and config.outputs[3] != null))
            return error.InvalidConfig;
        for (config.outputs, 0..) |output, i| {
            if (output) |out| {
                for (config.outputs[0..i]) |previous| {
                    if (previous) |other| {
                        if (other.pin == out.pin) return error.InvalidConfig;
                    }
                }
            }
        }

        r.MODE.write(.{ .UPDOWN = config.mode });
        r.PRESCALER.write(.{ .PRESCALER = config.prescaler });
        r.COUNTERTOP.write(.{ .COUNTERTOP = config.countertop });
        r.DECODER.write(.{ .LOAD = config.load, .MODE = config.advance });
        r.LOOP.write(.{ .CNT = @fromBackingInt(config.loops) });
        r.SHORTS.write(config.shortcuts);
        for (&r.SEQ) |*seq| seq.CNT.write(.{ .CNT = .Disabled });
        inline for (std.enums.values(Event)) |event| _ = pwm.take_event(event);
        for (&r.PSEL.OUT, config.outputs) |*select, output| {
            if (output) |out| {
                out.pin.put(out.idle);
                out.pin.set_direction(.out);
                select.write(.{ .PIN = out.pin.index(), .PORT = out.pin.port(), .CONNECT = .Connected });
            } else {
                select.write(.{ .CONNECT = .Disconnected });
            }
        }
        r.ENABLE.write(.{ .ENABLE = .Enabled });
    }

    /// Program before playback or at a safe update point in PS §6.17.2.
    pub fn set_sequence(pwm: Pwm, slot: Slot, sequence: Sequence) error{ Disabled, InvalidSequence, NotInRam }!void {
        const r = pwm.regs();
        if (r.ENABLE.read().ENABLE != .Enabled) return error.Disabled;
        const load = r.DECODER.read().LOAD;
        const stride: usize = switch (load) {
            .Common => 1,
            .Grouped => 2,
            .Individual, .WaveForm => 4,
        };
        const words = sequence.words;
        if (words.len == 0 or words.len > std.math.maxInt(u15) or words.len % stride != 0)
            return error.InvalidSequence;
        // PS §4.2 Memory and §6.17.2. Validate the whole EasyDMA range.
        const address = @intFromPtr(words.ptr);
        if (address < 0x2000_0000 or address > 0x2004_0000 - words.len * @sizeOf(u16))
            return error.NotInRam;
        if (load == .WaveForm) {
            var i: usize = 3;
            while (i < words.len) : (i += 4) {
                if (words[i] < 3 or words[i] > std.math.maxInt(u15)) return error.InvalidSequence;
            }
        }

        asm volatile ("dmb" ::: .{ .memory = true });
        const seq = &r.SEQ[@backingInt(slot)];
        seq.PTR.write(.{ .PTR = address });
        seq.CNT.write(.{ .CNT = @fromBackingInt(@as(u15, @intCast(words.len))) });
        seq.REFRESH.write(.{ .CNT = @fromBackingInt(sequence.refresh) });
        seq.ENDDELAY.write(.{ .CNT = sequence.end_delay });
    }

    /// Apply a fixed duty to every connected output in common-load, single-shot
    /// mode with no shortcuts. Call before starting or after the previous
    /// single-shot SEQEND. Keep storage alive until this call's SEQEND.
    pub fn play_duty(pwm: Pwm, storage: *align(4) [1]u16, percent: u8, active_low: bool) !void {
        const r = pwm.regs();
        if (r.ENABLE.read().ENABLE != .Enabled) return error.Disabled;
        if (r.DECODER.read().LOAD != .Common or r.LOOP.read().CNT != .Disabled or r.SHORTS.raw != 0)
            return error.InvalidConfig;
        const word = try duty_word(r.COUNTERTOP.read().COUNTERTOP, percent, active_low);
        // Check the DMA range before writing to storage or starting the task.
        try pwm.set_sequence(.seq0, .{ .words = storage });
        storage[0] = word;
        try pwm.start(.seq0);
    }

    /// Start a programmed slot and clear all playback event latches. With loops
    /// or restart shortcuts, program every slot that may run. If a stop is
    /// pending, wait for it to complete before starting again.
    /// The cleared latches are a clean baseline only for a stopped instance:
    /// a waveform still being driven (after SEQEND, as `play_duty` allows) can
    /// raise PWMPERIODEND between the clear and the new SEQSTARTED. A caller
    /// that counts periods or times them restarts from STOPPED, or counts from
    /// the SEQSTARTED of this call.
    pub fn start(pwm: Pwm, slot: Slot) error{ Disabled, MissingSequence }!void {
        const r = pwm.regs();
        if (r.ENABLE.read().ENABLE != .Enabled) return error.Disabled;
        const index = @backingInt(slot);
        const seq = &r.SEQ[index];
        if (seq.CNT.read().CNT == .Disabled) return error.MissingSequence;
        const loops = @backingInt(r.LOOP.read().CNT);
        const shorts = r.SHORTS.read();
        // PS §6.17.2: each loop ends with SEQ1. Starting at SEQ1 uses
        // up the first loop before SEQ0 can run.
        const other_slot_can_run = switch (slot) {
            .seq0 => loops != 0,
            .seq1 => loops > 1 or (loops == 1 and shorts.LOOPSDONE_SEQSTART0 == .Enabled),
        };
        if (other_slot_can_run and r.SEQ[1 - index].CNT.read().CNT == .Disabled) {
            const stop_on_seqend = switch (slot) {
                .seq0 => shorts.SEQEND0_STOP == .Enabled,
                .seq1 => shorts.SEQEND1_STOP == .Enabled,
            };
            // PS §6.17.2: SEQEND fires when the last value is applied. STOP
            // completes at the end of that period, ahead of a delayed chain.
            // NextStep and the last SEQ1 of a loop ignore these delays.
            const stop_before_chain = stop_on_seqend and (slot == .seq0 or loops > 1) and
                r.DECODER.read().MODE == .RefreshCount and
                (seq.REFRESH.read().CNT != .Continuous or seq.ENDDELAY.read().CNT != 0);
            if (!stop_before_chain) return error.MissingSequence;
        }
        inline for (std.enums.values(Event)) |event| _ = pwm.take_event(event);
        asm volatile ("dmb" ::: .{ .memory = true });
        r.TASKS_SEQSTART[index].write(.{ .TASKS_SEQSTART = .Trigger });
    }

    pub fn next_step(pwm: Pwm) void {
        pwm.regs().TASKS_NEXTSTEP.write(.{ .TASKS_NEXTSTEP = .Trigger });
    }

    /// Request an end-of-period stop. Wait for STOPPED before disabling the
    /// peripheral or reusing active buffers. Clears the configured shortcuts.
    pub fn request_stop(pwm: Pwm) void {
        const r = pwm.regs();
        r.SHORTS.write(.{});
        _ = pwm.take_event(.stopped);
        r.TASKS_STOP.write(.{ .TASKS_STOP = .Trigger });
    }

    /// Call before starting or after STOPPED. Output pins retain their GPIO idle levels.
    pub fn deinit(pwm: Pwm) void {
        const r = pwm.regs();
        r.ENABLE.write(.{ .ENABLE = .Disabled });
        for (&r.PSEL.OUT) |*select| select.write(.{ .CONNECT = .Disconnected });
    }

    /// Polls and acknowledges one latched event. Repeated hardware events can
    /// coalesce if the caller does not check before the next one arrives.
    pub fn take_event(pwm: Pwm, comptime event: Event) bool {
        const r = pwm.regs();
        const reg = switch (event) {
            .stopped => &r.EVENTS_STOPPED,
            .seq0_started => &r.EVENTS_SEQSTARTED[0],
            .seq1_started => &r.EVENTS_SEQSTARTED[1],
            .seq0_end => &r.EVENTS_SEQEND[0],
            .seq1_end => &r.EVENTS_SEQEND[1],
            .period_end => &r.EVENTS_PWMPERIODEND,
            .loops_done => &r.EVENTS_LOOPSDONE,
        };
        if (reg.raw == 0) return false;
        reg.write(.{});
        _ = reg.raw; // PS §6.1, delay after clearing an event.
        asm volatile ("dmb" ::: .{ .memory = true });
        return true;
    }
};
