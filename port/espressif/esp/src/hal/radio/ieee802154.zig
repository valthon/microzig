//! ESP32-C6 raw MAC, using the pinned ESP-IDF v5.5.1 blob ABI.
//! Register protocol: IDF hal/ieee802154_common_ll.h and ieee802154/driver/
//! esp_ieee802154_{dev,pib,frame}.c (Apache-2.0). The public C6 TRM does
//! not specify the radio MAC. Clock/power control: TRM v1.2 §§8.2.4.4, 12.4.2.5.
//!
//! One stationary Radio, one calling task; methods are synchronous. Hardware
//! handles FCS and legacy ACK turnaround while software polls event status.
//! No IRQ is routed, no background RX queue is provided. Between receive calls
//! the MAC is idle. Wi-Fi/BLE coexistence, security and enhanced ACK generation
//! are not implemented. Init requires radio.protocol = .ieee802154 and RTOS.
const std = @import("std");
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
    promiscuous: bool = false,
    /// Legacy (frame version 0/1) ACKs only. Disabled in promiscuous RX.
    auto_ack: bool = true,
    cca_threshold: i8 = -75,
    cca_mode: enum(u2) { carrier = 0, energy = 1, carrier_or_energy = 2, carrier_and_energy = 3 } = .energy,
    tx: TxConfig = .{},
};

pub const Error = error{
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

    /// Initialize in place; do not copy or move the handle until deinit.
    pub fn init(self: *Radio, allocator: std.mem.Allocator, config: Config) InitError!void {
        if (microzig.options.hal.radio.ble)
            @compileError("IEEE 802.15.4 and BLE cannot run simultaneously: no RF coexistence scheduler");
        if (microzig.options.hal.radio.protocol != .ieee802154) return error.UnsupportedRadioProtocol;
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
        osi.phy_enable();
        // IDF esp_ieee802154_enable: PHY -> esp_btbb_enable -> MAC reset/init.
        // No BTBB teardown call exists in the blob; IDF disable only drops refs.
        bt_bb_v2_init_cmplx(0);
        clocks.ieee802154_mac_reset();
        configure_mac(config);
        ieee802154_txon_delay_set();
    }

    pub fn deinit(self: *Radio) void {
        if (!self.is_owner()) return;
        self.stop();
        // Hold MAC in reset before relinquishing DMA buffers, even after faults.
        clocks.ieee802154_mac_reset();
        mac.EVENT_EN.write(.{ .EVENT_EN = 0 });
        osi.phy_disable();
        clocks.ieee802154_clocks_set_enabled(false);
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
    pub fn receive(self: *Radio, timeout_us: u32) Error!Frame {
        try self.check();
        if (timeout_us == 0) return error.InvalidDuration;
        configure_mac(self.config);
        clear_events(Event.all);
        defer self.stop();
        var io: RxIo = .{ .device = self };
        return rx.receive(&io, timeout_us);
    }

    /// MAC bytes include FCF/sequence/address/payload, exclude length and FCS.
    /// Hardware inserts the FCS. ACK-request frames wait for a matching legacy
    /// ACK. Unslotted CSMA-CA is used when use_cca is true; missing ACKs retry
    /// with the same sequence number. Config.tx bounds both procedures. Returns
    /// the final outcome; last_tx_attempts excludes unsuccessful CCAs.
    pub fn transmit(self: *Radio, frame: []const u8, use_cca: bool) Error!TxResult {
        try self.check();
        try frames.validate_tx(frame);
        self.last_tx_attempts = 0;
        const ack = frame[0] & 0x20 != 0;
        configure_mac(self.config);
        // ACK reception must use the hardware TX->RX transition, even if the
        // user was previously sniffing. RX settings are restored by receive.
        mac.CTRL_CFG.modify(.{ .HW_AUTO_ACK_RX_EN = @intFromBool(ack), .PROMISCUOUS_MODE = 0 });
        self.tx_dma[0] = @intCast(frame.len + 2);
        @memcpy(self.tx_dma[1..][0..frame.len], frame);
        @memset(self.tx_dma[1 + frame.len ..][0..2], 0);
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
        command(if (use_cca) .cca_tx_start else .tx_start);
        defer self.stop();
        var io: TxCompletionIo = .{ .device = self, .sequence = frame[2] };
        return frames.tx.wait_for_completion(&io, ack, self.config.tx.ack_wait_symbols);
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
    sequence: u8,

    pub fn now(_: *TxCompletionIo) u64 {
        return time.get_time_since_boot().to_us();
    }

    pub fn poll(_: *TxCompletionIo) frames.tx.Events {
        const events = mac.EVENT_STATUS.read().EVENT_STATUS;
        const reason = mac.TX_STATUS.read().TX_ABORT_STATUS;
        clear_events(events);
        return .{
            .done = events & Event.tx_done != 0,
            .ack_done = events & Event.ack_rx_done != 0,
            .abort = if (events & Event.tx_abort != 0) reason else null,
        };
    }

    pub fn mark_sent(self: *TxCompletionIo) void {
        self.device.last_tx_attempts += 1;
    }

    pub fn validate_ack(self: *TxCompletionIo) error{InvalidFrame}!void {
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        // The MAC filters ACK type/sequence and FCS. Check DMA too so
        // a stale or malformed packet cannot be reported as success.
        if (dma_load(&self.device.rx_dma, 0) & 0x7f != 5 or
            dma_load(&self.device.rx_dma, 1) & 7 != 2 or
            dma_load(&self.device.rx_dma, 3) != self.sequence) return error.InvalidFrame;
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

    pub fn poll(_: *RxIo) rx.Events {
        const events = mac.EVENT_STATUS.read().EVENT_STATUS;
        const reason = mac.RX_STATUS.read().RX_ABORT_STATUS;
        clear_events(events);
        if (events & Event.rx_done != 0)
            asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        return .{
            .abort = if (events & Event.rx_abort != 0) reason else null,
            .done = events & Event.rx_done != 0,
            .ack_done = events & Event.ack_tx_done != 0,
        };
    }

    pub fn load(self: *RxIo, index: usize) u8 {
        return dma_load(&self.device.rx_dma, index);
    }

    pub fn auto_ack(self: *RxIo) bool {
        return self.device.config.auto_ack and !self.device.config.promiscuous;
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
    if (config.channel < 11 or config.channel > 26) return error.InvalidChannel;
    try config.tx.validate();
}

fn configure_mac(config: Config) void {
    mac.CHANNEL.modify(.{ .HOP = @as(u7, @intCast((config.channel - 11) * 5 + 3)) });
    mac.TX_POWER.modify(.{ .TX_POWER = frames.power_index(config.tx_power) });
    mac.CTRL_CFG.modify(.{
        .HW_AUTO_ACK_TX_EN = @intFromBool(config.auto_ack and !config.promiscuous),
        .HW_AUTO_ACK_RX_EN = 0,
        .HW_ENHANCE_ACK_TX_EN = 0,
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
