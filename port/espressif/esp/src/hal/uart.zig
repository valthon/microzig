//! Blocking ESP32-C3/C6 HP UARTs. Each controller must have one exclusive owner;
//! do not share it with interrupts, DMA, ROM logging, or another handle.

const chip_specific = switch (@import("compatibility.zig").chip) {
    .esp32_c3 => @import("uart/esp32_c3.zig"),
    .esp32_c6 => @import("uart/esp32_c6.zig"),
};

const microzig = @import("microzig");
const gpio = @import("gpio.zig");
const time = @import("time.zig");
const mtime = microzig.drivers.time;
const timing = @import("uart/timing.zig");
const StreamDevice = microzig.drivers.base.StreamDevice;

pub const Error = error{ Timeout, FrameError, ParityError, Overflow };
pub const ConfigError = timing.Error || error{Timeout};
pub const Parity = enum { none, even, odd };
pub const DataBits = enum(u2) { five, six, seven, eight };
pub const StopBits = enum(u2) { one = 1, one_and_half = 2, two = 3 };
pub const Config = struct {
    baud_rate: u32 = 115200,
    data_bits: DataBits = .eight,
    parity: Parity = .none,
    stop_bits: StopBits = .one,
};

pub const instance = struct {
    pub fn num(index: u1) UART {
        return .{ .index = index };
    }
};

pub const UART = struct {
    index: u1,

    fn regs(self: UART) *volatile microzig.chip.types.peripherals.UART0 {
        return switch (self.index) {
            0 => microzig.chip.peripherals.UART0,
            1 => microzig.chip.peripherals.UART1,
        };
    }

    /// Destructively initializes this UART. Uses the 40 MHz XTAL, independent
    /// of CPU/APB frequency changes (C3 TRM v1.4 §§26.4.1, 26.5.2;
    /// C6 TRM v1.2 §§27.4.1, 27.5.2).
    pub fn init(self: UART, config: Config) ConfigError!void {
        try chip_specific.init(self.index, config);
    }

    /// The same pad can be passed for TX and RX for external-pad loopback.
    /// GPIO matrix routing: TRM v1.4 §§5.4, 5.5.
    pub fn connect_pins(self: UART, pins: struct { tx: ?gpio.Pin = null, rx: ?gpio.Pin = null }) void {
        if (pins.tx) |pin| {
            pin.put(1);
            // Keep the input path available when another UART receives on
            // this pad, too (e.g. a parity mismatch test).
            pin.apply(.{ .output_enable = true, .input_enable = true });
            pin.connect_peripheral_to_output(.{ .signal = if (self.index == 0) .u0txd else .u1txd });
        }
        if (pins.rx) |pin| {
            if (pins.tx == null or pins.tx.? != pin)
                pin.apply(.{ .input_enable = true });
            pin.connect_input_to_peripheral(.{ .signal = if (self.index == 0) .u0rxd else .u1rxd });
        }
    }

    /// Nonblocking FIFO access. RX errors remain latched until init or
    /// clear_rx_errors; the caller must discard data belonging to a bad frame.
    pub fn check_rx_errors(self: UART) Error!void {
        const flags = self.regs().INT_RAW.read();
        if (flags.RXFIFO_OVF_INT_RAW != 0) return error.Overflow;
        if (flags.PARITY_ERR_INT_RAW != 0) return error.ParityError;
        if (flags.FRM_ERR_INT_RAW != 0) return error.FrameError;
    }

    pub fn clear_rx_errors(self: UART) void {
        self.regs().INT_CLR.write(.{ .RXFIFO_OVF_INT_CLR = 1, .PARITY_ERR_INT_CLR = 1, .FRM_ERR_INT_CLR = 1 });
    }

    pub fn try_write(self: UART, bytes: []const u8) usize {
        const r = self.regs();
        const count = @min(bytes.len, 128 - r.STATUS.read().TXFIFO_CNT);
        for (bytes[0..count]) |byte| r.FIFO.write_raw(byte);
        return count;
    }

    pub fn try_read(self: UART, bytes: []u8) Error!usize {
        try self.check_rx_errors();
        const r = self.regs();
        const count = @min(bytes.len, r.STATUS.read().RXFIFO_CNT);
        for (bytes[0..count]) |*byte| byte.* = r.FIFO.read().RXFIFO_RD_BYTE;
        try self.check_rx_errors();
        return count;
    }

    /// Enqueues every byte. Use flush_blocking to wait for the final stop bit.
    /// null timeout explicitly requests an unbounded wait, as in hal.i2c.
    pub fn write_blocking(self: UART, bytes: []const u8, timeout: ?mtime.Duration) error{Timeout}!void {
        try self.write_deadline(bytes, mtime.Deadline.init_relative(time.get_time_since_boot(), timeout));
    }

    pub fn write_deadline(self: UART, bytes: []const u8, deadline: mtime.Deadline) error{Timeout}!void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            try check_deadline(deadline);
            pos += self.try_write(bytes[pos..]);
        }
    }

    pub fn read_blocking(self: UART, bytes: []u8, timeout: ?mtime.Duration) Error!void {
        try self.read_deadline(bytes, mtime.Deadline.init_relative(time.get_time_since_boot(), timeout));
    }

    pub fn read_deadline(self: UART, bytes: []u8, deadline: mtime.Deadline) Error!void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            try check_deadline(deadline);
            pos += try self.try_read(bytes[pos..]);
        }
    }

    pub fn flush_blocking(self: UART, timeout: ?mtime.Duration) error{Timeout}!void {
        const deadline = mtime.Deadline.init_relative(time.get_time_since_boot(), timeout);
        const r = self.regs();
        while (r.STATUS.read().TXFIFO_CNT != 0 or r.FSM_STATUS.read().ST_UTX_OUT != 0)
            try check_deadline(deadline);
    }
};

fn check_deadline(deadline: mtime.Deadline) error{Timeout}!void {
    if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
}

/// Compatibility entry point for ROM-initialized UART callers. No init or pin
/// changes; an unbounded blocking write preserves the original void signature.
pub fn write(comptime index: comptime_int, bytes: []const u8) void {
    if (index < 0 or index > 1) @compileError("only UART0 and UART1 are present");
    const uart = instance.num(index);
    var pos: usize = 0;
    while (pos < bytes.len) pos += uart.try_write(bytes[pos..]);
}

/// StreamDevice adapter. Its generic interface maps frame/parity/overflow to
/// IoError; use UART directly when the specific RX failure matters.
pub const Stream = struct {
    uart: UART,
    timeout: ?mtime.Duration = null,

    pub fn stream_device(self: *Stream) StreamDevice {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: StreamDevice.VTable = .{
        .connect_fn = null,
        .disconnect_fn = null,
        .writev_fn = writev,
        .readv_fn = readv,
    };

    fn writev(ctx: *anyopaque, chunks: []const []const u8) StreamDevice.WriteError!usize {
        const self: *Stream = @ptrCast(@alignCast(ctx));
        const deadline = mtime.Deadline.init_relative(time.get_time_since_boot(), self.timeout);
        var count: usize = 0;
        for (chunks) |chunk| {
            try self.uart.write_deadline(chunk, deadline);
            count += chunk.len;
        }
        return count;
    }

    fn readv(ctx: *anyopaque, chunks: [][]u8) StreamDevice.ReadError!usize {
        const self: *Stream = @ptrCast(@alignCast(ctx));
        const deadline = mtime.Deadline.init_relative(time.get_time_since_boot(), self.timeout);
        var count: usize = 0;
        for (chunks) |chunk| {
            if (chunk.len == 0) continue;
            while (true) {
                try check_deadline(deadline);
                const n = self.uart.try_read(chunk) catch |err| return switch (err) {
                    error.Timeout => error.Timeout,
                    else => error.IoError,
                };
                count += n;
                if (n != 0) break;
            }
            // A stream read may return as soon as any data is available.
            return count;
        }
        return count;
    }
};
