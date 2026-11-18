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
    system.enable_clocks_and_release_reset(mask.combine(.{ .uart_mem = true }));
    // Reset both clock domains together, as required by §26.4.1.
    r.CLK_CONF.modify(.{ .RST_CORE = 1 });
    system.peripheral_reset(mask);
    r.CLK_CONF.modify(.{ .RST_CORE = 0 });
    r.INT_ENA.write_raw(0);
    r.ID.modify(.{ .HIGH_SPEED = 0 }); // UPDATE_CTRL in the TRM.
    const deadline = mtime.Deadline.init_relative(time.get_time_since_boot(), .from_ms(100));
    try wait_update(r, deadline);
    r.CLK_CONF.write(.{
        .SCLK_SEL = 3,
        .SCLK_DIV_NUM = div.clock,
        .SCLK_DIV_A = 0,
        .SCLK_DIV_B = 0,
        .SCLK_EN = 1,
        .TX_SCLK_EN = 0,
        .RX_SCLK_EN = 0,
    });
    // Static registers are sampled when TX/RX clocks are enabled (§26.5.1.2).
    r.IDLE_CONF.modify(.{ .TX_IDLE_NUM = 0 });
    r.CLKDIV.write(.{ .CLKDIV = div.integer, .FRAG = div.fraction });
    r.CONF0.write(.{
        .BIT_NUM = @backingInt(config.data_bits),
        .STOP_BIT_NUM = @backingInt(config.stop_bits),
        .PARITY_EN = @intFromBool(config.parity != .none),
        .PARITY = @intFromBool(config.parity == .odd),
        .MEM_CLK_EN = 1,
    });
    r.CONF1.write(.{ .RXFIFO_FULL_THRHD = 120, .TXFIFO_EMPTY_THRHD = 16 });
    r.MEM_CONF.modify(.{ .RX_SIZE = 1, .TX_SIZE = 1 });
    r.CLK_CONF.modify(.{ .TX_SCLK_EN = 1, .RX_SCLK_EN = 1 });
    r.ID.modify(.{ .REG_UPDATE = 1 });
    try wait_update(r, deadline);
    r.CONF0.modify(.{ .RXFIFO_RST = 1, .TXFIFO_RST = 1 });
    r.CONF0.modify(.{ .RXFIFO_RST = 0, .TXFIFO_RST = 0 });
    r.INT_CLR.write_raw(0xffff_ffff);
}

fn wait_update(r: *volatile microzig.chip.types.peripherals.UART0, deadline: mtime.Deadline) error{Timeout}!void {
    while (r.ID.read().REG_UPDATE != 0) {
        if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
    }
}
