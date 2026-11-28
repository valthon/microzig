const std = @import("std");
const microzig = @import("microzig");
const USB = microzig.chip.peripherals.USB;
const PMA_BASE: u32 = 0x40006000;

//PMA(u16) <==> CPU(u32)
const PMA_value = packed struct(u32) {
    value: u16,
    _reserved: u16 = 0,
};

const BTABLEDescriptor = extern struct {
    TX_addr: PMA_value,
    TX_count: PMA_value,
    RX_addr: PMA_value,
    RX_count: PMA_value,
};

pub const BlockSize = enum {
    @"2bytes",
    @"32bytes",
};
pub const RX_size = struct {
    block_size: BlockSize = .@"2bytes",
    block_qtd: usize,

    pub fn calc_rx_size(size: *const RX_size) usize {
        // RM0008 Rev 21 §23.5.3 (USB_COUNTn_RX): the 32-byte encoding
        // stores one less than the number of blocks.
        return switch (size.block_size) {
            .@"2bytes" => size.block_qtd * 2,
            .@"32bytes" => (size.block_qtd + 1) * 32,
        };
    }

    pub fn to_RXcount(size: *const RX_size) u16 {
        const SL_bit: u16 = @as(u16, @backingInt(size.block_size)) << 15;
        const pkg_qtd: u16 = @as(u16, @intCast(size.block_qtd)) << 10;
        return SL_bit | pkg_qtd;
    }

    pub fn from_bytes(bytes: usize) RX_size {
        if (bytes > 62) {
            return .{ .block_qtd = (bytes - 1) / 32, .block_size = .@"32bytes" };
        }
        return .{ .block_qtd = std.mem.alignForward(usize, bytes, 2) / 2 };
    }
};
//the memory will be rounded to the nearest number of blocks to the value
pub const EntryMetadata = struct {
    tx_max_size: usize,
    rx_max_size: RX_size,
};

pub const Config = struct {
    pub const Error = error{InvalidEndpoint};
    EP0: ?EntryMetadata = null,
    EP1: ?EntryMetadata = null,
    EP2: ?EntryMetadata = null,
    EP3: ?EntryMetadata = null,
    EP4: ?EntryMetadata = null,
    EP5: ?EntryMetadata = null,
    EP6: ?EntryMetadata = null,
    EP7: ?EntryMetadata = null,

    pub fn set_config(self: *Config, endpoint: usize, config: EntryMetadata) Error!void {
        switch (endpoint) {
            0 => self.EP0 = config,
            1 => self.EP1 = config,
            2 => self.EP2 = config,
            3 => self.EP3 = config,
            4 => self.EP4 = config,
            5 => self.EP5 = config,
            6 => self.EP6 = config,
            7 => self.EP7 = config,
            else => {
                return error.InvalidEndpoint;
            },
        }
    }
};

pub const BTABLEError = error{
    PMAOverflow,
};

// RM0008 Rev 21 §§23.3.1 and 23.5.3: the USB uses byte offsets into
// 512 bytes of PMA. The CPU accesses each 16-bit word in a 32-bit slot.
const capacity = 512;
const table_bytes = 8 * 8;
const pma_words: [*]volatile u32 = if (@import("builtin").is_test and @hasDecl(microzig, "testing_usb"))
    &microzig.testing_usb.pma_words
else
    @ptrFromInt(PMA_BASE);
const BTABLE: *volatile [8]BTABLEDescriptor = @ptrCast(pma_words);

const BufferDescriptor = struct {
    tx_addr: u16,
    rx_addr: u16,
    rx_count: u16,
};

pub const Layout = [8]?BufferDescriptor;

pub fn plan_layout(config: Config) BTABLEError!Layout {
    const entries: [8]?EntryMetadata = .{
        config.EP0, config.EP1, config.EP2, config.EP3,
        config.EP4, config.EP5, config.EP6, config.EP7,
    };
    var layout: Layout = @splat(null);
    var offset: usize = table_bytes;
    for (entries, &layout) |entry, *descriptor| {
        const data = entry orelse continue;
        if (data.tx_max_size > capacity - offset) return error.PMAOverflow;
        const tx_size = std.mem.alignForward(usize, data.tx_max_size, 2);
        const rx_size = data.rx_max_size.calc_rx_size();
        if (rx_size > capacity - offset - tx_size) return error.PMAOverflow;
        descriptor.* = .{
            .tx_addr = @intCast(offset),
            .rx_addr = @intCast(offset + tx_size),
            .rx_count = data.rx_max_size.to_RXcount(),
        };
        offset += tx_size + rx_size;
    }
    return layout;
}

pub fn btable_init(layout: Layout) void {
    USB.BTABLE.raw = 0;
    for (layout, 0..) |descriptor, slot| {
        const data = descriptor orelse continue;
        BTABLE[slot].TX_addr.value = data.tx_addr;
        BTABLE[slot].TX_count.value = 0;
        BTABLE[slot].RX_addr.value = data.rx_addr;
        BTABLE[slot].RX_count.value = data.rx_count;
    }
}

pub inline fn RX_recv_size(EP: usize) usize {
    return BTABLE[EP].RX_count.value & 0x3FF;
}

pub fn RX_to_buffer(buffer: []u8, EP: usize) []const u8 {
    const PMA_buf = BTABLE[EP];
    const count = RX_recv_size(EP);
    if (count == 0) {
        return buffer[0..0];
    }

    const len = @min(count, buffer.len);
    const to_read = len / 2;
    const data = pma_words[PMA_buf.RX_addr.value / 2 ..][0..to_read];
    const buf_ptr = @as([*]align(1) u16, @ptrCast(buffer.ptr))[0..to_read];

    for (data, buf_ptr) |word, *half| {
        half.* = @truncate(word);
    }
    //if odd load the last byte into buffer
    if (len % 2 != 0) {
        buffer[len - 1] = @truncate(data.ptr[to_read]);
    }

    return buffer[0..len];
}

pub fn buffer_to_TX(buffer: []const u8, EP: usize) void {
    const len = buffer.len;

    //load bytes qtd into PMA
    if (len == 0) {
        BTABLE[EP].TX_count.value = 0;
        return;
    }
    BTABLE[EP].TX_count.value = @intCast((len));

    const to_write = len / 2;
    const buf_ptr = @as([*]align(1) const u16, @ptrCast(buffer.ptr))[0..to_write];
    const data = pma_words[BTABLE[EP].TX_addr.value / 2 ..][0..to_write];
    for (data, buf_ptr) |*word, val| {
        word.* = val;
    }

    //if odd, load the last byte into PMA
    if (len % 2 != 0) {
        data.ptr[data.len] = buffer[len - 1];
    }
}
