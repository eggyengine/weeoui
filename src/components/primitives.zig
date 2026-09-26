const std = @import("std");
const Canvas = @import("../canvas.zig").Canvas;
const Font = @import("../font.zig").Font;
const text_edit = @import("../text_edit.zig");
const types = @import("../types.zig");
const Color = types.Color;
const Rect = types.Rect;
const Vertex = types.Vertex;

fn focusRing(c: *Canvas, r: Rect, radius: f32, color: Color) !void {
    try c.roundRect(.{ .x = r.x - 3, .y = r.y - 3, .w = r.w + 6, .h = r.h + 6 }, color, radius + 3);
    try c.roundRect(.{ .x = r.x - 2, .y = r.y - 2, .w = r.w + 4, .h = r.h + 4 }, c.theme.background, radius + 2);
}

fn textIn(c: *Canvas, r: Rect, value: []const u8, size: f32, color: Color, alignment: Canvas.TextAlign) !void {
    if (r.w <= 0 or r.h <= 0) return;
    const previous = c.clip;
    c.clip = if (previous) |clip| clip.intersection(r) else r;
    defer c.clip = previous;
    try c.textIn(r, value, size, color, alignment);
}

fn wrappedTextIn(c: *Canvas, r: Rect, value: []const u8, size: f32, color: Color) !void {
    if (r.w <= 0 or r.h <= 0 or size <= 0) return;
    const previous = c.clip;
    c.clip = if (previous) |clip| clip.intersection(r) else r;
    defer c.clip = previous;
    var lines = c.font.lines(value, size, r.w);
    const line_height = size * 1.35;
    var y = r.y;
    while (y < r.y + r.h) : (y += line_height) {
        const line = lines.next() orelse break;
        try c.textIn(.{ .x = r.x, .y = y, .w = r.w, .h = line_height }, line, size, color, .start);
    }
}

pub const Input = struct {
    pub const Composition = struct {
        text: []const u8,
        /// Committed-value byte range to replace temporarily; defaults to the
        /// selection, then the caret. `cursor` is a byte offset within `text`.
        range: ?text_edit.Range = null,
        cursor: ?usize = null,
    };

    value: []const u8 = "",
    placeholder: []const u8 = "",
    focused: bool = false,
    caret_visible: bool = true,
    disabled: bool = false,
    invalid: bool = false,
    multiline: bool = false,
    cursor: ?usize = null,
    selection: ?text_edit.Range = null,
    composition: ?Composition = null,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
};

pub fn drawInput(c: *Canvas, r: Rect, opts: Input) !void {
    if (r.w <= 0 or r.h <= 0) return;
    const radius = c.theme.radiusMd();
    const border = if (opts.invalid) c.theme.destructive else c.theme.input;
    if (opts.focused and !opts.disabled) try focusRing(c, r, radius, if (opts.invalid) c.theme.destructive else c.theme.ring);
    try c.roundRect(r, border, radius);
    try c.roundRect(r.inset(1), if (opts.disabled) c.theme.muted else c.theme.background, @max(0, radius - 1));
    const area = text_edit.inputContentRect(r);
    const content = if (opts.value.len == 0) opts.placeholder else opts.value;
    const color = if (opts.disabled or opts.value.len == 0) c.theme.muted_foreground else c.theme.foreground;
    if (opts.focused and !opts.disabled and (opts.cursor != null or opts.selection != null or opts.composition != null)) {
        try paintEditingFeedback(c, area, opts);
    } else if (opts.multiline) {
        try wrappedTextIn(c, area, content, c.theme.text_size, color);
    } else {
        try textIn(c, area, content, c.theme.text_size, color, .start);
    }
}

fn checkedRange(value: []const u8, range: text_edit.Range) !void {
    if (range.start > range.end or range.end > value.len) return error.InvalidRange;
    if (!text_edit.isBoundary(value, range.start) or !text_edit.isBoundary(value, range.end)) return error.InvalidBoundary;
}

fn paintEditingFeedback(c: *Canvas, area: Rect, opts: Input) !void {
    if (area.w <= 0 or area.h <= 0 or c.theme.text_size <= 0) return;
    if (!std.unicode.utf8ValidateSlice(opts.value)) return error.InvalidUtf8;
    if (opts.selection) |range| try checkedRange(opts.value, range);
    const cursor = opts.cursor orelse opts.value.len;
    if (!text_edit.isBoundary(opts.value, cursor)) return error.InvalidBoundary;

    var view = text_edit.TextView{ .before = opts.value };
    var caret = cursor;
    var marked: ?text_edit.Range = null;
    if (opts.composition) |composition| {
        if (!std.unicode.utf8ValidateSlice(composition.text)) return error.InvalidUtf8;
        const range = composition.range orelse opts.selection orelse text_edit.Range{ .start = cursor, .end = cursor };
        try checkedRange(opts.value, range);
        const preedit_cursor = composition.cursor orelse composition.text.len;
        if (!text_edit.isBoundary(composition.text, preedit_cursor)) return error.InvalidBoundary;
        view = .{
            .before = opts.value[0..range.start],
            .inserted = composition.text,
            .after = opts.value[range.end..],
        };
        marked = .{ .start = range.start, .end = range.start + composition.text.len };
        caret = range.start + preedit_cursor;
    }
    const layout = text_edit.TextLayout{
        .font = c.font,
        .size = c.theme.text_size,
        .area = area,
        .multiline = opts.multiline,
        .scroll_x = opts.scroll_x,
        .scroll_y = opts.scroll_y,
    };
    const previous = c.clip;
    c.clip = if (previous) |clip| clip.intersection(area) else area;
    defer c.clip = previous;

    if (opts.value.len == 0 and opts.composition == null and opts.placeholder.len > 0) {
        if (opts.multiline) {
            try wrappedTextIn(c, area, opts.placeholder, c.theme.text_size, c.theme.muted_foreground);
        } else {
            try textIn(c, area, opts.placeholder, c.theme.text_size, c.theme.muted_foreground, .start);
        }
    }
    var lines = layout.lines(view);
    while (lines.next()) |line| {
        if (line.y + line.h <= area.y or line.y >= area.y + area.h) continue;
        if (opts.composition == null) if (opts.selection) |range| {
            try paintInputSpan(c, layout, view, line, range, false);
        };
        const y = layout.lineTextY(view, line);
        var x = layout.lineOrigin(view, line);
        var at = line.start;
        while (at < line.end) {
            const cp = view.codepoint(at);
            try c.text(x, y, cp.bytes, layout.size, c.theme.foreground);
            x += c.font.measure(cp.bytes, layout.size);
            at = cp.end;
        }
        if (marked) |range| try paintInputSpan(c, layout, view, line, range, true);
    }
    const caret_rect = layout.caretRect(view, caret);
    if (opts.caret_visible) try c.rect(caret_rect, c.theme.foreground);
}

fn paintInputSpan(c: *Canvas, layout: text_edit.TextLayout, view: text_edit.TextView, line: text_edit.TextLayout.Line, range: text_edit.Range, underline: bool) !void {
    if (range.start >= range.end) return;
    const start = @max(range.start, line.start);
    const end = @min(range.end, line.end);
    const newline = line.newline and range.start <= line.end and range.end > line.end;
    if (start >= end and !newline) return;
    const x = layout.penX(view, line, @min(start, line.end));
    const width = if (start < end) view.measure(c.font, layout.size, start, end) else 0;
    const highlight = Rect{
        .x = x,
        .y = line.y + @max(0, (line.h - layout.size * 1.35) / 2),
        .w = width + if (newline) @max(2, c.font.measure(" ", layout.size) / 2) else @as(f32, 0),
        .h = @min(line.h, layout.size * 1.35),
    };
    if (underline) {
        try c.rect(.{ .x = highlight.x, .y = highlight.y + highlight.h - 2, .w = highlight.w, .h = 1 }, c.theme.foreground);
    } else {
        try c.rectAlpha(highlight, c.theme.ring, 0.4);
    }
}

pub const Radio = struct {
    checked: bool = false,
    focused: bool = false,
};

pub fn drawRadio(c: *Canvas, r: Rect, opts: Radio) !void {
    const size = @min(20, @min(r.w, r.h));
    if (size <= 0) return;
    const center = r.center();
    const circle = Rect{ .x = center.x - size / 2, .y = center.y - size / 2, .w = size, .h = size };
    if (opts.focused) try focusRing(c, circle, size / 2, c.theme.ring);
    try c.roundRect(circle, if (opts.checked) c.theme.primary else c.theme.input, size / 2);
    try c.roundRect(circle.inset(1), c.theme.background, @max(0, size / 2 - 1));
    if (opts.checked) {
        const dot = circle.inset(size * 0.35);
        try c.roundRect(dot, c.theme.primary, dot.w / 2);
    }
}

/// Value is normalized to 0..1; non-finite values are rejected.
pub fn drawProgress(c: *Canvas, r: Rect, value: f32) !void {
    if (!std.math.isFinite(value)) return error.InvalidValue;
    if (r.w <= 0 or r.h <= 0) return;
    const track = Rect{ .x = r.x, .y = r.center().y - @min(r.h, 8) / 2, .w = r.w, .h = @min(r.h, 8) };
    const radius = @min(c.theme.radiusSm(), track.h / 2);
    try c.roundRect(track, c.theme.secondary, radius);
    const filled = track.w * std.math.clamp(value, 0, 1);
    if (filled > 0) try c.roundRect(.{ .x = track.x, .y = track.y, .w = filled, .h = track.h }, c.theme.primary, radius);
}

pub fn drawSkeleton(c: *Canvas, r: Rect) !void {
    try c.roundRect(r, c.theme.muted, c.theme.radiusMd());
}
pub fn drawAnimatedSkeleton(c: *Canvas, r: Rect, phase: f32) !void {
    if (!std.math.isFinite(phase)) return error.InvalidValue;
    const blend = 0.12 + 0.24 * (0.5 + 0.5 * @sin(phase * 2 * std.math.pi));
    var color: Color = undefined;
    for (&color, c.theme.muted, c.theme.background) |*channel, muted, background| {
        channel.* = muted * (1 - blend) + background * blend;
    }
    try c.roundRect(r, color, c.theme.radiusMd());
}

/// Phase is supplied by the caller, normalized to 0..1.
pub fn drawSpinner(c: *Canvas, r: Rect, phase: f32) !void {
    if (!std.math.isFinite(phase)) return error.InvalidValue;
    const size = @min(r.w, r.h);
    if (size <= 0) return;
    const dot_size = size * 0.12;
    const radius = size * 0.36;
    const center = r.center();
    const step: usize = @intFromFloat(std.math.clamp(phase, 0, 1) * 8);
    for (0..8) |i| {
        const angle = @as(f32, @floatFromInt(i)) * @as(f32, std.math.pi / 4.0);
        const dot = Rect{
            .x = center.x + @cos(angle) * radius - dot_size / 2,
            .y = center.y + @sin(angle) * radius - dot_size / 2,
            .w = dot_size,
            .h = dot_size,
        };
        try c.roundRect(dot, if (i == step % 8) c.theme.primary else c.theme.muted, dot_size / 2);
    }
}

pub fn drawAvatar(c: *Canvas, r: Rect, initials: []const u8) !void {
    const size = @min(r.w, r.h);
    if (size <= 0) return;
    const center = r.center();
    const circle = Rect{ .x = center.x - size / 2, .y = center.y - size / 2, .w = size, .h = size };
    try c.roundRect(circle, c.theme.muted, size / 2);
    try textIn(c, circle.inset(size * 0.1), initials, @min(c.theme.small_text_size, size * 0.45), c.theme.foreground, .center);
}

pub const Tab = struct {
    label: []const u8,
    selected: bool = false,
    focused: bool = false,
};

pub fn drawTab(c: *Canvas, r: Rect, opts: Tab) !void {
    if (r.w <= 0 or r.h <= 0) return;
    const radius = c.theme.radiusSm();
    if (opts.focused) try focusRing(c, r, radius, c.theme.ring);
    try c.roundRect(r, if (opts.selected) c.theme.border else c.theme.muted, radius);
    if (opts.selected) try c.roundRect(r.inset(1), c.theme.background, @max(0, radius - 1));
    try textIn(c, r.inset(6), opts.label, c.theme.small_text_size, if (opts.selected) c.theme.foreground else c.theme.muted_foreground, .center);
}

pub const ToggleButton = struct {
    label: []const u8,
    pressed: bool = false,
    focused: bool = false,
};

pub fn drawToggleButton(c: *Canvas, r: Rect, opts: ToggleButton) !void {
    if (r.w <= 0 or r.h <= 0) return;
    const radius = c.theme.radiusMd();
    if (opts.focused) try focusRing(c, r, radius, c.theme.ring);
    try c.roundRect(r, if (opts.pressed) c.theme.accent else c.theme.border, radius);
    if (!opts.pressed) try c.roundRect(r.inset(1), c.theme.background, @max(0, radius - 1));
    try textIn(c, r.inset(6), opts.label, c.theme.text_size, if (opts.pressed) c.theme.accent_foreground else c.theme.foreground, .center);
}

pub const Surface = enum { card, popover, dialog, tooltip, toast, menu, sidebar };

/// Tooltip uses primary/primary_foreground; card and toast use card/card_foreground,
/// popover, dialog, and menu use popover/popover_foreground; sidebar uses muted/foreground.
pub fn drawSurface(c: *Canvas, r: Rect, surface: Surface) !void {
    const fill = switch (surface) {
        .card, .toast => c.theme.card,
        .tooltip => c.theme.primary,
        .sidebar => c.theme.muted,
        .popover, .dialog, .menu => c.theme.popover,
    };
    const radius = switch (surface) {
        .sidebar => @as(f32, 0),
        .tooltip => c.theme.radiusSm(),
        .card, .dialog => c.theme.radiusLg(),
        .popover, .toast, .menu => c.theme.radiusMd(),
    };
    try c.roundRect(r, c.theme.border, radius);
    try c.roundRect(r.inset(1), fill, @max(0, radius - 1));
}

pub const Alert = struct {
    title: []const u8,
    description: []const u8 = "",
    destructive: bool = false,
};

pub fn drawAlert(c: *Canvas, r: Rect, opts: Alert) !void {
    const radius = c.theme.radiusLg();
    try c.roundRect(r, if (opts.destructive) c.theme.destructive else c.theme.border, radius);
    try c.roundRect(r.inset(1), c.theme.background, @max(0, radius - 1));
    const inner = r.inset(12);
    if (opts.description.len == 0) {
        try textIn(c, inner, opts.title, c.theme.text_size, if (opts.destructive) c.theme.destructive else c.theme.foreground, .start);
    } else {
        const title_height = c.theme.text_size * 1.35;
        try textIn(c, .{ .x = inner.x, .y = inner.y, .w = inner.w, .h = @min(inner.h, title_height) }, opts.title, c.theme.text_size, if (opts.destructive) c.theme.destructive else c.theme.foreground, .start);
        try wrappedTextIn(c, .{ .x = inner.x, .y = inner.y + title_height, .w = inner.w, .h = @max(0, inner.h - title_height) }, opts.description, c.theme.small_text_size, c.theme.muted_foreground);
    }
}

/// All data must be finite and nonnegative; invalid or empty data draws nothing.
pub fn drawBarChart(c: *Canvas, r: Rect, values: []const f32) !void {
    if (values.len == 0) return error.EmptyData;
    var maximum: f32 = 0;
    for (values) |value| {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidValue;
        maximum = @max(maximum, value);
    }
    if (r.w <= 0 or r.h <= 0) return;
    const slot = r.w / @as(f32, @floatFromInt(values.len));
    const gap = @min(4, slot * 0.2);
    try c.rect(.{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, c.theme.border);
    if (maximum == 0) return;
    for (values, 0..) |value, i| {
        if (value == 0) continue;
        const height = (value / maximum) * r.h;
        const bar = Rect{
            .x = r.x + slot * @as(f32, @floatFromInt(i)) + gap / 2,
            .y = r.y + r.h - height,
            .w = slot - gap,
            .h = height,
        };
        try c.roundRect(bar, c.theme.primary, @min(c.theme.radiusSm(), bar.w / 2));
    }
}

test "input clips long text to its bounds and restores the caller clip" {
    var font = try Font.init(std.testing.allocator, @embedFile("../assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var vertices: [1024]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    const r = Rect{ .x = 10, .y = 20, .w = 80, .h = 36 };
    canvas.clip = .{ .x = 20, .y = 10, .w = 40, .h = 60 };
    const previous = canvas.clip;
    try drawInput(&canvas, r, .{ .value = "Long text that cannot fit inside the input" });
    try std.testing.expectEqualDeep(previous, canvas.clip);
    try std.testing.expect(canvas.len > 0);
    for (canvas.items()) |vertex| {
        try std.testing.expect(vertex.position[0] >= 20 and vertex.position[0] <= 60);
        try std.testing.expect(vertex.position[1] >= r.y and vertex.position[1] <= r.y + r.h);
    }
}

test "focused input paints selection before glyphs and a clipped caret after them" {
    var font = try Font.init(std.testing.allocator, @embedFile("../assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var vertices: [2048]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    const r = Rect{ .x = 10, .y = 20, .w = 100, .h = 34 };
    const opts = Input{ .value = "AéB", .focused = true, .cursor = 3, .selection = .{ .start = 1, .end = 3 } };
    canvas.clip = .{ .x = 24, .y = 0, .w = 60, .h = 100 };
    const previous = canvas.clip;
    try drawInput(&canvas, r, opts);
    try std.testing.expectEqualDeep(previous, canvas.clip);
    const area = text_edit.inputContentRect(r).intersection(previous.?);
    var highlighted = false;
    for (canvas.items()) |vertex| {
        try std.testing.expect(vertex.position[0] >= previous.?.x and vertex.position[0] <= previous.?.x + previous.?.w);
        try std.testing.expect(vertex.position[1] >= previous.?.y and vertex.position[1] <= previous.?.y + previous.?.h);
        if (vertex.color[3] == 0.4) {
            highlighted = true;
            try std.testing.expect(vertex.position[0] >= area.x and vertex.position[0] <= area.x + area.w);
            try std.testing.expect(vertex.position[1] >= area.y and vertex.position[1] <= area.y + area.h);
        }
    }
    try std.testing.expect(highlighted);
    for (canvas.items()[canvas.len - 6 ..]) |vertex| {
        try std.testing.expectEqualDeep([4]f32{ canvas.theme.foreground[0], canvas.theme.foreground[1], canvas.theme.foreground[2], 1 }, vertex.color);
        try std.testing.expect(vertex.position[0] >= area.x and vertex.position[0] <= area.x + area.w);
        try std.testing.expect(vertex.position[1] >= area.y and vertex.position[1] <= area.y + area.h);
    }
    const focused_len = canvas.len;
    canvas.len = 0;
    try drawInput(&canvas, r, .{ .value = opts.value, .cursor = opts.cursor });
    try std.testing.expect(focused_len > canvas.len);
    for (canvas.items()) |vertex| try std.testing.expect(vertex.color[3] != 0.4);
}

test "multiline input paints underlined preedit, empty-line caret, and clipped selection" {
    var font = try Font.init(std.testing.allocator, @embedFile("../assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var vertices: [4096]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    const r = Rect{ .x = 0, .y = 0, .w = 90, .h = 55 };
    const area = text_edit.inputContentRect(r);
    canvas.clip = r;
    try drawInput(&canvas, r, .{ .value = "ab\n", .multiline = true, .focused = true, .cursor = 3, .composition = .{ .text = "xy\nz", .cursor = 3 } });
    const caret_y = canvas.items()[canvas.len - 1].position[1];
    try std.testing.expect(caret_y >= area.y + canvas.theme.text_size * 2 * 1.35);
    var underlined = false;
    for (canvas.items()) |vertex| {
        if (vertex.position[1] > area.y + canvas.theme.text_size * 1.35 and vertex.position[1] < area.y + canvas.theme.text_size * 2 * 1.35 and vertex.color[0] == canvas.theme.foreground[0]) underlined = true;
        try std.testing.expect(vertex.position[0] >= 0 and vertex.position[0] <= r.w);
        try std.testing.expect(vertex.position[1] >= 0 and vertex.position[1] <= r.h);
    }
    try std.testing.expect(underlined);
    canvas.len = 0;
    try drawInput(&canvas, r, .{ .value = "ab\ncd", .multiline = true, .focused = true, .cursor = 4, .selection = .{ .start = 1, .end = 4 } });
    var selected = false;
    for (canvas.items()) |vertex| if (vertex.color[3] == 0.4) {
        selected = true;
        try std.testing.expect(vertex.position[0] >= area.x and vertex.position[0] <= area.x + area.w);
    };
    try std.testing.expect(selected);
}

test "focused empty input retains placeholder beside caret and rejects invalid preedit" {
    var font = try Font.init(std.testing.allocator, @embedFile("../assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var vertices: [1024]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    const r = Rect{ .x = 10, .y = 20, .w = 140, .h = 34 };
    try drawInput(&canvas, r, .{ .focused = true, .placeholder = "Placeholder", .cursor = 0 });
    var muted = false;
    for (canvas.items()) |vertex| {
        if (vertex.color[0] == canvas.theme.muted_foreground[0] and vertex.color[3] == 1) muted = true;
    }
    try std.testing.expect(muted);
    try std.testing.expectEqual(canvas.theme.foreground[0], canvas.items()[canvas.len - 1].color[0]);
    canvas.len = 0;
    try std.testing.expectError(error.InvalidUtf8, drawInput(&canvas, r, .{
        .focused = true,
        .value = "abc",
        .cursor = 1,
        .composition = .{ .text = "\xff" },
    }));
}

test "chart rejects invalid data before drawing and progress clamps to the track" {
    var font = try Font.init(std.testing.allocator, @embedFile("../assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var vertices: [512]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    const r = Rect{ .x = 10, .y = 20, .w = 60, .h = 8 };
    try std.testing.expectError(error.EmptyData, drawBarChart(&canvas, r, &.{}));
    try std.testing.expectError(error.InvalidValue, drawBarChart(&canvas, r, &.{ 1, -1 }));
    try std.testing.expectError(error.InvalidValue, drawBarChart(&canvas, r, &.{ 1, std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidValue, drawBarChart(&canvas, r, &.{ 1, std.math.inf(f32) }));
    try std.testing.expectEqual(@as(usize, 0), canvas.len);
    try drawProgress(&canvas, r, -1);
    for (canvas.items()) |vertex| {
        try std.testing.expectEqualDeep([4]f32{ canvas.theme.secondary[0], canvas.theme.secondary[1], canvas.theme.secondary[2], 1 }, vertex.color);
    }
    canvas.len = 0;
    try drawProgress(&canvas, r, 2);
    try std.testing.expect(canvas.len > 0);
    try std.testing.expectEqualDeep([4]f32{ canvas.theme.primary[0], canvas.theme.primary[1], canvas.theme.primary[2], 1 }, canvas.items()[canvas.len - 1].color);
    for (canvas.items()) |vertex| {
        try std.testing.expect(vertex.position[0] >= r.x and vertex.position[0] <= r.x + r.w);
    }
    canvas.len = 0;
    try drawBarChart(&canvas, r, &.{ 0, 2, 4 });
    try std.testing.expect(canvas.len > 6);
    try std.testing.expectEqualDeep([4]f32{ canvas.theme.primary[0], canvas.theme.primary[1], canvas.theme.primary[2], 1 }, canvas.items()[canvas.len - 1].color);
}
