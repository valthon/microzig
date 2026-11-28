const std = @import("std");
const microzig = @import("microzig/build-internals");
const Chips = @import("src/Chips.zig");

const Self = @This();

chips: Chips,
boards: struct {
    stm32l476discovery: *const microzig.Target,
    stm32f3discovery: *const microzig.Target,
    stm32f4discovery: *const microzig.Target,
    stm3240geval: *const microzig.Target,
    stm32f429idiscovery: *const microzig.Target,
    stm32f303nucleo: *const microzig.Target,
},

pub fn init(dep: *std.Build.Dependency) ?Self {
    const b = dep.builder;

    const clockhelper_dep = b.lazyDependency("ClockHelper", .{}) orelse return null;
    const clockhelper_module = clockhelper_dep.module("clockhelper");
    const hal_imports: []std.Build.Module.Import = b.allocator.dupe(std.Build.Module.Import, &.{
        .{
            .name = "ClockTree",
            .module = clockhelper_module,
        },
    }) catch @panic("out of memory");

    const chips = Chips.init(dep, hal_imports) orelse return null;
    return .{
        .chips = chips,
        .boards = .{
            .stm32f303nucleo = chips.STM32F303RE.derive(.{
                .board = .{
                    .name = "STM32F303NUCLEO",
                    .root_source_file = b.path("src/boards/STM32F303NUCLEO.zig"),
                },
                .hal = microzig.HardwareAbstractionLayer{
                    .root_source_file = b.path("src/hals/STM32F303.zig"),
                    .imports = hal_imports,
                },
                .stack = .{ .ram_region_name = "CCMRAM" },
            }),
            .stm32l476discovery = chips.STM32L476VG.derive(.{
                .board = .{
                    .name = "STM32L476DISCOVERY",
                    .root_source_file = b.path("src/boards/STM32L476DISCOVERY.zig"),
                },
            }),
            .stm32f3discovery = chips.STM32F303VC.derive(.{
                .board = .{
                    .name = "STM32F3DISCOVERY",
                    .root_source_file = b.path("src/boards/STM32F3DISCOVERY.zig"),
                },
                .hal = microzig.HardwareAbstractionLayer{
                    .root_source_file = b.path("src/hals/STM32F303.zig"),
                    .imports = hal_imports,
                },
                .stack = .{ .ram_region_name = "CCMRAM" },
            }),
            .stm32f4discovery = chips.STM32F407VG.derive(.{
                .board = .{
                    .name = "STM32F4DISCOVERY",
                    .root_source_file = b.path("src/boards/STM32F4DISCOVERY.zig"),
                },
            }),
            .stm3240geval = chips.STM32F407VG.derive(.{
                .board = .{
                    .name = "STM3240G_EVAL",
                    .root_source_file = b.path("src/boards/STM3240G_EVAL.zig"),
                },
            }),
            .stm32f429idiscovery = chips.STM32F429ZI.derive(.{
                .board = .{
                    .name = "STM32F429IDISCOVERY",
                    .root_source_file = b.path("src/boards/STM32F429IDISCOVERY.zig"),
                },
                .hal = microzig.HardwareAbstractionLayer{
                    .root_source_file = b.path("src/hals/STM32F429.zig"),
                    .imports = hal_imports,
                },
            }),
        },
    };
}

pub fn build(b: *std.Build) !void {
    const generate = b.option(bool, "generate", "") orelse false;
    if (generate) {
        const stm32_data_generated = try b.dependencyLazy("stm32-data-generated", .{});

        const generate_optimize: std.lang.Optimize = .safe;
        const regz_dep = b.dependency("microzig/tools/regz", .{
            .optimize = generate_optimize,
        });
        const regz = regz_dep.module("regz");

        const generate_exe = b.addExecutable(.{
            .name = "generate",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/generate.zig"),
                .target = b.graph.host,
                .optimize = generate_optimize,
            }),
        });
        generate_exe.root_module.addImport("regz", regz);

        const generate_run = b.addRunArtifact(generate_exe);
        generate_run.addFileArg(stm32_data_generated.path("."));

        b.getInstallStep().dependOn(&generate_run.step);
    }

    const test_step = b.step("test", "Run platform agnostic unit tests");
    try add_usb_tests(b, test_step);
}

fn add_usb_tests(b: *std.Build, test_step: *std.Build.Step) !void {
    const core_source = "../../../core/src/microzig.zig";
    const drivers_source = "../../../drivers/src/root.zig";
    const examples_dir = "../../../examples/stmicro/stm32/src/stm32f1xx/";
    const cdc_source = examples_dir ++ "usb_cdc.zig";
    const hid_source = examples_dir ++ "usb_hid.zig";

    // The build.zig.zon paths omit core, drivers, and the examples. Skip the
    // checkout-only USB suites so the published port's test step can run.
    for ([_][]const u8{ core_source, drivers_source, cdc_source, hid_source }) |source| {
        const stat = b.root.statFile(b.graph.io, source) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        if (stat.kind != .file) return;
    }

    const stm32_data = b.lazyDependency("stm32-data-generated", .{}) orelse return;
    const regz = b.dependency("microzig/tools/regz", .{ .optimize = .safe }).artifact("regz");
    const generate_chip = b.addRunArtifact(regz);
    generate_chip.addArgs(&.{ "--format", "embassy", "--output_path" });
    const chips = generate_chip.addOutputDirectoryArg2("chips", .{});
    generate_chip.addArgs(&.{ "--device", "STM32F103C8" });
    generate_chip.addDirectoryArg2(stm32_data.path("."), .{});

    const host = b.graph.host;
    const core = b.createModule(.{
        .root_source_file = b.path(core_source),
        .target = host,
    });
    const drivers = b.createModule(.{
        .root_source_file = b.path(drivers_source),
        .target = host,
    });
    const chip = b.createModule(.{
        .root_source_file = chips.path(b, "STM32F103C8.zig"),
        .target = host,
    });
    const usb_dir = "src/hals/STM32F103/usb_internals/";
    const ll = b.createModule(.{
        .root_source_file = b.path(usb_dir ++ "usb_ll.zig"),
        .target = host,
    });
    const test_microzig = b.createModule(.{
        .root_source_file = b.path(usb_dir ++ "usb_test_microzig.zig"),
        .target = host,
        .imports = &.{
            .{ .name = "chip", .module = chip },
            .{ .name = "core_support", .module = core },
            .{ .name = "drivers", .module = drivers },
            .{ .name = "usb_ll", .module = ll },
        },
    });
    chip.addImport("microzig", test_microzig);
    ll.addImport("microzig", test_microzig);

    const ll_tests = b.addTest(.{ .name = "stm32f103-usb-ll", .root_module = ll });
    test_step.dependOn(&b.addRunArtifact(ll_tests).step);
    inline for (.{ .{ "cdc", cdc_source }, .{ "hid", hid_source } }) |entry| {
        const example_tests = b.addTest(.{
            .name = "stm32f103-usb-" ++ entry[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(entry[1]),
                .target = host,
                .imports = &.{.{ .name = "microzig", .module = test_microzig }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
    }
}
