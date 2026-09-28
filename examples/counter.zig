//! Standalone counter: SDL3 window, Vitellus (Vulkan) rendering, Weeoui UI.
//! Run with `zig build counter -Dsdl3 -Dvitellus`.
const std = @import("std");
const vit = @import("vitellus");
const sdl_window = @import("vitellus_sdl3");
const sdl3 = sdl_window.sdl;
const ui = @import("weeoui"); // core: Context (widgets), layout, fonts, accessibility
const weeoui_sdl3 = @import("weeoui_sdl3"); // SDL3 events -> weeoui input (+ screen reader attach), from -Dsdl3
const weeoui_vitellus = @import("weeoui_vitellus"); // draws weeoui's vertices with vitellus, from -Dvitellus

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    // sdl3 initialisation
    try sdl3.init(.{ .video = true });
    defer sdl3.quit(.{ .video = true });
    var window = sdl_window.Sdl3Window.init(try sdl3.video.Window.init("weeoui counter", 480, 320, .{ .vulkan = true, .resizable = true, .high_pixel_density = true }));
    defer window.deinit();

    // vitellus init
    const instance = try vit.Instance.init(gpa, .{ .backend = .{ .vulkan = true }, .validation = .none });
    defer instance.deinit();
    const adapter = try vit.Adapter.init(instance, .{});
    defer adapter.deinit();
    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();
    const queue = try vit.Queue.init(device, .{ .kind = .graphics });
    defer queue.deinit();
    const commands = try vit.CommandPool.init(device, .{ .kind = .graphics });
    defer commands.deinit();

    const caps = try adapter.surfaceCapabilities(gpa, try window.asWindow());
    defer caps.deinit();
    if (caps.formats.len == 0 or caps.present_modes.len == 0 or caps.composite_alpha.len == 0) return error.NoSurfaceCapabilities;
    var extent = try pixelSize(window);
    const swapchain = try vit.Swapchain.init(adapter, .{
        .window = try window.asWindow(),
        .queue = queue,
        .extent = extent,
        .format = caps.formats[0],
        .present_mode = caps.present_modes[0],
        .image_count = 2,
        .composite_alpha = caps.composite_alpha[0],
    });
    defer swapchain.deinit();
    const color_format = colorFormat(caps.formats[0]);

    // <<< weeoui init: the UI context and its GPU renderer
    // `Context` owns everything per-UI: the font atlas, frame memory, the vertex buffer,
    // input state, keyboard focus and the screen reader bridge. Make one per window.
    var ctx = try ui.Context.init(gpa);
    defer ctx.deinit();
    // sRGB swapchains expect linear colors; this makes weeoui convert its theme colors.
    ctx.srgb_target = weeoui_vitellus.isSrgb(color_format);
    // Pipeline + font texture + vertex buffer for drawing `ctx` output into `color_format` targets.
    // It uploads `ctx.font` once, so create it after the context and keep the font alive.
    var renderer = try weeoui_vitellus.Renderer.init(device, color_format, &ctx.font);
    defer renderer.deinit();
    // Runs first on exit: let the GPU finish before the renderer's resources are freed.
    defer queue.waitIdle() catch {};
    // >>>

    var count: u32 = 0;
    while (true) {
        while (sdl3.events.poll()) |event| switch (event) {
            .quit => return,
            // Feeds mouse/keyboard (Tab, Enter, Space) into `ctx`; the first event also attaches screen readers.
            else => weeoui_sdl3.handleEvent(&ctx, event),
        };

        const logical = try window.window.getSize();
        if (logical.@"0" == 0 or logical.@"1" == 0) continue; // minimized
        // The UI's coordinate space: logical window size, the same units SDL reports mouse positions in.
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = @floatFromInt(logical.@"0"), .h = @floatFromInt(logical.@"1") };
        const pixels = try pixelSize(window);
        if (pixels.width != extent.width or pixels.height != extent.height) {
            try queue.waitIdle();
            try swapchain.resize(pixels);
            extent = pixels;
        }
        // <<< weeoui HiDPI: physical pixels per viewport unit
        // Snaps edges to real pixels so lines stay crisp on scaled displays (e.g. 2x Retina).
        ctx.pixel_scale = .{ @as(f32, @floatFromInt(extent.width)) / viewport.w, @as(f32, @floatFromInt(extent.height)) / viewport.h };
        // Picks the matching glyph resolution so text isn't blurry when scaled.
        ctx.font.dpi_scale = ctx.pixel_scale[0];
        // >>>

        // <<< weeoui frame: describe the UI from your state, read back what the user did
        // Starts a frame: resets frame memory and applies queued input (clicks, Tab moves, screen reader actions).
        ctx.newFrame(viewport);
        // Containers nest until the matching `end()`: `.card` draws a panel, `.row`/`.column` only arrange.
        ctx.begin(.card);
        // Plain text, formatted like std.fmt. Not focusable.
        ctx.label("Count: {d}", .{count});
        // True on the frame it's clicked, activated with Enter/Space while focused, or "clicked" by a screen reader.
        // The label doubles as its id; use "Text##unique" when two widgets share a label.
        if (ctx.button("Increment")) count += 1;
        ctx.end();
        // Lays everything out, publishes the tree to screen readers, and returns triangles to draw.
        // The slice is valid until the next `render()`; any error from the widget calls surfaces here.
        const vertices = try ctx.render();
        // >>>

        // ponytail: waits for the GPU every frame so the renderer's single vertex buffer is free; use frames in flight if it matters.
        try queue.waitIdle();
        try commands.reset();
        const acquired = try swapchain.acquireNextImage(null);
        const cmd = try vit.CommandBuffer.init(commands, .{});
        defer cmd.deinit();
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .present, .after = .color_attachment } }});
        // Copies this frame's vertices to the GPU (converting viewport units to clip space). Must be outside a render pass.
        try renderer.upload(cmd, vertices, viewport);
        // Clear to the weeoui theme's background so the UI sits on a matching color.
        const bg = ctx.theme.background;
        try cmd.beginRenderPass(.{ .color_attachments = &.{.{
            .view = acquired.view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = if (ctx.srgb_target)
                .{ .r = ui.linearChannel(bg[0]), .g = ui.linearChannel(bg[1]), .b = ui.linearChannel(bg[2]), .a = 1 }
            else
                .{ .r = bg[0], .g = bg[1], .b = bg[2], .a = 1 },
        }} });
        // Draws the uploaded UI (vertices 0..len) into the current render pass; `extent` is the target size in pixels.
        renderer.draw(cmd, extent, 0, vertices.len);
        cmd.endRenderPass();
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .color_attachment, .after = .present } }});
        try cmd.finish();
        try queue.submit(.{ .command_buffers = &.{cmd} });
        _ = try swapchain.present(&.{});
    }
}

fn pixelSize(window: sdl_window.Sdl3Window) !vit.Extent2D {
    const size = try window.window.getSizeInPixels();
    return .{ .width = @intCast(size.@"0"), .height = @intCast(size.@"1") };
}

fn colorFormat(format: vit.SwapchainFormat) vit.Format {
    return switch (format) {
        .bgra8_unorm => .bgra8_unorm,
        .bgra8_unorm_srgb => .bgra8_unorm_srgb,
        .rgba8_unorm => .rgba8_unorm,
        .rgba8_unorm_srgb => .rgba8_unorm_srgb,
        .rgba16_float => .rgba16_float,
    };
}
