const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("weeoui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addDocs(b, mod, "weeoui");
    // libpng decodes the PNG strikes inside color emoji fonts (Noto Color Emoji, Apple Color Emoji).
    const freetype = b.dependency("freetype", .{ .target = target, .optimize = optimize, .@"enable-libpng" = true });
    const eggenvector = b.dependency("eggenvector", .{ .target = target, .optimize = optimize });
    mod.addImport("eggenvector", eggenvector.module("eggenvector"));
    mod.addImport("freetype", freetype.module("freetype"));
    mod.linkLibrary(freetype.artifact("freetype"));
    // stb_image decodes PNG/JPEG/GIF/...; stb_image_resize2 fits them into the color atlas.
    const stb = b.dependency("stb", .{});
    mod.addIncludePath(stb.path(""));
    mod.addCSourceFile(.{
        .file = b.addWriteFiles().add("stb.c",
            \\#define STB_IMAGE_IMPLEMENTATION
            \\#define STBI_NO_STDIO
            \\#include "stb_image.h"
            \\#define STB_IMAGE_RESIZE_IMPLEMENTATION
            \\#include "stb_image_resize2.h"
        ),
        // stb relies on shifts that UBSan traps on.
        .flags = &.{"-fno-sanitize=undefined"},
    });
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
        // `zig build counter|demo -Dsdl3 -Dvitellus`: the README quick start and the component
        // gallery. With an Android `-Dtarget` they build, install and launch APKs instead.
        const apps = [_]App{
            .{ .name = "counter", .module = example(b, "counter", mod, adapter.?), .step = b.step("counter", "Run the counter example") },
            .{ .name = "demo", .module = example(b, "demo", mod, adapter.?), .step = b.step("demo", "Run the component gallery") },
        };
        if (target.result.abi.isAndroid()) {
            addAndroidApps(b, &apps, vitellus_dep.?, sdl3_dep.?.module("sdl3"));
        } else {
            for (apps) |app| addDesktopExample(b, app.step, app.name, app.module);
            test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = apps[1].module, .use_llvm = true })).step);
        }
    }
}

fn example(b: *std.Build, name: []const u8, weeoui: *std.Build.Module, sdl3: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
        .target = weeoui.resolved_target,
        .optimize = weeoui.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "weeoui", .module = weeoui },
            .{ .name = "weeoui_sdl3", .module = sdl3 },
        },
    });
}

/// Install `name` with `zig build` (so `-Dtarget=x86_64-windows` cross-builds land in zig-out/bin)
/// and run the installed copy from `step`, so Windows finds accesskit.dll beside it.
fn addDesktopExample(b: *std.Build, step: *std.Build.Step, name: []const u8, root_module: *std.Build.Module) void {
    const exe = b.addExecutable(.{ .name = name, .root_module = root_module, .use_llvm = true });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);
    const run = b.addSystemCommand(&.{b.getInstallPath(.bin, exe.out_filename)});
    run.step.dependOn(&install.step);
    if (b.named_lazy_paths.get("accesskit_dll")) |dll| {
        const install_dll = b.addInstallBinFile(dll, "accesskit.dll");
        b.getInstallStep().dependOn(&install_dll.step);
        run.step.dependOn(&install_dll.step);
    }
    if (b.args) |args| run.addArgs(args);
    step.dependOn(&run.step);
}

/// Android links everything into one shared `libmain.so`, so static libraries need PIC.
fn makePic(compile: *std.Build.Step.Compile) void {
    compile.root_module.pic = true;
    for (compile.root_module.link_objects.items) |object| if (object == .other_step) makePic(object.other_step);
}

const App = struct { name: []const u8, module: *std.Build.Module, step: *std.Build.Step };

/// `zig build <app> -Dsdl3 -Dvitellus -Dtarget=aarch64-linux-android.35`: package each app as an
/// APK (`zig-out/bin/<app>.apk`, package `com.eggyengine.weeoui.<app>`), then install and start
/// it with adb. Needs `ANDROID_HOME`.
fn addAndroidApps(b: *std.Build, apps: []const App, vitellus: *std.Build.Dependency, sdl3: *std.Build.Module) void {
    const android = b.lazyImport(@This(), "android") orelse return;
    const vitellus_build = b.lazyImport(@This(), "vitellus") orelse return;
    const sdk = android.Sdk.create(b, .{});
    // SDLActivity loads `libmain.so` and calls its exported `SDL_main` (see `weeoui_sdl3.exportAndroidMain`).
    const libs = b.allocator.alloc(*std.Build.Step.Compile, apps.len) catch @panic("OOM");
    for (apps, libs) |app, *lib| lib.* = b.addLibrary(.{ .name = "main", .linkage = .dynamic, .root_module = app.module, .use_llvm = true });
    // zig-sdl3's SDL has no Android backend; Vitellus rebuilds it once, with its Android patch, for every app.
    const sdl = vitellus_build.androidSdl(b, vitellus, sdl3, libs);
    for (apps, libs, 0..) |app, lib, i| {
        const apk = sdk.createApk(.{
            .name = app.name,
            .api_level = .android15,
            .build_tools_version = "36.0.0",
            .ndk_version = "27.1.12297006",
        });
        apk.setKeyStore(sdk.createKeyStore(.example));
        apk.setAndroidManifest(b.addWriteFiles().add("AndroidManifest.xml", b.fmt(android_manifest, .{ app.name, app.name })));
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
        apk.addLibraryFile(switch (app.module.resolved_target.?.result.cpu.arch) {
            .aarch64 => .arm64_v8a,
            .arm => .armeabi_v7a,
            .x86_64 => .x86_64,
            .x86 => .x86,
            else => @panic("unsupported Android architecture"),
        }, sdl.library);
        apk.addArtifact(lib);
        const installed = apk.addInstallApk();
        if (i == 0) sdl.setLibC(lib.libc_file.?);
        b.getInstallStep().dependOn(&installed.step);
        const install = sdk.addAdbInstall(installed.source);
        const start = sdk.addAdbStart(b.fmt("com.eggyengine.weeoui.{s}/org.libsdl.app.SDLActivity", .{app.name}));
        start.step.dependOn(&install.step);
        app.step.dependOn(&start.step);
    }
}

const android_manifest =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    \\    android:versionCode="1"
    \\    android:versionName="0.0.1"
    \\    package="com.eggyengine.weeoui.{s}">
    \\    <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="35" />
    \\    <uses-feature android:name="android.hardware.vulkan.level" android:version="1" android:required="true" />
    \\    <uses-feature android:name="android.hardware.vulkan.version" android:version="0x00401000" android:required="true" />
    \\    <application android:label="weeoui {s}" android:theme="@android:style/Theme.NoTitleBar.Fullscreen" android:hardwareAccelerated="true">
    \\        <activity
    \\            android:name="org.libsdl.app.SDLActivity"
    \\            android:configChanges="layoutDirection|locale|orientation|uiMode|screenLayout|screenSize|smallestScreenSize|keyboard|keyboardHidden|navigation"
    \\            android:exported="true">
    \\            <intent-filter>
    \\                <action android:name="android.intent.action.MAIN" />
    \\                <category android:name="android.intent.category.LAUNCHER" />
    \\            </intent-filter>
    \\        </activity>
    \\    </application>
    \\</manifest>
    \\
;

/// Screen-reader support is on for desktop targets: link AccessKit's prebuilt C library into Weeoui.
/// On Windows it is a DLL; apps install `accesskit_dll` (a named lazy path) next to their executable.
fn linkAccessKit(b: *std.Build, mod: *std.Build.Module, target: std.Target) void {
    const accesskit = b.dependency("accesskit_c", .{});
    mod.addIncludePath(accesskit.path("include"));
    mod.link_libc = true;
    // No Android or web build; `accesskit.supported` is false there.
    if (target.abi.isAndroid() or target.os.tag == .emscripten) return;
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

/// `zig build docs`: Zig's HTML API docs for `mod` in zig-out/docs, which
/// .github/workflows/docs.yml publishes to GitHub Pages.
fn addDocs(b: *std.Build, mod: *std.Build.Module, name: []const u8) void {
    const docs = b.addObject(.{ .name = name, .root_module = mod });
    const install = b.addInstallDirectory(.{ .source_dir = docs.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "docs" });
    b.step("docs", "Build the API docs into zig-out/docs").dependOn(&install.step);
}
