//! Flash the SAME esp32_c6_selftest_ble_smp image on both boards, with a valid
//! named "nvs" partition. No wiring. Reserves GPIO3/14 for XIAO's RF switch.
//! Start both boards within 3 s. USB capture must follow the software reset.
//! With -Dsmp_method other than just_works an operator (or
//! tools/bench/ble_smp_user.py) answers each board's `io` prompt on its
//! USB Serial/JTAG console.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const ble = hal.radio.bluetooth;
const Host = ble.host.Host;
const smp = ble.host.smp;
const Store = hal.nvs_flash.Store;
const Value = ble.host.gatt.value_handle;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .log_level = .info,
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_scope_levels = &.{ .{ .scope = .esp_radio_osi, .level = .err }, .{ .scope = .esp_radio_timer, .level = .err } },
});
pub const microzig_options: microzig.Options = .{
    .interrupts = .{ .interrupt29 = ble.interrupt_handler, .interrupt30 = hal.radio.interrupt_handler, .interrupt31 = hal.rtos.interrupt_handler },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{ .rtos = .{ .enable = true, .priority_bits = 5, .preempt_same_priority_tasks_on_tick = true }, .radio = .{ .radios = .{ .wifi = false, .ble = true } } },
};
const clock_config: hal.clocks.Config = .init_comptime(160_000_000);
pub fn init() void {
    hal.init_sequence(clock_config);
}
comptime {
    _ = microzig.export_startup();
}
const suite_name = "MZ-SMP-TEST";
const ready_name = "MZ-SMP-READY";
const options = @import("smp_options");
const role: connection_policy.Role = @field(connection_policy.Role, @tagName(options.role));
const method: connection_policy.Method = @field(connection_policy.Method, @tagName(options.method));
const authenticated = method != .just_works;
const paired_step = @tagName(method) ++ "_encrypted";
var boot_nonce: [4]u8 = undefined;
var identity: ?connection_policy.Identity = null;
var selecting_ready = false;
const connection_policy = @import("selftest_ble_smp_connection.zig");
var connection_attempt: u8 = 0;
var controller: ble.Controller = .{};
var host: Host = undefined;
var storage: Store = undefined;
var adapter: smp.bonds.Nvs(Store.Handle) = undefined;
var control: Store.Handle = undefined;
var peer: ?ble.host.Advertisement = null;
var passed: u32 = 0;
var phase: u8 = 0;
var step: []const u8 = "init";
var finished: bool = false;
var failed: bool = false;
var mutex: hal.rtos.Mutex = .{};
const AttRecord = struct {
    count: u32 = 0,
    len: usize = 0,
    bytes: [ble.host.gatt.mtu]u8 = @splat(0),
};
var att_rx: AttRecord = .{};
var att_tx: AttRecord = .{};

fn set_step(value: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    step = value;
}
fn trace_att(_: *const Host, tx: bool, pdu: []const u8) void {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    const record = if (tx) &att_tx else &att_rx;
    record.count +%= 1;
    record.len = pdu.len;
    const len = @min(pdu.len, record.bytes.len);
    @memcpy(record.bytes[0..len], pdu[0..len]);
}
// Caller holds mutex for step/phase. Copy host-task state with scheduling
// excluded; never log or wait with interrupts masked. No key material is copied.
// Best-effort: the host task updates these fields without this lock, so a
// copy taken while it is preempted mid-update can mix two host states.
fn diagnostics() void {
    const snapshot = blk: {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();
        break :blk .{
            .connection = host.connection,
            .packet = host.last_packet,
            .connection_status = host.connection_status,
            .disconnect_reason = host.disconnect_reason,
            .hci = host.last_hci_status,
            .att = host.last_att_error,
            .encryption_status = host.last_encryption_status,
            .encryption_enabled = host.last_encryption_enabled,
            .state = if (host.security) |s| s.state else null,
            .encrypted = if (host.security) |s| s.encrypted else false,
            .authenticated = if (host.security) |s| s.authenticated else false,
            .bonded = if (host.security) |s| s.bonded else false,
            .smp_failure = if (host.security) |s| s.failure else null,
            .pending = host.att_pending,
            .timed_out = host.att_timed_out,
            .server_encrypted = if (host.server) |s| s.encrypted else false,
            .permission = if (host.server) |s| s.permissions[Value - 1] else null,
            .rx = att_rx,
            .tx = att_tx,
        };
    };
    std.log.err("SELFTEST ble_smp diag phase={d} step={s} attempt={d} connection={?d} connection_status={?d} disconnect_reason={?d} hci={d} att={d}", .{ phase, step, connection_attempt, snapshot.connection, snapshot.connection_status, snapshot.disconnect_reason, snapshot.hci, snapshot.att });
    std.log.err("SELFTEST ble_smp diag smp={?t} encrypted={} authenticated={} bonded={} smp_failure={?d} encryption_status={?d} encryption_enabled={?d} server_encrypted={} permission={?t} pending={?d} att_timeout={}", .{ snapshot.state, snapshot.encrypted, snapshot.authenticated, snapshot.bonded, snapshot.smp_failure, snapshot.encryption_status, snapshot.encryption_enabled, snapshot.server_encrypted, snapshot.permission, snapshot.pending, snapshot.timed_out });
    if (snapshot.packet) |packet| std.log.err("SELFTEST ble_smp diag last_packet kind={t} len={d} header={x}", .{ packet.kind, packet.len, packet.header });
    std.log.err("SELFTEST ble_smp diag att_rx count={d} len={d} pdu={x}", .{ snapshot.rx.count, snapshot.rx.len, snapshot.rx.bytes[0..@min(snapshot.rx.len, snapshot.rx.bytes.len)] });
    std.log.err("SELFTEST ble_smp diag att_tx count={d} len={d} pdu={x}", .{ snapshot.tx.count, snapshot.tx.len, snapshot.tx.bytes[0..@min(snapshot.tx.len, snapshot.tx.bytes.len)] });
}

/// The operator's side of SMP IO, on the host task. Each request is prompted
/// once; answers are lines read without blocking, so the host keeps
/// exchanging packets while the operator looks at the other board. A
/// withdrawn request prints `io cancel`.
var console: connection_policy.Console = .{};
fn user_io(_: ?*anyopaque, request: smp.IoRequest) smp.IoAnswer {
    switch (request) {
        .display => |value| {
            std.log.info("SELFTEST ble_smp io display={d:0>6}", .{value});
            return .accept;
        },
        .cancel => {
            std.log.info("SELFTEST ble_smp io cancel", .{});
            console.cancel(hal.usb_serial_jtag.read);
            return .accept;
        },
        .compare => |value| if (console.prompt()) std.log.info("SELFTEST ble_smp io compare={d:0>6}", .{value}),
        .input => if (console.prompt()) std.log.info("SELFTEST ble_smp io input", .{}),
    }
    console.refill(hal.usb_serial_jtag.read);
    while (console.line()) |line| {
        const reply = connection_policy.parse_reply(line);
        const answer: ?smp.IoAnswer = switch (request) {
            .compare => switch (reply) {
                .yes => .accept,
                .no => .reject,
                else => null,
            },
            .input => switch (reply) {
                .passkey => |value| .{ .passkey = value },
                .no => .reject,
                else => null,
            },
            .display, .cancel => null,
        };
        if (answer) |result| {
            std.log.info("SELFTEST ble_smp io answer={t}", .{result});
            console.answered();
            return result;
        }
        std.log.warn("SELFTEST ble_smp io ignored line len={d}", .{line.len});
    }
    return .pending;
}

fn now() u64 {
    return hal.time.get_time_since_boot().to_us() / 1000;
}
fn pass(name: []const u8) error{Deadline}!void {
    mutex.lock();
    defer mutex.unlock();
    if (finished) return error.Deadline;
    passed += 1;
    std.log.info("SELFTEST ble_smp {s}: PASS", .{name});
}
fn require(ok: bool) error{Mismatch}!void {
    if (!ok) return error.Mismatch;
}
fn advert(_: ?*anyopaque, ad: *const ble.host.Advertisement) void {
    if (peer != null or (!selecting_ready and ad.address_type != 0)) return;
    const selected = connection_policy.select(ad.address, ad.address_type, ad.event_type, ad.bytes[0..ad.len], selecting_ready, identity, options.peer_address) orelse return;
    identity = selected;
    peer = ad.*;
}
fn pump() !void {
    host.poll(50) catch |err| switch (err) {
        error.Timeout => {},
        else => return err,
    };
}
fn monitor() void {
    // Each of the two boots has a 40 s budget, including discovery. Report a
    // failure even if the host is stuck in a controller/ATT procedure.
    const deadline = now() + 40_000;
    while (true) {
        hal.rtos.sleep(.from_ms(1000));
        mutex.lock();
        if (!finished and now() >= deadline) {
            diagnostics();
            std.log.err("SELFTEST ble_smp deadline: FAIL phase={d}", .{phase});
            finished = true;
            failed = true;
        }
        if (finished) std.log.info("SELFTEST ble_smp DONE pass={d} fail={d}", .{ passed, @intFromBool(failed) });
        mutex.unlock();
    }
}
pub fn main() !void {
    // See XIAO board definition / Seeed hardware overview, RF switch assignment.
    // These otherwise unused pins stay low on the Super Mini as well.
    hal.gpio.num(3).apply(.{ .output_enable = true });
    hal.gpio.num(3).put(0);
    hal.gpio.num(14).apply(.{ .output_enable = true });
    hal.gpio.num(14).put(0);
    var heap: microzig.Allocator = try .init_with_heap(160 * 1024);
    run(heap.allocator()) catch |err| {
        mutex.lock();
        diagnostics();
        std.log.err("SELFTEST ble_smp {s}: FAIL {t} hci={d} att={d}", .{ step, err, host.last_hci_status, host.last_att_error });
        finished = true;
        failed = true;
        mutex.unlock();
        std.log.info("SELFTEST ble_smp DONE pass={d} fail=1", .{passed});
    };
    while (true) hal.rtos.sleep(.from_ms(1000));
}
fn run(allocator: std.mem.Allocator) !void {
    host = Host.init(controller.transport());
    host.on_att_packet = trace_att;
    const backend = try hal.nvs_flash.open(try hal.flash.Flash.init(.{}), "nvs");
    try storage.init(backend, backend.region.size);
    control = try storage.open("smp_selftest", .read_write_purge);
    phase = control.get(u8, "phase") catch |err| switch (err) {
        error.NotFound => 0,
        else => return err,
    };
    if (phase > 1) return error.InvalidPhase;
    passed = if (phase == 1) try control.get(u32, "passed") else 0;
    _ = try hal.rtos.spawn(allocator, monitor, .{}, .{ .name = "smp_deadline", .priority = .lowest, .stack_size = 2048 });
    adapter = .{ .handle = try storage.open("smp_bonds", .read_write_purge) };
    try controller.start(allocator);
    try host.initialize();
    var irk: [16]u8 = undefined;
    const saved_irk = control.get_blob("irk", &irk) catch |err| switch (err) {
        error.NotFound => blk: {
            try ble.security_crypto.random_fn(null, &irk);
            try control.set_blob("irk", &irk);
            break :blk &irk;
        },
        else => return err,
    };
    try require(saved_irk.len == 16);
    try ble.security_crypto.random_fn(null, &boot_nonce);
    const central = if (role == .auto) blk: {
        const data = connection_policy.advertising_data(suite_name, boot_nonce, false);
        try host.advertise_nonconnectable(data[1 .. data[0] + 1]);
        host.on_advertisement = advert;
        set_step("role_discovery");
        try host.scan(true);
        const discovery_end = now() + 6000;
        while (now() < discovery_end) try pump();
        try host.scan(false);
        host.on_advertisement = null;
        try host.stop_advertising();
        log_local("discovery");
        if (peer) |ad| log_peer("discovery", ad);
        const address = if (peer) |found| smp.crypto.reverse(6, found.address) else null;
        const elected = try connection_policy.is_central(.auto, host.local_address[1..7].*, address);
        if (phase == 0) try adapter.interface().remove([1]u8{0} ++ address.?);
        break :blk elected;
    } else try connection_policy.is_central(role, host.local_address[1..7].*, null);
    try host.configure_security(.{
        .crypto = ble.security_crypto,
        .store = adapter.interface(),
        .irk = irk,
        .io = switch (connection_policy.capability(method, central)) {
            inline else => |capability| @field(smp.IoCapability, @tagName(capability)),
        },
        .require_authenticated = authenticated,
        .io_fn = if (authenticated) user_io else null,
    });
    std.log.info("SELFTEST ble_smp phase={d} role={t} central={} method={t}", .{ phase, role, central, method });
    if (central) {
        try connect_peer();
        try central_run();
    } else {
        set_step("peripheral_ready");
        const data = connection_policy.advertising_data(ready_name, boot_nonce, true);
        try host.configure_advertising(ready_name);
        try host.set_advertising_data(data[1 .. data[0] + 1]);
        host.server.?.permissions[Value - 1] = .encrypted;
        try host.resume_advertising();
        log_local("peripheral_ready");
        std.log.info("SELFTEST ble_smp peripheral_ready scanning=false advertising=true name={s}", .{ready_name});
        set_step("wait_connection");
        while (host.connection == null) try pump();
        try peripheral_run();
    }
}
fn log_local(context: []const u8) void {
    const a = host.local_address;
    std.log.info("SELFTEST ble_smp {s} own_address={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} type={d} nonce={x}", .{ context, a[1], a[2], a[3], a[4], a[5], a[6], a[0], boot_nonce });
}
fn log_peer(context: []const u8, ad: ble.host.Advertisement) void {
    const a = ad.address;
    std.log.info("SELFTEST ble_smp {s} address={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} type={d} event_type={d} name={s} nonce={x}", .{ context, a[5], a[4], a[3], a[2], a[1], a[0], ad.address_type, ad.event_type, ad.name() orelse "", identity.?.nonce });
}
fn find_ready() !void {
    peer = null;
    selecting_ready = true;
    host.on_advertisement = advert;
    defer host.on_advertisement = null;
    try host.scan(true);
    const deadline = now() + 5000;
    while (peer == null and now() < deadline) pump() catch |err| {
        try host.scan(false);
        return err;
    };
    try host.scan(false);
    if (peer == null) return error.SelftestPeerNotFound;
}
fn wrong_gatt(value: []const u8) error{WrongSelftestGatt} {
    std.log.err("SELFTEST ble_smp wrong_peer_gatt expected=FFF1_declaration_handle5_value6_encrypted received={x} att={d}; refusing security", .{ value, host.last_att_error });
    return error.WrongSelftestGatt;
}
fn connect_peer() !void {
    connection_attempt = 0;
    while (true) {
        connection_attempt += 1;
        host.connection_status = null;
        host.disconnect_reason = null;
        set_step("connect");
        std.log.info("SELFTEST ble_smp connect attempt={d}/{d}", .{ connection_attempt, connection_policy.max_attempts });
        try find_ready();
        const selected = peer.?;
        log_peer("initiate", selected);
        host.connect_address(selected, 5000) catch |err| {
            try retry_connection(err);
            continue;
        };
        // A successful Connection Complete only creates a handle. Confirm
        // establishment with a read before starting any security procedure.
        set_step("connection_probe");
        var out: [20]u8 = undefined;
        // The open declaration at handle 5 must describe encrypted FFF1 at 6.
        const declaration_len = host.read(5, &out) catch |err| {
            if (err == error.AttError) return wrong_gatt(&.{});
            try retry_connection(err);
            continue;
        };
        if (!connection_policy.selftest_declaration(out[0..declaration_len])) return wrong_gatt(out[0..declaration_len]);
        if (host.read(Value, &out)) |len| return wrong_gatt(out[0..len]) else |err| {
            if (err != error.AttError) {
                try retry_connection(err);
                continue;
            }
            if (host.last_att_error != 0x0f) return wrong_gatt(&.{});
        }
        std.log.info("SELFTEST ble_smp connection_probe attempt={d} hci={d} att={d}", .{ connection_attempt, host.last_hci_status, host.last_att_error });
        return;
    }
}
fn retry_connection(err: ble.host.Error) !void {
    if (!connection_policy.retry(err, connection_attempt, host.connection, host.connection_status, host.disconnect_reason)) return err;
    std.log.warn("SELFTEST ble_smp {s} attempt={d}/{d} failed={t} connection_status={?d} disconnect_reason={?d}; retrying", .{ step, connection_attempt, connection_policy.max_attempts, err, host.connection_status, host.disconnect_reason });
    try alive();
    hal.rtos.sleep(.from_ms(connection_policy.backoff_ms));
}
fn central_run() !void {
    var out: [20]u8 = undefined;
    if (phase == 0) {
        set_step("att_before_pairing");
        if (host.read(Value, &out)) |_| return error.UnexpectedAccess else |err| {
            if (err != error.AttError) return err;
            try require(host.last_att_error == 0x0f);
        }
        try pass(step);
        set_step(paired_step);
        try host.secure();
        try require(host.security.?.encrypted and host.security.?.authenticated == authenticated);
        try pass(step);
        set_step("att_after_pairing");
        _ = try host.read(Value, &out);
        try pass(step);
        try verify_bond();
        try host.write(Value, "prepare_reset", false);
        try wait_value("reset_ready");
        try alive();
        try control.set(u32, "passed", passed);
        try control.set(u8, "phase", 1);
        try host.write(Value, "reset_now", false);
        reset();
    }
    set_step("reboot_bond_loaded");
    try require(host.security.?.bonded);
    try pass(step);
    set_step("reencrypt_without_pairing");
    try host.secure();
    try require(host.security.?.encrypted and host.security.?.pairing_count == 0 and host.security.?.authenticated == authenticated);
    try pass(step);
    _ = try host.read(Value, &out);
    set_step("peer_removes_bond");
    try host.write(Value, "remove_bond", false);
    try wait_value("removed");
    try pass(step);
    try host.disconnect();
    try connect_peer();
    set_step("missing_key_fails_cleanly");
    // The failure may disconnect and destroy the session; retain its address.
    const peer_address = host.security.?.peer;
    if (host.secure()) |_| return error.UnexpectedEncryption else |err| {
        try require(err == error.SecurityFailed or err == error.Disconnected or err == error.CommandFailed);
    }
    try pass(step);
    // End the failed encryption procedure before attempting fresh pairing.
    const remote = host.security_config.?.store.?;
    try remote.remove(peer_address);
    if (host.connection != null) try host.disconnect();
    try connect_peer();
    set_step("fresh_pairing");
    try host.secure();
    try require(host.security.?.encrypted and host.security.?.pairing_count == 1 and host.security.?.authenticated == authenticated);
    try pass(step);
    try verify_bond();
    try host.write(Value, "finish", false);
    try wait_value("finished");
    try finish();
}
fn verify_bond() !void {
    set_step("bond_stored");
    const session = host.security.?;
    const saved = (try adapter.interface().load(session.peer)) orelse return error.BondMissing;
    try require(smp.crypto.equal(saved.ltk, session.derived.ltk));
    try require(std.mem.eql(u8, &saved.irk, &session.peer_irk));
    try require(saved.authenticated == authenticated);
    try pass(step);
}
fn wait_value(expected: []const u8) !void {
    const deadline = now() + 3000;
    var bytes: [20]u8 = undefined;
    while (now() < deadline) {
        const len = try host.read(Value, &bytes);
        if (std.mem.eql(u8, bytes[0..len], expected)) return;
        hal.rtos.sleep(.from_ms(20));
    }
    return error.PeerTimeout;
}
fn set_value(value: []const u8) void {
    @memcpy(host.server.?.value[0..value.len], value);
    host.server.?.value_len = @intCast(value.len);
}
fn peripheral_run() !void {
    set_step(if (phase == 0) "wait_pairing_and_prepare_reset" else "wait_reencryption");
    var resumed = false;
    var removed = false;
    var failure_seen = false;
    while (true) {
        try pump();
        if (host.connection == null) {
            set_step("wait_reconnection");
            try host.resume_advertising();
            while (host.connection == null) try pump();
        }
        if (phase == 1 and !removed and !resumed and host.security.?.encrypted) {
            set_step("reencrypt_without_pairing");
            try require(host.security.?.bonded and host.security.?.pairing_count == 0 and host.security.?.authenticated == authenticated);
            try pass(step);
            resumed = true;
            set_step("wait_remove_bond");
        }
        if (phase == 1 and removed and !failure_seen and host.negative_ltk_replies != 0) {
            try pass("missing_key_fails_cleanly");
            failure_seen = true;
        }
        const value = host.server.?.value[0..host.server.?.value_len];
        if (phase == 0 and std.mem.eql(u8, value, "prepare_reset")) {
            set_step(paired_step);
            try require(host.security.?.encrypted and host.security.?.authenticated == authenticated);
            try pass(step);
            try verify_bond();
            set_value("reset_ready");
            set_step("wait_reset_now");
        } else if (phase == 0 and std.mem.eql(u8, value, "reset_now")) {
            try alive();
            try control.set(u32, "passed", passed);
            try control.set(u8, "phase", 1);
            reset();
        } else if (phase == 1 and std.mem.eql(u8, value, "remove_bond")) {
            try host.remove_bond(host.security.?.peer);
            try require(try adapter.interface().load(host.security.?.peer) == null);
            removed = true;
            set_value("removed");
            set_step("wait_missing_key_then_fresh_pairing");
            try pass("bond_removed");
        } else if (phase == 1 and std.mem.eql(u8, value, "finish")) {
            try require(removed and resumed and failure_seen and host.security.?.encrypted and host.security.?.pairing_count == 1 and host.security.?.authenticated == authenticated);
            try pass("fresh_pairing");
            try verify_bond();
            set_value("finished");
            // Service the central's final read before finishing this role.
            const end = now() + 500;
            while (now() < end) try pump();
            try finish();
            return;
        }
    }
}
fn alive() !void {
    mutex.lock();
    defer mutex.unlock();
    if (finished) return error.Deadline;
}
fn finish() !void {
    try control.set(u8, "phase", 0);
    mutex.lock();
    defer mutex.unlock();
    if (finished) return error.Deadline;
    finished = true;
    std.log.info("SELFTEST ble_smp DONE pass={d} fail=0", .{passed});
}
extern fn esp_rom_software_reset_system() callconv(.c) noreturn;
fn reset() noreturn {
    // Pinned C6 ROM alias in ld/esp32_c6/rom_functions.ld; software system
    // reset reloads the same flash image. No flash writes after the checkpoint.
    hal.rtos.sleep(.from_ms(200));
    esp_rom_software_reset_system();
}
