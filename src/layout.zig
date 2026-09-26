//! Frame-local element tree: measure, place, then paint.
const std = @import("std");
const types = @import("types.zig");
const Rect = types.Rect;
const Vec2 = types.Vec2;
const Font = @import("font.zig").Font;
const Canvas = @import("canvas.zig").Canvas;

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
    align_items: enum { start, center } = .start,
    overflow: enum { visible, scroll } = .visible,
};
pub const Text = struct { value: []const u8, size: f32, tone: enum { foreground, muted } = .foreground, wrap: bool = false };
pub const Paint = union(enum) {
    none,
    card,
    separator,
    text: Text,
    badge: []const u8,
    button: struct { label: []const u8, primary: bool = true, hot: bool, focused: bool },
    checkbox: struct { label: []const u8, checked: bool, focused: bool },
    toggle: struct { label: []const u8, enabled: bool, focused: bool },
    scrollbar: struct { state: *ScrollState, axis: ScrollState.Axis },
    custom: struct {
        context: *const anyopaque,
        measure: ?*const fn (*const anyopaque, f32, *const Font) f32 = null,
        draw: *const fn (*const anyopaque, *Canvas, Rect) anyerror!void,
    },
};

pub const ScrollState = @import("scroll.zig").ScrollState;

pub const Element = struct {
    id: u32 = 0,
    style: Style = .{},
    paint_kind: Paint = .none,
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
    pub fn layout(self: *Element, viewport: Rect, font: *const Font) void {
        place(self, viewport, viewport, font);
    }
    pub fn draw(self: *const Element, c: *Canvas) !void {
        const previous = c.clip;
        c.clip = self.clip;
        defer c.clip = previous;
        switch (self.paint_kind) {
            .none => {},
            .card => try @import("components/card.zig").draw(c, self.bounds),
            .separator => try c.rect(self.bounds, c.theme.border),
            .text => |t| {
                const color = if (t.tone == .muted) c.theme.muted else c.theme.foreground;
                if (t.wrap) try c.textWrappedIn(self.bounds, t.value, t.size, color) else try c.textIn(self.bounds, t.value, t.size, color, .start);
            },
            .badge => |label| try @import("components/badge.zig").draw(c, self.bounds, label),
            .button => |b| try @import("components/button.zig").draw(c, self.bounds, b.label, b.primary, b.hot, b.focused),
            .checkbox => |b| try @import("components/checkbox.zig").draw(c, self.bounds, b.label, b.checked, b.focused),
            .toggle => |b| try @import("components/toggle.zig").draw(c, self.bounds, b.label, b.enabled, b.focused),
            .scrollbar => |bar| try bar.state.drawBar(c, bar.axis),
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
        result.* = .{ .id = id, .style = style, .paint_kind = paint_kind, .children = try self.allocator.dupe(*Element, children) };
        return result;
    }
};

fn widthFor(style: Style, available: f32) f32 {
    return @max(style.min_width, @min(style.max_width orelse std.math.inf(f32), style.width orelse available));
}
fn rowWidth(parent: *const Element, child: *const Element, inner_width: f32) f32 {
    var basis: f32 = 0;
    var grows: f32 = 0;
    for (parent.children) |other| {
        basis += other.style.width orelse other.style.min_width;
        if (other.style.width == null) grows += other.style.grow;
    }
    basis += @as(f32, @floatFromInt(parent.children.len -| 1)) * parent.style.gap;
    const extra = @max(0, inner_width - basis);
    const proposed = child.style.width orelse child.style.min_width + (if (grows > 0) extra * child.style.grow / grows else 0);
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
            for (node.children) |child| height = @max(height, estimatedHeight(child, rowWidth(node, child, inner_width), font));
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
                const width = rowWidth(node, child, inner_width);
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
            const x = r.x + p.left + (if (node.style.align_items == .center) @max(0, (inner_width - width) / 2) else 0) - dx;
            place(child, .{ .x = x, .y = y, .w = width, .h = height }, child_clip, font);
            y += height + node.style.gap;
        }
    } else {
        var x = r.x + p.left - dx;
        for (node.children) |child| {
            const width = rowWidth(node, child, inner_width);
            const height = @max(inner_height, estimatedHeight(child, width, font));
            place(child, .{ .x = x, .y = r.y + p.top - dy, .w = width, .h = height }, child_clip, font);
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
}
