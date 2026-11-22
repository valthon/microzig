//! Open-AP authentication rejection: open AP matching -Dwifi_ssid; no protected AP with that SSID in range.
//! Supply -Dwifi_auth=wpa2_personal and a test -Dwifi_password (8+ bytes).
//! Default unprotected builds report FAIL, never a false rejection PASS.
//! Expected: SELFTEST wifi_open_ap DONE pass=3 fail=0 (start, scan, rejection).
//! Results repeat every 3 s.
const microzig = @import("microzig");
const checks = @import("selftest_wifi_checks.zig");
pub const mode: checks.Mode = .open_ap;
pub const panic = checks.panic;
pub const std_options = checks.std_options;
pub const microzig_options = checks.microzig_options;
comptime {
    _ = microzig.export_startup();
}
pub fn main() void {
    checks.run();
}
