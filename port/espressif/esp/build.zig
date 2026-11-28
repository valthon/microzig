const std = @import("std");
const Import = std.Build.Module.Import;
const microzig = @import("microzig/build-internals");

const Self = @This();

chips: struct {
    esp32_c3: *const microzig.Target,
    esp32_c3_direct_boot: *const microzig.Target,
    esp32_c3_flashless: *const microzig.Target,
    esp32_c6: *const microzig.Target,
    esp32_c6_lp: *const microzig.Target,
    esp32_c6_direct_boot: *const microzig.Target,
    esp32_c6_flashless: *const microzig.Target,
},

boards: struct {
    seeedstudio: struct {
        xiao_esp32_c6: *const microzig.Target,
    },
},

pub fn init(dep: *std.Build.Dependency) ?Self {
    const b = dep.builder;

    const esp32_c3_zig_target: std.Target.Query = .{
        .cpu_arch = .riscv32,
        .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
        .cpu_features_add = std.Target.riscv.featureSet(&.{
            .c,
            .m,
            .zicsr,
            .zifencei,
        }),
        .os_tag = .freestanding,
        .abi = .eabi,
    };

    const interrupt_encoding = b.createModule(.{
        .root_source_file = b.path("src/hal/interrupt_encoding.zig"),
    });

    // The esp32c6 high performance core is rv32imac, it has the atomics extension the esp32c3
    // core lacks.
    const esp32_c6_zig_target: std.Target.Query = .{
        .cpu_arch = .riscv32,
        .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
        .cpu_features_add = std.Target.riscv.featureSet(&.{
            .a,
            .c,
            .m,
            .zicsr,
            .zifencei,
        }),
        .os_tag = .freestanding,
        .abi = .eabi,
    };

    const riscv32_common_dep = b.dependency("microzig/modules/riscv32-common", .{});
    const riscv32_common_mod = riscv32_common_dep.module("riscv32-common");

    const esp_image_dep = b.dependency("microzig/tools/esp-image", .{});
    const esp_image_mod = esp_image_dep.module("esp_image");

    const esp_wifi_sys_dep = b.lazyDependency("esp-wifi-sys", .{}) orelse return null;
    const esp_wifi_driver_mod = make_esp_wifi_driver_module(b, esp_wifi_sys_dep, "esp32c3", esp32_c3_zig_target);

    const esp32_c6_wifi_driver_mod = make_esp_wifi_driver_module(b, esp_wifi_sys_dep, "esp32c6", esp32_c6_zig_target);

    const chip_esp32_c3: microzig.Target = .{
        .dep = dep,
        .preferred_binary_format = .{ .esp = .{
            .chip_id = .esp32_c3,
            .flash_mode = .dio,
            .flash_size = .@"4mb",
            .flash_freq = .@"40m",
        } },
        .zig_target = esp32_c3_zig_target,
        .cpu = .{
            .name = "esp_riscv",
            .root_source_file = b.path("src/cpus/esp_riscv.zig"),
            .imports = b.allocator.dupe(Import, &.{
                .{
                    .name = "cpu-config",
                    .module = get_cpu_config(b, .esp32_c3, .image),
                },
                .{
                    .name = "riscv32-common",
                    .module = riscv32_common_mod,
                },
                .{ .name = "interrupt-encoding", .module = interrupt_encoding },
            }) catch @panic("OOM"),
        },
        .chip = .{
            .name = "ESP32-C3",
            .url = "https://www.espressif.com/en/products/socs/esp32-c3",
            .register_definition = .{ .svd = b.path("src/chips/ESP32-C3.svd") },
            .patch_files = &.{b.path("patches/esp32_c3.zon")},
            .memory_regions = &.{
                .{ .name = "IROM", .offset = 0x4200_0000, .length = 0x0080_0000, .access = .rx },
                .{ .name = "DROM", .offset = 0x3C00_0000, .length = 0x0080_0000, .access = .r },
                .{ .name = "IRAM", .offset = 0x4037C000 + 0x4000, .length = 313 * 1024, .access = .x },
                // tag for stack
                .{ .name = "DRAM", .tag = .ram, .offset = 0x3FC7C000 + 0x4000, .length = 313 * 1024, .access = .rw },
            },
        },
        .hal = .{
            .root_source_file = b.path("src/hal.zig"),
            .imports = b.allocator.dupe(std.Build.Module.Import, &.{
                .{
                    .name = "interrupt-encoding",
                    .module = interrupt_encoding,
                },
                .{
                    .name = "esp_image",
                    .module = esp_image_mod,
                },
                .{
                    .name = "esp-wifi-driver",
                    .module = esp_wifi_driver_mod,
                },
            }) catch @panic("OOM"),
        },
        .linker_script = .{
            .generate = .memory_regions,
            .file = generate_linker_script(
                dep,
                "final.ld",
                &.{
                    b.path("ld/esp32_c3/image_boot_sections.ld"),
                    b.path("ld/esp32_c3/common_sections.ld"),
                    b.path("ld/esp32_c3/rom_functions.ld"),
                },
            ),
        },
    };

    const chip_esp32_c6: microzig.Target = .{
        .dep = dep,
        .preferred_binary_format = .{ .esp = .{
            .chip_id = .esp32_c6,
            .flash_mode = .dio,
            .flash_size = .@"4mb",
            .flash_freq = .@"40m",
        } },
        .zig_target = esp32_c6_zig_target,
        .cpu = .{
            .name = "esp_riscv",
            .root_source_file = b.path("src/cpus/esp_riscv.zig"),
            .imports = b.allocator.dupe(Import, &.{
                .{
                    .name = "cpu-config",
                    .module = get_cpu_config(b, .esp32_c6, .image),
                },
                .{
                    .name = "riscv32-common",
                    .module = riscv32_common_mod,
                },
                .{ .name = "interrupt-encoding", .module = interrupt_encoding },
            }) catch @panic("OOM"),
        },
        .chip = .{
            .name = "ESP32-C6",
            .url = "https://www.espressif.com/en/products/socs/esp32-c6",
            .register_definition = .{ .svd = b.path("src/chips/ESP32-C6.svd") },
            .patch_files = &.{b.path("patches/esp32_c6.zon")},
            .memory_regions = &.{
                // The instruction and the data view of the flash share one address space on this
                // chip, both start at 0x42000000.
                .{ .name = "IROM", .offset = 0x4200_0000, .length = 0x0080_0000, .access = .rx },
                .{ .name = "DROM", .offset = 0x4200_0000, .length = 0x0080_0000, .access = .r },
                // Same for the 512 KiB of HP SRAM. Everything from 0x4086E610 up is taken by the
                // rom: shared download buffers, the rom stack and the rom .bss/.data.
                .{ .name = "IRAM", .offset = 0x4080_0000, .length = 0x4086_E610 - 0x4080_0000, .access = .x },
                // tag for stack
                .{ .name = "DRAM", .tag = .ram, .offset = 0x4080_0000, .length = 0x4086_E610 - 0x4080_0000, .access = .rw },
            },
        },
        .hal = .{
            .root_source_file = b.path("src/hal.zig"),
            .imports = b.allocator.dupe(std.Build.Module.Import, &.{
                .{
                    .name = "interrupt-encoding",
                    .module = interrupt_encoding,
                },
                .{
                    .name = "esp_image",
                    .module = esp_image_mod,
                },
                .{
                    .name = "esp-wifi-driver",
                    .module = esp32_c6_wifi_driver_mod,
                },
            }) catch @panic("OOM"),
        },
        .linker_script = .{
            .generate = .memory_regions,
            .file = generate_linker_script(
                dep,
                "final.ld",
                &.{
                    b.path("ld/esp32_c6/image_boot_sections.ld"),
                    b.path("ld/esp32_c6/rom_functions.ld"),
                    b.path("ld/esp32_c6/esp32c6.rom.libc.ld"),
                    b.path("ld/esp32_c6/esp32c6.rom.libc-suboptimal_for_misaligned_mem.ld"),
                    b.path("ld/esp32_c6/radio_rom_functions.ld"),
                },
            ),
        },
    };

    return .{
        .chips = .{
            .esp32_c3 = chip_esp32_c3.derive(.{}),
            .esp32_c3_direct_boot = chip_esp32_c3.derive(.{
                .preferred_binary_format = .binary,
                .cpu = .{
                    .name = "esp_riscv",
                    .root_source_file = b.path("src/cpus/esp_riscv.zig"),
                    .imports = b.allocator.dupe(Import, &.{
                        .{
                            .name = "cpu-config",
                            .module = get_cpu_config(b, .esp32_c3, .direct),
                        },
                        .{
                            .name = "riscv32-common",
                            .module = riscv32_common_mod,
                        },
                        .{ .name = "interrupt-encoding", .module = interrupt_encoding },
                    }) catch @panic("OOM"),
                },
                .linker_script = .{
                    .generate = .memory_regions,
                    .file = generate_linker_script(
                        dep,
                        "final.ld",
                        &.{
                            b.path("ld/esp32_c3/direct_boot_sections.ld"),
                            b.path("ld/esp32_c3/common_sections.ld"),
                            b.path("ld/esp32_c3/rom_functions.ld"),
                        },
                    ),
                },
            }),
            .esp32_c3_flashless = chip_esp32_c3.derive(.{
                .ram_image = true,
                .linker_script = .{
                    .generate = .memory_regions,
                    .file = generate_linker_script(
                        dep,
                        "final.ld",
                        &.{
                            b.path("ld/esp32_c3/flashless_sections.ld"),
                            b.path("ld/esp32_c3/common_sections.ld"),
                            b.path("ld/esp32_c3/rom_functions.ld"),
                        },
                    ),
                },
            }),
            // TRM v1.2 §§3.3, 3.7.1: LP reset PC is SRAM + 0x80.
            .esp32_c6_lp = chip_esp32_c6.derive(.{
                .preferred_binary_format = .binary,
                .ram_image = true,
                .cpu = .{
                    .name = "esp_lp_riscv",
                    .root_source_file = b.path("src/cpus/esp_lp_riscv.zig"),
                },
                .hal = .{ .root_source_file = b.path("src/hal_lp.zig") },
                .chip = .{
                    .name = "ESP32-C6",
                    .register_definition = chip_esp32_c6.chip.register_definition,
                    .patch_files = chip_esp32_c6.chip.patch_files,
                    .memory_regions = &.{.{ .name = "LP_RAM", .tag = .ram, .offset = 0x5000_0000, .length = 16 * 1024, .access = .rwx }},
                },
                .linker_script = .{ .generate = .none, .file = b.path("ld/esp32_c6/lp_sections.ld") },
            }),
            .esp32_c6 = chip_esp32_c6.derive(.{}),
            .esp32_c6_direct_boot = chip_esp32_c6.derive(.{
                .preferred_binary_format = .binary,
                .cpu = .{
                    .name = "esp_riscv",
                    .root_source_file = b.path("src/cpus/esp_riscv.zig"),
                    .imports = b.allocator.dupe(Import, &.{
                        .{
                            .name = "cpu-config",
                            .module = get_cpu_config(b, .esp32_c6, .direct),
                        },
                        .{
                            .name = "riscv32-common",
                            .module = riscv32_common_mod,
                        },
                        .{ .name = "interrupt-encoding", .module = interrupt_encoding },
                    }) catch @panic("OOM"),
                },
                .linker_script = .{
                    .generate = .memory_regions,
                    .file = generate_linker_script(
                        dep,
                        "final.ld",
                        &.{
                            b.path("ld/esp32_c6/direct_boot_sections.ld"),
                            b.path("ld/esp32_c6/rom_functions.ld"),
                            b.path("ld/esp32_c6/esp32c6.rom.libc.ld"),
                            b.path("ld/esp32_c6/esp32c6.rom.libc-suboptimal_for_misaligned_mem.ld"),
                            b.path("ld/esp32_c6/radio_rom_functions.ld"),
                        },
                    ),
                },
            }),
            .esp32_c6_flashless = chip_esp32_c6.derive(.{
                .ram_image = true,
                .linker_script = .{
                    .generate = .memory_regions,
                    .file = generate_linker_script(
                        dep,
                        "final.ld",
                        &.{
                            b.path("ld/esp32_c6/flashless_sections.ld"),
                            b.path("ld/esp32_c6/rom_functions.ld"),
                            b.path("ld/esp32_c6/esp32c6.rom.libc.ld"),
                            b.path("ld/esp32_c6/esp32c6.rom.libc-suboptimal_for_misaligned_mem.ld"),
                            b.path("ld/esp32_c6/radio_rom_functions.ld"),
                        },
                    ),
                },
            }),
        },
        .boards = .{
            .seeedstudio = .{
                .xiao_esp32_c6 = chip_esp32_c6.derive(.{
                    .board = .{
                        .name = "Seeed Studio XIAO ESP32C6",
                        .url = "https://wiki.seeedstudio.com/xiao_esp32c6_getting_started/",
                        .root_source_file = b.path("src/boards/xiao_esp32_c6.zig"),
                    },
                }),
            },
        },
    };
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const test_step = b.step("test", "Run platform agnostic unit tests");
    if (b.lazyDependency("esp-wifi-sys", .{})) |sys| {
        const headers = wifi_headers(b, sys, "esp32c6", target);
        const HostRadios = enum { coex, wifi_disabled, wifi_only, ble_only };
        for ([_]HostRadios{ .coex, .wifi_disabled, .wifi_only, .ble_only }) |radios| {
            const host_microzig = b.createModule(.{
                .root_source_file = b.path(if (radios == .ble_only)
                    "src/hal/radio/test_ble_host.zig"
                else
                    "src/hal/usb_serial_jtag/test_microzig.zig"),
            });
            if (radios != .ble_only) {
                const options = b.addOptions();
                options.addOption(bool, "wifi", radios != .wifi_disabled);
                options.addOption(bool, "coex", radios != .wifi_only);
                host_microzig.addOptions("test-radio-options", options);
                host_microzig.addImport("core-allocator", b.createModule(.{ .root_source_file = b.path("../../../core/src/allocator.zig") }));
            }
            host_microzig.addImport("drivers", b.createModule(.{ .root_source_file = b.path("../../../drivers/src/root.zig") }));
            const unit_tests = b.addTest(.{
                .name = b.fmt("hal-host-{s}", .{@tagName(radios)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/hal.zig"),
                    .target = target,
                    .optimize = optimize,
                }),
                .filters = switch (radios) {
                    .coex => &.{},
                    .wifi_disabled => &.{"public Wi-Fi init validates options before acquiring a session"},
                    .wifi_only => &.{"hal.radio.wifi.test."},
                    .ble_only => &.{"BLE-only task ABI removes a timed waiter and reclaims the task"},
                },
            });
            host_microzig.addImport("hal-under-test", unit_tests.root_module);
            unit_tests.root_module.addImport("microzig", host_microzig);
            unit_tests.root_module.addImport("esp-wifi-driver", headers);
            unit_tests.root_module.addImport("interrupt-encoding", b.createModule(.{
                .root_source_file = b.path("src/hal/interrupt_encoding.zig"),
            }));
            test_step.dependOn(&b.addRunArtifact(unit_tests).step);
            if (radios != .coex) continue;

            // The public Wi-Fi stop panics, one process each.
            const stop_panic_tests = b.addTest(.{
                .name = "wifi-stop-panics",
                .root_module = unit_tests.root_module,
                .test_runner = .{ .path = b.path("src/hal/radio/stop_panic_runner.zig"), .mode = .simple },
            });
            for ([_][2][]const u8{
                .{ "rejects the interface stop", "Wi-Fi stop: the PP queue rejected the interface stop (ESP_ERR_WIFI_POST)" },
                .{ "rejects the hardware stop", "Wi-Fi stop: the PP queue rejected the hardware stop (ESP_ERR_WIFI_POST)" },
                .{ "rejects both stops", "Wi-Fi stop: the PP queue rejected the interface stop and the hardware stop (ESP_ERR_WIFI_POST)" },
                .{ "fails after the interfaces stopped", "Wi-Fi stop failed after the interfaces stopped" },
            }) |case| {
                const run = b.addRunArtifact(stop_panic_tests);
                run.addArgs(&case);
                test_step.dependOn(&run.step);
            }
        }
    }
    // Compile the actual C6 ABI layout on RV32 even on a 64-bit test host.
    const coex_layout = b.addObject(.{ .name = "coex-layout", .root_module = b.createModule(.{
        .root_source_file = b.path("src/hal/radio/coex_abi.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .riscv32, .os_tag = .freestanding }),
    }) });
    test_step.dependOn(&coex_layout.step);

    // Exercise the registered callbacks with debug logging enabled and check
    // the task-only panics in separate processes.
    const callback_probe = b.addExecutable(.{
        .name = "coex-callback-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/coex_callback_test.zig"),
            .target = b.graph.host,
        }),
    });
    const callback_host = b.createModule(.{ .root_source_file = b.path("src/hal/radio/test_coex_host.zig") });
    callback_probe.root_module.addImport("microzig", callback_host);
    callback_probe.root_module.addImport("esp-wifi-driver", callback_host);
    for ([_][]const u8{ "callbacks", "take", "give", "timer_disarm", "timer_done", "timer_setfn", "timer_arm_us" }) |mode| {
        const run = b.addRunArtifact(callback_probe);
        run.addArg(mode);
        test_step.dependOn(&run.step);
    }

    const selections = b.addWriteFiles();
    const radios = b.createModule(.{ .root_source_file = b.path("src/hal/radio/radios.zig") });
    for ([_][]const u8{
        ".{ .wifi = false }",
        ".{ .ieee802154 = true }",
        ".{ .wifi = false, .ble = true, .ieee802154 = true }",
        ".{ .ble = true, .ieee802154 = true }",
    }, [_][]const u8{
        "hal.radio.radios requires one selected radio",
        "hal.radio.radios: wifi + ieee802154 together is not supported; the only supported multi-radio selection is wifi + ble",
        "hal.radio.radios: ble + ieee802154 together is not supported; the only supported multi-radio selection is wifi + ble",
        "hal.radio.radios: wifi + ble + ieee802154 together is not supported; the only supported multi-radio selection is wifi + ble",
    }, 0..) |selection, expected, index| {
        const invalid = b.addObject(.{
            .name = "invalid-radio-selection",
            .root_module = b.createModule(.{
                .root_source_file = selections.add(b.fmt("selection-{d}.zig", .{index}), b.fmt(
                    "comptime {{ @import(\"radios\").Radios.validate({s}); }}",
                    .{selection},
                )),
                .target = b.graph.host,
            }),
        });
        invalid.root_module.addImport("radios", radios);
        invalid.expect_errors = .{ .contains = expected };
        test_step.dependOn(&invalid.step);
    }

    const nvs_crash_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/nvs_crash_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const nvs_crash_options = b.addOptions();
    nvs_crash_options.addOption([]const u8, "dump_path", b.option(
        []const u8,
        "nvs-crash-dump",
        "Absolute path: write every NVS crash image there for src/hal/nvs_testdata/crosscheck_idf.py",
    ) orelse "");
    nvs_crash_tests.root_module.addOptions("nvs_crash_options", nvs_crash_options);
    test_step.dependOn(&b.addRunArtifact(nvs_crash_tests).step);
    // ESP-IDF's init against this store's on random foreign partitions, for
    // src/hal/nvs_testdata/init_diff_idf.py; not part of `test`.
    const nvs_init_diff = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/nvs_init_diff.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const nvs_init_diff_options = b.addOptions();
    nvs_init_diff_options.addOption([]const u8, "dir", b.option(
        []const u8,
        "nvs-init-diff",
        "Absolute path: the directory src/hal/nvs_testdata/init_diff_idf.py runs in",
    ) orelse "");
    nvs_init_diff.root_module.addOptions("nvs_init_diff_options", nvs_init_diff_options);
    b.step("nvs-init-diff", "Run this NVS store's init for src/hal/nvs_testdata/init_diff_idf.py").dependOn(&b.addRunArtifact(nvs_init_diff).step);
    const nvs_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/nvs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(nvs_tests).step);
    const nvs_format_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/nvs_format.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(nvs_format_tests).step);
    const partition_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/partition_table.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(partition_tests).step);

    const espnow_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/radio/espnow_session.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(espnow_tests).step);

    const wifi_status_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/radio/wifi_status.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(wifi_status_tests).step);

    const ble_host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/radio/ble/host.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ble_host_tests).step);
    const ble_bond_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/radio/ble/smp_bond_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ble_bond_tests.root_module.addImport("nvs", b.createModule(.{
        .root_source_file = b.path("src/hal/nvs.zig"),
        .target = target,
        .optimize = optimize,
    }));
    test_step.dependOn(&b.addRunArtifact(ble_bond_tests).step);

    // Tests in a separate imported module need their own test artifact.
    const interrupt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/interrupt_encoding.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(interrupt_tests).step);

    const cpu_without_hal = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/cpu_without_hal_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const cpu_module = b.createModule(.{
        .root_source_file = b.path("src/cpus/esp_riscv.zig"),
    });
    cpu_module.addImport("microzig", cpu_without_hal.root_module);
    cpu_module.addImport("interrupt-encoding", b.createModule(.{
        .root_source_file = b.path("src/hal/interrupt_encoding.zig"),
    }));
    cpu_without_hal.root_module.addImport("esp-cpu", cpu_module);
    test_step.dependOn(&b.addRunArtifact(cpu_without_hal).step);

    // The C6 CLINT/peripheral interrupt split is pure data and testable on the host.
    const c6_interrupt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cpus/esp_riscv/esp32_c6.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(c6_interrupt_tests).step);

    const gdma_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal/gdma.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(gdma_tests).step);

    const cat_exe = b.addExecutable(.{
        .name = "cat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/cat.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(cat_exe);
}

const Chip = enum {
    esp32_c3,
    esp32_c6,
};

const BootMode = enum {
    direct,
    image,
};

fn get_cpu_config(b: *std.Build, chip: Chip, boot_mode: BootMode) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(Chip, "chip", chip);
    options.addOption(BootMode, "boot_mode", boot_mode);
    return b.createModule(.{
        .root_source_file = options.getOutput(),
    });
}

fn generate_linker_script(
    dep: *std.Build.Dependency,
    output_name: []const u8,
    input_paths: []const std.Build.LazyPath,
) std.Build.LazyPath {
    const b = dep.builder;
    const cat_exe = dep.artifact("cat");

    const run = b.addRunArtifact(cat_exe);
    for (input_paths) |path| {
        run.addFileArg(path);
    }
    return run.addOutputFileArg(output_name);
}

fn wifi_headers(b: *std.Build, esp_wifi_sys_dep: *std.Build.Dependency, chip_name: []const u8, radio_resolved_zig_target: std.Build.ResolvedTarget) *std.Build.Module {
    const translate_c = b.addTranslateC(.{
        .root_source_file = esp_wifi_sys_dep.path("c/include/include.h"),
        .target = radio_resolved_zig_target,
        .optimize = .Debug,
        .link_libc = false,
    });

    translate_c.addIncludePath(b.path("src/hal/radio/libc_dummy_include"));
    translate_c.addIncludePath(esp_wifi_sys_dep.path("c/headers"));
    translate_c.addIncludePath(esp_wifi_sys_dep.path("c/include"));
    translate_c.addIncludePath(esp_wifi_sys_dep.path(b.fmt("c/include/{s}", .{chip_name})));
    translate_c.addIncludePath(esp_wifi_sys_dep.path(b.fmt("c/headers/{s}", .{chip_name})));

    // A private module: the package can only register one module per name and there is one
    // of these per supported chip.
    return translate_c.createModule();
}

fn make_esp_wifi_driver_module(
    b: *std.Build,
    esp_wifi_sys_dep: *std.Build.Dependency,
    chip_name: []const u8,
    target_query: std.Target.Query,
) *std.Build.Module {
    const radio_resolved_zig_target = b.resolveTargetQuery(target_query);
    const mod = wifi_headers(b, esp_wifi_sys_dep, chip_name, radio_resolved_zig_target);
    mod.addLibraryPath(esp_wifi_sys_dep.path(b.fmt("esp-wifi-sys-{s}/libs", .{chip_name})));

    mod.linkSystemLibrary(if (std.mem.eql(u8, chip_name, "esp32c6")) "ble_app" else "btdm_app", .{});

    inline for (&.{
        "btbb",
        "coexist",
        "core",
        "espnow",
        "mesh",
        "net80211",
        "phy",
        "pp",
        "regulatory",
        "smartconfig",
        "wapi",
        "wpa_supplicant",
    }) |library| {
        mod.linkSystemLibrary(library, .{});
    }

    mod.linkSystemLibrary("printf", .{
        .weak = true,
    });

    return mod;
}
