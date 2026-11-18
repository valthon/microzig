//! ESP32-C3/C6 RMT, C3 TRM v1.4 §§33.3–33.5; C6 TRM v1.2 §§37.3–37.5. Polling only; callers exclusively
//! own the peripheral and must service each half-block before the next fills.

const chip_specific = switch (@import("compatibility.zig").chip) {
    .esp32_c3 => @import("rmt/esp32_c3.zig"),
    .esp32_c6 => @import("rmt/esp32_c6.zig"),
};

const std = @import("std");
const microzig = @import("microzig");
const RMT = microzig.chip.peripherals.RMT;
const system = @import("system.zig");

pub const block_words = 48;
const half_words = block_words / 2;

/// Two pulse codes, low half first. A zero duration terminates transmission.
pub const Item = packed struct(u32) {
    duration0: u15,
    level0: u1,
    duration1: u15,
    level1: u1,

    pub const end: Item = @bitCast(@as(u32, 0));
};

pub const ClockSource = chip_specific.ClockSource;
pub const ClockConfig = struct {
    source: ClockSource = .xtal,
    /// Source divided by (integer + 1 + numerator / denominator).
    integer: u8 = 0,
    numerator: u6 = 0,
    denominator: u6 = 0,
};

/// Resets all channels. Configure once, before creating channel transfers.
/// RC_FAST must already be enabled by the application's clock configuration.
pub fn init(config: ClockConfig) error{InvalidDivider}!void {
    if (config.numerator != 0 and
        (config.denominator == 0 or config.numerator >= config.denominator))
        return error.InvalidDivider;
    system.enable_clocks_and_release_reset(.{ .rmt = true });
    system.peripheral_reset(.{ .rmt = true });
    chip_specific.configure_clock(config);
    RMT.INT_ENA.write_raw(0);
    RMT.INT_CLR.write_raw(0x3fff);
}

// RAM has no generated register declaration. Address each 32-bit RAM word
// through Mmio; the four 48-word blocks start at RMT + 0x400 (§33.3.2).
fn memory(channel: usize, offset: usize) *volatile microzig.mmio.Mmio(u32) {
    return @ptrFromInt(@intFromPtr(RMT) + 0x400 + (channel * block_words + offset) * 4);
}

fn mask(bit: usize) u32 {
    return @as(u32, 1) << @as(u5, @intCast(bit));
}

pub const Carrier = struct {
    /// High/low periods in rmt_sclk cycles minus one (§33.3.4.3).
    high: u16,
    low: u16,
    level: u1 = 1,
    only_while_sending: bool = true,
};

pub const TxConfig = struct {
    /// Zero means divide by 256; otherwise divide by this value.
    divider: u8 = 40,
    idle_level: u1 = 0,
    carrier: ?Carrier = null,
    /// Repeat the entire in-memory sequence until stop(); at most 47 items.
    continuous: bool = false,
};

pub fn Tx(comptime channel: u1) type {
    return struct {
        const Self = @This();
        const end_mask = mask(channel);
        const error_mask = mask(4 + @as(usize, channel));
        const threshold_mask = mask(8 + @as(usize, channel));
        items: []const Item,
        next: usize,
        half: usize = 0,
        finished: bool = false,

        /// Keep items alive until complete. No ISR may access this channel.
        /// Durations must satisfy TRM v1.4 equations 33.1 and 33.3 (continuous).
        pub fn start(items: []const Item, config: TxConfig) error{InvalidItems}!Self {
            if (items.len == 0 or (config.continuous and items.len >= block_words))
                return error.InvalidItems;
            for (items) |item| {
                if (item.duration0 == 0 or item.duration1 == 0) return error.InvalidItems;
            }
            chip_specific.configure_tx(channel, config);
            RMT.INT_CLR.write_raw(end_mask | error_mask | threshold_mask);
            var self: Self = .{ .items = items, .next = 0 };
            self.fill(0, block_words);
            chip_specific.start_tx(channel);
            return self;
        }

        fn fill(self: *Self, offset: usize, count: usize) void {
            for (offset..offset + count) |i| {
                const item = if (self.next < self.items.len) self.items[self.next] else Item.end;
                memory(channel, i).write_raw(@bitCast(item));
                if (self.next < self.items.len) self.next += 1;
            }
        }

        /// Returns true on end; errors stop the channel. Call often enough to
        /// refill 24 items before the other 24 have transmitted. Missed service
        /// deadlines cannot be detected reliably by RMT hardware.
        pub fn poll(self: *Self) error{TxError}!bool {
            if (self.finished) return true;
            const raw = RMT.INT_RAW.raw;
            if (raw & error_mask != 0) {
                self.stop();
                return error.TxError;
            }
            if (raw & end_mask != 0) {
                self.finished = true;
                return true;
            }
            if (raw & threshold_mask != 0) {
                RMT.INT_CLR.write_raw(threshold_mask);
                // Continuous mode repeats the original RAM contents.
                if (!chip_specific.tx_continuous(channel)) self.fill(self.half * half_words, half_words);
                self.half ^= 1;
            }
            return false;
        }

        pub fn stop(self: *Self) void {
            chip_specific.stop_tx(channel);
            self.finished = true;
        }
    };
}

pub const RxCarrier = struct {
    /// Demodulation thresholds in channel ticks (TRM §33.3.5.4).
    high_threshold: u16,
    low_threshold: u16,
    level: u1 = 1,
};

pub const RxConfig = struct {
    divider: u8 = 40,
    idle_threshold: u15 = 200,
    /// Zero disables filtering; otherwise measured in rmt_sclk cycles.
    filter_threshold: u8 = 0,
    carrier: ?RxCarrier = null,
};

pub fn Rx(comptime channel: u2) type {
    if (channel < 2) @compileError("RMT RX channels are 2 and 3");
    return struct {
        const Self = @This();
        const end_mask = mask(channel);
        const error_mask = mask(4 + @as(usize, channel));
        const threshold_mask = mask(8 + @as(usize, channel));
        buffer: []Item,
        count: usize = 0,
        cursor: usize = 0,
        finished: bool = false,

        /// Buffer may include the final idle/end-marker item. Service every
        /// 24 items; each channel uses only its own RAM block.
        pub fn start(buffer: []Item, config: RxConfig) error{InvalidThreshold}!Self {
            if (config.idle_threshold == 0) return error.InvalidThreshold;
            chip_specific.configure_rx(channel, config);
            RMT.INT_CLR.write_raw(end_mask | error_mask | threshold_mask);
            chip_specific.start_rx(channel);
            return .{ .buffer = buffer };
        }

        fn copy(self: *Self, count: usize) error{BufferFull}!void {
            if (count > self.buffer.len - self.count) return error.BufferFull;
            // Read completed words through NONFIFO addressing while the receiver
            // owns RAM. In wrap mode it writes the other half during a threshold
            // copy (§33.3.5.2); finish copying before it wraps back to this half.
            // Changing MEM_OWNER while RX_EN is set would race the next write
            // and raise an ownership error (§33.3.2, register 33.5).
            for (0..count) |_| {
                self.buffer[self.count] = @bitCast(memory(channel, self.cursor).raw);
                self.count += 1;
                self.cursor = (self.cursor + 1) % block_words;
            }
        }

        pub fn poll(self: *Self) error{ RxError, BufferFull }!bool {
            if (self.finished) return true;
            const raw = RMT.INT_RAW.raw;
            if (raw & error_mask != 0) {
                self.stop();
                return error.RxError;
            }
            errdefer self.stop();
            if (raw & threshold_mask != 0) {
                RMT.INT_CLR.write_raw(threshold_mask);
                try self.copy(half_words);
            }
            if (raw & end_mask != 0) {
                const end = @as(usize, chip_specific.rx_end(channel)) % block_words;
                try self.copy((end + block_words - self.cursor) % block_words);
                self.stop();
                return true;
            }
            return false;
        }

        pub fn stop(self: *Self) void {
            chip_specific.stop_rx(channel);
            self.finished = true;
        }
    };
}

/// Encode bytes MSB first. Pass bytes in GRB order for WS2812 LEDs. Timing is
/// explicit in channel ticks so it stays valid across clock configurations.
/// Append the LED's required reset-low interval separately after transmission.
pub fn encode_ws2812(bytes: []const u8, output: []Item, zero: Item, one: Item) error{BufferFull}![]Item {
    if (bytes.len > output.len / 8) return error.BufferFull;
    var i: usize = 0;
    for (bytes) |byte| {
        var bit: u8 = 0x80;
        while (bit != 0) : (bit >>= 1) {
            output[i] = if (byte & bit == 0) zero else one;
            i += 1;
        }
    }
    return output[0..i];
}

test "WS2812 byte order, pulse packing and output capacity" {
    const zero: Item = .{ .duration0 = 3, .level0 = 1, .duration1 = 7, .level1 = 0 };
    const one: Item = .{ .duration0 = 6, .level0 = 1, .duration1 = 4, .level1 = 0 };
    var out: [16]Item = undefined;
    const encoded = try encode_ws2812(&.{ 0x81, 0x42 }, &out, zero, one);
    for (encoded, 0..) |item, i| {
        const high = i == 0 or i == 7 or i == 9 or i == 14;
        try std.testing.expectEqual(if (high) one else zero, item);
    }
    try std.testing.expectEqual(@as(u32, 0x0007_8003), @as(u32, @bitCast(zero)));
    try std.testing.expectError(error.BufferFull, encode_ws2812(&.{0}, out[0..7], zero, one));
    try std.testing.expectEqual(@as(usize, 0), (try encode_ws2812(&.{}, &out, zero, one)).len);
}
