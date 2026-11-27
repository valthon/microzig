//! The errors for the status codes the Wi-Fi blobs return. This file imports
//! nothing but std, so the port's host unit tests cover the mapping; wifi.zig
//! checks every value of `Code` against the IDF headers at compile time.
const std = @import("std");

const log = std.log.scoped(.esp_radio_wifi);

pub const Error = error{
    OutOfMemory,
    InvalidArg,
    /// ESP_ERR_WIFI_TIMEOUT (0x300C) from the blob, or `Wifi.stop` or `Wifi.deinit` giving up
    /// after waiting 5 s for another stop or deinit to return. `Wifi.deinit`
    /// also returns it if a connect is still in flight after waiting 1 s.
    Timeout,
    WouldBlock,
    WifiNotInitialized,
    WifiNotStarted,
    WifiNotStopped,
    WifiNotConnected,
    WifiInvalid_MAC,
    WifiInvalid_SSID,
    WifiInvalidPassword,
    /// ESP_ERR_WIFI_IF: Wi-Fi interface error.
    WifiInterface,
    /// ESP_ERR_WIFI_MODE: the call needs an interface the current mode lacks.
    /// Raw WPS calls also return it when the WPS registrar is already enabled
    /// (IDF v5.5.1 esp_wps.c:1904-1907).
    WifiMode,
    /// ESP_ERR_WIFI_STATE: Wi-Fi internal state error.
    WifiState,
    /// ESP_ERR_WIFI_CONN: error in the station or soft-AP internal control block.
    WifiControlBlock,
    /// ESP_ERR_WIFI_NVS: Wi-Fi internal NVS module error.
    WifiNvs,
    /// ESP_ERR_WIFI_POST: the request could not be posted to the Wi-Fi task.
    WifiPost,
    /// ESP_ERR_WIFI_INIT_STATE: init or deinit called in the wrong state.
    WifiInitState,
    /// ESP_ERR_WIFI_STOP_STATE: Wi-Fi is stopping. The blob returns it (0x3014) to a request
    /// made from another task while a stop is in progress (`ieee80211_ioctl+0x116..0x148`).
    /// `Wifi.connect` returns it while `Wifi.stop` or `Wifi.deinit` runs, and `Wifi.stop` and
    /// `Wifi.deinit` return it when called in a task whose own `Wifi.stop` or `Wifi.deinit` is
    /// running.
    WifiStopping,
    /// ESP_ERR_WIFI_NOT_ASSOC: the connection is not associated.
    WifiNotAssociated,
    /// ESP_ERR_WIFI_TX_DISALLOW: transmission is not allowed.
    WifiTxDisallowed,
    /// ESP_FAIL, ESP_ERR_WIFI_WAKE_FAIL, or a code `Code` does not list.
    WifiOther,
};

/// The status codes `check` names. Each tag is its IDF macro in lower case
/// (esp_err.h, esp_wifi.h), which is what lets wifi.zig compare the values
/// with the headers.
pub const Code = enum(i32) {
    /// Generic failure, e.g. from scan start (C6 libnet80211.a
    /// esp_wifi_scan_start+0x15e) and from esp_supplicant_init when
    /// esp_supplicant_common_init fails (esp-wifi-sys libwpa_supplicant.a
    /// esp_supplicant_common_init+0x32). wifi.zig's `disconnect` maps the
    /// one from a mode without a station to `error.WifiMode`.
    esp_fail = -1,

    /// Out of memory
    esp_err_no_mem = 0x101,

    /// Invalid argument
    esp_err_invalid_arg = 0x102,

    /// Wi_fi driver was not installed by esp_wifi_init
    esp_err_wifi_not_init = 0x3001,

    /// Wi_fi driver was not started by esp_wifi_start
    esp_err_wifi_not_started = 0x3002,

    /// Wi_fi driver was not stopped by esp_wifi_stop
    esp_err_wifi_not_stopped = 0x3003,

    /// Wi_fi interface error
    esp_err_wifi_if = 0x3004,

    /// Wi_fi mode error
    esp_err_wifi_mode = 0x3005,

    /// Wi_fi internal state error
    esp_err_wifi_state = 0x3006,

    /// Wi_fi internal control block of station or soft-AP error
    esp_err_wifi_conn = 0x3007,

    /// Wi_fi internal NVS module error
    esp_err_wifi_nvs = 0x3008,

    /// MAC address is invalid
    esp_err_wifi_mac = 0x3009,

    /// SSID is invalid
    esp_err_wifi_ssid = 0x300A,

    /// Password is invalid
    esp_err_wifi_password = 0x300B,

    /// Timeout error
    esp_err_wifi_timeout = 0x300C,

    /// Wi_fi is in sleep state(RF closed) and wakeup fail. No linked C3 or
    /// C6 libnet80211/libpp/libwpa_supplicant site returns it.
    esp_err_wifi_wake_fail = 0x300D,

    /// The caller would block
    esp_err_wifi_would_block = 0x300E,

    /// Station still in disconnect status
    esp_err_wifi_not_connect = 0x300F,

    /// Failed to post the event to Wi_fi task
    esp_err_wifi_post = 0x3012,

    /// Invalid Wi_fi state when init/deinit is called
    esp_err_wifi_init_state = 0x3013,

    /// Returned when Wi_fi is stopping
    esp_err_wifi_stop_state = 0x3014,

    /// The Wi_fi connection is not associated
    esp_err_wifi_not_assoc = 0x3015,

    /// The Wi_fi TX is disallowed
    esp_err_wifi_tx_disallow = 0x3016,
};

/// Any code other than ESP_OK (0) is an error. ESP_FAIL, ESP_ERR_WIFI_WAKE_FAIL
/// and codes `Code` does not name are `error.WifiOther`; every other listed
/// code has its own error.
pub fn check(raw_err_code: i32) Error!void {
    if (raw_err_code == 0) return;
    const err_code = std.enums.fromInt(Code, raw_err_code) orelse {
        log.debug("internal wifi error occurred: code {d}", .{raw_err_code});
        return error.WifiOther;
    };
    log.debug("internal wifi error occurred: {t}", .{err_code});
    return switch (err_code) {
        .esp_err_no_mem => error.OutOfMemory,
        .esp_err_invalid_arg => error.InvalidArg,
        .esp_err_wifi_timeout => error.Timeout,
        .esp_err_wifi_would_block => error.WouldBlock,
        .esp_err_wifi_not_init => error.WifiNotInitialized,
        .esp_err_wifi_not_started => error.WifiNotStarted,
        .esp_err_wifi_not_connect => error.WifiNotConnected,
        .esp_err_wifi_not_stopped => error.WifiNotStopped,
        .esp_err_wifi_mac => error.WifiInvalid_MAC,
        .esp_err_wifi_ssid => error.WifiInvalid_SSID,
        .esp_err_wifi_password => error.WifiInvalidPassword,
        .esp_err_wifi_if => error.WifiInterface,
        .esp_err_wifi_mode => error.WifiMode,
        .esp_err_wifi_state => error.WifiState,
        .esp_err_wifi_conn => error.WifiControlBlock,
        .esp_err_wifi_nvs => error.WifiNvs,
        .esp_err_wifi_post => error.WifiPost,
        .esp_err_wifi_init_state => error.WifiInitState,
        .esp_err_wifi_stop_state => error.WifiStopping,
        .esp_err_wifi_not_assoc => error.WifiNotAssociated,
        .esp_err_wifi_tx_disallow => error.WifiTxDisallowed,
        .esp_fail, .esp_err_wifi_wake_fail => error.WifiOther,
    };
}

test "ESP_OK is the only success" {
    try check(0);
    try std.testing.expectError(error.WifiOther, check(-1));
}

test "every listed code has its error" {
    const cases = [_]struct { i32, Error }{
        .{ 0x101, error.OutOfMemory },
        .{ 0x102, error.InvalidArg },
        .{ 0x3001, error.WifiNotInitialized },
        .{ 0x3002, error.WifiNotStarted },
        .{ 0x3003, error.WifiNotStopped },
        .{ 0x3004, error.WifiInterface },
        .{ 0x3005, error.WifiMode },
        .{ 0x3006, error.WifiState },
        .{ 0x3007, error.WifiControlBlock },
        .{ 0x3008, error.WifiNvs },
        .{ 0x3009, error.WifiInvalid_MAC },
        .{ 0x300A, error.WifiInvalid_SSID },
        .{ 0x300B, error.WifiInvalidPassword },
        .{ 0x300C, error.Timeout },
        .{ 0x300D, error.WifiOther },
        .{ 0x300E, error.WouldBlock },
        .{ 0x300F, error.WifiNotConnected },
        .{ 0x3012, error.WifiPost },
        .{ 0x3013, error.WifiInitState },
        .{ 0x3014, error.WifiStopping },
        .{ 0x3015, error.WifiNotAssociated },
        .{ 0x3016, error.WifiTxDisallowed },
    };
    try std.testing.expectEqual(std.enums.values(Code).len - 1, cases.len);
    for (cases) |case| try std.testing.expectError(case[1], check(case[0]));
}

test "an unlisted code is WifiOther, not a panic" {
    // 0x3010 and 0x3011 are unassigned in esp_wifi.h; 0x3017 is
    // ESP_ERR_WIFI_TWT_FULL, which the table does not name.
    for ([_]i32{ 0x3010, 0x3011, 0x3017, 0x103, -2, std.math.maxInt(i32) }) |raw| {
        try std.testing.expectError(error.WifiOther, check(raw));
    }
}
