//! The `Image` abstraction: a format-agnostic view over a disk image file,
//! analogous to qemu's `BlockDriver`. Supports `raw`, fixed `vhd`, and
//! dynamic `vhd` (sparse, block-allocated), VHDX (read-only), and qcow2
//! (read-only). Because there are only ever a
//! handful of formats, this uses a plain tagged union rather than a
//! vtable/`anyopaque` interface -- simpler and fully type-safe for a small,
//! closed set of variants.
//!
//! Every operation takes an explicit `std.Io` parameter (Zig 0.16's I/O
//! interface), matching the pattern used by `std.Io.File`/`std.Io.Dir`
//! themselves -- there is no implicit global filesystem or event loop.
//!
//! Dynamic VHD layout/semantics (BAT sector numbering, sector bitmap size,
//! and the "footer trailer always sits at the current end of file, and gets
//! overwritten by the next block's bitmap" allocation strategy) are verified
//! against QEMU's `block/vpc.c` (`vpc_open`, `alloc_block`, `get_image_offset`,
//! `create_dynamic_disk`), the de-facto interoperability reference.

const std = @import("std");
const Io = std.Io;
const vhd = @import("vhd.zig");
const vhdx = @import("vhdx.zig");
const qcow2 = @import("qcow2.zig");
pub const Format = @import("formats.zig").Format;

pub const OpenError = error{
    UnsupportedVhdDiskType,
    InvalidBlockSize,
} || Io.File.OpenError || Io.File.ReadPositionalError || Io.File.StatError ||
    vhd.Footer.DecodeError || vhd.DynamicHeader.DecodeError || vhdx.OpenError || qcow2.OpenError;

pub const CreateError = error{
    SizeNotSectorAligned,
    UnsupportedFormatForCreate,
} || Io.File.OpenError || Io.File.WritePositionalError || Io.File.SetLengthError;

pub const VhdSubformat = enum { fixed, dynamic };

pub const CreateOptions = struct {
    /// Only consulted when `format == .vhd`. Defaults to `.dynamic` to match
    /// real qemu-img's default subformat for `-f vpc`. Azure managed-disk
    /// uploads require *fixed* VHDs -- pass `.fixed` explicitly (the future
    /// `zvmi build-image`/`azure fixup` commands do this automatically).
    vhd_subformat: VhdSubformat = .dynamic,
};

pub const Info = struct {
    format: Format,
    /// Guest-visible disk size, in bytes.
    virtual_size: u64,
    /// Bytes actually occupied by the file on disk. For `raw`/fixed `vhd`
    /// this equals the virtual size (+ footer for vhd); for dynamic `vhd`
    /// it reflects only the blocks actually allocated so far.
    file_size: u64,
    subformat: ?VhdSubformat,
};

/// Per-image state needed to navigate a dynamic VHD's BAT and data blocks.
/// Not cached in memory beyond these scalars -- BAT entries themselves are
/// read/written directly against the file on each access (see `readBatEntry`),
/// trading a little I/O for a much simpler, allocation-free `Image`.
const DynamicState = struct {
    bat_offset: u64,
    max_table_entries: u32,
    block_size: u32,
    bitmap_size: u32,
    /// Where the *next* allocated block (bitmap + data) will be written.
    /// Also where a copy of the footer currently sits (matching QEMU: the
    /// footer trailer always sits at the true end of file, and gets
    /// overwritten by the next block's bitmap when another block is
    /// allocated).
    free_data_block_offset: u64,
    /// A ready-to-write encoded footer, rewritten to `free_data_block_offset`
    /// after every new block allocation.
    footer_template: [vhd.footer_size]u8,
};

/// Per-image state needed to navigate a read-only VHDX's BAT, mirroring
/// `DynamicState`'s "don't cache the BAT, read entries on demand" approach.
const VhdxState = struct {
    bat_offset: u64,
    block_size: u32,
    chunk_ratio: u64,
};

pub const Image = struct {
    file: Io.File,
    format: Format,
    /// Offset within `file` where guest-visible byte 0 lives (0 for raw,
    /// fixed vhd, and dynamic vhd -- dynamic vhd's "offset 0" is virtual;
    /// actual block placement is indirected through the BAT).
    data_offset: u64,
    virtual_size: u64,
    dynamic: ?DynamicState = null,
    vhdx: ?VhdxState = null,
    qcow2: ?qcow2.Info = null,

    pub fn openPath(io: Io, path: []const u8) OpenError!Image {
        const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);
        return openFile(io, file);
    }

    /// Takes ownership of `file` (closing the returned `Image` closes it).
    pub fn openFile(io: Io, file: Io.File) OpenError!Image {
        const file_size = (try file.stat(io)).size;

        // qcow2 and VHDX signatures both live at the very start of the file
        // (unlike VHD's footer, which trails the data); sniff them first so
        // we never misdetect either format as raw. Once a signature matches,
        // any further parse failure is a real error, not a fallback-to-raw
        // case.
        if (file_size >= 4) {
            var sig_buf: [8]u8 = undefined;
            const n = try file.readPositionalAll(io, &sig_buf, 0);
            if (n >= 4 and std.mem.eql(u8, sig_buf[0..4], &qcow2.file_signature)) {
                const qcow2_info = try qcow2.open(io, file);
                return .{
                    .file = file,
                    .format = .qcow2,
                    .data_offset = 0,
                    .virtual_size = qcow2_info.virtual_size,
                    .qcow2 = qcow2_info,
                };
            }
            if (n == 8 and std.mem.eql(u8, &sig_buf, &vhdx.file_signature)) {
                const vhdx_info = try vhdx.open(io, file);
                return .{
                    .file = file,
                    .format = .vhdx,
                    .data_offset = 0,
                    .virtual_size = vhdx_info.virtual_size,
                    .vhdx = .{
                        .bat_offset = vhdx_info.bat_offset,
                        .block_size = vhdx_info.block_size,
                        .chunk_ratio = vhdx_info.chunk_ratio,
                    },
                };
            }
        }

        if (file_size >= vhd.footer_size) {
            var footer_buf: [vhd.footer_size]u8 = undefined;
            const n = try file.readPositionalAll(io, &footer_buf, file_size - vhd.footer_size);
            if (n == vhd.footer_size) {
                if (vhd.Footer.decode(&footer_buf)) |footer| {
                    switch (footer.disk_type) {
                        .fixed => return .{
                            .file = file,
                            .format = .vhd,
                            .data_offset = 0,
                            .virtual_size = footer.virtualSize(),
                        },
                        .dynamic => return try openDynamic(io, file, footer, footer_buf),
                        else => return error.UnsupportedVhdDiskType,
                    }
                } else |_| {
                    // Not a valid VHD footer -- fall through and treat as raw.
                }
            }
        }

        return .{
            .file = file,
            .format = .raw,
            .data_offset = 0,
            .virtual_size = file_size,
        };
    }

    fn openDynamic(io: Io, file: Io.File, footer: vhd.Footer, footer_buf: [vhd.footer_size]u8) OpenError!Image {
        var header_buf: [vhd.dynamic_header_size]u8 = undefined;
        _ = try file.readPositionalAll(io, &header_buf, footer.data_offset);
        const header = try vhd.DynamicHeader.decode(&header_buf);

        if (!std.math.isPowerOfTwo(header.block_size) or header.block_size < 512) {
            return error.InvalidBlockSize;
        }
        const bitmap_size = vhd.bitmapSize(header.block_size);
        const free_offset = try computeFreeDataBlockOffset(
            file,
            io,
            header.table_offset,
            header.max_table_entries,
            bitmap_size,
            header.block_size,
        );

        return .{
            .file = file,
            .format = .vhd,
            .data_offset = 0,
            .virtual_size = footer.virtualSize(),
            .dynamic = .{
                .bat_offset = header.table_offset,
                .max_table_entries = header.max_table_entries,
                .block_size = header.block_size,
                .bitmap_size = bitmap_size,
                .free_data_block_offset = free_offset,
                .footer_template = footer_buf,
            },
        };
    }

    /// Creates a brand-new image file of the given format and virtual size.
    /// `size` must be a multiple of the 512-byte sector size.
    pub fn create(io: Io, path: []const u8, format: Format, size: u64, options: CreateOptions) CreateError!Image {
        if (size % 512 != 0) return error.SizeNotSectorAligned;
        // VHDX/qcow2 support is read-only (see vhdx.zig/qcow2.zig) -- reject
        // before creating any file on disk.
        if (format == .vhdx or format == .qcow2) return error.UnsupportedFormatForCreate;

        const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
        errdefer file.close(io);

        switch (format) {
            .raw => {
                try file.setLength(io, size);
                return .{ .file = file, .format = .raw, .data_offset = 0, .virtual_size = size };
            },
            .vhd => switch (options.vhd_subformat) {
                .fixed => {
                    try file.setLength(io, size + vhd.footer_size);
                    const footer = vhd.Footer.forFixedDisk(size, randomUuid(io), nowUnix(io));
                    const encoded = footer.encode();
                    try file.writePositionalAll(io, &encoded, size);
                    return .{ .file = file, .format = .vhd, .data_offset = 0, .virtual_size = size };
                },
                .dynamic => return try createDynamic(io, file, size),
            },
            .vhdx, .qcow2 => unreachable, // rejected above
        }
    }

    fn createDynamic(io: Io, file: Io.File, size: u64) CreateError!Image {
        const block_size: u32 = vhd.default_block_size;
        const bitmap_size = vhd.bitmapSize(block_size);
        const total_sectors = size / 512;
        const sectors_per_block = block_size / 512;
        const max_table_entries: u32 = @intCast(std.math.divCeil(u64, total_sectors, sectors_per_block) catch unreachable);

        const bat_offset: u64 = vhd.footer_size + vhd.dynamic_header_size;
        const bat_bytes_len: u64 = @as(u64, max_table_entries) * 4;
        const free_offset = alignUp(bat_offset + bat_bytes_len, 512);

        const footer = vhd.Footer.forDynamicDisk(size, vhd.footer_size, randomUuid(io), nowUnix(io));
        const footer_bytes = footer.encode();
        try file.writePositionalAll(io, &footer_bytes, 0);

        const header = vhd.DynamicHeader{
            .table_offset = bat_offset,
            .max_table_entries = max_table_entries,
            .block_size = block_size,
        };
        const header_bytes = header.encode();
        try file.writePositionalAll(io, &header_bytes, vhd.footer_size);

        try fillBatUnallocated(file, io, bat_offset, max_table_entries);

        try file.setLength(io, free_offset + vhd.footer_size);
        try file.writePositionalAll(io, &footer_bytes, free_offset);

        return .{
            .file = file,
            .format = .vhd,
            .data_offset = 0,
            .virtual_size = size,
            .dynamic = .{
                .bat_offset = bat_offset,
                .max_table_entries = max_table_entries,
                .block_size = block_size,
                .bitmap_size = bitmap_size,
                .free_data_block_offset = free_offset,
                .footer_template = footer_bytes,
            },
        };
    }

    pub fn info(self: Image, io: Io) Io.File.StatError!Info {
        const file_size = (try self.file.stat(io)).size;
        const subformat: ?VhdSubformat = if (self.format != .vhd)
            null
        else if (self.dynamic != null) .dynamic else .fixed;
        return .{ .format = self.format, .virtual_size = self.virtual_size, .file_size = file_size, .subformat = subformat };
    }

    pub const PreadError = error{UnsupportedVhdxBlockState} || qcow2.PreadError || Io.File.ReadPositionalError;

    pub fn pread(self: Image, io: Io, buffer: []u8, offset: u64) PreadError!usize {
        if (self.qcow2) |q| return qcow2.pread(self.file, io, q, buffer, offset);
        if (self.dynamic) |d| {
            var total: usize = 0;
            var off = offset;
            var remaining = buffer.len;
            while (remaining > 0) {
                const block_index: u32 = @intCast(off / d.block_size);
                const in_block_offset: u32 = @intCast(off % d.block_size);
                const chunk: usize = @min(remaining, d.block_size - in_block_offset);

                const bat_value = try readBatEntry(self.file, io, d.bat_offset, block_index);
                if (bat_value == unallocated_bat_entry) {
                    @memset(buffer[total..][0..chunk], 0);
                } else {
                    const block_data_offset = @as(u64, bat_value) * 512 + d.bitmap_size;
                    const got = try self.file.readPositionalAll(io, buffer[total..][0..chunk], block_data_offset + in_block_offset);
                    if (got < chunk) @memset(buffer[total + got ..][0 .. chunk - got], 0);
                }

                total += chunk;
                off += chunk;
                remaining -= chunk;
            }
            return total;
        }
        if (self.vhdx) |v| {
            var total: usize = 0;
            var off = offset;
            var remaining = buffer.len;
            while (remaining > 0) {
                const block_index = off / v.block_size;
                const in_block_offset: u32 = @intCast(off % v.block_size);
                const chunk: usize = @min(remaining, v.block_size - in_block_offset);

                const bat_index = vhdx.batIndexForBlock(block_index, v.chunk_ratio);
                const entry = try readBatEntryU64(self.file, io, v.bat_offset, bat_index);
                const state: vhdx.BlockState = @enumFromInt(entry & vhdx.bat_state_mask);

                switch (state) {
                    .fully_present => {
                        const file_offset = entry & vhdx.bat_file_off_mask;
                        const got = try self.file.readPositionalAll(io, buffer[total..][0..chunk], file_offset + in_block_offset);
                        if (got < chunk) @memset(buffer[total + got ..][0 .. chunk - got], 0);
                    },
                    .not_present, .undefined_state, .zero, .unmapped, .unmapped_v095 => {
                        @memset(buffer[total..][0..chunk], 0);
                    },
                    else => return error.UnsupportedVhdxBlockState, // partially_present (differencing only)
                }

                total += chunk;
                off += chunk;
                remaining -= chunk;
            }
            return total;
        }
        return self.file.readPositionalAll(io, buffer, self.data_offset + offset);
    }

    pub const PwriteError = error{ReadOnlyFormat} || Io.File.ReadPositionalError || Io.File.WritePositionalError;

    pub fn pwrite(self: *Image, io: Io, buffer: []const u8, offset: u64) PwriteError!void {
        if (self.format == .vhdx or self.format == .qcow2) return error.ReadOnlyFormat;
        if (self.dynamic) |*d| {
            var off = offset;
            var remaining = buffer.len;
            var src: usize = 0;
            while (remaining > 0) {
                const block_index: u32 = @intCast(off / d.block_size);
                const in_block_offset: u32 = @intCast(off % d.block_size);
                const chunk: usize = @min(remaining, d.block_size - in_block_offset);

                var bat_value = try readBatEntry(self.file, io, d.bat_offset, block_index);
                if (bat_value == unallocated_bat_entry) {
                    bat_value = try allocateBlock(self.file, io, d, block_index);
                }
                const block_data_offset = @as(u64, bat_value) * 512 + d.bitmap_size;
                try self.file.writePositionalAll(io, buffer[src..][0..chunk], block_data_offset + in_block_offset);

                src += chunk;
                off += chunk;
                remaining -= chunk;
            }
            return;
        }
        try self.file.writePositionalAll(io, buffer, self.data_offset + offset);
    }

    pub fn close(self: *Image, io: Io) void {
        self.file.close(io);
        self.* = undefined;
    }

    pub const ResizeError = error{
        ShrinkNotSupported,
        ExceedsAllocatedBatCapacity,
        ReadOnlyFormat,
    } || Io.File.SetLengthError || Io.File.WritePositionalError || Io.File.ReadPositionalError;

    /// Changes the guest-visible virtual size. Growing is supported for all
    /// formats (raw: extend with zeros; fixed vhd: extend + move footer;
    /// dynamic vhd: only if the new size still fits within the already
    /// allocated BAT capacity, i.e. no BAT growth -- otherwise returns
    /// `error.ExceedsAllocatedBatCapacity`). Shrinking is not yet supported
    /// (`error.ShrinkNotSupported`) since it requires format-specific data
    /// loss handling that qemu-img itself guards behind `--shrink`. VHDX and
    /// qcow2 are read-only, so resizing them always fails
    /// (`error.ReadOnlyFormat`).
    pub fn resize(self: *Image, io: Io, new_size: u64) ResizeError!void {
        if (self.format == .vhdx or self.format == .qcow2) return error.ReadOnlyFormat;
        if (new_size < self.virtual_size) return error.ShrinkNotSupported;
        if (new_size == self.virtual_size) return;

        switch (self.format) {
            .raw => {
                try self.file.setLength(io, new_size);
                self.virtual_size = new_size;
            },
            .vhd => {
                if (self.dynamic) |*d| {
                    const capacity = @as(u64, d.max_table_entries) * d.block_size;
                    if (new_size > capacity) return error.ExceedsAllocatedBatCapacity;
                    const footer = vhd.Footer.forDynamicDisk(new_size, vhd.footer_size, randomUuid(io), nowUnix(io));
                    d.footer_template = footer.encode();
                    try self.file.writePositionalAll(io, &d.footer_template, d.free_data_block_offset);
                    self.virtual_size = new_size;
                } else {
                    // Fixed: move the footer to the new end of the raw data
                    // region and rewrite it with the new size/geometry.
                    try self.file.setLength(io, new_size + vhd.footer_size);
                    const footer = vhd.Footer.forFixedDisk(new_size, randomUuid(io), nowUnix(io));
                    const encoded = footer.encode();
                    try self.file.writePositionalAll(io, &encoded, new_size);
                    self.virtual_size = new_size;
                }
            },
            .vhdx, .qcow2 => unreachable, // rejected above
        }
    }

    pub const CheckError = vhdx.OpenError || qcow2.OpenError || qcow2.CheckError || Io.File.StatError;

    pub const CheckResult = struct {
        ok: bool,
        message: []const u8,
    };

    /// Validates format metadata: VHD footer/header checksums and BAT bounds,
    /// VHDX header/region/metadata parsing, and qcow2 header/L1/L2 mapping
    /// sanity for the active image state.
    pub fn check(self: Image, io: Io) CheckError!CheckResult {
        if (self.format == .raw) return .{ .ok = true, .message = "raw image: nothing to check" };

        if (self.format == .vhdx) {
            _ = vhdx.open(io, self.file) catch |err| return .{
                .ok = false,
                .message = @errorName(err),
            };
            return .{ .ok = true, .message = "vhdx header/region/metadata checks passed" };
        }

        if (self.qcow2) |q| {
            qcow2.check(self.file, io, q) catch |err| return .{
                .ok = false,
                .message = @errorName(err),
            };
            return .{ .ok = true, .message = "qcow2 header/L1/L2 checks passed" };
        }

        const file_size = (try self.file.stat(io)).size;
        if (file_size < vhd.footer_size) return .{ .ok = false, .message = "file too small for a VHD footer" };

        var footer_buf: [vhd.footer_size]u8 = undefined;
        _ = try self.file.readPositionalAll(io, &footer_buf, file_size - vhd.footer_size);
        const footer = vhd.Footer.decode(&footer_buf) catch |err| return .{
            .ok = false,
            .message = switch (err) {
                error.BadCookie => "footer: bad cookie",
                error.BadChecksum => "footer: bad checksum",
            },
        };

        if (self.dynamic) |d| {
            var header_buf: [vhd.dynamic_header_size]u8 = undefined;
            _ = try self.file.readPositionalAll(io, &header_buf, footer.data_offset);
            const header_ok = if (vhd.DynamicHeader.decode(&header_buf)) |_| true else |_| false;
            if (!header_ok) return .{ .ok = false, .message = "dynamic header: bad cookie or checksum" };

            var index: u32 = 0;
            while (index < d.max_table_entries) : (index += 1) {
                const bat_value = try readBatEntry(self.file, io, d.bat_offset, index);
                if (bat_value == unallocated_bat_entry) continue;
                const block_end = @as(u64, bat_value) * 512 + d.bitmap_size + d.block_size;
                if (block_end > file_size) return .{ .ok = false, .message = "BAT entry points past end of file" };
            }
        }

        return .{ .ok = true, .message = "no errors found" };
    }

    pub const Extent = struct {
        /// Offset within the guest-visible virtual disk.
        offset: u64,
        length: u64,
        allocated: bool,
    };

    pub const MapError = Io.File.ReadPositionalError || qcow2.MapError || std.mem.Allocator.Error;

    /// Returns the list of allocated/unallocated extents covering the whole
    /// virtual disk (coalescing adjacent same-state blocks), analogous to
    /// `qemu-img map`. Caller owns the returned slice. `raw` and fixed `vhd`
    /// report a single, fully allocated extent (neither format has a sparse
    /// concept); dynamic `vhd`, `vhdx`, and `qcow2` walk their format-specific
    /// mapping tables.
    pub fn mapExtents(self: Image, io: Io, allocator: std.mem.Allocator) MapError![]Extent {
        if (self.dynamic) |d| {
            var extents = std.array_list.Managed(Extent).init(allocator);
            errdefer extents.deinit();

            var index: u32 = 0;
            while (index < d.max_table_entries) {
                const bat_value = try readBatEntry(self.file, io, d.bat_offset, index);
                const allocated = bat_value != unallocated_bat_entry;
                const block_start = @as(u64, index) * d.block_size;

                var run_end_index = index + 1;
                while (run_end_index < d.max_table_entries) : (run_end_index += 1) {
                    const next = try readBatEntry(self.file, io, d.bat_offset, run_end_index);
                    if ((next != unallocated_bat_entry) != allocated) break;
                }

                const run_end_offset = @min(@as(u64, run_end_index) * d.block_size, self.virtual_size);
                try extents.append(.{ .offset = block_start, .length = run_end_offset - block_start, .allocated = allocated });
                index = run_end_index;
            }
            return extents.toOwnedSlice();
        }

        if (self.vhdx) |v| {
            var extents = std.array_list.Managed(Extent).init(allocator);
            errdefer extents.deinit();

            const total_blocks = std.math.divCeil(u64, self.virtual_size, v.block_size) catch unreachable;

            var index: u64 = 0;
            while (index < total_blocks) {
                const allocated = try vhdxBlockAllocated(self.file, io, v, index);
                const block_start = index * v.block_size;

                var run_end_index = index + 1;
                while (run_end_index < total_blocks) : (run_end_index += 1) {
                    if (try vhdxBlockAllocated(self.file, io, v, run_end_index) != allocated) break;
                }

                const run_end_offset = @min(run_end_index * v.block_size, self.virtual_size);
                try extents.append(.{ .offset = block_start, .length = run_end_offset - block_start, .allocated = allocated });
                index = run_end_index;
            }
            return extents.toOwnedSlice();
        }

        if (self.qcow2) |q| {
            const src_extents = try qcow2.mapExtents(self.file, io, q, allocator);
            defer allocator.free(src_extents);

            const dst_extents = try allocator.alloc(Extent, src_extents.len);
            for (src_extents, 0..) |e, i| {
                dst_extents[i] = .{ .offset = e.offset, .length = e.length, .allocated = e.allocated };
            }
            return dst_extents;
        }

        const single = try allocator.alloc(Extent, 1);
        single[0] = .{ .offset = 0, .length = self.virtual_size, .allocated = true };
        return single;
    }
};

const unallocated_bat_entry: u32 = 0xFFFF_FFFF;

fn vhdxBlockAllocated(file: Io.File, io: Io, v: VhdxState, block_index: u64) Io.File.ReadPositionalError!bool {
    const bat_index = vhdx.batIndexForBlock(block_index, v.chunk_ratio);
    const entry = try readBatEntryU64(file, io, v.bat_offset, bat_index);
    const state: vhdx.BlockState = @enumFromInt(entry & vhdx.bat_state_mask);
    return state == .fully_present or state == .partially_present;
}

fn readBatEntryU64(file: Io.File, io: Io, bat_offset: u64, index: u64) Io.File.ReadPositionalError!u64 {
    var buf: [8]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, bat_offset + index * 8);
    return std.mem.readInt(u64, &buf, .little);
}

fn readBatEntry(file: Io.File, io: Io, bat_offset: u64, index: u32) Io.File.ReadPositionalError!u32 {
    var buf: [4]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, bat_offset + @as(u64, index) * 4);
    return std.mem.readInt(u32, &buf, .big);
}

fn writeBatEntry(file: Io.File, io: Io, bat_offset: u64, index: u32, value: u32) Io.File.WritePositionalError!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try file.writePositionalAll(io, &buf, bat_offset + @as(u64, index) * 4);
}

fn fillBatUnallocated(file: Io.File, io: Io, bat_offset: u64, max_table_entries: u32) Io.File.WritePositionalError!void {
    const bat_bytes_len: u64 = @as(u64, max_table_entries) * 4;
    const chunk: [4096]u8 = [_]u8{0xFF} ** 4096;
    var written: u64 = 0;
    while (written < bat_bytes_len) {
        const n: usize = @intCast(@min(bat_bytes_len - written, chunk.len));
        try file.writePositionalAll(io, chunk[0..n], bat_offset + written);
        written += n;
    }
}

/// Scans the BAT once to determine the current end of allocated data,
/// mirroring QEMU's `vpc_open`: starts from just past the BAT itself, then
/// grows to cover every already-allocated block (bitmap + data).
fn computeFreeDataBlockOffset(
    file: Io.File,
    io: Io,
    bat_offset: u64,
    max_table_entries: u32,
    bitmap_size: u32,
    block_size: u32,
) Io.File.ReadPositionalError!u64 {
    var free_offset = alignUp(bat_offset + @as(u64, max_table_entries) * 4, 512);

    var buf: [4096]u8 = undefined; // 1024 BAT entries per chunk
    var index: u32 = 0;
    while (index < max_table_entries) {
        const entries_this_chunk = @min(max_table_entries - index, 1024);
        const bytes_len = entries_this_chunk * 4;
        _ = try file.readPositionalAll(io, buf[0..bytes_len], bat_offset + @as(u64, index) * 4);

        var i: u32 = 0;
        while (i < entries_this_chunk) : (i += 1) {
            const val = std.mem.readInt(u32, buf[i * 4 ..][0..4], .big);
            if (val != unallocated_bat_entry) {
                const candidate = @as(u64, val) * 512 + bitmap_size + block_size;
                if (candidate > free_offset) free_offset = candidate;
            }
        }
        index += entries_this_chunk;
    }
    return free_offset;
}

/// Allocates a fresh block for `block_index`: writes an all-1s sector
/// bitmap, advances `d.free_data_block_offset` past it, rewrites the footer
/// trailer at the new end of file, and records the BAT entry. Returns the
/// BAT entry value (sector number of the bitmap) to use for this write.
fn allocateBlock(file: Io.File, io: Io, d: *DynamicState, block_index: u32) (Io.File.WritePositionalError)!u32 {
    const bitmap_offset = d.free_data_block_offset;
    const bat_value: u32 = @intCast(bitmap_offset / 512);

    const bitmap_chunk: [512]u8 = [_]u8{0xFF} ** 512;
    var written: u64 = 0;
    while (written < d.bitmap_size) {
        const n: usize = @intCast(@min(@as(u64, d.bitmap_size) - written, bitmap_chunk.len));
        try file.writePositionalAll(io, bitmap_chunk[0..n], bitmap_offset + written);
        written += n;
    }

    d.free_data_block_offset += d.block_size + d.bitmap_size;
    try file.writePositionalAll(io, &d.footer_template, d.free_data_block_offset);
    try writeBatEntry(file, io, d.bat_offset, block_index, bat_value);

    return bat_value;
}

fn alignUp(v: u64, a: u64) u64 {
    return (v + a - 1) / a * a;
}

fn nowUnix(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

fn randomUuid(io: Io) [16]u8 {
    var bytes: [16]u8 = undefined;
    Io.random(io, &bytes);
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
    return bytes;
}

pub const CopyError = Image.PreadError || Image.PwriteError ||
    std.mem.Allocator.Error || error{UnexpectedEndOfFile};

/// Copies all `src` virtual-disk bytes into `*dst` (which must already have
/// been created with at least `src`'s virtual size). Used by `zvmi convert`.
/// Takes `dst` by pointer since dynamic-vhd writes mutate BAT/allocation
/// state that must be visible to the caller after this returns.
///
/// All-zero chunks are skipped rather than written, so converting into a
/// dynamic vhd stays sparse instead of eagerly allocating every block it
/// touches. When `dst` is a dynamic vhd, the chunk size is aligned to its
/// block size so each chunk maps to exactly one BAT entry -- otherwise a
/// single mostly-zero copy chunk spanning multiple blocks would force all of
/// them to be allocated just because one had non-zero bytes.
pub fn copyAll(io: Io, src: Image, dst: *Image, allocator: std.mem.Allocator) CopyError!void {
    const chunk_size: usize = if (dst.dynamic) |d| d.block_size else 4 * 1024 * 1024;
    const buf = try allocator.alloc(u8, chunk_size);
    defer allocator.free(buf);

    var offset: u64 = 0;
    while (offset < src.virtual_size) {
        const remaining = src.virtual_size - offset;
        const n: usize = @intCast(@min(remaining, chunk_size));
        const got = try src.pread(io, buf[0..n], offset);
        if (got != n) return error.UnexpectedEndOfFile;
        if (!isAllZero(buf[0..n])) {
            try dst.pwrite(io, buf[0..n], offset);
        }
        offset += n;
    }
}

fn isAllZero(buf: []const u8) bool {
    for (buf) |b| {
        if (b != 0) return false;
    }
    return true;
}

test "create raw image, then open and read back zeros" {
    const io = std.testing.io;
    const path = "test-create-raw.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    var img = try Image.create(io, path, .raw, 1024 * 1024, .{});
    img.close(io);

    var opened = try Image.openPath(io, path);
    defer opened.close(io);
    try std.testing.expectEqual(Format.raw, opened.format);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), opened.virtual_size);

    var buf: [16]u8 = undefined;
    _ = try opened.pread(io, &buf, 0);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 16), &buf);
}

test "create fixed vhd image, then open and recover virtual size" {
    const io = std.testing.io;
    const path = "test-create-fixed.vhd";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const size: u64 = 8 * 1024 * 1024;
    var img = try Image.create(io, path, .vhd, size, .{ .vhd_subformat = .fixed });
    try img.pwrite(io, "hello", 0);
    img.close(io);

    var opened = try Image.openPath(io, path);
    defer opened.close(io);
    try std.testing.expectEqual(Format.vhd, opened.format);
    try std.testing.expectEqual(size, opened.virtual_size);

    var buf: [5]u8 = undefined;
    _ = try opened.pread(io, &buf, 0);
    try std.testing.expectEqualSlices(u8, "hello", &buf);

    // The footer must not be readable/writable as guest data.
    try std.testing.expectEqual(size + vhd.footer_size, (try opened.info(io)).file_size);
}

test "convert raw to fixed vhd round-trips data" {
    const io = std.testing.io;
    const src_path = "test-convert-src.img";
    const dst_path = "test-convert-dst.vhd";
    defer Io.Dir.cwd().deleteFile(io, src_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, dst_path) catch {};

    const size: u64 = 2 * 1024 * 1024;
    var src = try Image.create(io, src_path, .raw, size, .{});
    try src.pwrite(io, "some payload bytes", 4096);

    var dst = try Image.create(io, dst_path, .vhd, size, .{ .vhd_subformat = .fixed });
    try copyAll(io, src, &dst, std.testing.allocator);
    src.close(io);
    dst.close(io);

    var reopened = try Image.openPath(io, dst_path);
    defer reopened.close(io);
    var buf: [18]u8 = undefined;
    _ = try reopened.pread(io, &buf, 4096);
    try std.testing.expectEqualSlices(u8, "some payload bytes", &buf);
}

test "convert raw to dynamic vhd stays sparse for zero regions" {
    const io = std.testing.io;
    const src_path = "test-convert-sparse-src.img";
    const dst_path = "test-convert-sparse-dst.vhd";
    defer Io.Dir.cwd().deleteFile(io, src_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, dst_path) catch {};

    // 4 blocks' worth of raw, all zero except a few bytes in block 1.
    const size: u64 = 4 * @as(u64, vhd.default_block_size);
    var src = try Image.create(io, src_path, .raw, size, .{});
    try src.pwrite(io, "only-block-1", vhd.default_block_size + 123);

    var dst = try Image.create(io, dst_path, .vhd, size, .{ .vhd_subformat = .dynamic });
    try copyAll(io, src, &dst, std.testing.allocator);
    src.close(io);

    const extents = try dst.mapExtents(io, std.testing.allocator);
    defer std.testing.allocator.free(extents);
    dst.close(io);

    // Only the block actually touched should be allocated; the rest of the
    // 4-block disk should stay sparse.
    try std.testing.expectEqual(@as(usize, 3), extents.len);
    try std.testing.expectEqual(false, extents[0].allocated);
    try std.testing.expectEqual(true, extents[1].allocated);
    try std.testing.expectEqual(@as(u64, vhd.default_block_size), extents[1].offset);
    try std.testing.expectEqual(@as(u64, vhd.default_block_size), extents[1].length);
    try std.testing.expectEqual(false, extents[2].allocated);
}

test "create dynamic vhd, write across blocks, reopen and read back" {
    const io = std.testing.io;
    const path = "test-create-dynamic.vhd";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    // 3 blocks' worth so we exercise multiple BAT entries.
    const size: u64 = 3 * @as(u64, vhd.default_block_size);
    var img = try Image.create(io, path, .vhd, size, .{ .vhd_subformat = .dynamic });
    try std.testing.expect(img.dynamic != null);

    // Write into the 2nd block only -- the 1st and 3rd should stay unallocated.
    const payload = "dynamic-vhd-payload";
    try img.pwrite(io, payload, vhd.default_block_size + 4096);
    img.close(io);

    var opened = try Image.openPath(io, path);
    defer opened.close(io);
    try std.testing.expectEqual(Format.vhd, opened.format);
    try std.testing.expectEqual(size, opened.virtual_size);
    try std.testing.expect(opened.dynamic != null);

    var buf: [payload.len]u8 = undefined;
    _ = try opened.pread(io, &buf, vhd.default_block_size + 4096);
    try std.testing.expectEqualSlices(u8, payload, &buf);

    // Reading from an untouched region returns zeros (sparse).
    var zero_buf: [64]u8 = undefined;
    _ = try opened.pread(io, &zero_buf, 0);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 64), &zero_buf);

    // The file on disk should be much smaller than the virtual size, since
    // only one block was ever allocated.
    const stat = try opened.info(io);
    try std.testing.expect(stat.file_size < size);
}

test "dynamic vhd map reports sparse extents" {
    const io = std.testing.io;
    const path = "test-map-dynamic.vhd";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const size: u64 = 3 * @as(u64, vhd.default_block_size);
    var img = try Image.create(io, path, .vhd, size, .{ .vhd_subformat = .dynamic });
    try img.pwrite(io, "x", vhd.default_block_size);

    const extents = try img.mapExtents(io, std.testing.allocator);
    defer std.testing.allocator.free(extents);
    img.close(io);

    try std.testing.expectEqual(@as(usize, 3), extents.len);
    try std.testing.expectEqual(false, extents[0].allocated);
    try std.testing.expectEqual(true, extents[1].allocated);
    try std.testing.expectEqual(false, extents[2].allocated);
    try std.testing.expectEqual(@as(u64, vhd.default_block_size), extents[1].offset);
}

test "raw and fixed vhd map report a single allocated extent" {
    const io = std.testing.io;
    const raw_path = "test-map-raw.img";
    defer Io.Dir.cwd().deleteFile(io, raw_path) catch {};

    var img = try Image.create(io, raw_path, .raw, 4096, .{});
    const extents = try img.mapExtents(io, std.testing.allocator);
    defer std.testing.allocator.free(extents);
    img.close(io);

    try std.testing.expectEqual(@as(usize, 1), extents.len);
    try std.testing.expectEqual(true, extents[0].allocated);
    try std.testing.expectEqual(@as(u64, 4096), extents[0].length);
}

test "check reports ok for freshly created images" {
    const io = std.testing.io;

    {
        const path = "test-check-fixed.vhd";
        defer Io.Dir.cwd().deleteFile(io, path) catch {};
        var img = try Image.create(io, path, .vhd, 1024 * 1024, .{ .vhd_subformat = .fixed });
        defer img.close(io);
        const result = try img.check(io);
        try std.testing.expect(result.ok);
    }
    {
        const path = "test-check-dynamic.vhd";
        defer Io.Dir.cwd().deleteFile(io, path) catch {};
        var img = try Image.create(io, path, .vhd, 4 * 1024 * 1024, .{ .vhd_subformat = .dynamic });
        try img.pwrite(io, "abc", 0);
        defer img.close(io);
        const result = try img.check(io);
        try std.testing.expect(result.ok);
    }
}

test "check detects a corrupted footer" {
    const io = std.testing.io;
    const path = "test-check-corrupt.vhd";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    var img = try Image.create(io, path, .vhd, 1024 * 1024, .{ .vhd_subformat = .fixed });
    defer img.close(io);

    // Corrupt a reserved footer byte in place.
    var one: [1]u8 = .{0xFF};
    try img.file.writePositionalAll(io, &one, img.virtual_size + 100);

    const result = try img.check(io);
    try std.testing.expect(!result.ok);
}

test "resize grows raw and fixed vhd images" {
    const io = std.testing.io;
    {
        const path = "test-resize-raw.img";
        defer Io.Dir.cwd().deleteFile(io, path) catch {};
        var img = try Image.create(io, path, .raw, 1024, .{});
        defer img.close(io);
        try img.resize(io, 4096);
        try std.testing.expectEqual(@as(u64, 4096), img.virtual_size);
        try std.testing.expectEqual(@as(u64, 4096), (try img.info(io)).file_size);
    }
    {
        const path = "test-resize-fixed.vhd";
        defer Io.Dir.cwd().deleteFile(io, path) catch {};
        var img = try Image.create(io, path, .vhd, 1024 * 1024, .{ .vhd_subformat = .fixed });
        defer img.close(io);
        try img.resize(io, 2 * 1024 * 1024);
        try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), img.virtual_size);

        var reopened = try Image.openPath(io, path);
        defer reopened.close(io);
        try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), reopened.virtual_size);
    }
}

test "resize rejects shrinking" {
    const io = std.testing.io;
    const path = "test-resize-shrink.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    var img = try Image.create(io, path, .raw, 4096, .{});
    defer img.close(io);
    try std.testing.expectError(error.ShrinkNotSupported, img.resize(io, 1024));
}

// ---- qcow2 end-to-end integration test ----
//
// No real qemu/qemu-img install was available in this environment, so this
// test builds a minimal qcow2 image by hand and then verifies
// `Image.openPath`/`pread`/`check`/`mapExtents` against it. The fixture has
// three guest clusters: allocated, sparse, allocated.
test "Image reads a hand-built minimal qcow2 file" {
    const io = std.testing.io;
    const path = "test-qcow2-fixture.qcow2";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const total_file_size: u64 = 7 * 4096;
    var img = try Image.create(io, path, .raw, total_file_size, .{});
    const fixture = try writeQcow2TestFixture(&img, io, .{});
    img.close(io);

    var opened = try Image.openPath(io, path);
    defer opened.close(io);
    try std.testing.expectEqual(Format.qcow2, opened.format);
    try std.testing.expectEqual(fixture.virtual_size, opened.virtual_size);

    var block0: [13]u8 = undefined;
    _ = try opened.pread(io, &block0, 0);
    try std.testing.expectEqualSlices(u8, "QCOW2BLOCK000", &block0);

    var zero_buf: [64]u8 = undefined;
    _ = try opened.pread(io, &zero_buf, fixture.cluster_size);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 64), &zero_buf);

    var block2: [13]u8 = undefined;
    _ = try opened.pread(io, &block2, 2 * fixture.cluster_size + 32);
    try std.testing.expectEqualSlices(u8, "QCOW2BLOCK222", &block2);

    var one_byte: [1]u8 = .{1};
    try std.testing.expectError(error.ReadOnlyFormat, opened.pwrite(io, &one_byte, 0));
    try std.testing.expectError(error.ReadOnlyFormat, opened.resize(io, fixture.virtual_size + fixture.cluster_size));

    const result = try opened.check(io);
    try std.testing.expect(result.ok);

    const extents = try opened.mapExtents(io, std.testing.allocator);
    defer std.testing.allocator.free(extents);
    try std.testing.expectEqual(@as(usize, 3), extents.len);
    try std.testing.expectEqual(true, extents[0].allocated);
    try std.testing.expectEqual(false, extents[1].allocated);
    try std.testing.expectEqual(true, extents[2].allocated);
}

const Qcow2Fixture = struct {
    cluster_size: u64,
    virtual_size: u64,
};

const Qcow2FixtureOptions = struct {
    dirty: bool = false,
    corrupt: bool = false,
};

fn writeQcow2TestFixture(img: *Image, io: Io, options: Qcow2FixtureOptions) !Qcow2Fixture {
    const cluster_bits: u32 = 12;
    const cluster_size: u64 = 1 << cluster_bits;
    const refcount_table_offset: u64 = 1 * cluster_size;
    const refcount_block_offset: u64 = 2 * cluster_size;
    const l1_table_offset: u64 = 3 * cluster_size;
    const l2_table_offset: u64 = 4 * cluster_size;
    const data0_offset: u64 = 5 * cluster_size;
    const data2_offset: u64 = 6 * cluster_size;
    const virtual_size: u64 = 3 * cluster_size;

    var header: [112]u8 = [_]u8{0} ** 112;
    header[0..4].* = qcow2.file_signature;
    std.mem.writeInt(u32, header[4..8], 3, .big);
    std.mem.writeInt(u32, header[20..24], cluster_bits, .big);
    std.mem.writeInt(u64, header[24..32], virtual_size, .big);
    std.mem.writeInt(u32, header[36..40], 1, .big);
    std.mem.writeInt(u64, header[40..48], l1_table_offset, .big);
    std.mem.writeInt(u64, header[48..56], refcount_table_offset, .big);
    std.mem.writeInt(u32, header[56..60], 1, .big);
    var incompatible_features: u64 = 0;
    if (options.dirty) incompatible_features |= qcow2.incompatible_dirty;
    if (options.corrupt) incompatible_features |= qcow2.incompatible_corrupt;
    std.mem.writeInt(u64, header[72..80], incompatible_features, .big);
    std.mem.writeInt(u32, header[96..100], 4, .big);
    std.mem.writeInt(u32, header[100..104], 104, .big);
    try img.pwrite(io, &header, 0);

    var refcount_table: [4096]u8 = [_]u8{0} ** 4096;
    std.mem.writeInt(u64, refcount_table[0..8], refcount_block_offset, .big);
    try img.pwrite(io, &refcount_table, refcount_table_offset);

    var refcount_block: [4096]u8 = [_]u8{0} ** 4096;
    var cluster_index: usize = 0;
    while (cluster_index < 7) : (cluster_index += 1) {
        std.mem.writeInt(u16, refcount_block[cluster_index * 2 ..][0..2], 1, .big);
    }
    try img.pwrite(io, &refcount_block, refcount_block_offset);

    var l1_table: [4096]u8 = [_]u8{0} ** 4096;
    std.mem.writeInt(u64, l1_table[0..8], l2_table_offset | qcow2.copied_mask, .big);
    try img.pwrite(io, &l1_table, l1_table_offset);

    var l2_table: [4096]u8 = [_]u8{0} ** 4096;
    std.mem.writeInt(u64, l2_table[0..8], data0_offset | qcow2.copied_mask, .big);
    std.mem.writeInt(u64, l2_table[16..24], data2_offset | qcow2.copied_mask, .big);
    try img.pwrite(io, &l2_table, l2_table_offset);

    try img.pwrite(io, "QCOW2BLOCK000", data0_offset);
    try img.pwrite(io, "QCOW2BLOCK222", data2_offset + 32);

    return .{ .cluster_size = cluster_size, .virtual_size = virtual_size };
}

// ---- VHDX end-to-end integration test ----
//
// No real Hyper-V/QEMU install was available to generate a reference VHDX
// file, so this test builds a minimal-but-spec-correct one by hand (reusing
// the raw `Image`'s pwrite as a simple "poke bytes at this file offset"
// tool) and then verifies `Image.openPath`/`pread` read it back correctly.
// This exercises the full stack (signature/header/region-table/metadata
// parsing, CRC-32C validation, and BAT-driven reads for both an allocated
// and an unallocated block) even though, at this small scale, chunk_ratio
// is far larger than the block count, so the BAT interleaving adjustment
// itself is covered separately by `vhdx.zig`'s `batIndexForBlock` test.
test "Image reads a hand-built minimal VHDX file" {
    const io = std.testing.io;
    const path = "test-vhdx-fixture.vhdx";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const block_size: u32 = 1 * 1024 * 1024; // VHDX minimum block size
    const virtual_size: u64 = 2 * @as(u64, block_size); // 2 blocks
    const region_table_off: u64 = 3 * 64 * 1024;
    const bat_off: u64 = 1 * 1024 * 1024;
    const metadata_off: u64 = 2 * 1024 * 1024;
    const block0_data_off: u64 = 3 * 1024 * 1024;
    const total_file_size: u64 = block0_data_off + block_size;

    var img = try Image.create(io, path, .raw, total_file_size, .{});

    try img.pwrite(io, "vhdxfile", 0);
    try writeVhdxTestHeader(&img, io, 64 * 1024);
    try writeVhdxTestRegionTable(&img, io, region_table_off, bat_off, metadata_off);
    try writeVhdxTestMetadata(&img, io, metadata_off, block_size, virtual_size);

    // BAT: block 0 fully present at block0_data_off, block 1 not present.
    var bat_entry0: [8]u8 = undefined;
    std.mem.writeInt(u64, &bat_entry0, block0_data_off | 6, .little); // state=6 fully_present
    try img.pwrite(io, &bat_entry0, bat_off);
    var bat_entry1: [8]u8 = undefined;
    std.mem.writeInt(u64, &bat_entry1, 0, .little); // state=0 not_present
    try img.pwrite(io, &bat_entry1, bat_off + 8);

    try img.pwrite(io, "VHDXBLOCK0DATA", block0_data_off);
    img.close(io);

    var opened = try Image.openPath(io, path);
    defer opened.close(io);
    try std.testing.expectEqual(Format.vhdx, opened.format);
    try std.testing.expectEqual(virtual_size, opened.virtual_size);

    var buf: [14]u8 = undefined;
    _ = try opened.pread(io, &buf, 0);
    try std.testing.expectEqualSlices(u8, "VHDXBLOCK0DATA", &buf);

    // Block 1 (not present) reads as zero.
    var zero_buf: [64]u8 = undefined;
    _ = try opened.pread(io, &zero_buf, block_size);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 64), &zero_buf);

    // pwrite is rejected -- VHDX support is read-only.
    var one_byte: [1]u8 = .{1};
    try std.testing.expectError(error.ReadOnlyFormat, opened.pwrite(io, &one_byte, 0));

    // check() and mapExtents() should also work through the full Image API.
    const result = try opened.check(io);
    try std.testing.expect(result.ok);

    const extents = try opened.mapExtents(io, std.testing.allocator);
    defer std.testing.allocator.free(extents);
    try std.testing.expectEqual(@as(usize, 2), extents.len);
    try std.testing.expectEqual(true, extents[0].allocated);
    try std.testing.expectEqual(false, extents[1].allocated);
}

fn vhdxTestCrc32c(buf: []const u8) u32 {
    return std.hash.crc.Crc32Iscsi.hash(buf);
}

fn writeVhdxTestHeader(img: *Image, io: Io, offset: u64) !void {
    var buf: [4096]u8 = [_]u8{0} ** 4096;
    buf[0..4].* = "head".*;
    // checksum (buf[4..8]) filled below
    std.mem.writeInt(u64, buf[8..16], 2, .little); // sequence_number
    std.mem.writeInt(u16, buf[66..68], 1, .little); // version = 1

    const crc = vhdxTestCrc32c(&buf);
    std.mem.writeInt(u32, buf[4..8], crc, .little);
    try img.pwrite(io, &buf, offset);
}

fn writeVhdxTestRegionTable(img: *Image, io: Io, offset: u64, bat_offset: u64, metadata_offset: u64) !void {
    const guid = @import("guid.zig");
    const bat_guid = guid.parse("2DC27766-F623-4200-9D64-115E9BFD4A08");
    const metadata_guid = guid.parse("8B7CA206-4790-4B9A-B8FE-575F050F886E");

    var buf: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024);
    buf[0..4].* = "regi".*;
    // checksum (buf[4..8]) filled below
    std.mem.writeInt(u32, buf[8..12], 2, .little); // entry_count

    buf[16..32].* = bat_guid;
    std.mem.writeInt(u64, buf[32..40], bat_offset, .little);

    buf[48..64].* = metadata_guid;
    std.mem.writeInt(u64, buf[64..72], metadata_offset, .little);

    const crc = vhdxTestCrc32c(&buf);
    std.mem.writeInt(u32, buf[4..8], crc, .little);
    try img.pwrite(io, &buf, offset);
}

fn writeVhdxTestMetadata(img: *Image, io: Io, offset: u64, block_size: u32, virtual_size: u64) !void {
    const guid = @import("guid.zig");
    const file_params_guid = guid.parse("CAA16737-FA36-4D43-B3B6-33F0AA44E76B");
    const virtual_size_guid = guid.parse("2FA54224-CD1B-4876-B211-5DBED83BF4B8");
    const logical_sector_guid = guid.parse("8141BF1D-A96F-4709-BA47-F233A8FAAB5F");

    // Metadata table header (32 bytes) + 3 entries (32 bytes each) = 128 bytes,
    // then the actual item data placed at 64KB into the region (spec minimum).
    var table_buf: [128]u8 = [_]u8{0} ** 128;
    table_buf[0..8].* = "metadata".*;
    std.mem.writeInt(u16, table_buf[10..12], 3, .little); // entry_count

    const item0_off: u32 = 64 * 1024;
    const item1_off: u32 = item0_off + 64;
    const item2_off: u32 = item1_off + 64;

    table_buf[32..48].* = file_params_guid;
    std.mem.writeInt(u32, table_buf[48..52], item0_off, .little);
    std.mem.writeInt(u32, table_buf[52..56], 8, .little);

    table_buf[64..80].* = virtual_size_guid;
    std.mem.writeInt(u32, table_buf[80..84], item1_off, .little);
    std.mem.writeInt(u32, table_buf[84..88], 8, .little);

    table_buf[96..112].* = logical_sector_guid;
    std.mem.writeInt(u32, table_buf[112..116], item2_off, .little);
    std.mem.writeInt(u32, table_buf[116..120], 4, .little);

    try img.pwrite(io, &table_buf, offset);

    var file_params: [8]u8 = undefined;
    std.mem.writeInt(u32, file_params[0..4], block_size, .little);
    std.mem.writeInt(u32, file_params[4..8], 0, .little); // data_bits: no HAS_PARENT
    try img.pwrite(io, &file_params, offset + item0_off);

    var vsize: [8]u8 = undefined;
    std.mem.writeInt(u64, &vsize, virtual_size, .little);
    try img.pwrite(io, &vsize, offset + item1_off);

    var lss: [4]u8 = undefined;
    std.mem.writeInt(u32, &lss, 512, .little);
    try img.pwrite(io, &lss, offset + item2_off);
}
