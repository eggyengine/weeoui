//! Composed, frame-local widgets. Applications retain all interaction state.
const std = @import("std");
const L = @import("layout.zig");
const primitives = @import("components/primitives.zig");
const Rect = @import("types.zig").Rect;

pub const Choice = struct { id: u32, label: []const u8 };
pub const Section = struct { id: u32, title: []const u8, open: bool = false, content: []const *L.Element = &.{} };
pub const Date = struct { year: u16, month: u8, day: u8 = 0, hour: u8 = 0, minute: u8 = 0 };
pub const Modal = enum { dialog, alert_dialog, sheet, drawer };
pub const TableOptions = struct { lines: bool = false };
pub const MessageScrollOptions = struct {
    alignment: enum { start, center, end, nearest } = .nearest,
    margin: f32 = 0,
};

pub fn field(b: L.Builder, id: u32, name: []const u8, opts: primitives.Input) !*L.Element {
    const input = try b.input(id, opts);
    input.accessibility.label = name;
    return b.node(0, .{ .gap = 8 }, .none, &.{ try b.label(name), input });
}

pub fn inputGroup(b: L.Builder, id: u32, prefix: []const u8, opts: primitives.Input, suffix: []const u8) !*L.Element {
    return b.node(0, .{ .direction = .row, .height = 40, .gap = 8, .align_items = .center }, .none, &.{
        try b.node(0, .{ .width = @as(f32, @floatFromInt(prefix.len)) * 12 }, .{ .text = .{ .value = prefix, .tone = .muted } }, &.{}),
        try b.node(id, .{ .grow = 1, .height = 40 }, .{ .input = opts }, &.{}),
        try b.node(0, .{ .width = @as(f32, @floatFromInt(suffix.len)) * 12 }, .{ .text = .{ .value = suffix, .tone = .muted } }, &.{}),
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

pub fn select(b: L.Builder, id: u32, selected: []const u8, placeholder: []const u8) !*L.Element {
    const result = try b.node(id, .{ .direction = .row, .height = 40, .align_items = .center }, .none, &.{
        try b.node(0, .{ .height = 40, .grow = 1 }, .{ .input = .{ .value = selected, .placeholder = placeholder } }, &.{}),
        try b.icon(.chevron_down),
    });
    result.accessibility = .{ .role = .button, .label = if (selected.len == 0) placeholder else selected };
    result.children[0].accessibility.role = .ignored;
    result.children[1].accessibility.role = .ignored;
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
    }
    const index = selected orelse return error.InvalidSelection;
    const bar = try b.node(0, .{ .direction = .row, .gap = 4 }, .none, children);
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
    for (choices, 0..) |choice, i| children[i] = try b.button(choice.id, choice.label);
    return b.node(0, .{ .direction = .row, .gap = 4 }, .none, children);
}

pub fn menu(b: L.Builder, choices: []const Choice, highlighted_id: u32) !*L.Element {
    if (choices.len == 0) return b.node(0, .{ .width = 220, .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 } }, .{ .surface = .menu }, &.{try b.label("No results")});
    const children = try b.allocator.alloc(*L.Element, choices.len);
    defer b.allocator.free(children);
    for (choices, 0..) |choice, i| {
        children[i] = try b.node(choice.id, .{ .height = 36 }, .{
            .button = .{ .label = choice.label, .primary = false, .hot = choice.id == highlighted_id },
        }, &.{});
        children[i].accessibility.role = .menu_item;
    }
    return b.node(0, .{ .width = 220, .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 }, .gap = 2 }, .{ .surface = .menu }, children);
}

pub fn dropdownMenu(b: L.Builder, anchor: *const L.Element, choices: []const Choice, highlighted_id: u32, open: bool) !?*L.Element {
    if (!open) return null;
    const popup = try menu(b, choices, highlighted_id);
    popup.style.z_index = 100;
    popup.overlay = .{ .anchor = .{ .target = anchor } };
    return popup;
}

pub fn contextMenu(b: L.Builder, point: ?@import("types.zig").Vec2, choices: []const Choice, highlighted_id: u32) !?*L.Element {
    const position = point orelse return null;
    const popup = try menu(b, choices, highlighted_id);
    popup.style.z_index = 200;
    popup.overlay = .{ .point = position };
    return popup;
}

pub fn combobox(b: L.Builder, id: u32, query: []const u8, choices: []const Choice, highlighted_id: u32, open: bool) !*L.Element {
    if (!open) {
        const input = try b.input(id, .{ .value = query, .placeholder = "Search..." });
        input.accessibility.expanded = false;
        return input;
    }
    const input = try b.node(id, .{ .height = 40 }, .{ .input = .{ .value = query, .placeholder = "Search..." } }, &.{});
    input.accessibility.expanded = true;
    const matching = try b.allocator.alloc(Choice, choices.len);
    defer b.allocator.free(matching);
    var count: usize = 0;
    for (choices) |choice| {
        if (!containsIgnoreCase(choice.label, query)) continue;
        matching[count] = choice;
        count += 1;
    }
    const popup = (try dropdownMenu(b, input, matching[0..count], highlighted_id, true)).?;
    return b.node(0, .{ .width = 220, .gap = 4 }, .none, &.{
        input,
        popup,
    });
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

pub fn disclosure(b: L.Builder, id: u32, title: []const u8, open: bool, content: []const *L.Element) !*L.Element {
    const header = try b.node(id, .{ .height = 40 }, .{ .button = .{ .label = title, .primary = false } }, &.{});
    header.accessibility.expanded = open;
    return b.node(0, .{ .gap = 8 }, .none, if (open) &.{ header, try b.node(0, .{ .padding = .{ .left = 12 } }, .none, content) } else &.{header});
}

pub fn accordion(b: L.Builder, sections: []const Section) !*L.Element {
    const children = try b.allocator.alloc(*L.Element, sections.len);
    defer b.allocator.free(children);
    for (sections, 0..) |section, i| children[i] = try disclosure(b, section.id, section.title, section.open, section.content);
    return b.node(0, .{ .gap = 4 }, .none, children);
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
    return b.node(0, .{ .width = viewport.w, .height = viewport.h, .direction = .row }, .none, &.{
        first, try b.node(handle_id, .{ .width = 6, .height = viewport.h }, .skeleton, &.{}), second,
    });
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
    panel.style.z_index = 100;
    panel.overlay = .{ .anchor = .{ .target = anchor } };
    return panel;
}
pub fn hoverCardAt(b: L.Builder, anchor: *const L.Element, children: []const *L.Element) !*L.Element {
    const panel = try hoverCard(b, children);
    panel.style.width = 240;
    panel.style.z_index = 100;
    panel.overlay = .{ .anchor = .{ .target = anchor } };
    return panel;
}
pub fn tooltip(b: L.Builder, text: []const u8) !*L.Element {
    const result = try b.node(0, .{ .width = @max(96, @as(f32, @floatFromInt(text.len)) * 9 + 24), .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 } }, .{ .surface = .tooltip }, &.{try b.label(text)});
    result.accessibility.label = text;
    return result;
}
pub fn tooltipAt(b: L.Builder, anchor: *const L.Element, text: []const u8) !*L.Element {
    const panel = try tooltip(b, text);
    panel.style.z_index = 200;
    panel.overlay = .{ .anchor = .{ .target = anchor } };
    return panel;
}
pub fn toast(b: L.Builder, title: []const u8, description: []const u8) !*L.Element {
    return toastWithAction(b, title, description, null);
}
fn toastWithAction(b: L.Builder, title: []const u8, description: []const u8, action: ?*L.Element) !*L.Element {
    const heading = try b.label(title);
    const details = try b.node(0, .{}, .{ .text = .{ .value = description, .tone = .muted, .wrap = true } }, &.{});
    const result = try b.surface(.toast, if (action) |button| &.{ heading, details, button } else &.{ heading, details });
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
    const panel = try toastWithAction(b, title, description, try b.button(dismiss_id, "Dismiss"));
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
    const heading = try b.label(title);
    const details = try b.node(0, .{}, .{ .text = .{ .value = description, .tone = .muted, .wrap = true } }, &.{});
    return b.surface(.card, if (action) |a| &.{ heading, details, a } else &.{ heading, details });
}
pub fn message(b: L.Builder, author: []const u8, body: []const u8) !*L.Element {
    return b.surface(.popover, &.{ try b.label(author), try b.node(0, .{}, .{ .text = .{ .value = body, .wrap = true } }, &.{}) });
}
pub fn sidebar(b: L.Builder, viewport_height: f32, children: []const *L.Element) !*L.Element {
    if (!std.math.isFinite(viewport_height) or viewport_height <= 0) return error.InvalidSize;
    return b.node(0, .{ .width = 240, .height = viewport_height, .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 }, .gap = 8 }, .{ .surface = .sidebar }, children);
}
pub fn attachment(b: L.Builder, id: u32, filename: []const u8) !*L.Element {
    return b.node(0, .{ .direction = .row, .gap = 8 }, .none, &.{
        try b.button(id, "Choose file"),
        try b.node(0, .{ .grow = 1 }, .{ .text = .{ .value = filename, .tone = .muted } }, &.{}),
    });
}

pub fn kbd(b: L.Builder, shortcut: []const u8) !*L.Element {
    const mac = @import("builtin").os.tag == .macos;
    const label_text = if (mac and std.mem.startsWith(u8, shortcut, "Ctrl+")) shortcut[5..] else shortcut;
    const result = try b.node(0, .{
        .width = @max(48, @as(f32, @floatFromInt(label_text.len)) * 9 + 48),
        .height = 28,
        .padding = .{ .left = 8, .right = 8 },
        .direction = .row,
        .align_items = .center,
        .gap = 4,
    }, .{ .surface = .tooltip }, &.{ try b.icon(if (mac) .command else .keyboard), try b.node(0, .{}, .{ .text = .{ .value = label_text, .size = 14 } }, &.{}) });
    result.accessibility = .{ .role = .group, .label = shortcut };
    return result;
}

pub fn item(b: L.Builder, id: u32, title: []const u8, description: []const u8, leading: ?*L.Element) !*L.Element {
    const content = try b.node(0, .{ .grow = 1, .gap = 2 }, .none, &.{
        try b.label(title),
        try b.node(0, .{}, .{ .text = .{ .value = description, .tone = .muted, .wrap = true } }, &.{}),
    });
    return b.node(id, .{ .direction = .row, .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 }, .gap = 12 }, .none, if (leading) |icon| &.{ icon, content } else &.{content});
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
    }
    return result;
}

fn tableRow(b: L.Builder, values: []const []const u8, heading: bool) !*L.Element {
    const cells = try b.allocator.alloc(*L.Element, values.len);
    defer b.allocator.free(cells);
    for (values, 0..) |value, i| {
        cells[i] = try b.node(0, .{ .min_width = 96, .grow = 1, .height = 36, .padding = .{ .left = 12, .right = 12 } }, .{
            .text = .{ .value = value, .tone = if (heading) .muted else .foreground },
        }, &.{});
        cells[i].accessibility.role = if (heading) .column_header else .cell;
    }
    const row = try b.node(0, .{ .direction = .row }, .none, cells);
    row.accessibility.role = .row;
    return row;
}

pub fn carousel(b: L.Builder, previous_id: u32, next_id: u32, slides: []const *L.Element, selected: usize) !*L.Element {
    if (slides.len == 0 or selected >= slides.len) return error.InvalidSlide;
    const slide = try b.node(0, .{ .grow = 1, .min_width = 160 }, .none, &.{slides[selected]});
    return b.node(0, .{ .direction = .row, .gap = 8 }, .none, &.{
        try iconButton(b, previous_id, .chevron_left, "Previous slide"),
        slide,
        try iconButton(b, next_id, .chevron_right, "Next slide"),
    });
}

fn iconButton(b: L.Builder, id: u32, icon: @import("font.zig").Icon, label: []const u8) !*L.Element {
    const result = try b.node(id, .{ .width = 36, .height = 36, .padding = .{ .left = 6, .top = 6 } }, .{ .button = .{ .label = "", .primary = false } }, &.{try b.icon(icon)});
    result.accessibility.label = label;
    return result;
}

pub fn breadcrumb(b: L.Builder, choices: []const Choice) !*L.Element {
    if (choices.len == 0) return error.EmptyChoices;
    const children = try b.allocator.alloc(*L.Element, choices.len * 2 - 1);
    defer b.allocator.free(children);
    for (choices, 0..) |choice, i| {
        if (i > 0) children[i * 2 - 1] = try b.icon(.chevron_right);
        children[i * 2] = try b.node(choice.id, .{ .width = @max(24, @as(f32, @floatFromInt(choice.label.len)) * 12) }, .{
            .text = .{ .value = choice.label, .tone = if (i + 1 == choices.len) .foreground else .muted },
        }, &.{});
        if (i + 1 < choices.len) children[i * 2].accessibility.role = .button;
    }
    return b.node(0, .{ .direction = .row, .height = 32, .gap = 4 }, .none, children);
}

pub fn pagination(b: L.Builder, first_id: u32, current: u16, total: u16) !*L.Element {
    if (total == 0 or current == 0 or current > total or first_id > std.math.maxInt(u32) - @as(u32, total) - 1) return error.InvalidPagination;
    var pages: [7]*L.Element = undefined;
    var count: usize = 0;
    if (current > 1) {
        pages[count] = try iconButton(b, first_id, .chevron_left, "Previous page");
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
        pages[count] = try iconButton(b, first_id + @as(u32, total) + 1, .chevron_right, "Next page");
        count += 1;
    }
    return b.node(0, .{ .direction = .row, .gap = 4 }, .none, pages[0..count]);
}

fn pageButton(b: L.Builder, id: u32, text: []const u8, active: bool) !*L.Element {
    return b.node(id, .{ .width = 36, .height = 36 }, .{ .button = .{ .label = text, .primary = active } }, &.{});
}

pub fn calendar(b: L.Builder, first_id: u32, date: Date) !*L.Element {
    return calendarWithWidth(b, first_id, date, 300);
}
pub fn calendarWithWidth(b: L.Builder, first_id: u32, date: Date, width: f32) !*L.Element {
    if (!std.math.isFinite(width) or width < 192) return error.InvalidSize;
    const days = try daysInMonth(date);
    if (first_id > std.math.maxInt(u32) - 37) return error.InvalidDate;
    const first = firstWeekday(date.year, date.month);
    const weeks: usize = (@as(usize, first) + days + 6) / 7;
    const children = try b.allocator.alloc(*L.Element, weeks + 3);
    defer b.allocator.free(children);
    const heading = try std.fmt.allocPrint(b.allocator, "{d:0>4}-{d:0>2}", .{ date.year, date.month });
    const previous = try iconButton(b, first_id + 32, .chevron_left, "Previous month");
    const next_month = try iconButton(b, first_id + 33, .chevron_right, "Next month");
    previous.accessibility.disabled = date.year == 1 and date.month == 1;
    next_month.accessibility.disabled = date.year == 9999 and date.month == 12;
    children[0] = try b.node(0, .{ .height = 36, .direction = .row, .align_items = .center }, .none, &.{
        previous,
        try b.node(0, .{ .width = width - 24 - 72, .height = 28 }, .{ .text = .{ .value = heading, .alignment = .center } }, &.{}),
        next_month,
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
                slot.* = try pageButton(b, first_id + day, label_text, day == date.day);
                slot.*.style.width = day_width;
                day += 1;
            }
        }
        children[week + 2] = try b.node(0, .{ .direction = .row, .gap = 4 }, .none, &columns);
    }
    const clock = try std.fmt.allocPrint(b.allocator, "{d:0>2}:{d:0>2}", .{ date.hour, date.minute });
    children[weeks + 2] = try b.node(0, .{ .direction = .row, .gap = 4, .align_items = .center }, .none, &.{
        try compactIconButton(b, first_id + 34, .chevron_left, "Earlier hour"),
        try compactIconButton(b, first_id + 36, .chevron_left, "Earlier minute"),
        try b.node(0, .{ .width = width - 24 - 4 * 24 - 4 * 4, .height = 32 }, .{ .text = .{ .value = clock, .alignment = .center } }, &.{}),
        try compactIconButton(b, first_id + 37, .chevron_right, "Later minute"),
        try compactIconButton(b, first_id + 35, .chevron_right, "Later hour"),
    });
    return b.node(0, .{ .width = width, .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 }, .gap = 4 }, .{ .surface = .popover }, children);
}
fn compactIconButton(b: L.Builder, id: u32, icon: @import("font.zig").Icon, name: []const u8) !*L.Element {
    const result = try iconButton(b, id, icon, name);
    result.style = .{ .width = 24, .height = 28, .padding = .{ .left = 2, .top = 4 } };
    result.children[0].style.width = 20;
    result.children[0].style.height = 20;
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
pub fn shiftMonth(date: Date, direction: enum { previous, next }) !Date {
    _ = try daysInMonth(date);
    var changed = date;
    switch (direction) {
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

pub fn datePicker(b: L.Builder, id: u32, first_day_id: u32, date: Date, open: bool) !*L.Element {
    return datePickerWithWidth(b, id, first_day_id, date, open, 300);
}
pub fn datePickerWithWidth(b: L.Builder, id: u32, first_day_id: u32, date: Date, open: bool, width: f32) !*L.Element {
    _ = try daysInMonth(date);
    if (!std.math.isFinite(width) or width < 192) return error.InvalidSize;
    const label_text = if (date.day == 0) "" else try std.fmt.allocPrint(b.allocator, "{d:0>4}-{d:0>2}-{d:0>2}  {d:0>2}:{d:0>2}", .{ date.year, date.month, date.day, date.hour, date.minute });
    const input = try b.input(id, .{ .value = label_text, .placeholder = "Pick a date" });
    input.style.width = width;
    input.accessibility.role = .button;
    input.accessibility.expanded = open;
    if (!open) return input;
    const popup = try calendarWithWidth(b, first_day_id, date, width);
    popup.style.z_index = 100;
    popup.overlay = .{ .anchor = .{ .target = input } };
    return b.node(0, .{ .width = width }, .none, &.{ input, popup });
}

test "calendar lays out leap days and rejects invalid dates" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
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
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
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
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
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
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const group = try inputGroup(b, 302, "$", .{ .value = "42" }, "USD");
    group.layout(.{ .x = 0, .y = 0, .w = 400, .h = 40 }, &font);
    try std.testing.expect(group.children[2].bounds.w >= font.inkBounds("USD", 16).w);
    const path = try breadcrumb(b, &.{ .{ .id = 380, .label = "Home" }, .{ .id = 381, .label = "Components" } });
    path.layout(.{ .x = 0, .y = 0, .w = 400, .h = 32 }, &font);
    try std.testing.expect(path.children[2].bounds.w >= font.inkBounds("Components", 16).w);
}

test "composed widgets expose stable hit IDs and invalid input" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
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
    const heading = data.find(90).?;
    try std.testing.expect(data.hit(90, heading.bounds.center().x, heading.bounds.center().y));
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
