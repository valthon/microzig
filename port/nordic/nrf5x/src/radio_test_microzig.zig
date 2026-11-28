//! Host register boundary for the IEEE 802.15.4 driver. Register fields and
//! layout come from regz. The fixture models only tasks exercised by the tests.
const std = @import("std");

pub const config = .{ .chip_name = "nrf52840" };
pub const options = .{ .hal = .{ .ieee802154 = true } };
pub const drivers = struct {
    pub const base = struct {
        pub const IEEE802154_Radio = @import("radio_interface");
    };
};

pub const chip = struct {
    pub const types = @import("registers").types;
    pub const peripherals = struct {
        pub const RADIO = &radio;
        pub const CLOCK = &clock;
        pub const TEMP = &temperature;
        pub const TIMER0: *volatile regs.TIMER0 = undefined;
        pub const TIMER1: *volatile regs.TIMER0 = undefined;
        pub const TIMER2: *volatile regs.TIMER0 = undefined;
        pub const TIMER3 = &timer;
        pub const TIMER4: *volatile regs.TIMER0 = undefined;
        pub const RTC0 = &rtc;
        pub const RNG = &rng;
        pub const FICR = &ficr;
    };
};

const regs = chip.types.peripherals;
var radio: regs.RADIO = std.mem.zeroes(regs.RADIO);
var clock: regs.CLOCK = std.mem.zeroes(regs.CLOCK);
var temperature: regs.TEMP = std.mem.zeroes(regs.TEMP);
var timer: regs.TIMER0 = std.mem.zeroes(regs.TIMER0);
var rtc: regs.RTC0 = std.mem.zeroes(regs.RTC0);
var rng: regs.RNG = std.mem.zeroes(regs.RNG);
var ficr: regs.FICR = std.mem.zeroes(regs.FICR);

pub const mmio = struct {
    pub fn Mmio(comptime Packed: type) type {
        const Int = @Int(.unsigned, @bitSizeOf(Packed));
        return packed struct(Int) {
            const Self = @This();
            pub const underlying_type = Packed;
            raw: Int,

            pub fn read(self: *volatile Self) Packed {
                if (@intFromPtr(self) == @intFromPtr(&rtc.COUNTER))
                    rtc.COUNTER.raw = (rtc.COUNTER.raw +% fx.rtc_step) & 0x00ff_ffff;
                if (@intFromPtr(self) == @intFromPtr(&radio.STATE)) {
                    if (fx.on_radio_state_read) |callback| {
                        fx.on_radio_state_read = null;
                        callback();
                    }
                    if (fx.hide_rx_departure_state and Fixture.hardware_state() == .Disabled) {
                        // Test-only delay in CPU visibility. Hardware
                        // shortcuts and task acceptance still use raw STATE.
                        const state = @TypeOf(radio.STATE).underlying_type{ .STATE = .Rx };
                        return @bitCast(@as(Int, @intCast(@as(u32, @bitCast(state)))));
                    }
                }
                if (@intFromPtr(self) == @intFromPtr(&radio.EVENTS_END)) Fixture.run_hook(&fx.on_end_read);
                if (@intFromPtr(self) == @intFromPtr(&radio.EVENTS_PHYEND)) Fixture.run_hook(&fx.on_phyend_read);
                if (@intFromPtr(self) == @intFromPtr(&radio.RXCRC)) {
                    if (fx.on_rx_crc_read) |callback| {
                        fx.on_rx_crc_read = null;
                        callback();
                    }
                }
                const raw = self.raw;
                if (fx.delayed_capture) |capture| {
                    if (@intFromPtr(self) == @intFromPtr(&timer.CC[capture.cc])) {
                        std.debug.assert(fx.routes[capture.route].enabled);
                        timer.CC[capture.cc].raw = capture.tick;
                        fx.delayed_capture = null;
                    }
                }
                return @bitCast(raw);
            }

            pub fn write(self: *volatile Self, value: Packed) void {
                self.write_raw(@bitCast(value));
            }

            pub fn write_raw(self: *volatile Self, value: Int) void {
                const address = @intFromPtr(self);
                if (address == @intFromPtr(&radio.SHORTS)) Fixture.run_hook(&fx.before_shorts_write);
                const previous = self.raw;
                self.raw = value;
                Fixture.register_write(address, value, previous);
                if (address == @intFromPtr(&radio.SHORTS)) Fixture.run_hook(&fx.after_shorts_write);
            }
        };
    }
};

pub const interrupt = struct {
    const CriticalSection = struct {
        pub fn leave(_: CriticalSection) void {
            fx.mask_depth -= 1;
        }
    };

    pub fn enter_critical_section() CriticalSection {
        fx.mask_depth += 1;
        if (fx.on_mask) |callback| {
            fx.on_mask = null;
            callback();
        }
        return .{};
    }
};

pub const cpu = struct {
    pub const Interrupt = enum { RADIO, TIMER3 };

    pub const interrupt = struct {
        pub fn set_priority(_: Interrupt, _: enum { highest }) void {}

        pub fn enable(line: Interrupt) void {
            fx.enabled[@backingInt(line)] = true;
        }

        pub fn disable(line: Interrupt) void {
            fx.enabled[@backingInt(line)] = false;
        }

        pub fn set_pending(line: Interrupt) void {
            fx.pending[@backingInt(line)] = true;
        }

        pub fn clear_pending(line: Interrupt) void {
            fx.pending[@backingInt(line)] = false;
        }
    };
};

pub const hal = struct {
    pub const temp = struct {
        pub fn init() void {}
    };
    pub const timer = @import("hal/timer.zig");
    pub const ppi = struct {
        pub const Channel = enum(u5) {
            _,

            pub fn connect(channel: Channel, event: *volatile anyopaque, task: *volatile anyopaque, fork: ?*volatile anyopaque) error{FixedChannel}!void {
                if (@backingInt(channel) >= 20) return error.FixedChannel;
                std.debug.assert(fork == null);
                const route = &fx.routes[@backingInt(channel)];
                std.debug.assert(!route.enabled);
                route.event = @intFromPtr(event);
                route.task = @intFromPtr(task);
            }

            pub fn enable(channel: Channel) void {
                fx.routes[@backingInt(channel)].enabled = true;
            }

            pub fn disable(channel: Channel) void {
                const is_ack_route = fx.routes[@backingInt(channel)].enabled and
                    fx.routes[@backingInt(channel)].task == @intFromPtr(&radio.TASKS_TXEN);
                if (is_ack_route) Fixture.run_hook(&fx.before_ack_route_disable);
                if (fx.ppi_disable_stuck != @backingInt(channel)) fx.routes[@backingInt(channel)].enabled = false;
                if (is_ack_route) Fixture.run_hook(&fx.after_ack_route_disable);
            }

            pub fn enabled(channel: Channel) bool {
                return fx.routes[@backingInt(channel)].enabled;
            }
        };
    };
};

const Route = struct {
    event: usize = 0,
    task: usize = 0,
    enabled: bool = false,
};

pub var fx: Fixture = .{};

pub const Fixture = struct {
    const Producer = enum { none, packet_rx, packet_tx, cca, ed };
    const HeldLatch = enum { address, end, phyend, disabled };
    const Capture = struct { cc: u3, route: u5, tick: u32 };

    producer: Producer = .none,
    held: std.EnumSet(HeldLatch) = .empty,
    unseen: std.EnumSet(HeldLatch) = .empty,
    disable_completed_at: ?u32 = null,
    disable_completions: usize = 0,
    routes: [20]Route = @splat(.{}),
    ppi_disable_stuck: ?u5 = null,
    shorts_stuck: bool = false,
    mask_depth: usize = 0,
    on_mask: ?*const fn () void = null,
    on_after_normal: ?*const fn () void = null,
    disabled_samples: usize = 0,
    address_samples: usize = 0,
    on_disabled_read: ?*const fn () void = null,
    on_address_read: ?*const fn () void = null,
    after_address_sample: ?*const fn () void = null,
    before_shorts_write: ?*const fn () void = null,
    after_shorts_write: ?*const fn () void = null,
    before_ack_route_disable: ?*const fn () void = null,
    after_ack_route_disable: ?*const fn () void = null,
    on_settings_publish: ?*const fn () void = null,
    on_settings_tick: ?*const fn () void = null,
    on_disable: ?*const fn () void = null,
    on_radio_state_read: ?*const fn () void = null,
    hide_rx_departure_state: bool = false,
    on_end_read: ?*const fn () void = null,
    on_phyend_read: ?*const fn () void = null,
    on_backoff_departure: ?struct { boundary: Fixture.BackoffBoundary, call: *const fn () void } = null,
    on_rx_crc_read: ?*const fn () void = null,
    enabled: [2]bool = @splat(false),
    pending: [2]bool = @splat(false),
    tick: u32 = 0,
    timer_step: u32 = 1,
    rtc_step: u24 = 0,
    temp_stops: usize = 0,
    temp_starts: usize = 0,
    temp_retirement_stalls: bool = false,
    power_down_stalls: bool = false,
    timer_running: bool = false,
    timer_retirement_stalls: bool = false,
    ack_capture_stalls: bool = false,
    rxready_capture_stalls: bool = false,
    end_capture_stalls: bool = false,
    delayed_capture: ?Capture = null,
    hold_end_capture: bool = false,
    held_end_capture: ?Capture = null,
    rng_retirement_stalls: bool = false,
    rng_stops: usize = 0,
    disable_stalls: bool = false,
    lose_disabled_event: bool = false,
    defer_shortcut_disabled: bool = false,
    shortcut_disable_pending: bool = false,
    expire_on_compare_arm: ?u32 = null,
    tick_on_ack_compare_arm: ?u32 = null,
    capture_count: usize = 0,
    on_capture: ?struct { number: usize, call: *const fn () void } = null,
    jump_on_capture: usize = 0,
    jump_after_capture: usize = 0,
    jump_tick: u32 = 0,
    timer_stops: usize = 0,
    start: usize = 0,
    rx_enables: usize = 0,
    tx_enables: usize = 0,
    rxen_writes: usize = 0,
    txen_writes: usize = 0,
    on_packetptr_install: ?*const fn () void = null,
    on_packetptr_clear: ?*const fn () void = null,
    packetptr_writes: usize = 0,
    frequency_writes: usize = 0,
    tx_starts: usize = 0,
    cca_starts: usize = 0,
    ed_starts: usize = 0,
    disables: usize = 0,
    rssi_samples: bool = true,
    on_rssi_start: ?*const fn () void = null,
    rssistart_writes: usize = 0,
    on_rssi_clear: ?*const fn () void = null,

    pub fn reset() void {
        fx = .{};
        radio = std.mem.zeroes(regs.RADIO);
        clock = std.mem.zeroes(regs.CLOCK);
        temperature = std.mem.zeroes(regs.TEMP);
        timer = std.mem.zeroes(regs.TIMER0);
        rtc = std.mem.zeroes(regs.RTC0);
        rng = std.mem.zeroes(regs.RNG);
        ficr = std.mem.zeroes(regs.FICR);
    }

    pub fn advance(tick: u32) void {
        if (!fx.timer_running) return;
        const from = fx.tick;
        var serviced: u6 = 0;
        for (0..6) |_| {
            var next: ?usize = null;
            var distance = tick -% from;
            for (timer.CC, 0..) |cc, i| {
                const offset = cc.raw -% from;
                if (serviced & (@as(u6, 1) << @intCast(i)) == 0 and offset != 0 and offset <= distance) {
                    next = i;
                    distance = offset;
                }
            }
            const i = next orelse break;
            fx.tick = from +% distance;
            serviced |= @as(u6, 1) << @intCast(i);
            raise(&timer.EVENTS_COMPARE[i]);
        }
        fx.tick = tick;
    }

    pub fn dispatch(line: cpu.Interrupt, handler: *const fn () callconv(.c) void) bool {
        const index = @backingInt(line);
        if (fx.mask_depth != 0 or !fx.enabled[index]) return false;
        sample_irq_lines();
        if (!fx.pending[index]) return false;
        fx.pending[index] = false;
        handler();
        return true;
    }

    fn sample_irq_lines() void {
        fx.pending[@backingInt(cpu.Interrupt.RADIO)] =
            fx.pending[@backingInt(cpu.Interrupt.RADIO)] or radio_signal();
        fx.pending[@backingInt(cpu.Interrupt.TIMER3)] =
            fx.pending[@backingInt(cpu.Interrupt.TIMER3)] or timer_signal();
    }

    fn radio_signal() bool {
        const Mask = @TypeOf(radio.INTENSET).underlying_type;
        inline for (.{ "READY", "ADDRESS", "END", "DISABLED", "RSSIEND", "RXREADY", "TXREADY", "PHYEND", "EDEND", "CCAIDLE", "CCABUSY" }) |source| {
            if (radio.INTENSET.raw & (1 << @bitOffsetOf(Mask, source)) != 0 and
                @field(radio, "EVENTS_" ++ source).raw != 0) return true;
        }
        return false;
    }

    fn timer_signal() bool {
        const Mask = @TypeOf(timer.INTENSET).underlying_type;
        inline for (0..6) |cc| {
            const source = comptime std.fmt.comptimePrint("COMPARE{d}", .{cc});
            if (timer.INTENSET.raw & (1 << @bitOffsetOf(Mask, source)) != 0 and
                timer.EVENTS_COMPARE[cc].raw != 0) return true;
        }
        return false;
    }

    fn run_hook(hook: *?*const fn () void) void {
        if (hook.*) |callback| {
            hook.* = null;
            callback();
        }
    }

    pub const BackoffBoundary = enum { published, settled, released };

    pub fn backoff_departure(boundary: BackoffBoundary) void {
        if (fx.on_backoff_departure) |hook| {
            if (hook.boundary != boundary) return;
            fx.on_backoff_departure = null;
            hook.call();
        }
    }

    pub fn before_disabled_read() void {
        fx.disabled_samples += 1;
        run_hook(&fx.on_disabled_read);
    }

    pub fn before_address_read() void {
        fx.address_samples += 1;
        run_hook(&fx.on_address_read);
    }

    pub fn after_address_read() void {
        run_hook(&fx.after_address_sample);
    }

    pub fn after_normal() void {
        run_hook(&fx.on_after_normal);
    }

    pub fn before_settings_publish() void {
        if (fx.on_settings_publish) |callback| {
            fx.on_settings_publish = null;
            callback();
        }
    }

    pub fn after_settings_tick() void {
        run_hook(&fx.on_settings_tick);
    }

    pub fn set_rtc(tick: u24) void {
        rtc.COUNTER.raw = tick;
    }

    fn latch_kind(address: usize) ?HeldLatch {
        if (address == @intFromPtr(&radio.EVENTS_ADDRESS)) return .address;
        if (address == @intFromPtr(&radio.EVENTS_END)) return .end;
        if (address == @intFromPtr(&radio.EVENTS_PHYEND)) return .phyend;
        if (address == @intFromPtr(&radio.EVENTS_DISABLED)) return .disabled;
        return null;
    }

    pub fn hold_latch(event: anytype) void {
        const kind = latch_kind(@intFromPtr(event)).?;
        std.debug.assert(!fx.held.contains(kind) and !fx.unseen.contains(kind));
        fx.held.insert(kind);
    }

    pub fn reveal_latch(event: anytype) bool {
        const kind = latch_kind(@intFromPtr(event)).?;
        std.debug.assert(fx.held.contains(kind));
        fx.held.remove(kind);
        if (!fx.unseen.contains(kind)) return false;
        fx.unseen.remove(kind);
        inject_latch_only(event);
        return true;
    }

    // This bypasses hardware delivery, including PPI and SHORTS.
    pub fn inject_latch_only(event: anytype) void {
        event.raw = 1;
        sample_irq_lines();
    }

    fn deliver_ppi(address: usize) void {
        for (fx.routes, 0..) |route, index| {
            if (!route.enabled or route.event != address) continue;
            if (fx.ack_capture_stalls and address == @intFromPtr(&radio.EVENTS_ADDRESS)) continue;
            if (fx.rxready_capture_stalls and address == @intFromPtr(&radio.EVENTS_RXREADY)) continue;
            if (fx.end_capture_stalls and address == @intFromPtr(&radio.EVENTS_END)) continue;
            inline for (0..6) |cc| {
                if (route.task == @intFromPtr(&timer.TASKS_CAPTURE[cc])) {
                    if (fx.hold_end_capture and address == @intFromPtr(&radio.EVENTS_END)) {
                        std.debug.assert(fx.held_end_capture == null);
                        fx.held_end_capture = .{ .cc = cc, .route = @intCast(index), .tick = fx.tick };
                    } else {
                        timer.CC[cc].raw = fx.tick;
                    }
                }
            }
            if (route.task == @intFromPtr(&radio.TASKS_TXEN)) radio.TASKS_TXEN.write_raw(1);
        }
    }

    pub fn reveal_end_capture() void {
        const capture = fx.held_end_capture.?;
        std.debug.assert(fx.routes[capture.route].enabled);
        timer.CC[capture.cc].raw = capture.tick;
        fx.held_end_capture = null;
        fx.hold_end_capture = false;
    }

    pub fn raise(event: anytype) void {
        const address = @intFromPtr(event);
        if (address == @intFromPtr(&radio.EVENTS_ADDRESS)) {
            std.debug.assert(fx.producer == .packet_rx or fx.producer == .packet_tx);
        } else if (address == @intFromPtr(&radio.EVENTS_END)) {
            std.debug.assert(fx.producer == .packet_rx or fx.producer == .packet_tx);
            if (fx.producer == .packet_rx) fx.producer = .none;
        } else if (address == @intFromPtr(&radio.EVENTS_PHYEND)) {
            std.debug.assert(fx.producer == .packet_tx);
            fx.producer = .none;
        } else if (address == @intFromPtr(&radio.EVENTS_CCAIDLE) or address == @intFromPtr(&radio.EVENTS_CCABUSY)) {
            std.debug.assert(fx.producer == .cca);
            fx.producer = .none;
        } else if (address == @intFromPtr(&radio.EVENTS_EDEND)) {
            std.debug.assert(fx.producer == .ed);
            fx.producer = .none;
        }
        deliver_hardware_event(event);
    }

    // An impossible END can exercise revocation with its SHORTS and PPI
    // effects. Ordinary packets must take the checked raise() path.
    pub fn inject_unexpected_end() void {
        deliver_hardware_event(&radio.EVENTS_END);
    }

    pub fn inject_invalid_packet_tasks() void {
        std.debug.assert(fx.producer == .packet_rx);
        inject_replacement_enables();
        radio.TASKS_START.write_raw(1);
    }

    pub fn inject_replacement_enables() void {
        radio.TASKS_RXEN.write_raw(1);
        radio.TASKS_TXEN.write_raw(1);
    }

    fn hardware_state() @TypeOf(@as(@TypeOf(radio.STATE).underlying_type, undefined).STATE) {
        return @as(@TypeOf(radio.STATE).underlying_type, @bitCast(radio.STATE.raw)).STATE;
    }

    fn deliver_hardware_event(event: anytype) void {
        const addr = @intFromPtr(event);
        if (addr == @intFromPtr(&radio.EVENTS_TXREADY)) {
            std.debug.assert(hardware_state() == .TxRu);
            radio.STATE.write(.{ .STATE = .TxIdle });
        }
        if (addr == @intFromPtr(&radio.EVENTS_RXREADY) or addr == @intFromPtr(&radio.EVENTS_READY)) {
            const state = hardware_state();
            std.debug.assert(state == .RxIdle or state == .Rx);
        }
        deliver_ppi(addr);
        if (latch_kind(addr)) |kind| {
            if (fx.held.contains(kind)) {
                fx.unseen.insert(kind);
            } else {
                inject_latch_only(event);
            }
        } else {
            inject_latch_only(event);
        }
        const shorts = radio.SHORTS.read();
        if (addr == @intFromPtr(&radio.EVENTS_READY) and shorts.READY_EDSTART == .Enabled)
            radio.TASKS_EDSTART.write_raw(1);
        if (addr == @intFromPtr(&radio.EVENTS_RXREADY)) {
            if (shorts.RXREADY_START == .Enabled) radio.TASKS_START.write_raw(1);
            if (shorts.RXREADY_CCASTART == .Enabled) radio.TASKS_CCASTART.write_raw(1);
        }
        if (addr == @intFromPtr(&radio.EVENTS_TXREADY) and shorts.TXREADY_START == .Enabled)
            radio.TASKS_START.write_raw(1);
        if (addr == @intFromPtr(&radio.EVENTS_ADDRESS) and shorts.ADDRESS_RSSISTART == .Enabled)
            radio.TASKS_RSSISTART.write_raw(1);
        if (addr == @intFromPtr(&radio.EVENTS_CCAIDLE)) {
            if (shorts.CCAIDLE_STOP == .Enabled) radio.TASKS_STOP.write_raw(1);
            if (shorts.CCAIDLE_TXEN == .Enabled) radio.TASKS_TXEN.write_raw(1);
        }
        if ((addr == @intFromPtr(&radio.EVENTS_END) and shorts.END_DISABLE == .Enabled) or
            (addr == @intFromPtr(&radio.EVENTS_PHYEND) and shorts.PHYEND_DISABLE == .Enabled) or
            (addr == @intFromPtr(&radio.EVENTS_EDEND) and shorts.EDEND_DISABLE == .Enabled) or
            (addr == @intFromPtr(&radio.EVENTS_CCABUSY) and shorts.CCABUSY_DISABLE == .Enabled))
        {
            radio.TASKS_DISABLE.write_raw(1);
        }
        if (addr == @intFromPtr(&radio.EVENTS_DISABLED) and shorts.DISABLED_RSSISTOP == .Enabled)
            radio.TASKS_RSSISTOP.write_raw(1);
    }

    pub fn dispatch_ready_rx() void {
        std.debug.assert(hardware_state() == .RxRu);
        radio.STATE.write(.{ .STATE = .RxIdle });
        raise(&radio.EVENTS_RXREADY);
        raise(&radio.EVENTS_READY);
    }

    pub fn complete_shortcut() void {
        std.debug.assert(fx.shortcut_disable_pending);
        finish_disable();
    }

    pub fn inject_unexpected_disabled() void {
        fx.producer = .none;
        radio.STATE.write(.{ .STATE = .Disabled });
        inject_latch_only(&radio.EVENTS_DISABLED);
    }

    fn finish_disable() void {
        fx.shortcut_disable_pending = false;
        fx.producer = .none;
        fx.disable_completed_at = fx.tick;
        fx.disable_completions += 1;
        radio.STATE.write(.{ .STATE = .Disabled });
        if (!fx.lose_disabled_event) raise(&radio.EVENTS_DISABLED);
    }

    fn register_write(address: usize, value: u32, previous: u32) void {
        if (address == @intFromPtr(&radio.SHORTS) and fx.shorts_stuck) radio.SHORTS.raw = previous;
        if (address == @intFromPtr(&radio.PACKETPTR)) {
            fx.packetptr_writes += 1;
            if (value != 0) run_hook(&fx.on_packetptr_install) else run_hook(&fx.on_packetptr_clear);
        }
        if (address == @intFromPtr(&radio.FREQUENCY)) fx.frequency_writes += 1;
        inline for (.{ &radio, &timer, &temperature, &rng }) |peripheral| {
            if (address == @intFromPtr(&peripheral.INTENSET)) {
                peripheral.INTENSET.raw |= previous;
                sample_irq_lines();
            }
            if (address == @intFromPtr(&peripheral.INTENCLR)) peripheral.INTENSET.raw &= ~value;
        }
        if (address == @intFromPtr(&radio.EVENTS_RSSIEND) and value == 0) {
            if (fx.on_rssi_clear) |callback| {
                fx.on_rssi_clear = null;
                callback();
            }
        }
        if (address == @intFromPtr(&rng.EVENTS_VALRDY) and value == 0 and rng.TASKS_START.raw != 0)
            rng.EVENTS_VALRDY.raw = 1;
        if (value == 0) {
            if (address == @intFromPtr(&radio.POWER)) {
                if (fx.power_down_stalls) {
                    radio.POWER.raw = previous;
                } else {
                    radio = std.mem.zeroes(regs.RADIO);
                    fx.producer = .none;
                    fx.shortcut_disable_pending = false;
                }
            }
            if (address == @intFromPtr(&temperature.EVENTS_DATARDY) and fx.temp_retirement_stalls)
                temperature.EVENTS_DATARDY.raw = 1;
            return;
        }
        if (address == @intFromPtr(&clock.TASKS_HFCLKSTART)) clock.HFCLKSTAT.write(.{ .SRC = .Xtal, .STATE = .Running });
        if (address == @intFromPtr(&temperature.TASKS_START)) {
            temperature.EVENTS_DATARDY.raw = 1;
            fx.temp_starts += 1;
        }
        if (address == @intFromPtr(&temperature.TASKS_STOP)) fx.temp_stops += 1;
        if (address == @intFromPtr(&rng.TASKS_START)) rng.EVENTS_VALRDY.raw = 1;
        if (address == @intFromPtr(&rng.TASKS_STOP)) {
            fx.rng_stops += 1;
            if (!fx.rng_retirement_stalls) rng.TASKS_START.raw = 0;
        }
        // PS v1.11 §6.20 RADIO, Radio states diagram and IEEE 802.15.4
        // CCA sequence. CCAIDLE stops RX before its TXEN shortcut runs.
        if (address == @intFromPtr(&radio.TASKS_RXEN)) {
            fx.rxen_writes += 1;
            if (hardware_state() != .Disabled) return;
            fx.rx_enables += 1;
            fx.producer = .none;
            radio.STATE.write(.{ .STATE = .RxRu });
        }
        if (address == @intFromPtr(&radio.TASKS_TXEN)) {
            fx.txen_writes += 1;
            const state = hardware_state();
            if (state != .Disabled and state != .RxIdle) return;
            fx.tx_enables += 1;
            fx.producer = .none;
            radio.STATE.write(.{ .STATE = .TxRu });
        }
        if (address == @intFromPtr(&radio.TASKS_CCASTART) or address == @intFromPtr(&radio.TASKS_EDSTART)) {
            if (hardware_state() != .RxIdle) return;
            radio.STATE.write(.{ .STATE = .Rx });
            if (address == @intFromPtr(&radio.TASKS_CCASTART)) {
                fx.producer = .cca;
                fx.cca_starts += 1;
            } else {
                fx.producer = .ed;
                fx.ed_starts += 1;
            }
        }
        if (address == @intFromPtr(&radio.TASKS_STOP)) {
            switch (hardware_state()) {
                .Rx => radio.STATE.write(.{ .STATE = .RxIdle }),
                .Tx => radio.STATE.write(.{ .STATE = .TxIdle }),
                else => return,
            }
            fx.producer = .none;
        }
        if (address == @intFromPtr(&radio.TASKS_DISABLE)) {
            fx.disables += 1;
            if (fx.on_disable) |callback| {
                fx.on_disable = null;
                callback();
            }
            // PS v1.11 §6.20 RADIO, Radio states diagram. DISABLE
            // has no new transition from Disabled or ramp-down.
            const state = hardware_state();
            if (state == .Disabled or state == .RxDisable or state == .TxDisable) return;
            if (fx.defer_shortcut_disabled) {
                fx.shortcut_disable_pending = true;
                fx.producer = .none;
                radio.STATE.write(.{ .STATE = if (state == .Tx or state == .TxRu or state == .TxIdle) .TxDisable else .RxDisable });
            } else if (fx.lose_disabled_event) {
                finish_disable();
            } else if (!fx.disable_stalls) {
                finish_disable();
            }
        }
        if (address == @intFromPtr(&radio.TASKS_START)) {
            switch (hardware_state()) {
                .TxIdle => {
                    fx.tx_starts += 1;
                    fx.producer = .packet_tx;
                    radio.STATE.write(.{ .STATE = .Tx });
                },
                .RxIdle => {
                    fx.producer = .packet_rx;
                    radio.STATE.write(.{ .STATE = .Rx });
                },
                else => return,
            }
            fx.start += 1;
        }
        if (address == @intFromPtr(&radio.TASKS_RSSISTART)) {
            fx.rssistart_writes += 1;
            if (fx.rssi_samples) radio.EVENTS_RSSIEND.raw = 1;
            if (fx.on_rssi_start) |callback| {
                fx.on_rssi_start = null;
                callback();
            }
        }
        if (address == @intFromPtr(&timer.TASKS_CLEAR)) fx.tick = 0;
        if (address == @intFromPtr(&timer.TASKS_START)) fx.timer_running = true;
        if (address == @intFromPtr(&timer.TASKS_STOP)) {
            fx.timer_stops += 1;
            if (!fx.timer_retirement_stalls) fx.timer_running = false;
        }
        if (address == @intFromPtr(&timer.CC[0])) {
            if (fx.tick_on_ack_compare_arm) |tick| {
                fx.tick_on_ack_compare_arm = null;
                advance(tick);
            }
        }
        if (address == @intFromPtr(&timer.CC[1]) and fx.expire_on_compare_arm == value) {
            fx.expire_on_compare_arm = null;
            advance(value);
        }
        inline for (0..6) |cc| {
            if (address == @intFromPtr(&timer.TASKS_CAPTURE[cc])) {
                fx.capture_count += 1;
                if (fx.on_capture) |callback| {
                    if (callback.number == fx.capture_count) {
                        fx.on_capture = null;
                        callback.call();
                    }
                }
                if (fx.jump_on_capture == fx.capture_count) advance(fx.jump_tick);
                if (fx.timer_running) advance(fx.tick +% fx.timer_step);
                timer.CC[cc].raw = fx.tick;
                if (fx.jump_after_capture == fx.capture_count) advance(fx.jump_tick);
            }
        }
    }
};
