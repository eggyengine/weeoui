//! The weeoui component gallery, built on the immediate-mode `Context` API: each frame the UI is
//! described from `Demo`'s state, and the widgets report what the user did.
//! Run with `zig build demo -Dsdl3 -Dvitellus`.
const std = @import("std");
const ui = @import("weeoui");
const weeoui_sdl3 = @import("weeoui_sdl3");

pub fn main(init: std.process.Init) !void {
    var demo: Demo = .{ .gpa = init.gpa };
    defer demo.deinit();
    try weeoui_sdl3.run(init.gpa, init.io, .{ .title = "weeoui demo", .width = 1040, .height = 760 }, &demo, frame);
}

const Demo = struct {
    gpa: std.mem.Allocator,
    page: usize = 0,
    /// System, Light, Dark.
    appearance: usize = 0,
    scroll: ui.Layout.ScrollState = .{},
    // Controls
    clicks: u32 = 0,
    notifications: bool = true,
    reduced_motion: bool = false,
    volume: f32 = 60,
    // Forms
    name: ui.TextEdit(64) = .{},
    email: ui.TextEdit(96) = .{},
    size: usize = 1,
    plan: usize = 1,
    terms: bool = false,
    submitted: bool = false,
    // Feedback
    dialog: bool = false,
    deleted: bool = false,
    // Colour
    accent: ui.ColorEditor = .init((ui.Theme{}).primary, 1),
    custom_accent: bool = false,
    /// PNG, JPEG and animated GIF, decoded into the font's color atlas on the first frame.
    media: ?[3]ui.Image = null,

    fn deinit(self: *Demo) void {
        if (self.media) |*images| for (images) |*image| image.deinit(self.gpa);
    }
};

const pages = [_][]const u8{ "Controls", "Forms", "Feedback", "Data", "Media", "Colour" };

fn frame(d: *Demo, ctx: *ui.Context) !void {
    ctx.theme = switch (d.appearance) {
        0 => weeoui_sdl3.systemTheme(),
        1 => .{},
        else => ui.Theme.dark,
    };
    if (d.custom_accent) {
        ctx.theme.primary = d.accent.rgb();
        ctx.theme.ring = d.accent.rgb();
    }
    if (d.media == null) d.media = try loadMedia(d.gpa, &ctx.font);

    ctx.begin(.row);
    ctx.heading(1, "weeoui");
    ctx.badge("component gallery", .secondary);
    _ = ctx.select("Appearance", &.{ "System theme", "Light", "Dark" }, &d.appearance);
    ctx.end();
    if (ctx.tabs(&pages, &d.page)) d.scroll = .{};

    ctx.beginScroll(&d.scroll, null);
    ctx.beginGrid(if (ctx.viewport.w >= 760) 2 else 1);
    switch (d.page) {
        0 => controls(d, ctx),
        1 => forms(d, ctx),
        2 => feedback(d, ctx),
        3 => try data(ctx),
        4 => media(d, ctx),
        else => colour(d, ctx),
    }
    ctx.end();
    ctx.end();
}

fn controls(d: *Demo, ctx: *ui.Context) void {
    ctx.begin(.card);
    ctx.heading(4, "Buttons");
    ctx.begin(.row);
    if (ctx.button("Primary")) d.clicks += 1;
    ctx.tooltip("Counts your clicks");
    if (ctx.buttonVariant("Secondary", .secondary)) d.clicks += 1;
    if (ctx.buttonVariant("Outline", .outline)) d.clicks += 1;
    if (ctx.buttonVariant("Ghost", .ghost)) d.clicks += 1;
    if (ctx.buttonVariant("Reset", .destructive)) d.clicks = 0;
    ctx.end();
    ctx.label("Clicked {d} times", .{d.clicks});
    ctx.end();

    ctx.begin(.card);
    ctx.heading(4, "Switches");
    _ = ctx.toggle("Notifications", &d.notifications);
    _ = ctx.toggle("Reduce motion", &d.reduced_motion);
    ctx.muted(if (d.notifications) "You'll hear about new eggs." else "Quiet mode: no notifications.");
    ctx.end();

    ctx.begin(.card);
    ctx.heading(4, "Slider");
    _ = ctx.slider("Volume", &d.volume, 0, 100);
    ctx.label("Volume: {d:.0}%", .{d.volume});
    ctx.progress(d.volume / 100);
    ctx.muted("Drag, click, or focus it with Tab and use the arrow keys.");
    ctx.end();

    ctx.begin(.card);
    ctx.heading(4, "Badges and avatars");
    ctx.begin(.row);
    ctx.badge("Default", .default);
    ctx.badge("Secondary", .secondary);
    ctx.badge("Outline", .outline);
    ctx.badge("Destructive", .destructive);
    ctx.end();
    ctx.begin(.row);
    ctx.avatar("EG");
    ctx.avatar("YK");
    ctx.avatar("AL");
    ctx.end();
    ctx.end();
}

fn forms(d: *Demo, ctx: *ui.Context) void {
    ctx.begin(.card);
    ctx.heading(4, "Sign up");
    ctx.label("Name", .{});
    _ = ctx.textInput("Name##field", &d.name, "Ada Lovelace");
    ctx.label("Email", .{});
    _ = ctx.textInput("Email##field", &d.email, "ada@example.com");
    ctx.label("Box size", .{});
    _ = ctx.select("Box size", &.{ "Half dozen", "Dozen", "Flat of thirty" }, &d.size);
    _ = ctx.checkbox("I agree to the terms", &d.terms);
    if (ctx.button("Submit")) d.submitted = true;
    if (d.submitted) {
        if (d.terms and d.name.len > 0)
            ctx.alert("Thanks for signing up", d.name.text(), false)
        else
            ctx.alert("Almost there", "Enter a name and accept the terms.", true);
    }
    ctx.end();

    ctx.begin(.card);
    ctx.heading(4, "Plan");
    _ = ctx.radio("Free", &d.plan, 0);
    _ = ctx.radio("Pro", &d.plan, 1);
    _ = ctx.radio("Team", &d.plan, 2);
    ctx.muted(switch (d.plan) {
        0 => "One coop, community support.",
        1 => "Unlimited coops and priority support.",
        else => "Shared coops, roles and billing.",
    });
    ctx.end();
}

fn feedback(d: *Demo, ctx: *ui.Context) void {
    ctx.begin(.card);
    ctx.heading(4, "Alerts");
    ctx.alert("Heads up", "Eggs hatch faster when it's warm.", false);
    ctx.alert("Coop door open", "Close it before nightfall.", true);
    ctx.end();

    ctx.begin(.card);
    ctx.heading(4, "Loading");
    const t = @as(f32, @floatFromInt(ctx.time_ms % 4000)) / 4000;
    ctx.progress(if (d.reduced_motion) 0.6 else t);
    ctx.begin(.row);
    ctx.spinner();
    ctx.muted("Incubating…");
    ctx.end();
    ctx.skeleton(240, 16);
    ctx.skeleton(180, 16);
    ctx.end();

    ctx.begin(.card);
    ctx.heading(4, "Dialog");
    if (ctx.buttonVariant("Delete project", .destructive)) d.dialog = true;
    if (d.deleted) ctx.muted("Project deleted (not really).");
    ctx.end();
    if (ctx.beginDialog("Delete project?", &d.dialog)) {
        ctx.muted("This removes the coop and every egg in it. Press Escape to cancel.");
        ctx.begin(.row);
        if (ctx.buttonVariant("Cancel", .outline)) d.dialog = false;
        if (ctx.buttonVariant("Delete", .destructive)) {
            d.dialog = false;
            d.deleted = true;
        }
        ctx.end();
        ctx.endDialog();
    }
}

fn data(ctx: *ui.Context) !void {
    ctx.begin(.card);
    ctx.heading(4, "Table");
    ctx.table(&.{ "Hen", "Breed", "Eggs / week" }, &.{
        &.{ "Henrietta", "Orpington", "5" },
        &.{ "Yolanda", "Leghorn", "6" },
        &.{ "Shelly", "Silkie", "3" },
    });
    ctx.end();

    // Components without a Context wrapper go through the builder escape hatch.
    ctx.begin(.card);
    ctx.heading(4, "Chart");
    ctx.element(try ctx.builder().chart(&.{ 5, 6, 3, 7, 4, 6, 5 }));
    ctx.muted("Eggs per day this week.");
    ctx.end();

    ctx.begin(.card);
    ctx.heading(4, "Typeset");
    ctx.element(try ui.widgets.typeset(ctx.builder(),
        \\# Markdown
        \\Rendered with **typeset**: headings, lists and quotes.
        \\- Crack the egg
        \\- Whisk it
        \\> Never trust a runny yolk.
    , .{}));
    ctx.end();
}

fn media(d: *Demo, ctx: *ui.Context) void {
    const images = &d.media.?;
    ctx.begin(.card);
    ctx.heading(4, "PNG");
    ctx.image(&images[0], 160);
    ctx.muted("Straight alpha: the corners are transparent.");
    ctx.end();

    ctx.begin(.card);
    ctx.heading(4, "Animated GIF");
    ctx.image(&images[2], 144);
    ctx.label("{d} frames, {d} ms loop", .{ images[2].frames.len, images[2].duration_ms });
    ctx.end();

    ctx.begin(.card);
    ctx.heading(4, "JPEG");
    ctx.image(&images[1], 320);
    ctx.muted("Also BMP, TGA, PSD, HDR and PNM.");
    ctx.end();

    ctx.begin(.card);
    ctx.heading(4, "Emoji");
    ctx.label("Native color emoji: 🥚 🍳 🐣 🐔", .{});
    ctx.end();
}

fn colour(d: *Demo, ctx: *ui.Context) void {
    ctx.begin(.card);
    ctx.heading(4, "Colour picker");
    _ = ctx.colorPicker("Accent", &d.accent);
    var buffer: [8]u8 = undefined;
    ctx.label("sRGB #{s}, alpha {d:.2}", .{ d.accent.hex(&buffer, .srgb), d.accent.alpha });
    _ = ctx.toggle("Use as the accent colour", &d.custom_accent);
    ctx.end();
}

fn loadMedia(gpa: std.mem.Allocator, font: *ui.Font) ![3]ui.Image {
    var yolk = try ui.Image.load(gpa, font, @embedFile("assets/yolk.png"));
    errdefer yolk.deinit(gpa);
    var sunrise = try ui.Image.load(gpa, font, @embedFile("assets/sunrise.jpg"));
    errdefer sunrise.deinit(gpa);
    return .{ yolk, sunrise, try ui.Image.load(gpa, font, @embedFile("assets/bounce.gif")) };
}

test "every page lays out and paints at desktop and phone widths" {
    var ctx = try ui.Context.init(std.testing.allocator);
    defer ctx.deinit();
    var demo: Demo = .{ .gpa = std.testing.allocator, .appearance = 1 };
    defer demo.deinit();
    for ([_]f32{ 1040, 390 }) |width| for (0..pages.len) |page| {
        demo.page = page;
        demo.dialog = page == 2; // the Feedback page with its dialog open
        for (0..2) |_| {
            ctx.newFrame(.{ .x = 0, .y = 0, .w = width, .h = 760 });
            try frame(&demo, &ctx);
            try std.testing.expect((try ctx.render()).len > 0);
        }
    };
    try std.testing.expectEqual(@as(usize, 12), demo.media.?[2].frames.len);
}
