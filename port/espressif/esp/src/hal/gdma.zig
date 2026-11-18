//! GDMA channel 0, shared by peripheral clients under exclusive caller ownership.
//! C3 TRM v1.4 ch. 2; C6 TRM v1.2 ch. 4. No allocation or global state.
const std = @import("std");
const microzig = @import("microzig");
const compatibility = @import("compatibility.zig");
const system = @import("system.zig");

pub const max_descriptor_bytes = 4092;
pub const Direction = enum { tx, rx };
pub const Error = error{ InvalidMemory, InsufficientDescriptors, EmptyBuffer, DmaFault };

/// Three words, word aligned, in internal SRAM (C3 §2.4.1, C6 §4.4.1).
/// Hardware updates control through DMA; inspect it only through volatile reads.
pub const Descriptor = extern struct {
    control: u32,
    buffer: u32,
    next: u32,
};

pub fn descriptor_count(bytes: usize) usize {
    return bytes / max_descriptor_bytes + @intFromBool(bytes % max_descriptor_bytes != 0);
}

pub fn valid_region(address: usize, bytes: usize, lower: usize, end: usize) bool {
    return address >= lower and address < end and bytes <= end - address;
}

fn check_memory(address: usize, bytes: usize) Error!void {
    // C3 §2.4.7; C6 §4.4.7. Reject flash, MMIO and SRAM-crossing slices.
    const lower: usize = if (compatibility.chip == .esp32_c3) 0x3fc80000 else 0x40800000;
    const end: usize = if (compatibility.chip == .esp32_c3) 0x3fce0000 else 0x40880000;
    if (!valid_region(address, bytes, lower, end)) return error.InvalidMemory;
}

/// Storage and buffer must remain at fixed addresses and untouched until reset
/// or successful completion. RX buffers are mutable; TX buffers must be in RAM.
/// Burst mode is disabled, allowing byte-sized tails (§2.4.7 / §4.4.7).
pub fn prepare(storage: []Descriptor, buffer: []const u8, direction: Direction) Error![]Descriptor {
    if (buffer.len == 0) return error.EmptyBuffer;
    const count = descriptor_count(buffer.len);
    if (storage.len < count) return error.InsufficientDescriptors;
    const list = storage[0..count];
    try check_memory(@intFromPtr(list.ptr), list.len * @sizeOf(Descriptor));
    try check_memory(@intFromPtr(buffer.ptr), buffer.len);
    fill_list(list, @intCast(@intFromPtr(buffer.ptr)), @intCast(@intFromPtr(list.ptr)), buffer.len, direction);
    return list;
}

fn fill_list(list: []Descriptor, buffer_address: u32, list_address: u32, bytes: usize, direction: Direction) void {
    var offset: usize = 0;
    for (list, 0..) |*desc, i| {
        const len = @min(bytes - offset, max_descriptor_bytes);
        desc.* = .{
            .control = descriptor_control(@intCast(len), direction, i + 1 == list.len),
            .buffer = buffer_address + @as(u32, @intCast(offset)),
            .next = if (i + 1 == list.len) 0 else list_address + @as(u32, @intCast((i + 1) * @sizeOf(Descriptor))),
        };
        offset += len;
    }
}

fn descriptor_control(len: u12, direction: Direction, last: bool) u32 {
    return @as(u32, len) | (if (direction == .tx) @as(u32, len) << 12 else 0) |
        (if (direction == .tx and last) @as(u32, 1) << 30 else 0) | (@as(u32, 1) << 31);
}

// Registers are expanded to individual channels by regz on both chips.
fn reg(comptime name: []const u8) *volatile @FieldType(microzig.chip.types.peripherals.DMA, name ++ "_CH0") {
    return &@field(microzig.chip.peripherals.DMA, name ++ "_CH0");
}

fn field_name(comptime register: []const u8, comptime field: []const u8) []const u8 {
    return field ++ (if (compatibility.chip == .esp32_c3 or std.mem.eql(u8, register, "OUT_CONF0")) "0" else "");
}

fn set(comptime register: []const u8, comptime field: []const u8, value: anytype) void {
    const mmio = reg(register);
    var bits = mmio.read();
    @field(bits, field_name(register, field)) = value;
    mmio.write(bits);
}

/// Enable once, before any clients start. Does not reset the shared GDMA block.
pub fn init() void {
    system.clocks_enable_set(.{ .dma = true });
    system.peripheral_reset_clear(.{ .dma = true });
    microzig.chip.peripherals.DMA.MISC_CONF.modify(.{ .CLK_EN = 1 });
}

/// Resets only channel 0. This synchronously cancels descriptor/buffer access;
/// callers must also stop their peripheral before releasing its buffers.
/// C3 §2.6.2–2.6.3; C6 §4.6.1–4.6.2.
pub fn reset() void {
    set("IN_CONF0", "IN_RST_CH", 1);
    set("OUT_CONF0", "OUT_RST_CH", 1);
    set("IN_CONF0", "IN_RST_CH", 0);
    set("OUT_CONF0", "OUT_RST_CH", 0);
    if (compatibility.chip == .esp32_c3) {
        reg("INT_ENA").write_raw(0);
        reg("INT_CLR").write_raw(0x1fff);
    } else {
        reg("IN_INT_ENA").write_raw(0);
        reg("OUT_INT_ENA").write_raw(0);
        reg("IN_INT_CLR").write_raw(0x7f);
        reg("OUT_INT_CLR").write_raw(0x3f);
    }
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
}

/// Peripheral selector is from C3 Table 2.4-1 / C6 Table 4.4-1 (SPI2 = 0).
/// Exclusive ownership of channel 0 and this peripheral is the caller's duty.
pub fn start(direction: Direction, peripheral: u6, list: []Descriptor) void {
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    switch (direction) {
        .rx => {
            reg("IN_CONF0").write_raw(0); // non-burst, no memory-to-memory mode
            set("IN_CONF1", "IN_CHECK_OWNER_CH", 1);
            set("IN_PERI_SEL", "PERI_IN_SEL_CH", peripheral);
            set("IN_LINK", "INLINK_ADDR_CH", @as(u20, @truncate(@intFromPtr(list.ptr))));
            set("IN_LINK", "INLINK_START_CH", 1);
        },
        .tx => {
            reg("OUT_CONF0").write_raw(0);
            set("OUT_CONF0", "OUT_AUTO_WRBACK_CH", 1);
            set("OUT_CONF0", "OUT_EOF_MODE_CH", 1);
            set("OUT_CONF1", "OUT_CHECK_OWNER_CH", 1);
            set("OUT_PERI_SEL", "PERI_OUT_SEL_CH", peripheral);
            set("OUT_LINK", "OUTLINK_ADDR_CH", @as(u20, @truncate(@intFromPtr(list.ptr))));
            set("OUT_LINK", "OUTLINK_START_CH", 1);
        },
    }
}

/// EOF is required in addition to peripheral completion: RX writes may lag it.
pub fn completed(tx: bool, rx: bool) Error!bool {
    if (compatibility.chip == .esp32_c3) {
        const raw = reg("INT_RAW").read();
        if (raw.IN_DSCR_ERR_CH0_INT_RAW != 0 or raw.OUT_DSCR_ERR_CH0_INT_RAW != 0 or
            raw.IN_DSCR_EMPTY_CH0_INT_RAW != 0 or raw.INFIFO_OVF_CH0_INT_RAW != 0 or
            raw.INFIFO_UDF_CH0_INT_RAW != 0 or raw.OUTFIFO_OVF_CH0_INT_RAW != 0 or raw.OUTFIFO_UDF_CH0_INT_RAW != 0)
            return error.DmaFault;
        return (!tx or raw.OUT_TOTAL_EOF_CH0_INT_RAW != 0) and (!rx or raw.IN_SUC_EOF_CH0_INT_RAW != 0);
    } else {
        const input = reg("IN_INT_RAW").read();
        const output = reg("OUT_INT_RAW").read();
        if (input.IN_DSCR_ERR_CH_INT_RAW != 0 or input.IN_DSCR_EMPTY_CH_INT_RAW != 0 or
            input.INFIFO_OVF_CH_INT_RAW != 0 or input.INFIFO_UDF_CH_INT_RAW != 0 or
            output.OUT_DSCR_ERR_CH_INT_RAW != 0 or output.OUTFIFO_OVF_CH_INT_RAW != 0 or output.OUTFIFO_UDF_CH_INT_RAW != 0)
            return error.DmaFault;
        return (!tx or output.OUT_TOTAL_EOF_CH_INT_RAW != 0) and (!rx or input.IN_SUC_EOF_CH_INT_RAW != 0);
    }
}

pub fn received(list: []Descriptor, expected: usize) bool {
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    var total: usize = 0;
    for (list) |*desc| {
        const ptr: *volatile Descriptor = desc;
        const control = ptr.control;
        if (control & (@as(u32, 1) << 31) != 0) return false;
        total += (control >> 12) & 0xfff;
    }
    return total == expected;
}

test "descriptor boundaries and hardware word layout" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Descriptor));
    for ([_]usize{ 0, 1, 64, 4092, 4096, 10000, 32768 }, [_]usize{ 0, 1, 1, 1, 2, 3, 9 }) |bytes, count|
        try std.testing.expectEqual(count, descriptor_count(bytes));
    try std.testing.expectEqual(@as(u32, 0xc0ffffff), descriptor_control(4095, .tx, true));
    try std.testing.expectEqual(@as(u32, 0x80000001), descriptor_control(1, .rx, true));
    try std.testing.expectEqual(@as(u32, 0x80040040), descriptor_control(64, .tx, false));
}

test "DMA region excludes crossing end and arithmetic overflow" {
    try std.testing.expect(valid_region(0x3fc80000, 4, 0x3fc80000, 0x3fce0000));
    try std.testing.expect(!valid_region(0x3fcdffff, 2, 0x3fc80000, 0x3fce0000));
    try std.testing.expect(!valid_region(0, 1, 0x3fc80000, 0x3fce0000));
    try std.testing.expect(!valid_region(0x3fc80000, std.math.maxInt(usize), 0x3fc80000, 0x3fce0000));
}

test "multi-descriptor TX and RX chains preserve offsets, tails and EOF" {
    var list: [3]Descriptor = undefined;
    fill_list(&list, 0x3fc81000, 0x3fc80000, 10000, .tx);
    try std.testing.expectEqual(@as(u32, 0x3fc81ffc), list[1].buffer);
    try std.testing.expectEqual(@as(u32, 0x3fc82ff8), list[2].buffer);
    try std.testing.expectEqual(@as(u32, 0x3fc8000c), list[0].next);
    try std.testing.expectEqual(@as(u32, 0x3fc80018), list[1].next);
    try std.testing.expectEqual(@as(u32, 0), list[2].next);
    try std.testing.expectEqual(@as(u32, 1816), list[2].control & 0xfff);
    try std.testing.expectEqual(@as(u32, 1816), (list[2].control >> 12) & 0xfff);
    try std.testing.expectEqual(@as(u32, 0), list[0].control & (1 << 30));
    try std.testing.expectEqual(@as(u32, 1 << 30), list[2].control & (1 << 30));
    fill_list(&list, 0x3fc81000, 0x3fc80000, 10000, .rx);
    for (list) |desc| {
        try std.testing.expectEqual(@as(u32, 0), desc.control & 0x7ffff000);
        try std.testing.expectEqual(@as(u32, 1 << 31), desc.control & (1 << 31));
    }
}
