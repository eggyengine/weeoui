# weeoui

weeoui is a UI library used in the eggy engine project. Its default visual
tokens use the neutral shadcn/ui light palette, with a dark preset; it does not
port shadcn components or require CSS. The defaults follow shadcn/ui's
[semantic theming](https://ui.shadcn.com/docs/theming) and
[open-code, composable approach](https://ui.shadcn.com/docs): start with a
working look, then replace any part of it.

```zig
const b = weeoui.Layout.Builder{ .allocator = arena.allocator() };
const root = try b.card(&.{
    try b.text("Preferences"),
    try b.button(1, "Save"),
});
try root.render(viewport, &canvas);
if (mouse_pressed and root.hit(1, mouse_x, mouse_y)) save();
```

Use `b.row`, `b.column`, `b.text`, `b.card`, and `b.button` for defaults.
Interactive IDs belong to the application; it owns input and state. Call
`layout` and `draw` separately when you need bounds before painting. For full
control use `b.node(id, style, paint, children)` with explicit `Style` and
`Paint`, including `.custom` callbacks for your own appearance. Override any
color, radius, or text size via `canvas.theme = .{ .primary = ..., ... }`, or
set `canvas.theme = weeoui.Theme.dark`. Supply your own TTF/OTF bytes to
`Font.init` for typography and use `Canvas` primitives in custom painters.
When rendering to an sRGB framebuffer outside Eggy, set
`canvas.srgb_target = true` so colors are encoded only once.
When embedding in Eggy, set `Graphics.theme` so the background clear and
components use the same colors.

Build a frame-local tree with `Layout.Builder.node`, call `root.layout(viewport, font)`, then `root.draw(canvas)`. Rows and columns support padding, gaps, fixed or weighted sizes, constraints, and scrollable overflow. Give interactive elements stable IDs and use `root.find(id)` or `root.hit(id, x, y)` after layout. Keep `Layout.ScrollState` in application state between frames; the elements themselves can be rebuilt each frame. See `src/ui_demo.zig` in Eggy for a complete example.

Layout accepts any viewport rectangle, including one assigned to a future docked pane. Dock placement, split persistence, and drag-and-drop belong to the application workspace rather than this frame-local tree.
