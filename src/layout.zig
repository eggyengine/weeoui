//! Frame-local element tree: measure, place, then paint.
const std = @import("std");
const types = @import("types.zig");
const Rect = types.Rect;
const Vec2 = types.Vec2;
const Font = @import("font.zig").Font;
const Icon = @import("font.zig").Icon;
const Canvas = @import("canvas.zig").Canvas;
const primitives = @import("components/primitives.zig");
const color_editor = @import("components/color_editor.zig");
const ColorEditor = color_editor.ColorEditor;
const components = struct {
    const badge = @import("components/badge.zig");
    const button = @import("components/button.zig");
    const card = @import("components/card.zig");
    const checkbox = @import("components/checkbox.zig");
    const slider = @import("components/slider.zig");
    const toggle = @import("components/toggle.zig");
};
const Cursor = @import("input.zig").Cursor;
const flow = @import("flow.zig");
const text_selection = @import("text_selection.zig");

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
    badge: struct { label: []const u8, variant: components.badge.Variant = .default },
    button: struct { label: []const u8, variant: components.button.Variant = .default, hot: bool = false },
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
    color_channel: struct { editor: ColorEditor, channel: color_editor.Channel, label: []const u8 = "" },
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
    cursor: ?Cursor = null,
    natural_width: ?f32 = null,
    measured_height_width: ?f32 = null,
    measured_height: f32 = 0,

    /// The highlighted part of the text element `selection` starts in, if any. It points into
    /// that element's text, so copy it before the tree is freed.
    pub fn selectedText(self: *const Element, selection: types.TextSelection, font: *const Font) ?[]const u8 {
        return text_selection.selectedText(self, selection, font);
    }
    /// Bounds minus padding: where a text element's glyphs go.
    pub fn contentRect(self: *const Element) Rect {
        const padding = self.style.padding;
        return .{
            .x = self.bounds.x + padding.left,
            .y = self.bounds.y + padding.top,
            .w = @max(0, self.bounds.w - padding.left - padding.right),
            .h = @max(0, self.bounds.h - padding.top - padding.bottom),
        };
    }
    /// A text element's alignment with `start` and `end` swapped for right-to-left.
    pub fn textAlignment(self: *const Element) Canvas.TextAlign {
        const alignment = self.paint_kind.text.alignment;
        if (!self.rtl) return alignment;
        return switch (alignment) {
            .start => .end,
            .center => .center,
            .end => .start,
        };
    }

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
    pub fn cursorFor(self: *const Element) Cursor {
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
        flow.layout(self, viewport, font);
    }
    /// The width this element asks for before any growing or shrinking, e.g. to choose a
    /// compact variant when a row would not fit.
    pub fn preferredWidth(self: *Element, font: *const Font) f32 {
        return flow.preferredWidth(self, font);
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
                try components.card.draw(c, self.bounds);
                c.theme.foreground = c.theme.card_foreground;
            },
            .separator => try c.rect(self.bounds, c.theme.border),
            .text => |t| {
                const text_bounds = self.contentRect();
                c.clip = self.clip.intersection(text_bounds);
                if (c.text_selection) |selection| try text_selection.drawHighlight(self, c, selection);
                const hot = t.link and self.id != 0 and self.id == c.hot_id;
                const color = if (t.tone == .muted and !hot) c.theme.muted_foreground else c.theme.foreground;
                const alignment = self.textAlignment();
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
            .badge => |b| try components.badge.draw(c, self.bounds, b.label, b.variant),
            .button => |b| try components.button.draw(c, self.bounds, b.label, b.variant, b.hot or (self.id != 0 and self.id == c.hot_id)),
            .checkbox => |b| try components.checkbox.draw(c, self.bounds, b.label, b.checked),
            .toggle => |b| try components.toggle.draw(c, self.bounds, b.label, b.enabled),
            .slider => |s| try components.slider.draw(c, self.bounds, s.value),
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
            .color_wheel => |editor| try color_editor.drawWheel(c, self.bounds, editor),
            .color_channel => |slider| try color_editor.drawChannel(c, self.bounds, slider.editor, slider.channel, slider.label),
            .swatch => |swatch| try color_editor.drawSwatch(c, self.bounds, swatch.color, swatch.alpha),
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
    pub fn buttonVariant(self: Builder, id: u32, label_text: []const u8, variant: components.button.Variant) !*Element {
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
    try std.testing.expectEqual(Cursor.pointer, (try b.button(1, "Go")).cursorFor());
    try std.testing.expectEqual(Cursor.text, (try b.input(2, .{})).cursorFor());
    try std.testing.expectEqual(Cursor.not_allowed, (try b.input(3, .{ .disabled = true })).cursorFor());
    try std.testing.expectEqual(Cursor.default, (try b.text("Plain")).cursorFor());
    const disabled = try b.button(4, "No");
    disabled.accessibility.disabled = true;
    try std.testing.expectEqual(Cursor.not_allowed, disabled.cursorFor());
    const handle = try b.node(5, .{}, .skeleton, &.{});
    handle.cursor = .ew_resize;
    try std.testing.expectEqual(Cursor.ew_resize, handle.cursorFor());
}
