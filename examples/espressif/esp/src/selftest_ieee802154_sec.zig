//! SAME image on Super Mini ESP32-C6 and XIAO ESP32-C6; no wiring. GPIO3/14
//! select the XIAO ESP32-C6 internal antenna (leave these pads unconnected).
//! Roles use the full factory-derived extended address, not truncated shorts.
//! Fixed public test key, NEVER a deployment key. Reset both within 10 seconds.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const ieee = hal.radio.ieee802154;
const sec = ieee.security;
const hdr = ieee.header;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_level = .info,
    .log_scope_levels = &.{
        .{ .scope = .esp_radio, .level = .err },
        .{ .scope = .esp_radio_timer, .level = .err },
        .{ .scope = .esp_radio_osi, .level = .err },
    },
});
pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt29 = ieee.interrupt_handler,
        .interrupt30 = hal.radio.interrupt_handler,
        .interrupt31 = hal.rtos.interrupt_handler,
    },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{ .rtos = .{ .enable = true }, .radio = .{ .protocol = .ieee802154 } },
};
comptime {
    _ = microzig.export_startup();
}

const pan: u16 = 0x3254;
const checks = [_][]const u8{ "level1", "level2", "level3", "level4", "level5", "level6", "level7", "enhanced_ack", "legacy_ack", "tampered_mic", "replay" };
// Vendor-specific header IE, one byte, then HT2. The ACK validator must accept it.
const ack_ies = sec.hex("010fee803f");
const test_key = sec.hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecf");
const key_id: sec.KeyId = .{ .mode = 1, .index = 1 };

const Bench = struct {
    device: ieee.Radio = .{},
    local: [8]u8,
    peer: [8]u8 = @splat(0),
    sequence: u8 = 0,
    pass: u8 = 0,
    fail: u8 = 0,
    deadline: u64,
    diagnostic_stage: u8 = 255,

    fn report(self: *Bench, stage: u8, ok: bool) void {
        if (ok) self.pass += 1 else self.fail += 1;
        std.log.info("SELFTEST ieee802154_sec {s}: {s}", .{ checks[stage], if (ok) "PASS" else "FAIL" });
    }

    fn dump(stage: u8, label: []const u8, bytes: []const u8) void {
        std.log.info("stage={d} {s} len={d} bytes={x}", .{ stage, label, bytes.len, bytes });
        const h = hdr.parse(bytes) catch |err| {
            std.log.info("stage={d} {s} header={s}", .{ stage, label, @errorName(err) });
            return;
        };
        if (h.auxiliary) |a| std.log.info("stage={d} {s} sec={x} level={d} counter={d} mode={d} key_source={x} key_index={d} payload_offset={d} mic_len={d}", .{ stage, label, bytes[h.auxiliary_offset..][0..a.size()], a.level, a.counter, a.id.mode, a.id.source, a.id.index, h.payload_offset, sec.mic_len(a.level) });
    }

    fn expected_tx(stage: u8, input: []const u8, dma: []const u8) void {
        const h = hdr.parse(dma) catch return;
        const aux = h.auxiliary orelse return;
        var expected: [125]u8 = undefined;
        @memcpy(expected[0..input.len], input);
        _ = aux.encode(expected[h.auxiliary_offset..]) catch return;
        const mic = sec.mic_len(aux.level);
        sec.seal(test_key, sec.nonce(h.source[0..8].*, aux.counter, aux.level), aux.level, expected[0..input.len], h.payload_offset, expected[input.len..][0..mic]) catch |err| {
            std.log.info("stage={d} TX-expected={s}", .{ stage, @errorName(err) });
            return;
        };
        dump(stage, "TX-expected-wire", expected[0 .. input.len + mic]);
    }

    fn rx_diagnostic(self: *Bench, stage: u8, err: ?anyerror) void {
        var mic: []const u8 = "not_checked";
        if (err) |e| {
            if (e == error.AuthenticationFailed) mic = "failed";
        } else if (self.device.last_rx_wire) |f| {
            if (hdr.parse(f.bytes())) |h| {
                mic = if (h.auxiliary) |aux| (if (sec.mic_len(aux.level) == 0) "absent" else "passed") else "absent";
            } else |_| {}
        }
        std.log.info("stage={d} RX status={s} events=0x{x} abort={any} MIC={s}", .{ stage, if (err) |e| @errorName(e) else "received", self.device.last_events, self.device.last_rx_abort, mic });
        if (self.device.last_rx_wire) |f| dump(stage, "RX-wire", f.bytes());
        if (self.device.last_ack_tx) |trace| {
            std.log.info("stage={d} ACK-TX transmitted={} level={d} rx_counter={d} ack_counter={any} len={any} finish_reason={s} finish_events=0x{x} generation_error={s}", .{ stage, trace.transmitted(), trace.level, trace.received_counter, trace.ack_counter, trace.ack_len, if (trace.finish_reason) |r| @tagName(r) else "none", trace.finish_events, trace.generation_error orelse "none" });
            if (trace.ack_len) |len| dump(stage, if (trace.level >= 5) "ACK-TX-DMA-hardware" else "ACK-TX-wire", self.device.ack_dma[1..][0..len]);
        }
    }

    fn make_frame(self: *Bench, out: *[125]u8, kind: u8, stage: u8, level: u3, version: u2, ack: bool, broadcast: bool) !usize {
        out[0] = 0x01 | (if (broadcast or version < 2) @as(u8, 0x40) else 0) | (if (ack) @as(u8, 0x20) else 0) | (if (level != 0) @as(u8, 8) else 0);
        // Broadcast discovery uses a short destination; all tests use full addresses.
        out[1] = (if (broadcast) @as(u8, 0xc8) else 0xcc) | (@as(u8, version) << 4);
        out[2] = self.sequence;
        self.sequence +%= 1;
        std.mem.writeInt(u16, out[3..5], pan, .little);
        var offset: usize = 5;
        if (broadcast) {
            @memset(out[offset..][0..2], 0xff);
            offset += 2;
        } else {
            @memcpy(out[offset..][0..8], &self.peer);
            offset += 8;
        }
        @memcpy(out[offset..][0..8], &self.local);
        offset += 8;
        if (level != 0) offset += try (sec.Auxiliary{ .level = level, .counter = 0, .id = key_id }).encode(out[offset..]);
        @memcpy(out[offset..][0..6], &[_]u8{ 'M', 'Z', 'S', 'C', kind, stage });
        return offset + 6;
    }

    fn send(self: *Bench, kind: u8, stage: u8) void {
        var bytes: [125]u8 = undefined;
        const len = self.make_frame(&bytes, kind, stage, 0, 1, false, kind == 'H') catch return;
        _ = self.device.transmit(bytes[0..len], false) catch return;
    }

    fn message(self: *Bench, timeout: u32) ?struct { kind: u8, stage: u8, frame: ieee.Frame } {
        const frame = self.device.receive(timeout) catch |err| {
            if (err != error.Timeout) self.rx_diagnostic(self.diagnostic_stage, err);
            return null;
        };
        const h = hdr.parse(frame.bytes()) catch return null;
        const payload = frame.bytes()[h.payload_offset..];
        if (payload.len != 6 or !std.mem.eql(u8, payload[0..4], "MZSC")) return null;
        if (h.source.len != 8 or std.mem.eql(u8, h.source, &self.local)) return null;
        if (payload[4] != 'H' and !std.mem.eql(u8, h.source, &self.peer)) return null;
        return .{ .kind = payload[4], .stage = payload[5], .frame = frame };
    }

    fn discover(self: *Bench) bool {
        var found = false;
        var settle: u64 = self.deadline;
        while (now() < @min(self.deadline, settle)) {
            self.send('H', 0);
            // Different randomized listen lengths prevent identical firmware
            // from repeatedly transmitting together after simultaneous resets.
            if (self.message(100_000 + hal.rng.random_u32() % 100_000)) |m| {
                if (m.kind == 'H') {
                    const h = hdr.parse(m.frame.bytes()) catch continue;
                    self.peer = h.source[0..8].*;
                    if (!found) settle = now() + 1_500_000;
                    found = true;
                }
            }
            hal.rtos.sleep(.from_ms(1));
        }
        return found;
    }

    fn coordinator(self: *Bench, key: *sec.Key) void {
        for (checks, 0..) |_, index| {
            const stage: u8 = @intCast(index);
            self.diagnostic_stage = stage;
            const until = @min(self.deadline, now() + 2_500_000);
            var ready = false;
            while (now() < until and !ready) {
                self.send('C', stage);
                if (self.message(150_000)) |m| ready = m.kind == 'Y' and m.stage == stage;
            }
            if (!ready) {
                std.log.info("stage={d} handshake=timeout", .{stage});
                self.report(stage, false);
                continue;
            }
            var bytes: [125]u8 = undefined;
            const level: u3 = if (index < 7) @intCast(index + 1) else if (index >= 9) 5 else 0;
            var len = self.make_frame(&bytes, 'D', stage, level, if (index == 8) 1 else 2, index < 9, false) catch {
                self.report(stage, false);
                continue;
            };
            var wire = index >= 9;
            if (wire) {
                const h = hdr.parse(bytes[0..len]) catch {
                    self.report(stage, false);
                    continue;
                };
                var aux = h.auxiliary.?;
                aux.counter = key.reserve() catch {
                    self.report(stage, false);
                    continue;
                };
                _ = aux.encode(bytes[h.auxiliary_offset..]) catch {
                    self.report(stage, false);
                    continue;
                };
                sec.seal(key.value, sec.nonce(self.local, aux.counter, level), level, bytes[0..len], h.payload_offset, bytes[len..][0..4]) catch {
                    self.report(stage, false);
                    continue;
                };
                len += 4;
                if (index == 9) bytes[len - 1] ^= 1;
            }
            dump(stage, "TX-input", bytes[0..len]);
            var ack_ok = index >= 9;
            var delivered = false;
            var response_ok = false;
            while (now() < until and !delivered) {
                const tx = if (wire) self.device.transmit_wire(bytes[0..len], false) else self.device.transmit(bytes[0..len], false);
                // Save TX evidence before receive() resets RX/event diagnostics.
                const tx_events = self.device.last_events;
                const tx_abort = self.device.last_tx_abort;
                const ack_error = self.device.last_ack_error;
                const ack_wire = self.device.last_ack_wire;
                var tx_copy: [125]u8 = undefined;
                const tx_len: usize = self.device.tx_dma[0] - 2;
                @memcpy(tx_copy[0..tx_len], self.device.tx_dma[1..][0..tx_len]);
                if (tx) |result| {
                    if (index < 9 and result == .ack_received) {
                        if (self.device.last_ack) |a| {
                            const ah = hdr.parse(a.bytes()) catch continue;
                            ack_ok = if (index == 8) ah.version < 2 else ah.version == 2 and (ah.auxiliary != null) == (level != 0) and a.data[1] & 2 != 0;
                        }
                    }
                } else |err| std.log.info("stage={d} TX {s}", .{ stage, @errorName(err) });
                const wait_until = @min(until, now() + 200_000);
                while (now() < wait_until) {
                    if (self.message(20_000)) |m| {
                        if (m.stage != stage) continue;
                        if (m.kind == 'R' or m.kind == 'F') {
                            delivered = true;
                            response_ok = m.kind == 'R';
                            break;
                        }
                        // For replay the same exact secured MPDU is sent a
                        // second time, after the responder accepted the seed.
                        if (m.kind == 'Z' and index == 10) break;
                    }
                }
                std.log.info("stage={d} TX status={s} events=0x{x} abort={any} attempts={d} ACK_check={s}", .{ stage, if (tx) |r| @tagName(r) else |e| @errorName(e), tx_events, tx_abort, self.device.last_tx_attempts, if (ack_error) |e| @errorName(e) else if (ack_wire != null) "passed" else "not_checked" });
                dump(stage, if (level >= 5 and !wire) "TX-DMA-hardware" else "TX-wire", tx_copy[0..tx_len]);
                if (!wire) expected_tx(stage, bytes[0..len], tx_copy[0..tx_len]);
                if (ack_wire) |a| {
                    dump(stage, "ACK-wire", a.bytes());
                    const ah = hdr.parse(a.bytes()) catch continue;
                    std.log.info("stage={d} ACK MIC={s}", .{ stage, if (ack_error) |e| (if (e == error.AuthenticationFailed) "failed" else "not_checked") else if (ah.auxiliary) |aux| (if (sec.mic_len(aux.level) == 0) "absent" else "passed") else "absent" });
                }
                wire = index >= 9;
            }
            std.log.info("stage={d} delivered={} response_ok={} ack_ok={}", .{ stage, delivered, response_ok, ack_ok });
            self.report(stage, delivered and response_ok and ack_ok);
        }
        // Final receipt lets the responder finish immediately; repeated in
        // case it was transmitting its last result on the first attempt.
        const end = @min(self.deadline, now() + 500_000);
        while (now() < end) {
            self.send('E', 0);
            _ = self.message(25_000);
        }
    }

    fn responder(self: *Bench) void {
        var stage: ?u8 = null;
        var timeout_reported = false;
        var seeded = false;
        var result: ?bool = null;
        var reported: [checks.len]bool = @splat(false);
        while (now() < self.deadline) {
            const frame = self.device.receive(100_000) catch |err| {
                if (stage) |s| {
                    if (err != error.Timeout or (!timeout_reported and result == null)) self.rx_diagnostic(s, err);
                    if (err == error.Timeout) timeout_reported = true;
                }
                if (stage) |s| {
                    if (result == null and ((s == 9 and err == error.AuthenticationFailed) or (s == 10 and seeded and err == error.Replay))) result = true;
                }
                if (result) |ok| {
                    const s = stage.?;
                    if (!reported[s]) {
                        self.report(s, ok);
                        reported[s] = true;
                    }
                    self.send(if (ok) 'R' else 'F', s);
                }
                continue;
            };
            const h = hdr.parse(frame.bytes()) catch continue;
            const payload = frame.bytes()[h.payload_offset..];
            if (h.source.len != 8 or !std.mem.eql(u8, h.source, &self.peer) or payload.len != 6 or !std.mem.eql(u8, payload[0..4], "MZSC")) continue;
            const kind = payload[4];
            const s = payload[5];
            if (kind == 'E') break;
            if (s >= checks.len) continue;
            if (kind == 'C') {
                if (stage == null or stage.? != s) {
                    stage = s;
                    self.diagnostic_stage = s;
                    timeout_reported = false;
                    seeded = false;
                    result = null;
                }
                self.send('Y', s);
            } else if (kind == 'D' and stage == s) {
                self.rx_diagnostic(s, null);
                dump(s, "RX-plaintext", frame.bytes());
                if (s == 10 and !seeded) {
                    seeded = true;
                    self.send('Z', s);
                    continue;
                }
                if (result == null) {
                    const expected: u3 = if (s < 7) @intCast(s + 1) else 0;
                    const ack_sent = frame.ack_transmitted and (s == 8 or (if (self.device.last_ack_tx) |trace| trace.transmitted() else false));
                    result = s < 9 and ack_sent and h.version == (if (s == 8) @as(u2, 1) else @as(u2, 2)) and (if (h.auxiliary) |a| a.level == expected else expected == 0);
                }
            }
            if (result) |ok| {
                if (!reported[s]) {
                    self.report(s, ok);
                    reported[s] = true;
                }
                self.send(if (ok) 'R' else 'F', s);
            }
            hal.rtos.sleep(.from_ms(1));
        }
        for (reported, 0..) |done, i| if (!done) self.report(@intCast(i), false);
    }
};

pub fn main() void {
    // Board-independent image: these are the XIAO RF-switch pads; unused
    // pads on the unconnected Super Mini. Matches boards/xiao_esp32_c6.zig.
    hal.gpio.num(3).apply(.{ .output_enable = true });
    hal.gpio.num(3).put(0);
    hal.gpio.num(14).apply(.{ .output_enable = true });
    hal.gpio.num(14).put(0);
    const mac = hal.efuse.read_mac();
    var bench: Bench = .{ .local = .{ mac[5], mac[4], mac[3], 0xfe, 0xff, mac[2], mac[1], mac[0] }, .deadline = now() + 45_000_000 };
    var keys = [_]sec.Key{.{ .id = key_id, .value = test_key }};
    var replay: [4]sec.Replay = @splat(.{});
    // The level4 check exercises encryption-only delivery and ACKs, which a
    // context rejects unless it opts in.
    var context: sec.Context = .{ .keys = &keys, .replay = &replay, .accept_unauthenticated = true };
    var heap = microzig.Allocator.init_with_heap(16384) catch |err| {
        fatal(err);
    };
    bench.device.init(heap.allocator(), .{ .channel = 25, .pan_id = pan, .short_address = 0xfffe, .extended_address = bench.local, .tx_power = 10, .security = &context, .enhanced_ack = true, .ack_diagnostics = true, .ack_header_ies = &ack_ies, .tx = .{ .max_frame_retries = 0 } }) catch |err| {
        fatal(err);
    };
    // Discovery has a separate 14s deadline, permitting boots ten seconds apart.
    const finish = bench.deadline;
    bench.deadline = now() + 14_000_000;
    const found = bench.discover();
    bench.deadline = finish;
    if (found) {
        const lower = std.mem.readInt(u64, &bench.local, .little) < std.mem.readInt(u64, &bench.peer, .little);
        std.log.info("ROLE {s} local={x} peer={x}", .{ if (lower) "coordinator" else "responder", bench.local, bench.peer });
        if (lower) bench.coordinator(&keys[0]) else bench.responder();
    } else for (checks, 0..) |_, i| bench.report(@intCast(i), false);
    bench.device.deinit();
    std.log.info("SELFTEST ieee802154_sec DONE pass={d} fail={d}", .{ bench.pass, bench.fail });
    while (true) hal.rtos.sleep(.from_ms(1000));
}

fn fatal(err: anyerror) noreturn {
    std.log.err("SELFTEST ieee802154_sec init: FAIL {s}", .{@errorName(err)});
    std.log.info("SELFTEST ieee802154_sec DONE pass=0 fail=1", .{});
    while (true) hal.rtos.sleep(.from_ms(1000));
}
fn now() u64 {
    return hal.time.get_time_since_boot().to_us();
}
