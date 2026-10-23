//! The full component gallery as a docked editor: every widget, docking, floating panels and
//! DevTools (F12) in one window. Built on the lower-level `Layout` API, so this file wires SDL
//! input to `Demo` itself instead of using `weeoui_sdl3.run`.
//! Run with `zig build gallery -Dsdl3 -Dvitellus`, or build it for the browser (WebGPU) with
//! `-Dtarget=wasm32-emscripten`: zig-out/web/gallery.html.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("weeoui");
const vit = @import("vitellus");
const weeoui_sdl3 = @import("weeoui_sdl3");
const sdl_adapter = @import("vitellus_sdl3");
const Painter = @import("weeoui_vitellus").Painter;
const Demo = @import("demo.zig").Demo;
const sdl3 = sdl_adapter.sdl;

const web = builtin.os.tag == .emscripten;

comptime {
    _ = sdl_adapter.main_callbacks;
}

pub const _start = void;
pub const WinMainCRTStartup = void;
pub const std_options: std.Options = .{ .logFn = ui.devtools.logFn };
pub const panic = vit.web.panic;

/// Vertex budget per frame; DevTools and the gallery together need well over 30k.
const max_vertices = 250_000;

const App = struct {
    gpa: std.mem.Allocator,
    window: sdl_adapter.Sdl3Window,
    painter: Painter,
    font: ui.Font,
    /// On the heap: `Demo` is large, and Debug builds keep copies of by-value results on the stack.
    demo: *Demo,
    vertices: []ui.Vertex,
    /// Title bar geometry for the OS hit test; SDL keeps a pointer to it.
    frame: *weeoui_sdl3.Frame,
    system_theme: ui.Theme,
    viewport: ui.Rect,
    /// Input changed the demo since its last layout; hit tests lay it out again first.
    layout_dirty: bool = true,
    text_input: bool = false,
    last_ns: u64 = 0,

    fn init(gpa: std.mem.Allocator, io: std.Io) !*App {
        try sdl3.init(.{ .video = true });
        errdefer sdl3.quit(.{ .video = true });
        var window = sdl_adapter.Sdl3Window.init(try sdl3.video.Window.init("weeoui gallery", 1280, 800, .{ .vulkan = !web, .resizable = true, .high_pixel_density = true }));
        errdefer window.deinit();
        var font = try ui.Font.init(gpa, ui.default_font);
        errdefer font.deinit();
        // A page can't read the OS emoji font, so the browser draws emoji for us.
        if (web) font.platform = ui.web.textRenderer() else _ = font.loadSystemEmoji(io);
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        const demo = try gpa.create(Demo);
        errdefer gpa.destroy(demo);
        // The browser page is the window: no title bar, and pop-outs float inside it.
        demo.* = .{ .docked = true, .custom_frame = !web };
        demo.dock.os_windows = false;
        if (!web) demo.frame_layout = weeoui_sdl3.buttonLayout(gpa, io);
        demo.dock.buttons = demo.frame_layout;
        const frame = try gpa.create(weeoui_sdl3.Frame);
        errdefer gpa.destroy(frame);
        frame.* = .{};
        if (demo.custom_frame) weeoui_sdl3.useCustomFrame(window.window, frame) catch |err| {
            std.log.warn("custom title bar unavailable: {s}", .{@errorName(err)});
            demo.custom_frame = false;
        };
        const pixels = try window.window.getSizeInPixels();
        const extent = vit.Extent2D{ .width = @intCast(@max(1, pixels.@"0")), .height = @intCast(@max(1, pixels.@"1")) };
        var painter = try Painter.init(gpa, try window.asWindow(), extent, &font);
        errdefer painter.deinit();
        const vertices = try gpa.alloc(ui.Vertex, max_vertices);
        app.* = .{
            .gpa = gpa,
            .window = window,
            .painter = painter,
            .font = font,
            .demo = demo,
            .vertices = vertices,
            .frame = frame,
            .system_theme = weeoui_sdl3.systemTheme(),
            .viewport = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .last_ns = sdl3.timer.getNanosecondsSinceInit(),
        };
        try app.syncSize();
        return app;
    }

    fn deinit(self: *App) void {
        const gpa = self.gpa;
        self.painter.deinit();
        self.demo.deinit();
        gpa.destroy(self.demo);
        gpa.destroy(self.frame);
        gpa.free(self.vertices);
        self.font.deinit();
        self.window.deinit();
        sdl3.quit(.{ .video = true });
        gpa.destroy(self);
    }

    fn syncSize(self: *App) !void {
        const logical = try self.window.window.getSize();
        const pixels = try self.window.window.getSizeInPixels();
        if (logical.@"0" == 0 or logical.@"1" == 0) return;
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = @as(f32, @floatFromInt(logical.@"0")) / self.demo.ui_scale, .h = @as(f32, @floatFromInt(logical.@"1")) / self.demo.ui_scale };
        if (std.meta.eql(viewport, self.viewport)) return;
        self.viewport = viewport;
        // Phones get the single-column gallery; panels need room.
        self.demo.docked = viewport.w >= 720;
        self.font.dpi_scale = @as(f32, @floatFromInt(pixels.@"0")) / self.viewport.w;
        self.layout_dirty = true;
    }

    /// Bring hit-test rectangles up to date before input reads them.
    fn ensureLayout(self: *App) !void {
        if (!self.layout_dirty) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        try self.demo.relayout(arena.allocator(), self.viewport, &self.font);
        self.layout_dirty = false;
    }

    fn theme(self: *const App) ui.Theme {
        var t: ui.Theme = switch (self.demo.appearance) {
            .system => self.system_theme,
            .light => .{},
            .dark => ui.Theme.dark,
        };
        if (self.demo.custom_accent) {
            const accent = self.demo.color.rgb();
            t.primary = accent;
            t.primary_foreground = ui.onColor(accent);
            t.ring = accent;
        }
        return t;
    }

    fn iterate(self: *App) !sdl3.AppResult {
        const now = sdl3.timer.getNanosecondsSinceInit();
        const dt = @as(f32, @floatFromInt(now - self.last_ns)) / std.time.ns_per_s;
        self.last_ns = now;
        self.demo.animation_phase = @mod(self.demo.animation_phase + @min(dt, 0.25) / 1.2, 1);
        self.demo.tickScroll(dt);
        // The window size, or the UI scale slider (by drag, click or keys), may have changed it.
        try self.syncSize();
        if (web) {
            var buffer: [4096]u8 = undefined;
            if (ui.web.takePaste(&buffer)) |text| if (self.demo.isEditing()) {
                _ = self.demo.insertText(text);
                self.layout_dirty = true;
            };
            if (ui.web.takePickedFile(&buffer)) |picked| {
                switch (picked) {
                    .file => |name| self.demo.selectedFile(name),
                    .cancelled => self.demo.fileCancelled(),
                }
                self.layout_dirty = true;
            }
        }
        const pixels = try self.window.window.getSizeInPixels();
        if (pixels.@"0" == 0 or pixels.@"1" == 0) return .run; // minimized
        const extent = vit.Extent2D{ .width = @intCast(pixels.@"0"), .height = @intCast(pixels.@"1") };
        const t = self.theme();
        var canvas = ui.Canvas.init(self.vertices, &self.font);
        canvas.theme = t;
        canvas.srgb_target = self.painter.srgb();
        canvas.pixel_scale = .{ @as(f32, @floatFromInt(extent.width)) / self.viewport.w, @as(f32, @floatFromInt(extent.height)) / self.viewport.h };
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        try self.drawViewport(&canvas, try self.demo.draw(arena.allocator(), &canvas, self.viewport));
        self.layout_dirty = false;
        const rects = self.demo.frames[0];
        self.frame.* = .{ .bar = rects.bar, .buttons = rects.buttons, .button_count = rects.count, .controls = rects.controls, .popup_open = self.demo.popupOpen(), .scale = 1 / self.demo.ui_scale };
        const flags = self.window.window.getFlags();
        self.demo.window_state[0] = .{ .maximized = flags.maximized, .focused = flags.input_focus };
        try self.painter.paint(extent, &self.font, self.vertices[0..canvas.len], self.viewport, t.background);
        weeoui_sdl3.setCursor(self.demo.pointerCursor());
        return .run;
    }

    fn paste(self: *App) void {
        if (!sdl3.clipboard.hasText()) return;
        const copied = sdl3.clipboard.getText() catch return;
        defer sdl3.free(copied);
        _ = self.demo.insertText(copied);
    }

    /// Stands in for an engine's renderer in the Scene panel. It goes between the docked layer
    /// and the overlays (`split`), where Eggy draws its 3D view, so menus and floating panels stay on top.
    fn drawViewport(self: *App, canvas: *ui.Canvas, split: usize) !void {
        const r = self.demo.scene_clip;
        if (r.w < 48 or r.h < 48) return;
        const overlays = try self.gpa.dupe(ui.Vertex, canvas.items()[split..]);
        defer self.gpa.free(overlays);
        canvas.len = split;
        canvas.clip = r;
        defer canvas.clip = null;
        const v = self.demo.scene_viewport;
        const c = v.center();
        const size = @min(v.w, v.h) * 0.3;
        try canvas.triangle(.{ .{ c.x, c.y - size }, .{ c.x + size * 0.87, c.y + size * 0.5 }, .{ c.x - size * 0.87, c.y + size * 0.5 } }, .{ .{ 0.95, 0.7, 0.2, 1 }, .{ 0.85, 0.25, 0.36, 1 }, .{ 0.18, 0.61, 0.88, 1 } });
        try canvas.textIn(.{ .x = v.x, .y = v.y + v.h - 48, .w = v.w, .h = 24 }, "Your renderer draws here", 13, canvas.theme.muted_foreground, .center);
        if (canvas.len + overlays.len > self.vertices.len) return error.OutOfVertices;
        @memcpy(self.vertices[canvas.len..][0..overlays.len], overlays);
        canvas.len += overlays.len;
    }

    fn event(self: *App, curr_event: sdl3.events.Event) !sdl3.AppResult {
        // Handlers hit-test against the layout, so apply what earlier events changed.
        try self.ensureLayout();
        const demo = self.demo;
        const font = &self.font;
        const scale = demo.ui_scale;
        // Fingers: tap on release, swipe to scroll, hold for the right-click menu.
        if (weeoui_sdl3.fromTouch(curr_event)) {
            switch (curr_event) {
                .mouse_button_down => |e| demo.touchDown(e.x / scale, e.y / scale, font),
                .mouse_motion => |e| demo.touchMove(e.x / scale, e.y / scale, font),
                .mouse_button_up => demo.touchUp(font),
                else => {},
            }
            self.layout_dirty = true;
        } else if (weeoui_sdl3.translate(curr_event)) |ui_event| switch (ui_event) {
            .pointer_move => |p| {
                // Moving the pointer only changes hit targets when it opens or closes a hover
                // popup; laying out on every motion event is what made dragging lag.
                const popups = .{ demo.hover_card_open, demo.tooltip_open };
                demo.pointerMoveAt(p.x / scale, p.y / scale, font);
                if (popups[0] != demo.hover_card_open or popups[1] != demo.tooltip_open) self.layout_dirty = true;
            },
            .pointer_down => |button| {
                switch (button.button) {
                    .left => demo.pointerDownWithClicks(button.position.x / scale, button.position.y / scale, font, button.clicks),
                    .right => demo.pointerContextDown(button.position.x / scale, button.position.y / scale),
                    .middle => demo.pointerMiddleDown(button.position.x / scale, button.position.y / scale),
                }
                self.layout_dirty = true;
            },
            .pointer_up => |button| if (button.button == .left) {
                // The release point decides where a dragged dock tab lands.
                demo.pointer_x = button.position.x / scale;
                demo.pointer_y = button.position.y / scale;
                demo.pointerUp();
                self.layout_dirty = true;
            },
            .wheel => |wheel| demo.scrollWheel(wheel.position.x / scale, wheel.position.y / scale, wheel.delta.x, wheel.delta.y),
            .text => |text| {
                if (!demo.insertText(text)) _ = demo.menuTypeAhead(text);
                self.layout_dirty = true;
            },
            .composition => |text| {
                demo.setComposition(text.text, text.cursor);
                self.layout_dirty = true;
            },
            .key_down => |key| {
                try self.keyDown(key);
                self.layout_dirty = true;
            },
        } else switch (curr_event) {
            .quit, .terminating, .window_close_requested => return .success,
            .window_resized, .window_pixel_size_changed, .window_display_scale_changed => try self.syncSize(),
            .system_theme_changed => self.system_theme = weeoui_sdl3.systemTheme(),
            .user => |user| if (user.code == file_event_code) {
                const chosen: *FileChoice = @ptrCast(@alignCast(user.data1.?));
                defer std.heap.c_allocator.destroy(chosen);
                if (chosen.len) |len| demo.selectedFile(chosen.name[0..len]) else demo.fileCancelled();
                self.layout_dirty = true;
            },
            else => {},
        }
        if (demo.window_request) |request| {
            demo.window_request = null;
            if (weeoui_sdl3.windowAction(self.window.window, request.button)) return .success;
        }
        // Cut, Copy and Paste from the right-click text menu.
        if (demo.clipboard_request) |request| {
            demo.clipboard_request = null;
            switch (request) {
                .copy, .cut => if (demo.selectedText()) |text| {
                    copyText(text);
                    if (request == .cut) demo.cutSelection();
                },
                .paste => if (web) ui.web.requestPaste() else self.paste(),
            }
            self.layout_dirty = true;
        }
        if (demo.file_request) {
            demo.file_request = false;
            if (web) ui.web.pickFile() else sdl3.dialog.showOpenFile(anyopaque, fileChosen, null, self.window.window, null, null, false);
        }
        const editing = demo.isEditing();
        if (editing != self.text_input) {
            (if (editing) sdl3.keyboard.startTextInput(self.window.window) else sdl3.keyboard.stopTextInput(self.window.window)) catch {};
            self.text_input = editing;
        }
        return .run;
    }

    fn keyDown(self: *App, key: anytype) !void {
        const demo = self.demo;
        const font = &self.font;
        const code = key.key;
        const command = if (builtin.os.tag == .macos) key.modifiers.super else key.modifiers.control;
        const extend = key.modifiers.shift;
        const word = key.modifiers.control or (builtin.os.tag == .macos and key.modifiers.alt);
        // The IME owns navigation until its preedit is committed or cancelled.
        if (demo.composition_len > 0 and code != .escape and code != .tab) return;
        // Highlighted static text (View > Selectable Text) copies like a field's selection.
        if (command and code == .c and !demo.isEditing()) {
            if (demo.selectedText()) |text| copyText(text);
            return;
        }
        if (command and demo.isEditing()) switch (code) {
            .a, .z, .y => {
                _ = demo.editKey(if (code == .a) .select_all else if (code == .y or extend) .redo else .undo, false, false, font);
                return;
            },
            .c, .x => {
                if (demo.selectedText()) |selection| {
                    copyText(selection);
                    if (code == .x) demo.cutSelection();
                }
                return;
            },
            .v => {
                // In the browser the text arrives a little later (see `iterate`).
                if (web) ui.web.requestPaste() else self.paste();
                return;
            },
            else => {},
        };
        if (key.repeat and code != .tab and !demo.isEditing() and !(code == .enter and demo.focusRepeats())) return;
        switch (code) {
            // Holding Tab / Shift+Tab keeps moving focus at the keyboard's repeat rate.
            .tab => demo.next(extend),
            .f12 => demo.toggleDevtools(),
            .i => if (extend and command) demo.toggleDevtools(),
            .escape => if (demo.composition_len > 0) demo.setComposition("", null) else {
                _ = demo.dismiss();
            },
            .left, .right => {
                const dir: i8 = if (code == .left) -1 else 1;
                const moved = if (builtin.os.tag == .macos and command and demo.isEditing())
                    demo.editKey(if (dir < 0) .home else .end, extend, false, font)
                else
                    demo.editKey(if (dir < 0) .left else .right, extend, word, font);
                if (!moved and !demo.treeKey(if (dir < 0) .left else .right) and !demo.moveComposite(dir)) demo.adjustFocused(@floatFromInt(dir));
            },
            .up => if (!demo.treeKey(.up) and !demo.adjustVertical(1, extend) and !demo.menuMove(-1) and !demo.editKey(.up, extend, false, font)) {
                _ = demo.moveComposite(-1);
            },
            .down => if (!demo.treeKey(.down) and !demo.adjustVertical(-1, extend) and !demo.menuMove(1) and !demo.editKey(.down, extend, false, font)) {
                _ = demo.moveComposite(1);
            },
            .backspace => {
                // Ctrl or Alt deletes the word before the caret (Option on macOS).
                if ((word or key.modifiers.alt) and demo.isEditing() and demo.selectedText() == null) _ = demo.editKey(.left, true, true, font);
                if (!demo.editKey(.backspace, false, false, font)) _ = demo.backspace();
            },
            .delete => {
                if ((word or key.modifiers.alt) and demo.isEditing() and demo.selectedText() == null) _ = demo.editKey(.right, true, true, font);
                _ = demo.editKey(.delete, false, false, font);
            },
            .space => if (!demo.isEditing()) demo.activate(),
            .enter => if (demo.composition_len == 0 and !demo.confirmMenu()) {
                if (demo.isEditing()) {
                    if (demo.focusId() == 301) _ = demo.insertText("\n") else _ = demo.commitEdit();
                } else demo.activate();
            },
            .page_down => if (!demo.dialog_open) demo.scroll.wheel(0, -self.viewport.h / 40),
            .page_up => if (!demo.dialog_open) demo.scroll.wheel(0, self.viewport.h / 40),
            .home => if (!demo.editKey(.home, extend, word, font) and !demo.dialog_open) {
                demo.scroll.offset.y = 0;
            },
            .end => if (!demo.editKey(.end, extend, word, font) and !demo.dialog_open) {
                demo.scroll.offset.y = demo.scroll.content.y;
            },
            else => {},
        }
    }
};

/// SDL user-event code for a file dialog's answer.
const file_event_code: i32 = -1;
/// A file dialog's answer: the chosen file's name, or no `len` for a cancel.
const FileChoice = struct { name: [128]u8 = undefined, len: ?usize = null };

/// SDL may answer from another thread, so hand the result to the event loop as a user event.
fn fileChosen(_: ?*anyopaque, files: ?[]const [*:0]const u8, _: ?usize, failed: bool) void {
    const chosen = std.heap.c_allocator.create(FileChoice) catch return;
    chosen.* = .{};
    if (failed) std.log.err("file dialog failed: {s}", .{sdl3.errors.get() orelse "unknown"});
    if (!failed) if (files) |list| if (list.len > 0) {
        const name = std.fs.path.basename(std.mem.span(list[0]));
        const len = @min(name.len, chosen.name.len);
        @memcpy(chosen.name[0..len], name[0..len]);
        chosen.len = len;
    };
    sdl3.events.push(.{ .user = .{ .common = .{ .timestamp = 0 }, .event_type = @backingInt(sdl3.events.Type.user), .code = file_event_code, .data1 = chosen } }) catch std.heap.c_allocator.destroy(chosen);
}

/// The system clipboard: SDL's is the page's own in the browser.
fn copyText(text: []const u8) void {
    if (web) return ui.web.copy(text);
    var buffer: [1024]u8 = undefined;
    sdl3.clipboard.setText(std.fmt.bufPrintSentinel(&buffer, "{s}", .{text}, 0) catch return) catch {};
}

/// The SDL callbacks' app state: a handle, since zig-sdl3 copies the state by value.
const Handle = struct { app: *App };

pub fn init(init_data: sdl3.Init) !struct { Handle, sdl3.AppResult } {
    return .{ .{ .app = try App.init(init_data.gpa, init_data.io) }, .run };
}

pub fn iterate(handle: *Handle) !sdl3.AppResult {
    return handle.app.iterate();
}

pub fn event(handle: *Handle, curr_event: sdl3.events.Event) !sdl3.AppResult {
    return handle.app.event(curr_event);
}

pub fn quit(handle: ?*Handle, _: sdl3.AppResult) void {
    if (handle) |h| h.app.deinit();
}
