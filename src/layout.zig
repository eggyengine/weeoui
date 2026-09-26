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
    pub const Role = enum { group, label, heading, button, checkbox, switch_control, slider, input, radio, radio_group, progress, tab, tab_list, tab_panel, image, alert, dialog, alert_dialog, menu, menu_item, table, row, cell, column_header, ignored };
    role: ?Role = null,
    label: ?[]const u8 = null,
    description: ?[]const u8 = null,
    numeric_value: ?f32 = null,
    expanded: ?bool = null,
    modal: bool = false,
    disabled: bool = false,
};

pub const Element = struct {
    id: u32 = 0,
    style: Style = .{},
    paint_kind: Paint = .none,
    accessibility: Accessibility = .{},
    children: []const *Element = &.{},
    scroll: ?*ScrollState = null,
    bounds: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    clip: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

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
        if (!self.bounds.intersection(self.clip).contains(x, y)) return null;
        var i = self.children.len;
        while (i > 0) {
            i -= 1;
            if (self.children[i].scrollAt(x, y)) |scroll| return scroll;
        }
        return self.scroll;
    }
    pub fn layout(self: *Element, viewport: Rect, font: *const Font) void {
        place(self, viewport, viewport, font);
    }
    pub fn render(self: *Element, viewport: Rect, c: *Canvas) !void {
        self.layout(viewport, c.font);
        try self.draw(c);
    }
    pub fn draw(self: *const Element, c: *Canvas) !void {
        const previous = c.clip;
        c.clip = self.clip;
        defer c.clip = previous;
        const previous_foreground = c.theme.foreground;
        defer c.theme.foreground = previous_foreground;
        switch (self.paint_kind) {
            .none => {},
            .card => {
                try @import("components/card.zig").draw(c, self.bounds);
                c.theme.foreground = c.theme.card_foreground;
            },
            .separator => try c.rect(self.bounds, c.theme.border),
            .text => |t| {
                c.clip = self.clip.intersection(self.bounds);
                const color = if (t.tone == .muted) c.theme.muted_foreground else c.theme.foreground;
                if (t.wrap) try c.textWrappedInAligned(self.bounds, t.value, t.size, color, t.alignment) else try c.textIn(self.bounds, t.value, t.size, color, t.alignment);
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
        for (self.children) |child| try child.draw(c);
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    pub fn node(self: Builder, id: u32, style: Style, paint_kind: Paint, children: []const *Element) !*Element {
        const result = try self.allocator.create(Element);
        errdefer self.allocator.destroy(result);
        result.* = .{ .id = id, .style = style, .paint_kind = paint_kind, .children = if (children.len == 0) &.{} else try self.allocator.dupe(*Element, children) };
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
fn naturalWidth(node: *const Element, font: *const Font) f32 {
    if (node.style.width) |width| return widthFor(node.style, width);
    var width: f32 = 0;
    if (node.children.len > 0) {
        for (node.children) |child| {
            const child_width = naturalWidth(child, font);
            if (node.style.direction == .row) {
                width += child_width;
            } else {
                width = @max(width, child_width);
            }
        }
        if (node.style.direction == .row) width += @as(f32, @floatFromInt(node.children.len - 1)) * node.style.gap;
    } else switch (node.paint_kind) {
        .text => |t| width = font.measure(t.value, t.size),
        else => {},
    }
    return widthFor(node.style, @max(node.style.min_width, width + node.style.padding.left + node.style.padding.right));
}
fn rowWidth(parent: *const Element, child: *const Element, inner_width: f32, font: *const Font) f32 {
    var basis: f32 = 0;
    var grows: f32 = 0;
    for (parent.children) |other| {
        basis += naturalWidth(other, font);
        if (other.style.width == null) grows += other.style.grow;
    }
    basis += @as(f32, @floatFromInt(parent.children.len -| 1)) * parent.style.gap;
    const extra = @max(0, inner_width - basis);
    const proposed = naturalWidth(child, font) + (if (child.style.width == null and grows > 0) extra * child.style.grow / grows else 0);
    return widthFor(child.style, proposed);
}
fn estimatedHeight(node: *const Element, width: f32, font: *const Font) f32 {
    if (node.style.height) |height| return height;
    const inner_width = @max(0, width - node.style.padding.left - node.style.padding.right);
    var height: f32 = 0;
    if (node.children.len > 0) {
        if (node.style.direction == .column) {
            for (node.children) |child| height += estimatedHeight(child, widthFor(child.style, inner_width), font);
            height += @as(f32, @floatFromInt(node.children.len - 1)) * node.style.gap;
        } else {
            for (node.children) |child| height = @max(height, estimatedHeight(child, rowWidth(node, child, inner_width, font), font));
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
    return @max(node.style.min_height, @min(node.style.max_height orelse std.math.inf(f32), height + node.style.padding.top + node.style.padding.bottom));
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
            for (node.children) |child| {
                const width = widthFor(child.style, inner_width);
                content_width = @max(content_width, width + p.left + p.right);
                content_height += estimatedHeight(child, width, font);
            }
            content_height += @as(f32, @floatFromInt(node.children.len - 1)) * node.style.gap;
        } else {
            for (node.children) |child| {
                const width = rowWidth(node, child, inner_width, font);
                content_width += width;
                content_height = @max(content_height, estimatedHeight(child, width, font) + p.top + p.bottom);
            }
            content_width += @as(f32, @floatFromInt(node.children.len - 1)) * node.style.gap;
        }
    }
    if (node.scroll) |scroll| {
        scroll.viewport = r;
        scroll.content = Vec2.init(content_width, content_height);
        scroll.clamp();
    }
    const dx: f32 = if (node.scroll) |scroll| scroll.offset.x else 0;
    const dy: f32 = if (node.scroll) |scroll| scroll.offset.y else 0;
    const child_clip = if (node.style.overflow == .scroll) inherited_clip.intersection(r) else inherited_clip;
    if (node.style.direction == .column) {
        var grows: f32 = 0;
        for (node.children) |child| if (child.style.height == null) {
            grows += child.style.grow;
        };
        const free = if (node.style.overflow == .scroll) 0 else @max(0, r.h - content_height);
        var y = r.y + p.top - dy;
        for (node.children) |child| {
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
