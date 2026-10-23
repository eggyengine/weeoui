//! Build tool: copy a static library (`ar` archive) with the DWARF of each ELF64 object in it
//! emptied, for `strip_debug_info <in.a> <out.a>`. Each `.debug_*` section and its relocations keep
//! their place but get size 0, so nothing else in the object moves.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const in_path = args.next() orelse return error.MissingInput;
    const out_path = args.next() orelse return error.MissingOutput;

    const archive = try std.Io.Dir.cwd().readFileAlloc(io, in_path, gpa, .unlimited);
    defer gpa.free(archive);
    try emptyDebugSections(archive);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = archive });
}

const magic = "!<arch>\n";
const member_header_len = 60;

/// Empty the DWARF of every ELF64 little-endian member of `archive`, in place.
fn emptyDebugSections(archive: []u8) !void {
    if (!std.mem.startsWith(u8, archive, magic)) return error.NotAnArchive;
    var at: usize = magic.len;
    while (at + member_header_len <= archive.len) {
        const header = archive[at..][0..member_header_len];
        if (!std.mem.eql(u8, header[58..60], "`\n")) return error.BadMemberHeader;
        const size = try std.fmt.parseInt(usize, std.mem.trimEnd(u8, header[48..58], " "), 10);
        const data_at = at + member_header_len;
        if (data_at + size > archive.len) return error.TruncatedArchive;
        try emptyObjectDebugSections(archive[data_at..][0..size]);
        // Members start on even offsets.
        at = data_at + size + (size & 1);
    }
}

/// Set the size of `object`'s `.debug_*` and `.rela.debug_*` sections to 0. Anything that isn't
/// an ELF64 little-endian object (the archive's symbol and name tables) is left alone.
fn emptyObjectDebugSections(object: []u8) !void {
    if (object.len < 64 or !std.mem.eql(u8, object[0..4], "\x7fELF") or object[4] != 2 or object[5] != 1) return;
    const section_headers_at = std.mem.readInt(u64, object[0x28..][0..8], .little);
    const header_len = std.mem.readInt(u16, object[0x3a..][0..2], .little);
    if (section_headers_at == 0 or header_len < 64) return;
    const first = try sectionHeader(object, section_headers_at, header_len, 0);

    // Past 0xff00 sections, the count and the names' index live in the first section header.
    var count: u64 = std.mem.readInt(u16, object[0x3c..][0..2], .little);
    if (count == 0) count = std.mem.readInt(u64, first[32..40], .little);
    var names_index: u64 = std.mem.readInt(u16, object[0x3e..][0..2], .little);
    if (names_index == 0xffff) names_index = std.mem.readInt(u32, first[40..44], .little);
    const names_header = try sectionHeader(object, section_headers_at, header_len, names_index);
    const names_at = std.mem.readInt(u64, names_header[24..32], .little);
    const names_len = std.mem.readInt(u64, names_header[32..40], .little);
    if (names_at + names_len > object.len) return error.TruncatedObject;
    const names = object[names_at..][0..names_len];

    for (0..count) |index| {
        const header = try sectionHeader(object, section_headers_at, header_len, index);
        const name_at = std.mem.readInt(u32, header[0..4], .little);
        if (name_at >= names.len) return error.BadSectionName;
        const name = std.mem.sliceTo(names[name_at..], 0);
        if (std.mem.startsWith(u8, name, ".debug_") or std.mem.startsWith(u8, name, ".rela.debug_")) {
            std.mem.writeInt(u64, header[32..40], 0, .little);
        }
    }
}

fn sectionHeader(object: []u8, headers_at: u64, header_len: u16, index: u64) !*[64]u8 {
    const at = headers_at + index * header_len;
    if (at + 64 > object.len) return error.TruncatedObject;
    return object[at..][0..64];
}

test "an object's debug sections are emptied, and nothing else" {
    // An ELF64 object with sections: null, .shstrtab, .text, .debug_info, .rela.debug_info.
    const names = "\x00.shstrtab\x00.text\x00.debug_info\x00.rela.debug_info\x00";
    var object: [64 + names.len + 5 * 64]u8 = @splat(0);
    @memcpy(object[0..6], "\x7fELF\x02\x01");
    const headers_at = 64 + names.len;
    std.mem.writeInt(u64, object[0x28..][0..8], headers_at, .little);
    std.mem.writeInt(u16, object[0x3a..][0..2], 64, .little);
    std.mem.writeInt(u16, object[0x3c..][0..2], 5, .little);
    std.mem.writeInt(u16, object[0x3e..][0..2], 1, .little);
    @memcpy(object[64..][0..names.len], names);
    const name_offsets = [_]u32{ 0, 1, 11, 17, 29 };
    for (name_offsets, 0..) |name_at, i| {
        const header = object[headers_at + i * 64 ..][0..64];
        std.mem.writeInt(u32, header[0..4], name_at, .little);
        std.mem.writeInt(u64, header[32..40], 7, .little);
    }
    std.mem.writeInt(u64, object[headers_at + 64 + 24 ..][0..8], 64, .little);
    std.mem.writeInt(u64, object[headers_at + 64 + 32 ..][0..8], names.len, .little);

    try emptyObjectDebugSections(&object);
    const sizes = [_]u64{ 7, names.len, 7, 0, 0 };
    for (sizes, 0..) |expected, i| {
        try std.testing.expectEqual(expected, std.mem.readInt(u64, object[headers_at + i * 64 + 32 ..][0..8], .little));
    }
}
