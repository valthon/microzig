//! SP 800-38A Appendix F four-block known answers, both key widths, no wiring.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const cfb128_vectors = hal.aes.cfb128_vectors;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = hal.usb_serial_jtag.logger.log });
comptime {
    _ = microzig.export_startup();
}
fn hex(comptime text: []const u8) [text.len / 2]u8 {
    return comptime blk: {
        var bytes: [text.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
        break :blk bytes;
    };
}
pub fn main() void {
    hal.time.sleep_ms(1500);
    var pass: usize = 0;
    var fail: usize = 0;
    const plain = cfb128_vectors.plain;
    inline for (.{
        .{ hex("2b7e151628aed2a6abf7158809cf4f3c"), .{ "3ad77bb40d7a3660a89ecaf32466ef97f5d3d58503b9699de785895a96fdbaaf43b1cd7f598ece23881b00e3ed0306887b0c785e27e8ad3f8223207104725dd4", "7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b273bed6b8e3c1743b7116e69e222295163ff1caa1681fac09120eca307586e1a7", "3b3fd92eb72dad20333449f8e83cfb4a7789508d16918f03f53c52dac54ed8259740051e9c5fecf64344f7a82260edcc304c6528f659c77866a510d9c1d6ae5e", "874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff5ae4df3edbd5d35e5b4f09020db03eab1e031dda2fbe03d1792170a0f3009cee", "3b79424c9c0dd436bace9e0ed4586a4f32b9ded50ae3ba69d472e88267fb505270cbad1e257691f7c47c5038297edda32ff26d0ed19174096161ecc14086dd62", cfb128_vectors.ciphertext_hex[0] } },
        .{ hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"), .{ "f3eed1bdb5d2a03c064b5a7e3db181f8591ccb10d410ed26dc5ba74a31362870b6ed21b99ca6f4f9f153e7b1beafed1d23304b7a39f9f3ff067d8d8f9e24ecc7", "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b", "dc7e84bfda79164b7ecd8486985d38604febdc6740d20b3ac88f6ad82a4fb08d71ab47a086e86eedf39d1c5bba97c4080126141d67f37be8538f5a8be740e484", "601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c52b0930daa23de94ce87017ba2d84988ddfc9c58db67aada613c2dd08457941a6", "dc1f1a8520a64db55fcc8ac554844e889700adc6e10c63cf2d8cd2d8ce668f3eb9191719c47444fb43bff9b9883c2cd051120402009f974998c89d195722a75b", cfb128_vectors.ciphertext_hex[1] } },
    }) |vector| {
        inline for (.{ .ecb, .cbc, .ofb, .ctr, .cfb8, .cfb128 }, vector[1]) |tag, expected_hex| {
            const mode: hal.aes.Mode = tag;
            const expected = hex(expected_hex);
            const initial = if (mode == .ctr) hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff") else hex("000102030405060708090a0b0c0d0e0f");
            var iv = initial;
            inline for (.{ .encrypt, .decrypt }) |direction| {
                // Decrypt in place, including CFB8's dependence on ciphertext.
                var actual: [64]u8 = if (direction == .decrypt) expected else @splat(0);
                const input = if (direction == .decrypt) &actual else &plain;
                const wanted = if (direction == .decrypt) &plain else &expected;
                iv = initial;
                const failure: ?hal.aes.Error = if (hal.aes.crypt(&vector[0], mode, direction, &iv, input, &actual)) |_| null else |err| err;
                const ok = failure == null and std.mem.eql(u8, wanted, &actual);
                if (ok) {
                    pass += 1;
                    std.log.info("SELFTEST aes {s}_{d}_{s}: PASS", .{ @tagName(mode), vector[0].len * 8, @tagName(direction) });
                } else {
                    fail += 1;
                    std.log.info("SELFTEST aes {s}_{d}_{s}: FAIL expected={s} actual={s} error={s}", .{
                        @tagName(mode),
                        vector[0].len * 8,
                        @tagName(direction),
                        std.fmt.bytesToHex(wanted, .lower),
                        std.fmt.bytesToHex(&actual, .lower),
                        if (failure) |err| @errorName(err) else "none",
                    });
                }
            }
        }
    }
    while (true) {
        std.log.info("SELFTEST aes DONE pass={} fail={}", .{ pass, fail });
        hal.time.sleep_ms(1000);
    }
}
