//! Chrome-style DevTools for any Weeoui layout tree, as three tools the app shows in panels
//! (dock panels, say): Elements (the whole tree, box model, editable styles), Performance, and
//! Console. Each frame the app calls `apply` on its freshly built page (edits live as overrides,
//! because the page is rebuilt every frame), lays it out, calls `prepare` with it, and builds
//! `view` for each tool it shows. Route the tools' ids to `activate`, text keys to
//! `insertText`/`editKey`/`commit`, and draw `highlight` over the page last.
const std = @import("std");
const L = @import("layout.zig");
const types = @import("types.zig");
const Canvas = @import("canvas.zig").Canvas;
const Font = @import("font.zig").Font;
const Rect = types.Rect;

/// Every panel control uses an id from `first_id` upwards; keep app ids below it.
pub const first_id: u32 = 0xDE70_0000;
const inspect_id = first_id + 8;
const clear_id = first_id + 10;
/// Id on each tool view's root element (not interactive): + @intFromEnum(Tool).
pub const view_id = first_id + 20;
const reset_id = first_id + 13;
const clear_edits_id = first_id + 14;
const expand_all_id = first_id + 15;
const collapse_all_id = first_id + 16;
/// Editable property fields: + @intFromEnum(Prop).
const prop_first = first_id + 200;
const row_first = first_id + 1000;
pub const max_rows = 8192;
/// Each row's expand/collapse chevron.
const chevron_first = row_first + max_rows;
const console_lines = 200;
const line_bytes = 200;

pub const Tool = enum(u8) { elements, performance, console };
pub const Level = enum { info, warn, err };
/// Keys a property field understands while it is being edited.
pub const EditKey = enum { left, right, home, end, backspace, delete, select_all, up, down };

/// Properties the Styles pane can change, in display order.
pub const Prop = enum(u8) {
    width,
    height,
    min_width,
    max_width,
    padding_top,
    padding_right,
    padding_bottom,
    padding_left,
    gap,
    grow,
    columns,
    z_index,
    direction,
    justify,
    align_items,
    wrap,
    overflow,
    rtl,
    text,
    text_size,
    hidden,

    const Kind = enum { number, size, choice, text };
    fn kind(self: Prop) Kind {
        return switch (self) {
            .width, .height, .max_width => .size,
            .direction, .justify, .align_items, .wrap, .overflow, .rtl, .hidden => .choice,
            .text => .text,
            else => .number,
        };
    }
    fn choices(self: Prop) []const []const u8 {
        return switch (self) {
            .direction => &.{ "column", "row" },
            .justify => &.{ "start", "center", "end", "space_between" },
            .align_items => &.{ "start", "center", "end" },
            .wrap, .hidden => &.{ "false", "true" },
            .overflow => &.{ "visible", "scroll" },
            .rtl => &.{ "inherit", "ltr", "rtl" },
            else => &.{},
        };
    }
    fn name(self: Prop) []const u8 {
        return switch (self) {
            .min_width => "min-width",
            .max_width => "max-width",
            .padding_top => "padding-top",
            .padding_right => "padding-right",
            .padding_bottom => "padding-bottom",
            .padding_left => "padding-left",
            .z_index => "z-index",
            .align_items => "align-items",
            .text_size => "font-size",
            .text => "text",
            else => @tagName(self),
        };
    }
};
const prop_count = @typeInfo(Prop).@"enum".fields.len;

const Value = union(enum) { number: f32, auto, choice: u8, text: []u8 };
/// Edits to one element; null means "as the app built it".
const Override = struct { values: [prop_count]?Value = @splat(null) };

const root_path: u64 = 14695981039346656037;
fn childPath(parent: u64, index: usize) u64 {
    return (parent ^ (index + 1)) *% 1099511628211;
}

/// Deepest element under (x, y), preferring later (painted-on-top) children.
fn pathAt(element: *const L.Element, path: u64, x: f32, y: f32) ?u64 {
    var i = element.children.len;
    while (i > 0) {
        i -= 1;
        if (pathAt(element.children[i], childPath(path, i), x, y)) |found| return found;
    }
    const visible = element.bounds.intersection(element.clip);
    return if (visible.w > 0 and visible.h > 0 and visible.contains(x, y)) path else null;
}

/// The element at `target`, recording every ancestor path in `trail` so they can be expanded.
fn find(element: *const L.Element, path: u64, target: u64, trail: *std.ArrayList(u64), gpa: std.mem.Allocator) !?*const L.Element {
    if (path == target) return element;
    try trail.append(gpa, path);
    for (element.children, 0..) |child, i| {
        if (try find(child, childPath(path, i), target, trail, gpa)) |found| return found;
    }
    _ = trail.pop();
    return null;
}

fn count(element: *const L.Element) usize {
    var total: usize = 1;
    for (element.children) |child| total += count(child);
    return total;
}

/// Tag-like name: the paint kind, with the surface or icon kind where that says more.
fn tagName(buffer: []u8, element: *const L.Element) []const u8 {
    return switch (element.paint_kind) {
        .surface => |surface| std.fmt.bufPrint(buffer, "surface.{s}", .{@tagName(surface)}) catch "surface",
        .icon => |icon| std.fmt.bufPrint(buffer, "icon.{s}", .{@tagName(icon)}) catch "icon",
        .none => if (element.children.len == 0) "empty" else if (element.style.columns > 0) "grid" else switch (element.style.direction) {
            .row => "row",
            .column => "column",
        },
        else => @tagName(element.paint_kind),
    };
}

/// The element's visible text, and a pointer to it when that text is editable.
fn textSlot(element: *L.Element) ?*[]const u8 {
    return switch (element.paint_kind) {
        .text => |*t| &t.value,
        .button => |*b| &b.label,
        .checkbox => |*b| &b.label,
        .toggle => |*b| &b.label,
        .toggle_button => |*b| &b.label,
        .tab => |*t| &t.label,
        .badge => |*b| &b.label,
        .menu_item => |*m| &m.label,
        .disclosure => |*d| &d.label,
        .input => |*i| &i.value,
        else => null,
    };
}
fn textOf(element: *const L.Element) []const u8 {
    if (textSlot(@constCast(element))) |slot| return slot.*;
    return element.accessibility.label orelse "";
}

/// Current value of `prop` on `element`, as shown in its field.
fn describe(buffer: []u8, element: *const L.Element, prop: Prop) []const u8 {
    const s = element.style;
    const number = struct {
        fn f(buf: []u8, value: f32) []const u8 {
            return std.fmt.bufPrint(buf, "{d}", .{value}) catch "?";
        }
    }.f;
    return switch (prop) {
        .width => if (s.width) |v| number(buffer, v) else "auto",
        .height => if (s.height) |v| number(buffer, v) else "auto",
        .max_width => if (s.max_width) |v| number(buffer, v) else "auto",
        .min_width => number(buffer, s.min_width),
        .padding_top => number(buffer, s.padding.top),
        .padding_right => number(buffer, s.padding.right),
        .padding_bottom => number(buffer, s.padding.bottom),
        .padding_left => number(buffer, s.padding.left),
        .gap => number(buffer, s.gap),
        .grow => number(buffer, s.grow),
        .columns => number(buffer, @floatFromInt(s.columns)),
        .z_index => number(buffer, @floatFromInt(s.z_index)),
        .direction => @tagName(s.direction),
        .justify => @tagName(s.justify),
        .align_items => @tagName(s.align_items),
        .wrap => if (s.wrap) "true" else "false",
        .overflow => @tagName(s.overflow),
        .rtl => if (s.rtl) |rtl| (if (rtl) "rtl" else "ltr") else "inherit",
        .text => textOf(element),
        .text_size => switch (element.paint_kind) {
            .text => |t| number(buffer, t.size),
            else => "",
        },
        .hidden => "false",
    };
}

fn applies(element: *const L.Element, prop: Prop) bool {
    return switch (prop) {
        .text => textSlot(@constCast(element)) != null,
        .text_size => element.paint_kind == .text,
        else => true,
    };
}

fn applyValue(element: *L.Element, prop: Prop, value: Value) void {
    const s = &element.style;
    const f: f32 = switch (value) {
        .number => |n| n,
        else => 0,
    };
    const choice: u8 = switch (value) {
        .choice => |c| c,
        else => 0,
    };
    switch (prop) {
        .width => s.width = if (value == .auto) null else f,
        .height => s.height = if (value == .auto) null else f,
        .max_width => s.max_width = if (value == .auto) null else f,
        .min_width => s.min_width = f,
        .padding_top => s.padding.top = f,
        .padding_right => s.padding.right = f,
        .padding_bottom => s.padding.bottom = f,
        .padding_left => s.padding.left = f,
        .gap => s.gap = f,
        .grow => s.grow = f,
        .columns => s.columns = @intFromFloat(std.math.clamp(f, 0, 64)),
        .z_index => s.z_index = @intFromFloat(std.math.clamp(f, -30000, 30000)),
        .direction => s.direction = @enumFromInt(choice),
        .justify => s.justify = @enumFromInt(choice),
        .align_items => s.align_items = @enumFromInt(choice),
        .wrap => s.wrap = choice == 1,
        .overflow => s.overflow = @enumFromInt(choice),
        .rtl => s.rtl = switch (choice) {
            0 => null,
            1 => false,
            else => true,
        },
        .text => if (textSlot(element)) |slot| {
            slot.* = value.text;
        },
        .text_size => switch (element.paint_kind) {
            .text => |*t| t.size = std.math.clamp(f, 4, 200),
            else => {},
        },
        // display: none — nothing painted, no size, children dropped.
        .hidden => if (choice == 1) {
            s.width = 0;
            s.height = 0;
            s.min_width = 0;
            s.min_height = 0;
            s.padding = .{};
            element.paint_kind = .none;
            element.children = &.{};
        },
    }
}

pub const Devtools = struct {
    /// Pick mode: hovering the page highlights, clicking selects.
    inspecting: bool = false,
    selected: u64 = 0,
    /// Page element under the pointer while inspecting.
    hovered: u64 = 0,
    pointer: ?[2]f32 = null,
    /// A click on the page while inspecting, resolved on the next `panel`.
    pick: ?[2]f32 = null,
    /// Rows start expanded, so every element is listed; this holds the folded ones.
    collapsed: std.AutoHashMapUnmanaged(u64, void) = .empty,
    collapse_all: bool = false,
    overrides: std.AutoHashMapUnmanaged(u64, Override) = .empty,
    /// Property field being typed into, and its text.
    editing: ?Prop = null,
    edit: @import("text_edit.zig").TextEdit(128) = @import("text_edit.zig").TextEdit(128).init("") catch unreachable,
    /// What the selected element's fields showed last frame, for starting edits between frames.
    shown: [prop_count][128]u8 = undefined,
    shown_len: [prop_count]u8 = @splat(0),
    shown_choice: [prop_count]u8 = @splat(0),
    rows: [max_rows]u64 = undefined,
    row_count: usize = 0,
    tree_scroll: L.ScrollState = .{},
    details_scroll: L.ScrollState = .{},
    console_scroll: L.ScrollState = .{ .auto_scroll = true },
    frames: [120]f32 = @splat(0),
    frame_head: usize = 0,
    frame_count: usize = 0,
    /// Vertices the app drew last frame (for Performance).
    vertices: usize = 0,
    lines: [console_lines][line_bytes]u8 = undefined,
    line_lens: [console_lines]u8 = @splat(0),
    line_levels: [console_lines]Level = @splat(.info),
    line_head: usize = 0,
    line_count: usize = 0,
    /// Page tree of the frame being built; valid until the frame's `highlight`.
    page: ?*const L.Element = null,
    scroll_to_selected: bool = false,

    pub fn deinit(self: *Devtools, gpa: std.mem.Allocator) void {
        self.clearEdits(gpa);
        self.overrides.deinit(gpa);
        self.collapsed.deinit(gpa);
    }

    pub fn recordFrame(self: *Devtools, milliseconds: f32) void {
        self.frames[self.frame_head] = milliseconds;
        self.frame_head = (self.frame_head + 1) % self.frames.len;
        self.frame_count = @min(self.frame_count + 1, self.frames.len);
    }

    pub fn log(self: *Devtools, level: Level, comptime fmt: []const u8, args: anytype) void {
        const slot = (self.line_head + self.line_count) % console_lines;
        const text = std.fmt.bufPrint(&self.lines[slot], fmt, args) catch self.lines[slot][0..];
        self.line_lens[slot] = @intCast(@min(text.len, 255));
        self.line_levels[slot] = level;
        if (self.line_count == console_lines) self.line_head = (self.line_head + 1) % console_lines else self.line_count += 1;
    }

    /// Re-apply property edits to a freshly built page; true when anything changed, in which case
    /// lay the page out again. Edits apply even while the panel is closed, like an unreloaded page.
    pub fn apply(self: *const Devtools, page: *L.Element) bool {
        if (self.overrides.count() == 0) return false;
        return self.applyAt(page, root_path);
    }
    fn applyAt(self: *const Devtools, element: *L.Element, path: u64) bool {
        var changed = false;
        if (self.overrides.get(path)) |edits| {
            for (edits.values, 0..) |value, i| if (value) |v| {
                applyValue(element, @enumFromInt(i), v);
                changed = true;
            };
        }
        for (element.children, 0..) |child, i| changed = self.applyAt(child, childPath(path, i)) or changed;
        return changed;
    }

    fn setOverride(self: *Devtools, gpa: std.mem.Allocator, prop: Prop, value: Value) !void {
        const entry = try self.overrides.getOrPut(gpa, self.selected);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const slot = &entry.value_ptr.values[@intFromEnum(prop)];
        if (slot.*) |old| if (old == .text) gpa.free(old.text);
        slot.* = value;
    }
    fn resetSelected(self: *Devtools, gpa: std.mem.Allocator) void {
        const removed = self.overrides.fetchRemove(self.selected) orelse return;
        for (removed.value.values) |value| if (value) |v| if (v == .text) gpa.free(v.text);
    }
    fn clearEdits(self: *Devtools, gpa: std.mem.Allocator) void {
        var it = self.overrides.valueIterator();
        while (it.next()) |edits| for (edits.values) |value| if (value) |v| if (v == .text) gpa.free(v.text);
        self.overrides.clearRetainingCapacity();
    }

    /// Whether `id` is a typed property field (number, size or text).
    pub fn isField(self: *const Devtools, id: u32) bool {
        _ = self;
        if (id < prop_first or id >= prop_first + prop_count) return false;
        return (@as(Prop, @enumFromInt(id - prop_first))).kind() != .choice;
    }
    fn begin(self: *Devtools, prop: Prop) void {
        self.editing = prop;
        const i = @intFromEnum(prop);
        self.edit.set(self.shown[i][0..self.shown_len[i]]) catch self.edit.set("") catch unreachable;
        self.edit.selectAll();
    }
    /// Type into a property field; begins editing it with its current value.
    pub fn insertText(self: *Devtools, id: u32, text: []const u8) bool {
        if (!self.isField(id)) return false;
        const prop: Prop = @enumFromInt(id - prop_first);
        if (self.editing != prop) self.begin(prop);
        _ = self.edit.insertFitting(text) catch {};
        return true;
    }
    pub fn editKey(self: *Devtools, gpa: std.mem.Allocator, id: u32, key: EditKey, extend: bool, word: bool) bool {
        if (!self.isField(id)) return false;
        const prop: Prop = @enumFromInt(id - prop_first);
        if (key == .up or key == .down) {
            // Chrome-style stepping: 1, or 10 with Shift.
            if (prop.kind() == .text) return false;
            if (self.editing != prop) self.begin(prop);
            const current = std.fmt.parseFloat(f32, std.mem.trim(u8, self.edit.text(), " px")) catch 0;
            const step: f32 = if (extend) 10 else 1;
            var buffer: [32]u8 = undefined;
            self.edit.set(std.fmt.bufPrint(&buffer, "{d}", .{current + if (key == .up) step else -step}) catch "0") catch {};
            _ = self.commit(gpa, id);
            return true;
        }
        if (self.editing != prop) self.begin(prop);
        switch (key) {
            .left => self.edit.moveLeft(extend, word),
            .right => self.edit.moveRight(extend, word),
            .home => self.edit.moveHome(extend),
            .end => self.edit.moveEnd(extend),
            .backspace => self.edit.backspace(),
            .delete => self.edit.delete(),
            .select_all => self.edit.selectAll(),
            .up, .down => unreachable,
        }
        return true;
    }
    /// Enter: parse the field's text into an edit. Invalid numbers are rejected and logged.
    pub fn commit(self: *Devtools, gpa: std.mem.Allocator, id: u32) bool {
        if (!self.isField(id) or self.selected == 0) return false;
        const prop: Prop = @enumFromInt(id - prop_first);
        if (self.editing != prop) return true;
        self.editing = null;
        const typed = std.mem.trim(u8, self.edit.text(), " ");
        const value: Value = switch (prop.kind()) {
            .text => .{ .text = gpa.dupe(u8, self.edit.text()) catch return true },
            .size, .number => if (prop.kind() == .size and std.ascii.eqlIgnoreCase(typed, "auto"))
                .auto
            else
                .{ .number = std.fmt.parseFloat(f32, std.mem.trimEnd(u8, typed, "px ")) catch {
                    self.log(.warn, "{s}: \"{s}\" is not a number", .{ prop.name(), typed });
                    return true;
                } },
            .choice => unreachable,
        };
        if (value == .number and !std.math.isFinite(value.number)) return true;
        self.setOverride(gpa, prop, value) catch {};
        return true;
    }
    /// Focus left the field: apply what was typed, as Chrome does on blur.
    pub fn blur(self: *Devtools, gpa: std.mem.Allocator) void {
        if (self.editing) |prop| _ = self.commit(gpa, prop_first + @intFromEnum(prop));
    }
    /// Escape while editing: drop the typed text. Returns whether an edit was open.
    pub fn cancel(self: *Devtools) bool {
        if (self.editing == null) return false;
        self.editing = null;
        return true;
    }

    /// Handle a press on a panel id; false when `id` is not the panel's.
    pub fn activate(self: *Devtools, gpa: std.mem.Allocator, id: u32) bool {
        if (id < first_id) return false;
        switch (id) {
            inspect_id => self.inspecting = !self.inspecting,
            clear_id => {
                self.line_count = 0;
                self.line_head = 0;
            },
            reset_id => self.resetSelected(gpa),
            clear_edits_id => self.clearEdits(gpa),
            expand_all_id => {
                self.collapsed.clearRetainingCapacity();
                self.collapse_all = false;
            },
            collapse_all_id => {
                self.collapsed.clearRetainingCapacity();
                self.collapse_all = true;
            },
            prop_first...prop_first + prop_count - 1 => {
                const prop: Prop = @enumFromInt(id - prop_first);
                if (prop.kind() != .choice) {
                    if (self.editing != prop) self.begin(prop);
                } else if (self.selected != 0) {
                    const next = (self.shown_choice[@intFromEnum(prop)] + 1) % @as(u8, @intCast(prop.choices().len));
                    self.setOverride(gpa, prop, .{ .choice = next }) catch {};
                }
            },
            row_first...row_first + max_rows - 1 => {
                const index = id - row_first;
                if (index < self.row_count and self.rows[index] != self.selected) {
                    self.selected = self.rows[index];
                    self.editing = null;
                }
            },
            chevron_first...chevron_first + max_rows - 1 => {
                const index = id - chevron_first;
                if (index >= self.row_count) return true;
                const path = self.rows[index];
                // With collapse-all on, the set lists the rows opened instead.
                if (self.collapsed.contains(path)) _ = self.collapsed.remove(path) else self.collapsed.put(gpa, path, {}) catch {};
            },
            else => {},
        }
        return true;
    }
    /// Tree rows other than the selected one stay out of Tab order (arrow keys walk the tree).
    pub fn skipInTabOrder(self: *const Devtools, id: u32) bool {
        if (id >= chevron_first and id < chevron_first + max_rows) return true;
        if (id < row_first or id >= row_first + max_rows) return false;
        const index = id - row_first;
        if (index >= self.row_count) return true;
        // With nothing selected the first row is the tree's tab stop.
        return if (self.selected == 0) index != 0 else self.rows[index] != self.selected;
    }
    /// Arrow keys on a tree row: up/down select a neighbour (returning its id to focus),
    /// right expands, left collapses.
    pub fn treeKey(self: *Devtools, gpa: std.mem.Allocator, id: u32, key: EditKey) ?u32 {
        if (id < row_first or id >= row_first + max_rows) return null;
        const index = id - row_first;
        if (index >= self.row_count) return null;
        const path = self.rows[index];
        switch (key) {
            .up, .down => {
                const next = if (key == .up) index -| 1 else @min(self.row_count - 1, index + 1);
                self.selected = self.rows[next];
                self.editing = null;
                return row_first + @as(u32, @intCast(next));
            },
            .left, .right => {
                if ((key == .right) != self.isOpen(path)) {
                    if (self.collapsed.contains(path)) _ = self.collapsed.remove(path) else self.collapsed.put(gpa, path, {}) catch {};
                }
                return id;
            },
            else => return null,
        }
    }
    fn isOpen(self: *const Devtools, path: u64) bool {
        return self.collapsed.contains(path) == self.collapse_all;
    }

    /// Page pointer while inspecting (moves highlight) — call from pointer motion.
    pub fn pointerMove(self: *Devtools, x: f32, y: f32) void {
        self.pointer = if (self.inspecting) .{ x, y } else null;
    }
    /// A page click while inspecting selects the element there; returns whether it was consumed.
    pub fn pointerDown(self: *Devtools, x: f32, y: f32) bool {
        if (!self.inspecting) return false;
        self.pick = .{ x, y };
        return true;
    }

    /// Inspect `page` (already laid out) this frame: resolve the pointer and any pick against it.
    /// Call before `view`, and keep `page` alive until `highlight`.
    pub fn prepare(self: *Devtools, gpa: std.mem.Allocator, page: *const L.Element) !void {
        self.page = page;
        self.hovered = 0;
        if (self.pointer) |p| self.hovered = pathAt(page, root_path, p[0], p[1]) orelse 0;
        const p = self.pick orelse return;
        self.pick = null;
        self.inspecting = false;
        const path = pathAt(page, root_path, p[0], p[1]) orelse return;
        self.selected = path;
        self.editing = null;
        var trail: std.ArrayList(u64) = .empty;
        defer trail.deinit(gpa);
        _ = try find(page, root_path, path, &trail, gpa);
        for (trail.items) |ancestor| if (!self.isOpen(ancestor)) {
            if (self.collapsed.contains(ancestor)) _ = self.collapsed.remove(ancestor) else try self.collapsed.put(gpa, ancestor, {});
        };
        self.scroll_to_selected = true;
    }

    /// One tool, sized to `area`, for the page given to `prepare`.
    pub fn view(self: *Devtools, b: L.Builder, gpa: std.mem.Allocator, tool: Tool, area: Rect) !*L.Element {
        const page = self.page orelse return error.NotPrepared;
        const body = switch (tool) {
            .elements => try self.elements(b, gpa, page, area.w, area.h),
            .performance => try self.performance(b, page, area.w),
            .console => try self.consoleView(b, area.w, area.h),
        };
        const result = try b.node(view_id + @intFromEnum(tool), .{ .width = area.w, .height = area.h }, .none, &.{body});
        result.accessibility = .{ .role = .region, .label = switch (tool) {
            .elements => "Elements",
            .performance => "Performance",
            .console => "Console",
        } };
        return result;
    }

    fn elements(self: *Devtools, b: L.Builder, gpa: std.mem.Allocator, page: *const L.Element, w: f32, h: f32) !*L.Element {
        var rows: std.ArrayList(*L.Element) = .empty;
        self.row_count = 0;
        try self.treeRows(b, &rows, page, root_path, 0);
        // Tree beside the styles when the panel is wide, above them when it is tall.
        const stacked = w < h * 1.2;
        const tree_w = if (stacked) w else w * 0.5;
        const tree_h = if (stacked) h * 0.5 else h;
        if (self.scroll_to_selected) {
            self.scroll_to_selected = false;
            if (std.mem.indexOfScalar(u64, self.rows[0..self.row_count], self.selected)) |index| {
                self.tree_scroll.offset.y = @max(0, @as(f32, @floatFromInt(index)) * 22 - tree_h / 2);
            }
        }
        const tree_tools = try b.node(0, .{ .direction = .row, .height = 28, .gap = 4, .align_items = .center, .padding = .{ .left = 4, .right = 6 } }, .none, &.{
            try b.node(inspect_id, .{ .height = 24 }, .{ .toggle_button = .{ .label = "Inspect", .pressed = self.inspecting } }, &.{}),
            try b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = try std.fmt.allocPrint(b.allocator, "{d} elements", .{count(page)}), .size = 12, .tone = .muted } }, &.{}),
            try b.node(expand_all_id, .{ .height = 24 }, .{ .button = .{ .label = "Expand all", .variant = .ghost } }, &.{}),
            try b.node(collapse_all_id, .{ .height = 24 }, .{ .button = .{ .label = "Collapse all", .variant = .ghost } }, &.{}),
        });
        const tree = try @import("widgets.zig").scrollArea(b, .{ .x = 0, .y = 0, .w = tree_w, .h = @max(24, tree_h - 29) }, &self.tree_scroll, &.{try b.node(0, .{ .padding = .{ .top = 2, .bottom = 4 } }, .none, rows.items)});
        var trail: std.ArrayList(u64) = .empty;
        defer trail.deinit(gpa);
        const chosen = if (self.selected != 0) try find(page, root_path, self.selected, &trail, gpa) else null;
        const details_w = if (stacked) w else w - tree_w - 1;
        const details_h = if (stacked) h - tree_h - 1 else h;
        const details = try @import("widgets.zig").scrollArea(b, .{ .x = 0, .y = 0, .w = details_w, .h = @max(24, details_h) }, &self.details_scroll, &.{if (chosen) |element| try self.styles(b, element) else try b.node(0, .{ .padding = .{ .left = 12, .top = 12, .right = 12 } }, .{ .text = .{ .value = "Select an element, or press Inspect and click the page.", .size = 12, .tone = .muted, .wrap = true } }, &.{})});
        const left = try b.node(0, .{ .width = tree_w }, .none, &.{ tree_tools, try b.separator(), tree });
        const divider = try b.node(0, if (stacked) .{ .height = 1 } else .{ .width = 1 }, .separator, &.{});
        return b.node(0, .{ .direction = if (stacked) .column else .row }, .none, &.{ left, divider, details });
    }

    fn treeRows(self: *Devtools, b: L.Builder, rows: *std.ArrayList(*L.Element), element: *const L.Element, path: u64, depth: usize) !void {
        if (self.row_count == max_rows) return;
        const open = self.isOpen(path);
        var tag_buffer: [48]u8 = undefined;
        const tag = tagName(&tag_buffer, element);
        const text = textOf(element);
        const shown = text[0..@min(text.len, 32)];
        const label = try std.fmt.allocPrint(b.allocator, "<{s}>{s}{s}{s}{s}{s}", .{
            tag,
            if (element.id != 0 and element.id < first_id) try std.fmt.allocPrint(b.allocator, " #{d}", .{element.id}) else "",
            if (shown.len > 0) "  \"" else "",
            shown,
            if (shown.len > 0) (if (text.len > shown.len) "...\"" else "\"") else "",
            if (self.overrides.contains(path)) "  (edited)" else "",
        });
        const index = self.row_count;
        self.rows[index] = path;
        self.row_count += 1;
        const chevron = if (element.children.len == 0)
            try b.node(0, .{ .width = 16, .height = 16 }, .none, &.{})
        else blk: {
            const toggle_node = try b.node(chevron_first + @as(u32, @intCast(index)), .{ .width = 16, .height = 16 }, .{ .icon = if (open) .chevron_down else .chevron_right }, &.{});
            toggle_node.accessibility = .{ .role = .button, .label = if (open) "Collapse" else "Expand", .expanded = open };
            break :blk toggle_node;
        };
        const row = try b.node(row_first + @as(u32, @intCast(index)), .{ .direction = .row, .height = 22, .gap = 4, .align_items = .center, .padding = .{ .left = 4 + @as(f32, @floatFromInt(depth)) * 12, .right = 6 } }, if (path == self.selected) .{ .surface = .track } else .hover, &.{
            chevron,
            try b.node(0, .{ .grow = 1, .height = 22 }, .{ .text = .{ .value = label, .size = 12 } }, &.{}),
        });
        row.accessibility = .{ .role = .button, .label = label };
        try rows.append(b.allocator, row);
        if (!open) return;
        for (element.children, 0..) |child, i| try self.treeRows(b, rows, child, childPath(path, i), depth + 1);
    }

    /// Styles pane: every editable property as a field, then the box model and read-only facts.
    fn styles(self: *Devtools, b: L.Builder, element: *const L.Element) !*L.Element {
        var fields: std.ArrayList(*L.Element) = .empty;
        const edits = self.overrides.get(self.selected);
        inline for (@typeInfo(Prop).@"enum".fields) |field| {
            const prop: Prop = @enumFromInt(field.value);
            const i = field.value;
            var buffer: [128]u8 = undefined;
            const current = if (edits != null and edits.?.values[i] != null and prop == .hidden) "true" else describe(&buffer, element, prop);
            // Remember what was shown so edits can start from it between frames.
            const len = @min(current.len, 127);
            @memcpy(self.shown[i][0..len], current[0..len]);
            self.shown_len[i] = @intCast(len);
            if (prop.kind() == .choice) self.shown_choice[i] = for (prop.choices(), 0..) |choice, c| {
                if (std.mem.eql(u8, choice, current)) break @intCast(c);
            } else 0;
            if (applies(element, prop)) {
                const edited = edits != null and edits.?.values[i] != null;
                const id = prop_first + @as(u32, i);
                const control = if (prop.kind() == .choice)
                    try b.node(id, .{ .height = 24, .grow = 1 }, .{ .button = .{ .label = try b.allocator.dupe(u8, current), .variant = .outline } }, &.{})
                else if (self.editing == prop)
                    try b.node(id, .{ .height = 26, .grow = 1 }, .{ .input = .{ .value = try b.allocator.dupe(u8, self.edit.text()), .focused = true, .cursor = self.edit.cursor, .selection = self.edit.selection() } }, &.{})
                else
                    try b.node(id, .{ .height = 26, .grow = 1 }, .{ .input = .{ .value = try b.allocator.dupe(u8, current) } }, &.{});
                control.accessibility.label = prop.name();
                try fields.append(b.allocator, try b.node(0, .{ .direction = .row, .gap = 8, .align_items = .center }, .none, &.{
                    try b.node(0, .{ .width = 104 }, .{ .text = .{ .value = if (edited) try std.fmt.allocPrint(b.allocator, "{s} *", .{prop.name()}) else prop.name(), .size = 12, .tone = if (edited) .foreground else .muted } }, &.{}),
                    control,
                }));
            }
        }
        var tag_buffer: [48]u8 = undefined;
        const heading = try std.fmt.allocPrint(b.allocator, "<{s}>{s}", .{ tagName(&tag_buffer, element), if (element.id != 0 and element.id < first_id) try std.fmt.allocPrint(b.allocator, " #{d}", .{element.id}) else "" });
        const actions = try b.node(0, .{ .direction = .row, .gap = 6, .align_items = .center }, .none, &.{
            try b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = heading, .size = 13 } }, &.{}),
            try b.node(reset_id, .{ .height = 24 }, .{ .button = .{ .label = "Reset", .variant = .ghost } }, &.{}),
            try b.node(clear_edits_id, .{ .height = 24 }, .{ .button = .{ .label = "Clear all edits", .variant = .ghost } }, &.{}),
        });
        return b.node(0, .{ .gap = 10, .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 12 } }, .none, &.{
            actions,
            try caption(b, "Styles  (click a value to type, Enter to apply, arrows to step)"),
            try b.node(0, .{ .gap = 4 }, .none, fields.items),
            try caption(b, "Box model"),
            try boxModel(b, element),
            try caption(b, "Computed"),
            try facts(b, element),
        });
    }

    fn performance(self: *Devtools, b: L.Builder, page: *const L.Element, w: f32) !*L.Element {
        // The chart keeps a slice until the frame is drawn, so the samples live in the frame arena.
        const n = @min(self.frame_count, 60);
        const values = try b.allocator.alloc(f32, n);
        var total: f32 = 0;
        var worst: f32 = 0;
        for (0..n) |i| {
            const v = self.frames[(self.frame_head + self.frames.len - n + i) % self.frames.len];
            values[i] = @max(0, v);
            total += v;
            worst = @max(worst, v);
        }
        const average = if (n > 0) total / @as(f32, @floatFromInt(n)) else 0;
        const stat = struct {
            fn make(builder: L.Builder, name: []const u8, value: []const u8) !*L.Element {
                return builder.node(0, .{ .gap = 2, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 } }, .{ .surface = .card }, &.{
                    try builder.node(0, .{}, .{ .text = .{ .value = name, .size = 12, .tone = .muted } }, &.{}),
                    try builder.node(0, .{}, .{ .text = .{ .value = value, .size = 18 } }, &.{}),
                });
            }
        }.make;
        const chart = if (n > 0) try b.chart(values) else try b.node(0, .{ .height = 120 }, .none, &.{});
        chart.style.height = 120;
        chart.accessibility.label = "Frame times";
        return b.node(0, .{ .gap = 10, .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 } }, .none, &.{
            try b.node(0, .{ .columns = if (w >= 360) 3 else 2, .gap = 8 }, .none, &.{
                try stat(b, "FPS", try std.fmt.allocPrint(b.allocator, "{d:.0}", .{if (average > 0) 1000 / average else 0})),
                try stat(b, "Frame (avg)", try std.fmt.allocPrint(b.allocator, "{d:.2} ms", .{average})),
                try stat(b, "Frame (worst)", try std.fmt.allocPrint(b.allocator, "{d:.2} ms", .{worst})),
                try stat(b, "Vertices", try std.fmt.allocPrint(b.allocator, "{d}", .{self.vertices})),
                try stat(b, "Elements", try std.fmt.allocPrint(b.allocator, "{d}", .{count(page)})),
                try stat(b, "Tree rows", try std.fmt.allocPrint(b.allocator, "{d}", .{self.row_count})),
            }),
            try b.node(0, .{}, .{ .text = .{ .value = "Frame times, last 60 frames", .size = 12, .tone = .muted } }, &.{}),
            chart,
        });
    }

    fn consoleView(self: *Devtools, b: L.Builder, w: f32, h: f32) !*L.Element {
        const entries = try b.allocator.alloc(*L.Element, self.line_count);
        for (entries, 0..) |*entry, i| {
            const slot = (self.line_head + i) % console_lines;
            const level = self.line_levels[slot];
            entry.* = try b.node(0, .{ .direction = .row, .gap = 8, .padding = .{ .left = 10, .right = 10, .top = 3, .bottom = 3 } }, .none, &.{
                try b.node(0, .{ .width = 36 }, .{ .text = .{ .value = @tagName(level), .size = 12, .tone = if (level == .info) .muted else .foreground } }, &.{}),
                try b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = self.lines[slot][0..self.line_lens[slot]], .size = 12, .wrap = true } }, &.{}),
            });
        }
        const bar = try b.node(0, .{ .direction = .row, .height = 32, .gap = 8, .align_items = .center, .padding = .{ .left = 8, .right = 8 } }, .none, &.{
            try b.node(clear_id, .{ .height = 26 }, .{ .button = .{ .label = "Clear", .variant = .ghost } }, &.{}),
            try b.node(0, .{}, .{ .text = .{ .value = try std.fmt.allocPrint(b.allocator, "{d} messages", .{self.line_count}), .size = 12, .tone = .muted } }, &.{}),
        });
        const log_area = try @import("widgets.zig").messageScroller(b, .{ .x = 0, .y = 0, .w = w, .h = @max(24, h - 33) }, &self.console_scroll, entries);
        return b.node(0, .{}, .none, &.{ bar, try b.separator(), log_area });
    }

    /// Chrome-style overlay for the row or page element under the pointer (else the selection):
    /// blue content, green padding, and a size label. Call after drawing the page and panel.
    pub fn highlight(self: *Devtools, c: *Canvas, gpa: std.mem.Allocator) !void {
        defer self.page = null;
        const page = self.page orelse return;
        const target = if (c.hot_id >= row_first and c.hot_id < row_first + self.row_count)
            self.rows[c.hot_id - row_first]
        else if (self.hovered != 0) self.hovered else self.selected;
        if (target == 0) return;
        var trail: std.ArrayList(u64) = .empty;
        defer trail.deinit(gpa);
        const element = (try find(page, root_path, target, &trail, gpa)) orelse return;
        const previous = c.clip;
        c.clip = element.clip;
        defer c.clip = previous;
        const r = element.bounds;
        const p = element.style.padding;
        const content = Rect{ .x = r.x + p.left, .y = r.y + p.top, .w = @max(0, r.w - p.left - p.right), .h = @max(0, r.h - p.top - p.bottom) };
        const green = types.rgb(0x93, 0xC4, 0x7D);
        try c.rectAlpha(.{ .x = r.x, .y = r.y, .w = r.w, .h = p.top }, green, 0.55);
        try c.rectAlpha(.{ .x = r.x, .y = r.y + r.h - p.bottom, .w = r.w, .h = p.bottom }, green, 0.55);
        try c.rectAlpha(.{ .x = r.x, .y = content.y, .w = p.left, .h = content.h }, green, 0.55);
        try c.rectAlpha(.{ .x = r.x + r.w - p.right, .y = content.y, .w = p.right, .h = content.h }, green, 0.55);
        try c.rectAlpha(content, types.rgb(0x6F, 0xA8, 0xDC), 0.55);
        c.clip = null;
        var tag_buffer: [48]u8 = undefined;
        var label_buffer: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "{s}  {d:.0} x {d:.0}", .{ tagName(&tag_buffer, element), r.w, r.h }) catch return;
        const width = c.font.measure(label, 12) + 16;
        // Above the element, else below it, else just inside its top edge.
        const visible = element.clip;
        const y = if (r.y - 26 >= visible.y) r.y - 26 else if (r.y + r.h + 26 <= visible.y + visible.h) r.y + r.h + 4 else @max(visible.y, r.y) + 4;
        const tip = Rect{ .x = @max(visible.x, r.x), .y = y, .w = width, .h = 22 };
        try c.roundRect(tip, types.rgb(0x20, 0x21, 0x24), 4);
        try c.textIn(tip.inset(8), label, 12, .{ 0.93, 0.93, 0.93 }, .start);
    }
};

fn caption(b: L.Builder, text: []const u8) !*L.Element {
    return b.node(0, .{}, .{ .text = .{ .value = text, .size = 12, .tone = .muted, .wrap = true } }, &.{});
}

/// Chrome's nested padding/content boxes with their sizes.
fn boxModel(b: L.Builder, element: *const L.Element) !*L.Element {
    const p = element.style.padding;
    const r = element.bounds;
    const number = struct {
        fn node(builder: L.Builder, value: f32) !*L.Element {
            return builder.node(0, .{ .width = 28 }, .{ .text = .{ .value = try std.fmt.allocPrint(builder.allocator, "{d:.0}", .{value}), .size = 12, .tone = .muted, .alignment = .center } }, &.{});
        }
    }.node;
    const content = try b.node(0, .{ .grow = 1, .height = 30 }, .{ .surface = .card }, &.{
        try b.node(0, .{ .height = 30 }, .{ .text = .{ .value = try std.fmt.allocPrint(b.allocator, "{d:.0} x {d:.0}", .{ @max(0, r.w - p.left - p.right), @max(0, r.h - p.top - p.bottom) }), .size = 12, .alignment = .center } }, &.{}),
    });
    return b.node(0, .{ .gap = 2, .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 6 } }, .{ .surface = .track }, &.{
        try b.node(0, .{ .direction = .row }, .none, &.{ try caption(b, "padding"), try b.node(0, .{ .grow = 1 }, .none, &.{}), try number(b, p.top), try b.node(0, .{ .grow = 1 }, .none, &.{}), try b.node(0, .{ .width = 44 }, .none, &.{}) }),
        try b.node(0, .{ .direction = .row, .gap = 6, .align_items = .center }, .none, &.{ try number(b, p.left), content, try number(b, p.right) }),
        try b.node(0, .{ .direction = .row, .justify = .center }, .none, &.{try number(b, p.bottom)}),
    });
}

/// Read-only facts: where the element ended up and what assistive technology sees.
fn facts(b: L.Builder, element: *const L.Element) !*L.Element {
    var lines: std.ArrayList(*L.Element) = .empty;
    const add = struct {
        fn line(builder: L.Builder, list: *std.ArrayList(*L.Element), name: []const u8, value: []const u8) !void {
            try list.append(builder.allocator, try builder.node(0, .{ .direction = .row, .gap = 8 }, .none, &.{
                try builder.node(0, .{ .width = 104 }, .{ .text = .{ .value = name, .size = 12, .tone = .muted } }, &.{}),
                try builder.node(0, .{ .grow = 1 }, .{ .text = .{ .value = value, .size = 12, .wrap = true } }, &.{}),
            }));
        }
    }.line;
    const r = element.bounds;
    try add(b, &lines, "position", try std.fmt.allocPrint(b.allocator, "{d:.0}, {d:.0}", .{ r.x, r.y }));
    try add(b, &lines, "size", try std.fmt.allocPrint(b.allocator, "{d:.0} x {d:.0}", .{ r.w, r.h }));
    try add(b, &lines, "direction", if (element.rtl) "rtl" else "ltr");
    try add(b, &lines, "role", if (element.accessibility.role) |role| @tagName(role) else "(from paint)");
    try add(b, &lines, "name", element.accessibility.label orelse textOf(element));
    try add(b, &lines, "actionable", if (element.actionable()) "yes" else "no");
    return b.node(0, .{ .gap = 4 }, .none, lines.items);
}

/// Console sink for `logFn`; point it at the app's `Devtools`.
pub var console: ?*Devtools = null;

/// `std.Options.logFn` that also shows info, warnings and errors in the DevTools console.
pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    std.log.defaultLog(level, scope, format, args);
    const sink = console orelse return;
    const mapped: Level = switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => return,
    };
    sink.log(mapped, format, args);
}

fn showElements(tools: *Devtools, b: L.Builder, font: *const Font, page: *const L.Element, area: Rect) !*L.Element {
    _ = font;
    try tools.prepare(std.testing.allocator, page);
    return tools.view(b, std.testing.allocator, .elements, area);
}

test "every element is listed, picks select the deepest one, and the console wraps" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const button = try b.button(7, "Save");
    const page = try b.node(0, .{ .width = 400, .height = 300, .padding = .{ .left = 10, .top = 10 } }, .none, &.{ try b.text("Title"), try b.node(0, .{ .direction = .row }, .none, &.{button}) });
    page.layout(.{ .x = 0, .y = 0, .w = 400, .h = 300 }, &font);
    var tools = Devtools{};
    defer tools.deinit(std.testing.allocator);
    const area = Rect{ .x = 400, .y = 0, .w = 380, .h = 300 };
    const built = try showElements(&tools, b, &font, page, area);
    try std.testing.expectEqual(@as(usize, 4), tools.row_count); // root, text, row, button
    built.layout(area, &font);
    try std.testing.expect(built.find(inspect_id) != null);
    try std.testing.expect(tools.activate(std.testing.allocator, chevron_first + 2)); // fold the row
    _ = try showElements(&tools, b, &font, page, area);
    try std.testing.expectEqual(@as(usize, 3), tools.row_count);
    tools.inspecting = true;
    try std.testing.expect(tools.pointerDown(button.bounds.center().x, button.bounds.center().y));
    _ = try showElements(&tools, b, &font, page, area);
    try std.testing.expect(!tools.inspecting);
    try std.testing.expectEqual(@as(usize, 4), tools.row_count); // the pick unfolded the row again
    try std.testing.expectEqual(tools.rows[3], tools.selected);
    try std.testing.expect(tools.activate(std.testing.allocator, collapse_all_id));
    _ = try showElements(&tools, b, &font, page, area);
    try std.testing.expectEqual(@as(usize, 1), tools.row_count);
    try std.testing.expect(!tools.activate(std.testing.allocator, 12));
    for (0..console_lines + 5) |i| tools.log(.info, "line {d}", .{i});
    try std.testing.expectEqual(@as(usize, console_lines), tools.line_count);
    try std.testing.expectEqualStrings("line 5", tools.lines[tools.line_head][0..tools.line_lens[tools.line_head]]);
    var vertices: [8192]types.Vertex = undefined;
    var canvas = Canvas.init(&vertices, &font);
    try tools.highlight(&canvas, std.testing.allocator);
    try std.testing.expect(canvas.len > 0);
}

test "property edits persist across rebuilds and can be stepped, cycled, typed and reset" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var tools = Devtools{};
    defer tools.deinit(std.testing.allocator);
    const area = Rect{ .x = 400, .y = 0, .w = 380, .h = 600 };
    // A tiny immediate-mode app: the page is rebuilt from scratch every frame.
    const Frame = struct {
        arena: std.heap.ArenaAllocator,
        fn build(self: *@This(), f: *const Font, t: *Devtools) !*L.Element {
            _ = self.arena.reset(.retain_capacity);
            const b = L.Builder{ .allocator = self.arena.allocator() };
            const page = try b.node(0, .{ .width = 400, .height = 300 }, .none, &.{ try b.text("Title"), try b.button(7, "Save") });
            page.layout(.{ .x = 0, .y = 0, .w = 400, .h = 300 }, f);
            if (t.apply(page)) page.layout(.{ .x = 0, .y = 0, .w = 400, .h = 300 }, f);
            _ = try showElements(t, b, f, page, .{ .x = 400, .y = 0, .w = 380, .h = 600 });
            return page;
        }
    };
    _ = area;
    var frame = Frame{ .arena = .init(std.testing.allocator) };
    defer frame.arena.deinit();
    var page = try frame.build(&font, &tools);
    try std.testing.expect(tools.activate(std.testing.allocator, row_first + 2)); // select the button
    page = try frame.build(&font, &tools);
    const width_id = prop_first + @intFromEnum(Prop.width);
    // Type a width.
    try std.testing.expect(tools.activate(std.testing.allocator, width_id));
    try std.testing.expect(tools.insertText(width_id, "200"));
    try std.testing.expect(tools.commit(std.testing.allocator, width_id));
    page = try frame.build(&font, &tools);
    try std.testing.expectEqual(@as(f32, 200), page.children[1].bounds.w);
    // Step it with the arrow keys (Shift = 10).
    try std.testing.expect(tools.editKey(std.testing.allocator, width_id, .up, true, false));
    page = try frame.build(&font, &tools);
    try std.testing.expectEqual(@as(f32, 210), page.children[1].bounds.w);
    // Edit the label, then cycle a choice.
    const text_id = prop_first + @intFromEnum(Prop.text);
    try std.testing.expect(tools.insertText(text_id, "Ship it"));
    try std.testing.expect(tools.commit(std.testing.allocator, text_id));
    page = try frame.build(&font, &tools);
    try std.testing.expectEqualStrings("Ship it", page.children[1].paint_kind.button.label);
    try std.testing.expect(tools.activate(std.testing.allocator, prop_first + @intFromEnum(Prop.hidden)));
    page = try frame.build(&font, &tools);
    try std.testing.expectEqual(@as(f32, 0), page.children[1].bounds.h); // hidden
    // Bad numbers are refused and logged; "auto" clears a size.
    try std.testing.expect(tools.insertText(width_id, "wide"));
    try std.testing.expect(tools.commit(std.testing.allocator, width_id));
    try std.testing.expect(tools.line_count == 1);
    try std.testing.expect(tools.activate(std.testing.allocator, reset_id));
    page = try frame.build(&font, &tools);
    try std.testing.expectEqual(@as(f32, 120), page.children[1].bounds.w);
    try std.testing.expectEqualStrings("Save", page.children[1].paint_kind.button.label);
    try std.testing.expect(!tools.isField(prop_first + @intFromEnum(Prop.direction)));
}

test "the tree is one tab stop walked with arrow keys" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const page = try b.node(0, .{}, .none, &.{ try b.text("A"), try b.node(0, .{}, .none, &.{try b.text("B")}) });
    page.layout(.{ .x = 0, .y = 0, .w = 300, .h = 200 }, &font);
    var tools = Devtools{};
    defer tools.deinit(std.testing.allocator);
    const area = Rect{ .x = 300, .y = 0, .w = 300, .h = 400 };
    _ = try showElements(&tools, b, &font, page, area);
    try std.testing.expectEqual(@as(usize, 4), tools.row_count);
    tools.selected = tools.rows[0];
    try std.testing.expect(!tools.skipInTabOrder(row_first));
    try std.testing.expect(tools.skipInTabOrder(row_first + 1) and tools.skipInTabOrder(chevron_first));
    try std.testing.expectEqual(@as(?u32, row_first + 1), tools.treeKey(std.testing.allocator, row_first, .down));
    try std.testing.expectEqual(tools.rows[1], tools.selected);
    try std.testing.expectEqual(@as(?u32, row_first + 2), tools.treeKey(std.testing.allocator, row_first + 1, .down));
    _ = tools.treeKey(std.testing.allocator, row_first + 2, .left); // collapse the inner column
    _ = try showElements(&tools, b, &font, page, area);
    try std.testing.expectEqual(@as(usize, 3), tools.row_count);
    _ = tools.treeKey(std.testing.allocator, row_first + 2, .right);
    _ = try showElements(&tools, b, &font, page, area);
    try std.testing.expectEqual(@as(usize, 4), tools.row_count);
    try std.testing.expect(tools.treeKey(std.testing.allocator, 5, .down) == null);
}
