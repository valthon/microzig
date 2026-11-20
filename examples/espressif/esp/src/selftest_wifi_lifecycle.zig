//! N2/N4 regression exercise, followed by the ordinary DHCP/TCP echo server.
//! Use -Dwifi_ssid/-Dwifi_password/-Dwifi_auth; no external wiring is required.
//! Peer: matching station AP with DHCP; expected wifi_lifecycle DONE pass=8 fail=0.
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
