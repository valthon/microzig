const std = @import("std");
const microzig = @import("microzig");
const enums = @import("enums.zig");

const hal = microzig.hal;
const Digital_IO = microzig.drivers.base.Digital_IO;
const spi_v2 = microzig.chip.types.peripherals.spi_v2;
const SPI_Peripheral = spi_v2.SPI;
pub const Instances = enums.SPI_Type;
const Error = error{
    MissingGpioPin,
} || Digital_IO.SetDirError || Digital_IO.SetBiasError || Digital_IO.WriteError || Digital_IO.ReadError;

const ChipSelect = enum {
    NSS, //hardware slave management using NSS pin
    GPIO, //software slave management using external GPIO
};

pub const Config = struct {
    phase: spi_v2.CPHA = .FirstEdge,
    polarity: spi_v2.CPOL = .IdleLow,
    chip_select: ChipSelect = .NSS,
    frame_format: spi_v2.LSBFIRST = .MSBFirst,
    data_size: spi_v2.DS = .Bits8,
    max_frequency: u32,
};

pub const SPI = Spi(SPI_Peripheral);

fn Spi(comptime Peripheral: type) type {
    return struct {
        const Self = @This();

        instance: Instances,
        spi: *volatile Peripheral,
        nss: ?*Digital_IO,

        pub fn apply(self: *const Self, config: Config) Error!void {
            const clk = hal.rcc.get_clock(self.instance);

            const divider = (clk / config.max_frequency) + 1;

            const br: spi_v2.BR = switch (divider) {
                0...2 => .Div2,
                3...4 => .Div4,
                5...8 => .Div8,
                9...16 => .Div16,
                17...32 => .Div32,
                33...64 => .Div64,
                65...128 => .Div128,
                else => .Div256,
            };

            self.spi.CR1.raw = 0; // Disable SPI end clear configs before configuration
            self.spi.CR1.modify(.{
                .CPOL = config.polarity,
                .CPHA = config.phase,
                .LSBFIRST = config.frame_format,
                .BR = br,
                .MSTR = spi_v2.MSTR.Master,
            });

            self.spi.CR2.modify(.{
                .DS = config.data_size,
                .SSOE = 1,
                .FRXTH = .Quarter,
            });

            // for now we only support master mode
            switch (config.chip_select) {
                .GPIO => {
                    if (self.nss) |nss| {
                        try nss.set_direction(.output);
                        try nss.set_bias(null);
                        try nss.write(.high);
                    } else {
                        return Error.MissingGpioPin;
                    }
                    self.spi.CR1.modify(.{ .SSM = 1, .SSI = 1 }); // Enable software slave management
                    self.spi.CR2.modify(.{ .SSOE = 0 }); // output disable for NSS pin
                },
                .NSS => {
                    self.spi.CR1.modify(.{ .SSM = 0, .SSI = 0 }); // Disable software slave management
                    self.spi.CR2.modify(.{ .SSOE = 1 }); // output enable for NSS pin
                },
            }

            self.spi.CR1.modify(.{ .SPE = 1 }); // Enable SPI
        }

        fn check_tx(self: *const Self) bool {
            return self.spi.SR.read().TXE != 0;
        }

        fn check_rx(self: *const Self) bool {
            return self.spi.SR.read().RXNE != 0;
        }

        fn busy_wait(self: *const Self) void {
            while (self.spi.SR.read().BSY != 0) {}
        }

        fn software_nss(self: *const Self) ?*Digital_IO {
            // RM0316 §30.5.5, NSS pin management. SSM selects software NSS.
            return if (self.spi.CR1.read().SSM == 1) self.nss else null;
        }

        pub fn write_blocking(self: *const Self, out: []const u8) Error!void {
            const pin = self.software_nss();
            if (pin) |nss| {
                try nss.write(.low);
            }
            defer if (pin) |nss| {
                nss.write(.high) catch {
                    @panic("NSS pin can not unselect chip");
                };
            };

            for (out) |byte| {
                self.spi.DR8 = byte;
                while (!self.check_tx()) {}
            }
            std.log.info("Status {any}", .{self.spi.SR.read()});

            // Empting the read fifo
            while (self.check_rx()) {
                std.mem.doNotOptimizeAway(self.spi.DR8);
            }

            self.busy_wait();

            std.log.info("Status {any}", .{self.spi.SR.read()});
        }

        ///this function is full-duplex only and does not support 3-wire mode and data burst
        ///if the revice buffer is bigger than the transmit buffer dummy bytes will be sent until the receive buffer is full
        ///if the transmit buffer is bigger than the receive buffer, all additional bytes will be ignored
        pub fn transceive_blocking(self: *const Self, out: []const u8, in: []u8) Error!void {
            const pin = self.software_nss();
            if (pin) |nss| {
                try nss.write(.low);
            }
            defer if (pin) |nss| {
                nss.write(.high) catch {
                    @panic("NSS pin can not unselect chip");
                };
            };
            const out_len = out.len;
            const in_len = in.len;

            var out_remain = out_len - 1;
            // Each byte sent to MOSI is read back as 0x00
            var in_remain = in_len + out_len;

            //  Let's purge the RX fifo
            while (self.check_rx()) {
                std.mem.doNotOptimizeAway(self.spi.DR8);
            }

            //load the first byte
            //the RX value will be loaded into the shift register, and will be loaded into the DR register after the first clock cycle
            self.spi.DR8 = out[0];
            while ((out_remain > 0) or (in_remain > 0)) {
                while (!self.check_tx()) {}
                if (out_remain > 0) {
                    self.spi.DR8 = out[out_len - out_remain];
                    out_remain -= 1;
                } else {
                    // Keep the clock running
                    self.spi.DR8 = 0;
                }

                while (!self.check_rx()) {}
                if (in_remain > 0) {
                    if (in_remain > in_len) {
                        // Discarding the bytes sent during transmit
                        std.mem.doNotOptimizeAway(self.spi.DR8);
                        in_remain -= 1;
                    } else {
                        in[in_len - in_remain] = @intCast(self.spi.DR8);
                        in_remain -= 1;
                    }
                }
            }

            self.busy_wait();
        }

        pub fn init(comptime spi_inst: Instances, nss: ?*Digital_IO) Self {
            hal.rcc.enable_clock(enums.to_peripheral(spi_inst));
            return .{ .spi = enums.get_regs(Peripheral, spi_inst), .instance = spi_inst, .nss = nss };
        }
    };
}

test "blocking SPI transfers toggle a supplied GPIO only in software NSS mode" {
    const Status = @FieldType(SPI_Peripheral, "SR").underlying_type;
    const Peripheral = struct {
        CR1: @FieldType(SPI_Peripheral, "CR1") = .{ .raw = 0 },
        SR: StatusRegister,
        DR8: u8 = 0,

        const StatusRegister = struct {
            reads: usize = 0,
            rx_after: usize,

            fn read(self: *volatile @This()) Status {
                self.reads += 1;
                if (self.reads > 8) @panic("unexpected SPI status poll");
                return std.mem.zeroInit(Status, .{
                    .TXE = 1,
                    .RXNE = @intFromBool(self.reads >= self.rx_after),
                });
            }
        };
    };
    const FakeGPIO = struct {
        writes: [2]Digital_IO.State = undefined,
        count: usize = 0,

        fn write(ctx: *anyopaque, value: Digital_IO.State) Digital_IO.WriteError!void {
            const gpio: *@This() = @ptrCast(@alignCast(ctx));
            gpio.writes[gpio.count] = value;
            gpio.count += 1;
        }

        const vtable: Digital_IO.VTable = .{
            .set_direction_fn = undefined,
            .set_bias_fn = undefined,
            .write_fn = write,
            .read_fn = undefined,
        };
    };

    for ([_]u1{ 0, 1 }) |ssm| {
        const expected: []const Digital_IO.State = if (ssm == 1) &.{ .low, .high } else &.{};
        var gpio: FakeGPIO = .{};
        var pin: Digital_IO = .{ .ptr = &gpio, .vtable = &FakeGPIO.vtable };
        var regs: Peripheral = .{ .SR = .{ .rx_after = std.math.maxInt(usize) } };
        regs.CR1.modify(.{ .SSM = ssm });
        const spi: Spi(Peripheral) = .{ .instance = undefined, .spi = &regs, .nss = &pin };

        try spi.write_blocking("x");
        try std.testing.expectEqualSlices(Digital_IO.State, expected, gpio.writes[0..gpio.count]);

        gpio.count = 0;
        // The FIFO starts empty and receives data after the first write.
        regs.SR = .{ .rx_after = 2 };
        var input: [1]u8 = undefined;
        try spi.transceive_blocking("x", &input);
        try std.testing.expectEqualSlices(Digital_IO.State, expected, gpio.writes[0..gpio.count]);
    }
}
