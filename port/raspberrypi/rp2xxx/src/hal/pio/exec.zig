const std = @import("std");
const Chip = @import("../chip.zig").Chip;
const Instruction = @import("assembler/encoder.zig").Instruction;

const Scratch = enum { x, y };

pub fn set_scratch(comptime chip: Chip, pio: anytype, sm: anytype, destination: Scratch, value: u32) void {
    // PULL is a barrier/no-op with autopull and a full OSR (RP2040 §3.4.7.2,
    // RP2350 §11.4.7.2). Disable autopull so it always replaces the old OSR.
    const shiftctrl = &pio.get_sm_regs(sm).shiftctrl;
    const autopull = shiftctrl.read().AUTOPULL;
    shiftctrl.modify(.{ .AUTOPULL = 0 });
    defer shiftctrl.modify(.{ .AUTOPULL = autopull });

    pio.sm_write(sm, value);
    pio.sm_exec(sm, Instruction(chip){ .tag = .push_pull_mov_rx, .delay_side_set = 0, .payload = .{ .pull = .{
        .block = 1,
        .if_empty = 0,
    } } });
    pio.sm_exec(sm, Instruction(chip){ .tag = .mov, .delay_side_set = 0, .payload = .{ .mov = .{
        .destination = if (destination == .x) .x else .y,
        .operation = .none,
        .source = .osr,
    } } });
    // Leave the output shift count at 32 so the next OUT can autopull FIFO data
    // (RP2040 §3.5.4, RP2350 §11.5.4). Autopull stays disabled for this drain.
    pio.sm_exec(sm, Instruction(chip){
        .tag = .out,
        .delay_side_set = 0,
        .payload = .{
            .out = .{
                .destination = .null,
                .bit_count = 0, // 32 bits
            },
        },
    });
}

// Model the documented OSR/PULL behavior, including PULL's autopull barrier.
fn TestPio(comptime chip: Chip) type {
    return struct {
        const Self = @This();
        const ShiftCtrl = struct {
            AUTOPULL: u1,
            fn read(self: *ShiftCtrl) ShiftCtrl {
                return self.*;
            }
            fn modify(self: *ShiftCtrl, fields: anytype) void {
                self.AUTOPULL = fields.AUTOPULL;
            }
        };
        regs: struct { shiftctrl: ShiftCtrl },
        fifo: ?u32 = null,
        osr: u32 = 0xdeadbeef,
        shift_count: u6,
        pins: u32 = 0,
        pin_count: u6 = 0,
        x: u32 = 0,
        y: u32 = 0,

        fn get_sm_regs(self: *Self, _: u2) @TypeOf(&self.regs) {
            return &self.regs;
        }
        fn sm_write(self: *Self, _: u2, value: u32) void {
            std.debug.assert(self.fifo == null);
            self.fifo = value;
        }
        fn pull(self: *Self) void {
            self.osr = self.fifo.?;
            self.fifo = null;
            self.shift_count = 0;
        }
        fn sm_exec(self: *Self, _: u2, instruction: Instruction(chip)) void {
            switch (instruction.tag) {
                .push_pull_mov_rx => {
                    std.debug.assert(instruction.payload.pull.if_empty == 0);
                    if (self.regs.shiftctrl.AUTOPULL == 0 or self.shift_count == 32) self.pull();
                },
                .mov => {
                    std.debug.assert(instruction.payload.mov.source == .osr);
                    switch (instruction.payload.mov.destination) {
                        .x => self.x = self.osr,
                        .y => self.y = self.osr,
                        else => unreachable,
                    }
                },
                .out => {
                    const autopull = self.regs.shiftctrl.AUTOPULL == 1;
                    if (self.shift_count == 32 and autopull) self.pull();
                    const count: u6 = if (instruction.payload.out.bit_count == 0) 32 else instruction.payload.out.bit_count;
                    const bits = if (count == 32) self.osr else self.osr & ((@as(u32, 1) << @as(u5, @intCast(count))) - 1);
                    switch (instruction.payload.out.destination) {
                        .x => self.x = bits,
                        .y => self.y = bits,
                        .null => {},
                        .pins => {
                            self.pins |= bits << @as(u5, @intCast(self.pin_count));
                            self.pin_count += count;
                        },
                        else => unreachable,
                    }
                    self.osr = if (count == 32) 0 else self.osr >> @as(u5, @intCast(count));
                    self.shift_count = @min(32, self.shift_count + count);
                    if (autopull and self.shift_count == 32 and self.fifo != null) self.pull();
                },
                else => unreachable,
            }
        }
    };
}

test "set scratch replaces full or empty OSR with either autopull setting" {
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        for ([_]u1{ 0, 1 }) |autopull| {
            for ([_]bool{ false, true }) |empty| {
                inline for (.{ Scratch.x, Scratch.y }) |dest| {
                    var pio: TestPio(chip) = .{ .regs = .{ .shiftctrl = .{ .AUTOPULL = autopull } }, .shift_count = if (empty) 32 else 0 };
                    set_scratch(chip, &pio, @as(u2, 0), dest, 0x12345678);
                    try std.testing.expectEqual(@as(u32, 0x12345678), if (dest == .x) pio.x else pio.y);
                    try std.testing.expectEqual(@as(u32, 0), pio.osr);
                    try std.testing.expectEqual(@as(u6, 32), pio.shift_count);
                    try std.testing.expect(pio.fifo == null);
                    try std.testing.expectEqual(autopull, pio.regs.shiftctrl.AUTOPULL);
                }
            }
        }
    }
}

test "scratch initialization followed by FIFO output sends the command word" {
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        for ([_]u6{ 0, 32 }) |initial_shift_count| {
            var pio: TestPio(chip) = .{
                .regs = .{ .shiftctrl = .{ .AUTOPULL = 1 } },
                .shift_count = initial_shift_count,
            };
            set_scratch(chip, &pio, @as(u2, 0), .x, 31);
            set_scratch(chip, &pio, @as(u2, 0), .y, 63);
            const command: u32 = 0x12345678;
            pio.sm_write(0, command);
            // Both CYW43 drivers resume at OUT PINS, 1 with autopull enabled.
            for (0..32) |_| pio.sm_exec(0, .{
                .tag = .out,
                .delay_side_set = 0,
                .payload = .{ .out = .{ .destination = .pins, .bit_count = 1 } },
            });
            try std.testing.expectEqual(command, pio.pins);
            try std.testing.expectEqual(@as(u32, 31), pio.x);
            try std.testing.expectEqual(@as(u32, 63), pio.y);
            try std.testing.expect(pio.fifo == null);
            try std.testing.expectEqual(@as(u6, 32), pio.shift_count);
        }
    }
}
