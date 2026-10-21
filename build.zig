const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Browser builds (WebGPU) link with Emscripten; its sysroot must be set before any C dependency.
    const web = target.result.os.tag == .emscripten;
    const emscripten = if (web) (b.lazyImport(@This(), "vitellus") orelse return).Emscripten.init(b, target, b.option([]const u8, "emsdk", "Path to emsdk for web builds (default: $EMSDK, then ~/emsdk)")) else null;
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
    // Web apps that use `ui.web` link this with `emcc --js-library`.
    b.addNamedLazyPath("web_js", b.path("src/web.js"));
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = mod, .use_llvm = true }));
    const test_step = b.step("test", "Check Weeoui module");
    test_step.dependOn(&tests.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("build/strip_debug_info.zig"), .target = b.graph.host }) })).step);

    // Opt-in so consumers without SDL never fetch it.
    var sdl3_dep: ?*std.Build.Dependency = null;
    var adapter: ?*std.Build.Module = null;
    // On by default when building Weeoui itself (so `zig build counter` just works); opt-in for
    // projects that depend on it, so ones without SDL never fetch it. `addApp` turns both on.
    const root_project = b.pkg_hash.len == 0;
    if (b.option(bool, "sdl3", "Provide the weeoui_sdl3 input adapter module") orelse root_project) {
        // SDL 3.4.0's Wayland pointer-leave handler shifts by -1 (`SDL_BUTTON_MASK(0)`), so UBSan
        // traps whenever the pointer leaves with a button held, e.g. dragging the title bar.
        const sdl3_lazy = if (emscripten) |em|
            b.lazyDependency("sdl3", .{ .target = target, .optimize = optimize, .c_sdl_sanitize_c = .off, .sdl_system_include_path = em.include })
        else
            b.lazyDependency("sdl3", .{ .target = target, .optimize = optimize, .c_sdl_sanitize_c = .off });
        if (sdl3_lazy) |sdl3| {
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
    if (b.option(bool, "vitellus", "Provide the weeoui_vitellus renderer module") orelse root_project) {
        if (b.lazyDependency("vitellus", .{ .target = target, .optimize = optimize })) |vitellus| {
            vitellus_dep = vitellus;
            renderer = b.addModule("weeoui_vitellus", .{
                .root_source_file = b.path("src/vitellus.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "weeoui", .module = mod }, .{ .name = "vitellus", .module = vitellus.module("vitellus") }, .{ .name = "vitellus_spirv", .module = vitellus.module("vitellus_spirv") } },
            });
            test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = renderer.?, .use_llvm = true })).step);
        }
    }

    // Both backends: `weeoui_sdl3.run` opens a window and draws with `weeoui_vitellus.Painter`.
    if (sdl3_dep != null and vitellus_dep != null) {
        const vitellus_module = vitellus_dep.?.module("vitellus");
        const sdl_window = b.addModule("vitellus_sdl3", .{
            .root_source_file = vitellus_dep.?.path("src/windowing/sdl3.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "vitellus", .module = vitellus_module }, .{ .name = "sdl3", .module = sdl3_dep.?.module("sdl3") } },
        });
        adapter.?.addImport("vitellus", vitellus_module);
        adapter.?.addImport("vitellus_sdl3", sdl_window);
        adapter.?.addImport("weeoui_vitellus", renderer.?);
        if (!root_project) return;
        // The examples, built like any Weeoui app: `zig build counter|demo|gallery`, with
        // `-Dtarget=wasm32-emscripten` for the browser or `-Dtarget=aarch64-linux-android.35` for an APK.
        const parts = Parts.of(b, target, optimize).?;
        buildApp(b, parts, .{ .name = "counter", .root_source_file = b.path("examples/counter.zig"), .step = "counter" });
        buildApp(b, parts, .{ .name = "demo", .root_source_file = b.path("examples/demo.zig"), .step = "demo" });
        // ponytail: no Android gallery; its SDL main callbacks need SDL_main.h, which Vitellus's
        // Android SDL build leaves out. `run` apps start through `exportMain` there instead.
        if (!target.result.abi.isAndroid()) buildApp(b, parts, .{
            .name = "gallery",
            .root_source_file = b.path("examples/gallery/main.zig"),
            .step = "gallery",
            // Docking and DevTools sit below `Context`, so the gallery runs its own SDL main callbacks.
            .own_entry = true,
            .imports = &.{ .{ .name = "weeoui_vitellus", .module = renderer.? }, .{ .name = "vitellus", .module = vitellus_module }, .{ .name = "vitellus_sdl3", .module = sdl_window } },
        });
        if (target.result.os.tag == .emscripten or target.result.abi.isAndroid()) return;
        for ([_][]const u8{ "examples/demo.zig", "examples/gallery/demo.zig" }) |file| {
            const tested = b.createModule(.{ .root_source_file = b.path(file), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "weeoui", .module = mod }, .{ .name = "weeoui_sdl3", .module = adapter.? } }, .link_libc = true });
            test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tested, .use_llvm = true })).step);
        }
    }
}

pub const AppOptions = struct {
    name: []const u8,
    /// Your app: a `pub fn main(init: std.process.Init) !void` that calls `weeoui_sdl3.run`.
    /// Nothing else is needed: logging, panics and each platform's entry point are set up for you.
    root_source_file: std.Build.LazyPath,
    /// Defaults to `-Dtarget` and `-Doptimize`. Pass them when building several apps.
    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.builtin.OptimizeMode = null,
    /// The `zig build` step that runs the app.
    step: []const u8 = "run",
    /// Other modules your app imports.
    imports: []const std.Build.Module.Import = &.{},
    /// Your file is the program's root and starts itself (SDL's main callbacks, say) instead of
    /// having a `main` for Weeoui to wrap.
    own_entry: bool = false,
};

/// Build a Weeoui app for wherever `-Dtarget` points: a desktop program, a web page
/// (`wasm32-emscripten`, into zig-out/web) or an Android APK. In your build.zig:
///
///     pub fn build(b: *std.Build) void {
///         @import("weeoui").addApp(b, .{ .name = "coop", .root_source_file = b.path("src/main.zig") });
///     }
///
/// `zig build run` starts it: runs the program, opens the page in a browser, or installs and
/// launches the APK with adb (needs `ANDROID_HOME`). The web needs emsdk (`$EMSDK` or ~/emsdk).
pub fn addApp(b: *std.Build, options: AppOptions) void {
    const target = options.target orelse b.standardTargetOptions(.{});
    const optimize = options.optimize orelse b.standardOptimizeOption(.{});
    const weeoui = b.dependency("weeoui", .{ .target = target, .optimize = optimize, .sdl3 = true, .vitellus = true });
    var resolved = options;
    resolved.target = target;
    resolved.optimize = optimize;
    // On a fresh checkout Weeoui's lazy dependencies (SDL, Vitellus) aren't fetched yet: Zig
    // fetches them and runs this build again.
    buildApp(b, Parts.of(weeoui.builder, target, optimize) orelse return, resolved);
}

/// What an app needs from Weeoui's own build (`weeoui` is Weeoui's builder, even when another
/// project's build calls `addApp`).
const Parts = struct {
    weeoui: *std.Build,
    ui: *std.Build.Module,
    sdl3: *std.Build.Module,
    vitellus: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    fn of(weeoui: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?Parts {
        return .{
            .weeoui = weeoui,
            .ui = weeoui.modules.get("weeoui").?,
            .sdl3 = weeoui.modules.get("weeoui_sdl3") orelse return null,
            // The same arguments Weeoui's build used, so this is that dependency again.
            .vitellus = weeoui.lazyDependency("vitellus", .{ .target = target, .optimize = optimize }) orelse return null,
            .target = target,
            .optimize = optimize,
        };
    }
};

fn buildApp(b: *std.Build, parts: Parts, options: AppOptions) void {
    const target = options.target orelse parts.target;
    const optimize = options.optimize orelse parts.optimize;
    const app = b.createModule(.{ .root_source_file = options.root_source_file, .target = target, .optimize = optimize, .link_libc = true });
    app.addImport("weeoui", parts.ui);
    app.addImport("weeoui_sdl3", parts.sdl3);
    for (options.imports) |import| app.addImport(import.name, import.module);
    const root = if (options.own_entry) app else b.createModule(.{
        // In the browser Zig's start code would wrap a root `main` with threaded I/O, which can't
        // build there; `exportMain` starts it instead.
        .root_source_file = b.addWriteFiles().add("main.zig", if (target.result.os.tag == .emscripten) entry_source else entry_source ++ "pub const main = app.main;\n"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "app", .module = app }, .{ .name = "weeoui_sdl3", .module = parts.sdl3 } },
    });
    const step = b.step(options.step, b.fmt("Run {s}", .{options.name}));
    const wb = parts.weeoui;
    if (target.result.os.tag == .emscripten) {
        const vitellus_build = wb.lazyImport(@This(), "vitellus") orelse return;
        const page = vitellus_build.Emscripten.init(b, target, null).addApp(b, .{
            .name = options.name,
            .root_module = root,
            .shell_file = wb.path("src/shell.html"),
            // The font atlases and Debug frames outgrow Vitellus's 1 MiB stack; web.js is `ui.web`.
            .args = &.{ "-sSTACK_SIZE=8388608", "--js-library", wb.pathFromRoot("src/web.js") },
        });
        step.dependOn(&page.run.step);
    } else if (target.result.abi.isAndroid()) {
        addAndroidApp(b, parts, options.name, root, step);
    } else {
        const exe = b.addExecutable(.{ .name = options.name, .root_module = root, .use_llvm = true });
        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);
        // Run the installed copy, so Windows finds accesskit.dll beside it.
        const run = b.addSystemCommand(&.{b.getInstallPath(.bin, exe.out_filename)});
        run.step.dependOn(&install.step);
        if (wb.named_lazy_paths.get("accesskit_dll")) |dll| {
            const install_dll = b.addInstallBinFile(dll, "accesskit.dll");
            b.getInstallStep().dependOn(&install_dll.step);
            run.step.dependOn(&install_dll.step);
        }
        if (b.args) |args| run.addArgs(args);
        step.dependOn(&run.step);
    }
}

/// The root `addApp` puts around an app's `main`.
const entry_source =
    \\//! Generated by `weeoui.addApp`: starts the app's `main` on every platform.
    \\const std = @import("std");
    \\const app = @import("app");
    \\const weeoui_sdl3 = @import("weeoui_sdl3");
    \\
    \\pub const std_options: std.Options = if (@hasDecl(app, "std_options")) app.std_options else weeoui_sdl3.std_options;
    \\pub const panic = if (@hasDecl(app, "panic")) app.panic else weeoui_sdl3.panic;
    \\comptime {
    \\    weeoui_sdl3.exportMain(app.main);
    \\}
    \\
;

/// Android links everything into one shared `libmain.so`, so static libraries need PIC.
fn makePic(compile: *std.Build.Step.Compile) void {
    compile.root_module.pic = true;
    for (compile.root_module.link_objects.items) |object| if (object == .other_step) makePic(object.other_step);
}

/// Package the app as an APK (`zig-out/bin/<name>.apk`, package `com.eggyengine.weeoui.<name>`),
/// then install and start it with adb from `step`. Needs `ANDROID_HOME`.
fn addAndroidApp(b: *std.Build, parts: Parts, name: []const u8, root: *std.Build.Module, step: *std.Build.Step) void {
    const wb = parts.weeoui;
    const android = wb.lazyImport(@This(), "android") orelse return;
    const vitellus_build = wb.lazyImport(@This(), "vitellus") orelse return;
    const sdk = android.Sdk.create(b, .{});
    // SDLActivity loads `libmain.so` and calls its exported `SDL_main` (`weeoui_sdl3.exportMain`).
    const lib = b.addLibrary(.{ .name = "main", .linkage = .dynamic, .root_module = root, .use_llvm = true });
    // zig-sdl3's SDL has no Android backend; Vitellus rebuilds it with its Android patch. That
    // swaps the library inside the sdl3 module, so it happens once and later apps share it.
    const first = android_sdl == null;
    if (first) {
        const sdl = vitellus_build.androidSdl(b, parts.vitellus, parts.sdl3.import_table.get("sdl3").?, &.{lib});
        android_sdl = .{ .library = sdl.library, .run = sdl.run, .lib = lib };
    } else lib.step.dependOn(&android_sdl.?.lib.step);
    const apk = sdk.createApk(.{
        .name = name,
        .api_level = .android15,
        .build_tools_version = "36.0.0",
        .ndk_version = "27.1.12297006",
    });
    apk.setKeyStore(sdk.createKeyStore(.example));
    apk.setAndroidManifest(b.addWriteFiles().add("AndroidManifest.xml", b.fmt(android_manifest, .{ name, name })));
    apk.addJavaSourceFiles(.{
        .root = wb.path("examples/android/java"),
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
    apk.addLibraryFile(switch (root.resolved_target.?.result.cpu.arch) {
        .aarch64 => .arm64_v8a,
        .arm => .armeabi_v7a,
        .x86_64 => .x86_64,
        .x86 => .x86,
        else => @panic("unsupported Android architecture"),
    }, android_sdl.?.library);
    apk.addArtifact(lib);
    const installed = apk.addInstallApk();
    // The patched SDL builds against the NDK libc zig-android-sdk set on the first app.
    if (first) android_sdl.?.run.addFileArg(lib.libc_file.?);
    b.getInstallStep().dependOn(&installed.step);
    const install = sdk.addAdbInstall(installed.source);
    const start = sdk.addAdbStart(b.fmt("com.eggyengine.weeoui.{s}/org.libsdl.app.SDLActivity", .{name}));
    start.step.dependOn(&install.step);
    step.dependOn(&start.step);
}
var android_sdl: ?struct { library: std.Build.LazyPath, run: *std.Build.Step.Run, lib: *std.Build.Step.Compile } = null;

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

/// Screen-reader support is on for desktop targets AccessKit ships a library for: link its
/// prebuilt C library into Weeoui. Elsewhere (musl, or Linux on other architectures) Weeoui
/// builds without it, as `accesskit.supported` says. On Windows it is a DLL; apps install
/// `accesskit_dll` (a named lazy path) next to their executable.
fn linkAccessKit(b: *std.Build, mod: *std.Build.Module, target: std.Target) void {
    const accesskit = b.dependency("accesskit_c", .{});
    mod.addIncludePath(accesskit.path("include"));
    mod.link_libc = true;
    // No Android, web, musl or other-architecture build: `accesskit.supported` is false there.
    if (target.abi.isAndroid() or target.os.tag == .emscripten) return;
    const msvc = target.abi == .msvc;
    const library = switch (target.os.tag) {
        .linux => if (!target.abi.isGnu()) return else switch (target.cpu.arch) {
            .x86_64 => "lib/linux/x86_64/static/libaccesskit.a",
            .x86 => "lib/linux/x86/static/libaccesskit.a",
            else => return,
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => if (msvc) "lib/windows/x86_64/msvc/shared/accesskit.lib" else "lib/windows/x86_64/mingw/shared/libaccesskit.a",
            .aarch64 => "lib/windows/arm64/msvc/shared/accesskit.lib",
            else => return,
        },
        .macos => switch (target.cpu.arch) {
            .x86_64 => "lib/macos/x86_64/static/libaccesskit.a",
            .aarch64 => "lib/macos/arm64/static/libaccesskit.a",
            else => return,
        },
        else => return,
    };
    mod.addObjectFile(if (target.os.tag == .linux) withoutDebugInfo(b, accesskit.path(library)) else accesskit.path(library));
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

/// A copy of the static library `archive` without its DWARF. AccessKit's is Rust's, whose references
/// between units Zig 0.16 can't follow: linked in, it stops every stack trace of the binary
/// resolving a single frame. Without it, only AccessKit's own frames go unnamed.
// ponytail: drop once Zig's DWARF reader follows DW_FORM_ref_addr into other units.
fn withoutDebugInfo(b: *std.Build, archive: std.Build.LazyPath) std.Build.LazyPath {
    const tool = b.addExecutable(.{ .name = "strip_debug_info", .root_module = b.createModule(.{
        .root_source_file = b.path("build/strip_debug_info.zig"),
        .target = b.graph.host,
    }) });
    const run = b.addRunArtifact(tool);
    run.addFileArg(archive);
    return run.addOutputFileArg("libaccesskit.a");
}

/// `zig build docs`: Zig's HTML API docs for `mod` in zig-out/docs, which
/// .github/workflows/docs.yml publishes to GitHub Pages.
fn addDocs(b: *std.Build, mod: *std.Build.Module, name: []const u8) void {
    const docs = b.addObject(.{ .name = name, .root_module = mod });
    const install = b.addInstallDirectory(.{ .source_dir = docs.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "docs" });
    b.step("docs", "Build the API docs into zig-out/docs").dependOn(&install.step);
}
