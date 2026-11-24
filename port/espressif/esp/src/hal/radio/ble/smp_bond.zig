//! Versioned bond records in an application-owned hal.nvs namespace, opened
//! read_write_purge. One atomic blob holds eight peers, including their IRKs.
const std = @import("std");
const crypto = @import("smp_crypto.zig");
pub const Bond = struct {
    peer: crypto.Address,
    ltk: crypto.Key,
    irk: crypto.Key = @splat(0),
    identity: crypto.Address,
    authenticated: bool,
};
pub const Error = error{StorageFailed};
pub const Store = struct {
    context: *anyopaque,
    load_fn: *const fn (*anyopaque, crypto.Address) Error!?Bond,
    save_fn: *const fn (*anyopaque, Bond) Error!void,
    remove_fn: *const fn (*anyopaque, crypto.Address) Error!void,
    pub fn load(self: Store, peer: crypto.Address) Error!?Bond {
        return self.load_fn(self.context, peer);
    }
    pub fn save(self: Store, bond: Bond) Error!void {
        return self.save_fn(self.context, bond);
    }
    pub fn remove(self: Store, peer: crypto.Address) Error!void {
        return self.remove_fn(self.context, peer);
    }
};
/// Adapter owns a copy of the NVS handle; its storage/flash and this adapter
/// must outlive the host. Full storage fails rather than evicting a peer.
pub fn Nvs(comptime Handle: type) type {
    return struct {
        handle: Handle,
        const Self = @This();
        const record_size = 48;
        const Table = [8 * record_size]u8;
        pub fn interface(self: *Self) Store {
            return .{ .context = self, .load_fn = load, .save_fn = save, .remove_fn = remove };
        }
        fn read(self: *Self) Error!Table {
            if (self.handle.mode != .read_write_purge) return error.StorageFailed;
            var bytes: Table = @splat(0);
            const data = self.handle.get_blob("bonds_v1", &bytes) catch |err| switch (err) {
                error.NotFound => return bytes,
                else => return error.StorageFailed,
            };
            if (data.len != bytes.len) return error.StorageFailed;
            for (0..8) |i| {
                const record = bytes[i * record_size ..][0..record_size];
                if (record[0] > 1 or (record[0] == 1 and (record[1] > 1 or record[2] > 1 or record[25] > 1))) return error.StorageFailed;
            }
            return bytes;
        }
        fn decode(bytes: *const [record_size]u8) Bond {
            return .{ .peer = bytes[2..9].*, .authenticated = bytes[1] == 1, .ltk = bytes[9..25].*, .identity = bytes[25..32].*, .irk = bytes[32..48].* };
        }
        fn matches(bond: Bond, peer: crypto.Address) bool {
            if (std.mem.eql(u8, &bond.peer, &peer) or std.mem.eql(u8, &bond.identity, &peer)) return true;
            // Core Vol 3 Part H §2.2.2: RPA = prand || ah(IRK, prand).
            return peer[0] == 1 and peer[1] & 0xc0 == 0x40 and
                !std.mem.allEqual(u8, &bond.irk, 0) and
                std.mem.eql(u8, &crypto.ah(bond.irk, peer[1..4].*), peer[4..7]);
        }
        fn load(ctx: *anyopaque, peer: crypto.Address) Error!?Bond {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var table = try self.read();
            defer std.crypto.secureZero(u8, &table);
            for (0..8) |i| {
                const record = table[i * record_size ..][0..record_size];
                if (record[0] == 0) continue;
                const bond = decode(record);
                if (matches(bond, peer)) return bond;
            }
            return null;
        }
        fn save(ctx: *anyopaque, bond: Bond) Error!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var table = try self.read();
            defer std.crypto.secureZero(u8, &table);
            // Every record naming this connection address or identity is the
            // same peer. An unauthenticated save may replace none of them, or a
            // lower slot could shadow an authenticated bond for load(). The
            // first match is overwritten and later duplicates are purged, but
            // only when at most one of them is authenticated: one pairing may
            // not replace two authenticated bonds.
            var free: ?usize = null;
            var first: ?usize = null;
            var authenticated_match = false;
            for (0..8) |i| {
                const record = table[i * record_size ..][0..record_size];
                if (record[0] == 0) {
                    if (free == null) free = i;
                    continue;
                }
                const old = decode(record);
                if (!matches(old, bond.peer) and !matches(old, bond.identity)) continue;
                if (old.authenticated) {
                    if (!bond.authenticated) return error.StorageFailed;
                    if (authenticated_match) return error.StorageFailed;
                    authenticated_match = true;
                }
                if (first == null) first = i else @memset(record, 0);
            }
            const i = first orelse free orelse return error.StorageFailed;
            table[i * record_size ..][0..record_size].* = [2]u8{ 1, @intFromBool(bond.authenticated) } ++ bond.peer ++ bond.ltk ++ bond.identity ++ bond.irk;
            self.handle.set_blob("bonds_v1", &table) catch return error.StorageFailed;
            self.handle.commit() catch return error.StorageFailed;
        }
        fn remove(ctx: *anyopaque, peer: crypto.Address) Error!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var table = try self.read();
            defer std.crypto.secureZero(u8, &table);
            var changed = false;
            for (0..8) |i| {
                const record = table[i * record_size ..][0..record_size];
                if (record[0] == 0 or !matches(decode(record), peer)) continue;
                @memset(record, 0);
                changed = true;
            }
            if (changed) {
                self.handle.set_blob("bonds_v1", &table) catch return error.StorageFailed;
                self.handle.commit() catch return error.StorageFailed;
            }
        }
    };
}
