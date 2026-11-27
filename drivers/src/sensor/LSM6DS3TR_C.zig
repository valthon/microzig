//! ST LSM6DS3TR-C over I²C (datasheet DocID030071 Rev 3).
const std = @import("std");
const I2C_Device = @import("../base/I2C_Device.zig");

pub const LSM6DS3TR_C = struct {
    bus: I2C_Device,
    address: I2C_Device.Address,

    // Datasheet §9.12 and §4.1 Table 3.
    pub const device_id = 0x6a;
    pub const accel_mg_per_lsb = 0.061;
    pub const gyro_mdps_per_lsb = 8.75;

    pub const Sample = struct {
        /// X, Y, Z raw acceleration counts at ±2 g.
        accel: [3]i16,
        /// X, Y, Z raw angular-rate counts at ±250 degrees/s.
        gyro: [3]i16,
    };

    pub fn who_am_i(dev: LSM6DS3TR_C) I2C_Device.InterfaceError!u8 {
        var id: [1]u8 = undefined;
        try dev.bus.write_then_read(dev.address, &.{0x0f}, &id);
        return id[0];
    }

    /// Configure after power-on or reset, when IF_INC is set by default.
    /// Probe WHO_AM_I first and wait for the sensors to settle after setup.
    pub fn configure(dev: LSM6DS3TR_C) I2C_Device.InterfaceError!void {
        // Datasheet §9.13–9.15: CTRL1_XL and CTRL2_G at 104 Hz and default
        // ranges, followed by CTRL3_C with BDU and IF_INC for a coherent burst.
        try dev.bus.write(dev.address, &.{ 0x10, 0x40, 0x40, 0x44 });
    }

    pub fn data_ready(dev: LSM6DS3TR_C) I2C_Device.InterfaceError!bool {
        // Datasheet §9.27: STATUS_REG.GDA and XLDA.
        var status: [1]u8 = undefined;
        try dev.bus.write_then_read(dev.address, &.{0x1e}, &status);
        return status[0] & 0b11 == 0b11;
    }

    pub fn read_sample(dev: LSM6DS3TR_C) I2C_Device.InterfaceError!Sample {
        // Datasheet §9.29–9.40: signed little-endian gyro, then accel.
        var data: [12]u8 = undefined;
        try dev.bus.write_then_read(dev.address, &.{0x22}, &data);
        var sample: Sample = undefined;
        inline for (0..3) |axis| {
            sample.gyro[axis] = std.mem.readInt(i16, data[2 * axis ..][0..2], .little);
            sample.accel[axis] = std.mem.readInt(i16, data[6 + 2 * axis ..][0..2], .little);
        }
        return sample;
    }
};

test "LSM6DS3TR-C register commands and signed axis order" {
    var test_bus = I2C_Device.TestDevice.init(&.{
        &.{0x6a},
        &.{0x03},
        &.{ 0x34, 0x12, 0xfe, 0xff, 0x00, 0x80, 0x42, 0x00, 0x00, 0x40, 0xff, 0x7f },
    }, true);
    defer test_bus.deinit();
    const dev: LSM6DS3TR_C = .{ .bus = test_bus.i2c_device(), .address = @fromBackingInt(0x6a) };

    try std.testing.expectEqual(LSM6DS3TR_C.device_id, try dev.who_am_i());
    try dev.configure();
    try std.testing.expect(try dev.data_ready());
    const sample = try dev.read_sample();
    try std.testing.expectEqual([3]i16{ 0x1234, -2, -32768 }, sample.gyro);
    try std.testing.expectEqual([3]i16{ 0x42, 0x4000, 32767 }, sample.accel);
    try test_bus.expect_sent(&.{ &.{0x0f}, &.{ 0x10, 0x40, 0x40, 0x44 }, &.{0x1e}, &.{0x22} });
}
