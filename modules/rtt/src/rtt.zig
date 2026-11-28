const std = @import("std");
const lock = @import("lock.zig");
const memory_barrier = @import("memory_barrier.zig");
const MemoryBarrierFn = memory_barrier.MemoryBarrierFn;
pub const AnyLock = lock.AnyLock;
pub const GenericLock = lock.GenericLock;

/// Header that indicates to the connected probe how many up/down channels are in use.
///
/// The RTT header is found based on the string "SEGGER RTT", so we need to avoid storing
/// the whole string in memory anywhere other than this header (otherwise host software
/// may choose the wrong location). Storing it reversed and copying it into the header at runtime accomplishes this.
const Header = extern struct {
    id: [16]u8,
    max_up_channels: usize,
    max_down_channels: usize,

    pub fn init(self: *Header, comptime max_up_channels: usize, comptime max_down_channels: usize, comptime barrier_fn: MemoryBarrierFn) void {
        self.max_up_channels = max_up_channels;
        self.max_down_channels = max_down_channels;

        // Volatile loads keep the compiler from embedding the forward signature.
        const reversed: *const volatile [16]u8 = "\x00\x00\x00\x00\x00\x00TTR REGGES";
        for (1..self.id.len) |i| {
            self.id[i] = reversed[self.id.len - 1 - i];
        }
        barrier_fn();
        // Publish the signature only after the descriptors and remaining id bytes.
        @as(*volatile u8, &self.id[0]).* = reversed[self.id.len - 1];
        barrier_fn();
    }
};

pub const channel = struct {
    /// Select the target-to-probe or probe-to-target channel list.
    pub const Direction = enum { up, down };

    pub const Mode = enum(usize) {
        no_block_skip = 0,
        no_block_trim = 1,
        block_if_full = 2,
        _,
    };

    fn decode_mode(flags: usize) Mode {
        return switch (flags & 3) {
            1 => .no_block_trim,
            2 => .block_if_full,
            else => .no_block_skip,
        };
    }

    /// Configuration for an up or down channel per the RTT spec
    pub const Config = struct {
        name: [*:0]const u8,
        buffer_size: usize,
        mode: Mode,
    };

    /// Represents a target -> host communication channel.
    ///
    /// Implements a ring buffer of size - 1 bytes, as this implementation
    /// does not fill up the buffer in order to avoid the problem of being unable to
    /// distinguish between full and empty.
    fn Up(comptime barrier_fn: MemoryBarrierFn) type {
        return extern struct {
            /// Name is optional and is not required by the spec. Standard names so far are:
            /// "Terminal", "SysView", "J-Scope_t4i4"
            name: [*:0]const u8,

            buffer: [*]u8,

            /// Note from above actual buffer size is size - 1 bytes
            size: usize,

            write_offset: usize,
            read_offset: usize,

            /// Flags[1:0] select the RTT operating mode. On 32-bit targets,
            /// Flags[23:2] are reserved and Flags[31:24] must be zero for validity.
            flags: usize,

            const Self = @This();

            fn init(self: *Self, name: [*:0]const u8, buffer: []u8, mode_: Mode) void {
                self.* = .{
                    .name = name,
                    .buffer = buffer.ptr,
                    .size = buffer.len,
                    .write_offset = 0,
                    .read_offset = 0,
                    .flags = @as(u2, @truncate(@backingInt(mode_))),
                };
            }

            /// One attempt under the lock, using a single snapshot of the probe's offset.
            fn write_available(self: *Self, comptime size: usize, buffer: *[size]u8, bytes: []const u8, write_mode: Mode) usize {
                const read_offset = @as(*volatile usize, &self.read_offset).*;
                const write_offset = @as(*volatile usize, &self.write_offset).*;
                if (read_offset >= size or write_offset >= size) return 0;

                const space = if (read_offset > write_offset)
                    read_offset - write_offset - 1
                else
                    size - write_offset - 1 + read_offset;
                if (write_mode == .no_block_skip and bytes.len > space) return 0;

                const count = @min(bytes.len, space);
                if (count == 0) return 0;
                const first = @min(count, size - write_offset);
                std.mem.copyForwards(u8, buffer[write_offset..][0..first], bytes[0..first]);
                std.mem.copyForwards(u8, buffer[0 .. count - first], bytes[first..count]);

                barrier_fn();
                const end = write_offset + first;
                self.write_offset = if (end == size) count - first else end;
                return count;
            }

            /// Implements the std.Io.Writer interface
            pub const Writer = struct {
                write_fn: *const fn ([]const u8) usize,
                interface: std.Io.Writer,

                fn init(write_fn: *const fn ([]const u8) usize, buf: []u8) Writer {
                    return .{
                        .write_fn = write_fn,
                        .interface = .{
                            .vtable = &.{
                                .drain = drain,
                            },
                            .buffer = buf,
                            .end = 0,
                        },
                    };
                }

                /// Skip and trim consume the input even when some bytes are dropped.
                /// Block mode waits for room in the RTT buffer.
                fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                    const writer_: *Writer = @fieldParentPtr("interface", io_w);

                    const buffered = io_w.buffered();
                    if (buffered.len > 0) {
                        _ = writer_.write_fn(buffered);
                        _ = io_w.consumeAll();
                    }
                    var n: usize = 0;
                    for (data[0 .. data.len - 1]) |d| {
                        _ = writer_.write_fn(d);
                        n += d.len;
                    }
                    for (0..splat) |_| {
                        const to_splat = data[data.len - 1];
                        _ = writer_.write_fn(to_splat);
                        n += to_splat.len;
                    }
                    return n;
                }
            };
        };
    }

    /// Represents a host -> target communication channel.
    ///
    /// Implements a ring buffer of size - 1 bytes, as this implementation
    /// does not fill up the buffer in order to avoid the problem of being unable to
    /// distinguish between full and empty.
    fn Down(comptime barrier_fn: MemoryBarrierFn) type {
        return extern struct {
            /// Name is optional and is not required by the spec. Standard names so far are:
            /// "Terminal", "SysView", "J-Scope_t4i4"
            name: [*:0]const u8,

            buffer: [*]u8,

            /// Note from above actual buffer size is size - 1 bytes
            size: usize,

            write_offset: usize,
            read_offset: usize,

            /// Flags[1:0] select the RTT operating mode. On 32-bit targets,
            /// Flags[23:2] are reserved and Flags[31:24] must be zero for validity.
            flags: usize,

            const Self = @This();

            pub fn init(self: *Self, name: [*:0]const u8, buffer: []u8, mode_: Mode) void {
                self.* = .{
                    .name = name,
                    .buffer = buffer.ptr,
                    .size = buffer.len,
                    .write_offset = 0,
                    .read_offset = 0,
                    .flags = @as(u2, @truncate(@backingInt(mode_))),
                };
            }

            /// Read from the probe without blocking. The caller holds the lock.
            fn read_available(self: *Self, comptime size: usize, buffer: *[size]u8, bytes: []u8) usize {
                const write_offset = @as(*volatile usize, &self.write_offset).*;
                barrier_fn();
                const read_offset = @as(*volatile usize, &self.read_offset).*;
                const count = @min(bytes.len, available_bytes(size, read_offset, write_offset));
                if (count == 0) return 0;

                const first = @min(count, size - read_offset);
                std.mem.copyForwards(u8, bytes[0..first], buffer[read_offset..][0..first]);
                std.mem.copyForwards(u8, bytes[first..count], buffer[0 .. count - first]);

                barrier_fn();
                const end = read_offset + first;
                self.read_offset = if (end == size) count - first else end;
                return count;
            }

            fn available_bytes(comptime size: usize, read_offset: usize, write_offset: usize) usize {
                if (read_offset >= size or write_offset >= size) return 0;
                return if (write_offset >= read_offset)
                    write_offset - read_offset
                else
                    size - read_offset + write_offset;
            }

            /// Snapshot of the bytes the probe has published. The caller holds the lock.
            fn bytes_available(self: *Self, comptime size: usize) usize {
                const write_offset = @as(*volatile usize, &self.write_offset).*;
                const read_offset = @as(*volatile usize, &self.read_offset).*;
                return available_bytes(size, read_offset, write_offset);
            }

            /// Implements the std.Io.Reader interface
            pub const Reader = struct {
                read_fn: *const fn ([]u8) usize,
                interface: std.Io.Reader,
                pending: ?u8 = null,

                fn init(read_fn: *const fn ([]u8) usize, buf: []u8) Reader {
                    return .{
                        .read_fn = read_fn,
                        .interface = .{
                            .vtable = &.{
                                .stream = stream,

                                // Default discarding behavior is acceptable, and will still work even with a zero
                                // length buffer
                                .discard = std.Io.Reader.defaultDiscard,

                                // The default behavior prioritizes reading entire internal buffers worth of data rather
                                // than directly calling RTT reads individually, which is exactly what is desired
                                .readVec = std.Io.Reader.defaultReadVec,

                                // The default rebase behavior of moving data back to the start of the internal buffer
                                // is acceptable
                                .rebase = std.Io.Reader.defaultRebase,
                            },
                            .buffer = buf,
                            .end = 0,
                            .seek = 0,
                        },
                    };
                }

                fn stream(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
                    if (limit == .nothing) return 0;
                    const reader_: *Reader = @fieldParentPtr("interface", io_r);
                    if (reader_.pending == null) {
                        const dest = limit.slice(io_w.unusedCapacitySlice());
                        if (dest.len > 0) {
                            const n = reader_.read_fn(dest);
                            if (n > 0) io_w.advance(n);
                            return n;
                        }

                        // A full or unbuffered writer can drain without
                        // rebasing. Keep this byte if the writer cannot take it.
                        var byte: [1]u8 = undefined;
                        if (reader_.read_fn(&byte) == 0) return 0;
                        reader_.pending = byte[0];
                    }
                    const n = try io_w.write(&.{reader_.pending.?});
                    if (n > 0) reader_.pending = null;
                    return n;
                }
            };
        };
    }
};

fn buffer_field(comptime direction: channel.Direction, comptime index: usize) []const u8 {
    return std.fmt.comptimePrint("{s}_buffer_{d}", .{ @tagName(direction), index });
}

/// Constructs a struct type where each field is a u8 array of size specified by channel config.
///
/// Fields follow the naming convention "up_buffer_N" for up channels, and "down_buffer_N" for down channels.
fn BuildBufferStorageType(comptime up_channels: []const channel.Config, comptime down_channels: []const channel.Config) type {
    const count = up_channels.len + down_channels.len;
    var field_names: [count][]const u8 = undefined;
    var field_types: [count]type = undefined;
    var field_attrs: [count]std.lang.Type.Struct.FieldAttributes = undefined;

    var i: usize = 0;
    for (up_channels, 0..) |up_cfg, idx| {
        field_names[i] = buffer_field(.up, idx);
        field_types[i] = [up_cfg.buffer_size]u8;
        field_attrs[i] = .{};

        i += 1;
    }

    for (down_channels, 0..) |down_cfg, idx| {
        field_names[i] = buffer_field(.down, idx);
        field_types[i] = [down_cfg.buffer_size]u8;
        field_attrs[i] = .{};

        i += 1;
    }

    return @Struct(.@"extern", null, &field_names, &field_types, &field_attrs);
}

/// Creates a control block struct for the given channel configs. Buffer storage is also contained within this struct, although
/// per the RTT spec it doesn't have to be.
fn ControlBlock(comptime up_channels: []const channel.Config, comptime down_channels: []const channel.Config, comptime barrier_fn: MemoryBarrierFn) type {
    if (up_channels.len == 0 or down_channels.len == 0) {
        @compileError("Must have at least 1 up and down channel configured");
    }

    inline for (.{ up_channels, down_channels }, .{ "up", "down" }) |channels, direction| {
        for (channels, 0..) |cfg, i| {
            if (cfg.buffer_size < 2) @compileError(std.fmt.comptimePrint(
                "RTT {s} channel {d} ({s}) needs a buffer_size of at least 2",
                .{ direction, i, cfg.name },
            ));
        }
    }

    const BufferContainerType = BuildBufferStorageType(up_channels, down_channels);
    return extern struct {
        header: Header,
        up_channels: [up_channels.len]channel.Up(barrier_fn),
        down_channels: [down_channels.len]channel.Down(barrier_fn),
        buffers: BufferContainerType,

        pub fn init(self: *@This()) void {
            @as(*volatile u8, &self.header.id[0]).* = 0;
            barrier_fn();

            inline for (up_channels, 0..) |cfg, i| {
                self.up_channels[i].init(cfg.name, &@field(self.buffers, buffer_field(.up, i)), cfg.mode);
            }
            inline for (down_channels, 0..) |cfg, i| {
                self.down_channels[i].init(cfg.name, &@field(self.buffers, buffer_field(.down, i)), cfg.mode);
            }
            self.header.init(up_channels.len, down_channels.len, barrier_fn);
        }
    };
}

/// Compile time configuration of RTT instance
pub const Config = struct {
    up_channels: []const channel.Config = &[_]channel.Config{.{ .name = "Terminal", .buffer_size = 1024, .mode = .no_block_skip }},
    down_channels: []const channel.Config = &[_]channel.Config{.{ .name = "Terminal", .buffer_size = 16, .mode = .block_if_full }},
    /// Optionally supply a custom implementation of exclusive access protection (lock/unlock),
    /// defaults to original Segger lock implementation when not provided, disables lock protection when
    /// provided with null.
    ///
    /// If trying to run RTT on a platform not yet supported by the "defaults" this must be provided or set to null
    exclusive_access: ?AnyLock = lock.default.get(),
    /// Optionally supply a custom implementation of a memory barrier function,
    /// defaults to original Segger memory barrier implementation when not provided, disables memory barriers
    /// when provided with null
    ///
    /// If trying to run RTT on a platform not yet supported by the "defaults" this must be provided or set to null
    memory_barrier_fn: ?MemoryBarrierFn = memory_barrier.resolve_memory_barrier().memory_barrier_fn,
    /// Optionally place the RTT control block (and buffers) in a specific linker section
    linker_section: ?[]const u8 = null,
};

/// Creates an RTT namespace given the compile time configuration with functions for writing/reading from RTT channels.
pub fn RTT(comptime config: Config) type {
    return struct {
        const exclusive_access = config.exclusive_access orelse lock.empty.get();
        const mb_fn = config.memory_barrier_fn orelse memory_barrier.empty_memory_barrier;
        var initialised = false;
        var control_block: ControlBlock(
            config.up_channels,
            config.down_channels,
            mb_fn,
        ) linksection(config.linker_section orelse ".data") = undefined;

        comptime {
            // `_SEGGER_RTT` is the name SEGGER's sources use and the one host tools
            // (probe-rs, J-Link) look up in the ELF; `RttControlBlock` is kept for
            // existing scripts.
            @export(&control_block, .{ .name = "_SEGGER_RTT" });
            @export(&control_block, .{ .name = "RttControlBlock" });
        }

        // Accessed under exclusive_access, including from exception handlers.
        fn is_initialised() bool {
            return @as(*volatile bool, &initialised).*;
        }

        /// Publish the control block, discarding bytes still in the rings on
        /// reinitialisation. Bytes buffered by an I/O handle stay with it.
        pub fn init() void {
            exclusive_access.lock_fn(exclusive_access.context);
            defer exclusive_access.unlock_fn(exclusive_access.context);

            const live: *volatile bool = &initialised;
            live.* = false;
            control_block.init();
            live.* = true;
        }

        fn check_channel(comptime direction: channel.Direction, comptime channel_number: usize) void {
            comptime {
                const count = switch (direction) {
                    .up => config.up_channels.len,
                    .down => config.down_channels.len,
                };
                if (channel_number >= count) @compileError(std.fmt.comptimePrint(
                    "RTT {s} channel {d} is out of range ({d} configured)",
                    .{ @tagName(direction), channel_number, count },
                ));
            }
        }

        fn channel_flags(comptime direction: channel.Direction, comptime channel_number: usize) *volatile usize {
            return switch (direction) {
                .up => &control_block.up_channels[channel_number].flags,
                .down => &control_block.down_channels[channel_number].flags,
            };
        }

        /// Return the channel's current mode, or null before init.
        pub fn mode(comptime direction: channel.Direction, comptime channel_number: usize) ?channel.Mode {
            check_channel(direction, channel_number);
            exclusive_access.lock_fn(exclusive_access.context);
            defer exclusive_access.unlock_fn(exclusive_access.context);
            if (!is_initialised()) return null;

            return channel.decode_mode(channel_flags(direction, channel_number).*);
        }

        /// Set the channel's mode bits. Calls before init are ignored.
        pub fn set_mode(comptime direction: channel.Direction, comptime channel_number: usize, new_mode: channel.Mode) void {
            check_channel(direction, channel_number);
            exclusive_access.lock_fn(exclusive_access.context);
            defer exclusive_access.unlock_fn(exclusive_access.context);
            if (!is_initialised()) return;

            const flags = channel_flags(direction, channel_number);
            flags.* = (flags.* & ~@as(usize, 3)) | @as(u2, @truncate(@backingInt(new_mode)));
        }

        /// Write bytes to a given up channel
        pub fn write(comptime channel_number: usize, bytes: []const u8) usize {
            check_channel(.up, channel_number);
            var written: usize = 0;
            var write_mode: ?channel.Mode = null;
            while (written < bytes.len) {
                // A blocking write resamples host progress with the lock released
                // between attempts, including attempts that find no space.
                exclusive_access.lock_fn(exclusive_access.context);
                defer exclusive_access.unlock_fn(exclusive_access.context);
                if (!is_initialised()) return written;

                const up = &control_block.up_channels[channel_number];
                const size = config.up_channels[channel_number].buffer_size;
                const buffer = &@field(control_block.buffers, buffer_field(.up, channel_number));
                const active_mode = write_mode orelse channel.decode_mode(channel_flags(.up, channel_number).*);
                write_mode = active_mode;
                written += up.write_available(size, buffer, bytes[written..], active_mode);
                if (active_mode != .block_if_full) break;
            }
            return written;
        }

        /// Access the std.Io adapter through `interface`. Its other fields are internal.
        pub const Writer = channel.Up(mb_fn).Writer;

        /// Returns a Writer for the given up channel. A zero-length buffer
        /// sends bytes through drain immediately. With a buffer, flush to write
        /// pending bytes to the current control block. A flush before init
        /// drops its bytes.
        pub fn writer(comptime channel_number: usize, buf: []u8) Writer {
            check_channel(.up, channel_number);
            const Endpoint = struct {
                fn send(bytes: []const u8) usize {
                    return write(channel_number, bytes);
                }
            };
            return Writer.init(Endpoint.send, buf);
        }

        /// Read bytes from a given down channel
        pub fn read(comptime channel_number: usize, bytes: []u8) usize {
            check_channel(.down, channel_number);
            exclusive_access.lock_fn(exclusive_access.context);
            defer exclusive_access.unlock_fn(exclusive_access.context);
            if (!is_initialised()) return 0;

            const size = config.down_channels[channel_number].buffer_size;
            const buffer = &@field(control_block.buffers, buffer_field(.down, channel_number));
            const down = &control_block.down_channels[channel_number];
            return down.read_available(size, buffer, bytes);
        }

        /// Return a non-consuming snapshot of bytes in a down ring.
        /// Returns zero before init. Bytes prefetched by a Reader are separate.
        pub fn bytes_available(comptime channel_number: usize) usize {
            check_channel(.down, channel_number);
            exclusive_access.lock_fn(exclusive_access.context);
            defer exclusive_access.unlock_fn(exclusive_access.context);
            if (!is_initialised()) return 0;

            const size = config.down_channels[channel_number].buffer_size;
            return control_block.down_channels[channel_number].bytes_available(size);
        }

        /// Access the std.Io adapter through `interface`. Its other fields are internal.
        pub const Reader = channel.Down(mb_fn).Reader;

        /// Returns a Reader that implements the std.Io.Reader interface for a given down channel.
        /// A zero-length buffer will cause asserts in any of the std.Io.Reader functions that require buffering
        /// (peek*() functions, delimiter searching functions, etc.). Supplying a small buffer also helps with
        /// reducing the total number of read calls to RTT, and thus total number of locks/interrupt enable/disable.
        pub fn reader(comptime channel_number: usize, buffer: []u8) Reader {
            check_channel(.down, channel_number);
            const Endpoint = struct {
                fn receive(bytes: []u8) usize {
                    return read(channel_number, bytes);
                }
            };
            return Reader.init(Endpoint.receive, buffer);
        }
    };
}

const TestLock = struct {
    var held = false;
    var on_unlock: ?*const fn () void = null;
    var on_barrier: ?*const fn () void = null;
    var instance: GenericLock(void, enter, leave) = .{ .context = {} };

    fn enter(_: void) void {
        std.debug.assert(!held);
        held = true;
    }

    fn leave(_: void) void {
        std.debug.assert(held);
        held = false;
        if (on_unlock) |notify| notify();
    }

    inline fn barrier() void {
        std.debug.assert(held);
        if (on_barrier) |notify| notify();
    }
};

const TestRTT = RTT(.{
    .up_channels = &.{
        .{ .name = "skip", .buffer_size = 4, .mode = .no_block_skip },
        .{ .name = "trim", .buffer_size = 4, .mode = .no_block_trim },
        .{ .name = "block", .buffer_size = 4, .mode = .block_if_full },
    },
    .down_channels = &.{.{ .name = "down", .buffer_size = 4, .mode = .block_if_full }},
    .exclusive_access = TestLock.instance.any(),
    .memory_barrier_fn = TestLock.barrier,
});

test "control block layout" {
    TestRTT.init();
    const cb = &TestRTT.control_block;
    const Block = @TypeOf(cb.*);
    const word = @sizeOf(usize);
    const id_size = @sizeOf(@FieldType(Header, "id"));
    const Up = @TypeOf(cb.up_channels[0]);
    const Down = @TypeOf(cb.down_channels[0]);
    try std.testing.expectEqual(0, @offsetOf(Block, "header"));
    try std.testing.expectEqual(16, id_size);
    try std.testing.expectEqual(id_size, @offsetOf(Header, "max_up_channels"));
    try std.testing.expectEqual(id_size + word, @offsetOf(Header, "max_down_channels"));
    try std.testing.expectEqual(id_size + 2 * word, @sizeOf(Header));
    try std.testing.expectEqual(@sizeOf(Header), @offsetOf(Block, "up_channels"));
    try std.testing.expectEqual(@sizeOf(Header) + @sizeOf(@TypeOf(cb.up_channels)), @offsetOf(Block, "down_channels"));

    inline for (.{ Up, Down }) |Descriptor| {
        const fields = .{ "name", "buffer", "size", "write_offset", "read_offset", "flags" };
        inline for (fields, 0..) |field, i| {
            try std.testing.expectEqual(i * word, @offsetOf(Descriptor, field));
            try std.testing.expectEqual(word, @sizeOf(@FieldType(Descriptor, field)));
        }
        try std.testing.expectEqual(fields.len * word, @sizeOf(Descriptor));
    }

    try std.testing.expectEqualSlices(u8, "SEGGER RTT\x00\x00\x00\x00\x00\x00", &cb.header.id);
    try std.testing.expectEqual(3, cb.header.max_up_channels);
    try std.testing.expectEqual(1, cb.header.max_down_channels);
}

test "write never fills the last byte (no_block_skip)" {
    TestRTT.init();
    const up = &TestRTT.control_block.up_channels[0];
    try std.testing.expectEqual(0, TestRTT.write(0, "abcd"));
    try std.testing.expectEqual(3, TestRTT.write(0, "abc"));
    try std.testing.expectEqual(0, TestRTT.write(0, "d"));
    try std.testing.expectEqual(3, up.write_offset);
    up.read_offset = 2;
    try std.testing.expectEqual(2, TestRTT.write(0, "de"));
    try std.testing.expectEqual(1, up.write_offset);
    try std.testing.expectEqualSlices(u8, "ebcd", &TestRTT.control_block.buffers.up_buffer_0);
}

test "write never fills the last byte (no_block_trim)" {
    TestRTT.init();
    const up = &TestRTT.control_block.up_channels[1];
    try std.testing.expectEqual(3, TestRTT.write(1, "abcd"));
    try std.testing.expectEqual(0, TestRTT.write(1, "d"));
    try std.testing.expectEqual(3, up.write_offset);
    up.read_offset = 2;
    try std.testing.expectEqual(2, TestRTT.write(1, "def"));
    try std.testing.expectEqual(1, up.write_offset);
    try std.testing.expectEqualSlices(u8, "ebcd", &TestRTT.control_block.buffers.up_buffer_1);
}

test "write never fills the last byte (block_if_full)" {
    TestRTT.init();
    const Probe = struct {
        var attempts: usize = 0;

        fn consume() void {
            const up = &TestRTT.control_block.up_channels[2];
            switch (attempts) {
                0, 1 => {
                    // First chunk left the last byte free, and the next attempt
                    // came back with no space. The probe now frees two bytes.
                    std.debug.assert(up.write_offset == 3 and up.read_offset == 0);
                    if (attempts == 1) up.read_offset = 2;
                },
                2 => std.debug.assert(up.write_offset == 1 and up.read_offset == 2),
                else => @panic("unexpected blocking write attempt"),
            }
            attempts += 1;
        }
    };
    Probe.attempts = 0;
    TestLock.on_unlock = Probe.consume;
    defer TestLock.on_unlock = null;
    try std.testing.expectEqual(5, TestRTT.write(2, "abcde"));
    try std.testing.expectEqual(3, Probe.attempts);
    try std.testing.expectEqualSlices(u8, "ebcd", &TestRTT.control_block.buffers.up_buffer_2);
}

test "init writes flags" {
    const cb = &TestRTT.control_block;
    TestRTT.init();
    for (&cb.up_channels) |*up| up.flags = std.math.maxInt(usize);
    cb.down_channels[0].flags = std.math.maxInt(usize);
    const InitOrder = struct {
        var barriers: usize = 0;

        fn check_barrier() void {
            const block = &TestRTT.control_block;
            std.debug.assert(!TestRTT.is_initialised());
            switch (barriers) {
                0 => std.debug.assert(block.header.id[0] == 0 and block.down_channels[0].flags == std.math.maxInt(usize)),
                1 => std.debug.assert(block.header.id[0] == 0 and block.down_channels[0].flags == 2),
                2 => std.debug.assert(block.header.id[0] == 'S'),
                else => @panic("unexpected init barrier"),
            }
            barriers += 1;
        }

        fn check_unlock() void {
            std.debug.assert(TestRTT.is_initialised());
        }
    };
    InitOrder.barriers = 0;
    TestLock.on_barrier = InitOrder.check_barrier;
    TestLock.on_unlock = InitOrder.check_unlock;
    defer {
        TestLock.on_barrier = null;
        TestLock.on_unlock = null;
    }
    TestRTT.init();
    try std.testing.expectEqual(3, InitOrder.barriers);

    for (&cb.up_channels, 0..) |*up, mode| try std.testing.expectEqual(mode, up.flags);
    try std.testing.expectEqual(2, cb.down_channels[0].flags);
    try std.testing.expectEqual(.block_if_full, TestRTT.mode(.down, 0));
}

test "out-of-range host offset" {
    TestRTT.init();
    const cb = &TestRTT.control_block;
    var bytes: [4]u8 = @splat('!');
    cb.buffers.up_buffer_0 = @splat('!');
    cb.buffers.up_buffer_1 = @splat('!');
    for ([_]usize{ 4, std.math.maxInt(usize) }) |invalid| {
        for (cb.up_channels[0..2], 0..) |*up, i| {
            up.read_offset = invalid;
            up.write_offset = 0;
            try std.testing.expectEqual(0, if (i == 0) TestRTT.write(0, "a") else TestRTT.write(1, "a"));
            try std.testing.expectEqual(0, up.write_offset);
            up.read_offset = 0;
            up.write_offset = invalid;
            try std.testing.expectEqual(0, if (i == 0) TestRTT.write(0, "a") else TestRTT.write(1, "a"));
            try std.testing.expectEqual(invalid, up.write_offset);
        }
        const down = &cb.down_channels[0];
        down.write_offset = invalid;
        down.read_offset = 0;
        try std.testing.expectEqual(0, TestRTT.bytes_available(0));
        try std.testing.expectEqual(0, TestRTT.read(0, &bytes));
        try std.testing.expectEqual(0, down.read_offset);
        down.write_offset = 0;
        down.read_offset = invalid;
        try std.testing.expectEqual(0, TestRTT.bytes_available(0));
        try std.testing.expectEqual(0, TestRTT.read(0, &bytes));
        try std.testing.expectEqual(invalid, down.read_offset);
    }
    try std.testing.expectEqualSlices(u8, "!!!!", &bytes);
    try std.testing.expectEqualSlices(u8, "!!!!", &cb.buffers.up_buffer_0);
    try std.testing.expectEqualSlices(u8, "!!!!", &cb.buffers.up_buffer_1);
}

test "corrupted descriptor" {
    TestRTT.init();
    const cb = &TestRTT.control_block;
    var decoy: [4]u8 = @splat('!');
    cb.up_channels[0].buffer = &decoy;
    cb.up_channels[0].size = 1;
    try std.testing.expectEqual(3, TestRTT.write(0, "abc"));
    try std.testing.expectEqualSlices(u8, "abc", cb.buffers.up_buffer_0[0..3]);
    try std.testing.expectEqualSlices(u8, "!!!!", &decoy);

    const down = &cb.down_channels[0];
    down.buffer = &decoy;
    down.size = 1;
    down.read_offset = 3;
    down.write_offset = 2;
    cb.buffers.down_buffer_0 = "bc!a".*;
    try std.testing.expectEqual(3, TestRTT.bytes_available(0));
    var dest: [3]u8 = undefined;
    var writer_ = std.Io.Writer.fixed(&dest);
    var reader_ = TestRTT.reader(0, &.{});
    try std.testing.expectEqual(3, try reader_.interface.stream(&writer_, .unlimited));
    try std.testing.expectEqualSlices(u8, "abc", writer_.buffered());
    try std.testing.expectEqual(2, down.read_offset);
    try std.testing.expectEqual(0, try reader_.interface.stream(&writer_, .unlimited));
}

test "unknown mode" {
    TestRTT.init();
    const cb = &TestRTT.control_block;
    cb.up_channels[1].flags = 0x1003;
    try std.testing.expectEqual(0, TestRTT.write(1, "abcd"));
    var writer_ = TestRTT.writer(1, &.{});
    try writer_.interface.writeAll("abcd");
    try std.testing.expectEqual(0, cb.up_channels[1].write_offset);
    try std.testing.expectEqual(3, TestRTT.write(1, "abc"));

    const down = &cb.down_channels[0];
    down.flags = 0x1003;
    try std.testing.expectEqual(.no_block_skip, TestRTT.mode(.up, 1));
    try std.testing.expectEqual(.no_block_skip, TestRTT.mode(.down, 0));
}

test "bytes_available is non-consuming" {
    TestRTT.init();
    const cb = &TestRTT.control_block;
    try std.testing.expectEqual(0, TestRTT.bytes_available(0));
    cb.buffers.down_buffer_0 = "abc!".*;
    cb.down_channels[0].write_offset = 3;
    TestRTT.initialised = false;
    try std.testing.expectEqual(0, TestRTT.bytes_available(0));
    try std.testing.expectEqual(0, cb.down_channels[0].read_offset);

    TestRTT.initialised = true;
    try std.testing.expectEqual(3, TestRTT.bytes_available(0));
    try std.testing.expectEqual(3, TestRTT.bytes_available(0));
    var bytes: [2]u8 = undefined;
    try std.testing.expectEqual(2, TestRTT.read(0, &bytes));
    try std.testing.expectEqualSlices(u8, "ab", &bytes);
    try std.testing.expectEqual(1, TestRTT.bytes_available(0));
}

test "set_mode on up and down channels" {
    TestRTT.init();
    const cb = &TestRTT.control_block;
    const up = &cb.up_channels[0];
    const down = &cb.down_channels[0];
    up.flags = 0x1000;
    down.flags = 0x2002;

    TestRTT.initialised = false;
    TestRTT.set_mode(.up, 0, .no_block_trim);
    TestRTT.set_mode(.down, 0, .no_block_skip);
    try std.testing.expectEqual(null, TestRTT.mode(.up, 0));
    try std.testing.expectEqual(null, TestRTT.mode(.down, 0));
    try std.testing.expectEqual(0x1000, up.flags);
    try std.testing.expectEqual(0x2002, down.flags);

    TestRTT.initialised = true;
    TestRTT.set_mode(.up, 0, .no_block_trim);
    TestRTT.set_mode(.down, 0, .no_block_skip);
    try std.testing.expectEqual(.no_block_trim, TestRTT.mode(.up, 0));
    try std.testing.expectEqual(.no_block_skip, TestRTT.mode(.down, 0));
    try std.testing.expectEqual(0x1001, up.flags);
    try std.testing.expectEqual(0x2000, down.flags);
    try std.testing.expectEqual(3, TestRTT.write(0, "abcd"));
}

test "calls before init" {
    // Model a warm reset where the fresh private flag guards a stale RAM block.
    TestRTT.init();
    TestRTT.initialised = false;
    const cb = &TestRTT.control_block;
    cb.down_channels[0].write_offset = 1;
    cb.buffers.down_buffer_0[0] = 'a';
    try std.testing.expectEqual(0, TestRTT.write(0, "abc"));
    var dest: [4]u8 = @splat('!');
    try std.testing.expectEqual(0, TestRTT.read(0, &dest));
    var output = std.Io.Writer.fixed(&dest);
    var reader_ = TestRTT.reader(0, &.{});
    try std.testing.expectEqual(0, try reader_.interface.stream(&output, .unlimited));
    try std.testing.expectEqualSlices(u8, "!!!!", &dest);

    var buffer: [4]u8 = undefined;
    var writer_ = TestRTT.writer(0, &buffer);
    try writer_.interface.writeAll("abc");
    try writer_.interface.flush();
    try std.testing.expectEqual(0, cb.up_channels[0].write_offset);
    try std.testing.expectEqual(0, cb.down_channels[0].read_offset);

    try writer_.interface.writeAll("xyz");
    TestRTT.init();
    try writer_.interface.flush();
    try std.testing.expectEqual(3, cb.up_channels[0].write_offset);
    try std.testing.expectEqualSlices(u8, "xyz", cb.buffers.up_buffer_0[0..3]);
}

test "empty stream with an unbuffered destination" {
    const Destination = struct {
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            @panic("an empty stream must not drain its destination");
        }
    };
    var output: std.Io.Writer = .{
        .vtable = &.{ .drain = Destination.drain },
        .buffer = &.{},
        .end = 0,
    };
    var reader_ = TestRTT.reader(0, &.{});
    TestRTT.init();
    const cb = &TestRTT.control_block;
    cb.buffers.down_buffer_0[0] = 'a';
    cb.down_channels[0].write_offset = 1;
    TestRTT.initialised = false;
    try std.testing.expectEqual(0, try reader_.interface.stream(&output, .unlimited));
    TestRTT.init();
    try std.testing.expectEqual(0, try reader_.interface.stream(&output, .unlimited));
}

test "stream into an unbuffered destination" {
    TestRTT.init();
    const cb = &TestRTT.control_block;
    cb.buffers.down_buffer_0 = "abc!".*;
    cb.down_channels[0].write_offset = 3;
    var reader_ = TestRTT.reader(0, &.{});
    var full = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, reader_.interface.stream(&full, .unlimited));

    var output = TestRTT.writer(0, &.{});
    for (0..3) |_| {
        try std.testing.expectEqual(1, try reader_.interface.stream(&output.interface, .limited(1)));
    }
    try std.testing.expectEqual(0, try reader_.interface.stream(&output.interface, .unlimited));
    try std.testing.expectEqual(3, cb.down_channels[0].read_offset);
    try std.testing.expectEqual(3, cb.up_channels[0].write_offset);
    try std.testing.expectEqualSlices(u8, "abc", cb.buffers.up_buffer_0[0..3]);
}

test "reinitialisation preserves handle buffers" {
    TestRTT.init();
    const cb = &TestRTT.control_block;
    cb.buffers.down_buffer_0 = "abc!".*;
    cb.down_channels[0].write_offset = 3;
    var input_buffer: [2]u8 = undefined;
    var reader_ = TestRTT.reader(0, &input_buffer);
    try std.testing.expectEqualSlices(u8, "ab", try reader_.interface.peek(2));

    var output_buffer: [4]u8 = undefined;
    var writer_ = TestRTT.writer(0, &output_buffer);
    try writer_.interface.writeAll("xyz");
    TestRTT.init();
    try std.testing.expectEqualSlices(u8, "ab", try reader_.interface.take(2));
    try std.testing.expectEqual(0, TestRTT.read(0, &input_buffer));
    try writer_.interface.flush();
    try std.testing.expectEqual(3, cb.up_channels[0].write_offset);
    try std.testing.expectEqualSlices(u8, "xyz", cb.buffers.up_buffer_0[0..3]);
}

test {
    _ = lock;
}
