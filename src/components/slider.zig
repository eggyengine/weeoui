const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

/// Value is normalized to 0..1; input handling belongs to the caller.
pub fn draw(c: *Canvas, r: Rect, value: f32, focused: bool) !void {
    const track = Rect{ .x = r.x + 8, .y = r.center().y - 2, .w = @max(0, r.w - 16), .h = 4 };
    try c.rect(track, c.theme.border);
    const x = track.x + track.w * @max(0, @min(1, value));
    if (focused) try c.outline(.{ .x = x - 10, .y = r.center().y - 10, .w = 20, .h = 20 }, c.theme.ring);
    try c.rect(.{ .x = x - 7, .y = r.center().y - 7, .w = 14, .h = 14 }, c.theme.primary);
}
