// Emscripten library for web.zig. Link with `emcc --js-library web.js`.
addToLibrary({
  // Draw `codepoint` on a scratch canvas with the browser's text stack (which falls back to the
  // system's color emoji font) and write its metrics; `weeoui_glyph_pixels` reads it back.
  weeoui_glyph_measure: (codepoint, size, metrics) => {
    const text = String.fromCodePoint(codepoint);
    const canvas = (Module.weeouiGlyphCanvas ??= new OffscreenCanvas(1, 1));
    const font = `${size}px sans-serif`;
    let ctx = canvas.getContext('2d', { willReadFrequently: true });
    ctx.font = font;
    const m = ctx.measureText(text);
    const ascent = Math.ceil(m.fontBoundingBoxAscent ?? size * 0.9);
    const descent = Math.ceil(m.fontBoundingBoxDescent ?? size * 0.25);
    const width = Math.min(512, Math.max(1, Math.ceil(m.width)));
    const height = Math.min(512, Math.max(1, ascent + descent));
    // Resizing clears the canvas and its state.
    canvas.width = width;
    canvas.height = height;
    ctx = canvas.getContext('2d', { willReadFrequently: true });
    ctx.font = font;
    ctx.fillText(text, 0, ascent);
    HEAP32[metrics >> 2] = width;
    HEAP32[(metrics >> 2) + 1] = height;
    HEAP32[(metrics >> 2) + 2] = ascent;
    HEAPF32[(metrics >> 2) + 3] = m.width;
    return 1;
  },
  // Straight-alpha RGBA, `width * height * 4` bytes, as the atlas wants.
  weeoui_glyph_pixels: (out) => {
    const canvas = Module.weeouiGlyphCanvas;
    HEAPU8.set(canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data, out);
  },

  weeoui_copy: (text, len) => {
    const value = new TextDecoder().decode(HEAPU8.slice(text, text + len));
    navigator.clipboard?.writeText(value).catch((error) => console.warn('copy failed:', error));
  },
  // Pasted text queues here from the page's paste event until the app takes it.
  weeoui_paste_take__postset: `
    if (typeof document != 'undefined') document.addEventListener('paste', (event) => {
      Module.weeouiPaste = (Module.weeouiPaste ?? '') + event.clipboardData.getData('text/plain');
      Module.weeouiPasteEventAt = performance.now();
      event.preventDefault();
    });`,
  weeoui_paste_request: () => {
    // The browser already handed over this paste (Cmd+V on macOS gets through SDL): don't paste twice.
    if (performance.now() - (Module.weeouiPasteEventAt ?? -1e9) < 1000) return;
    navigator.clipboard?.readText()
      .then((text) => { Module.weeouiPaste = (Module.weeouiPaste ?? '') + text; })
      .catch((error) => console.warn('paste failed:', error));
  },
  // Resolve on the browser's next display frame; the wasm stack waits (ASYNCIFY).
  weeoui_next_frame__async: true,
  weeoui_next_frame: () => Asyncify.handleAsync(() => new Promise((resolve) => requestAnimationFrame(() => resolve()))),

  // The on-screen keyboard. A page can only raise it by focusing something editable during a
  // touch, so a hidden input waits for touches on the text fields the app reported, and what is
  // typed into it queues up for `weeoui_keyboard_take` instead of reaching SDL.
  $weeouiKeyboard: () => {
    if (Module.weeouiInput) return Module.weeouiInput;
    const input = document.createElement('input');
    Object.assign(input, { autocomplete: 'off', autocapitalize: 'off', spellcheck: false });
    input.setAttribute('autocorrect', 'off');
    // 16px keeps iOS from zooming in on focus.
    input.style.cssText = 'position:fixed;left:0;bottom:0;width:1px;height:1px;opacity:0;font-size:16px;border:0;padding:0;-webkit-user-select:text;user-select:text;';
    document.body.appendChild(input);
    const queue = (Module.weeouiTyped = []);
    let composing = false;
    const flush = () => { if (input.value) queue.push(input.value); input.value = ''; };
    input.addEventListener('compositionstart', () => { composing = true; });
    input.addEventListener('compositionend', () => { composing = false; flush(); });
    input.addEventListener('input', () => { if (!composing) flush(); });
    input.addEventListener('beforeinput', (event) => {
      if (event.inputType === 'deleteContentBackward' && !input.value) { queue.push(-2); event.preventDefault(); }
      if (event.inputType === 'insertLineBreak') { queue.push(-3); event.preventDefault(); }
    });
    const keys = { Enter: -3, Delete: -4, ArrowLeft: -5, ArrowRight: -6, Tab: -7, Escape: -8 };
    input.addEventListener('keydown', (event) => {
      event.stopPropagation(); // typed here, not on the page: keep SDL from seeing it twice
      if (event.key === 'Backspace' && !input.value && !composing) { queue.push(-2); event.preventDefault(); }
      else if (keys[event.key]) { queue.push(keys[event.key]); event.preventDefault(); }
    });
    input.addEventListener('keypress', (event) => event.stopPropagation());
    input.addEventListener('keyup', (event) => event.stopPropagation());
    // A finger (or pen) lifting counts as a user gesture, so focusing here raises the keyboard.
    Module.canvas.addEventListener('pointerup', (event) => {
      if (event.pointerType === 'mouse') return;
      const rect = Module.canvas.getBoundingClientRect();
      const x = event.clientX - rect.left, y = event.clientY - rect.top;
      if ((Module.weeouiTextFields ?? []).some((f) => x >= f[0] && x < f[0] + f[2] && y >= f[1] && y < f[1] + f[3])) input.focus({ preventScroll: true });
    }, { capture: true });
    return (Module.weeouiInput = input);
  },
  weeoui_text_fields__deps: ['$weeouiKeyboard'],
  weeoui_text_fields: (rects, count) => {
    weeouiKeyboard();
    const fields = [];
    for (let i = 0; i < count; i++) fields.push(Array.from(HEAPF32.subarray((rects >> 2) + i * 4, (rects >> 2) + i * 4 + 4)));
    Module.weeouiTextFields = fields;
  },
  weeoui_keyboard__deps: ['$weeouiKeyboard'],
  weeoui_keyboard: (open) => {
    const input = weeouiKeyboard();
    if (!open && document.activeElement === input) input.blur();
  },
  weeoui_keyboard_take: (out, max) => {
    const queue = Module.weeouiTyped;
    if (!queue || !queue.length) return -1;
    const next = queue.shift();
    if (typeof next === 'number') return next;
    const bytes = new TextEncoder().encode(next);
    const len = Math.min(bytes.length, max);
    HEAPU8.set(bytes.subarray(0, len), out);
    return len;
  },

  // A hidden <input type=file>; its answer waits in Module.weeouiFile until the app takes it.
  weeoui_pick_file: () => {
    const input = document.createElement('input');
    input.type = 'file';
    input.addEventListener('change', () => { Module.weeouiFile = input.files[0] ? { name: input.files[0].name } : { cancelled: true }; });
    input.addEventListener('cancel', () => { Module.weeouiFile = { cancelled: true }; });
    input.click();
  },
  weeoui_file_take: (out, max) => {
    const picked = Module.weeouiFile;
    if (!picked) return -1;
    Module.weeouiFile = null;
    if (picked.cancelled) return -2;
    const bytes = new TextEncoder().encode(picked.name);
    const len = Math.min(bytes.length, max);
    HEAPU8.set(bytes.subarray(0, len), out);
    return len;
  },
  weeoui_paste_take: (out, max) => {
    if (!Module.weeouiPaste) return 0;
    const bytes = new TextEncoder().encode(Module.weeouiPaste);
    const len = Math.min(bytes.length, max);
    HEAPU8.set(bytes.subarray(0, len), out);
    Module.weeouiPaste = '';
    return len;
  },
});
