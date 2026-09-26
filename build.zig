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
    mod.addImport("freetype", freetype.module("freetype"));
    mod.linkLibrary(freetype.artifact("freetype"));
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = mod, .use_llvm = true }));
    b.step("test", "Check Weeoui module").dependOn(&tests.step);
}
