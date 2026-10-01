---
sidebar_position: 1
title: Build a small app
---

# Build a small app

This guide builds **Coop**, a tracker for a flock of hens. Along the way it covers state, containers, text input, selects, per-row widgets, sliders and a confirmation dialog. The full program is shown at the end. It runs with the setup from [Getting started](../getting-started.md).

## 1. Keep state in your own types

Weeoui doesn't store your data. You keep all state in plain Zig values and pass a pointer to `run`:

```zig
const Coop = struct {
    hens: [16]Hen = undefined,
    count: usize = 0,
    new_name: ui.TextEdit(32) = .{},
    breed: usize = 0,
    feed: f32 = 50,
    confirm_clear: bool = false,
};

pub fn main(init: std.process.Init) !void {
    var coop = Coop{};
    try weeoui_sdl3.run(init.gpa, init.io, .{ .title = "Coop" }, &coop, frame);
}
```

Widgets read and write your values through pointers. `ctx.toggle("Laying", &hen.laying)` flips the bool when it is clicked. `ctx.slider("Feed", &coop.feed, 0, 150)` writes the dragged value back. Text fields edit a `ui.TextEdit(n)`, a fixed-capacity buffer that also stores the cursor, the selection and the undo history.

## 2. Lay out with containers

`ctx.begin(kind)` opens a container and `ctx.end()` closes it. Every widget call between the two goes inside it:

```zig
ctx.begin(.card);
ctx.heading(4, "Add a hen");
ctx.label("Name", .{});
_ = ctx.textInput("Name", &coop.new_name, "Henrietta");
ctx.label("Breed", .{});
_ = ctx.select("Breed", &breeds, &coop.breed);
if (ctx.button("Add")) coop.add();
ctx.end();
```

| Container | Lays out |
| --- | --- |
| `.column` | Children stacked top to bottom. The frame itself is a column. |
| `.row` | Children side by side, wrapping when they run out of room. |
| `.card` | A padded column on a card surface, capped at a readable width. |
| `ctx.beginGrid(n)` | `n` equal columns, filled row by row. |
| `ctx.beginScroll(&state, height)` | A scrolling column of a fixed height. |

If the content is taller than the window, the page scrolls without any extra code.

## 3. Read what the user did

Interactive widgets return `bool`:

- `button` returns true on the frame it is clicked.
- `checkbox`, `toggle`, `radio`, `slider`, `select`, `tabs` and `textInput` return true when they change your value.

So event handling is just an `if`:

```zig
if (ctx.buttonVariant("Clear flock", .destructive)) coop.confirm_clear = true;
```

## 4. Give repeated widgets unique names

Each widget's id comes from its label and the containers around it. Two widgets in the same container with the same label would share an id. Anything after `##` in a label is hidden from view but still counts towards the id, so you can make repeated labels unique:

```zig
const arena = ctx.builder().allocator; // freed at the end of the frame
ctx.begin(.row);
_ = ctx.toggle(try std.fmt.allocPrint(arena, "{s}##hen{d}", .{ hen.label(), i }), &hen.laying);
if (ctx.buttonVariant(try std.fmt.allocPrint(arena, "Remove##{d}", .{i}), .ghost)) { ... }
ctx.end();
```

Format labels with the frame arena from `ctx.builder().allocator`. Strings passed to widgets have to stay valid until `render`, and the arena is reset at the start of every frame.

Labels also name widgets for screen readers. Text inputs, selects and sliders don't draw their label, so put a `ctx.label` above them when you want the label to be visible. `ctx.label` takes no id, so it can repeat the field's name without a clash.

## 5. Dialogs

`beginDialog` draws a modal over the whole window while the bool it is given is `true`. It returns `true` only while the dialog is open, so you only add its contents in that case. Pressing Escape closes it for you:

```zig
if (ctx.beginDialog("Clear the flock?", &coop.confirm_clear)) {
    ctx.muted("Every hen is removed. Press Escape to cancel.");
    ctx.begin(.row);
    if (ctx.buttonVariant("Cancel", .outline)) coop.confirm_clear = false;
    if (ctx.buttonVariant("Clear", .destructive)) {
        coop.count = 0;
        coop.confirm_clear = false;
    }
    ctx.end();
    ctx.endDialog();
}
```

## 6. Errors

Widget calls don't return errors, so you write them without `try`. If one fails, for example because it ran out of memory, the context records the error and `render` returns it at the end of the frame. Only your own fallible calls, such as `allocPrint` above, need `try`.

## Full program

```zig title="src/main.zig"
const std = @import("std");
const ui = @import("weeoui");
const weeoui_sdl3 = @import("weeoui_sdl3");

const Hen = struct {
    name: [32]u8 = undefined,
    name_len: usize = 0,
    breed: usize = 0,
    laying: bool = true,

    fn label(self: *const Hen) []const u8 {
        return self.name[0..self.name_len];
    }
};

const Coop = struct {
    hens: [16]Hen = undefined,
    count: usize = 0,
    new_name: ui.TextEdit(32) = .{},
    breed: usize = 0,
    feed: f32 = 50,
    confirm_clear: bool = false,

    fn add(self: *Coop) void {
        const name = std.mem.trim(u8, self.new_name.text(), " ");
        if (name.len == 0 or self.count == self.hens.len) return;
        var hen = Hen{ .name_len = name.len, .breed = self.breed };
        @memcpy(hen.name[0..name.len], name);
        self.hens[self.count] = hen;
        self.count += 1;
        self.new_name.set("") catch unreachable;
    }

    fn remove(self: *Coop, index: usize) void {
        std.mem.copyForwards(Hen, self.hens[index .. self.count - 1], self.hens[index + 1 .. self.count]);
        self.count -= 1;
    }
};

const breeds = [_][]const u8{ "Orpington", "Leghorn", "Silkie" };

pub fn main(init: std.process.Init) !void {
    var coop = Coop{};
    try weeoui_sdl3.run(init.gpa, init.io, .{ .title = "Coop", .width = 520, .height = 640 }, &coop, frame);
}

fn frame(coop: *Coop, ctx: *ui.Context) !void {
    ctx.heading(1, "Coop");

    ctx.begin(.card);
    ctx.heading(4, "Add a hen");
    ctx.label("Name", .{});
    _ = ctx.textInput("Name", &coop.new_name, "Henrietta");
    ctx.label("Breed", .{});
    _ = ctx.select("Breed", &breeds, &coop.breed);
    if (ctx.button("Add")) coop.add();
    ctx.end();

    ctx.begin(.card);
    ctx.heading(4, "Flock");
    if (coop.count == 0) ctx.muted("No hens yet.");
    var laying: usize = 0;
    var i: usize = 0;
    while (i < coop.count) : (i += 1) {
        const hen = &coop.hens[i];
        const arena = ctx.builder().allocator;
        ctx.begin(.row);
        _ = ctx.toggle(try std.fmt.allocPrint(arena, "{s}##hen{d}", .{ hen.label(), i }), &hen.laying);
        ctx.badge(breeds[hen.breed], .secondary);
        if (ctx.buttonVariant(try std.fmt.allocPrint(arena, "Remove##{d}", .{i}), .ghost)) {
            coop.remove(i);
            ctx.end();
            break;
        }
        ctx.end();
        if (hen.laying) laying += 1;
    }
    ctx.label("{d} of {d} laying", .{ laying, coop.count });
    ctx.end();

    ctx.begin(.card);
    ctx.heading(4, "Feed");
    ctx.label("Grams per hen: {d:.0}", .{coop.feed});
    _ = ctx.slider("Grams per hen", &coop.feed, 0, 150);
    ctx.progress(coop.feed / 150);
    if (ctx.buttonVariant("Clear flock", .destructive)) coop.confirm_clear = true;
    ctx.end();

    if (ctx.beginDialog("Clear the flock?", &coop.confirm_clear)) {
        ctx.muted("Every hen is removed. Press Escape to cancel.");
        ctx.begin(.row);
        if (ctx.buttonVariant("Cancel", .outline)) coop.confirm_clear = false;
        if (ctx.buttonVariant("Clear", .destructive)) {
            coop.count = 0;
            coop.confirm_clear = false;
        }
        ctx.end();
        ctx.endDialog();
    }
}
```

## Next steps

- [Immediate mode in depth](../concepts/immediate-mode.md): the frame lifecycle, focus and hit testing.
- [Theming and images](../concepts/theming.md): colours, dark mode and pictures.
- [Your own loop and renderer](../concepts/custom-loop.md): embed Weeoui in an engine.
