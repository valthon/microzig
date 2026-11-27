//! nRF52840 Product Specification v1.11 §6.15, PDM.
const std = @import("std");
const microzig = @import("microzig");
const gpio = @import("gpio.zig");
const compatibility = @import("compatibility.zig");

const Regs = microzig.chip.types.peripherals.PDM;
const Mode = @FieldType(Regs, "MODE").underlying_type;

pub const Frequency = @FieldType(@FieldType(Regs, "PDMCLKCTRL").underlying_type, "FREQ");
pub const Ratio = @FieldType(@FieldType(Regs, "RATIO").underlying_type, "RATIO");
pub const Operation = @FieldType(Mode, "OPERATION");
pub const Edge = @FieldType(Mode, "EDGE");

pub const Config = struct {
    clk: gpio.Pin,
    din: gpio.Pin,
    frequency: Frequency = .Default,
    ratio: Ratio = .Ratio64,
    operation: Operation = .Mono,
    edge: Edge = .LeftFalling,
    /// Relative to the default peripheral gain, in 0.5 dB steps (-40 to +40).
    left_gain: i8 = 0,
    right_gain: i8 = 0,
};

pub const Event = enum { started, end, stopped };
pub const Buffer = []align(4) i16;
const BufferError = error{ InvalidBufferLength, NotInRam };

/// Owns the singleton PDM until deinit. Keep a single copy and serialize
/// calls, including event handling, with any ISR using the same peripheral.
pub const Pdm = struct {
    state: enum { idle, running, stopping, closed },

    fn regs() *volatile Regs {
        if (comptime compatibility.chip != .nrf52840)
            compatibility.unsupported_chip("PDM");
        return microzig.chip.peripherals.PDM;
    }

    pub fn init(config: Config) error{ Busy, InvalidConfig }!Pdm {
        const r = regs();
        if (r.ENABLE.read().ENABLE == .Enabled) return error.Busy;
        if (config.clk == config.din or
            config.left_gain < -40 or config.left_gain > 40 or
            config.right_gain < -40 or config.right_gain > 40)
            return error.InvalidConfig;
        switch (config.frequency) {
            .@"1000K", .Default, .@"1067K", .@"1231K", .@"1280K", .@"1333K" => {},
            else => return error.InvalidConfig,
        }

        // PS §6.15.6, configure GPIO and pin selection before enabling PDM.
        config.clk.put(0);
        config.clk.set_direction(.out);
        config.din.set_direction(.in);
        config.din.set_input_buffer(.connect);
        r.PSEL.CLK.write(.{ .PIN = config.clk.index(), .PORT = config.clk.port(), .CONNECT = .Connected });
        r.PSEL.DIN.write(.{ .PIN = config.din.index(), .PORT = config.din.port(), .CONNECT = .Connected });
        r.PDMCLKCTRL.write(.{ .FREQ = config.frequency });
        r.RATIO.write(.{ .RATIO = config.ratio });
        r.MODE.write(.{ .OPERATION = config.operation, .EDGE = config.edge });
        r.GAINL.write(.{ .GAINL = @fromBackingInt(@as(u7, @intCast(40 + config.left_gain))) });
        r.GAINR.write(.{ .GAINR = @fromBackingInt(@as(u7, @intCast(40 + config.right_gain))) });
        r.INTEN.write(.{});
        r.ENABLE.write(.{ .ENABLE = .Enabled });
        return .{ .state = .idle };
    }

    /// Start receiving signed PCM into data RAM. A buffer must hold an even
    /// number of samples. Stereo stores interleaved left/right samples.
    /// The buffer follows the same ownership rules as a queued buffer.
    pub fn start(pdm: *Pdm, buffer: Buffer) (BufferError || error{ Busy, Closed })!void {
        switch (pdm.state) {
            .idle => {},
            .closed => return error.Closed,
            .running, .stopping => return error.Busy,
        }
        const address = try buffer_address(buffer);
        inline for (std.enums.values(Event)) |event| _ = pdm.take_event(event);
        const r = regs();
        r.SAMPLE.MAXCNT.write(.{ .BUFFSIZE = @intCast(buffer.len) });
        set_buffer_pointer(address);
        pdm.state = .running;
        r.TASKS_START.write(.{ .TASKS_START = .Trigger });
    }

    /// Queue the next disjoint buffer after observing STARTED and before the
    /// current buffer fills. Queue once per STARTED. Each replacement must
    /// match the length passed to start. PS §6.15.4 documents a double-buffered
    /// pointer, with no atomic pointer/count update. Holding MAXCNT fixed
    /// keeps either latched address valid at the boundary. EasyDMA can reuse the
    /// current buffer if it misses the replacement. Keep each buffer alive
    /// and untouched until its END and a subsequent STARTED that you can
    /// attribute to a disjoint replacement, or until STOPPED. If a boundary
    /// was missed or the switch is uncertain, wait for STOPPED.
    pub fn queue_buffer(pdm: *Pdm, buffer: Buffer) (BufferError || error{NotRunning})!void {
        if (pdm.state != .running) return error.NotRunning;
        if (buffer.len != regs().SAMPLE.MAXCNT.read().BUFFSIZE) return error.InvalidBufferLength;
        set_buffer_pointer(try buffer_address(buffer));
    }

    fn buffer_address(buffer: Buffer) BufferError!u32 {
        if (buffer.len == 0 or buffer.len > std.math.maxInt(u15) or buffer.len % 2 != 0)
            return error.InvalidBufferLength;
        // PS §4.2 and §6.15.4. DMA writes complete 32-bit words into Data RAM.
        const address = @intFromPtr(buffer.ptr);
        if (address < 0x2000_0000 or address > 0x2004_0000 - buffer.len * @sizeOf(i16))
            return error.NotInRam;
        return address;
    }

    fn set_buffer_pointer(address: u32) void {
        asm volatile ("dmb" ::: .{ .memory = true });
        regs().SAMPLE.PTR.write(.{ .SAMPLEPTR = address });
    }

    /// STOPPED releases all DMA buffers. END during stop may be a partial buffer.
    pub fn request_stop(pdm: *Pdm) void {
        if (pdm.state != .running) return;
        pdm.state = .stopping;
        regs().TASKS_STOP.write(.{ .TASKS_STOP = .Trigger });
    }

    /// Poll and acknowledge a latched event. END reports a transfer boundary.
    /// The buffer reuse rules are documented on queue_buffer. Consume STOPPED
    /// before restarting or deinitializing. A bounded wait belongs to the caller.
    pub fn take_event(pdm: *Pdm, comptime event: Event) bool {
        if (pdm.state == .closed) return false;
        const r = regs();
        const reg = switch (event) {
            .started => &r.EVENTS_STARTED,
            .end => &r.EVENTS_END,
            .stopped => &r.EVENTS_STOPPED,
        };
        if (reg.raw == 0) return false;
        reg.write(.{});
        _ = reg.raw; // PS §6.1, delay after clearing an event.
        asm volatile ("dmb" ::: .{ .memory = true });
        if (event == .stopped) pdm.state = .idle;
        return true;
    }

    pub fn deinit(pdm: *Pdm) error{Busy}!void {
        switch (pdm.state) {
            .closed => return,
            .idle => {},
            .running, .stopping => return error.Busy,
        }
        const r = regs();
        r.ENABLE.write(.{ .ENABLE = .Disabled });
        r.PSEL.CLK.write(.{ .CONNECT = .Disconnected });
        r.PSEL.DIN.write(.{ .CONNECT = .Disconnected });
        pdm.state = .closed;
    }
};
