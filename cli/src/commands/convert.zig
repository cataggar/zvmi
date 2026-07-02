//! `zvmi convert -f <src_format> -O <dst_format> [-o subformat=fixed|dynamic] <src> <dst>`

const std = @import("std");
const zvmi = @import("zvmi");
const opts = @import("opts.zig");

pub fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    var dst_format: ?zvmi.Format = null;
    var options: zvmi.CreateOptions = .{};
    var positional: [2][]const u8 = undefined;
    var positional_count: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-f")) {
            // Source format is auto-detected by Image.openPath; -f is
            // accepted (like qemu-img) but only used as a sanity check.
            i += 1;
            if (i >= args.len) return fail("convert: -f requires a format argument", .{});
            if (zvmi.Format.parseName(args[i]) == null)
                return fail("convert: unknown source format '{s}'", .{args[i]});
        } else if (std.mem.eql(u8, a, "-O")) {
            i += 1;
            if (i >= args.len) return fail("convert: -O requires a format argument", .{});
            dst_format = zvmi.Format.parseName(args[i]) orelse
                return fail("convert: unknown destination format '{s}'", .{args[i]});
        } else if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= args.len) return fail("convert: -o requires an option list", .{});
            options = opts.parseVhdCreateOptions(args[i]) orelse return 1;
        } else if (positional_count < positional.len) {
            positional[positional_count] = a;
            positional_count += 1;
        } else {
            return fail("convert: unexpected argument '{s}'", .{a});
        }
    }

    if (positional_count != 2) {
        return fail("usage: zvmi convert -f <src_format> -O <dst_format> [-o subformat=fixed|dynamic] <src> <dst>", .{});
    }
    const dst_fmt = dst_format orelse return fail("convert: -O <format> is required", .{});
    const src_path = positional[0];
    const dst_path = positional[1];

    var src = zvmi.Image.openPath(io, src_path) catch |err|
        return fail("convert: failed to open '{s}': {s}", .{ src_path, @errorName(err) });
    defer src.close(io);

    var dst = zvmi.Image.create(io, dst_path, dst_fmt, src.virtual_size, options) catch |err|
        return fail("convert: failed to create '{s}': {s}", .{ dst_path, @errorName(err) });
    defer dst.close(io);

    zvmi.copyAll(io, src, &dst, gpa) catch |err|
        return fail("convert: copy failed: {s}", .{@errorName(err)});

    return 0;
}

fn fail(comptime format: []const u8, args: anytype) u8 {
    std.debug.print(format ++ "\n", args);
    return 1;
}
