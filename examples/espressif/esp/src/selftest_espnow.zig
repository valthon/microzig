//! Same image on two boards, no AP or wiring. Lower station MAC coordinates.
//! Expected SELFTEST espnow DONE pass=9 fail=0, within 60 seconds of first boot.
//! The selftest_espnow_coex build selects Wi-Fi + BLE: each board starts the
//! BLE controller and advertises "MZ-ESPNOW" (non-connectable) before Wi-Fi.
//! After its ESP-NOW exchange each board scans for the peer's advertisement
//! from the peer's public address, keeps advertising while the peer can still
//! be scanning, then stops advertising with an HCI command. Hearing the peer
//! and stopping are a tenth check. Expected DONE pass=10 fail=0.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const radio = hal.radio;
const now = radio.espnow;
const rtos = hal.rtos;
const coex = @import("espnow_options").coex;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .logFn = hal.usb_serial_jtag.logger.log, .log_level = .info });
pub const microzig_options: microzig.Options = if (coex) .{
    .interrupts = .{ .interrupt29 = radio.bluetooth.interrupt_handler, .interrupt30 = radio.interrupt_handler, .interrupt31 = rtos.interrupt_handler },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{ .rtos = .{ .enable = true }, .radio = .{ .radios = .{ .wifi = true, .ble = true } } },
} else .{
    .interrupts = .{ .interrupt30 = radio.interrupt_handler, .interrupt31 = rtos.interrupt_handler },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{ .rtos = .{ .enable = true } },
};
comptime {
    _ = microzig.export_startup();
}
// The BLE controller requires the 160 MHz CPU clock (bluetooth.zig rejects
// others with InvalidCpuClock); the Wi-Fi-only build keeps the HAL default.
pub const init = if (coex) init_160_mhz else hal.init;
const clock_160_mhz: hal.clocks.Config = .init_comptime(160_000_000);
fn init_160_mhz() void {
    hal.init_sequence(clock_160_mhz);
}
const names = [_][]const u8{ "init", "peer_table", "broadcast", "absent_delivery", "unicast", "encrypted", "mismatched_key", "maximum_payload", "deinit" } ++
    (if (coex) [_][]const u8{"ble_advertising"} else [_][]const u8{});
var controller: if (coex) radio.bluetooth.Controller else void = if (coex) .{} else {};
var host: if (coex) radio.bluetooth.host.Host else void = undefined;
// The coex build's heap shared by Wi-Fi and BLE, attached for the rest of the boot.
var radio_heap_buffer: if (coex) [128 * 1024]u8 else void align(16) = undefined;
var radio_heap: if (coex) radio.SharedHeap else void = undefined;
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
const ble_name = "MZ-ESPNOW";
// Flags (LE General Discoverable, no BR/EDR) and the complete local name.
const advertising_data = [_]u8{ 2, 1, 6, ble_name.len + 1, 9 } ++ ble_name.*;
/// How long a board scans for the peer's advertisement.
const scan_ms = 5000;

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
    if (coex) {
        try controller.start(gpa);
        host = .init(controller.transport());
        try host.initialize();
        try host.advertise_nonconnectable(&advertising_data);
    }
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
    // Advertise while the peer can still be scanning. The follower leaves its
    // final window at most phase_ms after the leader's exchange ends, then
    // scans for up to scan_ms. The leader ended first and scans for up to
    // scan_ms, so its scan ends within scan_ms of the follower's end. The extra
    // second covers the peer's session deinit before its scan.
    const hold = if (coex) deadline(if (leader) protocol.phase_ms + scan_ms + 1000 else scan_ms + 1000) else {};
    if (try session.dropped_frames() != 0) return error.ReceiveOverflow;
    try session.deinit();
    results[8] = true;
    if (coex) {
        const heard = try hear_peer(hold);
        try host.stop_advertising();
        results[9] = heard;
    }
}
/// Scan for the peer's advertisement, which proves that it is still
/// advertising after this board's exchange: the leader ends first and hears
/// the follower during the follower's final ESP-NOW window, and the follower
/// hears the leader after the leader's exchange. Advertising continues until
/// `hold`, so the peer's scan can hear this board; the run limit can cut the
/// hold short, which is logged.
fn hear_peer(hold: microzig.drivers.time.Deadline) !bool {
    var heard = false;
    host.on_advertisement = peer_advertisement;
    host.advertisement_context = &heard;
    defer host.on_advertisement = null;
    const start = hal.time.get_time_since_boot();
    try host.scan(true);
    const limit = deadline(scan_ms);
    while (!heard and !expired(limit)) try poll_host();
    try host.scan(false);
    if (heard) std.log.info("SELFTEST espnow heard the peer's {s} after {d} ms", .{ ble_name, (hal.time.get_time_since_boot().to_us() - start.to_us()) / 1000 });
    while (!expired(hold)) try poll_host();
    if (!hold.is_reached_by(hal.time.get_time_since_boot()))
        std.log.warn("SELFTEST espnow run limit cut the advertising hold short", .{});
    return heard;
}
fn poll_host() !void {
    host.poll(50) catch |err| if (err != error.Timeout) return err;
}
/// Matches the peer's name from its public address: bluetooth.zig sets the
/// station MAC plus two in the last octet (IDF v5.5.1
/// esp_hw_support/mac_addr.c:16-17,391-397 under the C6 default of four
/// universal addresses, port/esp32c6/Kconfig.mac:3,33-40), and HCI reports
/// carry it reversed.
fn peer_advertisement(context: ?*anyopaque, ad: *const radio.bluetooth.host.Advertisement) void {
    const heard: *bool = @ptrCast(@alignCast(context));
    var address = other;
    address[5] +%= 2;
    std.mem.reverse(u8, &address);
    const name = ad.name() orelse return;
    if (ad.address_type == 0 and std.mem.eql(u8, &ad.address, &address) and std.mem.eql(u8, name, ble_name)) heard.* = true;
}
pub fn main() void {
    run_limit = deadline(55000);
    // The BLE controller's storage comes from the same heap in the coex build.
    var heap = microzig.Allocator.init_with_heap(if (coex) 160 * 1024 else 65536) catch |err| finish(err);
    if (coex) {
        radio_heap = radio.SharedHeap.init(&radio_heap_buffer) catch |err| finish(err);
        radio.attach_shared_heap(&radio_heap) catch |err| finish(err);
    }
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
