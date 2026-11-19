//! ESP32-C6 TRM v1.2 §19.4: CPU block transforms; same interface on C3.
//! §19.5's six SP 800-38A modes are chained in software: the hardware mode
//! controller requires DMA. No padding, authentication, allocation or eFuse use.
//! Call only from thread context, exclusively against DS and other crypto users.
const std = @import("std");
const microzig = @import("microzig");
const system = @import("system.zig");
const AES = microzig.chip.peripherals.AES;
const key_names = .{ "KEY_0", "KEY_1", "KEY_2", "KEY_3", "KEY_4", "KEY_5", "KEY_6", "KEY_7" };
pub const Mode = enum { ecb, cbc, ofb, ctr, cfb8, cfb128 };
pub const Direction = enum { encrypt, decrypt };
pub const Error = error{ InvalidKey, InvalidLength, Timeout };
pub const cfb128_vectors = @import("aes/cfb128_vectors.zig");

/// Key is 16 or 32 bytes. IV is ignored for ECB; CTR increments all 128 bits,
/// big endian. All modes require whole blocks except CFB8. Input/output may
/// be identical or disjoint, never partially overlapping. IV must be disjoint
/// from all buffers. It is updated for continuation only on successful return.
/// A timeout leaves output partially written; discard it and the original IV.
pub fn crypt(key: []const u8, mode: Mode, direction: Direction, iv: *[16]u8, input: []const u8, output: []u8) Error!void {
    if (key.len != 16 and key.len != 32) return error.InvalidKey;
    if (input.len != output.len or (mode != .cfb8 and input.len % 16 != 0)) return error.InvalidLength;
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    system.enable_clocks_and_release_reset(.{ .crypto_aes = true });
    // ESP-IDF aes_ll_reset_register: DS reset also holds AES in reset.
    system.peripheral_reset_clear(.{ .crypto_ds = true });
    system.peripheral_reset(.{ .crypto_aes = true });
    defer {
        inline for (key_names) |name| @field(AES, name).raw = 0;
        system.peripheral_reset(.{ .crypto_aes = true });
    }
    AES.DMA_ENABLE.write(.{ .DMA_ENABLE = 0 });
    // CFB decrypt also uses the forward AES transform (ESP-IDF
    // esp_aes_crypt_cfb128 CPU path). MODE selects the block transform,
    // not software chaining; C6 TRM §19.3 Table 19.3-2, §19.4.3.
    const decrypt_block = direction == .decrypt and (mode == .ecb or mode == .cbc);
    AES.MODE.write(.{ .MODE = @as(u3, if (key.len == 32) 2 else 0) + @as(u3, if (decrypt_block) 4 else 0) });
    inline for (key_names, 0..) |name, i| {
        if (i * 4 < key.len)
            @field(AES, name).raw = std.mem.readInt(u32, key[i * 4 ..][0..4], .little);
    }
    var feedback = iv.*;
    if (mode == .cfb8) {
        for (input, output) |byte, *out| {
            var stream: [16]u8 = undefined;
            try block(&feedback, &stream);
            out.* = byte ^ stream[0];
            std.mem.copyForwards(u8, feedback[0..15], feedback[1..16]);
            feedback[15] = if (direction == .encrypt) out.* else byte;
        }
    } else {
        var offset: usize = 0;
        while (offset < input.len) : (offset += 16) {
            const original = input[offset..][0..16].*;
            var work = original;
            var result: [16]u8 = undefined;
            switch (mode) {
                .ecb => try block(&work, &result),
                .cbc => {
                    if (direction == .encrypt) for (&work, feedback) |*v, f| {
                        v.* ^= f;
                    };
                    try block(&work, &result);
                    if (direction == .decrypt) for (&result, feedback) |*v, f| {
                        v.* ^= f;
                    };
                    feedback = if (direction == .encrypt) result else original;
                },
                .ofb, .ctr, .cfb128 => {
                    try block(&feedback, &result);
                    if (mode == .ofb) feedback = result;
                    for (&result, original) |*v, b| v.* ^= b;
                    if (mode == .cfb128) feedback = if (direction == .encrypt) result else original;
                    if (mode == .ctr) {
                        var i: usize = 16;
                        while (i > 0) {
                            i -= 1;
                            feedback[i] +%= 1;
                            if (feedback[i] != 0) break;
                        }
                    }
                },
                .cfb8 => unreachable, // handled separately above
            }
            @memcpy(output[offset..][0..16], &result);
        }
    }
    if (mode != .ecb) iv.* = feedback;
}

fn block(input: *const [16]u8, output: *[16]u8) Error!void {
    // C6 TRM §§19.4.2–19.4.3: little-endian words, TRIGGER=1,
    // then STATE=0 before reading TEXT_OUT; key/mode persist across blocks.
    inline for (.{ "TEXT_IN_0", "TEXT_IN_1", "TEXT_IN_2", "TEXT_IN_3" }, 0..) |name, i|
        @field(AES, name).raw = std.mem.readInt(u32, input[i * 4 ..][0..4], .little);
    AES.TRIGGER.write(.{ .TRIGGER = 1 });
    for (0..100_000) |_| {
        if (AES.STATE.read().STATE == 0) {
            inline for (.{ "TEXT_OUT_0", "TEXT_OUT_1", "TEXT_OUT_2", "TEXT_OUT_3" }, 0..) |name, i|
                std.mem.writeInt(u32, output[i * 4 ..][0..4], @field(AES, name).raw, .little);
            return;
        }
    }
    return error.Timeout;
}
