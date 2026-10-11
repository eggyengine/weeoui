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
const ui = b.dependency("weeoui", .{
    .target = target,
    .optimize = optimize,
    .sdl3 = true, // fetches SDL3, provides `weeoui_sdl3` (input)
    .vitellus = true, // fetches Vitellus, provides `weeoui_vitellus` (rendering)
});

// The backends are lazy dependencies: on a fresh checkout they appear only after
// Zig fetches them and reruns build.zig, so return early until then.
const weeoui_sdl3 = ui.builder.modules.get("weeoui_sdl3") orelse return;
const weeoui_vitellus = ui.builder.modules.get("weeoui_vitellus") orelse return;

exe.root_module.addImport("weeoui", ui.module("weeoui"));
exe.root_module.addImport("weeoui_sdl3", weeoui_sdl3);
exe.root_module.addImport("weeoui_vitellus", weeoui_vitellus);
```

if your project already depends on vitellus, build `src/vitellus.zig` against your own copy instead of setting `.vitellus = true`, otherwise you get two vitellus modules:
```zig
exe.root_module.addImport("weeoui_vitellus", b.createModule(.{
    .root_source_file = ui.path("src/vitellus.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "weeoui", .module = ui.module("weeoui") },
        .{ .name = "vitellus", .module = vit.module("vitellus") },
    },
}));
```

## quick start

weeoui is immediate mode: each frame you call widgets from your own state, and they return what the user did. with both backends enabled (`.sdl3 = true, .vitellus = true`), `weeoui_sdl3.run` opens the window and handles the GPU, input, displays and more for you. 

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
zig build counter -Dsdl3 -Dvitellus
```
