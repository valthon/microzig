//! ESP32-C6 TRM v1.2 §§20.3.2–20.7. Affine points only; verification is
//! curve membership, not signature verification. Thread context only.
//! One caller owns the accelerator at a time; a concurrent caller gets
//! error.Busy. Interrupts stay enabled while the hardware calculates.
//! No constant-time or fault resistance claim.
const std = @import("std");
const microzig = @import("microzig");
const system = @import("system.zig");
comptime {
    if (@import("compatibility.zig").chip != .esp32_c6) @compileError("ECC requires ESP32-C6");
}
const ECC = microzig.chip.peripherals.ECC;
const CPU = microzig.chip.peripherals.ECC_CPU;
const PCR = microzig.chip.peripherals.PCR;
const word_suffixes = .{ "0", "1", "2", "3", "4", "5", "6", "7" };
pub const Error = error{ Timeout, InvalidPoint, InvalidScalar, Busy };
pub const Curve = enum(u1) {
    p192 = 0,
    p256 = 1,
    pub fn byte_length(comptime curve: Curve) usize {
        return if (curve == .p192) 24 else 32;
    }
};

/// Canonical unsigned big-endian coordinates; the point at infinity is excluded.
pub fn Point(comptime curve: Curve) type {
    return struct { x: [curve.byte_length()]u8, y: [curve.byte_length()]u8 };
}

// NIST FIPS 186-4 Appendix D.1.2: prime fields and group orders for P-192 / P-256.
fn prime(comptime curve: Curve) [curve.byte_length()]u8 {
    var bytes: [curve.byte_length()]u8 = undefined;
    const T = @Int(.unsigned, curve.byte_length() * 8);
    std.mem.writeInt(T, &bytes, if (curve == .p192) 0xfffffffffffffffffffffffffffffffeffffffffffffffff else 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff, .big);
    return bytes;
}
fn order(comptime curve: Curve) [curve.byte_length()]u8 {
    var bytes: [curve.byte_length()]u8 = undefined;
    const T = @Int(.unsigned, curve.byte_length() * 8);
    std.mem.writeInt(T, &bytes, if (curve == .p192) 0xffffffffffffffffffffffff99def836146bc9b1b4d22831 else 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551, .big);
    return bytes;
}
fn canonical(comptime curve: Curve, point: Point(curve)) bool {
    const p = prime(curve);
    return std.mem.order(u8, &point.x, &p) == .lt and std.mem.order(u8, &point.y, &p) == .lt;
}

/// False for noncanonical coordinates and off-curve points. Hardware faults are errors.
pub fn verify(comptime curve: Curve, point: Point(curve)) Error!bool {
    if (!canonical(curve, point)) return false;
    return (try calculate(curve, point, null)).valid;
}

/// Scalar is unsigned big endian, 1 <= scalar < group order. Uses hardware
/// verify-then-multiply mode; off-curve inputs never produce a returned point.
pub fn multiply(comptime curve: Curve, scalar: [curve.byte_length()]u8, point: Point(curve)) Error!Point(curve) {
    const n = order(curve);
    var nonzero: u8 = 0;
    for (scalar) |b| nonzero |= b;
    if (nonzero == 0 or std.mem.order(u8, &scalar, &n) != .lt) return error.InvalidScalar;
    if (!canonical(curve, point)) return error.InvalidPoint;
    const result = try calculate(curve, point, scalar);
    if (!result.valid) return error.InvalidPoint;
    return result.point;
}
fn Result(comptime curve: Curve) type {
    return struct { valid: bool, point: Point(curve) };
}
// Only this driver touches ECC, ECC_MEM and their PCR clock/reset/power
// registers (ECC_CONF, ECC_PD_CTRL), so ownership of the accelerator needs no
// critical section across the calculation. The completion poll reads the raw
// CALC_DONE status with its interrupt disabled; that status does not depend on
// the CPU's interrupt mask. A P-256 multiply therefore no longer delays the
// radio controller's interrupts; a preempting task that also calls this
// driver receives error.Busy instead of waiting.
var owned: bool = false;
fn acquire() Error!void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    if (owned) return error.Busy;
    owned = true;
}
fn release() void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    owned = false;
}
fn calculate(comptime curve: Curve, point: Point(curve), scalar: ?[curve.byte_length()]u8) Error!Result(curve) {
    try acquire();
    defer release();
    system.enable_clocks_and_release_reset(.{ .crypto_ecc = true });
    PCR.ECC_PD_CTRL.modify(.{ .ECC_MEM_PD = 0, .ECC_MEM_FORCE_PD = 0 });
    system.peripheral_reset(.{ .crypto_ecc = true });
    defer {
        system.peripheral_reset_set(.{ .crypto_ecc = true });
        PCR.ECC_PD_CTRL.modify(.{ .ECC_MEM_PD = 1, .ECC_MEM_FORCE_PU = 0 });
        system.clocks_enable_clear(.{ .crypto_ecc = true });
    }
    ECC.MULT_INT_ENA.write(.{ .CALC_DONE_INT_ENA = 0 });
    ECC.MULT_INT_CLR.write(.{ .CALC_DONE_INT_CLR = 1 });
    write_operand(curve, "PX", point.x);
    write_operand(curve, "PY", point.y);
    write_operand(curve, "K", scalar orelse @splat(0));
    ECC.MULT_CONF.write(.{
        .KEY_LENGTH = @backingInt(curve),
        .WORK_MODE = if (scalar != null) 3 else 2,
        .MEM_CLOCK_GATE_FORCE_ON = 1,
        .START = 1,
    });
    for (0..10_000_000) |_| {
        if (ECC.MULT_INT_RAW.read().CALC_DONE_INT_RAW == 1) {
            const valid = ECC.MULT_CONF.read().VERIFICATION_RESULT == 1;
            var result = point;
            if (valid and scalar != null) {
                result.x = read_operand(curve, "PX");
                result.y = read_operand(curve, "PY");
            }
            ECC.MULT_INT_CLR.write(.{ .CALC_DONE_INT_CLR = 1 });
            return .{ .valid = valid, .point = result };
        }
    }
    return error.Timeout;
}
fn write_operand(comptime curve: Curve, comptime bank: []const u8, bytes: [curve.byte_length()]u8) void {
    inline for (0..8) |i| {
        const value = if (i < curve.byte_length() / 4) std.mem.readInt(u32, bytes[curve.byte_length() - (i + 1) * 4 ..][0..4], .big) else 0;
        @field(CPU, bank ++ word_suffixes[i]).write(.{ .VALUE = value });
    }
}
fn read_operand(comptime curve: Curve, comptime bank: []const u8) [curve.byte_length()]u8 {
    var bytes: [curve.byte_length()]u8 = undefined;
    inline for (0..(comptime curve.byte_length() / 4)) |i| {
        const value = @field(CPU, bank ++ word_suffixes[i]).read().VALUE;
        std.mem.writeInt(u32, bytes[curve.byte_length() - (i + 1) * 4 ..][0..4], value, .big);
    }
    return bytes;
}
