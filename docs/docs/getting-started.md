---
sidebar_position: 2
title: Getting started
---

# Getting started

Weeoui requires Zig `0.16.0`.

## Add the dependency

```bash
zig fetch --save git+https://github.com/eggyengine/weeoui
```

In `build.zig`, enable both backends to get a ready-made window and renderer:

```zig
const ui = b.dependency("weeoui", .{
    .target = target,
    .optimize = optimize,
    .sdl3 = true, // provides weeoui_sdl3 (window and input)
    .vitellus = true, // provides weeoui_vitellus (rendering)
});

exe.root_module.addImport("weeoui", ui.module("weeoui"));
exe.root_module.addImport("weeoui_sdl3", ui.module("weeoui_sdl3"));
```

### If you already depend on Vitellus

`.vitellus = true` fetches Weeoui's own copy of Vitellus. If your project already has Vitellus, build the renderer against your copy instead, so that you don't end up with two `vitellus` modules:

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

## A counter

```zig title="src/main.zig"
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

`weeoui_sdl3.run` opens the window, sets up the GPU, and feeds input, HiDPI scaling and screen reader events into the context. Then it calls `frame(state, ctx)` once per frame until the window closes.

`RunOptions` accepts `title`, `width`, `height`, `theme` and `emoji`. Leave `theme` as `null` to follow the system's light or dark setting. Set `emoji` to `false` to skip loading the system emoji font.

## Examples in the repository

```bash
zig build counter -Dsdl3 -Dvitellus  # the counter above
zig build demo -Dsdl3 -Dvitellus     # every component
```

You can cross-compile for Windows with `-Dtarget=x86_64-windows`, or for Android with `-Dtarget=aarch64-linux-android`.
