const std = @import("std");
const microzig = @import("microzig");
const mdf = microzig.drivers;
const drivers = mdf.base;
const peripherals = microzig.chip.peripherals;
pub const I2C0 = peripherals.I2C0;

const gpio = @import("gpio.zig");
const time = @import("time.zig");
const compatibility = @import("compatibility.zig");

// XTAL_CLK is 40 MHz: C3 TRM v1.4 §28.4.1; C6 TRM v1.2 §29.4.1.
const SOURCE_CLK_FREQ: u32 = 40_000_000;
const FILTER_THRESHOLD: u4 = 7;

pub const ConfigError = error{
    InvalidClkConfig,
    PeripheralDisabled,
    Timeout,
};

pub const Address = drivers.I2C_Device.Address;
pub const AddressError = drivers.I2C_Device.Address.Error;
pub const Error = drivers.I2C_Device.Error || error{
    FifoExceeded,
    ArbitrationLost,
    ExecutionIncomplete,
    CommandNumberExceeded,
};

const logic = @import("i2c_logic.zig");
const calculate_timing = logic.calculate_timing;
const read_commands = logic.read_commands;
const Command = logic.Command;

const OperationType = enum(u1) {
    write = 0,
    read = 1,
};

pub const instance = struct {
    pub fn num(n: u1) I2C {
        if (n != 0) @compileError("Only I2C0 is present");
        return .{ .regs = I2C0 };
    }
};

const I2cRegs = microzig.chip.types.peripherals.I2C0;

const I2C_FIFO_SIZE: usize = 32;
// Chunk writes/reads by this size
const I2C_CHUNK_SIZE: usize = I2C_FIFO_SIZE - 1;

/// I2C Master peripheral driver
pub const I2C = struct {
    regs: *volatile I2cRegs,
    frequency: u32 = 100_000,
    sda_pin: ?gpio.Pin = null,
    scl_pin: ?gpio.Pin = null,

    inline fn get_regs(self: I2C) *volatile I2cRegs {
        return self.regs;
    }

    // Both chips have eight 32-bit command registers (C6 TRM v1.2 §29.4.9).
    // C6 spells the index in every field name; normalize the identical layout.
    const CommandRegister = microzig.mmio.Mmio(packed struct(u32) {
        COMMAND: u14 = 0,
        reserved: u17 = 0,
        COMMAND_DONE: u1 = 0,
    });

    fn command_regs(self: I2C) *volatile [8]CommandRegister {
        return switch (compatibility.chip) {
            .esp32_c3 => @ptrCast(&self.regs.COMD),
            .esp32_c6 => @ptrCast(&self.regs.COMD0),
        };
    }

    /// Connect pins first, then apply. Initialization recovers a connected bus.
    /// HAL initialization and the monotonic system timer must already be running.
    /// A stuck bus is logged; initialization still leaves the controller configured.
    pub fn apply(self: *I2C, frequency: u32) ConfigError!void {
        self.frequency = frequency;
        try self.init();
    }

    pub fn init(self: I2C) ConfigError!void {
        const regs = self.get_regs();

        // Enable I2C peripheral clock and take it out of reset
        microzig.hal.system.enable_clocks_and_release_reset(.{ .i2c_ext0 = true });

        // Reset entire peripheral (also resets fifo)
        self.reset();

        // Disable all I2C interrupts
        regs.INT_ENA.write_raw(0);

        // Clear all I2C interrupts
        self.clear_interrupts();

        // Configure controller
        regs.CTR.write_raw(0);
        regs.CTR.modify(.{
            .MS_MODE = 1, // Set I2C controller to master mode
            .ARBITRATION_EN = 1, // Detect another master winning arbitration
            .SDA_FORCE_OUT = 1, // Direct output; the GPIO pad supplies open drain (TRM 28.4.6)
            .SCL_FORCE_OUT = 1, // Direct output; the GPIO pad supplies open drain
            .TX_LSB_FIRST = 0, // MSB first for sending
            .RX_LSB_FIRST = 0, // MSB first for receiving
            .CLK_EN = @intFromBool(compatibility.chip == .esp32_c3), // Reserved on C6
        });

        // Configure filter
        self.set_filter(FILTER_THRESHOLD, FILTER_THRESHOLD);

        // Configure frequency
        // TODO: Take timeout as extra arg and handle saturation?
        try self.set_frequency(SOURCE_CLK_FREQ, self.frequency);

        // Propagate configuration changes
        self.update_config();

        if (self.sda_pin != null and self.scl_pin != null) {
            self.recover_bus() catch |err| switch (err) {
                error.Timeout => std.log.warn("I2C bus recovery timed out; controller restored", .{}),
                else => return err,
            };
        }
    }

    /// Prepare open-drain pads without pulling an idle bus low, then route I2C.
    /// Call before apply/init; if connecting afterwards, call recover_bus explicitly.
    /// Applies Pin.Config defaults: drive_strength = 5mA and input_filter_enable = false.
    /// Set custom drive strength and input filtering after connect_pins. These pad
    /// controls are described in ESP32-C3 TRM v1.4 sections 5.12 and 5.15.
    pub fn connect_pins(self: *I2C, pins: struct {
        sda: ?gpio.Pin = null,
        scl: ?gpio.Pin = null,
        /// Disable when external pull-ups provide the required rise time.
        pull_up: bool = true,
    }) void {
        for ([_]?gpio.Pin{ pins.sda, pins.scl }) |maybe_pin| {
            if (maybe_pin) |pin| {
                // The reset output latch is low. Release the line before
                // enabling output (TRM v1.4, sections 5.5 and 28.4.6).
                pin.put(1);
                pin.apply(.{
                    .output_enable = true,
                    .input_enable = true,
                    .open_drain = true,
                    .pull = if (pins.pull_up) .up else .disabled,
                });
            }
        }

        if (pins.sda) |sda_pin| {
            self.sda_pin = sda_pin;
            sda_pin.connect_peripheral_to_output(.{ .signal = .i2cext0_sda });
            sda_pin.connect_input_to_peripheral(.{ .signal = .i2cext0_sda });
        }

        if (pins.scl) |scl_pin| {
            self.scl_pin = scl_pin;
            scl_pin.connect_peripheral_to_output(.{ .signal = .i2cext0_scl });
            scl_pin.connect_input_to_peripheral(.{ .signal = .i2cext0_scl });
        }
    }

    /// Reset the I2C controller
    fn reset(self: I2C) void {
        // NOTE: This is done explicitly in apply after disabling all i2c interrupts
        // Clear all I2C interrupts
        // self.clear_interrupts();

        // Reset FIFO
        self.reset_fifo();

        // Reset command list
        self.reset_command_list();

        // Reset FSM
        self.get_regs().CTR.modify(.{ .FSM_RST = 1 });
    }

    /// Reset the FIFO buffers
    fn reset_fifo(self: I2C) void {
        self.get_regs().FIFO_CONF.modify(.{
            .TX_FIFO_RST = 1,
            .RX_FIFO_RST = 1,
            // Esp hal sets these here
            .NONFIFO_EN = 0,
            .FIFO_PRT_EN = 1,
            // Esp hal sets these, but why?
            .RXFIFO_WM_THRHD = 1,
            .TXFIFO_WM_THRHD = 31,
        });

        // Shouldn't be needed, it's clear on write
        self.get_regs().FIFO_CONF.modify(.{
            .TX_FIFO_RST = 0,
            .RX_FIFO_RST = 0,
        });

        self.get_regs().INT_CLR.write(.{
            .RXFIFO_WM_INT_CLR = 1,
            .TXFIFO_WM_INT_CLR = 1,
        });

        self.update_config();
    }

    /// Reset the command list
    fn reset_command_list(self: I2C) void {
        // Reset all command registers
        for (0..self.command_regs().len) |i|
            self.command_regs()[@intCast(i)].write_raw(0);
    }

    /// Set the filter threshold in clock cycles
    fn set_filter(self: I2C, sda_threshold: ?u4, scl_threshold: ?u4) void {
        self.get_regs().FILTER_CFG.write(.{
            .SDA_FILTER_THRES = if (sda_threshold) |t| t else 0,
            .SDA_FILTER_EN = if (sda_threshold) |_| @as(u1, 1) else @as(u1, 0),
            .SCL_FILTER_THRES = if (scl_threshold) |t| t else 0,
            .SCL_FILTER_EN = if (scl_threshold) |_| @as(u1, 1) else @as(u1, 0),
        });
    }

    fn timing_for_frequency(source_clk: u32, bus_freq: u32) ConfigError!logic.Timing {
        return calculate_timing(source_clk, apb_clk_freq(), bus_freq);
    }

    /// Reads the active APB clock frequency from the clock registers, so custom clock configs
    /// are honoured as well.
    fn apb_clk_freq() u32 {
        switch (compatibility.chip) {
            // C3 TRM v1.4 Table 6.2-2: APB follows divided XTAL or is 80 MHz with PLL.
            .esp32_c3 => {
                const system = peripherals.SYSTEM.SYSCLK_CONF.read();
                return if (system.SOC_CLK_SEL == 0)
                    SOURCE_CLK_FREQ / (@as(u32, system.PRE_DIV_CNT) + 1)
                else
                    80_000_000;
            },
            // C6 TRM v1.2 §8.2.4.1, Tables 8.2-1 and 8.2-2: HP_ROOT_CLK is XTAL (40 MHz),
            // PLL (divided to 160 MHz by hardware) or RC_FAST (17.5 MHz); AHB divides it by
            // AHB_HS_DIV_NUM + 1 on the PLL and by AHB_LS_DIV_NUM + 1 otherwise, and APB divides
            // AHB by APB_DIV_NUM + 1. While the automatic reduction of Register 8.64 is enabled
            // APB may drop to the APB_DECREASE_DIV_NUM divider, so the slower of the two is used.
            .esp32_c6 => {
                const PCR = peripherals.PCR;
                const ahb = PCR.AHB_FREQ_CONF.read();
                const apb = PCR.APB_FREQ_CONF.read();
                const root_clk: u32, const ahb_div: u32 = switch (PCR.SYSCLK_CONF.read().SOC_CLK_SEL) {
                    0 => .{ SOURCE_CLK_FREQ, ahb.AHB_LS_DIV_NUM },
                    1 => .{ 160_000_000, ahb.AHB_HS_DIV_NUM },
                    // 3 is reserved; take the slowest source.
                    else => .{ 17_500_000, ahb.AHB_LS_DIV_NUM },
                };
                const apb_div: u32 = @max(apb.APB_DIV_NUM, apb.APB_DECREASE_DIV_NUM);
                return root_clk / (ahb_div + 1) / (apb_div + 1);
            },
        }
    }

    /// Sets the frequency of the I2C interface
    fn set_frequency(self: I2C, source_clk: u32, bus_freq: u32) ConfigError!void {
        self.set_timing(try timing_for_frequency(source_clk, bus_freq));
    }

    fn set_timing(self: I2C, timing: logic.Timing) void {

        // Set clock divider
        switch (compatibility.chip) {
            .esp32_c3 => self.get_regs().CLK_CONF.modify(.{
                .SCLK_SEL = 0,
                .SCLK_DIV_NUM = timing.divider,
            }),
            // C6 TRM v1.2 §29.4.1 moves the functional clock to PCR.
            .esp32_c6 => peripherals.PCR.I2C_SCLK_CONF.modify(.{
                .I2C_SCLK_SEL = 0,
                .I2C_SCLK_DIV_NUM = timing.divider,
                .I2C_SCLK_DIV_A = 0,
                .I2C_SCLK_DIV_B = 0,
                .I2C_SCLK_EN = 1,
            }),
        }

        // Set SCL period
        self.get_regs().SCL_LOW_PERIOD.modify(.{ .SCL_LOW_PERIOD = timing.low });
        self.get_regs().SCL_HIGH_PERIOD.modify(.{ .SCL_HIGH_PERIOD = timing.high, .SCL_WAIT_HIGH_PERIOD = timing.wait_high });

        // Set SDA sample and hold times
        self.get_regs().SDA_HOLD.write(.{ .TIME = timing.sda_hold });
        self.get_regs().SDA_SAMPLE.write(.{ .TIME = timing.sda_sample });

        // Set setup times
        self.get_regs().SCL_RSTART_SETUP.write(.{ .TIME = timing.setup });
        self.get_regs().SCL_STOP_SETUP.write(.{ .TIME = timing.setup });

        // Set hold times
        self.get_regs().SCL_START_HOLD.write(.{ .TIME = timing.setup });
        self.get_regs().SCL_STOP_HOLD.write(.{ .TIME = timing.setup });

        // Set timeout
        self.get_regs().TO.write(.{
            .TIME_OUT_VALUE = 10,
            .TIME_OUT_EN = 1,
        });
    }

    /// Clear a single-controller bus after initialization or an aborted transfer.
    /// Requires both connected pins and an initialized, running HAL timer.
    /// Pulses are sent at 100 kHz, then the configured transfer rate is restored.
    /// Timeout means the bus could not be released. Controller configuration and
    /// output routing are restored on both success and failure.
    pub fn recover_bus(self: I2C) ConfigError!void {
        const sda = self.sda_pin orelse return error.PeripheralDisabled;
        const scl = self.scl_pin orelse return error.PeripheralDisabled;
        const original_timing = try timing_for_frequency(SOURCE_CLK_FREQ, self.frequency);
        const recovery_timing = try timing_for_frequency(SOURCE_CLK_FREQ, 100_000);
        const regs = self.get_regs();
        const saved_sda_output = sda.get_output_routing();
        const saved_scl_output = scl.get_output_routing();
        self.reset();
        self.set_timing(recovery_timing);
        defer {
            // Release GPIO outputs and reset the FSM before handing pads back.
            // This also aborts a pulse generator that failed to self-clear.
            sda.put(1);
            scl.put(1);
            regs.SCL_SP_CONF.write_raw(0);
            self.reset();
            self.set_timing(original_timing);
            self.clear_interrupts();
            self.update_config();
            scl.restore_output_routing(saved_scl_output);
            sda.restore_output_routing(saved_sda_output);
        }
        // Keep SDA released during hardware clocks, independently of FSM state.
        // GPIO matrix routing and open-drain latches: C3 TRM v1.4 5.5.2/5.5.3;
        // C6 TRM v1.2 7.5.2/7.5.3.
        sda.put(1);
        scl.put(1);
        sda.connect_peripheral_to_output(.{ .signal = .gpio });
        // C3 TRM v1.4 28.4.4, C6 TRM v1.2 29.4.4: hardware clocks the slave while
        // the master is idle.
        // UM10204 Rev. 7.0 3.1.16 specifies nine clocks to release stuck SDA.
        regs.SCL_SP_CONF.write(.{
            .SCL_RST_SLV_NUM = 9,
            .SCL_RST_SLV_EN = 1,
            .SCL_PD_EN = 0,
            .SDA_PD_EN = 0,
        });
        self.update_config();
        const deadline = mdf.time.Deadline.init_relative(time.get_time_since_boot(), .from_ms(20));
        while (regs.SCL_SP_CONF.read().SCL_RST_SLV_EN != 0) {
            if (deadline.is_reached_by(time.get_time_since_boot()))
                return error.Timeout;
        }
        // 28.4.4 requires CONF_UPGATE after the enable bit self-clears.
        self.update_config();

        // Controller capture: a standalone STOP command from idle produced no
        // bus activity or TRANS_COMPLETE. Temporarily use GPIO for a real STOP:
        // SDA rises only after SCL is physically high (UM10204 3.1.4).
        scl.connect_peripheral_to_output(.{ .signal = .gpio });
        for (logic.recovery_stop_steps) |step| {
            switch (step) {
                .scl_low => scl.put(0),
                .sda_low => sda.put(0),
                .scl_release => {
                    scl.put(1);
                    while (scl.read() == 0) {
                        if (deadline.is_reached_by(time.get_time_since_boot()))
                            return error.Timeout;
                    }
                },
                .sda_release => {
                    sda.put(1);
                    while (sda.read() == 0) {
                        if (deadline.is_reached_by(time.get_time_since_boot()))
                            return error.Timeout;
                    }
                },
            }
            // Six timestamp increments guarantee at least 5 us despite timer
            // truncation, exceeding Standard-mode STOP setup/bus-free minima
            // (UM10204 Rev. 7.0 Table 11: 4.0 us and 4.7 us).
            time.sleep_us(6);
        }
    }

    fn reset_fsm(self: I2C) !void {
        // Even though C2 and C3 have a FSM reset bit, esp-idf does not
        // define SOC_I2C_SUPPORT_HW_FSM_RST for them, so include them in the fallback impl.
        microzig.hal.system.peripheral_reset(.{ .i2c_ext0 = true });

        try self.init();
    }

    fn check_errors(self: I2C) !void {
        // Reset the peripheral in case of error
        errdefer self.reset_fsm() catch {};

        const interrupts = self.get_regs().INT_RAW.read();
        // Either FSM can time out into idle without a completion interrupt
        // (ESP32-C3 TRM v1.4, section 28.4.8), even with no caller deadline.
        if (interrupts.TIME_OUT_INT_RAW == 1 or
            interrupts.SCL_ST_TO_INT_RAW == 1 or
            interrupts.SCL_MAIN_ST_TO_INT_RAW == 1)
        {
            return Error.Timeout;
        } else if (interrupts.NACK_INT_RAW == 1) {
            return Error.NoAcknowledge;
        } else if (interrupts.ARBITRATION_LOST_INT_RAW == 1) {
            return Error.ArbitrationLost;
        } else if (interrupts.TRANS_COMPLETE_INT_RAW == 1 and self.get_regs().SR.read().RESP_REC == 0) {
            return Error.NoAcknowledge;
        }
    }

    /// Propagate configuration to the peripheral
    inline fn update_config(self: I2C) void {
        self.get_regs().CTR.modify(.{ .CONF_UPGATE = 1 });
    }

    /// Read data from FIFO
    inline fn read_fifo(self: I2C) u8 {
        return self.get_regs().DATA.read().FIFO_RDATA;
    }

    /// Write data to FIFO
    inline fn write_fifo(self: I2C, data: u8) void {
        self.get_regs().DATA.write(.{ .FIFO_RDATA = data });
    }

    /// Clear all interrupts
    inline fn clear_interrupts(self: I2C) void {
        self.get_regs().INT_CLR.write_raw(0x3ffff);
    }

    fn prepare_phase(self: I2C) Error!void {
        // END leaves SCL low. Either FSM can time out into idle between phases
        // (TRM v1.4 28.4.8), including before a repeated START. Check before
        // clearing completion flags, and preserve timeout flags so one arriving
        // between this read and the W1C write is still seen by check_errors.
        const raw = self.get_regs().INT_RAW.read();
        if (raw.SCL_ST_TO_INT_RAW != 0 or raw.SCL_MAIN_ST_TO_INT_RAW != 0 or raw.TIME_OUT_INT_RAW != 0)
            try self.check_errors();
        // TRM 28.8 INT_CLR: timeout flags are bits 8, 13 and 14.
        const timeout_flags: u32 = (1 << 8) | (1 << 13) | (1 << 14);
        self.get_regs().INT_CLR.write_raw(0x3ffff & ~timeout_flags);
    }

    inline fn start_transmission(self: I2C) void {
        self.get_regs().CTR.modify(.{ .TRANS_START = 1 });
    }

    inline fn add_cmd(self: I2C, cmd_start_idx: *usize, cmd: Command) !void {
        if (cmd_start_idx.* + 1 > self.command_regs().len)
            return Error.CommandNumberExceeded;

        self.command_regs()[cmd_start_idx.*].write(.{
            .COMMAND = cmd.to_value(),
            .COMMAND_DONE = 0,
        });
        cmd_start_idx.* += 1;
    }

    fn setup_read(
        self: I2C,
        addr: Address,
        buffer: []const u8,
        start: bool,
        will_continue: bool,
        cmd_start_idx: *usize,
    ) !void {
        if (buffer.len == 0)
            return Error.NoData;

        const max_len = if (will_continue) I2C_CHUNK_SIZE else I2C_CHUNK_SIZE + 1;
        if (buffer.len > max_len)
            return Error.FifoExceeded;

        if (start)
            try self.add_cmd(cmd_start_idx, .{ .write = .{
                .ack_exp = .ack,
                .ack_check_en = true,
                .length = 1,
            } });

        for (read_commands(@intCast(buffer.len), will_continue)) |command| {
            if (command) |cmd| try self.add_cmd(cmd_start_idx, cmd);
        }

        self.update_config();

        // Load address and R/W bit
        if (start)
            self.write_fifo(@as(u8, @backingInt(addr)) << 1 | @backingInt(OperationType.read));
    }

    fn setup_write(self: I2C, addr: Address, bytes: []const u8, start: bool, cmd_start_idx: *usize) !void {
        const max_len = if (start) I2C_CHUNK_SIZE else I2C_CHUNK_SIZE + 1;
        if (bytes.len > max_len)
            return Error.FifoExceeded;

        const write_len: u8 = @truncate(if (start) bytes.len + 1 else bytes.len);

        if (write_len > 0) {
            try self.add_cmd(cmd_start_idx, .{ .write = .{
                .ack_exp = .ack,
                .ack_check_en = true,
                .length = @bitCast(write_len),
            } });
        }

        // Load address and R/W bit
        if (start)
            self.write_fifo(@as(u8, @backingInt(addr)) << 1 | @backingInt(OperationType.write));

        // Load data bytes into FIFO
        for (bytes) |byte|
            self.write_fifo(byte);
    }

    fn read_all_from_fifo(self: I2C, buffer: []u8) !void {
        if (self.get_regs().SR.read().RXFIFO_CNT < buffer.len)
            return Error.ExecutionIncomplete;

        for (buffer) |*byte|
            byte.* = self.read_fifo();
    }

    fn wait_for_completion(self: I2C, deadline: mdf.time.Deadline) !void {
        // Monitor for completion or errors
        while (true) {
            const interrupts = self.get_regs().INT_RAW.read();

            // Check for errors
            try self.check_errors();

            // Check for completion
            if (interrupts.TRANS_COMPLETE_INT_RAW == 1 or interrupts.END_DETECT_INT_RAW == 1)
                break;

            // Check for timeout
            if (deadline.is_reached_by(time.get_time_since_boot())) {
                self.reset();
                return Error.Timeout;
            }
        }

        // Verify all commands were executed
        for (0..self.command_regs().len) |i| {
            const cmd = self.command_regs()[i].read();
            if (cmd.COMMAND != 0 and cmd.COMMAND_DONE == 0) {
                return Error.ExecutionIncomplete;
            }
        }
    }

    /// Read data from an I2C slave
    pub fn read_blocking(self: I2C, addr: Address, dst: []u8, timeout: ?mdf.time.Duration) !void {
        return self.readv_blocking(addr, &.{dst}, timeout);
    }

    pub fn readv_blocking(self: I2C, addr: Address, chunks: []const []u8, timeout: ?mdf.time.Duration) !void {
        const deadline = mdf.time.Deadline.init_relative(time.get_time_since_boot(), timeout);
        return self.readv_operation_blocking(addr, chunks, deadline);
    }

    fn readv_operation_blocking(self: I2C, addr: Address, chunks: []const []u8, deadline: mdf.time.Deadline) Error!void {
        const read_vec = microzig.utilities.SliceVector([]u8).init(chunks);

        var is_first_chunk = true;
        // Always saving room for the address byte. With a custom iterator we could make sure only the first chunk is 31 (room for address)
        const total_size = read_vec.size();
        var bytes_processed: usize = 0;

        var iter = read_vec.iterator();
        // TODO: Maybe we don't need 31 byte limit for reads
        while (iter.next_chunk(31)) |chunk| {
            const is_last_chunk = (bytes_processed + chunk.len == total_size);
            try self.read_operation_blocking(
                addr,
                chunk,
                is_first_chunk,
                is_last_chunk,
                !is_last_chunk,
                deadline,
            );
            is_first_chunk = false;
            bytes_processed += chunk.len;
        }
    }

    fn read_operation_blocking(
        self: I2C,
        addr: Address,
        buffer: []u8,
        start: bool,
        stop: bool,
        will_continue: bool,
        deadline: mdf.time.Deadline,
    ) !void {
        addr.check_reserved() catch return Error.TargetAddressReserved;

        try self.prepare_phase();

        // Short circuit for zero length reads as that would be an invalid operation.
        // Read lengths in the TRM are 1-255.
        if (buffer.len == 0 and !start and !stop)
            return;

        self.reset_fifo();
        self.reset_command_list();

        // See TRM sections 28.5.5.1 and 28.5.8.1 to understand the command structure
        var cmd_idx: usize = 0;
        if (start)
            try self.add_cmd(&cmd_idx, Command.start);

        try self.setup_read(addr, buffer, start, will_continue, &cmd_idx);

        try self.add_cmd(&cmd_idx, if (stop) Command.stop else Command.end);

        self.start_transmission();

        try self.wait_for_completion(deadline);

        // Read data from FIFO into buffer
        try self.read_all_from_fifo(buffer);
    }

    /// Write data to an I2C slave
    pub fn write_blocking(self: I2C, addr: Address, data: []const u8, timeout: ?mdf.time.Duration) !void {
        return self.writev_blocking(addr, &.{data}, timeout);
    }

    pub fn writev_blocking(self: I2C, addr: Address, chunks: []const []const u8, timeout: ?mdf.time.Duration) Error!void {
        const deadline = mdf.time.Deadline.init_relative(time.get_time_since_boot(), timeout);
        return self.writev_operation_blocking(addr, chunks, true, true, deadline);
    }

    /// Write then read in one transfer, with a repeated START and one deadline.
    pub fn write_then_read_blocking(self: I2C, addr: Address, src: []const u8, dst: []u8, timeout: ?mdf.time.Duration) Error!void {
        return self.writev_then_readv_blocking(addr, &.{src}, &.{dst}, timeout);
    }

    pub fn writev_then_readv_blocking(
        self: I2C,
        addr: Address,
        write_chunks: []const []const u8,
        read_chunks: []const []u8,
        timeout: ?mdf.time.Duration,
    ) Error!void {
        const deadline = mdf.time.Deadline.init_relative(time.get_time_since_boot(), timeout);
        const has_reads = microzig.utilities.SliceVector([]u8).init(read_chunks).size() != 0;
        // Validate before starting: reserved addresses cannot be read.
        if (has_reads) addr.check_reserved() catch return Error.TargetAddressReserved;

        // END holds SCL low between phases; the next RSTART resumes the same
        // transfer (ESP32-C3 TRM v1.4, sections 28.1 and 28.5).
        try self.writev_operation_blocking(addr, write_chunks, true, !has_reads, deadline);
        if (has_reads)
            try self.readv_operation_blocking(addr, read_chunks, deadline);
    }

    fn writev_operation_blocking(
        self: I2C,
        addr: Address,
        chunks: []const []const u8,
        start: bool,
        stop: bool,
        deadline: mdf.time.Deadline,
    ) Error!void {
        // TODO: Write a new utility that does similar but that will coalesce into a specified size
        const write_vec = microzig.utilities.SliceVector([]const u8).init(chunks);
        if (write_vec.size() == 0)
            return self.write_operation_blocking(addr, &.{}, start, stop, deadline);

        var iter = write_vec.iterator();

        var is_first_chunk = true;
        var buffer: [I2C_FIFO_SIZE]u8 = undefined;
        var buffer_level: usize = 0;
        const total_size = write_vec.size();
        var remaining = total_size;
        // Pack up 'vec' chunks into 'fifo' chunks of up to `max_chunk_size`, writing whenever we
        // fill up.
        while (remaining != 0) {
            const max_chunk_size = if (remaining <= I2C_CHUNK_SIZE)
                remaining
            else if (is_first_chunk)
                // Reserve space for start byte
                I2C_CHUNK_SIZE
            else
                // Fully use the FIFO
                I2C_CHUNK_SIZE + 1;

            const buffer_remaining = max_chunk_size - buffer_level;
            if (buffer_remaining == 0) {
                // Buffer is full, send it
                remaining -= buffer_level;
                const is_last_chunk = (remaining == 0);
                try self.write_operation_blocking(addr, buffer[0..buffer_level], start and is_first_chunk, stop and is_last_chunk, deadline);
                is_first_chunk = false;
                buffer_level = 0;
                continue;
            }

            // Try to get next chunk. We should never not get a chunk here since we know ahead of
            // time how much to request.
            const chunk = iter.next_chunk(buffer_remaining) orelse return;

            // Copy chunk to buffer
            @memcpy(buffer[buffer_level..][0..chunk.len], chunk);
            buffer_level += chunk.len;
        }
    }

    fn write_operation_blocking(
        self: I2C,
        addr: Address,
        bytes: []const u8,
        start: bool,
        stop: bool,
        deadline: mdf.time.Deadline,
    ) Error!void {
        addr.check_reserved() catch |err| switch (err) {
            AddressError.GeneralCall => {},
            else => return Error.TargetAddressReserved,
        };

        // Short circuit for zero length writes without start or end as that would be an
        // invalid operation. Write lengths in the TRM are 1-255.
        if (bytes.len == 0 and !start and !stop)
            return;

        try self.prepare_phase();

        self.reset_fifo();
        self.reset_command_list();

        // See TRM sections 28.5.1.1 and 28.5.4.1 to understand the command structure
        var cmd_idx: usize = 0;
        if (start)
            try self.add_cmd(&cmd_idx, Command.start);

        try self.setup_write(addr, bytes, start, &cmd_idx);

        try self.add_cmd(&cmd_idx, if (stop) Command.stop else Command.end);

        self.start_transmission();

        try self.wait_for_completion(deadline);
    }
};
