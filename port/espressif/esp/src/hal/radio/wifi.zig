const std = @import("std");
const assert = std.debug.assert;

pub const c = @import("esp-wifi-driver");
const microzig = @import("microzig");
const wifi_options = microzig.options.hal.radio.wifi;
const time = microzig.drivers.time;

const radio = @import("../radio.zig");
const callbacks = @import("callback_context.zig");
const osi = @import("osi.zig");
const wifi_status = @import("wifi_status.zig");
const rtos = @import("../rtos.zig");
const compatibility = @import("../compatibility.zig");
const hal_time = @import("../time.zig");

const log = std.log.scoped(.esp_radio_wifi);

pub const Options = struct {
    /// A process-global listener. An event posted before deinit returned can
    /// still reach the listener after deinit releases the handle. The driver
    /// finishes updating handle state before invoking the listener and drops
    /// events that arrive when there is no owner.
    on_event: ?*const fn (e: Event) void = null,
    on_packet_received: ?*const fn (comptime interface: Interface, data: []const u8) void = null,
    /// Called by the Wi-Fi driver when a transmission completes; `status` is false if it
    /// failed. `data` is the 802.11 frame as the driver sent it, not the Ethernet frame given
    /// to `Wifi.send_packet`: MAC header, the CCMP header on a protected link, LLC/SNAP, payload.
    /// The station's EAPOL handshake frames arrive here too. `data` ends before the frame
    /// does: on a WPA2 link a 60-byte Ethernet frame (46-byte payload after a 26-byte QoS
    /// header, CCMP header and LLC/SNAP) came back as 74 bytes on an ESP32-C3 and 70 on an
    /// ESP32-C6, so the last 14 (C3) or 18 (C6) payload bytes were not in the slice; 100- and
    /// 300-byte frames were cut by the same amounts. Payload near the tail is not visible.
    /// Search for a marker near the start of the payload rather than compute offsets from
    /// the length.
    on_packet_transmitted: ?*const fn (interface: Interface, data: []const u8, status: bool) void = null,
};

pub const InitError = radio.InitError || PowerSaveError || error{
    AlreadyInitialized,
    UnsupportedRadioProtocol,
    WifiRollbackPending,
    WifiSessionBusy,
};

/// In a coexistence image, `Wifi.init` on the running owner returns success without
/// reading this configuration; the session keeps the first init's settings.
pub const InitConfig = struct {
    /// Power save mode. Only `.none` is supported on the ESP32-C6. A
    /// coexistence `Wifi.init` on the running owner returns before checking it.
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

extern fn wifi_osi_funcs_register(table: *c.wifi_osi_funcs_t) c_int;
extern var s_wifi_api_lock: ?*anyopaque;
extern var g_wifi_global_lock: ?*anyopaque;
// The blob keeps both lock addresses across sessions.
var boot_locks: osi.WifiBootLocks = .{};

fn install_boot_locks() InternalError!void {
    // wifi_api_lock reads the registered OSI table when its handle is non-null.
    // C3/C6 libnet80211.a: wifi_api_lock and wifi_init_in_caller_task lazily
    // allocate the API and global locks. wifi_deinit_in_caller_task deletes
    // the interrupt and MAC list locks but leaves these two installed.
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    try c_err(wifi_osi_funcs_register(&g_wifi_osi_funcs));
    boot_locks.install(&s_wifi_api_lock, &g_wifi_global_lock);
}

// The context-free blob event callback routes through this pointer under a critical section.
var owner: ?*Wifi = null;

/// Initialize in place and keep this address valid until deinit succeeds and
/// any concurrent calls on the handle have returned. The caller serializes
/// operations with deinit, except for stop, deinit and connect, which may
/// overlap as documented below.
pub const Wifi = struct {
    lifecycle_active: std.atomic.Value(bool) = .init(false),
    /// Stops begun and not yet returned, connects in flight, and a count of the stops that gave up
    /// waiting for connects in flight, by which a connect tells whether one gave up on it (see
    /// `sta_connecting`). Read and changed only in a critical section. Nothing waits while holding
    /// it, and `connect` takes no lock: a `connect` in another task waits for the Wi-Fi task until
    /// it has serviced the request (`ieee80211_ioctl+0x1a8..0x1be`), so a lock that `connect` held
    /// across the blob call would deadlock an `on_event` that connects from the Wi-Fi task.
    calls: struct { stops: u32 = 0, connects: u32 = 0, give_ups: u32 = 0 } = .{},
    /// Held by the running stop, so stops run one at a time. Only stops take it.
    /// Host tests simulate acquiring it on one thread.
    stop_lock: if (callbacks.host_test) HostStopLock else rtos.Mutex = .{},
    sta_state: std.atomic.Value(StaState) = .init(.none),
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
    sta_connecting: std.atomic.Value(bool) = .init(false),
    /// Count of StaDisconnected events, which `leave_ap` waits for.
    sta_disconnects: std.atomic.Value(u32) = .init(0),
    ap_state: std.atomic.Value(ApState) = .init(.none),
    // Protected by the owner critical section. A claimed handle can route
    // events during init, but only a successful init admits driver calls.
    ready: bool = false,

    const InitOutcome = enum { release, rollback_pending, ready };

    /// In a coexistence image `gpa` is unused (the session allocates from the
    /// attached `radio.SharedHeap`); the parameter stays so that `init` has one
    /// signature in every radio selection, and Wi-Fi-only images allocate from
    /// it. A second handle returns `error.AlreadyInitialized`. On the owning
    /// handle, a coexistence init returns success without reading `config` if
    /// running, or `error.WifiSessionBusy` if busy or pending teardown. A
    /// single-radio init on the owning handle returns `error.AlreadyInitialized`.
    /// After deinit, init on that handle returns `error.WifiSessionBusy` until
    /// any outstanding stops, deinits and connects have drained.
    ///
    /// Driver operations on the owner, including connect and disconnect,
    /// return `error.WouldBlock` until the initial init succeeds. The cached
    /// station and AP state accessors remain available.
    ///
    /// In either image, `error.WifiRollbackPending` means this handle still owns
    /// Wi-Fi. Retry cleanup with `deinit`, which is allowed after init returns.
    /// Other init failures release any ownership acquired by the call.
    pub fn init(self: *Wifi, gpa: std.mem.Allocator, config: InitConfig) InitError!void {
        const already_owned = try self.claim_init(config);
        if (comptime !radio.coex_enabled and microzig.options.hal.radio.radios.ble)
            @compileError("Wi-Fi and BLE cannot run simultaneously: hal.radio.radios.ble selects exclusive BLE mode");
        comptime if (!callbacks.host_test) export_symbols();

        // IDF v5.5.1 esp_wifi/src/wifi_init.c:343-345: a second init succeeds
        // without reading the new configuration.
        if (radio.coex_enabled and already_owned) {
            defer self.finish_lifecycle();
            if (osi.wifi_shutdown.stage == .running) return;
            return error.WifiSessionBusy;
        }

        var outcome: InitOutcome = .release;
        defer self.finish_init(outcome);
        if (!radio.coex_enabled) try radio.init(gpa);
        var backend = if (callbacks.host_test) HostWifi{} else InitBackend{ .config = config };
        const configured = if (radio.coex_enabled)
            start_session(&osi.wifi_shutdown, &backend)
        else
            configure_single(&backend);
        configured catch |err| {
            if (err == error.WifiRollbackPending) outcome = .rollback_pending;
            return err;
        };
        if (!callbacks.host_test and compatibility.chip == .esp32_c6)
            @import("../analog/esp32_c6.zig").wifi_set_inited(true);
        outcome = .ready;
    }

    /// Stops Wi-Fi as `stop` does, leaving the AP first, then releases the driver and the radio. A
    /// stop running in another task returns first; a stop called while this runs waits until it has
    /// returned and then, if this released the driver, gets `error.WifiNotInitialized` from
    /// the ownership check.
    ///
    /// Returns `error.Timeout` if the running stop has not returned within 5 s, which in the runs
    /// only a stop called from `on_event` caused, or if an earlier connect is still in flight after
    /// a 1 s wait. It returns `error.WifiStopping` if the calling task's own stop is running
    /// (a call from an event that stop posted). These errors leave ownership and the driver intact
    /// and allow a retry. Deinit returns `error.WouldBlock` while init is in
    /// progress. It also
    /// returns the error of `esp_wifi_deinit_internal` unless that is `ESP_ERR_WIFI_NOT_INIT`, since
    /// the driver is then still initialised. That error comes after the stop: the station has left
    /// the AP and Wi-Fi has been stopped, unless the error is `ESP_ERR_WIFI_NOT_STOPPED` (below):
    /// Wi-Fi is still started. Either way it releases nothing: the driver and the radio stay
    /// initialised, and the driver keeps allocating from the allocator given to `init`. Keep that
    /// allocator's memory, and anything else lent to the driver or to a network stack on it, until
    /// a later `deinit` returns without an error. Keep this handle at the same address as well.
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
    ///
    /// In a coexistence image a deinit while another stop or deinit runs, or from a radio
    /// callback, returns WouldBlock instead of waiting, and `connect` returns `error.WifiStopping`
    /// until the whole teardown returns. A coex caller retries deinit from task context on
    /// WouldBlock, which a driver deinit rejected by the full packet-processing queue returns; a
    /// retry resumes after the stop and does not leave the AP again. A stop step the queue rejects
    /// panics, as in `stop`. The coexistence teardown also returns the errors of the stop and of
    /// the supplicant deinit, which the single-radio one ignores. Every failed step stays pending
    /// and releases nothing, as above, and a retry resumes where it failed; `ESP_ERR_WIFI_NOT_INIT`
    /// from the driver deinit counts as done there too. Without a session it returns
    /// WifiNotInitialized, as IDF v5.5.1 wifi_init.c:267-269.
    pub fn deinit(self: *Wifi) DeinitError!void {
        try self.begin_stop(.deinit);
        var released = false;
        defer self.end_stop(.deinit, released);
        if (!self.wait_for_connects()) {
            log.warn("deinit: a connect still in flight after 1 s, retry teardown", .{});
            return error.Timeout;
        }
        if (radio.coex_enabled) {
            if (osi.wifi_shutdown.stage == .running) self.leave_ap_before_stop();
            try deinit_coex();
        } else {
            const ready = blk: {
                const cs = microzig.interrupt.enter_critical_section();
                defer cs.leave();
                break :blk self.ready;
            };
            // A driver left by init rollback never admitted a start.
            if (ready) {
                self.leave_ap_before_stop();
                _ = if (callbacks.host_test) HostWifi.esp_wifi_stop() else c.esp_wifi_stop();
            }
            try release_single(&osi.wifi_shutdown, if (callbacks.host_test) HostWifi else ShutdownBackend);
        }
        released = true;
    }

    fn claim_init(self: *Wifi, config: InitConfig) InitError!bool {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        if (owner) |current| {
            if (!radio.coex_enabled or current != self) return error.AlreadyInitialized;
            if (!self.take_lifecycle()) return error.WifiSessionBusy;
            return true;
        }

        if (radio.coex_enabled and callbacks.active()) return error.WifiSessionBusy;
        // A released handle can still have a queued stop or a connect the stop gave up on.
        if (self.calls.stops != 0 or self.calls.connects != 0 or self.stop_lock.locked != null)
            return error.WifiSessionBusy;
        if (!microzig.options.hal.radio.radios.wifi) return error.UnsupportedRadioProtocol;
        if (compatibility.chip == .esp32_c6 and config.power_save_mode != .none)
            return error.PowerSaveUnsupported;

        self.* = .{};
        self.lifecycle_active.store(true, .monotonic);
        owner = self;
        return false;
    }

    fn begin_lifecycle(self: *Wifi) InternalError!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        try self.check_operational();
        if (!self.take_lifecycle()) return error.WouldBlock;
    }

    fn take_lifecycle(self: *Wifi) bool {
        return !callbacks.active() and self.lifecycle_active.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }

    fn finish_init(self: *Wifi, outcome: InitOutcome) void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        self.ready = outcome == .ready;
        if (outcome == .release) owner = null;
        self.finish_lifecycle();
    }

    fn finish_lifecycle(self: *Wifi) void {
        self.lifecycle_active.store(false, .release);
    }

    fn require_operational(self: *const Wifi) InternalError!void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        try self.check_operational();
    }

    // Caller holds the critical section.
    fn check_operational(self: *const Wifi) InternalError!void {
        try self.check_owner();
        if (!self.ready) return error.WouldBlock;
    }

    // Caller holds the critical section.
    fn check_owner(self: *const Wifi) InternalError!void {
        if (owner != self) return error.WifiNotInitialized;
    }

    /// In a coexistence image the lifecycle claim covers the mode change and every
    /// interface configuration, so no other lifecycle call runs between them. A configuration
    /// that fails validation returns `error.InvalidConfig` before the mode changes.
    pub fn apply(self: *Wifi, config: Config) ConfigError!void {
        if (radio.coex_enabled) try self.begin_lifecycle() else try self.require_operational();
        defer if (radio.coex_enabled) self.finish_lifecycle();
        if (radio.coex_enabled) try require_running_session();
        switch (config) {
            .ap => |ap_config| try check_access_point_config(ap_config),
            .sta => |sta_config| try check_station_config(sta_config),
            .ap_sta => |ap_sta_config| {
                try check_access_point_config(ap_sta_config.ap);
                try check_station_config(ap_sta_config.sta);
            },
        }
        switch (config) {
            .ap => |ap_config| {
                try set_mode_unclaimed(.ap);
                try apply_access_point_config(ap_config);
            },
            .sta => |sta_config| {
                try set_mode_unclaimed(.sta);
                try self.apply_station_config(sta_config);
            },
            .ap_sta => |ap_sta_config| {
                try set_mode_unclaimed(.ap_sta);
                try apply_access_point_config(ap_sta_config.ap);
                try self.apply_station_config(ap_sta_config.sta);
            },
        }
    }

    pub fn get_mode(self: *const Wifi) InternalError!WifiMode {
        try self.require_operational();
        var mode: c.wifi_mode_t = undefined;
        try c_err(if (callbacks.host_test) HostWifi.esp_wifi_get_mode(&mode) else c.esp_wifi_get_mode(&mode));
        return @fromBackingInt(mode);
    }

    /// With a station or soft-AP started, a mode change stops and starts the
    /// affected interfaces and posts their events.
    pub fn set_mode(self: *Wifi, mode: WifiMode) InternalError!void {
        if (radio.coex_enabled) try self.begin_lifecycle() else try self.require_operational();
        defer if (radio.coex_enabled) self.finish_lifecycle();
        if (radio.coex_enabled) try require_running_session();
        try set_mode_unclaimed(mode);
    }

    /// Applies `config` to the station interface without changing the mode, unlike `apply`,
    /// which also sets it. `esp_wifi_set_config` also clears the blob's station blacklist
    /// (`wifi_set_config_process+0x78`, C3 and C6 libnet80211.a). While the station is connecting it
    /// returns `error.WifiState` (`wifi_set_config_process+0x36..0x58`). Applied to a connected
    /// station, it was accepted and a `StaDisconnected` (reason 8) followed within milliseconds.
    pub fn apply_station_config(self: *const Wifi, config: Config.Station) ConfigError!void {
        try self.require_operational();
        try check_station_config(config);

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
        try c_err(set_config(c.WIFI_IF_STA, &tmp));
    }

    pub fn set_power_save_mode(self: *const Wifi, mode: PowerSaveMode) PowerSaveError!void {
        try self.require_operational();
        try set_power_save_mode_internal(mode);
    }

    pub fn set_protocol(self: *const Wifi, protocols: []const Protocol) InternalError!void {
        const mode = try self.get_mode();
        if (callbacks.host_test) unreachable; // Protocol changes are not modelled.
        var combined: u8 = 0;
        for (protocols) |protocol| {
            combined |= @backingInt(protocol);
        }

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
    pub fn set_inactive_time(self: *const Wifi, interface: Interface, inactive_time: u16) InternalError!void {
        try self.require_operational();
        if (callbacks.host_test) unreachable; // This blob operation is not modelled.
        try c_err(c.esp_wifi_set_inactive_time(
            @backingInt(interface),
            inactive_time,
        ));
    }

    /// Non-blocking.
    pub fn start(self: *Wifi) InternalError!void {
        if (radio.coex_enabled) try self.begin_lifecycle() else try self.require_operational();
        defer if (radio.coex_enabled) self.finish_lifecycle();
        if (radio.coex_enabled) try require_running_session();
        try c_err(if (callbacks.host_test) HostWifi.esp_wifi_start() else c.esp_wifi_start());
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
    /// station; after `deinit`, the ownership check returns `error.WifiNotInitialized`). A stop waits
    /// at most 5 s for the running one, then returns `error.Timeout` with a warning, without
    /// stopping. Stop returns `error.WouldBlock` while init is in progress.
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
    ///
    /// `esp_wifi_stop` itself can sleep too: the C6 driver waits 10 ms between its TX-drain
    /// retries (at most 500, about 5 s; see `osi.stop_driver`), and in a coexistence image a stop
    /// also waits for a `disconnect` already in progress to return. The AP is left before that
    /// wait, since a disconnect during the driver stop returns WouldBlock. In a coexistence image
    /// a stop while another stop or deinit runs, or from a radio callback, returns WouldBlock
    /// instead of waiting, and a stop that fails after stopping only the interfaces or only the
    /// hardware panics, since the driver can neither finish nor repeat it.
    pub fn stop(self: *Wifi) InternalError!void {
        if (radio.coex_enabled) try self.begin_lifecycle();
        defer if (radio.coex_enabled) self.finish_lifecycle();
        if (radio.coex_enabled) try require_running_session();
        try self.begin_stop(.stop);
        defer self.end_stop(.stop, false);
        if (!self.wait_for_connects()) {
            log.warn("stop: a connect still in flight after 1 s, stopping without waiting", .{});
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            self.calls.give_ups +%= 1;
        }
        self.leave_ap_before_stop();
        if (radio.coex_enabled) {
            return osi.wifi_shutdown.stop(callbacks.current_task(), if (callbacks.host_test) HostWifi else ShutdownBackend);
        }
        try c_err(if (callbacks.host_test) HostWifi.esp_wifi_stop() else c.esp_wifi_stop());
    }

    /// Non-blocking. Without a station in the mode this returns `error.WifiMode`; while `stop`
    /// runs, or `deinit`, `error.WifiStopping`. It takes no lock, so `on_event` may call it.
    pub fn connect(self: *Wifi) InternalError!void {
        const give_ups = blk: {
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            // Check readiness in the same critical section that admits the call.
            try self.check_operational();
            if (self.calls.stops != 0) return error.WifiStopping;
            self.calls.connects += 1;
            break :blk self.calls.give_ups;
        };
        const status = if (callbacks.host_test) HostWifi.esp_wifi_connect_internal() else c.esp_wifi_connect_internal();
        {
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            // With the count, so a stop that waited for this connect reads the flag after it is set.
            if (owner == self and status == c.ESP_OK and self.calls.give_ups == give_ups)
                self.sta_connecting.store(true, .release);
            self.calls.connects -= 1;
        }
        try c_err(status);
    }

    /// Non-blocking. Without a station in the mode this returns `error.WifiMode`.
    /// In a coexistence image it returns WouldBlock while a stop or deinit is
    /// stopping the driver (see `osi.DisconnectGate`).
    pub fn disconnect(self: *const Wifi) InternalError!void {
        try self.require_operational();
        if (radio.coex_enabled and !osi.disconnect_gate.enter()) return error.WouldBlock;
        defer if (radio.coex_enabled) osi.disconnect_gate.leave();
        const status = if (callbacks.host_test) HostWifi.esp_wifi_disconnect_internal() else c.esp_wifi_disconnect_internal();
        // connect answers a mode without a station with ESP_ERR_WIFI_MODE
        // (wifi_connect_process+0x12..0x16, +0x5c..0x5e), but disconnect answers the
        // same test with bare ESP_FAIL (wifi_disconnect_process+0x1e..0x24, +0x3e;
        // C3 and C6 libnet80211.a). ESP_FAIL also comes from a station whose
        // ieee80211_sta_disconnect fails (_do_wifi_disconnect+0xa2..0xa6), so the
        // mode decides; esp_wifi_get_mode reads the byte both processes test.
        // The mode is read after the call, so a set_mode racing this disconnect on
        // another task can swap error.WifiMode and error.WifiOther.
        if (status == c.ESP_FAIL and !(try self.get_mode()).is_sta()) return error.WifiMode;
        try c_err(status);
    }

    pub fn get_ap_state(self: *const Wifi) ApState {
        return self.ap_state.load(.monotonic);
    }

    pub fn get_sta_state(self: *const Wifi) StaState {
        return self.sta_state.load(.acquire);
    }

    /// RSSI in dBm of the access point the station is connected to
    /// (IDF v5.5.1 esp_wifi.h:1667 esp_wifi_sta_get_rssi).
    pub fn get_sta_rssi(self: *const Wifi) InternalError!i32 {
        try self.require_operational();
        if (callbacks.host_test) unreachable; // This blob operation is not modelled.
        var rssi: c_int = 0;
        try c_err(c.esp_wifi_sta_get_rssi(&rssi));
        return rssi;
    }

    pub fn send_packet(self: *const Wifi, iface: Interface, data: []const u8) (error{TooManyPacketsInFlight} || InternalError)!void {
        try self.require_operational();
        if (callbacks.host_test) unreachable; // This blob operation is not modelled.
        try c_err(c.esp_wifi_internal_tx(@backingInt(iface), @ptrCast(@constCast(data.ptr)), @intCast(data.len)));
    }

    /// Blocks until the scan is finished. The returned iterator must be deinited
    /// or consumed before another call to scan.
    pub fn scan(self: *const Wifi, config: ScanConfig) ConfigError!ScanResultsIterator {
        try self.require_operational();
        if (callbacks.host_test) unreachable; // This blob operation is not modelled.
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
        return ScanResultsIterator.init(self);
    }

    const StopOperation = enum { stop, deinit };

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
    fn begin_stop(self: *Wifi, comptime operation: StopOperation) InternalError!void {
        const held = blk: {
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            if (operation == .stop) try self.check_operational() else try self.check_owner();
            if (!radio.coex_enabled and self.lifecycle_active.load(.acquire)) return error.WouldBlock;
            if (radio.coex_enabled and operation == .deinit) {
                // Claim the lifecycle and close connect admission in the same critical section.
                if (!self.take_lifecycle()) return error.WouldBlock;
            } else if (self.stop_lock.locked == callbacks.current_task()) {
                break :blk true;
            }
            self.calls.stops += 1;
            break :blk false;
        };
        if (held) {
            log.warn("stop: called during this task's own stop (from on_event?), not stopping", .{});
            return error.WifiStopping;
        }
        errdefer if (radio.coex_enabled and operation == .deinit) self.finish_lifecycle();
        const timeout: rtos.Timeout = if (callbacks.host_test) .never else .{ .after = .from_ms(5000) };
        self.stop_lock.lock_with_timeout(timeout) catch |err| {
            log.warn("stop: another stop still running after 5 s (one from on_event?), not stopping", .{});
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            self.calls.stops -= 1;
            return err;
        };
        errdefer self.end_stop(.stop, false);
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        // A deinit may have released ownership while this task was waiting for the lock.
        try self.check_owner();
    }

    fn end_stop(self: *Wifi, comptime operation: StopOperation, released: bool) void {
        if (released) {
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            // Unlock may schedule a queued stop. It must see that teardown released Wi-Fi.
            self.ready = false;
            owner = null;
        }
        self.stop_lock.unlock();
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        // Keep the stop counted through owner release and unlock, which can schedule another task.
        self.calls.stops -= 1;
        if (radio.coex_enabled and operation == .deinit) self.lifecycle_active.store(false, .release);
    }

    fn connects_in_flight(self: *const Wifi) u32 {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        return self.calls.connects;
    }

    /// Runs after waiting for connects and before asking the driver to stop.
    fn leave_ap_before_stop(self: *Wifi) void {
        if (callbacks.host_test) return; // The mock has no AP association or scheduler.
        // `update_sta_state` stores the state and counts a StaDisconnected before it clears
        // `sta_connecting`, so these reads, in this order, see a connecting station either as
        // connecting or in the state its event left; a StaDisconnected after `seen` ends the
        // wait. No connect begins while a stop runs. If an ordinary stop gave up waiting,
        // a connect still in flight leaves the flag alone when it returns.
        const seen = self.sta_disconnects.load(.acquire);
        const connecting = self.sta_connecting.load(.acquire);
        if (self.get_sta_state() == .connected) {
            self.leave_ap(.connected, seen);
        } else if (connecting) {
            self.leave_ap(.connecting, seen);
        }
    }

    /// Waits at most 1 s for the connects admitted before the stop or deinit.
    /// A stop can hit this limit if an on_event blocks the Wi-Fi task, including
    /// a stop called from on_event there, which is unsupported.
    ///
    /// The deadline is checked between 1 ms sleeps, so it can be checked late
    /// while a higher-priority task keeps the CPU. The Wi-Fi task does for the
    /// first connect after boot: its software WPA2 key derivation (pbkdf2_sha1,
    /// libwpa_supplicant.a) took well over a second on the ESP32-C3 and ESP32-C6.
    fn wait_for_connects(self: *const Wifi) bool {
        if (callbacks.host_test) return self.connects_in_flight() == 0;
        const deadline = time.Deadline.init_relative(hal_time.get_time_since_boot(), .from_ms(1000));
        while (self.connects_in_flight() != 0) {
            if (deadline.is_reached_by(hal_time.get_time_since_boot())) return false;
            rtos.sleep(.from_ms(1));
        }
        return true;
    }

    /// `seen` is the StaDisconnected count read before the state, so a StaDisconnected that lands
    /// after that read ends the wait even if this `disconnect` posts none. A station still scanning
    /// when it is stopped has sent nothing to leave, and its `disconnect` posts no
    /// `StaDisconnected`, so a connecting station waits for one at most 100 ms and without a warning.
    fn leave_ap(self: *Wifi, from: enum { connected, connecting }, seen: u32) void {
        self.disconnect() catch |err| {
            log.warn("stop: disconnect failed ({t}), stopping without it", .{err});
            return;
        };
        const limit: time.Duration = if (from == .connected) .from_ms(1000) else .from_ms(100);
        const deadline = time.Deadline.init_relative(hal_time.get_time_since_boot(), limit);
        while (self.sta_disconnects.load(.acquire) == seen) {
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

    fn update_sta_state(self: *Wifi, event: EventType) void {
        const new_sta_state: StaState = switch (event) {
            .StaStart => .started,
            .StaConnected => .connected,
            .StaDisconnected => .disconnected,
            .StaStop => .stopped,
            else => return,
        };
        // In this order: `leave_ap_before_stop` reads them in reverse.
        self.sta_state.store(new_sta_state, .release);
        if (new_sta_state == .disconnected) _ = self.sta_disconnects.fetchAdd(1, .release);
        if (new_sta_state != .started) self.sta_connecting.store(false, .release);
    }

    fn update_ap_state(self: *Wifi, event: EventType) void {
        const new_ap_state: ApState = switch (event) {
            .ApStart => .started,
            .ApStop => .stopped,
            else => return,
        };
        self.ap_state.store(new_ap_state, .monotonic);
    }
};

const InitStep = enum { radio, coex, adapter, driver, mode, supplicant, tx, rx_ap, rx_sta, country, power_save };

fn start_session(state: *osi.WifiShutdown, backend: anytype) InitError!void {
    if (state.stage != .off) return error.WifiSessionBusy;
    try backend.run(.radio);
    state.stage = .release;
    inline for (.{ .coex, .adapter, .driver, .mode, .supplicant, .tx, .rx_ap, .rx_sta, .country, .power_save }) |step| {
        run_init_step(backend, step) catch |err| {
            backend.rollback() catch return error.WifiRollbackPending;
            return err;
        };
        if (step == .driver) state.stage = .driver;
        if (step == .supplicant) state.stage = .supplicant;
    }
    state.stage = .running;
}

fn run_init_step(backend: anytype, comptime step: InitStep) InitError!void {
    const entry_depth = if (step == .driver) backend.api_depth() else 0;
    backend.run(step) catch |err| {
        // C3 and C6 libnet80211.a esp_wifi_init_internal take the API lock at
        // +0x3e. PM, WDEV and NET80211 table OOM skip the unlock at +0xe0.
        // Cleanup takes it again at +0x14c and releases only one level.
        if (step == .driver and backend.api_depth() > entry_depth) backend.unlock_api();
        if (step == .supplicant) backend.discard_unregistered();
        return err;
    };
}

extern var wpa_cb: ?*anyopaque;
extern fn eloop_destroy() void;

// C3/C6 libwpa_supplicant.a esp_supplicant_init+0x22 allocates wpa_cb.
// On management-frame registration failure, +0x124 skips the transfer at +0x12a.
// eloop_destroy+0x10 checks the active flag, so a later supplicant deinit can call it again.
// esp_supplicant_common_init has already undone its own registration there.
fn discard_unregistered_wpa(slot: *?*anyopaque, destroy_eloop: anytype) void {
    const table = slot.* orelse return;
    destroy_eloop();
    slot.* = null;
    osi.free(table);
}

const InitBackend = struct {
    config: InitConfig,

    fn run(self: *@This(), comptime step: InitStep) InitError!void {
        const config = self.config;
        switch (step) {
            // Allocates from the attached heap; the argument is unused here.
            .radio => try radio.init(.failing),
            .coex => try c_err(c.coex_init()),
            .adapter => try install_boot_locks(),
            .driver => {
                const init_config = make_init_config(config, &g_wifi_osi_funcs, c.g_wifi_default_wpa_crypto_funcs);
                try c_err(c.esp_wifi_init_internal(&init_config));
            },
            .mode => try c_err(c.esp_wifi_set_mode(c.WIFI_MODE_NULL)),
            .supplicant => {
                if (radio.coex_enabled) try osi.eloop_reservation.reserve(rtos.get_current_task());
                defer if (radio.coex_enabled) osi.eloop_reservation.finish();
                try c_err(c.esp_supplicant_init());
            },
            .tx => try c_err(c.esp_wifi_set_tx_done_cb(tx_done_cb)),
            .rx_ap => try c_err(c.esp_wifi_internal_reg_rxcb(c.ESP_IF_WIFI_AP, recv_cb_ap)),
            .rx_sta => try c_err(c.esp_wifi_internal_reg_rxcb(c.ESP_IF_WIFI_STA, recv_cb_sta)),
            .country => {
                const country = config.country_info.get_wifi_country_t(config.max_tx_power);
                try c_err(c.esp_wifi_set_country(&country));
            },
            .power_save => try set_power_save_mode_internal(config.power_save_mode),
        }
    }

    fn api_depth(_: *@This()) u32 {
        return boot_locks.api_depth(rtos.get_current_task());
    }

    fn unlock_api(_: *@This()) void {
        _ = boot_locks.api.unlock();
    }

    fn discard_unregistered(_: *@This()) void {
        discard_unregistered_wpa(&wpa_cb, eloop_destroy);
    }

    fn rollback(_: *@This()) InternalError!void {
        if (radio.coex_enabled) try deinit_coex() else try release_single(&osi.wifi_shutdown, ShutdownBackend);
    }
};

extern fn esp_wifi_unregister_wpa_cb_internal() c_int;
extern fn esp_wifi_get_user_init_flag_internal() bool;

const ShutdownBackend = struct {
    pub fn stop() InternalError!void {
        try c_err(c.esp_wifi_stop());
    }
    pub fn driver_started() bool {
        return esp_wifi_get_user_init_flag_internal();
    }
    pub fn deinit_supplicant() InternalError!void {
        try c_err(c.esp_supplicant_deinit());
    }
    pub fn unregister_wpa() InternalError!void {
        try c_err(esp_wifi_unregister_wpa_cb_internal());
    }
    pub fn deinit_driver() InternalError!void {
        try c_err(c.esp_wifi_deinit_internal());
    }
    pub fn join(task: *rtos.Task) void {
        rtos.join(task);
    }
    pub fn release() void {
        if (compatibility.chip == .esp32_c6) @import("../analog/esp32_c6.zig").wifi_set_inited(false);
        // The lifecycle entry already refused interrupt and callback context,
        // radio.deinit's only error.
        if (radio.coex_enabled) {
            radio.deinit() catch @panic("Wi-Fi teardown released the radio from a callback");
        } else {
            radio.deinit();
        }
    }
};

// The radio reference is already held. Unwind even if driver init itself failed.
fn configure_single(backend: anytype) InitError!void {
    inline for (.{ .adapter, .driver, .mode, .supplicant, .tx, .rx_ap, .rx_sta, .country, .power_save }) |step| {
        run_init_step(backend, step) catch |err| {
            backend.rollback() catch return error.WifiRollbackPending;
            return err;
        };
    }
}

fn release_single(shutdown: *osi.WifiShutdown, backend: anytype) InternalError!void {
    backend.deinit_driver() catch |err| if (err != error.WifiNotInitialized) return err;
    backend.deinit_supplicant() catch |err| log.debug("supplicant teardown returned {t}", .{err});
    shutdown.join_worker(backend);
    backend.release();
}

fn deinit_coex() InternalError!void {
    return osi.wifi_shutdown.deinit(callbacks.current_task(), if (callbacks.host_test) HostWifi else ShutdownBackend);
}

// Coex start, stop and set_mode run only on a complete session. With no
// session the blob returns 0x3001: C6 libnet80211.a esp_wifi_start+0x3c,
// esp_wifi_set_mode+0x46; esp_wifi_stop through wifi_api_lock+0x56 before
// the first init and ieee80211_ioctl+0x10a after the last deinit.
// A pending teardown or init rollback is retried by its owner.
fn require_running_session() InternalError!void {
    return switch (osi.wifi_shutdown.stage) {
        .running => {},
        .off => error.WifiNotInitialized,
        else => error.WouldBlock,
    };
}

pub const DeinitError = InternalError;

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

pub const WifiMode = enum(u32) {
    /// No interface. `Wifi.init` selects it, and `Wifi.start` succeeds in it.
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

/// Mode change shared by `Wifi.set_mode` and `Wifi.apply` after ownership and lifecycle checks.
inline fn set_mode_unclaimed(mode: WifiMode) InternalError!void {
    try c_err(if (callbacks.host_test) HostWifi.esp_wifi_set_mode(@backingInt(mode)) else c.esp_wifi_set_mode(@backingInt(mode)));
}

fn check_station_config(config: Config.Station) error{InvalidConfig}!void {
    if (config.ssid.len > 32) {
        return error.InvalidConfig;
    }
    if (config.password.len > 64) {
        return error.InvalidConfig;
    }
    // A WPA3-only threshold matches only access points that need SAE (see `wifi_feature_caps`).
    if (config.auth_method == .wpa3_personal) {
        return error.InvalidConfig;
    }
}

fn check_access_point_config(config: Config.AccessPoint) error{InvalidConfig}!void {
    if (config.ssid.len > 32) {
        return error.InvalidConfig;
    }
    if (config.password.len > 64) {
        return error.InvalidConfig;
    }
    // Both would advertise SAE, which the linked supplicant cannot run (see `wifi_feature_caps`).
    if (config.auth_method == .wpa3_personal or config.auth_method == .wpa2_wpa3_personal) {
        return error.InvalidConfig;
    }
}

fn apply_access_point_config(config: Config.AccessPoint) ConfigError!void {
    try check_access_point_config(config);

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
    try c_err(set_config(c.WIFI_IF_AP, &tmp));
}

fn set_config(interface: c.wifi_interface_t, config: *c_patched.wifi_config_t) c.esp_err_t {
    return if (callbacks.host_test) HostWifi.esp_wifi_set_config(interface) else c_patched.esp_wifi_set_config(interface, config);
}

fn set_power_save_mode_internal(mode: PowerSaveMode) PowerSaveError!void {
    if (compatibility.chip == .esp32_c6 and mode != .none) return error.PowerSaveUnsupported;
    if (callbacks.host_test) return;
    try c_err(c.esp_wifi_set_ps(@backingInt(mode)));
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

const HostStopLock = struct {
    locked: ?*rtos.Task = null,
    on_wait: ?*const fn (*HostStopLock) void = null,

    fn lock_with_timeout(self: *HostStopLock, _: rtos.Timeout) rtos.TimeoutError!void {
        if (self.locked != null) {
            const on_wait = self.on_wait orelse return error.Timeout;
            on_wait(self);
        }
        assert(self.locked == null);
        self.locked = callbacks.current_task();
    }

    fn unlock(self: *HostStopLock) void {
        assert(self.locked == callbacks.current_task());
        self.locked = null;
    }
};

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
    const routed: ?EventType = blk: {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        const wifi = owner orelse break :blk null;
        const event_type: EventType = @fromBackingInt(id);
        wifi.update_sta_state(event_type);
        wifi.update_ap_state(event_type);
        break :blk event_type;
    };
    const event_type = routed orelse {
        log.debug("dropping event without a Wi-Fi owner: {}", .{id});
        return;
    };
    log.debug("event received: {t}", .{event_type});

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
        const scope = callbacks.Scope.enter();
        defer scope.leave();
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

pub const Interface = enum(u32) {
    ap = c.WIFI_IF_AP,
    sta = c.WIFI_IF_STA,

    pub fn is_active(self: Interface, wifi: *const Wifi) InternalError!bool {
        const mode = try wifi.get_mode();
        return switch (self) {
            .ap => mode.is_ap(),
            .sta => mode.is_sta(),
        };
    }
};

fn tx_done_cb(
    iface_idx: u8,
    data_ptr: [*c]u8,
    data_len: [*c]u16,
    status: bool,
) callconv(.c) void {
    log.debug("tx_done_cb", .{});

    if (wifi_options.on_packet_transmitted) |on_packet_transmitted| {
        const interface = std.enums.fromInt(Interface, iface_idx) orelse return;
        const scope = callbacks.Scope.enter();
        defer scope.leave();
        on_packet_transmitted(interface, data_ptr[0..data_len.*], status);
    }
}

fn recv_cb_ap(buf: ?*anyopaque, len: u16, eb: ?*anyopaque) callconv(.c) c.esp_err_t {
    log.debug("recv_cb_ap {?} {} {?}", .{ buf, len, eb });

    if (wifi_options.on_packet_received) |on_packet_received| {
        const scope = callbacks.Scope.enter();
        defer scope.leave();
        on_packet_received(.ap, @as([*]const u8, @ptrCast(buf))[0..len]);
    }
    c.esp_wifi_internal_free_rx_buffer(eb);

    return c.ESP_OK;
}

fn recv_cb_sta(buf: ?*anyopaque, len: u16, eb: ?*anyopaque) callconv(.c) c.esp_err_t {
    log.debug("recv_cb_sta {?} {} {?}", .{ buf, len, eb });

    if (wifi_options.on_packet_received) |on_packet_received| {
        const scope = callbacks.Scope.enter();
        defer scope.leave();
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

/// SAFETY: There can be only one scan iterator at a time. Deinit it before deinitializing Wi-Fi.
pub const ScanResultsIterator = struct {
    wifi: *const Wifi,
    remaining: u16,
    ap_record: c_patched.wifi_ap_record_t = undefined,

    /// Blocks the current thread until the scan finishes and returns an
    /// iterator for the scan results.
    fn init(wifi: *const Wifi) InternalError!ScanResultsIterator {
        var ap_count: u16 = undefined;
        try c_err(c.esp_wifi_scan_get_ap_num(&ap_count));
        return .{ .wifi = wifi, .remaining = ap_count };
    }

    pub fn deinit(self: ScanResultsIterator) InternalError!void {
        try self.wifi.require_operational();
        // free any ap records that were not returned
        c_err(c.esp_wifi_clear_ap_list()) catch |err| {
            std.log.warn("failed to clear ap list: {t}", .{err});
        };
    }

    /// SAFETY: AP_Record strings last until the next call to next.
    pub fn next(self: *ScanResultsIterator) InternalError!?AP_Record {
        try self.wifi.require_operational();
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

    /// WPA3 Personal authentication. Not supported: the linked supplicant has no SAE (see
    /// `wifi_feature_caps`), so an access point or a station threshold of this value is
    /// `error.InvalidConfig`. Scan records may still report it.
    wpa3_personal = c.WIFI_AUTH_WPA3_PSK,

    /// WPA2/WPA3 Personal authentication (supports both). An access point cannot offer it
    /// (`error.InvalidConfig`), as it would advertise SAE. A station threshold of this value is
    /// accepted, since such an access point also offers WPA2, and scan records may report it.
    wpa2_wpa3_personal = c.WIFI_AUTH_WPA2_WPA3_PSK,

    /// WLAN Authentication and Privacy Infrastructure (WAPI).
    wapi_personal = c.WIFI_AUTH_WAPI_PSK,
};

fn export_symbols() void {
    @export(&g_wifi_osi_funcs, .{ .name = "g_wifi_osi_funcs" });
}

// ESP-IDF v5.5.1's station_example_main.c passes a stack-local config in wifi_init_sta.
// The blob tables are parameters so host tests can build a configuration without linking them.
fn make_init_config(
    config: InitConfig,
    osi_funcs: *c.wifi_osi_funcs_t,
    wpa_crypto_funcs: c.wpa_crypto_funcs_t,
) c.wifi_init_config_t {
    return .{
        .osi_funcs = osi_funcs,
        .wpa_crypto_funcs = wpa_crypto_funcs,
        .static_rx_buf_num = config.static_rx_buf_num,
        .dynamic_rx_buf_num = config.dynamic_rx_buf_num,
        .tx_buf_type = c.CONFIG_ESP_WIFI_TX_BUFFER_TYPE,
        .static_tx_buf_num = config.static_tx_buf_num,
        .dynamic_tx_buf_num = config.dynamic_tx_buf_num,
        // IDF WIFI_INIT_CONFIG_DEFAULT: 0 = static, 1 = dynamic. The STATIC_RX_MGMT_BUFFER
        // choice flag is 1 when static is selected, which would request dynamic buffers.
        .rx_mgmt_buf_type = c.CONFIG_ESP_WIFI_DYNAMIC_RX_MGMT_BUF,
        .rx_mgmt_buf_num = c.CONFIG_ESP_WIFI_RX_MGMT_BUF_NUM_DEF,
        .cache_tx_buf_num = c.WIFI_CACHE_TX_BUFFER_NUM,
        .csi_enable = 0, // TODO: WiFi channel state information enable flag.
        .ampdu_rx_enable = @intFromBool(config.ampdu_rx_enable),
        .ampdu_tx_enable = @intFromBool(config.ampdu_tx_enable),
        .amsdu_tx_enable = @intFromBool(config.amsdu_tx_enable),
        .nvs_enable = 0,
        .nano_enable = 0,
        .rx_ba_win = config.rx_ba_win,
        .wifi_task_core_id = 0,
        .beacon_max_len = c.WIFI_SOFTAP_BEACON_MAX_LEN,
        .mgmt_sbuf_num = c.WIFI_MGMT_SBUF_NUM,
        .feature_caps = wifi_feature_caps,
        .sta_disconnected_pm = false,
        .espnow_max_encrypt_num = c.CONFIG_ESP_WIFI_ESPNOW_MAX_ENCRYPT_NUM,
        .tx_hetb_queue_num = 3,
        .dump_hesigb_enable = false,
        .magic = c.WIFI_INIT_CONFIG_MAGIC,
    };
}

const wifi_enable_wpa3_sae: u64 = 1 << 0; // not set, see wifi_feature_caps
const wifi_enable_enterprise: u64 = 1 << 7;
// const wifi_ftm_initiator: u64 = 1 << 2;
// const wifi_ftm_responder: u64 = 1 << 3;
// const wifi_enable_gcmp: u64 = 1 << 4;
// const wifi_enable_gmac: u64 = 1 << 5;
// const wifi_enable_11r: u64 = 1 << 6;

// The blob reads these capabilities only from wifi_init_config_t.feature_caps (make_init_config),
// as ESP-IDF v5.5.1's WIFI_INIT_CONFIG_DEFAULT passes WIFI_FEATURE_CAPS (esp_wifi.h), which
// includes WIFI_ENABLE_WPA3_SAE only with CONFIG_ESP_WIFI_ENABLE_WPA3_SAE. The linked C3 and C6
// libwpa_supplicant.a were built without SAE. Their sae.c and esp_wpa3.c objects are present but
// define no symbols (ESP-IDF compiles both unconditionally; sae.c's body is guarded by
// CONFIG_WPA3_SAE, esp_wpa3.c's by CONFIG_WPA3_SAE and CONFIG_SAE), nothing defines a
// crypto_ec_* function, and
// esp_supplicant_init references neither esp_wifi_register_wpa3_cb nor
// esp_wifi_register_wpa3_ap_cb. esp_wpa_main.c calls both unconditionally; esp_wpa3_i.h stubs the
// first out without CONFIG_WPA3_SAE and the second without CONFIG_SAE
// (CONFIG_ESP_WIFI_SOFTAP_SAE_SUPPORT). Advertising SAE would let the blob choose an SAE handshake
// that no supplicant callback runs.
const wifi_feature_caps: u64 = wifi_enable_enterprise;

// The blob retains this OS adapter table through its C ABI.
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
        ._semphr_delete = osi.WifiPpSlots.delete_sem,
        // IDF v5.5.1 esp_wifi/esp32c6/esp_adapter.c:598-599 shares the
        // coex semaphore ABI. ieee80211_ioctl reads the driver's return
        // status only when its completion semaphore take returns pdTRUE.
        ._semphr_take = if (radio.coex_enabled) @import("coex.zig").SemaphoreSlots.take else osi.semphr_take,
        ._semphr_give = if (radio.coex_enabled) @import("coex.zig").SemaphoreSlots.give else osi.semphr_give,
        ._wifi_thread_semphr_get = osi.wifi_thread_semphr_get,
        ._mutex_create = osi.mutex_create,
        ._recursive_mutex_create = if (radio.coex_enabled) osi.wifi_recursive_mutex_create else osi.recursive_mutex_create,
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
        ._task_delete = osi.wifi_task_delete,
        ._task_delay = osi.task_delay,
        ._task_ms_to_tick = osi.task_ms_to_tick,
        ._task_get_current_task = osi.task_get_current_task,
        ._task_get_max_priority = osi.task_get_max_priority,
        ._malloc = osi.malloc,
        ._free = if (radio.coex_enabled) osi.wifi_shutdown_free else osi.free,
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
        ._timer_setfn = if (radio.coex_enabled) osi.wifi_timer_setfn else osi.timer_setfn,
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
        ._wifi_malloc = if (radio.coex_enabled) osi.wifi_shutdown_malloc else osi.wifi_malloc,
        ._wifi_realloc = osi.wifi_realloc,
        ._wifi_calloc = osi.wifi_calloc,
        ._wifi_zalloc = if (radio.coex_enabled) osi.wifi_shutdown_zalloc else osi.wifi_zalloc,
        ._wifi_create_queue = osi.wifi_create_queue,
        ._wifi_delete_queue = osi.WifiPpSlots.delete_queue,
        ._coex_init = osi.coex_init,
        ._coex_deinit = osi.coex_deinit,
        ._coex_enable = osi.coex_enable,
        ._coex_disable = osi.coex_disable,
        ._coex_status_get = osi.coex_status_get,
        ._coex_condition_set = if (radio.coex_enabled) null else @ptrCast(&osi.coex_condition_set),
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
    if (radio.coex_enabled) f._coex_schm_get_phase_by_idx = @import("coex.zig").coex_schm_get_phase_by_idx;
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

test "coex Wi-Fi init releases each acquired stage and only the owner retries rollback" {
    if (!radio.coex_enabled) return error.SkipZigTest;
    const Host = struct {
        state: osi.WifiShutdown = .{},
        caller: rtos.Task = undefined,
        fail_step: ?InitStep = null,
        early_table_oom: bool = false,
        init_caller: ?*rtos.Task = null,
        locks: osi.WifiBootLocks = .{},
        manual_delete: bool = false,
        reject_deinit_post: bool = false,
        radio_ref: bool = false,
        driver: bool = false,
        registered_wpa: ?*anyopaque = null,
        next_step: usize = 0,
        joins: usize = 0,

        var pp_handle: ?*rtos.Task = null;
        var unregistered: ?*anyopaque = null;
        var eloop_lock: ?*anyopaque = null;
        var eloop_timer: ?*@import("timer.zig").Timer = null;

        fn run(self: *@This(), comptime step: InitStep) InitError!void {
            assert(self.next_step == @backingInt(step));
            self.next_step += 1;
            if (step == .driver) {
                if (!self.take_api()) return error.WouldBlock;
                if (self.early_table_oom) {
                    assert(pp_handle == null and self.state.worker == null);
                    assert(self.take_api()); // blob's shared failure epilogue
                    self.unlock_api();
                    return error.OutOfMemory;
                }
                self.unlock_api(); // normal pre-worker unlock at +0xe0
                const mem = try osi.callback_allocator().alignedAlloc(u8, .@"16", @sizeOf(rtos.Task) + 256);
                const task: *rtos.Task = @ptrCast(mem.ptr);
                task.* = .{ .context = undefined, .stack = mem[@sizeOf(rtos.Task)..], .priority = .lowest, .allocation_alignment = .@"16" };
                self.state.record_worker(task);
                pp_handle = task;
                if (self.fail_step == step) {
                    if (self.manual_delete)
                        self.state.delete_task(task, &self.caller, detach, exit)
                    else
                        self.state.delete_task(null, task, detach, exit);
                    pp_handle = null; // blob clears its only handle before returning
                }
            }
            if (step == .supplicant) {
                assert(unregistered == null and eloop_lock == null);
                var reservation: osi.EloopReservation = .{};
                try reservation.reserve(&self.caller);
                defer reservation.finish();
                unregistered = osi.calloc(1, 0x6c) orelse return error.OutOfMemory;
                eloop_timer = reservation.take_timer(&self.caller).?;
                eloop_lock = reservation.take_mutex(&self.caller).?;
            }
            if (self.fail_step == step) return error.WifiOther;
            switch (step) {
                .radio => self.radio_ref = true,
                .driver => self.driver = true,
                .supplicant => {
                    self.registered_wpa = unregistered;
                    unregistered = null;
                },
                else => {},
            }
        }

        fn take_api(self: *@This()) bool {
            const caller = self.init_caller orelse &self.caller;
            if (self.locks.api.owning_task) |locking_task| {
                if (locking_task != caller) return false;
            }
            self.locks.api.owning_task = caller;
            self.locks.api.value += 1;
            return true;
        }
        fn api_depth(self: *@This()) u32 {
            return self.locks.api_depth(self.init_caller orelse &self.caller);
        }
        fn unlock_api(self: *@This()) void {
            assert(self.api_depth() > 0);
            self.locks.api.value -= 1;
            if (self.locks.api.value == 0) self.locks.api.owning_task = null;
        }
        fn detach(task: *rtos.Task) void {
            task.state = .exited;
        }
        fn exit(action: rtos.YieldAction) void {
            assert(action == .exit);
            pp_handle.?.state = .exited;
        }
        fn destroy_eloop() void {
            osi.callback_allocator().destroy(eloop_timer.?);
            eloop_timer = null;
            osi.mutex_delete(eloop_lock);
            eloop_lock = null;
        }
        fn discard_unregistered(_: *@This()) void {
            discard_unregistered_wpa(&unregistered, destroy_eloop);
        }
        fn rollback(self: *@This()) InternalError!void {
            try self.state.deinit(&self.caller, self);
        }
        pub fn stop(_: *@This()) InternalError!void {}
        pub fn driver_started(_: *@This()) bool {
            return false;
        }
        pub fn deinit_supplicant(self: *@This()) InternalError!void {
            assert(self.registered_wpa != null);
            destroy_eloop();
            try self.unregister_wpa();
        }
        pub fn unregister_wpa(self: *@This()) InternalError!void {
            osi.free(self.registered_wpa);
            self.registered_wpa = null;
        }
        pub fn deinit_driver(self: *@This()) InternalError!void {
            assert(self.driver);
            if (self.reject_deinit_post) return error.WouldBlock;
            self.state.delete_task(null, pp_handle.?, detach, exit);
            pp_handle = null;
            self.driver = false;
        }
        pub fn join(self: *@This(), task: *rtos.Task) void {
            assert(!self.driver and self.radio_ref and pp_handle == null and task.state == .exited);
            self.joins += 1;
        }
        pub fn release(self: *@This()) void {
            assert(!self.driver and self.radio_ref);
            self.radio_ref = false;
        }
    };

    var host: Host = .{};
    var route: @import("shared_heap.zig").TestRoute = .{};
    route.install(std.testing.failing_allocator);
    defer route.restore();
    for (std.enums.values(InitStep)) |step| {
        for ([_]bool{ false, true }) |manual| {
            var accounting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            route.reroute(accounting.allocator());
            host = .{ .fail_step = step, .manual_delete = manual };
            try std.testing.expectError(error.WifiOther, start_session(&host.state, &host));
            try std.testing.expectEqual(@backingInt(step) + 1, host.next_step);
            try std.testing.expectEqual(@intFromBool(@backingInt(step) >= @backingInt(InitStep.driver)), host.joins);
            try std.testing.expect(host.state.stage == .off and !host.radio_ref);
            try std.testing.expect(Host.eloop_lock == null and Host.unregistered == null);
            try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
        }
    }

    // Fail in the table constructors before pp_create_task. Keep the same
    // boot mutexes across sessions and preserve a caller's preexisting depth.
    for ([_]bool{ false, true }) |already_locked| {
        var second_task: rtos.Task = undefined;
        route.reroute(std.testing.allocator);
        host = .{ .early_table_oom = true };
        if (already_locked) try std.testing.expect(host.take_api());
        try std.testing.expectError(error.OutOfMemory, start_session(&host.state, &host));
        try std.testing.expect(host.state.stage == .off and host.joins == 0);
        try std.testing.expectEqual(@intFromBool(already_locked), host.api_depth());
        if (already_locked) host.unlock_api();
        host.init_caller = &second_task;
        host.early_table_oom = false;
        host.next_step = 0;
        try start_session(&host.state, &host);
        try host.rollback();
        try std.testing.expect(host.joins == 1 and host.locks.api.owning_task == null);
    }

    // Worker, reserved eloop timer, reserved mutex, and the blob's wpa_cb.
    for (0..4) |fail_index| {
        var accounting = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        route.reroute(accounting.allocator());
        host = .{};
        try std.testing.expectError(error.OutOfMemory, start_session(&host.state, &host));
        try std.testing.expect(host.state.stage == .off and Host.unregistered == null);
        try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
    }

    for ([_]bool{ true, false }) |fail_registration| {
        var accounting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        route.reroute(accounting.allocator());
        host = .{ .fail_step = if (fail_registration) .supplicant else null, .reject_deinit_post = fail_registration };
        if (fail_registration) {
            try std.testing.expectError(error.WifiRollbackPending, start_session(&host.state, &host));
            try std.testing.expect(host.state.stage == .driver and Host.eloop_lock == null and Host.unregistered == null);
        } else try start_session(&host.state, &host);
        const steps = host.next_step;
        try std.testing.expectError(error.WifiSessionBusy, start_session(&host.state, &host));
        try std.testing.expect(host.driver and host.radio_ref and host.next_step == steps);
        host.reject_deinit_post = false;
        try host.rollback();
        try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
    }
}

// Replace blob calls only. Public validation, ownership, startup and shutdown
// stages, event dispatch and callback context are shared with firmware.
// Each esp_* function returns what C6 libnet80211.a returns in that state.
// Association is not modelled: connect and disconnect post no events.
const HostWifi = struct {
    // wifi_init_completed: init state 3, from esp_wifi_init_internal until
    // esp_wifi_deinit_internal.
    var initialized = false;
    // g_wifi_nvs byte 0.
    var mode: c.wifi_mode_t = c.WIFI_MODE_NULL;
    // g_ic+0x1f1 == 2, set by wifi_start_process+0x7c after the start events
    // and cleared by wifi_stop_process+0x60 after the stop events.
    var started = false;

    const not_init = 0x3001;
    const not_started = 0x3002;
    const not_stopped = 0x3003;
    const mode_error = 0x3005;
    const wifi_post = 0x3012;
    const no_mem = 0x101;
    const fail = -1;

    var on_adapter: ?*const fn () InitError!void = null;
    var on_country: ?*const fn () InitError!void = null;

    fn run(_: *@This(), comptime step: InitStep) InitError!void {
        switch (step) {
            .radio => try radio.init(.failing),
            .adapter => if (on_adapter) |probe| try probe(),
            .driver => initialized = true,
            .mode => try c_err(esp_wifi_set_mode(c.WIFI_MODE_NULL)),
            .country => if (on_country) |probe| try probe(),
            else => {},
        }
    }

    fn has_sta(m: c.wifi_mode_t) bool {
        return m == c.WIFI_MODE_STA or m == c.WIFI_MODE_APSTA;
    }
    fn has_ap(m: c.wifi_mode_t) bool {
        return m == c.WIFI_MODE_AP or m == c.WIFI_MODE_APSTA;
    }

    // The packet task posts interface events synchronously inside the ioctl:
    // wifi_station_start+0xda (StaStart), wifi_station_stop+0x9c (StaStop),
    // wifi_softap_start+0x378 (ApStart), wifi_softap_stop+0x1be (ApStop).
    fn post(event: EventType) void {
        var packet_task: rtos.Task = .{ .context = undefined, .stack = &.{}, .priority = .lowest };
        const previous_task = callbacks.host_current;
        callbacks.host_current = &packet_task;
        defer callbacks.host_current = previous_task;
        assert(osi.esp_event_post("WIFI_EVENT", @backingInt(event), null, 0, 0) == 0);
    }

    // _do_wifi_start: station first, then soft-AP.
    fn start_interfaces(m: c.wifi_mode_t) void {
        if (has_sta(m)) post(.StaStart);
        if (has_ap(m)) post(.ApStart);
    }

    // _do_wifi_stop: each stop posts only for an interface that is running
    // (wifi_station_stop+0x14..0x1c, wifi_softap_stop+0x20..0x2a).
    fn stop_interfaces(m: c.wifi_mode_t) void {
        if (has_sta(m)) post(.StaStop);
        if (has_ap(m)) post(.ApStop);
    }

    fn esp_wifi_start() i32 {
        if (!initialized) return not_init; // esp_wifi_start+0xc
        if (started) return 0; // wifi_start_process+0x1c
        start_interfaces(mode);
        started = true;
        return 0;
    }

    // Stop steps the full PP queue rejects, and how many 24-byte ioctls the
    // heap still grants (null: all) when the reserved one is unavailable.
    var reject_stop: struct { interfaces: bool = false, hardware: bool = false } = .{};
    var ioctl_heap_budget: ?usize = null;
    var reserved_ioctls: usize = 0;

    // esp_wifi_stop allocates one 24-byte ioctl per step (+0x2a, +0xf8,
    // +0x18c); ieee80211_ioctl+0x1c4 frees it before the next.
    fn stop_ioctl() bool {
        if (osi.wifi_shutdown.reserve_ioctl(callbacks.current_task(), 24)) |ioctl| {
            reserved_ioctls += 1;
            assert(osi.wifi_shutdown.release_ioctl(ioctl));
            return true;
        }
        if (ioctl_heap_budget) |*budget| {
            if (budget.* == 0) return false;
            budget.* -= 1;
        }
        return true;
    }

    fn esp_wifi_stop() i32 {
        if (!initialized) return not_init;
        if (!stop_ioctl()) return no_mem; // +0x2a..0x56, before step 0
        // wifi_stop_process+0x20 returns 0x3002 when stopped;
        // esp_wifi_stop+0xde maps it to success at +0x1d6.
        if (!started) return 0;
        // +0xcc..0xe2 goes on past a rejected step 0.
        if (!reject_stop.interfaces) {
            stop_interfaces(mode);
            started = false;
        }
        if (!stop_ioctl()) return no_mem; // step 1, +0xf4..0x11e
        if (!stop_ioctl()) return no_mem; // step 2, +0x188..0x194
        return if (reject_stop.hardware) wifi_post else 0;
    }

    // Interface configurations, and whether each ran under the lifecycle claim.
    var configured: [4]struct { interface: c.wifi_interface_t, claimed: bool } = undefined;
    var configured_len: usize = 0;

    // esp_wifi_set_config+0x12..0x16 returns 0x3001 before init completes, then
    // posts wifi_set_config_process; the interface checks are not modelled.
    fn esp_wifi_set_config(interface: c.wifi_interface_t) i32 {
        if (!initialized) return not_init;
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        configured[configured_len] = .{ .interface = interface, .claimed = owner.?.lifecycle_active.load(.acquire) };
        configured_len += 1;
        return 0;
    }

    fn esp_wifi_set_mode(new: c.wifi_mode_t) i32 {
        if (!initialized) return not_init; // esp_wifi_set_mode+0x10
        const old = mode;
        if (started and old != new) {
            // wifi_set_mode_process+0x50: wifi_stop_old_mode, then
            // _do_wifi_start for each interface the new mode adds (+0x11c, +0xd8).
            if (has_sta(old) and !has_sta(new)) post(.StaStop);
            if (has_ap(old) and !has_ap(new)) post(.ApStop);
            if (has_sta(new) and !has_sta(old)) post(.StaStart);
            if (has_ap(new) and !has_ap(old)) post(.ApStart);
        }
        mode = new; // wifi_set_mode_process+0xec
        return 0;
    }

    fn esp_wifi_get_mode(out: *c.wifi_mode_t) i32 {
        if (!initialized) return not_init; // esp_wifi_get_mode+0x10
        out.* = mode;
        return 0;
    }

    var connect_calls: usize = 0;
    var disconnect_calls: usize = 0;

    fn esp_wifi_connect_internal() i32 {
        connect_calls += 1;
        if (!initialized) return not_init; // +0xc
        if (!started) return not_started; // +0x18
        if (!has_sta(mode)) return mode_error; // wifi_connect_process+0x16, +0x5c
        return 0;
    }

    fn esp_wifi_disconnect_internal() i32 {
        disconnect_calls += 1;
        if (!initialized) return not_init; // +0xc
        if (!started) return not_started; // +0x18
        if (!has_sta(mode)) return fail; // wifi_disconnect_process+0x24, +0x3e
        return 0;
    }

    fn api_depth(_: *@This()) u32 {
        return 0;
    }
    fn unlock_api(_: *@This()) void {
        unreachable; // The simulated driver never acquires the blob API lock.
    }
    fn discard_unregistered(_: *@This()) void {}
    fn rollback(_: *@This()) InternalError!void {
        if (radio.coex_enabled) try deinit_coex() else try release_single(&osi.wifi_shutdown, @This());
    }

    // Shutdown backend.
    var reject_deinit_driver = false;
    var deinit_driver_gone = false;

    pub fn stop() InternalError!void {
        try c_err(esp_wifi_stop());
    }
    pub fn driver_started() bool {
        return started;
    }
    pub fn deinit_supplicant() InternalError!void {}
    pub fn unregister_wpa() InternalError!void {}
    pub fn deinit_driver() InternalError!void {
        if (started) return c_err(not_stopped);
        // A full PP queue fails the deinit ioctl with 0x3012
        // (ieee80211_ioctl+0x15a..0x18e); the driver stays initialized.
        if (reject_deinit_driver) return c_err(wifi_post);
        initialized = false;
        started = false;
        mode = c.WIFI_MODE_NULL;
        // esp_wifi_deinit_internal+0x6e..0x7e answers a driver already deinitialised.
        if (deinit_driver_gone) return c_err(not_init);
    }
    pub fn join(_: *rtos.Task) void {
        unreachable; // The simulated driver starts no PP task.
    }
    pub fn release() void {
        if (radio.coex_enabled) radio.deinit() catch unreachable else radio.deinit();
    }
};

const host_session_allocator = if (radio.coex_enabled) std.testing.failing_allocator else std.testing.allocator;

test "public Wi-Fi init validates options before acquiring a session" {
    var wifi: Wifi = .{};
    errdefer EventLog.end_failed_session(&wifi);
    const allocator = host_session_allocator;
    if (!microzig.options.hal.radio.radios.wifi) {
        try std.testing.expectError(error.UnsupportedRadioProtocol, wifi.init(allocator, .{}));
        try std.testing.expectError(error.UnsupportedRadioProtocol, wifi.init(allocator, .{ .power_save_mode = .min }));
    } else {
        try std.testing.expectError(error.PowerSaveUnsupported, wifi.init(allocator, .{ .power_save_mode = .min }));
        try std.testing.expect(osi.wifi_shutdown.stage == .off and !wifi.lifecycle_active.load(.acquire));
        if (radio.coex_enabled) @import("host_test_heap.zig").attach();
        try wifi.init(allocator, .{});
        try wifi.deinit();
    }
    try std.testing.expect(osi.wifi_shutdown.stage == .off and !wifi.lifecycle_active.load(.acquire));
}

test "ordinary StaStart reaches the configured Wi-Fi listener" {
    var wifi: Wifi = .{};
    if (radio.coex_enabled) @import("host_test_heap.zig").attach();
    try wifi.init(host_session_allocator, .{});
    errdefer EventLog.end_failed_session(&wifi);
    var event_id: i32 = -1;
    const previous_observer = microzig.observed_wifi_event;
    microzig.observed_wifi_event = &event_id;
    defer microzig.observed_wifi_event = previous_observer;
    on_event_post(@backingInt(EventType.StaStart), null, 0);
    try std.testing.expectEqual(@backingInt(EventType.StaStart), event_id);
    try std.testing.expectEqual(StaState.started, wifi.get_sta_state());
    try wifi.deinit();
}

// Records every Wi-Fi event the configured listener receives.
const EventLog = struct {
    var events: [16]EventType = undefined;
    var len: usize = 0;

    listener: @TypeOf(microzig.wifi_listener),

    fn on_event(event: Event) void {
        events[len] = event;
        len += 1;
    }

    fn install() EventLog {
        if (radio.coex_enabled) @import("host_test_heap.zig").attach();
        const saved: EventLog = .{ .listener = microzig.wifi_listener };
        microzig.wifi_listener = on_event;
        len = 0;
        return saved;
    }

    fn restore(saved: EventLog) void {
        microzig.wifi_listener = saved.listener;
        len = 0;
    }

    // Registered with errdefer after `defer restore`, so it runs only when the
    // test already failed, and before restore. It ends any session or
    // lifecycle claim the failed test left, so later tests start from boot state.
    fn end_failed_session(wifi: *Wifi) void {
        wifi.lifecycle_active.store(false, .release);
        HostWifi.reject_deinit_driver = false;
        HostWifi.deinit_driver_gone = false;
        HostWifi.reject_stop = .{};
        HostWifi.ioctl_heap_budget = null;
        osi.wifi_shutdown.ioctl_in_use = false;
        osi.disconnect_gate = .{};
        microzig.wifi_listener = on_event;
        len = 0;
        wifi.deinit() catch {
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            if (owner == wifi) {
                osi.wifi_shutdown = .{};
                owner = null;
            }
        };
        HostWifi.initialized = false;
        HostWifi.started = false;
        HostWifi.mode = c.WIFI_MODE_NULL;
    }

    fn take() []const EventType {
        defer len = 0;
        return events[0..len];
    }
};

test "public Wi-Fi calls before init and after final deinit return WifiNotInitialized" {
    var wifi: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);
    for (0..2) |round| {
        try std.testing.expect(osi.wifi_shutdown.stage == .off);
        try std.testing.expectError(error.WifiNotInitialized, wifi.start());
        try std.testing.expectError(error.WifiNotInitialized, wifi.stop());
        try std.testing.expectError(error.WifiNotInitialized, wifi.set_mode(.sta));
        try std.testing.expectError(error.WifiNotInitialized, wifi.get_mode());
        try std.testing.expectError(error.WifiNotInitialized, wifi.connect());
        try std.testing.expectError(error.WifiNotInitialized, wifi.disconnect());
        try std.testing.expectError(error.WifiNotInitialized, wifi.deinit());
        try std.testing.expect(!wifi.lifecycle_active.load(.acquire));
        if (round == 0) {
            try wifi.init(host_session_allocator, .{});
            try wifi.set_mode(.sta);
            try wifi.start();
            try wifi.deinit();
        }
    }
    try std.testing.expectEqualSlices(EventType, &.{ .StaStart, .StaStop }, EventLog.take());
}

test "a second Wi-Fi handle cannot change the running driver or its own state" {
    var first: Wifi = .{};
    var second: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&first);
    const allocator = host_session_allocator;
    try first.init(allocator, .{});
    try first.set_mode(.ap_sta);
    try first.start();
    second.sta_state.store(.stopped, .monotonic);
    try std.testing.expectError(error.AlreadyInitialized, second.init(allocator, .{ .power_save_mode = .min }));
    try std.testing.expectError(error.WifiNotInitialized, second.apply(.{ .sta = .{ .ssid = "net" } }));
    try std.testing.expectError(error.WifiNotInitialized, second.apply_station_config(.{ .ssid = "net" }));
    try std.testing.expectError(error.WifiNotInitialized, second.set_mode(.sta));
    try std.testing.expectError(error.WifiNotInitialized, second.get_mode());
    try std.testing.expectError(error.WifiNotInitialized, second.start());
    try std.testing.expectError(error.WifiNotInitialized, second.stop());
    try std.testing.expectError(error.WifiNotInitialized, second.connect());
    try std.testing.expectError(error.WifiNotInitialized, second.disconnect());
    try std.testing.expectError(error.WifiNotInitialized, second.scan(.{}));
    try std.testing.expectError(error.WifiNotInitialized, second.send_packet(.sta, "frame"));
    try std.testing.expectError(error.WifiNotInitialized, second.set_protocol(&.{.P802D11BGN}));
    try std.testing.expectError(error.WifiNotInitialized, second.set_inactive_time(.sta, 6));
    try std.testing.expectError(error.WifiNotInitialized, second.set_power_save_mode(.min));
    try std.testing.expectError(error.WifiNotInitialized, second.get_sta_rssi());
    try std.testing.expectError(error.WifiNotInitialized, Interface.sta.is_active(&second));
    try std.testing.expectError(error.WifiNotInitialized, second.deinit());
    try std.testing.expectEqual(WifiMode.ap_sta, try first.get_mode());
    try std.testing.expectEqual(StaState.started, first.get_sta_state());
    try std.testing.expectEqual(ApState.started, first.get_ap_state());
    try std.testing.expectEqual(StaState.stopped, second.get_sta_state());
    try std.testing.expectEqualSlices(EventType, &.{ .StaStart, .ApStart }, EventLog.take());
    try first.deinit();

    try std.testing.expectError(error.PowerSaveUnsupported, first.init(allocator, .{ .power_save_mode = .min }));
    try std.testing.expectEqual(StaState.stopped, first.get_sta_state());
    try std.testing.expectEqual(ApState.stopped, first.get_ap_state());

    // Claiming ownership resets existing handle state.
    errdefer EventLog.end_failed_session(&second);
    try second.init(allocator, .{});
    try std.testing.expectEqual(StaState.none, second.get_sta_state());
    try std.testing.expectEqual(ApState.none, second.get_ap_state());
    try std.testing.expectEqual(WifiMode.none, try second.get_mode());
    try second.deinit();
}

test "events posted with no Wi-Fi owner are dropped" {
    var wifi: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);
    try wifi.init(host_session_allocator, .{});
    try wifi.set_mode(.ap_sta);
    try wifi.start();
    try wifi.deinit();
    try std.testing.expectEqualSlices(EventType, &.{ .StaStart, .ApStart, .StaStop, .ApStop }, EventLog.take());

    HostWifi.post(.StaStart);
    HostWifi.post(.ApStart);
    try std.testing.expectEqual(StaState.stopped, wifi.get_sta_state());
    try std.testing.expectEqual(ApState.stopped, wifi.get_ap_state());
    try std.testing.expectEqual(0, EventLog.take().len);
}

test "a stop queued across single-radio teardown prevents reuse until it returns" {
    if (radio.coex_enabled) return error.SkipZigTest;
    const Probe = struct {
        fn on_wait(lock: *HostStopLock) void {
            const handle: *Wifi = @fieldParentPtr("stop_lock", lock);
            const waiter = callbacks.host_current;
            callbacks.host_current = lock.locked.?;
            defer callbacks.host_current = waiter;

            // The earlier task finishes teardown before this task acquires the lock.
            handle.end_stop(.deinit, true);
            assert(handle.calls.stops == 1);
            if (handle.init(host_session_allocator, .{})) |_| unreachable else |err| {
                assert(err == error.WifiSessionBusy);
            }
        }
    };
    var wifi: Wifi = .{};
    try std.testing.expect(!try wifi.claim_init(.{}));
    wifi.finish_init(.ready);
    errdefer EventLog.end_failed_session(&wifi);
    try wifi.begin_stop(.stop);
    wifi.stop_lock.on_wait = Probe.on_wait;

    var waiter: rtos.Task = undefined;
    const previous_task = callbacks.host_current;
    callbacks.host_current = &waiter;
    defer callbacks.host_current = previous_task;
    try std.testing.expectError(error.WifiNotInitialized, wifi.begin_stop(.stop));
    try std.testing.expectEqual(0, wifi.calls.stops);
    try std.testing.expect(wifi.stop_lock.locked == null);
    try std.testing.expect(!try wifi.claim_init(.{}));
    wifi.finish_init(.release);
}

test "single-radio adapter runs before driver init and releases the radio on failure" {
    if (radio.coex_enabled) return error.SkipZigTest;

    const Probe = struct {
        var calls: usize = 0;
        var reject = true;
        var accounting: *std.testing.FailingAllocator = undefined;

        fn on_adapter() InitError!void {
            assert(!HostWifi.initialized);
            assert(accounting.allocations > accounting.deallocations);
            calls += 1;
            if (reject) return error.InvalidArg;
        }
    };

    var accounting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var wifi: Wifi = .{};
    errdefer EventLog.end_failed_session(&wifi);
    Probe.accounting = &accounting;
    HostWifi.on_adapter = Probe.on_adapter;
    defer HostWifi.on_adapter = null;

    try std.testing.expectError(error.InvalidArg, wifi.init(accounting.allocator(), .{}));
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expectEqual(null, owner);
    try std.testing.expect(!HostWifi.initialized);
    try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);

    Probe.reject = false;
    try wifi.init(accounting.allocator(), .{});
    try std.testing.expectEqual(@as(usize, 2), Probe.calls);
    try std.testing.expect(HostWifi.initialized);
    try wifi.deinit();
    try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
}

test "public Wi-Fi operations cannot enter the driver during init or rollback" {
    const Probe = struct {
        var handle: *Wifi = undefined;

        fn reject_country() InitError!void {
            // The blob is initialized at this step, so a premature start
            // could succeed and make the driver reject rollback.
            assert(HostWifi.initialized and !HostWifi.started);
            var other: Wifi = .{};
            expect_error(error.WouldBlock, handle.start());
            assert(!HostWifi.started);

            // A connect that gets past admission here could reach the blob
            // after another handle has taken over. Verify that it never
            // registers an in-flight call or enters the blob.
            const connects = HostWifi.connect_calls;
            const disconnects = HostWifi.disconnect_calls;
            expect_error(error.WouldBlock, handle.connect());
            expect_error(error.WouldBlock, handle.disconnect());
            assert(handle.calls.connects == 0 and HostWifi.connect_calls == connects);
            assert(HostWifi.disconnect_calls == disconnects);
            expect_error(error.WouldBlock, handle.get_mode());
            expect_error(error.WouldBlock, handle.stop());
            expect_error(error.WouldBlock, handle.deinit());
            expect_error(error.WifiNotInitialized, other.stop());
            expect_error(error.WifiNotInitialized, other.deinit());
            assert(handle.calls.stops == 0);
            return error.InvalidArg;
        }

        fn expect_error(expected: InternalError, result: anytype) void {
            if (result) |_| unreachable else |err| assert(err == expected);
        }
    };

    var wifi: Wifi = .{};
    var other: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);

    Probe.handle = &wifi;
    HostWifi.on_country = Probe.reject_country;
    defer HostWifi.on_country = null;

    try std.testing.expectError(error.InvalidArg, wifi.init(host_session_allocator, .{}));
    try std.testing.expectEqual(null, owner);
    try std.testing.expect(!HostWifi.initialized and !wifi.ready);

    HostWifi.on_country = null;
    try other.init(host_session_allocator, .{});
    {
        errdefer EventLog.end_failed_session(&other);
        try other.set_mode(.sta);
        try other.start();
        const connects = HostWifi.connect_calls;
        try std.testing.expectError(error.WifiNotInitialized, wifi.connect());
        try std.testing.expectEqual(connects, HostWifi.connect_calls);
        try other.connect();
        try std.testing.expectEqual(connects + 1, HostWifi.connect_calls);
        try other.deinit();
    }

    // Force one rollback failure. Only deinit can reach the driver while
    // the failed init retains the owner.
    HostWifi.on_country = Probe.reject_country;
    HostWifi.reject_deinit_driver = true;
    defer HostWifi.reject_deinit_driver = false;
    try std.testing.expectError(error.WifiRollbackPending, wifi.init(host_session_allocator, .{}));
    try std.testing.expect(owner == &wifi and HostWifi.initialized and !wifi.ready);
    try std.testing.expectError(error.AlreadyInitialized, other.init(host_session_allocator, .{}));
    try std.testing.expectError(error.WouldBlock, wifi.start());
    try std.testing.expectError(error.WouldBlock, wifi.get_mode());
    try std.testing.expectError(error.WouldBlock, wifi.connect());
    try std.testing.expectError(error.WouldBlock, wifi.disconnect());
    try std.testing.expectError(error.WouldBlock, wifi.stop());
    try std.testing.expectError(if (radio.coex_enabled) error.WouldBlock else error.WifiPost, wifi.deinit());
    try std.testing.expect(owner == &wifi and HostWifi.initialized);

    HostWifi.reject_deinit_driver = false;
    HostWifi.on_country = null;
    try wifi.deinit();
    try std.testing.expectEqual(null, owner);
    try std.testing.expect(!HostWifi.initialized);
    try wifi.init(host_session_allocator, .{});
    try std.testing.expect(wifi.ready);
    try wifi.deinit();
}

test "single-radio init failure releases the driver and radio or leaves teardown retryable" {
    const Backend = struct {
        shutdown: osi.WifiShutdown = .{},
        fail_step: InitStep = .country,
        depth: u32 = 0,
        entry_depth: u32 = 0,
        adapter_installed: bool = false,
        wpa_unregistered: bool = false,

        var driver_error: ?InternalError = null;
        var supplicant_released = false;
        var radio_released = false;

        fn run(self: *@This(), comptime step: InitStep) InitError!void {
            if (step == .adapter) self.adapter_installed = true;
            if (step == .driver) assert(self.adapter_installed);
            if (step != self.fail_step) return;
            if (step == .supplicant) {
                self.wpa_unregistered = true;
                return error.OutOfMemory;
            }
            if (step == .driver) {
                self.depth += 1;
                return error.OutOfMemory;
            }
            return error.InvalidArg;
        }

        fn api_depth(self: *@This()) u32 {
            return self.depth;
        }

        fn unlock_api(self: *@This()) void {
            self.depth -= 1;
        }

        fn discard_unregistered(self: *@This()) void {
            assert(self.wpa_unregistered);
            self.wpa_unregistered = false;
        }

        fn rollback(self: *@This()) InternalError!void {
            assert(!self.wpa_unregistered);
            assert(self.entry_depth == self.depth);
            try release_single(&self.shutdown, @This());
        }

        fn deinit_driver() InternalError!void {
            if (driver_error) |err| return err;
        }

        fn deinit_supplicant() InternalError!void {
            supplicant_released = true;
        }

        pub fn join(_: *rtos.Task) void {
            unreachable; // These failures model no PP worker.
        }

        fn release() void {
            assert(supplicant_released);
            radio_released = true;
        }
    };

    var backend: Backend = .{};
    for ([_]?InternalError{ null, error.WifiNotInitialized, error.WouldBlock }) |status| {
        Backend.driver_error = status;
        Backend.supplicant_released = false;
        Backend.radio_released = false;
        if ((status orelse error.WifiOther) == error.WouldBlock) {
            try std.testing.expectError(error.WifiRollbackPending, configure_single(&backend));
            try std.testing.expect(!Backend.supplicant_released and !Backend.radio_released);
            Backend.driver_error = null;
            try release_single(&backend.shutdown, Backend);
        } else {
            try std.testing.expectError(error.InvalidArg, configure_single(&backend));
        }
        try std.testing.expect(Backend.supplicant_released and Backend.radio_released);
    }

    // An early driver-init failure leaves a recursive level held even when
    // its deinit reports that the driver never initialized.
    for ([_]u32{ 0, 1 }) |entry_depth| {
        backend = .{ .fail_step = .driver, .depth = entry_depth, .entry_depth = entry_depth };
        Backend.driver_error = error.WifiNotInitialized;
        Backend.supplicant_released = false;
        Backend.radio_released = false;
        try std.testing.expectError(error.OutOfMemory, configure_single(&backend));
        try std.testing.expectEqual(entry_depth, backend.depth);
        try std.testing.expect(Backend.supplicant_released and Backend.radio_released);
    }

    // A supplicant failure must discard the partial registration before teardown.
    backend = .{ .fail_step = .supplicant };
    Backend.driver_error = null;
    Backend.supplicant_released = false;
    Backend.radio_released = false;
    try std.testing.expectError(error.OutOfMemory, configure_single(&backend));
    try std.testing.expect(!backend.wpa_unregistered);
    try std.testing.expect(Backend.supplicant_released and Backend.radio_released);
}

test "single-radio cleanup joins and reclaims both packet-worker deletion paths" {
    const Backend = struct {
        var active: *@This() = undefined;
        shutdown: osi.WifiShutdown = .{},
        accounting: *std.testing.FailingAllocator,
        scheduler: rtos.RTOS_State,
        worker_slot: ?*rtos.Task,
        manual: bool,
        deinit_result: ?InternalError,
        joined: bool = false,
        released: bool = false,

        fn detach(task: *rtos.Task) void {
            active.scheduler.detach_task(task);
        }

        fn exit(action: rtos.YieldAction) void {
            assert(action == .exit and active.worker_slot == null);
            active.shutdown.worker.?.state = .exited;
        }

        fn deinit_driver(self: *@This()) InternalError!void {
            if (self.manual) {
                // pp_delete_task_manually passes the task handle, then clears it.
                self.shutdown.delete_task(self.worker_slot.?, self.scheduler.current_task, detach, exit);
                self.worker_slot = null;
            }
            if (self.deinit_result) |err| return err;
        }

        fn deinit_supplicant(_: *@This()) InternalError!void {}

        pub fn join(self: *@This(), task: *rtos.Task) void {
            assert(self.accounting.deallocations == 0);
            if (!self.manual) {
                // After acknowledging deletion, ppTask clears the blob slot
                // and exits through task_delete(null).
                self.worker_slot = null;
                self.shutdown.delete_task(null, task, detach, exit);
            }
            assert(task.state == .exited and self.worker_slot == null);
            self.joined = true;
        }

        fn release(self: *@This()) void {
            assert(self.joined and self.shutdown.worker == null and self.accounting.deallocations == 1);
            self.released = true;
        }
    };

    for ([_]bool{ false, true }) |manual| {
        var accounting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var route: @import("shared_heap.zig").TestRoute = .{};
        const previous_gpa = osi.gpa;
        if (radio.coex_enabled) route.install(accounting.allocator()) else osi.gpa = accounting.allocator();
        defer if (radio.coex_enabled) route.restore() else {
            osi.gpa = previous_gpa;
        };
        const mem = try osi.callback_allocator().alignedAlloc(u8, .@"16", @sizeOf(rtos.Task) + 64);
        const worker: *rtos.Task = @ptrCast(mem.ptr);
        worker.* = .{ .context = undefined, .stack = mem[@sizeOf(rtos.Task)..], .priority = .lowest, .state = .suspended };
        var queue: rtos.PriorityWaitQueue = .{};
        var waiter: rtos.PriorityWaitQueue.Waiter = .{ .task = worker, .priority = .lowest };
        if (manual) {
            queue.list.append(&waiter.node);
            worker.active_wait = .{ .queue = &queue, .node = &waiter.node };
        }

        var caller: rtos.Task = undefined;
        var backend: Backend = .{
            .accounting = &accounting,
            .scheduler = .{ .current_task = &caller, .current_sleep_queue = undefined, .overflow_sleep_queue = undefined },
            .worker_slot = worker,
            .manual = manual,
            .deinit_result = if (manual) error.WifiNotInitialized else null,
        };
        Backend.active = &backend;
        backend.shutdown.record_worker(worker);
        try release_single(&backend.shutdown, &backend);
        try std.testing.expect(backend.released and queue.list.first == null);
        try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
    }
}

test "deinit times out with a counted connect and ordinary stop still gives up" {
    var wifi: Wifi = .{};
    var second: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);
    const allocator = host_session_allocator;
    try wifi.init(allocator, .{});
    try wifi.set_mode(.sta);
    try wifi.start();
    try std.testing.expectEqualSlices(EventType, &.{.StaStart}, EventLog.take());

    // Suspend a caller between admission and entering the blob. The host wait
    // models expiration immediately because it does not run the scheduler.
    wifi.calls.connects = 1;
    try std.testing.expectError(error.Timeout, wifi.deinit());
    try std.testing.expectEqual(0, wifi.calls.give_ups);
    try std.testing.expect(HostWifi.initialized and HostWifi.started);
    try std.testing.expectError(error.AlreadyInitialized, second.init(allocator, .{}));
    try std.testing.expectEqual(0, EventLog.take().len);

    // The failed deinit reopens admission. Ordinary stop can continue even
    // while the first caller is still counted.
    try wifi.connect();
    try std.testing.expectEqual(1, wifi.calls.connects);
    try wifi.stop();
    try std.testing.expectEqual(1, wifi.calls.give_ups);
    try std.testing.expectEqualSlices(EventType, &.{.StaStop}, EventLog.take());

    wifi.calls.connects = 0;
    try wifi.deinit();
    try std.testing.expectError(error.WifiNotInitialized, wifi.connect());
}

test "public Wi-Fi deinit releases the radio when the driver is already deinitialised" {
    var wifi: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);
    try wifi.init(host_session_allocator, .{});
    HostWifi.deinit_driver_gone = true;
    defer HostWifi.deinit_driver_gone = false;
    try wifi.deinit();
    try std.testing.expect(osi.wifi_shutdown.stage == .off);
    HostWifi.deinit_driver_gone = false;
    // The radio was released, so a new session starts and ends.
    try wifi.init(host_session_allocator, .{});
    try wifi.deinit();
    try std.testing.expect(osi.wifi_shutdown.stage == .off);
}

test "public Wi-Fi null mode starts and stops no interface" {
    var wifi: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);
    try wifi.init(host_session_allocator, .{});
    try std.testing.expectEqual(WifiMode.none, try wifi.get_mode());
    try wifi.start();
    try wifi.start();
    // 0x3005 from wifi_connect_process and ESP_FAIL from wifi_disconnect_process.
    try std.testing.expectError(error.WifiMode, wifi.connect());
    try std.testing.expectError(error.WifiMode, wifi.disconnect());
    // A second coex init keeps the started session (IDF wifi_init.c:343-345).
    const invalid: InitConfig = .{ .power_save_mode = .min };
    if (radio.coex_enabled) {
        try wifi.init(host_session_allocator, invalid);
        try std.testing.expect(osi.wifi_shutdown.stage == .running);
    } else {
        try std.testing.expectError(error.AlreadyInitialized, wifi.init(host_session_allocator, invalid));
    }
    try wifi.stop();
    try wifi.start();
    try wifi.deinit();
    try std.testing.expectEqual(0, EventLog.take().len);
    try std.testing.expect(osi.wifi_shutdown.stage == .off);
}

test "public Wi-Fi station start and stop post one event per transition" {
    var wifi: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);
    try wifi.init(host_session_allocator, .{});
    try wifi.set_mode(.sta);
    try wifi.stop();
    try std.testing.expectError(error.WifiNotStarted, wifi.connect());
    try std.testing.expectError(error.WifiNotStarted, wifi.disconnect());
    try std.testing.expectEqual(0, EventLog.take().len);
    try wifi.start();
    try wifi.start();
    try wifi.connect();
    try wifi.disconnect();
    try wifi.stop();
    try wifi.stop();
    try std.testing.expectEqualSlices(EventType, &.{ .StaStart, .StaStop }, EventLog.take());
    try wifi.start();
    try wifi.deinit();
    try std.testing.expectEqualSlices(EventType, &.{ .StaStart, .StaStop }, EventLog.take());
    try std.testing.expectEqual(StaState.stopped, wifi.get_sta_state());
    try std.testing.expect(osi.wifi_shutdown.stage == .off);
}

test "public Wi-Fi stop hands every stop step the reserved ioctl" {
    if (!radio.coex_enabled) return error.SkipZigTest;
    var wifi: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);
    try wifi.init(host_session_allocator, .{});
    try wifi.set_mode(.sta);
    try wifi.start();
    _ = EventLog.take();
    // With no heap left, steps 1 and 2 would fail with ESP_ERR_NO_MEM after
    // the interfaces stopped.
    HostWifi.ioctl_heap_budget = 0;
    defer HostWifi.ioctl_heap_budget = null;
    HostWifi.reserved_ioctls = 0;
    try wifi.stop();
    try std.testing.expectEqual(3, HostWifi.reserved_ioctls);
    try std.testing.expectEqualSlices(EventType, &.{.StaStop}, EventLog.take());
    try std.testing.expect(osi.wifi_shutdown.owner == null and !HostWifi.started);

    // A failed allocation before step 0 stops nothing and is returned.
    try wifi.start();
    _ = EventLog.take();
    osi.wifi_shutdown.ioctl_in_use = true;
    try std.testing.expectError(error.OutOfMemory, wifi.stop());
    osi.wifi_shutdown.ioctl_in_use = false;
    try std.testing.expect(HostWifi.started and EventLog.take().len == 0);
    try wifi.deinit();
    try std.testing.expectEqualSlices(EventType, &.{.StaStop}, EventLog.take());
    try std.testing.expect(osi.wifi_shutdown.stage == .off);
}

test "public Wi-Fi disconnect returns WouldBlock while the driver is stopping" {
    if (!radio.coex_enabled) return error.SkipZigTest;
    var wifi: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);
    try wifi.init(host_session_allocator, .{});
    try wifi.set_mode(.sta);
    try wifi.start();
    osi.disconnect_gate.close(struct {
        fn wait() void {
            unreachable; // no disconnect is inside
        }
    }.wait);
    try std.testing.expectError(error.WouldBlock, wifi.disconnect());
    try wifi.connect();
    osi.disconnect_gate.open();
    try wifi.disconnect();
    try wifi.deinit();
    try std.testing.expect(osi.wifi_shutdown.stage == .off);
}

// A stop that fails part-way panics, so these run one per process under
// stop_panic_runner.zig, which passes only on the expected panic message.
// The default test runner skips them.
fn start_for_stop_panic(wifi: *Wifi) !void {
    if (!@hasDecl(@import("root"), "stop_panic_runner")) return error.SkipZigTest;
    if (radio.coex_enabled) @import("host_test_heap.zig").attach();
    try wifi.init(host_session_allocator, .{});
    try wifi.set_mode(.sta);
    try wifi.start();
}

test "Wi-Fi stop panics when the PP queue rejects the interface stop" {
    if (!radio.coex_enabled) return error.SkipZigTest;
    var wifi: Wifi = .{};
    try start_for_stop_panic(&wifi);
    HostWifi.reject_stop = .{ .interfaces = true };
    try wifi.stop();
}

test "Wi-Fi stop panics when the PP queue rejects the hardware stop" {
    if (!radio.coex_enabled) return error.SkipZigTest;
    var wifi: Wifi = .{};
    try start_for_stop_panic(&wifi);
    HostWifi.reject_stop = .{ .hardware = true };
    try wifi.stop();
}

test "Wi-Fi stop panics when the PP queue rejects both stops" {
    if (!radio.coex_enabled) return error.SkipZigTest;
    var wifi: Wifi = .{};
    try start_for_stop_panic(&wifi);
    HostWifi.reject_stop = .{ .interfaces = true, .hardware = true };
    try wifi.stop();
}

test "Wi-Fi stop panics when an allocation fails after the interfaces stopped" {
    if (!radio.coex_enabled) return error.SkipZigTest;
    var wifi: Wifi = .{};
    try start_for_stop_panic(&wifi);
    // Without the reserved ioctl, the heap grants only step 0's.
    osi.wifi_shutdown.ioctl_in_use = true;
    HostWifi.ioctl_heap_budget = 1;
    try wifi.stop();
}

test "public Wi-Fi mode changes on a started session switch only the affected interfaces" {
    var wifi: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);
    try wifi.init(host_session_allocator, .{});
    try wifi.start();
    const steps = [_]struct { WifiMode, []const EventType }{
        .{ .sta, &.{.StaStart} },
        .{ .ap_sta, &.{.ApStart} },
        .{ .ap, &.{.StaStop} },
        .{ .sta, &.{ .ApStop, .StaStart } },
        .{ .sta, &.{} },
        .{ .none, &.{.StaStop} },
        .{ .ap_sta, &.{ .StaStart, .ApStart } },
    };
    for (steps) |step| {
        try wifi.set_mode(step[0]);
        try std.testing.expectEqual(step[0], try wifi.get_mode());
        try std.testing.expectEqualSlices(EventType, step[1], EventLog.take());
    }
    try wifi.deinit();
    try std.testing.expectEqualSlices(EventType, &.{ .StaStop, .ApStop }, EventLog.take());
    try std.testing.expectEqual(ApState.stopped, wifi.get_ap_state());
    try std.testing.expect(osi.wifi_shutdown.stage == .off);
}

test "apply holds the lifecycle claim from the mode change through every interface configuration" {
    if (!radio.coex_enabled) return error.SkipZigTest;
    var wifi: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);
    HostWifi.configured_len = 0;
    try std.testing.expectError(error.WifiNotInitialized, wifi.apply(.{ .sta = .{ .ssid = "net" } }));
    try wifi.init(host_session_allocator, .{});
    try wifi.apply(.{ .ap_sta = .{ .ap = .{ .ssid = "ap", .channel = 1, .max_connections = 1 }, .sta = .{ .ssid = "net" } } });
    try std.testing.expectEqual(WifiMode.ap_sta, try wifi.get_mode());
    try std.testing.expectEqual(@as(usize, 2), HostWifi.configured_len);
    for (HostWifi.configured[0..2], [_]c.wifi_interface_t{ c.WIFI_IF_AP, c.WIFI_IF_STA }) |entry, interface| {
        try std.testing.expectEqual(interface, entry.interface);
        try std.testing.expect(entry.claimed);
    }
    try std.testing.expect(!wifi.lifecycle_active.load(.acquire));

    // Another owner: neither the mode nor a configuration changes.
    wifi.lifecycle_active.store(true, .release);
    try std.testing.expectError(error.WouldBlock, wifi.apply(.{ .ap = .{ .ssid = "ap", .channel = 1, .max_connections = 1 } }));
    wifi.lifecycle_active.store(false, .release);
    try std.testing.expectEqual(WifiMode.ap_sta, try wifi.get_mode());
    try std.testing.expectEqual(@as(usize, 2), HostWifi.configured_len);

    // A rejected configuration still releases the claim.
    try std.testing.expectError(error.InvalidConfig, wifi.apply(.{ .sta = .{ .ssid = &@as([33]u8, @splat('x')) } }));
    try std.testing.expect(!wifi.lifecycle_active.load(.acquire));
    try wifi.deinit();
    _ = EventLog.take();
}

test "apply rejects every configuration that needs SAE before the mode changes" {
    var wifi: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);
    HostWifi.configured_len = 0;
    try wifi.init(host_session_allocator, .{});
    try wifi.apply(.{ .sta = .{ .ssid = "net", .password = "passphrase", .auth_method = .wpa2_personal } });
    try std.testing.expectEqual(@as(usize, 1), HostWifi.configured_len);

    const ap: Config.AccessPoint = .{ .ssid = "ap", .password = "passphrase", .channel = 6, .max_connections = 1 };
    for ([_]AuthMethod{ .wpa3_personal, .wpa2_wpa3_personal }) |auth_method| {
        var sae_ap = ap;
        sae_ap.auth_method = auth_method;
        try std.testing.expectError(error.InvalidConfig, wifi.apply(.{ .ap = sae_ap }));
        try std.testing.expectError(error.InvalidConfig, wifi.apply(.{ .ap_sta = .{ .ap = sae_ap, .sta = .{ .ssid = "net" } } }));
    }
    const wpa3_sta: Config.Station = .{ .ssid = "net", .password = "passphrase", .auth_method = .wpa3_personal };
    try std.testing.expectError(error.InvalidConfig, wifi.apply(.{ .sta = wpa3_sta }));
    try std.testing.expectError(error.InvalidConfig, wifi.apply(.{ .ap_sta = .{ .ap = ap, .sta = wpa3_sta } }));
    try std.testing.expectError(error.InvalidConfig, wifi.apply_station_config(wpa3_sta));
    // Neither the mode nor an interface configuration changed.
    try std.testing.expectEqual(WifiMode.sta, try wifi.get_mode());
    try std.testing.expectEqual(@as(usize, 1), HostWifi.configured_len);

    // From AP mode, a rejected station configuration leaves the mode at AP.
    try wifi.apply(.{ .ap = ap });
    try std.testing.expectEqual(@as(usize, 2), HostWifi.configured_len);
    try std.testing.expectError(error.InvalidConfig, wifi.apply(.{ .sta = wpa3_sta }));
    try std.testing.expectEqual(WifiMode.ap, try wifi.get_mode());
    try std.testing.expectEqual(@as(usize, 2), HostWifi.configured_len);

    // A WPA2/WPA3 access point also offers WPA2, so it stays a valid station threshold.
    try wifi.apply(.{ .sta = .{ .ssid = "net", .password = "passphrase", .auth_method = .wpa2_wpa3_personal } });
    try std.testing.expectEqual(@as(usize, 3), HostWifi.configured_len);
    try wifi.deinit();
    try std.testing.expectEqual(0, EventLog.take().len);
}

test "the driver init configuration does not advertise WPA3 SAE" {
    var osi_funcs: c.wifi_osi_funcs_t = undefined;
    const init_config = make_init_config(.{}, &osi_funcs, undefined);
    try std.testing.expectEqual(@as(u64, 0), init_config.feature_caps & wifi_enable_wpa3_sae);
}

test "public Wi-Fi calls wait for a pending teardown or another lifecycle owner" {
    if (!radio.coex_enabled) return error.SkipZigTest;
    var wifi: Wifi = .{};
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);
    try wifi.init(host_session_allocator, .{});
    try wifi.set_mode(.sta);
    try wifi.start();
    _ = EventLog.take();

    // Another task owns the lifecycle. Blob calls outside it are not gated.
    wifi.lifecycle_active.store(true, .release);
    try std.testing.expectError(error.WifiSessionBusy, wifi.init(host_session_allocator, .{}));
    try std.testing.expectError(error.WouldBlock, wifi.deinit());
    try std.testing.expectError(error.WouldBlock, wifi.start());
    try std.testing.expectError(error.WouldBlock, wifi.stop());
    try std.testing.expectError(error.WouldBlock, wifi.set_mode(.ap));
    try std.testing.expectEqual(WifiMode.sta, try wifi.get_mode());
    try wifi.connect();
    try wifi.disconnect();
    wifi.lifecycle_active.store(false, .release);

    // The deinit ioctl is rejected after the stop and supplicant stages.
    HostWifi.reject_deinit_driver = true;
    defer HostWifi.reject_deinit_driver = false;
    try std.testing.expectError(error.WouldBlock, wifi.deinit());
    var second: Wifi = .{};
    try std.testing.expectError(error.AlreadyInitialized, second.init(host_session_allocator, .{}));
    try std.testing.expectError(error.WifiNotInitialized, second.deinit());
    try std.testing.expect(osi.wifi_shutdown.stage == .driver and !wifi.lifecycle_active.load(.acquire));
    try std.testing.expectEqualSlices(EventType, &.{.StaStop}, EventLog.take());
    try std.testing.expectError(error.WifiSessionBusy, wifi.init(host_session_allocator, .{ .power_save_mode = .min }));
    try std.testing.expectError(error.WouldBlock, wifi.start());
    try std.testing.expectError(error.WouldBlock, wifi.stop());
    try std.testing.expectError(error.WouldBlock, wifi.set_mode(.ap));
    try std.testing.expectEqual(WifiMode.sta, try wifi.get_mode());
    try std.testing.expectError(error.WifiNotStarted, wifi.connect());
    try std.testing.expectError(error.WifiNotStarted, wifi.disconnect());
    HostWifi.reject_deinit_driver = false;
    wifi.calls.connects = 1;
    try std.testing.expectError(error.Timeout, wifi.deinit());
    try std.testing.expect(osi.wifi_shutdown.stage == .driver);
    wifi.calls.connects = 0;
    try wifi.deinit();
    try std.testing.expect(osi.wifi_shutdown.stage == .off);
    try std.testing.expectEqual(0, EventLog.take().len);
}

test "public Wi-Fi deinit completes when StaStop calls public init" {
    if (!radio.coex_enabled) return error.SkipZigTest;
    var wifi: Wifi = .{};
    const Probe = struct {
        var observed = false;
        var handle: *Wifi = undefined;
        fn on_event(event: Event) void {
            assert(event == .StaStop);
            var other: Wifi = .{};
            try_non_owner(other.stop());
            try_non_owner(other.deinit());
            if (handle.init(host_session_allocator, .{})) |_| unreachable else |err| assert(err == error.WifiSessionBusy);
            if (handle.deinit()) |_| unreachable else |err| assert(err == error.WouldBlock);
            if (handle.start()) |_| unreachable else |err| assert(err == error.WouldBlock);
            if (handle.stop()) |_| unreachable else |err| assert(err == error.WouldBlock);
            if (handle.connect()) |_| unreachable else |err| assert(err == error.WifiStopping);
            if (handle.set_mode(.none)) |_| unreachable else |err| assert(err == error.WouldBlock);
            if (handle.disconnect()) |_| unreachable else |err| assert(err == error.WouldBlock);
            assert((handle.get_mode() catch unreachable) == .sta);
            if (radio.init(host_session_allocator)) |_| unreachable else |err| assert(err == error.WouldBlock);
            if (radio.deinit()) |_| unreachable else |err| assert(err == error.WouldBlock);
            observed = true;
        }

        fn try_non_owner(result: InternalError!void) void {
            if (result) |_| unreachable else |err| assert(err == error.WifiNotInitialized);
        }
    };
    const saved = EventLog.install();
    defer saved.restore();
    errdefer EventLog.end_failed_session(&wifi);
    try wifi.init(host_session_allocator, .{});
    try wifi.set_mode(.sta);
    try wifi.start();
    Probe.handle = &wifi;
    microzig.wifi_listener = Probe.on_event;
    defer Probe.observed = false;
    try wifi.deinit();
    try std.testing.expect(Probe.observed);
    try std.testing.expect(!wifi.lifecycle_active.load(.acquire) and osi.wifi_shutdown.stage == .off);
}
