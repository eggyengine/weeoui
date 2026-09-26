const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

pub fn draw(c: *Canvas, r: Rect, label: []const u8, checked: bool, focused: bool) !void {
    const box = Rect{ .x = r.x, .y = r.center().y - 10, .w = 20, .h = 20 };
    if (focused) try c.outline(.{ .x = box.x - 3, .y = box.y - 3, .w = 26, .h = 26 }, c.theme.ring);
    try c.rect(box, if (checked) c.theme.primary else c.theme.surface);
    if (!checked) try c.outline(box, c.theme.border);
    if (checked) try c.textIn(box, "X", 15, c.theme.primary_text, .center);
    try c.textIn(.{ .x = r.x + 32, .y = r.y, .w = r.w - 32, .h = r.h }, label, 16, c.theme.foreground, .start);
}
