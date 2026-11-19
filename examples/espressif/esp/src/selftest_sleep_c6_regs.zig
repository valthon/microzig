//! Built only. No wiring. Never requests sleep or hands regulators to PMU.
//! Prints hardware reads and IDF v5.5.1 init/light/deep/XTAL-off light plans.
//! default_* phases compare fixed inputs directly to independent literal IDF
//! fixtures; later phases use the measured clocks and hardware eFuse biases.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const sleep = hal.clocks.sleep;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = hal.usb_serial_jtag.logger.log });
comptime {
    microzig.export_startup();
}
var pass: usize = 0;
var fail: usize = 0;
fn print_register(r: sleep.RegisterProbe) void {
    const ok = r.would_write == r.idf_expected;
    if (ok) pass += 1 else fail += 1;
    std.log.info("SELFTEST sleep_c6_regs {s}/{s}: {s} addr=0x{x:0>8} current=0x{x:0>8} would=0x{x:0>8} idf=0x{x:0>8} mask=0x{x:0>8}", .{
        r.phase, r.name, if (ok) @as([]const u8, "PASS") else "FAIL", r.address, r.current, r.would_write, r.idf_expected, r.mask,
    });
}
pub fn main() void {
    hal.time.sleep_ms(1500);
    while (true) {
        pass = 0;
        fail = 0;
        sleep.probe_registers(print_register) catch |err| {
            fail += 1;
            std.log.info("SELFTEST sleep_c6_regs calibration: FAIL error={s}", .{@errorName(err)});
        };
        std.log.info("SELFTEST sleep_c6_regs DONE pass={} fail={}", .{ pass, fail });
        hal.time.sleep_ms(3000);
    }
}
