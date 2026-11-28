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
    const data = try b.dependencyLazy("stm32-data-generated", .{});
    const regz_dep = b.dependency("microzig/tools/regz", .{ .optimize = .safe });
    const generate = b.option(bool, "generate", "") orelse false;
    if (generate) {
        const regz = regz_dep.module("regz");

        const generate_exe = b.addExecutable(.{
            .name = "generate",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/generate.zig"),
                .target = b.graph.host,
                .optimize = .safe,
            }),
        });
        generate_exe.root_module.addImport("regz", regz);

        const generate_run = b.addRunArtifact(generate_exe);
        generate_run.addFileArg(data.path("."));

        b.getInstallStep().dependOn(&generate_run.step);
    }

    const test_step = b.step("test", "Run platform agnostic unit tests");
    const generate_chip = b.addRunArtifact(regz_dep.artifact("regz"));
    generate_chip.addArgs(&.{ "--format", "embassy", "--output_path" });
    const chip_dir = generate_chip.addOutputDirectoryArg("chips");
    generate_chip.addArgs(&.{ "--device", "STM32F303VC" });
    generate_chip.addDirectoryArg(data.path("."));

    const sources = b.addWriteFiles();
    // Keep relative imports between HAL files within the host test module.
    _ = sources.addCopyDirectory(b.path("src/hals"), "hals", .{});
    const test_root = sources.add("tests.zig",
        \\test {
        \\    _ = @import("hals/STM32F103/drivers.zig");
        \\    _ = @import("hals/common/i2c_v2.zig");
        \\    _ = @import("hals/common/spi_v2.zig");
        \\    _ = @import("hals/common/systick.zig");
        \\}
    );
    // Host tests use real register layouts and portable drivers. ARM interrupt
    // instructions and the hardware clock are replaced by host stand-ins.
    const shim = b.createModule(.{ .root_source_file = sources.add("microzig.zig",
        \\pub const chip = @import("chip");
        \\pub const config = .{ .chip_name = "STM32F303VC" };
        \\pub const mmio = @import("core").mmio;
        \\pub const utilities = @import("core").utilities;
        \\pub const drivers = @import("drivers");
        \\pub const interrupt = struct {
        \\    pub fn enter_critical_section() Section { return .{}; }
        \\    const Section = struct { pub fn leave(_: Section) void {} };
        \\};
        \\pub const hal = struct {
        \\    pub const systick = struct {
        \\        pub fn is_initialized() bool { return false; }
        \\        pub fn get_time_since_boot() u64 { unreachable; }
        \\    };
        \\};
    ) });
    const chip = b.createModule(.{ .root_source_file = chip_dir.path(b, "STM32F303VC.zig") });
    chip.addImport("microzig", shim);
    shim.addImport("chip", chip);
    shim.addImport("core", b.createModule(.{ .root_source_file = b.path("../../../core/src/microzig.zig") }));
    shim.addImport("drivers", b.createModule(.{ .root_source_file = b.path("../../../drivers/src/root.zig") }));

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = test_root,
            .target = b.graph.host,
            .imports = &.{.{ .name = "microzig", .module = shim }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
