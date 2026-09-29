const std = @import("std");
const Font = @import("font.zig").Font;
const Rect = @import("types.zig").Rect;

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const Error = error{ InvalidUtf8, Full, InvalidBoundary, InvalidRange };

pub fn isBoundary(text: []const u8, at: usize) bool {
    return at <= text.len and (at == text.len or at == 0 or text[at] & 0xc0 != 0x80);
}

fn previous(text: []const u8, at: usize) usize {
    var pos = at - 1;
    while (pos > 0 and text[pos] & 0xc0 == 0x80) pos -= 1;
    return pos;
}

fn next(text: []const u8, at: usize) usize {
    var pos = at + 1;
    while (pos < text.len and text[pos] & 0xc0 == 0x80) pos += 1;
    return pos;
}

fn lineStart(text: []const u8, at: usize) usize {
    var pos = at;
    while (pos > 0 and text[pos - 1] != '\n') pos -= 1;
    return pos;
}

fn lineEnd(text: []const u8, at: usize) usize {
    var pos = at;
    while (pos < text.len and text[pos] != '\n') pos += 1;
    return pos;
}

const Kind = enum { whitespace, word, punctuation };

fn kind(byte: u8) Kind {
    if (std.ascii.isWhitespace(byte)) return .whitespace;
    if (byte >= 128 or std.ascii.isAlphanumeric(byte) or byte == '_') return .word;
    return .punctuation;
}

/// An app-owned, fixed-capacity UTF-8 editor. Positions are byte offsets at codepoint
/// boundaries, not extended grapheme clusters. The font currently renders non-ASCII
/// scalars as fallback glyphs. History keeps sixteen states without heap allocation.
pub fn TextEdit(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Snapshot = struct {
            bytes: [capacity]u8 = undefined,
            len: usize = 0,
            cursor: usize = 0,
            anchor: usize = 0,
        };

        bytes: [capacity]u8 = undefined,
        len: usize = 0,
        cursor: usize = 0,
        anchor: usize = 0,
        history: [16]Snapshot = [_]Snapshot{.{}} ** 16,
        history_len: usize = 0,
        history_pos: usize = 0,
        preferred_x: ?f32 = null,

        pub fn init(initial: []const u8) Error!Self {
            var self: Self = .{};
            try self.set(initial);
            return self;
        }

        pub fn text(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        /// Set a new value, move the caret to its end and clear edit history.
        pub fn set(self: *Self, value: []const u8) Error!void {
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
            if (value.len > capacity) return error.Full;
            std.mem.copyForwards(u8, self.bytes[0..value.len], value);
            self.len = value.len;
            self.cursor = value.len;
            self.anchor = value.len;
            self.history_len = 0;
            self.history_pos = 0;
            self.preferred_x = null;
        }

        pub fn selection(self: *const Self) ?Range {
            if (self.cursor == self.anchor) return null;
            return .{ .start = @min(self.cursor, self.anchor), .end = @max(self.cursor, self.anchor) };
        }

        pub fn selectAll(self: *Self) void {
            self.anchor = 0;
            self.cursor = self.len;
            self.preferred_x = null;
        }

        pub fn selectWord(self: *Self) void {
            if (self.len == 0) return;
            const value = self.text();
            const at = if (self.cursor == self.len) previous(value, self.cursor) else self.cursor;
            const group = kind(value[at]);
            var start = at;
            while (start > 0 and kind(value[previous(value, start)]) == group) start = previous(value, start);
            var end = next(value, at);
            while (end < value.len and kind(value[end]) == group) end = next(value, end);
            self.anchor = start;
            self.cursor = end;
            self.preferred_x = null;
        }

        pub fn selectLine(self: *Self) void {
            const value = self.text();
            self.anchor = lineStart(value, self.cursor);
            self.cursor = lineEnd(value, self.cursor);
            if (self.cursor < value.len) self.cursor += 1;
            self.preferred_x = null;
        }

        pub fn setCursor(self: *Self, at: usize, extend: bool) Error!void {
            if (!isBoundary(self.text(), at)) return error.InvalidBoundary;
            self.moveTo(at, extend);
        }

        fn moveTo(self: *Self, at: usize, extend: bool) void {
            self.cursor = at;
            if (!extend) self.anchor = at;
            self.preferred_x = null;
        }

        fn snapshot(self: *const Self) Snapshot {
            var state: Snapshot = .{ .len = self.len, .cursor = self.cursor, .anchor = self.anchor };
            @memcpy(state.bytes[0..self.len], self.text());
            return state;
        }

        fn restore(self: *Self, state: *const Snapshot) void {
            @memcpy(self.bytes[0..state.len], state.bytes[0..state.len]);
            self.len = state.len;
            self.cursor = state.cursor;
            self.anchor = state.anchor;
            self.preferred_x = null;
        }

        pub fn undo(self: *Self) bool {
            if (self.history_len == 0 or self.history_pos == 0) return false;
            self.history_pos -= 1;
            self.restore(&self.history[self.history_pos]);
            return true;
        }

        pub fn redo(self: *Self) bool {
            if (self.history_len == 0 or self.history_pos + 1 >= self.history_len) return false;
            self.history_pos += 1;
            self.restore(&self.history[self.history_pos]);
            return true;
        }

        pub fn replace(self: *Self, range: Range, value: []const u8) Error!void {
            const current = self.text();
            if (range.start > range.end or range.end > current.len) return error.InvalidRange;
            if (!isBoundary(current, range.start) or !isBoundary(current, range.end)) return error.InvalidBoundary;
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
            const remaining = self.len - (range.end - range.start);
            if (value.len > capacity - remaining) return error.Full;
            if (range.start == range.end and value.len == 0) return;

            var replacement: [capacity]u8 = undefined;
            @memcpy(replacement[0..value.len], value);
            if (self.history_len == 0) {
                self.history[0] = self.snapshot();
                self.history_len = 1;
            } else self.history_len = self.history_pos + 1;
            if (self.history_len == self.history.len) {
                std.mem.copyForwards(Snapshot, self.history[0 .. self.history.len - 1], self.history[1..]);
                self.history_len -= 1;
            }
            const tail = self.len - range.end;
            const tail_start = range.start + value.len;
            if (tail_start > range.end) {
                std.mem.copyBackwards(u8, self.bytes[tail_start..][0..tail], self.bytes[range.end..][0..tail]);
            } else {
                std.mem.copyForwards(u8, self.bytes[tail_start..][0..tail], self.bytes[range.end..][0..tail]);
            }
            @memcpy(self.bytes[range.start..][0..value.len], replacement[0..value.len]);
            self.len = remaining + value.len;
            self.cursor = tail_start;
            self.anchor = self.cursor;
            self.preferred_x = null;
            self.history[self.history_len] = self.snapshot();
            self.history_pos = self.history_len;
            self.history_len += 1;
        }

        pub fn insert(self: *Self, value: []const u8) Error!void {
            try self.replace(self.selection() orelse .{ .start = self.cursor, .end = self.cursor }, value);
        }

        pub fn backspace(self: *Self) void {
            const range = self.selection() orelse if (self.cursor > 0)
                Range{ .start = previous(self.text(), self.cursor), .end = self.cursor }
            else
                return;
            self.replace(range, "") catch unreachable;
        }

        pub fn delete(self: *Self) void {
            const range = self.selection() orelse if (self.cursor < self.len)
                Range{ .start = self.cursor, .end = next(self.text(), self.cursor) }
            else
                return;
            self.replace(range, "") catch unreachable;
        }

        fn wordLeft(self: *const Self) usize {
            const value = self.text();
            var pos = self.cursor;
            while (pos > 0) {
                const prior = previous(value, pos);
                if (kind(value[prior]) != .whitespace) break;
                pos = prior;
            }
            if (pos == 0) return 0;
            const group = kind(value[previous(value, pos)]);
            while (pos > 0) {
                const prior = previous(value, pos);
                if (kind(value[prior]) != group) break;
                pos = prior;
            }
            return pos;
        }

        fn wordRight(self: *const Self) usize {
            const value = self.text();
            var pos = self.cursor;
            if (pos < value.len and kind(value[pos]) != .whitespace) {
                const group = kind(value[pos]);
                while (pos < value.len and kind(value[pos]) == group) pos = next(value, pos);
            }
            while (pos < value.len and kind(value[pos]) == .whitespace) pos = next(value, pos);
            return pos;
        }

        pub fn moveLeft(self: *Self, extend: bool, word: bool) void {
            if (!extend) if (self.selection()) |range| {
                self.moveTo(range.start, false);
                return;
            };
            self.moveTo(if (word) self.wordLeft() else if (self.cursor > 0) previous(self.text(), self.cursor) else 0, extend);
        }

        pub fn moveRight(self: *Self, extend: bool, word: bool) void {
            if (!extend) if (self.selection()) |range| {
                self.moveTo(range.end, false);
                return;
            };
            self.moveTo(if (word) self.wordRight() else if (self.cursor < self.len) next(self.text(), self.cursor) else self.len, extend);
        }

        pub fn moveHome(self: *Self, extend: bool) void {
            self.moveTo(lineStart(self.text(), self.cursor), extend);
        }

        pub fn moveEnd(self: *Self, extend: bool) void {
            self.moveTo(lineEnd(self.text(), self.cursor), extend);
        }

        pub fn moveDocumentStart(self: *Self, extend: bool) void {
            self.moveTo(0, extend);
        }

        pub fn moveDocumentEnd(self: *Self, extend: bool) void {
            self.moveTo(self.len, extend);
        }

        /// Move between hard (LF-delimited) lines; repeat calls retain the desired x.
        pub fn moveVertical(self: *Self, font: *const Font, size: f32, direction: enum { up, down }, extend: bool) void {
            const value = self.text();
            const start = lineStart(value, self.cursor);
            const end = lineEnd(value, self.cursor);
            const x = self.preferred_x orelse font.measure(value[start..self.cursor], size);
            const target_end: usize, const target_start: usize = switch (direction) {
                .up => if (start == 0) return else .{ start - 1, lineStart(value, start - 1) },
                .down => if (end == value.len) return else .{ lineEnd(value, end + 1), end + 1 },
            };
            const at = nearest(font, size, value[target_start..target_end], target_start, x);
            self.moveTo(at, extend);
            self.preferred_x = x;
        }

        /// `area` is Input's content rectangle (see inputContentRect), in UI coordinates.
        /// Repeated calls with `extend = true` implement pointer dragging.
        pub fn placeCaret(self: *Self, font: *const Font, size: f32, area: Rect, multiline: bool, x: f32, y: f32, extend: bool) void {
            self.placeCaretIn(.{ .font = font, .size = size, .area = area, .multiline = multiline }, x, y, extend);
        }

        /// Use this overload when the painted Input has nonzero scroll_x/scroll_y.
        pub fn placeCaretIn(self: *Self, layout: TextLayout, x: f32, y: f32, extend: bool) void {
            self.moveTo(layout.hitTest(self.text(), x, y), extend);
        }
    };
}

fn nearest(font: *const Font, size: f32, value: []const u8, start: usize, x: f32) usize {
    var pos: usize = 0;
    var width: f32 = 0;
    while (pos < value.len) {
        const end = next(value, pos);
        const advance = font.measure(value[pos..end], size);
        if (x < width + advance / 2) break;
        width += advance;
        pos = end;
    }
    return start + pos;
}

pub fn inputContentRect(r: Rect) Rect {
    return .{ .x = r.x + 10, .y = r.y + 4, .w = @max(0, r.w - 20), .h = @max(0, r.h - 8) };
}

/// Up to three adjoining UTF-8 runs, for painting IME preedit without allocating.
pub const TextView = struct {
    before: []const u8,
    inserted: []const u8 = "",
    after: []const u8 = "",

    pub const Codepoint = struct { bytes: []const u8, end: usize };

    pub fn length(self: TextView) usize {
        return self.before.len + self.inserted.len + self.after.len;
    }

    fn run(self: TextView, at: usize) []const u8 {
        if (at < self.before.len) return self.before[at..];
        if (at < self.before.len + self.inserted.len) return self.inserted[at - self.before.len ..];
        return self.after[at - self.before.len - self.inserted.len ..];
    }

    pub fn byteAt(self: TextView, at: usize) u8 {
        return self.run(at)[0];
    }

    pub fn codepoint(self: TextView, at: usize) Codepoint {
        const bytes = self.run(at);
        const count: usize = if (bytes[0] < 0x80) 1 else if (bytes[0] < 0xe0) 2 else if (bytes[0] < 0xf0) 3 else 4;
        const byte_count = @min(bytes.len, count);
        return .{ .bytes = bytes[0..byte_count], .end = at + byte_count };
    }

    pub fn measure(self: TextView, font: *const Font, size: f32, start: usize, end: usize) f32 {
        var x: f32 = 0;
        var at = start;
        while (at < end) {
            const cp = self.codepoint(at);
            x += font.measure(cp.bytes, size);
            at = cp.end;
        }
        return x;
    }
};

/// Geometry shared by caret painting and pointer hit testing. Soft wrapping preserves
/// every byte (including spaces); hard LF produces another line, even at text end.
pub const TextLayout = struct {
    font: *const Font,
    size: f32,
    area: Rect,
    multiline: bool = false,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,

    pub const Line = struct {
        start: usize,
        end: usize,
        y: f32,
        h: f32,
        soft_wrap: bool = false,
        newline: bool = false,
    };

    pub const Lines = struct {
        layout: TextLayout,
        view: TextView,
        at: usize = 0,
        y: f32,
        done: bool = false,

        pub fn next(self: *Lines) ?Line {
            if (self.done) return null;
            const l = self.layout;
            const start = self.at;
            const height = if (l.multiline) l.size * 1.35 else l.area.h;
            const line = Line{ .start = start, .end = start, .y = self.y, .h = height };
            if (!l.multiline) {
                self.done = true;
                return .{ .start = 0, .end = self.view.length(), .y = self.y, .h = height };
            }
            if (start == self.view.length()) {
                self.done = true;
                return line;
            }
            var at = start;
            var width: f32 = 0;
            var break_at: ?usize = null;
            while (at < self.view.length()) {
                const cp = self.view.codepoint(at);
                if (cp.bytes[0] == '\n') {
                    self.at = cp.end;
                    self.y += height;
                    return .{ .start = start, .end = at, .y = line.y, .h = height, .newline = true };
                }
                const advance = l.font.measure(cp.bytes, l.size);
                if (at > start and width + advance > @max(1, l.area.w)) {
                    const end = break_at orelse at;
                    self.at = end;
                    self.y += height;
                    return .{ .start = start, .end = end, .y = line.y, .h = height, .soft_wrap = true };
                }
                width += advance;
                at = cp.end;
                if (cp.bytes[0] == ' ') break_at = at;
            }
            self.at = at;
            self.done = true;
            return .{ .start = start, .end = at, .y = line.y, .h = height };
        }
    };

    pub fn lines(self: TextLayout, view: TextView) Lines {
        return .{ .layout = self, .view = view, .y = self.area.y - self.scroll_y };
    }

    const Ink = struct { left: f32 = 0, top: f32 = 0, height: f32 = 0 };

    fn ink(self: TextLayout, view: TextView, line: Line) Ink {
        var left: f32 = std.math.inf(f32);
        var top: f32 = std.math.inf(f32);
        var bottom: f32 = -std.math.inf(f32);
        var advance: f32 = 0;
        var at = line.start;
        while (at < line.end) {
            const cp = view.codepoint(at);
            const bounds = self.font.inkBounds(cp.bytes, self.size);
            if (bounds.w > 0 and bounds.h > 0) {
                left = @min(left, advance + bounds.x);
                top = @min(top, bounds.y);
                bottom = @max(bottom, bounds.y + bounds.h);
            }
            advance += self.font.measure(cp.bytes, self.size);
            at = cp.end;
        }
        if (left == std.math.inf(f32)) return .{};
        return .{ .left = left, .top = top, .height = bottom - top };
    }

    pub fn lineOrigin(self: TextLayout, view: TextView, line: Line) f32 {
        return self.area.x - self.scroll_x - self.ink(view, line).left;
    }

    pub fn lineTextY(self: TextLayout, view: TextView, line: Line) f32 {
        const bounds = self.ink(view, line);
        return line.y + (line.h - bounds.height) / 2 - bounds.top;
    }

    pub fn penX(self: TextLayout, view: TextView, line: Line, at: usize) f32 {
        return self.lineOrigin(view, line) + view.measure(self.font, self.size, line.start, at);
    }

    pub fn caretRect(self: TextLayout, view: TextView, at: usize) Rect {
        var iter = self.lines(view);
        var last: Line = undefined;
        while (iter.next()) |line| {
            last = line;
            if (at < line.end or at == line.end and !line.soft_wrap) return self.caretOnLine(view, line, at);
        }
        return self.caretOnLine(view, last, last.end);
    }

    fn caretOnLine(self: TextLayout, view: TextView, line: Line, at: usize) Rect {
        const height = @min(line.h, @max(1, self.size * 1.2));
        return .{ .x = self.penX(view, line, at), .y = line.y + (line.h - height) / 2, .w = 1, .h = height };
    }

    pub fn hitTest(self: TextLayout, value: []const u8, x: f32, y: f32) usize {
        const view = TextView{ .before = value };
        var iter = self.lines(view);
        var last: Line = undefined;
        while (iter.next()) |line| {
            last = line;
            if (!self.multiline or y < line.y + line.h) return self.hitLine(view, line, x);
        }
        return self.hitLine(view, last, x);
    }

    fn hitLine(self: TextLayout, view: TextView, line: Line, x: f32) usize {
        var pen = self.lineOrigin(view, line);
        var at = line.start;
        while (at < line.end) {
            const cp = view.codepoint(at);
            const advance = self.font.measure(cp.bytes, self.size);
            if (x < pen + advance / 2) break;
            pen += advance;
            at = cp.end;
        }
        return at;
    }
};

test "UTF-8 insertion, selection replacement, deletion and atomic errors" {
    const Editor = TextEdit(16);
    var edit = try Editor.init("aé🙂b");
    try std.testing.expectEqual(@as(usize, 8), edit.cursor);
    try std.testing.expectError(error.InvalidBoundary, edit.setCursor(2, false));
    try std.testing.expectEqual(@as(usize, 8), edit.cursor);
    try edit.setCursor(1, false);
    edit.moveRight(true, false);
    try std.testing.expectEqualDeep(Range{ .start = 1, .end = 3 }, edit.selection().?);
    try edit.insert("界");
    try std.testing.expectEqualStrings("a界🙂b", edit.text());
    try std.testing.expectEqual(@as(usize, 4), edit.cursor);
    edit.backspace();
    try std.testing.expectEqualStrings("a🙂b", edit.text());
    edit.delete();
    try std.testing.expectEqualStrings("ab", edit.text());
    const old = edit.cursor;
    try std.testing.expectError(error.InvalidBoundary, edit.setCursor(2 + 1, false));
    try std.testing.expectEqual(old, edit.cursor);
    try std.testing.expectError(error.InvalidUtf8, edit.insert("\xff"));
    try std.testing.expectError(error.Full, edit.insert("longer than capacity"));
    try std.testing.expectError(error.InvalidRange, edit.replace(.{ .start = 2, .end = 1 }, "x"));
    try std.testing.expectEqualStrings("ab", edit.text());
    var full = try TextEdit(4).init("aéb");
    try std.testing.expectError(error.Full, full.insert("z"));
    try std.testing.expectEqualStrings("aéb", full.text());
    try std.testing.expectEqual(@as(usize, 4), full.cursor);
    try std.testing.expect(!full.undo());
    try std.testing.expectError(error.InvalidBoundary, full.replace(.{ .start = 1, .end = 2 }, ""));
    try full.replace(.{ .start = 1, .end = 3 }, "b");
    try std.testing.expectEqualStrings("abb", full.text());
}

test "word and hard-line navigation never split codepoints" {
    var edit = try TextEdit(64).init("hi, 世界!\nalpha beta\nz");
    try edit.setCursor(0, false);
    edit.moveRight(false, true);
    try std.testing.expectEqual(@as(usize, 2), edit.cursor);
    edit.moveRight(false, true);
    try std.testing.expectEqual(@as(usize, 4), edit.cursor);
    edit.moveRight(false, true);
    try std.testing.expectEqual(@as(usize, 10), edit.cursor);
    edit.moveLeft(true, true);
    try std.testing.expectEqualDeep(Range{ .start = 4, .end = 10 }, edit.selection().?);
    edit.moveRight(false, false);
    edit.moveEnd(false);
    try std.testing.expectEqual(@as(usize, 11), edit.cursor);
    edit.moveHome(true);
    try std.testing.expectEqualDeep(Range{ .start = 0, .end = 11 }, edit.selection().?);
    edit.selectAll();
    try std.testing.expectEqualDeep(Range{ .start = 0, .end = edit.len }, edit.selection().?);
    edit.moveDocumentEnd(false);
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    edit.moveVertical(&font, 16, .up, false);
    try std.testing.expectEqual(@as(usize, 13), edit.cursor);
    edit.moveVertical(&font, 16, .up, false);
    try std.testing.expectEqual(@as(usize, 1), edit.cursor);
    edit.moveVertical(&font, 16, .down, false);
    try std.testing.expectEqual(@as(usize, 13), edit.cursor);
}

test "word and line selections preserve UTF-8 boundaries and hard newlines" {
    var edit = try TextEdit(64).init("hi, 世界!\nalpha beta\nz");
    try edit.setCursor(4, false);
    edit.selectWord();
    const word = edit.selection().?;
    try std.testing.expectEqualStrings("世界", edit.text()[word.start..word.end]);
    edit.selectLine();
    const line = edit.selection().?;
    try std.testing.expectEqualStrings("hi, 世界!\n", edit.text()[line.start..line.end]);
    const beta = std.mem.indexOf(u8, edit.text(), "beta").?;
    try edit.setCursor(beta + 1, false);
    edit.selectWord();
    const last_word = edit.selection().?;
    try std.testing.expectEqualStrings("beta", edit.text()[last_word.start..last_word.end]);
    edit.selectLine();
    const second_line = edit.selection().?;
    try std.testing.expectEqualStrings("alpha beta\n", edit.text()[second_line.start..second_line.end]);
}

test "undo and redo preserve selection and invalidate redo on edit" {
    var edit = try TextEdit(16).init("alpha");
    try edit.setCursor(1, false);
    edit.moveRight(true, false);
    try edit.insert("é");
    try std.testing.expectEqualStrings("aépha", edit.text());
    try std.testing.expect(edit.undo());
    try std.testing.expectEqualStrings("alpha", edit.text());
    try std.testing.expectEqualDeep(Range{ .start = 1, .end = 2 }, edit.selection().?);
    try std.testing.expect(!edit.undo());
    try std.testing.expect(edit.redo());
    try std.testing.expectEqualStrings("aépha", edit.text());
    try std.testing.expect(edit.undo());
    try edit.insert("X");
    try std.testing.expect(!edit.redo());
}

test "bounded undo history retains fifteen prior edits" {
    var edit = try TextEdit(32).init("");
    for (0..20) |_| try edit.insert("a");
    for (0..15) |_| try std.testing.expect(edit.undo());
    try std.testing.expectEqualStrings("aaaaa", edit.text());
    try std.testing.expect(!edit.undo());
    for (0..15) |_| try std.testing.expect(edit.redo());
    try std.testing.expectEqual(@as(usize, 20), edit.text().len);
    try std.testing.expect(edit.undo());
    try edit.insert("Z");
    try std.testing.expect(!edit.redo());
}

test "pointer placement uses the same wrapped geometry as caret painting" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var edit = try TextEdit(32).init("AéB\nx");
    const area = inputContentRect(.{ .x = 10, .y = 20, .w = 120, .h = 80 });
    const layout = TextLayout{ .font = &font, .size = 16, .area = area, .multiline = true };
    const view = TextView{ .before = edit.text() };
    const pos = layout.caretRect(view, 3);
    edit.placeCaret(&font, 16, area, true, pos.x, pos.y + pos.h / 2, false);
    try std.testing.expectEqual(@as(usize, 3), edit.cursor);
    edit.placeCaret(&font, 16, area, true, area.x, area.y + 16 * 1.35 + 2, true);
    try std.testing.expectEqualDeep(Range{ .start = 3, .end = 5 }, edit.selection().?);
    try edit.setCursor(0, false);
    edit.placeCaret(&font, 16, area, false, area.x + font.measure("Aé", 16), area.y + 4, false);
    try std.testing.expectEqual(@as(usize, 3), edit.cursor);
}

test "soft wrap and scroll map pointer positions to UTF-8 boundaries" {
    var font = try Font.init(std.testing.allocator, @embedFile("assets/OpenSans-Regular.ttf"));
    defer font.deinit();
    var edit = try TextEdit(32).init("ab é🙂z");
    const area = Rect{ .x = 20, .y = 30, .w = font.measure("ab ", 16) + 1, .h = 75 };
    const layout = TextLayout{ .font = &font, .size = 16, .area = area, .multiline = true };
    var lines = layout.lines(.{ .before = edit.text() });
    const first = lines.next().?;
    try std.testing.expect(first.soft_wrap);
    try std.testing.expectEqual(@as(usize, 3), first.end);
    const second = lines.next().?;
    try std.testing.expectEqual(first.end, second.start);
    const second_caret = layout.caretRect(.{ .before = edit.text() }, 3);
    try std.testing.expectApproxEqAbs(second.y + second.h / 2, second_caret.y + second_caret.h / 2, 0.001);
    edit.placeCaretIn(layout, second_caret.x, second_caret.y + second_caret.h / 2, false);
    try std.testing.expectEqual(@as(usize, 3), edit.cursor);
    edit.placeCaretIn(.{ .font = &font, .size = 16, .area = area, .multiline = true, .scroll_y = 16 * 1.35 }, area.x, area.y + 1, true);
    try std.testing.expectEqual(@as(usize, 3), edit.cursor);
}
