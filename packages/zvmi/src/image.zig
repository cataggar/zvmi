//! The `Image` abstraction: a format-agnostic view over a disk image file,
//! analogous to qemu's `BlockDriver`. Milestone 1 supports `raw` and fixed
//! `vhd` only; dynamic vhd, vhdx, and qcow2 are later milestones (see the
//! project plan). Because there are only ever a handful of formats, this
//! uses a plain tagged union rather than a vtable/`anyopaque` interface --
//! simpler and fully type-safe for a small, closed set of variants.
//!
//! Every operation takes an explicit `std.Io` parameter (Zig 0.16's I/O
//! interface), matching the pattern used by `std.Io.File`/`std.Io.Dir`
//! themselves -- there is no implicit global filesystem or event loop.

const std = @import("std");
const Io = std.Io;
const vhd = @import("vhd.zig");
pub const Format = @import("formats.zig").Format;

pub const OpenError = error{
    UnsupportedVhdDiskType,
} || Io.File.OpenError || Io.File.ReadPositionalError || Io.File.StatError || vhd.Footer.DecodeError;

pub const CreateError = error{
    SizeNotSectorAligned,
} || Io.File.OpenError || Io.File.WritePositionalError || Io.File.SetLengthError;

pub const Info = struct {
    format: Format,
    /// Guest-visible disk size, in bytes.
    virtual_size: u64,
    /// Bytes actually occupied by the file on disk (host-side file size;
    /// for `raw`/fixed `vhd` this is the same as the file length, since
    /// neither format is sparse-aware yet).
    file_size: u64,
};

pub const Image = struct {
    file: Io.File,
    format: Format,
    /// Offset within `file` where guest-visible byte 0 lives (0 for both
    /// raw and fixed vhd -- fixed vhd's footer is a trailer, not a header).
    data_offset: u64,
    virtual_size: u64,

    pub fn openPath(io: Io, path: []const u8) OpenError!Image {
        const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);
        return openFile(io, file);
    }

    /// Takes ownership of `file` (closing the returned `Image` closes it).
    pub fn openFile(io: Io, file: Io.File) OpenError!Image {
        const file_size = (try file.stat(io)).size;

        if (file_size >= vhd.footer_size) {
            var footer_buf: [vhd.footer_size]u8 = undefined;
            const n = try file.readPositionalAll(io, &footer_buf, file_size - vhd.footer_size);
            if (n == vhd.footer_size) {
                if (vhd.Footer.decode(&footer_buf)) |footer| {
                    if (footer.disk_type != .fixed) return error.UnsupportedVhdDiskType;
                    return .{
                        .file = file,
                        .format = .vhd,
                        .data_offset = 0,
                        .virtual_size = footer.current_size,
                    };
                } else |_| {
                    // Not a valid VHD footer -- fall through and treat as raw.
                }
            }
        }

        return .{
            .file = file,
            .format = .raw,
            .data_offset = 0,
            .virtual_size = file_size,
        };
    }

    /// Creates a brand-new image file of the given format and virtual size.
    /// `size` must be a multiple of the 512-byte sector size.
    pub fn create(io: Io, path: []const u8, format: Format, size: u64) CreateError!Image {
        if (size % 512 != 0) return error.SizeNotSectorAligned;

        const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
        errdefer file.close(io);

        switch (format) {
            .raw => {
                try file.setLength(io, size);
                return .{ .file = file, .format = .raw, .data_offset = 0, .virtual_size = size };
            },
            .vhd => {
                try file.setLength(io, size + vhd.footer_size);
                const now_unix: i64 = @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
                const footer = vhd.Footer.forFixedDisk(size, randomUuid(io), now_unix);
                const encoded = footer.encode();
                try file.writePositionalAll(io, &encoded, size);
                return .{ .file = file, .format = .vhd, .data_offset = 0, .virtual_size = size };
            },
        }
    }

    pub fn info(self: Image, io: Io) Io.File.StatError!Info {
        const file_size = (try self.file.stat(io)).size;
        return .{ .format = self.format, .virtual_size = self.virtual_size, .file_size = file_size };
    }

    pub fn pread(self: Image, io: Io, buffer: []u8, offset: u64) Io.File.ReadPositionalError!usize {
        return self.file.readPositionalAll(io, buffer, self.data_offset + offset);
    }

    pub fn pwrite(self: Image, io: Io, buffer: []const u8, offset: u64) Io.File.WritePositionalError!void {
        try self.file.writePositionalAll(io, buffer, self.data_offset + offset);
    }

    pub fn close(self: *Image, io: Io) void {
        self.file.close(io);
        self.* = undefined;
    }
};

fn randomUuid(io: Io) [16]u8 {
    var bytes: [16]u8 = undefined;
    Io.random(io, &bytes);
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
    return bytes;
}

pub const CopyError = Io.File.ReadPositionalError || Io.File.WritePositionalError ||
    std.mem.Allocator.Error || error{UnexpectedEndOfFile};

/// Copies all `src` virtual-disk bytes into `dst` (which must already have
/// been created with at least `src`'s virtual size). Used by `zvmi convert`.
pub fn copyAll(io: Io, src: Image, dst: Image, allocator: std.mem.Allocator) CopyError!void {
    const chunk_size: usize = 4 * 1024 * 1024;
    const buf = try allocator.alloc(u8, chunk_size);
    defer allocator.free(buf);

    var offset: u64 = 0;
    while (offset < src.virtual_size) {
        const remaining = src.virtual_size - offset;
        const n: usize = @intCast(@min(remaining, chunk_size));
        const got = try src.pread(io, buf[0..n], offset);
        if (got != n) return error.UnexpectedEndOfFile;
        try dst.pwrite(io, buf[0..n], offset);
        offset += n;
    }
}

test "create raw image, then open and read back zeros" {
    const io = std.testing.io;
    const path = "test-create-raw.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    var img = try Image.create(io, path, .raw, 1024 * 1024);
    img.close(io);

    var opened = try Image.openPath(io, path);
    defer opened.close(io);
    try std.testing.expectEqual(Format.raw, opened.format);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), opened.virtual_size);

    var buf: [16]u8 = undefined;
    _ = try opened.pread(io, &buf, 0);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 16), &buf);
}

test "create fixed vhd image, then open and recover virtual size" {
    const io = std.testing.io;
    const path = "test-create-fixed.vhd";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const size: u64 = 8 * 1024 * 1024;
    var img = try Image.create(io, path, .vhd, size);
    try img.pwrite(io, "hello", 0);
    img.close(io);

    var opened = try Image.openPath(io, path);
    defer opened.close(io);
    try std.testing.expectEqual(Format.vhd, opened.format);
    try std.testing.expectEqual(size, opened.virtual_size);

    var buf: [5]u8 = undefined;
    _ = try opened.pread(io, &buf, 0);
    try std.testing.expectEqualSlices(u8, "hello", &buf);

    // The footer must not be readable/writable as guest data.
    try std.testing.expectEqual(size + vhd.footer_size, (try opened.info(io)).file_size);
}

test "convert raw to fixed vhd round-trips data" {
    const io = std.testing.io;
    const src_path = "test-convert-src.img";
    const dst_path = "test-convert-dst.vhd";
    defer Io.Dir.cwd().deleteFile(io, src_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, dst_path) catch {};

    const size: u64 = 2 * 1024 * 1024;
    var src = try Image.create(io, src_path, .raw, size);
    try src.pwrite(io, "some payload bytes", 4096);

    var dst = try Image.create(io, dst_path, .vhd, size);
    try copyAll(io, src, dst, std.testing.allocator);
    src.close(io);
    dst.close(io);

    var reopened = try Image.openPath(io, dst_path);
    defer reopened.close(io);
    var buf: [18]u8 = undefined;
    _ = try reopened.pread(io, &buf, 4096);
    try std.testing.expectEqualSlices(u8, "some payload bytes", &buf);
}
