const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

pub fn draw(c: *Canvas, r: Rect) !void {
    try c.rect(.{ .x = r.x, .y = r.y + 3, .w = r.w, .h = r.h }, c.theme.border);
    try c.rect(r, c.theme.surface);
    try c.outline(r, c.theme.border);
}
