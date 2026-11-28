const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const rtt = b.addModule("rtt", .{
        .root_source_file = b.path("src/rtt.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = rtt });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run RTT host tests").dependOn(&run_tests.step);
}
