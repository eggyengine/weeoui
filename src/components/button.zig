const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

pub fn draw(c: *Canvas, r: Rect, label: []const u8, primary: bool, hot: bool, focused: bool) !void {
    const radius = c.theme.radiusMd();
    if (focused) {
        try c.roundRect(.{ .x = r.x - 3, .y = r.y - 3, .w = r.w + 6, .h = r.h + 6 }, c.theme.ring, radius + 3);
        try c.roundRect(.{ .x = r.x - 2, .y = r.y - 2, .w = r.w + 4, .h = r.h + 4 }, c.theme.background, radius + 2);
    }
    if (!primary and !hot) try c.roundRect(r, c.theme.border, radius);
    try c.roundRect(if (!primary and !hot) r.inset(1) else r, if (primary) c.theme.primary else if (hot) c.theme.accent else c.theme.secondary, radius);
    try c.textIn(r, label, c.theme.text_size, if (primary) c.theme.primary_foreground else if (hot) c.theme.accent_foreground else c.theme.secondary_foreground, .center);
}
