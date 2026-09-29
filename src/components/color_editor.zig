//! Unreal-style color picker: a hue/saturation disc, vertical saturation and value bars,
//! gradient RGBA and HSV sliders, Old/New preview, linear and sRGB hex. State is app-owned.
const std = @import("std");
const Canvas = @import("../canvas.zig").Canvas;
const types = @import("../types.zig");
const Color = types.Color;
const Hsv = types.Hsv;
const Rect = types.Rect;

/// Every draggable part; the widget gives part `p` the id `first_id + @intFromEnum(p)`.
pub const Channel = enum(u8) { wheel, saturation, value, red, green, blue, alpha, hue, sat, val };

pub const ColorEditor = struct {
    hsv: Hsv,
    alpha: f32 = 1,
    /// Color when editing began: the "Old" swatch, restored by Cancel.
    original: Hsv,
    original_alpha: f32 = 1,
    /// Part being dragged and its bounds when the drag began.
    drag: ?Channel = null,
    drag_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn init(color: Color, alpha: f32) ColorEditor {
        const hsv = Hsv.fromRgb(color, 0);
        return .{ .hsv = hsv, .alpha = alpha, .original = hsv, .original_alpha = alpha };
    }
    /// Current color, sRGB.
    pub fn rgb(self: ColorEditor) Color {
        return self.hsv.toRgb();
    }
    /// Current color in linear light, as Unreal shows R, G and B.
    pub fn linear(self: ColorEditor) Color {
        const c = self.rgb();
        return .{ types.linearChannel(c[0]), types.linearChannel(c[1]), types.linearChannel(c[2]) };
    }
    /// Slider position 0..1 for `channel` (the wheel reports hue).
    pub fn get(self: ColorEditor, channel: Channel) f32 {
        const l = self.linear();
        return switch (channel) {
            .wheel, .hue => self.hsv.h,
            .saturation, .sat => self.hsv.s,
            .value, .val => self.hsv.v,
            .red => l[0],
            .green => l[1],
            .blue => l[2],
            .alpha => self.alpha,
        };
    }
    /// Set a slider channel from a 0..1 position; RGB edits keep the hue of greys.
    pub fn set(self: *ColorEditor, channel: Channel, t: f32) void {
        const v = std.math.clamp(t, 0, 1);
        switch (channel) {
            .wheel, .hue => self.hsv.h = @mod(t, 1),
            .saturation, .sat => self.hsv.s = v,
            .value, .val => self.hsv.v = v,
            .alpha => self.alpha = v,
            .red, .green, .blue => {
                var l = self.linear();
                l[@intFromEnum(channel) - @intFromEnum(Channel.red)] = v;
                self.hsv = Hsv.fromRgb(.{ types.srgbChannel(l[0]), types.srgbChannel(l[1]), types.srgbChannel(l[2]) }, self.hsv.h);
            },
        }
    }
    /// Start dragging `channel` inside `bounds` at (x, y). The wheel picks hue and saturation together.
    pub fn press(self: *ColorEditor, channel: Channel, bounds: Rect, x: f32, y: f32) void {
        self.drag = channel;
        self.drag_rect = bounds;
        self.dragTo(x, y);
    }
    pub fn dragTo(self: *ColorEditor, x: f32, y: f32) void {
        const channel = self.drag orelse return;
        const r = self.drag_rect;
        switch (channel) {
            .wheel => {
                const cx = r.x + r.w / 2;
                const cy = r.y + r.h / 2;
                const radius = @min(r.w, r.h) / 2;
                self.hsv.h = @mod(std.math.atan2(x - cx, cy - y) / (2 * std.math.pi), 1);
                self.hsv.s = std.math.clamp(std.math.hypot(x - cx, y - cy) / radius, 0, 1);
            },
            .saturation, .value => self.set(channel, 1 - (y - r.y) / @max(1, r.h)),
            else => {
                const track = sliderTrack(r);
                self.set(channel, (x - track.x) / @max(1, track.w));
            },
        }
    }
    pub fn release(self: *ColorEditor) void {
        self.drag = null;
    }
    /// Keyboard step: ±1 moves a slider by 1% (hue by 1°); on the wheel, `vertical` changes saturation.
    pub fn nudge(self: *ColorEditor, channel: Channel, direction: f32, vertical: bool) void {
        const target: Channel = if (channel == .wheel and vertical) .saturation else channel;
        const step: f32 = if (target == .wheel or target == .hue) 1.0 / 360.0 else 0.01;
        self.set(target, self.get(target) + direction * step);
    }
    pub fn revert(self: *ColorEditor) void {
        self.hsv = self.original;
        self.alpha = self.original_alpha;
    }
    pub fn commit(self: *ColorEditor) void {
        self.original = self.hsv;
        self.original_alpha = self.alpha;
    }
    /// "RRGGBBAA" of the linear (Unreal "Hex Linear") or sRGB color.
    pub fn hex(self: ColorEditor, buffer: *[8]u8, space: enum { linear, srgb }) []const u8 {
        const c = if (space == .linear) self.linear() else self.rgb();
        var bytes: [4]u8 = undefined;
        for (bytes[0..3], c) |*byte, channel| byte.* = @intFromFloat(@round(std.math.clamp(channel, 0, 1) * 255));
        bytes[3] = @intFromFloat(@round(self.alpha * 255));
        return std.fmt.bufPrint(buffer, "{X:0>8}", .{std.mem.readInt(u32, &bytes, .big)}) catch unreachable;
    }
    /// Parse "RRGGBB" or "RRGGBBAA" (with or without `#`) in the given space.
    pub fn setHex(self: *ColorEditor, text: []const u8, space: enum { linear, srgb }) !void {
        const digits = std.mem.trimStart(u8, std.mem.trim(u8, text, " \t"), "#");
        if (digits.len != 6 and digits.len != 8) return error.InvalidColor;
        var bytes: [4]u8 = .{ 0, 0, 0, 255 };
        _ = std.fmt.hexToBytes(bytes[0 .. digits.len / 2], digits) catch return error.InvalidColor;
        var c: Color = undefined;
        for (&c, bytes[0..3]) |*channel, byte| {
            const value = @as(f32, @floatFromInt(byte)) / 255;
            channel.* = if (space == .linear) types.srgbChannel(value) else value;
        }
        self.hsv = Hsv.fromRgb(c, self.hsv.h);
        self.alpha = @as(f32, @floatFromInt(bytes[3])) / 255;
    }
};

/// Label on the left, number on the right, gradient track between.
pub fn sliderTrack(r: Rect) Rect {
    return .{ .x = r.x + 18, .y = r.y + 3, .w = @max(0, r.w - 18 - 52), .h = @max(0, r.h - 6) };
}

/// The color a slider shows at position `t`: the current color with only that channel changed.
fn sample(editor: ColorEditor, channel: Channel, t: f32) [4]f32 {
    var probe = editor;
    probe.set(channel, t);
    const c = probe.rgb();
    return .{ c[0], c[1], c[2], if (channel == .alpha) t else 1 };
}

fn checker(c: *Canvas, r: Rect) !void {
    try c.rect(r, .{ 0.85, 0.85, 0.85 });
    const cell: f32 = 6;
    var y = r.y;
    var row: usize = 0;
    while (y < r.y + r.h) : ({
        y += cell;
        row += 1;
    }) {
        var x = r.x + if (row % 2 == 1) cell else 0;
        while (x < r.x + r.w) : (x += 2 * cell) try c.rect(.{ .x = x, .y = y, .w = @min(cell, r.x + r.w - x), .h = @min(cell, r.y + r.h - y) }, .{ 0.6, 0.6, 0.6 });
    }
}

/// A gradient bar for `channel`, horizontal with label and value, or a bare vertical bar.
pub fn drawChannel(c: *Canvas, r: Rect, editor: ColorEditor, channel: Channel, label: []const u8) !void {
    const vertical = channel == .saturation or channel == .value;
    const track = if (vertical) r else sliderTrack(r);
    if (track.w <= 0 or track.h <= 0) return;
    if (channel == .alpha) try checker(c, track);
    const stops = 12;
    for (0..stops) |i| {
        const t0 = @as(f32, @floatFromInt(i)) / stops;
        const t1 = @as(f32, @floatFromInt(i + 1)) / stops;
        const a = sample(editor, channel, t0);
        const b = sample(editor, channel, t1);
        const seg = if (vertical)
            [4][2]f32{ .{ track.x, track.y + (1 - t1) * track.h }, .{ track.x + track.w, track.y + (1 - t1) * track.h }, .{ track.x + track.w, track.y + (1 - t0) * track.h }, .{ track.x, track.y + (1 - t0) * track.h } }
        else
            [4][2]f32{ .{ track.x + t0 * track.w, track.y }, .{ track.x + t1 * track.w, track.y }, .{ track.x + t1 * track.w, track.y + track.h }, .{ track.x + t0 * track.w, track.y + track.h } };
        const colors = if (vertical) [4][4]f32{ b, b, a, a } else [4][4]f32{ a, b, b, a };
        try c.triangle(.{ seg[0], seg[1], seg[2] }, .{ colors[0], colors[1], colors[2] });
        try c.triangle(.{ seg[0], seg[2], seg[3] }, .{ colors[0], colors[2], colors[3] });
    }
    try c.roundRectStroke(track, c.theme.border, 0, 1);
    // Thumb: a white bar with dark edges across the track.
    const t = editor.get(channel);
    const thumb = if (vertical)
        Rect{ .x = track.x - 2, .y = track.y + (1 - t) * track.h - 2, .w = track.w + 4, .h = 4 }
    else
        Rect{ .x = track.x + t * track.w - 2, .y = track.y - 2, .w = 4, .h = track.h + 4 };
    try c.rect(thumb.inset(-1), .{ 0, 0, 0 });
    try c.rect(thumb, .{ 1, 1, 1 });
    if (vertical) return;
    const size = c.theme.small_text_size;
    try c.textIn(.{ .x = r.x, .y = r.y, .w = 14, .h = r.h }, label, size, c.theme.muted_foreground, .start);
    var buffer: [16]u8 = undefined;
    const value = if (channel == .hue)
        std.fmt.bufPrint(&buffer, "{d:.1}", .{t * 360}) catch unreachable
    else
        std.fmt.bufPrint(&buffer, "{d:.3}", .{t}) catch unreachable;
    try c.textIn(.{ .x = r.x + r.w - 48, .y = r.y, .w = 48, .h = r.h }, value, size, c.theme.foreground, .end);
}

/// Hue around, saturation outward, at full value like Unreal's wheel; marker at the current color.
pub fn drawWheel(c: *Canvas, r: Rect, editor: ColorEditor) !void {
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    const radius = @min(r.w, r.h) / 2;
    if (radius <= 4) return;
    const feather = 1 / @max(1, c.pixel_scale[0]);
    const segments = 96;
    const white = [4]f32{ 1, 1, 1, 1 };
    for (0..segments) |i| {
        const h0 = @as(f32, @floatFromInt(i)) / segments;
        const h1 = @as(f32, @floatFromInt(i + 1)) / segments;
        const a0 = h0 * 2 * std.math.pi;
        const a1 = h1 * 2 * std.math.pi;
        const c0 = (Hsv{ .h = h0 }).toRgb();
        const c1 = (Hsv{ .h = h1 }).toRgb();
        // Saturation is linear in RGB along a radius, so one fan triangle per hue step is exact.
        const edge = radius - feather;
        const p0 = [2]f32{ cx + @sin(a0) * edge, cy - @cos(a0) * edge };
        const p1 = [2]f32{ cx + @sin(a1) * edge, cy - @cos(a1) * edge };
        try c.triangle(.{ .{ cx, cy }, p0, p1 }, .{ white, .{ c0[0], c0[1], c0[2], 1 }, .{ c1[0], c1[1], c1[2], 1 } });
        // Feathered rim so the disc edge is anti-aliased.
        const q0 = [2]f32{ cx + @sin(a0) * radius, cy - @cos(a0) * radius };
        const q1 = [2]f32{ cx + @sin(a1) * radius, cy - @cos(a1) * radius };
        try c.triangle(.{ p0, p1, q1 }, .{ .{ c0[0], c0[1], c0[2], 1 }, .{ c1[0], c1[1], c1[2], 1 }, .{ c1[0], c1[1], c1[2], 0 } });
        try c.triangle(.{ p0, q1, q0 }, .{ .{ c0[0], c0[1], c0[2], 1 }, .{ c1[0], c1[1], c1[2], 0 }, .{ c0[0], c0[1], c0[2], 0 } });
    }
    const angle = editor.hsv.h * 2 * std.math.pi;
    const d = editor.hsv.s * radius;
    const marker = Rect{ .x = cx + @sin(angle) * d - 6, .y = cy - @cos(angle) * d - 6, .w = 12, .h = 12 };
    try c.roundRectStroke(marker.inset(-1), .{ 0, 0, 0 }, 7, 1);
    try c.roundRectStroke(marker, .{ 1, 1, 1 }, 6, 2);
}

/// A color chip with a hairline border; translucent colors sit on a checkerboard.
pub fn drawSwatch(c: *Canvas, r: Rect, color: Color, alpha: f32) !void {
    try c.rect(r, c.theme.border);
    const inner = r.inset(1);
    if (alpha < 1) try checker(c, inner);
    try c.rectAlpha(inner, color, std.math.clamp(alpha, 0, 1));
}

test "channels map through linear RGB, hex round-trips, and drags clamp" {
    var editor = ColorEditor.init(types.rgb(0xF2, 0xB2, 0x33), 1);
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("F2B233FF", editor.hex(&buffer, .srgb));
    try editor.setHex("#3366CC80", .srgb);
    try std.testing.expectEqualStrings("3366CC80", editor.hex(&buffer, .srgb));
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), editor.alpha, 0.001);
    // Linear hex of sRGB 0x80 grey is about 0x37.
    try editor.setHex("808080", .srgb);
    try std.testing.expectEqualStrings("373737FF", editor.hex(&buffer, .linear));
    const hue = editor.hsv.h;
    editor.set(.red, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1), editor.get(.red), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, types.linearChannel(0x80.0 / 255.0)), editor.get(.green), 0.002);
    _ = hue;
    const bar = Rect{ .x = 0, .y = 0, .w = 20, .h = 100 };
    editor.press(.value, bar, 10, -50);
    try std.testing.expectEqual(@as(f32, 1), editor.hsv.v);
    editor.dragTo(10, 75);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), editor.hsv.v, 0.001);
    editor.release();
    const wheel = Rect{ .x = 0, .y = 0, .w = 200, .h = 200 };
    editor.press(.wheel, wheel, 200, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), editor.hsv.h, 0.001);
    try std.testing.expectEqual(@as(f32, 1), editor.hsv.s);
    editor.revert();
    try std.testing.expectEqualStrings("F2B233FF", editor.hex(&buffer, .srgb));
    editor.nudge(.hue, 1, false);
    try std.testing.expectApproxEqAbs(editor.original.h + 1.0 / 360.0, editor.hsv.h, 0.0001);
    try std.testing.expectError(error.InvalidColor, editor.setHex("12345", .srgb));
}
