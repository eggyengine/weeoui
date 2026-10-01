---
sidebar_position: 4
title: Docking and DevTools
---

# Docking and DevTools

`ui.dock` and `ui.devtools` are the editor-tooling layer. They give you the dockable panels and Chrome-style inspector of a game-engine editor.

:::note Lower-level API
Both of these work on the element tree from `ui.Layout` (built with a `Layout.Builder` and drawn with a `ui.Canvas`). They don't plug into `Context`. Your app builds the tree, draws it, and passes input to them itself. The sections below describe that contract.
:::

## Docking

### What it can do

- **Splits and tab stacks.** Panels sit in a tree of horizontal and vertical splits that the user can resize. Each leaf is a stack of tabs.
- **Drag to rearrange.** Dragging a tab shows a compass over the stack under the pointer. Dropping on the centre adds it as a tab, and dropping on an edge splits that side.
- **Floating windows.** A panel can float inside the main window, with its own title bar buttons to close, minimise (fold to the tab bar) and maximise (fill the window).
- **Pop out to OS windows.** A panel can move into its own operating-system window and later dock back. If your app can't open extra windows, set `os_windows = false` and pop-outs float instead.
- **Tab menu.** Every stack has a menu with pop out, float and dock back.
- **Native-looking buttons.** Floating windows order and style their buttons from `buttons`. Use `weeoui_sdl3.buttonLayout` to read the desktop's layout.
- **Accessibility.** Splitters are announced as sliders, and tabs and buttons are focusable.

| Limit | Value |
| --- | --- |
| Panel ids | Nonzero and below `dock.max_panel` (`0x10000`) |
| Nodes (splits and stacks) | 64 |
| Tabs per stack | 16 |
| Floating windows | `dock.max_floating` (8) |
| OS windows | `dock.max_windows` (8) |

### Setting up the dock

Store one `DockSpace` in your app state and number your panels:

```zig
const Panel = enum(u32) { scene = 1, inspector, console, assets };

var dock = ui.dock.DockSpace.init();

// Build the starting arrangement once:
try dock.add(@intFromEnum(Panel.scene), null, .center);
try dock.add(@intFromEnum(Panel.inspector), @intFromEnum(Panel.scene), .right);
try dock.add(@intFromEnum(Panel.console), @intFromEnum(Panel.scene), .bottom);
try dock.add(@intFromEnum(Panel.assets), @intFromEnum(Panel.console), .center); // a tab beside console
```

`add(panel, near, side)` puts `panel` on `side` of the stack that holds `near`. When `near` is `null`, it uses the root. Other operations you can call from code:

- `remove(panel)`
- `move(panel, node, side)`
- `float(panel, rect)`
- `detach(panel)`, which moves the panel into an OS window
- `redock(host)`
- `nodeOf(panel)` and `isVisible(panel)`

### Building the dock each frame

`build` takes a provider: any value that has `title` and `content` methods.

```zig
const Panels = struct {
    app: *App,

    pub fn title(_: Panels, panel: u32) []const u8 {
        return switch (@as(Panel, @enumFromInt(panel))) {
            .scene => "Scene",
            .inspector => "Inspector",
            .console => "Console",
            .assets => "Assets",
        };
    }

    pub fn content(self: Panels, b: ui.Layout.Builder, panel: u32, rect: ui.Rect) !*ui.Layout.Element {
        return switch (@as(Panel, @enumFromInt(panel))) {
            .scene => b.node(0, .{ .width = rect.w, .height = rect.h }, .none, &.{}), // your viewport goes here
            else => b.column(&.{try b.label("...")}),
        };
    }
};

const root = try dock.build(b, .main, viewport, Panels{ .app = app });
root.layout(viewport, &font);
try root.draw(&canvas);
```

`build(b, .main, ...)` builds the main window, including its floating windows. For each popped-out panel, check `dock.windows[i]`. When it is set, open an OS window of the given `size` (you can keep your own handle in `handle`) and build that window with `.{ .window = i }`. When the user closes such a window, call `dock.redock(.{ .window = i })`.

### Routing input

Every id the dock creates lies at or above `ui.dock.first_id`. Your hit testing gives you the id under the pointer, and you pass events on like this:

| Event | Call |
| --- | --- |
| Pointer pressed on an id | `dock.press(id, x, y)`. Returns `true` if the dock handled it. |
| Pointer moved while `dock.dragging()` | `dock.dragTo(x, y)` |
| Pointer released while dragging | `dock.release(x, y)` |
| Enter or Space on a focused id | `dock.activate(id)`. Returns `true` if handled. |
| Escape | `dock.dismissMenu()`. Returns `true` if a menu was open. |
| Choosing the pointer shape | Use `dock.cursor()` when it isn't `null`, for example during splitter drags. |

## DevTools

DevTools inspects any element tree. It has three tools, each shown in a panel you choose, typically a dock panel:

- **Elements**: the whole tree, a box model, and editable style properties.
- **Performance**: frame times and vertex counts.
- **Console**: your app's log output.

### Initialising

```zig
var devtools: ui.devtools.Devtools = .{};
defer devtools.deinit(gpa);
```

To send `std.log` output to the Console, install the log function and point it at your `Devtools`:

```zig
pub const std_options: std.Options = .{ .logFn = ui.devtools.logFn };

// once devtools exists:
ui.devtools.console = &devtools;
```

`logFn` still prints to stderr as usual. It also copies info, warning and error messages into the Console. You can write to the Console directly with `devtools.log(.warn, "fmt", .{...})`.

### Each frame

The page is rebuilt every frame, so property edits made in DevTools are stored as overrides and reapplied every frame. Call these in this order:

```zig
// 1. Build and lay out your page, then reapply the user's edits.
const page = try buildPage(b);
page.layout(viewport, &font);
if (devtools.apply(page)) page.layout(viewport, &font);

// 2. Inspect it. `page` has to stay alive until `highlight`.
try devtools.prepare(gpa, page);

// 3. Build each visible tool into the area its panel occupies.
const elements = try devtools.view(b, gpa, .elements, panel_rect);
elements.layout(panel_rect, &font);

// 4. Draw the page and the panels, then the inspector overlay last.
try root.draw(&canvas);
try devtools.highlight(&canvas, gpa);

// 5. Feed the Performance tool.
devtools.recordFrame(frame_ms);
devtools.vertices = canvas.len;
```

### Routing input

DevTools ids lie at or above `ui.devtools.first_id`.

| Event | Call |
| --- | --- |
| Click or keyboard activation on an id | `devtools.activate(gpa, id)` |
| Pointer motion over the page | `devtools.pointerMove(x, y)` (it highlights the element under the pointer while `inspecting`) |
| Pointer pressed on the page | `devtools.pointerDown(x, y)`. Returns `true` when it picked an element. |
| Typing into a property field (`isField(id)`) | `insertText(id, text)`, `editKey(gpa, id, key, extend, word)`, then `commit(gpa, id)` on Enter |
| Focus leaving a field | `devtools.blur(gpa)` |
| Escape | `devtools.cancel()`, then turn off `inspecting` |
| Arrow keys in the tree | `devtools.treeKey(gpa, id, key)` returns the row to focus next |
| Tab order | Skip ids for which `devtools.skipInTabOrder(id)` returns `true` |

Set `devtools.inspecting = true` to enter pick mode. In pick mode, hovering highlights elements and a click selects one. Show a crosshair cursor while it's on.

## Title bars

`ui.titlebar.bar` draws a custom title bar with close, minimise and maximise buttons laid out like the desktop's. With SDL3:

- `weeoui_sdl3.useCustomFrame` removes the system frame.
- `weeoui_sdl3.windowAction` carries out a button press.
- `weeoui_sdl3.buttonLayout` reads the desktop's button order.
