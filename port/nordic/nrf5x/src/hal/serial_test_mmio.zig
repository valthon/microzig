//! Generated serial register layouts use this MMIO implementation in host tests.
pub const mmio = @This();

pub var after_read: *const fn (*volatile u32) void = undefined;
pub var on_write: *const fn (*volatile u32, u32) void = undefined;

pub fn Mmio(comptime Packed: type) type {
    const Int = @Int(.unsigned, @bitSizeOf(Packed));
    return packed struct(Int) {
        const Self = @This();

        raw: Int,
        pub const underlying_type = Packed;

        pub fn read(addr: *volatile Self) Packed {
            const value = addr.raw;
            if (Int == u32) after_read(&addr.raw);
            return @bitCast(value);
        }

        pub fn write(addr: *volatile Self, value: Packed) void {
            addr.write_raw(@bitCast(value));
        }

        pub fn write_raw(addr: *volatile Self, value: Int) void {
            addr.raw = value;
            if (Int == u32) on_write(&addr.raw, value);
        }

        pub fn modify(addr: *volatile Self, fields: anytype) void {
            var value = addr.read();
            inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |field| {
                @field(value, field) = @field(fields, field);
            }
            addr.write(value);
        }
    };
}
