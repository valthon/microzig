const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .esp = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const maybe_example = b.option([]const u8, "example", "only build matching examples");
    const expected_mac_text = b.option([]const u8, "expected_mac", "selftest_c6_core: the board's efuse MAC (aa:bb:cc:dd:ee:ff); unset reports SKIP");
    const expected_mac: ?u48 = if (expected_mac_text) |text| parse_mac(text) orelse
        std.process.fatal("-Dexpected_mac={s}: expected six hex bytes separated by ':'", .{text}) else null;

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const examples: []const Example = &.{
        .{ .name = "selftest_i2s", .file = "src/selftest_i2s.zig" },
        .{ .name = "selftest_parl_io", .file = "src/selftest_parl_io.zig", .chips = &.{.esp32_c6} },
        .{ .name = "selftest_dedicated_gpio", .file = "src/selftest_dedicated_gpio.zig" },
        .{ .name = "selftest_gdma", .file = "src/selftest_gdma.zig" },
        .{ .name = "selftest_ecc", .file = "src/selftest_ecc.zig", .chips = &.{.esp32_c6} },
        .{ .name = "selftest_rsa", .file = "src/selftest_rsa.zig" },
        .{ .name = "selftest_aes", .file = "src/selftest_aes.zig" },
        .{ .name = "selftest_sha", .file = "src/selftest_sha.zig" },
        .{ .name = "selftest_mcpwm", .file = "src/selftest_mcpwm.zig", .chips = &.{.esp32_c6} },
        .{ .name = "selftest_etm", .file = "src/selftest_etm.zig", .chips = &.{.esp32_c6} },
        .{ .name = "selftest_pcnt", .file = "src/selftest_pcnt.zig", .chips = &.{.esp32_c6} },
        .{ .name = "selftest_sigma_delta", .file = "src/selftest_sigma_delta.zig", .chips = &.{ .esp32_c3, .esp32_c6 } },
        .{ .name = "selftest_gpio_irq", .file = "src/selftest_gpio_irq.zig", .chips = &.{ .esp32_c3, .esp32_c6 } },
        .{ .name = "selftest_spi_dma", .file = "src/selftest_spi_dma.zig" },
        .{ .name = "selftest_sleep_s1", .file = "src/selftest_sleep.zig", .sleep_stage = 1, .chips = &.{.esp32_c3} },
        .{ .name = "selftest_sleep_s2", .file = "src/selftest_sleep.zig", .sleep_stage = 2, .chips = &.{.esp32_c3} },
        .{ .name = "selftest_sleep_s3", .file = "src/selftest_sleep.zig", .sleep_stage = 3, .chips = &.{.esp32_c3} },
        .{ .name = "selftest_sleep_s4", .file = "src/selftest_sleep.zig", .sleep_stage = 4, .chips = &.{.esp32_c3} },
        .{ .name = "selftest_sleep_s5", .file = "src/selftest_sleep.zig", .sleep_stage = 5, .chips = &.{.esp32_c3} },
        .{ .name = "selftest_sleep_s6", .file = "src/selftest_sleep.zig", .sleep_stage = 6, .chips = &.{.esp32_c3} },
        .{ .name = "selftest_sleep", .file = "src/selftest_sleep.zig", .sleep_stage = 4, .chips = &.{.esp32_c3} },
        .{ .name = "selftest_c6_ledc", .file = "src/selftest_c6_ledc.zig", .chips = &.{.esp32_c6} },
        .{ .name = "selftest_c6_core", .file = "src/selftest_c6_core.zig", .chips = &.{.esp32_c6}, .mac_option = true },
        .{ .name = "blinky", .file = "src/blinky.zig", .chips = &.{ .esp32_c3, .esp32_c6 } },
        .{ .name = "custom_clock_config", .file = "src/custom_clock_config.zig", .chips = &.{ .esp32_c3, .esp32_c6 } },
        .{ .name = "gpio_input", .file = "src/gpio_input.zig", .chips = &.{ .esp32_c3, .esp32_c6 } },
        .{ .name = "i2c_accel", .file = "src/i2c_accel.zig" },
        .{ .name = "i2c_bus_scan", .file = "src/i2c_bus_scan.zig" },
        .{ .name = "i2c_temp", .file = "src/i2c_temp.zig" },
        .{ .name = "i2c_display_sh1106", .file = "src/i2c_display_sh1106.zig" },
        .{ .chips = &.{.esp32_c3}, .name = "i2c_display_ssd1306_c3_oled_042", .file = "src/i2c_display_ssd1306_c3_oled_042.zig" },
        .{ .name = "selftest_ledc_fade", .file = "src/selftest_ledc_fade.zig", .chips = &.{.esp32_c3} },
        .{ .name = "ledc_pwm_servo", .file = "src/ledc_pwm_servo.zig" },
        .{ .name = "stepper_driver", .file = "src/stepper_driver.zig" },
        .{ .name = "stepper_driver_dumb", .file = "src/stepper_driver_dumb.zig" },
        .{ .chips = &.{ .esp32_c3, .esp32_c6 }, .name = "selftest_uart", .file = "src/selftest_uart.zig" },
        .{ .chips = &.{ .esp32_c3, .esp32_c6 }, .name = "selftest_rmt", .file = "src/selftest_rmt.zig" },
        .{ .chips = &.{ .esp32_c3, .esp32_c6 }, .name = "selftest_timers", .file = "src/selftest_timers.zig" },
        .{ .chips = &.{ .esp32_c3, .esp32_c6 }, .name = "selftest_usj", .file = "src/selftest_usj.zig" },
        .{ .name = "systimer", .file = "src/systimer.zig", .chips = &.{ .esp32_c3, .esp32_c6 } },
        .{ .chips = &.{ .esp32_c3, .esp32_c6 }, .name = "selftest_twai", .file = "src/selftest_twai.zig" },
        .{ .chips = &.{ .esp32_c3, .esp32_c6 }, .name = "selftest_flash", .file = "src/selftest_flash.zig" },
        .{ .chips = &.{ .esp32_c3, .esp32_c6 }, .name = "selftest_adc", .file = "src/selftest_adc.zig" },
        .{ .name = "ws2812_blinky", .file = "src/ws2812_blinky.zig" },
        .{ .chips = &.{.esp32_c3}, .name = "rtos", .file = "src/rtos.zig" },
        .{ .chips = &.{.esp32_c3}, .name = "tcp_server", .file = "src/tcp_server.zig", .features = .{
            .flashless = false,
            .lwip = true,
        } },
    };

    const board_examples: []const BoardExample = &.{
        .{
            .name = "board_blinky",
            .file = "src/xiao_esp32_c6_blinky.zig",
            .prefix = "xiao_esp32_c6",
            .target = mb.ports.esp.boards.seeedstudio.xiao_esp32_c6,
        },
    };

    for (examples) |example| {
        // If we specify example, only select the ones that match
        if (maybe_example) |selected_example|
            if (!std.mem.containsAtLeast(u8, example.name, 1, selected_example))
                continue;

        for (std.enums.values(TargetEnum)) |target_enum| {
            if (!example.features.flashless and std.mem.containsAtLeast(u8, @tagName(target_enum), 1, "flashless"))
                continue;

            if (std.mem.indexOfScalar(Chip, example.chips, target_enum.chip()) == null)
                continue;

            const target_desc = target_enum.get_target_desc(mb);

            // `add_firmware` basically works like addExecutable, but takes a
            // `microzig.Target` for target instead of a `std.zig.CrossTarget`.
            //
            // The target will convey all necessary information on the chip,
            // cpu and potentially the board as well.
            const fw = mb.add_firmware(.{
                .name = b.fmt("{s}_{s}", .{ target_desc.prefix, example.name }),
                .target = target_desc.target,
                .optimize = optimize,
                .root_source_file = b.path(example.file),
            });

            if (example.sleep_stage) |stage| {
                const options = b.addOptions();
                options.addOption(u8, "stage", stage);
                fw.exe.root_module.addOptions("sleep_test_options", options);
            }

            if (example.mac_option) {
                const options = b.addOptions();
                options.addOption(?u48, "expected_mac", expected_mac);
                fw.exe.root_module.addOptions("c6_core_options", options);
            }

            if (example.features.lwip) {
                const target = b.resolveTargetQuery(fw.target.zig_target);

                const foundation_dep = b.dependency("foundation_libc", .{
                    .target = target,
                    .optimize = optimize,
                    .single_threaded = true,
                });

                const lwip_dep = b.dependency("lwip", .{
                    .target = target,
                    .optimize = optimize,
                    .include_dir = b.path("src/lwip/include"),
                });

                const libc_lib = foundation_dep.artifact("foundation");
                const lwip = lwip_dep.module("lwip");

                lwip.linkLibrary(libc_lib);
                fw.exe.root_module.addImport("lwip", lwip);
            }

            // `installFirmware()` is the MicroZig pendant to `Build.installArtifact()`
            // and allows installing the firmware as a typical firmware file.
            //
            // This will also install into `$prefix/firmware` instead of `$prefix/bin`.
            mb.install_firmware(fw, .{});

            // For debugging, we also always install the firmware as an ELF file
            mb.install_firmware(fw, .{ .format = .elf });
        }
    }

    for (board_examples) |example| {
        // If we specify example, only select the ones that match
        if (maybe_example) |selected_example|
            if (!std.mem.containsAtLeast(u8, example.name, 1, selected_example))
                continue;

        const fw = mb.add_firmware(.{
            .name = b.fmt("{s}_{s}", .{ example.prefix, example.name }),
            .target = example.target,
            .optimize = optimize,
            .root_source_file = b.path(example.file),
        });

        mb.install_firmware(fw, .{});
        mb.install_firmware(fw, .{ .format = .elf });
    }
}

/// An example written against one specific board instead of a bare chip.
const BoardExample = struct {
    name: []const u8,
    file: []const u8,
    /// Prefixed to the installed firmware name.
    prefix: []const u8,
    target: *const microzig.Target,
};

const TargetEnum = enum {
    esp32_c3,
    esp32_c3_direct_boot,
    esp32_c3_flashless,
    esp32_c6,
    esp32_c6_direct_boot,
    esp32_c6_flashless,

    fn get_target_desc(target_enum: TargetEnum, mb: *MicroBuild) TargetDescription {
        return switch (target_enum) {
            .esp32_c3 => .{
                .prefix = "esp32_c3",
                .target = mb.ports.esp.chips.esp32_c3,
            },
            .esp32_c3_direct_boot => .{
                .prefix = "esp32_c3_direct_boot",
                .target = mb.ports.esp.chips.esp32_c3_direct_boot,
            },
            .esp32_c3_flashless => .{
                .prefix = "esp32_c3_flashless",
                .target = mb.ports.esp.chips.esp32_c3_flashless,
            },
            .esp32_c6 => .{
                .prefix = "esp32_c6",
                .target = mb.ports.esp.chips.esp32_c6,
            },
            .esp32_c6_direct_boot => .{
                .prefix = "esp32_c6_direct_boot",
                .target = mb.ports.esp.chips.esp32_c6_direct_boot,
            },
            .esp32_c6_flashless => .{
                .prefix = "esp32_c6_flashless",
                .target = mb.ports.esp.chips.esp32_c6_flashless,
            },
        };
    }

    fn chip(target_enum: TargetEnum) Chip {
        return switch (target_enum) {
            .esp32_c3, .esp32_c3_direct_boot, .esp32_c3_flashless => .esp32_c3,
            .esp32_c6, .esp32_c6_direct_boot, .esp32_c6_flashless => .esp32_c6,
        };
    }
};

const Chip = enum {
    esp32_c3,
    esp32_c6,
};

const TargetDescription = struct {
    prefix: []const u8,
    target: *const microzig.Target,
};

const Example = struct {
    const Features = packed struct {
        flashless: bool = true,
        lwip: bool = false,
    };

    name: []const u8,
    file: []const u8,
    features: Features = .{},
    sleep_stage: ?u8 = null,
    /// Receives `-Dexpected_mac` as module `c6_core_options`.
    mac_option: bool = false,
    /// Chips whose peripherals and board assumptions this example supports.
    chips: []const Chip = &.{ .esp32_c3, .esp32_c6 },
};

fn parse_mac(text: []const u8) ?u48 {
    var it = std.mem.splitScalar(u8, text, ':');
    var value: u48 = 0;
    var count: usize = 0;
    while (it.next()) |part| : (count += 1) {
        if (count == 6 or part.len != 2) return null;
        for (part) |char| {
            if (!std.ascii.isHex(char)) return null;
        }
        value = (value << 8) | (std.fmt.parseInt(u8, part, 16) catch return null);
    }
    return if (count == 6) value else null;
}
