pub const ClockSource = enum(u2) { pll_f80m = 1, rc_fast = 2, xtal = 3 };
const peripherals = @import("microzig").chip.peripherals;
const ClockConfig = @import("../rmt.zig").ClockConfig;

// C6 TRM v1.2 §§8.5.1 (PCR_RMT_SCLK_CONF), 37.3.3, 37.5:
// source/divider live in PCR; SYS_CONF only controls memory/register clocks.
pub fn configure_clock(config: ClockConfig) void {
    peripherals.PCR.RMT_SCLK_CONF.modify(.{
        .RMT_SCLK_DIV_NUM = config.integer,
        .RMT_SCLK_DIV_A = config.denominator,
        .RMT_SCLK_DIV_B = config.numerator,
        .RMT_SCLK_SEL = @backingInt(config.source),
        .RMT_SCLK_EN = 1,
    });
    // The SVD also lists obsolete source/divider fields in SYS_CONF.
    // Preserve those reserved bits; only PCR controls the C6 source/divider.
    peripherals.RMT.SYS_CONF.modify(.{
        .APB_FIFO_MASK = 1,
        .MEM_CLK_FORCE_ON = 1,
        .RMT_MEM_FORCE_PU = 1,
        .CLK_EN = 1,
    });
}

const RMT = peripherals.RMT;
// C6 TRM v1.2 §§37.3.1–37.3.7, 37.4–37.5: TX 0/1 and RX 2/3;
// the vendor SVD indexes each RX register array from zero.

const rmt = @import("../rmt.zig");
const half_words = rmt.block_words / 2;

pub fn configure_tx(comptime channel: u1, config: rmt.TxConfig) void {
    const conf = if (channel == 0) &RMT.TX_CH0CONF0 else @as(@TypeOf(&RMT.TX_CH0CONF0), @ptrCast(&RMT.TX_CH1CONF0));
    conf.modify(.{ .CONF_UPDATE_CH0 = 1 });
    conf.write(.{
        .DIV_CNT_CH0 = config.divider,
        .MEM_SIZE_CH0 = 1,
        .MEM_TX_WRAP_EN_CH0 = 1,
        .TX_CONTI_MODE_CH0 = @intFromBool(config.continuous),
        .IDLE_OUT_EN_CH0 = 1,
        .IDLE_OUT_LV_CH0 = config.idle_level,
        .CARRIER_EN_CH0 = @intFromBool(config.carrier != null),
        .CARRIER_EFF_EN_CH0 = if (config.carrier) |c| @intFromBool(c.only_while_sending) else 0,
        .CARRIER_OUT_LV_CH0 = if (config.carrier) |c| c.level else 0,
        .MEM_RD_RST_CH0 = 1,
        .APB_MEM_RST_CH0 = 1,
    });
    if (config.carrier) |c| {
        const duty = if (channel == 0) &RMT.CH0CARRIER_DUTY else @as(@TypeOf(&RMT.CH0CARRIER_DUTY), @ptrCast(&RMT.CH1CARRIER_DUTY));
        duty.write(.{ .CARRIER_HIGH_CH = c.high, .CARRIER_LOW_CH = c.low });
    }
    const limit = if (channel == 0) &RMT.CH0_TX_LIM else @as(@TypeOf(&RMT.CH0_TX_LIM), @ptrCast(&RMT.CH1_TX_LIM));
    limit.write(.{ .TX_LIM_CH = half_words });
}
pub fn start_tx(comptime channel: u1) void {
    const conf = if (channel == 0) &RMT.TX_CH0CONF0 else @as(@TypeOf(&RMT.TX_CH0CONF0), @ptrCast(&RMT.TX_CH1CONF0));
    conf.modify(.{ .CONF_UPDATE_CH0 = 1 });
    conf.modify(.{ .TX_START_CH0 = 1 });
}
pub fn tx_continuous(comptime channel: u1) bool {
    const conf = if (channel == 0) &RMT.TX_CH0CONF0 else @as(@TypeOf(&RMT.TX_CH0CONF0), @ptrCast(&RMT.TX_CH1CONF0));
    return conf.read().TX_CONTI_MODE_CH0 != 0;
}
pub fn stop_tx(comptime channel: u1) void {
    const conf = if (channel == 0) &RMT.TX_CH0CONF0 else @as(@TypeOf(&RMT.TX_CH0CONF0), @ptrCast(&RMT.TX_CH1CONF0));
    conf.modify(.{ .CONF_UPDATE_CH0 = 1 });
    conf.modify(.{ .TX_STOP_CH0 = 1 });
    conf.modify(.{ .CONF_UPDATE_CH0 = 1 });
}
pub fn configure_rx(comptime channel: u2, config: rmt.RxConfig) void {
    const conf = if (channel == 2) &RMT.RX_CH0CONF1 else @as(@TypeOf(&RMT.RX_CH0CONF1), @ptrCast(&RMT.RX_CH1CONF1));
    conf.modify(.{ .CONF_UPDATE_CH2 = 1 });
    const config0 = if (channel == 2) &RMT.RX_CH0CONF0 else @as(@TypeOf(&RMT.RX_CH0CONF0), @ptrCast(&RMT.RX_CH1CONF0));
    const limit = if (channel == 2) &RMT.CH0_RX_LIM else @as(@TypeOf(&RMT.CH0_RX_LIM), @ptrCast(&RMT.CH1_RX_LIM));
    limit.write(.{ .RMT_RX_LIM_CH2 = half_words });
    if (config.carrier) |carrier| {
        const removal = if (channel == 2) &RMT.CH0_RX_CARRIER_RM else @as(@TypeOf(&RMT.CH0_RX_CARRIER_RM), @ptrCast(&RMT.CH1_RX_CARRIER_RM));
        removal.write(.{ .CARRIER_HIGH_THRES_CH = carrier.high_threshold, .CARRIER_LOW_THRES_CH = carrier.low_threshold });
    }
    config0.write(.{
        .DIV_CNT_CH2 = config.divider,
        .IDLE_THRES_CH2 = config.idle_threshold,
        .CARRIER_EN_CH2 = @intFromBool(config.carrier != null),
        .CARRIER_OUT_LV_CH2 = if (config.carrier) |c| c.level else 0,
        .MEM_SIZE_CH2 = 1,
    });
    conf.write(.{
        .MEM_WR_RST_CH2 = 1,
        .APB_MEM_RST_CH2 = 1,
        .MEM_OWNER_CH2 = 1,
        .MEM_RX_WRAP_EN_CH2 = 1,
        .RX_FILTER_EN_CH2 = @intFromBool(config.filter_threshold != 0),
        .RX_FILTER_THRES_CH2 = config.filter_threshold,
    });
}
pub fn start_rx(comptime channel: u2) void {
    const conf = if (channel == 2) &RMT.RX_CH0CONF1 else @as(@TypeOf(&RMT.RX_CH0CONF1), @ptrCast(&RMT.RX_CH1CONF1));
    conf.modify(.{ .CONF_UPDATE_CH2 = 1 });
    conf.modify(.{ .RX_EN_CH2 = 1 });
    conf.modify(.{ .CONF_UPDATE_CH2 = 1 });
}
pub fn rx_end(comptime channel: u2) usize {
    const status = if (channel == 2) &RMT.RX_CH0STATUS else @as(@TypeOf(&RMT.RX_CH0STATUS), @ptrCast(&RMT.RX_CH1STATUS));
    return status.read().MEM_WADDR_EX_CH2;
}
pub fn stop_rx(comptime channel: u2) void {
    const conf = if (channel == 2) &RMT.RX_CH0CONF1 else @as(@TypeOf(&RMT.RX_CH0CONF1), @ptrCast(&RMT.RX_CH1CONF1));
    conf.modify(.{ .CONF_UPDATE_CH2 = 1 });
    conf.modify(.{ .RX_EN_CH2 = 0 });
    conf.modify(.{ .CONF_UPDATE_CH2 = 1 });
}
