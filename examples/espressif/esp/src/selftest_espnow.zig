//! Same image on two boards, no AP or wiring. Lower station MAC coordinates.
//! Expected SELFTEST espnow DONE pass=9 fail=0, within 60 seconds of first boot.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const radio = hal.radio;
const now = radio.espnow;
const rtos = hal.rtos;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .logFn = hal.usb_serial_jtag.logger.log, .log_level = .info });
pub const microzig_options: microzig.Options = .{
    .interrupts = .{ .interrupt30 = radio.interrupt_handler, .interrupt31 = rtos.interrupt_handler },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{ .rtos = .{ .enable = true } },
};
comptime {
    _ = microzig.export_startup();
}
const names = [_][]const u8{ "init", "peer_table", "broadcast", "absent_delivery", "unicast", "encrypted", "mismatched_key", "maximum_payload", "deinit" };
var results: [names.len]bool = @splat(false);
var session: now.Session = .{};
var frame: now.Frame = undefined;
var other: now.Mac = undefined;
var mismatch_received = false;
const key: now.Key = @splat(0x35);
const wrong_key: now.Key = @splat(0xa7);
const magic = "MZESPNOW";
const protocol = @import("selftest_espnow_protocol.zig");
const absent: now.Mac = .{ 2, 0x4d, 0x5a, 0xee, 0xff, 0x19 };
var run_limit: microzig.drivers.time.Deadline = undefined;

fn deadline(ms: u32) microzig.drivers.time.Deadline {
    return .init_relative(hal.time.get_time_since_boot(), .from_ms(ms));
}
fn expired(limit: microzig.drivers.time.Deadline) bool {
    const time = hal.time.get_time_since_boot();
    return limit.is_reached_by(time) or run_limit.is_reached_by(time);
}
fn packet(out: []u8, kind: u8, phase: u8) void {
    for (out, 0..) |*byte, i| byte.* = @intCast(i % 251);
    @memcpy(out[0..8], magic);
    out[8] = kind;
    out[9] = phase;
    out[10] = @intFromBool(mismatch_received);
    out[11] = @intCast(session.version);
}
fn valid() bool {
    return frame.len >= 12 and std.mem.eql(u8, frame.data[0..8], magic);
}
fn from_peer() bool {
    return valid() and std.mem.eql(u8, &frame.source, &other);
}
fn send(address: now.Mac, bytes: []const u8) !now.Delivery {
    try session.send(address, bytes);
    const limit = deadline(2000);
    while (!expired(limit)) {
        if (try session.poll_delivery()) |delivery| return delivery;
        if (std.mem.eql(u8, &address, &absent)) {
            // Only delivery matters for this probe. Drain repeated hellos/phase 1
            // while waiting so a slow absent-peer callback cannot fill the FIFO.
            while (try session.poll_receive(&frame)) {}
        }
        rtos.sleep(.from_ms(2));
    }
    return error.DeliveryTimeout;
}
fn message(kind: u8, phase: u8) !void {
    var bytes: [12]u8 = undefined;
    packet(&bytes, kind, phase);
    if (try send(now.broadcast, &bytes) != .success) return error.BroadcastDelivery;
}
fn configure(phase: u8, leader: bool) !void {
    try session.modify_peer(.{ .address = other, .channel = 1, .lmk = if (phase == 1) null else if (phase == 3 and leader) wrong_key else key });
}
fn table_checks() !void {
    const count = try session.peer_count();
    if (count.total != 1 or count.encrypted != 0) return error.Count;
    try session.add_peer(.{ .address = other, .channel = 1 });
    if (!try session.has_peer(other)) return error.MissingPeer;
    if (session.add_peer(.{ .address = other })) |_| return error.DuplicateAccepted else |err| {
        if (err != error.PeerExists) return err;
    }
    try session.modify_peer(.{ .address = other, .channel = 1, .lmk = key });
    const peer = try session.get_peer(other);
    const encrypted = try session.peer_count();
    if (peer.channel != 1 or peer.interface != .sta or peer.lmk == null or !std.mem.eql(u8, &peer.lmk.?, &key) or encrypted.total != 2 or encrypted.encrypted != 1) return error.PeerRoundtrip;
    try session.remove_peer(other);
    if (try session.has_peer(other)) return error.RemoveFailed;
    if (session.get_peer(other)) |_| return error.RemovedFound else |err| {
        if (err != error.PeerNotFound) return err;
    }
    try session.add_peer(.{ .address = other, .channel = 1 });
    results[1] = true;
    try session.add_peer(.{ .address = absent, .channel = 1 });
    results[3] = try send(absent, "MZESPNOWabsent") == .failure;
    try session.remove_peer(absent);
}
fn discover() !void {
    const own = radio.read_mac(.sta);
    const limit = deadline(protocol.discovery_ms);
    var discovery: protocol.Discovery = .{ .own = own };
    var next = deadline(0);
    while (!expired(limit)) {
        if (expired(next)) {
            try message(0, 0);
            next = deadline(200);
        }
        while (try session.poll_receive(&frame)) {
            if (!valid() or !std.mem.eql(u8, &frame.destination, &now.broadcast)) continue;
            if (discovery.receive(frame.source, frame.data[8], frame.data[9])) {
                other = discovery.peer.?;
                results[2] = true;
                return;
            }
        }
        rtos.sleep(.from_ms(5));
    }
    return error.DiscoveryTimeout;
}
fn start_phase(phase: u8) !void {
    try configure(phase, true);
    const limit = deadline(protocol.phase_ms);
    var next = deadline(0);
    while (!expired(limit)) {
        if (expired(next)) {
            try message(1, phase);
            next = deadline(250);
        }
        while (try session.poll_receive(&frame)) {
            if (!from_peer()) continue;
            if (frame.data[8] == 3 and frame.data[9] == 3) mismatch_received = true;
            if (frame.data[8] == 2 and frame.data[9] == phase) {
                if (frame.data[11] != session.version) return error.VersionMismatch;
                if (phase == 4) results[6] = !mismatch_received and frame.data[10] == 0;
                return;
            }
        }
        rtos.sleep(.from_ms(5));
    }
    return error.PhaseTimeout;
}
fn exchange(phase: u8) !bool {
    var bytes: [now.max_payload]u8 = undefined;
    const len: usize = if (phase == 4) session.max_payload_len else 32;
    packet(bytes[0..len], 3, phase);
    const limit = deadline(protocol.exchange_ms);
    var next = deadline(0);
    while (!expired(limit)) {
        if (expired(next)) {
            // A MAC ACK does not guarantee that the application received the frame.
            _ = try send(other, bytes[0..len]);
            next = deadline(250);
        }
        while (try session.poll_receive(&frame)) {
            if (from_peer() and frame.data[8] == 3 and frame.data[9] == phase)
                return frame.rssi != null and frame.len == len and std.mem.eql(u8, frame.payload(), bytes[0..len]);
        }
        rtos.sleep(.from_ms(5));
    }
    return false;
}
fn lead() !void {
    try start_phase(1);
    results[4] = try exchange(1);
    try start_phase(2);
    results[5] = try exchange(2);
    try start_phase(3);
    var bytes: [32]u8 = undefined;
    packet(&bytes, 3, 3);
    _ = try send(other, &bytes); // MAC ACK may succeed even though decryption fails.
    const limit = deadline(1800);
    while (!expired(limit)) {
        while (try session.poll_receive(&frame)) {
            if (from_peer() and frame.data[8] == 3 and frame.data[9] == 3) mismatch_received = true;
        }
        rtos.sleep(.from_ms(5));
    }
    try start_phase(4);
    results[7] = try exchange(4);
    // Keep the follower alive until it has echoed and recorded the final delivery.
    try start_phase(5);
}
fn follow() !void {
    var phase: u8 = 0;
    const limit = deadline(40000);
    var final_limit: ?microzig.drivers.time.Deadline = null;
    while (!expired(limit)) {
        // Cover the leader's entire phase retry window if the first final ACK is lost.
        if (final_limit) |end| {
            if (expired(end)) return;
        }
        if (try session.poll_receive(&frame)) {
            if (!from_peer()) continue;
            const kind = frame.data[8];
            const incoming = frame.data[9];
            if (kind == 1 and incoming >= 1 and incoming <= 5) {
                if (incoming != phase) {
                    if (incoming != phase + 1) return error.PhaseOrder;
                    if (incoming == 4) results[6] = !mismatch_received;
                    if (incoming != 5) try configure(incoming, false);
                    phase = incoming;
                    try message(2, phase);
                    if (phase == 3) {
                        var bytes: [32]u8 = undefined;
                        packet(&bytes, 3, 3);
                        _ = try send(other, &bytes);
                    }
                    if (phase == 5) final_limit = deadline(protocol.phase_ms);
                } else try message(2, phase);
            } else if (kind == 3 and incoming == 3) {
                mismatch_received = true;
            } else if (kind == 3 and incoming == phase and phase < 5) {
                const len: usize = if (phase == 4) session.max_payload_len else 32;
                var expected: [now.max_payload]u8 = undefined;
                packet(expected[0..len], 3, phase);
                const correct = frame.len == len and frame.rssi != null and std.mem.eql(u8, frame.payload(), expected[0..len]);
                const delivered = try send(other, frame.payload()) == .success;
                const index: usize = switch (phase) {
                    1 => 4,
                    2 => 5,
                    4 => 7,
                    else => return error.UnexpectedData,
                };
                // Duplicate requests must be echoed too: the previous echo may be lost.
                results[index] = results[index] or (correct and delivered);
            }
        } else rtos.sleep(.from_ms(5));
    }
    return error.FollowerTimeout;
}
fn exercise(gpa: std.mem.Allocator) !void {
    @import("wifi_antenna.zig").apply();
    try radio.wifi.init(gpa, .{});
    try radio.wifi.apply(.{ .sta = .{ .ssid = "", .channel = 1 } });
    try radio.wifi.start();
    const limit = deadline(3000);
    while (!radio.wifi.get_sta_state().is_started()) {
        if (expired(limit)) return error.WifiStartTimeout;
        rtos.sleep(.from_ms(5));
    }
    try radio.wifi.c_err(radio.wifi.c.esp_wifi_set_channel(1, radio.wifi.c.WIFI_SECOND_CHAN_NONE));
    try session.init();
    try session.set_pmk(@splat(0x91));
    try session.set_wake_window(65535);
    try session.add_peer(.{ .address = now.broadcast, .channel = 1 });
    results[0] = true;
    try discover();
    try table_checks();
    const own = radio.read_mac(.sta);
    const leader = std.mem.order(u8, &own, &other) == .lt;
    std.log.info("SELFTEST espnow role={s} version={d} maximum={d}", .{ if (leader) "leader" else "follower", session.version, session.max_payload_len });
    if (leader) try lead() else try follow();
    if (try session.dropped_frames() != 0) return error.ReceiveOverflow;
    try session.deinit();
    results[8] = true;
}
pub fn main() void {
    run_limit = deadline(55000);
    var heap = microzig.Allocator.init_with_heap(65536) catch |err| finish(err);
    exercise(heap.allocator()) catch |err| finish(err);
    finish(null);
}
fn finish(failure: ?anyerror) noreturn {
    while (true) {
        var passed: usize = 0;
        for (names, results) |name, ok| {
            std.log.info("SELFTEST espnow {s}: {s}", .{ name, if (ok) "PASS" else "FAIL" });
            passed += @intFromBool(ok);
        }
        if (failure) |err| std.log.err("SELFTEST espnow error: {t}", .{err});
        std.log.info("SELFTEST espnow DONE pass={d} fail={d}", .{ passed, names.len - passed });
        rtos.sleep(.from_ms(3000));
    }
}
