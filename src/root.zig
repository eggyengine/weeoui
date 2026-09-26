//! Weeoui immediate-mode components and FreeType font atlas.
const types = @import("types.zig");
pub const Color = types.Color;
pub const Vertex = types.Vertex;
pub const Rect = types.Rect;
pub const Theme = types.Theme;
pub const Font = @import("font.zig").Font;
pub const Canvas = @import("canvas.zig").Canvas;
pub const default_font = @embedFile("assets/OpenSans-Regular.ttf");
pub const card = @import("components/card.zig");
pub const badge = @import("components/badge.zig");
pub const button = @import("components/button.zig");
pub const checkbox = @import("components/checkbox.zig");
pub const toggle = @import("components/toggle.zig");

test {
    _ = @import("font.zig");
    _ = @import("canvas.zig");
}
