const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .nrf5x = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const maybe_example = b.option([]const u8, "example", "only build matching examples");

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const nrf52840_dongle = mb.ports.nrf5x.boards.nordic.nrf52840_dongle;
    const nrf52840_mdk = mb.ports.nrf5x.boards.nordic.nrf52840_mdk;
    const pca10040 = mb.ports.nrf5x.boards.nordic.pca10040;
    const microbit_v1 = mb.ports.nrf5x.boards.bbc.microbit_v1;
    const microbit_v2 = mb.ports.nrf5x.boards.bbc.microbit_v2;
    const nice_nano = mb.ports.nrf5x.boards.nicekeyboards.nice_nano;
    const xiao_nrf52840_sense = mb.ports.nrf5x.boards.seeed.xiao_nrf52840_sense;

    const available_examples = [_]Example{
        .{ .target = nrf52840_dongle, .name = "nrf52840_dongle_blinky", .file = "src/blinky.zig" },

        .{ .target = nrf52840_mdk, .name = "nrf52840_mdk_blinky", .file = "src/blinky.zig" },
        .{ .target = nrf52840_mdk, .name = "nrf52840_mdk_uart", .file = "src/uart.zig" },
        .{ .target = nrf52840_mdk, .name = "nrf52840_mdk_i2c_bus_scan", .file = "src/i2c_bus_scan.zig" },
        .{ .target = nrf52840_mdk, .name = "nrf52840_mdk_i2c_accel", .file = "src/i2c_accel.zig" },
        .{ .target = nrf52840_mdk, .name = "nrf52840_mdk_i2c_hall_effect", .file = "src/i2c_hall_effect.zig" },
        .{ .target = nrf52840_mdk, .name = "nrf52840_mdk_i2c_position_sensor", .file = "src/i2c_position_sensor.zig" },
        .{ .target = nrf52840_mdk, .name = "nrf52840_mdk_i2c_temp", .file = "src/i2c_temp.zig" },
        .{ .target = nrf52840_mdk, .name = "nrf52840_mdk_rtt_log", .file = "src/rtt_log.zig" },
        .{ .target = nrf52840_mdk, .name = "nrf52840_mdk_semihosting", .file = "src/semihosting.zig" },
        .{ .target = nrf52840_mdk, .name = "nrf52840_mdk_spi_master", .file = "src/spi_master.zig" },
        .{ .target = nrf52840_mdk, .name = "nrf52840_mdk_usb_hid", .file = "src/usb_hid.zig" },
        .{ .target = nrf52840_mdk, .name = "nrf52840_mdk_usb_cdc", .file = "src/usb_cdc.zig" },

        .{ .target = pca10040, .name = "pca10040_blinky", .file = "src/blinky.zig" },
        .{ .target = pca10040, .name = "pca10040_uart", .file = "src/uart.zig" },
        .{ .target = pca10040, .name = "pca10040_i2c_bus_scan", .file = "src/i2c_bus_scan.zig" },
        .{ .target = pca10040, .name = "pca10040_i2c_temp", .file = "src/i2c_temp.zig" },
        .{ .target = pca10040, .name = "pca10040_spi_master", .file = "src/spi_master.zig" },

        .{ .target = microbit_v1, .name = "microbit_v1_display", .file = "src/microbit/display.zig" },
        .{ .target = microbit_v2, .name = "microbit_v2_display", .file = "src/microbit/display.zig" },

        // A UF2 image for a flash region that starts behind a SoftDevice, at 0x26000.
        .{ .target = nice_nano, .name = "nice_nano_uart", .file = "src/uart.zig" },

        // UF2 images for the flash behind the board's SoftDevice S140 v7, at 0x27000.
        .{ .target = xiao_nrf52840_sense, .name = "xiao_nrf52840_sense_blinky", .file = "src/blinky.zig" },
        .{ .target = xiao_nrf52840_sense, .name = "xiao_nrf52840_sense_usb_cdc", .file = "src/usb_cdc.zig" },
        .{ .target = xiao_nrf52840_sense, .name = "xiao_nrf52840_sense_probe", .file = "src/xiao_probe.zig" },
        .{ .target = xiao_nrf52840_sense, .name = "xiao_nrf52840_sense_selftest_harness", .file = "src/selftest/harness_check.zig" },
        .{ .target = xiao_nrf52840_sense, .name = "xiao_nrf52840_sense_selftest_harness_min", .file = "src/selftest/harness_min.zig" },
        .{ .target = xiao_nrf52840_sense, .name = "xiao_nrf52840_sense_fallback_hang", .file = "src/selftest/fallback_hang.zig" },
        .{ .target = xiao_nrf52840_sense, .name = "xiao_nrf52840_sense_selftest_timing", .file = "src/selftest/timing.zig" },
        .{ .target = xiao_nrf52840_sense, .name = "xiao_nrf52840_sense_selftest_storage", .file = "src/selftest/storage.zig" },
        .{ .target = xiao_nrf52840_sense, .name = "xiao_nrf52840_sense_selftest_analog", .file = "src/selftest/analog.zig" },
        .{ .target = xiao_nrf52840_sense, .name = "xiao_nrf52840_sense_selftest_sense", .file = "src/selftest/sense.zig" },
    };

    for (available_examples) |example| {
        // If we specify example, only select the ones that match
        if (maybe_example) |selected_example|
            if (!std.mem.containsAtLeast(u8, example.name, 1, selected_example))
                continue;

        // `add_firmware` basically works like addExecutable, but takes a
        // `microzig.Target` for target instead of a `std.zig.CrossTarget`.
        //
        // The target will convey all necessary information on the chip,
        // cpu and potentially the board as well.
        const fw = mb.add_firmware(.{
            .name = example.name,
            .target = example.target,
            .optimize = optimize,
            .root_source_file = b.path(example.file),
        });

        fw.exe.root_module.addImport("cdc_console", b.createModule(.{
            .root_source_file = b.path("src/cdc_console.zig"),
            .imports = &.{.{ .name = "microzig", .module = fw.core_mod }},
        }));

        // `install_firmware()` is the MicroZig pendant to `Build.installArtifact()`
        // and allows installing the firmware as a typical firmware file.
        //
        // This will also install into `$prefix/firmware` instead of `$prefix/bin`.
        mb.install_firmware(fw, .{});

        // For debugging, we also always install the firmware as an ELF file
        mb.install_firmware(fw, .{ .format = .elf });
    }
}

const Example = struct {
    target: *const microzig.Target,
    name: []const u8,
    file: []const u8,
};
