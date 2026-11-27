const std = @import("std");

pub const Allocator = @import("core-allocator");
pub const drivers = @import("drivers");
pub const config = .{ .chip_name = "ESP32-C6" };

pub const radio_test = struct {
    pub var clock_source: u2 = 1;
    pub threadlocal var in_isr = false;

    pub const Mutex = struct {
        inner: std.Io.Mutex = .init,
        pub fn lock(self: *@This()) void {
            self.inner.lockUncancelable(std.testing.io);
        }
        pub fn unlock(self: *@This()) void {
            self.inner.unlock(std.testing.io);
        }
    };
};

const radio = @import("hal-under-test").radio;
const radio_options = @import("test-radio-options");

// The host application has a configured listener. Individual probes can
// temporarily replace it without changing the HAL's dispatch path.
pub var observed_wifi_event: ?*i32 = null;
pub var wifi_listener: *const fn (radio.wifi.Event) void = configured_listener;
fn configured_listener(event: radio.wifi.Event) void {
    if (observed_wifi_event) |id| id.* = @backingInt(@as(radio.wifi.EventType, event));
}

fn on_wifi_event(event: radio.wifi.Event) void {
    wifi_listener(event);
}

pub const options = .{ .hal = .{
    .radio = .{
        .wifi = radio.wifi.Options{ .on_event = on_wifi_event },
        .radios = radio.Radios{ .wifi = radio_options.wifi, .ble = radio_options.coex, .ieee802154 = radio_options.coex },
    },
    .rtos = .{ .enable = true, .priority_bits = 4, .ready_queue_force_no_buckets = false },
} };

pub const interrupt = struct {
    pub fn enter_critical_section() @This() {
        return .{};
    }

    pub fn leave(_: @This()) void {}
};
