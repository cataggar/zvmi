//! MBR (Master Boot Record) partition table codec. Supports two shapes:
//! a *protective MBR* (a single 0xEE "GPT protective" entry spanning the
//! disk, required at LBA 0 ahead of a GPT for Gen2/UEFI Azure VMs), and a
//! plain single-partition MBR (a bootable 0x83 "Linux" entry, for Gen1/BIOS
//! Azure VMs). Field layout and offsets verified against the classic MBR
//! structure (partition table at offset 0x1BE, boot signature 0x55AA at
//! 0x1FE) documented on Wikipedia's "Master boot record" article.

const std = @import("std");

pub const sector_size: usize = 512;
pub const partition_table_offset: usize = 0x1BE;
pub const entry_size: usize = 16;
pub const max_entries: usize = 4;

pub const boot_signature: [2]u8 = .{ 0x55, 0xAA };

pub const PartitionType = enum(u8) {
    empty = 0x00,
    linux = 0x83,
    gpt_protective = 0xEE,
    _,
};

pub const PartitionEntry = struct {
    bootable: bool = false,
    /// CHS is legacy and ignored by virtually every modern reader in favor
    /// of the LBA fields, but is still computed/filled in for maximum
    /// compatibility with anything that still looks at it.
    start_chs: [3]u8 = .{ 0, 0, 0 },
    partition_type: PartitionType = .empty,
    end_chs: [3]u8 = .{ 0, 0, 0 },
    first_lba: u32 = 0,
    sector_count: u32 = 0,

    fn encode(self: PartitionEntry, buf: *[entry_size]u8) void {
        buf[0] = if (self.bootable) 0x80 else 0x00;
        buf[1..4].* = self.start_chs;
        buf[4] = @intFromEnum(self.partition_type);
        buf[5..8].* = self.end_chs;
        std.mem.writeInt(u32, buf[8..12], self.first_lba, .little);
        std.mem.writeInt(u32, buf[12..16], self.sector_count, .little);
    }

    fn decode(buf: *const [entry_size]u8) PartitionEntry {
        return .{
            .bootable = buf[0] == 0x80,
            .start_chs = buf[1..4].*,
            .partition_type = @enumFromInt(buf[4]),
            .end_chs = buf[5..8].*,
            .first_lba = std.mem.readInt(u32, buf[8..12], .little),
            .sector_count = std.mem.readInt(u32, buf[12..16], .little),
        };
    }
};

pub const Mbr = struct {
    entries: [max_entries]PartitionEntry = [_]PartitionEntry{.{}} ** max_entries,
    /// 32-bit disk signature at offset 0x1B8; zero is valid (means "unset").
    disk_signature: u32 = 0,

    pub fn encode(self: Mbr) [sector_size]u8 {
        var buf: [sector_size]u8 = [_]u8{0} ** sector_size;
        // Bootstrap code area (0..0x1B8) intentionally starts zeroed because
        // this codec only produces partition *tables*, not boot code.
        // Higher-level callers such as `build_image` may later overlay BIOS
        // stage-1 bytes here while preserving the table/signature tail.
        std.mem.writeInt(u32, buf[0x1B8..0x1BC], self.disk_signature, .little);

        for (self.entries, 0..) |entry, i| {
            const off = partition_table_offset + i * entry_size;
            entry.encode(buf[off..][0..entry_size]);
        }
        buf[510..512].* = boot_signature;
        return buf;
    }

    pub const DecodeError = error{BadBootSignature};

    pub fn decode(buf: *const [sector_size]u8) DecodeError!Mbr {
        if (!std.mem.eql(u8, buf[510..512], &boot_signature)) return error.BadBootSignature;

        var entries: [max_entries]PartitionEntry = undefined;
        for (&entries, 0..) |*entry, i| {
            const off = partition_table_offset + i * entry_size;
            entry.* = PartitionEntry.decode(buf[off..][0..entry_size]);
        }
        return .{
            .entries = entries,
            .disk_signature = std.mem.readInt(u32, buf[0x1B8..0x1BC], .little),
        };
    }
};

/// Standard CHS-address translation (heads=255, sectors/track=63), clamped
/// to the maximum representable CHS value (1023, 254, 63) for LBAs beyond
/// what 10-bit cylinders can address -- exactly what real partitioning
/// tools (fdisk, parted) do for any disk too large for pure CHS addressing,
/// which is virtually all disks in practice today. The clamped sentinel
/// signals readers to trust the LBA fields instead.
pub fn chsForLba(lba: u32) [3]u8 {
    const heads: u32 = 255;
    const sectors_per_track: u32 = 63;
    const max_cylinder: u32 = 1023;

    const cylinder = lba / (heads * sectors_per_track);
    if (cylinder > max_cylinder) {
        return .{ 0xFE, 0xFF, 0xFF };
    }
    const head: u32 = (lba / sectors_per_track) % heads;
    const sector: u32 = (lba % sectors_per_track) + 1;

    return .{
        @intCast(head),
        @intCast((sector & 0x3F) | ((cylinder >> 2) & 0xC0)),
        @intCast(cylinder & 0xFF),
    };
}

/// Builds a protective MBR (a single 0xEE entry spanning the disk),
/// required at LBA 0 immediately before a GPT header, per the UEFI spec.
/// `disk_total_sectors` is the whole disk's size in 512-byte sectors.
pub fn protectiveMbr(disk_total_sectors: u64) Mbr {
    // The MBR's LBA/size fields are 32-bit; a disk larger than that gets
    // its protective entry clipped to 0xFFFFFFFF sectors, same as real
    // implementations (the GPT header carries the real, 64-bit extents).
    const size_sectors: u32 = @intCast(@min(disk_total_sectors - 1, 0xFFFF_FFFF));
    var mbr = Mbr{};
    mbr.entries[0] = .{
        .bootable = false,
        .start_chs = chsForLba(1),
        .partition_type = .gpt_protective,
        .end_chs = chsForLba(1 + size_sectors - 1),
        .first_lba = 1,
        .sector_count = size_sectors,
    };
    return mbr;
}

/// Builds a plain single-partition MBR: one bootable 0x83 (Linux) entry
/// starting at `first_lba` and spanning `sector_count` sectors. Used for
/// Gen1 (BIOS) Azure VMs, which boot via a classic MBR + a single root
/// partition (no separate ESP).
pub fn singleLinuxPartitionMbr(first_lba: u32, sector_count: u32) Mbr {
    var mbr = Mbr{};
    mbr.entries[0] = .{
        .bootable = true,
        .start_chs = chsForLba(first_lba),
        .partition_type = .linux,
        .end_chs = chsForLba(first_lba + sector_count - 1),
        .first_lba = first_lba,
        .sector_count = sector_count,
    };
    return mbr;
}

test "protectiveMbr encode/decode round-trip" {
    const total_sectors: u64 = 32 * 1024 * 1024 / 512; // 32 MiB disk
    const mbr = protectiveMbr(total_sectors);
    const encoded = mbr.encode();

    try std.testing.expectEqualSlices(u8, &boot_signature, encoded[510..512]);

    const decoded = try Mbr.decode(&encoded);
    try std.testing.expectEqual(PartitionType.gpt_protective, decoded.entries[0].partition_type);
    try std.testing.expectEqual(@as(u32, 1), decoded.entries[0].first_lba);
    try std.testing.expectEqual(@as(u32, total_sectors - 1), decoded.entries[0].sector_count);
    try std.testing.expectEqual(PartitionType.empty, decoded.entries[1].partition_type);
}

test "singleLinuxPartitionMbr encode/decode round-trip" {
    const mbr = singleLinuxPartitionMbr(2048, 1 * 1024 * 1024);
    const encoded = mbr.encode();
    const decoded = try Mbr.decode(&encoded);

    try std.testing.expectEqual(PartitionType.linux, decoded.entries[0].partition_type);
    try std.testing.expect(decoded.entries[0].bootable);
    try std.testing.expectEqual(@as(u32, 2048), decoded.entries[0].first_lba);
    try std.testing.expectEqual(@as(u32, 1 * 1024 * 1024), decoded.entries[0].sector_count);
}

test "Mbr.decode rejects a bad boot signature" {
    var buf = [_]u8{0} ** sector_size;
    try std.testing.expectError(error.BadBootSignature, Mbr.decode(&buf));
}

test "chsForLba clamps to the sentinel for large LBAs" {
    const chs = chsForLba(0xFFFF_FFFF);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFE, 0xFF, 0xFF }, &chs);
}
