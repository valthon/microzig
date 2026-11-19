//! ESP32-C6 bench example; on a XIAO ESP32C6 use the xiao_esp32_c6 build.
//! Evidence per build: port README, "BLE bench examples".
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
    try bench.run(.scan);
}
