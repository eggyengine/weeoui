//! Browser builds: what a page has to get from the browser instead of the OS. Link `web.js` into
//! the page with `emcc --js-library` (named lazy path `web_js`; the gallery's build does this).
//!
//! - `textRenderer`: emoji and other glyphs the main font lacks, from the browser's text stack.
//!   A page can't hand FreeType the system's emoji font.
//! - `copy`, `requestPaste` and `takePaste`: the system clipboard. SDL keeps a clipboard of its
//!   own on the web.
//! - `pickFile` and `takePickedFile`: the browser's file chooser. SDL has no file dialogs there.
const std = @import("std");
const font = @import("font.zig");

extern fn weeoui_glyph_measure(codepoint: u32, size: f32, metrics: *[4]u32) c_int;
extern fn weeoui_glyph_pixels(out: [*]u8) void;
extern fn weeoui_copy(text: [*]const u8, len: usize) void;
extern fn weeoui_paste_take(out: [*]u8, max: usize) usize;
extern fn weeoui_paste_request() void;
extern fn weeoui_pick_file() void;
extern fn weeoui_file_take(out: [*]u8, max: usize) i32;

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

/// Paste from the system clipboard: call it for the paste shortcut and for a menu's Paste. The
/// browser may ask the user first; the text arrives later through `takePaste`. SDL swallows
/// Ctrl+V, so the page's own paste event rarely fires; when it does, this doesn't paste twice.
pub fn requestPaste() void {
    weeoui_paste_request();
}

/// Text pasted since the last call (see `requestPaste`), or null. The clipboard answers
/// asynchronously, so poll this every frame.
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

/// Open the browser's file chooser. Call it from a click or key press (browsers refuse
/// otherwise); the answer arrives later through `takePickedFile`.
pub fn pickFile() void {
    weeoui_pick_file();
}

pub const Picked = union(enum) { file: []const u8, cancelled };

/// The file chosen since the last call (its name, in `buffer`), a cancel, or null for no answer
/// yet. Poll it every frame.
pub fn takePickedFile(buffer: []u8) ?Picked {
    const len = weeoui_file_take(buffer.ptr, buffer.len);
    if (len == -1) return null;
    if (len == -2) return .cancelled;
    return .{ .file = wholeCharacters(buffer[0..@intCast(len)], @as(usize, @intCast(len)) == buffer.len) };
}
