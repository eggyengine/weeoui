const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("weeoui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    b.step("test", "Check Weeoui module").dependOn(&tests.step);
}
