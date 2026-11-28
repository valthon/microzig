const std = @import("std");
const builtin = @import("builtin");

const hal = @import("../hal.zig");
const microzig = if (builtin.is_test) hal.serial_test else @import("microzig");
const mdf = microzig.drivers;
const drivers = mdf.base;
const peripherals = microzig.chip.peripherals;
const compatibility = @import("compatibility.zig");

const gpio = @import("gpio.zig");
const time = if (builtin.is_test) hal.serial_test else @import("time.zig");

const version: enum {
    nrf5283x,
    nrf52840,
} = switch (compatibility.chip) {
    .nrf52, .nrf52833 => .nrf5283x,
    .nrf52840 => .nrf52840,
    else => compatibility.unsupported_chip("DMA I2C"),
};

// "Two Wire Interface Master"
const I2C0 = peripherals.TWIM0;
const I2C1 = peripherals.TWIM1;

const I2cRegs = microzig.chip.types.peripherals.TWIM0;

const Config = struct {
    scl_pin: gpio.Pin,
    sda_pin: gpio.Pin,
    // TODO: Name these more nicely
    frequency: enum {
        @"100000",
        @"250000",
        @"400000",
    } = .@"100000",
};

pub const Address = drivers.I2C_Device.Address;
pub const AddressError = drivers.I2C_Device.Address.Error;
pub const Error = drivers.I2C_Device.Error || error{
    BusStuck,
    Overrun,
    Receive,
    TooMuchData,
    Transmit,
};

/// Create an I2C instance from a peripheral number (0 or 1).
pub fn num(n: u1) I2C {
    return @fromBackingInt(n);
}

/// After error.BusStuck, the previous transfer's buffers remain owned by
/// EasyDMA. Keep them alive and untouched until a subsequent transfer,
/// wait_for_dma, apply, or deinit on the same instance returns without
/// error.BusStuck.
pub const I2C = enum(u1) {
    _,

    fn get_regs(i2c: I2C) *volatile I2cRegs {
        return switch (@backingInt(i2c)) {
            0 => I2C0,
            1 => I2C1,
        };
    }

    inline fn disable(i2c: I2C) void {
        i2c.get_regs().ENABLE.write(.{
            .ENABLE = .Disabled,
        });
    }

    inline fn enable(i2c: I2C) void {
        i2c.get_regs().ENABLE.write(.{
            .ENABLE = .Enabled,
        });
    }

    pub fn apply(i2c: I2C, config: Config) !void {
        try hal.wait_for_shared_dma(@backingInt(i2c));
        i2c.disable();
        hal.clear_shared_dma_registers(@backingInt(i2c));
        defer i2c.enable();

        const regs = i2c.get_regs();

        // Pins must be setup as INPUT with SOD1 drive strength
        config.scl_pin.set_direction(.in);
        config.scl_pin.set_drive_strength(.SOD1);
        switch (version) {
            .nrf5283x => regs.PSEL.SCL.write(.{
                .PIN = config.scl_pin.index(),
                .CONNECT = .Connected,
            }),
            .nrf52840 => regs.PSEL.SCL.write(.{
                .PIN = config.scl_pin.index(),
                .PORT = config.scl_pin.port(),
                .CONNECT = .Connected,
            }),
        }

        config.sda_pin.set_direction(.in);
        config.sda_pin.set_drive_strength(.SOD1);
        switch (version) {
            .nrf5283x => regs.PSEL.SDA.write(.{
                .PIN = config.sda_pin.index(),
                .CONNECT = .Connected,
            }),
            .nrf52840 => regs.PSEL.SDA.write(.{
                .PIN = config.sda_pin.index(),
                .PORT = config.sda_pin.port(),
                .CONNECT = .Connected,
            }),
        }

        regs.FREQUENCY.write(.{
            .FREQUENCY = switch (config.frequency) {
                .@"100000" => .K100,
                .@"250000" => .K250,
                .@"400000" => .K400,
            },
        });

        i2c.disable_interrupts();
    }

    /// Resets the peripheral when possible. Use deinit to report a stuck bus
    /// to the caller.
    pub fn reset(i2c: I2C) void {
        i2c.deinit() catch |err| std.log.err("TWIM reset failed: {s}", .{@errorName(err)});
    }

    /// Disables I2C and resets its configuration after EasyDMA releases RAM.
    pub fn deinit(i2c: I2C) error{BusStuck}!void {
        try hal.wait_for_shared_dma(@backingInt(i2c));
        i2c.disable();
        hal.clear_shared_dma_registers(@backingInt(i2c));
        const regs = i2c.get_regs();
        regs.SHORTS.raw = 0x00000000;
        regs.INTENSET.raw = 0x00000000;
        regs.ERRORSRC.raw = 0xFFFFFFFF;
        regs.PSEL.SCL.raw = 0xFFFFFFFF;
        regs.PSEL.SDA.raw = 0xFFFFFFFF;
        regs.FREQUENCY.raw = 0x04000000;
        regs.ADDRESS.raw = 0x00000000;
    }

    /// Check if a TX byte has been sent by reading the TXDSENT event.
    fn tx_sent(i2c: I2C) bool {
        return i2c.get_regs().EVENTS_TXDSENT.read().EVENTS_TXDSENT == .Generated;
    }

    /// Check if RX data is ready by reading the RXDREADY event.
    fn rx_ready(i2c: I2C) bool {
        return i2c.get_regs().EVENTS_RXDREADY.read().EVENTS_RXDREADY == .Generated;
    }

    /// Configure the TX DMA buffer for transmission.
    /// Returns error if buffer is too large for the hardware's MAXCNT register.
    fn set_tx_buffer(i2c: I2C, buf: []const u8) !void {
        // TODO: There has got to be a nicer way to do this. MAXCNT is u16 on nRF52840, and u8 on
        // nRF52831
        const tx_cnt_type = @FieldType(@FieldType(@FieldType(I2cRegs, "TXD"), "MAXCNT").underlying_type, "MAXCNT");
        if (std.math.cast(tx_cnt_type, buf.len) == null)
            return Error.TooMuchData;

        const regs = i2c.get_regs();
        regs.TXD.PTR.write(.{ .PTR = @truncate(@intFromPtr(buf.ptr)) });
        regs.TXD.MAXCNT.write(.{ .MAXCNT = @truncate(buf.len) });
    }

    /// Configure the RX DMA buffer for reception.
    /// Returns error if buffer is too large for the hardware's MAXCNT register.
    fn set_rx_buffer(i2c: I2C, buf: []u8) !void {
        const regs = i2c.get_regs();
        // TODO: There has got to be a nicer way to do this. MAXCNT is u16 on nRF52840, and u8 on
        // nRF52831
        const rx_cnt_type = @FieldType(@FieldType(@FieldType(I2cRegs, "RXD"), "MAXCNT").underlying_type, "MAXCNT");
        if (std.math.cast(rx_cnt_type, buf.len) == null)
            return Error.TooMuchData;
        regs.RXD.PTR.write(.{ .PTR = @truncate(@intFromPtr(buf.ptr)) });
        regs.RXD.MAXCNT.write(.{ .MAXCNT = @truncate(buf.len) });
    }

    /// Set the target I2C device address for the next transaction.
    /// Temporarily disables the peripheral to update the address register.
    fn set_address(i2c: I2C, addr: Address) Error!void {
        const regs = i2c.get_regs();
        if (regs.ENABLE.read().ENABLE != .Enabled) return Error.UnknownAbort;
        i2c.disable();
        defer i2c.enable();
        regs.ADDRESS.write(.{
            .ADDRESS = @backingInt(addr),
        });
    }

    /// Clear all hardware shortcuts by resetting the SHORTS register.
    fn clear_shorts(i2c: I2C) void {
        const regs = i2c.get_regs();
        regs.SHORTS.raw = 0x00000000;
    }

    /// Clear pending I2C event flags (SUSPENDED, STOPPED, ERROR).
    fn clear_events(i2c: I2C) void {
        const regs = i2c.get_regs();
        regs.EVENTS_SUSPENDED.raw = 0;
        regs.EVENTS_STOPPED.raw = 0;
        regs.EVENTS_ERROR.raw = 0;
    }

    /// Clear all error flags in the ERRORSRC register.
    fn clear_errors(i2c: I2C) void {
        const regs = i2c.get_regs();
        regs.ERRORSRC.raw = 0xFFFFFFFF;
    }

    // NOTE: Probably not needed, we never set them
    /// Disable I2C interrupts for STOPPED, ERROR, and SUSPENDED events.
    fn disable_interrupts(i2c: I2C) void {
        const regs = i2c.get_regs();
        // NOTE: Ignore `.Enabled`, this is write to clear
        regs.INTENCLR.modify(.{
            .STOPPED = .Enabled,
            .ERROR = .Enabled,
            .SUSPENDED = .Enabled,
        });
    }

    /// Check for I2C transaction errors by reading the ERRORSRC register.
    /// Returns the raw error source value on success, or a specific Error.
    fn check_error(i2c: I2C) Error!u32 {
        const regs = i2c.get_regs();
        const abort_reason = regs.ERRORSRC.read();

        if (abort_reason.OVERRUN == .Received) {
            // Byte was received before we read the last one
            return Error.Overrun;
        } else if (abort_reason.ANACK == .Received) {
            // NACK received after address (device not present)
            return Error.DeviceNotPresent;
        } else if (abort_reason.DNACK == .Received) {
            // NACK received after sending data
            return Error.NoAcknowledge;
        }
        return @bitCast(abort_reason);
    }

    /// Verify that the expected number of bytes were received via DMA.
    /// Returns error if actual received count doesn't match expected length.
    fn check_rx(i2c: I2C, len: usize) Error!void {
        const regs = i2c.get_regs();
        const bytes_read = regs.RXD.AMOUNT.read().AMOUNT;
        if (bytes_read != len)
            return Error.Receive;
    }

    /// Verify that the expected number of bytes were transmitted via DMA.
    /// Returns error if actual transmitted count doesn't match expected length.
    fn check_tx(i2c: I2C, len: usize) Error!void {
        const regs = i2c.get_regs();
        const bytes_written = regs.TXD.AMOUNT.read().AMOUNT;
        if (bytes_written != len)
            return Error.Transmit;
    }

    fn current_transfer_has_dma(regs: *volatile I2cRegs) bool {
        // Within a transaction each START has a non-null pointer, including
        // for address-only writes. Completion clears the pointers.
        return regs.TXD.PTR.read().PTR != 0 or regs.RXD.PTR.read().PTR != 0;
    }

    fn release_dma(regs: *volatile I2cRegs) void {
        regs.TXD.PTR.write(.{ .PTR = 0 });
        regs.RXD.PTR.write(.{ .PTR = 0 });
    }

    /// Waits for an outstanding STOP before the caller reuses its DMA buffers.
    pub fn wait_for_dma(i2c: I2C) error{BusStuck}!void {
        return hal.wait_for_shared_dma(@backingInt(i2c));
    }

    /// Completes an already-requested TWIM STOP for the shared recovery guard.
    pub fn finish_dma_stop(i2c: I2C) error{BusStuck}!void {
        const regs = i2c.get_regs();
        const frequency: u32 = switch (regs.FREQUENCY.read().FREQUENCY) {
            .K250 => 250_000,
            .K400 => 400_000,
            else => 100_000,
        };
        // A TWI byte includes an ACK/NACK clock in addition to its eight bits.
        const cleanup = mdf.time.Deadline.init_relative(time.get_time_since_boot(), .from_us(hal.stop_budget_us(frequency, 9)));
        try hal.wait_for_stop(regs, cleanup, time.get_time_since_boot, false);
        release_dma(regs);
    }

    fn finish_if_stopped(regs: *volatile I2cRegs) bool {
        if (regs.EVENTS_STOPPED.read().EVENTS_STOPPED != .Generated) return false;
        release_dma(regs);
        regs.EVENTS_STOPPED.raw = 0;
        return true;
    }

    /// Returns true if recovery had to request a software STOP.
    fn stop_if_pending(i2c: I2C) error{BusStuck}!bool {
        const regs = i2c.get_regs();
        if (finish_if_stopped(regs)) return false;

        i2c.clear_shorts();
        // nRF52840 PS v1.2 §§6.31.1, 6.31.3, 6.31.5: RESUME before
        // STOP if suspended. Wait for STOPPED before touching DMA or ENABLE.
        regs.TASKS_RESUME.write(.{ .TASKS_RESUME = .Trigger });
        regs.TASKS_STOP.write(.{ .TASKS_STOP = .Trigger });
        try hal.finish_dma_stop(@backingInt(i2c), .twim);
        return true;
    }

    fn abort_transfer(i2c: I2C) error{BusStuck}!void {
        if (current_transfer_has_dma(i2c.get_regs())) _ = try i2c.stop_if_pending();
    }

    /// Wait for the current chunk. On error or timeout, stop the entire transfer.
    fn wait(i2c: I2C, deadline: mdf.time.Deadline) Error!void {
        const regs = i2c.get_regs();
        while (true) {
            const now = time.get_time_since_boot();
            if (finish_if_stopped(regs)) return;
            if (regs.EVENTS_ERROR.read().EVENTS_ERROR == .Generated) {
                // The caller reads ERRORSRC to report the bus error after STOPPED.
                return i2c.abort_transfer();
            }
            if (regs.EVENTS_SUSPENDED.read().EVENTS_SUSPENDED == .Generated) {
                regs.EVENTS_SUSPENDED.raw = 0;
                return;
            }
            if (deadline.is_reached_by(now)) {
                if (try i2c.stop_if_pending()) return Error.Timeout;
                return;
            }
        }
    }

    /// Attempts to write number of bytes provided to target device and blocks until one of the
    /// following occurs:
    /// - Bytes have been transmitted successfully
    /// - An error occurs and the transaction is aborted
    /// - The transaction times out (a null for timeout blocks indefinitely)
    ///
    pub fn write_blocking(i2c: I2C, addr: Address, data: []const u8, timeout: ?mdf.time.Duration) Error!void {
        return i2c.writev_blocking(addr, &.{data}, timeout);
    }

    /// Attempts to write number of bytes provided to target device and blocks until one of the following occurs:
    /// - Bytes have been transmitted successfully
    /// - An error occurs and the transaction is aborted
    /// - The transaction times out (a null for timeout blocks indefinitely)
    ///
    /// NOTE: This function is a vectored version of `write_blocking` and takes an array of arrays.
    ///       This pattern allows one to create better zero-copy send routines as message prefixes and
    ///       suffixes won't need to be concatenated/inserted to the original buffer, but can be managed
    ///       in a separate memory.
    ///
    pub fn writev_blocking(i2c: I2C, addr: Address, chunks: []const []const u8, timeout: ?mdf.time.Duration) Error!void {
        try hal.wait_for_shared_dma(@backingInt(i2c));
        addr.check_reserved() catch |err| switch (err) {
            AddressError.GeneralCall => {},
            else => return Error.IllegalAddress,
        };

        if (chunks.len == 0)
            return Error.NoData;

        const regs = i2c.get_regs();
        const deadline = mdf.time.Deadline.init_relative(time.get_time_since_boot(), timeout);

        try i2c.set_address(addr);

        i2c.clear_shorts();
        i2c.clear_events();
        i2c.clear_errors();
        i2c.disable_interrupts();

        for (0.., chunks) |i, chunk| {
            const stop = i == chunks.len - 1;
            i2c.set_tx_buffer(chunk) catch |err| {
                try i2c.abort_transfer();
                return err;
            };

            // Set it up to automatically stop after sending the last byte of this DMA transaction,
            // but only if we are on the last chunk. Otherwise, instead we want to suspend so that
            // we can resume on the next chunk.
            if (stop)
                regs.SHORTS.modify(.{
                    .LASTTX_STOP = .Enabled,
                    .LASTTX_SUSPEND = .Disabled,
                })
            else
                regs.SHORTS.modify(.{
                    .LASTTX_SUSPEND = .Enabled,
                    .LASTTX_STOP = .Disabled,
                });

            // We always have to START, but if we are not on the first chunk, we also have to resume
            regs.TASKS_STARTTX.write(.{ .TASKS_STARTTX = .Trigger });
            if (i != 0)
                regs.TASKS_RESUME.write(.{ .TASKS_RESUME = .Trigger });

            // If current chunk has 0 len, we can still START a transaction, but because the LASTTX
            // event will never hit, the shortcut above won't trigger. Therefore, we need to
            // explicitly stop or suspend the task in this case.
            if (chunk.len == 0)
                if (stop)
                    regs.TASKS_STOP.write(.{ .TASKS_STOP = .Trigger })
                else
                    regs.TASKS_SUSPEND.write(.{ .TASKS_SUSPEND = .Trigger });

            try i2c.wait(deadline);
            _ = i2c.check_error() catch |err| {
                try i2c.abort_transfer();
                return err;
            };
            i2c.check_tx(chunk.len) catch |err| {
                try i2c.abort_transfer();
                return err;
            };
        }
    }

    /// Attempts to read number of bytes in provided slice from target device and blocks until one
    /// of the following occurs:
    /// - Bytes have been read successfully
    /// - An error occurs and the transaction is aborted
    /// - The transaction times out (a null for timeout blocks indefinitely)
    ///
    /// NOTE: readv_blocking is unsupported because of a bug in the chip, where subsequent reads
    /// cannot be performed without sending an extra START event.
    pub fn read_blocking(i2c: I2C, addr: Address, dst: []u8, timeout: ?mdf.time.Duration) Error!void {
        try hal.wait_for_shared_dma(@backingInt(i2c));
        addr.check_reserved() catch return Error.IllegalAddress;

        // TODO: We can handle this if for some reason we want to send a start and immediate stop?
        if (dst.len == 0)
            return Error.NoData;

        const regs = i2c.get_regs();
        const deadline = mdf.time.Deadline.init_relative(time.get_time_since_boot(), timeout);

        try i2c.set_address(addr);

        i2c.clear_shorts();
        i2c.clear_events();
        i2c.clear_errors();

        i2c.disable_interrupts();

        try i2c.set_rx_buffer(dst);

        // TODO: We only set the stop one if this is the last transaction... we could handle writev
        // this way probably. If it's not the last chunk, then just suspend
        // Set it up to automatically stop after receiving the last expected byte
        regs.SHORTS.modify(.{ .LASTRX_STOP = .Enabled });

        regs.TASKS_STARTRX.write(.{ .TASKS_STARTRX = .Trigger });

        try i2c.wait(deadline);
        _ = try i2c.check_error();
        try i2c.check_rx(dst.len);
    }

    /// Attempts to write number of bytes provided to target device and then immediately read bytes
    /// following a repeated start command (or Start + Stop if repeated start is disabled). Blocks
    /// until one of the following occurs:
    /// - Bytes have been transmitted and read successfully
    /// - An error occurs and the transaction is aborted
    /// - The transaction times out (a null for timeout blocks indefinitely)
    ///
    /// This is useful for the common scenario of writing an address to a target device, and then
    /// immediately reading bytes from that address
    pub fn write_then_read_blocking(i2c: I2C, addr: Address, data: []const u8, dst: []u8, timeout: ?mdf.time.Duration) Error!void {
        try hal.wait_for_shared_dma(@backingInt(i2c));
        addr.check_reserved() catch return Error.IllegalAddress;

        // TODO: We can handle this actually
        if (data.len == 0)
            return Error.NoData;
        if (dst.len == 0)
            return Error.NoData;

        const regs = i2c.get_regs();
        const deadline = mdf.time.Deadline.init_relative(time.get_time_since_boot(), timeout);

        try i2c.set_address(addr);

        i2c.clear_shorts();
        i2c.clear_events();
        i2c.clear_errors();

        i2c.disable_interrupts();

        try i2c.set_tx_buffer(data);
        i2c.set_rx_buffer(dst) catch |err| {
            // STARTTX has yet to be triggered. Release the prepared TX pointer.
            release_dma(regs);
            return err;
        };

        // Set it up to automatically start a read after it's finished writing, and stop after it's
        // finished reading.
        regs.SHORTS.modify(.{
            .LASTTX_STARTRX = .Enabled,
            .LASTRX_STOP = .Enabled,
        });

        // Trigger transaction
        regs.TASKS_STARTTX.write(.{ .TASKS_STARTTX = .Trigger });

        try i2c.wait(deadline);
        _ = try i2c.check_error();
        try i2c.check_rx(dst.len);
        try i2c.check_tx(data.len);
    }
};
