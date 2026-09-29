const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

/// shadcn/ui badge variants.
pub const Variant = enum { default, secondary, destructive, outline };

pub fn draw(c: *Canvas, r: Rect, label: []const u8, variant: Variant) !void {
    const t = c.theme;
    switch (variant) {
        .default => try c.roundRect(r, t.primary, r.h / 2),
        .secondary => try c.roundRect(r, t.secondary, r.h / 2),
        .destructive => try c.roundRect(r, t.destructive, r.h / 2),
        .outline => {
            try c.roundRect(r, t.border, r.h / 2);
            try c.roundRect(r.inset(1), t.card, r.h / 2 - 1);
        },
    }
    const color = switch (variant) {
        .default => t.primary_foreground,
        .secondary => t.secondary_foreground,
        .destructive => @import("../types.zig").onColor(t.destructive),
        .outline => t.foreground,
    };
    try c.textIn(r, label, t.small_text_size, color, .center);
}
