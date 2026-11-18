const std = @import("std");
const ConfigError = error{InvalidClkConfig};
const SOURCE_CLK_FREQ: u32 = 40_000_000;
const FILTER_THRESHOLD: u4 = 7;

pub const RecoveryStopStep = enum {
    scl_low,
    sda_low,
    scl_release,
    sda_release,
};

// After nine hardware clocks with SDA released, generate STOP via open-drain
// GPIO. SDA must rise while SCL is high (NXP UM10204 Rev. 7.0 section 3.1.4).
pub const recovery_stop_steps = [_]RecoveryStopStep{
    .scl_low, .sda_low, .scl_release, .sda_release,
};

test "bus recovery STOP releases SDA only after SCL is high" {
    var scl = true;
    var sda = true;
    var stops: usize = 0;
    for (recovery_stop_steps) |step| {
        const previous_sda = sda;
        switch (step) {
            .scl_low => scl = false,
            .sda_low => sda = false,
            .scl_release => scl = true,
            .sda_release => sda = true,
        }
        if (scl and sda != previous_sda) {
            // A falling SDA here would be an unintended START, not STOP.
            try std.testing.expect(sda);
            stops += 1;
        }
    }
    try std.testing.expect(scl and sda);
    try std.testing.expectEqual(@as(usize, 1), stops);
}

// Register values, in divided I2C_SCLK cycles (TRM v1.4, section 28.4.7).
pub const Timing = struct {
    divider: u8,
    low: u9,
    high: u9,
    wait_high: u7,
    sda_hold: u9,
    sda_sample: u9,
    setup: u9,
};

pub fn calculate_timing(source_clk: u32, apb_clk: u32, bus_freq: u32) ConfigError!Timing {
    if (bus_freq == 0 or source_clk == 0 or apb_clk == 0)
        return error.InvalidClkConfig;

    // Leave room for an asymmetric low phase in the 9-bit registers.
    const divider = @as(u64, source_clk) / (@as(u64, bus_freq) * 900) + 1;
    if (divider > 256)
        return error.InvalidClkConfig;
    const denominator = divider * bus_freq;
    // Empirical margin: the controller's 400 kHz capture measured ~404 kbit/s,
    // or ~98.8 cycles versus the TRM 28.4.7 formula's 100. Add two SCLK
    // cycles after rounding up. This is a measured correction, not a TRM rule.
    const period = (@as(u64, source_clk) + denominator - 1) / denominator + 2;
    if (period <= 22 or period > 902)
        return error.InvalidClkConfig;

    // NXP UM10204 Rev. 7.0 Table 11 (Table 10 in Rev. 6): minima in ns.
    const min_low_ns: u64 = if (bus_freq <= 100_000) 4700 else if (bus_freq <= 400_000) 1300 else 500;
    const min_high_ns: u64 = if (bus_freq <= 100_000) 4000 else if (bus_freq <= 400_000) 600 else 260;
    const ns_denominator = divider * 1_000_000_000;
    const min_low = (@as(u64, source_clk) * min_low_ns + ns_denominator - 1) / ns_denominator;
    const min_high = (@as(u64, source_clk) * min_high_ns + ns_denominator - 1) / ns_denominator;
    const low = @max(min_low, if (bus_freq <= 400_000) (period * 53 + 99) / 100 else period / 2);
    if (low >= period or low > 512)
        return error.InvalidClkConfig;
    const wait_high = @min(127, @max(FILTER_THRESHOLD + 1, (period - low) / 8));
    if (period - low <= wait_high + 2)
        return error.InvalidClkConfig;
    const high = period - low - wait_high - 2;
    const sample = wait_high + (high -| wait_high) / 2;
    // TRM 28.4.7 limit 2: 3*fSCLK <= (SDA_HOLD_TIME-4)*fAPB.
    const apb_denominator = divider * apb_clk;
    const min_hold = 4 + (3 * @as(u64, source_clk) + apb_denominator - 1) / apb_denominator;
    const sda_hold = @max(min_hold, low / 4);
    if (high > 511 or high + 1 < min_high or wait_high >= sample or sample >= high or sda_hold >= low - 1)
        return error.InvalidClkConfig;
    return .{
        .divider = @intCast(divider - 1),
        .low = @intCast(low - 1),
        .high = @intCast(high),
        .wait_high = @intCast(wait_high),
        .sda_hold = @intCast(sda_hold),
        .sda_sample = @intCast(sample),
        .setup = @intCast(low - 1),
    };
}

test "C3 timing respects empirical rate margin, I2C minima and APB hold limit" {
    for ([_]u32{ 10_000_000, 20_000_000, 40_000_000, 80_000_000 }) |apb| {
        for ([_]u32{ 1_000, 10_000, 80_000, 100_000, 400_000, 1_000_000 }) |frequency| {
            const timing = try calculate_timing(SOURCE_CLK_FREQ, apb, frequency);
            const period = @as(u64, timing.low) + timing.high + timing.wait_high + 3;
            const divider = @as(u64, timing.divider) + 1;
            try std.testing.expect(SOURCE_CLK_FREQ <= divider * (period - 2) * frequency);
            const min_low_ns: u64 = if (frequency <= 100_000) 4700 else if (frequency <= 400_000) 1300 else 500;
            const min_high_ns: u64 = if (frequency <= 100_000) 4000 else if (frequency <= 400_000) 600 else 260;
            try std.testing.expect((@as(u64, timing.low) + 1) * divider * 1_000_000_000 >= min_low_ns * SOURCE_CLK_FREQ);
            try std.testing.expect((@as(u64, timing.high) + 1) * divider * 1_000_000_000 >= min_high_ns * SOURCE_CLK_FREQ);
            try std.testing.expect(3 * @as(u64, SOURCE_CLK_FREQ) <= (@as(u64, timing.sda_hold) - 4) * divider * apb);
            try std.testing.expect(timing.wait_high < timing.sda_sample);
            try std.testing.expect(timing.sda_sample < timing.high);
        }
    }
    for ([_]u32{ 0, 1, 2_000_000, std.math.maxInt(u32) }) |frequency|
        try std.testing.expectError(error.InvalidClkConfig, calculate_timing(SOURCE_CLK_FREQ, 80_000_000, frequency));
    try std.testing.expectError(error.InvalidClkConfig, calculate_timing(SOURCE_CLK_FREQ, 0, 400_000));
    try std.testing.expectError(error.InvalidClkConfig, calculate_timing(SOURCE_CLK_FREQ, 1, 400_000));
}

const Opcode = enum(u4) {
    RSTART = 6,
    WRITE = 1,
    READ = 3,
    STOP = 2,
    END = 4,
};

pub const Command = union(enum) {
    start,
    stop,
    end,
    write: struct {
        /// Expected ACK value for transmitter
        ack_exp: Ack,
        /// Enable ACK checking
        ack_check_en: bool,
        /// Data length in bytes (1-255)
        length: u8,
    },
    read: struct {
        /// ACK value to send after byte received
        ack_value: Ack,
        /// Data length in bytes (1-255)
        length: u8,
    },

    /// Convert command to register value
    pub fn to_value(self: Command) u14 {
        var cmd: u14 = 0;

        switch (self) {
            .start, .stop, .end => {
                cmd = 0;
            },
            .write => |write| {
                cmd = @as(u14, write.length);
            },
            .read => |read| {
                cmd = @as(u14, read.length);
            },
        }

        // Set opcode
        const opcode: Opcode = switch (self) {
            .start => .RSTART,
            .stop => .STOP,
            .end => .END,
            .write => .WRITE,
            .read => .READ,
        };
        cmd |= @as(u14, @backingInt(opcode)) << 11;

        // Set ack_check_en bit
        if (self == .write and self.write.ack_check_en) {
            cmd |= 1 << 8;
        }

        // Set ack_exp bit
        const ack_exp = if (self == .write) self.write.ack_exp else .nack;
        if (ack_exp == .nack) {
            cmd |= 1 << 9;
        }

        // Set ack_value bit
        const ack_value = if (self == .read) self.read.ack_value else .nack;
        if (ack_value == .nack) {
            cmd |= 1 << 10;
        }

        return cmd;
    }
};

// Splitting trailing ACK reads is an implementation choice, not a TRM rule:
// ESP32-C3 TRM v1.4 section 28.5.8 step 17 permits a single READ M; END.
// Never encode byte_num = 0 (section 28.4.9).
pub fn read_commands(length: u8, will_continue: bool) [4]?Command {
    std.debug.assert(length > 0);
    var commands: [4]?Command = @splat(null);
    const ack_length = if (will_continue) length else length - 1;
    const tail = @min(ack_length, if (will_continue) @as(u8, 2) else 1);
    var idx: usize = 0;
    if (ack_length > tail) {
        commands[idx] = .{ .read = .{ .ack_value = .ack, .length = ack_length - tail } };
        idx += 1;
    }
    for (0..tail) |_| {
        commands[idx] = .{ .read = .{ .ack_value = .ack, .length = 1 } };
        idx += 1;
    }
    if (!will_continue)
        commands[idx] = .{ .read = .{ .ack_value = .nack, .length = 1 } };
    return commands;
}

test "READ commands have nonzero byte counts across FIFO and slice boundaries" {
    for (1..33) |length| {
        for ([_]bool{ false, true }) |continues| {
            var total: usize = 0;
            var nacks: usize = 0;
            for (read_commands(@intCast(length), continues)) |command| {
                if (command) |cmd| {
                    try std.testing.expect(cmd.read.length > 0);
                    total += cmd.read.length;
                    if (cmd.read.ack_value == .nack) nacks += 1;
                }
            }
            try std.testing.expectEqual(length, total);
            try std.testing.expectEqual(@as(usize, if (continues) 0 else 1), nacks);
        }
    }
}

const Ack = enum(u1) {
    ack = 0,
    nack = 1,
};
