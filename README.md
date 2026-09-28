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

weeoui is immediate mode: each frame you call widgets from your own state, and they return what the user did. the classic counter, drawn with an existing vitellus `device`, `queue` and swapchain:

```zig
const ui = @import("weeoui");
const weeoui_sdl3 = @import("weeoui_sdl3");
const weeoui_vitellus = @import("weeoui_vitellus");

var ctx = try ui.Context.init(gpa);
defer ctx.deinit();
ctx.srgb_target = weeoui_vitellus.isSrgb(color_format);
var renderer = try weeoui_vitellus.Renderer.init(device, color_format, &ctx.font);
defer renderer.deinit();
var count: u32 = 0;

while (running) {
    while (sdl3.events.poll()) |event| weeoui_sdl3.handleEvent(&ctx, event);

    ctx.newFrame(viewport); // window size in logical units, same as mouse coordinates
    ctx.begin(.card);
    ctx.label("Count: {d}", .{count});
    if (ctx.button("Increment")) count += 1;
    ctx.end();
    const vertices = try ctx.render();

    // record into your command buffer:
    try renderer.upload(cmd, vertices, viewport); // before the render pass
    try cmd.beginRenderPass(.{ ... });
    renderer.draw(cmd, extent, 0, vertices.len);
    cmd.endRenderPass();
}
```

screen readers work out of the box: `ctx` publishes its widget tree through [AccessKit](https://accesskit.dev) every frame, `weeoui_sdl3.handleEvent` attaches it to your window on the first event, and a screen reader "click" makes `ctx.button` return true like a mouse click. set `ctx.name` to change the window name announced. other windowing backends call `ctx.attachAccessibility(...)` once. on windows, install `ui.namedLazyPath("accesskit_dll")` next to your executable.

a complete, runnable version (window, swapchain and all) is in [`examples/counter.zig`](examples/counter.zig):
```bash
zig build counter -Dsdl3 -Dvitellus
```
