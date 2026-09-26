//! Immediate-mode geometry using one texture atlas for text and shapes.
const std = @import("std");
const types = @import("types.zig");
const Font = @import("font.zig").Font;
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

    pub fn init(vertices: []Vertex, font: *const Font) Canvas {
        return .{ .vertices = vertices, .font = font };
    }
    pub fn items(self: *const Canvas) []const Vertex {
        return self.vertices[0..self.len];
    }
    pub fn rect(self: *Canvas, r: Rect, color: Color) !void {
        try self.quad(r, .{ .x = 0.5 / @as(f32, atlas_width), .y = 0.5 / @as(f32, atlas_height), .w = 0, .h = 0 }, color);
    }
    pub fn outline(self: *Canvas, r: Rect, color: Color) !void {
        try self.rect(.{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, color);
        try self.rect(.{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, color);
        try self.rect(.{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, color);
        try self.rect(.{ .x = r.x + r.w - 1, .y = r.y, .w = 1, .h = r.h }, color);
    }
    pub fn text(self: *Canvas, x: f32, y: f32, value: []const u8, size: f32, color: Color) !void {
        if (size <= 0) return;
        const scale = size / self.font.size;
        var at = x;
        // ponytail: atlas covers printable ASCII; other Unicode codepoints show one fallback glyph until dynamic atlases are needed.
        for (value) |byte| {
            if (byte & 0xc0 == 0x80) continue;
            const g = self.font.glyph(byte);
            if (g.w > 0 and g.h > 0) try self.quad(
                .{ .x = at + @as(f32, @floatFromInt(g.left)) * scale, .y = y + (self.font.ascent - @as(f32, @floatFromInt(g.top))) * scale, .w = @as(f32, @floatFromInt(g.w)) * scale, .h = @as(f32, @floatFromInt(g.h)) * scale },
                .{ .x = @as(f32, @floatFromInt(g.x)) / atlas_width, .y = @as(f32, @floatFromInt(g.y)) / atlas_height, .w = @as(f32, @floatFromInt(g.w)) / atlas_width, .h = @as(f32, @floatFromInt(g.h)) / atlas_height },
                color,
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
    fn quad(self: *Canvas, r: Rect, uv: Rect, color: Color) !void {
        if (r.w <= 0 or r.h <= 0) return;
        if (self.len + 6 > self.vertices.len) return error.OutOfVertices;
        const rgba: [4]f32 = .{ color[0], color[1], color[2], 1 };
        const a = Vertex{ .position = .{ r.x, r.y }, .color = rgba, .uv = .{ uv.x, uv.y } };
        const b = Vertex{ .position = .{ r.x + r.w, r.y }, .color = rgba, .uv = .{ uv.x + uv.w, uv.y } };
        const c = Vertex{ .position = .{ r.x + r.w, r.y + r.h }, .color = rgba, .uv = .{ uv.x + uv.w, uv.y + uv.h } };
        const d = Vertex{ .position = .{ r.x, r.y + r.h }, .color = rgba, .uv = .{ uv.x, uv.y + uv.h } };
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
