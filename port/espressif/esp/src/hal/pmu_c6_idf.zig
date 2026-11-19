//! Independent ESP-IDF v5.5.1 oracle, without HAL field encoding or helpers.
//! Literal profiles come from compiling IDF's unmodified C and LL headers:
//! examples/espressif/esp/tools/sleep_c6_idf_reference.py. Host tests compare
//! the actual HAL plan to these literals, not merely to this runtime oracle.
const std = @import("std");
pub const vectors = @import("pmu_c6_idf_vectors.zon");
pub const SleepDomains = struct {
    power_down_xtal: bool = false,
    lp_core: bool = false,
    slow_source: u2 = 0,
};
pub const Word = struct { name: []const u8, mask: u32, value: u32 };
pub const init_words: [vectors[0].init_words.len]Word = blk: {
    var result: [vectors[0].init_words.len]Word = undefined;
    for (vectors[0].init_words, 0..) |w, i| result[i] = .{ .name = w.name, .mask = w.mask, .value = w.value };
    break :blk result;
};
pub const Fuses = struct { version: u32, hp: u5, lp: u5, deep_dbg: u3, deep_lp: u4 };
pub const Bias = struct { hp: u5, lp: u5, deep_dbg: u4, deep_lp: u5 };

/// pmu_param.c:418–466; pmu_sleep.c:57–81. This does not call active_dbias.
pub fn bias(f: Fuses) Bias {
    var result: Bias = .{ .hp = 25, .lp = 26, .deep_dbg = 12, .deep_lp = 23 };
    if (f.version >= 3) {
        if (f.hp != 0) result.hp = @intCast(@min(@as(u32, f.hp) + 2, 31));
        if (f.lp != 0) result.lp = @intCast(@min(@as(u32, f.lp) + 2, 31));
        result.deep_dbg = @intCast(@as(u32, f.deep_dbg) + 8);
        result.deep_lp = @truncate(@as(u32, f.deep_lp) + 23);
    }
    return result;
}

fn ticks(us: u64, period: u32) u32 {
    return @intCast(us * 524288 / period);
}

/// For the fixed inputs, use the checked-in IDF words verbatim. For measured
/// clocks/burned biases, independently specialize the affected raw fields.
/// Packing is from soc/esp32c6/register/soc/pmu_struct.h, not generated SVD.
pub fn sleep_word(comptime name: []const u8, b: Bias, slow: u32, fast: u32, deep: bool, domains: SleepDomains) Word {
    const index: usize = if (deep) 1 else if (domains.power_down_xtal) 2 else 0;
    var word: Word = undefined;
    inline for (vectors, 0..) |v, i| {
        if (i < 3 and index == i) {
            var found = false;
            inline for (v.words) |w| {
                if (comptime std.mem.eql(u8, name, w.name)) {
                    word = .{ .name = w.name, .mask = w.mask, .value = w.value };
                    found = true;
                }
            }
            std.debug.assert(found);
        }
    }
    const kept_xtal = !deep and !domains.power_down_xtal;
    const kept_fast = kept_xtal or domains.lp_core;
    if (std.mem.eql(u8, name, "HP_SLEEP_LP_CK_POWER") or std.mem.eql(u8, name, "LP_SLEEP_LP_CK_POWER")) {
        const hp = std.mem.eql(u8, name, "HP_SLEEP_LP_CK_POWER");
        word.value = (if (kept_xtal or domains.slow_source == 1) @as(u32, 0x10000000) else 0) |
            (if (kept_xtal or domains.slow_source == 2) @as(u32, 0x20000000) else 0) |
            (if (hp or kept_fast) @as(u32, 0x40000000) else 0);
    }
    if (std.mem.eql(u8, name, "LP_SLEEP_LP_DIG_POWER") and domains.lp_core) word.value = 0x40000000;
    const nominal_bias = b.hp == 25 and b.lp == 26 and b.deep_dbg == 12 and b.deep_lp == 23;
    if (slow == 3495253 and fast == 26214 and nominal_bias and !domains.lp_core) return word;
    // pmu_sleep.c:244–279,308–326 and pmu_param.h:349–399.
    if (std.mem.eql(u8, name, "HP_SLEEP_HP_REGULATOR0"))
        word.value = (@as(u32, if (deep) 0 else if (kept_fast) b.hp else 1) * 0x08000000) | @as(u32, if (deep) 0 else 0x40000);
    if (std.mem.eql(u8, name, "LP_SLEEP_LP_REGULATOR0"))
        word.value = @as(u32, if (deep) b.deep_lp else if (kept_fast) b.lp else 12) * 0x08000000 | 0x400000;
    if (deep and std.mem.eql(u8, name, "LP_SLEEP_BIAS"))
        word.value = @as(u32, b.deep_dbg) * 0x04000000 | 0xc0000000;
    // pmu_sleep.c:196–215,237–240; pmu_param.h:461–490.
    if (std.mem.eql(u8, name, "SLP_WAKEUP_CNTL3")) word.value = ticks(450, slow) * 257;
    if (std.mem.eql(u8, name, "SLP_WAKEUP_CNTL7")) word.value = ticks(154, fast) * 65536;
    if (std.mem.eql(u8, name, "SLP_WAKEUP_CNTL5"))
        word.value = ticks(if (deep) 500 else 154, slow) * 0x1000000 | ticks(278 + 124 + 450 + 70, fast);
    if (std.mem.eql(u8, name, "POWER_WAIT_TIMER0")) word.value = ticks(2, fast) * (0x800000 + 0x4000);
    if (std.mem.eql(u8, name, "POWER_WAIT_TIMER1")) word.value = ticks(2, fast) * (0x800000 + 0x10000);
    if (std.mem.eql(u8, name, "POWER_CK_WAIT_CNTL"))
        word.value = ticks(250, if (kept_xtal) slow else fast) | ticks(50, fast) * 65536;
    return word;
}
