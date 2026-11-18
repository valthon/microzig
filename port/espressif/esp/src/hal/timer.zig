//! ESP32-C3/C6 timer0 in each timer group.
//! C3 TRM v1.4 §§11.2–11.3; C6 TRM v1.2 §§14.2–14.3.
//! The caller owns the group; serialize access with any interrupt handler.

const chip_specific = switch (@import("compatibility.zig").chip) {
    .esp32_c3 => @import("timer/esp32_c3.zig"),
    .esp32_c6 => @import("timer/esp32_c6.zig"),
};

const microzig = @import("microzig");
const system = @import("system.zig");
const peripherals = microzig.chip.peripherals;

pub const Group = enum(u1) {
    timg0,
    timg1,

    pub fn registers(self: Group) @TypeOf(peripherals.TIMG0) {
        return switch (self) {
            .timg0 => peripherals.TIMG0,
            .timg1 => @ptrCast(peripherals.TIMG1),
        };
    }

    /// Releases reset without resetting the other timer/watchdog in this group.
    pub fn enable_clock(self: Group) void {
        system.enable_clocks_and_release_reset(switch (self) {
            .timg0 => .{ .timergroup0 = true },
            .timg1 => .{ .timergroup1 = true },
        });
    }

    pub fn interrupt_source(self: Group) microzig.cpu.interrupt.Source {
        return switch (self) {
            .timg0 => .tg0_t0_level,
            .timg1 => .tg1_t0_level,
        };
    }

    pub const Config = struct {
        /// Zero encodes 65536; one and two both divide by two
        /// (C3 TRM v1.4 §11.2.1; C6 TRM v1.2 §14.3.1).
        divider: u16 = 80,
        /// Select 40 MHz XTAL instead of 80 MHz APB (C3) / PLL_F80M (C6).
        use_xtal: bool = false,
        increase: bool = true,
    };

    /// Configures a stopped timer with alarm and auto-reload disabled.
    pub fn configure(self: Group, config: Config) void {
        self.enable_clock();
        const r = self.registers();
        r.REGCLK.modify(.{ .TIMER_CLK_IS_ACTIVE = 1 });
        self.set_enabled(false);
        chip_specific.configure_timer(self, config);
        chip_specific.reset_divider(r);
        self.set_interrupt_enabled(false);
        self.clear_interrupt();
        self.set_reload(0);
        self.reload();
    }

    pub fn set_enabled(self: Group, enabled: bool) void {
        chip_specific.set_enabled(self.registers(), enabled);
    }

    /// Bounded latch wait; the caller must serialize concurrent snapshot requests.
    pub fn read(self: Group) error{Timeout}!u54 {
        return chip_specific.read(self.registers());
    }

    pub fn set_reload(self: Group, value: u54) void {
        chip_specific.set_reload(self.registers(), value);
    }

    pub fn reload(self: Group) void {
        chip_specific.reload(self.registers());
    }

    /// Disables the comparator while updating its two halves; call arm_alarm next.
    pub fn set_alarm(self: Group, value: u54, auto_reload: bool) void {
        chip_specific.set_alarm(self.registers(), value, auto_reload);
    }

    /// Hardware clears alarm enable on every firing, including auto-reload mode.
    pub fn arm_alarm(self: Group) void {
        chip_specific.arm_alarm(self.registers());
    }

    pub fn set_interrupt_enabled(self: Group, enabled: bool) void {
        self.registers().INT_ENA_TIMERS.modify(.{ .T0_INT_ENA = @intFromBool(enabled) });
    }

    pub fn interrupt_raw(self: Group) bool {
        return self.registers().INT_RAW_TIMERS.read().T0_INT_RAW != 0;
    }

    pub fn interrupt_status(self: Group) bool {
        return self.registers().INT_ST_TIMERS.read().T0_INT_ST != 0;
    }

    pub fn clear_interrupt(self: Group) void {
        self.registers().INT_CLR_TIMERS.write(.{ .T0_INT_CLR = 1, .WDT_INT_CLR = 0 });
    }
};
