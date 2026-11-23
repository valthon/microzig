//! Host-driven RX/TX check. Send LF or CRLF terminated lines, including empty
//! lines and lines spanning multiple 64-byte USB packets. Replies are unprefixed:
//! ECHO <decimal payload length> <eight lowercase hex digits of CRC-32/ISO-HDLC>.
//! The line terminator is excluded from both length and CRC; no line buffer limit.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const usj = hal.usb_serial_jtag;
const Deadline = microzig.drivers.time.Deadline;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = usj.logger.log,
    .log_level = .info,
});

comptime {
    _ = microzig.export_startup();
}

pub fn main() void {
    var crc = std.hash.Crc32.init();
    var len: usize = 0;
    var pending_cr = false;
    var received_line = false;
    var ready_at = Deadline.init_relative(hal.time.get_time_since_boot(), .from_ms(0));
    while (true) {
        if (!received_line and ready_at.is_reached_by(hal.time.get_time_since_boot())) {
            std.log.info("SELFTEST usj ready", .{});
            ready_at = Deadline.init_relative(hal.time.get_time_since_boot(), .from_ms(1000));
        }
        var byte: [1]u8 = undefined;
        _ = usj.read_blocking(&byte, ready_at) catch continue;
        if (byte[0] == '\n') {
            received_line = true;
            var response: [64]u8 = undefined;
            const line = std.mem.print(&response, "ECHO {d} {x:0>8}\r\n", .{ len, crc.final() }) catch unreachable;
            // A closed host must not stall RX forever. A timeout can mean partial TX.
            _ = usj.write_blocking(line, Deadline.init_relative(hal.time.get_time_since_boot(), .from_ms(1000))) catch {};
            crc = std.hash.Crc32.init();
            len = 0;
            pending_cr = false;
            ready_at = .init_relative(hal.time.get_time_since_boot(), null);
        } else {
            if (pending_cr) {
                crc.update("\r");
                len += 1;
            }
            pending_cr = byte[0] == '\r';
            if (!pending_cr) {
                crc.update(&byte);
                len += 1;
            }
        }
    }
}
