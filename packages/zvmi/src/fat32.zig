//! FAT32 filesystem read/write support over a partition-sized region inside a
//! `zvmi.Image`. The public API is image+region based rather than owning a raw
//! file handle, so callers can point the filesystem codec at any partition
//! inside a larger disk image and keep using the existing `Image` abstraction.

const std = @import("std");
const Io = std.Io;
const Image = @import("image.zig").Image;

/// Byte range inside the backing `Image` that contains the FAT32 volume.
pub const Region = struct {
    offset: u64,
    length: u64,
};

/// Format-time geometry and metadata. `partition_offset`/`partition_len`
/// describe the partition-relative range to populate inside the backing image.
pub const FormatOptions = struct {
    partition_offset: u64,
    partition_len: u64,
    bytes_per_sector: u16 = default_bytes_per_sector,
    sectors_per_cluster: ?u8 = null,
    fat_count: u8 = 2,
    reserved_sector_count: u16 = 32,
    media_descriptor: u8 = 0xF8,
    sectors_per_track: u16 = 63,
    head_count: u16 = 255,
    hidden_sectors: u32 = 0,
    volume_id: u32 = 0x5A56_4D49,
    volume_label: [11]u8 = "NO NAME    ".*,
};

pub const DirEntryKind = enum { file, directory };

pub const DirEntry = struct {
    name: []u8,
    kind: DirEntryKind,
    size: u32,
};

/// Frees the slice returned by `FileSystem.listDirAlloc`.
pub fn freeDirEntries(allocator: std.mem.Allocator, entries: []DirEntry) void {
    for (entries) |entry| allocator.free(entry.name);
    allocator.free(entries);
}

pub const Error = error{
    VolumeTooSmall,
    UnsupportedBytesPerSector,
    InvalidSectorsPerCluster,
    InvalidFatCount,
    PartitionLengthNotAligned,
    PartitionOutOfBounds,
    InvalidBootSector,
    NotFat32,
    InvalidPath,
    PathComponentTooLong,
    UnsupportedName,
    PathNotFound,
    NotDirectory,
    IsDirectory,
    AlreadyExists,
    NoSpaceLeft,
    BadClusterChain,
    UnexpectedEndOfFile,
    FileTooLarge,
};

pub const FormatError = Error || Image.PreadError || Image.PwriteError;
pub const OpenError = Error || Image.PreadError || Image.PwriteError;
pub const MutationError = Error || Image.PreadError || Image.PwriteError;
pub const ListError = Error || Image.PreadError || Image.PwriteError || std.mem.Allocator.Error;
pub const ReadFileError = Error || Image.PreadError || Image.PwriteError || std.mem.Allocator.Error;

pub const FileSystem = struct {
    image: *Image,
    region: Region,
    info: VolumeInfo,
    free_cluster_count: u32,
    next_free_cluster: u32,

    /// Ensures every component of `path` exists, creating missing
    /// directories along the way (`mkdir -p` semantics).
    pub fn createDir(self: *FileSystem, io: Io, path: []const u8) MutationError!void {
        var current = self.info.root_cluster;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |component| {
            try validateComponent(component);
            if (try self.findEntry(io, current, component)) |entry| {
                if (entry.kind() != .directory) return error.NotDirectory;
                current = entry.first_cluster;
                continue;
            }

            const cluster = try self.allocateCluster(io);
            errdefer self.releaseChain(io, cluster) catch {};
            try self.initDirectoryCluster(io, cluster, current);
            try self.appendDirectoryEntry(io, current, component, .directory, cluster, 0);
            current = cluster;
        }
    }

    /// Creates a new file and writes its full contents in one call.
    pub fn writeFile(self: *FileSystem, io: Io, path: []const u8, contents: []const u8) MutationError!void {
        const parent = try self.resolveParent(io, path);
        if (parent.name.len == 0) return error.InvalidPath;
        if (try self.findEntry(io, parent.cluster, parent.name)) |_| return error.AlreadyExists;
        if (contents.len > std.math.maxInt(u32)) return error.FileTooLarge;

        var first_cluster: u32 = 0;
        if (contents.len > 0) {
            const cluster_size = self.info.clusterSize();
            const needed_clusters: u32 = @intCast(std.math.divCeil(u64, contents.len, cluster_size) catch unreachable);
            first_cluster = try self.allocateChain(io, needed_clusters);
            errdefer self.releaseChain(io, first_cluster) catch {};
            try self.writeChainData(io, first_cluster, contents);
        }

        try self.appendDirectoryEntry(io, parent.cluster, parent.name, .file, first_cluster, @intCast(contents.len));
    }

    /// Returns the immediate children of `path` (`/` or empty for the root).
    pub fn listDirAlloc(self: *FileSystem, io: Io, allocator: std.mem.Allocator, path: []const u8) ListError![]DirEntry {
        const cluster = if (isRootPath(path)) self.info.root_cluster else blk: {
            const entry = (try self.lookup(io, path)) orelse return error.PathNotFound;
            if (entry.kind() != .directory) return error.NotDirectory;
            break :blk entry.first_cluster;
        };

        var entries = std.array_list.Managed(DirEntry).init(allocator);
        errdefer {
            for (entries.items) |entry| allocator.free(entry.name);
            entries.deinit();
        }

        var iter = try DirectoryIterator.init(self, io, cluster);
        while (try iter.next(io, null)) |raw| {
            if (raw.attr & attr_volume_id != 0) continue;
            const name = try raw.nameAlloc(allocator);
            errdefer allocator.free(name);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
                allocator.free(name);
                continue;
            }
            try entries.append(.{
                .name = name,
                .kind = if (raw.attr & attr_directory != 0) .directory else .file,
                .size = raw.size,
            });
        }

        return entries.toOwnedSlice();
    }

    /// Reads the full contents of `path`, following the FAT chain for the
    /// file's data clusters.
    pub fn readFileAlloc(self: *FileSystem, io: Io, allocator: std.mem.Allocator, path: []const u8) ReadFileError![]u8 {
        const entry = (try self.lookup(io, path)) orelse return error.PathNotFound;
        if (entry.kind() != .file) return error.IsDirectory;

        const buffer = try allocator.alloc(u8, entry.size);
        errdefer allocator.free(buffer);
        if (entry.size == 0) return buffer;

        try self.readChainData(io, entry.first_cluster, buffer);
        return buffer;
    }

    fn resolveParent(self: *FileSystem, io: Io, path: []const u8) MutationError!struct { cluster: u32, name: []const u8 } {
        var last_component: []const u8 = "";
        var current = self.info.root_cluster;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |component| {
            try validateComponent(component);
            if (it.peek() == null) {
                last_component = component;
                break;
            }
            const entry = (try self.findEntry(io, current, component)) orelse return error.PathNotFound;
            if (entry.kind() != .directory) return error.NotDirectory;
            current = entry.first_cluster;
        }
        return .{ .cluster = current, .name = last_component };
    }

    fn lookup(self: *FileSystem, io: Io, path: []const u8) OpenError!?LocatedEntry {
        if (isRootPath(path)) return null;
        var current = self.info.root_cluster;
        var found: ?LocatedEntry = null;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |component| {
            try validateComponent(component);
            found = (try self.findEntry(io, current, component)) orelse return null;
            if (it.peek() != null) {
                if (found.?.kind() != .directory) return error.NotDirectory;
                current = found.?.first_cluster;
            }
        }
        return found;
    }

    fn appendDirectoryEntry(
        self: *FileSystem,
        io: Io,
        dir_cluster: u32,
        name: []const u8,
        kind: DirEntryKind,
        first_cluster: u32,
        size: u32,
    ) MutationError!void {
        var utf16_units: [max_long_name_units]u16 = undefined;
        const utf16_name = try encodeLongName(name, &utf16_units);

        const short_name = try chooseShortName(self, io, dir_cluster, name);
        const use_lfn = requiresLongName(name, short_name);
        const lfn_count: usize = if (use_lfn) std.math.divCeil(usize, utf16_name.len + 1, 13) catch unreachable else 0;
        const total_slots = lfn_count + 1;

        var slots: [max_directory_slots][directory_entry_size]u8 = [_][directory_entry_size]u8{[_]u8{0} ** directory_entry_size} ** max_directory_slots;
        if (use_lfn) buildLfnEntries(slots[0..lfn_count], utf16_name, short_name);
        slots[lfn_count] = buildShortEntry(short_name, kind, first_cluster, size);

        const start_slot = try self.findDirectoryEnd(io, dir_cluster);
        try self.ensureDirectorySlots(io, dir_cluster, start_slot + total_slots + 1);
        try self.writeDirectorySlots(io, dir_cluster, start_slot, slots[0..total_slots]);
    }

    fn findEntry(self: *FileSystem, io: Io, dir_cluster: u32, wanted: []const u8) MutationError!?LocatedEntry {
        var iter = try DirectoryIterator.init(self, io, dir_cluster);
        while (try iter.next(io, wanted)) |entry| {
            if (entry.matches(wanted)) return entry;
        }
        return null;
    }

    fn findDirectoryEnd(self: *FileSystem, io: Io, dir_cluster: u32) MutationError!usize {
        var cluster = dir_cluster;
        var slot_index: usize = 0;
        const slots_per_cluster = self.info.clusterSize() / directory_entry_size;
        var cluster_buf: [max_cluster_size]u8 = undefined;

        while (true) {
            const slice = cluster_buf[0..self.info.clusterSize()];
            try self.readCluster(io, cluster, slice);
            var i: usize = 0;
            while (i < slots_per_cluster) : (i += 1) {
                if (slice[i * directory_entry_size] == 0x00) return slot_index + i;
            }
            slot_index += slots_per_cluster;
            const next = try self.nextCluster(io, cluster);
            if (next == null) return slot_index;
            cluster = next.?;
        }
    }

    fn ensureDirectorySlots(self: *FileSystem, io: Io, dir_cluster: u32, needed_slots: usize) MutationError!void {
        const slots_per_cluster = self.info.clusterSize() / directory_entry_size;
        var have_clusters: usize = 0;
        var last_cluster = dir_cluster;
        var cluster = dir_cluster;
        while (true) {
            have_clusters += 1;
            last_cluster = cluster;
            const next = try self.nextCluster(io, cluster);
            if (next == null) break;
            cluster = next.?;
        }

        const required_clusters = std.math.divCeil(usize, needed_slots, slots_per_cluster) catch unreachable;
        while (have_clusters < required_clusters) : (have_clusters += 1) {
            const new_cluster = try self.allocateCluster(io);
            try self.zeroCluster(io, new_cluster);
            try self.writeFatEntry(io, last_cluster, new_cluster);
            last_cluster = new_cluster;
        }
    }

    fn writeDirectorySlots(self: *FileSystem, io: Io, dir_cluster: u32, start_slot: usize, slots: []const [directory_entry_size]u8) MutationError!void {
        const slots_per_cluster = self.info.clusterSize() / directory_entry_size;
        var cluster = dir_cluster;
        var remaining = start_slot;
        while (remaining >= slots_per_cluster) : (remaining -= slots_per_cluster) {
            cluster = (try self.nextCluster(io, cluster)) orelse return error.BadClusterChain;
        }

        var slot_in_cluster = remaining;
        for (slots) |slot| {
            const rel = self.clusterOffset(cluster) + slot_in_cluster * directory_entry_size;
            try self.writeRegion(io, &slot, rel);
            slot_in_cluster += 1;
            if (slot_in_cluster == slots_per_cluster) {
                slot_in_cluster = 0;
                cluster = (try self.nextCluster(io, cluster)) orelse return error.BadClusterChain;
            }
        }
    }

    fn initDirectoryCluster(self: *FileSystem, io: Io, cluster: u32, parent_cluster: u32) MutationError!void {
        try self.zeroCluster(io, cluster);
        const dot = buildDotEntry(false, cluster);
        const dotdot = buildDotEntry(true, parent_cluster);
        try self.writeRegion(io, &dot, self.clusterOffset(cluster));
        try self.writeRegion(io, &dotdot, self.clusterOffset(cluster) + directory_entry_size);
    }

    fn allocateChain(self: *FileSystem, io: Io, count: u32) MutationError!u32 {
        std.debug.assert(count > 0);
        var first: u32 = 0;
        var prev: u32 = 0;
        errdefer if (first != 0) self.releaseChain(io, first) catch {};
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            const cluster = try self.allocateCluster(io);
            if (first == 0) first = cluster else try self.writeFatEntry(io, prev, cluster);
            prev = cluster;
        }
        return first;
    }

    fn releaseChain(self: *FileSystem, io: Io, first_cluster: u32) MutationError!void {
        if (first_cluster == 0) return;
        var cluster = first_cluster;
        while (true) {
            const next = try self.nextCluster(io, cluster);
            try self.writeFatEntry(io, cluster, 0);
            self.free_cluster_count += 1;
            if (cluster < self.next_free_cluster) self.next_free_cluster = cluster;
            if (next == null) break;
            cluster = next.?;
        }
        try self.persistFsInfo(io);
    }

    fn allocateCluster(self: *FileSystem, io: Io) MutationError!u32 {
        if (self.free_cluster_count == 0) return error.NoSpaceLeft;
        const max_cluster = self.info.maxClusterNumber();
        var probe = if (self.next_free_cluster < 2 or self.next_free_cluster > max_cluster) @as(u32, 2) else self.next_free_cluster;
        const start = probe;
        while (true) {
            if (try self.readFatEntry(io, probe) == 0) {
                try self.writeFatEntry(io, probe, fat_entry_eoc);
                self.free_cluster_count -= 1;
                self.next_free_cluster = if (probe == max_cluster) 2 else probe + 1;
                try self.persistFsInfo(io);
                return probe;
            }
            probe = if (probe == max_cluster) 2 else probe + 1;
            if (probe == start) return error.NoSpaceLeft;
        }
    }

    fn writeChainData(self: *FileSystem, io: Io, first_cluster: u32, data: []const u8) MutationError!void {
        const cluster_size = self.info.clusterSize();
        var cluster = first_cluster;
        var offset: usize = 0;
        var zero_buf: [max_cluster_size]u8 = [_]u8{0} ** max_cluster_size;
        while (true) {
            const take = @min(data.len - offset, cluster_size);
            const cluster_rel = self.clusterOffset(cluster);
            try self.writeRegion(io, data[offset .. offset + take], cluster_rel);
            if (take < cluster_size) {
                try self.writeRegion(io, zero_buf[0 .. cluster_size - take], cluster_rel + take);
            }
            offset += take;
            if (offset == data.len) break;
            cluster = (try self.nextCluster(io, cluster)) orelse return error.BadClusterChain;
        }
    }

    fn readChainData(self: *FileSystem, io: Io, first_cluster: u32, buffer: []u8) MutationError!void {
        if (buffer.len == 0) return;
        var cluster = first_cluster;
        const cluster_size = self.info.clusterSize();
        var offset: usize = 0;
        while (offset < buffer.len) {
            const take = @min(buffer.len - offset, cluster_size);
            try self.readRegion(io, buffer[offset .. offset + take], self.clusterOffset(cluster));
            offset += take;
            if (offset == buffer.len) break;
            cluster = (try self.nextCluster(io, cluster)) orelse return error.BadClusterChain;
        }
    }

    fn persistFsInfo(self: *FileSystem, io: Io) MutationError!void {
        var sector: [default_bytes_per_sector]u8 = [_]u8{0} ** default_bytes_per_sector;
        std.mem.writeInt(u32, sector[0..4], fsinfo_lead_signature, .little);
        std.mem.writeInt(u32, sector[484..488], fsinfo_struct_signature, .little);
        std.mem.writeInt(u32, sector[488..492], self.free_cluster_count, .little);
        std.mem.writeInt(u32, sector[492..496], self.next_free_cluster, .little);
        std.mem.writeInt(u32, sector[508..512], fsinfo_trail_signature, .little);

        const primary = @as(u64, self.info.fsinfo_sector) * self.info.bytes_per_sector;
        try self.writeRegion(io, &sector, primary);
        if (self.info.backup_boot_sector + 1 < self.info.reserved_sector_count) {
            const backup = @as(u64, self.info.backup_boot_sector + 1) * self.info.bytes_per_sector;
            try self.writeRegion(io, &sector, backup);
        }
    }

    fn recountFreeClusters(self: *FileSystem, io: Io) MutationError!void {
        var free: u32 = 0;
        var next_free: u32 = 0;
        var cluster: u32 = 2;
        const max_cluster = self.info.maxClusterNumber();
        while (cluster <= max_cluster) : (cluster += 1) {
            if (try self.readFatEntry(io, cluster) == 0) {
                free += 1;
                if (next_free == 0) next_free = cluster;
            }
        }
        self.free_cluster_count = free;
        self.next_free_cluster = if (next_free == 0) 2 else next_free;
    }

    fn nextCluster(self: *FileSystem, io: Io, cluster: u32) MutationError!?u32 {
        const entry = try self.readFatEntry(io, cluster);
        if (entry == 0) return error.BadClusterChain;
        if (entry >= fat_entry_eoc_min and entry <= fat_entry_mask) return null;
        if (entry == fat_entry_bad or entry < 2 or entry > self.info.maxClusterNumber()) return error.BadClusterChain;
        return entry;
    }

    fn readFatEntry(self: *FileSystem, io: Io, cluster: u32) MutationError!u32 {
        var buf: [4]u8 = undefined;
        const rel = @as(u64, self.info.reserved_sector_count) * self.info.bytes_per_sector + @as(u64, cluster) * 4;
        try self.readRegion(io, &buf, rel);
        return std.mem.readInt(u32, &buf, .little) & fat_entry_mask;
    }

    fn writeFatEntry(self: *FileSystem, io: Io, cluster: u32, value: u32) MutationError!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        var fat_index: u8 = 0;
        while (fat_index < self.info.fat_count) : (fat_index += 1) {
            const rel = (@as(u64, self.info.reserved_sector_count) + @as(u64, fat_index) * self.info.fat_size_sectors) * self.info.bytes_per_sector + @as(u64, cluster) * 4;
            try self.writeRegion(io, &buf, rel);
        }
    }

    fn readCluster(self: *FileSystem, io: Io, cluster: u32, buffer: []u8) MutationError!void {
        try self.readRegion(io, buffer, self.clusterOffset(cluster));
    }

    fn zeroCluster(self: *FileSystem, io: Io, cluster: u32) MutationError!void {
        var zeros: [max_cluster_size]u8 = [_]u8{0} ** max_cluster_size;
        try self.writeRegion(io, zeros[0..self.info.clusterSize()], self.clusterOffset(cluster));
    }

    fn clusterOffset(self: *const FileSystem, cluster: u32) u64 {
        const data_sector = self.info.data_start_sector + @as(u64, cluster - 2) * self.info.sectors_per_cluster;
        return data_sector * self.info.bytes_per_sector;
    }

    fn readRegion(self: *const FileSystem, io: Io, buffer: []u8, relative_offset: u64) MutationError!void {
        if (relative_offset + buffer.len > self.region.length) return error.PartitionOutOfBounds;
        const got = try self.image.pread(io, buffer, self.region.offset + relative_offset);
        if (got != buffer.len) return error.UnexpectedEndOfFile;
    }

    fn writeRegion(self: *const FileSystem, io: Io, buffer: []const u8, relative_offset: u64) MutationError!void {
        if (relative_offset + buffer.len > self.region.length) return error.PartitionOutOfBounds;
        try self.image.pwrite(io, buffer, self.region.offset + relative_offset);
    }
};

/// Formats `options.partition_offset..partition_offset+partition_len` inside
/// `image` as a FAT32 volume with an empty root directory.
pub fn format(image: *Image, io: Io, options: FormatOptions) FormatError!void {
    const layout = try computeLayout(options);
    var fs = FileSystem{
        .image = image,
        .region = .{ .offset = options.partition_offset, .length = options.partition_len },
        .info = layout,
        .free_cluster_count = layout.data_cluster_count - 1,
        .next_free_cluster = 3,
    };

    try zeroRange(&fs, io, 0, @as(u64, layout.reserved_sector_count) * layout.bytes_per_sector);
    try zeroRange(&fs, io, @as(u64, layout.reserved_sector_count) * layout.bytes_per_sector, @as(u64, layout.fat_count) * layout.fat_size_sectors * layout.bytes_per_sector);
    try fs.zeroCluster(io, layout.root_cluster);

    const boot_sector = buildBootSector(layout);
    try fs.writeRegion(io, &boot_sector, 0);

    var fsinfo_sector_buf: [default_bytes_per_sector]u8 = [_]u8{0} ** default_bytes_per_sector;
    std.mem.writeInt(u32, fsinfo_sector_buf[0..4], fsinfo_lead_signature, .little);
    std.mem.writeInt(u32, fsinfo_sector_buf[484..488], fsinfo_struct_signature, .little);
    std.mem.writeInt(u32, fsinfo_sector_buf[488..492], layout.data_cluster_count - 1, .little);
    std.mem.writeInt(u32, fsinfo_sector_buf[492..496], 3, .little);
    std.mem.writeInt(u32, fsinfo_sector_buf[508..512], fsinfo_trail_signature, .little);
    try fs.writeRegion(io, &fsinfo_sector_buf, @as(u64, layout.fsinfo_sector) * layout.bytes_per_sector);

    if (layout.backup_boot_sector < layout.reserved_sector_count) {
        try fs.writeRegion(io, &boot_sector, @as(u64, layout.backup_boot_sector) * layout.bytes_per_sector);
    }
    if (layout.backup_boot_sector + 1 < layout.reserved_sector_count) {
        try fs.writeRegion(io, &fsinfo_sector_buf, @as(u64, layout.backup_boot_sector + 1) * layout.bytes_per_sector);
    }

    try fs.writeFatEntry(io, 0, (@as(u32, 0x0FFF_FF00) | options.media_descriptor));
    try fs.writeFatEntry(io, 1, fat_entry_mask);
    try fs.writeFatEntry(io, layout.root_cluster, fat_entry_eoc);
}

/// Opens an existing FAT32 volume that lives inside `region` of `image`.
pub fn open(image: *Image, io: Io, region: Region) OpenError!FileSystem {
    var boot_sector: [default_bytes_per_sector]u8 = undefined;
    if (region.length < default_bytes_per_sector) return error.InvalidBootSector;
    const got = try image.pread(io, &boot_sector, region.offset);
    if (got != boot_sector.len) return error.UnexpectedEndOfFile;

    if (boot_sector[510] != 0x55 or boot_sector[511] != 0xAA) return error.InvalidBootSector;

    const bytes_per_sector = std.mem.readInt(u16, boot_sector[11..13], .little);
    if (!isSupportedBytesPerSector(bytes_per_sector)) return error.UnsupportedBytesPerSector;
    const sectors_per_cluster = boot_sector[13];
    if (!isValidSectorsPerCluster(sectors_per_cluster)) return error.InvalidSectorsPerCluster;

    const reserved_sector_count = std.mem.readInt(u16, boot_sector[14..16], .little);
    const fat_count = boot_sector[16];
    const root_entry_count = std.mem.readInt(u16, boot_sector[17..19], .little);
    const total_sectors_16 = std.mem.readInt(u16, boot_sector[19..21], .little);
    const fat_size_16 = std.mem.readInt(u16, boot_sector[22..24], .little);
    const total_sectors_32 = std.mem.readInt(u32, boot_sector[32..36], .little);
    const fat_size_32 = std.mem.readInt(u32, boot_sector[36..40], .little);
    const root_cluster = std.mem.readInt(u32, boot_sector[44..48], .little);
    const fsinfo_sector = std.mem.readInt(u16, boot_sector[48..50], .little);
    const backup_boot_sector = std.mem.readInt(u16, boot_sector[50..52], .little);
    const hidden_sectors = std.mem.readInt(u32, boot_sector[28..32], .little);
    const media_descriptor = boot_sector[21];
    const sectors_per_track = std.mem.readInt(u16, boot_sector[24..26], .little);
    const head_count = std.mem.readInt(u16, boot_sector[26..28], .little);
    const volume_id = std.mem.readInt(u32, boot_sector[67..71], .little);
    const boot_signature = boot_sector[66];

    if (root_entry_count != 0 or total_sectors_16 != 0 or fat_size_16 != 0) return error.NotFat32;
    if (boot_signature != 0x29) return error.InvalidBootSector;
    if (!std.mem.eql(u8, boot_sector[82..90], "FAT32   ")) return error.NotFat32;
    if (fat_count == 0) return error.InvalidFatCount;
    if (fat_size_32 == 0 or root_cluster < 2) return error.InvalidBootSector;
    if (@as(u64, total_sectors_32) * bytes_per_sector > region.length) return error.PartitionOutOfBounds;

    const data_start_sector = @as(u64, reserved_sector_count) + @as(u64, fat_count) * fat_size_32;
    if (total_sectors_32 <= data_start_sector) return error.InvalidBootSector;
    const data_cluster_count: u32 = @intCast((@as(u64, total_sectors_32) - data_start_sector) / sectors_per_cluster);
    if (data_cluster_count < min_fat32_clusters) return error.NotFat32;

    var label: [11]u8 = undefined;
    @memcpy(&label, boot_sector[71..82]);

    var fs = FileSystem{
        .image = image,
        .region = region,
        .info = .{
            .bytes_per_sector = bytes_per_sector,
            .sectors_per_cluster = sectors_per_cluster,
            .reserved_sector_count = reserved_sector_count,
            .fat_count = fat_count,
            .fat_size_sectors = fat_size_32,
            .total_sectors = total_sectors_32,
            .root_cluster = root_cluster,
            .fsinfo_sector = fsinfo_sector,
            .backup_boot_sector = backup_boot_sector,
            .hidden_sectors = hidden_sectors,
            .media_descriptor = media_descriptor,
            .sectors_per_track = sectors_per_track,
            .head_count = head_count,
            .volume_id = volume_id,
            .volume_label = label,
            .data_start_sector = data_start_sector,
            .data_cluster_count = data_cluster_count,
        },
        .free_cluster_count = 0,
        .next_free_cluster = 2,
    };

    if (fsinfo_sector < reserved_sector_count) {
        var sector: [default_bytes_per_sector]u8 = undefined;
        try fs.readRegion(io, &sector, @as(u64, fsinfo_sector) * bytes_per_sector);
        if (std.mem.readInt(u32, sector[0..4], .little) == fsinfo_lead_signature and
            std.mem.readInt(u32, sector[484..488], .little) == fsinfo_struct_signature and
            std.mem.readInt(u32, sector[508..512], .little) == fsinfo_trail_signature)
        {
            fs.free_cluster_count = std.mem.readInt(u32, sector[488..492], .little);
            fs.next_free_cluster = std.mem.readInt(u32, sector[492..496], .little);
        } else {
            try fs.recountFreeClusters(io);
        }
    } else {
        try fs.recountFreeClusters(io);
    }

    return fs;
}

const default_bytes_per_sector: usize = 512;
const max_cluster_size: usize = 32 * 1024;
const min_fat32_clusters: u32 = 65_525;
const max_long_name_units: usize = 255;
const directory_entry_size: usize = 32;
const max_directory_slots: usize = 21;
const fat_entry_mask: u32 = 0x0FFF_FFFF;
const fat_entry_eoc: u32 = 0x0FFF_FFFF;
const fat_entry_eoc_min: u32 = 0x0FFF_FFF8;
const fat_entry_bad: u32 = 0x0FFF_FFF7;
const fsinfo_lead_signature: u32 = 0x4161_5252;
const fsinfo_struct_signature: u32 = 0x6141_7272;
const fsinfo_trail_signature: u32 = 0xAA55_0000;
const attr_read_only: u8 = 0x01;
const attr_hidden: u8 = 0x02;
const attr_system: u8 = 0x04;
const attr_volume_id: u8 = 0x08;
const attr_directory: u8 = 0x10;
const attr_archive: u8 = 0x20;
const attr_long_name: u8 = attr_read_only | attr_hidden | attr_system | attr_volume_id;
const timestamp_date_placeholder: u16 = 1 << 5 | 1;

const VolumeInfo = struct {
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sector_count: u16,
    fat_count: u8,
    fat_size_sectors: u32,
    total_sectors: u32,
    root_cluster: u32,
    fsinfo_sector: u16,
    backup_boot_sector: u16,
    hidden_sectors: u32,
    media_descriptor: u8,
    sectors_per_track: u16,
    head_count: u16,
    volume_id: u32,
    volume_label: [11]u8,
    data_start_sector: u64,
    data_cluster_count: u32,

    fn clusterSize(self: VolumeInfo) usize {
        return @as(usize, self.bytes_per_sector) * self.sectors_per_cluster;
    }

    fn maxClusterNumber(self: VolumeInfo) u32 {
        return self.data_cluster_count + 1;
    }
};

const LocatedEntry = struct {
    short_name: [11]u8,
    utf16_name: [max_long_name_units]u16,
    utf16_len: usize,
    attr: u8,
    first_cluster: u32,
    size: u32,

    fn kind(self: LocatedEntry) DirEntryKind {
        return if (self.attr & attr_directory != 0) .directory else .file;
    }

    fn matches(self: LocatedEntry, wanted: []const u8) bool {
        var utf16: [max_long_name_units]u16 = undefined;
        const units = encodeLongName(wanted, &utf16) catch return false;
        if (units.len != self.utf16_len) return false;
        var i: usize = 0;
        while (i < units.len) : (i += 1) {
            if (!utf16EqualFold(units[i], self.utf16_name[i])) return false;
        }
        return true;
    }

    fn nameAlloc(self: LocatedEntry, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var utf8_len: usize = 0;
        var i: usize = 0;
        while (i < self.utf16_len) {
            const scalar, const consumed = decodeUtf16Scalar(self.utf16_name[i..self.utf16_len]) catch unreachable;
            utf8_len += std.unicode.utf8CodepointSequenceLength(scalar) catch unreachable;
            i += consumed;
        }
        const out = try allocator.alloc(u8, utf8_len);
        var out_i: usize = 0;
        i = 0;
        while (i < self.utf16_len) {
            const scalar, const consumed = decodeUtf16Scalar(self.utf16_name[i..self.utf16_len]) catch unreachable;
            out_i += std.unicode.utf8Encode(scalar, out[out_i..]) catch unreachable;
            i += consumed;
        }
        return out;
    }
};

const DirectoryIterator = struct {
    fs: *FileSystem,
    cluster: u32,
    cluster_buf: [max_cluster_size]u8 = undefined,
    offset_in_cluster: usize = 0,
    eof: bool = false,
    lfn: LongNameState = .{},

    fn init(fs: *FileSystem, io: Io, cluster: u32) MutationError!DirectoryIterator {
        var iter = DirectoryIterator{ .fs = fs, .cluster = cluster };
        try iter.fs.readCluster(io, cluster, iter.cluster_buf[0..iter.fs.info.clusterSize()]);
        return iter;
    }

    fn next(self: *DirectoryIterator, io: Io, _: ?[]const u8) MutationError!?LocatedEntry {
        if (self.eof) return null;
        const cluster_size = self.fs.info.clusterSize();

        while (true) {
            if (self.offset_in_cluster == cluster_size) {
                const next_cluster = try self.fs.nextCluster(io, self.cluster);
                if (next_cluster == null) {
                    self.eof = true;
                    return null;
                }
                self.cluster = next_cluster.?;
                self.offset_in_cluster = 0;
                try self.fs.readCluster(io, self.cluster, self.cluster_buf[0..cluster_size]);
            }

            const entry = self.cluster_buf[self.offset_in_cluster .. self.offset_in_cluster + directory_entry_size];
            self.offset_in_cluster += directory_entry_size;

            if (entry[0] == 0x00) {
                self.eof = true;
                return null;
            }
            if (entry[0] == 0xE5) {
                self.lfn.reset();
                continue;
            }
            if (entry[11] == attr_long_name) {
                self.lfn.push(entry) catch self.lfn.reset();
                continue;
            }

            const located = try makeLocatedEntry(entry, &self.lfn);
            self.lfn.reset();
            return located;
        }
    }
};

const LongNameState = struct {
    units: [max_long_name_units]u16 = undefined,
    len: usize = 0,
    checksum: u8 = 0,
    expected_sequence: u8 = 0,
    active: bool = false,

    fn reset(self: *LongNameState) void {
        self.* = .{};
    }

    fn push(self: *LongNameState, entry: []const u8) Error!void {
        const sequence = entry[0] & 0x1F;
        if (sequence == 0) return error.InvalidBootSector;
        const is_last = entry[0] & 0x40 != 0;
        const checksum = entry[13];
        if (is_last) {
            self.reset();
            self.active = true;
            self.expected_sequence = sequence;
            self.checksum = checksum;
            self.len = @as(usize, sequence) * 13;
            if (self.len > self.units.len) return error.PathComponentTooLong;
        } else if (!self.active or sequence != self.expected_sequence - 1 or checksum != self.checksum) {
            return error.InvalidBootSector;
        }
        self.expected_sequence = sequence;
        const index = (@as(usize, sequence) - 1) * 13;
        copyLfnUnits(self.units[index .. index + 13], entry);
        if (sequence == 1) {
            var actual_len: usize = 0;
            while (actual_len < self.len and self.units[actual_len] != 0x0000 and self.units[actual_len] != 0xFFFF) : (actual_len += 1) {}
            self.len = actual_len;
        }
    }
};

fn computeLayout(options: FormatOptions) Error!VolumeInfo {
    if (!isSupportedBytesPerSector(options.bytes_per_sector)) return error.UnsupportedBytesPerSector;
    if (options.partition_len % options.bytes_per_sector != 0) return error.PartitionLengthNotAligned;
    if (options.fat_count == 0) return error.InvalidFatCount;
    if (options.reserved_sector_count < 8) return error.InvalidBootSector;

    const total_sectors_u64 = options.partition_len / options.bytes_per_sector;
    if (total_sectors_u64 > std.math.maxInt(u32)) return error.VolumeTooSmall;
    const total_sectors: u32 = @intCast(total_sectors_u64);

    const sectors_per_cluster = if (options.sectors_per_cluster) |spc| blk: {
        if (!isValidSectorsPerCluster(spc)) return error.InvalidSectorsPerCluster;
        if (@as(u32, spc) * options.bytes_per_sector > max_cluster_size) return error.InvalidSectorsPerCluster;
        break :blk spc;
    } else try chooseSectorsPerCluster(total_sectors, options.bytes_per_sector, options.reserved_sector_count, options.fat_count);

    const layout = try layoutFor(total_sectors, options.bytes_per_sector, options.reserved_sector_count, options.fat_count, sectors_per_cluster);
    if (layout.data_cluster_count < min_fat32_clusters) return error.VolumeTooSmall;

    return .{
        .bytes_per_sector = options.bytes_per_sector,
        .sectors_per_cluster = sectors_per_cluster,
        .reserved_sector_count = options.reserved_sector_count,
        .fat_count = options.fat_count,
        .fat_size_sectors = layout.fat_size_sectors,
        .total_sectors = total_sectors,
        .root_cluster = 2,
        .fsinfo_sector = 1,
        .backup_boot_sector = 6,
        .hidden_sectors = options.hidden_sectors,
        .media_descriptor = options.media_descriptor,
        .sectors_per_track = options.sectors_per_track,
        .head_count = options.head_count,
        .volume_id = options.volume_id,
        .volume_label = options.volume_label,
        .data_start_sector = layout.data_start_sector,
        .data_cluster_count = layout.data_cluster_count,
    };
}

fn chooseSectorsPerCluster(total_sectors: u32, bytes_per_sector: u16, reserved_sector_count: u16, fat_count: u8) Error!u8 {
    const candidates = [_]u8{ 1, 2, 4, 8, 16, 32, 64, 128 };
    for (candidates) |candidate| {
        if (@as(u32, candidate) * bytes_per_sector > max_cluster_size) continue;
        const layout = try layoutFor(total_sectors, bytes_per_sector, reserved_sector_count, fat_count, candidate);
        if (layout.data_cluster_count >= min_fat32_clusters) return candidate;
    }
    return error.VolumeTooSmall;
}

fn layoutFor(total_sectors: u32, bytes_per_sector: u16, reserved_sector_count: u16, fat_count: u8, sectors_per_cluster: u8) Error!struct { fat_size_sectors: u32, data_start_sector: u64, data_cluster_count: u32 } {
    var fat_size: u32 = 1;
    while (true) {
        const metadata_sectors = @as(u64, reserved_sector_count) + @as(u64, fat_count) * fat_size;
        if (metadata_sectors >= total_sectors) return error.VolumeTooSmall;
        const data_sectors = @as(u64, total_sectors) - metadata_sectors;
        const cluster_count: u32 = @intCast(data_sectors / sectors_per_cluster);
        if (cluster_count == 0) return error.VolumeTooSmall;
        const needed_fat = std.math.divCeil(u64, (@as(u64, cluster_count) + 2) * 4, bytes_per_sector) catch unreachable;
        if (needed_fat <= fat_size) {
            return .{
                .fat_size_sectors = fat_size,
                .data_start_sector = metadata_sectors,
                .data_cluster_count = cluster_count,
            };
        }
        fat_size = @intCast(needed_fat);
    }
}

fn buildBootSector(info: VolumeInfo) [default_bytes_per_sector]u8 {
    var sector: [default_bytes_per_sector]u8 = [_]u8{0} ** default_bytes_per_sector;
    sector[0] = 0xEB;
    sector[1] = 0x58;
    sector[2] = 0x90;
    sector[3..11].* = "zvmiFAT ".*;
    std.mem.writeInt(u16, sector[11..13], info.bytes_per_sector, .little);
    sector[13] = info.sectors_per_cluster;
    std.mem.writeInt(u16, sector[14..16], info.reserved_sector_count, .little);
    sector[16] = info.fat_count;
    std.mem.writeInt(u16, sector[17..19], 0, .little);
    std.mem.writeInt(u16, sector[19..21], 0, .little);
    sector[21] = info.media_descriptor;
    std.mem.writeInt(u16, sector[22..24], 0, .little);
    std.mem.writeInt(u16, sector[24..26], info.sectors_per_track, .little);
    std.mem.writeInt(u16, sector[26..28], info.head_count, .little);
    std.mem.writeInt(u32, sector[28..32], info.hidden_sectors, .little);
    std.mem.writeInt(u32, sector[32..36], info.total_sectors, .little);
    std.mem.writeInt(u32, sector[36..40], info.fat_size_sectors, .little);
    std.mem.writeInt(u16, sector[40..42], 0, .little);
    std.mem.writeInt(u16, sector[42..44], 0, .little);
    std.mem.writeInt(u32, sector[44..48], info.root_cluster, .little);
    std.mem.writeInt(u16, sector[48..50], info.fsinfo_sector, .little);
    std.mem.writeInt(u16, sector[50..52], info.backup_boot_sector, .little);
    sector[64] = 0x80;
    sector[66] = 0x29;
    std.mem.writeInt(u32, sector[67..71], info.volume_id, .little);
    sector[71..82].* = info.volume_label;
    sector[82..90].* = "FAT32   ".*;
    sector[510] = 0x55;
    sector[511] = 0xAA;
    return sector;
}

fn zeroRange(fs: *const FileSystem, io: Io, start: u64, length: u64) MutationError!void {
    var zeros: [4096]u8 = [_]u8{0} ** 4096;
    var written: u64 = 0;
    while (written < length) {
        const take: usize = @intCast(@min(length - written, zeros.len));
        try fs.writeRegion(io, zeros[0..take], start + written);
        written += take;
    }
}

fn isSupportedBytesPerSector(value: u16) bool {
    return value == 512 or value == 1024 or value == 2048 or value == 4096;
}

fn isValidSectorsPerCluster(value: u8) bool {
    return value != 0 and std.math.isPowerOfTwo(value) and value <= 128;
}

fn isRootPath(path: []const u8) bool {
    return path.len == 0 or std.mem.eql(u8, path, "/");
}

fn validateComponent(component: []const u8) Error!void {
    if (component.len == 0) return error.InvalidPath;
    if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidPath;
    if (component[component.len - 1] == ' ' or component[component.len - 1] == '.') return error.UnsupportedName;

    var utf16_units: [max_long_name_units]u16 = undefined;
    const units = try encodeLongName(component, &utf16_units);
    if (units.len == 0) return error.InvalidPath;
}

fn encodeLongName(name: []const u8, out: *[max_long_name_units]u16) Error![]const u16 {
    var in_i: usize = 0;
    var out_i: usize = 0;
    while (in_i < name.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(name[in_i]) catch return error.UnsupportedName;
        if (in_i + cp_len > name.len) return error.UnsupportedName;
        const codepoint = std.unicode.utf8Decode(name[in_i .. in_i + cp_len]) catch return error.UnsupportedName;
        switch (codepoint) {
            0...31 => return error.UnsupportedName,
            '/', '\\', ':', '*', '?', '"', '<', '>', '|' => return error.UnsupportedName,
            else => {},
        }
        if (codepoint <= 0xFFFF) {
            if (out_i >= out.len) return error.PathComponentTooLong;
            out[out_i] = @intCast(codepoint);
            out_i += 1;
        } else {
            if (out_i + 1 >= out.len) return error.PathComponentTooLong;
            const scalar = codepoint - 0x1_0000;
            out[out_i] = @intCast(0xD800 + (scalar >> 10));
            out[out_i + 1] = @intCast(0xDC00 + (scalar & 0x3FF));
            out_i += 2;
        }
        in_i += cp_len;
    }
    return out[0..out_i];
}

fn decodeUtf16Scalar(units: []const u16) Error!struct { u21, usize } {
    const first = units[0];
    if (first >= 0xD800 and first <= 0xDBFF) {
        if (units.len < 2) return error.UnsupportedName;
        const second = units[1];
        if (second < 0xDC00 or second > 0xDFFF) return error.UnsupportedName;
        const scalar = 0x1_0000 + (((@as(u21, first) - 0xD800) << 10) | (@as(u21, second) - 0xDC00));
        return .{ scalar, 2 };
    }
    if (first >= 0xDC00 and first <= 0xDFFF) return error.UnsupportedName;
    return .{ first, 1 };
}

fn utf16EqualFold(a: u16, b: u16) bool {
    if (a < 128 and b < 128) return std.ascii.toUpper(@intCast(a)) == std.ascii.toUpper(@intCast(b));
    return a == b;
}

fn makeLocatedEntry(entry: []const u8, lfn: *LongNameState) MutationError!LocatedEntry {
    var result = LocatedEntry{
        .short_name = undefined,
        .utf16_name = undefined,
        .utf16_len = 0,
        .attr = entry[11],
        .first_cluster = (@as(u32, std.mem.readInt(u16, entry[20..22], .little)) << 16) | std.mem.readInt(u16, entry[26..28], .little),
        .size = std.mem.readInt(u32, entry[28..32], .little),
    };
    @memcpy(&result.short_name, entry[0..11]);

    if (lfn.active and lfn.expected_sequence == 1 and shortNameChecksum(result.short_name) == lfn.checksum and lfn.len > 0) {
        result.utf16_len = lfn.len;
        @memcpy(result.utf16_name[0..lfn.len], lfn.units[0..lfn.len]);
    } else {
        result.utf16_len = try decodeShortNameUtf16(result.short_name, &result.utf16_name);
    }
    return result;
}

fn decodeShortNameUtf16(short_name: [11]u8, out: *[max_long_name_units]u16) Error!usize {
    var len: usize = 0;
    var base_end: usize = 8;
    while (base_end > 0 and short_name[base_end - 1] == ' ') : (base_end -= 1) {}
    var i: usize = 0;
    while (i < base_end) : (i += 1) {
        out[len] = if (i == 0 and short_name[i] == 0x05) 0x00E5 else short_name[i];
        len += 1;
    }
    var ext_end: usize = 11;
    while (ext_end > 8 and short_name[ext_end - 1] == ' ') : (ext_end -= 1) {}
    if (ext_end > 8) {
        out[len] = '.';
        len += 1;
        i = 8;
        while (i < ext_end) : (i += 1) {
            out[len] = short_name[i];
            len += 1;
        }
    }
    return len;
}

fn requiresLongName(name: []const u8, short_name: [11]u8) bool {
    if (isCanonicalShortName(name)) {
        var utf16_name: [max_long_name_units]u16 = undefined;
        const units = encodeLongName(name, &utf16_name) catch return true;
        var short_units: [max_long_name_units]u16 = undefined;
        const short_len = decodeShortNameUtf16(short_name, &short_units) catch return true;
        if (units.len != short_len) return true;
        var i: usize = 0;
        while (i < units.len) : (i += 1) {
            if (units[i] != short_units[i]) return true;
        }
        return false;
    }
    return true;
}

fn isCanonicalShortName(name: []const u8) bool {
    const split = splitName(name);
    if (split.base.len == 0 or split.base.len > 8 or split.ext.len > 3) return false;
    for (split.base) |ch| if (!isCanonicalShortChar(ch)) return false;
    for (split.ext) |ch| if (!isCanonicalShortChar(ch)) return false;
    return true;
}

fn isCanonicalShortChar(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or switch (ch) {
        '$', '%', '\'', '-', '_', '@', '~', '`', '!', '(', ')', '{', '}', '^', '#', '&' => true,
        else => false,
    };
}

fn sanitizeShortComponent(source: []const u8, max_len: usize, default_value: []const u8, out: []u8) usize {
    var len: usize = 0;
    for (source) |ch| {
        if (ch == ' ' or ch == '.') continue;
        const upper = std.ascii.toUpper(ch);
        if (isCanonicalShortChar(upper)) {
            out[len] = upper;
        } else if (upper < 128) {
            out[len] = '_';
        } else {
            continue;
        }
        len += 1;
        if (len == max_len) break;
    }
    if (len == 0) {
        const take = @min(max_len, default_value.len);
        @memcpy(out[0..take], default_value[0..take]);
        return take;
    }
    return len;
}

fn splitName(name: []const u8) struct { base: []const u8, ext: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        if (dot == 0 or dot == name.len - 1) return .{ .base = name, .ext = "" };
        return .{ .base = name[0..dot], .ext = name[dot + 1 ..] };
    }
    return .{ .base = name, .ext = "" };
}

fn buildShortName(base: []const u8, ext: []const u8) [11]u8 {
    var short_name = [_]u8{' '} ** 11;
    @memcpy(short_name[0..base.len], base);
    @memcpy(short_name[8 .. 8 + ext.len], ext);
    return short_name;
}

fn chooseShortName(fs: *FileSystem, io: Io, dir_cluster: u32, name: []const u8) MutationError![11]u8 {
    const split = splitName(name);
    if (isCanonicalShortName(name)) {
        const direct = buildShortName(split.base, split.ext);
        if (try shortNameExists(fs, io, dir_cluster, direct)) return error.AlreadyExists;
        return direct;
    }

    var base_buf: [8]u8 = undefined;
    var ext_buf: [3]u8 = undefined;
    const ext_len = sanitizeShortComponent(split.ext, 3, "", &ext_buf);
    const stem_len = sanitizeShortComponent(split.base, 8, "FILE", &base_buf);

    var suffix_num: u32 = 1;
    while (suffix_num < 1_000_000) : (suffix_num += 1) {
        var suffix_buf: [8]u8 = undefined;
        const suffix = try std.fmt.bufPrint(&suffix_buf, "~{d}", .{suffix_num});
        var stem_with_suffix: [8]u8 = [_]u8{' '} ** 8;
        const prefix_len = 8 - suffix.len;
        @memcpy(stem_with_suffix[0..prefix_len], base_buf[0..@min(prefix_len, stem_len)]);
        @memcpy(stem_with_suffix[prefix_len .. prefix_len + suffix.len], suffix);
        const candidate = buildShortName(trimSpaces(&stem_with_suffix), ext_buf[0..ext_len]);
        if (!(try shortNameExists(fs, io, dir_cluster, candidate))) return candidate;
    }
    return error.NoSpaceLeft;
}

fn trimSpaces(buf: []const u8) []const u8 {
    var end = buf.len;
    while (end > 0 and buf[end - 1] == ' ') : (end -= 1) {}
    return buf[0..end];
}

fn shortNameExists(fs: *FileSystem, io: Io, dir_cluster: u32, short_name: [11]u8) MutationError!bool {
    var iter = try DirectoryIterator.init(fs, io, dir_cluster);
    while (try iter.next(io, null)) |entry| {
        if (std.mem.eql(u8, &entry.short_name, &short_name)) return true;
    }
    return false;
}

fn shortNameChecksum(short_name: [11]u8) u8 {
    var sum: u8 = 0;
    for (short_name) |ch| {
        sum = (((sum & 1) << 7) +% (sum >> 1)) +% ch;
    }
    return sum;
}

fn buildShortEntry(short_name: [11]u8, kind: DirEntryKind, first_cluster: u32, size: u32) [directory_entry_size]u8 {
    var entry: [directory_entry_size]u8 = [_]u8{0} ** directory_entry_size;
    entry[0..11].* = short_name;
    entry[11] = if (kind == .directory) attr_directory else attr_archive;
    std.mem.writeInt(u16, entry[14..16], 0, .little);
    std.mem.writeInt(u16, entry[16..18], timestamp_date_placeholder, .little);
    std.mem.writeInt(u16, entry[18..20], timestamp_date_placeholder, .little);
    std.mem.writeInt(u16, entry[20..22], @intCast(first_cluster >> 16), .little);
    std.mem.writeInt(u16, entry[22..24], 0, .little);
    std.mem.writeInt(u16, entry[24..26], timestamp_date_placeholder, .little);
    std.mem.writeInt(u16, entry[26..28], @intCast(first_cluster & 0xFFFF), .little);
    std.mem.writeInt(u32, entry[28..32], size, .little);
    return entry;
}

fn buildDotEntry(parent: bool, cluster: u32) [directory_entry_size]u8 {
    var name = [_]u8{' '} ** 11;
    name[0] = '.';
    if (parent) name[1] = '.';
    return buildShortEntry(name, .directory, cluster, 0);
}

fn buildLfnEntries(entries: [][directory_entry_size]u8, utf16_name: []const u16, short_name: [11]u8) void {
    const checksum = shortNameChecksum(short_name);
    const count = entries.len;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const sequence = count - index;
        var entry: [directory_entry_size]u8 = [_]u8{0} ** directory_entry_size;
        entry[0] = @intCast(sequence);
        if (index == 0) entry[0] |= 0x40;
        entry[11] = attr_long_name;
        entry[12] = 0;
        entry[13] = checksum;
        std.mem.writeInt(u16, entry[26..28], 0, .little);

        const start = (sequence - 1) * 13;
        var units: [13]u16 = [_]u16{0xFFFF} ** 13;
        var i: usize = 0;
        while (i < 13 and start + i < utf16_name.len) : (i += 1) units[i] = utf16_name[start + i];
        if (start + i == utf16_name.len and i < 13) {
            units[i] = 0x0000;
            i += 1;
            while (i < 13) : (i += 1) units[i] = 0xFFFF;
        }
        writeLfnUnitSlice(entry[1..11], units[0..5]);
        writeLfnUnitSlice(entry[14..26], units[5..11]);
        writeLfnUnitSlice(entry[28..32], units[11..13]);
        entries[index] = entry;
    }
}

fn writeLfnUnitSlice(bytes: []u8, units: []const u16) void {
    var i: usize = 0;
    while (i < units.len) : (i += 1) {
        std.mem.writeInt(u16, bytes[i * 2 ..][0..2], units[i], .little);
    }
}

fn copyLfnUnits(out: []u16, entry: []const u8) void {
    readLfnUnitSlice(out[0..5], entry[1..11]);
    readLfnUnitSlice(out[5..11], entry[14..26]);
    readLfnUnitSlice(out[11..13], entry[28..32]);
}

fn readLfnUnitSlice(out: []u16, bytes: []const u8) void {
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        out[i] = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little);
    }
}

test "format writes FAT32 boot sector, FSInfo, backup boot sector, and root FAT anchor" {
    const io = std.testing.io;
    const path = "test-fat32-format.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const partition_offset: u64 = 1024 * 1024;
    const partition_len: u64 = 64 * 1024 * 1024;
    const image_len = partition_offset + partition_len + 4096;

    var img = try Image.create(io, path, .raw, image_len, .{});
    defer img.close(io);

    try format(&img, io, .{ .partition_offset = partition_offset, .partition_len = partition_len });

    var boot: [512]u8 = undefined;
    _ = try img.pread(io, &boot, partition_offset);
    try std.testing.expectEqualSlices(u8, "FAT32   ", boot[82..90]);
    try std.testing.expectEqual(@as(u16, 512), std.mem.readInt(u16, boot[11..13], .little));
    try std.testing.expectEqual(@as(u8, 32), std.mem.readInt(u16, boot[14..16], .little));
    try std.testing.expectEqual(@as(u8, 2), boot[16]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, boot[44..48], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, boot[48..50], .little));
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, boot[50..52], .little));
    try std.testing.expectEqual(@as(u8, 0x55), boot[510]);
    try std.testing.expectEqual(@as(u8, 0xAA), boot[511]);

    var fsinfo_sector: [512]u8 = undefined;
    _ = try img.pread(io, &fsinfo_sector, partition_offset + 512);
    try std.testing.expectEqual(fsinfo_lead_signature, std.mem.readInt(u32, fsinfo_sector[0..4], .little));
    try std.testing.expectEqual(fsinfo_struct_signature, std.mem.readInt(u32, fsinfo_sector[484..488], .little));
    try std.testing.expectEqual(fsinfo_trail_signature, std.mem.readInt(u32, fsinfo_sector[508..512], .little));

    var backup_boot: [512]u8 = undefined;
    _ = try img.pread(io, &backup_boot, partition_offset + 6 * 512);
    try std.testing.expectEqualSlices(u8, &boot, &backup_boot);

    var fat0: [12]u8 = undefined;
    _ = try img.pread(io, &fat0, partition_offset + 32 * 512);
    try std.testing.expectEqual(@as(u32, 0x0FFF_FFF8), std.mem.readInt(u32, fat0[0..4], .little) & fat_entry_mask);
    try std.testing.expectEqual(fat_entry_mask, std.mem.readInt(u32, fat0[4..8], .little) & fat_entry_mask);
    try std.testing.expectEqual(fat_entry_eoc, std.mem.readInt(u32, fat0[8..12], .little) & fat_entry_mask);
}

test "format, write nested tree with VFAT long names, list, and read back" {
    const io = std.testing.io;
    const path = "test-fat32-roundtrip.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const partition_offset: u64 = 2 * 1024 * 1024;
    const partition_len: u64 = 96 * 1024 * 1024;
    const image_len = partition_offset + partition_len;

    var img = try Image.create(io, path, .raw, image_len, .{});
    try format(&img, io, .{ .partition_offset = partition_offset, .partition_len = partition_len });

    var fs = try open(&img, io, .{ .offset = partition_offset, .length = partition_len });
    try fs.createDir(io, "EFI/BOOT");
    try fs.createDir(io, "EFI/tools and utilities");
    try fs.writeFile(io, "EFI/BOOT/BOOTX64.EFI", "shim payload");
    try fs.writeFile(io, "EFI/BOOT/grub configuration.cfg", "set timeout=0\nmenuentry 'test' {}\n");
    try fs.writeFile(io, "EFI/tools and utilities/fallback bootloader path.txt", "EFI/BOOT/BOOTX64.EFI\n");
    img.close(io);

    var reopened = try Image.openPath(io, path);
    defer reopened.close(io);
    var reopened_fs = try open(&reopened, io, .{ .offset = partition_offset, .length = partition_len });

    const root_entries = try reopened_fs.listDirAlloc(io, std.testing.allocator, "/");
    defer freeDirEntries(std.testing.allocator, root_entries);
    try std.testing.expectEqual(@as(usize, 1), root_entries.len);
    try std.testing.expectEqualStrings("EFI", root_entries[0].name);
    try std.testing.expectEqual(DirEntryKind.directory, root_entries[0].kind);

    const boot_entries = try reopened_fs.listDirAlloc(io, std.testing.allocator, "EFI/BOOT");
    defer freeDirEntries(std.testing.allocator, boot_entries);
    try std.testing.expectEqual(@as(usize, 2), boot_entries.len);
    try std.testing.expectEqualStrings("BOOTX64.EFI", boot_entries[0].name);
    try std.testing.expectEqualStrings("grub configuration.cfg", boot_entries[1].name);

    const cfg = try reopened_fs.readFileAlloc(io, std.testing.allocator, "EFI/BOOT/grub configuration.cfg");
    defer std.testing.allocator.free(cfg);
    try std.testing.expectEqualStrings("set timeout=0\nmenuentry 'test' {}\n", cfg);

    const fallback = try reopened_fs.readFileAlloc(io, std.testing.allocator, "EFI/tools and utilities/fallback bootloader path.txt");
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("EFI/BOOT/BOOTX64.EFI\n", fallback);
}
