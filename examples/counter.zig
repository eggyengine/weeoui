//! Standalone counter: `weeoui_sdl3.run` opens the window, sets up Vitellus and feeds input.
//! Run with `zig build counter -Dsdl3 -Dvitellus` (add `-Dtarget=aarch64-linux-android` for an APK).
const std = @import("std");
const ui = @import("weeoui");
const weeoui_sdl3 = @import("weeoui_sdl3");

pub fn main(init: std.process.Init) !void {
    try start(init.gpa, init.io);
}

fn start(gpa: std.mem.Allocator, io: std.Io) !void {
    var count: u32 = 0;
    try weeoui_sdl3.run(gpa, io, .{ .title = "weeoui counter", .width = 480, .height = 320 }, &count, frame);
}

pub const std_options = weeoui_sdl3.std_options;

comptime {
    weeoui_sdl3.exportAndroidMain(start);
}

/// Called every frame: describe the UI from your state, read back what the user did.
fn frame(count: *u32, ctx: *ui.Context) !void {
    ctx.begin(.card);
    ctx.label("Count: {d} 🥚", .{count.*});
    if (ctx.button("Increment")) count.* += 1;
    ctx.end();
}
