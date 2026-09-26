//! Scroll position, clamping, and draggable scrollbar thumbs.
const std = @import("std");
const Rect = @import("types.zig").Rect;
const Vec2 = @import("types.zig").Vec2;
const Canvas = @import("canvas.zig").Canvas;

pub const ScrollState = struct {
    pub const Axis = enum { vertical, horizontal };
    offset: Vec2 = .zero,
    viewport: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    content: Vec2 = .zero,
    vertical_bar: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    horizontal_bar: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    dragging: enum { none, vertical, horizontal } = .none,
    anchor: f32 = 0,

    pub fn clamp(self: *ScrollState) void {
        self.offset.x = std.math.clamp(self.offset.x, 0, @max(0, self.content.x - self.viewport.w));
        self.offset.y = std.math.clamp(self.offset.y, 0, @max(0, self.content.y - self.viewport.h));
        if (self.dragging == .horizontal and self.content.x <= self.viewport.w) self.dragging = .none;
        if (self.dragging == .vertical and self.content.y <= self.viewport.h) self.dragging = .none;
    }
    pub fn wheel(self: *ScrollState, dx: f32, dy: f32) void {
        self.offset.x -= dx * 40;
        self.offset.y -= dy * 40;
        self.clamp();
    }
    pub fn ensureVisible(self: *ScrollState, r: Rect) void {
        if (r.x < self.viewport.x) self.offset.x -= self.viewport.x - r.x;
        if (r.x + r.w > self.viewport.x + self.viewport.w) self.offset.x += r.x + r.w - self.viewport.x - self.viewport.w;
        if (r.y < self.viewport.y) self.offset.y -= self.viewport.y - r.y;
        if (r.y + r.h > self.viewport.y + self.viewport.h) self.offset.y += r.y + r.h - self.viewport.y - self.viewport.h;
        self.clamp();
    }
    fn verticalThumb(self: *const ScrollState) Rect {
        const track = @max(1, self.vertical_bar.h - 8);
        const h = @min(track, @max(24, track * self.viewport.h / self.content.y));
        return .{ .x = self.vertical_bar.x + (self.vertical_bar.w - 6) / 2, .y = self.vertical_bar.y + 4 + (track - h) * self.offset.y / @max(1, self.content.y - self.viewport.h), .w = 6, .h = h };
    }
    fn horizontalThumb(self: *const ScrollState) Rect {
        const track = @max(1, self.horizontal_bar.w - 8);
        const w = @min(track, @max(24, track * self.viewport.w / self.content.x));
        return .{ .x = self.horizontal_bar.x + 4 + (track - w) * self.offset.x / @max(1, self.content.x - self.viewport.w), .y = self.horizontal_bar.y + (self.horizontal_bar.h - 6) / 2, .w = w, .h = 6 };
    }
    pub fn pointerDown(self: *ScrollState, x: f32, y: f32) bool {
        if (self.vertical_bar.h >= 16 and self.content.y > self.viewport.h and self.verticalThumb().contains(x, y)) {
            self.dragging = .vertical;
            self.anchor = y - self.verticalThumb().y;
            return true;
        }
        if (self.horizontal_bar.w >= 16 and self.content.x > self.viewport.w and self.horizontalThumb().contains(x, y)) {
            self.dragging = .horizontal;
            self.anchor = x - self.horizontalThumb().x;
            return true;
        }
        return false;
    }
    pub fn pointerMove(self: *ScrollState, x: f32, y: f32) void {
        switch (self.dragging) {
            .vertical => {
                const thumb = self.verticalThumb();
                self.offset.y = (y - self.anchor - self.vertical_bar.y - 4) * (self.content.y - self.viewport.h) / @max(1, self.vertical_bar.h - 8 - thumb.h);
            },
            .horizontal => {
                const thumb = self.horizontalThumb();
                self.offset.x = (x - self.anchor - self.horizontal_bar.x - 4) * (self.content.x - self.viewport.w) / @max(1, self.horizontal_bar.w - 8 - thumb.w);
            },
            .none => return,
        }
        self.clamp();
    }
    pub fn pointerUp(self: *ScrollState) void {
        self.dragging = .none;
    }
    pub fn drawBar(self: *const ScrollState, c: *Canvas, axis: Axis) !void {
        if (axis == .vertical and self.vertical_bar.h >= 16 and self.content.y > self.viewport.h) {
            try c.rect(.{ .x = self.vertical_bar.x + (self.vertical_bar.w - 6) / 2, .y = self.vertical_bar.y + 4, .w = 6, .h = self.vertical_bar.h - 8 }, c.theme.border);
            try c.rect(self.verticalThumb(), c.theme.muted);
        }
        if (axis == .horizontal and self.horizontal_bar.w >= 16 and self.content.x > self.viewport.w) {
            try c.rect(.{ .x = self.horizontal_bar.x + 4, .y = self.horizontal_bar.y + (self.horizontal_bar.h - 6) / 2, .w = self.horizontal_bar.w - 8, .h = 6 }, c.theme.border);
            try c.rect(self.horizontalThumb(), c.theme.muted);
        }
    }
};

test "scrollbar thumb drags through content range" {
    var scroll = ScrollState{ .viewport = .{ .x = 0, .y = 0, .w = 88, .h = 100 }, .content = Vec2.init(88, 300), .vertical_bar = .{ .x = 88, .y = 0, .w = 12, .h = 100 } };
    const thumb = scroll.verticalThumb();
    try std.testing.expect(scroll.pointerDown(thumb.x + 2, thumb.y + 2));
    scroll.pointerMove(thumb.x + 2, 98);
    try std.testing.expect(scroll.offset.y > 0);
    try std.testing.expect(scroll.offset.y <= 200);
    scroll.pointerUp();
    try std.testing.expect(scroll.dragging == .none);
}
