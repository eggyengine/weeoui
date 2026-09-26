const std = @import("std");

pub const Color = [3]f32;
pub const Vec2 = @import("eggenvector").Vec2;
pub const Vertex = extern struct { position: [2]f32, color: [4]f32, uv: [2]f32 };
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

/// Neutral light tokens from https://ui.shadcn.com/docs/theming
pub const Theme = struct {
    background: Color = oklch(1, 0, 0),
    foreground: Color = oklch(0.145, 0, 0),
    card: Color = oklch(1, 0, 0),
    card_foreground: Color = oklch(0.145, 0, 0),
    popover: Color = oklch(1, 0, 0),
    popover_foreground: Color = oklch(0.145, 0, 0),
    primary: Color = oklch(0.205, 0, 0),
    primary_foreground: Color = oklch(0.985, 0, 0),
    secondary: Color = oklch(0.97, 0, 0),
    secondary_foreground: Color = oklch(0.205, 0, 0),
    muted: Color = oklch(0.97, 0, 0),
    muted_foreground: Color = oklch(0.556, 0, 0),
    accent: Color = oklch(0.97, 0, 0),
    accent_foreground: Color = oklch(0.205, 0, 0),
    destructive: Color = oklch(0.577, 0.245, 27.325),
    border: Color = oklch(0.922, 0, 0),
    input: Color = oklch(0.922, 0, 0),
    ring: Color = oklch(0.708, 0, 0),
    radius: f32 = 10,
    text_size: f32 = 16,
    small_text_size: f32 = 14,

    pub const dark: Theme = .{
        .background = oklch(0.145, 0, 0),
        .foreground = oklch(0.985, 0, 0),
        .card = oklch(0.205, 0, 0),
        .card_foreground = oklch(0.985, 0, 0),
        .popover = oklch(0.205, 0, 0),
        .popover_foreground = oklch(0.985, 0, 0),
        .primary = oklch(0.922, 0, 0),
        .primary_foreground = oklch(0.205, 0, 0),
        .secondary = oklch(0.269, 0, 0),
        .secondary_foreground = oklch(0.985, 0, 0),
        .muted = oklch(0.269, 0, 0),
        .muted_foreground = oklch(0.708, 0, 0),
        .accent = oklch(0.269, 0, 0),
        .accent_foreground = oklch(0.985, 0, 0),
        .destructive = oklch(0.704, 0.191, 22.216),
        .border = oklch(0.269, 0, 0),
        .input = oklch(0.269, 0, 0),
        .ring = oklch(0.556, 0, 0),
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
