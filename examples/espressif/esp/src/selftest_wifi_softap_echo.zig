//! W4: flash softap on the other C3/C6, start it before this station.
//! Both images use identical -Dsoftap_ssid/-Dsoftap_password (demo defaults work).
//! Joins, gets DHCP, connects to 192.168.4.1:7, checks 10 binary payloads.
//! Expected: SELFTEST wifi_softap_echo DONE pass=13 fail=0 (start, join, DHCP, 10 echoes).
//! Swap C3/C6 roles and repeat; no PC on the AP is needed.
//! Ran 3/3 per AP/station pair (C3, Super Mini, XIAO; see the README). Results repeat every 3 s.
const microzig = @import("microzig");
const checks = @import("selftest_wifi_checks.zig");
pub const mode: checks.Mode = .softap_echo;
pub const panic = checks.panic;
pub const std_options = checks.std_options;
pub const microzig_options = checks.microzig_options;
comptime {
    _ = microzig.export_startup();
}
pub fn main() void {
    checks.run();
}
