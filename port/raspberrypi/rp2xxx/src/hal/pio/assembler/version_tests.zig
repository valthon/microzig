const std = @import("std");
const assembler = @import("../assembler.zig");
const Chip = @import("../../chip.zig").Chip;

fn reject(comptime chip: Chip, comptime source: []const u8, comptime message: []const u8) !void {
    const diagnostic = comptime blk: {
        @setEvalBranchQuota(100_000);
        var diagnostic: ?assembler.Diagnostics = null;
        _ = assembler.assemble_impl(chip, source, &diagnostic, .{}) catch break :blk diagnostic.?;
        @compileError("expected rejection: " ++ source);
    };
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message.slice(), message) != null);
    try std.testing.expect(diagnostic.index <= source.len);
}

test "target version defaults and program defines" {
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        const program = comptime assembler.assemble(chip, ".program probe\n.define public answer 42\nnop", .{}).get_program_by_name("probe");
        try std.testing.expectEqual(@as(u1, if (chip == .RP2350) 1 else 0), program.pio_version);
        try std.testing.expectEqual(@as(i64, 42), comptime program.get_define_by_name("answer"));
    }
}

test "version one instructions diagnose on RP2040 and explicit v0" {
    inline for (.{
        "irq prev set 1",     "irq next wait 1", "wait irq prev 1", "wait irq next 1",
        "wait jmppin",        "wait jmppin + 3", "mov pindirs, x",  "mov rxfifo[y], isr",
        "mov osr, rxfifo[0]",
    }) |instruction| {
        try reject(.RP2040, ".program probe\n" ++ instruction, "PIO version 1");
        try reject(.RP2350, ".program probe\n.pio_version 0\n" ++ instruction, "PIO version 1");
    }
    try reject(.RP2040, ".program probe\n.pio_version 1\nnop", "not supported on RP2040");
}

test "configuration validation diagnostics" {
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        inline for (.{
            .{ ".clock_div 0.5", "clock divider" },
            .{ ".clock_div 65536", "clock divider" },
            .{ ".set 6", ".set count" },
            .{ ".in 33", "pin count" },
            .{ ".out 33", "pin count" },
            .{ ".in 32 auto 0", "shift threshold" },
            .{ ".out 32 auto 33", "shift threshold" },
            .{ ".mov_status txfifo < 32", "mov_status index" },
            .{ ".mov_status rxfifo < 32", "mov_status index" },
            .{ ".pio_version 2", "PIO version must" },
        }) |case| try reject(chip, ".program probe\n" ++ case[0] ++ "\nnop", case[1]);
        inline for (.{ "txput", "txget", "putget" }) |fifo| {
            try reject(chip, ".program probe\n.pio_version 0\n.fifo " ++ fifo ++ "\nnop", "PIO version 1");
        }
        try reject(chip, ".program probe\n.pio_version 0\n.in 16\nnop", ".in count must be 32");
        try reject(chip, ".program probe\n.pio_version 0\n.mov_status irq set 0\nnop", "PIO version 1");
    }
    inline for (.{ "txput", "txget", "putget" }) |fifo| {
        try reject(.RP2350, ".program probe\n.fifo " ++ fifo ++ "\npush", "push requires");
        try reject(.RP2350, ".program probe\n.fifo " ++ fifo ++ "\n.in 16 auto\nnop", "autopush is incompatible");
    }
    try reject(.RP2350, ".program probe\n.mov_status irq next set 8\nnop", "mov_status index");
}
