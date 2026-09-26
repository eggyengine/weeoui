//! Composed, frame-local widgets. Applications retain all interaction state.
const std = @import("std");
const L = @import("layout.zig");
const primitives = @import("components/primitives.zig");
const Rect = @import("types.zig").Rect;

pub const Choice = struct { id: u32, label: []const u8 };
pub const Section = struct { id: u32, title: []const u8, open: bool = false, content: []const *L.Element = &.{} };
pub const Date = struct { year: u16, month: u8, day: u8 = 0 };
pub const Modal = enum { dialog, alert_dialog, sheet, drawer };

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

pub fn combobox(b: L.Builder, id: u32, query: []const u8, choices: []const Choice, highlighted_id: u32, open: bool) !*L.Element {
    if (!open) {
        const input = try b.input(id, .{ .value = query, .placeholder = "Search..." });
        input.accessibility.expanded = false;
        return input;
    }
    const input = try b.node(id, .{ .height = 40 }, .{ .input = .{ .value = query, .placeholder = "Search..." } }, &.{});
    input.accessibility.expanded = true;
    return b.node(0, .{ .width = 220, .gap = 4 }, .none, &.{
        input,
        try menu(b, choices, highlighted_id),
    });
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
    return popover(b, children);
}
pub fn tooltip(b: L.Builder, text: []const u8) !*L.Element {
    return b.node(0, .{ .width = @max(96, @as(f32, @floatFromInt(text.len)) * 9 + 24), .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 } }, .{ .surface = .tooltip }, &.{try b.label(text)});
}
pub fn toast(b: L.Builder, title: []const u8, description: []const u8) !*L.Element {
    return b.surface(.toast, &.{ try b.label(title), try b.node(0, .{}, .{ .text = .{ .value = description, .tone = .muted, .wrap = true } }, &.{}) });
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
    return b.node(0, .{
        .width = @max(28, @as(f32, @floatFromInt(shortcut.len)) * 9 + 16),
        .height = 28,
        .padding = .{ .left = 8, .right = 8 },
    }, .{ .surface = .tooltip }, &.{try b.node(0, .{}, .{ .text = .{ .value = shortcut, .size = 14 } }, &.{})});
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
    return scrollArea(b, viewport, state, messages);
}

pub fn table(b: L.Builder, headers: []const []const u8, rows: []const []const []const u8) !*L.Element {
    if (headers.len == 0) return error.InvalidTable;
    const children = try b.allocator.alloc(*L.Element, rows.len + 1);
    defer b.allocator.free(children);
    children[0] = try tableRow(b, headers, true);
    for (rows, 0..) |row, i| {
        if (row.len != headers.len) return error.InvalidTable;
        children[i + 1] = try tableRow(b, row, false);
    }
    const result = try b.node(0, .{ .gap = 1 }, .{ .surface = .card }, children);
    result.accessibility.role = .table;
    return result;
}

pub fn dataTable(b: L.Builder, headers: []const Choice, rows: []const []const []const u8) !*L.Element {
    if (headers.len == 0) return error.InvalidTable;
    const labels = try b.allocator.alloc([]const u8, headers.len);
    defer b.allocator.free(labels);
    for (headers, 0..) |header, i| {
        if (header.id == 0) return error.InvalidId;
        labels[i] = header.label;
    }
    const result = try table(b, labels, rows);
    for (headers, 0..) |header, i| {
        result.children[0].children[i].id = header.id;
    }
    return result;
}

fn tableRow(b: L.Builder, values: []const []const u8, heading: bool) !*L.Element {
    const cells = try b.allocator.alloc(*L.Element, values.len);
    defer b.allocator.free(cells);
    for (values, 0..) |value, i| {
        cells[i] = try b.node(0, .{ .min_width = 96, .grow = 1, .height = 36, .padding = .{ .left = 8, .right = 8 } }, .{
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
        if (i > 0) children[i * 2 - 1] = try b.node(0, .{ .width = 12 }, .{ .text = .{ .value = ">", .tone = .muted } }, &.{});
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
        pages[count] = try pageButton(b, first_id, "<", false);
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
        pages[count] = try pageButton(b, first_id + @as(u32, total) + 1, ">", false);
        count += 1;
    }
    return b.node(0, .{ .direction = .row, .gap = 4 }, .none, pages[0..count]);
}

fn pageButton(b: L.Builder, id: u32, text: []const u8, active: bool) !*L.Element {
    return b.node(id, .{ .width = 36, .height = 36 }, .{ .button = .{ .label = text, .primary = active } }, &.{});
}

pub fn calendar(b: L.Builder, first_id: u32, date: Date) !*L.Element {
    const days = try daysInMonth(date);
    if (first_id > std.math.maxInt(u32) - 31) return error.InvalidDate;
    const first = firstWeekday(date.year, date.month);
    const weeks: usize = (@as(usize, first) + days + 6) / 7;
    const children = try b.allocator.alloc(*L.Element, weeks + 2);
    defer b.allocator.free(children);
    const heading = try std.fmt.allocPrint(b.allocator, "{d:0>4}-{d:0>2}", .{ date.year, date.month });
    children[0] = try b.node(0, .{ .height = 32 }, .{ .text = .{ .value = heading } }, &.{});
    const weekdays = [_][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };
    var headings: [7]*L.Element = undefined;
    for (weekdays, 0..) |name, i| headings[i] = try b.node(0, .{ .width = 36, .height = 24 }, .{ .text = .{ .value = name, .size = 12, .tone = .muted } }, &.{});
    children[1] = try b.node(0, .{ .direction = .row, .gap = 4 }, .none, &headings);
    var day: u8 = 1;
    for (0..weeks) |week| {
        var columns: [7]*L.Element = undefined;
        for (&columns, 0..) |*slot, column| {
            const index = week * 7 + column;
            if (index < first or day > days) {
                slot.* = try b.node(0, .{ .width = 36, .height = 36 }, .none, &.{});
            } else {
                const label_text = try std.fmt.allocPrint(b.allocator, "{d}", .{day});
                slot.* = try pageButton(b, first_id + day, label_text, day == date.day);
                day += 1;
            }
        }
        children[week + 2] = try b.node(0, .{ .direction = .row, .gap = 4 }, .none, &columns);
    }
    return b.node(0, .{ .width = 276, .gap = 4 }, .{ .surface = .popover }, children);
}

fn firstWeekday(year: u16, month: u8) u8 {
    const offsets = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const y: i32 = @as(i32, year) - @as(i32, if (month < 3) 1 else 0);
    const sunday: i32 = @mod(y + @divTrunc(y, 4) - @divTrunc(y, 100) + @divTrunc(y, 400) + offsets[month - 1] + 1, 7);
    return @intCast(@mod(sunday + 6, 7));
}

fn daysInMonth(date: Date) !u8 {
    if (date.year == 0 or date.month < 1 or date.month > 12) return error.InvalidDate;
    const days: u8 = @intCast(std.time.epoch.getDaysInMonth(date.year, @enumFromInt(date.month)));
    if (date.day > days) return error.InvalidDate;
    return days;
}

pub fn datePicker(b: L.Builder, id: u32, first_day_id: u32, date: Date, open: bool) !*L.Element {
    _ = try daysInMonth(date);
    const label_text = if (date.day == 0) "" else try std.fmt.allocPrint(b.allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ date.year, date.month, date.day });
    const input = try b.input(id, .{ .value = label_text, .placeholder = "Pick a date" });
    input.accessibility.role = .button;
    input.accessibility.expanded = open;
    if (!open) return input;
    return b.node(0, .{ .width = 276, .gap = 4 }, .none, &.{ input, try calendar(b, first_day_id, date) });
}

test "calendar lays out leap days and rejects invalid dates" {
    var font = try @import("font.zig").Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"), 24);
    defer font.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = L.Builder{ .allocator = arena.allocator() };
    const calendar_root = try calendar(b, 100, .{ .year = 2024, .month = 2, .day = 29 });
    calendar_root.layout(.{ .x = 0, .y = 0, .w = 276, .h = 300 }, &font);
    const leap_day = calendar_root.find(129).?;
    try std.testing.expect(calendar_root.hit(129, leap_day.bounds.center().x, leap_day.bounds.center().y));
    try std.testing.expectEqual(@as(u8, 3), firstWeekday(2024, 2));
    try std.testing.expectEqual(@as(u8, 1), firstWeekday(2026, 9));
    try std.testing.expectError(error.InvalidDate, calendar(b, 100, .{ .year = 2025, .month = 2, .day = 29 }));
    try std.testing.expectError(error.InvalidDate, calendar(b, 100, .{ .year = 2025, .month = 13 }));
    try std.testing.expectError(error.InvalidDate, datePicker(b, 9, 100, .{ .year = 2025, .month = 13 }, false));
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
