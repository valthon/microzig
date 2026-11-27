//! Shared PHY bookkeeping for coexistence images, after IDF v5.5.1
//! components/esp_phy/src/phy_init.c esp_phy_enable/esp_phy_disable (308-415)
//! and phy_common.c phy_track_pll/phy_track_pll_internal (53-101) and the
//! modem flag helpers (139-155). Pure state: osi.zig applies the hardware steps.

pub const Modem = enum(u3) {
    wifi = 1,
    bt = 2,
    ieee802154 = 4,

    fn mask(modem: Modem) u3 {
        return @backingInt(modem);
    }
};

/// Arguments for phy_param_track_tot(wifi, bt_154).
pub const Track = struct { wifi: bool, bt_154: bool };

/// phy_common.c PHY_TRACK_PLL_PERIOD_IN_US (ESP_PHY_PLL_TRACK_PERIOD_MS default 1000).
pub const track_period_us = 1_000_000;

pub const State = struct {
    flags: u3 = 0,
    wifi_tracked_us: u64 = 0,
    bt_154_tracked_us: u64 = 0,

    /// Set the modem's flag. True when no modem was enabled, so the caller
    /// powers on and calibrates (phy_init.c:311) and starts the track timer.
    pub fn enable(self: *State, modem: Modem) bool {
        const first = self.flags == 0;
        self.flags |= modem.mask();
        return first;
    }

    /// Clear the modem's flag. True only when it was the sole enabled modem,
    /// so the caller closes the PHY (phy_init.c:385-387 `saved_modem == modem`).
    pub fn disable(self: *State, modem: Modem) bool {
        const saved = self.flags;
        self.flags &= ~modem.mask();
        return saved == modem.mask();
    }

    pub fn contains(self: State, modem: Modem) bool {
        return self.flags & modem.mask() != 0;
    }

    fn bt_154(self: State) bool {
        return self.flags & (Modem.bt.mask() | Modem.ieee802154.mask()) != 0;
    }

    /// phy_track_pll: track when an enabled group last tracked over a period ago.
    pub fn track_if_due(self: *State, now_us: u64) ?Track {
        const wifi_due = self.contains(.wifi) and now_us -% self.wifi_tracked_us > track_period_us;
        const bt_154_due = self.bt_154() and now_us -% self.bt_154_tracked_us > track_period_us;
        return if (wifi_due or bt_154_due) self.track(now_us) else null;
    }

    /// phy_track_pll_internal: track every enabled group and stamp it.
    pub fn track(self: *State, now_us: u64) ?Track {
        const result: Track = .{ .wifi = self.contains(.wifi), .bt_154 = self.bt_154() };
        if (result.wifi) self.wifi_tracked_us = now_us;
        if (result.bt_154) self.bt_154_tracked_us = now_us;
        return if (result.wifi or result.bt_154) result else null;
    }
};

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "first enable powers on and only the last modem's disable powers off" {
    var state: State = .{};
    try expect(state.enable(.wifi));
    try expect(!state.enable(.bt));
    // A repeated enable is a flag, not a count (phy_set_modem_flag).
    try expect(!state.enable(.wifi));
    try expect(!state.disable(.wifi));
    try expect(state.contains(.bt) and !state.contains(.wifi));
    try expect(state.disable(.bt));
    try expectEqual(@as(u3, 0), state.flags);
}

test "disable of a modem that was never enabled does not close the others" {
    var state: State = .{};
    _ = state.enable(.bt);
    try expect(!state.disable(.wifi));
    try expect(state.contains(.bt));
    // Disabling with nothing enabled closes nothing either (saved 0 != modem).
    try expect(state.disable(.bt));
    try expect(!state.disable(.bt));
}

test "tracking groups Wi-Fi apart from BT and 802.15.4 with separate stamps" {
    var state: State = .{};
    _ = state.enable(.wifi);
    try expectEqual(Track{ .wifi = true, .bt_154 = false }, state.track_if_due(2_000_000).?);
    _ = state.enable(.bt);
    // The BT group has never tracked, so it is due; both groups track together.
    try expectEqual(Track{ .wifi = true, .bt_154 = true }, state.track_if_due(2_100_000).?);
    try expect(state.track_if_due(3_000_000) == null);
    try expectEqual(Track{ .wifi = true, .bt_154 = true }, state.track_if_due(3_100_001).?);
    _ = state.disable(.wifi);
    try expectEqual(Track{ .wifi = false, .bt_154 = true }, state.track(3_200_000).?);
    _ = state.disable(.bt);
    try expect(state.track(4_000_000) == null);
}

test "802.15.4 shares the BT tracking group" {
    var state: State = .{};
    _ = state.enable(.ieee802154);
    try expectEqual(Track{ .wifi = false, .bt_154 = true }, state.track(5).?);
    try expect(state.bt_154_tracked_us == 5 and state.wifi_tracked_us == 0);
}
