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

test "reselecting the active USB configuration invalidates the previous CDC lifetime" {
    try @import("hal/usbd.zig").testing.configuration_reselection();
}

test "clearing a Nordic OUT halt resets DATA0 and releases only an empty stalled slot" {
    try @import("hal/usbd.zig").testing.halt_out_clear();
}

test "clearing a Nordic IN halt resets DATA0 before clearing EPSTALL" {
    try @import("hal/usbd.zig").testing.halt_in_clear();
}

test "Nordic halt wakes the peripheral before writing EPSTALL" {
    try @import("hal/usbd.zig").testing.halt_wake();
}

test "Nordic halt wake timeout leaves the Halt bit clear and does not write EPSTALL" {
    try @import("hal/usbd.zig").testing.halt_wake_timeout();
}

test "Nordic reset, close and detach retire endpoint halts" {
    try @import("hal/usbd.zig").testing.halt_retirement();
}
