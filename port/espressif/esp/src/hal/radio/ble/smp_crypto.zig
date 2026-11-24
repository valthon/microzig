//! Core v5.4 Vol 3 Part H §2.2. All integers here are big endian, as in
//! Appendix D. SMP/HCI little-endian conversion belongs at the wire boundary.
const std = @import("std");
pub const Key = [16]u8;
pub const Coordinate = [32]u8;
pub const Address = [7]u8;
pub fn reverse(comptime n: usize, bytes: [n]u8) [n]u8 {
    var result = bytes;
    std.mem.reverse(u8, &result);
    return result;
}
pub fn cmac(key: Key, message: []const u8) Key {
    var result: Key = undefined;
    std.crypto.auth.cmac.CmacAes128.create(&result, message, &key);
    return result;
}
pub fn f4(u: Coordinate, v: Coordinate, x: Key, z: u8) Key {
    return cmac(x, &(u ++ v ++ [1]u8{z}));
}
pub const Derived = struct { mac: Key, ltk: Key };
pub fn f5(w: Coordinate, n1: Key, n2: Key, a1: Address, a2: Address) Derived {
    const salt = hex("6c888391aaf5a53860370bdb5a6083be");
    const t = cmac(salt, &w);
    const tail = "btle".* ++ n1 ++ n2 ++ a1 ++ a2 ++ [2]u8{ 1, 0 };
    return .{ .mac = cmac(t, &([1]u8{0} ++ tail)), .ltk = cmac(t, &([1]u8{1} ++ tail)) };
}
pub fn f6(w: Key, n1: Key, n2: Key, r: Key, io: [3]u8, a1: Address, a2: Address) Key {
    return cmac(w, &(n1 ++ n2 ++ r ++ io ++ a1 ++ a2));
}
pub fn g2(u: Coordinate, v: Coordinate, x: Key, y: Key) u32 {
    const mac = cmac(x, &(u ++ v ++ y));
    return std.mem.readInt(u32, mac[12..16], .big);
}
pub fn ah(irk: Key, prand: [3]u8) [3]u8 {
    const input = @as([13]u8, @splat(0)) ++ prand;
    var out: Key = undefined;
    std.crypto.core.aes.Aes128.initEnc(irk).encrypt(&out, &input);
    return out[13..16].*;
}
pub fn equal(a: Key, b: Key) bool {
    return std.crypto.timing_safe.eql(Key, a, b);
}
pub fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var result: [s.len / 2]u8 = undefined;
    for (&result, 0..) |*b, i| b.* = std.fmt.parseInt(u8, s[i * 2 ..][0..2], 16) catch unreachable;
    return result;
}
test "Core v5.4 Vol 3 Part H Appendix D.1 AES-CMAC" {
    const k = hex("2b7e151628aed2a6abf7158809cf4f3c");
    const m = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710");
    inline for (.{ .{ 0, "bb1d6929e95937287fa37d129b756746" }, .{ 16, "070a16b46b4d4144f79bdd9dd04a287c" }, .{ 40, "dfa66747de9ae63030ca32611497c827" }, .{ 64, "51f0bebf7e3b9d92fc49741779363cfe" } }) |v|
        try std.testing.expectEqualSlices(u8, &hex(v[1]), &cmac(k, m[0..v[0]]));
}
test "Core v5.4 Vol 3 Part H Appendix D.2-D.5, D.7" {
    const u = hex("20b003d2f297be2c5e2c83a7e9f9a5b9eff49111acf4fddbcc0301480e359de6");
    const v = hex("55188b3d32f6bb9a900afcfbeed4e72a59cb9ac2f19d7cfb6b4fdd49f47fc5fd");
    const n1 = hex("d5cb8454d177733effffb2ec712baeab");
    const n2 = hex("a6e8e7cc25a75f6e216583f7ff3dc4cf");
    const a1 = hex("0056123737bfce");
    const a2 = hex("00a713702dcfc1");
    try std.testing.expectEqualSlices(u8, &hex("f2c916f107a9bd1cf1eda1bea974872d"), &f4(u, v, n1, 0));
    const keys = f5(hex("ec0234a357c8ad05341010a60a397d9b99796b13b4f866f1868d34f373bfa698"), n1, n2, a1, a2);
    try std.testing.expectEqualSlices(u8, &hex("2965f176a1084a02fd3f6a20ce636e20"), &keys.mac);
    try std.testing.expectEqualSlices(u8, &hex("6986791169d7cd23980522b594750a38"), &keys.ltk);
    try std.testing.expectEqualSlices(u8, &hex("e3c473989cd0e8c5d26c0b09da958f61"), &f6(keys.mac, n1, n2, hex("12a3343bb453bb5408da42d20c2d0fc8"), hex("010102"), a1, a2));
    try std.testing.expectEqual(@as(u32, 0x2f9ed5ba), g2(u, v, n1, n2));
    try std.testing.expectEqualSlices(u8, &hex("0dfbaa"), &ah(hex("ec0234a357c8ad05341010a60a397d9b"), hex("708194")));
}
