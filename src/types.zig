pub const Color = [3]f32;
pub const Vec2 = @import("eggenvector").Vec2;
pub const Vertex = extern struct { position: [2]f32, color: [4]f32, uv: [2]f32 };
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    pub fn center(self: Rect) Vec2 {
        return Vec2.init(self.x, self.y).add(Vec2.init(self.w, self.h).scale(0.5));
    }
    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }
    pub fn intersection(self: Rect, other: Rect) Rect {
        const x = @max(self.x, other.x);
        const y = @max(self.y, other.y);
        return .{ .x = x, .y = y, .w = @max(0, @min(self.x + self.w, other.x + other.w) - x), .h = @max(0, @min(self.y + self.h, other.y + other.h) - y) };
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
