//! Native screen-reader bridge backed by AccessKit: publishes `accessibility.Snapshot`s and
//! queues assistive-technology actions for the UI thread to apply.
const std = @import("std");
const builtin = @import("builtin");
const Rect = @import("types.zig").Rect;
const a11y = @import("accessibility.zig");
const c = @cImport({
    @cInclude("accesskit.h");
});

const text_run_id: u64 = @as(u64, 1) << 63;

/// The native window AccessKit attaches to. Linux (AT-SPI) needs no handle.
pub const Window = union(enum) {
    unix,
    win32: *anyopaque,
    /// An `NSWindow*`. `class_name` is the window's Objective-C class, for focus forwarding.
    cocoa: struct { window: *anyopaque, class_name: [:0]const u8 },
};

pub const Action = union(enum) {
    focus: u32,
    click: u32,
    increment: u32,
    decrement: u32,
    set_value: struct {
        target: u32,
        buffer: [128]u8 = undefined,
        len: usize = 0,
        pub fn text(self: *const @This()) []const u8 {
            return self.buffer[0..self.len];
        }
    },
    /// Character offsets (not bytes) into the target's value.
    set_selection: struct { target: u32, anchor: usize, focus: usize },
};

const Native = switch (builtin.os.tag) {
    .linux => c.accesskit_unix_adapter,
    .windows => c.accesskit_windows_subclassing_adapter,
    .macos => c.accesskit_macos_subclassing_adapter,
    else => @compileError("AccessKit has no desktop adapter for this target"),
};

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    /// Label for the root window node when the snapshot's root has none.
    name: []const u8,
    mutex: std.atomic.Mutex = .unlocked,
    arena: std.heap.ArenaAllocator,
    snapshot: a11y.Snapshot = .{ .nodes = &.{.{ .id = 0, .role = .group, .bounds = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .children = &.{} }}, .focus = 0 },
    /// Multiplies snapshot bounds into window coordinates.
    scale: f32 = 1,
    native: ?*Native = null,
    queue: [64]Action = undefined,
    queue_start: usize = 0,
    queue_len: usize = 0,

    pub fn create(allocator: std.mem.Allocator, window: Window, name: []const u8) !*Adapter {
        const self = try allocator.create(Adapter);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .name = name, .arena = .init(allocator) };
        self.native = switch (builtin.os.tag) {
            .linux => c.accesskit_unix_adapter_new(initialTree, self, handleAction, self, deactivated, self),
            .windows => c.accesskit_windows_subclassing_adapter_new(@ptrCast(@alignCast(window.win32)), initialTree, self, handleAction, self),
            .macos => blk: {
                c.accesskit_macos_add_focus_forwarder_to_window_class(window.cocoa.class_name.ptr);
                break :blk c.accesskit_macos_subclassing_adapter_for_window(window.cocoa.window, initialTree, self, handleAction, self);
            },
            else => unreachable,
        } orelse return error.AccessKitInitFailed;
        return self;
    }

    pub fn destroy(self: *Adapter) void {
        switch (builtin.os.tag) {
            .linux => c.accesskit_unix_adapter_free(self.native.?),
            .windows => c.accesskit_windows_subclassing_adapter_free(self.native.?),
            .macos => c.accesskit_macos_subclassing_adapter_free(self.native.?),
            else => unreachable,
        }
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    /// Publish `snapshot`, taking ownership of the `arena` it was allocated in.
    pub fn update(self: *Adapter, arena: std.heap.ArenaAllocator, snapshot: a11y.Snapshot, scale: f32) void {
        self.lock();
        var old = self.arena;
        self.arena = arena;
        self.snapshot = snapshot;
        self.scale = scale;
        self.mutex.unlock();
        old.deinit();
        const native = self.native orelse return; // headless (tests)
        switch (builtin.os.tag) {
            .linux => c.accesskit_unix_adapter_update_if_active(native, updatedTree, self),
            .windows => if (c.accesskit_windows_subclassing_adapter_update_if_active(native, updatedTree, self)) |events| c.accesskit_windows_queued_events_raise(events),
            .macos => if (c.accesskit_macos_subclassing_adapter_update_if_active(native, updatedTree, self)) |events| c.accesskit_macos_queued_events_raise(events),
            else => unreachable,
        }
    }

    pub fn setFocused(self: *Adapter, focused: bool) void {
        switch (builtin.os.tag) {
            .linux => c.accesskit_unix_adapter_update_window_focus_state(self.native.?, focused),
            .macos => if (c.accesskit_macos_subclassing_adapter_update_view_focus_state(self.native.?, focused)) |events| c.accesskit_macos_queued_events_raise(events),
            else => {},
        }
    }

    /// Screen-space window bounds including (`outer`) and excluding (`inner`) decorations.
    /// Only X11 needs this; other platforms query the window themselves.
    pub fn setWindowBounds(self: *Adapter, outer: Rect, inner: Rect) void {
        if (builtin.os.tag != .linux) return;
        c.accesskit_unix_adapter_set_root_window_bounds(self.native.?, toNative(outer, 1), toNative(inner, 1));
    }

    /// Next queued assistive-technology action, oldest first. Call from the UI thread.
    pub fn nextAction(self: *Adapter) ?Action {
        self.lock();
        defer self.mutex.unlock();
        if (self.queue_len == 0) return null;
        const action = self.queue[self.queue_start];
        self.queue_start = (self.queue_start + 1) % self.queue.len;
        self.queue_len -= 1;
        return action;
    }

    pub fn push(self: *Adapter, action: Action) void {
        self.lock();
        defer self.mutex.unlock();
        // ponytail: fixed queue; actions arrive at human speed, so dropping past 64 is fine.
        if (self.queue_len == self.queue.len) return std.log.warn("AccessKit action queue full; dropping action", .{});
        self.queue[(self.queue_start + self.queue_len) % self.queue.len] = action;
        self.queue_len += 1;
    }

    fn lock(self: *Adapter) void {
        // ponytail: spin lock shared with AccessKit's threads; use a blocking mutex if trees get large.
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn initialTree(userdata: ?*anyopaque) callconv(.c) ?*c.accesskit_tree_update {
        const self: *Adapter = @ptrCast(@alignCast(userdata.?));
        return self.buildUpdate(true);
    }

    fn updatedTree(userdata: ?*anyopaque) callconv(.c) ?*c.accesskit_tree_update {
        const self: *Adapter = @ptrCast(@alignCast(userdata.?));
        return self.buildUpdate(false);
    }

    fn deactivated(_: ?*anyopaque) callconv(.c) void {}

    fn buildUpdate(self: *Adapter, initial: bool) *c.accesskit_tree_update {
        self.lock();
        defer self.mutex.unlock();
        const tree = c.accesskit_tree_update_with_capacity_and_focus(self.snapshot.nodes.len * 2, self.snapshot.focus) orelse @panic("AccessKit tree allocation failed");
        if (initial) c.accesskit_tree_update_set_tree_info(tree, c.accesskit_tree_info_new(0));
        for (self.snapshot.nodes) |source| {
            const node = c.accesskit_node_new(if (source.id == 0) c.ACCESSKIT_ROLE_WINDOW else if (source.multiline and source.role == .input) c.ACCESSKIT_ROLE_MULTILINE_TEXT_INPUT else nativeRole(source.role)) orelse @panic("AccessKit node allocation failed");
            c.accesskit_node_set_bounds(node, toNative(source.bounds, self.scale));
            const label = if (source.id == 0 and source.label.len == 0) self.name else source.label;
            if (label.len != 0) c.accesskit_node_set_label_with_length(node, label.ptr, label.len);
            if (source.description.len != 0) c.accesskit_node_set_description_with_length(node, source.description.ptr, source.description.len);
            if (source.described_by) |id| c.accesskit_node_push_described_by(node, id);
            if (source.controls) |id| c.accesskit_node_push_controlled(node, id);
            if (source.value.len != 0) c.accesskit_node_set_value_with_length(node, source.value.ptr, source.value.len);
            if (source.disabled) c.accesskit_node_set_disabled(node);
            if (source.invalid) c.accesskit_node_set_invalid(node, c.ACCESSKIT_INVALID_TRUE);
            if (source.modal) c.accesskit_node_set_modal(node);
            if (source.live != .off) c.accesskit_node_set_live(node, if (source.live == .polite) c.ACCESSKIT_LIVE_POLITE else c.ACCESSKIT_LIVE_ASSERTIVE);
            if (source.role == .ignored) c.accesskit_node_set_hidden(node);
            if (source.toggled) |value| c.accesskit_node_set_toggled(node, if (value) c.ACCESSKIT_TOGGLED_TRUE else c.ACCESSKIT_TOGGLED_FALSE);
            if (source.selected) |value| c.accesskit_node_set_selected(node, value);
            if (source.expanded) |value| c.accesskit_node_set_expanded(node, value);
            if (source.numeric_value) |value| {
                c.accesskit_node_set_numeric_value(node, value);
                c.accesskit_node_set_min_numeric_value(node, 0);
                c.accesskit_node_set_max_numeric_value(node, 1);
                if (source.role == .slider) c.accesskit_node_set_numeric_value_step(node, 0.05);
            }
            for (source.children) |child| c.accesskit_node_push_child(node, child);
            if (source.role == .input and !source.disabled) {
                const child_id = text_run_id | source.id;
                const text = c.accesskit_node_new(c.ACCESSKIT_ROLE_TEXT_RUN) orelse @panic("AccessKit text run allocation failed");
                c.accesskit_node_set_value_with_length(text, source.value.ptr, source.value.len);
                const lengths = self.allocator.alloc(u8, source.value.len) catch @panic("AccessKit character allocation failed");
                defer self.allocator.free(lengths);
                var at: usize = 0;
                var characters: usize = 0;
                while (at < source.value.len) : (characters += 1) {
                    const size = std.unicode.utf8ByteSequenceLength(source.value[at]) catch unreachable;
                    lengths[characters] = size;
                    at += size;
                }
                c.accesskit_node_set_character_lengths(text, characters, lengths.ptr);
                c.accesskit_node_push_child(node, child_id);
                c.accesskit_tree_update_push_node(tree, child_id, text);
                if (source.text_selection) |selection| c.accesskit_node_set_text_selection(node, .{
                    .anchor = .{ .node = child_id, .character_index = std.unicode.utf8CountCodepoints(source.value[0..selection.anchor]) catch unreachable },
                    .focus = .{ .node = child_id, .character_index = std.unicode.utf8CountCodepoints(source.value[0..selection.focus]) catch unreachable },
                });
            }
            if (source.actionable and !source.disabled) {
                c.accesskit_node_add_action(node, c.ACCESSKIT_ACTION_FOCUS);
                switch (source.role) {
                    .button, .checkbox, .switch_control, .radio, .tab, .menu_item, .column_header => c.accesskit_node_add_action(node, c.ACCESSKIT_ACTION_CLICK),
                    .slider => {
                        c.accesskit_node_add_action(node, c.ACCESSKIT_ACTION_INCREMENT);
                        c.accesskit_node_add_action(node, c.ACCESSKIT_ACTION_DECREMENT);
                    },
                    .input => {
                        c.accesskit_node_add_action(node, c.ACCESSKIT_ACTION_SET_VALUE);
                        c.accesskit_node_add_action(node, c.ACCESSKIT_ACTION_SET_TEXT_SELECTION);
                    },
                    else => {},
                }
            }
            c.accesskit_tree_update_push_node(tree, source.id, node);
        }
        return tree;
    }

    fn handleAction(request: ?*c.accesskit_action_request, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Adapter = @ptrCast(@alignCast(userdata.?));
        defer c.accesskit_action_request_free(request);
        if (decode(request.?)) |action| self.push(action);
    }
};

fn decode(request: *const c.accesskit_action_request) ?Action {
    if (request.target_node == 0 or request.target_node > std.math.maxInt(u32)) return null;
    const target: u32 = @intCast(request.target_node);
    switch (request.action) {
        c.ACCESSKIT_ACTION_FOCUS => return .{ .focus = target },
        c.ACCESSKIT_ACTION_CLICK => return .{ .click = target },
        c.ACCESSKIT_ACTION_INCREMENT => return .{ .increment = target },
        c.ACCESSKIT_ACTION_DECREMENT => return .{ .decrement = target },
        c.ACCESSKIT_ACTION_SET_VALUE => {
            if (!request.data.has_value or request.data.value.tag != c.ACCESSKIT_ACTION_DATA_VALUE) return null;
            const raw = request.data.value.unnamed_0.unnamed_1.value orelse return null;
            const value = std.mem.span(raw);
            var action: Action = .{ .set_value = .{ .target = target } };
            if (value.len > action.set_value.buffer.len) {
                std.log.warn("AccessKit value exceeds 128 bytes; ignoring", .{});
                return null;
            }
            @memcpy(action.set_value.buffer[0..value.len], value);
            action.set_value.len = value.len;
            return action;
        },
        c.ACCESSKIT_ACTION_SET_TEXT_SELECTION => {
            if (!request.data.has_value or request.data.value.tag != c.ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION) return null;
            const selection = request.data.value.unnamed_0.unnamed_7.set_text_selection;
            const run = text_run_id | request.target_node;
            if (selection.anchor.node != run or selection.focus.node != run) return null;
            return .{ .set_selection = .{ .target = target, .anchor = selection.anchor.character_index, .focus = selection.focus.character_index } };
        },
        else => return null,
    }
}

fn toNative(r: Rect, scale: f32) c.accesskit_rect {
    const s: f64 = @floatCast(scale);
    return .{ .x0 = @as(f64, r.x) * s, .y0 = @as(f64, r.y) * s, .x1 = @as(f64, r.x + r.w) * s, .y1 = @as(f64, r.y + r.h) * s };
}

fn nativeRole(role: a11y.Role) c.accesskit_role {
    return switch (role) {
        .group, .ignored => c.ACCESSKIT_ROLE_GENERIC_CONTAINER,
        .region => c.ACCESSKIT_ROLE_REGION,
        .log => c.ACCESSKIT_ROLE_LOG,
        .label => c.ACCESSKIT_ROLE_LABEL,
        .heading => c.ACCESSKIT_ROLE_HEADING,
        .button => c.ACCESSKIT_ROLE_BUTTON,
        .checkbox => c.ACCESSKIT_ROLE_CHECK_BOX,
        .switch_control => c.ACCESSKIT_ROLE_SWITCH,
        .slider => c.ACCESSKIT_ROLE_SLIDER,
        .input => c.ACCESSKIT_ROLE_TEXT_INPUT,
        .radio => c.ACCESSKIT_ROLE_RADIO_BUTTON,
        .radio_group => c.ACCESSKIT_ROLE_RADIO_GROUP,
        .progress => c.ACCESSKIT_ROLE_PROGRESS_INDICATOR,
        .tab => c.ACCESSKIT_ROLE_TAB,
        .tab_list => c.ACCESSKIT_ROLE_TAB_LIST,
        .tab_panel => c.ACCESSKIT_ROLE_TAB_PANEL,
        .image => c.ACCESSKIT_ROLE_IMAGE,
        .alert => c.ACCESSKIT_ROLE_ALERT,
        .status => c.ACCESSKIT_ROLE_STATUS,
        .tooltip => c.ACCESSKIT_ROLE_TOOLTIP,
        .dialog => c.ACCESSKIT_ROLE_DIALOG,
        .alert_dialog => c.ACCESSKIT_ROLE_ALERT_DIALOG,
        .menu => c.ACCESSKIT_ROLE_MENU,
        .menu_item => c.ACCESSKIT_ROLE_MENU_ITEM,
        .table => c.ACCESSKIT_ROLE_TABLE,
        .row => c.ACCESSKIT_ROLE_ROW,
        .cell => c.ACCESSKIT_ROLE_CELL,
        .column_header => c.ACCESSKIT_ROLE_COLUMN_HEADER,
    };
}

/// AccessKit's debug dump of what `adapter` would publish; for tests.
pub fn debugTree(adapter: *Adapter, allocator: std.mem.Allocator) ![]u8 {
    const tree = adapter.buildUpdate(false);
    defer c.accesskit_tree_update_free(tree);
    const debug = c.accesskit_tree_update_debug(tree) orelse return error.AccessKitDebugFailed;
    defer c.accesskit_string_free(debug);
    return allocator.dupe(u8, std.mem.span(debug));
}

test "snapshots become native nodes and actions queue in order" {
    var adapter = Adapter{ .allocator = std.testing.allocator, .name = "test app", .arena = .init(std.testing.allocator) };
    defer adapter.arena.deinit();
    var children = [_]u64{7};
    adapter.snapshot = .{ .nodes = &.{
        .{ .id = 0, .role = .group, .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .children = &children },
        .{ .id = 7, .role = .button, .bounds = .{ .x = 0, .y = 0, .w = 50, .h = 20 }, .children = &.{}, .label = "Increment", .actionable = true },
    }, .focus = 7 };
    const dump = try debugTree(&adapter, std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "Increment") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "test app") != null);

    adapter.push(.{ .click = 7 });
    adapter.push(.{ .focus = 7 });
    try std.testing.expectEqual(@as(u32, 7), adapter.nextAction().?.click);
    try std.testing.expectEqual(@as(u32, 7), adapter.nextAction().?.focus);
    try std.testing.expect(adapter.nextAction() == null);
}
