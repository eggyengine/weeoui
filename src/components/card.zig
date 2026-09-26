const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

pub fn draw(c: *Canvas, r: Rect) !void {
    try c.roundRect(r, c.theme.border, c.theme.radiusLg());
    try c.roundRect(r.inset(1), c.theme.card, @max(0, c.theme.radiusLg() - 1));
}
