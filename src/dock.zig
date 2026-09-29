//! Dockable panels, as in game-engine editors: a tree of splits and tab stacks, floating windows
//! inside the main window, and panels detached into their own OS windows.
//!
//! The app owns one `DockSpace` and a set of panels identified by nonzero `u32`s (below
//! `max_panel`). Each frame it calls `build` once per host (the main window, plus every entry in
//! `windows` it has opened an OS window for), supplying titles and contents. Presses on the dock's
//! ids go to `press`, pointer motion while `dragging()` to `drag`, and the release to `release`;
//! keyboard activation of its ids goes to `activate`.
const std = @import("std");
const builtin = @import("builtin");
const L = @import("layout.zig");
const titlebar = @import("titlebar.zig");
const types = @import("types.zig");
const Canvas = @import("canvas.zig").Canvas;
const Rect = types.Rect;

/// Dock controls use ids from `first_id`; keep app ids below it.
pub const first_id: u32 = 0xD0C0_0000;
/// Panel ids must be nonzero and below this.
pub const max_panel: u32 = 0x1_0000;
const tab_first = first_id; // + panel
const split_first = first_id + 0x1_0000; // + node
const popout_first = first_id + 0x1_0100; // + node
const dockback_first = first_id + 0x1_0200; // + node
const grip_first = first_id + 0x1_0300; // + floating index
const bar_first = first_id + 0x1_0400; // + node
/// The stack's menu button, and its items: + node * 4 + (pop out, float, dock back).
const menu_first = first_id + 0x1_0500;
const menu_item_first = first_id + 0x1_0600;
/// Floating windows' close/minimize/maximize: + floating * 3 + `titlebar.Button`.
const window_button_first = first_id + 0x1_0800;
const last_id = window_button_first + max_floating * 3;
fn owns(id: u32) bool {
    return id >= first_id and id < last_id;
}

const max_nodes = 64;
const max_tabs = 16;
pub const max_floating = 8;
pub const max_windows = 8;
const splitter: f32 = 4;
const min_side: f32 = 60;
const grip: f32 = 14;

pub const Side = enum { center, left, right, top, bottom };
pub const Host = union(enum) { main, floating: u8, window: u8 };

const Index = u8;
const none: Index = 0xFF;
const zero = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };

const Node = struct {
    kind: enum { free, split, tabs } = .free,
    /// Split: `first` above `second` instead of beside it.
    vertical: bool = false,
    ratio: f32 = 0.5,
    first: Index = none,
    second: Index = none,
    parent: Index = none,
    panels: [max_tabs]u32 = undefined,
    count: u8 = 0,
    active: u8 = 0,
    rect: Rect = zero,
};

pub const Floating = struct {
    root: Index,
    rect: Rect,
    /// Stacking order; higher draws on top.
    z: u32 = 0,
    /// Folded to its tab bar.
    minimized: bool = false,
    /// Filling the main window; `restore` is where it goes back to.
    maximized: bool = false,
    restore: Rect = zero,
};

pub const Window = struct {
    root: Index,
    /// Size to open the OS window at, in logical units.
    size: [2]f32,
    /// App-owned OS window, renderer, etc.; the dock never touches it.
    handle: ?*anyopaque = null,
};

/// Where a dragged tab would land.
pub const Target = union(enum) {
    node: struct { index: Index, side: Side },
    float: Rect,
    window,
};

const Drag = union(enum) {
    none,
    split: Index,
    move: struct { floating: u8, dx: f32, dy: f32 },
    resize: struct { floating: u8, dx: f32, dy: f32 },
    tab: struct { panel: u32, x: f32, y: f32, started: bool = false, target: ?Target = null, pointer: [2]f32 = .{ 0, 0 } },
};

pub const DockSpace = struct {
    nodes: [max_nodes]Node = [_]Node{.{}} ** max_nodes,
    root: Index = none,
    floating: [max_floating]?Floating = @splat(null),
    windows: [max_windows]?Window = @splat(null),
    z_counter: u32 = 0,
    viewport: Rect = zero,
    drag: Drag = .none,
    /// False when the app cannot open OS windows: pop-outs float instead.
    os_windows: bool = true,
    tab_height: f32 = 30,
    /// Close/minimize/maximize order and look for floating windows; set from the desktop's.
    buttons: titlebar.Layout = titlebar.Layout.default(builtin.os.tag),
    /// Tab stack whose menu is open.
    menu: Index = none,

    pub fn init() DockSpace {
        var self = DockSpace{};
        self.root = self.alloc() catch unreachable;
        self.nodes[self.root] = .{ .kind = .tabs };
        return self;
    }

    fn alloc(self: *DockSpace) !Index {
        for (&self.nodes, 0..) |*node, i| if (node.kind == .free) {
            node.* = .{ .kind = .tabs };
            return @intCast(i);
        };
        return error.TooManyDockNodes;
    }

    /// Tab stack holding `panel`.
    pub fn nodeOf(self: *const DockSpace, panel: u32) ?Index {
        for (self.nodes, 0..) |node, i| {
            if (node.kind == .tabs and std.mem.indexOfScalar(u32, node.panels[0..node.count], panel) != null) return @intCast(i);
        }
        return null;
    }
    fn top(self: *const DockSpace, index: Index) Index {
        var at = index;
        while (self.nodes[at].parent != none) at = self.nodes[at].parent;
        return at;
    }
    pub fn hostOf(self: *const DockSpace, index: Index) Host {
        const root = self.top(index);
        for (self.floating, 0..) |f, i| if (f) |entry| if (entry.root == root) return .{ .floating = @intCast(i) };
        for (self.windows, 0..) |w, i| if (w) |entry| if (entry.root == root) return .{ .window = @intCast(i) };
        return .main;
    }
    /// The panel shown in `panel`'s tab stack.
    pub fn isVisible(self: *const DockSpace, panel: u32) bool {
        const index = self.nodeOf(panel) orelse return false;
        const node = self.nodes[index];
        return node.panels[node.active] == panel;
    }

    /// Dock `panel` next to (or with `.center`, into the same tab stack as) `near`; without
    /// `near` it joins the largest tab stack of the main window.
    pub fn add(self: *DockSpace, panel: u32, near: ?u32, side: Side) !void {
        if (panel == 0 or panel >= max_panel) return error.InvalidPanel;
        if (self.nodeOf(panel) != null) return error.PanelExists;
        const target = if (near) |other| self.nodeOf(other) orelse return error.UnknownPanel else self.largest(self.root);
        _ = try self.insert(target, side, panel);
    }

    fn largest(self: *const DockSpace, index: Index) Index {
        const node = self.nodes[index];
        if (node.kind == .tabs) return index;
        const a = self.largest(node.first);
        const b = self.largest(node.second);
        const ra = self.nodes[a].rect;
        const rb = self.nodes[b].rect;
        return if (rb.w * rb.h > ra.w * ra.h) b else a;
    }

    /// Put `panel` into tab stack `index` (center) or beside it. Returns where the stack's
    /// previous contents ended up (they move when the stack is split).
    fn insert(self: *DockSpace, index: Index, side: Side, panel: u32) !Index {
        if (side == .center or self.nodes[index].count == 0) {
            const node = &self.nodes[index];
            if (node.count == max_tabs) return error.TooManyTabs;
            node.panels[node.count] = panel;
            node.active = node.count;
            node.count += 1;
            return index;
        }
        const moved = try self.alloc();
        errdefer self.nodes[moved] = .{};
        const added = try self.alloc();
        self.nodes[moved] = self.nodes[index];
        self.nodes[moved].parent = index;
        self.nodes[added] = .{ .kind = .tabs, .parent = index, .count = 1 };
        self.nodes[added].panels[0] = panel;
        const before = side == .left or side == .top;
        self.nodes[index] = .{
            .kind = .split,
            .vertical = side == .top or side == .bottom,
            .first = if (before) added else moved,
            .second = if (before) moved else added,
            .parent = self.nodes[index].parent,
            .rect = self.nodes[index].rect,
        };
        return moved;
    }

    fn removeTab(self: *DockSpace, index: Index, panel: u32) void {
        const node = &self.nodes[index];
        const at = std.mem.indexOfScalar(u32, node.panels[0..node.count], panel) orelse return;
        std.mem.copyForwards(u32, node.panels[at .. node.count - 1], node.panels[at + 1 .. node.count]);
        node.count -= 1;
        if (node.active > at or node.active == node.count) node.active -|= 1;
    }

    /// An empty tab stack gives its space to its sibling; an empty floating or OS window closes.
    fn collapse(self: *DockSpace, index: Index) void {
        const parent = self.nodes[index].parent;
        if (parent == none) {
            if (index == self.root) return; // the main window keeps an empty stack
            for (&self.floating) |*f| if (f.*) |entry| if (entry.root == index) {
                f.* = null;
            };
            for (&self.windows) |*w| if (w.*) |entry| if (entry.root == index) {
                w.* = null;
            };
            self.nodes[index] = .{};
            return;
        }
        const p = self.nodes[parent];
        const sibling = if (p.first == index) p.second else p.first;
        const rect = p.rect;
        self.nodes[parent] = self.nodes[sibling];
        self.nodes[parent].parent = p.parent;
        self.nodes[parent].rect = rect;
        if (self.nodes[parent].kind == .split) {
            self.nodes[self.nodes[parent].first].parent = parent;
            self.nodes[self.nodes[parent].second].parent = parent;
        }
        self.nodes[sibling] = .{};
        self.nodes[index] = .{};
    }

    /// Take `panel` out of the layout (it is no longer shown).
    pub fn remove(self: *DockSpace, panel: u32) void {
        const index = self.nodeOf(panel) orelse return;
        self.removeTab(index, panel);
        if (self.nodes[index].count == 0) self.collapse(index);
    }

    /// Move `panel` to `side` of tab stack `target`.
    pub fn move(self: *DockSpace, panel: u32, target: Index, side: Side) !void {
        var source = self.nodeOf(panel) orelse return error.UnknownPanel;
        if (source == target and (side == .center or self.nodes[source].count == 1)) return;
        self.removeTab(source, panel);
        const moved = try self.insert(target, side, panel);
        if (source == target) source = moved;
        if (self.nodes[source].count == 0) self.collapse(source);
    }

    fn newRoot(self: *DockSpace, panel: u32) !Index {
        const index = try self.alloc();
        self.nodes[index].panels[0] = panel;
        self.nodes[index].count = 1;
        return index;
    }

    /// Float `panel` in its own window inside the main one.
    pub fn float(self: *DockSpace, panel: u32, rect: Rect) !void {
        const slot = for (self.floating, 0..) |f, i| {
            if (f == null) break i;
        } else return error.TooManyFloating;
        self.remove(panel);
        self.z_counter += 1;
        self.floating[slot] = .{ .root = try self.newRoot(panel), .rect = rect, .z = self.z_counter };
    }

    /// Move `panel` into a new OS window; the app opens it on the next frame. Without OS window
    /// support the panel floats instead.
    pub fn detach(self: *DockSpace, panel: u32) !void {
        const index = self.nodeOf(panel) orelse return error.UnknownPanel;
        const rect = self.nodes[index].rect;
        const size = [2]f32{ @max(320, rect.w), @max(240, rect.h) };
        if (!self.os_windows) return self.float(panel, .{ .x = self.viewport.x + 40, .y = self.viewport.y + 40, .w = @min(size[0], self.viewport.w - 80), .h = @min(size[1], self.viewport.h - 80) });
        const slot = for (self.windows, 0..) |w, i| {
            if (w == null) break i;
        } else return error.TooManyWindows;
        self.remove(panel);
        self.windows[slot] = .{ .root = try self.newRoot(panel), .size = size };
    }

    /// Return every panel of a floating or OS window to the main window and close it.
    /// Call this when the user closes an OS window.
    pub fn redock(self: *DockSpace, host: Host) void {
        const root = switch (host) {
            .main => return,
            .floating => |i| (self.floating[i] orelse return).root,
            .window => |i| (self.windows[i] orelse return).root,
        };
        var panels: [max_nodes * max_tabs]u32 = undefined;
        const n = self.collect(root, &panels, 0);
        for (panels[0..n]) |panel| {
            self.remove(panel);
            self.add(panel, null, .center) catch {};
        }
    }
    fn collect(self: *const DockSpace, index: Index, out: []u32, start: usize) usize {
        const node = self.nodes[index];
        switch (node.kind) {
            .tabs => {
                @memcpy(out[start..][0..node.count], node.panels[0..node.count]);
                return start + node.count;
            },
            .split => return self.collect(node.second, out, self.collect(node.first, out, start)),
            .free => return start,
        }
    }

    fn place(self: *DockSpace, index: Index, r: Rect) void {
        const node = &self.nodes[index];
        node.rect = r;
        if (node.kind != .split) return;
        const total = (if (node.vertical) r.h else r.w) - splitter;
        const a = std.math.clamp(total * node.ratio, @min(min_side, total / 2), @max(total - min_side, total / 2));
        const first = node.first;
        const second = node.second;
        if (node.vertical) {
            self.place(first, .{ .x = r.x, .y = r.y, .w = r.w, .h = a });
            self.place(second, .{ .x = r.x, .y = r.y + a + splitter, .w = r.w, .h = total - a });
        } else {
            self.place(first, .{ .x = r.x, .y = r.y, .w = a, .h = r.h });
            self.place(second, .{ .x = r.x + a + splitter, .y = r.y, .w = total - a, .h = r.h });
        }
    }

    /// Compute every rectangle for the main window and its floating windows.
    pub fn layout(self: *DockSpace, viewport: Rect) void {
        self.viewport = viewport;
        self.place(self.root, viewport);
        for (&self.floating) |*f| if (f.*) |*entry| {
            if (entry.maximized) entry.rect = viewport;
            // Keep at least the tab bar reachable.
            entry.rect.w = std.math.clamp(entry.rect.w, 160, @max(160, viewport.w));
            entry.rect.h = std.math.clamp(entry.rect.h, 120, @max(120, viewport.h));
            entry.rect.x = std.math.clamp(entry.rect.x, viewport.x - entry.rect.w + 60, viewport.x + viewport.w - 60);
            entry.rect.y = std.math.clamp(entry.rect.y, viewport.y, viewport.y + viewport.h - self.tab_height);
            const h = if (entry.minimized) self.tab_height else entry.rect.h - 2 - grip;
            self.place(entry.root, .{ .x = entry.rect.x + 1, .y = entry.rect.y + 1, .w = entry.rect.w - 2, .h = h });
        };
    }

    pub fn dragging(self: *const DockSpace) bool {
        return self.drag != .none;
    }
    /// Pointer shape while a drag is under way: resize arrows on splitters and the grip, a move
    /// cursor while carrying a tab or a floating window.
    pub fn cursor(self: *const DockSpace) ?@import("input.zig").Cursor {
        return switch (self.drag) {
            .none => null,
            .split => |index| if (self.nodes[index].vertical) .ns_resize else .ew_resize,
            .move => .move,
            .resize => .nwse_resize,
            .tab => |t| if (t.started) .move else null,
        };
    }

    fn raise(self: *DockSpace, index: Index) void {
        switch (self.hostOf(index)) {
            .floating => |i| {
                self.z_counter += 1;
                self.floating[i].?.z = self.z_counter;
            },
            else => {},
        }
    }

    /// Pointer down on dock id `id` at (x, y) in its host's coordinates. Returns false for other ids.
    pub fn press(self: *DockSpace, id: u32, x: f32, y: f32) bool {
        if (!owns(id)) return false;
        if (!(id >= menu_first and id < menu_item_first + max_nodes * 4)) self.menu = none;
        switch (id) {
            tab_first + 1...tab_first + max_panel - 1 => {
                const panel = id - tab_first;
                const index = self.nodeOf(panel) orelse return true;
                self.select(index, panel);
                self.raise(index);
                // Tabs in OS windows switch but don't drag: their coordinates are another window's.
                if (self.hostOf(index) != .window) self.drag = .{ .tab = .{ .panel = panel, .x = x, .y = y, .pointer = .{ x, y } } };
            },
            split_first...split_first + max_nodes - 1 => self.drag = .{ .split = @intCast(id - split_first) },
            bar_first...bar_first + max_nodes - 1 => {
                const index: Index = @intCast(id - bar_first);
                self.raise(index);
                switch (self.hostOf(index)) {
                    .floating => |i| if (!self.floating[i].?.maximized) {
                        const r = self.floating[i].?.rect;
                        self.drag = .{ .move = .{ .floating = i, .dx = x - r.x, .dy = y - r.y } };
                    },
                    else => {},
                }
            },
            grip_first...grip_first + max_floating - 1 => {
                const i: u8 = @intCast(id - grip_first);
                const r = (self.floating[i] orelse return true).rect;
                self.drag = .{ .resize = .{ .floating = i, .dx = r.x + r.w - x, .dy = r.y + r.h - y } };
            },
            else => _ = self.activate(id),
        }
        return true;
    }

    /// Keyboard (or assistive) activation of dock id `id`.
    pub fn activate(self: *DockSpace, id: u32) bool {
        if (!owns(id)) return false;
        switch (id) {
            tab_first + 1...tab_first + max_panel - 1 => {
                const panel = id - tab_first;
                if (self.nodeOf(panel)) |index| self.select(index, panel);
            },
            popout_first...popout_first + max_nodes - 1 => {
                const node = self.nodes[id - popout_first];
                if (node.kind == .tabs and node.count > 0) self.detach(node.panels[node.active]) catch {};
            },
            dockback_first...dockback_first + max_nodes - 1 => self.redock(self.hostOf(@intCast(id - dockback_first))),
            menu_first...menu_first + max_nodes - 1 => {
                const index: Index = @intCast(id - menu_first);
                self.menu = if (self.menu == index) none else index;
            },
            menu_item_first...menu_item_first + max_nodes * 4 - 1 => {
                const index: Index = @intCast((id - menu_item_first) / 4);
                const node = self.nodes[index];
                self.menu = none;
                if (node.kind != .tabs or node.count == 0) return true;
                const panel = node.panels[node.active];
                switch ((id - menu_item_first) % 4) {
                    0 => self.detach(panel) catch {},
                    1 => self.float(panel, self.floatRect(panel, node.rect.x + 40, node.rect.y + 40)) catch {},
                    else => self.redock(self.hostOf(index)),
                }
            },
            window_button_first...window_button_first + max_floating * 3 - 1 => {
                const i: u8 = @intCast((id - window_button_first) / 3);
                const f = &(self.floating[i] orelse return true);
                switch (@as(titlebar.Button, @enumFromInt((id - window_button_first) % 3))) {
                    .close => self.redock(.{ .floating = i }),
                    .minimize => f.minimized = !f.minimized,
                    .maximize => {
                        if (f.maximized) f.rect = f.restore else f.restore = f.rect;
                        f.maximized = !f.maximized;
                        f.minimized = false;
                    },
                }
            },
            else => {},
        }
        return true;
    }
    /// Close the open stack menu (a press elsewhere, or Escape). Returns whether one was open.
    pub fn dismissMenu(self: *DockSpace) bool {
        defer self.menu = none;
        return self.menu != none;
    }

    fn select(self: *DockSpace, index: Index, panel: u32) void {
        const node = &self.nodes[index];
        node.active = @intCast(std.mem.indexOfScalar(u32, node.panels[0..node.count], panel) orelse return);
    }

    /// Pointer motion while `dragging()`, in the main window's coordinates.
    pub fn dragTo(self: *DockSpace, x: f32, y: f32) void {
        switch (self.drag) {
            .none => {},
            .split => |index| {
                const node = &self.nodes[index];
                const r = node.rect;
                const total = (if (node.vertical) r.h else r.w) - splitter;
                if (total <= 0) return;
                const at = if (node.vertical) y - r.y else x - r.x;
                node.ratio = std.math.clamp((at - splitter / 2) / total, 0.05, 0.95);
            },
            .move => |m| {
                const f = &(self.floating[m.floating] orelse return);
                f.rect.x = x - m.dx;
                f.rect.y = y - m.dy;
            },
            .resize => |m| {
                const f = &(self.floating[m.floating] orelse return);
                f.rect.w = @max(160, x + m.dx - f.rect.x);
                f.rect.h = @max(120, y + m.dy - f.rect.y);
            },
            .tab => |*t| {
                t.pointer = .{ x, y };
                if (!t.started and std.math.hypot(x - t.x, y - t.y) < 6) return;
                t.started = true;
                t.target = self.targetAt(t.panel, x, y);
            },
        }
    }

    /// Pointer released: finish the drag (a dragged tab docks, floats, or pops out).
    pub fn release(self: *DockSpace, x: f32, y: f32) void {
        defer self.drag = .none;
        switch (self.drag) {
            .tab => |t| {
                if (!t.started) return;
                const target = self.targetAt(t.panel, x, y);
                switch (target) {
                    .node => |n| self.move(t.panel, n.index, n.side) catch {},
                    .float => |r| self.float(t.panel, r) catch {},
                    .window => self.detach(t.panel) catch {},
                }
            },
            else => {},
        }
    }

    /// Tab stack under (x, y), topmost floating window first.
    fn stackAt(self: *const DockSpace, x: f32, y: f32) ?Index {
        var best: ?Index = null;
        var best_z: u32 = 0;
        for (self.floating) |f| if (f) |entry| {
            if (entry.rect.contains(x, y) and (best == null or entry.z > best_z)) {
                best = self.deepest(entry.root, x, y);
                best_z = entry.z;
            }
        };
        if (best) |b| return b;
        return if (self.viewport.contains(x, y)) self.deepest(self.root, x, y) else null;
    }
    fn deepest(self: *const DockSpace, index: Index, x: f32, y: f32) Index {
        const node = self.nodes[index];
        if (node.kind != .split) return index;
        return if (self.nodes[node.first].rect.contains(x, y)) self.deepest(node.first, x, y) else self.deepest(node.second, x, y);
    }

    /// The compass buttons shown over tab stack `index` while dragging.
    pub fn compass(self: *const DockSpace, index: Index) [5]struct { side: Side, rect: Rect } {
        const r = self.nodes[index].rect;
        const c = r.center();
        const s: f32 = 30;
        const step: f32 = 36;
        const at = struct {
            fn f(cx: f32, cy: f32, size: f32) Rect {
                return .{ .x = cx - size / 2, .y = cy - size / 2, .w = size, .h = size };
            }
        }.f;
        return .{
            .{ .side = .center, .rect = at(c.x, c.y, s) },
            .{ .side = .left, .rect = at(c.x - step, c.y, s) },
            .{ .side = .right, .rect = at(c.x + step, c.y, s) },
            .{ .side = .top, .rect = at(c.x, c.y - step, s) },
            .{ .side = .bottom, .rect = at(c.x, c.y + step, s) },
        };
    }

    fn targetAt(self: *const DockSpace, panel: u32, x: f32, y: f32) Target {
        if (!self.viewport.contains(x, y)) return if (self.os_windows) .window else .{ .float = self.floatRect(panel, x, y) };
        if (self.stackAt(x, y)) |index| {
            for (self.compass(index)) |button| if (button.rect.contains(x, y)) return .{ .node = .{ .index = index, .side = button.side } };
            // Dropping onto a tab bar joins that stack.
            const r = self.nodes[index].rect;
            if (y < r.y + self.tab_height and y >= r.y) return .{ .node = .{ .index = index, .side = .center } };
        }
        return .{ .float = self.floatRect(panel, x, y) };
    }
    fn floatRect(self: *const DockSpace, panel: u32, x: f32, y: f32) Rect {
        const r = if (self.nodeOf(panel)) |index| self.nodes[index].rect else zero;
        const w = std.math.clamp(r.w, 280, 480);
        const h = std.math.clamp(r.h, 200, 360);
        return .{ .x = x - 40, .y = y - self.tab_height / 2, .w = w, .h = h };
    }

    /// Area a drop on `target` would give the panel, for the preview.
    fn previewRect(self: *const DockSpace, target: Target) ?Rect {
        return switch (target) {
            .window => null,
            .float => |r| r,
            .node => |n| blk: {
                const r = self.nodes[n.index].rect;
                break :blk switch (n.side) {
                    .center => r,
                    .left => Rect{ .x = r.x, .y = r.y, .w = r.w / 2, .h = r.h },
                    .right => Rect{ .x = r.x + r.w / 2, .y = r.y, .w = r.w / 2, .h = r.h },
                    .top => Rect{ .x = r.x, .y = r.y, .w = r.w, .h = r.h / 2 },
                    .bottom => Rect{ .x = r.x, .y = r.y + r.h / 2, .w = r.w, .h = r.h / 2 },
                };
            },
        };
    }

    /// Build `host`'s element tree sized to `viewport`. `provider` has
    /// `fn title(self, panel: u32) []const u8` and
    /// `fn content(self, b: L.Builder, panel: u32, rect: Rect) !*L.Element`.
    pub fn build(self: *DockSpace, b: L.Builder, host: Host, viewport: Rect, provider: anytype) !*L.Element {
        var layers: std.ArrayList(*L.Element) = .empty;
        switch (host) {
            .main => {
                self.layout(viewport);
                try layers.append(b.allocator, try self.nodeElement(b, self.root, .main, provider));
                // Floating windows, bottom to top.
                var order: [max_floating]u8 = undefined;
                var n: usize = 0;
                for (self.floating, 0..) |f, i| if (f != null) {
                    order[n] = @intCast(i);
                    n += 1;
                };
                const Z = struct {
                    fn less(space: *const DockSpace, a: u8, c: u8) bool {
                        return space.floating[a].?.z < space.floating[c].?.z;
                    }
                };
                std.mem.sort(u8, order[0..n], self, Z.less);
                for (order[0..n], 0..) |i, rank| try layers.append(b.allocator, try self.floatingElement(b, i, @intCast(rank), provider));
                if (self.drag == .tab and self.drag.tab.started) try self.dragPreview(b, &layers);
            },
            .floating => return error.FloatingIsPartOfMain,
            .window => |i| {
                const entry = self.windows[i] orelse return error.UnknownWindow;
                self.place(entry.root, viewport);
                try layers.append(b.allocator, try self.nodeElement(b, entry.root, host, provider));
            },
        }
        return b.node(0, .{ .width = viewport.w, .height = viewport.h }, .none, layers.items);
    }

    fn nodeElement(self: *DockSpace, b: L.Builder, index: Index, host: Host, provider: anytype) !*L.Element {
        const node = self.nodes[index];
        const r = node.rect;
        if (node.kind == .split) {
            const handle = try b.node(split_first + index, if (node.vertical) .{ .height = splitter } else .{ .width = splitter }, .hover, &.{});
            handle.cursor = if (node.vertical) .ns_resize else .ew_resize;
            handle.accessibility = .{ .role = .slider, .label = "Resize panels", .numeric_value = node.ratio };
            return b.node(0, .{ .width = r.w, .height = r.h, .direction = if (node.vertical) .column else .row }, .none, &.{
                try self.nodeElement(b, node.first, host, provider),
                handle,
                try self.nodeElement(b, node.second, host, provider),
            });
        }
        var tabs: std.ArrayList(*L.Element) = .empty;
        for (node.panels[0..node.count], 0..) |panel, i| {
            const tab = try b.node(tab_first + panel, .{ .height = self.tab_height - 6 }, .{ .tab = .{ .label = provider.title(panel), .selected = i == node.active } }, &.{});
            tab.accessibility = .{ .role = .tab, .label = provider.title(panel) };
            try tabs.append(b.allocator, tab);
        }
        try tabs.append(b.allocator, try b.node(0, .{ .grow = 1 }, .none, &.{}));
        if (node.count > 0) {
            const burger = try b.node(menu_first + index, .{ .width = self.tab_height - 6, .height = self.tab_height - 6, .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 } }, .{ .button = .{ .label = "", .variant = .ghost, .hot = self.menu == index } }, &.{try b.node(0, .{ .width = 16, .height = 16 }, .{ .icon = .menu }, &.{})});
            burger.children[0].accessibility.role = .ignored;
            burger.accessibility = .{ .role = .button, .label = "Panel menu", .expanded = self.menu == index };
            try tabs.append(b.allocator, burger);
            if (self.menu == index) {
                var items: [3]@import("widgets.zig").MenuItem = undefined;
                var n: usize = 0;
                if (host != .window and self.os_windows) {
                    items[n] = .{ .id = menu_item_first + @as(u32, index) * 4, .label = "Pop out into window" };
                    n += 1;
                }
                if (host == .main) {
                    items[n] = .{ .id = menu_item_first + @as(u32, index) * 4 + 1, .label = "Float" };
                    n += 1;
                }
                if (host != .main) {
                    items[n] = .{ .id = menu_item_first + @as(u32, index) * 4 + 2, .label = "Dock back" };
                    n += 1;
                }
                const menu = try @import("widgets.zig").menuItems(b, items[0..n], 0, 0);
                menu.style.width = 200;
                try tabs.append(b.allocator, @import("widgets.zig").anchorTo(menu, burger, .bottom, 700));
            }
        }
        const floating_index: ?u8 = switch (host) {
            .floating => |i| if (self.floating[i].?.root == index) i else null,
            else => null,
        };
        if (floating_index) |i| {
            const f = self.floating[i].?;
            const state = titlebar.State{ .maximized = f.maximized };
            const ids = [3]u32{ window_button_first + @as(u32, i) * 3, window_button_first + @as(u32, i) * 3 + 1, window_button_first + @as(u32, i) * 3 + 2 };
            try tabs.insert(b.allocator, 0, try titlebar.buttonRow(b, self.buttons, .left, state, ids));
            try tabs.append(b.allocator, try titlebar.buttonRow(b, self.buttons, .right, state, ids));
        }
        const bar = try b.node(bar_first + index, .{ .direction = .row, .height = self.tab_height, .gap = 2, .align_items = .center, .padding = .{ .left = 3, .right = 3 } }, .{ .surface = .track }, tabs.items);
        bar.accessibility = .{ .role = .tab_list, .label = "Panels" };
        if (floating_index != null) {
            // A floating window moves by its tab bar, so the bar is a press target of its own.
            bar.accessibility = .{ .role = .button, .label = "Move window" };
            bar.cursor = .move;
        }
        const content_rect = Rect{ .x = r.x, .y = r.y + self.tab_height, .w = r.w, .h = @max(0, r.h - self.tab_height) };
        if (content_rect.h <= 0) return b.node(0, .{ .width = r.w, .height = r.h }, .none, &.{bar}); // a minimized floating window
        const content = if (node.count == 0)
            try b.node(0, .{ .padding = .{ .top = 24 } }, .{ .text = .{ .value = "Drag a tab here", .size = 13, .tone = .muted, .alignment = .center } }, &.{})
        else
            try provider.content(b, node.panels[node.active], content_rect);
        const body = try b.node(0, .{ .width = content_rect.w, .height = content_rect.h, .overflow = .scroll }, .none, &.{content});
        body.accessibility = .{ .role = .tab_panel, .label = if (node.count > 0) provider.title(node.panels[node.active]) else "Empty" };
        return b.node(0, .{ .width = r.w, .height = r.h }, .none, &.{ bar, body });
    }

    fn floatingElement(self: *DockSpace, b: L.Builder, i: u8, rank: u8, provider: anytype) !*L.Element {
        const f = self.floating[i].?;
        const handle = try b.node(grip_first + i, .{ .width = grip, .height = grip }, .{ .custom = .{ .context = &grip_marker, .draw = drawGrip } }, &.{});
        handle.accessibility = .{ .role = .slider, .label = "Resize window" };
        handle.cursor = .nwse_resize;
        const window = if (f.minimized)
            try b.node(0, .{ .width = f.rect.w, .height = self.tab_height + 2, .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } }, .{ .surface = .popover }, &.{try self.nodeElement(b, f.root, .{ .floating = i }, provider)})
        else
            try b.node(0, .{ .width = f.rect.w, .height = f.rect.h, .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } }, .{ .surface = .popover }, &.{
                try self.nodeElement(b, f.root, .{ .floating = i }, provider),
                try b.node(0, .{ .direction = .row, .height = grip, .justify = .end }, .none, &.{handle}),
            });
        window.style.z_index = 400 + @as(i16, rank);
        window.overlay = .{ .point = .init(f.rect.x, f.rect.y) };
        window.accessibility = .{ .role = .dialog, .label = "Floating panel" };
        return window;
    }

    fn dragPreview(self: *DockSpace, b: L.Builder, layers: *std.ArrayList(*L.Element)) !void {
        const t = self.drag.tab;
        const hint = struct {
            fn at(builder: L.Builder, r: Rect, draw: *const fn (*const anyopaque, *Canvas, Rect) anyerror!void, context: *const anyopaque, z: i16) !*L.Element {
                const e = try builder.node(0, .{ .width = r.w, .height = r.h, .z_index = z }, .{ .custom = .{ .context = context, .draw = draw } }, &.{});
                e.overlay = .{ .point = .init(r.x, r.y) };
                e.accessibility.role = .ignored;
                return e;
            }
        }.at;
        if (t.target) |target| if (self.previewRect(target)) |r| try layers.append(b.allocator, try hint(b, r, drawHint, &grip_marker, 900));
        if (self.stackAt(t.pointer[0], t.pointer[1])) |index| {
            for (self.compass(index)) |button| {
                const hovered = t.target != null and t.target.? == .node and t.target.?.node.index == index and t.target.?.node.side == button.side;
                try layers.append(b.allocator, try hint(b, button.rect, drawCompass, &compass_contexts[@as(usize, @intFromEnum(button.side)) * 2 + @intFromBool(hovered)], 950));
            }
        }
    }
};

const grip_marker: u8 = 0;
const CompassButton = struct { side: Side, hovered: bool };
const compass_contexts = blk: {
    var all: [10]CompassButton = undefined;
    for (0..5) |s| for (0..2) |h| {
        all[s * 2 + h] = .{ .side = @enumFromInt(s), .hovered = h == 1 };
    };
    break :blk all;
};

fn drawHint(_: *const anyopaque, c: *Canvas, r: Rect) anyerror!void {
    try c.roundRectAlpha(r, c.theme.ring, c.theme.radiusMd(), 0.25);
    try c.roundRectStroke(r, c.theme.ring, c.theme.radiusMd(), 2);
}

fn drawCompass(context: *const anyopaque, c: *Canvas, r: Rect) anyerror!void {
    const button: *const CompassButton = @ptrCast(@alignCast(context));
    try c.roundRect(r, c.theme.border, 6);
    try c.roundRect(r.inset(1), if (button.hovered) c.theme.accent else c.theme.popover, 5);
    // A filled block on the side the panel would take.
    const inner = r.inset(6);
    const fill = switch (button.side) {
        .center => inner,
        .left => Rect{ .x = inner.x, .y = inner.y, .w = inner.w / 2, .h = inner.h },
        .right => Rect{ .x = inner.x + inner.w / 2, .y = inner.y, .w = inner.w / 2, .h = inner.h },
        .top => Rect{ .x = inner.x, .y = inner.y, .w = inner.w, .h = inner.h / 2 },
        .bottom => Rect{ .x = inner.x, .y = inner.y + inner.h / 2, .w = inner.w, .h = inner.h / 2 },
    };
    try c.roundRectStroke(inner, c.theme.muted_foreground, 2, 1);
    try c.roundRect(fill, if (button.hovered) c.theme.primary else c.theme.muted_foreground, 2);
}

fn drawGrip(_: *const anyopaque, c: *Canvas, r: Rect) anyerror!void {
    // Three dots along the diagonal, like a window corner grip.
    for (0..3) |i| {
        const d = @as(f32, @floatFromInt(i)) * 4;
        try c.roundRect(.{ .x = r.x + r.w - 4 - d, .y = r.y + r.h - 4 - (8 - d), .w = 2, .h = 2 }, c.theme.muted_foreground, 1);
        try c.roundRect(.{ .x = r.x + r.w - 4, .y = r.y + r.h - 4 - d, .w = 2, .h = 2 }, c.theme.muted_foreground, 1);
    }
}

const TestProvider = struct {
    fn title(_: TestProvider, panel: u32) []const u8 {
        return switch (panel) {
            1 => "Scene",
            2 => "Console",
            3 => "Inspector",
            else => "Panel",
        };
    }
    fn content(_: TestProvider, b: L.Builder, panel: u32, _: Rect) !*L.Element {
        return b.node(panel * 10, .{}, .{ .text = .{ .value = "body" } }, &.{});
    }
};

test "panels split, tab, collapse and keep their sizes" {
    var dock = DockSpace.init();
    const viewport = Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    try dock.add(1, null, .center);
    try dock.add(2, 1, .right);
    try dock.add(3, 2, .bottom);
    dock.layout(viewport);
    const scene = dock.nodes[dock.nodeOf(1).?].rect;
    const inspector = dock.nodes[dock.nodeOf(3).?].rect;
    try std.testing.expectEqual(@as(f32, 0), scene.x);
    try std.testing.expectApproxEqAbs(@as(f32, 498), scene.w, 0.01);
    try std.testing.expect(inspector.x > 500 and inspector.y > 290);
    // Tabbing Console into Scene's stack collapses the right column's upper half.
    try dock.move(2, dock.nodeOf(1).?, .center);
    dock.layout(viewport);
    try std.testing.expectEqual(dock.nodeOf(1).?, dock.nodeOf(2).?);
    try std.testing.expect(dock.isVisible(2) and !dock.isVisible(1));
    try std.testing.expectEqual(@as(f32, 600), dock.nodes[dock.nodeOf(3).?].rect.h);
    // Removing everything leaves the main window one empty stack, and every node is reused.
    dock.remove(1);
    dock.remove(2);
    dock.remove(3);
    var used: usize = 0;
    for (dock.nodes) |node| used += @intFromBool(node.kind != .free);
    try std.testing.expectEqual(@as(usize, 1), used);
    try std.testing.expectEqual(@as(u8, 0), dock.nodes[dock.root].count);
}

test "dragging tabs docks on the compass, floats elsewhere and pops out past the window" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    var dock = DockSpace.init();
    const viewport = Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    try dock.add(1, null, .center);
    try dock.add(2, 1, .center);
    try dock.add(3, 1, .right);
    const root = try dock.build(b, .main, viewport, TestProvider{});
    root.layout(viewport, &font);
    try std.testing.expect(root.find(tab_first + 2) != null and root.find(30) != null);
    // Drag Console (a tab of the left stack) onto the right stack's "bottom" compass button.
    const right = dock.nodeOf(3).?;
    const bottom = dock.compass(right)[4].rect.center();
    try std.testing.expect(dock.press(tab_first + 2, 20, 15));
    dock.dragTo(40, 60);
    dock.dragTo(bottom.x, bottom.y);
    try std.testing.expectEqual(Side.bottom, dock.drag.tab.target.?.node.side);
    const preview = try dock.build(b, .main, viewport, TestProvider{});
    try std.testing.expect(preview.children.len > 1); // compass and hint overlays
    dock.release(bottom.x, bottom.y);
    dock.layout(viewport);
    const console = dock.nodes[dock.nodeOf(2).?].rect;
    try std.testing.expect(console.x > 500 and console.y > 290);
    // Dropping away from the compass floats it; the floating window moves and resizes.
    try std.testing.expect(dock.press(tab_first + 2, console.x + 10, console.y + 10));
    dock.dragTo(100, 500);
    dock.release(100, 500);
    try std.testing.expect(dock.hostOf(dock.nodeOf(2).?) == .floating);
    dock.layout(viewport);
    try std.testing.expect(dock.press(bar_first + dock.nodeOf(2).?, 80, 490));
    dock.dragTo(380, 190);
    dock.release(380, 190);
    // Floated at (60, 485); grabbed 20 right and 5 down of its corner, then dragged.
    try std.testing.expectEqual(@as(f32, 360), dock.floating[0].?.rect.x);
    try std.testing.expectEqual(@as(f32, 185), dock.floating[0].?.rect.y);
    // Past the main window's edge it becomes an OS window; "Dock" brings it back.
    try std.testing.expect(dock.press(tab_first + 2, 300, 110));
    dock.dragTo(1200, 300);
    dock.release(1200, 300);
    try std.testing.expect(dock.floating[0] == null and dock.windows[0] != null);
    const window = try dock.build(b, .{ .window = 0 }, .{ .x = 0, .y = 0, .w = 400, .h = 300 }, TestProvider{});
    window.layout(.{ .x = 0, .y = 0, .w = 400, .h = 300 }, &font);
    try std.testing.expect(window.find(menu_first + dock.nodeOf(2).?) != null);
    // "Dock back" from the stack menu.
    try std.testing.expect(dock.activate(menu_first + dock.nodeOf(2).?));
    try std.testing.expect(dock.activate(menu_item_first + @as(u32, dock.nodeOf(2).?) * 4 + 2));
    try std.testing.expect(dock.windows[0] == null and dock.hostOf(dock.nodeOf(2).?) == .main);
}

test "splitters resize within limits and pop-out floats without OS windows" {
    var dock = DockSpace.init();
    dock.os_windows = false;
    const viewport = Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    try dock.add(1, null, .center);
    try dock.add(2, 1, .left);
    dock.layout(viewport);
    try std.testing.expect(dock.press(split_first + dock.root, 500, 300));
    dock.dragTo(250, 300);
    dock.release(250, 300);
    dock.layout(viewport);
    try std.testing.expectApproxEqAbs(@as(f32, 248), dock.nodes[dock.nodeOf(2).?].rect.w, 1);
    try std.testing.expect(dock.press(split_first + dock.root, 250, 300));
    dock.dragTo(-500, 300);
    dock.release(-500, 300);
    dock.layout(viewport);
    try std.testing.expect(dock.nodes[dock.nodeOf(2).?].rect.w >= min_side);
    // The stack menu's first item pops out; without OS windows that floats.
    try std.testing.expect(dock.activate(menu_first + dock.nodeOf(1).?));
    try std.testing.expectEqual(dock.nodeOf(1).?, dock.menu);
    try std.testing.expect(dock.activate(menu_item_first + @as(u32, dock.nodeOf(1).?) * 4 + 1));
    try std.testing.expect(dock.hostOf(dock.nodeOf(1).?) == .floating and dock.menu == none);
    try std.testing.expectError(error.PanelExists, dock.add(2, null, .center));
    // Ids outside the dock's range (another widget's) are left alone.
    try std.testing.expect(!dock.press(0xDE70_0008, 0, 0) and !dock.activate(last_id));
}

test "floating windows minimize to their tab bar, maximize over the main window, and close back in" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    var dock = DockSpace.init();
    dock.buttons = titlebar.Layout.default(.windows);
    const viewport = Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    try dock.add(1, null, .center);
    try dock.add(2, 1, .right);
    try dock.float(2, .{ .x = 100, .y = 100, .w = 300, .h = 200 });
    var root = try dock.build(b, .main, viewport, TestProvider{});
    root.layout(viewport, &font);
    const close = window_button_first + @intFromEnum(titlebar.Button.close);
    const minimize = window_button_first + @intFromEnum(titlebar.Button.minimize);
    const maximize = window_button_first + @intFromEnum(titlebar.Button.maximize);
    try std.testing.expect(root.find(close) != null and root.find(maximize) != null);
    try std.testing.expect(root.find(close).?.bounds.x > root.find(minimize).?.bounds.x); // Windows order
    try std.testing.expect(dock.activate(minimize));
    root = try dock.build(b, .main, viewport, TestProvider{});
    root.layout(viewport, &font);
    try std.testing.expect(root.find(20) == null); // content hidden while minimized
    try std.testing.expect(dock.activate(maximize));
    dock.layout(viewport);
    try std.testing.expectEqual(viewport.w, dock.floating[0].?.rect.w);
    try std.testing.expect(dock.activate(maximize));
    dock.layout(viewport);
    try std.testing.expectEqual(@as(f32, 300), dock.floating[0].?.rect.w);
    try std.testing.expect(dock.activate(close));
    try std.testing.expect(dock.floating[0] == null and dock.hostOf(dock.nodeOf(2).?) == .main);
}
