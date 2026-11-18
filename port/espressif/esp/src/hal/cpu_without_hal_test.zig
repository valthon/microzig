const std = @import("std");
const cpu = @import("esp-cpu");

// Stand in for microzig with no HAL. The CPU's interrupt types must not need one.
pub const hal = void;

test "CPU interrupt types can be imported without a HAL" {
    try std.testing.expectEqual(@as(u5, 31), @backingInt(cpu.Interrupt.interrupt31));
    try std.testing.expectEqual(@as(u1, 1), @backingInt(cpu.interrupt.Type.edge));
}
