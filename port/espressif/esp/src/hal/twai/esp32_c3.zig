const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const twai = @import("../twai.zig");
pub const controller_count = 1;
pub fn Instance(comptime index: usize) type {
    if (index >= controller_count) @compileError("TWAI controller does not exist on this chip");
    return struct {
        pub const regs = microzig.chip.peripherals.TWAI;
        pub fn init(config: twai.Config) void {
            hal.system.clocks_enable_set(.{ .twai = true });
            hal.system.peripheral_reset(.{ .twai = true });
            regs.MODE.modify(.{ .RESET_MODE = 1 });
            regs.INT_ENA.write_raw(0);
            regs.CLOCK_DIVIDER.modify(.{ .CLOCK_OFF = 1 });
            regs.BUS_TIMING_0.write(.{ .BAUD_PRESC = config.timing.prescaler, .SYNC_JUMP_WIDTH = 0 });
            regs.BUS_TIMING_1.write(.{ .TIME_SEG1 = config.timing.segment1, .TIME_SEG2 = config.timing.segment2, .TIME_SAMP = 0 });
            regs.ERR_WARNING_LIMIT.write(.{ .ERR_WARNING_LIMIT = 96 });
            regs.RX_ERR_CNT.write(.{ .RX_ERR_CNT = 0 });
            regs.TX_ERR_CNT.write(.{ .TX_ERR_CNT = 0 });
            inline for (0..4) |i| {
                @field(regs, std.fmt.comptimePrint("DATA_{d}", .{i})).write_raw(@as(u8, @truncate(config.filter.code >> (24 - 8 * i))));
                @field(regs, std.fmt.comptimePrint("DATA_{d}", .{i + 4})).write_raw(@as(u8, @truncate(config.filter.mask >> (24 - 8 * i))));
            }
            config.tx.apply(.{ .output_enable = true, .input_enable = config.tx == config.rx });
            if (config.rx != config.tx) config.rx.apply(.{ .input_enable = true });
            config.tx.connect_peripheral_to_output(.{ .signal = .twai_tx });
            config.rx.connect_input_to_peripheral(.{ .signal = .twai_rx });
            regs.MODE.write(.{
                .RESET_MODE = 0,
                .LISTEN_ONLY_MODE = @intFromBool(config.mode == .listen_only),
                .SELF_TEST_MODE = @intFromBool(config.mode == .self_test),
                .RX_FILTER_MODE = @intFromBool(config.filter.mode == .single),
            });
        }
        pub fn deinit() void {
            regs.MODE.modify(.{ .RESET_MODE = 1 });
            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();
            hal.system.peripheral_reset_set(.{ .twai = true });
            hal.system.clocks_enable_clear(.{ .twai = true });
        }
        pub fn status() struct { bus_off: u1, tx_free: u1, tx_complete: u1, rx_ready: u1, miss: u1 } {
            const value = regs.STATUS.read();
            return .{ .bus_off = value.BUS_OFF_ST, .tx_free = value.TX_BUF_ST, .tx_complete = value.TX_COMPLETE, .rx_ready = value.RX_BUF_ST, .miss = value.MISS_ST };
        }
        pub fn message_count() u8 {
            return regs.RX_MESSAGE_CNT.read().RX_MESSAGE_COUNTER;
        }
        pub fn begin_recovery() void {
            regs.MODE.modify(.{ .RESET_MODE = 0 });
        }
        pub fn start_transmit(self_receive: bool) void {
            regs.CMD.write(.{ .TX_REQ = @intFromBool(!self_receive), .SELF_RX_REQ = @intFromBool(self_receive), .ABORT_TX = 0, .RELEASE_BUF = 0, .CLR_OVERRUN = 0 });
        }
        pub fn command(action: twai.Command) void {
            regs.CMD.write(.{ .TX_REQ = 0, .SELF_RX_REQ = 0, .ABORT_TX = @intFromBool(action == .abort_tx), .RELEASE_BUF = @intFromBool(action == .release_rx), .CLR_OVERRUN = @intFromBool(action == .clear_overrun) });
        }
    };
}
