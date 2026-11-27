//! Seeed Studio XIAO nRF52840 Sense.
//!
//! Pins from Seeed's Arduino variant (Seeed-Studio/Adafruit_nRF52_Arduino,
//! variants/Seeed_XIAO_nRF52840_Sense/variant.cpp) and Zephyr's
//! boards/seeed/xiao_ble/xiao_ble_common.dtsi, which marks the LEDs active low.
//! USB is the chip's native USBD.
const microzig = @import("microzig");
const nrf = microzig.hal;
const gpio = nrf.gpio;

pub const led_active_state = 0;

pub const led1 = gpio.num(0, 26);
pub const led_r = led1;
pub const led2 = gpio.num(0, 30);
pub const led_g = led2;
pub const led3 = gpio.num(0, 6);
pub const led_b = led3;
pub const leds: []const gpio.Pin = &.{ led1, led2, led3 };

// D6 and D7 on the edge connector (Serial1 in Seeed's variant).
pub const uart_tx = gpio.num(1, 11);
pub const uart_rx = gpio.num(1, 12);

/// Puya P25Q16H, per Zephyr boards/seeed/xiao_ble/xiao_ble_common.dtsi.
/// The flash ID and density are specified in P25Q16H v2.1 §§10.35 and 2.
pub const flash_jedec_id = [3]u8{ 0x85, 0x60, 0x15 };
pub const flash_qspi_config: nrf.qspi.Config = .{
    // Zephyr boards/seeed/xiao_ble/xiao_ble-pinctrl.dtsi, qspi_default.
    .pins = .{
        .sck = gpio.num(0, 21),
        .csn = gpio.num(0, 25),
        .io0 = gpio.num(0, 20),
        .io1 = gpio.num(0, 24),
        .io2 = gpio.num(0, 22),
        .io3 = gpio.num(0, 23),
    },
    .capacity = 2 * 1024 * 1024,
    // P25Q16H v2.1 §10.15 (6Bh), §10.26 (32h) and §5.3 (AC characteristics).
    .sck_divider = 3, // 8 MHz
    .read_opcode = .READ4O,
    .write_opcode = .PP4O,
    // P25Q16H v2.1 §10.31 (ABh) and §5.3 (tRES1 max 8 µs).
    .deep_power_down_release_us = 8,
    // Allow margin above two 3 ms page programs and 20 ms erase (v2.1 §5.4).
    .transaction_timeout_us = 25_000,
    .flash_timeout_us = 50_000,
};

/// Enable quad I/O for this power cycle. Check the JEDEC ID before calling.
pub fn enable_flash_quad(flash: *nrf.qspi.QSPI) (nrf.qspi.Error || error{QuadEnableFailed})!void {
    // P25Q16H v2.1 §§10.4–10.5 and §10.8. Preserve protection bits while
    // setting QE (S9) with the volatile WRSR sequence.
    const qe = 1 << 1;
    try flash.wait_flash_ready();
    var high = [1]u8{0};
    try flash.custom_instruction(0x35, &high);
    if (high[0] & qe != 0) return;

    var low = [1]u8{0};
    try flash.custom_instruction(0x05, &low);
    var status = [2]u8{ low[0], high[0] | qe };
    try flash.custom_instruction(0x50, &.{});
    try flash.custom_instruction(0x01, &status);
    try flash.wait_flash_ready();
    high[0] = 0;
    try flash.custom_instruction(0x35, &high);
    if (high[0] & qe == 0) return error.QuadEnableFailed;
}

// Seeed's Sense variant.cpp D15–D18 and variant.h Wire1 map. Zephyr's
// xiao_ble_nrf52840_sense.dts supplies the address and active-high enable.
pub const imu_power_enable = gpio.num(1, 8);
pub const imu_scl = gpio.num(0, 27);
pub const imu_sda = gpio.num(0, 7);
pub const imu_int1 = gpio.num(0, 11);
pub const imu_address: nrf.i2c.Address = @fromBackingInt(0x6a);

// Seeed's Sense variant.cpp D19–D21. The same Zephyr board DTS marks the
// microphone enable active high and specifies S0H1 for both power pins.
pub const mic_power_enable = gpio.num(1, 10);
pub const mic_clk = gpio.num(1, 0);
pub const mic_data = gpio.num(0, 16);
/// The PDM edge the microphone drives, as the EDGE value that puts it in the
/// left (mono) slot. Its L/R pin is tied to ground (Seeed schematic v1.2,
/// sheet 3, MIC1); in stereo capture its samples land in the rising-edge slot
/// (measured on this board with the sense self-test).
pub const mic_edge: nrf.pdm.Edge = .LeftRising;

/// Resets into the Adafruit bootloader's UF2 mode (USB drive and CDC), as a
/// double-tap on reset does. The bootloader reads POWER.GPREGRET at start and
/// takes 0x57, DFU_MAGIC_UF2_RESET, as this request
/// (Adafruit_nRF52_Bootloader src/main.c). The reset is AIRCR.SYSRESETREQ with
/// the 0x05FA key (ARMv7-M Architecture Reference Manual, B3.2.6), framed by
/// DSBs and keeping PRIGROUP, as CMSIS's NVIC_SystemReset does, so the
/// GPREGRET write completes before the reset. Should the reset still not
/// happen, the bootloader fallback's watchdog lands the board in UF2 mode.
pub fn reboot_to_bootloader() noreturn {
    microzig.chip.peripherals.POWER.GPREGRET.write(.{ .GPREGRET = 0x57 });
    const scb = microzig.cpu.peripherals.scb;
    asm volatile ("dsb" ::: .{ .memory = true });
    scb.AIRCR.write(.{
        .VECTRESET = 0,
        .VECTCLRACTIVE = 0,
        .SYSRESETREQ = 1,
        .PRIGROUP = scb.AIRCR.read().PRIGROUP,
        .ENDIANNESS = 0,
        .VECTKEY = 0x05FA,
    });
    asm volatile ("dsb" ::: .{ .memory = true });
    while (true) {}
}

/// Arm in the root init hook before starting the HAL. A watchdog reset clears
/// GPREGRET and GPREGRET2 and leaves RESETREAS.DOG set (measured with xiao_probe).
/// Adafruit_nRF52_Bootloader leaves RESETREAS for the application. DOG or LOCKUP
/// requests UF2 entry unless RESETPIN is set (nRF52840 anomaly 136).
///
/// Adafruit_nRF52_Bootloader 0.6.1 src/main.c gives software-requested UF2 mode
/// 3 s to enumerate. With no host, a hung image can cycle through UF2 and back.
///
/// Requests a nominal timeout of 1 through 131,072,000 ms for a fresh watchdog.
/// A watchdog already running keeps its configuration and last reload, including
/// across a soft reset (measured). Service it with feed_bootloader_fallback.
/// Returns the boot reset flags observed before clearing them.
pub fn arm_bootloader_fallback(comptime timeout_ms: u32) nrf.power.ResetReason {
    const ticks = @as(u64, timeout_ms) * 32768 / 1000;
    if (ticks < 16 or ticks > 1 << 32)
        @compileError("bootloader fallback timeout must be between 1 and 131,072,000 ms");

    const reason = nrf.power.reset_reason();
    // RESETREAS accumulates across resets and is write-one-to-clear (PS v1.11,
    // POWER). Take ownership of the snapshot so the next boot sees fresh flags.
    nrf.power.clear_reset_reason(reason);
    if (reason.RESETPIN != .Detected and (reason.DOG == .Detected or reason.LOCKUP == .Detected))
        reboot_to_bootloader();

    nrf.wdt.configure(.{ .timeout_ticks = @intCast(ticks) }) catch |err| switch (err) {
        error.AlreadyRunning => return reason,
        error.InvalidTimeout, error.NoReloadRegisters => unreachable, // Checked above, with default RR0.
    };
    nrf.wdt.start();
    return reason;
}

/// Reload every enabled watchdog channel, including channels enabled by an
/// earlier image (nRF52840 PS v1.11 §6.36.1).
pub fn feed_bootloader_fallback() void {
    nrf.wdt.reload_enabled();
}

/// Retained progress word in the RAM excluded by the XIAO target in build.zig.
/// It follows the MBR's first eight bytes and lies below the Adafruit bootloader's
/// RAM at 0x20008000 and its double-reset word at 0x20007F7C (linker/nrf52840.ld
/// and src/main.c).
pub const breadcrumb: *volatile u32 = @ptrFromInt(0x20000008);
pub const breadcrumb_magic: u32 = 0xB12D_0000;

/// Records `stage` (16 bits) in the breadcrumb word.
pub fn mark(stage: u16) void {
    breadcrumb.* = breadcrumb_magic | stage;
}

pub fn init() void {
    for (leds) |led| {
        led.set_direction(.out);
        led.put(1);
    }
}
