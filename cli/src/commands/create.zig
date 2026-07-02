//! `zvmi create -f <format> [-o key=value,...] <file> <size>`

const std = @import("std");
const zvmi = @import("zvmi");

pub fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    var format: ?zvmi.Format = null;
    var positional: [2][]const u8 = undefined;
    var positional_count: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-f")) {
            i += 1;
            if (i >= args.len) return fail("create: -f requires a format argument", .{});
            format = zvmi.Format.parseName(args[i]) orelse
                return fail("create: unknown format '{s}' (expected raw, vhd, or vpc)", .{args[i]});
        } else if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= args.len) return fail("create: -o requires an option list", .{});
            // Options are accepted but not yet used by any format (no
            // per-format tunables exist until dynamic vhd/qcow2 land).
        } else if (positional_count < positional.len) {
            positional[positional_count] = a;
            positional_count += 1;
        } else {
            return fail("create: unexpected argument '{s}'", .{a});
        }
    }

    if (positional_count != 2) {
        return fail("usage: zvmi create -f <format> <file> <size>", .{});
    }
    const fmt = format orelse return fail("create: -f <format> is required", .{});
    const path = positional[0];
    const size = zvmi.parseSize(positional[1]) catch |err|
        return fail("create: invalid size '{s}': {s}", .{ positional[1], @errorName(err) });

    _ = gpa;
    var img = zvmi.Image.create(io, path, fmt, size) catch |err|
        return fail("create: failed to create '{s}': {s}", .{ path, @errorName(err) });
    img.close(io);

    std.debug.print("Formatting '{s}', fmt={s} size={d}\n", .{ path, fmt.displayName(), size });
    return 0;
}

fn fail(comptime format: []const u8, args: anytype) u8 {
    std.debug.print(format ++ "\n", args);
    return 1;
}
