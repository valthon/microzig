pub const ClockSource = enum(u2) { apb = 1, rc_fast = 2, xtal = 3 };
const RMT = @import("microzig").chip.peripherals.RMT;
const ClockConfig = @import("../rmt.zig").ClockConfig;

pub fn configure_clock(config: ClockConfig) void {
    RMT.SYS_CONF.write(.{
        .APB_FIFO_MASK = 1,
        .MEM_CLK_FORCE_ON = 1,
        .MEM_FORCE_PU = 1,
        .SCLK_DIV_NUM = config.integer,
        .SCLK_DIV_A = config.numerator,
        .SCLK_DIV_B = config.denominator,
        .SCLK_SEL = @backingInt(config.source),
        .SCLK_ACTIVE = 1,
        .CLK_EN = 1,
    });
}

const rmt = @import("../rmt.zig");
const half_words = rmt.block_words / 2;

pub fn configure_tx(comptime channel: u1, config: rmt.TxConfig) void {
    const conf = if (channel == 0) &RMT.CH0_TX_CONF0 else @as(@TypeOf(&RMT.CH0_TX_CONF0), @ptrCast(&RMT.CH1_TX_CONF0));
    conf.modify(.{ .CONF_UPDATE = 1 });
    conf.write(.{
        .DIV_CNT = config.divider,
        .MEM_SIZE = 1,
        .MEM_TX_WRAP_EN = 1,
        .TX_CONTI_MODE = @intFromBool(config.continuous),
        .IDLE_OUT_EN = 1,
        .IDLE_OUT_LV = config.idle_level,
        .CARRIER_EN = @intFromBool(config.carrier != null),
        .CARRIER_EFF_EN = if (config.carrier) |c| @intFromBool(c.only_while_sending) else 0,
        .CARRIER_OUT_LV = if (config.carrier) |c| c.level else 0,
        .MEM_RD_RST = 1,
        .APB_MEM_RST = 1,
    });
    if (config.carrier) |c| {
        const duty = if (channel == 0) &RMT.CH0CARRIER_DUTY else @as(@TypeOf(&RMT.CH0CARRIER_DUTY), @ptrCast(&RMT.CH1CARRIER_DUTY));
        duty.write(.{ .CARRIER_HIGH = c.high, .CARRIER_LOW = c.low });
    }
    const limit = if (channel == 0) &RMT.CH0_TX_LIM else @as(@TypeOf(&RMT.CH0_TX_LIM), @ptrCast(&RMT.CH1_TX_LIM));
    limit.write(.{ .TX_LIM = half_words });
}
pub fn start_tx(comptime channel: u1) void {
    const conf = if (channel == 0) &RMT.CH0_TX_CONF0 else @as(@TypeOf(&RMT.CH0_TX_CONF0), @ptrCast(&RMT.CH1_TX_CONF0));
    conf.modify(.{ .CONF_UPDATE = 1 });
    conf.modify(.{ .TX_START = 1 });
}
pub fn tx_continuous(comptime channel: u1) bool {
    const conf = if (channel == 0) &RMT.CH0_TX_CONF0 else @as(@TypeOf(&RMT.CH0_TX_CONF0), @ptrCast(&RMT.CH1_TX_CONF0));
    return conf.read().TX_CONTI_MODE != 0;
}
pub fn stop_tx(comptime channel: u1) void {
    const conf = if (channel == 0) &RMT.CH0_TX_CONF0 else @as(@TypeOf(&RMT.CH0_TX_CONF0), @ptrCast(&RMT.CH1_TX_CONF0));
    conf.modify(.{ .CONF_UPDATE = 1 });
    conf.modify(.{ .TX_STOP = 1 });
    conf.modify(.{ .CONF_UPDATE = 1 });
}
pub fn configure_rx(comptime channel: u2, config: rmt.RxConfig) void {
    const conf = if (channel == 2) &RMT.CH2CONF1 else @as(@TypeOf(&RMT.CH2CONF1), @ptrCast(&RMT.CH3CONF1));
    conf.modify(.{ .CONF_UPDATE = 1 });
    const config0 = if (channel == 2) &RMT.CH2_RX_CONF0 else @as(@TypeOf(&RMT.CH2_RX_CONF0), @ptrCast(&RMT.CH3_RX_CONF0));
    const limit = if (channel == 2) &RMT.CH2_RX_LIM else @as(@TypeOf(&RMT.CH2_RX_LIM), @ptrCast(&RMT.CH3_RX_LIM));
    limit.write(.{ .RX_LIM = half_words });
    if (config.carrier) |carrier| {
        const removal = if (channel == 2) &RMT.CH2_RX_CARRIER_RM else @as(@TypeOf(&RMT.CH2_RX_CARRIER_RM), @ptrCast(&RMT.CH3_RX_CARRIER_RM));
        removal.write(.{ .CARRIER_HIGH_THRES = carrier.high_threshold, .CARRIER_LOW_THRES = carrier.low_threshold });
    }
    config0.write(.{
        .DIV_CNT = config.divider,
        .IDLE_THRES = config.idle_threshold,
        .CARRIER_EN = @intFromBool(config.carrier != null),
        .CARRIER_OUT_LV = if (config.carrier) |c| c.level else 0,
        .MEM_SIZE = 1,
    });
    conf.write(.{
        .MEM_WR_RST = 1,
        .APB_MEM_RST = 1,
        .MEM_OWNER = 1,
        .MEM_RX_WRAP_EN = 1,
        .RX_FILTER_EN = @intFromBool(config.filter_threshold != 0),
        .RX_FILTER_THRES = config.filter_threshold,
    });
}
pub fn start_rx(comptime channel: u2) void {
    const conf = if (channel == 2) &RMT.CH2CONF1 else @as(@TypeOf(&RMT.CH2CONF1), @ptrCast(&RMT.CH3CONF1));
    conf.modify(.{ .CONF_UPDATE = 1 });
    conf.modify(.{ .RX_EN = 1 });
    conf.modify(.{ .CONF_UPDATE = 1 });
}
pub fn rx_end(comptime channel: u2) usize {
    const status = if (channel == 2) &RMT.CH2STATUS else @as(@TypeOf(&RMT.CH2STATUS), @ptrCast(&RMT.CH3STATUS));
    return status.read().MEM_WADDR_EX;
}
pub fn stop_rx(comptime channel: u2) void {
    const conf = if (channel == 2) &RMT.CH2CONF1 else @as(@TypeOf(&RMT.CH2CONF1), @ptrCast(&RMT.CH3CONF1));
    conf.modify(.{ .CONF_UPDATE = 1 });
    conf.modify(.{ .RX_EN = 0 });
    conf.modify(.{ .CONF_UPDATE = 1 });
}
