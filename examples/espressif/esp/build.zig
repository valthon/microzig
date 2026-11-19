const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .esp = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const maybe_example = b.option([]const u8, "example", "only build matching examples");
    const wifi_ssid = b.option([]const u8, "wifi_ssid", "Wi-Fi station SSID for tcp_server and selftest_wifi_lifecycle") orelse "SSID";
    const wifi_password = b.option([]const u8, "wifi_password", "Wi-Fi station passphrase for tcp_server and selftest_wifi_lifecycle") orelse "";
    // Names of hal.radio.wifi.AuthMethod; the station joins no AP weaker than this.
    const wifi_auth = b.option([]const u8, "wifi_auth", "Weakest AP auth the station accepts, a hal.radio.wifi.AuthMethod name (default: wpa2_personal with a passphrase, none without)") orelse
        if (wifi_password.len != 0) "wpa2_personal" else "none";
    // tcp_server (also imported by selftest_wifi_lifecycle) validates this
    // with std.meta.stringToEnum(AuthMethod, ...). Keep the enum as the only
    // source of accepted names instead of maintaining a second list here.
    if (wifi_password.len == 0 and !std.mem.eql(u8, wifi_auth, "none"))
        std.process.fatal("-Dwifi_auth={s} needs -Dwifi_password", .{wifi_auth});
    const expected_mac_text = b.option([]const u8, "expected_mac", "selftest_c6_core: the board's efuse MAC (aa:bb:cc:dd:ee:ff); unset reports SKIP");
    const ble_scan_seconds = b.option(u32, "ble_scan_seconds", "BLE observer scan duration (1..3600 seconds)") orelse 10;
    if (ble_scan_seconds == 0 or ble_scan_seconds > 3600) @panic("ble_scan_seconds must be in 1..3600");
    const antenna = b.option(Antenna, "antenna", "Antenna the XIAO ESP32C6 builds of the BLE and 802.15.4 examples select (default internal)") orelse .internal;
    const ble_peer_name = b.option([]const u8, "ble_peer_name", "BLE central peer advertised name") orelse "H2-PEER";
    if (ble_peer_name.len == 0 or ble_peer_name.len > 31) @panic("ble_peer_name must be 1..31 bytes");
    const softap_ssid = b.option([]const u8, "softap_ssid", "SoftAP SSID (1..32 bytes)") orelse "microzig-softap";
    const softap_password = b.option([]const u8, "softap_password", "SoftAP WPA2 passphrase (8..63 printable ASCII bytes)") orelse "microzig-demo";
    if (softap_ssid.len == 0 or softap_ssid.len > 32)
        std.process.fatal("SoftAP SSID must be 1..32 bytes", .{});
    if (softap_password.len < 8 or softap_password.len > 63)
        std.process.fatal("SoftAP passphrase must be 8..63 printable ASCII bytes", .{});
    for (softap_password) |ch| {
        if (ch < 32 or ch > 126) std.process.fatal("SoftAP passphrase must be printable ASCII", .{});
    }
    const dhcp_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/softap_dhcp.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    b.step("test", "Test the example-local DHCP server").dependOn(&b.addRunArtifact(dhcp_tests).step);
    const expected_mac: ?u48 = if (expected_mac_text) |text| parse_mac(text) orelse
        std.process.fatal("-Dexpected_mac={s}: expected six hex bytes separated by ':'", .{text}) else null;

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    var lp_images: [std.enums.values(LpImage).len]*MicroBuild.Firmware = undefined;
    for (std.enums.values(LpImage)) |image| {
        const lp = mb.add_firmware(.{
            .name = b.fmt("esp32_c6_lp_{s}", .{@tagName(image)}),
            .target = mb.ports.esp.chips.esp32_c6_lp,
            .optimize = optimize,
            .root_source_file = b.path(b.fmt("src/lp_{s}.zig", .{@tagName(image)})),
        });
        lp_images[@backingInt(image)] = lp;
        mb.install_firmware(lp, .{});
        mb.install_firmware(lp, .{ .format = .elf });
    }

    const examples: []const Example = &.{
        .{ .name = "compile_wifi", .file = "src/compile_wifi.zig", .chips = &.{ .esp32_c3, .esp32_c6 }, .features = .{ .image_boot_only = true } },
        .{ .name = "selftest_ieee802154", .file = "src/selftest_ieee802154.zig", .chips = &.{.esp32_c6}, .antenna_option = true, .features = .{ .image_boot_only = true } },
        .{ .name = "softap", .file = "src/softap.zig", .features = .{ .image_boot_only = true, .flashless = false, .lwip = true } },
        .{ .name = "selftest_lp_irq", .file = "src/selftest_lp_irq.zig", .chips = &.{.esp32_c6}, .lp_image = .irq },
        .{ .name = "selftest_lp_i2c", .file = "src/selftest_lp_i2c.zig", .chips = &.{.esp32_c6}, .lp_image = .i2c },
        .{ .name = "selftest_lp_uart", .file = "src/selftest_lp_uart.zig", .chips = &.{.esp32_c6}, .lp_image = .uart },
        .{ .name = "selftest_lp_timer", .file = "src/selftest_lp_timer.zig", .chips = &.{.esp32_c6}, .lp_image = .timer },
        .{ .name = "selftest_lp_core", .file = "src/selftest_lp_core.zig", .chips = &.{.esp32_c6}, .lp_image = .counter },
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
        .{ .chips = &.{ .esp32_c3, .esp32_c6 }, .name = "rtos", .file = "src/rtos.zig" },
        .{ .chips = &.{ .esp32_c3, .esp32_c6 }, .name = "selftest_wifi_lifecycle", .file = "src/selftest_wifi_lifecycle.zig", .wifi_options = true, .features = .{
            .flashless = false,
            .lwip = true,
        } },
        .{ .chips = &.{ .esp32_c3, .esp32_c6 }, .name = "tcp_server", .file = "src/tcp_server.zig", .wifi_options = true, .features = .{
            .flashless = false,
            .lwip = true,
        } },
        .{ .name = "selftest_ble_hci", .file = "src/selftest_ble_hci.zig", .chips = &.{.esp32_c6}, .features = .{ .image_boot_only = true } },
        .{ .name = "ble_scan", .file = "src/ble_scan.zig", .chips = &.{.esp32_c6}, .ble_options = true, .features = .{ .image_boot_only = true } },
        .{ .name = "ble_peripheral", .file = "src/ble_peripheral.zig", .chips = &.{.esp32_c6}, .ble_options = true, .features = .{ .image_boot_only = true } },
        .{ .name = "ble_central", .file = "src/ble_central.zig", .chips = &.{.esp32_c6}, .ble_options = true, .features = .{ .image_boot_only = true } },
    };

    const board_examples: []const BoardExample = &.{
        .{
            .name = "board_blinky",
            .file = "src/xiao_esp32_c6_blinky.zig",
            .prefix = "xiao_esp32_c6",
            .target = mb.ports.esp.boards.seeedstudio.xiao_esp32_c6,
        },
        // The radio examples again, for the XIAO's rf switch (see ble_bench.run).
        .{ .name = "ble_scan", .file = "src/ble_scan.zig", .prefix = "xiao_esp32_c6", .target = mb.ports.esp.boards.seeedstudio.xiao_esp32_c6, .ble_options = true },
        .{ .name = "ble_peripheral", .file = "src/ble_peripheral.zig", .prefix = "xiao_esp32_c6", .target = mb.ports.esp.boards.seeedstudio.xiao_esp32_c6, .ble_options = true },
        .{ .name = "ble_central", .file = "src/ble_central.zig", .prefix = "xiao_esp32_c6", .target = mb.ports.esp.boards.seeedstudio.xiao_esp32_c6, .ble_options = true },
        // The radio self-test again, for the XIAO's rf switch (see its main).
        .{
            .name = "selftest_ieee802154",
            .file = "src/selftest_ieee802154.zig",
            .prefix = "xiao_esp32_c6",
            .target = mb.ports.esp.boards.seeedstudio.xiao_esp32_c6,
            .antenna_option = true,
        },
    };

    for (examples) |example| {
        // If we specify example, only select the ones that match
        if (maybe_example) |selected_example|
            if (!std.mem.containsAtLeast(u8, example.name, 1, selected_example))
                continue;

        for (std.enums.values(TargetEnum)) |target_enum| {
            if (example.features.image_boot_only and target_enum != .esp32_c3 and target_enum != .esp32_c6)
                continue;
            // C6 lwIP images need flash capacity for the Wi-Fi blobs and TCP/IP stack;
            // build the image-boot target, excluding direct-boot and RAM-only variants.
            if (example.features.lwip and target_enum.chip() == .esp32_c6 and target_enum != .esp32_c6)
                continue;

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

            if (example.lp_image) |image| {
                fw.exe.root_module.addAnonymousImport("lp_image", .{ .root_source_file = lp_images[@backingInt(image)].get_emitted_bin(.binary) });
            }

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
            if (example.ble_options) add_ble_options(b, fw, ble_scan_seconds, ble_peer_name);
            if (example.ble_options or example.antenna_option) add_antenna_option(b, fw, antenna);

            if (example.wifi_options) {
                const options = b.addOptions();
                options.addOption([]const u8, "ssid", wifi_ssid);
                options.addOption([]const u8, "password", wifi_password);
                options.addOption([]const u8, "auth", wifi_auth);
                fw.exe.root_module.addOptions("wifi_options", options);
            }

            if (std.mem.eql(u8, example.name, "softap")) {
                const options = b.addOptions();
                options.addOption([]const u8, "ssid", softap_ssid);
                options.addOption([]const u8, "password", softap_password);
                fw.exe.root_module.addOptions("softap_options", options);
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
        if (example.ble_options) add_ble_options(b, fw, ble_scan_seconds, ble_peer_name);
        if (example.ble_options or example.antenna_option) add_antenna_option(b, fw, antenna);

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
    /// Receives `-Dble_scan_seconds` and `-Dble_peer_name` as module `ble_options`,
    /// and `-Dantenna` as module `antenna_options`.
    ble_options: bool = false,
    /// Receives `-Dantenna` as module `antenna_options`.
    antenna_option: bool = false,
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
        image_boot_only: bool = false,
        lwip: bool = false,
    };

    name: []const u8,
    file: []const u8,
    features: Features = .{},
    sleep_stage: ?u8 = null,
    /// Receives `-Dexpected_mac` as module `c6_core_options`.
    mac_option: bool = false,
    /// Receives station credentials as module `wifi_options`.
    wifi_options: bool = false,
    /// Receives BLE options as `ble_options` and `-Dantenna` as `antenna_options`.
    ble_options: bool = false,
    /// Receives `-Dantenna` as module `antenna_options`.
    antenna_option: bool = false,
    lp_image: ?LpImage = null,
    /// Chips whose peripherals and board assumptions this example supports.
    chips: []const Chip = &.{ .esp32_c3, .esp32_c6 },
};

fn add_ble_options(b: *std.Build, fw: *MicroBuild.Firmware, scan_seconds: u32, peer_name: []const u8) void {
    const options = b.addOptions();
    options.addOption(u32, "scan_seconds", scan_seconds);
    options.addOption([]const u8, "peer_name", peer_name);
    fw.exe.root_module.addOptions("ble_options", options);
}

/// Mirrors the XIAO ESP32C6 board's `antenna.Selection`.
const Antenna = enum { internal, external };

fn add_antenna_option(b: *std.Build, fw: *MicroBuild.Firmware, antenna: Antenna) void {
    const options = b.addOptions();
    options.addOption(Antenna, "antenna", antenna);
    fw.exe.root_module.addOptions("antenna_options", options);
}

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

const LpImage = enum { counter, timer, uart, i2c, irq };
