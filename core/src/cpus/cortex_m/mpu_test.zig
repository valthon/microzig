const std = @import("std");

test "stack guard MPU register layouts" {
    // Arm DDI0419C B3.5.3-B3.5.7 and DDI0403E.e B3.5.5-B3.5.9.
    inline for (.{ @import("m0plus.zig"), @import("m3.zig"), @import("m4.zig"), @import("m7.zig") }) |core| {
        const Mpu = core.MemoryProtectionUnit;
        try std.testing.expectEqual(0, @offsetOf(Mpu, "TYPE"));
        try std.testing.expectEqual(4, @offsetOf(Mpu, "CTRL"));
        try std.testing.expectEqual(8, @offsetOf(Mpu, "RNR"));
        try std.testing.expectEqual(12, @offsetOf(Mpu, "RBAR"));
        try std.testing.expectEqual(16, @offsetOf(Mpu, "RASR"));

        const mpu: Mpu = undefined;
        const Type = @TypeOf(mpu.TYPE).underlying_type;
        const Ctrl = @TypeOf(mpu.CTRL).underlying_type;
        const Rnr = @TypeOf(mpu.RNR).underlying_type;
        const Rbar = @TypeOf(mpu.RBAR).underlying_type;
        const Rasr = @TypeOf(mpu.RASR).underlying_type;
        try std.testing.expectEqual(8, @bitOffsetOf(Type, "DREGION"));
        try std.testing.expectEqual(0, @bitOffsetOf(Ctrl, "ENABLE"));
        try std.testing.expectEqual(1, @bitOffsetOf(Ctrl, "HFNMIENA"));
        try std.testing.expectEqual(2, @bitOffsetOf(Ctrl, "PRIVDEFENA"));
        try std.testing.expectEqual(0, @bitOffsetOf(Rnr, "REGION"));
        try std.testing.expectEqual(4, @bitOffsetOf(Rbar, "VALID"));
        try std.testing.expectEqual(5, @bitOffsetOf(Rbar, "ADDR"));
        try std.testing.expectEqual(32, @bitSizeOf(Rasr));
        try std.testing.expectEqual(0, @bitOffsetOf(Rasr, "ENABLE"));
        try std.testing.expectEqual(1, @bitOffsetOf(Rasr, "SIZE"));
        try std.testing.expectEqual(8, @bitOffsetOf(Rasr, "SRD"));
        try std.testing.expectEqual(16, @bitOffsetOf(Rasr, "B"));
        try std.testing.expectEqual(17, @bitOffsetOf(Rasr, "C"));
        try std.testing.expectEqual(18, @bitOffsetOf(Rasr, "S"));
        try std.testing.expectEqual(24, @bitOffsetOf(Rasr, "AP"));
        try std.testing.expectEqual(28, @bitOffsetOf(Rasr, "XN"));
    }
}
