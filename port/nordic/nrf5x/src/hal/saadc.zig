//! Blocking, task-triggered SAADC for nRF52840. Serialize access to the peripheral.
const microzig = @import("microzig");
const time = microzig.hal.time;
const Absolute = microzig.drivers.time.Absolute;
const saadc = microzig.chip.peripherals.SAADC;
const ch = &saadc.CH[0];

pub const Input = @FieldType(@TypeOf(ch.PSELP.read()), "PSELP");
pub const Gain = @FieldType(@TypeOf(ch.CONFIG.read()), "GAIN");
pub const Reference = @FieldType(@TypeOf(ch.CONFIG.read()), "REFSEL");
pub const Acquisition = @FieldType(@TypeOf(ch.CONFIG.read()), "TACQ");
pub const Resolution = @FieldType(@TypeOf(saadc.RESOLUTION.read()), "VAL");
pub const Oversampling = @FieldType(@TypeOf(saadc.OVERSAMPLE.read()), "OVERSAMPLE");

pub const Channel = struct {
    positive: Input,
    negative: ?Input = null,
    gain: Gain = .Gain1_6,
    reference: Reference = .Internal,
    acquisition: Acquisition = .@"10us",
    resolution: Resolution = .@"12bit",
    oversampling: Oversampling = .Bypass,
    low: i16 = -32768,
    high: i16 = 32767,
};

pub const LimitEvents = struct {
    low: bool,
    high: bool,
};

pub const Error = error{ Busy, InvalidChannel, InvalidBuffer, Timeout, StopTimeout };

fn expired(deadline: Absolute) bool {
    return deadline.is_reached_by(time.get_time_since_boot());
}

fn wait(event: anytype, deadline: Absolute) bool {
    while (event.raw == 0) {
        if (expired(deadline)) return false;
    }
    return true;
}

// PS v1.11 §6.23.4: END and STOPPED acknowledge that EasyDMA has released RAM.
fn stop() bool {
    saadc.EVENTS_STOPPED.write_raw(0);
    saadc.TASKS_STOP.write_raw(1);
    return wait(&saadc.EVENTS_STOPPED, microzig.drivers.time.make_timeout_us(time.get_time_since_boot(), 2_000));
}

/// Run before first sampling and after ambient changes greater than 10 °C
/// (PS v1.11 §6.23.6). Calibration always runs outside a sampling session
/// (nRF52840 anomalies 237 and 252).
pub fn calibrate_offset(deadline: Absolute) Error!void {
    if (saadc.ENABLE.read().ENABLE == .Enabled) return error.Busy;
    saadc.ENABLE.write(.{ .ENABLE = .Enabled });

    saadc.EVENTS_CALIBRATEDONE.write_raw(0);
    saadc.TASKS_CALIBRATEOFFSET.write_raw(1);
    const calibrated = wait(&saadc.EVENTS_CALIBRATEDONE, deadline);
    if (!stop()) return error.StopTimeout;
    saadc.ENABLE.write(.{ .ENABLE = .Disabled });
    if (!calibrated) return error.Timeout;
}

/// Like sample_buffer, with a single caller-owned EasyDMA slot.
pub fn sample(channel: Channel, result: *align(4) i16, deadline: Absolute) Error!i16 {
    const buffer: *align(4) [1]i16 = @ptrCast(result);
    try sample_buffer(channel, buffer, deadline);
    return result.*;
}

/// Fill a Data RAM buffer with signed, little-endian results (PS v1.11
/// §§6.23.2–6.23.4). On StopTimeout, keep the buffer reserved and untouched
/// until reset. The peripheral stays enabled so subsequent calls return Busy.
pub fn sample_buffer(channel: Channel, buffer: []align(4) i16, deadline: Absolute) Error!void {
    if (saadc.ENABLE.read().ENABLE == .Enabled) return error.Busy;
    if (channel.positive == .NC or channel.negative == .NC or channel.low > channel.high or
        (channel.resolution == .@"14bit" and channel.oversampling == .Bypass))
        return error.InvalidChannel;
    if (buffer.len == 0 or buffer.len > 32767) return error.InvalidBuffer;
    const address = @intFromPtr(buffer.ptr);
    for (microzig.config.memory_regions) |region| {
        if (region.tag == .ram and address >= region.offset and
            address - region.offset <= region.length and
            buffer.len * @sizeOf(i16) <= region.length - (address - region.offset)) break;
    } else return error.InvalidBuffer;

    for (&saadc.CH) |*unused| {
        unused.PSELP.write(.{ .PSELP = .NC });
        unused.PSELN.write(.{ .PSELN = .NC });
    }
    ch.PSELP.write(.{ .PSELP = channel.positive });
    const negative: Input = channel.negative orelse .NC;
    ch.PSELN.write(.{ .PSELN = @fromBackingInt(@intCast(@backingInt(negative))) });
    ch.CONFIG.write(.{
        .GAIN = channel.gain,
        .REFSEL = channel.reference,
        .TACQ = channel.acquisition,
        .MODE = if (channel.negative == null) .SE else .Diff,
        .BURST = if (channel.oversampling == .Bypass) .Disabled else .Enabled,
    });
    ch.LIMIT.write(.{ .LOW = @bitCast(channel.low), .HIGH = @bitCast(channel.high) });
    saadc.RESOLUTION.write(.{ .VAL = channel.resolution });
    saadc.OVERSAMPLE.write(.{ .OVERSAMPLE = channel.oversampling });
    saadc.SAMPLERATE.write(.{ .MODE = .Task });
    saadc.RESULT.PTR.write(.{ .PTR = address });
    saadc.RESULT.MAXCNT.write(.{ .MAXCNT = @intCast(buffer.len) });
    saadc.EVENTS_CH[0].LIMITL.write_raw(0);
    saadc.EVENTS_CH[0].LIMITH.write_raw(0);

    asm volatile ("dmb" ::: .{ .memory = true });
    saadc.ENABLE.write(.{ .ENABLE = .Enabled });
    const filled = convert(buffer.len, deadline);
    // Even on timeout, obtain a DMA-release event before returning the buffer.
    if (!stop() and saadc.EVENTS_END.raw == 0) return error.StopTimeout;
    // Order caller accesses to the buffer after the observed DMA release.
    asm volatile ("dmb" ::: .{ .memory = true });
    saadc.ENABLE.write(.{ .ENABLE = .Disabled });
    if (!filled) return error.Timeout;
}

fn convert(count: usize, deadline: Absolute) bool {
    saadc.EVENTS_STARTED.write_raw(0);
    saadc.EVENTS_END.write_raw(0);
    saadc.TASKS_START.write_raw(1);
    if (!wait(&saadc.EVENTS_STARTED, deadline)) return false;

    // In burst mode RESULTDONE corresponds to the averaged sample. END
    // acknowledges the final DMA write.
    // No new SAMPLE task once the deadline has passed, even if the previous
    // event arrived just in time.
    for (0..count - 1) |_| {
        if (expired(deadline)) return false;
        saadc.EVENTS_RESULTDONE.write_raw(0);
        saadc.TASKS_SAMPLE.write_raw(1);
        if (!wait(&saadc.EVENTS_RESULTDONE, deadline)) return false;
    }
    if (expired(deadline)) return false;
    saadc.TASKS_SAMPLE.write_raw(1);
    return wait(&saadc.EVENTS_END, deadline) and saadc.RESULT.AMOUNT.read().AMOUNT == count;
}

/// Sticky limit events for the last conversion, cleared by the next one
/// (PS v1.11 §6.23.5).
pub fn limit_events() LimitEvents {
    return .{
        .low = saadc.EVENTS_CH[0].LIMITL.raw != 0,
        .high = saadc.EVENTS_CH[0].LIMITH.raw != 0,
    };
}
