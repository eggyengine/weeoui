const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

pub fn draw(c: *Canvas, r: Rect, label: []const u8, enabled: bool, focused: bool) !void {
    try c.textIn(.{ .x = r.x, .y = r.y, .w = r.w - 54, .h = r.h }, label, 16, c.theme.foreground, .start);
    const track = Rect{ .x = r.x + r.w - 42, .y = r.center().y - 12, .w = 42, .h = 24 };
    if (focused) try c.outline(.{ .x = track.x - 3, .y = track.y - 3, .w = 48, .h = 30 }, c.theme.ring);
    try c.rect(track, if (enabled) c.theme.primary else c.theme.border);
    try c.rect(.{ .x = track.x + (if (enabled) @as(f32, 21) else 3), .y = track.y + 3, .w = 18, .h = 18 }, c.theme.surface);
}
