const std = @import("std");
const microzig = @import("microzig");
const time = @import("time.zig");
const enums = @import("../common/enums.zig");

const I2C_Peripheral = microzig.chip.types.peripherals.i2c_v1.I2C;
const DUTY = microzig.chip.types.peripherals.i2c_v1.DUTY;
const F_S = microzig.chip.types.peripherals.i2c_v1.F_S;
const mdf = microzig.drivers;
const drivers = mdf.base;
const Duration = mdf.time.Duration;
const PollDeadline = @import("../common/systick.zig").PollDeadline;

const default_timeout_us = 100_000;
const recovery_timeout_us = 5_000;

pub const Mode = enum {
    standard,
    fast,
};

pub const AddressMode = enum {
    @"7bits",
    @"10bits",
};

pub const Address = struct {
    mode: AddressMode = .@"7bits",
    addr: u10,

    pub fn new(addr: u7) Address {
        return .{ .addr = addr };
    }

    pub fn from_generic(addr: mdf.base.I2C_Device.Address) Address {
        return .{ .addr = @backingInt(addr) };
    }

    pub fn new_10bits(addr: u10) Address {
        return .{
            .addr = addr,
            .mode = .@"10bits",
        };
    }
};

pub const Config = struct {
    pclk: usize,
    speed: usize,
    mode: Mode = .standard,
    enable_duty: bool = false,
    address_mode: AddressMode = .@"7bits",
};

pub const ConfigError = error{
    PCLKUnderflow,
    PCLKOverflow,
    SpeedOverflow,
    SpeedUnderflow,
    InvalidAddress,
    InvalidTrise,
    InvalidCCR,
};

pub const Error = drivers.I2C_Device.Error || error{
    ArbitrationLoss,
    BusError,
    BusTimeout,

    //https://www.st.com/content/ccc/resource/technical/document/errata_sheet/f5/50/c9/46/56/db/4a/f6/CD00197763.pdf/files/CD00197763.pdf/jcr:content/translations/en.CD00197763.pdf
    //Timeout during start and stop may indicate that the bus is stuck, therefore it is necessary to reset the I2C
    //the user must also ensure that the timeout period is long enough to complete the operation
    UnrecoverableError,
};

fn freq_to_ns(freq: usize) usize {
    return @intCast(1_000_000_000 / @as(u64, freq));
}
fn calc_Trise(pclk: usize, Tmax: usize) usize {
    const Tpclk: f32 = @floatFromInt(freq_to_ns(pclk));
    const fTmax: f32 = @floatFromInt(Tmax);
    const Trise: usize = @intFromFloat(@ceil((fTmax / Tpclk) + 1));
    return Trise;
}

fn calc_CCR(pclk: usize, speed: usize, duty: ?bool) usize {
    const mult_val: f32 = if (duty) |val| if (val) 25 else 3 else 2;
    const fpclk: f32 = @floatFromInt(pclk);
    const fspeed: f32 = @floatFromInt(speed);
    return @as(usize, @intFromFloat(@ceil(fpclk / (mult_val * fspeed))));
}

fn comptime_fail_or_error(msg: []const u8, fmt_args: anytype, err: ConfigError) ConfigError {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(msg, fmt_args));
    } else {
        return err;
    }
}

pub const Instances = enums.I2C_Type;

pub const I2C = struct {
    regs: *volatile I2C_Peripheral,
    fn validate_pclk(pclk: usize, mode: Mode) !void {
        if (pclk > 50_000_000)
            return comptime_fail_or_error(
                "pclk needs to be < 50'000'000, is {}",
                .{pclk},
                ConfigError.PCLKOverflow,
            );
        switch (mode) {
            .standard => {
                if (pclk < 2_000_000)
                    return comptime_fail_or_error(
                        "pclk needs to be >= 2_000_000 in standard mode, is {}",
                        .{pclk},
                        ConfigError.PCLKUnderflow,
                    );
            },
            .fast => {
                if (pclk < 4_000_000)
                    return comptime_fail_or_error(
                        "pclk needs to be >= 4_000_000 in fast mode, is {}",
                        .{pclk},
                        ConfigError.PCLKUnderflow,
                    );
            },
        }
    }

    fn validate_speed(speed: usize, mode: Mode) !void {
        if (speed == 0)
            return comptime_fail_or_error("Invalid I2C speed (0)", .{}, ConfigError.SpeedUnderflow);

        switch (mode) {
            .standard => {
                if (speed > 100_000)
                    return comptime_fail_or_error(
                        "speed: {d} is too high for standard mode",
                        .{speed},
                        ConfigError.SpeedOverflow,
                    );
            },
            .fast => {
                if (speed > 400_000)
                    return comptime_fail_or_error(
                        "speed: {d} is too high for fast mode",
                        .{speed},
                        ConfigError.SpeedOverflow,
                    );
            },
        }
    }

    fn validate_Trise(pclk: usize, mode: Mode) !usize {
        const Tmax: usize = switch (mode) {
            .standard => 1000,
            .fast => 300,
        };

        const Trise = calc_Trise(pclk, Tmax);
        if ((Trise == 0) or (Trise > 63))
            return comptime_fail_or_error(
                "I2C config error: rise time invalid for plk {} and mode {any}",
                .{ pclk, mode },
                ConfigError.InvalidTrise,
            );
        return Trise;
    }

    fn validate_CCR(config: Config) !usize {
        const pclk = config.pclk;
        const speed = config.speed;
        const duty: ?bool = if (config.mode == .standard) null else config.enable_duty;
        const CCR = calc_CCR(pclk, speed, duty);
        switch (config.mode) {
            .fast => {
                if (CCR < 4)
                    return comptime_fail_or_error("Invalid CCR", .{}, ConfigError.InvalidCCR);
            },
            else => {},
        }

        return CCR;
    }

    pub fn apply(i2c: *const I2C, comptime config: Config) void {
        const mode = config.mode;
        const pclk = config.pclk;
        comptime validate_pclk(pclk, mode) catch unreachable;
        comptime validate_speed(config.speed, mode) catch unreachable;
        const Trise = comptime validate_Trise(pclk, mode) catch unreachable;
        const CCR = comptime validate_CCR(config) catch unreachable;

        i2c.apply_internal(config, CCR, Trise);
    }

    pub fn runtime_apply(i2c: *const I2C, config: Config) ConfigError!void {
        const mode = config.mode;
        const pclk = config.pclk;
        try validate_pclk(pclk, mode);
        try validate_speed(config.speed, mode);
        const Trise = try validate_Trise(pclk, mode);
        const CCR = try validate_CCR(config);

        i2c.apply_internal(config, CCR, Trise);
    }

    fn apply_internal(i2c: *const I2C, config: Config, CCR: usize, Trise: usize) void {
        const regs = i2c.regs;
        const val: u6 = @intCast(config.pclk / 1_000_000);
        const duty: usize = if (config.enable_duty) 1 else 0;
        const mode: F_S = @fromBackingInt(@backingInt(config.mode));

        regs.CR1.modify(.{ .PE = 0 });
        i2c.reset();

        regs.CR2.modify(.{ .FREQ = val });

        regs.TRISE.modify(.{ .TRISE = @as(u6, @intCast(Trise)) });

        regs.CCR.modify(.{
            .CCR = @as(u12, @intCast(CCR)),
            .DUTY = @as(DUTY, @fromBackingInt(@intCast(duty))),
            .F_S = mode,
        });

        regs.CR1.modify(.{ .PE = 1 });
    }

    fn reset(i2c: *const I2C) void {
        const regs = i2c.regs;
        regs.CR1.modify(.{ .SWRST = 1 });
        regs.CR1.modify(.{ .SWRST = 0 });
    }

    fn status_error(status: @FieldType(I2C_Peripheral, "SR1").underlying_type) ?Error {
        if (status.AF == 1) return error.NoAcknowledge;
        if (status.ARLO == 1) return error.ArbitrationLoss;
        if (status.BERR == 1) return error.BusError;
        if (status.TIMEOUT == 1) return error.BusTimeout;
        return null;
    }

    fn wait(regs: anytype, comptime flag: []const u8, deadline: *PollDeadline) Error!void {
        while (true) {
            const status = regs.SR1.read();
            if (status_error(status)) |err| return err;
            if (@field(status, flag) == 1) return;
            if (deadline.expired(time.get_time_since_boot().to_us())) return error.Timeout;
        }
    }

    fn retire_failed_transfer(i2c: *const I2C, err: Error) Error {
        defer i2c.clear_errors();
        if (err == error.ArbitrationLoss) return err;

        const control = i2c.regs.CR1.read();
        if (control.START == 1) return error.UnrecoverableError;
        // Reading SR2 also releases a latched ADDR before an abort.
        if (control.STOP == 1 or i2c.regs.SR2.read().MSL == 1) {
            i2c.clear_errors();
            var recovery = PollDeadline.init(time.get_time_since_boot().to_us(), recovery_timeout_us);
            if (control.STOP == 1) {
                i2c.wait_for_stop(&recovery) catch return error.UnrecoverableError;
            } else {
                i2c.STOP(&recovery) catch return error.UnrecoverableError;
            }
        }
        return err;
    }

    fn prepare(i2c: *const I2C) Error!void {
        const control = i2c.regs.CR1.read();
        // RM0008 §26.6.1 forbids modifying CR1 while START or STOP is set.
        if (control.START == 1 or control.STOP == 1 or i2c.regs.SR2.read().MSL == 1)
            return error.UnrecoverableError;
    }

    pub fn clear_errors(i2c: *const I2C) void {
        const regs = i2c.regs;
        regs.SR1.modify(.{
            .AF = 0,
            .ARLO = 0,
            .BERR = 0,
            .TIMEOUT = 0,
        });
    }

    fn START(i2c: *const I2C, deadline: *PollDeadline) Error!void {
        const regs = i2c.regs;

        regs.CR1.modify(.{
            .ACK = 1,
            .START = 1,
        });

        //if start condition is not generated in time, i2c bus need to be reset
        //NOTE: this is a workaround for the errata 2.9.4
        wait(regs, "START", deadline) catch return error.UnrecoverableError;
    }

    fn STOP(i2c: *const I2C, deadline: *PollDeadline) Error!void {
        const regs = i2c.regs;

        //if stop is already set, just wait for it to be cleared
        if (regs.CR1.read().STOP != 1) {
            regs.CR1.modify(.{
                .ACK = 0,
                .STOP = 1,
            });
        }

        try i2c.wait_for_stop(deadline);
    }

    fn wait_for_stop(i2c: *const I2C, deadline: *PollDeadline) Error!void {
        const regs = i2c.regs;
        //if stop condition is not generated in time, i2c bus need to be reset
        //if the bus still busy after stop condition, it means that the bus is in an error state, errata: 2.9.7
        while (true) {
            // STOPF is a slave flag on F1 (RM0008 §26.6.6). A master
            // waits for CR1.STOP and BUSY to clear.
            if (status_error(regs.SR1.read())) |err| return err;
            if (regs.CR1.read().STOP == 0 and !i2c.is_busy()) return;
            if (deadline.expired(time.get_time_since_boot().to_us())) return error.UnrecoverableError;
        }
    }

    fn clear_addr(regs: anytype) void {
        //clear ADDR register
        _ = regs.SR1.read();
        _ = regs.SR2.read();
    }

    fn send_7bits_addr(i2c: *const I2C, addr: u10, IO: u1, deadline: *PollDeadline) Error!void {
        const regs = i2c.regs;
        const addr7 = @as(u8, @intCast(addr));
        const byte: u8 = (addr7 << 1) + IO;
        regs.DR.modify(.{ .DR = byte });

        try wait(regs, "ADDR", deadline);
    }

    fn send_10bits_addr(i2c: *const I2C, addr: u10, IO: u1, deadline: *PollDeadline) Error!void {
        const regs = i2c.regs;

        //10 bits address is sent in 2 bytes
        //first byte is  made of a 5 bit prefix 111100 | the 2 MSB of the address + 0
        //second byte is made of the 8 LSB of the address
        //https://www.i2c-bus.org/addressing/10-bit-addressing/
        const high: u8 = @as(u8, @intCast(addr >> 8)) & 0b11;
        const low: u8 = @as(u8, @intCast(addr & 0xFF));
        const header: u8 = ((0xF0 | (high << 1)) & 0b11110110); //first header is always in Write mode

        regs.DR.modify(.{ .DR = header });
        try wait(regs, "ADD10", deadline);

        regs.DR.modify(.{ .DR = low });
        try wait(regs, "ADDR", deadline);
        if (IO == 1) {
            clear_addr(regs);
            const read_header: u8 = header | 1;
            try i2c.START(deadline);
            regs.DR.modify(.{ .DR = read_header });
            try wait(regs, "ADDR", deadline);
        }
    }

    fn set_addr(i2c: *const I2C, address: Address, rw: u1, deadline: *PollDeadline) Error!void {
        switch (address.mode) {
            .@"7bits" => try i2c.send_7bits_addr(address.addr, rw, deadline),
            .@"10bits" => try i2c.send_10bits_addr(address.addr, rw, deadline),
        }
    }

    fn read_rxne(regs: anytype, deadline: *PollDeadline) Error!u8 {
        try wait(regs, "RXNE", deadline);
        return regs.DR.read().DR;
    }

    fn read_last_two(regs: anytype, deadline: *PollDeadline) Error![2]u8 {
        try wait(regs, "BTF", deadline);
        // ES096, "Wrong data read into data register", workaround 2.
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        regs.CR1.modify(.{ .STOP = 1 });
        return .{ regs.DR.read().DR, regs.DR.read().DR };
    }

    fn read_last_three(regs: anytype, deadline: *PollDeadline) Error![3]u8 {
        try wait(regs, "BTF", deadline);
        const third_last, const second_last = blk: {
            // ES096, "Wrong data read into data register", workaround 2.
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            regs.CR1.modify(.{ .ACK = 0 });
            const byte = regs.DR.read().DR;
            regs.CR1.modify(.{ .STOP = 1 });
            break :blk .{ byte, regs.DR.read().DR };
        };
        return .{ third_last, second_last, try read_rxne(regs, deadline) };
    }

    // RM0008 rev 21 §26.3.3, master receiver method 2 (EV7, EV7_2, EV7_3).
    // The tail is selected once for the whole transaction, across slice boundaries.
    fn receive_data(regs: anytype, vector: microzig.utilities.SliceVector([]u8), count: usize, deadline: *PollDeadline) Error!void {
        // RM0008 rev 21 §26.3.3, master receiver method 2 (EV6_1 and EV6_3).
        // set_addr leaves the final ADDR latched, stretching SCL until cleared.
        {
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            if (count == 1) regs.CR1.modify(.{ .ACK = 0 });
            clear_addr(regs);
            switch (count) {
                1 => regs.CR1.modify(.{ .STOP = 1 }),
                2 => regs.CR1.modify(.{ .ACK = 0 }),
                else => {},
            }
        }

        var dest = vector.iterator();
        for (0..count -| 3) |_| {
            dest.next_element_ptr().?.value_ptr.* = try read_rxne(regs, deadline);
        }
        const tail: [3]u8, const tail_len: usize = switch (count) {
            1 => .{ .{ try read_rxne(regs, deadline), 0, 0 }, 1 },
            2 => blk: {
                const bytes = try read_last_two(regs, deadline);
                break :blk .{ .{ bytes[0], bytes[1], 0 }, 2 };
            },
            else => .{ try read_last_three(regs, deadline), 3 },
        };
        for (tail[0..tail_len]) |byte| dest.next_element_ptr().?.value_ptr.* = byte;
    }

    pub fn readv_blocking(i2c: *const I2C, addr: Address, chunks: []const []u8, timeout: ?Duration) Error!void {
        try i2c.prepare();
        i2c.readv(addr, chunks, timeout) catch |err| return i2c.retire_failed_transfer(err);
    }

    fn readv(i2c: *const I2C, addr: Address, chunks: []const []u8, timeout: ?Duration) Error!void {
        const vector = microzig.utilities.SliceVector([]u8).init(chunks);
        const count = vector.size();
        if (count == 0) return;

        const regs = i2c.regs;
        var deadline = PollDeadline.init(time.get_time_since_boot().to_us(), if (timeout) |t| t.to_us() else default_timeout_us);
        regs.CR1.modify_one("POS", if (count == 2) .Next else .Current);
        try i2c.START(&deadline);
        try i2c.set_addr(addr, 1, &deadline);

        try receive_data(regs, vector, count, &deadline);
        try i2c.wait_for_stop(&deadline);
        regs.CR1.modify_one("POS", .Current);
    }

    pub fn writev_blocking(i2c: *const I2C, addr: Address, chunks: []const []const u8, timeout: ?Duration) Error!void {
        try i2c.prepare();
        i2c.writev(addr, chunks, timeout) catch |err| return i2c.retire_failed_transfer(err);
    }

    fn writev(i2c: *const I2C, addr: Address, chunks: []const []const u8, timeout: ?Duration) Error!void {
        const regs = i2c.regs;
        var deadline = PollDeadline.init(time.get_time_since_boot().to_us(), if (timeout) |t| t.to_us() else default_timeout_us);

        regs.CR1.modify_one("POS", .Current);
        try i2c.START(&deadline);
        try i2c.set_addr(addr, 0, &deadline);
        clear_addr(regs);

        for (chunks) |data| {
            for (data) |byte| {
                try wait(regs, "TXE", &deadline);

                regs.DR.modify(.{
                    .DR = byte,
                });
            }
        }

        try wait(regs, "BTF", &deadline);

        try i2c.STOP(&deadline);
    }

    pub fn write_blocking(i2c: *const I2C, address: Address, data: []const u8, timeout: ?Duration) Error!void {
        return i2c.writev_blocking(address, &.{data}, timeout);
    }

    pub fn read_blocking(i2c: *const I2C, address: Address, data: []u8, timeout: ?Duration) Error!void {
        return i2c.readv_blocking(address, &.{data}, timeout);
    }

    ///use this function to check if the i2c is busy in multi-master mode
    ///NOTE: in single master mode
    ///having a busy state before the start condition means that the bus is in an error state.
    pub fn is_busy(i2c: *const I2C) bool {
        const regs = i2c.regs;
        return regs.SR2.read().BUSY == 1;
    }

    pub fn init(comptime instance: Instances) I2C {
        return .{ .regs = enums.get_regs(I2C_Peripheral, instance) };
    }
};

test "F1 receiver writes ACK and STOP at the transaction tail across chunks" {
    const Event = enum { clear_addr, nack, stop, data };
    const Bus = struct {
        const Self = @This();
        events: [9]Event = undefined,
        event_count: usize = 0,
        next: u8 = 1,

        fn record(self: *Self, event: Event) void {
            self.events[self.event_count] = event;
            self.event_count += 1;
        }

        const Control = struct {
            bus: *Self,

            fn modify(self: @This(), fields: anytype) void {
                if (@hasField(@TypeOf(fields), "ACK") and fields.ACK == 0) self.bus.record(.nack);
                if (@hasField(@TypeOf(fields), "STOP") and fields.STOP == 1) self.bus.record(.stop);
            }
        };
        const Status = struct {
            fn read(_: @This()) @FieldType(I2C_Peripheral, "SR1").underlying_type {
                return std.mem.zeroInit(@FieldType(I2C_Peripheral, "SR1").underlying_type, .{ .RXNE = 1, .BTF = 1 });
            }
        };
        const Status2 = struct {
            bus: *Self,

            fn read(self: @This()) void {
                self.bus.record(.clear_addr);
            }
        };
        const Data = struct {
            bus: *Self,

            fn read(self: @This()) struct { DR: u8 } {
                self.bus.record(.data);
                defer self.bus.next += 1;
                return .{ .DR = self.bus.next };
            }
        };
    };

    const sequences: []const []const Event = &.{
        &.{ .nack, .clear_addr, .stop, .data },
        &.{ .clear_addr, .nack, .stop, .data, .data },
        &.{ .clear_addr, .nack, .data, .stop, .data, .data },
        &.{ .clear_addr, .data, .nack, .data, .stop, .data, .data },
        &.{ .clear_addr, .data, .data, .nack, .data, .stop, .data, .data },
    };
    for (sequences, 1..) |expected, len| {
        var first: [1]u8 = undefined;
        var rest: [4]u8 = undefined;
        const chunks: []const []u8 = &.{ &.{}, &first, &.{}, rest[0 .. len - 1], &.{} };
        const vector = microzig.utilities.SliceVector([]u8).init(chunks);
        var bus: Bus = .{};
        const regs = .{
            .CR1 = Bus.Control{ .bus = &bus },
            .SR1 = Bus.Status{},
            .SR2 = Bus.Status2{ .bus = &bus },
            .DR = Bus.Data{ .bus = &bus },
        };
        var deadline = PollDeadline.init(0, default_timeout_us);
        try I2C.receive_data(regs, vector, vector.size(), &deadline);
        try std.testing.expectEqualSlices(Event, expected, bus.events[0..bus.event_count]);
        try std.testing.expectEqual(@as(u8, 1), first[0]);
        try std.testing.expectEqualSlices(u8, (&[_]u8{ 2, 3, 4, 5 })[0 .. len - 1], rest[0 .. len - 1]);
    }
}

test "F1 master waits time out with a stalled clock and prioritize hardware TIMEOUT" {
    var regs = std.mem.zeroes(I2C_Peripheral);
    const bus: I2C = .{ .regs = &regs };
    inline for (.{ "START", "ADDR", "ADD10", "RXNE", "TXE", "BTF" }) |flag| {
        regs.SR1.raw = 0;
        var deadline = PollDeadline.init(0, default_timeout_us);
        deadline.stalled_polls_left = 1;
        try std.testing.expectError(error.Timeout, I2C.wait(bus.regs, flag, &deadline));
        regs.SR1.modify(.{ .TIMEOUT = 1 });
        regs.SR1.modify_one(flag, 1);
        try std.testing.expectError(error.BusTimeout, I2C.wait(bus.regs, flag, &deadline));
    }
    regs.SR1.raw = 0;
    regs.CR1.modify(.{ .STOP = 1 });
    var deadline = PollDeadline.init(0, default_timeout_us);
    deadline.stalled_polls_left = 1;
    try std.testing.expectError(error.UnrecoverableError, bus.wait_for_stop(&deadline));
    try std.testing.expectError(error.UnrecoverableError, bus.prepare());
}
