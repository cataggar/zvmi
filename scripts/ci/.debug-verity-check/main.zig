const std = @import("std");
const cpio = @import("cpio");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [8192]u8 = undefined;
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

    // Decompress (assume zstd, matching what we've observed) using a
    // properly-sized indirect-mode window buffer, then list every cpio
    // entry whose path contains "verity", to see the exact stored path
    // format the real dracut-produced archive uses.
    var input = std.Io.Reader.fixed(bytes[0..got]);
    const window_len = std.compress.zstd.default_window_len;
    const window_buf = try allocator.alloc(u8, window_len + std.compress.zstd.block_size_max);
    var decompressor = std.compress.zstd.Decompress.init(&input, window_buf, .{ .window_len = window_len });
    const decompressed = decompressor.reader.allocRemaining(allocator, .limited(1 << 30)) catch |err| {
        try out.print("decompress error: {s}\n", .{@errorName(err)});
        try out.flush();
        return;
    };
    try out.print("decompressed to {d} bytes\n", .{decompressed.len});

    var reader = cpio.Reader.init(decompressed);
    var count: usize = 0;
    var matches: usize = 0;
    while (true) {
        const entry = reader.next() catch |err| {
            try out.print("cpio parse error after {d} entries at offset {d}: {s}\n", .{ count, reader.offset, @errorName(err) });
            break;
        };
        const e = entry orelse break;
        count += 1;
        if (std.mem.indexOf(u8, e.path, "verity") != null) {
            matches += 1;
            try out.print("MATCH: path=\"{s}\" kind={s} mode={o}\n", .{ e.path, @tagName(e.kind), e.mode });
        }
    }
    try out.print("total cpio entries: {d}, verity-path matches: {d}, final cpio offset: {d} (decompressed len {d})\n", .{ count, matches, reader.offset, decompressed.len });
    try out.flush();
}


