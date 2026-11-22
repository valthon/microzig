//! TX completion callbacks: AP matching -Dwifi_ssid/-Dwifi_password/-Dwifi_auth, no IP peer needed.
//! Sends 10 tagged Ethernet frames and requires a successful TX-done for each.
//! Expected: SELFTEST wifi_tx_done DONE pass=3 fail=0 (start, join, callbacks).
//! Results repeat every 3 s.
const microzig = @import("microzig");
const checks = @import("selftest_wifi_checks.zig");
pub const mode: checks.Mode = .tx_done;
pub const panic = checks.panic;
pub const std_options = checks.std_options;
pub const microzig_options = checks.microzig_options;
comptime {
    _ = microzig.export_startup();
}
pub fn main() void {
    checks.run();
}
