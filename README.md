# weeoui

_weeoui_ (meaning small user interface, yes yes, or ykw depending on your mindset) is a fast UI library written in Zig and used in the [eggy](https://github.com/eggyengine/eggy) engine project.

what you get:

- **a fucktonne of components**: buttons, inputs, selects, menus and menubars, dialogs, sheets, calendars, tables, toasts, the lot, in a warm light/dark "yolk" theme that can follow the system
- **proper layouts**: flex rows and columns with justify, wrap and grow, grids, right-to-left, and scroll areas
- **editor tooling**: dockable panels you can split, tab, float, or pop out into their own OS windows, custom title bars whose buttons follow your desktop's layout, and Chrome-style DevTools that can inspect and edit the UI live
- **accessibility first**: every control reaches screen readers through AccessKit, with keyboard focus, visible focus rings, and cursors that match what's under the pointer

guides and API reference: https://eggyengine.github.io/weeoui/

## add to project
requires zig `0.16.0`

to use this with the zig build system, import as so:
```bash
zig fetch --save git+https://github.com/eggyengine/weeoui
```

and then in `build.zig`:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    @import("weeoui").addApp(b, .{ .name = "counter", .root_source_file = b.path("src/main.zig") });
}
```

that builds your app for wherever `-Dtarget` points (desktop, `wasm32-emscripten` for the browser, `aarch64-linux-android.35` for a phone), and sets up logging, panics and each platform's entry point for you. `zig build run` starts it.

embedding weeoui in your own engine instead? enable the backends you want on the dependency (`.sdl3 = true`, `.vitellus = true`) and import the modules; see [getting started](https://eggyengine.github.io/weeoui/getting-started) for building the renderer against your own copy of vitellus.

## quick start

weeoui is immediate mode: each frame you call widgets from your own state, and they return what the user did. `weeoui_sdl3.run` opens the window and handles the GPU, mouse, touch, keyboard, clipboard, displays and more for you, on the desktop, android and the web.

```zig
const std = @import("std");
const ui = @import("weeoui");
const weeoui_sdl3 = @import("weeoui_sdl3");

pub fn main(init: std.process.Init) !void {
    var count: u32 = 0;
    try weeoui_sdl3.run(init.gpa, init.io, .{ .title = "Counter" }, &count, frame);
}

fn frame(count: *u32, ctx: *ui.Context) !void {
    ctx.begin(.card);
    ctx.label("Count: {d}", .{count.*});
    if (ctx.button("Increment")) count.* += 1;
    ctx.end();
}
```

the runnable version is [`examples/counter.zig`](examples/counter.zig):
```bash
zig build counter
```
