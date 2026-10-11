---
sidebar_position: 2
title: Run in the browser
---

# Run in the browser

Weeoui apps run in the browser on WebGPU, from the same code as on the desktop:

```bash
zig build run -Dtarget=wasm32-emscripten -Doptimize=ReleaseFast
```

This builds `zig-out/web/<name>.html` (with `.js` and `.wasm` beside it), serves it and opens it in your browser. Any static file host can serve that folder. Leave out `-Doptimize` only to debug: Debug builds are much slower in the browser.

[**Open the live demo**](pathname:///demo/): the full component gallery, with docking and DevTools (press F12).

## What you need

- [emsdk](https://emscripten.org/docs/getting_started/downloads.html), installed and activated. The build finds it through `$EMSDK`, or in `~/emsdk`.
- Dawn's WebGPU bindings, fetched once with `embuilder build emdawnwebgpu`.
- A browser with WebGPU: a recent Chrome or Edge, Safari 26, or Firefox 141 or later on Windows.

## What `run` does in the browser

`addApp` and `weeoui_sdl3.run` handle the differences, so there's nothing to change in your app:

- **Frame loop:** the browser owns it, so `run` hands control back once per display frame (`ui.web.nextFrame`).
- **Touch:** taps act when the finger lifts, swipes scroll and glide on, and nothing stays hovered after a tap. Pages are laid out for phone widths.
- **Phone keyboard:** touching a text field opens the on-screen keyboard (`ui.web.setTextFields`).
- **Clipboard:** Ctrl+C, Ctrl+X and Ctrl+V use the system clipboard (`ui.web.copy`, `ui.web.requestPaste`). The browser may ask for permission the first time something is pasted.
- **Emoji:** drawn by the browser, which has the system's emoji font (`ui.web.textRenderer`).
- **Logging and panics:** go to the browser console.

`init.io` is `std.Io.failing` in the browser, because Zig 0.16 can't build its threaded I/O there.

## Differences from the desktop

| | Desktop | Browser |
| --- | --- | --- |
| GPU backend | Vulkan (SPIR-V shaders) | WebGPU (WGSL shaders) |
| Screen readers | AccessKit | Not yet |
| Dock pop-outs | OS windows | Set `dock.os_windows = false` so panels float instead |
| Custom title bars | `weeoui_sdl3.useCustomFrame` | None: the page is the window |
| Files | SDL's file dialogs | `ui.web.pickFile` (names only) |

## Without `run`

Apps that drive their own loop on the Layout API, like the gallery (`examples/gallery`), use SDL's main callbacks (`vitellus_sdl3.main_callbacks`) and pass `.own_entry = true` to `addApp`. They call the `ui.web` functions above themselves. `examples/gallery/main.zig` shows each one in use.
