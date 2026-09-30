const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("weeoui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // libpng decodes the PNG strikes inside color emoji fonts (Noto Color Emoji, Apple Color Emoji).
    const freetype = b.dependency("freetype", .{ .target = target, .optimize = optimize, .@"enable-libpng" = true });
    const eggenvector = b.dependency("eggenvector", .{ .target = target, .optimize = optimize });
    mod.addImport("eggenvector", eggenvector.module("eggenvector"));
    mod.addImport("freetype", freetype.module("freetype"));
    mod.linkLibrary(freetype.artifact("freetype"));
    // Aro's `@cImport` rejects bionic's `_Nonnull` array parameters; zig-android-sdk does the same for translate-c.
    if (target.result.abi.isAndroid()) {
        for ([_]*std.Build.Module{ mod, freetype.module("freetype") }) |m| {
            m.addCMacro("_Nonnull", "");
            m.addCMacro("_Nullable", "");
        }
        makePic(freetype.artifact("freetype"));
    }
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
                .link_libc = true, // `@cImport("jni.h")` on Android
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

    // Both backends: `weeoui_sdl3.run` opens a window and draws with `weeoui_vitellus.Painter`.
    if (sdl3_dep != null and vitellus_dep != null) {
        const vitellus_module = vitellus_dep.?.module("vitellus");
        const sdl_window = b.createModule(.{
            .root_source_file = vitellus_dep.?.path("src/windowing/sdl3.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "vitellus", .module = vitellus_module }, .{ .name = "sdl3", .module = sdl3_dep.?.module("sdl3") } },
        });
        adapter.?.addImport("vitellus", vitellus_module);
        adapter.?.addImport("vitellus_sdl3", sdl_window);
        adapter.?.addImport("weeoui_vitellus", renderer.?);
        // `zig build counter -Dsdl3 -Dvitellus`: the README quick start as a runnable window.
        const counter_module = b.createModule(.{
            .root_source_file = b.path("examples/counter.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "weeoui", .module = mod },
                .{ .name = "weeoui_sdl3", .module = adapter.? },
            },
        });
        const counter_step = b.step("counter", "Run the counter example (on Android: build, install and launch the APK)");
        if (target.result.abi.isAndroid()) {
            addAndroidCounter(b, counter_step, counter_module, vitellus_dep.?, sdl3_dep.?.module("sdl3"));
        } else {
            const counter = b.addExecutable(.{ .name = "counter", .root_module = counter_module, .use_llvm = true });
            counter_step.dependOn(&b.addRunArtifact(counter).step);
        }
    }
}

/// Android links everything into one shared `libmain.so`, so static libraries need PIC.
fn makePic(compile: *std.Build.Step.Compile) void {
    compile.root_module.pic = true;
    for (compile.root_module.link_objects.items) |object| if (object == .other_step) makePic(object.other_step);
}

/// `zig build counter -Dsdl3 -Dvitellus -Dtarget=aarch64-linux-android.35`: package the counter as
/// an APK (`zig-out/bin/counter.apk`), then install and start it with adb. Needs `ANDROID_HOME`.
fn addAndroidCounter(b: *std.Build, step: *std.Build.Step, root_module: *std.Build.Module, vitellus: *std.Build.Dependency, sdl3: *std.Build.Module) void {
    const android = b.lazyImport(@This(), "android") orelse return;
    const vitellus_build = b.lazyImport(@This(), "vitellus") orelse return;
    const sdk = android.Sdk.create(b, .{});
    const apk = sdk.createApk(.{
        .name = "counter",
        .api_level = .android15,
        .build_tools_version = "36.0.0",
        .ndk_version = "27.1.12297006",
    });
    apk.setKeyStore(sdk.createKeyStore(.example));
    apk.setAndroidManifest(b.path("examples/android/AndroidManifest.xml"));
    apk.addJavaSourceFiles(.{
        .root = b.path("examples/android/java"),
        .files = &.{
            "org/libsdl/app/SDL.java",
            "org/libsdl/app/SDLActivity.java",
            "org/libsdl/app/SDLAudioManager.java",
            "org/libsdl/app/SDLControllerManager.java",
            "org/libsdl/app/SDLDummyEdit.java",
            "org/libsdl/app/SDLInputConnection.java",
            "org/libsdl/app/SDLSurface.java",
            "org/libsdl/app/HIDDevice.java",
            "org/libsdl/app/HIDDeviceManager.java",
            "org/libsdl/app/HIDDeviceUSB.java",
            "org/libsdl/app/HIDDeviceBLESteamController.java",
        },
    });
    // zig-sdl3's SDL has no Android backend; Vitellus rebuilds it with its Android patch.
    // SDLActivity loads `libmain.so` and calls its exported `SDL_main`.
    const lib = b.addLibrary(.{ .name = "main", .linkage = .dynamic, .root_module = root_module, .use_llvm = true });
    const sdl = vitellus_build.androidSdl(b, vitellus, sdl3, lib);
    apk.addLibraryFile(switch (root_module.resolved_target.?.result.cpu.arch) {
        .aarch64 => .arm64_v8a,
        .arm => .armeabi_v7a,
        .x86_64 => .x86_64,
        .x86 => .x86,
        else => @panic("unsupported Android architecture"),
    }, sdl.library);
    apk.addArtifact(lib);
    const installed = apk.addInstallApk();
    sdl.setLibC(lib.libc_file.?);
    b.getInstallStep().dependOn(&installed.step);
    const install = sdk.addAdbInstall(installed.source);
    const start = sdk.addAdbStart("com.eggyengine.weeoui.counter/org.libsdl.app.SDLActivity");
    start.step.dependOn(&install.step);
    step.dependOn(&start.step);
}

/// Screen-reader support is on for desktop targets: link AccessKit's prebuilt C library into Weeoui.
/// On Windows it is a DLL; apps install `accesskit_dll` (a named lazy path) next to their executable.
fn linkAccessKit(b: *std.Build, mod: *std.Build.Module, target: std.Target) void {
    const accesskit = b.dependency("accesskit_c", .{});
    mod.addIncludePath(accesskit.path("include"));
    mod.link_libc = true;
    if (target.abi.isAndroid()) return; // no Android build; `accesskit.supported` is false there
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
