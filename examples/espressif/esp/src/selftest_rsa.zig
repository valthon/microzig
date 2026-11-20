//! No wiring. std.crypto.ff cross-checks modular operations; Zig u256 checks
//! plain multiplication. Maximum-width cases use (R-1) identities.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = hal.usb_serial_jtag.logger.log });
comptime {
    _ = microzig.export_startup();
}
fn limbs(comptime n: usize, value: u256) [n]u32 {
    var words: [n]u32 = undefined;
    for (&words, 0..) |*w, i| w.* = @truncate(value >> @intCast(i * 32));
    return words;
}
fn check_modular(comptime n: usize, comptime modulus: u128, comptime exponentiate: bool) !bool {
    const m = limbs(n, modulus);
    const x = limbs(n, modulus - 2);
    const y = limbs(n, if (exponentiate) 65537 else modulus - 3);
    const rr_value: u512 = (@as(u512, 1) << (n * 64)) % modulus;
    const rr = limbs(n, @intCast(rr_value));
    var actual: [n]u32 = undefined;
    const F = std.crypto.ff.Modulus(128);
    const field = try F.fromPrimitive(u128, modulus);
    const a = try F.Fe.fromPrimitive(u128, field, modulus - 2);
    const b = try F.Fe.fromPrimitive(u128, field, if (exponentiate) 65537 else modulus - 3);
    const expected = if (exponentiate) try field.powPublic(a, b) else field.mul(a, b);
    const words = limbs(n, try expected.toPrimitive(u128));
    if (exponentiate) try hal.rsa.mod_exp(&x, &y, &m, &rr, &actual) else try hal.rsa.mod_multiply(&x, &y, &m, &rr, &actual);
    return std.mem.eql(u32, &words, &actual);
}
fn check_multiply(comptime n: usize, comptime value: u128) !bool {
    const x = limbs(n, value);
    const y = limbs(n, value - 1);
    const expected = limbs(n * 2, @as(u256, value) * (value - 1));
    var actual: [n * 2]u32 = undefined;
    try hal.rsa.multiply(&x, &y, &actual);
    return std.mem.eql(u32, &expected, &actual);
}
fn check_max_multiply() !bool {
    const x: [48]u32 = @splat(0xffffffff);
    var result: [96]u32 = undefined;
    try hal.rsa.multiply(&x, &x, &result);
    for (result, 0..) |word, i| {
        const expected: u32 = if (i == 0) 1 else if (i < 48) 0 else if (i == 48) 0xfffffffe else 0xffffffff;
        if (word != expected) return false;
    }
    return true;
}
fn check_max_modular(comptime exponentiate: bool) !bool {
    const m: [96]u32 = @splat(0xffffffff);
    var x = m;
    x[0] -= 2;
    var y: [96]u32 = @splat(0);
    y[0] = 3;
    var rr: [96]u32 = @splat(0);
    rr[0] = 1; // R mod (R-1) = 1, hence R² mod (R-1) = 1.
    var actual: [96]u32 = undefined;
    if (exponentiate) try hal.rsa.mod_exp(&x, &y, &m, &rr, &actual) else try hal.rsa.mod_multiply(&x, &y, &m, &rr, &actual);
    var expected = m;
    expected[0] -= if (exponentiate) 8 else 6;
    return std.mem.eql(u32, &expected, &actual);
}
fn report(name: []const u8, ok: bool, pass: *usize, fail: *usize) void {
    if (ok) pass.* += 1 else fail.* += 1;
    std.log.info("SELFTEST rsa {s}: {s}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL" });
}
pub fn main() void {
    hal.time.sleep_ms(1500);
    var pass: usize = 0;
    var fail: usize = 0;
    inline for (.{ .{ 1, 0xfffffffb }, .{ 2, 0xffffffffffffffc5 }, .{ 4, 0xffffffffffffffffffffffffffffff61 } }) |v| {
        inline for (.{ false, true }) |exp| {
            report(std.fmt.comptimePrint("{s}_{d}", .{ if (exp) "mod_exp" else "mod_mul", v[0] * 32 }), check_modular(v[0], v[1], exp) catch false, &pass, &fail);
        }
        report(std.fmt.comptimePrint("multiply_{d}", .{v[0] * 32}), check_multiply(v[0], v[1] - 2) catch false, &pass, &fail);
    }
    report("multiply_1536", check_max_multiply() catch false, &pass, &fail);
    report("mod_mul_3072", check_max_modular(false) catch false, &pass, &fail);
    report("mod_exp_3072", check_max_modular(true) catch false, &pass, &fail);
    while (true) {
        std.log.info("SELFTEST rsa DONE pass={} fail={}", .{ pass, fail });
        hal.time.sleep_ms(1000);
    }
}
