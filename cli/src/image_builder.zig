//! Host-native entry point used by the exported `std.Build` image helper.

const std = @import("std");
const build_image_cmd = @import("commands/build_image.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    std.process.exit(build_image_cmd.run(init.gpa, init.io, argv[1..]));
}

test {
    _ = build_image_cmd;
}
