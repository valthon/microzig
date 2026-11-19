const std = @import("std");
const microzig = @import("microzig");
// Both generated chip maps call this USB_DEVICE. EP1/EP1_CONF are described
// in C6 TRM v1.2 §32.7, registers 32.1/32.2 (FIFO protocol: §32.3.2).
const USB_SERIAL_JTAG = microzig.chip.peripherals.USB_DEVICE;
const time = @import("time.zig");
const Deadline = microzig.drivers.time.Deadline;
const log_state = @import("usb_serial_jtag/state.zig");

/// Destructive C3 reconnect experiment: discards pending CDC/JTAG transfers and
/// interrupt configuration. Serialize against all USB users, including logging.
/// Requires an already clocked controller, with PLL/APB suitable for USB (§30.4).
/// Keep detached for a host-visible interval AFTER this returns, then attach.
/// This is not a light-sleep state backup and does not preserve endpoint state.
pub const Reenumeration = struct {
    conf0: @TypeOf(USB_SERIAL_JTAG.CONF0.read()),

    pub fn detach_and_reset() Reenumeration {
        @import("compatibility.zig").require_esp32_c3("USB re-enumeration experiment");
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const saved = USB_SERIAL_JTAG.CONF0.read();
        // C3 TRM v1.4 §30.6 reg 30.2: pad enable and pull override are
        // separate controls. Remove both pull-ups, not just pad functionality.
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

    pub fn attach(self: Reenumeration) void {
        // Restore PHY selection, pin exchange, thresholds and pull policy.
        // The bus clock is already enabled, as in IDF sleep_console.c restore.
        USB_SERIAL_JTAG.CONF0.write(self.conf0);
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
/// FRAM_NUM (32.17), INT_RAW/INT_CLR (32.12/32.15) have the same pad,
/// pull-override, SOF and bus-reset fields used below. Preserve C6's additional
/// USB_JTAG_BRIDGE_EN bit along with all caller interrupt enables.
/// Serialize the entire begin/finish interval against all
/// USB users; pending CDC/JTAG transfers may be lost. Masking interrupts alone
/// does not exclude a preempted logger owner. Quiesce logging and other TX
/// users before begin(), and keep them quiescent through finish().
/// Requires running PLL/APB clocks (C3 TRM v1.4 §30.4) and SYSTIMER unit 0.
pub const Disconnect = struct {
    conf0: @TypeOf(USB_SERIAL_JTAG.CONF0.read()),
    int_ena: @TypeOf(USB_SERIAL_JTAG.INT_ENA.read()),
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
    /// CONF0 and interrupt enables even on timeout. Call once.
    pub fn finish(self: Disconnect) ?bool {
        if (self.conf0.USB_PAD_ENABLE == 0) return null;
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        defer USB_SERIAL_JTAG.INT_ENA.write(self.int_ena);
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
        // §30.4: controller/CDC endpoints are self-initializing; there is no
        // firmware endpoint re-arm sequence. §30.3.2 FIFO flags determine readiness.
        // No peripheral reset here: preserve the caller's interrupt configuration.
        if (!self.host_attached) return null;
        const deadline = Deadline.init_relative(time.get_time_since_boot(), self.options.bus_reset_timeout);
        while (USB_SERIAL_JTAG.INT_RAW.read().USB_BUS_RESET_INT_RAW == 0) {
            if (deadline.is_reached_by(time.get_time_since_boot())) {
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

/// Returns `false` if data can be sent.
pub fn tx_fifo_full() bool {
    return USB_SERIAL_JTAG.EP1_CONF.read().SERIAL_IN_EP_DATA_FREE == 0;
}

/// Call this after you are done writing data. After `tx_fifo_full()` returns false
/// you can start sending more data.
pub fn tx_fifo_flush() void {
    USB_SERIAL_JTAG.EP1_CONF.write(.{ .WR_DONE = 1 });
}

/// Writes one byte to the fifo.
pub fn tx_fifo_write(byte: u8) void {
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
        return self.deadline.is_reached_by(time.get_time_since_boot());
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
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    if (boot_tx_checked) return;
    boot_tx_checked = true;
    if (tx_fifo_full()) release_stuck_tx();
}

/// Success means the host consumed every flushed packet, including the final one.
/// Timeout indicates a host that is absent, closed, or not reading (C3 TRM v1.4 §30.4; C6 TRM v1.2 §32.3.2).
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
        for (packet) |byte| tx_fifo_write(byte);
        // The 64th byte flushes automatically (C3 TRM v1.4 §30.3.2; C6 TRM v1.2 §32.3.2).
        if (packet.len < 64) tx_fifo_flush();
        try wait_for_tx(deadline);
        offset += packet.len;
    }
    return data.len;
}

/// Buffered writer with bounded host-consumption waits. Inspect err after WriteFailed.
/// Each drain gets one timeout, or the shared `deadline` when set; no failed
/// bytes are retained for a later message.
pub const Writer = struct {
    interface: std.Io.Writer,
    timeout: microzig.drivers.time.Duration = .from_ms(100),
    /// When set, every drain uses this deadline instead of `timeout`.
    deadline: ?Deadline = null,
    err: ?error{Timeout} = null,

    pub fn init(buffer: []u8) Writer {
        return .{ .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        const deadline = self.deadline orelse Deadline.init_relative(time.get_time_since_boot(), self.timeout);
        self.err = null;
        const buffered = w.buffer[0..w.end];
        w.end = 0;
        _ = write_blocking(buffered, deadline) catch |err| {
            self.err = err;
            return error.WriteFailed;
        };
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            n += write_blocking(bytes, deadline) catch |err| {
                self.err = err;
                return error.WriteFailed;
            };
        }
        for (0..splat) |_| {
            n += write_blocking(data[data.len - 1], deadline) catch |err| {
                self.err = err;
                return error.WriteFailed;
            };
        }
        return n;
    }
};

/// USB Serial JTAG logger. Use `.logFn = logger.log` in std_options.
/// Waits for the host run with the caller's interrupt state: the logger masks
/// interrupts only to claim the writer and to update its counters, never
/// while waiting. Each drain waits at most 2 ms. A caller that already has
/// interrupts masked, or is in a nested interrupt handler, gets one
/// 2 ms deadline for the whole line instead, so it masks at most 2 ms per
/// line plus formatting and FIFO writes.
/// A line that starts while another is being written (from an interrupt
/// handler or a preempting task) is dropped, not interleaved. A stalled host
/// drops subsequent lines without waiting. Every dropped or possibly
/// truncated line is counted conservatively. The next written line reports
/// at most N lost lines since the last confirmed report: committed packets
/// can arrive after a timeout, including the report itself.
/// Fatal panic/trap handling takes over the writer with interrupts masked.
/// This is best-effort logging (including error/panic text), not confirmed TX;
/// use write_blocking with caller serialization for delivery confirmation.
pub const logger = struct {
    var buffer: [64]u8 = undefined;
    var writer = Writer.init(&buffer);
    // All state accesses are guarded by critical sections, or owned by the
    // context that claimed the writer (host_stalled).
    var state: log_state.State = .{};

    /// Called only on a fatal path that never returns to the interrupted owner.
    pub fn prepare_panic() void {
        microzig.cpu.interrupt.disable_interrupts();
        state.takeover(&writer.interface.end);
    }

    fn count_dropped() void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        state.count_dropped();
    }

    /// Owner only: discards the line and counts it.
    fn drop_line() void {
        writer.interface.end = 0;
        state.host_stalled = true;
        count_dropped();
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

        const masked_by_caller = !microzig.interrupt.globally_enabled() or
            microzig.cpu.interrupt.get_priority_threshold() != .zero;
        const unreported = claim: {
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            break :claim state.claim() orelse return;
        };
        defer {
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            state.release();
        }

        release_stuck_tx_at_boot();
        // A reading host frees a packet slot within one 1 ms USB frame
        // (measured on C3 and C6 under Windows: at most 154 us per packet,
        // 326 us per line); 50 us dropped most lines while the host read.
        writer.timeout = .from_ms(2);
        writer.deadline = if (masked_by_caller)
            Deadline.init_relative(time.get_time_since_boot(), writer.timeout)
        else
            null;

        if (state.host_stalled and tx_fifo_full()) {
            // No wait runs here: release a stuck buffer on every dropped
            // line, not only on the timeout that began the stall.
            release_stuck_tx();
            drop_line();
            return;
        }
        if (unreported != 0) {
            // A timed-out line may have left a delivered fragment. Terminate
            // it before reporting loss and attempting the next complete line.
            writer.interface.print("\r\n[usb logger: lost at most {d} lines since last confirmed report]\r\n", .{unreported}) catch {
                drop_line();
                return;
            };
            writer.interface.flush() catch {
                drop_line();
                return;
            };
            // Lines dropped by other contexts meanwhile stay counted.
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            state.confirm_report(unreported);
        }
        state.host_stalled = false;

        const current_time = time.get_time_since_boot();
        const seconds = current_time.to_us() / std.time.us_per_s;
        const microseconds = current_time.to_us() % std.time.us_per_s;

        writer.interface.print(prefix ++ format ++ "\r\n", .{ seconds, microseconds } ++ args) catch {
            drop_line();
            return;
        };
        writer.interface.flush() catch {
            drop_line();
        };
    }
};
