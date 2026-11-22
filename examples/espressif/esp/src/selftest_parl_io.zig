//! Parallel capture/replay between a Super Mini C6 and Pico 2 W.
//! Wire ESP GPIO0–7 to Pico GP8–15, GPIO18 to GP16, GPIO19 to GP17,
//! and GND to GND. Load pico2_w_ram_esp_peer and send `mode parl c6`
//! over Pico USB CDC before starting; request `status` after ESP DONE.
//! GPIO0–7 = data0–7, GPIO18 = clock, GPIO19 = valid, with common ground.
//! ESP32-C6 TRM v1.2 §38.5.3 and §38.8 Registers 38.3/38.1:
//! TX changes data on the rising edge (TX_SMP_EDGE_SEL=0, no inversion);
//! RX samples on the falling edge (RX_CLK_EDGE_SEL=1, inverted input clock).
//! The peer captures falling edges, then replays at 1 MHz with rising-edge
//! data changes. It discards setup bursts shorter than 16 edges, detects 1 ms
//! clock idle, and replies after 20 ms. Release all ten pads immediately after
//! TX, arm external-clock RX, and leave a 100 ms quiet interval after each case
//! for the peer to finish and release its pads, including after a failed case.
//! Pull CLK low while released: the peer's capture input has no clock pull.
//! PASS requires SELFTEST parl_io DONE pass=16 fail=0: echoed data and
//! intact guards at widths 1/2/4/8, valid/software gating, 64/4096 bytes.
//! Also require PEER parl clk: PASS (1 MHz within 1%), no peer FAIL verdicts.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const parl = hal.parl_io;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{ .logFn = hal.usb_serial_jtag.logger.log, .log_level = .info });
comptime {
    _ = microzig.export_startup();
}
var tx: [4096]u8 align(4) = undefined;
// Four-byte leading guard preserves DMA alignment; trailing guard also covers
// the maximum-length frame, unlike checking only unused buffer capacity.
var rx: [4 + 4096 + 4]u8 align(4) = undefined;
var output: [2]hal.gdma.Descriptor = undefined;
var input: [2]hal.gdma.Descriptor = undefined;
const pads = [_]hal.gpio.Pin{ hal.gpio.num(0), hal.gpio.num(1), hal.gpio.num(2), hal.gpio.num(3), hal.gpio.num(4), hal.gpio.num(5), hal.gpio.num(6), hal.gpio.num(7) };
const clock = hal.gpio.num(18);
const valid = hal.gpio.num(19);

fn release_pads() void {
    for (pads) |pin| pin.apply(.{});
    clock.apply(.{ .pull = .down });
    valid.apply(.{});
}

fn run_case(width: parl.Width, with_valid: bool, length: usize) (parl.Error || error{ Mismatch, GuardCorrupted })!void {
    const count: usize = @as(usize, 16) >> @backingInt(width);
    @memset(&rx, 0xa5);
    const sent = parl.Port(1).transfer(.{
        .width = width,
        .tx_data = pads[0..count],
        .tx_clock = clock,
        .tx_valid = if (with_valid) valid else null,
    }, .{ .tx = tx[0..length], .tx_descriptors = &output }, 200000);
    // Do this before inspecting the result, arming RX, logging, or waiting.
    // TX-only transfer leaves output routing in place even on an error.
    release_pads();
    // At 1 MHz even the longest replay is only 32.768 ms. This also covers
    // the 1 ms frame delimiter and 20 ms reply delay if RX fails to arm.
    defer {
        // RX routing removes the clock pull; restore quiet idle on every exit.
        release_pads();
        hal.time.sleep_ms(100);
    }
    try sent;
    const received = rx[4..][0..length];
    try parl.Port(1).transfer(.{
        .width = width,
        .rx_data = pads[0..count],
        .rx_clock = clock,
        .rx_valid = if (with_valid) valid else null,
    }, .{ .rx = received, .rx_descriptors = &input }, 200000);
    for (rx[0..4]) |byte| {
        if (byte != 0xa5) return error.GuardCorrupted;
    }
    for (rx[4 + length ..]) |byte| {
        if (byte != 0xa5) return error.GuardCorrupted;
    }
    if (!std.mem.eql(u8, tx[0..length], received)) return error.Mismatch;
}

pub fn main() void {
    release_pads();
    var state: u32 = 0x38d5317;
    for (&tx) |*byte| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = @truncate(state);
    }
    hal.gdma.init();
    var pass: usize = 0;
    var fail: usize = 0;
    const widths = [_]parl.Width{ .bits1, .bits2, .bits4, .bits8 };
    const lengths = [_]usize{ 64, 4096 };
    // Per case: null passed, otherwise the transfer error or "Mismatch".
    var results: [widths.len][2][lengths.len]?[]const u8 = undefined;
    for (widths, 0..) |width, w| {
        for ([_]bool{ true, false }, 0..) |with_valid, m| {
            for (lengths, 0..) |length, l| {
                run_case(width, with_valid, length) catch |err| {
                    results[w][m][l] = @errorName(err);
                    fail += 1;
                    continue;
                };
                results[w][m][l] = null;
                pass += 1;
            }
        }
    }
    release_pads();
    // Lines logged in the first moments after the RAM load are lost before the
    // host reopens the port; report once it is back, and repeat.
    hal.time.sleep_ms(1500);
    while (true) {
        for (widths, results) |width, modes| {
            for ([_][]const u8{ "valid", "software" }, modes) |mode, row| {
                for (lengths, row) |length, result| {
                    if (result) |reason| {
                        std.log.err("SELFTEST parl_io {s}_{s}_{d}: FAIL error={s}", .{ @tagName(width), mode, length, reason });
                    } else std.log.info("SELFTEST parl_io {s}_{s}_{d}: PASS", .{ @tagName(width), mode, length });
                }
            }
        }
        std.log.info("SELFTEST parl_io DONE pass={d} fail={d}", .{ pass, fail });
        hal.time.sleep_ms(1000);
    }
}
