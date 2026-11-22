//! I2S master against a Pico 2 W PIO slave.
//! Wire ESP C6 GPIO0/1/2/3 to Pico GP8/9/10/11 respectively;
//! for ESP C3, GPIO0/1/3/10 to Pico GP0/1/2/3. Connect common GND.
//! Load pico2_w_ram_esp_peer, send `mode i2s c3` or `mode i2s c6` on
//! Pico USB CDC, start the ESP test, then request `status` after DONE.
//! PASS requires SELFTEST i2s DONE pass=8 fail=0 (echo equality, EOF
//! count and intact guards), PEER i2s clk: PASS (1 MHz within 1%),
//! and no peer FAIL verdicts.
//! L2=BCK, L3=WS, L1=DOUT, L0=DIN: C6 GPIO2/3/1/0; C3 GPIO3/10/1/0.
//! Philips stereo, PLL160M / 20 / 8 = 1 MHz BCK. Select peer mode i2s and
//! the matching bank before loading. The peer echoes the previous transfer's
//! sample bits, starting one BCK after its first WS fall; A primes it, B checks A.
//!
//! Timing evidence: ESP32-C3 TRM v1.4 §29.5–29.5.1, Fig. 29.5-1 (p.734),
//! registers 29.6/29.13 RX/TX_MSB_SHIFT; ESP32-C6 TRM v1.2 §30.5–30.5.1,
//! Fig. 30.5-1 (p.976), registers 30.6/30.13 RX/TX_MSB_SHIFT. Both fields at
//! 1 put WS one BCK ahead of the MSB, transmitted first. With rising edges
//! numbered from zero after WS falls, edge 0 precedes the sample and edge 1
//! carries its MSB in both TX and RX; its LSB is at edge sample_bits.
//! Thus sample bit 0 (whether first serial bit or numeric LSB) has the same
//! WS-relative position in TX and RX, so the peer replays each bit at the
//! edge it captured it on. It skips edge 0, the delay bit, so the last
//! sample's LSB (on the edge after the final frame) ends a captured word.
//! ESP-IDF v5.5.1 components/hal/esp32c6/include/hal/i2s_ll.h:560–580
//! documents the symmetric shift helpers and writes tx_msb_shift (568) and
//! rx_msb_shift (579). The HAL enables both, including RX-only master mode.
//! Sources: https://www.espressif.com/sites/default/files/documentation/esp32-c3_technical_reference_manual_en.pdf
//! https://www.espressif.com/sites/default/files/documentation/esp32-c6_technical_reference_manual_en.pdf
//!
//! Each transfer releases all four pads, pulling BCK/WS low, and leaves 110 ms
//! idle for peer decode/rearm (minimum 100 ms, plus completion margin).
//! I2S replay uses the next ESP-clocked transfer, rather
//! than the autonomous reply window used by RMT/PARL_IO. No data-pad sharing.
//! The eof_num case also checks echoed data, so absent peers cannot pass just
//! because RX EOF counts locally generated clocks. Missing/corrupt data gives
//! error=DataMismatch; peripheral/DMA waits have a 100 ms deadline.
//! Run once; after 1.5 s repeat the eight verdicts and DONE every second.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const i2s = hal.i2s;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .logFn = hal.usb_serial_jtag.logger.log, .log_level = .info });
comptime {
    _ = microzig.export_startup();
}

const c6 = std.mem.eql(u8, microzig.config.chip_name, "ESP32-C6");
const bck = hal.gpio.num(if (c6) 2 else 3);
const ws = hal.gpio.num(if (c6) 3 else 10);
const dout = hal.gpio.num(1);
const din = hal.gpio.num(0);
const widths = [_]i2s.SampleBits{ .bits16, .bits32 };
const lengths = [_]usize{ 64, 512, 2048 };
const Error = i2s.Error || error{ UnexpectedLength, GuardCorrupted, DataMismatch };

var tx_a: [2048]u8 align(4) = undefined;
var tx_b: [2048]u8 align(4) = undefined;
// Keep guards even for the largest transfer.
var rx: [2064]u8 align(4) = undefined;
var output: [1]hal.gdma.Descriptor = undefined;
var input: [1]hal.gdma.Descriptor = undefined;

fn config(bits: i2s.SampleBits) i2s.Config {
    return .{ .bits = bits, .bck = bck, .ws = ws, .tx_data = dout, .rx_data = din };
}

fn release_pins() void {
    // The peer has no pulls on these inputs; keep its frame delimiter quiet.
    for ([_]hal.gpio.Pin{ bck, ws }) |pin| pin.apply(.{ .pull = .down });
    for ([_]hal.gpio.Pin{ dout, din }) |pin| pin.apply(.{});
}

fn fill(data: []u8, seed: u32) void {
    var state = seed;
    for (data) |*byte| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = @truncate(state);
    }
}

fn transfer(cfg: i2s.Config, data: ?[]const u8, capacity: ?usize) Error!usize {
    @memset(&rx, 0xa5);
    defer {
        release_pins();
        hal.time.sleep_ms(110);
    }
    const actual = try i2s.Port(2).transfer(cfg, .{
        .tx = data,
        .rx = if (capacity) |len| rx[0..len] else null,
        .tx_descriptors = if (data != null) &output else &.{},
        .rx_descriptors = if (capacity != null) &input else &.{},
    }, 100_000);
    const expected = if (capacity) |len| cfg.rx_eof_num orelse len else 0;
    // For the diagnostic override, check immediately after actual EOF, not
    // just after the advertised capacity: RX_STOP_MODE must stop at EOF.
    if (actual > (capacity orelse 0)) return error.UnexpectedLength;
    if (!std.mem.allEqual(u8, rx[actual..], 0xa5)) return error.GuardCorrupted;
    if (actual != expected) return error.UnexpectedLength;
    return actual;
}

fn check_echo(length: usize) Error!void {
    if (!std.mem.eql(u8, tx_a[0..length], rx[0..length])) return error.DataMismatch;
}

fn eof_probe() Error!usize {
    fill(&tx_a, 0x30d5317);
    fill(&tx_b, 0xc6e0f031);
    _ = try transfer(config(.bits32), tx_a[0..1024], 1024);
    // Keep the first EOF inside capacity under either interpretation:
    // IDF: 64 bytes. TRM: (RX_BITS_MOD+1)*(EOF_NUM+1)/8 = 32*65/8 = 260.
    // RX_STOP_MODE=1 stops reception at that EOF while TX continues to 1024.
    var probe = config(.bits32);
    probe.rx_eof_num = 64;
    const actual = try transfer(probe, tx_b[0..1024], 512);
    try check_echo(64);
    return actual;
}

fn round_trip(bits: i2s.SampleBits, length: usize) Error!usize {
    const seed = 0x30d5317 ^ @as(u32, @intCast(length)) ^ @as(u32, @backingInt(bits));
    fill(&tx_a, seed);
    fill(&tx_b, seed ^ 0xa55a1234);
    _ = try transfer(config(bits), tx_a[0..length], length);
    const actual = try transfer(config(bits), tx_b[0..length], length);
    try check_echo(length);
    return actual;
}

fn directions() Error!usize {
    fill(&tx_a, 0xd1ec7105);
    var cfg = config(.bits32);
    cfg.rx_data = null;
    _ = try transfer(cfg, &tx_a, null);
    cfg = config(.bits32);
    cfg.tx_data = null;
    const actual = try transfer(cfg, null, tx_a.len);
    try check_echo(tx_a.len);
    return actual;
}

fn report(name: []const u8, result: Error!usize) void {
    if (result) |actual| {
        std.log.info("SELFTEST i2s {s}: PASS actual={d}", .{ name, actual });
    } else |err| {
        std.log.err("SELFTEST i2s {s}: FAIL error={s}", .{ name, @errorName(err) });
    }
}

pub fn main() void {
    hal.gdma.init();
    release_pins();
    const eof = eof_probe();
    var results: [widths.len][lengths.len]Error!usize = undefined;
    for (widths, &results) |bits, *row| {
        for (lengths, row) |length, *result| result.* = round_trip(bits, length);
    }
    const direction = directions();
    var pass: usize = 0;
    if (eof) |_| {
        pass += 1;
    } else |_| {}
    for (results) |row| {
        for (row) |result| {
            if (result) |_| {
                pass += 1;
            } else |_| {}
        }
    }
    if (direction) |_| {
        pass += 1;
    } else |_| {}
    hal.time.sleep_ms(1500);
    while (true) {
        std.log.info("SELFTEST i2s info peer=pico bank={s} bck=1000000 tx_rx_offset_bck=0", .{if (c6) "c6" else "c3"});
        std.log.info("SELFTEST i2s info eof_num raw=64 bits=32 idf_bytes=64 trm_bytes=260 rx_capacity=512", .{});
        report("eof_num", eof);
        inline for (widths, 0..) |bits, i| {
            inline for (lengths, 0..) |length, j| {
                report(std.fmt.comptimePrint("{s}_{d}", .{ @tagName(bits), length }), results[i][j]);
            }
        }
        report("directions", direction);
        std.log.info("SELFTEST i2s DONE pass={d} fail={d}", .{ pass, 8 - pass });
        hal.time.sleep_ms(1000);
    }
}
