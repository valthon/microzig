const std = @import("std");
const microzig = @import("microzig");
const SliceVector = microzig.utilities.SliceVector;

const clocks = @import("clocks.zig");
const gpio = @import("gpio.zig");
const system = @import("system.zig");
const compatibility = @import("compatibility.zig");

const SPI_Regs = microzig.chip.types.peripherals.SPI2;

pub const fifo_word_len = 16;
pub const fifo_byte_len = fifo_word_len * @sizeOf(u32);

pub const BitMode = enum {
    single_one_wire,
    single_two_wires,
    dual,
    quad,
};

pub const instance = struct {
    pub const SPI2 = num(2);
    pub fn num(n: u2) SPI {
        std.debug.assert(n == 2);
        return @fromBackingInt(n);
    }
};

// TODO: add support for peripheral controlled chip select pins

pub const SPI = enum(u2) {
    _,

    pub const Config = struct {
        clock_config: clocks.Config,
        baud_rate: u32,
        bit_order: BitOrder = .msb_first,

        fn get_clock_source(self: Config) struct { select: u1, frequency: u32 } {
            // ESP32-C3 TRM v1.4, section 27.11, SPI_CLK_GATE_REG:
            // MST_CLK_SEL selects PLL_F80M (1) or the undivided XTAL (0).
            // Only rely on the PLL when the CPU clock config enables it.
            return switch (self.clock_config.cpu_clk_source) {
                .pll_clk => .{ .select = 1, .frequency = 80_000_000 },
                .xtal_clk => .{ .select = 0, .frequency = clocks.xtal_clk_freq },
            };
        }

        fn validate(self: Config) error{InvalidBaudRate}!void {
            const source_freq = self.get_clock_source().frequency;
            const min_divider = 1;
            const max_divider = (std.math.maxInt(u6) + 1) * (std.math.maxInt(u4) + 1);

            if (self.baud_rate < source_freq / max_divider or self.baud_rate > source_freq / min_divider) {
                return error.InvalidBaudRate;
            }
        }

        // translated from esp-hal in rust
        fn get_clock_config(self: Config) u32 {
            // TODO: we can return directly the packed type if we add some patches
            // to regz (not possible rn).
            const Reg = packed struct(u32) {
                CLKCNT_L: u6,
                CLKCNT_H: u6,
                CLKCNT_N: u6,
                CLKDIV_PRE: u4,
                reserved: u9 = 0,
                CLK_EQU_SYSCLK: u1,
            };

            const source_freq = self.get_clock_source().frequency;

            // Use the selected source directly if target frequency is high enough.
            if (self.baud_rate > ((source_freq / 4) * 3)) {
                return @bitCast(@as(Reg, .{
                    .CLKCNT_L = 0,
                    .CLKCNT_H = 0,
                    .CLKCNT_N = 0,
                    .CLKDIV_PRE = 0,
                    .CLK_EQU_SYSCLK = 1,
                }));
            }

            var bestn: i32 = -1;
            var bestpre: i32 = -1;
            var besterr: u32 = 0;

            const target_freq_hz: i32 = @intCast(self.baud_rate);
            const source_freq_hz: i32 = @intCast(source_freq);

            // Try all n values from 2 to 64
            var n: i32 = 2;
            while (n <= 64) : (n += 1) {
                var pre = @divFloor(@divFloor(source_freq_hz, n) + @divFloor(target_freq_hz, 2), target_freq_hz);
                if (pre <= 0) pre = 1;
                if (pre > 16) pre = 16;

                const real_freq = @divFloor(source_freq_hz, (pre * n));
                const errval = @abs(real_freq - target_freq_hz);

                if (bestn == -1 or errval <= besterr) {
                    besterr = errval;
                    bestn = n;
                    bestpre = pre;
                }
            }

            const l: i32 = bestn;
            var h: i32 = @divFloor(128 * bestn + 127, 256);
            if (h <= 0) h = 1;

            return @bitCast(@as(Reg, .{
                .CLKCNT_L = @intCast(l - 1),
                .CLKCNT_H = @intCast(h - 1),
                .CLKCNT_N = @intCast(bestn - 1),
                .CLKDIV_PRE = @intCast(bestpre - 1),
                .CLK_EQU_SYSCLK = 0,
            }));
        }
    };

    pub const BitOrder = enum(u1) {
        msb_first = 0,
        lsb_first = 1,
    };

    pub fn apply(self: SPI, comptime config: Config) void {
        comptime config.validate() catch @compileError("invalid baud rate");

        system.enable_clocks_and_release_reset(.{
            .spi2 = true,
        });

        self.modify_register("CLK_GATE", .{
            .CLK_EN = 1,
        });

        // this also enables using all 16 words
        self.register("USER").write_raw(0);

        switch (compatibility.chip) {
            .esp32_c3 => self.modify_register("CLK_GATE", .{
                .MST_CLK_ACTIVE = 1,
                .MST_CLK_SEL = config.get_clock_source().select,
            }),
            // C6 TRM v1.2 §8.4 PCR_SPI2_CLKM_CONF_REG, §28.5.1.
            .esp32_c6 => microzig.chip.peripherals.PCR.SPI2_CLKM_CONF.modify(.{
                .SPI2_CLKM_SEL = config.get_clock_source().select,
                .SPI2_CLKM_EN = 1,
            }),
        }

        self.modify_register("CTRL", .{
            .Q_POL = 0,
            .D_POL = 0,
            .WP_POL = 0,
        });

        // this also disables all cs lines
        self.register("MISC").write_raw(0);

        self.register("SLAVE").write_raw(0);

        self.register("CLOCK").write_raw(config.get_clock_config());

        self.clear_transfer_done();

        self.modify_register("DMA_INT_ENA", .{
            .TRANS_DONE_INT_ENA = 1,
        });

        self.set_bit_order(config.bit_order);
    }

    pub inline fn connect_pins(_: SPI, pins: struct {
        data: union(enum) {
            single_one_wire: ?gpio.Pin,
            single_two_wires: struct {
                mosi: ?gpio.Pin = null,
                miso: ?gpio.Pin = null,
            },
            dual: struct {
                bit0: ?gpio.Pin = null,
                bit1: ?gpio.Pin = null,
            },
            quad: struct {
                bit0: ?gpio.Pin = null,
                bit1: ?gpio.Pin = null,
                bit2: ?gpio.Pin = null,
                bit3: ?gpio.Pin = null,
            },
        } = .{ .single_one_wire = null },
        clk: ?gpio.Pin = null,
    }) void {
        switch (pins.data) {
            .single_one_wire => |maybe_pin| if (maybe_pin) |pin| {
                pin.connect_input_to_peripheral(.{ .signal = .fspid });
                pin.connect_peripheral_to_output(.{ .signal = .fspid });
            },
            .single_two_wires => |maybe_pins| {
                if (maybe_pins.mosi) |mosi| {
                    mosi.connect_peripheral_to_output(.{ .signal = .fspid });
                }
                if (maybe_pins.miso) |miso| {
                    miso.connect_input_to_peripheral(.{ .signal = .fspiq });
                }
            },
            .dual => |maybe_pins| {
                if (maybe_pins.bit0) |bit0| {
                    bit0.connect_input_to_peripheral(.{ .signal = .fspid });
                    bit0.connect_peripheral_to_output(.{ .signal = .fspid });
                }
                if (maybe_pins.bit1) |bit1| {
                    bit1.connect_input_to_peripheral(.{ .signal = .fspiq });
                    bit1.connect_peripheral_to_output(.{ .signal = .fspiq });
                }
            },
            .quad => |maybe_pins| {
                if (maybe_pins.bit0) |bit0| {
                    bit0.connect_input_to_peripheral(.{ .signal = .fspid });
                    bit0.connect_peripheral_to_output(.{ .signal = .fspid });
                }
                if (maybe_pins.bit1) |bit1| {
                    bit1.connect_input_to_peripheral(.{ .signal = .fspiq });
                    bit1.connect_peripheral_to_output(.{ .signal = .fspiq });
                }
                if (maybe_pins.bit2) |bit2| {
                    bit2.connect_input_to_peripheral(.{ .signal = .fspiwp });
                    bit2.connect_peripheral_to_output(.{ .signal = .fspiwp });
                }
                if (maybe_pins.bit3) |bit3| {
                    bit3.connect_input_to_peripheral(.{ .signal = .fspihd });
                    bit3.connect_peripheral_to_output(.{ .signal = .fspihd });
                }
            },
        }

        if (pins.clk) |clk_pin| {
            clk_pin.connect_peripheral_to_output(.{ .signal = .fspiclk });
        }
    }

    pub fn writev_blocking(
        self: SPI,
        buffer_vec: []const []const u8,
        bit_mode: BitMode,
    ) void {
        const vec: SliceVector([]const u8) = .init(buffer_vec);
        var iter = vec.iterator();

        var remaining = vec.size();

        while (remaining > 0) {
            const transfer_len: u18 = @min(remaining, fifo_byte_len);

            self.fill_fifo(&iter, transfer_len);

            self.start_transfer_generic(
                true,
                false,
                transfer_len * 8,
                bit_mode,
            );

            self.wait_for_transfer_blocking();

            remaining -= transfer_len;
        }
    }

    pub fn write_blocking(
        self: SPI,
        buffer: []const u8,
        bit_mode: BitMode,
    ) void {
        self.writev_blocking(
            &.{buffer},
            bit_mode,
        );
    }

    pub fn readv_blocking(
        self: SPI,
        buffer_vec: []const []u8,
        bit_mode: BitMode,
    ) usize {
        const vec: SliceVector([]u8) = .init(buffer_vec);
        var iter = vec.iterator();

        const total_len = vec.size();

        var remaining = total_len;

        while (remaining > 0) {
            const transfer_len: u18 = @min(remaining, fifo_byte_len);

            self.start_transfer_generic(
                false,
                true,
                transfer_len * 8,
                bit_mode,
            );
            self.wait_for_transfer_blocking();

            self.read_fifo(&iter, transfer_len);

            remaining -= transfer_len;
        }

        return total_len;
    }

    pub fn read_blocking(
        self: SPI,
        buffer: []u8,
        bit_mode: BitMode,
    ) usize {
        return self.readv_blocking(
            &.{buffer},
            bit_mode,
        );
    }

    pub fn transceivev_blocking(
        self: SPI,
        write_buffer_vec: []const []const u8,
        read_buffer_vec: []const []u8,
    ) void {
        const write_vec: SliceVector([]const u8) = .init(write_buffer_vec);
        var write_iter = write_vec.iterator();
        const read_vec: SliceVector([]const u8) = .init(read_buffer_vec);
        var read_iter = read_vec.iterator();

        var remaining = write_vec.size();
        std.debug.assert(remaining == read_vec.size()); // the length of the written data must equal the length of the read data

        while (remaining > 0) {
            const transfer_len = @min(remaining, fifo_byte_len);

            self.fill_fifo(&write_iter, transfer_len);

            self.start_transfer_generic(
                true,
                true,
                transfer_len * 8,
                .single_two_wires,
            );
            self.wait_for_transfer_blocking();

            self.read_fifo(&read_iter, transfer_len);

            remaining -= transfer_len;
        }
    }

    pub fn transceive_blocking(
        self: SPI,
        write_buffer: []const u8,
        read_buffer: []u8,
    ) void {
        self.transceivev_blocking(&.{write_buffer}, &.{read_buffer});
    }

    // W1C: write only the requested flag, never read-modify-write.
    fn clear_transfer_done(self: SPI) void {
        var value = std.mem.zeroes(@TypeOf(self.register("DMA_INT_CLR").read()));
        @field(value, register_name("TRANS_DONE_INT_CLR")) = 1;
        self.register("DMA_INT_CLR").write(value);
    }

    // C6's SVD keeps the SPI_ prefix; select generated names without copying
    // register definitions or duplicating the transfer implementation.
    fn register_name(comptime name: []const u8) []const u8 {
        return if (compatibility.chip == .esp32_c6) "SPI_" ++ name else name;
    }

    fn register(self: SPI, comptime name: []const u8) *volatile @FieldType(SPI_Regs, register_name(name)) {
        return &@field(self.get_regs(), register_name(name));
    }

    fn modify_register(self: SPI, comptime name: []const u8, fields: anytype) void {
        const reg = self.register(name);
        var value = reg.read();
        inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |field| {
            @field(value, register_name(field)) = @field(fields, field);
        }
        reg.write(value);
    }

    inline fn get_regs(self: SPI) *volatile SPI_Regs {
        std.debug.assert(@backingInt(self) == 2);
        return microzig.chip.peripherals.SPI2;
    }

    fn set_bit_order(self: SPI, bit_order: BitOrder) void {
        self.modify_register("CTRL", .{
            .RD_BIT_ORDER = @backingInt(bit_order),
            .WR_BIT_ORDER = @backingInt(bit_order),
        });
    }

    fn fill_fifo(self: SPI, iter: *SliceVector([]const u8).Iterator, len: usize) void {
        const fifo: *volatile [16]u32 = @ptrCast(self.register("W0"));

        var i: usize = 0;
        var word: u32 = 0;
        while (i < len) : (i += 1) {
            const el = iter.next_element().?;

            const shift: u5 = @intCast((i & 0x3) << 3);
            word |= @as(u32, el.value) << shift;

            if ((i + 1) % 4 == 0) {
                fifo[i / 4] = word;
                word = 0;
            }
        }

        // Add remaining bytes
        if (len % 4 != 0) {
            fifo[len / 4] = word;
        }
    }

    fn read_fifo(self: SPI, iter: *SliceVector([]u8).Iterator, len: usize) void {
        const fifo: *volatile [16]u32 = @ptrCast(self.register("W0"));

        var i: usize = 0;
        while (i < len) : (i += 1) {
            const el = iter.next_element_ptr().?;

            const shift: u5 = @intCast((i & 0x3) << 3);
            el.value_ptr.* = @intCast((fifo[i / 4] >> shift) & 0xff);
        }
    }

    fn start_transfer_generic(
        self: SPI,
        write: bool,
        read: bool,
        data_bitlen: u18,
        bit_mode: BitMode,
    ) void {
        self.modify_register("USER", .{
            .DOUTDIN = @intFromBool(write and read),
            .SIO = @intFromBool(bit_mode == .single_one_wire),

            .USR_COMMAND = 0,
            .USR_ADDR = 0,
            .USR_DUMMY = 0,
            .USR_MOSI = @intFromBool(write),
            .USR_MISO = @intFromBool(read),

            .FWRITE_DUAL = @intFromBool(bit_mode == .dual),
            .FWRITE_QUAD = @intFromBool(bit_mode == .quad),
        });

        self.modify_register("CTRL", .{
            .FCMD_DUAL = @intFromBool(bit_mode == .dual),
            .FCMD_QUAD = @intFromBool(bit_mode == .quad),
            .FADDR_DUAL = @intFromBool(bit_mode == .dual),
            .FADDR_QUAD = @intFromBool(bit_mode == .quad),
            .FREAD_DUAL = @intFromBool(bit_mode == .dual),
            .FREAD_QUAD = @intFromBool(bit_mode == .quad),
        });

        self.register("MS_DLEN").write_raw(@intCast(data_bitlen - 1));

        self.clear_transfer_done();

        self.modify_register("DMA_CONF", .{
            .RX_AFIFO_RST = 1,
            .BUF_AFIFO_RST = 1,
            .DMA_AFIFO_RST = 1,
        });

        self.modify_register("CMD", .{
            .UPDATE = 1,
        });

        while (@field(self.register("CMD").read(), register_name("UPDATE")) == 1) {}

        self.modify_register("CMD", .{
            .USR = 1,
        });
    }

    fn wait_for_transfer_blocking(self: SPI) void {
        while (@field(self.register("DMA_INT_RAW").read(), register_name("TRANS_DONE_INT_RAW")) != 1) {}
    }
};
