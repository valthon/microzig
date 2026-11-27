//! Shared C6 bench configuration and USB results. No wiring needed. On a XIAO ESP32C6 flash
//! the xiao_esp32_c6_* build: the esp32_c6 build leaves its rf switch off, about 20 dB down.
const std = @import("std");
const microzig = @import("microzig");
const options = @import("ble_options");
const hal = microzig.hal;
const rtos = hal.rtos;
const ble = hal.radio.bluetooth;
const Host = ble.host.Host;
const Error = ble.host.Error || error{ValueMismatch};
/// Everything a bench run can fail with: controller start, then host steps.
const Failure = ble.Error || Error;
const antenna = @import("antenna_options").antenna;
pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{
    .log_level = .info,
    .logFn = hal.usb_serial_jtag.logger.log,
    .log_scope_levels = &.{ .{ .scope = .esp_radio_osi, .level = .err }, .{ .scope = .esp_radio_timer, .level = .err } },
});
pub const microzig_options: microzig.Options = .{
    .interrupts = .{ .interrupt29 = ble.interrupt_handler, .interrupt30 = hal.radio.interrupt_handler, .interrupt31 = rtos.interrupt_handler },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{
        // Match IDF's controller priorities and give host/callout/PHY tasks
        // fair service even when advertising reports arrive continuously.
        .rtos = .{ .enable = true, .priority_bits = 5, .preempt_same_priority_tasks_on_tick = true },
        .radio = .{ .radios = .{ .wifi = false, .ble = true } },
    },
};
pub const Role = enum { scan, peripheral, central };
const clock_config: hal.clocks.Config = .init_comptime(160_000_000);
pub fn init() void {
    hal.init_sequence(clock_config);
}
// Application storage is stable for the entire boot. The library owns no host
// globals; the reporter's shared counters are protected by its task mutex.
var controller: ble.Controller = .{};
var host: Host = undefined;
var reporter: Reporter = .{};

const fail_format = "SELFTEST {s} {s}: FAIL {t} hci_status={d} att_error={d} disconnect_reason={?x}";

const Reporter = struct {
    mutex: rtos.Mutex = .{},
    suite: []const u8 = "",
    step: []const u8 = "controller",
    passed: u32 = 0,
    failed: u32 = 0,
    done: bool = false,
    reports: u32 = 0,
    connections: u32 = 0,
    attempts: u8 = 0,
    notifications: u32 = 0,
    subscribed: bool = false,
    // The first failure, repeated with every DONE line: USB may open late.
    failure: ?Failure = null,
    failed_step: []const u8 = "",
    hci_status: u8 = 0,
    att_error: u8 = 0,
    disconnect_reason: ?u8 = null,

    fn begin(self: *Reporter, step: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.step = step;
    }
    fn pass(self: *Reporter, step: []const u8) void {
        self.mutex.lock();
        self.step = step;
        self.passed += 1;
        self.mutex.unlock();
        std.log.info("SELFTEST {s} {s}: PASS", .{ self.suite, step });
    }
    fn fail(self: *Reporter, err: Failure) void {
        self.mutex.lock();
        self.failed += 1;
        const step = self.step;
        if (self.failure == null) {
            self.failure = err;
            self.failed_step = step;
            self.hci_status = host.last_hci_status;
            self.att_error = host.last_att_error;
            self.disconnect_reason = host.disconnect_reason;
        }
        self.mutex.unlock();
        std.log.err(fail_format, .{ self.suite, step, err, host.last_hci_status, host.last_att_error, host.disconnect_reason });
    }
    fn finish(self: *Reporter) void {
        self.mutex.lock();
        self.done = true;
        self.mutex.unlock();
        self.print();
    }
    fn print(self: *Reporter) void {
        self.mutex.lock();
        const done = self.done;
        const step = self.step;
        const passed = self.passed;
        const failed = self.failed;
        const reports = self.reports;
        const connections = self.connections;
        const attempts = self.attempts;
        const notifications = self.notifications;
        const subscribed = self.subscribed;
        const failure = self.failure;
        const failed_step = self.failed_step;
        const hci_status = self.hci_status;
        const att_error = self.att_error;
        const disconnect_reason = self.disconnect_reason;
        self.mutex.unlock();
        if (failure) |err| std.log.err(fail_format, .{ self.suite, failed_step, err, hci_status, att_error, disconnect_reason });
        if (done) std.log.info("SELFTEST {s} DONE pass={d} fail={d}", .{ self.suite, passed, failed }) else std.log.info("SELFTEST {s} RUNNING step={s} pass={d} fail={d}", .{ self.suite, step, passed, failed });
        std.log.info("BLE {s} advertising_reports={d} connections={d} notifications={d} subscribed={}", .{ self.suite, reports, connections, notifications, subscribed });
        if (std.mem.eql(u8, self.suite, "ble_central"))
            std.log.info("BLE {s} attempts={d}", .{ self.suite, attempts });
    }
    fn run(self: *Reporter) void {
        rtos.sleep(.from_ms(1500));
        while (true) {
            self.print();
            rtos.sleep(.from_ms(3000));
        }
    }
    fn metrics(self: *Reporter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.notifications = if (host.server) |server| server.counter else host.notifications;
        self.subscribed = if (host.server) |server| server.subscribed else host.peer_notify != 0 and host.connection != null;
    }
};

pub fn run(comptime role: Role) !void {
    reporter.suite = "ble_" ++ @tagName(role);
    // A board with an rf switch in front of the antenna (the XIAO ESP32C6) leaves it
    // unpowered at reset. On the bench that cost about 20 dB in both directions.
    if (microzig.config.has_board) {
        if (@hasDecl(microzig.board, "antenna"))
            microzig.board.antenna.apply(@field(microzig.board.antenna.Selection, @tagName(antenna)));
    }
    // Initialize before starting the reporter so even a controller failure has
    // defined host diagnostics. No HCI traffic is sent by Host.init.
    host = .init(controller.transport());
    var heap: microzig.Allocator = try .init_with_heap(160 * 1024);
    _ = try rtos.spawn(heap.allocator(), Reporter.run, .{&reporter}, .{
        .name = "ble_report",
        .priority = @fromBackingInt(2),
        .stack_size = 4096,
    });
    controller.start(heap.allocator()) catch |err| {
        reporter.fail(err);
        reporter.finish();
        idle();
    };
    reporter.pass("controller");
    reporter.begin("hci");
    host.initialize() catch |err| {
        reporter.fail(err);
        reporter.finish();
        idle();
    };
    reporter.pass("hci");
    const result = switch (role) {
        .scan => scan(),
        .peripheral => peripheral(),
        .central => central(),
    };
    result catch |err| {
        reporter.fail(err);
        if (role == .central) {
            central_teardown() catch |cleanup_err| {
                reporter.begin("teardown");
                reporter.fail(cleanup_err);
                // Do not advertise DONE while the controller may hold a link.
                idle();
            };
        }
        reporter.finish();
        idle();
    };
    if (role == .central) {
        central_teardown() catch |err| {
            reporter.begin("teardown");
            reporter.fail(err);
            idle();
        };
    }
    reporter.finish();
    idle();
}
fn idle() noreturn {
    while (true) rtos.sleep(.from_ms(1000));
}
fn now_ms() u64 {
    return hal.time.get_time_since_boot().to_us() / 1000;
}
fn central_teardown() Error!void {
    // Keep the original failing step/status before cleanup changes diagnostics.
    // A lost ATT response does not undo a write; never retry it on this bearer.
    if (host.connection != null) try host.disconnect();
    // After local termination no more packets refresh the peer's supervision
    // timer. Allow it to expire even if the peer missed LL_TERMINATE_IND.
    // LE connection updates are tracked by the host; 100 ms covers two of the
    // requested maximum 50 ms intervals. DONE therefore cannot race a new boot
    // against this run's still-live peer link.
    reporter.begin("peer_release");
    rtos.sleep(.from_ms(host.supervision_timeout_ms + 100));
}
fn poll_idle() Error!void {
    host.poll(100) catch |err| switch (err) {
        error.Timeout => {},
        else => return err,
    };
}
fn scan() Error!void {
    host.on_advertisement = advertiser;
    host.advertisement_context = &reporter;
    reporter.begin("scan_start");
    try host.scan(true);
    reporter.pass("scan_start");
    reporter.begin("scan");
    const deadline = now_ms() + @as(u64, options.scan_seconds) * 1000;
    while (now_ms() < deadline) try poll_idle();
    reporter.begin("scan_stop");
    try host.scan(false);
    reporter.pass("scan_stop");
}
fn advertiser(context: ?*anyopaque, ad: *const ble.host.Advertisement) void {
    const report: *Reporter = @ptrCast(@alignCast(context));
    report.mutex.lock();
    report.reports +%= 1;
    report.mutex.unlock();
    const raw_name = ad.name() orelse "";
    var name: [31]u8 = undefined;
    for (raw_name, 0..) |byte, i| name[i] = if (std.ascii.isPrint(byte)) byte else '.';
    std.log.info("BLE advertiser {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2} type={d} rssi={d} name={s}", .{
        ad.address[5], ad.address[4], ad.address[3], ad.address[2], ad.address[1], ad.address[0], ad.address_type, ad.rssi, name[0..raw_name.len],
    });
}
fn peripheral() Error!void {
    reporter.begin("advertise");
    try host.advertise("MZ-C6");
    reporter.pass("advertise");
    reporter.begin("await_peer");
    var was_connected = false;
    var saw_connection = false;
    var saw_subscription = false;
    var saw_notification = false;
    while (true) {
        host.poll(100) catch |err| switch (err) {
            error.Timeout => {},
            error.Disconnected => if (host.connection != null) {
                return err;
            },
            else => return err,
        };
        host.tick() catch |err| switch (err) {
            error.Disconnected => if (host.connection != null) {
                return err;
            },
            else => return err,
        };
        if (!was_connected and host.connection != null) {
            reporter.mutex.lock();
            reporter.connections += 1;
            reporter.mutex.unlock();
            if (!saw_connection) {
                reporter.pass("connection");
                saw_connection = true;
            }
        }
        if (was_connected and host.connection == null) try host.resume_advertising();
        was_connected = host.connection != null;
        const server = &host.server.?;
        if (server.subscribed and !saw_subscription) {
            reporter.pass("subscription");
            saw_subscription = true;
        }
        if (server.counter > 0 and !saw_notification) {
            reporter.pass("notify");
            saw_notification = true;
            reporter.metrics();
            reporter.finish();
        }
        reporter.metrics();
    }
}
const max_connect_attempts = 3;
const connect_backoff_ms = 250;

fn retry_connection(err: Error, attempt: u8) Error!void {
    std.log.warn("BLE ble_central attempt={d}/{d} failed={t} connection_status={?x} disconnect_reason={?x}", .{
        attempt, max_connect_attempts, err, host.connection_status, host.disconnect_reason,
    });
    // Core v6.0 Vol 1 Part F §2.59: 0x3e means establishment failed.
    // Vol 6 Part B §4.5 / §4.5.2 distinguish creation from establishment and
    // its initial supervision timeout. A handle alone is not proof of a link:
    // the controller can report 0x3e while the first discovery is outstanding.
    // Do not treat a host Timeout or an established-link timeout (0x08) as 0x3e.
    const establishment_failed = switch (err) {
        error.ConnectionFailed => host.connection_status == 0x3e,
        error.Disconnected, error.NoConnection => host.disconnect_reason == 0x3e,
        else => false,
    };
    if (!establishment_failed or host.connection != null or attempt >= max_connect_attempts) return err;
    std.log.info("BLE ble_central retry backoff_ms={d}", .{connect_backoff_ms});
    rtos.sleep(.from_ms(connect_backoff_ms));
}

fn central() Error!void {
    var attempt: u8 = 0;
    const peer = while (true) {
        attempt += 1;
        reporter.mutex.lock();
        reporter.attempts = attempt;
        reporter.mutex.unlock();
        std.log.info("BLE ble_central attempt={d}/{d}", .{ attempt, max_connect_attempts });
        // Keep diagnostics specific to this attempt, including failures in scan.
        host.connection_status = null;
        host.disconnect_reason = null;
        reporter.begin("connect");
        host.connect_named(options.peer_name, 15_000) catch |err| {
            try retry_connection(err, attempt);
            continue;
        };
        reporter.begin("discover");
        const discovered = host.discover() catch |err| {
            try retry_connection(err, attempt);
            continue;
        };
        break discovered;
    };
    // Count these checks once, after discovery confirms a usable connection.
    reporter.pass("connect");
    reporter.mutex.lock();
    reporter.connections = 1;
    reporter.mutex.unlock();
    std.log.info("BLE FFF0={x}..{x} FFF1={x} FFF2={x} CCCD={x}", .{ peer.service_start, peer.service_end, peer.read_write, peer.notify, peer.cccd });
    reporter.pass("discover");
    var value: [20]u8 = undefined;
    reporter.begin("read");
    const initial_len = try host.read(peer.read_write, &value);
    std.log.info("BLE initial FFF1 length={d}", .{initial_len});
    reporter.pass("read");
    reporter.begin("write");
    try host.write(peer.read_write, "MZ-C6", false);
    reporter.pass("write");
    reporter.begin("readback");
    const readback_len = try host.read(peer.read_write, &value);
    if (!std.mem.eql(u8, value[0..readback_len], "MZ-C6")) return error.ValueMismatch;
    reporter.pass("readback");
    reporter.begin("write_command");
    try host.write(peer.read_write, "MZ-C6-WNR", true);
    reporter.pass("write_command");
    reporter.begin("command_readback");
    const command_len = try host.read(peer.read_write, &value);
    if (!std.mem.eql(u8, value[0..command_len], "MZ-C6-WNR")) return error.ValueMismatch;
    reporter.pass("command_readback");
    reporter.begin("subscribe");
    try host.subscribe(peer);
    reporter.pass("subscribe");
    reporter.begin("notifications");
    const deadline = now_ms() + 6000;
    while (host.notifications < 2 and now_ms() < deadline) {
        try poll_idle();
        if (host.connection == null) return error.Disconnected;
        reporter.metrics();
    }
    if (host.notifications < 2) return error.Timeout;
    std.log.info("BLE received notifications={d} last_length={d}", .{ host.notifications, host.notification_len });
    reporter.pass("notifications");
    reporter.begin("unsubscribe");
    try host.write(peer.cccd, &.{ 0, 0 }, false);
    host.peer_notify = 0;
    reporter.metrics();
    reporter.pass("unsubscribe");
    reporter.begin("disconnect");
    try host.disconnect();
    reporter.pass("disconnect");
}
