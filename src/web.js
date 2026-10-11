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
      event.preventDefault();
    });`,
  weeoui_paste_request: () => {
    navigator.clipboard?.readText()
      .then((text) => { Module.weeouiPaste = (Module.weeouiPaste ?? '') + text; })
      .catch((error) => console.warn('paste failed:', error));
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
