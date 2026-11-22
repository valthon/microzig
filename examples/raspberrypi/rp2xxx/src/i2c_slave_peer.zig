//! Pico 2 W (RP2350 ARM) register-file peer for ESP selftest_i2c, address 0x42.
//! SDA GP4 (physical pin 6) -> ESP C3 / Super Mini ESP32-C6 GPIO5;
//! SCL GP5 (physical pin 7) -> ESP GPIO6; common GND (e.g. Pico pin 8).
//! XIAO ESP32-C6 instead uses SDA D4/GPIO22, SCL D5/GPIO23 (its board pin map).
//! Internal pull-ups on GP4/GP5 (with the ESP side's); external 4.7 kohm
//! pull-ups to 3.3 V are recommended for longer wires or faster clocks.
//! Start this peer first, then the ESP. ESP expected DONE pass=8 fail=0.
//! Ran from RAM on a Pico 2 W against an ESP32-C6 Super Mini (port/espressif/
//! esp/README.md). Peer itself has no SELFTEST pass count.
//!
//! Write: first byte selects an 8-bit register, subsequent bytes write and
//! increment it, wrapping at 256. Read: return and increment selected register.
//! STOP retains the pointer; a new write (including repeated START) replaces it.
//! 0x00..0xef, 0xf4..0xff: RAM; read-only 0xf0: delayed 0xa5, 0xf1: stretch
//! capability (1), 0xf2: immediate 0xa5, 0xf3: protocol version (1).
//! RP2350 Datasheet section 12.2.10.1.2: RD_REQ holds SCL low until software
//! supplies data; polling RAW_INTR_STAT is supported. We defer service by 20 us
//! for 0xf0 in the main loop, then use the HAL slave handler and callbacks.
const microzig = @import("microzig");
const hal = microzig.hal;
const regs = microzig.chip.peripherals.I2C0;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});
comptime {
    microzig.export_startup();
}

// The HAL enables the IRQ in open(); mask it before leaving the critical
// section. Main alone services the HAL, owns RAM and pointer, and delays reads.
pub const microzig_options: microzig.Options = .{
    .interrupts = .{ .I2C0_IRQ = .{ .c = hal.i2c.slave.isr0 } },
};
var transfer_buffer: [32]u8 = undefined;
var registers: [256]u8 = @splat(0);
var pointer: u8 = 0;

pub fn main() void {
    const pins = hal.pins.GlobalConfiguration{
        .GPIO4 = .{ .function = .I2C0_SDA, .slew_rate = .slow, .pull = .up },
        .GPIO5 = .{ .function = .I2C0_SCL, .slew_rate = .slow, .pull = .up },
    };
    _ = pins.apply();
    {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        hal.i2c.slave.i2c0.open(@fromBackingInt(0x42), &transfer_buffer, receive, transmit, null);
        microzig.cpu.interrupt.disable(.I2C0_IRQ);
    }
    while (true) {
        if (regs.IC_INTR_STAT.raw == 0) continue;
        if (regs.IC_RAW_INTR_STAT.read().RD_REQ == .ACTIVE and pointer == 0xf0)
            hal.time.sleep_us(20);
        hal.i2c.slave.isr0();
    }
}

fn receive(data: []const u8, first: bool, last: bool, general_call: bool, param: ?*anyopaque) void {
    _ = last;
    _ = param;
    if (general_call or data.len == 0) return;
    var payload = data;
    if (first) {
        pointer = data[0];
        payload = data[1..];
    }
    for (payload) |byte| {
        if (pointer < 0xf0 or pointer > 0xf3) registers[pointer] = byte;
        pointer +%= 1;
    }
}

fn transmit(data: []u8, first: bool, param: ?*anyopaque) usize {
    _ = first;
    _ = param;
    data[0] = switch (pointer) {
        0xf0, 0xf2 => 0xa5,
        0xf1, 0xf3 => 1,
        else => registers[pointer],
    };
    pointer +%= 1;
    // Supply exactly one byte per RD_REQ so unconsumed FIFO prefetch does not
    // advance the register pointer beyond what the master actually requested.
    return 1;
}
