const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

pub fn draw(c: *Canvas, r: Rect, label: []const u8, primary: bool, hot: bool, focused: bool) !void {
    if (focused) try c.outline(.{ .x = r.x - 3, .y = r.y - 3, .w = r.w + 6, .h = r.h + 6 }, c.theme.ring);
    try c.rect(r, if (primary) c.theme.primary else if (hot) c.theme.accent else c.theme.surface);
    if (!primary) try c.outline(r, c.theme.border);
    try c.textIn(r, label, 16, if (primary) c.theme.primary_text else c.theme.foreground, .center);
}
