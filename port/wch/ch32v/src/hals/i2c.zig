//!
//! This file implements the I²C driver for the CH32V chip family
//!
//! Based on the WCH CH32V20x I2C peripheral implementation.
//! Reference: CH32V20x Reference Manual Section on I2C
//!
//! STOP/MSL status can change between sampling and issuing a command.
//! A deadline sample likewise precedes the separate access that issues
//! START, sends an address or data, enables DMA, or releases ADDR.
const microzig = @import("microzig");
const mdf = microzig.drivers;
const drivers = mdf.base;
const hal = microzig.hal;
const gpio = hal.gpio;
const dma = hal.dma;

const I2C1 = microzig.chip.peripherals.I2C1;
const I2C2 = microzig.chip.peripherals.I2C2;

const I2cRegs = microzig.chip.types.peripherals.I2C1;

pub const Address = drivers.I2C_Device.Address;
pub const AddressError = drivers.I2C_Device.Address.Error;
pub const Error = drivers.I2C_Device.Error || error{
    ArbitrationLost,
    TransferTooLong,
    DmaTransferFailed,
    /// STOP recovery failed. Reapply the I2C configuration after the bus is idle.
    RecoveryRequired,
    BusError,
    Overrun,
};

/// Pin remapping configuration for I2C peripherals
///
/// I2C1 has 2 configurations (1 bit: PCFR1.I2C1_RM):
///   .default (0): SCL=PB6,  SDA=PB7
///   .remap1  (1): SCL=PB8,  SDA=PB9
///
/// I2C2 has only 1 configuration (no remap available):
///   .default: SCL=PB10, SDA=PB11
///
/// See CH32V Reference Manual AFIO_PCFR1 section for details
pub const Remap = enum(u1) {
    default = 0,
    remap1 = 1,
};

pub const Config = struct {
    /// DMA configuration for I2C transfers (optional)
    /// When configured, enables DMA for transfers >= threshold bytes
    /// Smaller transfers automatically use polling mode
    pub const DmaConfig = struct {
        tx_channel: dma.Channel,
        rx_channel: dma.Channel,
        priority: dma.Priority = .Medium,
        /// Minimum transfer size in bytes to use DMA (smaller uses polling)
        /// Default: 16 bytes (conservative heuristic, not benchmarked)
        /// Lower this for testing or small-transfer optimization
        /// Increase this to reduce DMA overhead for small transfers
        threshold: usize = 16,
    };

    repeated_start: bool = true,
    baud_rate: u32 = 100_000,
    duty_cycle: DutyCycle = .duty_2,

    /// Optional DMA configuration - null means polling-only mode
    /// Example: .dma = .{ .tx_channel = .Ch6, .rx_channel = .Ch7 }
    dma: ?DmaConfig = null,
};

pub const DutyCycle = enum {
    duty_2, // I2C fast mode Tlow/Thigh = 2
    duty_16_9, // I2C fast mode Tlow/Thigh = 16/9
};

pub const ConfigError = error{
    UnsupportedBaudRate,
    InputFreqTooLow,
};

pub const Setup = struct {
    instance: I2C,
    scl_pin: gpio.Pin,
    sda_pin: gpio.Pin,
    /// AFIO pin remap — must match the pins chosen above.
    /// See the Remap enum doc comment for which pins each setting maps to.
    remap: Remap = .default,

    /// Apply settings: configure I2C pins and peripheral.
    pub fn apply(comptime self: Setup, comptime config: Config) void {
        self.scl_pin.configure_alternate_function(.open_drain, .max_50MHz);
        self.sda_pin.configure_alternate_function(.open_drain, .max_50MHz);
        self.instance.apply(config, self.remap);
    }
};

pub const instance = struct {
    pub const I2C1: I2C = @fromBackingInt(0);
    pub const I2C2: I2C = @fromBackingInt(1);
    pub fn num(instance_number: u2) I2C {
        return @fromBackingInt(instance_number - 1);
    }
};

pub const I2C = enum(u1) {
    _,

    const poll_limit = 100_000;

    pub inline fn get_regs(i2c: I2C) *volatile I2cRegs {
        return switch (@backingInt(i2c)) {
            0 => I2C1,
            1 => I2C2,
        };
    }

    inline fn disable(i2c: I2C) void {
        write_control(&i2c.get_regs().CTLR1, .{ .PE = 0 });
    }

    inline fn enable(i2c: I2C) void {
        write_control(&i2c.get_regs().CTLR1, .{ .PE = 1 });
    }

    /// Initializes the I2C HW block per the Config provided
    pub fn apply(comptime i2c: I2C, comptime config: Config, comptime remap: Remap) void {
        const regs = i2c.get_regs();

        // Compile-time DMA validation
        if (comptime config.dma) |dma_cfg| {
            const tx_peripheral = comptime if (@backingInt(i2c) == 0)
                dma.Peripheral.I2C1_TX
            else
                dma.Peripheral.I2C2_TX;
            const rx_peripheral = comptime if (@backingInt(i2c) == 0)
                dma.Peripheral.I2C1_RX
            else
                dma.Peripheral.I2C2_RX;

            // Ensure that these channels are compatible with these peripherals (compile error if invalid)
            comptime tx_peripheral.ensure_compatible_with(dma_cfg.tx_channel);
            comptime rx_peripheral.ensure_compatible_with(dma_cfg.rx_channel);
        }

        // Enable peripheral clock
        hal.clocks.enable_peripheral_clock(switch (@backingInt(i2c)) {
            0 => .I2C1,
            1 => .I2C2,
        });

        // Configure AFIO remap
        hal.clocks.enable_afio_clock();
        const AFIO = microzig.chip.peripherals.AFIO;
        switch (@backingInt(i2c)) {
            0 => AFIO.PCFR1.modify(.{ .I2C1_RM = @backingInt(remap) }),
            // I2C2 does not have remap support on CH32V20x
            1 => {},
        }

        // Get peripheral clock frequency
        const rcc_clocks = hal.clocks.get_freqs();
        const pclk1 = rcc_clocks.pclk1;

        // Set peripheral clock frequency in MHz (must be done before disable per WCH code)
        const freqrange: u6 = @intCast(@min(pclk1 / 1_000_000, 63));
        regs.CTLR2.modify(.{ .FREQ = freqrange });

        // Disable peripheral for configuration
        i2c.disable();

        // Calculate clock control register value
        var ccr: u16 = 0;
        if (config.baud_rate <= 100_000) {
            // Standard mode (≤100kHz)
            var result = @as(u16, @intCast(pclk1 / (config.baud_rate * 2)));
            if (result < 4) result = 4; // Minimum value
            ccr = result;

            // Rise time register: freqrange + 1
            regs.RTR.write(.{ .TRISE = freqrange + 1 });
        } else {
            // Fast mode (>100kHz)
            var result: u16 = 0;
            if (config.duty_cycle == .duty_2) {
                result = @intCast(pclk1 / (config.baud_rate * 3));
            } else {
                result = @intCast(pclk1 / (config.baud_rate * 25));
                result |= 0x4000; // Set duty cycle bit
            }

            if ((result & 0x0FFF) == 0) {
                result |= 0x0001; // Minimum value
            }

            ccr = result | 0x8000; // Set F/S bit for fast mode

            // Rise time register: ((freqrange * 300) / 1000) + 1
            const trise: u6 = @intCast(((@as(u32, freqrange) * 300) / 1000) + 1);
            regs.RTR.write(.{ .TRISE = trise });
        }

        // Write clock configuration
        regs.CKCFGR.write_raw(ccr);

        // Enable peripheral first
        i2c.enable();

        // Configure control register 1 - clear mode bits and set I2C mode + ACK
        // This matches: tmpreg &= CTLR1_CLEAR_Mask; tmpreg |= (I2C_Mode_I2C | I2C_Ack_Enable);
        write_control(&regs.CTLR1, .{
            .SMBUS = 0, // I2C mode (not SMBus)
            .SMBTYPE = 0, // Not used in I2C mode
            .ACK = 1, // Enable ACK
            .ENGC = 0, // Disable general call
        });

        // Enable DMA mode in I2C peripheral if configured
        regs.CTLR2.modify(.{ .DMAEN = @intFromBool(config.dma != null), .LAST = 0 });
    }

    /// Disables I2C, returns peripheral registers to reset state.
    pub fn reset(i2c: I2C) void {
        i2c.disable();
    }

    // A failed STOP recovery leaves PE clear. Reapply configuration before retrying.
    fn begin_transfer(i2c: I2C, ack: bool, deadline: mdf.time.Deadline) Error!void {
        const regs = i2c.get_regs();
        try require_enabled(regs.CTLR1.read().PE);
        try i2c.wait_for_bus_idle(deadline);
        write_control(&regs.CTLR1, .{ .ACK = @intFromBool(ack) });
        write_control(&regs.CTLR1, .{ .START = 1 });
    }

    /// Generate STOP condition
    inline fn generate_stop(i2c: I2C) void {
        write_control(&i2c.get_regs().CTLR1, .{ .STOP = 1, .ACK = 0 });
    }

    fn abort_transfer(i2c: I2C) void {
        // Allow a short, independent STOP recovery after a transfer timeout.
        // The poll cap also applies if the TIM2 tick is interrupted or stopped.
        const recovery_deadline = hal.time.deadline_in_ms(2);
        recover_after_abort(i2c, recovery_deadline, hal.time.get_time_since_boot);
    }

    fn prepare_abort(i2c: I2C) void {
        const control = &i2c.get_regs().CTLR1;
        // A pending STOP already disabled ACK. Let hardware finish it
        // without writing either command bit during that interval.
        if (control.read().STOP == 0) write_control(control, .{ .ACK = 0 });
    }

    fn poll_abort(i2c: I2C) bool {
        const regs = i2c.get_regs();
        const status = regs.STAR1.read();
        const bus = regs.STAR2.read();
        // RM §19.12.6: STAR1 then STAR2 releases ADDR stretching. Reading
        // DATAR releases RXNE/BTF stretching while STOP is pending.
        if (status.RxNE == 1) _ = regs.DATAR.read();
        const control = regs.CTLR1.read();
        if (bus.MSL == 1 and status.ARLO == 0 and control.STOP == 0) i2c.generate_stop();
        if (bus.MSL == 0 and status.ARLO != 0 and control.STOP != 0)
            write_control(&regs.CTLR1, .{ .STOP = 0 });
        return !local_stop_pending(bus.MSL, control.STOP, status.ARLO);
    }

    fn can_reset_after_abort(i2c: I2C) bool {
        const regs = i2c.get_regs();
        // A completed or lost transaction can still have one byte waiting in
        // DATAR and one in the shifter. Discard both without changing PE.
        for (0..2) |_| {
            if (regs.STAR1.read().RxNE == 0) break;
            _ = regs.DATAR.read();
        }
        const status = regs.STAR1.read();
        const lost_arbitration = status.ARLO != 0;
        // DMA may have returned a timeout before observing a bus error.
        // Clear those flags while preserving the original transfer error.
        clear_errors(&regs.STAR1, status, true);
        return may_reset_after_abort(lost_arbitration, regs.STAR2.read().BUSY != 0);
    }

    fn bus_idle(i2c: I2C) error{}!bool {
        const regs = i2c.get_regs();
        return regs.STAR2.read().BUSY == 0 and regs.CTLR1.read().STOP == 0;
    }

    fn wait_for_bus_idle(i2c: I2C, deadline: mdf.time.Deadline) Error!void {
        try hal.time.wait_until_ready(i2c, bus_idle, deadline, hal.time.get_time_since_boot, poll_limit);
    }

    fn wait_for_stop(i2c: I2C, deadline: mdf.time.Deadline) Error!void {
        const Poll = struct {
            fn ready(bus: I2C) TerminalError!bool {
                try bus.poll_errors();
                return bus.bus_idle();
            }
        };
        try hal.time.wait_until_ready(i2c, Poll.ready, deadline, hal.time.get_time_since_boot, poll_limit);
    }

    /// Send 7-bit address with direction bit
    inline fn send_address(i2c: I2C, addr: Address, direction: enum { write, read }) void {
        const addr_byte = @as(u8, @backingInt(addr)) << 1 | @intFromBool(direction == .read);
        i2c.get_regs().DATAR.write_raw(addr_byte);
    }

    fn wait_flag_star1(i2c: I2C, comptime flag_name: []const u8, deadline: mdf.time.Deadline) Error!void {
        const Poll = struct {
            fn ready(bus: I2C) Error!bool {
                const status = bus.get_regs().STAR1.read();
                try bus.check_errors(status);
                return @field(status, flag_name) == 1;
            }
        };
        try hal.time.wait_until_ready(i2c, Poll.ready, deadline, hal.time.get_time_since_boot, poll_limit);
    }

    fn check_errors(i2c: I2C, status: @TypeOf(i2c.get_regs().STAR1.read())) TerminalError!void {
        terminal_error(status) catch |err| {
            // Hold ARLO for abort, even if another flag was present in this sample.
            clear_errors(&i2c.get_regs().STAR1, status, false);
            return err;
        };
    }

    fn poll_errors(i2c: I2C) TerminalError!void {
        try i2c.check_errors(i2c.get_regs().STAR1.read());
    }

    fn wait_for_dma(i2c: I2C, comptime channel: dma.Channel, deadline: mdf.time.Deadline) Error!void {
        const Poll = struct {
            fn ready(bus: I2C) Error!bool {
                return dma.poll_peripheral_transfer(bus, poll_errors, .{channel});
            }
        };
        try hal.time.wait_until_ready(i2c, Poll.ready, deadline, hal.time.get_time_since_boot, null);
    }

    /// Attempts to write bytes to target device and blocks until complete, error, or timeout
    pub fn write_blocking(i2c: I2C, addr: Address, data: []const u8, timeout: ?mdf.time.Duration) Error!void {
        return i2c.writev_blocking(addr, &.{data}, timeout);
    }

    /// Vectored write - writes multiple buffers in sequence
    pub fn writev_blocking(i2c: I2C, addr: Address, chunks: []const []const u8, timeout: ?mdf.time.Duration) Error!void {
        const regs = i2c.get_regs();
        const write_vec = microzig.utilities.SliceVector([]const u8).init(chunks);

        if (write_vec.size() == 0) return Error.NoData;

        const deadline = mdf.time.Deadline.init_relative(hal.time.get_time_since_boot(), timeout);

        try i2c.begin_transfer(false, deadline);
        errdefer i2c.abort_transfer();

        // Wait for SB (Start Bit) flag
        try i2c.wait_flag_star1("SB", deadline);

        // Send address with write bit
        i2c.send_address(addr, .write);

        // Wait for ADDR flag (errors like NACK are checked while waiting)
        try i2c.wait_flag_star1("ADDR", deadline);

        // Clear ADDR by reading SR2
        _ = regs.STAR2.read();

        // Send data bytes
        var iter = write_vec.iterator();
        while (iter.next_element()) |element| {
            // Wait for TXE (Transmit buffer Empty)
            try i2c.wait_flag_star1("TxE", deadline);

            // Write data to DATAR
            regs.DATAR.write_raw(element.value);
        }

        // Wait for BTF (Byte Transfer Finished) - ensures last byte is transmitted
        try i2c.wait_flag_star1("BTF", deadline);

        // Generate STOP condition
        i2c.generate_stop();

        // Wait for STOP and BUSY to clear.
        try i2c.wait_for_stop(deadline);
    }

    /// Attempts to read bytes from target device and blocks until complete, error, or timeout
    pub fn read_blocking(i2c: I2C, addr: Address, dst: []u8, timeout: ?mdf.time.Duration) Error!void {
        return i2c.readv_blocking(addr, &.{dst}, timeout);
    }

    /// Vectored read - reads into multiple buffers in sequence
    pub fn readv_blocking(i2c: I2C, addr: Address, chunks: []const []u8, timeout: ?mdf.time.Duration) Error!void {
        const regs = i2c.get_regs();
        const read_vec = microzig.utilities.SliceVector([]u8).init(chunks);

        if (read_vec.size() == 0) return Error.NoData;

        const deadline = mdf.time.Deadline.init_relative(hal.time.get_time_since_boot(), timeout);
        const total_bytes = read_vec.size();

        try i2c.begin_transfer(total_bytes > 1, deadline);
        errdefer i2c.abort_transfer();

        // Wait for SB (Start Bit) flag
        try i2c.wait_flag_star1("SB", deadline);

        // Send address with read bit
        i2c.send_address(addr, .read);

        // Wait for ADDR flag (errors like NACK are checked while waiting)
        try i2c.wait_flag_star1("ADDR", deadline);

        // Handle single byte read specially
        if (total_bytes == 1) {
            // Clear ADDR by reading SR2
            _ = regs.STAR2.read();

            // Generate STOP
            i2c.generate_stop();

            // Wait for RxNE
            try i2c.wait_flag_star1("RxNE", deadline);

            // Read data
            var iter = read_vec.iterator();
            if (iter.next_element_ptr()) |element| {
                element.value_ptr.* = regs.DATAR.read().DATAR;
            }
        } else {
            // Clear ADDR by reading SR2
            _ = regs.STAR2.read();

            // Read data bytes
            var iter = read_vec.iterator();
            var bytes_remaining = total_bytes;

            while (iter.next_element_ptr()) |element| {
                bytes_remaining -= 1;

                // For the last byte, disable ACK and generate STOP before reading
                if (bytes_remaining == 0) {
                    i2c.generate_stop();
                }

                // Wait for RxNE
                try i2c.wait_flag_star1("RxNE", deadline);

                // Read data
                element.value_ptr.* = regs.DATAR.read().DATAR;
            }
        }

        // Wait for STOP and BUSY to clear.
        try i2c.wait_for_stop(deadline);
    }

    /// Write then read with repeated start (or STOP/START if repeated start disabled)
    pub fn write_then_read_blocking(i2c: I2C, addr: Address, src: []const u8, dst: []u8, timeout: ?mdf.time.Duration) Error!void {
        // For CH32V, we'll do separate write and read operations
        // The repeated start would require more complex state machine
        try i2c.write_blocking(addr, src, timeout);
        try i2c.read_blocking(addr, dst, timeout);
    }

    /// Write then read with repeated start (or STOP/START if repeated start disabled)
    pub fn writev_then_readv_blocking(
        i2c: I2C,
        addr: Address,
        write_chunks: []const []const u8,
        read_chunks: []const []u8,
        timeout: ?mdf.time.Duration,
    ) Error!void {
        // For CH32V, we'll do separate write and read operations
        // The repeated start would require more complex state machine
        try i2c.writev_blocking(addr, write_chunks, timeout);
        try i2c.readv_blocking(addr, read_chunks, timeout);
    }

    /// Write using DMA (only available if DMA configured)
    pub fn write_dma(
        i2c: I2C,
        comptime config: Config,
        addr: Address,
        data: []const u8,
        timeout: ?mdf.time.Duration,
    ) Error!void {
        comptime if (config.dma == null)
            @compileError("write_dma() requires DMA configuration in I2C config");

        const dma_cfg = comptime config.dma.?;
        const regs = i2c.get_regs();
        const deadline = mdf.time.Deadline.init_relative(hal.time.get_time_since_boot(), timeout);

        if (data.len == 0) return Error.NoData;
        _ = try dma.checked_transfer_count(data.len);

        try i2c.begin_transfer(false, deadline);
        errdefer i2c.abort_transfer();

        // Wait for SB (Start Bit) flag
        try i2c.wait_flag_star1("SB", deadline);

        // Send address with write bit
        i2c.send_address(addr, .write);

        // Wait for ADDR flag
        try i2c.wait_flag_star1("ADDR", deadline);

        // Setup DMA transfer from memory to I2C DATAR
        const peripheral_target = dma.PeripheralTarget{
            .addr = @intFromPtr(&regs.DATAR),
        };

        try deadline.check(hal.time.get_time_since_boot());
        dma_cfg.tx_channel.setup_transfer(
            peripheral_target, // destination (I2C DATAR)
            data, // source (memory buffer)
            .{
                .priority = dma_cfg.priority,
                .circular_mode = false,
            },
        );

        defer dma_cfg.tx_channel.stop();

        // Clear ADDR by reading SR2 (starts I2C and DMA transfer)
        try deadline.check(hal.time.get_time_since_boot());
        _ = regs.STAR2.read();

        // CH32F/V20x_V30x_V31x RM §19.9: TX DMA completion can precede BTF.
        try i2c.wait_for_dma(dma_cfg.tx_channel, deadline);

        // Wait for BTF (Byte Transfer Finished) - ensures last byte transmitted
        try i2c.wait_flag_star1("BTF", deadline);

        // Generate STOP condition
        i2c.generate_stop();

        // Wait for STOP and BUSY to clear.
        try i2c.wait_for_stop(deadline);
    }

    pub fn read_dma(
        i2c: I2C,
        comptime config: Config,
        addr: Address,
        dst: []u8,
        timeout: ?mdf.time.Duration,
    ) Error!void {
        comptime if (config.dma == null)
            @compileError("read_dma() requires DMA configuration in I2C config");

        const dma_cfg = comptime config.dma.?;
        const regs = i2c.get_regs();
        const deadline = mdf.time.Deadline.init_relative(hal.time.get_time_since_boot(), timeout);

        if (dst.len == 0) return Error.NoData;
        _ = try dma.checked_transfer_count(dst.len);

        try i2c.begin_transfer(true, deadline);
        errdefer i2c.abort_transfer();

        // Wait for SB flag
        try i2c.wait_flag_star1("SB", deadline);

        // Send address with read bit
        i2c.send_address(addr, .read);

        // Wait for ADDR flag
        try i2c.wait_flag_star1("ADDR", deadline);

        // CRITICAL: LAST tells I2C peripheral to NACK the final byte when DMA counter reaches 1
        // (DMAEN is already set globally in apply() method)
        regs.CTLR2.modify(.{ .LAST = 1 });
        defer regs.CTLR2.modify(.{ .LAST = 0 });

        // Setup DMA transfer from I2C DATAR to memory
        const peripheral_target = dma.PeripheralTarget{
            .addr = @intFromPtr(&regs.DATAR),
        };

        try deadline.check(hal.time.get_time_since_boot());
        dma_cfg.rx_channel.setup_transfer(
            dst, // write: destination (memory buffer)
            peripheral_target, // read: source (I2C DATAR)
            .{
                .priority = dma_cfg.priority,
                .circular_mode = false,
            },
        );

        defer dma_cfg.rx_channel.stop();

        // Clear ADDR by reading SR2 (starts I2C and DMA transfer)
        try deadline.check(hal.time.get_time_since_boot());
        _ = regs.STAR2.read();

        // CH32F/V20x_V30x_V31x RM §19.9: RX DMA completion precedes STOP.
        try i2c.wait_for_dma(dma_cfg.rx_channel, deadline);

        // Disable ACK and generate STOP
        i2c.generate_stop();

        // Wait for STOP and BUSY to clear.
        try i2c.wait_for_stop(deadline);
    }

    /// Automatic write - uses DMA if configured and transfer is large enough
    ///
    /// Automatically selects between DMA and polling based on transfer size. DMA is used for
    /// transfers over configured threshold, polling for smaller transfers.
    ///
    /// NOTE: The 16-byte default threshold is a heuristic based on typical DMA setup overhead vs
    /// polling cost. It has not been benchmarked specifically for CH32V and may not be optimal for
    /// all use cases. For explicit control, use write_dma() or write_blocking() directly.
    pub fn write_auto(
        i2c: I2C,
        comptime config: Config,
        addr: Address,
        data: []const u8,
        timeout: ?mdf.time.Duration,
    ) Error!void {
        if (comptime config.dma) |dma_cfg| {
            if (data.len >= dma_cfg.threshold) {
                return i2c.write_dma(config, addr, data, timeout);
            }
        }
        return i2c.write_blocking(addr, data, timeout);
    }

    /// Automatic read - uses DMA if configured and transfer is large enough
    ///
    /// Automatically selects between DMA and polling based on transfer size. DMA is used for
    /// transfers over configured threshold, polling for smaller transfers.
    ///
    /// NOTE: The 16-byte default threshold is a heuristic based on typical DMA setup overhead vs
    /// polling cost. It has not been benchmarked specifically for CH32V and may not be optimal for
    /// all use cases. For explicit control, use read_dma() or read_blocking() directly.
    pub fn read_auto(
        i2c: I2C,
        comptime config: Config,
        addr: Address,
        dst: []u8,
        timeout: ?mdf.time.Duration,
    ) Error!void {
        if (comptime config.dma) |dma_cfg| {
            if (dst.len >= dma_cfg.threshold) {
                return i2c.read_dma(config, addr, dst, timeout);
            }
        }
        return i2c.read_blocking(addr, dst, timeout);
    }

    /// Automatic vectored write - uses DMA per-chunk based on threshold
    ///
    /// For each chunk in the write operation:
    /// - If chunk size >= DMA threshold: uses write_dma()
    /// - If chunk size < DMA threshold: uses write_blocking()
    ///
    /// This approach maximizes DMA utilization without requiring buffer allocation.
    /// When DMA is not configured, falls back to writev_blocking().
    pub fn writev_auto(
        i2c: I2C,
        comptime config: Config,
        addr: Address,
        chunks: []const []const u8,
        timeout: ?mdf.time.Duration,
    ) Error!void {
        if (comptime config.dma) |dma_cfg| {
            // Process each chunk individually, using DMA for chunks >= threshold
            for (chunks) |chunk| {
                if (chunk.len >= dma_cfg.threshold) {
                    try i2c.write_dma(config, addr, chunk, timeout);
                } else {
                    try i2c.write_blocking(addr, chunk, timeout);
                }
            }
            return;
        }
        return i2c.writev_blocking(addr, chunks, timeout);
    }

    /// Automatic vectored read - uses DMA per-chunk based on threshold
    ///
    /// For each chunk in the read operation:
    /// - If chunk size >= DMA threshold: uses read_dma()
    /// - If chunk size < DMA threshold: uses read_blocking()
    ///
    /// This approach maximizes DMA utilization without requiring buffer allocation.
    /// When DMA is not configured, falls back to readv_blocking().
    pub fn readv_auto(
        i2c: I2C,
        comptime config: Config,
        addr: Address,
        chunks: []const []u8,
        timeout: ?mdf.time.Duration,
    ) Error!void {
        if (comptime config.dma) |dma_cfg| {
            // Process each chunk individually, using DMA for chunks >= threshold
            for (chunks) |chunk| {
                if (chunk.len >= dma_cfg.threshold) {
                    try i2c.read_dma(config, addr, chunk, timeout);
                } else {
                    try i2c.read_blocking(addr, chunk, timeout);
                }
            }
            return;
        }
        return i2c.readv_blocking(addr, chunks, timeout);
    }

    /// Automatic write-then-read operation
    ///
    /// Combines writev_auto() and readv_auto() to enable DMA for both operations.
    /// Each operation independently selects DMA or polling based on chunk sizes.
    pub fn writev_then_readv_auto(
        i2c: I2C,
        comptime config: Config,
        addr: Address,
        write_chunks: []const []const u8,
        read_chunks: []const []u8,
        timeout: ?mdf.time.Duration,
    ) Error!void {
        try i2c.writev_auto(config, addr, write_chunks, timeout);
        try i2c.readv_auto(config, addr, read_chunks, timeout);
    }
};

// CH32F/V20x_V30x_V31x RM §19.12.1: START and STOP are self-clearing
// commands. Only write a one when the caller explicitly issues a command.
fn write_control(register: anytype, fields: anytype) void {
    var control = register.read();
    control.START = 0;
    control.STOP = 0;
    inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |field| {
        @field(control, field) = @field(fields, field);
    }
    register.write(control);
}

const TerminalError = error{ ArbitrationLost, BusError, NoAcknowledge, Overrun };

fn terminal_error(status: anytype) TerminalError!void {
    if (status.ARLO != 0) return error.ArbitrationLost;
    if (status.BERR != 0) return error.BusError;
    if (status.AF != 0) return error.NoAcknowledge;
    if (status.OVR != 0) return error.Overrun;
}

// RM §19.12.6: ones preserve RW0 flags, including those raised after
// the snapshot. Never write the snapshot itself back to the register.
fn clear_errors(register: anytype, status: anytype, clear_arbitration: bool) void {
    const Status = @TypeOf(status);
    const clear_arlo = clear_arbitration and status.ARLO != 0;
    if (status.AF == 0 and status.BERR == 0 and status.OVR == 0 and !clear_arlo) return;
    var value: Status = .{
        .ADDR = 1,
        .PECERR = 1,
        .AF = @intFromBool(status.AF == 0),
        .BERR = @intFromBool(status.BERR == 0),
        .OVR = @intFromBool(status.OVR == 0),
        .ARLO = @intFromBool(!clear_arlo),
    };
    if (@hasField(Status, "TIMEOUT")) value.TIMEOUT = 1;
    if (@hasField(Status, "SMBALERT")) value.SMBALERT = 1;
    register.write(value);
}

fn require_enabled(pe: u1) error{RecoveryRequired}!void {
    if (pe == 0) return error.RecoveryRequired;
}

// RM §19.12.7: arbitration loss clears MSL. BUSY covers all controllers
// and belongs in the wait before START, never in the local STOP recovery.
fn local_stop_pending(master: u1, stop: u1, arbitration_lost: u1) bool {
    return master != 0 or (stop != 0 and arbitration_lost == 0);
}

fn may_reset_after_abort(lost_arbitration: bool, bus_busy: bool) bool {
    return !lost_arbitration and !bus_busy;
}

fn recover_after_abort(bus: anytype, recovery_deadline: anytype, comptime now: anytype) void {
    bus.prepare_abort();
    const Clock = @import("time.zig");
    const Poll = struct {
        fn ready(context: @TypeOf(bus)) error{}!bool {
            return context.poll_abort();
        }
    };
    if (!bus.poll_abort()) {
        Clock.wait_until_ready(bus, Poll.ready, recovery_deadline, now, I2C.poll_limit) catch {
            // The deadline may have expired even though STOP has completed.
            if (!bus.poll_abort()) {
                bus.disable();
                return;
            }
        };
    }
    // RM §19.12.6: clearing PE clears pending RXNE, BTF and ADDR.
    // Leave PE alone when another controller owns the bus.
    if (bus.can_reset_after_abort()) {
        bus.disable();
        bus.enable();
    }
}

test "I2C abort waits for STOP, flushes receive state and requires reapply if stuck" {
    const Fake = struct {
        const Deadline = struct {
            limit: u8,

            pub fn check(deadline: @This(), current: u8) error{Timeout}!void {
                if (current >= deadline.limit) return error.Timeout;
            }
        };
        var tick: u8 = 0;

        enabled: u1 = 1,
        pending_rx: bool = true,
        stop_requested: bool = false,
        stop_at: u8,
        master: u1 = 1,
        externally_busy: bool = false,
        lost_arbitration: bool = false,
        disable_calls: u8 = 0,

        fn prepare_abort(bus: *@This()) void {
            if (bus.master == 1) bus.stop_requested = true;
        }

        fn poll_abort(bus: *@This()) bool {
            if (bus.stop_requested and tick >= bus.stop_at) {
                bus.master = 0;
                bus.stop_requested = false;
            }
            const lost = @intFromBool(bus.lost_arbitration);
            const pending = local_stop_pending(bus.master, @intFromBool(bus.stop_requested), lost);
            if (!pending) bus.stop_requested = false;
            return !pending;
        }

        fn can_reset_after_abort(bus: *@This()) bool {
            bus.pending_rx = false;
            return may_reset_after_abort(bus.lost_arbitration, bus.externally_busy);
        }

        fn disable(bus: *@This()) void {
            bus.enabled = 0;
            bus.disable_calls += 1;
            bus.pending_rx = false;
        }

        fn enable(bus: *@This()) void {
            bus.enabled = 1;
        }

        fn now() u8 {
            tick += 1;
            return tick;
        }
    };

    const testing = @import("std").testing;
    const expired_transfer: Fake.Deadline = .{ .limit = 1 };
    const recovery_deadline: Fake.Deadline = .{ .limit = 6 };
    Fake.tick = 2;
    try testing.expectError(error.Timeout, expired_transfer.check(Fake.tick));
    var bus: Fake = .{ .stop_at = 4 };
    recover_after_abort(&bus, recovery_deadline, Fake.now);
    try testing.expect(Fake.tick >= bus.stop_at and Fake.tick < recovery_deadline.limit);
    try testing.expect(!bus.pending_rx);
    try require_enabled(bus.enabled);

    Fake.tick = 2;
    bus = .{ .stop_at = 7 };
    recover_after_abort(&bus, recovery_deadline, Fake.now);
    try testing.expectEqual(6, Fake.tick);
    try testing.expect(!bus.pending_rx);
    try testing.expectError(error.RecoveryRequired, require_enabled(bus.enabled));

    // Another master owns the bus after arbitration loss. A busy bus with
    // neither MSL nor STOP set must not consume the recovery budget.
    Fake.tick = 6;
    bus = .{ .stop_at = 7, .master = 0, .externally_busy = true, .lost_arbitration = true };
    recover_after_abort(&bus, recovery_deadline, Fake.now);
    try testing.expectEqual(6, Fake.tick);
    try testing.expectEqual(0, bus.disable_calls);
    try testing.expect(!bus.pending_rx);
    try require_enabled(bus.enabled);

    bus.stop_requested = true;
    recover_after_abort(&bus, recovery_deadline, Fake.now);
    try testing.expect(!bus.stop_requested);
    try testing.expectEqual(0, bus.disable_calls);

    bus.externally_busy = false;
    recover_after_abort(&bus, recovery_deadline, Fake.now);
    try testing.expectEqual(0, bus.disable_calls);
}

test "I2C writes only explicit START or STOP commands" {
    const Control = struct { START: u1 = 0, STOP: u1 = 0, ACK: u1 = 0, PE: u1 = 1 };
    const Register = struct {
        value: Control,

        fn read(reg: *@This()) Control {
            return reg.value;
        }

        fn write(reg: *@This(), value: Control) void {
            reg.value = value;
        }
    };
    const testing = @import("std").testing;
    var control: Register = .{ .value = .{ .START = 1, .STOP = 1 } };
    write_control(&control, .{ .ACK = @as(u1, 1) });
    try testing.expectEqual(Control{ .ACK = 1 }, control.value);
    write_control(&control, .{ .START = 1 });
    try testing.expectEqual(Control{ .START = 1, .ACK = 1 }, control.value);
    write_control(&control, .{ .STOP = 1, .ACK = 0 });
    try testing.expectEqual(Control{ .STOP = 1 }, control.value);
}

test "I2C status clears observed flags without losing late arbitration loss" {
    const Status = struct {
        ADDR: u1 = 0,
        PECERR: u1 = 0,
        AF: u1 = 0,
        BERR: u1 = 0,
        OVR: u1 = 0,
        ARLO: u1 = 0,
        TIMEOUT: u1 = 0,
        SMBALERT: u1 = 0,
    };
    const Register = struct {
        latched: Status,
        writes: u8 = 0,

        fn write(reg: *@This(), value: Status) void {
            inline for (@typeInfo(Status).@"struct".field_names) |field| {
                @field(reg.latched, field) &= @field(value, field);
            }
            reg.writes += 1;
        }
    };
    const testing = @import("std").testing;
    const observed: Status = .{ .AF = 1, .BERR = 1 };
    var status: Register = .{ .latched = .{
        .AF = 1,
        .BERR = 1,
        .ARLO = 1,
        .ADDR = 1,
        .PECERR = 1,
        .TIMEOUT = 1,
        .SMBALERT = 1,
    } };
    clear_errors(&status, observed, false);
    try testing.expectEqual(1, status.writes);
    try testing.expectEqual(Status{ .ARLO = 1, .ADDR = 1, .PECERR = 1, .TIMEOUT = 1, .SMBALERT = 1 }, status.latched);
    try testing.expectError(error.ArbitrationLost, terminal_error(status.latched));
    clear_errors(&status, status.latched, true);
    try testing.expectEqual(0, status.latched.ARLO);
}
