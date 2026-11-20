//! ESP32-C6 TRM v1.2 §11.3.2–11.3.5 and §7.14.
//! Polling-free event/task routing; the caller owns the selected channels/pads.
const std = @import("std");
const microzig = @import("microzig");
const gpio = @import("gpio.zig");
const system = @import("system.zig");
comptime {
    if (@import("compatibility.zig").chip != .esp32_c6) @compileError("ETM requires ESP32-C6");
}
const ETM = microzig.chip.peripherals.SOC_ETM;
const GPIO_SD = microzig.chip.peripherals.GPIO_SD;

pub fn apply() void {
    system.enable_clocks_and_release_reset(.{ .etm = true });
}

/// IDs from TRM Tables 11.3-1/11.3-2. Peripheral event/task enables
/// must also be configured. GPIO helpers below return these typed IDs.
pub const Event = enum(u8) { gpio0_rising = 1, gpio0_falling = 9, gpio0_any = 17, _ };
pub const Task = enum(u8) {
    gpio0_set = 1,
    gpio0_clear = 9,
    gpio0_toggle = 17,
    // TRM Table 11.3-2 / §3.8, IDF soc_etm_source.h ULP_TASK_WAKEUP_CPU.
    lp_cpu_wake = 154,
    _,
};
pub const Edge = enum(u8) { rising = 1, falling = 9, any = 17 };
pub const Action = enum(u8) { set = 1, clear = 9, toggle = 17 };

/// Configure one of eight GPIO event sources. Pad input must be enabled.
/// Disable any matrix channels consuming this source before rebinding it.
pub fn gpio_event(comptime index: u3, pin: gpio.Pin, edge: Edge) Event {
    const reg = &@field(GPIO_SD, std.fmt.comptimePrint("ETM_EVENT_CH{d}_CFG", .{index}));
    reg.modify(.{ .ETM_CH0_EVENT_EN = 0 });
    reg.write(.{ .ETM_CH0_EVENT_SEL = @backingInt(pin), .ETM_CH0_EVENT_EN = 1 });
    return @fromBackingInt(@intCast(@backingInt(edge) + @as(u8, index)));
}

/// Bind a pad to one of eight GPIO task groups; several pads can share a group.
/// Configure the pad as a GPIO output first. Disable its matrix route to unbind.
pub fn gpio_task(comptime pin: u5, index: u3, action: Action, enabled: bool) Task {
    if (pin >= 31) @compileError("invalid C6 GPIO");
    const reg = &@field(GPIO_SD, std.fmt.comptimePrint("ETM_TASK_P{d}_CFG", .{pin / 4}));
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    var value = reg.read();
    @field(value, std.fmt.comptimePrint("ETM_TASK_GPIO{d}_EN", .{pin})) = @intFromBool(enabled);
    @field(value, std.fmt.comptimePrint("ETM_TASK_GPIO{d}_SEL", .{pin})) = index;
    reg.write(value);
    return @fromBackingInt(@intCast(@backingInt(action) + @as(u8, index)));
}

pub fn channel(comptime index: u6) Channel {
    if (index >= 50) @compileError("ETM channel must be 0..49");
    return @fromBackingInt(@intCast(index));
}
pub const Channel = enum(u6) {
    channel0 = 0,
    channel1 = 1,
    channel2 = 2,
    channel3 = 3,
    channel4 = 4,
    channel5 = 5,
    channel6 = 6,
    channel7 = 7,
    channel8 = 8,
    channel9 = 9,
    channel10 = 10,
    channel11 = 11,
    channel12 = 12,
    channel13 = 13,
    channel14 = 14,
    channel15 = 15,
    channel16 = 16,
    channel17 = 17,
    channel18 = 18,
    channel19 = 19,
    channel20 = 20,
    channel21 = 21,
    channel22 = 22,
    channel23 = 23,
    channel24 = 24,
    channel25 = 25,
    channel26 = 26,
    channel27 = 27,
    channel28 = 28,
    channel29 = 29,
    channel30 = 30,
    channel31 = 31,
    channel32 = 32,
    channel33 = 33,
    channel34 = 34,
    channel35 = 35,
    channel36 = 36,
    channel37 = 37,
    channel38 = 38,
    channel39 = 39,
    channel40 = 40,
    channel41 = 41,
    channel42 = 42,
    channel43 = 43,
    channel44 = 44,
    channel45 = 45,
    channel46 = 46,
    channel47 = 47,
    channel48 = 48,
    channel49 = 49,

    /// Disables the route before replacing IDs. Call enable(true) to arm it.
    pub fn apply(self: Channel, event: Event, task: Task) error{InvalidId}!void {
        if (@backingInt(event) == 0 or @backingInt(task) == 0) return error.InvalidId;
        self.enable(false);
        // §11.4: event/task register pairs have an eight-byte stride.
        const Registers = extern struct { event: @TypeOf(ETM.CH0_EVT_ID), task: @TypeOf(ETM.CH0_TASK_ID) };
        const routes: *volatile [50]Registers = @ptrCast(&ETM.CH0_EVT_ID);
        routes[@backingInt(self)].event.write_raw(@backingInt(event));
        routes[@backingInt(self)].task.write_raw(@backingInt(task));
    }

    pub fn enable(self: Channel, enabled: bool) void {
        const n = @backingInt(self);
        // SET/CLR are write-one commands (§11.3.5); never read-modify-write.
        const mask = @as(u32, 1) << @as(u5, @truncate(n));
        if (n < 32) {
            if (enabled) ETM.CH_ENA_AD0_SET.write_raw(mask) else ETM.CH_ENA_AD0_CLR.write_raw(mask);
        } else {
            if (enabled) ETM.CH_ENA_AD1_SET.write_raw(mask) else ETM.CH_ENA_AD1_CLR.write_raw(mask);
        }
    }
};
