const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../types.zig").Rect;

/// shadcn/ui button variants.
pub const Variant = enum { default, secondary, outline, ghost, destructive, link };

/// shadcn/ui button sizes: `sm` is the compact one desktop menu bars use.
pub const Size = enum {
    default,
    sm,

    /// The label's text size: the theme's for `default`.
    pub fn textSize(size: Size, theme: @import("../types.zig").Theme) f32 {
        return switch (size) {
            .default => theme.text_size,
            .sm => sm_text_size,
        };
    }

    /// Horizontal padding around the label, on each side.
    pub fn padding(size: Size) f32 {
        return switch (size) {
            .default => 16,
            .sm => 8,
        };
    }
};
/// `Size.sm`'s text size, for menus and other compact controls.
pub const sm_text_size: f32 = 12;
pub const sm_small_text_size: f32 = 11;

pub fn draw(c: *Canvas, r: Rect, label: []const u8, variant: Variant, size: Size, hot: bool) !void {
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
    const text_size = size.textSize(t);
    try c.textIn(r, label, text_size, color, .center);
    if (variant == .link and hot) {
        const ink = c.font.inkBounds(label, text_size);
        const x = r.center().x - ink.w / 2;
        try c.rect(.{ .x = x, .y = r.center().y + ink.h / 2 + 2, .w = ink.w, .h = 1 }, color);
    }
}
