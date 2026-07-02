//! `zvmi`: a qemu-img-like CLI over the `zvmi` library. Milestone 1 supports
//! `create`, `info`, and `convert` for `raw` and fixed `vhd`.

const std = @import("std");
const zvmi = @import("zvmi");

const create_cmd = @import("commands/create.zig");
const info_cmd = @import("commands/info.zig");
const convert_cmd = @import("commands/convert.zig");

const usage =
    \\Usage: zvmi <command> [options]
    \\
    \\Commands:
    \\  create -f <format> [-o key=value,...] <file> <size>
    \\  info [--output=human|json] <file>
    \\  convert -f <src_format> -O <dst_format> <src> <dst>
    \\
    \\Formats: raw, vhd (alias: vpc)
    \\Sizes accept K/M/G/T binary suffixes (e.g. 20G).
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    const exit_code = run(gpa, io, argv[1..]);
    std.process.exit(exit_code);
}

fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    if (args.len < 1) {
        std.debug.print("{s}", .{usage});
        return 1;
    }

    const command = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, command, "create")) return create_cmd.run(gpa, io, rest);
    if (std.mem.eql(u8, command, "info")) return info_cmd.run(gpa, io, rest);
    if (std.mem.eql(u8, command, "convert")) return convert_cmd.run(gpa, io, rest);
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }
    std.debug.print("zvmi: unknown command '{s}'\n\n{s}", .{ command, usage });
    return 1;
}

test {
    _ = create_cmd;
    _ = info_cmd;
    _ = convert_cmd;
}
