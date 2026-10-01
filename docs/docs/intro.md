---
slug: /
sidebar_position: 1
title: Introduction
---

# Weeoui

Weeoui is an immediate-mode UI library for Zig. It is used by the [Eggy](https://github.com/eggyengine/eggy) engine.

You describe the UI every frame from your own state, and each widget call returns what the user did with it. Weeoui keeps no widget objects for you to create, update or destroy:

```zig
fn frame(count: *u32, ctx: *ui.Context) !void {
    ctx.begin(.card);
    ctx.label("Count: {d}", .{count.*});
    if (ctx.button("Increment")) count.* += 1;
    ctx.end();
}
```

## Features

- **Components**: buttons, inputs, selects, tabs, sliders, dialogs, tables, toasts, charts, images and a colour picker. Everything uses the warm "yolk" theme, in light or dark.
- **Layout**: flex rows and columns, grids, wrapping, right-to-left text and scroll areas.
- **Editor tooling**: dockable panels, custom title bars, and DevTools that inspect the UI while it runs.
- **Accessibility**: every control is exposed to screen readers through AccessKit. Keyboard focus, focus rings and pointer cursors work out of the box.

## Modules

| Module | Build flag | Purpose |
| --- | --- | --- |
| `weeoui` | always | `Context`, widgets, layout, fonts and images. Has no platform dependencies. |
| `weeoui_sdl3` | `.sdl3 = true` | SDL3 input, windowing, and `run`, which handles the whole frame loop for you. |
| `weeoui_vitellus` | `.vitellus = true` | GPU rendering through [Vitellus](https://github.com/eggyengine/vitellus). |

## Where to go next

- [Getting started](./getting-started.md): add Weeoui and run the counter.
- [Build a small app](./guide/first-app.md): state, forms, lists and dialogs.
- [API reference](pathname:///api/): the Zig-generated docs for every public declaration.
