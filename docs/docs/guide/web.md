---
sidebar_position: 2
title: Run in the browser
---

# Run in the browser

Weeoui runs in the browser on WebGPU. The same app code builds for the desktop and for the web: Vitellus picks its WebGPU backend for `wasm32-emscripten`, and `weeoui_vitellus` loads WGSL shaders there instead of SPIR-V.

[**Open the live demo**](pathname:///demo/): the full component gallery with docking and DevTools (press F12), running on WebGPU.

## What you need

- [emsdk](https://emscripten.org/docs/getting_started/downloads.html), installed and activated. Point the build at it with `$EMSDK` or `-Demsdk=<path>`; otherwise it looks in `~/emsdk`.
- Dawn's WebGPU bindings, fetched once with `embuilder build emdawnwebgpu`.
- A browser with WebGPU: a recent Chrome or Edge, Safari 26, or Firefox 141 on Windows.

## Try the gallery

```bash
zig build gallery -Dsdl3 -Dvitellus -Dtarget=wasm32-emscripten -Doptimize=ReleaseFast
```

This builds `zig-out/web/gallery.html`, serves it with `emrun` and opens it in your browser. Build without `-Doptimize` only when you need to debug. Debug builds are much slower in the browser.

## Build your own app

Zig compiles the app into a static library, and `em++` links it with its dependencies into a page. Vitellus's build exposes a helper for that. In `build.zig`:

```zig
const vitellus_build = @import("vitellus");

const web = target.result.os.tag == .emscripten;
// Before creating any dependency: it points C dependencies at Emscripten's sysroot.
const emscripten = vitellus_build.Emscripten.init(b, target, null);
const weeoui = b.dependency("weeoui", .{ .target = target, .optimize = optimize, .sdl3 = true, .vitellus = true });

if (web) {
    const app = emscripten.addApp(b, .{
        .name = "app",
        .root_module = app_module,
        .shell_file = b.path("web/shell.html"), // optional: your own page around the canvas
        .args = &.{
            "-sSTACK_SIZE=8388608",
            // `ui.web`: emoji and the system clipboard (see below).
            "--js-library", weeoui.namedLazyPath("web_js").getPath(b),
        },
    });
    b.step("run", "Open the app in a browser").dependOn(&app.run.step);
}
```

The page lands in `zig-out/web/` as `<name>.html`, `<name>.js` and `<name>.wasm`. Any static file host can serve it.

### The frame loop

The browser owns the frame loop, so `weeoui_sdl3.run`, which loops until the window closes, doesn't work there. Use SDL's main callbacks instead. With `vitellus_sdl3.main_callbacks`, SDL calls your `init`, `event`, `iterate` and `quit` functions on the desktop and on the web alike:

```zig
const sdl_adapter = @import("vitellus_sdl3");
const sdl3 = sdl_adapter.sdl;

comptime {
    _ = sdl_adapter.main_callbacks;
}

pub const _start = void;
pub const WinMainCRTStartup = void;

pub fn init(init_data: sdl3.Init) !struct { State, sdl3.AppResult } { ... }
pub fn event(state: *State, event: sdl3.events.Event) !sdl3.AppResult { ... }
pub fn iterate(state: *State) !sdl3.AppResult { ... } // one frame: build the UI and paint it
pub fn quit(state: ?*State, result: sdl3.AppResult) void { ... }
```

Inside those, feed events and paint frames as described in [Your own loop and renderer](../concepts/custom-loop.md). `examples/gallery/main.zig` is a complete example.

On the web, `init_data.io` is `std.Io.failing`, because Zig 0.16 can't build its threaded I/O for Emscripten. Don't use it there.

### Logging and panics

Zig 0.16 can't build its stderr logger for Emscripten either. Send logs and panics to the browser console:

```zig
pub const std_options = vit.web.std_options;
pub const panic = vit.web.panic;
```

`ui.devtools.logFn` already writes to the browser console on the web, so DevTools apps can keep using it.

### Emoji

A page can't hand FreeType the system's emoji font, so `Font.loadSystemEmoji` finds nothing in the browser. Let the browser draw them instead:

```zig
if (web) font.platform = ui.web.textRenderer() else _ = font.loadSystemEmoji(io);
```

This draws every glyph the main font lacks on a 2D canvas, where the browser falls back to the system's color emoji font. It needs `web.js` linked in with `--js-library`, as in the build above.

### Copy and paste

SDL keeps a clipboard of its own on the web, so text copied with it never leaves the page. Use `ui.web` for the system clipboard instead:

```zig
// On Ctrl+C or Cmd+C (browsers only allow this right after a key press or click):
ui.web.copy(selected_text);

// Every frame, while a text field has focus:
var buffer: [4096]u8 = undefined;
if (ui.web.takePaste(&buffer)) |text| insert(text);
```

The browser gives the page pasted text only through its paste event, so poll `takePaste` instead of reading the clipboard when Ctrl+V arrives. SDL lets that event through while its text input is on, which is whenever a field has focus.

A Paste that doesn't come from the keyboard, such as a right-click menu's, calls `ui.web.requestPaste()` instead. The browser may ask the user for permission first, and the text arrives through `takePaste` as before.

## Differences from the desktop

| | Desktop | Browser |
| --- | --- | --- |
| GPU backend | Vulkan (SPIR-V shaders) | WebGPU (WGSL shaders) |
| Screen readers | AccessKit | Not yet |
| Emoji | System emoji font via FreeType | Browser text stack (`ui.web.textRenderer`) |
| Clipboard | SDL (`sdl3.clipboard`) | `ui.web.copy` and `ui.web.takePaste` |
| Dock pop-outs | OS windows | Set `dock.os_windows = false` so panels float instead |
| Custom title bars | `weeoui_sdl3.useCustomFrame` | None: the page is the window |
| `weeoui_sdl3.run` | Yes | No: use main callbacks |

Weeoui's `Context` is about 90 KiB, and Debug builds keep copies of large values on the stack, so raise Emscripten's stack (`-sSTACK_SIZE`) as above and keep big state on the heap.
