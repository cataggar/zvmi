//! Transactional mutation of an existing disk through a full raw staging
//! copy. Only existing entries in zvmi-compatible ext4 filesystems can be
//! overwritten or removed; unsupported layouts fail before the source is
//! ever opened for writing.

const std = @import("std");
const ext4 = @import("ext4.zig");
const Format = @import("formats.zig").Format;
const gpt = @import("gpt.zig");
const image_mod = @import("image.zig");
const Image = image_mod.Image;
const mbr = @import("mbr.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const PartitionSelector = union(enum) {
    /// One-based slot in the GPT partition entry array.
    gpt_index: u32,
    /// One-based slot in the four-entry MBR partition table.
    mbr_index: u8,
};

pub const FileSource = union(enum) {
    bytes: []const u8,
    host_path: []const u8,
};

pub const Operation = union(enum) {
    overwrite_file: struct {
        path: []const u8,
        source: FileSource,
    },
    remove_file: []const u8,
    remove_tree: []const u8,
};

pub const Options = struct {
    source_path: []const u8,
    output_path: []const u8,
    output_format: Format,
    root_partition: PartitionSelector,
    operations: []const Operation,
    expected_virtual_size: ?u64 = null,
    max_source_file_bytes: u64 = 1024 * 1024 * 1024,
    output_create_options: image_mod.CreateOptions = .{},
};

pub const Report = struct {
    source_format: Format,
    output_format: Format,
    virtual_size: u64,
    partition_offset: u64,
    partition_length: u64,
    flattened_backing_chain: bool,
    operation_count: usize,
};

const Partition = struct {
    offset: u64,
    length: u64,
};

pub fn edit(
    allocator: Allocator,
    io: Io,
    options: Options,
) !Report {
    if (options.source_path.len == 0 or options.output_path.len == 0) return error.InvalidPath;
    const source_path = try std.fs.path.resolve(allocator, &.{options.source_path});
    defer allocator.free(source_path);
    const output_path = try std.fs.path.resolve(allocator, &.{options.output_path});
    defer allocator.free(output_path);
    if (std.mem.eql(u8, source_path, output_path)) return error.SourceOutputConflict;
    try validateOperations(options.operations);

    var source = try Image.openPathReadOnly(io, source_path);
    var source_open = true;
    defer if (source_open) source.close(io);
    if (options.expected_virtual_size) |expected| {
        if (expected != source.virtual_size) return error.VirtualSizeMismatch;
    }
    const virtual_size = source.virtual_size;
    const source_format = source.format;
    const flattened = if (source.qcow2) |info| info.backing_depth != 0 else false;
    const partition = try selectPartition(allocator, io, source, options.root_partition);
    const partition_end = std.math.add(u64, partition.offset, partition.length) catch
        return error.InvalidPartitionBounds;
    if (partition.length == 0 or partition_end > virtual_size) return error.InvalidPartitionBounds;

    const raw_path = try std.fmt.allocPrint(allocator, "{s}.native-edit.raw", .{output_path});
    defer allocator.free(raw_path);
    const output_stage_path = try std.fmt.allocPrint(allocator, "{s}.native-edit.output", .{output_path});
    defer allocator.free(output_stage_path);
    if (std.mem.eql(u8, raw_path, source_path) or
        std.mem.eql(u8, output_stage_path, source_path))
    {
        return error.SourceOutputConflict;
    }
    var raw_exists = false;
    defer if (raw_exists) Io.Dir.cwd().deleteFile(io, raw_path) catch {};
    var output_stage_exists = false;
    defer if (output_stage_exists) Io.Dir.cwd().deleteFile(io, output_stage_path) catch {};

    var raw = try Image.createExclusive(io, raw_path, .raw, virtual_size, .{});
    raw_exists = true;
    var raw_open = true;
    defer if (raw_open) raw.close(io);
    try image_mod.copyAll(io, source, &raw, allocator);
    source.close(io);
    source_open = false;

    var editor = try ext4.Editor.open(io, raw.file, allocator, .{ .offset = partition.offset });
    var editor_open = true;
    defer if (editor_open) editor.deinit();
    const filesystem_bytes = std.math.mul(u64, editor.reader.total_blocks, editor.reader.block_size) catch
        return error.InvalidFilesystemBounds;
    const filesystem_end = std.math.add(u64, partition.offset, filesystem_bytes) catch
        return error.InvalidFilesystemBounds;
    if (filesystem_end > partition_end) return error.InvalidFilesystemBounds;

    try preflightOperations(allocator, io, &editor, options.operations, options.max_source_file_bytes);
    for (options.operations) |operation| {
        switch (operation) {
            .overwrite_file => |overwrite| {
                const content = try loadSource(allocator, io, overwrite.source, options.max_source_file_bytes);
                defer allocator.free(content);
                try editor.writeFile(io, overwrite.path, content);
            },
            .remove_file => |path| try editor.deleteFile(io, path),
            .remove_tree => |path| try editor.deleteTree(io, path),
        }
    }
    try editor.close(io);
    editor_open = false;
    raw.close(io);
    raw_open = false;

    if (options.output_format == .raw) {
        try Io.Dir.cwd().renamePreserve(raw_path, Io.Dir.cwd(), output_path, io);
        raw_exists = false;
    } else {
        var raw_source = try Image.openPathReadOnly(io, raw_path);
        defer raw_source.close(io);
        var output = try Image.createExclusive(
            io,
            output_stage_path,
            options.output_format,
            virtual_size,
            options.output_create_options,
        );
        output_stage_exists = true;
        var output_open = true;
        defer if (output_open) output.close(io);
        try image_mod.copyAll(io, raw_source, &output, allocator);
        output.close(io);
        output_open = false;
        try Io.Dir.cwd().renamePreserve(output_stage_path, Io.Dir.cwd(), output_path, io);
        output_stage_exists = false;
    }

    return .{
        .source_format = source_format,
        .output_format = options.output_format,
        .virtual_size = virtual_size,
        .partition_offset = partition.offset,
        .partition_length = partition.length,
        .flattened_backing_chain = flattened,
        .operation_count = options.operations.len,
    };
}

fn validateOperations(operations: []const Operation) !void {
    for (operations) |operation| {
        const path = switch (operation) {
            .overwrite_file => |overwrite| overwrite.path,
            .remove_file => |path| path,
            .remove_tree => |path| path,
        };
        if (!validAbsoluteImagePath(path)) return error.InvalidImagePath;
        if (operation == .overwrite_file) {
            switch (operation.overwrite_file.source) {
                .bytes => {},
                .host_path => |source| if (source.len == 0) return error.InvalidSourcePath,
            }
        }
    }
}

fn validAbsoluteImagePath(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/' or path[path.len - 1] == '/') return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..") or
            std.mem.indexOfScalar(u8, component, 0) != null)
        {
            return false;
        }
    }
    return true;
}

fn selectPartition(
    allocator: Allocator,
    io: Io,
    image: Image,
    selector: PartitionSelector,
) !Partition {
    var sector: [mbr.sector_size]u8 = undefined;
    if (try image.pread(io, &sector, 0) != sector.len) return error.UnexpectedEndOfFile;
    const boot_record = try mbr.Mbr.decode(&sector);
    const protective = for (boot_record.entries) |entry| {
        if (entry.partition_type == .gpt_protective) break true;
    } else false;

    return switch (selector) {
        .gpt_index => |one_based| blk: {
            if (!protective or one_based == 0) return error.PartitionStyleMismatch;
            const parsed = try gpt.readGpt(image, io, allocator);
            defer allocator.free(parsed.partitions);
            try validateGptLayout(parsed, image.virtual_size);
            for (parsed.partitions) |partition| {
                if (partition.table_index + 1 != one_based) continue;
                const sector_count = std.math.add(u64, partition.last_lba - partition.first_lba, 1) catch
                    return error.InvalidPartitionBounds;
                break :blk .{
                    .offset = std.math.mul(u64, partition.first_lba, mbr.sector_size) catch
                        return error.InvalidPartitionBounds,
                    .length = std.math.mul(u64, sector_count, mbr.sector_size) catch
                        return error.InvalidPartitionBounds,
                };
            }
            return error.PartitionNotFound;
        },
        .mbr_index => |one_based| blk: {
            if (protective or one_based == 0 or one_based > mbr.max_entries) {
                return error.PartitionStyleMismatch;
            }
            const partition = boot_record.entries[one_based - 1];
            if (partition.partition_type == .empty or partition.sector_count == 0) {
                return error.PartitionNotFound;
            }
            break :blk .{
                .offset = @as(u64, partition.first_lba) * mbr.sector_size,
                .length = @as(u64, partition.sector_count) * mbr.sector_size,
            };
        },
    };
}

fn validateGptLayout(parsed: gpt.ParsedGpt, virtual_size: u64) !void {
    if (virtual_size == 0 or virtual_size % gpt.sector_size != 0) {
        return error.InvalidPartitionBounds;
    }
    const total_lbas = virtual_size / gpt.sector_size;
    const header = parsed.header;
    if (header.current_lba != 1 or
        header.backup_lba != total_lbas - 1 or
        header.first_usable_lba > header.last_usable_lba or
        header.last_usable_lba >= total_lbas)
    {
        return error.InvalidPartitionBounds;
    }

    const array_bytes = std.math.mul(
        u64,
        header.num_partition_entries,
        header.partition_entry_size,
    ) catch return error.InvalidPartitionBounds;
    const array_bytes_rounded = std.math.add(
        u64,
        array_bytes,
        gpt.sector_size - 1,
    ) catch return error.InvalidPartitionBounds;
    const array_sectors = array_bytes_rounded / gpt.sector_size;
    if (array_sectors == 0) return error.InvalidPartitionBounds;
    const primary_array_last = std.math.add(
        u64,
        header.partition_entry_lba,
        array_sectors - 1,
    ) catch return error.InvalidPartitionBounds;
    if (primary_array_last >= header.first_usable_lba or
        header.partition_entry_lba <= header.current_lba or
        header.backup_lba < array_sectors)
    {
        return error.InvalidPartitionBounds;
    }
    const backup_array_first = header.backup_lba - array_sectors;
    const backup_array_last = header.backup_lba - 1;
    if (header.last_usable_lba >= backup_array_first) {
        return error.InvalidPartitionBounds;
    }

    for (parsed.partitions, 0..) |partition, index| {
        if (partition.last_lba < partition.first_lba or
            partition.first_lba < header.first_usable_lba or
            partition.last_lba > header.last_usable_lba or
            lbaRangeContains(partition.first_lba, partition.last_lba, header.current_lba) or
            lbaRangeContains(partition.first_lba, partition.last_lba, header.backup_lba) or
            lbaRangesOverlap(
                partition.first_lba,
                partition.last_lba,
                header.partition_entry_lba,
                primary_array_last,
            ) or
            lbaRangesOverlap(
                partition.first_lba,
                partition.last_lba,
                backup_array_first,
                backup_array_last,
            ))
        {
            return error.InvalidPartitionBounds;
        }
        for (parsed.partitions[index + 1 ..]) |other| {
            if (other.last_lba < other.first_lba or
                lbaRangesOverlap(
                    partition.first_lba,
                    partition.last_lba,
                    other.first_lba,
                    other.last_lba,
                ))
            {
                return error.InvalidPartitionBounds;
            }
        }
    }
}

fn lbaRangeContains(first: u64, last: u64, lba: u64) bool {
    return first <= lba and lba <= last;
}

fn lbaRangesOverlap(first_a: u64, last_a: u64, first_b: u64, last_b: u64) bool {
    return first_a <= last_b and first_b <= last_a;
}

fn preflightOperations(
    allocator: Allocator,
    io: Io,
    editor: *ext4.Editor,
    operations: []const Operation,
    max_source_file_bytes: u64,
) !void {
    for (operations) |operation| {
        switch (operation) {
            .overwrite_file => |overwrite| {
                const stat = try editor.reader.statPath(io, overwrite.path);
                if (stat.kind != .file) return error.NotRegularFile;
                switch (overwrite.source) {
                    .bytes => |bytes| if (bytes.len > max_source_file_bytes) return error.SourceFileTooLarge,
                    .host_path => |path| {
                        const file = try Io.Dir.cwd().openFile(io, path, .{});
                        defer file.close(io);
                        const source_stat = try file.stat(io);
                        if (source_stat.kind != .file) return error.SourceNotRegularFile;
                        if (source_stat.size > max_source_file_bytes) return error.SourceFileTooLarge;
                    },
                }
            },
            .remove_file => |path| {
                const stat = try editor.reader.statPath(io, path);
                if (stat.kind == .directory) return error.IsDirectory;
            },
            .remove_tree => |path| {
                const stat = try editor.reader.statPath(io, path);
                if (stat.kind != .directory) return error.NotDirectory;
            },
        }
    }
    _ = allocator;
}

fn loadSource(
    allocator: Allocator,
    io: Io,
    source: FileSource,
    max_source_file_bytes: u64,
) ![]u8 {
    return switch (source) {
        .bytes => |bytes| allocator.dupe(u8, bytes),
        .host_path => |path| Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(std.math.cast(usize, max_source_file_bytes) orelse std.math.maxInt(usize)),
        ),
    };
}

const test_disk_size: u64 = 32 * 1024 * 1024;
const test_partition_first_lba: u32 = 2048;
const test_partition_sectors: u32 = 48 * 1024;
const test_unrelated_first_lba: u32 = 54 * 1024;
const test_unrelated_sectors: u32 = 4 * 1024;

fn createTestDisk(io: Io, path: []const u8) !void {
    const root_tree = @import("root_tree.zig");
    var image = try Image.createExclusive(io, path, .raw, test_disk_size, .{});
    defer image.close(io);

    var boot_record = mbr.singleLinuxPartitionMbr(test_partition_first_lba, test_partition_sectors);
    boot_record.entries[1] = .{
        .partition_type = .linux,
        .first_lba = test_unrelated_first_lba,
        .sector_count = test_unrelated_sectors,
    };
    boot_record.disk_signature = 0xA1B2_C3D4;
    const encoded_mbr = boot_record.encode();
    try image.pwrite(io, &encoded_mbr, 0);
    try image.pwrite(
        io,
        &([_]u8{0xA5} ** 4096),
        @as(u64, test_unrelated_first_lba) * mbr.sector_size,
    );

    const spool_path = "test-preserved-image-root.spool";
    defer Io.Dir.cwd().deleteFile(io, spool_path) catch {};
    var tree = try root_tree.RootTree.init(std.testing.allocator, io, spool_path, .{});
    defer tree.deinit();
    try tree.putDirectory("etc", .{ .mode = 0o755 });
    try tree.putFileBytes("etc/config", "before\n", .{ .mode = 0o640, .uid = 12, .gid = 34 });
    try tree.putFileBytes("etc/remove", "remove\n", .{ .mode = 0o644 });
    try tree.putDirectory("var", .{ .mode = 0o755 });
    try tree.putDirectory("var/tmp", .{ .mode = 0o755 });
    try tree.putDirectory("var/tmp/drop", .{ .mode = 0o700 });
    try tree.putFileBytes("var/tmp/drop/item", "remove tree\n", .{ .mode = 0o600 });

    _ = try ext4.populate(io, image.file, std.testing.allocator, try tree.ext4View(), .{
        .offset = @as(u64, test_partition_first_lba) * mbr.sector_size,
        .length = @as(u64, test_partition_sectors) * mbr.sector_size,
        .label = "preserved-root",
        .uuid = [_]u8{0x42} ** 16,
        .timestamp = 1_735_689_600,
    });
}

fn hashTestPath(io: Io, path: []const u8) ![32]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const wanted: usize = @intCast(@min(@as(u64, buffer.len), size - offset));
        const count = try file.readPositionalAll(io, buffer[0..wanted], offset);
        if (count == 0) return error.UnexpectedEndOfFile;
        hash.update(buffer[0..count]);
        offset += count;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

test "preserved editor mutates a raw copy without changing source or unrelated bytes" {
    const io = std.testing.io;
    const source_path = "test-preserved-image-source.raw";
    const output_path = "test-preserved-image-output.raw";
    defer Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-edit.raw") catch {};
    try createTestDisk(io, source_path);
    const source_before = try hashTestPath(io, source_path);

    const operations = [_]Operation{
        .{ .overwrite_file = .{
            .path = "/etc/config",
            .source = .{ .bytes = "after\n" },
        } },
        .{ .remove_file = "/etc/remove" },
        .{ .remove_tree = "/var/tmp/drop" },
    };
    const report = try edit(std.testing.allocator, io, .{
        .source_path = source_path,
        .output_path = output_path,
        .output_format = .raw,
        .root_partition = .{ .mbr_index = 1 },
        .operations = &operations,
        .expected_virtual_size = test_disk_size,
    });
    try std.testing.expectEqual(test_disk_size, report.virtual_size);
    try std.testing.expectEqual(@as(usize, operations.len), report.operation_count);
    try std.testing.expectEqualSlices(u8, &source_before, &(try hashTestPath(io, source_path)));

    var source = try Image.openPathReadOnly(io, source_path);
    defer source.close(io);
    var output = try Image.openPathReadOnly(io, output_path);
    defer output.close(io);
    var source_unrelated: [4096]u8 = undefined;
    var output_unrelated: [4096]u8 = undefined;
    const unrelated_offset = @as(u64, test_unrelated_first_lba) * mbr.sector_size;
    _ = try source.pread(io, &source_unrelated, unrelated_offset);
    _ = try output.pread(io, &output_unrelated, unrelated_offset);
    try std.testing.expectEqualSlices(u8, &source_unrelated, &output_unrelated);
    var source_mbr: [mbr.sector_size]u8 = undefined;
    var output_mbr: [mbr.sector_size]u8 = undefined;
    _ = try source.pread(io, &source_mbr, 0);
    _ = try output.pread(io, &output_mbr, 0);
    try std.testing.expectEqualSlices(u8, &source_mbr, &output_mbr);

    var reader = try ext4.open(io, output.file, std.testing.allocator, .{
        .offset = @as(u64, test_partition_first_lba) * mbr.sector_size,
    });
    defer reader.deinit();
    const config = try reader.readFileAlloc(io, std.testing.allocator, "/etc/config");
    defer std.testing.allocator.free(config);
    try std.testing.expectEqualStrings("after\n", config);
    const stat = try reader.statPath(io, "/etc/config");
    try std.testing.expectEqual(@as(u16, 0o640), stat.mode);
    try std.testing.expectEqual(@as(u32, 12), stat.uid);
    try std.testing.expectEqual(@as(u32, 34), stat.gid);
    try std.testing.expectError(error.NotFound, reader.statPath(io, "/etc/remove"));
    try std.testing.expectError(error.NotFound, reader.statPath(io, "/var/tmp/drop"));

    var source_reader = try ext4.open(io, source.file, std.testing.allocator, .{
        .offset = @as(u64, test_partition_first_lba) * mbr.sector_size,
    });
    defer source_reader.deinit();
    const original = try source_reader.readFileAlloc(io, std.testing.allocator, "/etc/config");
    defer std.testing.allocator.free(original);
    try std.testing.expectEqualStrings("before\n", original);
}

test "preserved editor publishes standalone qcow2 and cleans failed staging" {
    const io = std.testing.io;
    const raw_path = "test-preserved-image-base.raw";
    const base_path = "test-preserved-image-base.qcow2";
    const source_path = "test-preserved-image-overlay.qcow2";
    const output_path = "test-preserved-image-result.qcow2";
    const failed_path = "test-preserved-image-failed.qcow2";
    defer Io.Dir.cwd().deleteFile(io, raw_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, base_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-edit.raw") catch {};
    defer Io.Dir.cwd().deleteFile(io, failed_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, failed_path ++ ".native-edit.raw") catch {};
    try createTestDisk(io, raw_path);
    {
        var raw = try Image.openPathReadOnly(io, raw_path);
        defer raw.close(io);
        var qcow = try Image.createExclusive(io, base_path, .qcow2, test_disk_size, .{});
        defer qcow.close(io);
        try image_mod.copyAll(io, raw, &qcow, std.testing.allocator);
    }
    {
        var overlay = try Image.createExclusive(io, source_path, .qcow2, test_disk_size, .{});
        overlay.close(io);
        const file = try Io.Dir.cwd().openFile(io, source_path, .{ .mode = .read_write });
        defer file.close(io);
        var header: [104]u8 = undefined;
        if (try file.readPositionalAll(io, &header, 0) != header.len) {
            return error.UnexpectedEndOfFile;
        }
        const backing_offset = std.mem.readInt(u32, header[100..104], .big);
        std.mem.writeInt(u64, header[8..16], backing_offset, .big);
        std.mem.writeInt(u32, header[16..20], base_path.len, .big);
        try file.writePositionalAll(io, &header, 0);
        try file.writePositionalAll(io, base_path, backing_offset);
    }
    const source_before = try hashTestPath(io, source_path);
    const base_before = try hashTestPath(io, base_path);

    const operation = [_]Operation{.{ .overwrite_file = .{
        .path = "/etc/config",
        .source = .{ .bytes = "qcow2\n" },
    } }};
    const report = try edit(std.testing.allocator, io, .{
        .source_path = source_path,
        .output_path = output_path,
        .output_format = .qcow2,
        .root_partition = .{ .mbr_index = 1 },
        .operations = &operation,
    });
    try std.testing.expect(report.flattened_backing_chain);
    try std.testing.expectEqualSlices(u8, &source_before, &(try hashTestPath(io, source_path)));
    try std.testing.expectEqualSlices(u8, &base_before, &(try hashTestPath(io, base_path)));
    var output = try Image.openPathReadOnly(io, output_path);
    defer output.close(io);
    try std.testing.expectEqual(Format.qcow2, output.format);
    try std.testing.expectEqual(@as(u8, 0), output.qcow2.?.backing_depth);
    try std.testing.expectEqual(@as(u16, 0), output.qcow2.?.backing_file_len);

    const invalid = [_]Operation{.{ .overwrite_file = .{
        .path = "/etc/missing",
        .source = .{ .bytes = "nope" },
    } }};
    try std.testing.expectError(error.NotFound, edit(std.testing.allocator, io, .{
        .source_path = source_path,
        .output_path = failed_path,
        .output_format = .qcow2,
        .root_partition = .{ .mbr_index = 1 },
        .operations = &invalid,
    }));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, failed_path, .{}));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, failed_path ++ ".native-edit.raw", .{}));
}

test "preserved editor does not replace an existing output" {
    const io = std.testing.io;
    const source_path = "test-preserved-existing-source.raw";
    const output_path = "test-preserved-existing-output.raw";
    defer Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-edit.raw") catch {};
    try createTestDisk(io, source_path);
    {
        const output = try Io.Dir.cwd().createFile(io, output_path, .{});
        defer output.close(io);
        try output.writePositionalAll(io, "preserve-me", 0);
    }

    try std.testing.expectError(error.PathAlreadyExists, edit(std.testing.allocator, io, .{
        .source_path = source_path,
        .output_path = output_path,
        .output_format = .raw,
        .root_partition = .{ .mbr_index = 1 },
        .operations = &.{},
    }));

    const output = try Io.Dir.cwd().openFile(io, output_path, .{});
    defer output.close(io);
    var bytes: ["preserve-me".len]u8 = undefined;
    _ = try output.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings("preserve-me", &bytes);
    try std.testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(io, output_path ++ ".native-edit.raw", .{}),
    );
}

test "preserved editor rejects reversed GPT partition extents" {
    const io = std.testing.io;
    const source_path = "test-preserved-reversed-gpt.raw";
    const output_path = "test-preserved-reversed-gpt-output.raw";
    defer Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-edit.raw") catch {};

    const disk_size: u64 = 2 * 1024 * 1024;
    {
        var image = try Image.createExclusive(io, source_path, .raw, disk_size, .{});
        defer image.close(io);
        const protective = mbr.protectiveMbr(disk_size / mbr.sector_size).encode();
        try image.pwrite(io, &protective, 0);

        var entries = [_]u8{0} ** (gpt.default_num_partition_entries * gpt.partition_entry_size);
        entries[0..16].* = [_]u8{1} ** 16;
        entries[16..32].* = [_]u8{2} ** 16;
        std.mem.writeInt(u64, entries[32..40], 100, .little);
        std.mem.writeInt(u64, entries[40..48], 99, .little);
        const header = (gpt.Header{
            .current_lba = 1,
            .backup_lba = disk_size / gpt.sector_size - 1,
            .first_usable_lba = 34,
            .last_usable_lba = disk_size / gpt.sector_size - 34,
            .disk_guid = [_]u8{3} ** 16,
            .partition_entry_lba = 2,
            .partition_array_crc32 = std.hash.crc.Crc32.hash(&entries),
        }).encode();
        try image.pwrite(io, &header, gpt.sector_size);
        try image.pwrite(io, &entries, gpt.sector_size * 2);
    }

    try std.testing.expectError(error.InvalidPartitionBounds, edit(std.testing.allocator, io, .{
        .source_path = source_path,
        .output_path = output_path,
        .output_format = .raw,
        .root_partition = .{ .gpt_index = 1 },
        .operations = &.{},
    }));
}

test "preserved editor rejects overlapping GPT partitions and metadata" {
    const disk_size: u64 = 2 * 1024 * 1024;
    const total_lbas = disk_size / gpt.sector_size;
    const header = gpt.Header{
        .current_lba = 1,
        .backup_lba = total_lbas - 1,
        .first_usable_lba = 34,
        .last_usable_lba = total_lbas - 34,
        .disk_guid = [_]u8{3} ** 16,
        .partition_entry_lba = 2,
        .partition_array_crc32 = 0,
    };

    var overlapping = [_]gpt.PartitionEntry{
        .{ .table_index = 0, .first_lba = 100, .last_lba = 200 },
        .{ .table_index = 1, .first_lba = 150, .last_lba = 250 },
    };
    try std.testing.expectError(error.InvalidPartitionBounds, validateGptLayout(.{
        .header = header,
        .partitions = &overlapping,
    }, disk_size));

    var metadata_overlap = [_]gpt.PartitionEntry{
        .{ .table_index = 0, .first_lba = 2, .last_lba = 40 },
    };
    var permissive_header = header;
    permissive_header.first_usable_lba = 1;
    try std.testing.expectError(error.InvalidPartitionBounds, validateGptLayout(.{
        .header = permissive_header,
        .partitions = &metadata_overlap,
    }, disk_size));
}
