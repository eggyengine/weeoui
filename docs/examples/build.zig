//! Builds the guide's full program from src/ (written there by check.sh).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ui = b.dependency("weeoui", .{ .target = target, .optimize = optimize, .sdl3 = true, .vitellus = true });
    // `-Dsdl3`/`-Dvitellus` pull lazy dependencies: on a fresh checkout the module appears only after
    // Zig fetches them and reruns this build, so return early instead of panicking.
    const weeoui_sdl3 = ui.builder.modules.get("weeoui_sdl3") orelse return;
    const exe = b.addExecutable(.{
        .name = "example",
        // Zig 0.16's self-hosted linker rejects R_X86_64_PC64 in glibc/GCC .sframe.
        .use_llvm = target.result.os.tag == .linux,
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }),
    });
    exe.root_module.addImport("weeoui", ui.module("weeoui"));
    exe.root_module.addImport("weeoui_sdl3", weeoui_sdl3);
    b.installArtifact(exe);
}
