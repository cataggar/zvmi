//! Minimal USTAR reader/writer shared by OCI layer ingestion and COSI packaging.

const std = @import("std");
const Io = std.Io;

pub const block_size: usize = 512;

pub const Kind = enum {
    file,
    directory,
    symlink,
    hardlink,
};

pub const Xattr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Entry = struct {
    path: []const u8,
    kind: Kind,
    mode: u32,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u64,
    content: []const u8,
    link_name: ?[]const u8 = null,
    xattrs: []const Xattr = &.{},
};

const max_pax_xattrs_per_entry = 256;
const max_pax_xattr_bytes_per_entry = 1024 * 1024;

pub const Error = std.Io.Writer.Error || error{
    InvalidHeader,
    InvalidOctal,
    InvalidPaxRecord,
    TruncatedArchive,
    UnsupportedType,
    ArchiveTooLarge,
    EntryStillOpen,
    EntryNotOpen,
    SizeMismatch,
    PathTooLong,
    ValueTooLarge,
    PaxXattrLimitExceeded,
} || std.mem.Allocator.Error || Io.File.ReadPositionalError || Io.File.StatError;

pub const Reader = struct {
    data: []const u8,
    offset: usize = 0,
    pending_pax_path: ?[]const u8 = null,
    pending_pax_link_path: ?[]const u8 = null,
    pending_pax_uid: ?u32 = null,
    pending_pax_gid: ?u32 = null,
    pending_pax_xattrs: [max_pax_xattrs_per_entry]Xattr = undefined,
    pending_pax_xattr_count: usize = 0,
    pending_pax_xattr_bytes: usize = 0,
    path_buffer: [256]u8 = undefined,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn next(self: *Reader) Error!?Entry {
        while (true) {
            if (self.offset == self.data.len) return null;
            if (self.offset + block_size > self.data.len) return error.TruncatedArchive;

            const header = self.data[self.offset .. self.offset + block_size];
            self.offset += block_size;

            if (isZeroBlock(header)) {
                self.clearPendingPax();
                return null;
            }

            const size = try parseOctal(trimField(header[124..136]));
            const next_offset = self.offset + alignBlock(size);
            if (next_offset > self.data.len) return error.TruncatedArchive;

            const typeflag: u8 = header[156];
            const content = self.data[self.offset .. self.offset + size];
            self.offset = next_offset;

            switch (typeflag) {
                0, '0', '1', '2', '5' => {
                    const entry = try self.parseEntry(header, typeflag, content, size);
                    self.clearPendingPax();
                    return entry;
                },
                'x', 'g' => {
                    try self.parsePax(content, typeflag == 'x');
                    continue;
                },
                else => return error.UnsupportedType,
            }
        }
    }

    fn parseEntry(self: *Reader, header: []const u8, typeflag: u8, content: []const u8, size: usize) Error!Entry {
        const raw_name = trimField(header[0..100]);
        const prefix = trimField(header[345..500]);
        const raw_path = if (self.pending_pax_path) |path|
            path
        else if (prefix.len == 0)
            raw_name
        else blk: {
            if (prefix.len + 1 + raw_name.len > self.path_buffer.len) return error.InvalidHeader;
            @memcpy(self.path_buffer[0..prefix.len], prefix);
            self.path_buffer[prefix.len] = '/';
            @memcpy(self.path_buffer[prefix.len + 1 ..][0..raw_name.len], raw_name);
            break :blk self.path_buffer[0 .. prefix.len + 1 + raw_name.len];
        };

        if (raw_path.len == 0) return error.InvalidHeader;

        const mode: u32 = @intCast(try parseOctal(trimField(header[100..108])));
        const header_uid = std.math.cast(u32, try parseOctal(trimField(header[108..116]))) orelse return error.InvalidOctal;
        const header_gid = std.math.cast(u32, try parseOctal(trimField(header[116..124]))) orelse return error.InvalidOctal;
        const link_name = if (self.pending_pax_link_path) |path| path else blk: {
            const trimmed = trimField(header[157..257]);
            break :blk if (trimmed.len == 0) null else trimmed;
        };

        return .{
            .path = raw_path,
            .kind = switch (typeflag) {
                0, '0' => .file,
                '1' => .hardlink,
                '2' => .symlink,
                '5' => .directory,
                else => unreachable,
            },
            .mode = mode,
            .uid = self.pending_pax_uid orelse header_uid,
            .gid = self.pending_pax_gid orelse header_gid,
            .size = size,
            .content = content,
            .link_name = link_name,
            .xattrs = self.pending_pax_xattrs[0..self.pending_pax_xattr_count],
        };
    }

    fn parsePax(self: *Reader, content: []const u8, local_only: bool) Error!void {
        var cursor: usize = 0;
        while (cursor < content.len) {
            const len_end = std.mem.indexOfScalarPos(u8, content, cursor, ' ') orelse return error.InvalidPaxRecord;
            const record_len = std.fmt.parseInt(usize, content[cursor..len_end], 10) catch return error.InvalidPaxRecord;
            if (record_len == 0 or cursor + record_len > content.len) return error.InvalidPaxRecord;

            const record = content[cursor .. cursor + record_len];
            if (record[record.len - 1] != '\n') return error.InvalidPaxRecord;

            const kv = record[(len_end - cursor + 1) .. record.len - 1];
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.InvalidPaxRecord;
            const key = kv[0..eq];
            const value = kv[eq + 1 ..];

            if (local_only) {
                if (std.mem.eql(u8, key, "path")) {
                    self.pending_pax_path = value;
                } else if (std.mem.eql(u8, key, "linkpath")) {
                    self.pending_pax_link_path = value;
                } else if (std.mem.eql(u8, key, "uid")) {
                    self.pending_pax_uid = std.fmt.parseInt(u32, value, 10) catch return error.InvalidPaxRecord;
                } else if (std.mem.eql(u8, key, "gid")) {
                    self.pending_pax_gid = std.fmt.parseInt(u32, value, 10) catch return error.InvalidPaxRecord;
                } else if (paxXattrName(key)) |name| {
                    try self.appendPaxXattr(name, value);
                }
            }

            cursor += record_len;
        }
    }

    fn clearPendingPax(self: *Reader) void {
        self.pending_pax_path = null;
        self.pending_pax_link_path = null;
        self.pending_pax_uid = null;
        self.pending_pax_gid = null;
        self.pending_pax_xattr_count = 0;
        self.pending_pax_xattr_bytes = 0;
    }

    fn appendPaxXattr(self: *Reader, name: []const u8, value: []const u8) Error!void {
        if (!isRelevantXattrName(name)) return;
        if (self.pending_pax_xattr_count == max_pax_xattrs_per_entry) return error.PaxXattrLimitExceeded;
        const bytes = std.math.add(usize, name.len, value.len) catch return error.PaxXattrLimitExceeded;
        const total = std.math.add(usize, self.pending_pax_xattr_bytes, bytes) catch return error.PaxXattrLimitExceeded;
        if (total > max_pax_xattr_bytes_per_entry) return error.PaxXattrLimitExceeded;
        self.pending_pax_xattrs[self.pending_pax_xattr_count] = .{ .name = name, .value = value };
        self.pending_pax_xattr_count += 1;
        self.pending_pax_xattr_bytes = total;
    }
};

fn paxXattrName(key: []const u8) ?[]const u8 {
    inline for (.{
        "SCHILY.xattr.",
        "LIBARCHIVE.xattr.",
    }) |prefix| {
        if (std.mem.startsWith(u8, key, prefix)) return key[prefix.len..];
    }
    return null;
}

fn isRelevantXattrName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    inline for (.{
        "user.",
        "trusted.",
        "security.",
        "system.",
    }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return name.len > prefix.len;
    }
    return false;
}

pub const OwnedArchive = struct {
    bytes: []u8,

    pub fn deinit(self: *OwnedArchive, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn reader(self: OwnedArchive) Reader {
        return Reader.init(self.bytes);
    }
};

pub fn readFile(io: Io, allocator: std.mem.Allocator, file: Io.File, max_size: usize) Error!OwnedArchive {
    const stat = try file.stat(io);
    if (stat.size > max_size) return error.ArchiveTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return .{ .bytes = bytes };
}

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

fn isZeroBlock(block: []const u8) bool {
    for (block) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn trimField(field: []const u8) []const u8 {
    const nul = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    var trimmed = field[0..nul];
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == ' ') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return trimmed;
}

fn parseOctal(field: []const u8) Error!usize {
    if (field.len == 0) return 0;
    return std.fmt.parseInt(usize, field, 8) catch error.InvalidOctal;
}

fn alignBlock(size: usize) usize {
    return std.mem.alignForward(usize, size, block_size);
}

fn padLen(size: u64) usize {
    const rem: usize = @intCast(size % block_size);
    return if (rem == 0) 0 else block_size - rem;
}

fn makeHeader(path: []const u8, mode: u32, size: u64) Error![block_size]u8 {
    var header: [block_size]u8 = [_]u8{0} ** block_size;

    splitPath(path, header[0..100], header[345..500]) catch return error.PathTooLong;
    try writeOctal(header[100..108], mode, true);
    try writeOctal(header[108..116], 0, true);
    try writeOctal(header[116..124], 0, true);
    try writeOctal(header[124..136], size, true);
    try writeOctal(header[136..148], 0, true);
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

const ReaderTarSpec = struct {
    path: []const u8,
    mode: u32,
    uid: u32 = 0,
    gid: u32 = 0,
    typeflag: u8,
    content: []const u8,
    link_name: ?[]const u8,
};

fn buildTar(allocator: std.mem.Allocator, specs: []const ReaderTarSpec) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, 2048);
    errdefer out.deinit();

    for (specs) |spec| {
        try appendTarEntry(&out, spec);
    }
    try out.writer.splatByteAll(0, 2 * block_size);
    return out.toOwnedSlice();
}

fn appendTarEntry(out: *std.Io.Writer.Allocating, spec: ReaderTarSpec) !void {
    var header: [block_size]u8 = [_]u8{0} ** block_size;
    if (spec.path.len > 100) return error.InvalidHeader;
    @memcpy(header[0..spec.path.len], spec.path);
    try writeOctalField(header[100..108], spec.mode);
    try writeOctalField(header[108..116], spec.uid);
    try writeOctalField(header[116..124], spec.gid);
    try writeOctalField(header[124..136], spec.content.len);
    try writeOctalField(header[136..148], 0);
    @memset(header[148..156], ' ');
    header[156] = spec.typeflag;
    if (spec.link_name) |link_name| {
        if (link_name.len > 100) return error.InvalidHeader;
        @memcpy(header[157..][0..link_name.len], link_name);
    }
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");

    var checksum: u32 = 0;
    for (header) |byte| checksum += byte;
    try writeChecksumField(header[148..156], checksum);

    try out.writer.writeAll(&header);
    try out.writer.writeAll(spec.content);
    const padding = alignBlock(spec.content.len) - spec.content.len;
    if (padding > 0) try out.writer.splatByteAll(0, padding);
}

fn buildPaxRecord(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    var record = try std.fmt.allocPrint(allocator, "0 {s}={s}\n", .{ key, value });
    errdefer allocator.free(record);

    while (true) {
        const len_digits = countBase10(record.len);
        const needed_len = len_digits + 1 + key.len + 1 + value.len + 1;
        if (needed_len == record.len) return record;
        allocator.free(record);
        record = try std.fmt.allocPrint(allocator, "{d} {s}={s}\n", .{ needed_len, key, value });
    }
}

fn countBase10(value: usize) usize {
    var n = value;
    var digits: usize = 1;
    while (n >= 10) : (n /= 10) digits += 1;
    return digits;
}

fn writeOctalField(field: []u8, value: u64) !void {
    if (field.len == 0) return;
    @memset(field, 0);
    var buf: [32]u8 = undefined;
    const octal = try std.fmt.bufPrint(&buf, "{o}", .{value});
    if (octal.len + 1 > field.len) return error.InvalidHeader;
    const digits = field.len - 1;
    @memset(field[0..digits], '0');
    const start = digits - octal.len;
    @memcpy(field[start .. start + octal.len], octal);
}

fn writeChecksumField(field: []u8, value: u32) !void {
    @memset(field, ' ');
    var buf: [16]u8 = undefined;
    const octal = try std.fmt.bufPrint(&buf, "{o}", .{value});
    if (octal.len + 2 > field.len) return error.InvalidHeader;
    const start = field.len - octal.len - 2;
    @memcpy(field[start .. start + octal.len], octal);
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

        const size = try parseTarEntryOctal(trimNul(header[124..136]));
        const payload = archive[offset .. offset + size];
        try list.append(.{ .path = full_path, .payload = payload });
        offset += size + padLen(size);
    }

    return list.toOwnedSlice();
}

fn trimNul(field: []const u8) []const u8 {
    return std.mem.sliceTo(field, 0);
}

fn parseTarEntryOctal(text: []const u8) !usize {
    const trimmed = std.mem.trim(u8, text, " \x00");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(usize, trimmed, 8);
}

test "reader iterates regular tar entries" {
    const bytes = try buildTar(std.testing.allocator, &.{
        .{ .path = "alpha.txt", .mode = 0o644, .typeflag = '0', .content = "alpha", .link_name = null },
        .{ .path = "dir/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "dir/link", .mode = 0o777, .typeflag = '2', .content = "", .link_name = "../alpha.txt" },
    });
    defer std.testing.allocator.free(bytes);

    var reader = Reader.init(bytes);

    const first = (try reader.next()).?;
    try std.testing.expectEqualStrings("alpha.txt", first.path);
    try std.testing.expectEqual(Kind.file, first.kind);
    try std.testing.expectEqual(@as(u64, 5), first.size);
    try std.testing.expectEqualSlices(u8, "alpha", first.content);

    const second = (try reader.next()).?;
    try std.testing.expectEqualStrings("dir/", second.path);
    try std.testing.expectEqual(Kind.directory, second.kind);

    const third = (try reader.next()).?;
    try std.testing.expectEqualStrings("dir/link", third.path);
    try std.testing.expectEqual(Kind.symlink, third.kind);
    try std.testing.expectEqualStrings("../alpha.txt", third.link_name.?);

    try std.testing.expect((try reader.next()) == null);
}

test "reader honors pax path override" {
    const long_path = "very/long/path/component-that-exceeds-ustar-name-field/with/a/final-file.txt";
    const pax_record = try buildPaxRecord(std.testing.allocator, "path", long_path);
    defer std.testing.allocator.free(pax_record);

    const bytes = try buildTar(std.testing.allocator, &.{
        .{ .path = "PaxHeaders/path", .mode = 0o644, .typeflag = 'x', .content = pax_record, .link_name = null },
        .{ .path = "placeholder", .mode = 0o644, .typeflag = '0', .content = "payload", .link_name = null },
    });
    defer std.testing.allocator.free(bytes);

    var reader = Reader.init(bytes);
    const entry = (try reader.next()).?;
    try std.testing.expectEqualStrings(long_path, entry.path);
    try std.testing.expectEqualSlices(u8, "payload", entry.content);
    try std.testing.expect((try reader.next()) == null);
}

test "reader preserves USTAR ownership and bounded relevant PAX xattrs" {
    const allocator = std.testing.allocator;
    const uid = try buildPaxRecord(allocator, "uid", "4242");
    defer allocator.free(uid);
    const gid = try buildPaxRecord(allocator, "gid", "4343");
    defer allocator.free(gid);
    const capability = try buildPaxRecord(allocator, "SCHILY.xattr.security.capability", "cap-bytes");
    defer allocator.free(capability);
    const ignored = try buildPaxRecord(allocator, "SCHILY.xattr.invalid.namespace", "ignored");
    defer allocator.free(ignored);
    const pax = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ uid, gid, capability, ignored });
    defer allocator.free(pax);

    const bytes = try buildTar(allocator, &.{
        .{ .path = "PaxHeaders/meta", .mode = 0o644, .typeflag = 'x', .content = pax, .link_name = null },
        .{ .path = "owned", .mode = 0o640, .uid = 1, .gid = 2, .typeflag = '0', .content = "payload", .link_name = null },
    });
    defer allocator.free(bytes);

    var reader = Reader.init(bytes);
    const entry = (try reader.next()).?;
    try std.testing.expectEqualStrings("owned", entry.path);
    try std.testing.expectEqual(@as(u32, 4242), entry.uid);
    try std.testing.expectEqual(@as(u32, 4343), entry.gid);
    try std.testing.expectEqual(@as(usize, 1), entry.xattrs.len);
    try std.testing.expectEqualStrings("security.capability", entry.xattrs[0].name);
    try std.testing.expectEqualStrings("cap-bytes", entry.xattrs[0].value);
}

test "reader rejects PAX xattrs beyond the per-entry bound" {
    const allocator = std.testing.allocator;
    var pax = std.Io.Writer.Allocating.init(allocator);
    defer pax.deinit();
    for (0..max_pax_xattrs_per_entry + 1) |index| {
        const value = try std.fmt.allocPrint(allocator, "{d}", .{index});
        defer allocator.free(value);
        const record = try buildPaxRecord(allocator, "SCHILY.xattr.user.bound", value);
        defer allocator.free(record);
        try pax.writer.writeAll(record);
    }
    const bytes = try buildTar(allocator, &.{
        .{ .path = "PaxHeaders/overflow", .mode = 0o644, .typeflag = 'x', .content = pax.written(), .link_name = null },
        .{ .path = "overflow", .mode = 0o644, .typeflag = '0', .content = "payload", .link_name = null },
    });
    defer allocator.free(bytes);

    var reader = Reader.init(bytes);
    try std.testing.expectError(error.PaxXattrLimitExceeded, reader.next());
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
