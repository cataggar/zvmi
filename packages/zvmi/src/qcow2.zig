//! qcow2 (QEMU copy-on-write v2/v3) support for uncompressed, standalone
//! images.
//!
//! The on-disk header layout, feature bits, refcount structures, and two-level
//! L1/L2 guest-cluster mapping implemented here are transcribed from QEMU's
//! public qcow2 interoperability documentation and `block/qcow2.h`/
//! `block/qcow2.c`, the de-facto interoperability reference for this format.
//! All multi-byte fields are big-endian.
//!
//! Scope / limitations:
//!  - Backing files / differencing images are not supported for writes
//!    (`error.BackingFileNotSupported` on open, `error.SnapshotsNotSupported`
//!    on write/resize when internal snapshots are present).
//!  - Compressed clusters are not supported
//!    (`error.CompressedClusterNotSupported`).
//!  - Encryption is not supported (`error.EncryptionNotSupported`).
//!  - Extended L2 entries / external data files are not supported.
//!  - qcow2 creation always writes a version 3 header with 64 KiB clusters,
//!    an empty L1 table, and fully provisioned refcount metadata for the
//!    current virtual size.

const std = @import("std");
const Io = std.Io;

pub const file_signature: [4]u8 = .{ 'Q', 'F', 'I', 0xFB };
pub const min_cluster_bits: u32 = 9;
pub const max_cluster_bits: u32 = 21;
pub const default_cluster_bits: u32 = 16;
pub const default_refcount_order: u32 = 4;
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

const header_length_v3: u32 = 104;
const header_buffer_size: usize = 112;

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
    InvalidRefcountBlock,
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
    MissingRefcountBlock,
    ReferencedClusterHasZeroRefcount,
};

pub const CreateError = error{
    SizeNotSectorAligned,
    UnsupportedClusterSize,
    UnsupportedRefcountOrderForWrite,
    ImageTooLarge,
    MissingRefcountBlock,
} || Io.File.ReadPositionalError || Io.File.WritePositionalError || Io.File.SetLengthError;

pub const PwriteError = LookupError || error{
    ImageMarkedDirty,
    ImageMarkedCorrupt,
    SnapshotsNotSupported,
    SharedL2TableNotSupported,
    SharedClusterNotSupported,
    UnsupportedRefcountOrderForWrite,
    WritePastEndOfImage,
    MissingRefcountBlock,
    RefcountTableTooSmall,
} || Io.File.ReadPositionalError || Io.File.WritePositionalError || Io.File.SetLengthError;

pub const ResizeError = error{
    ShrinkNotSupported,
    ImageMarkedDirty,
    ImageMarkedCorrupt,
    SnapshotsNotSupported,
    UnsupportedRefcountOrderForWrite,
    MissingRefcountBlock,
    RefcountTableTooSmall,
    ImageTooLarge,
} || Io.File.ReadPositionalError || Io.File.WritePositionalError || Io.File.SetLengthError;

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
    refcount_table_capacity_blocks: u64,
    refcount_block_count: u32,
    refcount_order: u32,
    header_length: u32,
    incompatible_features: u64,
    snapshot_count: u32,
};

const ClusterMapping = struct {
    host_cluster_offset: ?u64,
    reads_as_zero: bool,
    physically_allocated: bool,
};

const Layout = struct {
    cluster_size: u64,
    l2_entries: u64,
    guest_clusters: u64,
    l1_size: u32,
    l1_clusters: u32,
    refcount_block_entries: u64,
    refcount_block_count: u32,
    refcount_table_clusters: u32,
    max_host_clusters: u64,
};

pub fn open(io: Io, file: Io.File) OpenError!Info {
    const file_size = (try file.stat(io)).size;

    var header: [header_buffer_size]u8 = undefined;
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
    const snapshot_count = std.mem.readInt(u32, header[60..64], .big);

    var incompatible_features: u64 = 0;
    var refcount_order: u32 = default_refcount_order;
    var header_length: u32 = 72;
    var compression_type: u8 = 0;

    if (version == 3) {
        if (n < 104) return error.HeaderTooShort;
        incompatible_features = std.mem.readInt(u64, header[72..80], .big);
        refcount_order = std.mem.readInt(u32, header[96..100], .big);
        header_length = std.mem.readInt(u32, header[100..104], .big);
        if (header_length < header_length_v3) return error.HeaderTooShort;
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

    const refcount_table_capacity_blocks = @as(u64, refcount_table_clusters) * cluster_size / 8;
    const refcount_block_count = try scanRefcountBlockCount(file, io, refcount_table_offset, refcount_table_clusters, cluster_size, file_size);

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
        .refcount_table_capacity_blocks = refcount_table_capacity_blocks,
        .refcount_block_count = refcount_block_count,
        .refcount_order = refcount_order,
        .header_length = header_length,
        .incompatible_features = incompatible_features,
        .snapshot_count = snapshot_count,
    };
}

/// Creates a new qcow2 image with a version 3 header, 64 KiB clusters, an
/// empty L1 table, and preallocated refcount metadata sized for `size`.
pub fn create(io: Io, file: Io.File, size: u64) CreateError!Info {
    if (size % 512 != 0) return error.SizeNotSectorAligned;
    const layout = try layoutForSize(size, default_cluster_bits, default_refcount_order);

    const refcount_table_offset = layout.cluster_size;
    const refcount_blocks_offset = refcount_table_offset + @as(u64, layout.refcount_table_clusters) * layout.cluster_size;
    const l1_table_offset = refcount_blocks_offset + @as(u64, layout.refcount_block_count) * layout.cluster_size;
    const initial_file_size = l1_table_offset + @as(u64, layout.l1_clusters) * layout.cluster_size;
    try file.setLength(io, initial_file_size);

    const info = Info{
        .virtual_size = size,
        .file_size = initial_file_size,
        .version = 3,
        .cluster_bits = default_cluster_bits,
        .cluster_size = layout.cluster_size,
        .l1_size = layout.l1_size,
        .l1_table_offset = l1_table_offset,
        .l2_entries = layout.l2_entries,
        .refcount_table_offset = refcount_table_offset,
        .refcount_table_clusters = layout.refcount_table_clusters,
        .refcount_table_capacity_blocks = @as(u64, layout.refcount_table_clusters) * layout.cluster_size / 8,
        .refcount_block_count = layout.refcount_block_count,
        .refcount_order = default_refcount_order,
        .header_length = header_length_v3,
        .incompatible_features = 0,
        .snapshot_count = 0,
    };

    try writeInitialHeader(file, io, info);

    var block_index: u32 = 0;
    while (block_index < info.refcount_block_count) : (block_index += 1) {
        const block_offset = refcount_blocks_offset + @as(u64, block_index) * info.cluster_size;
        try writeRefcountTableEntry(file, io, info.refcount_table_offset, block_index, block_offset);
    }

    const metadata_clusters = 1 + @as(u64, info.refcount_table_clusters) + @as(u64, info.refcount_block_count) + @as(u64, layout.l1_clusters);
    var cluster_index: u64 = 0;
    while (cluster_index < metadata_clusters) : (cluster_index += 1) {
        try writeRefcountByClusterIndex(file, io, info, cluster_index, 1);
    }

    return info;
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

/// Writes guest-visible bytes, allocating qcow2 L2/data clusters on demand.
/// Snapshots/shared clusters are intentionally not supported: writes fail with
/// `error.SnapshotsNotSupported`, `error.SharedL2TableNotSupported`, or
/// `error.SharedClusterNotSupported` instead of attempting copy-on-write.
pub fn pwrite(file: Io.File, io: Io, info: *Info, buffer: []const u8, offset: u64) PwriteError!void {
    try ensureWritableImage(info.*);
    const write_end = std.math.add(u64, offset, buffer.len) catch return error.WritePastEndOfImage;
    if (write_end > info.virtual_size) return error.WritePastEndOfImage;

    var dirty_marked = false;
    var ok = false;
    if (info.version >= 3) {
        try setDirtyState(file, io, info, true);
        dirty_marked = true;
    }
    defer if (dirty_marked and ok) setDirtyState(file, io, info, false) catch {};

    var off = offset;
    var remaining = buffer.len;
    var src: usize = 0;
    while (remaining > 0) {
        const guest_cluster_index = off / info.cluster_size;
        const in_cluster_offset: u32 = @intCast(off % info.cluster_size);
        const chunk: usize = @intCast(@min(@as(u64, remaining), info.cluster_size - in_cluster_offset));

        const l2_table_offset = try ensureL2TableWritable(file, io, info, guest_cluster_index);
        const l2_index = guest_cluster_index % info.l2_entries;
        const host_cluster_offset = try ensureDataClusterWritable(file, io, info, l2_table_offset, l2_index);
        try file.writePositionalAll(io, buffer[src..][0..chunk], host_cluster_offset + in_cluster_offset);

        src += chunk;
        off += chunk;
        remaining -= chunk;
    }

    ok = true;
}

/// Grows the guest-visible virtual size. If the new size requires a larger L1
/// table or more refcount metadata, qcow2 metadata is expanded in place and
/// the header is updated accordingly.
pub fn resize(file: Io.File, io: Io, info: *Info, new_size: u64) ResizeError!void {
    try ensureWritableImage(info.*);
    if (new_size < info.virtual_size) return error.ShrinkNotSupported;
    if (new_size == info.virtual_size) return;

    var dirty_marked = false;
    var ok = false;
    if (info.version >= 3) {
        try setDirtyState(file, io, info, true);
        dirty_marked = true;
    }
    defer if (dirty_marked and ok) setDirtyState(file, io, info, false) catch {};

    const layout = layoutForSize(new_size, info.cluster_bits, info.refcount_order) catch |err| switch (err) {
        error.ImageTooLarge => return error.ImageTooLarge,
        error.UnsupportedRefcountOrderForWrite => return error.UnsupportedRefcountOrderForWrite,
        error.UnsupportedClusterSize => unreachable,
    };
    try ensureRefcountCapacity(file, io, info, layout);
    try ensureL1Capacity(file, io, info, layout.l1_size, layout.l1_clusters);

    try writeHeaderU64Field(file, io, 24, new_size);
    info.virtual_size = new_size;
    ok = true;
}

pub fn check(file: Io.File, io: Io, info: Info) CheckError!void {
    if (info.incompatible_features & incompatible_dirty != 0) return error.ImageMarkedDirty;
    if (info.incompatible_features & incompatible_corrupt != 0) return error.ImageMarkedCorrupt;

    try expectClusterRefcountNonZero(file, io, info, 0);
    try setClusterRangeRefcountExpected(file, io, info, info.refcount_table_offset / info.cluster_size, info.refcount_table_clusters);
    try setClusterRangeRefcountExpected(file, io, info, info.l1_table_offset / info.cluster_size, tableClusterCount(@as(u64, info.l1_size) * 8, info.cluster_size));

    const table_entries = info.refcount_table_capacity_blocks;
    var table_index: u64 = 0;
    while (table_index < table_entries) : (table_index += 1) {
        const block_offset = try readU64(file, io, info.refcount_table_offset + table_index * 8);
        if (block_offset == 0) continue;
        try expectClusterRefcountNonZero(file, io, info, block_offset / info.cluster_size);
    }

    const guest_clusters = divCeil(info.virtual_size, info.cluster_size);
    var guest_cluster_index: u64 = 0;
    while (guest_cluster_index < guest_clusters) : (guest_cluster_index += 1) {
        const l1_index = guest_cluster_index / info.l2_entries;
        if (l1_index >= info.l1_size) return error.L1TableTooSmall;

        const l1_entry = try readU64(file, io, info.l1_table_offset + l1_index * 8);
        const l2_table_offset = l1_entry & host_offset_mask;
        if (l2_table_offset == 0) continue;
        try expectClusterRefcountNonZero(file, io, info, l2_table_offset / info.cluster_size);

        const mapping = try lookupGuestCluster(file, io, info, guest_cluster_index);
        if (mapping.host_cluster_offset) |host_cluster_offset| {
            try expectClusterRefcountNonZero(file, io, info, host_cluster_offset / info.cluster_size);
        }
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

fn layoutForSize(virtual_size: u64, cluster_bits: u32, refcount_order: u32) error{ UnsupportedClusterSize, UnsupportedRefcountOrderForWrite, ImageTooLarge }!Layout {
    if (cluster_bits < min_cluster_bits or cluster_bits > max_cluster_bits) return error.UnsupportedClusterSize;
    if (refcount_order != default_refcount_order) return error.UnsupportedRefcountOrderForWrite;

    const cluster_size = @as(u64, 1) << @intCast(cluster_bits);
    const l2_entries = cluster_size / l2_entry_size;
    const guest_clusters = divCeil(virtual_size, cluster_size);
    const l1_size_u64 = @max(@as(u64, 1), divCeil(guest_clusters, l2_entries));
    const l1_size = std.math.cast(u32, l1_size_u64) orelse return error.ImageTooLarge;
    const l1_clusters = std.math.cast(u32, divCeil(std.math.mul(u64, l1_size_u64, 8) catch return error.ImageTooLarge, cluster_size)) orelse return error.ImageTooLarge;
    const refcount_block_entries = cluster_size / 2;

    var refcount_block_count_u64: u64 = 1;
    var refcount_table_clusters_u64: u64 = 1;
    while (true) {
        const host_clusters = 1 + refcount_table_clusters_u64 + refcount_block_count_u64 + @as(u64, l1_clusters) + l1_size_u64 + guest_clusters;
        const needed_blocks = divCeil(host_clusters, refcount_block_entries);
        const needed_table_clusters = @max(@as(u64, 1), divCeil(needed_blocks * 8, cluster_size));
        if (needed_blocks == refcount_block_count_u64 and needed_table_clusters == refcount_table_clusters_u64) {
            return .{
                .cluster_size = cluster_size,
                .l2_entries = l2_entries,
                .guest_clusters = guest_clusters,
                .l1_size = l1_size,
                .l1_clusters = l1_clusters,
                .refcount_block_entries = refcount_block_entries,
                .refcount_block_count = std.math.cast(u32, refcount_block_count_u64) orelse return error.ImageTooLarge,
                .refcount_table_clusters = std.math.cast(u32, refcount_table_clusters_u64) orelse return error.ImageTooLarge,
                .max_host_clusters = host_clusters,
            };
        }
        refcount_block_count_u64 = needed_blocks;
        refcount_table_clusters_u64 = needed_table_clusters;
    }
}

fn ensureWritableImage(info: Info) error{ ImageMarkedDirty, ImageMarkedCorrupt, SnapshotsNotSupported, UnsupportedRefcountOrderForWrite }!void {
    if (info.incompatible_features & incompatible_dirty != 0) return error.ImageMarkedDirty;
    if (info.incompatible_features & incompatible_corrupt != 0) return error.ImageMarkedCorrupt;
    if (info.snapshot_count != 0) return error.SnapshotsNotSupported;
    if (info.refcount_order != default_refcount_order) return error.UnsupportedRefcountOrderForWrite;
}

fn setDirtyState(file: Io.File, io: Io, info: *Info, dirty: bool) Io.File.WritePositionalError!void {
    if (info.version < 3) return;
    if (dirty) {
        info.incompatible_features |= incompatible_dirty;
    } else {
        info.incompatible_features &= ~incompatible_dirty;
    }
    try writeHeaderU64Field(file, io, 72, info.incompatible_features);
}

fn expectClusterRefcountNonZero(file: Io.File, io: Io, info: Info, cluster_index: u64) CheckError!void {
    if (try readRefcountByClusterIndex(file, io, info, cluster_index) == 0) {
        return error.ReferencedClusterHasZeroRefcount;
    }
}

fn setClusterRangeRefcountExpected(file: Io.File, io: Io, info: Info, start_cluster_index: u64, cluster_count: u32) CheckError!void {
    var i: u32 = 0;
    while (i < cluster_count) : (i += 1) {
        try expectClusterRefcountNonZero(file, io, info, start_cluster_index + i);
    }
}

fn ensureL2TableWritable(file: Io.File, io: Io, info: *Info, guest_cluster_index: u64) PwriteError!u64 {
    const l1_index = guest_cluster_index / info.l2_entries;
    if (l1_index >= info.l1_size) return error.WritePastEndOfImage;

    const l1_entry_offset = info.l1_table_offset + l1_index * 8;
    const l1_entry = try readU64(file, io, l1_entry_offset);
    const l2_table_offset = l1_entry & host_offset_mask;
    if (l2_table_offset == 0) {
        const new_table_offset = try allocateCluster(file, io, info);
        try writeU64(file, io, l1_entry_offset, new_table_offset | copied_mask);
        return new_table_offset;
    }
    if (!isAligned(l2_table_offset, info.cluster_size) or l2_table_offset < info.cluster_size or l2_table_offset + info.cluster_size > info.file_size) {
        return error.InvalidL1Entry;
    }

    const refcount = try readRefcountAtOffset(file, io, info.*, l2_table_offset);
    if (refcount != 1) return error.SharedL2TableNotSupported;
    if ((l1_entry & copied_mask) == 0) {
        try writeU64(file, io, l1_entry_offset, l2_table_offset | copied_mask);
    }
    return l2_table_offset;
}

fn ensureDataClusterWritable(file: Io.File, io: Io, info: *Info, l2_table_offset: u64, l2_index: u64) PwriteError!u64 {
    const entry_offset = l2_table_offset + l2_index * 8;
    const l2_entry = try readU64(file, io, entry_offset);
    if (l2_entry & compressed_mask != 0) return error.CompressedClusterNotSupported;

    const host_cluster_offset = l2_entry & host_offset_mask;
    if (host_cluster_offset == 0) {
        const new_cluster_offset = try allocateCluster(file, io, info);
        try writeU64(file, io, entry_offset, new_cluster_offset | copied_mask);
        return new_cluster_offset;
    }
    if (!isAligned(host_cluster_offset, info.cluster_size) or host_cluster_offset < info.cluster_size or host_cluster_offset + info.cluster_size > info.file_size) {
        return error.InvalidL2Entry;
    }

    const refcount = try readRefcountAtOffset(file, io, info.*, host_cluster_offset);
    if (refcount != 1) return error.SharedClusterNotSupported;
    if ((l2_entry & zero_mask) != 0) {
        try zeroRange(file, io, host_cluster_offset, info.cluster_size);
    }
    if ((l2_entry & copied_mask) == 0 or (l2_entry & zero_mask) != 0) {
        try writeU64(file, io, entry_offset, host_cluster_offset | copied_mask);
    }
    return host_cluster_offset;
}

fn ensureRefcountCapacity(file: Io.File, io: Io, info: *Info, layout: Layout) ResizeError!void {
    if (layout.refcount_block_count <= info.refcount_block_count and layout.refcount_table_clusters <= info.refcount_table_clusters) return;
    try rebuildRefcountStructure(file, io, info, layout.refcount_table_clusters, layout.refcount_block_count);
}

fn rebuildRefcountStructure(file: Io.File, io: Io, info: *Info, new_table_clusters: u32, new_block_count: u32) (Io.File.ReadPositionalError || Io.File.WritePositionalError || Io.File.SetLengthError || error{MissingRefcountBlock})!void {
    const old_info = info.*;
    const old_cluster_count = divCeil(old_info.file_size, old_info.cluster_size);
    const new_table_offset = old_info.file_size;
    const new_blocks_offset = new_table_offset + @as(u64, new_table_clusters) * old_info.cluster_size;
    const new_file_size = new_blocks_offset + @as(u64, new_block_count) * old_info.cluster_size;

    try file.setLength(io, new_file_size);
    try zeroRange(file, io, new_table_offset, new_file_size - new_table_offset);

    var block_index: u32 = 0;
    while (block_index < new_block_count) : (block_index += 1) {
        const block_offset = new_blocks_offset + @as(u64, block_index) * old_info.cluster_size;
        try writeRefcountTableEntry(file, io, new_table_offset, block_index, block_offset);
    }

    var new_info = old_info;
    new_info.file_size = new_file_size;
    new_info.refcount_table_offset = new_table_offset;
    new_info.refcount_table_clusters = new_table_clusters;
    new_info.refcount_table_capacity_blocks = @as(u64, new_table_clusters) * new_info.cluster_size / 8;
    new_info.refcount_block_count = new_block_count;

    var cluster_index: u64 = 0;
    while (cluster_index < old_cluster_count) : (cluster_index += 1) {
        if (try readRefcountByClusterIndex(file, io, old_info, cluster_index) != 0) {
            try writeRefcountByClusterIndex(file, io, new_info, cluster_index, 1);
        }
    }

    try setClusterRangeRefcount(file, io, new_info, new_table_offset / new_info.cluster_size, new_table_clusters, 1);
    try setClusterRangeRefcount(file, io, new_info, new_blocks_offset / new_info.cluster_size, new_block_count, 1);
    try setClusterRangeRefcount(file, io, new_info, old_info.refcount_table_offset / old_info.cluster_size, old_info.refcount_table_clusters, 0);

    var old_block_index: u32 = 0;
    while (old_block_index < old_info.refcount_block_count) : (old_block_index += 1) {
        const old_block_offset = try readU64(file, io, old_info.refcount_table_offset + @as(u64, old_block_index) * 8);
        if (old_block_offset == 0) continue;
        try writeRefcountByClusterIndex(file, io, new_info, old_block_offset / old_info.cluster_size, 0);
    }

    try writeHeaderU64Field(file, io, 48, new_table_offset);
    try writeHeaderU32Field(file, io, 56, new_table_clusters);
    info.* = new_info;
}

fn ensureL1Capacity(file: Io.File, io: Io, info: *Info, new_l1_size: u32, new_l1_clusters: u32) ResizeError!void {
    if (new_l1_size <= info.l1_size) return;

    const old_l1_clusters = tableClusterCount(@as(u64, info.l1_size) * 8, info.cluster_size);
    if (new_l1_clusters <= old_l1_clusters) {
        const old_entries_bytes = @as(u64, info.l1_size) * 8;
        const new_entries_bytes = @as(u64, new_l1_size - info.l1_size) * 8;
        try zeroRange(file, io, info.l1_table_offset + old_entries_bytes, new_entries_bytes);
        try writeHeaderU32Field(file, io, 36, new_l1_size);
        info.l1_size = new_l1_size;
        return;
    }

    const new_l1_offset = try allocateContiguousMetadataClustersAtEnd(file, io, info, new_l1_clusters);
    try copyRange(file, io, info.l1_table_offset, new_l1_offset, @as(u64, info.l1_size) * 8);

    const old_l1_offset = info.l1_table_offset;
    try writeHeaderU32Field(file, io, 36, new_l1_size);
    try writeHeaderU64Field(file, io, 40, new_l1_offset);
    info.l1_size = new_l1_size;
    info.l1_table_offset = new_l1_offset;

    try setClusterRangeRefcount(file, io, info.*, old_l1_offset / info.cluster_size, old_l1_clusters, 0);
}

fn allocateCluster(file: Io.File, io: Io, info: *Info) PwriteError!u64 {
    var existing_clusters = divCeil(info.file_size, info.cluster_size);
    var cluster_index: u64 = 0;
    while (cluster_index < existing_clusters) : (cluster_index += 1) {
        if (try readRefcountByClusterIndex(file, io, info.*, cluster_index) == 0) {
            try writeRefcountByClusterIndex(file, io, info.*, cluster_index, 1);
            try zeroRange(file, io, cluster_index * info.cluster_size, info.cluster_size);
            return cluster_index * info.cluster_size;
        }
    }

    while (existing_clusters >= maxAddressableHostClusters(info.*)) {
        try ensureRefcountBlocksForClusterIndex(file, io, info, existing_clusters);
        existing_clusters = divCeil(info.file_size, info.cluster_size);
    }
    const cluster_offset = info.file_size;
    try file.setLength(io, info.file_size + info.cluster_size);
    info.file_size += info.cluster_size;
    try writeRefcountByClusterIndex(file, io, info.*, existing_clusters, 1);
    try zeroRange(file, io, cluster_offset, info.cluster_size);
    return cluster_offset;
}

fn allocateContiguousMetadataClustersAtEnd(file: Io.File, io: Io, info: *Info, cluster_count: u32) (Io.File.ReadPositionalError || Io.File.WritePositionalError || Io.File.SetLengthError || error{ MissingRefcountBlock, RefcountTableTooSmall })!u64 {
    if (cluster_count == 0) return info.file_size;

    while (true) {
        const start_index = divCeil(info.file_size, info.cluster_size);
        const end_index = start_index + cluster_count;
        if (end_index <= maxAddressableHostClusters(info.*)) break;
        try ensureRefcountBlocksForClusterIndex(file, io, info, end_index - 1);
        if (end_index > maxAddressableHostClusters(info.*)) return error.RefcountTableTooSmall;
    }

    const start_index = divCeil(info.file_size, info.cluster_size);
    const start_offset = info.file_size;
    const byte_len = @as(u64, cluster_count) * info.cluster_size;
    try file.setLength(io, info.file_size + byte_len);
    info.file_size += byte_len;
    try zeroRange(file, io, start_offset, byte_len);

    var i: u32 = 0;
    while (i < cluster_count) : (i += 1) {
        try writeRefcountByClusterIndex(file, io, info.*, start_index + i, 1);
    }
    return start_offset;
}

fn ensureRefcountBlocksForClusterIndex(file: Io.File, io: Io, info: *Info, cluster_index: u64) (Io.File.ReadPositionalError || Io.File.WritePositionalError || Io.File.SetLengthError || error{ MissingRefcountBlock, RefcountTableTooSmall })!void {
    const needed_blocks = divCeil(cluster_index + 1, refcountBlockEntries(info.*));
    if (needed_blocks <= info.refcount_block_count) return;

    var new_table_clusters = info.refcount_table_clusters;
    if (needed_blocks > info.refcount_table_capacity_blocks) {
        const table_bytes = std.math.mul(u64, needed_blocks, 8) catch return error.RefcountTableTooSmall;
        new_table_clusters = tableClusterCount(table_bytes, info.cluster_size);
    }

    try rebuildRefcountStructure(file, io, info, new_table_clusters, @intCast(needed_blocks));
}

fn setClusterRangeRefcount(file: Io.File, io: Io, info: Info, start_cluster_index: u64, cluster_count: u32, value: u16) (Io.File.ReadPositionalError || Io.File.WritePositionalError || error{MissingRefcountBlock})!void {
    var i: u32 = 0;
    while (i < cluster_count) : (i += 1) {
        try writeRefcountByClusterIndex(file, io, info, start_cluster_index + i, value);
    }
}

fn scanRefcountBlockCount(file: Io.File, io: Io, refcount_table_offset: u64, refcount_table_clusters: u32, cluster_size: u64, file_size: u64) (Io.File.ReadPositionalError || error{InvalidRefcountBlock})!u32 {
    const entry_count = @as(u64, refcount_table_clusters) * cluster_size / 8;
    var last_nonzero: u64 = 0;
    var saw_nonzero = false;
    var index: u64 = 0;
    while (index < entry_count) : (index += 1) {
        const entry = try readU64(file, io, refcount_table_offset + index * 8);
        if (entry != 0) {
            if (!tableFits(file_size, entry, cluster_size, cluster_size, cluster_size)) return error.InvalidRefcountBlock;
            saw_nonzero = true;
            last_nonzero = index + 1;
        }
    }
    if (!saw_nonzero) return 0;
    return std.math.cast(u32, last_nonzero) orelse std.math.maxInt(u32);
}

fn readRefcountAtOffset(file: Io.File, io: Io, info: Info, offset: u64) (Io.File.ReadPositionalError || error{MissingRefcountBlock})!u16 {
    return readRefcountByClusterIndex(file, io, info, offset / info.cluster_size);
}

fn readRefcountByClusterIndex(file: Io.File, io: Io, info: Info, cluster_index: u64) (Io.File.ReadPositionalError || error{MissingRefcountBlock})!u16 {
    const table_index = cluster_index / refcountBlockEntries(info);
    if (table_index >= info.refcount_block_count) return 0;

    const block_offset = try readU64(file, io, info.refcount_table_offset + table_index * 8);
    if (block_offset == 0) return 0;
    if (!isAligned(block_offset, info.cluster_size)) return error.MissingRefcountBlock;

    const block_index = cluster_index % refcountBlockEntries(info);
    var buf: [2]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, block_offset + block_index * 2);
    return std.mem.readInt(u16, &buf, .big);
}

fn writeRefcountByClusterIndex(file: Io.File, io: Io, info: Info, cluster_index: u64, value: u16) (Io.File.ReadPositionalError || Io.File.WritePositionalError || error{MissingRefcountBlock})!void {
    const table_index = cluster_index / refcountBlockEntries(info);
    if (table_index >= info.refcount_block_count) return error.MissingRefcountBlock;

    const block_offset = try readU64(file, io, info.refcount_table_offset + table_index * 8);
    if (block_offset == 0 or !isAligned(block_offset, info.cluster_size)) return error.MissingRefcountBlock;

    const block_index = cluster_index % refcountBlockEntries(info);
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .big);
    try file.writePositionalAll(io, &buf, block_offset + block_index * 2);
}

fn writeInitialHeader(file: Io.File, io: Io, info: Info) Io.File.WritePositionalError!void {
    var header: [header_buffer_size]u8 = [_]u8{0} ** header_buffer_size;
    header[0..4].* = file_signature;
    std.mem.writeInt(u32, header[4..8], info.version, .big);
    std.mem.writeInt(u32, header[20..24], info.cluster_bits, .big);
    std.mem.writeInt(u64, header[24..32], info.virtual_size, .big);
    std.mem.writeInt(u32, header[36..40], info.l1_size, .big);
    std.mem.writeInt(u64, header[40..48], info.l1_table_offset, .big);
    std.mem.writeInt(u64, header[48..56], info.refcount_table_offset, .big);
    std.mem.writeInt(u32, header[56..60], info.refcount_table_clusters, .big);
    std.mem.writeInt(u64, header[72..80], info.incompatible_features, .big);
    std.mem.writeInt(u32, header[96..100], info.refcount_order, .big);
    std.mem.writeInt(u32, header[100..104], info.header_length, .big);
    try file.writePositionalAll(io, &header, 0);
}

fn writeHeaderU32Field(file: Io.File, io: Io, offset: u64, value: u32) Io.File.WritePositionalError!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try file.writePositionalAll(io, &buf, offset);
}

fn writeHeaderU64Field(file: Io.File, io: Io, offset: u64, value: u64) Io.File.WritePositionalError!void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .big);
    try file.writePositionalAll(io, &buf, offset);
}

fn writeRefcountTableEntry(file: Io.File, io: Io, refcount_table_offset: u64, index: u32, block_offset: u64) Io.File.WritePositionalError!void {
    try writeU64(file, io, refcount_table_offset + @as(u64, index) * 8, block_offset);
}

fn copyRange(file: Io.File, io: Io, src_offset: u64, dst_offset: u64, byte_length: u64) (Io.File.ReadPositionalError || Io.File.WritePositionalError)!void {
    var buf: [4096]u8 = undefined;
    var copied: u64 = 0;
    while (copied < byte_length) {
        const n: usize = @intCast(@min(byte_length - copied, buf.len));
        _ = try file.readPositionalAll(io, buf[0..n], src_offset + copied);
        try file.writePositionalAll(io, buf[0..n], dst_offset + copied);
        copied += n;
    }
}

fn zeroRange(file: Io.File, io: Io, offset: u64, byte_length: u64) Io.File.WritePositionalError!void {
    const zeroes: [4096]u8 = [_]u8{0} ** 4096;
    var written: u64 = 0;
    while (written < byte_length) {
        const n: usize = @intCast(@min(byte_length - written, zeroes.len));
        try file.writePositionalAll(io, zeroes[0..n], offset + written);
        written += n;
    }
}

fn tableClusterCount(byte_length: u64, cluster_size: u64) u32 {
    return @intCast(@max(@as(u64, 1), divCeil(byte_length, cluster_size)));
}

fn maxAddressableHostClusters(info: Info) u64 {
    return @as(u64, info.refcount_block_count) * refcountBlockEntries(info);
}

fn refcountBlockEntries(info: Info) u64 {
    return info.cluster_size / 2;
}

fn tableFits(file_size: u64, offset: u64, byte_length: u64, alignment: u64, minimum_offset: u64) bool {
    if (!isAligned(offset, alignment) or offset < minimum_offset) return false;
    const end = std.math.add(u64, offset, byte_length) catch return false;
    return end <= file_size;
}

fn writeU64(file: Io.File, io: Io, offset: u64, value: u64) Io.File.WritePositionalError!void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .big);
    try file.writePositionalAll(io, &buf, offset);
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

test "check detects referenced clusters with zero refcounts" {
    const io = std.testing.io;
    const path = "test-qcow2-bad-refcount.qcow2";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const fixture = try writeTestFixture(io, path, .{});

    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const info = try open(io, file);
    try writeRefcountByClusterIndex(file, io, info, fixture.data0_offset / fixture.cluster_size, 0);
    try std.testing.expectError(error.ReferencedClusterHasZeroRefcount, check(file, io, info));
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

test "pwrite zero-fills allocated zero clusters before partial writes" {
    const io = std.testing.io;
    const path = "test-qcow2-zero-cluster-write.qcow2";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);

    var info = try create(io, file, 2 * (1 << default_cluster_bits));
    try pwrite(file, io, &info, "seed", 0);

    const l1_entry = try readU64(file, io, info.l1_table_offset);
    const l2_offset = l1_entry & host_offset_mask;
    const data_entry_offset = l2_offset;
    const data_offset = (try readU64(file, io, data_entry_offset)) & host_offset_mask;

    const stale = [_]u8{0x7B} ** 64;
    try file.writePositionalAll(io, &stale, data_offset);
    try writeU64(file, io, data_entry_offset, data_offset | copied_mask | zero_mask);

    var zeros_before: [64]u8 = undefined;
    _ = try pread(file, io, info, &zeros_before, 0);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 64), &zeros_before);

    try pwrite(file, io, &info, "hi", 32);

    var buf: [64]u8 = undefined;
    _ = try pread(file, io, info, &buf, 0);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), buf[0..32]);
    try std.testing.expectEqualSlices(u8, "hi", buf[32..34]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 30), buf[34..64]);
}

test "resize clears newly exposed in-place L1 entries" {
    const io = std.testing.io;
    const path = "test-qcow2-l1-slack.qcow2";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);

    var info = try create(io, file, 256 * 1024 * 1024);
    try writeU64(file, io, info.l1_table_offset + 8, info.refcount_table_offset | copied_mask);

    try resize(file, io, &info, 1024 * 1024 * 1024);

    var buf: [64]u8 = undefined;
    _ = try pread(file, io, info, &buf, 512 * 1024 * 1024);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 64), &buf);
}

test "create, write, resize, and validate refcounts" {
    const io = std.testing.io;
    const path = "test-qcow2-write.qcow2";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const initial_size: u64 = 256 * 1024 * 1024;
    const grown_size: u64 = 1024 * 1024 * 1024;
    const cross_boundary_offset: u64 = 512 * 1024 * 1024 - 96;
    const sparse_offset: u64 = 3 * 65536 + 37;
    const distant_offset: u64 = 768 * 1024 * 1024 + 123;
    const payload0 = "qcow2-direct-0";
    const payload1 = "qcow2-direct-1";
    const payload2 = [_]u8{0x5A} ** 256;

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);

    var info = try create(io, file, initial_size);
    try pwrite(file, io, &info, payload0, sparse_offset);
    try resize(file, io, &info, grown_size);
    try pwrite(file, io, &info, payload1, distant_offset);
    try pwrite(file, io, &info, &payload2, cross_boundary_offset);

    const reopened = try open(io, file);
    try std.testing.expectEqual(grown_size, reopened.virtual_size);

    var buf0: [payload0.len]u8 = undefined;
    _ = try pread(file, io, reopened, &buf0, sparse_offset);
    try std.testing.expectEqualSlices(u8, payload0, &buf0);

    var buf1: [payload1.len]u8 = undefined;
    _ = try pread(file, io, reopened, &buf1, distant_offset);
    try std.testing.expectEqualSlices(u8, payload1, &buf1);

    var buf2: [payload2.len]u8 = undefined;
    _ = try pread(file, io, reopened, &buf2, cross_boundary_offset);
    try std.testing.expectEqualSlices(u8, &payload2, &buf2);

    try verifyAllocatedClustersMatchRefcounts(file, io, reopened);
}

test "resize grows refcount metadata past a full legacy coverage boundary" {
    const io = std.testing.io;
    const path = "test-qcow2-refcount-grow.qcow2";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);

    try writeFullCoverage4kFixture(file, io);

    var info = try open(io, file);
    const old_virtual_size = info.virtual_size;
    try resize(file, io, &info, old_virtual_size + info.cluster_size);
    try std.testing.expect(info.refcount_block_count > 1);
    try std.testing.expectEqual(@as(u16, 0), try readRefcountByClusterIndex(file, io, info, 1));
    try std.testing.expectEqual(@as(u16, 0), try readRefcountByClusterIndex(file, io, info, 2));

    try pwrite(file, io, &info, "grow", old_virtual_size);
    var buf: [4]u8 = undefined;
    _ = try pread(file, io, info, &buf, old_virtual_size);
    try std.testing.expectEqualSlices(u8, "grow", &buf);
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

    var header: [header_buffer_size]u8 = [_]u8{0} ** header_buffer_size;
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
    std.mem.writeInt(u32, header[100..104], header_length_v3, .big);
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

fn writeFullCoverage4kFixture(file: Io.File, io: Io) !void {
    const cluster_bits: u32 = 12;
    const cluster_size: u64 = 1 << cluster_bits;
    const l2_entries: u64 = cluster_size / 8;
    const guest_clusters: u64 = 2040;
    const l1_size: u32 = 4;
    const refcount_table_offset: u64 = 1 * cluster_size;
    const refcount_block_offset: u64 = 2 * cluster_size;
    const l1_table_offset: u64 = 3 * cluster_size;
    const l2_tables_offset: u64 = 4 * cluster_size;
    const data_offset_base: u64 = 8 * cluster_size;
    const total_clusters: u64 = 2048;
    const total_file_size: u64 = total_clusters * cluster_size;
    const virtual_size: u64 = guest_clusters * cluster_size;

    try file.setLength(io, total_file_size);

    var header: [header_buffer_size]u8 = [_]u8{0} ** header_buffer_size;
    header[0..4].* = file_signature;
    std.mem.writeInt(u32, header[4..8], 3, .big);
    std.mem.writeInt(u32, header[20..24], cluster_bits, .big);
    std.mem.writeInt(u64, header[24..32], virtual_size, .big);
    std.mem.writeInt(u32, header[36..40], l1_size, .big);
    std.mem.writeInt(u64, header[40..48], l1_table_offset, .big);
    std.mem.writeInt(u64, header[48..56], refcount_table_offset, .big);
    std.mem.writeInt(u32, header[56..60], 1, .big);
    std.mem.writeInt(u32, header[96..100], 4, .big);
    std.mem.writeInt(u32, header[100..104], header_length_v3, .big);
    try file.writePositionalAll(io, &header, 0);

    var refcount_table: [4096]u8 = [_]u8{0} ** 4096;
    std.mem.writeInt(u64, refcount_table[0..8], refcount_block_offset, .big);
    try file.writePositionalAll(io, &refcount_table, refcount_table_offset);

    var refcount_block: [4096]u8 = [_]u8{0} ** 4096;
    var cluster_index: usize = 0;
    while (cluster_index < total_clusters) : (cluster_index += 1) {
        std.mem.writeInt(u16, refcount_block[cluster_index * 2 ..][0..2], 1, .big);
    }
    try file.writePositionalAll(io, &refcount_block, refcount_block_offset);

    var l1_table: [4096]u8 = [_]u8{0} ** 4096;
    var l1_index: u32 = 0;
    while (l1_index < l1_size) : (l1_index += 1) {
        std.mem.writeInt(u64, l1_table[l1_index * 8 ..][0..8], l2_tables_offset + @as(u64, l1_index) * cluster_size | copied_mask, .big);
    }
    try file.writePositionalAll(io, &l1_table, l1_table_offset);

    var guest_cluster_index: u64 = 0;
    while (guest_cluster_index < guest_clusters) : (guest_cluster_index += 1) {
        const table_index = guest_cluster_index / l2_entries;
        const entry_index = guest_cluster_index % l2_entries;
        const l2_offset = l2_tables_offset + table_index * cluster_size;
        const data_offset = data_offset_base + guest_cluster_index * cluster_size;
        var entry_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &entry_buf, data_offset | copied_mask, .big);
        try file.writePositionalAll(io, &entry_buf, l2_offset + entry_index * 8);
    }
}

fn verifyAllocatedClustersMatchRefcounts(file: Io.File, io: Io, info: Info) !void {
    var expected = std.array_list.Managed(u64).init(std.testing.allocator);
    defer expected.deinit();
    var actual = std.array_list.Managed(u64).init(std.testing.allocator);
    defer actual.deinit();

    try expected.append(0);
    var i: u32 = 0;
    while (i < info.refcount_table_clusters) : (i += 1) {
        try expected.append(1 + i);
    }

    var block_index: u32 = 0;
    while (block_index < info.refcount_block_count) : (block_index += 1) {
        const block_offset = try readU64(file, io, info.refcount_table_offset + @as(u64, block_index) * 8);
        try expected.append(block_offset / info.cluster_size);
    }

    const l1_clusters = tableClusterCount(@as(u64, info.l1_size) * 8, info.cluster_size);
    var l1_cluster: u32 = 0;
    while (l1_cluster < l1_clusters) : (l1_cluster += 1) {
        try expected.append(info.l1_table_offset / info.cluster_size + l1_cluster);
    }

    var l1_index: u64 = 0;
    while (l1_index < info.l1_size) : (l1_index += 1) {
        const l1_entry = try readU64(file, io, info.l1_table_offset + l1_index * 8);
        const l2_offset = l1_entry & host_offset_mask;
        if (l2_offset == 0) continue;
        try expected.append(l2_offset / info.cluster_size);

        var l2_index: u64 = 0;
        while (l2_index < info.l2_entries) : (l2_index += 1) {
            const l2_entry = try readU64(file, io, l2_offset + l2_index * 8);
            const data_offset = l2_entry & host_offset_mask;
            if (data_offset == 0) continue;
            try expected.append(data_offset / info.cluster_size);
        }
    }

    const cluster_count = divCeil(info.file_size, info.cluster_size);
    var cluster_index: u64 = 0;
    while (cluster_index < cluster_count) : (cluster_index += 1) {
        if (try readRefcountByClusterIndex(file, io, info, cluster_index) != 0) {
            try actual.append(cluster_index);
        }
    }

    std.mem.sort(u64, expected.items, {}, std.sort.asc(u64));
    std.mem.sort(u64, actual.items, {}, std.sort.asc(u64));

    var deduped_expected = std.array_list.Managed(u64).init(std.testing.allocator);
    defer deduped_expected.deinit();
    var last: ?u64 = null;
    for (expected.items) |value| {
        if (last != null and last.? == value) continue;
        try deduped_expected.append(value);
        last = value;
    }

    try std.testing.expectEqualSlices(u64, deduped_expected.items, actual.items);
}
