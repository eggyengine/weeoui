const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

pub fn draw(c: *Canvas, r: Rect, label: []const u8, enabled: bool) !void {
    try c.textIn(.{ .x = r.x, .y = r.y, .w = r.w - 52, .h = r.h }, label, c.theme.text_size, c.theme.foreground, .start);
    const track = Rect{ .x = r.x + r.w - 40, .y = r.center().y - 11, .w = 40, .h = 22 };
    try c.roundRect(track, if (enabled) c.theme.primary else c.theme.input, 11);
    try c.roundRect(.{ .x = track.x + (if (enabled) @as(f32, 20) else 2), .y = track.y + 2, .w = 18, .h = 18 }, .{ 1, 1, 1 }, 9);
}
