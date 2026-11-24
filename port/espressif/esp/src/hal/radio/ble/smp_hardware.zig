//! C6 P-256 adapter. Hardware verifies curve membership before multiplication.
//! Scalars/points are big endian in hal.ecc; SMP encoding is handled separately.
const std = @import("std");
const ecc = @import("../../ecc.zig");
const osi = @import("../osi.zig");
const smp = @import("smp.zig");
const c = smp.crypto;
pub const crypto: smp.Crypto = .{ .random_fn = random, .key_pair_fn = key_pair, .dh_fn = dh };
fn random(_: ?*anyopaque, out: []u8) smp.Error!void {
    var i: usize = 0;
    while (i < out.len) {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, osi.rand(), .little);
        const len = @min(4, out.len - i);
        @memcpy(out[i..][0..len], bytes[0..len]);
        i += len;
    }
}
fn key_pair(_: ?*anyopaque) smp.Error!smp.KeyPair {
    const generator: ecc.Point(.p256) = .{
        .x = c.hex("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"),
        .y = c.hex("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"),
    };
    var private: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &private);
    for (0..16) |_| {
        try random(null, &private);
        if (std.mem.eql(u8, &private, &c.hex("3f49f6d4a3c55f3874c9b3e3d2103f504aff607beb40b7995899b8a6cd3c1abd"))) continue;
        const point = ecc.multiply(.p256, private, generator) catch |err| switch (err) {
            error.InvalidScalar => continue,
            else => return error.CryptoFailed,
        };
        return .{ .public = .{ .x = point.x, .y = point.y }, .private = private };
    }
    return error.CryptoFailed;
}
fn dh(_: ?*anyopaque, private: [32]u8, peer: smp.Point) smp.Error![32]u8 {
    const point = ecc.multiply(.p256, private, .{ .x = peer.x, .y = peer.y }) catch return error.CryptoFailed;
    return point.x;
}
/// IDF v5.5.1 bt.c ble_sm_alg_gen_key_pair/gen_dhkey use little-endian
/// coordinates, private scalar and shared X at the controller ABI boundary.
pub fn controller_key(public: [*]u8, private: [*]u8) callconv(.c) c_int {
    var pair = key_pair(null) catch return -1;
    defer std.crypto.secureZero(u8, &pair.private);
    public[0..32].* = c.reverse(32, pair.public.x);
    public[32..64].* = c.reverse(32, pair.public.y);
    private[0..32].* = c.reverse(32, pair.private);
    return 0;
}
pub fn controller_dh(x: [*]const u8, y: [*]const u8, private: [*]const u8, out: [*]u8) callconv(.c) c_int {
    var secret = c.reverse(32, private[0..32].*);
    defer std.crypto.secureZero(u8, &secret);
    var shared = dh(null, secret, .{ .x = c.reverse(32, x[0..32].*), .y = c.reverse(32, y[0..32].*) }) catch return -1;
    defer std.crypto.secureZero(u8, &shared);
    out[0..32].* = c.reverse(32, shared);
    return 0;
}
