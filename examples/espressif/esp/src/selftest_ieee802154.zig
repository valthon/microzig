//! Flash the C6 image-boot target, or the XIAO ESP32-C6 board target
//! on a XIAO ESP32-C6.
//! Channel 25, PAN 0x1234. The short address is (factory_mac[4] << 8) | mac[5];
//! 0x0001 (H2/test peer), 0x0003 (nRF default), 0xfffe and 0xffff are remapped
//! by XOR with 0x8000. The extended address inserts ff:fe between factory MAC
//! bytes 2 and 3, then reverses all eight bytes for the HAL's wire order.
//! ADDRESS prints short=0xHHHH and extended_wire=<eight hex octets> at boot.
//! Before testing two C6s, the host must verify their printed shorts differ:
//! truncating a MAC to 16 bits cannot guarantee uniqueness. If equal, do not
//! run them together. Replace the old fixed C6 destination 0x0002 in peer MPDUs
//! with the printed short, low byte first (bytes 5/6 of a compressed short frame).
//! Configure the peer to transmit that MPDU with its own FCS. Match channel/PAN,
//! and enable filtered RX with auto-ACK on exactly one peer at short 0x0001
//! before resetting the C6.
//! For nRF, override its default 0x0003 with `wpan filter 0x1234 0x0001` and
//! `wpan promisc off`, `wpan rx on`; disable H2 RX when nRF is the ACK peer.
//! The C6 listens promiscuously for five seconds, sends four peer-test frames,
//! then listens with filtering/auto-ACK. Send peer ACK requests after that set.
//! PASS requires init, energy-detect completion, broadcast TX_DONE, and both
//! ACK-request frames (seq 0x21 and 0x22) ACK_RECEIVED: 2/2, using the HAL's
//! default ACK retries and unslotted CSMA-CA for both frames.
//! Final NO_ACK, CCA_BUSY or TX error on either fails peer_ack.
//! DONE is emitted only after the outgoing set (or a fatal setup failure),
//! with four cases: success is pass=4 fail=0. No peer therefore fails peer_ack.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const ieee = hal.radio.ieee802154;
const antenna = @import("antenna_options").antenna;

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
        .interrupt30 = hal.radio.interrupt_handler,
        .interrupt31 = hal.rtos.interrupt_handler,
    },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{
        .rtos = .{ .enable = true },
        .radio = .{ .radios = .{ .wifi = false, .ieee802154 = true } },
    },
};
comptime {
    _ = microzig.export_startup();
}

const CHANNEL = 25;
const PAN_ID: u16 = 0x1234;
const PEER_SHORT: u16 = 0x0001;
// Match the ESP32-H2 peer, which transmits at +20 dBm (its console `txpower -g`).
// At 0 dBm the C6's auto-ACKs reach the peer about 20 dB below its frames and
// near its receive floor, so the peer counts ACKs as missing that the C6 sent.
const TX_POWER_DBM = 20;
const LISTEN_SECONDS = 5;

const Results = struct {
    local_short: u16,
    peer_checks_complete: bool = false,
    init_error: ?anyerror = null,
    energy: ieee.Error!ieee.Energy = error.NotInitialized,
    tx: ieee.Error!ieee.TxResult = error.NotInitialized,
    received: u32 = 0,
    crc_errors: u32 = 0,
    rx_errors: u32 = 0,
    peer_ack: u32 = 0,
    peer_no_ack: u32 = 0,
    peer_busy: u32 = 0,
    peer_errors: u32 = 0,
    next_report: u64,

    fn report(self: *Results) void {
        const current = now();
        if (current < self.next_report) return;
        self.next_report = current + 3_000_000;
        var pass: u8 = 0;
        if (self.init_error) |err| {
            std.log.err("SELFTEST ieee802154 init: FAIL {s}", .{@errorName(err)});
        } else {
            pass += 1;
            std.log.info("SELFTEST ieee802154 init: PASS channel={d} pan=0x{x} short=0x{x:0>4}", .{ CHANNEL, PAN_ID, self.local_short });
        }
        if (self.energy) |energy| {
            pass += 1;
            std.log.info("SELFTEST ieee802154 energy_detect: PASS rssi={d} busy={}", .{ energy.rssi, energy.busy });
        } else |err| std.log.err("SELFTEST ieee802154 energy_detect: FAIL {s}", .{@errorName(err)});
        if (self.tx) |result| {
            const ok = result == .tx_done;
            if (ok) pass += 1;
            std.log.info("SELFTEST ieee802154 tx_without_ack: {s} result={s}", .{ if (ok) "PASS" else "FAIL", tx_name(result) });
        } else |err| std.log.err("SELFTEST ieee802154 tx_without_ack: FAIL {s}", .{@errorName(err)});
        if (self.peer_checks_complete) {
            const ok = self.peer_ack == 2;
            if (ok) pass += 1;
            std.log.info("SELFTEST ieee802154 peer_ack: {s} ack={d}/2 required=2/2", .{ if (ok) "PASS" else "FAIL", self.peer_ack });
            std.log.info("SELFTEST ieee802154 DONE pass={d} fail={d}", .{ pass, 4 - pass });
        }
        std.log.info("PEERS rx={d} crc_errors={d} rx_errors={d} ack={d} no_ack={d} cca_busy={d} tx_errors={d}", .{
            self.received, self.crc_errors, self.rx_errors, self.peer_ack, self.peer_no_ack, self.peer_busy, self.peer_errors,
        });
    }
};

pub fn main() void {
    // A board with an rf switch in front of the antenna (the XIAO ESP32C6) leaves it
    // unpowered at reset. On the bench that cost about 20 dB.
    if (microzig.config.has_board) {
        if (@hasDecl(microzig.board, "antenna"))
            microzig.board.antenna.apply(@field(microzig.board.antenna.Selection, @tagName(antenna)));
    }
    const mac = hal.efuse.read_mac();
    const local_short = short_address(mac);
    const extended_wire: [8]u8 = .{ mac[5], mac[4], mac[3], 0xfe, 0xff, mac[2], mac[1], mac[0] };
    std.log.info("ADDRESS channel={d} pan=0x{x:0>4} short=0x{x:0>4} extended_wire={x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        CHANNEL,          PAN_ID,           local_short,
        extended_wire[0], extended_wire[1], extended_wire[2],
        extended_wire[3], extended_wire[4], extended_wire[5],
        extended_wire[6], extended_wire[7],
    });
    var results: Results = .{ .local_short = local_short, .next_report = now() + 1_500_000 };
    var heap = microzig.Allocator.init_with_heap(16384) catch |err| {
        results.init_error = err;
        report_forever(&results);
    };
    var device: ieee.Radio = .{};
    var config: ieee.Config = .{
        .channel = CHANNEL,
        .pan_id = PAN_ID,
        .short_address = local_short,
        .extended_address = extended_wire,
        .tx_power = TX_POWER_DBM,
        .promiscuous = true,
    };
    device.init(heap.allocator(), config) catch |err| {
        results.init_error = err;
        report_forever(&results);
    };
    // Radio-only checks: no loopback, peer, ACK or quiet channel required.
    results.energy = device.energy_detect(128);
    const probe = data_frame(local_short, 0x10, false, 0xffff);
    results.tx = device.transmit(&probe, false);

    // Begin sniffing immediately after the short radio-only checks. Report
    // within the loop so the host sees radio-only cases while listening.
    const listen_until = now() + LISTEN_SECONDS * 1_000_000;
    while (now() < listen_until) {
        listen(&device, &results);
        results.report();
    }

    // Leave promiscuous mode to exercise address filtering and legacy auto-ACK
    // for incoming peer frames after our fixed outgoing set.
    config.promiscuous = false;
    device.configure(config) catch |err| {
        results.rx_errors += 1;
        std.log.err("RX configure failed: {s}", .{@errorName(err)});
        device.deinit();
        report_forever(&results);
    };
    const cases = [_]struct { seq: u8, ack: bool, dest: u16, cca: bool }{
        .{ .seq = 0x20, .ack = false, .dest = PEER_SHORT, .cca = false },
        .{ .seq = 0x21, .ack = true, .dest = PEER_SHORT, .cca = true },
        .{ .seq = 0x22, .ack = true, .dest = PEER_SHORT, .cca = true },
        .{ .seq = 0x23, .ack = false, .dest = 0xffff, .cca = true },
    };
    for (cases) |case| {
        const frame = data_frame(local_short, case.seq, case.ack, case.dest);
        const result = device.transmit(&frame, case.cca);
        if (result) |value| {
            switch (value) {
                .ack_received => if (case.ack) {
                    results.peer_ack += 1;
                },
                .no_ack => results.peer_no_ack += 1,
                .cca_busy => results.peer_busy += 1,
                .tx_done => {},
            }
            std.log.info("TX seq={d} ack_request={} cca={} {s} attempts={d}", .{ case.seq, case.ack, case.cca, tx_name(value), device.last_tx_attempts });
        } else |err| {
            results.peer_errors += 1;
            std.log.err("TX seq={d} FAIL {s}", .{ case.seq, @errorName(err) });
        }
        hal.rtos.sleep(.from_ms(100));
        results.report();
    }
    results.peer_checks_complete = true;
    results.next_report = 0;
    results.report();
    while (true) {
        listen(&device, &results);
        results.report();
    }
}

fn listen(device: *ieee.Radio, results: *Results) void {
    // Let the shared PHY tracking timer task run while the MAC is idle.
    defer hal.rtos.sleep(.from_ms(1));
    // The MAC listens only inside receive(), and every call ends with a stop.
    // A long window keeps that gap rare: with 10 ms windows the C6 missed
    // about 1 frame in 20 from an H2 sending every 0.6 s.
    const frame = device.receive(500_000) catch |err| {
        switch (err) {
            error.Timeout => {},
            error.Crc => results.crc_errors += 1,
            else => {
                results.rx_errors += 1;
                // Bound error output if a hardware fault persists.
                if (results.rx_errors == 1) std.log.err("RX FAIL {s}", .{@errorName(err)});
                hal.rtos.sleep(.from_ms(10));
            },
        }
        return;
    };
    results.received += 1;
    var hex: [250]u8 = undefined;
    const digits = "0123456789abcdef";
    for (frame.bytes(), 0..) |byte, i| {
        hex[2 * i] = digits[byte >> 4];
        hex[2 * i + 1] = digits[byte & 15];
    }
    std.log.info("FRAME len={d} lqi={d} rssi={d} {s}", .{ frame.len, frame.lqi, frame.rssi, hex[0 .. 2 * @as(usize, frame.len)] });
}

fn short_address(mac: [6]u8) u16 {
    const candidate = (@as(u16, mac[4]) << 8) | mac[5];
    return switch (candidate) {
        PEER_SHORT, 0x0003, 0xfffe, 0xffff => candidate ^ 0x8000,
        else => candidate,
    };
}

fn data_frame(source: u16, seq: u8, ack: bool, dest: u16) [13]u8 {
    // Legacy data, PAN compression, short destination and source; no FCS.
    return .{
        if (ack) 0x61 else 0x41, 0x88,              seq,
        @truncate(PAN_ID),       PAN_ID >> 8,       @truncate(dest),
        @intCast(dest >> 8),     @truncate(source), @intCast(source >> 8),
        'M',                     'Z',               '1',
        '5',
    };
}

fn tx_name(result: ieee.TxResult) []const u8 {
    return switch (result) {
        .tx_done => "TX_DONE",
        .ack_received => "ACK_RECEIVED",
        .no_ack => "NO_ACK",
        .cca_busy => "CCA_BUSY",
    };
}

fn report_forever(results: *Results) noreturn {
    results.peer_checks_complete = true;
    while (true) {
        results.report();
        hal.rtos.sleep(.from_ms(100));
    }
}

fn now() u64 {
    return hal.time.get_time_since_boot().to_us();
}
