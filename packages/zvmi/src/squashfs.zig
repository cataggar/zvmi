//! SquashFS 4.0 **read-only** reader.
//!
//! This implementation intentionally targets the documented SquashFS 4.0
//! on-disk layout but only supports *uncompressed* metadata/data/fragment
//! blocks. That keeps the reader self-contained for this issue's synthetic
//! fixtures while still validating the real inode/directory/fragment-table
//! structure. Real Azure Linux installer media stores its embedded rootfs in
//! compressed SquashFS (typically zstd/xz), so adding a decompressor is a
//! follow-up once a small decoder dependency is acceptable in this repo.

const std = @import("std");
const Io = std.Io;

pub const magic: u32 = 0x7371_7368; // "hsqs" little-endian on disk
pub const major_version: u16 = 4;
pub const metadata_block_size: usize = 8192;
pub const metadata_uncompressed_bit: u16 = 1 << 15;
pub const data_uncompressed_bit: u32 = 1 << 24;
pub const invalid_fragment: u32 = 0xFFFF_FFFF;
pub const invalid_table: u64 = std.math.maxInt(u64);

pub const EntryKind = enum { file, directory, symlink };

pub const DirEntry = struct {
    name: []const u8,
    index: usize,
    kind: EntryKind,
};

pub const Entry = struct {
    name: []const u8,
    parent: ?usize,
    kind: EntryKind,
    size: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    data_start: u64,
    block_sizes: []u32,
    fragment_index: ?u32,
    fragment_offset: u32,
    symlink_target: ?[]const u8,
};

pub const Superblock = struct {
    inodes: u32,
    block_size: u32,
    fragments: u32,
    compression: u16,
    block_log: u16,
    flags: u16,
    no_ids: u16,
    root_inode: u64,
    bytes_used: u64,
    id_table_start: u64,
    xattr_id_table_start: u64,
    inode_table_start: u64,
    directory_table_start: u64,
    fragment_table_start: u64,
    lookup_table_start: u64,
};

pub const OpenError = error{
    BadMagic,
    UnsupportedVersion,
    CompressedMetadataUnsupported,
    CompressedDataUnsupported,
    InvalidMetadataBlock,
    InvalidMetadataReference,
    InvalidDirectoryEntry,
    InvalidFragmentIndex,
    InvalidIdIndex,
    UnsupportedInodeType,
} || Io.File.OpenError || Io.File.ReadPositionalError || Io.File.StatError || std.mem.Allocator.Error;

pub const LookupError = error{ NotFound, NotADirectory, TooManySymlinks, BrokenSymlink } || std.mem.Allocator.Error;
pub const ReadError = error{ NotAFile, NotASymlink, CompressedDataUnsupported, InvalidFragmentIndex } || Io.File.ReadPositionalError || std.mem.Allocator.Error;

pub const Reader = struct {
    allocator: std.mem.Allocator,
    file: Io.File,
    superblock: Superblock,
    ids: []u32,
    fragments: []FragmentEntry,
    entries: []Entry,
    root_index: usize,

    pub fn openPath(allocator: std.mem.Allocator, io: Io, path: []const u8) OpenError!Reader {
        const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
        errdefer file.close(io);
        return openFile(allocator, io, file);
    }

    pub fn openFile(allocator: std.mem.Allocator, io: Io, file: Io.File) OpenError!Reader {
        const stat = try file.stat(io);
        var sb_buf: [96]u8 = undefined;
        _ = try file.readPositionalAll(io, &sb_buf, 0);
        const sb = try parseSuperblock(&sb_buf);

        const fragment_meta_start = try firstIndexedMetadataStart(allocator, io, file, sb.fragment_table_start, sb.fragments, @sizeOf(FragmentEntry));
        const id_meta_start = try firstIndexedMetadataStart(allocator, io, file, sb.id_table_start, sb.no_ids, @sizeOf(u32));

        const inode_table = try readMetadataTable(allocator, io, file, sb.inode_table_start, sb.directory_table_start);
        errdefer inode_table.deinit(allocator);

        const directory_table_end = minOptionalU64(fragment_meta_start, id_meta_start) orelse stat.size;
        const directory_table = try readMetadataTable(allocator, io, file, sb.directory_table_start, directory_table_end);
        errdefer directory_table.deinit(allocator);

        const ids = try readIdTable(allocator, io, file, sb, id_meta_start);
        errdefer allocator.free(ids);

        const fragments = try readFragmentTable(allocator, io, file, sb, fragment_meta_start);
        errdefer allocator.free(fragments);

        var builder = Builder{
            .allocator = allocator,
            .ids = ids,
            .fragments = fragments,
            .inode_table = inode_table,
            .directory_table = directory_table,
            .block_size = sb.block_size,
            .entries = std.array_list.Managed(Entry).init(allocator),
        };
        errdefer builder.deinit();

        const root_index = try builder.parseNode(sb.root_inode, null, "/");

        const entries = try builder.entries.toOwnedSlice();
        builder.entries = std.array_list.Managed(Entry).init(allocator);
        builder.inode_table.deinit(allocator);
        builder.directory_table.deinit(allocator);

        return .{
            .allocator = allocator,
            .file = file,
            .superblock = sb,
            .ids = ids,
            .fragments = fragments,
            .entries = entries,
            .root_index = root_index,
        };
    }

    pub fn close(self: *Reader, io: Io) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.block_sizes);
            if (entry.symlink_target) |target| self.allocator.free(target);
        }
        self.allocator.free(self.entries);
        self.allocator.free(self.ids);
        self.allocator.free(self.fragments);
        self.file.close(io);
        self.* = undefined;
    }

    pub fn getEntry(self: Reader, index: usize) *const Entry {
        return &self.entries[index];
    }

    pub fn lookup(self: Reader, path: []const u8) LookupError!usize {
        return self.lookupFrom(self.root_index, path, false, 0);
    }

    pub fn listDirAlloc(self: Reader, allocator: std.mem.Allocator, index: usize) (std.mem.Allocator.Error || error{NotADirectory})![]DirEntry {
        if (self.entries[index].kind != .directory) return error.NotADirectory;
        var list = std.array_list.Managed(DirEntry).init(allocator);
        errdefer list.deinit();
        for (self.entries, 0..) |entry, i| {
            if (entry.parent == index) try list.append(.{ .name = entry.name, .index = i, .kind = entry.kind });
        }
        std.mem.sort(DirEntry, list.items, {}, dirEntryLessThan);
        return list.toOwnedSlice();
    }

    pub fn readFileAlloc(self: Reader, allocator: std.mem.Allocator, io: Io, index: usize) ReadError![]u8 {
        const entry = self.entries[index];
        if (entry.kind != .file) return error.NotAFile;

        const out = try allocator.alloc(u8, @intCast(entry.size));
        errdefer allocator.free(out);
        @memset(out, 0);

        var file_off = entry.data_start;
        var produced: usize = 0;
        for (entry.block_sizes) |raw_size| {
            const chunk_len: usize = @intCast(@min(@as(u64, self.superblock.block_size), entry.size - produced));
            if (raw_size == 0) {
                produced += chunk_len;
                continue;
            }
            if ((raw_size & data_uncompressed_bit) == 0) return error.CompressedDataUnsupported;
            const stored_size = raw_size & ~data_uncompressed_bit;
            const got = try self.file.readPositionalAll(io, out[produced..][0..chunk_len], file_off);
            if (got < chunk_len) @memset(out[produced + got ..][0 .. chunk_len - got], 0);
            file_off += stored_size;
            produced += chunk_len;
        }

        if (produced < out.len) {
            const frag_index = entry.fragment_index orelse return out;
            if (frag_index >= self.fragments.len) return error.InvalidFragmentIndex;
            const fragment = self.fragments[frag_index];
            if ((fragment.raw_size & data_uncompressed_bit) == 0) return error.CompressedDataUnsupported;
            const stored_size = fragment.raw_size & ~data_uncompressed_bit;
            const fragment_bytes = try allocator.alloc(u8, stored_size);
            defer allocator.free(fragment_bytes);
            _ = try self.file.readPositionalAll(io, fragment_bytes, fragment.start_block);

            const tail_len = out.len - produced;
            @memcpy(out[produced..], fragment_bytes[entry.fragment_offset .. entry.fragment_offset + tail_len]);
        }

        return out;
    }

    pub fn readLink(self: Reader, index: usize) ReadError![]const u8 {
        if (self.entries[index].kind != .symlink) return error.NotASymlink;
        return self.entries[index].symlink_target.?;
    }

    pub fn resolveSymlink(self: Reader, index: usize) LookupError!usize {
        if (self.entries[index].kind != .symlink) return error.BrokenSymlink;
        return self.lookupFrom(self.entries[index].parent orelse self.root_index, self.entries[index].symlink_target.?, true, 1);
    }

    fn lookupFrom(self: Reader, start_index: usize, path: []const u8, follow_final_symlink: bool, depth: u8) LookupError!usize {
        if (depth > 16) return error.TooManySymlinks;
        var current = if (std.mem.startsWith(u8, path, "/")) self.root_index else start_index;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
            if (std.mem.eql(u8, component, "..")) {
                current = self.entries[current].parent orelse self.root_index;
                continue;
            }
            if (self.entries[current].kind != .directory) return error.NotADirectory;
            const child = self.findChild(current, component) orelse return error.NotFound;
            const is_last = it.peek() == null;
            if (self.entries[child].kind == .symlink and (!is_last or follow_final_symlink)) {
                current = self.lookupFrom(self.entries[child].parent orelse self.root_index, self.entries[child].symlink_target.?, true, depth + 1) catch |err| switch (err) {
                    error.NotFound, error.NotADirectory => return error.BrokenSymlink,
                    else => return err,
                };
            } else {
                current = child;
            }
        }
        return current;
    }

    fn findChild(self: Reader, parent: usize, name: []const u8) ?usize {
        for (self.entries, 0..) |entry, i| {
            if (entry.parent == parent and std.mem.eql(u8, entry.name, name)) return i;
        }
        return null;
    }
};

const FragmentEntry = struct {
    start_block: u64,
    raw_size: u32,
};

const MetaBlockMap = struct {
    disk_rel_offset: u64,
    decompressed_offset: usize,
    size: usize,
};

const TableData = struct {
    bytes: []u8 = &.{},
    maps: []MetaBlockMap = &.{},

    fn deinit(self: *const TableData, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.maps);
    }
};

const InodeData = struct {
    kind: EntryKind,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    data_start: u64,
    block_sizes: []u32,
    fragment_index: ?u32,
    fragment_offset: u32,
    symlink_target: ?[]u8,
    dir_start_block: u32,
    dir_offset: u16,
    dir_size: u32,

    fn deinit(self: *InodeData, allocator: std.mem.Allocator) void {
        allocator.free(self.block_sizes);
        if (self.symlink_target) |target| allocator.free(target);
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    ids: []const u32,
    fragments: []const FragmentEntry,
    inode_table: TableData,
    directory_table: TableData,
    block_size: u32,
    entries: std.array_list.Managed(Entry),

    fn deinit(self: *Builder) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.block_sizes);
            if (entry.symlink_target) |target| self.allocator.free(target);
        }
        self.entries.deinit();
        self.inode_table.deinit(self.allocator);
        self.directory_table.deinit(self.allocator);
    }

    fn parseNode(self: *Builder, inode_ref: u64, parent: ?usize, display_name: []const u8) OpenError!usize {
        var inode = try self.readInode(inode_ref);
        defer inode.deinit(self.allocator);

        const name = try self.allocator.dupe(u8, display_name);
        errdefer self.allocator.free(name);
        const block_sizes = try self.allocator.dupe(u32, inode.block_sizes);
        errdefer self.allocator.free(block_sizes);
        const target = if (inode.symlink_target) |link| try self.allocator.dupe(u8, link) else null;
        errdefer if (target) |link| self.allocator.free(link);

        try self.entries.append(.{
            .name = name,
            .parent = parent,
            .kind = inode.kind,
            .size = inode.size,
            .mode = inode.mode,
            .uid = inode.uid,
            .gid = inode.gid,
            .data_start = inode.data_start,
            .block_sizes = block_sizes,
            .fragment_index = inode.fragment_index,
            .fragment_offset = inode.fragment_offset,
            .symlink_target = target,
        });
        const index = self.entries.items.len - 1;

        if (inode.kind == .directory) {
            try self.parseDirectory(index, inode.dir_start_block, inode.dir_offset, inode.dir_size);
        }
        return index;
    }

    fn parseDirectory(self: *Builder, parent_index: usize, start_block: u32, start_offset: u16, dir_size: u32) OpenError!void {
        var cursor = try translateMetadataRef(&self.directory_table, start_block, start_offset);
        const end = cursor + dir_size;
        if (end > self.directory_table.bytes.len) return error.InvalidDirectoryEntry;

        while (cursor < end) {
            if (cursor + 12 > end) return error.InvalidDirectoryEntry;
            const header = self.directory_table.bytes[cursor .. cursor + 12];
            cursor += 12;
            const count = std.mem.readInt(u32, header[0..4], .little) + 1;
            const shared_block = std.mem.readInt(u32, header[4..8], .little);
            const _inode_base = std.mem.readInt(u32, header[8..12], .little);
            _ = _inode_base;

            var i: u32 = 0;
            while (i < count) : (i += 1) {
                if (cursor + 8 > end) return error.InvalidDirectoryEntry;
                const entry = self.directory_table.bytes[cursor .. cursor + 8];
                cursor += 8;

                const inode_offset = std.mem.readInt(u16, entry[0..2], .little);
                const name_len = std.mem.readInt(u16, entry[6..8], .little) + 1;
                if (cursor + name_len > end) return error.InvalidDirectoryEntry;
                const name_bytes = self.directory_table.bytes[cursor .. cursor + name_len];
                cursor += name_len;

                const inode_ref = (@as(u64, shared_block) << 16) | inode_offset;
                _ = try self.parseNode(inode_ref, parent_index, name_bytes);
            }
        }
    }

    fn readInode(self: *Builder, inode_ref: u64) OpenError!InodeData {
        const block = inode_ref >> 16;
        const offset: u16 = @intCast(inode_ref & 0xFFFF);
        const base_index = try translateMetadataRef(&self.inode_table, block, offset);
        if (base_index + 16 > self.inode_table.bytes.len) return error.InvalidMetadataReference;
        const base = self.inode_table.bytes[base_index..];

        const inode_type = std.mem.readInt(u16, base[0..2], .little);
        const base_mode = std.mem.readInt(u16, base[2..4], .little);
        const uid_index = std.mem.readInt(u16, base[4..6], .little);
        const gid_index = std.mem.readInt(u16, base[6..8], .little);
        if (uid_index >= self.ids.len or gid_index >= self.ids.len) return error.InvalidIdIndex;

        const uid = self.ids[uid_index];
        const gid = self.ids[gid_index];

        return switch (inode_type) {
            1 => try self.readDirInode(base, base_mode, uid, gid, false),
            2 => try self.readRegInode(base, base_mode, uid, gid, false),
            3 => try self.readSymlinkInode(base, base_mode, uid, gid, false),
            8 => try self.readDirInode(base, base_mode, uid, gid, true),
            9 => try self.readRegInode(base, base_mode, uid, gid, true),
            10 => try self.readSymlinkInode(base, base_mode, uid, gid, true),
            else => error.UnsupportedInodeType,
        };
    }

    fn readDirInode(self: *Builder, base: []const u8, base_mode: u16, uid: u32, gid: u32, long: bool) OpenError!InodeData {
        if (long) {
            if (base.len < 40) return error.InvalidMetadataReference;
            return .{
                .kind = .directory,
                .mode = typeBits(.directory) | base_mode,
                .uid = uid,
                .gid = gid,
                .size = std.mem.readInt(u32, base[20..24], .little),
                .data_start = 0,
                .block_sizes = try self.allocator.alloc(u32, 0),
                .fragment_index = null,
                .fragment_offset = 0,
                .symlink_target = null,
                .dir_start_block = std.mem.readInt(u32, base[24..28], .little),
                .dir_offset = std.mem.readInt(u16, base[34..36], .little),
                .dir_size = std.mem.readInt(u32, base[20..24], .little),
            };
        }
        if (base.len < 32) return error.InvalidMetadataReference;
        return .{
            .kind = .directory,
            .mode = typeBits(.directory) | base_mode,
            .uid = uid,
            .gid = gid,
            .size = std.mem.readInt(u16, base[24..26], .little),
            .data_start = 0,
            .block_sizes = try self.allocator.alloc(u32, 0),
            .fragment_index = null,
            .fragment_offset = 0,
            .symlink_target = null,
            .dir_start_block = std.mem.readInt(u32, base[16..20], .little),
            .dir_offset = std.mem.readInt(u16, base[26..28], .little),
            .dir_size = std.mem.readInt(u16, base[24..26], .little),
        };
    }

    fn readRegInode(self: *Builder, base: []const u8, base_mode: u16, uid: u32, gid: u32, long: bool) OpenError!InodeData {
        if (long) {
            if (base.len < 56) return error.InvalidMetadataReference;
            const file_size = std.mem.readInt(u64, base[24..32], .little);
            const fragment = std.mem.readInt(u32, base[44..48], .little);
            const remainder = file_size % self.block_size;
            const full_blocks = file_size / self.block_size;
            const block_count: usize = @intCast(full_blocks + (if (fragment == invalid_fragment and remainder != 0) @as(u64, 1) else 0));
            const block_list = try readBlockSizes(self.allocator, base[56..], block_count);
            return .{
                .kind = .file,
                .mode = typeBits(.file) | base_mode,
                .uid = uid,
                .gid = gid,
                .size = file_size,
                .data_start = std.mem.readInt(u64, base[16..24], .little),
                .block_sizes = block_list,
                .fragment_index = if (fragment == invalid_fragment) null else fragment,
                .fragment_offset = std.mem.readInt(u32, base[48..52], .little),
                .symlink_target = null,
                .dir_start_block = 0,
                .dir_offset = 0,
                .dir_size = 0,
            };
        }

        if (base.len < 32) return error.InvalidMetadataReference;
        const file_size = std.mem.readInt(u32, base[28..32], .little);
        const fragment = std.mem.readInt(u32, base[20..24], .little);
        const remainder = file_size % self.block_size;
        const full_blocks = file_size / self.block_size;
        const block_count: usize = @intCast(full_blocks + (if (fragment == invalid_fragment and remainder != 0) @as(u32, 1) else 0));
        const block_list = try readBlockSizes(self.allocator, base[32..], block_count);
        return .{
            .kind = .file,
            .mode = typeBits(.file) | base_mode,
            .uid = uid,
            .gid = gid,
            .size = file_size,
            .data_start = std.mem.readInt(u32, base[16..20], .little),
            .block_sizes = block_list,
            .fragment_index = if (fragment == invalid_fragment) null else fragment,
            .fragment_offset = std.mem.readInt(u32, base[24..28], .little),
            .symlink_target = null,
            .dir_start_block = 0,
            .dir_offset = 0,
            .dir_size = 0,
        };
    }

    fn readSymlinkInode(self: *Builder, base: []const u8, base_mode: u16, uid: u32, gid: u32, long: bool) OpenError!InodeData {
        if (base.len < 24) return error.InvalidMetadataReference;
        const symlink_size = std.mem.readInt(u32, base[20..24], .little);
        const extra: usize = if (long) 4 else 0;
        if (24 + symlink_size + extra > base.len) return error.InvalidMetadataReference;
        const target = try self.allocator.dupe(u8, base[24 .. 24 + symlink_size]);
        return .{
            .kind = .symlink,
            .mode = typeBits(.symlink) | base_mode,
            .uid = uid,
            .gid = gid,
            .size = symlink_size,
            .data_start = 0,
            .block_sizes = try self.allocator.alloc(u32, 0),
            .fragment_index = null,
            .fragment_offset = 0,
            .symlink_target = target,
            .dir_start_block = 0,
            .dir_offset = 0,
            .dir_size = 0,
        };
    }
};

fn parseSuperblock(buf: *const [96]u8) OpenError!Superblock {
    if (std.mem.readInt(u32, buf[0..4], .little) != magic) return error.BadMagic;
    if (std.mem.readInt(u16, buf[28..30], .little) != major_version) return error.UnsupportedVersion;

    return .{
        .inodes = std.mem.readInt(u32, buf[4..8], .little),
        .block_size = std.mem.readInt(u32, buf[12..16], .little),
        .fragments = std.mem.readInt(u32, buf[16..20], .little),
        .compression = std.mem.readInt(u16, buf[20..22], .little),
        .block_log = std.mem.readInt(u16, buf[22..24], .little),
        .flags = std.mem.readInt(u16, buf[24..26], .little),
        .no_ids = std.mem.readInt(u16, buf[26..28], .little),
        .root_inode = std.mem.readInt(u64, buf[32..40], .little),
        .bytes_used = std.mem.readInt(u64, buf[40..48], .little),
        .id_table_start = std.mem.readInt(u64, buf[48..56], .little),
        .xattr_id_table_start = std.mem.readInt(u64, buf[56..64], .little),
        .inode_table_start = std.mem.readInt(u64, buf[64..72], .little),
        .directory_table_start = std.mem.readInt(u64, buf[72..80], .little),
        .fragment_table_start = std.mem.readInt(u64, buf[80..88], .little),
        .lookup_table_start = std.mem.readInt(u64, buf[88..96], .little),
    };
}

fn firstIndexedMetadataStart(allocator: std.mem.Allocator, io: Io, file: Io.File, index_table_start: u64, item_count: anytype, item_size: usize) OpenError!?u64 {
    if (index_table_start == invalid_table or item_count == 0) return null;
    const count = std.math.divCeil(usize, @as(usize, item_count) * item_size, metadata_block_size) catch unreachable;
    if (count == 0) return null;
    const table = try allocator.alloc(u8, count * 8);
    defer allocator.free(table);
    _ = try file.readPositionalAll(io, table, index_table_start);
    return std.mem.readInt(u64, table[0..8], .little);
}

fn readIndexedTableOffsets(allocator: std.mem.Allocator, io: Io, file: Io.File, index_table_start: u64, item_count: usize, item_size: usize) OpenError![]u64 {
    const count = std.math.divCeil(usize, item_count * item_size, metadata_block_size) catch unreachable;
    if (count == 0) return allocator.alloc(u64, 0);
    const table = try allocator.alloc(u8, count * 8);
    defer allocator.free(table);
    _ = try file.readPositionalAll(io, table, index_table_start);
    const out = try allocator.alloc(u64, count);
    for (out, 0..) |*value, i| value.* = std.mem.readInt(u64, table[i * 8 ..][0..8], .little);
    return out;
}

fn readMetadataTable(allocator: std.mem.Allocator, io: Io, file: Io.File, start: u64, end: u64) OpenError!TableData {
    var bytes = std.array_list.Managed(u8).init(allocator);
    errdefer bytes.deinit();
    var maps = std.array_list.Managed(MetaBlockMap).init(allocator);
    errdefer maps.deinit();

    var offset = start;
    while (offset < end) {
        var header_buf: [2]u8 = undefined;
        _ = try file.readPositionalAll(io, &header_buf, offset);
        const header = std.mem.readInt(u16, &header_buf, .little);
        const size = header & ~metadata_uncompressed_bit;
        if (size == 0) return error.InvalidMetadataBlock;
        if ((header & metadata_uncompressed_bit) == 0) return error.CompressedMetadataUnsupported;
        if (offset + 2 + size > end) return error.InvalidMetadataBlock;

        const payload = try allocator.alloc(u8, size);
        defer allocator.free(payload);
        _ = try file.readPositionalAll(io, payload, offset + 2);
        try maps.append(.{ .disk_rel_offset = offset - start, .decompressed_offset = bytes.items.len, .size = size });
        try bytes.appendSlice(payload);
        offset += 2 + size;
    }

    return .{ .bytes = try bytes.toOwnedSlice(), .maps = try maps.toOwnedSlice() };
}

fn translateMetadataRef(table: *const TableData, block: u64, offset: u16) OpenError!usize {
    for (table.maps) |map| {
        if (map.disk_rel_offset == block) {
            if (offset > map.size) return error.InvalidMetadataReference;
            return map.decompressed_offset + offset;
        }
    }
    return error.InvalidMetadataReference;
}

fn readIdTable(allocator: std.mem.Allocator, io: Io, file: Io.File, sb: Superblock, id_meta_start: ?u64) OpenError![]u32 {
    if (sb.no_ids == 0) return allocator.alloc(u32, 0);
    const start = id_meta_start orelse return error.InvalidMetadataBlock;
    var table = try readMetadataTable(allocator, io, file, start, sb.id_table_start);
    defer table.deinit(allocator);

    const ids = try allocator.alloc(u32, sb.no_ids);
    for (ids, 0..) |*id, i| {
        const off = i * 4;
        id.* = std.mem.readInt(u32, table.bytes[off..][0..4], .little);
    }
    return ids;
}

fn readFragmentTable(allocator: std.mem.Allocator, io: Io, file: Io.File, sb: Superblock, fragment_meta_start: ?u64) OpenError![]FragmentEntry {
    if (sb.fragments == 0) return allocator.alloc(FragmentEntry, 0);
    const start = fragment_meta_start orelse return error.InvalidMetadataBlock;
    const offsets = try readIndexedTableOffsets(allocator, io, file, sb.fragment_table_start, sb.fragments, @sizeOf(FragmentEntry));
    defer allocator.free(offsets);

    var table = try readMetadataTable(allocator, io, file, start, sb.fragment_table_start);
    defer table.deinit(allocator);

    const entries = try allocator.alloc(FragmentEntry, sb.fragments);
    for (entries, 0..) |*entry, i| {
        const off = i * 16;
        entry.* = .{
            .start_block = std.mem.readInt(u64, table.bytes[off..][0..8], .little),
            .raw_size = std.mem.readInt(u32, table.bytes[off + 8 ..][0..4], .little),
        };
    }
    return entries;
}

fn readBlockSizes(allocator: std.mem.Allocator, bytes: []const u8, count: usize) OpenError![]u32 {
    const out = try allocator.alloc(u32, count);
    for (out, 0..) |*value, i| {
        const off = i * 4;
        if (off + 4 > bytes.len) return error.InvalidMetadataReference;
        value.* = std.mem.readInt(u32, bytes[off..][0..4], .little);
    }
    return out;
}

fn typeBits(kind: EntryKind) u32 {
    return switch (kind) {
        .directory => 0o040000,
        .file => 0o100000,
        .symlink => 0o120000,
    };
}

fn minOptionalU64(a: ?u64, b: ?u64) ?u64 {
    if (a == null) return b;
    if (b == null) return a;
    return @min(a.?, b.?);
}

fn dirEntryLessThan(_: void, a: DirEntry, b: DirEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
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

fn appendMetadataBlock(list: *std.array_list.Managed(u8), payload: []const u8) !void {
    try appendU16Le(list, @as(u16, @intCast(payload.len)) | metadata_uncompressed_bit);
    try list.appendSlice(payload);
}

fn buildSyntheticSquashfsImage(allocator: std.mem.Allocator) ![]u8 {
    const block_size: u32 = 1024;
    const block_log: u16 = 10;
    const full_data = [_]u8{'A'} ** block_size;
    const fragment_tail = [_]u8{'B'} ** 476;

    const data_block_start: u64 = 96;
    const fragment_data_start: u64 = data_block_start + full_data.len;

    var inode_payload = std.array_list.Managed(u8).init(allocator);
    defer inode_payload.deinit();

    const root_inode_offset: u16 = @intCast(inode_payload.items.len);
    _ = root_inode_offset;
    try appendU16Le(&inode_payload, 1);
    try appendU16Le(&inode_payload, 0o755);
    try appendU16Le(&inode_payload, 0);
    try appendU16Le(&inode_payload, 0);
    try appendU32Le(&inode_payload, 0);
    try appendU32Le(&inode_payload, 1);
    try appendU32Le(&inode_payload, 0);
    try appendU32Le(&inode_payload, 2);
    try appendU16Le(&inode_payload, 23);
    try appendU16Le(&inode_payload, 0);
    try appendU32Le(&inode_payload, 1);

    const nested_inode_offset: u16 = @intCast(inode_payload.items.len);
    try appendU16Le(&inode_payload, 1);
    try appendU16Le(&inode_payload, 0o755);
    try appendU16Le(&inode_payload, 0);
    try appendU16Le(&inode_payload, 0);
    try appendU32Le(&inode_payload, 0);
    try appendU32Le(&inode_payload, 2);
    try appendU32Le(&inode_payload, 0);
    try appendU32Le(&inode_payload, 2);
    try appendU16Le(&inode_payload, 31);
    try appendU16Le(&inode_payload, 23);
    try appendU32Le(&inode_payload, 1);

    const file_inode_offset: u16 = @intCast(inode_payload.items.len);
    try appendU16Le(&inode_payload, 2);
    try appendU16Le(&inode_payload, 0o644);
    try appendU16Le(&inode_payload, 0);
    try appendU16Le(&inode_payload, 0);
    try appendU32Le(&inode_payload, 0);
    try appendU32Le(&inode_payload, 3);
    try appendU32Le(&inode_payload, @intCast(data_block_start));
    try appendU32Le(&inode_payload, 0);
    try appendU32Le(&inode_payload, 0);
    try appendU32Le(&inode_payload, 1500);
    try appendU32Le(&inode_payload, block_size | data_uncompressed_bit);

    var dir_payload = std.array_list.Managed(u8).init(allocator);
    defer dir_payload.deinit();
    try appendU32Le(&dir_payload, 0);
    try appendU32Le(&dir_payload, 0);
    try appendU32Le(&dir_payload, 2);
    try appendU16Le(&dir_payload, nested_inode_offset);
    try appendU16Le(&dir_payload, 0);
    try appendU16Le(&dir_payload, 1);
    try appendU16Le(&dir_payload, 2);
    try dir_payload.appendSlice("etc");

    try appendU32Le(&dir_payload, 0);
    try appendU32Le(&dir_payload, 0);
    try appendU32Le(&dir_payload, 3);
    try appendU16Le(&dir_payload, file_inode_offset);
    try appendU16Le(&dir_payload, 0);
    try appendU16Le(&dir_payload, 2);
    try appendU16Le(&dir_payload, 10);
    try dir_payload.appendSlice("message.txt");

    var fragment_payload = std.array_list.Managed(u8).init(allocator);
    defer fragment_payload.deinit();
    try appendU64Le(&fragment_payload, fragment_data_start);
    try appendU32Le(&fragment_payload, fragment_tail.len | data_uncompressed_bit);
    try appendU32Le(&fragment_payload, 0);

    var id_payload = std.array_list.Managed(u8).init(allocator);
    defer id_payload.deinit();
    try appendU32Le(&id_payload, 0);

    var image = std.array_list.Managed(u8).init(allocator);
    errdefer image.deinit();
    try image.resize(96);
    @memset(image.items, 0);
    try image.appendSlice(&full_data);
    try image.appendSlice(&fragment_tail);

    const inode_table_start: u64 = image.items.len;
    try appendMetadataBlock(&image, inode_payload.items);
    const directory_table_start: u64 = image.items.len;
    try appendMetadataBlock(&image, dir_payload.items);
    const fragment_meta_start: u64 = image.items.len;
    try appendMetadataBlock(&image, fragment_payload.items);
    const fragment_table_start: u64 = image.items.len;
    try appendU64Le(&image, fragment_meta_start);
    const id_meta_start: u64 = image.items.len;
    try appendMetadataBlock(&image, id_payload.items);
    const id_table_start: u64 = image.items.len;
    try appendU64Le(&image, id_meta_start);
    const bytes_used: u64 = image.items.len;

    std.mem.writeInt(u32, image.items[0..4], magic, .little);
    std.mem.writeInt(u32, image.items[4..8], 3, .little);
    std.mem.writeInt(u32, image.items[8..12], 0, .little);
    std.mem.writeInt(u32, image.items[12..16], block_size, .little);
    std.mem.writeInt(u32, image.items[16..20], 1, .little);
    std.mem.writeInt(u16, image.items[20..22], 1, .little);
    std.mem.writeInt(u16, image.items[22..24], block_log, .little);
    std.mem.writeInt(u16, image.items[24..26], 0b1011, .little);
    std.mem.writeInt(u16, image.items[26..28], 1, .little);
    std.mem.writeInt(u16, image.items[28..30], major_version, .little);
    std.mem.writeInt(u16, image.items[30..32], 0, .little);
    std.mem.writeInt(u64, image.items[32..40], 0, .little);
    std.mem.writeInt(u64, image.items[40..48], bytes_used, .little);
    std.mem.writeInt(u64, image.items[48..56], id_table_start, .little);
    std.mem.writeInt(u64, image.items[56..64], invalid_table, .little);
    std.mem.writeInt(u64, image.items[64..72], inode_table_start, .little);
    std.mem.writeInt(u64, image.items[72..80], directory_table_start, .little);
    std.mem.writeInt(u64, image.items[80..88], fragment_table_start, .little);
    std.mem.writeInt(u64, image.items[88..96], invalid_table, .little);

    return image.toOwnedSlice();
}

fn writeFixture(path: []const u8, bytes: []const u8) !void {
    const io = std.testing.io;
    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

test "squashfs reader enumerates nested directories and extracts fragment-backed file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test-squashfs-uncompressed.sqsh";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const image = try buildSyntheticSquashfsImage(allocator);
    defer allocator.free(image);
    try writeFixture(path, image);

    var reader = try Reader.openPath(allocator, io, path);
    defer reader.close(io);

    try std.testing.expectEqual(@as(u32, 1024), reader.superblock.block_size);
    try std.testing.expectEqual(@as(usize, 1), reader.fragments.len);

    const dir_index = try reader.lookup("/etc");
    try std.testing.expectEqual(EntryKind.directory, reader.getEntry(dir_index).kind);

    const file_index = try reader.lookup("/etc/message.txt");
    const contents = try reader.readFileAlloc(allocator, io, file_index);
    defer allocator.free(contents);
    try std.testing.expectEqual(@as(usize, 1500), contents.len);
    for (contents[0..1024]) |byte| try std.testing.expectEqual(@as(u8, 'A'), byte);
    for (contents[1024..]) |byte| try std.testing.expectEqual(@as(u8, 'B'), byte);

    const root_entries = try reader.listDirAlloc(allocator, reader.root_index);
    defer allocator.free(root_entries);
    try std.testing.expectEqual(@as(usize, 1), root_entries.len);
    try std.testing.expectEqualStrings("etc", root_entries[0].name);
}
