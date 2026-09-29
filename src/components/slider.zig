const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

/// Value is normalized to 0..1; input handling belongs to the caller.
pub fn draw(c: *Canvas, r: Rect, value: f32) !void {
    const track = Rect{ .x = r.x + 8, .y = r.center().y - 3, .w = @max(0, r.w - 16), .h = 6 };
    try c.roundRect(track, c.theme.border, 3);
    const x = track.x + track.w * @max(0, @min(1, value));
    if (x > track.x) try c.roundRect(.{ .x = track.x, .y = track.y, .w = x - track.x, .h = track.h }, c.theme.primary, 3);
    const thumb = Rect{ .x = x - 8, .y = r.center().y - 8, .w = 16, .h = 16 };
    try c.roundRect(thumb, c.theme.primary, 8);
    try c.roundRect(thumb.inset(1.5), .{ 1, 1, 1 }, 6.5);
}
