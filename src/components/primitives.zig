const std = @import("std");
const Canvas = @import("../canvas.zig").Canvas;
const Font = @import("../font.zig").Font;
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
    value: []const u8 = "",
    placeholder: []const u8 = "",
    focused: bool = false,
    disabled: bool = false,
    invalid: bool = false,
    multiline: bool = false,
};

pub fn drawInput(c: *Canvas, r: Rect, opts: Input) !void {
    if (r.w <= 0 or r.h <= 0) return;
    const radius = c.theme.radiusMd();
    const border = if (opts.invalid) c.theme.destructive else c.theme.input;
    if (opts.focused and !opts.disabled) try focusRing(c, r, radius, if (opts.invalid) c.theme.destructive else c.theme.ring);
    try c.roundRect(r, border, radius);
    try c.roundRect(r.inset(1), if (opts.disabled) c.theme.muted else c.theme.background, @max(0, radius - 1));
    const area = Rect{ .x = r.x + 10, .y = r.y + 4, .w = @max(0, r.w - 20), .h = @max(0, r.h - 8) };
    const content = if (opts.value.len == 0) opts.placeholder else opts.value;
    const color = if (opts.disabled or opts.value.len == 0) c.theme.muted_foreground else c.theme.foreground;
    if (opts.multiline) {
        try wrappedTextIn(c, area, content, c.theme.text_size, color);
    } else {
        try textIn(c, area, content, c.theme.text_size, color, .start);
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
