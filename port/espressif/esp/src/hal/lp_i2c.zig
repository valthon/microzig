//! ESP32-C6 LP I2C master. TRM v1.2 §§29.4.5–29.4.9, 29.5,
//! 29.6.1, 29.11.1; fixed pins in Table 7.13-1; clock mux §8.5.2.
//! Reference: ESP-IDF lp_core_i2c.c and esp32c6/hal/i2c_ll.h.
//! Single owner (HP or LP), single master, polling; caller serializes calls.
const microzig = @import("microzig");
const io = @import("lp_io.zig");
const p = microzig.chip.peripherals;
const i = p.LP_I2C0;
pub const Error = error{ InvalidTiming, InvalidLength, Nack, ArbitrationLost, Timeout, Fifo };
pub const Config = struct {
    source_hz: u32,
    bus_hz: u32 = 100000,
    clock: enum { lp_fast, xtal_d2 } = .lp_fast,
    /// Weak internal pulls suffice for the unwired scan, not a loaded bus.
    internal_pullups: bool = false,
};

pub fn apply(config: Config) Error!void {
    if (config.bus_hz == 0 or config.bus_hz > 400000) return error.InvalidTiming;
    const half = config.source_hz / config.bus_hz / 2;
    // LP has no HP PCR prescaler. Bound all 9-bit timings and 7-bit wait.
    if (half < 10 or half > 256) return error.InvalidTiming;
    const wait = if (config.bus_hz >= 80000) half / 2 - 2 else half / 4;
    if (wait > 127) return error.InvalidTiming;
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    // SCL first, high before routing SDA, as in IDF lp_i2c_set_pin.
    io.apply(7, .{ .function = .peripheral, .output = true, .open_drain = true, .initial_level = 1, .pull = if (config.internal_pullups) .up else .none });
    io.apply(6, .{ .function = .peripheral, .output = true, .open_drain = true, .initial_level = 1, .pull = if (config.internal_pullups) .up else .none });
    p.LP_PERI.CLK_EN.modify(.{ .LP_EXT_I2C_CK_EN = 1 });
    p.LP_PERI.RESET_EN.modify(.{ .LP_EXT_I2C_RESET_EN = 1 });
    p.LP_PERI.RESET_EN.modify(.{ .LP_EXT_I2C_RESET_EN = 0 });
    p.LP_CLKRST.LPPERI.modify(.{ .LP_I2C_CLK_SEL = @intFromBool(config.clock == .xtal_d2) });
    i.I2C_CTR.write(.{ .I2C_CLK_EN = 1, .I2C_RX_FULL_ACK_LEVEL = 1 });
    i.I2C_INT_ENA.raw = 0;
    i.I2C_INT_CLR.raw = 0xffff;
    // TRM §29.4.7; IDF timing calculation deliberately does not subtract
    // one from high/wait, to account for measured controller behavior.
    i.I2C_SCL_LOW_PERIOD.write(.{ .I2C_SCL_LOW_PERIOD = @intCast(half - 1) });
    i.I2C_SCL_HIGH_PERIOD.write(.{ .I2C_SCL_HIGH_PERIOD = @intCast(half - wait), .I2C_SCL_WAIT_HIGH_PERIOD = @intCast(wait) });
    i.I2C_SDA_HOLD.write(.{ .TIME = @intCast(half / 4 - 1) });
    i.I2C_SDA_SAMPLE.write(.{ .TIME = @intCast(half / 2 - 1) });
    i.I2C_SCL_START_HOLD.write(.{ .TIME = @intCast(half - 1) });
    i.I2C_SCL_RSTART_SETUP.write(.{ .TIME = @intCast(half - 1) });
    i.I2C_SCL_STOP_HOLD.write(.{ .TIME = @intCast(half - 1) });
    i.I2C_SCL_STOP_SETUP.write(.{ .TIME = @intCast(half - 1) });
    i.I2C_TO.write(.{ .I2C_TIME_OUT_EN = 1, .I2C_TIME_OUT_VALUE = 16 });
    i.I2C_SCL_ST_TIME_OUT.write(.{ .I2C_SCL_ST_TO_I2C = 16 });
    i.I2C_SCL_MAIN_ST_TIME_OUT.write(.{ .I2C_SCL_MAIN_ST_TO_I2C = 16 });
    i.I2C_FILTER_CFG.write(.{ .I2C_SCL_FILTER_EN = 1, .I2C_SDA_FILTER_EN = 1, .I2C_SCL_FILTER_THRES = 7, .I2C_SDA_FILTER_THRES = 7 });
    i.I2C_FIFO_CONF.write(.{ .I2C_FIFO_PRT_EN = 1 });
    i.I2C_CTR.modify(.{ .I2C_CONF_UPGATE = 1 });
}

const Opcode = enum(u3) { write = 1, stop = 2, read = 3, end = 4, restart = 6 };
// TRM §29.4.9 command fields, packed inside the generated COMMANDn field.
const Command = packed struct(u14) {
    byte_count: u8 = 0,
    ack_check: bool = false,
    ack_expected: u1 = 0,
    ack_value: u1 = 0,
    opcode: Opcode,
};
fn command(comptime n: u3, value: Command) void {
    const std = @import("std");
    @field(i, std.fmt.comptimePrint("I2C_COMD{d}", .{n})).raw = @as(u14, @bitCast(value));
}

/// Empty write sends only address+W and checks its ACK.
pub fn probe(address: u7, poll_limit: u32) Error!void {
    try write(address, &.{}, poll_limit);
}

/// One START/address/data/STOP transaction, up to 15 data bytes (16-byte FIFO).
pub fn write(address: u7, data: []const u8, poll_limit: u32) Error!void {
    if (data.len > 15) return error.InvalidLength;
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    try prepare(poll_limit);
    errdefer reset();
    i.I2C_DATA.write(.{ .I2C_FIFO_RDATA = @as(u8, address) << 1 });
    for (data) |byte| i.I2C_DATA.write(.{ .I2C_FIFO_RDATA = byte });
    command(0, .{ .opcode = .restart });
    command(1, .{ .opcode = .write, .byte_count = @intCast(data.len + 1), .ack_check = true });
    command(2, .{ .opcode = .stop });
    try execute(poll_limit);
}

/// One START/address/read/STOP transaction, 1–16 bytes, last byte NACKed.
/// Combined write/read with a repeated START is not implemented.
pub fn read(address: u7, data: []u8, poll_limit: u32) Error!void {
    if (data.len == 0 or data.len > 16) return error.InvalidLength;
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    try prepare(poll_limit);
    errdefer reset();
    i.I2C_DATA.write(.{ .I2C_FIFO_RDATA = (@as(u8, address) << 1) | 1 });
    command(0, .{ .opcode = .restart });
    command(1, .{ .opcode = .write, .byte_count = 1, .ack_check = true });
    if (data.len > 1) {
        command(2, .{ .opcode = .read, .byte_count = @intCast(data.len - 1) });
        command(3, .{ .opcode = .read, .byte_count = 1, .ack_value = 1 });
        command(4, .{ .opcode = .stop });
    } else {
        command(2, .{ .opcode = .read, .byte_count = 1, .ack_value = 1 });
        command(3, .{ .opcode = .stop });
    }
    try execute(poll_limit);
    if (i.I2C_SR.read().I2C_RXFIFO_CNT != data.len) return error.Fifo;
    for (data) |*byte| byte.* = i.I2C_DATA.read().I2C_FIFO_RDATA;
}

fn reset() void {
    // TRM §29.4.4/29.11.1: reset SCL FSM after a failed transaction.
    i.I2C_CTR.modify(.{ .I2C_TRANS_START = 0, .I2C_FSM_RST = 1 });
}
fn prepare(poll_limit: u32) Error!void {
    reset();
    var left = poll_limit;
    while (i.I2C_CTR.read().I2C_FSM_RST != 0) {
        if (left == 0) return error.Timeout;
        left -= 1;
    }
    i.I2C_FIFO_CONF.modify(.{ .I2C_RX_FIFO_RST = 1, .I2C_TX_FIFO_RST = 1 });
    i.I2C_FIFO_CONF.modify(.{ .I2C_RX_FIFO_RST = 0, .I2C_TX_FIFO_RST = 0 });
    i.I2C_INT_CLR.raw = 0xffff;
    inline for (0..8) |n| command(n, .{ .opcode = .end });
}
/// C6 TRM §29.4.9 item 5: NACK generates an interrupt and STOP. Wait for
/// completion when the budget permits, but preserve the known NACK on expiry.
/// Prior hardware observation: resetting during STOP can leave a completion
/// that skips the next address (TXFIFO_CNT=1). execute rejects that completion.
fn finish_nack(poll_limit: u32) Error {
    var left = poll_limit;
    while (i.I2C_INT_RAW.read().I2C_TRANS_COMPLETE_INT_RAW == 0) {
        if (left == 0) return error.Nack;
        left -= 1;
    }
    return error.Nack;
}
fn execute(poll_limit: u32) Error!void {
    i.I2C_CTR.modify(.{ .I2C_CONF_UPGATE = 1 });
    i.I2C_CTR.modify(.{ .I2C_TRANS_START = 1 });
    var left = poll_limit;
    while (true) {
        const status = i.I2C_INT_RAW.read();
        if (status.I2C_NACK_INT_RAW != 0) return finish_nack(left);
        if (status.I2C_ARBITRATION_LOST_INT_RAW != 0) return error.ArbitrationLost;
        if (status.I2C_TIME_OUT_INT_RAW != 0 or status.I2C_SCL_ST_TO_INT_RAW != 0 or status.I2C_SCL_MAIN_ST_TO_INT_RAW != 0) return error.Timeout;
        if (status.I2C_TXFIFO_OVF_INT_RAW != 0 or status.I2C_RXFIFO_OVF_INT_RAW != 0 or status.I2C_MST_TXFIFO_UDF_INT_RAW != 0 or status.I2C_RXFIFO_UDF_INT_RAW != 0) return error.Fifo;
        if (status.I2C_TRANS_COMPLETE_INT_RAW != 0) {
            // §29.11.1: TXFIFO_CNT is bytes still to be sent. A stale
            // completion after any aborted transaction is not an ACK.
            if (i.I2C_SR.read().I2C_TXFIFO_CNT != 0) return error.Fifo;
            return;
        }
        if (left == 0) return error.Timeout;
        left -= 1;
    }
}
