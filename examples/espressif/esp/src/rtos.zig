//! C3/C6 queue demo: expected SELFTEST rtos DONE pass=6 fail=0.
//! Five ordered deliveries, then an empty-queue timeout; about four seconds.
const std = @import("std");

const microzig = @import("microzig");
const esp = microzig.hal;
const usb_serial_jtag = esp.usb_serial_jtag;
const rtos = esp.rtos;

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .logFn = usb_serial_jtag.logger.log,
    .log_level = .debug,
});

comptime {
    _ = microzig.export_startup();
}

pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt31 = rtos.interrupt_handler,
    },
    .cpu = .{
        .interrupt_stack = .{
            .enable = true,
            .size = 4096,
        },
    },
    .hal = .{
        .rtos = .{
            .enable = true,
        },
    },
};

fn task1(queue: *rtos.Queue(u32)) void {
    for (0..5) |i| {
        queue.put_one(@intCast(i), .{ .after = .from_ms(1000) }) catch |err| {
            std.log.err("producer: {s}", .{@errorName(err)});
            return;
        };
        rtos.sleep(.from_ms(500));
    }
}

pub fn main() !void {
    var heap = try microzig.Allocator.init_with_heap(4096);
    const gpa = heap.allocator();

    var buffer: [1]u32 = undefined;
    var queue: rtos.Queue(u32) = .init(&buffer);

    esp.time.sleep_ms(1000);

    const task = try rtos.spawn(gpa, task1, .{&queue}, .{});

    var delivered: [5]bool = @splat(false);
    for (&delivered, 0..) |*passed, expected| {
        const item = queue.get_one(.{ .after = .from_ms(1000) }) catch |err| {
            std.log.err("consumer: {s}", .{@errorName(err)});
            continue;
        };
        std.log.info("got item: {}", .{item});
        passed.* = item == expected;
    }
    // Joining first guarantees no producer can enqueue after the timeout check.
    rtos.wait_and_free(gpa, task);
    var timed_out = false;
    if (queue.get_one(.{ .after = .from_ms(1000) })) |extra| {
        std.log.err("unexpected extra item: {}", .{extra});
    } else |err| {
        timed_out = err == error.Timeout;
        std.log.info("consumer: {s}", .{@errorName(err)});
    }

    // Repeat the saved result so a host attaching late can still score the run.
    while (true) {
        var pass: usize = 0;
        for (delivered, 0..) |passed, i| {
            if (passed) pass += 1;
            std.log.info("SELFTEST rtos item{d}: {s} expected={d}", .{
                i, if (passed) "PASS" else "FAIL", i,
            });
        }
        if (timed_out) pass += 1;
        std.log.info("SELFTEST rtos timeout: {s}", .{if (timed_out) "PASS" else "FAIL"});
        std.log.info("SELFTEST rtos DONE pass={d} fail={d}", .{ pass, 6 - pass });
        rtos.sleep(.from_ms(1000));
    }
}
