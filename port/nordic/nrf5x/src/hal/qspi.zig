//! Blocking nRF52840 QSPI for SPI NOR flash.
const std = @import("std");
const microzig = @import("microzig");
const compatibility = @import("compatibility.zig");
const gpio = @import("gpio.zig");
const time = @import("time.zig");
const Absolute = microzig.drivers.time.Absolute;

const regs = switch (compatibility.chip) {
    .nrf52840 => microzig.chip.peripherals.QSPI,
    else => compatibility.unsupported_chip("QSPI"),
};

const Interface = @TypeOf(regs.IFCONFIG0.read());
pub const ReadOpcode = @FieldType(Interface, "READOC");
pub const WriteOpcode = @FieldType(Interface, "WRITEOC");

pub const Pins = struct {
    sck: gpio.Pin,
    csn: gpio.Pin,
    io0: gpio.Pin,
    io1: gpio.Pin,
    io2: gpio.Pin,
    io3: gpio.Pin,
};

pub const Config = struct {
    pins: Pins,
    capacity: u32,
    /// PS v1.11 §6.19.10. SCK is 32 MHz / (1 + sck_divider).
    sck_divider: u4,
    read_opcode: ReadOpcode = .FASTREAD,
    write_opcode: WriteOpcode = .PP,
    addressing: union(enum) {
        bits24,
        /// Optional EN4B instruction to send during ACTIVATE.
        bits32: ?u8,
    } = .bits24,
    /// Set to the flash's tRES1 in microseconds to send ABh before ACTIVATE.
    deep_power_down_release_us: ?u32 = null,
    /// Budget for a peripheral transaction, including up to two page programs.
    transaction_timeout_us: u32,
    /// Budget for the longest flash operation, including chip erase.
    flash_timeout_us: u32,
};

pub const Error = error{
    InvalidConfig,
    AlreadyEnabled,
    Inactive,
    OutOfBounds,
    InvalidLength,
    Unaligned,
    Timeout,
    Faulted,
};

pub const sector_size = 4096;
pub const block_size = 65536;
pub const max_transfer = 256;

pub const Erase = enum { sector, block, chip };

/// Owns the singleton QSPI peripheral. Call from one foreground context with
/// the HAL timebase running. Keep this handle stationary in static RAM from
/// initialization until successful deinit. If a peripheral transaction times
/// out, the handle and its EasyDMA buffer remain reserved until system reset.
pub const QSPI = struct {
    state: enum { idle, active, faulted } = .idle,
    config: Config = undefined,
    dma: [max_transfer]u8 align(4) = undefined,

    pub fn init(self: *QSPI, config: Config) Error!void {
        if (self.state == .faulted) return error.Faulted;
        if (regs.ENABLE.read().ENABLE == .Enabled) return error.AlreadyEnabled;
        if (config.capacity == 0 or config.capacity % sector_size != 0 or
            (config.addressing == .bits24 and config.capacity > 1 << 24) or
            config.transaction_timeout_us == 0 or config.flash_timeout_us == 0)
            return error.InvalidConfig;

        // PS §4.2.1. EasyDMA targets the data RAM alias.
        const dma_address = @intFromPtr(&self.dma);
        if (dma_address < 0x20000000 or dma_address > 0x20040000 - max_transfer)
            return error.InvalidConfig;

        const pin_names = .{ "sck", "csn", "io0", "io1", "io2", "io3" };
        const psel_names = .{ "SCK", "CSN", "IO0", "IO1", "IO2", "IO3" };
        var used: u64 = 0;
        inline for (pin_names) |name| {
            const pin = @field(config.pins, name);
            const index = @backingInt(pin);
            const mask = @as(u64, 1) << index;
            if (index >= 48 or used & mask != 0) return error.InvalidConfig;
            used |= mask;
        }

        // PS §6.19.1. Set GPIO drive and PSEL before acquiring the pins.
        config.pins.csn.put(1);
        config.pins.csn.set_direction(.out);
        inline for (pin_names, 0..) |name, i| {
            const pin = @field(config.pins, name);
            if (i != 1) pin.set_direction(.in);
            pin.set_pull(.disabled);
            pin.set_input_buffer(.disconnect);
            pin.set_sense(.disabled);
            pin.set_drive_strength(.HOH1);
        }

        if (config.deep_power_down_release_us) |release_us|
            release_deep_power_down(config.pins, release_us);

        inline for (pin_names, psel_names) |name, psel| {
            const pin = @field(config.pins, name);
            @field(regs.PSEL, psel).write(.{
                .PIN = pin.index(),
                .PORT = pin.port(),
                .CONNECT = .Connected,
            });
        }

        regs.IFCONFIG0.write(.{
            .READOC = config.read_opcode,
            .WRITEOC = config.write_opcode,
            .ADDRMODE = if (config.addressing == .bits24) .@"24BIT" else .@"32BIT",
        });
        regs.IFCONFIG1.write(.{ .SCKFREQ = config.sck_divider });
        regs.ADDRCONF.write(switch (config.addressing) {
            .bits24 => .{},
            .bits32 => |opcode| if (opcode) |value| .{ .OPCODE = value, .MODE = .Opcode } else .{},
        });
        self.config = config;
        self.state = .active;
        regs.ENABLE.write(.{ .ENABLE = .Enabled });
        clear_ready();
        regs.TASKS_ACTIVATE.write(.{ .TASKS_ACTIVATE = .Trigger });
        try self.wait_event();
    }

    /// Deactivate and release the peripheral after both errata workarounds.
    pub fn deinit(self: *QSPI) Error!void {
        try self.require_active();
        // Anomalies 208 and 122: trigger DEACTIVATE from the CPU and write
        // the workaround register before clearing ENABLE (nrfx nrf_qspi_disable).
        regs.TASKS_DEACTIVATE.write(.{ .TASKS_DEACTIVATE = .Trigger });
        microzig.chip.peripherals.QSPI_ERRATA.DEACTIVATE_WORKAROUND.write(.{ .APPLY = 1 });
        regs.ENABLE.write(.{ .ENABLE = .Disabled });
        self.state = .idle;
    }

    /// Exchange up to eight bytes after the opcode, in wire order.
    /// A zero-length slice sends the opcode alone. IO2 and IO3 are held high.
    pub fn custom_instruction(self: *QSPI, opcode: u8, data: []u8) Error!void {
        try self.require_active();
        if (data.len > 8) return error.InvalidLength;
        var bytes: [8]u8 = @splat(0);
        @memcpy(bytes[0..data.len], data);
        regs.CINSTRDAT0.write_raw(std.mem.readInt(u32, bytes[0..4], .little));
        regs.CINSTRDAT1.write_raw(std.mem.readInt(u32, bytes[4..8], .little));

        // PS §6.19.6. Writing CINSTRCONF starts the transaction.
        clear_ready();
        regs.CINSTRCONF.write(.{
            .OPCODE = opcode,
            .LENGTH = @fromBackingInt(@as(u4, @intCast(data.len + 1))),
            .LIO2 = 1,
            .LIO3 = 1,
        });
        try self.wait_event();
        std.mem.writeInt(u32, bytes[0..4], regs.CINSTRDAT0.raw, .little);
        std.mem.writeInt(u32, bytes[4..8], regs.CINSTRDAT1.raw, .little);
        @memcpy(data, bytes[0..data.len]);
    }

    pub fn read_jedec_id(self: *QSPI) Error![3]u8 {
        var id: [3]u8 = @splat(0);
        try self.custom_instruction(0x9f, &id);
        return id;
    }

    /// Read into any writable buffer. Offset and length must be word aligned.
    pub fn read(self: *QSPI, offset: u32, data: []u8) Error!void {
        try self.check_transfer(offset, data.len);
        try self.wait_flash_ready();
        regs.READ.SRC.write(.{ .SRC = offset });
        regs.READ.DST.write(.{ .DST = @intFromPtr(&self.dma) });
        regs.READ.CNT.write(.{ .CNT = @intCast(data.len) });
        clear_ready();
        regs.TASKS_READSTART.write(.{ .TASKS_READSTART = .Trigger });
        try self.wait_event();
        asm volatile ("dmb" ::: .{ .memory = true });
        @memcpy(data, self.dma[0..data.len]);
    }

    /// Program erased flash. The controller splits a transfer at page boundaries
    /// (PS §6.19.2). Read back data to detect flash protection or program failure.
    pub fn program(self: *QSPI, offset: u32, data: []const u8) Error!void {
        try self.check_transfer(offset, data.len);
        try self.wait_flash_ready();
        @memcpy(self.dma[0..data.len], data);
        regs.WRITE.DST.write(.{ .DST = offset });
        regs.WRITE.SRC.write(.{ .SRC = @intFromPtr(&self.dma) });
        regs.WRITE.CNT.write(.{ .CNT = @intCast(data.len) });
        clear_ready();
        asm volatile ("dmb" ::: .{ .memory = true });
        regs.TASKS_WRITESTART.write(.{ .TASKS_WRITESTART = .Trigger });
        try self.wait_event();
        try self.wait_flash_ready();
    }

    /// Erase a 4 KiB sector, a 64 KiB block, or the entire device (offset 0).
    pub fn erase(self: *QSPI, offset: u32, kind: Erase) Error!void {
        try self.require_active();
        const len = switch (kind) {
            .sector => sector_size,
            .block => block_size,
            .chip => self.config.capacity,
        };
        try self.check_range(offset, len);
        if (offset % len != 0) return error.Unaligned;

        try self.wait_flash_ready();
        regs.ERASE.PTR.write(.{ .PTR = offset });
        regs.ERASE.LEN.write(.{ .LEN = switch (kind) {
            .sector => .@"4KB",
            .block => .@"64KB",
            .chip => .All,
        } });
        clear_ready();
        regs.TASKS_ERASESTART.write(.{ .TASKS_ERASESTART = .Trigger });
        try self.wait_event();
        // PS §6.19.4. READY means the erase started, so poll flash WIP separately.
        try self.wait_flash_ready();
    }

    /// Poll standard SPI NOR RDSR (0x05), bit 0. Also useful after custom writes.
    pub fn wait_flash_ready(self: *QSPI) Error!void {
        try self.require_active();
        const deadline = deadline_after(self.config.flash_timeout_us);
        while (true) {
            var status = [_]u8{0};
            try self.custom_instruction(0x05, &status);
            if (status[0] & 1 == 0) return;
            if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
        }
    }

    fn require_active(self: *const QSPI) Error!void {
        return switch (self.state) {
            .idle => error.Inactive,
            .active => {},
            .faulted => error.Faulted,
        };
    }

    fn check_range(self: *const QSPI, offset: u32, len: usize) Error!void {
        if (offset > self.config.capacity or len > self.config.capacity - offset)
            return error.OutOfBounds;
    }

    fn check_transfer(self: *const QSPI, offset: u32, len: usize) Error!void {
        try self.require_active();
        if (len == 0 or len > max_transfer) return error.InvalidLength;
        if (offset % 4 != 0 or len % 4 != 0) return error.Unaligned;
        try self.check_range(offset, len);
    }

    fn wait_event(self: *QSPI) Error!void {
        const deadline = deadline_after(self.config.transaction_timeout_us);
        while (!deadline.is_reached_by(time.get_time_since_boot())) {
            if (regs.EVENTS_READY.read().EVENTS_READY == .Generated) return;
        }
        self.state = .faulted;
        return error.Timeout;
    }
};

fn release_deep_power_down(pins: Pins, release_us: u32) void {
    // PS v1.11 §§6.19.1, 6.19.7 and STATUS.READY. The controller requires
    // READY to request DPM exit, but ACTIVATE already communicates with flash.
    // Send the single-line ABh frame via GPIO while QSPI is disabled.
    pins.sck.put(0);
    pins.io0.put(1);
    pins.io2.put(1);
    pins.io3.put(1);
    pins.sck.set_direction(.out);
    pins.io0.set_direction(.out);
    pins.io2.set_direction(.out);
    pins.io3.set_direction(.out);

    var opcode: u8 = 0xab;
    pins.csn.put(0);
    for (0..8) |_| {
        pins.io0.put(@truncate(opcode >> 7));
        opcode <<= 1;
        wake_clock_delay();
        pins.sck.put(1);
        wake_clock_delay();
        pins.sck.put(0);
    }
    wake_clock_delay();
    pins.csn.put(1);
    // Allow for one tick of quantization in the 32.768 kHz HAL timebase.
    time.sleep_us(@as(u64, release_us) + 32);
    pins.sck.set_direction(.in);
    pins.io0.set_direction(.in);
    pins.io2.set_direction(.in);
    pins.io3.set_direction(.in);
}

inline fn wake_clock_delay() void {
    // Four cycles at 64 MHz (PS v1.11 §4.1.3.1) give 62.5 ns for each
    // half-cycle and for the setup and hold times (P25Q16H v2.1 §5.3).
    asm volatile ("nop\nnop\nnop\nnop" ::: .{ .memory = true });
}

fn clear_ready() void {
    regs.EVENTS_READY.write(.{ .EVENTS_READY = .NotGenerated });
    _ = regs.EVENTS_READY.read();
}

fn deadline_after(us: u32) Absolute {
    return microzig.drivers.time.make_timeout_us(time.get_time_since_boot(), us);
}
