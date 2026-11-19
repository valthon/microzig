//! ESP32-C6 BLE controller/HCI, paired with the pinned ESP-IDF v5.5.1 blobs.
//! One controller per boot; storage and allocator must outlive it. No modem
//! sleep, pairing, or concurrent Wi-Fi. See the port README for evidence.
const std = @import("std");
const microzig = @import("microzig");
const c = @import("esp-wifi-driver");
const abi = @import("ble/abi.zig");
const npl = @import("ble/npl.zig");
const radio = @import("../radio.zig");
const rtos = @import("../rtos.zig");
const osi = @import("osi.zig");
const analog = @import("../analog/esp32_c6.zig");
const p = microzig.chip.peripherals;
const cs_enter = microzig.interrupt.enter_critical_section;
pub const host = @import("ble/host.zig");
const wire = @import("ble/protocol.zig");

pub const Error = radio.InitError || error{ AlreadyStarted, InvalidCpuClock, ControllerFailed, NotEnabled, InvalidPacket, NoBuffer, TransportFailed, ReceiveOverflow, Timeout };
pub const PacketKind = wire.PacketKind;
pub const Packet = wire.Packet;
const Isr = struct {
    source: microzig.cpu.interrupt.Source,
    callback: *const fn (?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
};
// Only the blob's C ABI uses this singleton. Application state belongs to Controller.
var active: ?*Controller = null;

pub const Controller = struct {
    npl_state: npl.State = undefined,
    queue: rtos.Queue(Packet) = undefined,
    storage: [16]Packet = undefined,
    overflow: bool = false,
    enabled: bool = false,
    isrs: [8]?Isr = @splat(null),

    /// Adapt this controller to the allocation-free Zig host.
    pub fn transport(self: *Controller) wire.Transport {
        return .{ .context = self, .send_command_fn = host_command, .send_acl_fn = host_acl, .receive_fn = host_receive, .now_ms_fn = host_now };
    }

    /// Start from task context. A failed start requires reboot: the closed
    /// controller does not offer a safe abort of partially created tasks.
    pub fn start(self: *Controller, allocator: std.mem.Allocator) Error!void {
        comptime {
            @export(&blob_putchar, .{ .name = "_putchar" });
            if (@import("../compatibility.zig").chip != .esp32_c6)
                @compileError("BLE controller is supported only on ESP32-C6");
            if (!microzig.options.hal.radio.ble)
                @compileError("select hal.radio.ble=true for exclusive BLE mode");
            microzig.cpu.interrupt.expect_handler(.interrupt29, interrupt_handler);
        }
        // C6 TRM §8.2.4.1: PLL root / 3, no extra HS divider or
        // 120 MHz force. This must match cfg.cpu_freq_mhz, not IDF's build
        // default: MicroZig's default CPU clock is 80 MHz.
        const cpu = p.PCR.CPU_FREQ_CONF.read();
        if (p.PCR.SYSCLK_CONF.read().SOC_CLK_SEL != 1 or cpu.CPU_HS_DIV_NUM != 0 or cpu.CPU_HS_120M_FORCE != 0)
            return error.InvalidCpuClock;
        {
            const cs = cs_enter();
            defer cs.leave();
            if (active != null) return error.AlreadyStarted;
            active = self;
        }
        self.queue = .init(&self.storage);
        self.npl_state = .{ .allocator = allocator };
        try radio.init(allocator);
        try self.npl_state.start();
        try checked(abi.esp_register_ext_funcs(&ext_funcs));
        try checked(abi.esp_register_npl_funcs(&npl.funcs));
        clocks_enable();
        var cfg = config();
        try checked(abi.ble_osi_coex_funcs_register(&coex_funcs));
        try checked(abi.esp_ble_register_bb_funcs());
        try checked(abi.r_ble_controller_init(&cfg));
        // IDF v5.5.1 ble.c: the feature stack environments are separate from
        // r_ble_controller_init, even in controller-only mode.
        try checked(abi.base_stack_initEnv());
        try checked(abi.conn_stack_initEnv());
        try checked(abi.adv_stack_initEnv());
        try checked(abi.extAdv_stack_initEnv());
        try checked(abi.sync_stack_initEnv());
        abi.r_filter_duplicate_mode_disable(0xffffffff);
        abi.r_filter_duplicate_mode_enable(5); // address + PDU type, bt.c
        abi.r_filter_duplicate_set_ring_list_max_num(100);
        try checked(abi.r_esp_ble_msys_init(128, 320, 12, 12, 1));
        // IDF v5.5.1 mac_addr.c: the pinned four-address configuration
        // assigns BT the base address plus two in its final octet.
        var mac = radio.read_mac(.sta);
        mac[5] +%= 2;
        std.mem.reverse(u8, &mac);
        try checked(abi.r_esp_ble_ll_set_public_addr(&mac));
        abi.r_ble_hci_trans_cfg_hs(receive_event, self, receive_acl, self);
        try phy_enable();
        abi.bt_bb_v2_init_cmplx(1);
        try checked(abi.base_stack_enable());
        try checked(abi.adv_stack_enable());
        try checked(abi.extAdv_stack_enable());
        try checked(abi.sync_stack_enable());
        try checked(abi.conn_stack_enable());
        try checked(abi.r_ble_controller_enable(1)); // ESP_BT_MODE_BLE
        self.enabled = true;
        _ = try rtos.spawn(allocator, track_phy, .{}, .{
            .name = "ble_phy",
            .priority = .lowest,
            .stack_size = 2048,
        });
    }

    /// HCI command without an H4 type byte; the transport copies it.
    /// Serialize commands and observe HCI command credits at the host layer.
    pub fn send_command(self: *Controller, data: []const u8) Error!void {
        if (!self.enabled) return error.NotEnabled;
        if (data.len < 3 or data.len > 258 or data.len != @as(usize, data[2]) + 3)
            return error.InvalidPacket;
        const buf = abi.r_ble_hci_trans_buf_alloc(3) orelse return error.NoBuffer;
        @memcpy(buf[0..data.len], data);
        // As in IDF hci_transport.c, ownership transfers even on a failed TX.
        if (abi.r_ble_hci_trans_hs_cmd_tx(buf) != 0) return error.TransportFailed;
    }

    /// ACL header + payload, without H4 type byte. The host owns ACL credits.
    pub fn send_acl(self: *Controller, data: []const u8) Error!void {
        if (!self.enabled) return error.NotEnabled;
        if (data.len < 4 or data.len > 259 or data.len != @as(usize, std.mem.readInt(u16, data[2..4], .little)) + 4)
            return error.InvalidPacket;
        // LE Host -> Controller accepts non-flushable starts or continuation,
        // without broadcast flags (Core Vol 4 Part E §5.4.2).
        if (std.mem.readInt(u16, data[0..2], .little) & 0xe000 != 0) return error.InvalidPacket;
        // IDF esp_hci_internal.h: reserve four user-header bytes for ACL.
        const mbuf = abi.r_os_msys_get_pkthdr(@intCast(data.len), 4) orelse return error.NoBuffer;
        if (abi.r_os_mbuf_append(mbuf, data.ptr, @intCast(data.len)) != 0) {
            _ = abi.r_os_mbuf_free_chain(mbuf);
            return error.NoBuffer;
        }
        if (abi.r_ble_hci_trans_hs_acl_tx(mbuf) != 0) return error.TransportFailed;
    }

    /// Single consumer. Overflow is explicit: reconnect/reset the host after
    /// packet loss rather than silently continuing with inconsistent credits.
    pub fn receive(self: *Controller, timeout_ms: u32) Error!Packet {
        {
            const cs = cs_enter();
            defer cs.leave();
            if (self.overflow) return error.ReceiveOverflow;
        }
        return self.queue.get_one(.{ .after = .from_ms(@min(timeout_ms, 4_000_000)) }) catch error.Timeout;
    }
};

fn host_command(context: *anyopaque, data: []const u8) wire.Error!void {
    const self: *Controller = @ptrCast(@alignCast(context));
    self.send_command(data) catch |err| return transport_error(err);
}
fn host_acl(context: *anyopaque, data: []const u8) wire.Error!void {
    const self: *Controller = @ptrCast(@alignCast(context));
    self.send_acl(data) catch |err| return transport_error(err);
}
fn host_receive(context: *anyopaque, timeout_ms: u32) wire.Error!Packet {
    const self: *Controller = @ptrCast(@alignCast(context));
    return self.receive(timeout_ms) catch |err| return transport_error(err);
}
fn host_now(_: *anyopaque) u64 {
    return @import("../time.zig").get_time_since_boot().to_us() / 1000;
}
fn transport_error(err: Error) wire.Error {
    return switch (err) {
        error.Timeout => error.Timeout,
        error.ReceiveOverflow => error.ReceiveOverflow,
        error.InvalidPacket => error.InvalidPacket,
        error.NoBuffer, error.OutOfMemory => error.NoBuffer,
        else => error.TransportFailed,
    };
}

fn checked(rc: c_int) error{ControllerFailed}!void {
    if (rc != 0) return error.ControllerFailed;
}
// The bundled tiny printf uses this output hook. Suppress blob diagnostics,
// as osi.putchar does for Wi-Fi; controller assertions still panic explicitly.
fn blob_putchar(_: u8) callconv(.c) void {}
fn push(self: *Controller, packet: Packet) c_int {
    var hptw = false;
    if (!self.queue.put_one_from_isr(packet, &hptw)) {
        const cs = cs_enter();
        defer cs.leave();
        self.overflow = true;
    }
    if (hptw) rtos.yield_from_isr();
    return 0;
}
fn receive_event(data: [*]u8, arg: ?*anyopaque) callconv(.c) c_int {
    defer abi.r_ble_hci_trans_buf_free(data);
    const self: *Controller = @ptrCast(@alignCast(arg));
    var packet: Packet = .{ .kind = .event, .len = @as(u16, data[1]) + 2, .bytes = undefined };
    @memcpy(packet.bytes[0..packet.len], data[0..packet.len]);
    return push(self, packet);
}
fn receive_acl(mbuf: *abi.Mbuf, arg: ?*anyopaque) callconv(.c) c_int {
    defer _ = abi.r_os_mbuf_free_chain(mbuf);
    const self: *Controller = @ptrCast(@alignCast(arg));
    // os_mbuf_pkthdr immediately follows os_mbuf; it is not at om_data.
    const header: *const abi.PacketHeader = @ptrFromInt(@intFromPtr(mbuf) + @sizeOf(abi.Mbuf));
    var packet: Packet = .{ .kind = .acl, .len = header.len, .bytes = undefined };
    if (packet.len > packet.bytes.len or abi.r_os_mbuf_copydata(mbuf, 0, packet.len, &packet.bytes) != 0) {
        const cs = cs_enter();
        defer cs.leave();
        self.overflow = true;
        return 0;
    }
    return push(self, packet);
}

const ext_funcs: abi.ExtFuncs = .{
    .intr_alloc = intr_alloc,
    .intr_free = intr_free,
    .malloc = osi.malloc,
    .free = osi.free,
    .task_create = osi.task_create_pinned_to_core,
    .task_delete = osi.task_delete,
    .assert = controller_assert,
    .random = osi.rand,
    .ecc_key = no_ecc_key,
    .ecc_dh = no_ecc_dh,
    .reset_modem = reset_modem,
};
const coex_funcs: abi.CoexFuncs = .{ .set = no_coex, .clear = no_coex };
fn no_coex(_: u32, _: u32) callconv(.c) void {}
fn no_ecc_key(_: [*]u8, _: [*]u8) callconv(.c) c_int {
    return -1;
}
fn no_ecc_dh(_: [*]const u8, _: [*]const u8, _: [*]const u8, _: [*]u8) callconv(.c) c_int {
    return -1;
}
fn controller_assert(_: u32, _: [*:0]const u8, _: u32, _: u32) callconv(.c) void {
    @panic("BLE controller assertion");
}
fn intr_alloc(source: c_int, _: c_int, callback: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque, out: *?*anyopaque) callconv(.c) c_int {
    // IDF v5.5.1 soc/esp32c6/include/soc/interrupts.h: 4 BT_MAC, 5 BT_BB,
    // 7 LP_TIMER (the controller's hal timer, from r_ble_controller_enable),
    // 9 BLE_TIMER, 10 BLE_SEC. This port routes neither 6 BT_BB_NMI (no NMI
    // handling) nor 8 COEX (no coexistence); a request for either is an error.
    switch (source) {
        4, 5, 7, 9, 10 => {},
        else => {
            std.log.scoped(.esp_ble).err("controller requested unsupported interrupt source {d}", .{source});
            return -1;
        },
    }
    const self = active orelse return -1;
    const cs = cs_enter();
    defer cs.leave();
    for (&self.isrs) |*slot| {
        if (slot.* != null) continue;
        const src: microzig.cpu.interrupt.Source = @fromBackingInt(@as(u7, @intCast(source)));
        slot.* = .{ .source = src, .callback = callback, .arg = arg };
        out.* = slot;
        microzig.cpu.interrupt.map(src, .interrupt29);
        microzig.cpu.interrupt.set_type(.interrupt29, .level);
        microzig.cpu.interrupt.set_priority(.interrupt29, .highest);
        microzig.cpu.interrupt.enable(.interrupt29);
        return 0;
    }
    return -1;
}
fn intr_free(handle: *?*anyopaque) callconv(.c) c_int {
    const slot: *?Isr = @ptrCast(@alignCast(handle.* orelse return -1));
    const cs = cs_enter();
    defer cs.leave();
    if (slot.*) |isr| microzig.cpu.interrupt.map(isr.source, null);
    slot.* = null;
    handle.* = null;
    return 0;
}
pub const interrupt_handler: microzig.cpu.InterruptHandler = .{ .c = struct {
    fn handler(_: *microzig.cpu.TrapFrame) linksection(".ram_text") callconv(.c) void {
        const self = active orelse return;
        const status = microzig.cpu.interrupt.Status.init();
        for (self.isrs) |slot| if (slot) |isr| {
            if (status.is_set(isr.source)) isr.callback(isr.arg);
        };
    }
}.handler };

// C6 TRM v1.2 §8.2.4.4, §8.5 MODEM_SYSCON/LPCON clock/reset
// registers; sequence and crystal divider from IDF v5.5.1 modem_clock.c,
// modem_syscon_ll.h and bt.c esp_bt_rtc_slow_clk_select.
fn clocks_enable() void {
    const cs = cs_enter();
    defer cs.leave();
    p.MODEM_SYSCON.CLK_CONF.modify(.{
        .CLK_MODEM_SEC_EN = 1,
        .CLK_MODEM_SEC_ECB_EN = 1,
        .CLK_MODEM_SEC_CCM_EN = 1,
        .CLK_MODEM_SEC_BAH_EN = 1,
        .CLK_MODEM_SEC_APB_EN = 1,
        .CLK_BLE_TIMER_EN = 1,
        .CLK_ETM_EN = 1,
    });
    p.MODEM_SYSCON.CLK_CONF1.modify(.{ .CLK_BT_APB_EN = 1, .CLK_BT_EN = 1 });
    p.MODEM_LPCON.CLK_CONF.modify(.{ .CLK_COEX_EN = 1, .CLK_LP_TIMER_EN = 1 });
    p.MODEM_LPCON.LP_TIMER_CONF.modify(.{
        .CLK_LP_TIMER_SEL_OSC_SLOW = 0,
        .CLK_LP_TIMER_SEL_OSC_FAST = 0,
        .CLK_LP_TIMER_SEL_XTAL = 1,
        .CLK_LP_TIMER_SEL_XTAL32K = 0,
        .CLK_LP_TIMER_DIV_NUM = 399,
    });
    p.MODEM_SYSCON.MODEM_RST_CONF.modify(.{ .RST_BTMAC = 1, .RST_BTMAC_APB = 1, .RST_BLE_TIMER = 1, .RST_MODEM_SEC = 1 });
    p.MODEM_SYSCON.MODEM_RST_CONF.modify(.{ .RST_BTMAC = 0, .RST_BTMAC_APB = 0, .RST_BLE_TIMER = 0, .RST_MODEM_SEC = 0 });
}
fn reset_modem(opts: u8, start: u8) callconv(.c) void {
    if (opts != 5 or start == 0) return;
    const cs = cs_enter();
    defer cs.leave();
    // IDF bt.c toggles bits 16 (BT BB) and 18 (BT BB APB).
    p.MODEM_SYSCON.MODEM_RST_CONF.modify(.{ .RST_BTBB = 1, .RST_BTBB_APB = 1 });
    p.MODEM_SYSCON.MODEM_RST_CONF.modify(.{ .RST_BTBB = 0, .RST_BTBB_APB = 0 });
}
extern fn phy_init_param_set(u8) void;
extern fn phy_bbpll_en_usb(bool) void;
extern fn phy_param_track_tot(bool, bool) void;
fn phy_enable() Error!void {
    analog.phy_clocks_set_enabled(true);
    analog.calibration_clocks_set_enabled(true);
    defer {
        analog.calibration_clocks_set_enabled(false);
        const cs = cs_enter();
        defer cs.leave();
        p.MODEM_SYSCON.CLK_CONF1.modify(.{ .CLK_BT_APB_EN = 1, .CLK_BT_EN = 1 });
    }
    phy_init_param_set(1);
    phy_bbpll_en_usb(true);
    var calibration: c.esp_phy_calibration_data_t = std.mem.zeroes(c.esp_phy_calibration_data_t);
    // IDF v5.5.1 esp_private/phy.h: 1 is ESP_CAL_DATA_CHECK_FAIL, reported
    // whenever the supplied calibration data is invalid, as it always is
    // here (zeroed). Full calibration still runs; phy_init.c only uses the
    // code to decide whether to store new data, and other values are reserved.
    _ = c.register_chipv7_phy(@ptrCast(&phy_data), &calibration, c.PHY_RF_CAL_FULL);
    phy_param_track_tot(false, true);
}
// IDF esp_phy/esp32c6/phy_init_data.h, same limits as the Wi-Fi adapter.
const phy_data: [128]u8 = blk: {
    var data: [128]u8 = @splat(0);
    data[0] = 0x0a;
    data[2..20].* = .{ 0x50, 0x50, 0x50, 0x50, 0x50, 0x4c, 0x4c, 0x4c, 0x4c, 0x48, 0x44, 0x3c, 0x3c, 0x3c, 0x4c, 0x4c, 0x4c, 0x48 };
    data[127] = 0x51;
    break :blk data;
};
fn track_phy() void {
    while (true) {
        rtos.sleep(.from_ms(1000));
        phy_param_track_tot(false, true);
    }
}
fn config() abi.Config {
    var cfg = std.mem.zeroes(abi.Config);
    cfg.config_version = 0x20250606;
    cfg.config_magic = 0x5a5aa5a5;
    cfg.ble_ll_resolv_list_size = 4;
    cfg.ble_hci_evt_hi_buf_count = 16;
    cfg.ble_hci_evt_lo_buf_count = 8;
    cfg.ble_ll_sync_list_cnt = 5;
    cfg.ble_ll_sync_cnt = 1;
    cfg.ble_ll_rsp_dup_list_count = 20;
    cfg.ble_ll_adv_dup_list_count = 20;
    cfg.rtc_freq = 100_000; // XTAL 40 MHz / 400, bt.c default LP clock
    cfg.ble_ll_sca = 60;
    // IDF v5.5.1 Kconfig BT_LE_DFT_TX_POWER_LEVEL_DBM defaults to +9 dBm for both fields
    // (esp_bt.h BT_CONTROLLER_INIT_CONFIG_DEFAULT). Zeroed, they meant 0 dBm, and peers often
    // missed the initiator's CONNECT_IND, which is sent once and never retransmitted.
    cfg.ble_ll_tx_pwr_dbm = 9;
    cfg.ch39_txpwr = 9;
    cfg.ble_ll_scan_phy_number = 1;
    cfg.ble_ll_conn_def_auth_pyld_tmo = 3000;
    cfg.ble_ll_jitter_usecs = 16;
    cfg.ble_ll_sched_max_adv_pdu_usecs = 376;
    cfg.ble_ll_sched_direct_adv_max_usecs = 502;
    cfg.ble_ll_sched_adv_max_usecs = 852;
    cfg.ble_scan_rsp_data_max_len = 31;
    cfg.ble_ll_cfg_num_hci_cmd_pkts = 1;
    cfg.ble_ll_ctrl_proc_timeout_ms = 40000;
    cfg.nimble_max_connections = 1;
    cfg.ble_whitelist_size = 8;
    cfg.ble_acl_buf_size = 255;
    cfg.ble_acl_buf_count = 12;
    cfg.ble_hci_evt_buf_size = 257;
    cfg.ble_multi_adv_instances = 1;
    cfg.ble_ext_adv_max_size = 31;
    cfg.controller_task_stack_size = 8192;
    cfg.controller_task_prio = @intCast(@min(@as(u32, 23), @as(u32, @backingInt(rtos.Priority.highest))));
    cfg.cca_rssi_thresh = 196;
    cfg.ble_scan_classify_filter_enable = 1;
    cfg.main_xtal_freq = 40;
    // IDF efuse_hal_chip_revision = major * 100 + minor; C6 TRM §6
    // EFUSE_RD_MAC_SPI_SYS_3 contains WAFER_VERSION_{MAJOR,MINOR}.
    const efuse = @import("../efuse.zig");
    cfg.version_num = @as(u32, efuse.read(.{ .block = 1, .bit_offset = 118, .bit_length = 2 })) * 100 +
        efuse.read(.{ .block = 1, .bit_offset = 114, .bit_length = 4 });
    cfg.cpu_freq_mhz = 160;
    cfg.csa2_select = 1;
    cfg.scan_backoff_upperlimitmax = 256;
    cfg.vhci_enabled = 1;
    cfg.fast_conn_data_tx_en = 1;
    cfg.adv_rsv_cnt = 1;
    cfg.conn_rsv_cnt = 1;
    return cfg;
}
