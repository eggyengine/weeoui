const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

/// shadcn/ui button variants.
pub const Variant = enum { default, secondary, outline, ghost, destructive, link };

pub fn draw(c: *Canvas, r: Rect, label: []const u8, variant: Variant, hot: bool) !void {
    const radius = c.theme.radiusMd();
    const t = c.theme;
    const shade: f32 = if (hot) 0.92 else 1;
    switch (variant) {
        .default, .destructive => {
            const p = if (variant == .default) t.primary else t.destructive;
            // A darker 1px lip under the fill gives the flat button some depth.
            try c.roundRect(r, .{ p[0] * 0.82, p[1] * 0.82, p[2] * 0.82 }, radius);
            try c.roundRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h - 1 }, .{ p[0] * shade, p[1] * shade, p[2] * shade }, radius);
        },
        .secondary => try c.roundRect(r, if (hot) t.border else t.secondary, radius),
        .outline => {
            try c.roundRect(r, t.input, radius);
            try c.roundRect(r.inset(1), if (hot) t.accent else t.card, @max(0, radius - 1));
        },
        .ghost => if (hot) try c.roundRect(r, t.accent, radius),
        .link => {},
    }
    const color = switch (variant) {
        .default => t.primary_foreground,
        .destructive => @import("../types.zig").onColor(t.destructive),
        .secondary => t.secondary_foreground,
        .outline, .ghost => if (hot) t.accent_foreground else t.foreground,
        .link => t.accent_foreground,
    };
    try c.textIn(r, label, t.text_size, color, .center);
    if (variant == .link and hot) {
        const ink = c.font.inkBounds(label, t.text_size);
        const x = r.center().x - ink.w / 2;
        try c.rect(.{ .x = x, .y = r.center().y + ink.h / 2 + 2, .w = ink.w, .h = 1 }, color);
    }
}
