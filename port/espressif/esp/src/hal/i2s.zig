//! I2S0 Philips stereo over GDMA, 16- or 32-bit samples in equal-width slots.
//! C6 TRM v1.2 §30.5.1, §30.6–30.11; C3 TRM I2S controller uses the same
//! data-path layout, with clock registers in I2S instead of PCR.
//! Caller exclusively owns I2S0, its pins and the chosen GDMA pair. Initialize
//! gdma and HAL time first. No allocation, interrupts, PDM or fractional clocks.
const std = @import("std");
const microzig = @import("microzig");
const compatibility = @import("compatibility.zig");
const system = @import("system.zig");
const gpio = @import("gpio.zig");
const gdma = @import("gdma.zig");
const time = @import("time.zig");
const hw = switch (compatibility.chip) {
    .esp32_c3 => microzig.chip.peripherals.I2S,
    .esp32_c6 => microzig.chip.peripherals.I2S0,
};
pub const SampleBits = enum(u6) { bits16 = 16, bits32 = 32 };
pub const Config = struct {
    bits: SampleBits = .bits16,
    bck: gpio.Pin,
    ws: gpio.Pin,
    tx_data: ?gpio.Pin = null,
    rx_data: ?gpio.Pin = null,
    /// BCK = PLL160M / clock_divider / bck_divider. Sample rate is
    /// BCK / (2 * bits). Both dividers are integer; no rate rounding is hidden.
    clock_divider: u8 = 20,
    /// At least eight core clocks per BCK, including the duplex RX slave.
    bck_divider: u7 = 8,
    /// RX_EOF_NUM byte-count override for silicon diagnostics. Null selects
    /// rx.len bytes. RX capacity and duplex TX data must cover this byte count.
    rx_eof_num: ?u12 = null,
};
pub const Error = gdma.Error || error{ InvalidConfig, InvalidLength, OverlappingMemory, Timeout, PeripheralFault, ShortRead };

/// Program RX_EOF_NUM in one place. C6 TRM v1.2 register 30.10 says received
/// bits = (RX_BITS_MOD + 1) * (RX_EOF_NUM + 1). ESP-IDF instead passes bytes:
/// esp_hal_i2s/{esp32c3,esp32c6}/include/hal/i2s_ll.h, i2s_ll_rx_set_eof_num,
/// and esp_driver_i2s/i2s_common.c:553, i2s_ll_rx_set_eof_num(..., bufsize).
/// Hardware settles it for bytes: with RX_BITS_MOD = 31 and RX_EOF_NUM = 64,
/// selftest_i2s saw the first EOF after 64 bytes, not the TRM's 260, on an
/// ESP32-C3 rev v0.4 and an ESP32-C6 rev v0.2.
fn set_rx_eof_num(value: u12) void {
    hw.RXEOF_NUM.write(.{ .RX_EOF_NUM = value });
}

fn configure_clocks(config: Config, tx: bool) void {
    // C6 §30.6: set a small integer divider first, then the fractional
    // coefficients, then the requested integer divider. The small-divider
    // transition also follows ESP-IDF i2s_ll_*_set_raw_clk_div's workaround.
    if (compatibility.chip == .esp32_c6) {
        const pcr = microzig.chip.peripherals.PCR;
        pcr.I2S_TX_CLKM_CONF.modify(.{ .I2S_TX_CLKM_EN = 1, .I2S_TX_CLKM_SEL = 2, .I2S_TX_CLKM_DIV_NUM = 2 });
        pcr.I2S_RX_CLKM_CONF.modify(.{ .I2S_RX_CLKM_EN = 1, .I2S_RX_CLKM_SEL = 2, .I2S_RX_CLKM_DIV_NUM = 2, .I2S_MCLK_SEL = @as(u1, @intFromBool(!tx)) });
        pcr.I2S_TX_CLKM_DIV_CONF.write(.{ .I2S_TX_CLKM_DIV_X = 0, .I2S_TX_CLKM_DIV_Y = 1, .I2S_TX_CLKM_DIV_Z = 0, .I2S_TX_CLKM_DIV_YN1 = 0 });
        pcr.I2S_RX_CLKM_DIV_CONF.write(.{ .I2S_RX_CLKM_DIV_X = 0, .I2S_RX_CLKM_DIV_Y = 1, .I2S_RX_CLKM_DIV_Z = 0, .I2S_RX_CLKM_DIV_YN1 = 0 });
        pcr.I2S_TX_CLKM_CONF.modify(.{ .I2S_TX_CLKM_DIV_NUM = config.clock_divider });
        pcr.I2S_RX_CLKM_CONF.modify(.{ .I2S_RX_CLKM_DIV_NUM = config.clock_divider });
    } else {
        hw.TX_CLKM_CONF.modify(.{ .CLK_EN = 1, .TX_CLK_ACTIVE = 1, .TX_CLK_SEL = 2, .TX_CLKM_DIV_NUM = 2 });
        hw.RX_CLKM_CONF.modify(.{ .RX_CLK_ACTIVE = 1, .RX_CLK_SEL = 2, .RX_CLKM_DIV_NUM = 2, .MCLK_SEL = @as(u1, @intFromBool(!tx)) });
        hw.TX_CLKM_DIV_CONF.write(.{ .TX_CLKM_DIV_X = 0, .TX_CLKM_DIV_Y = 1, .TX_CLKM_DIV_Z = 0, .TX_CLKM_DIV_YN1 = 0 });
        hw.RX_CLKM_DIV_CONF.write(.{ .RX_CLKM_DIV_X = 0, .RX_CLKM_DIV_Y = 1, .RX_CLKM_DIV_Z = 0, .RX_CLKM_DIV_YN1 = 0 });
        hw.TX_CLKM_CONF.modify(.{ .TX_CLKM_DIV_NUM = config.clock_divider });
        hw.RX_CLKM_CONF.modify(.{ .RX_CLKM_DIV_NUM = config.clock_divider });
    }
}

fn output(pin: gpio.Pin, signal: gpio.OutputSignal) void {
    pin.apply(.{ .input_enable = true, .output_enable = true });
    pin.connect_peripheral_to_output(.{ .signal = signal });
}

// C3 §2.4.1 / C6 §4.4.1: only count descriptors returned by DMA, ending
// at the first suc_eof descriptor. Never infer delivery from buffer contents.
fn received_bytes(list: []gdma.Descriptor) Error!usize {
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    var bytes: usize = 0;
    for (list) |*descriptor| {
        const ptr: *volatile gdma.Descriptor = descriptor;
        const control = ptr.control;
        if (control & (1 << 31) != 0) break;
        bytes += (control >> 12) & 0xfff;
        if (control & (1 << 30) != 0) return bytes;
    }
    return error.ShortRead;
}

pub fn Port(comptime channel: u2) type {
    return struct {
        const dma = gdma.Channel(channel);
        /// Blocking finite TX, RX or duplex transfer. TX is master; RX alone
        /// is master, and duplex RX shares TX BCK/WS internally as a slave.
        /// Buffers are disjoint word-aligned SRAM, whole interleaved L/R frames,
        /// at most 4092 bytes (4088 for 32-bit stereo). Pins remain routed.
        /// Returns bytes delivered at the first RX EOF, or zero for TX-only.
        /// Without a diagnostic override, a short receive is an error.
        /// On all exits DMA is stopped and cannot access buffers/descriptors.
        pub fn transfer(config: Config, buffers: gdma.Transfer, timeout_us: u32) Error!usize {
            const tx = buffers.tx != null;
            const rx = buffers.rx != null;
            if (config.clock_divider < 2 or config.bck_divider < 8 or config.bck_divider > 64 or
                (tx and config.tx_data == null) or (rx and config.rx_data == null) or
                (!rx and config.rx_eof_num != null) or config.bck == config.ws) return error.InvalidConfig;
            if (tx) {
                const pin = config.tx_data.?;
                if (pin == config.bck or pin == config.ws) return error.InvalidConfig;
            }
            if (rx) {
                const pin = config.rx_data.?;
                if (pin == config.bck or pin == config.ws) return error.InvalidConfig;
            }
            const frame_bytes: usize = @as(usize, @backingInt(config.bits)) / 4;
            for ([_]?[]const u8{ buffers.tx, if (buffers.rx) |data| data else null }) |maybe_data| {
                if (maybe_data) |data| {
                    if (data.len == 0 or data.len > 4092 or data.len % frame_bytes != 0 or @intFromPtr(data.ptr) % 4 != 0)
                        return error.InvalidLength;
                }
            }
            if (config.rx_eof_num) |value| {
                if (value == 0 or value > buffers.rx.?.len or (tx and value > buffers.tx.?.len)) return error.InvalidLength;
            } else if (tx and rx and buffers.tx.?.len < buffers.rx.?.len) return error.InvalidLength;
            const lists = try gdma.prepare_transfer(buffers);
            const deadline = microzig.drivers.time.make_timeout_us(time.get_time_since_boot(), timeout_us);
            system.clocks_enable_set(.{ .i2s0 = true });
            system.peripheral_reset(.{ .i2s0 = true });
            dma.reset();
            defer stop();
            configure_clocks(config, tx);
            // §30.7: clocks must run before resetting units and async FIFOs.
            hw.TX_CONF.modify(.{ .TX_RESET = 1, .TX_FIFO_RESET = 1 });
            hw.RX_CONF.modify(.{ .RX_RESET = 1, .RX_FIFO_RESET = 1 });
            hw.TX_CONF.modify(.{ .TX_RESET = 0, .TX_FIFO_RESET = 0 });
            hw.RX_CONF.modify(.{ .RX_RESET = 0, .RX_FIFO_RESET = 0 });
            hw.INT_ENA.write_raw(0);
            hw.INT_CLR.write_raw(15);
            // Use our explicit deadline rather than the peripheral's FIFO watchdog.
            hw.LC_HUNG_CONF.modify(.{ .LC_FIFO_TIMEOUT_ENA = 0 });
            hw.TX_CONF.write(.{ .TX_SLAVE_MOD = 0, .TX_TDM_EN = 1, .TX_PDM_EN = 0, .TX_MONO = 0, .TX_PCM_BYPASS = 1, .TX_STOP_EN = 1, .TX_BIG_ENDIAN = 0, .TX_BIT_ORDER = 0, .TX_LEFT_ALIGN = 1, .TX_WS_IDLE_POL = 0, .SIG_LOOPBACK = @as(u1, @intFromBool(tx and rx)) });
            hw.RX_CONF.write(.{ .RX_SLAVE_MOD = @as(u1, @intFromBool(tx)), .RX_TDM_EN = 1, .RX_PDM_EN = 0, .RX_MONO = 0, .RX_PCM_BYPASS = 1, .RX_STOP_MODE = 1, .RX_BIG_ENDIAN = 0, .RX_BIT_ORDER = 0, .RX_LEFT_ALIGN = 1, .RX_WS_IDLE_POL = 0 });
            const bits_minus_one: u5 = @intCast(@backingInt(config.bits) - 1);
            hw.TX_CONF1.modify(.{ .TX_BITS_MOD = bits_minus_one, .TX_TDM_CHAN_BITS = bits_minus_one, .TX_HALF_SAMPLE_BITS = bits_minus_one, .TX_TDM_WS_WIDTH = bits_minus_one, .TX_MSB_SHIFT = 1, .TX_BCK_DIV_NUM = @as(u6, @intCast(config.bck_divider - 1)) });
            hw.RX_CONF1.modify(.{ .RX_BITS_MOD = bits_minus_one, .RX_TDM_CHAN_BITS = bits_minus_one, .RX_HALF_SAMPLE_BITS = bits_minus_one, .RX_TDM_WS_WIDTH = bits_minus_one, .RX_MSB_SHIFT = 1, .RX_BCK_DIV_NUM = @as(u6, @intCast(config.bck_divider - 1)) });
            var tx_slots = std.mem.zeroes(@TypeOf(hw.TX_TDM_CTRL.read()));
            tx_slots.TX_TDM_CHAN0_EN = 1;
            tx_slots.TX_TDM_CHAN1_EN = 1;
            tx_slots.TX_TDM_TOT_CHAN_NUM = 1;
            hw.TX_TDM_CTRL.write(tx_slots);
            var rx_slots = std.mem.zeroes(@TypeOf(hw.RX_TDM_CTRL.read()));
            rx_slots.RX_TDM_PDM_CHAN0_EN = 1;
            rx_slots.RX_TDM_PDM_CHAN1_EN = 1;
            rx_slots.RX_TDM_TOT_CHAN_NUM = 1;
            hw.RX_TDM_CTRL.write(rx_slots);
            // Applying RX first preserves TX output routing when the data pad
            // is deliberately shared for no-wiring GPIO matrix loopback.
            if (rx) config.rx_data.?.apply(.{ .input_enable = true });
            output(config.bck, if (tx) .i2so_bck else .i2si_bck);
            output(config.ws, if (tx) .i2so_ws else .i2si_ws);
            if (tx) output(config.tx_data.?, .i2si_sd); // matrix signal 15 = I2SO_SD_out
            if (rx) config.rx_data.?.connect_input_to_peripheral(.{ .signal = .i2si_sd });
            hw.TX_CONF.modify(.{ .TX_UPDATE = 1 });
            hw.RX_CONF.modify(.{ .RX_UPDATE = 1 });
            while (hw.TX_CONF.read().TX_UPDATE != 0 or hw.RX_CONF.read().RX_UPDATE != 0) {
                if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
            }
            if (rx) {
                set_rx_eof_num(config.rx_eof_num orelse @as(u12, @intCast(buffers.rx.?.len)));
                dma.start(.rx, 3, lists.rx);
            }
            if (tx) dma.start(.tx, 3, lists.tx);
            // Arm RX before allowing TX to supply the first BCK/WS edge.
            if (rx) hw.RX_CONF.modify(.{ .RX_START = 1 });
            if (tx) hw.TX_CONF.modify(.{ .TX_START = 1 });
            while (true) {
                const status = hw.INT_RAW.read();
                if (status.TX_HUNG_INT_RAW != 0 or status.RX_HUNG_INT_RAW != 0) return error.PeripheralFault;
                if (try dma.completed(tx, rx) and (!tx or hw.STATE.read().TX_IDLE != 0)) break;
                if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
            }
            const actual = if (rx) try received_bytes(lists.rx) else 0;
            if (rx and config.rx_eof_num == null and actual != buffers.rx.?.len) return error.ShortRead;
            return actual;
        }

        fn stop() void {
            hw.TX_CONF.modify(.{ .TX_START = 0 });
            hw.RX_CONF.modify(.{ .RX_START = 0 });
            system.peripheral_reset_set(.{ .i2s0 = true });
            dma.reset();
        }
    };
}
