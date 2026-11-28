const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Configurable options
    const mem_size = b.option(
        usize,
        "mem_size",
        "The size of the heap memory",
    ) orelse 16 * 1024;
    const pbuf_pool_size = b.option(
        usize,
        "pbuf_pool_size",
        "The number of buffers in the packet buffer pool",
    ) orelse 32;
    const mtu = b.option(
        u16,
        "mtu",
        "Layer 3 MTU, includes TCP/UDP and IP headers, don't include layer 2 Ethernet header",
    ) orelse 1500;
    const pbuf_header_length = b.option(
        u16,
        "pbuf_header_length",
        "The number of bytes allocated in packet buffer before Ethernet header for use in the underlying link driver",
    ) orelse 0;
    const pbuf_length = b.option(
        u16,
        "pbuf_length",
        "The size of each packet buffer in the pool",
    ) orelse mtu + ethernet_header + pbuf_header_length;

    _ = add_network_module(b, "net", target, optimize, .{
        .mem_size = mem_size,
        .pbuf_pool_size = pbuf_pool_size,
        .mtu = mtu,
        .pbuf_length = pbuf_length,
        .pbuf_header_length = pbuf_header_length,
    });

    // Exercise the link driver's reserved prefix on the host as well.
    const host_net = add_network_module(b, null, b.graph.host, optimize, .{
        .mem_size = 16 * 1024,
        .pbuf_pool_size = 32,
        .mtu = 1500,
        .pbuf_length = 1540,
        .pbuf_header_length = 22,
    });
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "net", .module = host_net }},
        }),
    });
    b.step("test", "Run host network tests").dependOn(&b.addRunArtifact(tests).step);
}

const ethernet_header = 14;

const Settings = struct {
    mem_size: usize,
    pbuf_pool_size: usize,
    mtu: u16,
    pbuf_length: u16,
    pbuf_header_length: u16,
};

fn add_network_module(
    b: *std.Build,
    name: ?[]const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    settings: Settings,
) *std.Build.Module {
    const mtu = settings.mtu;
    const pbuf_length = settings.pbuf_length;
    const pbuf_header_length = settings.pbuf_header_length;
    if (pbuf_length < mtu + ethernet_header + pbuf_header_length) {
        @panic("Invalid lwip packet buffer length");
    }

    const foundation_dep = b.dependency("foundationlibc", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });

    const lwip_dep = b.dependency("lwip", .{
        .target = target,
        .optimize = optimize,
        .include_dir = b.path("src/include"),
        .c_macros = &[_][]const u8{
            // Align for both DMA words and pointers stored by lwIP.
            b.fmt("MEM_ALIGNMENT={d}", .{@max(4, target.result.ptrBitWidth() / 8)}),
            // IPv6 reassembly overlays a pointer on the 8-byte fragment header
            // unless the header is copied aside.
            b.fmt("IPV6_FRAG_COPYHEADER={d}", .{@intFromBool(target.result.ptrBitWidth() > 32)}),
            b.fmt("MEM_SIZE={d}", .{settings.mem_size}),
            b.fmt("PBUF_POOL_SIZE={d}", .{settings.pbuf_pool_size}),
            b.fmt("PBUF_LINK_HLEN={d}", .{ethernet_header}),
            b.fmt("PBUF_POOL_BUFSIZE={d}", .{pbuf_length}),
            b.fmt("PBUF_LINK_ENCAPSULATION_HLEN={d}", .{pbuf_header_length}),
            // Reserve 40 bytes for IPv6 and 20 for TCP.
            b.fmt("TCP_MSS={d}", .{mtu - 40 - 20}),
        },
    });

    const lwip = lwip_dep.module("lwip");
    lwip.linkLibrary(foundation_dep.artifact("foundation"));

    const options = b.addOptions();
    options.addOption(u16, "mtu", mtu);
    options.addOption(u16, "pbuf_length", pbuf_length);
    options.addOption(u16, "pbuf_header_length", pbuf_header_length);
    const module_options: std.Build.Module.CreateOptions = .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "link", .module = b.dependency("link", .{}).module("link") },
            .{ .name = "lwip", .module = lwip },
            .{ .name = "config", .module = options.createModule() },
        },
    };
    return if (name) |module_name| b.addModule(module_name, module_options) else b.createModule(module_options);
}
