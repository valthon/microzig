//! Host-only microzig stand-in. Uses the actual generated C6 register types
//! and actual pmu_c6.zig plan construction; never dereferences a peripheral.
const std = @import("std");
pub const chip = @import("chip");
pub const mmio = @import("mmio");
const pmu = @import("pmu");
const reference = pmu.idf_reference;

fn check_word(r: pmu.Row, name: []const u8, mask: u32, value: u32) !void {
    errdefer std.debug.print("PMU row {s}: HAL=0x{x:0>8} oracle=0x{x:0>8} fixture=0x{x:0>8}\n", .{ name, r.value, r.idf, value });
    try std.testing.expectEqualStrings(name, r.name);
    try std.testing.expectEqual(mask, r.mask);
    try std.testing.expectEqual(value, r.value);
    try std.testing.expectEqual(value, r.idf);
}

test "actual C6 plans match nine independent literal IDF v5.5.1 profiles" {
    inline for (reference.vectors) |v| {
        const cal = pmu.Calibration.from_fuses(.{ .version = v.fuses.version, .hp = v.fuses.hp, .lp = v.fuses.lp, .deep_dbg = v.fuses.deep_dbg, .deep_lp = v.fuses.deep_lp });
        try std.testing.expectEqual(v.bias.hp, cal.hp);
        try std.testing.expectEqual(v.bias.lp, cal.lp);
        try std.testing.expectEqual(v.bias.deep_dbg, cal.deep_dbg);
        try std.testing.expectEqual(v.bias.deep_lp, cal.deep_lp);
        const init = pmu.init_plan(cal);
        // IDF's LL packs all init table rows, including repeated writes.
        // The plan preserves untouched bits; compare each IDF word under its
        // actual HAL mask for every eFuse profile, not just the bias fields.
        inline for (v.init_words, 0..) |word, i| {
            const row = init.rows[i];
            try check_word(row, word.name, row.mask, word.value & row.mask);
        }
        const plan = try pmu.sleep_plan_for_clock(cal, .{ .slow = v.slow, .fast = v.fast }, v.deep, false, .{ .power_down_xtal = v.xtal_off });
        errdefer std.debug.print("fixture: {s}\n", .{v.name});
        try std.testing.expectEqual(v.words.len, plan.len);
        inline for (v.words, 0..) |word, i| try check_word(plan.rows[i], word.name, word.mask, word.value);
    }
}

test "the oracle detects the original fast/slow XTAL error and power/bias mutations" {
    const v = reference.vectors[1]; // default_deep, XTAL off
    const cal = pmu.Calibration.from_fuses(.{ .version = 0, .hp = 0, .lp = 0, .deep_dbg = 0, .deep_lp = 0 });
    const plan = try pmu.sleep_plan_for_clock(cal, .{ .slow = v.slow, .fast = v.fast }, true, false, .{});
    var checked: usize = 0;
    for (plan.rows[0..plan.len]) |r| {
        if (std.mem.eql(u8, r.name, "POWER_CK_WAIT_CNTL")) {
            // Previous implementation used slow cycles (37) for XTAL-off.
            const wrong = (r.value & 0xffff0000) | 37;
            try std.testing.expect(wrong != r.idf);
            try std.testing.expectEqual(@as(u32, 5000), r.idf & 0xffff);
            checked += 1;
        }
        if (std.mem.eql(u8, r.name, "HP_SLEEP_DIG_POWER") or std.mem.eql(u8, r.name, "LP_SLEEP_LP_REGULATOR0")) {
            const wrong = r.value ^ 0x08000000;
            try std.testing.expect(wrong != r.idf);
            checked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), checked);
}

test "XTAL-off rejects XTAL LP_FAST; wake sources retain LP domains" {
    const cal = pmu.Calibration.from_fuses(.{ .version = 0, .hp = 0, .lp = 0, .deep_dbg = 0, .deep_lp = 0 });
    const clocks = .{ .slow = 3495253, .fast = 26214 };
    try std.testing.expectError(error.UnsupportedClock, pmu.sleep_plan_for_clock(cal, .{ .slow = clocks.slow, .fast = clocks.fast }, true, true, .{}));
    try std.testing.expectError(error.UnsupportedClock, pmu.sleep_plan_for_clock(cal, .{ .slow = clocks.slow, .fast = clocks.fast }, false, true, .{ .power_down_xtal = true }));
    _ = try pmu.sleep_plan_for_clock(cal, .{ .slow = clocks.slow, .fast = clocks.fast }, false, true, .{});
    inline for (.{ @as(u2, 0), @as(u2, 1), @as(u2, 2) }) |slow| {
        const plan = try pmu.sleep_plan_for_clock(cal, .{ .slow = clocks.slow, .fast = clocks.fast }, true, false, .{ .lp_core = true, .slow_source = slow });
        for (plan.rows[0..plan.len]) |row| {
            try std.testing.expectEqual(row.idf, row.value);
            if (std.mem.eql(u8, row.name, "LP_SLEEP_LP_DIG_POWER")) try std.testing.expectEqual(@as(u32, 0x40000000), row.value);
            if (std.mem.eql(u8, row.name, "LP_SLEEP_LP_CK_POWER")) {
                try std.testing.expect(row.value & 0x40000000 != 0);
                try std.testing.expectEqual(slow == 1, row.value & 0x10000000 != 0);
                try std.testing.expectEqual(slow == 2, row.value & 0x20000000 != 0);
            }
        }
    }
}
