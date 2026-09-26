//! Toolkit-independent accessibility snapshot of a laid-out Weeoui tree.
const std = @import("std");
const L = @import("layout.zig");
const Rect = @import("types.zig").Rect;

pub const Role = L.Accessibility.Role;
pub const Node = struct {
    id: u64,
    role: Role,
    bounds: Rect,
    children: []u64,
    label: []const u8 = "",
    description: []const u8 = "",
    value: []const u8 = "",
    numeric_value: ?f32 = null,
    toggled: ?bool = null,
    selected: ?bool = null,
    expanded: ?bool = null,
    modal: bool = false,
    disabled: bool = false,
    invalid: bool = false,
    multiline: bool = false,
    actionable: bool = false,
};
pub const Snapshot = struct {
    nodes: []const Node,
    focus: u64,
};

pub fn collect(allocator: std.mem.Allocator, root: *const L.Element, focus_id: u32) !Snapshot {
    var nodes: std.ArrayList(Node) = .empty;
    var ids = std.AutoHashMap(u32, void).init(allocator);
    defer ids.deinit();
    if (root.id == 0) {
        _ = try append(allocator, &nodes, &ids, root, true);
    } else {
        const children = try allocator.alloc(u64, 1);
        try nodes.append(allocator, .{ .id = 0, .role = .group, .bounds = root.bounds.intersection(root.clip), .children = children });
        children[0] = try append(allocator, &nodes, &ids, root, false);
    }
    if (focus_id != 0 and !ids.contains(focus_id)) return error.UnknownFocus;
    return .{ .nodes = try nodes.toOwnedSlice(allocator), .focus = focus_id };
}

fn append(allocator: std.mem.Allocator, nodes: *std.ArrayList(Node), ids: *std.AutoHashMap(u32, void), element: *const L.Element, is_root: bool) !u64 {
    const id: u64 = if (is_root) 0 else if (element.id != 0) element.id else (@as(u64, 1) << 32) | @as(u64, @intCast(nodes.items.len));
    if (!is_root and element.id != 0) {
        const entry = try ids.getOrPut(element.id);
        if (entry.found_existing) return error.DuplicateId;
    }
    const index = nodes.items.len;
    try nodes.append(allocator, .{
        .id = id,
        .role = element.accessibility.role orelse roleFor(element.paint_kind),
        .bounds = element.bounds.intersection(element.clip),
        .children = try allocator.alloc(u64, element.children.len),
    });
    const children = nodes.items[index].children;
    for (element.children, 0..) |child, i| children[i] = try append(allocator, nodes, ids, child, false);
    var node = &nodes.items[index];
    node.label = try allocator.dupe(u8, element.accessibility.label orelse labelFor(element.paint_kind));
    node.description = try allocator.dupe(u8, element.accessibility.description orelse "");
    if (element.accessibility.numeric_value) |value| {
        if (!std.math.isFinite(value)) return error.InvalidValue;
        node.numeric_value = value;
    }
    node.expanded = element.accessibility.expanded;
    node.modal = element.accessibility.modal;
    node.disabled = element.accessibility.disabled;
    node.actionable = !is_root and element.actionable();
    switch (element.paint_kind) {
        .input => |input| {
            node.value = try allocator.dupe(u8, input.value);
            node.disabled = node.disabled or input.disabled;
            node.invalid = input.invalid;
            node.multiline = input.multiline;
            if (node.label.len == 0) node.label = try allocator.dupe(u8, input.placeholder);
        },
        .checkbox => |value| node.toggled = value.checked,
        .toggle => |value| node.toggled = value.enabled,
        .toggle_button => |value| node.toggled = value.pressed,
        .radio => |value| node.toggled = value.checked,
        .tab => |value| node.selected = value.selected,
        .slider => |value| {
            if (!std.math.isFinite(value.value) or value.value < 0 or value.value > 1) return error.InvalidValue;
            node.numeric_value = value.value;
        },
        .progress => |value| {
            if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidValue;
            node.numeric_value = value;
        },
        .alert => |value| node.description = try allocator.dupe(u8, value.description),
        else => {},
    }
    if (node.role == .radio and element.children.len > 0) switch (element.children[0].paint_kind) {
        .radio => |value| {
            node.toggled = value.checked;
        },
        else => {},
    };
    return id;
}

fn roleFor(paint: L.Paint) Role {
    return switch (paint) {
        .text, .badge => .label,
        .button, .toggle_button => .button,
        .checkbox => .checkbox,
        .toggle => .switch_control,
        .slider => .slider,
        .input => .input,
        .radio => .radio,
        .progress => .progress,
        .tab => .tab,
        .avatar, .bar_chart => .image,
        .alert => .alert,
        .surface => |surface| switch (surface) {
            .menu => .menu,
            .dialog => .dialog,
            else => .group,
        },
        .separator, .scrollbar, .skeleton, .spinner, .icon => .ignored,
        else => .group,
    };
}

fn labelFor(paint: L.Paint) []const u8 {
    return switch (paint) {
        .text => |value| value.value,
        .badge, .avatar => |value| value,
        .button => |value| value.label,
        .checkbox => |value| value.label,
        .toggle => |value| value.label,
        .toggle_button => |value| value.label,
        .tab => |value| value.label,
        .alert => |value| value.title,
        else => "",
    };
}

test "snapshot maps role, focus, state, clipping and custom semantics" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const checkbox = try b.node(7, .{ .height = 32 }, .{ .checkbox = .{ .label = "Agreed", .checked = true } }, &.{});
    checkbox.accessibility.description = "Required to proceed";
    const input = try b.input(8, .{ .value = "Text", .invalid = true });
    input.accessibility.label = "Display name";
    const root = try b.node(0, .{ .height = 60 }, .none, &.{ checkbox, input });
    root.layout(.{ .x = 0, .y = 0, .w = 200, .h = 60 }, &font);
    const snapshot = try collect(arena.allocator(), root, 8);
    try std.testing.expectEqual(@as(u64, 8), snapshot.focus);
    try std.testing.expectEqual(Role.checkbox, snapshot.nodes[1].role);
    try std.testing.expect(snapshot.nodes[1].toggled.?);
    try std.testing.expectEqualStrings("Required to proceed", snapshot.nodes[1].description);
    try std.testing.expectEqualStrings("Display name", snapshot.nodes[2].label);
    try std.testing.expect(snapshot.nodes[2].invalid);
    try std.testing.expectEqual(@as(f32, 28), snapshot.nodes[2].bounds.h);
    input.paint_kind.input.disabled = true;
    const disabled = try collect(arena.allocator(), root, 8);
    try std.testing.expect(disabled.nodes[2].disabled);
    try std.testing.expect(!disabled.nodes[2].actionable);
    try std.testing.expectError(error.UnknownFocus, collect(arena.allocator(), root, 9));
    input.id = 7;
    try std.testing.expectError(error.DuplicateId, collect(arena.allocator(), root, 7));
}

test "composed panels remain visible and invalid numeric state fails explicitly" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const overlay = try @import("widgets.zig").modal(b, .{ .x = 0, .y = 0, .w = 300, .h = 200 }, .dialog, &.{try b.button(5, "Confirm")});
    overlay.layout(.{ .x = 0, .y = 0, .w = 300, .h = 200 }, &font);
    const snapshot = try collect(arena.allocator(), overlay, 5);
    try std.testing.expectEqual(Role.group, snapshot.nodes[0].role);
    try std.testing.expectEqual(Role.dialog, snapshot.nodes[1].role);
    try std.testing.expect(snapshot.nodes[1].modal);
    try std.testing.expectEqual(Role.button, snapshot.nodes[2].role);
    const invalid = try b.node(0, .{ .height = 16 }, .{ .progress = std.math.nan(f32) }, &.{});
    invalid.layout(.{ .x = 0, .y = 0, .w = 200, .h = 16 }, &font);
    try std.testing.expectError(error.InvalidValue, collect(arena.allocator(), invalid, 0));
    const standalone = try b.button(17, "Save");
    standalone.layout(.{ .x = 0, .y = 0, .w = 120, .h = 40 }, &font);
    const standalone_snapshot = try collect(arena.allocator(), standalone, 17);
    try std.testing.expectEqual(@as(u64, 17), standalone_snapshot.focus);
    try std.testing.expectEqual(Role.button, standalone_snapshot.nodes[1].role);
}
