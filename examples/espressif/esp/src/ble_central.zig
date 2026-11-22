//! ESP32-C6 bench example; on a XIAO ESP32C6 use the xiao_esp32_c6 build.
//! Evidence per build: port README, "BLE bench examples".
//! At most 3 connection attempts, 250 ms apart, only for establishment failure
//! 0x3e (including a disconnect during initial discovery). Bluetooth Core v6.0,
//! Vol 1 Part F §2.59 defines 0x3e; Vol 6 Part B §4.5.2 covers supervision timeout
//! before establishment. Other errors fail immediately; all 13 checks must pass.
//! ATT waits use the Core 30 s transaction timeout. Success and failure close
//! the link and allow peer supervision to expire before DONE; capture until DONE.
const microzig = @import("microzig");
const bench = @import("ble_bench.zig");
pub const panic = bench.panic;
pub const init = bench.init;
pub const std_options = bench.std_options;
pub const microzig_options = bench.microzig_options;
comptime {
    _ = microzig.export_startup();
}
pub fn main() !void {
    try bench.run(.central);
}
