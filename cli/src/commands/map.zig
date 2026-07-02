//! `zvmi map [--output=human|json] <file>`

const std = @import("std");
const zvmi = @import("zvmi");

const OutputMode = enum { human, json };

pub fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    var output: OutputMode = .human;
    var path: ?[]const u8 = null;

    for (args) |a| {
        if (std.mem.eql(u8, a, "--output=json")) {
            output = .json;
        } else if (std.mem.eql(u8, a, "--output=human")) {
            output = .human;
        } else if (path == null) {
            path = a;
        } else {
            return fail("map: unexpected argument '{s}'", .{a});
        }
    }

    const file_path = path orelse return fail("usage: zvmi map [--output=human|json] <file>", .{});

    var img = zvmi.Image.openPath(io, file_path) catch |err|
        return fail("map: failed to open '{s}': {s}", .{ file_path, @errorName(err) });
    defer img.close(io);

    const extents = img.mapExtents(io, gpa) catch |err|
        return fail("map: failed: {s}", .{@errorName(err)});
    defer gpa.free(extents);

    switch (output) {
        .human => {
            std.debug.print("{s: <12} {s: <12} {s}\n", .{ "Offset", "Length", "Mapped" });
            for (extents) |e| {
                std.debug.print("0x{x: <10} 0x{x: <10} {s}\n", .{ e.offset, e.length, if (e.allocated) "true" else "false" });
            }
        },
        .json => {
            var buf: [256]u8 = undefined;
            std.debug.print("[", .{});
            for (extents, 0..) |e, idx| {
                var writer = std.Io.Writer.fixed(&buf);
                std.json.Stringify.value(.{
                    .start = e.offset,
                    .length = e.length,
                    .data = e.allocated,
                }, .{}, &writer) catch |err|
                    return fail("map: failed to format JSON: {s}", .{@errorName(err)});
                std.debug.print("{s}{s}", .{ writer.buffered(), if (idx + 1 < extents.len) "," else "" });
            }
            std.debug.print("]\n", .{});
        },
    }

    return 0;
}

fn fail(comptime format: []const u8, args: anytype) u8 {
    std.debug.print(format ++ "\n", args);
    return 1;
}
