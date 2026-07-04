const std = @import("std");
const Io = std.Io;

const azure = @import("azure.zig");
const bootconfig = @import("bootconfig.zig");
const cosi = @import("cosi.zig");
const ext4 = @import("ext4.zig");
const fat32 = @import("fat32.zig");
const Format = @import("formats.zig").Format;
const gpt = @import("gpt.zig");
const guid = @import("guid.zig");
const image_mod = @import("image.zig");
const Image = image_mod.Image;
const layout = @import("layout.zig");
const mbr = @import("mbr.zig");
const oci = @import("oci.zig");
const iso9660 = @import("iso9660.zig");
const qcow2 = @import("qcow2.zig");
const squashfs = @import("squashfs.zig");
const verity = @import("verity.zig");

const mib: u64 = azure.one_mib;
pub const default_esp_size: u64 = 96 * mib;
const scratch_copy_chunk_size: usize = 1024 * 1024;
const nested_filesystem_probe_len: usize = 2048;
const ext4_magic_offset: usize = 1024 + 56;
const ext4_magic: u16 = 0xEF53;
const max_nested_filesystem_depth: u8 = 3;

pub const BuildImageOptions = struct {
    iso_path: []const u8,
    container_path: []const u8,
    output_path: []const u8,
    size: u64,
    generation: azure.Generation = .gen2,
    output_format: ?Format = null,
    rootfs_path_in_iso: ?[]const u8 = null,
    esp_size: u64 = default_esp_size,
    ext4_label: []const u8 = "rootfs",
    verity: bool = false,
    dry_run: bool = false,
    verbose: bool = false,
};

pub const BuildImageReport = struct {
    output_format: Format,
    generation: azure.Generation,
    architecture: bootconfig.Architecture,
    disk_size: u64,
    dry_run: bool,
    rootfs_path_in_iso: []u8,
    planned_partitions: []bootconfig.PlannedPartitionIdentity,
    verity: ?verity.Info = null,
    vhd_alignment: ?azure.FixupResult = null,
    partition_style: ?azure.PartitionStyleReport = null,

    pub fn deinit(self: *BuildImageReport, allocator: std.mem.Allocator) void {
        allocator.free(self.rootfs_path_in_iso);
        allocator.free(self.planned_partitions);
        self.* = undefined;
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    io: Io,
    options: BuildImageOptions,
) !BuildImageReport {
    const output_format = try resolveOutputFormat(options.output_format, options.output_path);
    const disk_size = if (output_format == .vhd) azure.alignSizeToMib(options.size) else options.size;

    if (options.verbose and output_format == .vhd and disk_size != options.size) {
        std.debug.print("build-image: aligned requested VHD size from {d} to {d} bytes for Azure compatibility\n", .{ options.size, disk_size });
    }

    logStep(options.verbose, "load container image");
    var container_image = try oci.load(io, allocator, options.container_path, .{});
    defer container_image.deinit();

    const architecture = inferArchitecture(container_image.config.architecture);
    const planned_partitions = try planPartitionIdentities(allocator, io, disk_size, options.generation, architecture, options.esp_size);
    var planned_partitions_owned = false;
    errdefer if (!planned_partitions_owned) allocator.free(planned_partitions);

    logStep(options.verbose, "open ISO");
    var iso_reader = try iso9660.Reader.openPath(allocator, io, options.iso_path);
    defer iso_reader.close(io);

    const rootfs_path_in_iso = try discoverRootfsPathInIso(allocator, &iso_reader, options.rootfs_path_in_iso);
    var rootfs_path_in_iso_owned = false;
    errdefer if (!rootfs_path_in_iso_owned) allocator.free(rootfs_path_in_iso);

    var report = BuildImageReport{
        .output_format = output_format,
        .generation = options.generation,
        .architecture = architecture,
        .disk_size = disk_size,
        .dry_run = options.dry_run,
        .rootfs_path_in_iso = rootfs_path_in_iso,
        .planned_partitions = planned_partitions,
    };
    // `report` now owns both allocations; disarm the standalone errdefers above
    // so `report.deinit` below is the single owner responsible for freeing them.
    planned_partitions_owned = true;
    rootfs_path_in_iso_owned = true;
    errdefer report.deinit(allocator);

    if (options.dry_run) return report;

    const rootfs_scratch_path = try std.fmt.allocPrint(allocator, "{s}.build-image-rootfs.sqsh", .{options.output_path});
    defer allocator.free(rootfs_scratch_path);
    var extracted_rootfs = false;
    defer if (extracted_rootfs) Io.Dir.cwd().deleteFile(io, rootfs_scratch_path) catch {};

    logStep(options.verbose, "extract squashfs payload from ISO");
    try extractIsoEntryToPath(allocator, io, &iso_reader, rootfs_path_in_iso, rootfs_scratch_path);
    extracted_rootfs = true;

    logStep(options.verbose, "open squashfs rootfs");
    var squash_reader = try squashfs.Reader.openPath(allocator, io, rootfs_scratch_path);
    defer squash_reader.close(io);

    const nested_scratch_prefix = try std.fmt.allocPrint(allocator, "{s}.build-image-nested", .{options.output_path});
    defer allocator.free(nested_scratch_prefix);

    logStep(options.verbose, "merge ISO, squashfs, and OCI trees");
    var source_tree = try MergedSourceTree.init(allocator, io, &iso_reader, rootfs_path_in_iso, &squash_reader, &container_image, nested_scratch_prefix);
    source_tree.bind();
    defer source_tree.deinit(allocator);

    const raw_build_path = if (output_format == .raw)
        options.output_path
    else
        try std.fmt.allocPrint(allocator, "{s}.build-image.raw", .{options.output_path});
    defer if (output_format != .raw) allocator.free(raw_build_path);
    const remove_raw_build = output_format != .raw;
    defer if (remove_raw_build) Io.Dir.cwd().deleteFile(io, raw_build_path) catch {};

    logStep(options.verbose, "create build image");
    var raw_img = try Image.create(io, raw_build_path, .raw, disk_size, .{});
    var raw_img_open = true;
    defer if (raw_img_open) raw_img.close(io);

    const disk_guid = randomGuid(io);
    switch (options.generation) {
        .gen2 => {
            logStep(options.verbose, "write GPT partition tables");
            try writeGptLayout(allocator, &raw_img, io, disk_guid, planned_partitions);
        },
        .gen1 => {
            logStep(options.verbose, "write MBR partition table");
            try writeMbrLayout(&raw_img, io, planned_partitions);
        },
    }

    if (findPartitionByRole(planned_partitions, .esp)) |esp_partition| {
        logStep(options.verbose, "format ESP as FAT32");
        try fat32.format(&raw_img, io, .{
            .partition_offset = esp_partition.planned.offset_bytes,
            .partition_len = esp_partition.planned.length_bytes,
            .volume_label = "ZVMI ESP   ".*,
        });
    }

    const root_partition = findRootPartition(planned_partitions, architecture) orelse return error.MissingRootPartition;
    const verity_layout = if (options.verity)
        try verity.splitPartition(root_partition.planned.length_bytes, ext4.default_block_size, ext4.default_block_size)
    else
        null;
    const rootfs_length = if (verity_layout) |layout_for_verity| layout_for_verity.data_size else root_partition.planned.length_bytes;

    logStep(options.verbose, "populate root ext4 filesystem");
    _ = try ext4.populate(io, raw_img.file, allocator, &source_tree.view, .{
        .offset = root_partition.planned.offset_bytes,
        .length = rootfs_length,
        .label = options.ext4_label,
    });

    if (verity_layout) |layout_for_verity| {
        logStep(options.verbose, "generate dm-verity hash tree");
        var salt: [verity.salt_size]u8 = undefined;
        Io.random(io, &salt);
        report.verity = try verity.generateAndWrite(io, raw_img.file, allocator, .{
            .device_offset = root_partition.planned.offset_bytes,
            .data_size = layout_for_verity.data_size,
            .hash_offset = layout_for_verity.hash_offset,
            .data_block_size = ext4.default_block_size,
            .hash_block_size = ext4.default_block_size,
            .salt = salt,
        });
    }

    if (options.generation == .gen1) {
        logStep(options.verbose, "install BIOS GRUB boot chain");
        try bootconfig.installBiosBoot(allocator, io, &raw_img, &source_tree.view, .{
            .planned_partitions = planned_partitions,
            .architecture = architecture,
            .verity = report.verity,
        });
    }

    if (findPartitionByRole(planned_partitions, .esp)) |esp_partition| {
        logStep(options.verbose, "populate ESP boot files");
        var esp_fs = try fat32.open(&raw_img, io, .{
            .offset = esp_partition.planned.offset_bytes,
            .length = esp_partition.planned.length_bytes,
        });
        _ = try bootconfig.populateEsp(allocator, io, &esp_fs, &source_tree.view, .{
            .planned_partitions = planned_partitions,
            .architecture = architecture,
            .verity = report.verity,
        });
    }

    raw_img.close(io);
    raw_img_open = false;

    if (output_format != .raw) {
        logStep(options.verbose, "convert raw build image to requested output format");
        try convertRawToOutput(allocator, io, raw_build_path, options.output_path, output_format, disk_size);
    }

    var final_img = try Image.openPath(io, options.output_path);
    defer final_img.close(io);

    if (output_format == .vhd) {
        logStep(options.verbose, "validate Azure VHD alignment");
        report.vhd_alignment = try azure.alignFixedVhd(&final_img, io);
    }

    if (output_format != .qcow2) {
        logStep(options.verbose, "validate partition style");
        const partition_style = try azure.checkPartitionStyle(final_img, io, allocator, options.generation);
        report.partition_style = partition_style;
        if (!partition_style.ok) return error.PartitionStyleCheckFailed;
    }

    return report;
}

fn resolveOutputFormat(explicit: ?Format, output_path: []const u8) !Format {
    const resolved = explicit orelse blk: {
        if (std.mem.lastIndexOfScalar(u8, output_path, '.')) |dot| {
            const ext = output_path[dot + 1 ..];
            if (std.ascii.eqlIgnoreCase(ext, "vhd") or std.ascii.eqlIgnoreCase(ext, "vpc")) break :blk Format.vhd;
            if (std.ascii.eqlIgnoreCase(ext, "raw") or std.ascii.eqlIgnoreCase(ext, "img")) break :blk Format.raw;
            if (std.ascii.eqlIgnoreCase(ext, "vhdx")) break :blk Format.vhdx;
            if (std.ascii.eqlIgnoreCase(ext, "qcow2")) break :blk Format.qcow2;
        }
        break :blk Format.raw;
    };

    return switch (resolved) {
        .raw, .vhd, .qcow2 => resolved,
        .vhdx => error.UnsupportedOutputFormat,
    };
}

fn inferArchitecture(raw_arch: ?[]const u8) bootconfig.Architecture {
    const arch = raw_arch orelse return .x86_64;
    if (std.ascii.eqlIgnoreCase(arch, "amd64") or std.ascii.eqlIgnoreCase(arch, "x86_64")) return .x86_64;
    if (std.ascii.eqlIgnoreCase(arch, "arm64") or std.ascii.eqlIgnoreCase(arch, "aarch64")) return .aarch64;
    return .x86_64;
}

fn planPartitionIdentities(
    allocator: std.mem.Allocator,
    io: Io,
    disk_size: u64,
    generation: azure.Generation,
    architecture: bootconfig.Architecture,
    esp_size: u64,
) ![]bootconfig.PlannedPartitionIdentity {
    return switch (generation) {
        .gen2 => try planGen2PartitionIdentities(allocator, io, disk_size, architecture, esp_size),
        .gen1 => try planGen1PartitionIdentities(allocator, io, disk_size, architecture),
    };
}

fn planGen2PartitionIdentities(
    allocator: std.mem.Allocator,
    io: Io,
    disk_size: u64,
    architecture: bootconfig.Architecture,
    esp_size: u64,
) ![]bootconfig.PlannedPartitionIdentity {
    const root_role: layout.PartitionRole = switch (architecture) {
        .x86_64 => .root_x86_64,
        .aarch64 => .root_aarch64,
    };
    const requests = [_]layout.PartitionRequest{
        .{ .name = "ESP", .role = .esp, .size = .{ .fixed = esp_size } },
        .{ .name = "root", .role = root_role, .size = .{ .percent = 100.0 } },
    };
    const planned = try layout.planLayout(allocator, disk_size, &requests, null);
    errdefer allocator.free(planned);
    const identities = try allocator.alloc(bootconfig.PlannedPartitionIdentity, planned.len);
    for (planned, 0..) |part, index| {
        identities[index] = .{ .planned = part, .unique_guid = randomGuid(io) };
    }
    allocator.free(planned);
    return identities;
}

fn planGen1PartitionIdentities(
    allocator: std.mem.Allocator,
    io: Io,
    disk_size: u64,
    architecture: bootconfig.Architecture,
) ![]bootconfig.PlannedPartitionIdentity {
    if (disk_size % gpt.sector_size != 0) return error.InvalidDiskSize;
    const root_role: layout.PartitionRole = switch (architecture) {
        .x86_64 => .root_x86_64,
        .aarch64 => .root_aarch64,
    };
    // Reserve the classic post-MBR embedding gap (sector 1 up to the first
    // 1 MiB-aligned partition) so BIOS GRUB can place `core.img` there.
    const offset_bytes = mib;
    if (disk_size <= offset_bytes + mib) return error.DiskTooSmall;
    const usable_bytes = alignDown(disk_size - offset_bytes, mib);
    if (usable_bytes == 0) return error.DiskTooSmall;
    const disk_signature = randomDiskSignature(io);

    const identities = try allocator.alloc(bootconfig.PlannedPartitionIdentity, 1);
    identities[0] = .{ .planned = .{
        .name = "root",
        .role = root_role,
        .type_guid = root_role.defaultTypeGuid(),
        .offset_bytes = offset_bytes,
        .length_bytes = usable_bytes,
    }, .unique_guid = randomGuid(io), .mbr_disk_signature = disk_signature };
    return identities;
}

fn alignDown(value: u64, alignment: u64) u64 {
    return value / alignment * alignment;
}

fn randomGuid(io: Io) guid.Guid {
    var bytes: guid.Guid = undefined;
    Io.random(io, &bytes);
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    return bytes;
}

fn randomDiskSignature(io: Io) u32 {
    var disk_signature: u32 = 0;
    while (disk_signature == 0) Io.random(io, std.mem.asBytes(&disk_signature));
    return disk_signature;
}

fn writeGptLayout(
    allocator: std.mem.Allocator,
    img: *Image,
    io: Io,
    disk_guid: guid.Guid,
    planned: []const bootconfig.PlannedPartitionIdentity,
) !void {
    const specs = try allocator.alloc(gpt.PlacedPartitionSpec, planned.len);
    defer allocator.free(specs);

    for (planned, 0..) |partition, index| {
        specs[index] = .{
            .type_guid = partition.planned.type_guid,
            .unique_guid = partition.unique_guid,
            .placement = .{
                .first_lba = partition.planned.firstLba(),
                .last_lba = partition.planned.lastLba(),
            },
            .name_utf16le = gpt.asciiName(partition.planned.name),
        };
    }
    try gpt.writeGptPlaced(img, io, disk_guid, specs);
}

fn writeMbrLayout(
    img: *Image,
    io: Io,
    planned: []const bootconfig.PlannedPartitionIdentity,
) !void {
    const root_partition = findAnyRootPartition(planned) orelse return error.MissingRootPartition;
    const first_lba = std.math.cast(u32, root_partition.planned.firstLba()) orelse return error.PartitionTooLargeForMbr;
    const sector_count = std.math.cast(u32, root_partition.planned.sizeSectors()) orelse return error.PartitionTooLargeForMbr;
    var table = mbr.singleLinuxPartitionMbr(first_lba, sector_count);
    table.disk_signature = root_partition.mbr_disk_signature orelse 0;
    const encoded = table.encode();
    try img.pwrite(io, &encoded, 0);
}

fn convertRawToOutput(
    allocator: std.mem.Allocator,
    io: Io,
    raw_path: []const u8,
    output_path: []const u8,
    output_format: Format,
    disk_size: u64,
) !void {
    var src = try Image.openPath(io, raw_path);
    defer src.close(io);

    var create_options: image_mod.CreateOptions = .{};
    if (output_format == .vhd) {
        create_options.vhd_subformat = .fixed;
    }

    var dst = try Image.create(io, output_path, output_format, disk_size, create_options);
    defer dst.close(io);

    try image_mod.copyAll(io, src, &dst, allocator);
}

fn logStep(verbose: bool, message: []const u8) void {
    if (verbose) std.debug.print("build-image: {s}\n", .{message});
}

fn discoverRootfsPathInIso(
    allocator: std.mem.Allocator,
    reader: *iso9660.Reader,
    override_path: ?[]const u8,
) ![]u8 {
    if (override_path) |path| {
        const lookup_path = if (std.mem.startsWith(u8, path, "/")) path else try std.fmt.allocPrint(allocator, "/{s}", .{path});
        defer if (lookup_path.ptr != path.ptr) allocator.free(lookup_path);
        const index = try reader.lookup(lookup_path);
        if (reader.getEntry(index).kind != .file) return error.InvalidRootfsPath;
        return allocator.dupe(u8, trimLeadingSlash(path));
    }

    var best: ?[]u8 = null;
    errdefer if (best) |path| allocator.free(path);

    var queue = std.array_list.Managed(struct { index: usize, path: []u8 }).init(allocator);
    defer {
        for (queue.items) |item| allocator.free(item.path);
        queue.deinit();
    }

    const root_entries = try reader.listDirAlloc(allocator, reader.root_index);
    defer allocator.free(root_entries);
    for (root_entries) |entry| {
        try queue.append(.{ .index = entry.index, .path = try allocator.dupe(u8, entry.name) });
    }

    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const item = queue.items[cursor];
        const node = reader.getEntry(item.index);
        if (node.kind == .directory) {
            const children = try reader.listDirAlloc(allocator, item.index);
            defer allocator.free(children);
            for (children) |child| {
                const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ item.path, child.name });
                try queue.append(.{ .index = child.index, .path = child_path });
            }
            continue;
        }
        if (!isRootfsCandidate(item.path)) continue;
        if (best == null or candidateScore(item.path) > candidateScore(best.?)) {
            if (best) |previous| allocator.free(previous);
            best = try allocator.dupe(u8, item.path);
        }
    }

    return best orelse error.RootfsNotFound;
}

fn isRootfsCandidate(path: []const u8) bool {
    const base = baseName(path);
    return std.ascii.endsWithIgnoreCase(base, ".squashfs") or
        std.ascii.endsWithIgnoreCase(base, ".sqsh") or
        std.ascii.indexOfIgnoreCase(base, "squashfs") != null or
        std.ascii.indexOfIgnoreCase(base, "rootfs") != null or
        std.ascii.endsWithIgnoreCase(base, ".img");
}

fn candidateScore(path: []const u8) u8 {
    const base = baseName(path);
    if (std.ascii.endsWithIgnoreCase(base, ".squashfs") or std.ascii.endsWithIgnoreCase(base, ".sqsh")) return 4;
    if (std.ascii.indexOfIgnoreCase(base, "squashfs") != null) return 3;
    if (std.ascii.indexOfIgnoreCase(base, "rootfs") != null) return 2;
    if (std.ascii.endsWithIgnoreCase(base, ".img")) return 1;
    return 0;
}

fn extractIsoEntryToPath(
    allocator: std.mem.Allocator,
    io: Io,
    reader: *iso9660.Reader,
    path_in_iso: []const u8,
    output_path: []const u8,
) !void {
    const lookup_path = if (std.mem.startsWith(u8, path_in_iso, "/")) path_in_iso else try std.fmt.allocPrint(allocator, "/{s}", .{path_in_iso});
    defer if (lookup_path.ptr != path_in_iso.ptr) allocator.free(lookup_path);

    const index = try reader.lookup(lookup_path);
    if (reader.getEntry(index).kind != .file) return error.InvalidRootfsPath;

    const file = try Io.Dir.cwd().createFile(io, output_path, .{ .read = true, .truncate = true });
    defer file.close(io);

    const buffer = try allocator.alloc(u8, scratch_copy_chunk_size);
    defer allocator.free(buffer);

    const entry = reader.getEntry(index);
    var offset: u64 = 0;
    while (offset < entry.size) {
        const want: usize = @intCast(@min(@as(u64, buffer.len), entry.size - offset));
        const got = try readIsoFileAt(io, reader, index, buffer[0..want], offset);
        if (got == 0) return error.UnexpectedEndOfStream;
        try file.writePositionalAll(io, buffer[0..got], offset);
        offset += got;
    }
}

fn trimLeadingSlash(path: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, path, "/")) path[1..] else path;
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn findPartitionByRole(
    planned: []const bootconfig.PlannedPartitionIdentity,
    role: layout.PartitionRole,
) ?bootconfig.PlannedPartitionIdentity {
    for (planned) |partition| {
        if (partition.planned.role == role) return partition;
    }
    return null;
}

fn findRootPartition(
    planned: []const bootconfig.PlannedPartitionIdentity,
    architecture: bootconfig.Architecture,
) ?bootconfig.PlannedPartitionIdentity {
    const preferred_role: layout.PartitionRole = switch (architecture) {
        .x86_64 => .root_x86_64,
        .aarch64 => .root_aarch64,
    };
    if (findPartitionByRole(planned, preferred_role)) |partition| return partition;
    return findAnyRootPartition(planned);
}

fn findAnyRootPartition(planned: []const bootconfig.PlannedPartitionIdentity) ?bootconfig.PlannedPartitionIdentity {
    for (planned) |partition| switch (partition.planned.role) {
        .root_x86_64, .root_aarch64, .linux_filesystem_data => return partition,
        else => {},
    };
    return null;
}

const NestedSource = union(enum) {
    ext4: struct {
        scratch_path: []u8,
        file: Io.File,
        reader: ext4.Reader,
    },
    squashfs: struct {
        scratch_path: []u8,
        reader: squashfs.Reader,
    },
};

const MergedSourceTree = struct {
    io: Io,
    entries: []MergedEntry,
    nested_sources: []*NestedSource,
    index: usize = 0,
    view: ext4.FileTreeView,

    const MergedEntry = struct {
        path: []u8,
        kind: ext4.Kind,
        mode: u16,
        uid: u32,
        gid: u32,
        size: u64,
        content: ContentSource = .none,
        xattrs: ?[]ext4.OwnedXattr = null,
    };

    const PendingEntry = struct {
        path: []u8,
        kind: ext4.Kind,
        mode: u16,
        uid: u32,
        gid: u32,
        size: u64,
        content: ContentSource = .none,
        xattrs: ?[]ext4.OwnedXattr = null,
        alive: bool = true,
    };

    const ContentSource = union(enum) {
        none,
        bytes: []const u8,
        owned_bytes: []u8,
        iso_file: struct { io: Io, reader: *iso9660.Reader, index: usize },
        squashfs_file: struct { io: Io, reader: *squashfs.Reader, index: usize },
        nested_ext4_file: struct { io: Io, reader: *ext4.Reader, path: []const u8 },
    };

    fn init(
        allocator: std.mem.Allocator,
        io: Io,
        iso_reader: *iso9660.Reader,
        rootfs_path_in_iso: []const u8,
        squash_reader: *squashfs.Reader,
        container_image: *oci.Image,
        nested_scratch_prefix: []const u8,
    ) !MergedSourceTree {
        var pending = std.array_list.Managed(PendingEntry).init(allocator);
        defer pending.deinit();

        var path_index = std.StringHashMap(usize).init(allocator);
        defer path_index.deinit();

        var nested_sources = std.array_list.Managed(*NestedSource).init(allocator);
        errdefer {
            deinitNestedSourcePointers(io, allocator, nested_sources.items);
            nested_sources.deinit();
        }
        var next_nested_scratch_id: usize = 0;

        try collectSquashfsEntries(
            allocator,
            io,
            &pending,
            &path_index,
            &nested_sources,
            nested_scratch_prefix,
            &next_nested_scratch_id,
            squash_reader,
            squash_reader.root_index,
            "",
            0,
        );
        try collectIsoEntries(allocator, io, &pending, &path_index, iso_reader, iso_reader.root_index, "", rootfs_path_in_iso);
        pruneEmptyAncestorDirectories(&pending, &path_index, rootfs_path_in_iso);
        try collectOciEntries(allocator, &pending, &path_index, container_image);
        try synthesizeMissingParents(allocator, &pending, &path_index);

        var live_count: usize = 0;
        for (pending.items) |*entry| {
            if (entry.alive) {
                live_count += 1;
            } else {
                deinitPendingEntry(allocator, entry);
            }
        }

        const entries = try allocator.alloc(MergedEntry, live_count);
        errdefer allocator.free(entries);

        var out_index: usize = 0;
        for (pending.items) |*entry| {
            if (!entry.alive) continue;
            entries[out_index] = .{
                .path = entry.path,
                .kind = entry.kind,
                .mode = entry.mode,
                .uid = entry.uid,
                .gid = entry.gid,
                .size = entry.size,
                .content = entry.content,
                .xattrs = entry.xattrs,
            };
            out_index += 1;
        }

        std.mem.sort(MergedEntry, entries, {}, struct {
            fn lessThan(_: void, a: MergedEntry, b: MergedEntry) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);

        return .{
            .io = io,
            .entries = entries,
            .nested_sources = try nested_sources.toOwnedSlice(),
            .view = .{ .ctx = undefined, .next_fn = next, .reset_fn = reset },
        };
    }

    fn deinit(self: *MergedSourceTree, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| deinitMergedEntry(allocator, entry);
        allocator.free(self.entries);
        deinitNestedSourcePointers(self.io, allocator, self.nested_sources);
        allocator.free(self.nested_sources);
        self.* = undefined;
    }

    fn bind(self: *MergedSourceTree) void {
        self.view = .{
            .ctx = self,
            .next_fn = next,
            .reset_fn = reset,
        };
    }

    fn reset(ctx: *anyopaque) void {
        const self: *MergedSourceTree = @ptrCast(@alignCast(ctx));
        self.index = 0;
    }

    fn next(ctx: *anyopaque) ext4.FileTreeView.IteratorError!?ext4.FileTreeView.Entry {
        const self: *MergedSourceTree = @ptrCast(@alignCast(ctx));
        if (self.index >= self.entries.len) return null;
        const entry = &self.entries[self.index];
        self.index += 1;
        return .{
            .path = entry.path,
            .kind = entry.kind,
            .mode = entry.mode,
            .uid = entry.uid,
            .gid = entry.gid,
            .size = entry.size,
            .content = if (entry.kind == .directory)
                null
            else
                .{ .ctx = &entry.content, .read_at_fn = readContent },
            .xattrs = ownedXattrsAsView(entry.xattrs),
        };
    }

    fn readContent(
        ctx: *const anyopaque,
        buffer: []u8,
        offset: u64,
    ) ext4.FileTreeView.ContentError!usize {
        const source: *const ContentSource = @ptrCast(@alignCast(ctx));
        return switch (source.*) {
            .none => 0,
            .bytes => |bytes| readBytes(bytes, buffer, offset),
            .owned_bytes => |bytes| readBytes(bytes, buffer, offset),
            .iso_file => |file| readIsoFileAt(file.io, file.reader, file.index, buffer, offset) catch error.ReadFailed,
            .squashfs_file => |file| readSquashfsFileAt(file.io, file.reader, file.index, buffer, offset) catch error.ReadFailed,
            .nested_ext4_file => |file| file.reader.preadPath(file.io, file.path, buffer, offset) catch error.ReadFailed,
        };
    }
};

const NestedFilesystemKind = enum {
    ext4,
    squashfs,
};

fn deinitPendingEntry(allocator: std.mem.Allocator, entry: *MergedSourceTree.PendingEntry) void {
    deinitContentSource(allocator, &entry.content);
    if (entry.xattrs) |xattrs| ext4.freeXattrs(allocator, xattrs);
    allocator.free(entry.path);
    entry.* = undefined;
}

fn deinitMergedEntry(allocator: std.mem.Allocator, entry: *MergedSourceTree.MergedEntry) void {
    deinitContentSource(allocator, &entry.content);
    if (entry.xattrs) |xattrs| ext4.freeXattrs(allocator, xattrs);
    allocator.free(entry.path);
    entry.* = undefined;
}

fn deinitContentSource(allocator: std.mem.Allocator, source: *MergedSourceTree.ContentSource) void {
    switch (source.*) {
        .owned_bytes => |bytes| allocator.free(bytes),
        else => {},
    }
    source.* = .none;
}

fn ownedXattrsAsView(xattrs: ?[]ext4.OwnedXattr) []const ext4.Xattr {
    const owned = xattrs orelse return &.{};
    return @as([*]const ext4.Xattr, @ptrCast(owned.ptr))[0..owned.len];
}

fn isValidOwnedXattrName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    inline for (.{
        "user.",
        "trusted.",
        "security.",
        "system.",
    }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) {
            const short_name = name[prefix.len..];
            return short_name.len > 0 and short_name.len <= 255;
        }
    }
    return true;
}

fn dedupeOwnedXattrs(allocator: std.mem.Allocator, xattrs: []ext4.OwnedXattr) ![]ext4.OwnedXattr {
    if (xattrs.len == 0) return xattrs;

    const keep = try allocator.alloc(bool, xattrs.len);
    defer allocator.free(keep);
    @memset(keep, true);

    var unique_count = xattrs.len;
    for (xattrs, 0..) |xattr, index| {
        if (!isValidOwnedXattrName(xattr.name)) {
            keep[index] = false;
            unique_count -= 1;
            continue;
        }
        var other: usize = 0;
        while (other < index) : (other += 1) {
            if (keep[other] and std.mem.eql(u8, xattrs[other].name, xattr.name)) {
                keep[index] = false;
                unique_count -= 1;
                break;
            }
        }
    }
    if (unique_count == xattrs.len) return xattrs;

    const deduped = try allocator.alloc(ext4.OwnedXattr, unique_count);
    var out_index: usize = 0;
    for (xattrs, keep) |xattr, should_keep| {
        if (should_keep) {
            deduped[out_index] = xattr;
            out_index += 1;
        } else {
            allocator.free(xattr.name);
            allocator.free(xattr.value);
        }
    }
    allocator.free(xattrs);
    return deduped;
}

fn deinitNestedSourcePointers(io: Io, allocator: std.mem.Allocator, nested_sources: []const *NestedSource) void {
    for (nested_sources) |source| {
        switch (source.*) {
            .ext4 => |*nested| {
                nested.reader.deinit();
                nested.file.close(io);
                Io.Dir.cwd().deleteFile(io, nested.scratch_path) catch {};
                allocator.free(nested.scratch_path);
            },
            .squashfs => |*nested| {
                nested.reader.close(io);
                Io.Dir.cwd().deleteFile(io, nested.scratch_path) catch {};
                allocator.free(nested.scratch_path);
            },
        }
        allocator.destroy(source);
    }
}

fn collectSquashfsEntries(
    allocator: std.mem.Allocator,
    io: Io,
    pending: *std.array_list.Managed(MergedSourceTree.PendingEntry),
    path_index: *std.StringHashMap(usize),
    nested_sources: *std.array_list.Managed(*NestedSource),
    nested_scratch_prefix: []const u8,
    next_nested_scratch_id: *usize,
    reader: *squashfs.Reader,
    parent_index: usize,
    prefix: []const u8,
    nesting_depth: u8,
) anyerror!void {
    const children = try reader.listDirAlloc(allocator, parent_index);
    defer allocator.free(children);

    for (children) |child| {
        const full_path = if (prefix.len == 0)
            try allocator.dupe(u8, child.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, child.name });
        errdefer allocator.free(full_path);

        const entry = reader.getEntry(child.index);
        const mode = normalizeMode(switch (entry.kind) {
            .directory => .directory,
            .file => .file,
            .symlink => .symlink,
        }, entry.mode);
        switch (entry.kind) {
            .directory => {
                try overlayEntry(allocator, pending, path_index, .{
                    .path = full_path,
                    .kind = .directory,
                    .mode = mode,
                    .uid = entry.uid,
                    .gid = entry.gid,
                    .size = 0,
                });
                try collectSquashfsEntries(
                    allocator,
                    io,
                    pending,
                    path_index,
                    nested_sources,
                    nested_scratch_prefix,
                    next_nested_scratch_id,
                    reader,
                    child.index,
                    full_path,
                    nesting_depth,
                );
            },
            .file => {
                if (try collectNestedFilesystemFromSquashfsFile(
                    allocator,
                    io,
                    pending,
                    path_index,
                    nested_sources,
                    nested_scratch_prefix,
                    next_nested_scratch_id,
                    reader,
                    child.index,
                    full_path,
                    nesting_depth,
                )) {
                    allocator.free(full_path);
                    continue;
                }
                try overlayEntry(allocator, pending, path_index, .{
                    .path = full_path,
                    .kind = .file,
                    .mode = mode,
                    .uid = entry.uid,
                    .gid = entry.gid,
                    .size = entry.size,
                    .content = .{ .squashfs_file = .{ .io = io, .reader = reader, .index = child.index } },
                });
            },
            .symlink => {
                const target = try reader.readLink(child.index);
                try overlayEntry(allocator, pending, path_index, .{
                    .path = full_path,
                    .kind = .symlink,
                    .mode = mode,
                    .uid = entry.uid,
                    .gid = entry.gid,
                    .size = target.len,
                    .content = .{ .bytes = target },
                });
            },
        }
    }
}

fn collectNestedFilesystemFromSquashfsFile(
    allocator: std.mem.Allocator,
    io: Io,
    pending: *std.array_list.Managed(MergedSourceTree.PendingEntry),
    path_index: *std.StringHashMap(usize),
    nested_sources: *std.array_list.Managed(*NestedSource),
    nested_scratch_prefix: []const u8,
    next_nested_scratch_id: *usize,
    reader: *squashfs.Reader,
    index: usize,
    path: []const u8,
    nesting_depth: u8,
) anyerror!bool {
    if (nesting_depth >= max_nested_filesystem_depth) return false;

    var probe: [nested_filesystem_probe_len]u8 = undefined;
    const got = try readSquashfsFileAt(io, reader, index, &probe, 0);
    const nested_kind = detectNestedFilesystem(probe[0..got]) orelse return false;

    switch (nested_kind) {
        .ext4 => {
            const nested_source = try openNestedExt4FromSquashfsFile(
                allocator,
                io,
                nested_sources,
                nested_scratch_prefix,
                next_nested_scratch_id,
                reader,
                index,
            );
            // LiveOS-style media use nested filesystem image files as a
            // transport wrapper. Flatten the nested image's own root into the
            // merged tree root instead of preserving the wrapper file path.
            try collectExt4Entries(allocator, io, pending, path_index, &nested_source.ext4.reader, "");
            pruneEmptyAncestorDirectories(pending, path_index, path);
        },
        .squashfs => {
            const nested_source = try openNestedSquashfsFromSquashfsFile(
                allocator,
                io,
                nested_sources,
                nested_scratch_prefix,
                next_nested_scratch_id,
                reader,
                index,
            );
            // Flatten nested squashfs roots for the same reason as ext4
            // wrappers above: callers want the effective rootfs contents.
            try collectSquashfsEntries(
                allocator,
                io,
                pending,
                path_index,
                nested_sources,
                nested_scratch_prefix,
                next_nested_scratch_id,
                &nested_source.squashfs.reader,
                nested_source.squashfs.reader.root_index,
                "",
                nesting_depth + 1,
            );
            pruneEmptyAncestorDirectories(pending, path_index, path);
        },
    }
    return true;
}

fn pruneEmptyAncestorDirectories(
    pending: *std.array_list.Managed(MergedSourceTree.PendingEntry),
    path_index: *std.StringHashMap(usize),
    path: []const u8,
) void {
    var end_opt = std.mem.lastIndexOfScalar(u8, path, '/');
    while (end_opt) |end| {
        const parent = path[0..end];
        if (path_index.get(parent)) |existing_index| {
            if (pending.items[existing_index].kind == .directory and !hasLiveDescendants(pending.items, parent)) {
                deactivateEntry(pending, path_index, existing_index);
            }
        }
        end_opt = std.mem.lastIndexOfScalar(u8, parent, '/');
    }
}

fn hasLiveDescendants(entries: []const MergedSourceTree.PendingEntry, prefix: []const u8) bool {
    for (entries) |entry| {
        if (!entry.alive) continue;
        if (isDescendantPath(entry.path, prefix)) return true;
    }
    return false;
}

fn detectNestedFilesystem(bytes: []const u8) ?NestedFilesystemKind {
    if (bytes.len >= 4 and std.mem.readInt(u32, bytes[0..4], .little) == squashfs.magic) {
        return .squashfs;
    }
    if (bytes.len >= ext4_magic_offset + 2 and std.mem.readInt(u16, bytes[ext4_magic_offset..][0..2], .little) == ext4_magic) {
        return .ext4;
    }
    return null;
}

fn openNestedExt4FromSquashfsFile(
    allocator: std.mem.Allocator,
    io: Io,
    nested_sources: *std.array_list.Managed(*NestedSource),
    nested_scratch_prefix: []const u8,
    next_nested_scratch_id: *usize,
    reader: *squashfs.Reader,
    index: usize,
) !*NestedSource {
    const scratch_path = try nextNestedScratchPath(allocator, nested_scratch_prefix, next_nested_scratch_id, "ext4");
    errdefer allocator.free(scratch_path);
    errdefer Io.Dir.cwd().deleteFile(io, scratch_path) catch {};

    try extractSquashfsEntryToPath(allocator, io, reader, index, scratch_path);

    const file = try Io.Dir.cwd().openFile(io, scratch_path, .{});
    errdefer file.close(io);

    var nested_reader = try ext4.Reader.open(io, file, allocator, .{});
    errdefer nested_reader.deinit();

    const source = try allocator.create(NestedSource);
    errdefer allocator.destroy(source);
    source.* = .{
        .ext4 = .{
            .scratch_path = scratch_path,
            .file = file,
            .reader = nested_reader,
        },
    };
    try nested_sources.append(source);
    return source;
}

fn openNestedSquashfsFromSquashfsFile(
    allocator: std.mem.Allocator,
    io: Io,
    nested_sources: *std.array_list.Managed(*NestedSource),
    nested_scratch_prefix: []const u8,
    next_nested_scratch_id: *usize,
    reader: *squashfs.Reader,
    index: usize,
) !*NestedSource {
    const scratch_path = try nextNestedScratchPath(allocator, nested_scratch_prefix, next_nested_scratch_id, "sqsh");
    errdefer allocator.free(scratch_path);
    errdefer Io.Dir.cwd().deleteFile(io, scratch_path) catch {};

    try extractSquashfsEntryToPath(allocator, io, reader, index, scratch_path);

    var nested_reader = try squashfs.Reader.openPath(allocator, io, scratch_path);
    errdefer nested_reader.close(io);

    const source = try allocator.create(NestedSource);
    errdefer allocator.destroy(source);
    source.* = .{
        .squashfs = .{
            .scratch_path = scratch_path,
            .reader = nested_reader,
        },
    };
    try nested_sources.append(source);
    return source;
}

fn nextNestedScratchPath(
    allocator: std.mem.Allocator,
    nested_scratch_prefix: []const u8,
    next_nested_scratch_id: *usize,
    extension: []const u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}-{d}.{s}",
        .{ nested_scratch_prefix, next_nested_scratch_id.*, extension },
    );
    next_nested_scratch_id.* += 1;
    return path;
}

fn collectExt4Entries(
    allocator: std.mem.Allocator,
    io: Io,
    pending: *std.array_list.Managed(MergedSourceTree.PendingEntry),
    path_index: *std.StringHashMap(usize),
    reader: *ext4.Reader,
    prefix: []const u8,
) !void {
    const children = try reader.listDir(io, allocator, prefix);
    defer ext4.freeDirEntries(allocator, children);

    for (children) |child| {
        const full_path = if (prefix.len == 0)
            try allocator.dupe(u8, child.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, child.name });
        errdefer allocator.free(full_path);

        const stat = try reader.statPath(io, full_path);
        const xattrs = try dedupeOwnedXattrs(allocator, try reader.readXattrsAlloc(io, allocator, full_path));
        errdefer ext4.freeXattrs(allocator, xattrs);

        switch (child.kind) {
            .directory => {
                try overlayEntry(allocator, pending, path_index, .{
                    .path = full_path,
                    .kind = .directory,
                    .mode = normalizeMode(.directory, stat.mode),
                    .uid = stat.uid,
                    .gid = stat.gid,
                    .size = 0,
                    .xattrs = xattrs,
                });
                try collectExt4Entries(allocator, io, pending, path_index, reader, full_path);
            },
            .file => {
                try overlayEntry(allocator, pending, path_index, .{
                    .path = full_path,
                    .kind = .file,
                    .mode = normalizeMode(.file, stat.mode),
                    .uid = stat.uid,
                    .gid = stat.gid,
                    .size = stat.size,
                    .content = .{ .nested_ext4_file = .{ .io = io, .reader = reader, .path = full_path } },
                    .xattrs = xattrs,
                });
            },
            .symlink => {
                const target = try reader.readLinkAlloc(io, allocator, full_path);
                errdefer allocator.free(target);
                try overlayEntry(allocator, pending, path_index, .{
                    .path = full_path,
                    .kind = .symlink,
                    .mode = normalizeMode(.symlink, stat.mode),
                    .uid = stat.uid,
                    .gid = stat.gid,
                    .size = target.len,
                    .content = .{ .owned_bytes = target },
                    .xattrs = xattrs,
                });
            },
        }
    }
}

fn extractSquashfsEntryToPath(
    allocator: std.mem.Allocator,
    io: Io,
    reader: *squashfs.Reader,
    index: usize,
    output_path: []const u8,
) !void {
    const entry = reader.getEntry(index);
    if (entry.kind != .file) return error.NotAFile;

    const file = try Io.Dir.cwd().createFile(io, output_path, .{ .read = true, .truncate = true });
    defer file.close(io);

    const buffer = try allocator.alloc(u8, scratch_copy_chunk_size);
    defer allocator.free(buffer);

    var offset: u64 = 0;
    while (offset < entry.size) {
        const want: usize = @intCast(@min(@as(u64, buffer.len), entry.size - offset));
        const got = try readSquashfsFileAt(io, reader, index, buffer[0..want], offset);
        if (got == 0) return error.UnexpectedEndOfStream;
        try file.writePositionalAll(io, buffer[0..got], offset);
        offset += got;
    }
}

fn collectIsoEntries(
    allocator: std.mem.Allocator,
    io: Io,
    pending: *std.array_list.Managed(MergedSourceTree.PendingEntry),
    path_index: *std.StringHashMap(usize),
    reader: *iso9660.Reader,
    parent_index: usize,
    prefix: []const u8,
    rootfs_path_in_iso: []const u8,
) !void {
    const children = try reader.listDirAlloc(allocator, parent_index);
    defer allocator.free(children);

    for (children) |child| {
        const full_path = if (prefix.len == 0)
            try allocator.dupe(u8, child.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, child.name });
        errdefer allocator.free(full_path);

        if (std.ascii.eqlIgnoreCase(full_path, rootfs_path_in_iso)) {
            allocator.free(full_path);
            continue;
        }

        const entry = reader.getEntry(child.index);
        const kind: ext4.Kind = switch (entry.kind) {
            .directory => .directory,
            .file => .file,
            .symlink => .symlink,
        };
        const mode = normalizeMode(kind, entry.mode);

        switch (entry.kind) {
            .directory => {
                try overlayEntry(allocator, pending, path_index, .{
                    .path = full_path,
                    .kind = .directory,
                    .mode = mode,
                    .uid = entry.uid,
                    .gid = entry.gid,
                    .size = 0,
                });
                try collectIsoEntries(allocator, io, pending, path_index, reader, child.index, full_path, rootfs_path_in_iso);
            },
            .file => {
                try overlayEntry(allocator, pending, path_index, .{
                    .path = full_path,
                    .kind = .file,
                    .mode = mode,
                    .uid = entry.uid,
                    .gid = entry.gid,
                    .size = entry.size,
                    .content = .{ .iso_file = .{ .io = io, .reader = reader, .index = child.index } },
                });
            },
            .symlink => {
                const target = try reader.readLink(child.index);
                try overlayEntry(allocator, pending, path_index, .{
                    .path = full_path,
                    .kind = .symlink,
                    .mode = mode,
                    .uid = entry.uid,
                    .gid = entry.gid,
                    .size = target.len,
                    .content = .{ .bytes = target },
                });
            },
        }
    }
}

fn collectOciEntries(
    allocator: std.mem.Allocator,
    pending: *std.array_list.Managed(MergedSourceTree.PendingEntry),
    path_index: *std.StringHashMap(usize),
    image: *oci.Image,
) !void {
    var iter = image.iterator();
    while (iter.next()) |entry| {
        const kind: ext4.Kind = switch (entry.kind) {
            .directory => .directory,
            .file, .hardlink => .file,
            .symlink => .symlink,
        };
        const bytes: []const u8 = switch (entry.kind) {
            .file => entry.content,
            .symlink => entry.link_name.?,
            .hardlink => blk: {
                const target = image.get(entry.link_name orelse return error.MissingHardlinkTarget) orelse return error.MissingHardlinkTarget;
                if (target.kind != .file) return error.UnsupportedHardlinkTarget;
                break :blk target.content;
            },
            .directory => "",
        };
        try overlayEntry(allocator, pending, path_index, .{
            .path = try allocator.dupe(u8, entry.path),
            .kind = kind,
            .mode = normalizeMode(kind, entry.mode),
            .uid = 0,
            .gid = 0,
            .size = switch (kind) {
                .directory => 0,
                .file, .symlink => bytes.len,
            },
            .content = switch (kind) {
                .directory => .none,
                .file, .symlink => .{ .bytes = bytes },
            },
        });
    }
}

fn overlayEntry(
    allocator: std.mem.Allocator,
    pending: *std.array_list.Managed(MergedSourceTree.PendingEntry),
    path_index: *std.StringHashMap(usize),
    entry: MergedSourceTree.PendingEntry,
) !void {
    try removeAncestorConflicts(pending, path_index, entry.path);
    if (entry.kind != .directory) removeDescendants(pending, path_index, entry.path);
    if (path_index.get(entry.path)) |existing_index| deactivateEntry(pending, path_index, existing_index);

    try pending.append(entry);
    try path_index.put(pending.items[pending.items.len - 1].path, pending.items.len - 1);
    _ = allocator;
}

fn synthesizeMissingParents(
    allocator: std.mem.Allocator,
    pending: *std.array_list.Managed(MergedSourceTree.PendingEntry),
    path_index: *std.StringHashMap(usize),
) !void {
    var cursor: usize = 0;
    while (cursor < pending.items.len) : (cursor += 1) {
        if (!pending.items[cursor].alive) continue;
        const path = pending.items[cursor].path;
        var end = std.mem.lastIndexOfScalar(u8, path, '/') orelse continue;
        while (true) {
            const parent = path[0..end];
            if (path_index.get(parent)) |existing_index| {
                if (pending.items[existing_index].kind != .directory) {
                    deactivateEntry(pending, path_index, existing_index);
                    try overlayEntry(allocator, pending, path_index, .{
                        .path = try allocator.dupe(u8, parent),
                        .kind = .directory,
                        .mode = 0o755,
                        .uid = 0,
                        .gid = 0,
                        .size = 0,
                    });
                }
            } else {
                try overlayEntry(allocator, pending, path_index, .{
                    .path = try allocator.dupe(u8, parent),
                    .kind = .directory,
                    .mode = 0o755,
                    .uid = 0,
                    .gid = 0,
                    .size = 0,
                });
            }
            end = std.mem.lastIndexOfScalar(u8, parent, '/') orelse break;
        }
    }
}

fn removeAncestorConflicts(
    pending: *std.array_list.Managed(MergedSourceTree.PendingEntry),
    path_index: *std.StringHashMap(usize),
    path: []const u8,
) !void {
    var end_opt = std.mem.lastIndexOfScalar(u8, path, '/');
    while (end_opt) |end| {
        const parent = path[0..end];
        if (path_index.get(parent)) |existing_index| {
            if (pending.items[existing_index].kind != .directory) {
                deactivateEntry(pending, path_index, existing_index);
            }
        }
        end_opt = std.mem.lastIndexOfScalar(u8, parent, '/');
    }
}

fn removeDescendants(
    pending: *std.array_list.Managed(MergedSourceTree.PendingEntry),
    path_index: *std.StringHashMap(usize),
    prefix: []const u8,
) void {
    for (pending.items, 0..) |entry, index| {
        if (!entry.alive) continue;
        if (isDescendantPath(entry.path, prefix)) deactivateEntry(pending, path_index, index);
    }
}

fn deactivateEntry(
    pending: *std.array_list.Managed(MergedSourceTree.PendingEntry),
    path_index: *std.StringHashMap(usize),
    index: usize,
) void {
    if (!pending.items[index].alive) return;
    pending.items[index].alive = false;
    if (path_index.get(pending.items[index].path)) |mapped_index| {
        if (mapped_index == index) _ = path_index.remove(pending.items[index].path);
    }
}

fn isDescendantPath(candidate: []const u8, prefix: []const u8) bool {
    return candidate.len > prefix.len and
        std.mem.startsWith(u8, candidate, prefix) and
        candidate[prefix.len] == '/';
}

fn normalizeMode(kind: ext4.Kind, raw_mode: u32) u16 {
    const mode = @as(u16, @intCast(raw_mode & 0o7777));
    if ((mode & 0o7777) != 0) return mode & 0o7777;
    return switch (kind) {
        .directory => 0o755,
        .file => 0o644,
        .symlink => 0o777,
    };
}

fn readBytes(bytes: []const u8, buffer: []u8, offset: u64) ext4.FileTreeView.ContentError!usize {
    const start = std.math.cast(usize, offset) orelse return error.UnexpectedEndOfStream;
    if (start > bytes.len) return error.UnexpectedEndOfStream;
    const count = @min(buffer.len, bytes.len - start);
    std.mem.copyForwards(u8, buffer[0..count], bytes[start .. start + count]);
    return count;
}

fn readIsoFileAt(io: Io, reader: *iso9660.Reader, index: usize, buffer: []u8, offset: u64) !usize {
    const entry = reader.getEntry(index);
    if (entry.kind != .file) return error.NotAFile;
    if (offset > entry.size) return error.UnexpectedEndOfStream;
    if (offset == entry.size or buffer.len == 0) return 0;

    const remaining_total = entry.size - offset;
    const target_len: usize = @intCast(@min(@as(u64, buffer.len), remaining_total));
    var produced: usize = 0;
    var file_offset_within_entry = offset;

    for (entry.extents) |extent| {
        if (file_offset_within_entry >= extent.size) {
            file_offset_within_entry -= extent.size;
            continue;
        }

        const extent_offset = file_offset_within_entry;
        const extent_remaining = extent.size - extent_offset;
        const take: usize = @intCast(@min(@as(u64, target_len - produced), extent_remaining));
        const absolute_offset = @as(u64, extent.lba) * reader.logical_block_size + extent_offset;
        const got = try reader.file.readPositionalAll(io, buffer[produced .. produced + take], absolute_offset);
        if (got < take) @memset(buffer[produced + got .. produced + take], 0);
        produced += take;
        file_offset_within_entry = 0;
        if (produced == target_len) break;
    }

    return produced;
}

fn readSquashfsFileAt(io: Io, reader: *squashfs.Reader, index: usize, buffer: []u8, offset: u64) !usize {
    const entry = reader.getEntry(index);
    if (entry.kind != .file) return error.NotAFile;
    if (offset > entry.size) return error.UnexpectedEndOfStream;
    return reader.readFileAt(reader.allocator, io, index, buffer, offset);
}

fn expectGen2BuiltImageContents(
    allocator: std.mem.Allocator,
    io: Io,
    img: *Image,
    report: BuildImageReport,
    image_path: []const u8,
) !void {
    const parsed = try gpt.readGpt(img.*, io, allocator);
    defer allocator.free(parsed.partitions);
    try std.testing.expectEqual(@as(usize, 2), parsed.partitions.len);
    try std.testing.expectEqualSlices(u8, &guid.esp, &parsed.partitions[0].partition_type_guid);
    try std.testing.expectEqualSlices(u8, &report.planned_partitions[1].unique_guid, &parsed.partitions[1].unique_partition_guid);

    const esp_partition = report.planned_partitions[0].planned;
    var esp = try fat32.open(img, io, .{ .offset = esp_partition.offset_bytes, .length = esp_partition.length_bytes });

    const bootx64 = try esp.readFileAlloc(io, allocator, "EFI/BOOT/BOOTX64.EFI");
    defer allocator.free(bootx64);
    try std.testing.expectEqualStrings("bootx64-from-oci", bootx64);

    const vendor_grub = try esp.readFileAlloc(io, allocator, "EFI/Acme/grub.cfg");
    defer allocator.free(vendor_grub);
    try std.testing.expect(std.mem.indexOf(u8, vendor_grub, "menuentry") != null);

    const bls_entry = try esp.readFileAlloc(io, allocator, "loader/entries/vmlinuz-test.conf");
    defer allocator.free(bls_entry);
    try std.testing.expect(std.mem.indexOf(u8, bls_entry, "root=PARTUUID=") != null);
    try std.testing.expect(std.mem.indexOf(u8, bls_entry, "/boot/vmlinuz-test") != null);

    const root_partition = report.planned_partitions[1].planned;
    const rootfs_scratch_path = try std.fmt.allocPrint(allocator, "{s}.test-rootfs.raw", .{image_path});
    defer allocator.free(rootfs_scratch_path);
    defer Io.Dir.cwd().deleteFile(io, rootfs_scratch_path) catch {};
    try extractImageRegionToPath(allocator, io, img, root_partition.offset_bytes, root_partition.length_bytes, rootfs_scratch_path);

    const rootfs_scratch = try Io.Dir.cwd().openFile(io, rootfs_scratch_path, .{});
    defer rootfs_scratch.close(io);
    var root_reader = try ext4.open(io, rootfs_scratch, allocator, .{});
    defer root_reader.deinit();

    const root_entries = try root_reader.listDir(io, allocator, "");
    defer {
        for (root_entries) |entry| allocator.free(entry.name);
        allocator.free(root_entries);
    }
    try std.testing.expect(root_entries.len >= 3);

    const squashfs_file = try root_reader.readFileAlloc(io, allocator, "etc/message.txt");
    defer allocator.free(squashfs_file);
    try std.testing.expectEqual(@as(usize, 1500), squashfs_file.len);
    try std.testing.expectEqual(@as(u8, 'A'), squashfs_file[0]);
    try std.testing.expectEqual(@as(u8, 'B'), squashfs_file[squashfs_file.len - 1]);

    const overlay_file = try root_reader.readFileAlloc(io, allocator, "app/hello.txt");
    defer allocator.free(overlay_file);
    try std.testing.expectEqualStrings("hello from layer2\n", overlay_file);

    const boot_kernel = try root_reader.readFileAlloc(io, allocator, "boot/vmlinuz-test");
    defer allocator.free(boot_kernel);
    try std.testing.expectEqualStrings("kernel-from-oci", boot_kernel);
}

fn syntheticSquashfsBlockByte(block_index: usize) u8 {
    return @as(u8, 'A') + @as(u8, @intCast(block_index % 26));
}

fn syntheticSquashfsFragmentByte(full_data_block_count: usize) u8 {
    return @as(u8, 'A') + @as(u8, @intCast(full_data_block_count % 26));
}

fn buildExpectedSyntheticSquashfsFileAlloc(allocator: std.mem.Allocator, options: squashfs.SyntheticImageOptions) ![]u8 {
    if (options.file_bytes) |bytes| return allocator.dupe(u8, bytes);

    const block_size: usize = @intCast(options.block_size);
    const full_data_block_count: usize = @intCast(options.full_data_blocks);
    const fragment_tail_size: usize = @intCast(options.fragment_tail_size);
    const total_len = full_data_block_count * block_size + fragment_tail_size;
    const bytes = try allocator.alloc(u8, total_len);

    var offset: usize = 0;
    for (0..full_data_block_count) |block_index| {
        @memset(bytes[offset..][0..block_size], syntheticSquashfsBlockByte(block_index));
        offset += block_size;
    }
    if (fragment_tail_size > 0) {
        @memset(bytes[offset..][0..fragment_tail_size], syntheticSquashfsFragmentByte(full_data_block_count));
    }
    return bytes;
}

const SyntheticNestedExt4Entry = struct {
    path: []const u8,
    kind: ext4.Kind,
    mode: u16,
    uid: u32,
    gid: u32,
    size: u64 = 0,
    bytes: []const u8 = "",
};

const SyntheticNestedExt4Tree = struct {
    entries: []const SyntheticNestedExt4Entry,
    index: usize = 0,
    view: ext4.FileTreeView,

    fn init(entries: []const SyntheticNestedExt4Entry) SyntheticNestedExt4Tree {
        return .{
            .entries = entries,
            .view = .{
                .ctx = undefined,
                .next_fn = next,
                .reset_fn = reset,
            },
        };
    }

    fn bind(self: *SyntheticNestedExt4Tree) void {
        self.view = .{
            .ctx = self,
            .next_fn = next,
            .reset_fn = reset,
        };
    }

    fn reset(ctx: *anyopaque) void {
        const self: *SyntheticNestedExt4Tree = @ptrCast(@alignCast(ctx));
        self.index = 0;
    }

    fn next(ctx: *anyopaque) ext4.FileTreeView.IteratorError!?ext4.FileTreeView.Entry {
        const self: *SyntheticNestedExt4Tree = @ptrCast(@alignCast(ctx));
        if (self.index >= self.entries.len) return null;
        const entry = self.entries[self.index];
        self.index += 1;
        return .{
            .path = entry.path,
            .kind = entry.kind,
            .mode = entry.mode,
            .uid = entry.uid,
            .gid = entry.gid,
            .size = entry.size,
            .content = if (entry.kind == .directory)
                null
            else
                .{ .ctx = &self.entries[self.index - 1], .read_at_fn = readContent },
        };
    }

    fn readContent(ctx: *const anyopaque, buffer: []u8, offset: u64) ext4.FileTreeView.ContentError!usize {
        const entry: *const SyntheticNestedExt4Entry = @ptrCast(@alignCast(ctx));
        return readBytes(entry.bytes, buffer, offset);
    }
};

fn buildSyntheticNestedExt4ImageAlloc(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
) ![]u8 {
    var tree = SyntheticNestedExt4Tree.init(&[_]SyntheticNestedExt4Entry{
        .{ .path = "bin", .kind = .symlink, .mode = 0o777, .uid = 0, .gid = 0, .size = 7, .bytes = "usr/bin" },
        .{ .path = "etc", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0 },
        .{ .path = "etc/hostname", .kind = .file, .mode = 0o644, .uid = 0, .gid = 0, .size = 12, .bytes = "nested-host\n" },
        .{ .path = "usr", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0 },
        .{ .path = "usr/bin", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0 },
        .{ .path = "usr/bin/true", .kind = .file, .mode = 0o755, .uid = 0, .gid = 0, .size = 17, .bytes = "#!/bin/sh\nexit 0\n" },
    });
    tree.bind();

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);

    _ = try ext4.populate(io, file, allocator, &tree.view, .{
        .length = 8 * 1024 * 1024,
        .label = "nested-root",
    });

    const image_size = (try file.stat(io)).size;
    const bytes = try allocator.alloc(u8, image_size);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

fn extractImageRegionToPath(
    allocator: std.mem.Allocator,
    io: Io,
    img: *Image,
    offset: u64,
    length: u64,
    output_path: []const u8,
) !void {
    const file = try Io.Dir.cwd().createFile(io, output_path, .{ .read = true, .truncate = true });
    defer file.close(io);

    const buffer = try allocator.alloc(u8, scratch_copy_chunk_size);
    defer allocator.free(buffer);

    var copied: u64 = 0;
    while (copied < length) {
        const want: usize = @intCast(@min(@as(u64, buffer.len), length - copied));
        const got = try img.pread(io, buffer[0..want], offset + copied);
        if (got != want) return error.UnexpectedEndOfStream;
        try file.writePositionalAll(io, buffer[0..want], copied);
        copied += got;
    }
}

test "build-image builds Gen2 VHD and qcow2 outputs from XZ squashfs + OCI layout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const iso_path = "test-build-image.iso";
    const oci_root = "test-build-image-oci";
    const vhd_output_path = "test-build-image.vhd";
    const qcow2_output_path = "test-build-image.qcow2";
    defer Io.Dir.cwd().deleteFile(io, iso_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, oci_root) catch {};
    defer Io.Dir.cwd().deleteFile(io, vhd_output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, qcow2_output_path) catch {};

    const squashfs_bytes = try squashfs.buildSyntheticSquashfsImage(allocator, .{ .compression = .xz });
    defer allocator.free(squashfs_bytes);
    try writeMinimalIsoWithFile(allocator, io, iso_path, "ROOT.SQUASHFS;1", squashfs_bytes);

    var fixture = try createBuildImageOciFixture(allocator, io, oci_root);
    defer fixture.deinit(allocator);

    var vhd_report = try build(allocator, io, .{
        .iso_path = iso_path,
        .container_path = oci_root,
        .output_path = vhd_output_path,
        .output_format = .vhd,
        .generation = .gen2,
        .size = 256 * mib,
    });
    defer vhd_report.deinit(allocator);

    try std.testing.expectEqual(Format.vhd, vhd_report.output_format);
    try std.testing.expect(vhd_report.partition_style.?.ok);
    try std.testing.expectEqual(@as(usize, 2), vhd_report.planned_partitions.len);

    var vhd_img = try Image.openPath(io, vhd_output_path);
    defer vhd_img.close(io);
    try expectGen2BuiltImageContents(allocator, io, &vhd_img, vhd_report, vhd_output_path);

    var qcow2_report = try build(allocator, io, .{
        .iso_path = iso_path,
        .container_path = oci_root,
        .output_path = qcow2_output_path,
        .output_format = .qcow2,
        .generation = .gen2,
        .size = 256 * mib,
    });
    defer qcow2_report.deinit(allocator);

    try std.testing.expectEqual(Format.qcow2, qcow2_report.output_format);
    try std.testing.expect(qcow2_report.partition_style == null);
    try std.testing.expectEqual(@as(usize, 2), qcow2_report.planned_partitions.len);

    const qcow2_file = try Io.Dir.cwd().openFile(io, qcow2_output_path, .{});
    defer qcow2_file.close(io);
    const qcow2_info = try qcow2.open(io, qcow2_file);
    try std.testing.expectEqual(qcow2_report.disk_size, qcow2_info.virtual_size);

    var qcow2_img = try Image.openPath(io, qcow2_output_path);
    defer qcow2_img.close(io);
    try std.testing.expectEqual(Format.qcow2, qcow2_img.format);
    try expectGen2BuiltImageContents(allocator, io, &qcow2_img, qcow2_report, qcow2_output_path);
}

test "build-image populates multi-block squashfs files into ext4 for small sequential reads" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const iso_path = "test-build-image-large-squashfs.iso";
    const oci_root = "test-build-image-large-squashfs-oci";
    const output_path = "test-build-image-large-squashfs.raw";
    defer Io.Dir.cwd().deleteFile(io, iso_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, oci_root) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};

    const squashfs_options = squashfs.SyntheticImageOptions{
        .compression = .xz,
        .block_size = 64 * 1024,
        .full_data_blocks = 48,
        .fragment_tail_size = 8192,
    };
    const squashfs_bytes = try squashfs.buildSyntheticSquashfsImage(allocator, squashfs_options);
    defer allocator.free(squashfs_bytes);
    try writeMinimalIsoWithFile(allocator, io, iso_path, "ROOT.SQUASHFS;1", squashfs_bytes);

    var fixture = try createBuildImageOciFixture(allocator, io, oci_root);
    defer fixture.deinit(allocator);

    var report = try build(allocator, io, .{
        .iso_path = iso_path,
        .container_path = oci_root,
        .output_path = output_path,
        .output_format = .raw,
        .generation = .gen2,
        .size = 256 * mib,
    });
    defer report.deinit(allocator);

    var img = try Image.openPath(io, output_path);
    defer img.close(io);

    const root_partition = report.planned_partitions[1].planned;
    const rootfs_scratch_path = try std.fmt.allocPrint(allocator, "{s}.test-rootfs.raw", .{output_path});
    defer allocator.free(rootfs_scratch_path);
    defer Io.Dir.cwd().deleteFile(io, rootfs_scratch_path) catch {};
    try extractImageRegionToPath(allocator, io, &img, root_partition.offset_bytes, root_partition.length_bytes, rootfs_scratch_path);

    const rootfs_scratch = try Io.Dir.cwd().openFile(io, rootfs_scratch_path, .{});
    defer rootfs_scratch.close(io);
    var root_reader = try ext4.open(io, rootfs_scratch, allocator, .{});
    defer root_reader.deinit();

    const contents = try root_reader.readFileAlloc(io, allocator, "etc/message.txt");
    defer allocator.free(contents);
    const expected = try buildExpectedSyntheticSquashfsFileAlloc(allocator, squashfs_options);
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, contents);
}

test "build-image unwraps nested ext4 filesystem images inside squashfs files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const iso_path = "test-build-image-nested-ext4.iso";
    const oci_root = "test-build-image-nested-ext4-oci";
    const output_path = "test-build-image-nested-ext4.raw";
    const nested_ext4_path = "test-build-image-nested-rootfs.img";
    defer Io.Dir.cwd().deleteFile(io, iso_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, oci_root) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, nested_ext4_path) catch {};

    const nested_ext4_bytes = try buildSyntheticNestedExt4ImageAlloc(allocator, io, nested_ext4_path);
    defer allocator.free(nested_ext4_bytes);

    const squashfs_bytes = try squashfs.buildSyntheticSquashfsImage(allocator, .{
        .compression = .none,
        .block_size = 1024 * 1024,
        .file_bytes = nested_ext4_bytes,
    });
    defer allocator.free(squashfs_bytes);
    try writeMinimalIsoWithFile(allocator, io, iso_path, "ROOT.SQUASHFS;1", squashfs_bytes);

    var fixture = try createBuildImageOciFixture(allocator, io, oci_root);
    defer fixture.deinit(allocator);

    var report = try build(allocator, io, .{
        .iso_path = iso_path,
        .container_path = oci_root,
        .output_path = output_path,
        .output_format = .raw,
        .generation = .gen2,
        .size = 256 * mib,
    });
    defer report.deinit(allocator);

    var img = try Image.openPath(io, output_path);
    defer img.close(io);

    const root_partition = report.planned_partitions[1].planned;
    const rootfs_scratch_path = try std.fmt.allocPrint(allocator, "{s}.test-rootfs.raw", .{output_path});
    defer allocator.free(rootfs_scratch_path);
    defer Io.Dir.cwd().deleteFile(io, rootfs_scratch_path) catch {};
    try extractImageRegionToPath(allocator, io, &img, root_partition.offset_bytes, root_partition.length_bytes, rootfs_scratch_path);

    const rootfs_scratch = try Io.Dir.cwd().openFile(io, rootfs_scratch_path, .{});
    defer rootfs_scratch.close(io);
    var root_reader = try ext4.open(io, rootfs_scratch, allocator, .{});
    defer root_reader.deinit();

    const hostname = try root_reader.readFileAlloc(io, allocator, "etc/hostname");
    defer allocator.free(hostname);
    try std.testing.expectEqualStrings("nested-host\n", hostname);

    const true_payload = try root_reader.readFileAlloc(io, allocator, "usr/bin/true");
    defer allocator.free(true_payload);
    try std.testing.expectEqualStrings("#!/bin/sh\nexit 0\n", true_payload);

    const bin_link = try root_reader.readLinkAlloc(io, allocator, "bin");
    defer allocator.free(bin_link);
    try std.testing.expectEqualStrings("usr/bin", bin_link);

    try std.testing.expectError(error.NotFound, root_reader.statPath(io, "etc/message.txt"));

    const overlay_file = try root_reader.readFileAlloc(io, allocator, "app/hello.txt");
    defer allocator.free(overlay_file);
    try std.testing.expectEqualStrings("hello from layer2\n", overlay_file);
}

test "build-image installs a Gen1 BIOS GRUB chain into the post-MBR gap" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const iso_path = "test-build-image-gen1.iso";
    const oci_root = "test-build-image-gen1-oci";
    const output_path = "test-build-image-gen1.raw";
    defer Io.Dir.cwd().deleteFile(io, iso_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, oci_root) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};

    const squashfs_bytes = try squashfs.buildSyntheticSquashfsImage(allocator, .{ .compression = .xz });
    defer allocator.free(squashfs_bytes);
    try writeMinimalIsoWithFile(allocator, io, iso_path, "ROOT.SQUASHFS;1", squashfs_bytes);

    var fixture = try createBuildImageOciFixture(allocator, io, oci_root);
    defer fixture.deinit(allocator);

    var report = try build(allocator, io, .{
        .iso_path = iso_path,
        .container_path = oci_root,
        .output_path = output_path,
        .output_format = .raw,
        .generation = .gen1,
        .size = 256 * mib,
    });
    defer report.deinit(allocator);

    try std.testing.expectEqual(Format.raw, report.output_format);
    try std.testing.expect(report.partition_style.?.ok);
    try std.testing.expectEqual(@as(usize, 1), report.planned_partitions.len);
    try std.testing.expectEqual(@as(u64, mib), report.planned_partitions[0].planned.offset_bytes);

    var img = try Image.openPath(io, output_path);
    defer img.close(io);

    var sector0: [mbr.sector_size]u8 = undefined;
    _ = try img.pread(io, &sector0, 0);
    const parsed_mbr = try mbr.Mbr.decode(&sector0);
    try std.testing.expect(parsed_mbr.entries[0].bootable);
    try std.testing.expectEqual(mbr.PartitionType.linux, parsed_mbr.entries[0].partition_type);
    try std.testing.expectEqual(@as(u32, @intCast(report.planned_partitions[0].planned.firstLba())), parsed_mbr.entries[0].first_lba);
    try std.testing.expectEqual(@as(u32, @intCast(report.planned_partitions[0].planned.sizeSectors())), parsed_mbr.entries[0].sector_count);

    var expected_boot = try allocator.dupe(u8, fixture.bios_boot_img);
    defer allocator.free(expected_boot);
    std.mem.writeInt(u64, expected_boot[0x5C..][0..8], 1, .little);
    try std.testing.expectEqualSlices(u8, expected_boot[0..0x1B8], sector0[0..0x1B8]);

    var expected_mbr = mbr.singleLinuxPartitionMbr(
        @intCast(report.planned_partitions[0].planned.firstLba()),
        @intCast(report.planned_partitions[0].planned.sizeSectors()),
    );
    expected_mbr.disk_signature = report.planned_partitions[0].mbr_disk_signature.?;
    const expected_table_tail = expected_mbr.encode();
    try std.testing.expectEqualSlices(u8, expected_table_tail[0x1B8..], sector0[0x1B8..]);

    const core_sector_count = std.math.divCeil(usize, fixture.bios_core_img.len, mbr.sector_size) catch unreachable;
    const embedded_core = try allocator.alloc(u8, core_sector_count * mbr.sector_size);
    defer allocator.free(embedded_core);
    _ = try img.pread(io, embedded_core, mbr.sector_size);

    var expected_core = try allocator.alloc(u8, embedded_core.len);
    defer allocator.free(expected_core);
    @memset(expected_core, 0);
    std.mem.copyForwards(u8, expected_core[0..fixture.bios_core_img.len], fixture.bios_core_img);
    std.mem.writeInt(u64, expected_core[500..][0..8], 2, .little);
    std.mem.writeInt(u16, expected_core[508..][0..2], @intCast(core_sector_count - 1), .little);
    std.mem.writeInt(u16, expected_core[510..][0..2], 0x820, .little);
    try std.testing.expectEqualSlices(u8, expected_core, embedded_core);
}

test "build-image can append a dm-verity tree and pass metadata through COSI output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const iso_path = "test-build-image-verity.iso";
    const oci_root = "test-build-image-verity-oci";
    const output_path = "test-build-image-verity.raw";
    const cosi_path = "test-build-image-verity.cosi";
    defer Io.Dir.cwd().deleteFile(io, iso_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, oci_root) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, cosi_path) catch {};

    const squashfs_bytes = try squashfs.buildSyntheticSquashfsImage(allocator, .{ .compression = .xz });
    defer allocator.free(squashfs_bytes);
    try writeMinimalIsoWithFile(allocator, io, iso_path, "ROOT.SQUASHFS;1", squashfs_bytes);

    var fixture = try createBuildImageOciFixture(allocator, io, oci_root);
    defer fixture.deinit(allocator);

    var report = try build(allocator, io, .{
        .iso_path = iso_path,
        .container_path = oci_root,
        .output_path = output_path,
        .output_format = .raw,
        .generation = .gen2,
        .size = 256 * mib,
        .verity = true,
    });
    defer report.deinit(allocator);

    try std.testing.expect(report.verity != null);

    var img = try Image.openPath(io, output_path);
    defer img.close(io);

    const esp_partition = report.planned_partitions[0].planned;
    var esp = try fat32.open(&img, io, .{ .offset = esp_partition.offset_bytes, .length = esp_partition.length_bytes });

    const bls_entry = try esp.readFileAlloc(io, allocator, "loader/entries/vmlinuz-test.conf");
    defer allocator.free(bls_entry);

    var root_hash_buf: [verity.digest_size * 2]u8 = undefined;
    const root_hash_text = report.verity.?.formatRootHash(&root_hash_buf);
    try std.testing.expect(std.mem.indexOf(u8, bls_entry, "root=/dev/mapper/root") != null);
    try std.testing.expect(std.mem.indexOf(u8, bls_entry, root_hash_text) != null);
    try std.testing.expect(std.mem.indexOf(u8, bls_entry, "systemd.verity_root_options=superblock=0,format=1") != null);

    try cosi.writeWithOptions(img, io, allocator, cosi_path, .{
        .root_verity = report.verity,
    });

    const cosi_file = try Io.Dir.cwd().openFile(io, cosi_path, .{});
    defer cosi_file.close(io);
    const cosi_size = (try cosi_file.stat(io)).size;
    const cosi_bytes = try allocator.alloc(u8, cosi_size);
    defer allocator.free(cosi_bytes);
    _ = try cosi_file.readPositionalAll(io, cosi_bytes, 0);

    try std.testing.expect(std.mem.indexOf(u8, cosi_bytes, "\"roothash\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cosi_bytes, root_hash_text) != null);
    try std.testing.expect(std.mem.indexOf(u8, cosi_bytes, "\"hashAlgorithm\":\"sha256\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cosi_bytes, "\"hashOffset\":") != null);
}

test "build-image can append a dm-verity tree for Gen1 builds and synthesize an MBR PARTUUID cmdline" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const iso_path = "test-build-image-verity-gen1.iso";
    const oci_root = "test-build-image-verity-gen1-oci";
    const output_path = "test-build-image-verity-gen1.raw";
    defer Io.Dir.cwd().deleteFile(io, iso_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, oci_root) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};

    const squashfs_bytes = try squashfs.buildSyntheticSquashfsImage(allocator, .{ .compression = .xz });
    defer allocator.free(squashfs_bytes);
    try writeMinimalIsoWithFile(allocator, io, iso_path, "ROOT.SQUASHFS;1", squashfs_bytes);

    var fixture = try createBuildImageOciFixture(allocator, io, oci_root);
    defer fixture.deinit(allocator);

    var report = try build(allocator, io, .{
        .iso_path = iso_path,
        .container_path = oci_root,
        .output_path = output_path,
        .output_format = .raw,
        .generation = .gen1,
        .size = 256 * mib,
        .verity = true,
    });
    defer report.deinit(allocator);

    try std.testing.expect(report.verity != null);
    try std.testing.expectEqual(@as(usize, 1), report.planned_partitions.len);
    try std.testing.expect(report.planned_partitions[0].mbr_disk_signature != null);

    var img = try Image.openPath(io, output_path);
    defer img.close(io);

    var sector0: [mbr.sector_size]u8 = undefined;
    _ = try img.pread(io, &sector0, 0);
    const parsed_mbr = try mbr.Mbr.decode(&sector0);
    try std.testing.expectEqual(report.planned_partitions[0].mbr_disk_signature.?, parsed_mbr.disk_signature);

    var partuuid_buf: [mbr.partuuid_len]u8 = undefined;
    const root_partuuid_text = mbr.formatPartuuid(&partuuid_buf, parsed_mbr.disk_signature, 1);
    const kernel_options = try bootconfig.renderKernelOptions(allocator, root_partuuid_text, "", report.verity);
    defer allocator.free(kernel_options);

    var root_hash_buf: [verity.digest_size * 2]u8 = undefined;
    const root_hash_text = report.verity.?.formatRootHash(&root_hash_buf);
    try std.testing.expect(std.mem.indexOf(u8, kernel_options, "root=/dev/mapper/root ro") != null);
    try std.testing.expect(std.mem.indexOf(u8, kernel_options, root_hash_text) != null);
    try std.testing.expect(std.mem.indexOf(u8, kernel_options, "systemd.verity_root_data=PARTUUID=") != null);
    try std.testing.expect(std.mem.indexOf(u8, kernel_options, "systemd.verity_root_hash=PARTUUID=") != null);
    try std.testing.expect(std.mem.indexOf(u8, kernel_options, root_partuuid_text) != null);
}

test "build-image reports errors cleanly (no double-free) when squashfs open fails after partition planning" {
    // Regression test for a bug found via real-world testing against the real
    // Azure Linux 4.0 ISO (https://aka.ms/azurelinux-4.0-x86_64.iso), whose
    // embedded /LiveOS/squashfs.img uses XZ-compressed metadata blocks.
    // `build()` used to register an `errdefer allocator.free(planned_partitions)`
    // / `errdefer allocator.free(rootfs_path_in_iso)` *and* a later
    // `errdefer report.deinit(allocator)` that also frees the same two slices;
    // any error past that point (like squashfs.Reader.openFile returning
    // InvalidMetadataBlock for malformed compressed metadata) triggered all of
    // them during unwinding and
    // double-freed both allocations. `std.testing.allocator` below will fail
    // this test if that regresses.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const iso_path = "test-build-image-compressed.iso";
    const oci_root = "test-build-image-compressed-oci";
    const output_path = "test-build-image-compressed.vhd";
    defer Io.Dir.cwd().deleteFile(io, iso_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, oci_root) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};

    const squashfs_bytes = try squashfs.buildSyntheticSquashfsImage(allocator, .{ .compression = .none });
    defer allocator.free(squashfs_bytes);

    // Clear the inode table's metadata-block "uncompressed" bit and relabel
    // the filesystem as XZ-compressed so squashfs.Reader attempts to
    // decompress raw metadata bytes and fails after partition planning.
    std.mem.writeInt(u16, squashfs_bytes[20..22], @intFromEnum(squashfs.Compression.xz), .little);
    const inode_table_start = std.mem.readInt(u64, squashfs_bytes[64..72], .little);
    const header_offset: usize = @intCast(inode_table_start);
    var header = std.mem.readInt(u16, squashfs_bytes[header_offset..][0..2], .little);
    header &= ~squashfs.metadata_uncompressed_bit;
    std.mem.writeInt(u16, squashfs_bytes[header_offset..][0..2], header, .little);

    try writeMinimalIsoWithFile(allocator, io, iso_path, "ROOT.SQUASHFS;1", squashfs_bytes);

    var fixture = try createBuildImageOciFixture(allocator, io, oci_root);
    defer fixture.deinit(allocator);

    try std.testing.expectError(error.InvalidMetadataBlock, build(allocator, io, .{
        .iso_path = iso_path,
        .container_path = oci_root,
        .output_path = output_path,
        .output_format = .vhd,
        .generation = .gen2,
        .size = 256 * mib,
    }));
}

const BuildImageOciFixture = struct {
    bios_boot_img: []u8,
    bios_core_img: []u8,
    layer1_tar: []u8,
    layer2_tar: []u8,
    layer1_gzip: []u8,
    layer2_gzip: []u8,
    config_json: []u8,
    config_digest: []u8,
    layer1_digest: []u8,
    layer2_digest: []u8,
    manifest_json: []u8,
    manifest_digest: []u8,
    index_json: []u8,

    fn deinit(self: *BuildImageOciFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.bios_boot_img);
        allocator.free(self.bios_core_img);
        allocator.free(self.layer1_tar);
        allocator.free(self.layer2_tar);
        allocator.free(self.layer1_gzip);
        allocator.free(self.layer2_gzip);
        allocator.free(self.config_json);
        allocator.free(self.config_digest);
        allocator.free(self.layer1_digest);
        allocator.free(self.layer2_digest);
        allocator.free(self.manifest_json);
        allocator.free(self.manifest_digest);
        allocator.free(self.index_json);
        self.* = undefined;
    }
};

fn createBuildImageOciFixture(
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
) !BuildImageOciFixture {
    try Io.Dir.cwd().createDirPath(io, root);
    var dir = try Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "blobs/sha256");

    const bios_boot_img = try makeSyntheticBiosBootImg(allocator);
    errdefer allocator.free(bios_boot_img);
    const bios_core_img = try makeSyntheticBiosCoreImg(allocator);
    errdefer allocator.free(bios_core_img);
    const layer1_tar = try buildTarArchive(allocator, &.{
        .{ .path = "boot/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "boot/vmlinuz-test", .mode = 0o644, .typeflag = '0', .content = "kernel-from-oci", .link_name = null },
        .{ .path = "boot/initramfs-test.img", .mode = 0o644, .typeflag = '0', .content = "initrd-from-oci", .link_name = null },
        .{ .path = "boot/grub2/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "boot/grub2/i386-pc/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "boot/grub2/i386-pc/boot.img", .mode = 0o644, .typeflag = '0', .content = bios_boot_img, .link_name = null },
        .{ .path = "boot/grub2/i386-pc/core.img", .mode = 0o644, .typeflag = '0', .content = bios_core_img, .link_name = null },
        .{ .path = "EFI/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "EFI/BOOT/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "EFI/BOOT/BOOTX64.EFI", .mode = 0o644, .typeflag = '0', .content = "bootx64-from-oci", .link_name = null },
        .{ .path = "EFI/Acme/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "EFI/Acme/grubx64.efi", .mode = 0o644, .typeflag = '0', .content = "grubx64-from-oci", .link_name = null },
        .{ .path = "app/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "app/hello.txt", .mode = 0o644, .typeflag = '0', .content = "hello from layer1\n", .link_name = null },
        .{ .path = "etc/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "etc/remove.txt", .mode = 0o644, .typeflag = '0', .content = "remove me\n", .link_name = null },
    });
    const layer2_tar = try buildTarArchive(allocator, &.{
        .{ .path = "etc/.wh.remove.txt", .mode = 0o000, .typeflag = '0', .content = "", .link_name = null },
        .{ .path = "app/hello.txt", .mode = 0o644, .typeflag = '0', .content = "hello from layer2\n", .link_name = null },
        .{ .path = "usr/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "usr/bin/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "usr/bin/tool", .mode = 0o755, .typeflag = '0', .content = "#!/bin/sh\n", .link_name = null },
    });

    const layer1_gzip = try gzipBytes(allocator, layer1_tar);
    const layer2_gzip = try gzipBytes(allocator, layer2_tar);
    const config_json = try std.fmt.allocPrint(
        allocator,
        "{{\"architecture\":\"amd64\",\"os\":\"linux\",\"rootfs\":{{\"type\":\"layers\",\"diff_ids\":[]}}}}",
        .{},
    );
    const config_digest = try writeBlobAndDigest(allocator, io, dir, config_json);
    const layer1_digest = try writeBlobAndDigest(allocator, io, dir, layer1_gzip);
    const layer2_digest = try writeBlobAndDigest(allocator, io, dir, layer2_gzip);
    const manifest_json = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"config\":{{\"mediaType\":\"application/vnd.oci.image.config.v1+json\",\"digest\":\"{s}\",\"size\":{d}}},\"layers\":[{{\"mediaType\":\"application/vnd.oci.image.layer.v1.tar+gzip\",\"digest\":\"{s}\",\"size\":{d}}},{{\"mediaType\":\"application/vnd.oci.image.layer.v1.tar+gzip\",\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{ config_digest, config_json.len, layer1_digest, layer1_gzip.len, layer2_digest, layer2_gzip.len },
    );
    const manifest_digest = try writeBlobAndDigest(allocator, io, dir, manifest_json);
    const index_json = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"manifests\":[{{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{ manifest_digest, manifest_json.len },
    );

    try dir.writeFile(io, .{ .sub_path = "oci-layout", .data = "{\"imageLayoutVersion\":\"1.0.0\"}" });
    try dir.writeFile(io, .{ .sub_path = "index.json", .data = index_json });

    return .{
        .bios_boot_img = bios_boot_img,
        .bios_core_img = bios_core_img,
        .layer1_tar = layer1_tar,
        .layer2_tar = layer2_tar,
        .layer1_gzip = layer1_gzip,
        .layer2_gzip = layer2_gzip,
        .config_json = config_json,
        .config_digest = config_digest,
        .layer1_digest = layer1_digest,
        .layer2_digest = layer2_digest,
        .manifest_json = manifest_json,
        .manifest_digest = manifest_digest,
        .index_json = index_json,
    };
}

const TarSpec = struct {
    path: []const u8,
    mode: u32,
    typeflag: u8,
    content: []const u8,
    link_name: ?[]const u8,
};

fn buildTarArchive(allocator: std.mem.Allocator, specs: []const TarSpec) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    errdefer out.deinit();

    for (specs) |spec| try appendTarSpec(&out, spec);
    try out.writer.splatByteAll(0, 1024);
    return out.toOwnedSlice();
}

fn appendTarSpec(out: *std.Io.Writer.Allocating, spec: TarSpec) !void {
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
    const padding = std.mem.alignForward(usize, spec.content.len, 512) - spec.content.len;
    if (padding > 0) try out.writer.splatByteAll(0, padding);
}

fn gzipBytes(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, @max(@as(usize, 64), data.len));
    errdefer out.deinit();

    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&out.writer, &history, .gzip, .default);
    try compressor.writer.writeAll(data);
    try compressor.finish();
    return out.toOwnedSlice();
}

fn writeBlobAndDigest(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const digest_string = try std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
    const blob_path = try std.fmt.allocPrint(allocator, "blobs/sha256/{s}", .{hex});
    defer allocator.free(blob_path);
    try dir.writeFile(io, .{ .sub_path = blob_path, .data = data });
    return digest_string;
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

fn makeSyntheticBiosBootImg(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try allocator.alloc(u8, mbr.sector_size);
    for (bytes, 0..) |*byte, index| byte.* = @intCast((index * 17 + 11) % 251);
    return bytes;
}

fn makeSyntheticBiosCoreImg(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try allocator.alloc(u8, 900);
    for (bytes, 0..) |*byte, index| byte.* = @intCast((index * 29 + 7) % 253);
    return bytes;
}

fn appendU16Le(list: *std.array_list.Managed(u8), value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try list.appendSlice(&buf);
}

fn appendU32Le(list: *std.array_list.Managed(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try list.appendSlice(&buf);
}

fn appendU64Le(list: *std.array_list.Managed(u8), value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    try list.appendSlice(&buf);
}

fn writeMinimalIsoWithFile(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    iso_file_name: []const u8,
    bytes: []const u8,
) !void {
    const root_lba: u32 = 20;
    const file_lba: u32 = 21;

    var image = std.array_list.Managed(u8).init(allocator);
    defer image.deinit();
    try image.resize((file_lba + @as(u32, @intCast(std.math.divCeil(u64, bytes.len, iso9660.descriptor_size) catch unreachable))) * iso9660.descriptor_size);
    @memset(image.items, 0);

    var pvd: [iso9660.descriptor_size]u8 = [_]u8{0} ** iso9660.descriptor_size;
    pvd[0] = 1;
    pvd[1..6].* = iso9660.standard_id;
    pvd[6] = 1;
    write733(pvd[80..88], @intCast(image.items.len / iso9660.descriptor_size));
    write723(pvd[128..132], iso9660.descriptor_size);
    write733(pvd[132..140], 0);
    std.mem.writeInt(u32, pvd[140..144], 19, .little);
    const root_record = makeDirectoryRecord(&.{0}, root_lba, iso9660.descriptor_size, 0x02, &.{});
    @memcpy(pvd[156 .. 156 + root_record[0]], root_record[0..root_record[0]]);
    image.items[iso9660.volume_descriptor_lba * iso9660.descriptor_size .. (iso9660.volume_descriptor_lba + 1) * iso9660.descriptor_size].* = pvd;

    var terminator: [iso9660.descriptor_size]u8 = [_]u8{0} ** iso9660.descriptor_size;
    terminator[0] = 255;
    terminator[1..6].* = iso9660.standard_id;
    terminator[6] = 1;
    image.items[(iso9660.volume_descriptor_lba + 1) * iso9660.descriptor_size .. (iso9660.volume_descriptor_lba + 2) * iso9660.descriptor_size].* = terminator;

    var path_table = std.array_list.Managed(u8).init(allocator);
    defer path_table.deinit();
    try path_table.append(1);
    try path_table.append(0);
    try appendU32Le(&path_table, root_lba);
    try appendU16Le(&path_table, 1);
    try path_table.append(0);
    try path_table.append(0);
    write733(image.items[16 * iso9660.descriptor_size + 132 .. 16 * iso9660.descriptor_size + 140], @intCast(path_table.items.len));
    @memcpy(image.items[19 * iso9660.descriptor_size ..][0..path_table.items.len], path_table.items);

    var root_dir = std.array_list.Managed(u8).init(allocator);
    defer root_dir.deinit();
    const dot = makeDirectoryRecord(&.{0}, root_lba, iso9660.descriptor_size, 0x02, &.{});
    try root_dir.appendSlice(dot[0..dot[0]]);
    const dotdot = makeDirectoryRecord(&.{1}, root_lba, iso9660.descriptor_size, 0x02, &.{});
    try root_dir.appendSlice(dotdot[0..dotdot[0]]);
    const file_record = makeDirectoryRecord(iso_file_name, file_lba, bytes.len, 0, &.{});
    try root_dir.appendSlice(file_record[0..file_record[0]]);
    @memcpy(image.items[root_lba * iso9660.descriptor_size ..][0..root_dir.items.len], root_dir.items);

    @memcpy(image.items[file_lba * iso9660.descriptor_size ..][0..bytes.len], bytes);

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, image.items, 0);
}

fn makeDirectoryRecord(
    file_identifier: []const u8,
    extent_lba: u32,
    data_length: usize,
    flags: u8,
    system_use: []const u8,
) [256]u8 {
    var record: [256]u8 = [_]u8{0} ** 256;
    const identifier_len = file_identifier.len;
    const padding: usize = if (identifier_len % 2 == 0) 1 else 0;
    const record_len = 33 + identifier_len + padding + system_use.len;
    record[0] = @intCast(record_len);
    record[1] = 0;
    write733(record[2..10], extent_lba);
    write733(record[10..18], @intCast(data_length));
    record[25] = flags;
    record[28] = 1;
    record[29] = 0;
    record[30] = 1;
    record[31] = 0;
    record[32] = @intCast(identifier_len);
    @memcpy(record[33 .. 33 + identifier_len], file_identifier);
    if (padding == 1) record[33 + identifier_len] = 0;
    @memcpy(record[33 + identifier_len + padding .. 33 + identifier_len + padding + system_use.len], system_use);
    return record;
}

fn write723(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .little);
    std.mem.writeInt(u16, bytes[2..4], value, .big);
}

fn write733(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .little);
    std.mem.writeInt(u32, bytes[4..8], value, .big);
}
