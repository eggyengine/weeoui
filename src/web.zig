//! Browser builds: what a page has to get from the browser instead of the OS. Link `web.js` into
//! the page with `emcc --js-library` (named lazy path `web_js`; the gallery's build does this).
//!
//! - `textRenderer`: emoji and other glyphs the main font lacks, from the browser's text stack.
//!   A page can't hand FreeType the system's emoji font.
//! - `copy` and `takePaste`: the system clipboard. SDL keeps a clipboard of its own on the web.
const std = @import("std");
const font = @import("font.zig");

extern fn weeoui_glyph_measure(codepoint: u32, size: f32, metrics: *[4]u32) c_int;
extern fn weeoui_glyph_pixels(out: [*]u8) void;
extern fn weeoui_copy(text: [*]const u8, len: usize) void;
extern fn weeoui_paste_take(out: [*]u8, max: usize) usize;
extern fn weeoui_paste_request() void;

/// Set as `Font.platform` to draw missing glyphs on a 2D canvas, where the browser falls back
/// to the system's color emoji font.
pub fn textRenderer() font.PlatformRenderer {
    return .{ .context = null, .render = render };
}

fn render(_: ?*anyopaque, allocator: std.mem.Allocator, codepoint: u21, size: f32) ?font.PlatformGlyph {
    // Width, height, top (ascent) and advance (f32 bits), for the glyph now drawn on the canvas.
    var metrics: [4]u32 = undefined;
    if (weeoui_glyph_measure(codepoint, size, &metrics) == 0) return null;
    const width: u16 = @intCast(metrics[0]);
    const height: u16 = @intCast(metrics[1]);
    const pixels = allocator.alloc(u8, @as(usize, width) * height * 4) catch return null;
    weeoui_glyph_pixels(pixels.ptr);
    return .{ .pixels = pixels, .width = width, .height = height, .top = @intCast(metrics[2]), .advance = @bitCast(metrics[3]) };
}

/// Put `text` on the system clipboard. Call it while handling the copy or cut shortcut: browsers
/// only allow writes shortly after the user pressed a key or clicked.
pub fn copy(text: []const u8) void {
    weeoui_copy(text.ptr, text.len);
}

/// Read the system clipboard for a paste that didn't come from the keyboard (a menu's Paste).
/// The browser may ask the user first; the text arrives later through `takePaste`.
pub fn requestPaste() void {
    weeoui_paste_request();
}

/// Text the user pasted (Ctrl+V or Cmd+V) since the last call, or null. Browsers hand pasted
/// text to the page only in their paste event, so poll this every frame instead of reading the
/// clipboard when the shortcut arrives. Keyboard events don't reach the paste event unless SDL's
/// text input is on, so this works while a text field has focus.
pub fn takePaste(buffer: []u8) ?[]const u8 {
    const len = weeoui_paste_take(buffer.ptr, buffer.len);
    if (len == 0) return null;
    return wholeCharacters(buffer[0..len], len == buffer.len);
}

/// `text`, minus a character cut in half at its end when `truncated`.
fn wholeCharacters(text: []const u8, truncated: bool) []const u8 {
    if (!truncated) return text;
    var lead = text.len;
    while (lead > 0 and text[lead - 1] & 0xC0 == 0x80) lead -= 1;
    if (lead == 0) return text[0..0];
    lead -= 1;
    const need = std.unicode.utf8ByteSequenceLength(text[lead]) catch 1;
    return if (lead + need > text.len) text[0..lead] else text;
}

test "a truncated paste ends on a whole character" {
    try std.testing.expectEqualStrings("egg ", wholeCharacters("egg \xf0\x9f\xa5", true));
    try std.testing.expectEqualStrings("egg \u{1f95a}", wholeCharacters("egg \u{1f95a}", true));
    try std.testing.expectEqualStrings("egg \xf0\x9f", wholeCharacters("egg \xf0\x9f", false));
}
