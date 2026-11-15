//! Errata workarounds
//!
//! References:
//! * https://github.com/nordicsemi/nrfx/blob/nrfx-1.x/master/drivers/src/nrfx_usbd.c
//! * https://github.com/nordicsemi/nrfx/blob/nrfx-1.x/master/mdk/nrf52_erratas.h
//! * https://github.com/nrf-rs/nrf-usbd/blob/main/src/errata.rs

const microzig = @import("microzig");
const compatibility = microzig.hal.compatibility;

const version: enum {
    nrf52833,
    nrf52840,
} = switch (compatibility.chip) {
    .nrf52833 => .nrf52833,
    .nrf52840 => .nrf52840,
    else => compatibility.unsupported_chip("usbd"),
};

const Register = microzig.mmio.Mmio(packed struct(u32) { value: u32 });

inline fn reg(addr: usize) *volatile Register {
    return @ptrFromInt(addr);
}

pub fn pre_enable() void {
    if (errata_187_applies()) {
        if (reg(0x4006EC00).raw == 0x00000000) {
            reg(0x4006EC00).write_raw(0x00009375);
            reg(0x4006ED14).write_raw(0x00000003);
            reg(0x4006EC00).write_raw(0x00009375);
        } else {
            reg(0x4006ED14).write_raw(0x00000003);
        }
    }

    pre_wakeup();
}

pub fn post_enable() void {
    post_wakeup();

    if (errata_187_applies()) {
        if (reg(0x4006EC00).raw == 0x00000000) {
            reg(0x4006EC00).write_raw(0x00009375);
            reg(0x4006ED14).write_raw(0x00000000);
            reg(0x4006EC00).write_raw(0x00009375);
        } else {
            reg(0x4006ED14).write_raw(0x00000000);
        }
    }
}

pub fn pre_wakeup() void {
    if (errata_171_applies()) {
        if (reg(0x4006EC00).raw == 0x00000000) {
            reg(0x4006EC00).write_raw(0x00009375);
            reg(0x4006EC14).write_raw(0x000000C0);
            reg(0x4006EC00).write_raw(0x00009375);
        } else {
            reg(0x4006EC14).write_raw(0x000000C0);
        }
    }
}

pub fn post_wakeup() void {
    if (errata_171_applies()) {
        if (reg(0x4006EC00).raw == 0x00000000) {
            reg(0x4006EC00).write_raw(0x00009375);
            reg(0x4006EC14).write_raw(0x00000000);
            reg(0x4006EC00).write_raw(0x00009375);
        } else {
            reg(0x4006EC14).write_raw(0x00000000);
        }
    }
}

/// Anomaly 199, "USBD cannot receive tasks during DMA": in substance, USB tasks cannot be
/// used while an EasyDMA transfer is in progress. The workaround is to write 0x00000082 to
/// 0x40027C1C when a transfer is started, and 0 when it has completed. The register is not
/// in the product specification.
///
/// The address and the two values are those of nrfx v3.9.0 (commit
/// 85c444ee0b76272d8a074b82845f04e92b3253c4), drivers/src/nrfx_usbd.c,
/// `usbd_dma_pending_set` and `usbd_dma_pending_clear`; the anomaly's title is the one in
/// drivers/src/nrfx_usbd_errata.h of that release. The description above paraphrases
/// Nordic's online errata for the nRF52840 (rev. 3), which was not checked against the
/// PDF, so it is not Nordic's wording.
///
/// Called before the task that starts an EasyDMA transfer; nrfx's `usbd_dma_pending_set`
/// writes the same value at the same point.
pub fn dma_begin() void {
    if (errata_199_applies()) reg(0x40027C1C).write_raw(0x00000082);
}

/// Called only after ENDEPIN[n] / ENDEPOUT[n], per nRF52840 Revision 3 Errata,
/// anomaly 199, Workaround. A timeout retains the workaround and quarantines USBD.
pub fn dma_end() void {
    if (errata_199_applies()) reg(0x40027C1C).write_raw(0x00000000);
}

/// Applies to nRF52840
inline fn errata_171_applies() bool {
    return switch (version) {
        .nrf52840 => true,
        else => false,
    };
}

// Applies to:
// - nRF52833
// - nRF52840 0x01..0x05 and unknown future variants
inline fn errata_187_applies() bool {
    const variant = reg(0x10000134).raw;
    return switch (version) {
        .nrf52833 => true,
        .nrf52840 => variant != 0x00,
    };
}

/// Applies to nRF52840, every variant (nrfx's `nrf52_errata_199`); not to nRF52833
inline fn errata_199_applies() bool {
    return switch (version) {
        .nrf52840 => true,
        else => false,
    };
}

/// Disarm a data IN endpoint before its buffer or ownership is reused.
/// Exact sequence: Nordic nrfx v3.9.0, drivers/src/nrfx_usbd.c, usbd_ep_abort.
/// nRF52840 PS v1.1 does not document these registers. Explicit exception to
/// AGENTS.md rule 7 approved by David, 2026-11-15: "Use the exact disarm sequence".
/// Hardware validation pending. Caller serializes this indexed register pair.
pub fn disarm_in(ep: u3) void {
    const base = @intFromPtr(microzig.chip.peripherals.USBD);
    const selector = reg(base + 0x800);
    const data = reg(base + 0x804);
    selector.write_raw(0x7B6 + 2 * (@as(u32, ep) - 1));
    var temp: u8 = @truncate(data.raw);
    temp |= 1 << 1;
    data.write_raw(data.raw | temp);
    _ = data.raw;
}
