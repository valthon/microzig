test "USBFS EP0 discards retransmitted OUT without advancing state" {
    try @import("hals/usbfs.zig").Polled(.{}, .{}).testing.duplicate_out();
}

test "USBHS EP0 discards retransmitted OUT without advancing state" {
    try @import("hals/usbhs.zig").Polled(.{}, .{}).testing.duplicate_out();
}
