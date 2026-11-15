const std = @import("std");
const assembler = @import("../assembler.zig");
const Chip = @import("../../chip.zig").Chip;
const corpus = @import("corpus_expected.zig");

const Result = struct {
    output: ?assembler.Output,
    diagnostic: ?assembler.Diagnostics,
};

fn assemble_case(comptime chip: Chip, comptime source: []const u8) Result {
    @setEvalBranchQuota(100_000);
    var diagnostic: ?assembler.Diagnostics = null;
    const output = assembler.assemble_impl(chip, source, &diagnostic, .{}) catch
        return .{ .output = null, .diagnostic = diagnostic };
    return .{ .output = output, .diagnostic = diagnostic };
}

fn check_case(comptime chip: Chip, comptime case: corpus.Case) !void {
    errdefer std.log.err("PIO corpus case '{s}' on {s}", .{ case.name, @tagName(chip) });
    const result = comptime assemble_case(chip, case.source);
    if (case.words) |expected| {
        const output = result.output orelse return error.ReferenceAccepted;
        var position: usize = 0;
        for (output.programs) |program| {
            if (position + program.instructions.len > expected.len) return error.InstructionCountMismatch;
            try std.testing.expectEqualSlices(u16, expected[position..][0..program.instructions.len], program.instructions);
            position += program.instructions.len;
        }
        try std.testing.expectEqual(expected.len, position);
    } else {
        if (result.output != null) return error.ReferenceRejected;
        const diagnostic = result.diagnostic orelse return error.MissingDiagnostic;
        try std.testing.expect(diagnostic.message.len > 0);
        try std.testing.expect(diagnostic.index <= case.source.len);
    }
}

test "pioasm differential corpus" {
    @setEvalBranchQuota(100_000);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@embedFile("corpus.json"), &hash, .{});
    try std.testing.expectEqualSlices(u8, &corpus.corpus_hash, &hash);
    var failures: usize = 0;
    inline for (corpus.cases) |case| {
        inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
            check_case(chip, case) catch {
                failures += 1;
            };
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
