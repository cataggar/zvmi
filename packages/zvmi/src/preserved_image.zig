//! Transactional mutation/rebuild of an existing disk through a full raw
//! staging copy. `edit` changes only existing paths; `rebuild` strictly
//! imports the narrow writer-compatible ext4 profile before applying pure OS
//! customization. `inspectRebuild` performs the same source preflight without
//! creating any files. Sources are always read-only.

const std = @import("std");
const ext4 = @import("ext4.zig");
const Format = @import("formats.zig").Format;
const gpt = @import("gpt.zig");
const guid = @import("guid.zig");
const image_mod = @import("image.zig");
const Image = image_mod.Image;
const mbr = @import("mbr.zig");
const os_customization = @import("os_customization.zig");
const root_tree = @import("root_tree.zig");

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

/// Options for a rootless, full-tree rebuild of the deliberately narrow
/// `zvmi_ext4_v1` source profile. `source_date_epoch` controls pure OS
/// customization data; the ext4 inode/superblock timestamp is validated and
/// preserved from the source.
pub const RebuildOptions = struct {
    source_path: []const u8,
    output_path: []const u8,
    expected_source_format: ?Format = null,
    output_format: Format,
    root_partition: PartitionSelector,
    existing_operations: []const Operation = &.{},
    customization: os_customization.OsCustomization = .{},
    generalization: os_customization.GeneralizationPolicy = .none,
    source_date_epoch: u64,
    limits: root_tree.Limits = .{},
    max_scan_metadata_bytes: usize = 256 * 1024 * 1024,
    expected_virtual_size: ?u64 = null,
    max_source_file_bytes: u64 = 1024 * 1024 * 1024,
    output_create_options: image_mod.CreateOptions = .{},
};

pub const RebuildReport = struct {
    source_format: Format,
    output_format: Format,
    virtual_size: u64,
    partition_offset: u64,
    partition_length: u64,
    flattened_backing_chain: bool,
    strict_profile: ext4.StrictProfile,
    ext4_uuid: [16]u8,
    /// Exact preserved ext4 volume-name field.
    ext4_label: [16]u8,
    ext4_block_size: u32,
    filesystem_length: u64,
    ext4_global_timestamp: u32,
    source_manifest_sha256: [32]u8,
    final_manifest_sha256: [32]u8,
    /// RootTree node counts exclude its implicit root directory.
    imported_node_count: usize,
    final_node_count: usize,
    existing_operation_count: usize,
    os_customization_count: usize,
    generalization_count: usize,
};

/// Plain, allocation-independent result of `inspectRebuild`. Inspection
/// validates the complete source/profile contract without creating files.
pub const RebuildInspection = struct {
    source_format: Format,
    virtual_size: u64,
    partition_offset: u64,
    partition_length: u64,
    flattened_backing_chain: bool,
    strict_profile: ext4.StrictProfile,
    ext4_uuid: [16]u8,
    ext4_label: [16]u8,
    ext4_block_size: u32,
    filesystem_length: u64,
    ext4_global_timestamp: u32,
    /// Excludes the implicit root directory.
    imported_node_count: usize,
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

    try publishRawStaging(
        allocator,
        io,
        raw_path,
        output_stage_path,
        output_path,
        options.output_format,
        virtual_size,
        options.output_create_options,
        &raw_exists,
        &output_stage_exists,
    );

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

/// Performs the complete rebuild source preflight using read-only handles.
/// No output, staging, spool, workspace, or other file is created.
pub fn inspectRebuild(
    allocator: Allocator,
    io: Io,
    options: RebuildOptions,
) !RebuildInspection {
    if (options.source_path.len == 0 or options.output_path.len == 0) return error.InvalidPath;
    const source_path = try std.fs.path.resolve(allocator, &.{options.source_path});
    defer allocator.free(source_path);
    const output_path = try std.fs.path.resolve(allocator, &.{options.output_path});
    defer allocator.free(output_path);
    if (std.mem.eql(u8, source_path, output_path)) return error.SourceOutputConflict;
    try validateOperations(options.existing_operations);

    var source = try Image.openPathReadOnly(io, source_path);
    defer source.close(io);
    if (options.expected_source_format) |expected| {
        if (source.format != expected) return error.SourceFormatMismatch;
    }
    if (options.expected_virtual_size) |expected| {
        if (expected != source.virtual_size) return error.VirtualSizeMismatch;
    }
    const partition = try selectRebuildPartition(allocator, io, source, options.root_partition);
    const partition_end = std.math.add(u64, partition.offset, partition.length) catch
        return error.InvalidPartitionBounds;
    if (partition.length == 0 or partition_end > source.virtual_size) {
        return error.InvalidPartitionBounds;
    }

    var reader = try ext4.openReadOnlySource(
        io,
        source.file,
        .{ .ctx = &source, .read_at_fn = imageReadAt },
        allocator,
        .{ .offset = partition.offset },
    );
    defer reader.deinit();
    var scanned = try ext4.scanWriterCompatible(&reader, io, allocator, strictScanOptions(
        options,
        partition.length,
    ));
    defer scanned.deinit();
    try preflightScannedOperations(scanned.fileTreeView(), options.existing_operations);

    try preflightReadOnlyDependencies(
        io,
        options.existing_operations,
        options.customization,
        options.max_source_file_bytes,
    );

    const raw_path = try std.fmt.allocPrint(allocator, "{s}.native-rebuild.raw", .{output_path});
    defer allocator.free(raw_path);
    const output_stage_path = try std.fmt.allocPrint(
        allocator,
        "{s}.native-rebuild.output",
        .{output_path},
    );
    defer allocator.free(output_stage_path);
    const spool_path = try std.fmt.allocPrint(
        allocator,
        "{s}.native-rebuild.spool",
        .{output_path},
    );
    defer allocator.free(spool_path);
    try validateRebuildArtifactPaths(
        allocator,
        source,
        source_path,
        output_path,
        raw_path,
        output_stage_path,
        spool_path,
        options.existing_operations,
        options.customization,
    );
    var validation_tree = root_tree.RootTree.initMemory(allocator, io, options.limits);
    defer validation_tree.deinit();
    try validation_tree.importExt4ViewBorrowed(scanned.fileTreeView());
    try preflightTreeOperations(&validation_tree, options.existing_operations);
    try applyTreeOperations(
        io,
        &validation_tree,
        options.existing_operations,
        options.max_source_file_bytes,
    );
    try os_customization.apply(
        allocator,
        &validation_tree,
        options.customization,
        options.source_date_epoch,
    );
    try os_customization.generalize(
        allocator,
        &validation_tree,
        options.generalization,
    );
    _ = try ext4.preflightPopulate(
        allocator,
        try validation_tree.ext4View(),
        .{
            .offset = partition.offset,
            .length = scanned.identity.filesystem_length,
            .block_size = scanned.identity.block_size,
            .label = &scanned.identity.label,
            .uuid = scanned.identity.uuid,
            .timestamp = scanned.identity.global_timestamp,
        },
    );

    return .{
        .source_format = source.format,
        .virtual_size = source.virtual_size,
        .partition_offset = partition.offset,
        .partition_length = partition.length,
        .flattened_backing_chain = if (source.qcow2) |info| info.backing_depth != 0 else false,
        .strict_profile = scanned.identity.profile,
        .ext4_uuid = scanned.identity.uuid,
        .ext4_label = scanned.identity.label,
        .ext4_block_size = scanned.identity.block_size,
        .filesystem_length = scanned.identity.filesystem_length,
        .ext4_global_timestamp = scanned.identity.global_timestamp,
        .imported_node_count = scanned.nodeCount(),
    };
}

/// Strictly imports, customizes, and rebuilds a writer-compatible ext4 tree.
/// Source validation (including the complete allocated inode/block graph)
/// finishes before any spool, raw staging, conversion staging, or output file
/// is created.
pub fn rebuild(
    allocator: Allocator,
    io: Io,
    options: RebuildOptions,
) !RebuildReport {
    if (options.source_path.len == 0 or options.output_path.len == 0) return error.InvalidPath;
    const source_path = try std.fs.path.resolve(allocator, &.{options.source_path});
    defer allocator.free(source_path);
    const output_path = try std.fs.path.resolve(allocator, &.{options.output_path});
    defer allocator.free(output_path);
    if (std.mem.eql(u8, source_path, output_path)) return error.SourceOutputConflict;
    try validateOperations(options.existing_operations);

    var source = try Image.openPathReadOnly(io, source_path);
    var source_open = true;
    defer if (source_open) source.close(io);
    if (options.expected_source_format) |expected| {
        if (source.format != expected) return error.SourceFormatMismatch;
    }
    if (options.expected_virtual_size) |expected| {
        if (expected != source.virtual_size) return error.VirtualSizeMismatch;
    }
    const virtual_size = source.virtual_size;
    const source_format = source.format;
    const flattened = if (source.qcow2) |info| info.backing_depth != 0 else false;
    const partition = try selectRebuildPartition(allocator, io, source, options.root_partition);
    const partition_end = std.math.add(u64, partition.offset, partition.length) catch
        return error.InvalidPartitionBounds;
    if (partition.length == 0 or partition_end > virtual_size) {
        return error.InvalidPartitionBounds;
    }

    var reader = try ext4.openReadOnlySource(
        io,
        source.file,
        .{ .ctx = &source, .read_at_fn = imageReadAt },
        allocator,
        .{ .offset = partition.offset },
    );
    defer reader.deinit();
    var scanned = try ext4.scanWriterCompatible(
        &reader,
        io,
        allocator,
        strictScanOptions(options, partition.length),
    );
    defer scanned.deinit();

    try preflightReadOnlyDependencies(
        io,
        options.existing_operations,
        options.customization,
        options.max_source_file_bytes,
    );

    const raw_path = try std.fmt.allocPrint(allocator, "{s}.native-rebuild.raw", .{output_path});
    defer allocator.free(raw_path);
    const output_stage_path = try std.fmt.allocPrint(
        allocator,
        "{s}.native-rebuild.output",
        .{output_path},
    );
    defer allocator.free(output_stage_path);
    const spool_path = try std.fmt.allocPrint(
        allocator,
        "{s}.native-rebuild.spool",
        .{output_path},
    );
    defer allocator.free(spool_path);
    try validateRebuildArtifactPaths(
        allocator,
        source,
        source_path,
        output_path,
        raw_path,
        output_stage_path,
        spool_path,
        options.existing_operations,
        options.customization,
    );

    var tree = try root_tree.RootTree.init(allocator, io, spool_path, options.limits);
    defer tree.deinit();
    try tree.importExt4View(scanned.fileTreeView());
    const imported_node_count = tree.nodeCount();
    if (imported_node_count != scanned.nodeCount()) return error.ImportedNodeCountMismatch;
    const source_manifest = try tree.manifestDigest();

    try preflightTreeOperations(&tree, options.existing_operations);
    try applyTreeOperations(
        io,
        &tree,
        options.existing_operations,
        options.max_source_file_bytes,
    );
    try os_customization.apply(
        allocator,
        &tree,
        options.customization,
        options.source_date_epoch,
    );
    try os_customization.generalize(allocator, &tree, options.generalization);

    const final_manifest = try tree.manifestDigest();
    const final_node_count = tree.nodeCount();
    const final_view = try tree.ext4View();

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

    try zeroFileRange(io, raw.file, partition.offset, partition.length);
    _ = try ext4.populate(io, raw.file, allocator, final_view, .{
        .offset = partition.offset,
        .length = scanned.identity.filesystem_length,
        .block_size = scanned.identity.block_size,
        .label = &scanned.identity.label,
        .uuid = scanned.identity.uuid,
        .timestamp = scanned.identity.global_timestamp,
    });
    raw.close(io);
    raw_open = false;

    try publishRawStaging(
        allocator,
        io,
        raw_path,
        output_stage_path,
        output_path,
        options.output_format,
        virtual_size,
        options.output_create_options,
        &raw_exists,
        &output_stage_exists,
    );

    return .{
        .source_format = source_format,
        .output_format = options.output_format,
        .virtual_size = virtual_size,
        .partition_offset = partition.offset,
        .partition_length = partition.length,
        .flattened_backing_chain = flattened,
        .strict_profile = scanned.identity.profile,
        .ext4_uuid = scanned.identity.uuid,
        .ext4_label = scanned.identity.label,
        .ext4_block_size = scanned.identity.block_size,
        .filesystem_length = scanned.identity.filesystem_length,
        .ext4_global_timestamp = scanned.identity.global_timestamp,
        .source_manifest_sha256 = source_manifest,
        .final_manifest_sha256 = final_manifest,
        .imported_node_count = imported_node_count,
        .final_node_count = final_node_count,
        .existing_operation_count = options.existing_operations.len,
        .os_customization_count = customizationCount(options.customization),
        .generalization_count = generalizationCount(options.generalization),
    };
}

fn strictScanOptions(options: RebuildOptions, partition_length: u64) ext4.StrictScanOptions {
    return .{
        .expected_length = partition_length,
        .max_nodes = options.limits.max_nodes,
        .max_path_bytes = options.limits.max_path_bytes,
        .max_component_bytes = options.limits.max_component_bytes,
        .max_file_bytes = options.limits.max_file_bytes,
        .max_total_bytes = options.limits.max_total_bytes,
        .max_xattrs_per_node = options.limits.max_xattrs_per_node,
        .max_xattr_bytes_per_node = options.limits.max_xattr_bytes_per_node,
        .max_scan_metadata_bytes = options.max_scan_metadata_bytes,
    };
}

fn imageReadAt(
    ctx: *const anyopaque,
    io: Io,
    buffer: []u8,
    offset: u64,
) anyerror!usize {
    const image: *const Image = @ptrCast(@alignCast(ctx));
    return image.pread(io, buffer, offset);
}

fn publishRawStaging(
    allocator: Allocator,
    io: Io,
    raw_path: []const u8,
    output_stage_path: []const u8,
    output_path: []const u8,
    output_format: Format,
    virtual_size: u64,
    output_create_options: image_mod.CreateOptions,
    raw_exists: *bool,
    output_stage_exists: *bool,
) !void {
    if (output_format == .raw) {
        try Io.Dir.cwd().renamePreserve(raw_path, Io.Dir.cwd(), output_path, io);
        raw_exists.* = false;
        return;
    }

    var raw_source = try Image.openPathReadOnly(io, raw_path);
    defer raw_source.close(io);
    var output = try Image.createExclusive(
        io,
        output_stage_path,
        output_format,
        virtual_size,
        output_create_options,
    );
    output_stage_exists.* = true;
    var output_open = true;
    defer if (output_open) output.close(io);
    try image_mod.copyAll(io, raw_source, &output, allocator);
    output.close(io);
    output_open = false;
    try Io.Dir.cwd().renamePreserve(output_stage_path, Io.Dir.cwd(), output_path, io);
    output_stage_exists.* = false;
}

fn zeroFileRange(io: Io, file: Io.File, offset: u64, length: u64) !void {
    const zeroes: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024);
    var written: u64 = 0;
    while (written < length) {
        const chunk: usize = @intCast(@min(@as(u64, zeroes.len), length - written));
        try file.writePositionalAll(io, zeroes[0..chunk], offset + written);
        written += chunk;
    }
}

fn preflightReadOnlyDependencies(
    io: Io,
    operations: []const Operation,
    customization: os_customization.OsCustomization,
    max_source_file_bytes: u64,
) !void {
    for (operations) |operation| switch (operation) {
        .overwrite_file => |overwrite| switch (overwrite.source) {
            .bytes => |bytes| if (bytes.len > max_source_file_bytes) {
                return error.SourceFileTooLarge;
            },
            .host_path => |path| try preflightHostFile(io, path, max_source_file_bytes),
        },
        .remove_file, .remove_tree => {},
    };
    for (customization.filesystem) |operation| switch (operation) {
        .put_file => |file| switch (file.source) {
            .inline_bytes => |bytes| if (bytes.len > max_source_file_bytes) {
                return error.SourceFileTooLarge;
            },
            .host_path => |path| try preflightHostFile(io, path, max_source_file_bytes),
        },
        else => {},
    };
}

fn preflightHostFile(io: Io, path: []const u8, max_bytes: u64) !void {
    if (path.len == 0) return error.InvalidSourcePath;
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.SourceNotRegularFile;
    if (stat.size > max_bytes) return error.SourceFileTooLarge;
}

fn validateRebuildArtifactPaths(
    allocator: Allocator,
    source: Image,
    source_path: []const u8,
    output_path: []const u8,
    raw_path: []const u8,
    output_stage_path: []const u8,
    spool_path: []const u8,
    operations: []const Operation,
    customization: os_customization.OsCustomization,
) !void {
    const artifacts = [_][]const u8{ output_path, raw_path, output_stage_path, spool_path };
    for (artifacts, 0..) |path, index| {
        if (std.mem.eql(u8, path, source_path)) return error.SourceOutputConflict;
        for (artifacts[index + 1 ..]) |other| {
            if (std.mem.eql(u8, path, other)) return error.SourceOutputConflict;
        }
    }
    const dependencies = try source.sourceDependencyPaths(allocator);
    defer {
        for (dependencies) |path| allocator.free(path);
        allocator.free(dependencies);
    }
    for (dependencies) |dependency| {
        try validateDependencyArtifactIsolation(allocator, dependency, &artifacts);
    }
    for (operations) |operation| switch (operation) {
        .overwrite_file => |overwrite| switch (overwrite.source) {
            .host_path => |path| try validateDependencyArtifactIsolation(
                allocator,
                path,
                &artifacts,
            ),
            .bytes => {},
        },
        .remove_file, .remove_tree => {},
    };
    for (customization.filesystem) |operation| switch (operation) {
        .put_file => |file| switch (file.source) {
            .host_path => |path| try validateDependencyArtifactIsolation(
                allocator,
                path,
                &artifacts,
            ),
            .inline_bytes => {},
        },
        else => {},
    };
}

fn validateDependencyArtifactIsolation(
    allocator: Allocator,
    dependency_path: []const u8,
    artifacts: []const []const u8,
) !void {
    if (dependency_path.len == 0) return error.InvalidSourcePath;
    const resolved = try std.fs.path.resolve(allocator, &.{dependency_path});
    defer allocator.free(resolved);
    for (artifacts) |artifact| {
        if (std.mem.eql(u8, resolved, artifact)) return error.SourceOutputConflict;
    }
}

fn preflightTreeOperations(
    tree: *const root_tree.RootTree,
    operations: []const Operation,
) !void {
    for (operations) |operation| {
        const absolute_path = switch (operation) {
            .overwrite_file => |overwrite| overwrite.path,
            .remove_file => |path| path,
            .remove_tree => |path| path,
        };
        const path = absolute_path[1..];
        const node = tree.findNode(path) orelse return error.MissingExistingPath;
        switch (operation) {
            .overwrite_file => if (node.kind != .file) return error.NotRegularFile,
            .remove_file => if (node.kind == .directory) return error.IsDirectory,
            .remove_tree => if (node.kind != .directory) return error.NotDirectory,
        }
    }
}

fn preflightScannedOperations(
    view: *ext4.FileTreeView,
    operations: []const Operation,
) !void {
    for (operations) |operation| {
        const absolute_path = switch (operation) {
            .overwrite_file => |overwrite| overwrite.path,
            .remove_file => |path| path,
            .remove_tree => |path| path,
        };
        const path = absolute_path[1..];
        view.reset();
        while (try view.next()) |entry| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            switch (operation) {
                .overwrite_file => if (entry.kind != .file) return error.NotRegularFile,
                .remove_file => if (entry.kind == .directory) return error.IsDirectory,
                .remove_tree => if (entry.kind != .directory) return error.NotDirectory,
            }
            break;
        } else return error.MissingExistingPath;
    }
}

fn applyTreeOperations(
    io: Io,
    tree: *root_tree.RootTree,
    operations: []const Operation,
    max_source_file_bytes: u64,
) !void {
    for (operations) |operation| switch (operation) {
        .overwrite_file => |overwrite| {
            const path = overwrite.path[1..];
            const node = tree.findNode(path) orelse return error.MissingExistingPath;
            if (node.kind != .file) return error.NotRegularFile;
            switch (overwrite.source) {
                .bytes => |content| {
                    if (content.len > max_source_file_bytes) return error.SourceFileTooLarge;
                    try tree.putFileBytes(path, content, node.metadata);
                },
                .host_path => |source_path| {
                    const source = try Io.Dir.cwd().openFile(io, source_path, .{});
                    defer source.close(io);
                    const stat = try source.stat(io);
                    if (stat.kind != .file) return error.SourceNotRegularFile;
                    if (stat.size > max_source_file_bytes) return error.SourceFileTooLarge;
                    try tree.putFileFromPath(path, source_path, node.metadata);
                },
            }
        },
        .remove_file => |absolute_path| {
            const path = absolute_path[1..];
            const node = tree.findNode(path) orelse return error.MissingExistingPath;
            if (node.kind == .directory) return error.IsDirectory;
            if (!try tree.remove(path)) return error.MissingExistingPath;
        },
        .remove_tree => |absolute_path| {
            const path = absolute_path[1..];
            const node = tree.findNode(path) orelse return error.MissingExistingPath;
            if (node.kind != .directory) return error.NotDirectory;
            if (!try tree.remove(path)) return error.MissingExistingPath;
        },
    };
}

fn customizationCount(customization: os_customization.OsCustomization) usize {
    return customization.filesystem.len +
        @intFromBool(customization.hostname != null) +
        customization.groups.len +
        customization.users.len +
        customization.services.len +
        customization.kernel_modules.len;
}

fn generalizationCount(policy: os_customization.GeneralizationPolicy) usize {
    return switch (policy) {
        .none => 0,
        .azure => |options| @as(usize, @intFromBool(options.reset_hostname)) +
            @intFromBool(options.clear_machine_id) +
            @intFromBool(options.remove_ssh_host_keys) +
            @intFromBool(options.remove_agent_state) +
            @intFromBool(options.remove_dhcp_leases) +
            @intFromBool(options.remove_logs) +
            @intFromBool(options.remove_caches) +
            @intFromBool(options.clear_random_seed) +
            options.remove_users.len,
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

fn selectRebuildPartition(
    allocator: Allocator,
    io: Io,
    image: Image,
    selector: PartitionSelector,
) !Partition {
    if (image.virtual_size == 0 or image.virtual_size % mbr.sector_size != 0) {
        return error.InvalidPartitionBounds;
    }
    const selected = try selectPartition(allocator, io, image, selector);
    switch (selector) {
        .mbr_index => |one_based| {
            var sector: [mbr.sector_size]u8 = undefined;
            if (try image.pread(io, &sector, 0) != sector.len) {
                return error.UnexpectedEndOfFile;
            }
            const table = try mbr.Mbr.decode(&sector);
            if (table.entries[one_based - 1].partition_type != .linux) {
                return error.UnsupportedRootPartitionType;
            }
            const disk_sectors = image.virtual_size / mbr.sector_size;
            for (table.entries, 0..) |entry, index| {
                if (entry.partition_type == .empty) continue;
                const end = std.math.add(
                    u64,
                    entry.first_lba,
                    entry.sector_count,
                ) catch return error.InvalidPartitionBounds;
                if (entry.sector_count == 0 or end > disk_sectors) {
                    return error.InvalidPartitionBounds;
                }
                for (table.entries[index + 1 ..]) |other| {
                    if (other.partition_type == .empty) continue;
                    const other_end = std.math.add(
                        u64,
                        other.first_lba,
                        other.sector_count,
                    ) catch return error.InvalidPartitionBounds;
                    if (@as(u64, entry.first_lba) < other_end and
                        @as(u64, other.first_lba) < end)
                    {
                        return error.InvalidPartitionBounds;
                    }
                }
            }
        },
        .gpt_index => |one_based| {
            const parsed = try gpt.readGpt(image, io, allocator);
            defer allocator.free(parsed.partitions);
            const partition = for (parsed.partitions) |entry| {
                if (entry.table_index + 1 == one_based) break entry;
            } else return error.PartitionNotFound;
            if (!std.mem.eql(u8, &partition.partition_type_guid, &guid.linux_filesystem_data) and
                !std.mem.eql(u8, &partition.partition_type_guid, &guid.linux_root_x86_64) and
                !std.mem.eql(u8, &partition.partition_type_guid, &guid.linux_root_aarch64))
            {
                return error.UnsupportedRootPartitionType;
            }
        },
    }
    return selected;
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
    const config_xattrs = [_]ext4.Xattr{.{ .name = "user.origin", .value = "preserved" }};
    try tree.putDirectory("etc", .{ .mode = 0o755 });
    try tree.putFileBytes("etc/config", "before\n", .{
        .mode = 0o640,
        .uid = 12,
        .gid = 34,
        .xattrs = &config_xattrs,
    });
    try tree.putFileBytes("etc/remove", "remove\n", .{ .mode = 0o644 });
    try tree.putSymlink("config-link", "etc/config", .{ .mode = 0o777, .uid = 56, .gid = 78 });
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

fn expectOutsideRangeEqual(
    io: Io,
    source: Image,
    output: Image,
    excluded_offset: u64,
    excluded_length: u64,
) !void {
    var source_buffer: [64 * 1024]u8 = undefined;
    var output_buffer: [64 * 1024]u8 = undefined;
    const excluded_end = excluded_offset + excluded_length;
    var offset: u64 = 0;
    while (offset < source.virtual_size) {
        if (offset == excluded_offset) {
            offset = excluded_end;
            continue;
        }
        const range_end = if (offset < excluded_offset) excluded_offset else source.virtual_size;
        const wanted: usize = @intCast(@min(
            @as(u64, source_buffer.len),
            range_end - offset,
        ));
        if (try source.pread(io, source_buffer[0..wanted], offset) != wanted or
            try output.pread(io, output_buffer[0..wanted], offset) != wanted)
        {
            return error.UnexpectedEndOfFile;
        }
        try std.testing.expectEqualSlices(
            u8,
            source_buffer[0..wanted],
            output_buffer[0..wanted],
        );
        offset += wanted;
    }
}

fn expectRebuildArtifactsMissing(io: Io, output_path: []const u8) !void {
    inline for (.{ "", ".native-rebuild.raw", ".native-rebuild.output", ".native-rebuild.spool" }) |suffix| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{
            output_path,
            suffix,
        });
        defer std.testing.allocator.free(path);
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, path, .{}));
    }
}

const TestExt4Crc32c = std.hash.crc.Crc(u32, .{
    .polynomial = 0x1edc6f41,
    .initial = 0xffff_ffff,
    .reflect_input = true,
    .reflect_output = true,
    .xor_output = 0x0000_0000,
});

fn updateTestDirectoryLeafChecksum(
    block: []u8,
    uuid: [16]u8,
    inode_number: u32,
) void {
    var inode_le = std.mem.nativeToLittle(u32, inode_number);
    var generation_le = std.mem.nativeToLittle(u32, @as(u32, 0));
    var hasher = TestExt4Crc32c.init();
    hasher.update(&uuid);
    hasher.update(std.mem.asBytes(&inode_le));
    hasher.update(std.mem.asBytes(&generation_le));
    hasher.update(block[0 .. block.len - 12]);
    std.mem.writeInt(u32, block[block.len - 4 ..][0..4], hasher.final(), .little);
}

fn mutateRootDirectoryEntry(
    io: Io,
    path: []const u8,
    entry_name: []const u8,
    replacement_inode: ?u32,
    replacement_file_type: ?u8,
    replacement_name_byte: ?struct { index: usize, value: u8 },
) !void {
    var image = try Image.openPath(io, path);
    defer image.close(io);
    const partition_offset = @as(u64, test_partition_first_lba) * mbr.sector_size;
    var reader = try ext4.open(io, image.file, std.testing.allocator, .{
        .offset = partition_offset,
    });
    defer reader.deinit();
    const extents = try reader.readExtents(io, std.testing.allocator, "/");
    defer std.testing.allocator.free(extents);
    var block: [ext4.default_block_size]u8 = undefined;
    for (extents) |extent| {
        var extent_block: u16 = 0;
        while (extent_block < extent.block_count) : (extent_block += 1) {
            const physical_block = extent.start_block + extent_block;
            const block_offset = partition_offset + physical_block * ext4.default_block_size;
            if (try image.pread(io, &block, block_offset) != block.len) {
                return error.UnexpectedEndOfFile;
            }
            var offset: usize = 0;
            while (offset + 8 <= block.len) {
                const rec_len = std.mem.readInt(u16, block[offset + 4 ..][0..2], .little);
                const name_len = block[offset + 6];
                if (rec_len < 8 or offset + rec_len > block.len or name_len > rec_len - 8) {
                    return error.BadDirectoryEntry;
                }
                const name = block[offset + 8 .. offset + 8 + name_len];
                if (std.mem.eql(u8, name, entry_name)) {
                    if (replacement_inode) |inode| {
                        std.mem.writeInt(u32, block[offset..][0..4], inode, .little);
                    }
                    if (replacement_file_type) |file_type| block[offset + 7] = file_type;
                    if (replacement_name_byte) |replacement| {
                        if (replacement.index >= name.len) return error.InvalidTestMutation;
                        block[offset + 8 + replacement.index] = replacement.value;
                    }
                    updateTestDirectoryLeafChecksum(&block, reader.uuid, ext4.root_inode);
                    try image.pwrite(io, &block, block_offset);
                    return;
                }
                offset += rec_len;
            }
        }
    }
    return error.NotFound;
}

test "rebuild inspection validates source without creating artifacts" {
    const io = std.testing.io;
    const source_path = "test-rebuild-inspection-source.raw";
    const output_path = "test-rebuild-inspection-output.raw";
    defer Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.raw") catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.output") catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.spool") catch {};
    try createTestDisk(io, source_path);
    const source_before = try hashTestPath(io, source_path);

    const inspection = try inspectRebuild(std.testing.allocator, io, .{
        .source_path = source_path,
        .output_path = output_path,
        .expected_source_format = .raw,
        .output_format = .raw,
        .root_partition = .{ .mbr_index = 1 },
        .source_date_epoch = 1_735_689_600,
        .expected_virtual_size = test_disk_size,
    });
    try std.testing.expectEqual(Format.raw, inspection.source_format);
    try std.testing.expectEqual(test_disk_size, inspection.virtual_size);
    try std.testing.expectEqual(
        @as(u64, test_partition_first_lba) * mbr.sector_size,
        inspection.partition_offset,
    );
    try std.testing.expectEqual(
        @as(u64, test_partition_sectors) * mbr.sector_size,
        inspection.partition_length,
    );
    try std.testing.expectEqual(ext4.StrictProfile.zvmi_ext4_v1, inspection.strict_profile);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x42} ** 16), &inspection.ext4_uuid);
    try std.testing.expectEqual(@as(u32, 1_735_689_600), inspection.ext4_global_timestamp);
    try std.testing.expectEqual(@as(usize, 8), inspection.imported_node_count);
    try std.testing.expectEqualSlices(u8, &source_before, &(try hashTestPath(io, source_path)));
    try expectRebuildArtifactsMissing(io, output_path);
}

test "rebuild inspection strict failure creates no artifacts" {
    const io = std.testing.io;
    const source_path = "test-rebuild-inspection-invalid-source.raw";
    const output_path = "test-rebuild-inspection-invalid-output.raw";
    defer Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.raw") catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.output") catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.spool") catch {};
    try createTestDisk(io, source_path);
    try mutateRootDirectoryEntry(
        io,
        source_path,
        "config-link",
        null,
        null,
        .{ .index = 6, .value = '/' },
    );

    try std.testing.expectError(error.InvalidImportedPath, inspectRebuild(
        std.testing.allocator,
        io,
        .{
            .source_path = source_path,
            .output_path = output_path,
            .output_format = .raw,
            .root_partition = .{ .mbr_index = 1 },
            .source_date_epoch = 1_735_689_600,
        },
    ));
    try expectRebuildArtifactsMissing(io, output_path);
}

test "rebuild inspection simulates ordered mutations without creating artifacts" {
    const io = std.testing.io;
    const source_path = "test-rebuild-inspection-mutations-source.raw";
    const output_path = "test-rebuild-inspection-mutations-output.raw";
    const oversized_path = "test-rebuild-inspection-oversized.bin";
    defer Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, oversized_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.raw") catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.output") catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.spool") catch {};
    try createTestDisk(io, source_path);

    try std.testing.expectError(error.MissingExistingPath, inspectRebuild(
        std.testing.allocator,
        io,
        .{
            .source_path = source_path,
            .output_path = output_path,
            .output_format = .raw,
            .root_partition = .{ .mbr_index = 1 },
            .existing_operations = &.{
                .{ .remove_tree = "/etc" },
                .{ .overwrite_file = .{
                    .path = "/etc/config",
                    .source = .{ .bytes = "replacement\n" },
                } },
            },
            .source_date_epoch = 1_735_689_600,
        },
    ));
    try expectRebuildArtifactsMissing(io, output_path);

    try std.testing.expectError(error.MissingCustomizationPath, inspectRebuild(
        std.testing.allocator,
        io,
        .{
            .source_path = source_path,
            .output_path = output_path,
            .output_format = .raw,
            .root_partition = .{ .mbr_index = 1 },
            .customization = .{ .filesystem = &.{
                .{ .remove = "/etc/config" },
                .{ .set_metadata = .{ .path = "/etc/config" } },
            } },
            .source_date_epoch = 1_735_689_600,
        },
    ));
    try expectRebuildArtifactsMissing(io, output_path);

    {
        const oversized = try Io.Dir.cwd().createFile(io, oversized_path, .{});
        defer oversized.close(io);
        try oversized.setLength(io, @as(u64, test_partition_sectors) * mbr.sector_size);
    }
    try std.testing.expectError(error.NotEnoughSpace, inspectRebuild(
        std.testing.allocator,
        io,
        .{
            .source_path = source_path,
            .output_path = output_path,
            .output_format = .raw,
            .root_partition = .{ .mbr_index = 1 },
            .customization = .{ .filesystem = &.{
                .{ .put_file = .{
                    .path = "/oversized",
                    .source = .{ .host_path = oversized_path },
                } },
            } },
            .source_date_epoch = 1_735_689_600,
        },
    ));
    try expectRebuildArtifactsMissing(io, output_path);
}

test "strict raw rebuild preserves identity tree metadata and outside bytes deterministically" {
    const io = std.testing.io;
    const source_path = "test-preserved-rebuild-source.raw";
    const output_path = "test-preserved-rebuild-output.raw";
    const output2_path = "test-preserved-rebuild-output-2.raw";
    const artifacts = [_][]const u8{
        source_path,
        output_path,
        output2_path,
        output_path ++ ".native-rebuild.raw",
        output_path ++ ".native-rebuild.output",
        output_path ++ ".native-rebuild.spool",
        output2_path ++ ".native-rebuild.raw",
        output2_path ++ ".native-rebuild.output",
        output2_path ++ ".native-rebuild.spool",
    };
    defer for (artifacts) |path| Io.Dir.cwd().deleteFile(io, path) catch {};
    try createTestDisk(io, source_path);
    {
        var source = try Image.openPath(io, source_path);
        defer source.close(io);
        try source.pwrite(
            io,
            &([_]u8{0xA7} ** ext4.default_block_size),
            (@as(u64, test_partition_first_lba + test_partition_sectors) *
                mbr.sector_size) - ext4.default_block_size,
        );
    }
    const source_before = try hashTestPath(io, source_path);

    const existing = [_]Operation{
        .{ .overwrite_file = .{
            .path = "/etc/config",
            .source = .{ .bytes = "rebuilt\n" },
        } },
        .{ .remove_file = "/etc/remove" },
        .{ .remove_tree = "/var/tmp/drop" },
    };
    const filesystem = [_]os_customization.FilesystemOperation{
        .{ .put_directory = .{
            .path = "/opt/new",
            .metadata = .{ .mode = 0o750, .uid = 101, .gid = 202 },
        } },
        .{ .put_file = .{
            .path = "/opt/new/value",
            .source = .{ .inline_bytes = "created\n" },
            .metadata = .{ .mode = 0o600, .uid = 303, .gid = 404 },
        } },
        .{ .put_symlink = .{
            .path = "/created-link",
            .target = "opt/new/value",
            .metadata = .{ .mode = 0o777, .uid = 505, .gid = 606 },
        } },
    };
    const rebuild_options = RebuildOptions{
        .source_path = source_path,
        .output_path = output_path,
        .expected_source_format = .raw,
        .output_format = .raw,
        .root_partition = .{ .mbr_index = 1 },
        .existing_operations = &existing,
        .customization = .{ .filesystem = &filesystem },
        .generalization = .{ .azure = .{} },
        .source_date_epoch = 1_735_689_600,
        .expected_virtual_size = test_disk_size,
    };
    const report = try rebuild(std.testing.allocator, io, rebuild_options);
    var second_options = rebuild_options;
    second_options.output_path = output2_path;
    const second_report = try rebuild(std.testing.allocator, io, second_options);

    try std.testing.expectEqual(ext4.StrictProfile.zvmi_ext4_v1, report.strict_profile);
    try std.testing.expectEqual(@as(u32, 1_735_689_600), report.ext4_global_timestamp);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x42} ** 16), &report.ext4_uuid);
    try std.testing.expectEqualSlices(
        u8,
        &report.source_manifest_sha256,
        &second_report.source_manifest_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &report.final_manifest_sha256,
        &second_report.final_manifest_sha256,
    );
    try std.testing.expectEqual(report.imported_node_count, second_report.imported_node_count);
    try std.testing.expectEqual(report.final_node_count, second_report.final_node_count);
    try std.testing.expectEqual(@as(usize, existing.len), report.existing_operation_count);
    try std.testing.expectEqual(@as(usize, filesystem.len), report.os_customization_count);
    try std.testing.expect(report.generalization_count > 0);
    try std.testing.expectEqualSlices(u8, &source_before, &(try hashTestPath(io, source_path)));

    var source = try Image.openPathReadOnly(io, source_path);
    defer source.close(io);
    var output = try Image.openPathReadOnly(io, output_path);
    defer output.close(io);
    const partition_offset = @as(u64, test_partition_first_lba) * mbr.sector_size;
    const partition_length = @as(u64, test_partition_sectors) * mbr.sector_size;
    try expectOutsideRangeEqual(
        io,
        source,
        output,
        partition_offset,
        partition_length,
    );
    var cleared_free_block: [ext4.default_block_size]u8 = undefined;
    _ = try output.pread(
        io,
        &cleared_free_block,
        partition_offset + partition_length - cleared_free_block.len,
    );
    try std.testing.expect(std.mem.allEqual(u8, &cleared_free_block, 0));

    var reader = try ext4.open(io, output.file, std.testing.allocator, .{
        .offset = partition_offset,
    });
    defer reader.deinit();
    var strict = try ext4.scanWriterCompatible(&reader, io, std.testing.allocator, .{
        .expected_length = partition_length,
    });
    defer strict.deinit();
    try std.testing.expectEqual(report.final_node_count, strict.nodeCount());
    try std.testing.expectEqualSlices(u8, &report.ext4_label, &strict.identity.label);
    try std.testing.expectEqual(report.ext4_global_timestamp, strict.identity.global_timestamp);

    const config = try reader.readFileAlloc(io, std.testing.allocator, "/etc/config");
    defer std.testing.allocator.free(config);
    try std.testing.expectEqualStrings("rebuilt\n", config);
    const config_stat = try reader.statPath(io, "/etc/config");
    try std.testing.expectEqual(@as(u16, 0o640), config_stat.mode);
    try std.testing.expectEqual(@as(u32, 12), config_stat.uid);
    try std.testing.expectEqual(@as(u32, 34), config_stat.gid);
    const origin = try reader.readXattrAlloc(
        io,
        std.testing.allocator,
        "/etc/config",
        "user.origin",
    );
    defer std.testing.allocator.free(origin);
    try std.testing.expectEqualStrings("preserved", origin);
    try std.testing.expectError(error.NotFound, reader.statPath(io, "/etc/remove"));
    try std.testing.expectError(error.NotFound, reader.statPath(io, "/var/tmp/drop"));

    const value = try reader.readFileAlloc(io, std.testing.allocator, "/opt/new/value");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("created\n", value);
    const value_stat = try reader.statPath(io, "/opt/new/value");
    try std.testing.expectEqual(@as(u16, 0o600), value_stat.mode);
    try std.testing.expectEqual(@as(u32, 303), value_stat.uid);
    try std.testing.expectEqual(@as(u32, 404), value_stat.gid);
    const target = try reader.readLinkAlloc(io, std.testing.allocator, "/created-link");
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("opt/new/value", target);
    const hostname = try reader.readFileAlloc(io, std.testing.allocator, "/etc/hostname");
    defer std.testing.allocator.free(hostname);
    try std.testing.expectEqualStrings("localhost.localdomain\n", hostname);

    inline for (.{ ".native-rebuild.raw", ".native-rebuild.output", ".native-rebuild.spool" }) |suffix| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ output_path, suffix });
        defer std.testing.allocator.free(path);
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, path, .{}));
    }
}

test "strict rebuild flattens a backed qcow2 source without changing its chain" {
    const io = std.testing.io;
    const raw_path = "test-rebuild-backed-base.raw";
    const base_path = "test-rebuild-backed-base.qcow2";
    const source_path = "test-rebuild-backed-overlay.qcow2";
    const output_path = "test-rebuild-backed-output.qcow2";
    const artifacts = [_][]const u8{
        raw_path,
        base_path,
        source_path,
        output_path,
        output_path ++ ".native-rebuild.raw",
        output_path ++ ".native-rebuild.output",
        output_path ++ ".native-rebuild.spool",
    };
    defer for (artifacts) |path| Io.Dir.cwd().deleteFile(io, path) catch {};
    try createTestDisk(io, raw_path);
    {
        var raw = try Image.openPathReadOnly(io, raw_path);
        defer raw.close(io);
        var base = try Image.createExclusive(io, base_path, .qcow2, test_disk_size, .{});
        defer base.close(io);
        try image_mod.copyAll(io, raw, &base, std.testing.allocator);
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

    const report = try rebuild(std.testing.allocator, io, .{
        .source_path = source_path,
        .output_path = output_path,
        .expected_source_format = .qcow2,
        .output_format = .qcow2,
        .root_partition = .{ .mbr_index = 1 },
        .source_date_epoch = 1_735_689_600,
    });
    try std.testing.expect(report.flattened_backing_chain);
    try std.testing.expectEqualSlices(u8, &source_before, &(try hashTestPath(io, source_path)));
    try std.testing.expectEqualSlices(u8, &base_before, &(try hashTestPath(io, base_path)));

    var output = try Image.openPathReadOnly(io, output_path);
    defer output.close(io);
    try std.testing.expectEqual(Format.qcow2, output.format);
    try std.testing.expectEqual(@as(u8, 0), output.qcow2.?.backing_depth);
    try std.testing.expectEqual(@as(u16, 0), output.qcow2.?.backing_file_len);
    var reader = try ext4.openReadOnlySource(
        io,
        output.file,
        .{ .ctx = &output, .read_at_fn = imageReadAt },
        std.testing.allocator,
        .{ .offset = @as(u64, test_partition_first_lba) * mbr.sector_size },
    );
    defer reader.deinit();
    var strict = try ext4.scanWriterCompatible(&reader, io, std.testing.allocator, .{
        .expected_length = @as(u64, test_partition_sectors) * mbr.sector_size,
    });
    defer strict.deinit();
    try std.testing.expectEqual(report.final_node_count, strict.nodeCount());
}

test "strict rebuild rejects inode aliases before creating staging" {
    const io = std.testing.io;
    const source_path = "test-rebuild-alias-source.raw";
    const output_path = "test-rebuild-alias-output.raw";
    defer Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.raw") catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.output") catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.spool") catch {};
    try createTestDisk(io, source_path);

    var source = try Image.openPathReadOnly(io, source_path);
    var reader = try ext4.open(io, source.file, std.testing.allocator, .{
        .offset = @as(u64, test_partition_first_lba) * mbr.sector_size,
    });
    const config_inode = (try reader.statPath(io, "/etc/config")).inode;
    reader.deinit();
    source.close(io);
    try mutateRootDirectoryEntry(io, source_path, "config-link", config_inode, 1, null);

    try std.testing.expectError(error.InodeAlias, rebuild(std.testing.allocator, io, .{
        .source_path = source_path,
        .output_path = output_path,
        .output_format = .raw,
        .root_partition = .{ .mbr_index = 1 },
        .source_date_epoch = 1_735_689_600,
    }));
    try expectRebuildArtifactsMissing(io, output_path);
}

test "strict rebuild rejects malformed imported paths before creating staging" {
    const io = std.testing.io;
    const source_path = "test-rebuild-malformed-tree-source.raw";
    const output_path = "test-rebuild-malformed-tree-output.raw";
    defer Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.raw") catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.output") catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path ++ ".native-rebuild.spool") catch {};
    try createTestDisk(io, source_path);
    try mutateRootDirectoryEntry(
        io,
        source_path,
        "config-link",
        null,
        null,
        .{ .index = 6, .value = '/' },
    );

    try std.testing.expectError(error.InvalidImportedPath, rebuild(std.testing.allocator, io, .{
        .source_path = source_path,
        .output_path = output_path,
        .output_format = .raw,
        .root_partition = .{ .mbr_index = 1 },
        .source_date_epoch = 1_735_689_600,
    }));
    try expectRebuildArtifactsMissing(io, output_path);
}

test "strict rebuild rejects filesystem trailers and unsupported partition layout before staging" {
    const io = std.testing.io;
    const trailer_source = "test-rebuild-trailer-source.raw";
    const trailer_output = "test-rebuild-trailer-output.raw";
    const layout_source = "test-rebuild-layout-source.raw";
    const layout_output = "test-rebuild-layout-output.raw";
    const paths = [_][]const u8{
        trailer_source,
        trailer_output,
        trailer_output ++ ".native-rebuild.raw",
        trailer_output ++ ".native-rebuild.output",
        trailer_output ++ ".native-rebuild.spool",
        layout_source,
        layout_output,
        layout_output ++ ".native-rebuild.raw",
        layout_output ++ ".native-rebuild.output",
        layout_output ++ ".native-rebuild.spool",
    };
    defer for (paths) |path| Io.Dir.cwd().deleteFile(io, path) catch {};
    try createTestDisk(io, trailer_source);
    {
        var image = try Image.openPath(io, trailer_source);
        defer image.close(io);
        var sector: [mbr.sector_size]u8 = undefined;
        if (try image.pread(io, &sector, 0) != sector.len) return error.UnexpectedEndOfFile;
        var table = try mbr.Mbr.decode(&sector);
        table.entries[0].sector_count += 8;
        table.encodePartitionTableInto(&sector);
        try image.pwrite(io, &sector, 0);
    }
    try std.testing.expectError(error.FilesystemLengthMismatch, rebuild(
        std.testing.allocator,
        io,
        .{
            .source_path = trailer_source,
            .output_path = trailer_output,
            .output_format = .raw,
            .root_partition = .{ .mbr_index = 1 },
            .source_date_epoch = 1_735_689_600,
        },
    ));
    try expectRebuildArtifactsMissing(io, trailer_output);

    try createTestDisk(io, layout_source);
    {
        var image = try Image.openPath(io, layout_source);
        defer image.close(io);
        var sector: [mbr.sector_size]u8 = undefined;
        if (try image.pread(io, &sector, 0) != sector.len) return error.UnexpectedEndOfFile;
        var table = try mbr.Mbr.decode(&sector);
        table.entries[0].partition_type = @enumFromInt(0x07);
        table.encodePartitionTableInto(&sector);
        try image.pwrite(io, &sector, 0);
    }
    try std.testing.expectError(error.UnsupportedRootPartitionType, rebuild(
        std.testing.allocator,
        io,
        .{
            .source_path = layout_source,
            .output_path = layout_output,
            .output_format = .raw,
            .root_partition = .{ .mbr_index = 1 },
            .source_date_epoch = 1_735_689_600,
        },
    ));
    try expectRebuildArtifactsMissing(io, layout_output);
}

test "failed rebuild customization and publication clean every staging artifact" {
    const io = std.testing.io;
    const source_path = "test-rebuild-cleanup-source.raw";
    const customization_output = "test-rebuild-cleanup-customization.raw";
    const publish_output = "test-rebuild-cleanup-publish.raw";
    const paths = [_][]const u8{
        source_path,
        customization_output,
        customization_output ++ ".native-rebuild.raw",
        customization_output ++ ".native-rebuild.output",
        customization_output ++ ".native-rebuild.spool",
        publish_output,
        publish_output ++ ".native-rebuild.raw",
        publish_output ++ ".native-rebuild.output",
        publish_output ++ ".native-rebuild.spool",
    };
    defer for (paths) |path| Io.Dir.cwd().deleteFile(io, path) catch {};
    try createTestDisk(io, source_path);

    const invalid_customization = [_]os_customization.FilesystemOperation{
        .{ .set_metadata = .{ .path = "/missing", .mode = 0o600 } },
    };
    try std.testing.expectError(error.MissingCustomizationPath, rebuild(
        std.testing.allocator,
        io,
        .{
            .source_path = source_path,
            .output_path = customization_output,
            .output_format = .raw,
            .root_partition = .{ .mbr_index = 1 },
            .customization = .{ .filesystem = &invalid_customization },
            .source_date_epoch = 1_735_689_600,
        },
    ));
    try expectRebuildArtifactsMissing(io, customization_output);

    {
        const output = try Io.Dir.cwd().createFile(io, publish_output, .{});
        defer output.close(io);
        try output.writePositionalAll(io, "preserve-me", 0);
    }
    try std.testing.expectError(error.PathAlreadyExists, rebuild(
        std.testing.allocator,
        io,
        .{
            .source_path = source_path,
            .output_path = publish_output,
            .output_format = .raw,
            .root_partition = .{ .mbr_index = 1 },
            .source_date_epoch = 1_735_689_600,
        },
    ));
    inline for (.{ ".native-rebuild.raw", ".native-rebuild.output", ".native-rebuild.spool" }) |suffix| {
        const artifact = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}{s}",
            .{ publish_output, suffix },
        );
        defer std.testing.allocator.free(artifact);
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, artifact, .{}));
    }
    const existing = try Io.Dir.cwd().openFile(io, publish_output, .{});
    defer existing.close(io);
    var bytes: ["preserve-me".len]u8 = undefined;
    _ = try existing.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings("preserve-me", &bytes);
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
