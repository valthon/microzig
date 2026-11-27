//! Line framing and bounded USB writes for the CDC examples.
const std = @import("std");
const microzig = @import("microzig");
const nrf = microzig.hal;
const time = nrf.time;
const CDC = microzig.core.usb.drivers.CDC;

pub const Lines = struct {
    pub const capacity = 1024;
    buffer: [capacity]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,
    configuration_generation: u32 = 0,

    /// Accept CR, LF or CRLF. Ignore empty lines and drop oversized lines in full.
    /// The returned line is borrowed until the next byte is pushed.
    pub fn push(self: *Lines, byte: u8) ?[]const u8 {
        switch (byte) {
            '\r', '\n' => {
                defer self.clear();
                return if (self.len == 0 or self.overflow) null else self.buffer[0..self.len];
            },
            else => {
                if (self.len == self.buffer.len) {
                    self.overflow = true;
                } else {
                    self.buffer[self.len] = byte;
                    self.len += 1;
                }
                return null;
            },
        }
    }

    pub fn sync_configuration(self: *Lines, generation: u32) void {
        if (self.configuration_generation != generation) {
            self.clear();
            self.configuration_generation = generation;
        }
    }

    pub fn clear(self: *Lines) void {
        self.len = 0;
        self.overflow = false;
    }
};

pub fn poll(device: *nrf.usbd.USBD, controller: anytype) void {
    device.poll(controller);
    // USBD can tear down on VBUS loss without notifying the controller. The
    // CDC-only controller owns fixed storage, so drop its old configuration.
    // A new connection must enumerate before the watchdog is fed again.
    if (!device.is_connected() and controller.drivers() != null)
        controller.* = .init;
}

/// Borrow this runtime only until the next poll.
pub fn serial(device: *const nrf.usbd.USBD, controller: anytype) ?*CDC.Runtime {
    if (!device.is_connected()) return null;
    const drivers = controller.drivers() orelse return null;
    return &drivers.serial;
}

/// Stop after 100 ms without accepting any new bytes.
/// Returns false if the USB connection or configuration changed.
pub fn write_all(device: *nrf.usbd.USBD, controller: anytype, bytes: []const u8) bool {
    const generation = device.get_configuration_generation();
    var last_progress = time.get_time_since_boot().to_us();
    var rest = bytes;
    while (device.get_configuration_generation() == generation) {
        const cdc = serial(device, controller) orelse return false;
        const accepted = cdc.write(rest);
        rest = rest[accepted..];
        if (!device.is_connected()) return false;
        if (rest.len == 0 and cdc.flush()) return device.is_connected();
        const now = time.get_time_since_boot().to_us();
        if (accepted != 0) {
            last_progress = now;
        } else if (now - last_progress >= 100_000) {
            return true;
        }
        poll(device, controller);
    }
    return false;
}

test "CDC lines span reads and handle batched commands and CRLF" {
    var lines: Lines = .{};
    for ("u") |byte| try std.testing.expect(lines.push(byte) == null);
    var count: usize = 0;
    const expected = [_][]const u8{ "uf2", "dog", "soft" };
    for ("f2\r\ndog\nsoft\r") |byte| {
        if (lines.push(byte)) |line| {
            try std.testing.expect(count < expected.len);
            try std.testing.expectEqualStrings(expected[count], line);
            count += 1;
        }
    }
    try std.testing.expectEqual(expected.len, count);
}

test "CDC drops an oversized line and clears partial input at disconnect" {
    var lines: Lines = .{};
    for (0..Lines.capacity + 1) |_| try std.testing.expect(lines.push('x') == null);
    for ("uf2\n") |byte| try std.testing.expect(lines.push(byte) == null);
    try std.testing.expect(lines.push('x') == null);
    lines.clear();
    for ("uf2") |byte| try std.testing.expect(lines.push(byte) == null);
    try std.testing.expectEqualStrings("uf2", lines.push('\n').?);
}

test "CDC command fragments cannot cross a configuration change" {
    var lines: Lines = .{};
    lines.sync_configuration(1);
    try std.testing.expect(lines.push('u') == null);
    lines.sync_configuration(2);
    for ("f2") |byte| try std.testing.expect(lines.push(byte) == null);
    try std.testing.expectEqualStrings("f2", lines.push('\n').?);
}
