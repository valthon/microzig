//! No wiring. FIPS 186-4 Appendix D generators; std.crypto cross-checks
//! P-256 multiplication and P-192 doubling over its prime field.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const ecc = hal.ecc;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .log_level = .info, .logFn = hal.usb_serial_jtag.logger.log });
comptime {
    _ = microzig.export_startup();
}
fn hex(comptime text: []const u8) [text.len / 2]u8 {
    return comptime blk: {
        var result: [text.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&result, text) catch unreachable;
        break :blk result;
    };
}
fn generator(comptime curve: ecc.Curve) ecc.Point(curve) {
    return if (curve == .p192) .{
        .x = hex("188da80eb03090f67cbf20eb43a18800f4ff0afd82ff1012"),
        .y = hex("07192b95ffc8da78631011ed6b24cdd573f977a11e794811"),
    } else .{
        .x = hex("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"),
        .y = hex("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"),
    };
}
fn same(comptime curve: ecc.Curve, a: ecc.Point(curve), b: ecc.Point(curve)) bool {
    return std.mem.eql(u8, &a.x, &b.x) and std.mem.eql(u8, &a.y, &b.y);
}
fn software_double_p192() !ecc.Point(.p192) {
    const F = std.crypto.ff.Modulus(192);
    const p: u192 = 0xfffffffffffffffffffffffffffffffeffffffffffffffff;
    const field = try F.fromPrimitive(u192, p);
    const g = generator(.p192);
    const x = try F.Fe.fromBytes(field, &g.x, .big);
    const y = try F.Fe.fromBytes(field, &g.y, .big);
    const three = try F.Fe.fromPrimitive(u192, field, 3);
    const inverse_exponent = try F.Fe.fromPrimitive(u192, field, p - 2);
    // slope = (3*x² - 3)/(2*y); Fermat inverse since p is prime.
    const numerator = field.sub(field.mul(three, field.mul(x, x)), three);
    const denominator = field.add(y, y);
    const slope = field.mul(numerator, try field.powPublic(denominator, inverse_exponent));
    const out_x = field.sub(field.mul(slope, slope), field.add(x, x));
    const out_y = field.sub(field.mul(slope, field.sub(x, out_x)), y);
    var result: ecc.Point(.p192) = undefined;
    try out_x.toBytes(&result.x, .big);
    try out_y.toBytes(&result.y, .big);
    return result;
}
fn check_multiply(comptime curve: ecc.Curve, comptime scalar_value: u32) !bool {
    var scalar: [curve.byte_length()]u8 = @splat(0);
    std.mem.writeInt(u32, scalar[scalar.len - 4 ..][0..4], scalar_value, .big);
    const actual = try ecc.multiply(curve, scalar, generator(curve));
    const expected = if (curve == .p192) try software_double_p192() else blk: {
        const P = std.crypto.ecc.P256;
        const sw = try P.basePoint.mul(scalar, .big);
        const affine = sw.affineCoordinates();
        break :blk ecc.Point(.p256){ .x = affine.x.toBytes(.big), .y = affine.y.toBytes(.big) };
    };
    return same(curve, actual, expected) and try ecc.verify(curve, actual);
}
fn check_rejections(comptime curve: ecc.Curve) !bool {
    const zero: [curve.byte_length()]u8 = @splat(0);
    const g = generator(curve);
    var invalid = ecc.Point(curve){ .x = zero, .y = zero };
    invalid.x[invalid.x.len - 1] = 1;
    invalid.y[invalid.y.len - 1] = 1;
    if (try ecc.verify(curve, invalid)) return false;
    var scalar = zero;
    scalar[scalar.len - 1] = 2;
    if (ecc.multiply(curve, scalar, invalid)) |_| return false else |err| {
        if (err != error.InvalidPoint) return err;
    }
    if (ecc.multiply(curve, zero, g)) |_| return false else |err| {
        if (err != error.InvalidScalar) return err;
    }
    const order = if (curve == .p192) hex("ffffffffffffffffffffffff99def836146bc9b1b4d22831") else hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551");
    if (ecc.multiply(curve, order, g)) |_| return false else |err| {
        if (err != error.InvalidScalar) return err;
    }
    invalid = g;
    invalid.x = @splat(0xff);
    return !try ecc.verify(curve, invalid);
}
fn report(name: []const u8, ok: bool, pass: *usize, fail: *usize) void {
    if (ok) pass.* += 1 else fail.* += 1;
    std.log.info("SELFTEST ecc {s}: {s}", .{ name, if (ok) @as([]const u8, "PASS") else "FAIL" });
}
pub fn main() void {
    hal.time.sleep_ms(1500);
    var pass: usize = 0;
    var fail: usize = 0;
    inline for (.{ ecc.Curve.p192, ecc.Curve.p256 }) |curve| {
        report(@tagName(curve) ++ "_generator", ecc.verify(curve, generator(curve)) catch false, &pass, &fail);
        report(@tagName(curve) ++ "_double", check_multiply(curve, 2) catch false, &pass, &fail);
        report(@tagName(curve) ++ "_reject", check_rejections(curve) catch false, &pass, &fail);
    }
    report("p256_scalar_12345678", check_multiply(.p256, 0x12345678) catch false, &pass, &fail);
    while (true) {
        std.log.info("SELFTEST ecc DONE pass={} fail={}", .{ pass, fail });
        hal.time.sleep_ms(1000);
    }
}
