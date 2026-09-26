//! Scroll position, clamping, and draggable scrollbar thumbs.
const std = @import("std");
const Rect = @import("types.zig").Rect;
const Vec2 = @import("types.zig").Vec2;
const Canvas = @import("canvas.zig").Canvas;

pub const ScrollState = struct {
    pub const Axis = enum { vertical, horizontal };
    pub const MessageStart = enum { start, end };
    offset: Vec2 = .zero,
    viewport: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    content: Vec2 = .zero,
    vertical_bar: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    horizontal_bar: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    dragging: enum { none, vertical, horizontal } = .none,
    anchor: f32 = 0,
    message_mode: bool = false,
    message_start: MessageStart = .end,
    auto_scroll: bool = false,
    following_messages: bool = false,
    messages_initialized: bool = false,
    pending_prepend: f32 = 0,

    pub fn clamp(self: *ScrollState) void {
        self.offset.x = std.math.clamp(self.offset.x, 0, @max(0, self.content.x - self.viewport.w));
        self.offset.y = std.math.clamp(self.offset.y, 0, @max(0, self.content.y - self.viewport.h));
        if (self.dragging == .horizontal and self.content.x <= self.viewport.w) self.dragging = .none;
        if (self.dragging == .vertical and self.content.y <= self.viewport.h) self.dragging = .none;
    }
    pub fn wheel(self: *ScrollState, dx: f32, dy: f32) void {
        if (self.message_mode and dy > 0) self.following_messages = false;
        self.offset.x -= dx * 40;
        self.offset.y -= dy * 40;
        self.clamp();
        if (self.message_mode and self.auto_scroll and dy < 0 and self.atMessageEnd()) self.following_messages = true;
    }
    pub fn updateLayout(self: *ScrollState, viewport: Rect, content: Vec2) void {
        self.viewport = viewport;
        self.content = content;
        if (self.message_mode) {
            if (content.y == 0) {
                self.offset.y = 0;
                self.following_messages = false;
                self.messages_initialized = false;
            } else if (!self.messages_initialized) {
                self.offset.y = if (self.message_start == .end) self.messageEnd() else 0;
                self.following_messages = self.auto_scroll and self.message_start == .end;
                self.messages_initialized = true;
            } else if (self.following_messages and self.auto_scroll) {
                self.offset.y = self.messageEnd();
            } else {
                self.offset.y += self.pending_prepend;
            }
            self.pending_prepend = 0;
        }
        self.clamp();
    }
    fn messageEnd(self: *const ScrollState) f32 {
        return @max(0, self.content.y - self.viewport.h);
    }
    pub fn atMessageEnd(self: *const ScrollState) bool {
        return self.offset.y >= self.messageEnd() - 1;
    }
    pub fn jumpToMessageEnd(self: *ScrollState) void {
        self.offset.y = self.messageEnd();
        self.following_messages = self.auto_scroll;
    }
    pub fn preserveMessagePrepend(self: *ScrollState, added_height: f32) !void {
        if (!self.message_mode or !std.math.isFinite(added_height) or added_height < 0) return error.InvalidPrepend;
        const total = self.pending_prepend + added_height;
        if (!std.math.isFinite(total)) return error.InvalidPrepend;
        self.pending_prepend = total;
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
            if (self.message_mode) self.following_messages = false;
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
        if (self.message_mode and self.auto_scroll and self.dragging == .vertical and self.atMessageEnd()) self.following_messages = true;
    }
    pub fn pointerUp(self: *ScrollState) void {
        self.dragging = .none;
    }
    pub fn drawBar(self: *const ScrollState, c: *Canvas, axis: Axis) !void {
        if (axis == .vertical and self.vertical_bar.h >= 16 and self.content.y > self.viewport.h) {
            try c.rect(.{ .x = self.vertical_bar.x + (self.vertical_bar.w - 6) / 2, .y = self.vertical_bar.y + 4, .w = 6, .h = self.vertical_bar.h - 8 }, c.theme.border);
            try c.roundRect(self.verticalThumb(), c.theme.muted_foreground, @min(c.theme.radiusSm(), 3));
        }
        if (axis == .horizontal and self.horizontal_bar.w >= 16 and self.content.x > self.viewport.w) {
            try c.rect(.{ .x = self.horizontal_bar.x + 4, .y = self.horizontal_bar.y + (self.horizontal_bar.h - 6) / 2, .w = self.horizontal_bar.w - 8, .h = 6 }, c.theme.border);
            try c.roundRect(self.horizontalThumb(), c.theme.muted_foreground, @min(c.theme.radiusSm(), 3));
        }
    }
};

test "message scroller opens at end and follows only with auto-scroll" {
    const viewport = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    var passive = ScrollState{ .message_mode = true };
    passive.updateLayout(viewport, Vec2.init(100, 240));
    try std.testing.expectEqual(@as(f32, 140), passive.offset.y);
    passive.updateLayout(viewport, Vec2.init(100, 280));
    try std.testing.expectEqual(@as(f32, 140), passive.offset.y);
    passive.jumpToMessageEnd();
    try std.testing.expectEqual(@as(f32, 180), passive.offset.y);
    passive.updateLayout(viewport, Vec2.init(100, 300));
    try std.testing.expectEqual(@as(f32, 180), passive.offset.y);

    var following = ScrollState{ .message_mode = true, .auto_scroll = true };
    following.updateLayout(viewport, Vec2.init(100, 240));
    following.updateLayout(viewport, Vec2.init(100, 280));
    try std.testing.expectEqual(@as(f32, 180), following.offset.y);
    following.wheel(0, 1);
    try std.testing.expectEqual(@as(f32, 140), following.offset.y);
    following.updateLayout(viewport, Vec2.init(100, 300));
    try std.testing.expectEqual(@as(f32, 140), following.offset.y);
    following.wheel(0, -10);
    try std.testing.expect(following.atMessageEnd());
    following.updateLayout(viewport, Vec2.init(100, 340));
    try std.testing.expectEqual(@as(f32, 240), following.offset.y);
}

test "message scroller restores prepends, deferred content, and start position" {
    const viewport = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    var state = ScrollState{ .message_mode = true, .message_start = .start };
    state.updateLayout(viewport, Vec2.init(100, 0));
    try std.testing.expect(!state.messages_initialized);
    state.updateLayout(viewport, Vec2.init(100, 240));
    try std.testing.expectEqual(@as(f32, 0), state.offset.y);
    state.wheel(0, -2);
    try std.testing.expectEqual(@as(f32, 80), state.offset.y);
    try state.preserveMessagePrepend(30);
    state.updateLayout(viewport, Vec2.init(100, 270));
    try std.testing.expectEqual(@as(f32, 110), state.offset.y);
    try std.testing.expectError(error.InvalidPrepend, state.preserveMessagePrepend(-1));
    state.updateLayout(viewport, Vec2.init(100, 0));
    try std.testing.expect(!state.messages_initialized);
    state.updateLayout(viewport, Vec2.init(100, 260));
    try std.testing.expectEqual(@as(f32, 0), state.offset.y);
}

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
