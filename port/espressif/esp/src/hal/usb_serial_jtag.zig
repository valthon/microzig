const std = @import("std");
const microzig = @import("microzig");
// Both generated chip maps call this USB_DEVICE. EP1/EP1_CONF are described
// in C6 TRM v1.2 §32.7, registers 32.1/32.2 (FIFO protocol: §32.3.2).
const USB_SERIAL_JTAG = microzig.chip.peripherals.USB_DEVICE;
const time = @import("time.zig");
const Deadline = microzig.drivers.time.Deadline;

/// Returns `false` if data can be sent.
pub fn tx_fifo_full() bool {
    return USB_SERIAL_JTAG.EP1_CONF.read().SERIAL_IN_EP_DATA_FREE == 0;
}

/// Call this after you are done writing data. After `tx_fifo_full()` returns false
/// you can start sending more data.
pub fn tx_fifo_flush() void {
    USB_SERIAL_JTAG.EP1_CONF.write(.{ .WR_DONE = 1 });
}

/// Writes one byte to the fifo.
pub fn tx_fifo_write(byte: u8) void {
    USB_SERIAL_JTAG.EP1.write(.{
        .RDWR_BYTE = byte,
    });
}

/// Returns true while the OUT endpoint contains unread bytes.
/// C3 TRM v1.4 §30.3.2; C6 TRM v1.2 §32.3.2: identical EP1 FIFO protocol.
pub fn rx_fifo_available() bool {
    return USB_SERIAL_JTAG.EP1_CONF.read().SERIAL_OUT_EP_DATA_AVAIL != 0;
}

/// Caller must first check rx_fifo_available(). Reading consumes one byte.
pub fn rx_fifo_read() u8 {
    return USB_SERIAL_JTAG.EP1.read().RDWR_BYTE;
}

/// Reads up to buffer.len bytes without waiting. Returns zero when no data is ready.
/// RX must have a single consumer; do not also read the FIFO from an interrupt.
pub fn read(buffer: []u8) usize {
    var n: usize = 0;
    while (n < buffer.len and rx_fifo_available()) : (n += 1) {
        buffer[n] = rx_fifo_read();
    }
    return n;
}

/// Waits for at least one byte, then returns the currently available data.
/// An empty buffer returns immediately. Uses one deadline for the entire wait.
pub fn read_blocking(buffer: []u8, deadline: Deadline) error{Timeout}!usize {
    if (buffer.len == 0) return 0;
    while (true) {
        const n = read(buffer);
        if (n != 0) return n;
        if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
    }
}

fn wait_for_tx(deadline: Deadline) error{Timeout}!void {
    while (tx_fifo_full()) {
        if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
    }
}

/// Success means the host consumed every flushed packet, including the final one.
/// Timeout indicates a host that is absent, closed, or not reading (C3 TRM v1.4 §30.4; C6 TRM v1.2 §32.3.2).
/// A timeout can follow partial delivery; retrying the whole slice may duplicate data.
/// Serialize TX callers, including the logger. The deadline covers the whole write.
pub fn write_blocking(data: []const u8, deadline: Deadline) error{Timeout}!usize {
    if (data.len == 0) return 0;
    try wait_for_tx(deadline);
    var offset: usize = 0;
    while (offset < data.len) {
        const packet = data[offset..][0..@min(64, data.len - offset)];
        for (packet) |byte| tx_fifo_write(byte);
        // The 64th byte flushes automatically (C3 TRM v1.4 §30.3.2; C6 TRM v1.2 §32.3.2).
        if (packet.len < 64) tx_fifo_flush();
        try wait_for_tx(deadline);
        offset += packet.len;
    }
    return data.len;
}

/// Buffered writer with bounded host-consumption waits. Inspect err after WriteFailed.
/// Each drain gets one timeout; no failed bytes are retained for a later message.
pub const Writer = struct {
    interface: std.Io.Writer,
    timeout: microzig.drivers.time.Duration = .from_ms(100),
    err: ?error{Timeout} = null,

    pub fn init(buffer: []u8) Writer {
        return .{ .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        const deadline = Deadline.init_relative(time.get_time_since_boot(), self.timeout);
        self.err = null;
        const buffered = w.buffer[0..w.end];
        w.end = 0;
        _ = write_blocking(buffered, deadline) catch |err| {
            self.err = err;
            return error.WriteFailed;
        };
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            n += write_blocking(bytes, deadline) catch |err| {
                self.err = err;
                return error.WriteFailed;
            };
        }
        for (0..splat) |_| {
            n += write_blocking(data[data.len - 1], deadline) catch |err| {
                self.err = err;
                return error.WriteFailed;
            };
        }
        return n;
    }
};

/// USB Serial JTAG logger. Use `.logFn = logger.log` in std_options.
/// Failed lines are discarded; subsequent calls retry even after a host timeout.
pub const logger = struct {
    var buffer: [64]u8 = undefined;
    var writer = Writer.init(&buffer);

    pub fn log(
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const level_prefix = comptime "[{}.{:0>6}] " ++ level.asText();
        const prefix = comptime level_prefix ++ switch (scope) {
            .default => ": ",
            else => " (" ++ @tagName(scope) ++ "): ",
        };

        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();

        const current_time = time.get_time_since_boot();
        const seconds = current_time.to_us() / std.time.us_per_s;
        const microseconds = current_time.to_us() % std.time.us_per_s;

        writer.interface.print(prefix ++ format ++ "\r\n", .{ seconds, microseconds } ++ args) catch {
            writer.interface.end = 0;
            return;
        };
        writer.interface.flush() catch {
            writer.interface.end = 0;
        };
    }
};
