---
sidebar_position: 3
title: Your own loop and renderer
---

# Your own loop and renderer

`weeoui_sdl3.run` is the quickest way to get going. An engine usually owns the window, the frame loop and the GPU itself, so Weeoui splits into three layers you can wire up separately:

- **`weeoui`** turns input events into vertices. It knows nothing about windows or GPUs.
- **`weeoui_sdl3`** translates SDL events and attaches the screen reader bridge.
- **`weeoui_vitellus`** draws the vertices with Vitellus.

## Driving the context

```zig
var ctx = try ui.Context.init(gpa);
defer ctx.deinit();
ctx.name = "My editor"; // the window name that screen readers announce

while (running) {
    while (sdl3.events.poll()) |event| {
        // ... your own handling ...
        weeoui_sdl3.handleEvent(&ctx, event);
    }

    ctx.newFrame(.{ .x = 0, .y = 0, .w = width_points, .h = height_points });
    buildUi(&ctx);
    const vertices = try ctx.render();

    // ... draw `vertices` (see below) ...

    weeoui_sdl3.setCursor(ctx.cursor);
    if (ctx.wants_text) {
        // turn on SDL text input, which also shows the on-screen keyboard
    }
}
```

The viewport is in UI units, which are normally window points. On HiDPI displays, set the physical-pixel ratio so that text is rasterised sharply:

```zig
ctx.pixel_scale = .{ pixel_width / viewport.w, pixel_height / viewport.h };
ctx.font.dpi_scale = ctx.pixel_scale[0];
```

The first call to `handleEvent` for a window also connects AccessKit, so screen readers work without any extra code. To manage AccessKit yourself, call `ctx.attachAccessibility(try weeoui_sdl3.accessKitWindow(window))` instead.

## Rendering with `Painter`

`Painter` owns the Vitellus device, the swapchain and the renderer for one window:

```zig
var painter = try weeoui_vitellus.Painter.init(gpa, try window.asWindow(), pixel_extent, &ctx.font);
defer painter.deinit();
ctx.srgb_target = painter.srgb();

// every frame, after ctx.render():
try painter.paint(pixel_extent, &ctx.font, vertices, viewport, ctx.theme.background);
```

`paint` resizes the swapchain when `pixel_extent` changes. It keeps `weeoui_vitellus.frames_in_flight` (2) frames in flight, so the CPU builds the next frame while the GPU draws the last one.

## Rendering into your own pass with `Renderer`

If you already have a Vitellus device and frame loop, which is how Eggy uses Weeoui, use `Renderer` directly and record the UI into your own command buffer:

```zig
var renderer = try weeoui_vitellus.Renderer.init(device, color_format, &ctx.font);
defer renderer.deinit();
ctx.srgb_target = weeoui_vitellus.isSrgb(color_format);

// each frame, outside a render pass:
try renderer.upload(cmd, &ctx.font, vertices, viewport);

// inside the render pass that targets the swapchain image:
renderer.draw(cmd, extent, 0, vertices.len);
```

`Renderer` cycles through `weeoui_vitellus.frames_in_flight` (2) vertex buffers. Before each `upload`, wait for the GPU to finish the frame that used the same buffer two uploads ago.

`weeoui_vitellus.colorFormat` converts a `SwapchainFormat` into the `vit.Format` that `Renderer.init` expects.
