// C6 TRM v1.2 §§8.5.1 (PCR TWAI0/1_CONF and FUNC_CLK_CONF),
// 33.3–33.6: separate register banks, XTAL functional clock and GPIO routes.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const twai = @import("../twai.zig");
pub const controller_count = 2;
pub fn Instance(comptime index: usize) type {
    if (index >= controller_count) @compileError("TWAI controller does not exist on this chip");
    return struct {
        const mask: hal.system.PeripheralMask = if (index == 0) .{ .twai0 = true } else .{ .twai1 = true };
        pub const regs = if (index == 0) microzig.chip.peripherals.TWAI0 else microzig.chip.peripherals.TWAI1;
        pub fn init(config: twai.Config) void {
            hal.system.clocks_enable_set(mask);
            hal.system.peripheral_reset(mask);
            if (index == 0) {
                microzig.chip.peripherals.PCR.TWAI0_FUNC_CLK_CONF.modify(.{ .TWAI0_FUNC_CLK_SEL = 0, .TWAI0_FUNC_CLK_EN = 1 });
            } else {
                microzig.chip.peripherals.PCR.TWAI1_FUNC_CLK_CONF.modify(.{ .TWAI1_FUNC_CLK_SEL = 0, .TWAI1_FUNC_CLK_EN = 1 });
            }
            regs.MODE.modify(.{ .RESET_MODE = 1 });
            regs.INTERRUPT_ENABLE.write_raw(0);
            regs.CLOCK_DIVIDER.modify(.{ .CLOCK_OFF = 1 });
            regs.BUS_TIMING_0.write(.{ .BAUD_PRESC = config.timing.prescaler, .SYNC_JUMP_WIDTH = 0 });
            regs.BUS_TIMING_1.write(.{ .TIME_SEGMENT1 = config.timing.segment1, .TIME_SEGMENT2 = config.timing.segment2, .TIME_SAMPLING = 0 });
            regs.ERR_WARNING_LIMIT.write(.{ .ERR_WARNING_LIMIT = 96 });
            regs.RX_ERR_CNT.write(.{ .RX_ERR_CNT = 0 });
            regs.TX_ERR_CNT.write(.{ .TX_ERR_CNT = 0 });
            inline for (0..4) |i| {
                @field(regs, std.fmt.comptimePrint("DATA_{d}", .{i})).write_raw(@as(u8, @truncate(config.filter.code >> (24 - 8 * i))));
                @field(regs, std.fmt.comptimePrint("DATA_{d}", .{i + 4})).write_raw(@as(u8, @truncate(config.filter.mask >> (24 - 8 * i))));
            }
            config.tx.apply(.{ .output_enable = true, .input_enable = config.tx == config.rx });
            if (config.rx != config.tx) config.rx.apply(.{ .input_enable = true });
            config.tx.connect_peripheral_to_output(.{ .signal = if (index == 0) .twai0_tx else .twai1_tx });
            config.rx.connect_input_to_peripheral(.{ .signal = if (index == 0) .twai0_rx else .twai1_rx });
            regs.MODE.write(.{
                .RESET_MODE = 0,
                .LISTEN_ONLY_MODE = @intFromBool(config.mode == .listen_only),
                .SELF_TEST_MODE = @intFromBool(config.mode == .self_test),
                .ACCEPTANCE_FILTER_MODE = @intFromBool(config.filter.mode == .single),
            });
        }
        pub fn deinit() void {
            regs.MODE.modify(.{ .RESET_MODE = 1 });
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            hal.system.peripheral_reset_set(mask);
            hal.system.clocks_enable_clear(mask);
            if (index == 0) {
                microzig.chip.peripherals.PCR.TWAI0_FUNC_CLK_CONF.modify(.{ .TWAI0_FUNC_CLK_EN = 0 });
            } else {
                microzig.chip.peripherals.PCR.TWAI1_FUNC_CLK_CONF.modify(.{ .TWAI1_FUNC_CLK_EN = 0 });
            }
        }
        pub fn status() struct { bus_off: u1, tx_free: u1, tx_complete: u1, rx_ready: u1, miss: u1 } {
            const value = regs.STATUS.read();
            return .{ .bus_off = value.NODE_BUS_OFF, .tx_free = value.TRANSMIT_BUFFER, .tx_complete = value.TRANSMISSION_COMPLETE, .rx_ready = value.RECEIVE_BUFFER, .miss = value.MISS };
        }
        pub fn message_count() u8 {
            return regs.RX_MESSAGE_COUNTER.read().RX_MESSAGE_COUNTER;
        }
        pub fn begin_recovery() void {
            regs.MODE.modify(.{ .RESET_MODE = 0 });
        }
        pub fn start_transmit(self_receive: bool) void {
            regs.CMD.write(.{ .TX_REQUEST = @intFromBool(!self_receive), .SELF_RX_REQUEST = @intFromBool(self_receive), .ABORT_TX = 0, .RELEASE_BUFFER = 0, .CLEAR_DATA_OVERRUN = 0 });
        }
        pub fn command(action: twai.Command) void {
            regs.CMD.write(.{ .TX_REQUEST = 0, .SELF_RX_REQUEST = 0, .ABORT_TX = @intFromBool(action == .abort_tx), .RELEASE_BUFFER = @intFromBool(action == .release_rx), .CLEAR_DATA_OVERRUN = @intFromBool(action == .clear_overrun) });
        }
    };
}
