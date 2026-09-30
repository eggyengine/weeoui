//! Vitellus renderer for Weeoui vertices, in the spirit of egui_wgpu.
//! `Painter` owns the whole GPU setup for one window; `Renderer` is the piece to embed when
//! an application already has its own device and render passes.
const std = @import("std");
const vit = @import("vitellus");
const ui = @import("weeoui");
const log = std.log.scoped(.renderer);

/// How many frames the GPU may still be drawing while the CPU fills the next one.
pub const frames_in_flight = 2;

pub const Renderer = struct {
    device: vit.Device,
    /// One per frame in flight, so `upload` never writes what the GPU is still reading.
    vertices: [frames_in_flight]vit.Buffer,
    capacity: [frames_in_flight]usize,
    /// Which of `vertices` the last `upload` filled and `draw` reads.
    slot: usize = 0,
    pipeline_layout: vit.PipelineLayout,
    pipeline: vit.GraphicsPipeline,
    font_texture: vit.Texture,
    font_view: vit.TextureView,
    color_texture: vit.Texture,
    color_view: vit.TextureView,
    font_sampler: vit.Sampler,
    font_layout: vit.BindGroupLayout,
    font_group: vit.BindGroup,
    /// Created on the first atlas change: glyphs rasterized after `init` (Unicode, emoji).
    staging: [frames_in_flight]?vit.Buffer = @splat(null),
    font_version: u32,
    font_needs_barrier: bool = true,

    /// `color_format` is the render target format. The atlases start from `font`; `upload`
    /// sends them again whenever the font has rasterized new glyphs.
    pub fn init(device: vit.Device, color_format: vit.Format, font: *const ui.Font) !Renderer {
        const capacity = 4096;
        var vertices: [frames_in_flight]vit.Buffer = undefined;
        for (&vertices, 0..) |*buffer, i| {
            errdefer for (vertices[0..i]) |made| made.deinit();
            buffer.* = try createVertexBuffer(device, capacity);
        }
        errdefer for (vertices) |buffer| buffer.deinit();
        const font_texture = try vit.Texture.init(device, .{ .label = "weeoui font", .width = ui.atlas_width, .height = ui.atlas_height, .format = .r8_unorm, .usage = .{ .sampled = true, .transfer_dst = true }, .initial_data = font.pixels });
        errdefer font_texture.deinit();
        const font_view = try vit.TextureView.init(device, .{ .texture = font_texture });
        errdefer font_view.deinit();
        // Emoji pixels are sRGB-encoded; an sRGB texture decodes them for sRGB targets.
        const color_texture = try vit.Texture.init(device, .{ .label = "weeoui color glyphs", .width = ui.color_atlas_size, .height = ui.color_atlas_size, .format = if (isSrgb(color_format)) .rgba8_unorm_srgb else .rgba8_unorm, .usage = .{ .sampled = true, .transfer_dst = true }, .initial_data = font.color_pixels });
        errdefer color_texture.deinit();
        const color_view = try vit.TextureView.init(device, .{ .texture = color_texture });
        errdefer color_view.deinit();
        const font_sampler = try vit.Sampler.init(device, .{ .address_u = .clamp_to_edge, .address_v = .clamp_to_edge });
        errdefer font_sampler.deinit();
        const font_layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
            .{ .binding = 1, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
            .{ .binding = 2, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
        } });
        errdefer font_layout.deinit();
        const font_group = try vit.BindGroup.init(device, .{ .layout = font_layout, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = font_view } },
            .{ .binding = 1, .resource = .{ .sampler = font_sampler } },
            .{ .binding = 2, .resource = .{ .texture_view = color_view } },
        } });
        errdefer font_group.deinit();
        const vs = try vit.Shader.init(device, .{ .label = "weeoui vert", .stage = .vertex, .source = vit.SPIRVShaderModule.init(.{ .code = @embedFile("shaders/ui.vert.spv") }) });
        defer vs.deinit();
        const fs = try vit.Shader.init(device, .{ .label = "weeoui frag", .stage = .fragment, .source = vit.SPIRVShaderModule.init(.{ .code = @embedFile("shaders/ui.frag.spv") }) });
        defer fs.deinit();
        const pipeline_layout = try vit.PipelineLayout.init(device, .{ .label = "weeoui layout", .bind_group_layouts = &.{font_layout} });
        errdefer pipeline_layout.deinit();
        const pipeline = try vit.GraphicsPipeline.init(device, .{
            .label = "weeoui pipeline",
            .vertex = vs,
            .fragment = fs,
            .vertex_buffers = &.{.{ .stride = @sizeOf(ui.Vertex), .attributes = &.{
                .{ .location = 0, .format = .float32x2, .offset = 0 },
                .{ .location = 1, .format = .float32x4, .offset = @offsetOf(ui.Vertex, "color") },
                .{ .location = 2, .format = .float32x2, .offset = @offsetOf(ui.Vertex, "uv") },
                .{ .location = 3, .format = .float32, .offset = @offsetOf(ui.Vertex, "mode") },
            } }},
            .color_targets = &.{.{ .format = color_format, .blend = .{ .color = .{ .source = .src_alpha, .destination = .one_minus_src_alpha }, .alpha = .{ .source = .one, .destination = .one_minus_src_alpha } } }},
            .raster = .{ .cull_mode = .none },
            .layout = pipeline_layout,
        });
        return .{ .device = device, .vertices = vertices, .capacity = @splat(capacity), .pipeline_layout = pipeline_layout, .pipeline = pipeline, .font_texture = font_texture, .font_view = font_view, .color_texture = color_texture, .color_view = color_view, .font_sampler = font_sampler, .font_layout = font_layout, .font_group = font_group, .font_version = font.version() };
    }

    pub fn deinit(self: *Renderer) void {
        self.pipeline.deinit();
        self.pipeline_layout.deinit();
        self.font_group.deinit();
        self.font_layout.deinit();
        self.font_sampler.deinit();
        self.color_view.deinit();
        self.color_texture.deinit();
        self.font_view.deinit();
        self.font_texture.deinit();
        for (self.staging) |staging| if (staging) |buffer| buffer.deinit();
        for (self.vertices) |buffer| buffer.deinit();
    }

    /// Copy `vertices` (in `viewport` units) and any glyphs `font` gained to the GPU. Call outside
    /// a render pass; the buffers grow as needed. Each call takes the next of `frames_in_flight`
    /// buffers: first wait for the GPU to finish the frame that uploaded `frames_in_flight` calls ago.
    pub fn upload(self: *Renderer, cmd: vit.CommandBuffer, font: *const ui.Font, vertices: []const ui.Vertex, viewport: ui.Rect) !void {
        if (self.font_needs_barrier) {
            try cmd.barrier(&.{
                .{ .texture = .{ .texture = self.font_texture, .before = .common, .after = .sampled } },
                .{ .texture = .{ .texture = self.color_texture, .before = .common, .after = .sampled } },
            });
            self.font_needs_barrier = false;
        }
        self.slot = (self.slot + 1) % frames_in_flight;
        if (font.version() != self.font_version) try self.uploadAtlases(cmd, font);
        if (vertices.len > self.capacity[self.slot]) {
            const capacity = std.math.ceilPowerOfTwoAssert(usize, vertices.len);
            const grown = try createVertexBuffer(self.device, capacity);
            self.vertices[self.slot].deinit();
            self.vertices[self.slot] = grown;
            self.capacity[self.slot] = capacity;
        }
        if (vertices.len == 0) return;
        const size = vertices.len * @sizeOf(ui.Vertex);
        const buffer = self.vertices[self.slot];
        const mapped = try buffer.map(.write, .{ .size = size });
        const out: []ui.Vertex = @alignCast(std.mem.bytesAsSlice(ui.Vertex, mapped[0..size]));
        for (out, vertices) |*dst, src| dst.* = toClip(src, viewport);
        buffer.unmap(.{ .size = size });
    }

    // ponytail: re-sends both whole atlases (8 MB) when any glyph is added; track dirty rows if typing new scripts stutters.
    fn uploadAtlases(self: *Renderer, cmd: vit.CommandBuffer, font: *const ui.Font) !void {
        const gray = font.pixels.len;
        const total = gray + font.color_pixels.len;
        if (self.staging[self.slot] == null) self.staging[self.slot] = try vit.Buffer.init(self.device, .{ .label = "weeoui glyph staging", .size = total, .usage = .{ .transfer_src = true }, .memory = .upload });
        const staging = self.staging[self.slot].?;
        const mapped = try staging.map(.write, .{ .size = total });
        @memcpy(mapped[0..gray], font.pixels);
        @memcpy(mapped[gray..total], font.color_pixels);
        staging.unmap(.{ .size = total });
        try cmd.barrier(&.{
            .{ .buffer = .{ .buffer = staging, .before = .host_write, .after = .copy_source } },
            .{ .texture = .{ .texture = self.font_texture, .before = .sampled, .after = .copy_destination } },
            .{ .texture = .{ .texture = self.color_texture, .before = .sampled, .after = .copy_destination } },
        });
        try cmd.copyBufferToTexture(.{ .buffer = staging, .bytes_per_row = ui.atlas_width, .texture = .{ .texture = self.font_texture }, .extent = .{ .width = ui.atlas_width, .height = ui.atlas_height } });
        try cmd.copyBufferToTexture(.{ .buffer = staging, .buffer_offset = gray, .bytes_per_row = ui.color_atlas_size * 4, .texture = .{ .texture = self.color_texture }, .extent = .{ .width = ui.color_atlas_size, .height = ui.color_atlas_size } });
        try cmd.barrier(&.{
            .{ .buffer = .{ .buffer = staging, .before = .copy_source, .after = .host_write } },
            .{ .texture = .{ .texture = self.font_texture, .before = .copy_destination, .after = .sampled } },
            .{ .texture = .{ .texture = self.color_texture, .before = .copy_destination, .after = .sampled } },
        });
        self.font_version = font.version();
    }

    /// Draw `count` uploaded vertices starting at `first`. Call inside a render pass targeting `extent`.
    pub fn draw(self: *const Renderer, cmd: vit.CommandBuffer, extent: vit.Extent2D, first: usize, count: usize) void {
        if (count == 0) return;
        cmd.setGraphicsPipeline(self.pipeline);
        cmd.setBindGroup(0, self.font_group, &.{});
        cmd.setViewport(.{ .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height) });
        cmd.setScissor(.{ .width = extent.width, .height = extent.height });
        cmd.setVertexBuffer(0, self.vertices[self.slot], 0);
        cmd.draw(@intCast(count), 1, @intCast(first), 0);
    }
};

/// Everything needed to put Weeoui on one window: device, swapchain, and `Renderer`.
/// Windowing stays outside: pass any `vit.Window` (the SDL3 adapter's `run` does this for you).
pub const Painter = struct {
    instance: vit.Instance,
    adapter: vit.Adapter,
    device: vit.Device,
    queue: vit.Queue,
    commands: vit.CommandPool,
    swapchain: vit.Swapchain,
    format: vit.Format,
    extent: vit.Extent2D,
    renderer: Renderer,

    /// `extent` is the window size in physical pixels; `font` seeds the glyph atlases.
    pub fn init(gpa: std.mem.Allocator, window: vit.Window, extent: vit.Extent2D, font: *const ui.Font) !Painter {
        const instance = try vit.Instance.init(gpa, .{ .backend = .{ .vulkan = true }, .validation = .none });
        errdefer instance.deinit();
        const adapter = try vit.Adapter.init(instance, .{});
        errdefer adapter.deinit();
        const device = try vit.Device.init(adapter, .{});
        errdefer device.deinit();
        const queue = try vit.Queue.init(device, .{ .kind = .graphics });
        errdefer queue.deinit();
        const commands = try vit.CommandPool.init(device, .{ .kind = .graphics });
        errdefer commands.deinit();
        const caps = try adapter.surfaceCapabilities(gpa, window);
        defer caps.deinit();
        if (caps.formats.len == 0 or caps.present_modes.len == 0 or caps.composite_alpha.len == 0) return error.NoSurfaceCapabilities;
        const swapchain = try vit.Swapchain.init(adapter, .{
            .window = window,
            .queue = queue,
            .extent = extent,
            .format = caps.formats[0],
            .present_mode = caps.present_modes[0],
            .image_count = 2,
            .composite_alpha = caps.composite_alpha[0],
        });
        errdefer swapchain.deinit();
        const format = colorFormat(caps.formats[0]);
        const renderer = try Renderer.init(device, format, font);
        log.info("painting {d}x{d} as {s}", .{ extent.width, extent.height, @tagName(format) });
        return .{ .instance = instance, .adapter = adapter, .device = device, .queue = queue, .commands = commands, .swapchain = swapchain, .format = format, .extent = extent, .renderer = renderer };
    }

    pub fn deinit(self: *Painter) void {
        self.queue.waitIdle() catch {};
        self.renderer.deinit();
        self.swapchain.deinit();
        self.commands.deinit();
        self.queue.deinit();
        self.device.deinit();
        self.adapter.deinit();
        self.instance.deinit();
    }

    /// Whether Weeoui should linearize colors (`Context.srgb_target`).
    pub fn srgb(self: *const Painter) bool {
        return isSrgb(self.format);
    }

    /// Clear to `background` and draw one frame of `vertices` laid out in `viewport` units.
    /// A new `extent` (physical pixels) resizes the swapchain first.
    pub fn paint(self: *Painter, extent: vit.Extent2D, font: *const ui.Font, vertices: []const ui.Vertex, viewport: ui.Rect, background: ui.Color) !void {
        // ponytail: waits for the GPU every frame so the single vertex buffer is free; add frames in flight if it matters.
        try self.queue.waitIdle();
        if (extent.width != self.extent.width or extent.height != self.extent.height) {
            try self.swapchain.resize(extent);
            self.extent = extent;
        }
        try self.commands.reset();
        const acquired = try self.swapchain.acquireNextImage(null);
        const cmd = try vit.CommandBuffer.init(self.commands, .{});
        defer cmd.deinit();
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .present, .after = .color_attachment } }});
        try self.renderer.upload(cmd, font, vertices, viewport);
        const linear = self.srgb();
        try cmd.beginRenderPass(.{ .color_attachments = &.{.{
            .view = acquired.view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{
                .r = if (linear) ui.linearChannel(background[0]) else background[0],
                .g = if (linear) ui.linearChannel(background[1]) else background[1],
                .b = if (linear) ui.linearChannel(background[2]) else background[2],
                .a = 1,
            },
        }} });
        self.renderer.draw(cmd, self.extent, 0, vertices.len);
        cmd.endRenderPass();
        try cmd.barrier(&.{.{ .texture_view = .{ .view = acquired.view, .before = .color_attachment, .after = .present } }});
        try cmd.finish();
        try self.queue.submit(.{ .command_buffers = &.{cmd} });
        _ = try self.swapchain.present(&.{});
    }
};

/// Whether Weeoui should linearize colors for this target (`Canvas.srgb_target` / `Context.srgb_target`).
pub fn isSrgb(format: vit.Format) bool {
    return format == .bgra8_unorm_srgb or format == .rgba8_unorm_srgb;
}

pub fn colorFormat(format: vit.SwapchainFormat) vit.Format {
    return switch (format) {
        .bgra8_unorm => .bgra8_unorm,
        .bgra8_unorm_srgb => .bgra8_unorm_srgb,
        .rgba8_unorm => .rgba8_unorm,
        .rgba8_unorm_srgb => .rgba8_unorm_srgb,
        .rgba16_float => .rgba16_float,
    };
}

fn createVertexBuffer(device: vit.Device, capacity: usize) !vit.Buffer {
    return vit.Buffer.init(device, .{ .label = "weeoui vertices", .size = capacity * @sizeOf(ui.Vertex), .usage = .{ .vertex = true }, .memory = .upload });
}

fn toClip(v: ui.Vertex, viewport: ui.Rect) ui.Vertex {
    var out = v;
    out.position = .{ 2 * (v.position[0] - viewport.x) / viewport.w - 1, 1 - 2 * (v.position[1] - viewport.y) / viewport.h };
    return out;
}

test "vertices map from viewport units to clip space" {
    const viewport = ui.Rect{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const corner = toClip(.{ .position = .{ 0, 0 }, .color = .{ 1, 1, 1, 1 }, .uv = .{ 0, 0 } }, viewport);
    try std.testing.expectEqual([2]f32{ -1, 1 }, corner.position);
    const centre = toClip(.{ .position = .{ 100, 50 }, .color = .{ 1, 1, 1, 1 }, .uv = .{ 0, 0 } }, viewport);
    try std.testing.expectEqual([2]f32{ 0, 0 }, centre.position);
    std.testing.refAllDecls(Renderer);
    std.testing.refAllDecls(Painter);
}
