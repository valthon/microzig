const std = @import("std");
const microzig = @import("microzig");
const enums = @import("enums.zig");
const PollDeadline = @import("systick.zig").PollDeadline;

const I2C_Type = enums.I2C_Type;
const I2C_Peripherals = microzig.chip.types.peripherals.i2c_v2.I2C;
const hal = microzig.hal;
const drivers = microzig.drivers.base;

pub const Address = drivers.I2C_Device.Address;
const InterfaceError = drivers.I2C_Device.InterfaceError;
const I2CError = drivers.I2C_Device.Error;

pub const ConfigError = error{
    PCLKUnderflow,
    PCLKOverflow,
};

// 100Khz for now
const TimingSpec_Standard = .{
    .t_low = 4.7,
    .t_high = 4.0,
    .t_rise = 1.0,
    .t_fall = 0.3,
    .t_su_dat = 0.25,
    .t_max_vd_ack = 3.45,
    .t_min_vd_ack = 0.01,
    .t_max_af = 0.26,
    .t_min_af = 0.05,
};

const TIMINGR = blk: {
    const info = @typeInfo(I2C_Peripherals).@"struct";
    break :blk for (info.field_names, info.field_types) |field_name, field_type| {
        if (std.mem.eql(u8, "TIMINGR", field_name)) {
            break :blk field_type;
        }
    } else @compileError("No TIMINGR register");
};

const I2C = struct {
    regs: *volatile I2C_Peripherals,
    timingr: TIMINGR.underlying_type,

    fn compute_presc(comptime instance: I2C_Type) ConfigError!struct { f32, u4 } {
        // Let first see if we need to prescale.
        // 100Khz = 10us period ~ 5us for SCLL/SCLH
        const device_clock = @as(f32, @floatFromInt(hal.rcc.get_clock(enums.to_peripheral(instance))));
        const t_sckl = 1_000_000.0 / device_clock;

        if (t_sckl > 0.1) {
            return .{ t_sckl, 0 };
        }

        // t_presc = 0.1us accomonddate for most timing register
        const ideal_presc = @as(u32, @intFromFloat(@round(0.1 / t_sckl))) - 1;

        if (ideal_presc > 15) {
            std.log.info("i2cclk frequency is too high in other to set prescal", .{});
            return ConfigError.PCLKOverflow;
        }
        const presc = @as(u4, @intCast(ideal_presc));
        const t_presc = t_sckl * @as(f32, @floatFromInt(presc + 1));

        return .{ t_presc, presc };
    }

    fn compute_hold_time(t_presc: f32) ConfigError!u4 {
        const real_sdadel = (TimingSpec_Standard.t_fall + TimingSpec_Standard.t_min_vd_ack - TimingSpec_Standard.t_max_af) / t_presc;
        if (real_sdadel > 15.0) {
            std.log.info("Hold time is too short consider lowering the i2cclk frequency", .{});
            return ConfigError.PCLKOverflow;
        }
        const sdadel = @as(u4, @intFromFloat(@round(real_sdadel)));
        // TODO check fi max value is less the 1 and return an error
        return if (sdadel == 0) 1 else sdadel;
    }

    fn compute_setup_time(t_presc: f32) ConfigError!u4 {
        const real_scdel = (TimingSpec_Standard.t_rise + TimingSpec_Standard.t_su_dat) / t_presc;
        if (real_scdel > 15.0) {
            std.log.info("Setup time is too short consider lowering the i2cclk frequency", .{});
            return ConfigError.PCLKOverflow;
        }
        const scdel = @as(u4, @intFromFloat(@round(real_scdel)));
        // TODO check fi max value is less the 1 and return an error
        return if (scdel == 0) 1 else scdel;
    }

    fn compute_low_time(t_presc: f32) ConfigError!u8 {
        const real_scll = ((TimingSpec_Standard.t_low - TimingSpec_Standard.t_min_af - 2 * t_presc) / t_presc) - 1;
        if (real_scll > 256.0) {
            std.log.info("Clock low time is too short consider lowering the i2cclk frequency", .{});
            return ConfigError.PCLKOverflow;
        }
        return @as(u8, @intFromFloat(@round(real_scll)));
    }

    fn compute_high_time(t_presc: f32) ConfigError!u8 {
        const real_sclh = ((TimingSpec_Standard.t_high - TimingSpec_Standard.t_min_af - 2 * t_presc) / t_presc) - 1;
        if (real_sclh > 256.0) {
            std.log.info("Clock high time is too short consider lowering the i2cclk frequency", .{});
            return ConfigError.PCLKOverflow;
        }
        return @as(u8, @intFromFloat(@round(real_sclh)));
    }

    fn prepare(i2c: *const I2C) I2CError!void {
        const control = i2c.regs.CR2.read();
        if (i2c.regs.CR1.read().PE == 0 or control.START == 1 or control.STOP == 1)
            return error.UnknownAbort;
        clear_transfer_flags(i2c.regs);
    }

    // TODO this should configure
    // Interrupt,
    // Frequency
    // Others...
    pub fn apply(i2c: *const I2C) void {
        const regs = i2c.regs;

        regs.CR1.modify(.{ .PE = 0 });

        regs.TIMINGR.modify(i2c.timingr);

        regs.CR1.modify(.{ .PE = 1 });
    }

    pub fn read_blocking(i2c: *const I2C, addr: Address, chunks: []u8) I2CError!void {
        const count = std.math.cast(u8, chunks.len) orelse return error.BufferOverrun;
        try i2c.prepare();
        const regs = i2c.regs;
        var deadline = PollDeadline.init(now_us(), transfer_timeout_us);
        errdefer retire_failed_transfer(regs, now_us);

        regs.CR2.modify(.{
            .NBYTES = count,
            .SADD = @as(u10, @backingInt(addr)) << 1,
            .AUTOEND = .Automatic,
            .DIR = .Read,
            .START = 1,
        });

        for (chunks, 1..) |*byte, index| {
            try wait_for_status(regs, microzig.config.chip_name, if (index == chunks.len) .last_rx else .rx, &deadline, now_us);
            byte.* = regs.RXDR.read().RXDATA;
        }
        try wait_for_status(regs, microzig.config.chip_name, .stop, &deadline, now_us);
    }

    fn write_blocking_intern(i2c: *const I2C, addr: Address, comptime restart: bool, chunks: []const u8) I2CError!void {
        const count = std.math.cast(u8, chunks.len) orelse return error.BufferOverrun;
        try i2c.prepare();
        const regs = i2c.regs;
        var deadline = PollDeadline.init(now_us(), transfer_timeout_us);
        errdefer retire_failed_transfer(regs, now_us);

        regs.CR2.modify(.{
            .NBYTES = count,
            .SADD = @as(u10, @backingInt(addr)) << 1,
            .AUTOEND = if (restart) .Software else .Automatic,
            .DIR = .Write,
            .START = 1,
        });

        for (chunks) |byte| {
            try wait_for_status(regs, microzig.config.chip_name, .tx, &deadline, now_us);
            regs.TXDR.modify(.{ .TXDATA = byte });
        }

        try wait_for_status(regs, microzig.config.chip_name, if (restart) .restart else .stop, &deadline, now_us);
    }

    pub fn write_blocking_restart(i2c: *const I2C, address: Address, data: []const u8) I2CError!void {
        return i2c.write_blocking_intern(address, true, data);
    }

    pub fn write_blocking(i2c: *const I2C, address: Address, data: []const u8) I2CError!void {
        return i2c.write_blocking_intern(address, false, data);
    }

    /// Initialize a given I2C peripheral and compute the
    /// TIMINGR register base on the clock frequency.
    /// Be aware that this require FPU.
    ///
    /// Note: This can be run at comptime if rcc clock is comptime known
    /// and remove the need of FPU.
    pub fn init(comptime instance: I2C_Type) ConfigError!I2C {
        hal.rcc.enable_clock(enums.to_peripheral(instance));
        const t_presc, const presc = try compute_presc(instance);
        const scdel = try compute_setup_time(t_presc);
        const sdadel = try compute_hold_time(t_presc);
        const scll = try compute_low_time(t_presc);
        const sclh = try compute_high_time(t_presc);

        const timingr: TIMINGR.underlying_type = .{
            .PRESC = presc,
            .SCLDEL = scdel,
            .SDADEL = sdadel,
            .SCLL = scll,
            .SCLH = sclh,
        };

        return .{ .regs = enums.get_regs(I2C_Peripherals, instance), .timingr = timingr };
    }
};

pub const I2C_Device = struct {
    i2c: I2C,
    const device_vtable = drivers.I2C_Device.VTable{
        .writev_fn = I2C_Device.writev_fn,
        .readv_fn = I2C_Device.readv_fn,
        .writev_then_readv_fn = I2C_Device.writev_then_readv_fn,
    };
    fn writev_fn(dev: *anyopaque, addr: Address, datagrams: []const []const u8) InterfaceError!void {
        const i2c: *I2C_Device = @ptrCast(@alignCast(dev));
        addr.check_reserved() catch {
            return InterfaceError.TargetAddressReserved;
        };
        for (datagrams) |chunk| {
            try i2c.i2c.write_blocking(addr, chunk);
        }
    }

    fn readv_fn(dev: *anyopaque, addr: Address, datagrams: []const []u8) InterfaceError!usize {
        const i2c: *I2C_Device = @ptrCast(@alignCast(dev));
        addr.check_reserved() catch {
            return InterfaceError.TargetAddressReserved;
        };
        var read: usize = 0;
        for (datagrams) |chunk| {
            try i2c.i2c.read_blocking(addr, chunk);
            read += chunk.len;
        }
        return read;
    }

    fn writev_then_readv_fn(
        dev: *anyopaque,
        addr: Address,
        write_chunks: []const []const u8,
        read_chunks: []const []u8,
    ) InterfaceError!void {
        const i2c: *I2C_Device = @ptrCast(@alignCast(dev));
        addr.check_reserved() catch {
            return InterfaceError.TargetAddressReserved;
        };
        if (write_chunks.len != read_chunks.len) return error.Unsupported;
        // Validate every pair before starting a write that leaves the bus at TC.
        for (write_chunks, read_chunks) |tx, rx| {
            if (tx.len > std.math.maxInt(u8) or rx.len > std.math.maxInt(u8)) return error.BufferOverrun;
        }
        for (write_chunks, read_chunks) |tx, rx| {
            try i2c.i2c.write_blocking_restart(addr, tx);
            try i2c.i2c.read_blocking(addr, rx);
        }
    }

    pub fn apply(i2c: *const I2C_Device) void {
        i2c.i2c.apply();
    }

    pub fn init(comptime instance: I2C_Type) ConfigError!I2C_Device {
        return .{ .i2c = try I2C.init(instance) };
    }

    pub fn i2c_device(i2c: *I2C_Device) drivers.I2C_Device {
        return .{ .ptr = i2c, .vtable = &device_vtable };
    }
};

// At 100 kHz a full 255-byte chunk takes about 23 ms before clock stretching.
const transfer_timeout_us = 100_000;
const recovery_timeout_us = 5_000;

fn now_us() u64 {
    return if (hal.systick.is_initialized()) hal.systick.get_time_since_boot() else 0;
}

const Phase = enum { rx, last_rx, tx, restart, stop };

fn spurious_controller_berr(comptime chip_name: []const u8) bool {
    // STM32F303: ES0246 §2.5.7 (x6/x8), ES0204 §2.5.7 (xB/xC),
    // and ES0261 §2.6.6 (xD/xE). STM32L471/475/476/486: ES0250 §2.20.4.
    // BERR can assert spuriously and does not stop a controller transfer.
    return std.mem.startsWith(u8, chip_name, "STM32F303") or
        std.mem.startsWith(u8, chip_name, "STM32L471") or
        std.mem.startsWith(u8, chip_name, "STM32L475") or
        std.mem.startsWith(u8, chip_name, "STM32L476") or
        std.mem.startsWith(u8, chip_name, "STM32L486");
}

// RM0316 §28.4.9 and RM0351 §39.4.9, I2C master mode. NACK can suppress
// TXIS/TC or coincide with STOPF. AUTOEND can set STOPF before software
// reads the final RXDR, so only the final RX byte may accept both flags.
fn wait_for_status(regs: anytype, comptime chip_name: []const u8, phase: Phase, deadline: *PollDeadline, comptime clock: fn () u64) I2CError!void {
    while (true) {
        const status = regs.ISR.read();
        if (status.NACKF == 1) return error.NoAcknowledge;
        if (status.TIMEOUT == 1) return error.Timeout;
        if (status.ARLO == 1) return error.UnknownAbort;
        if (status.BERR == 1) {
            if (comptime !spurious_controller_berr(chip_name)) return error.UnknownAbort;
            const Clear = @FieldType(I2C_Peripherals, "ICR").underlying_type;
            regs.ICR.write(std.mem.zeroInit(Clear, .{ .BERRCF = 1 }));
        }
        if (status.STOPF == 1 and phase != .stop and (phase != .last_rx or status.RXNE == 0))
            return error.UnknownAbort;
        const ready = switch (phase) {
            .rx, .last_rx => status.RXNE,
            .tx => status.TXIS,
            .restart => status.TC,
            .stop => status.STOPF,
        };
        if (ready == 1) return;
        if (deadline.expired(clock())) return error.Timeout;
    }
}

fn clear_transfer_flags(regs: anytype) void {
    // ICR is write-one-to-clear.
    const Clear = @TypeOf(regs.ICR).underlying_type;
    regs.ICR.write(std.mem.zeroInit(Clear, .{
        .STOPCF = 1,
        .NACKCF = 1,
        .BERRCF = 1,
        .ARLOCF = 1,
        .TIMOUTCF = 1,
    }));
}

fn retire_failed_transfer(regs: anytype, comptime clock: fn () u64) void {
    wait_for_failed_stop(regs, clock);

    // RM0316 §28.4.6 and RM0351 §39.4.6, I2C reset. Clear PE, check
    // the APB readback, then re-enable. Even if STOP completed, an
    // unconsumed RXDR or TXDR and latched status can survive it.
    regs.CR1.modify(.{ .PE = 0 });
    if (regs.CR1.read().PE == 0) regs.CR1.modify(.{ .PE = 1 });
}

fn wait_for_failed_stop(regs: anytype, comptime clock: fn () u64) void {
    var status = regs.ISR.read();
    const control = regs.CR2.read();
    if (control.START == 1 or status.STOPF == 1 or status.ARLO == 1 or status.TIMEOUT == 1) return;

    // NACK already schedules STOP. For another failure while still master,
    // request STOP once. Give it time to finish before resetting the engine.
    if (status.NACKF == 0 and control.STOP == 0) regs.CR2.modify(.{ .STOP = 1 });
    var deadline = PollDeadline.init(clock(), recovery_timeout_us);
    while (true) {
        status = regs.ISR.read();
        if (status.STOPF == 1 or status.ARLO == 1 or status.TIMEOUT == 1) return;
        if (deadline.expired(clock())) return;
    }
}

test "I2C v2 rejects mismatched vectors before starting a write" {
    var regs = std.mem.zeroes(I2C_Peripherals);
    var adapter: I2C_Device = .{ .i2c = .{ .regs = &regs, .timingr = undefined } };
    const dev = adapter.i2c_device();
    const addr: Address = @fromBackingInt(0x40);
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.Unsupported, dev.writev_then_readv(addr, &.{}, &.{&byte}));
    try std.testing.expectError(error.Unsupported, dev.writev_then_readv(addr, &.{"x"}, &.{}));
    var oversize: [256]u8 = undefined;
    try std.testing.expectError(error.BufferOverrun, dev.writev_then_readv(addr, &.{"x"}, &.{&oversize}));
    try std.testing.expectEqual(@as(u32, 0), regs.CR2.raw);
}

const Status = @FieldType(I2C_Peripherals, "ISR").underlying_type;

test "I2C v2 polls handle errors, unexpected STOP, and both forms of timeout" {
    const Register = struct {
        status: Status,
        reads: usize = 0,

        fn read(self: *@This()) Status {
            self.reads += 1;
            return switch (self.reads) {
                1 => std.mem.zeroes(Status),
                2, 3 => self.status,
                else => @panic("poll missed a terminal status"),
            };
        }
    };
    const Clock = struct {
        fn now() u64 {
            return 10;
        }
    };
    for (std.enums.values(Phase)) |phase| {
        const Case = struct { status: Status, expected: I2CError };
        const cases: []const Case = &.{
            .{ .status = std.mem.zeroInit(Status, .{ .NACKF = 1, .STOPF = 1 }), .expected = error.NoAcknowledge },
            .{ .status = std.mem.zeroInit(Status, .{ .BERR = 1 }), .expected = error.UnknownAbort },
            .{ .status = std.mem.zeroInit(Status, .{ .ARLO = 1 }), .expected = error.UnknownAbort },
            .{ .status = std.mem.zeroInit(Status, .{ .TIMEOUT = 1 }), .expected = error.Timeout },
        };
        for (cases) |case| {
            var reg: Register = .{ .status = case.status };
            var deadline = PollDeadline.init(0, 11);
            try std.testing.expectError(case.expected, wait_for_status(.{ .ISR = &reg }, "unlisted", phase, &deadline, Clock.now));
        }
        var reg: Register = .{ .status = std.mem.zeroes(Status) };
        var deadline = PollDeadline.init(0, 10);
        try std.testing.expectError(error.Timeout, wait_for_status(.{ .ISR = &reg }, "unlisted", phase, &deadline, Clock.now));
        reg.status.STOPF = 1;
        reg.reads = 1;
        if (phase == .stop) {
            try wait_for_status(.{ .ISR = &reg }, "unlisted", phase, &deadline, Clock.now);
        } else {
            try std.testing.expectError(error.UnknownAbort, wait_for_status(.{ .ISR = &reg }, "unlisted", phase, &deadline, Clock.now));
        }
    }
    var last: Register = .{ .status = std.mem.zeroInit(Status, .{ .RXNE = 1, .STOPF = 1 }), .reads = 1 };
    var deadline = PollDeadline.init(0, 10);
    try wait_for_status(.{ .ISR = &last }, "unlisted", .last_rx, &deadline, Clock.now);
    try std.testing.expectError(error.UnknownAbort, wait_for_status(.{ .ISR = &last }, "unlisted", .rx, &deadline, Clock.now));
    var stalled: Register = .{ .status = std.mem.zeroes(Status) };
    deadline = PollDeadline.init(10, 100);
    deadline.stalled_polls_left = 2;
    try std.testing.expectError(error.Timeout, wait_for_status(.{ .ISR = &stalled }, "unlisted", .stop, &deadline, Clock.now));
}

test "I2C v2 clears a spurious BERR and completes a blocking read" {
    var regs = std.mem.zeroes(I2C_Peripherals);
    regs.CR1.modify(.{ .PE = 1 });
    regs.ISR.modify(.{ .BERR = 1, .RXNE = 1, .STOPF = 1 });
    const bus: I2C = .{ .regs = &regs, .timingr = undefined };
    var byte: [1]u8 = undefined;
    try bus.read_blocking(@fromBackingInt(0x40), &byte);
    const Clear = @TypeOf(regs.ICR).underlying_type;
    try std.testing.expectEqual(std.mem.zeroInit(Clear, .{ .BERRCF = 1 }), regs.ICR.read());
}

test "I2C v2 waits past BERR and still handles terminal flags on affected parts" {
    const Clear = @FieldType(I2C_Peripherals, "ICR").underlying_type;
    const Bus = struct {
        status: Status,
        ICR: @FieldType(I2C_Peripherals, "ICR") = .{ .raw = 0 },

        fn read(self: *@This()) Status {
            const clear = self.ICR.read();
            return if (clear.BERRCF == 0) std.mem.zeroInit(Status, .{ .BERR = 1 }) else self.status;
        }

        fn wait(self: *@This(), comptime chip_name: []const u8, phase: Phase) I2CError!void {
            const Clock = struct {
                fn now() u64 {
                    return 1;
                }
            };
            var deadline = PollDeadline.init(0, 2);
            deadline.stalled_polls_left = 4;
            try wait_for_status(.{ .ISR = self, .ICR = &self.ICR }, chip_name, phase, &deadline, Clock.now);
        }
    };

    inline for (.{ "STM32F303VC", "STM32L476VG" }) |chip_name| {
        const cases = [_]struct { Phase, Status }{
            .{ .rx, std.mem.zeroInit(Status, .{ .RXNE = 1 }) },
            .{ .last_rx, std.mem.zeroInit(Status, .{ .RXNE = 1, .STOPF = 1 }) },
            .{ .tx, std.mem.zeroInit(Status, .{ .TXIS = 1 }) },
            .{ .restart, std.mem.zeroInit(Status, .{ .TC = 1 }) },
            .{ .stop, std.mem.zeroInit(Status, .{ .STOPF = 1 }) },
        };
        for (cases) |case| {
            var bus: Bus = .{ .status = case[1] };
            try bus.wait(chip_name, case[0]);
            try std.testing.expectEqual(std.mem.zeroInit(Clear, .{ .BERRCF = 1 }), bus.ICR.read());
        }

        var nack: Bus = .{ .status = std.mem.zeroInit(Status, .{ .NACKF = 1, .STOPF = 1 }) };
        try std.testing.expectError(error.NoAcknowledge, nack.wait(chip_name, .stop));
        var stalled: Bus = .{ .status = std.mem.zeroes(Status) };
        try std.testing.expectError(error.Timeout, stalled.wait(chip_name, .tx));
    }
}

test "I2C v2 waits for delayed STOP before resetting or times out" {
    const Bus = struct {
        stop_after: ?usize,
        nack: bool,
        start_pending: bool = false,
        reads: usize = 0,
        stop_seen: bool = false,
        stop_writes: usize = 0,
        enabled: bool = true,
        resets: usize = 0,
        reset_before_stop: bool = false,

        const ISR = struct {
            bus: *Device,

            fn read(self: @This()) Status {
                const bus = self.bus;
                bus.reads += 1;
                bus.stop_seen = if (bus.stop_after) |after| bus.reads >= after else false;
                return std.mem.zeroInit(Status, .{
                    .STOPF = @intFromBool(bus.stop_seen),
                    .NACKF = @intFromBool(bus.nack),
                    .BERR = @intFromBool(!bus.nack),
                });
            }
        };
        const CR1 = struct {
            bus: *Device,

            fn read(self: @This()) struct { PE: u1 } {
                return .{ .PE = @intFromBool(self.bus.enabled) };
            }

            fn modify(self: @This(), fields: struct { PE: u1 }) void {
                self.bus.enabled = fields.PE == 1;
                if (!self.bus.enabled) {
                    self.bus.reset_before_stop = self.bus.stop_after != null and !self.bus.stop_seen;
                    self.bus.resets += 1;
                }
            }
        };
        const CR2 = struct {
            bus: *Device,

            fn read(self: @This()) struct { START: u1, STOP: u1 } {
                return .{ .START = @intFromBool(self.bus.start_pending), .STOP = 0 };
            }

            fn modify(self: @This(), fields: struct { STOP: u1 }) void {
                std.debug.assert(fields.STOP == 1);
                self.bus.stop_writes += 1;
            }
        };
        const Device = @This();
        var clock_us: u64 = 0;

        fn now() u64 {
            clock_us += 1_000;
            return clock_us;
        }
    };

    for ([_]Bus{
        .{ .stop_after = 3, .nack = true },
        .{ .stop_after = 3, .nack = false },
        .{ .stop_after = null, .nack = true },
        .{ .stop_after = null, .nack = false },
        .{ .stop_after = null, .nack = false, .start_pending = true },
    }) |initial| {
        var bus = initial;
        const regs = .{ .ISR = Bus.ISR{ .bus = &bus }, .CR1 = Bus.CR1{ .bus = &bus }, .CR2 = Bus.CR2{ .bus = &bus } };
        retire_failed_transfer(regs, Bus.now);
        try std.testing.expectEqual(@as(usize, if (bus.nack or bus.start_pending) 0 else 1), bus.stop_writes);
        try std.testing.expectEqual(@as(usize, 1), bus.resets);
        try std.testing.expect(!bus.reset_before_stop);
        if (bus.stop_after == null) {
            try std.testing.expectEqual(@as(usize, if (bus.start_pending) 1 else 6), bus.reads);
        }
        try std.testing.expect(bus.enabled);
    }
}
