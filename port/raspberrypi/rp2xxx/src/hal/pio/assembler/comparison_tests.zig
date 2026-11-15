const std = @import("std");
const assembler = @import("../assembler.zig");
const Chip = @import("../../chip.zig").Chip;

const c = @import("c");

fn pio_comparison(comptime source: []const u8) !void {
    inline for (comptime .{ Chip.RP2040, Chip.RP2350 }) |chip| {
        try pio_comparison_chip(chip, ".pio_version 0\n" ++ source);
    }
}

fn pio_comparison_chip(comptime chip: Chip, comptime source: []const u8) !void {
    @setEvalBranchQuota(100_000);
    const output = comptime assembler.assemble(chip, source, .{});
    try std.testing.expect(output.programs.len > 0);

    inline for (output.programs) |program| {
        inline for (program.defines) |define| {
            try std.testing.expectEqual(@field(c, program.name ++ "_" ++ define.name), define.value);
        }
        const expected_insns = @field(c, program.name ++ "_program_instructions");
        const expected_program = @field(c, program.name ++ "_program");
        try std.testing.expectEqual(expected_program.used_gpio_ranges, program.used_gpio_ranges);
        try std.testing.expectEqual(expected_program.pio_version, program.pio_version);
        try std.testing.expectEqual(expected_program.length, program.instructions.len);
        try std.testing.expectEqual(expected_program.origin, if (program.origin) |origin| @as(i32, origin) else -1);
        try std.testing.expectEqual(@field(c, program.name ++ "_wrap_target"), program.wrap_target orelse 0);
        try std.testing.expectEqual(@field(c, program.name ++ "_wrap"), program.wrap orelse program.instructions.len - 1);
        const config = @field(c, program.name ++ "_program_get_default_config")(0);
        if (program.config.in) |input| {
            try std.testing.expectEqual(config.in_count, input.count);
            try std.testing.expectEqual(config.in_right, input.right);
            try std.testing.expectEqual(config.autopush, input.auto);
            try std.testing.expectEqual(config.in_threshold, input.threshold);
        }
        if (program.config.out) |out| {
            try std.testing.expectEqual(config.out_count, out.count);
            try std.testing.expectEqual(config.out_right, out.right);
            try std.testing.expectEqual(config.autopull, out.auto);
            try std.testing.expectEqual(config.out_threshold, out.threshold);
        }
        if (program.config.set) |count| try std.testing.expectEqual(config.set_count, count);
        if (program.config.fifo) |fifo| try std.testing.expectEqual(config.fifo, @backingInt(fifo));
        if (program.config.mov_status) |status| {
            try std.testing.expectEqual(config.status_sel, switch (status.source) {
                .txfifo => @as(u32, 0),
                .rxfifo => 1,
                .irq => 2,
            });
            try std.testing.expectEqual(config.status_n, @as(u32, status.n) + @as(u32, @backingInt(status.block)) * 8);
        }
        if (program.config.clock_div) |div| {
            try std.testing.expectEqual(config.div_int, @as(u32, @intFromFloat(div)));
            try std.testing.expectEqual(config.div_frac, @as(u32, @intFromFloat((div - @trunc(div)) * 256)));
        }
        try std.testing.expectEqual(config.side_count, if (program.side_set) |side| @as(u32, side.count) + @intFromBool(side.optional) else 0);
        try std.testing.expectEqual(config.side_optional, if (program.side_set) |side| side.optional else false);
        try std.testing.expectEqual(config.side_pindirs, if (program.side_set) |side| side.pindir else false);

        for (program.instructions, expected_insns) |actual, expected| {
            std.log.debug("expected: 0x{x}", .{expected});
            std.log.debug("  actual: 0x{x}", .{actual});
            std.log.debug("", .{});
        }

        for (program.instructions, expected_insns) |actual, expected|
            try std.testing.expectEqual(expected, actual);
    }
}

test "pio.comparison.addition" {
    try pio_comparison(@embedFile("comparison_tests/addition.pio"));
}

test "pio.comparison.apa102" {
    try pio_comparison(@embedFile("comparison_tests/apa102.pio"));
}

test "pio.comparison.blink" {
    try pio_comparison(@embedFile("comparison_tests/blink.pio"));
}

test "pio.comparison.clocked_input" {
    try pio_comparison(@embedFile("comparison_tests/clocked_input.pio"));
}

test "pio.comparison.differential_manchester" {
    try pio_comparison(@embedFile("comparison_tests/differential_manchester.pio"));
}

test "pio.comparison.hello" {
    try pio_comparison(@embedFile("comparison_tests/hello.pio"));
}

test "pio.comparison.hub75" {
    try pio_comparison(@embedFile("comparison_tests/hub75.pio"));
}

test "pio.comparison.i2c" {
    try pio_comparison(@embedFile("comparison_tests/i2c.pio"));
}

test "pio.comparison.irq" {
    try pio_comparison_chip(.RP2350, @embedFile("comparison_tests/irq.pio"));
}

test "pio.comparison.manchester_encoding" {
    try pio_comparison(@embedFile("comparison_tests/manchester_encoding.pio"));
}

test "pio.comparison.movrx" {
    try pio_comparison_chip(.RP2350, @embedFile("comparison_tests/movrx.pio"));
}

test "pio.comparison.nec_carrier_burst" {
    try pio_comparison(@embedFile("comparison_tests/nec_carrier_burst.pio"));
}

test "pio.comparison.nec_carrier_control" {
    try pio_comparison(@embedFile("comparison_tests/nec_carrier_control.pio"));
}

test "pio.comparison.nec_receive" {
    try pio_comparison(@embedFile("comparison_tests/nec_receive.pio"));
}

test "pio.comparison.pio_serialiser" {
    try pio_comparison(@embedFile("comparison_tests/pio_serialiser.pio"));
}

test "pio.comparison.pwm" {
    try pio_comparison(@embedFile("comparison_tests/pwm.pio"));
}

test "pio.comparison.quadrature_encoder" {
    try pio_comparison(@embedFile("comparison_tests/quadrature_encoder.pio"));
}

test "pio.comparison.resistor_dac" {
    try pio_comparison(@embedFile("comparison_tests/resistor_dac.pio"));
}

test "pio.comparison.spi" {
    try pio_comparison(@embedFile("comparison_tests/spi.pio"));
}

test "pio.comparison.squarewave" {
    try pio_comparison(@embedFile("comparison_tests/squarewave.pio"));
}

test "pio.comparison.squarewave_fast" {
    try pio_comparison(@embedFile("comparison_tests/squarewave_fast.pio"));
}

test "pio.comparison.squarewave_wrap" {
    try pio_comparison(@embedFile("comparison_tests/squarewave_wrap.pio"));
}

test "pio.comparison.st7789_lcd" {
    try pio_comparison(@embedFile("comparison_tests/st7789_lcd.pio"));
}

test "pio.comparison.uart_rx" {
    try pio_comparison(@embedFile("comparison_tests/uart_rx.pio"));
}

test "pio.comparison.uart_tx" {
    try pio_comparison(@embedFile("comparison_tests/uart_tx.pio"));
}

test "pio.comparison.ws2812" {
    try pio_comparison(@embedFile("comparison_tests/ws2812.pio"));
}

// Headers generated with pico-sdk 2.1.1 pioasm -v 0 -o c-sdk.
test "pio.comparison.origin and wait irq rel" {
    @setEvalBranchQuota(100_000);
    try pio_comparison(@embedFile("comparison_tests/correctness.pio"));
    inline for (.{ Chip.RP2040, Chip.RP2350 }) |chip| {
        const program = comptime assembler.assemble(chip, @embedFile("comparison_tests/correctness.pio"), .{}).get_program_by_name("origin_four");
        try std.testing.expectEqual(@as(?i32, 4), program.origin);
        try std.testing.expectEqual(@as(?u5, c.origin_four_wrap), program.wrap);
        try std.testing.expectEqual(@as(?u5, c.origin_four_wrap_target), program.wrap_target);
        try std.testing.expectEqual(@as(?u5, c.origin_four_offset_loop), program.get_label_index("loop"));
    }
}

test "pio.comparison.grammar" {
    try pio_comparison(@embedFile("comparison_tests/grammar.pio"));
}

test "pio.comparison.config v1" {
    try pio_comparison_chip(.RP2350, @embedFile("comparison_tests/config_v1.pio"));
}
