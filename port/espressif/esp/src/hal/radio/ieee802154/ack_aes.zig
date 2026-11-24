//! C6 TRM v1.2 §§19.4.2–19.4.3, Typical AES (CPU, no DMA).
//! Private to enhanced-ACK generation, with interrupts masked by the caller.
//! hal.aes also masks interrupts for its entire operation, so the ISR cannot
//! interrupt a task using AES. DS/other direct crypto users must be idle.
const std = @import("std");
const microzig = @import("microzig");
const system = @import("../../system.zig");
const security = @import("security.zig");
const aes = microzig.chip.peripherals.AES;
const key_names = .{ "KEY_0", "KEY_1", "KEY_2", "KEY_3", "KEY_4", "KEY_5", "KEY_6", "KEY_7" };

pub const Cipher = struct {
    pub fn init(key: [16]u8) Cipher {
        system.enable_clocks_and_release_reset(.{ .crypto_aes = true });
        // Same DS reset dependency as hal.aes / IDF aes_ll_reset_register.
        system.peripheral_reset_clear(.{ .crypto_ds = true });
        system.peripheral_reset(.{ .crypto_aes = true });
        aes.DMA_ENABLE.write(.{ .DMA_ENABLE = 0 });
        aes.MODE.write(.{ .MODE = 0 });
        inline for (key_names, 0..) |name, i| {
            if (i < 4) @field(aes, name).raw = std.mem.readInt(u32, key[i * 4 ..][0..4], .little);
        }
        return .{};
    }

    pub fn deinit(_: Cipher) void {
        inline for (key_names) |name| @field(aes, name).raw = 0;
        system.peripheral_reset(.{ .crypto_aes = true });
    }

    pub fn encrypt(_: Cipher, output: *[16]u8, input: *const [16]u8) security.Error!void {
        inline for (.{ "TEXT_IN_0", "TEXT_IN_1", "TEXT_IN_2", "TEXT_IN_3" }, 0..) |name, i|
            @field(aes, name).raw = std.mem.readInt(u32, input[i * 4 ..][0..4], .little);
        aes.TRIGGER.write(.{ .TRIGGER = 1 });
        // A short, fixed bound: do not inherit the task AES driver's 100,000
        // polls inside the turnaround ISR. Failure stops ACK generation.
        for (0..256) |_| {
            if (aes.STATE.read().STATE == 0) {
                inline for (.{ "TEXT_OUT_0", "TEXT_OUT_1", "TEXT_OUT_2", "TEXT_OUT_3" }, 0..) |name, i|
                    std.mem.writeInt(u32, output[i * 4 ..][0..4], @field(aes, name).raw, .little);
                return;
            }
        }
        return error.CryptoTimeout;
    }
};
