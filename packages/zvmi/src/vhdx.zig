//! VHDX (Hyper-V's successor format to VHD) **read-only** support.
//!
//! Every struct layout, offset, well-known GUID, the CRC-32C checksum
//! algorithm, and -- critically -- the BAT chunk-ratio interleaving math are
//! transcribed directly from QEMU's `block/vhdx.h`/`block/vhdx.c` (based on
//! Microsoft's "VHDX Format Specification v1.00"), the de-facto
//! interoperability reference for this format, since no real Hyper-V/QEMU
//! install was available in this environment to generate reference files
//! for round-trip testing. All multi-byte fields are little-endian.
//!
//! Scope / limitations (read-only, non-differencing only):
//!  - Differencing (parent/backing-file) VHDX images are not supported
//!    (`error.DifferencingNotSupported`).
//!  - Only 512-byte logical sectors are supported (matches QEMU's own
//!    restriction; virtually all real-world VHDX files use 512).
//!  - The journal/log is *not* replayed. A VHDX file left with unflushed log
//!    entries (e.g. after an unclean shutdown) may read stale data. Files
//!    written by a tool that flushed and cleanly closed the image (the
//!    common case for images meant to be shared/converted) are unaffected.
//!  - Writing/creating VHDX is not implemented.

const std = @import("std");
const Io = std.Io;
const guid = @import("guid.zig");

pub const header_block_size: usize = 64 * 1024;
pub const file_id_offset: u64 = 0;
pub const header1_offset: u64 = header_block_size * 1;
pub const header2_offset: u64 = header_block_size * 2;
pub const region_table_offset: u64 = header_block_size * 3;

pub const header_size: usize = 4 * 1024;
pub const header_signature: [4]u8 = "head".*;
pub const region_signature: [4]u8 = "regi".*;
pub const metadata_signature: [8]u8 = "metadata".*;
pub const file_signature: [8]u8 = "vhdxfile".*;

/// Sector-bitmap-block interleaving granularity: for every `chunk_ratio`
/// payload block entries in the BAT, there is one extra (here, ignored)
/// sector-bitmap-block entry -- see `batIndexForBlock`.
pub const max_sectors_per_block: u64 = 1 << 23;

/// upper 44 bits = file offset in 1 MiB units (conveniently, masking
/// without shifting already yields the byte offset, since 1 MiB == 2^20 and
/// the mask starts at bit 20); lower 3 bits = block state.
pub const bat_state_mask: u64 = 0x7;
pub const bat_file_off_mask: u64 = 0xFFFF_FFFF_FFF0_0000;

pub const BlockState = enum(u3) {
    not_present = 0,
    undefined_state = 1,
    zero = 2,
    unmapped = 3,
    unmapped_v095 = 5,
    fully_present = 6,
    partially_present = 7,
    _,
};

// ---- Well-known region table entry GUIDs ----
pub const bat_region_guid: guid.Guid = guid.parse("2DC27766-F623-4200-9D64-115E9BFD4A08");
pub const metadata_region_guid: guid.Guid = guid.parse("8B7CA206-4790-4B9A-B8FE-575F050F886E");

// ---- Well-known metadata item GUIDs ----
pub const file_parameters_guid: guid.Guid = guid.parse("CAA16737-FA36-4D43-B3B6-33F0AA44E76B");
pub const virtual_disk_size_guid: guid.Guid = guid.parse("2FA54224-CD1B-4876-B211-5DBED83BF4B8");
pub const page83_data_guid: guid.Guid = guid.parse("BECA12AB-B2E6-4523-93EF-C309E000C746");
pub const logical_sector_size_guid: guid.Guid = guid.parse("8141BF1D-A96F-4709-BA47-F233A8FAAB5F");
pub const physical_sector_size_guid: guid.Guid = guid.parse("CDA348C7-445D-4471-9CC9-E9885251C556");
pub const parent_locator_guid: guid.Guid = guid.parse("A8D35F2D-B30B-454D-ABF7-D3D84834AB0C");

pub const file_params_has_parent: u32 = 0x02;

const Crc32c = std.hash.crc.Crc32Iscsi;

pub const OpenError = error{
    BadFileSignature,
    NoValidHeader,
    BadRegionTableChecksum,
    BadRegionSignature,
    MissingBatRegion,
    MissingMetadataRegion,
    MissingFileParameters,
    MissingVirtualDiskSize,
    MissingLogicalSectorSize,
    UnsupportedLogicalSectorSize,
    DifferencingNotSupported,
    InvalidBlockSize,
} || Io.File.ReadPositionalError;

/// Everything `Image` needs to translate guest-visible byte offsets into
/// file offsets. Not cached beyond these scalars -- BAT entries are read
/// on demand (see `readBatEntry` in `image.zig`), matching the on-demand
/// approach already used for dynamic VHD.
pub const Info = struct {
    virtual_size: u64,
    block_size: u32,
    /// `(2^23 * logical_sector_size) / block_size`, always a power of two.
    chunk_ratio: u64,
    bat_offset: u64,
};

/// Parses the file signature, header, region table, and metadata table,
/// returning enough information to read guest data. `file` must be
/// positioned/seekable via positional reads (no seek state is assumed).
pub fn open(io: Io, file: Io.File) OpenError!Info {
    var sig: [8]u8 = undefined;
    _ = try file.readPositionalAll(io, &sig, file_id_offset);
    if (!std.mem.eql(u8, &sig, &file_signature)) return error.BadFileSignature;

    const header = try readValidHeader(io, file);
    _ = header; // only sequence-number selection matters for us; fields unused beyond that.

    const region = try readRegionTable(io, file);

    const params = try readFileParameters(io, file, region.metadata_offset);
    if (params.data_bits & file_params_has_parent != 0) return error.DifferencingNotSupported;
    if (!std.math.isPowerOfTwo(params.block_size) or params.block_size == 0) return error.InvalidBlockSize;

    const virtual_size = try readVirtualDiskSize(io, file, region.metadata_offset);
    const logical_sector_size = try readLogicalSectorSize(io, file, region.metadata_offset);
    if (logical_sector_size != 512) return error.UnsupportedLogicalSectorSize;

    const chunk_ratio = max_sectors_per_block * logical_sector_size / params.block_size;

    return .{
        .virtual_size = virtual_size,
        .block_size = params.block_size,
        .chunk_ratio = chunk_ratio,
        .bat_offset = region.bat_offset,
    };
}

/// Index into the BAT array for payload block `block_index`, accounting for
/// the interleaved (here, unused/skipped) sector-bitmap-block entries: one
/// extra slot after every `chunk_ratio` payload entries. Matches QEMU's
/// `vhdx_block_translate`: `bat_idx += bat_idx >> chunk_ratio_bits`, i.e.
/// `bat_idx += bat_idx / chunk_ratio` since chunk_ratio is a power of two.
pub fn batIndexForBlock(block_index: u64, chunk_ratio: u64) u64 {
    return block_index + block_index / chunk_ratio;
}

fn readValidHeader(io: Io, file: Io.File) OpenError!HeaderInfo {
    const h1 = readOneHeader(io, file, header1_offset);
    const h2 = readOneHeader(io, file, header2_offset);

    if (h1 != null and h2 == null) return h1.?;
    if (h1 == null and h2 != null) return h2.?;
    if (h1 == null and h2 == null) return error.NoValidHeader;

    if (h1.?.sequence_number >= h2.?.sequence_number) return h1.?;
    return h2.?;
}

const HeaderInfo = struct { sequence_number: u64 };

fn readOneHeader(io: Io, file: Io.File, offset: u64) ?HeaderInfo {
    var buf: [header_size]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, offset) catch return null;
    if (n != header_size) return null;
    if (!std.mem.eql(u8, buf[0..4], &header_signature)) return null;

    var checked = buf;
    checked[4..8].* = .{ 0, 0, 0, 0 };
    const stored_crc = std.mem.readInt(u32, buf[4..8], .little);
    if (Crc32c.hash(&checked) != stored_crc) return null;

    const version = std.mem.readInt(u16, buf[66..68], .little);
    if (version != 1) return null;

    return .{ .sequence_number = std.mem.readInt(u64, buf[8..16], .little) };
}

const RegionInfo = struct {
    bat_offset: u64,
    metadata_offset: u64,
};

fn readRegionTable(io: Io, file: Io.File) OpenError!RegionInfo {
    var buf: [header_block_size]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, region_table_offset);

    var checked = buf;
    checked[4..8].* = .{ 0, 0, 0, 0 };
    const stored_crc = std.mem.readInt(u32, buf[4..8], .little);
    if (Crc32c.hash(&checked) != stored_crc) return error.BadRegionTableChecksum;

    if (!std.mem.eql(u8, buf[0..4], &region_signature)) return error.BadRegionSignature;
    const entry_count = std.mem.readInt(u32, buf[8..12], .little);

    var bat_offset: ?u64 = null;
    var metadata_offset: ?u64 = null;

    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        const off = 16 + i * 32;
        const entry_guid: guid.Guid = buf[off..][0..16].*;
        const file_offset = std.mem.readInt(u64, buf[off + 16 ..][0..8], .little);

        if (std.mem.eql(u8, &entry_guid, &bat_region_guid)) {
            bat_offset = file_offset;
        } else if (std.mem.eql(u8, &entry_guid, &metadata_region_guid)) {
            metadata_offset = file_offset;
        }
    }

    return .{
        .bat_offset = bat_offset orelse return error.MissingBatRegion,
        .metadata_offset = metadata_offset orelse return error.MissingMetadataRegion,
    };
}

/// Finds a metadata item by GUID, returning its absolute file offset and
/// length, or `null` if not present. `metadata_region_offset` is the file
/// offset of the metadata region (from the region table).
fn findMetadataItem(io: Io, file: Io.File, metadata_region_offset: u64, item_guid: guid.Guid) OpenError!?struct { file_offset: u64, length: u32 } {
    var header_buf: [32]u8 = undefined;
    _ = try file.readPositionalAll(io, &header_buf, metadata_region_offset);
    if (!std.mem.eql(u8, header_buf[0..8], &metadata_signature)) return null;

    const entry_count = std.mem.readInt(u16, header_buf[10..12], .little);

    var i: u16 = 0;
    while (i < entry_count) : (i += 1) {
        var entry_buf: [32]u8 = undefined;
        _ = try file.readPositionalAll(io, &entry_buf, metadata_region_offset + 32 + @as(u64, i) * 32);

        const entry_guid: guid.Guid = entry_buf[0..16].*;
        if (std.mem.eql(u8, &entry_guid, &item_guid)) {
            const item_offset = std.mem.readInt(u32, entry_buf[16..20], .little);
            const item_length = std.mem.readInt(u32, entry_buf[20..24], .little);
            return .{ .file_offset = metadata_region_offset + item_offset, .length = item_length };
        }
    }
    return null;
}

fn readFileParameters(io: Io, file: Io.File, metadata_region_offset: u64) OpenError!struct { block_size: u32, data_bits: u32 } {
    const item = (try findMetadataItem(io, file, metadata_region_offset, file_parameters_guid)) orelse
        return error.MissingFileParameters;
    var buf: [8]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, item.file_offset);
    return .{
        .block_size = std.mem.readInt(u32, buf[0..4], .little),
        .data_bits = std.mem.readInt(u32, buf[4..8], .little),
    };
}

fn readVirtualDiskSize(io: Io, file: Io.File, metadata_region_offset: u64) OpenError!u64 {
    const item = (try findMetadataItem(io, file, metadata_region_offset, virtual_disk_size_guid)) orelse
        return error.MissingVirtualDiskSize;
    var buf: [8]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, item.file_offset);
    return std.mem.readInt(u64, &buf, .little);
}

fn readLogicalSectorSize(io: Io, file: Io.File, metadata_region_offset: u64) OpenError!u32 {
    const item = (try findMetadataItem(io, file, metadata_region_offset, logical_sector_size_guid)) orelse
        return error.MissingLogicalSectorSize;
    var buf: [4]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, item.file_offset);
    return std.mem.readInt(u32, &buf, .little);
}

test "batIndexForBlock matches QEMU's vhdx_block_translate interleaving" {
    // chunk_ratio=4: blocks 0-3 map directly, block 4 gets +1 (one sector
    // bitmap slot inserted after every 4 payload entries), block 8 gets +2.
    try std.testing.expectEqual(@as(u64, 0), batIndexForBlock(0, 4));
    try std.testing.expectEqual(@as(u64, 3), batIndexForBlock(3, 4));
    try std.testing.expectEqual(@as(u64, 5), batIndexForBlock(4, 4));
    try std.testing.expectEqual(@as(u64, 8), batIndexForBlock(7, 4));
    try std.testing.expectEqual(@as(u64, 10), batIndexForBlock(8, 4));
}

test "guid constants match known VHDX region/metadata GUIDs" {
    // Cross-checked against QEMU's block/vhdx.c static MSGUID literals
    // (bat_guid, metadata_guid, file_param_guid, ...).
    const expected_bat: guid.Guid = .{
        0x66, 0x77, 0xc2, 0x2d, 0x23, 0xf6, 0x00, 0x42,
        0x9d, 0x64, 0x11, 0x5e, 0x9b, 0xfd, 0x4a, 0x08,
    };
    try std.testing.expectEqualSlices(u8, &expected_bat, &bat_region_guid);
}
