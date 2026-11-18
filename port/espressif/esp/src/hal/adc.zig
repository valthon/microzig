const impl = if (@import("builtin").is_test) @import("adc/esp32_c3.zig") else switch (@import("compatibility.zig").chip) {
    .esp32_c3 => @import("adc/esp32_c3.zig"),
    .esp32_c6 => @import("adc/esp32_c6.zig"),
};

pub const Channel = impl.Channel;
pub const Attenuation = impl.Attenuation;
pub const BitWidth = impl.BitWidth;
pub const Config = impl.Config;
pub const Sample = impl.Sample;
pub const Adc1 = impl.Adc1;

test {
    _ = impl;
    _ = @import("adc/calibration_c6.zig");
}
