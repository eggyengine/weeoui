const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

pub fn draw(c: *Canvas, r: Rect, label: []const u8, checked: bool) !void {
    const box = Rect{ .x = r.x, .y = r.center().y - 9, .w = 18, .h = 18 };
    const radius = c.theme.radiusSm() - 1;
    try c.roundRect(box, if (checked) c.theme.primary else c.theme.input, radius);
    if (checked) {
        try c.icon(box.inset(2), .check, c.theme.primary_foreground);
    } else {
        try c.roundRect(box.inset(1), c.theme.card, @max(0, radius - 1));
    }
    try c.textIn(.{ .x = r.x + 28, .y = r.y, .w = r.w - 28, .h = r.h }, label, c.theme.text_size, c.theme.foreground, .start);
}
