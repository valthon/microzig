const c = @import("lwip").c;
const rtos = @import("microzig").hal.rtos;

extern fn lwip_assert_core_locked() void;

test {
    _ = @import("lwip/exports.zig");
}

test "lwIP core lock assertion rejects an unlocked mutex" {
    var mutex: rtos.Mutex = .{};
    c.lock_tcpip_core = &mutex;
    defer c.lock_tcpip_core = null;
    lwip_assert_core_locked();
}

test "lwIP core lock assertion rejects another task's lock" {
    var other_task: u8 = 0;
    var mutex: rtos.Mutex = .{ .locked = &other_task };
    c.lock_tcpip_core = &mutex;
    defer c.lock_tcpip_core = null;
    lwip_assert_core_locked();
}

test "lwIP core lock assertion rejects ISR context" {
    var mutex: rtos.Mutex = .{ .locked = rtos.get_current_task() };
    c.lock_tcpip_core = &mutex;
    defer c.lock_tcpip_core = null;
    rtos.interrupt_context = true;
    defer rtos.interrupt_context = false;
    lwip_assert_core_locked();
}
