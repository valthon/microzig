//! Ran on a XIAO ESP32-C6 against an H2 peer (see the port README). Flash the C6
//! image-boot target, or the XIAO board target on a XIAO. No wiring or peer is needed
//! for the three SELFTEST cases; the later transmissions exercise peers.
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
        .radio = .{ .protocol = .ieee802154 },
    },
};
comptime {
    _ = microzig.export_startup();
}

// NOTE: Bench configuration. H2 IDF ieee802154_cli: channel 25, PAN 0x1234,
// short address 0x0001. Configure the nRF52840 Zephyr raw shell to match the
// channel/PAN; use a distinct local address. Extended address is in wire order.
const CHANNEL = 25;
const PAN_ID: u16 = 0x1234;
const LOCAL_SHORT: u16 = 0x0002;
const PEER_SHORT: u16 = 0x0001;
const EXTENDED_ADDRESS: [8]u8 = .{ 2, 0, 0, 0, 0, 0, 0, 2 };
const TX_POWER_DBM = 0;
const LISTEN_SECONDS = 5;

const Results = struct {
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
            std.log.info("SELFTEST ieee802154 init: PASS channel={d} pan=0x{x} short=0x{x}", .{ CHANNEL, PAN_ID, LOCAL_SHORT });
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
        std.log.info("SELFTEST ieee802154 DONE pass={d} fail={d}", .{ pass, 3 - pass });
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
    var results: Results = .{ .next_report = now() + 1_500_000 };
    var heap = microzig.Allocator.init_with_heap(16384) catch |err| {
        results.init_error = err;
        report_forever(&results);
    };
    var device: ieee.Radio = .{};
    var config: ieee.Config = .{
        .channel = CHANNEL,
        .pan_id = PAN_ID,
        .short_address = LOCAL_SHORT,
        .extended_address = EXTENDED_ADDRESS,
        .tx_power = TX_POWER_DBM,
        .promiscuous = true,
    };
    device.init(heap.allocator(), config) catch |err| {
        results.init_error = err;
        report_forever(&results);
    };
    // Radio-only checks: no loopback, peer, ACK or quiet channel required.
    results.energy = device.energy_detect(128);
    const probe = data_frame(0x10, false, 0xffff);
    results.tx = device.transmit(&probe, false);

    // Begin sniffing immediately after the short radio-only checks. Report
    // within the loop so the host sees a summary after 1.5 s even while listening.
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
        .{ .seq = 0x21, .ack = true, .dest = PEER_SHORT, .cca = false },
        .{ .seq = 0x22, .ack = true, .dest = PEER_SHORT, .cca = true },
        .{ .seq = 0x23, .ack = false, .dest = 0xffff, .cca = true },
    };
    for (cases) |case| {
        const frame = data_frame(case.seq, case.ack, case.dest);
        const result = device.transmit(&frame, case.cca);
        if (result) |value| {
            switch (value) {
                .ack_received => results.peer_ack += 1,
                .no_ack => results.peer_no_ack += 1,
                .cca_busy => results.peer_busy += 1,
                .tx_done => {},
            }
            std.log.info("TX seq={d} ack_request={} cca={} {s}", .{ case.seq, case.ack, case.cca, tx_name(value) });
        } else |err| {
            results.peer_errors += 1;
            std.log.err("TX seq={d} FAIL {s}", .{ case.seq, @errorName(err) });
        }
        hal.rtos.sleep(.from_ms(100));
        results.report();
    }
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

fn data_frame(seq: u8, ack: bool, dest: u16) [13]u8 {
    // Legacy data, PAN compression, short destination and source; no FCS.
    return .{
        if (ack) 0x61 else 0x41, 0x88,                   seq,
        @truncate(PAN_ID),       PAN_ID >> 8,            @truncate(dest),
        @intCast(dest >> 8),     @truncate(LOCAL_SHORT), LOCAL_SHORT >> 8,
        'M',                     'Z',                    '1',
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
    while (true) {
        results.report();
        hal.rtos.sleep(.from_ms(100));
    }
}

fn now() u64 {
    return hal.time.get_time_since_boot().to_us();
}
