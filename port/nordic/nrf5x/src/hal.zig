const std = @import("std");
const microzig = @import("microzig");

pub const clocks = @import("hal/clocks.zig");
pub const compatibility = @import("hal/compatibility.zig");
pub const gpio = @import("hal/gpio.zig");
pub const gpiote = @import("hal/gpiote.zig");
pub const i2c = @import("hal/i2c.zig");
pub const ieee802154 = if (microzig.options.hal.ieee802154 and compatibility.chip == .nrf52840)
    @import("hal/radio/ieee802154.zig")
else
    struct {};
pub const i2cdma = @import("hal/i2cdma.zig");
pub const nvmc = @import("hal/nvmc.zig");
pub const pdm = @import("hal/pdm.zig");
pub const power = @import("hal/power.zig");
pub const ppi = @import("hal/ppi.zig");
pub const pwm = @import("hal/pwm.zig");
pub const qspi = @import("hal/qspi.zig");
pub const rng = @import("hal/rng.zig");
pub const rtc = @import("hal/rtc.zig");
pub const saadc = @import("hal/saadc.zig");
pub const spim = @import("hal/spim.zig");
pub const temp = @import("hal/temp.zig");
pub const time = @import("hal/time.zig");
pub const timer = @import("hal/timer.zig");
pub const uart = @import("hal/uart.zig");
pub const usbd = @import("hal/usbd.zig");
pub const wdt = @import("hal/wdt.zig");
pub const drivers = @import("hal/drivers.zig");
// TODO: interrupts, wifi, nfc, bt, zigbee

comptime {
    // Firmware builds also instantiate the methods against target register definitions.
    if (@hasDecl(microzig, "drivers") and compatibility.chip != .nrf51) {
        _ = &drivers.SPI_Device.write;
        _ = &drivers.SPI_Device.writev;
        _ = &drivers.SPI_Device.read;
        _ = &drivers.SPI_Device.readv;
        _ = &i2cdma.I2C.read_blocking;
        _ = &i2cdma.I2C.writev_blocking;
        _ = &i2cdma.I2C.write_then_read_blocking;
    }
}

pub const HAL_Options = struct {
    /// Reserve the nRF52840 RADIO and TIMER3 interrupt vectors for the radio driver.
    ieee802154: bool = false,
};

pub const default_interrupts: microzig.cpu.InterruptOptions = interrupts: {
    var handlers: microzig.cpu.InterruptOptions = .{
        // Required for timekeeping longer than 512 seconds.
        .RTC0 = .{ .c = time.rtc_interrupt },
    };
    if (microzig.options.hal.ieee802154) {
        if (compatibility.chip != .nrf52840) compatibility.unsupported_chip("IEEE 802.15.4");
        handlers.RADIO = .{ .c = ieee802154.radio_interrupt };
        handlers.TIMER3 = .{ .c = ieee802154.timer_interrupt };
    }
    break :interrupts handlers;
};

pub fn init() void {
    time.init();
}

pub const DmaMode = enum { spim, twim };

// The enum handles alias the same two physical instances. Callers serialize
// each instance, including across modes. Interrupt handlers do not access this.
var pending_dma_stop: [2]?DmaMode = @splat(null);

/// Waits for a STOP that a previous call could not finish on this instance.
pub fn wait_for_shared_dma(instance: u1) error{BusStuck}!void {
    if (pending_dma_stop[instance]) |mode| try finish_dma_stop(instance, mode);
}

/// Waits for an issued STOP, recording its mode only if the wait times out.
pub fn finish_dma_stop(instance: u1, mode: DmaMode) error{BusStuck}!void {
    errdefer pending_dma_stop[instance] = mode;
    try switch (mode) {
        .spim => spim.num(instance).finish_dma_stop(),
        .twim => i2cdma.num(instance).finish_dma_stop(),
    };
    pending_dma_stop[instance] = null;
}

/// Clears the shared DMA configuration after recovery and with ENABLE disabled.
pub fn clear_shared_dma_registers(instance: u1) void {
    // nRF52840 PS v1.2 §§6.1.2, 6.25.6 and 6.31.7: SPIM and TWIM
    // share the register offsets for both DMA pointers and counts.
    const regs = spim.num(instance).get_regs();
    regs.RXD.PTR.write_raw(0);
    regs.TXD.PTR.write_raw(0);
    regs.RXD.MAXCNT.write(.{ .MAXCNT = 0 });
    regs.TXD.MAXCNT.write(.{ .MAXCNT = 0 });
}

pub fn stop_budget_us(frequency: u32, bits_per_byte: u32) u32 {
    // Allow 16 byte times and round up. Add one RTC0 tick (32,768 Hz,
    // nRF52840 Product Specification, RTC) to cover timestamp quantization.
    return @max(1_000, (16 * bits_per_byte * 1_000_000 + frequency - 1) / frequency) + 31;
}

/// Waits for a STOP already requested by software or a shortcut.
pub fn wait_for_stop(regs: anytype, deadline: anytype, now: anytype, comptime wait_for_end: bool) error{BusStuck}!void {
    while (!transfer_has_stopped(regs, wait_for_end)) {
        if (deadline.is_reached_by(now())) {
            // Recheck in case hardware latched STOPPED during the clock read.
            if (transfer_has_stopped(regs, wait_for_end)) return;
            return error.BusStuck;
        }
    }
}

fn transfer_has_stopped(regs: anytype, comptime wait_for_end: bool) bool {
    return regs.EVENTS_STOPPED.read().EVENTS_STOPPED == .Generated and
        (!wait_for_end or regs.EVENTS_END.read().EVENTS_END == .Generated);
}

test "nRF EasyDMA STOP budget covers slow byte times and the 1 ms minimum" {
    try std.testing.expectEqual(@as(u32, 1_471), stop_budget_us(100_000, 9));
    try std.testing.expectEqual(@as(u32, 1_055), stop_budget_us(125_000, 8));
    try std.testing.expectEqual(@as(u32, 1_031), stop_budget_us(8_000_000, 8));
}

// Host tests use the generated register layouts in RAM. The fake clock
// advances between polls. Task order is observed at the register writes.
pub const serial_test = struct {
    const mmio = @import("serial_test_mmio");

    pub const drivers = @import("serial_drivers");
    pub const utilities = @import("serial_core").utilities;
    pub const chip = struct {
        pub const types = @import("serial_chip").types;
        pub const peripherals = struct {
            pub const SPIM0 = &serial_registers[0].spim;
            pub const SPIM1 = &serial_registers[1].spim;
            pub const TWIM0 = &serial_registers[0].twim;
            pub const TWIM1 = &serial_registers[1].twim;
            pub const TWI0 = &serial_registers[0].twi;
            pub const TWI1 = &serial_registers[1].twi;
            pub const P0 = &gpio_registers[0];
            pub const P1 = &gpio_registers[1];
        };
    };
    pub const gpio = struct {
        pub const Pin = enum {
            unused,
            pub fn set_direction(_: Pin, _: enum { out }) void {}
            pub fn put(_: Pin, _: u1) void {}
        };
    };

    const regs = chip.types.peripherals;
    const SerialRegisters = extern union {
        spim: regs.SPIM0,
        twim: regs.TWIM0,
        twi: regs.TWI0,
    };
    const Mode = enum { spim, twim, twi };
    var serial_registers: [2]SerialRegisters = undefined;
    var gpio_registers: [2]regs.P0 = undefined;
    var spi: *regs.SPIM0 = undefined;
    var twim: *regs.TWIM0 = undefined;
    var twi: *regs.TWI0 = undefined;
    const tick_us = 50;

    const Simulation = struct {
        now: u64 = 0,
        spim_complete_at: u64 = 0,
        spim_stops: bool = true,
        spim_chunks: [4]struct { tx: u16, rx: u16 } = undefined,
        spim_starts: usize = 0,
        spim_stop_at: ?u64 = null,
        spim_pin_writes: usize = 0,
        spim_pin_writes_enabled: usize = 0,
        twim_completion: enum { stalled, stopped, suspend_then_stop, suspend_with_error } = .stalled,
        twim_stop_after_read: ?struct { at: u64, amount: u16 } = null,
        twim_starts: usize = 0,
        twim_stop_at: ?u64 = null,
        twim_stops: bool = true,
        twim_suspended: bool = false,
        twi_tx_at: u64 = 300,
        twi_rx_at: u64 = 300,
        twi_stop_at: ?u64 = null,
        twi_stops: bool = true,
        twi_resumed_with_shorts_cleared: bool = false,
    };

    var bus: Simulation = undefined;

    fn reset(mode: Mode) void {
        reset_instance(0, mode);
    }

    fn reset_instance(instance: u1, mode: Mode) void {
        mmio.after_read = observe_read;
        mmio.on_write = observe_write;
        pending_dma_stop = @splat(null);
        bus = .{};
        serial_registers = std.mem.zeroes(@TypeOf(serial_registers));
        gpio_registers = std.mem.zeroes(@TypeOf(gpio_registers));
        spi = &serial_registers[instance].spim;
        twim = &serial_registers[instance].twim;
        twi = &serial_registers[instance].twi;
        switch (mode) {
            .spim => spi.ENABLE.write(.{ .ENABLE = .Enabled }),
            .twim => twim.ENABLE.write(.{ .ENABLE = .Enabled }),
            .twi => twi.ENABLE.write(.{ .ENABLE = .Enabled }),
        }
    }

    fn observe_read(addr: *volatile u32) void {
        if (addr != &twim.EVENTS_STOPPED.raw) return;
        const stop = bus.twim_stop_after_read orelse return;
        if (bus.now < stop.at) return;
        bus.twim_stop_after_read = null;
        twim.RXD.AMOUNT.write(.{ .AMOUNT = stop.amount });
        twim.EVENTS_STOPPED.raw = 1;
    }

    fn observe_write(addr: *volatile u32, value: u32) void {
        if (addr == &spi.PSEL.SCK.raw or addr == &spi.PSEL.MOSI.raw or addr == &spi.PSEL.MISO.raw) {
            bus.spim_pin_writes += 1;
            if (spi.ENABLE.read().ENABLE == .Enabled) bus.spim_pin_writes_enabled += 1;
        }
        if (value != 1 or twim.ENABLE.read().ENABLE != .Enabled) return;
        if (addr == &twim.TASKS_RESUME.raw) {
            twim.TASKS_RESUME.raw = 0;
            bus.twim_suspended = false;
        } else if (addr == &twim.TASKS_STOP.raw) {
            twim.TASKS_STOP.raw = 0;
            if (!bus.twim_suspended) bus.twim_stop_at = bus.now;
        }
    }

    pub fn get_time_since_boot() @This().drivers.time.Absolute {
        const now = bus.now;
        bus.now += tick_us;
        std.debug.assert(bus.now <= 10_000);
        if (spi.ENABLE.read().ENABLE == .Enabled) {
            poll_spim(now);
        } else if (twim.ENABLE.read().ENABLE == .Enabled) {
            poll_twim(now);
        } else if (twi.ENABLE.read().ENABLE == .Enabled) {
            poll_twi(now);
        }
        return .from_us(now);
    }

    fn poll_spim(now: u64) void {
        if (spi.TASKS_START.raw != 0) {
            spi.TASKS_START.raw = 0;
            bus.spim_chunks[bus.spim_starts] = .{
                .tx = spi.TXD.MAXCNT.read().MAXCNT,
                .rx = spi.RXD.MAXCNT.read().MAXCNT,
            };
            bus.spim_starts += 1;
        }
        if (spi.TASKS_STOP.raw != 0) {
            spi.TASKS_STOP.raw = 0;
            bus.spim_stop_at = now;
        }
        if (bus.spim_stop_at) |stop_at| {
            if (bus.spim_stops and now >= stop_at + tick_us) {
                spi.EVENTS_STOPPED.raw = 1;
                spi.EVENTS_END.raw = 1;
            }
        } else if (bus.spim_starts != 0 and now >= bus.spim_complete_at) {
            spi.EVENTS_END.raw = 1;
        }
    }

    fn poll_twim(now: u64) void {
        // Consume the driver's write-one-to-clear before injecting new errors.
        if (twim.ERRORSRC.raw == 0xFFFFFFFF) twim.ERRORSRC.raw = 0;
        if (!bus.twim_suspended and (twim.TASKS_STARTTX.raw != 0 or twim.TASKS_STARTRX.raw != 0)) {
            twim.TASKS_STARTTX.raw = 0;
            twim.TASKS_STARTRX.raw = 0;
            bus.twim_starts += 1;
            switch (bus.twim_completion) {
                .stalled => {},
                .suspend_then_stop, .suspend_with_error => {
                    twim.TXD.AMOUNT.write(.{ .AMOUNT = twim.TXD.MAXCNT.read().MAXCNT });
                    if (twim.SHORTS.read().LASTTX_SUSPEND == .Enabled) {
                        bus.twim_suspended = true;
                        twim.EVENTS_SUSPENDED.raw = 1;
                        if (bus.twim_completion == .suspend_with_error) {
                            twim.ERRORSRC.modify(.{ .DNACK = .Received });
                            twim.EVENTS_ERROR.raw = 1;
                        }
                    } else {
                        twim.EVENTS_STOPPED.raw = 1;
                    }
                },
                .stopped => {
                    twim.RXD.AMOUNT.write(.{ .AMOUNT = twim.RXD.MAXCNT.read().MAXCNT });
                    twim.EVENTS_STOPPED.raw = 1;
                },
            }
        }
        if (bus.twim_stop_at) |stop_at| {
            if (bus.twim_stops and now == stop_at + tick_us) twim.EVENTS_STOPPED.raw = 1;
        }
    }

    fn poll_twi(now: u64) void {
        if (twi.TASKS_STARTTX.raw != 0 and now >= bus.twi_tx_at) {
            twi.TASKS_STARTTX.raw = 0;
            twi.EVENTS_TXDSENT.raw = 1;
        }
        if (twi.TASKS_STARTRX.raw != 0 and now >= bus.twi_rx_at) {
            twi.TASKS_STARTRX.raw = 0;
            twi.RXD.raw = 0xA5;
            twi.EVENTS_RXDREADY.raw = 1;
        }
        if (twi.TASKS_STOP.raw != 0) {
            twi.TASKS_STOP.raw = 0;
            bus.twi_stop_at = now;
            bus.twi_resumed_with_shorts_cleared = twi.TASKS_RESUME.raw != 0 and twi.SHORTS.raw == 0;
        }
        twi.TASKS_RESUME.raw = 0;
        if (bus.twi_stop_at) |stop_at| {
            if (bus.twi_stops and now == stop_at + tick_us) twi.EVENTS_STOPPED.raw = 1;
        }
    }
};

test "concrete SPI adapter keeps its timeout across scalar, vectored and erased calls" {
    const fake = serial_test;
    var adapter = drivers.SPI_Device.init(spim.num(0), null);
    adapter.timeout = .from_us(100);
    var rx: [1]u8 = undefined;
    const Method = enum { write, writev, read, readv, erased_write, erased_read };
    inline for (std.enums.values(Method)) |method| {
        fake.reset(.spim);
        fake.bus.spim_complete_at = 300;
        const result = switch (method) {
            .write => adapter.write("w"),
            .writev => adapter.writev(&.{"w"}),
            .read => adapter.read(&rx),
            .readv => adapter.readv(&.{&rx}),
            .erased_write => adapter.datagram_device().write("w"),
            .erased_read => adapter.datagram_device().read(&rx),
        };
        try std.testing.expectError(error.Timeout, result);
        try std.testing.expectEqual(@as(usize, 1), fake.bus.spim_starts);
        try std.testing.expect(fake.bus.spim_stop_at != null);
        try std.testing.expectEqual(@as(u32, 1), fake.spi.EVENTS_STOPPED.raw);
        try std.testing.expectEqual(@as(u32, 1), fake.spi.EVENTS_END.raw);
        try std.testing.expectEqual(.Enabled, fake.spi.ENABLE.read().ENABLE);
    }
}

test "SPIM keeps the instance and DMA buffers outstanding until STOPPED and END" {
    const fake = serial_test;
    const spi = spim.num(0);
    var adapter = drivers.SPI_Device.init(spi, null);
    adapter.timeout = .from_us(100);
    fake.reset(.spim);
    fake.bus.spim_complete_at = 300;
    fake.bus.spim_stops = false;
    try std.testing.expectError(error.BusStuck, spi.write_blocking("w", .from_us(100)));
    const stop_at = fake.bus.spim_stop_at;
    try std.testing.expect(stop_at != null);
    try std.testing.expectEqual(.Enabled, fake.spi.ENABLE.read().ENABLE);
    const tx_ptr = fake.spi.TXD.PTR.raw;

    fake.spi.EVENTS_END.raw = 1;
    try std.testing.expectError(error.IoError, adapter.datagram_device().write("new"));
    try std.testing.expectEqual(@as(usize, 1), fake.bus.spim_starts);
    try std.testing.expectEqual(tx_ptr, fake.spi.TXD.PTR.raw);
    try std.testing.expectEqual(stop_at, fake.bus.spim_stop_at);

    fake.spi.EVENTS_END.raw = 0;
    fake.spi.EVENTS_STOPPED.raw = 1;
    try std.testing.expectError(error.BusStuck, spi.deinit());
    try std.testing.expectEqual(.Enabled, fake.spi.ENABLE.read().ENABLE);
    fake.spi.EVENTS_END.raw = 1;
    try spi.deinit();
    try std.testing.expectEqual(.Disabled, fake.spi.ENABLE.read().ENABLE);
}

test "SPIM apply waits for recovery and writes PSEL with SPIM disabled" {
    const fake = serial_test;
    const sck = gpio.num(0, 5);
    var dst: [1]u8 = undefined;
    for ([_]u1{ 0, 1 }) |instance| {
        const spi = spim.num(instance);
        for ([_]fake.Mode{ .spim, .twim }) |mode| {
            fake.reset_instance(instance, mode);
            if (mode == .spim) {
                fake.bus.spim_complete_at = 300;
                fake.bus.spim_stops = false;
                try std.testing.expectError(error.BusStuck, spi.write_blocking("w", .from_us(100)));
                fake.spi.EVENTS_STOPPED.raw = 1;
            } else {
                fake.bus.twim_stops = false;
                try std.testing.expectError(error.BusStuck, i2cdma.num(instance).read_blocking(@fromBackingInt(0x42), &dst, .from_us(100)));
            }

            const enable = fake.spi.ENABLE.raw;
            const before_wait = fake.bus.now;
            const other = spim.num(instance ^ 1);
            try other.apply(.{ .sck_pin = sck });
            try other.deinit();
            try std.testing.expectEqual(before_wait, fake.bus.now);

            try std.testing.expectError(error.BusStuck, spi.apply(.{ .sck_pin = sck }));
            try std.testing.expect(fake.bus.now > before_wait);
            try std.testing.expectError(error.BusStuck, spi.deinit());
            try std.testing.expectEqual(enable, fake.spi.ENABLE.raw);
            try std.testing.expectEqual(@as(usize, 0), fake.bus.spim_pin_writes);

            if (mode == .spim) {
                fake.spi.EVENTS_END.raw = 1;
            } else {
                fake.twim.EVENTS_STOPPED.raw = 1;
            }
            try spi.apply(.{ .sck_pin = sck, .miso_pin = gpio.num(0, 6), .mosi_pin = gpio.num(0, 7) });
            try std.testing.expectEqual(@as(usize, 3), fake.bus.spim_pin_writes);
            try std.testing.expectEqual(@as(usize, 0), fake.bus.spim_pin_writes_enabled);
            try std.testing.expectEqual(sck.index(), fake.spi.PSEL.SCK.read().PIN);
            try std.testing.expectEqual(.Enabled, fake.spi.ENABLE.read().ENABLE);
            const after_apply = fake.bus.now;
            try expect_shared_dma_cleared();
            try spi.deinit();
            try std.testing.expectEqual(after_apply, fake.bus.now);
        }
    }
}

test "TWIM waits for STOPPED after a transfer timeout" {
    const fake = serial_test;
    const bus = i2cdma.num(0);
    const addr: i2cdma.Address = @fromBackingInt(0x42);
    fake.reset(.twim);
    var dst: [1]u8 = undefined;
    try std.testing.expectError(error.Timeout, bus.read_blocking(addr, &dst, .from_us(100)));
    try std.testing.expect(fake.bus.twim_stop_at != null);
    try std.testing.expectEqual(@as(u32, 1), fake.twim.EVENTS_STOPPED.raw);
    try std.testing.expectEqual(.Enabled, fake.twim.ENABLE.read().ENABLE);
}

test "TWIM checks the received count when STOPPED latches before a timeout abort" {
    const fake = serial_test;
    const bus = i2cdma.num(0);
    const addr: i2cdma.Address = @fromBackingInt(0x42);
    var dst: [2]u8 = undefined;

    for ([_]u16{ dst.len, dst.len - 1 }) |amount| {
        fake.reset(.twim);
        // The deadline poll reads STOPPED just before the shortcut latches it.
        fake.bus.twim_stop_after_read = .{ .at = 100 + fake.tick_us, .amount = amount };
        const result = bus.read_blocking(addr, &dst, .from_us(100));
        if (amount == dst.len) {
            try result;
        } else {
            try std.testing.expectError(error.Receive, result);
        }
        try std.testing.expectEqual(null, fake.bus.twim_stop_at);
        try std.testing.expectEqual(@as(u32, 0), fake.twim.RXD.PTR.raw);
    }
}

test "TWIM blocks retries and deinit until a late STOPPED releases DMA" {
    const fake = serial_test;
    const bus = i2cdma.num(0);
    const addr: i2cdma.Address = @fromBackingInt(0x42);
    var dst: [1]u8 = undefined;
    var next: [2]u8 = undefined;
    fake.reset(.twim);
    fake.bus.twim_stops = false;
    try std.testing.expectError(error.BusStuck, bus.read_blocking(addr, &dst, .from_us(100)));
    const stop_at = fake.bus.twim_stop_at;
    try std.testing.expect(stop_at != null);
    try std.testing.expectEqual(.Enabled, fake.twim.ENABLE.read().ENABLE);
    const rx_ptr = fake.twim.RXD.PTR.raw;
    try std.testing.expectError(error.BusStuck, bus.read_blocking(addr, &next, .from_us(100)));
    try std.testing.expectError(error.BusStuck, bus.deinit());
    try std.testing.expectEqual(.Enabled, fake.twim.ENABLE.read().ENABLE);
    try std.testing.expectEqual(@as(usize, 1), fake.bus.twim_starts);
    try std.testing.expectEqual(rx_ptr, fake.twim.RXD.PTR.raw);
    try std.testing.expectEqual(stop_at, fake.bus.twim_stop_at);

    fake.twim.EVENTS_STOPPED.raw = 1;
    fake.bus.twim_completion = .stopped;
    try bus.read_blocking(addr, &next, .from_us(100));
    try std.testing.expectEqual(@as(usize, 2), fake.bus.twim_starts);
    try bus.deinit();
    try std.testing.expectEqual(.Disabled, fake.twim.ENABLE.read().ENABLE);
}

test "TWIM resumes a suspended transfer before stopping on a bus error" {
    const fake = serial_test;
    const bus = i2cdma.num(0);
    const addr: i2cdma.Address = @fromBackingInt(0x42);
    fake.reset(.twim);
    fake.bus.twim_completion = .suspend_with_error;
    try std.testing.expectError(error.NoAcknowledge, bus.writev_blocking(addr, &.{ "w", "x" }, .from_us(100)));
    try std.testing.expectEqual(@as(usize, 1), fake.bus.twim_starts);
    try std.testing.expectEqual(@as(u32, 1), fake.twim.EVENTS_STOPPED.raw);
    try std.testing.expectEqual(.Enabled, fake.twim.ENABLE.read().ENABLE);
}

test "TWIM accepts STOPPED and SUSPENDED at the deadline" {
    const fake = serial_test;
    const bus = i2cdma.num(0);
    const addr: i2cdma.Address = @fromBackingInt(0x42);
    var dst: [1]u8 = undefined;
    fake.reset(.twim);
    fake.bus.twim_completion = .stopped;
    try bus.read_blocking(addr, &dst, .from_us(50));
    try std.testing.expectEqual(null, fake.bus.twim_stop_at);

    fake.reset(.twim);
    fake.bus.twim_completion = .suspend_then_stop;
    try bus.writev_blocking(addr, &.{ "w", "x" }, .from_us(50));
    try std.testing.expectEqual(@as(usize, 2), fake.bus.twim_starts);
    try std.testing.expectEqual(null, fake.bus.twim_stop_at);
}

test "TWI apply preserves shared instances with pending EasyDMA recovery" {
    try check_twi_mode_switch(.apply);
}

test "TWIM apply preserves shared instances with pending SPIM recovery" {
    const fake = serial_test;
    const scl_pin = gpio.num(0, 8);
    const sda_pin = gpio.num(0, 9);
    for ([_]u1{ 0, 1 }) |instance| {
        const twim = i2cdma.num(instance);
        const twi = i2c.num(instance);
        fake.reset_instance(instance, .spim);
        fake.bus.spim_complete_at = 300;
        fake.bus.spim_stops = false;
        try std.testing.expectError(error.BusStuck, spim.num(instance).write_blocking("w", .from_us(100)));
        fake.spi.EVENTS_STOPPED.raw = 1;
        const scl = fake.twim.PSEL.SCL.raw;
        const sda = fake.twim.PSEL.SDA.raw;
        const tx_count = fake.spi.TXD.MAXCNT.raw;
        const before_wait = fake.bus.now;
        try std.testing.expectError(error.BusStuck, twim.apply(.{ .scl_pin = scl_pin, .sda_pin = sda_pin }));
        try std.testing.expect(fake.bus.now > before_wait);
        try std.testing.expectError(error.BusStuck, twi.apply(.{ .scl_pin = scl_pin, .sda_pin = sda_pin }));
        try std.testing.expectError(error.BusStuck, twim.deinit());
        try std.testing.expectError(error.BusStuck, twi.deinit());
        const address: i2c.Address = @fromBackingInt(0x42);
        try std.testing.expectError(error.BusStuck, twim.write_blocking(address, "w", .from_us(100)));
        try std.testing.expectError(error.BusStuck, twi.write_blocking(address, "w", .from_us(100)));
        try std.testing.expectEqual(.Enabled, fake.spi.ENABLE.read().ENABLE);
        try std.testing.expectEqual(scl, fake.twim.PSEL.SCL.raw);
        try std.testing.expectEqual(sda, fake.twim.PSEL.SDA.raw);
        try std.testing.expectEqual(tx_count, fake.spi.TXD.MAXCNT.raw);

        fake.spi.EVENTS_END.raw = 1;
        try twim.apply(.{ .scl_pin = scl_pin, .sda_pin = sda_pin });
        try std.testing.expectEqual(.Enabled, fake.twim.ENABLE.read().ENABLE);
        try std.testing.expectEqual(scl_pin.index(), fake.twim.PSEL.SCL.read().PIN);
        try std.testing.expectEqual(sda_pin.index(), fake.twim.PSEL.SDA.read().PIN);
        const after_apply = fake.bus.now;
        try expect_shared_dma_cleared();
        try twim.deinit();
        try std.testing.expectEqual(after_apply, fake.bus.now);
    }
}

test "completed SPIM to TWIM handoff leaves no pending recovery" {
    const fake = serial_test;
    fake.reset(.spim);
    try spim.num(0).write_blocking("w", .from_us(100));
    try std.testing.expectEqual(@as(u32, 0), fake.spi.EVENTS_STOPPED.raw);

    const now = fake.bus.now;
    const twim = i2cdma.num(0);
    try twim.apply(.{ .scl_pin = gpio.num(0, 8), .sda_pin = gpio.num(0, 9) });
    try twim.wait_for_dma();
    try std.testing.expectEqual(now, fake.bus.now);
    try expect_shared_dma_cleared();
    try twim.deinit();
}

test "completed TWIM to SPIM handoff leaves no pending recovery" {
    const fake = serial_test;
    fake.reset(.twim);
    fake.bus.twim_completion = .stopped;
    var dst: [1]u8 = undefined;
    try i2cdma.num(0).read_blocking(@fromBackingInt(0x42), &dst, .from_us(100));

    const now = fake.bus.now;
    const spi = spim.num(0);
    try spi.apply(.{ .sck_pin = gpio.num(0, 5) });
    try spi.wait_for_dma();
    try std.testing.expectEqual(now, fake.bus.now);
    try expect_shared_dma_cleared();
    try spi.deinit();
}

fn expect_shared_dma_cleared() !void {
    const regs = serial_test.spi;
    try std.testing.expectEqual(@as(u32, 0), regs.RXD.PTR.raw);
    try std.testing.expectEqual(@as(u32, 0), regs.TXD.PTR.raw);
    try std.testing.expectEqual(@as(u32, 0), regs.RXD.MAXCNT.raw);
    try std.testing.expectEqual(@as(u32, 0), regs.TXD.MAXCNT.raw);
}

test "shared recovery ignores programmed DMA registers without BusStuck" {
    const fake = serial_test;
    for ([_]fake.Mode{ .spim, .twim }) |mode| {
        fake.reset(mode);
        fake.spi.TXD.PTR.raw = 0x2000_0000;
        fake.spi.TXD.MAXCNT.raw = 1;
        try wait_for_shared_dma(0);
        try std.testing.expectEqual(@as(u64, 0), fake.bus.now);
        try std.testing.expectEqual(@as(u32, 0x2000_0000), fake.spi.TXD.PTR.raw);
        try std.testing.expectEqual(@as(u32, 1), fake.spi.TXD.MAXCNT.raw);
    }
}

test "TWI reset preserves shared instances with pending EasyDMA recovery" {
    try check_twi_mode_switch(.reset);
}

fn check_twi_mode_switch(comptime action: enum { apply, reset }) !void {
    const fake = serial_test;
    const twi = i2c.num(0);
    const scl_pin = gpio.num(0, 8);
    const sda_pin = gpio.num(0, 9);
    var dst: [1]u8 = undefined;

    for ([_]fake.Mode{ .spim, .twim }) |mode| {
        fake.reset(mode);
        switch (mode) {
            .spim => {
                fake.bus.spim_complete_at = 300;
                fake.bus.spim_stops = false;
                try std.testing.expectError(error.BusStuck, spim.num(0).write_blocking("w", .from_us(100)));
                fake.spi.EVENTS_STOPPED.raw = 1;
            },
            .twim => {
                fake.bus.twim_stops = false;
                try std.testing.expectError(error.BusStuck, i2cdma.num(0).read_blocking(@fromBackingInt(0x42), &dst, .from_us(100)));
            },
            .twi => unreachable,
        }
        const enable = fake.twi.ENABLE.raw;
        const scl = fake.twi.PSEL.SCL.raw;
        const sda = fake.twi.PSEL.SDA.raw;

        switch (action) {
            .apply => try std.testing.expectError(error.BusStuck, twi.apply(.{ .scl_pin = scl_pin, .sda_pin = sda_pin })),
            .reset => twi.reset(),
        }
        try std.testing.expectEqual(enable, fake.twi.ENABLE.raw);
        try std.testing.expectEqual(scl, fake.twi.PSEL.SCL.raw);
        try std.testing.expectEqual(sda, fake.twi.PSEL.SDA.raw);

        switch (mode) {
            .spim => fake.spi.EVENTS_END.raw = 1,
            .twim => fake.twim.EVENTS_STOPPED.raw = 1,
            .twi => unreachable,
        }
        switch (action) {
            .apply => {
                try twi.apply(.{ .scl_pin = scl_pin, .sda_pin = sda_pin });
                try std.testing.expectEqual(.Enabled, fake.twi.ENABLE.read().ENABLE);
                try std.testing.expectEqual(scl_pin.index(), fake.twi.PSEL.SCL.read().PIN);
            },
            .reset => {
                twi.reset();
                try std.testing.expectEqual(.Disabled, fake.twi.ENABLE.read().ENABLE);
                try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fake.twi.PSEL.SCL.raw);
            },
        }
    }
}

test "hal tests" {
    _ = @import("usb_tests.zig");
    _ = clocks;
    _ = gpio;
    _ = i2c;
    _ = i2cdma;
    _ = spim;
    _ = time;
    _ = uart;
    _ = usbd;

    _ = drivers;
}
