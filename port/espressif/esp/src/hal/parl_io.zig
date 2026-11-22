//! C6 PARL_IO, 1/2/4/8 data lines, XTAL-clocked master TX and external-clock RX.
//! C6 TRM §38.5.1–38.5.4, §38.6. Caller exclusively owns PARL_IO, pins and
//! the selected GDMA pair. No interrupts or allocation; initialize gdma first.
const microzig = @import("microzig");
const compatibility = @import("compatibility.zig");
const gpio = @import("gpio.zig");
const gdma = @import("gdma.zig");
const time = @import("time.zig");
comptime {
    if (compatibility.chip != .esp32_c6) @compileError("PARL_IO requires ESP32-C6");
}
const hw = microzig.chip.peripherals.PARL_IO;
const pcr = microzig.chip.peripherals.PCR;
pub const Width = enum(u3) { bits8 = 1, bits4 = 2, bits2 = 3, bits1 = 4 };
pub const Config = struct {
    width: Width = .bits8,
    /// TX bit clock = XTAL / clock_divider; 40 gives 1 MHz on a 40 MHz XTAL.
    clock_divider: u16 = 40,
    tx_data: []const gpio.Pin = &.{},
    rx_data: []const gpio.Pin = &.{},
    tx_clock: ?gpio.Pin = null,
    rx_clock: ?gpio.Pin = null,
    /// Optional TXD15 valid output and active-high RX enable on RXD15.
    tx_valid: ?gpio.Pin = null,
    rx_valid: ?gpio.Pin = null,
};
pub const Error = gdma.Error || error{ InvalidConfig, InvalidLength, OverlappingMemory, Timeout, ClockGateFailed, RxOverflow, ShortRead };

fn output(pin: gpio.Pin, signal: gpio.OutputSignal) void {
    pin.apply(.{ .input_enable = true, .output_enable = true });
    pin.connect_peripheral_to_output(.{ .signal = signal });
}
fn input(pin: gpio.Pin, signal: gpio.InputSignal) void {
    pin.set_input_enabled(true);
    pin.connect_input_to_peripheral(.{ .signal = signal });
}

pub fn Port(comptime channel: u2) type {
    return struct {
        const dma = gdma.Channel(channel);
        /// Finite TX, RX or duplex frame. Each buffer must be word-aligned and
        /// 4..65532 bytes, a multiple of four. Pins remain routed after return.
        /// TX cleanup gates the clock and clears START (C6 TRM v1.2 §38.6.2,
        /// steps 14–15); it does not disable pad outputs. For a bidirectional
        /// peer, the caller must apply(.{}) to every TX pad immediately on
        /// return, including errors. RX-only setup never enables pad outputs.
        /// RX without rx_valid uses software enable; the sender must start later.
        /// Every TX stretches the clock during setup: allow about 2 ms at a
        /// 40 MHz XTAL plus frame time in timeout_us (the whole-call budget).
        /// ClockGateFailed means the gated pad remained high, not a timeout.
        pub fn transfer(config: Config, buffers: gdma.Transfer, timeout_us: u32) Error!void {
            const tx = buffers.tx != null;
            const rx = buffers.rx != null;
            const width: usize = @as(usize, 16) >> @backingInt(config.width);
            if (config.clock_divider < 2 or (tx and (config.tx_data.len != width or config.tx_clock == null)) or
                (rx and (config.rx_data.len != width or config.rx_clock == null))) return error.InvalidConfig;
            // One output driver per pad; inputs may deliberately share TX pads.
            var outputs: [10]gpio.Pin = undefined;
            var output_count: usize = 0;
            if (tx) {
                for (config.tx_data) |pin| {
                    outputs[output_count] = pin;
                    output_count += 1;
                }
                outputs[output_count] = config.tx_clock.?;
                output_count += 1;
                if (config.tx_valid) |pin| {
                    outputs[output_count] = pin;
                    output_count += 1;
                }
            }
            for (outputs[0..output_count], 0..) |pin, i| {
                for (outputs[0..i]) |other| {
                    if (pin == other) return error.InvalidConfig;
                }
            }
            for ([_]?[]const u8{ buffers.tx, if (buffers.rx) |data| data else null }) |maybe_data| {
                if (maybe_data) |data| {
                    if (data.len < 4 or data.len > 65532 or data.len % 4 != 0 or @intFromPtr(data.ptr) % 4 != 0)
                        return error.InvalidLength;
                }
            }
            const lists = try gdma.prepare_transfer(buffers);
            const deadline = microzig.drivers.time.make_timeout_us(time.get_time_since_boot(), timeout_us);
            // §38.5.2: reset APB, async FIFOs with a free-running clock, then cores.
            pcr.PARL_IO_CONF.modify(.{ .PARL_CLK_EN = 1, .PARL_RST_EN = 1 });
            pcr.PARL_IO_CONF.modify(.{ .PARL_RST_EN = 0 });
            dma.reset();
            defer stop();
            pcr.PARL_CLK_TX_CONF.modify(.{ .PARL_CLK_TX_SEL = 0, .PARL_CLK_TX_DIV_NUM = config.clock_divider - 1, .PARL_CLK_TX_EN = 1 });
            pcr.PARL_CLK_RX_CONF.modify(.{ .PARL_CLK_RX_SEL = 0, .PARL_CLK_RX_DIV_NUM = 0, .PARL_CLK_RX_EN = 1 });
            hw.TX_CFG0.modify(.{ .TX_FIFO_SRST = 1 });
            hw.RX_CFG0.modify(.{ .RX_FIFO_SRST = 1 });
            time.sleep_us(2);
            hw.TX_CFG0.modify(.{ .TX_FIFO_SRST = 0 });
            hw.RX_CFG0.modify(.{ .RX_FIFO_SRST = 0 });
            time.sleep_us(2);
            pcr.PARL_CLK_TX_CONF.modify(.{ .PARL_TX_RST_EN = 1 });
            pcr.PARL_CLK_RX_CONF.modify(.{ .PARL_RX_RST_EN = 1 });
            pcr.PARL_CLK_TX_CONF.modify(.{ .PARL_TX_RST_EN = 0 });
            pcr.PARL_CLK_RX_CONF.modify(.{ .PARL_RX_RST_EN = 0 });
            hw.INT_ENA.write_raw(0);
            hw.INT_CLR.write_raw(7);
            if (rx) {
                for (config.rx_data) |pin| pin.apply(.{ .input_enable = true });
                config.rx_clock.?.apply(.{ .input_enable = true });
                if (config.rx_valid) |pin| pin.apply(.{ .input_enable = true });
            }
            if (tx) {
                for (config.tx_data, 0..) |pin, i| output(pin, @fromBackingInt(@as(u8, @intCast(47 + i))));
                if (config.tx_valid) |pin| output(pin, .parl_data15);
                hw.TX_CFG0.modify(.{ .TX_BYTELEN = @as(u16, @intCast(buffers.tx.?.len)), .TX_BUS_WID_SEL = @backingInt(config.width), .TX_HW_VALID_EN = @as(u1, @intFromBool(config.tx_valid != null)), .TX_GATING_EN = 0, .TX_SMP_EDGE_SEL = 0, .TX_BIT_UNPACK_ORDER = 0 });
                hw.TX_CFG1.modify(.{ .TX_IDLE_VALUE = 0 });
                dma.start(.tx, 9, lists.tx);
                while (hw.ST.read().TX_READY == 0) {
                    if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
                }
                // §38.5.2, §38.6: prime TX with a running core clock, then
                // stop it before arming RX. Without valid gating, any idle
                // clock edges would otherwise be sampled as frame data.
                // Stretch the clock before routing it to the pad, so a
                // receiver sees only the gating edges, not a burst lasting
                // as long as the wait above (longer from a cold cache).
                pcr.PARL_CLK_TX_CONF.modify(.{ .PARL_CLK_TX_DIV_NUM = 0xffff });
                output(config.tx_clock.?, gpio.OutputSignal.parl_tx_clk);
                try stop_tx_clock_low(config.tx_clock.?, config.clock_divider, deadline);
            }
            if (rx) {
                for (config.rx_data, 0..) |pin, i| input(pin, @fromBackingInt(@as(u8, @intCast(47 + i))));
                input(config.rx_clock.?, .parl_rx_clk);
                if (config.rx_valid) |pin| input(pin, .parl_data15);
                hw.RX_CFG0.modify(.{ .RX_DATA_BYTELEN = @as(u16, @intCast(buffers.rx.?.len)), .RX_BUS_WID_SEL = @backingInt(config.width), .RX_EOF_GEN_SEL = 0, .RX_SMP_MODE_SEL = @as(u2, if (config.rx_valid != null) 0 else 2), .RX_SW_EN = 1, .RX_LEVEL_SUBMODE_SEL = 0, .RX_CLK_EDGE_SEL = 1, .RX_BIT_PACK_ORDER = 0 });
                hw.RX_CFG1.modify(.{ .RX_TIMEOUT_EN = 0, .RX_EXT_EN_SEL = 15, .RX_REG_UPDATE = 1 });
                // Keep the internal clock running through configuration CDC
                // (C6 TRM v1.2 §38.5.2, Register 38.2). Waiting here after
                // switching to an idle external clock would prevent arming.
                while (hw.RX_CFG1.read().RX_REG_UPDATE != 0) {
                    if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
                }
                dma.start(.rx, 9, lists.rx);
                // §38.5.2: gate, assert START, ungate, then let the peer send.
                // No external edge is required before transfer reaches its
                // bounded completion wait, so an idle-low peer can start later.
                pcr.PARL_CLK_RX_CONF.modify(.{ .PARL_CLK_RX_EN = 0, .PARL_CLK_RX_SEL = 3, .PARL_CLK_RX_DIV_NUM = 0 });
                hw.RX_CFG0.modify(.{ .RX_START = 1 });
                pcr.PARL_CLK_RX_CONF.modify(.{ .PARL_CLK_RX_EN = 1 });
            }
            if (tx) {
                // RX is armed; release the first TX edge only after TX_START.
                hw.TX_CFG0.modify(.{ .TX_START = 1 });
                pcr.PARL_CLK_TX_CONF.modify(.{ .PARL_CLK_TX_EN = 1 });
            }
            while (true) {
                const status = hw.INT_RAW.read();
                if (status.RX_FIFO_WFULL_INT_RAW != 0) return error.RxOverflow;
                if (try dma.completed(tx, rx) and (!tx or status.TX_EOF_INT_RAW != 0)) break;
                if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
            }
            if (rx and !gdma.received(lists.rx, buffers.rx.?.len)) return error.ShortRead;
        }
        /// Gate low so RX does not sample idle data on the first falling edge
        /// before TX drives data on the rising edge (C6 TRM §38.5.3).
        /// Stretch to factor 65535 (§38.5.1): period about 1.64 ms at 40 MHz,
        /// each phase about 32768 XTAL cycles. Applying DIV_NUM mid-count is
        /// a prior hardware observation (16/16 tests at divider 40), not a TRM
        /// guarantee. tx_clock is input-enabled by output().
        fn stop_tx_clock_low(clock: gpio.Pin, divider: u16, deadline: microzig.drivers.time.Absolute) Error!void {
            pcr.PARL_CLK_TX_CONF.modify(.{ .PARL_CLK_TX_DIV_NUM = 0xffff });
            while (true) {
                if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
                for ([_]u1{ 1, 0 }) |level| {
                    while (clock.read() != level) {
                        if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
                    }
                }
                // An ISR may have consumed the low phase. Recheck with IRQs
                // masked and retry if necessary; never mask the phase wait.
                const cs = microzig.interrupt.enter_critical_section();
                defer cs.leave();
                if (clock.read() != 0) continue;
                pcr.PARL_CLK_TX_CONF.modify(.{ .PARL_CLK_TX_EN = 0 });
                break;
            }
            pcr.PARL_CLK_TX_CONF.modify(.{ .PARL_CLK_TX_DIV_NUM = divider - 1 });
            time.sleep_us(2);
            if (clock.read() != 0) return error.ClockGateFailed;
        }

        fn stop() void {
            pcr.PARL_CLK_TX_CONF.modify(.{ .PARL_CLK_TX_EN = 0 });
            pcr.PARL_CLK_RX_CONF.modify(.{ .PARL_CLK_RX_EN = 0 });
            hw.TX_CFG0.modify(.{ .TX_START = 0 });
            hw.RX_CFG0.modify(.{ .RX_START = 0 });
            pcr.PARL_IO_CONF.modify(.{ .PARL_RST_EN = 1 });
            dma.reset();
        }
    };
}
