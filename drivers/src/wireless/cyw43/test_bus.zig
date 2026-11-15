//! Fake SPI peer for host tests of synchronous ioctl replies.
const std = @import("std");
const bus = @import("bus.zig");
const consts = @import("consts.zig");

pub const TestBus = struct {
    reply: bool = true,
    empty_polls: usize = 0,
    polls: usize = 0,
    writes: usize = 0,
    payload: []const u8 = &.{},
    packet: [512]u32 = @splat(0),

    pub fn spi(self: *TestBus) bus.CYW43_SPI {
        return .{ .ptr = self, .vtable = &.{
            .spi_read_blocking_fn = read,
            .spi_write_blocking_fn = write,
        } };
    }

    pub fn delay(_: u32) void {}

    fn read(ctx: *anyopaque, cmd: u32, buffer: []u32) u32 {
        const self: *TestBus = @ptrCast(@alignCast(ctx));
        const function = (cmd >> 28) & 3;
        if (function == 0) {
            std.debug.assert(((cmd >> 11) & 0x1ffff) == consts.REG_BUS_STATUS);
            buffer[0] = 0;
            if (self.reply and self.polls >= self.empty_polls) {
                const len: u32 = @intCast(28 + self.payload.len);
                buffer[0] = consts.STATUS_F2_PKT_AVAILABLE |
                    (len << consts.STATUS_F2_PKT_LEN_SHIFT);
            }
            self.polls += 1;
        } else {
            std.debug.assert(function == 2);
            @memcpy(buffer, self.packet[0..buffer.len]);
        }
        return 0;
    }

    fn write(ctx: *anyopaque, words: []const u32) u32 {
        const self: *TestBus = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        const request = std.mem.sliceAsBytes(words[1..]);
        const packet = std.mem.sliceAsBytes(&self.packet);
        @memset(packet, 0);
        const len: u16 = @intCast(28 + self.payload.len);
        std.mem.writeInt(u16, packet[0..2], len, .little);
        std.mem.writeInt(u16, packet[2..4], ~len, .little);
        packet[7] = 12; // SDPCM header length, control channel is zero.
        packet[9] = request[4] +% 2; // Allow the next request.
        @memcpy(packet[12..28], request[12..28]); // Echo CDC command and ID.
        std.mem.writeInt(u32, packet[16..20], @intCast(self.payload.len), .little);
        @memcpy(packet[28..][0..self.payload.len], self.payload);
        return 0;
    }
};
