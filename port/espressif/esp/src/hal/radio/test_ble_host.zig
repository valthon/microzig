//! Hardware-free MicroZig configuration for the BLE-only OSI scheduler test.
pub const config = .{ .chip_name = "ESP32-C6" };
pub const ble_scheduler_test = {};
pub const drivers = @import("drivers");

const hal = @import("hal-under-test");

pub const options = .{ .hal = .{
    .radio = .{ .radios = hal.radio.Radios{ .wifi = false, .ble = true } },
    .rtos = .{
        .enable = true,
        .priority_bits = 4,
        .ready_queue_force_no_buckets = false,
        .preempt_same_priority_tasks_on_tick = false,
    },
} };

pub const radio_test = struct {
    pub const in_isr = false;
};

pub const interrupt = struct {
    pub fn enter_critical_section() @This() {
        return .{};
    }

    pub fn leave(_: @This()) void {}
};
