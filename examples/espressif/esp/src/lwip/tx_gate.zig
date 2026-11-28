const c = @import("include.zig").c;

const TxGate = @This();

/// Read by linkoutput while it holds the TCP/IP core lock.
enabled: bool = false,

pub fn set_enabled(gate: *TxGate, enabled: bool) void {
    c.LOCK_TCPIP_CORE();
    defer c.UNLOCK_TCPIP_CORE();
    gate.enabled = enabled;
}
