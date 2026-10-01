---
sidebar_position: 1
title: Immediate mode in depth
---

# Immediate mode in depth

## A frame

Every frame goes through the same steps. `weeoui_sdl3.run` performs them for you:

1. **`ctx.handle(event)`** for every input event since the last frame.
2. **`ctx.newFrame(viewport)`** resets the frame arena and opens the root column.
3. **Your widget calls**, which build this frame's element tree.
4. **`ctx.render()`** lays out and paints the tree. It returns the vertices to draw, or the first error any widget hit.

The vertices returned by `render` stay valid until the next `render`.

## Hit testing uses the previous frame

A widget's return value has to be known while you are still building the frame, before that frame has been laid out. To make this possible, Weeoui hit-tests against the layout from the previous frame. This is invisible in practice. It does mean a widget that appears for the first time can't be clicked until the frame after it is first drawn.

## Ids

Each widget is named by its label combined with the path of containers that are open around it. Use the `##` suffix to tell apart widgets that share a visible label (see [the guide](../guide/first-app.md#4-give-repeated-widgets-unique-names)). The same ids drive keyboard focus and the screen reader tree, so they need to stay the same from one frame to the next. Don't build labels from values that change every frame.

## Focus and keyboard

- Tab and Shift+Tab move through focusable widgets in the order they were declared.
- Enter and Space activate the focused widget. Escape closes popups and dialogs.
- The focus ring only appears after keyboard navigation, the same way `:focus-visible` works in browsers.
- `ctx.wants_text` is true while a text field has focus. Backends use it to turn on text input and the on-screen keyboard.

## The builder escape hatch

Only the common components have `Context` helpers. To use any other component, build it from `ui.widgets` with the frame builder, add it with `ctx.element`, and check for clicks with `ctx.idFor` and `ctx.activated`:

```zig
ctx.begin(.card);
ctx.heading(4, "Eggs this week");
ctx.element(try ctx.builder().chart(&.{ 5, 6, 3, 7, 4, 6, 5 }));
ctx.end();
```

Anything allocated through `ctx.builder()` lives until the end of the frame.

## Debugging

- Set `ctx.debug_hitboxes = true` to outline every clickable region in red.
- `ui.devtools` provides Chrome-style DevTools panels. They inspect and edit the live element tree.
