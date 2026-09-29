//! Immediate-mode front end: call widgets every frame, they return what the user did.
//! Hit-testing uses the previous frame's layout, so widgets can answer before this frame is laid out.
const std = @import("std");
const types = @import("types.zig");
const Rect = types.Rect;
const Vec2 = types.Vec2;
const Vertex = types.Vertex;
const Font = @import("font.zig").Font;
const Canvas = @import("canvas.zig").Canvas;
const L = @import("layout.zig");
const input = @import("input.zig");
const accessibility = @import("accessibility.zig");
const accesskit = @import("accesskit.zig");

pub const Container = enum { column, row, card };

pub const Context = struct {
    gpa: std.mem.Allocator,
    font: Font,
    theme: types.Theme = .{},
    /// Physical pixels per viewport unit, for crisp edges on HiDPI targets.
    pixel_scale: [2]f32 = .{ 1, 1 },
    /// Set when rendering to an sRGB target so colors are linearized.
    srgb_target: bool = false,
    arena: std.heap.ArenaAllocator,
    vertices: std.ArrayList(Vertex) = .empty,
    /// Element bounds from the last `render`, keyed by widget id.
    last_bounds: std.AutoHashMapUnmanaged(u32, Rect) = .empty,
    pointer: Vec2 = .zero,
    clicked: bool = false,
    viewport: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Open containers; the first entry is the frame root.
    stack: std.ArrayList(Open) = .empty,
    /// First failure during the frame, returned by `render` so widget calls need no `try`.
    err: ?anyerror = null,
    /// Screen-reader bridge; created by `attachAccessibility` (the SDL3 adapter does this for you).
    accesskit: ?*accesskit.Adapter = null,
    /// Name screen readers announce for the window.
    name: []const u8 = "weeoui",
    /// Focused widget (keyboard and assistive technology share it); 0 when none.
    focus: u32 = 0,
    /// Focusable widgets in declaration order: this frame's, and the last rendered frame's for Tab.
    focusables: std.ArrayList(u32) = .empty,
    last_focusables: std.ArrayList(u32) = .empty,
    /// Pending Tab (+1) / Shift+Tab (-1) moves, applied at `newFrame`.
    tab_moves: i32 = 0,
    /// Enter/Space pressed since the last frame.
    activate: bool = false,
    /// Widget clicked by assistive technology this frame.
    a11y_clicked: u32 = 0,
    /// Outline every clickable region in red, to check hit targets.
    debug_hitboxes: bool = false,
    /// Draw the focus ring: on after keyboard navigation, off after a click (like :focus-visible).
    focus_visible: bool = false,
    /// Pointer shape for the element under the pointer, after `render`; backends apply it.
    cursor: input.Cursor = .default,

    const Open = struct { kind: Container, id: u32, children: std.ArrayList(*L.Element) = .empty };

    pub fn init(gpa: std.mem.Allocator) !Context {
        return .{ .gpa = gpa, .font = try Font.init(gpa, @import("root.zig").default_font), .arena = .init(gpa) };
    }

    pub fn deinit(self: *Context) void {
        if (self.accesskit) |adapter| adapter.destroy();
        self.font.deinit();
        self.arena.deinit();
        self.vertices.deinit(self.gpa);
        self.last_bounds.deinit(self.gpa);
        self.last_focusables.deinit(self.gpa);
    }

    /// Feed pointer input in the same coordinates as the viewport.
    pub fn handle(self: *Context, event: input.Event) void {
        switch (event) {
            .pointer_move => |p| self.pointer = p,
            .pointer_down => |down| {
                self.pointer = down.position;
                self.focus_visible = false;
                if (down.button == .left) self.clicked = true;
            },
            .pointer_up => |up| self.pointer = up.position,
            .key_down => |key| switch (key.key) {
                // Repeats count too, so holding Tab keeps moving focus.
                .tab => {
                    self.tab_moves += if (key.modifiers.shift) -1 else 1;
                    self.focus_visible = true;
                },
                .enter, .space => if (!key.repeat) {
                    self.activate = true;
                },
                else => {},
            },
            else => {},
        }
    }

    /// Expose this UI to screen readers through `window`. Idempotent.
    pub fn attachAccessibility(self: *Context, window: accesskit.Window) !void {
        if (self.accesskit == null) self.accesskit = try accesskit.Adapter.create(self.gpa, window, self.name);
    }

    pub fn newFrame(self: *Context, viewport: Rect) void {
        _ = self.arena.reset(.retain_capacity);
        if (self.accesskit) |adapter| while (adapter.nextAction()) |action| switch (action) {
            .click => |target| self.a11y_clicked = target,
            .focus => |target| self.focus = target,
            else => {},
        };
        self.moveFocus();
        self.focusables = .empty;
        self.viewport = viewport;
        self.stack = .empty;
        self.err = null;
        self.push(.column, 0);
    }

    pub fn begin(self: *Context, kind: Container) void {
        self.push(kind, self.id(@tagName(kind)));
    }

    pub fn end(self: *Context) void {
        std.debug.assert(self.stack.items.len > 1); // unmatched `end`
        const open = self.stack.pop().?;
        const style: L.Style = switch (open.kind) {
            .column => .{ .gap = 12 },
            .row => .{ .direction = .row, .gap = 12 },
            .card => .{ .padding = .{ .left = 24, .right = 24, .top = 24, .bottom = 24 }, .gap = 12 },
        };
        self.add(open.id, style, if (open.kind == .card) .card else .none, open.children.items);
    }

    pub fn label(self: *Context, comptime fmt: []const u8, args: anytype) void {
        const value = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch |e| return self.fail(e);
        self.add(0, .{}, .{ .text = .{ .value = value } }, &.{});
    }

    /// Returns true on the frame the button is clicked. Text after `##` is hidden but keeps ids unique.
    pub fn button(self: *Context, text: []const u8) bool {
        const widget = self.focusable(text);
        const clicked = self.pressed(widget);
        self.add(widget, .{ .width = 120, .height = 40 }, .{ .button = .{ .label = visible(text), .hot = self.hovered(widget) } }, &.{});
        return clicked;
    }

    /// Toggles `value` when clicked; returns true if it changed.
    pub fn checkbox(self: *Context, text: []const u8, value: *bool) bool {
        const widget = self.focusable(text);
        const changed = self.pressed(widget);
        if (changed) value.* = !value.*;
        self.add(widget, .{ .height = 32 }, .{ .checkbox = .{ .label = visible(text), .checked = value.* } }, &.{});
        return changed;
    }

    /// Lays out and paints the frame. The vertices stay valid until the next `render`.
    pub fn render(self: *Context) ![]const Vertex {
        defer {
            self.clicked = false;
            self.a11y_clicked = 0;
            self.activate = false;
        }
        if (self.err) |e| return e;
        std.debug.assert(self.stack.items.len == 1); // missing `end`
        const b = L.Builder{ .allocator = self.arena.allocator() };
        const root = try b.node(0, .{ .width = self.viewport.w, .height = self.viewport.h, .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 }, .gap = 12 }, .none, self.stack.items[0].children.items);
        root.layout(self.viewport, &self.font);
        self.last_bounds.clearRetainingCapacity();
        try self.remember(root);
        self.last_focusables.clearRetainingCapacity();
        try self.last_focusables.appendSlice(self.gpa, self.focusables.items);
        if (std.mem.indexOfScalar(u32, self.focusables.items, self.focus) == null) self.focus = 0;
        if (self.accesskit) |adapter| {
            root.accessibility.label = self.name;
            // ponytail: republishes the whole tree every frame; diff against the last snapshot if screen readers lag.
            var tree_arena = std.heap.ArenaAllocator.init(self.gpa);
            errdefer tree_arena.deinit();
            const snapshot = try accessibility.collect(tree_arena.allocator(), root, self.focus);
            adapter.update(tree_arena, snapshot, 1);
        }
        if (self.vertices.capacity == 0) try self.vertices.ensureTotalCapacity(self.gpa, 4096);
        while (true) {
            var canvas = Canvas.init(self.vertices.allocatedSlice(), &self.font);
            canvas.theme = self.theme;
            canvas.pixel_scale = self.pixel_scale;
            canvas.srgb_target = self.srgb_target;
            canvas.focus_id = if (self.focus_visible) self.focus else 0;
            canvas.hot_id = self.hoveredWidget();
            self.cursor = if (root.find(canvas.hot_id)) |hot| hot.cursorFor() else .default;
            if (root.draw(&canvas)) {
                if (self.debug_hitboxes) root.drawHitboxes(&canvas) catch |e| switch (e) {
                    error.OutOfVertices => {
                        try self.vertices.ensureTotalCapacity(self.gpa, self.vertices.capacity * 2);
                        continue;
                    },
                    else => return e,
                };
                return canvas.items();
            } else |e| switch (e) {
                error.OutOfVertices => try self.vertices.ensureTotalCapacity(self.gpa, self.vertices.capacity * 2),
                else => return e,
            }
        }
    }

    fn push(self: *Context, kind: Container, widget: u32) void {
        self.stack.append(self.arena.allocator(), .{ .kind = kind, .id = widget }) catch |e| self.fail(e);
    }

    fn add(self: *Context, widget: u32, style: L.Style, paint: L.Paint, children: []const *L.Element) void {
        if (self.err != null) return;
        const b = L.Builder{ .allocator = self.arena.allocator() };
        const element = b.node(widget, style, paint, children) catch |e| return self.fail(e);
        const parent = &self.stack.items[self.stack.items.len - 1];
        parent.children.append(self.arena.allocator(), element) catch |e| self.fail(e);
    }

    fn remember(self: *Context, element: *const L.Element) !void {
        if (element.id != 0) try self.last_bounds.put(self.gpa, element.id, element.bounds.intersection(element.clip));
        for (element.children) |child| try self.remember(child);
    }

    // ponytail: ids hash the label with the open-container path; identical labels in one container collide, use `##suffix`.
    fn id(self: *const Context, text: []const u8) u32 {
        var seed: u64 = 0;
        for (self.stack.items) |open| seed = seed *% 31 +% open.id +% open.children.items.len;
        return @as(u32, @truncate(std.hash.Wyhash.hash(seed, text))) | 1;
    }

    /// Smallest last-frame widget under the pointer, so nested hit targets win.
    fn hoveredWidget(self: *const Context) u32 {
        var best: u32 = 0;
        var area = std.math.inf(f32);
        var it = self.last_bounds.iterator();
        while (it.next()) |entry| {
            const r = entry.value_ptr.*;
            if (r.contains(self.pointer.x, self.pointer.y) and r.w * r.h < area) {
                best = entry.key_ptr.*;
                area = r.w * r.h;
            }
        }
        return best;
    }

    fn hovered(self: *const Context, widget: u32) bool {
        const r = self.last_bounds.get(widget) orelse return false;
        return r.contains(self.pointer.x, self.pointer.y);
    }

    /// Id for an interactive widget, registered in Tab order. A mouse press on it takes focus.
    fn focusable(self: *Context, text: []const u8) u32 {
        const widget = self.id(text);
        self.focusables.append(self.arena.allocator(), widget) catch |e| self.fail(e);
        if (self.clicked and self.hovered(widget)) self.focus = widget;
        return widget;
    }

    fn moveFocus(self: *Context) void {
        defer self.tab_moves = 0;
        const order = self.last_focusables.items;
        if (self.tab_moves == 0 or order.len == 0) return;
        const n: i64 = @intCast(order.len);
        const start: i64 = if (std.mem.indexOfScalar(u32, order, self.focus)) |i| @intCast(i) else if (self.tab_moves > 0) -1 else n;
        self.focus = order[@intCast(@mod(start + self.tab_moves, n))];
    }

    fn pressed(self: *const Context, widget: u32) bool {
        return (self.clicked and self.hovered(widget)) or self.a11y_clicked == widget or (self.activate and self.focus == widget);
    }

    fn fail(self: *Context, e: anyerror) void {
        if (self.err == null) self.err = e;
    }
};

fn visible(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOf(u8, text, "##") orelse text.len];
}

test "screen reader clicks and the published tree reach the counter" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var adapter = accesskit.Adapter{ .allocator = std.testing.allocator, .name = "", .arena = .init(std.testing.allocator) };
    defer adapter.arena.deinit();
    ctx.accesskit = &adapter;
    defer ctx.accesskit = null;
    const viewport = Rect{ .x = 0, .y = 0, .w = 400, .h = 300 };
    var count: u32 = 0;
    for (0..2) |frame| {
        if (frame == 1) {
            var ids = ctx.last_bounds.keyIterator();
            adapter.push(.{ .click = ids.next().?.* }); // the only widget with an id
        }
        ctx.newFrame(viewport);
        ctx.label("Count: {d}", .{count});
        if (ctx.button("Increment")) count += 1;
        _ = try ctx.render();
    }
    try std.testing.expectEqual(@as(u32, 1), count);
    const dump = try accesskit.debugTree(&adapter, std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "Increment") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "weeoui") != null);
}

test "tab and shift+tab cycle focus; enter activates the focused widget" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const viewport = Rect{ .x = 0, .y = 0, .w = 400, .h = 300 };
    var count: u32 = 0;
    var hints = false;
    const Frame = struct {
        fn run(c: *Context, v: Rect, n: *u32, h: *bool) !void {
            c.newFrame(v);
            if (c.button("Increment")) n.* += 1;
            _ = c.checkbox("Show hints", h);
            _ = try c.render();
        }
    };
    const tab: input.Event = .{ .key_down = .{ .key = .tab, .modifiers = .{}, .repeat = false } };
    const back_tab: input.Event = .{ .key_down = .{ .key = .tab, .modifiers = .{ .shift = true }, .repeat = false } };
    const enter: input.Event = .{ .key_down = .{ .key = .enter, .modifiers = .{}, .repeat = false } };

    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(@as(u32, 0), ctx.focus);
    const button_id = ctx.last_focusables.items[0];
    const checkbox_id = ctx.last_focusables.items[1];

    ctx.handle(tab);
    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(button_id, ctx.focus);
    ctx.handle(enter);
    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(@as(u32, 1), count);

    ctx.handle(tab);
    ctx.handle(.{ .key_down = .{ .key = .space, .modifiers = .{}, .repeat = false } });
    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(checkbox_id, ctx.focus);
    try std.testing.expect(hints);

    // A held Tab (repeat events) keeps moving: two steps from the checkbox wrap back to it.
    ctx.handle(.{ .key_down = .{ .key = .tab, .modifiers = .{}, .repeat = true } });
    ctx.handle(.{ .key_down = .{ .key = .tab, .modifiers = .{}, .repeat = true } });
    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(checkbox_id, ctx.focus);
    ctx.handle(tab); // wraps to the first widget
    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(button_id, ctx.focus);
    ctx.handle(back_tab); // and back around to the last
    try Frame.run(&ctx, viewport, &count, &hints);
    try std.testing.expectEqual(checkbox_id, ctx.focus);
    try std.testing.expectEqual(@as(u32, 1), count);
}

test "counter button clicks against last frame's layout" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const viewport = Rect{ .x = 0, .y = 0, .w = 400, .h = 300 };
    var count: u32 = 0;
    var hints = false;
    for (0..3) |_| {
        ctx.newFrame(viewport);
        ctx.begin(.card);
        ctx.label("Count: {d}", .{count});
        if (ctx.button("Increment")) count += 1;
        _ = ctx.checkbox("Show hints", &hints);
        ctx.end();
        try std.testing.expect((try ctx.render()).len > 0);
        // Click the button (the only 120-wide widget) at its centre from the frame just rendered.
        var it = ctx.last_bounds.iterator();
        while (it.next()) |entry| if (entry.value_ptr.w == 120) ctx.handle(.{ .pointer_down = .{ .position = entry.value_ptr.center(), .button = .left, .clicks = 1 } });
    }
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expect(!hints);
}
