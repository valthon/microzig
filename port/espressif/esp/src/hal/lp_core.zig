//! ESP32-C6 LP CPU control. TRM v1.2 §§3.7–3.9, 5.3.2, 12.10.1.
//! Reference: ESP-IDF components/ulp/lp_core/lp_core.c and hal/lp_core_ll.h.
//! HP owns configuration and loading; LP owns its sleep requests. Serialize
//! HP calls against interrupts and never reconfigure while LP is using PMU.
const microzig = @import("microzig");
const p = microzig.chip.peripherals;

pub const sram_base = 0x5000_0000;
pub const mailbox_base = 0x5000_3f00;
pub const image_limit = 0x3b00; // Leaves the linker's 1 KiB stack and 256 B mailbox.

pub const WakeSources = packed struct(u5) {
    hp_cpu: bool = true,
    uart: bool = false,
    io: bool = false,
    etm: bool = false,
    timer: bool = false,
};

/// Stop is asynchronous (TRM §3.9.2). Before overwriting a live image,
/// the HP caller must allow the sleep flow to complete; do not load from LP.
/// For cold boot no LP program has run yet. Interrupts must not race this call.
pub fn stop() void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    p.PMU.LP_CPU_PWR0.modify(.{ .LP_CPU_SLP_STALL_EN = 1, .LP_CPU_SLP_RESET_EN = 1 });
    p.PMU.LP_CPU_PWR1.write(.{ .LP_CPU_WAKEUP_EN = 0, .LP_CPU_SLEEP_REQ = 1 });
    fence();
}

/// Load only at cold boot or after stop's sleep flow has completed. The entire
/// LP SRAM is exclusively owned here, including mailbox; other RTC users must
/// relinquish it. Like IDF, clear BSS/mailbox before copying the raw binary.
pub fn load(binary: []const u8) error{InvalidImage}!void {
    if (binary.len < 0x84 or binary.len > image_limit) return error.InvalidImage;
    const memory: [*]volatile u8 = @ptrFromInt(sram_base);
    for (0..16 * 1024) |i| memory[i] = 0;
    for (binary, 0..) |byte, i| memory[i] = byte;
    fence();
}

/// Start after loading. LP clock selection stays at the boot configuration.
/// First wake must be HP-initiated (TRM §3.9.2); subsequent timer/ETM wakes
/// restart at +0x80. ETM channel routing is configured separately by hal.etm.
pub fn start(sources: WakeSources, poll_limit: u32) error{ InvalidSources, Timeout }!void {
    if (!sources.hp_cpu) return error.InvalidSources;
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    // TRM §5.3.2: LP SRAM low-speed access, required for LP execution in sleep.
    p.LP_AON.LPBUS.modify(.{ .FAST_MEM_MUX_SEL = 0, .FAST_MEM_MUX_SEL_UPDATE = 1 });
    var left = poll_limit;
    while (p.LP_AON.LPBUS.read().FAST_MEM_MUX_SEL_STATUS != 0) {
        if (left == 0) return error.Timeout;
        left -= 1;
    }
    // TRM §3.9.2; IDF lp_core_ll_stall_at_sleep_request/rst_at_sleep_enable.
    p.PMU.LP_CPU_PWR0.modify(.{ .LP_CPU_SLP_STALL_EN = 1, .LP_CPU_SLP_RESET_EN = 1 });
    p.PMU.LP_CPU_PWR1.write(.{ .LP_CPU_WAKEUP_EN = @as(u5, @bitCast(sources)), .LP_CPU_SLEEP_REQ = 0 });
    // TRM §3.9.1: the UART wake detector also has a peripheral enable.
    p.LP_PERI.MEM_CTRL.modify(.{ .UART_WAKEUP_EN = @intFromBool(sources.uart) });
    p.LP_PERI.CPU.modify(.{ .LPCORE_DBGM_UNAVALIABLE = 0 });
    wake();
}

/// TRM §3.9.3: HP software wake is a write trigger, not an RMW register.
pub fn wake() void {
    fence();
    p.PMU.HP_LP_CPU_COMM.write(.{ .HP_TRIGGER_LP = 1, .LP_TRIGGER_HP = 0 });
}

/// LP acknowledges the latched HP wake before sleeping, otherwise the wake
/// source remains asserted (TRM Table 3.9-1 and §12.10.1 PMU_LP_INT_CLR).
pub fn acknowledge_hp_wake() void {
    p.PMU.LP_INT_CLR.write(.{ .HP_SW_TRIGGER_INT_CLR = 1 });
}

/// TRM §§3.8–3.9; flag accessor matches IDF hal/lp_core_ll.h.
/// LP_AON_LPCORE flag layout is supplied by the vendor register definitions.
pub fn etm_wakeup_pending() bool {
    return p.LP_AON.LPCORE.read().ETM_WAKEUP_FLAG != 0;
}
pub fn acknowledge_etm_wake() void {
    // Flag-clear is WT and flag itself is W1C; never RMW this register.
    p.LP_AON.LPCORE.write(.{ .ETM_WAKEUP_FLAG_CLR = 1 });
}

/// LP only. Reset on wake reinitializes stack and BSS; mailbox survives.
pub fn halt() noreturn {
    fence();
    p.PMU.LP_CPU_PWR1.modify(.{ .LP_CPU_SLEEP_REQ = 1 });
    while (true) asm volatile ("wfi");
}

fn fence() void {
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
}

/// Single-producer/single-consumer, aligned 32-bit words, no AMO instructions:
/// TRM §3.7.1 permits atomic *instructions* only on HP SRAM. Each word has
/// exactly one writer; never increment a word from both cores. Publish payload
/// before sequence, then read sequence before payload. Sequence must not wrap
/// while a consumer is processing it. Reloading clears every word.
pub const Mailbox = struct {
    pub const Word = enum(u6) {
        command, // HP writer
        sequence, // LP writer, published after payload
        counter, // LP writer
        pad_level, // LP writer
        result, // LP writer
        detail, // LP writer
    };
    fn address(word: Word) *volatile u32 {
        return @ptrFromInt(mailbox_base + 4 * @as(usize, @backingInt(word)));
    }
    pub fn read(word: Word) u32 {
        const value = address(word).*;
        fence();
        return value;
    }
    pub fn write(word: Word, value: u32) void {
        fence();
        address(word).* = value;
    }
};
