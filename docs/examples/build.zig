//! Builds the guide's full program from src/ (written there by check.sh), the way any Weeoui app
//! is built: one `addApp` call.
const std = @import("std");

pub fn build(b: *std.Build) void {
    @import("weeoui").addApp(b, .{ .name = "example", .root_source_file = b.path("src/main.zig") });
}
