const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("weeoui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const freetype = b.dependency("freetype", .{ .target = target, .optimize = optimize });
    const eggenvector = b.dependency("eggenvector", .{ .target = target, .optimize = optimize });
    mod.addImport("eggenvector", eggenvector.module("eggenvector"));
    mod.addImport("freetype", freetype.module("freetype"));
    mod.linkLibrary(freetype.artifact("freetype"));
    linkAccessKit(b, mod, target.result);
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = mod, .use_llvm = true }));
    const test_step = b.step("test", "Check Weeoui module");
    test_step.dependOn(&tests.step);

    // Opt-in so consumers without SDL never fetch it.
    var sdl3_dep: ?*std.Build.Dependency = null;
    var adapter: ?*std.Build.Module = null;
    if (b.option(bool, "sdl3", "Provide the weeoui_sdl3 input adapter module") orelse false) {
        if (b.lazyDependency("sdl3", .{ .target = target, .optimize = optimize })) |sdl3| {
            sdl3_dep = sdl3;
            adapter = b.addModule("weeoui_sdl3", .{
                .root_source_file = b.path("src/sdl3.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "weeoui", .module = mod }, .{ .name = "sdl3", .module = sdl3.module("sdl3") } },
            });
            test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = adapter.?, .use_llvm = true })).step);
        }
    }
    // Opt-in Vitellus renderer. Projects that already build Vitellus can instead compile
    // `src/vitellus.zig` with their own `vitellus` import to avoid a second copy.
    var vitellus_dep: ?*std.Build.Dependency = null;
    var renderer: ?*std.Build.Module = null;
    if (b.option(bool, "vitellus", "Provide the weeoui_vitellus renderer module") orelse false) {
        if (b.lazyDependency("vitellus", .{ .target = target, .optimize = optimize })) |vitellus| {
            vitellus_dep = vitellus;
            renderer = b.addModule("weeoui_vitellus", .{
                .root_source_file = b.path("src/vitellus.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "weeoui", .module = mod }, .{ .name = "vitellus", .module = vitellus.module("vitellus") } },
            });
            test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = renderer.?, .use_llvm = true })).step);
        }
    }

    // `zig build counter -Dsdl3 -Dvitellus`: the README quick start as a runnable window.
    if (sdl3_dep != null and vitellus_dep != null) {
        const vitellus_module = vitellus_dep.?.module("vitellus");
        const sdl_window = b.createModule(.{
            .root_source_file = vitellus_dep.?.path("src/windowing/sdl3.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "vitellus", .module = vitellus_module }, .{ .name = "sdl3", .module = sdl3_dep.?.module("sdl3") } },
        });
        const counter = b.addExecutable(.{
            .name = "counter",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/counter.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "weeoui", .module = mod },
                    .{ .name = "weeoui_sdl3", .module = adapter.? },
                    .{ .name = "weeoui_vitellus", .module = renderer.? },
                    .{ .name = "vitellus", .module = vitellus_module },
                    .{ .name = "vitellus_sdl3", .module = sdl_window },
                },
            }),
            .use_llvm = true,
        });
        b.step("counter", "Run the counter example").dependOn(&b.addRunArtifact(counter).step);
    }
}

/// Screen-reader support is always on: link AccessKit's prebuilt C library into Weeoui.
/// On Windows it is a DLL; apps install `accesskit_dll` (a named lazy path) next to their executable.
fn linkAccessKit(b: *std.Build, mod: *std.Build.Module, target: std.Target) void {
    const accesskit = b.dependency("accesskit_c", .{});
    mod.addIncludePath(accesskit.path("include"));
    mod.link_libc = true;
    const msvc = target.abi == .msvc;
    const library = switch (target.os.tag) {
        .linux => switch (target.cpu.arch) {
            .x86_64 => "lib/linux/x86_64/static/libaccesskit.a",
            .x86 => "lib/linux/x86/static/libaccesskit.a",
            else => @panic("AccessKit C 0.23.0 has no bundled Linux library for this architecture"),
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => if (msvc) "lib/windows/x86_64/msvc/shared/accesskit.lib" else "lib/windows/x86_64/mingw/shared/libaccesskit.a",
            .aarch64 => "lib/windows/arm64/msvc/shared/accesskit.lib",
            else => @panic("AccessKit C 0.23.0 has no bundled Windows library for this architecture"),
        },
        .macos => switch (target.cpu.arch) {
            .x86_64 => "lib/macos/x86_64/static/libaccesskit.a",
            .aarch64 => "lib/macos/arm64/static/libaccesskit.a",
            else => @panic("AccessKit C 0.23.0 has no bundled macOS library for this architecture"),
        },
        else => @panic("AccessKit is supported only on desktop Linux, macOS, and Windows"),
    };
    mod.addObjectFile(accesskit.path(library));
    switch (target.os.tag) {
        .linux => {
            mod.linkSystemLibrary("m", .{});
            mod.linkSystemLibrary("unwind", .{});
        },
        .windows => b.addNamedLazyPath("accesskit_dll", accesskit.path(switch (target.cpu.arch) {
            .aarch64 => "lib/windows/arm64/msvc/shared/accesskit.dll",
            else => if (msvc) "lib/windows/x86_64/msvc/shared/accesskit.dll" else "lib/windows/x86_64/mingw/shared/accesskit.dll",
        })),
        .macos => {
            inline for (.{ "AppKit", "Foundation", "CoreFoundation" }) |framework| mod.linkFramework(framework, .{});
            mod.linkSystemLibrary("objc", .{});
            mod.linkSystemLibrary("c++", .{});
        },
        else => unreachable,
    }
}
