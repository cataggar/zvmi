//! Local container image ingestion and layer flattening.
//!
//! Scope / limitations:
//!  - `load()` auto-detects OCI image-layout directories and docker/podman
//!    save tarballs on local disk.
//!  - Supports uncompressed and gzip-compressed tar layers.
//!  - `loadLayout()` remains available for callers that explicitly require
//!    an OCI image-layout directory.
//!  - Docker save tarballs with multiple manifest entries currently load the
//!    first entry; manifest selection is only supported for OCI layouts.
//!  - zstd-compressed layers are not supported yet.
//!  - Registry/network access, signatures, and manifest-list/platform
//!    resolution are out of scope; callers may optionally pick a specific
//!    manifest digest when `index.json` contains more than one entry.

const std = @import("std");
const Io = std.Io;
const tar = @import("tar.zig");

const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

pub const EntryKind = enum {
    file,
    directory,
    symlink,
    hardlink,
};

pub const FileTree = struct {
    allocator: Allocator,
    entries: []Entry,

    pub const Entry = struct {
        path: []const u8,
        kind: EntryKind,
        mode: u32,
        size: u64,
        link_name: ?[]const u8 = null,
        content: []const u8 = &.{},

        pub fn reader(self: Entry) Io.Reader {
            return .fixed(self.content);
        }
    };

    pub const Iterator = struct {
        entries: []const Entry,
        index: usize = 0,

        pub fn next(self: *Iterator) ?Entry {
            if (self.index >= self.entries.len) return null;
            defer self.index += 1;
            return self.entries[self.index];
        }
    };

    pub fn deinit(self: *FileTree) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.path);
            if (entry.link_name) |link_name| self.allocator.free(link_name);
            if (entry.kind == .file) self.allocator.free(entry.content);
        }
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn iterator(self: FileTree) Iterator {
        return .{ .entries = self.entries };
    }

    pub fn get(self: FileTree, path: []const u8) ?Entry {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }
};

pub const Config = struct {
    architecture: ?[]const u8 = null,
    os: ?[]const u8 = null,
    manifest_digest: []const u8,
};

pub const Image = struct {
    allocator: Allocator,
    config: Config,
    tree: FileTree,

    pub fn deinit(self: *Image) void {
        if (self.config.architecture) |architecture| self.allocator.free(architecture);
        if (self.config.os) |os| self.allocator.free(os);
        self.allocator.free(self.config.manifest_digest);
        self.tree.deinit();
        self.* = undefined;
    }

    pub fn iterator(self: Image) FileTree.Iterator {
        return self.tree.iterator();
    }

    pub fn get(self: Image, path: []const u8) ?FileTree.Entry {
        return self.tree.get(path);
    }
};

pub const LoadOptions = struct {
    /// Applies to OCI image-layout directories only.
    manifest_digest: ?[]const u8 = null,
    max_blob_size: usize = 64 * 1024 * 1024,
    max_layer_size: usize = 128 * 1024 * 1024,
    max_archive_size: usize = 512 * 1024 * 1024,
};

pub const LoadError = error{
    MissingOciLayout,
    MissingImageManifest,
    MissingDockerManifest,
    MissingDockerConfig,
    MissingDockerLayer,
    UnsupportedManifestList,
    UnsupportedDigestAlgorithm,
    UnsupportedLayerCompression,
    UnsupportedLayerMediaType,
    BlobTooLarge,
    LayerTooLarge,
    InvalidLayerPath,
    LayerDecompressionFailed,
} || Allocator.Error || Io.File.OpenError || Io.File.ReadPositionalError ||
    Io.File.StatError || Io.Dir.OpenError || std.json.ParseError(std.json.Scanner) ||
    tar.Error || error{StreamTooLong};

/// Auto-detects an OCI image-layout directory or docker/podman save tarball.
pub fn load(io: Io, allocator: Allocator, image_path: []const u8, options: LoadOptions) LoadError!Image {
    var image_dir = Io.Dir.cwd().openDir(io, image_path, .{}) catch |err| switch (err) {
        error.NotDir => return loadDockerSaveTarball(io, allocator, image_path, options),
        else => return err,
    };
    defer image_dir.close(io);
    return loadLayoutDir(io, allocator, image_dir, options);
}

/// Loads an OCI image-layout directory from local disk.
pub fn loadLayout(io: Io, allocator: Allocator, layout_path: []const u8, options: LoadOptions) LoadError!Image {
    var layout_dir = try Io.Dir.cwd().openDir(io, layout_path, .{});
    defer layout_dir.close(io);
    return loadLayoutDir(io, allocator, layout_dir, options);
}

/// Loads a docker/podman save tarball from local disk.
pub fn loadDockerSaveTarball(io: Io, allocator: Allocator, tarball_path: []const u8, options: LoadOptions) LoadError!Image {
    var tarball = try Io.Dir.cwd().openFile(io, tarball_path, .{});
    defer tarball.close(io);

    var archive = try tar.readFile(io, allocator, tarball, options.max_archive_size);
    defer archive.deinit(allocator);

    return loadDockerSaveArchive(allocator, archive.bytes, options);
}

fn loadLayoutDir(io: Io, allocator: Allocator, layout_dir: Io.Dir, options: LoadOptions) LoadError!Image {
    const layout_bytes = try readFileAtMost(io, allocator, layout_dir, "oci-layout", options.max_blob_size);
    defer allocator.free(layout_bytes);
    const layout = try std.json.parseFromSlice(LayoutFile, allocator, layout_bytes, .{ .ignore_unknown_fields = true });
    defer layout.deinit();
    if (layout.value.imageLayoutVersion.len == 0) return error.MissingOciLayout;

    const index_bytes = try readFileAtMost(io, allocator, layout_dir, "index.json", options.max_blob_size);
    defer allocator.free(index_bytes);
    const index = try std.json.parseFromSlice(IndexDocument, allocator, index_bytes, .{ .ignore_unknown_fields = true });
    defer index.deinit();

    const manifest_desc = selectManifest(index.value, options.manifest_digest) orelse return error.MissingImageManifest;
    if (isManifestListMediaType(manifest_desc.mediaType)) return error.UnsupportedManifestList;

    const manifest_bytes = try readBlob(io, allocator, layout_dir, manifest_desc.digest, options.max_blob_size);
    defer allocator.free(manifest_bytes);
    const manifest = try std.json.parseFromSlice(ManifestDocument, allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest.deinit();

    const config_bytes = try readBlob(io, allocator, layout_dir, manifest.value.config.digest, options.max_blob_size);
    defer allocator.free(config_bytes);
    const config_doc = try std.json.parseFromSlice(ConfigDocument, allocator, config_bytes, .{ .ignore_unknown_fields = true });
    defer config_doc.deinit();

    var entry_map = StringHashMap(FileTree.Entry).init(allocator);
    var entry_map_owned = true;
    errdefer if (entry_map_owned) deinitEntryMap(&entry_map, allocator);

    for (manifest.value.layers) |layer_desc| {
        try applyLayer(io, allocator, layout_dir, &entry_map, layer_desc, options);
    }
    var tree = try finalizeTree(allocator, &entry_map);
    entry_map_owned = false;
    errdefer tree.deinit();

    return .{
        .allocator = allocator,
        .config = .{
            .architecture = if (config_doc.value.architecture) |value| try allocator.dupe(u8, value) else null,
            .os = if (config_doc.value.os) |value| try allocator.dupe(u8, value) else null,
            .manifest_digest = try allocator.dupe(u8, manifest_desc.digest),
        },
        .tree = tree,
    };
}

const LayoutFile = struct {
    imageLayoutVersion: []const u8,
};

const Descriptor = struct {
    mediaType: ?[]const u8 = null,
    digest: []const u8,
    size: u64,
};

const IndexDocument = struct {
    schemaVersion: u32,
    manifests: []const Descriptor,
};

const ManifestDocument = struct {
    schemaVersion: u32,
    config: Descriptor,
    layers: []const Descriptor,
};

const DockerSaveManifestItem = struct {
    @"Config": []const u8,
    @"RepoTags": ?[]const []const u8 = null,
    @"Layers": []const []const u8,
};

const ConfigDocument = struct {
    architecture: ?[]const u8 = null,
    os: ?[]const u8 = null,
};

const ArchiveEntry = struct {
    kind: tar.Kind,
    content: []const u8,
};

const ArchiveIndex = struct {
    entries: StringHashMap(ArchiveEntry),

    fn init(allocator: Allocator, archive_bytes: []const u8) LoadError!ArchiveIndex {
        var entries = StringHashMap(ArchiveEntry).init(allocator);
        errdefer deinitArchiveEntries(&entries, allocator);

        var reader = tar.Reader.init(archive_bytes);
        while (try reader.next()) |entry| {
            const normalized_path = try normalizeArchivePath(allocator, entry.path);
            var path_owned = true;
            errdefer if (path_owned) allocator.free(normalized_path);

            if (entries.fetchRemove(normalized_path)) |removed| allocator.free(removed.key);
            try entries.put(normalized_path, .{
                .kind = entry.kind,
                .content = entry.content,
            });
            path_owned = false;
        }

        return .{ .entries = entries };
    }

    fn deinit(self: *ArchiveIndex, allocator: Allocator) void {
        deinitArchiveEntries(&self.entries, allocator);
        self.* = undefined;
    }

    fn getFile(self: ArchiveIndex, path: []const u8) ?ArchiveEntry {
        const entry = self.entries.get(path) orelse return null;
        return if (entry.kind == .file) entry else null;
    }
};

fn loadDockerSaveArchive(allocator: Allocator, archive_bytes: []const u8, options: LoadOptions) LoadError!Image {
    var archive = try ArchiveIndex.init(allocator, archive_bytes);
    defer archive.deinit(allocator);

    const manifest_file = archive.getFile("manifest.json") orelse return error.MissingDockerManifest;
    const manifest_doc = try std.json.parseFromSlice([]DockerSaveManifestItem, allocator, manifest_file.content, .{
        .ignore_unknown_fields = true,
    });
    defer manifest_doc.deinit();

    const manifest_entry = selectDockerSaveManifest(manifest_doc.value) orelse return error.MissingImageManifest;

    const config_path = try normalizeArchivePath(allocator, manifest_entry.@"Config");
    defer allocator.free(config_path);
    const config_file = archive.getFile(config_path) orelse return error.MissingDockerConfig;
    const config_doc = try std.json.parseFromSlice(ConfigDocument, allocator, config_file.content, .{
        .ignore_unknown_fields = true,
    });
    defer config_doc.deinit();

    var entry_map = StringHashMap(FileTree.Entry).init(allocator);
    var entry_map_owned = true;
    errdefer if (entry_map_owned) deinitEntryMap(&entry_map, allocator);

    for (manifest_entry.@"Layers") |layer_path_raw| {
        const layer_path = try normalizeArchivePath(allocator, layer_path_raw);
        defer allocator.free(layer_path);

        const layer_file = archive.getFile(layer_path) orelse return error.MissingDockerLayer;
        try applyLayerBytes(allocator, &entry_map, null, layer_file.content, options);
    }

    var tree = try finalizeTree(allocator, &entry_map);
    entry_map_owned = false;
    errdefer tree.deinit();

    const manifest_digest = try sha256DigestString(allocator, manifest_file.content);
    errdefer allocator.free(manifest_digest);

    return .{
        .allocator = allocator,
        .config = .{
            .architecture = if (config_doc.value.architecture) |value| try allocator.dupe(u8, value) else null,
            .os = if (config_doc.value.os) |value| try allocator.dupe(u8, value) else null,
            .manifest_digest = manifest_digest,
        },
        .tree = tree,
    };
}

fn selectDockerSaveManifest(manifests: []const DockerSaveManifestItem) ?DockerSaveManifestItem {
    return if (manifests.len == 0) null else manifests[0];
}

fn selectManifest(index: IndexDocument, requested_digest: ?[]const u8) ?Descriptor {
    if (requested_digest) |digest| {
        for (index.manifests) |manifest| {
            if (std.mem.eql(u8, manifest.digest, digest)) return manifest;
        }
        return null;
    }
    return if (index.manifests.len == 0) null else index.manifests[0];
}

fn isManifestListMediaType(media_type: ?[]const u8) bool {
    const mt = media_type orelse return false;
    return std.mem.eql(u8, mt, "application/vnd.oci.image.index.v1+json") or
        std.mem.eql(u8, mt, "application/vnd.docker.distribution.manifest.list.v2+json");
}

fn applyLayer(
    io: Io,
    allocator: Allocator,
    layout_dir: Io.Dir,
    entry_map: *StringHashMap(FileTree.Entry),
    layer_desc: Descriptor,
    options: LoadOptions,
) LoadError!void {
    if (layer_desc.mediaType) |media_type| {
        if (!isSupportedLayerMediaType(media_type)) return error.UnsupportedLayerMediaType;
    }
    const layer_blob = try readBlob(io, allocator, layout_dir, layer_desc.digest, options.max_blob_size);
    defer allocator.free(layer_blob);

    try applyLayerBytes(allocator, entry_map, layer_desc.mediaType, layer_blob, options);
}

fn applyLayerBytes(
    allocator: Allocator,
    entry_map: *StringHashMap(FileTree.Entry),
    media_type: ?[]const u8,
    layer_blob: []const u8,
    options: LoadOptions,
) LoadError!void {
    const layer_bytes = switch (detectCompression(media_type, layer_blob)) {
        .none => if (layer_blob.len > options.max_layer_size) return error.LayerTooLarge else try allocator.dupe(u8, layer_blob),
        .gzip => try decompressGzip(allocator, layer_blob, options.max_layer_size),
        .zstd => return error.UnsupportedLayerCompression,
    };
    defer allocator.free(layer_bytes);

    var lower_paths = std.array_list.Managed([]const u8).init(allocator);
    defer lower_paths.deinit();

    var existing_it = entry_map.iterator();
    while (existing_it.next()) |kv| {
        try lower_paths.append(kv.key_ptr.*);
    }

    var reader = tar.Reader.init(layer_bytes);
    while (try reader.next()) |layer_entry| {
        try applyLayerEntry(allocator, entry_map, lower_paths.items, layer_entry);
    }
}

const Compression = enum { none, gzip, zstd };

fn isSupportedLayerMediaType(media_type: []const u8) bool {
    return std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar") or
        std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar+gzip") or
        std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar+zstd") or
        std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.nondistributable.v1.tar") or
        std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.nondistributable.v1.tar+gzip") or
        std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.nondistributable.v1.tar+zstd") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.diff.tar") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.diff.tar.gzip") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.diff.tar.zstd") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.foreign.diff.tar") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.foreign.diff.tar.gzip");
}

fn detectCompression(media_type: ?[]const u8, bytes: []const u8) Compression {
    if (media_type) |mt| {
        if (std.mem.indexOf(u8, mt, "+zstd") != null or std.mem.endsWith(u8, mt, ".zstd")) return .zstd;
        if (std.mem.indexOf(u8, mt, "+gzip") != null or std.mem.endsWith(u8, mt, ".gzip")) return .gzip;
    }
    if (bytes.len >= 4 and bytes[0] == 0x28 and bytes[1] == 0xb5 and bytes[2] == 0x2f and bytes[3] == 0xfd) return .zstd;
    if (bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b) return .gzip;
    return .none;
}

fn decompressGzip(allocator: Allocator, bytes: []const u8, max_size: usize) LoadError![]u8 {
    var input = Io.Reader.fixed(bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    return decompressor.reader.allocRemaining(allocator, .limited(max_size)) catch |err| switch (err) {
        error.ReadFailed => error.LayerDecompressionFailed,
        error.StreamTooLong => error.LayerTooLarge,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn applyLayerEntry(
    allocator: Allocator,
    entry_map: *StringHashMap(FileTree.Entry),
    lower_paths: []const []const u8,
    layer_entry: tar.Entry,
) LoadError!void {
    const normalized_path = try normalizeLayerPath(allocator, layer_entry.path);
    defer allocator.free(normalized_path);

    if (normalized_path.len == 0) {
        if (layer_entry.kind == .directory) return;
        return error.InvalidLayerPath;
    }

    const dirname = parentPath(normalized_path);
    const basename = baseName(normalized_path);

    if (std.mem.eql(u8, basename, ".wh..wh..opq")) {
        try ensureParents(allocator, entry_map, dirname);
        if (dirname.len != 0) try upsertDirectory(allocator, entry_map, dirname, 0o755);
        try removeOpaqueLowerEntries(entry_map, allocator, lower_paths, dirname);
        return;
    }

    if (std.mem.startsWith(u8, basename, ".wh.") and basename.len > 4) {
        const target_path = try joinPath(allocator, dirname, basename[4..]);
        defer allocator.free(target_path);
        try removePathAndChildren(entry_map, allocator, target_path);
        return;
    }

    try ensureParents(allocator, entry_map, dirname);

    switch (layer_entry.kind) {
        .directory => try upsertDirectory(allocator, entry_map, normalized_path, nonZeroMode(layer_entry.mode, 0o755)),
        .file => {
            const content = try allocator.dupe(u8, layer_entry.content);
            errdefer allocator.free(content);
            const owned_path = try allocator.dupe(u8, normalized_path);
            errdefer allocator.free(owned_path);
            try putEntry(allocator, entry_map, .{
                .path = owned_path,
                .kind = .file,
                .mode = nonZeroMode(layer_entry.mode, 0o644),
                .size = content.len,
                .content = content,
            });
        },
        .symlink => {
            const link_name = try allocator.dupe(u8, layer_entry.link_name orelse return error.InvalidLayerPath);
            errdefer allocator.free(link_name);
            const owned_path = try allocator.dupe(u8, normalized_path);
            errdefer allocator.free(owned_path);
            try putEntry(allocator, entry_map, .{
                .path = owned_path,
                .kind = .symlink,
                .mode = nonZeroMode(layer_entry.mode, 0o777),
                .size = link_name.len,
                .link_name = link_name,
            });
        },
        .hardlink => {
            const link_name = try allocator.dupe(u8, layer_entry.link_name orelse return error.InvalidLayerPath);
            errdefer allocator.free(link_name);
            const owned_path = try allocator.dupe(u8, normalized_path);
            errdefer allocator.free(owned_path);
            try putEntry(allocator, entry_map, .{
                .path = owned_path,
                .kind = .hardlink,
                .mode = nonZeroMode(layer_entry.mode, 0o644),
                .size = 0,
                .link_name = link_name,
            });
        },
    }
}

fn normalizeLayerPath(allocator: Allocator, raw_path: []const u8) LoadError![]u8 {
    var path = raw_path;
    while (std.mem.startsWith(u8, path, "./")) path = path[2..];
    while (path.len > 0 and path[0] == '/') path = path[1..];

    var trimmed = path;
    while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    var first = true;
    var it = std.mem.splitScalar(u8, trimmed, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) return error.InvalidLayerPath;
        if (!first) out.writer.writeByte('/') catch return error.OutOfMemory;
        out.writer.writeAll(segment) catch return error.OutOfMemory;
        first = false;
    }

    return out.toOwnedSlice();
}

fn ensureParents(allocator: Allocator, entry_map: *StringHashMap(FileTree.Entry), path: []const u8) LoadError!void {
    if (path.len == 0) return;

    var cursor: usize = 0;
    while (cursor < path.len) {
        const slash = std.mem.indexOfScalarPos(u8, path, cursor, '/') orelse break;
        const parent = path[0..slash];
        try upsertDirectory(allocator, entry_map, parent, 0o755);
        cursor = slash + 1;
    }
    try upsertDirectory(allocator, entry_map, path, 0o755);
}

fn upsertDirectory(allocator: Allocator, entry_map: *StringHashMap(FileTree.Entry), path: []const u8, mode: u32) LoadError!void {
    if (path.len == 0) return;
    if (entry_map.getPtr(path)) |existing| {
        if (existing.kind == .directory) {
            existing.mode = mode;
            existing.size = 0;
            return;
        }
    }

    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try putEntry(allocator, entry_map, .{
        .path = owned_path,
        .kind = .directory,
        .mode = mode,
        .size = 0,
    });
}

fn putEntry(allocator: Allocator, entry_map: *StringHashMap(FileTree.Entry), entry: FileTree.Entry) LoadError!void {
    errdefer freeEntry(allocator, entry);

    if (entry.kind != .directory) {
        try removeChildrenOnly(entry_map, allocator, entry.path);
    }
    if (entry_map.fetchRemove(entry.path)) |removed| {
        freeEntry(allocator, removed.value);
    }
    try entry_map.put(entry.path, entry);
}

fn removePathAndChildren(entry_map: *StringHashMap(FileTree.Entry), allocator: Allocator, path: []const u8) LoadError!void {
    var doomed = std.array_list.Managed([]const u8).init(allocator);
    defer doomed.deinit();

    var it = entry_map.iterator();
    while (it.next()) |kv| {
        const candidate = kv.key_ptr.*;
        if (std.mem.eql(u8, candidate, path) or isDescendant(candidate, path)) {
            try doomed.append(candidate);
        }
    }

    for (doomed.items) |candidate| {
        if (entry_map.fetchRemove(candidate)) |removed| freeEntry(allocator, removed.value);
    }
}

fn removeChildrenOnly(entry_map: *StringHashMap(FileTree.Entry), allocator: Allocator, path: []const u8) LoadError!void {
    var doomed = std.array_list.Managed([]const u8).init(allocator);
    defer doomed.deinit();

    var it = entry_map.iterator();
    while (it.next()) |kv| {
        const candidate = kv.key_ptr.*;
        if (isDescendant(candidate, path)) try doomed.append(candidate);
    }

    for (doomed.items) |candidate| {
        if (entry_map.fetchRemove(candidate)) |removed| freeEntry(allocator, removed.value);
    }
}

fn removeOpaqueLowerEntries(
    entry_map: *StringHashMap(FileTree.Entry),
    allocator: Allocator,
    lower_paths: []const []const u8,
    directory: []const u8,
) LoadError!void {
    for (lower_paths) |candidate| {
        if (directory.len == 0) {
            if (entry_map.fetchRemove(candidate)) |removed| freeEntry(allocator, removed.value);
            continue;
        }
        if (isDescendant(candidate, directory)) {
            if (entry_map.fetchRemove(candidate)) |removed| freeEntry(allocator, removed.value);
        }
    }
}

fn joinPath(allocator: Allocator, parent: []const u8, child: []const u8) LoadError![]u8 {
    if (parent.len == 0) return allocator.dupe(u8, child);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, child });
}

fn isDescendant(candidate: []const u8, parent: []const u8) bool {
    return candidate.len > parent.len and
        std.mem.startsWith(u8, candidate, parent) and
        candidate[parent.len] == '/';
}

fn parentPath(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn nonZeroMode(mode: u32, fallback: u32) u32 {
    return if (mode == 0) fallback else mode;
}

fn freeEntry(allocator: Allocator, entry: FileTree.Entry) void {
    allocator.free(entry.path);
    if (entry.link_name) |link_name| allocator.free(link_name);
    if (entry.kind == .file) allocator.free(entry.content);
}

fn deinitArchiveEntries(entries: *StringHashMap(ArchiveEntry), allocator: Allocator) void {
    var it = entries.iterator();
    while (it.next()) |kv| allocator.free(kv.key_ptr.*);
    entries.deinit();
}

fn deinitEntryMap(entry_map: *StringHashMap(FileTree.Entry), allocator: Allocator) void {
    var it = entry_map.iterator();
    while (it.next()) |kv| {
        freeEntry(allocator, kv.value_ptr.*);
    }
    entry_map.deinit();
}

fn finalizeTree(allocator: Allocator, entry_map: *StringHashMap(FileTree.Entry)) LoadError!FileTree {
    const entries = try allocator.alloc(FileTree.Entry, entry_map.count());
    errdefer allocator.free(entries);

    var iter = entry_map.iterator();
    var index_out: usize = 0;
    while (iter.next()) |kv| {
        entries[index_out] = kv.value_ptr.*;
        index_out += 1;
    }
    entry_map.deinit();
    errdefer {
        var tree = FileTree{ .allocator = allocator, .entries = entries };
        tree.deinit();
    }

    std.mem.sort(FileTree.Entry, entries, {}, struct {
        fn lessThan(_: void, a: FileTree.Entry, b: FileTree.Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);

    return .{ .allocator = allocator, .entries = entries };
}

fn normalizeArchivePath(allocator: Allocator, raw_path: []const u8) LoadError![]u8 {
    return normalizeLayerPath(allocator, raw_path);
}

fn readBlob(io: Io, allocator: Allocator, layout_dir: Io.Dir, digest: []const u8, max_size: usize) LoadError![]u8 {
    if (!std.mem.startsWith(u8, digest, "sha256:")) return error.UnsupportedDigestAlgorithm;
    const hex = digest[7..];
    const path = try std.fmt.allocPrint(allocator, "blobs/sha256/{s}", .{hex});
    defer allocator.free(path);
    return readFileAtMost(io, allocator, layout_dir, path, max_size);
}

fn readFileAtMost(io: Io, allocator: Allocator, dir: Io.Dir, sub_path: []const u8, max_size: usize) LoadError![]u8 {
    var file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > max_size) return error.BlobTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

fn sha256DigestString(allocator: Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

test "load auto-detects OCI layouts and merges gzip layers, whiteouts, and opaque directories" {
    const io = std.testing.io;
    const fixture_root = "test-oci-layout-fixture";
    defer Io.Dir.cwd().deleteTree(io, fixture_root) catch {};

    var fixture = try createFixtureLayout(std.testing.allocator, io, fixture_root);
    defer fixture.deinit(std.testing.allocator);

    var image = try load(io, std.testing.allocator, fixture_root, .{});
    defer image.deinit();

    try std.testing.expectEqualStrings("amd64", image.config.architecture.?);
    try std.testing.expectEqualStrings("linux", image.config.os.?);

    const hello = image.get("hello.txt").?;
    try std.testing.expectEqual(EntryKind.file, hello.kind);
    try std.testing.expectEqualStrings("hello from top\n", hello.content);

    const keep = image.get("etc/keep.txt").?;
    try std.testing.expectEqualStrings("keep from base\n", keep.content);
    try std.testing.expect(image.get("etc/remove.txt") == null);

    const opaque_dir = image.get("etc/opaque").?;
    try std.testing.expectEqual(EntryKind.directory, opaque_dir.kind);
    try std.testing.expect(image.get("etc/opaque/from-base.txt") == null);
    const opaque_top = image.get("etc/opaque/from-top.txt").?;
    try std.testing.expectEqualStrings("top survives\n", opaque_top.content);

    const symlink = image.get("links/config").?;
    try std.testing.expectEqual(EntryKind.symlink, symlink.kind);
    try std.testing.expectEqualStrings("../etc/keep.txt", symlink.link_name.?);

    var iter = image.iterator();
    var seen: usize = 0;
    while (iter.next()) |_| seen += 1;
    try std.testing.expect(seen >= 7);
}

test "load auto-detects docker save tarballs and merges whiteouts" {
    const io = std.testing.io;
    const fixture_path = "test-docker-save-fixture.tar";
    defer Io.Dir.cwd().deleteFile(io, fixture_path) catch {};

    try createDockerSaveFixture(std.testing.allocator, io, fixture_path);

    var image = try load(io, std.testing.allocator, fixture_path, .{});
    defer image.deinit();

    try std.testing.expectEqualStrings("amd64", image.config.architecture.?);
    try std.testing.expectEqualStrings("linux", image.config.os.?);
    try std.testing.expect(std.mem.startsWith(u8, image.config.manifest_digest, "sha256:"));

    const hello = image.get("hello.txt").?;
    try std.testing.expectEqual(EntryKind.file, hello.kind);
    try std.testing.expectEqualStrings("hello from top\n", hello.content);

    const keep = image.get("etc/keep.txt").?;
    try std.testing.expectEqualStrings("keep from base\n", keep.content);
    try std.testing.expect(image.get("etc/remove.txt") == null);

    const opaque_dir = image.get("etc/opaque").?;
    try std.testing.expectEqual(EntryKind.directory, opaque_dir.kind);
    try std.testing.expect(image.get("etc/opaque/from-base.txt") == null);
    const opaque_top = image.get("etc/opaque/from-top.txt").?;
    try std.testing.expectEqualStrings("top survives\n", opaque_top.content);

    const symlink = image.get("links/config").?;
    try std.testing.expectEqual(EntryKind.symlink, symlink.kind);
    try std.testing.expectEqualStrings("../etc/keep.txt", symlink.link_name.?);
}

test "loadLayout rejects zstd layer media types" {
    const io = std.testing.io;
    const fixture_root = "test-oci-layout-zstd-fixture";
    defer Io.Dir.cwd().deleteTree(io, fixture_root) catch {};

    var fixture = try createFixtureLayout(std.testing.allocator, io, fixture_root);
    defer fixture.deinit(std.testing.allocator);

    var dir = try Io.Dir.cwd().openDir(io, fixture_root, .{});
    defer dir.close(io);

    const zstd_manifest_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schemaVersion\":2,\"config\":{{\"mediaType\":\"application/vnd.oci.image.config.v1+json\",\"digest\":\"{s}\",\"size\":{d}}},\"layers\":[{{\"mediaType\":\"application/vnd.oci.image.layer.v1.tar+zstd\",\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{ fixture.config_digest, fixture.config_json.len, fixture.layer1_digest, fixture.layer1_gzip.len },
    );
    defer std.testing.allocator.free(zstd_manifest_json);

    const zstd_manifest_digest = try writeBlobAndDigest(std.testing.allocator, io, dir, zstd_manifest_json);
    defer std.testing.allocator.free(zstd_manifest_digest);

    const zstd_index_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schemaVersion\":2,\"manifests\":[{{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{ zstd_manifest_digest, zstd_manifest_json.len },
    );
    defer std.testing.allocator.free(zstd_index_json);
    try dir.writeFile(io, .{ .sub_path = "index.json", .data = zstd_index_json });

    try std.testing.expectError(error.UnsupportedLayerCompression, loadLayout(io, std.testing.allocator, fixture_root, .{}));
}

const FixtureLayout = struct {
    layer1_tar: []u8,
    layer2_tar: []u8,
    layer1_gzip: []u8,
    layer2_gzip: []u8,
    config_digest: []u8,
    layer1_digest: []u8,
    layer2_digest: []u8,
    manifest_digest: []u8,
    config_json: []u8,
    manifest_json: []u8,
    index_json: []u8,

    fn deinit(self: *FixtureLayout, allocator: Allocator) void {
        allocator.free(self.layer1_tar);
        allocator.free(self.layer2_tar);
        allocator.free(self.layer1_gzip);
        allocator.free(self.layer2_gzip);
        allocator.free(self.config_digest);
        allocator.free(self.layer1_digest);
        allocator.free(self.layer2_digest);
        allocator.free(self.manifest_digest);
        allocator.free(self.config_json);
        allocator.free(self.manifest_json);
        allocator.free(self.index_json);
        self.* = undefined;
    }
};

fn createFixtureLayout(allocator: Allocator, io: Io, root: []const u8) !FixtureLayout {
    try Io.Dir.cwd().createDirPath(io, root);
    var dir = try Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "blobs/sha256");

    const layer1_tar = try buildTarArchive(allocator, &.{
        .{ .path = "etc/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "etc/keep.txt", .mode = 0o644, .typeflag = '0', .content = "keep from base\n", .link_name = null },
        .{ .path = "etc/remove.txt", .mode = 0o644, .typeflag = '0', .content = "remove me\n", .link_name = null },
        .{ .path = "etc/opaque/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "etc/opaque/from-base.txt", .mode = 0o644, .typeflag = '0', .content = "base hidden\n", .link_name = null },
        .{ .path = "hello.txt", .mode = 0o644, .typeflag = '0', .content = "hello from base\n", .link_name = null },
        .{ .path = "links/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "links/config", .mode = 0o777, .typeflag = '2', .content = "", .link_name = "../etc/keep.txt" },
    });
    const layer2_tar = try buildTarArchive(allocator, &.{
        .{ .path = "etc/.wh.remove.txt", .mode = 0o000, .typeflag = '0', .content = "", .link_name = null },
        .{ .path = "etc/opaque/.wh..wh..opq", .mode = 0o000, .typeflag = '0', .content = "", .link_name = null },
        .{ .path = "etc/opaque/from-top.txt", .mode = 0o644, .typeflag = '0', .content = "top survives\n", .link_name = null },
        .{ .path = "hello.txt", .mode = 0o644, .typeflag = '0', .content = "hello from top\n", .link_name = null },
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
        .layer1_tar = layer1_tar,
        .layer2_tar = layer2_tar,
        .layer1_gzip = layer1_gzip,
        .layer2_gzip = layer2_gzip,
        .config_digest = config_digest,
        .layer1_digest = layer1_digest,
        .layer2_digest = layer2_digest,
        .manifest_digest = manifest_digest,
        .config_json = config_json,
        .manifest_json = manifest_json,
        .index_json = index_json,
    };
}

fn createDockerSaveFixture(allocator: Allocator, io: Io, tarball_path: []const u8) !void {
    const layer1_tar = try buildTarArchive(allocator, &.{
        .{ .path = "etc/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "etc/keep.txt", .mode = 0o644, .typeflag = '0', .content = "keep from base\n", .link_name = null },
        .{ .path = "etc/remove.txt", .mode = 0o644, .typeflag = '0', .content = "remove me\n", .link_name = null },
        .{ .path = "etc/opaque/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "etc/opaque/from-base.txt", .mode = 0o644, .typeflag = '0', .content = "base hidden\n", .link_name = null },
        .{ .path = "hello.txt", .mode = 0o644, .typeflag = '0', .content = "hello from base\n", .link_name = null },
        .{ .path = "links/", .mode = 0o755, .typeflag = '5', .content = "", .link_name = null },
        .{ .path = "links/config", .mode = 0o777, .typeflag = '2', .content = "", .link_name = "../etc/keep.txt" },
    });
    defer allocator.free(layer1_tar);

    const layer2_tar = try buildTarArchive(allocator, &.{
        .{ .path = "etc/.wh.remove.txt", .mode = 0o000, .typeflag = '0', .content = "", .link_name = null },
        .{ .path = "etc/opaque/.wh..wh..opq", .mode = 0o000, .typeflag = '0', .content = "", .link_name = null },
        .{ .path = "etc/opaque/from-top.txt", .mode = 0o644, .typeflag = '0', .content = "top survives\n", .link_name = null },
        .{ .path = "hello.txt", .mode = 0o644, .typeflag = '0', .content = "hello from top\n", .link_name = null },
    });
    defer allocator.free(layer2_tar);

    const config_json = try std.fmt.allocPrint(
        allocator,
        "{{\"architecture\":\"amd64\",\"os\":\"linux\",\"rootfs\":{{\"type\":\"layers\",\"diff_ids\":[]}}}}",
        .{},
    );
    defer allocator.free(config_json);

    const repositories_json =
        "{\"example.com/test\":{\"latest\":\"2222222222222222222222222222222222222222222222222222222222222222\"}}";

    const outer_tar = try buildTarArchive(allocator, &.{
        .{ .path = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json", .mode = 0o644, .typeflag = '0', .content = config_json, .link_name = null },
        .{ .path = "1111111111111111111111111111111111111111111111111111111111111111/layer.tar", .mode = 0o644, .typeflag = '0', .content = layer1_tar, .link_name = null },
        .{ .path = "2222222222222222222222222222222222222222222222222222222222222222/layer.tar", .mode = 0o644, .typeflag = '0', .content = layer2_tar, .link_name = null },
        .{
            .path = "manifest.json",
            .mode = 0o644,
            .typeflag = '0',
            .content =
            "[{\"Config\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json\",\"RepoTags\":[\"example.com/test:latest\"],\"Layers\":[\"1111111111111111111111111111111111111111111111111111111111111111/layer.tar\",\"2222222222222222222222222222222222222222222222222222222222222222/layer.tar\"]}]",
            .link_name = null,
        },
        .{ .path = "repositories", .mode = 0o644, .typeflag = '0', .content = repositories_json, .link_name = null },
    });
    defer allocator.free(outer_tar);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tarball_path, .data = outer_tar });
}

fn writeBlobAndDigest(allocator: Allocator, io: Io, dir: Io.Dir, data: []const u8) ![]u8 {
    const digest_string = try sha256DigestString(allocator, data);
    const blob_path = try std.fmt.allocPrint(allocator, "blobs/sha256/{s}", .{digest_string[7..]});
    defer allocator.free(blob_path);
    try dir.writeFile(io, .{ .sub_path = blob_path, .data = data });
    return digest_string;
}

const TarSpec = struct {
    path: []const u8,
    mode: u32,
    typeflag: u8,
    content: []const u8,
    link_name: ?[]const u8,
};

fn buildTarArchive(allocator: Allocator, specs: []const TarSpec) ![]u8 {
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

fn gzipBytes(allocator: Allocator, data: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, @max(@as(usize, 64), data.len));
    errdefer out.deinit();

    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&out.writer, &history, .gzip, .default);
    try compressor.writer.writeAll(data);
    try compressor.finish();
    return out.toOwnedSlice();
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
