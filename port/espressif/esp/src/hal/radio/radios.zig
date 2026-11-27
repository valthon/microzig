// Keep the selection type anonymous like the original protocol field. Naming it
// changes Zig 0.17.1 function ordering even in C6 images that only configure clocks.
pub const Radios = @TypeOf(default);

// Add a combination here only after its radio lifecycle is supported. IDF v5.5.1
// supports Wi-Fi + BLE coexistence on the C6 (components/esp_coex/src/coexist.c);
// 802.15.4 pairs are later phases of the coexistence work.
pub const supported_coex_sets: []const Radios = &.{.{ .wifi = true, .ble = true }};

pub const default: packed struct(u3) {
    wifi: bool = true,
    ble: bool = false,
    ieee802154: bool = false,

    fn count(self: @This()) u2 {
        return @popCount(@as(u3, @bitCast(self)));
    }

    pub fn coexistence(self: @This()) bool {
        return self.count() > 1;
    }

    pub fn validate(comptime self: @This()) void {
        if (comptime self.count() == 0) @compileError("hal.radio.radios requires one selected radio");
        if (comptime !self.coexistence()) return;
        inline for (supported_coex_sets) |supported| {
            if (@as(u3, @bitCast(self)) == @as(u3, @bitCast(supported))) return;
        }
        @compileError("hal.radio.radios: " ++ self.names() ++ " together is not supported; " ++
            "the only supported multi-radio selection is wifi + ble");
    }

    fn names(comptime self: @This()) []const u8 {
        var out: []const u8 = "";
        for (.{ "wifi", "ble", "ieee802154" }) |name| {
            if (!@field(self, name)) continue;
            out = if (out.len == 0) name else out ++ " + " ++ name;
        }
        return out;
    }
} = .{};

test "each single radio is accepted and Wi-Fi is the default" {
    const expect = @import("std").testing.expect;
    try expect((Radios{}).wifi);
    inline for (.{ Radios{}, Radios{ .wifi = false, .ble = true }, Radios{ .wifi = false, .ieee802154 = true } }) |selection| {
        selection.validate();
        try expect(!selection.coexistence());
    }
}

test "Wi-Fi + BLE is the supported coexistence set" {
    const selection = Radios{ .ble = true };
    comptime selection.validate();
    try @import("std").testing.expect(selection.coexistence());
    try @import("std").testing.expectEqualStrings("wifi + ble + ieee802154", comptime (Radios{ .ble = true, .ieee802154 = true }).names());
}
