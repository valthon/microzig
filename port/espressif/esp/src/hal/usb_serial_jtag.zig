const std = @import("std");
const microzig = @import("microzig");
// Both generated chip maps call this USB_DEVICE.
const USB_SERIAL_JTAG = microzig.chip.peripherals.USB_DEVICE;
const builtin = @import("builtin");
const host_test = builtin.is_test and builtin.target.os.tag != .freestanding;
const test_host = @import("usb_serial_jtag/test_host.zig");
const time = @import("time.zig");
const Deadline = microzig.drivers.time.Deadline;
const tx_clock = if (host_test) test_host else time;
const log_interrupt = if (host_test) test_host.interrupt else microzig.interrupt;
const log_state = @import("usb_serial_jtag/state.zig");

/// Destructive C3 reconnect experiment: discards pending CDC/JTAG transfers and
/// interrupt configuration. Serialize against all USB users, including logging.
/// Requires an already clocked controller, with PLL/APB suitable for USB (§30.4).
/// Keep detached for a host-visible interval AFTER this returns, then attach.
/// This is not a light-sleep state backup and does not preserve endpoint state.
pub const Reenumeration = struct {
    conf0: if (host_test) void else @TypeOf(USB_SERIAL_JTAG.CONF0.read()),

    pub fn detach_and_reset() Reenumeration {
        if (host_test) {
            test_host.reset_controller();
            return .{ .conf0 = {} };
        }
        @import("compatibility.zig").require_esp32_c3("USB re-enumeration experiment");
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        // C3 TRM v1.4 §30.6 reg 30.2: pad enable and pull override are
        // separate controls. Remove both pull-ups, not just pad functionality.
        const saved = USB_SERIAL_JTAG.CONF0.read();
        USB_SERIAL_JTAG.CONF0.modify(.{ .USB_PAD_ENABLE = 0, .PAD_PULL_OVERRIDE = 1, .DP_PULLUP = 0, .DM_PULLUP = 0 });
        const system = microzig.chip.peripherals.SYSTEM;
        // §16.3.5/§16.4, PERIP_CLK_EN0/PERIP_RST_EN0: USB_DEVICE reset;
        // §30.6 EP state registers expose status, not endpoint reset controls.
        // Same reset pulse as local ESP-IDF usb_serial_jtag_ll_reset_register.
        system.PERIP_CLK_EN0.modify(.{ .USB_DEVICE_CLK_EN = 1 });
        system.PERIP_RST_EN0.modify(.{ .USB_DEVICE_RST = 1 });
        system.PERIP_RST_EN0.modify(.{ .USB_DEVICE_RST = 0 });
        var detached = saved;
        detached.USB_PAD_ENABLE = 0;
        detached.PAD_PULL_OVERRIDE = 1;
        detached.DP_PULLUP = 0;
        detached.DM_PULLUP = 0;
        detached.DP_PULLDOWN = 0;
        detached.DM_PULLDOWN = 0;
        USB_SERIAL_JTAG.CONF0.write(detached);
        // Reset may restore pad defaults briefly; the disconnect interval
        // starts here, after the reset and the final pull/pad write.
        return .{ .conf0 = saved };
    }

    /// Restore the saved pads. With logger holding enabled, SYSTIMER unit 0
    /// must be running to timestamp the start of the hold.
    pub fn attach(self: Reenumeration) void {
        // Restore PHY selection, pin exchange, thresholds and pull policy.
        // C3 TRM v1.4 §30.6 register 30.2 (CONF0).
        // The bus clock is already enabled, as in IDF sleep_console.c restore.
        if (!host_test) USB_SERIAL_JTAG.CONF0.write(self.conf0);
        const reattach_logger = if (host_test) HeldTestLogger else logger;
        if (reattach_logger.hold_enabled) {
            const cs = log_interrupt.enter_critical_section();
            defer cs.leave();
            reattach_logger.start_hold();
        }
    }
};

/// Options for one Disconnect (begin to finish) or one reconnect().
pub const ReattachOptions = struct {
    /// Bound on the post-attach wait for a host bus reset. The wait runs with
    /// interrupts masked, and only when begin() counted a host as attached.
    bus_reset_timeout: microzig.drivers.time.Duration = .from_ms(1000),
    /// Caller-owned attachment history; pass the same handle to every
    /// Disconnect and reconnect() of the device. With a handle, a bus reset
    /// seen by the last wait also counts, and finish() records its result
    /// there. null: begin() counts a host only by an advancing SOF frame index
    /// or a pending bus reset. Back-to-back detaches then keep their wait only
    /// while the reset that finish() saw stays latched in INT_RAW: once an
    /// application USB interrupt handler clears USB_BUS_RESET, or one detach
    /// counts no host and skips its wait, every later back-to-back detach
    /// skips it too (see Attachment).
    attachment: ?*Attachment = null,
};

/// Attachment history for back-to-back detaches, owned by the caller and
/// passed through ReattachOptions.attachment. The SOF sample alone misses a
/// host that is still debouncing the attach or resetting the bus after the
/// previous re-attach (USB 2.0 §7.1.7.3), and sends no SOFs meanwhile. With a
/// handle, the last finish() result is sticky: a seen bus reset keeps the
/// host counted as attached until a wait times out, so an unplugged host costs
/// at most one bus_reset_timeout.
///
/// Limitation: the history starts empty. On the first detach after power-up,
/// or after the host attaches, a host still in its attach debounce shows no
/// SOF and no pending reset, so begin() counts no host and finish() neither
/// waits nor records anything; detaching again right away can keep the host
/// from ever resetting the bus. Before the first back-to-back detach, call
/// wait_for_host() with the same handle.
pub const Attachment = struct {
    /// The last bus reset wait that ran saw a reset, or wait_for_host() saw a
    /// host after it.
    reset_seen: bool = false,
};

fn host_present(attachment: ?*const Attachment, sof_advanced: bool, bus_reset_pending: bool) bool {
    const reset_seen = if (attachment) |history| history.reset_seen else false;
    return sof_advanced or bus_reset_pending or reset_seen;
}

/// wait_for_host()'s check: a SOF or a pending reset is a host, which the
/// handle then remembers as if a bus reset wait had seen it.
fn note_host(attachment: ?*Attachment, sof_advanced: bool, bus_reset_pending: bool) bool {
    if (!host_present(null, sof_advanced, bus_reset_pending)) return false;
    record(attachment, true);
    return true;
}

/// Records a finish() result; null (no wait ran) keeps the previous one.
fn record(attachment: ?*Attachment, reset_seen: ?bool) void {
    const history = attachment orelse return;
    if (reset_seen) |seen| history.reset_seen = seen;
}

test "an Attachment keeps a host that reset the bus until a wait times out" {
    var state: Attachment = .{};
    // No SOF, no pending reset and no history: no host, so no wait runs.
    try std.testing.expect(!host_present(&state, false, false));
    record(&state, null);
    // First sleep: SOFs seen, the wait sees a reset.
    try std.testing.expect(host_present(&state, true, false));
    record(&state, true);
    // Next sleep right after: the host is still enumerating and sends no SOF.
    try std.testing.expect(host_present(&state, false, false));
    record(&state, true);
    try std.testing.expect(host_present(&state, false, false));
    // Host unplugged: one wait times out, after which no wait runs.
    record(&state, false);
    try std.testing.expect(!host_present(&state, false, false));
    // A reset still pending in INT_RAW also counts as a host.
    try std.testing.expect(host_present(&state, false, true));
}

test "a host seen by wait_for_host makes the next Disconnect wait" {
    var state: Attachment = .{};
    // After boot: the host is still debouncing, nothing counts it yet.
    try std.testing.expect(!note_host(&state, false, false));
    try std.testing.expect(!host_present(&state, false, false));
    // A SOF or a pending reset is a host, and the handle remembers it.
    try std.testing.expect(note_host(&state, true, false));
    try std.testing.expect(host_present(&state, false, false));
    state = .{};
    try std.testing.expect(note_host(&state, false, true));
    try std.testing.expect(host_present(&state, false, false));
    // Without a handle the host is reported but not remembered.
    try std.testing.expect(note_host(null, true, false));
    // The history alone is not a host: wait_for_host must see the bus.
    state = .{ .reset_seen = true };
    try std.testing.expect(!note_host(&state, false, false));
}

test "without an Attachment only a SOF or a pending bus reset counts" {
    try std.testing.expect(!host_present(null, false, false));
    try std.testing.expect(host_present(null, true, false));
    try std.testing.expect(host_present(null, false, true));
    // A seen reset is not remembered without a handle.
    record(null, true);
    try std.testing.expect(!host_present(null, false, false));
}

/// C3/C6 soft detach state. C6 TRM v1.2 §32.7 CONF0 (register 32.3),
/// FRAM_NUM (32.17), INT_RAW/INT_ENA/INT_CLR (32.12/32.14/32.15) have the same pad,
/// pull-override, SOF and bus-reset fields used below. Preserve C6's additional
/// USB_JTAG_BRIDGE_EN bit along with all caller interrupt enables.
/// C3 TRM v1.4 §30.6 describes CONF0 (30.2) and INT_ENA (30.18).
/// Serialize the entire begin/finish interval against all
/// USB users; pending CDC/JTAG transfers may be lost. Masking interrupts alone
/// does not exclude a preempted logger owner. Quiesce logging and other TX
/// users before begin(), and keep them quiescent through finish().
/// Requires running PLL/APB clocks (C3 TRM v1.4 §30.4) and SYSTIMER unit 0.
pub const Disconnect = struct {
    conf0: if (host_test) struct { USB_PAD_ENABLE: u1 } else @TypeOf(USB_SERIAL_JTAG.CONF0.read()),
    int_ena: if (host_test) void else @TypeOf(USB_SERIAL_JTAG.INT_ENA.read()),
    options: ReattachOptions,
    /// begin() counted a host as attached, so finish() waits for a bus reset.
    host_attached: bool,

    /// Pads disabled by the application (CONF0.USB_PAD_ENABLE = 0) are left
    /// untouched: no register is written and finish() returns null.
    /// Otherwise detaches and holds the detach for 10 ms. A host counts as
    /// attached if a bus reset is pending in INT_RAW (C3 TRM v1.4 §30.6
    /// register 30.16), if options.attachment records a reset seen by the last
    /// wait (see Attachment), or else if the SOF frame index advances while
    /// it is sampled for up to 3 ms before the detach (§30.6 register 30.8; a
    /// full-speed host sends one SOF per 1 ms frame, USB 2.0 §8.4.3). The
    /// sampling is skipped when one of the first two already holds. A host
    /// that suspended the bus counts as absent unless the history holds, and
    /// a host still in its attach debounce counts as absent (see Attachment).
    pub fn begin(options: ReattachOptions) Disconnect {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        var saved: Disconnect = .{
            .conf0 = USB_SERIAL_JTAG.CONF0.read(),
            .int_ena = USB_SERIAL_JTAG.INT_ENA.read(),
            .options = options,
            .host_attached = false,
        };
        if (saved.conf0.USB_PAD_ENABLE == 0) return saved;
        const reset_pending = USB_SERIAL_JTAG.INT_RAW.read().USB_BUS_RESET_INT_RAW != 0;
        saved.host_attached = host_present(options.attachment, false, reset_pending);
        if (!saved.host_attached) {
            const frame = USB_SERIAL_JTAG.FRAM_NUM.read().SOF_FRAME_INDEX;
            const sof_deadline = Deadline.init_relative(time.get_time_since_boot(), .from_ms(3));
            while (!sof_deadline.is_reached_by(time.get_time_since_boot())) {
                if (USB_SERIAL_JTAG.FRAM_NUM.read().SOF_FRAME_INDEX != frame) {
                    saved.host_attached = host_present(options.attachment, true, reset_pending);
                    break;
                }
            }
        }
        USB_SERIAL_JTAG.INT_ENA.write_raw(0);
        // C3 TRM v1.4 Table 5.12-1 USB note; §30.6 register 30.2:
        // PHY_SEL=0, override=8, DP PU/PD=9/10, DM PU/PD=11/12,
        // pad enable=14. Pad disable alone leaves D+ pulled up.
        // esp-hal PR #6808 uses the same pull override for sleep:
        // https://github.com/esp-rs/esp-hal/pull/6808
        USB_SERIAL_JTAG.CONF0.modify(.{
            .PAD_PULL_OVERRIDE = 1,
            .DP_PULLUP = 0,
            .DM_PULLUP = 0,
            .DP_PULLDOWN = 1,
            .USB_PAD_ENABLE = 0,
        });
        time.sleep_ms(10);
        return saved;
    }

    /// Reattach after clocks are restored and return whether a fresh host bus
    /// reset arrived within the begin() options' bus_reset_timeout (§30.6
    /// registers 30.16/30.19). Returns null without waiting when begin() saw
    /// the pads disabled (nothing was changed) or counted no host (see begin).
    /// A wait's result is recorded in options.attachment when one was given:
    /// a seen reset makes later begin() calls count the host as attached, a
    /// timeout ends that. This does not prove CDC traffic works. Restores
    /// CONF0 and interrupt enables even on timeout. If the pads were restored,
    /// the logger hold starts after any bus-reset wait. Call once.
    pub fn finish(self: Disconnect) ?bool {
        if (self.conf0.USB_PAD_ENABLE == 0) return null;
        const cs = log_interrupt.enter_critical_section();
        defer cs.leave();
        defer if (!host_test) USB_SERIAL_JTAG.INT_ENA.write(self.int_ena);
        if (!host_test) {
            // ESP-IoT-Solution, "Using USB-Serial-JTAG pins as normal GPIO":
            // https://docs.espressif.com/projects/esp-iot-solution/en/latest/usb/usb_overview/usb_serial_jtag.html
            // begin() supplied override, D+ pulldown and the >=10 ms hold.
            // Clear stale reset evidence BEFORE enabling pads (§30.6 regs 30.16/19).
            USB_SERIAL_JTAG.INT_CLR.write(.{ .USB_BUS_RESET_INT_CLR = 1 });
            // That page's pad enable, D+ pull-down off and D+ pull-up on, folded
            // into one write: separate writes would leave the pad enabled with D+
            // pulled down (SE0) in between. §30.6 register 30.2 documents these as
            // independent R/W fields with no required write order.
            var attach = USB_SERIAL_JTAG.CONF0.read();
            attach.PHY_SEL = 0;
            attach.USB_PAD_ENABLE = 1;
            attach.DP_PULLDOWN = 0;
            attach.DP_PULLUP = 1;
            USB_SERIAL_JTAG.CONF0.write(attach);
            // Then release the override, restoring the saved pull policy.
            USB_SERIAL_JTAG.CONF0.write(self.conf0);
        }
        const reattach_logger = if (host_test) HeldTestLogger else logger;
        defer reattach_logger.start_hold();
        // §30.4: controller/CDC endpoints are self-initializing; there is no
        // firmware endpoint re-arm sequence. §30.3.2 FIFO flags determine readiness.
        // No peripheral reset here: preserve the caller's interrupt configuration.
        if (!self.host_attached) return null;
        const deadline = Deadline.init_relative(tx_clock.get_time_since_boot(), self.options.bus_reset_timeout);
        while (true) {
            const reset_pending = if (host_test) test_host.bus_reset_pending() else USB_SERIAL_JTAG.INT_RAW.read().USB_BUS_RESET_INT_RAW != 0;
            if (reset_pending) break;
            if (deadline.is_reached_by(tx_clock.get_time_since_boot())) {
                record(self.options.attachment, false);
                return false;
            }
        }
        record(self.options.attachment, true);
        // Leave fresh reset pending for the caller's restored interrupt handler.
        return true;
    }
};

/// Waits until the SOF frame index advances (C3 TRM v1.4 §30.6 register
/// 30.8) or a bus reset is pending in INT_RAW (register 30.16), then returns
/// true and records the host in attachment (when given) so that the next
/// Disconnect counts it and waits for its bus reset. A reset latched by an
/// earlier enumeration counts even if that host has since left; the next
/// Disconnect then costs one bus_reset_timeout. Returns false when the
/// timeout expires (recording nothing), and at once when the application
/// disabled the pads (CONF0.USB_PAD_ENABLE = 0). Call it after
/// boot or attach, before back-to-back detaches or sleeps with
/// .disconnect_and_reenumerate: a host still in its attach debounce sends
/// neither (see Attachment). A reset already cleared by the caller's USB
/// interrupt handler is not seen; the SOF check still is. Interrupts stay
/// enabled; requires active USB clocks and SYSTIMER unit 0. C6 register
/// references: TRM v1.2 §32.7 registers 32.3, 32.12, 32.17.
pub fn wait_for_host(timeout: microzig.drivers.time.Duration, attachment: ?*Attachment) bool {
    if (USB_SERIAL_JTAG.CONF0.read().USB_PAD_ENABLE == 0) return false;
    const frame = USB_SERIAL_JTAG.FRAM_NUM.read().SOF_FRAME_INDEX;
    const deadline = Deadline.init_relative(time.get_time_since_boot(), timeout);
    while (true) {
        const sof_advanced = USB_SERIAL_JTAG.FRAM_NUM.read().SOF_FRAME_INDEX != frame;
        const reset_pending = USB_SERIAL_JTAG.INT_RAW.read().USB_BUS_RESET_INT_RAW != 0;
        if (note_host(attachment, sof_advanced, reset_pending)) return true;
        if (deadline.is_reached_by(time.get_time_since_boot())) return false;
    }
}

/// Recover USB without sleeping. Close/reopen the host port after detach.
/// Returns bus-reset evidence (null: pads disabled or no host counted, see
/// Disconnect.begin), not proof of enumeration or working IN/OUT.
/// Serialize against all USB users; requires active USB clocks and SYSTIMER.
pub fn reconnect(options: ReattachOptions) ?bool {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    const disconnected = Disconnect.begin(options);
    return disconnected.finish();
}

// EP1/EP1_CONF FIFO registers: C3 TRM v1.4 §30.6 registers 30.1/30.6,
// C6 TRM v1.2 §32.7 registers 32.1/32.2.

/// Returns `false` if data can be sent.
pub fn tx_fifo_full() bool {
    if (host_test) return test_host.full();
    return USB_SERIAL_JTAG.EP1_CONF.read().SERIAL_IN_EP_DATA_FREE == 0;
}

/// Call this after you are done writing data. After `tx_fifo_full()` returns false
/// you can start sending more data.
pub fn tx_fifo_flush() void {
    if (host_test) return test_host.flush();
    USB_SERIAL_JTAG.EP1_CONF.write(.{ .WR_DONE = 1 });
}

/// Writes one byte to the fifo.
pub fn tx_fifo_write(byte: u8) void {
    if (host_test) return test_host.write(byte);
    USB_SERIAL_JTAG.EP1.write(.{
        .RDWR_BYTE = byte,
    });
}

/// Returns true while the OUT endpoint contains unread bytes.
/// C3 TRM v1.4 §30.3.2; C6 TRM v1.2 §32.3.2: identical EP1 FIFO protocol.
pub fn rx_fifo_available() bool {
    return USB_SERIAL_JTAG.EP1_CONF.read().SERIAL_OUT_EP_DATA_AVAIL != 0;
}

/// Caller must first check rx_fifo_available(). Reading consumes one byte.
pub fn rx_fifo_read() u8 {
    return USB_SERIAL_JTAG.EP1.read().RDWR_BYTE;
}

/// Reads up to buffer.len bytes without waiting. Returns zero when no data is ready.
/// RX must have a single consumer; do not also read the FIFO from an interrupt.
pub fn read(buffer: []u8) usize {
    var n: usize = 0;
    while (n < buffer.len and rx_fifo_available()) : (n += 1) {
        buffer[n] = rx_fifo_read();
    }
    return n;
}

/// Waits for at least one byte, then returns the currently available data.
/// An empty buffer returns immediately. Uses one deadline for the entire wait.
pub fn read_blocking(buffer: []u8, deadline: Deadline) error{Timeout}!usize {
    if (buffer.len == 0) return 0;
    while (true) {
        const n = read(buffer);
        if (n != 0) return n;
        if (deadline.is_reached_by(time.get_time_since_boot())) return error.Timeout;
    }
}

const TxWait = struct {
    deadline: Deadline,
    pub fn full(_: *TxWait) bool {
        return tx_fifo_full();
    }
    pub fn expired(self: *TxWait) bool {
        return self.deadline.is_reached_by(tx_clock.get_time_since_boot());
    }
    pub fn release_stuck(_: *TxWait) void {
        release_stuck_tx();
    }
};

fn wait_for_tx(deadline: Deadline) error{Timeout}!void {
    var wait: TxWait = .{ .deadline = deadline };
    try log_state.wait_for_tx(&wait);
}

/// Re-commits the IN buffer (WR_DONE) while SERIAL_IN_EP_DATA_FREE reads 0.
/// DATA_FREE stays 0 after a flush "until data in UART TX FIFO is read by the
/// USB Host" (C6 TRM v1.2 §32.7 register 32.2; C3 TRM v1.4 register 30.6).
/// No TRM text describes a DATA_FREE that stays 0 with nothing committed;
/// the cause and this remedy are empirical (C6 bench observations, see the
/// port README). Callers write it only after reading DATA_FREE as 0. If the
/// host reads the buffer between that read and this write, WR_DONE commits
/// an empty buffer and a zero-length packet goes out, which CDC ACM hosts
/// ignore. Our writers flush every packet they write, so it never commits a
/// partial packet of ours.
fn release_stuck_tx() void {
    tx_fifo_flush();
}

var boot_tx_checked = false;

/// Before the first write after boot, release an IN buffer that was already
/// stuck at boot (see release_stuck_tx), so that write is not lost to it.
fn release_stuck_tx_at_boot() void {
    const cs = log_interrupt.enter_critical_section();
    defer cs.leave();
    if (boot_tx_checked) return;
    boot_tx_checked = true;
    if (tx_fifo_full()) release_stuck_tx();
}

/// Success means the host consumed every flushed packet, including the final one.
/// A host can consume packets before an application opens the port.
/// Timeout means the host did not consume a packet before the deadline.
/// A timeout can follow partial delivery; retrying the whole slice may duplicate data.
/// A timed-out wait re-commits the IN buffer for the host (release_stuck_tx).
/// Serialize TX callers. Masking interrupts does not exclude a preempted logger:
/// quiesce logging before using this API. The deadline covers the whole write.
pub fn write_blocking(data: []const u8, deadline: Deadline) error{Timeout}!usize {
    if (data.len == 0) return 0;
    release_stuck_tx_at_boot();
    try wait_for_tx(deadline);
    var offset: usize = 0;
    while (offset < data.len) {
        const packet = data[offset..][0..@min(64, data.len - offset)];
        commit_packet(packet);
        try wait_for_tx(deadline);
        offset += packet.len;
    }
    return data.len;
}

fn commit_packet(packet: []const u8) void {
    for (packet) |byte| tx_fifo_write(byte);
    // The 64th byte flushes automatically (C3 TRM v1.4 §30.3.2; C6 TRM v1.2 §32.3.2).
    if (packet.len < 64) tx_fifo_flush();
}

/// Buffered writer with bounded host-consumption waits. Inspect err after WriteFailed.
/// Each drain sends at most one 64-byte packet and gets one timeout, or the
/// shared `deadline` when set. A reservation that needs room sends packets the
/// same way until the moved bytes fit in the sent prefix. No failed bytes are
/// retained for a later message. Only the logger holds lines for a port open.
pub const Writer = struct {
    const tx_vtable: std.Io.Writer.VTable = .{ .drain = drain, .rebase = rebase };

    interface: std.Io.Writer,
    storage: []u8,
    timeout: microzig.drivers.time.Duration = .from_ms(100),
    /// When set, every drain uses this deadline instead of `timeout`.
    deadline: ?Deadline = null,
    err: ?error{Timeout} = null,

    pub fn init(buffer: []u8) Writer {
        return .{
            .interface = .{ .buffer = buffer, .vtable = &tx_vtable },
            .storage = buffer,
        };
    }

    /// Discards buffered bytes and restores the full buffer that drains shorten.
    pub fn discard(self: *Writer) void {
        self.interface = .{ .buffer = self.storage, .vtable = &tx_vtable };
    }

    fn send_packet(self: *Writer, bytes: []const u8) std.Io.Writer.Error!usize {
        const deadline = self.deadline orelse Deadline.init_relative(tx_clock.get_time_since_boot(), self.timeout);
        self.err = null;
        return write_blocking(bytes[0..@min(64, bytes.len)], deadline) catch |err| {
            self.discard();
            self.err = err;
            return error.WriteFailed;
        };
    }

    fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        // Send until the reservation fits and the bytes to move are no more
        // than the sent prefix they move into, so relocation stays linear in
        // bytes sent; only the `preserve` bytes may be moved unsent.
        while (w.end > preserve) {
            const consumed = w.buffer.ptr - self.storage.ptr;
            if (self.storage.len - w.end >= capacity and w.end <= consumed) break;
            const n = try self.send_packet(w.buffer[0 .. w.end - preserve]);
            w.buffer = w.buffer[n..];
            w.end -= n;
        }
        @memmove(self.storage[0..w.end], w.buffered());
        w.buffer = self.storage;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        if (w.end != 0) {
            const n = try self.send_packet(w.buffered());
            w.end -= n;
            w.buffer = if (w.end == 0) self.storage else w.buffer[n..];
            return 0; // Only bytes consumed from data count toward the result.
        }
        for (data, 0..) |bytes, i| {
            if (i == data.len - 1 and splat == 0) break;
            if (bytes.len == 0) continue;
            return self.send_packet(bytes);
        }
        return 0;
    }
};

/// USB Serial/JTAG logger. Use `.logFn = logger.log` in std_options.
/// At boot the first unmasked log call commits the IN buffer immediately,
/// whether empty or holding an earlier packet. If the host is already
/// reading, that call waits for settle and sends queued lines and its own.
/// After HAL reattach, the probe waits for an unmasked call at least 100 ms
/// into the hold. Lines logged in that window stay queued until such a call.
/// Disconnect.finish starts that hold after any bus-reset wait.
/// While a probe is pending, an unmasked call re-commits a still-full buffer
/// at least 500 ms after the last commit. Each unmasked probe poll
/// gives it up to 2 ms to drain. The 100 ms settle starts when a log call
/// records the drain under the critical section.
/// Unmasked callers can finish the wait and replay queued lines before
/// sending their own. Both waits leave the writer free so masked calls
/// can queue without touching the FIFO.
/// In the Windows diagnostic on C3 and C6, delayed empty commits stayed
/// pending with the port closed and drained after open.
/// Linux cdc-acm.c submits bulk IN read URBs in acm_port_activate at tty open.
/// The HAL option usb_serial_jtag_log_hold_size sets the queue budget
/// (2048 bytes by default, zero for immediate writes).
///
/// Waits for the host run with the caller's interrupt state. The logger uses
/// short critical sections for hold decisions, writer ownership and counters.
/// Each drain waits at most 2 ms. A caller that already has
/// interrupts masked, or is in a nested interrupt handler, shares one
/// 2 ms deadline across a direct write, plus formatting and FIFO writes.
/// A line from an interrupt handler or preempting task is dropped and
/// counted while another caller holds the writer, including during queue
/// formatting. Overflow keeps earlier queued lines and counts the dropped
/// line. A TX timeout during normal logging starts a new hold, including
/// when the host stops reading after boot. The logger stages a line that
/// fits before its first send and retains those bytes if no packet commits.
/// A line that exceeds the queue streams directly and counts as lost on
/// timeout. Unmasked calls
/// sample for drain without polling and re-commit a still-full buffer at the
/// same 500 ms interval. At zero hold size or in panic, the stalled path
/// drops subsequent lines without waiting until the FIFO is writable.
/// Observing the drain starts the same settle delay before replay.
/// A host that never reads keeps the queue on hold. A failed line that
/// committed a packet is retired and counted. Its bytes may still arrive.
/// The loss report counts drops and
/// possible truncations since the last confirmed report. The host may consume
/// packets before the application reopens, outside the scope of this count.
/// With holding enabled, fatal panic/trap handling discards the queue and
/// suppresses loss reports so fatal text gets the first send attempt.
/// A pending probe occupies the FIFO like any other committed packet. The
/// fatal write can time out before committing text if the host leaves it pending.
pub const logger = if (host_test)
    Logger(0)
else
    Logger(microzig.options.hal.usb_serial_jtag_log_hold_size);

// The Windows diagnostic first committed 100 ms after reconnect returned.
// Disconnect.finish starts the hold after the reset wait. An early commit
// may overlap enumeration: the working hypothesis is that DATA_FREE stays
// stuck low on C6, while endpoint setup on C3 frees it without a host read.
const probe_delay: microzig.drivers.time.Duration = .from_ms(100);
// Retry cadence from the same diagnostic, using the WR_DONE recovery in
// release_stuck_tx for a buffer that still reads full.
const probe_retry_interval: microzig.drivers.time.Duration = .from_ms(500);

/// Time from observing an IN packet drain until the hold can release.
/// On Windows, pyserial 3.5's `Serial.open` calls SetCommState and then
/// PurgeComm(PURGE_RXCLEAR)
/// (serialwin32.py). On the C6 bench, immediate replay could lose lines to
/// that purge.
const open_settle: microzig.drivers.time.Duration = .from_ms(100);
const packet_timeout: microzig.drivers.time.Duration = .from_ms(2);

fn Logger(comptime hold_size: usize) type {
    return struct {
        const hold_enabled = hold_size != 0;
        const length_size = @sizeOf(usize);
        const staging_vtable: std.Io.Writer.VTable = .{
            .drain = spill_drain,
            .rebase = spill_rebase,
            .flush = std.Io.Writer.noopFlush,
        };
        const HoldPhase = union(enum) {
            probe: ?microzig.drivers.time.Absolute,
            probe_pending: microzig.drivers.time.Absolute,
            tx_pending: microzig.drivers.time.Absolute,
            settling: microzig.drivers.time.Absolute,
            inactive,
        };
        const HoldWait = union(enum) {
            probe,
            settle: microzig.drivers.time.Absolute,
        };
        var hold_bytes: [hold_size]u8 = undefined;
        var hold: struct {
            phase: HoldPhase = .{ .probe = null },
            len: usize = 0,
            lines: usize = 0,
            panic_mode: bool = false,
        } = .{};

        var buffer: [64]u8 = undefined;
        var writer = Writer.init(&buffer);
        // All state accesses are guarded by critical sections, or owned by the
        // context that claimed the writer (host_stalled).
        var state: log_state.State = .{};

        // Reattach callers hold a critical section and have quiesced logging.
        // Preserve any lines still queued from an earlier hold.
        fn start_hold() void {
            if (hold_enabled) {
                hold.phase = .{ .probe = microzig.drivers.time.make_timeout(tx_clock.get_time_since_boot(), probe_delay) };
                state.host_stalled = false;
            }
        }

        /// Called only on a fatal path that never returns to the interrupted owner.
        pub fn prepare_panic() void {
            if (host_test) {
                test_host.masked = true;
            } else {
                microzig.cpu.interrupt.disable_interrupts();
            }
            state.takeover(&writer.interface.end);
            writer.discard();
            if (hold_enabled) {
                hold.phase = .inactive;
                hold.panic_mode = true;
                state.dropped_lines +|= hold.lines;
                hold.len = 0;
                hold.lines = 0;
            }
        }

        fn count_dropped() void {
            const cs = log_interrupt.enter_critical_section();
            defer cs.leave();
            state.count_dropped();
        }

        /// Owner only: drops the current call's line. Replay accounts for its own line.
        fn drop_line() void {
            writer.discard();
            state.host_stalled = true;
            count_dropped();
        }

        fn print_line(w: *std.Io.Writer, comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
            const current_time = tx_clock.get_time_since_boot().to_us();
            try w.print(format ++ "\r\n", .{ current_time / std.time.us_per_s, current_time % std.time.us_per_s } ++ args);
        }

        fn send_line(comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
            try print_line(&writer.interface, format, args);
            try writer.interface.flush();
        }

        fn spill_drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            try spill_rebase(w, 0, 0);
            return w.writeSplat(data, splat);
        }

        // Switch the same formatter to direct TX, keeping any requested suffix
        // buffered for a writableSlicePreserve reservation.
        fn spill_rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
            if (preserve +| capacity > writer.storage.len) return error.WriteFailed;
            const staged = w.buffered();
            const split = staged.len -| preserve;
            writer.discard();
            try w.writeAll(staged[0..split]);
            const suffix = staged[split..];
            try w.ensureUnusedCapacity(suffix.len + capacity);
            try w.writeAll(suffix);
        }

        // The previous queue has drained. Stage this line in the same RAM
        // budget and stream excess bytes without restarting the formatter.
        fn stage_or_send_line(comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
            writer.err = null;
            if (hold_size > length_size) {
                writer.interface = .{ .buffer = hold_bytes[length_size..], .vtable = &staging_vtable };
            }
            defer writer.discard();
            try print_line(&writer.interface, format, args);
            if (writer.interface.vtable == &staging_vtable) {
                append_line(&hold_bytes, writer.interface.end);
            } else {
                try writer.interface.flush();
            }
        }

        fn save_line(comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
            const space = hold_bytes[hold.len..];
            if (space.len < length_size) return error.WriteFailed;
            var fixed: std.Io.Writer = .fixed(space[length_size..]);
            try print_line(&fixed, format, args);
            append_line(space, fixed.end);
        }

        fn append_line(space: []u8, len: usize) void {
            std.mem.writeInt(usize, space[0..length_size], len, .little);
            hold.len += length_size + len;
            hold.lines += 1;
        }

        fn replay() error{Timeout}!void {
            var offset: usize = 0;
            defer {
                const pending = hold_bytes[offset..hold.len];
                @memmove(hold_bytes[0..pending.len], pending);
                hold.len = pending.len;
            }
            while (offset < hold.len) {
                const len = std.mem.readInt(usize, hold_bytes[offset..][0..length_size], .little);
                const line = hold_bytes[offset + length_size ..][0..len];
                var sent: usize = 0;
                // Once a packet is committed, retire the line even if only a
                // prefix can arrive. A timeout before that leaves it queued.
                defer if (sent != 0) {
                    offset += length_size + len;
                    hold.lines -= 1;
                };
                errdefer if (sent != 0) count_dropped();
                while (sent < line.len) {
                    const packet = line[sent..][0..@min(64, line.len - sent)];
                    const deadline = writer.deadline orelse Deadline.init_relative(tx_clock.get_time_since_boot(), writer.timeout);
                    try wait_for_tx(deadline);
                    commit_packet(packet);
                    sent += packet.len;
                    try wait_for_tx(deadline);
                }
            }
        }

        fn rehold() void {
            // The timed-out TX wait just re-committed the buffer.
            hold.phase = .{ .tx_pending = tx_clock.get_time_since_boot() };
        }

        // Called under the critical section with the writer free. Return a
        // wait to perform outside it, or leave the phase ready for claiming.
        fn hold_wait(probe_waited: bool) ?HoldWait {
            switch (hold.phase) {
                .probe => |eligible_at| {
                    if (eligible_at) |eligible| {
                        if (!eligible.is_reached_by(tx_clock.get_time_since_boot())) return null;
                    }
                    // EP1_CONF.WR_DONE also releases DATA_FREE stuck at boot.
                    // If a previous packet is still pending, the same write
                    // re-commits it and its drain supplies the evidence.
                    tx_fifo_flush();
                    hold.phase = .{ .probe_pending = tx_clock.get_time_since_boot() };
                    return .probe;
                },
                .probe_pending => |last_commit| {
                    if (!probe_waited) {
                        const retry_at = microzig.drivers.time.make_timeout(last_commit, probe_retry_interval);
                        if (retry_at.is_reached_by(tx_clock.get_time_since_boot()) and tx_fifo_full()) {
                            release_stuck_tx();
                            hold.phase = .{ .probe_pending = tx_clock.get_time_since_boot() };
                        }
                        return .probe;
                    }
                    if (tx_fifo_full()) return null;
                },
                .tx_pending => |last_commit| {
                    const retry_at = microzig.drivers.time.make_timeout(last_commit, probe_retry_interval);
                    const retry_due = retry_at.is_reached_by(tx_clock.get_time_since_boot());
                    if (tx_fifo_full()) {
                        if (!retry_due) return null;
                        release_stuck_tx();
                        hold.phase = .{ .tx_pending = tx_clock.get_time_since_boot() };
                        if (tx_fifo_full()) return null;
                    }
                },
                .settling => |until| {
                    if (!until.is_reached_by(tx_clock.get_time_since_boot()))
                        return .{ .settle = until };
                    return null;
                },
                .inactive => return null,
            }
            const until = microzig.drivers.time.make_timeout(tx_clock.get_time_since_boot(), open_settle);
            hold.phase = .{ .settling = until };
            return .{ .settle = until };
        }

        fn send_loss_report(unreported: usize) std.Io.Writer.Error!void {
            // A timed-out line may have left a delivered fragment. Terminate
            // it before reporting loss and attempting the next complete line.
            try writer.interface.print("\r\n[usb logger: lost at most {d} lines since last confirmed report]\r\n", .{unreported});
            try writer.interface.flush();
        }

        pub fn log(
            comptime level: std.log.Level,
            comptime scope: @TypeOf(.EnumLiteral),
            comptime format: []const u8,
            args: anytype,
        ) void {
            const level_prefix = comptime "[{}.{:0>6}] " ++ level.asText();
            const prefix = comptime level_prefix ++ switch (scope) {
                .default => ": ",
                else => " (" ++ @tagName(scope) ++ "): ",
            };

            const masked_by_caller = if (host_test) test_host.masked else !microzig.interrupt.globally_enabled() or microzig.cpu.interrupt.get_priority_threshold() != .zero;
            var probe_waited = false;
            const claimed = while (true) {
                const wait = decide: {
                    const cs = log_interrupt.enter_critical_section();
                    defer cs.leave();
                    const from_hold = hold_enabled and !state.busy and hold.phase != .inactive;
                    if (from_hold and !masked_by_caller) {
                        if (hold_wait(probe_waited)) |wait| break :decide wait;
                    }
                    const unreported = state.claim() orelse return;
                    // Only the caller that claims after settling releases the
                    // hold. Masked callers can still append right up to replay.
                    const queue = from_hold and (masked_by_caller or hold.phase != .settling);
                    if (from_hold and !queue) hold.phase = .inactive;
                    break .{ .unreported = unreported, .queue = queue };
                };
                switch (wait) {
                    .probe => {
                        const until = Deadline.init_relative(tx_clock.get_time_since_boot(), packet_timeout);
                        while (tx_fifo_full() and !until.is_reached_by(tx_clock.get_time_since_boot())) {}
                        // Recheck the current hold and FIFO under the critical
                        // section. Another caller may have already replayed.
                        probe_waited = true;
                    },
                    .settle => |until| while (!until.is_reached_by(tx_clock.get_time_since_boot())) {},
                }
            };
            defer {
                const cs = log_interrupt.enter_critical_section();
                defer cs.leave();
                state.release();
            }

            if (claimed.queue) {
                save_line(prefix ++ format, args) catch count_dropped();
                return;
            }

            release_stuck_tx_at_boot();
            // Allow for USB frame scheduling. Shorter waits dropped lines
            // even with a reading host on the C3 and C6 under Windows.
            writer.timeout = packet_timeout;
            writer.deadline = if (masked_by_caller)
                Deadline.init_relative(tx_clock.get_time_since_boot(), writer.timeout)
            else
                null;

            if (state.host_stalled and tx_fifo_full()) {
                // No wait runs here: release a stuck buffer on every dropped
                // line, not only on the timeout that began the stall.
                release_stuck_tx();
                drop_line();
                return;
            }
            const can_rehold = hold_enabled and !hold.panic_mode;
            if (claimed.unreported != 0 and !(hold_enabled and hold.panic_mode)) {
                send_loss_report(claimed.unreported) catch {
                    if (can_rehold) {
                        rehold();
                        save_line(prefix ++ format, args) catch count_dropped();
                    } else {
                        drop_line();
                    }
                    return;
                };
                // Lines dropped by other contexts meanwhile stay counted.
                const cs = log_interrupt.enter_critical_section();
                defer cs.leave();
                state.confirm_report(claimed.unreported);
            }
            state.host_stalled = false;

            if (can_rehold) {
                if (hold.len != 0) replay() catch {
                    rehold();
                    save_line(prefix ++ format, args) catch count_dropped();
                    return;
                };
                stage_or_send_line(prefix ++ format, args) catch {
                    if (writer.err != null) rehold();
                    count_dropped();
                    return;
                };
                if (hold.len != 0) replay() catch rehold();
                return;
            }
            send_line(prefix ++ format, args) catch {
                drop_line();
            };
        }
    };
}

test "logger strings crossing the line buffer keep their fields" {
    if (!host_test) return error.SkipZigTest;
    inline for (.{ 31, 32, 63, 64, 65, 100, 200 }) |len| {
        test_host.reset();
        test_host.latency_us = 1100;
        logger.state = .{};
        logger.writer.discard();
        const field: [len]u8 = @splat('h');
        logger.log(.info, .default, "FIELD {s} END", .{&field});
        try std.testing.expect(std.mem.indexOf(u8, test_host.output(), comptime std.fmt.comptimePrint("FIELD {s} END\r\n", .{field})) != null);
        try std.testing.expectEqual(@as(usize, 0), logger.state.dropped_lines);
    }
}

fn reset_test_logger() void {
    test_host.reset();
    logger.state = .{};
    logger.writer.discard();
}

const HeldTestLogger = Logger(256);

fn reset_held_test_logger() void {
    test_host.reset();
    HeldTestLogger.state = .{};
    HeldTestLogger.hold = .{};
    HeldTestLogger.writer.discard();
    boot_tx_checked = false;
}

fn expect_log_order(lines: []const []const u8) !void {
    var output = test_host.output();
    for (lines) |line| {
        const index = std.mem.indexOf(u8, output, line) orelse return error.MissingLogLine;
        output = output[index + line.len ..];
    }
}

test "logger queues before the reattach probe delay even with a free FIFO" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.set_reading(false);
    try std.testing.expect(!test_host.full());
    const accesses = test_host.fifo_accesses;
    HeldTestLogger.start_hold();
    const attached_at = test_host.clock_us();
    test_host.advance(probe_delay.to_us() - 30);
    HeldTestLogger.log(.info, .default, "BEFORE PROBE", .{});
    try std.testing.expect(test_host.clock_us() - attached_at < probe_delay.to_us());
    try std.testing.expectEqual(accesses, test_host.fifo_accesses);
    try std.testing.expectEqual(0, test_host.output().len);

    HeldTestLogger.log(.info, .default, "PORT CLOSED", .{});
    try std.testing.expectEqual(attached_at + probe_delay.to_us(), test_host.last_commit_us);
    try std.testing.expectEqual(1, test_host.packet_count);
    try std.testing.expectEqual(0, test_host.output().len);
    test_host.set_reading(true);
    HeldTestLogger.log(.info, .default, "PORT OPEN", .{});
    try expect_log_order(&.{ "BEFORE PROBE\r\n", "PORT CLOSED\r\n", "PORT OPEN\r\n" });
}

test "logger re-commits a stuck probe at 500 ms intervals and settles after drain" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.enumerating = true;
    test_host.set_reading(false);
    HeldTestLogger.log(.info, .default, "FIRST PROBE", .{});
    const first = test_host.last_commit_us;
    const interval = probe_retry_interval.to_us();
    test_host.advance(first + interval - 100 - test_host.clock_us());
    HeldTestLogger.log(.info, .default, "EARLY", .{});
    try std.testing.expectEqual(0, test_host.recommits);

    HeldTestLogger.log(.info, .default, "STILL ENUMERATING", .{});
    try std.testing.expectEqual(1, test_host.recommits);
    try std.testing.expect(test_host.last_commit_us - first >= interval);
    const retry = test_host.last_commit_us;
    test_host.enumerating = false;
    test_host.set_reading(true);
    try std.testing.expectEqual(0, test_host.packets_read);
    HeldTestLogger.log(.info, .default, "STILL STUCK", .{});
    try std.testing.expectEqual(1, test_host.recommits);
    try std.testing.expectEqual(0, test_host.output().len);

    test_host.advance(retry + interval - test_host.clock_us());
    const reopened = test_host.clock_us();
    HeldTestLogger.log(.info, .default, "RECOVERED", .{});
    try std.testing.expectEqual(2, test_host.recommits);
    try std.testing.expect(test_host.last_commit_us - reopened >= open_settle.to_us());
    try expect_log_order(&.{ "FIRST PROBE\r\n", "EARLY\r\n", "STILL ENUMERATING\r\n", "STILL STUCK\r\n", "RECOVERED\r\n" });
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
}

test "logger bounds each probe wait while the port is closed and replays after open" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.set_reading(false);
    const field: [72]u8 = @splat('x');
    const start = test_host.clock_us();
    HeldTestLogger.log(.info, .default, "FIRST {s}", .{&field});
    try std.testing.expectEqual(1, test_host.packet_count);
    try std.testing.expectEqual(1, test_host.fifo_accesses - test_host.status_reads);
    try std.testing.expect(test_host.clock_us() - start <= 2_040);

    test_host.advance(3_000_000);
    const retry = test_host.clock_us();
    HeldTestLogger.log(.info, .default, "SECOND", .{});
    try std.testing.expect(test_host.clock_us() - retry <= 2_040);
    try std.testing.expectEqual(2, test_host.fifo_accesses - test_host.status_reads);
    try std.testing.expectEqual(0, test_host.output().len);

    test_host.set_reading(true);
    HeldTestLogger.log(.info, .default, "REPLAY", .{});
    try expect_log_order(&.{ "FIRST " ++ field ++ "\r\n", "SECOND\r\n", "REPLAY\r\n" });
    try std.testing.expectEqual(0, std.mem.count(u8, test_host.output(), "lost at most"));
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
}

test "a single unmasked boot log reaches an already reading host before returning" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.latency_us = 1100;
    HeldTestLogger.log(.info, .default, "ONLY LINE", .{});
    try expect_log_order(&.{"ONLY LINE\r\n"});
    try std.testing.expectEqual(2, test_host.packet_count);
    try std.testing.expect(test_host.last_commit_us >= 1100 + open_settle.to_us());
    try std.testing.expect(test_host.clock_us() < 103_000);
}

test "logger flushes an early boot burst on its first unmasked call" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.masked = true;
    HeldTestLogger.log(.info, .default, "FIRST", .{});
    HeldTestLogger.log(.info, .default, "SECOND", .{});
    try std.testing.expectEqual(0, test_host.fifo_accesses);

    test_host.masked = false;
    try std.testing.expect(test_host.clock_us() < probe_delay.to_us());
    HeldTestLogger.log(.info, .default, "LAST", .{});
    try expect_log_order(&.{ "FIRST\r\n", "SECOND\r\n", "LAST\r\n" });
    try std.testing.expectEqual(4, test_host.packet_count);
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
    try std.testing.expect(test_host.clock_us() < 102_000);
}

test "logger sends a finite FIELD HEX DONE burst with one settle delay" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    const field: [200]u8 = @splat('h');
    HeldTestLogger.log(.info, .default, "FIELD {s}", .{&field});
    HeldTestLogger.log(.info, .default, "HEX 00010203", .{});
    HeldTestLogger.log(.info, .default, "DONE", .{});
    try expect_log_order(&.{ "FIELD " ++ field ++ "\r\n", "HEX 00010203\r\n", "DONE\r\n" });
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
    try std.testing.expect(test_host.clock_us() < probe_delay.to_us() + 102_000);
}

test "logger probes a stuck boot FIFO even when the port is already open" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.stuck_at_boot = true;
    HeldTestLogger.log(.info, .default, "OPEN AT BOOT", .{});
    try std.testing.expectEqual(2, test_host.packet_count);
    try expect_log_order(&.{"OPEN AT BOOT\r\n"});
}

test "the first eligible unmasked log after reattach starts a fresh probe" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    HeldTestLogger.log(.info, .default, "BEFORE DETACH", .{});
    HeldTestLogger.log(.info, .default, "BOOT REPLAY", .{});
    const packets = test_host.packet_count;
    const fifo_accesses = test_host.fifo_accesses;
    HeldTestLogger.start_hold();
    HeldTestLogger.log(.info, .default, "BEFORE PROBE", .{});
    try std.testing.expectEqual(packets, test_host.packet_count);
    test_host.advance(3_000_000);
    try std.testing.expectEqual(fifo_accesses, test_host.fifo_accesses);

    test_host.set_reading(false);
    HeldTestLogger.log(.info, .default, "AFTER ATTACH", .{});
    try std.testing.expectEqual(packets + 1, test_host.packet_count);
    try std.testing.expect(test_host.fifo_accesses > fifo_accesses);
    test_host.set_reading(true);
    HeldTestLogger.log(.info, .default, "AFTER SETTLE", .{});
    try expect_log_order(&.{ "BEFORE DETACH\r\n", "BOOT REPLAY\r\n", "BEFORE PROBE\r\n", "AFTER ATTACH\r\n", "AFTER SETTLE\r\n" });
}

test "Disconnect finish starts the probe delay after a slow bus reset" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    HeldTestLogger.log(.info, .default, "BOOT", .{});
    const packets = test_host.packet_count;
    const accesses = test_host.fifo_accesses;

    var attachment: Attachment = .{};
    const disconnected: Disconnect = .{
        .conf0 = .{ .USB_PAD_ENABLE = 1 },
        .int_ena = {},
        .host_attached = true,
        .options = .{ .attachment = &attachment },
    };
    test_host.set_reading(false);
    const reset_at = test_host.clock_us() + 150_000;
    test_host.bus_reset_at_us = reset_at;
    try std.testing.expectEqual(@as(?bool, true), disconnected.finish());
    try std.testing.expect(attachment.reset_seen);
    const returned_at = test_host.clock_us();
    try std.testing.expect(returned_at >= reset_at);

    HeldTestLogger.log(.info, .default, "AFTER RESET", .{});
    try std.testing.expectEqual(accesses, test_host.fifo_accesses);
    test_host.advance(returned_at + probe_delay.to_us() - test_host.clock_us());
    HeldTestLogger.log(.info, .default, "PORT CLOSED", .{});
    try std.testing.expectEqual(packets + 1, test_host.packet_count);
    try std.testing.expect(test_host.last_commit_us - returned_at >= probe_delay.to_us());

    test_host.set_reading(true);
    HeldTestLogger.log(.info, .default, "PORT OPEN", .{});
    try expect_log_order(&.{ "BOOT\r\n", "AFTER RESET\r\n", "PORT CLOSED\r\n", "PORT OPEN\r\n" });
}

test "logger waits for a previously stalled FIFO on reattach" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    HeldTestLogger.log(.info, .default, "BOOT", .{});
    HeldTestLogger.log(.info, .default, "BOOT REPLAY", .{});

    test_host.set_reading(false);
    HeldTestLogger.log(.info, .default, "BEFORE DETACH", .{});
    try std.testing.expectEqual(1, HeldTestLogger.state.dropped_lines);
    try std.testing.expectEqual(.tx_pending, std.meta.activeTag(HeldTestLogger.hold.phase));
    HeldTestLogger.start_hold();
    test_host.advance(probe_delay.to_us());

    HeldTestLogger.log(.info, .default, "HELD AFTER ATTACH", .{});
    const retry = test_host.clock_us();
    HeldTestLogger.log(.info, .default, "STILL PENDING", .{});
    try std.testing.expect(test_host.clock_us() - retry <= 2_030);
    try std.testing.expectEqual(1, HeldTestLogger.state.dropped_lines);
    test_host.set_reading(true);
    HeldTestLogger.log(.info, .default, "REOPENED", .{});
    try expect_log_order(&.{ "BEFORE DETACH\r\n", "lost at most 1 lines", "HELD AFTER ATTACH\r\n", "STILL PENDING\r\n", "REOPENED\r\n" });
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
}

test "logger counts hold overflow and keeps complete earlier lines" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.set_reading(false);
    HeldTestLogger.log(.info, .default, "KEPT", .{});
    const oversized: [256]u8 = @splat('x');
    HeldTestLogger.log(.info, .default, "OVERFLOW {s}", .{&oversized});
    HeldTestLogger.log(.info, .default, "ALSO KEPT", .{});
    try std.testing.expectEqual(1, HeldTestLogger.state.dropped_lines);
    try std.testing.expectEqual(1, test_host.packet_count);

    test_host.set_reading(true);
    HeldTestLogger.log(.info, .default, "CURRENT", .{});
    try expect_log_order(&.{ "lost at most 1 lines", ": KEPT\r\n", "ALSO KEPT\r\n", "CURRENT\r\n" });
    try std.testing.expect(std.mem.indexOf(u8, test_host.output(), "OVERFLOW") == null);
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
}

test "masked logger leaves probing and replay for unmasked calls" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.latency_us = 1100;
    test_host.set_reading(false);
    test_host.masked = true;
    HeldTestLogger.log(.info, .default, "MASKED AT BOOT", .{});
    try std.testing.expectEqual(0, test_host.fifo_accesses);

    test_host.masked = false;
    HeldTestLogger.log(.info, .default, "PROBE", .{});
    test_host.set_reading(true);
    test_host.advance(1100);

    const fifo_accesses = test_host.fifo_accesses;
    test_host.masked = true;
    HeldTestLogger.log(.info, .default, "MASKED RELEASE", .{});
    HeldTestLogger.log(.info, .default, "STILL MASKED", .{});
    try std.testing.expectEqual(fifo_accesses, test_host.fifo_accesses);
    try std.testing.expectEqual(0, test_host.output().len);

    test_host.masked = false;
    HeldTestLogger.log(.info, .default, "UNMASKED", .{});
    try expect_log_order(&.{ "MASKED AT BOOT\r\n", "PROBE\r\n", "MASKED RELEASE\r\n", "STILL MASKED\r\n", "UNMASKED\r\n" });
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
}

test "masked calls queue without FIFO access during the probe and settle waits" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.latency_us = 1100;
    const Preempt = struct {
        var fifo_accesses: usize = 0;

        fn masked_log(comptime message: []const u8) void {
            const before = test_host.fifo_accesses;
            test_host.masked = true;
            defer test_host.masked = false;
            HeldTestLogger.log(.info, .default, message, .{});
            fifo_accesses += test_host.fifo_accesses - before;
        }

        fn during_probe() void {
            masked_log("MASKED DURING PROBE");
            test_host.preemption = .{ .at_us = probe_delay.to_us() + 5_000, .run = during_settle };
        }

        fn during_settle() void {
            masked_log("MASKED DURING SETTLE");
        }
    };
    Preempt.fifo_accesses = 0;
    test_host.preemption = .{ .at_us = probe_delay.to_us() + 100, .run = Preempt.during_probe };
    HeldTestLogger.log(.info, .default, "OUTER", .{});
    try expect_log_order(&.{ "MASKED DURING PROBE\r\n", "MASKED DURING SETTLE\r\n", "OUTER\r\n" });
    try std.testing.expectEqual(0, Preempt.fifo_accesses);
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
}

test "preemption at settle entry or during settle does not extend the deadline" {
    if (!host_test) return error.SkipZigTest;
    const Preempt = struct {
        fn during_settle() void {
            HeldTestLogger.log(.info, .default, "PREEMPTING", .{});
        }
    };
    // The first case preempts at the first clock sample of the settle wait.
    for ([_]u64{ 50, 5_000 }) |preempt_after_us| {
        reset_held_test_logger();
        test_host.advance(probe_delay.to_us());
        test_host.masked = true;
        HeldTestLogger.log(.info, .default, "QUEUED", .{});
        test_host.masked = false;
        test_host.preemption = .{
            .at_us = test_host.clock_us() + preempt_after_us,
            .run = Preempt.during_settle,
        };
        HeldTestLogger.log(.info, .default, "OUTER", .{});
        try expect_log_order(&.{ "QUEUED\r\n", "PREEMPTING\r\n", "OUTER\r\n" });
        try std.testing.expectEqual(1, std.mem.count(u8, test_host.output(), "QUEUED\r\n"));
        try std.testing.expectEqual(4, test_host.packet_count);
        try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
        try std.testing.expect(test_host.clock_us() < probe_delay.to_us() + 102_000);
    }
}

test "logger keeps untouched queued lines when replay stalls and settles again" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.set_reading(false);
    HeldTestLogger.log(.info, .default, "FIRST", .{});
    HeldTestLogger.log(.info, .default, "STALLED", .{});
    HeldTestLogger.log(.info, .default, "UNSENT", .{});
    test_host.stall_packet = 3; // Empty probe, FIRST, STALLED.
    test_host.set_reading(true);
    HeldTestLogger.log(.info, .default, "QUEUED CURRENT", .{});
    try std.testing.expectEqual(1, HeldTestLogger.state.dropped_lines);

    const reads = test_host.status_reads;
    HeldTestLogger.log(.info, .default, "STILL FULL", .{});
    try std.testing.expectEqual(reads + 1, test_host.status_reads);
    test_host.advance(10_000);
    const observed = test_host.clock_us();
    HeldTestLogger.log(.info, .default, "RECOVERED", .{});
    try std.testing.expect(test_host.last_commit_us - observed >= open_settle.to_us());
    try expect_log_order(&.{ "FIRST\r\n", "STALLED\r\n", "lost at most 1 lines", "UNSENT\r\n", "QUEUED CURRENT\r\n", "STILL FULL\r\n", "RECOVERED\r\n" });
    try std.testing.expectEqual(1, std.mem.count(u8, test_host.output(), "STALLED\r\n"));
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
}

test "logger re-commits a stuck replay after the retry interval and settles after drain" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.masked = true;
    HeldTestLogger.log(.info, .default, "STALLED", .{});
    HeldTestLogger.log(.info, .default, "UNSENT", .{});
    test_host.masked = false;
    const HostReset = struct {
        fn during_settle() void {
            test_host.enumerating = true;
        }
    };
    test_host.preemption = .{ .at_us = test_host.clock_us() + 5_000, .run = HostReset.during_settle };
    HeldTestLogger.log(.info, .default, "QUEUED CURRENT", .{});
    try std.testing.expectEqual(1, HeldTestLogger.state.dropped_lines);
    // The timeout already re-committed once, while the host was enumerating.
    try std.testing.expectEqual(1, test_host.recommits);
    const retry_at = test_host.last_commit_us + probe_retry_interval.to_us();
    test_host.enumerating = false;
    test_host.advance(retry_at - 100 - test_host.clock_us());
    HeldTestLogger.log(.info, .default, "TOO EARLY", .{});
    try std.testing.expectEqual(1, test_host.recommits);
    try std.testing.expectEqual(0, test_host.output().len);

    test_host.advance(retry_at - test_host.clock_us());
    test_host.masked = true;
    const accesses = test_host.fifo_accesses;
    HeldTestLogger.log(.info, .default, "MASKED", .{});
    test_host.masked = false;
    try std.testing.expectEqual(accesses, test_host.fifo_accesses);

    const observed = test_host.clock_us();
    HeldTestLogger.log(.info, .default, "RECOVERED", .{});
    try std.testing.expectEqual(2, test_host.recommits);
    try std.testing.expect(test_host.last_commit_us - observed >= open_settle.to_us());
    try expect_log_order(&.{ "STALLED\r\n", "lost at most 1 lines", "UNSENT\r\n", "QUEUED CURRENT\r\n", "TOO EARLY\r\n", "MASKED\r\n", "RECOVERED\r\n" });
    try std.testing.expectEqual(1, std.mem.count(u8, test_host.output(), "STALLED\r\n"));
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
}

test "logger keeps the queue when the loss report stalls before replay" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.set_reading(false);
    HeldTestLogger.log(.info, .default, "QUEUED", .{});
    const oversized: [256]u8 = @splat('x');
    HeldTestLogger.log(.info, .default, "{s}", .{&oversized});

    test_host.stall_packet = 2;
    test_host.set_reading(true);
    HeldTestLogger.log(.info, .default, "QUEUED CURRENT", .{});
    try std.testing.expectEqual(1, HeldTestLogger.state.dropped_lines);

    const reads = test_host.status_reads;
    HeldTestLogger.log(.info, .default, "WHILE REPORT PENDING", .{});
    try std.testing.expectEqual(reads + 1, test_host.status_reads);
    test_host.advance(10_000);
    HeldTestLogger.log(.info, .default, "RECOVERED", .{});
    try expect_log_order(&.{
        "lost at most 1 lines since last confirmed report]\r\n",
        "QUEUED\r\n",
        "QUEUED CURRENT\r\n",
        "WHILE REPORT PENDING\r\n",
        "RECOVERED\r\n",
    });
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
}

test "logger reholds when the loss report stalls after releasing an empty queue" {
    if (!host_test) return error.SkipZigTest;
    const oversized: [256]u8 = @splat('x');
    for ([_]bool{ false, true }) |after_replay| {
        reset_held_test_logger();
        test_host.advance(probe_delay.to_us());
        test_host.set_reading(false);
        if (after_replay) {
            HeldTestLogger.log(.info, .default, "LAST QUEUED", .{});
            HeldTestLogger.log(.info, .default, "{s}", .{&oversized});
            test_host.set_reading(true);
            // The report succeeds, then replay retires the last line on timeout.
            test_host.stall_packet = 4;
            HeldTestLogger.log(.info, .default, "{s}", .{&oversized});
            HeldTestLogger.log(.info, .default, "{s}", .{&oversized});
            test_host.advance(10_000);
            test_host.stall_packet = 5;
        } else {
            // All calls during the initial hold overflow.
            HeldTestLogger.log(.info, .default, "{s}", .{&oversized});
            HeldTestLogger.log(.info, .default, "{s}", .{&oversized});
            test_host.stall_packet = 2;
            test_host.set_reading(true);
        }
        const dropped = HeldTestLogger.state.dropped_lines;
        try std.testing.expectEqual(if (after_replay) @as(usize, 3) else 2, dropped);
        try std.testing.expectEqual(0, HeldTestLogger.hold.lines);

        HeldTestLogger.log(.info, .default, "QUEUED CURRENT", .{});
        const reads = test_host.status_reads;
        HeldTestLogger.log(.info, .default, "WHILE REPORT PENDING", .{});
        try std.testing.expectEqual(reads + 1, test_host.status_reads);
        try std.testing.expectEqual(dropped, HeldTestLogger.state.dropped_lines);
        test_host.advance(10_000);
        HeldTestLogger.log(.info, .default, "RECOVERED", .{});
        try expect_log_order(&.{
            if (after_replay) "lost at most 3 lines since last confirmed report]\r\n" else "lost at most 2 lines since last confirmed report]\r\n",
            "QUEUED CURRENT\r\n",
            "WHILE REPORT PENDING\r\n",
            "RECOVERED\r\n",
        });
        try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
    }
}

test "logger re-holds when the host stops reading after boot" {
    if (!host_test) return error.SkipZigTest;
    for ([_]bool{ false, true }) |masked| {
        reset_held_test_logger();
        HeldTestLogger.log(.info, .default, "BOOT", .{});
        try expect_log_order(&.{"BOOT\r\n"});
        const packets = test_host.packet_count;

        test_host.set_reading(false);
        test_host.masked = masked;
        const start = test_host.clock_us();
        const field: [100]u8 = @splat('x');
        HeldTestLogger.log(.info, .default, "TIMED OUT {s} END", .{&field});
        try std.testing.expect(test_host.clock_us() - start <= 2_040);
        try std.testing.expectEqual(1, HeldTestLogger.state.dropped_lines);
        try std.testing.expectEqual(packets + 1, test_host.packet_count);
        try std.testing.expectEqual(1, test_host.recommits);
        const retry_at = test_host.last_commit_us + probe_retry_interval.to_us();

        const accesses = test_host.fifo_accesses;
        test_host.masked = true;
        HeldTestLogger.log(.info, .default, "MASKED", .{});
        try std.testing.expectEqual(accesses, test_host.fifo_accesses);
        test_host.masked = false;
        test_host.advance(retry_at - 100 - test_host.clock_us());
        HeldTestLogger.log(.info, .default, "BEFORE RETRY", .{});
        try std.testing.expect(test_host.clock_us() < retry_at);
        try std.testing.expectEqual(1, test_host.recommits);
        test_host.advance(retry_at - test_host.clock_us());
        HeldTestLogger.log(.info, .default, "AFTER RETRY", .{});
        try std.testing.expect(test_host.clock_us() - retry_at < 100);
        try std.testing.expectEqual(2, test_host.recommits);
        try std.testing.expectEqual(packets + 1, test_host.packet_count);
        try std.testing.expectEqual(1, HeldTestLogger.state.dropped_lines);

        test_host.set_reading(true);
        const observed = test_host.clock_us();
        HeldTestLogger.log(.info, .default, "REPLUGGED", .{});
        try std.testing.expect(test_host.last_commit_us - observed >= open_settle.to_us());
        try expect_log_order(&.{ "BOOT\r\n", "TIMED OUT ", "lost at most 1 lines", "MASKED\r\n", "BEFORE RETRY\r\n", "AFTER RETRY\r\n", "REPLUGGED\r\n" });
        try std.testing.expectEqual(1, std.mem.count(u8, test_host.output(), "TIMED OUT "));
        try std.testing.expectEqual(0, std.mem.count(u8, test_host.output(), " END\r\n"));
        try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
    }
}

test "logger preserves the original formatted line when a pending packet prevents its first commit" {
    if (!host_test) return error.SkipZigTest;
    const Record = struct {
        calls: usize = 0,
        sampled_us: u64 = 0,
        text: []const u8 = "ORIGINAL",

        pub fn format(self: *@This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
            self.calls += 1;
            self.sampled_us = test_host.clock_us();
            defer self.text = "CHANGED";
            try w.writeAll(self.text);
        }
    };
    for ([_]bool{ false, true }) |masked| {
        reset_held_test_logger();
        HeldTestLogger.log(.info, .default, "BOOT", .{});
        test_host.set_reading(false);
        try std.testing.expectError(error.Timeout, write_blocking("RAW\r\n", .init_relative(tx_clock.get_time_since_boot(), packet_timeout)));
        test_host.masked = masked;
        var message: Record = .{};
        const started = test_host.clock_us();
        HeldTestLogger.log(.info, .default, "NOT COMMITTED {f}", .{&message});
        try std.testing.expectEqual(1, message.calls);
        try std.testing.expect(message.sampled_us - started < 100);
        try std.testing.expect(test_host.clock_us() - started <= 2_040);
        try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
        var line: [80]u8 = undefined;
        const expected = try std.fmt.bufPrint(&line, "[{}.{:0>6}] info: NOT COMMITTED ORIGINAL\r\n", .{
            message.sampled_us / std.time.us_per_s,
            message.sampled_us % std.time.us_per_s,
        });

        test_host.masked = false;
        test_host.set_reading(true);
        HeldTestLogger.log(.info, .default, "RECOVERED", .{});
        try expect_log_order(&.{ "BOOT\r\n", "RAW\r\n", expected, "RECOVERED\r\n" });
        try std.testing.expectEqual(1, std.mem.count(u8, test_host.output(), expected));
        try std.testing.expectEqual(1, message.calls);
    }
}

test "logger streams an oversized line without restarting its formatter" {
    if (!host_test) return error.SkipZigTest;
    const field: [200]u8 = @splat('x');
    const tail: [48]u8 = @splat('y');
    const Oversized = struct {
        calls: *usize,
        reserve: bool,

        pub fn format(self: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
            self.calls.* += 1;
            try w.writeAll(&field);
            try w.writeAll("KEEP");
            if (self.reserve) {
                const dest = try w.writableSlicePreserve("KEEP".len, tail.len);
                @memcpy(dest, &tail);
            } else {
                try w.writeAll(&tail);
            }
        }
    };
    for ([_]bool{ false, true }) |reserve| {
        reset_held_test_logger();
        HeldTestLogger.log(.info, .default, "BOOT", .{});
        var calls: usize = 0;
        const message: Oversized = .{ .calls = &calls, .reserve = reserve };
        HeldTestLogger.log(.info, .default, "OVERSIZED {f}", .{message});
        try expect_log_order(&.{ "BOOT\r\n", field ++ "KEEP" ++ tail ++ "\r\n" });
        try std.testing.expectEqual(1, calls);

        test_host.set_reading(false);
        try std.testing.expectError(error.Timeout, write_blocking("RAW\r\n", .init_relative(tx_clock.get_time_since_boot(), packet_timeout)));
        HeldTestLogger.log(.info, .default, "TIMED OUT {f}", .{message});
        try std.testing.expectEqual(2, calls);
        try std.testing.expectEqual(1, HeldTestLogger.state.dropped_lines);
        HeldTestLogger.log(.info, .default, "QUEUED", .{});
        test_host.set_reading(true);
        HeldTestLogger.log(.info, .default, "RECOVERED", .{});
        try expect_log_order(&.{ "RAW\r\n", "lost at most 1 lines", "QUEUED\r\n", "RECOVERED\r\n" });
        try std.testing.expectEqual(0, std.mem.count(u8, test_host.output(), "TIMED OUT"));
        try std.testing.expectEqual(2, calls);
    }
}

test "zero hold size drops lines while a direct write or loss report is stalled" {
    if (!host_test) return error.SkipZigTest;
    reset_test_logger();
    test_host.stall_packet = 1;
    logger.log(.info, .default, "DIRECT WRITE", .{});
    const stalled_at = test_host.clock_us();
    logger.log(.info, .default, "DROPPED AFTER WRITE", .{});
    try std.testing.expectEqual(stalled_at, test_host.clock_us());
    try std.testing.expectEqual(2, logger.state.dropped_lines);

    test_host.advance(10_000);
    test_host.stall_packet = test_host.packet_count + 1;
    logger.log(.info, .default, "DROPPED DURING REPORT", .{});
    logger.log(.info, .default, "DROPPED WHILE STALLED", .{});
    try std.testing.expectEqual(4, logger.state.dropped_lines);

    test_host.advance(10_000);
    const resumed_at = test_host.clock_us();
    logger.log(.info, .default, "RECOVERED", .{});
    try std.testing.expect(test_host.clock_us() - resumed_at < 100);
    try expect_log_order(&.{ "lost at most 4 lines since last confirmed report]\r\n", "RECOVERED\r\n" });
    try std.testing.expectEqual(0, std.mem.count(u8, test_host.output(), "DROPPED"));
}

test "logger holds through Linux enumeration until tty open submits IN reads" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.set_reading(false);
    const field: [72]u8 = @splat('x');
    HeldTestLogger.log(.info, .default, "BOOT {s} COMPLETE", .{&field});

    // acm_probe sends line coding, but acm_port_activate has not submitted reads.
    HeldTestLogger.log(.info, .default, "ENUMERATED", .{});
    test_host.advance(3_000_000);
    HeldTestLogger.log(.info, .default, "LATE OPEN", .{});
    try std.testing.expectEqual(1, test_host.packet_count);
    try std.testing.expectEqual(0, test_host.output().len);
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);

    test_host.set_reading(true);
    HeldTestLogger.log(.info, .default, "OPEN", .{});
    try expect_log_order(&.{ "BOOT " ++ field ++ " COMPLETE\r\n", "ENUMERATED\r\n", "LATE OPEN\r\n", "OPEN\r\n" });
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
}

test "logger counts overflow during a long hold while the host stays closed" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.set_reading(false);
    HeldTestLogger.log(.info, .default, "FIRST", .{});
    HeldTestLogger.log(.info, .default, "KEPT", .{});
    test_host.advance(3_000_000);

    const field: [80]u8 = @splat('x');
    HeldTestLogger.log(.info, .default, "FILL {s}", .{&field});
    HeldTestLogger.log(.info, .default, "OVERFLOW {s}", .{&field});
    HeldTestLogger.log(.info, .default, "STILL FITS", .{});
    try std.testing.expectEqual(1, test_host.packet_count);
    try std.testing.expectEqual(1, HeldTestLogger.state.dropped_lines);
    try std.testing.expectEqual(0, test_host.output().len);

    test_host.set_reading(true);
    HeldTestLogger.log(.info, .default, "READING", .{});
    try expect_log_order(&.{ "lost at most 1 lines", "FIRST\r\n", "KEPT\r\n", "FILL " ++ field ++ "\r\n", "STILL FITS\r\n", "READING\r\n" });
    try std.testing.expectEqual(0, std.mem.count(u8, test_host.output(), "OVERFLOW"));
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
}

test "logger keeps the first queued line when an earlier packet blocks the FIFO" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.set_reading(false);
    try std.testing.expectError(error.Timeout, write_blocking("PENDING\r\n", .init_relative(tx_clock.get_time_since_boot(), .from_ms(2))));
    HeldTestLogger.log(.info, .default, "FIRST QUEUED", .{});
    HeldTestLogger.log(.info, .default, "RELEASE", .{});
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
    try std.testing.expectEqual(0, test_host.output().len);

    test_host.set_reading(true);
    HeldTestLogger.log(.info, .default, "RECOVERED", .{});
    try expect_log_order(&.{ "PENDING\r\n", "FIRST QUEUED\r\n", "RELEASE\r\n", "RECOVERED\r\n" });
}

test "logger panic commits fatal text first when the first data packet stalls" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.set_reading(false);
    HeldTestLogger.log(.info, .default, "HELD LINE", .{});
    try std.testing.expectEqual(1, test_host.packet_count);
    test_host.set_reading(true);
    test_host.stall_packet = 2;
    HeldTestLogger.prepare_panic();
    HeldTestLogger.log(.err, .default, "PANIC TEXT", .{});
    try std.testing.expectEqual(error.Timeout, HeldTestLogger.writer.err.?);
    test_host.advance(10_000);
    try std.testing.expect(!test_host.full());
    HeldTestLogger.log(.err, .default, "PANIC DETAIL", .{});
    try expect_log_order(&.{ "PANIC TEXT\r\n", "PANIC DETAIL\r\n" });
    try std.testing.expect(std.mem.indexOf(u8, test_host.output(), "HELD LINE") == null);
    try std.testing.expect(std.mem.indexOf(u8, test_host.output(), "lost at most") == null);
}

test "a panic write times out within its packet budget when the probe is pending" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.set_reading(false);
    HeldTestLogger.log(.info, .default, "HELD LINE", .{});
    try std.testing.expectEqual(1, test_host.packet_count);

    HeldTestLogger.prepare_panic();
    const start = test_host.clock_us();
    HeldTestLogger.log(.err, .default, "PANIC TEXT", .{});
    try std.testing.expectEqual(error.Timeout, HeldTestLogger.writer.err.?);
    try std.testing.expect(test_host.clock_us() - start <= 2_030);
    try std.testing.expectEqual(0, HeldTestLogger.hold.lines);
    try std.testing.expectEqual(1, test_host.packet_count);

    test_host.set_reading(true);
    try std.testing.expectEqual(1, test_host.packets_read);
    try std.testing.expectEqual(0, test_host.output().len);
    HeldTestLogger.log(.err, .default, "PANIC DETAIL", .{});
    try expect_log_order(&.{"PANIC DETAIL\r\n"});
    try std.testing.expectEqual(0, std.mem.count(u8, test_host.output(), "lost at most"));
}

test "zero hold size writes immediately at boot and after reattach" {
    if (!host_test) return error.SkipZigTest;
    reset_test_logger();
    boot_tx_checked = false;
    logger.log(.info, .default, "IMMEDIATE AT BOOT", .{});
    try expect_log_order(&.{"IMMEDIATE AT BOOT\r\n"});
    try std.testing.expectEqual(1, test_host.packet_count);
    logger.start_hold();
    logger.log(.info, .default, "IMMEDIATE AFTER ATTACH", .{});
    try expect_log_order(&.{"IMMEDIATE AFTER ATTACH\r\n"});
    try std.testing.expectEqual(2, test_host.packet_count);
}

test "logger named and temporary bytesToHex slices and raw hex" {
    if (!host_test) return error.SkipZigTest;
    inline for (.{ 0, 1100 }) |latency_us| {
        reset_test_logger();
        test_host.latency_us = latency_us;
        var raw: [32]u8 = undefined;
        for (&raw, 0..) |*byte, i| byte.* = @intCast(i);
        const expected = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
        const hex = std.fmt.bytesToHex(raw, .lower);
        logger.log(.info, .default, "NAMED {s} END", .{hex[0..]});
        logger.log(.info, .default, "TEMP {s} END", .{std.fmt.bytesToHex(raw, .lower)[0..]});
        logger.log(.info, .default, "CHUNKS {s}{s} END", .{ hex[0..32], hex[32..64] });
        logger.log(.info, .default, "RAW {x} END", .{&raw});
        inline for (.{ "NAMED ", "TEMP ", "CHUNKS ", "RAW " }) |prefix| {
            try std.testing.expect(std.mem.indexOf(u8, test_host.output(), prefix ++ expected ++ " END\r\n") != null);
        }
        try std.testing.expectEqual(@as(usize, 0), logger.state.dropped_lines);
    }
}

test "Writer drain accounts only input bytes and handles vectors and splats" {
    if (!host_test) return error.SkipZigTest;
    inline for (.{ 0, 1, 64, 100 }) |capacity| {
        test_host.reset();
        test_host.latency_us = 1100;
        var buffer: [capacity]u8 = undefined;
        var writer = Writer.init(&buffer);
        writer.timeout = .from_ms(2);
        try writer.interface.writeAll("buffered");
        var vec: [3][]const u8 = .{ "", "head", "ab" };
        try writer.interface.writeSplatAll(&vec, 40);
        var zero: [2][]const u8 = .{ "tail", "excluded" };
        try writer.interface.writeSplatAll(&zero, 0);
        try writer.interface.flush();
        var expected: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&expected);
        try w.writeAll("bufferedhead");
        for (0..40) |_| try w.writeAll("ab");
        try w.writeAll("tail");
        try std.testing.expectEqualStrings(w.buffered(), test_host.output());
        try std.testing.expectEqual(@as(usize, 0), writer.interface.end);
        try std.testing.expectEqual(@as(?error{Timeout}, null), writer.err);
    }
    test_host.reset();
    var buffer: [64]u8 = undefined;
    var writer = Writer.init(&buffer);
    try writer.interface.writeAll("prefix");
    // The return count excludes buffer bytes, including when only those drain.
    const consumed = try Writer.drain(&writer.interface, &.{"field"}, 1);
    try std.testing.expect(consumed <= "field".len);
    try writer.interface.writeAll("field"[consumed..]);
    try writer.interface.flush();
    try std.testing.expectEqualStrings("prefixfield", test_host.output());
}

test "logger counts a timeout and reports it before the next line" {
    if (!host_test) return error.SkipZigTest;
    inline for (.{ 1, 2 }) |stalled_packet| {
        reset_test_logger();
        test_host.latency_us = 100;
        test_host.stall_packet = stalled_packet;
        const field: [200]u8 = @splat('h');
        logger.log(.info, .default, "FIELD {s} END", .{&field});
        try std.testing.expectEqual(@as(usize, 1), logger.state.dropped_lines);
        try std.testing.expectEqual(@as(usize, 0), logger.writer.interface.end);
        try std.testing.expectEqual(error.Timeout, logger.writer.err.?);
        // Host resumes and consumes the already committed fragment.
        test_host.advance(20_000);
        test_host.stall_packet = null;
        logger.log(.info, .default, "RECOVERED", .{});
        try std.testing.expect(std.mem.indexOf(u8, test_host.output(), "lost at most 1 lines since last confirmed report]\r\n") != null);
        try std.testing.expect(std.mem.endsWith(u8, test_host.output(), "RECOVERED\r\n"));
        try std.testing.expectEqual(@as(usize, 0), logger.state.dropped_lines);
    }
}

test "masked logger keeps one deadline for the entire line" {
    if (!host_test) return error.SkipZigTest;
    reset_test_logger();
    test_host.masked = true;
    test_host.latency_us = 1100;
    const field: [200]u8 = @splat('h');
    logger.log(.info, .default, "FIELD {s} END", .{&field});
    try std.testing.expectEqual(@as(usize, 1), logger.state.dropped_lines);
    try std.testing.expectEqual(@as(usize, 0), logger.writer.interface.end);
    try std.testing.expectEqual(error.Timeout, logger.writer.err.?);
}

test "write_blocking accepts driver deadlines on the host" {
    if (!host_test) return error.SkipZigTest;
    test_host.reset();
    try std.testing.expectEqual(0, try write_blocking("", .no_deadline));
    const deadline: microzig.drivers.time.Deadline = .init_absolute(.from_us(1000));
    try std.testing.expectEqual(1, try write_blocking("x", deadline));
}

test "draining a large buffer bounds bytes relocated" {
    if (!host_test) return error.SkipZigTest;
    test_host.reset();
    var payload: [4096]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i / 64);
    var buffer: [payload.len]u8 = undefined;
    var writer = Writer.init(&buffer);
    try writer.interface.writeAll(&payload);
    var relocated: usize = 0;
    while (writer.interface.end != 0) {
        const before = writer.interface.buffered();
        const sent = test_host.output().len;
        try std.testing.expectEqual(0, try Writer.drain(&writer.interface, &.{""}, 1));
        const n = test_host.output().len - sent;
        try std.testing.expectEqual(64, n);
        const pending = writer.interface.buffered();
        // A pending suffix at a new address has been copied.
        if (pending.ptr != before[n..].ptr) relocated += pending.len;
    }
    try std.testing.expectEqualSlices(u8, &payload, test_host.output());
    try std.testing.expect(relocated <= payload.len);
}

test "repeated reservations on a full writer bound bytes relocated" {
    if (!host_test) return error.SkipZigTest;
    test_host.reset();
    var initial: [4096]u8 = undefined;
    for (&initial, 0..) |*byte, i| byte.* = @truncate(i / 64);
    var buffer: [initial.len]u8 = undefined;
    var writer = Writer.init(&buffer);
    try writer.interface.writeAll(&initial);
    var relocated: usize = 0;
    for (0..64) |i| {
        const before = writer.interface.buffered();
        const sent = test_host.output().len;
        const reserved = if (i % 2 == 0) try writer.interface.writableSlice(64) else blk: {
            const greedy = try writer.interface.writableSliceGreedy(64);
            writer.interface.advance(64);
            break :blk greedy[0..64];
        };
        @memset(reserved, @intCast(0x80 + i));
        const n = test_host.output().len - sent;
        const pending = writer.interface.buffered()[0 .. before.len - n];
        // A pending suffix at a new address has been copied.
        if (pending.ptr != before[n..].ptr) relocated += pending.len;
    }
    const sent_while_reserving = test_host.output().len;
    try writer.interface.flush();
    try std.testing.expectEqualSlices(u8, &initial, test_host.output()[0..initial.len]);
    for (0..64) |i| {
        const expected: [64]u8 = @splat(@intCast(0x80 + i));
        try std.testing.expectEqualSlices(u8, &expected, test_host.output()[initial.len + 64 * i ..][0..64]);
    }
    try std.testing.expectEqual(initial.len + 64 * 64, test_host.output().len);
    // Every relocated byte moves into a prefix sent since the last compaction.
    try std.testing.expect(relocated <= sent_while_reserving);
}

test "Writer rebase preserves the suffix after a partial drain" {
    if (!host_test) return error.SkipZigTest;
    test_host.reset();
    var buffer: [256]u8 = undefined;
    var writer = Writer.init(&buffer);
    var payload: [buffer.len]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @intCast(i);
    try writer.interface.writeAll(&payload);
    try std.testing.expectEqual(0, try Writer.drain(&writer.interface, &.{""}, 1));
    const reserved = try writer.interface.writableSlicePreserve(16, 240);
    @memset(reserved, 'x');
    try writer.interface.flush();
    try std.testing.expectEqualSlices(u8, &payload, test_host.output()[0..payload.len]);
    const expected: [240]u8 = @splat('x');
    try std.testing.expectEqualSlices(u8, &expected, test_host.output()[payload.len..]);
    try std.testing.expectEqual(buffer.len, writer.interface.buffer.len);
}

test "Writer restores its full buffer after a failed partial drain" {
    if (!host_test) return error.SkipZigTest;
    test_host.reset();
    var buffer: [256]u8 = undefined;
    var writer = Writer.init(&buffer);
    writer.timeout = .from_ms(2);
    const first: [buffer.len]u8 = @splat('a');
    try writer.interface.writeAll(&first);
    try std.testing.expectEqual(0, try Writer.drain(&writer.interface, &.{""}, 1));
    try std.testing.expect(writer.interface.buffer.len < buffer.len);
    test_host.stall_packet = 2;
    try std.testing.expectError(error.WriteFailed, writer.interface.flush());
    try std.testing.expectEqual(error.Timeout, writer.err.?);
    try std.testing.expectEqual(@as(usize, 0), writer.interface.end);
    try std.testing.expectEqual(@as([*]u8, &buffer), writer.interface.buffer.ptr);
    try std.testing.expectEqual(buffer.len, writer.interface.buffer.len);
    // The host consumes the committed packet; the next line goes out whole.
    test_host.advance(20_000);
    test_host.stall_packet = null;
    const sent = test_host.output().len;
    const line: [200]u8 = @splat('b');
    try writer.interface.writeAll(&line);
    try writer.interface.flush();
    try std.testing.expectEqual(@as(?error{Timeout}, null), writer.err);
    try std.testing.expect(std.mem.endsWith(u8, test_host.output()[sent..], &line));
}

test "dropping a logger line restores its full buffer" {
    if (!host_test) return error.SkipZigTest;
    reset_test_logger();
    // As left by a drain that sent part of the buffered bytes.
    logger.writer.interface.buffer = logger.writer.storage[16..];
    logger.writer.interface.end = 8;
    logger.drop_line();
    try std.testing.expectEqual(@as(usize, 0), logger.writer.interface.end);
    try std.testing.expectEqual(logger.writer.storage.ptr, logger.writer.interface.buffer.ptr);
    try std.testing.expectEqual(logger.writer.storage.len, logger.writer.interface.buffer.len);
    reset_test_logger();
}

test "logger measures settle from observation even if the packet drained long ago" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.set_reading(false);
    test_host.latency_us = 10_000;
    HeldTestLogger.log(.info, .default, "HELD", .{});
    const reads = test_host.status_reads;
    try std.testing.expectEqual(0, test_host.packets_read);

    test_host.set_reading(true);
    try std.testing.expectEqual(0, test_host.packets_read);
    test_host.advance(10_000);
    try std.testing.expectEqual(1, test_host.packets_read);
    test_host.advance(3_000_000);
    try std.testing.expectEqual(reads, test_host.status_reads);
    try std.testing.expectEqual(0, test_host.output().len);

    test_host.latency_us = 0;
    const observed = test_host.clock_us();
    HeldTestLogger.log(.info, .default, "OPEN", .{});
    try std.testing.expect(test_host.last_commit_us - observed >= open_settle.to_us());
    try std.testing.expectEqual(0, test_host.recommits);
    try expect_log_order(&.{ "HELD\r\n", "OPEN\r\n" });
}

test "reattach commits a fresh probe after a previous commit drained while idle" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.set_reading(false);
    test_host.latency_us = 10_000;
    HeldTestLogger.log(.info, .default, "BEFORE ATTACH", .{});
    const reads = test_host.status_reads;
    test_host.set_reading(true);
    test_host.advance(150_000);
    try std.testing.expectEqual(1, test_host.packets_read);
    try std.testing.expectEqual(reads, test_host.status_reads);

    HeldTestLogger.start_hold();
    test_host.set_reading(false);
    test_host.latency_us = 0;
    test_host.advance(probe_delay.to_us());
    HeldTestLogger.log(.info, .default, "AFTER ATTACH", .{});
    try std.testing.expectEqual(2, test_host.packet_count);
    try std.testing.expectEqual(1, test_host.packets_read);
    try std.testing.expectEqual(0, test_host.output().len);

    test_host.set_reading(true);
    HeldTestLogger.log(.info, .default, "REPLAY", .{});
    try expect_log_order(&.{ "BEFORE ATTACH\r\n", "AFTER ATTACH\r\n", "REPLAY\r\n" });
}

test "destructive reattach probes again after the controller discards a pending probe" {
    if (!host_test) return error.SkipZigTest;
    reset_held_test_logger();
    test_host.advance(probe_delay.to_us());
    test_host.set_reading(false);
    HeldTestLogger.log(.info, .default, "BEFORE RESET", .{});
    try std.testing.expect(test_host.full());

    const detached = Reenumeration.detach_and_reset();
    try std.testing.expect(!test_host.full());
    try std.testing.expectEqual(0, test_host.packets_read);
    detached.attach();
    test_host.advance(probe_delay.to_us());

    HeldTestLogger.log(.info, .default, "AFTER RESET", .{});
    try std.testing.expectEqual(2, test_host.packet_count);
    try std.testing.expect(test_host.full());
    try std.testing.expectEqual(2, HeldTestLogger.hold.lines);
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
    try std.testing.expectEqual(0, test_host.output().len);

    test_host.set_reading(true);
    HeldTestLogger.log(.info, .default, "REOPENED", .{});
    try expect_log_order(&.{ "BEFORE RESET\r\n", "AFTER RESET\r\n", "REOPENED\r\n" });
    try std.testing.expectEqual(0, HeldTestLogger.state.dropped_lines);
}
