# weeoui

_weeoui_ (meaning small user interface, yes yes, or ykw depending on your mindset) is a fast UI library written in Zig and used in the [eggy](https://github.com/eggyengine/eggy) engine project.

![weeoui component gallery. run with `zig build gallery`](docs/image.png)

<sub>run with `zig build gallery`, or look at the demo below</sub>

guides and API reference: https://eggyengine.github.io/weeoui/

## add to project
requires zig `0.17.0`

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

embedding weeoui in your own engine instead? enable the backends you want on the dependency (`.sdl3 = true`, `.vitellus = true`) and import the modules; see [getting started](https://eggyengine.github.io/weeoui/getting-started) for building the renderer against your own copy of vitellus.

## quick start

weeoui is immediate mode: each frame you call widgets from your own state, and they return what the user did.

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

run it with `zig build counter`, or look at the source [`examples/counter.zig`](examples/counter.zig):
```bash
zig build counter
```
