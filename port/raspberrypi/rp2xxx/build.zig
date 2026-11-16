const std = @import("std");
const microzig = @import("microzig/build-internals");

const Self = @This();

chips: struct {
    rp2040: *const microzig.Target,
    rp2350_arm: *const microzig.Target,
    rp2350_riscv: *const microzig.Target,
},

boards: struct {
    adafruit: struct {
        feather_rp2350: *const microzig.Target,
        metro_rp2350: *const microzig.Target,
    },
    raspberrypi: struct {
        pico: *const microzig.Target,
        pico_flashless: *const microzig.Target,
        pico2_arm: *const microzig.Target,
        pico2_arm_flashless: *const microzig.Target,
        pico2_riscv: *const microzig.Target,
        pico2_riscv_flashless: *const microzig.Target,
    },
    waveshare: struct {
        rp2040_plus_4m: *const microzig.Target,
        rp2040_plus_16m: *const microzig.Target,
        rp2040_eth: *const microzig.Target,
        rp2040_matrix: *const microzig.Target,
    },
},

pub fn init(dep: *std.Build.Dependency) ?Self {
    const b = dep.builder;

    const riscv32_common_dep = b.dependency("microzig/modules/riscv32-common", .{});
    const pico_sdk = b.dependencyLazy("pico-sdk", .{}) catch return null;
    const bounded_array_dep = b.dependency("bounded-array", .{});

    const hal: microzig.HardwareAbstractionLayer = .{
        .root_source_file = b.path("src/hal.zig"),
        .imports = b.allocator.dupe(std.Build.Module.Import, &.{.{
            .name = "bounded-array",
            .module = bounded_array_dep.module("bounded-array"),
        }}) catch @panic("OOM"),
    };

    const chip_rp2040: microzig.Target = .{
        .dep = dep,
        .preferred_binary_format = .{ .uf2 = .{
            .family_id = .RP2040,
        } },
        .zig_target = .{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m0plus },
            .os_tag = .freestanding,
            .abi = .eabi,
        },
        .chip = .{
            .name = "RP2040",
            .register_definition = .{ .svd = pico_sdk.path("src/rp2040/hardware_regs/RP2040.svd") },
            .memory_regions = &.{
                .{ .tag = .flash, .offset = 0x10000000, .length = 2 * 1024 * 1024, .access = .rx },
                .{ .tag = .ram, .offset = 0x20000000, .length = 256 * 1024, .access = .rwx },
            },
            .patch_files = &.{b.path("patches/rp2040.zon")},
        },
        .hal = hal,
        .linker_script = .{
            .file = b.path("ld/rp2040/sections.ld"),
        },
    };

    const chip_rp2350_arm: microzig.Target = .{
        .dep = dep,
        .preferred_binary_format = .{ .uf2 = .{
            .family_id = .RP2350_ARM_S,
        } },
        .zig_target = .{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },
            .os_tag = .freestanding,
            .abi = .eabihf,
            .cpu_features_add = std.Target.arm.featureSet(&.{ .fp_armv8d16sp, .dsp }),
        },
        .chip = .{
            .name = "RP2350",
            .register_definition = .{ .svd = pico_sdk.path("src/rp2350/hardware_regs/RP2350.svd") },
            .memory_regions = &.{
                .{ .tag = .flash, .offset = 0x10000000, .length = 4 * 1024 * 1024, .access = .rx },
                .{ .tag = .ram, .offset = 0x20000000, .length = 512 * 1024, .access = .rwx },
                // TODO: maybe these can be used for stacks
                .{ .tag = .ram, .offset = 0x20080000, .length = 4 * 1024, .access = .rwx },
                .{ .tag = .ram, .offset = 0x20081000, .length = 4 * 1024, .access = .rwx },
            },
            .patch_files = &.{b.path("patches/rp2350.zon")},
        },
        .hal = hal,
        .linker_script = .{
            .file = b.path("ld/rp2350/arm_sections.ld"),
        },
    };

    const chip_rp2350_riscv: microzig.Target = .{
        .dep = dep,
        .preferred_binary_format = .{ .uf2 = .{
            .family_id = .RP2350_RISCV,
        } },
        .zig_target = .{
            .cpu_arch = .riscv32,
            .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
            .cpu_features_add = std.Target.riscv.featureSet(&.{
                .a,
                .m,
                .c,
                .zba,
                .zbb,
                .zbs,
                .zcb,
                .zcmp,
                .zbkb,
                .zicsr,
                .zifencei,
            }),
            .os_tag = .freestanding,
            .abi = .eabi,
        },
        .cpu = .{
            .name = "hazard3",
            .root_source_file = b.path("src/cpus/hazard3.zig"),
            .imports = b.allocator.dupe(std.Build.Module.Import, &.{
                .{
                    .name = "riscv32-common",
                    .module = riscv32_common_dep.module("riscv32-common"),
                },
            }) catch @panic("OOM"),
        },
        .chip = .{
            .name = "RP2350",
            .register_definition = .{ .svd = pico_sdk.path("src/rp2350/hardware_regs/RP2350.svd") },
            .memory_regions = &.{
                .{ .tag = .flash, .offset = 0x10000000, .length = 4 * 1024 * 1024, .access = .rx },
                .{ .tag = .ram, .offset = 0x20000000, .length = 512 * 1024, .access = .rwx },
                // TODO: maybe these can be used for stacks
                .{ .tag = .ram, .offset = 0x20080000, .length = 4 * 1024, .access = .rwx },
                .{ .tag = .ram, .offset = 0x20081000, .length = 4 * 1024, .access = .rwx },
            },
            .patch_files = &.{
                b.path("patches/rp2350.zon"),
                b.path("patches/rp2350_hazard3.zon"),
            },
        },
        .hal = hal,
        .linker_script = .{
            .file = b.path("ld/rp2350/riscv_sections.ld"),
        },
    };

    const bootrom_rp2040 = get_bootrom(b, &chip_rp2040, .w25q080);
    const rp2040_bootrom_imports = b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "bootloader", .module = b.createModule(.{ .root_source_file = bootrom_rp2040 }) },
    }) catch @panic("out of memory");

    return .{
        .chips = .{
            .rp2040 = chip_rp2040.derive(.{}),
            .rp2350_arm = chip_rp2350_arm.derive(.{}),
            .rp2350_riscv = chip_rp2350_riscv.derive(.{}),
        },
        .boards = .{
            .adafruit = .{
                .feather_rp2350 = chip_rp2350_arm.derive(.{
                    .chip = .{
                        .name = "RP2350",
                        .register_definition = .{ .svd = pico_sdk.path("src/rp2350/hardware_regs/RP2350.svd") },
                        .memory_regions = &.{
                            .{ .tag = .flash, .offset = 0x10000000, .length = 8 * 1024 * 1024, .access = .rx },
                            .{ .tag = .ram, .offset = 0x20000000, .length = 512 * 1024, .access = .rwx },
                            .{ .tag = .ram, .offset = 0x20080000, .length = 4 * 1024, .access = .rwx },
                            .{ .tag = .ram, .offset = 0x20081000, .length = 4 * 1024, .access = .rwx },
                        },
                        .patch_files = &.{b.path("patches/rp2350.zon")},
                    },
                    .board = .{
                        .name = "Adafruit Feather RP2350",
                        .url = "https://www.adafruit.com/product/6000",
                        .root_source_file = b.path("src/boards/adafruit_feather_rp2350.zig"),
                    },
                }),
                .metro_rp2350 = chip_rp2350_arm.derive(.{
                    .chip = .{
                        .name = "RP2350",
                        .register_definition = .{ .svd = pico_sdk.path("src/rp2350/hardware_regs/RP2350.svd") },
                        .memory_regions = &.{
                            .{ .tag = .flash, .offset = 0x10000000, .length = 16 * 1024 * 1024, .access = .rx },
                            .{ .tag = .ram, .offset = 0x20000000, .length = 512 * 1024, .access = .rwx },
                            .{ .tag = .ram, .offset = 0x20080000, .length = 4 * 1024, .access = .rwx },
                            .{ .tag = .ram, .offset = 0x20081000, .length = 4 * 1024, .access = .rwx },
                        },
                        .patch_files = &.{b.path("patches/rp2350.zon")},
                    },
                    .board = .{
                        .name = "Adafruit Metro RP2350",
                        .url = "https://www.adafruit.com/product/6267",
                        .root_source_file = b.path("src/boards/adafruit_metro_rp2350.zig"),
                    },
                }),
            },
            .raspberrypi = .{
                .pico = chip_rp2040.derive(.{
                    .board = .{
                        .name = "RaspberryPi Pico",
                        .url = "https://www.raspberrypi.com/products/raspberry-pi-pico/",
                        .root_source_file = b.path("src/boards/raspberry_pi_pico.zig"),
                        .imports = rp2040_bootrom_imports,
                    },
                }),
                .pico_flashless = chip_rp2040.derive(.{
                    .ram_image = true,
                    // we can use the default generated linker script
                    .linker_script = .{},
                    .entry = .{ .symbol_name = "_entry_point" },
                    .board = .{
                        .name = "RaspberryPi Pico (ram image)",
                        .url = "https://www.raspberrypi.com/products/raspberry-pi-pico/",
                        .root_source_file = b.path("src/boards/raspberry_pi_pico.zig"),
                    },
                }),
                .pico2_arm = chip_rp2350_arm.derive(.{
                    .board = .{
                        .name = "RaspberryPi Pico 2",
                        .url = "https://www.raspberrypi.com/products/raspberry-pi-pico2/",
                        .root_source_file = b.path("src/boards/raspberry_pi_pico2.zig"),
                    },
                }),
                .pico2_arm_flashless = chip_rp2350_arm.derive(.{
                    .ram_image = true,
                    .linker_script = .{
                        .file = b.path("ld/rp2350/arm_ram_image_sections.ld"),
                    },
                    .entry = .{ .symbol_name = "_entry_point" },
                    .board = .{
                        .name = "RaspberryPi Pico 2 (ram image)",
                        .url = "https://www.raspberrypi.com/products/raspberry-pi-pico2/",
                        .root_source_file = b.path("src/boards/raspberry_pi_pico2.zig"),
                    },
                }),
                .pico2_riscv = chip_rp2350_riscv.derive(.{
                    .board = .{
                        .name = "RaspberryPi Pico 2",
                        .url = "https://www.raspberrypi.com/products/raspberry-pi-pico2/",
                        .root_source_file = b.path("src/boards/raspberry_pi_pico2.zig"),
                    },
                }),
                .pico2_riscv_flashless = chip_rp2350_riscv.derive(.{
                    .ram_image = true,
                    .linker_script = .{
                        .file = b.path("ld/rp2350/riscv_ram_image_sections.ld"),
                    },
                    .board = .{
                        .name = "RaspberryPi Pico 2 (ram image)",
                        .url = "https://www.raspberrypi.com/products/raspberry-pi-pico2/",
                        .root_source_file = b.path("src/boards/raspberry_pi_pico2.zig"),
                    },
                }),
            },
            .waveshare = .{
                .rp2040_plus_4m = chip_rp2040.derive(.{
                    .board = .{
                        .name = "Waveshare RP2040-Plus (4M Flash)",
                        .url = "https://www.waveshare.com/rp2040-plus.htm",
                        .root_source_file = b.path("src/boards/waveshare_rp2040_plus_4m.zig"),
                        .imports = rp2040_bootrom_imports,
                    },
                }),
                .rp2040_plus_16m = chip_rp2040.derive(.{
                    .board = .{
                        .name = "Waveshare RP2040-Plus (16M Flash)",
                        .url = "https://www.waveshare.com/rp2040-plus.htm",
                        .root_source_file = b.path("src/boards/waveshare_rp2040_plus_16m.zig"),
                        .imports = rp2040_bootrom_imports,
                    },
                }),
                .rp2040_eth = chip_rp2040.derive(.{
                    .board = .{
                        .name = "Waveshare RP2040-ETH Mini",
                        .url = "https://www.waveshare.com/rp2040-eth.htm",
                        .root_source_file = b.path("src/boards/waveshare_rp2040_eth.zig"),
                        .imports = rp2040_bootrom_imports,
                    },
                }),
                .rp2040_matrix = chip_rp2040.derive(.{
                    .board = .{
                        .name = "Waveshare RP2040-Matrix",
                        .url = "https://www.waveshare.com/rp2040-matrix.htm",
                        .root_source_file = b.path("src/boards/waveshare_rp2040_matrix.zig"),
                        .imports = rp2040_bootrom_imports,
                    },
                }),
            },
        },
    };
}

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const bounded_array_dep = b.dependency("bounded-array", .{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = try comparison_header(b),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    translate_c.defineCMacro("PICO_NO_HARDWARE", "1");
    translate_c.addIncludePath(b.path("src/hal/pio/assembler"));

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bounded-array", .module = bounded_array_dep.module("bounded-array") },
                .{ .name = "c", .module = translate_c.createModule() },
            },
        }),
    });
    unit_tests.root_module.addIncludePath(b.path("src/hal/pio/assembler"));

    const unit_tests_run = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run platform agnostic unit tests");
    test_step.dependOn(&unit_tests_run.step);

    // The PIO self-test runner's own unit tests need a Python 3 on PATH as
    // `python3`, so they are a separate step rather than part of `test`.
    const hwtest_tests = b.addSystemCommand(&.{ "python3", "-m", "unittest", "discover", "-q", "-s" });
    hwtest_tests.addDirectoryArg(b.path("tools/pio-hwtest"));
    const hwtest_step = b.step("test-hwtest-runner", "Run the PIO self-test runner's unit tests (needs python3)");
    hwtest_step.dependOn(&hwtest_tests.step);
}

const BootROM = union(enum) {
    at25sf128a,
    generic_03h,
    is25lp080,
    w25q080,
    w25x10cl,

    // Use the old stage2 bootloader vendored with MicroZig till 2023-09-13
    legacy,
};

fn get_bootrom(b: *std.Build, target: *const microzig.Target, rom: BootROM) std.Build.LazyPath {
    var zig_target = target.zig_target;
    zig_target.abi = .eabi;

    const rom_exe = b.addExecutable(.{
        .name = b.fmt("stage2-{t}", .{rom}),
        .root_module = b.createModule(.{
            .optimize = .small,
            .target = b.resolveTargetQuery(zig_target),
        }),
    });

    //rom_exe.linkage = .static;
    rom_exe.build_id = .none;
    rom_exe.setLinkerScript(b.path(b.fmt("src/bootroms/{s}/shared/stage2.ld", .{target.chip.name})));
    rom_exe.root_module.addAssemblyFile(b.path(b.fmt("src/bootroms/{s}/{s}.S", .{ target.chip.name, @tagName(rom) })));
    rom_exe.entry = .{ .symbol_name = "_stage2_boot" };

    const rom_objcopy = b.addObjCopy(rom_exe.getEmittedBin(), .{
        .basename = b.fmt("{s}.bin", .{@tagName(rom)}),
        .format = .binary,
    });

    return rom_objcopy.getOutput();
}

// Translate the generated data and default configurations without the SDK's
// MMIO implementation or the examples' hardware helper functions.
fn comparison_header(b: *std.Build) !std.Build.LazyPath {
    const directory = "src/hal/pio/assembler/";
    b.dependOnFileContents(b.path(directory ++ "comparison_tests.h"));
    const includes = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, try b.root.joinString(b.allocator, directory ++ "comparison_tests.h"), b.allocator, .limited(1024 * 1024));
    var header: std.Io.Writer.Allocating = .init(b.allocator);
    try header.writer.writeAll(
        \\#include <stdbool.h>
        \\#include "comparison_tests.h"
        \\typedef unsigned int uint;
        \\struct pio_program { const uint16_t *instructions; uint length; int origin; uint pio_version; uint used_gpio_ranges; };
        \\typedef struct { uint side_count; bool side_optional; bool side_pindirs; uint in_count, out_count, set_count, in_threshold, out_threshold; bool in_right, out_right, autopush, autopull; uint fifo, status_sel, status_n, div_int, div_frac; } pio_sm_config;
        \\static inline pio_sm_config pio_get_default_sm_config(void) { return (pio_sm_config){0}; }
        \\static inline void sm_config_set_wrap(pio_sm_config *c, uint target, uint wrap) { (void)c; (void)target; (void)wrap; }
        \\static inline void sm_config_set_sideset(pio_sm_config *c, uint n, bool opt, bool dirs) { c->side_count = n; c->side_optional = opt; c->side_pindirs = dirs; }
        \\#define PICO_PIO_VERSION 1
        \\enum { PIO_FIFO_JOIN_NONE, PIO_FIFO_JOIN_TX, PIO_FIFO_JOIN_RX, PIO_FIFO_JOIN_TXPUT, PIO_FIFO_JOIN_TXGET, PIO_FIFO_JOIN_PUTGET };
        \\enum { STATUS_TX_LESSTHAN, STATUS_RX_LESSTHAN, STATUS_IRQ_INDEX };
        \\static inline void sm_config_set_in_pin_count(pio_sm_config *c, uint n) { c->in_count = n; }
        \\static inline void sm_config_set_out_pin_count(pio_sm_config *c, uint n) { c->out_count = n; }
        \\static inline void sm_config_set_set_pin_count(pio_sm_config *c, uint n) { c->set_count = n; }
        \\static inline void sm_config_set_in_shift(pio_sm_config *c, bool right, bool auto_, uint n) { c->in_right = right; c->autopush = auto_; c->in_threshold = n; }
        \\static inline void sm_config_set_out_shift(pio_sm_config *c, bool right, bool auto_, uint n) { c->out_right = right; c->autopull = auto_; c->out_threshold = n; }
        \\static inline void sm_config_set_fifo_join(pio_sm_config *c, uint n) { c->fifo = n; }
        \\static inline void sm_config_set_mov_status(pio_sm_config *c, uint sel, uint n) { c->status_sel = sel; c->status_n = n; }
        \\static inline void sm_config_set_clkdiv_int_frac(pio_sm_config *c, uint i, uint f) { c->div_int = i; c->div_frac = f; }
        \\
    );
    var lines = std.mem.splitScalar(u8, includes, '\n');
    // Trim '\r' so a CRLF checkout (Windows, core.autocrlf) reads the same
    // as an LF one.
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (!std.mem.startsWith(u8, line, "#include \"comparison_tests/")) continue;
        const file = line[10 .. line.len - 1];
        b.dependOnFileContents(b.path(b.fmt("{s}{s}", .{ directory, file })));
        const contents = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, try b.root.joinString(b.allocator, b.fmt("{s}{s}", .{ directory, file })), b.allocator, .limited(1024 * 1024));
        var source_lines = std.mem.splitScalar(u8, contents, '\n');
        var copying = false;
        while (source_lines.next()) |raw_source_line| {
            const source_line = std.mem.trimEnd(u8, raw_source_line, "\r");
            if (std.mem.startsWith(u8, source_line, "static const struct pio_program ") or
                std.mem.startsWith(u8, source_line, "static inline pio_sm_config ")) copying = true;
            if (copying) {
                try header.writer.print("{s}\n", .{source_line});
                if (std.mem.eql(u8, source_line, "};") or std.mem.eql(u8, source_line, "}")) copying = false;
            }
        }
    }
    return b.addWriteFiles().add("pio_comparison_metadata.h", header.written());
}
