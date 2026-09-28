//! SDL3 adapter. Pass every SDL event to `handleEvent`: it feeds input and wires up screen readers.
const std = @import("std");
const builtin = @import("builtin");
const sdl3 = @import("sdl3");
const ui = @import("weeoui");
const Vec2 = ui.Vec2;

/// Forward an SDL event to a `ui.Context`. The first event from a window also attaches AccessKit to it.
pub fn handleEvent(ctx: *ui.Context, event: sdl3.events.Event) void {
    if (windowOf(event)) |window| {
        if (ctx.accesskit == null) {
            if (accessKitWindow(window)) |native| {
                ctx.attachAccessibility(native) catch |err| std.log.warn("screen reader support unavailable: {s}", .{@errorName(err)});
            } else |err| std.log.warn("screen reader support unavailable: {s}", .{@errorName(err)});
            if (ctx.accesskit) |adapter| syncWindowBounds(adapter, window);
        }
        if (ctx.accesskit) |adapter| switch (event) {
            .window_focus_gained => adapter.setFocused(true),
            .window_focus_lost => adapter.setFocused(false),
            .window_moved, .window_resized, .window_shown => syncWindowBounds(adapter, window),
            else => {},
        };
    }
    if (translate(event)) |e| ctx.handle(e);
}

/// The native handle AccessKit needs for `window`, for apps that manage their own `accesskit.Adapter`.
pub fn accessKitWindow(window: sdl3.video.Window) !ui.accesskit.Window {
    const props = try window.getProperties();
    return switch (builtin.os.tag) {
        .windows => .{ .win32 = (props.win32_hwnd orelse return error.NoNativeWindow).value orelse return error.NoNativeWindow },
        .macos => .{ .cocoa = .{ .window = (props.cocoa_window orelse return error.NoNativeWindow).value orelse return error.NoNativeWindow, .class_name = "SDL3Window" } },
        else => .unix,
    };
}

/// Tell AccessKit where `window` is on screen. Only X11 needs it; elsewhere this does nothing.
pub fn syncWindowBounds(adapter: *ui.accesskit.Adapter, window: sdl3.video.Window) void {
    if (builtin.os.tag != .linux) return;
    const props = window.getProperties() catch return;
    if (props.x11_window == null) return;
    const position = window.getPosition() catch return;
    const size = window.getSize() catch return;
    const borders = window.getBordersSize() catch return;
    const inner = ui.Rect{ .x = @floatFromInt(position.@"0"), .y = @floatFromInt(position.@"1"), .w = @floatFromInt(size.@"0"), .h = @floatFromInt(size.@"1") };
    const outer = ui.Rect{
        .x = inner.x - @as(f32, @floatFromInt(borders.left)),
        .y = inner.y - @as(f32, @floatFromInt(borders.top)),
        .w = inner.w + @as(f32, @floatFromInt(borders.left + borders.right)),
        .h = inner.h + @as(f32, @floatFromInt(borders.top + borders.bottom)),
    };
    adapter.setWindowBounds(outer, inner);
}

fn windowOf(event: sdl3.events.Event) ?sdl3.video.Window {
    const id: ?sdl3.video.WindowId = switch (event) {
        inline else => |payload| blk: {
            const T = @TypeOf(payload);
            if (T == sdl3.events.Window) break :blk payload.id;
            if (@typeInfo(T) == .@"struct" and @hasField(T, "window_id")) break :blk payload.window_id;
            break :blk null;
        },
    };
    return sdl3.video.Window.fromId(id orelse return null) catch null;
}

/// SDL event to Weeoui input, or null when it isn't input. For apps that route input themselves.
pub fn translate(event: sdl3.events.Event) ?ui.input.Event {
    return switch (event) {
        .mouse_motion => |motion| .{ .pointer_move = Vec2.init(motion.x, motion.y) },
        .mouse_button_down => |down| .{ .pointer_down = .{ .position = Vec2.init(down.x, down.y), .button = button(down.button) orelse return null, .clicks = down.clicks } },
        .mouse_button_up => |up| .{ .pointer_up = .{ .position = Vec2.init(up.x, up.y), .button = button(up.button) orelse return null } },
        .mouse_wheel => |wheel| .{ .wheel = .{ .position = Vec2.init(wheel.x, wheel.y), .delta = Vec2.init(wheel.scroll_x, wheel.scroll_y) } },
        .text_input => |text| .{ .text = text.text },
        .text_editing => |text| .{ .composition = .{ .text = text.text, .cursor = text.start } },
        .key_down => |key_event| .{ .key_down = .{ .key = key(key_event.key orelse return null) orelse return null, .modifiers = modifiers(key_event.mod), .repeat = key_event.repeat } },
        else => null,
    };
}

fn button(value: sdl3.mouse.Button) ?ui.input.Button {
    return switch (value) {
        .left => .left,
        .middle => .middle,
        .right => .right,
        else => null,
    };
}

fn modifiers(mod: sdl3.keycode.KeyModifier) ui.input.Modifiers {
    return .{ .shift = mod.shiftDown(), .control = mod.controlDown(), .alt = mod.altDown(), .super = mod.guiDown() };
}

fn key(code: sdl3.keycode.Keycode) ?ui.input.Key {
    if (code == .return_key or code == .kp_enter) return .enter;
    inline for (@typeInfo(ui.input.Key).@"enum".fields) |field| {
        if (comptime @hasField(sdl3.keycode.Keycode, field.name)) {
            if (code == @field(sdl3.keycode.Keycode, field.name)) return @field(ui.input.Key, field.name);
        }
    }
    return null;
}

test "SDL events become Weeoui input" {
    const down = translate(.{ .mouse_button_down = .{ .common = .{ .timestamp = 0 }, .button = .left, .down = true, .clicks = 2, .x = 10, .y = 20 } }).?;
    try std.testing.expectEqual(@as(u8, 2), down.pointer_down.clicks);
    try std.testing.expectEqual(@as(f32, 20), down.pointer_down.position.y);
    try std.testing.expectEqual(ui.input.Key.enter, key(.kp_enter).?);
    try std.testing.expectEqual(ui.input.Key.page_down, key(.page_down).?);
    std.testing.refAllDecls(@This());
}
