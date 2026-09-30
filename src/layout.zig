//! Frame-local element tree: measure, place, then paint.
const std = @import("std");
const types = @import("types.zig");
const Rect = types.Rect;
const Vec2 = types.Vec2;
const Font = @import("font.zig").Font;
const Icon = @import("font.zig").Icon;
const Canvas = @import("canvas.zig").Canvas;
const primitives = @import("components/primitives.zig");
const ColorEditor = @import("components/color_editor.zig").ColorEditor;

pub const Insets = struct { left: f32 = 0, right: f32 = 0, top: f32 = 0, bottom: f32 = 0 };
pub const Style = struct {
    direction: enum { column, row } = .column,
    /// Main-axis distribution of leftover space when no child grows.
    justify: enum { start, center, end, space_between } = .start,
    /// Rows only: children that do not fit move to a new line (flex-wrap).
    wrap: bool = false,
    /// Grid with this many equal columns; children fill it row by row and stretch to the cell.
    columns: u16 = 0,
    /// Right-to-left: rows run from the right and `start` aligns right. Null inherits.
    rtl: ?bool = null,
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: f32 = 0,
    min_height: f32 = 0,
    max_width: ?f32 = null,
    max_height: ?f32 = null,
    /// Width over height: the height follows the laid-out width (images). `height` wins if set.
    aspect_ratio: ?f32 = null,
    grow: f32 = 0,
    gap: f32 = 0,
    padding: Insets = .{},
    align_items: enum { start, center, end } = .start,
    overflow: enum { visible, scroll } = .visible,
    z_index: i16 = 0,
};
pub const Overlay = union(enum) {
    anchor: struct { target: *const Element, gap: f32 = 4, side: enum { bottom, right } = .bottom },
    point: Vec2,
    viewport,
};
/// `link` text is muted until hovered, then foreground and underlined.
pub const Text = struct { value: []const u8, size: f32 = 16, tone: enum { foreground, muted } = .foreground, wrap: bool = false, alignment: Canvas.TextAlign = .start, link: bool = false };
pub const Paint = union(enum) {
    none,
    card,
    separator,
    text: Text,
    badge: struct { label: []const u8, variant: @import("components/badge.zig").Variant = .default },
    button: struct { label: []const u8, variant: @import("components/button.zig").Variant = .default, hot: bool = false },
    checkbox: struct { label: []const u8, checked: bool = false },
    toggle: struct { label: []const u8, enabled: bool = false },
    slider: struct { value: f32 = 0 },
    scrollbar: struct { state: *ScrollState, axis: ScrollState.Axis },
    input: primitives.Input,
    radio: primitives.Radio,
    progress: f32,
    skeleton,
    animated_skeleton: f32,
    spinner: f32,
    avatar: []const u8,
    icon: Icon,
    tab: primitives.Tab,
    toggle_button: primitives.ToggleButton,
    surface: primitives.Surface,
    alert: primitives.Alert,
    bar_chart: []const f32,
    menu_item: primitives.MenuItem,
    disclosure: struct { label: []const u8, open: bool = false },
    bubble: primitives.Bubble,
    /// Accent background while the pointer is over this element (links, list rows).
    hover,
    color_wheel: ColorEditor,
    color_channel: struct { editor: ColorEditor, channel: @import("components/color_editor.zig").Channel, label: []const u8 = "" },
    swatch: struct { color: types.Color, alpha: f32 = 1 },
    backdrop,
    /// A color-atlas sprite, such as the current frame of an `Image`.
    image: @import("font.zig").Glyph,
    custom: struct {
        context: *const anyopaque,
        measure: ?*const fn (*const anyopaque, f32, *const Font) f32 = null,
        draw: *const fn (*const anyopaque, *Canvas, Rect) anyerror!void,
    },
};

pub const ScrollState = @import("scroll.zig").ScrollState;

pub const Accessibility = struct {
    pub const Role = enum { group, region, log, label, heading, button, checkbox, switch_control, slider, input, radio, radio_group, progress, tab, tab_list, tab_panel, image, alert, status, tooltip, dialog, alert_dialog, menu, menu_item, table, row, cell, column_header, ignored };
    role: ?Role = null,
    label: ?[]const u8 = null,
    description: ?[]const u8 = null,
    described_by: ?u32 = null,
    controls: ?u32 = null,
    numeric_value: ?f32 = null,
    expanded: ?bool = null,
    modal: bool = false,
    live: enum { off, polite, assertive } = .off,
    disabled: bool = false,
};

pub const Element = struct {
    id: u32 = 0,
    style: Style = .{},
    paint_kind: Paint = .none,
    accessibility: Accessibility = .{},
    children: []const *Element = &.{},
    paint_order: []const usize = &.{},
    overlay: ?Overlay = null,
    has_overlays: bool = false,
    scroll: ?*ScrollState = null,
    bounds: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    clip: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Resolved from `style.rtl` and the parent during layout.
    rtl: bool = false,
    /// Pointer shape over this element; null picks one from what it is (see `cursorFor`).
    cursor: ?@import("input.zig").Cursor = null,
    natural_width: ?f32 = null,
    measured_height_width: ?f32 = null,
    measured_height: f32 = 0,

    pub fn find(self: *const Element, id: u32) ?*const Element {
        if (self.id == id and id != 0) return self;
        for (self.children) |child| if (child.find(id)) |found| return found;
        return null;
    }
    pub fn hit(self: *const Element, id: u32, x: f32, y: f32) bool {
        const found = self.find(id) orelse return false;
        return found.bounds.intersection(found.clip).contains(x, y);
    }
    pub fn actionable(self: *const Element) bool {
        if (self.id == 0 or self.accessibility.disabled) return false;
        if (self.paint_kind == .input and self.paint_kind.input.disabled) return false;
        const role = self.accessibility.role orelse switch (self.paint_kind) {
            .button, .toggle_button, .disclosure => Accessibility.Role.button,
            .menu_item => |item| if (item.heading) return false else Accessibility.Role.menu_item,
            .checkbox => Accessibility.Role.checkbox,
            .toggle => Accessibility.Role.switch_control,
            .slider, .color_wheel, .color_channel => Accessibility.Role.slider,
            .input => Accessibility.Role.input,
            .tab => Accessibility.Role.tab,
            else => return false,
        };
        return switch (role) {
            .button, .checkbox, .switch_control, .slider, .input, .radio, .tab, .menu_item, .column_header => true,
            else => false,
        };
    }
    /// The pointer shape to show over this element: its own `cursor`, else a hand for
    /// clickable things, an I-beam for text fields, a crosshair for the color wheel, and
    /// "not allowed" for disabled controls.
    pub fn cursorFor(self: *const Element) @import("input.zig").Cursor {
        if (self.cursor) |c| return c;
        if (self.accessibility.disabled) return .not_allowed;
        return switch (self.paint_kind) {
            .input => |i| if (i.disabled) .not_allowed else .text,
            .color_wheel => .crosshair,
            .menu_item => |m| if (m.disabled) .not_allowed else if (m.heading) .default else .pointer,
            .text => |t| if (t.link and self.id != 0) .pointer else .default,
            else => if (self.actionable()) .pointer else .default,
        };
    }
    pub fn scrollAt(self: *const Element, x: f32, y: f32) ?*ScrollState {
        var above: ?i16 = null;
        while (self.overlayLayerBefore(above)) |z| {
            if (self.scrollOverlayLayerAt(x, y, z)) |state| return state;
            above = z;
        }
        return self.scrollBaseAt(x, y);
    }
    fn scrollBaseAt(self: *const Element, x: f32, y: f32) ?*ScrollState {
        if (self.overlay != null) return null;
        return self.scrollSubtreeAt(x, y);
    }
    fn scrollSubtreeAt(self: *const Element, x: f32, y: f32) ?*ScrollState {
        const within = self.bounds.intersection(self.clip).contains(x, y);
        if (!within and !self.has_overlays) return null;
        var i = self.children.len;
        while (i > 0) {
            i -= 1;
            const child = self.paintChild(i);
            if (self.overlay != null) {
                if (child.scrollSubtreeAt(x, y)) |state| return state;
            } else if (child.scrollBaseAt(x, y)) |state| return state;
        }
        return if (within) self.scroll else null;
    }
    fn overlayLayerBefore(self: *const Element, above: ?i16) ?i16 {
        if (self.overlay != null) return if (above == null or self.style.z_index < above.?) self.style.z_index else null;
        var layer: ?i16 = null;
        for (self.children) |child| {
            if (child.overlayLayerBefore(above)) |z| layer = if (layer) |current| @max(current, z) else z;
        }
        return layer;
    }
    fn scrollOverlayLayerAt(self: *const Element, x: f32, y: f32, z: i16) ?*ScrollState {
        if (self.overlay != null) return if (self.style.z_index == z) self.scrollSubtreeAt(x, y) else null;
        var i = self.children.len;
        while (i > 0) {
            i -= 1;
            if (self.paintChild(i).scrollOverlayLayerAt(x, y, z)) |state| return state;
        }
        return null;
    }
    pub fn paintChild(self: *const Element, index: usize) *Element {
        return self.children[if (self.paint_order.len == 0) index else self.paint_order[index]];
    }
    pub fn layout(self: *Element, viewport: Rect, font: *const Font) void {
        clearMeasurements(self);
        place(self, viewport, viewport, font, false);
    }
    /// Outline what pointer hit-testing sees (bounds within clip) for every actionable element.
    pub fn drawHitboxes(self: *const Element, c: *Canvas) !void {
        const previous = c.clip;
        c.clip = null;
        defer c.clip = previous;
        if (self.actionable()) {
            const r = self.bounds.intersection(self.clip);
            if (r.w > 0 and r.h > 0) {
                try c.rectAlpha(r, .{ 1, 0, 0 }, 0.12);
                try c.outline(r, .{ 1, 0, 0 });
            }
        }
        for (self.children) |child| try child.drawHitboxes(c);
    }
    pub fn render(self: *Element, viewport: Rect, c: *Canvas) !void {
        self.layout(viewport, c.font);
        try self.draw(c);
    }
    pub fn draw(self: *const Element, c: *Canvas) !void {
        return self.drawBase(c, false);
    }
    pub fn drawWithoutOverlays(self: *const Element, c: *Canvas) !void {
        return self.drawBase(c, true);
    }
    pub fn drawOverlays(self: *const Element, c: *Canvas) !void {
        var after: ?i16 = null;
        while (self.overlayLayerAfter(after)) |z| {
            try self.drawOverlayLayer(c, z);
            after = z;
        }
    }
    pub fn overlayLayerAfter(self: *const Element, after: ?i16) ?i16 {
        if (self.overlay != null) {
            return if (after == null or self.style.z_index > after.?) self.style.z_index else null;
        }
        var next_layer: ?i16 = null;
        for (self.children) |child| {
            if (child.overlayLayerAfter(after)) |z| next_layer = if (next_layer) |current| @min(current, z) else z;
        }
        return next_layer;
    }
    fn drawOverlayLayer(self: *const Element, c: *Canvas, z: i16) !void {
        if (self.overlay != null) {
            if (self.style.z_index == z) try self.draw(c);
            return;
        }
        for (0..self.children.len) |i| try self.paintChild(i).drawOverlayLayer(c, z);
    }
    fn drawBase(self: *const Element, c: *Canvas, skip_overlays: bool) !void {
        if (skip_overlays and self.overlay != null) return;
        const previous = c.clip;
        c.clip = self.clip;
        defer c.clip = previous;
        const previous_foreground = c.theme.foreground;
        defer c.theme.foreground = previous_foreground;
        const visible = self.bounds.intersection(self.clip);
        if ((visible.w <= 0 or visible.h <= 0) and self.paint_kind != .card and self.paint_kind != .surface) {
            for (0..self.children.len) |i| try self.paintChild(i).drawBase(c, skip_overlays);
            return;
        }
        switch (self.paint_kind) {
            .none => {},
            .card => {
                try @import("components/card.zig").draw(c, self.bounds);
                c.theme.foreground = c.theme.card_foreground;
            },
            .separator => try c.rect(self.bounds, c.theme.border),
            .text => |t| {
                const padding = self.style.padding;
                const text_bounds = Rect{
                    .x = self.bounds.x + padding.left,
                    .y = self.bounds.y + padding.top,
                    .w = @max(0, self.bounds.w - padding.left - padding.right),
                    .h = @max(0, self.bounds.h - padding.top - padding.bottom),
                };
                c.clip = self.clip.intersection(text_bounds);
                const hot = t.link and self.id != 0 and self.id == c.hot_id;
                const color = if (t.tone == .muted and !hot) c.theme.muted_foreground else c.theme.foreground;
                const alignment: Canvas.TextAlign = if (!self.rtl) t.alignment else switch (t.alignment) {
                    .start => .end,
                    .center => .center,
                    .end => .start,
                };
                if (t.wrap) try c.textWrappedInAligned(text_bounds, t.value, t.size, color, alignment) else try c.textIn(text_bounds, t.value, t.size, color, alignment);
                if (hot) {
                    const ink = c.font.inkBounds(t.value, t.size);
                    const x = switch (alignment) {
                        .start => text_bounds.x,
                        .center => text_bounds.center().x - ink.w / 2,
                        .end => text_bounds.x + text_bounds.w - ink.w,
                    };
                    try c.rect(.{ .x = x, .y = text_bounds.center().y + ink.h / 2 + 2, .w = ink.w, .h = 1 }, color);
                }
                c.clip = self.clip;
            },
            .badge => |b| try @import("components/badge.zig").draw(c, self.bounds, b.label, b.variant),
            .button => |b| try @import("components/button.zig").draw(c, self.bounds, b.label, b.variant, b.hot or (self.id != 0 and self.id == c.hot_id)),
            .checkbox => |b| try @import("components/checkbox.zig").draw(c, self.bounds, b.label, b.checked),
            .toggle => |b| try @import("components/toggle.zig").draw(c, self.bounds, b.label, b.enabled),
            .slider => |s| try @import("components/slider.zig").draw(c, self.bounds, s.value),
            .scrollbar => |bar| try bar.state.drawBar(c, bar.axis),
            .input => |value| try primitives.drawInput(c, self.bounds, value),
            .radio => |value| try primitives.drawRadio(c, self.bounds, value),
            .progress => |value| try primitives.drawProgress(c, self.bounds, value),
            .skeleton => try primitives.drawSkeleton(c, self.bounds),
            .animated_skeleton => |phase| try primitives.drawAnimatedSkeleton(c, self.bounds, phase),
            .spinner => |phase| try primitives.drawSpinner(c, self.bounds, phase),
            .avatar => |initials| try primitives.drawAvatar(c, self.bounds, initials),
            .icon => |icon| try c.icon(self.bounds, icon, c.theme.foreground),
            .tab => |value| try primitives.drawTab(c, self.bounds, value),
            .toggle_button => |value| try primitives.drawToggleButton(c, self.bounds, value),
            .surface => |surface| {
                try primitives.drawSurface(c, self.bounds, surface);
                c.theme.foreground = switch (surface) {
                    .card => c.theme.card_foreground,
                    .tooltip => c.theme.background,
                    .sidebar, .track => previous_foreground,
                    else => c.theme.popover_foreground,
                };
            },
            .alert => |value| try primitives.drawAlert(c, self.bounds, value),
            .bar_chart => |values| try primitives.drawBarChart(c, self.bounds, values),
            .menu_item => |item| {
                var value = item;
                value.hot = item.hot or (self.id != 0 and self.id == c.hot_id);
                try primitives.drawMenuItem(c, self.bounds, value);
            },
            .disclosure => |d| try primitives.drawDisclosure(c, self.bounds, d.label, d.open, self.id != 0 and self.id == c.hot_id),
            .bubble => |variant| {
                try primitives.drawBubble(c, self.bounds, variant);
                c.theme.foreground = primitives.bubbleForeground(c.theme, variant);
            },
            .hover => if (self.id != 0 and self.id == c.hot_id) try c.roundRect(self.bounds, c.theme.accent, c.theme.radiusMd()),
            .color_wheel => |editor| try @import("components/color_editor.zig").drawWheel(c, self.bounds, editor),
            .color_channel => |slider| try @import("components/color_editor.zig").drawChannel(c, self.bounds, slider.editor, slider.channel, slider.label),
            .swatch => |swatch| try @import("components/color_editor.zig").drawSwatch(c, self.bounds, swatch.color, swatch.alpha),
            .backdrop => try c.rectAlpha(self.bounds, .{ 0, 0, 0 }, 0.45),
            .image => |sprite| try c.image(self.bounds, sprite, 1),
            .custom => |custom| try custom.draw(custom.context, c, self.bounds),
        }
        for (0..self.children.len) |i| try self.paintChild(i).drawBase(c, skip_overlays);
        if (self.scroll) |scroll| if (scroll.overlay_bar) {
            c.clip = self.clip.intersection(self.bounds);
            try scroll.drawBar(c, .vertical);
            try scroll.drawBar(c, .horizontal);
            c.clip = self.clip;
        };
        // After the children so the ring stays visible on any background.
        if (self.id != 0 and self.id == c.focus_id) {
            const round = switch (self.paint_kind) {
                .radio, .avatar, .spinner, .color_wheel => @min(self.bounds.w, self.bounds.h) / 2,
                else => c.theme.radiusMd(),
            };
            try primitives.focusRing(c, self.bounds, round, c.theme.ring);
        }
    }
};

fn clearMeasurements(node: *Element) void {
    node.natural_width = null;
    node.measured_height_width = null;
    for (node.children) |child| clearMeasurements(child);
}

pub const Builder = struct {
    allocator: std.mem.Allocator,
    pub fn node(self: Builder, id: u32, style: Style, paint_kind: Paint, children: []const *Element) !*Element {
        const result = try self.allocator.create(Element);
        errdefer self.allocator.destroy(result);
        result.* = .{ .id = id, .style = style, .paint_kind = paint_kind, .children = if (children.len == 0) &.{} else try self.allocator.dupe(*Element, children) };
        for (children) |child| result.has_overlays = result.has_overlays or child.overlay != null or child.has_overlays;
        if (children.len > 1) {
            var ordered = false;
            for (children) |child| if (child.style.z_index != 0) {
                ordered = true;
                break;
            };
            if (ordered) {
                const order = try self.allocator.alloc(usize, children.len);
                for (order, 0..) |*slot, i| {
                    slot.* = i;
                    var j = i;
                    while (j > 0 and children[order[j - 1]].style.z_index > children[order[j]].style.z_index) : (j -= 1) {
                        std.mem.swap(usize, &order[j - 1], &order[j]);
                    }
                }
                result.paint_order = order;
            }
        }
        return result;
    }
    pub fn text(self: Builder, value: []const u8) !*Element {
        return self.node(0, .{}, .{ .text = .{ .value = value } }, &.{});
    }
    pub fn row(self: Builder, children: []const *Element) !*Element {
        return self.node(0, .{ .direction = .row }, .none, children);
    }
    pub fn column(self: Builder, children: []const *Element) !*Element {
        return self.node(0, .{}, .none, children);
    }
    pub fn card(self: Builder, children: []const *Element) !*Element {
        return self.node(0, .{ .padding = .{ .left = 24, .right = 24, .top = 24, .bottom = 24 }, .gap = 12 }, .card, children);
    }
    pub fn button(self: Builder, id: u32, label_text: []const u8) !*Element {
        return self.node(id, .{ .width = 120, .height = 40 }, .{ .button = .{ .label = label_text } }, &.{});
    }
    pub fn buttonVariant(self: Builder, id: u32, label_text: []const u8, variant: @import("components/button.zig").Variant) !*Element {
        return self.node(id, .{ .width = 120, .height = 40 }, .{ .button = .{ .label = label_text, .variant = variant } }, &.{});
    }
    pub fn label(self: Builder, value: []const u8) !*Element {
        return self.text(value);
    }
    pub fn separator(self: Builder) !*Element {
        return self.node(0, .{ .height = 1 }, .separator, &.{});
    }
    pub fn input(self: Builder, id: u32, opts: primitives.Input) !*Element {
        return self.node(id, .{ .height = 40 }, .{ .input = opts }, &.{});
    }
    pub fn textarea(self: Builder, id: u32, opts: primitives.Input) !*Element {
        var value = opts;
        value.multiline = true;
        return self.node(id, .{ .height = 96 }, .{ .input = value }, &.{});
    }
    /// The circle carries `id`, so it alone is the hit target and focus ring.
    pub fn radio(self: Builder, id: u32, label_text: []const u8, checked: bool) !*Element {
        const circle = try self.node(id, .{ .width = 20, .height = 20 }, .{ .radio = .{ .checked = checked } }, &.{});
        circle.accessibility = .{ .role = .radio, .label = label_text };
        const result = try self.node(0, .{ .direction = .row, .height = 32, .gap = 10, .align_items = .center }, .none, &.{
            circle,
            try self.node(0, .{ .grow = 1 }, .{ .text = .{ .value = label_text } }, &.{}),
        });
        result.children[1].accessibility.role = .ignored;
        return result;
    }
    pub fn progress(self: Builder, value: f32) !*Element {
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidProgress;
        return self.node(0, .{ .height = 16 }, .{ .progress = value }, &.{});
    }
    pub fn skeleton(self: Builder, width: f32, height: f32) !*Element {
        if (!std.math.isFinite(width) or !std.math.isFinite(height) or width <= 0 or height <= 0) return error.InvalidSize;
        return self.node(0, .{ .width = width, .height = height }, .skeleton, &.{});
    }
    pub fn animatedSkeleton(self: Builder, width: f32, height: f32, phase: f32) !*Element {
        if (!std.math.isFinite(width) or !std.math.isFinite(height) or width <= 0 or height <= 0 or !std.math.isFinite(phase) or phase < 0 or phase > 1) return error.InvalidSize;
        return self.node(0, .{ .width = width, .height = height }, .{ .animated_skeleton = phase }, &.{});
    }
    pub fn spinner(self: Builder, phase: f32) !*Element {
        if (!std.math.isFinite(phase) or phase < 0 or phase > 1) return error.InvalidPhase;
        return self.node(0, .{ .width = 24, .height = 24 }, .{ .spinner = phase }, &.{});
    }
    pub fn avatar(self: Builder, initials: []const u8) !*Element {
        return self.node(0, .{ .width = 40, .height = 40 }, .{ .avatar = initials }, &.{});
    }
    pub fn icon(self: Builder, value: Icon) !*Element {
        const result = try self.node(0, .{ .width = 24, .height = 24 }, .{ .icon = value }, &.{});
        result.accessibility.role = .ignored;
        return result;
    }
    pub fn tab(self: Builder, id: u32, label_text: []const u8, selected: bool) !*Element {
        return self.node(id, .{ .height = 36, .min_width = 72, .grow = 1 }, .{ .tab = .{ .label = label_text, .selected = selected } }, &.{});
    }
    pub fn toggleButton(self: Builder, id: u32, label_text: []const u8, pressed: bool) !*Element {
        return self.node(id, .{ .width = 100, .height = 36 }, .{ .toggle_button = .{ .label = label_text, .pressed = pressed } }, &.{});
    }
    pub fn surface(self: Builder, kind: primitives.Surface, children: []const *Element) !*Element {
        return self.node(0, .{ .gap = 12, .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 } }, .{ .surface = kind }, children);
    }
    pub fn alert(self: Builder, opts: primitives.Alert) !*Element {
        return self.node(0, .{ .height = 80 }, .{ .alert = opts }, &.{});
    }
    pub fn chart(self: Builder, values: []const f32) !*Element {
        if (values.len == 0) return error.EmptyChart;
        for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidChartValue;
        return self.node(0, .{ .height = 160 }, .{ .bar_chart = values }, &.{});
    }
};

test "simple builder retains advanced styling and interaction" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = Builder{ .allocator = arena.allocator() };
    const action = try b.button(7, "Save");
    const root = try b.card(&.{ try b.text("Preferences"), try b.row(&.{action}) });
    var vertices: [1024]types.Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    canvas.theme.card_foreground = .{ 1, 0, 0 };
    try root.render(.{ .x = 0, .y = 0, .w = 240, .h = 140 }, &canvas);
    try std.testing.expect(root.hit(7, action.bounds.x + 1, action.bounds.y + 1));
    try std.testing.expect(canvas.len > 0);
    var found_card_text = false;
    for (canvas.items()) |vertex| {
        if (vertex.color[0] == 1 and vertex.color[1] == 0 and vertex.color[2] == 0) found_card_text = true;
    }
    try std.testing.expect(found_card_text);
    try std.testing.expectEqual((types.Theme{}).foreground, canvas.theme.foreground);
}

/// Never wider than `available`: a fixed or minimum width gives way to a narrower container
/// rather than spilling out of it (rows that scroll ask with their full content width).
fn widthFor(style: Style, available: f32) f32 {
    const wanted = @max(style.min_width, @min(style.max_width orelse std.math.inf(f32), style.width orelse available));
    return @max(0, @min(available, wanted));
}
fn naturalWidth(node: *Element, font: *const Font) f32 {
    if (node.natural_width) |width| return width;
    if (node.style.width) |width| return widthFor(node.style, width);
    var width: f32 = 0;
    if (node.children.len > 0) {
        var count: usize = 0;
        for (node.children) |child| {
            if (child.overlay != null) continue;
            count += 1;
            const child_width = naturalWidth(child, font);
            if (node.style.direction == .row) {
                width += child_width;
            } else {
                width = @max(width, child_width);
            }
        }
        if (node.style.direction == .row) width += @as(f32, @floatFromInt(count -| 1)) * node.style.gap;
    } else switch (node.paint_kind) {
        .text => |t| width = font.measure(t.value, t.size),
        // ponytail: measures at the default theme's text sizes; pass explicit widths for custom themes.
        .button => |b| width = font.measure(b.label, 14) + 32,
        .badge => |b| width = font.measure(b.label, 13) + 20,
        .menu_item => |item| width = font.measure(item.label, 14) + font.measure(item.shortcut, 13) + 64,
        .toggle_button => |t| width = font.measure(t.label, 14) + 24,
        .tab => |t| width = font.measure(t.label, 14) + 24,
        else => {},
    }
    const result = widthFor(node.style, @max(node.style.min_width, width + node.style.padding.left + node.style.padding.right));
    node.natural_width = result;
    return result;
}
fn rowWidth(parent: *Element, child: *Element, inner_width: f32, font: *const Font) f32 {
    var basis: f32 = 0;
    var grows: f32 = 0;
    for (parent.children) |other| {
        if (other.overlay != null) continue;
        basis += naturalWidth(other, font);
        if (other.style.width == null) grows += other.style.grow;
    }
    var flow_count: usize = 0;
    for (parent.children) |other| if (other.overlay == null) {
        flow_count += 1;
    };
    basis += @as(f32, @floatFromInt(flow_count -| 1)) * parent.style.gap;
    // A scrolling row keeps natural widths and scrolls; any other row shrinks growing children to fit.
    const extra = if (parent.style.overflow == .scroll) @max(0, inner_width - basis) else inner_width - basis;
    // Growing children share leftover space, and give it back (flex-shrink) when the row overflows.
    const proposed = naturalWidth(child, font) + (if (child.style.width == null and grows > 0) extra * child.style.grow / grows else 0);
    return widthFor(child.style, @max(0, proposed));
}
fn cellWidth(node: *const Element, inner_width: f32) f32 {
    const columns: f32 = @floatFromInt(node.style.columns);
    return @max(0, (inner_width - (columns - 1) * node.style.gap) / columns);
}
/// Grid rows and wrapped lines: flow children `start..end` share one line of height `h`.
const Line = struct { start: usize, end: usize, h: f32, w: f32 };
fn nextLine(node: *Element, start: usize, inner_width: f32, font: *const Font) ?Line {
    var line = Line{ .start = start, .end = start, .h = 0, .w = 0 };
    var count: usize = 0;
    while (line.end < node.children.len) : (line.end += 1) {
        const child = node.children[line.end];
        if (child.overlay != null) continue;
        const width = if (node.style.columns > 0) widthFor(child.style, cellWidth(node, inner_width)) else @min(inner_width, naturalWidth(child, font));
        if (node.style.columns > 0 and count == node.style.columns) break;
        if (node.style.columns == 0 and count > 0 and line.w + node.style.gap + width > inner_width) break;
        line.w += (if (count > 0) node.style.gap else 0) + width;
        line.h = @max(line.h, estimatedHeight(child, width, font));
        count += 1;
    }
    return if (count == 0) null else line;
}
fn linesHeight(node: *Element, inner_width: f32, font: *const Font) f32 {
    var height: f32 = 0;
    var start: usize = 0;
    var count: usize = 0;
    while (nextLine(node, start, inner_width, font)) |line| : (start = line.end) {
        height += line.h;
        count += 1;
    }
    return height + @as(f32, @floatFromInt(count -| 1)) * node.style.gap;
}
fn lined(node: *const Element) bool {
    return node.style.columns > 0 or (node.style.direction == .row and node.style.wrap);
}
fn estimatedHeight(node: *Element, width: f32, font: *const Font) f32 {
    if (node.style.height) |height| return height;
    if (node.style.aspect_ratio) |ratio| if (ratio > 0) return width / ratio;
    if (node.measured_height_width == width) return node.measured_height;
    const inner_width = @max(0, width - node.style.padding.left - node.style.padding.right);
    var height: f32 = 0;
    if (node.children.len > 0) {
        if (lined(node)) {
            height = linesHeight(node, inner_width, font);
        } else if (node.style.direction == .column) {
            var flow_count: usize = 0;
            for (node.children) |child| {
                if (child.overlay != null) continue;
                flow_count += 1;
                height += estimatedHeight(child, widthFor(child.style, inner_width), font);
            }
            height += @as(f32, @floatFromInt(flow_count -| 1)) * node.style.gap;
        } else {
            for (node.children) |child| {
                if (child.overlay != null) continue;
                height = @max(height, estimatedHeight(child, rowWidth(node, child, inner_width, font), font));
            }
        }
    } else {
        switch (node.paint_kind) {
            .text => |t| height = if (t.wrap) font.wrappedHeight(t.value, t.size, inner_width) else t.size * 1.35,
            .custom => |custom| if (custom.measure) |measure| {
                height = measure(custom.context, inner_width, font);
            },
            else => {},
        }
    }
    node.measured_height = @max(node.style.min_height, @min(node.style.max_height orelse std.math.inf(f32), height + node.style.padding.top + node.style.padding.bottom));
    node.measured_height_width = width;
    return node.measured_height;
}
/// Leading offset and extra gap that `justify` gives `free` space shared by `count` children.
fn justified(node: *const Element, free: f32, count: usize) [2]f32 {
    if (free <= 0) return .{ 0, 0 };
    return switch (node.style.justify) {
        .start => .{ 0, 0 },
        .center => .{ free / 2, 0 },
        .end => .{ free, 0 },
        .space_between => .{ 0, if (count > 1) free / @as(f32, @floatFromInt(count - 1)) else 0 },
    };
}
fn place(node: *Element, r: Rect, inherited_clip: Rect, font: *const Font, inherited_rtl: bool) void {
    node.bounds = r;
    node.clip = inherited_clip;
    node.rtl = node.style.rtl orelse inherited_rtl;
    switch (node.paint_kind) {
        .scrollbar => |bar| switch (bar.axis) {
            .vertical => bar.state.vertical_bar = r,
            .horizontal => bar.state.horizontal_bar = r,
        },
        else => {},
    }
    const p = node.style.padding;
    const inner_width = @max(0, r.w - p.left - p.right);
    const inner_height = @max(0, r.h - p.top - p.bottom);
    var content_width: f32 = p.left + p.right;
    var content_height: f32 = p.top + p.bottom;
    var flow_count: usize = 0;
    var row_used: f32 = 0;
    if (node.children.len > 0) {
        if (lined(node)) {
            content_width = r.w;
            content_height += linesHeight(node, inner_width, font);
        } else if (node.style.direction == .column) {
            for (node.children) |child| {
                if (child.overlay != null) continue;
                flow_count += 1;
                const width = widthFor(child.style, inner_width);
                content_width = @max(content_width, width + p.left + p.right);
                content_height += estimatedHeight(child, width, font);
            }
            content_height += @as(f32, @floatFromInt(flow_count -| 1)) * node.style.gap;
        } else {
            for (node.children) |child| {
                if (child.overlay != null) continue;
                flow_count += 1;
                const width = rowWidth(node, child, inner_width, font);
                row_used += width;
                content_height = @max(content_height, estimatedHeight(child, width, font) + p.top + p.bottom);
            }
            row_used += @as(f32, @floatFromInt(flow_count -| 1)) * node.style.gap;
            content_width += row_used;
        }
    }
    if (node.scroll) |scroll| {
        scroll.updateLayout(r, Vec2.init(content_width, content_height));
    }
    const dx: f32 = if (node.scroll) |scroll| scroll.offset.x else 0;
    const dy: f32 = if (node.scroll) |scroll| scroll.offset.y else 0;
    const child_clip = if (node.style.overflow == .scroll) inherited_clip.intersection(r) else inherited_clip;
    const left = r.x + p.left;
    // Children are placed left to right, then mirrored inside the content box for RTL.
    const Placer = struct {
        fn put(parent: *Element, child: *Element, rect: Rect, clip: Rect, f: *const Font, box_left: f32, box_width: f32) void {
            var at = rect;
            if (parent.rtl) at.x = 2 * box_left + box_width - rect.x - rect.w;
            place(child, at, clip, f, parent.rtl);
        }
    };
    if (lined(node)) {
        var start: usize = 0;
        var y = r.y + p.top - dy;
        while (nextLine(node, start, inner_width, font)) |line| : (start = line.end) {
            const offsets = if (node.style.columns > 0) [2]f32{ 0, 0 } else justified(node, inner_width - line.w, line.end - line.start);
            var x = left + offsets[0] - dx;
            for (node.children[line.start..line.end]) |child| {
                if (child.overlay != null) continue;
                const width = if (node.style.columns > 0) widthFor(child.style, cellWidth(node, inner_width)) else @min(inner_width, naturalWidth(child, font));
                const height = if (node.style.columns > 0) line.h else estimatedHeight(child, width, font);
                const align_y: f32 = if (node.style.columns > 0) 0 else switch (node.style.align_items) {
                    .start => 0,
                    .center => (line.h - height) / 2,
                    .end => line.h - height,
                };
                Placer.put(node, child, .{ .x = x, .y = y + align_y, .w = width, .h = height }, child_clip, font, left, inner_width);
                x += width + node.style.gap + offsets[1];
            }
            y += line.h + node.style.gap;
        }
    } else if (node.style.direction == .column) {
        var grows: f32 = 0;
        for (node.children) |child| if (child.style.height == null) {
            if (child.overlay == null) grows += child.style.grow;
        };
        const free = if (node.style.overflow == .scroll) 0 else @max(0, r.h - content_height);
        const offsets = if (grows > 0) [2]f32{ 0, 0 } else justified(node, free, flow_count);
        var y = r.y + p.top - dy + offsets[0];
        for (node.children) |child| {
            if (child.overlay != null) continue;
            const width = widthFor(child.style, inner_width);
            const natural = estimatedHeight(child, width, font);
            const height = natural + (if (child.style.height == null and grows > 0) free * child.style.grow / grows else 0);
            const x = left + switch (node.style.align_items) {
                .start => @as(f32, 0),
                .center => @max(0, (inner_width - width) / 2),
                .end => @max(0, inner_width - width),
            } - dx;
            Placer.put(node, child, .{ .x = x, .y = y, .w = width, .h = height }, child_clip, font, left, inner_width);
            y += height + node.style.gap + offsets[1];
        }
    } else {
        const offsets = justified(node, inner_width - row_used, flow_count);
        var x = left - dx + offsets[0];
        for (node.children) |child| {
            if (child.overlay != null) continue;
            const width = rowWidth(node, child, inner_width, font);
            const height = estimatedHeight(child, width, font);
            const align_y: f32 = switch (node.style.align_items) {
                .start => 0,
                .center => @max(0, (inner_height - height) / 2),
                .end => @max(0, inner_height - height),
            };
            Placer.put(node, child, .{ .x = x, .y = r.y + p.top + align_y - dy, .w = width, .h = height }, child_clip, font, left, inner_width);
            x += width + node.style.gap + offsets[1];
        }
    }
    for (0..node.children.len) |i| {
        const child = node.paintChild(i);
        const overlay = child.overlay orelse continue;
        const width = widthFor(child.style, inherited_clip.w);
        const height = estimatedHeight(child, width, font);
        var x: f32 = inherited_clip.x;
        var y: f32 = inherited_clip.y;
        switch (overlay) {
            .anchor => |position| {
                const target = position.target.bounds;
                const anchor_visible = target.intersection(position.target.clip);
                if (anchor_visible.w <= 0 or anchor_visible.h <= 0) {
                    place(child, .{ .x = 0, .y = 0, .w = width, .h = height }, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, font, node.rtl);
                    continue;
                }
                switch (position.side) {
                    .bottom => {
                        x = if (node.rtl) target.x + target.w - width else target.x;
                        y = target.y + target.h + position.gap;
                        if (y + height > inherited_clip.y + inherited_clip.h and target.y - position.gap - height >= inherited_clip.y) {
                            y = target.y - position.gap - height;
                        }
                    },
                    .right => {
                        x = target.x + target.w + position.gap;
                        y = target.y;
                        if (node.rtl or x + width > inherited_clip.x + inherited_clip.w) x = target.x - position.gap - width;
                    },
                }
            },
            .point => |point| {
                x = point.x;
                y = point.y;
            },
            .viewport => {},
        }
        x = std.math.clamp(x, inherited_clip.x, @max(inherited_clip.x, inherited_clip.x + inherited_clip.w - width));
        y = std.math.clamp(y, inherited_clip.y, @max(inherited_clip.y, inherited_clip.y + inherited_clip.h - height));
        place(child, .{ .x = x, .y = y, .w = width, .h = height }, inherited_clip, font, node.rtl);
    }
}

test "grid, wrap, justify and rtl place children" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = Builder{ .allocator = arena.allocator() };
    var cells: [5]*Element = undefined;
    for (&cells, 0..) |*cell, i| cell.* = try b.node(@intCast(i + 1), .{ .height = @floatFromInt(10 + i * 10) }, .none, &.{});
    const grid = try b.node(0, .{ .columns = 3, .gap = 10 }, .none, &cells);
    grid.layout(.{ .x = 0, .y = 0, .w = 320, .h = 200 }, &font);
    try std.testing.expectEqual(@as(f32, 100), cells[0].bounds.w);
    try std.testing.expectEqual(@as(f32, 220), cells[2].bounds.x);
    try std.testing.expectEqual(@as(f32, 30), cells[0].bounds.h); // stretched to the row
    try std.testing.expectEqual(@as(f32, 40), cells[3].bounds.y);
    try std.testing.expectEqual(@as(f32, 40 + 50), estimatedHeight(grid, 320, &font));

    var chips: [3]*Element = undefined;
    for (&chips, 0..) |*chip, i| chip.* = try b.node(@intCast(10 + i), .{ .width = 100, .height = 20 }, .none, &.{});
    const wrapped = try b.node(0, .{ .direction = .row, .wrap = true, .gap = 10, .justify = .end }, .none, &chips);
    wrapped.layout(.{ .x = 0, .y = 0, .w = 250, .h = 100 }, &font);
    try std.testing.expectEqual(@as(f32, 30), chips[2].bounds.y);
    try std.testing.expectEqual(@as(f32, 150), chips[2].bounds.x);
    try std.testing.expectEqual(@as(f32, 30), wrapped.bounds.h - 70 + estimatedHeight(wrapped, 250, &font) - 50);

    const a = try b.node(20, .{ .width = 40, .height = 10 }, .none, &.{});
    const c = try b.node(21, .{ .width = 40, .height = 10 }, .none, &.{});
    const between = try b.node(0, .{ .direction = .row, .justify = .space_between }, .none, &.{ a, c });
    between.layout(.{ .x = 0, .y = 0, .w = 200, .h = 10 }, &font);
    try std.testing.expectEqual(@as(f32, 160), c.bounds.x);
    const mirrored = try b.node(0, .{ .direction = .row, .rtl = true }, .none, &.{ a, c });
    mirrored.layout(.{ .x = 0, .y = 0, .w = 200, .h = 10 }, &font);
    try std.testing.expectEqual(@as(f32, 160), a.bounds.x);
    try std.testing.expectEqual(@as(f32, 120), c.bounds.x);
    try std.testing.expect(a.rtl);
}

test "independent scroll roots clamp and clip children" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = Builder{ .allocator = arena.allocator() };
    const leaf = try b.node(1, .{ .width = 120, .height = 160 }, .none, &.{});
    const inner = try b.node(2, .{ .width = 100, .height = 100, .overflow = .scroll }, .none, &.{leaf});
    var inner_scroll = ScrollState{ .offset = Vec2.init(0, 200) };
    inner.scroll = &inner_scroll;
    const root = try b.node(3, .{ .width = 90, .height = 90, .overflow = .scroll }, .none, &.{inner});
    var outer_scroll = ScrollState{};
    root.scroll = &outer_scroll;
    root.layout(.{ .x = 0, .y = 0, .w = 90, .h = 90 }, &font);
    try std.testing.expectEqual(@as(f32, 60), inner_scroll.offset.y);
    try std.testing.expectEqual(@as(f32, 10), outer_scroll.content.y - outer_scroll.viewport.h);
    try std.testing.expect(!root.hit(1, 50, 95));
    outer_scroll.wheel(0, -1);
    try std.testing.expectEqual(@as(f32, 10), outer_scroll.offset.y);
    try std.testing.expectEqual(@as(f32, 60), inner_scroll.offset.y);
    try std.testing.expectEqual(@as(?*ScrollState, &inner_scroll), root.scrollAt(50, 50));
    try std.testing.expect(root.scrollAt(50, 95) == null);
    root.layout(.{ .x = 0, .y = 0, .w = 120, .h = 120 }, &font);
    try std.testing.expectEqual(@as(?*ScrollState, &outer_scroll), root.scrollAt(110, 110));
}

test "row and column alignment use measured child dimensions" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = Builder{ .allocator = arena.allocator() };
    const a = try b.node(1, .{ .width = 20, .height = 20 }, .none, &.{});
    const c = try b.node(2, .{ .width = 30, .height = 50 }, .none, &.{});
    const row = try b.node(3, .{ .direction = .row, .height = 100, .align_items = .center }, .none, &.{ a, c });
    row.layout(.{ .x = 10, .y = 20, .w = 200, .h = 100 }, &font);
    try std.testing.expectEqual(@as(f32, 20), a.bounds.h);
    try std.testing.expectEqual(@as(f32, 60), a.bounds.y);
    try std.testing.expectEqual(@as(f32, 45), c.bounds.y);
    const col = try b.node(4, .{ .align_items = .end, .width = 200 }, .none, &.{a});
    col.layout(.{ .x = 10, .y = 20, .w = 200, .h = 100 }, &font);
    try std.testing.expectEqual(@as(f32, 190), a.bounds.x);
    const first = try b.text("Some text");
    const second = try b.text(" follows");
    const text_row = try b.row(&.{ first, second });
    text_row.layout(.{ .x = 0, .y = 0, .w = 200, .h = 32 }, &font);
    try std.testing.expectApproxEqAbs(font.measure("Some text", 16), first.bounds.w, 0.01);
    try std.testing.expectApproxEqAbs(first.bounds.x + first.bounds.w, second.bounds.x, 0.01);
}

test "layout caches measurements per pass and remeasures at a new width" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = Builder{ .allocator = arena.allocator() };
    const text = try b.node(1, .{}, .{ .text = .{ .value = "Wrapped text changes height when its width changes", .wrap = true } }, &.{});
    const root = try b.node(0, .{}, .none, &.{text});
    root.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 }, &font);
    const wide_height = text.bounds.h;
    try std.testing.expect(text.measured_height_width != null);
    root.layout(.{ .x = 0, .y = 0, .w = 80, .h = 200 }, &font);
    try std.testing.expect(text.bounds.h > wide_height);
    try std.testing.expectEqual(@as(?f32, 80), text.measured_height_width);
}

test "clipped parent skips its own paint without hiding overflowing children" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = Builder{ .allocator = arena.allocator() };
    const parent = try b.node(1, .{ .width = 20, .height = 20 }, .skeleton, &.{try b.node(2, .{ .width = 10, .height = 10 }, .skeleton, &.{})});
    parent.bounds = .{ .x = -30, .y = 0, .w = 20, .h = 20 };
    parent.clip = .{ .x = 0, .y = 0, .w = 20, .h = 20 };
    parent.children[0].bounds = .{ .x = 4, .y = 4, .w = 10, .h = 10 };
    parent.children[0].clip = parent.clip;
    var vertices: [1024]types.Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    try parent.draw(&canvas);
    try std.testing.expect(canvas.len > 0);
    for (canvas.items()) |vertex| try std.testing.expect(vertex.position[0] >= 0);
}

test "overlay escapes flow, flips at viewport edge, and paints above its trigger" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = Builder{ .allocator = arena.allocator() };
    const trigger = try b.node(1, .{ .height = 30 }, .{ .button = .{ .label = "Options" } }, &.{});
    const panel = try b.node(2, .{ .width = 100, .height = 70, .z_index = 10 }, .{ .surface = .popover }, &.{});
    panel.overlay = .{ .anchor = .{ .target = trigger } };
    const root = try b.node(0, .{ .height = 120 }, .none, &.{
        try b.node(0, .{ .height = 88 }, .none, &.{}),
        trigger,
        panel,
    });
    root.layout(.{ .x = 0, .y = 0, .w = 140, .h = 120 }, &font);
    try std.testing.expectEqual(@as(f32, 88), trigger.bounds.y);
    try std.testing.expect(panel.bounds.y < trigger.bounds.y);
    try std.testing.expectEqual(@as(f32, 100), panel.bounds.w);
    try std.testing.expectEqual(@as(*Element, panel), root.paintChild(root.children.len - 1));
    var vertices: [2000]types.Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    try root.drawWithoutOverlays(&canvas);
    const base_vertices = canvas.len;
    try root.drawOverlays(&canvas);
    try std.testing.expect(canvas.len > base_vertices);
    try std.testing.expect(root.hit(2, panel.bounds.x + 2, panel.bounds.y + 2));
}

test "overlay layers paint globally in z order and scroll outside anchor bounds" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = Builder{ .allocator = arena.allocator() };
    const paint = struct {
        fn draw(context: *const anyopaque, canvas: *Canvas, r: Rect) !void {
            const color: *const types.Color = @ptrCast(@alignCast(context));
            try canvas.rect(r, color.*);
        }
    }.draw;
    const back_color = types.Color{ 1, 0, 0 };
    const front_color = types.Color{ 0, 0, 1 };
    var panel_scroll: ScrollState = .{};
    var back_scroll: ScrollState = .{};
    const front = try b.node(11, .{ .width = 30, .height = 30, .z_index = 200, .overflow = .scroll }, .{ .custom = .{ .context = &front_color, .draw = paint } }, &.{try b.node(0, .{ .height = 90 }, .none, &.{})});
    front.overlay = .{ .point = .init(100, 20) };
    front.scroll = &panel_scroll;
    const back = try b.node(12, .{ .width = 30, .height = 30, .z_index = 100, .overflow = .scroll }, .{ .custom = .{ .context = &back_color, .draw = paint } }, &.{try b.node(0, .{ .height = 90 }, .none, &.{})});
    back.overlay = .{ .point = .init(100, 20) };
    back.scroll = &back_scroll;
    const first = try b.node(0, .{ .width = 40, .height = 40 }, .none, &.{front});
    const second = try b.node(0, .{ .width = 40, .height = 40 }, .none, &.{back});
    const root = try b.node(0, .{ .direction = .row }, .none, &.{ first, second });
    root.layout(.{ .x = 0, .y = 0, .w = 200, .h = 80 }, &font);
    try std.testing.expect(root.scrollAt(110, 25) == &panel_scroll);
    var vertices: [128]types.Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    try root.drawOverlays(&canvas);
    try std.testing.expect(canvas.len >= 12);
    try std.testing.expectEqual(@as(f32, 1), canvas.items()[0].color[0]);
    try std.testing.expectEqual(@as(f32, 1), canvas.items()[canvas.len - 1].color[2]);
}

test "anchored popups disappear when their trigger scrolls fully out of view" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = Builder{ .allocator = arena.allocator() };
    const trigger = try b.button(1, "Options");
    const panel = try b.node(2, .{ .width = 100, .height = 60, .z_index = 10 }, .{ .surface = .menu }, &.{});
    panel.overlay = .{ .anchor = .{ .target = trigger } };
    const container = try b.node(0, .{ .height = 100, .overflow = .scroll }, .none, &.{
        try b.node(0, .{ .height = 160 }, .none, &.{}),
        trigger,
        panel,
    });
    var scroll: ScrollState = .{};
    container.scroll = &scroll;
    container.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, &font);
    try std.testing.expectEqual(@as(f32, 0), panel.clip.h);
    try std.testing.expect(!container.hit(2, 2, 2));
    scroll.offset.y = 140;
    container.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, &font);
    try std.testing.expect(panel.clip.h > 0);
}

test "cursors follow what is under the pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = Builder{ .allocator = arena.allocator() };
    try std.testing.expectEqual(@import("input.zig").Cursor.pointer, (try b.button(1, "Go")).cursorFor());
    try std.testing.expectEqual(@import("input.zig").Cursor.text, (try b.input(2, .{})).cursorFor());
    try std.testing.expectEqual(@import("input.zig").Cursor.not_allowed, (try b.input(3, .{ .disabled = true })).cursorFor());
    try std.testing.expectEqual(@import("input.zig").Cursor.default, (try b.text("Plain")).cursorFor());
    const disabled = try b.button(4, "No");
    disabled.accessibility.disabled = true;
    try std.testing.expectEqual(@import("input.zig").Cursor.not_allowed, disabled.cursorFor());
    const handle = try b.node(5, .{}, .skeleton, &.{});
    handle.cursor = .ew_resize;
    try std.testing.expectEqual(@import("input.zig").Cursor.ew_resize, handle.cursorFor());
}
