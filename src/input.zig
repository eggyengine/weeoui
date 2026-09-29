//! Backend-neutral pointer, keyboard, and text input. Platform adapters translate into these types.
const std = @import("std");
const Vec2 = @import("types.zig").Vec2;

pub const Button = enum { left, middle, right };
/// Keys Weeoui widgets react to; everything else is delivered as text.
pub const Key = enum {
    tab,
    escape,
    enter,
    space,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    f12,
};
pub const Modifiers = packed struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
};
/// Positions are in window coordinates; `text` slices are only valid while handling the event.
pub const Event = union(enum) {
    pointer_move: Vec2,
    pointer_down: struct { position: Vec2, button: Button, clicks: u8 },
    pointer_up: struct { position: Vec2, button: Button },
    wheel: struct { position: Vec2, delta: Vec2 },
    key_down: struct { key: Key, modifiers: Modifiers, repeat: bool },
    text: []const u8,
    composition: struct { text: []const u8, cursor: ?usize },
};
