//! ESP32-C6 LP domain HAL. HP clocks, ROM calls and watchdog init do not run here.
pub const lp_core = @import("hal/lp_core.zig");

pub const lp_io = @import("hal/lp_io.zig");

pub const lp_timer = @import("hal/lp_timer.zig");

pub const lp_uart = @import("hal/lp_uart.zig");

pub const lp_i2c = @import("hal/lp_i2c.zig");
