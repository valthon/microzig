//! Interrupt-driven nRF52840 IEEE 802.15.4 PHY and legacy MAC filtering.
//! Peripheral ownership and interrupt latency requirements are in the port README.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const ppi = hal.ppi;
const phy = @import("ieee802154_phy.zig");
const header = @import("ieee802154_header.zig");
const SourceMatch = @import("ieee802154_src_match.zig").Table;
const Interface = microzig.drivers.base.IEEE802154_Radio;

const peripherals = microzig.chip.peripherals;
const radio = peripherals.RADIO;
const clock = peripherals.CLOCK;
const temp = peripherals.TEMP;
const timer = peripherals.TIMER3;
const rtc = peripherals.RTC0;
const rng = peripherals.RNG;
// PS v1.11 §6.20 and Nordic wait_until_radio_is_disabled. Keep waits
// finite independently of both peripheral clocks.
const transition_checks = 16_384;
// Provisional CPU spin for the design's 4 µs observation window.
// PS v1.11 §6.16 bounds PPI synchronization, not CC visibility.
const capture_checks = 32;
const producer_checks = 128;
const startup_checks = 1 << 21;
const timer3: hal.timer.Timer = .timer3;
const tx_sfd_capture: ppi.Channel = @fromBackingInt(17);
const end_capture: ppi.Channel = @fromBackingInt(18);
const ack_launch: ppi.Channel = @fromBackingInt(19);
const ack_launch_cc = 0;
// An owned RX close leases CC0 after ADDRESS, when RXREADY has already
// been captured and diagnostic RSSI is excluded. PS v1.11 §6.20 RADIO:
// allow a maximum frame, the END pipeline, and rounded-up ramp-down.
const retained_close_us = phy.sfd_to_frame_end_us(Interface.max_psdu_len) + phy.rx_end_delay_us + 1;
// IEEE 802.15.4 PPDU adds a four-octet preamble and one SFD octet
// before PHR/PSDU. Include the RX END pipeline and bounded ramp-down.
const settings_history_us = 5 * 2 * phy.symbol_us + retained_close_us;
const deadline_cc = 1;
const now_cc = 2;
const tx_sfd_cc = 3;
const end_cc = 4;
const temperature_cc = 5;

const io_timeout_us = 1_000;
const temperature_sample_us = 1_000_000;
// PS v1.11 §6.21, RNG Electrical Specification: typical t_RNG,START is
// 128 µs and t_RNG,BC is 120 µs. Allow 16 times their sum for each HAL restart.
const seed_byte_timeout_us = 16 * (128 + 120);
// IEEE 802.15.4-2006 symbol timing and MAC PIB defaults for the 2.4 GHz PHY.
const backoff_us = 20 * phy.symbol_us;
const ack_wait_us = 54 * phy.symbol_us;
// OpenThread radio.h refers to OPENTHREAD_CONFIG_MAC_DATA_POLL_TIMEOUT
// for RX after a pending Data Request ACK. The default is 100 ms.
const data_poll_wait_us = 100_000;
const ed_sample_us = 8 * phy.symbol_us;
// PS v1.11 §6.20 EDCNT holds the number of samples minus one.
const max_ed_samples = 1 << 21;
comptime {
    std.debug.assert(max_ed_samples == 1 << @bitSizeOf(@FieldType(@TypeOf(radio.EDCNT).underlying_type, "EDCNT")));
}
const event_capacity: usize = 16;
const max_frame_retries = 7;

pub const CcaMode = enum { energy, carrier, carrier_and_energy, carrier_or_energy, energy_test };

pub const Config = struct {
    channel: u8 = 11,
    rx_on_when_idle: bool = true,
    /// Exact dBm setting from the nRF52840 TXPOWER register.
    tx_power: i8 = 0,
    pan_id: u16 = 0xffff,
    short_address: u16 = 0xffff,
    /// Least significant octet first, as on the wire.
    extended_address: [8]u8 = @splat(0),
    promiscuous: bool = false,
    auto_ack: bool = true,
    cca_mode: CcaMode = .energy,
    cca_threshold: i8 = -75,
    min_be: u4 = 3,
    max_be: u4 = 5,
};

/// IEEE 802.15.4-2006 §6.9.7 energy level corresponding to a scan result in dBm.
pub const ed_level = phy.ed_level;

pub const Error = Interface.Error;

const Phase = enum {
    off,
    stopping,
    rx,
    auto_ack,
    backoff,
    tx_cca,
    tx,
    ack_rx,
    ack_drain,
    ed,
    cca,

    fn receiving(phase: Phase) bool {
        return phase == .rx;
    }

    fn first_tx_phase(csma_ca: bool, max_backoffs: u8) Phase {
        if (!csma_ca) return .tx;
        return if (max_backoffs == 0) .tx_cca else .backoff;
    }
};

const Operation = enum { idle, tx, ed, cca };

const EventReservation = struct {
    // null means no request. Zero means the terminal event is queued but unread.
    remaining: ?usize = null,

    fn reserve(self: *EventReservation, comptime operation: Operation, queued: usize, retries: u8) error{Busy}!void {
        const needed: usize = switch (operation) {
            .tx => 2 + @as(usize, retries),
            .ed, .cca => 1,
            else => @compileError("operation has no queued completion"),
        };
        if (self.remaining != null or queued + needed > event_capacity) return error.Busy;
        self.remaining = needed;
    }

    fn has_rx_space(self: EventReservation, queued: usize) bool {
        return queued < event_capacity - (self.remaining orelse 0);
    }

    fn queue_start(self: *EventReservation) void {
        const remaining = self.remaining orelse 0;
        std.debug.assert(remaining >= 2);
        self.remaining = remaining - 1;
    }

    fn queue_terminal(self: *EventReservation) void {
        std.debug.assert((self.remaining orelse 0) > 0);
        self.remaining = 0;
    }

    fn poll_terminal(self: *EventReservation) void {
        std.debug.assert(self.remaining == 0);
        self.remaining = null;
    }
};

const Frame = struct {
    data: [Interface.max_frame_len]u8 = undefined,
    len: u8,
    metadata: Interface.RxFrame,

    /// Copy a received frame into `slot` field by field. ReleaseSmall copies
    /// memory byte by byte, so assigning a built Frame would copy all of
    /// `data` again; this copies only the received bytes.
    fn store(slot: *?Frame, rx: *const Interface.RxFrame) void {
        slot.* = .{ .len = @intCast(rx.bytes.len), .metadata = rx.* };
        slot.*.?.metadata.bytes = &.{};
        @memcpy(slot.*.?.data[0..rx.bytes.len], rx.bytes);
    }

    fn with_ack_result(frame: Frame, sent: bool) Frame {
        var result = frame;
        result.metadata.ack_sent = sent;
        if (!sent) result.metadata.acked_with_frame_pending = false;
        return result;
    }

    fn view(self: *const Frame) Interface.RxFrame {
        var result = self.metadata;
        result.bytes = self.data[0..self.len];
        return result;
    }
};

const Queued = union(enum) {
    rx: Frame,
    rx_error: Interface.RxError,
    tx_started: Interface.TxStarted,
    tx_done: struct { status: Interface.TxStatus, timestamp: ?u64, ack: ?Frame },
    ed_done: Error!i8,
    cca_done: Error!bool,
};

const Tx = struct {
    bytes: [Interface.max_frame_len]u8 = undefined,
    len: u8,
    sequence: ?u8,
    possible_data_request: bool,
    channel: u8,
    power: ?i8,
    csma_ca: bool,
    max_backoffs: u8,
    retries_left: u8,
    backoffs: u8 = 0,
    be: u4 = 0,
    on_air_end: u32 = 0,
    timestamp: ?u64 = 0,
    attempts: u16 = 0,
    earned_terminal: ?Interface.TxStatus = null,
    // The verified sender ACK that goes with an earned acked terminal.
    earned_ack: ?Frame = null,

    fn charge_busy(self: *Tx, max_be: u4) bool {
        self.backoffs += 1;
        self.be = @min(self.be + 1, max_be);
        return self.backoffs <= self.max_backoffs;
    }

    fn retry(self: *Tx) bool {
        if (self.sequence == null or self.retries_left == 0) return false;
        self.retries_left -= 1;
        return true;
    }
};

const TxAttempt = struct {
    launched: bool = false,
    reported: bool = false,

    const Latches = struct { address: bool = false, phy_end: bool = false };
    const Marker = enum { address, phy_end };

    fn marker(self: TxAttempt, latches: Latches) ?Marker {
        if (!self.launched or self.reported) return null;
        if (latches.address) return .address;
        if (latches.phy_end) return .phy_end;
        return null;
    }
};

const PollResponse = struct {
    channel: u8,
    // Anchor the deadline at the captured ACK END. A response's captured
    // ADDRESS must precede this tick, even if its END arrives later.
    end_deadline: u32,

    fn after_ack(channel: u8, ack_end: u32, rx_on_when_idle: bool, possible_data_request: bool, ack_fcf: u8) ?PollResponse {
        if (rx_on_when_idle or !possible_data_request or ack_fcf & 0x10 == 0) return null;
        return .{ .channel = channel, .end_deadline = ack_end +% data_poll_wait_us };
    }

    fn due(self: PollResponse, tick: u32) bool {
        return phy.tick_reached(tick, self.end_deadline);
    }

    fn includes_address(self: PollResponse, address: u32) bool {
        return !self.due(address);
    }
};

const RxSettings = struct {
    config: Config,
    pan_coordinator: bool = false,
    deliver_bad_fcs: bool = false,
    sources: SourceMatch = .{},

    const Disposition = union(enum) {
        reject,
        accept,
        ack: struct { sequence: u8, pending: bool, power: i8 },
    };

    fn classify(self: *const RxSettings, bytes: []const u8, fcs_ok: bool, ack_allowed: bool) Disposition {
        if (!fcs_ok) return if (self.deliver_bad_fcs) .accept else .reject;
        if (self.config.promiscuous) return .accept;
        const h = header.parse(bytes) catch return .reject;
        return switch (h.filter(
            self.config.pan_id,
            self.config.short_address,
            &self.config.extended_address,
            ack_allowed and self.config.auto_ack,
            self.pan_coordinator,
        )) {
            .reject => .reject,
            .accept => .accept,
            .ack => .{ .ack = .{
                .sequence = h.sequence,
                .pending = self.sources.frame_pending(h, bytes),
                .power = self.config.tx_power,
            } },
        };
    }
};

// One snapshot per distinct cutover tick. Extra back-to-back writes
// use bounded backpressure rather than evicting a live generation.
const RxSettingsVersions = struct {
    const capacity = 8;
    const Entry = struct { tick: u32, settings: RxSettings };

    entries: [capacity]Entry = undefined,
    oldest: usize = 0,
    count: usize = 1,
    staged: RxSettings = undefined,

    fn init(settings: RxSettings) RxSettingsVersions {
        var self: RxSettingsVersions = .{};
        self.entries[0] = .{ .tick = 0, .settings = settings };
        return self;
    }

    fn index(self: *const RxSettingsVersions, offset: usize) usize {
        return (self.oldest + offset) % capacity;
    }

    fn current(self: *const RxSettingsVersions) *const RxSettings {
        return &self.entries[self.index(self.count - 1)].settings;
    }

    fn at_end(self: *const RxSettingsVersions, end: u32, prime: u32) *const RxSettings {
        var offset = self.count - 1;
        while (offset != 0 and self.entries[self.index(offset)].tick -% prime > end -% prime)
            offset -= 1;
        return &self.entries[self.index(offset)].settings;
    }

    fn edit(self: *RxSettingsVersions) *RxSettings {
        self.staged = self.current().*;
        return &self.staged;
    }

    fn reset_arm(self: *RxSettingsVersions, tick: u32) void {
        self.oldest = self.index(self.count - 1);
        self.count = 1;
        self.entries[self.oldest].tick = tick;
    }

    fn has_room(self: *const RxSettingsVersions, tick: u32) bool {
        return self.count < capacity or self.entries[self.index(self.count - 1)].tick == tick;
    }

    fn publish(self: *RxSettingsVersions, tick: u32) void {
        std.debug.assert(self.has_room(tick));
        if (self.entries[self.index(self.count - 1)].tick != tick) self.count += 1;
        self.entries[self.index(self.count - 1)] = .{ .tick = tick, .settings = self.staged };
    }
};

const RxHandoff = struct {
    channel: u8,
    request: ?u64,
};

const Measurement = union(enum) { energy: i8, cca: bool };

var owner: ?*Radio = null;

/// Stationary caller-owned storage. Serialize foreground calls and keep RADIO,
/// TIMER3 and PPI 17–19 available until deinit. The TIMER3 IRQ samples TEMP for
/// anomaly 153; RNG seeds the handle during init.
pub const Radio = struct {
    rx_settings: RxSettingsVersions,
    idle_close_pending: bool = false,
    enabled: bool = false,
    rx_request: ?u64 = null,
    next_request: u64 = 0,
    arm_request: ?u64 = null,
    poll_response: ?PollResponse = null,

    phase: Phase = .off,
    after_stop: Phase = .off,
    after_auto_ack: ?Phase = null,
    stopped_phase: Phase = .off,
    stopping_rx: ?RxHandoff = null,
    close: ?Close = null,
    close_wait_failed: bool = false,
    ramped: bool = false,
    backoff_listening: bool = false,
    backoff_tick: ?u32 = null,
    operation: Operation = .idle,
    deadline: ?u32 = null,
    fault: ?Interface.Fault = null,
    quarantined: bool = false,
    public_time: u64 = 0,
    public_tick: u32 = 0,
    progress_rtc: u24 = 0,
    temp_deadline: ?u32 = null,
    temp_started: bool = false,
    deferred_channel: ?u8 = null,
    rx_reserved: bool = false,
    rx_settled: bool = false,
    capture_prime: u32 = 0,
    captures: [3]Capture = @splat(.unread),
    address_established: bool = false,
    rx_ready_tick: ?u32 = null,
    measurement_origin: ?u32 = null,
    measurement_result: ?Measurement = null,
    housekeeping: bool = false,
    overrun_before: usize = 0,
    rx_channel: u8,
    adjustment: i8,
    random: std.Random.DefaultPrng,

    packet: [1 + Interface.max_psdu_len]u8 align(4) = undefined,
    tx: Tx = undefined,
    tx_attempt: TxAttempt = .{},
    pending_rx: ?Frame = null,
    pending_rx_request: ?u64 = null,
    rx_replacement: ?Phase = null,
    resolve_first_result: ?usize = null,
    staged_tx_start: ?u64 = null,
    measurement_channel: u8 = 11,
    cca_state: Interface.State = .sleep,
    ed_samples: u32 = 0,

    queue: [event_capacity]Queued = undefined,
    read_index: usize = 0,
    queued: usize = 0,
    reservation: EventReservation = .{},
    overrun: u32 = 0,
    // Nordic m_no_rx_buffer_notified: set when a buffer-missing arm reports
    // overrun, cleared when poll frees a FIFO slot.
    starved_reported: bool = false,
    delivered: Frame = undefined,
    notify: ?Interface.Notify = null,
    notify_pending: bool = false,

    /// Initialize disabled. Call enable on the returned interface before use.
    /// `self` must be stationary: init installs it as the RADIO owner before
    /// verifying the hardware. If init returns `HardwareFault`, retirement could
    /// not be confirmed and ownership is retained, so keep the handle and its
    /// DMA storage stationary until chip reset; never let it go out of scope.
    pub fn init(self: *Radio, config: Config) Error!void {
        if (!microzig.options.hal.ieee802154)
            @compileError("Set microzig_options.hal.ieee802154 to install the RADIO and TIMER3 vectors");
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        if (owner != null) return error.Busy;
        try validate(config);
        self.* = .{
            .rx_settings = .init(.{ .config = config }),
            .rx_channel = config.channel,
            .adjustment = 0,
            .random = .init(0),
        };
        owner = self;
        self.isolate_interrupts();
        if (self.quarantined) return error.HardwareFault;

        // PS v1.11 CLOCK, HFCLK controller. Leave the shared crystal request active.
        clock.TASKS_HFCLKSTART.write_raw(1);
        const started = rtc.COUNTER.read().COUNTER;
        for (0..startup_checks) |_| {
            const status = clock.HFCLKSTAT.read();
            if (status.SRC == .Xtal and status.STATE == .Running) break;
            if (rtc_elapsed(started, 20_000)) {
                owner = null;
                return error.Timeout;
            }
        } else {
            owner = null;
            return error.Timeout;
        }

        hal.temp.init();
        start_temperature_sample();
        self.temp_started = true;
        const sample_start = rtc.COUNTER.read().COUNTER;
        for (0..startup_checks) |_| {
            if (temp.EVENTS_DATARDY.raw != 0 or rtc_elapsed(sample_start, io_timeout_us)) break;
        }
        const sampled = temp.EVENTS_DATARDY.raw != 0;
        if (sampled) self.adjustment = temperature_adjustment(@bitCast(temp.TEMP.read().TEMP));
        if (!self.retire_temperature()) {
            self.record_fault(.temp_retirement);
            if (!self.retire_temperature()) self.quarantined = true;
            if (self.quarantined) return error.HardwareFault;
            owner = null;
            return error.Timeout;
        }
        if (!sampled) {
            owner = null;
            return error.Timeout;
        }
        self.random = .init(csma_seed());
        if (!retire_rng()) {
            self.record_fault(.rng_retirement);
            if (!retire_rng()) {
                self.quarantined = true;
                return error.HardwareFault;
            }
            owner = null;
            return error.Timeout;
        }
        const retired = self.retire_lifecycle(false);
        if (self.quarantined) return error.HardwareFault;
        if (!retired) {
            owner = null;
            return error.Timeout;
        }
    }

    /// Release the handle after all queued outcomes have been drained.
    pub fn deinit(self: *Radio) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        if (owner != self) return;
        if (self.backlog()) return error.Busy;
        if (self.enabled) try self.execute_stop(true, null);
        if (self.backlog()) return error.Busy;
        if (self.quarantined) return error.HardwareFault;
        owner = null;
    }

    fn record_fault(self: *Radio, reason: Interface.FaultReason) void {
        if (self.fault) |*fault| {
            fault.count +|= 1;
        } else {
            self.fault = .{ .reason = reason };
        }
        self.notify_pending = true;
    }

    fn backlog(self: *const Radio) bool {
        return self.fault != null or self.queued != 0 or self.overrun != 0;
    }

    fn deliver_wake(self: *Radio) void {
        if (!self.notify_pending and !self.backlog()) return;
        if (self.notify) |notify| {
            self.notify_pending = false;
            notify.call(notify.context);
        }
    }

    fn isolate_interrupts(self: *Radio) void {
        radio.INTENCLR.write_raw(0xffff_ffff);
        timer.INTENCLR.write_raw(0xffff_ffff);
        temp.INTENCLR.write_raw(0xffff_ffff);
        if (radio.INTENSET.raw != 0 or timer.INTENSET.raw != 0 or temp.INTENSET.raw != 0) {
            self.record_fault(.interrupt_isolation);
            self.quarantined = true;
        }
        const irq = microzig.cpu.interrupt;
        irq.disable(.RADIO);
        irq.disable(.TIMER3);
        irq.clear_pending(.RADIO);
        irq.clear_pending(.TIMER3);
    }

    fn retire_temperature(self: *Radio) bool {
        if (!self.temp_started) return true;
        temp.TASKS_STOP.write_raw(1);
        if (!clear_stopped_event(&temp.EVENTS_DATARDY)) return false;
        self.temp_started = false;
        return true;
    }

    fn retire_lifecycle(self: *Radio, radio_power_handled: bool) bool {
        var clean = true;
        self.temp_deadline = null;
        if (!self.retire_temperature()) {
            clean = false;
            self.record_fault(.temp_retirement);
            if (!self.retire_temperature()) self.quarantined = true;
        }
        if (!retire_timer()) {
            clean = false;
            self.record_fault(.timer_retirement);
            if (!retire_timer()) self.quarantined = true;
        }
        if (!radio_power_handled) clean = self.retire_radio_power() and clean;
        self.isolate_interrupts();
        return clean and !self.quarantined;
    }

    fn retire_radio_power(self: *Radio) bool {
        // PS v1.11 §6.20 and Nordic nrf_radio_reset: revoke RADIO activity
        // with POWER down. Restore and verify configuration on next Enable.
        power_off();
        if (radio.POWER.raw == 0) return true;
        self.record_fault(.radio_reset);
        power_off();
        if (radio.POWER.raw != 0) self.quarantined = true;
        return false;
    }

    fn start_lifecycle(self: *Radio) Error!void {
        if (self.quarantined) return error.HardwareFault;
        if (radio.POWER.raw != 0) return self.fail_startup(.radio_reset);
        if (!timer_is_stopped()) return self.fail_startup(.timer_retirement);
        reset_radio();
        set_radio_power(self.rx_settings.current().config.tx_power);
        radio.FREQUENCY.write(.{ .FREQUENCY = channel_frequency(self.rx_channel) });
        timer.SHORTS.write_raw(0);
        timer3.apply(.{ .width = .bits32, .prescaler = 4 }) catch unreachable;
        if (!radio_configuration_valid() or
            radio.FREQUENCY.read().FREQUENCY != channel_frequency(self.rx_channel) or
            radio.TXPOWER.raw != @as(u8, @bitCast(self.rx_settings.current().config.tx_power)))
            return self.fail_startup(.radio_reset);
        if (timer.MODE.read().MODE != .Timer or timer.BITMODE.read().BITMODE != .@"32Bit" or
            timer.PRESCALER.read().PRESCALER != 4)
            return self.fail_startup(.timer_retirement);
        timer3.clear();
        timer3.start();
        const initial = counter_now();
        var advanced = false;
        for (0..transition_checks) |_| {
            if (counter_now() != initial) {
                advanced = true;
                break;
            }
        }
        if (!advanced) return self.fail_startup(.clock_stalled);
        const irq = microzig.cpu.interrupt;
        irq.set_priority(.RADIO, .highest);
        irq.set_priority(.TIMER3, .highest);
        irq.clear_pending(.RADIO);
        irq.clear_pending(.TIMER3);
        self.public_tick = counter_now();
        self.progress_rtc = rtc.COUNTER.read().COUNTER;
        self.temp_deadline = self.public_tick +% temperature_sample_us;
        self.program_compare(temperature_cc, self.temp_deadline.?);
        start_temperature_sample();
        self.temp_started = true;
        self.enabled = true;
        irq.enable(.RADIO);
        irq.enable(.TIMER3);
        if (self.notify_pending or self.backlog()) self.request_event_notification();
    }

    fn fail_startup(self: *Radio, reason: Interface.FaultReason) Error {
        // A failed Enable may record a sticky diagnostic before logical
        // enablement, while ordinary dispatch and FIFO publication are
        // still sealed.
        self.record_fault(reason);
        _ = self.retire_lifecycle(false);
        self.deliver_wake();
        return error.HardwareFault;
    }

    fn enter_fault(self: *Radio, reason: Interface.FaultReason) void {
        self.execute_stop(true, reason) catch |err| {
            std.debug.assert(err == error.HardwareFault);
        };
    }

    // The explicit stop executor owns the old evidence through quiescence.
    // Keep captures installed while revoking new launches, as in Nordic's
    // operation_terminated_notify.
    fn execute_stop(self: *Radio, lifecycle: bool, initial_fault: ?Interface.FaultReason) Error!void {
        const first_result = self.resolve_first_result orelse self.queued;
        const old_phase = if (self.phase == .stopping) self.stopped_phase else self.phase;
        const sender_ack = old_phase == .ack_drain or
            (old_phase == .ack_rx and self.ramped);
        const close = self.commit_close();
        var failed = initial_fault != null or close.fault_reason() != null;
        if (initial_fault) |reason| self.record_fault(reason) else if (close.unexpected_disabled)
            self.record_fault(.unexpected_disabled);
        if (close.missing_capture and initial_fault != .missing_capture) self.record_fault(.missing_capture);
        self.disarm_deadline();
        const revoked = self.revoke_producers(.stop);
        var revocation_fault = initial_fault == .producer_revocation;
        if (!revoked or close.revocation_failed) {
            if (!revocation_fault) self.record_fault(.producer_revocation);
            revocation_fault = true;
            failed = true;
        }
        // A stuck CC0 launch route can issue TXEN even while RADIO is
        // quiescent. Stop its timer now and verify shutdown in teardown.
        if (!revoked) timer.TASKS_STOP.write_raw(1);
        const stopped = revoked and !self.close_wait_failed and self.stop_committed_radio();
        self.close_wait_failed = false;
        if (!stopped) {
            if (revoked and initial_fault != .radio_timeout) self.record_fault(.radio_timeout);
            failed = true;
        }
        var start: ?struct { tick: ?u64 } = if (self.staged_tx_start != null) .{ .tick = self.staged_tx_start } else null;
        self.staged_tx_start = null;
        if (self.operation == .tx and (old_phase == .tx or old_phase == .tx_cca)) {
            const marker = self.tx_marker();
            if (marker) |evidence| {
                const tick = self.tx_capture(evidence);
                if (tick == null) {
                    if (initial_fault != .missing_capture) self.record_fault(.missing_capture);
                    failed = true;
                }
                start = .{ .tick = tick };
            }
        }
        if (!stopped) _ = self.retire_radio_power();
        var retired = self.retire_arm();
        if (!retired) {
            if (!revocation_fault) self.record_fault(.producer_revocation);
            failed = true;
            timer.TASKS_STOP.write_raw(1);
            retired = self.retire_arm();
            if (!retired) self.quarantined = true;
        }
        if (stopped and retired) radio.PACKETPTR.write_raw(0);
        const seal = lifecycle or failed;
        if (seal and !self.retire_lifecycle(!stopped)) failed = true;
        if (start) |evidence| self.queue_tx_start(if (failed) null else evidence.tick);
        if (self.pending_rx != null) {
            self.publish_pending_rx();
        } else if (close.owned and old_phase != .ack_rx and old_phase != .ack_drain) {
            self.enqueue(.{ .rx_error = .aborted });
        }
        switch (self.operation) {
            .idle => {},
            .tx => {
                const ack = self.tx.earned_ack;
                self.finish_tx(self.tx.earned_terminal orelse if (sender_ack) .no_ack else .aborted, ack);
            },
            .ed => self.enqueue(.{ .ed_done = error.Aborted }),
            .cca => self.enqueue(.{ .cca_done = error.Aborted }),
        }
        self.operation = .idle;
        self.rx_request = null;
        self.poll_response = null;
        self.deferred_channel = null;
        self.stopping_rx = null;
        self.after_auto_ack = null;
        self.rx_replacement = null;
        self.backoff_tick = null;
        self.tx_attempt = .{};
        self.phase = .off;
        const irq = microzig.cpu.interrupt;
        if (seal) {
            self.enabled = false;
            if (failed) self.clear_result_times(first_result);
            irq.clear_pending(.RADIO);
            irq.clear_pending(.TIMER3);
            self.deliver_wake();
        } else {
            irq.clear_pending(.RADIO);
            irq.clear_pending(.TIMER3);
            self.request_event_notification();
        }
        if (failed) return if (lifecycle) error.HardwareFault else error.Aborted;
    }

    fn clear_result_times(self: *Radio, first: usize) void {
        for (first..self.queued) |index| {
            switch (self.queue[(self.read_index + index) % event_capacity]) {
                .rx => |*frame| frame.metadata.timestamp_us = null,
                .tx_started => |*start| start.timestamp_us = null,
                .tx_done => |*done| {
                    done.timestamp = null;
                    if (done.ack) |*ack| ack.metadata.timestamp_us = null;
                },
                else => {},
            }
        }
    }

    /// Update settings as one generation. Use receive() to select a channel.
    pub fn configure(self: *Radio, config: Config) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        if (owner != self) return error.InvalidState;
        try self.normal();
        const old_config = self.rx_settings.current().config;
        var settings = self.rx_settings.current().*;
        settings.config = config;
        settings.config.channel = old_config.channel;
        try validate(settings.config);
        try self.apply_settings_change(settings, old_config.rx_on_when_idle != config.rx_on_when_idle);
    }

    pub fn ieee802154_radio(self: *Radio) Interface {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        if (owner == self and self.enabled) _ = self.resolve();
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Number of FIFO events published when this call takes the snapshot.
    /// A separately reported RX overrun is not a FIFO event.
    pub fn queued_event_count(self: *Radio) usize {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        if (owner != self) return 0;
        return self.queued;
    }

    fn record_receive(self: *Radio) void {
        self.next_request +%= 1;
        self.rx_request = self.next_request;
    }

    fn consume_receive(self: *Radio, accepted: bool, request: ?u64, keep_listening: bool) void {
        if (accepted and !keep_listening and request != null and request == self.rx_request) self.rx_request = null;
    }

    fn idle_state(self: *const Radio) Interface.State {
        const rx_live = self.packet_rx() or self.phase == .auto_ack or self.stopping_rx != null or
            self.rx_request != null or self.poll_response != null or self.replacement_rx();
        return if (rx_live) .receive else .sleep;
    }

    /// A departure earlier in this call left the radio off with its RX
    /// continuation saved. Report the RX that the pended dispatch will arm.
    fn replacement_rx(self: *const Radio) bool {
        return self.rx_replacement == .rx and self.idle_phase() == .rx;
    }

    fn idle_phase(self: *const Radio) Phase {
        return if (self.enabled and (self.rx_request != null or self.poll_response != null or self.rx_settings.current().config.rx_on_when_idle)) .rx else .off;
    }

    fn listen_channel(self: *const Radio) u8 {
        return if (self.poll_response) |response| response.channel else if (self.backoff_listening) self.tx.channel else self.rx_channel;
    }

    fn require_enabled(self: *const Radio) Error!void {
        if (owner != self or !self.enabled) return error.InvalidState;
    }

    fn apply_settings_change(self: *Radio, settings: RxSettings, start_rx_if_idle: bool) Error!void {
        const enabled = settings.config.rx_on_when_idle;
        const closing = self.rx_settings.current().config.rx_on_when_idle and !enabled;
        self.rx_settings.edit().* = settings;
        try self.publish_rx_settings();
        if (closing) {
            self.rx_request = null;
            self.deferred_channel = null;
            if (self.enabled and self.poll_response == null and
                (self.phase.receiving() or (self.phase == .backoff and self.backoff_listening)))
            {
                self.idle_close_pending = true;
                microzig.cpu.interrupt.set_pending(.RADIO);
            }
        } else if (self.enabled and enabled and start_rx_if_idle) {
            if (self.operation == .idle and self.phase == .off and self.rx_replacement == null)
                self.begin_disabled(.rx);
            if (self.phase == .backoff and !self.backoff_listening) {
                self.backoff_listening = true;
                self.start_rx(.{});
            }
        }
    }

    fn rssi_contention(self: *Radio) Error {
        const address = self.read_capture(end_cc) orelse {
            self.enter_fault(.missing_capture);
            return error.Aborted;
        };
        if (self.poll_response) |response|
            if (!response.includes_address(address)) return error.InvalidState;
        return error.Busy;
    }

    fn publish_rx_settings(self: *Radio) Error!void {
        if (@import("builtin").is_test) microzig.Fixture.before_settings_publish();
        const cutover = if (self.rx_armed()) blk: {
            const tick = counter_now();
            if (@import("builtin").is_test) microzig.Fixture.after_settings_tick();
            break :blk if (self.rx_settings.has_room(tick)) tick else try self.wait_settings_cutover(tick);
        } else null;
        if (cutover == null) self.rx_settings.reset_arm(0);
        self.rx_settings.publish(cutover orelse 0);
    }

    fn wait_settings_cutover(self: *Radio, start: u32) Error!?u32 {
        const limit = start +% settings_history_us;
        // The CPU bound also covers stalled TIMER3.
        for (0..transition_checks * 8) |_| {
            try self.normal();
            const armed = self.rx_armed();
            const versions = &self.rx_settings;
            const can_retire = armed and versions.count == RxSettingsVersions.capacity and self.can_retire_settings_entry();
            const tick = counter_now();
            if (phy.tick_reached(tick, limit)) break;
            if (!armed) return null;
            if (versions.has_room(tick)) return tick;
            if (can_retire) {
                versions.oldest = versions.index(1);
                versions.count -= 1;
                return tick;
            }
        }
        self.enter_fault(.radio_timeout);
        return error.Aborted;
    }

    fn can_retire_settings_entry(self: *const Radio) bool {
        const versions = &self.rx_settings;
        const newest = versions.entries[versions.index(versions.count - 1)].tick;
        if (newest -% versions.entries[versions.oldest].tick <= settings_history_us) return false;
        const end = timer.CC[tx_sfd_cc].read().CC;
        if (end == self.capture_prime -% 1) {
            if (self.address_established or (self.close != null and self.close.?.owned) or
                radio.EVENTS_ADDRESS.raw != 0 or radio.EVENTS_END.raw != 0 or radio.EVENTS_DISABLED.raw != 0) return false;
            switch (radio.STATE.read().STATE) {
                .RxDisable, .Disabled => return false,
                else => {},
            }
            return true;
        }
        return end -% self.capture_prime >= versions.entries[versions.index(1)].tick -% self.capture_prime;
    }

    fn normal(self: *Radio) Error!void {
        if (self.enabled and !self.resolve()) return error.Aborted;
        if (@import("builtin").is_test) microzig.Fixture.after_normal();
    }

    // The final TIMER3 sample is the admission decision. The subsequent
    // DISABLED and ADDRESS reads determine only hardware ownership. A due
    // cutoff settles through NORMAL, or through Window expiry alone when a
    // departure earlier in this call left a saved replacement.
    fn admission_tick(self: *Radio) Error!bool {
        const tick = counter_now();
        const response = self.poll_response orelse return false;
        if (!response.due(tick)) return false;
        if (self.phase == .off and self.rx_replacement != null) {
            // A departure earlier in this call saved the replacement, and
            // the pended dispatch owns its setup. Only the cutoff is due,
            // and with the radio off its expiry commits no close.
            self.expire_response();
            return true;
        }
        try self.normal();
        return true;
    }

    fn reserve_completion(self: *Radio, comptime operation: Operation, retries: u8) Error!void {
        var reservation: EventReservation = undefined;
        while (true) {
            if (self.operation != .idle or self.phase == .auto_ack) return error.Busy;
            if (self.close) |close| {
                if (close.owned) return error.Busy;
            } else if (self.rx_reserved and radio.EVENTS_ADDRESS.raw != 0) {
                const tick = self.address_capture() orelse {
                    self.enter_fault(.missing_capture);
                    return error.Aborted;
                };
                if (self.poll_response == null or self.poll_response.?.includes_address(tick))
                    return error.Busy;
            }
            reservation = self.reservation;
            try reservation.reserve(operation, self.queued + @intFromBool(self.rx_reserved), retries);
            if (!try self.admission_tick()) break;
        }
        const close = self.commit_close();
        if (close.fault_reason()) |reason| {
            self.enter_fault(reason);
            return error.Aborted;
        }
        if (close.owned and self.stopping_rx == null)
            self.stopping_rx = .{ .channel = self.listen_channel(), .request = self.arm_request };
        self.reservation = reservation;
        if (operation == .cca) self.cca_state = self.idle_state();
        self.operation = operation;
    }

    fn retire_response(self: *Radio) void {
        self.poll_response = null;
        self.deferred_channel = null;
    }

    fn promote_response(self: *Radio) void {
        if (self.deferred_channel) |channel| {
            self.rx_channel = channel;
            self.record_receive();
        }
        self.retire_response();
    }

    fn expire_response(self: *Radio) void {
        if (self.poll_response == null) return;
        if (self.packet_rx() and self.phase != .ack_rx and self.phase != .ack_drain) {
            const close = self.commit_close();
            if (close.fault_reason()) |reason| {
                self.enter_fault(reason);
                return;
            }
            if (close.owned and self.stopping_rx == null)
                self.stopping_rx = .{ .channel = self.listen_channel(), .request = null };
        }
        self.promote_response();
        if (self.backoff_tick == null) self.disarm_deadline();
        self.request_event_notification();
        if (self.phase.receiving()) self.transition(.rx);
    }

    fn request_event_notification(self: *Radio) void {
        self.notify_pending = true;
        if (self.enabled and self.notify != null) microzig.cpu.interrupt.set_pending(.RADIO);
    }

    fn report_overrun(self: *Radio) void {
        if (self.overrun == 0) {
            self.overrun_before = self.queued;
            self.request_event_notification();
        }
        self.overrun +|= 1;
    }

    fn enqueue(self: *Radio, event: Queued) void {
        std.debug.assert(self.enabled);
        switch (event) {
            // The owner's frame or abort uses its arm's slot. Without one
            // the accounting is broken: the result is lost and counted.
            .rx, .rx_error => if (!self.reservation.has_rx_space(self.queued)) {
                self.record_fault(.event_reservation);
                self.report_overrun();
                return;
            },
            .tx_started => self.reservation.queue_start(),
            .tx_done, .ed_done, .cca_done => self.reservation.queue_terminal(),
        }
        const index = (self.read_index + self.queued) % event_capacity;
        self.queue[index] = event;
        self.queued += 1;
        self.request_event_notification();
    }

    fn take_event(self: *Radio) ?Interface.Event {
        if (self.fault) |fault| {
            self.fault = null;
            return .{ .fault = fault };
        }
        if (self.overrun != 0 and self.overrun_before == 0) {
            self.overrun = 0;
            return .{ .rx_error = .overrun };
        }
        if (self.queued == 0) return null;
        self.overrun_before -|= 1;
        self.starved_reported = false;
        const event = &self.queue[self.read_index];
        self.read_index = (self.read_index + 1) % event_capacity;
        self.queued -= 1;
        switch (event.*) {
            .rx => |*frame| {
                self.delivered = frame.*;
                return .{ .rx = self.delivered.view() };
            },
            .rx_error => |err| return .{ .rx_error = err },
            .tx_started => |start| return .{ .tx_started = start },
            .tx_done => |*done| {
                self.reservation.poll_terminal();
                const ack = if (done.ack) |*frame| blk: {
                    self.delivered = frame.*;
                    break :blk self.delivered.view();
                } else null;
                return .{ .tx_done = .{
                    .status = done.status,
                    .timestamp_us = done.timestamp,
                    .ack = ack,
                } };
            },
            .ed_done => |result| {
                self.reservation.poll_terminal();
                return if (result) |dbm| .{ .energy_scan_done = dbm } else |err| .{ .energy_scan_failed = err };
            },
            .cca_done => |result| {
                self.reservation.poll_terminal();
                return .{ .cca_done = result };
            },
        }
    }

    fn counter_now() u32 {
        return timer3.capture(now_cc);
    }

    fn sample_clock(self: *Radio, tick: u32) bool {
        const rtc_tick = rtc.COUNTER.read().COUNTER;
        const elapsed = tick -% self.public_tick;
        if (elapsed == 0) {
            if (rtc_tick -% self.progress_rtc >= 64) {
                // PS v1.11 §§6.20, 6.30. Confirm with an independent RTC
                // sample across the wait, including the RTC's 24-bit wrap.
                for (0..transition_checks) |_| {
                    if (counter_now() != tick) return true;
                    if (rtc.COUNTER.read().COUNTER -% rtc_tick >= 2) {
                        self.enter_fault(.clock_stalled);
                        return false;
                    }
                }
            }
        } else {
            self.public_time +|= elapsed;
            self.public_tick = tick;
            self.progress_rtc = rtc_tick;
        }
        return true;
    }

    fn timestamp(self: *Radio, capture: u32, lag: u32) u64 {
        const now = counter_now();
        return (self.public_time +| (now -% self.public_tick)) -| (now -% capture) -| lag;
    }

    fn disarm_deadline(self: *Radio) void {
        self.deadline = null;
        self.housekeeping = false;
        timer3.set_compare_interrupt(deadline_cc, false);
        timer3.clear_compare(deadline_cc);
    }

    fn program_compare(_: *Radio, comptime channel: u3, tick: u32) void {
        timer3.set_compare_interrupt(channel, false);
        timer3.clear_compare(channel);
        timer3.set_compare(channel, tick);
        timer3.set_compare_interrupt(channel, true);
        if (phy.tick_reached(counter_now(), tick)) microzig.cpu.interrupt.set_pending(.TIMER3);
    }

    fn arm_at(self: *Radio, tick: u32) void {
        self.deadline = tick;
        self.housekeeping = false;
        self.program_compare(deadline_cc, tick);
    }

    fn arm_after(self: *Radio, delay_us: u32) void {
        self.arm_at(counter_now() +% delay_us);
    }

    const Close = struct {
        disabled: bool = false,
        unexpected_disabled: bool = false,
        owned: bool = false,
        address_tick: ?u32 = null,
        missing_capture: bool = false,
        revocation_failed: bool = false,
        watchdog: ?u32 = null,

        fn fault_reason(self: Close) ?Interface.FaultReason {
            if (self.revocation_failed) return .producer_revocation;
            if (self.unexpected_disabled) return .unexpected_disabled;
            if (self.missing_capture) return .missing_capture;
            return null;
        }
    };

    fn commit_close(self: *Radio) Close {
        return self.commit_close_kind(false);
    }

    fn commit_rx_completion(self: *Radio) Close {
        if (self.close) |close| return close;
        // Sample again at commitment. The earlier resolver slot check
        // may have found the slot still live.
        const slot_proceed = self.phase == .backoff and self.backoff_listening and self.slot_due();
        return self.commit_close_kind(slot_proceed);
    }

    fn commit_close_kind(self: *Radio, slot_proceed: bool) Close {
        if (self.close) |close| return close;
        const sender = self.phase == .ack_rx or self.phase == .ack_drain;
        const cutoff = if (self.poll_response) |response| response.end_deadline else if (sender) self.sender_ack_cutoff() else null;
        var close = commit_boundary(&self.close, self, .{
            .buffer_missing = self.packet_rx() and !self.rx_reserved,
            .reserved = self.rx_reserved,
            .established = self.address_established,
            .cutoff = cutoff,
            .slot_proceed = slot_proceed,
        });
        // A committed RX close cannot acquire a later ADDRESS. Keep the
        // latch and route until its old arm is reconciled.
        if (self.rx_reserved) mask_radio(.{ .ADDRESS = .Enabled });
        if (self.ramped and close.owned and !close.disabled and !close.missing_capture) {
            if (!self.revoke_producers(.reuse_cc0)) {
                close.revocation_failed = true;
                self.close = close;
                return close;
            }
            close.watchdog = counter_now() +% retained_close_us;
            self.close = close;
            self.program_compare(ack_launch_cc, close.watchdog.?);
        }
        return close;
    }

    fn disabled_latch(_: *Radio) bool {
        if (@import("builtin").is_test) microzig.Fixture.before_disabled_read();
        return radio.EVENTS_DISABLED.raw != 0;
    }

    fn address_latch(_: *Radio) bool {
        if (@import("builtin").is_test) microzig.Fixture.before_address_read();
        const address = radio.EVENTS_ADDRESS.raw != 0;
        if (@import("builtin").is_test) microzig.Fixture.after_address_read();
        return address;
    }

    fn rx_armed(self: *const Radio) bool {
        return self.enabled and self.rx_reserved and (self.packet_rx() or self.stopping_rx != null);
    }

    fn packet_rx(self: *const Radio) bool {
        return self.phase.receiving() or self.phase == .ack_rx or self.phase == .ack_drain or
            (self.phase == .backoff and self.backoff_listening);
    }

    fn transition(self: *Radio, next: Phase) void {
        if (self.phase == .stopping) {
            self.after_stop = next;
            if (self.retained_close_ready()) {
                self.consume_disabled();
            } else if (self.enabled) {
                self.arm_retained_deadline();
            }
            return;
        }
        if (self.phase == .off and self.rx_replacement != null) {
            // The departure that saved this replacement ran in the same call.
            // Admission's ownership read left a quiet close record, so retire
            // it and make the admitted phase the sole saved continuation.
            if (!self.retire_for_transition()) return;
            self.rx_replacement = next;
            return;
        }
        const close = self.commit_close();
        if (close.fault_reason()) |reason| {
            self.enter_fault(reason);
            return;
        }
        const retain_rx = self.packet_rx() and close.owned;
        if (retain_rx) {
            if (!self.revoke_producers(.retain_rx)) {
                self.enter_fault(.producer_revocation);
                return;
            }
        } else if (!self.quiesce_close()) {
            return;
        }
        self.stopped_phase = self.phase;
        if (retain_rx and self.stopping_rx == null and self.phase != .ack_rx and self.phase != .ack_drain)
            self.stopping_rx = .{ .channel = self.listen_channel(), .request = self.arm_request };
        self.disarm_deadline();
        self.phase = .stopping;
        self.after_stop = next;
        if (retain_rx and !self.retained_close_ready()) {
            if (self.enabled) self.arm_retained_deadline();
            return;
        }
        self.consume_disabled();
    }

    const Revocation = enum { stop, close, retain_rx, reuse_cc0, retire };

    fn revoke_producers(self: *const Radio, mode: Revocation) bool {
        // PS v1.11 §§6.16 and 6.20. In a live close keep ADDRESS and
        // END captures until the saved evidence has been reconciled.
        var captures_revoked = true;
        if (mode == .retire) {
            tx_sfd_capture.disable();
            end_capture.disable();
            const tx_sfd_enabled = tx_sfd_capture.enabled();
            const end_enabled = end_capture.enabled();
            captures_revoked = !tx_sfd_enabled and !end_enabled;
        }
        const cancel_ack = self.phase == .auto_ack and (mode == .stop or mode == .close);
        var cc0_revoked = true;
        if (cancel_ack or mode == .reuse_cc0 or mode == .retire) {
            ack_launch.disable();
            cc0_revoked = !ack_launch.enabled();
        }
        if (mode == .reuse_cc0) return cc0_revoked;
        const shorts: @TypeOf(radio.SHORTS).underlying_type = switch (mode) {
            .stop, .retire => .{},
            .close => .{ .DISABLED_RSSISTOP = .Enabled },
            .retain_rx => rx_close_shorts,
            .reuse_cc0 => unreachable,
        };
        radio.SHORTS.write(shorts);
        const shorts_revoked = radio.SHORTS.raw == @as(u32, @bitCast(shorts));
        if (!captures_revoked or !cc0_revoked or !shorts_revoked) return false;
        if (cancel_ack or mode == .retire) {
            timer3.set_compare_interrupt(ack_launch_cc, false);
            timer3.clear_compare(ack_launch_cc);
        }
        return true;
    }

    fn stop_committed_radio(self: *Radio) bool {
        // A revoked trigger can latch without firing its task. Only
        // current-arm RADIO evidence decides whether to wait.
        switch (radio.STATE.read().STATE) {
            .Disabled => {
                if (!self.ramped and radio.EVENTS_READY.raw == 0 and
                    radio.EVENTS_TXREADY.raw == 0 and radio.EVENTS_RXREADY.raw == 0) return true;
            },
            .RxDisable, .TxDisable => {},
            else => radio.TASKS_DISABLE.write_raw(1),
        }
        return wait_disabled();
    }

    // A retained owner is allowed to finish on air. Once the arm departs
    // or its commit-time watchdog fires, require the original DISABLED.
    fn retained_close_ready(self: *Radio) bool {
        if (radio.EVENTS_DISABLED.raw != 0) return true;
        if (radio.EVENTS_END.raw != 0) return self.finish_shortcut_close();
        if (!self.ramped) return false;
        const expired = if (self.close.?.watchdog) |deadline|
            timer3.compare_pending(ack_launch_cc) or phy.tick_reached(counter_now(), deadline)
        else
            false;
        const departing = switch (radio.STATE.read().STATE) {
            .RxDisable, .Disabled => true,
            else => false,
        };
        if (!expired and !departing) return false;
        if (wait_disabled()) return true;
        self.fail_close_wait();
        return false;
    }

    fn finish_shortcut_close(self: *Radio) bool {
        if (self.rx_armed()) mask_radio(.{ .END = .Enabled });
        const close = self.commit_rx_completion();
        if (close.fault_reason()) |reason| {
            self.enter_fault(reason);
            return false;
        }
        return self.quiesce_close();
    }

    // The fault executor takes over this same close on a failed wait.
    fn quiesce_close(self: *Radio) bool {
        if (!self.revoke_producers(.close)) {
            self.enter_fault(.producer_revocation);
            return false;
        }
        if (self.stop_committed_radio()) return true;
        self.fail_close_wait();
        return false;
    }

    fn fail_close_wait(self: *Radio) void {
        self.close_wait_failed = true;
        self.enter_fault(.radio_timeout);
    }

    fn arm_retained_deadline(self: *Radio) void {
        if (self.backoff_tick) |slot| {
            self.arm_at(slot);
        } else if (self.poll_response) |response| {
            self.arm_at(response.end_deadline);
        }
    }

    fn retire_arm(self: *Radio) bool {
        if (!self.revoke_producers(.retire)) return false;
        radio.INTENCLR.write(.{ .DISABLED = .Enabled });
        _ = radio.INTENCLR.raw;
        clear_disabled();
        self.disarm_deadline();
        clear_phase_interrupts();
        self.rx_settings.reset_arm(0);
        self.close = null;
        self.idle_close_pending = false;
        self.ramped = false;
        self.rx_reserved = false;
        self.stopping_rx = null;
        self.rx_settled = false;
        self.address_established = false;
        self.rx_ready_tick = null;
        self.backoff_listening = false;
        self.measurement_origin = null;
        self.measurement_result = null;
        radio.EVENTS_ADDRESS.write_raw(0);
        radio.EVENTS_END.write_raw(0);
        radio.EVENTS_PHYEND.write_raw(0);
        radio.EVENTS_EDEND.write_raw(0);
        radio.EVENTS_CCAIDLE.write_raw(0);
        radio.EVENTS_CCABUSY.write_raw(0);
        radio.EVENTS_READY.write_raw(0);
        radio.EVENTS_TXREADY.write_raw(0);
        radio.EVENTS_RXREADY.write_raw(0);
        _ = radio.EVENTS_RXREADY.raw;
        return true;
    }

    fn begin_disabled(self: *Radio, requested: Phase) void {
        if (requested == .ack_drain) {
            self.handle_ack_rx();
            return;
        }
        const handoff = self.stopping_rx;
        const backoff_departure = self.phase == .stopping and self.stopped_phase == .backoff;
        if (handoff) |rx| {
            if (!self.finish_retained_rx(rx)) return;
            if (self.phase == .auto_ack) {
                self.after_auto_ack = self.settle_departing_slot(requested, true);
                self.arm_retained_deadline();
                return;
            }
        }
        if (!self.retire_for_transition()) return;
        if (backoff_departure or requested == .backoff or self.earned_tx_terminal() != null) {
            self.finish_backoff_rx(requested, handoff != null, handoff != null);
        } else {
            self.finish_rx_transition(requested, handoff != null);
        }
    }

    fn retire_for_transition(self: *Radio) bool {
        if (self.retire_arm()) return true;
        self.enter_fault(.producer_revocation);
        return false;
    }

    // Preview the post-commit capacity while preparing a replacement.
    // The caller still owns any staged results.
    const ArmSetup = struct {
        dequeue_fifo: bool = false,
    };

    fn finish_backoff_rx(self: *Radio, continuation: Phase, owned: bool, departs_rx: bool) void {
        // The old arm has retired. Keep its saved owner through the
        // slot decision after publication.
        const defer_setup = departs_rx or self.pending_rx != null;
        self.publish_pending_rx();
        if (@import("builtin").is_test) microzig.Fixture.backoff_departure(.published);
        const next = self.settle_departing_slot(continuation, owned);
        if (@import("builtin").is_test) microzig.Fixture.backoff_departure(.settled);
        self.resume_backoff_rx(next, defer_setup);
    }

    fn resume_backoff_rx(self: *Radio, continuation: Phase, departs_rx: bool) void {
        // Only the continuation crosses this boundary. Replacement setup
        // cannot charge another slot to the departing owner.
        if (@import("builtin").is_test) microzig.Fixture.backoff_departure(.released);
        const terminal = self.earned_tx_terminal();
        if (terminal) |status| self.finish_tx(status, null);
        if (!departs_rx and terminal == null) {
            self.start_disabled_arm(continuation);
            return;
        }
        self.defer_rx_replacement(continuation);
    }

    fn defer_rx_replacement(self: *Radio, continuation: Phase) void {
        self.phase = .off;
        radio.PACKETPTR.write_raw(0);
        self.rx_replacement = continuation;
        // The next dispatch must run even when no hook is installed.
        microzig.cpu.interrupt.set_pending(.RADIO);
    }

    fn finish_rx_transition(self: *Radio, continuation: Phase, departs_rx: bool) void {
        const defer_setup = departs_rx or self.pending_rx != null;
        self.publish_pending_rx();
        if (defer_setup) {
            self.defer_rx_replacement(continuation);
        } else {
            self.start_disabled_arm(continuation);
        }
    }

    fn start_disabled_arm(self: *Radio, continuation: Phase) void {
        self.start_replacement_arm(continuation, .{});
    }

    fn start_replacement_arm(self: *Radio, continuation: Phase, setup: ArmSetup) void {
        self.tx_attempt = .{};
        const next = if (continuation == .rx) self.idle_phase() else continuation;
        self.phase = next;
        const channel = switch (next) {
            .ed, .cca => self.measurement_channel,
            .backoff, .tx, .tx_cca, .ack_rx => self.tx.channel,
            .rx => self.listen_channel(),
            else => self.rx_channel,
        };
        radio.FREQUENCY.write(.{ .FREQUENCY = channel_frequency(channel) });

        switch (next) {
            .ed, .cca, .tx, .tx_cca => radio.INTENSET.write(.{ .DISABLED = .Enabled }),
            else => {},
        }
        switch (next) {
            .off => radio.PACKETPTR.write_raw(0),
            .rx, .ack_rx => self.start_rx(setup),
            .backoff => self.begin_backoff(setup),
            .tx, .tx_cca => self.start_tx(next == .tx_cca),
            .ed => {
                radio.EDCNT.write(.{ .EDCNT = @intCast(self.ed_samples - 1) });
                radio.EVENTS_EDEND.write_raw(0);
                radio.INTENSET.write(.{ .READY = .Enabled, .EDEND = .Enabled });
                self.prime_captures();
                connect_capture(ack_launch, &radio.EVENTS_READY, ack_launch_cc);
                radio.SHORTS.write(.{ .READY_EDSTART = .Enabled, .EDEND_DISABLE = .Enabled });
                self.enable_rx();
            },
            .cca => {
                self.prepare_cca();
                self.prime_captures();
                connect_capture(ack_launch, &radio.EVENTS_RXREADY, ack_launch_cc);
                radio.INTENSET.write(.{ .RXREADY = .Enabled, .CCAIDLE = .Enabled, .CCABUSY = .Enabled });
                radio.SHORTS.write(.{
                    .RXREADY_CCASTART = .Enabled,
                    .CCAIDLE_STOP = .Enabled,
                    .CCABUSY_DISABLE = .Enabled,
                });
                self.enable_rx();
            },
            else => unreachable,
        }
        self.request_event_notification();
    }

    fn finish_retained_rx(self: *Radio, handoff: RxHandoff) bool {
        if (radio.EVENTS_END.raw == 0 and !wait_event(&radio.EVENTS_END)) {
            self.enter_fault(.unexpected_disabled);
            return false;
        }
        self.deliver_completed_rx(handoff.channel, handoff.request);
        return self.enabled;
    }

    fn slot_due(self: *Radio) bool {
        const slot = self.backoff_tick orelse return false;
        return phy.tick_reached(counter_now(), slot);
    }

    fn take_slot(self: *Radio) void {
        self.backoff_tick = null;
        self.disarm_deadline();
    }

    // This is the last point that can charge a slot to the departing owner.
    // A retry gets a new absolute deadline; the old slot cannot run again.
    fn settle_departing_slot(self: *Radio, requested: Phase, owned: bool) Phase {
        if (requested != .backoff or !self.slot_due()) return requested;
        self.take_slot();
        return if (owned) self.busy_assessment() else .tx_cca;
    }

    fn draw_slot(self: *Radio) u32 {
        // IEEE 802.15.4-2006 §7.5.1.4, as in Nordic random_backoff_start.
        const mask: u8 = @intCast((@as(u16, 1) << self.tx.be) - 1);
        const slots = self.random.random().int(u8) & mask;
        return counter_now() +% @as(u32, slots) * backoff_us;
    }

    fn begin_backoff(self: *Radio, setup: ArmSetup) void {
        const tick = self.backoff_tick orelse self.draw_slot();
        self.backoff_tick = tick;
        if (phy.tick_reached(counter_now(), tick)) {
            self.take_slot();
            self.start_replacement_arm(.tx_cca, setup);
            return;
        }
        self.arm_at(tick);
        self.backoff_listening = self.rx_settings.current().config.rx_on_when_idle;
        if (self.backoff_listening) self.start_rx(setup);
    }

    fn set_packet(self: *Radio) void {
        if (!@import("builtin").is_test) asm volatile ("dmb" ::: .{ .memory = true });
        const address = @intFromPtr(&self.packet);
        radio.PACKETPTR.write(.{ .PACKETPTR = if (@import("builtin").is_test) @truncate(address) else address });
    }

    fn load_packet(self: *Radio, bytes: []const u8) void {
        self.packet[0] = @intCast(bytes.len + Interface.fcs_len);
        @memcpy(self.packet[1..][0..bytes.len], bytes);
        self.set_packet();
    }

    const Capture = union(enum) { unread, invalid, tick: u32 };

    fn prime_captures(self: *Radio) void {
        radio.EVENTS_ADDRESS.write_raw(0);
        radio.EVENTS_END.write_raw(0);
        radio.EVENTS_READY.write_raw(0);
        radio.EVENTS_RXREADY.write_raw(0);
        _ = radio.EVENTS_RXREADY.raw;
        self.capture_prime = counter_now();
        self.captures = @splat(.unread);
        inline for ([_]u3{ ack_launch_cc, tx_sfd_cc, end_cc }) |cc|
            timer3.set_compare(cc, self.capture_prime -% 1);
    }

    fn read_capture(self: *Radio, comptime cc: u3) ?u32 {
        const cached = &self.captures[
            switch (cc) {
                ack_launch_cc => 0,
                tx_sfd_cc => 1,
                end_cc => 2,
                else => @compileError("not a RADIO capture channel"),
            }
        ];
        switch (cached.*) {
            .tick => |tick| return tick,
            .invalid => return null,
            .unread => {},
        }
        for (0..capture_checks) |_| {
            const value = timer.CC[cc].read().CC;
            if (capture_in_arm(self.capture_prime, value, counter_now())) {
                cached.* = .{ .tick = value };
                return value;
            }
        }
        cached.* = .invalid;
        return null;
    }

    fn address_capture(self: *Radio) ?u32 {
        return self.read_capture(end_cc);
    }

    fn start_rx(self: *Radio, setup: ArmSetup) void {
        radio.INTENSET.write(.{ .DISABLED = .Enabled });
        self.arm_request = if (self.phase == .rx and self.poll_response == null) self.rx_request else null;
        const queued = self.queued - @intFromBool(setup.dequeue_fifo);
        self.rx_reserved = self.phase == .ack_rx or self.reservation.has_rx_space(queued);
        radio.SHORTS.write(.{ .DISABLED_RSSISTOP = .Enabled });
        if (self.rx_reserved) {
            self.prime_captures();
            self.rx_settings.reset_arm(self.capture_prime);
            connect_capture(tx_sfd_capture, &radio.EVENTS_END, tx_sfd_cc);
            connect_capture(end_capture, &radio.EVENTS_ADDRESS, end_cc);
            if (self.phase != .ack_rx) connect_capture(ack_launch, &radio.EVENTS_RXREADY, ack_launch_cc);
            // RADIO anomaly 110 (Engineering A): disable after each RX frame.
            radio.SHORTS.write(.{
                .RXREADY_START = .Enabled,
                .ADDRESS_RSSISTART = .Enabled,
                .END_DISABLE = .Enabled,
                .DISABLED_RSSISTOP = .Enabled,
            });
            radio.INTENSET.write(.{ .END = .Enabled, .ADDRESS = .Enabled });
            self.set_packet();
        } else {
            radio.PACKETPTR.write_raw(0);
        }
        const cutoff: ?u32 = switch (self.phase) {
            .ack_rx => self.sender_ack_cutoff(),
            .rx => if (self.poll_response) |response| response.end_deadline else null,
            .backoff => self.backoff_tick,
            else => unreachable,
        };
        if (self.phase != .backoff) {
            if (cutoff) |tick| {
                self.arm_at(tick);
            } else if (self.rx_reserved) {
                timer3.set_compare(deadline_cc, counter_now() +% (1 << 31));
                timer3.clear_compare(deadline_cc);
                self.housekeeping = true;
                timer3.set_compare_interrupt(deadline_cc, true);
            }
        }
        // The setup above can cross the cutoff with IRQs masked. There is
        // no departing RX owner if this arm never issued RXEN.
        if (cutoff) |tick| {
            if (phy.tick_reached(counter_now(), tick)) {
                switch (self.phase) {
                    .ack_rx => {
                        if (!self.retire_for_transition()) return;
                        self.start_retry_or_finish();
                    },
                    .rx => {
                        if (!self.retire_for_transition()) return;
                        self.promote_response();
                        self.start_replacement_arm(.rx, setup);
                    },
                    .backoff => {
                        if (!self.retire_for_transition()) return;
                        self.take_slot();
                        self.start_replacement_arm(.tx_cca, setup);
                    },
                    else => unreachable,
                }
                return;
            }
        }
        // Nordic notify_no_rx_buffer: frames may be lost while RX listens
        // without a slot. Report once until poll frees one.
        if (!self.rx_reserved and !self.starved_reported) {
            self.starved_reported = true;
            self.report_overrun();
        }
        self.enable_rx();
    }

    fn enable_rx(self: *Radio) void {
        self.ramped = true;
        radio.TASKS_RXEN.write_raw(1);
    }

    fn psdu_payload_len(phr: u8) ?u8 {
        if (phr < Interface.fcs_len or phr > Interface.max_psdu_len) return null;
        return phr - Interface.fcs_len;
    }

    /// The finished RX, read in place: `bytes` aliases the DMA buffer and is
    /// valid until the buffer is reused for the next RX or an ACK.
    fn received_frame(self: *Radio, channel: u8, deliver_bad_fcs: bool, end: u32) ?Interface.RxFrame {
        // PS v1.11 RADIO, Receive sequence and RXCRC. EasyDMA omits FCS,
        // appends LQI, and holds these samples until the next reception.
        const fcs_ok = radio.CRCSTATUS.read().CRCSTATUS == .CRCOk;
        if (!fcs_ok and !deliver_bad_fcs) return null;
        if (!@import("builtin").is_test) asm volatile ("dmb" ::: .{ .memory = true });
        const length = self.packet[0];
        const length_without_fcs = psdu_payload_len(length) orelse return null;
        const crc: u16 = @truncate(radio.RXCRC.read().RXCRC);
        return .{
            .bytes = self.packet[1..][0..length_without_fcs],
            .fcs = .{ @truncate(crc), @truncate(crc >> 8) },
            .fcs_ok = fcs_ok,
            .channel = channel,
            .rssi = if (radio.EVENTS_ADDRESS.raw != 0)
                read_rssi_dbm(self.adjustment)
            else
                -128,
            .lqi = correct_level(self.packet[1 + @as(usize, length_without_fcs)], self.adjustment) *| 4,
            .timestamp_us = self.timestamp(end, phy.rx_end_delay_us + phy.sfd_to_frame_end_us(length)),
        };
    }

    fn deliver_completed_rx(self: *Radio, channel: u8, request: ?u64) void {
        if (!self.close.?.owned) return;
        const end = self.read_capture(tx_sfd_cc) orelse {
            self.enter_fault(.missing_capture);
            return;
        };
        const settings = self.rx_settings.at_end(end, self.capture_prime);
        // Classify in place and copy only an accepted frame, before the ACK
        // reuses the buffer, as Nordic's nrf_802154_core.c parses in place.
        const accepted = if (self.received_frame(channel, settings.deliver_bad_fcs, end)) |rx|
            self.accept_received_frame(&rx, settings.classify(rx.bytes, rx.fcs_ok, true))
        else
            false;
        if (!self.enabled) return;
        if (accepted and !settings.config.rx_on_when_idle) {
            if (self.phase == .auto_ack) {
                self.consume_receive(true, request, false);
            } else {
                self.pending_rx_request = request;
            }
        }
    }

    fn handle_rx(self: *Radio) void {
        self.deliver_completed_rx(self.listen_channel(), self.arm_request);
        if (!self.enabled) return;
        if (self.phase == .auto_ack) {
            self.arm_retained_deadline();
        } else if (self.retire_for_transition()) {
            self.finish_rx_transition(.rx, true);
        }
    }

    /// Return true once the frame is queued or has a queue slot waiting for its ACK.
    fn accept_received_frame(self: *Radio, rx: *const Interface.RxFrame, disposition: RxSettings.Disposition) bool {
        if (disposition == .reject) return false;

        // Only a reserved arm owns a frame, and its FIFO slot stays free
        // until the frame is published or the arm retires: only the
        // owner's frame or its abort uses that slot, and Transmit, ED and
        // CCA count it or refuse the owner (reserve_completion). A full
        // FIFO here is broken accounting, reported as a fault.
        if (!self.reservation.has_rx_space(self.queued)) {
            self.enter_fault(.event_reservation);
            return false;
        }
        Frame.store(&self.pending_rx, rx);
        if (disposition == .ack) {
            const ack = disposition.ack;
            self.pending_rx.?.metadata.acked_with_frame_pending = ack.pending;
            if (self.arm_auto_ack(ack.sequence, ack.pending, ack.power)) return true;
            if (!self.enabled) return false;
        }
        return true;
    }

    fn arm_auto_ack(self: *Radio, sequence: u8, pending: bool, power: i8) bool {
        // Retire END before reusing the packet buffer for the ACK.
        mask_radio(.{ .END = .Enabled });

        // PS v1.11 RADIO and PPI. Schedule from captured END, allowing for
        // the END pipeline and fast ramp-up. Never arm an already late ACK.
        const end = self.read_capture(tx_sfd_cc) orelse return false;
        const tick = end +% phy.ack_txen_us;
        if (phy.tick_reached(counter_now(), tick -% 4)) return false;
        if (!self.retire_for_transition()) return false;
        ack_launch.connect(&timer.EVENTS_COMPARE[ack_launch_cc], &radio.TASKS_TXEN, null) catch unreachable;
        self.load_packet(&.{ if (pending) 0x12 else 0x02, 0x00, sequence });
        set_radio_power(power);
        radio.EVENTS_PHYEND.write_raw(0);
        radio.SHORTS.write(tx_shorts);
        timer3.set_compare(ack_launch_cc, tick);
        timer3.clear_compare(ack_launch_cc);
        radio.INTENSET.write(.{ .DISABLED = .Enabled, .PHYEND = .Enabled });
        if (phy.tick_reached(counter_now(), tick -% 4)) {
            return false;
        }

        self.phase = .auto_ack;
        ack_launch.enable();
        return true;
    }

    fn publish_pending_rx(self: *Radio) void {
        if (self.pending_rx) |frame| {
            self.consume_receive(true, self.pending_rx_request, false);
            self.enqueue(.{ .rx = frame.with_ack_result(frame.metadata.ack_sent) });
        }
        self.pending_rx = null;
        self.pending_rx_request = null;
    }

    fn prepare_cca(self: *const Radio) void {
        radio.EVENTS_CCAIDLE.write_raw(0);
        radio.EVENTS_CCABUSY.write_raw(0);
        radio.CCACTRL.write(.{
            .CCAMODE = switch (self.rx_settings.current().config.cca_mode) {
                .energy => .EdMode,
                .carrier => .CarrierMode,
                .carrier_and_energy => .CarrierAndEdMode,
                .carrier_or_energy => .CarrierOrEdMode,
                .energy_test => .EdModeTest1,
            },
            // Anomaly 153, Nordic nrf_802154_rssi_cca_ed_threshold_corrected_get.
            .CCAEDTHRES = correct_level(@intCast(@max(0, @as(i16, self.rx_settings.current().config.cca_threshold) - phy.ed_offset_dbm)), self.adjustment),
        });
    }

    fn start_tx(self: *Radio, use_cca: bool) void {
        self.load_packet(self.tx.bytes[0..self.tx.len]);
        set_radio_power(self.tx.power orelse self.rx_settings.current().config.tx_power);
        radio.EVENTS_TXREADY.write_raw(0);
        radio.EVENTS_ADDRESS.write_raw(0);
        radio.EVENTS_END.write_raw(0);
        radio.EVENTS_PHYEND.write_raw(0);
        self.prime_captures();
        connect_capture(tx_sfd_capture, &radio.EVENTS_ADDRESS, tx_sfd_cc);
        connect_capture(end_capture, &radio.EVENTS_PHYEND, end_cc);
        radio.INTENSET.write(.{ .TXREADY = .Enabled, .PHYEND = .Enabled });
        if (use_cca) {
            self.prepare_cca();
            connect_capture(ack_launch, &radio.EVENTS_RXREADY, ack_launch_cc);
            radio.INTENSET.write(.{ .RXREADY = .Enabled, .CCAIDLE = .Enabled, .CCABUSY = .Enabled });
            radio.SHORTS.write(.{
                .RXREADY_CCASTART = .Enabled,
                .CCAIDLE_STOP = .Enabled,
                .CCAIDLE_TXEN = .Enabled,
                .CCABUSY_DISABLE = .Enabled,
                .PHYEND_DISABLE = .Enabled,
            });
            self.enable_rx();
        } else {
            radio.SHORTS.write(.{ .PHYEND_DISABLE = .Enabled });
            self.ramped = true;
            radio.TASKS_TXEN.write_raw(1);
        }
    }

    fn start_attempt(self: *Radio) Phase {
        self.tx.backoffs = 0;
        self.tx.be = self.rx_settings.current().config.min_be;
        return Phase.first_tx_phase(self.tx.csma_ca, self.tx.max_backoffs);
    }

    fn tx_marker(self: *const Radio) ?TxAttempt.Marker {
        return self.tx_attempt.marker(.{
            .address = radio.EVENTS_ADDRESS.raw != 0,
            .phy_end = radio.EVENTS_PHYEND.raw != 0,
        });
    }

    fn tx_capture(self: *Radio, marker: TxAttempt.Marker) ?u64 {
        const tick = (if (marker == .address) self.read_capture(tx_sfd_cc) else self.read_capture(end_cc)) orelse return null;
        // PS v1.11 §6.20 EVENTS_ADDRESS. Nordic nrf_802154_trx uses
        // ADDRESS as the transmitted end-of-SFD marker.
        return self.timestamp(tick, if (marker == .address) 0 else phy.sfd_to_frame_end_us(self.tx.len + Interface.fcs_len));
    }

    fn report_tx_start(self: *Radio, timestamp_us: ?u64) void {
        mask_radio(.{ .ADDRESS = .Enabled });
        self.tx_attempt.reported = true;
        self.queue_tx_start(timestamp_us);
    }

    fn queue_tx_start(self: *Radio, timestamp_us: ?u64) void {
        self.tx.attempts += 1;
        self.tx.timestamp = timestamp_us;
        self.enqueue(.{ .tx_started = .{ .timestamp_us = timestamp_us, .attempt = self.tx.attempts } });
    }

    fn earned_tx_terminal(self: *const Radio) ?Interface.TxStatus {
        return if (self.operation == .tx) self.tx.earned_terminal else null;
    }

    fn finish_tx(self: *Radio, status: Interface.TxStatus, ack: ?Frame) void {
        self.tx.earned_terminal = null;
        self.operation = .idle;
        self.backoff_tick = null;
        if (self.after_stop == .backoff or self.after_stop == .tx_cca) self.after_stop = .rx;
        if (self.after_auto_ack == .backoff or self.after_auto_ack == .tx_cca) self.after_auto_ack = .rx;
        self.enqueue(.{ .tx_done = .{ .status = status, .timestamp = self.tx.timestamp, .ack = ack } });
        self.tx.earned_ack = null;
    }

    fn sender_ack_cutoff(self: *const Radio) u32 {
        return self.tx.on_air_end +% (ack_wait_us + phy.rx_end_delay_us);
    }

    fn handle_tx(self: *Radio) void {
        if (self.tx_attempt.launched and
            (radio.EVENTS_PHYEND.raw != 0 or wait_event(&radio.EVENTS_PHYEND)))
        {
            const start = if (self.tx_marker()) |marker| self.tx_capture(marker) orelse {
                self.enter_fault(.missing_capture);
                return;
            } else null;
            mask_radio(.{ .PHYEND = .Enabled });
            const end = self.read_capture(end_cc) orelse {
                self.enter_fault(.missing_capture);
                return;
            };
            if (!self.retire_for_transition()) return;
            self.tx.on_air_end = end;
            if (self.tx.sequence != null) {
                // Anomaly 204: only switch to RX after DISABLED.
                // Delayed service can leave no live sender ACK window.
                self.staged_tx_start = start;
                if (phy.tick_reached(counter_now(), self.sender_ack_cutoff())) {
                    self.start_retry_or_finish();
                } else {
                    self.start_disabled_arm(.ack_rx);
                    self.publish_staged_tx_start();
                }
            } else {
                if (start) |tick| self.queue_tx_start(tick);
                self.finish_tx(.sent, null);
                self.start_disabled_arm(.rx);
            }
        } else {
            self.enter_fault(.unexpected_disabled);
        }
    }

    fn busy_assessment(self: *Radio) Phase {
        if (!self.tx.charge_busy(self.rx_settings.current().config.max_be)) {
            self.tx.earned_terminal = .channel_access_failure;
            self.backoff_tick = null;
            return .rx;
        }
        self.backoff_tick = self.draw_slot();
        return .backoff;
    }

    fn publish_staged_tx_start(self: *Radio) void {
        if (self.staged_tx_start) |tick| {
            self.staged_tx_start = null;
            self.queue_tx_start(tick);
        }
    }

    fn start_retry_or_finish(self: *Radio) void {
        if (self.tx.retry()) {
            self.start_disabled_arm(self.start_attempt());
            self.publish_staged_tx_start();
        } else {
            self.publish_staged_tx_start();
            self.finish_tx(.no_ack, null);
            // No matching ACK means no response window or timed RX setup.
            self.start_disabled_arm(.rx);
        }
    }

    fn handle_ack_rx(self: *Radio) void {
        const close = self.commit_close();
        if (close.fault_reason()) |reason| {
            self.enter_fault(reason);
            return;
        }
        if (close.owned) {
            if (radio.EVENTS_END.raw == 0 and !wait_event(&radio.EVENTS_END)) {
                self.enter_fault(.unexpected_disabled);
                return;
            }
            const end = self.read_capture(tx_sfd_cc) orelse {
                self.enter_fault(.missing_capture);
                return;
            };
            if (phy.completed_before(end -% self.tx.on_air_end, ack_wait_us)) {
                if (self.received_frame(self.tx.channel, false, end)) |rx| {
                    if (header.ack_matches(rx.bytes, self.tx.sequence.?) == true) {
                        var frame: ?Frame = null;
                        Frame.store(&frame, &rx);
                        const settings = self.rx_settings.at_end(end, self.capture_prime);
                        const window = PollResponse.after_ack(self.tx.channel, end, settings.config.rx_on_when_idle, self.tx.possible_data_request, rx.bytes[0]);
                        // Save the verified ACK before retiring its arm, as
                        // settle_auto_ack does, so a retirement fault
                        // still reports acked.
                        self.tx.earned_terminal = .acked;
                        self.tx.earned_ack = frame;
                        if (!self.retire_for_transition()) return;
                        if (window) |response| {
                            if (!response.due(counter_now())) self.poll_response = response;
                        }
                        self.finish_tx(.acked, frame);
                        self.defer_rx_replacement(.rx);
                        return;
                    }
                }
                if (!self.enabled) return;
            }
        }
        if (!self.retire_for_transition()) return;
        if (self.tx.retry()) {
            self.defer_rx_replacement(self.start_attempt());
        } else {
            self.finish_tx(.no_ack, null);
            self.defer_rx_replacement(.rx);
        }
    }

    fn next_after_auto_ack(self: *Radio) Phase {
        defer self.after_auto_ack = null;
        return self.after_auto_ack orelse .rx;
    }

    fn resolve(self: *Radio) bool {
        if (!self.enabled) return true;
        // Fault takeover may also need to clear results produced earlier
        // in this dispatch. The pended replacement opens a new scope.
        std.debug.assert(self.resolve_first_result == null);
        self.resolve_first_result = self.queued;
        defer self.resolve_first_result = null;
        return self.resolve_enabled();
    }

    fn resolve_enabled(self: *Radio) bool {
        const now = counter_now();
        if (!self.sample_clock(now)) return false;
        if (self.packet_rx() and !self.rx_reserved and self.close == null and radio.EVENTS_DISABLED.raw != 0) {
            _ = self.commit_close();
            self.enter_fault(.unexpected_disabled);
            return false;
        }
        if (self.temp_deadline) |tick| {
            if (phy.tick_reached(now, tick)) {
                if (self.temp_started and temp.EVENTS_DATARDY.raw != 0) {
                    self.adjustment = temperature_adjustment(@bitCast(temp.TEMP.read().TEMP));
                    if (!self.retire_temperature()) {
                        self.enter_fault(.temp_retirement);
                        return false;
                    }
                    start_temperature_sample();
                    self.temp_started = true;
                }
                self.temp_deadline = now +% temperature_sample_us;
                self.program_compare(temperature_cc, self.temp_deadline.?);
            }
        }
        if (self.rx_replacement) |next| {
            self.rx_replacement = null;
            if (next == .rx) {
                if (self.poll_response) |response| {
                    if (response.due(counter_now())) self.promote_response();
                }
            }
            self.start_disabled_arm(next);
            if (!self.enabled) return false;
        }
        for (0..2 + max_frame_retries + 5) |_| {
            if (self.poll_response) |response| {
                if (response.due(counter_now())) self.expire_response();
                if (!self.enabled) return false;
                if (self.rx_replacement != null) return true;
            }
            const old_phase = self.phase;
            const old_deadline = self.deadline;
            self.service_phase();
            if (!self.enabled) return false;
            if (self.rx_replacement != null) return true;
            if (self.phase == old_phase and self.deadline == old_deadline) break;
        }
        if (self.phase == .tx or self.phase == .tx_cca) {
            if (self.tx_marker()) |marker| {
                // A close that arrived after phase service belongs to the
                // next dispatch. Leave its start evidence for that close.
                if (marker == .address and radio.EVENTS_PHYEND.raw == 0 and radio.EVENTS_DISABLED.raw == 0) {
                    const timestamp_us = self.tx_capture(marker) orelse {
                        self.enter_fault(.missing_capture);
                        return false;
                    };
                    if (radio.EVENTS_PHYEND.raw == 0 and radio.EVENTS_DISABLED.raw == 0)
                        self.report_tx_start(timestamp_us);
                }
            }
        }
        return true;
    }

    fn service_phase(self: *Radio) void {
        const on_air = (self.phase == .tx or self.phase == .tx_cca) and self.tx_attempt.launched and radio.EVENTS_PHYEND.raw != 0;
        const phase_before = self.phase;
        if (!on_air and (self.phase == .ed or self.phase == .cca or self.phase == .tx_cca)) {
            if (!self.service_measurement()) return;
            if (phase_before != self.phase) return;
        }
        if (self.phase == .tx or self.phase == .tx_cca) {
            if (!self.tx_attempt.launched and radio.EVENTS_TXREADY.raw != 0 and radio.EVENTS_DISABLED.raw == 0) {
                mask_radio(.{ .TXREADY = .Enabled });
                radio.EVENTS_ADDRESS.write_raw(0);
                radio.INTENSET.write(.{ .ADDRESS = .Enabled });
                self.tx_attempt.launched = true;
                radio.TASKS_START.write_raw(1);
            }
        }
        if (on_air) {
            mask_radio(.{ .PHYEND = .Enabled });
            _ = self.read_capture(end_cc) orelse {
                self.enter_fault(.missing_capture);
                return;
            };
            self.disarm_deadline();
        }
        if (self.phase == .auto_ack) {
            self.service_auto_ack();
            return;
        }
        if (on_air and !self.finish_shortcut_close()) return;
        if (self.phase == .backoff or self.phase == .stopping) {
            if (self.slot_due()) {
                self.service_slot();
                if (!self.enabled or self.rx_replacement != null) return;
            }
        }
        if (self.idle_close_pending) {
            self.idle_close_pending = false;
            const close = self.commit_rx_completion();
            if (close.fault_reason()) |reason| {
                self.enter_fault(reason);
                return;
            }
            if (!close.owned) {
                if (self.quiesce_close()) self.begin_disabled(if (self.phase == .backoff) .backoff else .rx);
                return;
            }
        }
        if (self.close != null and self.close.?.owned and self.rx_armed()) {
            if (self.retained_close_ready()) self.consume_disabled();
        } else if (radio.EVENTS_DISABLED.raw != 0) {
            self.consume_disabled();
        } else if (self.rx_armed() and radio.EVENTS_END.raw != 0) {
            if (self.finish_shortcut_close()) self.consume_disabled();
        }
        if (!self.enabled or self.rx_replacement != null) return;
        if (self.rx_armed() and radio.EVENTS_ADDRESS.raw != 0) {
            mask_radio(.{ .ADDRESS = .Enabled });
            if (self.close == null and !self.address_established) {
                const tick = self.address_capture() orelse {
                    self.enter_fault(.missing_capture);
                    return;
                };
                self.address_established = if (self.poll_response) |response| response.includes_address(tick) else if (self.phase == .ack_rx or self.phase == .ack_drain)
                    !phy.tick_reached(tick, self.sender_ack_cutoff())
                else
                    true;
            }
        }
        if (self.housekeeping and timer3.compare_pending(deadline_cc)) {
            self.disarm_deadline();
            if (radio.EVENTS_ADDRESS.raw == 0) self.transition(.rx);
        }
        const deadline = self.deadline orelse return;
        if (!phy.tick_reached(counter_now(), deadline)) return;
        self.disarm_deadline();
        switch (self.phase) {
            .backoff, .stopping => self.service_slot(),
            .ack_rx, .ack_drain => {
                const close = self.commit_close();
                if (close.fault_reason()) |reason| {
                    self.enter_fault(reason);
                } else if (close.owned) {
                    if (!self.revoke_producers(.retain_rx)) {
                        self.enter_fault(.producer_revocation);
                        return;
                    }
                    self.phase = .ack_drain;
                    if (self.retained_close_ready()) self.consume_disabled();
                } else {
                    // transition and the candidate resolver reuse this record.
                    self.transition(.ack_drain);
                }
            },
            else => {},
        }
    }

    fn service_slot(self: *Radio) void {
        while (self.slot_due()) {
            self.take_slot();
            const close = self.commit_close_kind(true);
            if (close.fault_reason()) |reason| {
                self.enter_fault(reason);
                return;
            }
            const target = if (close.owned) self.busy_assessment() else .tx_cca;
            self.transition(target);
            if (!self.enabled or self.phase != .stopping) return;
        }
        if (self.backoff_tick) |tick| self.arm_at(tick);
    }

    fn service_auto_ack(self: *Radio) void {
        if (self.settle_auto_ack()) |next| {
            if (next == .backoff or self.earned_tx_terminal() != null) {
                // PHYEND released ACK ownership before this slot decision.
                self.finish_backoff_rx(next, false, true);
            } else {
                self.finish_rx_transition(next, true);
            }
        }
    }

    fn settle_auto_ack(self: *Radio) ?Phase {
        while (true) {
            const due = self.slot_due();
            const phyend = @as(u32, @bitCast(radio.EVENTS_PHYEND.read())) != 0;
            const disabled = radio.EVENTS_DISABLED.raw != 0;
            if (disabled or phyend) {
                mask_radio(.{ .PHYEND = .Enabled });
                if (!disabled and !self.finish_shortcut_close()) return null;
                if (!phyend and !wait_event(&radio.EVENTS_PHYEND)) {
                    self.enter_fault(.unexpected_disabled);
                    return null;
                }
                self.pending_rx.?.metadata.ack_sent = true;
                if (!self.retire_for_transition()) return null;
                return self.next_after_auto_ack();
            }
            if (!due) {
                if (self.backoff_tick) |tick| {
                    if (self.deadline != tick) self.arm_at(tick);
                }
                return null;
            }
            self.take_slot();
            self.after_auto_ack = self.busy_assessment();
        }
    }

    fn service_measurement(self: *Radio) bool {
        if (self.measurement_result != null) return true;
        const ed = self.phase == .ed;
        const started = if (ed) radio.EVENTS_READY.raw != 0 else radio.EVENTS_RXREADY.raw != 0;
        if (self.measurement_origin == null and started) {
            self.measurement_origin = self.read_capture(ack_launch_cc) orelse {
                self.enter_fault(.missing_capture);
                return false;
            };
            self.arm_at(self.measurement_origin.? +% (if (ed) self.ed_samples * ed_sample_us else ed_sample_us));
            mask_radio(if (ed) .{ .READY = .Enabled } else .{ .RXREADY = .Enabled });
        }
        const due = if (self.deadline) |tick| phy.tick_reached(counter_now(), tick) else false;
        const wait = due or radio.EVENTS_DISABLED.raw != 0;
        for (0..if (wait) transition_checks else 1) |_| {
            if (self.phase == .tx_cca and self.tx_attempt.launched and radio.EVENTS_PHYEND.raw != 0) return true;
            if (ed) {
                if (radio.EVENTS_EDEND.raw == 0) continue;
                self.measurement_result = .{ .energy = level_dbm(correct_level(radio.EDSAMPLE.read().EDLVL, self.adjustment)) };
                mask_radio(.{ .EDEND = .Enabled });
            } else {
                const clear = radio.EVENTS_CCAIDLE.raw != 0;
                if (!clear and radio.EVENTS_CCABUSY.raw == 0) continue;
                self.measurement_result = .{ .cca = clear };
                mask_radio(.{ .CCAIDLE = .Enabled, .CCABUSY = .Enabled });
            }
            self.disarm_deadline();
            if (ed) {
                if (!self.finish_shortcut_close()) return false;
                self.consume_disabled();
            } else if (self.phase == .cca) {
                _ = self.commit_close();
                if (!self.quiesce_close()) return false;
                self.consume_disabled();
            } else if (self.phase == .tx_cca and !self.measurement_result.?.cca) {
                self.transition(self.busy_assessment());
                return self.enabled;
            }
            return true;
        }
        if (wait) {
            self.enter_fault(.radio_timeout);
            return false;
        }
        return true;
    }

    fn consume_disabled(self: *Radio) void {
        mask_radio(if (self.rx_armed())
            .{ .DISABLED = .Enabled, .END = .Enabled, .ADDRESS = .Enabled }
        else
            .{ .DISABLED = .Enabled });
        switch (self.phase) {
            .stopping => self.begin_disabled(self.after_stop),
            .rx, .backoff => {
                const backoff = self.phase == .backoff;
                if (backoff and !self.backoff_listening) {
                    self.enter_fault(.unexpected_disabled);
                    return;
                }
                const close = self.commit_rx_completion();
                if (close.fault_reason()) |reason| {
                    self.enter_fault(reason);
                    return;
                }
                // A rejected frame needs no further packet evidence once
                // the saved DISABLED and current-arm END capture agree.
                const captured_departure = !close.owned and close.disabled and
                    radio.EVENTS_END.raw == 0 and self.read_capture(tx_sfd_cc) != null;
                if (!captured_departure and radio.EVENTS_END.raw == 0 and !wait_event(&radio.EVENTS_END)) {
                    self.enter_fault(.unexpected_disabled);
                    return;
                }
                if (!backoff) {
                    self.handle_rx();
                    return;
                }
                self.deliver_completed_rx(self.tx.channel, null);
                if (!self.enabled) return;
                // ACK setup may have retired the hardware arm or declined
                // launch after crossing the slot. The copied close still owns
                // the frame through the decision.
                if (self.phase == .auto_ack) {
                    self.after_auto_ack = self.settle_departing_slot(.backoff, close.owned);
                    self.arm_retained_deadline();
                } else {
                    if (!self.retire_for_transition()) return;
                    self.finish_backoff_rx(.backoff, close.owned, true);
                }
            },
            .auto_ack => self.service_auto_ack(),
            .tx, .tx_cca => self.handle_tx(),
            .ack_rx, .ack_drain => self.handle_ack_rx(),
            .ed, .cca => {
                const result = self.measurement_result orelse {
                    self.enter_fault(.unexpected_disabled);
                    return;
                };
                if (!self.retire_for_transition()) return;
                self.operation = .idle;
                switch (result) {
                    .energy => |energy| self.enqueue(.{ .ed_done = energy }),
                    .cca => |clear| self.enqueue(.{ .cca_done = clear }),
                }
                self.start_disabled_arm(.rx);
            },
            .off => clear_disabled(),
        }
    }
};

const rx_close_shorts: @TypeOf(radio.SHORTS).underlying_type = .{
    .ADDRESS_RSSISTART = .Enabled,
    .END_DISABLE = .Enabled,
    .DISABLED_RSSISTOP = .Enabled,
};
const tx_shorts: @TypeOf(radio.SHORTS).underlying_type = .{ .TXREADY_START = .Enabled, .PHYEND_DISABLE = .Enabled };

pub fn radio_interrupt() callconv(.c) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    const self = owner orelse return;
    if (self.enabled and self.resolve() and self.notify_pending) self.deliver_wake();
}

pub fn timer_interrupt() callconv(.c) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    if (owner) |self| _ = self.resolve();
}

const Dispatch = struct {
    fn get(ptr: *anyopaque) *Radio {
        return @ptrCast(@alignCast(ptr));
    }

    fn capabilities(ptr: *anyopaque) Interface.Capabilities {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner == self) _ = self.resolve();
        return .{
            .energy_scan = true,
            .csma_backoff = true,
            .transmit_retries = true,
            .ack_timeout = true,
            .sleep_to_tx = true,
            .rx_on_when_idle = true,
            .src_match = true,
            .bad_fcs_delivery = true,
        };
    }

    fn now_us(ptr: *anyopaque) u64 {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return 0;
        if (self.enabled) _ = self.resolve();
        return self.public_time;
    }

    fn state(ptr: *anyopaque) Interface.State {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self or !self.enabled or !self.resolve()) return .disabled;
        return switch (self.operation) {
            .tx => .transmit,
            .ed => .energy_scan,
            .cca => self.cca_state,
            .idle => self.idle_state(),
        };
    }

    fn receive_sensitivity(ptr: *anyopaque) i8 {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner == self and self.enabled) _ = self.resolve();
        // PS v1.11 RADIO, IEEE 802.15.4 RX sensitivity (typical).
        return -100;
    }

    fn enable(ptr: *anyopaque) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return error.InvalidState;
        if (self.enabled) {
            if (!self.resolve()) return error.HardwareFault;
            return;
        }
        return self.start_lifecycle();
    }

    fn disable(ptr: *anyopaque) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self or !self.enabled) return;
        return self.execute_stop(true, null);
    }

    fn sleep(ptr: *anyopaque) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        try self.require_enabled();
        return self.execute_stop(false, null);
    }

    fn receive(ptr: *anyopaque, channel: u8) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        try self.require_enabled();
        if (self.operation != .idle) return error.Busy;
        if (!valid_channel(channel)) return error.InvalidArgument;
        const committed_channel = if (self.poll_response != null)
            self.listen_channel()
        else if (self.stopping_rx) |handoff|
            handoff.channel
        else
            self.rx_channel;
        if (channel != committed_channel and (self.rx_request == null or channel != self.rx_channel)) {
            try self.execute_stop(false, null);
        } else {
            try self.normal();
            _ = try self.admission_tick();
        }
        if (self.poll_response) |response| {
            if (channel == response.channel) {
                self.deferred_channel = channel;
                return;
            }
        }
        if (self.phase == .auto_ack) return error.Busy;
        if (self.stopping_rx) |handoff| {
            if (handoff.channel != channel) return error.Busy;
        } else if (self.rx_armed() and channel != self.listen_channel() and radio.EVENTS_ADDRESS.raw != 0) {
            const capture = self.address_capture() orelse {
                self.enter_fault(.missing_capture);
                return error.Aborted;
            };
            if (self.poll_response == null or self.poll_response.?.includes_address(capture)) return error.Busy;
        }
        const same_arm = self.phase.receiving() and channel == self.listen_channel();
        const bind_new = same_arm and self.poll_response == null and !self.address_latch();
        const needs_handoff = self.phase != .off and !same_arm and self.poll_response == null;
        if (needs_handoff) {
            const close = self.commit_close();
            if (close.fault_reason()) |reason| {
                self.enter_fault(reason);
                return error.Aborted;
            }
            if (close.owned and self.stopping_rx == null)
                self.stopping_rx = .{ .channel = self.listen_channel(), .request = self.arm_request };
        }
        const previous_channel = self.rx_channel;
        self.record_receive();
        self.deferred_channel = null;
        self.rx_channel = channel;
        if (self.phase == .off) {
            if (self.rx_replacement == null) self.begin_disabled(.rx);
        } else if (needs_handoff) {
            self.transition(.rx);
        }
        if (!self.enabled) {
            // A fault in this Receive's own handoff records no request; Fault
            // transition already retired the request it staged.
            self.rx_channel = previous_channel;
            return error.Aborted;
        }
        if (bind_new) self.arm_request = self.rx_request;
    }

    fn transmit(ptr: *anyopaque, request: *const Interface.TxRequest) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        try self.require_enabled();
        try self.normal();
        if (request.tx_at_us != null) return error.Unsupported;
        if (!valid_channel(request.channel) or
            !phy.valid_csma_backoffs(request.csma_ca, request.max_csma_backoffs) or
            request.max_frame_retries > max_frame_retries)
            return error.InvalidArgument;
        if (request.tx_power) |power| if (!valid_power(power)) return error.InvalidArgument;
        const bytes = request.bytes;
        const ack_header = try header.tx_ack_header(bytes);
        const retries = if (ack_header != null) request.max_frame_retries else 0;
        try self.reserve_completion(.tx, retries);
        self.tx = .{
            .len = @intCast(bytes.len),
            .sequence = if (ack_header) |h| h.sequence else null,
            .possible_data_request = if (ack_header) |h| h.possible_data_request(bytes) else false,
            .channel = request.channel,
            .power = request.tx_power,
            .csma_ca = request.csma_ca,
            .max_backoffs = request.max_csma_backoffs,
            .retries_left = retries,
        };
        @memcpy(self.tx.bytes[0..bytes.len], bytes);
        const phase = self.start_attempt();
        self.retire_response();
        self.transition(phase);
    }

    fn energy_scan(ptr: *anyopaque, channel: u8, duration: u32) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        try self.require_enabled();
        try self.normal();
        if (!valid_channel(channel)) return error.InvalidArgument;
        const samples = ed_sample_count(duration) orelse return error.InvalidArgument;
        try self.reserve_completion(.ed, 0);
        self.measurement_channel = channel;
        self.ed_samples = samples;
        self.retire_response();
        self.transition(.ed);
    }

    fn cca(ptr: *anyopaque) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        try self.require_enabled();
        try self.normal();
        try self.reserve_completion(.cca, 0);
        self.measurement_channel = if (self.poll_response) |response| response.channel else self.rx_channel;
        self.retire_response();
        self.transition(.cca);
    }

    fn rssi(ptr: *anyopaque) Error!i8 {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        try self.require_enabled();
        try self.normal();
        if (self.phase == .auto_ack or (self.close != null and self.close.?.owned)) return error.Busy;
        if (!self.packet_rx() or !self.rx_reserved or self.phase == .ack_rx or self.phase == .ack_drain)
            return error.InvalidState;
        if (radio.EVENTS_ADDRESS.raw != 0) return self.rssi_contention();
        const state_value = radio.STATE.read().STATE;
        if (state_value != .Rx and state_value != .RxIdle) return error.InvalidState;
        if (!self.rx_settled) {
            if (radio.EVENTS_RXREADY.raw == 0) return error.InvalidState;
            if (self.rx_ready_tick == null) {
                self.rx_ready_tick = self.read_capture(ack_launch_cc) orelse {
                    self.enter_fault(.missing_capture);
                    return error.Aborted;
                };
            }
            if (Radio.counter_now() -% self.rx_ready_tick.? < 16) return error.InvalidState;
            self.rx_settled = true;
        }
        radio.EVENTS_RSSIEND.write_raw(0);
        _ = radio.EVENTS_RSSIEND.raw;
        if (radio.EVENTS_ADDRESS.raw != 0) return self.rssi_contention();
        if (self.poll_response) |response| if (response.due(Radio.counter_now())) return error.InvalidState;
        radio.TASKS_RSSISTART.write_raw(1);
        for (0..transition_checks) |_| {
            if (radio.EVENTS_ADDRESS.raw != 0) return self.rssi_contention();
            if (radio.EVENTS_RSSIEND.raw == 0) continue;
            const value = read_rssi_dbm(self.adjustment);
            if (radio.EVENTS_ADDRESS.raw != 0) return self.rssi_contention();
            return value;
        }
        if (radio.EVENTS_ADDRESS.raw != 0) return self.rssi_contention();
        self.enter_fault(.radio_timeout);
        return error.Aborted;
    }

    fn poll(ptr: *anyopaque, mode: Interface.PollMode) ?Interface.Event {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return null;
        const faulted = self.enabled and !self.resolve();
        if (mode == .preserve_fault and (!self.enabled or self.fault != null)) return null;
        var restore_rx: ?Phase = null;
        var rearm_faulted = false;
        if (self.enabled and self.fault == null and self.packet_rx() and !self.rx_reserved and self.queued != 0 and
            (self.overrun == 0 or self.overrun_before != 0) and self.reservation.has_rx_space(self.queued - 1))
        {
            const close = self.commit_close();
            if (close.fault_reason()) |reason| {
                self.enter_fault(reason);
            } else if (self.quiesce_close() and self.retire_for_transition()) {
                restore_rx = if (self.phase == .backoff) .backoff else .rx;
            }
            rearm_faulted = restore_rx == null;
            if (rearm_faulted and mode == .preserve_fault) return null;
        }
        if (restore_rx) |next| {
            self.start_replacement_arm(next, .{ .dequeue_fifo = true });
            rearm_faulted = !self.enabled;
            if (rearm_faulted and mode == .preserve_fault) return null;
        }
        const event = self.take_event();
        if (!faulted and !rearm_faulted) {
            if (!self.enabled) {
                if (self.backlog()) self.deliver_wake();
            } else if (self.backlog() or (event != null and self.reservation.remaining == null)) {
                self.request_event_notification();
            }
        }
        return event;
    }

    fn fault_pending(ptr: *anyopaque) Interface.FaultPending {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return .{};
        const fault = self.fault orelse return .{};
        return .{ .pending = true, .reason = fault.reason, .count = fault.count };
    }

    fn set_notify(ptr: *anyopaque, notify: ?Interface.Notify) void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return;
        self.notify = notify;
        if (self.enabled) {
            if (!self.resolve()) return;
            if (self.notify_pending or self.backlog()) self.request_event_notification();
        } else self.deliver_wake();
    }

    fn set_pan_id(ptr: *anyopaque, pan: u16) void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return;
        if (self.enabled and !self.resolve()) return;
        self.rx_settings.edit().config.pan_id = pan;
        self.publish_rx_settings() catch return;
    }

    fn set_short_address(ptr: *anyopaque, address: u16) void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return;
        if (self.enabled and !self.resolve()) return;
        self.rx_settings.edit().config.short_address = address;
        self.publish_rx_settings() catch return;
    }

    fn set_extended_address(ptr: *anyopaque, address: [8]u8) void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return;
        if (self.enabled and !self.resolve()) return;
        self.rx_settings.edit().config.extended_address = address;
        self.publish_rx_settings() catch return;
    }

    fn set_pan_coordinator(ptr: *anyopaque, enabled: bool) void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return;
        if (self.enabled and !self.resolve()) return;
        self.rx_settings.edit().pan_coordinator = enabled;
        self.publish_rx_settings() catch return;
    }

    fn set_promiscuous(ptr: *anyopaque, enabled: bool) void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return;
        if (self.enabled and !self.resolve()) return;
        self.rx_settings.edit().config.promiscuous = enabled;
        self.publish_rx_settings() catch return;
    }

    fn get_promiscuous(ptr: *anyopaque) bool {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return false;
        if (self.enabled) _ = self.resolve();
        return self.rx_settings.current().config.promiscuous;
    }

    fn set_deliver_bad_fcs(ptr: *anyopaque, enabled: bool) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return error.InvalidState;
        try self.normal();
        self.rx_settings.edit().deliver_bad_fcs = enabled;
        try self.publish_rx_settings();
    }

    fn set_rx_on_when_idle(ptr: *anyopaque, enabled: bool) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return;
        try self.normal();
        var settings = self.rx_settings.current().*;
        settings.config.rx_on_when_idle = enabled;
        try self.apply_settings_change(settings, enabled);
    }

    fn set_tx_power(ptr: *anyopaque, dbm: i8) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return error.InvalidState;
        try self.normal();
        if (!valid_power(dbm)) return error.InvalidArgument;
        self.rx_settings.edit().config.tx_power = dbm;
        try self.publish_rx_settings();
    }

    fn get_tx_power(ptr: *anyopaque) i8 {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return 0;
        if (self.enabled) _ = self.resolve();
        return self.rx_settings.current().config.tx_power;
    }

    fn get_cca_threshold(ptr: *anyopaque) Error!i8 {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return error.InvalidState;
        try self.normal();
        return self.rx_settings.current().config.cca_threshold;
    }

    fn set_cca_threshold(ptr: *anyopaque, dbm: i8) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return error.InvalidState;
        try self.normal();
        if (!valid_threshold(dbm)) return error.InvalidArgument;
        self.rx_settings.edit().config.cca_threshold = dbm;
        try self.publish_rx_settings();
    }

    fn set_src_match_enabled(ptr: *anyopaque, enabled: bool) void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return;
        if (self.enabled and !self.resolve()) return;
        self.rx_settings.edit().sources.enabled = enabled;
        self.publish_rx_settings() catch return;
    }

    fn add_src_match(ptr: *anyopaque, address: Interface.Address) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return error.InvalidState;
        try self.normal();
        const sources = &self.rx_settings.edit().sources;
        try switch (address) {
            .short => |value| SourceMatch.add(&sources.short, value),
            .extended => |value| SourceMatch.add(&sources.extended, value),
        };
        try self.publish_rx_settings();
    }

    fn remove_src_match(ptr: *anyopaque, address: Interface.Address) Error!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return error.InvalidState;
        try self.normal();
        const sources = &self.rx_settings.edit().sources;
        try switch (address) {
            .short => |value| SourceMatch.remove(&sources.short, value),
            .extended => |value| SourceMatch.remove(&sources.extended, value),
        };
        try self.publish_rx_settings();
    }

    fn clear_src_match(ptr: *anyopaque, kind: Interface.AddressKind) void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const self = get(ptr);
        if (owner != self) return;
        if (self.enabled and !self.resolve()) return;
        const sources = &self.rx_settings.edit().sources;
        switch (kind) {
            .short => sources.short = @splat(null),
            .extended => sources.extended = @splat(null),
        }
        self.publish_rx_settings() catch return;
    }
};

const vtable: Interface.VTable = .{
    .capabilities = Dispatch.capabilities,
    .now_us = Dispatch.now_us,
    .state = Dispatch.state,
    .receive_sensitivity = Dispatch.receive_sensitivity,
    .enable = Dispatch.enable,
    .disable = Dispatch.disable,
    .sleep = Dispatch.sleep,
    .receive = Dispatch.receive,
    .transmit = Dispatch.transmit,
    .energy_scan = Dispatch.energy_scan,
    .cca = Dispatch.cca,
    .rssi = Dispatch.rssi,
    .poll = Dispatch.poll,
    .fault_pending = Dispatch.fault_pending,
    .set_notify = Dispatch.set_notify,
    .set_pan_id = Dispatch.set_pan_id,
    .set_short_address = Dispatch.set_short_address,
    .set_extended_address = Dispatch.set_extended_address,
    .set_pan_coordinator = Dispatch.set_pan_coordinator,
    .set_promiscuous = Dispatch.set_promiscuous,
    .get_promiscuous = Dispatch.get_promiscuous,
    .set_deliver_bad_fcs = Dispatch.set_deliver_bad_fcs,
    .set_rx_on_when_idle = Dispatch.set_rx_on_when_idle,
    .set_tx_power = Dispatch.set_tx_power,
    .get_tx_power = Dispatch.get_tx_power,
    .set_cca_threshold = Dispatch.set_cca_threshold,
    .get_cca_threshold = Dispatch.get_cca_threshold,
    .set_src_match_enabled = Dispatch.set_src_match_enabled,
    .add_src_match = Dispatch.add_src_match,
    .remove_src_match = Dispatch.remove_src_match,
    .clear_src_match = Dispatch.clear_src_match,
};

const CloseContext = struct {
    buffer_missing: bool = false,
    reserved: bool = false,
    established: bool = false,
    cutoff: ?u32 = null,
    slot_proceed: bool = false,
};

// Keep both reads here so a takeover uses the same record and never
// reclassifies a latch that arrived on the far side of this boundary.
fn commit_boundary(saved: *?Radio.Close, io: anytype, context: CloseContext) Radio.Close {
    if (saved.*) |record| return record;
    const disabled = io.disabled_latch();
    const address = context.reserved and (io.address_latch() or context.established);
    const excluded = context.slot_proceed and disabled and !context.established;
    const tick = if (address and !excluded) io.address_capture() else null;
    const record: Radio.Close = .{
        .disabled = disabled,
        .unexpected_disabled = disabled and context.buffer_missing,
        .owned = address and !excluded and (context.cutoff == null or
            (tick != null and !phy.tick_reached(tick.?, context.cutoff.?))),
        .address_tick = tick,
        .missing_capture = address and !excluded and tick == null,
    };
    saved.* = record;
    return record;
}

fn valid_channel(channel: u8) bool {
    return channel >= 11 and channel <= 26;
}

fn valid_power(dbm: i8) bool {
    return switch (dbm) {
        -40, -20, -16, -12, -8, -4, 0, 2...8 => true,
        else => false,
    };
}

fn valid_threshold(dbm: i8) bool {
    return dbm >= phy.ed_offset_dbm and dbm <= 0;
}

fn validate(config: Config) Error!void {
    if (!valid_channel(config.channel) or !valid_power(config.tx_power) or !valid_threshold(config.cca_threshold))
        return error.InvalidArgument;
    if (config.min_be > config.max_be or config.max_be < 3 or config.max_be > 8)
        return error.InvalidArgument;
}

fn set_radio_power(dbm: i8) void {
    radio.TXPOWER.write(.{ .TXPOWER = @fromBackingInt(@intCast(@as(u8, @bitCast(dbm)))) });
}

fn mask_radio(sources: @TypeOf(radio.INTENCLR).underlying_type) void {
    radio.INTENCLR.write(sources);
    _ = radio.INTENCLR.raw;
}

fn clear_phase_interrupts() void {
    radio.INTENCLR.write(.{
        .RXREADY = .Enabled,
        .READY = .Enabled,
        .PHYEND = .Enabled,
        .EDEND = .Enabled,
        .CCABUSY = .Enabled,
        .RSSIEND = .Enabled,
        .TXREADY = .Enabled,
        .ADDRESS = .Enabled,
        .CCAIDLE = .Enabled,
        .END = .Enabled,
    });
    _ = radio.INTENCLR.raw;
}

fn clear_disabled() void {
    radio.EVENTS_DISABLED.write_raw(0);
    _ = radio.EVENTS_DISABLED.raw;
}

fn power_off() void {
    radio.POWER.write_raw(0);
    _ = radio.POWER.raw;
}

fn reset_radio() void {
    power_off();
    radio.POWER.write_raw(1);
    radio.MODE.write(.{ .MODE = .Ieee802154_250Kbit });
    // PS v1.11 RADIO, IEEE 802.15.4. PHR includes FCS, EasyDMA omits it.
    radio.PCNF0.write(.{ .LFLEN = 8, .PLEN = .@"32bitZero", .CRCINC = .Include });
    radio.PCNF1.write(.{ .MAXLEN = 127, .ENDIAN = .Little, .WHITEEN = .Disabled });
    radio.SFD.write(.{ .SFD = 0xa7 });
    radio.CRCCNF.write(.{ .LEN = .Two, .SKIPADDR = .Ieee802154 });
    radio.CRCPOLY.write(.{ .CRCPOLY = 0x11021 });
    radio.CRCINIT.write(.{ .CRCINIT = 0 });
    radio.MODECNF0.write(.{ .RU = .Fast, .DTX = .Center });
}

fn ed_sample_count(duration: u32) ?u32 {
    if (duration > max_ed_samples * ed_sample_us) return null;
    return @max(1, (duration + ed_sample_us - 1) / ed_sample_us);
}

fn channel_frequency(channel: u8) u7 {
    return @intCast(5 + (channel - 11) * 5);
}

fn capture_in_arm(prime: u32, capture: u32, now: u32) bool {
    return capture != prime -% 1 and capture -% prime <= now -% prime;
}

fn connect_capture(channel: ppi.Channel, event: *volatile anyopaque, cc: u3) void {
    channel.connect(event, &timer.TASKS_CAPTURE[cc], null) catch unreachable;
    channel.enable();
}

fn wait_event(event: anytype) bool {
    for (0..transition_checks) |_| {
        if (@as(u32, @bitCast(event.read())) != 0) return true;
    }
    return false;
}

fn wait_disabled() bool {
    for (0..transition_checks) |_| {
        if (radio.STATE.read().STATE == .Disabled and radio.EVENTS_DISABLED.raw != 0) return true;
    }
    return false;
}

fn rtc_elapsed(start: u24, budget_us: u32) bool {
    const elapsed = rtc.COUNTER.read().COUNTER -% start;
    return @as(u64, elapsed) * 1_000_000 >= @as(u64, budget_us) * 32_768;
}

// TEMP and RNG have no STOP-complete event (PS v1.11 §§6.21, 6.28).
// Allow in-flight register visibility, then look for a reassertion.
fn clear_stopped_event(event: anytype) bool {
    for (0..producer_checks) |_| asm volatile ("nop");
    event.write_raw(0);
    _ = event.raw;
    for (0..producer_checks) |_| {
        if (event.raw != 0) return false;
    }
    return true;
}

fn retire_timer() bool {
    // PS v1.11 §6.30 and nRF52840 TIMER anomaly 78.
    timer.INTENCLR.write_raw(0xffff_ffff);
    timer.TASKS_STOP.write_raw(1);
    timer.TASKS_SHUTDOWN.write_raw(1);
    timer3.clear();
    inline for (0..6) |i| timer3.clear_compare(@intCast(i));
    return timer_is_stopped();
}

fn timer_is_stopped() bool {
    for (0..producer_checks) |_| {
        if (Radio.counter_now() != 0) return false;
    }
    return true;
}

fn retire_rng() bool {
    // PS v1.11 §6.21, STOP and VALRDY.
    rng.INTENCLR.write_raw(0xffff_ffff);
    rng.SHORTS.write_raw(0);
    rng.TASKS_STOP.write_raw(1);
    return clear_stopped_event(&rng.EVENTS_VALRDY) and rng.INTENSET.raw == 0;
}

fn radio_configuration_valid() bool {
    return radio.POWER.raw != 0 and radio.STATE.read().STATE == .Disabled and
        radio.MODE.read().MODE == .Ieee802154_250Kbit and radio.SFD.read().SFD == 0xa7 and
        radio.PCNF0.read().LFLEN == 8 and radio.PCNF0.read().PLEN == .@"32bitZero" and
        radio.PCNF0.read().CRCINC == .Include and radio.PCNF1.read().MAXLEN == 127 and
        radio.PCNF1.read().ENDIAN == .Little and radio.PCNF1.read().WHITEEN == .Disabled and
        radio.CRCCNF.read().LEN == .Two and radio.CRCCNF.read().SKIPADDR == .Ieee802154 and
        radio.CRCPOLY.read().CRCPOLY == 0x11021 and radio.CRCINIT.read().CRCINIT == 0 and
        radio.MODECNF0.read().RU == .Fast and radio.MODECNF0.read().DTX == .Center;
}

fn csma_seed() u64 {
    rng.CONFIG.write(.{ .DERCEN = .Enabled });
    rng.EVENTS_VALRDY.write_raw(0);
    rng.TASKS_START.write_raw(1);
    var seed: [8]u8 = undefined;
    for (&seed) |*byte| {
        const started = rtc.COUNTER.read().COUNTER;
        for (0..startup_checks) |_| {
            if (rng.EVENTS_VALRDY.raw != 0 or rtc_elapsed(started, seed_byte_timeout_us)) break;
        }
        if (rng.EVENTS_VALRDY.raw == 0) {
            // PS v1.11 FICR, DEVICEID.
            const id = &peripherals.FICR.DEVICEID;
            const device_id = (@as(u64, id[1].read().DEVICEID) << 32) | id[0].read().DEVICEID;
            return device_id ^ rtc.COUNTER.read().COUNTER;
        }
        byte.* = rng.VALUE.read().VALUE;
        rng.EVENTS_VALRDY.write_raw(0);
        _ = rng.EVENTS_VALRDY.raw;
    }
    return std.mem.readInt(u64, &seed, .little);
}

fn start_temperature_sample() void {
    temp.EVENTS_DATARDY.write_raw(0);
    temp.TASKS_START.write_raw(1);
}

fn temperature_adjustment(q: i32) i8 {
    // RADIO anomaly 153, nrfx/mdk. Correct positive RSSISAMPLE magnitude
    // before negating, as in Nordic's nrf_802154_trx.c.
    if (q <= -120) return 3;
    if (q <= -40) return 2;
    if (q <= 40) return 1;
    if (q <= 120) return 0;
    if (q <= 200) return -1;
    if (q <= 280) return -2;
    return -3;
}

fn read_rssi_dbm(adjustment: i8) i8 {
    const magnitude = @as(i16, radio.RSSISAMPLE.read().RSSISAMPLE) + adjustment;
    return @intCast(-std.math.clamp(magnitude, 0, 128));
}

fn correct_level(raw: u8, adjustment: i8) u8 {
    return @intCast(std.math.clamp(@as(i16, raw) - adjustment, 0, 255));
}

fn level_dbm(raw: u8) i8 {
    // RADIO anomaly 236: scale by 4 for ED/LQI units only, never for dBm.
    return @intCast(@min(@as(i16, raw) + phy.ed_offset_dbm, 127));
}

test "TX reserves start and completion slots until they are queued" {
    var reservation: EventReservation = .{};
    try std.testing.expectError(error.Busy, reservation.reserve(.tx, 15, 0));
    try reservation.reserve(.tx, 14, 0);
    try std.testing.expect(!reservation.has_rx_space(14));
    reservation.queue_start(); // 15 events are now queued.
    try std.testing.expect(!reservation.has_rx_space(15));
    reservation.queue_terminal(); // Terminal events keep blocking submission until polled.
    try std.testing.expectError(error.Busy, reservation.reserve(.tx, 0, 0));
    reservation.poll_terminal();
    try reservation.reserve(.tx, 14, 0);
}

test "completion without TX start releases the spare slot and single-event operations need one slot" {
    var reservation: EventReservation = .{};
    try reservation.reserve(.tx, 14, 0);
    reservation.queue_terminal();
    try std.testing.expect(reservation.has_rx_space(15));
    reservation.poll_terminal();
    try std.testing.expectError(error.Busy, reservation.reserve(.ed, 16, 0));
    try reservation.reserve(.ed, 15, 0);
    try std.testing.expect(!reservation.has_rx_space(15));
    reservation.queue_terminal();
    reservation.poll_terminal();
    try reservation.reserve(.cca, 15, 0);
}

test "TX reserves every offloaded retry plus its terminal event" {
    var reservation: EventReservation = .{};
    const attempts = max_frame_retries + 1;
    const queued = event_capacity - attempts - 1;
    try std.testing.expectError(error.Busy, reservation.reserve(.tx, queued + 1, max_frame_retries));
    try reservation.reserve(.tx, queued, max_frame_retries);
    for (0..attempts) |i| {
        try std.testing.expect(!reservation.has_rx_space(queued + i));
        reservation.queue_start();
    }
    reservation.queue_terminal();
    try std.testing.expectError(error.Busy, reservation.reserve(.tx, 0, 0));
    reservation.poll_terminal();
    try reservation.reserve(.tx, queued, max_frame_retries);
}

test "TX start reconciliation distinguishes ramp-up, on-air evidence and prior reporting" {
    var attempt: TxAttempt = .{};
    try std.testing.expectEqual(null, attempt.marker(.{}));
    attempt.launched = true;
    try std.testing.expectEqual(null, attempt.marker(.{}));
    try std.testing.expectEqual(.address, attempt.marker(.{ .address = true }).?);
    try std.testing.expectEqual(.phy_end, attempt.marker(.{ .phy_end = true }).?);
    attempt.reported = true;
    try std.testing.expectEqual(null, attempt.marker(.{ .address = true, .phy_end = true }));
}

test "sleepy Data Request waits on the TX channel only for a matching pending ACK" {
    const ack_end = std.math.maxInt(u32) - 23;
    const response = PollResponse.after_ack(25, ack_end, false, true, 0x12).?;
    try std.testing.expectEqual(@as(u8, 25), response.channel);
    try std.testing.expectEqual(@as(u32, ack_end) +% 100_000, response.end_deadline);
    try std.testing.expect(response.includes_address(response.end_deadline -% 1));
    try std.testing.expect(!response.includes_address(response.end_deadline));
    try std.testing.expectEqual(null, PollResponse.after_ack(25, ack_end, true, true, 0x12));
    try std.testing.expectEqual(null, PollResponse.after_ack(25, ack_end, false, false, 0x12));
    try std.testing.expectEqual(null, PollResponse.after_ack(25, ack_end, false, true, 0x02));
}

test "first CCA skips random backoff for zero on every attempt" {
    try std.testing.expectEqual(Phase.tx, Phase.first_tx_phase(false, 4));
    try std.testing.expectEqual(Phase.tx_cca, Phase.first_tx_phase(true, 0));
    try std.testing.expectEqual(Phase.backoff, Phase.first_tx_phase(true, 1));
}

test "one-shot receive consumes only the delivered request identity" {
    var self: Radio = .{ .rx_settings = undefined, .rx_channel = 11, .adjustment = 0, .random = .init(0) };
    self.record_receive();
    const old = self.rx_request;
    self.record_receive();
    self.consume_receive(true, old, false);
    const renewed = self.rx_request;
    try std.testing.expect(renewed != old and renewed != null);
    self.consume_receive(false, renewed, false);
    try std.testing.expectEqual(renewed, self.rx_request);
    self.consume_receive(true, renewed, true);
    try std.testing.expectEqual(renewed, self.rx_request);
    self.consume_receive(true, renewed, false);
    try std.testing.expectEqual(@as(?u64, null), self.rx_request);
}

test "sticky fault preserves the first reason and saturates outside the FIFO" {
    var self: Radio = .{ .rx_settings = undefined, .rx_channel = 11, .adjustment = 0, .random = .init(0) };
    self.record_fault(.missing_capture);
    self.fault.?.count = std.math.maxInt(u32) - 1;
    self.record_fault(.radio_timeout);
    self.record_fault(.clock_stalled);
    try std.testing.expect(self.backlog());
    try std.testing.expectEqual(@as(usize, 0), self.queued);
    try std.testing.expectEqual(Interface.Fault{
        .reason = .missing_capture,
        .count = std.math.maxInt(u32),
    }, self.take_event().?.fault);
    try std.testing.expect(!self.backlog());
}

test "capture freshness rejects a sentinel across TIMER3 rollover" {
    const prime = 0xffff_fffa;
    try std.testing.expect(!capture_in_arm(prime, prime - 1, 10));
    try std.testing.expect(capture_in_arm(prime, 3, 10));
    try std.testing.expect(!capture_in_arm(prime, 11, 10));
}

test "channel admission enforces 11 through 26 and maps the RF frequency" {
    try std.testing.expect(!valid_channel(10));
    try std.testing.expect(!valid_channel(27));
    for (11..27) |channel| {
        try std.testing.expect(valid_channel(@intCast(channel)));
        try std.testing.expectEqual(5 + (channel - 11) * 5, channel_frequency(@intCast(channel)));
    }
}

test "captured END selects one complete settings generation across cutovers and wrap" {
    var versions: RxSettingsVersions = .init(.{
        .config = .{ .pan_id = 0x1234, .short_address = 3 },
        .sources = .{ .enabled = true },
    });
    const prime = 0xffff_fff0;
    versions.reset_arm(prime);
    try SourceMatch.add(&versions.entries[0].settings.sources.short, @as(u16, 1));
    const bytes = [_]u8{ 0x63, 0x88, 9, 0x34, 0x12, 3, 0, 1, 0, 0x04 };
    const next = versions.edit();
    try SourceMatch.remove(&next.sources.short, @as(u16, 1));
    next.config.tx_power = -4;
    versions.publish(0);
    const older = versions.at_end(0xffff_ffff, prime).classify(&bytes, true, true).ack;
    try std.testing.expect(older.pending);
    try std.testing.expectEqual(@as(i8, 0), older.power);
    const updated = versions.at_end(0, prime).classify(&bytes, true, true).ack;
    try std.testing.expect(!updated.pending);
    try std.testing.expectEqual(@as(i8, -4), updated.power);

    versions.edit().config.tx_power = -8;
    versions.publish(0);
    try std.testing.expectEqual(@as(i8, 0), versions.at_end(0xffff_ffff, prime).config.tx_power);
    try std.testing.expectEqual(@as(i8, -8), versions.at_end(0, prime).config.tx_power);
    versions.edit().config.short_address = 4;
    versions.publish(1);
    versions.edit().config.promiscuous = true;
    versions.publish(2);
    const pinned = versions.at_end(0, prime).classify(&bytes, true, true).ack;
    try std.testing.expectEqual(@as(u8, 9), pinned.sequence);
    try std.testing.expect(!pinned.pending);
    try std.testing.expectEqual(@as(i8, -8), pinned.power);
    try std.testing.expect(versions.current().classify(&bytes, true, true) == .accept);
}

const CloseFixture = struct {
    disabled: bool = false,
    disabled_after_read: bool = false,
    address: ?u32 = null,
    disabled_reads: usize = 0,
    address_reads: usize = 0,

    fn disabled_latch(self: *CloseFixture) bool {
        self.disabled_reads += 1;
        defer if (self.disabled_after_read) {
            self.disabled = true;
        };
        return self.disabled;
    }

    fn address_latch(self: *CloseFixture) bool {
        self.address_reads += 1;
        return self.address != null;
    }

    fn address_capture(self: *CloseFixture) ?u32 {
        return self.address;
    }
};

test "Deinit or sender ACK expiry consumes one committed close boundary" {
    var io: CloseFixture = .{ .disabled_after_read = true, .address = 100 };
    var saved: ?Radio.Close = null;
    const first = commit_boundary(&saved, &io, .{ .reserved = true, .cutoff = 100 });
    try std.testing.expect(!first.disabled and !first.owned);
    io.address = 99;
    const takeover = commit_boundary(&saved, &io, .{ .reserved = true, .cutoff = 100 });
    try std.testing.expectEqual(first, takeover);
    try std.testing.expectEqual(@as(usize, 1), io.disabled_reads);
    try std.testing.expectEqual(@as(usize, 1), io.address_reads);
}

test "buffer-missing DISABLED before commitment faults, later DISABLED belongs to the close" {
    var io: CloseFixture = .{ .disabled = true };
    var saved: ?Radio.Close = null;
    try std.testing.expect(commit_boundary(&saved, &io, .{ .buffer_missing = true }).unexpected_disabled);
    saved = null;
    io = .{ .disabled_after_read = true };
    const close = commit_boundary(&saved, &io, .{ .buffer_missing = true });
    try std.testing.expect(io.disabled and !close.disabled and !close.unexpected_disabled and !close.owned);
}

test "late backoff END does not take ownership from a slot close" {
    var io: CloseFixture = .{ .disabled = true, .address = 99 };
    var saved: ?Radio.Close = null;
    try std.testing.expect(!commit_boundary(&saved, &io, .{ .reserved = true, .slot_proceed = true }).owned);
    saved = null;
    const established = commit_boundary(&saved, &io, .{ .reserved = true, .established = true, .slot_proceed = true });
    try std.testing.expect(established.owned);
}

test "admission uses the timer sample before the hardware reads that straddle expiry" {
    const response: PollResponse = .{ .channel = 25, .end_deadline = 0 };
    const tick_before_reads: u32 = std.math.maxInt(u32);
    try std.testing.expect(!response.due(tick_before_reads));
    var io: CloseFixture = .{ .disabled_after_read = true, .address = 0 };
    var saved: ?Radio.Close = null;
    const close = commit_boundary(&saved, &io, .{ .reserved = true, .cutoff = response.end_deadline });
    try std.testing.expect(io.disabled and !close.owned);
    try std.testing.expect(response.due(0));
    try std.testing.expect(response.due(1));
}

test "post-expiry CCA uses the resolved channel at the final admission sample" {
    const response: PollResponse = .{ .channel = 25, .end_deadline = 200 };
    for ([_]?u8{ null, 25 }) |renewal| {
        var self: Radio = .{ .rx_settings = undefined, .rx_channel = 11, .adjustment = 0, .random = .init(0) };
        self.poll_response = response;
        self.deferred_channel = renewal;
        try std.testing.expect(!response.due(199));
        try std.testing.expectEqual(@as(u8, 25), self.listen_channel());
        try std.testing.expect(response.due(200));
        self.promote_response();
        try std.testing.expectEqual(renewal orelse 11, self.listen_channel());
        self.consume_receive(true, self.rx_request, false);
        try std.testing.expectEqual(renewal orelse 11, self.listen_channel());
    }
}

test "failed Enable startup diagnostic can publish while disabled" {
    var self: Radio = .{ .rx_settings = undefined, .rx_channel = 11, .adjustment = 0, .random = .init(0) };
    self.record_fault(.radio_reset);
    self.record_fault(.timer_retirement);
    try std.testing.expect(!self.enabled and self.backlog());
    try std.testing.expectEqual(@as(usize, 0), self.queued);
    try std.testing.expectEqual(Interface.Fault{ .reason = .radio_reset, .count = 2 }, self.take_event().?.fault);
    try std.testing.expect(self.take_event() == null);
}

test "PHR and DMA lengths respect FCS storage and TX limits" {
    try std.testing.expectEqual(@as(?u8, null), Radio.psdu_payload_len(1));
    try std.testing.expectEqual(@as(?u8, 0), Radio.psdu_payload_len(2));
    try std.testing.expectEqual(@as(?u8, 125), Radio.psdu_payload_len(127));
    try std.testing.expectEqual(@as(?u8, null), Radio.psdu_payload_len(128));
    try std.testing.expectEqual(null, try header.tx_ack_header(&@as([125]u8, @splat(0))));
    try std.testing.expectError(error.InvalidFrame, header.tx_ack_header(&@as([126]u8, @splat(0))));
}

test "ED maximum compare fits and the next duration is rejected" {
    const largest = max_ed_samples * ed_sample_us;
    try std.testing.expectEqual(@as(?u32, 1), ed_sample_count(0));
    try std.testing.expectEqual(@as(?u32, 2), ed_sample_count(129));
    try std.testing.expectEqual(@as(?u32, max_ed_samples), ed_sample_count(largest));
    try std.testing.expectEqual(@as(?u32, null), ed_sample_count(largest + 1));
}

test "FCS and promiscuous policy determine RX delivery and ACK suppression" {
    const bytes = [_]u8{ 0x61, 0x88, 9, 0x34, 0x12, 3, 0, 1, 0 };
    var settings: RxSettings = .{ .config = .{ .pan_id = 0x1234, .short_address = 3 } };
    try std.testing.expect(settings.classify(&bytes, true, true) == .ack);
    try std.testing.expect(settings.classify(&bytes, false, true) == .reject);
    settings.deliver_bad_fcs = true;
    try std.testing.expect(settings.classify(&bytes, false, true) == .accept);
    settings.config.promiscuous = true;
    try std.testing.expect(settings.classify(&bytes, true, true) == .accept);
}

test "unsolicited ACK is filtered outside TX ACK wait except in promiscuous mode" {
    const ack = [_]u8{ 0x12, 0, 9 };
    const newer_frame = [_]u8{ 0x05, 0x20, 9 };
    var settings: RxSettings = .{ .config = .{} };
    try std.testing.expect(settings.classify(&ack, true, true) == .reject);
    try std.testing.expect(settings.classify(&newer_frame, true, true) == .reject);
    settings.config.promiscuous = true;
    try std.testing.expect(settings.classify(&ack, true, true) == .accept);
    try std.testing.expect(settings.classify(&newer_frame, true, true) == .accept);
}

test "busy hardware and software slots share the post-increment exhaustion and BE cap" {
    var tx: Tx = undefined;
    tx.max_backoffs = 5;
    tx.backoffs = 0;
    tx.be = 3;
    for (1..6) |charged| {
        try std.testing.expect(tx.charge_busy(5));
        try std.testing.expectEqual(charged, tx.backoffs);
        try std.testing.expectEqual(@as(u4, if (charged == 1) 4 else 5), tx.be);
    }
    try std.testing.expect(!tx.charge_busy(5));
    try std.testing.expectEqual(@as(u8, 6), tx.backoffs);
    try std.testing.expectEqual(@as(u4, 5), tx.be);
    tx.max_backoffs = 0;
    tx.backoffs = 0;
    try std.testing.expect(!tx.charge_busy(5));
}

test "max ACK retries terminate and no-AR TX bypasses ACK retry" {
    var tx: Tx = undefined;
    tx.sequence = 9;
    tx.retries_left = max_frame_retries;
    for (0..max_frame_retries) |_| try std.testing.expect(tx.retry());
    try std.testing.expect(!tx.retry());
    tx.sequence = null;
    tx.retries_left = max_frame_retries;
    try std.testing.expect(!tx.retry());
}

test "abandoning immediate ACK clears both metadata bits while preserving the frame" {
    const frame: Frame = .{
        .data = undefined,
        .len = 0,
        .metadata = .{
            .bytes = &.{},
            .fcs = .{ 0, 0 },
            .channel = 25,
            .rssi = -50,
            .lqi = 100,
            .timestamp_us = 42,
            .acked_with_frame_pending = true,
        },
    };
    const sent = frame.with_ack_result(true);
    try std.testing.expect(sent.metadata.ack_sent and sent.metadata.acked_with_frame_pending);
    const abandoned = frame.with_ack_result(false);
    try std.testing.expect(!abandoned.metadata.ack_sent and !abandoned.metadata.acked_with_frame_pending);
    try std.testing.expectEqual(@as(?u64, 42), abandoned.metadata.timestamp_us);
}

test "sticky fault precedes saved teardown results and preserves old visible timestamps" {
    var self: Radio = .{ .rx_settings = undefined, .rx_channel = 11, .adjustment = 0, .random = .init(0) };
    self.queue[0] = .{ .tx_started = .{ .timestamp_us = 123, .attempt = 1 } };
    self.queue[1] = .{ .tx_done = .{ .timestamp = 123, .status = .aborted, .ack = null } };
    self.queued = 2;
    self.reservation.remaining = 0;
    self.clear_result_times(1);
    self.record_fault(.timer_retirement);
    try std.testing.expectEqual(.timer_retirement, self.take_event().?.fault.reason);
    try std.testing.expectEqual(@as(?u64, 123), self.take_event().?.tx_started.timestamp_us);
    try std.testing.expectEqual(@as(?u64, null), self.take_event().?.tx_done.timestamp_us);
    try std.testing.expect(self.reservation.remaining == null and !self.backlog());
}

test {
    _ = @import("ieee802154_header.zig");
    _ = @import("ieee802154_phy.zig");
    _ = @import("ieee802154_src_match.zig");
}

fn expect_overrun(iface: Interface) !void {
    try std.testing.expectEqual(Interface.RxError.overrun, iface.poll().?.rx_error);
}

fn init_test_radio(self: *Radio) !Interface {
    microzig.Fixture.reset();
    try self.init(.{ .channel = 25, .rx_on_when_idle = false, .pan_id = 0x1234, .short_address = 3 });
    const iface = self.ieee802154_radio();
    try iface.enable();
    return iface;
}

fn start_test_tx(iface: Interface) !void {
    try iface.transmit(&.{
        .bytes = &.{ 0x41, 0x88, 1, 0x34, 0x12, 0xff, 0xff, 3, 0 },
        .channel = 25,
        .csma_ca = false,
    });
    microzig.Fixture.raise(&radio.EVENTS_TXREADY);
    try std.testing.expect(service_test_radio());
    try std.testing.expectEqual(@as(usize, 1), microzig.fx.start);
}

test "explicit stop aborts unprocessed RX END once" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    microzig.Fixture.raise(&radio.EVENTS_END);

    try iface.disable();
    try std.testing.expectEqual(Interface.State.disabled, iface.state());
    try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    _ = service_test_radio();
    _ = service_test_timer();
    try std.testing.expect(iface.poll() == null);
    try self.deinit();
}

test "an explicit stop publishes a latched TX start before the abort even with PHYEND and DISABLED present" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try start_test_tx(iface);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    microzig.Fixture.raise(&radio.EVENTS_PHYEND);

    try iface.sleep();
    try std.testing.expectEqual(Interface.State.sleep, iface.state());
    try std.testing.expect(iface.poll().?.tx_started.timestamp_us != null);
    try std.testing.expectEqual(Interface.TxStatus.aborted, iface.poll().?.tx_done.status);
    try std.testing.expect(iface.poll() == null);
}

test "a capture failure in Disable emits one untimed proven start and terminal" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try start_test_tx(iface);
    microzig.fx.ack_capture_stalls = true;
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    microzig.fx.ack_capture_stalls = false;
    microzig.Fixture.raise(&radio.EVENTS_PHYEND);

    try std.testing.expectError(error.HardwareFault, iface.disable());
    try std.testing.expectEqual(Interface.State.disabled, iface.state());
    try std.testing.expectEqual(Interface.Fault{ .reason = .missing_capture }, iface.poll().?.fault);
    try std.testing.expectEqual(@as(?u64, null), iface.poll().?.tx_started.timestamp_us);
    const terminal = iface.poll().?.tx_done;
    try std.testing.expectEqual(Interface.TxStatus.aborted, terminal.status);
    try std.testing.expectEqual(@as(?u64, null), terminal.timestamp_us);
    try std.testing.expect(iface.poll() == null);
}

test "unverified TIMER3 retirement isolates producers, leaves terminals and quarantines routing" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.energy_scan(25, 128);
    microzig.fx.timer_retirement_stalls = true;
    try std.testing.expectError(error.HardwareFault, iface.disable());
    try std.testing.expectEqual(Interface.State.disabled, iface.state());
    try std.testing.expect(!microzig.fx.enabled[@backingInt(microzig.cpu.Interrupt.RADIO)]);
    try std.testing.expect(!microzig.fx.enabled[@backingInt(microzig.cpu.Interrupt.TIMER3)]);
    const stops = microzig.fx.timer_stops;
    try iface.disable();
    try std.testing.expectEqual(stops, microzig.fx.timer_stops);
    try std.testing.expectError(error.HardwareFault, iface.enable());
    try std.testing.expectError(error.Busy, self.deinit());
    try std.testing.expectEqual(Interface.Fault{ .reason = .timer_retirement }, iface.poll().?.fault);
    try std.testing.expectEqual(error.Aborted, iface.poll().?.energy_scan_failed);
    try std.testing.expect(iface.poll() == null);
    try std.testing.expectError(error.HardwareFault, self.deinit());
    var other: Radio = undefined;
    try std.testing.expectError(error.Busy, other.init(.{}));
    try std.testing.expectEqual(stops, microzig.fx.timer_stops);
}

test "failed TIMER3 startup publishes a diagnostic while leaving FIFO publication sealed" {
    microzig.Fixture.reset();
    var self: Radio = undefined;
    defer owner = null;
    try self.init(.{});
    const iface = self.ieee802154_radio();
    microzig.fx.timer_step = 0;
    try std.testing.expectError(error.HardwareFault, iface.enable());
    try std.testing.expectEqual(Interface.State.disabled, iface.state());
    try std.testing.expectEqual(@as(usize, 0), self.queued_event_count());
    try std.testing.expectEqual(Interface.FaultPending{
        .pending = true,
        .reason = .clock_stalled,
        .count = 1,
    }, iface.fault_pending());
    microzig.fx.timer_step = 1;
    try iface.enable();
    try iface.sleep();
    try std.testing.expectEqual(Interface.Fault{ .reason = .clock_stalled }, iface.poll().?.fault);
    try std.testing.expect(iface.poll() == null);
}

test "CCA samples its channel after the final cutoff decision under the mask" {
    for ([_]?u8{ null, 25 }) |renewal| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        self.rx_channel = 11;
        self.record_receive();
        self.poll_response = .{ .channel = 25, .end_deadline = 1000 };
        self.deferred_channel = renewal;
        self.begin_disabled(.rx);
        microzig.Fixture.dispatch_ready_rx();
        microzig.fx.timer_step = 0;
        microzig.Fixture.advance(999);
        microzig.fx.jump_on_capture = microzig.fx.capture_count + 4;
        microzig.fx.jump_tick = 1000;
        try iface.cca();
        try std.testing.expect(self.poll_response == null and self.deferred_channel == null);
        try std.testing.expectEqual(renewal orelse 11, self.measurement_channel);
        try std.testing.expectEqual(channel_frequency(renewal orelse 11), radio.FREQUENCY.read().FREQUENCY);
        try std.testing.expectEqual(Interface.State.receive, iface.state());
    }
}

const delayed_ed_sample = 151;
const replacement_ed_sample = 19;

test "ED preserves a captured start origin and result across IRQ service order" {
    for ([_]bool{ false, true }) |timer_first| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try iface.energy_scan(25, 128);
        microzig.fx.timer_step = 0;
        microzig.Fixture.advance(100);
        microzig.Fixture.dispatch_ready_rx();
        microzig.Fixture.advance(200);
        if (timer_first) microzig.cpu.interrupt.set_pending(.TIMER3);
        try std.testing.expect(if (timer_first) service_test_timer() else service_test_radio());
        try std.testing.expectEqual(@as(?u32, 228), self.deadline);
        try expect_radio_drained();
        microzig.fx.defer_shortcut_disabled = true;
        radio.EDSAMPLE.write(.{ .EDLVL = delayed_ed_sample });
        const expected = level_dbm(correct_level(delayed_ed_sample, self.adjustment));
        microzig.Fixture.raise(&radio.EVENTS_EDEND);
        microzig.fx.on_radio_state_read = complete_masked_ed;
        try std.testing.expect(service_test_radio());
        try std.testing.expect(microzig.fx.on_radio_state_read == null);
        try std.testing.expectEqual(@as(u8, replacement_ed_sample), radio.EDSAMPLE.read().EDLVL);
        try std.testing.expectEqual(expected, iface.poll().?.energy_scan_done);
        try expect_radio_drained();
        try std.testing.expect(iface.poll() == null);
    }
}

fn complete_masked_ed() void {
    std.debug.assert(radio.INTENSET.read().EDEND != .Enabled);
    std.debug.assert(radio.EVENTS_EDEND.raw != 0 and ack_launch.enabled());
    radio.EDSAMPLE.write(.{ .EDLVL = replacement_ed_sample });
    microzig.Fixture.complete_shortcut();
}

fn inject_sampled_frame() void {
    std.debug.assert(microzig.fx.mask_depth != 0);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    microzig.Fixture.raise(&radio.EVENTS_END);
}

test "FIFO depth ignores a frame latched after taking its interrupt mask" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    const bytes = [_]u8{ 0x41, 0x88, 1, 0x34, 0x12, 3, 0, 1, 0 };
    self.packet[0] = bytes.len + Interface.fcs_len;
    self.packet[1..][0..bytes.len].* = bytes;
    self.packet[1 + bytes.len] = 80;
    radio.CRCSTATUS.write(.{ .CRCSTATUS = .CRCOk });
    microzig.fx.on_mask = inject_sampled_frame;
    try std.testing.expectEqual(@as(usize, 0), self.queued_event_count());
    try std.testing.expect(service_test_radio());
    try std.testing.expectEqual(@as(usize, 1), self.queued_event_count());
    try std.testing.expectEqualSlices(u8, &bytes, iface.poll().?.rx.bytes);
    try std.testing.expect(iface.poll() == null);
}

fn test_frame(self: *Radio, bytes: []const u8) void {
    self.packet[0] = @intCast(bytes.len + Interface.fcs_len);
    @memcpy(self.packet[1..][0..bytes.len], bytes);
    self.packet[1 + bytes.len] = 80;
    radio.CRCSTATUS.write(.{ .CRCSTATUS = .CRCOk });
    radio.RSSISAMPLE.write(.{ .RSSISAMPLE = 50 });
}

const test_unicast = [_]u8{ 0x41, 0x88, 1, 0x34, 0x12, 3, 0, 1, 0 };
const test_ack_request = [_]u8{ 0x61, 0x88, 1, 0x34, 0x12, 3, 0, 1, 0 };

test "ordinary ADDRESS owns an RX abort even when its capture is missing" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    microzig.fx.ack_capture_stalls = true;
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    try std.testing.expect(service_test_radio());
    try std.testing.expectEqual(Interface.State.disabled, iface.state());
    try std.testing.expectEqual(Interface.Fault{ .reason = .missing_capture }, iface.poll().?.fault);
    try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    try std.testing.expect(iface.poll() == null);
    try self.deinit();
}

test "response ownership is strictly before cutoff under either IRQ ordering" {
    for ([_]bool{ false, true }) |timer_first| {
        for ([_]bool{ false, true }) |early| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            self.rx_channel = 11;
            self.poll_response = .{ .channel = 25, .end_deadline = 1000 };
            self.begin_disabled(.rx);
            try iface.receive(25);
            microzig.Fixture.dispatch_ready_rx();
            test_frame(&self, &test_unicast);
            microzig.fx.timer_step = 0;
            microzig.Fixture.advance(if (early) 999 else 1000);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            microzig.Fixture.advance(1400);
            microzig.Fixture.raise(&radio.EVENTS_END);

            try std.testing.expect(if (timer_first) service_test_timer() else service_test_radio());
            if (early) {
                const frame = iface.poll().?.rx;
                try std.testing.expectEqual(@as(u8, 25), frame.channel);
                try std.testing.expectEqualSlices(u8, &test_unicast, frame.bytes);
            }
            try std.testing.expect(iface.poll() == null);
            try std.testing.expectEqual(@as(u8, 25), self.rx_channel);
            try std.testing.expect(self.rx_request != null);
            try std.testing.expect(self.poll_response == null);
        }
    }
}

test "sender ACK cutoff takes one quiet or owned close through either IRQ" {
    for ([_]bool{ false, true }) |timer_first| {
        for ([_]bool{ false, true }) |owned| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            try iface.transmit(&.{
                .bytes = &test_ack_request,
                .channel = 25,
                .csma_ca = false,
                .max_frame_retries = 0,
            });
            microzig.Fixture.raise(&radio.EVENTS_TXREADY);
            try std.testing.expect(service_test_radio());
            microzig.fx.timer_step = 0;
            microzig.Fixture.advance(500);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            microzig.Fixture.advance(1000);
            microzig.Fixture.raise(&radio.EVENTS_PHYEND);

            try std.testing.expect(service_test_radio());
            try std.testing.expectEqual(Phase.ack_rx, self.phase);
            try std.testing.expect(iface.poll().? == .tx_started);
            microzig.Fixture.dispatch_ready_rx();
            const cutoff = self.deadline.?;
            if (owned) {
                microzig.Fixture.advance(cutoff - 1);
                microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            }
            microzig.Fixture.advance(cutoff);
            if (!timer_first and !owned) microzig.cpu.interrupt.set_pending(.RADIO);
            try std.testing.expect(if (timer_first) service_test_timer() else service_test_radio());
            if (owned) {
                try std.testing.expect(iface.poll() == null);
                try std.testing.expect(self.close.?.owned);
                test_frame(&self, &.{ 0x02, 0, 1 });
                microzig.Fixture.advance(cutoff + 32);
                microzig.Fixture.raise(&radio.EVENTS_END);

                try std.testing.expect(service_test_radio());
            }
            try std.testing.expectEqual(Interface.TxStatus.no_ack, iface.poll().?.tx_done.status);
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "quiet full FIFO withholds START and restoration retains a live response cutoff" {
    for ([_]bool{ false, true }) |response| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        for (0..event_capacity) |_| self.enqueue(.{ .rx_error = .aborted });
        if (response) self.poll_response = .{ .channel = 25, .end_deadline = 1000 };
        try iface.receive(25);
        if (response) self.begin_disabled(.rx);
        try std.testing.expect(!self.rx_reserved);
        try std.testing.expectEqual(@as(u32, 1), self.overrun);
        try std.testing.expectEqual(@as(u32, 0), radio.PACKETPTR.raw);
        try std.testing.expect(radio.SHORTS.read().RXREADY_START != .Enabled);
        microzig.Fixture.dispatch_ready_rx();
        try std.testing.expectEqual(.RxIdle, radio.STATE.read().STATE);
        try std.testing.expectEqual(@as(usize, 0), microzig.fx.start);
        try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
        microzig.Fixture.dispatch_ready_rx();
        try std.testing.expectEqual(@as(usize, 1), microzig.fx.start);
        try expect_radio_drained();
        try std.testing.expect(self.rx_reserved);
        try std.testing.expectEqual(@as(usize, event_capacity - 1), self.queued_event_count());
        if (response) {
            try std.testing.expectEqual(@as(?u32, 1000), self.deadline);
            try std.testing.expectEqual(channel_frequency(25), radio.FREQUENCY.read().FREQUENCY);
        }
    }
}

fn receive_test_frame(self: *Radio) !void {
    test_frame(self, &test_unicast);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    try std.testing.expect(service_test_radio());
    microzig.Fixture.advance(microzig.fx.tick + 400);
    microzig.Fixture.raise(&radio.EVENTS_END);
    try std.testing.expect(service_test_radio());
    // The pended dispatch sets up the next arm.
    if (self.rx_replacement != null) try std.testing.expect(service_test_radio());
}

test "an ordered overrun marker precedes later FIFO results" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    for (0..event_capacity) |_| self.enqueue(.{ .rx_error = .aborted });
    try iface.receive(25);
    try std.testing.expect(!self.rx_reserved);
    try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    microzig.Fixture.dispatch_ready_rx();
    try std.testing.expect(self.rx_reserved);
    try receive_test_frame(&self);
    for (1..event_capacity) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    try expect_overrun(iface);
    try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
    try std.testing.expect(iface.poll() == null);
}

test "a buffer-missing arm reports overrun once per episode" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    for (0..event_capacity) |_| self.enqueue(.{ .rx_error = .aborted });
    try iface.set_rx_on_when_idle(true);
    try std.testing.expect(!self.rx_reserved);
    try std.testing.expectEqual(@as(u32, 1), self.overrun);
    // A retune re-arms without storage in the same episode: no new report.
    try iface.receive(26);
    try std.testing.expect(!self.rx_reserved);
    try std.testing.expectEqual(@as(u32, 1), self.overrun);
    for (0..event_capacity) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    try expect_overrun(iface);
    try std.testing.expect(iface.poll() == null);

    // Poll freed a slot, so filling the FIFO again starts a new episode.
    microzig.Fixture.dispatch_ready_rx();
    try std.testing.expect(self.rx_reserved);
    for (0..event_capacity - 1) |_| self.enqueue(.{ .rx_error = .aborted });
    try receive_test_frame(&self);
    try std.testing.expect(!self.rx_reserved);
    try std.testing.expectEqual(@as(u32, 1), self.overrun);
    for (0..event_capacity - 1) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
    try expect_overrun(iface);
    try std.testing.expect(iface.poll() == null);
}

test "a later starvation folds into the unread marker's position" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    for (0..event_capacity) |_| self.enqueue(.{ .rx_error = .aborted });
    try iface.set_rx_on_when_idle(true);
    try std.testing.expectEqual(@as(usize, event_capacity), self.overrun_before);
    try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    microzig.Fixture.dispatch_ready_rx();
    try std.testing.expect(self.rx_reserved);
    // Frame F fills the FIFO, so the next arm starts a new episode.
    try receive_test_frame(&self);
    try std.testing.expect(!self.rx_reserved);
    try std.testing.expectEqual(@as(u32, 2), self.overrun);
    // The new episode keeps the unread marker's position, before F.
    for (1..event_capacity) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    try expect_overrun(iface);
    try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
    try std.testing.expect(iface.poll() == null);
}

test "poll returns a leading marker without arming RX against a full FIFO" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    for (0..event_capacity) |_| self.enqueue(.{ .rx_error = .aborted });
    try iface.set_rx_on_when_idle(true);
    try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    microzig.Fixture.dispatch_ready_rx();
    try receive_test_frame(&self);
    try std.testing.expect(!self.rx_reserved);
    // Draining the aborts re-arms reserved and brings the marker to the head.
    for (1..event_capacity) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    try std.testing.expect(self.rx_reserved);
    try std.testing.expectEqual(@as(usize, 0), self.overrun_before);
    try std.testing.expectEqual(@as(usize, 1), self.queued);
    // Fill the FIFO up to the arm's slot and receive into it.
    for (0..event_capacity - 2) |_| self.enqueue(.{ .rx_error = .aborted });
    microzig.Fixture.dispatch_ready_rx();
    try receive_test_frame(&self);
    try std.testing.expect(!self.rx_reserved);
    try std.testing.expectEqual(@as(usize, event_capacity), self.queued);
    // Reading the marker frees no slot, so poll must not re-arm.
    try expect_overrun(iface);
    try std.testing.expect(!self.rx_reserved);
    try std.testing.expectEqual(@as(usize, event_capacity), self.queued);
    try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
    try std.testing.expect(self.rx_reserved);
}

fn reach_backoff_slot() void {
    microzig.Fixture.advance(owner.?.backoff_tick.?);
}

test "a buffer-missing backoff arm whose slot is due reports no overrun" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.set_rx_on_when_idle(true);
    try iface.sleep();
    // With the TX reservation, these leave no RX slot.
    for (0..event_capacity - 2) |_| self.enqueue(.{ .rx_error = .aborted });
    _ = seed_test_backoff(&self);
    microzig.fx.on_packetptr_clear = reach_backoff_slot;
    try iface.transmit(&.{ .bytes = &test_unicast, .channel = 25 });
    try std.testing.expect(microzig.fx.on_packetptr_clear == null);
    // The arm took the slot without issuing RXEN.
    try std.testing.expect(self.backoff_tick == null and self.phase != .backoff);
    try std.testing.expectEqual(@as(u32, 0), self.overrun);
    try std.testing.expect(!self.starved_reported);
}

test "an owner's abort without its slot at a Mode stop faults and counts" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    for (0..event_capacity - 1) |_| self.enqueue(.{ .rx_error = .aborted });
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    test_frame(&self, &test_unicast);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    try std.testing.expect(service_test_radio());
    // Break the invariant: an event takes the owner's slot.
    self.enqueue(.{ .rx_error = .window_ended });
    try iface.sleep();
    try std.testing.expectEqual(Interface.Fault{ .reason = .event_reservation }, iface.poll().?.fault);
    for (0..event_capacity - 1) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    try std.testing.expectEqual(Interface.RxError.window_ended, iface.poll().?.rx_error);
    try expect_overrun(iface);
    try std.testing.expect(iface.poll() == null);
}

test "poll retirement fault keeps the FIFO head in both poll modes" {
    for ([_]enum { ordinary, response, backoff }{ .ordinary, .response, .backoff }) |origin| {
        for ([_]Interface.PollMode{ .drain, .preserve_fault }) |mode| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            if (origin == .backoff) {
                try iface.set_rx_on_when_idle(true);
                try iface.sleep();
                _ = seed_test_backoff(&self);
            }
            const fifo_count: usize = if (origin == .backoff) event_capacity - 2 else event_capacity;
            self.enqueue(.{ .rx_error = .window_ended });
            for (1..fifo_count) |_| self.enqueue(.{ .rx_error = .aborted });
            switch (origin) {
                .ordinary => try iface.receive(25),
                .response => {
                    self.poll_response = .{ .channel = 25, .end_deadline = 2000 };
                    self.begin_disabled(.rx);
                },
                .backoff => try iface.transmit(&.{ .bytes = &test_unicast, .channel = 25 }),
            }
            microzig.Fixture.dispatch_ready_rx();
            try std.testing.expect(!self.rx_reserved);
            try std.testing.expectEqual(@as(u32, @bitCast(@as(@TypeOf(radio.SHORTS).underlying_type, .{
                .DISABLED_RSSISTOP = .Enabled,
            }))), radio.SHORTS.raw);
            const writes = EnableWrites.snapshot();
            const read_index = self.read_index;
            microzig.fx.shorts_stuck = true;
            const event = Dispatch.poll(&self, mode);
            if (mode == .preserve_fault) {
                try std.testing.expect(event == null);
                try std.testing.expectEqual(Interface.Fault{ .reason = .producer_revocation }, iface.poll().?.fault);
            } else {
                try std.testing.expectEqual(Interface.Fault{ .reason = .producer_revocation }, event.?.fault);
            }
            try writes.expect_delta(0, 0);
            try std.testing.expectEqual(read_index, self.read_index);
            try std.testing.expectEqual(fifo_count + @intFromBool(origin == .backoff), self.queued);
            try std.testing.expectEqual(Interface.RxError.window_ended, iface.poll().?.rx_error);
            for (1..fifo_count) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
            try expect_overrun(iface);
            if (origin == .backoff) try expect_aborted_operation(iface, .tx);
            try std.testing.expect(iface.poll() == null);
        }
    }
}

fn fail_replacement_at_cutoff() void {
    microzig.fx.ppi_disable_stuck = @backingInt(tx_sfd_capture);
    microzig.Fixture.advance(microzig.fx.jump_tick);
}

test "poll retains FIFO head when replacement setup crosses a deadline and retirement fails" {
    for ([_]bool{ false, true }) |backoff| {
        for ([_]Interface.PollMode{ .drain, .preserve_fault }) |mode| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            const count: usize = if (backoff) event_capacity - 2 else event_capacity;
            self.enqueue(.{ .rx_error = .window_ended });
            for (1..count) |_| self.enqueue(.{ .rx_error = .aborted });
            if (backoff) {
                try iface.set_rx_on_when_idle(true);
                try iface.sleep();
                _ = seed_test_backoff(&self);
                try iface.transmit(&.{ .bytes = &test_unicast, .channel = 25 });
            } else {
                self.poll_response = .{ .channel = 25, .end_deadline = 2000 };
                self.begin_disabled(.rx);
            }
            microzig.Fixture.dispatch_ready_rx();
            try std.testing.expect(!self.rx_reserved);
            const writes = EnableWrites.snapshot();
            const head = self.read_index;
            microzig.fx.jump_tick = self.deadline.?;
            microzig.fx.on_packetptr_install = fail_replacement_at_cutoff;
            const event = Dispatch.poll(&self, mode);
            try std.testing.expect(microzig.fx.on_packetptr_install == null);
            try writes.expect_delta(0, 0);
            try std.testing.expectEqual(head, self.read_index);
            if (mode == .preserve_fault) try std.testing.expect(event == null);
            const fault = if (mode == .preserve_fault) iface.poll().? else event.?;
            try std.testing.expectEqual(Interface.Fault{ .reason = .producer_revocation }, fault.fault);
            try std.testing.expectEqual(Interface.RxError.window_ended, iface.poll().?.rx_error);
            for (1..count) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
            try expect_overrun(iface);
            if (backoff) try expect_aborted_operation(iface, .tx);
            try std.testing.expect(iface.poll() == null);
        }
    }
}

fn seed_test_backoff(self: *Radio) u32 {
    for (0..64) |seed| {
        self.random = .init(seed);
        var preview = self.random;
        const be = self.rx_settings.current().config.min_be;
        const slots = preview.random().int(u8) & (@as(u8, 0xff) >> @intCast(8 - be));
        if (slots != 0) return @as(u32, slots) * backoff_us;
    }
    unreachable;
}

fn start_test_backoff(self: *Radio, iface: Interface, cutoff: u32) !void {
    try iface.set_rx_on_when_idle(true);
    try iface.sleep();
    _ = seed_test_backoff(self);
    microzig.fx.timer_step = 0;
    try iface.transmit(&.{ .bytes = &test_unicast, .channel = 25, .max_csma_backoffs = 4 });
    try std.testing.expectEqual(Phase.backoff, self.phase);
    self.backoff_tick = cutoff;
    self.arm_at(cutoff);
    microzig.Fixture.dispatch_ready_rx();
}

fn service_test_radio() bool {
    return microzig.Fixture.dispatch(.RADIO, radio_interrupt);
}

fn expect_radio_drained() !void {
    // An old source can already be pending in the NVIC. Consuming one
    // stale delivery must leave no level asserted and no second pending IRQ.
    _ = service_test_radio();
    try std.testing.expect(!service_test_radio());
}

fn service_test_timer() bool {
    return microzig.Fixture.dispatch(.TIMER3, timer_interrupt);
}

fn reveal_end_after_disabled() void {
    std.debug.assert(microzig.Fixture.reveal_latch(&radio.EVENTS_END));
}

test "due backoff slot drops late END and charges an established owner before delivery" {
    for ([_]bool{ false, true }) |established| {
        for ([_]bool{ false, true }) |timer_first| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            try start_test_backoff(&self, iface, 1000);
            test_frame(&self, &test_unicast);
            microzig.Fixture.advance(950);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            if (established) {
                try std.testing.expect(service_test_radio());
                try std.testing.expect(self.address_established);
            }
            microzig.Fixture.advance(1000);
            if (established) {
                microzig.Fixture.raise(&radio.EVENTS_END);
            } else {
                // END took its real shortcut while its own CPU latch was hidden.
                const completions = microzig.fx.disable_completions;
                microzig.Fixture.hold_latch(&radio.EVENTS_END);
                microzig.Fixture.raise(&radio.EVENTS_END);
                try std.testing.expectEqual(completions + 1, microzig.fx.disable_completions);
                try std.testing.expectEqual(@as(?u32, 1000), microzig.fx.disable_completed_at);
                try std.testing.expectEqual(@as(u32, 1000), timer.CC[tx_sfd_cc].raw);
                try std.testing.expect(radio.EVENTS_END.raw == 0 and radio.EVENTS_DISABLED.raw != 0);
                microzig.fx.on_radio_state_read = reveal_end_after_disabled;
            }
            const disables = microzig.fx.disables;
            try std.testing.expect(if (timer_first) service_test_timer() else service_test_radio());
            try std.testing.expectEqual(disables, microzig.fx.disables);
            if (established) {
                try std.testing.expectEqual(@as(u8, 1), self.tx.backoffs);
                const frame = iface.poll().?.rx;
                try std.testing.expect(!frame.ack_sent);
                try std.testing.expectEqualSlices(u8, &test_unicast, frame.bytes);
            } else {
                try std.testing.expect(microzig.fx.on_radio_state_read == null);
                try std.testing.expectEqual(Phase.tx_cca, self.phase);
                try std.testing.expectEqual(@as(u8, 0), self.tx.backoffs);
                microzig.Fixture.dispatch_ready_rx();
                try std.testing.expectEqual(@as(usize, 1), microzig.fx.cca_starts);
            }
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "CCA applies mode and threshold with clear true and busy false" {
    for ([_]bool{ false, true }) |clear| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try self.configure(.{ .cca_mode = .carrier_and_energy, .cca_threshold = -75, .rx_on_when_idle = false });
        try iface.cca();
        try std.testing.expectEqual(.CarrierAndEdMode, radio.CCACTRL.read().CCAMODE);
        try std.testing.expectEqual(@as(u8, @intCast(-75 - phy.ed_offset_dbm - self.adjustment)), radio.CCACTRL.read().CCAEDTHRES);
        microzig.Fixture.dispatch_ready_rx();
        if (clear) {
            microzig.Fixture.raise(&radio.EVENTS_CCAIDLE);
            try std.testing.expectEqual(.RxIdle, radio.STATE.read().STATE);
        } else {
            microzig.Fixture.raise(&radio.EVENTS_CCABUSY);
        }
        try std.testing.expect(service_test_radio());
        try std.testing.expectEqual(clear, try iface.poll().?.cca_done);
        try std.testing.expect(iface.poll() == null);
    }
}

fn inject_rssi_packet_address() void {
    std.debug.assert(microzig.fx.mask_depth != 0);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    radio.RSSISAMPLE.write(.{ .RSSISAMPLE = 67 });
}

test "diagnostic RSSI leaves packet sample ownership with ADDRESS" {
    for ([_]bool{ false, true }) |after_start| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try std.testing.expectError(error.InvalidState, iface.rssi());
        try iface.receive(25);
        microzig.fx.timer_step = 0;
        microzig.Fixture.advance(40);
        microzig.Fixture.dispatch_ready_rx();
        try std.testing.expectError(error.InvalidState, iface.rssi());
        microzig.Fixture.advance(65);
        test_frame(&self, &test_unicast);
        try std.testing.expectEqual(@as(i8, -50 - self.adjustment), try iface.rssi());
        if (after_start) microzig.fx.on_rssi_start = inject_rssi_packet_address else microzig.fx.on_rssi_clear = inject_rssi_packet_address;
        try std.testing.expectError(error.Busy, iface.rssi());
        microzig.Fixture.advance(480);
        microzig.Fixture.raise(&radio.EVENTS_END);

        try std.testing.expect(service_test_radio());
        try std.testing.expectEqual(@as(i8, -67 - self.adjustment), iface.poll().?.rx.rssi);
        try std.testing.expect(iface.poll() == null);
    }
}

test "confirmed enabled-idle clock stall crosses RTC wrap and seals stale vectors" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    const saved = iface.now_us();
    self.progress_rtc = 0xfffffe - 80;
    microzig.Fixture.set_rtc(0xfffffe);
    microzig.fx.timer_step = 0;
    microzig.fx.rtc_step = 1;
    microzig.Fixture.raise(&timer.EVENTS_COMPARE[temperature_cc]);
    try std.testing.expect(service_test_timer());
    try std.testing.expectEqual(Interface.State.disabled, iface.state());
    try std.testing.expectEqual(saved, iface.now_us());
    try std.testing.expectEqual(Interface.Fault{ .reason = .clock_stalled }, iface.poll().?.fault);
    const captures = microzig.fx.capture_count;
    // Deliberately call stale vectors after their NVIC lines are sealed.
    radio_interrupt();
    timer_interrupt();
    try iface.disable();
    try std.testing.expectEqual(captures, microzig.fx.capture_count);
    try std.testing.expect(iface.poll() == null);
    try self.deinit();
}

test "TEMP verification failure is reported even with saturated sticky count" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    self.fault = .{ .reason = .clock_stalled, .count = std.math.maxInt(u32) };
    microzig.fx.temp_retirement_stalls = true;
    try std.testing.expectError(error.HardwareFault, iface.disable());
    try std.testing.expectEqual(Interface.Fault{ .reason = .clock_stalled, .count = std.math.maxInt(u32) }, iface.poll().?.fault);
    try std.testing.expectEqual(Interface.State.disabled, iface.state());
    try std.testing.expectError(error.HardwareFault, self.deinit());
}

test "temperature boundaries correct RSSI, ED and LQI in the right direction" {
    const samples = [_]struct { q: i32, adjustment: i8 }{
        .{ .q = -120, .adjustment = 3 }, .{ .q = -119, .adjustment = 2 },
        .{ .q = -40, .adjustment = 2 },  .{ .q = -39, .adjustment = 1 },
        .{ .q = 40, .adjustment = 1 },   .{ .q = 41, .adjustment = 0 },
        .{ .q = 120, .adjustment = 0 },  .{ .q = 121, .adjustment = -1 },
        .{ .q = 200, .adjustment = -1 }, .{ .q = 201, .adjustment = -2 },
        .{ .q = 280, .adjustment = -2 }, .{ .q = 281, .adjustment = -3 },
    };
    for (samples) |sample| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        microzig.fx.timer_step = 0;
        temp.TEMP.write(.{ .TEMP = @bitCast(sample.q) });
        microzig.Fixture.advance(self.temp_deadline.?);
        try std.testing.expect(service_test_timer());
        try std.testing.expectEqual(sample.adjustment, self.adjustment);

        try iface.receive(25);
        microzig.Fixture.dispatch_ready_rx();
        test_frame(&self, &test_unicast);
        self.packet[1 + test_unicast.len] = 45;
        microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
        try std.testing.expect(service_test_radio());
        microzig.Fixture.advance(microzig.fx.tick + 400);
        microzig.Fixture.raise(&radio.EVENTS_END);
        try std.testing.expect(service_test_radio());
        const frame = iface.poll().?.rx;
        try std.testing.expectEqual(@as(i8, -50) - sample.adjustment, frame.rssi);
        try std.testing.expectEqual(@as(u8, @intCast(180 - @as(i16, sample.adjustment) * 4)), frame.lqi);

        try iface.energy_scan(25, 128);
        microzig.Fixture.dispatch_ready_rx();
        radio.EDSAMPLE.write(.{ .EDLVL = 30 });
        microzig.Fixture.advance(microzig.fx.tick + 128);
        microzig.Fixture.raise(&radio.EVENTS_EDEND);
        try std.testing.expect(service_test_radio());
        try std.testing.expectEqual(@as(i8, -62) - sample.adjustment, iface.poll().?.energy_scan_done);
        try std.testing.expect(iface.poll() == null);
    }
}

test "RX policy settlement retires the old request before a later renewal" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.set_rx_on_when_idle(true);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    test_frame(&self, &test_unicast);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    microzig.fx.on_settings_publish = raise_test_end;
    try iface.set_rx_on_when_idle(false);
    try std.testing.expect(self.rx_request == null);
    try std.testing.expect(iface.poll().? == .rx);
    try std.testing.expectEqual(Phase.off, self.phase);
    try iface.receive(25);
    const renewed = self.rx_request.?;
    try std.testing.expectEqual(renewed, self.rx_request.?);
    try std.testing.expectEqual(renewed, self.arm_request.?);
}

test "response cutoff after the admission sample leaves that decision committed" {
    for ([_]enum { receive, tx, ed, cca }{ .receive, .tx, .ed, .cca }) |entry| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        self.rx_channel = 11;
        self.poll_response = .{ .channel = 25, .end_deadline = 1000 };
        self.begin_disabled(.rx);
        try iface.receive(25);
        microzig.Fixture.dispatch_ready_rx();
        microzig.fx.timer_step = 0;
        microzig.Fixture.advance(999);
        microzig.fx.jump_after_capture = microzig.fx.capture_count + 4;
        microzig.fx.jump_tick = 1000;
        switch (entry) {
            .receive => {
                try iface.receive(25);
                try std.testing.expect(self.poll_response != null);
                try std.testing.expect(self.rx_request == null);
                _ = service_test_timer();
                try std.testing.expectEqual(@as(u8, 25), self.rx_channel);
                try std.testing.expect(self.rx_request != null);
            },
            .tx => try iface.transmit(&.{ .bytes = &test_unicast, .channel = 25, .csma_ca = false }),
            .ed => try iface.energy_scan(25, 128),
            .cca => try iface.cca(),
        }
        try std.testing.expect(self.poll_response == null and self.deferred_channel == null);
        if (entry != .receive) {
            try std.testing.expectEqual(@as(u8, 11), self.rx_channel);
            try std.testing.expect(self.rx_request == null);
            if (entry == .cca) try std.testing.expectEqual(@as(u8, 25), self.measurement_channel);
        }
    }
}

test "unexpected buffer-missing DISABLED outranks a due response or slot" {
    for ([_]enum { ordinary, response, backoff }{ .ordinary, .response, .backoff }) |context| {
        for ([_]bool{ false, true }) |timer_first| {
            if (timer_first and context == .ordinary) continue; // No CC1 deadline is armed.
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            const fill = event_capacity - @as(usize, if (context == .backoff) 2 else 0);
            for (0..fill) |_| self.enqueue(.{ .rx_error = .aborted });
            switch (context) {
                .ordinary => try iface.receive(25),
                .response => {
                    self.poll_response = .{ .channel = 25, .end_deadline = 1000 };
                    self.begin_disabled(.rx);
                    try iface.receive(25);
                },
                .backoff => try start_test_backoff(&self, iface, 1000),
            }
            try std.testing.expect(!self.rx_reserved);
            microzig.Fixture.advance(1000);
            microzig.Fixture.inject_unexpected_disabled();
            try std.testing.expect(if (timer_first) service_test_timer() else service_test_radio());
            try std.testing.expectEqual(Interface.State.disabled, iface.state());
            try std.testing.expectEqual(Interface.Fault{ .reason = .unexpected_disabled }, iface.poll().?.fault);
            for (0..fill) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
            try expect_overrun(iface);
            if (context == .backoff) try std.testing.expectEqual(Interface.TxStatus.aborted, iface.poll().?.tx_done.status);
            try std.testing.expect(iface.poll() == null);
        }
    }
}

fn wake_after_isolation(ptr: ?*anyopaque) void {
    std.debug.assert(microzig.fx.mask_depth != 0);
    std.debug.assert(!microzig.fx.enabled[@backingInt(microzig.cpu.Interrupt.RADIO)]);
    std.debug.assert(!microzig.fx.enabled[@backingInt(microzig.cpu.Interrupt.TIMER3)]);
    std.debug.assert(!microzig.fx.pending[@backingInt(microzig.cpu.Interrupt.RADIO)]);
    std.debug.assert(!microzig.fx.pending[@backingInt(microzig.cpu.Interrupt.TIMER3)]);
    const count: *usize = @ptrCast(@alignCast(ptr.?));
    count.* += 1;
}

test "hook swap on a prologue fault wakes only the new hook after final isolation" {
    for ([_]bool{ false, true }) |install| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        var old_wakes: usize = 0;
        var new_wakes: usize = 0;
        iface.set_notify(.{ .context = &old_wakes, .call = wake_after_isolation });
        try iface.energy_scan(25, 128);
        microzig.Fixture.dispatch_ready_rx();
        const origin = microzig.fx.tick;
        microzig.Fixture.advance(origin + 128);
        iface.set_notify(if (install) .{ .context = &new_wakes, .call = wake_after_isolation } else null);
        try std.testing.expectEqual(@as(usize, 0), old_wakes);
        try std.testing.expectEqual(@as(usize, @intFromBool(install)), new_wakes);
        try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
        try std.testing.expectEqual(error.Aborted, iface.poll().?.energy_scan_failed);
        try std.testing.expect(iface.poll() == null);
    }
}

test "Deinit with pending results precedes a due measurement and retains ownership" {
    for ([_]enum { fifo, overrun, fault }{ .fifo, .overrun, .fault }) |backlog_kind| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        if (backlog_kind == .overrun) {
            // A buffer-missing arm reports overrun. Draining the FIFO
            // leaves only its marker.
            for (0..event_capacity) |_| self.enqueue(.{ .rx_error = .aborted });
            try iface.receive(25);
            for (0..event_capacity) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
            try std.testing.expect(self.queued == 0 and self.overrun != 0);
        }
        try iface.energy_scan(25, 128);
        microzig.Fixture.dispatch_ready_rx();
        microzig.Fixture.advance(microzig.fx.tick + 128);
        switch (backlog_kind) {
            .fifo => self.enqueue(.{ .rx_error = .aborted }),
            .overrun => {},
            .fault => self.record_fault(.missing_capture),
        }
        const captures = microzig.fx.capture_count;
        try std.testing.expectError(error.Busy, self.deinit());
        try std.testing.expectEqual(captures, microzig.fx.capture_count);
        try std.testing.expect(owner == &self and self.enabled and self.operation == .ed);
        const fault = iface.poll().?.fault;
        try std.testing.expectEqual(if (backlog_kind == .fault) Interface.FaultReason.missing_capture else .radio_timeout, fault.reason);
        if (backlog_kind == .fifo) try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
        if (backlog_kind == .overrun) try std.testing.expectEqual(Interface.RxError.overrun, iface.poll().?.rx_error);
        try std.testing.expectEqual(error.Aborted, iface.poll().?.energy_scan_failed);
        try self.deinit();
        try std.testing.expect(owner == null);
    }
}

test "settings typed and void changes publish nothing when prologue faults" {
    for ([_]bool{ false, true }) |typed| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try iface.energy_scan(25, 128);
        microzig.Fixture.dispatch_ready_rx();
        microzig.Fixture.advance(microzig.fx.tick + 128);
        if (typed) {
            try std.testing.expectError(error.Aborted, iface.set_rx_on_when_idle(true));
        } else {
            iface.set_pan_id(0x5678);
        }
        try std.testing.expectEqual(@as(u16, 0x1234), self.rx_settings.current().config.pan_id);
        try std.testing.expect(!self.rx_settings.current().config.rx_on_when_idle);
        try std.testing.expectEqual(Interface.State.disabled, iface.state());
        try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
        try std.testing.expectEqual(error.Aborted, iface.poll().?.energy_scan_failed);
    }
}

test "auto ACK keeps a live window cutoff and abandons the saved frame on Sleep" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    self.rx_channel = 11;
    self.poll_response = .{ .channel = 25, .end_deadline = 1000 };
    self.begin_disabled(.rx);
    microzig.Fixture.dispatch_ready_rx();
    test_frame(&self, &test_ack_request);
    microzig.fx.timer_step = 0;
    microzig.Fixture.advance(600);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    microzig.Fixture.advance(950);
    microzig.Fixture.raise(&radio.EVENTS_END);

    try std.testing.expect(service_test_radio());
    try std.testing.expectEqual(Phase.auto_ack, self.phase);
    try std.testing.expectEqual(@as(?u32, 1000), self.deadline);
    try iface.receive(25);
    microzig.Fixture.advance(1000);
    try std.testing.expect(service_test_timer());
    try std.testing.expect(self.poll_response == null and self.rx_request != null);
    try std.testing.expectEqual(Phase.auto_ack, self.phase);
    try iface.sleep();
    const abandoned = iface.poll().?.rx;
    try std.testing.expect(!abandoned.ack_sent and !abandoned.acked_with_frame_pending);
    try std.testing.expect(abandoned.timestamp_us != null);
    try std.testing.expect(iface.poll() == null);
    try std.testing.expectEqual(Interface.State.sleep, iface.state());
}

test "failed Enable cleanup quarantines a live RADIO and preserves the first reason" {
    microzig.Fixture.reset();
    var self: Radio = undefined;
    defer owner = null;
    try self.init(.{});
    const iface = self.ieee802154_radio();
    microzig.fx.timer_step = 0;
    microzig.fx.power_down_stalls = true;
    try std.testing.expectError(error.HardwareFault, iface.enable());
    try std.testing.expectEqual(Interface.FaultPending{
        .pending = true,
        .reason = .clock_stalled,
        .count = 2,
    }, iface.fault_pending());
    try std.testing.expectEqual(@as(usize, 0), self.queued_event_count());
    try std.testing.expectEqual(Interface.State.disabled, iface.state());
    try std.testing.expectError(error.Busy, self.deinit());
    try std.testing.expectEqual(@as(u32, 2), iface.poll().?.fault.count);
    try std.testing.expectError(error.HardwareFault, self.deinit());
    try std.testing.expectError(error.HardwareFault, iface.enable());
    try std.testing.expect(owner == &self);
}

test "housekeeping re-primes quiet RX across rollover and skips an owned frame" {
    for ([_]bool{ false, true }) |owned| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        microzig.fx.timer_step = 0;
        // Set the local epoch and prime near hardware wrap to exercise the
        // half-range CC1 latch without requiring billions of fake ticks.
        self.public_tick = 0xc000_0000;
        microzig.Fixture.advance(self.public_tick);
        try iface.receive(25);
        const request = self.rx_request;
        const compare = timer.CC[deadline_cc].read().CC;
        try std.testing.expectEqual(@as(u32, 0x4000_0000), compare);
        microzig.Fixture.dispatch_ready_rx();
        if (owned) {
            microzig.Fixture.advance(compare -% 10);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            try std.testing.expect(service_test_radio());
        }
        microzig.Fixture.advance(compare);
        try std.testing.expect(service_test_timer());
        try std.testing.expectEqual(request, self.rx_request);
        if (owned) {
            try std.testing.expect(!self.housekeeping and self.address_established);
            try std.testing.expectEqual(@as(u32, 0xc000_0000), self.capture_prime);
        } else {
            try std.testing.expect(self.housekeeping);
            try std.testing.expectEqual(compare, self.capture_prime);
            try std.testing.expect(!self.rx_settled);
        }
        try std.testing.expect(iface.poll() == null);
    }
}

test "valid TX PHYEND completes without a saved CCA clear result" {
    for ([_]bool{ false, true }) |cca_enabled| {
        for ([_]bool{ false, true }) |request_ack| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            try iface.transmit(&.{
                .bytes = if (request_ack) &test_ack_request else &test_unicast,
                .channel = 25,
                .csma_ca = cca_enabled,
                .max_csma_backoffs = 0,
            });
            if (cca_enabled) {
                microzig.Fixture.dispatch_ready_rx();
                microzig.Fixture.raise(&radio.EVENTS_CCAIDLE);
                radio.EVENTS_CCAIDLE.write_raw(0);
            }
            microzig.Fixture.raise(&radio.EVENTS_TXREADY);
            try std.testing.expect(service_test_radio());
            try std.testing.expect(self.tx_attempt.launched);
            microzig.fx.timer_step = 0;
            microzig.Fixture.advance(1000);
            microzig.Fixture.raise(&radio.EVENTS_END);
            try std.testing.expectEqual(@as(u32, 0), microzig.fx.disable_completions);
            microzig.Fixture.raise(&radio.EVENTS_PHYEND);

            try std.testing.expect(service_test_radio());
            try std.testing.expect(iface.poll().?.tx_started.timestamp_us != null);
            if (request_ack) {
                try std.testing.expectEqual(Phase.ack_rx, self.phase);
                try std.testing.expectEqual(@as(?u32, 1000 + ack_wait_us + phy.rx_end_delay_us), self.deadline);
            } else {
                try std.testing.expectEqual(Interface.TxStatus.sent, iface.poll().?.tx_done.status);
            }
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "progress-only wake survives mode stop and the final lifecycle clear" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    var wakes: usize = 0;
    iface.set_notify(.{ .context = &wakes, .call = wake_after_isolation });
    self.request_event_notification();
    try iface.sleep();
    try std.testing.expect(microzig.fx.pending[@backingInt(microzig.cpu.Interrupt.RADIO)]);
    try std.testing.expectEqual(@as(usize, 0), wakes);
    try iface.disable();
    try std.testing.expectEqual(@as(usize, 1), wakes);
    try std.testing.expect(iface.poll() == null);
    try self.deinit();
}

test "occupied Init leaves a due ED untouched and verified Init retires both producers" {
    microzig.Fixture.reset();
    var self: Radio = undefined;
    defer owner = null;
    try self.init(.{});
    try std.testing.expectEqual(@as(usize, 1), microzig.fx.rng_stops);
    try std.testing.expectEqual(@as(usize, 1), microzig.fx.temp_stops);
    const initial_captures = microzig.fx.capture_count;
    try self.deinit();
    try std.testing.expectEqual(initial_captures, microzig.fx.capture_count);

    const iface = try init_test_radio(&self);
    try iface.energy_scan(25, 128);
    microzig.Fixture.dispatch_ready_rx();
    microzig.Fixture.advance(microzig.fx.tick + 128);
    const captures = microzig.fx.capture_count;
    var other: Radio = undefined;
    try std.testing.expectError(error.Busy, other.init(.{ .channel = 0 }));
    try std.testing.expectEqual(captures, microzig.fx.capture_count);
    try std.testing.expect(owner == &self and self.enabled and self.operation == .ed);
    try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
    try std.testing.expectEqual(error.Aborted, iface.poll().?.energy_scan_failed);
}

test "unverified RNG or TEMP Init cleanup leaves routing installed and isolated" {
    for ([_]bool{ false, true }) |rng_fault| {
        microzig.Fixture.reset();
        var self: Radio = undefined;
        defer owner = null;
        microzig.fx.rng_retirement_stalls = rng_fault;
        microzig.fx.temp_retirement_stalls = !rng_fault;
        try std.testing.expectError(error.HardwareFault, self.init(.{}));
        const iface = self.ieee802154_radio();
        try std.testing.expectEqual(Interface.State.disabled, iface.state());
        try std.testing.expectEqual(@as(usize, 0), self.queued_event_count());
        try std.testing.expect(owner == &self and self.quarantined);
        try std.testing.expectEqual(if (rng_fault) Interface.FaultReason.rng_retirement else .temp_retirement, iface.poll().?.fault.reason);
        try std.testing.expectError(error.HardwareFault, self.deinit());
    }
}

test "direct Deinit waits for delayed ADDRESS capture on the departing RX arm" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    microzig.fx.ack_capture_stalls = true;
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    microzig.fx.delayed_capture = .{
        .cc = end_cc,
        .route = @backingInt(end_capture),
        .tick = microzig.fx.tick,
    };
    try std.testing.expectError(error.Busy, self.deinit());
    try std.testing.expect(microzig.fx.delayed_capture == null);
    try std.testing.expect(!end_capture.enabled());
    try std.testing.expect(!iface.fault_pending().pending);
    try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    try self.deinit();
}

test "mode and lifecycle stops abort every admitted measurement with one terminal" {
    for ([_]bool{ false, true }) |disable| {
        for ([_]enum { ed, cca, tx_cca }{ .ed, .cca, .tx_cca }) |measurement| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            switch (measurement) {
                .ed => try iface.energy_scan(25, 128),
                .cca => try iface.cca(),
                .tx_cca => try iface.transmit(&.{ .bytes = &test_unicast, .channel = 25, .max_csma_backoffs = 0 }),
            }
            microzig.Fixture.dispatch_ready_rx();
            try std.testing.expect(service_test_radio());
            // Pending hardware would complete normally if a prologue ran.
            if (measurement == .ed) {
                microzig.Fixture.raise(&radio.EVENTS_EDEND);
            } else {
                microzig.Fixture.raise(&radio.EVENTS_CCABUSY);
            }
            if (disable) try iface.disable() else try iface.sleep();
            const terminal = iface.poll().?;
            switch (measurement) {
                .ed => try std.testing.expectEqual(error.Aborted, terminal.energy_scan_failed),
                .cca => try std.testing.expectError(error.Aborted, terminal.cca_done),
                .tx_cca => try std.testing.expectEqual(Interface.TxStatus.aborted, terminal.tx_done.status),
            }
            _ = service_test_radio();
            _ = service_test_timer();
            try std.testing.expect(iface.poll() == null);
            try std.testing.expectEqual(if (disable) Interface.State.disabled else .sleep, iface.state());
        }
    }
}

test "repeated Enable reports its own prologue fault without restarting" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    const temp_starts = microzig.fx.temp_starts;
    const cc5 = timer.CC[temperature_cc].raw;
    const before = iface.now_us();
    try iface.enable();
    try std.testing.expectEqual(temp_starts, microzig.fx.temp_starts);
    try std.testing.expectEqual(cc5, timer.CC[temperature_cc].raw);
    try iface.cca();
    microzig.Fixture.dispatch_ready_rx();
    microzig.Fixture.advance(microzig.fx.tick + ed_sample_us);
    try std.testing.expectError(error.HardwareFault, iface.enable());
    try std.testing.expectEqual(temp_starts, microzig.fx.temp_starts);
    try std.testing.expectEqual(Interface.State.disabled, iface.state());
    try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
    try std.testing.expectError(error.Aborted, iface.poll().?.cca_done);
    try iface.enable();
    try std.testing.expectEqual(temp_starts + 1, microzig.fx.temp_starts);
    try std.testing.expect(iface.now_us() >= before);
    try std.testing.expect(iface.poll() == null);
}

fn start_test_sender_ack(iface: Interface, frame: []const u8, cutoff_during_setup: bool) !void {
    try iface.transmit(&.{
        .bytes = frame,
        .channel = 25,
        .csma_ca = false,
        .max_frame_retries = 0,
    });
    microzig.Fixture.raise(&radio.EVENTS_TXREADY);
    try std.testing.expect(service_test_radio());
    try std.testing.expect(!service_test_radio());
    microzig.fx.timer_step = 0;
    microzig.Fixture.advance(1000);
    if (cutoff_during_setup) microzig.fx.expire_on_compare_arm = 1000 + ack_wait_us + phy.rx_end_delay_us;
    microzig.Fixture.raise(&radio.EVENTS_PHYEND);
    try std.testing.expect(service_test_radio());
    try std.testing.expect(iface.poll().? == .tx_started);
}

const test_data_request = [_]u8{ 0x63, 0x88, 1, 0x34, 0x12, 3, 0, 1, 0, 0x04 };

test "sender ACK and new response launch recheck deadline after setup begins" {
    for ([_]bool{ false, true }) |sender| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        const writes = EnableWrites.snapshot();
        try start_test_sender_ack(iface, &test_data_request, sender);
        if (sender) {
            try std.testing.expectEqual(@as(usize, 0), microzig.fx.rx_enables);
            try std.testing.expectEqual(Interface.TxStatus.no_ack, iface.poll().?.tx_done.status);
        } else {
            try std.testing.expectEqual(Phase.ack_rx, self.phase);
            try std.testing.expect(self.tx.possible_data_request);
            microzig.Fixture.dispatch_ready_rx();
            test_frame(&self, &.{ 0x12, 0, 1 });
            microzig.Fixture.advance(1400);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            try std.testing.expect(service_test_radio());
            microzig.Fixture.advance(1600);
            microzig.fx.expire_on_compare_arm = 1600 + data_poll_wait_us;
            microzig.Fixture.raise(&radio.EVENTS_END);
            try std.testing.expect(service_test_radio());
            try std.testing.expectEqual(Phase.rx, self.rx_replacement.?);
            try std.testing.expect(service_test_radio());
            try std.testing.expectEqual(Interface.TxStatus.acked, iface.poll().?.tx_done.status);
            try std.testing.expectEqual(@as(usize, 1), microzig.fx.rx_enables);
        }
        try writes.expect_delta(@intFromBool(!sender), 1);
        try std.testing.expect(microzig.fx.expire_on_compare_arm == null);
        try std.testing.expect(self.poll_response == null);
        try std.testing.expectEqual(Interface.State.sleep, iface.state());
        try std.testing.expect(!service_test_radio());
        try std.testing.expect(iface.poll() == null);
    }
}

test "verified sender ACK survives failure retiring its arm" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try start_test_sender_ack(iface, &test_data_request, false);
    try std.testing.expectEqual(Phase.ack_rx, self.phase);
    microzig.Fixture.dispatch_ready_rx();
    test_frame(&self, &.{ 0x12, 0, 1 });
    microzig.Fixture.advance(1400);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    try std.testing.expect(service_test_radio());
    microzig.Fixture.advance(1600);
    const writes = EnableWrites.snapshot();
    microzig.fx.ppi_disable_stuck = @backingInt(tx_sfd_capture);
    microzig.Fixture.raise(&radio.EVENTS_END);
    try std.testing.expect(service_test_radio());
    try writes.expect_delta(0, 0);
    try std.testing.expect(self.poll_response == null);
    try std.testing.expect(self.rx_replacement == null);
    try std.testing.expectEqual(Interface.Fault{ .reason = .producer_revocation }, iface.poll().?.fault);
    const terminal = iface.poll().?.tx_done;
    try std.testing.expectEqual(Interface.TxStatus.acked, terminal.status);
    try std.testing.expect(terminal.timestamp_us == null);
    const ack = terminal.ack.?;
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0, 1 }, ack.bytes);
    try std.testing.expect(ack.timestamp_us == null);
    try std.testing.expect(iface.poll() == null);
}

test "TX start remains staged when expired sender ACK setup fails retirement" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.transmit(&.{ .bytes = &test_ack_request, .channel = 25, .csma_ca = false, .max_frame_retries = 0 });
    microzig.Fixture.raise(&radio.EVENTS_TXREADY);
    try std.testing.expect(service_test_radio());
    microzig.fx.timer_step = 0;
    microzig.Fixture.advance(1000);
    microzig.fx.jump_tick = 1000 + ack_wait_us + phy.rx_end_delay_us;
    microzig.fx.on_packetptr_install = fail_replacement_at_cutoff;
    const writes = EnableWrites.snapshot();
    microzig.Fixture.raise(&radio.EVENTS_PHYEND);
    try std.testing.expect(service_test_radio());
    try std.testing.expect(microzig.fx.on_packetptr_install == null);
    try writes.expect_delta(0, 0);
    try std.testing.expectEqual(Interface.Fault{ .reason = .producer_revocation }, iface.poll().?.fault);
    try std.testing.expect(iface.poll().?.tx_started.timestamp_us == null);
    const terminal = iface.poll().?.tx_done;
    try std.testing.expect(terminal.status == .aborted and terminal.timestamp_us == null);
    try std.testing.expect(iface.poll() == null);
}

test "response continuation omits stale RXEN after a frame or immediate ACK" {
    for ([_]bool{ false, true }) |with_ack| {
        for ([_]bool{ false, true }) |renew| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            self.poll_response = .{ .channel = 25, .end_deadline = 2000 };
            self.begin_disabled(.rx);
            if (renew) try iface.receive(25);
            microzig.Fixture.dispatch_ready_rx();
            microzig.fx.timer_step = 0;
            test_frame(&self, if (with_ack) &test_ack_request else &test_unicast);
            microzig.Fixture.advance(500);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            try std.testing.expect(service_test_radio());
            const writes = EnableWrites.snapshot();
            microzig.Fixture.advance(1000);
            if (!with_ack) microzig.fx.expire_on_compare_arm = 2000;
            microzig.Fixture.raise(&radio.EVENTS_END);
            try std.testing.expect(service_test_radio());
            if (with_ack) {
                try std.testing.expectEqual(Phase.auto_ack, self.phase);
                try start_test_ack_on_air(1000);
                microzig.fx.expire_on_compare_arm = 2000;
                microzig.Fixture.raise(&radio.EVENTS_PHYEND);
                try std.testing.expect(service_test_radio());
            }
            try std.testing.expectEqual(Phase.rx, self.rx_replacement.?);
            try writes.expect_delta(0, @intFromBool(with_ack));
            try std.testing.expect(service_test_radio());
            try writes.expect_delta(@intFromBool(renew), @intFromBool(with_ack));
            try std.testing.expectEqual(@as(usize, if (renew) 2 else 1), microzig.fx.rx_enables);
            try std.testing.expectEqual(renew, self.arm_request != null);
            try std.testing.expect(microzig.fx.expire_on_compare_arm == null);
            try std.testing.expect(self.poll_response == null);
            try std.testing.expectEqual(with_ack, iface.poll().?.rx.ack_sent);
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "verified response ACK survives failure retiring the old or replacement arm" {
    for ([_]bool{ false, true }) |fail_replacement| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try iface.add_src_match(.{ .short = 1 });
        try iface.set_src_match_enabled(true);
        self.poll_response = .{ .channel = 25, .end_deadline = 2000 };
        self.begin_disabled(.rx);
        microzig.Fixture.dispatch_ready_rx();
        microzig.fx.timer_step = 0;
        test_frame(&self, &test_data_request);
        microzig.Fixture.advance(500);
        microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
        try std.testing.expect(service_test_radio());
        microzig.Fixture.advance(1000);
        microzig.Fixture.raise(&radio.EVENTS_END);
        try std.testing.expect(service_test_radio());
        try std.testing.expectEqual(Phase.auto_ack, self.phase);
        try std.testing.expectEqual(@as(u8, 0x12), self.packet[1]);
        try start_test_ack_on_air(1000);

        const writes = EnableWrites.snapshot();
        if (!fail_replacement) microzig.fx.ppi_disable_stuck = @backingInt(ack_launch);
        microzig.Fixture.raise(&radio.EVENTS_PHYEND);
        try std.testing.expect(service_test_radio());
        var expected_timestamp: ?u64 = null;
        if (fail_replacement) {
            try writes.expect_delta(0, 0);
            try std.testing.expectEqual(Phase.rx, self.rx_replacement.?);
            try std.testing.expectEqual(@as(usize, 1), self.queued);
            const saved = self.queue[self.read_index].rx.metadata;
            try std.testing.expect(saved.ack_sent and saved.acked_with_frame_pending);
            try std.testing.expect(saved.timestamp_us != null);
            expected_timestamp = saved.timestamp_us;
            microzig.fx.jump_tick = 2000;
            microzig.fx.on_packetptr_install = fail_replacement_at_cutoff;
            try std.testing.expect(service_test_radio());
            try std.testing.expect(microzig.fx.on_packetptr_install == null);
        }
        try writes.expect_delta(0, 0);
        try std.testing.expectEqual(Interface.Fault{ .reason = .producer_revocation }, iface.poll().?.fault);
        const frame = iface.poll().?.rx;
        try std.testing.expectEqualSlices(u8, &test_data_request, frame.bytes);
        try std.testing.expect(frame.ack_sent and frame.acked_with_frame_pending);
        try std.testing.expectEqual(expected_timestamp, frame.timestamp_us);
        try std.testing.expect(iface.poll() == null);
    }
}

fn inject_close_address() void {
    std.debug.assert(microzig.fx.mask_depth != 0);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
}

const EnableWrites = struct {
    rx: usize,
    tx: usize,

    fn snapshot() EnableWrites {
        return .{ .rx = microzig.fx.rxen_writes, .tx = microzig.fx.txen_writes };
    }

    fn expect_delta(self: EnableWrites, rx: usize, tx: usize) !void {
        try std.testing.expectEqual(EnableWrites{ .rx = self.rx + rx, .tx = self.tx + tx }, snapshot());
    }
};

fn submit_test_operation(iface: Interface, operation: Operation) !void {
    switch (operation) {
        .tx => try iface.transmit(&.{ .bytes = &test_unicast, .channel = 25, .csma_ca = false }),
        .ed => try iface.energy_scan(25, 128),
        .cca => try iface.cca(),
        .idle => unreachable,
    }
}

test "operation preflight refuses an existing RX owner and retains one found at commitment" {
    for ([_]Operation{ .tx, .ed, .cca }) |operation| {
        for ([_]bool{ false, true }) |before_preflight| {
            var request = test_ack_request;
            request[2] = if (before_preflight) 0xd3 else 0x7a;
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            try iface.receive(25);
            microzig.Fixture.dispatch_ready_rx();
            test_frame(&self, &request);
            if (before_preflight) {
                microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
                try std.testing.expectError(error.Busy, submit_test_operation(iface, operation));
                try std.testing.expect(self.reservation.remaining == null);
            } else {
                microzig.fx.on_address_read = inject_close_address;
                try submit_test_operation(iface, operation);
                try std.testing.expect(self.close.?.owned and self.stopping_rx != null);
                try std.testing.expectEqual(operation, self.operation);
                const state: Interface.State = switch (operation) {
                    .tx => .transmit,
                    .ed => .energy_scan,
                    .cca => .receive,
                    .idle => unreachable,
                };
                try std.testing.expectEqual(state, iface.state());
                try std.testing.expectError(error.Busy, iface.receive(25));
                try std.testing.expectError(error.Busy, iface.receive(11));
            }
            microzig.fx.timer_step = 0;
            const end = microzig.fx.tick;
            microzig.fx.defer_shortcut_disabled = !before_preflight;
            microzig.Fixture.raise(&radio.EVENTS_END);
            if (!before_preflight) microzig.fx.on_radio_state_read = complete_masked_rx;
            try std.testing.expect(service_test_radio());
            try std.testing.expect(microzig.fx.on_radio_state_read == null);
            microzig.fx.defer_shortcut_disabled = false;
            try std.testing.expectEqual(Phase.auto_ack, self.phase);
            try std.testing.expectEqual(request[2], self.packet[3]);
            try start_test_ack_on_air(end);
            microzig.Fixture.raise(&radio.EVENTS_PHYEND);
            try std.testing.expect(service_test_radio());
            const rx = iface.poll().?.rx;
            try std.testing.expect(rx.ack_sent);
            try std.testing.expectEqualSlices(u8, &request, rx.bytes);
            if (!before_preflight) {
                try std.testing.expectEqual(operation, self.operation);
                try iface.disable();
                const terminal = iface.poll().?;
                switch (operation) {
                    .tx => try std.testing.expectEqual(Interface.TxStatus.aborted, terminal.tx_done.status),
                    .ed => try std.testing.expectEqual(error.Aborted, terminal.energy_scan_failed),
                    .cca => try std.testing.expectError(error.Aborted, terminal.cca_done),
                    .idle => unreachable,
                }
            }
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "policy-close failure follows publication and excludes a late ADDRESS" {
    for ([_]bool{ false, true }) |configure| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try iface.set_rx_on_when_idle(true);
        try iface.receive(25);
        microzig.Fixture.dispatch_ready_rx();
        const writes = EnableWrites.snapshot();
        microzig.fx.disable_stalls = true;
        microzig.fx.on_disable = inject_close_address;
        if (configure) {
            try self.configure(.{ .rx_on_when_idle = false, .pan_id = 0x5678 });
        } else {
            try iface.set_rx_on_when_idle(false);
        }
        try std.testing.expect(!self.rx_settings.current().config.rx_on_when_idle);
        try std.testing.expectEqual(@as(u16, if (configure) 0x5678 else 0x1234), self.rx_settings.current().config.pan_id);
        try std.testing.expect(!iface.fault_pending().pending);
        try std.testing.expect(service_test_radio());
        try writes.expect_delta(0, 0);
        try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
        try std.testing.expect(iface.poll() == null);
        try std.testing.expectEqual(Interface.State.disabled, iface.state());
    }
}

fn raise_test_end() void {
    microzig.Fixture.raise(&radio.EVENTS_END);
}

fn hide_end_at_cutover() void {
    microzig.Fixture.hold_latch(&radio.EVENTS_END);
    microzig.Fixture.hold_latch(&radio.EVENTS_DISABLED);
    raise_test_end();
    std.debug.assert(radio.EVENTS_END.raw == 0 and radio.EVENTS_DISABLED.raw == 0);
}

fn end_before_settings_tick() void {
    hide_end_at_cutover();
    microzig.Fixture.advance(microzig.fx.tick +% 1);
}

fn end_after_settings_tick() void {
    microzig.Fixture.advance(microzig.fx.tick +% 1);
    hide_end_at_cutover();
}

fn arm_hidden_settings_end(before: bool, lost: bool) void {
    microzig.fx.lose_disabled_event = lost;
    if (before) {
        microzig.fx.on_settings_publish = end_before_settings_tick;
    } else {
        microzig.fx.on_settings_tick = end_after_settings_tick;
    }
}

fn check_hidden_settings_end(before: bool, cutover: u32) !u32 {
    try std.testing.expect(microzig.fx.on_settings_publish == null and microzig.fx.on_settings_tick == null);
    try std.testing.expectEqual(@as(u32, 0), radio.EVENTS_END.raw);
    try std.testing.expectEqual(@as(u32, 0), radio.EVENTS_DISABLED.raw);
    const end = if (before) cutover -% 1 else cutover +% 1;
    try std.testing.expectEqual(end, timer.CC[tx_sfd_cc].raw);
    try std.testing.expectEqual(@as(?u32, end), microzig.fx.disable_completed_at);
    return end;
}

fn dispatch_hidden_settings_end(lost: bool) !void {
    try std.testing.expect(microzig.Fixture.reveal_latch(&radio.EVENTS_END));
    try std.testing.expectEqual(!lost, microzig.Fixture.reveal_latch(&radio.EVENTS_DISABLED));
    try std.testing.expect(service_test_radio());
}

test "successive setters preserve generation A while END and CC3 are hidden" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    test_frame(&self, &test_ack_request);
    microzig.fx.timer_step = 0;
    microzig.Fixture.advance(500);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    const end = microzig.fx.tick;
    microzig.fx.hold_end_capture = true;
    hide_end_at_cutover();
    try std.testing.expectEqual(@as(?u32, end), microzig.fx.disable_completed_at);
    const sentinel = self.capture_prime -% 1;
    var config = self.rx_settings.current().config;
    config.tx_power = -4;
    microzig.Fixture.advance(end + 1);
    try self.configure(config);
    try std.testing.expectEqual(sentinel, timer.CC[tx_sfd_cc].raw);
    microzig.Fixture.advance(end + 2);
    try iface.set_rx_on_when_idle(true);
    try std.testing.expectEqual(sentinel, timer.CC[tx_sfd_cc].raw);
    try std.testing.expectEqual(@as(usize, 3), self.rx_settings.count);
    try std.testing.expectEqual(@as(u32, 0), radio.EVENTS_END.raw);
    try std.testing.expectEqual(@as(u32, 0), radio.EVENTS_DISABLED.raw);

    microzig.Fixture.reveal_end_capture();
    try dispatch_hidden_settings_end(false);
    try std.testing.expectEqual(Phase.auto_ack, self.phase);
    try std.testing.expectEqual(@as(u32, 0), radio.TXPOWER.raw);
    try std.testing.expect(self.rx_request == null);
    try start_test_ack_on_air(end);
    microzig.Fixture.raise(&radio.EVENTS_PHYEND);
    try std.testing.expect(service_test_radio());
    try std.testing.expect(iface.poll().?.rx.ack_sent);
    try std.testing.expect(iface.poll() == null);
}

fn fill_settings_ring(self: *Radio, first_offset: u32) !Config {
    microzig.fx.timer_step = 0;
    var config = self.rx_settings.current().config;
    for (1..RxSettingsVersions.capacity) |i| {
        microzig.Fixture.advance(self.capture_prime +% first_offset +% @as(u32, @intCast(i - 1)));
        config.pan_id += 1;
        try self.configure(config);
    }
    try std.testing.expectEqual(RxSettingsVersions.capacity, self.rx_settings.count);
    return config;
}

test "full settings burst ignores wall age and services CC5 while waiting" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    var config = try fill_settings_ring(&self, 1);
    const oldest = self.rx_settings.oldest;
    const prior = config.pan_id;
    microzig.Fixture.advance(self.capture_prime +% settings_history_us +% 20);
    try std.testing.expect(!self.can_retire_settings_entry());
    try std.testing.expectEqual(oldest, self.rx_settings.oldest);

    self.temp_deadline = microzig.fx.tick + 20;
    self.program_compare(temperature_cc, self.temp_deadline.?);
    temp.TEMP.write(.{ .TEMP = 201 });
    const starts = microzig.fx.temp_starts;
    const wait_start = microzig.fx.tick;
    microzig.fx.timer_step = 1;
    config.pan_id += 1;
    try std.testing.expectError(error.Aborted, self.configure(config));
    try std.testing.expect(microzig.fx.tick -% wait_start >= settings_history_us);
    try std.testing.expectEqual(starts + 1, microzig.fx.temp_starts);
    try std.testing.expectEqual(@as(i8, -2), self.adjustment);
    try std.testing.expectEqual(prior, self.rx_settings.current().config.pan_id);
    try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
    try std.testing.expect(iface.poll() == null);
}

test "an aged committed settings span still protects a departing sentinel" {
    for ([_]bool{ false, true }) |departing| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try iface.receive(25);
        microzig.Fixture.dispatch_ready_rx();
        var config = try fill_settings_ring(&self, settings_history_us);
        if (departing) {
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            microzig.fx.hold_end_capture = true;
            microzig.fx.lose_disabled_event = true;
            hide_end_at_cutover();
        }
        try std.testing.expectEqual(!departing, self.can_retire_settings_entry());
        microzig.fx.timer_step = 1;
        const prior = config.pan_id;
        config.pan_id += 1;
        const result = self.configure(config);
        if (departing) {
            try std.testing.expectError(error.Aborted, result);
            try std.testing.expectEqual(prior, self.rx_settings.current().config.pan_id);
            try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
            try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
        } else {
            try result;
            try std.testing.expectEqual(config.pan_id, self.rx_settings.current().config.pan_id);
            try std.testing.expectEqual(RxSettingsVersions.capacity, self.rx_settings.count);
            try std.testing.expectEqual(self.capture_prime +% settings_history_us, self.rx_settings.entries[self.rx_settings.oldest].tick);
        }
        try std.testing.expect(iface.poll() == null);
    }
}

fn cross_settings_budget_during_rx() void {
    microzig.Fixture.advance(microzig.fx.tick +% settings_history_us +% 1);
}

test "full ring rechecks its budget when NORMAL retires the RX arm" {
    for ([_]bool{ false, true }) |idle| {
        for ([_]bool{ false, true }) |expired| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            if (idle) try iface.set_rx_on_when_idle(true) else try iface.receive(25);
            microzig.Fixture.dispatch_ready_rx();
            var config = try fill_settings_ring(&self, 1);
            const prior = config.pan_id;
            var frame = test_unicast;
            frame[3] = @truncate(prior);
            frame[4] = @truncate(prior >> 8);
            test_frame(&self, &frame);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            microzig.Fixture.advance(microzig.fx.tick + 1);
            microzig.fx.on_settings_tick = raise_test_end;
            if (expired) microzig.fx.on_rx_crc_read = cross_settings_budget_during_rx;
            config.pan_id += 1;
            const result = self.configure(config);
            try std.testing.expect(microzig.fx.on_settings_tick == null and microzig.fx.on_rx_crc_read == null);
            if (expired) {
                try std.testing.expectError(error.Aborted, result);
                try std.testing.expectEqual(prior, self.rx_settings.current().config.pan_id);
                try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
            } else {
                try result;
                try std.testing.expectEqual(config.pan_id, self.rx_settings.current().config.pan_id);
                try std.testing.expectEqual(Phase.rx, self.rx_replacement.?);
                try std.testing.expect(service_test_radio());
                try std.testing.expectEqual(if (idle) Phase.rx else .off, self.phase);
            }
            try std.testing.expectEqualSlices(u8, &frame, iface.poll().?.rx.bytes);
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "sender ACK uses captured settings and enters drain at the natural cutoff" {
    for ([_]enum { receive, timely_drain, late_drain }{ .receive, .timely_drain, .late_drain }) |mode| {
        for ([_]bool{ false, true }) |configure| {
            for ([_]bool{ false, true }) |before| {
                for ([_]bool{ false, true }) |lost| {
                    var self: Radio = undefined;
                    defer owner = null;
                    const iface = try init_test_radio(&self);
                    const old_idle = mode == .timely_drain and !before;
                    if (old_idle) try iface.set_rx_on_when_idle(true);
                    try start_test_sender_ack(iface, &.{ 0x63, 0x88, 1, 0x34, 0x12, 3, 0, 1, 0, 0x04 }, false);
                    microzig.Fixture.dispatch_ready_rx();
                    const bytes = [_]u8{ 0x12, 0, 1 };
                    test_frame(&self, &bytes);
                    const cutoff = self.sender_ack_cutoff();
                    microzig.Fixture.advance(cutoff -% 200);
                    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
                    try std.testing.expect(service_test_radio());
                    const writes = EnableWrites.snapshot();
                    if (mode != .receive) {
                        if (mode == .timely_drain) {
                            microzig.Fixture.advance(cutoff -% 1);
                            microzig.fx.lose_disabled_event = lost;
                            hide_end_at_cutover();
                            // Delay only CPU observations of departure through
                            // cutoff and the setter. The hardware has already
                            // captured END and run its shortcut.
                            microzig.fx.hide_rx_departure_state = true;
                        }
                        microzig.Fixture.advance(cutoff);
                        try std.testing.expect(service_test_timer());
                        try std.testing.expectEqual(Phase.ack_drain, self.phase);
                    }
                    microzig.fx.timer_step = 0;
                    const cutover = microzig.fx.tick + @as(u32, @intFromBool(before));
                    if (mode != .timely_drain) arm_hidden_settings_end(before, lost);
                    if (configure) {
                        var config = self.rx_settings.current().config;
                        config.rx_on_when_idle = !old_idle;
                        try self.configure(config);
                    } else {
                        try iface.set_rx_on_when_idle(!old_idle);
                    }
                    const end = if (mode == .timely_drain) cutoff -% 1 else try check_hidden_settings_end(before, cutover);
                    if (mode == .timely_drain) {
                        try std.testing.expectEqual(Phase.ack_drain, self.phase);
                        try std.testing.expectEqual(cutoff, self.rx_settings.entries[self.rx_settings.index(self.rx_settings.count - 1)].tick);
                        try std.testing.expectEqual(end, timer.CC[tx_sfd_cc].raw);
                        try std.testing.expectEqual(@as(?u32, end), microzig.fx.disable_completed_at);
                        try std.testing.expect(radio.EVENTS_END.raw == 0 and radio.EVENTS_DISABLED.raw == 0);
                        microzig.fx.hide_rx_departure_state = false;
                    }
                    try std.testing.expect(!iface.fault_pending().pending);
                    const end_idle = if (mode == .timely_drain or before) old_idle else !old_idle;
                    try dispatch_hidden_settings_end(lost);
                    if (lost) try writes.expect_delta(0, 0);
                    if (lost) try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
                    const done = iface.poll().?.tx_done;
                    const acked = !lost and mode != .late_drain;
                    try std.testing.expectEqual(if (acked) Interface.TxStatus.acked else .no_ack, done.status);
                    try std.testing.expectEqual(acked, done.ack != null);
                    if (acked) try std.testing.expectEqualSlices(u8, &bytes, done.ack.?.bytes);
                    try std.testing.expectEqual(acked and !end_idle, self.poll_response != null);
                    if (self.poll_response) |response| try std.testing.expectEqual(end +% data_poll_wait_us, response.end_deadline);
                    try std.testing.expect(iface.poll() == null);
                }
            }
        }
    }
}

test "data RX uses captured END for whole-generation filter ACK and idle policy" {
    for ([_]enum { ordinary, backoff, response }{ .ordinary, .backoff, .response }) |origin| {
        for ([_]enum { power, filter, idle }{ .power, .filter, .idle }) |edit| {
            for ([_]bool{ false, true }) |before| {
                for ([_]bool{ false, true }) |lost| {
                    var self: Radio = undefined;
                    defer owner = null;
                    const iface = try init_test_radio(&self);
                    switch (origin) {
                        .ordinary => {
                            try iface.receive(25);
                            microzig.Fixture.dispatch_ready_rx();
                        },
                        .backoff => try start_test_backoff(&self, iface, 2000),
                        .response => {
                            self.poll_response = .{ .channel = 25, .end_deadline = 2000 };
                            self.begin_disabled(.rx);
                            microzig.Fixture.dispatch_ready_rx();
                        },
                    }
                    test_frame(&self, &test_ack_request);
                    microzig.fx.timer_step = 0;
                    microzig.Fixture.advance(500);
                    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
                    const cutover = microzig.fx.tick + @as(u32, @intFromBool(before));
                    const old_idle = self.rx_settings.current().config.rx_on_when_idle;
                    const writes = EnableWrites.snapshot();
                    arm_hidden_settings_end(before, lost);
                    var config = self.rx_settings.current().config;
                    switch (edit) {
                        .power => {
                            config.tx_power = -4;
                            try self.configure(config);
                        },
                        .filter => {
                            config.pan_id = 0x5678;
                            try self.configure(config);
                        },
                        .idle => try iface.set_rx_on_when_idle(!old_idle),
                    }
                    const end = try check_hidden_settings_end(before, cutover);
                    const settings = self.rx_settings.at_end(end, self.capture_prime).config;
                    try std.testing.expectEqual(@as(u16, if (edit == .filter and !before) 0x5678 else 0x1234), settings.pan_id);
                    try std.testing.expectEqual(@as(i8, if (edit == .power and !before) -4 else 0), settings.tx_power);
                    try std.testing.expectEqual(if (edit != .idle or before) old_idle else !old_idle, settings.rx_on_when_idle);
                    try std.testing.expect(!iface.fault_pending().pending);
                    try dispatch_hidden_settings_end(lost);
                    if (lost) {
                        try writes.expect_delta(0, 0);
                        try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
                        try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
                        if (origin == .backoff) try expect_aborted_operation(iface, .tx);
                    } else if (before or edit != .filter) {
                        try std.testing.expectEqual(Phase.auto_ack, self.phase);
                        try std.testing.expectEqual(test_ack_request[2], self.packet[3]);
                        try std.testing.expectEqual(@as(u32, if (edit == .power and !before) 0xfc else 0), radio.TXPOWER.raw);
                        try start_test_ack_on_air(end);
                        microzig.Fixture.raise(&radio.EVENTS_PHYEND);
                        try std.testing.expect(service_test_radio());
                        const frame = iface.poll().?.rx;
                        try std.testing.expect(frame.ack_sent);
                        try std.testing.expectEqualSlices(u8, &test_ack_request, frame.bytes);
                        if (edit == .idle and origin == .ordinary) try std.testing.expectEqual(!before, self.rx_request != null);
                    } else {
                        try std.testing.expect(self.phase != .auto_ack);
                    }
                    try std.testing.expect(iface.poll() == null);
                }
            }
        }
    }
}

fn inject_pre_cutoff_address() void {
    inject_close_address();
    timer.CC[end_cc].raw -%= 1;
}

test "committed close masks ADDRESS and retained END without losing either capture" {
    for ([_]enum { operation, slot, response, housekeeping, policy, sender_ack }{
        .operation, .slot, .response, .housekeeping, .policy, .sender_ack,
    }) |kind| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        switch (kind) {
            .slot => try start_test_backoff(&self, iface, 2000),
            .response => {
                self.poll_response = .{ .channel = 25, .end_deadline = 2000 };
                self.begin_disabled(.rx);
                microzig.Fixture.dispatch_ready_rx();
            },
            .sender_ack => {
                try start_test_sender_ack(iface, &test_ack_request, false);
                microzig.Fixture.dispatch_ready_rx();
            },
            else => {
                if (kind == .policy) try iface.set_rx_on_when_idle(true);
                try iface.receive(25);
                microzig.Fixture.dispatch_ready_rx();
            },
        }
        microzig.fx.timer_step = 0;
        microzig.fx.on_address_read = inject_pre_cutoff_address;
        switch (kind) {
            .operation => try iface.energy_scan(25, 128),
            .policy => {
                try iface.set_rx_on_when_idle(false);
                try std.testing.expect(service_test_radio());
            },
            else => {
                const cutoff = if (kind == .housekeeping) timer.CC[deadline_cc].raw else self.deadline.?;
                microzig.Fixture.advance(cutoff);
                try std.testing.expect(service_test_timer());
            },
        }
        try std.testing.expect(microzig.fx.on_address_read == null);
        try std.testing.expect(self.close.?.owned);
        try std.testing.expect(radio.EVENTS_ADDRESS.raw != 0);
        try std.testing.expect(end_capture.enabled());
        try expect_radio_drained();

        if (kind == .sender_ack) test_frame(&self, &.{ 0x02, 0, 1 }) else test_frame(&self, &test_unicast);
        microzig.fx.defer_shortcut_disabled = true;
        microzig.Fixture.raise(&radio.EVENTS_END);
        microzig.fx.on_radio_state_read = complete_masked_rx;
        try std.testing.expect(service_test_radio());
        try std.testing.expect(microzig.fx.on_radio_state_read == null);
        try expect_radio_drained();
        if (kind == .sender_ack) {
            try std.testing.expectEqual(Interface.TxStatus.no_ack, iface.poll().?.tx_done.status);
        } else {
            try std.testing.expect(iface.poll().? == .rx);
        }
    }
}

test "missing DISABLED in a close faults once and keeps each reserved terminal" {
    for ([_]enum { tx, ed, cca, response, housekeeping, buffer, slot, busy_cca, busy_ramp_down, clear_cca }{
        .tx, .ed, .cca, .response, .housekeeping, .buffer, .slot, .busy_cca, .busy_ramp_down, .clear_cca,
    }) |kind| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        switch (kind) {
            .tx, .ed, .cca, .housekeeping => {
                try iface.receive(25);
                microzig.Fixture.dispatch_ready_rx();
            },
            .response => {
                self.poll_response = .{ .channel = 25, .end_deadline = 1000 };
                self.begin_disabled(.rx);
                microzig.Fixture.dispatch_ready_rx();
            },
            .buffer => {
                for (0..event_capacity) |_| self.enqueue(.{ .rx_error = .aborted });
                try iface.receive(25);
                microzig.Fixture.dispatch_ready_rx();
                try std.testing.expect(!self.rx_reserved);
            },
            .slot => try start_test_backoff(&self, iface, 1000),
            .busy_cca, .busy_ramp_down => {
                // A real backoff expires into hardware CCA with no RX owner.
                _ = seed_test_backoff(&self);
                try iface.transmit(&.{ .bytes = &test_unicast, .channel = 25, .max_csma_backoffs = 4 });
                microzig.Fixture.advance(self.backoff_tick.?);
                try std.testing.expect(service_test_timer());
                try std.testing.expectEqual(Phase.tx_cca, self.phase);
                microzig.Fixture.dispatch_ready_rx();
                microzig.fx.defer_shortcut_disabled = kind == .busy_ramp_down;
            },
            .clear_cca => {
                try iface.cca();
                microzig.Fixture.dispatch_ready_rx();
            },
        }

        microzig.fx.disable_stalls = kind != .tx;
        microzig.fx.lose_disabled_event = kind == .tx or kind == .busy_cca;
        const rxen_writes = microzig.fx.rxen_writes;
        const txen_writes = microzig.fx.txen_writes;
        const disables = microzig.fx.disables;
        switch (kind) {
            .tx => try submit_test_operation(iface, .tx),
            .ed => try submit_test_operation(iface, .ed),
            .cca => try submit_test_operation(iface, .cca),
            .response, .housekeeping, .slot => {
                microzig.Fixture.advance(timer.CC[deadline_cc].raw);
                try std.testing.expect(service_test_timer());
            },
            .buffer => {
                try std.testing.expect(Dispatch.poll(&self, .preserve_fault) == null);
                try std.testing.expectEqual(@as(usize, event_capacity), self.queued_event_count());
            },
            .busy_cca, .busy_ramp_down, .clear_cca => {
                if (kind != .clear_cca) {
                    microzig.Fixture.raise(&radio.EVENTS_CCABUSY);
                } else {
                    microzig.Fixture.raise(&radio.EVENTS_CCAIDLE);
                }
                try std.testing.expect(service_test_radio());
            },
        }
        try std.testing.expectEqual(disables + 1, microzig.fx.disables);
        try std.testing.expectEqual(rxen_writes, microzig.fx.rxen_writes);
        try std.testing.expectEqual(txen_writes, microzig.fx.txen_writes);
        try std.testing.expectEqual(Interface.State.disabled, iface.state());
        try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
        switch (kind) {
            .tx, .slot, .busy_cca, .busy_ramp_down => try std.testing.expectEqual(Interface.TxStatus.aborted, iface.poll().?.tx_done.status),
            .ed => try std.testing.expectEqual(error.Aborted, iface.poll().?.energy_scan_failed),
            .cca, .clear_cca => try std.testing.expectError(error.Aborted, iface.poll().?.cca_done),
            .buffer => {
                for (0..event_capacity) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
                try expect_overrun(iface);
            },
            else => {},
        }
        try std.testing.expect(iface.poll() == null);
        try std.testing.expect(!service_test_radio());
        try std.testing.expect(!service_test_timer());
    }
}

test "backoff slot crossed during arm setup launches CCA without listening RXEN" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.set_rx_on_when_idle(true);
    try iface.sleep();
    microzig.fx.timer_step = 0;
    microzig.fx.expire_on_compare_arm = microzig.fx.tick +% seed_test_backoff(&self);
    const writes = EnableWrites.snapshot();
    try iface.transmit(&.{ .bytes = &test_unicast, .channel = 25, .max_csma_backoffs = 4 });
    try std.testing.expect(microzig.fx.expire_on_compare_arm == null);
    try std.testing.expectEqual(Phase.tx_cca, self.phase);
    try writes.expect_delta(1, 0);
    try std.testing.expectEqual(@as(u8, 0), self.tx.backoffs);
    microzig.Fixture.dispatch_ready_rx();
    try std.testing.expectEqual(@as(usize, 1), microzig.fx.cca_starts);
}

fn complete_masked_rx() void {
    std.debug.assert(radio.INTENSET.read().END != .Enabled);
    std.debug.assert(radio.INTENSET.read().ADDRESS != .Enabled);
    std.debug.assert(radio.EVENTS_END.raw != 0 and tx_sfd_capture.enabled());
    microzig.Fixture.complete_shortcut();
}

fn cross_slot_during_end_read() void {
    microzig.Fixture.advance(owner.?.backoff_tick.?);
    // The device already captured END and its shortcut already produced
    // DISABLED. Reveal only the delayed CPU-visible END latch.
    std.debug.assert(microzig.Fixture.reveal_latch(&radio.EVENTS_END));
}

fn cross_slot_during_frame_read() void {
    microzig.Fixture.advance(owner.?.backoff_tick.?);
}

fn reveal_address_and_end_in_wait() void {
    const close = owner.?.close.?;
    std.debug.assert(close.disabled and !close.owned and close.address_tick == null);
    std.debug.assert(radio.INTENSET.read().ADDRESS != .Enabled);
    microzig.Fixture.reveal_end_capture();
    std.debug.assert(microzig.Fixture.reveal_latch(&radio.EVENTS_ADDRESS));
    std.debug.assert(microzig.Fixture.reveal_latch(&radio.EVENTS_END));
}

test "DISABLED-first RX keeps a late-visible ADDRESS outside the saved boundary" {
    for ([_]bool{ false, true }) |response| {
        for ([_]bool{ false, true }) |capture_visible| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            if (response) {
                self.poll_response = .{ .channel = 25, .end_deadline = 2000 };
                self.begin_disabled(.rx);
            } else {
                try iface.receive(25);
            }
            microzig.Fixture.dispatch_ready_rx();
            const window = self.poll_response;
            const request = self.rx_request;
            const rx_enables = microzig.fx.rx_enables;
            const address_reads = microzig.fx.address_samples;
            const disabled_reads = microzig.fx.disabled_samples;
            test_frame(&self, &test_ack_request);
            microzig.fx.timer_step = 0;
            microzig.Fixture.advance(500);
            microzig.Fixture.hold_latch(&radio.EVENTS_ADDRESS);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            microzig.Fixture.hold_latch(&radio.EVENTS_END);
            microzig.fx.hold_end_capture = !capture_visible;
            microzig.Fixture.raise(&radio.EVENTS_END);
            if (!capture_visible) microzig.fx.on_end_read = reveal_address_and_end_in_wait;
            try std.testing.expect(service_test_radio());
            try std.testing.expect(microzig.fx.on_end_read == null);
            if (capture_visible) {
                try std.testing.expectEqual(@as(u32, 0), radio.EVENTS_END.raw);
                try std.testing.expectEqual(@as(u32, 0), radio.EVENTS_ADDRESS.raw);
            }
            try std.testing.expectEqual(address_reads + 1, microzig.fx.address_samples);
            try std.testing.expectEqual(disabled_reads + 1, microzig.fx.disabled_samples);
            try std.testing.expectEqual(Phase.rx, self.rx_replacement.?);
            try std.testing.expectEqual(rx_enables, microzig.fx.rx_enables);
            try std.testing.expect(service_test_radio());
            try std.testing.expectEqual(Phase.rx, self.phase);
            try std.testing.expectEqual(rx_enables + 1, microzig.fx.rx_enables);
            try std.testing.expectEqual(@as(usize, 0), microzig.fx.tx_enables);
            try std.testing.expect(!iface.fault_pending().pending);
            try std.testing.expectEqual(window, self.poll_response);
            try std.testing.expectEqual(request, self.rx_request);
            try expect_radio_drained();
            try std.testing.expect(iface.poll() == null);
        }
    }
}

fn reveal_end_at_slot_commitment() void {
    const self = owner.?;
    const close = self.close.?;
    std.debug.assert(microzig.fx.tick == self.backoff_tick.?);
    std.debug.assert(close.disabled and close.owned == self.address_established);
    std.debug.assert(microzig.Fixture.reveal_latch(&radio.EVENTS_END));
}

test "slot crossed at DISABLED commitment excludes only an unestablished owner" {
    for ([_]bool{ false, true }) |established| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try start_test_backoff(&self, iface, 1000);
        test_frame(&self, &test_unicast);
        microzig.Fixture.advance(900);
        microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
        if (established) try std.testing.expect(service_test_radio());
        try std.testing.expectEqual(established, self.address_established);
        microzig.Fixture.advance(999);
        microzig.Fixture.hold_latch(&radio.EVENTS_END);
        microzig.Fixture.raise(&radio.EVENTS_END);
        const busy = self.tx.backoffs;
        const be = self.tx.be;
        const disabled_reads = microzig.fx.disabled_samples;
        const address_reads = microzig.fx.address_samples;
        // Resolve reads now, checks the still-live slot, then takes the
        // commitment decision tick as DISABLED wins dispatch.
        microzig.fx.on_capture = .{ .number = microzig.fx.capture_count + 3, .call = cross_slot_during_frame_read };
        if (established) microzig.fx.on_end_read = reveal_end_at_slot_commitment;
        try std.testing.expect(service_test_radio());
        try std.testing.expect(microzig.fx.on_capture == null and microzig.fx.on_end_read == null);
        try std.testing.expectEqual(disabled_reads + 1, microzig.fx.disabled_samples);
        try std.testing.expectEqual(address_reads + 1, microzig.fx.address_samples);
        if (established) {
            try std.testing.expectEqual(busy + 1, self.tx.backoffs);
            try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
        } else {
            try std.testing.expectEqual(@as(u32, 0), radio.EVENTS_END.raw);
            try std.testing.expectEqual(busy, self.tx.backoffs);
            try std.testing.expectEqual(be, self.tx.be);
            try std.testing.expect(!iface.fault_pending().pending);
            try std.testing.expectEqual(Phase.tx_cca, self.rx_replacement.?);
            try std.testing.expect(service_test_radio());
            try std.testing.expectEqual(Phase.tx_cca, self.phase);
            try std.testing.expectEqual(@as(usize, 0), microzig.fx.cca_starts);
            microzig.Fixture.dispatch_ready_rx();
            try std.testing.expectEqual(@as(usize, 1), microzig.fx.cca_starts);
        }
        try std.testing.expect(iface.poll() == null);
    }
}

fn cross_slot_after_backoff_disposition() void {
    const self = owner.?;
    std.debug.assert(self.pending_rx == null and self.queued == 1);
    std.debug.assert(!self.ramped and !self.backoff_listening);
    microzig.Fixture.advance(microzig.fx.jump_tick);
}

test "backoff slot decision is after published RX and before replacement setup" {
    for ([_]bool{ false, true }) |retained| {
        for ([_]bool{ false, true }) |listening| {
            for ([_]microzig.Fixture.BackoffBoundary{ .published, .settled, .released }) |boundary| {
                var self: Radio = undefined;
                defer owner = null;
                const iface = try init_test_radio(&self);
                try start_test_backoff(&self, iface, 1000);
                microzig.Fixture.advance(900);
                test_frame(&self, &test_unicast);
                microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
                try std.testing.expect(service_test_radio());
                if (retained) {
                    microzig.Fixture.advance(1000);
                    try std.testing.expect(service_test_timer());
                    try std.testing.expectEqual(Phase.stopping, self.phase);
                    self.backoff_tick = 1200;
                    self.arm_at(1200);
                }
                if (!listening) try iface.set_rx_on_when_idle(false);
                const busy = self.tx.backoffs;
                const old_slot = self.backoff_tick.?;
                const writes = EnableWrites.snapshot();
                // Select a nonzero retry so any CCA at this tick is from
                // the old slot, never from a coincident zero-delay retry.
                _ = seed_test_backoff(&self);
                microzig.fx.jump_tick = old_slot;
                microzig.fx.on_backoff_departure = .{ .boundary = boundary, .call = cross_slot_after_backoff_disposition };
                microzig.Fixture.raise(&radio.EVENTS_END);
                try std.testing.expect(service_test_radio());
                try std.testing.expect(microzig.fx.on_backoff_departure == null);
                try std.testing.expect(self.rx_replacement != null);
                try writes.expect_delta(0, 0);
                try std.testing.expect(service_test_radio());
                const charge = boundary == .published;
                try std.testing.expectEqual(busy + @intFromBool(charge), self.tx.backoffs);
                if (charge) {
                    try std.testing.expectEqual(Phase.backoff, self.phase);
                    try std.testing.expect(self.backoff_tick.? > old_slot);
                    try writes.expect_delta(@intFromBool(listening), 0);
                } else {
                    try std.testing.expectEqual(Phase.tx_cca, self.phase);
                    try std.testing.expect(self.backoff_tick == null);
                    try writes.expect_delta(1, 0);
                    microzig.Fixture.dispatch_ready_rx();
                }
                try std.testing.expectEqual(@as(usize, @intFromBool(!charge)), microzig.fx.cca_starts);
                try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
                try std.testing.expect(iface.poll() == null);
            }
        }
    }
}

test "separate backoff replacement faults preserve the published timestamp" {
    for ([_]enum { listening, retained, immediate_ack }{ .listening, .retained, .immediate_ack }) |origin| {
        for ([_]bool{ false, true }) |fail_setup| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            const slot = 2000;
            try start_test_backoff(&self, iface, if (origin == .retained) 1000 else slot);
            const bytes: []const u8 = if (origin == .immediate_ack) &test_ack_request else &test_unicast;
            test_frame(&self, bytes);
            microzig.Fixture.advance(900);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            try std.testing.expect(service_test_radio());
            if (origin == .retained) {
                microzig.Fixture.advance(1000);
                try std.testing.expect(service_test_timer());
                try std.testing.expectEqual(Phase.stopping, self.phase);
                self.backoff_tick = slot;
                self.arm_at(slot);
            }

            microzig.Fixture.advance(1100);
            microzig.Fixture.raise(&radio.EVENTS_END);
            try std.testing.expect(service_test_radio());
            if (origin == .immediate_ack) {
                try std.testing.expectEqual(Phase.auto_ack, self.phase);
                try start_test_ack_on_air(1100);
                microzig.Fixture.raise(&radio.EVENTS_PHYEND);
                try std.testing.expect(service_test_radio());
            }
            try std.testing.expectEqual(Phase.backoff, self.rx_replacement.?);
            try std.testing.expectEqual(Phase.off, self.phase);
            try std.testing.expect(!self.ramped and !self.backoff_listening);
            try std.testing.expect(!tx_sfd_capture.enabled() and !end_capture.enabled() and !ack_launch.enabled());
            try std.testing.expect(self.notify == null);
            try std.testing.expect(microzig.fx.pending[@backingInt(microzig.cpu.Interrupt.RADIO)]);
            try std.testing.expectEqual(@as(usize, 1), self.queued);
            const timestamp = self.queue[self.read_index].rx.metadata.timestamp_us;
            try std.testing.expect(timestamp != null);
            const writes = EnableWrites.snapshot();
            const busy = self.tx.backoffs;

            if (fail_setup) {
                // Reach the slot with the replacement's routes installed.
                microzig.fx.jump_tick = slot;
                microzig.fx.on_packetptr_install = fail_replacement_at_cutoff;
                try std.testing.expect(service_test_radio());
                try std.testing.expect(microzig.fx.on_packetptr_install == null);
                try writes.expect_delta(0, 0);
                try std.testing.expectEqual(Interface.Fault{ .reason = .producer_revocation }, iface.poll().?.fault);
            } else {
                // Reach the slot while the replacement is still deferred.
                microzig.Fixture.advance(slot);
                try std.testing.expect(service_test_radio());
                try writes.expect_delta(1, 0);
                try std.testing.expectEqual(Phase.tx_cca, self.phase);
                microzig.Fixture.dispatch_ready_rx();
                try std.testing.expectEqual(@as(usize, 1), microzig.fx.cca_starts);
            }
            try std.testing.expectEqual(busy, self.tx.backoffs);
            const frame = iface.poll().?.rx;
            try std.testing.expectEqual(timestamp, frame.timestamp_us);
            try std.testing.expectEqual(origin == .immediate_ack, frame.ack_sent);
            try std.testing.expectEqualSlices(u8, bytes, frame.bytes);
            if (fail_setup) try expect_aborted_operation(iface, .tx);
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "CSMA exhaustion commits RX then its earned terminal before deferred setup" {
    for ([_]enum { listening, retained, immediate_ack }{ .listening, .retained, .immediate_ack }) |origin| {
        for ([_]enum { sleep, disable, fault }{ .sleep, .disable, .fault }) |takeover| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            const slot = 2000;
            try start_test_backoff(&self, iface, if (origin == .retained) 1000 else slot);
            const bytes: []const u8 = if (origin == .immediate_ack) &test_ack_request else &test_unicast;
            test_frame(&self, bytes);
            microzig.Fixture.advance(900);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            try std.testing.expect(service_test_radio());
            if (origin == .retained) {
                microzig.Fixture.advance(1000);
                try std.testing.expect(service_test_timer());
                try std.testing.expectEqual(Phase.stopping, self.phase);
                self.backoff_tick = slot;
                self.arm_at(slot);
            }
            self.tx.max_backoffs = self.tx.backoffs;
            const busy = self.tx.backoffs;

            microzig.Fixture.advance(1100);
            if (origin != .immediate_ack) {
                microzig.fx.jump_tick = slot;
                microzig.fx.on_backoff_departure = .{ .boundary = .published, .call = cross_slot_after_backoff_disposition };
            }
            microzig.Fixture.raise(&radio.EVENTS_END);
            try std.testing.expect(service_test_radio());
            if (origin == .immediate_ack) {
                try std.testing.expectEqual(Phase.auto_ack, self.phase);
                try start_test_ack_on_air(1100);
                microzig.Fixture.advance(slot);
                try std.testing.expect(service_test_timer());
                try std.testing.expect(self.earned_tx_terminal() == .channel_access_failure and self.queued == 0);
                microzig.Fixture.raise(&radio.EVENTS_PHYEND);
                try std.testing.expect(service_test_radio());
            }

            try std.testing.expectEqual(busy + 1, self.tx.backoffs);
            try std.testing.expectEqual(Phase.off, self.phase);
            try std.testing.expectEqual(Phase.rx, self.rx_replacement.?);
            try std.testing.expectEqual(Operation.idle, self.operation);
            try std.testing.expect(self.earned_tx_terminal() == null);
            try std.testing.expectEqual(@as(usize, 2), self.queued);
            try std.testing.expect(microzig.fx.pending[@backingInt(microzig.cpu.Interrupt.RADIO)]);
            const writes = EnableWrites.snapshot();
            switch (takeover) {
                .sleep => try iface.sleep(),
                .disable => try iface.disable(),
                .fault => {
                    microzig.fx.temp_retirement_stalls = true;
                    microzig.Fixture.advance(self.temp_deadline.?);
                    try std.testing.expect(service_test_timer());
                    try std.testing.expectEqual(Interface.FaultReason.temp_retirement, iface.poll().?.fault.reason);
                },
            }
            try writes.expect_delta(0, 0);
            try std.testing.expect(self.rx_replacement == null);
            const frame = iface.poll().?.rx;
            try std.testing.expectEqualSlices(u8, bytes, frame.bytes);
            try std.testing.expect(frame.timestamp_us != null);
            try std.testing.expectEqual(origin == .immediate_ack, frame.ack_sent);
            try std.testing.expectEqual(Interface.TxStatus.channel_access_failure, iface.poll().?.tx_done.status);
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "earned busy terminal survives retained RX or ACK teardown before publication" {
    for ([_]bool{ false, true }) |immediate_ack| {
        for ([_]enum { sleep, disable, lost_disabled }{ .sleep, .disable, .lost_disabled }) |takeover| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            const slot = 2000;
            try start_test_backoff(&self, iface, slot);
            self.tx.max_backoffs = 0;
            test_frame(&self, if (immediate_ack) &test_ack_request else &test_unicast);
            microzig.Fixture.advance(900);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            try std.testing.expect(service_test_radio());
            if (immediate_ack) {
                microzig.Fixture.advance(1100);
                microzig.Fixture.raise(&radio.EVENTS_END);
                try std.testing.expect(service_test_radio());
                try start_test_ack_on_air(1100);
            }

            microzig.Fixture.advance(slot);
            try std.testing.expect(service_test_timer());
            try std.testing.expectEqual(if (immediate_ack) Phase.auto_ack else .stopping, self.phase);
            try std.testing.expectEqual(Interface.TxStatus.channel_access_failure, self.earned_tx_terminal().?);
            try std.testing.expectEqual(@as(usize, 0), self.queued);
            try std.testing.expect(self.rx_replacement == null);
            const writes = EnableWrites.snapshot();
            switch (takeover) {
                .sleep => try iface.sleep(),
                .disable => try iface.disable(),
                .lost_disabled => {
                    microzig.fx.lose_disabled_event = true;
                    if (immediate_ack) {
                        microzig.Fixture.raise(&radio.EVENTS_PHYEND);
                    } else {
                        microzig.Fixture.raise(&radio.EVENTS_END);
                    }
                    try std.testing.expect(service_test_radio());
                    try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
                },
            }
            try writes.expect_delta(0, 0);
            const disposition = iface.poll().?;
            if (immediate_ack) {
                const frame = disposition.rx;
                try std.testing.expectEqualSlices(u8, &test_ack_request, frame.bytes);
                try std.testing.expect(!frame.ack_sent and !frame.acked_with_frame_pending);
                if (takeover == .lost_disabled) try std.testing.expect(frame.timestamp_us == null);
            } else {
                try std.testing.expectEqual(Interface.RxError.aborted, disposition.rx_error);
            }
            try std.testing.expectEqual(Interface.TxStatus.channel_access_failure, iface.poll().?.tx_done.status);
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "only NORMAL CCABUSY service earns a terminal before a TX close" {
    for ([_]bool{ false, true }) |serviced| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try iface.transmit(&.{ .bytes = &test_unicast, .channel = 25, .max_csma_backoffs = 0 });
        microzig.Fixture.dispatch_ready_rx();
        try std.testing.expect(service_test_radio());
        microzig.fx.lose_disabled_event = serviced;
        const writes = EnableWrites.snapshot();
        microzig.Fixture.raise(&radio.EVENTS_CCABUSY);
        try std.testing.expectEqual(@as(usize, 0), self.queued);
        try std.testing.expect(self.earned_tx_terminal() == null);
        if (serviced) {
            try std.testing.expect(service_test_radio());
            try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
        } else {
            try iface.sleep();
        }
        try writes.expect_delta(0, 0);
        const terminal = iface.poll().?.tx_done;
        try std.testing.expectEqual(if (serviced) Interface.TxStatus.channel_access_failure else .aborted, terminal.status);
        try std.testing.expectEqual(@as(u8, @intFromBool(serviced)), self.tx.backoffs);
        try std.testing.expect(iface.poll() == null);
    }
}

test "slot crossed during END wait or classification charges the departing frame" {
    for ([_]bool{ false, true }) |retained| {
        for ([_]bool{ false, true }) |late_end| {
            for ([_]bool{ false, true }) |established| {
                // The retained retry can only exist after an owned slot.
                if (retained and !established) continue;
                var self: Radio = undefined;
                defer owner = null;
                const iface = try init_test_radio(&self);
                try start_test_backoff(&self, iface, 1000);
                microzig.Fixture.advance(900);
                microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
                if (established) {
                    try std.testing.expect(service_test_radio());
                } else {
                    try std.testing.expect(microzig.fx.pending[@backingInt(microzig.cpu.Interrupt.RADIO)]);
                    try std.testing.expect(!self.address_established);
                }
                if (retained) {
                    microzig.Fixture.advance(1000);
                    try std.testing.expect(service_test_timer());
                    try std.testing.expectEqual(Phase.stopping, self.phase);
                    self.backoff_tick = 1200;
                    self.arm_at(1200);
                }
                const previous_busy = self.tx.backoffs;
                test_frame(&self, &test_unicast);
                microzig.Fixture.advance(self.backoff_tick.? - 1);
                if (late_end) microzig.Fixture.hold_latch(&radio.EVENTS_END);
                microzig.Fixture.raise(&radio.EVENTS_END);
                if (late_end) {
                    microzig.fx.on_end_read = cross_slot_during_end_read;
                } else {
                    microzig.fx.on_rx_crc_read = cross_slot_during_frame_read;
                }
                try std.testing.expect(service_test_radio());
                try std.testing.expect(microzig.fx.on_end_read == null);
                try std.testing.expect(microzig.fx.on_rx_crc_read == null);
                try std.testing.expectEqual(previous_busy + 1, self.tx.backoffs);
                try std.testing.expect(iface.poll().? == .rx);
                try std.testing.expect(iface.poll() == null);
            }
        }
    }
}

fn finish_ack_at_slot_snapshot() void {
    microzig.fx.defer_shortcut_disabled = true;
    microzig.Fixture.raise(&radio.EVENTS_PHYEND);
    microzig.fx.on_radio_state_read = microzig.Fixture.complete_shortcut;
}

test "PHYEND between resolver entry and slot snapshot releases immediate ACK ownership" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try start_test_backoff(&self, iface, 2000);
    test_frame(&self, &test_ack_request);
    microzig.Fixture.advance(500);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    try std.testing.expect(service_test_radio());
    microzig.Fixture.advance(1000);
    microzig.Fixture.raise(&radio.EVENTS_END);
    try std.testing.expect(service_test_radio());
    try std.testing.expectEqual(Phase.auto_ack, self.phase);
    try start_test_ack_on_air(1000);
    microzig.Fixture.advance(2000);
    microzig.fx.on_capture = .{
        .number = microzig.fx.capture_count + 2,
        .call = finish_ack_at_slot_snapshot,
    };
    try std.testing.expect(service_test_timer());
    try std.testing.expect(microzig.fx.on_capture == null);
    try std.testing.expect(microzig.fx.on_radio_state_read == null);
    try std.testing.expectEqual(@as(u8, 0), self.tx.backoffs);
    try std.testing.expectEqual(Phase.tx_cca, self.rx_replacement.?);
    try std.testing.expect(service_test_radio());
    try std.testing.expectEqual(Phase.tx_cca, self.phase);
    try std.testing.expect(iface.poll().?.rx.ack_sent);
    microzig.Fixture.dispatch_ready_rx();
    try std.testing.expectEqual(@as(usize, 1), microzig.fx.cca_starts);
    try std.testing.expect(iface.poll() == null);
}

test "missing shortcut DISABLED faults RX and ED even after STATE becomes Disabled" {
    for ([_]enum { ordinary, response, backoff, sender, retained_tx, retained_ed, retained_cca, ed }{
        .ordinary, .response, .backoff, .sender, .retained_tx, .retained_ed, .retained_cca, .ed,
    }) |kind| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        switch (kind) {
            .backoff => try start_test_backoff(&self, iface, 2000),
            .sender => {
                try start_test_sender_ack(iface, &test_ack_request, false);
                microzig.Fixture.dispatch_ready_rx();
            },
            .ed => {
                try iface.energy_scan(25, 128);
                microzig.Fixture.dispatch_ready_rx();
            },
            .response => {
                self.poll_response = .{ .channel = 25, .end_deadline = 2000 };
                self.begin_disabled(.rx);
                microzig.Fixture.dispatch_ready_rx();
            },
            else => {
                try iface.receive(25);
                microzig.Fixture.dispatch_ready_rx();
            },
        }
        switch (kind) {
            .retained_tx, .retained_ed, .retained_cca => {
                microzig.fx.on_address_read = inject_close_address;
                try submit_test_operation(iface, switch (kind) {
                    .retained_tx => .tx,
                    .retained_ed => .ed,
                    .retained_cca => .cca,
                    else => unreachable,
                });
                try std.testing.expectEqual(Phase.stopping, self.phase);
            },
            .ed => {},
            else => {
                microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
                try std.testing.expect(service_test_radio());
            },
        }
        microzig.fx.lose_disabled_event = true;
        const rx_launches = microzig.fx.rxen_writes;
        const tx_launches = microzig.fx.txen_writes;
        const disables = microzig.fx.disables;
        if (kind == .ed) {
            microzig.Fixture.raise(&radio.EVENTS_EDEND);
        } else {
            microzig.Fixture.raise(&radio.EVENTS_END);
        }
        try std.testing.expectEqual(.Disabled, radio.STATE.read().STATE);
        try std.testing.expectEqual(@as(u32, 0), radio.EVENTS_DISABLED.raw);
        try std.testing.expect(service_test_radio());
        try std.testing.expectEqual(disables + 1, microzig.fx.disables);
        try std.testing.expectEqual(rx_launches, microzig.fx.rxen_writes);
        try std.testing.expectEqual(tx_launches, microzig.fx.txen_writes);
        try std.testing.expectEqual(Interface.State.disabled, iface.state());
        try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
        if (kind != .ed and kind != .sender) {
            try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
        }
        switch (kind) {
            .backoff, .retained_tx => try std.testing.expectEqual(Interface.TxStatus.aborted, iface.poll().?.tx_done.status),
            .sender => try std.testing.expectEqual(Interface.TxStatus.no_ack, iface.poll().?.tx_done.status),
            .ed, .retained_ed => try std.testing.expectEqual(error.Aborted, iface.poll().?.energy_scan_failed),
            .retained_cca => try std.testing.expectError(error.Aborted, iface.poll().?.cca_done),
            else => {},
        }
        try std.testing.expect(iface.poll() == null);
        try std.testing.expect(!service_test_radio());
        try std.testing.expect(!service_test_timer());
    }
}

fn inject_address_and_end() void {
    inject_close_address();
    raise_test_end();
}

fn complete_test_operation(iface: Interface, operation: Operation) !void {
    switch (operation) {
        .tx => {
            microzig.Fixture.raise(&radio.EVENTS_TXREADY);
            try std.testing.expect(service_test_radio());
            microzig.Fixture.raise(&radio.EVENTS_PHYEND);
            try std.testing.expect(service_test_radio());
            try std.testing.expect(iface.poll().? == .tx_started);
            try std.testing.expectEqual(Interface.TxStatus.sent, iface.poll().?.tx_done.status);
        },
        .ed => {
            microzig.Fixture.dispatch_ready_rx();
            microzig.Fixture.raise(&radio.EVENTS_EDEND);
            try std.testing.expect(service_test_radio());
            try std.testing.expect(iface.poll().? == .energy_scan_done);
        },
        .cca => {
            microzig.Fixture.dispatch_ready_rx();
            microzig.Fixture.raise(&radio.EVENTS_CCAIDLE);
            try std.testing.expect(service_test_radio());
            try std.testing.expect(try iface.poll().?.cca_done);
        },
        .idle => unreachable,
    }
}

fn expect_aborted_operation(iface: Interface, operation: Operation) !void {
    const terminal = iface.poll().?;
    switch (operation) {
        .tx => try std.testing.expectEqual(Interface.TxStatus.aborted, terminal.tx_done.status),
        .ed => try std.testing.expectEqual(error.Aborted, terminal.energy_scan_failed),
        .cca => try std.testing.expectError(error.Aborted, terminal.cca_done),
        .idle => unreachable,
    }
}

fn start_test_ack_on_air(end: u32) !void {
    const enables = microzig.fx.tx_enables;
    const starts = microzig.fx.tx_starts;
    microzig.Fixture.advance(end +% phy.ack_txen_us);
    try std.testing.expectEqual(enables + 1, microzig.fx.tx_enables);
    microzig.Fixture.raise(&radio.EVENTS_TXREADY);
    try std.testing.expectEqual(starts + 1, microzig.fx.tx_starts);
}

fn arm_test_immediate_ack(iface: Interface, self: *Radio, ahead_of: Operation) !u32 {
    test_frame(self, &test_ack_request);
    if (ahead_of != .idle) {
        microzig.fx.on_address_read = inject_close_address;
        try submit_test_operation(iface, ahead_of);
        try std.testing.expectEqual(Phase.stopping, self.phase);
    } else {
        microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
        try std.testing.expect(service_test_radio());
    }
    microzig.fx.timer_step = 0;
    const end = microzig.fx.tick;
    microzig.Fixture.raise(&radio.EVENTS_END);
    try std.testing.expect(service_test_radio());
    try std.testing.expectEqual(Phase.auto_ack, self.phase);
    return end;
}

fn start_test_immediate_ack(iface: Interface, self: *Radio, ahead_of: Operation) !void {
    try start_test_ack_on_air(try arm_test_immediate_ack(iface, self, ahead_of));
}

test "ACK PHYEND wakes the bounded verifier when DISABLED is lost" {
    for ([_]enum { ordinary, response, backoff, tx, ed, cca }{
        .ordinary, .response, .backoff, .tx, .ed, .cca,
    }) |context| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        switch (context) {
            .response => {
                self.poll_response = .{ .channel = 25, .end_deadline = 4000 };
                self.begin_disabled(.rx);
                microzig.Fixture.dispatch_ready_rx();
            },
            .backoff => try start_test_backoff(&self, iface, 4000),
            else => {
                try iface.receive(25);
                microzig.Fixture.dispatch_ready_rx();
            },
        }
        const operation: Operation = switch (context) {
            .backoff, .tx => .tx,
            .ed => .ed,
            .cca => .cca,
            else => .idle,
        };
        const writes = EnableWrites.snapshot();
        try start_test_immediate_ack(iface, &self, if (context == .backoff) .idle else operation);
        try std.testing.expect(!service_test_radio());
        microzig.fx.lose_disabled_event = true;
        microzig.Fixture.raise(&radio.EVENTS_PHYEND);
        try std.testing.expectEqual(@as(u32, 0), radio.EVENTS_DISABLED.raw);
        microzig.fx.on_radio_state_read = expect_phyend_masked;
        try std.testing.expect(service_test_radio());
        try std.testing.expect(microzig.fx.on_radio_state_read == null);
        try std.testing.expect(!service_test_radio());
        try writes.expect_delta(0, 1);
        try std.testing.expectEqual(Interface.State.disabled, iface.state());
        try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
        const frame = iface.poll().?.rx;
        try std.testing.expectEqualSlices(u8, &test_ack_request, frame.bytes);
        try std.testing.expect(!frame.ack_sent);
        if (operation != .idle) try expect_aborted_operation(iface, operation);
        try std.testing.expect(iface.poll() == null);
    }
}

fn expect_phyend_masked() void {
    std.debug.assert(radio.INTENSET.read().PHYEND != .Enabled);
    std.debug.assert(radio.EVENTS_PHYEND.raw != 0);
}

const RevocationSource = enum { rx_end, unowned_rx_end, ed_end, tx_phyend, ack_phyend, cca_busy };

fn revocation_injector(comptime source: RevocationSource) *const fn () void {
    return struct {
        fn inject() void {
            std.debug.assert(microzig.fx.mask_depth != 0);
            switch (source) {
                .rx_end => microzig.Fixture.raise(&radio.EVENTS_END),
                .unowned_rx_end => microzig.Fixture.inject_unexpected_end(),
                .ed_end => microzig.Fixture.raise(&radio.EVENTS_EDEND),
                .tx_phyend, .ack_phyend => microzig.Fixture.raise(&radio.EVENTS_PHYEND),
                .cca_busy => microzig.Fixture.raise(&radio.EVENTS_CCABUSY),
            }
            if (microzig.fx.shortcut_disable_pending)
                microzig.fx.on_radio_state_read = microzig.Fixture.complete_shortcut;
        }
    }.inject;
}

test "revocation uses radio state for every disabling shortcut" {
    inline for (std.enums.values(RevocationSource)) |source| {
        for ([_]enum { before_sample, during_write, after_write }{
            .before_sample, .during_write, .after_write,
        }) |position| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            switch (source) {
                .rx_end, .unowned_rx_end, .ack_phyend => {
                    try iface.receive(25);
                    microzig.Fixture.dispatch_ready_rx();
                    if (source == .ack_phyend) {
                        try start_test_immediate_ack(iface, &self, .idle);
                    } else if (source == .rx_end) {
                        microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
                        try std.testing.expect(service_test_radio());
                    }
                },
                .ed_end => {
                    try iface.energy_scan(25, 128);
                    microzig.Fixture.dispatch_ready_rx();
                },
                .tx_phyend => try start_test_tx(iface),
                .cca_busy => {
                    try iface.cca();
                    microzig.Fixture.dispatch_ready_rx();
                },
            }

            const disables = microzig.fx.disables;
            const completions = microzig.fx.disable_completions;
            microzig.fx.defer_shortcut_disabled = position != .after_write;
            const inject = revocation_injector(source);
            switch (position) {
                .before_sample => microzig.fx.on_disabled_read = inject,
                .during_write => microzig.fx.before_shorts_write = inject,
                .after_write => microzig.fx.after_shorts_write = inject,
            }
            if (source == .unowned_rx_end) {
                try iface.energy_scan(25, 128);
            } else {
                try iface.sleep();
            }
            try std.testing.expect(microzig.fx.on_disabled_read == null);
            try std.testing.expect(microzig.fx.before_shorts_write == null);
            try std.testing.expect(microzig.fx.after_shorts_write == null);
            try std.testing.expect(microzig.fx.on_radio_state_read == null);
            try expect_radio_drained();
            try std.testing.expectEqual(completions + 1, microzig.fx.disable_completions);
            // During the SHORTS write, the driver's samples cannot prove
            // whether the shortcut fired. A redundant task is harmless.
            if (position != .during_write)
                try std.testing.expectEqual(disables + 1, microzig.fx.disables);
            microzig.fx.defer_shortcut_disabled = false;
            switch (source) {
                .rx_end => try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error),
                .unowned_rx_end => try complete_test_operation(iface, .ed),
                .ed_end => try expect_aborted_operation(iface, .ed),
                .tx_phyend => {
                    try std.testing.expect(iface.poll().? == .tx_started);
                    try expect_aborted_operation(iface, .tx);
                },
                .ack_phyend => try std.testing.expect(!iface.poll().?.rx.ack_sent),
                .cca_busy => try expect_aborted_operation(iface, .cca),
            }
            try expect_radio_drained();
            try std.testing.expectEqual(completions + 1 + @as(usize, if (source == .unowned_rx_end) 1 else 0), microzig.fx.disable_completions);
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "declined ACK at launch still charges a slot crossed during ACK setup" {
    for ([_]bool{ false, true }) |retained| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        const end = 900;
        const cutoff = end + phy.ack_txen_us - 4;
        try start_test_backoff(&self, iface, if (retained) 800 else cutoff);
        microzig.Fixture.advance(700);
        microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
        try std.testing.expect(service_test_radio());
        if (retained) {
            microzig.Fixture.advance(800);
            try std.testing.expect(service_test_timer());
            try std.testing.expectEqual(Phase.stopping, self.phase);
            self.backoff_tick = cutoff;
            self.arm_at(cutoff);
        }
        const busy = self.tx.backoffs;
        const writes = EnableWrites.snapshot();
        test_frame(&self, &test_ack_request);
        microzig.Fixture.advance(end);
        microzig.fx.tick_on_ack_compare_arm = cutoff;
        microzig.Fixture.raise(&radio.EVENTS_END);
        try std.testing.expect(service_test_radio());
        try std.testing.expect(microzig.fx.tick_on_ack_compare_arm == null);
        try std.testing.expectEqual(busy + 1, self.tx.backoffs);
        try std.testing.expect(self.phase != .auto_ack);
        try std.testing.expect(self.rx_replacement != null);
        try writes.expect_delta(0, 0);
        try std.testing.expect(service_test_radio());
        try writes.expect_delta(1, 0);
        try std.testing.expect(!iface.poll().?.rx.ack_sent);
        try std.testing.expect(iface.poll() == null);
    }
}

test "a hardware IRQ pended before foreground masks its source still dispatches once" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    try std.testing.expectEqual(Interface.State.receive, iface.state());
    try std.testing.expect(radio.INTENSET.read().ADDRESS != .Enabled);
    microzig.cpu.interrupt.disable(.RADIO);
    try std.testing.expect(!service_test_radio());
    microzig.cpu.interrupt.enable(.RADIO);
    try std.testing.expect(service_test_radio());
    try std.testing.expect(!service_test_radio());
    try std.testing.expect(iface.poll() == null);
}

test "DISABLE while already Disabled produces no completion edge" {
    var self: Radio = undefined;
    defer owner = null;
    _ = try init_test_radio(&self);
    std.debug.assert(radio.STATE.read().STATE == .Disabled);
    radio.TASKS_DISABLE.write_raw(1);
    try std.testing.expectEqual(@as(u32, 0), radio.EVENTS_DISABLED.raw);
    try std.testing.expect(!service_test_radio());
}

const MatrixClose = enum {
    configure_rx,
    policy_rx,
    configure_backoff,
    policy_backoff,
    slot,
    housekeeping,
    response,
    sender_ack,
    buffer_restore,
    tx,
    ed,
    cca,
    sleep,
    retune,
    disable,
    deinit,
    fault,

    fn backoff(row: MatrixClose) bool {
        return row == .configure_backoff or row == .policy_backoff or row == .slot;
    }

    fn p3(row: MatrixClose) bool {
        return switch (row) {
            .sleep, .retune, .disable, .deinit, .fault => true,
            else => false,
        };
    }

    fn operation(row: MatrixClose) Operation {
        return switch (row) {
            .tx, .slot, .configure_backoff, .policy_backoff, .sender_ack => .tx,
            .ed => .ed,
            .cca => .cca,
            else => .idle,
        };
    }
};

const MatrixAddress = enum { before, after, absent };
const MatrixEnd = enum { before_disabled, between_reads, after_address, absent };
const MatrixTiming = enum { normal, at_cutoff, timely_hidden };
const MatrixExclusion = enum { no_packet_arm, absent_address_control, distinct_stop_control };

fn matrix_exclusion(row: MatrixClose, address: MatrixAddress, end: MatrixEnd) ?MatrixExclusion {
    if (row == .buffer_restore) {
        return if (address == .absent and end == .absent) null else .no_packet_arm;
    }
    if (address == .absent) return .absent_address_control;
    if (address == .before and end == .absent) return .distinct_stop_control;
    return null;
}

fn reveal_matrix_address() void {
    std.debug.assert(microzig.Fixture.reveal_latch(&radio.EVENTS_ADDRESS));
}

fn reveal_matrix_end() void {
    std.debug.assert(microzig.Fixture.reveal_latch(&radio.EVENTS_END));
    const disabled = microzig.Fixture.reveal_latch(&radio.EVENTS_DISABLED);
    std.debug.assert(disabled == !microzig.fx.lose_disabled_event);
}

fn reveal_matrix_frame() void {
    reveal_matrix_address();
    reveal_matrix_end();
}

fn matrix_end_with_hidden_address() void {
    microzig.Fixture.hold_latch(&radio.EVENTS_ADDRESS);
    const completions = microzig.fx.disable_completions;
    inject_address_and_end();
    std.debug.assert(microzig.fx.disable_completions == completions + 1);
    std.debug.assert(radio.EVENTS_ADDRESS.raw == 0 and radio.EVENTS_END.raw != 0);
    std.debug.assert((radio.EVENTS_DISABLED.raw == 0) == microzig.fx.lose_disabled_event);
}

fn arm_matrix_injection(row: MatrixClose, address: MatrixAddress, end: MatrixEnd, timing: MatrixTiming) void {
    if (address == .absent) return;
    if (address == .after) {
        const show_end: *const fn () void = if (timing == .timely_hidden) reveal_matrix_end else matrix_end_with_hidden_address;
        switch (end) {
            .before_disabled => microzig.fx.on_disabled_read = show_end,
            .between_reads => microzig.fx.on_address_read = show_end,
            .after_address => microzig.fx.after_address_sample = inject_address_and_end,
            .absent => microzig.fx.after_address_sample = inject_close_address,
        }
        if (end == .before_disabled or end == .between_reads)
            microzig.fx.after_address_sample = reveal_matrix_address;
        return;
    }
    const address_only: *const fn () void = switch (row) {
        .sender_ack, .response => reveal_matrix_address,
        else => inject_close_address,
    };
    const address_and_end: *const fn () void = switch (row) {
        .sender_ack, .response => reveal_matrix_frame,
        .slot => if (end == .before_disabled) raise_test_end else inject_address_and_end,
        else => inject_address_and_end,
    };
    switch (end) {
        .before_disabled => microzig.fx.on_disabled_read = address_and_end,
        .between_reads => microzig.fx.on_address_read = address_and_end,
        .after_address => {
            microzig.fx.on_address_read = address_only;
            microzig.fx.after_address_sample = if (row == .sender_ack or row == .response) reveal_matrix_end else raise_test_end;
        },
        .absent => unreachable,
    }
}

fn invoke_matrix_close(row: MatrixClose, self: *Radio, iface: Interface, early: bool, lost: bool) !void {
    switch (row) {
        .configure_rx, .configure_backoff => {
            var config = self.rx_settings.current().config;
            config.rx_on_when_idle = false;
            try self.configure(config);
            try std.testing.expect(service_test_radio());
        },
        .policy_rx, .policy_backoff => {
            try iface.set_rx_on_when_idle(false);
            try std.testing.expect(service_test_radio());
        },
        .slot, .housekeeping, .response, .sender_ack, .fault => try std.testing.expect(service_test_timer()),
        .buffer_restore => {
            if (lost) {
                try std.testing.expect(Dispatch.poll(self, .preserve_fault) == null);
            } else {
                try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
            }
        },
        .tx, .ed, .cca => try submit_test_operation(iface, row.operation()),
        .sleep => {
            const result = iface.sleep();
            if (lost) try std.testing.expectError(error.Aborted, result) else try result;
        },
        .retune => {
            const result = iface.receive(11);
            if (lost) try std.testing.expectError(error.Aborted, result) else try result;
        },
        .disable => {
            const result = iface.disable();
            if (lost) try std.testing.expectError(error.HardwareFault, result) else try result;
        },
        .deinit => {
            const result = self.deinit();
            if (lost) {
                try std.testing.expectError(error.HardwareFault, result);
            } else if (early) {
                try std.testing.expectError(error.Busy, result);
            } else {
                try result;
            }
        },
    }
}

fn expect_matrix_continuation(row: MatrixClose, self: *Radio, early: bool, lost: bool) !void {
    const enabled = !lost and row != .disable and row != .deinit and row != .fault;
    try std.testing.expectEqual(enabled, self.enabled);
    try std.testing.expectEqual(if (row == .deinit and !lost and !early) null else self, owner);
    if (!enabled) {
        try std.testing.expectEqual(Phase.off, self.phase);
        try std.testing.expectEqual(Operation.idle, self.operation);
        try std.testing.expect(self.deadline == null and !self.housekeeping);
        try std.testing.expect(self.temp_deadline == null);
        try std.testing.expectEqual(@as(u8, if (row == .response) 11 else 25), self.rx_channel);
        return;
    }
    const phase: Phase = switch (row) {
        .configure_rx, .policy_rx, .sender_ack, .sleep => .off,
        .configure_backoff, .policy_backoff => .backoff,
        .slot => if (early) .backoff else .tx_cca,
        .housekeeping, .response, .buffer_restore, .retune => .rx,
        .tx => .tx,
        .ed => .ed,
        .cca => .cca,
        else => unreachable,
    };
    const channel: u8 = if (row == .response or row == .retune) 11 else 25;
    const operation = if (row == .sender_ack) Operation.idle else row.operation();
    try std.testing.expectEqual(operation, self.operation);
    try std.testing.expectEqual(phase, self.phase);
    try std.testing.expectEqual(channel_frequency(channel), radio.FREQUENCY.read().FREQUENCY);
    try std.testing.expectEqual(@as(?PollResponse, null), self.poll_response);
    const state: @TypeOf(radio.STATE.read().STATE) = switch (phase) {
        .off => .Disabled,
        .tx => .TxRu,
        .rx, .cca, .ed, .tx_cca => .RxRu,
        .backoff => if (row == .slot) .RxRu else .Disabled,
        else => unreachable,
    };
    try std.testing.expectEqual(state, radio.STATE.read().STATE);
    if (phase == .backoff) {
        if (row == .slot) {
            try std.testing.expectEqual(@as(u8, 1), self.tx.backoffs);
            try std.testing.expect(self.backoff_tick.? != 2000);
        } else {
            try std.testing.expectEqual(@as(?u32, 2000), self.backoff_tick);
            try std.testing.expect(!self.backoff_listening);
        }
        try std.testing.expectEqual(self.backoff_tick, self.deadline);
        try std.testing.expectEqual(self.deadline.?, timer.CC[deadline_cc].raw);
    } else {
        try std.testing.expect(self.backoff_tick == null and self.deadline == null);
    }
    try std.testing.expectEqual(phase == .rx, self.housekeeping);
    if (phase == .rx) {
        try std.testing.expect(self.rx_reserved);
        try std.testing.expectEqual(microzig.fx.tick +% (1 << 31), timer.CC[deadline_cc].raw);
        try std.testing.expect(timer.INTENSET.read().COMPARE1 == .Enabled);
    }
}

fn replay_matrix_close(row: MatrixClose, address: MatrixAddress, end: MatrixEnd, lost: bool, timing: MatrixTiming, ack_requested: bool) !void {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    if (row.backoff()) {
        try start_test_backoff(&self, iface, 2000);
    } else switch (row) {
        .response => {
            self.rx_channel = 11;
            self.record_receive();
            self.poll_response = .{ .channel = 25, .end_deadline = 2000 };
            self.begin_disabled(.rx);
            microzig.Fixture.dispatch_ready_rx();
        },
        .sender_ack => {
            try start_test_sender_ack(iface, &test_ack_request, false);
            microzig.Fixture.dispatch_ready_rx();
        },
        else => {
            if (row == .buffer_restore) {
                for (0..event_capacity) |_| self.enqueue(.{ .rx_error = .aborted });
            }
            if (row == .configure_rx or row == .policy_rx or row == .housekeeping) try iface.set_rx_on_when_idle(true);
            try iface.receive(25);
            microzig.Fixture.dispatch_ready_rx();
        },
    }
    var request = test_ack_request;
    request[2] = 0x85;
    const packet: []const u8 = if (row == .sender_ack) &.{ 0x02, 0, 1 } else if (ack_requested) &request else &test_unicast;
    test_frame(&self, packet);
    if (row.backoff()) _ = seed_test_backoff(&self);
    microzig.fx.timer_step = 0;
    const timed = row == .response or row == .sender_ack;
    const captured_early = timed and ((address == .before and timing == .normal) or timing == .timely_hidden);
    switch (row) {
        .slot, .housekeeping, .response, .sender_ack => {
            const cutoff = timer.CC[deadline_cc].raw;
            if (row == .slot and address == .before and end == .before_disabled) {
                microzig.Fixture.advance(cutoff -% 1);
                microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
                try std.testing.expect(service_test_radio());
                try std.testing.expect(self.address_established);
            }
            if (captured_early) {
                const saved_end = cutoff -% 1;
                const from_address = phy.sfd_to_frame_end_us(@intCast(packet.len + Interface.fcs_len)) + phy.rx_end_delay_us;
                const completions = microzig.fx.disable_completions;
                microzig.fx.lose_disabled_event = lost;
                microzig.Fixture.hold_latch(&radio.EVENTS_ADDRESS);
                microzig.Fixture.hold_latch(&radio.EVENTS_END);
                microzig.Fixture.hold_latch(&radio.EVENTS_DISABLED);
                microzig.Fixture.advance(saved_end -% from_address);
                microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
                microzig.Fixture.advance(saved_end);
                microzig.Fixture.raise(&radio.EVENTS_END);
                try std.testing.expectEqual(completions + 1, microzig.fx.disable_completions);
                try std.testing.expectEqual(@as(?u32, saved_end), microzig.fx.disable_completed_at);
                try std.testing.expectEqual(saved_end, timer.CC[tx_sfd_cc].raw);
                try std.testing.expectEqual(saved_end -% from_address, timer.CC[end_cc].raw);
                try std.testing.expect(radio.EVENTS_ADDRESS.raw == 0 and radio.EVENTS_END.raw == 0 and
                    radio.EVENTS_DISABLED.raw == 0);
            }
            microzig.Fixture.advance(cutoff);
        },
        .fault => {
            _ = iface.now_us();
            microzig.Fixture.set_rtc(self.progress_rtc +% 80);
            microzig.fx.rtc_step = 1;
            microzig.Fixture.raise(&timer.EVENTS_COMPARE[temperature_cc]);
        },
        else => {},
    }
    const early = address == .before and timing != .at_cutoff;
    const disabled_samples = microzig.fx.disabled_samples;
    const address_samples = microzig.fx.address_samples;
    const writes = EnableWrites.snapshot();
    microzig.fx.lose_disabled_event = lost;
    arm_matrix_injection(row, address, end, timing);
    // A timestamp at the timed cutoff is ineligible even at read (1).
    if (timing == .at_cutoff) microzig.fx.on_disabled_read = inject_address_and_end;

    const ack_sent = ack_requested and !lost;
    const completions_at_commit = microzig.fx.disable_completions;
    try invoke_matrix_close(row, &self, iface, early, lost);
    try expect_radio_drained();
    if (lost or row == .fault) try writes.expect_delta(0, 0);
    if (captured_early) {
        try std.testing.expectEqual(completions_at_commit, microzig.fx.disable_completions);
    }
    try std.testing.expectEqual(disabled_samples + 1, microzig.fx.disabled_samples);
    try std.testing.expectEqual(address_samples + @as(usize, if (row == .buffer_restore) 0 else 1), microzig.fx.address_samples);
    try std.testing.expect(microzig.fx.on_disabled_read == null);
    try std.testing.expect(microzig.fx.on_address_read == null);
    try std.testing.expect(microzig.fx.after_address_sample == null);

    if (ack_sent) {
        try std.testing.expectEqual(Phase.auto_ack, self.phase);
        try std.testing.expectEqual(packet[2], self.packet[3]);
        try start_test_ack_on_air(timer.CC[ack_launch_cc].raw -% phy.ack_txen_us);
        microzig.Fixture.raise(&radio.EVENTS_PHYEND);
        try std.testing.expect(service_test_radio());
    }

    if (self.rx_replacement != null) try std.testing.expect(service_test_radio());
    try expect_matrix_continuation(row, &self, early, lost);
    if (lost or row == .fault) {
        const expected: Interface.Fault = if (row == .fault)
            .{ .reason = .clock_stalled, .count = if (lost) 2 else 1 }
        else
            .{ .reason = .radio_timeout };
        try std.testing.expectEqual(expected, iface.poll().?.fault);
        try std.testing.expectEqual(Interface.State.disabled, iface.state());
    }
    if (early and row != .sender_ack) {
        const event = iface.poll().?;
        if (lost or row.p3()) {
            try std.testing.expectEqual(Interface.RxError.aborted, event.rx_error);
        } else {
            try std.testing.expectEqualSlices(u8, packet, event.rx.bytes);
            try std.testing.expectEqual(ack_sent, event.rx.ack_sent);
        }
    }

    const operation = row.operation();
    const clear_slot = row == .slot and !early and !lost;
    if (row == .sender_ack) {
        const done = iface.poll().?.tx_done;
        if (early and !lost) {
            try std.testing.expectEqual(Interface.TxStatus.acked, done.status);
            const ack = done.ack.?;
            try std.testing.expectEqualSlices(u8, packet, ack.bytes);
            try std.testing.expectEqual(@as(u8, 25), ack.channel);
            try std.testing.expect(ack.fcs_ok and ack.timestamp_us != null);
        } else {
            try std.testing.expectEqual(Interface.TxStatus.no_ack, done.status);
            try std.testing.expect(done.ack == null);
        }
    } else if (operation != .idle) {
        if (clear_slot) {
            try std.testing.expectEqual(@as(u8, 0), self.tx.backoffs);
            try std.testing.expectEqual(@as(usize, 0), microzig.fx.cca_starts);
            microzig.Fixture.dispatch_ready_rx();
            try std.testing.expectEqual(@as(usize, 1), microzig.fx.cca_starts);
            microzig.Fixture.raise(&radio.EVENTS_CCAIDLE);
            try complete_test_operation(iface, operation);
            try std.testing.expectEqual(@as(usize, 1), microzig.fx.cca_starts);
        } else if (lost or row.backoff()) {
            if (!lost) try iface.disable();
            try expect_aborted_operation(iface, operation);
        } else {
            try complete_test_operation(iface, operation);
        }
    } else if (row == .buffer_restore) {
        const queued = if (lost) event_capacity else event_capacity - 1;
        for (0..queued) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
        try expect_overrun(iface);
        try std.testing.expectEqual(!lost, self.rx_reserved);
    }
    const foreground_starts: usize = @intFromBool(row == .sender_ack or (row == .tx and !lost) or clear_slot);
    try std.testing.expectEqual(foreground_starts + @intFromBool(ack_sent), microzig.fx.tx_starts);
    try expect_radio_drained();
    try std.testing.expect(iface.poll() == null);
}

fn replay_matrix_fault_takeover(lost: bool) !void {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.set_rx_on_when_idle(true);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    microzig.fx.on_address_read = inject_close_address;
    try iface.energy_scan(25, 128);
    try std.testing.expect(self.close.?.owned);
    const disables = microzig.fx.disabled_samples;
    const addresses = microzig.fx.address_samples;
    microzig.fx.timer_step = 0;
    _ = iface.now_us();
    microzig.Fixture.set_rtc(self.progress_rtc +% 80);
    microzig.fx.rtc_step = 1;
    const writes = EnableWrites.snapshot();
    microzig.fx.lose_disabled_event = lost;
    microzig.Fixture.raise(&radio.EVENTS_END);
    microzig.Fixture.raise(&timer.EVENTS_COMPARE[temperature_cc]);
    try std.testing.expect(service_test_timer());
    try writes.expect_delta(0, 0);
    try std.testing.expectEqual(disables, microzig.fx.disabled_samples);
    try std.testing.expectEqual(addresses, microzig.fx.address_samples);
    try std.testing.expectEqual(Interface.Fault{
        .reason = .clock_stalled,
        .count = if (lost) 2 else 1,
    }, iface.poll().?.fault);
    try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    try expect_aborted_operation(iface, .ed);
    try std.testing.expect(iface.poll() == null);
    try std.testing.expect(!service_test_radio());
}

test "shared close boundary matrix keeps exactly one disposition across every close kind" {
    var excluded = std.EnumArray(MatrixExclusion, usize).initFill(0);
    for (std.enums.values(MatrixClose)) |row| {
        for (std.enums.values(MatrixAddress)) |address| {
            for (std.enums.values(MatrixEnd)) |end| {
                if (matrix_exclusion(row, address, end)) |reason| {
                    excluded.getPtr(reason).* += 1;
                    continue;
                }
                for ([_]bool{ false, true }) |lost| {
                    errdefer std.debug.print("close matrix {s} ADDRESS={s} END={s} loss={}\n", .{ @tagName(row), @tagName(address), @tagName(end), lost });
                    try replay_matrix_close(row, address, end, lost, .normal, false);
                    if (address == .before and !row.p3() and row != .sender_ack) {
                        try replay_matrix_close(row, address, end, lost, .normal, true);
                    }
                }
            }
        }
    }
    // Mark all inapplicable combinations explicitly, including buffer-missing
    // RX, which has neither an ADDRESS owner nor an END shortcut.
    try std.testing.expectEqual(@as(usize, 11), excluded.get(.no_packet_arm));
    try std.testing.expectEqual(@as(usize, 64), excluded.get(.absent_address_control));
    try std.testing.expectEqual(@as(usize, 16), excluded.get(.distinct_stop_control));
    for ([_]MatrixClose{ .response, .sender_ack }) |row| {
        for ([_]bool{ false, true }) |lost| {
            try replay_matrix_close(row, .before, .before_disabled, lost, .at_cutoff, false);
            for ([_]MatrixEnd{ .before_disabled, .between_reads }) |end| {
                try replay_matrix_close(row, .after, end, lost, .timely_hidden, false);
            }
        }
    }
    for ([_]bool{ false, true }) |lost| try replay_matrix_fault_takeover(lost);
}

fn lose_phyend_shortcut_on_revocation() void {
    microzig.Fixture.raise(&radio.EVENTS_PHYEND);
}

fn hide_end_shortcut_on_revocation() void {
    microzig.Fixture.hold_latch(&radio.EVENTS_END);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    microzig.Fixture.raise(&radio.EVENTS_END);
    std.debug.assert(radio.STATE.read().STATE == .Disabled);
    std.debug.assert(radio.EVENTS_END.raw == 0 and radio.EVENTS_DISABLED.raw == 0);
}

test "hidden END and lost DISABLED fault even after RX state reaches Disabled" {
    for ([_]Operation{ .tx, .ed, .cca, .idle }) |operation| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try iface.receive(25);
        microzig.Fixture.dispatch_ready_rx();
        test_frame(&self, &test_unicast);
        const rx_enables = microzig.fx.rxen_writes;
        const tx_enables = microzig.fx.txen_writes;
        const completions = microzig.fx.disable_completions;
        microzig.fx.lose_disabled_event = true;
        microzig.fx.before_shorts_write = hide_end_shortcut_on_revocation;
        if (operation == .idle) {
            try std.testing.expectError(error.Aborted, iface.sleep());
        } else {
            try submit_test_operation(iface, operation);
        }
        try std.testing.expect(microzig.fx.before_shorts_write == null);
        try std.testing.expectEqual(completions + 1, microzig.fx.disable_completions);
        try std.testing.expectEqual(rx_enables, microzig.fx.rxen_writes);
        try std.testing.expectEqual(tx_enables, microzig.fx.txen_writes);
        try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
        if (operation != .idle) try expect_aborted_operation(iface, operation);
        try std.testing.expect(iface.poll() == null);
        try std.testing.expectEqual(Interface.State.disabled, iface.state());
    }
}

fn hide_owned_end() void {
    microzig.Fixture.hold_latch(&radio.EVENTS_END);
    microzig.Fixture.raise(&radio.EVENTS_END);
    std.debug.assert(radio.EVENTS_END.raw == 0 and radio.EVENTS_DISABLED.raw == 0);
}

test "owned handoffs verify lost DISABLED at commitment or at the retained close deadline" {
    for ([_]Operation{ .tx, .ed, .cca }) |operation| {
        for ([_]bool{ true, false }) |at_commit| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            try iface.receive(25);
            microzig.Fixture.dispatch_ready_rx();
            test_frame(&self, &test_unicast);
            microzig.fx.timer_step = 0;
            const completions = microzig.fx.disable_completions;
            const rx_enables = microzig.fx.rxen_writes;
            const tx_enables = microzig.fx.txen_writes;
            const disabled_samples = microzig.fx.disabled_samples;
            const address_samples = microzig.fx.address_samples;
            microzig.fx.lose_disabled_event = true;
            microzig.fx.on_address_read = inject_close_address;
            if (at_commit) microzig.fx.after_address_sample = hide_owned_end;
            try submit_test_operation(iface, operation);

            if (!at_commit) {
                try std.testing.expect(self.close.?.owned);
                const watchdog = self.close.?.watchdog.?;
                try std.testing.expectEqual(microzig.fx.tick +% retained_close_us, watchdog);
                try std.testing.expect(timer.INTENSET.read().COMPARE0 == .Enabled);
                try expect_radio_drained();
                hide_owned_end();
                // Neither source can wake RADIO. The close timer was armed
                // while the frame was still on air.
                try std.testing.expect(!service_test_radio());
                microzig.Fixture.advance(watchdog -% 1);
                try std.testing.expect(!service_test_timer());
                microzig.Fixture.advance(watchdog);
                try std.testing.expect(service_test_timer());
            }
            try std.testing.expectEqual(completions + 1, microzig.fx.disable_completions);
            try std.testing.expectEqual(rx_enables, microzig.fx.rxen_writes);
            try std.testing.expectEqual(tx_enables, microzig.fx.txen_writes);
            try std.testing.expectEqual(disabled_samples + 1, microzig.fx.disabled_samples);
            try std.testing.expectEqual(address_samples + 1, microzig.fx.address_samples);
            try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
            try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
            try expect_aborted_operation(iface, operation);
            try std.testing.expect(iface.poll() == null);
            try std.testing.expectEqual(Interface.State.disabled, iface.state());
        }
    }
}

test "radio fixture ignores enable and START tasks during active RX" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    test_frame(&self, &test_unicast);
    const rx_enables = microzig.fx.rx_enables;
    const tx_enables = microzig.fx.tx_enables;
    const starts = microzig.fx.start;
    microzig.Fixture.inject_invalid_packet_tasks();
    try std.testing.expectEqual(rx_enables, microzig.fx.rx_enables);
    try std.testing.expectEqual(tx_enables, microzig.fx.tx_enables);
    try std.testing.expectEqual(starts, microzig.fx.start);
    try std.testing.expectEqual(.Rx, radio.STATE.read().STATE);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    microzig.Fixture.raise(&radio.EVENTS_END);
    try std.testing.expect(service_test_radio());
    try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
    try std.testing.expect(iface.poll() == null);
}

test "hidden ACK PHYEND and lost DISABLED fault after a PPI-launched ramp" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    const writes = EnableWrites.snapshot();
    try start_test_immediate_ack(iface, &self, .tx);
    microzig.fx.lose_disabled_event = true;
    microzig.Fixture.hold_latch(&radio.EVENTS_PHYEND);
    microzig.Fixture.raise(&radio.EVENTS_PHYEND);
    timer3.clear_compare(ack_launch_cc);
    try std.testing.expectEqual(.Disabled, radio.STATE.read().STATE);
    try std.testing.expect(radio.EVENTS_PHYEND.raw == 0 and radio.EVENTS_DISABLED.raw == 0);

    try std.testing.expectError(error.Aborted, iface.sleep());
    try writes.expect_delta(0, 1);
    try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
    try std.testing.expect(!iface.poll().?.rx.ack_sent);
    try expect_aborted_operation(iface, .tx);
    try std.testing.expect(iface.poll() == null);
}

fn match_revoked_ack_compare() void {
    const enabled = ack_launch.enabled();
    const enables = microzig.fx.tx_enables;
    microzig.Fixture.advance(timer.CC[ack_launch_cc].raw);
    std.debug.assert(timer3.compare_pending(ack_launch_cc));
    std.debug.assert(microzig.fx.tx_enables == enables + @intFromBool(enabled));
}

fn complete_revoked_ack_without_disabled() void {
    match_revoked_ack_compare();
    microzig.Fixture.raise(&radio.EVENTS_TXREADY);
    microzig.Fixture.hold_latch(&radio.EVENTS_PHYEND);
    microzig.fx.lose_disabled_event = true;
    microzig.Fixture.raise(&radio.EVENTS_PHYEND);
    timer3.clear_compare(ack_launch_cc);
    std.debug.assert(radio.EVENTS_TXREADY.raw != 0 and radio.EVENTS_PHYEND.raw == 0);
    std.debug.assert(radio.EVENTS_DISABLED.raw == 0);
}

test "Sleep quarantines a stuck ACK launch route without releasing its storage" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    _ = try arm_test_immediate_ack(iface, &self, .tx);
    try std.testing.expectEqual(.Disabled, radio.STATE.read().STATE);
    try std.testing.expect(ack_launch.enabled());
    const launch = timer.CC[ack_launch_cc].raw;
    const packet = self.packet[0..4].*;
    const writes = EnableWrites.snapshot();
    const packetptr = microzig.fx.packetptr_writes;
    microzig.fx.ppi_disable_stuck = @backingInt(ack_launch);

    try std.testing.expectError(error.Aborted, iface.sleep());
    try std.testing.expect(self.quarantined and ack_launch.enabled());
    try std.testing.expect(!microzig.fx.timer_running);
    try std.testing.expectEqual(@as(u32, 0), radio.POWER.raw);
    try std.testing.expectEqual(launch, timer.CC[ack_launch_cc].raw);
    try std.testing.expectEqual(packetptr, microzig.fx.packetptr_writes);
    try std.testing.expectEqual(packet, self.packet[0..4].*);
    microzig.Fixture.advance(launch +% 1);
    try writes.expect_delta(0, 0);
    try std.testing.expect(!service_test_radio() and !service_test_timer());
    try std.testing.expectEqual(Interface.Fault{ .reason = .producer_revocation }, iface.poll().?.fault);
    try std.testing.expect(!iface.poll().?.rx.ack_sent);
    try expect_aborted_operation(iface, .tx);
    try std.testing.expect(iface.poll() == null);
    try std.testing.expectError(error.HardwareFault, iface.enable());
    try std.testing.expectError(error.HardwareFault, self.deinit());
}

test "stuck capture routes preserve accepted RX through ACK setup failure" {
    for ([_]ppi.Channel{ tx_sfd_capture, end_capture }) |route| {
        for ([_]enum { ordinary, response, backoff, retained }{ .ordinary, .response, .backoff, .retained }) |origin| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            switch (origin) {
                .ordinary, .retained => {
                    try iface.set_rx_on_when_idle(true);
                    microzig.Fixture.dispatch_ready_rx();
                },
                .response => {
                    self.poll_response = .{ .channel = 25, .end_deadline = 2000 };
                    self.begin_disabled(.rx);
                    microzig.Fixture.dispatch_ready_rx();
                },
                .backoff => try start_test_backoff(&self, iface, 2000),
            }
            test_frame(&self, &test_ack_request);
            if (origin == .retained) {
                microzig.fx.on_address_read = inject_close_address;
                try iface.energy_scan(25, 128);
                try std.testing.expectEqual(Phase.stopping, self.phase);
            } else {
                microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            }
            microzig.Fixture.raise(&radio.EVENTS_END);
            const cc3 = timer.CC[tx_sfd_cc].raw;
            const cc4 = timer.CC[end_cc].raw;
            const writes = EnableWrites.snapshot();
            const packetptr = microzig.fx.packetptr_writes;
            microzig.fx.ppi_disable_stuck = @backingInt(route);

            try std.testing.expect(service_test_radio());
            try std.testing.expect(self.quarantined and route.enabled());
            try writes.expect_delta(0, 0);
            try std.testing.expectEqual(packetptr, microzig.fx.packetptr_writes);
            try std.testing.expectEqual(cc3, timer.CC[tx_sfd_cc].raw);
            try std.testing.expectEqual(cc4, timer.CC[end_cc].raw);
            try std.testing.expectEqual(Interface.Fault{ .reason = .producer_revocation }, iface.poll().?.fault);
            const frame = iface.poll().?.rx;
            try std.testing.expectEqualSlices(u8, &test_ack_request, frame.bytes);
            try std.testing.expect(frame.timestamp_us == null and !frame.ack_sent and !frame.acked_with_frame_pending);
            if (origin == .backoff) try expect_aborted_operation(iface, .tx);
            if (origin == .retained) try expect_aborted_operation(iface, .ed);
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "retained close does not reuse CC0 when capture revocation fails" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    const capture = timer.CC[ack_launch_cc].raw;
    const writes = EnableWrites.snapshot();
    microzig.fx.ppi_disable_stuck = @backingInt(ack_launch);
    microzig.fx.on_address_read = inject_close_address;
    try std.testing.expectError(error.Aborted, iface.energy_scan(25, 128));
    try std.testing.expect(self.quarantined);
    try std.testing.expectEqual(capture, timer.CC[ack_launch_cc].raw);
    try writes.expect_delta(0, 0);
    try std.testing.expectEqual(Interface.Fault{ .reason = .producer_revocation }, iface.poll().?.fault);
    try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    try std.testing.expect(iface.poll() == null);
}

test "TX start first observed in a failed completion dispatch is untimed" {
    for ([_]bool{ false, true }) |via_cca| {
        for ([_]bool{ false, true }) |address| {
            for ([_]bool{ false, true }) |lost_disabled| {
                var self: Radio = undefined;
                defer owner = null;
                const iface = try init_test_radio(&self);
                try iface.transmit(&.{ .bytes = &test_unicast, .channel = 25, .csma_ca = via_cca, .max_csma_backoffs = 0 });
                if (via_cca) {
                    microzig.Fixture.dispatch_ready_rx();
                    microzig.Fixture.raise(&radio.EVENTS_CCAIDLE);
                    try std.testing.expect(service_test_radio());
                }
                microzig.Fixture.raise(&radio.EVENTS_TXREADY);
                try std.testing.expect(service_test_radio());
                try std.testing.expectEqual(@as(usize, 1), microzig.fx.start);
                microzig.Fixture.advance(1000);
                if (address) microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
                microzig.Fixture.advance(1500);
                microzig.fx.lose_disabled_event = lost_disabled;
                if (!lost_disabled) microzig.fx.ppi_disable_stuck = @backingInt(tx_sfd_capture);
                const writes = EnableWrites.snapshot();
                microzig.Fixture.raise(&radio.EVENTS_PHYEND);
                try std.testing.expect(service_test_radio());
                try writes.expect_delta(0, 0);
                const reason: Interface.FaultReason = if (lost_disabled) .radio_timeout else .producer_revocation;
                try std.testing.expectEqual(Interface.Fault{ .reason = reason }, iface.poll().?.fault);
                try std.testing.expect(iface.poll().?.tx_started.timestamp_us == null);
                const terminal = iface.poll().?.tx_done;
                try std.testing.expect(terminal.status == .aborted and terminal.timestamp_us == null);
                try std.testing.expect(iface.poll() == null);
            }
        }
    }
}

fn complete_measurement_during_wait() void {
    const self = owner.?;
    std.debug.assert(self.measurement_result != null and self.queued == 0);
    const interrupts = radio.INTENSET.read();
    std.debug.assert(interrupts.EDEND != .Enabled and interrupts.CCAIDLE != .Enabled and interrupts.CCABUSY != .Enabled);
    std.debug.assert(radio.EVENTS_DISABLED.raw == 0);
    if (self.phase == .ed) radio.EDSAMPLE.write(.{ .EDLVL = replacement_ed_sample });
    microzig.Fixture.complete_shortcut();
}

fn defer_measurement_until_wait() void {
    microzig.fx.on_radio_state_read = complete_measurement_during_wait;
}

fn complete_tx_busy_during_wait() void {
    const self = owner.?;
    std.debug.assert(self.tx.backoffs == 1 and !self.measurement_result.?.cca);
    std.debug.assert(radio.INTENSET.read().CCABUSY != .Enabled);
    std.debug.assert(radio.EVENTS_DISABLED.raw == 0 and self.queued == 0);
    microzig.Fixture.advance(microzig.fx.jump_tick);
    microzig.Fixture.complete_shortcut();
}

fn defer_tx_busy_until_wait() void {
    microzig.fx.on_radio_state_read = complete_tx_busy_during_wait;
}

test "TX CCABUSY keeps its busy decision through delayed DISABLED" {
    for ([_]bool{ false, true }) |exhausted| {
        for ([_]bool{ false, true }) |timer_first| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            microzig.fx.timer_step = 0;
            _ = seed_test_backoff(&self);
            try iface.transmit(&.{
                .bytes = &test_unicast,
                .channel = 25,
                .max_csma_backoffs = if (exhausted) 0 else 1,
            });
            if (!exhausted) {
                try std.testing.expectEqual(Phase.backoff, self.phase);
                microzig.Fixture.advance(self.backoff_tick.?);
                try std.testing.expect(service_test_timer());
            }
            try std.testing.expectEqual(Phase.tx_cca, self.phase);
            microzig.Fixture.dispatch_ready_rx();
            try std.testing.expect(service_test_radio());
            try expect_radio_drained();

            // Predict a nonzero retry from the busy decision tick. The
            // wait advances time, so redrawing after DISABLED would differ.
            _ = seed_test_backoff(&self);
            var preview = self.random;
            const be = @min(self.tx.be + 1, self.rx_settings.current().config.max_be);
            const mask: u8 = @intCast((@as(u16, 1) << be) - 1);
            const delay = @as(u32, preview.random().int(u8) & mask) * backoff_us;
            try std.testing.expect(delay > 17);
            const decision_tick = microzig.fx.tick + 20;
            microzig.Fixture.advance(decision_tick);
            const retry_tick = decision_tick + delay;
            const completions = microzig.fx.disable_completions;
            const writes = EnableWrites.snapshot();
            microzig.fx.jump_tick = decision_tick + 17;
            microzig.fx.defer_shortcut_disabled = true;
            microzig.Fixture.raise(&radio.EVENTS_CCABUSY);
            microzig.fx.on_radio_state_read = defer_tx_busy_until_wait;

            const irq = @backingInt(microzig.cpu.Interrupt.RADIO);
            try std.testing.expect(microzig.fx.pending[irq]);
            if (timer_first) {
                microzig.cpu.interrupt.set_pending(.TIMER3);
                try std.testing.expect(service_test_timer());
            } else {
                _ = iface.now_us();
            }
            try std.testing.expect(microzig.fx.on_radio_state_read == null);
            try std.testing.expectEqual(decision_tick + 17, microzig.fx.disable_completed_at);
            try std.testing.expectEqual(completions + 1, microzig.fx.disable_completions);
            try std.testing.expectEqual(@as(u8, 1), self.tx.backoffs);
            try std.testing.expectEqual(@as(usize, @intFromBool(exhausted)), self.queued);

            try std.testing.expect(microzig.fx.pending[irq]);
            try std.testing.expect(service_test_radio());
            try std.testing.expect(!service_test_radio());
            try std.testing.expectEqual(completions + 1, microzig.fx.disable_completions);
            try std.testing.expectEqual(@as(u8, 1), self.tx.backoffs);
            try writes.expect_delta(0, 0);
            if (exhausted) {
                try std.testing.expect(self.backoff_tick == null and self.deadline == null);
                try std.testing.expectEqual(Interface.TxStatus.channel_access_failure, iface.poll().?.tx_done.status);
            } else {
                try std.testing.expectEqual(Phase.backoff, self.phase);
                try std.testing.expectEqual(@as(?u32, retry_tick), self.backoff_tick);
                try std.testing.expectEqual(@as(?u32, retry_tick), self.deadline);
                try std.testing.expectEqual(retry_tick, timer.CC[deadline_cc].raw);
            }
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "ED and standalone CCA resolve DISABLED within one bounded dispatch" {
    for ([_]enum { ed, clear, busy }{ .ed, .clear, .busy }) |source| {
        for ([_]bool{ false, true }) |timer_first| {
            for ([_]bool{ false, true }) |lost| {
                var self: Radio = undefined;
                defer owner = null;
                const iface = try init_test_radio(&self);
                if (source == .ed) try iface.energy_scan(25, 128) else try iface.cca();
                microzig.Fixture.dispatch_ready_rx();
                try std.testing.expect(service_test_radio());
                try expect_radio_drained();

                const writes = EnableWrites.snapshot();
                const completions = microzig.fx.disable_completions;
                microzig.fx.lose_disabled_event = lost;
                if (!lost) {
                    microzig.fx.defer_shortcut_disabled = true;
                    if (source == .clear) {
                        // The first STATE read precedes software DISABLE.
                        microzig.fx.on_disable = defer_measurement_until_wait;
                    } else {
                        // Skip the preliminary STATE read in quiescence.
                        microzig.fx.on_radio_state_read = defer_measurement_until_wait;
                    }
                }
                const expected_ed = level_dbm(correct_level(delayed_ed_sample, self.adjustment));
                switch (source) {
                    .ed => {
                        radio.EDSAMPLE.write(.{ .EDLVL = delayed_ed_sample });
                        microzig.Fixture.raise(&radio.EVENTS_EDEND);
                    },
                    .clear => microzig.Fixture.raise(&radio.EVENTS_CCAIDLE),
                    .busy => microzig.Fixture.raise(&radio.EVENTS_CCABUSY),
                }
                const radio_irq = @backingInt(microzig.cpu.Interrupt.RADIO);
                try std.testing.expect(microzig.fx.pending[radio_irq]);
                if (timer_first) {
                    microzig.cpu.interrupt.set_pending(.TIMER3);
                    try std.testing.expect(service_test_timer());
                } else {
                    _ = iface.now_us();
                }
                try writes.expect_delta(0, 0);
                try std.testing.expectEqual(completions + 1, microzig.fx.disable_completions);
                try std.testing.expect(microzig.fx.on_radio_state_read == null and microzig.fx.on_disable == null);
                try std.testing.expectEqual(@as(usize, 1), self.queued);
                // The originating RADIO vector was pending before settlement.
                // Successful settlement drains it harmlessly. Fault teardown
                // clears and isolates it before publication.
                try std.testing.expectEqual(!lost, microzig.fx.pending[radio_irq]);
                try std.testing.expectEqual(!lost, service_test_radio());
                try std.testing.expectEqual(@as(usize, 1), self.queued);
                if (lost) {
                    try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
                    try expect_aborted_operation(iface, if (source == .ed) .ed else .cca);
                } else if (source == .ed) {
                    try std.testing.expectEqual(@as(u8, replacement_ed_sample), radio.EDSAMPLE.read().EDLVL);
                    try std.testing.expectEqual(expected_ed, iface.poll().?.energy_scan_done);
                } else {
                    try std.testing.expectEqual(source == .clear, try iface.poll().?.cca_done);
                }
                try std.testing.expect(iface.poll() == null);
            }
        }
    }
}

test "normal TX and measurement terminals wait for verified retirement" {
    for ([_]enum { tx, busy_tx, sender_ack, ed, cca }{ .tx, .busy_tx, .sender_ack, .ed, .cca }) |kind| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        const route = switch (kind) {
            .tx, .busy_tx, .sender_ack => tx_sfd_capture,
            .ed, .cca => ack_launch,
        };
        switch (kind) {
            .tx => {
                try start_test_tx(iface);
                microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
                try std.testing.expect(service_test_radio());
                try std.testing.expect(iface.poll().? == .tx_started);
            },
            .busy_tx => {
                try iface.transmit(&.{ .bytes = &test_unicast, .channel = 25, .max_csma_backoffs = 0 });
                microzig.Fixture.dispatch_ready_rx();
            },
            .sender_ack => {
                try start_test_sender_ack(iface, &test_ack_request, false);
                microzig.Fixture.dispatch_ready_rx();
                test_frame(&self, &.{ 0x02, 0, test_ack_request[2] });
                microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            },
            .ed => {
                try iface.energy_scan(25, 128);
                microzig.Fixture.dispatch_ready_rx();
            },
            .cca => {
                try iface.cca();
                microzig.Fixture.dispatch_ready_rx();
            },
        }
        microzig.fx.ppi_disable_stuck = @backingInt(route);
        const writes = EnableWrites.snapshot();
        switch (kind) {
            .tx => microzig.Fixture.raise(&radio.EVENTS_PHYEND),
            .busy_tx => microzig.Fixture.raise(&radio.EVENTS_CCABUSY),
            .sender_ack => microzig.Fixture.raise(&radio.EVENTS_END),
            .ed => microzig.Fixture.raise(&radio.EVENTS_EDEND),
            .cca => microzig.Fixture.raise(&radio.EVENTS_CCAIDLE),
        }
        try std.testing.expect(service_test_radio());
        try writes.expect_delta(0, 0);
        try std.testing.expectEqual(Interface.Fault{ .reason = .producer_revocation }, iface.poll().?.fault);
        switch (kind) {
            .tx => try expect_aborted_operation(iface, .tx),
            .busy_tx => {
                const terminal = iface.poll().?.tx_done;
                try std.testing.expectEqual(Interface.TxStatus.channel_access_failure, terminal.status);
                try std.testing.expect(terminal.timestamp_us == null and terminal.ack == null);
            },
            .sender_ack => {
                const terminal = iface.poll().?.tx_done;
                try std.testing.expectEqual(Interface.TxStatus.no_ack, terminal.status);
                try std.testing.expect(terminal.ack == null);
            },
            .ed => try expect_aborted_operation(iface, .ed),
            .cca => try expect_aborted_operation(iface, .cca),
        }
        try std.testing.expect(iface.poll() == null);
    }
}

test "failed SHORTS readback prevents a stop from reporting success" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    const writes = EnableWrites.snapshot();
    microzig.fx.shorts_stuck = true;
    try std.testing.expectError(error.Aborted, iface.sleep());
    try writes.expect_delta(0, 0);
    try std.testing.expectEqual(@as(u32, 0), radio.POWER.raw);
    try std.testing.expectEqual(Interface.Fault{ .reason = .producer_revocation }, iface.poll().?.fault);
    try std.testing.expect(iface.poll() == null);
}

test "ACK PPI revocation distinguishes a canceled compare from a launched arm" {
    for ([_]enum { sleep, retune, disable, deinit, fault }{ .sleep, .retune, .disable, .deinit, .fault }) |stop| {
        for ([_]enum { before, after, lost }{ .before, .after, .lost }) |position| {
            errdefer std.debug.print("ACK revocation {s} {s}\n", .{ @tagName(stop), @tagName(position) });
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            try iface.receive(25);
            microzig.Fixture.dispatch_ready_rx();
            _ = try arm_test_immediate_ack(iface, &self, .idle);
            try std.testing.expectEqual(.Disabled, radio.STATE.read().STATE);
            try std.testing.expect(radio.EVENTS_RXREADY.raw == 0 and radio.EVENTS_READY.raw == 0);
            const writes = EnableWrites.snapshot();
            const disables = microzig.fx.disables;
            const completions = microzig.fx.disable_completions;
            switch (position) {
                .before => microzig.fx.before_ack_route_disable = match_revoked_ack_compare,
                .after => microzig.fx.after_ack_route_disable = match_revoked_ack_compare,
                .lost => microzig.fx.before_ack_route_disable = complete_revoked_ack_without_disabled,
            }
            const lost = position == .lost;
            switch (stop) {
                .sleep, .retune => {
                    const result = if (stop == .sleep) iface.sleep() else iface.receive(11);
                    if (lost) try std.testing.expectError(error.Aborted, result) else try result;
                },
                .disable => {
                    const result = iface.disable();
                    if (lost) try std.testing.expectError(error.HardwareFault, result) else try result;
                },
                .deinit => try std.testing.expectError(if (lost) error.HardwareFault else error.Busy, self.deinit()),
                .fault => {
                    microzig.Fixture.set_rtc(self.progress_rtc +% 80);
                    microzig.fx.rtc_step = 1;
                    microzig.Fixture.raise(&timer.EVENTS_COMPARE[temperature_cc]);
                    try std.testing.expect(service_test_timer());
                },
            }
            try std.testing.expect(microzig.fx.before_ack_route_disable == null and microzig.fx.after_ack_route_disable == null);
            try std.testing.expect(!timer3.compare_pending(ack_launch_cc));
            if (stop == .retune and !lost) {
                try std.testing.expectEqual(Phase.rx, self.phase);
                try std.testing.expectEqual(@intFromPtr(&radio.EVENTS_RXREADY), microzig.fx.routes[@backingInt(ack_launch)].event);
            } else {
                try std.testing.expect(!ack_launch.enabled());
            }
            try writes.expect_delta(@intFromBool(stop == .retune and !lost), @intFromBool(position != .after));
            try std.testing.expectEqual(disables + @intFromBool(position != .after), microzig.fx.disables);
            try std.testing.expectEqual(completions + @intFromBool(position != .after), microzig.fx.disable_completions);
            if (stop == .fault) {
                try std.testing.expectEqual(Interface.Fault{ .reason = .clock_stalled, .count = if (lost) 2 else 1 }, iface.poll().?.fault);
            } else if (lost) {
                try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
            }
            const frame = iface.poll().?.rx;
            try std.testing.expectEqualSlices(u8, &test_ack_request, frame.bytes);
            try std.testing.expect(!frame.ack_sent);
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "shortcut completion lost during revocation does not issue another DISABLE" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try start_test_tx(iface);
    const writes = EnableWrites.snapshot();
    microzig.fx.lose_disabled_event = true;
    microzig.fx.before_shorts_write = lose_phyend_shortcut_on_revocation;
    const disables = microzig.fx.disables;
    try std.testing.expectError(error.Aborted, iface.sleep());
    try writes.expect_delta(0, 0);
    try std.testing.expectEqual(disables + 1, microzig.fx.disables);
    try std.testing.expectEqual(Interface.Fault{ .reason = .radio_timeout }, iface.poll().?.fault);
    try std.testing.expect(iface.poll().? == .tx_started);
    try expect_aborted_operation(iface, .tx);
    try std.testing.expect(iface.poll() == null);
}

test "capture reads advance hardware compares and launch a pending ACK" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    const end = 600;
    const launch = end + phy.ack_txen_us;
    self.poll_response = .{ .channel = 25, .end_deadline = launch };
    self.begin_disabled(.rx);
    microzig.Fixture.dispatch_ready_rx();
    test_frame(&self, &test_ack_request);
    microzig.fx.timer_step = 0;
    microzig.Fixture.advance(200);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    try std.testing.expect(service_test_radio());
    microzig.Fixture.advance(end);
    microzig.Fixture.raise(&radio.EVENTS_END);
    try std.testing.expect(service_test_radio());
    try std.testing.expectEqual(Phase.auto_ack, self.phase);
    self.temp_deadline = launch;
    self.program_compare(temperature_cc, launch);

    microzig.Fixture.advance(launch - 1);
    try std.testing.expectEqual(@as(usize, 0), microzig.fx.tx_enables);
    microzig.fx.timer_step = 1;
    try std.testing.expectEqual(@as(u32, launch), Radio.counter_now());
    try std.testing.expectEqual(@as(usize, 1), microzig.fx.tx_enables);
    try std.testing.expect(timer3.compare_pending(ack_launch_cc));
    try std.testing.expect(timer3.compare_pending(deadline_cc));
    try std.testing.expect(timer3.compare_pending(temperature_cc));
    try std.testing.expect(microzig.fx.pending[@backingInt(microzig.cpu.Interrupt.TIMER3)]);
    microzig.fx.timer_step = 0;
    try std.testing.expect(service_test_timer());
    try std.testing.expect(self.poll_response == null);
    try std.testing.expectEqual(@as(?u32, launch + temperature_sample_us), self.temp_deadline);
    microzig.Fixture.raise(&radio.EVENTS_TXREADY);
    try std.testing.expectEqual(@as(usize, 1), microzig.fx.tx_starts);
    microzig.Fixture.raise(&radio.EVENTS_PHYEND);
    try std.testing.expect(service_test_radio());
    try std.testing.expect(iface.poll().?.rx.ack_sent);
    try std.testing.expect(iface.poll() == null);
}

test "END capture stays available through synchronous DISABLED wait or faults once" {
    for ([_]bool{ false, true }) |publish_capture| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try iface.receive(25);
        microzig.Fixture.dispatch_ready_rx();
        test_frame(&self, &test_unicast);
        microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
        try std.testing.expect(service_test_radio());
        microzig.fx.end_capture_stalls = true;
        microzig.fx.defer_shortcut_disabled = true;
        microzig.Fixture.raise(&radio.EVENTS_END);
        if (publish_capture) {
            microzig.fx.delayed_capture = .{
                .cc = tx_sfd_cc,
                .route = @backingInt(tx_sfd_capture),
                .tick = microzig.fx.tick,
            };
        }
        const completions = microzig.fx.disable_completions;
        microzig.fx.on_radio_state_read = complete_masked_rx;
        try std.testing.expect(service_test_radio());
        try std.testing.expectEqual(completions + 1, microzig.fx.disable_completions);
        try std.testing.expect(microzig.fx.on_radio_state_read == null and microzig.fx.delayed_capture == null);
        if (publish_capture) {
            try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
        } else {
            try std.testing.expectEqual(Interface.Fault{ .reason = .missing_capture }, iface.poll().?.fault);
            try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
        }
        try expect_radio_drained();
        try std.testing.expect(iface.poll() == null);
    }
}

test "missing CC4 during synchronous packet close preserves one RX abort" {
    for ([_]bool{ false, true }) |backoff| {
        for ([_]bool{ false, true }) |disabled_first| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            if (backoff) {
                try start_test_backoff(&self, iface, 2000);
            } else {
                try iface.receive(25);
                microzig.Fixture.dispatch_ready_rx();
            }
            test_frame(&self, &test_ack_request);
            microzig.fx.ack_capture_stalls = true;
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            try std.testing.expectEqual(self.capture_prime -% 1, timer.CC[end_cc].raw);
            if (disabled_first) {
                microzig.Fixture.hold_latch(&radio.EVENTS_END);
            } else {
                microzig.fx.defer_shortcut_disabled = true;
                microzig.fx.on_radio_state_read = complete_masked_rx;
            }
            microzig.Fixture.raise(&radio.EVENTS_END);
            try std.testing.expect(service_test_radio());
            try std.testing.expect(microzig.fx.on_radio_state_read == null);
            try std.testing.expectEqual(Interface.Fault{ .reason = .missing_capture }, iface.poll().?.fault);
            try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
            if (backoff) try expect_aborted_operation(iface, .tx);
            try std.testing.expect(iface.poll() == null);
            try std.testing.expect(!service_test_radio());
        }
    }
}

test "missing CC4 at retained-stop commitment preserves the owner from either RX origin" {
    for ([_]bool{ false, true }) |backoff| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        if (backoff) {
            try start_test_backoff(&self, iface, 2000);
        } else {
            try iface.set_rx_on_when_idle(true);
            microzig.Fixture.dispatch_ready_rx();
            try iface.set_rx_on_when_idle(false);
        }
        const rxen = microzig.fx.rxen_writes;
        const txen = microzig.fx.txen_writes;
        microzig.fx.ack_capture_stalls = true;
        microzig.fx.on_address_read = inject_close_address;
        if (backoff) {
            microzig.Fixture.advance(self.backoff_tick.?);
            try std.testing.expect(service_test_timer());
        } else {
            try std.testing.expect(service_test_radio());
        }
        try std.testing.expect(microzig.fx.on_address_read == null);
        try std.testing.expectEqual(rxen, microzig.fx.rxen_writes);
        try std.testing.expectEqual(txen, microzig.fx.txen_writes);
        try std.testing.expectEqual(Interface.Fault{ .reason = .missing_capture }, iface.poll().?.fault);
        try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
        if (backoff) try expect_aborted_operation(iface, .tx);
        try std.testing.expect(iface.poll() == null);
    }
}

test "timed RX cannot establish ownership from ADDRESS with missing CC4" {
    for ([_]bool{ false, true }) |sender_ack| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        if (sender_ack) {
            try start_test_sender_ack(iface, &test_ack_request, false);
            test_frame(&self, &.{ 0x02, 0, test_ack_request[2] });
        } else {
            self.poll_response = .{ .channel = 25, .end_deadline = 2000 };
            self.begin_disabled(.rx);
            test_frame(&self, &test_ack_request);
        }
        microzig.Fixture.dispatch_ready_rx();
        const rxen = microzig.fx.rxen_writes;
        const txen = microzig.fx.txen_writes;
        microzig.fx.ack_capture_stalls = true;
        microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
        microzig.Fixture.raise(&radio.EVENTS_END);
        try std.testing.expect(service_test_radio());
        try std.testing.expectEqual(rxen, microzig.fx.rxen_writes);
        try std.testing.expectEqual(txen, microzig.fx.txen_writes);
        try std.testing.expectEqual(Interface.Fault{ .reason = .missing_capture }, iface.poll().?.fault);
        if (sender_ack) {
            const terminal = iface.poll().?.tx_done;
            try std.testing.expectEqual(Interface.TxStatus.no_ack, terminal.status);
            try std.testing.expect(terminal.ack == null);
        }
        try std.testing.expect(iface.poll() == null);
    }
}

test "post-prologue CC4 failure aborts admission and RSSI without a diagnostic sample" {
    for ([_]Operation{ .tx, .ed, .cca, .idle }) |operation| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try iface.receive(25);
        microzig.Fixture.dispatch_ready_rx();
        const rxen = microzig.fx.rxen_writes;
        const txen = microzig.fx.txen_writes;
        const rssistart = microzig.fx.rssistart_writes;
        microzig.fx.ack_capture_stalls = true;
        microzig.fx.on_after_normal = inject_close_address;
        if (operation == .idle) {
            try std.testing.expectError(error.Aborted, iface.rssi());
        } else {
            try std.testing.expectError(error.Aborted, submit_test_operation(iface, operation));
        }
        try std.testing.expect(microzig.fx.on_after_normal == null);
        try std.testing.expectEqual(rxen, microzig.fx.rxen_writes);
        try std.testing.expectEqual(txen, microzig.fx.txen_writes);
        // Only the ADDRESS shortcut wrote RSSISTART.
        try std.testing.expectEqual(rssistart + 1, microzig.fx.rssistart_writes);
        try std.testing.expectEqual(Interface.Fault{ .reason = .missing_capture }, iface.poll().?.fault);
        try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
        try std.testing.expect(iface.poll() == null);
    }
}

test "missing RXREADY capture faults before diagnostic RSSISTART" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.fx.rxready_capture_stalls = true;
    microzig.Fixture.dispatch_ready_rx();
    try std.testing.expect(radio.EVENTS_RXREADY.raw != 0);
    try std.testing.expectEqual(self.capture_prime -% 1, timer.CC[ack_launch_cc].raw);
    try std.testing.expectError(error.Aborted, iface.rssi());
    try std.testing.expectEqual(@as(usize, 0), microzig.fx.rssistart_writes);
    try std.testing.expectEqual(Interface.Fault{ .reason = .missing_capture }, iface.poll().?.fault);
    try std.testing.expect(iface.poll() == null);
}

fn complete_old_policy_frame() void {
    std.debug.assert(owner.?.rx_settings.current().config.rx_on_when_idle);
    complete_masked_rx();
    microzig.fx.defer_shortcut_disabled = false;
}

test "fixture enable tasks cannot consume a pending CPU STATE hook" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    test_frame(&self, &test_unicast);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    microzig.fx.defer_shortcut_disabled = true;
    microzig.Fixture.raise(&radio.EVENTS_END);
    microzig.fx.on_radio_state_read = microzig.Fixture.complete_shortcut;
    const rx_enables = microzig.fx.rx_enables;
    const tx_enables = microzig.fx.tx_enables;
    const rxen_writes = microzig.fx.rxen_writes;
    const txen_writes = microzig.fx.txen_writes;
    microzig.Fixture.inject_replacement_enables();
    try std.testing.expect(microzig.fx.on_radio_state_read != null);
    try std.testing.expect(microzig.fx.shortcut_disable_pending);
    try std.testing.expectEqual(rx_enables, microzig.fx.rx_enables);
    try std.testing.expectEqual(tx_enables, microzig.fx.tx_enables);
    try std.testing.expectEqual(rxen_writes + 1, microzig.fx.rxen_writes);
    try std.testing.expectEqual(txen_writes + 1, microzig.fx.txen_writes);
    try std.testing.expect(service_test_radio());
    try std.testing.expect(microzig.fx.on_radio_state_read == null);
    try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
    try std.testing.expect(iface.poll() == null);
}

test "policy setters finish a pending END under the old settings before publishing" {
    for ([_]bool{ false, true }) |backoff| {
        for ([_]bool{ false, true }) |configure| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            if (backoff) {
                try start_test_backoff(&self, iface, 2000);
            } else {
                try iface.set_rx_on_when_idle(true);
                try iface.receive(25);
                microzig.Fixture.dispatch_ready_rx();
            }
            test_frame(&self, &test_unicast);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            try std.testing.expect(service_test_radio());
            microzig.fx.defer_shortcut_disabled = true;
            microzig.Fixture.raise(&radio.EVENTS_END);
            microzig.fx.on_radio_state_read = complete_old_policy_frame;
            if (configure) {
                var config = self.rx_settings.current().config;
                config.rx_on_when_idle = false;
                config.pan_id = 0x5678;
                try self.configure(config);
                try std.testing.expectEqual(@as(u16, 0x5678), self.rx_settings.current().config.pan_id);
            } else {
                try iface.set_rx_on_when_idle(false);
            }
            try std.testing.expect(microzig.fx.on_radio_state_read == null);
            try std.testing.expect(!self.rx_settings.current().config.rx_on_when_idle);
            try std.testing.expect(service_test_radio());
            try std.testing.expectEqual(if (backoff) Phase.backoff else .off, self.phase);
            try std.testing.expectEqual(@as(?u32, if (backoff) 2000 else null), self.deadline);
            try std.testing.expect(!self.backoff_listening);
            const frame = iface.poll().?.rx;
            try std.testing.expectEqualSlices(u8, &test_unicast, frame.bytes);
            try std.testing.expect(!frame.ack_sent);
            try expect_radio_drained();
            try std.testing.expect(iface.poll() == null);
        }
    }
}

const SameCallDeparture = enum { rx_end, ack_phyend };

// Leave a completed RX frame or immediate ACK latched and unserviced, so the
// next foreground call's NORMAL prologue performs the departure.
fn latch_test_departure(iface: Interface, self: *Radio, departure: SameCallDeparture) !void {
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    switch (departure) {
        .rx_end => {
            test_frame(self, &test_unicast);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            microzig.Fixture.raise(&radio.EVENTS_END);
        },
        .ack_phyend => {
            try start_test_immediate_ack(iface, self, .idle);
            microzig.Fixture.raise(&radio.EVENTS_PHYEND);
        },
    }
}

fn expect_test_departure_frame(iface: Interface, departure: SameCallDeparture) !void {
    const frame = iface.poll().?.rx;
    try std.testing.expectEqualSlices(u8, if (departure == .rx_end) &test_unicast else &test_ack_request, frame.bytes);
    try std.testing.expect(frame.timestamp_us != null);
    try std.testing.expectEqual(departure == .ack_phyend, frame.ack_sent);
}

test "TX, ED or CCA admitted in the departing call becomes the sole continuation" {
    for ([_]SameCallDeparture{ .rx_end, .ack_phyend }) |departure| {
        for ([_]Operation{ .tx, .ed, .cca }) |operation| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            try latch_test_departure(iface, &self, departure);
            const writes = EnableWrites.snapshot();
            try submit_test_operation(iface, operation);
            const next: Phase = switch (operation) {
                .tx => .tx,
                .ed => .ed,
                .cca => .cca,
                .idle => unreachable,
            };
            try std.testing.expectEqual(Phase.off, self.phase);
            try std.testing.expectEqual(next, self.rx_replacement.?);
            try std.testing.expect(self.close == null);
            try writes.expect_delta(0, 0);
            try expect_test_departure_frame(iface, departure);

            try std.testing.expect(service_test_radio());
            try std.testing.expect(self.rx_replacement == null);
            try std.testing.expectEqual(next, self.phase);
            try std.testing.expectEqual(operation, self.operation);
            try writes.expect_delta(@intFromBool(operation != .tx), @intFromBool(operation == .tx));
            switch (operation) {
                .tx => {
                    try std.testing.expectEqual(channel_frequency(25), radio.FREQUENCY.read().FREQUENCY);
                    microzig.Fixture.raise(&radio.EVENTS_TXREADY);
                    try std.testing.expect(service_test_radio());
                    try std.testing.expectEqual(Phase.tx, self.phase);
                    try std.testing.expectEqual(@as(usize, 1), microzig.fx.tx_starts - @intFromBool(departure == .ack_phyend));
                },
                .ed => try std.testing.expectEqual(@as(u32, self.ed_samples - 1), radio.EDCNT.read().EDCNT),
                .cca => try std.testing.expectEqual(channel_frequency(25), radio.FREQUENCY.read().FREQUENCY),
                .idle => unreachable,
            }
            try std.testing.expect(!iface.fault_pending().pending);
        }
    }
}

test "CSMA exhaustion in the admitting call keeps its replacement behind the unread terminal" {
    // An earned terminal holds its reservation until poll, so TERM_NONE
    // admission in the departing call is refused and cannot replace RX.
    for ([_]Operation{ .tx, .ed, .cca }) |operation| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        const slot = 2000;
        try start_test_backoff(&self, iface, slot);
        test_frame(&self, &test_unicast);
        microzig.Fixture.advance(900);
        microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
        try std.testing.expect(service_test_radio());
        self.tx.max_backoffs = self.tx.backoffs;
        microzig.Fixture.advance(1100);
        microzig.fx.jump_tick = slot;
        microzig.fx.on_backoff_departure = .{ .boundary = .published, .call = cross_slot_after_backoff_disposition };
        microzig.Fixture.raise(&radio.EVENTS_END);

        const writes = EnableWrites.snapshot();
        try std.testing.expectError(error.Busy, submit_test_operation(iface, operation));
        try std.testing.expect(microzig.fx.on_backoff_departure == null);
        try std.testing.expectEqual(Phase.off, self.phase);
        try std.testing.expectEqual(Phase.rx, self.rx_replacement.?);
        try std.testing.expectEqual(Operation.idle, self.operation);
        try std.testing.expect(self.close == null);
        try writes.expect_delta(0, 0);

        try std.testing.expect(service_test_radio());
        try std.testing.expectEqual(Phase.rx, self.phase);
        try writes.expect_delta(1, 0);
        try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
        try std.testing.expectEqual(Interface.TxStatus.channel_access_failure, iface.poll().?.tx_done.status);
        try std.testing.expect(iface.poll() == null);
        try submit_test_operation(iface, operation);
        try std.testing.expectEqual(operation, self.operation);
        try std.testing.expect(self.rx_replacement == null);
        try std.testing.expect(!iface.fault_pending().pending);
    }
}

test "receive or idle policy in the departing call steers the deferred replacement" {
    for ([_]SameCallDeparture{ .rx_end, .ack_phyend }) |departure| {
        for ([_]enum { renew, idle_on, idle_off }{ .renew, .idle_on, .idle_off }) |call| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            if (call == .idle_off) try iface.set_rx_on_when_idle(true);
            try latch_test_departure(iface, &self, departure);
            const writes = EnableWrites.snapshot();
            switch (call) {
                .renew => try iface.receive(25),
                .idle_on => try iface.set_rx_on_when_idle(true),
                .idle_off => try iface.set_rx_on_when_idle(false),
            }
            try std.testing.expectEqual(Phase.off, self.phase);
            try std.testing.expectEqual(Phase.rx, self.rx_replacement.?);
            try writes.expect_delta(0, 0);
            try expect_test_departure_frame(iface, departure);

            try std.testing.expect(service_test_radio());
            try std.testing.expect(self.rx_replacement == null);
            const listening = call != .idle_off;
            try std.testing.expectEqual(if (listening) Phase.rx else .off, self.phase);
            try std.testing.expectEqual(call == .renew, self.rx_request != null);
            try writes.expect_delta(@intFromBool(listening), 0);
            try std.testing.expect(!iface.fault_pending().pending);
        }
    }
}

test "operation behind a retained filtered frame launches in the pended dispatch" {
    for ([_]Operation{ .tx, .ed, .cca }) |operation| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try iface.receive(25);
        microzig.Fixture.dispatch_ready_rx();
        // Addressed to 0x0004, so the owned frame is filtered.
        test_frame(&self, &.{ 0x41, 0x88, 1, 0x34, 0x12, 4, 0, 1, 0 });
        microzig.fx.on_address_read = inject_close_address;
        try submit_test_operation(iface, operation);
        try std.testing.expect(self.close.?.owned and self.stopping_rx != null);
        const next: Phase = switch (operation) {
            .tx => .tx,
            .ed => .ed,
            .cca => .cca,
            .idle => unreachable,
        };
        microzig.fx.timer_step = 0;
        microzig.fx.defer_shortcut_disabled = true;
        microzig.Fixture.raise(&radio.EVENTS_END);
        microzig.fx.on_radio_state_read = complete_masked_rx;
        const writes = EnableWrites.snapshot();
        try std.testing.expect(service_test_radio());
        try std.testing.expect(microzig.fx.on_radio_state_read == null);
        microzig.fx.defer_shortcut_disabled = false;
        try writes.expect_delta(0, 0);
        try std.testing.expectEqual(Phase.off, self.phase);
        try std.testing.expectEqual(next, self.rx_replacement.?);
        try std.testing.expect(iface.poll() == null);
        try std.testing.expect(service_test_radio());
        try std.testing.expect(self.rx_replacement == null);
        try std.testing.expectEqual(next, self.phase);
        try std.testing.expectEqual(operation, self.operation);
        try writes.expect_delta(@intFromBool(operation != .tx), @intFromBool(operation == .tx));
        try std.testing.expect(!iface.fault_pending().pending);
        try std.testing.expect(iface.poll() == null);
    }
}

const RxIntent = enum { idle_policy, one_shot };
// The sender departures complete a TX under idle policy: a matching or
// mismatched ACK ends ACK RX, or CSMA exhausts on a backoff RX END.
const IntentDeparture = enum { accepted, filtered, ack, sender_acked, sender_no_ack, backoff_exhausted };

const rx_departures = [_]IntentDeparture{ .accepted, .filtered, .ack };

fn intent_departures(intent: RxIntent) []const IntentDeparture {
    return switch (intent) {
        .idle_policy => &(rx_departures ++ [_]IntentDeparture{ .sender_acked, .sender_no_ack, .backoff_exhausted }),
        .one_shot => &rx_departures,
    };
}

// Addressed to 0x0004, so the frame is filtered.
const test_filtered = [_]u8{ 0x41, 0x88, 1, 0x34, 0x12, 4, 0, 1, 0 };

// Leave a completed frame, immediate ACK or sender ACK latched and
// unserviced on RX armed by idle policy or by a one-shot receive with idle
// policy off.
fn latch_intent_departure(iface: Interface, self: *Radio, intent: RxIntent, departure: IntentDeparture) !void {
    switch (departure) {
        .sender_acked, .sender_no_ack => {
            std.debug.assert(intent == .idle_policy);
            try iface.set_rx_on_when_idle(true);
            try iface.sleep();
            try start_test_sender_ack(iface, &test_ack_request, false);
            try std.testing.expectEqual(Phase.ack_rx, self.phase);
            microzig.Fixture.dispatch_ready_rx();
            // Sequence 1 matches the request; sequence 2 does not.
            test_frame(self, &.{ 0x02, 0, if (departure == .sender_acked) 1 else 2 });
            microzig.Fixture.advance(1400);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            try std.testing.expect(service_test_radio());
            microzig.Fixture.advance(1600);
            microzig.Fixture.raise(&radio.EVENTS_END);
            return;
        },
        .backoff_exhausted => {
            std.debug.assert(intent == .idle_policy);
            const slot = 2000;
            try start_test_backoff(self, iface, slot);
            test_frame(self, &test_unicast);
            microzig.Fixture.advance(900);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            try std.testing.expect(service_test_radio());
            self.tx.max_backoffs = self.tx.backoffs;
            microzig.Fixture.advance(1100);
            microzig.fx.jump_tick = slot;
            microzig.fx.on_backoff_departure = .{ .boundary = .published, .call = cross_slot_after_backoff_disposition };
            microzig.Fixture.raise(&radio.EVENTS_END);
            return;
        },
        .accepted, .filtered, .ack => {},
    }
    switch (intent) {
        .idle_policy => try iface.set_rx_on_when_idle(true),
        .one_shot => try iface.receive(25),
    }
    microzig.Fixture.dispatch_ready_rx();
    switch (departure) {
        .accepted, .filtered => {
            test_frame(self, if (departure == .filtered) &test_filtered else &test_unicast);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            microzig.Fixture.raise(&radio.EVENTS_END);
        },
        .ack => {
            try start_test_immediate_ack(iface, self, .idle);
            microzig.Fixture.raise(&radio.EVENTS_PHYEND);
        },
        .sender_acked, .sender_no_ack, .backoff_exhausted => unreachable,
    }
}

// Idle policy keeps RX after any frame. An accepted one-shot frame
// consumes its request, so nothing will listen after the departure.
fn intent_listens(intent: RxIntent, departure: IntentDeparture) bool {
    return intent == .idle_policy or departure == .filtered;
}

fn expect_intent_departure_frame(iface: Interface, departure: IntentDeparture) !void {
    switch (departure) {
        .filtered => {},
        .accepted, .ack => {
            const frame = iface.poll().?.rx;
            try std.testing.expectEqualSlices(u8, if (departure == .accepted) &test_unicast else &test_ack_request, frame.bytes);
            try std.testing.expectEqual(departure == .ack, frame.ack_sent);
        },
        .sender_acked, .sender_no_ack => {
            const done = iface.poll().?.tx_done;
            try std.testing.expectEqual(if (departure == .sender_acked) Interface.TxStatus.acked else .no_ack, done.status);
        },
        .backoff_exhausted => {
            try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
            try std.testing.expectEqual(Interface.TxStatus.channel_access_failure, iface.poll().?.tx_done.status);
        },
    }
}

test "logical state in the departing call reports the saved RX replacement" {
    for ([_]RxIntent{ .idle_policy, .one_shot }) |intent| {
        for (intent_departures(intent)) |departure| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            try latch_intent_departure(iface, &self, intent, departure);
            const listens = intent_listens(intent, departure);
            const expected: Interface.State = if (listens) .receive else .sleep;
            const writes = EnableWrites.snapshot();
            try std.testing.expectEqual(expected, iface.state());
            try std.testing.expectEqual(Phase.off, self.phase);
            try std.testing.expectEqual(Phase.rx, self.rx_replacement.?);
            try writes.expect_delta(0, 0);

            try std.testing.expect(service_test_radio());
            try std.testing.expect(self.rx_replacement == null);
            try std.testing.expectEqual(if (listens) Phase.rx else .off, self.phase);
            try writes.expect_delta(@intFromBool(listens), 0);
            try std.testing.expectEqual(expected, iface.state());
            try expect_intent_departure_frame(iface, departure);
            try std.testing.expect(iface.poll() == null);
            try std.testing.expect(!iface.fault_pending().pending);
        }
    }
}

test "standalone CCA admitted in the departing call projects the saved RX replacement" {
    // A sender departure leaves its TX terminal unread, so its EventReservation
    // refuses CCA admission in that call with Busy.
    for ([_]RxIntent{ .idle_policy, .one_shot }) |intent| {
        for (rx_departures) |departure| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            try latch_intent_departure(iface, &self, intent, departure);
            const listens = intent_listens(intent, departure);
            const expected: Interface.State = if (listens) .receive else .sleep;
            const writes = EnableWrites.snapshot();
            try iface.cca();
            try std.testing.expectEqual(Phase.off, self.phase);
            try std.testing.expectEqual(Phase.cca, self.rx_replacement.?);
            try writes.expect_delta(0, 0);
            try std.testing.expectEqual(expected, self.cca_state);

            try std.testing.expect(service_test_radio());
            try std.testing.expectEqual(Phase.cca, self.phase);
            try writes.expect_delta(1, 0);
            try std.testing.expectEqual(expected, iface.state());
            try expect_intent_departure_frame(iface, departure);
            try complete_test_operation(iface, .cca);
            try std.testing.expectEqual(expected, iface.state());
            try std.testing.expectEqual(if (listens) Phase.rx else .off, self.phase);
            try std.testing.expect(!iface.fault_pending().pending);
        }
    }
}

fn reach_response_cutoff() void {
    microzig.Fixture.advance(2000);
}

test "admission at a due cutoff after a same-call departure leaves replacement setup pended" {
    for ([_]enum { receive, tx, ed, cca }{ .receive, .tx, .ed, .cca }) |entry| {
        for ([_]bool{ false, true }) |renew| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            self.rx_channel = 11;
            self.poll_response = .{ .channel = 25, .end_deadline = 2000 };
            self.begin_disabled(.rx);
            if (renew) try iface.receive(25);
            microzig.Fixture.dispatch_ready_rx();
            microzig.fx.timer_step = 0;
            test_frame(&self, &test_unicast);
            microzig.Fixture.advance(500);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            try std.testing.expect(service_test_radio());
            microzig.Fixture.advance(1500);
            microzig.Fixture.raise(&radio.EVENTS_END);
            // The entry's NORMAL prologue departs before the cutoff, and the
            // admission sample after it finds the cutoff due.
            microzig.fx.on_after_normal = reach_response_cutoff;
            const writes = EnableWrites.snapshot();
            switch (entry) {
                .receive => try iface.receive(25),
                .tx => try submit_test_operation(iface, .tx),
                .ed => try submit_test_operation(iface, .ed),
                .cca => try submit_test_operation(iface, .cca),
            }
            try std.testing.expect(microzig.fx.on_after_normal == null);
            const next: Phase = switch (entry) {
                .receive => .rx,
                .tx => .tx,
                .ed => .ed,
                .cca => .cca,
            };
            try std.testing.expectEqual(Phase.off, self.phase);
            try std.testing.expectEqual(next, self.rx_replacement.?);
            try writes.expect_delta(0, 0);
            try std.testing.expect(self.poll_response == null and self.deferred_channel == null);
            const promoted = renew or entry == .receive;
            try std.testing.expectEqual(@as(u8, if (promoted) 25 else 11), self.rx_channel);
            try std.testing.expectEqual(promoted, self.rx_request != null);
            if (entry == .cca) {
                try std.testing.expectEqual(@as(u8, if (renew) 25 else 11), self.measurement_channel);
                try std.testing.expectEqual(@as(Interface.State, if (renew) .receive else .sleep), self.cca_state);
            }

            try std.testing.expect(service_test_radio());
            try std.testing.expect(self.rx_replacement == null);
            try std.testing.expectEqual(next, self.phase);
            try writes.expect_delta(@intFromBool(entry != .tx), @intFromBool(entry == .tx));
            try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
            try std.testing.expect(!iface.fault_pending().pending);
        }
    }
}

const RenewalClose = enum { completes, radio_timeout, missing_capture };

fn finish_renewal_close() void {
    microzig.Fixture.raise(&radio.EVENTS_END);
}

fn stall_renewal_close() void {
    microzig.fx.disable_stalls = true;
    microzig.Fixture.raise(&radio.EVENTS_END);
}

fn lose_renewal_end_capture() void {
    microzig.fx.end_capture_stalls = true;
    microzig.Fixture.raise(&radio.EVENTS_END);
}

test "receive renewal records its request only when its own natural close succeeds" {
    for ([_]RenewalClose{ .completes, .radio_timeout, .missing_capture }) |outcome| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        self.rx_channel = 11;
        self.record_receive();
        const old_request = self.rx_request.?;
        self.poll_response = .{ .channel = 25, .end_deadline = 1000 };
        self.begin_disabled(.rx);
        microzig.Fixture.dispatch_ready_rx();
        test_frame(&self, &test_unicast);
        microzig.fx.timer_step = 0;
        microzig.Fixture.advance(999);
        microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
        microzig.Fixture.advance(1000);
        // Window expiry retains the pre-cutoff owner in natural stopping.
        try std.testing.expect(service_test_timer());
        try std.testing.expectEqual(Phase.stopping, self.phase);
        try std.testing.expectEqual(@as(u8, 25), self.stopping_rx.?.channel);
        try std.testing.expectEqual(old_request, self.rx_request.?);

        // A Receive on the retained channel renews through NORMAL, then the
        // retained frame finishes in the renewal's own handoff.
        microzig.fx.on_after_normal = switch (outcome) {
            .completes => finish_renewal_close,
            .radio_timeout => stall_renewal_close,
            .missing_capture => lose_renewal_end_capture,
        };
        if (outcome == .completes) {
            try iface.receive(25);
            try std.testing.expect(microzig.fx.on_after_normal == null);
            try std.testing.expectEqual(@as(u8, 25), self.rx_channel);
            const renewed = self.rx_request.?;
            try std.testing.expect(renewed != old_request);
            try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
            try std.testing.expect(service_test_radio());
            try std.testing.expectEqual(Phase.rx, self.phase);
            try std.testing.expectEqual(renewed, self.arm_request.?);
            try std.testing.expectEqual(channel_frequency(25), radio.FREQUENCY.read().FREQUENCY);
            try std.testing.expect(iface.poll() == null);
            continue;
        }
        try std.testing.expectError(error.Aborted, iface.receive(25));
        try std.testing.expect(microzig.fx.on_after_normal == null);
        try std.testing.expectEqual(Interface.State.disabled, iface.state());
        // Close fault return: the failed renewal records no request and no
        // channel, and Fault transition retired the old request.
        try std.testing.expect(self.rx_request == null);
        try std.testing.expectEqual(@as(u8, 11), self.rx_channel);
        const reason: Interface.FaultReason = if (outcome == .radio_timeout) .radio_timeout else .missing_capture;
        try std.testing.expectEqual(Interface.Fault{ .reason = reason }, iface.poll().?.fault);
        try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
        try std.testing.expect(iface.poll() == null);
        microzig.fx.disable_stalls = false;
        microzig.fx.end_capture_stalls = false;
        microzig.fx.timer_step = 1;
        try iface.enable();
        try std.testing.expectEqual(channel_frequency(11), radio.FREQUENCY.read().FREQUENCY);
        try std.testing.expectEqual(Interface.State.sleep, iface.state());
    }
}

fn cross_response_cutoff() void {
    microzig.Fixture.advance(1000);
}

test "diagnostic RSSI after a response cutoff never samples the retired arm" {
    for ([_]bool{ false, true }) |after_prologue| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        self.rx_channel = 11;
        self.poll_response = .{ .channel = 25, .end_deadline = 1000 };
        self.begin_disabled(.rx);
        // A deferred renewal on the window channel: the replacement arm
        // listens on the same channel as the retired one.
        try iface.receive(25);
        microzig.fx.timer_step = 0;
        microzig.Fixture.advance(40);
        microzig.Fixture.dispatch_ready_rx();
        microzig.Fixture.advance(100);
        test_frame(&self, &test_unicast);
        try std.testing.expectEqual(@as(i8, -50 - self.adjustment), try iface.rssi());
        try std.testing.expect(self.rx_settled);

        const rssistart = microzig.fx.rssistart_writes;
        if (after_prologue) {
            // The cutoff passes after the NORMAL prologue and before sampling.
            microzig.fx.on_after_normal = cross_response_cutoff;
            try std.testing.expectError(error.InvalidState, iface.rssi());
            try std.testing.expect(microzig.fx.on_after_normal == null);
            try std.testing.expectEqual(rssistart, microzig.fx.rssistart_writes);
            try std.testing.expect(service_test_timer());
        } else {
            microzig.Fixture.advance(1000);
            try std.testing.expectError(error.InvalidState, iface.rssi());
        }
        try std.testing.expectEqual(rssistart, microzig.fx.rssistart_writes);
        try std.testing.expect(self.poll_response == null);
        try std.testing.expectEqual(@as(u8, 25), self.rx_channel);
        try std.testing.expect(self.rx_request != null);
        try std.testing.expectEqual(.RxRu, radio.STATE.read().STATE);

        // The replacement on the same channel proves its own RX settle.
        microzig.Fixture.dispatch_ready_rx();
        try std.testing.expectError(error.InvalidState, iface.rssi());
        try std.testing.expectEqual(rssistart, microzig.fx.rssistart_writes);
        microzig.Fixture.advance(1016);
        try std.testing.expectEqual(@as(i8, -50 - self.adjustment), try iface.rssi());
        try std.testing.expectEqual(rssistart + 1, microzig.fx.rssistart_writes);
        try std.testing.expect(iface.poll() == null);
    }
}

const UnexpectedTxDisabled = enum { tx_ramp, tx_launched, tx_cca_assessing, tx_cca_ramp, tx_cca_launched, late_phyend };

fn deliver_late_phyend() void {
    timer.CC[end_cc].raw = microzig.fx.tick;
    microzig.Fixture.inject_latch_only(&radio.EVENTS_PHYEND);
}

test "unexpected DISABLED in either TX phase takes TX attempt completion" {
    for ([_]UnexpectedTxDisabled{ .tx_ramp, .tx_launched, .tx_cca_assessing, .tx_cca_ramp, .tx_cca_launched, .late_phyend }) |case| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        const cca = switch (case) {
            .tx_cca_assessing, .tx_cca_ramp, .tx_cca_launched => true,
            else => false,
        };
        // Zero backoffs enter tx_cca directly.
        try iface.transmit(&.{ .bytes = &test_unicast, .channel = 25, .csma_ca = cca, .max_csma_backoffs = 0 });
        try std.testing.expectEqual(if (cca) Phase.tx_cca else Phase.tx, self.phase);
        if (cca and case != .tx_cca_assessing) {
            microzig.Fixture.dispatch_ready_rx();
            microzig.Fixture.raise(&radio.EVENTS_CCAIDLE);
            try std.testing.expect(service_test_radio());
            try std.testing.expectEqual(Measurement{ .cca = true }, self.measurement_result.?);
            try std.testing.expectEqual(.TxRu, radio.STATE.read().STATE);
        }
        const launch = switch (case) {
            .tx_launched, .tx_cca_launched, .late_phyend => true,
            else => false,
        };
        if (launch) {
            microzig.Fixture.raise(&radio.EVENTS_TXREADY);
            try std.testing.expect(service_test_radio());
            try std.testing.expect(self.tx_attempt.launched);
        }
        microzig.Fixture.inject_unexpected_disabled();
        if (case == .late_phyend) microzig.fx.on_phyend_read = deliver_late_phyend;
        try std.testing.expect(service_test_radio());
        if (case == .late_phyend) {
            // Completion evidence found by the bounded check takes the
            // normal completion branch.
            try std.testing.expect(microzig.fx.on_phyend_read == null);
            try std.testing.expect(iface.poll().?.tx_started.timestamp_us != null);
            try std.testing.expectEqual(Interface.TxStatus.sent, iface.poll().?.tx_done.status);
            try std.testing.expectEqual(Interface.State.sleep, iface.state());
            try std.testing.expect(!iface.fault_pending().pending);
        } else {
            // Without PHYEND, TX attempt completion (or, before the assessment
            // result, the measurement bounded check) enters Fault transition.
            const reason: Interface.FaultReason = if (case == .tx_cca_assessing) .radio_timeout else .unexpected_disabled;
            try std.testing.expectEqual(Interface.State.disabled, iface.state());
            try std.testing.expectEqual(Interface.Fault{ .reason = reason }, iface.poll().?.fault);
            try std.testing.expectEqual(Interface.TxStatus.aborted, iface.poll().?.tx_done.status);
        }
        try std.testing.expect(iface.poll() == null);
    }
}

test "diagnostic RSSI refuses a frame retained in natural stopping as Busy" {
    for ([_]bool{ false, true }) |backoff| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        if (backoff) {
            try start_test_backoff(&self, iface, 1000);
        } else {
            self.rx_channel = 11;
            self.poll_response = .{ .channel = 25, .end_deadline = 1000 };
            self.begin_disabled(.rx);
            microzig.Fixture.dispatch_ready_rx();
            microzig.fx.timer_step = 0;
        }
        test_frame(&self, &test_unicast);
        microzig.Fixture.advance(950);
        microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
        try std.testing.expect(service_test_radio());
        try std.testing.expect(self.address_established);
        // Response expiry or slot service retains the owner in natural stopping.
        microzig.Fixture.advance(1000);
        try std.testing.expect(service_test_timer());
        try std.testing.expectEqual(Phase.stopping, self.phase);
        try std.testing.expect(self.close.?.owned);
        try std.testing.expect(!self.packet_rx());

        const rssistart = microzig.fx.rssistart_writes;
        try std.testing.expectError(error.Busy, iface.rssi());
        try std.testing.expectEqual(rssistart, microzig.fx.rssistart_writes);
        try std.testing.expectEqual(Phase.stopping, self.phase);

        microzig.Fixture.advance(1400);
        microzig.Fixture.raise(&radio.EVENTS_END);
        try std.testing.expect(service_test_radio());
        try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
        try std.testing.expect(!iface.fault_pending().pending);
    }
}

test "an owned frame keeps the last FIFO slot its arm reserved" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    for (0..event_capacity - 1) |_| self.enqueue(.{ .rx_error = .aborted });
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    try std.testing.expect(self.rx_reserved);
    test_frame(&self, &test_unicast);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    try std.testing.expect(service_test_radio());
    // The ADDRESS preflight refuses every operation while the owner is live.
    for ([_]Operation{ .tx, .ed, .cca }) |operation|
        try std.testing.expectError(error.Busy, submit_test_operation(iface, operation));
    microzig.Fixture.advance(microzig.fx.tick + 400);
    microzig.Fixture.raise(&radio.EVENTS_END);
    try std.testing.expect(service_test_radio());
    try std.testing.expectEqual(event_capacity, self.queued);
    try std.testing.expectEqual(@as(u32, 0), self.overrun);
    for (0..event_capacity - 1) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    try std.testing.expectEqualSlices(u8, &test_unicast, iface.poll().?.rx.bytes);
    try std.testing.expect(iface.poll() == null);
}

test "an owned frame without its reserved slot faults and counts the lost abort" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    for (0..event_capacity - 1) |_| self.enqueue(.{ .rx_error = .aborted });
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    test_frame(&self, &test_unicast);
    microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
    try std.testing.expect(service_test_radio());
    // Break the invariant: an event takes the owner's slot.
    self.enqueue(.{ .rx_error = .window_ended });
    try std.testing.expectEqual(event_capacity, self.queued);
    microzig.Fixture.advance(microzig.fx.tick + 400);
    microzig.Fixture.raise(&radio.EVENTS_END);
    _ = service_test_radio();
    try std.testing.expect(!self.enabled and self.pending_rx == null);
    // Both detections fault: the frame at accept and its abort at enqueue.
    try std.testing.expectEqual(Interface.Fault{ .reason = .event_reservation, .count = 2 }, iface.poll().?.fault);
    for (0..event_capacity - 1) |_| try std.testing.expectEqual(Interface.RxError.aborted, iface.poll().?.rx_error);
    try std.testing.expectEqual(Interface.RxError.window_ended, iface.poll().?.rx_error);
    try std.testing.expectEqual(Interface.RxError.overrun, iface.poll().?.rx_error);
    try std.testing.expect(iface.poll() == null);
}

test "admission counts a reserved arm's slot when its owner appears at the commitment read" {
    for ([_]Operation{ .ed, .cca }) |operation| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        // One free slot: enough for the operation only if the arm's slot is not counted.
        for (0..event_capacity - 1) |_| self.enqueue(.{ .rx_error = .aborted });
        try iface.receive(25);
        microzig.Fixture.dispatch_ready_rx();
        try std.testing.expect(self.rx_reserved);
        test_frame(&self, &test_unicast);
        // The preflight sees no ADDRESS; it latches at the commitment read.
        microzig.fx.on_address_read = inject_close_address;
        defer microzig.fx.on_address_read = null;
        try std.testing.expectError(error.Busy, submit_test_operation(iface, operation));
        try std.testing.expectEqual(Operation.idle, self.operation);
    }
}

var retune_stop_retired: ?bool = null;

fn unstick_capture_route() void {
    microzig.fx.ppi_disable_stuck = null;
}

// Runs at the Mode stop's PACKETPTR clear, which follows a verified stop
// and arm retirement. Leave a capture route live and stuck for the
// re-arm's retirement only.
fn fail_retune_rearm() void {
    retune_stop_retired = !owner.?.rx_reserved and radio.STATE.read().STATE == .Disabled;
    microzig.fx.routes[@backingInt(tx_sfd_capture)].enabled = true;
    microzig.fx.ppi_disable_stuck = @backingInt(tx_sfd_capture);
    microzig.fx.before_shorts_write = unstick_capture_route;
}

test "receive retune keeps rx_channel when its Mode stop succeeds and the re-arm faults" {
    var self: Radio = undefined;
    defer owner = null;
    const iface = try init_test_radio(&self);
    try iface.receive(25);
    microzig.Fixture.dispatch_ready_rx();
    const old_request = self.rx_request.?;
    retune_stop_retired = null;
    microzig.fx.on_packetptr_clear = fail_retune_rearm;
    try std.testing.expectError(error.Aborted, iface.receive(26));
    try std.testing.expect(microzig.fx.on_packetptr_clear == null);
    try std.testing.expectEqual(@as(?bool, true), retune_stop_retired);
    try std.testing.expect(!self.quarantined);
    try std.testing.expectEqual(Interface.State.disabled, iface.state());
    // Close fault return: the failed retune records no request and no
    // channel, and Fault transition retired the old request.
    try std.testing.expect(self.rx_request == null);
    try std.testing.expect(self.next_request != old_request);
    try std.testing.expectEqual(@as(u8, 25), self.rx_channel);
    try std.testing.expectEqual(Interface.Fault{ .reason = .producer_revocation }, iface.poll().?.fault);
    try std.testing.expect(iface.poll() == null);
    try iface.enable();
    try std.testing.expectEqual(channel_frequency(25), radio.FREQUENCY.read().FREQUENCY);
    try std.testing.expectEqual(Interface.State.sleep, iface.state());
}

test "diagnostic RSSI ignores a latched sender ACK ADDRESS and refuses a retained candidate as Busy" {
    for ([_]Phase{ .ack_rx, .ack_drain }) |phase| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try start_test_sender_ack(iface, &test_ack_request, false);
        microzig.Fixture.dispatch_ready_rx();
        test_frame(&self, &.{ 0x02, 0, 1 });
        const cutoff = self.sender_ack_cutoff();
        // A pre-cutoff ADDRESS qualified by Sender ACK timing.
        microzig.Fixture.advance(cutoff -% 200);
        microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
        if (phase == .ack_drain) {
            try std.testing.expect(service_test_radio());
            microzig.Fixture.advance(cutoff);
            try std.testing.expect(service_test_timer());
        }
        try std.testing.expectEqual(phase, self.phase);
        try std.testing.expect(radio.EVENTS_ADDRESS.raw != 0);
        const close = self.close;
        const rssistart = microzig.fx.rssistart_writes;
        // ack_rx is ineligible before its latched ADDRESS is tested; the
        // candidate that cutoff retained in ack_drain is a committed owner.
        const expected = if (phase == .ack_rx) error.InvalidState else error.Busy;
        try std.testing.expectEqual(phase == .ack_drain, close != null and close.?.owned);
        try std.testing.expectError(expected, iface.rssi());
        try std.testing.expectEqual(phase, self.phase);
        try std.testing.expectEqual(close, self.close);
        try std.testing.expectEqual(rssistart, microzig.fx.rssistart_writes);
        try std.testing.expect(!iface.fault_pending().pending);
    }
}

const UnenabledHandle = enum { never_enabled, disabled, faulted, copy_of_owner, busy_init };

test "entries on a disabled owner or an unowned handle return InvalidState before channel or resolver work" {
    const config: Config = .{ .channel = 25, .rx_on_when_idle = false, .pan_id = 0x1234, .short_address = 3 };
    for ([_]UnenabledHandle{ .never_enabled, .disabled, .faulted, .copy_of_owner, .busy_init }) |how| {
        microzig.Fixture.reset();
        var self: Radio = undefined;
        defer owner = null;
        try self.init(config);
        var other: Radio = undefined;
        const handle: *Radio = switch (how) {
            .never_enabled, .disabled, .faulted => &self,
            .copy_of_owner, .busy_init => &other,
        };
        switch (how) {
            .never_enabled => {},
            .disabled => {
                const iface = self.ieee802154_radio();
                try iface.enable();
                try iface.receive(25);
                try iface.disable();
            },
            .faulted => {
                const iface = self.ieee802154_radio();
                try iface.enable();
                try iface.receive(25);
                microzig.Fixture.dispatch_ready_rx();
                microzig.fx.ack_capture_stalls = true;
                microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
                try std.testing.expect(service_test_radio());
                microzig.fx.ack_capture_stalls = false;
            },
            .copy_of_owner, .busy_init => {
                const iface = self.ieee802154_radio();
                try iface.enable();
                try iface.receive(25);
                microzig.Fixture.dispatch_ready_rx();
                // A by-value copy carries the owner's enabled flag and live
                // arm. Init returns Busy before writing its handle, so that
                // storage keeps whatever it held, here the same image.
                other = self;
                if (how == .busy_init) try std.testing.expectError(error.Busy, other.init(config));
                try std.testing.expect(other.enabled);
            },
        }
        const owner_phase = self.phase;
        const iface = handle.ieee802154_radio();
        try std.testing.expectEqual(Interface.State.disabled, iface.state());
        const captures = microzig.fx.capture_count;
        const rxen = microzig.fx.rxen_writes;
        const txen = microzig.fx.txen_writes;
        const disables = microzig.fx.disables;
        const frequency = microzig.fx.frequency_writes;
        const rssistart = microzig.fx.rssistart_writes;
        const sequence = handle.next_request;
        const request = handle.rx_request;
        // Invalid, matching and retune channels all stop at the guard.
        for ([_]u8{ 10, 25, 26 }) |channel|
            try std.testing.expectError(error.InvalidState, iface.receive(channel));
        try std.testing.expectError(error.InvalidState, iface.sleep());
        try std.testing.expectError(error.InvalidState, iface.transmit(&.{ .bytes = &test_unicast, .channel = 26, .csma_ca = false }));
        try std.testing.expectError(error.InvalidState, iface.energy_scan(11, 128));
        try std.testing.expectError(error.InvalidState, iface.cca());
        try std.testing.expectError(error.InvalidState, iface.rssi());
        try std.testing.expectEqual(captures, microzig.fx.capture_count);
        try std.testing.expectEqual(rxen, microzig.fx.rxen_writes);
        try std.testing.expectEqual(txen, microzig.fx.txen_writes);
        try std.testing.expectEqual(disables, microzig.fx.disables);
        try std.testing.expectEqual(frequency, microzig.fx.frequency_writes);
        try std.testing.expectEqual(rssistart, microzig.fx.rssistart_writes);
        try std.testing.expectEqual(sequence, handle.next_request);
        try std.testing.expectEqual(request, handle.rx_request);
        try std.testing.expectEqual(@as(u8, 25), handle.rx_channel);
        try std.testing.expectEqual(Interface.State.disabled, iface.state());
        // The installed owner keeps routing and its own phase.
        try std.testing.expectEqual(@as(?*Radio, &self), owner);
        try std.testing.expectEqual(owner_phase, self.phase);
    }
}

test "promiscuous RX delivers newer-version and reserved-type frames raw that filtered RX drops" {
    // Both are addressed to this node with AR set: a version 2 data frame
    // and a version 0 frame of reserved type 5.
    for ([_][]const u8{
        &.{ 0x61, 0xa8, 7, 0x34, 0x12, 3, 0, 1, 0 },
        &.{ 0x65, 0x88, 7, 0x34, 0x12, 3, 0, 1, 0 },
    }) |bytes| {
        for ([_]bool{ false, true }) |promiscuous| {
            var self: Radio = undefined;
            defer owner = null;
            const iface = try init_test_radio(&self);
            iface.set_promiscuous(promiscuous);
            try iface.receive(25);
            microzig.Fixture.dispatch_ready_rx();
            test_frame(&self, bytes);
            microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
            try std.testing.expect(service_test_radio());
            microzig.Fixture.advance(microzig.fx.tick + 400);
            microzig.Fixture.raise(&radio.EVENTS_END);
            try std.testing.expect(service_test_radio());
            try std.testing.expect(self.phase != .auto_ack);
            try std.testing.expect(!ack_launch.enabled());
            if (promiscuous) {
                const frame = iface.poll().?.rx;
                try std.testing.expectEqualSlices(u8, bytes, frame.bytes);
                try std.testing.expect(!frame.ack_sent);
            } else {
                // The rejected frame leaves the one-shot request pending.
                try std.testing.expect(self.rx_request != null);
            }
            try std.testing.expect(iface.poll() == null);
        }
    }
}

test "immediate ACK carries the received frame's sequence number" {
    for ([_]struct { frame: []const u8, fcf: u8 }{
        .{ .frame = &.{ 0x61, 0x88, 0xa5, 0x34, 0x12, 3, 0, 1, 0 }, .fcf = 0x02 },
        // A Data Request with source matching disabled gets Frame Pending.
        .{ .frame = &.{ 0x63, 0x88, 0x5a, 0x34, 0x12, 3, 0, 1, 0, 0x04 }, .fcf = 0x12 },
    }) |case| {
        var self: Radio = undefined;
        defer owner = null;
        const iface = try init_test_radio(&self);
        try iface.receive(25);
        microzig.Fixture.dispatch_ready_rx();
        test_frame(&self, case.frame);
        microzig.Fixture.raise(&radio.EVENTS_ADDRESS);
        try std.testing.expect(service_test_radio());
        microzig.fx.timer_step = 0;
        const end = microzig.fx.tick;
        microzig.Fixture.raise(&radio.EVENTS_END);
        try std.testing.expect(service_test_radio());
        try std.testing.expectEqual(Phase.auto_ack, self.phase);
        // IEEE 802.15.4-2006 §7.5.6.4.2: PHR, Frame Control, then the DSN
        // copied from the frame being acknowledged.
        try std.testing.expectEqualSlices(u8, &.{ 3 + Interface.fcs_len, case.fcf, 0x00, case.frame[2] }, self.packet[0..4]);
        try std.testing.expectEqual(@as(u32, @truncate(@intFromPtr(&self.packet))), radio.PACKETPTR.raw);
        try start_test_ack_on_air(end);
        microzig.Fixture.raise(&radio.EVENTS_PHYEND);
        try std.testing.expect(service_test_radio());
        const frame = iface.poll().?.rx;
        try std.testing.expectEqualSlices(u8, case.frame, frame.bytes);
        try std.testing.expect(frame.ack_sent);
        try std.testing.expectEqual(case.fcf == 0x12, frame.acked_with_frame_pending);
        try std.testing.expect(iface.poll() == null);
    }
}
