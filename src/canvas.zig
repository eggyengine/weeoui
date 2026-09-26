//! Immediate-mode geometry using one texture atlas for text and shapes.
const std = @import("std");
const types = @import("types.zig");
const Font = @import("font.zig").Font;
const Icon = @import("font.zig").Icon;
const atlas_width = @import("font.zig").atlas_width;
const atlas_height = @import("font.zig").atlas_height;
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
        const sx = self.pixel_scale[0];
        const sy = self.pixel_scale[1];
        const x = @round(r.x * sx);
        const y = @round(r.y * sy);
        const right = @max(x + 1, @round((r.x + r.w) * sx));
        const bottom = @max(y + 1, @round((r.y + r.h) * sy));
        try self.quad(.{ .x = x / sx, .y = y / sy, .w = (right - x) / sx, .h = (bottom - y) / sy }, .{ .x = 0.5 / @as(f32, atlas_width), .y = 0.5 / @as(f32, atlas_height), .w = 0, .h = 0 }, color, alpha);
    }
    pub fn roundRect(self: *Canvas, r: Rect, color: Color, radius: f32) !void {
        if (r.w <= 0 or r.h <= 0) return;
        const corner = @max(0, @min(radius, @min(r.w, r.h) / 2));
        if (corner < 1) return self.rect(r, color);
        try self.rect(.{ .x = r.x, .y = r.y + corner, .w = r.w, .h = r.h - 2 * corner }, color);
        var y: f32 = 0;
        while (y < corner) {
            const band = @min(1 / @max(1, self.pixel_scale[1]), corner - y);
            const dy = corner - y - band / 2;
            const inset = corner - @sqrt(@max(0, corner * corner - dy * dy));
            const strip = Rect{ .x = r.x + inset, .y = r.y + y, .w = r.w - 2 * inset, .h = band };
            try self.rect(strip, color);
            try self.rect(.{ .x = strip.x, .y = r.y + r.h - y - band, .w = strip.w, .h = band }, color);
            y += band;
        }
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
        }, color, 1);
    }
    pub fn text(self: *Canvas, x: f32, y: f32, value: []const u8, size: f32, color: Color) !void {
        if (size <= 0) return;
        const strike = self.font.strike(size);
        const scale = size / strike.size;
        var at = x;
        // ponytail: atlas covers printable ASCII; other Unicode codepoints show one fallback glyph until dynamic atlases are needed.
        for (value) |byte| {
            if (byte & 0xc0 == 0x80) continue;
            const g = strike.glyph(byte);
            if (g.w > 0 and g.h > 0) try self.quad(
                .{ .x = at + @as(f32, @floatFromInt(g.left)) * scale, .y = y + (strike.ascent - @as(f32, @floatFromInt(g.top))) * scale, .w = @as(f32, @floatFromInt(g.w)) * scale, .h = @as(f32, @floatFromInt(g.h)) * scale },
                .{ .x = @as(f32, @floatFromInt(g.x)) / atlas_width, .y = @as(f32, @floatFromInt(g.y)) / atlas_height, .w = @as(f32, @floatFromInt(g.w)) / atlas_width, .h = @as(f32, @floatFromInt(g.h)) / atlas_height },
                color,
                1,
            );
            at += g.advance * scale;
        }
    }
    pub const TextAlign = enum { start, center, end };
    /// Align visible ink within a rectangle; all components share the same vertical center.
    pub fn textIn(self: *Canvas, r: Rect, value: []const u8, size: f32, color: Color, alignment: TextAlign) !void {
        const ink = self.font.inkBounds(value, size);
        const center = r.center();
        const x = switch (alignment) {
            .start => r.x - ink.x,
            .center => center.x - ink.x - ink.w / 2,
            .end => r.x + r.w - ink.x - ink.w,
        };
        try self.text(x, center.y - ink.y - ink.h / 2, value, size, color);
    }
    pub fn textWrappedIn(self: *Canvas, r: Rect, value: []const u8, size: f32, color: Color) !void {
        return self.textWrappedInAligned(r, value, size, color, .start);
    }
    pub fn textWrappedInAligned(self: *Canvas, r: Rect, value: []const u8, size: f32, color: Color, alignment: TextAlign) !void {
        var iter = self.font.lines(value, size, r.w);
        var y = r.y;
        const line_height = size * 1.35;
        while (iter.next()) |line| {
            try self.textIn(.{ .x = r.x, .y = y, .w = r.w, .h = line_height }, line, size, color, alignment);
            y += line_height;
        }
    }
    fn quad(self: *Canvas, r: Rect, uv: Rect, color: Color, alpha: f32) !void {
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
        const a = Vertex{ .position = .{ visible.x, visible.y }, .color = rgba, .uv = .{ u_start, v_start } };
        const b = Vertex{ .position = .{ visible.x + visible.w, visible.y }, .color = rgba, .uv = .{ u_end, v_start } };
        const c = Vertex{ .position = .{ visible.x + visible.w, visible.y + visible.h }, .color = rgba, .uv = .{ u_end, v_end } };
        const d = Vertex{ .position = .{ visible.x, visible.y + visible.h }, .color = rgba, .uv = .{ u_start, v_end } };
        const triangles = [_]Vertex{ a, b, c, a, c, d };
        @memcpy(self.vertices[self.len..][0..6], &triangles);
        self.len += 6;
    }
};

test "rectangle hit testing and geometry" {
    const r = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expect(r.contains(10, 20));
    try std.testing.expect(!r.contains(40, 20));
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var vertices: [6]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    try canvas.rect(r, .{ 1, 1, 1 });
    try std.testing.expectEqual(@as(usize, 6), canvas.items().len);
    try std.testing.expectError(error.OutOfVertices, canvas.rect(r, .{ 1, 1, 1 }));
}

test "text ink is centered in its rectangle" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 32);
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
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 32);
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
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
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
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 32);
    defer font.deinit();
    var vertices: [6]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    canvas.clip = .{ .x = 12, .y = 12, .w = 8, .h = 8 };
    try canvas.icon(.{ .x = 8, .y = 8, .w = 16, .h = 16 }, .check, .{ 1, 1, 1 });
    try std.testing.expectEqual(@as(usize, 6), canvas.len);
    try std.testing.expectEqual(@as(f32, 12), canvas.items()[0].position[0]);
    try std.testing.expect(canvas.items()[0].uv[0] > 0);
}

test "solid rectangles snap to physical pixels without changing text vertices" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
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
    try std.testing.expectApproxEqAbs(@as(f32, 1.2) + @as(f32, @floatFromInt(strike.glyph('A').left)) * 16 / strike.size, canvas.items()[before].position[0], 0.001);
}

test "rounded rectangles leave corners empty and honor custom radius" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var vertices: [180]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    try canvas.roundRect(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, .{ 1, 1, 1 }, 5);
    try std.testing.expect(canvas.len > 6);
    for (canvas.items()) |vertex| {
        try std.testing.expect(!(vertex.position[0] == 0 and vertex.position[1] == 0));
    }
}

test "sRGB target linearizes theme colors before framebuffer encoding" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var vertices: [6]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    canvas.srgb_target = true;
    try canvas.rect(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ 0.5, 0.5, 0.5 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.214), canvas.items()[0].color[0], 0.001);
}

test "translucent backdrop retains alpha and rejects invalid opacity" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var vertices: [6]Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    const area = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try canvas.rectAlpha(area, .{ 0, 0, 0 }, 0.4);
    try std.testing.expectEqual(@as(f32, 0.4), canvas.items()[0].color[3]);
    try std.testing.expectError(error.InvalidAlpha, canvas.rectAlpha(area, .{ 0, 0, 0 }, -1));
}
