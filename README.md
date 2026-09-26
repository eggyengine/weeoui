# weeoui

weeoui is a UI library used in the eggy engine project.

Build a frame-local tree with `Layout.Builder.node`, call `root.layout(viewport, font)`, then `root.draw(canvas)`. Rows and columns support padding, gaps, fixed or weighted sizes, constraints, and scrollable overflow. Give interactive elements stable IDs and use `root.find(id)` or `root.hit(id, x, y)` after layout. Keep `Layout.ScrollState` in application state between frames; the elements themselves can be rebuilt each frame. See `src/ui_demo.zig` in Eggy for a complete example.

Layout accepts any viewport rectangle, including one assigned to a future docked pane. Dock placement, split persistence, and drag-and-drop belong to the application workspace rather than this frame-local tree.
