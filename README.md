# weeoui

weeoui is a UI library used in the eggy engine project. Its default visual
tokens use the neutral shadcn/ui light palette, with a dark preset. Its native
controls do not copy React implementations or require CSS. The defaults follow shadcn/ui's
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
For icons, `b.icon(.search)` uses an atlas-backed Lucide glyph, and
`canvas.icon(rect, .check, color)` lets custom painters choose its color and
bounds. The fourteen bundled SVGs (including search, chevrons, command,
keyboard, image, clock, and calendar) are
pinned to Lucide revision `66d8f9fc394b8530377e5f6112f0b8908ba01280`
under `src/assets/lucide/`, alongside their license. Pre-rasterized masks
are embedded at build time; applications do not need an SVG renderer.
When rendering to an sRGB framebuffer outside Eggy, set
`canvas.srgb_target = true` so colors are encoded only once.
When embedding in Eggy, set `Graphics.theme` so the background clear and
components use the same colors.

Weeoui also provides a platform-independent semantic snapshot of a laid-out
tree. Give focusable elements stable nonzero IDs and pass the app's current
focus to `weeoui.accessibility.collect(arena.allocator(), root, focused_id)`;
the snapshot includes roles, labels, values, state, child relationships, and
clipped bounds. Duplicate IDs or unknown focus are errors. Override inferred
semantics with `element.accessibility = .{ .role = .button, .label = "Open",
.description = "Opens settings" }`; mark purely decorative nodes with
`.role = .ignored`. Hosts must connect snapshots and actions to a native
accessibility adapter: Eggy's SDL3 host uses AccessKit and routes actions back
to application-owned state. A semantic snapshot alone does not register
screen-reader support.

Set `.alignment = .start`, `.center`, or `.end` on a `Layout.Text` paint to
align its visible ink (including wrapped lines) within its bounds.
`Style.align_items` independently positions children on the cross axis; rows
use their measured widths and natural child heights rather than stretching
every child to the row height.

Additional painted controls are `b.input`, `b.textarea`, `b.radio`, `b.progress`,
`b.skeleton`, `b.spinner`, `b.avatar`, `b.tab`, `b.toggleButton`, `b.alert`,
and `b.chart`. `weeoui.widgets` composes them without hiding the element tree:

```zig
const choices = [_]weeoui.widgets.Choice{
    .{ .id = 10, .label = "General" },
    .{ .id = 11, .label = "Advanced" },
};
const tabs = try weeoui.widgets.tabs(b, &choices, selected_id, &.{
    try b.text("General settings"),
    try b.text("Advanced settings"),
});
try tabs.render(viewport, &canvas);
if (mouse_pressed and tabs.hit(11, mouse_x, mouse_y)) selected_id = 11;
```

| Native UI family | API |
| --- | --- |
| Fields, labels, input groups, OTP, selects, comboboxes | `widgets.field`, `inputGroup`, `inputOtp`, `select`, `combobox`, `command` |
| Radio/toggle/button groups, tabs, accordion, collapsible | `widgets.radioGroup`, `toggleGroup`, `buttonGroup`, `tabs`, `accordion`, `disclosure` |
| Dropdown/context menus, popovers, hover cards, tooltips | `widgets.dropdownMenu`, `contextMenu`, `popoverAt`, `hoverCardAt`, `tooltipAt` |
| Dialogs, alert dialogs, sheets, drawers, alerts, toasts | `widgets.modal`, `b.alert`, `widgets.toast` |
| Calendar, date picker, tables, sortable headers, pagination, breadcrumbs | `widgets.calendar`, `datePicker`, `table`, `dataTable`, `pagination`, `breadcrumb` |
| Carousel, scroll area, resizable panes, aspect ratio | `widgets.carousel`, `scrollArea`, `resizable`, `aspectRatio` |
| Sidebar, empty states, messages, item rows, keyboard hints, attachments, charts | `widgets.sidebar`, `empty`, `message`, `item`, `kbd`, `attachment`, `b.chart` |

Pass an anchor element to `dropdownMenu`/`popoverAt`/`tooltipAt`, or a
pointer position to `contextMenu`; pass `null` when the context menu is
closed. Overlays flip upward when needed, stay within the viewport, do not
increase page height, and paint after base UI in `z_index` order. If a host
draws other content between UI layers, call `root.drawWithoutOverlays(canvas)`,
draw that content, then `root.drawOverlays(canvas)`. Route hit tests in the
same order and trap focus within a modal; Eggy's demo implements both.
Open state and trigger dismissal belong to the application. `table` handles
visible rows; `dataTableWithOptions(..., .{ .lines = true })` adds visible
row separators, while `dataTable` retains the borderless default. Header IDs
let the app sort, filter, and page data.
`attachment` exposes a button ID for
the app's native file picker. Modal overlays take the full viewport; render
them after the underlying UI and route input to the modal instead of controls
behind it. Pass the current animation phase to `spinner`.
`calendar` and `datePicker` assign day IDs `first_id + day` (1-31), month
navigation IDs `first_id + 32/33`, and time-adjustment IDs `first_id + 34..37`.
`widgets.shiftMonth` clamps the selected day when changing months. Use
`widgets.form` for field groups and `messageScroller` for scrollable messages
with AccessKit region and live-log semantics. A message scroller opens at
the end by default; set `scroll.message_start = .start` before its first
layout to open at the top. Set `scroll.auto_scroll = true` to follow new
messages until the user scrolls up, and call `scroll.jumpToMessageEnd()`
for a "Jump to latest" button. To preserve the reading position after
prepending older rows, pass their measured height to
`scroll.preserveMessagePrepend(height)` before the next layout. Give
messages stable nonzero IDs and call
`widgets.scrollToMessage(region, id, .{ .alignment = .start, .margin = 8 })`
on a laid-out region to target one; relayout afterward to update the
painted bounds. Missing IDs return `false`.
For editable text, retain a `weeoui.TextEdit(128)` per field and pass its
`text()`, `cursor`, and `selection()` into `weeoui.Input`. Pass SDL text events
through `insert`, keyboard actions through `moveLeft`/`moveRight`/`undo`, and
IME preedit through `Input.composition`; the editor validates UTF-8, bounds,
and codepoint boundaries. `selectWord()` and `selectLine()` provide
multi-click selection without splitting UTF-8 codepoints. `Input` handles
focus, caret, selection, and composition painting. Use
`b.animatedSkeleton(width, height, phase)` and
`b.spinner(phase)` for time-driven loading feedback.
UI strings
currently render printable ASCII; non-ASCII text uses a fallback glyph until
the font atlas supports dynamic Unicode. Browser-only integrations and
app-specific data models are not bundled.

Build a frame-local tree with `Layout.Builder.node`, call `root.layout(viewport, font)`, then `root.draw(canvas)`. Rows and columns support padding, gaps, fixed or weighted sizes, constraints, and scrollable overflow. Give interactive elements stable IDs and use `root.find(id)` or `root.hit(id, x, y)` after layout. Keep `Layout.ScrollState` in application state between frames; the elements themselves can be rebuilt each frame. See `src/ui_demo.zig` in Eggy for a complete example.

Layout accepts any viewport rectangle, including one assigned to a future docked pane. Dock placement, split persistence, and drag-and-drop belong to the application workspace rather than this frame-local tree.
