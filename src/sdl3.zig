//! SDL3 adapter. Pass every SDL event to `handleEvent`: it feeds input and wires up screen readers.
const std = @import("std");
const builtin = @import("builtin");
const sdl3 = @import("sdl3");
const ui = @import("weeoui");
const Vec2 = ui.Vec2;
const log = std.log.scoped(.window);

pub const RunOptions = struct {
    title: [:0]const u8 = "weeoui",
    width: u32 = 800,
    height: u32 = 600,
    /// Fixed theme, or null to follow the OS light/dark setting live.
    theme: ?ui.Theme = null,
    /// Load the system color emoji font as a fallback.
    emoji: bool = true,
};

/// Open a window and call `frame(state, ctx)` every frame until it is closed: the
/// window, GPU, input, HiDPI and screen-reader plumbing are handled here.
///
///     try weeoui_sdl3.run(init.gpa, init.io, .{ .title = "Counter" }, &count, struct {
///         fn frame(count: *u32, ctx: *ui.Context) !void {
///             ctx.label("Count: {d}", .{count.*});
///             if (ctx.button("Increment")) count.* += 1;
///         }
///     }.frame);
///
/// Needs the Vitellus renderer too (`-Dsdl3 -Dvitellus`).
pub fn run(gpa: std.mem.Allocator, io: std.Io, options: RunOptions, state: anytype, comptime frame: fn (@TypeOf(state), *ui.Context) anyerror!void) !void {
    const vitellus_window = @import("vitellus_sdl3");
    const Painter = @import("weeoui_vitellus").Painter;
    try sdl3.init(.{ .video = true });
    defer sdl3.quit(.{ .video = true });
    var window = vitellus_window.Sdl3Window.init(try sdl3.video.Window.init(options.title, options.width, options.height, .{ .vulkan = true, .resizable = true, .high_pixel_density = true }));
    defer window.deinit();
    var ctx = try ui.Context.init(gpa);
    defer ctx.deinit();
    ctx.name = options.title;
    ctx.theme = options.theme orelse systemTheme();
    if (builtin.abi.isAndroid()) {
        // Android's emoji font is COLRv1, which FreeType can't draw; use the platform's text stack.
        if (options.emoji) if (sdl3.c.SDL_GetAndroidJNIEnv()) |env| {
            ctx.font.platform = @import("android_text.zig").renderer(env);
        };
    } else if (options.emoji) _ = ctx.font.loadSystemEmoji(io);
    // Built while the window has a surface and dropped while backgrounded: Android destroys the
    // surface when the app leaves the screen, and hands out a new one when it returns.
    var painter: ?Painter = null;
    defer if (painter) |*p| p.deinit();
    var background = false;
    var text_input = false;
    var scale: f32 = 1; // UI units per window point
    const start = std.Io.Timestamp.now(io, .awake);
    while (true) {
        if (background) try sdl3.events.wait(); // nothing to draw; sleep until something happens
        while (sdl3.events.poll()) |event| switch (event) {
            .quit, .window_close_requested, .terminating => return,
            .system_theme_changed => if (options.theme == null) {
                ctx.theme = systemTheme();
            },
            .will_enter_background => {
                background = true;
                if (painter) |*p| p.deinit();
                painter = null;
            },
            .did_enter_foreground => background = false,
            else => handleScaledEvent(&ctx, event, scale),
        };
        if (background) continue;
        const logical = try window.window.getSize();
        if (logical.@"0" == 0 or logical.@"1" == 0) {
            sdl3.timer.delayMilliseconds(16); // minimized
            continue;
        }
        // The display's content scale (Windows' 125-200% setting, Android's density, X11's Xft.dpi)
        // that pixel density doesn't already cover: macOS and Wayland come out at 1.
        scale = (window.window.getDisplayScale() catch 1) / (window.window.getPixelDensity() catch 1);
        if (!(scale > 0) or !std.math.isFinite(scale)) scale = 1;
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = @as(f32, @floatFromInt(logical.@"0")) / scale, .h = @as(f32, @floatFromInt(logical.@"1")) / scale };
        const pixels = try pixelSize(window.window);
        ctx.pixel_scale = .{ @as(f32, @floatFromInt(pixels.width)) / viewport.w, @as(f32, @floatFromInt(pixels.height)) / viewport.h };
        ctx.font.dpi_scale = ctx.pixel_scale[0];
        // Lay out inside the safe area so status bars and camera cutouts don't cover the UI.
        const safe = window.window.getSafeArea() catch null;
        ctx.newFrame(if (safe) |r| .{ .x = @as(f32, @floatFromInt(r.x)) / scale, .y = @as(f32, @floatFromInt(r.y)) / scale, .w = @as(f32, @floatFromInt(r.w)) / scale, .h = @as(f32, @floatFromInt(r.h)) / scale } else viewport);
        if (painter == null) {
            painter = try Painter.init(gpa, try window.asWindow(), pixels, &ctx.font);
            ctx.srgb_target = painter.?.srgb();
        }
        ctx.time_ms = @intCast(@max(0, start.untilNow(io, .awake).toMilliseconds()));
        try frame(state, &ctx);
        try painter.?.paint(pixels, &ctx.font, try ctx.render(), viewport, ctx.theme.background);
        // Text events (and Android's on-screen keyboard) only while a text field has focus.
        if (ctx.wants_text != text_input) {
            text_input = ctx.wants_text;
            (if (text_input) sdl3.keyboard.startTextInput(window.window) else sdl3.keyboard.stopTextInput(window.window)) catch {};
        }
        setCursor(ctx.cursor);
    }
}

/// `std_options` for apps: on Android, where stderr goes nowhere, logs go to logcat.
///
///     pub const std_options = weeoui_sdl3.std_options;
pub const std_options: std.Options = if (builtin.abi.isAndroid()) .{ .logFn = logcat } else .{};

fn logcat(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const android_log = struct {
        extern "log" fn __android_log_write(priority: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;
    };
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, format, args) catch blk: {
        buffer[buffer.len - 1] = 0; // truncated
        break :blk buffer[0 .. buffer.len - 1 :0];
    };
    const priority: c_int = switch (level) {
        .err => 6,
        .warn => 5,
        .info => 4,
        .debug => 3,
    };
    _ = android_log.__android_log_write(priority, if (scope == .default) "weeoui" else @tagName(scope), text);
}

/// On Android, SDLActivity loads the app as `libmain.so` and calls `SDL_main` instead of `main`.
/// This exports it, calling `start` with the allocator and `Io` `std.process.Init` would give:
///
///     comptime { weeoui_sdl3.exportAndroidMain(start); }
pub fn exportAndroidMain(comptime start: fn (std.mem.Allocator, std.Io) anyerror!void) void {
    if (!builtin.abi.isAndroid()) return;
    const entry = struct {
        fn sdlMain(_: c_int, _: [*c][*c]u8) callconv(.c) c_int {
            var debug: std.heap.DebugAllocator(.{}) = .init;
            defer _ = debug.deinit();
            const gpa = if (builtin.mode == .Debug) debug.allocator() else std.heap.smp_allocator;
            var threaded: std.Io.Threaded = .init(gpa, .{});
            defer threaded.deinit();
            start(gpa, threaded.io()) catch |err| {
                std.log.err("app exited: {s}", .{@errorName(err)});
                return 1;
            };
            return 0;
        }
    };
    @export(&entry.sdlMain, .{ .name = "SDL_main" });
}

fn pixelSize(window: sdl3.video.Window) !@import("vitellus").Extent2D {
    const size = try window.getSizeInPixels();
    return .{ .width = @intCast(size.@"0"), .height = @intCast(size.@"1") };
}

/// The close/minimize/maximize layout the desktop uses. On Linux this reads GNOME's
/// `button-layout` (what gnome-tweaks edits), then GTK's `gtk-decoration-layout`; macOS and
/// Windows use their fixed conventions.
pub fn buttonLayout(gpa: std.mem.Allocator, io: std.Io) ui.titlebar.Layout {
    const fallback = ui.titlebar.Layout.default(builtin.os.tag);
    if (builtin.os.tag == .macos or builtin.os.tag == .windows) return fallback;
    if (std.process.run(gpa, io, .{ .argv = &.{ "gsettings", "get", "org.gnome.desktop.wm.preferences", "button-layout" }, .stdout_limit = .limited(1024) })) |result| {
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0 and std.mem.indexOfScalar(u8, result.stdout, ':') != null) {
            log.info("title bar buttons from GNOME: {s}", .{std.mem.trim(u8, result.stdout, " \r\n'")});
            return ui.titlebar.Layout.parse(result.stdout, .gnome);
        }
    } else |_| {}
    const home = std.mem.span(std.c.getenv("HOME") orelse return fallback);
    for ([_][]const u8{ "/.config/gtk-4.0/settings.ini", "/.config/gtk-3.0/settings.ini" }) |suffix| {
        const path = std.fmt.allocPrint(gpa, "{s}{s}", .{ home, suffix }) catch continue;
        defer gpa.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 10)) catch continue;
        defer gpa.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), "gtk-decoration-layout")) {
                log.info("title bar buttons from {s}: {s}", .{ path, std.mem.trim(u8, line[eq + 1 ..], " \t\r") });
                return ui.titlebar.Layout.parse(line[eq + 1 ..], .gnome);
            }
        }
    }
    log.info("title bar buttons: platform default", .{});
    return fallback;
}

/// Where a borderless window's title bar and buttons are, for the OS hit test. Keep it at a
/// stable address and refresh it after each layout.
pub const Frame = struct {
    bar: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    buttons: [3]ui.Rect = @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0 }),
    button_count: u8 = 0,
    /// UI units per window point (e.g. 1 / ui scale).
    scale: f32 = 1,
};

/// Replace `window`'s OS decorations with a drawn title bar: presses on `frame.bar` move the
/// window (with the desktop's snapping) and its edges resize it.
pub fn useCustomFrame(window: sdl3.video.Window, frame: *Frame) !void {
    try window.setBordered(false);
    try window.setHitTest(Frame, frameHitTest, frame);
    log.debug("window {d} uses a drawn title bar", .{window.getId() catch 0});
}

fn frameHitTest(window: sdl3.video.Window, area: sdl3.rect.IPoint, frame: ?*Frame) sdl3.video.HitTestResult {
    const f = frame orelse return .normal;
    const size = window.getSize() catch return .normal;
    const s = f.scale;
    const hit = ui.titlebar.hitTest(
        .{ @as(f32, @floatFromInt(size.@"0")) * s, @as(f32, @floatFromInt(size.@"1")) * s },
        f.bar,
        f.buttons[0..f.button_count],
        window.getFlags().maximized,
        @as(f32, @floatFromInt(area.x)) * s,
        @as(f32, @floatFromInt(area.y)) * s,
    );
    return switch (hit) {
        .normal => .normal,
        .drag => .draggable,
        .resize_top_left => .resize_top_left,
        .resize_top => .resize_top,
        .resize_top_right => .resize_top_right,
        .resize_right => .resize_right,
        .resize_bottom_right => .resize_bottom_right,
        .resize_bottom => .resize_bottom,
        .resize_bottom_left => .resize_bottom_left,
        .resize_left => .resize_left,
    };
}

/// Carry out a title bar button: minimize, or toggle maximize. Returns true for close, which
/// the app handles (quit, or dock a panel back).
pub fn windowAction(window: sdl3.video.Window, pressed: ui.titlebar.Button) bool {
    log.info("window {d}: {s}", .{ window.getId() catch 0, if (pressed == .maximize and window.getFlags().maximized) "restore" else @tagName(pressed) });
    switch (pressed) {
        .close => return true,
        .minimize => window.minimize() catch {},
        .maximize => (if (window.getFlags().maximized) window.restore() else window.maximize()) catch {},
    }
    return false;
}

var cursors: [@typeInfo(ui.Cursor).@"enum".fields.len]?sdl3.mouse.Cursor = @splat(null);
var current_cursor: ?ui.Cursor = null;

/// Show `cursor`, creating each system cursor once. Cheap to call every frame.
pub fn setCursor(cursor: ui.Cursor) void {
    if (current_cursor == cursor) return;
    const i = @intFromEnum(cursor);
    if (cursors[i] == null) cursors[i] = sdl3.mouse.Cursor.initSystem(switch (cursor) {
        .default => .default,
        .pointer => .pointer,
        .text => .text,
        .crosshair => .crosshair,
        .move => .move,
        .not_allowed => .not_allowed,
        .ew_resize => .east_west_resize,
        .ns_resize => .north_south_resize,
        .nwse_resize => .northwest_southeast_resize,
        .nesw_resize => .northeast_southwest_resize,
        .progress => .progress,
        .wait => .wait,
    }) catch return;
    sdl3.mouse.set(cursors[i]) catch return;
    current_cursor = cursor;
}

/// The theme matching the OS light/dark setting. Re-read it on `.system_theme_changed`.
pub fn systemTheme() ui.Theme {
    return if (sdl3.video.getSystemTheme() == .dark) ui.Theme.dark else .{};
}

/// Forward an SDL event to a `ui.Context`. The first event from a window also attaches AccessKit to it.
pub fn handleEvent(ctx: *ui.Context, event: sdl3.events.Event) void {
    handleScaledEvent(ctx, event, 1);
}

/// `handleEvent` for a UI drawn `scale` times larger than window points.
fn handleScaledEvent(ctx: *ui.Context, event: sdl3.events.Event, scale: f32) void {
    if (windowOf(event)) |window| {
        if (ctx.accesskit == null and ui.accesskit.supported) {
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
    if (translate(event)) |e| ctx.handle(scaled(e, scale));
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

/// `event` with positions divided by `scale`, for UIs drawn larger than window points.
fn scaled(event: ui.input.Event, scale: f32) ui.input.Event {
    var e = event;
    switch (e) {
        .pointer_move => |*p| p.* = p.scale(1 / scale),
        .pointer_down => |*d| d.position = d.position.scale(1 / scale),
        .pointer_up => |*u| u.position = u.position.scale(1 / scale),
        .wheel => |*w| w.position = w.position.scale(1 / scale),
        else => {},
    }
    return e;
}

/// SDL event to Weeoui input, or null when it isn't input. For apps that route input themselves.
pub fn translate(event: sdl3.events.Event) ?ui.input.Event {
    return switch (event) {
        .mouse_motion => |motion| .{ .pointer_move = Vec2.init(motion.x, motion.y) },
        .mouse_button_down => |down| .{ .pointer_down = .{ .position = Vec2.init(down.x, down.y), .button = button(down.button) orelse return null, .clicks = down.clicks } },
        .mouse_button_up => |up| .{ .pointer_up = .{ .position = Vec2.init(up.x, up.y), .button = button(up.button) orelse return null } },
        .mouse_wheel => |wheel| .{ .wheel = .{ .position = Vec2.init(wheel.x, wheel.y), .delta = wheelDelta(wheel.scroll_x, wheel.scroll_y, sdl3.keyboard.getModState().shiftDown()) } },
        .text_input => |text| .{ .text = text.text },
        .text_editing => |text| .{ .composition = .{ .text = text.text, .cursor = text.start } },
        .key_down => |key_event| .{ .key_down = .{ .key = key(key_event.key orelse return null) orelse return null, .modifiers = modifiers(key_event.mod), .repeat = key_event.repeat } },
        else => null,
    };
}

/// Shift turns a vertical wheel into horizontal scrolling, for mice without a tilt wheel.
fn wheelDelta(x: f32, y: f32, shift: bool) Vec2 {
    return if (shift and x == 0) Vec2.init(y, 0) else Vec2.init(x, y);
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
    if (code == .func12) return .f12;
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
    try std.testing.expectEqual(Vec2.init(-2, 0), wheelDelta(0, -2, true));
    try std.testing.expectEqual(Vec2.init(1, -2), wheelDelta(1, -2, true));
    std.testing.refAllDecls(@This());
}
