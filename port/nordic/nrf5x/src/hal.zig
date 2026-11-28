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
