//! Vitellus renderer for Weeoui vertices, in the spirit of egui_wgpu.
//! Per frame: `upload` before your render pass, then `draw` inside it.
const std = @import("std");
const vit = @import("vitellus");
const ui = @import("weeoui");

pub const Renderer = struct {
    device: vit.Device,
    vertices: vit.Buffer,
    capacity: usize,
    pipeline_layout: vit.PipelineLayout,
    pipeline: vit.GraphicsPipeline,
    font_texture: vit.Texture,
    font_view: vit.TextureView,
    font_sampler: vit.Sampler,
    font_layout: vit.BindGroupLayout,
    font_group: vit.BindGroup,
    font_needs_barrier: bool = true,

    /// `color_format` is the render target format; the font atlas is uploaded once from `font`.
    pub fn init(device: vit.Device, color_format: vit.Format, font: *const ui.Font) !Renderer {
        const capacity = 4096;
        const vertices = try createVertexBuffer(device, capacity);
        errdefer vertices.deinit();
        const font_texture = try vit.Texture.init(device, .{ .label = "weeoui font", .width = ui.atlas_width, .height = ui.atlas_height, .format = .r8_unorm, .usage = .{ .sampled = true }, .initial_data = font.pixels });
        errdefer font_texture.deinit();
        const font_view = try vit.TextureView.init(device, .{ .texture = font_texture });
        errdefer font_view.deinit();
        const font_sampler = try vit.Sampler.init(device, .{ .address_u = .clamp_to_edge, .address_v = .clamp_to_edge });
        errdefer font_sampler.deinit();
        const font_layout = try vit.BindGroupLayout.init(device, .{ .entries = &.{
            .{ .binding = 0, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
            .{ .binding = 1, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
        } });
        errdefer font_layout.deinit();
        const font_group = try vit.BindGroup.init(device, .{ .layout = font_layout, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = font_view } },
            .{ .binding = 1, .resource = .{ .sampler = font_sampler } },
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
            } }},
            .color_targets = &.{.{ .format = color_format, .blend = .{ .color = .{ .source = .src_alpha, .destination = .one_minus_src_alpha }, .alpha = .{ .source = .one, .destination = .one_minus_src_alpha } } }},
            .raster = .{ .cull_mode = .none },
            .layout = pipeline_layout,
        });
        return .{ .device = device, .vertices = vertices, .capacity = capacity, .pipeline_layout = pipeline_layout, .pipeline = pipeline, .font_texture = font_texture, .font_view = font_view, .font_sampler = font_sampler, .font_layout = font_layout, .font_group = font_group };
    }

    pub fn deinit(self: *Renderer) void {
        self.pipeline.deinit();
        self.pipeline_layout.deinit();
        self.font_group.deinit();
        self.font_layout.deinit();
        self.font_sampler.deinit();
        self.font_view.deinit();
        self.font_texture.deinit();
        self.vertices.deinit();
    }

    /// Copy `vertices` (in `viewport` units) to the GPU. Call outside a render pass; the buffer grows as needed.
    // ponytail: one upload buffer reused every frame; wait for the previous frame before calling, or add per-frame buffers.
    pub fn upload(self: *Renderer, cmd: vit.CommandBuffer, vertices: []const ui.Vertex, viewport: ui.Rect) !void {
        if (self.font_needs_barrier) {
            try cmd.barrier(&.{.{ .texture = .{ .texture = self.font_texture, .before = .common, .after = .sampled } }});
            self.font_needs_barrier = false;
        }
        if (vertices.len > self.capacity) {
            const capacity = std.math.ceilPowerOfTwoAssert(usize, vertices.len);
            const grown = try createVertexBuffer(self.device, capacity);
            self.vertices.deinit();
            self.vertices = grown;
            self.capacity = capacity;
        }
        if (vertices.len == 0) return;
        const size = vertices.len * @sizeOf(ui.Vertex);
        const mapped = try self.vertices.map(.write, .{ .size = size });
        const out: []ui.Vertex = @alignCast(std.mem.bytesAsSlice(ui.Vertex, mapped[0..size]));
        for (out, vertices) |*dst, src| dst.* = toClip(src, viewport);
        self.vertices.unmap(.{ .size = size });
    }

    /// Draw `count` uploaded vertices starting at `first`. Call inside a render pass targeting `extent`.
    pub fn draw(self: *const Renderer, cmd: vit.CommandBuffer, extent: vit.Extent2D, first: usize, count: usize) void {
        if (count == 0) return;
        cmd.setGraphicsPipeline(self.pipeline);
        cmd.setBindGroup(0, self.font_group, &.{});
        cmd.setViewport(.{ .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height) });
        cmd.setScissor(.{ .width = extent.width, .height = extent.height });
        cmd.setVertexBuffer(0, self.vertices, 0);
        cmd.draw(@intCast(count), 1, @intCast(first), 0);
    }
};

/// Whether Weeoui should linearize colors for this target (`Canvas.srgb_target` / `Context.srgb_target`).
pub fn isSrgb(format: vit.Format) bool {
    return format == .bgra8_unorm_srgb or format == .rgba8_unorm_srgb;
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
}
