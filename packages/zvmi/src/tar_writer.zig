//! Minimal USTAR writer used by `cosi.zig` to package `metadata.json` and the
//! per-partition `images/*.raw.zst` artifacts into a single `.cosi` tarball.
//! Keep this module narrowly scoped for now; a future OCI-ingestion feature may
//! want a shared tar reader/writer abstraction, but that consolidation would be
//! a separate change.

const std = @import("std");

pub const block_size: usize = 512;

pub const Error = std.Io.Writer.Error || error{
    EntryStillOpen,
    EntryNotOpen,
    SizeMismatch,
    PathTooLong,
    ValueTooLarge,
};

pub const StreamingEntryWriter = struct {
    parent: *Writer,
    interface: std.Io.Writer,

    pub fn init(parent: *Writer, buffer: []u8) StreamingEntryWriter {
        return .{
            .parent = parent,
            .interface = .{
                .buffer = buffer,
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                },
            },
        };
    }

    fn commit(self: *StreamingEntryWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (!self.parent.entry_open or bytes.len > self.parent.bytes_remaining) return error.WriteFailed;
        try self.parent.out.writeAll(bytes);
        self.parent.bytes_remaining -= bytes.len;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *StreamingEntryWriter = @alignCast(@fieldParentPtr("interface", w));
        const buffered = w.buffered();
        if (buffered.len > 0) try self.commit(buffered);
        w.end = 0;

        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            try self.commit(slice);
            total += slice.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.commit(pattern);
            total += pattern.len;
        }
        return total;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *StreamingEntryWriter = @alignCast(@fieldParentPtr("interface", w));
        const buffered = w.buffered();
        if (buffered.len > 0) try self.commit(buffered);
        w.end = 0;
    }
};

pub const Writer = struct {
    out: *std.Io.Writer,
    bytes_remaining: u64 = 0,
    pad_bytes: usize = 0,
    entry_open: bool = false,

    pub fn init(out: *std.Io.Writer) Writer {
        return .{ .out = out };
    }

    pub fn beginFile(self: *Writer, path: []const u8, mode: u32, size: u64) Error!void {
        if (self.entry_open) return error.EntryStillOpen;

        var header = try makeHeader(path, mode, size);
        try self.out.writeAll(&header);
        self.bytes_remaining = size;
        self.pad_bytes = padLen(size);
        self.entry_open = true;
    }

    pub fn writeAll(self: *Writer, bytes: []const u8) Error!void {
        if (!self.entry_open) return error.EntryNotOpen;
        if (bytes.len > self.bytes_remaining) return error.SizeMismatch;
        try self.out.writeAll(bytes);
        self.bytes_remaining -= bytes.len;
    }

    pub fn endFile(self: *Writer) Error!void {
        if (!self.entry_open) return error.EntryNotOpen;
        if (self.bytes_remaining != 0) return error.SizeMismatch;

        if (self.pad_bytes > 0) {
            const zeros = [_]u8{0} ** block_size;
            try self.out.writeAll(zeros[0..self.pad_bytes]);
        }
        self.pad_bytes = 0;
        self.entry_open = false;
    }

    pub fn entryWriter(self: *Writer, buffer: []u8) StreamingEntryWriter {
        return StreamingEntryWriter.init(self, buffer);
    }

    pub fn writeFile(self: *Writer, path: []const u8, mode: u32, bytes: []const u8) Error!void {
        try self.beginFile(path, mode, bytes.len);
        try self.writeAll(bytes);
        try self.endFile();
    }

    pub fn finish(self: *Writer) Error!void {
        if (self.entry_open) return error.EntryStillOpen;
        const zeros = [_]u8{0} ** block_size;
        try self.out.writeAll(&zeros);
        try self.out.writeAll(&zeros);
        try self.out.flush();
    }
};

fn padLen(size: u64) usize {
    const rem: usize = @intCast(size % block_size);
    return if (rem == 0) 0 else block_size - rem;
}

fn makeHeader(path: []const u8, mode: u32, size: u64) Error![block_size]u8 {
    var header: [block_size]u8 = [_]u8{0} ** block_size;

    splitPath(path, header[0..100], header[345..500]) catch return error.PathTooLong;
    try writeOctal(header[100..108], mode, true);
    try writeOctal(header[108..116], 0, true); // uid
    try writeOctal(header[116..124], 0, true); // gid
    try writeOctal(header[124..136], size, true);
    try writeOctal(header[136..148], 0, true); // mtime
    @memset(header[148..156], ' ');
    header[156] = '0';
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");

    const checksum = checksumForHeader(&header);
    writeChecksum(header[148..156], checksum);
    return header;
}

fn checksumForHeader(header: *const [block_size]u8) u32 {
    var sum: u32 = 0;
    for (header) |byte| sum += byte;
    return sum;
}

fn splitPath(path: []const u8, name_field: []u8, prefix_field: []u8) error{PathTooLong}!void {
    if (path.len <= name_field.len) {
        @memcpy(name_field[0..path.len], path);
        return;
    }

    var split_at: ?usize = null;
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] != '/') continue;
        const prefix = path[0 .. i - 1];
        const name = path[i..];
        if (prefix.len <= prefix_field.len and name.len <= name_field.len) {
            split_at = i;
            break;
        }
    }

    const split = split_at orelse return error.PathTooLong;
    const prefix = path[0 .. split - 1];
    const name = path[split..];
    @memcpy(prefix_field[0..prefix.len], prefix);
    @memcpy(name_field[0..name.len], name);
}

fn writeOctal(field: []u8, value: u64, nul_terminated: bool) Error!void {
    @memset(field, 0);
    const digits_len: usize = if (nul_terminated) field.len - 1 else field.len;
    var digits = field[0..digits_len];
    @memset(digits, '0');

    var n = value;
    var idx = digits.len;
    while (idx > 0 and n > 0) {
        idx -= 1;
        digits[idx] = @as(u8, @intCast('0' + (n & 7)));
        n >>= 3;
    }
    if (n != 0) return error.ValueTooLarge;
}

fn writeChecksum(field: []u8, checksum: u32) void {
    @memset(field, 0);
    const digits = field[0 .. field.len - 2];
    @memset(digits, '0');

    var n: u64 = checksum;
    var idx = digits.len;
    while (idx > 0 and n > 0) {
        idx -= 1;
        digits[idx] = @as(u8, @intCast('0' + (n & 7)));
        n >>= 3;
    }
    field[field.len - 2] = 0;
    field[field.len - 1] = ' ';
}

const TarEntry = struct {
    path: []const u8,
    payload: []const u8,
};

fn parseEntries(allocator: std.mem.Allocator, archive: []const u8) ![]TarEntry {
    var list = std.array_list.Managed(TarEntry).init(allocator);
    errdefer list.deinit();

    var offset: usize = 0;
    while (offset + block_size <= archive.len) {
        const header = archive[offset .. offset + block_size];
        offset += block_size;
        if (std.mem.allEqual(u8, header, 0)) break;

        const name = trimNul(header[0..100]);
        const prefix = trimNul(header[345..500]);
        const full_path = if (prefix.len == 0)
            try allocator.dupe(u8, name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });

        const size = try parseOctal(trimNul(header[124..136]));
        const payload = archive[offset .. offset + size];
        try list.append(.{ .path = full_path, .payload = payload });
        offset += size + padLen(size);
    }

    return list.toOwnedSlice();
}

fn trimNul(field: []const u8) []const u8 {
    return std.mem.sliceTo(field, 0);
}

fn parseOctal(text: []const u8) !usize {
    const trimmed = std.mem.trim(u8, text, " \x00");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(usize, trimmed, 8);
}

test "writes a small USTAR archive" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var writer = Writer.init(&out.writer);
    try writer.writeFile("metadata.json", 0o400, "{}\n");
    try writer.writeFile("images/part.raw.zst", 0o400, "payload");
    try writer.finish();

    const entries = try parseEntries(std.testing.allocator, out.written());
    defer {
        for (entries) |entry| std.testing.allocator.free(entry.path);
        std.testing.allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("metadata.json", entries[0].path);
    try std.testing.expectEqualStrings("{}\n", entries[0].payload);
    try std.testing.expectEqualStrings("images/part.raw.zst", entries[1].path);
    try std.testing.expectEqualStrings("payload", entries[1].payload);
}
