//! Pure partition-layout planning: turn fixed-size and percentage-based
//! partition requests into aligned byte offsets and lengths that fit inside
//! GPT's usable address range.

const std = @import("std");
const azure = @import("azure.zig");
const gpt = @import("gpt.zig");
const guid = @import("guid.zig");

pub const default_alignment: u64 = azure.one_mib;
const percent_epsilon: f64 = 1e-9;

pub const PlanError = std.mem.Allocator.Error || error{
    DiskTooSmall,
    InvalidAlignment,
    InvalidDiskSize,
    InvalidFixedSize,
    InvalidPercentage,
    OverAllocated,
    PartitionTooSmall,
};

pub const PartitionRole = enum {
    esp,
    boot,
    root_x86_64,
    root_aarch64,
    usr_x86_64,
    usr_aarch64,
    linux_filesystem_data,
    microsoft_basic_data,

    pub fn defaultTypeGuid(self: PartitionRole) guid.Guid {
        return switch (self) {
            .esp => guid.esp,
            .boot => guid.linux_xbootldr,
            .root_x86_64 => guid.linux_root_x86_64,
            .root_aarch64 => guid.linux_root_aarch64,
            .usr_x86_64 => guid.linux_usr_x86_64,
            .usr_aarch64 => guid.linux_usr_aarch64,
            .linux_filesystem_data => guid.linux_filesystem_data,
            .microsoft_basic_data => guid.microsoft_basic_data,
        };
    }
};

pub const PartitionRequest = struct {
    name: []const u8,
    role: PartitionRole,
    size: union(enum) {
        fixed: u64,
        percent: f64,
    },
    type_guid: ?guid.Guid = null,
};

/// Planned partitions borrow `name` directly from the corresponding input
/// request.
pub const PlannedPartition = struct {
    name: []const u8,
    role: PartitionRole,
    type_guid: guid.Guid,
    offset_bytes: u64,
    length_bytes: u64,

    pub fn firstLba(self: PlannedPartition) u64 {
        return self.offset_bytes / gpt.sector_size;
    }

    pub fn lastLba(self: PlannedPartition) u64 {
        return self.firstLba() + self.sizeSectors() - 1;
    }

    pub fn sizeSectors(self: PlannedPartition) u64 {
        return self.length_bytes / gpt.sector_size;
    }
};

fn alignSize(size: u64, alignment: u64) u64 {
    std.debug.assert(alignment != 0);
    if (alignment == default_alignment) return azure.alignSizeToMib(size);
    if (size == 0) return 0;
    return ((size - 1) / alignment + 1) * alignment;
}

fn alignSizeDown(size: u64, alignment: u64) u64 {
    std.debug.assert(alignment != 0);
    return size / alignment * alignment;
}

fn scaleUnits(total_units: u64, numerator: f64, denominator: f64) u64 {
    const exact = @as(f64, @floatFromInt(total_units)) * numerator / denominator;
    return @as(u64, @intFromFloat(@floor(exact + percent_epsilon)));
}

/// Plans partitions inside GPT's usable region. Fixed-size requests are
/// aligned up first; percentage requests then consume their requested share
/// of the remaining aligned capacity. If percentage requests sum to less
/// than 100, any tail space is left unallocated at the end of the disk.
pub fn planLayout(
    allocator: std.mem.Allocator,
    disk_size: u64,
    requests: []const PartitionRequest,
    alignment_override: ?u64,
) PlanError![]PlannedPartition {
    const alignment = alignment_override orelse default_alignment;
    if (alignment == 0 or alignment % gpt.sector_size != 0) return error.InvalidAlignment;
    if (disk_size % gpt.sector_size != 0) return error.InvalidDiskSize;

    const total_sectors = disk_size / gpt.sector_size;
    const first_usable_lba: u64 = 2 + gpt.partition_array_sectors;
    const backup_reserved_sectors: u64 = 1 + gpt.partition_array_sectors;
    if (total_sectors <= first_usable_lba + backup_reserved_sectors) return error.DiskTooSmall;

    const first_usable_offset = first_usable_lba * gpt.sector_size;
    const usable_end_offset = disk_size - backup_reserved_sectors * gpt.sector_size;
    const first_partition_offset = alignSize(first_usable_offset, alignment);
    if (first_partition_offset >= usable_end_offset) return error.DiskTooSmall;

    const usable_aligned_bytes = alignSizeDown(usable_end_offset - first_partition_offset, alignment);

    const lengths = try allocator.alloc(u64, requests.len);
    defer allocator.free(lengths);
    @memset(lengths, 0);

    var fixed_total_bytes: u64 = 0;
    var percent_total: f64 = 0.0;
    var percent_count: usize = 0;
    for (requests, 0..) |request, i| {
        switch (request.size) {
            .fixed => |bytes| {
                if (bytes == 0) return error.InvalidFixedSize;
                lengths[i] = alignSize(bytes, alignment);
                if (lengths[i] > usable_aligned_bytes -| fixed_total_bytes) return error.OverAllocated;
                fixed_total_bytes += lengths[i];
            },
            .percent => |percent| {
                if (!std.math.isFinite(percent) or percent <= 0.0) return error.InvalidPercentage;
                percent_total += percent;
                if (percent_total > 100.0 + percent_epsilon) return error.OverAllocated;
                percent_count += 1;
            },
        }
    }

    const remaining_units = (usable_aligned_bytes - fixed_total_bytes) / alignment;
    var remaining_percent_total = percent_total;
    var remaining_percent_units = scaleUnits(remaining_units, percent_total, 100.0);
    var remaining_percent_count = percent_count;
    for (requests, 0..) |request, i| {
        switch (request.size) {
            .fixed => {},
            .percent => |percent| {
                const units = if (remaining_percent_count == 1)
                    remaining_percent_units
                else
                    scaleUnits(remaining_percent_units, percent, remaining_percent_total);
                if (units == 0) return error.PartitionTooSmall;

                lengths[i] = units * alignment;
                remaining_percent_units -= units;
                remaining_percent_total -= percent;
                remaining_percent_count -= 1;
            },
        }
    }

    const planned = try allocator.alloc(PlannedPartition, requests.len);
    errdefer allocator.free(planned);

    var cursor = first_partition_offset;
    for (requests, lengths, 0..) |request, length, i| {
        planned[i] = .{
            .name = request.name,
            .role = request.role,
            .type_guid = request.type_guid orelse request.role.defaultTypeGuid(),
            .offset_bytes = cursor,
            .length_bytes = length,
        };
        cursor += length;
    }

    return planned;
}

test "planLayout mixes fixed and percentage requests deterministically" {
    const requests = [_]PartitionRequest{
        .{ .name = "ESP", .role = .esp, .size = .{ .fixed = 64 * azure.one_mib } },
        .{ .name = "boot", .role = .boot, .size = .{ .fixed = 32 * azure.one_mib } },
        .{ .name = "root", .role = .root_x86_64, .size = .{ .percent = 75.0 } },
        .{ .name = "usr", .role = .usr_x86_64, .size = .{ .percent = 25.0 }, .type_guid = guid.linux_filesystem_data },
    };

    const planned = try planLayout(std.testing.allocator, 512 * azure.one_mib, &requests, null);
    defer std.testing.allocator.free(planned);

    try std.testing.expectEqual(@as(usize, requests.len), planned.len);
    try std.testing.expectEqual(@as(u64, azure.one_mib), planned[0].offset_bytes);
    try std.testing.expectEqual(@as(u64, 64 * azure.one_mib), planned[0].length_bytes);
    try std.testing.expectEqual(@as(u64, 65 * azure.one_mib), planned[1].offset_bytes);
    try std.testing.expectEqualSlices(u8, &guid.linux_xbootldr, &planned[1].type_guid);
    try std.testing.expectEqual(@as(u64, 97 * azure.one_mib), planned[2].offset_bytes);
    try std.testing.expectEqual(@as(u64, 310 * azure.one_mib), planned[2].length_bytes);
    try std.testing.expectEqual(@as(u64, 407 * azure.one_mib), planned[3].offset_bytes);
    try std.testing.expectEqual(@as(u64, 104 * azure.one_mib), planned[3].length_bytes);
    try std.testing.expectEqualSlices(u8, &guid.linux_filesystem_data, &planned[3].type_guid);
}

test "planLayout rounds offsets and lengths to the requested alignment" {
    const requests = [_]PartitionRequest{
        .{ .name = "boot", .role = .boot, .size = .{ .fixed = azure.one_mib } },
        .{ .name = "root", .role = .root_aarch64, .size = .{ .fixed = 5 * azure.one_mib } },
    };

    const four_mib = 4 * azure.one_mib;
    const planned = try planLayout(std.testing.allocator, 128 * azure.one_mib, &requests, four_mib);
    defer std.testing.allocator.free(planned);

    try std.testing.expectEqual(@as(u64, four_mib), planned[0].offset_bytes);
    try std.testing.expectEqual(@as(u64, four_mib), planned[0].length_bytes);
    try std.testing.expectEqual(@as(u64, 2 * four_mib), planned[1].offset_bytes);
    try std.testing.expectEqual(@as(u64, 2 * four_mib), planned[1].length_bytes);
}

test "planLayout rejects over-allocation" {
    const requests = [_]PartitionRequest{
        .{ .name = "ESP", .role = .esp, .size = .{ .fixed = 32 * azure.one_mib } },
        .{ .name = "root", .role = .root_x86_64, .size = .{ .percent = 80.0 } },
        .{ .name = "usr", .role = .usr_x86_64, .size = .{ .percent = 30.0 } },
    };

    try std.testing.expectError(error.OverAllocated, planLayout(std.testing.allocator, 128 * azure.one_mib, &requests, null));
}

test "planLayout rejects a positive percentage that cannot reach one alignment unit" {
    const requests = [_]PartitionRequest{
        .{ .name = "tiny", .role = .linux_filesystem_data, .size = .{ .percent = 1.0 } },
    };

    try std.testing.expectError(error.PartitionTooSmall, planLayout(std.testing.allocator, 64 * azure.one_mib, &requests, null));
}

test "planLayout survives a GPT write/read round-trip" {
    const io = std.testing.io;
    const path = "test-layout-gpt-roundtrip.img";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const disk_size = 256 * azure.one_mib;
    const requests = [_]PartitionRequest{
        .{ .name = "ESP", .role = .esp, .size = .{ .fixed = 64 * azure.one_mib } },
        .{ .name = "root", .role = .root_x86_64, .size = .{ .percent = 100.0 } },
    };

    const planned = try planLayout(std.testing.allocator, disk_size, &requests, null);
    defer std.testing.allocator.free(planned);

    const Image = @import("image.zig").Image;
    var img = try Image.create(io, path, .raw, disk_size, .{});
    defer img.close(io);

    const specs = [_]gpt.PlacedPartitionSpec{
        .{
            .type_guid = planned[0].type_guid,
            .unique_guid = guid.parse("88888888-8888-8888-8888-888888888888"),
            .placement = .{ .first_lba = planned[0].firstLba(), .last_lba = planned[0].lastLba() },
            .name_utf16le = gpt.asciiName(planned[0].name),
        },
        .{
            .type_guid = planned[1].type_guid,
            .unique_guid = guid.parse("99999999-9999-9999-9999-999999999999"),
            .placement = .{ .first_lba = planned[1].firstLba(), .last_lba = planned[1].lastLba() },
            .name_utf16le = gpt.asciiName(planned[1].name),
        },
    };

    const disk_guid = guid.parse("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");
    try gpt.writeGptPlaced(&img, io, disk_guid, &specs);

    const parsed = try gpt.readGpt(img, io, std.testing.allocator);
    defer std.testing.allocator.free(parsed.partitions);

    try std.testing.expectEqual(@as(usize, specs.len), parsed.partitions.len);
    try std.testing.expectEqual(planned[0].firstLba(), parsed.partitions[0].first_lba);
    try std.testing.expectEqual(planned[0].lastLba(), parsed.partitions[0].last_lba);
    try std.testing.expectEqual(planned[1].firstLba(), parsed.partitions[1].first_lba);
    try std.testing.expectEqual(planned[1].lastLba(), parsed.partitions[1].last_lba);
    try std.testing.expectEqualSlices(u8, &guid.esp, &parsed.partitions[0].partition_type_guid);
    try std.testing.expectEqualSlices(u8, &guid.linux_root_x86_64, &parsed.partitions[1].partition_type_guid);
    try std.testing.expectEqualSlices(u8, &disk_guid, &parsed.header.disk_guid);
}
