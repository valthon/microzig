//! nRF52840 watchdog. Serialize configuration and start.
const microzig = @import("microzig");
const wdt = microzig.chip.peripherals.WDT;

pub const Config = struct {
    /// Nominal ticks of the 32.768 kHz clock (16 through 2^32).
    timeout_ticks: u33,
    run_in_sleep: bool = true,
    run_in_halt: bool = false,
    /// Bit n enables reload request register n.
    reload_registers: u8 = 1,
};

pub fn is_running() bool {
    return wdt.RUNSTATUS.read().RUNSTATUS == .Running;
}

/// Configure before start. PS v1.11 §6.36 gives timeout = (CRV + 1)/32768 s.
pub fn configure(config: Config) error{ AlreadyRunning, InvalidTimeout, NoReloadRegisters }!void {
    if (is_running()) return error.AlreadyRunning;
    if (config.timeout_ticks < 16 or config.timeout_ticks > 1 << 32) return error.InvalidTimeout;
    if (config.reload_registers == 0) return error.NoReloadRegisters;

    wdt.CRV.write(.{ .CRV = @intCast(config.timeout_ticks - 1) });
    wdt.CONFIG.write(.{
        .SLEEP = if (config.run_in_sleep) .Run else .Pause,
        .HALT = if (config.run_in_halt) .Run else .Pause,
    });
    wdt.RREN.write_raw(config.reload_registers);
}

/// The watchdog locks its configuration and runs until a reset that resets WDT.
pub fn start() void {
    wdt.TASKS_START.write(.{ .TASKS_START = .Trigger });
}

/// All enabled registers must request a reload before the counter reloads
/// (PS v1.11 §6.36.1).
pub fn reload(register: u3) void {
    wdt.RR[register].write(.{ .RR = .Reload });
}

/// For a single owner servicing every enabled reload register.
pub fn reload_enabled() void {
    const enabled: u8 = @truncate(wdt.RREN.raw);
    for (0..8) |index| {
        const register: u3 = @intCast(index);
        if (enabled & (@as(u8, 1) << register) != 0) reload(register);
    }
}
