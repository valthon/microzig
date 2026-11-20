//! Shared with selftest_aes so the hardware answers are pinned by host tests.
//! NIST SP 800-38A F.3.13–F.3.14 (128 bits), F.3.17–F.3.18 (256 bits).
//! F.3.15–F.3.16 describe AES-192, which this HAL does not support.
const std = @import("std");

pub const plain = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710");
pub const iv = hex("000102030405060708090a0b0c0d0e0f");
pub const ciphertext_hex = .{
    "3b3fd92eb72dad20333449f8e83cfb4ac8a64537a0b3a93fcde3cdad9f1ce58b26751f67a3cbb140b1808cf187a4f4dfc04b05357c5d1c0eeac4c66f9ff7f2e6",
    "dc7e84bfda79164b7ecd8486985d386039ffed143b28b1c832113c6331e5407bdf10132415e54b92a13ed0a8267ae2f975a385741ab9cef82031623d55b1e471",
};

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    return comptime blk: {
        var bytes: [text.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
        break :blk bytes;
    };
}

test "CFB128 hardware vectors match std.crypto AES encryption and decryption" {
    inline for (.{
        hex("2b7e151628aed2a6abf7158809cf4f3c"),
        hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
    }, ciphertext_hex) |key, expected_hex| {
        const Aes = if (key.len == 16) std.crypto.core.aes.Aes128 else std.crypto.core.aes.Aes256;
        const aes = Aes.initEnc(key);
        const expected = hex(expected_hex);
        inline for (.{ false, true }) |decrypt| {
            var feedback = iv;
            var actual: [64]u8 = undefined;
            const input = if (decrypt) expected else plain;
            for (0..4) |i| {
                var stream: [16]u8 = undefined;
                aes.encrypt(&stream, &feedback);
                const offset = i * 16;
                for (stream, input[offset..][0..16], actual[offset..][0..16]) |s, b, *out| out.* = s ^ b;
                feedback = if (decrypt) input[offset..][0..16].* else actual[offset..][0..16].*;
            }
            try std.testing.expectEqualSlices(u8, if (decrypt) &plain else &expected, &actual);
            try std.testing.expectEqualSlices(u8, expected[48..64], &feedback);
        }
    }
}
