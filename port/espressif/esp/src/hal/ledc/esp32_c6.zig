//! ESP32-C6 LEDC: TRM v1.2 §35.3.2–35.3.4.
const std = @import("std");
const microzig = @import("microzig");
const LEDC = microzig.chip.peripherals.LEDC;

const clocks = @import("../clocks.zig");
const gpio = @import("../gpio.zig");
const system = @import("../system.zig");

pub const ClockSource = enum(u2) {
    pll_f80m_clk = 1,
    xtal_clk = 3,
};

/// Enables the LEDC peripheral and sets the clock source.
pub fn apply(clock_source: ClockSource) void {
    system.enable_clocks_and_release_reset(.{ .ledc = true });

    set_clock_source(clock_source);
}

/// Timers configuration is specific to a clock source. If changed, all active
/// timers must be reconfigured.
pub fn set_clock_source(clock_source: ClockSource) void {
    // C6 TRM v1.2 §35.3.2.1: functional source lives in PCR.
    microzig.chip.peripherals.PCR.LEDC_SCLK_CONF.modify(.{
        .LEDC_SCLK_SEL = @backingInt(clock_source),
        .LEDC_SCLK_EN = 1,
    });
}

pub fn get_clock_source() ClockSource {
    return @fromBackingInt(microzig.chip.peripherals.PCR.LEDC_SCLK_CONF.read().LEDC_SCLK_SEL);
}

pub fn timer(num: u2) Timer {
    return @fromBackingInt(num);
}

pub fn channel(num: u2) Channel {
    return @fromBackingInt(num);
}

inline fn comptime_fail_or_error(msg: []const u8, fmt_args: anytype, err: anytype) !void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(msg, fmt_args));
    } else {
        return err;
    }
}

pub const Timer = enum(u2) {
    timer0 = 0,
    timer1 = 1,
    timer2 = 2,
    timer3 = 3,

    pub const Config = struct {
        clock_config: clocks.Config,
        /// The frequency of the timer in Hz.
        frequency: u32,
        /// The number of precision bits for the timer. Takes values from 1 to 14.
        precision: u4,

        pub const Error = error{
            InvalidFrequency,
            InvalidPrecision,
        };

        fn resolve(config: Config, clock_source: ClockSource) Error!u18 {
            const src_freq = switch (clock_source) {
                .pll_f80m_clk => 80_000_000,
                .xtal_clk => clocks.xtal_clk_freq,
            };

            if (config.frequency == 0) try comptime_fail_or_error("frequency must be greater than 0", .{}, error.InvalidFrequency);

            if (config.precision <= 0 or config.precision > 14) try comptime_fail_or_error(
                "invalid precision: {} (must be greater than 0 and less than or equal to 14)",
                .{config.precision},
                error.InvalidPrecision,
            );

            const divider = (@as(u64, src_freq) << 8) / config.frequency / (@as(u64, 1) << config.precision);
            if (divider < 256) try comptime_fail_or_error("frequency too high: {}", .{config.frequency}, error.InvalidFrequency);
            if (divider > std.math.maxInt(u18)) try comptime_fail_or_error("frequency too low: {}", .{config.frequency}, error.InvalidFrequency);

            return @truncate(divider);
        }
    };

    /// Applies the configuration to the timer and validates it at comptime.
    /// Requires the clock source to be provided.
    pub fn apply(tim: Timer, comptime config: Config, comptime clock_source: ClockSource) void {
        const resolved_config = comptime config.resolve(clock_source) catch unreachable;
        apply_internal(tim, config, resolved_config);
    }

    /// Applies the configuration to the timer and returns an error if invalid.
    /// Doesn't require the clock source to be provided as it is fetched at
    /// runtime.
    pub fn apply_runtime(tim: Timer, config: Config) Config.Error!void {
        const clock_source = get_clock_source();
        const resolved_config = try config.resolve(clock_source);
        apply_internal(tim, config, resolved_config);
    }

    fn apply_internal(tim: Timer, config: Config, divider: u18) void {
        const regs = tim.get_regs();

        regs.conf.modify(.{
            .TIMER_DUTY_RES = config.precision,
            .CLK_DIV_TIMER = divider,
            .TIMER_PAUSE = 0,
            .TIMER_RST = 0,
            .TICK_SEL_TIMER = 0,
        });

        regs.conf.modify(.{
            .TIMER_PARA_UP = 1,
        });
    }

    inline fn get_regs(tim: Timer) *volatile extern struct {
        conf: @TypeOf(LEDC.TIMER0_CONF),
        value: @TypeOf(LEDC.TIMER0_VALUE),
    } {
        return switch (tim) {
            .timer0 => @ptrCast(@alignCast(&LEDC.TIMER0_CONF)),
            .timer1 => @ptrCast(@alignCast(&LEDC.TIMER1_CONF)),
            .timer2 => @ptrCast(@alignCast(&LEDC.TIMER2_CONF)),
            .timer3 => @ptrCast(@alignCast(&LEDC.TIMER3_CONF)),
        };
    }
};

pub const Channel = enum(u2) {
    channel0 = 0,
    channel1 = 1,
    channel2 = 2,
    channel3 = 3,

    pub const Config = struct {
        timer: Timer,
        initial_duty: u15 = 0,
    };

    /// Applies the configuration to the channel.
    pub fn apply(chan: Channel, config: Config) void {
        const regs = chan.get_regs();

        regs.hpoint.write(.{ .HPOINT_CH = 0 });
        regs.conf0.modify(.{
            .TIMER_SEL_CH = @backingInt(config.timer),
            .SIG_OUT_EN_CH = 1,
        });

        // also calls update()
        chan.set_duty(config.initial_duty);
    }

    /// Connects the channel to the provided pin.
    pub fn connect_pin(chan: Channel, pin: gpio.Pin) void {
        pin.connect_peripheral_to_output(.{
            .signal = switch (chan) {
                .channel0 => .ledc_ls_sig0,
                .channel1 => .ledc_ls_sig1,
                .channel2 => .ledc_ls_sig2,
                .channel3 => .ledc_ls_sig3,
            },
        });
    }

    /// Sets a constant duty cycle.
    pub fn set_duty(chan: Channel, duty: u15) void {
        // Load the duty through a single zero-scale range. DUTY_START and
        // PARA_UP must be asserted even for a fixed duty (TRM v1.2 §35.3.4.1,
        // §35.5 registers 35.1–35.2; ESP-IDF v5.2 ledc_set_duty/update_duty).
        chan.start_duty_fade(duty, .{ .increment = 0, .cycle = 1, .duration = 1 });
    }

    /// Starts a fade duty and waits for it to complete.
    pub fn fade_duty_blocking(chan: Channel, starting_duty: u15, options: DutyFadeOptions, timeout_us: u64) error{Timeout}!void {
        start_duty_fade(chan, starting_duty, options);
        const time = @import("../time.zig");
        const start = time.get_time_since_boot().to_us();
        while (!is_duty_fade_done(chan)) {
            if (time.get_time_since_boot().to_us() - start >= timeout_us) return error.Timeout;
        }
    }

    /// Starts a duty cycle fade.
    pub fn start_duty_fade(chan: Channel, starting_duty: u15, options: DutyFadeOptions) void {
        const regs = chan.get_regs();

        regs.duty.write(.{ .DUTY_CH = @as(u19, starting_duty) << 4 });

        switch (chan) {
            .channel0 => LEDC.INT_CLR.write(.{ .DUTY_CHNG_END_CH0_INT_CLR = 1 }),
            .channel1 => LEDC.INT_CLR.write(.{ .DUTY_CHNG_END_CH1_INT_CLR = 1 }),
            .channel2 => LEDC.INT_CLR.write(.{ .DUTY_CHNG_END_CH2_INT_CLR = 1 }),
            .channel3 => LEDC.INT_CLR.write(.{ .DUTY_CHNG_END_CH3_INT_CLR = 1 }),
        }

        // C6 TRM v1.2 §35.3.4.1: program one gamma range, then latch it.
        const gamma = chan.gamma_regs();
        // Match ESP-IDF v5.2 ledc_ll_set_fade_param_range's synchronization
        // workaround between the APB and LEDC clock domains.
        gamma.wr_addr.write(.{ .CH_GAMMA_WR_ADDR = 0 });
        microzig.hal.rom.delay_us(5);
        gamma.wr.write(.{
            .CH_GAMMA_DUTY_INC = @intFromBool(options.increment >= 0),
            .CH_GAMMA_DUTY_NUM = options.duration,
            .CH_GAMMA_DUTY_CYCLE = options.cycle,
            .CH_GAMMA_SCALE = @truncate(@abs(options.increment)),
        });
        gamma.wr_addr.write(.{ .CH_GAMMA_WR_ADDR = 0 });
        microzig.hal.rom.delay_us(5);
        chan.gamma_conf().write(.{ .CH_GAMMA_ENTRY_NUM = 1 });
        regs.conf1.write(.{ .DUTY_START_CH = 1 });

        chan.update();
    }

    /// Returns true if the previous duty cycle fade is complete.
    pub fn is_duty_fade_done(chan: Channel) bool {
        return switch (chan) {
            .channel0 => LEDC.INT_RAW.read().DUTY_CHNG_END_CH0_INT_RAW == 1,
            .channel1 => LEDC.INT_RAW.read().DUTY_CHNG_END_CH1_INT_RAW == 1,
            .channel2 => LEDC.INT_RAW.read().DUTY_CHNG_END_CH2_INT_RAW == 1,
            .channel3 => LEDC.INT_RAW.read().DUTY_CHNG_END_CH3_INT_RAW == 1,
        };
    }

    pub const DutyFadeOptions = struct {
        increment: i11,
        // Every `cycle` ticks the duty cycle is incremented by `increment`.
        cycle: u10,
        // The fade lasts for `duration` ticks.
        duration: u10,
    };

    fn gamma_regs(chan: Channel) *volatile extern struct {
        wr: @TypeOf(LEDC.CH0_GAMMA_WR),
        wr_addr: @TypeOf(LEDC.CH0_GAMMA_WR_ADDR),
        rd_addr: @TypeOf(LEDC.CH0_GAMMA_RD_ADDR),
        rd_data: @TypeOf(LEDC.CH0_GAMMA_RD_DATA),
    } {
        return switch (chan) {
            .channel0 => @ptrCast(&LEDC.CH0_GAMMA_WR),
            .channel1 => @ptrCast(&LEDC.CH1_GAMMA_WR),
            .channel2 => @ptrCast(&LEDC.CH2_GAMMA_WR),
            .channel3 => @ptrCast(&LEDC.CH3_GAMMA_WR),
        };
    }

    fn gamma_conf(chan: Channel) *volatile @TypeOf(LEDC.CH0_GAMMA_CONF) {
        return switch (chan) {
            .channel0 => @ptrCast(&LEDC.CH0_GAMMA_CONF),
            .channel1 => @ptrCast(&LEDC.CH1_GAMMA_CONF),
            .channel2 => @ptrCast(&LEDC.CH2_GAMMA_CONF),
            .channel3 => @ptrCast(&LEDC.CH3_GAMMA_CONF),
        };
    }

    fn update(chan: Channel) void {
        const regs = chan.get_regs();

        regs.conf0.modify(.{
            .PARA_UP_CH = 1,
        });
    }

    inline fn get_regs(chan: Channel) *volatile extern struct {
        conf0: @TypeOf(LEDC.CH0_CONF0),
        hpoint: @TypeOf(LEDC.CH0_HPOINT),
        duty: @TypeOf(LEDC.CH0_DUTY),
        conf1: @TypeOf(LEDC.CH0_CONF1),
        duty_r: @TypeOf(LEDC.CH0_DUTY_R),
    } {
        return switch (chan) {
            .channel0 => @ptrCast(@alignCast(&LEDC.CH0_CONF0)),
            .channel1 => @ptrCast(@alignCast(&LEDC.CH1_CONF0)),
            .channel2 => @ptrCast(@alignCast(&LEDC.CH2_CONF0)),
            .channel3 => @ptrCast(@alignCast(&LEDC.CH3_CONF0)),
        };
    }
};
