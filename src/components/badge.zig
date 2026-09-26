const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

pub fn draw(c: *Canvas, r: Rect, label: []const u8) !void {
    try c.rect(r, c.theme.accent);
    try c.text(r.x + 9, r.y + 5, label, 14, c.theme.foreground);
}
