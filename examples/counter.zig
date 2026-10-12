//! The README's counter. `zig build counter` runs it; add `-Dtarget=wasm32-emscripten` for the
//! browser or `-Dtarget=aarch64-linux-android.35` for a phone. `addApp` does the rest.
const std = @import("std");
const ui = @import("weeoui");
const weeoui_sdl3 = @import("weeoui_sdl3");

pub fn main(init: std.process.Init) !void {
    var count: u32 = 0;
    try weeoui_sdl3.run(init.gpa, init.io, .{ .title = "weeoui counter", .width = 480, .height = 320 }, &count, frame);
}

/// Called every frame: describe the UI from your state, read back what the user did.
fn frame(count: *u32, ctx: *ui.Context) !void {
    ctx.begin(.card);
    ctx.label("Count: {d} 🥚", .{count.*});
    if (ctx.button("Increment")) count.* += 1;
    ctx.end();
}
