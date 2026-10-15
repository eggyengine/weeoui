//! Measure and place: sizes every element of a tree, then gives each its bounds and clip.
//! Rows and columns follow flexbox (grow, shrink, justify, align, wrap); `Style.columns` makes a
//! grid. Overlays leave the flow and are placed against their anchor, a point, or the viewport.
const std = @import("std");
const types = @import("types.zig");
const Rect = types.Rect;
const Vec2 = types.Vec2;
const Font = @import("font.zig").Font;
const L = @import("layout.zig");
const Element = L.Element;
const Style = L.Style;
const Builder = L.Builder;
const button = @import("components/button.zig");
const ScrollState = L.ScrollState;

/// Give `root` and its subtree bounds and clips inside `viewport`.
pub fn layout(root: *Element, viewport: Rect, font: *const Font) void {
    clearMeasurements(root);
    place(root, viewport, viewport, font, false);
}

/// The width `root` asks for before any growing or shrinking.
pub fn preferredWidth(root: *Element, font: *const Font) f32 {
    clearMeasurements(root);
    return naturalWidth(root, font);
}

fn clearMeasurements(node: *Element) void {
    node.natural_width = null;
    node.measured_height_width = null;
    for (node.children) |child| clearMeasurements(child);
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
        .button => |b| width = font.measure(b.label, if (b.size == .sm) button.sm_text_size else 14) + 2 * b.size.padding(),
        .badge => |b| width = font.measure(b.label, 13) + 20,
        .menu_item => |item| width = if (item.size == .sm)
            font.measure(item.label, button.sm_text_size) + font.measure(item.shortcut, button.sm_small_text_size) + 56
        else
            font.measure(item.label, 14) + font.measure(item.shortcut, 13) + 64,
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
        // A popup without a width (a tooltip, a menu) fits its content; a viewport overlay fills.
        const width = if (overlay != .viewport and child.style.width == null)
            @min(inherited_clip.w, naturalWidth(child, font))
        else
            widthFor(child.style, inherited_clip.w);
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
