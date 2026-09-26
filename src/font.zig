//! FreeType rasterization into a compact grayscale atlas.
const std = @import("std");
const c = @import("freetype").c;

pub const atlas_width = 512;
pub const atlas_height = 512;

pub const Glyph = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
    left: i16 = 0,
    top: i16 = 0,
    advance: f32 = 0,
};

pub const Font = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    glyphs: [95]Glyph = [_]Glyph{.{}} ** 95,
    size: f32,
    ascent: f32,

    /// Rasterize printable ASCII from any TTF/OTF bytes. Bytes are borrowed only during init.
    pub fn init(allocator: std.mem.Allocator, bytes: []const u8, pixel_size: u32) !Font {
        if (bytes.len == 0 or pixel_size == 0 or pixel_size > 64) return error.InvalidFont;
        var library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
        defer _ = c.FT_Done_FreeType(library);
        var face: c.FT_Face = undefined;
        if (c.FT_New_Memory_Face(library, bytes.ptr, @intCast(bytes.len), 0, &face) != 0) return error.InvalidFont;
        defer _ = c.FT_Done_Face(face);
        if (c.FT_Set_Pixel_Sizes(face, 0, pixel_size) != 0) return error.InvalidFontSize;
        const pixels = try allocator.alloc(u8, atlas_width * atlas_height);
        errdefer allocator.free(pixels);
        @memset(pixels, 0);
        pixels[0] = 255; // White texel for untextured shapes.
        var font = Font{ .allocator = allocator, .pixels = pixels, .size = @floatFromInt(pixel_size), .ascent = @floatFromInt(face.*.size.*.metrics.ascender >> 6) };
        var pen_x: usize = 2;
        var pen_y: usize = 2;
        var row_h: usize = 0;
        for (32..127) |codepoint| {
            if (c.FT_Load_Char(face, codepoint, c.FT_LOAD_RENDER) != 0) return error.GlyphLoadFailed;
            const slot = face.*.glyph;
            const bitmap = slot.*.bitmap;
            const w: usize = @intCast(bitmap.width);
            const h: usize = @intCast(bitmap.rows);
            if (bitmap.pixel_mode != c.FT_PIXEL_MODE_GRAY and w * h != 0) return error.UnsupportedGlyphBitmap;
            if (pen_x + w + 1 > atlas_width) {
                pen_x = 2;
                pen_y += row_h + 2;
                row_h = 0;
            }
            if (pen_y + h + 1 > atlas_height) return error.AtlasFull;
            if (w * h != 0) {
                const source: [*]const u8 = @ptrCast(bitmap.buffer);
                const pitch: isize = bitmap.pitch;
                for (0..h) |row| {
                    const source_row = if (pitch >= 0) row else h - 1 - row;
                    const start = source_row * @as(usize, @intCast(@abs(pitch)));
                    @memcpy(pixels[(pen_y + row) * atlas_width + pen_x ..][0..w], source[start..][0..w]);
                }
            }
            font.glyphs[codepoint - 32] = .{
                .x = @intCast(pen_x),
                .y = @intCast(pen_y),
                .w = @intCast(w),
                .h = @intCast(h),
                .left = @intCast(slot.*.bitmap_left),
                .top = @intCast(slot.*.bitmap_top),
                .advance = @as(f32, @floatFromInt(slot.*.advance.x)) / 64,
            };
            pen_x += w + 2;
            row_h = @max(row_h, h);
        }
        return font;
    }

    pub fn deinit(self: *Font) void {
        self.allocator.free(self.pixels);
    }
    pub fn glyph(self: *const Font, byte: u8) Glyph {
        return self.glyphs[if (byte >= 32 and byte <= 126) byte - 32 else '?' - 32];
    }
    pub fn measure(self: *const Font, value: []const u8, size: f32) f32 {
        var width: f32 = 0;
        for (value) |byte| {
            if (byte & 0xc0 == 0x80) continue;
            width += self.glyph(byte).advance * size / self.size;
        }
        return width;
    }
};

test "rasterize supplied font and measure text" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 32);
    defer font.deinit();
    try std.testing.expect(font.measure("Hello", 16) > font.measure("Hi", 16));
    try std.testing.expect(font.glyph('A').w > 0);
}
