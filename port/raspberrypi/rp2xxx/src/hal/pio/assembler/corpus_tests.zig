const std = @import("std");
const assembler = @import("../assembler.zig");
const Chip = @import("../../chip.zig").Chip;
const corpus = @import("corpus_expected.zig");

const Result = struct {
    output: ?assembler.Output,
    diagnostic: ?assembler.Diagnostics,
};

fn assemble_case(comptime chip: Chip, comptime source: []const u8) Result {
    @setEvalBranchQuota(1_000_000);
    var diagnostic: ?assembler.Diagnostics = null;
    const output = assembler.assemble_impl(chip, source, &diagnostic, .{}) catch
        return .{ .output = null, .diagnostic = diagnostic };
    return .{ .output = output, .diagnostic = diagnostic };
}

fn check_case(comptime chip: Chip, comptime case: corpus.Case) !void {
    errdefer std.log.err("PIO corpus case '{s}' on {s}", .{ case.name, @tagName(chip) });
    const result = comptime assemble_case(chip, ".pio_version " ++ (if (case.version == 0) "0" else "1") ++ "\n" ++ case.source);
    // SDK 2.1.1 omits the version check for IRQ MOV status. Preserve its
    // accepted oracle result but enforce the RP2350-only hardware contract.
    if (case.requires_v1 and case.version == 0) {
        try std.testing.expect(result.output == null);
        try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.?.message.slice(), "PIO version 1") != null);
        return;
    }
    if (case.words) |expected| {
        const output = result.output orelse return error.ReferenceAccepted;
        var position: usize = 0;
        try std.testing.expectEqual(output.programs.len, case.metadata.len);
        for (output.programs, case.metadata) |program, meta| {
            try std.testing.expectEqual(meta.pio_version, program.pio_version);
            try std.testing.expectEqual(meta.used_gpio_ranges, program.used_gpio_ranges);
            try std.testing.expectEqual(meta.origin, program.origin orelse -1);
            try std.testing.expectEqual(meta.wrap, if (program.wrap) |wrap| @as(i32, wrap) else @max(0, @as(i32, @intCast(program.instructions.len)) - 1));
            try std.testing.expectEqual(meta.wrap_target, program.wrap_target orelse 0);
            try std.testing.expectEqualDeep(meta.side_set, program.side_set);
            try std.testing.expectEqual(meta.config.fifo orelse .txrx, program.config.fifo orelse .txrx);
            const divider = program.config.clock_div orelse 1;
            try std.testing.expectEqual(meta.config.clock_div orelse 1, @trunc(divider * 256) / 256);
            inline for (.{ "mov_status", "in", "out", "set" }) |name| {
                if (@field(meta.config, name)) |value| {
                    try std.testing.expectEqualDeep(value, @field(program.config, name).?);
                }
            }
            if (position + program.instructions.len > expected.len) return error.InstructionCountMismatch;
            try std.testing.expectEqualSlices(u16, expected[position..][0..program.instructions.len], program.instructions);
            position += program.instructions.len;
        }
        try std.testing.expectEqual(expected.len, position);
    } else {
        if (result.output != null) return error.ReferenceRejected;
        const diagnostic = result.diagnostic orelse return error.MissingDiagnostic;
        try std.testing.expect(diagnostic.message.len > 0);
        try std.testing.expect(diagnostic.index <= case.source.len + 15);
    }
}

fn check_rp2040_rejection(comptime source: []const u8) !void {
    const result = comptime assemble_case(.RP2040, ".pio_version 1\n" ++ source);
    try std.testing.expect(result.output == null);
    try std.testing.expect(result.diagnostic.?.message.len > 0);
}

test "pioasm differential corpus" {
    @setEvalBranchQuota(1_000_000);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@embedFile("corpus.json"), &hash, .{});
    try std.testing.expectEqualSlices(u8, &corpus.corpus_hash, &hash);
    var failures: usize = 0;
    inline for (corpus.cases) |case| {
        inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
            if (comptime case.version == 1 and chip == .RP2040) {
                try check_rp2040_rejection(case.source);
                continue;
            }
            check_case(chip, case) catch {
                failures += 1;
            };
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
