//! Custom window title bars whose close/minimize/maximize buttons follow the platform:
//! which buttons exist and on which side (GNOME's `button-layout`, GTK's
//! `gtk-decoration-layout`, macOS traffic lights on the left, Windows on the right), and how
//! they look. The backend (see `weeoui_sdl3.useCustomFrame`) makes the bar drag the window.
const std = @import("std");
const builtin = @import("builtin");
const L = @import("layout.zig");
const types = @import("types.zig");
const Canvas = @import("canvas.zig").Canvas;
const Rect = types.Rect;

pub const Button = enum(u2) { close, minimize, maximize };
pub const Style = enum { mac, gnome, windows };

pub const Layout = struct {
    left: [3]?Button = @splat(null),
    right: [3]?Button = @splat(null),
    style: Style = .gnome,

    /// The platform's usual layout, used when the desktop doesn't say otherwise.
    pub fn default(os: std.Target.Os.Tag) Layout {
        return switch (os) {
            .macos => parse("close,minimize,maximize:", .mac),
            .windows => parse(":minimize,maximize,close", .windows),
            else => parse(":minimize,maximize,close", .gnome),
        };
    }

    /// Parse a GNOME/GTK layout such as "appmenu:minimize,maximize,close" (left of the colon
    /// goes on the left). Unknown entries (appmenu, icon, spacer, menu) are skipped.
    pub fn parse(text: []const u8, style: Style) Layout {
        var layout = Layout{ .style = style };
        const trimmed = std.mem.trim(u8, text, " \t\r\n'\"");
        const colon = std.mem.indexOfScalar(u8, trimmed, ':');
        const sides = [2][]const u8{ if (colon) |c| trimmed[0..c] else "", if (colon) |c| trimmed[c + 1 ..] else trimmed };
        for (sides, [2]*[3]?Button{ &layout.left, &layout.right }) |side, slots| {
            var n: usize = 0;
            var it = std.mem.tokenizeAny(u8, side, ", ");
            while (it.next()) |name| {
                const button = std.meta.stringToEnum(Button, name) orelse continue;
                if (n == slots.len or layout.has(button)) continue;
                slots[n] = button;
                n += 1;
            }
        }
        return layout;
    }

    pub fn has(self: Layout, button: Button) bool {
        for (self.left ++ self.right) |slot| if (slot == button) return true;
        return false;
    }
};

/// Ids from `first_id` for window `slot`: + 0 close, + 1 minimize, + 2 maximize, + 3 the bar.
pub fn id(first_id: u32, slot: u32, part: enum(u2) { close, minimize, maximize, bar }) u32 {
    return first_id + slot * 4 + @intFromEnum(part);
}

pub const State = struct { maximized: bool = false, focused: bool = true };
pub const height: f32 = 36;

const Glyph = struct { button: Button, style: Style, maximized: bool, id: u32, focused: bool };

/// A title bar: platform buttons on their sides and the title in the middle. Its element has id
/// `id(first_id, slot, .bar)`; the button elements carry the other three ids.
pub fn bar(b: L.Builder, first_id: u32, slot: u32, title: []const u8, layout: Layout, state: State) !*L.Element {
    var children: std.ArrayList(*L.Element) = .empty;
    const group = struct {
        fn make(builder: L.Builder, list: *std.ArrayList(*L.Element), buttons: [3]?Button, l: Layout, s: State, first: u32, window: u32) !void {
            var row: std.ArrayList(*L.Element) = .empty;
            for (buttons) |slot_button| if (slot_button) |button| try row.append(builder.allocator, try buttonElement(builder, l.style, button, s, id(first, window, @enumFromInt(@intFromEnum(button)))));
            try list.append(builder.allocator, try builder.node(0, .{ .direction = .row, .gap = if (l.style == .mac) 8 else if (l.style == .gnome) 12 else 0, .align_items = .center, .padding = .{ .left = if (l.style == .windows) 0 else 12, .right = if (l.style == .windows) 0 else 12 }, .height = height }, .none, row.items));
        }
    }.make;
    try group(b, &children, layout.left, layout, state, first_id, slot);
    const label = try b.node(0, .{ .grow = 1, .height = height }, .{ .text = .{ .value = title, .size = 13, .tone = if (state.focused) .foreground else .muted, .alignment = .center } }, &.{});
    label.accessibility.role = .heading;
    try children.append(b.allocator, label);
    try group(b, &children, layout.right, layout, state, first_id, slot);
    const result = try b.node(id(first_id, slot, .bar), .{ .direction = .row, .height = height, .align_items = .center }, .{ .surface = .track }, children.items);
    result.accessibility = .{ .role = .group, .label = title };
    return result;
}

/// Just the buttons of one side, for bars drawn by other widgets (floating dock windows).
/// `ids` gives each button's element id, indexed by `Button`.
pub fn buttonRow(b: L.Builder, layout: Layout, side: enum { left, right }, state: State, ids: [3]u32) !*L.Element {
    var row: std.ArrayList(*L.Element) = .empty;
    for (if (side == .left) layout.left else layout.right) |slot| if (slot) |button| try row.append(b.allocator, try buttonElement(b, layout.style, button, state, ids[@intFromEnum(button)]));
    return b.node(0, .{ .direction = .row, .gap = if (layout.style == .windows) 0 else 8, .align_items = .center, .padding = .{ .left = 4, .right = 4 } }, .none, row.items);
}

fn buttonElement(b: L.Builder, style: Style, button: Button, state: State, element_id: u32) !*L.Element {
    const glyph = try b.allocator.create(Glyph);
    glyph.* = .{ .button = button, .style = style, .maximized = state.maximized, .id = element_id, .focused = state.focused };
    const size: [2]f32 = switch (style) {
        .mac => .{ 12, 12 },
        .gnome => .{ 24, 24 },
        .windows => .{ 46, height },
    };
    const node = try b.node(element_id, .{ .width = size[0], .height = size[1] }, .{ .custom = .{ .context = glyph, .draw = drawButton } }, &.{});
    node.accessibility = .{ .role = .button, .label = switch (button) {
        .close => "Close",
        .minimize => "Minimize",
        .maximize => if (state.maximized) "Restore" else "Maximize",
    } };
    return node;
}

/// A straight line from `a` to `b`, `width` thick (two triangles).
fn line(c: *Canvas, a: [2]f32, b: [2]f32, width: f32, color: types.Color) !void {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = @max(0.001, std.math.hypot(dx, dy));
    const nx = -dy / len * width / 2;
    const ny = dx / len * width / 2;
    const rgba = [4]f32{ color[0], color[1], color[2], 1 };
    const p = [4][2]f32{ .{ a[0] + nx, a[1] + ny }, .{ b[0] + nx, b[1] + ny }, .{ b[0] - nx, b[1] - ny }, .{ a[0] - nx, a[1] - ny } };
    try c.triangle(.{ p[0], p[1], p[2] }, .{ rgba, rgba, rgba });
    try c.triangle(.{ p[0], p[2], p[3] }, .{ rgba, rgba, rgba });
}

/// Minimize bar, maximize square, restore double square, or close cross, centred in `r`.
fn drawSymbol(c: *Canvas, r: Rect, glyph: Glyph, size: f32, color: types.Color) !void {
    const center = r.center();
    const half = size / 2;
    const stroke = @max(1, size / 9);
    switch (glyph.button) {
        .minimize => try c.rect(.{ .x = center.x - half, .y = center.y - stroke / 2, .w = size, .h = stroke }, color),
        .maximize => if (glyph.style == .mac) {
            try c.rect(.{ .x = center.x - half, .y = center.y - stroke / 2, .w = size, .h = stroke }, color);
            try c.rect(.{ .x = center.x - stroke / 2, .y = center.y - half, .w = stroke, .h = size }, color);
        } else if (glyph.maximized) {
            const s = size * 0.8;
            try c.roundRectStroke(.{ .x = center.x - half + size - s, .y = center.y - half, .w = s, .h = s }, color, 1, stroke);
            try c.roundRect(.{ .x = center.x - half, .y = center.y - half + size - s, .w = s, .h = s }, c.theme.muted, 1);
            try c.roundRectStroke(.{ .x = center.x - half, .y = center.y - half + size - s, .w = s, .h = s }, color, 1, stroke);
        } else try c.roundRectStroke(.{ .x = center.x - half, .y = center.y - half, .w = size, .h = size }, color, 1, stroke),
        .close => {
            try line(c, .{ center.x - half, center.y - half }, .{ center.x + half, center.y + half }, stroke * 1.3, color);
            try line(c, .{ center.x + half, center.y - half }, .{ center.x - half, center.y + half }, stroke * 1.3, color);
        },
    }
}

fn drawButton(context: *const anyopaque, c: *Canvas, r: Rect) anyerror!void {
    const glyph: *const Glyph = @ptrCast(@alignCast(context));
    const hot = c.hot_id == glyph.id;
    const t = c.theme;
    switch (glyph.style) {
        // Traffic lights: coloured when the window is focused, grey otherwise; symbols on hover.
        .mac => {
            const fill = if (!glyph.focused and !hot) t.border else switch (glyph.button) {
                .close => types.rgb(0xFF, 0x5F, 0x57),
                .minimize => types.rgb(0xFE, 0xBC, 0x2E),
                .maximize => types.rgb(0x28, 0xC8, 0x40),
            };
            try c.roundRect(r, fill, r.w / 2);
            if (hot) try drawSymbol(c, r, glyph.*, r.w * 0.5, .{ 0.3, 0.1, 0.05 });
        },
        // Adwaita: round buttons with a faint fill that deepens on hover.
        .gnome => {
            try c.roundRectAlpha(r, t.foreground, r.w / 2, if (hot) 0.16 else 0.08);
            try drawSymbol(c, r, glyph.*, 9, t.foreground);
        },
        // Windows: full-height rectangles; close turns red on hover.
        .windows => {
            if (hot) try c.rectAlpha(r, if (glyph.button == .close) types.rgb(0xC4, 0x2B, 0x1C) else t.foreground, if (glyph.button == .close) 1 else 0.1);
            try drawSymbol(c, r, glyph.*, 10, if (hot and glyph.button == .close) .{ 1, 1, 1 } else t.foreground);
        },
    }
}

pub const Hit = enum { normal, drag, resize_top_left, resize_top, resize_top_right, resize_right, resize_bottom_right, resize_bottom, resize_bottom_left, resize_left };

/// What a press at (x, y) does in a window of `size` whose title bar is `bar_rect` and whose
/// buttons are `buttons`: resize at the edges (unless maximized), drag on the bar, else nothing.
pub fn hitTest(size: [2]f32, bar_rect: Rect, buttons: []const Rect, maximized: bool, x: f32, y: f32) Hit {
    const edge: f32 = 6;
    if (!maximized) {
        const left = x < edge;
        const right = x >= size[0] - edge;
        const top = y < edge;
        const bottom = y >= size[1] - edge;
        if (top and left) return .resize_top_left;
        if (top and right) return .resize_top_right;
        if (bottom and left) return .resize_bottom_left;
        if (bottom and right) return .resize_bottom_right;
        if (top) return .resize_top;
        if (bottom) return .resize_bottom;
        if (left) return .resize_left;
        if (right) return .resize_right;
    }
    for (buttons) |button| if (button.contains(x, y)) return .normal;
    return if (bar_rect.contains(x, y)) .drag else .normal;
}

test "layouts parse like GNOME and GTK, dropping unknown and repeated entries" {
    const gnome = Layout.parse("'appmenu:minimize,maximize,close'", .gnome);
    try std.testing.expectEqual([3]?Button{ null, null, null }, gnome.left);
    try std.testing.expectEqual([3]?Button{ .minimize, .maximize, .close }, gnome.right);
    const tweaked = Layout.parse(":close", .gnome); // gnome-tweaks with minimize and maximize off
    try std.testing.expect(tweaked.has(.close) and !tweaked.has(.minimize) and !tweaked.has(.maximize));
    const mac = Layout.default(.macos);
    try std.testing.expectEqual([3]?Button{ .close, .minimize, .maximize }, mac.left);
    try std.testing.expectEqual(Style.mac, mac.style);
    try std.testing.expectEqual([3]?Button{ .minimize, .maximize, .close }, Layout.default(.windows).right);
    const odd = Layout.parse("close,icon:spacer,close,maximize", .gnome);
    try std.testing.expectEqual([3]?Button{ .close, null, null }, odd.left);
    try std.testing.expectEqual([3]?Button{ .maximize, null, null }, odd.right);
}

test "hit testing resizes at edges, drags the bar, and leaves buttons clickable" {
    const size = [2]f32{ 800, 600 };
    const bar_rect = Rect{ .x = 0, .y = 0, .w = 800, .h = height };
    const buttons = [_]Rect{.{ .x = 760, .y = 6, .w = 24, .h = 24 }};
    try std.testing.expectEqual(Hit.drag, hitTest(size, bar_rect, &buttons, false, 400, 20));
    try std.testing.expectEqual(Hit.normal, hitTest(size, bar_rect, &buttons, false, 770, 15));
    try std.testing.expectEqual(Hit.resize_top_left, hitTest(size, bar_rect, &buttons, false, 2, 2));
    try std.testing.expectEqual(Hit.resize_right, hitTest(size, bar_rect, &buttons, false, 798, 300));
    try std.testing.expectEqual(Hit.drag, hitTest(size, bar_rect, &buttons, true, 2, 2)); // maximized: no resize
    try std.testing.expectEqual(Hit.normal, hitTest(size, bar_rect, &buttons, false, 400, 300));
}

test "the bar orders buttons per layout and exposes ids" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const first: u32 = 0xC0FF_0000;
    const root = try bar(b, first, 1, "Scene", Layout.default(.macos), .{});
    root.layout(.{ .x = 0, .y = 0, .w = 600, .h = height }, &font);
    const close = root.find(id(first, 1, .close)).?;
    const maximize = root.find(id(first, 1, .maximize)).?;
    try std.testing.expect(close.bounds.x < 60 and close.bounds.x < maximize.bounds.x);
    try std.testing.expect(close.actionable());
    try std.testing.expect(!root.find(id(first, 1, .bar)).?.actionable());
    var vertices: [4096]types.Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    canvas.hot_id = id(first, 1, .close);
    try root.draw(&canvas);
    try std.testing.expect(canvas.len > 0);
    const tweaked = try bar(b, first, 0, "eggy", Layout.parse(":close", .gnome), .{});
    try std.testing.expect(tweaked.find(id(first, 0, .minimize)) == null);
}
