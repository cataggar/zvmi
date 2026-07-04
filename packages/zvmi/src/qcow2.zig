//! qcow2 (QEMU copy-on-write v2/v3) **read-only** support.
//!
//! The on-disk header layout, feature bits, and two-level L1/L2 guest-cluster
//! mapping implemented here are transcribed from QEMU's public qcow2
//! interoperability documentation and `block/qcow2.h`/`block/qcow2.c`, the
//! de-facto interoperability reference for this format. All multi-byte fields
//! are big-endian.
//!
//! Scope / limitations (read-only only):
//!  - Backing files / differencing images are not supported
//!    (`error.BackingFileNotSupported`).
//!  - Compressed clusters are not supported
//!    (`error.CompressedClusterNotSupported`).
//!  - Encryption is not supported (`error.EncryptionNotSupported`).
//!  - Extended L2 entries / external data files are not supported.
//!  - Internal snapshots are ignored; reads always expose only the currently
//!    active L1 table from the qcow2 header.
//!  - Writing/creating/resizing qcow2 is not implemented.

const std = @import("std");
const Io = std.Io;

pub const file_signature: [4]u8 = .{ 'Q', 'F', 'I', 0xFB };
pub const min_cluster_bits: u32 = 9;
pub const max_cluster_bits: u32 = 21;
pub const l2_entry_size: u64 = 8;
pub const copied_mask: u64 = 1 << 63;
pub const compressed_mask: u64 = 1 << 62;
pub const zero_mask: u64 = 1 << 0;
pub const host_offset_mask: u64 = 0x00FF_FFFF_FFFF_FE00;

pub const incompatible_dirty: u64 = 1 << 0;
pub const incompatible_corrupt: u64 = 1 << 1;
pub const incompatible_data_file: u64 = 1 << 2;
pub const incompatible_compression: u64 = 1 << 3;
pub const incompatible_extl2: u64 = 1 << 4;
pub const incompatible_known_mask: u64 = incompatible_dirty |
    incompatible_corrupt |
    incompatible_data_file |
    incompatible_compression |
    incompatible_extl2;

pub const OpenError = error{
    BadFileSignature,
    UnsupportedVersion,
    UnsupportedClusterSize,
    HeaderTooShort,
    HeaderExceedsClusterSize,
    HeaderPastEndOfFile,
    BackingFileNotSupported,
    EncryptionNotSupported,
    UnsupportedIncompatibleFeature,
    ExternalDataFileNotSupported,
    UnsupportedCompressionType,
    ExtendedL2NotSupported,
    InvalidRefcountOrder,
    MissingRefcountTable,
    MisalignedRefcountTable,
    MisalignedL1Table,
    RefcountTablePastEndOfFile,
    L1TablePastEndOfFile,
    L1TableTooSmall,
} || Io.File.ReadPositionalError || Io.File.StatError;

pub const LookupError = error{
    L1TableTooSmall,
    InvalidL1Entry,
    InvalidL2Entry,
    CompressedClusterNotSupported,
} || Io.File.ReadPositionalError;

pub const PreadError = LookupError;

pub const CheckError = LookupError || error{
    ImageMarkedDirty,
    ImageMarkedCorrupt,
};

pub const Extent = struct {
    offset: u64,
    length: u64,
    allocated: bool,
};

pub const MapError = LookupError || std.mem.Allocator.Error;

pub const Info = struct {
    virtual_size: u64,
    file_size: u64,
    version: u32,
    cluster_bits: u32,
    cluster_size: u64,
    l1_size: u32,
    l1_table_offset: u64,
    l2_entries: u64,
    refcount_table_offset: u64,
    refcount_table_clusters: u32,
    refcount_order: u32,
    header_length: u32,
    incompatible_features: u64,
};

const ClusterMapping = struct {
    host_cluster_offset: ?u64,
    reads_as_zero: bool,
    physically_allocated: bool,
};

pub fn open(io: Io, file: Io.File) OpenError!Info {
    const file_size = (try file.stat(io)).size;

    var header: [112]u8 = undefined;
    const n = try file.readPositionalAll(io, &header, 0);
    if (n < 72) return error.HeaderTooShort;
    if (!std.mem.eql(u8, header[0..4], &file_signature)) return error.BadFileSignature;

    const version = std.mem.readInt(u32, header[4..8], .big);
    if (version < 2 or version > 3) return error.UnsupportedVersion;

    const backing_file_offset = std.mem.readInt(u64, header[8..16], .big);
    const backing_file_size = std.mem.readInt(u32, header[16..20], .big);
    const cluster_bits = std.mem.readInt(u32, header[20..24], .big);
    if (cluster_bits < min_cluster_bits or cluster_bits > max_cluster_bits) {
        return error.UnsupportedClusterSize;
    }
    const cluster_size = @as(u64, 1) << @intCast(cluster_bits);

    const virtual_size = std.mem.readInt(u64, header[24..32], .big);
    const crypt_method = std.mem.readInt(u32, header[32..36], .big);
    const l1_size = std.mem.readInt(u32, header[36..40], .big);
    const l1_table_offset = std.mem.readInt(u64, header[40..48], .big);
    const refcount_table_offset = std.mem.readInt(u64, header[48..56], .big);
    const refcount_table_clusters = std.mem.readInt(u32, header[56..60], .big);

    var incompatible_features: u64 = 0;
    var refcount_order: u32 = 4;
    var header_length: u32 = 72;
    var compression_type: u8 = 0;

    if (version == 3) {
        if (n < 104) return error.HeaderTooShort;
        incompatible_features = std.mem.readInt(u64, header[72..80], .big);
        refcount_order = std.mem.readInt(u32, header[96..100], .big);
        header_length = std.mem.readInt(u32, header[100..104], .big);
        if (header_length < 104) return error.HeaderTooShort;
        if (header_length > 104) {
            if (n < 105) return error.HeaderTooShort;
            compression_type = header[104];
        }
    }

    if (header_length > cluster_size) return error.HeaderExceedsClusterSize;
    if (file_size < header_length) return error.HeaderPastEndOfFile;

    if (backing_file_offset != 0 or backing_file_size != 0) return error.BackingFileNotSupported;
    if (crypt_method != 0) return error.EncryptionNotSupported;

    if (incompatible_features & ~incompatible_known_mask != 0) {
        return error.UnsupportedIncompatibleFeature;
    }
    if (incompatible_features & incompatible_data_file != 0) return error.ExternalDataFileNotSupported;
    if (incompatible_features & incompatible_compression != 0 or compression_type != 0) {
        return error.UnsupportedCompressionType;
    }
    if (incompatible_features & incompatible_extl2 != 0) return error.ExtendedL2NotSupported;

    if (refcount_order > 6) return error.InvalidRefcountOrder;
    if (refcount_table_clusters == 0) return error.MissingRefcountTable;

    const refcount_table_bytes = std.math.mul(u64, @as(u64, refcount_table_clusters), cluster_size) catch return error.RefcountTablePastEndOfFile;
    if (!tableFits(file_size, refcount_table_offset, refcount_table_bytes, cluster_size, cluster_size)) {
        if (!isAligned(refcount_table_offset, cluster_size) or refcount_table_offset < cluster_size) {
            return error.MisalignedRefcountTable;
        }
        return error.RefcountTablePastEndOfFile;
    }

    const l1_table_bytes = std.math.mul(u64, @as(u64, l1_size), l2_entry_size) catch return error.L1TablePastEndOfFile;
    if (!tableFits(file_size, l1_table_offset, l1_table_bytes, cluster_size, cluster_size)) {
        if (!isAligned(l1_table_offset, cluster_size) or l1_table_offset < cluster_size) {
            return error.MisalignedL1Table;
        }
        return error.L1TablePastEndOfFile;
    }

    const l2_entries = cluster_size / l2_entry_size;
    const guest_clusters = divCeil(virtual_size, cluster_size);
    const required_l1_entries = divCeil(guest_clusters, l2_entries);
    if (l1_size < required_l1_entries) return error.L1TableTooSmall;

    return .{
        .virtual_size = virtual_size,
        .file_size = file_size,
        .version = version,
        .cluster_bits = cluster_bits,
        .cluster_size = cluster_size,
        .l1_size = l1_size,
        .l1_table_offset = l1_table_offset,
        .l2_entries = l2_entries,
        .refcount_table_offset = refcount_table_offset,
        .refcount_table_clusters = refcount_table_clusters,
        .refcount_order = refcount_order,
        .header_length = header_length,
        .incompatible_features = incompatible_features,
    };
}

pub fn pread(file: Io.File, io: Io, info: Info, buffer: []u8, offset: u64) PreadError!usize {
    if (offset >= info.virtual_size) return 0;

    var total: usize = 0;
    var off = offset;
    var remaining = @min(buffer.len, info.virtual_size - offset);
    while (remaining > 0) {
        const guest_cluster_index = off / info.cluster_size;
        const in_cluster_offset: u32 = @intCast(off % info.cluster_size);
        const chunk: usize = @intCast(@min(@as(u64, remaining), info.cluster_size - in_cluster_offset));
        const mapping = try lookupGuestCluster(file, io, info, guest_cluster_index);

        if (mapping.reads_as_zero) {
            @memset(buffer[total..][0..chunk], 0);
        } else {
            const host_cluster_offset = mapping.host_cluster_offset.?;
            const got = try file.readPositionalAll(io, buffer[total..][0..chunk], host_cluster_offset + in_cluster_offset);
            if (got < chunk) @memset(buffer[total + got ..][0 .. chunk - got], 0);
        }

        total += chunk;
        off += chunk;
        remaining -= chunk;
    }
    return total;
}

pub fn check(file: Io.File, io: Io, info: Info) CheckError!void {
    if (info.incompatible_features & incompatible_dirty != 0) return error.ImageMarkedDirty;
    if (info.incompatible_features & incompatible_corrupt != 0) return error.ImageMarkedCorrupt;

    const guest_clusters = divCeil(info.virtual_size, info.cluster_size);
    var guest_cluster_index: u64 = 0;
    while (guest_cluster_index < guest_clusters) : (guest_cluster_index += 1) {
        _ = try lookupGuestCluster(file, io, info, guest_cluster_index);
    }
}

pub fn mapExtents(file: Io.File, io: Io, info: Info, allocator: std.mem.Allocator) MapError![]Extent {
    var extents = std.array_list.Managed(Extent).init(allocator);
    errdefer extents.deinit();

    const guest_clusters = divCeil(info.virtual_size, info.cluster_size);
    var index: u64 = 0;
    while (index < guest_clusters) {
        const allocated = (try lookupGuestCluster(file, io, info, index)).physically_allocated;
        const start = index * info.cluster_size;

        var run_end = index + 1;
        while (run_end < guest_clusters) : (run_end += 1) {
            const next_allocated = (try lookupGuestCluster(file, io, info, run_end)).physically_allocated;
            if (next_allocated != allocated) break;
        }

        const end = @min(run_end * info.cluster_size, info.virtual_size);
        try extents.append(.{ .offset = start, .length = end - start, .allocated = allocated });
        index = run_end;
    }

    return extents.toOwnedSlice();
}

fn lookupGuestCluster(file: Io.File, io: Io, info: Info, guest_cluster_index: u64) LookupError!ClusterMapping {
    const l1_index = guest_cluster_index / info.l2_entries;
    if (l1_index >= info.l1_size) return error.L1TableTooSmall;

    const l1_entry = try readU64(file, io, info.l1_table_offset + l1_index * 8);
    const l2_table_offset = l1_entry & host_offset_mask;
    if (l2_table_offset == 0) {
        return .{ .host_cluster_offset = null, .reads_as_zero = true, .physically_allocated = false };
    }
    if (!isAligned(l2_table_offset, info.cluster_size) or l2_table_offset < info.cluster_size or l2_table_offset + info.cluster_size > info.file_size) {
        return error.InvalidL1Entry;
    }

    const l2_index = guest_cluster_index % info.l2_entries;
    const l2_entry = try readU64(file, io, l2_table_offset + l2_index * 8);
    if (l2_entry & compressed_mask != 0) return error.CompressedClusterNotSupported;

    const host_cluster_offset = l2_entry & host_offset_mask;
    const reads_as_zero = (l2_entry & zero_mask) != 0;
    if (host_cluster_offset == 0) {
        return .{ .host_cluster_offset = null, .reads_as_zero = true, .physically_allocated = false };
    }
    if (!isAligned(host_cluster_offset, info.cluster_size) or host_cluster_offset < info.cluster_size or host_cluster_offset + info.cluster_size > info.file_size) {
        return error.InvalidL2Entry;
    }

    return .{
        .host_cluster_offset = host_cluster_offset,
        .reads_as_zero = reads_as_zero,
        .physically_allocated = true,
    };
}

fn tableFits(file_size: u64, offset: u64, byte_length: u64, alignment: u64, minimum_offset: u64) bool {
    if (!isAligned(offset, alignment) or offset < minimum_offset) return false;
    const end = std.math.add(u64, offset, byte_length) catch return false;
    return end <= file_size;
}

fn readU64(file: Io.File, io: Io, offset: u64) Io.File.ReadPositionalError!u64 {
    var buf: [8]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, offset);
    return std.mem.readInt(u64, &buf, .big);
}

fn isAligned(value: u64, alignment: u64) bool {
    return alignment != 0 and value % alignment == 0;
}

fn divCeil(numerator: u64, denominator: u64) u64 {
    if (numerator == 0) return 0;
    return std.math.divCeil(u64, numerator, denominator) catch unreachable;
}

test "open parses a minimal qcow2 header" {
    const io = std.testing.io;
    const path = "test-qcow2-open.qcow2";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    _ = try writeTestFixture(io, path, .{});

    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const info = try open(io, file);
    try std.testing.expectEqual(@as(u32, 3), info.version);
    try std.testing.expectEqual(@as(u32, 12), info.cluster_bits);
    try std.testing.expectEqual(@as(u64, 4096), info.cluster_size);
    try std.testing.expectEqual(@as(u64, 3 * 4096), info.virtual_size);
    try std.testing.expectEqual(@as(u32, 1), info.l1_size);
    try std.testing.expectEqual(@as(u64, 3 * 4096), info.l1_table_offset);
    try std.testing.expectEqual(@as(u64, 4096 / 8), info.l2_entries);
    try std.testing.expectEqual(@as(u64, 4096), info.refcount_table_offset);
    try std.testing.expectEqual(@as(u32, 1), info.refcount_table_clusters);
}

test "lookupGuestCluster maps allocated and sparse clusters" {
    const io = std.testing.io;
    const path = "test-qcow2-lookup.qcow2";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const fixture = try writeTestFixture(io, path, .{});

    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const info = try open(io, file);

    const cluster0 = try lookupGuestCluster(file, io, info, 0);
    try std.testing.expectEqual(@as(?u64, fixture.data0_offset), cluster0.host_cluster_offset);
    try std.testing.expect(!cluster0.reads_as_zero);
    try std.testing.expect(cluster0.physically_allocated);

    const cluster1 = try lookupGuestCluster(file, io, info, 1);
    try std.testing.expectEqual(@as(?u64, null), cluster1.host_cluster_offset);
    try std.testing.expect(cluster1.reads_as_zero);
    try std.testing.expect(!cluster1.physically_allocated);

    const cluster2 = try lookupGuestCluster(file, io, info, 2);
    try std.testing.expectEqual(@as(?u64, fixture.data2_offset), cluster2.host_cluster_offset);
    try std.testing.expect(cluster2.physically_allocated);
}

test "pread zero-fills sparse clusters" {
    const io = std.testing.io;
    const path = "test-qcow2-pread.qcow2";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    _ = try writeTestFixture(io, path, .{});

    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const info = try open(io, file);

    var payload: [13]u8 = undefined;
    const got = try pread(file, io, info, &payload, 0);
    try std.testing.expectEqual(payload.len, got);
    try std.testing.expectEqualSlices(u8, "QCOW2BLOCK000", &payload);

    var zeroes: [64]u8 = undefined;
    _ = try pread(file, io, info, &zeroes, info.cluster_size);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 64), &zeroes);
}

test "check reports dirty images" {
    const io = std.testing.io;
    const path = "test-qcow2-dirty.qcow2";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    _ = try writeTestFixture(io, path, .{ .dirty = true });

    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const info = try open(io, file);
    try std.testing.expectError(error.ImageMarkedDirty, check(file, io, info));
}

const TestFixture = struct {
    cluster_size: u64,
    l1_table_offset: u64,
    l2_table_offset: u64,
    data0_offset: u64,
    data2_offset: u64,
};

const TestFixtureOptions = struct {
    dirty: bool = false,
    corrupt: bool = false,
};

fn writeTestFixture(io: Io, path: []const u8, options: TestFixtureOptions) !TestFixture {
    const cluster_bits: u32 = 12;
    const cluster_size: u64 = 1 << cluster_bits;
    const refcount_table_offset: u64 = 1 * cluster_size;
    const refcount_block_offset: u64 = 2 * cluster_size;
    const l1_table_offset: u64 = 3 * cluster_size;
    const l2_table_offset: u64 = 4 * cluster_size;
    const data0_offset: u64 = 5 * cluster_size;
    const data2_offset: u64 = 6 * cluster_size;
    const total_file_size: u64 = 7 * cluster_size;
    const virtual_size: u64 = 3 * cluster_size;

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);
    try file.setLength(io, total_file_size);

    var header: [112]u8 = [_]u8{0} ** 112;
    header[0..4].* = file_signature;
    std.mem.writeInt(u32, header[4..8], 3, .big);
    std.mem.writeInt(u32, header[20..24], cluster_bits, .big);
    std.mem.writeInt(u64, header[24..32], virtual_size, .big);
    std.mem.writeInt(u32, header[36..40], 1, .big);
    std.mem.writeInt(u64, header[40..48], l1_table_offset, .big);
    std.mem.writeInt(u64, header[48..56], refcount_table_offset, .big);
    std.mem.writeInt(u32, header[56..60], 1, .big);
    var incompatible_features: u64 = 0;
    if (options.dirty) incompatible_features |= incompatible_dirty;
    if (options.corrupt) incompatible_features |= incompatible_corrupt;
    std.mem.writeInt(u64, header[72..80], incompatible_features, .big);
    std.mem.writeInt(u32, header[96..100], 4, .big);
    std.mem.writeInt(u32, header[100..104], 104, .big);
    try file.writePositionalAll(io, &header, 0);

    var refcount_table: [4096]u8 = [_]u8{0} ** 4096;
    std.mem.writeInt(u64, refcount_table[0..8], refcount_block_offset, .big);
    try file.writePositionalAll(io, &refcount_table, refcount_table_offset);

    var refcount_block: [4096]u8 = [_]u8{0} ** 4096;
    var cluster_index: usize = 0;
    while (cluster_index < 7) : (cluster_index += 1) {
        std.mem.writeInt(u16, refcount_block[cluster_index * 2 ..][0..2], 1, .big);
    }
    try file.writePositionalAll(io, &refcount_block, refcount_block_offset);

    var l1_table: [4096]u8 = [_]u8{0} ** 4096;
    std.mem.writeInt(u64, l1_table[0..8], l2_table_offset | copied_mask, .big);
    try file.writePositionalAll(io, &l1_table, l1_table_offset);

    var l2_table: [4096]u8 = [_]u8{0} ** 4096;
    std.mem.writeInt(u64, l2_table[0..8], data0_offset | copied_mask, .big);
    std.mem.writeInt(u64, l2_table[16..24], data2_offset | copied_mask, .big);
    try file.writePositionalAll(io, &l2_table, l2_table_offset);

    try file.writePositionalAll(io, "QCOW2BLOCK000", data0_offset);
    try file.writePositionalAll(io, "QCOW2BLOCK222", data2_offset + 32);

    return .{
        .cluster_size = cluster_size,
        .l1_table_offset = l1_table_offset,
        .l2_table_offset = l2_table_offset,
        .data0_offset = data0_offset,
        .data2_offset = data2_offset,
    };
}
