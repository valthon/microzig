//! N2/N4 regression exercise, followed by the ordinary DHCP/TCP echo server.
//! Edit the NOTE credentials in tcp_server.zig; no external wiring is required.
const microzig = @import("microzig");
const server = @import("tcp_server.zig");

pub const panic = server.panic;
pub const std_options = server.std_options;
pub const microzig_options = server.microzig_options;

comptime {
    _ = microzig.export_startup();
}

pub fn main() !void {
    try server.run(true);
}
