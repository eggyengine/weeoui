//! Immediate-mode front end: call widgets every frame, they return what the user did.
//! Hit-testing uses the previous frame's layout, so widgets can answer before this frame is laid out.
//!
//! Widgets are named by their label; text after `##` is hidden but keeps names unique. For any
//! component without a wrapper here, build it with `builder()` and `widgets`, give it an `idFor`
//! id, add it with `element`, and ask `clicked`.
const std = @import("std");
const types = @import("types.zig");
const Rect = types.Rect;
const Vec2 = types.Vec2;
const Vertex = types.Vertex;
const Font = @import("font.zig").Font;
const Canvas = @import("canvas.zig").Canvas;
const L = @import("layout.zig");
const W = @import("widgets.zig");
const input = @import("input.zig");
const accessibility = @import("accessibility.zig");
const accesskit = @import("accesskit.zig");
const text_edit = @import("text_edit.zig");
const Image = @import("image.zig").Image;
const ColorEditor = @import("components/color_editor.zig").ColorEditor;
const ButtonVariant = @import("components/button.zig").Variant;
const BadgeVariant = @import("components/badge.zig").Variant;

pub const Container = enum { column, row, card };

/// Keyboard input queued for the focused widget, in arrival order.
const Pending = union(enum) {
    key: @FieldType(input.Event, "key_down"),
    /// Byte range of `Context.typed`.
    text: struct { start: usize, len: usize },
};

/// Where a widget sat last frame and which overlay layer it was on (higher wins hit tests).
const Target = struct { rect: Rect, z: i16 };

pub const Context = struct {
    gpa: std.mem.Allocator,
    font: Font,
    theme: types.Theme = .{},
    /// Physical pixels per viewport unit, for crisp edges on HiDPI targets.
    pixel_scale: [2]f32 = .{ 1, 1 },
    /// Set when rendering to an sRGB target so colors are linearized.
    srgb_target: bool = false,
    /// Milliseconds since the app started; drives GIFs and spinners. Backends set it each frame.
    time_ms: u64 = 0,
    arena: std.heap.ArenaAllocator,
    vertices: std.ArrayList(Vertex) = .empty,
    /// Element bounds from the last `render`, keyed by widget id.
    last_bounds: std.AutoHashMapUnmanaged(u32, Target) = .empty,
    /// The last rendered tree, for routing wheel and scrollbar input; freed by `newFrame`.
    last_root: ?*L.Element = null,
    pointer: Vec2 = .zero,
    /// A tap or click landed since the last frame: pressed and released on the same widget
    /// without scrolling in between, like a touch screen expects.
    clicked: bool = false,
    /// The left button went down since the last frame; drag widgets (sliders) grab the pointer on it.
    pressed_down: bool = false,
    /// The left button is held.
    pointer_held: bool = false,
    /// Where the current press started and on which widget, until it becomes a scroll.
    press: ?struct { at: Vec2, widget: u32 } = null,
    /// Widget that owns the pointer while the button is held (slider, color wheel).
    active: u32 = 0,
    /// Widget whose drag ended since the last frame.
    released: u32 = 0,
    /// Scroll area being dragged by its bar, or panned by a swipe.
    scroll_drag: ?struct { state: *L.ScrollState, bar: bool, last: Vec2 } = null,
    /// Scroll positions of widgets that scroll themselves (tab bars), by widget id.
    scroll_states: std.AutoHashMapUnmanaged(u32, *L.ScrollState) = .empty,
    viewport: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Open containers; the first entry is the frame root.
    stack: std.ArrayList(Open) = .empty,
    /// First failure during the frame, returned by `render` so widget calls need no `try`.
    err: ?anyerror = null,
    /// Screen-reader bridge; created by `attachAccessibility` (the SDL3 adapter does this for you).
    accesskit: ?*accesskit.Adapter = null,
    /// Name screen readers announce for the window.
    name: []const u8 = "weeoui",
    /// Focused widget (keyboard and assistive technology share it); 0 when none.
    focus: u32 = 0,
    /// Focusable widgets in declaration order: this frame's, and the last rendered frame's for Tab.
    focusables: std.ArrayList(u32) = .empty,
    last_focusables: std.ArrayList(u32) = .empty,
    /// Pending Tab (+1) / Shift+Tab (-1) moves, applied at `newFrame`.
    tab_moves: i32 = 0,
    /// Enter/Space pressed since the last frame.
    activate: bool = false,
    /// Escape pressed since the last frame; closes popups and dialogs.
    escape: bool = false,
    /// Keys and text for the focused text field.
    pending: std.ArrayList(Pending) = .empty,
    typed: std.ArrayList(u8) = .empty,
    /// A text field has focus: backends should enable text input (and the on-screen keyboard).
    wants_text: bool = false,
    /// The open select or menu, by trigger id; 0 when none.
    open_popup: u32 = 0,
    /// Widget clicked by assistive technology this frame.
    a11y_clicked: u32 = 0,
    /// Outline every clickable region in red, to check hit targets.
    debug_hitboxes: bool = false,
    /// Draw the focus ring: on after keyboard navigation, off after a click (like :focus-visible).
    focus_visible: bool = false,
    /// Pointer shape for the element under the pointer, after `render`; backends apply it.
    cursor: input.Cursor = .default,
    /// The element the last widget call added, for `tooltip`.
    last_added: ?*L.Element = null,
    /// The window's own scroll position: the page scrolls whenever its content is taller than the window.
    scroll: L.ScrollState = .{},

    const Kind = enum { column, row, card, grid, scroll, dialog };
    const Open = struct {
        kind: Kind,
        id: u32,
        children: std.ArrayList(*L.Element) = .empty,
        columns: u16 = 0,
        height: f32 = 0,
        scroll: ?*L.ScrollState = null,
        title: []const u8 = "",
    };

    pub fn init(gpa: std.mem.Allocator) !Context {
        return .{ .gpa = gpa, .font = try Font.init(gpa, @import("root.zig").default_font), .arena = .init(gpa) };
    }

    pub fn deinit(self: *Context) void {
        if (self.accesskit) |adapter| adapter.destroy();
        self.font.deinit();
        self.arena.deinit();
        self.vertices.deinit(self.gpa);
        self.last_bounds.deinit(self.gpa);
        self.last_focusables.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.typed.deinit(self.gpa);
        var states = self.scroll_states.valueIterator();
        while (states.next()) |state| self.gpa.destroy(state.*);
        self.scroll_states.deinit(self.gpa);
    }

    /// Feed input in the same coordinates as the viewport.
    pub fn handle(self: *Context, event: input.Event) void {
        switch (event) {
            .pointer_move => |p| {
                self.pointer = p;
                if (self.scroll_drag) |*drag| {
                    if (drag.bar) drag.state.pointerMove(p.x, p.y) else {
                        drag.state.offset = drag.state.offset.sub(p.sub(drag.last));
                        drag.state.clamp();
                    }
                    drag.last = p;
                } else if (self.press) |press| {
                    // A press that travels becomes a swipe: it scrolls whatever can scroll that way
                    // under where it started, and is no longer a tap.
                    const moved = p.sub(press.at);
                    if (self.active == 0 and @abs(moved.x) + @abs(moved.y) > swipe_threshold) {
                        const axis: L.ScrollState.Axis = if (@abs(moved.x) > @abs(moved.y)) .horizontal else .vertical;
                        if (self.last_root) |root| if (scrollable(root, press.at.x, press.at.y, axis)) |state| {
                            self.scroll_drag = .{ .state = state, .bar = false, .last = press.at };
                            self.press = null;
                            self.handle(event);
                        };
                    }
                }
            },
            .pointer_down => |down| {
                self.pointer = down.position;
                self.focus_visible = false;
                if (down.button != .left) return;
                self.pressed_down = true;
                self.pointer_held = true;
                self.press = .{ .at = down.position, .widget = self.hoveredWidget() };
                if (self.last_root) |root| if (root.scrollAt(down.position.x, down.position.y)) |state| {
                    if (state.pointerDown(down.position.x, down.position.y)) {
                        self.scroll_drag = .{ .state = state, .bar = true, .last = down.position };
                        self.press = null;
                    }
                };
            },
            .pointer_up => |up| {
                self.pointer = up.position;
                if (up.button != .left) return;
                if (self.press) |press| {
                    if (press.widget == self.hoveredWidget()) self.clicked = true;
                }
                self.press = null;
                self.pointer_held = false;
                self.released = self.active;
                self.active = 0;
                if (self.scroll_drag) |drag| if (drag.bar) drag.state.pointerUp();
                self.scroll_drag = null;
            },
            .wheel => |wheel| if (self.last_root) |root| {
                const axis: L.ScrollState.Axis = if (wheel.delta.y != 0) .vertical else .horizontal;
                if (scrollable(root, wheel.position.x, wheel.position.y, axis)) |state| state.wheel(wheel.delta.x, wheel.delta.y);
            },
            .key_down => |key| {
                switch (key.key) {
                    // Repeats count too, so holding Tab keeps moving focus.
                    .tab => {
                        self.tab_moves += if (key.modifiers.shift) -1 else 1;
                        self.focus_visible = true;
                        return;
                    },
                    .enter, .space => if (!key.repeat) {
                        self.activate = true;
                    },
                    .escape => self.escape = true,
                    else => {},
                }
                self.pending.append(self.gpa, .{ .key = key }) catch {};
            },
            .text => |value| {
                const start = self.typed.items.len;
                self.typed.appendSlice(self.gpa, value) catch return;
                self.pending.append(self.gpa, .{ .text = .{ .start = start, .len = value.len } }) catch {};
            },
            .composition => {},
        }
    }

    /// Expose this UI to screen readers through `window`. Idempotent.
    pub fn attachAccessibility(self: *Context, window: accesskit.Window) !void {
        if (self.accesskit == null) self.accesskit = try accesskit.Adapter.create(self.gpa, window, self.name);
    }

    pub fn newFrame(self: *Context, viewport: Rect) void {
        self.last_root = null;
        _ = self.arena.reset(.retain_capacity);
        if (self.accesskit) |adapter| while (adapter.nextAction()) |action| switch (action) {
            .click => |target| self.a11y_clicked = target,
            .focus => |target| self.focus = target,
            else => {},
        };
        self.moveFocus();
        self.focusables = .empty;
        self.viewport = viewport;
        self.stack = .empty;
        self.err = null;
        self.wants_text = false;
        self.last_added = null;
        self.push(.{ .kind = .column, .id = 0 });
    }

    // Containers ------------------------------------------------------------

    pub fn begin(self: *Context, kind: Container) void {
        self.push(.{ .kind = switch (kind) {
            .column => .column,
            .row => .row,
            .card => .card,
        }, .id = self.id(@tagName(kind)) });
    }

    /// A grid of `columns` equal columns, filled row by row. Close with `end`.
    pub fn beginGrid(self: *Context, columns: u16) void {
        self.push(.{ .kind = .grid, .id = self.id("grid"), .columns = @max(1, columns) });
    }

    /// A scrolling column `height` tall inside the page (the page itself scrolls on its own).
    /// `state` keeps the scroll position between frames. Close with `end`.
    pub fn beginScroll(self: *Context, state: *L.ScrollState, height: f32) void {
        self.push(.{ .kind = .scroll, .id = self.id("scroll"), .height = height, .scroll = state });
    }

    /// A modal dialog over the whole window while `open.*`. Escape closes it. Returns whether
    /// it is open; only then add its contents and call `endDialog`.
    pub fn beginDialog(self: *Context, title: []const u8, open: *bool) bool {
        if (open.* and self.escape) {
            open.* = false;
            self.escape = false;
        }
        if (!open.*) return false;
        self.push(.{ .kind = .dialog, .id = self.id(title), .title = visible(title) });
        return true;
    }

    pub fn endDialog(self: *Context) void {
        std.debug.assert(self.stack.items[self.stack.items.len - 1].kind == .dialog); // `endDialog` without `beginDialog`
        self.end();
    }

    pub fn end(self: *Context) void {
        std.debug.assert(self.stack.items.len > 1); // unmatched `end`
        const open = self.stack.pop().?;
        if (self.err != null) return;
        const b = self.builder();
        switch (open.kind) {
            .column => self.add(open.id, .{ .gap = 12 }, .none, open.children.items),
            .row => self.add(open.id, .{ .direction = .row, .gap = 12, .align_items = .center, .wrap = true }, .none, open.children.items),
            // Cards stop growing at a readable width instead of stretching across wide windows.
            .card => self.add(open.id, .{ .padding = .{ .left = 24, .right = 24, .top = 24, .bottom = 24 }, .gap = 12, .max_width = 640 }, .card, open.children.items),
            .grid => self.add(open.id, .{ .columns = open.columns, .gap = 12 }, .none, open.children.items),
            .scroll => {
                const area = b.node(open.id, .{ .height = open.height, .overflow = .scroll, .gap = 12, .padding = .{ .right = 12 } }, .none, open.children.items) catch |e| return self.fail(e);
                area.scroll = open.scroll;
                open.scroll.?.overlay_bar = true;
                self.append(area);
            },
            .dialog => {
                const children = self.arena.allocator().alloc(*L.Element, open.children.items.len + 1) catch |e| return self.fail(e);
                children[0] = W.heading(b, 3, open.title) catch |e| return self.fail(e);
                @memcpy(children[1..], open.children.items);
                const modal = W.modal(b, self.viewport, .dialog, children) catch |e| return self.fail(e);
                // The backdrop takes an id so it swallows clicks meant for the page underneath.
                modal.id = open.id;
                modal.overlay = .viewport;
                modal.style.z_index = 300;
                self.appendTo(0, modal);
            },
        }
    }

    // Text and display ------------------------------------------------------

    pub fn label(self: *Context, comptime fmt: []const u8, args: anytype) void {
        const value = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch |e| return self.fail(e);
        self.add(0, .{}, .{ .text = .{ .value = value, .wrap = true } }, &.{});
    }

    /// `level` 1 (page title) to 4 (small section title).
    pub fn heading(self: *Context, level: u3, value: []const u8) void {
        self.append(W.heading(self.builder(), level, value) catch |e| return self.fail(e));
    }

    /// Wrapped body text.
    pub fn text(self: *Context, value: []const u8) void {
        self.add(0, .{}, .{ .text = .{ .value = value, .wrap = true } }, &.{});
    }

    /// Wrapped secondary text.
    pub fn muted(self: *Context, value: []const u8) void {
        self.add(0, .{}, .{ .text = .{ .value = value, .wrap = true, .tone = .muted, .size = 14 } }, &.{});
    }

    pub fn separator(self: *Context) void {
        self.add(0, .{ .height = 1 }, .separator, &.{});
    }

    pub fn badge(self: *Context, text_value: []const u8, variant: BadgeVariant) void {
        self.add(0, .{ .height = 22 }, .{ .badge = .{ .label = text_value, .variant = variant } }, &.{});
    }

    pub fn avatar(self: *Context, initials: []const u8) void {
        self.add(0, .{ .width = 40, .height = 40 }, .{ .avatar = initials }, &.{});
    }

    pub fn alert(self: *Context, title: []const u8, description: []const u8, destructive: bool) void {
        self.add(0, .{ .height = 80 }, .{ .alert = .{ .title = title, .description = description, .destructive = destructive } }, &.{});
    }

    /// `value` from 0 to 1.
    pub fn progress(self: *Context, value: f32) void {
        self.add(0, .{ .height = 16 }, .{ .progress = std.math.clamp(value, 0, 1) }, &.{});
    }

    pub fn spinner(self: *Context) void {
        self.add(0, .{ .width = 24, .height = 24 }, .{ .spinner = @as(f32, @floatFromInt(self.time_ms % 1000)) / 1000 }, &.{});
    }

    pub fn skeleton(self: *Context, width: f32, height: f32) void {
        self.add(0, .{ .width = width, .height = height }, .{ .animated_skeleton = @as(f32, @floatFromInt(self.time_ms % 1500)) / 1500 }, &.{});
    }

    pub fn table(self: *Context, headers: []const []const u8, rows: []const []const []const u8) void {
        self.append(W.tableWithOptions(self.builder(), headers, rows, .{ .lines = true }) catch |e| return self.fail(e));
    }

    /// Draw `image` (its current frame, for GIFs) `width` wide, or at its decoded size when
    /// null, keeping its aspect ratio.
    pub fn image(self: *Context, value: *const Image, width: ?f32) void {
        const w = width orelse @as(f32, @floatFromInt(value.width));
        const h = w * @as(f32, @floatFromInt(value.height)) / @as(f32, @floatFromInt(@max(1, value.width)));
        self.add(0, .{ .width = w, .aspect_ratio = w / @max(1, h) }, .{ .image = value.frameAt(self.time_ms) }, &.{});
        if (self.last_added) |added| added.accessibility.role = .image;
    }

    /// Show `text` beside the previous widget while the pointer rests on it.
    pub fn tooltip(self: *Context, value: []const u8) void {
        const anchor = self.last_added orelse return;
        if (anchor.id == 0 or anchor.id != self.hoveredWidget()) return;
        self.appendTo(0, W.tooltipAt(self.builder(), anchor, value) catch |e| return self.fail(e));
    }

    // Controls ----------------------------------------------------------------

    /// Returns true on the frame the button is clicked.
    pub fn button(self: *Context, value: []const u8) bool {
        return self.buttonVariant(value, .default);
    }

    pub fn buttonVariant(self: *Context, value: []const u8, variant: ButtonVariant) bool {
        const widget = self.focusable(value);
        const clicked_now = self.pressed(widget);
        const shown = visible(value);
        self.add(widget, .{ .width = @max(96, self.font.measure(shown, 14) + 32), .height = 40 }, .{ .button = .{ .label = shown, .variant = variant, .hot = self.hoveredWidget() == widget } }, &.{});
        return clicked_now;
    }

    /// Toggles `value` when clicked; returns true if it changed.
    pub fn checkbox(self: *Context, value_label: []const u8, value: *bool) bool {
        const widget = self.focusable(value_label);
        const changed = self.pressed(widget);
        if (changed) value.* = !value.*;
        self.add(widget, .{ .height = 32 }, .{ .checkbox = .{ .label = visible(value_label), .checked = value.* } }, &.{});
        return changed;
    }

    /// A switch; returns true if `value` changed.
    pub fn toggle(self: *Context, value_label: []const u8, value: *bool) bool {
        const widget = self.focusable(value_label);
        const changed = self.pressed(widget);
        if (changed) value.* = !value.*;
        self.add(widget, .{ .height = 32 }, .{ .toggle = .{ .label = visible(value_label), .enabled = value.* } }, &.{});
        return changed;
    }

    /// One choice of a radio group: selects `index` into `selected`. Returns true if it changed.
    pub fn radio(self: *Context, value_label: []const u8, selected: *usize, index: usize) bool {
        const widget = self.focusable(value_label);
        const changed = self.pressed(widget) and selected.* != index;
        if (changed) selected.* = index;
        const b = self.builder();
        const circle = b.node(0, .{ .width = 20, .height = 20 }, .{ .radio = .{ .checked = selected.* == index } }, &.{}) catch |e| return self.failed(e);
        const caption = b.node(0, .{}, .{ .text = .{ .value = visible(value_label) } }, &.{}) catch |e| return self.failed(e);
        caption.accessibility.role = .ignored;
        self.add(widget, .{ .direction = .row, .height = 32, .gap = 10, .align_items = .center }, .none, &.{ circle, caption });
        if (self.last_added) |added| added.accessibility = .{ .role = .radio, .label = visible(value_label) };
        return changed;
    }

    /// Drag, click, or use the arrow keys to set `value` between `min` and `max`. Returns true if it changed.
    pub fn slider(self: *Context, value_label: []const u8, value: *f32, min: f32, max: f32) bool {
        const widget = self.focusable(value_label);
        if (self.pressed_down and self.hoveredWidget() == widget) self.active = widget;
        const before = value.*;
        if (self.active == widget) if (self.last_bounds.get(widget)) |target| {
            const t = std.math.clamp((self.pointer.x - target.rect.x - 8) / @max(1, target.rect.w - 16), 0, 1);
            value.* = min + t * (max - min);
        };
        if (self.focus == widget) for (self.pending.items) |item| switch (item) {
            .key => |key| switch (key.key) {
                .left, .down => value.* -= (max - min) / 20,
                .right, .up => value.* += (max - min) / 20,
                .home => value.* = min,
                .end => value.* = max,
                else => {},
            },
            .text => {},
        };
        value.* = std.math.clamp(value.*, min, max);
        const t = if (max > min) (value.* - min) / (max - min) else 0;
        self.add(widget, .{ .height = 28, .min_width = 160 }, .{ .slider = .{ .value = t } }, &.{});
        if (self.last_added) |added| added.accessibility = .{ .label = visible(value_label), .numeric_value = t };
        return value.* != before;
    }

    /// A tab bar; clicking a tab selects its index. Draw the selected tab's content after it.
    pub fn tabs(self: *Context, labels: []const []const u8, selected: *usize) bool {
        const b = self.builder();
        const children = self.arena.allocator().alloc(*L.Element, labels.len) catch |e| return self.failed(e);
        var changed = false;
        for (labels, children, 0..) |tab_label, *child, i| {
            const widget = self.focusable(tab_label);
            if (self.pressed(widget) and selected.* != i) {
                selected.* = i;
                changed = true;
            }
            child.* = b.tab(widget, visible(tab_label), selected.* == i) catch |e| return self.failed(e);
            child.*.style.height = 32;
        }
        // Too many tabs for the width scroll sideways instead of squashing.
        const bar = b.node(0, .{ .direction = .row, .gap = 2, .padding = .{ .left = 3, .right = 3, .top = 3, .bottom = 3 }, .overflow = .scroll }, .{ .surface = .track }, children) catch |e| return self.failed(e);
        bar.accessibility.role = .tab_list;
        bar.scroll = self.scrollState(self.id("tabs")) catch |e| return self.failed(e);
        self.append(bar);
        return changed;
    }

    /// A dropdown of `options`; picking one sets `selected`. Returns true if it changed.
    pub fn select(self: *Context, value_label: []const u8, options: []const []const u8, selected: *usize) bool {
        const widget = self.focusable(value_label);
        const b = self.builder();
        var changed = false;
        var on_item = false;
        if (self.open_popup == widget) {
            for (options, 0..) |_, i| {
                const item = itemId(widget, i);
                if (self.hoveredWidget() == item) on_item = true;
                if (self.pressed(item)) {
                    changed = selected.* != i;
                    selected.* = i;
                    self.open_popup = 0;
                }
            }
            if (self.escape) {
                self.open_popup = 0;
                self.escape = false;
            }
        }
        if (self.pressed(widget)) {
            self.open_popup = if (self.open_popup == widget) 0 else widget;
        } else if (self.open_popup == widget and self.clicked and !on_item) self.open_popup = 0;
        const current = if (selected.* < options.len) options[selected.*] else "";
        const trigger = W.select(b, widget, current, visible(value_label)) catch |e| return self.failed(e);
        trigger.style.min_width = 200;
        self.append(trigger);
        if (self.open_popup == widget) {
            const choices = self.arena.allocator().alloc(W.Choice, options.len) catch |e| return self.failed(e);
            for (choices, options, 0..) |*choice, option, i| choice.* = .{ .id = itemId(widget, i), .label = option };
            const hot = self.hoveredWidget();
            if (W.dropdownMenu(b, trigger, choices, hot, true) catch |e| return self.failed(e)) |menu| self.appendTo(0, menu);
            for (choices) |choice| self.focusables.append(self.arena.allocator(), choice.id) catch |e| return self.failed(e);
        }
        return changed;
    }

    /// A single-line text field editing `edit` (a `TextEdit(n)`). Returns true if the text changed.
    pub fn textInput(self: *Context, value_label: []const u8, edit: anytype, placeholder: []const u8) bool {
        const widget = self.focusable(value_label);
        const size = self.theme.text_size;
        const before_len = edit.len;
        const before_hash = std.hash.Wyhash.hash(0, edit.text());
        if (self.focus == widget) {
            self.wants_text = true;
            if (self.clicked and self.hoveredWidget() == widget) if (self.last_bounds.get(widget)) |target| {
                edit.placeCaret(&self.font, size, text_edit.inputContentRect(target.rect), false, self.pointer.x, self.pointer.y, false);
            };
            for (self.pending.items) |item| switch (item) {
                .text => |range| _ = edit.insertFitting(self.typed.items[range.start..][0..range.len]) catch false,
                .key => |key| {
                    const word = key.modifiers.control or key.modifiers.alt;
                    const shift = key.modifiers.shift;
                    switch (key.key) {
                        .backspace => edit.backspace(),
                        .delete => edit.delete(),
                        .left => edit.moveLeft(shift, word),
                        .right => edit.moveRight(shift, word),
                        .home => edit.moveHome(shift),
                        .end => edit.moveEnd(shift),
                        .a => if (key.modifiers.control or key.modifiers.super) edit.selectAll(),
                        .z => if (key.modifiers.control or key.modifiers.super) {
                            _ = if (shift) edit.redo() else edit.undo();
                        },
                        .y => if (key.modifiers.control) {
                            _ = edit.redo();
                        },
                        else => {},
                    }
                },
            };
        }
        const focused = self.focus == widget;
        self.add(widget, .{ .height = 40, .min_width = 200 }, .{ .input = .{
            .value = edit.text(),
            .placeholder = placeholder,
            .focused = focused,
            .caret_visible = (self.time_ms / 530) % 2 == 0,
            .cursor = if (focused) edit.cursor else null,
            .selection = if (focused) edit.selection() else null,
        } }, &.{});
        if (self.last_added) |added| added.accessibility.label = visible(value_label);
        return edit.len != before_len or std.hash.Wyhash.hash(0, edit.text()) != before_hash;
    }

    /// Hue wheel plus value and alpha sliders editing `editor`. Returns true while it changes.
    pub fn colorPicker(self: *Context, value_label: []const u8, editor: *ColorEditor) bool {
        const base = self.focusable(value_label);
        const b = self.builder();
        const before = editor.*;
        const parts = [_]struct { id: u32, channel: @import("components/color_editor.zig").Channel }{
            .{ .id = itemId(base, 0), .channel = .wheel },
            .{ .id = itemId(base, 1), .channel = .value },
            .{ .id = itemId(base, 2), .channel = .alpha },
        };
        for (parts) |part| {
            if (self.pressed_down and self.hoveredWidget() == part.id) if (self.last_bounds.get(part.id)) |target| {
                self.active = part.id;
                editor.press(part.channel, target.rect, self.pointer.x, self.pointer.y);
            };
            if (self.active == part.id) editor.dragTo(self.pointer.x, self.pointer.y);
            if (self.released == part.id) editor.release();
        }
        const wheel = b.node(parts[0].id, .{ .width = 160, .height = 160 }, .{ .color_wheel = editor.* }, &.{}) catch |e| return self.failed(e);
        const value = b.node(parts[1].id, .{ .height = 28, .min_width = 160 }, .{ .color_channel = .{ .editor = editor.*, .channel = .value, .label = "Value" } }, &.{}) catch |e| return self.failed(e);
        const alpha = b.node(parts[2].id, .{ .height = 28, .min_width = 160 }, .{ .color_channel = .{ .editor = editor.*, .channel = .alpha, .label = "Alpha" } }, &.{}) catch |e| return self.failed(e);
        const swatch = b.node(0, .{ .height = 40 }, .{ .swatch = .{ .color = editor.rgb(), .alpha = editor.alpha } }, &.{}) catch |e| return self.failed(e);
        const sliders = b.node(0, .{ .gap = 12, .grow = 1 }, .none, &.{ value, alpha, swatch }) catch |e| return self.failed(e);
        self.add(0, .{ .direction = .row, .gap = 16 }, .none, &.{ wheel, sliders });
        return !std.meta.eql(before, editor.*);
    }

    // Escape hatch ------------------------------------------------------------

    /// Frame-lifetime allocator for building `widgets`/`Layout` elements by hand.
    pub fn builder(self: *Context) L.Builder {
        return .{ .allocator = self.arena.allocator() };
    }

    /// Id for a hand-built interactive element named `value`, registered in Tab order.
    pub fn idFor(self: *Context, value: []const u8) u32 {
        return self.focusable(value);
    }

    /// Add a hand-built element to the open container.
    pub fn element(self: *Context, value: *L.Element) void {
        self.append(value);
    }

    /// Whether the element with `widget` id (from `idFor`) was clicked or activated this frame.
    pub fn activated(self: *const Context, widget: u32) bool {
        return self.pressed(widget);
    }

    /// Lays out and paints the frame. The vertices stay valid until the next `render`.
    pub fn render(self: *Context) ![]const Vertex {
        defer {
            self.clicked = false;
            self.a11y_clicked = 0;
            self.activate = false;
            self.escape = false;
            self.released = 0;
            self.pressed_down = false;
            self.pending.clearRetainingCapacity();
            self.typed.clearRetainingCapacity();
        }
        if (self.err) |e| return e;
        std.debug.assert(self.stack.items.len == 1); // missing `end`
        const b = self.builder();
        const root = try b.node(0, .{ .width = self.viewport.w, .height = self.viewport.h, .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 }, .gap = 12, .overflow = .scroll }, .none, self.stack.items[0].children.items);
        root.scroll = &self.scroll;
        self.scroll.overlay_bar = true;
        root.layout(self.viewport, &self.font);
        self.last_root = root;
        self.last_bounds.clearRetainingCapacity();
        try self.remember(root, 0);
        self.last_focusables.clearRetainingCapacity();
        try self.last_focusables.appendSlice(self.gpa, self.focusables.items);
        if (std.mem.indexOfScalar(u32, self.focusables.items, self.focus) == null) self.focus = 0;
        if (self.accesskit) |adapter| {
            root.accessibility.label = self.name;
            // ponytail: republishes the whole tree every frame; diff against the last snapshot if screen readers lag.
            var tree_arena = std.heap.ArenaAllocator.init(self.gpa);
            errdefer tree_arena.deinit();
            const snapshot = try accessibility.collect(tree_arena.allocator(), root, self.focus);
            adapter.update(tree_arena, snapshot, 1);
        }
        if (self.vertices.capacity == 0) try self.vertices.ensureTotalCapacity(self.gpa, 4096);
        while (true) {
            var canvas = Canvas.init(self.vertices.allocatedSlice(), &self.font);
            canvas.theme = self.theme;
            canvas.pixel_scale = self.pixel_scale;
            canvas.srgb_target = self.srgb_target;
            canvas.focus_id = if (self.focus_visible) self.focus else 0;
            canvas.hot_id = self.hoveredWidget();
            self.cursor = if (root.find(canvas.hot_id)) |hot| hot.cursorFor() else .default;
            if (root.draw(&canvas)) {
                if (self.debug_hitboxes) root.drawHitboxes(&canvas) catch |e| switch (e) {
                    error.OutOfVertices => {
                        try self.vertices.ensureTotalCapacity(self.gpa, self.vertices.capacity * 2);
                        continue;
                    },
                    else => return e,
                };
                return canvas.items();
            } else |e| switch (e) {
                error.OutOfVertices => try self.vertices.ensureTotalCapacity(self.gpa, self.vertices.capacity * 2),
                else => return e,
            }
        }
    }

    /// Scroll position kept for `widget` between frames.
    fn scrollState(self: *Context, widget: u32) !*L.ScrollState {
        const entry = try self.scroll_states.getOrPut(self.gpa, widget);
        if (!entry.found_existing) {
            errdefer _ = self.scroll_states.remove(widget);
            entry.value_ptr.* = try self.gpa.create(L.ScrollState);
            entry.value_ptr.*.* = .{};
        }
        return entry.value_ptr.*;
    }

    fn push(self: *Context, open: Open) void {
        self.stack.append(self.arena.allocator(), open) catch |e| self.fail(e);
    }

    fn add(self: *Context, widget: u32, style: L.Style, paint: L.Paint, children: []const *L.Element) void {
        if (self.err != null) return;
        self.append(self.builder().node(widget, style, paint, children) catch |e| return self.fail(e));
    }

    fn append(self: *Context, value: *L.Element) void {
        self.appendTo(self.stack.items.len - 1, value);
    }

    fn appendTo(self: *Context, depth: usize, value: *L.Element) void {
        if (self.err != null) return;
        self.stack.items[depth].children.append(self.arena.allocator(), value) catch |e| return self.fail(e);
        self.last_added = value;
    }

    fn remember(self: *Context, value: *const L.Element, layer: i16) !void {
        const z = if (value.overlay != null) value.style.z_index else layer;
        if (value.id != 0) try self.last_bounds.put(self.gpa, value.id, .{ .rect = value.bounds.intersection(value.clip), .z = z });
        for (value.children) |child| try self.remember(child, z);
    }

    // ponytail: ids hash the label with the open-container path; identical labels in one container collide, use `##suffix`.
    fn id(self: *const Context, value: []const u8) u32 {
        var seed: u64 = 0;
        for (self.stack.items) |open| seed = seed *% 31 +% open.id +% open.children.items.len;
        return @as(u32, @truncate(std.hash.Wyhash.hash(seed, value))) | 1;
    }

    /// Topmost last-frame widget under the pointer: the highest overlay layer, then the smallest
    /// area, so popups beat the page and nested hit targets win.
    fn hoveredWidget(self: *const Context) u32 {
        var best: u32 = 0;
        var best_z: i16 = std.math.minInt(i16);
        var area = std.math.inf(f32);
        var it = self.last_bounds.iterator();
        while (it.next()) |entry| {
            const target = entry.value_ptr.*;
            const r = target.rect;
            if (!r.contains(self.pointer.x, self.pointer.y)) continue;
            if (target.z > best_z or (target.z == best_z and r.w * r.h < area)) {
                best = entry.key_ptr.*;
                best_z = target.z;
                area = r.w * r.h;
            }
        }
        return best;
    }

    /// Id for an interactive widget, registered in Tab order. A mouse press on it takes focus.
    fn focusable(self: *Context, value: []const u8) u32 {
        const widget = self.id(value);
        self.focusables.append(self.arena.allocator(), widget) catch |e| self.fail(e);
        if (self.clicked and self.hoveredWidget() == widget) self.focus = widget;
        return widget;
    }

    fn moveFocus(self: *Context) void {
        defer self.tab_moves = 0;
        const order = self.last_focusables.items;
        if (self.tab_moves == 0 or order.len == 0) return;
        const n: i64 = @intCast(order.len);
        const start: i64 = if (std.mem.indexOfScalar(u32, order, self.focus)) |i| @intCast(i) else if (self.tab_moves > 0) -1 else n;
        self.focus = order[@intCast(@mod(start + self.tab_moves, n))];
    }

    fn pressed(self: *const Context, widget: u32) bool {
        return (self.clicked and self.hoveredWidget() == widget) or self.a11y_clicked == widget or (self.activate and self.focus == widget);
    }

    fn fail(self: *Context, e: anyerror) void {
        if (self.err == null) self.err = e;
    }

    fn failed(self: *Context, e: anyerror) bool {
        self.fail(e);
        return false;
    }
};

/// How far (in viewport units) a press may travel and still count as a tap.
const swipe_threshold = 10;

/// The innermost scroll area under (`x`, `y`) with room to move along `axis`, so a sideways swipe
/// on a tab bar scrolls the tabs while an up/down swipe on it still scrolls the page.
fn scrollable(element: *const L.Element, x: f32, y: f32, axis: L.ScrollState.Axis) ?*L.ScrollState {
    const within = element.bounds.intersection(element.clip).contains(x, y);
    if (!within and !element.has_overlays) return null;
    var i = element.children.len;
    while (i > 0) {
        i -= 1;
        if (scrollable(element.paintChild(i), x, y, axis)) |state| return state;
    }
    const state = element.scroll orelse return null;
    if (!within) return null;
    const room = switch (axis) {
        .horizontal => state.content.x - state.viewport.w,
        .vertical => state.content.y - state.viewport.h,
    };
    return if (room > 0.5) state else null;
}

/// Stable id for the `index`th part of `widget` (select options, color picker parts).
fn itemId(widget: u32, index: usize) u32 {
    return @as(u32, @truncate(std.hash.Wyhash.hash(widget, std.mem.asBytes(&index)))) | 1;
}

fn visible(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOf(u8, text, "##") orelse text.len];
}

test "screen reader clicks and the published tree reach the counter" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var adapter = accesskit.Adapter{ .allocator = std.testing.allocator, .name = "", .arena = .init(std.testing.allocator) };
    defer adapter.arena.deinit();
    ctx.accesskit = &adapter;
    defer ctx.accesskit = null;
    const viewport = Rect{ .x = 0, .y = 0, .w = 400, .h = 300 };
    var count: u32 = 0;
    for (0..2) |frame| {
        if (frame == 1) {
            var ids = ctx.last_bounds.keyIterator();
            adapter.push(.{ .click = ids.next().?.* }); // the only widget with an id
        }
        ctx.newFrame(viewport);
        ctx.label("Count: {d}", .{count});
        if (ctx.button("Increment")) count += 1;
        _ = try ctx.render();
    }
    try std.testing.expectEqual(@as(u32, 1), count);
    const dump = try accesskit.debugTree(&adapter, std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "Increment") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "weeoui") != null);
}

test "tab and shift+tab cycle focus; enter activates the focused widget" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const viewport = Rect{ .x = 0, .y = 0, .w = 400, .h = 300 };
    var count: u32 = 0;
    var hints = false;
    const Frame = struct {
        fn run(c: *Context, v: Rect, n: *u32, h: *bool) !void {
            c.newFrame(v);
            if (c.button("Increment")) n.* += 1;
            _ = c.checkbox("Show hints", h);
            _ = try c.render();
        }
    };
    const tab: input.Event = .{ .key_down = .{ .key = .tab, .modifiers = .{}, .repeat = false } };
    const back_tab: input.Event = .{ .key_down = .{ .key = .tab, .modifiers = .{ .shift = true }, .repeat = false } };
    const enter: input.Event = .{ .key_down = .{ .key = .enter, .modifiers = .{}, .repeat = false } };

    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(@as(u32, 0), ctx.focus);
    const button_id = ctx.last_focusables.items[0];
    const checkbox_id = ctx.last_focusables.items[1];

    ctx.handle(tab);
    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(button_id, ctx.focus);
    ctx.handle(enter);
    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(@as(u32, 1), count);

    ctx.handle(tab);
    ctx.handle(.{ .key_down = .{ .key = .space, .modifiers = .{}, .repeat = false } });
    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(checkbox_id, ctx.focus);
    try std.testing.expect(hints);

    // A held Tab (repeat events) keeps moving: two steps from the checkbox wrap back to it.
    ctx.handle(.{ .key_down = .{ .key = .tab, .modifiers = .{}, .repeat = true } });
    ctx.handle(.{ .key_down = .{ .key = .tab, .modifiers = .{}, .repeat = true } });
    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(checkbox_id, ctx.focus);
    ctx.handle(tab); // wraps to the first widget
    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(button_id, ctx.focus);
    ctx.handle(back_tab); // and back around to the last
    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(checkbox_id, ctx.focus);
    try std.testing.expectEqual(@as(u32, 1), count);
}

test "counter button clicks against last frame's layout" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const viewport = Rect{ .x = 0, .y = 0, .w = 400, .h = 300 };
    var count: u32 = 0;
    var hints = false;
    for (0..3) |_| {
        ctx.newFrame(viewport);
        ctx.begin(.card);
        ctx.label("Count: {d}", .{count});
        if (ctx.button("Increment")) count += 1;
        _ = ctx.checkbox("Show hints", &hints);
        ctx.end();
        try std.testing.expect((try ctx.render()).len > 0);
        // Click the button (the first focusable widget) at its centre from the frame just rendered.
        const target = ctx.last_bounds.get(ctx.last_focusables.items[0]).?;
        ctx.handle(.{ .pointer_down = .{ .position = target.rect.center(), .button = .left, .clicks = 1 } });
        ctx.handle(.{ .pointer_up = .{ .position = target.rect.center(), .button = .left } });
    }
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expect(!hints);
}

test "slider drags, select picks, text input types, radio selects, dialog closes on escape" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const viewport = Rect{ .x = 0, .y = 0, .w = 600, .h = 800 };
    const State = struct {
        volume: f32 = 0,
        size: usize = 0,
        choice: usize = 0,
        name: text_edit.TextEdit(32) = .{},
        dialog: bool = true,
        fn frame(c: *Context, v: Rect, s: *@This()) !void {
            c.newFrame(v);
            _ = c.slider("Volume", &s.volume, 0, 10);
            _ = c.select("Size", &.{ "Small", "Medium", "Large" }, &s.size);
            _ = c.textInput("Name", &s.name, "Your name");
            _ = c.radio("One", &s.choice, 0);
            _ = c.radio("Two", &s.choice, 1);
            if (c.beginDialog("Hello", &s.dialog)) c.endDialog();
            _ = try c.render();
        }
    };
    var s: State = .{};
    try State.frame(&ctx, viewport, &s);
    // The open dialog covers the page; Escape closes it.
    ctx.handle(.{ .key_down = .{ .key = .escape, .modifiers = .{}, .repeat = false } });
    try State.frame(&ctx, viewport, &s);
    try std.testing.expect(!s.dialog);
    try State.frame(&ctx, viewport, &s);
    const ids = ctx.last_focusables.items; // volume, size, name, one, two
    const at = struct {
        fn center(c: *const Context, widget: u32) Vec2 {
            return c.last_bounds.get(widget).?.rect.center();
        }
    };

    // Press the slider at its right end and drag to the middle.
    const track = ctx.last_bounds.get(ids[0]).?.rect;
    ctx.handle(.{ .pointer_down = .{ .position = Vec2.init(track.x + track.w - 1, track.center().y), .button = .left, .clicks = 1 } });
    try State.frame(&ctx, viewport, &s);
    try std.testing.expectEqual(@as(f32, 10), s.volume);
    ctx.handle(.{ .pointer_move = track.center() });
    try State.frame(&ctx, viewport, &s);
    try std.testing.expectApproxEqAbs(@as(f32, 5), s.volume, 0.01);
    ctx.handle(.{ .pointer_up = .{ .position = track.center(), .button = .left } });

    // Open the select, then pick its third option from the popup.
    tap(&ctx, at.center(&ctx, ids[1]));
    try State.frame(&ctx, viewport, &s);
    try State.frame(&ctx, viewport, &s);
    const large = ctx.last_bounds.get(itemId(ids[1], 2)).?.rect.center();
    ctx.handle(.{ .pointer_move = large });
    tap(&ctx, large);
    try State.frame(&ctx, viewport, &s);
    try std.testing.expectEqual(@as(usize, 2), s.size);
    try std.testing.expectEqual(@as(u32, 0), ctx.open_popup);

    // Focus the field by clicking it, then type and backspace.
    tap(&ctx, at.center(&ctx, ids[2]));
    try State.frame(&ctx, viewport, &s);
    try std.testing.expect(ctx.wants_text);
    ctx.handle(.{ .text = "Eggs" });
    ctx.handle(.{ .key_down = .{ .key = .backspace, .modifiers = .{}, .repeat = false } });
    try State.frame(&ctx, viewport, &s);
    try std.testing.expectEqualStrings("Egg", s.name.text());

    // Clicking the second radio's label selects it.
    tap(&ctx, at.center(&ctx, ids[4]));
    try State.frame(&ctx, viewport, &s);
    try std.testing.expectEqual(@as(usize, 1), s.choice);
}

test "the page scrolls on its own when content is taller than the window" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const viewport = Rect{ .x = 0, .y = 0, .w = 300, .h = 200 };
    for (0..3) |_| {
        ctx.newFrame(viewport);
        for (0..40) |i| ctx.label("Row {d}", .{i});
        _ = try ctx.render();
        ctx.handle(.{ .wheel = .{ .position = Vec2.init(150, 100), .delta = Vec2.init(0, -1) } });
    }
    try std.testing.expect(ctx.scroll.offset.y > 0);
    // Touch-style drag on the background pans it back.
    ctx.handle(.{ .pointer_down = .{ .position = Vec2.init(290, 150), .button = .left, .clicks = 1 } });
    ctx.handle(.{ .pointer_move = Vec2.init(290, 400) });
    try std.testing.expectEqual(@as(f32, 0), ctx.scroll.offset.y);
}

fn tap(ctx: *Context, at: Vec2) void {
    ctx.handle(.{ .pointer_move = at });
    ctx.handle(.{ .pointer_down = .{ .position = at, .button = .left, .clicks = 1 } });
    ctx.handle(.{ .pointer_up = .{ .position = at, .button = .left } });
}

test "a swipe that starts on a button scrolls the page instead of clicking" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const viewport = Rect{ .x = 0, .y = 0, .w = 300, .h = 200 };
    var clicks: u32 = 0;
    const Page = struct {
        fn frame(c: *Context, v: Rect, n: *u32) !void {
            c.newFrame(v);
            if (c.button("Tap me")) n.* += 1;
            for (0..40) |i| c.label("Row {d}", .{i});
            _ = try c.render();
        }
    };
    try Page.frame(&ctx, viewport, &clicks);
    const button = ctx.last_bounds.get(ctx.last_focusables.items[0]).?.rect.center();
    ctx.handle(.{ .pointer_down = .{ .position = button, .button = .left, .clicks = 1 } });
    ctx.handle(.{ .pointer_move = button.sub(Vec2.init(0, 60)) });
    ctx.handle(.{ .pointer_up = .{ .position = button.sub(Vec2.init(0, 60)), .button = .left } });
    try Page.frame(&ctx, viewport, &clicks);
    try std.testing.expectEqual(@as(u32, 0), clicks);
    try std.testing.expect(ctx.scroll.offset.y > 40);
    // A tap on it (scrolled back into view) still clicks.
    ctx.scroll.offset = .zero;
    try Page.frame(&ctx, viewport, &clicks);
    try Page.frame(&ctx, viewport, &clicks);
    tap(&ctx, ctx.last_bounds.get(ctx.last_focusables.items[0]).?.rect.center());
    try Page.frame(&ctx, viewport, &clicks);
    try std.testing.expectEqual(@as(u32, 1), clicks);
}
