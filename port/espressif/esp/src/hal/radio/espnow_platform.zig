//! Target dependencies, separated so the session contract can run on the host.
pub const microzig = @import("microzig");
pub const c = @import("esp-wifi-driver");
pub const wifi = @import("wifi.zig");

pub fn lifecycle_busy() bool {
    return @import("../radio.zig").coex_enabled and @import("callback_context.zig").active();
}
