//! ESP32-C6 LP UART, polling 8N1. TRM v1.2 §§27.4.1–27.4.4,
//! 27.5.1, 27.7.2; clock mux §8.5 LP_CLKRST_LPPERI_REG.
//! Reference: ESP-IDF lp_core_uart.c and esp32c6/hal/uart_ll.h.
//! HP or LP may own the controller, never both concurrently.
const microzig = @import("microzig");
const io = @import("lp_io.zig");
const p = microzig.chip.peripherals;
const u = p.LP_UART;
pub const Error = error{ InvalidBaud, Timeout, RxFault };
pub const Config = struct {
    baud: u32 = 115200,
    clock: enum { lp_fast, xtal_d2 } = .lp_fast,
    /// Actual source frequency: calibrate LP_FAST for accurate external baud.
    source_hz: u32,
    loopback: bool = false,
};

pub fn apply(config: Config, poll_limit: u32) Error!void {
    if (config.baud == 0) return error.InvalidBaud;
    const divider = (@as(u64, config.source_hz) * 16) / config.baud;
    if (divider < 16 or divider > 0xffff) return error.InvalidBaud;
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    // TRM §27.4.1, IDF lp_uart_ll_enable_bus_clock/reset_register.
    p.LP_PERI.CLK_EN.modify(.{ .LP_UART_CK_EN = 1 });
    p.LP_PERI.RESET_EN.modify(.{ .LP_UART_RESET_EN = 1 });
    p.LP_PERI.RESET_EN.modify(.{ .LP_UART_RESET_EN = 0 });
    p.LP_CLKRST.LPPERI.modify(.{ .LP_UART_CLK_SEL = @intFromBool(config.clock == .xtal_d2) });
    u.CLK_CONF.modify(.{ .TX_SCLK_EN = 1, .RX_SCLK_EN = 1 });
    u.INT_ENA.raw = 0;
    u.INT_CLR.raw = 0x000c7fff; // Defined W1C flags only; reserved bits stay zero.
    u.CLKDIV_SYNC.write(.{ .CLKDIV = @intCast(divider >> 4), .CLKDIV_FRAG = @truncate(divider) });
    u.CONF0_SYNC.write(.{ .BIT_NUM = 3, .STOP_BIT_NUM = 1, .MEM_CLK_EN = 1, .LOOPBACK = @intFromBool(config.loopback), .RXFIFO_RST = 1, .TXFIFO_RST = 1 });
    try sync(poll_limit);
    u.CONF0_SYNC.modify(.{ .RXFIFO_RST = 0, .TXFIFO_RST = 0 });
    try sync(poll_limit);
    // TRM Table 7.13-1: fixed GPIO4 RX / GPIO5 TX. Loopback needs no pads.
    if (!config.loopback) {
        io.apply(4, .{ .function = .peripheral });
        io.apply(5, .{ .function = .peripheral, .input = false, .output = true, .initial_level = 1 });
    }
}

fn sync(poll_limit: u32) Error!void {
    u.REG_UPDATE.write(.{ .REG_UPDATE = 1 });
    var left = poll_limit;
    while (u.REG_UPDATE.read().REG_UPDATE != 0) {
        if (left == 0) return error.Timeout;
        left -= 1;
    }
}

pub fn write_byte(byte: u8, poll_limit: u32) Error!void {
    var left = poll_limit;
    while (u.AFIFO_STATUS.read().TX_AFIFO_FULL != 0) {
        if (left == 0) return error.Timeout;
        left -= 1;
    }
    u.FIFO.write(.{ .RXFIFO_RD_BYTE = byte });
}

pub fn read_byte(poll_limit: u32) Error!u8 {
    var left = poll_limit;
    while (true) {
        const raw = u.INT_RAW.read();
        if (raw.PARITY_ERR_INT_RAW != 0 or raw.FRM_ERR_INT_RAW != 0 or raw.RXFIFO_OVF_INT_RAW != 0) {
            u.INT_CLR.write(.{ .PARITY_ERR_INT_CLR = 1, .FRM_ERR_INT_CLR = 1, .RXFIFO_OVF_INT_CLR = 1 });
            return error.RxFault;
        }
        if (u.STATUS.read().RXFIFO_CNT != 0) return u.FIFO.read().RXFIFO_RD_BYTE;
        if (left == 0) return error.Timeout;
        left -= 1;
    }
}
