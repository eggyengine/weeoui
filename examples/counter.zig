//! Standalone counter: `weeoui_sdl3.run` opens the window, sets up Vitellus and feeds input.
//! Run with `zig build counter -Dsdl3 -Dvitellus` (add `-Dtarget=aarch64-linux-android` for an APK).
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("weeoui");
const weeoui_sdl3 = @import("weeoui_sdl3");

pub fn main(init: std.process.Init) !void {
    try start(init.gpa, init.io);
}

fn start(gpa: std.mem.Allocator, io: std.Io) !void {
    var count: u32 = 0;
    try weeoui_sdl3.run(gpa, io, .{ .title = "weeoui counter", .width = 480, .height = 320 }, &count, frame);
}

/// Android drops stderr, so send logs to logcat there.
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

// On Android, SDLActivity loads this as `libmain.so` and calls `SDL_main` on its own thread.
comptime {
    if (builtin.abi.isAndroid()) @export(&androidMain, .{ .name = "SDL_main" });
}

/// SDL calls this instead of `main`, so it builds the `std.process.Init` pieces `start` needs.
fn androidMain(_: c_int, _: [*c][*c]u8) callconv(.c) c_int {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug.deinit();
    const gpa = if (builtin.mode == .Debug) debug.allocator() else std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    start(gpa, threaded.io()) catch |err| {
        std.log.err("counter: {s}", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// Called every frame: describe the UI from your state, read back what the user did.
fn frame(count: *u32, ctx: *ui.Context) !void {
    ctx.begin(.card);
    ctx.label("Count: {d} 🥚", .{count.*});
    if (ctx.button("Increment")) count.* += 1;
    ctx.end();
}
