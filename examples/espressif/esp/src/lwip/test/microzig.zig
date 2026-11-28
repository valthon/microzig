const std = @import("std");

const tx = @import("lwip").c.TxTest;

pub const config = .{ .has_board = false };
pub fn export_startup() void {}

pub const drivers = struct {
    pub const time = struct {
        pub const Deadline = struct {
            pub fn init_relative(_: Duration, _: Duration) Deadline {
                return .{};
            }
            pub fn is_reached_by(_: Deadline, _: Duration) bool {
                return false;
            }
        };
    };
};

pub const interrupt = struct {
    pub fn enter_critical_section() struct {
        pub fn leave(_: @This()) void {}
    } {
        return .{};
    }
};

// A one-slot RTOS queue that records how the caller asks the scheduler to yield.
pub const hal = struct {
    pub const radio = struct {
        pub fn read_mac(_: wifi.Interface) [6]u8 {
            return .{ 2, 0, 0, 0, 0, 1 };
        }

        pub const wifi = struct {
            pub const Interface = enum { sta };
            pub const AuthMethod = enum { none };
            pub const Config = union(enum) {
                sta: Station,

                pub const Station = struct {
                    ssid: []const u8,
                    password: []const u8,
                    auth_method: AuthMethod,
                };
            };
            pub const StaState = enum {
                connected,

                pub fn is_started(_: StaState) bool {
                    return true;
                }
            };
            const Scan = struct {
                const Record = struct {
                    ssid: []const u8,
                    rssi: i8,
                    primary_channel: u8,
                    auth_mode: ?AuthMethod,
                };

                pub fn next(_: *Scan) error{ScanFailed}!?Record {
                    return null;
                }
                pub fn deinit(_: *Scan) error{ScanFailed}!void {}
            };

            pub const Wifi = struct {
                pub fn init(_: *Wifi, _: std.mem.Allocator, _: struct {}) error{WifiRollbackPending}!void {}
                pub fn deinit(_: *Wifi) error{ WouldBlock, Timeout }!void {
                    tx.deinit();
                }
                pub fn apply(_: *Wifi, _: Config) error{WifiState}!void {}
                pub fn start(_: *Wifi) error{WifiState}!void {}
                pub fn scan(_: *Wifi, _: struct {}) error{ScanFailed}!Scan {
                    return .{};
                }
                pub fn get_sta_state(_: *Wifi) StaState {
                    return .connected;
                }
                pub fn connect(_: *Wifi) error{WifiState}!void {}
                pub fn apply_station_config(_: *Wifi, _: Config.Station) error{ WifiState, Timeout }!void {}
                pub fn send_packet(_: *Wifi, _: Interface, _: []const u8) error{WifiState}!void {
                    tx.send();
                }
            };
        };
    };

    pub const rtos = struct {
        pub var immediate_yields: usize = 0;
        pub var deferred_yields: usize = 0;
        pub var higher_priority_waiter: bool = false;
        pub var interrupt_context: bool = false;
        var task: u8 = 0;

        pub fn in_isr() bool {
            return interrupt_context;
        }

        pub fn get_current_task() *u8 {
            return &task;
        }

        pub fn sleep(_: Duration) void {}

        pub fn Signal(comptime T: type) type {
            return struct {
                pub fn put(_: *@This(), _: T) void {}
                pub fn wait(_: *@This()) void {}
            };
        }

        pub const Mutex = struct {
            locked: ?*u8 = null,
            pub fn lock(_: *Mutex) void {}
            pub fn unlock(_: *Mutex) void {}
        };

        pub fn Queue(comptime Element: type) type {
            return struct {
                const Self = @This();
                type_erased: struct { buffer: []u8 },
                full: bool = false,

                pub fn init(buffer: []Element) Self {
                    std.debug.assert(buffer.len == 1);
                    return .{ .type_erased = .{ .buffer = std.mem.sliceAsBytes(buffer) } };
                }

                pub fn put_one(queue: *Self, element: Element, _: Timeout) error{Timeout}!void {
                    var woken = false;
                    if (!queue.put_one_from_isr(element, &woken)) return error.Timeout;
                    if (woken) immediate_yields += 1;
                }

                pub fn put_one_from_isr(queue: *Self, element: Element, woken: *bool) bool {
                    if (queue.full) return false;
                    std.mem.bytesAsSlice(Element, queue.type_erased.buffer)[0] = element;
                    queue.full = true;
                    woken.* = higher_priority_waiter;
                    return true;
                }

                pub fn get_one(queue: *Self, _: Timeout) error{Timeout}!Element {
                    if (!queue.full) return error.Timeout;
                    queue.full = false;
                    return std.mem.bytesAsSlice(Element, queue.type_erased.buffer)[0];
                }
            };
        }

        pub fn yield_from_isr() void {
            deferred_yields += 1;
        }

        pub const Semaphore = struct {
            pub fn init(_: u8, _: u8) Semaphore {
                return .{};
            }
            pub fn give(_: *Semaphore) void {}
            pub fn take_with_timeout(_: *Semaphore, _: Timeout) error{Timeout}!void {}
        };

        pub fn spawn(_: std.mem.Allocator, _: anytype, _: anytype, _: struct {
            name: []const u8,
            stack_size: usize,
            priority: enum(u8) { _ },
        }) error{OutOfMemory}!?*anyopaque {
            return null;
        }
    };

    pub const rng = struct {
        pub fn random_u32() u32 {
            return 0;
        }
    };

    pub const time = struct {
        pub fn get_time_since_boot() Duration {
            return .{};
        }
    };
};

const Timeout = union(enum) {
    never,
    non_blocking,
    after: Duration,
};

const Duration = struct {
    pub fn from_ms(_: u32) Duration {
        return .{};
    }
    pub fn diff(_: Duration, _: Duration) Duration {
        return .{};
    }
    pub fn to_us(_: Duration) u64 {
        return 0;
    }
};
