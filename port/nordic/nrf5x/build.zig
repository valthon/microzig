const std = @import("std");
const microzig = @import("microzig/build-internals");

const Self = @This();

chips: struct {
    nrf51822: *const microzig.Target,
    nrf52832: *const microzig.Target,
    nrf52833: *const microzig.Target,
    nrf52840: *const microzig.Target,
},

boards: struct {
    nordic: struct {
        nrf52840_dongle: *const microzig.Target,
        nrf52840_mdk: *const microzig.Target,
        pca10040: *const microzig.Target,
    },
    bbc: struct {
        microbit_v1: *const microzig.Target,
        microbit_v2: *const microzig.Target,
    },
    nicekeyboards: struct {
        nice_nano: *const microzig.Target,
    },
    seeed: struct {
        xiao_nrf52840_sense: *const microzig.Target,
    },
},

pub fn init(dep: *std.Build.Dependency) ?Self {
    const b = dep.builder;

    const nrfx = b.dependencyLazy("nrfx", .{}) catch return null;

    const hal: microzig.HardwareAbstractionLayer = .{
        .root_source_file = b.path("src/hal.zig"),
    };

    const chip_nrf51822: microzig.Target = .{
        .dep = dep,
        .preferred_binary_format = .elf,
        .zig_target = .{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m0 },
            .os_tag = .freestanding,
            .abi = .eabi,
        },
        .chip = .{
            .name = "nrf51",
            .url = "https://www.nordicsemi.com/products/nrf51822",
            .register_definition = .{
                .svd = nrfx.path("mdk/nrf51.svd"),
            },
            .memory_regions = &.{
                .{ .tag = .flash, .offset = 0x00000000, .length = 128 * 1024, .access = .rx },
                .{ .tag = .ram, .offset = 0x20000000, .length = 16 * 1024, .access = .rwx },
            },
            .patch_files = &.{
                b.path("patches/nrf51.zon"),
            },
        },
        .hal = hal,
    };

    const chip_nrf52832: microzig.Target = .{
        .dep = dep,
        .preferred_binary_format = .elf,
        .zig_target = .{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m4 },
            .os_tag = .freestanding,
            .abi = .eabi,
        },
        .chip = .{
            .name = "nrf52",
            .url = "https://www.nordicsemi.com/products/nrf52832",
            .register_definition = .{
                .svd = nrfx.path("mdk/nrf52.svd"),
            },
            .memory_regions = &.{
                .{ .tag = .flash, .offset = 0x00000000, .length = 0x80000, .access = .rx },
                .{ .tag = .ram, .offset = 0x20000000, .length = 0x10000, .access = .rwx },
            },
            .patch_files = &.{
                b.path("patches/nrf528xx.zon"),
            },
        },
        .hal = hal,
    };

    const chip_nrf52833: microzig.Target = .{
        .dep = dep,
        .preferred_binary_format = .elf,
        .zig_target = .{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m4 },
            .os_tag = .freestanding,
            .abi = .eabi,
        },
        .chip = .{
            .name = "nrf52833",
            .url = "https://www.nordicsemi.com/products/nrf52833",
            .register_definition = .{
                .svd = nrfx.path("mdk/nrf52833.svd"),
            },
            .memory_regions = &.{
                .{ .tag = .flash, .offset = 0x00000000, .length = 512 * 1024, .access = .rx },
                .{ .tag = .ram, .offset = 0x20000000, .length = 128 * 1024, .access = .rwx },
            },
            .patch_files = &.{
                b.path("patches/nrf528xx.zon"),
            },
        },
        .hal = hal,
    };

    const nrf52840_patches = &.{
        b.path("patches/nrf528xx.zon"),
        b.path("patches/nrf52840.zon"),
    };
    const chip_nrf52840: microzig.Target = .{
        .dep = dep,
        .preferred_binary_format = .elf,
        .zig_target = .{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m4 },
            .os_tag = .freestanding,
            .abi = .eabi,
        },
        .chip = .{
            .name = "nrf52840",
            .url = "https://www.nordicsemi.com/products/nrf52840",
            .register_definition = .{
                .svd = nrfx.path("mdk/nrf52840.svd"),
            },
            .memory_regions = &.{
                .{ .tag = .flash, .offset = 0x00000000, .length = 0x100000, .access = .rx },
                // TODO: use code ram for `.ram_text`
                .{ .tag = .ram, .offset = 0x20000000, .length = 0x40000, .access = .rwx },

                // EXTFLASH
                .{ .tag = .flash, .offset = 0x12000000, .length = 0x8000000, .access = .rx },

                // CODE_RAM
                .{ .name = "code_ram", .offset = 0x800000, .length = 0x40000, .access = .x },
            },
            .patch_files = nrf52840_patches,
        },
        .hal = hal,
    };

    return .{
        .chips = .{
            .nrf51822 = chip_nrf51822.derive(.{}),
            .nrf52832 = chip_nrf52832.derive(.{}),
            .nrf52833 = chip_nrf52833.derive(.{}),
            .nrf52840 = chip_nrf52840.derive(.{}),
        },
        .boards = .{
            .nordic = .{
                .nrf52840_dongle = chip_nrf52840.derive(.{
                    .board = .{
                        .name = "nRF52840 Dongle",
                        .url = "https://www.nordicsemi.com/Products/Development-hardware/nrf52840-dongle",
                        .root_source_file = b.path("src/boards/nrf52840-dongle.zig"),
                    },
                }),
                .nrf52840_mdk = chip_nrf52840.derive(.{
                    .board = .{
                        .name = "nRF52840 MDK USB Dongle",
                        .url = "https://wiki.makerdiary.com/nrf52840-mdk-usb-dongle",
                        .root_source_file = b.path("src/boards/nrf52840-mdk.zig"),
                    },
                }),
                .pca10040 = chip_nrf52832.derive(.{
                    .board = .{
                        .name = "PCA10040",
                        .url = "https://www.nordicsemi.com/Products/Development-hardware/nRF52-DK",
                        .root_source_file = b.path("src/boards/pca10040.zig"),
                    },
                }),
            },
            .bbc = .{
                .microbit_v1 = chip_nrf51822.derive(.{
                    .preferred_binary_format = .hex,
                    .board = .{
                        .name = "micro:bit v1",
                        .url = "https://tech.microbit.org/hardware/1-5-revision",
                        .root_source_file = b.path("src/boards/microbit.zig"),
                    },
                }),
                .microbit_v2 = chip_nrf52833.derive(.{
                    .preferred_binary_format = .hex,
                    .board = .{
                        .name = "micro:bit v2",
                        .url = "https://tech.microbit.org/hardware/2-2-revision",
                        .root_source_file = b.path("src/boards/microbit.zig"),
                    },
                }),
            },
            .nicekeyboards = .{
                .nice_nano = chip_nrf52840.derive(.{
                    .preferred_binary_format = .{ .uf2 = .{ .family_id = .NRF52840 } },
                    .chip = .{
                        .name = "nrf52840",
                        .url = "https://www.nordicsemi.com/products/nrf52840",
                        .register_definition = .{
                            .svd = nrfx.path("mdk/nrf52840.svd"),
                        },
                        .memory_regions = &.{
                            .{ .tag = .flash, .offset = 0x00026000, .length = 0x100000 - 0x26000, .access = .rx },
                            .{ .tag = .ram, .offset = 0x20000008, .length = 0x40000 - 8, .access = .rwx },
                        },
                        .patch_files = nrf52840_patches,
                    },
                    .board = .{
                        .name = "nice!nano",
                        .url = "https://nicekeyboards.com/docs/nice-nano",
                        .root_source_file = b.path("src/boards/nice_nano.zig"),
                    },
                }),
            },
            .seeed = .{
                // Ships with the Adafruit UF2 bootloader and SoftDevice S140 v7, whose
                // applications start at 0x27000 (Adafruit_nRF52_Bootloader README, "S140
                // v6 is 0x26000, v7 is 0x27000"). The image ends where Adafruit's Arduino
                // core ends its own (0xED000, linker/nrf52840_s140_v6.ld), leaving its
                // flash file system and the bootloader at 0xF4000 (linker/nrf52840.ld)
                // alone. The first eight RAM bytes belong to the MBR. Reserve the
                // next eight for the board breadcrumb and keep application RAM
                // eight-byte aligned. The SoftDevice is never enabled.
                .xiao_nrf52840_sense = chip_nrf52840.derive(.{
                    .preferred_binary_format = .{ .uf2 = .{ .family_id = .NRF52840 } },
                    .chip = .{
                        .name = "nrf52840",
                        .url = "https://www.nordicsemi.com/products/nrf52840",
                        .register_definition = .{
                            .svd = nrfx.path("mdk/nrf52840.svd"),
                        },
                        .memory_regions = &.{
                            .{ .tag = .flash, .offset = 0x00027000, .length = 0xED000 - 0x27000, .access = .rx },
                            .{ .tag = .ram, .offset = 0x20000010, .length = 0x40000 - 0x10, .access = .rwx },
                        },
                        .patch_files = nrf52840_patches,
                    },
                    .board = .{
                        .name = "XIAO nRF52840 Sense",
                        .url = "https://wiki.seeedstudio.com/XIAO_BLE",
                        .root_source_file = b.path("src/boards/xiao_nrf52840_sense.zig"),
                    },
                }),
            },
        },
    };
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const usb_core = b.createModule(.{
        .root_source_file = b.path("../../../core/src/microzig.zig"),
        .target = b.graph.host,
    });
    const usb_test_microzig = b.createModule(.{
        .root_source_file = b.path("src/usb_test_microzig.zig"),
        .imports = &.{.{ .name = "usb", .module = usb_core }},
    });
    const nrfx = b.dependencyLazy("nrfx", .{}) catch return;
    const internals = b.dependency("microzig/build-internals", .{});
    const regz = internals.builder.dependency("regz", .{ .optimize = .safe }).artifact("regz");
    const generate = b.addRunArtifact(regz);
    generate.addArgs(&.{ "--format", "svd", "--output_path" });
    const chips = generate.addOutputDirectoryArg2("chips", .{});
    for ([_][]const u8{ "patches/nrf528xx.zon", "patches/nrf52840.zon" }) |patch| {
        generate.addArg("--patch_path");
        generate.addFileArg2(b.path(patch), .{});
    }
    generate.addFileArg2(nrfx.path("mdk/nrf52840.svd"), .{});
    const serial_mmio = b.createModule(.{
        .root_source_file = b.path("src/hal/serial_test_mmio.zig"),
    });
    const serial_chip = b.createModule(.{
        .root_source_file = chips.path(b, "nrf52840.zig"),
        .imports = &.{.{ .name = "microzig", .module = serial_mmio }},
    });
    const serial_drivers = b.createModule(.{
        .root_source_file = b.path("../../../drivers/src/root.zig"),
    });
    const driver_options = b.addOptions();
    driver_options.addOption(bool, "asserts", true);
    serial_drivers.addOptions("config", driver_options);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "microzig", .module = usb_test_microzig },
                .{ .name = "serial_chip", .module = serial_chip },
                .{ .name = "serial_drivers", .module = serial_drivers },
                .{ .name = "serial_core", .module = usb_core },
                .{ .name = "serial_test_mmio", .module = serial_mmio },
            },
        }),
    });

    const unit_tests_run = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run platform agnostic unit tests");
    test_step.dependOn(&unit_tests_run.step);
    add_radio_tests(b, test_step, optimize);
}

fn add_radio_tests(b: *std.Build, test_step: *std.Build.Step, optimize: std.builtin.OptimizeMode) void {
    const nrfx = b.dependencyLazy("nrfx", .{}) catch return;
    const regz = b.dependencyLazy("regz", .{ .optimize = .safe }) catch return;
    const generate = b.addRunArtifact(regz.artifact("regz"));
    generate.addArgs(&.{ "--format", "svd", "--output_path" });
    const chips = generate.addOutputDirectoryArg2("chips", .{});
    for ([_][]const u8{ "patches/nrf528xx.zon", "patches/nrf52840.zon" }) |patch| {
        generate.addArg("--patch_path");
        generate.addFileArg2(b.path(patch), .{});
    }
    generate.addFileArg2(nrfx.path("mdk/nrf52840.svd"), .{});

    const registers = b.createModule(.{
        .root_source_file = chips.path(b, "nrf52840.zig"),
        .target = b.graph.host,
    });
    const radio_interface = b.createModule(.{
        .root_source_file = b.path("../../../drivers/src/base/IEEE802154_Radio.zig"),
        .target = b.graph.host,
    });
    const core = b.createModule(.{
        .root_source_file = b.path("src/radio_test_microzig.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "registers", .module = registers },
            .{ .name = "radio_interface", .module = radio_interface },
        },
    });
    registers.addImport("microzig", core);
    core.addImport("microzig", core);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/hal/radio/ieee802154.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "microzig", .module = core }},
    }) });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
