//! Unwired GPIO6/7 with weak pulls: every unreserved address must NACK.
const i2c = @import("microzig").hal.lp_i2c;
pub const Result = struct { nacks: u32 = 0, acks: u32 = 0, faults: u32 = 0, bits: u32 = 0 };
pub fn run() Result {
    var result: Result = .{};
    i2c.apply(.{ .source_hz = 16_000_000, .internal_pullups = true }) catch {
        result.faults = 1;
        return result;
    };
    for (0x08..0x78) |address| {
        if (i2c.probe(@intCast(address), 200000)) {
            result.acks += 1;
        } else |err| {
            if (err == error.Nack) result.nacks += 1 else result.faults += 1;
        }
    }
    const data = [_]u8{0xa5};
    if (i2c.write(0x55, &data, 200000)) {} else |err| {
        if (err == error.Nack) result.bits |= 1;
    }
    var received: [1]u8 = undefined;
    if (i2c.read(0x55, &received, 200000)) {} else |err| {
        if (err == error.Nack) result.bits |= 2;
    }
    // A second probe after errors verifies controller recovery.
    if (i2c.probe(0x55, 200000)) {} else |err| {
        if (err == error.Nack) result.bits |= 4;
    }
    return result;
}
