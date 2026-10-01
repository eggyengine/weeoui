---
sidebar_position: 2
title: Theming and images
---

# Theming and images

## Themes

`ctx.theme` is a plain `ui.Theme` struct of colours and sizes. `.{}` is the light yolk theme and `ui.Theme.dark` is the dark one. `weeoui_sdl3.systemTheme()` returns whichever one matches the operating system.

Change the theme at any point during a frame:

```zig
fn frame(app: *App, ctx: *ui.Context) !void {
    ctx.theme = if (app.dark) ui.Theme.dark else .{};
    ctx.theme.primary = ui.rgb(0x4F, 0x9D, 0xDE);
    ctx.theme.ring = ctx.theme.primary;
    // ...
}
```

If you set `RunOptions.theme` to `null`, `run` follows the operating system's light or dark setting while the app is running.

`ui.parseHex` and `ui.formatHex` convert to and from `#rrggbb` strings. For a full colour editor, keep a `ui.ColorEditor` in your state and pass it to `ctx.colorPicker`:

```zig
// state
accent: ui.ColorEditor = .init((ui.Theme{}).primary, 1),

// frame
_ = ctx.colorPicker("Accent", &app.accent);
ctx.theme.primary = app.accent.rgb();
```

## Button and badge variants

`buttonVariant` takes `.default`, `.secondary`, `.outline`, `.ghost`, `.destructive` or `.link`. `badge` takes `.default`, `.secondary`, `.destructive` or `.outline`.

## Images

`ui.Image.load` decodes PNG, JPEG, BMP, TGA, PSD, HDR, PNM and GIF files into the font's colour atlas. Animated GIFs play based on `ctx.time_ms`.

```zig
// once, after the context exists:
var egg = try ui.Image.load(gpa, &ctx.font, @embedFile("egg.gif"));
defer egg.deinit(gpa);

// every frame:
ctx.image(&egg, 128); // 128 wide, keeping the aspect ratio
```

Images share the atlas with colour emoji, so a few limits apply:

- An image is at most 512 px on a side.
- All frames of one image together take at most a quarter of the atlas.

Larger images are scaled down when they are loaded. With `run`, the simplest place to load images is lazily on the first frame (see `examples/demo.zig`).
