//! Build with -Dexample=selftest_usj_reenumerate and run on an ESP32-C3 or C6.
//! Open USB Serial/JTAG, start capturing output, and send a newline (repeat
//! it until START arrives; bytes already in the receive FIFO at boot are
//! discarded).
//! After each detach, reopen the port promptly and continue the same
//! capture. Replay starts once the logger sees the committed IN buffer drain
//! and the settle delay elapses. Pass when SEQ 1 through the seq value in
//! SELFTEST usj_reenumerate DONE arrive in order with no gaps or loss reports
//! after START. DONE repeats so the host can always check the final number.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const usj = hal.usb_serial_jtag;
const Deadline = microzig.drivers.time.Deadline;

pub const panic = microzig.panic;
pub const microzig_options: microzig.Options = .{
    // A reopen about 2.2 s late queues roughly 110 lines of about 30 bytes,
    // exceeding the default 2 KiB queue.
    .hal = .{ .usb_serial_jtag_log_hold_size = 4096 },
};
pub const std_options = microzig.std_options(.{
    .logFn = usj.logger.log,
    .log_level = .info,
});
comptime {
    _ = microzig.export_startup();
}

pub fn main() void {
    // The port can survive the reset that started this image (the CDC RTS
    // reset does not re-enumerate), so bytes sent to the previous image may
    // still be in the receive FIFO. Discard what is there at boot.
    var stale: [64]u8 = undefined;
    while (usj.read(&stale) != 0) {}

    var byte: [1]u8 = undefined;
    while (true) {
        const n = usj.read_blocking(&byte, Deadline.init_relative(hal.time.get_time_since_boot(), .from_ms(500))) catch continue;
        if (n != 0 and byte[0] == '\n') break;
    }

    std.log.info("SELFTEST usj_reenumerate START", .{});
    const cycles = 12;
    var seq: u32 = 0;
    for (0..cycles) |cycle| {
        if (cycle != 0) {
            // Give the host time to read: on the bench, lines logged just
            // before a detach were sometimes missing from the capture.
            hal.time.sleep_ms(200);
            _ = usj.reconnect(.{});
        }
        for (0..125) |_| {
            seq += 1;
            std.log.info("SEQ {d}", .{seq});
            hal.time.sleep_ms(20);
        }
    }
    while (true) {
        std.log.info("SELFTEST usj_reenumerate DONE seq={d}", .{seq});
        hal.time.sleep_ms(1000);
    }
}
