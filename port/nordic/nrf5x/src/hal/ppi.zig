//! nRF52840 PPI (Product Specification v1.11, §6.16).
const microzig = @import("microzig");
const compatibility = @import("compatibility.zig");
const Regs = microzig.chip.types.peripherals.PPI;

fn regs() *volatile Regs {
    if (compatibility.chip != .nrf52840) compatibility.unsupported_chip("PPI");
    return microzig.chip.peripherals.PPI;
}

pub const Channel = enum(u5) {
    // The primary event/task pair is wired in hardware (PS §6.16.1, Table 2).
    timer0_compare0_radio_txen = 20,
    timer0_compare0_radio_rxen = 21,
    timer0_compare1_radio_disable = 22,
    radio_bcmatch_aar_start = 23,
    radio_ready_ccm_ksgen = 24,
    radio_address_ccm_crypt = 25,
    radio_address_timer0_capture1 = 26,
    radio_end_timer0_capture2 = 27,
    rtc0_compare0_radio_txen = 28,
    rtc0_compare0_radio_rxen = 29,
    rtc0_compare0_timer0_clear = 30,
    rtc0_compare0_timer0_start = 31,
    _, // 0–19 are programmable.

    pub fn mask(channel: Channel) u32 {
        return @as(u32, 1) << @backingInt(channel);
    }

    pub fn enabled(channel: Channel) bool {
        return regs().CHEN.raw & channel.mask() != 0;
    }

    pub fn enable(channel: Channel) void {
        regs().CHENSET.write_raw(channel.mask());
    }

    pub fn disable(channel: Channel) void {
        regs().CHENCLR.write_raw(channel.mask());
    }

    /// Program a disabled channel using addresses of generated event and task
    /// registers. Keep any group enable tasks for the channel quiescent during
    /// configuration. A null fork removes the second task.
    pub fn connect(
        channel: Channel,
        event: *volatile anyopaque,
        task: *volatile anyopaque,
        fork: ?*volatile anyopaque,
    ) error{FixedChannel}!void {
        const r = regs();
        const i = @backingInt(channel);
        if (i >= r.CH.len) return error.FixedChannel;

        r.CH[i].EEP.write(.{ .EEP = @intFromPtr(event) });
        r.CH[i].TEP.write(.{ .TEP = @intFromPtr(task) });
        channel.set_fork(fork);
    }

    /// Set or remove the second task of a disabled programmable or fixed channel.
    pub fn set_fork(channel: Channel, task: ?*volatile anyopaque) void {
        regs().FORK[@backingInt(channel)].TEP.write(.{ .TEP = if (task) |t| @intFromPtr(t) else 0 });
    }
};

pub const Group = enum(u3) {
    group0,
    group1,
    group2,
    group3,
    group4,
    group5,

    /// Replace group membership without changing channel enable bits.
    pub fn set_channels(group: Group, channels: u32) void {
        regs().CHG[@backingInt(group)].write_raw(channels);
    }

    pub fn enable(group: Group) void {
        regs().TASKS_CHG[@backingInt(group)].EN.write_raw(1);
    }

    pub fn disable(group: Group) void {
        regs().TASKS_CHG[@backingInt(group)].DIS.write_raw(1);
    }

    pub fn enable_endpoint(group: Group) *volatile anyopaque {
        return &regs().TASKS_CHG[@backingInt(group)].EN;
    }

    pub fn disable_endpoint(group: Group) *volatile anyopaque {
        return &regs().TASKS_CHG[@backingInt(group)].DIS;
    }
};
