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

## build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    @import("weeoui").addApp(b, .{ .name = "counter", .root_source_file = b.path("src/main.zig") });
}
```

`addApp` builds your app for wherever `-Dtarget` points: a desktop program, a web page or an Android APK. It also sets up logging, the panic handler and each platform's entry point, so your code needs none of that.

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

`weeoui_sdl3.run` opens the window, sets up the GPU, and feeds mouse, touch, keyboard, clipboard, HiDPI scaling and screen reader events into the context. Then it calls `frame(state, ctx)` once per frame until the window closes.

`RunOptions` accepts `title`, `width`, `height`, `theme` and `emoji`. Leave `theme` as `null` to follow the system's light or dark setting. Set `emoji` to `false` to skip the system's emoji.

## Run it

```bash
zig build run                                     # on this computer
zig build run -Dtarget=wasm32-emscripten          # in the browser (WebGPU)
zig build run -Dtarget=aarch64-linux-android.35   # on a phone, through adb
```

The browser build needs [emsdk](./guide/web.md#what-you-need), and Android needs `ANDROID_HOME`. Cross-compile for Windows with `-Dtarget=x86_64-windows`.

### Using Weeoui inside your own engine

`addApp` is for apps that `weeoui_sdl3.run` drives. An engine that owns its window and renderer imports the modules instead. Enable the backends it wants on the dependency (`.sdl3 = true`, `.vitellus = true`) and see [Your own loop and renderer](./concepts/custom-loop.md). If the engine already depends on Vitellus, build the renderer against its copy so there's only one `vitellus` module:

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

## Examples in the repository

```bash
zig build counter   # a small app (Coop)
zig build demo      # every component through `Context`
zig build gallery   # the full gallery: docking, DevTools and every widget
```

Add `-Dtarget=wasm32-emscripten` or `-Dtarget=aarch64-linux-android.35` to any of them, or [open the live demo](pathname:///demo/).
