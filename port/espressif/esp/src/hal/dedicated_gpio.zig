//! Eight CPU GPIO signals on C3 and C6, mapped through the GPIO matrix.
//! C6 TRM §1.14.5 (CSRs 0x803–0x805), §7.4–7.5 and table 7.11-1.
//! C3 TRM CPU GPIO CSRs and IO MUX/GPIO matrix use the same signal layout.
//! Call init() or connect() before direct CSR operations.
const microzig = @import("microzig");
const compatibility = @import("compatibility.zig");
const gpio = @import("gpio.zig");

/// Enable access without resetting active channels. C3 TRM registers
/// SYSTEM_CPU_PERI_CLK_EN_REG / SYSTEM_CPU_PERI_RST_EN_REG gate and reset
/// dedicated GPIO independently of the peripheral clock mask. C6 has no such
/// SYSTEM gate. Preserve other CPU peripherals, including ASSIST_DEBUG.
pub fn init() void {
    if (compatibility.chip == .esp32_c3) {
        const system = microzig.chip.peripherals.SYSTEM;
        system.CPU_PERI_CLK_EN.modify(.{ .CLK_EN_DEDICATED_GPIO = 1 });
        system.CPU_PERI_RST_EN.modify(.{ .RST_EN_DEDICATED_GPIO = 0 });
    }
}

/// Caller owns this CPU signal and pad exclusively. Connecting enables both
/// input and output; the output latch starts low. No allocation or global state.
pub fn connect(channel: u3, pin: gpio.Pin) void {
    init();
    const mask = @as(u8, 1) << channel;
    disable_output(mask);
    clear(mask);
    pin.apply(.{ .input_enable = true });
    pin.connect_input_to_peripheral(.{ .signal = @fromBackingInt(@as(u8, 28) + channel) });
    pin.connect_peripheral_to_output(.{
        .signal = @fromBackingInt(@as(u8, 28) + channel),
        .output_enable_signal_controlled_by_peripheral = true,
    });
    enable_output(mask);
}

/// CSR set/clear instructions preserve other channels atomically.
pub fn enable_output(mask: u8) void {
    asm volatile ("csrs 0x803, %[mask]"
        :
        : [mask] "r" (@as(u32, mask)),
        : .{ .memory = true });
}

pub fn disable_output(mask: u8) void {
    asm volatile ("csrc 0x803, %[mask]"
        :
        : [mask] "r" (@as(u32, mask)),
        : .{ .memory = true });
}

pub fn set(mask: u8) void {
    asm volatile ("csrs 0x805, %[mask]"
        :
        : [mask] "r" (@as(u32, mask)),
        : .{ .memory = true });
}

pub fn clear(mask: u8) void {
    asm volatile ("csrc 0x805, %[mask]"
        :
        : [mask] "r" (@as(u32, mask)),
        : .{ .memory = true });
}

/// Sample the routed pad inputs, independent of the output latch.
pub fn read() u8 {
    return @truncate(asm volatile ("csrr %[value], 0x804"
        : [value] "=r" (-> u32),
        :
        : .{ .memory = true }));
}

pub fn read_output() u8 {
    return @truncate(asm volatile ("csrr %[value], 0x805"
        : [value] "=r" (-> u32),
        :
        : .{ .memory = true }));
}
