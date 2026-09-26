//! Small immediate-mode UI primitives. Coordinates are logical pixels.
const std = @import("std");

pub const Color = [3]f32;
pub const Vertex = extern struct { position: [2]f32, color: Color };
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }
};
pub const Theme = struct {
    background: Color = .{ 0.965, 0.968, 0.973 },
    surface: Color = .{ 1, 1, 1 },
    foreground: Color = .{ 0.09, 0.11, 0.15 },
    muted: Color = .{ 0.39, 0.43, 0.49 },
    border: Color = .{ 0.84, 0.86, 0.89 },
    primary: Color = .{ 0.11, 0.15, 0.22 },
    primary_text: Color = .{ 1, 1, 1 },
    accent: Color = .{ 0.93, 0.94, 0.96 },
    ring: Color = .{ 0.30, 0.43, 0.66 },
};

pub const Canvas = struct {
    vertices: []Vertex,
    len: usize = 0,
    theme: Theme = .{},

    pub fn init(vertices: []Vertex) Canvas {
        return .{ .vertices = vertices };
    }
    pub fn items(self: *const Canvas) []const Vertex {
        return self.vertices[0..self.len];
    }

    pub fn rect(self: *Canvas, r: Rect, color: Color) !void {
        if (r.w <= 0 or r.h <= 0) return;
        if (self.len + 6 > self.vertices.len) return error.OutOfVertices;
        const a = Vertex{ .position = .{ r.x, r.y }, .color = color };
        const b = Vertex{ .position = .{ r.x + r.w, r.y }, .color = color };
        const c = Vertex{ .position = .{ r.x + r.w, r.y + r.h }, .color = color };
        const d = Vertex{ .position = .{ r.x, r.y + r.h }, .color = color };
        const quad = [_]Vertex{ a, b, c, a, c, d };
        @memcpy(self.vertices[self.len..][0..6], &quad);
        self.len += 6;
    }
    pub fn outline(self: *Canvas, r: Rect, color: Color) !void {
        try self.rect(.{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, color);
        try self.rect(.{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, color);
        try self.rect(.{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, color);
        try self.rect(.{ .x = r.x + r.w - 1, .y = r.y, .w = 1, .h = r.h }, color);
    }
    pub fn text(self: *Canvas, x: f32, y: f32, value: []const u8, scale: f32, color: Color) !void {
        var at = x;
        for (value) |ch| {
            const rows = glyph(std.ascii.toUpper(ch));
            for (rows, 0..) |row, iy| {
                for (0..5) |ix| {
                    if (row & (@as(u8, 0x10) >> @as(u3, @intCast(ix))) != 0)
                        try self.rect(.{ .x = at + @as(f32, @floatFromInt(ix)) * scale, .y = y + @as(f32, @floatFromInt(iy)) * scale, .w = scale, .h = scale }, color);
                }
            }
            at += 6 * scale;
        }
    }
    pub fn card(self: *Canvas, r: Rect) !void {
        try self.rect(.{ .x = r.x, .y = r.y + 3, .w = r.w, .h = r.h }, self.theme.border);
        try self.rect(r, self.theme.surface);
        try self.outline(r, self.theme.border);
    }
    pub fn badge(self: *Canvas, r: Rect, label: []const u8) !void {
        try self.rect(r, self.theme.accent);
        try self.text(r.x + 9, r.y + 6, label, 1.5, self.theme.foreground);
    }
    pub fn button(self: *Canvas, r: Rect, label: []const u8, primary: bool, hot: bool, focused: bool) !void {
        if (focused) try self.outline(.{ .x = r.x - 3, .y = r.y - 3, .w = r.w + 6, .h = r.h + 6 }, self.theme.ring);
        try self.rect(r, if (primary) self.theme.primary else if (hot) self.theme.accent else self.theme.surface);
        if (!primary) try self.outline(r, self.theme.border);
        const label_w: f32 = @floatFromInt(label.len * 12);
        try self.text(r.x + (r.w - label_w) / 2, r.y + (r.h - 14) / 2, label, 2, if (primary) self.theme.primary_text else self.theme.foreground);
    }
    pub fn checkbox(self: *Canvas, r: Rect, label: []const u8, checked: bool, focused: bool) !void {
        const box = Rect{ .x = r.x, .y = r.y + 4, .w = 20, .h = 20 };
        if (focused) try self.outline(.{ .x = box.x - 3, .y = box.y - 3, .w = 26, .h = 26 }, self.theme.ring);
        try self.rect(box, if (checked) self.theme.primary else self.theme.surface);
        if (!checked) try self.outline(box, self.theme.border);
        if (checked) try self.text(box.x + 4, box.y + 3, "X", 2, self.theme.primary_text);
        try self.text(r.x + 32, r.y + 7, label, 2, self.theme.foreground);
    }
    pub fn toggle(self: *Canvas, r: Rect, label: []const u8, enabled: bool, focused: bool) !void {
        try self.text(r.x, r.y + 7, label, 2, self.theme.foreground);
        const track = Rect{ .x = r.x + r.w - 42, .y = r.y + 2, .w = 42, .h = 24 };
        if (focused) try self.outline(.{ .x = track.x - 3, .y = track.y - 3, .w = 48, .h = 30 }, self.theme.ring);
        try self.rect(track, if (enabled) self.theme.primary else self.theme.border);
        try self.rect(.{ .x = track.x + (if (enabled) @as(f32, 21) else 3), .y = track.y + 3, .w = 18, .h = 18 }, self.theme.surface);
    }
};

fn glyph(ch: u8) [7]u8 {
    return switch (ch) {
        'A' => .{ 14, 17, 17, 31, 17, 17, 17 },
        'B' => .{ 30, 17, 17, 30, 17, 17, 30 },
        'C' => .{ 14, 17, 16, 16, 16, 17, 14 },
        'D' => .{ 30, 17, 17, 17, 17, 17, 30 },
        'E' => .{ 31, 16, 16, 30, 16, 16, 31 },
        'F' => .{ 31, 16, 16, 30, 16, 16, 16 },
        'G' => .{ 14, 17, 16, 23, 17, 17, 14 },
        'H' => .{ 17, 17, 17, 31, 17, 17, 17 },
        'I' => .{ 31, 4, 4, 4, 4, 4, 31 },
        'J' => .{ 7, 2, 2, 2, 18, 18, 12 },
        'K' => .{ 17, 18, 20, 24, 20, 18, 17 },
        'L' => .{ 16, 16, 16, 16, 16, 16, 31 },
        'M' => .{ 17, 27, 21, 21, 17, 17, 17 },
        'N' => .{ 17, 25, 21, 19, 17, 17, 17 },
        'O' => .{ 14, 17, 17, 17, 17, 17, 14 },
        'P' => .{ 30, 17, 17, 30, 16, 16, 16 },
        'Q' => .{ 14, 17, 17, 17, 21, 18, 13 },
        'R' => .{ 30, 17, 17, 30, 20, 18, 17 },
        'S' => .{ 15, 16, 16, 14, 1, 1, 30 },
        'T' => .{ 31, 4, 4, 4, 4, 4, 4 },
        'U' => .{ 17, 17, 17, 17, 17, 17, 14 },
        'V' => .{ 17, 17, 17, 17, 17, 10, 4 },
        'W' => .{ 17, 17, 17, 21, 21, 21, 10 },
        'X' => .{ 17, 17, 10, 4, 10, 17, 17 },
        'Y' => .{ 17, 17, 10, 4, 4, 4, 4 },
        'Z' => .{ 31, 1, 2, 4, 8, 16, 31 },
        '0' => .{ 14, 17, 19, 21, 25, 17, 14 },
        '1' => .{ 4, 12, 4, 4, 4, 4, 14 },
        '2' => .{ 14, 17, 1, 2, 4, 8, 31 },
        '3' => .{ 30, 1, 1, 14, 1, 1, 30 },
        '4' => .{ 2, 6, 10, 18, 31, 2, 2 },
        '5' => .{ 31, 16, 30, 1, 1, 17, 14 },
        '6' => .{ 6, 8, 16, 30, 17, 17, 14 },
        '7' => .{ 31, 1, 2, 4, 8, 8, 8 },
        '8' => .{ 14, 17, 17, 14, 17, 17, 14 },
        '9' => .{ 14, 17, 17, 15, 1, 2, 12 },
        ':' => .{ 0, 4, 4, 0, 4, 4, 0 },
        '.' => .{ 0, 0, 0, 0, 0, 12, 12 },
        '-' => .{ 0, 0, 0, 31, 0, 0, 0 },
        '/' => .{ 1, 2, 2, 4, 8, 8, 16 },
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        else => .{ 31, 17, 1, 6, 4, 0, 4 },
    };
}

test "rectangle hit testing and geometry" {
    const r = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expect(r.contains(10, 20));
    try std.testing.expect(!r.contains(40, 20));
    var vertices: [6]Vertex = undefined;
    var canvas = Canvas.init(&vertices);
    try canvas.rect(r, .{ 1, 1, 1 });
    try std.testing.expectEqual(@as(usize, 6), canvas.items().len);
    try std.testing.expectError(error.OutOfVertices, canvas.rect(r, .{ 1, 1, 1 }));
}
