const std = @import("std");
const initramfs = @import("initramfs");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_fw.interface;

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) {
        try out.print("usage: {s} <initramfs-path>\n", .{args[0]});
        try out.flush();
        return error.Usage;
    }

    const file = try std.Io.Dir.cwd().openFile(io, args[1], .{ .mode = .read_only });
    defer file.close(io);
    const stat = try file.stat(io);
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    const got = try file.readPositionalAll(io, bytes, 0);

    try out.print("read {d} bytes from {s}; first 8 bytes: {x}\n", .{ got, args[1], bytes[0..@min(8, got)] });

    const status = try initramfs.checkVerityTooling(allocator, bytes[0..got]);
    try out.print("checkVerityTooling result: {s}\n", .{@tagName(status)});
    try out.flush();
}
