//! Immediate-mode geometry using one texture atlas for text and shapes.
const std = @import("std");
const types = @import("types.zig");
const Font = @import("font.zig").Font;
const Icon = @import("font.zig").Icon;
const atlas_width = @import("font.zig").atlas_width;
const atlas_height = @import("font.zig").atlas_height;
const color_atlas_size = @import("font.zig").color_atlas_size;
const Rect = types.Rect;
const Color = types.Color;
const Vertex = types.Vertex;

pub const Canvas = struct {
    vertices: []Vertex,
    font: *const Font,
    len: usize = 0,
    theme: types.Theme = .{},
    clip: ?Rect = null,
    pixel_scale: [2]f32 = .{ 1, 1 },
    srgb_target: bool = false,
    /// Element id that draws the keyboard focus ring; 0 for none.
    focus_id: u32 = 0,
    /// Element id under the pointer, painted in its hover state; 0 for none.
    hot_id: u32 = 0,

    pub fn init(vertices: []Vertex, font: *const Font) Canvas {
        return .{ .vertices = vertices, .font = font };
    }
    pub fn items(self: *const Canvas) []const Vertex {
        return self.vertices[0..self.len];
    }
    pub fn rect(self: *Canvas, r: Rect, color: Color) !void {
        return self.rectAlpha(r, color, 1);
    }
    pub fn rectAlpha(self: *Canvas, r: Rect, color: Color, alpha: f32) !void {
        if (!std.math.isFinite(alpha) or alpha < 0 or alpha > 1) return error.InvalidAlpha;
        if (r.w <= 0 or r.h <= 0) return;
        try self.quad(self.snapped(r), solid_uv, color, alpha, 0);
    }
    pub fn roundRect(self: *Canvas, r: Rect, color: Color, radius: f32) !void {
        return self.roundRectAlpha(r, color, radius, 1);
    }
    /// Straight edges snap to physical pixels; corners are anti-aliased by the corner distance field.
    pub fn roundRectAlpha(self: *Canvas, r: Rect, color: Color, radius: f32, alpha: f32) !void {
        if (!std.math.isFinite(alpha) or alpha < 0 or alpha > 1) return error.InvalidAlpha;
        if (r.w <= 0 or r.h <= 0) return;
        const s = self.snapped(r);
        const k = @max(0, @min(radius, @min(s.w, s.h) / 2));
        if (k * @min(self.pixel_scale[0], self.pixel_scale[1]) < 1) return self.quad(s, solid_uv, color, alpha, 0);
        try self.quad(.{ .x = s.x + k, .y = s.y, .w = s.w - 2 * k, .h = s.h }, solid_uv, color, alpha, 0);
        try self.quad(.{ .x = s.x, .y = s.y + k, .w = k, .h = s.h - 2 * k }, solid_uv, color, alpha, 0);
        try self.quad(.{ .x = s.x + s.w - k, .y = s.y + k, .w = k, .h = s.h - 2 * k }, solid_uv, color, alpha, 0);
        try self.corners(s, k, color, alpha, 1);
    }
    /// A `width`-thick outline just inside `r`, anti-aliased like `roundRect`.
    pub fn roundRectStroke(self: *Canvas, r: Rect, color: Color, radius: f32, width: f32) !void {
        if (r.w <= 0 or r.h <= 0 or width <= 0) return;
        const s = self.snapped(r);
        const k = @max(width, @min(radius, @min(s.w, s.h) / 2));
        try self.quad(.{ .x = s.x + k, .y = s.y, .w = s.w - 2 * k, .h = width }, solid_uv, color, 1, 0);
        try self.quad(.{ .x = s.x + k, .y = s.y + s.h - width, .w = s.w - 2 * k, .h = width }, solid_uv, color, 1, 0);
        try self.quad(.{ .x = s.x, .y = s.y + k, .w = width, .h = s.h - 2 * k }, solid_uv, color, 1, 0);
        try self.quad(.{ .x = s.x + s.w - width, .y = s.y + k, .w = width, .h = s.h - 2 * k }, solid_uv, color, 1, 0);
        try self.corners(s, k, color, 1, 1 + width / k);
    }
    fn corners(self: *Canvas, s: Rect, k: f32, color: Color, alpha: f32, mode: f32) !void {
        const g = self.font.corner;
        const tile_u = @as(f32, @floatFromInt(g.x)) / atlas_width;
        const tile_v = @as(f32, @floatFromInt(g.y)) / atlas_height;
        const du = @as(f32, @floatFromInt(g.w)) / atlas_width;
        const dv = @as(f32, @floatFromInt(g.h)) / atlas_height;
        // Negative extents mirror the top-left tile into the other corners.
        try self.quad(.{ .x = s.x, .y = s.y, .w = k, .h = k }, .{ .x = tile_u, .y = tile_v, .w = du, .h = dv }, color, alpha, mode);
        try self.quad(.{ .x = s.x + s.w - k, .y = s.y, .w = k, .h = k }, .{ .x = tile_u + du, .y = tile_v, .w = -du, .h = dv }, color, alpha, mode);
        try self.quad(.{ .x = s.x, .y = s.y + s.h - k, .w = k, .h = k }, .{ .x = tile_u, .y = tile_v + dv, .w = du, .h = -dv }, color, alpha, mode);
        try self.quad(.{ .x = s.x + s.w - k, .y = s.y + s.h - k, .w = k, .h = k }, .{ .x = tile_u + du, .y = tile_v + dv, .w = -du, .h = -dv }, color, alpha, mode);
    }
    fn snapped(self: *const Canvas, r: Rect) Rect {
        const sx = self.pixel_scale[0];
        const sy = self.pixel_scale[1];
        const x = @round(r.x * sx);
        const y = @round(r.y * sy);
        const right = @max(x + 1, @round((r.x + r.w) * sx));
        const bottom = @max(y + 1, @round((r.y + r.h) * sy));
        return .{ .x = x / sx, .y = y / sy, .w = (right - x) / sx, .h = (bottom - y) / sy };
    }
    pub fn outline(self: *Canvas, r: Rect, color: Color) !void {
        try self.rect(.{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, color);
        try self.rect(.{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, color);
        try self.rect(.{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, color);
        try self.rect(.{ .x = r.x + r.w - 1, .y = r.y, .w = 1, .h = r.h }, color);
    }
    pub fn icon(self: *Canvas, r: Rect, value: Icon, color: Color) !void {
        const glyph = self.font.icon(value);
        try self.quad(r, .{
            .x = @as(f32, @floatFromInt(glyph.x)) / atlas_width,
            .y = @as(f32, @floatFromInt(glyph.y)) / atlas_height,
            .w = @as(f32, @floatFromInt(glyph.w)) / atlas_width,
            .h = @as(f32, @floatFromInt(glyph.h)) / atlas_height,
        }, color, 1, 0);
    }
    pub fn text(self: *Canvas, x: f32, y: f32, value: []const u8, size: f32, color: Color) !void {
        if (size <= 0) return;
        const strike = self.font.strike(size);
        const scale = self.font.strikeScale(strike, size);
        var at = x;
        var i: usize = 0;
        while (i < value.len) {
            const g = self.font.next(strike, value, &i);
            // Color glyphs index the color atlas and keep their own colors.
            const aw: f32 = if (g.color) color_atlas_size else atlas_width;
            const ah: f32 = if (g.color) color_atlas_size else atlas_height;
            if (g.w > 0 and g.h > 0) try self.quad(
                // Glyph origins land on physical pixels so exact strikes sample 1:1.
                .{ .x = @round((at + @as(f32, @floatFromInt(g.left)) * scale) * self.pixel_scale[0]) / self.pixel_scale[0], .y = @round((y + (strike.ascent - @as(f32, @floatFromInt(g.top))) * scale) * self.pixel_scale[1]) / self.pixel_scale[1], .w = @as(f32, @floatFromInt(g.w)) * scale, .h = @as(f32, @floatFromInt(g.h)) * scale },
                .{ .x = @as(f32, @floatFromInt(g.x)) / aw, .y = @as(f32, @floatFromInt(g.y)) / ah, .w = @as(f32, @floatFromInt(g.w)) / aw, .h = @as(f32, @floatFromInt(g.h)) / ah },
                if (g.color) .{ 1, 1, 1 } else color,
                1,
                if (g.color) -1 else 0,
            );
            at += g.advance * scale;
        }
    }
    pub const TextAlign = enum { start, center, end };
    /// Align visible ink within a rectangle; all components share the same vertical center.
    pub fn textIn(self: *Canvas, r: Rect, value: []const u8, size: f32, color: Color, alignment: TextAlign) !void {
        if (self.clip) |clip| {
            const visible = r.intersection(clip);
            if (visible.w <= 0 or visible.h <= 0) return;
        }
        const ink = self.font.inkBounds(value, size);
        // Vertical placement uses the cap height so neighbouring labels share a baseline.
        const cap = self.font.inkBounds("H", size);
        const center = r.center();
        const x = switch (alignment) {
            .start => r.x - ink.x,
            .center => center.x - ink.x - ink.w / 2,
            .end => r.x + r.w - ink.x - ink.w,
        };
        try self.text(x, center.y - cap.y - cap.h / 2, value, size, color);
    }
    pub fn textWrappedIn(self: *Canvas, r: Rect, value: []const u8, size: f32, color: Color) !void {
        return self.textWrappedInAligned(r, value, size, color, .start);
    }
    pub fn textWrappedInAligned(self: *Canvas, r: Rect, value: []const u8, size: f32, color: Color, alignment: TextAlign) !void {
        if (self.clip) |clip| {
            const visible = r.intersection(clip);
            if (visible.w <= 0 or visible.h <= 0) return;
        }
        var iter = self.font.lines(value, size, r.w);
        var y = r.y;
        const line_height = size * 1.35;
        while (iter.next()) |line| {
            try self.textIn(.{ .x = r.x, .y = y, .w = r.w, .h = line_height }, line, size, color, alignment);
            y += line_height;
        }
    }
    /// Flat-textured triangle with a color (sRGB + alpha) per corner, interpolated across it.
    /// Clipped exactly to `clip`, so gradients and wheels can sit inside scroll areas.
    pub fn triangle(self: *Canvas, points: [3][2]f32, colors: [3][4]f32) !void {
        const Point = struct { p: [2]f32, c: [4]f32 };
        var polygon: [9]Point = undefined;
        var count: usize = 3;
        for (0..3) |i| polygon[i] = .{ .p = points[i], .c = colors[i] };
        if (self.clip) |clip| {
            // Sutherland-Hodgman against the four clip edges: axis, sign, bound.
            const planes = [_]struct { axis: usize, sign: f32, at: f32 }{
                .{ .axis = 0, .sign = 1, .at = clip.x },
                .{ .axis = 0, .sign = -1, .at = clip.x + clip.w },
                .{ .axis = 1, .sign = 1, .at = clip.y },
                .{ .axis = 1, .sign = -1, .at = clip.y + clip.h },
            };
            for (planes) |plane| {
                var out: [9]Point = undefined;
                var n: usize = 0;
                for (0..count) |i| {
                    const a = polygon[i];
                    const b = polygon[(i + 1) % count];
                    const da = (a.p[plane.axis] - plane.at) * plane.sign;
                    const db = (b.p[plane.axis] - plane.at) * plane.sign;
                    if (da >= 0) {
                        out[n] = a;
                        n += 1;
                    }
                    if ((da >= 0) != (db >= 0) and n < out.len) {
                        const t = da / (da - db);
                        var mid: Point = undefined;
                        for (0..2) |k| mid.p[k] = a.p[k] + (b.p[k] - a.p[k]) * t;
                        for (0..4) |k| mid.c[k] = a.c[k] + (b.c[k] - a.c[k]) * t;
                        out[n] = mid;
                        n += 1;
                    }
                }
                polygon = out;
                count = n;
                if (count < 3) return;
            }
        }
        if (self.len + (count - 2) * 3 > self.vertices.len) return error.OutOfVertices;
        const uv = [2]f32{ solid_uv.x, solid_uv.y };
        for (1..count - 1) |i| for ([_]usize{ 0, i, i + 1 }) |j| {
            const c = polygon[j].c;
            self.vertices[self.len] = .{
                .position = polygon[j].p,
                .color = if (self.srgb_target) .{ types.linearChannel(c[0]), types.linearChannel(c[1]), types.linearChannel(c[2]), c[3] } else c,
                .uv = uv,
            };
            self.len += 1;
        };
    }
    const solid_uv = Rect{ .x = 0.5 / @as(f32, atlas_width), .y = 0.5 / @as(f32, atlas_height), .w = 0, .h = 0 };
    fn quad(self: *Canvas, r: Rect, uv: Rect, color: Color, alpha: f32, mode: f32) !void {
        if (r.w <= 0 or r.h <= 0) return;
        const visible = if (self.clip) |clip| r.intersection(clip) else r;
        if (visible.w <= 0 or visible.h <= 0) return;
        if (self.len + 6 > self.vertices.len) return error.OutOfVertices;
        const rgba: [4]f32 = .{
            if (self.srgb_target) types.linearChannel(color[0]) else color[0],
            if (self.srgb_target) types.linearChannel(color[1]) else color[1],
            if (self.srgb_target) types.linearChannel(color[2]) else color[2],
            alpha,
        };
        const u_start = uv.x + (visible.x - r.x) / r.w * uv.w;
        const v_start = uv.y + (visible.y - r.y) / r.h * uv.h;
        const u_end = uv.x + (visible.x + visible.w - r.x) / r.w * uv.w;
        const v_end = uv.y + (visible.y + visible.h - r.y) / r.h * uv.h;
        const a = Vertex{ .position = .{ visible.x, visible.y }, .color = rgba, .uv = .{ u_start, v_start }, .mode = mode };
        const b = Vertex{ .position = .{ visible.x + visible.w, visible.y }, .color = rgba, .uv = .{ u_end, v_start }, .mode = mode };
        const c = Vertex{ .position = .{ visible.x + visible.w, visible.y + visible.h }, .color = rgba, .uv = .{ u_end, v_end }, .mode = mode };
        const d = Vertex{ .position = .{ visible.x, visible.y + visible.h }, .color = rgba, .uv = .{ u_start, v_end }, .mode = mode };
        const triangles = [_]Vertex{ a, b, c, a, c, d };
        @memcpy(self.vertices[self.len..][0..6], &triangles);
        self.len += 6;
    }
};

test "rectangle hit testing and geometry" {
    const r = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expect(r.contains(10, 20));
    try std.testing.expect(!r.contains(40, 20));
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var vertices: [6]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    try canvas.rect(r, .{ 1, 1, 1 });
    try std.testing.expectEqual(@as(usize, 6), canvas.items().len);
    try std.testing.expectError(error.OutOfVertices, canvas.rect(r, .{ 1, 1, 1 }));
}

test "text ink is centered in its rectangle" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var vertices: [32]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    const area = Rect{ .x = 10, .y = 20, .w = 100, .h = 40 };
    try canvas.textIn(area, "AX", 16, .{ 1, 1, 1 }, .center);
    var left: f32 = std.math.inf(f32);
    var top: f32 = std.math.inf(f32);
    var right: f32 = -std.math.inf(f32);
    var bottom: f32 = -std.math.inf(f32);
    for (canvas.items()) |vertex| {
        left = @min(left, vertex.position[0]);
        top = @min(top, vertex.position[1]);
        right = @max(right, vertex.position[0]);
        bottom = @max(bottom, vertex.position[1]);
    }
    try std.testing.expectApproxEqAbs(area.center().x, (left + right) / 2, 0.01);
    try std.testing.expectApproxEqAbs(area.center().y, (top + bottom) / 2, 0.01);
}

test "start and end aligned ink meets the corresponding bounds" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var vertices: [32]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    const area = Rect{ .x = 10, .y = 20, .w = 100, .h = 40 };
    for ([_]Canvas.TextAlign{ .start, .end }) |alignment| {
        canvas.len = 0;
        try canvas.textIn(area, "AX", 16, .{ 1, 1, 1 }, alignment);
        var left: f32 = std.math.inf(f32);
        var right: f32 = -std.math.inf(f32);
        for (canvas.items()) |vertex| {
            left = @min(left, vertex.position[0]);
            right = @max(right, vertex.position[0]);
        }
        try std.testing.expectApproxEqAbs(if (alignment == .start) area.x else area.x + area.w, if (alignment == .start) left else right, 0.01);
    }
}

test "clip trims geometry to the viewport" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var vertices: [6]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    canvas.clip = .{ .x = 10, .y = 10, .w = 20, .h = 20 };
    try canvas.rect(.{ .x = 0, .y = 0, .w = 40, .h = 40 }, .{ 1, 1, 1 });
    for (canvas.items()) |vertex| {
        try std.testing.expect(vertex.position[0] >= 10 and vertex.position[0] <= 30);
        try std.testing.expect(vertex.position[1] >= 10 and vertex.position[1] <= 30);
    }
}

test "Lucide icon vertices use the font atlas and clip to their box" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var vertices: [6]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    canvas.clip = .{ .x = 12, .y = 12, .w = 8, .h = 8 };
    try canvas.icon(.{ .x = 8, .y = 8, .w = 16, .h = 16 }, .check, .{ 1, 1, 1 });
    try std.testing.expectEqual(@as(usize, 6), canvas.len);
    try std.testing.expectEqual(@as(f32, 12), canvas.items()[0].position[0]);
    try std.testing.expect(canvas.items()[0].uv[0] > 0);
}

test "solid rectangles and glyph origins snap to physical pixels" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var vertices: [24]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    canvas.pixel_scale = .{ 2, 2 };
    try canvas.rect(.{ .x = 1.2, .y = 2.2, .w = 3.1, .h = 4.1 }, .{ 1, 1, 1 });
    try std.testing.expectEqual(@as(f32, 1), canvas.items()[0].position[0]);
    try std.testing.expectEqual(@as(f32, 2), canvas.items()[0].position[1]);
    const before = canvas.len;
    try canvas.text(1.2, 2.2, "A", 16, .{ 1, 1, 1 });
    const strike = font.strike(16);
    const x = canvas.items()[before].position[0] * 2;
    try std.testing.expectEqual(@round(x), x);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2) + @as(f32, @floatFromInt(strike.glyph('A').left)) * 16 / strike.size, canvas.items()[before].position[0], 0.5);
}

test "strokes use ring corners and color glyphs sample the color atlas" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var vertices: [64]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    try canvas.roundRectStroke(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, .{ 1, 1, 1 }, 8, 2);
    try std.testing.expectEqual(@as(usize, 8 * 6), canvas.len);
    try std.testing.expectEqual(@as(f32, 1.25), canvas.items()[canvas.len - 1].mode);
}

test "rounded rectangles draw distance-field corners and honor custom radius" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var vertices: [180]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    try canvas.roundRect(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, .{ 1, 1, 1 }, 5);
    try std.testing.expectEqual(@as(usize, 7 * 6), canvas.len);
    var corners: usize = 0;
    for (canvas.items()) |vertex| {
        if (vertex.position[0] == 0 and vertex.position[1] == 0) try std.testing.expectEqual(@as(f32, 1), vertex.mode);
        if (vertex.mode == 1) corners += 1;
    }
    try std.testing.expectEqual(@as(usize, 4 * 6), corners);
}

test "sRGB target linearizes theme colors before framebuffer encoding" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var vertices: [6]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    canvas.srgb_target = true;
    try canvas.rect(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ 0.5, 0.5, 0.5 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.214), canvas.items()[0].color[0], 0.001);
}

test "translucent backdrop retains alpha and rejects invalid opacity" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var vertices: [6]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    const area = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try canvas.rectAlpha(area, .{ 0, 0, 0 }, 0.4);
    try std.testing.expectEqual(@as(f32, 0.4), canvas.items()[0].color[3]);
    try std.testing.expectError(error.InvalidAlpha, canvas.rectAlpha(area, .{ 0, 0, 0 }, -1));
}

test "gradient triangles clip exactly and interpolate corner colors" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var vertices: [32]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    canvas.clip = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try canvas.triangle(.{ .{ -10, 5 }, .{ 20, 5 }, .{ 5, 20 } }, .{ .{ 1, 0, 0, 1 }, .{ 0, 0, 1, 1 }, .{ 0, 1, 0, 1 } });
    try std.testing.expect(canvas.len >= 3 and canvas.len % 3 == 0);
    for (canvas.items()) |v| {
        try std.testing.expect(v.position[0] >= 0 and v.position[0] <= 10 and v.position[1] >= 0 and v.position[1] <= 10);
        // Where the left edge crosses x = 0, red has faded a third of the way toward blue.
        if (v.position[0] == 0 and v.position[1] == 5) try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), v.color[0], 0.001);
    }
    canvas.len = 0;
    try canvas.triangle(.{ .{ 20, 20 }, .{ 30, 20 }, .{ 25, 30 } }, .{ .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 } });
    try std.testing.expectEqual(@as(usize, 0), canvas.len);
}
