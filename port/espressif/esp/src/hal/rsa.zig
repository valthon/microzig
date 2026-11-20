//! ESP32-C6 TRM v1.2 §§22.3.1–22.3.4; shared C3 interface.
//! Raw large-integer arithmetic, not RSA padding or a signature protocol.
//! All limbs are least significant first. Thread context only; no concurrent DS.
//! Interrupts remain masked for each synchronous operation (up to ~753 ms for
//! 3072-bit exponentiation, TRM Table 22.3-1). Validation is not constant-time.
const std = @import("std");
const microzig = @import("microzig");
const system = @import("system.zig");
const compatibility = @import("compatibility.zig");
const RSA = microzig.chip.peripherals.RSA;
const CPU = microzig.chip.peripherals.RSA_CPU;
pub const Error = error{ InvalidLength, InvalidModulus, NonCanonical, Timeout };

// Patch format has no array operation: these word views repair the truncated
// SVD byte windows. Every access still uses a generated Mmio32 register.
fn memory(comptime bank: []const u8) [96]*volatile @TypeOf(CPU.M0) {
    @setEvalBranchQuota(100_000);
    var result: [96]*volatile @TypeOf(CPU.M0) = undefined;
    inline for (0..96) |i| result[i] = @ptrCast(&@field(CPU, bank ++ std.fmt.comptimePrint("{d}", .{i})));
    return result;
}
const m_mem = memory("M");
const z_mem = memory("Z");
const y_mem = memory("Y");
const x_mem = memory("X");

/// x, exponent, modulus, r_squared and output must have the same length (1–96).
/// modulus must be odd and >1, x and r_squared reduced modulo modulus.
/// Caller supplies r_squared = 2^(64*modulus.len) mod modulus, as required by
/// TRM §22.3.1. It depends on the padded limb length, not just the modulus value.
/// Output may alias an input; all input limbs are consumed before output writes.
pub fn mod_exp(x: []const u32, exponent: []const u32, modulus: []const u32, r_squared: []const u32, output: []u32) Error!void {
    try modular(.exponentiate, x, exponent, modulus, r_squared, output);
}

/// Same representation and precomputation as mod_exp; y must also be reduced.
pub fn mod_multiply(x: []const u32, y: []const u32, modulus: []const u32, r_squared: []const u32, output: []u32) Error!void {
    try modular(.multiply, x, y, modulus, r_squared, output);
}

fn less_than(a: []const u32, b: []const u32) bool {
    var i = a.len;
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) return a[i] < b[i];
    }
    return false;
}

fn modular(comptime operation: enum { exponentiate, multiply }, x: []const u32, y: []const u32, modulus: []const u32, rr: []const u32, output: []u32) Error!void {
    const n = modulus.len;
    if (n == 0 or n > 96 or x.len != n or y.len != n or rr.len != n or output.len != n) return error.InvalidLength;
    var high: u32 = 0;
    for (modulus[1..]) |word| high |= word;
    if (modulus[0] & 1 == 0 or (high == 0 and modulus[0] <= 1)) return error.InvalidModulus;
    if (!less_than(x, modulus) or !less_than(rr, modulus) or (operation == .multiply and !less_than(y, modulus))) return error.NonCanonical;
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    defer finish();
    try begin();
    RSA.MODE.write(.{ .MODE = @intCast(n - 1) });
    // Newton inverse doubles the correct low bits each iteration: 1 -> 32.
    var inverse: u32 = 1;
    for (0..5) |_| inverse *%= 2 -% modulus[0] *% inverse;
    RSA.M_PRIME.write(.{ .M_PRIME = 0 -% inverse });
    // TRM §22.3.4: 1 disables the data-dependent CONSTANT_TIME acceleration.
    RSA.CONSTANT_TIME.write(.{ .CONSTANT_TIME = 1 });
    RSA.SEARCH_ENABLE.write(.{ .SEARCH_ENABLE = 0 });
    for (x, y, modulus, rr, 0..) |a, b, m, r, i| {
        x_mem[i].write(.{ .VALUE = a });
        y_mem[i].write(.{ .VALUE = b });
        m_mem[i].write(.{ .VALUE = m });
        z_mem[i].write(.{ .VALUE = r });
    }
    if (operation == .exponentiate) RSA.SET_START_MODEXP.write(.{ .SET_START_MODEXP = 1 }) else RSA.SET_START_MODMULT.write(.{ .SET_START_MODMULT = 1 });
    try wait_idle();
    for (output, 0..) |*word, i| word.* = z_mem[i].read().VALUE;
}

/// x and y must have equal lengths 1–48; output must have twice that length.
/// Output may alias either input. No reduction or modulus is involved.
pub fn multiply(x: []const u32, y: []const u32, output: []u32) Error!void {
    const n = x.len;
    if (n == 0 or n > 48 or y.len != n or output.len != n * 2) return error.InvalidLength;
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    defer finish();
    try begin();
    RSA.MODE.write(.{ .MODE = @intCast(n * 2 - 1) });
    // TRM §22.3.3: Y goes in the upper half of Z, lower half starts zero.
    for (x, y, 0..) |a, b, i| {
        x_mem[i].write(.{ .VALUE = a });
        z_mem[i].write(.{ .VALUE = 0 });
        z_mem[n + i].write(.{ .VALUE = b });
    }
    RSA.SET_START_MULT.write(.{ .SET_START_MULT = 1 });
    try wait_idle();
    for (output, 0..) |*word, i| word.* = z_mem[i].read().VALUE;
}

fn begin() Error!void {
    system.enable_clocks_and_release_reset(.{ .crypto_rsa = true });
    system.peripheral_reset_clear(.{ .crypto_ds = true });
    system.peripheral_reset(.{ .crypto_rsa = true });
    switch (compatibility.chip) {
        .esp32_c3 => microzig.chip.peripherals.SYSTEM.RSA_PD_CTRL.modify(.{ .RSA_MEM_PD = 0 }),
        .esp32_c6 => microzig.chip.peripherals.PCR.RSA_PD_CTRL.modify(.{ .RSA_MEM_PD = 0, .RSA_MEM_FORCE_PD = 0 }),
    }
    RSA.INT_ENA.write(.{ .INT_ENA = 0 });
    for (0..1_000_000) |_| {
        if (RSA.QUERY_CLEAN.read().QUERY_CLEAN == 1) return;
    }
    return error.Timeout;
}

fn wait_idle() Error!void {
    for (0..100_000_000) |_| {
        if (RSA.QUERY_IDLE.read().QUERY_IDLE == 1) return;
    }
    return error.Timeout;
}

fn finish() void {
    // Stop a timed-out engine and power down operand SRAM. On next power-up,
    // QUERY_CLEAN must complete before any new operands are loaded.
    system.peripheral_reset_set(.{ .crypto_rsa = true });
    switch (compatibility.chip) {
        .esp32_c3 => microzig.chip.peripherals.SYSTEM.RSA_PD_CTRL.modify(.{ .RSA_MEM_PD = 1 }),
        .esp32_c6 => microzig.chip.peripherals.PCR.RSA_PD_CTRL.modify(.{ .RSA_MEM_PD = 1, .RSA_MEM_FORCE_PU = 0 }),
    }
    system.clocks_enable_clear(.{ .crypto_rsa = true });
}
