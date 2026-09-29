const std = @import("std");

pub const Color = [3]f32;
pub const Vec2 = @import("eggenvector").Vec2;
/// How the fragment shader reads the atlas: 0 coverage, 1 distance-field fill, 1 + f a
/// distance-field ring `f` of the radius thick, -1 the color atlas (emoji).
pub const Vertex = extern struct { position: [2]f32, color: [4]f32, uv: [2]f32, mode: f32 = 0 };
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    pub fn center(self: Rect) Vec2 {
        return Vec2.init(self.x, self.y).add(Vec2.init(self.w, self.h).scale(0.5));
    }
    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }
    pub fn intersection(self: Rect, other: Rect) Rect {
        const x = @max(self.x, other.x);
        const y = @max(self.y, other.y);
        return .{ .x = x, .y = y, .w = @max(0, @min(self.x + self.w, other.x + other.w) - x), .h = @max(0, @min(self.y + self.h, other.y + other.h) - y) };
    }
    pub fn inset(self: Rect, amount: f32) Rect {
        return .{ .x = self.x + amount, .y = self.y + amount, .w = @max(0, self.w - 2 * amount), .h = @max(0, self.h - 2 * amount) };
    }
};

/// Near-black or white, whichever reads better on `fill`.
pub fn onColor(fill: Color) Color {
    const luma = 0.2126 * fill[0] + 0.7152 * fill[1] + 0.0722 * fill[2];
    return if (luma > 0.55) .{ 0.08, 0.07, 0.06 } else .{ 1, 1, 1 };
}

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ @as(f32, @floatFromInt(r)) / 255, @as(f32, @floatFromInt(g)) / 255, @as(f32, @floatFromInt(b)) / 255 };
}

/// shadcn/ui tokens are OKLCH. L 0..1, C chroma, H degrees.
pub fn oklch(L: f32, C: f32, H: f32) Color {
    const rad = H * std.math.pi / 180;
    const a = C * @cos(rad);
    const b = C * @sin(rad);
    const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
    const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
    const s_ = L - 0.0894841775 * a - 1.2914855480 * b;
    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;
    return .{
        srgbChannel(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
        srgbChannel(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
        srgbChannel(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
    };
}

fn srgbChannel(linear: f32) f32 {
    const c = std.math.clamp(linear, 0, 1);
    return if (c <= 0.0031308) 12.92 * c else 1.055 * @exp(@log(c) / 2.4) - 0.055;
}

pub fn linearChannel(srgb: f32) f32 {
    const c = std.math.clamp(srgb, 0, 1);
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

/// Warm "Yolk" tokens; names follow https://ui.shadcn.com/docs/theming.
pub const Theme = struct {
    background: Color = rgb(0xFA, 0xF7, 0xF2),
    foreground: Color = rgb(0x1C, 0x19, 0x15),
    card: Color = rgb(0xFF, 0xFF, 0xFF),
    card_foreground: Color = rgb(0x1C, 0x19, 0x15),
    popover: Color = rgb(0xFF, 0xFF, 0xFF),
    popover_foreground: Color = rgb(0x1C, 0x19, 0x15),
    primary: Color = rgb(0xF2, 0xB2, 0x33),
    primary_foreground: Color = rgb(0x1C, 0x19, 0x15),
    secondary: Color = rgb(0xF3, 0xEE, 0xE6),
    secondary_foreground: Color = rgb(0x1C, 0x19, 0x15),
    muted: Color = rgb(0xF3, 0xEE, 0xE6),
    muted_foreground: Color = rgb(0x6B, 0x63, 0x58),
    accent: Color = rgb(0xFC, 0xEF, 0xD2),
    accent_foreground: Color = rgb(0x7A, 0x4E, 0x00),
    destructive: Color = rgb(0xB4, 0x23, 0x18),
    border: Color = rgb(0xE8, 0xE1, 0xD6),
    input: Color = rgb(0xD8, 0xCE, 0xBF),
    ring: Color = rgb(0xE6, 0xA0, 0x19),
    radius: f32 = 10,
    text_size: f32 = 14,
    small_text_size: f32 = 13,

    pub const dark: Theme = .{
        .background = rgb(0x15, 0x12, 0x0F),
        .foreground = rgb(0xF3, 0xEE, 0xE6),
        .card = rgb(0x1E, 0x1A, 0x16),
        .card_foreground = rgb(0xF3, 0xEE, 0xE6),
        .popover = rgb(0x1E, 0x1A, 0x16),
        .popover_foreground = rgb(0xF3, 0xEE, 0xE6),
        .primary = rgb(0xF5, 0xBE, 0x4A),
        .primary_foreground = rgb(0x1A, 0x16, 0x11),
        .secondary = rgb(0x29, 0x24, 0x1F),
        .secondary_foreground = rgb(0xF3, 0xEE, 0xE6),
        .muted = rgb(0x29, 0x24, 0x1F),
        .muted_foreground = rgb(0xA6, 0x9C, 0x8F),
        .accent = rgb(0x3A, 0x2E, 0x14),
        .accent_foreground = rgb(0xF5, 0xC9, 0x69),
        .destructive = rgb(0xF9, 0x70, 0x66),
        .border = rgb(0x2E, 0x28, 0x23),
        .input = rgb(0x43, 0x3B, 0x32),
        .ring = rgb(0xF5, 0xBE, 0x4A),
    };

    pub fn radiusSm(self: Theme) f32 {
        return self.radius * 0.6;
    }
    pub fn radiusMd(self: Theme) f32 {
        return self.radius * 0.8;
    }
    pub fn radiusLg(self: Theme) f32 {
        return self.radius;
    }
    pub fn radiusXl(self: Theme) f32 {
        return self.radius * 1.4;
    }
};

test "oklch maps shadcn white and near-black" {
    const white = oklch(1, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), white[0], 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 1), white[1], 0.02);
    const ink = oklch(0.145, 0, 0);
    try std.testing.expect(ink[0] < 0.2 and ink[1] < 0.2 and ink[2] < 0.2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.205), srgbChannel(linearChannel(0.205)), 0.001);
}

test "radius scale follows shadcn multipliers" {
    const theme = Theme{};
    try std.testing.expectEqual(theme.radius, theme.radiusLg());
    try std.testing.expectApproxEqAbs(theme.radius * 0.6, theme.radiusSm(), 0.001);
    try std.testing.expectApproxEqAbs(theme.radius * 1.4, theme.radiusXl(), 0.001);
}
