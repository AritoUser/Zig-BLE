//! Extracts one of the Zig programs shown in a Markdown file, so `zig build check-readme` can
//! compile exactly what the README shows.
//!
//!   readme-examples <markdown> <index> <expected count> <output.zig>
//!
//! A program is a ```zig block that defines `pub fn main`. The count is checked so a new
//! example cannot be added without the build compiling it.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) {
        std.debug.print("usage: readme-examples <markdown> <index> <expected count> <output.zig>\n", .{});
        return error.InvalidArguments;
    }
    const index = try std.fmt.parseInt(usize, args[2], 10);
    const expected = try std.fmt.parseInt(usize, args[3], 10);

    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(8 << 20));
    defer gpa.free(text);

    var found: usize = 0;
    var wanted: ?[]const u8 = null;
    var block_start: ?usize = null;
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line_start = offset;
        offset += raw_line.len + 1;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (block_start) |start| {
            if (!std.mem.eql(u8, line, "```")) continue;
            const block = text[start..line_start];
            block_start = null;
            if (std.mem.find(u8, block, "pub fn main(") == null) continue;
            if (found == index) wanted = block;
            found += 1;
        } else if (std.mem.eql(u8, line, "```zig")) {
            block_start = @min(offset, text.len);
        }
    }

    if (found != expected) {
        std.debug.print(
            "{s} shows {d} Zig programs, build.zig compiles {d}: update readme_example_count.\n",
            .{ args[1], found, expected },
        );
        return error.ExampleCountMismatch;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[4], .data = wanted orelse return error.NoSuchExample });
}
