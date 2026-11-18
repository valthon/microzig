const microzig = @import("microzig");
const uart = @import("../uart.zig");
const system = @import("../system.zig");
const time = @import("../time.zig");
const mtime = microzig.drivers.time;
const timing = @import("timing.zig");

fn regs(index: u1) *volatile microzig.chip.types.peripherals.UART0 {
    return if (index == 0) microzig.chip.peripherals.UART0 else microzig.chip.peripherals.UART1;
}

pub fn init(index: u1, config: uart.Config) uart.ConfigError!void {
    const div = try timing.calculate(40_000_000, config.baud_rate);
    const r = regs(index);
    const mask: system.PeripheralMask = if (index == 0) .{ .uart0 = true } else .{ .uart1 = true };
    system.enable_clocks_and_release_reset(mask);
    // C6 TRM v1.2 §§27.4.1, 27.7.1: separate TX/RX core resets.
    r.CLK_CONF.modify(.{ .TX_RST_CORE = 1, .RX_RST_CORE = 1 });
    system.peripheral_reset(mask);
    r.CLK_CONF.modify(.{ .TX_RST_CORE = 0, .RX_RST_CORE = 0 });
    r.INT_ENA.write_raw(0);
    const deadline = mtime.Deadline.init_relative(time.get_time_since_boot(), .from_ms(100));
    try wait_update(r, deadline);
    // PCR supplies the HP UART clock, including the predivider (C6 TRM
    // v1.2 §8.5.1 registers 8.2/8.5, §§27.3, 27.5.2).
    if (index == 0) {
        microzig.chip.peripherals.PCR.UART0_SCLK_CONF.write(.{
            .UART0_SCLK_SEL = 3,
            .UART0_SCLK_DIV_NUM = div.clock,
            .UART0_SCLK_EN = 1,
        });
    } else {
        microzig.chip.peripherals.PCR.UART1_SCLK_CONF.write(.{
            .UART1_SCLK_SEL = 3,
            .UART1_SCLK_DIV_NUM = div.clock,
            .UART1_SCLK_EN = 1,
        });
    }
    r.CLK_CONF.modify(.{ .TX_SCLK_EN = 0, .RX_SCLK_EN = 0 });
    // _SYNC registers cross into the core clock domain via REG_UPDATE (§27.5.1).
    r.IDLE_CONF_SYNC.modify(.{ .TX_IDLE_NUM = 0 });
    r.CLKDIV_SYNC.write(.{ .CLKDIV = div.integer, .CLKDIV_FRAG = div.fraction });
    r.CONF0_SYNC.write(.{
        .BIT_NUM = @backingInt(config.data_bits),
        .STOP_BIT_NUM = @backingInt(config.stop_bits),
        .PARITY_EN = @intFromBool(config.parity != .none),
        .PARITY = @intFromBool(config.parity == .odd),
        .MEM_CLK_EN = 1,
    });
    // HP UARTs have fixed, separate 128-byte RX/TX RAMs (§27.4.2),
    // so there are no C3-style MEM_CONF RX_SIZE/TX_SIZE fields to program.
    r.CONF1.write(.{ .RXFIFO_FULL_THRHD = 120, .TXFIFO_EMPTY_THRHD = 16 });
    r.CLK_CONF.modify(.{ .TX_SCLK_EN = 1, .RX_SCLK_EN = 1 });
    r.REG_UPDATE.write(.{ .REG_UPDATE = 1 });
    try wait_update(r, deadline);
    r.CONF0_SYNC.modify(.{ .RXFIFO_RST = 1, .TXFIFO_RST = 1 });
    r.REG_UPDATE.write(.{ .REG_UPDATE = 1 });
    try wait_update(r, deadline);
    r.CONF0_SYNC.modify(.{ .RXFIFO_RST = 0, .TXFIFO_RST = 0 });
    r.REG_UPDATE.write(.{ .REG_UPDATE = 1 });
    try wait_update(r, deadline);
    r.INT_CLR.write_raw(0xffff_ffff);
}

fn wait_update(r: *volatile microzig.chip.types.peripherals.UART0, deadline: mtime.Deadline) error{Timeout}!void {
    while (r.REG_UPDATE.read().REG_UPDATE != 0) {
        if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
    }
}
