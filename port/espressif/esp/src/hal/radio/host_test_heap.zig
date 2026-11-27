//! Host tests share one radio heap for the process, as the radios of one
//! boot do. Each test that initializes a radio attaches it first; the first
//! call attaches. Host-test code only: test blocks, and the wifi.zig helpers
//! (`EventLog.install`, `start_for_stop_panic`) that only tests call.
const radio = @import("../radio.zig");

pub var buffer: [16384]u8 align(16) = undefined;
pub var heap: radio.SharedHeap = undefined;

pub fn attach() void {
    if (@import("shared_heap.zig").allocator()) |_| return else |_| {}
    heap = radio.SharedHeap.init(&buffer) catch unreachable;
    radio.attach_shared_heap(&heap) catch unreachable;
}
