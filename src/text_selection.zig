//! Selecting static text by dragging across it: which characters a `types.TextSelection` covers,
//! the highlight behind them, and the selected bytes for copying.
const std = @import("std");
const types = @import("types.zig");
const Rect = types.Rect;
const Vec2 = types.Vec2;
const Font = @import("font.zig").Font;
const Canvas = @import("canvas.zig").Canvas;
const L = @import("layout.zig");
const Element = L.Element;

const max_text_lines = 64;
const TextLine = struct { start: usize, text: []const u8, x: f32, y: f32, h: f32 };

/// The highlighted part of the text element under `root` that `selection` starts in, if any.
/// It points into that element's text, so copy it before the tree is freed.
pub fn selectedText(root: *const Element, selection: types.TextSelection, font: *const Font) ?[]const u8 {
    const element = textAt(root, selection.anchor) orelse return null;
    const range = selectionRange(element, selection, font) orelse return null;
    return element.paint_kind.text.value[range[0]..range[1]];
}

/// Paint the highlight behind the part of text `element` that `selection` covers.
pub fn drawHighlight(element: *const Element, c: *Canvas, selection: types.TextSelection) !void {
    const range = selectionRange(element, selection, c.font) orelse return;
    const size = element.paint_kind.text.size;
    var buffer: [max_text_lines]TextLine = undefined;
    for (textLines(element, c.font, &buffer)) |line| {
        const from = @max(range[0], line.start);
        const to = @min(range[1], line.start + line.text.len);
        if (from >= to) continue;
        const x0 = line.x + c.font.measure(line.text[0 .. from - line.start], size);
        const x1 = line.x + c.font.measure(line.text[0 .. to - line.start], size);
        try c.rectAlpha(.{ .x = x0, .y = line.y, .w = x1 - x0, .h = line.h }, c.theme.ring, 0.35);
    }
}

/// The deepest text element under `point`.
fn textAt(element: *const Element, point: Vec2) ?*const Element {
    if (!element.clip.contains(point.x, point.y)) return null;
    for (element.children) |child| if (textAt(child, point)) |found| return found;
    return if (element.paint_kind == .text and element.bounds.contains(point.x, point.y)) element else null;
}

/// Byte range of text `element` that `selection` covers; null unless it starts there.
fn selectionRange(element: *const Element, selection: types.TextSelection, font: *const Font) ?[2]usize {
    if (element.paint_kind != .text or !element.bounds.intersection(element.clip).contains(selection.anchor.x, selection.anchor.y)) return null;
    var buffer: [max_text_lines]TextLine = undefined;
    const lines = textLines(element, font, &buffer);
    const a = offsetAt(font, element.paint_kind.text.size, lines, selection.anchor);
    const b = offsetAt(font, element.paint_kind.text.size, lines, selection.focus);
    if (a == b) return null;
    return .{ @min(a, b), @max(a, b) };
}

/// Where Canvas puts each line of text `element` (see `textIn` and `textWrappedInAligned`).
fn textLines(element: *const Element, font: *const Font, out: []TextLine) []TextLine {
    const t = element.paint_kind.text;
    const r = element.contentRect();
    const alignment = element.textAlignment();
    const line_height = t.size * 1.35;
    if (!t.wrap) {
        out[0] = .{ .start = 0, .text = t.value, .x = lineX(font, t.value, t.size, r, alignment), .y = r.center().y - line_height / 2, .h = line_height };
        return out[0..1];
    }
    var iter = font.lines(t.value, t.size, r.w);
    var count: usize = 0;
    // ponytail: selection reaches the first `max_text_lines` lines of a paragraph.
    while (iter.next()) |line| : (count += 1) {
        if (count == out.len) break;
        const start = @intFromPtr(line.ptr) - @intFromPtr(t.value.ptr);
        out[count] = .{ .start = start, .text = line, .x = lineX(font, line, t.size, .{ .x = r.x, .y = 0, .w = r.w, .h = 0 }, alignment), .y = r.y + @as(f32, @floatFromInt(count)) * line_height, .h = line_height };
    }
    return out[0..count];
}

/// Left edge of `line`'s pen, as `Canvas.textIn` places it.
fn lineX(font: *const Font, line: []const u8, size: f32, r: Rect, alignment: Canvas.TextAlign) f32 {
    const ink = font.inkBounds(line, size);
    return switch (alignment) {
        .start => r.x - ink.x,
        .center => r.center().x - ink.x - ink.w / 2,
        .end => r.x + r.w - ink.x - ink.w,
    };
}

/// Byte offset of the character boundary nearest `point` among `lines`.
fn offsetAt(font: *const Font, size: f32, lines: []const TextLine, point: Vec2) usize {
    if (lines.len == 0) return 0;
    var index: usize = 0;
    while (index + 1 < lines.len and point.y >= lines[index].y + lines[index].h) index += 1;
    const line = lines[index];
    var pen = line.x;
    var i: usize = 0;
    while (i < line.text.len) {
        const step = std.unicode.utf8ByteSequenceLength(line.text[i]) catch 1;
        const after = @min(line.text.len, i + step);
        const width = font.measure(line.text[i..after], size);
        if (point.x < pen + width / 2) break;
        pen += width;
        i = after;
    }
    return line.start + i;
}

test "dragging across static text highlights and copies the characters it covers" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const label = try b.node(0, .{}, .{ .text = .{ .value = "Crack the egg", .size = 16 } }, &.{});
    const root = try b.column(&.{label});
    var vertices: [2048]types.Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    try root.render(.{ .x = 0, .y = 0, .w = 300, .h = 100 }, &canvas);
    const plain = canvas.len;
    const y = label.bounds.center().y;
    const crack = font.measure("Crack", 16);
    // From the first letter to just past "Crack".
    const selection = types.TextSelection{ .anchor = Vec2.init(label.bounds.x + 1, y), .focus = Vec2.init(label.bounds.x + crack + 1, y) };
    try std.testing.expectEqualStrings("Crack", root.selectedText(selection, &font).?);
    // Backwards drags select the same way; a click without a drag selects nothing.
    try std.testing.expectEqualStrings("Crack", root.selectedText(.{ .anchor = selection.focus, .focus = selection.anchor }, &font).?);
    try std.testing.expect(root.selectedText(.{ .anchor = selection.anchor, .focus = selection.anchor }, &font) == null);
    // Off by default; with a selection the highlight paints under the glyphs.
    canvas.len = 0;
    canvas.text_selection = selection;
    try root.render(.{ .x = 0, .y = 0, .w = 300, .h = 100 }, &canvas);
    try std.testing.expect(canvas.len > plain);
}
