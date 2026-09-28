//! Frame-local element tree: measure, place, then paint.
const std = @import("std");
const types = @import("types.zig");
const Rect = types.Rect;
const Vec2 = types.Vec2;
const Font = @import("font.zig").Font;
const Icon = @import("font.zig").Icon;
const Canvas = @import("canvas.zig").Canvas;
const primitives = @import("components/primitives.zig");

pub const Insets = struct { left: f32 = 0, right: f32 = 0, top: f32 = 0, bottom: f32 = 0 };
pub const Style = struct {
    direction: enum { column, row } = .column,
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: f32 = 0,
    min_height: f32 = 0,
    max_width: ?f32 = null,
    max_height: ?f32 = null,
    grow: f32 = 0,
    gap: f32 = 0,
    padding: Insets = .{},
    align_items: enum { start, center, end } = .start,
    overflow: enum { visible, scroll } = .visible,
    z_index: i16 = 0,
};
pub const Overlay = union(enum) {
    anchor: struct { target: *const Element, gap: f32 = 4 },
    point: Vec2,
    viewport,
};
pub const Text = struct { value: []const u8, size: f32 = 16, tone: enum { foreground, muted } = .foreground, wrap: bool = false, alignment: Canvas.TextAlign = .start };
pub const Paint = union(enum) {
    none,
    card,
    separator,
    text: Text,
    badge: []const u8,
    button: struct { label: []const u8, primary: bool = true, hot: bool = false, focused: bool = false },
    checkbox: struct { label: []const u8, checked: bool = false, focused: bool = false },
    toggle: struct { label: []const u8, enabled: bool = false, focused: bool = false },
    slider: struct { value: f32 = 0, focused: bool = false },
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
    backdrop,
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
            .button, .toggle_button => Accessibility.Role.button,
            .checkbox => Accessibility.Role.checkbox,
            .toggle => Accessibility.Role.switch_control,
            .slider => Accessibility.Role.slider,
            .input => Accessibility.Role.input,
            .tab => Accessibility.Role.tab,
            else => return false,
        };
        return switch (role) {
            .button, .checkbox, .switch_control, .slider, .input, .radio, .tab, .menu_item, .column_header => true,
            else => false,
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
        place(self, viewport, viewport, font);
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
                const color = if (t.tone == .muted) c.theme.muted_foreground else c.theme.foreground;
                if (t.wrap) try c.textWrappedInAligned(text_bounds, t.value, t.size, color, t.alignment) else try c.textIn(text_bounds, t.value, t.size, color, t.alignment);
                c.clip = self.clip;
            },
            .badge => |label| try @import("components/badge.zig").draw(c, self.bounds, label),
            .button => |b| try @import("components/button.zig").draw(c, self.bounds, b.label, b.primary, b.hot, b.focused),
            .checkbox => |b| try @import("components/checkbox.zig").draw(c, self.bounds, b.label, b.checked, b.focused),
            .toggle => |b| try @import("components/toggle.zig").draw(c, self.bounds, b.label, b.enabled, b.focused),
            .slider => |s| try @import("components/slider.zig").draw(c, self.bounds, s.value, s.focused),
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
                    .tooltip => c.theme.primary_foreground,
                    .sidebar => previous_foreground,
                    else => c.theme.popover_foreground,
                };
            },
            .alert => |value| try primitives.drawAlert(c, self.bounds, value),
            .bar_chart => |values| try primitives.drawBarChart(c, self.bounds, values),
            .backdrop => try c.rectAlpha(self.bounds, .{ 0, 0, 0 }, 0.45),
            .custom => |custom| try custom.draw(custom.context, c, self.bounds),
        }
        for (0..self.children.len) |i| try self.paintChild(i).drawBase(c, skip_overlays);
        if (self.scroll) |scroll| if (scroll.overlay_bar) {
            c.clip = self.clip.intersection(self.bounds);
            try scroll.drawBar(c, .vertical);
        };
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
    pub fn radio(self: Builder, id: u32, label_text: []const u8, checked: bool) !*Element {
        const result = try self.node(id, .{ .direction = .row, .height = 32, .gap = 10, .align_items = .center }, .none, &.{
            try self.node(0, .{ .width = 20, .height = 20 }, .{ .radio = .{ .checked = checked } }, &.{}),
            try self.node(0, .{ .grow = 1 }, .{ .text = .{ .value = label_text } }, &.{}),
        });
        result.accessibility = .{ .role = .radio, .label = label_text };
        result.children[0].accessibility.role = .ignored;
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
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = Builder{ .allocator = arena.allocator() };
    const action = try b.button(7, "Save");
    action.paint_kind.button.focused = true;
    const root = try b.card(&.{ try b.text("Preferences"), try b.row(&.{action}) });
    var vertices: [1024]types.Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    canvas.theme.card_foreground = .{ 1, 0, 0 };
    try root.render(.{ .x = 0, .y = 0, .w = 240, .h = 140 }, &canvas);
    try std.testing.expect(root.hit(7, action.bounds.x + 1, action.bounds.y + 1));
    try std.testing.expect(action.paint_kind.button.focused);
    try std.testing.expect(canvas.len > 0);
    var found_card_text = false;
    for (canvas.items()) |vertex| {
        if (vertex.color[0] == 1 and vertex.color[1] == 0 and vertex.color[2] == 0) found_card_text = true;
    }
    try std.testing.expect(found_card_text);
    try std.testing.expectEqual((types.Theme{}).foreground, canvas.theme.foreground);
}

fn widthFor(style: Style, available: f32) f32 {
    return @max(style.min_width, @min(style.max_width orelse std.math.inf(f32), style.width orelse available));
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
    const extra = @max(0, inner_width - basis);
    const proposed = naturalWidth(child, font) + (if (child.style.width == null and grows > 0) extra * child.style.grow / grows else 0);
    return widthFor(child.style, proposed);
}
fn estimatedHeight(node: *Element, width: f32, font: *const Font) f32 {
    if (node.style.height) |height| return height;
    if (node.measured_height_width == width) return node.measured_height;
    const inner_width = @max(0, width - node.style.padding.left - node.style.padding.right);
    var height: f32 = 0;
    if (node.children.len > 0) {
        if (node.style.direction == .column) {
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
fn place(node: *Element, r: Rect, inherited_clip: Rect, font: *const Font) void {
    node.bounds = r;
    node.clip = inherited_clip;
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
    if (node.children.len > 0) {
        if (node.style.direction == .column) {
            var flow_count: usize = 0;
            for (node.children) |child| {
                if (child.overlay != null) continue;
                flow_count += 1;
                const width = widthFor(child.style, inner_width);
                content_width = @max(content_width, width + p.left + p.right);
                content_height += estimatedHeight(child, width, font);
            }
            content_height += @as(f32, @floatFromInt(flow_count -| 1)) * node.style.gap;
        } else {
            var flow_count: usize = 0;
            for (node.children) |child| {
                if (child.overlay != null) continue;
                flow_count += 1;
                const width = rowWidth(node, child, inner_width, font);
                content_width += width;
                content_height = @max(content_height, estimatedHeight(child, width, font) + p.top + p.bottom);
            }
            content_width += @as(f32, @floatFromInt(flow_count -| 1)) * node.style.gap;
        }
    }
    if (node.scroll) |scroll| {
        scroll.updateLayout(r, Vec2.init(content_width, content_height));
    }
    const dx: f32 = if (node.scroll) |scroll| scroll.offset.x else 0;
    const dy: f32 = if (node.scroll) |scroll| scroll.offset.y else 0;
    const child_clip = if (node.style.overflow == .scroll) inherited_clip.intersection(r) else inherited_clip;
    if (node.style.direction == .column) {
        var grows: f32 = 0;
        for (node.children) |child| if (child.style.height == null) {
            if (child.overlay == null) grows += child.style.grow;
        };
        const free = if (node.style.overflow == .scroll) 0 else @max(0, r.h - content_height);
        var y = r.y + p.top - dy;
        for (node.children) |child| {
            if (child.overlay != null) continue;
            const width = widthFor(child.style, inner_width);
            const natural = estimatedHeight(child, width, font);
            const height = natural + (if (child.style.height == null and grows > 0) free * child.style.grow / grows else 0);
            const x = r.x + p.left + switch (node.style.align_items) {
                .start => @as(f32, 0),
                .center => @max(0, (inner_width - width) / 2),
                .end => @max(0, inner_width - width),
            } - dx;
            place(child, .{ .x = x, .y = y, .w = width, .h = height }, child_clip, font);
            y += height + node.style.gap;
        }
    } else {
        var x = r.x + p.left - dx;
        for (node.children) |child| {
            if (child.overlay != null) continue;
            const width = rowWidth(node, child, inner_width, font);
            const height = estimatedHeight(child, width, font);
            const align_y: f32 = switch (node.style.align_items) {
                .start => 0,
                .center => @max(0, (inner_height - height) / 2),
                .end => @max(0, inner_height - height),
            };
            place(child, .{ .x = x, .y = r.y + p.top + align_y - dy, .w = width, .h = height }, child_clip, font);
            x += width + node.style.gap;
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
                const anchor_visible = position.target.bounds.intersection(position.target.clip);
                if (anchor_visible.w <= 0 or anchor_visible.h <= 0) {
                    place(child, .{ .x = 0, .y = 0, .w = width, .h = height }, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, font);
                    continue;
                }
                x = position.target.bounds.x;
                y = position.target.bounds.y + position.target.bounds.h + position.gap;
                if (y + height > inherited_clip.y + inherited_clip.h and position.target.bounds.y - position.gap - height >= inherited_clip.y) {
                    y = position.target.bounds.y - position.gap - height;
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
        place(child, .{ .x = x, .y = y, .w = width, .h = height }, inherited_clip, font);
    }
}

test "independent scroll roots clamp and clip children" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
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
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
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
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
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
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
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
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
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
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
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
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
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
