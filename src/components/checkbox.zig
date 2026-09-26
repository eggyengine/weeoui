const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

pub fn draw(c: *Canvas, r: Rect, label: []const u8, checked: bool, focused: bool) !void {
    const box = Rect{ .x = r.x, .y = r.center().y - 10, .w = 20, .h = 20 };
    if (focused) try c.roundRect(.{ .x = box.x - 3, .y = box.y - 3, .w = 26, .h = 26 }, c.theme.ring, c.theme.radiusSm() + 3);
    try c.roundRect(box, if (checked) c.theme.primary else c.theme.input, c.theme.radiusSm());
    if (!checked) try c.roundRect(box.inset(1), c.theme.background, @max(0, c.theme.radiusSm() - 1));
    if (checked) try c.textIn(box, "X", 15, c.theme.primary_foreground, .center);
    try c.textIn(.{ .x = r.x + 32, .y = r.y, .w = r.w - 32, .h = r.h }, label, c.theme.text_size, c.theme.foreground, .start);
}
