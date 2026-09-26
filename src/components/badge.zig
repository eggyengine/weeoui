const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

pub fn draw(c: *Canvas, r: Rect, label: []const u8) !void {
    try c.roundRect(r, c.theme.secondary, c.theme.radiusSm());
    try c.textIn(r, label, c.theme.small_text_size, c.theme.secondary_foreground, .center);
}
