const std = @import("std");

// lwIP bindings for native tests of the ESP sys_arch exports and Wi-Fi teardown.
pub const c = struct {
    pub const err_t = i8;
    pub const ERR_OK = 0;
    pub const ERR_MEM = -1;
    pub const SYS_ARCH_TIMEOUT = 0xffffffff;
    pub const SYS_MBOX_EMPTY = SYS_ARCH_TIMEOUT;

    pub const sys_mbox_t = ?*anyopaque;
    pub const sys_mutex_t = ?*anyopaque;
    pub const sys_sem_t = ?*anyopaque;
    pub const sys_thread_t = ?*anyopaque;
    pub const lwip_thread_fn = ?*const fn (?*anyopaque) callconv(.c) void;

    pub var lock_tcpip_core: sys_mutex_t = null;
    pub const ERR_BUF = -2;
    pub const ERR_TIMEOUT = -3;
    pub const ERR_RTE = -4;
    pub const ERR_INPROGRESS = -5;
    pub const ERR_VAL = -6;
    pub const ERR_WOULDBLOCK = -7;
    pub const ERR_USE = -8;
    pub const ERR_ALREADY = -9;
    pub const ERR_ISCONN = -10;
    pub const ERR_CONN = -11;
    pub const ERR_IF = -12;
    pub const ERR_ABRT = -13;
    pub const ERR_RST = -14;
    pub const ERR_CLSD = -15;
    pub const ERR_ARG = -16;

    pub const u8_t = u8;
    pub const enum_netconn_type = c_int;
    pub const NETCONN_TCP = 0x10;
    pub const NETCONN_COPY = 1;
    pub const NETIF_FLAG_BROADCAST = 2;
    pub const NETIF_FLAG_ETHARP = 8;
    pub const NETIF_FLAG_ETHERNET = 16;
    pub const NETIF_FLAG_IGMP = 32;
    pub const NETIF_FLAG_MLD6 = 64;

    pub const struct_pbuf = extern struct { tot_len: u16 = 1 };
    pub const struct_netconn = extern struct { unused: u8 = 0 };
    pub const netconn = struct_netconn;
    pub const netbuf = extern struct { unused: u8 = 0 };
    pub const ip4_addr_t = extern struct { addr: u32 = 0 };
    pub const ip_addr_t = extern struct { u_addr: extern union { ip4: ip4_addr_t } = .{ .ip4 = .{} } };
    const LinkOutput = *const fn ([*c]netif, [*c]struct_pbuf) callconv(.c) err_t;
    pub const struct_netif = extern struct {
        name: [2]u8 = undefined,
        linkoutput: ?LinkOutput = null,
        output: ?LinkOutput = null,
        output_ip6: ?LinkOutput = null,
        mtu: u16 = 0,
        flags: u8 = 0,
        hwaddr: [6]u8 = undefined,
        hwaddr_len: u8 = 0,
        ip_addr: ip_addr_t = .{},
    };
    pub const netif = struct_netif;
    const any_ip4: ip4_addr_t = .{};
    pub const IP4_ADDR_ANY = &any_ip4;
    pub var server_conn: netconn = .{};

    const io = std.testing.io;
    var core: std.Io.Mutex = .init;

    pub fn LOCK_TCPIP_CORE() void {
        // A runnable send can finish when the teardown task blocks on its lock.
        if (TxTest.worker != null) TxTest.resume_send.set(io);
        core.lockUncancelable(io);
    }

    pub fn UNLOCK_TCPIP_CORE() void {
        core.unlock(io);
    }

    pub fn tcpip_init(_: ?*const anyopaque, _: ?*anyopaque) void {}

    pub fn netifapi_netif_add(
        nif: *netif,
        _: *const ip4_addr_t,
        _: *const ip4_addr_t,
        _: *const ip4_addr_t,
        init_arg: ?*anyopaque,
        init: *const fn ([*c]netif) callconv(.c) err_t,
        _: LinkOutput,
    ) err_t {
        std.debug.assert(init_arg == null);
        LOCK_TCPIP_CORE();
        defer UNLOCK_TCPIP_CORE();
        nif.* = .{};
        TxTest.registered_netif = nif;
        return init(nif);
    }

    pub fn netifapi_netif_common(nif: *netif, action: ?*const fn (*netif) void, checked: ?*const fn (*netif) err_t) err_t {
        if (action == &netif_set_link_down) {
            // The TX gate should already have drained the paused sender.
            // Leave it paused on failure so deinit can observe the overlap.
            if (!core.tryLock()) return ERR_IF;
        } else {
            LOCK_TCPIP_CORE();
        }
        if (action) |run| run(nif);
        const result = if (checked) |run| run(nif) else ERR_OK;
        UNLOCK_TCPIP_CORE();

        if (action == &dhcp_release_and_stop and TxTest.start_after == .dhcp_release)
            TxTest.start_admitted_send();
        if (action == &netif_set_link_down)
            TxTest.pending_at_link_down = TxTest.run_pending_output();
        return result;
    }

    pub fn netconn_bind(_: [*c]netconn, _: ?*const ip_addr_t, _: u16) err_t {
        return ERR_USE;
    }

    pub fn netconn_delete(_: [*c]netconn) err_t {
        if (TxTest.start_after == .tcp_listener_delete) TxTest.start_admitted_send();
        return ERR_OK;
    }

    pub fn netconn_close(_: [*c]netconn) err_t {
        return ERR_OK;
    }

    pub fn netconn_listen(_: [*c]netconn) err_t {
        unreachable;
    }

    pub fn netconn_accept(_: [*c]netconn, _: *?*netconn) err_t {
        unreachable;
    }

    pub fn netconn_recv(_: ?*netconn, _: *?*netbuf) err_t {
        unreachable;
    }

    pub fn netbuf_delete(_: ?*netbuf) void {
        unreachable;
    }

    pub fn netbuf_data(_: ?*netbuf, _: *?*anyopaque, _: *u16) err_t {
        unreachable;
    }

    pub fn netconn_write_partly(_: ?*netconn, _: ?*anyopaque, _: usize, _: c_int, _: ?*usize) err_t {
        unreachable;
    }

    pub fn dhcp_start(_: *netif) err_t {
        return ERR_OK;
    }
    pub fn dhcp_release_and_stop(_: *netif) void {}
    pub fn netif_set_link_up(_: *netif) void {}
    pub fn netif_set_link_down(_: *netif) void {}
    pub fn netif_create_ip6_linklocal_address(_: [*c]netif, _: u8) void {}
    pub fn netif_set_status_callback(_: [*c]netif, _: *const fn ([*c]netif) callconv(.c) void) void {}
    pub fn netif_set_default(_: [*c]netif) void {}
    pub fn netif_set_up(_: [*c]netif) void {}

    pub fn etharp_output(_: [*c]netif, _: [*c]struct_pbuf) callconv(.c) err_t {
        unreachable;
    }
    pub const ethip6_output = etharp_output;
    pub const tcpip_input = etharp_output;

    pub fn pbuf_copy_partial(p: *struct_pbuf, dst: [*]u8, len: u16, off: u16) u16 {
        const count = @min(len, p.tot_len - off);
        @memset(dst[0..count], 0);
        return count;
    }

    pub fn ip4addr_ntoa(_: *const ip4_addr_t) [*:0]const u8 {
        return "192.0.2.1";
    }

    /// A completed send releases the real host mutex. Pending ARP output can
    /// grab the same lock as soon as the corresponding API call releases it.
    pub const TxTest = struct {
        const StartAfter = enum { tcp_listener_delete, dhcp_release };
        var start_after: StartAfter = undefined;
        var registered_netif: ?*netif = null;
        var worker: ?std.Thread = null;
        var entered_send: std.Io.Event = .unset;
        var resume_send: std.Io.Event = .unset;
        threadlocal var admitted_worker: bool = false;
        var sent: usize = 0;
        var admitted_result: ?err_t = null;
        var deinit_saw_completed: bool = false;
        var pending_at_deinit: ?err_t = null;
        pub var pending_at_link_down: ?err_t = null;

        pub fn reset(boundary: StartAfter) void {
            std.debug.assert(worker == null);
            start_after = boundary;
            registered_netif = null;
            entered_send = .unset;
            resume_send = .unset;
            sent = 0;
            admitted_result = null;
            deinit_saw_completed = false;
            pending_at_deinit = null;
            pending_at_link_down = null;
        }

        pub fn finish() void {
            if (worker) |thread| {
                resume_send.set(io);
                thread.join();
                worker = null;
            }
        }

        fn start_admitted_send() void {
            worker = std.Thread.spawn(.{}, run_admitted_output, .{}) catch @panic("start TX test thread");
            entered_send.waitUncancelable(io);
        }

        fn run_admitted_output() void {
            admitted_worker = true;
            core.lockUncancelable(io);
            const nif = registered_netif.?;
            var pbuf: struct_pbuf = .{};
            admitted_result = nif.linkoutput.?(nif, &pbuf);
            core.unlock(io);
            // Also wake the test if linkoutput incorrectly refused admission.
            entered_send.set(io);
        }

        fn run_pending_output() err_t {
            core.lockUncancelable(io);
            defer core.unlock(io);
            const nif = registered_netif.?;
            var pbuf: struct_pbuf = .{};
            return nif.linkoutput.?(nif, &pbuf);
        }

        pub fn send() void {
            if (admitted_worker) {
                entered_send.set(io);
                resume_send.waitUncancelable(io);
            }
            sent += 1;
        }

        pub fn deinit() void {
            // Start of Wi-Fi teardown. A held lock means the admitted send
            // can still be in the driver. Release it after observing the race
            // so a missing shutdown barrier produces a test failure, not a hang.
            deinit_saw_completed = core.tryLock();
            if (deinit_saw_completed) core.unlock(io);
            resume_send.set(io);
            pending_at_deinit = run_pending_output();
        }

        pub fn expect_drained() !void {
            finish();
            try std.testing.expectEqual(ERR_OK, admitted_result);
            try std.testing.expect(deinit_saw_completed);
            try std.testing.expectEqual(ERR_IF, pending_at_deinit);
            try std.testing.expectEqual(@as(usize, 1), sent);
        }
    };
};
