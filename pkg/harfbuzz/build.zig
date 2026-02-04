const std = @import("std");
const apple_sdk = @import("apple_sdk");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const freetype_enabled = b.option(bool, "enable-freetype", "Build freetype") orelse true;

    const freetype = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .@"enable-libpng" = true,
    });

    const module = harfbuzz: {
        const module = b.addModule("harfbuzz", .{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "freetype", .module = freetype.module("freetype") },
            },
        });

        const options = b.addOptions();
        options.addOption(bool, "coretext", false);
        options.addOption(bool, "freetype", freetype_enabled);
        module.addOptions("build_options", options);
        break :harfbuzz module;
    };

    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    if (!b.systemIntegrationOption("harfbuzz", .{})) {
        const lib = try buildLib(b, module, .{
            .target = target,
            .optimize = optimize,
            .freetype_enabled = freetype_enabled,
            .dynamic_link_opts = dynamic_link_opts,
        });
        _ = lib;
    }
}

fn buildLib(b: *std.Build, module: *std.Build.Module, options: anytype) !*std.Build.Step.Compile {
    const target = options.target;
    const optimize = options.optimize;
    const freetype_enabled = options.freetype_enabled;

    const freetype = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .@"enable-libpng" = true,
    });

    const lib = b.addLibrary(.{
        .name = "harfbuzz",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.linkLibC();
    lib.linkLibCpp();

    if (target.result.os.tag.isDarwin()) {
        try apple_sdk.addPaths(b, lib);
    }

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.appendSlice(b.allocator, &.{
        "-DHAVE_STDBOOL_H",
    });
    if (target.result.os.tag != .windows) {
        try flags.appendSlice(b.allocator, &.{
            "-DHAVE_UNISTD_H",
            "-DHAVE_SYS_MMAN_H",
            "-DHAVE_PTHREAD=1",
        });
    }

    if (freetype_enabled) {
        try flags.appendSlice(b.allocator, &.{
            "-DHAVE_FREETYPE=1",
            "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_DONE_MM_VAR=1",
            "-DHAVE_FT_GET_TRANSFORM=1",
        });

        lib.linkLibrary(freetype.artifact("freetype"));

        if (freetype.builder.lazyDependency(
            "freetype",
            .{},
        )) |freetype_dep| {
            module.addIncludePath(freetype_dep.path("include"));
        }
    }

    if (b.lazyDependency("harfbuzz", .{})) |upstream| {
        lib.addIncludePath(upstream.path("src"));
        module.addIncludePath(upstream.path("src"));
        lib.addCSourceFile(.{
            .file = upstream.path("src/harfbuzz.cc"),
            .flags = flags.items,
        });
        lib.installHeadersDirectory(
            upstream.path("src"),
            "",
            .{ .include_extensions = &.{".h"} },
        );
    }

    b.installArtifact(lib);

    return lib;
}
