const c = @import("lwip").c;

test {
    _ = @import("lwip/exports.zig");
    _ = @import("tcp_server.zig");
    _ = @import("selftest_coex_wifi_ble.zig");
}

// The firmware uses an explicit extern declaration for this C function.
export fn netconn_new_with_proto_and_callback(_: c.enum_netconn_type, _: c.u8_t, _: ?*const anyopaque) [*c]c.struct_netconn {
    return &c.server_conn;
}
