//! C6 clock users from IDF v5.5.1 esp_hw_support/modem_clock.c:303-315.
//! The caller holds the critical section across updating users and applying gates.
pub const Users = struct {
    wifi: u32 = 0,
    ble: u32 = 0,
    ieee802154: u32 = 0,
    calibration: u32 = 0,

    pub const Owner = enum { wifi, ble, ieee802154, calibration };

    pub fn update(self: *Users, comptime owner: Owner, enable: bool) void {
        const refs = &@field(self, @tagName(owner));
        if (enable) refs.* += 1 else refs.* -|= 1;
    }

    pub fn bt(self: Users) u1 {
        return @intFromBool(self.ble != 0 or self.ieee802154 != 0 or self.calibration != 0);
    }

    pub fn coex(self: Users) u1 {
        return @intFromBool(self.wifi != 0 or self.ble != 0 or self.ieee802154 != 0);
    }

    pub fn etm(self: Users) u1 {
        return @intFromBool(self.ble != 0 or self.ieee802154 != 0);
    }
};

test "calibration and 802.15.4 release only their own references" {
    const expect = @import("std").testing.expect;
    var users: Users = .{};
    users.update(.wifi, true);
    users.update(.ble, true);
    users.update(.calibration, true);
    users.update(.calibration, true);
    users.update(.ieee802154, true);
    users.update(.calibration, false);
    users.update(.ieee802154, false);
    try expect(users.bt() == 1 and users.etm() == 1);
    users.update(.calibration, false);
    try expect(users.bt() == 1);
    users.update(.ble, false);
    try expect(users.bt() == 0 and users.coex() == 1);
    users.update(.wifi, false);
    try expect(users.coex() == 0);
}

/// IDF v5.5.1 esp_phy/src/btbb_init.c:61-84 initializes on the first acquire;
/// btbb_init.c:86-95 ignores a release with no users. The caller serializes
/// the blob call with updates to the reference count.
pub const Btbb = struct {
    refs: u32 = 0,

    pub fn enable(self: *Btbb, print_version: u32, comptime init: anytype) void {
        if (self.refs == 0) init(print_version);
        self.refs += 1;
    }

    pub fn disable(self: *Btbb) void {
        if (self.refs != 0) self.refs -= 1;
    }
};

test "baseband init runs only on transition from zero users" {
    const Blob = struct {
        var calls: usize = 0;
        var last_arg: u32 = undefined;
        fn init(arg: u32) void {
            calls += 1;
            last_arg = arg;
        }
    };
    const expect = @import("std").testing.expect;
    var bb: Btbb = .{};
    bb.enable(1, Blob.init);
    bb.enable(0, Blob.init);
    bb.disable();
    bb.enable(0, Blob.init);
    try expect(Blob.calls == 1 and Blob.last_arg == 1);
    bb.disable();
    bb.disable();
    bb.disable();
    bb.enable(0, Blob.init);
    try expect(Blob.calls == 2 and Blob.last_arg == 0 and bb.refs == 1);
}
