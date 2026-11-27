//! Synchronous nRF52840 internal code flash access.
const microzig = @import("microzig");
const compatibility = @import("compatibility.zig");
const power = microzig.chip.peripherals.POWER;

const regs = switch (compatibility.chip) {
    .nrf52840 => microzig.chip.peripherals.NVMC,
    else => compatibility.unsupported_chip("NVMC"),
};

/// nRF52840 PS v1.11 §4.2.2, code flash geometry.
pub const page_size = 4096;
const flash_size = 1024 * 1024;
const erased_word = 0xffffffff;
const PofConfig = @TypeOf(power.POFCON.read());

pub const Error = error{ OutOfRegion, Unaligned, NotErased, PowerFailWarning, Timeout, VerifyFailed };

/// Absolute byte addresses in the half-open interval [start, end).
/// The caller owns the region and must exclude firmware and reserved flash.
/// Writes and erases disable the power-fail comparator (nRF52840 anomaly 242).
/// The supply must stay within the flash operating range. If the driver
/// cannot confirm that NVMC is idle in read mode, it leaves POF disabled.
/// Reset or confirm those conditions before re-enabling the comparator.
pub const Region = struct {
    start: usize,
    end: usize,

    pub fn read_word(region: Region, address: usize) Error!u32 {
        try region.check(address, @sizeOf(u32));
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        try wait_ready();
        return word_at(address).*;
    }

    /// Program one previously erased word. Erase the page before rewriting it.
    pub fn write_word(region: Region, address: usize, value: u32) Error!void {
        try region.check(address, @sizeOf(u32));
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();

        try wait_ready();
        const word = word_at(address);
        if (word.* != erased_word) return error.NotErased;
        if (value == erased_word) return;

        const pofcon = try suspend_power_fail_warning();
        // PS §4.3.1 and §4.3.7. Wait for NVMC before changing mode and after programming.
        regs.CONFIG.write(.{ .WEN = .Wen });
        try wait_ready();
        word.* = value;
        try restore_power_fail_warning(pofcon);
        if (word.* != value) return error.VerifyFailed;
    }

    /// Erase and verify one whole page contained in the region.
    pub fn erase_page(region: Region, address: usize) Error!void {
        try region.check(address, page_size);
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();

        // PS §4.3.2. CPU execution from flash stalls during erase.
        try wait_ready();
        const pofcon = try suspend_power_fail_warning();
        regs.CONFIG.write(.{ .WEN = .Een });
        try wait_ready();
        regs.ERASEPAGE.write(.{ .ERASEPAGE = address });
        try restore_power_fail_warning(pofcon);
        var offset: usize = 0;
        while (offset < page_size) : (offset += @sizeOf(u32)) {
            if (word_at(address + offset).* != erased_word) return error.VerifyFailed;
        }
    }

    fn check(region: Region, address: usize, size: usize) Error!void {
        if (region.end > flash_size or address < region.start or
            address > region.end or size > region.end - address) return error.OutOfRegion;
        if (address % size != 0) return error.Unaligned;
    }
};

// Anomaly 242: refuse pending POFWARN and mask the comparator for the write
// or erase. Leave the event for its owner to acknowledge.
fn suspend_power_fail_warning() Error!PofConfig {
    if (power.EVENTS_POFWARN.raw != 0) return error.PowerFailWarning;
    const original = power.POFCON.read();
    var disabled = original;
    disabled.POF = .Disabled;
    power.POFCON.write(disabled);
    // Catch a warning latched between the first check and disabling POF.
    if (power.EVENTS_POFWARN.raw != 0) {
        try restore_power_fail_warning(original);
        return error.PowerFailWarning;
    }
    return original;
}

fn restore_power_fail_warning(pofcon: PofConfig) Error!void {
    // Anomaly 242 protection must stay active until NVMC is idle in read mode.
    try wait_ready();
    regs.CONFIG.write(.{ .WEN = .Ren });
    try wait_ready();
    if (regs.CONFIG.read().WEN != .Ren) return error.VerifyFailed;
    power.POFCON.write(pofcon);
}

fn word_at(address: usize) *allowzero volatile u32 {
    return @ptrFromInt(address);
}

fn wait_ready() Error!void {
    // Bound polling even before the HAL timebase is initialized. The hardware flash
    // stall itself is governed by t_WRITE and t_ERASEPAGE (PS §4.3.8).
    for (0..1_000_000) |_| {
        if (regs.READY.read().READY == .Ready) return;
    }
    return error.Timeout;
}
