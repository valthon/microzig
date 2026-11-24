const std = @import("std");
const nvs = @import("nvs");
const bonds = @import("smp_bond.zig");
const Flash = struct {
    pub const Error = error{WriteFailed};
    bytes: [4 * nvs.page_size]u8 = @splat(0xff),
    fail: bool = false,
    pub fn read(self: *Flash, offset: u32, dest: []u8) Error!void {
        @memcpy(dest, self.bytes[offset..][0..dest.len]);
    }
    pub fn write(self: *Flash, offset: u32, data: []const u8) Error!void {
        if (self.fail) return error.WriteFailed;
        for (self.bytes[offset..][0..data.len], data) |*dst, src| dst.* &= src;
    }
    pub fn erase(self: *Flash, offset: u32) Error!void {
        if (self.fail) return error.WriteFailed;
        @memset(self.bytes[offset..][0..nvs.page_size], 0xff);
    }
};
test "bond load/store/remove survive flash reopen, purge secrets, and surface write errors" {
    var flash: Flash = .{};
    const Storage = nvs.Storage(*Flash);
    var storage: Storage = undefined;
    try storage.init(&flash, flash.bytes.len);
    var adapter: bonds.Nvs(Storage.Handle) = .{ .handle = try storage.open("ble_bonds", .read_write_purge) };
    const store = adapter.interface();
    const bond: bonds.Bond = .{ .peer = .{ 0, 1, 2, 3, 4, 5, 6 }, .identity = .{ 0, 1, 2, 3, 4, 5, 6 }, .ltk = @splat(0xa5), .irk = @splat(0x7b), .authenticated = true };
    try std.testing.expectEqual(@as(?bonds.Bond, null), try store.load(bond.peer));
    try store.save(bond);
    try storage.init(&flash, flash.bytes.len);
    try std.testing.expectEqualDeep(bond, (try store.load(bond.peer)).?);
    const c = @import("smp_crypto.zig");
    const prand = c.hex("708194");
    const rpa = [1]u8{1} ++ prand ++ c.ah(bond.irk, prand);
    try std.testing.expectEqualDeep(bond, (try store.load(rpa)).?);
    var replacement = bond;
    replacement.ltk = @splat(0xc3);
    try store.save(replacement);
    try std.testing.expect(std.mem.indexOf(u8, &flash.bytes, &bond.ltk) == null);
    try std.testing.expectEqualDeep(replacement, (try store.load(bond.peer)).?);
    var downgraded = replacement;
    downgraded.authenticated = false;
    try std.testing.expectError(error.StorageFailed, store.save(downgraded));
    flash.fail = true;
    try std.testing.expectError(error.StorageFailed, store.save(bond));
    flash.fail = false;
    try store.remove(rpa);
    try storage.init(&flash, flash.bytes.len);
    try std.testing.expectEqual(@as(?bonds.Bond, null), try store.load(bond.peer));
    try std.testing.expect(std.mem.indexOf(u8, &flash.bytes, &replacement.ltk) == null);
    try std.testing.expect(std.mem.indexOf(u8, &flash.bytes, &bond.irk) == null);
    try store.remove(bond.peer);
    for (0..8) |i| {
        var other = bond;
        other.peer[6] = @intCast(20 + i);
        other.identity = other.peer;
        try store.save(other);
    }
    try std.testing.expectError(error.StorageFailed, store.save(bond));
}
test "an unauthenticated save cannot shadow an authenticated identity from a lower slot" {
    var flash: Flash = .{};
    const Storage = nvs.Storage(*Flash);
    var storage: Storage = undefined;
    try storage.init(&flash, flash.bytes.len);
    var adapter: bonds.Nvs(Storage.Handle) = .{ .handle = try storage.open("ble_bonds", .read_write_purge) };
    const store = adapter.interface();
    const attacker: bonds.Bond = .{ .peer = .{ 0, 9, 9, 9, 9, 9, 9 }, .identity = .{ 0, 9, 9, 9, 9, 9, 9 }, .ltk = @splat(0x11), .authenticated = false };
    const victim: bonds.Bond = .{ .peer = .{ 1, 0xc1, 2, 3, 4, 5, 6 }, .identity = .{ 0, 1, 2, 3, 4, 5, 6 }, .ltk = @splat(0x22), .authenticated = true };
    try store.save(attacker); // slot 0
    try store.save(victim); // slot 1
    var claim = attacker;
    claim.identity = victim.identity;
    claim.ltk = @splat(0x33);
    try std.testing.expectError(error.StorageFailed, store.save(claim));
    try std.testing.expectEqualDeep(victim, (try store.load(victim.identity)).?);
    try std.testing.expectEqualDeep(attacker, (try store.load(attacker.peer)).?);
    // An unauthenticated duplicate is merged into one record, not left behind
    // a lower slot where load() would find it first.
    var weak = victim;
    weak.peer = .{ 0, 7, 7, 7, 7, 7, 7 };
    weak.identity = weak.peer;
    weak.authenticated = false;
    weak.ltk = @splat(0x55);
    try store.save(weak); // slot 2
    var upgrade = attacker;
    upgrade.identity = weak.identity;
    upgrade.authenticated = true;
    upgrade.ltk = @splat(0x44);
    try store.save(upgrade);
    try std.testing.expectEqualDeep(upgrade, (try store.load(weak.identity)).?);
    try std.testing.expectEqualDeep(upgrade, (try store.load(attacker.peer)).?);
    try std.testing.expect(std.mem.indexOf(u8, &flash.bytes, &weak.ltk) == null);
    try std.testing.expectEqualDeep(victim, (try store.load(victim.peer)).?);
}
test "an authenticated save matching two authenticated bonds replaces neither" {
    var flash: Flash = .{};
    const Storage = nvs.Storage(*Flash);
    var storage: Storage = undefined;
    try storage.init(&flash, flash.bytes.len);
    var adapter: bonds.Nvs(Storage.Handle) = .{ .handle = try storage.open("ble_bonds", .read_write_purge) };
    const store = adapter.interface();
    const x: bonds.Bond = .{ .peer = .{ 0, 1, 1, 1, 1, 1, 1 }, .identity = .{ 0, 1, 1, 1, 1, 1, 1 }, .ltk = @splat(0x11), .authenticated = true };
    const y: bonds.Bond = .{ .peer = .{ 0, 2, 2, 2, 2, 2, 2 }, .identity = .{ 0, 2, 2, 2, 2, 2, 2 }, .ltk = @splat(0x22), .authenticated = true };
    try store.save(x); // slot 0
    try store.save(y); // slot 1
    var claim = x;
    claim.identity = y.identity;
    claim.ltk = @splat(0x33);
    try std.testing.expectError(error.StorageFailed, store.save(claim));
    try storage.init(&flash, flash.bytes.len);
    try std.testing.expectEqualDeep(x, (try store.load(x.peer)).?);
    try std.testing.expectEqualDeep(y, (try store.load(y.identity)).?);
    try std.testing.expect(std.mem.indexOf(u8, &flash.bytes, &claim.ltk) == null);
}
