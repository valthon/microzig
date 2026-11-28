const microzig = @import("microzig");
const cpu = microzig.cpu;
const time = microzig.drivers.time;

const peripherals = microzig.chip.peripherals;
const PFIC = peripherals.PFIC;
const RCC = peripherals.RCC;
const TIM2 = peripherals.TIM2;

/// Safely read the 64-bit SysTick counter (CNTH:CNTL).
///
/// This implements the standard double-read pattern to avoid race conditions:
/// 1. Read high register
/// 2. Read low register
/// 3. Read high register again
/// 4. If both high reads match, the value is consistent
/// 5. Otherwise, the low register rolled over between reads - retry
///
/// This ensures we never get a value where low has rolled over but we read the old high value.
inline fn read_stk_cnt() u64 {
    while (true) {
        const high1: u32 = PFIC.STK_CNTH.raw;
        const low: u32 = PFIC.STK_CNTL.raw;
        const high2: u32 = PFIC.STK_CNTH.raw;

        // If high didn't change, we have a consistent reading
        if (high1 == high2) {
            return (@as(u64, high1) << 32) | @as(u64, low);
        }
        // Otherwise low rolled over between reads, try again
    }
}

// TIM2 is dedicated to the boot clock. The ISR owns the high word.
var overflows: u64 = 0;
var timer_hz: u32 = 0;
var tick_numerator: u32 = 0;
var epoch_us: u64 = 0;
const us_per_second = 1_000_000;

/// Initialize SysTick as a free-running counter for delays.
///
/// This configures SysTick to run continuously without interrupts or auto-reload.
/// CNTH:CNTL together form a 64-bit counter that increments at HCLK rate.
/// NOTE: This must be called AFTER configuring the system clock to the final frequency.
fn init_delay_counter() void {
    // Configure SysTick for free-running mode (no interrupts, no auto-reload)
    PFIC.STK_CTLR.modify(.{
        // Turn on the system counter STK
        .STE = 1,
        // Disable counter interrupt
        .STIE = 0,
        // HCLK for time base (i.e. count 8x faster)
        .STCLK = 1,
        // Free-running (no auto-reload)
        .STRE = 0,
    });

    // Reset the count registers
    PFIC.STK_CNTL.raw = 0;
    PFIC.STK_CNTH.raw = 0;
}

/// Start the TIM2 boot clock and the free-running SysTick delay counter.
/// Boot time stays monotonic across reinitialization. TIM2 ticks between a
/// system clock switch and this call are scaled at the old rate, which can
/// skew elapsed time and deadlines spanning the switch.
pub fn init() void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();

    const clocks = microzig.hal.clocks.get_freqs();
    // CH32F/V20x_V30x_V31x RM §3.3.1: TIM2 gets PCLK1, doubled
    // when the PB1 divider is greater than one.
    const frequency = if (clocks.pclk1 == clocks.hclk) clocks.pclk1 else 2 * clocks.pclk1;
    asm volatile ("" ::: .{ .memory = true });
    if (timer_hz == frequency) return;

    if (timer_hz == 0) {
        init_delay_counter();
        RCC.APB1PCENR.raw |= 1 << 0;
    }
    TIM2.CTLR1.modify(.{ .CEN = 0 });
    TIM2.DMAINTENR.modify(.{ .UIE = 0 });
    // With CNT stopped and its ISR masked, include any pending wrap
    // before UG resets CNT and sets its own update flag (RM §15.4.1, §15.4.6).
    if (timer_hz != 0)
        epoch_us += ticks_to_us(sample_counter(TIM2, overflows), tick_numerator, timer_hz);
    overflows = 0;

    const divisor = @max(1, frequency / us_per_second);
    timer_hz = frequency;
    tick_numerator = divisor * us_per_second;
    TIM2.PSC.write(.{ .PSC = @intCast(divisor - 1) });
    // RM §15.4.10 and §15.4.13: use the full 16-bit up-counter period.
    TIM2.ATRLR.write_raw(0xffff);
    TIM2.SWEVGR.write(.{ .UG = 1 });
    TIM2.INTFR.write_raw(0);
    TIM2.DMAINTENR.modify(.{ .UIE = 1 });
    TIM2.CTLR1.modify(.{ .CEN = 1 });
    cpu.interrupt.enable(.TIM2);
    asm volatile ("" ::: .{ .memory = true });
}

/// TIM2 interrupt handler.
///
/// This should be registered in the chip default_interrupts
/// ```zig
/// pub const default_interrupts: microzig.cpu.InterruptOptions = .{
///    .TIM2 = time.tim2_handler,
/// };
/// ```
pub fn tim2_handler() callconv(cpu.riscv_calling_convention) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();

    if (TIM2.INTFR.read().UIF == 0) return;
    // RM §15.4.5: UIF is cleared by writing zero. TIM2 is reserved for timekeeping.
    TIM2.INTFR.write_raw(0);
    overflows +%= 1;
    asm volatile ("" ::: .{ .memory = true });
}

fn sample_counter(timer: anytype, high: u64) u64 {
    const pending_before = timer.INTFR.read().UIF != 0;
    var low = timer.CNT.read().CNT;
    const pending = pending_before or timer.INTFR.read().UIF != 0;
    // If the overflow followed the first flag read, sample CNT again so
    // the low word belongs to the same period as the pending update.
    if (pending and !pending_before) low = timer.CNT.read().CNT;
    return ((high +% @intFromBool(pending)) << 16) | low;
}

fn ticks_to_us(ticks: u64, numerator: u32, frequency: u32) u64 {
    if (numerator == frequency) return ticks;
    // Scale the quotient and remainder separately to avoid overflowing the product.
    return ticks / frequency * numerator + (ticks % frequency) * numerator / frequency;
}

/// Get the current time since boot. TIM2 must service every rollover
/// (about 65.5 ms apart at 1 MHz). One pending rollover is included
/// before its handler runs. Timeout guarantees require TIM2 IRQ service.
/// Do not mask TIM2 or global interrupts across a timed wait.
pub fn get_time_since_boot() time.Absolute {
    const snapshot = blk: {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();

        asm volatile ("" ::: .{ .memory = true });
        if (timer_hz == 0) return .from_us(0);
        const counter = .{
            .ticks = sample_counter(TIM2, overflows),
            .epoch = epoch_us,
            .numerator = tick_numerator,
            .frequency = timer_hz,
        };
        asm volatile ("" ::: .{ .memory = true });
        break :blk counter;
    };
    return .from_us(snapshot.epoch + ticks_to_us(snapshot.ticks, snapshot.numerator, snapshot.frequency));
}

/// Sleep for the specified number of milliseconds using the TIM2 boot clock.
pub fn sleep_ms(time_ms: u32) void {
    const deadline = get_time_since_boot().add_duration(time.Duration.from_ms(time_ms));
    while (deadline.is_reached_by(get_time_since_boot()) == false) {
        asm volatile ("" ::: .{ .memory = true });
    }
}

/// Sleep for the specified number of microseconds.
pub fn sleep_us(time_us: u64) void {
    // Busy-wait using the cycle counter in safe chunks to avoid overflow.
    var remaining = time_us;
    while (remaining > 0) {
        const chunk: u32 = @intCast(@min(remaining, 1_000_000)); // <= 1s per iteration
        delay_us(chunk);
        remaining -= chunk;
    }
}

/// Busy-wait for the specified number of microseconds using SysTick.
///
/// Uses SysTick as a free-running 64-bit counter. This provides:
/// - No interrupt conflicts (SysTick runs with no interrupts, TIM2 handles timing)
/// - 64-bit range (practically unlimited delays)
/// - Immune to interrupt latency (counter runs continuously)
/// - Direct hardware access, no wrapping concerns
pub fn delay_us(us: u32) void {
    if (us == 0) return;

    const freq: u32 = microzig.hal.clocks.get_sysclk();

    // SysTick counter runs at HCLK
    // Calculate ticks needed for the delay
    const ticks_per_us: u32 = freq / 1_000_000;
    const ticks: u64 = @as(u64, us) * @as(u64, ticks_per_us);

    // Read 64-bit counter using safe double-read pattern
    const start = read_stk_cnt();

    // Wait until enough ticks have elapsed
    while (true) {
        const current = read_stk_cnt();

        if (current - start >= ticks) break;
        asm volatile ("" ::: .{ .memory = true });
    }
}

/// Deadlines require TIM2 IRQ service as described by get_time_since_boot.
pub fn deadline_in_ms(time_ms: u32) microzig.drivers.time.Deadline {
    return .init_relative(get_time_since_boot(), .from_ms(time_ms));
}

/// Deadlines require TIM2 IRQ service as described by get_time_since_boot.
pub fn deadline_in_us(time_us: u64) microzig.drivers.time.Deadline {
    return .init_relative(get_time_since_boot(), .from_us(time_us));
}

/// Accept readiness only when its observation is followed by a clock sample
/// strictly before the deadline. The status flags carry no event timestamp.
/// A zero poll limit returns Timeout without polling.
pub fn wait_until_ready(
    context: anytype,
    comptime poll: anytype,
    deadline: anytype,
    comptime now: anytype,
    comptime poll_limit: ?u32,
) !void {
    if (comptime poll_limit == 0) return error.Timeout;

    var remaining: u32 = poll_limit orelse 0;
    while (true) {
        const ready = try poll(context);
        try deadline.check(now());
        if (ready) return;
        if (comptime poll_limit != null) {
            remaining -= 1;
            if (remaining == 0) return error.Timeout;
        }
    }
}

test "zero poll limit times out without polling" {
    const Fake = struct {
        fn poll(_: void) error{UnexpectedPoll}!bool {
            return error.UnexpectedPoll;
        }

        fn now() time.Absolute {
            return .from_us(0);
        }
    };
    const deadline = time.Deadline.init_relative(.from_us(0), .from_us(1));
    try @import("std").testing.expectError(error.Timeout, wait_until_ready({}, Fake.poll, deadline, Fake.now, 0));
}

test "TIM2 reinitialization preserves elapsed time and services a pending wrap" {
    const testing = @import("std").testing;

    try testing.expectEqual(0, get_time_since_boot().to_us());
    init();
    try testing.expectEqual(7, TIM2.PSC.read().PSC);
    try testing.expectEqual(1, TIM2.CTLR1.read().CEN);
    try testing.expectEqual(1, TIM2.DMAINTENR.read().UIE);
    try testing.expect(microzig.interrupt.enabled);

    TIM2.INTFR.raw = 1;
    tim2_handler();
    TIM2.CNT.raw = 3;
    PFIC.STK_CNTL.raw = 123;

    init();
    try testing.expectEqual(65_539, get_time_since_boot().to_us());
    try testing.expectEqual(3, TIM2.CNT.read().CNT);
    try testing.expectEqual(123, PFIC.STK_CNTL.raw);

    TIM2.INTFR.raw = 1;
    TIM2.CNT.raw = 7;
    microzig.hal.clocks.frequency = 48_000_000;
    init();
    try testing.expectEqual(47, TIM2.PSC.read().PSC);
    try testing.expectEqual(131_079, get_time_since_boot().to_us());
    // A pending IRQ delivered after the handoff must see the cleared flag.
    tim2_handler();
    TIM2.CNT.raw = 10;
    try testing.expectEqual(131_089, get_time_since_boot().to_us());
    try testing.expect(microzig.interrupt.enabled);
}

test "TIM2 snapshots count through delayed interrupt and pending rollover" {
    const Fake = struct {
        const Status = struct {
            before: u1,
            after: u1,
            reads: u2 = 0,

            fn read(status: *@This()) struct { UIF: u1 } {
                const pending = if (status.reads == 0) status.before else status.after;
                status.reads += 1;
                return .{ .UIF = pending };
            }
        };
        const Count = struct {
            before: u16,
            after: u16,
            reads: u2 = 0,

            fn read(count: *@This()) struct { CNT: u16 } {
                const value = if (count.reads == 0) count.before else count.after;
                count.reads += 1;
                return .{ .CNT = value };
            }
        };

        const Deadline = struct {
            expires_at: u64,

            fn check(deadline: @This(), current: u64) error{Timeout}!void {
                if (current >= deadline.expires_at) return error.Timeout;
            }
        };
        var active_timer: *@This() = undefined;

        INTFR: Status,
        CNT: Count,

        fn now() u64 {
            return sample_counter(active_timer, 0);
        }

        fn ready(_: void) error{}!bool {
            return true;
        }
    };

    const testing = @import("std").testing;
    var timer: Fake = .{
        .INTFR = .{ .before = 0, .after = 0 },
        .CNT = .{ .before = 10_123, .after = 0 },
    };
    // Over ten of the old 1 ms ticks elapsed without any ISR.
    try testing.expectEqual(10_123, sample_counter(&timer, 0));
    timer.INTFR.reads = 0;
    timer.CNT.reads = 0;
    Fake.active_timer = &timer;
    const deadline: Fake.Deadline = .{ .expires_at = 10_000 };
    try testing.expectError(error.Timeout, wait_until_ready({}, Fake.ready, deadline, Fake.now, null));

    timer = .{ .INTFR = .{ .before = 0, .after = 1 }, .CNT = .{ .before = 0xffff, .after = 2 } };
    try testing.expectEqual(65_538, sample_counter(&timer, 0));

    timer = .{ .INTFR = .{ .before = 1, .after = 1 }, .CNT = .{ .before = 3, .after = 0 } };
    try testing.expectEqual(65_539, sample_counter(&timer, 0));

    timer = .{ .INTFR = .{ .before = 0, .after = 0 }, .CNT = .{ .before = 4, .after = 0 } };
    try testing.expectEqual(65_540, sample_counter(&timer, 1));
    try testing.expectEqual(2000, ticks_to_us(2100, 21_000_000, 22_050_000));
}
