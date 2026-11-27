//! The one allocator route of a coexistence image: a pointer to the
//! application's `SharedHeap`, written once by `radio.attach_shared_heap`.
//!
//! The blobs call `malloc(size_t)` and `free(void *)` by symbol, and the
//! adapter table's `void *(*_malloc)(size_t size)` and `void (*_free)(void *p)`
//! (esp-wifi-sys `c/include/esp_private/wifi_os_adapter.h:73-74`) carry no
//! context argument, so the OSI callbacks in `osi.zig` cannot be handed an
//! allocator. They read this pointer through `osi.callback_allocator()`, as
//! does the Zig code that frees what the blobs allocated (the PP task, the
//! eloop reservation, the radio timer worker and its nodes). Port code
//! reaches it through this file, which `hal.radio` does not export.
const std = @import("std");
const Allocator = std.mem.Allocator;
const microzig = @import("microzig");
const host_test = @import("callback_context.zig").host_test;

pub const SharedHeap = struct {
    heap: microzig.Allocator,

    pub fn init(buffer: []u8) microzig.Allocator.Error!SharedHeap {
        return .{ .heap = try .init_with_buffer(buffer) };
    }
};

// Null until the attach; never changed after it.
var attached: std.atomic.Value(?*SharedHeap) = .init(null);

// Host tests only (`TestRoute`): an allocator that takes the route's place.
var test_override: if (host_test) ?Allocator else void = if (host_test) null else {};

fn route() ?Allocator {
    if (host_test) if (test_override) |test_allocator| return test_allocator;
    const heap = attached.load(.acquire) orelse return null;
    return heap.heap.allocator();
}

/// The caller holds the radio init lock.
pub fn attach(heap: *SharedHeap) error{SharedHeapAlreadyAttached}!void {
    if (attached.load(.acquire) != null) return error.SharedHeapAlreadyAttached;
    attached.store(heap, .release);
}

/// The attached heap's allocator, for radio init.
pub fn allocator() error{SharedHeapNotAttached}!Allocator {
    return route() orelse error.SharedHeapNotAttached;
}

/// The allocator `osi.callback_allocator()` returns: the attached heap's, or
/// `Allocator.failing` before the attach, so a callback cannot reach
/// storage nobody owns.
pub fn callback_allocator() Allocator {
    return route() orelse .failing;
}

/// Host tests: point the attached heap at `heap` (null detaches it) and
/// return the previous heap for the test to restore. An installed
/// `TestRoute` takes precedence over the attached heap, so while one is
/// installed the swap does not change where allocations go.
pub fn swap_for_test(heap: ?*SharedHeap) ?*SharedHeap {
    comptime std.debug.assert(host_test);
    return attached.swap(heap, .acq_rel);
}

/// Host tests: the heap the route points at.
pub fn attached_for_test() ?*SharedHeap {
    comptime std.debug.assert(host_test);
    return attached.load(.acquire);
}

/// Host tests: route every allocation that reads this route (radio init and
/// the callbacks) to the allocator `install` is given, until `restore`.
pub const TestRoute = struct {
    previous: ?Allocator = null,

    pub fn install(self: *TestRoute, test_allocator: Allocator) void {
        comptime std.debug.assert(host_test);
        self.previous = test_override;
        test_override = test_allocator;
    }

    /// Route to another allocator without restoring in between.
    pub fn reroute(_: *TestRoute, test_allocator: Allocator) void {
        test_override = test_allocator;
    }

    pub fn restore(self: *TestRoute) void {
        test_override = self.previous;
    }
};
