const std = @import("std");
const assert = std.debug.assert;

pub const c = @import("esp-wifi-driver");
const microzig = @import("microzig");
const wifi_options = microzig.options.hal.radio.wifi;
const time = microzig.drivers.time;

const radio = @import("../radio.zig");
const osi = @import("osi.zig");
const wifi_status = @import("wifi_status.zig");
const compatibility = @import("../compatibility.zig");
const hal_time = @import("../time.zig");
const rtos = @import("../rtos.zig");

const log = std.log.scoped(.esp_radio_wifi);

pub const Options = struct {
    on_event: ?*const fn (e: Event) void = null,
    on_packet_received: ?*const fn (comptime interface: Interface, data: []const u8) void = null,
    /// Called by the Wi-Fi driver when a transmission completes; `status` is false if it
    /// failed. `data` is the 802.11 frame as the driver sent it, not the Ethernet frame given
    /// to `send_packet`: MAC header, the CCMP header on a protected link, LLC/SNAP, payload.
    /// The station's EAPOL handshake frames arrive here too. `data` ends before the frame
    /// does: on a WPA2 link a 60-byte Ethernet frame (46-byte payload after a 26-byte QoS
    /// header, CCMP header and LLC/SNAP) came back as 74 bytes on an ESP32-C3 and 70 on an
    /// ESP32-C6, so the last 14 (C3) or 18 (C6) payload bytes were not in the slice; 100- and
    /// 300-byte frames were cut by the same amounts. Payload near the tail is not visible.
    /// Search for a marker near the start of the payload rather than compute offsets from
    /// the length.
    on_packet_transmitted: ?*const fn (interface: Interface, data: []const u8, status: bool) void = null,
};

const InitError = radio.InitError || PowerSaveError || error{UnsupportedRadioProtocol};

pub const InitConfig = struct {
    /// Power save mode. Only `.none` is supported on the ESP32-C6.
    power_save_mode: PowerSaveMode = .none,

    /// Country info. If .auto the country info of the AP to which the station
    /// is connected is used.
    country_info: CountryInfo = .auto,
    /// Set maximum transmitting power after WiFi start.
    /// TODO: explain what values are valid
    /// TODO: should it be part of country info?
    max_tx_power: i8 = 20,

    /// Max number of WiFi static RX buffers.
    ///
    /// Each buffer takes approximately 1.6KB of RAM. The static rx buffers are
    /// allocated when esp_wifi_init is called, they are not freed until
    /// esp_wifi_deinit is called.
    ///
    /// WiFi hardware use these buffers to receive all 802.11 frames. A higher
    /// number may allow higher throughput but increases memory use. If
    /// [`Self::ampdu_rx_enable`] is enabled, this value is recommended to set
    /// equal or bigger than [`Self::rx_ba_win`] in order to achieve better
    /// throughput and compatibility with both stations and APs.
    static_rx_buf_num: u8 = 10,

    /// Max number of WiFi dynamic RX buffers
    ///
    /// Set the number of WiFi dynamic RX buffers, 0 means unlimited RX buffers
    /// will be allocated (provided sufficient free RAM). The size of each
    /// dynamic RX buffer depends on the size of the received data frame.
    ///
    /// For each received data frame, the WiFi driver makes a copy to an RX
    /// buffer and then delivers it to the high layer TCP/IP stack. The dynamic
    /// RX buffer is freed after the higher layer has successfully received the
    /// data frame.
    ///
    /// For some applications, WiFi data frames may be received faster than the
    /// application can process them. In these cases we may run out of memory
    /// if RX buffer number is unlimited (0).
    ///
    /// If a dynamic RX buffer limit is set, it should be at least the number
    /// of static RX buffers.
    dynamic_rx_buf_num: u16 = 32,

    /// Set the number of WiFi static TX buffers.
    ///
    /// Each buffer takes approximately 1.6KB of RAM. The static RX buffers are
    /// allocated when esp_wifi_init() is called, they are not released until
    /// esp_wifi_deinit() is called.
    ///
    /// For each transmitted data frame from the higher layer TCP/IP stack, the
    /// WiFi driver makes a copy of it in a TX buffer.
    ///
    /// For some applications especially UDP applications, the upper layer can
    /// deliver frames faster than WiFi layer can transmit. In these cases, we
    /// may run out of TX buffers.
    static_tx_buf_num: u8 = 0,

    /// Set the number of WiFi dynamic TX buffers.
    ///
    /// The size of each dynamic TX buffer is not fixed, it depends on the size
    /// of each transmitted data frame.
    ///
    /// For each transmitted frame from the higher layer TCP/IP stack, the WiFi
    /// driver makes a copy of it in a TX buffer.
    ///
    /// For some applications, especially UDP applications, the upper layer can
    /// deliver frames faster than WiFi layer can transmit. In these cases, we
    /// may run out of TX buffers.
    dynamic_tx_buf_num: u16 = 32,

    /// Select this option to enable AMPDU RX feature.
    ampdu_rx_enable: bool = true,

    /// Select this option to enable AMPDU TX feature.
    ampdu_tx_enable: bool = true,

    /// Select this option to enable AMSDU TX feature.
    amsdu_tx_enable: bool = false,

    /// Set the size of WiFi Block Ack RX window.
    ///
    /// Generally a bigger value means higher throughput and better
    /// compatibility but more memory. Most of time we should NOT change the
    /// default value unless special reason, e.g. test the maximum UDP RX
    /// throughput with iperf etc. For iperf test in shieldbox, the recommended
    /// value is 9~12.
    ///
    /// If PSRAM is used and WiFi memory is preferred to allocate in PSRAM
    /// first, the default and minimum value should be 16 to achieve better
    /// throughput and compatibility with both stations and APs.
    rx_ba_win: u8 = 6,

    pub const CountryInfo = union(enum) {
        auto,
        manual: struct {
            /// Country code.
            country_code: *const [2]u8 = "01",
            /// Start channel of the allowed 2.4GHz Wi-Fi channels.
            start_channel: u8 = 1,
            /// Total channel number of the allowed 2.4GHz Wi-Fi channels.
            total_channel_number: u8 = 11,
        },

        fn get_wifi_country_t(info: CountryInfo, max_tx_power: i8) c.wifi_country_t {
            return switch (info) {
                .auto => .{
                    .cc = .{ '0', '1', 0 },
                    .schan = 1,
                    .nchan = 11,
                    .max_tx_power = max_tx_power,
                    .policy = c.WIFI_COUNTRY_POLICY_AUTO,
                },
                .manual => |manual_info| .{
                    .cc = manual_info.country_code.* ++ .{0},
                    .schan = manual_info.start_channel,
                    .nchan = manual_info.total_channel_number,
                    .max_tx_power = max_tx_power,
                    .policy = c.WIFI_COUNTRY_POLICY_MANUAL,
                },
            };
        }
    };
};

pub fn init(gpa: std.mem.Allocator, config: InitConfig) InitError!void {
    if (comptime microzig.options.hal.radio.ble)
        @compileError("Wi-Fi and BLE cannot run simultaneously: hal.radio.ble selects exclusive BLE mode");
    comptime export_symbols();

    if (microzig.options.hal.radio.protocol != .wifi) return error.UnsupportedRadioProtocol;

    if (compatibility.chip == .esp32_c6 and config.power_save_mode != .none)
        return error.PowerSaveUnsupported;

    try radio.init(gpa);

    {
        init_config.wpa_crypto_funcs = c.g_wifi_default_wpa_crypto_funcs;
        init_config.feature_caps = g_wifi_feature_caps;
        init_config.static_rx_buf_num = config.static_rx_buf_num;
        init_config.dynamic_rx_buf_num = config.dynamic_rx_buf_num;
        init_config.static_tx_buf_num = config.static_tx_buf_num;
        init_config.dynamic_tx_buf_num = config.dynamic_tx_buf_num;
        init_config.ampdu_rx_enable = @intFromBool(config.ampdu_rx_enable);
        init_config.ampdu_tx_enable = @intFromBool(config.ampdu_tx_enable);
        init_config.amsdu_tx_enable = @intFromBool(config.amsdu_tx_enable);
        init_config.rx_ba_win = config.rx_ba_win;
    }

    // TODO: if coex enabled
    if (false) try c_err(c.coex_init());

    try c_err(c.esp_wifi_init_internal(&init_config));

    try c_err(c.esp_wifi_set_mode(c.WIFI_MODE_NULL));

    try c_err(c.esp_supplicant_init());

    try c_err(c.esp_wifi_set_tx_done_cb(tx_done_cb));
    try c_err(c.esp_wifi_internal_reg_rxcb(c.ESP_IF_WIFI_AP, recv_cb_ap));
    try c_err(c.esp_wifi_internal_reg_rxcb(c.ESP_IF_WIFI_STA, recv_cb_sta));

    {
        const country_info = config.country_info.get_wifi_country_t(config.max_tx_power);
        try c_err(c.esp_wifi_set_country(&country_info));
    }

    try set_power_save_mode(config.power_save_mode);
    if (compatibility.chip == .esp32_c6) @import("../analog/esp32_c6.zig").wifi_set_inited(true);
}

pub const DeinitError = InternalError;

/// Stops Wi-Fi as `stop` does, leaving the AP first, then releases the driver and the radio. A
/// stop running in another task returns first; a stop called while this runs waits until it has
/// returned and then, if this released the driver, gets `error.WifiNotInitialized` from
/// `esp_wifi_stop`.
///
/// Returns `error.Timeout` if the running stop has not returned within 5 s, which in the runs
/// only a stop called from `on_event` caused, and `error.WifiStopping` if the calling task's own
/// stop is running (a call from an event that stop posted); Wi-Fi is then untouched. It also
/// returns the error of `esp_wifi_deinit_internal` unless that is `ESP_ERR_WIFI_NOT_INIT`, since
/// the driver is then still initialised. That error comes after the stop: the station has left
/// the AP and Wi-Fi has been stopped, unless the error is `ESP_ERR_WIFI_NOT_STOPPED` (below):
/// Wi-Fi is still started. Either way it releases nothing: the driver and the radio stay
/// initialised, and the driver keeps allocating from the allocator given to `init`. Keep that
/// allocator's memory, and anything else lent to the driver or to a network stack on it, until
/// a later `deinit` returns without an error.
///
/// `esp_wifi_deinit_internal` (C3 and C6 libnet80211.a) returns `ESP_ERR_WIFI_NOT_STOPPED`
/// while Wi-Fi is started, as after a failed `esp_wifi_stop` (+0x18..0x46), the errors of its
/// API lock (+0x0c..0x16) and `ESP_ERR_WIFI_INIT_STATE` during another init or deinit
/// (+0x80..0xc0) before it changes any state; after `ESP_ERR_NO_MEM` (+0x132) or a failed
/// request to the Wi-Fi task (+0xf0..0xfa) it sets its state back to initialised
/// (+0x136..0x140). `ESP_ERR_WIFI_NOT_INIT` (+0x6e..0x7e) leaves no driver to release, and the
/// radio is released as after a success. The results of `esp_wifi_stop`, which a started
/// driver then reports as `ESP_ERR_WIFI_NOT_STOPPED`, and of `esp_supplicant_deinit` are
/// ignored.
pub fn deinit() DeinitError!void {
    try begin_stop();
    defer end_stop();
    _ = stop_leaving_ap();
    const status = c.esp_wifi_deinit_internal();
    if (status != c.ESP_ERR_WIFI_NOT_INIT) try c_err(status);
    _ = c.esp_supplicant_deinit();
    if (compatibility.chip == .esp32_c6) @import("../analog/esp32_c6.zig").wifi_set_inited(false);

    radio.deinit();
}

pub const ConfigError = InternalError || error{
    InvalidConfig,
};

pub const Config = union(enum) {
    ap: AccessPoint,
    sta: Station,
    ap_sta: struct {
        ap: AccessPoint,
        sta: Station,
    },
    // TODO: eap_sta

    pub const AccessPoint = struct {
        /// The SSID of the access point.
        ssid: []const u8,

        /// The password of the access point.
        password: []const u8 = "",

        /// Whether the SSID is hidden or visible.
        ssid_hidden: bool = false,

        /// The channel the access point will operate on. Ignored in `ap_sta`
        /// mode.
        channel: u8,

        /// The secondary channel configuration.
        secondary_channel: ?u8 = null,

        /// Authentication config to be used by the access point.
        auth_method: AuthMethod = .none,

        /// The maximum number of connections allowed on the access point.
        max_connections: u8,
    };

    pub const Station = struct {
        /// The SSID of the Wi-Fi network.
        ssid: []const u8,

        /// The password of the Wi-Fi network.
        password: []const u8 = "",

        /// The BSSID (MAC address) of the client.
        bssid: ?[6]u8 = null,

        /// Authentication config for the Wi-Fi connection.
        auth_method: AuthMethod = .none,

        /// The Wi-Fi channel to connect to.
        channel: u8 = 0,

        scan_method: ScanMethod = .fast,

        listen_interval: u16 = 3,

        failure_retry_cnt: u8 = 1,

        pub const ScanMethod = enum(u32) {
            fast = c.WIFI_FAST_SCAN,
            all_channel = c.WIFI_ALL_CHANNEL_SCAN,
        };
    };
};

pub fn apply(config: Config) ConfigError!void {
    switch (config) {
        .ap => |ap_config| {
            try set_mode(.ap);
            try apply_access_point_config(ap_config);
        },
        .sta => |sta_config| {
            try set_mode(.sta);
            try apply_station_config(sta_config);
        },
        .ap_sta => |ap_sta_config| {
            try set_mode(.ap_sta);
            try apply_access_point_config(ap_sta_config.ap);
            try apply_station_config(ap_sta_config.sta);
        },
    }
}

pub const WifiMode = enum(u32) {
    /// No interface. `init` selects it, and `start` succeeds in it.
    none = c.WIFI_MODE_NULL,
    sta = c.WIFI_MODE_STA,
    ap = c.WIFI_MODE_AP,
    ap_sta = c.WIFI_MODE_APSTA,

    pub fn is_sta(self: WifiMode) bool {
        return self == .sta or self == .ap_sta;
    }

    pub fn is_ap(self: WifiMode) bool {
        return self == .ap or self == .ap_sta;
    }
};

pub fn get_mode() InternalError!WifiMode {
    var mode: c.wifi_mode_t = undefined;
    try c_err(c.esp_wifi_get_mode(&mode));
    return @fromBackingInt(mode);
}

pub fn set_mode(mode: WifiMode) InternalError!void {
    try c_err(c.esp_wifi_set_mode(@backingInt(mode)));
}

fn apply_access_point_config(config: Config.AccessPoint) ConfigError!void {
    if (config.ssid.len > 32) {
        return error.InvalidConfig;
    }
    if (config.password.len > 64) {
        return error.InvalidConfig;
    }

    var ap_cfg: c_patched.wifi_ap_config_t = .{
        .ssid_len = @intCast(config.ssid.len),
        .channel = config.channel,
        .authmode = @backingInt(config.auth_method),
        .ssid_hidden = @intFromBool(config.ssid_hidden),
        .max_connection = config.max_connections,
        .beacon_interval = 100,
        .pairwise_cipher = c.WIFI_CIPHER_TYPE_CCMP,
        .ftm_responder = false,
        .pmf_cfg = .{
            .capable = true,
            .required = false,
        },
        .sae_pwe_h2e = 0,
        .csa_count = 3,
        .dtim_period = 2,
    };

    @memcpy(ap_cfg.ssid[0..config.ssid.len], config.ssid);
    @memcpy(ap_cfg.password[0..config.password.len], config.password);

    var tmp: c_patched.wifi_config_t = .{ .ap = ap_cfg };
    try c_err(c_patched.esp_wifi_set_config(c.WIFI_IF_AP, &tmp));
}

/// Applies `config` to the station interface without changing the mode, unlike `apply`,
/// which also sets it. `esp_wifi_set_config` also clears the blob's station blacklist
/// (`wifi_set_config_process+0x78`, C3 and C6 libnet80211.a). While the station is connecting it
/// returns `error.WifiState` (`wifi_set_config_process+0x36..0x58`). Applied to a connected
/// station, it was accepted and a `StaDisconnected` (reason 8) followed within milliseconds.
pub fn apply_station_config(config: Config.Station) ConfigError!void {
    if (config.ssid.len > 32) {
        return error.InvalidConfig;
    }
    if (config.password.len > 64) {
        return error.InvalidConfig;
    }

    var sta_cfg: c_patched.wifi_sta_config_t = .{
        .scan_method = @backingInt(config.scan_method),
        .bssid_set = config.bssid != null,
        .bssid = config.bssid orelse @splat(0),
        .channel = config.channel,
        .listen_interval = config.listen_interval,
        .sort_method = c.WIFI_CONNECT_AP_BY_SIGNAL,
        .threshold = .{
            .rssi = -99,
            .authmode = @backingInt(config.auth_method),
            .rssi_5g_adjustment = 0,
        },
        .pmf_cfg = .{
            .capable = true,
            .required = false,
        },
        .sae_pwe_h2e = 3,
        .failure_retry_cnt = config.failure_retry_cnt,
    };

    @memcpy(sta_cfg.ssid[0..config.ssid.len], config.ssid);
    @memcpy(sta_cfg.password[0..config.password.len], config.password);

    var tmp: c_patched.wifi_config_t = .{ .sta = sta_cfg };
    try c_err(c_patched.esp_wifi_set_config(c.WIFI_IF_STA, &tmp));
}

pub const PowerSaveMode = enum(u32) {
    none = c.WIFI_PS_NONE,
    min = c.WIFI_PS_MIN_MODEM,
    max = c.WIFI_PS_MAX_MODEM,
};

pub const PowerSaveError = InternalError || error{
    /// Modem sleep needs the sleep retention hooks, which aren't ported on the ESP32-C6.
    PowerSaveUnsupported,
};

pub fn set_power_save_mode(mode: PowerSaveMode) PowerSaveError!void {
    if (compatibility.chip == .esp32_c6 and mode != .none) return error.PowerSaveUnsupported;
    try c_err(c.esp_wifi_set_ps(@backingInt(mode)));
}

pub const Protocol = enum(u8) {
    /// 802.11b protocol.
    P802D11B = c.WIFI_PROTOCOL_11B,

    /// 802.11b/g protocol.
    P802D11BG = c.WIFI_PROTOCOL_11B | c.WIFI_PROTOCOL_11G,

    /// 802.11b/g/n protocol (default).
    P802D11BGN = c.WIFI_PROTOCOL_11B | c.WIFI_PROTOCOL_11G | c.WIFI_PROTOCOL_11N,

    /// 802.11b/g/n long-range (LR) protocol.
    P802D11BGNLR = c.WIFI_PROTOCOL_11B | c.WIFI_PROTOCOL_11G | c.WIFI_PROTOCOL_11N | c.WIFI_PROTOCOL_LR,

    /// 802.11 long-range (LR) protocol.
    P802D11LR = c.WIFI_PROTOCOL_LR,

    /// 802.11b/g/n/ax protocol.
    P802D11BGNAX = c.WIFI_PROTOCOL_11B | c.WIFI_PROTOCOL_11G | c.WIFI_PROTOCOL_11N | c.WIFI_PROTOCOL_11AX,
};

pub fn set_protocol(protocols: []const Protocol) InternalError!void {
    var combined: u8 = 0;
    for (protocols) |protocol| {
        combined |= @backingInt(protocol);
    }

    const mode = try get_mode();
    // With no interface in the mode there is nothing to configure, as `connect`
    // without a station.
    if (mode == .none) return error.WifiMode;
    if (mode.is_sta()) {
        try c_err(c.esp_wifi_set_protocol(c.WIFI_IF_STA, combined));
    }
    if (mode.is_ap()) {
        try c_err(c.esp_wifi_set_protocol(c.WIFI_IF_AP, combined));
    }
}

/// Set the inactive time in seconds of the STA or AP.
///
/// 1. For Station, if the station does not receive a beacon frame from the
/// connected SoftAP during the inactive time, disconnect from SoftAP. Default
/// 6s. Must be at least 3s.
///
/// 2. For SoftAP, if the softAP doesn't receive any data from the connected
/// STA during inactive time, the softAP will force deauth the STA. Default is
/// 300s. Must be at least 10s.
pub fn set_inactive_time(interface: Interface, inactive_time: u16) InternalError!void {
    try c_err(c.esp_wifi_set_inactive_time(
        @backingInt(interface),
        inactive_time,
    ));
}

/// Non-blocking.
pub fn start() InternalError!void {
    try c_err(c.esp_wifi_start());
}

/// Non-blocking unless the station is connected or connecting, or another stop runs. Such a
/// station leaves the AP first: `stop` calls `disconnect`, waits for the `StaDisconnected`
/// (reason 8, `WIFI_REASON_ASSOC_LEAVE`; at most 1 s when connected, 100 ms when connecting),
/// waits 100 ms more, then calls `esp_wifi_stop`, which posts `StaStop`. A station is connecting
/// from the `connect` that the blob accepts until the `StaConnected`, `StaDisconnected` or
/// `StaStop` that follows; a `disconnect` before the station has left scanning posts none of
/// them, and the next stop then calls `disconnect` again and waits the 100 ms for nothing, as
/// it can after an attempt whose event came before its `connect` returned (see
/// `sta_connecting`). From the start of a stop until it returns, `connect` returns
/// `error.WifiStopping`, so an application that connects again on `StaDisconnected` gets that
/// error instead of a connect the stop cancels; a stop first waits for connects that began
/// before it to return. Stops, and `deinit`, run one at a time: a later one waits until the
/// running one has returned, then stops what is left (nothing, if the first stopped the
/// station; after `deinit`, `esp_wifi_stop` returns `error.WifiNotInitialized`). A stop waits
/// at most 5 s for the running one, then returns `error.Timeout` with a warning, without
/// stopping.
///
/// Do not call `stop` or `deinit` from `on_event`. `on_event` runs in the task that posts the
/// event (`osi.esp_event_post` calls it directly), which for the station events was the Wi-Fi
/// task, and a stop waits for connects in flight, for the `StaDisconnected` and for another
/// stop. Called there on `StaConnected` or `StaDisconnected`, even with no connect in flight,
/// `esp_wifi_stop` blocked for seconds and the board usually trapped afterwards ("unhandled
/// trap"; Super Mini ESP32-C6 and ESP32-C3), as it did on the base HAL with a connect in flight.
/// Called there while another task's stop waits for the Wi-Fi task, in its `disconnect` or its
/// `esp_wifi_stop`, it blocks that stop until its own 5 s wait for it ends; called in a task
/// whose own stop posted the event, it returns `error.WifiStopping` with a warning.
///
/// `esp_wifi_stop` on a connected station sends the disassociation from inside the stop:
/// `wifi_stop_process` calls `ieee80211_set_hmac_stop` (+0x26), then `_do_wifi_stop` (+0x30),
/// whose `wifi_station_stop` sends it (`wifi_disconnect_process`, +0x5a) and then removes the
/// station interface (`ic_set_vif`, +0x74; C3 and C6 libnet80211.a). Sniffed against a
/// Pico 2 W AP, the stopping station repeated that disassociation dozens of times over tens of
/// ms, the AP answered the copies with deauthentications for over 100 ms, and a connect in that
/// time failed (`StaDisconnected` reason 202). A station stopped with `esp_wifi_stop` alone
/// between `connect` and `StaConnected` burst the same way in most such stops. Leaving first,
/// the disassociation usually went out once and drew no deauthentication, whether the station
/// was connected or between `connect` and `StaConnected`; occasionally, on the Super Mini
/// ESP32-C6, a retry of it drew a few deauthentications over at most about 10 ms. Stopped while
/// still scanning, the station sent nothing.
///
/// The 100 ms is measured, not derived from the blob: with no wait after the
/// `StaDisconnected`, the next connect still failed that way in some boots, each with a stop
/// much slower than usual; with 100 ms, in none of the same sitting.
pub fn stop() InternalError!void {
    try begin_stop();
    defer end_stop();
    try c_err(stop_leaving_ap());
}

/// Stops begun and not yet returned, connects in flight, and a count of the stops that gave up
/// waiting for connects in flight, by which a connect tells whether one gave up on it (see
/// `sta_connecting`). Read and changed only in a critical section. Nothing waits while holding
/// it, and `connect` takes no lock: a `connect` in another task waits for the Wi-Fi task until
/// it has serviced the request (`ieee80211_ioctl+0x1a8..0x1be`), so a lock that `connect` held
/// across the blob call would deadlock an `on_event` that connects from the Wi-Fi task.
var calls: struct { stops: u32 = 0, connects: u32 = 0, give_ups: u32 = 0 } = .{};

/// Held by the running stop, so stops run one at a time. Only stops take it.
var stop_lock: rtos.Mutex = .{};

/// Counts the stop, so that `connect` refuses from here on, then waits for the running stop.
/// The running stop holds the lock for its own waits, limited to 2.1 s but longer while the
/// Wi-Fi task keeps the CPU (see `wait_for_connects`), and for its `disconnect` and
/// `esp_wifi_stop` (with `deinit`, the release of the driver). From another task both wait
/// for the Wi-Fi task to service them (`ieee80211_ioctl`, which `esp_wifi_disconnect_internal`
/// tail-calls at +0x42 and `esp_wifi_stop` calls at +0xc4; C3 and C6 libnet80211.a). In the
/// runs `esp_wifi_stop` returned quickly unless an `on_event` blocked the Wi-Fi task, and took
/// longer for a station still connecting that a stop which gave up in `wait_for_connects` had
/// not taken off the AP. A stop from such an `on_event` waits here in the Wi-Fi task, which the
/// running stop's `disconnect` or `esp_wifi_stop` needs; the 5 s limit ends that wait. A task
/// that already holds the lock, as a stop called from an event its own stop posted does, is
/// refused at once.
fn begin_stop() error{ WifiStopping, Timeout }!void {
    const held = blk: {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        if (stop_lock.locked == rtos.get_current_task()) break :blk true;
        calls.stops += 1;
        break :blk false;
    };
    if (held) {
        log.warn("stop: called during this task's own stop (from on_event?), not stopping", .{});
        return error.WifiStopping;
    }
    stop_lock.lock_with_timeout(.{ .after = .from_ms(5000) }) catch |err| {
        log.warn("stop: another stop still running after 5 s (one from on_event?), not stopping", .{});
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        calls.stops -= 1;
        return err;
    };
}

fn end_stop() void {
    stop_lock.unlock();
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    calls.stops -= 1;
}

fn connects_in_flight() u32 {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    return calls.connects;
}

/// Runs between `begin_stop` and `end_stop`.
fn stop_leaving_ap() c.esp_err_t {
    wait_for_connects();
    // `update_sta_state` stores the state and counts a StaDisconnected before it clears
    // `sta_connecting`, so these reads, in this order, see a connecting station either as
    // connecting or in the state its event left; a StaDisconnected after `seen` ends the wait.
    // That also needs no connect to set the flag after `wait_for_connects`: none begins while
    // a stop runs, and those begun before have returned. If the 1 s wait gave up, a connect
    // still in flight leaves the flag alone when it returns, and this stop does not leave the AP
    // for it.
    const seen = sta_disconnects.load(.acquire);
    const connecting = sta_connecting.load(.acquire);
    if (get_sta_state() == .connected) {
        leave_ap(.connected, seen);
    } else if (connecting) {
        leave_ap(.connecting, seen);
    }
    return c.esp_wifi_stop();
}

/// Waits until the connects begun before this stop have been serviced, so none is accepted
/// after the stop has begun. Gives up after 1 s, which a stop reaches when the Wi-Fi task
/// services nothing for 1 s: when the stop itself runs in an `on_event` there, which is not
/// supported, or when an `on_event` blocks there for 1 s while another task stops. A connect
/// in flight when it gives up does not set `sta_connecting` when it returns, so that flag is
/// not left set after this stop has stopped the station.
///
/// The 1 s is checked between 1 ms sleeps, so the give-up comes late while a task above the
/// caller's priority keeps the CPU. The Wi-Fi task does for the first connect after boot: it
/// derives the WPA2 key from the passphrase in software (`pbkdf2_sha1`, libwpa_supplicant.a),
/// which in the runs took well over a second on the ESP32-C3 and ESP32-C6, and a stop in the
/// main task gave up over a second late; one during the next connect to the same AP, on time.
fn wait_for_connects() void {
    const deadline = time.Deadline.init_relative(hal_time.get_time_since_boot(), .from_ms(1000));
    while (connects_in_flight() != 0) {
        if (deadline.is_reached_by(hal_time.get_time_since_boot())) {
            log.warn("stop: a connect still in flight after 1 s, stopping without waiting", .{});
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            calls.give_ups +%= 1;
            return;
        }
        rtos.sleep(.from_ms(1));
    }
}

/// `seen` is the StaDisconnected count read before the state, so a StaDisconnected that lands
/// after that read ends the wait even if this `disconnect` posts none. A station still scanning
/// when it is stopped has sent nothing to leave, and its `disconnect` posts no
/// `StaDisconnected`, so a connecting station waits for one at most 100 ms and without a warning.
fn leave_ap(from: enum { connected, connecting }, seen: u32) void {
    disconnect() catch |err| {
        log.warn("stop: disconnect failed ({t}), stopping without it", .{err});
        return;
    };
    const limit: time.Duration = if (from == .connected) .from_ms(1000) else .from_ms(100);
    const deadline = time.Deadline.init_relative(hal_time.get_time_since_boot(), limit);
    while (sta_disconnects.load(.acquire) == seen) {
        if (deadline.is_reached_by(hal_time.get_time_since_boot())) {
            if (from == .connected) {
                log.warn("stop: no StaDisconnected within 1 s of disconnect", .{});
            }
            return;
        }
        rtos.sleep(.from_ms(5));
    }
    rtos.sleep(.from_ms(100));
}

/// Non-blocking. Without a station in the mode this returns `error.WifiMode`; while `stop`
/// runs, or `deinit`, `error.WifiStopping`. It takes no lock, so `on_event` may call it.
pub fn connect() InternalError!void {
    const give_ups = blk: {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        if (calls.stops != 0) return error.WifiStopping;
        calls.connects += 1;
        break :blk calls.give_ups;
    };
    const status = c.esp_wifi_connect_internal();
    {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        // With the count, so a stop that waited for this connect reads the flag after it is set.
        if (status == c.ESP_OK and calls.give_ups == give_ups) sta_connecting.store(true, .release);
        calls.connects -= 1;
    }
    try c_err(status);
}

/// Non-blocking. Without a station in the mode this returns `error.WifiMode`.
pub fn disconnect() InternalError!void {
    const status = c.esp_wifi_disconnect_internal();
    // connect answers a mode without a station with ESP_ERR_WIFI_MODE
    // (wifi_connect_process+0x12..0x16, +0x5c..0x5e), but disconnect answers the
    // same test with bare ESP_FAIL (wifi_disconnect_process+0x1e..0x24, +0x3e;
    // C3 and C6 libnet80211.a). ESP_FAIL also comes from a station whose
    // ieee80211_sta_disconnect fails (_do_wifi_disconnect+0xa2..0xa6), so the
    // mode decides; esp_wifi_get_mode reads the byte both processes test.
    // The mode is read after the call, so a set_mode racing this disconnect on
    // another task can swap error.WifiMode and error.WifiOther.
    if (status == c.ESP_FAIL and !(try get_mode()).is_sta()) return error.WifiMode;
    try c_err(status);
}

pub const EventType = enum(i32) {
    /// Wi-Fi is ready for operation.
    WifiReady = 0,
    /// Scan operation has completed.
    ScanDone,
    /// Station mode started.
    StaStart,
    /// Station mode stopped.
    StaStop,
    /// Station connected to a network.
    StaConnected,
    /// Station disconnected from a network.
    StaDisconnected,
    /// Station authentication mode changed.
    StaAuthmodeChange,

    /// Station WPS succeeds in enrollee mode.
    StaWpsErSuccess,
    /// Station WPS fails in enrollee mode.
    StaWpsErFailed,
    /// Station WPS timeout in enrollee mode.
    StaWpsErTimeout,
    /// Station WPS pin code in enrollee mode.
    StaWpsErPin,
    /// Station WPS overlap in enrollee mode.
    StaWpsErPbcOverlap,

    /// Soft-AP start.
    ApStart,
    /// Soft-AP stop.
    ApStop,
    /// A station connected to Soft-AP.
    ApStaconnected,
    /// A station disconnected from Soft-AP.
    ApStadisconnected,
    /// Received probe request packet in Soft-AP interface.
    ApProbereqrecved,

    /// Received report of FTM procedure.
    FtmReport,

    /// AP's RSSI crossed configured threshold.
    StaBssRssiLow,
    /// Status indication of Action Tx operation.
    ActionTxStatus,
    /// Remain-on-Channel operation complete.
    RocDone,

    /// Station beacon timeout.
    StaBeaconTimeout,

    /// Connectionless module wake interval has started.
    ConnectionlessModuleWakeIntervalStart,

    /// Soft-AP WPS succeeded in registrar mode.
    ApWpsRgSuccess,
    /// Soft-AP WPS failed in registrar mode.
    ApWpsRgFailed,
    /// Soft-AP WPS timed out in registrar mode.
    ApWpsRgTimeout,
    /// Soft-AP WPS pin code in registrar mode.
    ApWpsRgPin,
    /// Soft-AP WPS overlap in registrar mode.
    ApWpsRgPbcOverlap,

    /// iTWT setup.
    ItwtSetup,
    /// iTWT teardown.
    ItwtTeardown,
    /// iTWT probe.
    ItwtProbe,
    /// iTWT suspended.
    ItwtSuspend,
    /// TWT wakeup event.
    TwtWakeup,
    /// bTWT setup.
    BtwtSetup,
    /// bTWT teardown.
    BtwtTeardown,

    /// NAN (Neighbor Awareness Networking) discovery has started.
    NanStarted,
    /// NAN discovery has stopped.
    NanStopped,
    /// NAN service discovery match found.
    NanSvcMatch,
    /// Replied to a NAN peer with service discovery match.
    NanReplied,
    /// Received a follow-up message in NAN.
    NanReceive,
    /// Received NDP (Neighbor Discovery Protocol) request from a NAN peer.
    NdpIndication,
    /// NDP confirm indication.
    NdpConfirm,
    /// NAN datapath terminated indication.
    NdpTerminated,
    /// Wi-Fi home channel change, doesn't occur when scanning.
    HomeChannelChange,

    /// Received Neighbor Report response.
    StaNeighborRep,
};

pub const Event = union(EventType) {
    /// Wi-Fi is ready for operation.
    WifiReady,
    /// Scan operation has completed.
    ScanDone: c.wifi_event_sta_scan_done_t,
    /// Station mode started.
    StaStart,
    /// Station mode stopped.
    StaStop,
    /// Station connected to a network.
    StaConnected: c.wifi_event_sta_connected_t,
    /// Station disconnected from a network.
    StaDisconnected: c.wifi_event_sta_disconnected_t,
    /// Station authentication mode changed.
    StaAuthmodeChange: c.wifi_event_sta_authmode_change_t,

    /// Station WPS succeeds in enrollee mode.
    StaWpsErSuccess: c.wifi_event_sta_wps_er_success_t,
    /// Station WPS fails in enrollee mode.
    StaWpsErFailed,
    /// Station WPS timeout in enrollee mode.
    StaWpsErTimeout,
    /// Station WPS pin code in enrollee mode.
    StaWpsErPin: c.wifi_event_sta_wps_er_pin_t,
    /// Station WPS overlap in enrollee mode.
    StaWpsErPbcOverlap,

    /// Soft-AP start.
    ApStart,
    /// Soft-AP stop.
    ApStop,
    /// A station connected to Soft-AP.
    ApStaconnected: c.wifi_event_ap_staconnected_t,
    /// A station disconnected from Soft-AP.
    ApStadisconnected: c.wifi_event_ap_stadisconnected_t,
    /// Received probe request packet in Soft-AP interface.
    ApProbereqrecved: c.wifi_event_ap_probe_req_rx_t,

    /// Received report of FTM procedure.
    FtmReport: c.wifi_event_ftm_report_t,

    /// AP's RSSI crossed configured threshold.
    StaBssRssiLow: c.wifi_event_bss_rssi_low_t,
    /// Status indication of Action Tx operation.
    ActionTxStatus: c.wifi_event_action_tx_status_t,
    /// Remain-on-Channel operation complete.
    RocDone: c.wifi_event_roc_done_t,

    /// Station beacon timeout.
    StaBeaconTimeout,

    /// Connectionless module wake interval has started.
    ConnectionlessModuleWakeIntervalStart,

    /// Soft-AP WPS succeeded in registrar mode.
    ApWpsRgSuccess: c.wifi_event_ap_wps_rg_success_t,
    /// Soft-AP WPS failed in registrar mode.
    ApWpsRgFailed: c.wifi_event_ap_wps_rg_fail_reason_t,
    /// Soft-AP WPS timed out in registrar mode.
    ApWpsRgTimeout,
    /// Soft-AP WPS pin code in registrar mode.
    ApWpsRgPin: c.wifi_event_ap_wps_rg_pin_t,
    /// Soft-AP WPS overlap in registrar mode.
    ApWpsRgPbcOverlap,

    /// iTWT setup.
    ItwtSetup,
    /// iTWT teardown.
    ItwtTeardown,
    /// iTWT probe.
    ItwtProbe,
    /// iTWT suspended.
    ItwtSuspend,
    /// TWT wakeup event.
    TwtWakeup,
    /// bTWT setup.
    BtwtSetup,
    /// bTWT teardown.
    BtwtTeardown,

    /// NAN (Neighbor Awareness Networking) discovery has started.
    NanStarted,
    /// NAN discovery has stopped.
    NanStopped,
    /// NAN service discovery match found.
    // TODO: c.wifi_event_nan_svc_match_t
    NanSvcMatch,
    /// Replied to a NAN peer with service discovery match.
    // TODO: c.wifi_event_nan_replied_t
    NanReplied,
    /// Received a follow-up message in NAN.
    // TODO: c.wifi_event_nan_receive_t
    NanReceive,
    /// Received NDP (Neighbor Discovery Protocol) request from a NAN peer.
    // TODO: c.wifi_event_ndp_indication_t
    NdpIndication,
    /// NDP confirm indication.
    // TODO: c.wifi_event_ndp_confirm_t
    NdpConfirm,
    /// NAN datapath terminated indication.
    // TODO: c.wifi_event_ndp_terminated_t
    NdpTerminated,
    /// Wi-Fi home channel change, doesn't occur when scanning.
    HomeChannelChange: c.wifi_event_home_channel_change_t,

    /// Received Neighbor Report response.
    StaNeighborRep: c.wifi_event_neighbor_report_t,
};

/// Internal function. Called by osi layer.
pub fn on_event_post(id: i32, data: ?*anyopaque, data_size: usize) void {
    const event_type: EventType = @fromBackingInt(id);
    log.debug("event received: {t}", .{event_type});

    update_sta_state(event_type);
    update_ap_state(event_type);

    const event = switch (event_type) {
        inline else => |tag| blk: {
            const PayloadType = @FieldType(Event, @tagName(tag));
            if (PayloadType == void) break :blk @unionInit(Event, @tagName(tag), {});

            // Purposely skipping the assert if the type is void. There are
            // some todos where we use void for the payload instead of the
            // actual payload type.
            assert(data_size == @sizeOf(PayloadType));

            break :blk @unionInit(Event, @tagName(tag), @as(*PayloadType, @ptrCast(@alignCast(data))).*);
        },
    };

    if (wifi_options.on_event) |on_event| {
        on_event(event);
    }
}

pub const StaState = enum(u32) {
    none,
    started,
    connected,
    disconnected,
    stopped,

    pub fn is_started(state: StaState) bool {
        return switch (state) {
            .started, .connected, .disconnected => true,
            else => false,
        };
    }
};

pub const ApState = enum(u32) {
    none,
    started,
    stopped,
};

var sta_state: std.atomic.Value(StaState) = .init(.none);
/// Set by `connect` once the blob has accepted it, and cleared by the StaConnected,
/// StaDisconnected or StaStop that follows: a stop in between leaves the AP too. A refused
/// `connect` leaves it as it was. A stop reads it only once no connect is in flight, so setting
/// it after the blob call is soon enough, and it covers a `connect` issued before an earlier
/// attempt's event, such as a retry that does not wait for it, and accepted after that event.
/// It errs towards set: when the Wi-Fi task posts the accepted attempt's own event before the
/// blob call returns, the flag stays set until the next station event, as it does after a
/// `disconnect` while the station still scans, which posts none of these. A stop while it is
/// set without a connect pending calls `disconnect` for nothing and waits the 100 ms for a
/// StaDisconnected that does not come. A `connect` that a stop gave up waiting for does not set
/// it (see `wait_for_connects`).
var sta_connecting: std.atomic.Value(bool) = .init(false);
/// Count of StaDisconnected events, which `leave_ap` waits for.
var sta_disconnects: std.atomic.Value(u32) = .init(0);
var ap_state: std.atomic.Value(ApState) = .init(.none);

fn update_sta_state(event: EventType) void {
    const new_sta_state: StaState = switch (event) {
        .StaStart => .started,
        .StaConnected => .connected,
        .StaDisconnected => .disconnected,
        .StaStop => .stopped,
        else => return,
    };
    // In this order: `stop_leaving_ap` reads them in reverse.
    sta_state.store(new_sta_state, .release);
    if (new_sta_state == .disconnected) _ = sta_disconnects.fetchAdd(1, .release);
    if (new_sta_state != .started) sta_connecting.store(false, .release);
}

fn update_ap_state(event: EventType) void {
    const new_ap_state: ApState = switch (event) {
        .ApStart => .started,
        .ApStop => .stopped,
        else => return,
    };
    ap_state.store(new_ap_state, .monotonic);
}

pub fn get_ap_state() ApState {
    return ap_state.load(.monotonic);
}

pub fn get_sta_state() StaState {
    return sta_state.load(.acquire);
}

pub const Interface = enum(u32) {
    ap = c.WIFI_IF_AP,
    sta = c.WIFI_IF_STA,

    pub fn is_active(self: Interface) InternalError!bool {
        const mode = try get_mode();
        return switch (self) {
            .ap => mode.is_ap(),
            .sta => mode.is_sta(),
        };
    }
};

pub fn send_packet(iface: Interface, data: []const u8) (error{TooManyPacketsInFlight} || InternalError)!void {
    try c_err(c.esp_wifi_internal_tx(@backingInt(iface), @ptrCast(@constCast(data.ptr)), @intCast(data.len)));
}

fn tx_done_cb(
    iface_idx: u8,
    data_ptr: [*c]u8,
    data_len: [*c]u16,
    status: bool,
) callconv(.c) void {
    log.debug("tx_done_cb", .{});

    if (wifi_options.on_packet_transmitted) |on_packet_transmitted| {
        const interface = std.enums.fromInt(Interface, iface_idx) orelse return;
        on_packet_transmitted(interface, data_ptr[0..data_len.*], status);
    }
}

fn recv_cb_ap(buf: ?*anyopaque, len: u16, eb: ?*anyopaque) callconv(.c) c.esp_err_t {
    log.debug("recv_cb_ap {?} {} {?}", .{ buf, len, eb });

    if (wifi_options.on_packet_received) |on_packet_received| {
        on_packet_received(.ap, @as([*]const u8, @ptrCast(buf))[0..len]);
    }
    c.esp_wifi_internal_free_rx_buffer(eb);

    return c.ESP_OK;
}

fn recv_cb_sta(buf: ?*anyopaque, len: u16, eb: ?*anyopaque) callconv(.c) c.esp_err_t {
    log.debug("recv_cb_sta {?} {} {?}", .{ buf, len, eb });

    if (wifi_options.on_packet_received) |on_packet_received| {
        on_packet_received(.sta, @as([*]const u8, @ptrCast(buf))[0..len]);
    }
    c.esp_wifi_internal_free_rx_buffer(eb);

    return c.ESP_OK;
}

pub const ScanConfig = struct {
    ssid: ?[:0]const u8 = null,
    bssid: ?[:0]const u8 = null,
    channel: ?u8 = null,
    show_hidden: bool = true,
    type: Type = .{ .active = .{
        .min = .from_ms(100),
        .max = .from_ms(200),
    } },

    pub const Type = union(enum) {
        /// Active scan with min and max scan time per channel. This is the default
        /// and recommended if you are unsure.
        ///
        /// # Procedure
        /// 1. Send probe request on each channel.
        /// 2. Wait for probe response. Wait at least `min` time, but if no response is received, wait
        ///    up to `max` time.
        /// 3. Switch channel.
        /// 4. Repeat from 1.
        active: struct {
            /// Minimum scan time per channel.
            min: time.Duration,
            /// Maximum scan time per channel.
            max: time.Duration,
        },
        /// Passive scan.
        ///
        /// # Procedure
        /// 1. Wait for beacon for given duration.
        /// 2. Switch channel.
        /// 3. Repeat from 1.
        passive: time.Duration,
    };
};

/// Blocks until the scan is finished. The returned iterator must be deinited
/// or consumed before another call to scan.
pub fn scan(config: ScanConfig) ConfigError!ScanResultsIterator {
    const scan_time: c.wifi_scan_time_t = switch (config.type) {
        .active => |active_time| .{
            .active = .{
                .min = @intCast(active_time.min.to_us() / 1000),
                .max = @intCast(active_time.max.to_us() / 1000),
            },
        },
        .passive => |passive_time| blk: {
            if (!passive_time.less_than(.from_ms(1_500)))
                return error.InvalidConfig;

            break :blk .{ .passive = @intCast(passive_time.to_us() / 1000) };
        },
    };

    var scan_config: c.wifi_scan_config_t = .{
        .ssid = if (config.ssid) |ssid| @constCast(ssid.ptr) else null,
        .bssid = if (config.bssid) |bssid| @constCast(bssid.ptr) else null,
        .channel = config.channel orelse 0,
        .show_hidden = config.show_hidden,
        .scan_type = switch (config.type) {
            .active => c.WIFI_SCAN_TYPE_ACTIVE,
            .passive => c.WIFI_SCAN_TYPE_PASSIVE,
        },
        .scan_time = scan_time,
        .home_chan_dwell_time = 0,
        .channel_bitmap = .{
            .ghz_2_channels = 0,
            .ghz_5_channels = 0,
        },
        .coex_background_scan = false,
    };
    try c_err(c.esp_wifi_scan_start(&scan_config, true));
    return try .init();
}

/// SAFETY: There can be only one instance of `ScanIterator` at any given time.
pub const ScanResultsIterator = struct {
    remaining: u16,
    ap_record: c_patched.wifi_ap_record_t = undefined,

    /// Blocks the current thread until the scan finishes and returns an
    /// iterator for the scan results.
    pub fn init() InternalError!ScanResultsIterator {
        var ap_count: u16 = undefined;
        try c_err(c.esp_wifi_scan_get_ap_num(&ap_count));
        return .{ .remaining = ap_count };
    }

    pub fn deinit(_: ScanResultsIterator) void {
        // free any ap records that were not returned
        c_err(c.esp_wifi_clear_ap_list()) catch |err| {
            std.log.warn("failed to clear ap list: {t}", .{err});
        };
    }

    /// SAFETY: AP_Record strings last until the next call to next.
    pub fn next(self: *ScanResultsIterator) InternalError!?AP_Record {
        if (self.remaining == 0) {
            return null;
        }
        self.remaining -= 1;

        try c_err(c_patched.esp_wifi_scan_get_ap_record(&self.ap_record));

        const ssid = std.mem.sliceTo(&self.ap_record.ssid, 0);
        return .{
            .ssid = ssid,
            .primary_channel = self.ap_record.primary,
            .secondary_channel = self.ap_record.second,
            .rssi = self.ap_record.rssi,
            .auth_mode = std.enums.fromInt(AuthMethod, self.ap_record.authmode),
        };
    }

    /// Strings (eg: ssid) have the same lifetime as the iterator object.
    pub const AP_Record = struct {
        ssid: []const u8,
        primary_channel: u8,
        secondary_channel: u32,
        rssi: i8,
        // TODO: this doesn't contain possibilities
        auth_mode: ?AuthMethod,
        // TODO: add the rest
    };
};

pub const AuthMethod = enum(u32) {
    none = c.WIFI_AUTH_OPEN,

    /// Wired Equivalent Privacy (WEP) authentication.
    wep = c.WIFI_AUTH_WEP,

    /// Wi-Fi Protected Access (WPA) authentication.
    wpa = c.WIFI_AUTH_WPA_PSK,

    /// Wi-Fi Protected Access 2 (WPA2) Personal authentication (default).
    wpa2_personal = c.WIFI_AUTH_WPA2_PSK,

    /// WPA/WPA2 Personal authentication (supports both).
    wpa_wpa2_personal = c.WIFI_AUTH_WPA_WPA2_PSK,

    /// WPA2 Enterprise authentication.
    wpa2_enterprise = c.WIFI_AUTH_WPA2_ENTERPRISE,

    /// WPA3 Personal authentication.
    wpa3_personal = c.WIFI_AUTH_WPA3_PSK,

    /// WPA2/WPA3 Personal authentication (supports both).
    wpa2_wpa3_personal = c.WIFI_AUTH_WPA2_WPA3_PSK,

    /// WLAN Authentication and Privacy Infrastructure (WAPI).
    wapi_personal = c.WIFI_AUTH_WAPI_PSK,
};

fn export_symbols() void {
    @export(&g_wifi_feature_caps, .{ .name = "g_wifi_feature_caps" });
    @export(&g_wifi_osi_funcs, .{ .name = "g_wifi_osi_funcs" });
}

// TODO: configurable
var init_config: c.wifi_init_config_t = .{
    .osi_funcs = &g_wifi_osi_funcs,
    // .wpa_crypto_funcs = c.g_wifi_default_wpa_crypto_funcs,
    .static_rx_buf_num = 10, // overwritten by init
    .dynamic_rx_buf_num = 32, // overwritten by init
    .tx_buf_type = c.CONFIG_ESP_WIFI_TX_BUFFER_TYPE,
    .static_tx_buf_num = 0, // overwritten by init
    .dynamic_tx_buf_num = 32, // overwritten by init
    // IDF WIFI_INIT_CONFIG_DEFAULT: 0 = static, 1 = dynamic. The STATIC_RX_MGMT_BUFFER
    // choice flag is 1 when static is selected, which would request dynamic buffers.
    .rx_mgmt_buf_type = c.CONFIG_ESP_WIFI_DYNAMIC_RX_MGMT_BUF,
    .rx_mgmt_buf_num = c.CONFIG_ESP_WIFI_RX_MGMT_BUF_NUM_DEF,
    .cache_tx_buf_num = c.WIFI_CACHE_TX_BUFFER_NUM,
    .csi_enable = 0, // TODO: WiFi channel state information enable flag.
    .ampdu_rx_enable = 1, // overwritten by init
    .ampdu_tx_enable = 1, // overwritten by init
    .amsdu_tx_enable = 0, // overwritten by init
    .nvs_enable = 0,
    .nano_enable = 0,
    .rx_ba_win = 6, // overwritten by init
    .wifi_task_core_id = 0,
    .beacon_max_len = c.WIFI_SOFTAP_BEACON_MAX_LEN,
    .mgmt_sbuf_num = c.WIFI_MGMT_SBUF_NUM,
    .feature_caps = c.WIFI_FEATURE_CAPS,
    .sta_disconnected_pm = false,
    .espnow_max_encrypt_num = c.CONFIG_ESP_WIFI_ESPNOW_MAX_ENCRYPT_NUM,
    .tx_hetb_queue_num = 3,
    .dump_hesigb_enable = false,
    .magic = c.WIFI_INIT_CONFIG_MAGIC,
};

const wifi_enable_wpa3_sae: u64 = 1 << 0;
const wifi_enable_enterprise: u64 = 1 << 7;
// const wifi_ftm_initiator: u64 = 1 << 2;
// const wifi_ftm_responder: u64 = 1 << 3;
// const wifi_enable_gcmp: u64 = 1 << 4;
// const wifi_enable_gmac: u64 = 1 << 5;
// const wifi_enable_11r: u64 = 1 << 6;

var g_wifi_feature_caps: u64 = wifi_enable_wpa3_sae | wifi_enable_enterprise;

var g_wifi_osi_funcs: c.wifi_osi_funcs_t = osi_funcs: {
    var f: c.wifi_osi_funcs_t = .{
        ._version = c.ESP_WIFI_OS_ADAPTER_VERSION,
        ._env_is_chip = osi.env_is_chip,
        ._set_intr = osi.set_intr,
        ._clear_intr = osi.clear_intr,
        ._set_isr = osi.set_isr,
        ._ints_on = osi.ints_on,
        ._ints_off = osi.ints_off,
        ._is_from_isr = osi.is_from_isr,
        ._spin_lock_create = osi.spin_lock_create,
        ._spin_lock_delete = osi.spin_lock_delete,
        ._wifi_int_disable = osi.wifi_int_disable,
        ._wifi_int_restore = osi.wifi_int_restore,
        ._task_yield_from_isr = osi.task_yield_from_isr,
        ._semphr_create = osi.semphr_create,
        ._semphr_delete = osi.semphr_delete,
        ._semphr_take = osi.semphr_take,
        ._semphr_give = osi.semphr_give,
        ._wifi_thread_semphr_get = osi.wifi_thread_semphr_get,
        ._mutex_create = osi.mutex_create,
        ._recursive_mutex_create = osi.recursive_mutex_create,
        ._mutex_delete = osi.mutex_delete,
        ._mutex_lock = osi.mutex_lock,
        ._mutex_unlock = osi.mutex_unlock,
        ._queue_create = osi.queue_create,
        ._queue_delete = osi.queue_delete,
        ._queue_send = osi.queue_send,
        ._queue_send_from_isr = osi.queue_send_from_isr,
        ._queue_send_to_back = osi.queue_send_to_back,
        ._queue_send_to_front = osi.queue_send_to_front,
        ._queue_recv = osi.queue_recv,
        ._queue_msg_waiting = osi.queue_msg_waiting,
        ._event_group_create = @ptrCast(&osi.event_group_create),
        ._event_group_delete = @ptrCast(&osi.event_group_delete),
        ._event_group_set_bits = @ptrCast(&osi.event_group_set_bits),
        ._event_group_clear_bits = @ptrCast(&osi.event_group_clear_bits),
        ._event_group_wait_bits = @ptrCast(&osi.event_group_wait_bits),
        ._task_create_pinned_to_core = osi.task_create_pinned_to_core,
        ._task_create = osi.task_create,
        ._task_delete = osi.task_delete,
        ._task_delay = osi.task_delay,
        ._task_ms_to_tick = osi.task_ms_to_tick,
        ._task_get_current_task = osi.task_get_current_task,
        ._task_get_max_priority = osi.task_get_max_priority,
        ._malloc = osi.malloc,
        ._free = osi.free,
        ._event_post = osi.esp_event_post,
        ._get_free_heap_size = @ptrCast(&osi.get_free_heap_size),
        ._rand = osi.rand,
        ._dport_access_stall_other_cpu_start_wrap = osi.dport_access_stall_other_cpu_start_wrap,
        ._dport_access_stall_other_cpu_end_wrap = osi.dport_access_stall_other_cpu_end_wrap,
        ._wifi_apb80m_request = osi.wifi_apb80m_request,
        ._wifi_apb80m_release = osi.wifi_apb80m_release,
        ._phy_disable = osi.phy_disable,
        ._phy_enable = osi.phy_enable,
        ._phy_update_country_info = osi.phy_update_country_info,
        ._read_mac = osi.read_mac,
        ._timer_arm = osi.timer_arm,
        ._timer_disarm = osi.timer_disarm,
        ._timer_done = osi.timer_done,
        ._timer_setfn = osi.timer_setfn,
        ._timer_arm_us = osi.timer_arm_us,
        ._wifi_reset_mac = osi.wifi_reset_mac,
        ._wifi_clock_enable = osi.wifi_clock_enable,
        ._wifi_clock_disable = osi.wifi_clock_disable,
        ._wifi_rtc_enable_iso = @ptrCast(&osi.wifi_rtc_enable_iso),
        ._wifi_rtc_disable_iso = @ptrCast(&osi.wifi_rtc_disable_iso),
        ._esp_timer_get_time = osi.esp_timer_get_time,
        ._nvs_set_i8 = @ptrCast(&osi.nvs_set_i8),
        ._nvs_get_i8 = @ptrCast(&osi.nvs_get_i8),
        ._nvs_set_u8 = @ptrCast(&osi.nvs_set_u8),
        ._nvs_get_u8 = @ptrCast(&osi.nvs_get_u8),
        ._nvs_set_u16 = @ptrCast(&osi.nvs_set_u16),
        ._nvs_get_u16 = @ptrCast(&osi.nvs_get_u16),
        ._nvs_open = @ptrCast(&osi.nvs_open),
        ._nvs_close = @ptrCast(&osi.nvs_close),
        ._nvs_commit = @ptrCast(&osi.nvs_commit),
        ._nvs_set_blob = @ptrCast(&osi.nvs_set_blob),
        ._nvs_get_blob = @ptrCast(&osi.nvs_get_blob),
        ._nvs_erase_key = @ptrCast(&osi.nvs_erase_key),
        ._get_random = osi.get_random,
        ._get_time = osi.get_time,
        ._random = &osi.random,
        ._slowclk_cal_get = osi.slowclk_cal_get,
        ._log_write = osi.log_write,
        ._log_writev = osi.log_writev,
        ._log_timestamp = osi.log_timestamp,
        ._malloc_internal = osi.malloc_internal,
        ._realloc_internal = osi.realloc_internal,
        ._calloc_internal = osi.calloc_internal,
        ._zalloc_internal = osi.zalloc_internal,
        ._wifi_malloc = osi.wifi_malloc,
        ._wifi_realloc = osi.wifi_realloc,
        ._wifi_calloc = osi.wifi_calloc,
        ._wifi_zalloc = osi.wifi_zalloc,
        ._wifi_create_queue = osi.wifi_create_queue,
        ._wifi_delete_queue = osi.wifi_delete_queue,
        ._coex_init = osi.coex_init,
        ._coex_deinit = osi.coex_deinit,
        ._coex_enable = osi.coex_enable,
        ._coex_disable = osi.coex_disable,
        ._coex_status_get = osi.coex_status_get,
        ._coex_condition_set = @ptrCast(&osi.coex_condition_set),
        ._coex_wifi_request = osi.coex_wifi_request,
        ._coex_wifi_release = osi.coex_wifi_release,
        ._coex_wifi_channel_set = osi.coex_wifi_channel_set,
        ._coex_event_duration_get = osi.coex_event_duration_get,
        ._coex_pti_get = osi.coex_pti_get,
        ._coex_schm_status_bit_clear = osi.coex_schm_status_bit_clear,
        ._coex_schm_status_bit_set = osi.coex_schm_status_bit_set,
        ._coex_schm_interval_set = osi.coex_schm_interval_set,
        ._coex_schm_interval_get = osi.coex_schm_interval_get,
        ._coex_schm_curr_period_get = osi.coex_schm_curr_period_get,
        ._coex_schm_curr_phase_get = osi.coex_schm_curr_phase_get,
        ._coex_schm_process_restart = osi.coex_schm_process_restart,
        ._coex_schm_register_cb = osi.coex_schm_register_cb,
        ._coex_register_start_cb = osi.coex_register_start_cb,
        ._coex_schm_flexible_period_set = osi.coex_schm_flexible_period_set,
        ._coex_schm_flexible_period_get = osi.coex_schm_flexible_period_get,
        ._magic = @bitCast(c.ESP_WIFI_OS_ADAPTER_MAGIC),
    };
    // ESP32-C6 only: modem sleep retention hooks. Sleep isn't supported, so these must not be
    // called; stubs instead of null so a call shows up in the log instead of jumping to 0.
    if (@hasField(c.wifi_osi_funcs_t, "_regdma_link_set_write_wait_content")) {
        f._regdma_link_set_write_wait_content = osi.regdma_link_set_write_wait_content;
        f._sleep_retention_find_link_by_id = osi.sleep_retention_find_link_by_id;
    }
    break :osi_funcs f;
};

pub const InternalError = wifi_status.Error;

/// Any code other than ESP_OK is an error; see `wifi_status.check`.
pub const c_err = wifi_status.check;

// wifi_status cannot import the headers (its host tests run without them), so
// its codes are checked against them here.
comptime {
    assert(c.ESP_OK == 0);
    @setEvalBranchQuota(10_000);
    for (std.enums.values(wifi_status.Code)) |code| {
        const tag = @tagName(code);
        const macro = upper: {
            var buf: [tag.len]u8 = undefined;
            _ = std.ascii.upperString(&buf, tag);
            const name = buf;
            break :upper &name;
        };
        if (@field(c, macro) != @backingInt(code))
            @compileError("wifi_status.Code." ++ tag ++ " differs from " ++ macro);
    }
}

pub const c_patched = struct {
    pub const wifi_ap_config_t = extern struct {
        ssid: [32]u8 = std.mem.zeroes([32]u8),
        password: [64]u8 = std.mem.zeroes([64]u8),
        ssid_len: u8 = std.mem.zeroes(u8),
        channel: u8 = std.mem.zeroes(u8),
        authmode: c.wifi_auth_mode_t = std.mem.zeroes(c.wifi_auth_mode_t),
        ssid_hidden: u8 = std.mem.zeroes(u8),
        max_connection: u8 = std.mem.zeroes(u8),
        beacon_interval: u16 = std.mem.zeroes(u16),
        csa_count: u8 = std.mem.zeroes(u8),
        dtim_period: u8 = std.mem.zeroes(u8),
        pairwise_cipher: c.wifi_cipher_type_t = std.mem.zeroes(c.wifi_cipher_type_t),
        ftm_responder: bool = std.mem.zeroes(bool),
        pmf_cfg: c.wifi_pmf_config_t = std.mem.zeroes(c.wifi_pmf_config_t),
        sae_pwe_h2e: c.wifi_sae_pwe_method_t = std.mem.zeroes(c.wifi_sae_pwe_method_t),
    };

    pub const wifi_sta_config_t = extern struct {
        ssid: [32]u8 = std.mem.zeroes([32]u8),
        password: [64]u8 = std.mem.zeroes([64]u8),
        scan_method: c.wifi_scan_method_t = std.mem.zeroes(c.wifi_scan_method_t),
        bssid_set: bool = std.mem.zeroes(bool),
        bssid: [6]u8 = std.mem.zeroes([6]u8),
        channel: u8 = std.mem.zeroes(u8),
        listen_interval: u16 = std.mem.zeroes(u16),
        sort_method: c.wifi_sort_method_t = std.mem.zeroes(c.wifi_sort_method_t),
        threshold: c.wifi_scan_threshold_t = std.mem.zeroes(c.wifi_scan_threshold_t),
        pmf_cfg: c.wifi_pmf_config_t = std.mem.zeroes(c.wifi_pmf_config_t),
        packed1: Packed1 = std.mem.zeroes(Packed1),
        sae_pwe_h2e: c.wifi_sae_pwe_method_t = std.mem.zeroes(c.wifi_sae_pwe_method_t),
        sae_pk_mode: c.wifi_sae_pk_mode_t = std.mem.zeroes(c.wifi_sae_pk_mode_t),
        failure_retry_cnt: u8 = std.mem.zeroes(u8),
        packed2: Packed2 = std.mem.zeroes(Packed2),
        sae_h2e_identifier: [32]u8 = std.mem.zeroes([32]u8),

        // NOTE: maybe a little more imagination
        pub const Packed1 = packed struct(u32) {
            rm_enabled: bool,
            btm_enabled: bool,
            mbo_enabled: bool,
            ft_enabled: bool,
            owe_enabled: bool,
            transition_disable: bool,
            reserved: u26,
        };

        pub const Packed2 = packed struct(u32) {
            he_dcm_set: u1,
            he_dcm_max_constellation_tx: u2,
            he_dcm_max_constellation_rx: u2,
            he_mcs9_enabled: u1,
            he_su_beamformee_disabled: u1,
            he_trig_su_bmforming_feedback_disabled: u1,
            he_trig_mu_bmforming_partial_feedback_disabled: u1,
            he_trig_cqi_feedback_disable: u1,
            he_reserved: u22,
        };
    };

    pub const wifi_nan_config_t = extern struct {
        op_channel: u8 = std.mem.zeroes(u8),
        master_pref: u8 = std.mem.zeroes(u8),
        scan_time: u8 = std.mem.zeroes(u8),
        warm_up_sec: u16 = std.mem.zeroes(u16),
    };

    pub const wifi_config_t = extern union {
        ap: wifi_ap_config_t,
        sta: wifi_sta_config_t,
        nan: wifi_nan_config_t,
    };

    pub extern fn esp_wifi_set_config(interface: c.wifi_interface_t, conf: ?*wifi_config_t) c.esp_err_t;

    pub const wifi_ap_record_t = extern struct {
        bssid: [6]u8 = std.mem.zeroes([6]u8),
        ssid: [33]u8 = std.mem.zeroes([33]u8),
        primary: u8 = std.mem.zeroes(u8),
        second: c.wifi_second_chan_t = std.mem.zeroes(c.wifi_second_chan_t),
        rssi: i8 = std.mem.zeroes(i8),
        authmode: c.wifi_auth_mode_t = std.mem.zeroes(c.wifi_auth_mode_t),
        pairwise_cipher: c.wifi_cipher_type_t = std.mem.zeroes(c.wifi_cipher_type_t),
        group_cipher: c.wifi_cipher_type_t = std.mem.zeroes(c.wifi_cipher_type_t),
        ant: c.wifi_ant_t = std.mem.zeroes(c.wifi_ant_t),
        packed1: Packed1 = std.mem.zeroes(Packed1),
        country: c.wifi_country_t = std.mem.zeroes(c.wifi_country_t),
        he_ap: wifi_he_ap_info_t = std.mem.zeroes(wifi_he_ap_info_t),
        bandwidth: c.wifi_bandwidth_t = std.mem.zeroes(c.wifi_bandwidth_t),
        vht_ch_freq1: u8 = std.mem.zeroes(u8),
        vht_ch_freq2: u8 = std.mem.zeroes(u8),

        pub const Packed1 = packed struct(u32) {
            phy_11b: u1,
            phy_11g: u1,
            phy_11n: u1,
            phy_lr: u1,
            phy_11a: u1,
            phy_11ac: u1,
            phy_11ax: u1,
            wps: u1,
            ftm_responder: u1,
            ftm_initiator: u1,
            reserved: u22,
        };
    };

    pub const wifi_he_ap_info_t = extern struct {
        packed1: Packed1,
        bssid_index: u8,

        pub const Packed1 = packed struct(u8) {
            bss_color: u6,
            partial_bss_color: u1,
            bss_color_disabled: u1,
        };
    };

    pub extern fn esp_wifi_scan_get_ap_record(ap_record: ?*wifi_ap_record_t) c.esp_err_t;
};
