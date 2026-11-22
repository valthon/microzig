//! Protocol v1 of i2c_slave_peer.zig; RP2350 DS §12.2.10.1.2 RD_REQ.
//! Main-loop ownership: the I2C1 IRQ remains masked.
const microzig = @import("microzig");
const hal = microzig.hal;
const regs = microzig.chip.peripherals.I2C1;
var buffer: [32]u8 = undefined;
var ram: [256]u8 = @splat(0);
var pointer: u8 = 0;
pub var bytes: u64 = 0;
pub var frames: u64 = 0;
pub fn open() void {
    ram = @splat(0);
    pointer = 0;
    bytes = 0;
    frames = 0;
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    hal.i2c.slave.i2c1.open(@fromBackingInt(0x42), &buffer, receive, transmit, null);
    microzig.cpu.interrupt.disable(.I2C1_IRQ);
}
pub fn close() void {
    hal.i2c.slave.i2c1.close();
}
pub fn poll() void {
    if (regs.IC_INTR_STAT.raw == 0) return;
    if (regs.IC_RAW_INTR_STAT.read().RD_REQ == .ACTIVE and pointer == 0xf0) hal.time.sleep_us(20);
    hal.i2c.slave.isr1();
}
fn receive(data: []const u8, first: bool, last: bool, general: bool, param: ?*anyopaque) void {
    _ = last;
    _ = param;
    if (general or data.len == 0) return;
    var payload = data;
    if (first) {
        frames += 1;
        pointer = data[0];
        payload = data[1..];
    }
    bytes += data.len;
    for (payload) |byte| {
        if (pointer < 0xf0 or pointer > 0xf3) ram[pointer] = byte;
        pointer +%= 1;
    }
}
fn transmit(data: []u8, first: bool, param: ?*anyopaque) usize {
    _ = param;
    if (first) frames += 1;
    data[0] = switch (pointer) {
        0xf0, 0xf2 => 0xa5,
        0xf1, 0xf3 => 1,
        else => ram[pointer],
    };
    pointer +%= 1;
    bytes += 1;
    return 1;
}
