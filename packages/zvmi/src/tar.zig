//! Minimal tar reader used by OCI layer ingestion.
//!
//! This is intentionally private to the local-OCI feature set for now; if the
//! project later needs a shared tar reader/writer pair, this module can be
//! consolidated then.

const std = @import("std");
const Io = std.Io;

pub const Kind = enum {
    file,
    directory,
    symlink,
    hardlink,
};

pub const Entry = struct {
    path: []const u8,
    kind: Kind,
    mode: u32,
    size: u64,
    content: []const u8,
    link_name: ?[]const u8 = null,
};

pub const Error = error{
    InvalidHeader,
    InvalidOctal,
    InvalidPaxRecord,
    TruncatedArchive,
    UnsupportedType,
    ArchiveTooLarge,
} || std.mem.Allocator.Error || Io.File.ReadPositionalError || Io.File.StatError;

pub const Reader = struct {
    data: []const u8,
    offset: usize = 0,
    pending_pax_path: ?[]const u8 = null,
    pending_pax_link_path: ?[]const u8 = null,
    path_buffer: [256]u8 = undefined,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn next(self: *Reader) Error!?Entry {
        while (true) {
            if (self.offset == self.data.len) return null;
            if (self.offset + 512 > self.data.len) return error.TruncatedArchive;

            const header = self.data[self.offset .. self.offset + 512];
            self.offset += 512;

            if (isZeroBlock(header)) {
                self.pending_pax_path = null;
                self.pending_pax_link_path = null;
                return null;
            }

            const size = try parseOctal(trimField(header[124..136]));
            const next_offset = self.offset + align512(size);
            if (next_offset > self.data.len) return error.TruncatedArchive;

            const typeflag: u8 = header[156];
            const content = self.data[self.offset .. self.offset + size];
            self.offset = next_offset;

            switch (typeflag) {
                0, '0', '1', '2', '5' => {
                    const entry = try self.parseEntry(header, typeflag, content, size);
                    self.pending_pax_path = null;
                    self.pending_pax_link_path = null;
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
            .size = size,
            .content = content,
            .link_name = link_name,
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
                }
            }

            cursor += record_len;
        }
    }
};

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

fn align512(size: usize) usize {
    return std.mem.alignForward(usize, size, 512);
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

const TarSpec = struct {
    path: []const u8,
    mode: u32,
    typeflag: u8,
    content: []const u8,
    link_name: ?[]const u8,
};

fn buildTar(allocator: std.mem.Allocator, specs: []const TarSpec) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, 2048);
    errdefer out.deinit();

    for (specs) |spec| {
        try appendTarEntry(&out, spec);
    }
    try out.writer.splatByteAll(0, 1024);
    return out.toOwnedSlice();
}

fn appendTarEntry(out: *std.Io.Writer.Allocating, spec: TarSpec) !void {
    var header: [512]u8 = [_]u8{0} ** 512;
    if (spec.path.len > 100) return error.InvalidHeader;
    @memcpy(header[0..spec.path.len], spec.path);
    try writeOctalField(header[100..108], spec.mode);
    try writeOctalField(header[108..116], 0);
    try writeOctalField(header[116..124], 0);
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
    const padding = align512(spec.content.len) - spec.content.len;
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
