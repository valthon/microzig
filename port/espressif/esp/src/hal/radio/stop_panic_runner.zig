//! Test runner for the Wi-Fi stop panics. `<runner> <test name> <message>`
//! runs the one test whose name ends with <test name> and exits 0 only if it
//! panics with exactly <message>.
const builtin = @import("builtin");
const std = @import("std");

/// Tests that must panic check for this declaration and skip without it.
pub const stop_panic_runner = {};

pub const panic = std.debug.FullPanic(check_panic);
pub const std_options: std.Options = .{ .log_level = .warn };

var expected_panic: []const u8 = "";

fn check_panic(message: []const u8, _: ?usize) noreturn {
    std.process.exit(if (expected_panic.len != 0 and std.mem.eql(u8, message, expected_panic)) 0 else 1);
}

var args_buffer: [4096]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) void {
    var fba: std.heap.FixedBufferAllocator = .init(&args_buffer);
    const args = init.args.toSlice(fba.allocator()) catch std.process.exit(3);
    if (args.len != 3) std.process.exit(3);
    std.testing.allocator_instance = .init(std.heap.page_allocator, .{});
    for (builtin.test_functions) |test_fn| {
        if (!std.mem.endsWith(u8, test_fn.name, args[1])) continue;
        expected_panic = args[2];
        test_fn.func() catch std.process.exit(4);
        std.process.exit(2); // returned without panicking
    }
    std.process.exit(5); // no such test
}
