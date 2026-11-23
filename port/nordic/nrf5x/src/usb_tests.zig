test "init masks and clears a bootloader's USBD interrupt before late OUT listen" {
    try @import("hal/usbd.zig").testing.init_interrupt();
}

test "late OUT listen pends the previously enabled USBD interrupt" {
    try @import("hal/usbd.zig").testing.late_listen();
}

test "failed wake prevents OUT and IN DMA without quarantine" {
    try @import("hal/usbd.zig").testing.wake_timeout();
}

test "host activity exits low power before reset or setup processing" {
    try @import("hal/usbd.zig").testing.host_activity();
}

test "ISR poll leaves control OUT DMA for foreground" {
    try @import("hal/usbd.zig").testing.foreground_poll();
}

test "CDC reads notified OUT across suspend without a successful wake" {
    try @import("hal/usbd.zig").testing.cdc_out_suspend();
}

test "CDC IN survives wake timeout and completes after host resume" {
    try @import("hal/usbd.zig").testing.cdc_in_wake_timeout();
}
