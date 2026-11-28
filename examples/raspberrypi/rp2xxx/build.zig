const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const protocol_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/esp_peer/protocol.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    b.step("test", "Test the ESP peer protocol").dependOn(&b.addRunArtifact(protocol_tests).step);
    const maybe_example = b.option([]const u8, "example", "only build matching examples");
    const ap_security = b.option(
        enum { open, wpa_psk, wpa2_psk, wpa3_sae },
        "ap_security",
        "net-access_point security (default wpa2_psk)",
    ) orelse .wpa2_psk;
    const ap_run_s = b.option(u32, "ap_run_s", "net-access_point: reboot into the flash firmware after this many seconds (default 0, never)") orelse 0;

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const raspberrypi = mb.ports.rp2xxx.boards.raspberrypi;

    // Boards for the on-target PIO self-test. RAM images: a UF2 copy
    // loads into SRAM and leaves the board's flash untouched, so any reset
    // returns the board to the firmware already in flash.
    const xiao_rp2040_ram = raspberrypi.pico_flashless.derive(.{
        .board = .{
            .name = "Seeed XIAO RP2040 (ram image)",
            .url = "https://wiki.seeedstudio.com/XIAO-RP2040/",
            .root_source_file = b.path("src/boards/seeed_xiao_rp2040.zig"),
        },
    });
    const xiao_rp2350_ram = raspberrypi.pico2_arm_flashless.derive(.{
        .board = .{
            .name = "Seeed XIAO RP2350 (ram image)",
            .url = "https://wiki.seeedstudio.com/getting-started-xiao-rp2350/",
            .root_source_file = b.path("src/boards/seeed_xiao_rp2350.zig"),
        },
    });

    const pico2_w_ram = raspberrypi.pico2_arm_flashless.derive(.{
        .board = .{
            .name = "Raspberry Pi Pico 2 W (ram image)",
            .url = "https://datasheets.raspberrypi.com/pico/pico-2-w-datasheet.pdf",
            .root_source_file = b.path("src/boards/pico2_w.zig"),
        },
    });

    const pizero_rp2350_ram = raspberrypi.pico2_arm_flashless.derive(.{
        .board = .{
            .name = "Waveshare RP2350-PiZero (ram image)",
            .url = "https://www.waveshare.com/wiki/RP2350-PiZero",
            .root_source_file = b.path("src/boards/waveshare_rp2350_pizero.zig"),
        },
    });

    const specific_examples: []const Example = &.{
        .{ .target = pico2_w_ram, .name = "pico2_w_ram_esp_peer", .file = "src/esp_peer.zig" },
        .{ .target = pico2_w_ram, .name = "pico2_w_ram_i2c_slave_peer", .file = "src/i2c_slave_peer.zig" },
        .{ .target = pico2_w_ram, .name = "pico2_w_ram_net-access_point", .file = "src/net/access_point.zig" },
        // RaspberryPi Boards:
        .{ .target = raspberrypi.pico, .name = "pico_board_blinky", .file = "src/board_blinky.zig" },
        .{ .target = raspberrypi.pico, .name = "pico_random", .file = "src/rp2040_only/random.zig" },
        .{ .target = raspberrypi.pico, .name = "pico_rtc", .file = "src/rp2040_only/rtc.zig" },
        .{ .target = raspberrypi.pico, .name = "pico_multicore", .file = "src/blinky_core1.zig" },
        .{ .target = raspberrypi.pico, .name = "pico_hd44780", .file = "src/rp2040_only/hd44780.zig" },
        .{ .target = raspberrypi.pico, .name = "pico_pcf8574", .file = "src/rp2040_only/pcf8574.zig" },
        .{ .target = raspberrypi.pico, .name = "pico_i2c_slave", .file = "src/rp2040_only/i2c_slave.zig" },
        .{ .target = raspberrypi.pico, .name = "pico_freertos-hello-task", .file = "src/freertos/hello_task.zig" },
        .{ .target = raspberrypi.pico, .name = "pico_freertos-queue-demo", .file = "src/freertos/queue_demo.zig" },
        .{ .target = raspberrypi.pico, .name = "pico_freertos-multitask-demo", .file = "src/freertos/multitask_demo.zig" },

        .{ .target = raspberrypi.pico2_arm, .name = "pico2_arm_multicore", .file = "src/blinky_core1.zig" },
        .{ .target = raspberrypi.pico2_riscv, .name = "pico2_riscv_multicore", .file = "src/blinky_core1.zig" },
        .{ .target = raspberrypi.pico2_arm, .name = "pico2_arm_board_blinky", .file = "src/board_blinky.zig" },
        .{ .target = raspberrypi.pico2_arm, .name = "pico2_arm_freertos-hello-task", .file = "src/freertos/hello_task.zig" },
        .{ .target = raspberrypi.pico2_arm, .name = "pico2_arm_freertos-queue-demo", .file = "src/freertos/queue_demo.zig" },
        .{ .target = raspberrypi.pico2_arm, .name = "pico2_arm_freertos-multitask-demo", .file = "src/freertos/multitask_demo.zig" },

        .{ .target = raspberrypi.pico_flashless, .name = "pico_flashless_blinky", .file = "src/blinky.zig" },

        .{ .target = raspberrypi.pico2_arm_flashless, .name = "pico2_arm_flashless_blinky", .file = "src/blinky.zig" },
        .{ .target = raspberrypi.pico2_riscv_flashless, .name = "pico2_riscv_flashless_blinky", .file = "src/blinky.zig" },
        .{ .target = raspberrypi.pico2_arm_flashless, .name = "pico2_arm_flashless_system-timer", .file = "src/system_timer.zig" },
        .{ .target = raspberrypi.pico2_riscv_flashless, .name = "pico2_riscv_flashless_system-timer", .file = "src/system_timer.zig" },

        .{ .target = raspberrypi.pico2_arm, .name = "pico2_arm_random_data", .file = "src/rp2350_only/random_data.zig" },
        .{ .target = raspberrypi.pico2_riscv, .name = "pico2_riscv_random_data", .file = "src/rp2350_only/random_data.zig" },

        .{ .target = raspberrypi.pico2_arm, .name = "pico2_arm_always_on_timer", .file = "src/rp2350_only/always_on_timer.zig" },
        .{ .target = raspberrypi.pico2_riscv, .name = "pico2_riscv_always_on_timer", .file = "src/rp2350_only/always_on_timer.zig" },

        .{ .target = raspberrypi.pico2_arm, .name = "pico2_arm_pio-registers", .file = "src/rp2350_only/pio_registers.zig" },
        .{ .target = raspberrypi.pico2_riscv, .name = "pico2_riscv_pio-registers", .file = "src/rp2350_only/pio_registers.zig" },
        .{ .target = raspberrypi.pico2_arm, .name = "pico2_arm_pio-cross-irq", .file = "src/rp2350_only/pio_cross_irq.zig" },
        .{ .target = raspberrypi.pico2_riscv, .name = "pico2_riscv_pio-cross-irq", .file = "src/rp2350_only/pio_cross_irq.zig" },

        .{ .target = xiao_rp2040_ram, .name = "xiao_rp2040_ram_pio-selftest", .file = "src/pio_selftest.zig" },
        .{ .target = xiao_rp2350_ram, .name = "xiao_rp2350_ram_pio-selftest", .file = "src/pio_selftest.zig" },
        .{ .target = pizero_rp2350_ram, .name = "pizero_rp2350_ram_pio-selftest", .file = "src/pio_selftest.zig" },
        .{ .target = pico2_w_ram, .name = "pico2_w_ram_pio-selftest", .file = "src/pio_selftest.zig" },
        .{ .target = xiao_rp2040_ram, .name = "xiao_rp2040_ram_pio-selftest-nousb", .file = "src/pio_selftest_nousb.zig" },
        .{ .target = xiao_rp2350_ram, .name = "xiao_rp2350_ram_pio-selftest-nousb", .file = "src/pio_selftest_nousb.zig" },
        .{ .target = pizero_rp2350_ram, .name = "pizero_rp2350_ram_pio-selftest-nousb", .file = "src/pio_selftest_nousb.zig" },
        .{ .target = pico2_w_ram, .name = "pico2_w_ram_pio-selftest-nousb", .file = "src/pio_selftest_nousb.zig" },
        .{ .target = xiao_rp2040_ram, .name = "xiao_rp2040_ram_pio-selftest-exit", .file = "src/pio_selftest_exit.zig" },
        .{ .target = xiao_rp2350_ram, .name = "xiao_rp2350_ram_pio-selftest-exit", .file = "src/pio_selftest_exit.zig" },
        .{ .target = pizero_rp2350_ram, .name = "pizero_rp2350_ram_pio-selftest-exit", .file = "src/pio_selftest_exit.zig" },
        .{ .target = pico2_w_ram, .name = "pico2_w_ram_pio-selftest-exit", .file = "src/pio_selftest_exit.zig" },

        // Adafruit boards
        .{ .target = mb.ports.rp2xxx.boards.adafruit.feather_rp2350, .name = "adafruit_feather_rp2350_blinky", .file = "src/board_blinky.zig" },
        .{ .target = mb.ports.rp2xxx.boards.adafruit.feather_rp2350, .name = "adafruit_feather_rp2350_multicore", .file = "src/blinky_core1.zig" },
        .{ .target = mb.ports.rp2xxx.boards.adafruit.feather_rp2350, .name = "adafruit_feather_rp2350_usb-cdc", .file = "src/usb_cdc.zig" },
        .{ .target = mb.ports.rp2xxx.boards.adafruit.feather_rp2350, .name = "adafruit_feather_rp2350_usb-hid", .file = "src/usb_hid.zig" },
        .{ .target = mb.ports.rp2xxx.boards.adafruit.metro_rp2350, .name = "adafruit_metro_rp2350_blinky", .file = "src/board_blinky.zig" },

        .{ .target = mb.ports.rp2xxx.boards.adafruit.metro_rp2350, .name = "adafruit_metro_rp2350_pio-gpio-base", .file = "src/rp2350_only/pio_gpio_base.zig" },

        // WaveShare Boards:
        .{ .target = mb.ports.rp2xxx.boards.waveshare.rp2040_matrix, .name = "rp2040_matrix_tiles", .file = "src/rp2040_only/tiles.zig" },
        // .{ .target = "board:waveshare/rp2040_eth", .name = "rp2040-eth" },
        // .{ .target = "board:waveshare/rp2040_plus_4m", .name = "rp2040-plus-4m" },
        // .{ .target = "board:waveshare/rp2040_plus_16m", .name = "rp2040-plus-16m" },
    };

    const chip_agnostic_examples: []const ChipAgnosticExample = &.{
        .{ .name = "pins", .file = "src/pins.zig" },
        .{ .name = "adc", .file = "src/adc.zig" },
        .{ .name = "i2c-accel", .file = "src/i2c_accel.zig" },
        .{ .name = "i2c-bus-scan", .file = "src/i2c_bus_scan.zig" },
        .{ .name = "i2c-hall-effect", .file = "src/i2c_hall_effect.zig" },
        .{ .name = "pwm", .file = "src/pwm.zig" },
        .{ .name = "uart-echo", .file = "src/uart_echo.zig" },
        .{ .name = "uart-log", .file = "src/uart_log.zig" },
        .{ .name = "rtt-log", .file = "src/rtt_log.zig", .works_with_riscv = false },
        .{ .name = "spi-master", .file = "src/spi_master.zig" },
        .{ .name = "spi-slave", .file = "src/spi_slave.zig" },
        .{ .name = "spi-loopback-dma", .file = "src/spi_loopback_dma.zig" },
        .{ .name = "pio-sync", .file = "src/pio_sync.zig" },
        .{ .name = "pio-irq", .file = "src/pio_irq.zig" },
        .{ .name = "pio-dma-status", .file = "src/pio_dma_status.zig" },
        .{ .name = "pio-runtime", .file = "src/pio_runtime.zig" },
        .{ .name = "squarewave", .file = "src/squarewave.zig" },
        .{ .name = "ws2812", .file = "src/ws2812.zig" },
        .{ .name = "blinky", .file = "src/blinky.zig" },
        .{ .name = "ds18b20", .file = "src/ds18b20.zig" },
        .{ .name = "gpio-clock-output", .file = "src/gpio_clock_output.zig" },
        .{ .name = "gpio-interrupts", .file = "src/gpio_irq.zig" },
        .{ .name = "changing-system-clocks", .file = "src/changing_system_clocks.zig" },
        .{ .name = "custom-clock-config", .file = "src/custom_clock_config.zig" },
        .{ .name = "watchdog-timer", .file = "src/watchdog_timer.zig" },
        .{ .name = "system_timer", .file = "src/system_timer.zig" },
        .{ .name = "stepper_driver", .file = "src/stepper_driver.zig" },
        .{ .name = "stepper_driver_dumb", .file = "src/stepper_driver_dumb.zig" },
        .{ .name = "usb-hid", .file = "src/usb_hid.zig" },
        .{ .name = "usb-cdc", .file = "src/usb_cdc.zig" },
        .{ .name = "usb-raw-echo", .file = "src/usb_raw_echo.zig" },
        .{ .name = "dma", .file = "src/dma.zig" },
        .{ .name = "cyw43", .file = "src/cyw43.zig" },
        .{ .name = "cyw43-blinky", .file = "src/cyw43/blinky.zig" },
        .{ .name = "cyw43-wifi-scan", .file = "src/cyw43/wifi_scan.zig" },
        .{ .name = "cyw43-wifi-connect", .file = "src/cyw43/wifi_connect.zig" },
        .{ .name = "allocator", .file = "src/allocator.zig" },
        .{ .name = "mlx90640", .file = "src/mlx90640.zig" },
        .{ .name = "mlx90640-image", .file = "src/mlx90640_image.zig" },
        .{ .name = "mlx90640-hottest-point", .file = "src/mlx90640_hottest_point.zig" },
        //.{ .name = "ssd1306", .file = "src/ssd1306_oled.zig" },
        .{ .name = "st7789", .file = "src/st7789_lcd.zig" },
        .{ .name = "net-pong", .file = "src/net/pong.zig" },
        .{ .name = "net-irq", .file = "src/net/irq.zig" },
        .{ .name = "net-scan", .file = "src/net/scan.zig" },
        .{ .name = "net-udp", .file = "src/net/udp.zig" },
        .{ .name = "net-tcp_client", .file = "src/net/tcp_client.zig" },
        .{ .name = "net-tcp_server", .file = "src/net/tcp_server.zig" },
        .{ .name = "net-access_point", .file = "src/net/access_point.zig" },
        .{ .name = "board-id", .file = "src/board_id.zig" },
        .{ .name = "flash-program", .file = "src/flash_program.zig" },
    };

    var available_examples: std.ArrayList(Example) = .empty;
    available_examples.appendSlice(b.allocator, specific_examples) catch @panic("out of memory");
    for (chip_agnostic_examples) |example| {
        available_examples.append(b.allocator, .{
            .target = raspberrypi.pico,
            .name = b.fmt("pico_{s}", .{example.name}),
            .file = example.file,
            .imports = example.imports,
        }) catch @panic("out of memory");

        available_examples.append(b.allocator, .{
            .target = raspberrypi.pico2_arm,
            .name = b.fmt("pico2_arm_{s}", .{example.name}),
            .file = example.file,
            .imports = example.imports,
        }) catch @panic("out of memory");

        if (example.works_with_riscv) {
            available_examples.append(b.allocator, .{
                .target = raspberrypi.pico2_riscv,
                .name = b.fmt("pico2_riscv_{s}", .{example.name}),
                .file = example.file,
                .imports = example.imports,
            }) catch @panic("out of memory");
        }
    }

    for (available_examples.items) |example| {
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
            .imports = example.imports,
        });

        // Import net module for some examples
        if (std.mem.find(u8, example.name, "_net-") != null) {
            const net_dep = b.dependency("net", .{
                .target = b.resolveTargetQuery(fw.target.zig_target),
                .optimize = optimize,
                .mtu = 1500,
                // Cyw43 driver requires 22 bytes of header and 4 bytes of footer.
                // header + ethernet + mtu + footer = 22 + 14 + 1500 + 4 = 1540
                .pbuf_length = 1540,
                .pbuf_header_length = 22,
            });
            const net_mod = net_dep.module("net");
            fw.exe.root_module.addImport("net", net_mod);
        }

        if (std.mem.find(u8, example.name, "_net-access_point") != null) {
            fw.exe.root_module.addImport("dhcp_server", b.dependency("dhcp_server", .{}).module("dhcp_server"));
            const options = b.addOptions();
            options.addOption([]const u8, "security", @tagName(ap_security));
            options.addOption(u32, "run_s", ap_run_s);
            fw.exe.root_module.addOptions("ap_options", options);
        }

        // Import freertos module for some examples, kind of a hack
        // probably list of required modules should be specified in each example independently
        if (std.mem.find(u8, example.name, "_freertos-") != null) {
            var port_name: []const u8 = "Unknown";

            // FIXME: hacky way to select port based on target name (it doesn't take RP2350_RISCV into account)
            if (std.mem.eql(u8, fw.target.chip.name, "RP2040")) {
                port_name = "RP2040";
            } else {
                port_name = "RP2350_ARM";
            }

            const freertos_dep = b.dependency("freertos", .{
                .target = b.resolveTargetQuery(fw.target.zig_target),
                .optimize = optimize,
                .port_name = port_name,
            });
            const freertos_mod = freertos_dep.module("freertos");
            fw.exe.root_module.addImport("freertos", freertos_mod);
        }

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
    imports: []const std.Build.Module.Import = &.{},
};

const ChipAgnosticExample = struct {
    name: []const u8,
    file: []const u8,
    works_with_riscv: bool = true,
    imports: []const std.Build.Module.Import = &.{},
};
