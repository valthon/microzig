const impl = if (@import("builtin").is_test) @import("temperature/esp32_c3.zig") else switch (@import("compatibility.zig").chip) {
    .esp32_c3 => @import("temperature/esp32_c3.zig"),
    .esp32_c6 => @import("temperature/esp32_c6.zig"),
};

pub const init = impl.init;
pub const read_celsius = impl.read_celsius;

test {
    _ = impl;
}
