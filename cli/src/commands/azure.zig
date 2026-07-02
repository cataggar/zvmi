//! `zvmi azure fixup --generation 1|2 <file>`

const std = @import("std");
const zvmi = @import("zvmi");

pub fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    if (args.len < 1 or !std.mem.eql(u8, args[0], "fixup")) {
        return fail("usage: zvmi azure fixup --generation 1|2 <file>", .{});
    }
    const rest = args[1..];

    var generation: ?zvmi.azure.Generation = null;
    var path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--generation")) {
            i += 1;
            if (i >= rest.len) return fail("azure fixup: --generation requires an argument (1 or 2)", .{});
            if (std.mem.eql(u8, rest[i], "1")) {
                generation = .gen1;
            } else if (std.mem.eql(u8, rest[i], "2")) {
                generation = .gen2;
            } else {
                return fail("azure fixup: invalid --generation '{s}' (expected 1 or 2)", .{rest[i]});
            }
        } else if (path == null) {
            path = a;
        } else {
            return fail("azure fixup: unexpected argument '{s}'", .{a});
        }
    }

    const gen = generation orelse return fail("azure fixup: --generation 1|2 is required", .{});
    const file_path = path orelse return fail("usage: zvmi azure fixup --generation 1|2 <file>", .{});

    var img = zvmi.Image.openPath(io, file_path) catch |err|
        return fail("azure fixup: failed to open '{s}': {s}", .{ file_path, @errorName(err) });
    defer img.close(io);

    const align_result = zvmi.azure.alignFixedVhd(&img, io) catch |err| return fail(
        "azure fixup: {s} (Azure managed-disk upload requires a *fixed* .vhd; convert first with " ++
            "'zvmi convert -O vhd -o subformat=fixed <src> {s}')",
        .{ @errorName(err), file_path },
    );
    if (align_result.was_resized) {
        std.debug.print("Padded virtual size from {d} to {d} bytes (1 MiB alignment).\n", .{ align_result.old_size, align_result.new_size });
    } else {
        std.debug.print("Virtual size {d} bytes is already 1 MiB-aligned.\n", .{align_result.new_size});
    }

    const report = zvmi.azure.checkPartitionStyle(img, io, gpa, gen) catch |err|
        return fail("azure fixup: failed to check partition style: {s}", .{@errorName(err)});

    const gen_name: []const u8 = if (gen == .gen1) "Gen1" else "Gen2";
    if (report.ok) {
        std.debug.print("Partition style OK for {s}: {s}\n", .{ gen_name, report.message });
        return 0;
    }
    std.debug.print("Partition style check FAILED for {s}: {s}\n", .{ gen_name, report.message });
    return 2;
}

fn fail(comptime format: []const u8, args: anytype) u8 {
    std.debug.print(format ++ "\n", args);
    return 1;
}
