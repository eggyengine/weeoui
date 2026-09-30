//! Decoded images as color-atlas sprites: PNG, JPEG, BMP, TGA, PSD, HDR, PNM and GIF,
//! animated GIFs included (every frame is packed up front, so playback never re-uploads).
const std = @import("std");
const font_zig = @import("font.zig");
const Font = font_zig.Font;
const Glyph = font_zig.Glyph;
const c = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_image_resize2.h");
});
const log = std.log.scoped(.image);

/// Largest side of one packed frame, in pixels.
pub const max_side = 512;
/// Pixels one image (all frames together) may take in the color atlas: a quarter of it.
pub const max_pixels = font_zig.color_atlas_size * font_zig.color_atlas_size / 4;

pub const Frame = struct { sprite: Glyph, delay_ms: u32 };

pub const Image = struct {
    /// Decoded size in pixels, before any atlas downscale; a natural display size.
    width: u32,
    height: u32,
    frames: []Frame,
    /// Length of one animation loop; 0 for still images.
    duration_ms: u32,

    /// Decode `bytes` and pack every frame into `font`'s color atlas. Frames that would not fit
    /// `max_side` / `max_pixels` are downscaled.
    pub fn load(allocator: std.mem.Allocator, font: *Font, bytes: []const u8) !Image {
        if (bytes.len == 0 or bytes.len > std.math.maxInt(c_int)) return error.InvalidImage;
        var w: c_int = 0;
        var h: c_int = 0;
        var count: c_int = 1;
        var channels: c_int = 0;
        var delays: [*c]c_int = null;
        const gif = std.mem.startsWith(u8, bytes, "GIF8");
        const pixels = if (gif)
            c.stbi_load_gif_from_memory(bytes.ptr, @intCast(bytes.len), &delays, &w, &h, &count, &channels, 4)
        else
            c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &channels, 4);
        if (pixels == null) {
            log.debug("cannot decode image: {s}", .{std.mem.span(c.stbi_failure_reason())});
            return error.InvalidImage;
        }
        defer c.stbi_image_free(pixels);
        defer if (delays != null) c.stbi_image_free(delays);
        const width: usize = @intCast(w);
        const height: usize = @intCast(h);
        const n: usize = @intCast(@max(count, 1));

        const scale = fitScale(width, height, n);
        const fw: u16 = @intCast(@max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(width)) * scale)))));
        const fh: u16 = @intCast(@max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(height)) * scale)))));
        if (scale < 1) log.info("downscaling {d}x{d} x{d} frames to {d}x{d} for the atlas", .{ width, height, n, fw, fh });
        const scaled = try allocator.alloc(u8, @as(usize, fw) * fh * 4);
        defer allocator.free(scaled);

        const frames = try allocator.alloc(Frame, n);
        errdefer allocator.free(frames);
        var duration: u32 = 0;
        for (frames, 0..) |*frame, i| {
            const source = pixels[i * width * height * 4 ..][0 .. width * height * 4];
            const packed_pixels = if (scale < 1) blk: {
                // Straight alpha in, straight alpha out; stbir premultiplies internally so edges don't darken.
                if (c.stbir_resize_uint8_srgb(source.ptr, w, h, 0, scaled.ptr, fw, fh, 0, c.STBIR_RGBA) == null) return error.InvalidImage;
                break :blk scaled;
            } else source;
            // Browsers treat GIF delays under 20 ms as 100 ms; so do we.
            const delay: u32 = if (delays == null) 0 else if (delays[i] < 20) 100 else @intCast(delays[i]);
            frame.* = .{ .sprite = try font.addSprite(packed_pixels, fw, fh), .delay_ms = delay };
            duration += delay;
        }
        return .{ .width = @intCast(width), .height = @intCast(height), .frames = frames, .duration_ms = if (n > 1) duration else 0 };
    }

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
        self.* = undefined;
    }

    /// The frame to show `ms` milliseconds into playback (looping).
    pub fn frameAt(self: *const Image, ms: u64) Glyph {
        if (self.duration_ms == 0) return self.frames[0].sprite;
        var t: u64 = ms % self.duration_ms;
        for (self.frames) |frame| {
            if (t < frame.delay_ms) return frame.sprite;
            t -= frame.delay_ms;
        }
        return self.frames[self.frames.len - 1].sprite;
    }
};

/// Largest scale (at most 1) that keeps one frame within `max_side` and all frames within `max_pixels`.
fn fitScale(width: usize, height: usize, frames: usize) f32 {
    const side: f32 = @floatFromInt(@max(width, height));
    const area: f32 = @floatFromInt(width * height * frames);
    return @min(1, @min(max_side / side, @sqrt(@as(f32, max_pixels) / area)));
}

test "PNG decodes, GIF frames animate, and oversized images shrink to the atlas budget" {
    var font = try Font.init(std.testing.allocator, @import("root.zig").default_font);
    defer font.deinit();
    // 2x1 PNG (ImageMagick): one red and one half-transparent blue pixel.
    const png = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0xf4, 0x22, 0x7f, 0x8a, 0x00, 0x00, 0x00, 0x11, 0x49, 0x44, 0x41, 0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x9f, 0x81, 0xe1, 0x7f, 0x03, 0x00, 0x0f, 0x7a, 0x03, 0x7e, 0x1b, 0xda, 0x3d, 0x85, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    const before = font.version();
    var still = try Image.load(std.testing.allocator, &font, &png);
    defer still.deinit(std.testing.allocator);
    try std.testing.expect(font.version() != before);
    try std.testing.expectEqual(@as(u32, 2), still.width);
    try std.testing.expectEqual(@as(usize, 1), still.frames.len);
    const at = still.frames[0].sprite;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, font.color_pixels[(@as(usize, at.y) * font_zig.color_atlas_size + at.x) * 4 ..][0..4]);
    try std.testing.expectEqual(still.frameAt(12345), at);

    // 1x1 GIF (ImageMagick), two frames (black, then white) 100 ms apart.
    const gif = [_]u8{ 0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0xff, 0x0b, 0x4e, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, 0x32, 0x2e, 0x30, 0x03, 0x01, 0x00, 0x00, 0x00, 0x21, 0xf9, 0x04, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x21, 0xf9, 0x04, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x80, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3b };
    var animated = try Image.load(std.testing.allocator, &font, &gif);
    defer animated.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), animated.frames.len);
    try std.testing.expectEqual(@as(u32, 200), animated.duration_ms);
    try std.testing.expectEqual(animated.frames[0].sprite, animated.frameAt(50));
    try std.testing.expectEqual(animated.frames[1].sprite, animated.frameAt(150));
    try std.testing.expectEqual(animated.frames[0].sprite, animated.frameAt(250));

    try std.testing.expectEqual(@as(f32, 1), fitScale(64, 64, 10));
    try std.testing.expectEqual(@as(f32, 0.5), fitScale(1024, 256, 1));
    const s = fitScale(512, 512, 30);
    try std.testing.expectApproxEqRel(@as(f32, max_pixels), s * s * 512 * 512 * 30, 1e-4);
    try std.testing.expectError(error.InvalidImage, Image.load(std.testing.allocator, &font, "not an image"));
}
