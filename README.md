# weeoui

weeoui is a UI library used in the eggy engine project. 

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

exe.root_module.addImport("weeoui", ui.module("weeoui"));
exe.root_module.addImport("weeoui_sdl3", ui.module("weeoui_sdl3"));
exe.root_module.addImport("weeoui_vitellus", ui.module("weeoui_vitellus"));
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

weeoui is immediate mode: each frame you call widgets from your own state, and they return what the user did. with both backends enabled (`.sdl3 = true, .vitellus = true`), `weeoui_sdl3.run` opens the window and handles the GPU, input, HiDPI, system light/dark theme and emoji for you:

```zig
const std = @import("std");
const ui = @import("weeoui");
const weeoui_sdl3 = @import("weeoui_sdl3");

pub fn main() !void {
    var count: u32 = 0;
    try weeoui_sdl3.run(std.heap.smp_allocator, .{ .title = "Counter" }, &count, frame);
}

fn frame(count: *u32, ctx: *ui.Context) !void {
    ctx.begin(.card);
    ctx.label("Count: {d}", .{count.*});
    if (ctx.button("Increment")) count.* += 1;
    ctx.end();
}
```

already own a window or device? `weeoui_vitellus.Painter` takes any `vitellus.Window` and draws a frame with `painter.paint(extent, &ctx.font, try ctx.render(), viewport, ctx.theme.background)`; `weeoui_vitellus.Renderer` is the lower-level piece that records into your own render pass (`upload` before it, `draw` inside it).

screen readers work out of the box: `ctx` publishes its widget tree through [AccessKit](https://accesskit.dev) every frame, `weeoui_sdl3.handleEvent` attaches it to your window on the first event, and a screen reader "click" makes `ctx.button` return true like a mouse click. set `ctx.name` to change the window name announced. other windowing backends call `ctx.attachAccessibility(...)` once. on windows, install `ui.namedLazyPath("accesskit_dll")` next to your executable.

the runnable version is [`examples/counter.zig`](examples/counter.zig):
```bash
zig build counter -Dsdl3 -Dvitellus
```
