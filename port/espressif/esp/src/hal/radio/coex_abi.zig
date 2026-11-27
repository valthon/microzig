//! IDF v5.5.1 esp_coex/include/private/esp_coexist_adapter.h:16-52.
const std = @import("std");
const Handle = ?*anyopaque;
const IsrSemaphoreFn = *const fn (Handle, ?*i32) callconv(.c) i32;
pub const Adapter = extern struct {
    version: i32 = 2,
    task_yield_from_isr: *const fn () callconv(.c) void,
    semphr_create: *const fn (u32, u32) callconv(.c) Handle,
    semphr_delete: *const fn (Handle) callconv(.c) void,
    semphr_take_from_isr: IsrSemaphoreFn,
    semphr_give_from_isr: IsrSemaphoreFn,
    semphr_take: *const fn (Handle, u32) callconv(.c) i32,
    semphr_give: *const fn (Handle) callconv(.c) i32,
    is_in_isr: *const fn () callconv(.c) c_int,
    malloc_internal: *const fn (usize) callconv(.c) Handle,
    free: *const fn (Handle) callconv(.c) void,
    esp_timer_get_time: *const fn () callconv(.c) i64,
    env_is_chip: *const fn () callconv(.c) bool,
    timer_disarm: *const fn (Handle) callconv(.c) void,
    timer_done: *const fn (Handle) callconv(.c) void,
    timer_setfn: *const fn (Handle, Handle, Handle) callconv(.c) void,
    timer_arm_us: *const fn (Handle, u32, bool) callconv(.c) void,
    debug_matrix_init: *const fn (c_int, c_int, bool) callconv(.c) c_int,
    xtal_freq_get: *const fn () callconv(.c) c_int,
    magic: u32 = 0xdeadbeaf,
};

// The blob reads magic at a fixed offset on RV32.
comptime {
    if (@sizeOf(usize) == 4 and (@offsetOf(Adapter, "magic") != 0x4c or @sizeOf(Adapter) != 0x50))
        @compileError("unexpected C6 coex adapter layout");
}

pub const InitError = error{ CoexAdapterRegistrationFailed, CoexPreInitFailed };

// IDF v5.5.1 esp_system/startup_funcs.c:157-163. The pinned coex_schm_init
// calls timer_setfn synchronously but its void ABI cannot report allocation failure.
pub fn Startup(comptime Timer: type) type {
    return struct {
        reserved: ?*Timer = null,

        pub fn start(self: *@This(), allocator: std.mem.Allocator, adapter: *Adapter, register: anytype, pre_init: anytype) (InitError || std.mem.Allocator.Error)!void {
            if (register(adapter) != 0) return error.CoexAdapterRegistrationFailed;
            self.reserved = try allocator.create(Timer);
            defer if (self.reserved) |unused| {
                allocator.destroy(unused);
                self.reserved = null;
            };
            if (pre_init() != 0 or self.reserved != null) return error.CoexPreInitFailed;
        }

        // The synchronous setfn callback transfers this allocation to timer_list.
        pub fn take_timer(self: *@This()) *Timer {
            // libcoexist calls timer_setfn only from coex_schm_init, reached
            // only through the coex_pre_init that start() runs.
            const node = self.reserved orelse @panic("coex timer_setfn outside coex_pre_init");
            self.reserved = null;
            return node;
        }
    };
}

test "BLE controller coex table matches bt/controller/esp32c6/bt.c:86-92,485-491" {
    const Stub = struct {
        fn status(_: u32, _: u32) callconv(.c) void {}
    };
    const table: @import("ble/abi.zig").CoexFuncs = .{ .set = Stub.status, .clear = Stub.status };
    try std.testing.expectEqual(@as(u32, 0xfadebead), table.magic);
    try std.testing.expectEqual(@as(u32, 0x00010006), table.version);
}
