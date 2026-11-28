# dhcp-server

A small DHCPv4 server for a device that runs its own access point. It parses one request
datagram and builds the reply; the caller owns the UDP socket on port 67 and the clock, so it
works with any IP stack.

```zig
const dhcp = @import("dhcp_server");
const Dhcp = dhcp.Server(.{}); // 192.168.4.1/24, four leases from 192.168.4.2

var server: Dhcp = .{};

// In the port 67 receive callback:
if (server.receive(datagram, now_ms)) |reply| {
    // send reply.bytes to reply.destination, port dhcp.client_port
}
```

Design, invariants and the callers: [`docs/design/dhcp-server.md`](../../docs/design/dhcp-server.md).
