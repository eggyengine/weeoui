//! Android's own text stack (android.graphics over JNI) as a `ui.PlatformRenderer`, so emoji look
//! native. Android 13+ ships only COLRv1 emoji, which FreeType can't rasterize.
const std = @import("std");
const ui = @import("weeoui");
const c = @cImport(@cInclude("jni.h"));

/// `env` is the calling thread's `JNIEnv*` (e.g. `SDL_GetAndroidJNIEnv()`); glyphs draw on that thread.
pub fn renderer(env: *anyopaque) ui.PlatformRenderer {
    return .{ .context = env, .render = render };
}

fn render(context: ?*anyopaque, allocator: std.mem.Allocator, codepoint: u21, size: f32) ?ui.PlatformGlyph {
    const env: *c.JNIEnv = @ptrCast(@alignCast(context.?));
    const jni = env.*.*;
    if (jni.PushLocalFrame.?(env, 16) != 0) return null;
    defer _ = jni.PopLocalFrame.?(env, null);
    const glyph = draw(env, allocator, codepoint, size) catch null;
    if (jni.ExceptionCheck.?(env) != 0) {
        jni.ExceptionClear.?(env);
        if (glyph) |g| allocator.free(g.pixels);
        return null;
    }
    return glyph;
}

fn draw(env: *c.JNIEnv, allocator: std.mem.Allocator, codepoint: u21, size: f32) !ui.PlatformGlyph {
    const jni = env.*.*;
    // NewStringUTF wants modified UTF-8, which can't hold emoji directly; pass UTF-16 instead.
    var utf16: [2]c.jchar = undefined;
    const units: c.jsize = if (codepoint < 0x10000) blk: {
        utf16[0] = @intCast(codepoint);
        break :blk 1;
    } else blk: {
        utf16[0] = @intCast(0xD800 + ((codepoint - 0x10000) >> 10));
        utf16[1] = @intCast(0xDC00 + ((codepoint - 0x10000) & 0x3FF));
        break :blk 2;
    };
    const text = jni.NewString.?(env, &utf16, units) orelse return error.Jni;

    const paint_class = try class(env, "android/graphics/Paint");
    const paint = jni.NewObjectA.?(env, paint_class, try method(env, paint_class, "<init>", "(I)V"), &[_]c.jvalue{.{ .i = 1 }}) orelse return error.Jni; // ANTI_ALIAS_FLAG
    jni.CallVoidMethodA.?(env, paint, try method(env, paint_class, "setTextSize", "(F)V"), &[_]c.jvalue{.{ .f = size }});
    const advance = jni.CallFloatMethodA.?(env, paint, try method(env, paint_class, "measureText", "(Ljava/lang/String;)F"), &[_]c.jvalue{.{ .l = text }});
    const ascent = jni.CallFloatMethodA.?(env, paint, try method(env, paint_class, "ascent", "()F"), null); // negative
    const descent = jni.CallFloatMethodA.?(env, paint, try method(env, paint_class, "descent", "()F"), null);
    const width: u16 = @intFromFloat(@min(512, @max(1, @ceil(advance))));
    const height: u16 = @intFromFloat(@min(512, @max(1, @ceil(descent - ascent))));

    const bitmap_class = try class(env, "android/graphics/Bitmap");
    const config_class = try class(env, "android/graphics/Bitmap$Config");
    const argb = jni.GetStaticObjectField.?(env, config_class, jni.GetStaticFieldID.?(env, config_class, "ARGB_8888", "Landroid/graphics/Bitmap$Config;") orelse return error.Jni) orelse return error.Jni;
    const create = jni.GetStaticMethodID.?(env, bitmap_class, "createBitmap", "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;") orelse return error.Jni;
    const bitmap = jni.CallStaticObjectMethodA.?(env, bitmap_class, create, &[_]c.jvalue{ .{ .i = width }, .{ .i = height }, .{ .l = argb } }) orelse return error.Jni;
    const canvas_class = try class(env, "android/graphics/Canvas");
    const canvas = jni.NewObjectA.?(env, canvas_class, try method(env, canvas_class, "<init>", "(Landroid/graphics/Bitmap;)V"), &[_]c.jvalue{.{ .l = bitmap }}) orelse return error.Jni;
    jni.CallVoidMethodA.?(env, canvas, try method(env, canvas_class, "drawText", "(Ljava/lang/String;FFLandroid/graphics/Paint;)V"), &[_]c.jvalue{ .{ .l = text }, .{ .f = 0 }, .{ .f = -ascent }, .{ .l = paint } });

    const count = @as(usize, width) * height;
    const colors = jni.NewIntArray.?(env, @intCast(count)) orelse return error.Jni;
    jni.CallVoidMethodA.?(env, bitmap, try method(env, bitmap_class, "getPixels", "([IIIIIII)V"), &[_]c.jvalue{ .{ .l = colors }, .{ .i = 0 }, .{ .i = width }, .{ .i = 0 }, .{ .i = 0 }, .{ .i = width }, .{ .i = height } });
    jni.CallVoidMethodA.?(env, bitmap, try method(env, bitmap_class, "recycle", "()V"), null);
    if (jni.ExceptionCheck.?(env) != 0) return error.Jni;

    const argb_pixels = try allocator.alloc(c.jint, count);
    defer allocator.free(argb_pixels);
    jni.GetIntArrayRegion.?(env, colors, 0, @intCast(count), argb_pixels.ptr);
    const pixels = try allocator.alloc(u8, count * 4);
    // getPixels gives straight-alpha ARGB; the atlas wants RGBA.
    for (argb_pixels, 0..) |color, i| {
        const v: u32 = @bitCast(color);
        pixels[i * 4 ..][0..4].* = .{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v), @truncate(v >> 24) };
    }
    return .{ .pixels = pixels, .width = width, .height = height, .top = @intFromFloat(@round(-ascent)), .advance = advance };
}

fn class(env: *c.JNIEnv, name: [*:0]const u8) !c.jclass {
    return env.*.*.FindClass.?(env, name) orelse error.Jni;
}

fn method(env: *c.JNIEnv, owner: c.jclass, name: [*:0]const u8, signature: [*:0]const u8) !c.jmethodID {
    return env.*.*.GetMethodID.?(env, owner, name, signature) orelse error.Jni;
}
