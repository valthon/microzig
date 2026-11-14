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

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

pub fn pre_enable() void {
    if (errata_187_applies()) {
        if (reg(0x4006EC00).* == 0x00000000) {
            reg(0x4006EC00).* = 0x00009375;
            reg(0x4006ED14).* = 0x00000003;
            reg(0x4006EC00).* = 0x00009375;
        } else {
            reg(0x4006ED14).* = 0x00000003;
        }
    }

    pre_wakeup();
}

pub fn post_enable() void {
    post_wakeup();

    if (errata_187_applies()) {
        if (reg(0x4006EC00).* == 0x00000000) {
            reg(0x4006EC00).* = 0x00009375;
            reg(0x4006ED14).* = 0x00000000;
            reg(0x4006EC00).* = 0x00009375;
        } else {
            reg(0x4006ED14).* = 0x00000000;
        }
    }
}

pub fn pre_wakeup() void {
    if (errata_171_applies()) {
        if (reg(0x4006EC00).* == 0x00000000) {
            reg(0x4006EC00).* = 0x00009375;
            reg(0x4006EC14).* = 0x000000C0;
            reg(0x4006EC00).* = 0x00009375;
        } else {
            reg(0x4006EC14).* = 0x000000C0;
        }
    }
}

pub fn post_wakeup() void {
    if (errata_171_applies()) {
        if (reg(0x4006EC00).* == 0x00000000) {
            reg(0x4006EC00).* = 0x00009375;
            reg(0x4006EC14).* = 0x00000000;
            reg(0x4006EC00).* = 0x00009375;
        } else {
            reg(0x4006EC14).* = 0x00000000;
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
    if (errata_199_applies()) reg(0x40027C1C).* = 0x00000082;
}

/// Called when the wait for an EasyDMA transfer is over, and before any other USBD task:
/// after the transfer has ended (ENDEPIN[n] / ENDEPOUT[n]), and also after one that
/// `wait_easydma` gave up on, which may still be running (see `run_easydma` in usbd.zig).
/// The write is that of nrfx's `usbd_dma_pending_clear`.
pub fn dma_end() void {
    if (errata_199_applies()) reg(0x40027C1C).* = 0x00000000;
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
    const variant = @as(*volatile u32, @ptrFromInt(0x10000134)).*;
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
