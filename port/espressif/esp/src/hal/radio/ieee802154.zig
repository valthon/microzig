//! ESP32-C6 raw MAC, using the pinned ESP-IDF v5.5.1 blob ABI.
//! Register protocol: IDF hal/ieee802154_common_ll.h and ieee802154/driver/
//! esp_ieee802154_{dev,pib,frame}.c (Apache-2.0). The public C6 TRM does
//! not specify the radio MAC. Clock/power control: TRM v1.2 §§8.2.4.4, 12.4.2.5.
//!
//! One stationary Radio, one calling task; methods are synchronous. Hardware
//! handles FCS and legacy ACK turnaround while software polls event status.
//! RX_DONE uses interrupt29 at priority 15 only for enhanced ACK turnaround.
//! Applications still poll synchronous operations; no background RX queue.
//! Between receive calls the MAC is idle. The coexistence branches below are
//! compile-only: `hal.radio.radios` rejects 802.15.4 with Wi-Fi or BLE, so no
//! image can select them (valthon/microzig#40 tracks 802.15.4 coexistence).
//! Init requires radio.radios.ieee802154 and RTOS.
const std = @import("std");
pub const security = @import("ieee802154/security.zig");
pub const header = @import("ieee802154/header.zig");
pub const ack_diagnostics = @import("ieee802154/ack_diagnostics.zig");
const ack_request = @import("ieee802154/ack_request.zig");
const frames = @import("ieee802154_frame.zig");
const rx = @import("ieee802154_rx.zig");
const microzig = @import("microzig");
const radio = @import("../radio.zig");
const osi = @import("osi.zig");
const clocks = @import("../analog/esp32_c6.zig");
const time = @import("../time.zig");
const rng = @import("../rng.zig");
const mac = microzig.chip.peripherals.IEEE802154;
const Opcode = microzig.chip.types.peripherals.IEEE802154.Opcode;

extern fn bt_bb_v2_init_cmplx(print_version: c_int) void;
extern fn ieee802154_txon_delay_set() void;

pub const Config = struct {
    channel: u8 = 11,
    /// dBm; clamped/rounded down as in IDF v5.5.1 (−15 through +20).
    tx_power: i8 = 0,
    pan_id: u16 = 0xffff,
    short_address: u16 = 0xffff,
    /// Octets in over-the-air order, least significant octet first.
    extended_address: [8]u8 = @splat(0),
    /// Capture every CRC-valid frame without address filtering or ACKs.
    /// Secured frames are returned raw, as received (auxiliary header,
    /// ciphertext, MIC), even when `security` is set: no verification,
    /// decryption, replay or key-counter change. Treat them as unauthenticated.
    promiscuous: bool = false,
    /// Hardware legacy ACKs; enhanced ACKs also require enhanced_ack.
    /// Both are disabled in promiscuous RX.
    auto_ack: bool = true,
    /// Borrowed, stationary caller-owned key/replay tables, serialized by the
    /// owning task. The ISR reserves ACK counters only while receive is active.
    security: ?*security.Context = null,
    enhanced_ack: bool = false,
    /// Record each generated enhanced ACK and its first terminal event in
    /// Radio.last_ack_tx, so the task can confirm the ACK was transmitted.
    ack_diagnostics: bool = false,
    /// Complete header IE list ending with its only terminator, a zero-length
    /// HT2; HT1 is refused (header.validate_ack_ies). Borrowed until idle.
    ack_header_ies: []const u8 = &.{},
    cca_threshold: i8 = -75,
    cca_mode: enum(u2) { carrier = 0, energy = 1, carrier_or_energy = 2, carrier_and_energy = 3 } = .energy,
    tx: TxConfig = .{},
};

pub const Error = security.Error || error{
    UnsupportedRadioProtocol,
    AlreadyInitialized,
    NotInitialized,
    Faulted,
    InvalidChannel,
    InvalidFrame,
    UnsupportedFrame,
    InvalidDuration,
    InvalidTxConfig,
    Timeout,
    Crc,
    RxAborted,
    TxAborted,
    AckTransmitFailed,
    MissingAckInterrupt,
    CcaFailed,
};
pub const InitError = radio.InitError || Error;
pub const TxResult = frames.tx.Result;
pub const TxConfig = frames.tx.Config;
pub const Energy = struct { rssi: i8, busy: bool };
pub const Frame = rx.Frame;

const Event = struct {
    const tx_done = 1 << 0;
    const rx_done = 1 << 1;
    const ack_tx_done = 1 << 2;
    const ack_rx_done = 1 << 3;
    const rx_abort = 1 << 4;
    const tx_abort = 1 << 5;
    const ed_done = 1 << 6;
    const all = 0x1fff;
};

// Singleton hardware ownership, protected only for init/deinit. The owning
// task serializes operations and keeps the handle at its original address.
var owner: ?*Radio = null;

pub const Radio = struct {
    config: Config = .{},
    rx_dma: [128]u8 align(4) = @splat(0),
    tx_dma: [128]u8 align(4) = @splat(0),
    faulted: bool = false,
    /// Actual frame transmissions in the latest transmit call, excluding busy
    /// CCAs. Reset after frame validation; at most max_frame_retries + 1.
    last_tx_attempts: u8 = 0,
    /// Actual received ACK, after security verification; includes auxiliary
    /// header, excludes MIC/FCS. Null until a successful ACK exchange.
    last_ack: ?Frame = null,
    /// Diagnostic snapshots for the last operation; raw MPDUs retain their MIC.
    last_rx_wire: ?Frame = null,
    last_ack_wire: ?Frame = null,
    last_ack_error: ?Error = null,
    last_events: u13 = 0,
    last_tx_abort: ?u5 = null,
    last_rx_abort: ?u5 = null,
    /// Read only after receive/transmit returns (MAC IRQ is then unmapped).
    /// Each receive resets this; set for enhanced-ACK requests only when
    /// Config.ack_diagnostics is enabled.
    last_ack_tx: ?ack_diagnostics.Ack = null,
    ack_dma: [128]u8 align(4) = @splat(0),
    pending_events: std.atomic.Value(u32) = .init(0),
    ack_failed: std.atomic.Value(bool) = .init(false),
    /// Why the ACK generator refused a request; a refusal reserves no counter.
    /// Written before ack_failed is released; read after it is acquired.
    rx_rejection: ?security.Error = null,
    // Accessed with interrupts masked; configuration/keys/DMA remain stationary
    // throughout receive. The ISR never touches replay state or task plaintext;
    // it reserves ACK counters only for requests ack_request.prepare accepts.
    receiving: bool = false,
    tx_security: ?struct { key: usize, offset: u7 } = null,

    /// Initialize in place; do not copy or move the handle until deinit.
    pub fn init(self: *Radio, allocator: std.mem.Allocator, config: Config) InitError!void {
        if (!radio.coex_enabled and microzig.options.hal.radio.radios.ble)
            @compileError("IEEE 802.15.4 and BLE cannot run simultaneously: no RF coexistence scheduler");
        if (!microzig.options.hal.radio.radios.ieee802154) return error.UnsupportedRadioProtocol;
        try validate_config(config);
        {
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            if (owner != null) return error.AlreadyInitialized;
            owner = self;
        }
        errdefer release_owner();
        try radio.init(allocator);
        self.* = .{ .config = config };
        clocks.ieee802154_clocks_set_enabled(true);
        if (radio.coex_enabled) osi.phy_modem_enable(.ieee802154) else osi.phy_enable();
        // IDF esp_ieee802154_enable: PHY -> esp_btbb_enable -> MAC reset/init.
        // No BTBB teardown call exists in the blob; IDF disable only drops refs.
        if (radio.coex_enabled) @import("coex.zig").btbb_enable(0) else bt_bb_v2_init_cmplx(0);
        clocks.ieee802154_mac_reset();
        configure_mac(config);
        ieee802154_txon_delay_set();
    }

    pub fn deinit(self: *Radio) if (radio.coex_enabled) error{WouldBlock}!void else void {
        if (radio.coex_enabled and @import("callback_context.zig").active()) return error.WouldBlock;
        if (!self.is_owner()) return;
        self.stop();
        // Hold MAC in reset before relinquishing DMA buffers, even after faults.
        clocks.ieee802154_mac_reset();
        mac.EVENT_EN.write(.{ .EVENT_EN = 0 });
        if (radio.coex_enabled) @import("coex.zig").btbb_disable();
        if (radio.coex_enabled) osi.phy_modem_disable(.ieee802154) else osi.phy_disable();
        clocks.ieee802154_clocks_set_enabled(false);
        // The callback check above is radio.deinit's only error, so nothing
        // after the teardown starts can fail.
        if (radio.coex_enabled)
            radio.deinit() catch @panic("802.15.4 deinit released the radio from a callback")
        else
            radio.deinit();
        release_owner();
    }

    /// Takes effect for the next operation; MAC is idle between calls.
    pub fn configure(self: *Radio, config: Config) Error!void {
        try self.check();
        try validate_config(config);
        self.config = config;
        configure_mac(config);
    }

    /// Receive one CRC-valid MAC frame. Timeout is in microseconds. Recoverable
    /// aborts restart RX without extending the deadline. If no valid frame
    /// follows a bad FCS, return Crc at the deadline instead of Timeout.
    /// Secured frames are unsecured through Config.security, or refused with
    /// UnknownKey without one; promiscuous receive returns them raw
    /// (header.deliver). `Frame.protection` says which: `.authenticated`
    /// frames are verified plaintext, `.decrypted_unauthenticated` ones
    /// (level 4, opted in) are plaintext nothing vouches for, and
    /// `.raw_secured` ones are ciphertext+MIC.
    pub fn receive(self: *Radio, timeout_us: u32) Error!Frame {
        try self.check();
        if (timeout_us == 0) return error.InvalidDuration;
        self.last_rx_wire = null;
        self.last_events = 0;
        self.last_rx_abort = null;
        self.last_ack_tx = null;
        configure_mac(self.config);
        clear_events(Event.all);
        _ = self.pending_events.swap(0, .acq_rel);
        self.ack_failed.store(false, .release);
        self.rx_rejection = null;
        {
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            self.receiving = true;
            if (self.config.enhanced_ack and self.config.auto_ack and !self.config.promiscuous) {
                microzig.cpu.interrupt.map(.zb_mac, .interrupt29);
                microzig.cpu.interrupt.set_type(.interrupt29, .level);
                microzig.cpu.interrupt.set_priority(.interrupt29, .highest);
                microzig.cpu.interrupt.enable(.interrupt29);
            }
        }
        defer self.stop();
        defer {
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            if (self.config.enhanced_ack and self.config.auto_ack and !self.config.promiscuous) {
                microzig.cpu.interrupt.map(.zb_mac, null);
                microzig.cpu.interrupt.disable(.interrupt29);
            }
            self.receiving = false;
        }
        var io: RxIo = .{ .device = self };
        // A request the ACK generator refused got no ACK: return why. For
        // the incoming-security refusals (policy, counter 0xffffffff, key,
        // sender, MIC length) that is the error the check below returns.
        // Three cases differ from the task path: a key whose counters are
        // exhausted drops even a genuine frame (CounterExhausted), a
        // secured ACK-type frame with AR set returns InvalidFrame where the
        // task would authenticate it, and an unsecured request that cannot
        // be answered (one that fails to parse, such as an unterminated
        // header IE list) returns InvalidFrame or UnsupportedFrame where
        // without enhanced ACKs it is delivered.
        var result = rx.receive(&io, timeout_us) catch |err| return ack_request.receive_error(err, self.rx_rejection);
        const delivered = try header.deliver(self.config.security, self.config.promiscuous, result.data[0..result.len], self.config.pan_id);
        result.len = @intCast(delivered.len);
        result.protection = delivered.protection;
        return result;
    }

    /// MAC bytes include FCF/sequence/address/payload, exclude length and FCS.
    /// Hardware inserts the FCS. ACK-request frames wait for a matching
    /// legacy or enhanced ACK. Secured input includes a complete auxiliary
    /// header (counter overwritten), plaintext payload, and no MIC. The MAC
    /// secures/appends the MIC; the caller buffer is never changed. Unslotted CSMA-CA is used when
    /// use_cca is true; missing ACKs retry
    /// with the same sequence number. Config.tx bounds both procedures. Returns
    /// the final outcome; last_tx_attempts excludes unsuccessful CCAs.
    pub fn transmit(self: *Radio, frame: []const u8, use_cca: bool) Error!TxResult {
        try self.check();
        self.tx_security = null;
        self.last_ack = null;
        const h = try header.parse(frame);
        if (h.auxiliary == null and h.version < 2) try frames.validate_tx(frame);
        var len = frame.len;
        if (h.auxiliary) |aux| {
            const ctx = self.config.security orelse return error.UnknownKey;
            const key_index = try ctx.lookup(aux.id);
            len += security.mic_len(aux.level);
            if (len > 125) return error.InvalidFrame;
            self.tx_dma[0] = @intCast(len + 2);
            @memcpy(self.tx_dma[1..][0..frame.len], frame);
            var tx_aux = aux;
            tx_aux.counter = try ctx.keys[key_index].reserve();
            _ = try tx_aux.encode(self.tx_dma[1 + h.auxiliary_offset ..]);
            @memset(self.tx_dma[1 + frame.len ..][0 .. len - frame.len + 2], 0);
            if (try header.seal_software(ctx.keys[key_index].value, self.config.extended_address, self.tx_dma[1..][0..len])) {
                self.tx_security = null;
            } else self.tx_security = .{ .key = key_index, .offset = @intCast(h.payload_offset) };
        } else {
            self.tx_dma[0] = @intCast(len + 2);
            @memcpy(self.tx_dma[1..][0..len], frame);
            @memset(self.tx_dma[1 + len ..][0..2], 0);
        }
        return self.transmit_prepared(frame, use_cca);
    }

    /// Send an already secured wire MPDU without modifying its counter/MIC.
    /// Intended for raw-MAC interoperability and negative tests. Caller owns
    /// nonce uniqueness. Normal applications should use transmit().
    pub fn transmit_wire(self: *Radio, frame: []const u8, use_cca: bool) Error!TxResult {
        try self.check();
        _ = try header.parse(frame);
        self.tx_security = null;
        self.last_ack = null;
        self.tx_dma[0] = @intCast(frame.len + 2);
        @memcpy(self.tx_dma[1..][0..frame.len], frame);
        @memset(self.tx_dma[1 + frame.len ..][0..2], 0);
        return self.transmit_prepared(frame, use_cca);
    }

    fn transmit_prepared(self: *Radio, frame: []const u8, use_cca: bool) Error!TxResult {
        self.last_tx_attempts = 0;
        self.last_ack_wire = null;
        self.last_ack_error = null;
        self.last_events = 0;
        self.last_tx_abort = null;
        configure_mac(self.config);
        mac.CTRL_CFG.modify(.{ .HW_AUTO_ACK_RX_EN = @intFromBool(frame[0] & 0x20 != 0), .PROMISCUOUS_MODE = 0 });
        var io: TxIo = .{ .device = self, .frame = frame };
        return frames.tx.transmit(&io, self.config.tx, use_cca);
    }

    fn transmit_once(self: *Radio, frame: []const u8, use_cca: bool) Error!TxResult {
        const ack = frame[0] & 0x20 != 0;
        // Re-arm TX/ACK DMA for every retry, as IDF dev.c:859-874 tx_init does.
        mac.TXDMA_ADDR.write(.{ .TXDMA_ADDR = @intFromPtr(&self.tx_dma) });
        mac.RXDMA_ADDR.write(.{ .RXDMA_ADDR = @intFromPtr(&self.rx_dma) });
        clear_events(Event.all);
        mac.ED_SCAN_DURATION.modify(.{ .ED_SCAN_DURATION = 8 });
        if (self.tx_security) |sec| {
            const ctx = self.config.security.?;
            configure_security(ctx.keys[sec.key].value, self.config.extended_address, sec.offset);
        } else mac.SEC_CTRL.modify(.{ .SEC_EN = 0 });
        const frame_version: u2 = @truncate(frame[1] >> 4);
        // IDF v5.5.1 esp_ieee802154_set_ack_timeout converts us to
        // ceil(us/16); common_ll.h:set_ack_timeout writes this symbol count.
        mac.ACK_TIMEOUT.modify(.{ .ACK_TIMEOUT = self.config.tx.hardware_wait_symbols(frame_version) });
        command(if (use_cca) .cca_tx_start else .tx_start);
        defer self.stop();
        var io: TxCompletionIo = .{ .device = self, .frame = frame };
        return frames.tx.wait_for_completion(&io, ack, self.config.tx.completion_wait_symbols(frame_version));
    }

    /// Average RSSI (dBm) plus CCA decision. Duration is microseconds; like
    /// IDF's LL API it is bounded to u16. Standalone CCA uses eight us.
    pub fn energy_detect(self: *Radio, duration_us: u16) Error!Energy {
        try self.check();
        if (duration_us == 0) return error.InvalidDuration;
        configure_mac(self.config);
        clear_events(Event.all);
        mac.ED_SCAN_DURATION.modify(.{ .ED_SCAN_DURATION = duration_us });
        command(.ed_start);
        defer self.stop();
        const deadline = now() + @as(u64, duration_us) + 10_000;
        while (now() < deadline) {
            const events = mac.EVENT_STATUS.read().EVENT_STATUS;
            clear_events(events);
            if (events & Event.rx_abort != 0) return error.RxAborted;
            if (events & Event.ed_done != 0) {
                const result = mac.ED_SCAN_CFG.read();
                return .{ .rssi = @bitCast(result.ED_RSS), .busy = result.CCA_BUSY != 0 };
            }
            std.atomic.spinLoopHint();
        }
        return error.Timeout;
    }

    pub fn cca(self: *Radio) Error!bool {
        return !(try self.energy_detect(8)).busy;
    }

    fn stop(self: *Radio) void {
        if (self.last_ack_tx) |*trace| {
            trace.finish(.stopped, mac.EVENT_STATUS.read().EVENT_STATUS);
        }
        command(.stop);
        const deadline = now() + 10_000;
        while (true) {
            const status = mac.TXRX_STATUS.read();
            if (status.TX_PROC == 0 and status.RX_PROC == 0 and status.ED_PROC == 0 and status.ED_TRIGGER_TX_PROC == 0) break;
            if (now() >= deadline) {
                // Stop DMA before returning caller-owned buffers. A stuck MAC
                // requires explicit deinit/init; never quietly continue after it.
                clocks.ieee802154_mac_reset();
                self.faulted = true;
                break;
            }
        }
        clear_events(Event.all);
    }

    fn is_owner(self: *Radio) bool {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        return owner == self;
    }

    fn check(self: *Radio) Error!void {
        if (!self.is_owner()) return error.NotInitialized;
        if (self.faulted) return error.Faulted;
    }
};

const TxCompletionIo = struct {
    device: *Radio,
    frame: []const u8,

    pub fn now(_: *TxCompletionIo) u64 {
        return time.get_time_since_boot().to_us();
    }

    pub fn poll(self: *TxCompletionIo) frames.tx.Events {
        const events = mac.EVENT_STATUS.read().EVENT_STATUS;
        const reason = mac.TX_STATUS.read().TX_ABORT_STATUS;
        self.device.last_events |= events;
        if (events & Event.tx_abort != 0) self.device.last_tx_abort = reason;
        clear_events(events);
        return .{
            .done = events & Event.tx_done != 0,
            .ack_done = events & Event.ack_rx_done != 0,
            .abort = if (events & Event.tx_abort != 0) reason else null,
        };
    }

    pub fn end_tx(_: *TxCompletionIo) void {
        // IDF v5.5.1 dev.c event_end_process/isr_handle_tx_done disables
        // transmit security before entering RX_ACK, including M=0 frames.
        mac.SEC_CTRL.modify(.{ .SEC_EN = 0 });
    }

    pub fn mark_sent(self: *TxCompletionIo) void {
        self.device.last_tx_attempts += 1;
    }

    pub fn validate_ack(self: *TxCompletionIo) error{InvalidFrame}!void {
        self.check_ack() catch |err| {
            self.device.last_ack_error = err;
            return error.InvalidFrame;
        };
    }

    fn check_ack(self: *TxCompletionIo) Error!void {
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        const len = dma_load(&self.device.rx_dma, 0) & 0x7f;
        if (len < 5 or len > 127) return error.InvalidFrame;
        var ack: Frame = .{ .data = undefined, .len = @intCast(len - 2), .rssi = @bitCast(dma_load(&self.device.rx_dma, len - 1)), .lqi = dma_load(&self.device.rx_dma, len), .protection = .of_wire(dma_load(&self.device.rx_dma, 1)) };
        for (ack.data[0..ack.len], 1..) |*byte, i| byte.* = dma_load(&self.device.rx_dma, i);
        self.device.last_ack_wire = ack;
        const sent = header.parse(self.frame) catch return error.InvalidFrame;
        const got = header.parse(ack.bytes()) catch return error.InvalidFrame;
        if (ack.data[0] & 7 != 2 or ack.data[0] & 0x20 != 0 or got.sequence != sent.sequence) return error.InvalidFrame;
        if (sent.version < 2) {
            if (ack.len != 3 or got.version > 1) return error.InvalidFrame;
        } else {
            if (got.version != 2) return error.InvalidFrame;
            if (got.destination.len != 0 and !std.mem.eql(u8, got.destination, sent.source)) return error.InvalidFrame;
            if (got.source.len != 0 and !std.mem.eql(u8, got.source, sent.destination)) return error.InvalidFrame;
            if (got.destination_pan != null and got.destination_pan != (sent.source_pan orelse self.device.config.pan_id)) return error.InvalidFrame;
            if (sent.sequence == null and got.destination.len == 0) return error.InvalidFrame;
            if (sent.auxiliary) |a| {
                const b = got.auxiliary orelse return error.InvalidFrame;
                if (a.level != b.level or !a.id.eql(b.id)) return error.InvalidFrame;
            }
            if (got.auxiliary != null) {
                const ctx = self.device.config.security orelse return error.InvalidFrame;
                const delivered = try header.receive_ack(ctx, sent, ack.data[0..ack.len], self.device.config.pan_id);
                ack.len = @intCast(delivered.len);
                ack.protection = delivered.protection;
            }
        }
        self.device.last_ack = ack;
    }

    pub fn spin(_: *TxCompletionIo) void {
        std.atomic.spinLoopHint();
    }
};

const TxIo = struct {
    device: *Radio,
    frame: []const u8,

    pub fn random(_: *TxIo) u32 {
        // IDF v5.5.1 esp_openthread_radio.c:790-794 supplies entropy through
        // esp_fill_random; esp_hw_support/hw_random.c:55-104 reads the C6 RNG.
        // Our HAL uses that peripheral directly (C6 TRM v1.2 §§26.3-26.4).
        return rng.random_u32();
    }

    pub fn wait(_: *TxIo, us: u32) void {
        time.sleep_us(us);
    }

    pub fn attempt(self: *TxIo, use_cca: bool) Error!TxResult {
        const result = try self.device.transmit_once(self.frame, use_cca);
        // stop() can reset a stuck MAC in transmit_once's defer. Never retry
        // or report success with that reset configuration.
        if (self.device.faulted) return error.Faulted;
        return result;
    }
};

const RxIo = struct {
    device: *Radio,

    pub fn now(_: *RxIo) u64 {
        return time.get_time_since_boot().to_us();
    }

    pub fn start(self: *RxIo) void {
        // IDF enable_rx re-arms the buffer before every RX_START, including
        // the next_operation path after a recoverable RX abort.
        mac.RXDMA_ADDR.write(.{ .RXDMA_ADDR = @intFromPtr(&self.device.rx_dma) });
        command(.rx_start);
    }

    pub fn poll(self: *RxIo) rx.Events {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        service_events(self.device);
        const events: u13 = @truncate(self.device.pending_events.swap(0, .acq_rel));
        const reason = mac.RX_STATUS.read().RX_ABORT_STATUS;
        if (events & Event.rx_done != 0)
            asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        return .{
            .abort = if (events & Event.rx_abort != 0) reason else null,
            .done = events & Event.rx_done != 0,
            .ack_done = events & Event.ack_tx_done != 0,
            .ack_failed = self.device.ack_failed.swap(false, .acq_rel),
        };
    }

    pub fn load(self: *RxIo, index: usize) u8 {
        return dma_load(&self.device.rx_dma, index);
    }

    pub fn auto_ack(self: *RxIo) bool {
        return self.device.config.auto_ack and !self.device.config.promiscuous;
    }

    pub fn enhanced_ack(self: *RxIo) bool {
        return self.device.config.enhanced_ack;
    }

    pub fn set_pending(_: *RxIo) void {
        // IDF configures pending on RX_DONE before ACK_TX_DONE. This raw
        // driver has no indirect-data pending table.
        mac.ACK_FRAME_PENDING_EN.modify(.{ .ACK_FRAME_PENDING_EN = 0 });
    }

    pub fn spin(_: *RxIo) void {
        std.atomic.spinLoopHint();
    }
};

fn release_owner() void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    owner = null;
}

fn validate_config(config: Config) Error!void {
    if (config.enhanced_ack and comptime !std.meta.eql(microzig.options.interrupts.interrupt29, @as(?microzig.cpu.InterruptHandler, interrupt_handler))) return error.MissingAckInterrupt;
    if (config.channel < 11 or config.channel > 26) return error.InvalidChannel;
    try config.tx.validate();
    // Bound the ISR's key and peer lookups and IE walk independently of
    // caller storage.
    if (config.ack_header_ies.len > 80) return error.InvalidSecurityConfig;
    if (config.security) |ctx| {
        if (config.enhanced_ack and !ack_request.within_table_limits(ctx.keys.len, ctx.peers.len)) return error.InvalidSecurityConfig;
        try ctx.validate();
    }
    try header.validate_ack_ies(config.ack_header_ies);
}

fn configure_mac(config: Config) void {
    mac.CHANNEL.modify(.{ .HOP = @as(u7, @intCast((config.channel - 11) * 5 + 3)) });
    mac.TX_POWER.modify(.{ .TX_POWER = frames.power_index(config.tx_power) });
    mac.CTRL_CFG.modify(.{
        .HW_AUTO_ACK_TX_EN = @intFromBool(config.auto_ack and !config.promiscuous),
        .HW_AUTO_ACK_RX_EN = 0,
        .HW_ENHANCE_ACK_TX_EN = @intFromBool(config.enhanced_ack and config.auto_ack and !config.promiscuous),
        .PAN_COORDINATOR = 0,
        .PROMISCUOUS_MODE = @intFromBool(config.promiscuous),
        .AUTOPEND_ENHANCE = 0,
        .MAC_INF0_ENABLE = 1,
        .MAC_INF1_ENABLE = 0,
        .MAC_INF2_ENABLE = 0,
        .MAC_INF3_ENABLE = 0,
    });
    mac.INF0_PAN_ID.modify(.{ .MAC_INF0_PAN_ID = config.pan_id });
    mac.INF0_SHORT_ADDR.modify(.{ .MAC_INF0_SHORT_ADDR = config.short_address });
    mac.INF0_EXTEND_ADDR0.write(.{ .MAC_INF0_EXTEND_ADDR0 = std.mem.readInt(u32, config.extended_address[0..4], .little) });
    mac.INF0_EXTEND_ADDR1.write(.{ .MAC_INF0_EXTEND_ADDR1 = std.mem.readInt(u32, config.extended_address[4..8], .little) });
    mac.ED_SCAN_CFG.modify(.{
        .CCA_ED_THRESHOLD = @as(u8, @bitCast(config.cca_threshold)),
        .CCA_MODE = @backingInt(config.cca_mode),
        .DIS_ED_POWER_SEL = 1, // IDF ed_sample_mode = AVG.
    });
    mac.COEX_PTI.modify(.{ .COEX_PTI = 3, .COEX_ACK_PTI = 3 });
    mac.ACK_FRAME_PENDING_EN.modify(.{ .ACK_FRAME_PENDING_EN = 0 });
    mac.SEC_CTRL.modify(.{ .SEC_EN = 0 });
    // No CPU interrupt is mapped. EVENT_EN controls MAC event latching too.
    mac.EVENT_EN.write(.{ .EVENT_EN = Event.all });
    mac.RX_ABORT_INTR_CTRL.write(.{ .RX_ABORT_INTR_CTRL = 0x7fffffff });
    mac.TX_ABORT_INTERRUPT_CONTROL.write(.{ .TX_ABORT_INTERRUPT_CONTROL = 0x7fffffff });
}

fn command(opcode: Opcode) void {
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    mac.COMMAND.write(.{ .OPCODE = opcode });
}

fn clear_events(events: u13) void {
    // EVENT_STATUS is W1C: never read-modify-write a pending event register.
    mac.EVENT_STATUS.write(.{ .EVENT_STATUS = events });
}

fn dma_load(buffer: *const [128]u8, index: usize) u8 {
    const ptr: *const volatile u8 = &buffer[index];
    return ptr.*;
}

fn now() u64 {
    return time.get_time_since_boot().to_us();
}

/// Slot 29 is required only by IEEE802154 images using this driver. Mapping
/// exists only during enhanced-ACK receive; priority 15, level-triggered.
/// The ISR owns no buffers: receive keeps config/keys and both DMA buffers
/// stationary; task accesses receiving/config/keys with this IRQ unmapped or
/// interrupts masked. pending_events/ack_failed transfer completion atomically.
pub const interrupt_handler: microzig.cpu.InterruptHandler = .{
    .c = struct {
        fn handler(_: *microzig.cpu.TrapFrame) linksection(".ram_text") callconv(.c) void {
            if (owner) |device| service_events(device);
        }
    }.handler,
};

fn service_events(device: *Radio) void {
    const events = mac.EVENT_STATUS.read().EVENT_STATUS;
    device.last_events |= events;
    if (events & Event.rx_abort != 0) device.last_rx_abort = mac.RX_STATUS.read().RX_ABORT_STATUS;
    clear_events(events);
    if (events & Event.rx_done != 0 and events & Event.rx_abort == 0 and device.receiving and device.config.enhanced_ack and device.config.auto_ack and !device.config.promiscuous) {
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        const len = dma_load(&device.rx_dma, 0) & 0x7f;
        if (len >= 5 and len <= 127 and dma_load(&device.rx_dma, 1) & 0x20 != 0 and dma_load(&device.rx_dma, 2) & 0x30 == 0x20) {
            arm_enhanced_ack(device, len - 2) catch |err| {
                if (device.last_ack_tx) |*trace| {
                    trace.generation_error = @errorName(err);
                    trace.finish(.stopped, events);
                }
                device.ack_failed.store(true, .release);
                // IDF dev.c:477–481 stops RX if the generator cannot build an ACK.
                command(.stop);
            };
        }
    }
    if (events & (Event.ack_tx_done | Event.rx_abort) != 0) {
        if (device.last_ack_tx) |*trace| {
            trace.finish(.event, events);
        }
    }
    if (events & Event.rx_done != 0) {
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        const size = dma_load(&device.rx_dma, 0) & 0x7f;
        if (size >= 5 and size <= 127) {
            var raw: Frame = .{ .data = undefined, .len = @intCast(size - 2), .rssi = @bitCast(dma_load(&device.rx_dma, size - 1)), .lqi = dma_load(&device.rx_dma, size), .protection = .of_wire(dma_load(&device.rx_dma, 1)) };
            for (raw.data[0..raw.len], 1..) |*byte, i| byte.* = dma_load(&device.rx_dma, i);
            device.last_rx_wire = raw;
        }
    }
    _ = device.pending_events.fetchOr(events, .release);
}

fn arm_enhanced_ack(device: *Radio, len: usize) Error!void {
    // IDF v5.5.1 esp_ieee802154_dev.c:452–474: RX_DONE -> build ACK ->
    // TXDMA -> sec_update -> generate_done_notify. No software TX_START:
    // the MAC owns the 12-symbol (192 us) turnaround, IEEE §6.7.4.
    if (device.config.ack_diagnostics) device.last_ack_tx = .{ .level = 0, .received_counter = 0 };
    // Match IDF isr_handle_rx_done/event_end_process for unsecured requests too.
    mac.SEC_CTRL.modify(.{ .SEC_EN = 0 });
    mac.ACK_FRAME_PENDING_EN.modify(.{ .ACK_FRAME_PENDING_EN = 0 });
    var received: [125]u8 = undefined;
    for (received[0..len], 1..) |*byte, i| byte.* = dma_load(&device.rx_dma, i);
    // The request is not authenticated yet (that runs in the task after
    // turnaround). prepare reserves an ACK counter only for a request that
    // passes every check needing no crypto and that it can answer; any
    // refusal reserves nothing and is reported by receive.
    const trace: ?*ack_diagnostics.Ack = if (device.last_ack_tx) |*t| t else null;
    const prepared = ack_request.prepare(device.config.security, device.ack_dma[1..126], received[0..len], device.config.ack_header_ies, device.config.pan_id, trace) catch |err| return reject(device, err);
    const ack_len = prepared.len;
    device.ack_dma[0] = @intCast(ack_len + 2);
    @memset(device.ack_dma[1 + ack_len ..][0..2], 0);
    mac.TXDMA_ADDR.write(.{ .TXDMA_ADDR = @intFromPtr(&device.ack_dma) });
    if (prepared.key) |index| {
        const value = device.config.security.?.keys[index].value;
        const aux = prepared.auxiliary.?;
        // header.ack emits no payload. Avoid parsing the generated ACK twice
        // just to recover its security offset and select the accelerator.
        if (aux.level < 5) {
            // Generated ACKs have no message. M=0 therefore needs neither
            // AES nor key expansion. MIC-only needs B0, AD blocks and S0.
            if (aux.level < 4) {
                const cipher = @import("ieee802154/ack_aes.zig").Cipher.init(value);
                defer cipher.deinit();
                const end = ack_len - security.mic_len(aux.level);
                try security.seal_with_cipher(cipher, security.nonce(device.config.extended_address, aux.counter, aux.level), aux.level, device.ack_dma[1..][0..end], end, device.ack_dma[1 + end ..][0 .. ack_len - end]);
            }
            mac.SEC_CTRL.modify(.{ .SEC_EN = 0 });
        } else configure_security(value, device.config.extended_address, @intCast(ack_len - security.mic_len(aux.level)));
    } else mac.SEC_CTRL.modify(.{ .SEC_EN = 0 });
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    mac.ENHANCE_ACK_CFG.write(.{ .TX_ENH_ACK_GENERATE_DONE_NOTIFY = 1 });
}

/// The caller publishes ack_failed (release) after this returns.
fn reject(device: *Radio, err: security.Error) Error {
    device.rx_rejection = err;
    return err;
}

fn configure_security(key: [16]u8, extended: [8]u8, offset: u7) void {
    // IDF sec.c:16–29 and common_ll.h:442–468. Offset excludes the PHR
    // (frame.c:269–292 returns offset - 1).
    mac.SEC_EXTEND_ADDRESS0.write(.{ .SEC_EXTEND_ADDRESS0 = std.mem.readInt(u32, extended[0..4], .little) });
    mac.SEC_EXTEND_ADDRESS1.write(.{ .SEC_EXTEND_ADDRESS1 = std.mem.readInt(u32, extended[4..8], .little) });
    mac.SEC_KEY0.write(.{ .SEC_KEY0 = std.mem.readInt(u32, key[0..4], .little) });
    mac.SEC_KEY1.write(.{ .SEC_KEY1 = std.mem.readInt(u32, key[4..8], .little) });
    mac.SEC_KEY2.write(.{ .SEC_KEY2 = std.mem.readInt(u32, key[8..12], .little) });
    mac.SEC_KEY3.write(.{ .SEC_KEY3 = std.mem.readInt(u32, key[12..16], .little) });
    mac.SEC_CTRL.modify(.{ .SEC_EN = 1, .SEC_PAYLOAD_OFFSET = offset });
}
