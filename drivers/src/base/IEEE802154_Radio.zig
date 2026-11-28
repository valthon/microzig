//!
//! An abstract IEEE 802.15.4 radio with runtime dispatch.
//!
//! This is the one seam between a chip's 2.4 GHz O-QPSK radio driver and everything built on
//! 802.15.4: a Thread or Zigbee stack running on the device, an OpenThread RCP (Spinel over
//! UART/USB) where the stack runs on a host, a coordinator or border-router radio, a sniffer,
//! or a test tool. Port HALs implement it (`hal.ieee802154.Radio.ieee802154_radio()`); stacks
//! and tools depend only on this file, never on port code.
//!
//! The shape follows OpenThread's radio platform API (`openthread/platform/radio.h`), because it
//! is the most demanding consumer and it is the one a Thread library will wrap one-to-one:
//! - operations are non-blocking: `receive`, `transmit` and `energy_scan` start work and return;
//!   results arrive as `Event`s through `poll`. The `notify` hook can coalesce several events
//!   into one wakeup, possibly from interrupt context. A woken consumer polls until null;
//! - each on-air TX attempt, including offloaded retries, queues a `tx_started` event with
//!   the end-of-SFD timestamp. An OpenThread adapter sets the frame's TX timestamp before
//!   calling `otPlatRadioTxStarted` for that attempt and uses `tx_done` for final completion;
//! - the driver owns the turnaround-critical work the CPU cannot do in time from an event loop:
//!   address filtering, immediate ACKs, frame-pending bits from the source-match
//!   table, CSMA-CA and retransmission (when its capabilities say so), timestamps;
//! - capabilities are reported, not assumed. A stack fills the gaps in software (OpenThread does
//!   CSMA, retries, ACK timeouts and TX security itself when the radio lacks them).
//!
//! Roles and what they rely on:
//! - end device / router / coordinator: addressing, auto-ACK, source match + frame pending,
//!   `set_pan_coordinator` (accept frames without a destination address), CSMA, energy scan;
//! - Thread CSL: timed TX/RX (`transmit_timing`, `receive_timing`).
//!   Enhanced ACK and TX security capability bits are reserved for future contracts.
//! - sniffer: `set_promiscuous(true)` (no filtering, no ACKs), `set_deliver_bad_fcs(true)`,
//!   `RxFrame.fcs` and `fcs_ok`, `timestamp_us`, per-frame `rssi`/`lqi`, `receive(channel)` to hop;
//! - RCP: all of the above, unchanged; the Spinel framing is a separate library.
//!
//! Frames are MAC frames (MHR + payload) WITHOUT the PHR and without the FCS, as in
//! OpenThread's `otRadioFrame.mPsdu` minus the FCS. The radio adds the FCS on TX.
//! Addresses and keys are in over-the-air (little-endian) octet order.
//!
//! The blocking wrappers use fault-preserving polling. At entry a disabled
//! radio returns `InvalidState` before consulting the radio clock, or
//! `Aborted` if a sticky fault is pending.
//!

const IEEE802154_Radio = @This();

/// Pointer to the object implementing the driver.
ptr: *anyopaque,

/// Virtual table for the radio functions.
vtable: *const VTable,

pub const max_psdu_len = 127;
pub const fcs_len = 2;
/// Largest MAC frame without FCS.
pub const max_frame_len = max_psdu_len - fcs_len;

pub const Capabilities = packed struct(u16) {
    /// `energy_scan` is implemented.
    energy_scan: bool = false,
    /// `TxRequest.csma_ca` with `max_csma_backoffs` runs CSMA-CA in the driver.
    csma_backoff: bool = false,
    /// `TxRequest.max_frame_retries` retransmits in the driver. Requires `ack_timeout`.
    transmit_retries: bool = false,
    /// The driver waits for and matches the ACK, reporting `no_ack` on timeout.
    /// When false, the stack owns the ACK deadline and matching. See `VTable.transmit`.
    ack_timeout: bool = false,
    /// `transmit` may be called from `sleep` (no explicit `receive` first).
    sleep_to_tx: bool = false,
    /// `set_rx_on_when_idle` is honoured.
    rx_on_when_idle: bool = false,
    /// Reserved for IEEE 802.15.4-2015 enhanced ACKs. Leave false until
    /// the first implementation defines the interface contract.
    enhanced_ack: bool = false,
    /// Reserved for TX security offload. Leave false until the first
    /// implementation defines the interface contract.
    transmit_security: bool = false,
    /// `TxRequest.tx_at_us` is honoured.
    transmit_timing: bool = false,
    /// `receive_at` is implemented.
    receive_timing: bool = false,
    /// Source-match table drives the frame-pending bit of ACKs.
    src_match: bool = false,
    /// `set_deliver_bad_fcs(true)` delivers frames whose FCS failed.
    bad_fcs_delivery: bool = false,
    _reserved: u4 = 0,
};

pub const AddressKind = enum { short, extended };

pub const Address = union(AddressKind) {
    short: u16,
    extended: [8]u8,
};

pub const State = enum { disabled, sleep, receive, transmit, energy_scan };

pub const RxFrame = struct {
    /// MAC frame without FCS. Valid until the next `poll`.
    bytes: []const u8,
    /// FCS as received, for sniffers.
    fcs: [fcs_len]u8,
    /// False only when `set_deliver_bad_fcs(true)`; such frames are never ACKed.
    fcs_ok: bool = true,
    channel: u8,
    /// dBm, measured during the frame.
    rssi: i8,
    /// 0..255.
    lqi: u8,
    /// End of SFD on the `now_us` clock. Null on the fault path.
    timestamp_us: ?u64,
    /// The driver sent an ACK for this frame.
    ack_sent: bool = false,
    /// That ACK had the frame-pending bit set.
    acked_with_frame_pending: bool = false,
};

pub const TxRequest = struct {
    /// MAC frame without FCS. The driver consumes or copies it before returning.
    /// This may alias frame bytes from the last poll if submitted before polling again.
    bytes: []const u8,
    channel: u8,
    /// Perform CCA (and CSMA backoff if `csma_backoff` is supported) before each attempt.
    csma_ca: bool = true,
    /// Zero selects one CCA with no random backoff per attempt.
    /// Ignored when `csma_ca` is false.
    max_csma_backoffs: u8 = 4,
    /// Retransmissions after a missing ACK (0 = one attempt).
    max_frame_retries: u8 = 3,
    /// Start TX so the end of SFD is at this `now_us` time (`transmit_timing`). No backoff.
    tx_at_us: ?u64 = null,
    /// dBm for this frame only; null uses the configured power.
    tx_power: ?i8 = null,
};

pub const TxStatus = enum {
    /// Sent without a driver-owned ACK wait.
    sent,
    /// Sent and a matching ACK was received.
    acked,
    /// ACK requested but none arrived after all retries.
    no_ack,
    /// CCA failed after all backoffs.
    channel_access_failure,
    /// Cancelled by a control call or by driver recovery.
    aborted,
    /// The hardware failed to complete an attempt.
    failed,
};

pub const TxStarted = struct {
    /// End of SFD on the `now_us` clock. Null on the fault path.
    timestamp_us: ?u64,
    /// One-based on-air attempt number within this TX request.
    attempt: u16,
};

pub const TxDone = struct {
    status: TxStatus,
    /// The received ACK frame, when `status == .acked`.
    /// Valid until the next `poll`.
    ack: ?RxFrame = null,
    /// End of SFD of the last on-air attempt on the `now_us` clock.
    /// Zero if no attempt reached the end of SFD. Null on the fault path.
    timestamp_us: ?u64,
};

pub const RxError = enum {
    /// A frame failed FCS (reported only if the driver counts these; never with the frame).
    fcs,
    /// Frames may have been lost: RX listened, or a received result was
    /// ready, with no event slot free.
    overrun,
    /// `receive_at` window ended with no frame.
    window_ended,
    /// An owned frame was aborted before delivery.
    aborted,
};

pub const FaultReason = enum {
    unexpected_disabled,
    radio_timeout,
    missing_capture,
    clock_stalled,
    radio_reset,
    timer_retirement,
    temp_retirement,
    rng_retirement,
    interrupt_isolation,
    producer_revocation,
    /// The driver found its event-slot accounting violated.
    event_reservation,
};

pub const Fault = struct {
    reason: FaultReason,
    count: u32 = 1,
};

pub const FaultPending = struct {
    pending: bool = false,
    reason: ?FaultReason = null,
    count: u32 = 0,
};

pub const Event = union(enum) {
    fault: Fault,
    rx: RxFrame,
    rx_error: RxError,
    /// Once per on-air attempt that reaches the end of SFD, including retries.
    tx_started: TxStarted,
    tx_done: TxDone,
    /// Highest RSSI seen during the scan, dBm.
    energy_scan_done: i8,
    energy_scan_failed: Error,
    /// True when the channel was clear.
    cca_done: Error!bool,
};

pub const Error = error{
    /// The capability needed for this call is not reported.
    Unsupported,
    /// The radio or its event queue cannot accept the operation yet.
    Busy,
    /// Not allowed in the current `State` (for example `transmit` while disabled).
    InvalidState,
    /// Channel outside 11..26, or another argument out of range.
    InvalidArgument,
    /// Frame length above `max_frame_len`, or a header the driver cannot ACK-match.
    InvalidFrame,
    /// The source-match table is full.
    NoSpace,
    /// The source-match entry is not in the table.
    NotFound,
    Timeout,
    Aborted,
    /// Startup or teardown failed a hardware verification. Poll for the reason.
    HardwareFault,
};

pub const Notify = struct {
    context: ?*anyopaque,
    /// May be called from interrupt context; must not call back into the radio.
    call: *const fn (?*anyopaque) void,
};

pub const VTable = struct {
    capabilities: *const fn (*anyopaque) Capabilities,
    /// Monotonic clock in microseconds, shared by all frame timestamps.
    /// It must advance independently of radio operation progress so blocking
    /// wrappers can time out while a submission or completion is stalled.
    now_us: *const fn (*anyopaque) u64,
    state: *const fn (*anyopaque) State,
    /// Receiver sensitivity, dBm.
    receive_sensitivity: *const fn (*anyopaque) i8,

    enable: *const fn (*anyopaque) Error!void,
    /// Synchronously disable admission and seal publication. Saved results
    /// remain pollable, including when teardown reports HardwareFault.
    disable: *const fn (*anyopaque) Error!void,
    /// Synchronously stop the active operation and retire its receive request.
    sleep: *const fn (*anyopaque) Error!void,
    /// Enter (or stay in) RX on `channel`. Also the way a sniffer hops channels.
    /// With RX-on-when-idle disabled, an explicit receive ends after one accepted
    /// frame and any immediate ACK for that frame.
    /// An admitted TX, ED or CCA can refuse a new receive with Busy.
    receive: *const fn (*anyopaque, channel: u8) Error!void,
    receive_at: ?*const fn (*anyopaque, channel: u8, start_us: u64, duration_us: u32) Error!void = null,
    /// Guarantee a `tx_started` for every on-air attempt reaching the end of
    /// SFD and a `tx_done` for every accepted request. Return Busy when queue
    /// admission fails or a previous TX is active or has an unread completion.
    /// Return Busy during an immediate ACK. Poll and retry once the ACK has finished.
    /// The TX channel applies to its attempts and ACK wait. Continuing RX uses
    /// the channel selected by `receive` when the driver owns the ACK wait.
    /// With `ack_timeout` false, complete an on-air TX with `.sent` even if
    /// it requests an ACK, with `TxDone.ack` null. For an ACK request, enter
    /// RX on the TX channel in time for the reply and deliver ACKs as ordinary
    /// RX events after `tx_done`. The stack matches the ACK and owns the
    /// deadline. It can submit the retry after polling `tx_done`, or change
    /// RX state with `receive` or `sleep`.
    transmit: *const fn (*anyopaque, request: *const TxRequest) Error!void,
    /// Return Busy until a previous scan has finished and its success or failure has been polled.
    /// Return Busy during an immediate ACK. Poll and retry once the ACK has finished.
    energy_scan: ?*const fn (*anyopaque, channel: u8, duration_us: u32) Error!void = null,
    /// Run a standalone clear-channel assessment on the current channel.
    /// Return Busy until a previous assessment has finished and its `cca_done` has been polled.
    /// Return Busy during an immediate ACK. Poll and retry once the ACK has finished.
    cca: ?*const fn (*anyopaque) Error!void = null,
    /// Instantaneous RSSI on the current channel, dBm.
    /// Return Busy during an immediate ACK. Poll and retry once the ACK has finished.
    rssi: *const fn (*anyopaque) Error!i8,
    /// Next pending event, or null. After a notification, poll until null
    /// before waiting again. Frame bytes are valid until the next poll.
    poll: *const fn (*anyopaque, mode: PollMode) ?Event,
    /// Snapshot the sticky fault without running a prologue or consuming it.
    fault_pending: *const fn (*anyopaque) FaultPending,
    /// Register a coalesced, edge-triggered wakeup. One call may signal
    /// several queued events. The callback schedules a drain outside the ISR.
    set_notify: *const fn (*anyopaque, notify: ?Notify) void,

    // Address, filtering, bad-FCS, ACK power and source-match changes apply
    // to frames whose RX END latches after the setter returns. If END latches
    // during the setter, the frame may use either the full old or full new
    // settings. Filtering, ACK power and Frame Pending use one snapshot.
    set_pan_id: *const fn (*anyopaque, u16) void,
    set_short_address: *const fn (*anyopaque, u16) void,
    set_extended_address: *const fn (*anyopaque, [8]u8) void,
    /// Accept frames with no destination address addressed to our PAN (coordinator role).
    set_pan_coordinator: *const fn (*anyopaque, bool) void,
    /// No address filtering and no ACKs.
    set_promiscuous: *const fn (*anyopaque, bool) void,
    get_promiscuous: *const fn (*anyopaque) bool,
    set_deliver_bad_fcs: ?*const fn (*anyopaque, bool) Error!void = null,
    /// With idle RX disabled, a pending ACK to a Data Request can open a
    /// bounded response window on the TX channel before the radio sleeps.
    set_rx_on_when_idle: ?*const fn (*anyopaque, bool) Error!void = null,
    set_tx_power: *const fn (*anyopaque, dbm: i8) Error!void,
    get_tx_power: *const fn (*anyopaque) i8,
    set_cca_threshold: *const fn (*anyopaque, dbm: i8) Error!void,
    get_cca_threshold: *const fn (*anyopaque) Error!i8,

    set_src_match_enabled: ?*const fn (*anyopaque, bool) void = null,
    add_src_match: ?*const fn (*anyopaque, Address) Error!void = null,
    remove_src_match: ?*const fn (*anyopaque, Address) Error!void = null,
    clear_src_match: ?*const fn (*anyopaque, kind: AddressKind) void = null,
};

pub fn capabilities(self: IEEE802154_Radio) Capabilities {
    return self.vtable.capabilities(self.ptr);
}

pub fn now_us(self: IEEE802154_Radio) u64 {
    return self.vtable.now_us(self.ptr);
}

pub fn state(self: IEEE802154_Radio) State {
    return self.vtable.state(self.ptr);
}

pub fn receive_sensitivity(self: IEEE802154_Radio) i8 {
    return self.vtable.receive_sensitivity(self.ptr);
}

pub fn enable(self: IEEE802154_Radio) Error!void {
    return self.vtable.enable(self.ptr);
}

pub fn disable(self: IEEE802154_Radio) Error!void {
    return self.vtable.disable(self.ptr);
}

pub fn sleep(self: IEEE802154_Radio) Error!void {
    return self.vtable.sleep(self.ptr);
}

pub fn receive(self: IEEE802154_Radio, channel: u8) Error!void {
    return self.vtable.receive(self.ptr, channel);
}

pub fn receive_at(self: IEEE802154_Radio, channel: u8, start_us: u64, duration_us: u32) Error!void {
    const call = self.vtable.receive_at orelse return error.Unsupported;
    return call(self.ptr, channel, start_us, duration_us);
}

pub fn transmit(self: IEEE802154_Radio, request: *const TxRequest) Error!void {
    return self.vtable.transmit(self.ptr, request);
}

pub fn energy_scan(self: IEEE802154_Radio, channel: u8, duration_us: u32) Error!void {
    const call = self.vtable.energy_scan orelse return error.Unsupported;
    return call(self.ptr, channel, duration_us);
}

pub fn cca(self: IEEE802154_Radio) Error!void {
    const call = self.vtable.cca orelse return error.Unsupported;
    return call(self.ptr);
}

pub fn rssi(self: IEEE802154_Radio) Error!i8 {
    return self.vtable.rssi(self.ptr);
}

pub const PollMode = enum {
    drain,
    /// After settlement, return null without consuming any event if a sticky
    /// fault is pending, or if the radio is disabled. Decide under the same
    /// lock as dequeue so a fault discovered by settlement stays pollable.
    preserve_fault,
};

/// After a notification, consume events until this returns null.
pub fn poll(self: IEEE802154_Radio) ?Event {
    return self.vtable.poll(self.ptr, .drain);
}

pub fn fault_pending(self: IEEE802154_Radio) FaultPending {
    return self.vtable.fault_pending(self.ptr);
}

/// Set the coalesced queue wakeup callback.
pub fn set_notify(self: IEEE802154_Radio, notify: ?Notify) void {
    self.vtable.set_notify(self.ptr, notify);
}

pub fn set_pan_id(self: IEEE802154_Radio, pan_id: u16) void {
    self.vtable.set_pan_id(self.ptr, pan_id);
}

pub fn set_short_address(self: IEEE802154_Radio, address: u16) void {
    self.vtable.set_short_address(self.ptr, address);
}

pub fn set_extended_address(self: IEEE802154_Radio, address: [8]u8) void {
    self.vtable.set_extended_address(self.ptr, address);
}

pub fn set_pan_coordinator(self: IEEE802154_Radio, enabled: bool) void {
    self.vtable.set_pan_coordinator(self.ptr, enabled);
}

pub fn set_promiscuous(self: IEEE802154_Radio, enabled: bool) void {
    self.vtable.set_promiscuous(self.ptr, enabled);
}

pub fn get_promiscuous(self: IEEE802154_Radio) bool {
    return self.vtable.get_promiscuous(self.ptr);
}

pub fn set_deliver_bad_fcs(self: IEEE802154_Radio, enabled: bool) Error!void {
    const call = self.vtable.set_deliver_bad_fcs orelse return error.Unsupported;
    return call(self.ptr, enabled);
}

pub fn set_rx_on_when_idle(self: IEEE802154_Radio, enabled: bool) Error!void {
    const call = self.vtable.set_rx_on_when_idle orelse return error.Unsupported;
    return call(self.ptr, enabled);
}

pub fn set_tx_power(self: IEEE802154_Radio, dbm: i8) Error!void {
    return self.vtable.set_tx_power(self.ptr, dbm);
}

pub fn get_tx_power(self: IEEE802154_Radio) i8 {
    return self.vtable.get_tx_power(self.ptr);
}

pub fn set_cca_threshold(self: IEEE802154_Radio, dbm: i8) Error!void {
    return self.vtable.set_cca_threshold(self.ptr, dbm);
}

pub fn get_cca_threshold(self: IEEE802154_Radio) Error!i8 {
    return self.vtable.get_cca_threshold(self.ptr);
}

pub fn set_src_match_enabled(self: IEEE802154_Radio, enabled: bool) Error!void {
    const call = self.vtable.set_src_match_enabled orelse return error.Unsupported;
    call(self.ptr, enabled);
}

pub fn add_src_match(self: IEEE802154_Radio, address: Address) Error!void {
    const call = self.vtable.add_src_match orelse return error.Unsupported;
    return call(self.ptr, address);
}

pub fn remove_src_match(self: IEEE802154_Radio, address: Address) Error!void {
    const call = self.vtable.remove_src_match orelse return error.Unsupported;
    return call(self.ptr, address);
}

pub fn clear_src_match(self: IEEE802154_Radio, kind: AddressKind) Error!void {
    const call = self.vtable.clear_src_match orelse return error.Unsupported;
    call(self.ptr, kind);
}

/// Called synchronously by the blocking wrappers for unrelated events.
/// A blocking wrapper returns when its matching event arrives. A notify-driven
/// caller still drains any remaining events before waiting again.
/// Any frame bytes are valid only until the next poll. The callback must not poll or start an operation.
pub const OtherEvent = struct {
    context: ?*anyopaque,
    call: *const fn (?*anyopaque, Event) void,
};

/// Wait for a queued RX frame while the receiver runs on its current channel.
/// The timeout bounds the wait for event delivery. Set up RX separately,
/// since this wrapper does not change RX mode.
pub fn receive_blocking(self: IEEE802154_Radio, timeout_us: u32, other: ?OtherEvent) Error!RxFrame {
    try self.check_wait_state(false);
    return self.wait_for(.rx, self.now_us(), timeout_us, other);
}

/// Snapshot the request before polling queued events through `other`, so
/// `request.bytes` can refer to the frame from the last poll. A Busy submission
/// is retried within the same timeout. An accepted TX may finish after timeout.
pub fn transmit_blocking(self: IEEE802154_Radio, request: *const TxRequest, timeout_us: u32, other: ?OtherEvent) Error!TxDone {
    try self.check_wait_state(false);
    var bytes: [max_frame_len]u8 = undefined;
    var snapshot = request.*;
    if (snapshot.bytes.len > bytes.len) return error.InvalidFrame;
    const payload = bytes[0..snapshot.bytes.len];
    @memcpy(payload, snapshot.bytes);
    snapshot.bytes = payload;

    const start = self.now_us();
    try self.submit_blocking(self.vtable.transmit, .{ self.ptr, &snapshot }, start, timeout_us, other);
    return self.wait_for(.tx_done, start, timeout_us, other);
}

/// Try submission first, servicing events through `other` between Busy retries.
/// An accepted scan may finish after timeout.
pub fn energy_scan_blocking(self: IEEE802154_Radio, channel: u8, duration_us: u32, timeout_us: u32, other: ?OtherEvent) Error!i8 {
    try self.check_wait_state(false);
    const scan = self.vtable.energy_scan orelse return error.Unsupported;
    const start = self.now_us();
    try self.submit_blocking(scan, .{ self.ptr, channel, duration_us }, start, timeout_us, other);
    return self.wait_for(.energy_scan_done, start, timeout_us, other);
}

/// Try submission first, servicing events through `other` between Busy retries.
/// An accepted CCA may finish after timeout.
pub fn cca_blocking(self: IEEE802154_Radio, timeout_us: u32, other: ?OtherEvent) Error!bool {
    try self.check_wait_state(false);
    const assess = self.vtable.cca orelse return error.Unsupported;
    const start = self.now_us();
    try self.submit_blocking(assess, .{self.ptr}, start, timeout_us, other);
    return self.wait_for(.cca_done, start, timeout_us, other);
}

fn check_wait_state(self: IEEE802154_Radio, admitted: bool) Error!void {
    const disabled = self.state() == .disabled;
    if (self.fault_pending().pending) return error.Aborted;
    if (disabled) return if (admitted) error.Aborted else error.InvalidState;
}

fn within_budget(self: IEEE802154_Radio, start: u64, timeout_us: u32, admitted: bool) Error!void {
    try self.check_wait_state(admitted);
    const now = self.now_us();
    try self.check_wait_state(admitted);
    if (now -| start >= timeout_us) return error.Timeout;
}

fn poll_wait(self: IEEE802154_Radio, admitted: bool) Error!?Event {
    if (self.vtable.poll(self.ptr, .preserve_fault)) |event| return event;
    try self.check_wait_state(admitted);
    return null;
}

fn submit_blocking(
    self: IEEE802154_Radio,
    submit: anytype,
    args: anytype,
    start: u64,
    timeout_us: u32,
    other: ?OtherEvent,
) Error!void {
    while (true) {
        try self.within_budget(start, timeout_us, false);
        @call(.auto, submit, args) catch |err| {
            if (self.fault_pending().pending) return error.Aborted;
            if (err != error.Busy) return err;
            // Busy includes an unread completion of this kind. Service one
            // event per attempt so unrelated traffic cannot defer submission.
            if (try self.poll_wait(false)) |event| {
                if (other) |handler| handler.call(handler.context, event);
            }
            continue;
        };
        return;
    }
}

fn wait_for(
    self: IEEE802154_Radio,
    comptime expected: @typeInfo(Event).@"union".tag_type.?,
    start: u64,
    timeout_us: u32,
    other: ?OtherEvent,
) Error!switch (expected) {
    .rx => RxFrame,
    .tx_done => TxDone,
    .energy_scan_done => i8,
    .cca_done => bool,
    else => unreachable,
} {
    while (true) {
        try self.within_budget(start, timeout_us, expected != .rx);
        const event = try self.poll_wait(expected != .rx) orelse continue;
        if (event == expected) return @field(event, @tagName(expected));
        if (expected == .energy_scan_done and event == .energy_scan_failed) return event.energy_scan_failed;
        if (other) |handler| handler.call(handler.context, event);
    }
}

test {
    _ = @import("ieee802154_radio_tests.zig");
}
