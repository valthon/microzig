const std = @import("std");
const PMA = @import("usb_pma.zig");

const microzig = @import("microzig");
const time = microzig.hal.time;
const interrupt = microzig.interrupt;
const Duration = microzig.drivers.time.Duration;
const Deadline = microzig.drivers.time.Deadline;

const USB = microzig.chip.peripherals.USB;
const USBTypes = microzig.chip.types.peripherals.usb_v1;

const InitError = error{
    UsbAlreadyEnabled,
    InvalidEPC,
    EPControlTaken,
    EndpointTaken,
    ConfigError,
    BadEP0,
} || PMA.Config.Error || PMA.BTABLEError;

const EndpointError = error{
    UninitEndpoint,
    RecvBufferOVF,
    TransBufferOVF,
};

const UsbError = error{UsbNotInit} || EndpointError;
const StatusDir = enum {
    RX,
    TX,
};
pub const PID = enum {
    force_data0,
    force_data1,
    no_change,
    endpoint_ctr,
};

const EP_CALLBACK = *const fn (EpControl, ?*anyopaque) void;

pub const Endpoint = struct {
    //configs
    ep_control: EpControl,
    endpoint: u4,
    ep_type: USBTypes.EP_TYPE,
    tx_reset_state: USBTypes.STAT = .Disabled,
    tx_buffer_size: usize,
    rx_reset_state: USBTypes.STAT = .Disabled,
    rx_buffer_size: PMA.RX_size,
    ep_kind: bool = false,
    tx_callback: ?EP_CALLBACK = null,
    rx_callback: ?EP_CALLBACK = null,
    setup_callback: ?EP_CALLBACK = null,
    user_param: ?*anyopaque = null,

    //context data
    rx_pid: u1 = 0,
    tx_pid: u1 = 0,

    pub fn toggle_pid(self: *Endpoint, dir: StatusDir) void {
        switch (dir) {
            .RX => {
                self.rx_pid ^= 1;
            },
            .TX => {
                self.tx_pid ^= 1;
            },
        }
    }

    pub fn get_pid(self: *const Endpoint, dir: StatusDir) PID {
        switch (dir) {
            .RX => {
                return @fromBackingInt(self.rx_pid);
            },
            .TX => {
                return @fromBackingInt(self.tx_pid);
            },
        }
    }

    pub fn force_change(self: *Endpoint, dir: StatusDir, val: PID) PID {
        switch (dir) {
            .RX => self.rx_pid = @intCast(@backingInt(val)),
            .TX => self.tx_pid = @intCast(@backingInt(val)),
        }
        return val;
    }
};

pub const EpControl = enum {
    EPC0,
    EPC1,
    EPC2,
    EPC3,
    EPC4,
    EPC5,
    EPC6,
    EPC7,

    fn check_ep(ep: EpControl) EndpointError!usize {
        const ep_num: usize = @backingInt(ep);
        if (endpoints[ep_num] == null) {
            return error.UninitEndpoint;
        }
        return ep_num;
    }
    pub fn set_status(ep: EpControl, dir: StatusDir, status: USBTypes.STAT, pid: PID) EndpointError!void {
        const ep_num: usize = try ep.check_ep();
        change_status(dir, status, pid, ep_num);
    }

    pub fn read_buffer(ep: EpControl, buffer: []u8) EndpointError![]const u8 {
        const ep_num: usize = try ep.check_ep();
        if (buffer.len < PMA.RX_recv_size(ep_num)) {
            return error.RecvBufferOVF;
        }
        return PMA.RX_to_buffer(buffer, ep_num);
    }

    pub fn write_buffer(ep: EpControl, buffer: []const u8) EndpointError!void {
        const ep_num: usize = try ep.check_ep();
        if (buffer.len > endpoints[ep_num].?.tx_buffer_size) {
            return error.TransBufferOVF;
        }
        PMA.buffer_to_TX(buffer, ep_num);
    }

    //write to buffer and enable TX
    pub fn USB_send(ep: EpControl, buffer: []const u8, pid: PID) UsbError!void {
        if (!init) return error.UsbNotInit;
        const ep_num: usize = try ep.check_ep();
        if (buffer.len > endpoints[ep_num].?.tx_buffer_size) {
            return error.TransBufferOVF;
        }
        PMA.buffer_to_TX(buffer, ep_num);
        change_status(.TX, .Valid, pid, ep_num);
    }

    pub inline fn ZLP(ep: EpControl, pid: PID) UsbError!void {
        return USB_send(ep, &[_]u8{}, pid);
    }

    //read and enable RX for the next pkg
    pub fn USB_read(ep: EpControl, next: PID) UsbError![]const u8 {
        if (!init) return error.UsbNotInit;
        const ep_num: usize = try ep.check_ep();
        const recv = PMA.RX_to_buffer(iner_RX_buffer, ep_num);
        change_status(.RX, .Valid, next, ep_num);
        return recv;
    }
};

const UsbErrorStatus = struct {}; //TODO

const ResetCallback = *const fn (?*anyopaque) void;
const ErrorCallback = *const fn (UsbErrorStatus, ?*anyopaque) void;

pub const Config = struct {
    endpoints: []const Endpoint,
    RX_buffer: []u8,
    reset_callback: ?ResetCallback = null,
    reset_args: ?*anyopaque = null,
    error_callback: ?ErrorCallback = null,
    error_args: ?*anyopaque = null,
};

var init: bool = false;
var endpoints: [8]?Endpoint = @splat(null);
var iner_RX_buffer: []u8 = undefined;
var reset_callback: ?ResetCallback = null;
var reset_ctx: ?*anyopaque = null;
var error_callback: ?ErrorCallback = null;
var error_ctx: ?*anyopaque = null;

fn comptime_or_runtime_err(err: InitError, comptime msg: []const u8, args: anytype) InitError {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(msg, args));
    } else {
        return err;
    }
}

fn usb_check(config: Config) InitError!PMA.Config {
    if (config.endpoints.len > 8) {
        return comptime_or_runtime_err(
            InitError.ConfigError,
            "USB can only support up to 8 endpoints configurations\n",
            .{},
        );
    } else if (config.endpoints.len == 0) {
        return comptime_or_runtime_err(
            InitError.ConfigError,
            "USB must have at least one endpoint configuration\n\n",
            .{},
        );
    }

    var ep_check: u8 = 0;
    var max_rx_size: usize = 0;
    var btable_conf: PMA.Config = .{};
    for (config.endpoints) |epconf| {
        const slot: u3 = @intCast(@backingInt(epconf.ep_control));
        // Endpoint I/O indexes PMA by controller slot.
        if (epconf.endpoint != slot) return comptime_or_runtime_err(
            InitError.InvalidEPC,
            "EP {d} must match its controller slot EPC{d}",
            .{ epconf.endpoint, slot },
        );

        if (epconf.rx_buffer_size.block_qtd > std.math.maxInt(u5)) return comptime_or_runtime_err(
            InitError.ConfigError,
            "EP {d} RX block count does not fit NUM_BLOCK",
            .{epconf.endpoint},
        );
        const ep_size = epconf.rx_buffer_size.calc_rx_size();
        const ep_bit: u8 = @as(u8, 1) << slot;

        if (epconf.endpoint == 0) {
            if (epconf.ep_type != .Control) return comptime_or_runtime_err(
                InitError.BadEP0,
                "EP0 must have type: Control",
                .{},
            );
        }
        if (ep_size > max_rx_size) {
            max_rx_size = ep_size;
        }

        if ((ep_bit & ep_check) == 0) {
            ep_check |= ep_bit;
        } else {
            return comptime_or_runtime_err(
                InitError.EndpointTaken,
                "EP: {x} has already been taken\n",
                .{epconf.endpoint},
            );
        }

        try btable_conf.set_config(slot, .{
            .rx_max_size = epconf.rx_buffer_size,
            .tx_max_size = epconf.tx_buffer_size,
        });
    }
    if ((ep_check & 0x1) == 0) return comptime_or_runtime_err(
        InitError.BadEP0,
        "EP0 not configured\n",
        .{},
    );
    if (config.RX_buffer.len < max_rx_size) return comptime_or_runtime_err(
        InitError.ConfigError,
        "Internal RX is too small for current configuration",
        .{},
    );
    return btable_conf;
}

/// Initialize the USB controller once. Calls after initialization leave it running.
pub fn usb_init(comptime config: Config, startup: Duration) void {
    const btable_conf = comptime usb_check(config) catch unreachable;
    const layout = comptime PMA.plan_layout(btable_conf) catch
        @compileError("USB endpoint buffers exceed PMA capacity");
    if (init) return;
    inner_init(config, layout, startup);
}

/// Initialize the USB controller once, with runtime configuration validation.
pub fn usb_runtime_init(config: Config, startup: Duration) InitError!void {
    if (init) return error.UsbAlreadyEnabled;
    const btable_conf = try usb_check(config);
    const layout = try PMA.plan_layout(btable_conf);
    inner_init(config, layout, startup);
}

fn inner_init(config: Config, layout: PMA.Layout, startup: Duration) void {
    //interrupt.disable(.USB_LP_CAN1_RX0); //NOTE: some error with this function is disabling all interrupts
    const deadline = Deadline.init_relative(time.get_time_since_boot(), startup);

    //force USB reset before init
    USB.CNTR.modify(.{
        .PDWN = 0,
        .FRES = 1,
    });
    while (!deadline.is_reached_by(time.get_time_since_boot())) {
        asm volatile ("nop");
    }
    USB.CNTR.modify(.{ .FRES = 0 });

    //wait for reset
    while (USB.ISTR.read().RESET == 0) {
        asm volatile ("nop");
    }
    USB.CNTR.raw = 0;
    USB.ISTR.raw = 0;

    for (config.endpoints) |ep_conf| {
        const epc_num: usize = @backingInt(ep_conf.ep_control);
        endpoints[epc_num] = ep_conf;
    }
    PMA.btable_init(layout);

    reset_callback = config.reset_callback;
    reset_ctx = config.reset_args;
    error_callback = config.error_callback;
    error_ctx = config.error_args;
    iner_RX_buffer = config.RX_buffer;

    //re-enable interrupts
    USB.CNTR.modify(.{
        .RESETM = 1,
        .CTRM = 1,
    });

    init = true;

    interrupt.enable(.USB_LP_CAN1_RX0);
}

fn change_rx_status(status: USBTypes.STAT, pid: PID, EPC: usize) void {
    const current = USB.EPR[EPC].read();
    const valid: u2 = @as(u2, @backingInt(current.STAT_RX)) ^ @as(u2, @backingInt(status));
    const DTOG_val = switch (pid) {
        .no_change, .endpoint_ctr => @as(u1, 0),
        .force_data0 => current.DTOG_RX,
        .force_data1 => current.DTOG_RX ^ @as(u1, 1),
    };
    USB.EPR[EPC].modify(.{
        .STAT_RX = @as(USBTypes.STAT, @fromBackingInt(valid)),
        .DTOG_RX = DTOG_val,
        .CTR_RX = 1,
        .CTR_TX = 1,
        .STAT_TX = @as(USBTypes.STAT, @fromBackingInt(0)),
        .DTOG_TX = 0,
    });
}

fn change_tx_status(status: USBTypes.STAT, pid: PID, EPC: usize) void {
    const current = USB.EPR[EPC].read();
    const DTOG_val = switch (pid) {
        .no_change, .endpoint_ctr => @as(u1, 0),
        .force_data0 => current.DTOG_TX,
        .force_data1 => current.DTOG_TX ^ @as(u1, 1),
    };

    const valid: u2 = @as(u2, @backingInt(current.STAT_TX)) ^ @as(u2, @backingInt(status));

    USB.EPR[EPC].modify(.{
        .STAT_TX = @as(USBTypes.STAT, @fromBackingInt(valid)),
        .DTOG_TX = DTOG_val,
        .CTR_RX = 1,
        .CTR_TX = 1,
        .STAT_RX = @as(USBTypes.STAT, @fromBackingInt(0)),
        .DTOG_RX = 0,
    });
}

fn change_status(dir: StatusDir, status: USBTypes.STAT, pid: PID, EPC: usize) void {
    const endpoint = &endpoints[EPC].?;

    const call: *const fn (USBTypes.STAT, PID, usize) void = switch (dir) {
        .RX => change_rx_status,
        .TX => change_tx_status,
    };

    const new_pid = switch (pid) {
        .endpoint_ctr => endpoint.get_pid(dir),
        .force_data0, .force_data1 => |p| endpoint.force_change(dir, p),
        else => |some| some,
    };

    call(status, new_pid, EPC);
}

pub fn get_epc_from_ep(ep: usize) ?EpControl {
    for (endpoints) |eps| {
        if (eps) |valid| {
            if (valid.endpoint == ep) return valid.ep_control;
        }
    }
    return null;
}

pub fn set_addr(addr: u7) void {
    USB.DADDR.modify(.{
        .ADD = addr,
        .EF = 1,
    });
}

pub fn default_reset_handler() void {
    USB.DADDR.modify(.{
        .ADD = 0,
        .EF = 1,
    });
    //clear all endpoints
    for (0..8) |EP| {
        const current = USB.EPR[EP].read();
        USB.EPR[EP].modify(.{
            .EA = @as(u4, @intCast(EP)),
            .STAT_RX = current.STAT_RX,
            .STAT_TX = current.STAT_TX,
            .DTOG_TX = current.DTOG_TX,
            .DTOG_RX = current.DTOG_RX,
            .CTR_RX = 0,
            .CTR_TX = 0,
            .EP_KIND = 0,
        });
    }

    USB.ISTR.raw = 0;

    //re-configure endpoints
    for (0..8) |i| {
        if (endpoints[i]) |valid_ep| {
            USB.EPR[i].modify(.{
                .EA = valid_ep.endpoint,
                .EP_TYPE = valid_ep.ep_type,
                .STAT_RX = valid_ep.rx_reset_state,
                .STAT_TX = valid_ep.tx_reset_state,
                .EP_KIND = if (valid_ep.ep_kind) @as(u1, 1) else @as(u1, 0),
            });
        }
    }

    USB.CNTR.modify(.{
        .RESETM = 1,
        .CTRM = 1,
    });
}

pub fn usb_handler() callconv(.c) void {
    const event = USB.ISTR.read();
    if (event.RESET == 1) {
        USB.ISTR.modify(.{ .RESET = 0 });
        if (reset_callback) |callback| {
            callback(reset_ctx);
        } else {
            default_reset_handler();
        }
        return;
    }

    if (event.CTR == 0) return;
    const ep = event.EP_ID;
    const epc = if (endpoints[ep]) |*configured| configured else return;
    const epr = USB.EPR[ep].read();

    // RM0008 Rev 21 §23.5.2 (USB_EPnR): CTR_RX marks a completed OUT or
    // SETUP, SETUP is qualified by CTR_RX, and CTR_TX marks a completed IN.
    // Both CTR flags clear on zero. SETUP starts a new transfer (§23.4.2),
    // so clear an earlier IN completion before the SETUP callback can arm IN.
    const setup = epr.CTR_RX == 1 and epr.SETUP == 1;
    USB.EPR[ep].write(.{
        .EA = epr.EA,
        .EP_TYPE = epr.EP_TYPE,
        .EP_KIND = epr.EP_KIND,
        .CTR_RX = epr.CTR_RX ^ 1,
        .CTR_TX = if (setup) 0 else epr.CTR_TX ^ 1,
        .SETUP = 0, // Read-only.
        .STAT_RX = .Disabled, // Zero leaves toggle-on-write bits unchanged.
        .STAT_TX = .Disabled,
        .DTOG_RX = 0,
        .DTOG_TX = 0,
    });

    if (setup) {
        epc.rx_pid = epr.DTOG_RX;
        epc.tx_pid = epr.DTOG_TX;
        if (epc.setup_callback) |callback| callback(epc.ep_control, epc.user_param);
        return;
    }
    if (epr.CTR_RX == 1) {
        epc.toggle_pid(.RX);
        if (epc.rx_callback) |callback| callback(epc.ep_control, epc.user_param);
    }
    if (epr.CTR_TX == 1) {
        epc.toggle_pid(.TX);
        if (epc.tx_callback) |callback| callback(epc.ep_control, epc.user_param);
    }
}

test "get_epc_from_ep finds configured endpoints and rejects missing ones" {
    const saved = endpoints;
    defer endpoints = saved;
    endpoints = @splat(null);
    endpoints[3] = .{
        .ep_control = .EPC3,
        .endpoint = 3,
        .ep_type = .Bulk,
        .tx_buffer_size = 64,
        .rx_buffer_size = .{ .block_qtd = 0 },
    };

    try std.testing.expectEqual(EpControl.EPC3, get_epc_from_ep(3).?);
    try std.testing.expectEqual(@as(?EpControl, null), get_epc_from_ep(2));
    try std.testing.expectEqual(@as(?EpControl, null), get_epc_from_ep(16));
}

test "runtime USB init rejects invalid configurations before accessing hardware" {
    const ep0: Endpoint = .{
        .ep_control = .EPC0,
        .endpoint = 0,
        .ep_type = .Control,
        .tx_buffer_size = 8,
        .rx_buffer_size = .{ .block_qtd = 4 },
    };
    var bulk_ep0 = ep0;
    bulk_ep0.ep_type = .Bulk;
    var ep7 = ep0;
    ep7.ep_control = .EPC7;
    ep7.endpoint = 7;
    var mismatched = ep7;
    mismatched.endpoint = 3;
    var out_of_range = ep7;
    out_of_range.endpoint = 8;
    var rx: [8]u8 = undefined;
    const startup = Duration.from_ms(0);
    try std.testing.expectError(error.ConfigError, usb_runtime_init(.{
        .endpoints = &.{},
        .RX_buffer = &rx,
    }, startup));
    try std.testing.expectError(error.ConfigError, usb_runtime_init(.{
        .endpoints = &(@as([9]Endpoint, @splat(ep0))),
        .RX_buffer = &rx,
    }, startup));
    try std.testing.expectError(error.BadEP0, usb_runtime_init(.{
        .endpoints = &.{bulk_ep0},
        .RX_buffer = &rx,
    }, startup));
    try std.testing.expectError(error.BadEP0, usb_runtime_init(.{
        .endpoints = &.{ep7},
        .RX_buffer = &rx,
    }, startup));
    try std.testing.expectError(error.EndpointTaken, usb_runtime_init(.{
        .endpoints = &.{ ep0, ep0 },
        .RX_buffer = &rx,
    }, startup));
    try std.testing.expectError(error.InvalidEPC, usb_runtime_init(.{
        .endpoints = &.{ ep0, mismatched },
        .RX_buffer = &rx,
    }, startup));
    try std.testing.expectError(error.InvalidEPC, usb_runtime_init(.{
        .endpoints = &.{ ep0, out_of_range },
        .RX_buffer = &rx,
    }, startup));
    try std.testing.expectError(error.ConfigError, usb_runtime_init(.{
        .endpoints = &.{ep0},
        .RX_buffer = rx[0..7],
    }, startup));

    const mapping = try usb_check(.{
        .endpoints = &.{ ep7, ep0 },
        .RX_buffer = &rx,
    });
    try std.testing.expectEqual(@as(usize, 8), mapping.EP7.?.tx_max_size);
    try std.testing.expectEqual(@as(usize, 8), mapping.EP0.?.rx_max_size.calc_rx_size());
    try std.testing.expectEqual(@as(?PMA.EntryMetadata, null), mapping.EP1);
}

test "SETUP acknowledges stale TX before dispatch and delivers only SETUP" {
    const Trace = struct {
        setup: bool = false,
        tx: bool = false,
        ctr_at_setup: u1 = 1,

        fn on_setup(_: EpControl, ctx: ?*anyopaque) void {
            const trace: *@This() = @ptrCast(@alignCast(ctx.?));
            trace.setup = true;
            trace.ctr_at_setup = USB.EPR[0].read().CTR_TX;
        }

        fn on_tx(_: EpControl, ctx: ?*anyopaque) void {
            const trace: *@This() = @ptrCast(@alignCast(ctx.?));
            trace.tx = true;
        }
    };

    const saved = endpoints[0];
    defer endpoints[0] = saved;
    var trace: Trace = .{};
    endpoints[0] = .{
        .ep_control = .EPC0,
        .endpoint = 0,
        .ep_type = .Control,
        .tx_buffer_size = 8,
        .rx_buffer_size = .{ .block_qtd = 4 },
        .setup_callback = Trace.on_setup,
        .tx_callback = Trace.on_tx,
        .user_param = &trace,
    };

    USB.ISTR.raw = 0;
    USB.ISTR.modify(.{ .CTR = 1 });
    USB.EPR[0].raw = 0;
    USB.EPR[0].modify(.{ .CTR_RX = 1, .CTR_TX = 1, .SETUP = 1, .EP_TYPE = .Control });
    usb_handler();

    try std.testing.expect(trace.setup);
    try std.testing.expect(!trace.tx);
    try std.testing.expectEqual(@as(u1, 0), trace.ctr_at_setup);

    trace = .{};
    USB.ISTR.modify(.{ .CTR = 1 });
    // SETUP only has meaning when CTR_RX is set.
    USB.EPR[0].modify(.{ .CTR_RX = 0, .CTR_TX = 1, .SETUP = 1 });
    usb_handler();

    try std.testing.expect(!trace.setup);
    try std.testing.expect(trace.tx);
}

test "PMA overflow leaves the controller and endpoint state untouched" {
    const host = microzig.testing_usb;
    host.prepare();
    defer host.stop();
    defer endpoints = @splat(null);

    var rx: [64]u8 = undefined;
    USB.CNTR.modify(.{ .RESETM = 1, .CTRM = 1 });
    const cntr = USB.CNTR.raw;
    const istr = USB.ISTR.raw;

    var ep0: Endpoint = .{
        .ep_control = .EPC0,
        .endpoint = 0,
        .ep_type = .Control,
        .tx_buffer_size = 512,
        .rx_buffer_size = .from_bytes(64),
    };
    try std.testing.expectError(error.PMAOverflow, usb_runtime_init(.{
        .endpoints = &.{ep0},
        .RX_buffer = &rx,
    }, .from_us(0)));
    ep0.tx_buffer_size = std.math.maxInt(usize);
    try std.testing.expectError(error.PMAOverflow, usb_runtime_init(.{
        .endpoints = &.{ep0},
        .RX_buffer = &rx,
    }, .from_us(0)));
    ep0.tx_buffer_size = 8;
    ep0.rx_buffer_size.block_qtd = 32;
    try std.testing.expectError(error.ConfigError, usb_runtime_init(.{
        .endpoints = &.{ep0},
        .RX_buffer = &rx,
    }, .from_us(0)));
    try std.testing.expectEqual(cntr, USB.CNTR.raw);
    try std.testing.expectEqual(istr, USB.ISTR.raw);
    try std.testing.expectEqual(@as(?EpControl, null), get_epc_from_ep(0));
    try std.testing.expect(!init);
}

test "PMA layout reserves all descriptors and rounds packet buffers" {
    const host = microzig.testing_usb;
    host.prepare();
    defer host.stop();
    defer {
        init = false;
        endpoints = @splat(null);
    }

    const ep0: Endpoint = .{
        .ep_control = .EPC0,
        .endpoint = 0,
        .ep_type = .Control,
        .tx_buffer_size = 381,
        .rx_buffer_size = .from_bytes(64),
    };
    var ep7: Endpoint = .{
        .ep_control = .EPC7,
        .endpoint = 7,
        .ep_type = .Bulk,
        .tx_buffer_size = 3,
        .rx_buffer_size = .from_bytes(0),
    };
    var rx: [64]u8 = undefined;
    // Rounded allocations of 382 + 64 + 4 bytes exceed the 448-byte payload area.
    try std.testing.expectError(error.PMAOverflow, usb_runtime_init(.{
        .endpoints = &.{ ep0, ep7 },
        .RX_buffer = &rx,
    }, .from_us(0)));

    ep7.tx_buffer_size = 1;
    try usb_runtime_init(.{ .endpoints = &.{ ep0, ep7 }, .RX_buffer = &rx }, .from_us(0));
    try std.testing.expectEqual(@as(u32, 64), host.pma_words[0]); // EP0 TX starts after BTABLE.
    try std.testing.expectEqual(@as(u32, 446), host.pma_words[2]); // EP0 RX follows rounded TX.
    // RM0008 Rev 21 §23.5.3, Table 177: 64 bytes uses BL_SIZE=1 and NUM_BLOCK=1.
    try std.testing.expectEqual(@as(u32, 0x8400), host.pma_words[3]);
    try std.testing.expectEqual(@as(u32, 510), host.pma_words[28]); // EP7 TX follows 64-byte RX.
    try EpControl.EPC7.write_buffer(&.{0x42});
    try std.testing.expectEqual(@as(u32, 0x42), host.pma_words[255]);
}

test "a second runtime initialization leaves the active endpoint table intact" {
    const host = microzig.testing_usb;
    host.prepare();
    defer host.stop();
    defer {
        init = false;
        endpoints = @splat(null);
    }

    const ep0: Endpoint = .{
        .ep_control = .EPC0,
        .endpoint = 0,
        .ep_type = .Control,
        .tx_buffer_size = 8,
        .rx_buffer_size = .{ .block_qtd = 4 },
    };
    const ep1: Endpoint = .{
        .ep_control = .EPC1,
        .endpoint = 1,
        .ep_type = .Bulk,
        .tx_buffer_size = 16,
        .rx_buffer_size = .{ .block_qtd = 0 },
    };
    var rx: [8]u8 = undefined;
    try usb_runtime_init(.{ .endpoints = &.{ ep0, ep1 }, .RX_buffer = &rx }, .from_us(0));
    // Let a broken second initialization finish instead of waiting for reset.
    USB.ISTR.modify(.{ .RESET = 1 });
    const istr = USB.ISTR.raw;
    const pma = host.pma_words;
    try std.testing.expectError(error.UsbAlreadyEnabled, usb_runtime_init(.{
        .endpoints = &.{ep0},
        .RX_buffer = &rx,
    }, .from_us(0)));
    const CompileTimeConfig = struct {
        var rx_buffer: [8]u8 = undefined;
    };
    usb_init(.{ .endpoints = &.{ep0}, .RX_buffer = &CompileTimeConfig.rx_buffer }, .from_us(0));
    try std.testing.expectEqual(istr, USB.ISTR.raw);
    try std.testing.expectEqual(pma, host.pma_words);
    try std.testing.expectEqual(EpControl.EPC1, get_epc_from_ep(1).?);
}
