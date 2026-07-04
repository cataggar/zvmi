//! Native ext4 writer + readback helper for image building.
//!
//! Feature flags intentionally stay within a conservative, fsck-friendly
//! subset:
//!   - `feature_compat = EXT_ATTR | DIR_INDEX`: external xattr blocks are
//!     supported, and directories that outgrow a single leaf block are written
//!     with one-level htree indexes. `HAS_JOURNAL`, `RESIZE_INODE`, and quota
//!     bits remain unset; this writer deliberately ships a permanently
//!     journal-less filesystem for now because the target image-build flow
//!     creates filesystems offline and writes them atomically.
//!   - `feature_incompat = FILETYPE | EXTENTS`: directory entries carry the
//!     ext4 file-type byte, and regular-file / directory payloads are mapped
//!     with extents.
//!   - `feature_ro_compat = SPARSE_SUPER | METADATA_CSUM` (plus `LARGE_FILE`
//!     only when a file exceeds 2 GiB): sparse backup superblocks/group-
//!     descriptor tables are written for groups selected by ext4's classic
//!     sparse-super rule, and metadata-bearing structures are checksummed with
//!     crc32c.
//!
//! Deliberate phase-2 non-goals: no journal replay/log writing and no quota
//! files. Extents stay inline for small files, but larger fragmented files now
//! spill into standard ext4 extent/index blocks with recursive readback
//! support. With 4 KiB blocks this writer supports extent-tree depths up to 4,
//! which is enough to cover the filesystem's 32-bit logical-block space.
//! Resizing is supported as an offline, in-place grow operation that rewrites
//! the superblock/GDTs and initializes new block groups without enabling
//! ext4's separate `RESIZE_INODE` online-resize scaffolding.

const std = @import("std");
const Io = std.Io;

pub const default_block_size: u32 = 4096;
pub const default_blocks_per_group: u32 = 32 * 1024;
pub const root_inode: u32 = 2;
pub const first_non_reserved_inode: u32 = 11;

const inode_size: u16 = 128;
const group_desc_size: u16 = 32;
const max_inline_extents: usize = 4;
const max_supported_extent_depth: u16 = 4;
const superblock_size: usize = 1024;
const superblock_offset: u64 = 1024;
const dir_entry_alignment: usize = 4;
const sectors_per_block: u32 = default_block_size / 512;
const extent_header_size: usize = 12;
const extent_entry_size: usize = 12;

const super_magic: u16 = 0xEF53;
const state_clean: u16 = 0x0001;
const errors_continue: u16 = 0x0001;
const creator_os_linux: u32 = 0;
const rev_dynamic: u32 = 1;

const feature_compat_has_journal: u32 = 0x0004;
const feature_compat_ext_attr: u32 = 0x0008;
const feature_compat_resize_inode: u32 = 0x0010;
const feature_compat_dir_index: u32 = 0x0020;
const feature_incompat_filetype: u32 = 0x0002;
const feature_incompat_extents: u32 = 0x0040;
const feature_ro_compat_sparse_super: u32 = 0x0001;
const feature_ro_compat_large_file: u32 = 0x0002;
const feature_ro_compat_metadata_csum: u32 = 0x0400;
const writer_feature_compat: u32 = feature_compat_ext_attr | feature_compat_dir_index;
const writer_feature_incompat: u32 = feature_incompat_filetype | feature_incompat_extents;
const writer_feature_ro_compat_base: u32 = feature_ro_compat_sparse_super | feature_ro_compat_metadata_csum;

const inode_flag_index: u32 = 0x0000_1000;
const inode_flag_extents: u32 = 0x0008_0000;

const mode_dir: u16 = 0o040000;
const mode_reg: u16 = 0o100000;
const mode_symlink: u16 = 0o120000;

const dir_ft_unknown: u8 = 0;
const dir_ft_reg: u8 = 1;
const dir_ft_dir: u8 = 2;
const dir_ft_symlink: u8 = 7;
const dir_ft_checksum: u8 = 0xDE;

const extent_magic: u16 = 0xF30A;
const ext4_xattr_magic: u32 = 0xEA02_0000;
const dx_hash_half_md4: u8 = 0x1;
const super_checksum_type_crc32c: u8 = 0x1;
const xattr_name_user: u8 = 1;
const xattr_name_trusted: u8 = 4;
const xattr_name_security: u8 = 6;

pub const Kind = enum(u8) {
    directory,
    file,
    symlink,
};

pub const PopulateOptions = struct {
    /// Byte offset within `file` where the filesystem starts.
    offset: u64 = 0,
    /// Total filesystem size, in bytes. Must be a multiple of `block_size`.
    length: u64,
    /// Only 4096-byte blocks are currently supported.
    block_size: u32 = default_block_size,
    /// Optional volume label, truncated at 16 bytes.
    label: []const u8 = "",
    /// If omitted, a zero UUID is written.
    uuid: ?[16]u8 = null,
    /// POSIX seconds timestamp written to the superblock/inodes.
    timestamp: u32 = 0,
};

pub const ResizeOptions = struct {
    offset: u64 = 0,
    length: u64,
};

pub const FilesystemInfo = struct {
    block_count: u32,
    free_block_count: u32,
    inode_count: u32,
    free_inode_count: u32,
    group_count: u32,
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,
};

pub const Stat = struct {
    inode: u32,
    kind: Kind,
    mode: u16,
    uid: u32,
    gid: u32,
    size: u64,
};

pub const Extent = struct {
    logical_block: u32,
    start_block: u64,
    block_count: u16,
};

pub const DirEntry = struct {
    inode: u32,
    kind: Kind,
    name: []u8,
};

pub fn freeDirEntries(allocator: std.mem.Allocator, entries: []DirEntry) void {
    for (entries) |entry| allocator.free(entry.name);
    allocator.free(entries);
}

pub const Xattr = struct {
    name: []const u8,
    value: []const u8,
};

pub const OwnedXattr = struct {
    name: []u8,
    value: []u8,
};

pub fn freeXattrs(allocator: std.mem.Allocator, xattrs: []OwnedXattr) void {
    for (xattrs) |xattr| {
        allocator.free(xattr.name);
        allocator.free(xattr.value);
    }
    allocator.free(xattrs);
}

/// Small, self-contained tree-population interface for future ingestion
/// modules to adapt to. `populate()` resets the view once, consumes every
/// yielded entry, sorts them by path depth/name, and then writes the full
/// filesystem image in one pass. The root directory is implicit; entries must
/// use relative paths like `boot/kernel` rather than `/boot/kernel`.
pub const FileTreeView = struct {
    ctx: *anyopaque,
    next_fn: *const fn (ctx: *anyopaque) IteratorError!?Entry,
    reset_fn: *const fn (ctx: *anyopaque) void,

    pub const IteratorError = error{EnumerationFailed};
    pub const ContentError = error{ReadFailed, UnexpectedEndOfStream};

    pub const ContentReader = struct {
        ctx: *const anyopaque,
        read_at_fn: *const fn (ctx: *const anyopaque, buffer: []u8, offset: u64) ContentError!usize,

        pub fn readAt(self: ContentReader, buffer: []u8, offset: u64) ContentError!usize {
            return self.read_at_fn(self.ctx, buffer, offset);
        }
    };

    pub const Entry = struct {
        /// Relative UTF-8/byte path using `/` separators, without a leading `/`.
        path: []const u8,
        kind: Kind,
        /// Unix permission/sticky bits only; the file type comes from `kind`.
        mode: u16,
        uid: u32,
        gid: u32,
        /// Regular-file byte length, symlink-target byte length, or 0 for dirs.
        size: u64,
        /// Required for non-empty regular files and symlinks.
        content: ?ContentReader = null,
        /// Optional extended attributes such as `user.*` or `security.*`.
        xattrs: []const Xattr = &.{},
    };

    pub fn reset(self: *FileTreeView) void {
        self.reset_fn(self.ctx);
    }

    pub fn next(self: *FileTreeView) IteratorError!?Entry {
        return self.next_fn(self.ctx);
    }
};

pub const PopulateError = std.mem.Allocator.Error || Io.File.ReadPositionalError ||
    Io.File.WritePositionalError || Io.File.SetLengthError || Io.File.StatError ||
    FileTreeView.IteratorError || FileTreeView.ContentError || error{
    UnsupportedBlockSize,
    InvalidRange,
    LabelTooLong,
    InvalidPath,
    RootEntryForbidden,
    DuplicatePath,
    MissingParentDirectory,
    ParentNotDirectory,
    MissingContentReader,
    UnexpectedContentLength,
    InvalidDirectorySize,
    NotEnoughSpace,
    TooManyExtents,
    TooManyInodes,
    FilesystemTooLarge,
    InvalidXattr,
    XattrTooLarge,
};

pub const OpenError = std.mem.Allocator.Error || Io.File.ReadPositionalError || error{
    BadMagic,
    UnsupportedBlockSize,
    UnsupportedDescriptorSize,
    UnsupportedFeatures,
    UnsupportedInodeSize,
    UnsupportedRevision,
};

pub const ReadError = std.mem.Allocator.Error || Io.File.ReadPositionalError || error{
    NotFound,
    NotDirectory,
    NotFile,
    NotSymlink,
    BadDirectoryEntry,
    UnsupportedExtentDepth,
    UnsupportedInodeLayout,
    FileTooLarge,
    XattrNotFound,
};

pub const ResizeError = PopulateError || OpenError || Io.File.ReadPositionalError || Io.File.WritePositionalError ||
    Io.File.SetLengthError || Io.File.StatError || std.mem.Allocator.Error || error{
    InvalidRange,
    ShrinkNotSupported,
    UnsupportedResizeLayout,
    FilesystemTooLarge,
};

const OwnedEntry = struct {
    path: []u8,
    kind: Kind,
    mode: u16,
    uid: u32,
    gid: u32,
    size: u64,
    content: ?FileTreeView.ContentReader,
    xattrs: []OwnedXattr,
};

const Node = struct {
    path: []const u8,
    name: []const u8,
    parent_path: []const u8,
    parent_index: usize,
    inode: u32,
    kind: Kind,
    mode: u16,
    uid: u32,
    gid: u32,
    declared_size: u64,
    content: ?FileTreeView.ContentReader,
    xattrs: []OwnedXattr,
    dir_bytes: ?[]u8 = null,
    xattr_block_bytes: ?[]u8 = null,
    size_on_disk: u64 = 0,
    data_block_count: u32 = 0,
    extents: []Extent = &.{},
    extent_root: [60]u8 = [_]u8{0} ** 60,
    extent_tree_blocks: []ExtentTreeBlock = &.{},
    xattr_block: ?u64 = null,
    link_count: u16 = 1,
    uses_fast_symlink: bool = false,
    uses_hashed_directory: bool = false,
};

const ExtentHeader = struct {
    entries: u16,
    max: u16,
    depth: u16,
    generation: u32,
};

const ExtentIndex = struct {
    logical_block: u32,
    leaf_block: u64,
};

const ExtentTreeBlock = struct {
    block_number: u64,
    bytes: [default_block_size]u8 = [_]u8{0} ** default_block_size,
};

const ExtentNodeRef = struct {
    logical_block: u32,
    block_number: u64,
};

const Layout = struct {
    total_blocks: u32,
    group_count: u32,
    gdt_blocks: u32,
    inodes_per_group: u32,
    inode_table_blocks: u32,
    groups: []GroupLayout,
};

const GroupLayout = struct {
    index: u32,
    start_block: u64,
    block_count: u32,
    has_super_copy: bool,
    block_bitmap_block: u32,
    inode_bitmap_block: u32,
    inode_table_block: u32,
    data_start_block: u64,
    reserved_block_count: u32,
    data_capacity: u32,
    used_data_blocks: u32 = 0,
    used_inode_count: u32 = 0,
    used_dir_count: u32 = 0,
};

const WriterPlan = struct {
    entries: []OwnedEntry,
    nodes: []Node,
    feature_ro_compat: u32,
    data_blocks_needed: u32,

    fn deinit(self: *WriterPlan, allocator: std.mem.Allocator) void {
        for (self.nodes) |node| {
            if (node.dir_bytes) |bytes| allocator.free(bytes);
            if (node.xattr_block_bytes) |bytes| allocator.free(bytes);
            if (node.extents.len > 0) allocator.free(node.extents);
            if (node.extent_tree_blocks.len > 0) allocator.free(node.extent_tree_blocks);
            for (node.xattrs) |xattr| {
                allocator.free(xattr.name);
                allocator.free(xattr.value);
            }
            allocator.free(node.xattrs);
        }
        allocator.free(self.nodes);
        for (self.entries) |entry| allocator.free(entry.path);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

/// Formats a fresh ext4 filesystem inside `file[options.offset .. options.offset + options.length)`,
/// writes the supplied tree, and returns the resulting geometry/feature bits.
pub fn populate(
    io: Io,
    file: Io.File,
    allocator: std.mem.Allocator,
    tree: *FileTreeView,
    options: PopulateOptions,
) PopulateError!FilesystemInfo {
    if (options.block_size != default_block_size) return error.UnsupportedBlockSize;
    if (options.length == 0 or options.length % options.block_size != 0) return error.InvalidRange;
    if (options.label.len > 16) return error.LabelTooLong;

    const total_blocks64 = options.length / options.block_size;
    const total_blocks = std.math.cast(u32, total_blocks64) orelse return error.FilesystemTooLarge;

    const stat = try file.stat(io);
    if (stat.size < options.offset + options.length) {
        try file.setLength(io, options.offset + options.length);
    }

    var plan = try buildPlan(allocator, tree, options);
    defer plan.deinit(allocator);

    var layout = try buildLayout(allocator, total_blocks, plan.nodes.len, plan.data_blocks_needed);
    defer allocator.free(layout.groups);

    assignInodesToGroups(plan.nodes, layout.groups, layout.inodes_per_group);
    const free_blocks_before = countFreeBlocks(layout.groups);
    if (plan.data_blocks_needed > free_blocks_before) return error.NotEnoughSpace;

    try allocateNodeBlocks(allocator, plan.nodes, &layout);
    try writeNodeData(io, file, plan.nodes, options);
    try zeroUnusedInodeTableBlocks(io, file, layout, options.offset);
    try writeBitmaps(io, file, layout, options.offset);
    try writeInodes(io, file, plan.nodes, layout, options);
    try writeGroupDescriptorTables(io, file, layout, options.offset, options.uuid orelse [_]u8{0} ** 16);
    try writeSuperblocks(io, file, layout, plan, options);

    return .{
        .block_count = layout.total_blocks,
        .free_block_count = countFreeBlocks(layout.groups),
        .inode_count = layout.group_count * layout.inodes_per_group,
        .free_inode_count = countFreeInodes(layout.groups, layout.inodes_per_group),
        .group_count = layout.group_count,
        .feature_compat = writer_feature_compat,
        .feature_incompat = writer_feature_incompat,
        .feature_ro_compat = plan.feature_ro_compat,
    };
}

/// Grow an ext4 filesystem in place by extending the final block group or
/// appending new groups; this deliberately does not emulate online
/// `resize_inode` journaling/reservation machinery.
pub fn resize(io: Io, file: Io.File, allocator: std.mem.Allocator, options: ResizeOptions) ResizeError!FilesystemInfo {
    if (options.length == 0 or options.length % default_block_size != 0) return error.InvalidRange;

    var sb: [superblock_size]u8 = undefined;
    _ = try file.readPositionalAll(io, &sb, options.offset + superblock_offset);
    if (readInt(u16, sb[0x38..0x3A]) != super_magic) return error.BadMagic;
    if (readInt(u32, sb[0x4C..0x50]) != rev_dynamic) return error.UnsupportedRevision;
    if ((@as(u32, 1024) << @intCast(readInt(u32, sb[0x18..0x1C]))) != default_block_size) return error.UnsupportedBlockSize;

    const compat = readInt(u32, sb[0x5C..0x60]);
    const incompat = readInt(u32, sb[0x60..0x64]);
    const ro_compat = readInt(u32, sb[0x64..0x68]);
    if (compat & ~(writer_feature_compat | feature_compat_has_journal | feature_compat_resize_inode) != 0) return error.UnsupportedFeatures;
    if (compat & feature_compat_has_journal != 0) return error.UnsupportedResizeLayout;
    if (incompat != writer_feature_incompat) return error.UnsupportedFeatures;
    if (ro_compat & ~(writer_feature_ro_compat_base | feature_ro_compat_large_file) != 0) return error.UnsupportedFeatures;

    const old_total_blocks = readInt(u32, sb[0x04..0x08]);
    const new_total_blocks = std.math.cast(u32, options.length / default_block_size) orelse return error.FilesystemTooLarge;
    if (new_total_blocks < old_total_blocks) return error.ShrinkNotSupported;
    if (new_total_blocks == old_total_blocks) {
        return .{
            .block_count = old_total_blocks,
            .free_block_count = readInt(u32, sb[0x0C..0x10]),
            .inode_count = readInt(u32, sb[0x00..0x04]),
            .free_inode_count = readInt(u32, sb[0x10..0x14]),
            .group_count = blocksToGroups(old_total_blocks, readInt(u32, sb[0x20..0x24])),
            .feature_compat = compat,
            .feature_incompat = incompat,
            .feature_ro_compat = ro_compat,
        };
    }

    const desc_size = blk: {
        const raw = readInt(u16, sb[0xFE..0x100]);
        break :blk if (raw == 0) @as(u16, 32) else raw;
    };
    if (desc_size != group_desc_size) return error.UnsupportedDescriptorSize;

    const blocks_per_group = readInt(u32, sb[0x20..0x24]);
    const inodes_per_group = readInt(u32, sb[0x28..0x2C]);
    const inode_size_on_disk = readInt(u16, sb[0x58..0x5A]);
    if (blocks_per_group != default_blocks_per_group or inode_size_on_disk != inode_size) return error.UnsupportedResizeLayout;

    const old_group_count = blocksToGroups(old_total_blocks, blocks_per_group);
    const new_group_count = blocksToGroups(new_total_blocks, blocks_per_group);
    const old_gdt_blocks = blocksForBytes(@as(u64, old_group_count) * group_desc_size, default_block_size);
    const required_new_gdt_blocks = blocksForBytes(@as(u64, new_group_count) * group_desc_size, default_block_size);
    if (required_new_gdt_blocks > old_gdt_blocks) return error.UnsupportedResizeLayout;
    const inode_table_blocks = divCeil(@as(u32, inodes_per_group) * inode_size, default_block_size);

    const old_layout = try buildFixedLayout(allocator, old_total_blocks, blocks_per_group, inodes_per_group, inode_table_blocks, old_gdt_blocks);
    defer allocator.free(old_layout.groups);
    var new_layout = try buildFixedLayout(allocator, new_total_blocks, blocks_per_group, inodes_per_group, inode_table_blocks, old_gdt_blocks);
    defer allocator.free(new_layout.groups);

    const gdt_bytes = @as(usize, old_group_count) * group_desc_size;
    const gdt_storage_bytes = @as(usize, old_gdt_blocks) * default_block_size;
    const old_gdt = try allocator.alloc(u8, gdt_storage_bytes);
    defer allocator.free(old_gdt);
    @memset(old_gdt, 0);
    _ = try file.readPositionalAll(io, old_gdt, options.offset + default_block_size);
    _ = gdt_bytes;

    for (old_layout.groups, 0..) |old_group, index| {
        const base = index * group_desc_size;
        const free_blocks = readInt(u16, old_gdt[base + 12 .. base + 14]);
        const free_inodes = readInt(u16, old_gdt[base + 14 .. base + 16]);
        const used_dirs = readInt(u16, old_gdt[base + 16 .. base + 18]);
        new_layout.groups[index].used_data_blocks = old_group.data_capacity - free_blocks;
        new_layout.groups[index].used_inode_count = inodes_per_group - free_inodes;
        new_layout.groups[index].used_dir_count = used_dirs;
    }

    const stat = try file.stat(io);
    if (stat.size < options.offset + options.length) try file.setLength(io, options.offset + options.length);

    if (new_group_count > old_group_count) {
        var group_index = old_group_count;
        while (group_index < new_group_count) : (group_index += 1) {
            var zero_block: [default_block_size]u8 = [_]u8{0} ** default_block_size;
            var block: u32 = 0;
            while (block < inode_table_blocks) : (block += 1) {
                try file.writePositionalAll(io, &zero_block, options.offset + (@as(u64, new_layout.groups[group_index].inode_table_block) + block) * default_block_size);
            }
        }
    }

    try writeBitmaps(io, file, new_layout, options.offset);

    var uuid: [16]u8 = undefined;
    @memcpy(&uuid, sb[0x68..0x78]);
    try writeGroupDescriptorTables(io, file, new_layout, options.offset, uuid);

    writeInt(u32, sb[0x00..0x04], new_group_count * inodes_per_group);
    writeInt(u32, sb[0x04..0x08], new_total_blocks);
    writeInt(u32, sb[0x0C..0x10], countFreeBlocks(new_layout.groups));
    writeInt(u32, sb[0x10..0x14], countFreeInodes(new_layout.groups, inodes_per_group));
    writeInt(u32, sb[0x20..0x24], blocks_per_group);
    writeInt(u32, sb[0x24..0x28], blocks_per_group);
    writeInt(u32, sb[0x28..0x2C], inodes_per_group);
    writeInt(u16, sb[0x5A..0x5C], 0);
    setSuperblockChecksum(&sb);
    try file.writePositionalAll(io, &sb, options.offset + superblock_offset);
    for (new_layout.groups) |group| {
        if (group.index == 0 or !group.has_super_copy) continue;
        writeInt(u16, sb[0x5A..0x5C], @intCast(group.index));
        setSuperblockChecksum(&sb);
        try file.writePositionalAll(io, &sb, options.offset + group.start_block * default_block_size);
    }

    return .{
        .block_count = new_total_blocks,
        .free_block_count = countFreeBlocks(new_layout.groups),
        .inode_count = new_group_count * inodes_per_group,
        .free_inode_count = countFreeInodes(new_layout.groups, inodes_per_group),
        .group_count = new_group_count,
        .feature_compat = compat,
        .feature_incompat = incompat,
        .feature_ro_compat = ro_compat,
    };
}

pub const OpenOptions = struct {
    offset: u64 = 0,
};

pub const Reader = struct {
    file: Io.File,
    allocator: std.mem.Allocator,
    offset: u64,
    uuid: [16]u8,
    block_size: u32,
    total_blocks: u32,
    total_inodes: u32,
    blocks_per_group: u32,
    inodes_per_group: u32,
    inode_size: u16,
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,
    groups: []ReaderGroup,

    pub fn open(io: Io, file: Io.File, allocator: std.mem.Allocator, options: OpenOptions) OpenError!Reader {
        var sb: [superblock_size]u8 = undefined;
        _ = try file.readPositionalAll(io, &sb, options.offset + superblock_offset);
        if (readInt(u16, sb[0x38..0x3A]) != super_magic) return error.BadMagic;
        if (readInt(u32, sb[0x4C..0x50]) != rev_dynamic) return error.UnsupportedRevision;

        const block_size = @as(u32, 1024) << @intCast(readInt(u32, sb[0x18..0x1C]));
        if (block_size != default_block_size) return error.UnsupportedBlockSize;

        const incompat = readInt(u32, sb[0x60..0x64]);
        const ro_compat = readInt(u32, sb[0x64..0x68]);
        const compat = readInt(u32, sb[0x5C..0x60]);
        if (compat & ~(writer_feature_compat | feature_compat_has_journal | feature_compat_resize_inode) != 0) return error.UnsupportedFeatures;
        if (incompat & ~writer_feature_incompat != 0) return error.UnsupportedFeatures;
        if (ro_compat & ~(writer_feature_ro_compat_base | feature_ro_compat_large_file) != 0) return error.UnsupportedFeatures;

        var uuid: [16]u8 = undefined;
        @memcpy(&uuid, sb[0x68..0x78]);

        const desc_size = blk: {
            const raw = readInt(u16, sb[0xFE..0x100]);
            break :blk if (raw == 0) @as(u16, 32) else raw;
        };
        if (desc_size != group_desc_size) return error.UnsupportedDescriptorSize;

        const total_blocks = readInt(u32, sb[0x04..0x08]);
        const total_inodes = readInt(u32, sb[0x00..0x04]);
        const blocks_per_group = readInt(u32, sb[0x20..0x24]);
        const inodes_per_group = readInt(u32, sb[0x28..0x2C]);
        const inode_size_on_disk = readInt(u16, sb[0x58..0x5A]);
        if (inode_size_on_disk != inode_size) return error.UnsupportedInodeSize;
        const group_count = blocksToGroups(total_blocks, blocks_per_group);

        const groups = try allocator.alloc(ReaderGroup, group_count);
        errdefer allocator.free(groups);

        const gdt_bytes = @as(usize, group_count) * desc_size;
        const gdt_storage_bytes = @as(usize, blocksForBytes(gdt_bytes, block_size)) * block_size;
        const gdt = try allocator.alloc(u8, gdt_storage_bytes);
        defer allocator.free(gdt);
        @memset(gdt, 0);
        _ = try file.readPositionalAll(io, gdt, options.offset + @as(u64, block_size));
        var group_index: u32 = 0;
        while (group_index < group_count) : (group_index += 1) {
            const base = @as(usize, group_index) * desc_size;
            groups[group_index] = .{
                .block_bitmap_block = readInt(u32, gdt[base + 0 .. base + 4]),
                .inode_bitmap_block = readInt(u32, gdt[base + 4 .. base + 8]),
                .inode_table_block = readInt(u32, gdt[base + 8 .. base + 12]),
            };
        }

        return .{
            .file = file,
            .allocator = allocator,
            .offset = options.offset,
            .uuid = uuid,
            .block_size = block_size,
            .total_blocks = total_blocks,
            .total_inodes = total_inodes,
            .blocks_per_group = blocks_per_group,
            .inodes_per_group = inodes_per_group,
            .inode_size = inode_size_on_disk,
            .feature_compat = compat,
            .feature_incompat = incompat,
            .feature_ro_compat = ro_compat,
            .groups = groups,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.allocator.free(self.groups);
        self.* = undefined;
    }

    pub fn statPath(self: Reader, io: Io, path: []const u8) ReadError!Stat {
        const inode_number = try self.lookupPath(io, path);
        const inode = try self.readInode(io, inode_number);
        return inode.stat();
    }

    pub fn listDir(self: Reader, io: Io, allocator: std.mem.Allocator, path: []const u8) ReadError![]DirEntry {
        const inode_number = try self.lookupPath(io, path);
        const inode = try self.readInode(io, inode_number);
        if (inode.kind != .directory) return error.NotDirectory;

        const data = try self.readInodeDataAlloc(io, allocator, inode);
        defer allocator.free(data);

        var entries = std.array_list.Managed(DirEntry).init(allocator);
        errdefer {
            for (entries.items) |entry| allocator.free(entry.name);
            entries.deinit();
        }

        var offset: usize = 0;
        while (offset + 8 <= data.len) {
            const child_inode = readInt(u32, data[offset .. offset + 4]);
            const rec_len = readInt(u16, data[offset + 4 .. offset + 6]);
            const name_len = data[offset + 6];
            const file_type = data[offset + 7];
            if (rec_len < 8 or offset + rec_len > data.len) return error.BadDirectoryEntry;
            if (name_len > rec_len - 8) return error.BadDirectoryEntry;
            const name = data[offset + 8 .. offset + 8 + name_len];
            if (child_inode != 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                try entries.append(.{
                    .inode = child_inode,
                    .kind = dirFileTypeToKind(file_type),
                    .name = try allocator.dupe(u8, name),
                });
            }
            offset += rec_len;
        }
        return entries.toOwnedSlice();
    }

    pub fn readFileAlloc(self: Reader, io: Io, allocator: std.mem.Allocator, path: []const u8) ReadError![]u8 {
        const inode_number = try self.lookupPath(io, path);
        const inode = try self.readInode(io, inode_number);
        if (inode.kind != .file) return error.NotFile;
        return self.readInodeDataAlloc(io, allocator, inode);
    }

    pub fn readLinkAlloc(self: Reader, io: Io, allocator: std.mem.Allocator, path: []const u8) ReadError![]u8 {
        const inode_number = try self.lookupPath(io, path);
        const inode = try self.readInode(io, inode_number);
        if (inode.kind != .symlink) return error.NotSymlink;
        return self.readInodeDataAlloc(io, allocator, inode);
    }

    pub fn preadPath(self: Reader, io: Io, path: []const u8, buffer: []u8, offset: u64) ReadError!usize {
        const inode_number = try self.lookupPath(io, path);
        const inode = try self.readInode(io, inode_number);
        if (inode.kind != .file) return error.NotFile;
        return self.preadInode(io, inode, buffer, offset);
    }

    pub fn readExtents(self: Reader, io: Io, allocator: std.mem.Allocator, path: []const u8) ReadError![]Extent {
        const inode_number = try self.lookupPath(io, path);
        const inode = try self.readInode(io, inode_number);
        if (inode.kind != .file and inode.kind != .directory and inode.kind != .symlink) return error.UnsupportedInodeLayout;
        if (inode.kind == .symlink and inode.isFastSymlink()) {
            return allocator.alloc(Extent, 0);
        }
        return self.readInodeExtentsAlloc(io, allocator, inode);
    }

    pub fn readXattrsAlloc(self: Reader, io: Io, allocator: std.mem.Allocator, path: []const u8) ReadError![]OwnedXattr {
        const inode_number = try self.lookupPath(io, path);
        const inode = try self.readInode(io, inode_number);
        return self.readInodeXattrsAlloc(io, allocator, inode);
    }

    pub fn readXattrAlloc(self: Reader, io: Io, allocator: std.mem.Allocator, path: []const u8, name: []const u8) ReadError![]u8 {
        const xattrs = try self.readXattrsAlloc(io, allocator, path);
        defer freeXattrs(allocator, xattrs);
        for (xattrs) |xattr| {
            if (std.mem.eql(u8, xattr.name, name)) return allocator.dupe(u8, xattr.value);
        }
        return error.XattrNotFound;
    }

    fn lookupPath(self: Reader, io: Io, path: []const u8) ReadError!u32 {
        if (path.len == 0 or std.mem.eql(u8, path, "/")) return root_inode;

        var current_inode = root_inode;
        var start: usize = 0;
        while (start < path.len) {
            while (start < path.len and path[start] == '/') : (start += 1) {}
            if (start >= path.len) break;
            var end = start;
            while (end < path.len and path[end] != '/') : (end += 1) {}
            const component = path[start..end];
            current_inode = try self.lookupChild(io, current_inode, component);
            start = end + 1;
        }
        return current_inode;
    }

    fn lookupChild(self: Reader, io: Io, dir_inode_number: u32, name: []const u8) ReadError!u32 {
        const inode = try self.readInode(io, dir_inode_number);
        if (inode.kind != .directory) return error.NotDirectory;

        const data = try self.readInodeDataAlloc(io, self.allocator, inode);
        defer self.allocator.free(data);

        var offset: usize = 0;
        while (offset + 8 <= data.len) {
            const child_inode = readInt(u32, data[offset .. offset + 4]);
            const rec_len = readInt(u16, data[offset + 4 .. offset + 6]);
            const name_len = data[offset + 6];
            if (rec_len < 8 or offset + rec_len > data.len) return error.BadDirectoryEntry;
            if (name_len > rec_len - 8) return error.BadDirectoryEntry;
            if (child_inode != 0 and std.mem.eql(u8, data[offset + 8 .. offset + 8 + name_len], name)) {
                return child_inode;
            }
            offset += rec_len;
        }
        return error.NotFound;
    }

    fn preadInode(self: Reader, io: Io, inode: ParsedInode, buffer: []u8, offset: u64) ReadError!usize {
        if (offset >= inode.size) return 0;
        const max_len = std.math.cast(usize, inode.size - offset) orelse return error.FileTooLarge;
        const want = @min(buffer.len, max_len);

        if (inode.kind == .symlink and inode.isFastSymlink()) {
            const src = inode.block_bytes[0..@intCast(inode.size)];
            const src_offset: usize = @intCast(offset);
            std.mem.copyForwards(u8, buffer[0..want], src[src_offset .. src_offset + want]);
            return want;
        }

        const extents = try self.readInodeExtentsAlloc(io, self.allocator, inode);
        defer self.allocator.free(extents);
        var done: usize = 0;
        var remaining = want;
        var logical_offset = offset;
        while (remaining > 0) {
            const logical_block: u32 = @intCast(logical_offset / self.block_size);
            const within_block: usize = @intCast(logical_offset % self.block_size);
            const physical_block = findPhysicalBlock(extents, logical_block) orelse return error.UnsupportedInodeLayout;
            const chunk = @min(remaining, @as(usize, self.block_size) - within_block);
            _ = try self.file.readPositionalAll(io, buffer[done .. done + chunk], self.blockOffset(physical_block) + within_block);
            done += chunk;
            remaining -= chunk;
            logical_offset += chunk;
        }
        return done;
    }

    fn readInodeDataAlloc(self: Reader, io: Io, allocator: std.mem.Allocator, inode: ParsedInode) ReadError![]u8 {
        const size = std.math.cast(usize, inode.size) orelse return error.FileTooLarge;
        const data = try allocator.alloc(u8, size);
        errdefer allocator.free(data);
        if (size == 0) return data;

        if (inode.kind == .symlink and inode.isFastSymlink()) {
            std.mem.copyForwards(u8, data, inode.block_bytes[0..size]);
            return data;
        }

        const extents = try self.readInodeExtentsAlloc(io, allocator, inode);
        defer allocator.free(extents);
        var offset: usize = 0;
        while (offset < data.len) {
            offset += try self.preadInodeWithExtents(io, inode, extents, data[offset..], offset);
        }
        return data;
    }

    fn readInodeXattrsAlloc(self: Reader, io: Io, allocator: std.mem.Allocator, inode: ParsedInode) ReadError![]OwnedXattr {
        if (inode.file_acl_block == 0) return allocator.alloc(OwnedXattr, 0);

        const block = try allocator.alloc(u8, self.block_size);
        defer allocator.free(block);
        _ = try self.file.readPositionalAll(io, block, self.blockOffset(inode.file_acl_block));
        if (readInt(u32, block[0..4]) != ext4_xattr_magic) return error.UnsupportedInodeLayout;

        var xattrs = std.array_list.Managed(OwnedXattr).init(allocator);
        errdefer {
            for (xattrs.items) |xattr| {
                allocator.free(xattr.name);
                allocator.free(xattr.value);
            }
            xattrs.deinit();
        }

        var cursor: usize = 32;
        while (cursor + 4 <= block.len) {
            if (readInt(u32, block[cursor .. cursor + 4]) == 0) break;
            const name_len = block[cursor];
            const name_index = block[cursor + 1];
            const value_off = readInt(u16, block[cursor + 2 .. cursor + 4]);
            const value_size = readInt(u32, block[cursor + 8 .. cursor + 12]);
            const entry_len = alignUpU16(@as(u16, @intCast(16 + name_len)), 4);
            const short_name = block[cursor + 16 .. cursor + 16 + name_len];
            if (cursor + entry_len > block.len or value_off + value_size > block.len) return error.UnsupportedInodeLayout;
            try xattrs.append(.{
                .name = try joinXattrName(allocator, name_index, short_name),
                .value = try allocator.dupe(u8, block[value_off .. value_off + value_size]),
            });
            cursor += entry_len;
        }
        return xattrs.toOwnedSlice();
    }

    fn readInode(self: Reader, io: Io, inode_number: u32) ReadError!ParsedInode {
        if (inode_number == 0 or inode_number > self.total_inodes) return error.NotFound;
        const group_index = (inode_number - 1) / self.inodes_per_group;
        const index_in_group = (inode_number - 1) % self.inodes_per_group;
        const group = self.groups[group_index];
        const inode_offset = self.blockOffset(group.inode_table_block) + @as(u64, index_in_group) * self.inode_size;

        var buf: [inode_size]u8 = [_]u8{0} ** inode_size;
        _ = try self.file.readPositionalAll(io, &buf, inode_offset);
        return ParsedInode.fromBytes(inode_number, &buf);
    }

    fn blockOffset(self: Reader, block_number: u64) u64 {
        return self.offset + block_number * self.block_size;
    }

    fn readInodeExtentsAlloc(self: Reader, io: Io, allocator: std.mem.Allocator, inode: ParsedInode) ReadError![]Extent {
        if ((inode.flags & inode_flag_extents) == 0) return error.UnsupportedInodeLayout;

        var extents = std.array_list.Managed(Extent).init(allocator);
        errdefer extents.deinit();
        try self.appendExtentTreeEntries(io, &extents, inode.block_bytes[0..], max_inline_extents, null);
        return extents.toOwnedSlice();
    }

    fn appendExtentTreeEntries(
        self: Reader,
        io: Io,
        extents: *std.array_list.Managed(Extent),
        node_bytes: []const u8,
        node_capacity: usize,
        expected_depth: ?u16,
    ) ReadError!void {
        const header = try parseExtentHeader(node_bytes[0..extent_header_size]);
        if (expected_depth) |depth| {
            if (header.depth != depth) return error.UnsupportedInodeLayout;
        }
        if (header.depth > max_supported_extent_depth) return error.UnsupportedExtentDepth;
        if (header.entries > header.max or header.max > node_capacity) return error.UnsupportedInodeLayout;

        var entry_index: usize = 0;
        if (header.depth == 0) {
            while (entry_index < header.entries) : (entry_index += 1) {
                const base = extent_header_size + entry_index * extent_entry_size;
                try extents.append(decodeExtent(node_bytes[base .. base + extent_entry_size]));
            }
            return;
        }

        var child_block: [default_block_size]u8 = undefined;
        while (entry_index < header.entries) : (entry_index += 1) {
            const base = extent_header_size + entry_index * extent_entry_size;
            const child = decodeExtentIndex(node_bytes[base .. base + extent_entry_size]);
            _ = try self.file.readPositionalAll(io, &child_block, self.blockOffset(child.leaf_block));
            try self.appendExtentTreeEntries(
                io,
                extents,
                child_block[0..],
                extentEntriesPerBlock(self.block_size),
                header.depth - 1,
            );
        }
    }

    fn preadInodeWithExtents(
        self: Reader,
        io: Io,
        inode: ParsedInode,
        extents: []const Extent,
        buffer: []u8,
        offset: u64,
    ) ReadError!usize {
        if (offset >= inode.size) return 0;
        const max_len = std.math.cast(usize, inode.size - offset) orelse return error.FileTooLarge;
        const want = @min(buffer.len, max_len);

        var done: usize = 0;
        var remaining = want;
        var logical_offset = offset;
        while (remaining > 0) {
            const logical_block: u32 = @intCast(logical_offset / self.block_size);
            const within_block: usize = @intCast(logical_offset % self.block_size);
            const physical_block = findPhysicalBlock(extents, logical_block) orelse return error.UnsupportedInodeLayout;
            const chunk = @min(remaining, @as(usize, self.block_size) - within_block);
            _ = try self.file.readPositionalAll(io, buffer[done .. done + chunk], self.blockOffset(physical_block) + within_block);
            done += chunk;
            remaining -= chunk;
            logical_offset += chunk;
        }
        return done;
    }
};

pub fn open(io: Io, file: Io.File, allocator: std.mem.Allocator, options: OpenOptions) OpenError!Reader {
    return Reader.open(io, file, allocator, options);
}

const ReaderGroup = struct {
    block_bitmap_block: u32,
    inode_bitmap_block: u32,
    inode_table_block: u32,
};

const ParsedInode = struct {
    inode: u32,
    kind: Kind,
    mode: u16,
    uid: u32,
    gid: u32,
    size: u64,
    generation: u32,
    flags: u32,
    file_acl_block: u32,
    block_bytes: [60]u8,

    fn fromBytes(inode_number: u32, buf: []const u8) ReadError!ParsedInode {
        const full_mode = readInt(u16, buf[0..2]);
        const kind = modeToKind(full_mode) orelse return error.UnsupportedInodeLayout;
        var block_bytes: [60]u8 = undefined;
        @memcpy(&block_bytes, buf[40..100]);
        return .{
            .inode = inode_number,
            .kind = kind,
            .mode = full_mode & 0x0FFF,
            .uid = readInt(u16, buf[2..4]) | (@as(u32, readInt(u16, buf[120..122])) << 16),
            .gid = readInt(u16, buf[24..26]) | (@as(u32, readInt(u16, buf[122..124])) << 16),
            .size = readInt(u32, buf[4..8]) | (@as(u64, readInt(u32, buf[108..112])) << 32),
            .generation = readInt(u32, buf[100..104]),
            .flags = readInt(u32, buf[32..36]),
            .file_acl_block = readInt(u32, buf[104..108]),
            .block_bytes = block_bytes,
        };
    }

    fn stat(self: ParsedInode) Stat {
        return .{
            .inode = self.inode,
            .kind = self.kind,
            .mode = self.mode,
            .uid = self.uid,
            .gid = self.gid,
            .size = self.size,
        };
    }

    fn isFastSymlink(self: ParsedInode) bool {
        return self.kind == .symlink and self.size <= 60 and (self.flags & inode_flag_extents) == 0;
    }

};

fn buildPlan(allocator: std.mem.Allocator, tree: *FileTreeView, options: PopulateOptions) PopulateError!WriterPlan {
    var entries_list = std.array_list.Managed(OwnedEntry).init(allocator);
    errdefer {
        for (entries_list.items) |entry| {
            allocator.free(entry.path);
            freeOwnedXattrSlice(allocator, entry.xattrs);
        }
        entries_list.deinit();
    }

    tree.reset();
    while (try tree.next()) |entry| {
        try validateTreeEntry(entry);
        const owned_xattrs = try dupXattrs(allocator, entry.xattrs);
        errdefer freeOwnedXattrSlice(allocator, owned_xattrs);
        try entries_list.append(.{
            .path = try allocator.dupe(u8, entry.path),
            .kind = entry.kind,
            .mode = entry.mode,
            .uid = entry.uid,
            .gid = entry.gid,
            .size = entry.size,
            .content = entry.content,
            .xattrs = owned_xattrs,
        });
    }

    sortOwnedEntries(entries_list.items);
    if (hasDuplicatePaths(entries_list.items)) return error.DuplicatePath;

    const node_count = entries_list.items.len + 1;
    const nodes = try allocator.alloc(Node, node_count);
    errdefer allocator.free(nodes);

    nodes[0] = .{
        .path = "",
        .name = "",
        .parent_path = "",
        .parent_index = 0,
        .inode = root_inode,
        .kind = .directory,
        .mode = 0o755,
        .uid = 0,
        .gid = 0,
        .declared_size = 0,
        .content = null,
        .xattrs = &.{},
    };

    var next_inode = first_non_reserved_inode;
    for (entries_list.items, 0..) |*entry, index| {
        const parent_path = pathParent(entry.path);
        const parent_index = findNodeIndexByPath(nodes[0 .. index + 1], parent_path) orelse return error.MissingParentDirectory;
        if (nodes[parent_index].kind != .directory) return error.ParentNotDirectory;
        nodes[index + 1] = .{
            .path = entry.path,
            .name = pathBase(entry.path),
            .parent_path = parent_path,
            .parent_index = parent_index,
            .inode = next_inode,
            .kind = entry.kind,
            .mode = entry.mode,
            .uid = entry.uid,
            .gid = entry.gid,
            .declared_size = entry.size,
            .content = entry.content,
            .xattrs = entry.xattrs,
        };
        entry.xattrs = &.{};
        next_inode += 1;
    }

    try buildDirectoryPayloads(allocator, nodes, options.block_size);

    var data_blocks_needed: u32 = 0;
    var feature_ro_compat: u32 = writer_feature_ro_compat_base;
    for (nodes) |*node| {
        switch (node.kind) {
            .directory => {
                node.size_on_disk = node.dir_bytes.?.len;
                node.data_block_count = @intCast(node.size_on_disk / options.block_size);
                data_blocks_needed += node.data_block_count;
                node.link_count = countDirectoryLinks(nodes, node.inode);
            },
            .file => {
                node.size_on_disk = node.declared_size;
                node.data_block_count = blocksForBytes(node.size_on_disk, options.block_size);
                data_blocks_needed += node.data_block_count;
                if (node.size_on_disk > std.math.maxInt(i32)) feature_ro_compat |= feature_ro_compat_large_file;
            },
            .symlink => {
                node.size_on_disk = node.declared_size;
                node.uses_fast_symlink = node.declared_size <= 60;
                node.data_block_count = if (node.uses_fast_symlink) 0 else blocksForBytes(node.size_on_disk, options.block_size);
                data_blocks_needed += node.data_block_count;
            },
        }
        if (node.xattrs.len > 0) {
            node.xattr_block_bytes = try buildXattrBlock(allocator, node.xattrs, options.block_size);
            data_blocks_needed += 1;
        }
    }

    return .{
        .entries = try entries_list.toOwnedSlice(),
        .nodes = nodes,
        .feature_ro_compat = feature_ro_compat,
        .data_blocks_needed = data_blocks_needed,
    };
}

fn buildLayout(allocator: std.mem.Allocator, total_blocks: u32, node_count: usize, data_blocks_needed: u32) PopulateError!Layout {
    const group_count = blocksToGroups(total_blocks, default_blocks_per_group);
    const gdt_blocks = @max(@as(u32, 1), blocksForBytes(@as(u64, group_count) * group_desc_size, default_block_size));

    const usable_nodes = std.math.cast(u32, node_count - 1) orelse return error.TooManyInodes;
    const total_used_inodes = first_non_reserved_inode - 1 + usable_nodes;
    var inodes_per_group = divCeil(total_used_inodes, group_count);
    const inodes_per_block = default_block_size / inode_size;
    inodes_per_group = alignUpU32(@max(inodes_per_group, inodes_per_block), inodes_per_block);
    if (inodes_per_group > default_block_size * 8) return error.TooManyInodes;

    const inode_table_blocks = divCeil(@as(u32, inodes_per_group) * inode_size, default_block_size);
    const groups = try allocator.alloc(GroupLayout, group_count);
    errdefer allocator.free(groups);

    var group_index: u32 = 0;
    var free_blocks: u32 = 0;
    while (group_index < group_count) : (group_index += 1) {
        const start_block = @as(u64, group_index) * default_blocks_per_group;
        const block_count = @min(default_blocks_per_group, total_blocks - @as(u32, @intCast(start_block)));
        const has_super_copy = group_index == 0 or isSparseSuperGroup(group_index);
        const super_gdt_blocks: u32 = if (has_super_copy) 1 + gdt_blocks else 0;
        const reserved_block_count = super_gdt_blocks + 2 + inode_table_blocks;
        if (reserved_block_count >= block_count) return error.NotEnoughSpace;
        groups[group_index] = .{
            .index = group_index,
            .start_block = start_block,
            .block_count = block_count,
            .has_super_copy = has_super_copy,
            .block_bitmap_block = @intCast(start_block + super_gdt_blocks),
            .inode_bitmap_block = @intCast(start_block + super_gdt_blocks + 1),
            .inode_table_block = @intCast(start_block + super_gdt_blocks + 2),
            .data_start_block = start_block + reserved_block_count,
            .reserved_block_count = reserved_block_count,
            .data_capacity = block_count - reserved_block_count,
        };
        free_blocks += groups[group_index].data_capacity;
    }
    if (data_blocks_needed > free_blocks) return error.NotEnoughSpace;

    return .{
        .total_blocks = total_blocks,
        .group_count = group_count,
        .gdt_blocks = gdt_blocks,
        .inodes_per_group = inodes_per_group,
        .inode_table_blocks = inode_table_blocks,
        .groups = groups,
    };
}

fn buildFixedLayout(
    allocator: std.mem.Allocator,
    total_blocks: u32,
    blocks_per_group: u32,
    inodes_per_group: u32,
    inode_table_blocks: u32,
    gdt_blocks: u32,
) ResizeError!Layout {
    const group_count = blocksToGroups(total_blocks, blocks_per_group);
    const groups = try allocator.alloc(GroupLayout, group_count);
    errdefer allocator.free(groups);

    var group_index: u32 = 0;
    while (group_index < group_count) : (group_index += 1) {
        const start_block = @as(u64, group_index) * blocks_per_group;
        const block_count = @min(blocks_per_group, total_blocks - @as(u32, @intCast(start_block)));
        const has_super_copy = group_index == 0 or isSparseSuperGroup(group_index);
        const super_gdt_blocks: u32 = if (has_super_copy) 1 + gdt_blocks else 0;
        const reserved_block_count = super_gdt_blocks + 2 + inode_table_blocks;
        if (reserved_block_count >= block_count) return error.UnsupportedResizeLayout;
        groups[group_index] = .{
            .index = group_index,
            .start_block = start_block,
            .block_count = block_count,
            .has_super_copy = has_super_copy,
            .block_bitmap_block = @intCast(start_block + super_gdt_blocks),
            .inode_bitmap_block = @intCast(start_block + super_gdt_blocks + 1),
            .inode_table_block = @intCast(start_block + super_gdt_blocks + 2),
            .data_start_block = start_block + reserved_block_count,
            .reserved_block_count = reserved_block_count,
            .data_capacity = block_count - reserved_block_count,
        };
    }

    return .{
        .total_blocks = total_blocks,
        .group_count = group_count,
        .gdt_blocks = gdt_blocks,
        .inodes_per_group = inodes_per_group,
        .inode_table_blocks = inode_table_blocks,
        .groups = groups,
    };
}

fn assignInodesToGroups(nodes: []Node, groups: []GroupLayout, inodes_per_group: u32) void {
    for (nodes) |node| {
        const group_index = (node.inode - 1) / inodes_per_group;
        groups[group_index].used_inode_count += 1;
        if (node.kind == .directory) groups[group_index].used_dir_count += 1;
    }
    // Reserved inodes 1..10 live in group 0.
    groups[0].used_inode_count += first_non_reserved_inode - 2;
}

fn allocateNodeBlocks(allocator: std.mem.Allocator, nodes: []Node, layout: *Layout) PopulateError!void {
    var allocator_state = BlockAllocator{ .groups = layout.groups };
    for (nodes) |*node| {
        if (node.data_block_count == 0) {
            node.extents = &.{};
        } else {
            node.extents = try allocator_state.allocate(allocator, node.data_block_count);
        }
        if (!node.uses_fast_symlink) {
            try allocateExtentTreeBlocks(allocator, &allocator_state, node, default_block_size);
        }
        if (node.xattr_block_bytes != null) {
            node.xattr_block = try allocator_state.allocateSingle();
        }
    }
}

const BlockAllocator = struct {
    groups: []GroupLayout,
    current_group: usize = 0,

    fn allocate(self: *BlockAllocator, allocator: std.mem.Allocator, block_count: u32) PopulateError![]Extent {
        var extents = std.array_list.Managed(Extent).init(allocator);
        errdefer extents.deinit();
        var remaining = block_count;
        var logical: u32 = 0;
        while (remaining > 0) {
            while (self.current_group < self.groups.len and self.groups[self.current_group].used_data_blocks == self.groups[self.current_group].data_capacity) {
                self.current_group += 1;
            }
            if (self.current_group >= self.groups.len) return error.NotEnoughSpace;

            var group = &self.groups[self.current_group];
            const available = group.data_capacity - group.used_data_blocks;
            const take = @min(remaining, available);
            try extents.append(.{
                .logical_block = logical,
                .start_block = group.data_start_block + group.used_data_blocks,
                .block_count = @intCast(take),
            });
            group.used_data_blocks += take;
            logical += take;
            remaining -= take;
        }
        return extents.toOwnedSlice();
    }

    fn allocateSingle(self: *BlockAllocator) PopulateError!u64 {
        while (self.current_group < self.groups.len and self.groups[self.current_group].used_data_blocks == self.groups[self.current_group].data_capacity) {
            self.current_group += 1;
        }
        if (self.current_group >= self.groups.len) return error.NotEnoughSpace;
        const group = &self.groups[self.current_group];
        const block = group.data_start_block + group.used_data_blocks;
        group.used_data_blocks += 1;
        return block;
    }
};

fn writeNodeData(io: Io, file: Io.File, nodes: []Node, options: PopulateOptions) PopulateError!void {
    var scratch: [default_block_size]u8 = [_]u8{0} ** default_block_size;
    const uuid = options.uuid orelse [_]u8{0} ** 16;
    for (nodes) |node| {
        switch (node.kind) {
            .directory => {
                const bytes = node.dir_bytes.?;
                const dir_bytes = try std.heap.page_allocator.dupe(u8, bytes);
                defer std.heap.page_allocator.free(dir_bytes);
                var block_index: usize = 0;
                while (block_index < dir_bytes.len / options.block_size) : (block_index += 1) {
                    const block = dir_bytes[block_index * options.block_size .. (block_index + 1) * options.block_size];
                    if (node.uses_hashed_directory and block_index == 0) {
                        const root_limit = readInt(u16, block[32..34]);
                        const root_count = readInt(u16, block[34..36]);
                        setDxChecksum(block, 32, root_count, root_limit, uuid, node.inode, 0);
                    } else {
                        setDirectoryLeafChecksum(block, uuid, node.inode, 0);
                    }
                }
                var extent_index: usize = 0;
                while (extent_index < node.extents.len) : (extent_index += 1) {
                    const extent = node.extents[extent_index];
                    const byte_len = @as(usize, extent.block_count) * options.block_size;
                    const file_off = options.offset + extent.start_block * options.block_size;
                    const src_off = @as(usize, extent.logical_block) * options.block_size;
                    try file.writePositionalAll(io, dir_bytes[src_off .. src_off + byte_len], file_off);
                }
            },
            .file, .symlink => {
                if (node.uses_fast_symlink or node.data_block_count == 0) continue;
                const content = node.content orelse return error.MissingContentReader;
                var written_data: u64 = 0;
                var extent_index: usize = 0;
                while (extent_index < node.extents.len) : (extent_index += 1) {
                    const extent = node.extents[extent_index];
                    var block_index: u16 = 0;
                    while (block_index < extent.block_count) : (block_index += 1) {
                        @memset(&scratch, 0);
                        const copy_off = written_data;
                        const remaining = node.size_on_disk - copy_off;
                        const to_read = @min(@as(u64, options.block_size), remaining);
                        const want = @as(usize, @intCast(to_read));
                        if (want > 0) {
                            const got = try content.readAt(scratch[0..want], copy_off);
                            if (got != want) return error.UnexpectedContentLength;
                        }
                        const physical_block = extent.start_block + block_index;
                        try file.writePositionalAll(io, &scratch, options.offset + physical_block * options.block_size);
                        written_data += want;
                    }
                }
            },
        }
        for (node.extent_tree_blocks) |block| {
            try file.writePositionalAll(io, &block.bytes, options.offset + block.block_number * options.block_size);
        }
        if (node.xattr_block_bytes) |xattr_block| {
            const block_number = node.xattr_block orelse unreachable;
            const scratch_block = try std.heap.page_allocator.dupe(u8, xattr_block);
            defer std.heap.page_allocator.free(scratch_block);
            setXattrBlockChecksum(scratch_block, uuid, block_number);
            try file.writePositionalAll(io, scratch_block, options.offset + block_number * options.block_size);
        }
    }
}

fn zeroUnusedInodeTableBlocks(io: Io, file: Io.File, layout: Layout, offset: u64) PopulateError!void {
    const zero_block: [default_block_size]u8 = [_]u8{0} ** default_block_size;
    for (layout.groups) |group| {
        var block: u32 = 0;
        while (block < layout.inode_table_blocks) : (block += 1) {
            try file.writePositionalAll(io, &zero_block, offset + (@as(u64, group.inode_table_block) + block) * default_block_size);
        }
    }
}

fn buildGroupBitmaps(layout: Layout, group: GroupLayout, block_bitmap: []u8, inode_bitmap: []u8) void {
    @memset(block_bitmap, 0);
    @memset(inode_bitmap, 0);

    var bit: u32 = 0;
    while (bit < group.reserved_block_count + group.used_data_blocks) : (bit += 1) {
        setBitmapBit(block_bitmap, bit);
    }
    bit = group.block_count;
    while (bit < default_block_size * 8) : (bit += 1) {
        setBitmapBit(block_bitmap, bit);
    }

    bit = 0;
    while (bit < group.used_inode_count) : (bit += 1) {
        setBitmapBit(inode_bitmap, bit);
    }
    bit = layout.inodes_per_group;
    while (bit < default_block_size * 8) : (bit += 1) {
        setBitmapBit(inode_bitmap, bit);
    }
}

fn writeBitmaps(io: Io, file: Io.File, layout: Layout, offset: u64) PopulateError!void {
    var block_bitmap: [default_block_size]u8 = undefined;
    var inode_bitmap: [default_block_size]u8 = undefined;

    for (layout.groups) |group| {
        buildGroupBitmaps(layout, group, &block_bitmap, &inode_bitmap);
        try file.writePositionalAll(io, &block_bitmap, offset + @as(u64, group.block_bitmap_block) * default_block_size);
        try file.writePositionalAll(io, &inode_bitmap, offset + @as(u64, group.inode_bitmap_block) * default_block_size);
    }
}

fn writeInodes(io: Io, file: Io.File, nodes: []Node, layout: Layout, options: PopulateOptions) PopulateError!void {
    const uuid = options.uuid orelse [_]u8{0} ** 16;
    for (nodes) |node| {
        var buf: [inode_size]u8 = [_]u8{0} ** inode_size;
        writeInt(u16, buf[0..2], inodeMode(node));
        writeInt(u16, buf[2..4], @truncate(node.uid));
        writeInt(u32, buf[4..8], @truncate(node.size_on_disk));
        writeInt(u32, buf[8..12], options.timestamp);
        writeInt(u32, buf[12..16], options.timestamp);
        writeInt(u32, buf[16..20], options.timestamp);
        writeInt(u16, buf[24..26], @truncate(node.gid));
        writeInt(u16, buf[26..28], node.link_count);
        writeInt(u32, buf[28..32], node.data_block_count * sectors_per_block);
        var inode_flags: u32 = if (node.uses_fast_symlink) 0 else inode_flag_extents;
        if (node.uses_hashed_directory) inode_flags |= inode_flag_index;
        writeInt(u32, buf[32..36], inode_flags);

        if (node.uses_fast_symlink) {
            const want: usize = @intCast(node.declared_size);
            if (want > 0) {
                const content = node.content orelse return error.MissingContentReader;
                const got = try content.readAt(buf[40 .. 40 + want], 0);
                if (got != want) return error.UnexpectedContentLength;
            }
        } else {
            @memcpy(buf[40..100], &node.extent_root);
        }

        writeInt(u32, buf[104..108], @truncate(node.xattr_block orelse 0));
        writeInt(u32, buf[108..112], @as(u32, @truncate(node.size_on_disk >> 32)));
        writeInt(u16, buf[120..122], @as(u16, @truncate(node.uid >> 16)));
        writeInt(u16, buf[122..124], @as(u16, @truncate(node.gid >> 16)));
        setInodeChecksum(&buf, uuid, node.inode);

        const group_index = (node.inode - 1) / layout.inodes_per_group;
        const index_in_group = (node.inode - 1) % layout.inodes_per_group;
        const group = layout.groups[group_index];
        const inode_offset = options.offset + @as(u64, group.inode_table_block) * options.block_size + @as(u64, index_in_group) * inode_size;
        try file.writePositionalAll(io, &buf, inode_offset);
    }
}

fn writeGroupDescriptorTables(io: Io, file: Io.File, layout: Layout, offset: u64, uuid: [16]u8) PopulateError!void {
    const desc_bytes = @as(usize, layout.group_count) * group_desc_size;
    const table_bytes = @as(usize, layout.gdt_blocks) * default_block_size;
    const buf = try std.heap.page_allocator.alloc(u8, table_bytes);
    defer std.heap.page_allocator.free(buf);
    @memset(buf, 0);
    var block_bitmap: [default_block_size]u8 = undefined;
    var inode_bitmap: [default_block_size]u8 = undefined;
    for (layout.groups, 0..) |group, index| {
        const base = index * group_desc_size;
        buildGroupBitmaps(layout, group, &block_bitmap, &inode_bitmap);
        writeInt(u32, buf[base + 0 .. base + 4], group.block_bitmap_block);
        writeInt(u32, buf[base + 4 .. base + 8], group.inode_bitmap_block);
        writeInt(u32, buf[base + 8 .. base + 12], group.inode_table_block);
        writeInt(u16, buf[base + 12 .. base + 14], @intCast(group.block_count - group.reserved_block_count - group.used_data_blocks));
        writeInt(u16, buf[base + 14 .. base + 16], @intCast(layout.inodes_per_group - group.used_inode_count));
        writeInt(u16, buf[base + 16 .. base + 18], @intCast(group.used_dir_count));
        writeInt(u16, buf[base + 0x18 .. base + 0x1A], @truncate(bitmapChecksum(uuid, &block_bitmap, default_blocks_per_group / 8)));
        writeInt(u16, buf[base + 0x1A .. base + 0x1C], @truncate(bitmapChecksum(uuid, &inode_bitmap, layout.inodes_per_group / 8)));
        writeInt(u16, buf[base + 0x1C .. base + 0x1E], @intCast(layout.inodes_per_group - group.used_inode_count));
    }
    _ = desc_bytes;
    setGroupDescriptorChecksums(buf[0 .. @as(usize, layout.group_count) * group_desc_size], layout, uuid);

    try file.writePositionalAll(io, buf, offset + default_block_size);
    for (layout.groups) |group| {
        if (group.index == 0 or !group.has_super_copy) continue;
        try file.writePositionalAll(io, buf, offset + (group.start_block + 1) * default_block_size);
    }
}

fn writeSuperblocks(io: Io, file: Io.File, layout: Layout, plan: WriterPlan, options: PopulateOptions) PopulateError!void {
    var sb: [superblock_size]u8 = [_]u8{0} ** superblock_size;
    const label = encodeLabel(options.label);
    const uuid = options.uuid orelse [_]u8{0} ** 16;
    const free_blocks = countFreeBlocks(layout.groups);
    const free_inodes = countFreeInodes(layout.groups, layout.inodes_per_group);

    writeInt(u32, sb[0x00..0x04], layout.group_count * layout.inodes_per_group);
    writeInt(u32, sb[0x04..0x08], layout.total_blocks);
    writeInt(u32, sb[0x08..0x0C], 0);
    writeInt(u32, sb[0x0C..0x10], free_blocks);
    writeInt(u32, sb[0x10..0x14], free_inodes);
    writeInt(u32, sb[0x14..0x18], 0);
    writeInt(u32, sb[0x18..0x1C], 2);
    writeInt(u32, sb[0x1C..0x20], 2);
    writeInt(u32, sb[0x20..0x24], default_blocks_per_group);
    writeInt(u32, sb[0x24..0x28], default_blocks_per_group);
    writeInt(u32, sb[0x28..0x2C], layout.inodes_per_group);
    writeInt(u32, sb[0x2C..0x30], options.timestamp);
    writeInt(u32, sb[0x30..0x34], options.timestamp);
    writeInt(u16, sb[0x34..0x36], 0);
    writeInt(u16, sb[0x36..0x38], 0xFFFF);
    writeInt(u16, sb[0x38..0x3A], super_magic);
    writeInt(u16, sb[0x3A..0x3C], state_clean);
    writeInt(u16, sb[0x3C..0x3E], errors_continue);
    writeInt(u16, sb[0x3E..0x40], 0);
    writeInt(u32, sb[0x40..0x44], options.timestamp);
    writeInt(u32, sb[0x44..0x48], 0);
    writeInt(u32, sb[0x48..0x4C], creator_os_linux);
    writeInt(u32, sb[0x4C..0x50], rev_dynamic);
    writeInt(u16, sb[0x50..0x52], 0);
    writeInt(u16, sb[0x52..0x54], 0);
    writeInt(u32, sb[0x54..0x58], first_non_reserved_inode);
    writeInt(u16, sb[0x58..0x5A], inode_size);
    writeInt(u16, sb[0x5A..0x5C], 0);
    writeInt(u32, sb[0x5C..0x60], writer_feature_compat);
    writeInt(u32, sb[0x60..0x64], writer_feature_incompat);
    writeInt(u32, sb[0x64..0x68], plan.feature_ro_compat);
    sb[0x68..0x78].* = uuid;
    sb[0x78..0x88].* = label;
    writeInt(u8, sb[0xCC..0xCD], 0);
    writeInt(u8, sb[0xCD..0xCE], 0);
    writeInt(u16, sb[0xCE..0xD0], 0);
    writeInt(u8, sb[0xFC..0xFD], dx_hash_half_md4);
    writeInt(u8, sb[0xFD..0xFE], 0);
    writeInt(u16, sb[0xFE..0x100], group_desc_size);
    writeInt(u32, sb[0x108..0x10C], options.timestamp);
    writeInt(u8, sb[0x175..0x176], super_checksum_type_crc32c);
    setSuperblockChecksum(&sb);

    try file.writePositionalAll(io, &sb, options.offset + superblock_offset);
    for (layout.groups) |group| {
        if (group.index == 0 or !group.has_super_copy) continue;
        writeInt(u16, sb[0x5A..0x5C], @intCast(group.index));
        setSuperblockChecksum(&sb);
        try file.writePositionalAll(io, &sb, options.offset + group.start_block * options.block_size);
    }
}

fn buildDirectoryPayloads(allocator: std.mem.Allocator, nodes: []Node, block_size: u32) PopulateError!void {
    for (nodes, 0..) |*node, index| {
        if (node.kind != .directory) continue;

        var linear_specs = std.array_list.Managed(DirEntrySpec).init(allocator);
        defer linear_specs.deinit();

        try linear_specs.append(.{ .inode = node.inode, .kind = .directory, .name = "." });
        const parent_inode = if (index == 0) node.inode else nodes[node.parent_index].inode;
        try linear_specs.append(.{ .inode = parent_inode, .kind = .directory, .name = ".." });

        var child_specs = std.array_list.Managed(DirEntrySpec).init(allocator);
        defer child_specs.deinit();

        for (nodes, 0..) |child, child_index| {
            if (child_index == 0) continue;
            if (child.parent_index == index) {
                const spec: DirEntrySpec = .{ .inode = child.inode, .kind = child.kind, .name = child.name };
                try linear_specs.append(spec);
                try child_specs.append(spec);
            }
        }

        const linear_bytes = try buildLinearDirectoryBytes(allocator, linear_specs.items, block_size);
        if (linear_bytes.len <= block_size or child_specs.items.len == 0) {
            node.dir_bytes = linear_bytes;
            continue;
        }

        allocator.free(linear_bytes);
        node.uses_hashed_directory = true;
        node.dir_bytes = try buildIndexedDirectoryBytes(allocator, node.inode, parent_inode, child_specs.items, block_size);
    }
}

const DirEntrySpec = struct {
    inode: u32,
    kind: Kind,
    name: []const u8,
};

const HashedDirEntry = struct {
    spec: DirEntrySpec,
    hash: u32,
};

fn dirEntryMinRecLen(name_len: usize) u16 {
    return alignUpU16(@as(u16, @intCast(8 + name_len)), dir_entry_alignment);
}

fn buildLinearDirectoryBytes(allocator: std.mem.Allocator, specs: []const DirEntrySpec, block_size: u32) PopulateError![]u8 {
    var bytes = std.array_list.Managed(u8).init(allocator);
    errdefer bytes.deinit();
    try appendDirectoryLeafBlocks(&bytes, specs, block_size);
    return bytes.toOwnedSlice();
}

fn appendDirectoryLeafBlocks(bytes: *std.array_list.Managed(u8), specs: []const DirEntrySpec, block_size: u32) PopulateError!void {
    const usable = block_size - 12;
    var cursor: usize = 0;
    while (cursor < specs.len) {
        const block_start = bytes.items.len;
        try bytes.appendNTimes(0, block_size);
        var pos: usize = 0;
        while (cursor < specs.len) {
            const entry = specs[cursor];
            const min_rec_len = dirEntryMinRecLen(entry.name.len);
            const next_min = if (cursor + 1 < specs.len) dirEntryMinRecLen(specs[cursor + 1].name.len) else 0;
            if (pos + min_rec_len > usable) return error.InvalidDirectorySize;
            const rec_len: u16 = if (cursor + 1 == specs.len or pos + min_rec_len + next_min > usable)
                @intCast(usable - pos)
            else
                min_rec_len;
            encodeDirEntry(bytes.items[block_start + pos .. block_start + pos + rec_len], entry, rec_len);
            pos += rec_len;
            cursor += 1;
            if (pos == usable) break;
        }
        putDirectoryLeafTail(bytes.items[block_start .. block_start + block_size]);
    }
}

fn hashedDirEntryLess(lhs: HashedDirEntry, rhs: HashedDirEntry) bool {
    if (lhs.hash != rhs.hash) return lhs.hash < rhs.hash;
    return std.mem.order(u8, lhs.spec.name, rhs.spec.name) == .lt;
}

fn sortHashedDirEntries(entries: []HashedDirEntry) void {
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        var j = i;
        while (j > 0 and hashedDirEntryLess(entries[j], entries[j - 1])) : (j -= 1) {
            std.mem.swap(HashedDirEntry, &entries[j], &entries[j - 1]);
        }
    }
}

fn buildIndexedDirectoryBytes(
    allocator: std.mem.Allocator,
    inode_number: u32,
    parent_inode: u32,
    children: []const DirEntrySpec,
    block_size: u32,
) PopulateError![]u8 {
    const hashed = try allocator.alloc(HashedDirEntry, children.len);
    defer allocator.free(hashed);
    for (children, 0..) |child, index| {
        hashed[index] = .{ .spec = child, .hash = dirHash(child.name) };
    }
    sortHashedDirEntries(hashed);

    var leaf_starts = std.array_list.Managed(usize).init(allocator);
    defer leaf_starts.deinit();
    try leaf_starts.append(0);

    const usable = block_size - 12;
    var cursor: usize = 0;
    while (cursor < hashed.len) {
        var pos: usize = 0;
        const leaf_start = cursor;
        while (cursor < hashed.len) {
            const min_rec_len = dirEntryMinRecLen(hashed[cursor].spec.name.len);
            const next_min = if (cursor + 1 < hashed.len) dirEntryMinRecLen(hashed[cursor + 1].spec.name.len) else 0;
            if (pos + min_rec_len > usable) return error.InvalidDirectorySize;
            if (cursor > leaf_start and pos + min_rec_len + next_min > usable) break;
            pos += if (cursor + 1 == hashed.len or pos + min_rec_len + next_min > usable) usable - pos else min_rec_len;
            cursor += 1;
            if (pos == usable) break;
        }
        if (cursor < hashed.len) try leaf_starts.append(cursor);
    }

    const root_limit: usize = (block_size - 32 - 8) / 8;
    if (leaf_starts.items.len > root_limit) return error.InvalidDirectorySize;

    var bytes = std.array_list.Managed(u8).init(allocator);
    errdefer bytes.deinit();
    try bytes.appendNTimes(0, block_size);
    encodeDirEntry(bytes.items[0..12], .{ .inode = inode_number, .kind = .directory, .name = "." }, 12);
    encodeDirEntry(bytes.items[12..block_size], .{ .inode = parent_inode, .kind = .directory, .name = ".." }, @intCast(block_size - 12));
    writeInt(u32, bytes.items[24..28], 0);
    bytes.items[28] = dx_hash_half_md4;
    bytes.items[29] = 8;
    bytes.items[30] = 0;
    bytes.items[31] = 0;
    writeInt(u16, bytes.items[32..34], @intCast(root_limit));
    writeInt(u16, bytes.items[34..36], @intCast(leaf_starts.items.len));
    writeInt(u32, bytes.items[36..40], 1);
    for (leaf_starts.items[1..], 1..) |leaf_start, leaf_index| {
        const base = 32 + leaf_index * 8;
        writeInt(u32, bytes.items[base .. base + 4], hashed[leaf_start].hash);
        writeInt(u32, bytes.items[base + 4 .. base + 8], @intCast(leaf_index + 1));
    }
    setDxChecksum(bytes.items[0..block_size], 32, leaf_starts.items.len, root_limit, [_]u8{0} ** 16, inode_number, 0);

    var leaf_specs = try allocator.alloc(DirEntrySpec, hashed.len);
    defer allocator.free(leaf_specs);
    for (hashed, 0..) |entry, index| leaf_specs[index] = entry.spec;
    try appendDirectoryLeafBlocks(&bytes, leaf_specs, block_size);
    return bytes.toOwnedSlice();
}

fn validateTreeEntry(entry: FileTreeView.Entry) PopulateError!void {
    if (entry.path.len == 0) return error.RootEntryForbidden;
    if (entry.path[0] == '/' or entry.path[entry.path.len - 1] == '/') return error.InvalidPath;
    if (entry.kind == .directory and entry.size != 0) return error.InvalidDirectorySize;
    if ((entry.kind == .file or entry.kind == .symlink) and entry.size > 0 and entry.content == null) return error.MissingContentReader;
    if (std.mem.eql(u8, entry.path, ".") or std.mem.eql(u8, entry.path, "..")) return error.InvalidPath;

    var start: usize = 0;
    while (start < entry.path.len) {
        var end = start;
        while (end < entry.path.len and entry.path[end] != '/') : (end += 1) {
            if (entry.path[end] == 0) return error.InvalidPath;
        }
        if (end == start) return error.InvalidPath;
        const component = entry.path[start..end];
        if (component.len > 255 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidPath;
        start = end + 1;
    }

    for (entry.xattrs, 0..) |xattr, index| {
        _ = try splitXattrName(xattr.name);
        var other = index + 1;
        while (other < entry.xattrs.len) : (other += 1) {
            if (std.mem.eql(u8, xattr.name, entry.xattrs[other].name)) return error.InvalidXattr;
        }
    }
}

fn sortOwnedEntries(entries: []OwnedEntry) void {
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        var j = i;
        while (j > 0 and ownedEntryLess(entries[j], entries[j - 1])) : (j -= 1) {
            std.mem.swap(OwnedEntry, &entries[j], &entries[j - 1]);
        }
    }
}

fn hasDuplicatePaths(entries: []const OwnedEntry) bool {
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        if (std.mem.eql(u8, entries[i - 1].path, entries[i].path)) return true;
    }
    return false;
}

fn ownedEntryLess(a: OwnedEntry, b: OwnedEntry) bool {
    const da = pathDepth(a.path);
    const db = pathDepth(b.path);
    if (da != db) return da < db;
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn pathDepth(path: []const u8) usize {
    if (path.len == 0) return 0;
    var count: usize = 1;
    for (path) |c| {
        if (c == '/') count += 1;
    }
    return count;
}

fn pathParent(path: []const u8) []const u8 {
    const index = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..index];
}

fn pathBase(path: []const u8) []const u8 {
    const index = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[index + 1 ..];
}

fn findNodeIndexByPath(nodes: []const Node, path: []const u8) ?usize {
    for (nodes, 0..) |node, index| {
        if (std.mem.eql(u8, node.path, path)) return index;
    }
    return null;
}

fn countDirectoryLinks(nodes: []const Node, dir_inode: u32) u16 {
    var count: u16 = 2;
    for (nodes) |node| {
        if (node.kind == .directory and node.inode != dir_inode) {
            const parent_inode = nodes[node.parent_index].inode;
            if (parent_inode == dir_inode) count += 1;
        }
    }
    return count;
}

fn blocksForBytes(bytes: u64, block_size: u32) u32 {
    if (bytes == 0) return 0;
    return @intCast(divCeil(bytes, block_size));
}

fn blocksToGroups(total_blocks: u32, blocks_per_group: u32) u32 {
    return @intCast(divCeil(total_blocks, blocks_per_group));
}

fn countFreeBlocks(groups: []const GroupLayout) u32 {
    var total: u32 = 0;
    for (groups) |group| total += group.block_count - group.reserved_block_count - group.used_data_blocks;
    return total;
}

fn countFreeInodes(groups: []const GroupLayout, inodes_per_group: u32) u32 {
    var total: u32 = 0;
    for (groups) |group| total += inodes_per_group - group.used_inode_count;
    return total;
}

fn isSparseSuperGroup(index: u32) bool {
    if (index <= 1) return true;
    return isPowerOf(index, 3) or isPowerOf(index, 5) or isPowerOf(index, 7);
}

fn isPowerOf(value: u32, base: u32) bool {
    var current = value;
    while (current > 1 and current % base == 0) current /= base;
    return current == 1;
}

fn encodeDirEntry(buf: []u8, entry: DirEntrySpec, rec_len: u16) void {
    @memset(buf, 0);
    writeInt(u32, buf[0..4], entry.inode);
    writeInt(u16, buf[4..6], rec_len);
    buf[6] = @intCast(entry.name.len);
    buf[7] = kindToDirFileType(entry.kind);
    @memcpy(buf[8 .. 8 + entry.name.len], entry.name);
}

fn setBitmapBit(bitmap: []u8, index: u32) void {
    bitmap[index / 8] |= @as(u8, 1) << @intCast(index % 8);
}

fn inodeMode(node: Node) u16 {
    return kindToModeBits(node.kind) | (node.mode & 0x0FFF);
}

fn encodeExtentHeader(buf: []u8, entries: usize, max_entries: usize, depth: u16) void {
    @memset(buf, 0);
    writeInt(u16, buf[0..2], extent_magic);
    writeInt(u16, buf[2..4], @intCast(entries));
    writeInt(u16, buf[4..6], @intCast(max_entries));
    writeInt(u16, buf[6..8], depth);
    writeInt(u32, buf[8..12], 0);
}

fn encodeExtentLeafNode(buf: []u8, max_entries: usize, extents: []const Extent) void {
    encodeExtentHeader(buf, extents.len, max_entries, 0);
    for (extents, 0..) |extent, index| {
        const base = extent_header_size + index * extent_entry_size;
        writeInt(u32, buf[base .. base + 4], extent.logical_block);
        writeInt(u16, buf[base + 4 .. base + 6], extent.block_count);
        writeInt(u16, buf[base + 6 .. base + 8], @as(u16, @truncate(extent.start_block >> 32)));
        writeInt(u32, buf[base + 8 .. base + 12], @as(u32, @truncate(extent.start_block)));
    }
}

fn encodeExtentIndexNode(buf: []u8, max_entries: usize, depth: u16, children: []const ExtentNodeRef) void {
    encodeExtentHeader(buf, children.len, max_entries, depth);
    for (children, 0..) |child, index| {
        const base = extent_header_size + index * extent_entry_size;
        writeInt(u32, buf[base .. base + 4], child.logical_block);
        writeInt(u32, buf[base + 4 .. base + 8], @as(u32, @truncate(child.block_number)));
        writeInt(u16, buf[base + 8 .. base + 10], @as(u16, @truncate(child.block_number >> 32)));
        writeInt(u16, buf[base + 10 .. base + 12], 0);
    }
}

fn extentEntriesPerBlock(block_size: u32) usize {
    return (block_size - extent_header_size) / extent_entry_size;
}

fn extentTreeShape(extent_count: usize, block_size: u32) PopulateError!struct { depth: u16, block_count: usize } {
    if (extent_count <= max_inline_extents) return .{ .depth = 0, .block_count = 0 };

    const block_capacity = extentEntriesPerBlock(block_size);
    var depth: u16 = 1;
    var nodes_at_level = divCeil(extent_count, block_capacity);
    var total_blocks = nodes_at_level;
    while (nodes_at_level > max_inline_extents) {
        if (depth == max_supported_extent_depth) return error.TooManyExtents;
        nodes_at_level = divCeil(nodes_at_level, block_capacity);
        total_blocks += nodes_at_level;
        depth += 1;
    }
    return .{ .depth = depth, .block_count = total_blocks };
}

fn allocateExtentTreeBlocks(
    allocator: std.mem.Allocator,
    block_allocator: *BlockAllocator,
    node: *Node,
    block_size: u32,
) PopulateError!void {
    const shape = try extentTreeShape(node.extents.len, block_size);
    if (shape.block_count > 0) {
        node.extent_tree_blocks = try allocator.alloc(ExtentTreeBlock, shape.block_count);
        errdefer allocator.free(node.extent_tree_blocks);
        for (node.extent_tree_blocks) |*block| {
            block.* = .{ .block_number = try block_allocator.allocateSingle() };
        }
    } else {
        node.extent_tree_blocks = &.{};
    }
    try buildExtentTree(allocator, node, block_size, shape.depth);
}

fn buildExtentTree(allocator: std.mem.Allocator, node: *Node, block_size: u32, depth: u16) PopulateError!void {
    if (depth == 0) {
        encodeExtentLeafNode(node.extent_root[0..], max_inline_extents, node.extents);
        return;
    }

    const block_capacity = extentEntriesPerBlock(block_size);
    const leaf_count = divCeil(node.extents.len, block_capacity);
    var current = try allocator.alloc(ExtentNodeRef, leaf_count);
    defer allocator.free(current);

    var block_cursor: usize = 0;
    var leaf_index: usize = 0;
    while (leaf_index < leaf_count) : (leaf_index += 1) {
        const start = leaf_index * block_capacity;
        const end = @min(start + block_capacity, node.extents.len);
        encodeExtentLeafNode(node.extent_tree_blocks[block_cursor].bytes[0..], block_capacity, node.extents[start..end]);
        current[leaf_index] = .{
            .logical_block = node.extents[start].logical_block,
            .block_number = node.extent_tree_blocks[block_cursor].block_number,
        };
        block_cursor += 1;
    }

    var child_depth: u16 = 0;
    while (current.len > max_inline_extents) {
        const next_count = divCeil(current.len, block_capacity);
        const next = try allocator.alloc(ExtentNodeRef, next_count);
        var parent_index: usize = 0;
        while (parent_index < next_count) : (parent_index += 1) {
            const start = parent_index * block_capacity;
            const end = @min(start + block_capacity, current.len);
            encodeExtentIndexNode(
                node.extent_tree_blocks[block_cursor].bytes[0..],
                block_capacity,
                child_depth + 1,
                current[start..end],
            );
            next[parent_index] = .{
                .logical_block = current[start].logical_block,
                .block_number = node.extent_tree_blocks[block_cursor].block_number,
            };
            block_cursor += 1;
        }
        allocator.free(current);
        current = next;
        child_depth += 1;
    }

    encodeExtentIndexNode(node.extent_root[0..], max_inline_extents, child_depth + 1, current);
}

fn encodeLabel(label: []const u8) [16]u8 {
    var out: [16]u8 = [_]u8{0} ** 16;
    @memcpy(out[0..label.len], label);
    return out;
}

fn kindToModeBits(kind: Kind) u16 {
    return switch (kind) {
        .directory => mode_dir,
        .file => mode_reg,
        .symlink => mode_symlink,
    };
}

fn kindToDirFileType(kind: Kind) u8 {
    return switch (kind) {
        .directory => dir_ft_dir,
        .file => dir_ft_reg,
        .symlink => dir_ft_symlink,
    };
}

fn dirFileTypeToKind(file_type: u8) Kind {
    return switch (file_type) {
        dir_ft_dir => .directory,
        dir_ft_symlink => .symlink,
        else => .file,
    };
}

fn modeToKind(mode: u16) ?Kind {
    return switch (mode & 0xF000) {
        mode_dir => .directory,
        mode_reg => .file,
        mode_symlink => .symlink,
        else => null,
    };
}

fn parseExtentHeader(buf: []const u8) ReadError!ExtentHeader {
    if (readInt(u16, buf[0..2]) != extent_magic) return error.UnsupportedInodeLayout;
    return .{
        .entries = readInt(u16, buf[2..4]),
        .max = readInt(u16, buf[4..6]),
        .depth = readInt(u16, buf[6..8]),
        .generation = readInt(u32, buf[8..12]),
    };
}

fn decodeExtent(buf: []const u8) Extent {
    const start_hi = readInt(u16, buf[6..8]);
    const start_lo = readInt(u32, buf[8..12]);
    return .{
        .logical_block = readInt(u32, buf[0..4]),
        .start_block = (@as(u64, start_hi) << 32) | start_lo,
        .block_count = readInt(u16, buf[4..6]),
    };
}

fn decodeExtentIndex(buf: []const u8) ExtentIndex {
    const leaf_lo = readInt(u32, buf[4..8]);
    const leaf_hi = readInt(u16, buf[8..10]);
    return .{
        .logical_block = readInt(u32, buf[0..4]),
        .leaf_block = (@as(u64, leaf_hi) << 32) | leaf_lo,
    };
}

fn findPhysicalBlock(extents: []const Extent, logical_block: u32) ?u64 {
    for (extents) |extent| {
        if (logical_block >= extent.logical_block and logical_block < extent.logical_block + extent.block_count) {
            return extent.start_block + (logical_block - extent.logical_block);
        }
    }
    return null;
}

fn readInt(comptime T: type, buf: []const u8) T {
    return std.mem.readInt(T, buf[0..@sizeOf(T)], .little);
}

fn writeInt(comptime T: type, buf: []u8, value: T) void {
    std.mem.writeInt(T, buf[0..@sizeOf(T)], value, .little);
}

fn divCeil(a: anytype, b: anytype) @TypeOf(a, b) {
    return std.math.divCeil(@TypeOf(a, b), a, b) catch unreachable;
}

fn alignUpU16(value: u16, alignment: usize) u16 {
    return @intCast((@as(usize, value) + alignment - 1) / alignment * alignment);
}

fn alignUpU32(value: u32, alignment: u32) u32 {
    return @intCast((@as(u64, value) + alignment - 1) / alignment * alignment);
}

fn alignUpUsize(value: usize, alignment: usize) usize {
    return (value + alignment - 1) / alignment * alignment;
}

fn alignDownUsize(value: usize, alignment: usize) usize {
    return value / alignment * alignment;
}

fn freeOwnedXattrSlice(allocator: std.mem.Allocator, xattrs: []OwnedXattr) void {
    for (xattrs) |xattr| {
        allocator.free(xattr.name);
        allocator.free(xattr.value);
    }
    allocator.free(xattrs);
}

fn dupXattrs(allocator: std.mem.Allocator, xattrs: []const Xattr) PopulateError![]OwnedXattr {
    const owned = try allocator.alloc(OwnedXattr, xattrs.len);
    errdefer {
        var index: usize = 0;
        while (index < xattrs.len) : (index += 1) {
            allocator.free(owned[index].name);
            allocator.free(owned[index].value);
        }
        allocator.free(owned);
    }
    for (xattrs, 0..) |xattr, index| {
        owned[index] = .{
            .name = try allocator.dupe(u8, xattr.name),
            .value = try allocator.dupe(u8, xattr.value),
        };
    }
    return owned;
}

fn splitXattrName(full_name: []const u8) PopulateError!struct { index: u8, short_name: []const u8 } {
    if (full_name.len == 0) return error.InvalidXattr;
    inline for (.{
        .{ .prefix = "user.", .index = xattr_name_user },
        .{ .prefix = "trusted.", .index = xattr_name_trusted },
        .{ .prefix = "security.", .index = xattr_name_security },
        .{ .prefix = "system.", .index = @as(u8, 7) },
    }) |candidate| {
        if (std.mem.startsWith(u8, full_name, candidate.prefix)) {
            const short_name = full_name[candidate.prefix.len..];
            if (short_name.len == 0 or short_name.len > 255) return error.InvalidXattr;
            return .{ .index = candidate.index, .short_name = short_name };
        }
    }
    if (full_name.len > 255) return error.InvalidXattr;
    return .{ .index = 0, .short_name = full_name };
}

fn joinXattrName(allocator: std.mem.Allocator, index: u8, short_name: []const u8) std.mem.Allocator.Error![]u8 {
    const prefix = switch (index) {
        xattr_name_user => "user.",
        xattr_name_trusted => "trusted.",
        xattr_name_security => "security.",
        7 => "system.",
        else => "",
    };
    var full_name = try allocator.alloc(u8, prefix.len + short_name.len);
    std.mem.copyForwards(u8, full_name[0..prefix.len], prefix);
    std.mem.copyForwards(u8, full_name[prefix.len..], short_name);
    return full_name;
}

const XattrBlockEntry = struct {
    name_index: u8,
    short_name: []const u8,
    value: []const u8,
};

fn xattrEntryLess(lhs: XattrBlockEntry, rhs: XattrBlockEntry) bool {
    if (lhs.name_index != rhs.name_index) return lhs.name_index < rhs.name_index;
    if (lhs.short_name.len != rhs.short_name.len) return lhs.short_name.len < rhs.short_name.len;
    return std.mem.order(u8, lhs.short_name, rhs.short_name) == .lt;
}

fn sortXattrEntries(entries: []XattrBlockEntry) void {
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        var j = i;
        while (j > 0 and xattrEntryLess(entries[j], entries[j - 1])) : (j -= 1) {
            std.mem.swap(XattrBlockEntry, &entries[j], &entries[j - 1]);
        }
    }
}

const Ext4Crc32c = std.hash.crc.Crc(u32, .{
    .polynomial = 0x1edc6f41,
    .initial = 0xffff_ffff,
    .reflect_input = true,
    .reflect_output = true,
    .xor_output = 0x0000_0000,
});

fn ext4Crc32c(chunks: []const []const u8) u32 {
    var hasher = Ext4Crc32c.init();
    for (chunks) |chunk| hasher.update(chunk);
    return hasher.final();
}

fn xattrEntryHash(name: []const u8, value: []const u8) u32 {
    var hash: u32 = 0;
    for (name) |byte| {
        hash = (hash << 5) ^ (hash >> (32 - 5)) ^ byte;
    }
    var index: usize = 0;
    while (index < value.len) : (index += 4) {
        const word = readInt(u32, value[index .. index + 4]);
        hash = (hash << 16) ^ (hash >> (32 - 16)) ^ word;
    }
    return hash;
}

fn xattrBlockHash(entry_hashes: []const u32) u32 {
    var hash: u32 = 0;
    for (entry_hashes) |entry_hash| {
        if (entry_hash == 0) return 0;
        hash = (hash << 16) ^ (hash >> (32 - 16)) ^ entry_hash;
    }
    return hash;
}

fn buildXattrBlock(allocator: std.mem.Allocator, xattrs: []const OwnedXattr, block_size: u32) PopulateError![]u8 {
    var entries = try allocator.alloc(XattrBlockEntry, xattrs.len);
    defer allocator.free(entries);
    for (xattrs, 0..) |xattr, index| {
        const parsed = try splitXattrName(xattr.name);
        entries[index] = .{
            .name_index = parsed.index,
            .short_name = parsed.short_name,
            .value = xattr.value,
        };
    }
    sortXattrEntries(entries);

    const block = try allocator.alloc(u8, block_size);
    errdefer allocator.free(block);
    @memset(block, 0);

    writeInt(u32, block[0..4], ext4_xattr_magic);
    writeInt(u32, block[4..8], 1);
    writeInt(u32, block[8..12], 1);

    var value_cursor: usize = block_size;
    var entry_cursor: usize = 32;
    const entry_hashes = try allocator.alloc(u32, entries.len);
    defer allocator.free(entry_hashes);

    for (entries, 0..) |entry, index| {
        const entry_len = alignUpU16(@as(u16, @intCast(16 + entry.short_name.len)), 4);
        if (entry_cursor + entry_len + 4 > value_cursor) return error.XattrTooLarge;

        const padded_len = alignUpUsize(entry.value.len, 4);
        value_cursor = alignDownUsize(value_cursor - padded_len, 4);
        if (value_cursor < entry_cursor + entry_len + 4) return error.XattrTooLarge;
        std.mem.copyForwards(u8, block[value_cursor .. value_cursor + entry.value.len], entry.value);

        const value_words = block[value_cursor .. value_cursor + padded_len];
        entry_hashes[index] = xattrEntryHash(entry.short_name, value_words);

        block[entry_cursor] = @intCast(entry.short_name.len);
        block[entry_cursor + 1] = entry.name_index;
        writeInt(u16, block[entry_cursor + 2 .. entry_cursor + 4], @intCast(value_cursor));
        writeInt(u32, block[entry_cursor + 4 .. entry_cursor + 8], 0);
        writeInt(u32, block[entry_cursor + 8 .. entry_cursor + 12], @intCast(entry.value.len));
        writeInt(u32, block[entry_cursor + 12 .. entry_cursor + 16], entry_hashes[index]);
        std.mem.copyForwards(u8, block[entry_cursor + 16 .. entry_cursor + 16 + entry.short_name.len], entry.short_name);
        entry_cursor += entry_len;
    }

    if (entry_cursor + 4 > value_cursor) return error.XattrTooLarge;
    writeInt(u32, block[12..16], xattrBlockHash(entry_hashes));
    return block;
}

fn putDirectoryLeafTail(block: []u8) void {
    const tail = block[block.len - 12 ..];
    @memset(tail, 0);
    writeInt(u16, tail[4..6], 12);
    tail[7] = dir_ft_checksum;
}

fn setDirectoryLeafChecksum(block: []u8, uuid: [16]u8, inode_number: u32, inode_generation: u32) void {
    var inode_le = std.mem.nativeToLittle(u32, inode_number);
    var generation_le = std.mem.nativeToLittle(u32, inode_generation);
    writeInt(u32, block[block.len - 4 ..], ext4Crc32c(&.{
        &uuid,
        std.mem.asBytes(&inode_le),
        std.mem.asBytes(&generation_le),
        block[0 .. block.len - 12],
    }));
}

fn setDxChecksum(block: []u8, count_offset: usize, count: usize, limit: usize, uuid: [16]u8, inode_number: u32, inode_generation: u32) void {
    var inode_le = std.mem.nativeToLittle(u32, inode_number);
    var generation_le = std.mem.nativeToLittle(u32, inode_generation);
    const tail_offset = count_offset + limit * 8;
    const tail = block[tail_offset .. tail_offset + 8];
    @memset(tail, 0);
    writeInt(u32, tail[4..8], ext4Crc32c(&.{
        &uuid,
        std.mem.asBytes(&inode_le),
        std.mem.asBytes(&generation_le),
        block[0 .. count_offset + count * 8],
        tail[0..4],
        tail[4..8],
    }));
}

fn setXattrBlockChecksum(block: []u8, uuid: [16]u8, block_number: u64) void {
    var block_le = std.mem.nativeToLittle(u64, block_number);
    writeInt(u32, block[0x10..0x14], 0);
    writeInt(u32, block[0x10..0x14], ext4Crc32c(&.{
        &uuid,
        std.mem.asBytes(&block_le),
        block,
    }));
}

fn setInodeChecksum(block: []u8, uuid: [16]u8, inode_number: u32) void {
    var inode_le = std.mem.nativeToLittle(u32, inode_number);
    var generation_le = std.mem.nativeToLittle(u32, @as(u32, 0));
    writeInt(u16, block[124..126], 0);
    writeInt(u16, block[124..126], @truncate(ext4Crc32c(&.{
        &uuid,
        std.mem.asBytes(&inode_le),
        std.mem.asBytes(&generation_le),
        block,
    })));
}

fn setSuperblockChecksum(sb: []u8) void {
    writeInt(u32, sb[0x3FC..0x400], ext4Crc32c(&.{sb[0..0x3FC]}));
}

fn bitmapChecksum(uuid: [16]u8, bitmap: []const u8, used_bytes: usize) u32 {
    return ext4Crc32c(&.{ &uuid, bitmap[0..used_bytes] });
}

fn setGroupDescriptorChecksums(gdt: []u8, layout: Layout, uuid: [16]u8) void {
    for (layout.groups, 0..) |_, index| {
        const base = index * group_desc_size;
        const desc = gdt[base .. base + group_desc_size];
        var group_le = std.mem.nativeToLittle(u32, @as(u32, @intCast(index)));
        writeInt(u16, desc[0x1E..0x20], 0);
        writeInt(u16, desc[0x1E..0x20], @truncate(ext4Crc32c(&.{
            &uuid,
            std.mem.asBytes(&group_le),
            desc,
        })));
    }
}

fn md4Rotate(value: u32, comptime shift: u5) u32 {
    return std.math.rotl(u32, value, shift);
}

fn md4F(x: u32, y: u32, z: u32) u32 {
    return z ^ (x & (y ^ z));
}

fn md4G(x: u32, y: u32, z: u32) u32 {
    return (x & y) +% ((x ^ y) & z);
}

fn md4H(x: u32, y: u32, z: u32) u32 {
    return x ^ y ^ z;
}

fn halfMd4Transform(buf: *[4]u32, input: [8]u32) u32 {
    var a = buf[0];
    var b = buf[1];
    var c = buf[2];
    var d = buf[3];

    inline for (.{
        .{ .f = md4F, .x = 0, .s = @as(u5, 3) }, .{ .f = md4F, .x = 1, .s = @as(u5, 7) },
        .{ .f = md4F, .x = 2, .s = @as(u5, 11) }, .{ .f = md4F, .x = 3, .s = @as(u5, 19) },
        .{ .f = md4F, .x = 4, .s = @as(u5, 3) }, .{ .f = md4F, .x = 5, .s = @as(u5, 7) },
        .{ .f = md4F, .x = 6, .s = @as(u5, 11) }, .{ .f = md4F, .x = 7, .s = @as(u5, 19) },
    }, 0..) |step, index| {
        switch (index % 4) {
            0 => a = md4Rotate(a +% step.f(b, c, d) +% input[step.x], step.s),
            1 => d = md4Rotate(d +% step.f(a, b, c) +% input[step.x], step.s),
            2 => c = md4Rotate(c +% step.f(d, a, b) +% input[step.x], step.s),
            else => b = md4Rotate(b +% step.f(c, d, a) +% input[step.x], step.s),
        }
    }

    inline for (.{
        .{ .x = 1, .s = @as(u5, 3) }, .{ .x = 3, .s = @as(u5, 5) },
        .{ .x = 5, .s = @as(u5, 9) }, .{ .x = 7, .s = @as(u5, 13) },
        .{ .x = 0, .s = @as(u5, 3) }, .{ .x = 2, .s = @as(u5, 5) },
        .{ .x = 4, .s = @as(u5, 9) }, .{ .x = 6, .s = @as(u5, 13) },
    }, 0..) |step, index| {
        const value = input[step.x] +% 0x5A82_7999;
        switch (index % 4) {
            0 => a = md4Rotate(a +% md4G(b, c, d) +% value, step.s),
            1 => d = md4Rotate(d +% md4G(a, b, c) +% value, step.s),
            2 => c = md4Rotate(c +% md4G(d, a, b) +% value, step.s),
            else => b = md4Rotate(b +% md4G(c, d, a) +% value, step.s),
        }
    }

    inline for (.{
        .{ .x = 3, .s = @as(u5, 3) }, .{ .x = 7, .s = @as(u5, 9) },
        .{ .x = 2, .s = @as(u5, 11) }, .{ .x = 6, .s = @as(u5, 15) },
        .{ .x = 1, .s = @as(u5, 3) }, .{ .x = 5, .s = @as(u5, 9) },
        .{ .x = 0, .s = @as(u5, 11) }, .{ .x = 4, .s = @as(u5, 15) },
    }, 0..) |step, index| {
        const value = input[step.x] +% 0x6ED9_EBA1;
        switch (index % 4) {
            0 => a = md4Rotate(a +% md4H(b, c, d) +% value, step.s),
            1 => d = md4Rotate(d +% md4H(a, b, c) +% value, step.s),
            2 => c = md4Rotate(c +% md4H(d, a, b) +% value, step.s),
            else => b = md4Rotate(b +% md4H(c, d, a) +% value, step.s),
        }
    }

    buf[0] +%= a;
    buf[1] +%= b;
    buf[2] +%= c;
    buf[3] +%= d;
    return buf[1];
}

fn strToHalfMd4Words(name: []const u8, start: usize) [8]u32 {
    var out: [8]u32 = undefined;
    const remaining = if (start < name.len) name[start..] else "";
    const len = @min(remaining.len, 32);
    var pad = @as(u32, @intCast(len));
    pad |= pad << 8;
    pad |= pad << 16;

    var index: usize = 0;
    while (index < out.len) : (index += 1) out[index] = pad;

    var cursor: usize = 0;
    index = 0;
    while (cursor + 4 <= len and index < out.len) : ({
        cursor += 4;
        index += 1;
    }) {
        const chunk = remaining[cursor .. cursor + 4];
        out[index] = (signedByteToU32(chunk[0]) << 24) |
            (signedByteToU32(chunk[1]) << 16) |
            (signedByteToU32(chunk[2]) << 8) |
            signedByteToU32(chunk[3]);
    }

    if (index < out.len) {
        var value = pad;
        var offset = cursor;
        while (offset < len) : (offset += 1) {
            value = signedByteToU32(remaining[offset]) +% (value << 8);
        }
        out[index] = value;
    }
    return out;
}

fn signedByteToU32(byte: u8) u32 {
    const signed: i32 = @as(i8, @bitCast(byte));
    return @bitCast(signed);
}

fn dirHash(name: []const u8) u32 {
    var buf = [4]u32{ 0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476 };
    var offset: usize = 0;
    while (offset < name.len or (name.len == 0 and offset == 0)) : (offset += 32) {
        const words = strToHalfMd4Words(name, offset);
        _ = halfMd4Transform(&buf, words);
        if (name.len == 0) break;
    }
    var hash = buf[1] & ~@as(u32, 1);
    if (hash == 0xFFFF_FFFE) hash = 0xFFFF_FFFC;
    return hash;
}

test "populate ext4 and round-trip a small tree with a multi-extent file" {
    const io = std.testing.io;
    const path = "test-ext4-roundtrip.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const fs_size: u64 = 160 * 1024 * 1024;
    const big_size: u64 = 130 * 1024 * 1024;

    var tree = InMemoryTree.init(&[_]InMemoryEntry{
        .{ .path = "boot", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0 },
        .{ .path = "boot/kernel.bin", .kind = .file, .mode = 0o644, .uid = 0, .gid = 0, .size = 14, .bytes = "kernel-payload" },
        .{ .path = "boot/initrd.img", .kind = .file, .mode = 0o600, .uid = 42, .gid = 24, .size = big_size, .generator = .pattern },
        .{ .path = "etc", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0 },
        .{ .path = "etc/hostname", .kind = .file, .mode = 0o644, .uid = 1000, .gid = 1000, .size = 10, .bytes = "zvmi-test\n" },
        .{ .path = "usr", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0 },
        .{ .path = "usr/bin", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0 },
        .{ .path = "usr/bin/tool", .kind = .file, .mode = 0o755, .uid = 0, .gid = 0, .size = 7, .bytes = "#!/bin\n" },
        .{ .path = "vmlinuz", .kind = .symlink, .mode = 0o777, .uid = 0, .gid = 0, .size = 15, .bytes = "boot/kernel.bin" },
    });
    tree.bind();

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);

    const info = try populate(io, file, std.testing.allocator, &tree.view, .{
        .length = fs_size,
        .label = "zvmi-ext4",
        .uuid = [_]u8{0x10} ** 16,
        .timestamp = 1_717_171_717,
    });
    try std.testing.expectEqual(writer_feature_compat, info.feature_compat);
    try std.testing.expectEqual(writer_feature_incompat, info.feature_incompat);
    try std.testing.expectEqual(writer_feature_ro_compat_base, info.feature_ro_compat & writer_feature_ro_compat_base);

    var reader = try open(io, file, std.testing.allocator, .{});
    defer reader.deinit();

    const root_entries = try reader.listDir(io, std.testing.allocator, "");
    defer freeDirEntries(std.testing.allocator, root_entries);
    try expectDirNames(root_entries, &.{ "boot", "etc", "usr", "vmlinuz" });

    const boot_entries = try reader.listDir(io, std.testing.allocator, "boot");
    defer freeDirEntries(std.testing.allocator, boot_entries);
    try expectDirNames(boot_entries, &.{ "initrd.img", "kernel.bin" });

    const hostname = try reader.readFileAlloc(io, std.testing.allocator, "etc/hostname");
    defer std.testing.allocator.free(hostname);
    try std.testing.expectEqualSlices(u8, "zvmi-test\n", hostname);

    const link = try reader.readLinkAlloc(io, std.testing.allocator, "vmlinuz");
    defer std.testing.allocator.free(link);
    try std.testing.expectEqualSlices(u8, "boot/kernel.bin", link);

    const tool_stat = try reader.statPath(io, "usr/bin/tool");
    try std.testing.expectEqual(Kind.file, tool_stat.kind);
    try std.testing.expectEqual(@as(u16, 0o755), tool_stat.mode);

    const big_stat = try reader.statPath(io, "boot/initrd.img");
    try std.testing.expectEqual(Kind.file, big_stat.kind);
    try std.testing.expectEqual(big_size, big_stat.size);
    try std.testing.expectEqual(@as(u32, 42), big_stat.uid);
    try std.testing.expectEqual(@as(u32, 24), big_stat.gid);

    const extents = try reader.readExtents(io, std.testing.allocator, "boot/initrd.img");
    defer std.testing.allocator.free(extents);
    try std.testing.expect(extents.len >= 2);

    var offset: u64 = 0;
    var buf: [64 * 1024]u8 = undefined;
    var expected: [64 * 1024]u8 = undefined;
    while (offset < big_size) {
        const chunk = @min(buf.len, @as(usize, @intCast(big_size - offset)));
        const got = try reader.preadPath(io, "boot/initrd.img", buf[0..chunk], offset);
        try std.testing.expectEqual(chunk, got);
        fillPattern(expected[0..chunk], offset);
        try std.testing.expectEqualSlices(u8, expected[0..chunk], buf[0..chunk]);
        offset += chunk;
    }
}

test "populate round-trips files that require extent index blocks" {
    const io = std.testing.io;
    const path = "test-ext4-multilevel-extents.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const fs_size: u64 = 768 * 1024 * 1024;
    const big_size: u64 = 544 * 1024 * 1024;

    var tree = InMemoryTree.init(&[_]InMemoryEntry{
        .{ .path = "boot", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0 },
        .{ .path = "boot/rootfs.img", .kind = .file, .mode = 0o600, .uid = 0, .gid = 0, .size = big_size, .generator = .pattern },
    });
    tree.bind();

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);
    _ = try populate(io, file, std.testing.allocator, &tree.view, .{
        .length = fs_size,
        .uuid = [_]u8{0x33} ** 16,
        .timestamp = 1_717_171_717,
    });

    var reader = try open(io, file, std.testing.allocator, .{});
    defer reader.deinit();

    const inode_number = try reader.lookupPath(io, "boot/rootfs.img");
    const inode = try reader.readInode(io, inode_number);
    const root_header = try parseExtentHeader(inode.block_bytes[0..extent_header_size]);
    try std.testing.expectEqual(@as(u16, 1), root_header.depth);

    const extents = try reader.readExtents(io, std.testing.allocator, "boot/rootfs.img");
    defer std.testing.allocator.free(extents);
    try std.testing.expect(extents.len > max_inline_extents);

    var offset: u64 = 0;
    var buf: [1024 * 1024]u8 = undefined;
    var expected: [1024 * 1024]u8 = undefined;
    while (offset < big_size) {
        const chunk = @min(buf.len, @as(usize, @intCast(big_size - offset)));
        const got = try reader.preadPath(io, "boot/rootfs.img", buf[0..chunk], offset);
        try std.testing.expectEqual(chunk, got);
        fillPattern(expected[0..chunk], offset);
        try std.testing.expectEqualSlices(u8, expected[0..chunk], buf[0..chunk]);
        offset += chunk;
    }
}

test "synthetic extent trees encode and decode beyond depth one" {
    const extent_count = max_inline_extents * extentEntriesPerBlock(default_block_size) + 1;
    const extents = try std.testing.allocator.alloc(Extent, extent_count);
    defer std.testing.allocator.free(extents);
    for (extents, 0..) |*extent, index| {
        extent.* = .{
            .logical_block = @intCast(index),
            .start_block = 10_000 + index,
            .block_count = 1,
        };
    }

    var node = Node{
        .path = "synthetic",
        .name = "synthetic",
        .parent_path = "",
        .parent_index = 0,
        .inode = 12,
        .kind = .file,
        .mode = 0o644,
        .uid = 0,
        .gid = 0,
        .declared_size = @as(u64, extent_count) * default_block_size,
        .content = null,
        .xattrs = &.{},
        .extents = extents,
    };

    const shape = try extentTreeShape(extent_count, default_block_size);
    try std.testing.expectEqual(@as(u16, 2), shape.depth);
    try std.testing.expectEqual(@as(usize, 6), shape.block_count);

    node.extent_tree_blocks = try std.testing.allocator.alloc(ExtentTreeBlock, shape.block_count);
    defer std.testing.allocator.free(node.extent_tree_blocks);
    for (node.extent_tree_blocks, 0..) |*block, index| {
        block.* = .{ .block_number = 20_000 + index };
    }

    try buildExtentTree(std.testing.allocator, &node, default_block_size, shape.depth);

    const root_header = try parseExtentHeader(node.extent_root[0..extent_header_size]);
    try std.testing.expectEqual(@as(u16, 2), root_header.depth);
    try std.testing.expectEqual(@as(u16, 1), root_header.entries);
    const root_child = decodeExtentIndex(node.extent_root[extent_header_size .. extent_header_size + extent_entry_size]);
    try std.testing.expectEqual(node.extent_tree_blocks[shape.block_count - 1].block_number, root_child.leaf_block);
    const internal_header = try parseExtentHeader(node.extent_tree_blocks[shape.block_count - 1].bytes[0..extent_header_size]);
    try std.testing.expectEqual(@as(u16, 1), internal_header.depth);
    try std.testing.expectEqual(@as(u16, 5), internal_header.entries);
    for (0..internal_header.entries) |entry_index| {
        const base = extent_header_size + entry_index * extent_entry_size;
        const child = decodeExtentIndex(node.extent_tree_blocks[shape.block_count - 1].bytes[base .. base + extent_entry_size]);
        try std.testing.expectEqual(node.extent_tree_blocks[entry_index].block_number, child.leaf_block);
    }

    const decoded = try decodeSyntheticExtentTree(std.testing.allocator, node.extent_root[0..], node.extent_tree_blocks[0..]);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqual(extents.len, decoded.len);
    for (extents, decoded) |expected, actual| {
        try std.testing.expectEqualDeep(expected, actual);
    }
}

test "reader rejects missing paths and wrong node kinds" {
    const io = std.testing.io;
    const path = "test-ext4-errors.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    var tree = InMemoryTree.init(&[_]InMemoryEntry{
        .{ .path = "dir", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0 },
        .{ .path = "dir/file", .kind = .file, .mode = 0o644, .uid = 0, .gid = 0, .size = 4, .bytes = "test" },
    });
    tree.bind();

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);
    _ = try populate(io, file, std.testing.allocator, &tree.view, .{ .length = 8 * 1024 * 1024 });

    var reader = try open(io, file, std.testing.allocator, .{});
    defer reader.deinit();

    try std.testing.expectError(error.NotFound, reader.statPath(io, "missing"));
    try std.testing.expectError(error.NotDirectory, reader.listDir(io, std.testing.allocator, "dir/file"));
    try std.testing.expectError(error.NotFile, reader.readFileAlloc(io, std.testing.allocator, "dir"));
}

test "populate respects non-zero partition-relative offsets" {
    const io = std.testing.io;
    const path = "test-ext4-offset.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const prefix_off: u64 = 1 * 1024 * 1024;
    const fs_len: u64 = 8 * 1024 * 1024;
    const suffix_off = prefix_off + fs_len;

    var tree = InMemoryTree.init(&[_]InMemoryEntry{
        .{ .path = "etc", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0 },
        .{ .path = "etc/os-release", .kind = .file, .mode = 0o644, .uid = 0, .gid = 0, .size = 9, .bytes = "NAME=zvmi" },
    });
    tree.bind();

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);
    try file.setLength(io, suffix_off + default_block_size);

    const prefix_guard: [32]u8 = [_]u8{0xA5} ** 32;
    const suffix_guard: [32]u8 = [_]u8{0x5A} ** 32;
    try file.writePositionalAll(io, &prefix_guard, prefix_off - prefix_guard.len);
    try file.writePositionalAll(io, &suffix_guard, suffix_off);

    _ = try populate(io, file, std.testing.allocator, &tree.view, .{
        .offset = prefix_off,
        .length = fs_len,
        .label = "offsetfs",
    });

    var check_prefix: [32]u8 = undefined;
    var check_suffix: [32]u8 = undefined;
    _ = try file.readPositionalAll(io, &check_prefix, prefix_off - check_prefix.len);
    _ = try file.readPositionalAll(io, &check_suffix, suffix_off);
    try std.testing.expectEqualSlices(u8, &prefix_guard, &check_prefix);
    try std.testing.expectEqualSlices(u8, &suffix_guard, &check_suffix);

    var reader = try open(io, file, std.testing.allocator, .{ .offset = prefix_off });
    defer reader.deinit();
    const contents = try reader.readFileAlloc(io, std.testing.allocator, "etc/os-release");
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualSlices(u8, "NAME=zvmi", contents);
}

test "populate round-trips empty regular files" {
    const io = std.testing.io;
    const path = "test-ext4-empty.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    var tree = InMemoryTree.init(&[_]InMemoryEntry{
        .{ .path = "empty", .kind = .file, .mode = 0o640, .uid = 7, .gid = 8, .size = 0 },
    });
    tree.bind();

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);
    _ = try populate(io, file, std.testing.allocator, &tree.view, .{ .length = 8 * 1024 * 1024 });

    var reader = try open(io, file, std.testing.allocator, .{});
    defer reader.deinit();
    const stat = try reader.statPath(io, "empty");
    try std.testing.expectEqual(Kind.file, stat.kind);
    try std.testing.expectEqual(@as(u16, 0o640), stat.mode);
    try std.testing.expectEqual(@as(u64, 0), stat.size);

    const contents = try reader.readFileAlloc(io, std.testing.allocator, "empty");
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqual(@as(usize, 0), contents.len);
}

test "populate round-trips xattrs and metadata checksums" {
    const io = std.testing.io;
    const path = "test-ext4-xattrs.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const selinux = [_]Xattr{
        .{ .name = "security.selinux", .value = "system_u:object_r:bin_t:s0" },
        .{ .name = "user.comment", .value = "hello-from-zvmi" },
    };
    const dir_xattrs = [_]Xattr{
        .{ .name = "user.label", .value = "config-dir" },
    };

    var tree = InMemoryTree.init(&[_]InMemoryEntry{
        .{ .path = "etc", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0, .xattrs = &dir_xattrs },
        .{ .path = "etc/hostname", .kind = .file, .mode = 0o644, .uid = 0, .gid = 0, .size = 10, .bytes = "zvmi-test\n", .xattrs = &selinux },
    });
    tree.bind();

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);

    const info = try populate(io, file, std.testing.allocator, &tree.view, .{
        .length = 16 * 1024 * 1024,
        .uuid = [_]u8{0x42} ** 16,
        .timestamp = 1_717_171_717,
    });
    try std.testing.expectEqual(writer_feature_compat, info.feature_compat);
    try std.testing.expect(info.feature_ro_compat & feature_ro_compat_metadata_csum != 0);

    var reader = try open(io, file, std.testing.allocator, .{});
    defer reader.deinit();

    const file_xattrs = try reader.readXattrsAlloc(io, std.testing.allocator, "etc/hostname");
    defer freeXattrs(std.testing.allocator, file_xattrs);
    try expectXattrValue(file_xattrs, "security.selinux", "system_u:object_r:bin_t:s0");
    try expectXattrValue(file_xattrs, "user.comment", "hello-from-zvmi");

    const dir_entries = try reader.listDir(io, std.testing.allocator, "etc");
    defer freeDirEntries(std.testing.allocator, dir_entries);
    try expectDirNames(dir_entries, &.{ "hostname" });

    const dir_attrs = try reader.readXattrsAlloc(io, std.testing.allocator, "etc");
    defer freeXattrs(std.testing.allocator, dir_attrs);
    try expectXattrValue(dir_attrs, "user.label", "config-dir");

    try expectMetadataChecksumsValid(io, file, 0, "etc/hostname", "etc");
}

test "large directories use htree indexing" {
    const io = std.testing.io;
    const path = "test-ext4-htree.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    var entries = std.array_list.Managed(InMemoryEntry).init(std.testing.allocator);
    defer entries.deinit();
    try entries.append(.{ .path = "big", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0 });
    var names: [300][16]u8 = undefined;
    var index: usize = 0;
    while (index < 300) : (index += 1) {
        const name = try std.fmt.bufPrint(&names[index], "big/file-{d:0>3}", .{index});
        try entries.append(.{
            .path = name,
            .kind = .file,
            .mode = 0o644,
            .uid = 0,
            .gid = 0,
            .size = 0,
        });
    }

    var tree = InMemoryTree.init(entries.items);
    tree.bind();

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);
    _ = try populate(io, file, std.testing.allocator, &tree.view, .{
        .length = 32 * 1024 * 1024,
        .uuid = [_]u8{0x24} ** 16,
        .timestamp = 1_717_171_717,
    });

    var reader = try open(io, file, std.testing.allocator, .{});
    defer reader.deinit();

    const dir_entries = try reader.listDir(io, std.testing.allocator, "big");
    defer freeDirEntries(std.testing.allocator, dir_entries);
    try std.testing.expectEqual(@as(usize, 300), dir_entries.len);
    _ = try reader.statPath(io, "big/file-000");
    _ = try reader.statPath(io, "big/file-127");
    _ = try reader.statPath(io, "big/file-299");

    const dir_inode = try reader.readInode(io, try reader.lookupPath(io, "big"));
    try std.testing.expect(dir_inode.flags & inode_flag_index != 0);
    const extents = try reader.readInodeExtentsAlloc(io, std.testing.allocator, dir_inode);
    defer std.testing.allocator.free(extents);
    try std.testing.expect(extents.len >= 1);

    var root_block: [default_block_size]u8 = undefined;
    _ = try file.readPositionalAll(io, &root_block, extents[0].start_block * default_block_size);
    try std.testing.expectEqual(dx_hash_half_md4, root_block[28]);
    try std.testing.expectEqual(@as(u8, 0), root_block[30]);
    try std.testing.expect(readInt(u16, root_block[34..36]) > 1);
}

test "resize grows ext4 filesystems in place" {
    const io = std.testing.io;
    const path = "test-ext4-resize.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    var tree = InMemoryTree.init(&[_]InMemoryEntry{
        .{ .path = "etc", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0 },
        .{ .path = "etc/os-release", .kind = .file, .mode = 0o644, .uid = 0, .gid = 0, .size = 9, .bytes = "NAME=zvmi" },
    });
    tree.bind();

    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);

    const before = try populate(io, file, std.testing.allocator, &tree.view, .{
        .length = 64 * 1024 * 1024,
        .uuid = [_]u8{0x55} ** 16,
        .timestamp = 1_717_171_717,
    });
    const after = try resize(io, file, std.testing.allocator, .{ .length = 192 * 1024 * 1024 });
    try std.testing.expect(after.block_count > before.block_count);
    try std.testing.expect(after.group_count > before.group_count);
    try std.testing.expect(after.free_block_count > before.free_block_count);

    var reader = try open(io, file, std.testing.allocator, .{});
    defer reader.deinit();
    const bytes = try reader.readFileAlloc(io, std.testing.allocator, "etc/os-release");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "NAME=zvmi", bytes);
}

const InMemoryEntry = struct {
    path: []const u8,
    kind: Kind,
    mode: u16,
    uid: u32,
    gid: u32,
    size: u64 = 0,
    bytes: []const u8 = "",
    xattrs: []const Xattr = &.{},
    generator: enum { none, pattern } = .none,
};

const InMemoryTree = struct {
    entries: []const InMemoryEntry,
    index: usize = 0,
    view: FileTreeView,

    fn init(entries: []const InMemoryEntry) InMemoryTree {
        return .{
            .entries = entries,
            .view = .{
                .ctx = undefined,
                .next_fn = next,
                .reset_fn = reset,
            },
        };
    }

    fn bind(self: *InMemoryTree) void {
        self.view = .{
            .ctx = self,
            .next_fn = next,
            .reset_fn = reset,
        };
    }

    fn reset(ctx: *anyopaque) void {
        const self: *InMemoryTree = @ptrCast(@alignCast(ctx));
        self.index = 0;
    }

    fn next(ctx: *anyopaque) FileTreeView.IteratorError!?FileTreeView.Entry {
        const self: *InMemoryTree = @ptrCast(@alignCast(ctx));
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
            .content = switch (entry.kind) {
                .directory => null,
                .file, .symlink => .{
                    .ctx = &self.entries[self.index - 1],
                    .read_at_fn = readContent,
                },
            },
            .xattrs = entry.xattrs,
        };
    }

    fn readContent(ctx: *const anyopaque, buffer: []u8, offset: u64) FileTreeView.ContentError!usize {
        const entry: *const InMemoryEntry = @ptrCast(@alignCast(ctx));
        switch (entry.generator) {
            .none => {
                const off = std.math.cast(usize, offset) orelse return error.UnexpectedEndOfStream;
                if (off > entry.bytes.len) return error.UnexpectedEndOfStream;
                const n = @min(buffer.len, entry.bytes.len - off);
                std.mem.copyForwards(u8, buffer[0..n], entry.bytes[off .. off + n]);
                return n;
            },
            .pattern => {
                fillPattern(buffer, offset);
                return buffer.len;
            },
        }
    }
};

fn fillPattern(buffer: []u8, offset: u64) void {
    for (buffer, 0..) |*byte, index| {
        byte.* = @truncate(((offset + index) * 31 + 17) & 0xFF);
    }
}

fn decodeSyntheticExtentTree(
    allocator: std.mem.Allocator,
    root_bytes: []const u8,
    blocks: []const ExtentTreeBlock,
) ![]Extent {
    var extents = std.array_list.Managed(Extent).init(allocator);
    errdefer extents.deinit();
    try appendSyntheticExtentTreeEntries(&extents, root_bytes, max_inline_extents, blocks, null);
    return extents.toOwnedSlice();
}

fn appendSyntheticExtentTreeEntries(
    extents: *std.array_list.Managed(Extent),
    node_bytes: []const u8,
    node_capacity: usize,
    blocks: []const ExtentTreeBlock,
    expected_depth: ?u16,
) !void {
    const header = try parseExtentHeader(node_bytes[0..extent_header_size]);
    if (expected_depth) |depth| try std.testing.expectEqual(depth, header.depth);
    try std.testing.expect(header.entries <= header.max);
    try std.testing.expect(header.max <= node_capacity);

    if (header.depth == 0) {
        var entry_index: usize = 0;
        while (entry_index < header.entries) : (entry_index += 1) {
            const base = extent_header_size + entry_index * extent_entry_size;
            try extents.append(decodeExtent(node_bytes[base .. base + extent_entry_size]));
        }
        return;
    }

    var entry_index: usize = 0;
    while (entry_index < header.entries) : (entry_index += 1) {
        const base = extent_header_size + entry_index * extent_entry_size;
        const child = decodeExtentIndex(node_bytes[base .. base + extent_entry_size]);
        const child_block = findSyntheticExtentTreeBlock(blocks, child.leaf_block) orelse return error.TestUnexpectedResult;
        try appendSyntheticExtentTreeEntries(
            extents,
            child_block[0..],
            extentEntriesPerBlock(default_block_size),
            blocks,
            header.depth - 1,
        );
    }
}

fn findSyntheticExtentTreeBlock(blocks: []const ExtentTreeBlock, block_number: u64) ?[]const u8 {
    for (blocks) |*block| {
        if (block.block_number == block_number) return block.bytes[0..];
    }
    return null;
}

fn expectXattrValue(xattrs: []const OwnedXattr, name: []const u8, value: []const u8) !void {
    for (xattrs) |xattr| {
        if (std.mem.eql(u8, xattr.name, name)) {
            try std.testing.expectEqualSlices(u8, value, xattr.value);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

fn expectMetadataChecksumsValid(io: Io, file: Io.File, offset: u64, file_path: []const u8, dir_path: []const u8) !void {
    var sb: [superblock_size]u8 = undefined;
    _ = try file.readPositionalAll(io, &sb, offset + superblock_offset);
    const stored_sb_checksum = readInt(u32, sb[0x3FC..0x400]);
    var sb_copy = sb;
    setSuperblockChecksum(&sb_copy);
    try std.testing.expectEqual(stored_sb_checksum, readInt(u32, sb_copy[0x3FC..0x400]));

    var uuid: [16]u8 = undefined;
    @memcpy(&uuid, sb[0x68..0x78]);
    const total_blocks = readInt(u32, sb[0x04..0x08]);
    const inodes_per_group = readInt(u32, sb[0x28..0x2C]);
    const inode_table_blocks = divCeil(@as(u32, inodes_per_group) * inode_size, default_block_size);
    const group_count = blocksToGroups(total_blocks, default_blocks_per_group);
    const gdt_blocks = blocksForBytes(@as(u64, group_count) * group_desc_size, default_block_size);

    const layout = try buildFixedLayout(std.testing.allocator, total_blocks, default_blocks_per_group, inodes_per_group, inode_table_blocks, gdt_blocks);
    defer std.testing.allocator.free(layout.groups);

    var gdt: [default_block_size]u8 = undefined;
    _ = try file.readPositionalAll(io, &gdt, offset + default_block_size);
    for (layout.groups, 0..) |group, index| {
        const base = index * group_desc_size;
        var desc_copy: [group_desc_size]u8 = undefined;
        @memcpy(&desc_copy, gdt[base .. base + group_desc_size]);
        const stored_desc_checksum = readInt(u16, desc_copy[0x1E..0x20]);
        setGroupDescriptorChecksums(desc_copy[0..], .{
            .total_blocks = layout.total_blocks,
            .group_count = 1,
            .gdt_blocks = layout.gdt_blocks,
            .inodes_per_group = layout.inodes_per_group,
            .inode_table_blocks = layout.inode_table_blocks,
            .groups = @constCast(&[_]GroupLayout{group}),
        }, uuid);
        try std.testing.expectEqual(stored_desc_checksum, readInt(u16, desc_copy[0x1E..0x20]));

        var block_bitmap: [default_block_size]u8 = undefined;
        var inode_bitmap: [default_block_size]u8 = undefined;
        _ = try file.readPositionalAll(io, &block_bitmap, offset + @as(u64, group.block_bitmap_block) * default_block_size);
        _ = try file.readPositionalAll(io, &inode_bitmap, offset + @as(u64, group.inode_bitmap_block) * default_block_size);
        try std.testing.expectEqual(@as(u16, @truncate(bitmapChecksum(uuid, &block_bitmap, default_blocks_per_group / 8))), readInt(u16, gdt[base + 0x18 .. base + 0x1A]));
        try std.testing.expectEqual(@as(u16, @truncate(bitmapChecksum(uuid, &inode_bitmap, inodes_per_group / 8))), readInt(u16, gdt[base + 0x1A .. base + 0x1C]));
    }

    var reader = try open(io, file, std.testing.allocator, .{ .offset = offset });
    defer reader.deinit();

    const file_inode_number = try reader.lookupPath(io, file_path);
    const file_group = (file_inode_number - 1) / reader.inodes_per_group;
    const file_index = (file_inode_number - 1) % reader.inodes_per_group;
    var raw_inode: [inode_size]u8 = undefined;
    _ = try file.readPositionalAll(io, &raw_inode, offset + @as(u64, reader.groups[file_group].inode_table_block) * default_block_size + @as(u64, file_index) * inode_size);
    const stored_inode_checksum = readInt(u16, raw_inode[124..126]);
    var inode_copy = raw_inode;
    setInodeChecksum(&inode_copy, uuid, file_inode_number);
    try std.testing.expectEqual(stored_inode_checksum, readInt(u16, inode_copy[124..126]));

    const parsed_inode = try reader.readInode(io, file_inode_number);
    if (parsed_inode.file_acl_block != 0) {
        var xattr_block: [default_block_size]u8 = undefined;
        _ = try file.readPositionalAll(io, &xattr_block, offset + @as(u64, parsed_inode.file_acl_block) * default_block_size);
        const stored_xattr_checksum = readInt(u32, xattr_block[0x10..0x14]);
        var xattr_copy = xattr_block;
        setXattrBlockChecksum(&xattr_copy, uuid, parsed_inode.file_acl_block);
        try std.testing.expectEqual(stored_xattr_checksum, readInt(u32, xattr_copy[0x10..0x14]));
    }

    const dir_inode_number = try reader.lookupPath(io, dir_path);
    const dir_inode = try reader.readInode(io, dir_inode_number);
    const dir_extents = try reader.readInodeExtentsAlloc(io, std.testing.allocator, dir_inode);
    defer std.testing.allocator.free(dir_extents);
    var dir_block: [default_block_size]u8 = undefined;
    _ = try file.readPositionalAll(io, &dir_block, offset + dir_extents[0].start_block * default_block_size);
    const stored_dir_checksum = readInt(u32, dir_block[dir_block.len - 4 ..]);
    var dir_copy = dir_block;
    setDirectoryLeafChecksum(&dir_copy, uuid, dir_inode_number, 0);
    try std.testing.expectEqual(stored_dir_checksum, readInt(u32, dir_copy[dir_copy.len - 4 ..]));
}

fn expectDirNames(entries: []const DirEntry, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, entries.len);
    for (expected, 0..) |name, index| {
        try std.testing.expectEqualSlices(u8, name, entries[index].name);
    }
}
