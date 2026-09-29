//! FreeType rasterization into a grayscale atlas plus a color atlas for emoji.
const std = @import("std");
const c = @import("freetype").c;
const Rect = @import("types.zig").Rect;

pub const atlas_width = 2048;
pub const atlas_height = 2048;
/// RGBA atlas holding color glyphs (emoji), filled on demand.
pub const color_atlas_size = 1024;
/// One strike per pixel size where UI text lives so glyphs map 1:1 to screen pixels.
// ponytail: sizes above 48px snap to the coarse list and scale; rasterize on demand if large text must be crisp.
const strike_sizes = blk: {
    var sizes: [48]u8 = undefined;
    for (0..43) |i| sizes[i] = 6 + i;
    for ([_]u8{ 56, 64, 72, 80, 96 }, 43..) |size, i| sizes[i] = size;
    break :blk sizes;
};
/// Quarter-disc distance field used for anti-aliased round corners and strokes.
const corner_size = 64;
pub const Icon = enum { chevron_down, chevron_left, chevron_right, check, search, calendar, chevron_up, clock, command, image, info, keyboard, menu, x, file, paperclip };
const icon_size = 48;
const icon_masks = [_][]const u8{
    @embedFile("assets/lucide/chevron-down.mask"),
    @embedFile("assets/lucide/chevron-left.mask"),
    @embedFile("assets/lucide/chevron-right.mask"),
    @embedFile("assets/lucide/check.mask"),
    @embedFile("assets/lucide/search.mask"),
    @embedFile("assets/lucide/calendar.mask"),
    @embedFile("assets/lucide/chevron-up.mask"),
    @embedFile("assets/lucide/clock.mask"),
    @embedFile("assets/lucide/command.mask"),
    @embedFile("assets/lucide/image.mask"),
    @embedFile("assets/lucide/info.mask"),
    @embedFile("assets/lucide/keyboard.mask"),
    @embedFile("assets/lucide/menu.mask"),
    @embedFile("assets/lucide/x.mask"),
    @embedFile("assets/lucide/file.mask"),
    @embedFile("assets/lucide/paperclip.mask"),
};
/// Where desktop systems keep a color emoji font; the first readable one wins.
const system_emoji_paths = [_][]const u8{
    "/usr/share/fonts/noto/NotoColorEmoji.ttf",
    "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
    "/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf",
    "/usr/share/fonts/noto-color-emoji/NotoColorEmoji.ttf",
    "/usr/local/share/fonts/NotoColorEmoji.ttf",
    "C:\\Windows\\Fonts\\seguiemj.ttf",
    "/System/Library/Fonts/Apple Color Emoji.ttc",
};

pub const Glyph = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
    left: i16 = 0,
    top: i16 = 0,
    advance: f32 = 0,
    /// Lives in the color atlas and ignores the text color.
    color: bool = false,
};

/// Shelf packer for one atlas.
const Shelf = struct {
    x: usize = 2,
    y: usize = 2,
    row_h: usize = 0,
    width: usize,
    height: usize,
    fn place(self: *Shelf, w: usize, h: usize) ?[2]usize {
        if (self.x + w + 1 > self.width) {
            self.x = 2;
            self.y += self.row_h + 2;
            self.row_h = 0;
        }
        if (self.y + h + 1 > self.height) return null;
        const at = [2]usize{ self.x, self.y };
        self.x += w + 2;
        self.row_h = @max(self.row_h, h);
        return at;
    }
};

/// FreeType state and glyphs rasterized after init. Heap-held so `*const Font` lookups can fill it.
const Dynamic = struct {
    library: c.FT_Library,
    face: c.FT_Face,
    emoji_face: ?c.FT_Face = null,
    emoji_bytes: ?[]u8 = null,
    glyphs: std.AutoHashMapUnmanaged(u64, Glyph) = .empty,
    shelf: Shelf,
    color_shelf: Shelf = .{ .width = color_atlas_size, .height = color_atlas_size },
    /// Bumped whenever either atlas gains pixels; renderers re-upload when it changes.
    version: u32 = 0,
};

fn copyGray(pixels: []u8, stride: usize, at: [2]usize, bitmap: c.FT_Bitmap) void {
    const w: usize = @intCast(bitmap.width);
    const h: usize = @intCast(bitmap.rows);
    if (w * h == 0) return;
    const source: [*]const u8 = @ptrCast(bitmap.buffer);
    const pitch: isize = bitmap.pitch;
    for (0..h) |row| {
        const source_row = if (pitch >= 0) row else h - 1 - row;
        const start = source_row * @as(usize, @intCast(@abs(pitch)));
        @memcpy(pixels[(at[1] + row) * stride + at[0] ..][0..w], source[start..][0..w]);
    }
}

pub const Font = struct {
    pub const Strike = struct {
        size: f32 = 0,
        ascent: f32 = 0,
        glyphs: [95]Glyph = [_]Glyph{.{}} ** 95,
        pub fn glyph(self: *const Strike, byte: u8) Glyph {
            return self.glyphs[if (byte >= 32 and byte <= 126) byte - 32 else '?' - 32];
        }
    };
    allocator: std.mem.Allocator,
    pixels: []u8,
    /// RGBA, straight alpha, sRGB-encoded.
    color_pixels: []u8,
    strikes: [strike_sizes.len]Strike = [_]Strike{.{}} ** strike_sizes.len,
    icons: [icon_masks.len]Glyph = [_]Glyph{.{}} ** icon_masks.len,
    corner: Glyph = .{},
    dpi_scale: f32 = 1,
    dynamic: *Dynamic,

    /// Rasterize printable ASCII from TTF/OTF `bytes`; other characters load on first use,
    /// so `bytes` must outlive the font (embedded fonts always do).
    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !Font {
        if (bytes.len == 0) return error.InvalidFont;
        const dynamic = try allocator.create(Dynamic);
        errdefer allocator.destroy(dynamic);
        dynamic.* = .{ .library = undefined, .face = undefined, .shelf = .{ .width = atlas_width, .height = atlas_height } };
        if (c.FT_Init_FreeType(&dynamic.library) != 0) return error.FreeTypeInitFailed;
        errdefer _ = c.FT_Done_FreeType(dynamic.library);
        if (c.FT_New_Memory_Face(dynamic.library, bytes.ptr, @intCast(bytes.len), 0, &dynamic.face) != 0) return error.InvalidFont;
        const face = dynamic.face;
        const pixels = try allocator.alloc(u8, atlas_width * atlas_height);
        errdefer allocator.free(pixels);
        @memset(pixels, 0);
        pixels[0] = 255; // White texel for untextured shapes.
        const color_pixels = try allocator.alloc(u8, color_atlas_size * color_atlas_size * 4);
        errdefer allocator.free(color_pixels);
        @memset(color_pixels, 0);
        var font = Font{ .allocator = allocator, .pixels = pixels, .color_pixels = color_pixels, .dynamic = dynamic };
        const shelf = &dynamic.shelf;
        for (strike_sizes, 0..) |strike_size, strike_index| {
            if (c.FT_Set_Pixel_Sizes(face, 0, strike_size) != 0) return error.InvalidFontSize;
            font.strikes[strike_index].size = @floatFromInt(strike_size);
            font.strikes[strike_index].ascent = @floatFromInt(face.*.size.*.metrics.ascender >> 6);
            for (32..127) |codepoint| {
                if (c.FT_Load_Char(face, @intCast(codepoint), c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_LIGHT) != 0) return error.GlyphLoadFailed;
                font.strikes[strike_index].glyphs[codepoint - 32] = try font.packGray(face.*.glyph);
            }
        }
        shelf.x = 2;
        shelf.y += shelf.row_h + 2;
        shelf.row_h = 0;
        for (icon_masks, 0..) |mask, i| {
            if (mask.len != icon_size * icon_size) return error.InvalidIconMask;
            const at = shelf.place(icon_size, icon_size) orelse return error.AtlasFull;
            for (0..icon_size) |row| {
                @memcpy(pixels[(at[1] + row) * atlas_width + at[0] ..][0..icon_size], mask[row * icon_size ..][0..icon_size]);
            }
            font.icons[i] = .{ .x = @intCast(at[0]), .y = @intCast(at[1]), .w = icon_size, .h = icon_size };
        }
        // Circle centre at the tile's bottom-right, 0.5 on the arc and linear in distance
        // (0.5 per radius), plus one texel of padding so filtering never reads neighbours.
        const at = shelf.place(corner_size + 2, corner_size + 2) orelse return error.AtlasFull;
        for (0..corner_size + 2) |row| for (0..corner_size + 2) |column| {
            const u = (@as(f32, @floatFromInt(column)) - 0.5) / corner_size;
            const v = (@as(f32, @floatFromInt(row)) - 0.5) / corner_size;
            const d = @sqrt((1 - u) * (1 - u) + (1 - v) * (1 - v));
            pixels[(at[1] + row) * atlas_width + at[0] + column] = @intFromFloat(@round(std.math.clamp(0.5 + (1 - d) * 0.5, 0, 1) * 255));
        };
        font.corner = .{ .x = @intCast(at[0] + 1), .y = @intCast(at[1] + 1), .w = corner_size, .h = corner_size };
        return font;
    }

    pub fn deinit(self: *Font) void {
        const dynamic = self.dynamic;
        if (dynamic.emoji_face) |face| _ = c.FT_Done_Face(face);
        if (dynamic.emoji_bytes) |bytes| self.allocator.free(bytes);
        _ = c.FT_Done_Face(dynamic.face);
        _ = c.FT_Done_FreeType(dynamic.library);
        dynamic.glyphs.deinit(self.allocator);
        self.allocator.destroy(dynamic);
        self.allocator.free(self.color_pixels);
        self.allocator.free(self.pixels);
    }

    /// Use a color emoji font for characters the main font lacks. Takes ownership of `bytes`.
    pub fn setEmojiFont(self: *Font, bytes: []u8) !void {
        var face: c.FT_Face = undefined;
        if (c.FT_New_Memory_Face(self.dynamic.library, bytes.ptr, @intCast(bytes.len), 0, &face) != 0) return error.InvalidFont;
        if (self.dynamic.emoji_face) |old| _ = c.FT_Done_Face(old);
        if (self.dynamic.emoji_bytes) |old| self.allocator.free(old);
        self.dynamic.emoji_face = face;
        self.dynamic.emoji_bytes = bytes;
    }

    /// Load the platform's color emoji font, if one is installed. Returns whether it found one.
    pub fn loadSystemEmoji(self: *Font, io: std.Io) bool {
        for (system_emoji_paths) |path| {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(64 << 20)) catch continue;
            self.setEmojiFont(bytes) catch {
                self.allocator.free(bytes);
                continue;
            };
            return true;
        }
        return false;
    }

    /// Current atlas contents version; see `pixels` and `color_pixels`.
    pub fn version(self: *const Font) u32 {
        return self.dynamic.version;
    }

    fn packGray(self: *const Font, slot: c.FT_GlyphSlot) !Glyph {
        const bitmap = slot.*.bitmap;
        const w: usize = @intCast(bitmap.width);
        const h: usize = @intCast(bitmap.rows);
        if (bitmap.pixel_mode != c.FT_PIXEL_MODE_GRAY and w * h != 0) return error.UnsupportedGlyphBitmap;
        const at = self.dynamic.shelf.place(w, h) orelse return error.AtlasFull;
        copyGray(self.pixels, atlas_width, at, bitmap);
        return .{
            .x = @intCast(at[0]),
            .y = @intCast(at[1]),
            .w = @intCast(w),
            .h = @intCast(h),
            .left = @intCast(slot.*.bitmap_left),
            .top = @intCast(slot.*.bitmap_top),
            .advance = @as(f32, @floatFromInt(slot.*.advance.x)) / 64,
        };
    }

    /// Premultiplied BGRA from FreeType, box-filtered to `scale`, stored as straight RGBA.
    fn packColor(self: *const Font, slot: c.FT_GlyphSlot, scale: f32) !Glyph {
        const bitmap = slot.*.bitmap;
        if (bitmap.pixel_mode != c.FT_PIXEL_MODE_BGRA) return error.UnsupportedGlyphBitmap;
        const sw: usize = @intCast(bitmap.width);
        const sh: usize = @intCast(bitmap.rows);
        const w: usize = @max(1, @as(usize, @intFromFloat(@ceil(@as(f32, @floatFromInt(sw)) * scale))));
        const h: usize = @max(1, @as(usize, @intFromFloat(@ceil(@as(f32, @floatFromInt(sh)) * scale))));
        const at = self.dynamic.color_shelf.place(w, h) orelse return error.AtlasFull;
        const source: [*]const u8 = @ptrCast(bitmap.buffer);
        const pitch: usize = @intCast(@abs(bitmap.pitch));
        for (0..h) |y| for (0..w) |x| {
            const x0: usize = @intFromFloat(@as(f32, @floatFromInt(x)) / scale);
            const y0: usize = @intFromFloat(@as(f32, @floatFromInt(y)) / scale);
            const x1: usize = @min(sw, @max(x0 + 1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(x + 1)) / scale))));
            const y1: usize = @min(sh, @max(y0 + 1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(y + 1)) / scale))));
            var sum = [4]u32{ 0, 0, 0, 0 };
            var count: u32 = 0;
            for (@min(y0, sh)..y1) |sy| for (@min(x0, sw)..x1) |sx| {
                const p = source[sy * pitch + sx * 4 ..][0..4];
                for (&sum, p) |*total, channel| total.* += channel;
                count += 1;
            };
            const out = self.color_pixels[((at[1] + y) * color_atlas_size + at[0] + x) * 4 ..][0..4];
            if (count == 0 or sum[3] == 0) {
                out.* = .{ 0, 0, 0, 0 };
                continue;
            }
            // BGRA premultiplied -> RGBA straight.
            out.* = .{
                @intCast(@min(255, sum[2] * 255 / sum[3])),
                @intCast(@min(255, sum[1] * 255 / sum[3])),
                @intCast(@min(255, sum[0] * 255 / sum[3])),
                @intCast(sum[3] / count),
            };
        };
        return .{
            .x = @intCast(at[0]),
            .y = @intCast(at[1]),
            .w = @intCast(w),
            .h = @intCast(h),
            .left = @intFromFloat(@round(@as(f32, @floatFromInt(slot.*.bitmap_left)) * scale)),
            .top = @intFromFloat(@round(@as(f32, @floatFromInt(slot.*.bitmap_top)) * scale)),
            .advance = @as(f32, @floatFromInt(slot.*.advance.x)) / 64 * scale,
            .color = true,
        };
    }

    /// Rasterize `codepoint` at `selected`'s size from the main font, else the emoji font.
    fn rasterize(self: *const Font, selected: *const Strike, codepoint: u21) !Glyph {
        const d = self.dynamic;
        const size: c.FT_UInt = @intFromFloat(selected.size);
        if (c.FT_Get_Char_Index(d.face, codepoint) != 0) {
            if (c.FT_Set_Pixel_Sizes(d.face, 0, size) != 0) return error.InvalidFontSize;
            if (c.FT_Load_Char(d.face, codepoint, c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_LIGHT) != 0) return error.GlyphLoadFailed;
            return self.packGray(d.face.*.glyph);
        }
        const face = d.emoji_face orelse return error.MissingGlyph;
        const index = c.FT_Get_Char_Index(face, codepoint);
        if (index == 0) return error.MissingGlyph;
        var scale: f32 = 1;
        if (face.*.num_fixed_sizes > 0) {
            // Bitmap emoji (CBDT/sbix) come in fixed strikes; take the first and scale down.
            if (c.FT_Select_Size(face, 0) != 0) return error.InvalidFontSize;
            scale = selected.size / @as(f32, @floatFromInt(face.*.size.*.metrics.y_ppem));
        } else if (c.FT_Set_Pixel_Sizes(face, 0, size) != 0) return error.InvalidFontSize;
        if (c.FT_Load_Glyph(face, index, c.FT_LOAD_COLOR | c.FT_LOAD_RENDER) != 0) return error.GlyphLoadFailed;
        return self.packColor(face.*.glyph, scale);
    }

    /// Decode the character at `i.*` and advance past it. Invalid UTF-8 draws `?`;
    /// joiners and variation selectors are zero-width.
    // ponytail: no shaping; ZWJ emoji sequences and flags draw as their parts.
    pub fn next(self: *const Font, selected: *const Strike, value: []const u8, i: *usize) Glyph {
        const byte = value[i.*];
        if (byte < 0x80) {
            i.* += 1;
            return selected.glyph(byte);
        }
        const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const codepoint = if (len > 1 and i.* + len <= value.len) std.unicode.utf8Decode(value[i.*..][0..len]) catch null else null;
        i.* += if (codepoint == null) 1 else len;
        const cp = codepoint orelse return selected.glyph('?');
        if (cp == 0x200d or (cp >= 0xfe00 and cp <= 0xfe0f)) return .{};
        const strike_index = (@intFromPtr(selected) - @intFromPtr(&self.strikes[0])) / @sizeOf(Strike);
        const key = (@as(u64, strike_index) << 32) | cp;
        const d = self.dynamic;
        if (d.glyphs.get(key)) |g| return g;
        // A failed lookup is cached as '?' so a missing character costs one FreeType call.
        const g = self.rasterize(selected, cp) catch selected.glyph('?');
        d.glyphs.put(self.allocator, key, g) catch return g;
        if (g.w > 0 and !std.meta.eql(g, selected.glyph('?'))) d.version +%= 1;
        return g;
    }

    pub fn glyph(self: *const Font, byte: u8) Glyph {
        return self.strike(16).glyph(byte);
    }
    pub fn icon(self: *const Font, value: Icon) Glyph {
        return self.icons[@intFromEnum(value)];
    }
    pub fn strike(self: *const Font, requested_size: f32) *const Strike {
        var best: usize = 0;
        for (1..self.strikes.len) |i| {
            if (@abs(self.strikes[i].size - requested_size * self.dpi_scale) < @abs(self.strikes[best].size - requested_size * self.dpi_scale)) best = i;
        }
        return &self.strikes[best];
    }
    /// Logical units per strike pixel. Exact strikes draw 1:1 in physical pixels.
    pub fn strikeScale(self: *const Font, selected: *const Strike, requested_size: f32) f32 {
        if (@abs(selected.size - requested_size * self.dpi_scale) <= 0.5) return 1 / self.dpi_scale;
        return requested_size / selected.size;
    }
    pub fn measure(self: *const Font, value: []const u8, size: f32) f32 {
        const selected = self.strike(size);
        const scale = self.strikeScale(selected, size);
        var width: f32 = 0;
        var i: usize = 0;
        while (i < value.len) width += self.next(selected, value, &i).advance * scale;
        return width;
    }
    /// Visible glyph bounds relative to Canvas.text's origin.
    pub fn inkBounds(self: *const Font, value: []const u8, size: f32) Rect {
        const selected = self.strike(size);
        const scale = self.strikeScale(selected, size);
        var pen: f32 = 0;
        var left: f32 = std.math.inf(f32);
        var top: f32 = std.math.inf(f32);
        var right: f32 = -std.math.inf(f32);
        var bottom: f32 = -std.math.inf(f32);
        var i: usize = 0;
        while (i < value.len) {
            const g = self.next(selected, value, &i);
            if (g.w > 0 and g.h > 0) {
                const x = pen + @as(f32, @floatFromInt(g.left)) * scale;
                const y = (selected.ascent - @as(f32, @floatFromInt(g.top))) * scale;
                left = @min(left, x);
                top = @min(top, y);
                right = @max(right, x + @as(f32, @floatFromInt(g.w)) * scale);
                bottom = @max(bottom, y + @as(f32, @floatFromInt(g.h)) * scale);
            }
            pen += g.advance * scale;
        }
        if (left == std.math.inf(f32)) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return .{ .x = left, .y = top, .w = right - left, .h = bottom - top };
    }
    pub const Lines = struct {
        font: *const Font,
        value: []const u8,
        size: f32,
        width: f32,
        at: usize = 0,

        pub fn next(self: *Lines) ?[]const u8 {
            if (self.at >= self.value.len) return null;
            const start = self.at;
            var end = start;
            var break_at: ?usize = null;
            while (end < self.value.len) {
                if (self.value[end] == '\n') break;
                if (self.value[end] == ' ') break_at = end;
                const step = @min(self.value.len - end, std.unicode.utf8ByteSequenceLength(self.value[end]) catch 1);
                // ponytail: quadratic for short UI labels; cache advances if long documents use this path.
                if (end > start and self.font.measure(self.value[start .. end + step], self.size) > @max(1, self.width)) {
                    end = break_at orelse end;
                    break;
                }
                end += step;
            }
            self.at = end;
            while (self.at < self.value.len and (self.value[self.at] == ' ' or self.value[self.at] == '\n')) self.at += 1;
            return self.value[start..end];
        }
    };
    pub fn lines(self: *const Font, value: []const u8, size: f32, width: f32) Lines {
        return .{ .font = self, .value = value, .size = size, .width = width };
    }
    pub fn wrappedHeight(self: *const Font, value: []const u8, size: f32, width: f32) f32 {
        var iter = self.lines(value, size, width);
        var count: usize = 0;
        while (iter.next()) |_| count += 1;
        return @as(f32, @floatFromInt(@max(1, count))) * size * 1.35;
    }
};

test "rasterize supplied font and measure text" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    try std.testing.expect(font.measure("Hello", 16) > font.measure("Hi", 16));
    try std.testing.expect(font.glyph('A').w > 0);
    try std.testing.expectEqual(@as(f32, 15), font.strike(15).size);
    try std.testing.expectEqual(@as(f32, 64), font.strike(62).size);
    font.dpi_scale = 1.5666667;
    try std.testing.expectEqual(@as(f32, 25), font.strike(16).size);
    try std.testing.expectEqual(1 / font.dpi_scale, font.strikeScale(font.strike(16), 16));
    try std.testing.expectEqual(@as(u16, icon_size), font.icon(.chevron_left).h);
    const corner = font.corner;
    try std.testing.expect(font.pixels[(@as(usize, corner.y) + corner_size - 1) * atlas_width + corner.x + corner_size - 1] > 250);
    try std.testing.expect(font.pixels[@as(usize, corner.y) * atlas_width + corner.x] < 100);
    const search = font.icon(.search);
    try std.testing.expectEqual(@as(u16, icon_size), search.w);
    var occupied = false;
    for (0..icon_size) |row| for (0..icon_size) |column| {
        if (font.pixels[(@as(usize, search.y) + row) * atlas_width + search.x + column] > 0) occupied = true;
    };
    try std.testing.expect(occupied);
}

test "non-ASCII text loads glyphs on demand and invalid UTF-8 degrades to ?" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    const before = font.version();
    try std.testing.expect(font.measure("\u{e9}", 16) > 0);
    try std.testing.expect(font.version() != before);
    const cached = font.version();
    _ = font.measure("\u{e9}\u{e9}", 16);
    try std.testing.expectEqual(cached, font.version());
    try std.testing.expectEqual(font.measure("?", 16), font.measure("\xff", 16));
    try std.testing.expectEqual(@as(f32, 0), font.measure("\u{fe0f}", 16));
}

test "system color emoji rasterize into the color atlas when installed" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var threaded: std.Io.Threaded = .init_single_threaded;
    if (!font.loadSystemEmoji(threaded.io())) return error.SkipZigTest;
    const selected = font.strike(24);
    var i: usize = 0;
    const g = font.next(selected, "\u{1f44d}", &i);
    try std.testing.expect(g.color and g.w > 0 and g.h > 0);
    var opaque_texel = false;
    for (0..g.h) |y| for (0..g.w) |x| {
        if (font.color_pixels[((@as(usize, g.y) + y) * color_atlas_size + g.x + x) * 4 + 3] > 200) opaque_texel = true;
    };
    try std.testing.expect(opaque_texel);
}
