//! Composed, frame-local widgets covering the shadcn/ui component set.
//! Applications retain all interaction state and pass it in every frame.
const std = @import("std");
const L = @import("layout.zig");
const primitives = @import("components/primitives.zig");
const Rect = @import("types.zig").Rect;
const Icon = @import("font.zig").Icon;
const ButtonVariant = @import("components/button.zig").Variant;

pub const Choice = struct { id: u32, label: []const u8 };
pub const Section = struct { id: u32, title: []const u8, open: bool = false, content: []const *L.Element = &.{} };
pub const Date = struct { year: u16, month: u8, day: u8 = 0, hour: u8 = 0, minute: u8 = 0 };
pub const Modal = enum { dialog, alert_dialog, sheet, drawer };
pub const TableOptions = struct { lines: bool = false };
pub const MessageScrollOptions = struct {
    alignment: enum { start, center, end, nearest } = .nearest,
    margin: f32 = 0,
};
/// A row in a dropdown, context menu or menubar. `id` 0 with `.item` is a heading.
pub const MenuItem = struct {
    id: u32 = 0,
    label: []const u8 = "",
    shortcut: []const u8 = "",
    kind: enum { item, checkbox, radio, label, separator, submenu } = .item,
    checked: bool = false,
    disabled: bool = false,
    /// Children of a `.submenu`, shown to its right while it is open.
    items: []const MenuItem = &.{},
};

/// Place `popup` over the page next to `anchor` (below, or to the right for submenus).
pub fn anchorTo(popup: *L.Element, anchor: *const L.Element, side: @FieldType(@FieldType(L.Overlay, "anchor"), "side"), z_index: i16) *L.Element {
    popup.style.z_index = z_index;
    popup.overlay = .{ .anchor = .{ .target = anchor, .side = side } };
    return popup;
}

/// Label, control, then a helper line; an invalid input shows the helper as an error.
pub fn field(b: L.Builder, id: u32, name: []const u8, description: []const u8, opts: primitives.Input) !*L.Element {
    const input = try b.input(id, opts);
    input.accessibility.label = name;
    input.accessibility.description = if (description.len > 0) description else null;
    if (description.len == 0) return b.node(0, .{ .gap = 8 }, .none, &.{ try b.label(name), input });
    const helper = try b.node(0, .{}, .{ .text = .{ .value = description, .size = 13, .tone = .muted, .wrap = true } }, &.{});
    if (opts.invalid) helper.paint_kind.text.tone = .foreground;
    return b.node(0, .{ .gap = 8 }, .none, &.{ try b.label(name), input, helper });
}

pub fn inputGroup(b: L.Builder, id: u32, prefix: []const u8, opts: primitives.Input, suffix: []const u8) !*L.Element {
    return b.node(0, .{ .direction = .row, .height = 40, .gap = 8, .align_items = .center }, .none, &.{
        try b.node(0, .{}, .{ .text = .{ .value = prefix, .tone = .muted } }, &.{}),
        try b.node(id, .{ .grow = 1, .height = 40 }, .{ .input = opts }, &.{}),
        try b.node(0, .{}, .{ .text = .{ .value = suffix, .tone = .muted } }, &.{}),
    });
}

pub fn inputOtp(b: L.Builder, first_id: u32, digits: []const u8, slots: usize) !*L.Element {
    if (slots == 0 or slots > 12 or digits.len > slots or first_id > std.math.maxInt(u32) - @as(u32, @intCast(slots))) return error.InvalidOtp;
    for (digits) |digit| if (digit < '0' or digit > '9') return error.InvalidOtp;
    const children = try b.allocator.alloc(*L.Element, slots);
    defer b.allocator.free(children);
    for (children, 0..) |*child, i| {
        child.* = try b.node(first_id + @as(u32, @intCast(i)), .{ .width = 40, .height = 40 }, .{ .input = .{
            .value = if (i < digits.len) digits[i .. i + 1] else "",
            .placeholder = "_",
        } }, &.{});
    }
    return b.node(0, .{ .direction = .row, .gap = 8 }, .none, children);
}

/// Field-looking trigger: value (or muted placeholder) with a chevron inside the box.
fn selectBox(b: L.Builder, id: u32, value: []const u8, placeholder: []const u8, height: f32) !*L.Element {
    const result = try b.node(id, .{ .direction = .row, .height = height, .align_items = .center, .gap = 8, .padding = .{ .left = 12, .right = 12 } }, .{ .input = .{} }, &.{
        try b.node(0, .{ .grow = 1, .height = height }, .{ .text = .{ .value = if (value.len == 0) placeholder else value, .size = 14, .tone = if (value.len == 0) .muted else .foreground } }, &.{}),
        try b.node(0, .{ .width = 16, .height = 16 }, .{ .icon = .chevron_down }, &.{}),
    });
    result.children[0].accessibility.role = .ignored;
    result.children[1].accessibility.role = .ignored;
    return result;
}

pub fn select(b: L.Builder, id: u32, selected: []const u8, placeholder: []const u8) !*L.Element {
    const result = try selectBox(b, id, selected, placeholder, 40);
    result.accessibility = .{ .role = .button, .label = if (selected.len == 0) placeholder else selected };
    return result;
}

/// A select without a popup: activating it (or arrow keys) steps through `options`, like a
/// platform `<select>` rendered inline.
pub fn nativeSelect(b: L.Builder, id: u32, options: []const []const u8, index: usize) !*L.Element {
    if (index >= options.len) return error.InvalidSelection;
    const result = try selectBox(b, id, options[index], "", 36);
    result.accessibility = .{ .role = .button, .label = options[index], .description = "Press to choose the next option" };
    return result;
}

pub fn radioGroup(b: L.Builder, choices: []const Choice, selected_id: u32) !*L.Element {
    if (choices.len == 0) return error.EmptyChoices;
    const children = try b.allocator.alloc(*L.Element, choices.len);
    defer b.allocator.free(children);
    for (choices, 0..) |choice, i| children[i] = try b.radio(choice.id, choice.label, choice.id == selected_id);
    const result = try b.node(0, .{ .gap = 4 }, .none, children);
    result.accessibility.role = .radio_group;
    return result;
}

pub fn tabs(b: L.Builder, choices: []const Choice, selected_id: u32, panels: []const *L.Element) !*L.Element {
    if (choices.len == 0 or panels.len != choices.len) return error.InvalidTabs;
    const children = try b.allocator.alloc(*L.Element, choices.len);
    defer b.allocator.free(children);
    var selected: ?usize = null;
    for (choices, 0..) |choice, i| {
        if (choice.id == selected_id) selected = i;
        children[i] = try b.tab(choice.id, choice.label, choice.id == selected_id);
        children[i].style.height = 32;
    }
    const index = selected orelse return error.InvalidSelection;
    const bar = try b.node(0, .{ .direction = .row, .gap = 2, .padding = .{ .left = 3, .right = 3, .top = 3, .bottom = 3 } }, .{ .surface = .track }, children);
    bar.accessibility.role = .tab_list;
    const panel = try b.node(0, .{}, .none, &.{panels[index]});
    panel.accessibility.role = .tab_panel;
    return b.node(0, .{ .gap = 12 }, .none, &.{ bar, panel });
}

pub fn toggleGroup(b: L.Builder, choices: []const Choice, pressed_ids: []const u32) !*L.Element {
    const children = try b.allocator.alloc(*L.Element, choices.len);
    defer b.allocator.free(children);
    for (choices, 0..) |choice, i| children[i] = try b.toggleButton(choice.id, choice.label, std.mem.indexOfScalar(u32, pressed_ids, choice.id) != null);
    return b.node(0, .{ .direction = .row, .gap = 4 }, .none, children);
}

pub fn buttonGroup(b: L.Builder, choices: []const Choice) !*L.Element {
    const children = try b.allocator.alloc(*L.Element, choices.len);
    defer b.allocator.free(children);
    for (choices, 0..) |choice, i| children[i] = try b.node(choice.id, .{ .height = 36 }, .{ .button = .{ .label = choice.label, .variant = .outline } }, &.{});
    return b.node(0, .{ .direction = .row, .gap = 4 }, .none, children);
}

/// Menu panel from plain choices; `highlighted_id` is the keyboard-highlighted row.
pub fn menu(b: L.Builder, choices: []const Choice, highlighted_id: u32) !*L.Element {
    const items = try b.allocator.alloc(MenuItem, choices.len);
    defer b.allocator.free(items);
    for (choices, items) |choice, *slot| slot.* = .{ .id = choice.id, .label = choice.label };
    return menuItems(b, items, highlighted_id, 0);
}

/// Menu panel with shortcuts, separators, check/radio rows and submenus. The submenu whose
/// id is `open_submenu` is attached to its row.
pub fn menuItems(b: L.Builder, items: []const MenuItem, highlighted_id: u32, open_submenu: u32) !*L.Element {
    if (items.len == 0) return b.node(0, .{ .width = 220, .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 } }, .{ .surface = .menu }, &.{try b.node(0, .{}, .{ .text = .{ .value = "No results", .tone = .muted, .size = 14 } }, &.{})});
    var inset = false;
    for (items) |entry| inset = inset or entry.kind == .checkbox or entry.kind == .radio;
    var children: std.ArrayList(*L.Element) = .empty;
    defer children.deinit(b.allocator);
    for (items) |entry| {
        if (entry.kind == .separator) {
            try children.append(b.allocator, try b.node(0, .{ .height = 9, .padding = .{ .top = 4, .bottom = 4, .left = -4, .right = -4 } }, .none, &.{try b.separator()}));
            continue;
        }
        const row = try b.node(if (entry.kind == .label) 0 else entry.id, .{ .height = if (entry.kind == .label) 28 else 32 }, .{ .menu_item = .{
            .label = entry.label,
            .shortcut = entry.shortcut,
            .hot = entry.id != 0 and entry.id == highlighted_id,
            .indicator = switch (entry.kind) {
                .checkbox => if (entry.checked) .checked else .unchecked,
                .radio => if (entry.checked) .radio_on else .radio_off,
                else => if (inset) .inset else .none,
            },
            .submenu = entry.kind == .submenu,
            .disabled = entry.disabled,
            .heading = entry.kind == .label,
        } }, &.{});
        row.accessibility.disabled = entry.disabled;
        if (entry.kind == .submenu) row.accessibility.expanded = entry.id == open_submenu;
        try children.append(b.allocator, row);
        if (entry.kind == .submenu and entry.id == open_submenu and entry.id != 0) {
            const sub = try menuItems(b, entry.items, highlighted_id, open_submenu);
            try children.append(b.allocator, anchorTo(sub, row, .right, 150));
        }
    }
    const result = try b.node(0, .{ .width = 240, .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 }, .gap = 1 }, .{ .surface = .menu }, children.items);
    return result;
}

pub fn dropdownMenu(b: L.Builder, anchor: *const L.Element, choices: []const Choice, highlighted_id: u32, open: bool) !?*L.Element {
    if (!open) return null;
    return anchorTo(try menu(b, choices, highlighted_id), anchor, .bottom, 100);
}

pub fn contextMenu(b: L.Builder, point: ?@import("types.zig").Vec2, choices: []const Choice, highlighted_id: u32) !?*L.Element {
    const position = point orelse return null;
    const popup = try menu(b, choices, highlighted_id);
    popup.style.z_index = 200;
    popup.overlay = .{ .point = position };
    return popup;
}

pub const MenubarMenu = struct { id: u32, label: []const u8, items: []const MenuItem };

/// Desktop-style menu bar. `open_id` is the open menu's trigger id (0 when closed).
pub fn menubar(b: L.Builder, menus: []const MenubarMenu, open_id: u32, highlighted_id: u32, open_submenu: u32) !*L.Element {
    var children: std.ArrayList(*L.Element) = .empty;
    defer children.deinit(b.allocator);
    for (menus) |entry| {
        const trigger = try b.node(entry.id, .{ .height = 30 }, .{ .button = .{ .label = entry.label, .variant = .ghost, .hot = entry.id == open_id } }, &.{});
        trigger.accessibility = .{ .role = .button, .label = entry.label, .expanded = entry.id == open_id };
        try children.append(b.allocator, trigger);
        if (entry.id == open_id) try children.append(b.allocator, anchorTo(try menuItems(b, entry.items, highlighted_id, open_submenu), trigger, .bottom, 100));
    }
    const bar = try b.node(0, .{ .direction = .row, .gap = 2, .height = 40, .align_items = .center, .padding = .{ .left = 4, .right = 4 } }, .{ .surface = .card }, children.items);
    bar.accessibility.role = .menu;
    return b.node(0, .{ .direction = .row }, .none, &.{bar});
}

pub const NavigationLink = struct { id: u32, title: []const u8, description: []const u8 = "" };
/// A top-level entry: with `links` it opens a panel, without it is a plain link.
pub const NavigationItem = struct { id: u32, label: []const u8, links: []const NavigationLink = &.{} };

/// Website-style navigation: triggers open a two-column panel of described links.
pub fn navigationMenu(b: L.Builder, items: []const NavigationItem, open_id: u32) !*L.Element {
    var children: std.ArrayList(*L.Element) = .empty;
    defer children.deinit(b.allocator);
    for (items) |entry| {
        const trigger = try b.node(entry.id, .{ .height = 36 }, .{ .button = .{ .label = entry.label, .variant = .ghost, .hot = entry.id == open_id } }, &.{});
        trigger.accessibility = .{ .role = .button, .label = entry.label, .expanded = if (entry.links.len > 0) entry.id == open_id else null };
        try children.append(b.allocator, trigger);
        if (entry.id != open_id or entry.links.len == 0) continue;
        const links = try b.allocator.alloc(*L.Element, entry.links.len);
        defer b.allocator.free(links);
        for (entry.links, links) |link, *slot| {
            slot.* = try b.node(link.id, .{ .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 }, .gap = 4 }, .hover, &.{
                try b.node(0, .{}, .{ .text = .{ .value = link.title, .size = 14 } }, &.{}),
                try b.node(0, .{}, .{ .text = .{ .value = link.description, .size = 13, .tone = .muted, .wrap = true } }, &.{}),
            });
            slot.*.accessibility = .{ .role = .button, .label = link.title, .description = link.description };
            slot.*.children[0].accessibility.role = .ignored;
            slot.*.children[1].accessibility.role = .ignored;
        }
        const panel = try b.node(0, .{ .width = 440, .padding = .{ .left = 6, .right = 6, .top = 6, .bottom = 6 }, .columns = 2, .gap = 4 }, .{ .surface = .popover }, links);
        try children.append(b.allocator, anchorTo(panel, trigger, .bottom, 100));
    }
    const result = try b.node(0, .{ .direction = .row, .gap = 4 }, .none, children.items);
    result.accessibility = .{ .role = .group, .label = "Navigation" };
    return result;
}

/// Search field with a filtered menu below it while `open`. The field keeps its width either way.
pub fn combobox(b: L.Builder, id: u32, query: []const u8, choices: []const Choice, highlighted_id: u32, open: bool) !*L.Element {
    const input = try b.input(id, .{ .value = query, .placeholder = "Search..." });
    input.accessibility.expanded = open;
    if (!open) return input;
    const matching = try b.allocator.alloc(Choice, choices.len);
    defer b.allocator.free(matching);
    var count: usize = 0;
    for (choices) |choice| {
        if (!containsIgnoreCase(choice.label, query)) continue;
        matching[count] = choice;
        count += 1;
    }
    const popup = (try dropdownMenu(b, input, matching[0..count], highlighted_id, true)).?;
    return b.node(0, .{}, .none, &.{ input, popup });
}
fn containsIgnoreCase(value: []const u8, query: []const u8) bool {
    if (query.len > value.len) return false;
    for (0..value.len - query.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(value[i..][0..query.len], query)) return true;
    }
    return false;
}

pub fn command(b: L.Builder, id: u32, query: []const u8, choices: []const Choice, highlighted_id: u32) !*L.Element {
    return combobox(b, id, query, choices, highlighted_id, true);
}

/// Collapsible: a trigger row that shows `content` beneath it while open.
pub fn disclosure(b: L.Builder, id: u32, title: []const u8, open: bool, content: []const *L.Element) !*L.Element {
    const header = try b.node(id, .{ .height = 44 }, .{ .disclosure = .{ .label = title, .open = open } }, &.{});
    return b.node(0, .{ .gap = 4 }, .none, if (open) &.{ header, try b.node(0, .{ .padding = .{ .bottom = 12 }, .gap = 8 }, .none, content) } else &.{header});
}

pub fn accordion(b: L.Builder, sections: []const Section) !*L.Element {
    const children = try b.allocator.alloc(*L.Element, sections.len * 2);
    defer b.allocator.free(children);
    for (sections, 0..) |section, i| {
        children[i * 2] = try disclosure(b, section.id, section.title, section.open, section.content);
        children[i * 2 + 1] = try b.separator();
    }
    return b.node(0, .{}, .none, children);
}

pub fn scrollArea(b: L.Builder, viewport: Rect, state: *L.ScrollState, children: []const *L.Element) !*L.Element {
    if (!std.math.isFinite(viewport.w) or !std.math.isFinite(viewport.h) or viewport.w <= 0 or viewport.h <= 0) return error.InvalidSize;
    const result = try b.node(0, .{ .width = viewport.w, .height = viewport.h, .overflow = .scroll }, .none, children);
    result.scroll = state;
    state.overlay_bar = true;
    return result;
}

pub fn aspectRatio(b: L.Builder, width: f32, ratio: f32, children: []const *L.Element) !*L.Element {
    if (!std.math.isFinite(width) or !std.math.isFinite(ratio) or width <= 0 or ratio <= 0) return error.InvalidRatio;
    const height = width / ratio;
    if (!std.math.isFinite(height)) return error.InvalidRatio;
    return b.node(0, .{ .width = width, .height = height }, .none, children);
}

pub fn resizable(b: L.Builder, viewport: Rect, fraction: f32, handle_id: u32, first: *L.Element, second: *L.Element) !*L.Element {
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1 or !std.math.isFinite(viewport.w) or !std.math.isFinite(viewport.h) or viewport.w <= 0 or viewport.h <= 0) return error.InvalidRatio;
    const first_width = @max(0, viewport.w - 6) * fraction;
    first.style.width = first_width;
    first.style.height = viewport.h;
    second.style.width = @max(0, viewport.w - 6 - first_width);
    second.style.height = viewport.h;
    const handle = try b.node(handle_id, .{ .width = 6, .height = viewport.h }, .skeleton, &.{});
    handle.cursor = .ew_resize;
    return b.node(0, .{ .width = viewport.w, .height = viewport.h, .direction = .row }, .none, &.{ first, handle, second });
}

pub fn modal(b: L.Builder, viewport: Rect, kind: Modal, children: []const *L.Element) !*L.Element {
    if (!std.math.isFinite(viewport.w) or !std.math.isFinite(viewport.h) or viewport.w <= 0 or viewport.h <= 0) return error.InvalidSize;
    const width: f32 = switch (kind) {
        .dialog, .alert_dialog => @min(480, @max(0, viewport.w - 32)),
        .sheet => @min(360, viewport.w),
        .drawer => viewport.w,
    };
    const height: f32 = switch (kind) {
        .dialog, .alert_dialog => @min(260, @max(0, viewport.h - 32)),
        .sheet => viewport.h,
        .drawer => @min(320, viewport.h),
    };
    const panel = try b.node(0, .{
        .width = width,
        .height = height,
        .padding = .{ .left = 24, .right = 24, .top = 24, .bottom = 24 },
        .gap = 12,
        .overflow = .scroll,
    }, .{ .surface = .dialog }, children);
    panel.accessibility = .{ .role = if (kind == .alert_dialog) .alert_dialog else .dialog, .modal = true };
    return b.node(0, .{
        .width = viewport.w,
        .height = viewport.h,
        .align_items = if (kind == .dialog or kind == .alert_dialog) .center else .start,
        .padding = .{
            .left = if (kind == .sheet) viewport.w - width else 0,
            .top = if (kind == .drawer) viewport.h - height else if (kind == .sheet) 0 else (viewport.h - height) / 2,
        },
    }, .backdrop, &.{panel});
}

pub fn popover(b: L.Builder, children: []const *L.Element) !*L.Element {
    return b.surface(.popover, children);
}
pub fn hoverCard(b: L.Builder, children: []const *L.Element) !*L.Element {
    return b.surface(.card, children);
}
pub fn popoverAt(b: L.Builder, anchor: *const L.Element, children: []const *L.Element) !*L.Element {
    const panel = try popover(b, children);
    panel.style.width = 220;
    return anchorTo(panel, anchor, .bottom, 100);
}
pub fn hoverCardAt(b: L.Builder, anchor: *const L.Element, children: []const *L.Element) !*L.Element {
    const panel = try hoverCard(b, children);
    panel.style.width = 240;
    return anchorTo(panel, anchor, .bottom, 100);
}
pub fn tooltip(b: L.Builder, text: []const u8) !*L.Element {
    const result = try b.node(0, .{ .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 } }, .{ .surface = .tooltip }, &.{try b.node(0, .{}, .{ .text = .{ .value = text, .size = 13 } }, &.{})});
    result.accessibility.label = text;
    return result;
}
pub fn tooltipAt(b: L.Builder, anchor: *const L.Element, text: []const u8) !*L.Element {
    return anchorTo(try tooltip(b, text), anchor, .bottom, 200);
}
pub fn toast(b: L.Builder, title: []const u8, description: []const u8) !*L.Element {
    return toastWithAction(b, title, description, null);
}
fn toastWithAction(b: L.Builder, title: []const u8, description: []const u8, action: ?*L.Element) !*L.Element {
    const title_node = try b.label(title);
    const details = try b.node(0, .{}, .{ .text = .{ .value = description, .tone = .muted, .wrap = true, .size = 14 } }, &.{});
    const result = try b.surface(.toast, if (action) |button| &.{ title_node, details, button } else &.{ title_node, details });
    result.accessibility.label = title;
    result.accessibility.description = description;
    result.accessibility.live = .polite;
    return result;
}
pub fn toastAt(b: L.Builder, viewport: Rect, title: []const u8, description: []const u8) !*L.Element {
    const panel = try toast(b, title, description);
    try placeToast(panel, viewport);
    return panel;
}
pub fn dismissibleToastAt(b: L.Builder, viewport: Rect, title: []const u8, description: []const u8, dismiss_id: u32) !*L.Element {
    const panel = try toastWithAction(b, title, description, try b.buttonVariant(dismiss_id, "Dismiss", .outline));
    try placeToast(panel, viewport);
    return panel;
}
fn placeToast(panel: *L.Element, viewport: Rect) !void {
    if (!std.math.isFinite(viewport.w) or !std.math.isFinite(viewport.h) or viewport.w <= 0 or viewport.h <= 0) return error.InvalidSize;
    panel.style.width = @max(1, @min(320, viewport.w - 16));
    panel.style.z_index = 500;
    panel.overlay = .{ .point = .init(viewport.x + viewport.w - panel.style.width.? - 8, viewport.y + 8) };
}
pub fn empty(b: L.Builder, title: []const u8, description: []const u8, action: ?*L.Element) !*L.Element {
    const title_node = try b.label(title);
    const details = try b.node(0, .{}, .{ .text = .{ .value = description, .tone = .muted, .wrap = true, .size = 14 } }, &.{});
    const result = try b.node(0, .{ .gap = 12, .padding = .{ .left = 24, .right = 24, .top = 32, .bottom = 32 }, .align_items = .center }, .{ .surface = .card }, if (action) |a| &.{ title_node, details, a } else &.{ title_node, details });
    title_node.paint_kind.text.alignment = .center;
    details.paint_kind.text.alignment = .center;
    return result;
}
/// Chat message: author avatar beside the name and body.
pub fn message(b: L.Builder, author: []const u8, body: []const u8) !*L.Element {
    const initials = author[0..@min(author.len, if (author.len > 0 and author[0] >= 0x80) std.unicode.utf8ByteSequenceLength(author[0]) catch 1 else 1)];
    const avatar = try b.avatar(initials);
    avatar.style.width = 32;
    avatar.style.height = 32;
    const result = try b.node(0, .{ .direction = .row, .gap = 12, .padding = .{ .top = 4, .bottom = 4 } }, .none, &.{
        avatar,
        try b.node(0, .{ .grow = 1, .gap = 2 }, .none, &.{
            try b.node(0, .{}, .{ .text = .{ .value = author, .size = 13, .tone = .muted } }, &.{}),
            try b.node(0, .{}, .{ .text = .{ .value = body, .size = 15, .wrap = true } }, &.{}),
        }),
    });
    result.accessibility = .{ .role = .group, .label = author, .description = body };
    return result;
}
pub fn sidebar(b: L.Builder, viewport_height: f32, children: []const *L.Element) !*L.Element {
    if (!std.math.isFinite(viewport_height) or viewport_height <= 0) return error.InvalidSize;
    return b.node(0, .{ .width = 240, .height = viewport_height, .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 }, .gap = 8 }, .{ .surface = .sidebar }, children);
}

pub const AttachmentState = enum { idle, uploading, processing, @"error", done };
pub const AttachmentInfo = struct {
    name: []const u8,
    description: []const u8 = "",
    state: AttachmentState = .done,
    /// 0..1 while uploading.
    progress: f32 = 0,
    icon: Icon = .file,
};

/// File card: media, name, metadata or upload progress, and a remove action (`remove_id`, 0 for none).
pub fn attachment(b: L.Builder, remove_id: u32, info: AttachmentInfo) !*L.Element {
    if (!std.math.isFinite(info.progress) or info.progress < 0 or info.progress > 1) return error.InvalidProgress;
    const media = try b.node(0, .{ .width = 40, .height = 40, .padding = .{ .left = 10, .right = 10, .top = 10, .bottom = 10 } }, .{ .surface = .track }, &.{try b.node(0, .{ .width = 20, .height = 20 }, .{ .icon = info.icon }, &.{})});
    media.children[0].accessibility.role = .ignored;
    const status = switch (info.state) {
        .uploading => try std.fmt.allocPrint(b.allocator, "Uploading {d}%", .{@as(u32, @intFromFloat(@round(info.progress * 100)))}),
        .processing => "Processing...",
        .@"error" => "Upload failed",
        .idle, .done => info.description,
    };
    const details = try b.node(0, .{ .grow = 1, .gap = 4 }, .none, &.{
        try b.node(0, .{}, .{ .text = .{ .value = info.name, .size = 14 } }, &.{}),
        try b.node(0, .{}, .{ .text = .{ .value = status, .size = 13, .tone = if (info.state == .@"error") .foreground else .muted } }, &.{}),
        if (info.state == .uploading) blk: {
            const bar = try b.progress(info.progress);
            bar.style.height = 6;
            break :blk bar;
        } else try b.node(0, .{ .height = 0 }, .none, &.{}),
    });
    const row = try b.node(0, .{ .direction = .row, .gap = 12, .align_items = .center, .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 } }, .{ .surface = .card }, if (remove_id == 0) &.{ media, details } else &.{ media, details, try iconButton(b, remove_id, .x, "Remove attachment", .ghost) });
    row.accessibility = .{ .role = .group, .label = info.name, .description = status };
    return row;
}

pub fn kbd(b: L.Builder, shortcut: []const u8) !*L.Element {
    const mac = @import("builtin").os.tag == .macos;
    const label_text = if (mac and std.mem.startsWith(u8, shortcut, "Ctrl+")) shortcut[5..] else shortcut;
    var children: [2]*L.Element = undefined;
    var count: usize = 0;
    if (mac and label_text.len != shortcut.len) {
        children[count] = try b.node(0, .{ .width = 12, .height = 12 }, .{ .icon = .command }, &.{});
        count += 1;
    }
    children[count] = try b.node(0, .{}, .{ .text = .{ .value = label_text, .size = 12, .tone = .muted } }, &.{});
    count += 1;
    const result = try b.node(0, .{ .height = 22, .padding = .{ .left = 6, .right = 6 }, .direction = .row, .align_items = .center, .gap = 2 }, .{ .surface = .track }, children[0..count]);
    result.accessibility = .{ .role = .group, .label = shortcut };
    return b.node(0, .{ .direction = .row }, .none, &.{result});
}

/// List row with optional leading media; highlights on hover when `id` is set.
pub fn item(b: L.Builder, id: u32, title: []const u8, description: []const u8, leading: ?*L.Element) !*L.Element {
    const content = try b.node(0, .{ .grow = 1, .gap = 2 }, .none, &.{
        try b.label(title),
        try b.node(0, .{}, .{ .text = .{ .value = description, .tone = .muted, .wrap = true, .size = 14 } }, &.{}),
    });
    return b.node(id, .{ .direction = .row, .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 }, .gap = 12, .align_items = .center }, .hover, if (leading) |icon| &.{ icon, content } else &.{content});
}

pub fn form(b: L.Builder, fields: []const *L.Element) !*L.Element {
    return b.node(0, .{ .gap = 16 }, .none, fields);
}

pub fn messageScroller(b: L.Builder, viewport: Rect, state: *L.ScrollState, messages: []const *L.Element) !*L.Element {
    const log = try b.node(0, .{}, .none, messages);
    log.accessibility = .{ .role = .log, .live = .polite };
    const region = try scrollArea(b, viewport, state, &.{log});
    region.accessibility = .{ .role = .region, .label = "Messages" };
    state.message_mode = true;
    return region;
}

pub fn scrollToMessage(region: *const L.Element, id: u32, options: MessageScrollOptions) !bool {
    if (!std.math.isFinite(options.margin) or options.margin < 0) return error.InvalidSize;
    const state = region.scroll orelse return error.InvalidScroller;
    if (!state.message_mode or region.children.len != 1) return error.InvalidScroller;
    if (region.bounds.w <= 0 or region.bounds.h <= 0 or state.viewport.h <= 0) return error.UnlaidOut;
    for (region.children[0].children) |message_node| {
        if (message_node.id != id or id == 0) continue;
        const top = message_node.bounds.y - region.bounds.y + state.offset.y;
        const bottom = top + message_node.bounds.h;
        const viewport_bottom = state.offset.y + state.viewport.h;
        const requested = switch (options.alignment) {
            .start => top - options.margin,
            .center => top + message_node.bounds.h / 2 - state.viewport.h / 2,
            .end => bottom + options.margin - state.viewport.h,
            .nearest => if (top < state.offset.y + options.margin)
                top - options.margin
            else if (bottom > viewport_bottom - options.margin)
                bottom + options.margin - state.viewport.h
            else
                state.offset.y,
        };
        state.offset.y = std.math.clamp(requested, 0, @max(0, state.content.y - state.viewport.h));
        state.following_messages = false;
        return true;
    }
    return false;
}

pub fn table(b: L.Builder, headers: []const []const u8, rows: []const []const []const u8) !*L.Element {
    return tableWithOptions(b, headers, rows, .{});
}

pub fn tableWithOptions(b: L.Builder, headers: []const []const u8, rows: []const []const []const u8, options: TableOptions) !*L.Element {
    if (headers.len == 0) return error.InvalidTable;
    const children = try b.allocator.alloc(*L.Element, rows.len + 1 + if (options.lines) rows.len else @as(usize, 0));
    defer b.allocator.free(children);
    children[0] = try tableRow(b, headers, true);
    for (rows, 0..) |row, i| {
        if (row.len != headers.len) return error.InvalidTable;
        if (options.lines) children[2 * i + 1] = try b.node(0, .{ .height = 1 }, .separator, &.{});
        children[(if (options.lines) 2 else @as(usize, 1)) * (i + 1)] = try tableRow(b, row, false);
    }
    const result = try b.node(0, .{}, .{ .surface = .card }, children);
    result.accessibility.role = .table;
    return result;
}

pub fn dataTable(b: L.Builder, headers: []const Choice, rows: []const []const []const u8) !*L.Element {
    return dataTableWithOptions(b, headers, rows, .{});
}

pub fn dataTableWithOptions(b: L.Builder, headers: []const Choice, rows: []const []const []const u8, options: TableOptions) !*L.Element {
    if (headers.len == 0) return error.InvalidTable;
    const labels = try b.allocator.alloc([]const u8, headers.len);
    defer b.allocator.free(labels);
    for (headers, 0..) |header, i| {
        if (header.id == 0) return error.InvalidId;
        labels[i] = header.label;
    }
    const result = try tableWithOptions(b, labels, rows, options);
    for (headers, 0..) |header, i| {
        result.children[0].children[i].id = header.id;
        result.children[0].children[i].paint_kind.text.link = true;
    }
    return result;
}

fn tableRow(b: L.Builder, values: []const []const u8, header: bool) !*L.Element {
    const cells = try b.allocator.alloc(*L.Element, values.len);
    defer b.allocator.free(cells);
    for (values, 0..) |value, i| {
        cells[i] = try b.node(0, .{ .height = 36, .padding = .{ .left = 12, .right = 12 } }, .{
            .text = .{ .value = value, .size = 14, .tone = if (header) .muted else .foreground },
        }, &.{});
        cells[i].accessibility.role = if (header) .column_header else .cell;
    }
    // Equal grid columns keep every row's cells lined up under their headers.
    const row = try b.node(0, .{ .columns = @intCast(values.len) }, .none, cells);
    row.accessibility.role = .row;
    return row;
}

pub fn carousel(b: L.Builder, previous_id: u32, next_id: u32, slides: []const *L.Element, selected: usize) !*L.Element {
    if (slides.len == 0 or selected >= slides.len) return error.InvalidSlide;
    const slide = try b.node(0, .{ .grow = 1, .min_width = 160 }, .none, &.{slides[selected]});
    return b.node(0, .{ .direction = .row, .gap = 8, .align_items = .center }, .none, &.{
        try iconButton(b, previous_id, .chevron_left, "Previous slide", .outline),
        slide,
        try iconButton(b, next_id, .chevron_right, "Next slide", .outline),
    });
}

pub fn iconButton(b: L.Builder, id: u32, icon: Icon, label: []const u8, variant: ButtonVariant) !*L.Element {
    const result = try b.node(id, .{ .width = 36, .height = 36, .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 } }, .{ .button = .{ .label = "", .variant = variant } }, &.{try b.node(0, .{ .width = 20, .height = 20 }, .{ .icon = icon }, &.{})});
    result.children[0].accessibility.role = .ignored;
    result.accessibility.label = label;
    return result;
}

/// Path of links; every crumb is clickable and the last one marks the current page.
pub fn breadcrumb(b: L.Builder, choices: []const Choice) !*L.Element {
    if (choices.len == 0) return error.EmptyChoices;
    const children = try b.allocator.alloc(*L.Element, choices.len * 2 - 1);
    defer b.allocator.free(children);
    for (choices, 0..) |choice, i| {
        if (i > 0) children[i * 2 - 1] = try b.node(0, .{ .width = 16, .height = 16 }, .{ .icon = .chevron_right }, &.{});
        const current = i + 1 == choices.len;
        children[i * 2] = try b.node(choice.id, .{ .height = 24 }, .{
            .text = .{ .value = choice.label, .size = 14, .tone = if (current) .foreground else .muted, .link = true },
        }, &.{});
        children[i * 2].accessibility = .{ .role = .button, .label = choice.label, .description = if (current) "Current page" else null };
    }
    const result = try b.node(0, .{ .direction = .row, .height = 32, .gap = 6, .align_items = .center }, .none, children);
    result.accessibility = .{ .role = .group, .label = "Breadcrumb" };
    return result;
}

pub fn pagination(b: L.Builder, first_id: u32, current: u16, total: u16) !*L.Element {
    if (total == 0 or current == 0 or current > total or first_id > std.math.maxInt(u32) - @as(u32, total) - 1) return error.InvalidPagination;
    var pages: [7]*L.Element = undefined;
    var count: usize = 0;
    if (current > 1) {
        pages[count] = try iconButton(b, first_id, .chevron_left, "Previous page", .ghost);
        count += 1;
    }
    const start = @max(1, @as(u32, current) -| 2);
    const end = @min(@as(u32, total), start + 4);
    for (start..end + 1) |page| {
        const text = try std.fmt.allocPrint(b.allocator, "{d}", .{page});
        pages[count] = try pageButton(b, first_id + @as(u32, @intCast(page)), text, page == current);
        count += 1;
    }
    if (current < total) {
        pages[count] = try iconButton(b, first_id + @as(u32, total) + 1, .chevron_right, "Next page", .ghost);
        count += 1;
    }
    return b.node(0, .{ .direction = .row, .gap = 4 }, .none, pages[0..count]);
}

fn pageButton(b: L.Builder, id: u32, text: []const u8, active: bool) !*L.Element {
    return b.node(id, .{ .width = 36, .height = 36 }, .{ .button = .{ .label = text, .variant = if (active) .outline else .ghost } }, &.{});
}

const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

pub fn calendar(b: L.Builder, first_id: u32, date: Date) !*L.Element {
    return calendarWithWidth(b, first_id, date, 300);
}
/// Month grid. Ids from `first_id`: +1..31 days, +32/+33 previous/next month,
/// +34/+35 earlier/later hour, +36/+37 earlier/later minute, +38/+39 previous/next year.
pub fn calendarWithWidth(b: L.Builder, first_id: u32, date: Date, width: f32) !*L.Element {
    if (!std.math.isFinite(width) or width < 192) return error.InvalidSize;
    const days = try daysInMonth(date);
    if (first_id > std.math.maxInt(u32) - 39) return error.InvalidDate;
    const first = firstWeekday(date.year, date.month);
    const weeks: usize = (@as(usize, first) + days + 6) / 7;
    const children = try b.allocator.alloc(*L.Element, weeks + 3);
    defer b.allocator.free(children);
    const month_label = try std.fmt.allocPrint(b.allocator, "{s} {d}", .{ month_names[date.month - 1], date.year });
    const previous_year = try yearButton(b, first_id + 38, "\u{ab}", "Previous year");
    const previous = try compactIconButton(b, first_id + 32, .chevron_left, "Previous month");
    const next_month = try compactIconButton(b, first_id + 33, .chevron_right, "Next month");
    const next_year = try yearButton(b, first_id + 39, "\u{bb}", "Next year");
    previous.accessibility.disabled = date.year == 1 and date.month == 1;
    previous_year.accessibility.disabled = date.year == 1;
    next_month.accessibility.disabled = date.year == 9999 and date.month == 12;
    next_year.accessibility.disabled = date.year == 9999;
    children[0] = try b.node(0, .{ .height = 36, .direction = .row, .align_items = .center, .gap = 2 }, .none, &.{
        previous_year,
        previous,
        try b.node(0, .{ .grow = 1, .height = 28 }, .{ .text = .{ .value = month_label, .size = 14, .alignment = .center } }, &.{}),
        next_month,
        next_year,
    });
    const weekdays = [_][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };
    const day_width = (width - 24 - 6 * 4) / 7;
    var headings: [7]*L.Element = undefined;
    for (weekdays, 0..) |name, i| headings[i] = try b.node(0, .{ .width = day_width, .height = 24 }, .{ .text = .{ .value = name, .size = 12, .tone = .muted, .alignment = .center } }, &.{});
    children[1] = try b.node(0, .{ .direction = .row, .gap = 4 }, .none, &headings);
    var day: u8 = 1;
    for (0..weeks) |week| {
        var columns: [7]*L.Element = undefined;
        for (&columns, 0..) |*slot, column| {
            const index = week * 7 + column;
            if (index < first or day > days) {
                slot.* = try b.node(0, .{ .width = day_width, .height = 36 }, .none, &.{});
            } else {
                const label_text = try std.fmt.allocPrint(b.allocator, "{d}", .{day});
                slot.* = try b.node(first_id + day, .{ .width = day_width, .height = 36 }, .{ .button = .{ .label = label_text, .variant = if (day == date.day) .default else .ghost } }, &.{});
                day += 1;
            }
        }
        children[week + 2] = try b.node(0, .{ .direction = .row, .gap = 4 }, .none, &columns);
    }
    const clock = try std.fmt.allocPrint(b.allocator, "{d:0>2}:{d:0>2}", .{ date.hour, date.minute });
    children[weeks + 2] = try b.node(0, .{ .direction = .row, .gap = 4, .align_items = .center }, .none, &.{
        try compactIconButton(b, first_id + 34, .chevron_left, "Earlier hour"),
        try compactIconButton(b, first_id + 36, .chevron_left, "Earlier minute"),
        try b.node(0, .{ .grow = 1, .height = 32 }, .{ .text = .{ .value = clock, .alignment = .center } }, &.{}),
        try compactIconButton(b, first_id + 37, .chevron_right, "Later minute"),
        try compactIconButton(b, first_id + 35, .chevron_right, "Later hour"),
    });
    return b.node(0, .{ .width = width, .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 }, .gap = 4 }, .{ .surface = .popover }, children);
}
/// Guillemets tell year steps apart from the single month chevrons.
fn yearButton(b: L.Builder, id: u32, text: []const u8, name: []const u8) !*L.Element {
    const result = try b.node(id, .{ .width = 24, .height = 28 }, .{ .button = .{ .label = text, .variant = .ghost } }, &.{});
    result.accessibility.label = name;
    return result;
}
fn compactIconButton(b: L.Builder, id: u32, icon: Icon, name: []const u8) !*L.Element {
    const result = try iconButton(b, id, icon, name, .ghost);
    result.style = .{ .width = 24, .height = 28, .padding = .{ .left = 2, .right = 2, .top = 4, .bottom = 4 } };
    return result;
}

fn firstWeekday(year: u16, month: u8) u8 {
    const offsets = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const y: i32 = @as(i32, year) - @as(i32, if (month < 3) 1 else 0);
    const sunday: i32 = @mod(y + @divTrunc(y, 4) - @divTrunc(y, 100) + @divTrunc(y, 400) + offsets[month - 1] + 1, 7);
    return @intCast(@mod(sunday + 6, 7));
}

fn daysInMonth(date: Date) !u8 {
    if (date.year == 0 or date.year > 9999 or date.month < 1 or date.month > 12 or date.hour > 23 or date.minute > 59) return error.InvalidDate;
    const days: u8 = @intCast(std.time.epoch.getDaysInMonth(date.year, @enumFromInt(date.month)));
    if (date.day > days) return error.InvalidDate;
    return days;
}
pub fn shiftMonth(date: Date, way: enum { previous, next }) !Date {
    _ = try daysInMonth(date);
    var changed = date;
    switch (way) {
        .previous => {
            if (date.year == 1 and date.month == 1) return error.InvalidDate;
            if (date.month == 1) {
                changed.year -= 1;
                changed.month = 12;
            } else changed.month -= 1;
        },
        .next => {
            if (date.year == 9999 and date.month == 12) return error.InvalidDate;
            if (date.month == 12) {
                changed.year += 1;
                changed.month = 1;
            } else changed.month += 1;
        },
    }
    changed.day = @min(date.day, try daysInMonth(.{ .year = changed.year, .month = changed.month }));
    return changed;
}
pub fn shiftYear(date: Date, way: enum { previous, next }) !Date {
    _ = try daysInMonth(date);
    var changed = date;
    switch (way) {
        .previous => changed.year = std.math.sub(u16, date.year, 1) catch return error.InvalidDate,
        .next => changed.year += 1,
    }
    if (changed.year == 0 or changed.year > 9999) return error.InvalidDate;
    changed.day = @min(date.day, try daysInMonth(.{ .year = changed.year, .month = changed.month }));
    return changed;
}
/// Parse "YYYY-MM-DD" with an optional "HH:MM"; surrounding and separating spaces are ignored.
pub fn parseDate(text: []const u8) !Date {
    var it = std.mem.tokenizeAny(u8, text, "-: \t");
    var fields: [5]u16 = .{ 0, 0, 0, 0, 0 };
    var count: usize = 0;
    while (it.next()) |part| : (count += 1) {
        if (count == fields.len) return error.InvalidDate;
        fields[count] = std.fmt.parseInt(u16, part, 10) catch return error.InvalidDate;
    }
    if (count != 3 and count != 5) return error.InvalidDate;
    if (fields[1] > 12 or fields[2] > 31 or fields[3] > 23 or fields[4] > 59) return error.InvalidDate;
    const date = Date{ .year = fields[0], .month = @intCast(fields[1]), .day = @intCast(fields[2]), .hour = @intCast(fields[3]), .minute = @intCast(fields[4]) };
    _ = try daysInMonth(date);
    if (date.day == 0) return error.InvalidDate;
    return date;
}
pub fn formatDate(allocator: std.mem.Allocator, date: Date) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}  {d:0>2}:{d:0>2}", .{ date.year, date.month, date.day, date.hour, date.minute });
}

pub fn datePicker(b: L.Builder, id: u32, first_day_id: u32, date: Date, open: bool) !*L.Element {
    return datePickerWithWidth(b, id, first_day_id, date, open, 300);
}
pub fn datePickerWithWidth(b: L.Builder, id: u32, first_day_id: u32, date: Date, open: bool, width: f32) !*L.Element {
    _ = try daysInMonth(date);
    if (!std.math.isFinite(width) or width < 192) return error.InvalidSize;
    const label_text = if (date.day == 0) "" else try formatDate(b.allocator, date);
    const input = try b.input(id, .{ .value = label_text, .placeholder = "Pick a date" });
    input.style.width = width;
    input.accessibility.role = .button;
    input.accessibility.expanded = open;
    if (!open) return input;
    const popup = try calendarWithWidth(b, first_day_id, date, width);
    return b.node(0, .{ .width = width }, .none, &.{ input, anchorTo(popup, input, .bottom, 100) });
}
/// Date picker you can type into: `text` is the app-owned field (parse it with `parseDate`),
/// `button_id` opens the calendar below it.
pub fn datePickerInput(b: L.Builder, input_id: u32, button_id: u32, first_day_id: u32, date: Date, text: primitives.Input, open: bool, width: f32) !*L.Element {
    _ = try daysInMonth(date);
    if (!std.math.isFinite(width) or width < 192) return error.InvalidSize;
    var opts = text;
    if (opts.placeholder.len == 0) opts.placeholder = "YYYY-MM-DD HH:MM";
    const input = try b.node(input_id, .{ .grow = 1, .height = 40 }, .{ .input = opts }, &.{});
    input.accessibility.label = "Date";
    const toggle = try iconButton(b, button_id, .calendar, "Open calendar", .outline);
    toggle.style.width = 40;
    toggle.style.height = 40;
    toggle.style.padding = .{ .left = 10, .right = 10, .top = 10, .bottom = 10 };
    toggle.accessibility.expanded = open;
    const row = try b.node(0, .{ .width = width, .direction = .row, .gap = 6 }, .none, &.{ input, toggle });
    if (!open) return row;
    return b.node(0, .{ .width = width }, .none, &.{ row, anchorTo(try calendarWithWidth(b, first_day_id, date, width), row, .bottom, 100) });
}

pub const BubbleOptions = struct {
    alignment: enum { start, end } = .start,
    variant: primitives.Bubble = .muted,
    /// Shown in a pill under the bubble, e.g. "👍 2".
    reactions: []const u8 = "",
};

/// Conversation bubble; `.end` sits on the right like the local user's messages.
pub fn bubble(b: L.Builder, text: []const u8, options: BubbleOptions) !*L.Element {
    const body = try b.node(0, .{ .max_width = 320, .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 8 } }, .{ .bubble = options.variant }, &.{
        try b.node(0, .{}, .{ .text = .{ .value = text, .size = 15, .wrap = true } }, &.{}),
    });
    body.accessibility = .{ .role = .group, .label = text };
    body.children[0].accessibility.role = .ignored;
    const stack = try b.node(0, .{ .gap = 2, .align_items = if (options.alignment == .end) .end else .start, .max_width = 320 }, .none, if (options.reactions.len == 0) &.{body} else &.{
        body,
        try b.node(0, .{ .direction = .row, .justify = if (options.alignment == .end) .end else .start }, .none, &.{try b.node(0, .{ .height = 22 }, .{ .badge = .{ .label = options.reactions, .variant = .outline } }, &.{})}),
    });
    return b.node(0, .{ .direction = .row, .justify = if (options.alignment == .end) .end else .start }, .none, &.{stack});
}

pub const MarkerVariant = enum { default, border, separator };

/// Inline status or system note in a conversation.
pub fn marker(b: L.Builder, text: []const u8, variant: MarkerVariant, icon: ?Icon) !*L.Element {
    const label_node = try b.node(0, .{}, .{ .text = .{ .value = text, .size = 13, .tone = .muted } }, &.{});
    const content = if (icon) |value| try b.node(0, .{ .direction = .row, .gap = 6, .align_items = .center }, .none, &.{
        try b.node(0, .{ .width = 14, .height = 14 }, .{ .icon = value }, &.{}),
        label_node,
    }) else label_node;
    const result = switch (variant) {
        .default => try b.node(0, .{ .direction = .row, .height = 24, .align_items = .center }, .none, &.{content}),
        .separator => try b.node(0, .{ .direction = .row, .height = 24, .gap = 12, .align_items = .center }, .none, &.{
            try b.node(0, .{ .height = 1, .grow = 1 }, .separator, &.{}),
            content,
            try b.node(0, .{ .height = 1, .grow = 1 }, .separator, &.{}),
        }),
        .border => try b.node(0, .{}, .none, &.{
            try b.separator(),
            try b.node(0, .{ .direction = .row, .height = 36, .align_items = .center, .padding = .{ .left = 4 } }, .none, &.{content}),
            try b.separator(),
        }),
    };
    result.accessibility = .{ .role = .status, .label = text };
    return result;
}

pub const Question = struct {
    title: []const u8,
    description: []const u8 = "",
    choices: []const []const u8 = &.{},
    multiple: bool = false,
    optional: bool = false,
    /// Show a free text answer under the choices.
    freeform: bool = false,
};

/// One step of a multi-question form. Ids from `first_id`: +0..15 choices (A..P), +16 the free
/// text input, +17 previous, +18 skip, +19 next (submit on the last step). `selected` is a
/// bit per choice.
pub fn questionnaire(b: L.Builder, first_id: u32, question: Question, index: usize, total: usize, selected: u16, answer: primitives.Input) !*L.Element {
    if (total == 0 or index >= total or question.choices.len > 16 or first_id > std.math.maxInt(u32) - 20) return error.InvalidQuestion;
    var children: std.ArrayList(*L.Element) = .empty;
    defer children.deinit(b.allocator);
    const progress_label = try std.fmt.allocPrint(b.allocator, "Question {d} of {d}", .{ index + 1, total });
    try children.append(b.allocator, try b.node(0, .{}, .{ .text = .{ .value = progress_label, .size = 13, .tone = .muted } }, &.{}));
    const bar = try b.progress(@as(f32, @floatFromInt(index + 1)) / @as(f32, @floatFromInt(total)));
    bar.style.height = 6;
    bar.accessibility.label = progress_label;
    try children.append(b.allocator, bar);
    try children.append(b.allocator, try b.node(0, .{}, .{ .text = .{ .value = question.title, .size = 18, .wrap = true } }, &.{}));
    if (question.description.len > 0) try children.append(b.allocator, try b.node(0, .{}, .{ .text = .{ .value = question.description, .size = 14, .tone = .muted, .wrap = true } }, &.{}));
    const letters = "ABCDEFGHIJKLMNOP";
    for (question.choices, 0..) |choice, i| {
        const on = selected & (@as(u16, 1) << @intCast(i)) != 0;
        const key = try b.node(0, .{ .width = 24, .height = 24 }, .{ .badge = .{ .label = letters[i .. i + 1], .variant = if (on) .default else .outline } }, &.{});
        const row = try b.node(first_id + @as(u32, @intCast(i)), .{ .direction = .row, .gap = 12, .align_items = .center, .height = 44, .padding = .{ .left = 10, .right = 10 } }, .{ .toggle_button = .{ .label = "", .pressed = on } }, &.{
            key,
            try b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = choice, .size = 15 } }, &.{}),
        });
        row.accessibility = .{ .role = if (question.multiple) .checkbox else .radio, .label = choice };
        key.accessibility.role = .ignored;
        row.children[1].accessibility.role = .ignored;
        try children.append(b.allocator, row);
    }
    if (question.freeform) {
        var opts = answer;
        if (opts.placeholder.len == 0) opts.placeholder = "Type your own answer";
        const input = try b.input(first_id + 16, opts);
        input.accessibility.label = "Your answer";
        try children.append(b.allocator, input);
    }
    var actions: std.ArrayList(*L.Element) = .empty;
    defer actions.deinit(b.allocator);
    const previous = try b.buttonVariant(first_id + 17, "Previous", .outline);
    previous.accessibility.disabled = index == 0;
    try actions.append(b.allocator, previous);
    try actions.append(b.allocator, try b.node(0, .{ .grow = 1 }, .none, &.{}));
    if (question.optional) try actions.append(b.allocator, try b.buttonVariant(first_id + 18, "Skip", .ghost));
    try actions.append(b.allocator, try b.buttonVariant(first_id + 19, if (index + 1 == total) "Submit" else "Next", .default));
    try children.append(b.allocator, try b.node(0, .{ .direction = .row, .gap = 8, .padding = .{ .top = 4 } }, .none, actions.items));
    const result = try b.node(0, .{ .gap = 10 }, .none, children.items);
    result.accessibility = .{ .role = .group, .label = question.title };
    return result;
}

const color_editor = @import("components/color_editor.zig");

/// Unreal-style color editor. Ids from `first_id`: +0 wheel, +1/+2 saturation/value bars,
/// +3..+6 R G B A, +7..+9 H S V (see `ColorChannel`), +10 hex linear, +11 hex sRGB, +12 OK,
/// +13 Cancel, +14 the Old swatch (restores), +15.. `swatches`. Route presses on the channel
/// ids to `editor.press(channel, bounds, x, y)`, moves to `dragTo`, and release to `release`.
pub fn colorEditor(b: L.Builder, first_id: u32, editor: color_editor.ColorEditor, hex_linear: primitives.Input, hex_srgb: primitives.Input, swatches: []const @import("types.zig").Color) !*L.Element {
    const wheel = try b.node(first_id, .{ .width = 180, .height = 180 }, .{ .color_wheel = editor }, &.{});
    wheel.accessibility = .{ .role = .slider, .label = "Hue and saturation", .description = "Left and right change hue, up and down saturation" };
    const bar = struct {
        fn make(builder: L.Builder, id: u32, e: color_editor.ColorEditor, channel: color_editor.Channel, name: []const u8) !*L.Element {
            const node = try builder.node(id, .{ .width = 16, .height = 180 }, .{ .color_channel = .{ .editor = e, .channel = channel } }, &.{});
            node.accessibility = .{ .role = .slider, .label = name };
            return node;
        }
    }.make;
    const slider = struct {
        fn make(builder: L.Builder, id: u32, e: color_editor.ColorEditor, channel: color_editor.Channel, text: []const u8, name: []const u8) !*L.Element {
            const node = try builder.node(id, .{ .height = 22 }, .{ .color_channel = .{ .editor = e, .channel = channel, .label = text } }, &.{});
            node.accessibility = .{ .role = .slider, .label = name };
            return node;
        }
    }.make;
    const caption = struct {
        fn make(builder: L.Builder, text: []const u8) !*L.Element {
            return builder.node(0, .{}, .{ .text = .{ .value = text, .size = 12, .tone = .muted } }, &.{});
        }
    }.make;
    const old = try b.node(first_id + 14, .{ .height = 40 }, .{ .swatch = .{ .color = editor.original.toRgb(), .alpha = editor.original_alpha } }, &.{});
    old.accessibility = .{ .role = .button, .label = "Old color", .description = "Restore the color you started with" };
    const new = try b.node(0, .{ .height = 40 }, .{ .swatch = .{ .color = editor.rgb(), .alpha = editor.alpha } }, &.{});
    new.accessibility = .{ .role = .image, .label = "New color" };
    var linear_opts = hex_linear;
    linear_opts.placeholder = "RRGGBBAA";
    var srgb_opts = hex_srgb;
    srgb_opts.placeholder = "RRGGBBAA";
    const linear_input = try b.node(first_id + 10, .{ .grow = 1, .height = 32 }, .{ .input = linear_opts }, &.{});
    linear_input.accessibility.label = "Hex linear";
    const srgb_input = try b.node(first_id + 11, .{ .grow = 1, .height = 32 }, .{ .input = srgb_opts }, &.{});
    srgb_input.accessibility.label = "Hex sRGB";
    const chips = try b.allocator.alloc(*L.Element, swatches.len);
    defer b.allocator.free(chips);
    for (swatches, chips, 0..) |color, *chip, i| {
        const name = try b.allocator.create([7]u8);
        chip.* = try b.node(first_id + 15 + @as(u32, @intCast(i)), .{ .width = 22, .height = 22 }, .{ .swatch = .{ .color = color } }, &.{});
        chip.*.accessibility = .{ .role = .button, .label = @import("types.zig").formatHex(name, color) };
    }
    const values = try b.node(0, .{ .width = 250, .gap = 6 }, .none, &.{
        try b.node(0, .{ .direction = .row }, .none, &.{
            try b.node(0, .{ .grow = 1, .gap = 2 }, .none, &.{ try caption(b, "Old"), old }),
            try b.node(0, .{ .grow = 1, .gap = 2 }, .none, &.{ try caption(b, "New"), new }),
        }),
        try slider(b, first_id + 3, editor, .red, "R", "Red"),
        try slider(b, first_id + 4, editor, .green, "G", "Green"),
        try slider(b, first_id + 5, editor, .blue, "B", "Blue"),
        try slider(b, first_id + 6, editor, .alpha, "A", "Alpha"),
        try slider(b, first_id + 7, editor, .hue, "H", "Hue"),
        try slider(b, first_id + 8, editor, .sat, "S", "Saturation"),
        try slider(b, first_id + 9, editor, .val, "V", "Value"),
        try b.node(0, .{ .direction = .row, .gap = 8, .align_items = .center }, .none, &.{ try b.node(0, .{ .width = 64 }, .{ .text = .{ .value = "Hex Linear", .size = 12, .tone = .muted } }, &.{}), linear_input }),
        try b.node(0, .{ .direction = .row, .gap = 8, .align_items = .center }, .none, &.{ try b.node(0, .{ .width = 64 }, .{ .text = .{ .value = "Hex sRGB", .size = 12, .tone = .muted } }, &.{}), srgb_input }),
    });
    const picker = try b.node(0, .{ .direction = .row, .gap = 12 }, .none, &.{
        wheel,
        try bar(b, first_id + 1, editor, .saturation, "Saturation"),
        try bar(b, first_id + 2, editor, .value, "Value"),
    });
    return b.node(0, .{ .gap = 12 }, .none, &.{
        try b.node(0, .{ .direction = .row, .wrap = true, .gap = 16 }, .none, &.{ picker, values }),
        try b.node(0, .{ .direction = .row, .wrap = true, .gap = 6 }, .none, chips),
        try b.node(0, .{ .direction = .row, .gap = 8, .justify = .end }, .none, &.{
            try b.buttonVariant(first_id + 12, "OK", .default),
            try b.buttonVariant(first_id + 13, "Cancel", .outline),
        }),
    });
}

pub const TypesetOptions = struct {
    /// `chat` tightens sizes and spacing for message bodies.
    density: enum { docs, chat } = .docs,
};

/// Style rendered markdown in one container (shadcn/ui Typeset): `#`-`####` headings,
/// paragraphs, `-`/`*`/`1.` lists, `>` quotes, fenced code, and `|` tables.
// ponytail: block-level only; inline **bold**, _italic_ and links render as plain text (backticks are dropped).
pub fn typeset(b: L.Builder, markdown: []const u8, options: TypesetOptions) !*L.Element {
    const chat = options.density == .chat;
    const body: f32 = if (chat) 15 else 16;
    var blocks: std.ArrayList(*L.Element) = .empty;
    defer blocks.deinit(b.allocator);
    var paragraph_text: std.ArrayList(u8) = .empty;
    var list_items: std.ArrayList([]const u8) = .empty;
    var ordered = false;
    var table_rows: std.ArrayList([]const []const u8) = .empty;
    var code: ?std.ArrayList(u8) = null;
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (true) {
        const raw = lines.next();
        const line = std.mem.trimEnd(u8, raw orelse "", " \r\t");
        if (code) |*block| {
            if (raw == null or std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) {
                const text = try b.node(0, .{}, .{ .text = .{ .value = try block.toOwnedSlice(b.allocator), .size = body - 2, .wrap = true } }, &.{});
                try blocks.append(b.allocator, try b.node(0, .{ .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 } }, .{ .surface = .track }, &.{text}));
                code = null;
                if (raw == null) break;
                continue;
            }
            if (block.items.len > 0) try block.append(b.allocator, '\n');
            try block.appendSlice(b.allocator, line);
            continue;
        }
        const trimmed = std.mem.trimStart(u8, line, " ");
        const bullet = std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ");
        const number = numberedItem(trimmed);
        const table_line = std.mem.startsWith(u8, trimmed, "|");
        // Close whatever block this line does not continue.
        if (paragraph_text.items.len > 0 and (raw == null or trimmed.len == 0 or bullet or number != null or table_line or trimmed[0] == '#' or trimmed[0] == '>' or std.mem.startsWith(u8, trimmed, "```"))) {
            try blocks.append(b.allocator, try b.node(0, .{}, .{ .text = .{ .value = try paragraph_text.toOwnedSlice(b.allocator), .size = body, .wrap = true } }, &.{}));
        }
        if (list_items.items.len > 0 and ((!bullet and number == null) or (number != null) != ordered)) {
            try blocks.append(b.allocator, try markdownList(b, list_items.items, ordered, body));
            list_items.clearRetainingCapacity();
        }
        if (table_rows.items.len > 0 and !table_line) {
            try blocks.append(b.allocator, try table(b, table_rows.items[0], table_rows.items[1..]));
            table_rows.clearRetainingCapacity();
        }
        if (raw == null) break;
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "```")) {
            code = .empty;
        } else if (trimmed[0] == '#') {
            const level = std.mem.indexOfNone(u8, trimmed, "#") orelse trimmed.len;
            const title = std.mem.trimStart(u8, trimmed[level..], " ");
            try blocks.append(b.allocator, try heading(b, @intCast(@min(4, level) + @as(usize, if (chat) 1 else 0)), try stripTicks(b, title)));
        } else if (trimmed[0] == '>') {
            try blocks.append(b.allocator, try blockquote(b, try stripTicks(b, std.mem.trimStart(u8, trimmed[1..], " "))));
        } else if (bullet or number != null) {
            ordered = number != null;
            try list_items.append(b.allocator, try stripTicks(b, if (number) |rest| rest else trimmed[2..]));
        } else if (table_line) {
            var cells: std.ArrayList([]const u8) = .empty;
            var parts = std.mem.splitScalar(u8, std.mem.trim(u8, trimmed, "|"), '|');
            var divider = true;
            while (parts.next()) |part| {
                const cell = std.mem.trim(u8, part, " ");
                if (std.mem.trim(u8, cell, "-: ").len != 0) divider = false;
                try cells.append(b.allocator, try stripTicks(b, cell));
            }
            if (!divider) try table_rows.append(b.allocator, try cells.toOwnedSlice(b.allocator));
        } else {
            if (paragraph_text.items.len > 0) try paragraph_text.append(b.allocator, ' ');
            try paragraph_text.appendSlice(b.allocator, try stripTicks(b, trimmed));
        }
    }
    const result = try b.node(0, .{ .gap = if (chat) 10 else 16 }, .none, blocks.items);
    result.accessibility = .{ .role = .group, .label = "Document" };
    return result;
}
fn numberedItem(line: []const u8) ?[]const u8 {
    const digits = std.mem.indexOfNone(u8, line, "0123456789") orelse return null;
    if (digits == 0 or !std.mem.startsWith(u8, line[digits..], ". ")) return null;
    return line[digits + 2 ..];
}
fn stripTicks(b: L.Builder, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '`') == null) return text;
    const out = try b.allocator.alloc(u8, text.len - std.mem.count(u8, text, "`"));
    var n: usize = 0;
    for (text) |byte| if (byte != '`') {
        out[n] = byte;
        n += 1;
    };
    return out;
}
fn markdownList(b: L.Builder, entries: []const []const u8, ordered: bool, size: f32) !*L.Element {
    const rows = try b.allocator.alloc(*L.Element, entries.len);
    defer b.allocator.free(rows);
    for (entries, rows, 1..) |entry, *row, index| row.* = try b.node(0, .{ .direction = .row, .gap = 10, .padding = .{ .left = 8 } }, .none, &.{
        try b.node(0, .{ .width = if (ordered) 20 else 8 }, .{ .text = .{ .value = if (ordered) try std.fmt.allocPrint(b.allocator, "{d}.", .{index}) else "\u{2022}", .size = size, .tone = .muted } }, &.{}),
        try b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = entry, .size = size, .wrap = true } }, &.{}),
    });
    return b.node(0, .{ .gap = 6 }, .none, rows);
}

/// Right-to-left (or left-to-right) region: rows mirror and start-aligned text moves right.
pub fn textDirection(b: L.Builder, rtl: bool, children: []const *L.Element) !*L.Element {
    return b.node(0, .{ .gap = 12, .rtl = rtl }, .none, children);
}

/// Typography: headings h1-h4 (h2 carries a rule underneath).
pub fn heading(b: L.Builder, level: u3, text: []const u8) !*L.Element {
    const size: f32 = switch (level) {
        1 => 34,
        2 => 26,
        3 => 21,
        4 => 18,
        else => 16,
    };
    const result = try b.node(0, .{}, .{ .text = .{ .value = text, .size = size, .wrap = true } }, &.{});
    result.accessibility.role = .heading;
    if (level != 2) return result;
    return b.node(0, .{ .gap = 8 }, .none, &.{ result, try b.separator() });
}
pub fn paragraph(b: L.Builder, text: []const u8) !*L.Element {
    return b.node(0, .{}, .{ .text = .{ .value = text, .size = 16, .wrap = true } }, &.{});
}
pub fn lead(b: L.Builder, text: []const u8) !*L.Element {
    return b.node(0, .{}, .{ .text = .{ .value = text, .size = 20, .tone = .muted, .wrap = true } }, &.{});
}
pub fn muted(b: L.Builder, text: []const u8) !*L.Element {
    return b.node(0, .{}, .{ .text = .{ .value = text, .size = 14, .tone = .muted, .wrap = true } }, &.{});
}
pub fn blockquote(b: L.Builder, text: []const u8) !*L.Element {
    return b.node(0, .{ .direction = .row, .gap = 16 }, .none, &.{
        try b.node(0, .{ .width = 2 }, .separator, &.{}),
        try b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = text, .size = 16, .tone = .muted, .wrap = true } }, &.{}),
    });
}
pub fn list(b: L.Builder, entries: []const []const u8, ordered: bool) !*L.Element {
    return markdownList(b, entries, ordered, 16);
}
pub fn inlineCode(b: L.Builder, text: []const u8) !*L.Element {
    return b.node(0, .{ .direction = .row }, .none, &.{try b.node(0, .{ .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 } }, .{ .surface = .track }, &.{try b.node(0, .{}, .{ .text = .{ .value = text, .size = 14 } }, &.{})})});
}

test "calendar lays out leap days and rejects invalid dates" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const calendar_root = try calendar(b, 100, .{ .year = 2024, .month = 2, .day = 29 });
    calendar_root.layout(.{ .x = 0, .y = 0, .w = 300, .h = 360 }, &font);
    const leap_day = calendar_root.find(129).?;
    try std.testing.expect(calendar_root.hit(129, leap_day.bounds.center().x, leap_day.bounds.center().y));
    try std.testing.expect(leap_day.bounds.x + leap_day.bounds.w <= calendar_root.bounds.x + calendar_root.bounds.w - 12);
    try std.testing.expect(calendar_root.find(132) != null);
    try std.testing.expect(calendar_root.find(137) != null);
    const january = try shiftMonth(.{ .year = 2024, .month = 12, .day = 31 }, .next);
    try std.testing.expectEqual(@as(u16, 2025), january.year);
    try std.testing.expectEqual(@as(u8, 1), january.month);
    const february = try shiftMonth(.{ .year = 2025, .month = 3, .day = 31 }, .previous);
    try std.testing.expectEqual(@as(u8, 28), february.day);
    try std.testing.expectError(error.InvalidDate, shiftMonth(.{ .year = 1, .month = 1 }, .previous));
    const compact = try calendarWithWidth(b, 200, .{ .year = 2024, .month = 2 }, 192);
    compact.layout(.{ .x = 0, .y = 0, .w = 192, .h = 360 }, &font);
    try std.testing.expect(compact.find(229).?.bounds.x + compact.find(229).?.bounds.w <= compact.bounds.x + compact.bounds.w - 12);
    try std.testing.expect(compact.find(235).?.bounds.x + compact.find(235).?.bounds.w <= compact.bounds.x + compact.bounds.w - 12);
    try std.testing.expectError(error.InvalidSize, calendarWithWidth(b, 200, .{ .year = 2024, .month = 2 }, 180));
    try std.testing.expectEqual(@as(u8, 3), firstWeekday(2024, 2));
    try std.testing.expectEqual(@as(u8, 1), firstWeekday(2026, 9));
    try std.testing.expectError(error.InvalidDate, calendar(b, 100, .{ .year = 2025, .month = 2, .day = 29 }));
    try std.testing.expectError(error.InvalidDate, calendar(b, 100, .{ .year = 2025, .month = 13 }));
    try std.testing.expectError(error.InvalidDate, datePicker(b, 9, 100, .{ .year = 2025, .month = 13 }, false));
}

test "popup and status semantics, message log, and optional table lines" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const anchor = try b.button(1, "Menu");
    const popup = (try dropdownMenu(b, anchor, &.{.{ .id = 2, .label = "Open" }}, 2, true)).?;
    const toast_panel = try dismissibleToastAt(b, .{ .x = 0, .y = 0, .w = 440, .h = 340 }, "Saved", "Done.", 3);
    var scroll: L.ScrollState = .{};
    const messages = try messageScroller(b, .{ .x = 0, .y = 0, .w = 240, .h = 100 }, &scroll, &.{try message(b, "A", "Hello")});
    const root = try b.node(0, .{ .height = 340 }, .none, &.{ anchor, popup, toast_panel, messages });
    root.layout(.{ .x = 0, .y = 0, .w = 440, .h = 340 }, &font);
    const snapshot = try @import("accessibility.zig").collect(arena.allocator(), root, 2);
    var menu_found = false;
    var status_found = false;
    var region_found = false;
    var log_found = false;
    for (snapshot.nodes) |node| switch (node.role) {
        .menu => menu_found = true,
        .status => {
            status_found = true;
            try std.testing.expectEqualStrings("Saved", node.label);
        },
        .region => {
            region_found = true;
            try std.testing.expectEqualStrings("Messages", node.label);
        },
        .log => {
            log_found = true;
            try std.testing.expectEqual(@as(@FieldType(@import("accessibility.zig").Node, "live"), .polite), node.live);
        },
        else => {},
    };
    try std.testing.expect(menu_found and status_found and region_found and log_found);
    try std.testing.expect(popup.bounds.y >= anchor.bounds.y + anchor.bounds.h);
    const plain = try tableWithOptions(b, &.{"Header"}, &.{&.{"Value"}}, .{});
    plain.layout(.{ .x = 0, .y = 0, .w = 200, .h = 80 }, &font);
    const lined = try tableWithOptions(b, &.{"Header"}, &.{&.{"Value"}}, .{ .lines = true });
    lined.layout(.{ .x = 0, .y = 0, .w = 200, .h = 80 }, &font);
    try std.testing.expectEqual(plain.children[0].bounds.y + plain.children[0].bounds.h, plain.children[1].bounds.y);
    try std.testing.expectEqual(lined.children[0].bounds.y + lined.children[0].bounds.h, lined.children[1].bounds.y);
    try std.testing.expectEqual(lined.children[1].bounds.y + 1, lined.children[2].bounds.y);
    try std.testing.expectEqual(@as(f32, 12), lined.children[0].children[0].style.padding.left);
}

test "message scroller finds stable IDs and aligns without unintended follow" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    var state = L.ScrollState{ .auto_scroll = true };
    const first = try b.node(10, .{ .height = 80 }, .none, &.{});
    const second = try b.node(11, .{ .height = 80 }, .none, &.{});
    const third = try b.node(12, .{ .height = 80 }, .none, &.{});
    const region = try messageScroller(b, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, &state, &.{ first, second, third });
    try std.testing.expectError(error.UnlaidOut, scrollToMessage(region, 11, .{}));
    region.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, &font);
    try std.testing.expectEqual(@as(f32, 140), state.offset.y);
    try std.testing.expect(try scrollToMessage(region, 11, .{ .alignment = .start, .margin = 10 }));
    try std.testing.expectEqual(@as(f32, 70), state.offset.y);
    region.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, &font);
    try std.testing.expectEqual(@as(f32, 70), state.offset.y);
    try std.testing.expect(try scrollToMessage(region, 11, .{}));
    try std.testing.expectEqual(@as(f32, 70), state.offset.y);
    try std.testing.expect(try scrollToMessage(region, 12, .{ .alignment = .end }));
    try std.testing.expectEqual(@as(f32, 140), state.offset.y);
    try std.testing.expect(!try scrollToMessage(region, 19, .{}));
    try std.testing.expectError(error.InvalidSize, scrollToMessage(region, 12, .{ .margin = -1 }));
}

test "input suffix and breadcrumb labels fit their painted bounds" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const group = try inputGroup(b, 302, "$", .{ .value = "42" }, "USD");
    group.layout(.{ .x = 0, .y = 0, .w = 400, .h = 40 }, &font);
    try std.testing.expect(group.children[2].bounds.w >= font.inkBounds("USD", 16).w);
    const path = try breadcrumb(b, &.{ .{ .id = 380, .label = "Home" }, .{ .id = 381, .label = "Components" } });
    path.layout(.{ .x = 0, .y = 0, .w = 400, .h = 32 }, &font);
    try std.testing.expect(path.children[2].bounds.w >= font.inkBounds("Components", 14).w);
}

test "composed widgets expose stable hit IDs and invalid input" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const options = [_]Choice{ .{ .id = 7, .label = "Overview" }, .{ .id = 8, .label = "Details" } };
    const root = try tabs(b, &options, 8, &.{ try b.text("First"), try b.text("Second") });
    root.layout(.{ .x = 0, .y = 0, .w = 300, .h = 160 }, &font);
    const selected_tab = root.find(8).?;
    try std.testing.expect(root.hit(8, selected_tab.bounds.center().x, selected_tab.bounds.center().y));
    try std.testing.expectEqualStrings("Second", root.children[1].children[0].paint_kind.text.value);
    const tab_semantics = try @import("accessibility.zig").collect(arena.allocator(), root, 8);
    try std.testing.expectEqual(L.Accessibility.Role.tab_list, tab_semantics.nodes[1].role);
    try std.testing.expectEqual(L.Accessibility.Role.tab_panel, tab_semantics.nodes[4].role);
    try std.testing.expectError(error.InvalidSelection, tabs(b, &options, 9, &.{ try b.text("First"), try b.text("Second") }));
    try std.testing.expectError(error.InvalidTable, table(b, &.{"Name"}, &.{&.{ "Alice", "Extra" }}));
    const data = try dataTable(b, &.{.{ .id = 90, .label = "Name" }}, &.{&.{"Alice"}});
    data.layout(.{ .x = 0, .y = 0, .w = 200, .h = 80 }, &font);
    const header = data.find(90).?;
    try std.testing.expect(data.hit(90, header.bounds.center().x, header.bounds.center().y));
    const table_semantics = try @import("accessibility.zig").collect(arena.allocator(), data, 90);
    try std.testing.expectEqual(L.Accessibility.Role.table, table_semantics.nodes[0].role);
    try std.testing.expectEqual(L.Accessibility.Role.column_header, table_semantics.nodes[2].role);
    try std.testing.expectError(error.InvalidPagination, pagination(b, 30, 3, 2));
    try std.testing.expectError(error.InvalidOtp, inputOtp(b, 40, "1X", 3));
    const screen = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    const overlay = try modal(b, screen, .dialog, &.{try b.button(22, "Continue")});
    overlay.layout(screen, &font);
    try std.testing.expectApproxEqAbs(@as(f32, 160), overlay.children[0].bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 170), overlay.children[0].bounds.y, 0.01);
    const sheet = try modal(b, screen, .sheet, &.{try b.label("Properties")});
    sheet.layout(screen, &font);
    try std.testing.expectApproxEqAbs(@as(f32, 440), sheet.children[0].bounds.x, 0.01);
}

test "dates parse from typed text and years shift with leap-day clamping" {
    const parsed = try parseDate(" 2024-02-29 13:05 ");
    try std.testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 29, .hour = 13, .minute = 5 }, parsed);
    try std.testing.expectEqual(Date{ .year = 1999, .month = 12, .day = 31 }, try parseDate("1999-12-31"));
    try std.testing.expectError(error.InvalidDate, parseDate("2023-02-29"));
    try std.testing.expectError(error.InvalidDate, parseDate("2024-13-01"));
    try std.testing.expectError(error.InvalidDate, parseDate("2024-01"));
    try std.testing.expectError(error.InvalidDate, parseDate("2024-01-01 24:00"));
    try std.testing.expectEqual(@as(u8, 28), (try shiftYear(parsed, .next)).day);
    try std.testing.expectError(error.InvalidDate, shiftYear(.{ .year = 1, .month = 1, .day = 1 }, .previous));
}

test "menubar opens one menu with shortcuts, checks and an open submenu beside its row" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const share = [_]MenuItem{ .{ .id = 20, .label = "Email link" }, .{ .id = 21, .label = "Messages" } };
    const file = [_]MenuItem{
        .{ .id = 10, .label = "New Tab", .shortcut = "Ctrl+T" },
        .{ .kind = .separator },
        .{ .id = 11, .label = "Share", .kind = .submenu, .items = &share },
        .{ .id = 12, .label = "Bookmarks", .kind = .checkbox, .checked = true },
    };
    const root = try b.node(0, .{}, .none, &.{try menubar(b, &.{ .{ .id = 1, .label = "File", .items = &file }, .{ .id = 2, .label = "Edit", .items = &.{} } }, 1, 10, 11)});
    root.layout(.{ .x = 0, .y = 0, .w = 800, .h = 600 }, &font);
    const trigger = root.find(1).?;
    const new_tab = root.find(10).?;
    const share_row = root.find(11).?;
    const email = root.find(20).?;
    try std.testing.expect(new_tab.bounds.y >= trigger.bounds.y + trigger.bounds.h);
    try std.testing.expect(email.bounds.x >= share_row.bounds.x + share_row.bounds.w);
    try std.testing.expect(root.find(2).?.bounds.x > trigger.bounds.x);
    try std.testing.expectEqual(@FieldType(primitives.MenuItem, "indicator").checked, root.find(12).?.paint_kind.menu_item.indicator);
    try std.testing.expect(new_tab.actionable() and root.find(12).?.actionable());
}

test "typeset turns markdown blocks into headings, lists, quotes, code and tables" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const doc = try typeset(b,
        \\# Title
        \\First line
        \\joins the paragraph with `code`.
        \\
        \\- one
        \\- two
        \\1. first
        \\> quoted
        \\```
        \\zig build
        \\```
        \\| Name | Status |
        \\| --- | --- |
        \\| Eggy | Ready |
    , .{});
    doc.layout(.{ .x = 0, .y = 0, .w = 400, .h = 800 }, &font);
    try std.testing.expectEqual(@as(usize, 7), doc.children.len);
    try std.testing.expectEqualStrings("Title", doc.children[0].paint_kind.text.value);
    try std.testing.expectEqualStrings("First line joins the paragraph with code.", doc.children[1].paint_kind.text.value);
    try std.testing.expectEqual(@as(usize, 2), doc.children[2].children.len); // bullets
    try std.testing.expectEqualStrings("1.", doc.children[3].children[0].children[0].paint_kind.text.value);
    try std.testing.expectEqualStrings("zig build", doc.children[5].children[0].paint_kind.text.value);
    try std.testing.expectEqual(L.Accessibility.Role.table, doc.children[6].accessibility.role.?);
    try std.testing.expectEqual(@as(usize, 2), doc.children[6].children.len); // header + one row, divider dropped
}
