//! Grows the root partition + ext4 filesystem to fill a larger disk than
//! the image was built at ("growpart"/`resize2fs` equivalent). See zvmi
//! issue #130.
//!
//! Generalized images are typically built small and deployed onto VMs with
//! a larger, user-chosen OS disk (Azure lets you specify an OS disk size
//! larger than the image at deployment time, never smaller); without this,
//! that extra space is simply unreachable. Real `waagent` does not
//! implement this at all -- on real Azure Linux images this is
//! cloud-init's job (`growpart`/`resizefs` modules), not waagent's. But
//! `azagent` already deliberately never defers to cloud-init and always
//! fully owns provisioning instead (issue #112's explicit scope decision),
//! so this falls to `azagent` by the same logic that put SSH-key/user
//! provisioning there.
//!
//! Runs on *every* boot, like `resource_disk.zig` (#113), not gated by the
//! provisioning sentinel: disk resize is a deployment-time/redeploy-time
//! event, not a first-boot-only one. Idempotent by construction: growing
//! the partition table and the filesystem are both no-ops once they
//! already reach the disk's current real size.
//!
//! The partition table (GPT/MBR) is grown by writing directly to the
//! whole-disk block device -- safe regardless of mount state, since a
//! partition table isn't something the kernel caches/owns the way a
//! mounted filesystem's metadata is. The root ext4 filesystem itself,
//! though, is *always* mounted while this runs (that's how it's found at
//! all, via `/proc/mounts`), so it's grown live via the kernel's own
//! `EXT4_IOC_RESIZE_FS` ioctl (matching what `resize2fs` itself does
//! against a mounted filesystem) rather than this package's own
//! `ext4.resize()`, which writes new metadata directly to the backing
//! block device and is only safe when a filesystem is *not* currently
//! mounted (e.g. `resource_disk.zig`'s fresh-format case).
const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const zvmi = @import("zvmi");
const mbr = zvmi.mbr;
const gpt = zvmi.gpt;
const ext4 = zvmi.ext4;
const Image = zvmi.Image;
const resource_disk = @import("resource_disk.zig");

pub const RootDevice = struct {
    /// Owned. Whole-disk kernel device name, e.g. `"sda"` or `"nvme0n1"`.
    disk_name: []u8,
    /// Owned. Root partition's kernel device name, e.g. `"sda2"` or
    /// `"nvme0n1p2"`.
    partition_name: []u8,
    /// 1-based partition number (from the `partition` sysfs attribute,
    /// not hand-parsed from the name), used as a cross-check that the
    /// partition table entry about to be grown really is the mounted
    /// root, not just assumed from table position.
    partition_number: u32,
};

/// Pure parser: finds the device-path field (first whitespace-separated
/// column) of the `/proc/mounts` line whose mount point (second column) is
/// exactly `/`, and returns its basename (e.g. `/dev/sda2` -> `sda2`,
/// `/dev/nvme0n1p2` -> `nvme0n1p2`). Borrows from `content`.
fn rootPartitionNameFromMounts(content: []const u8) error{RootMountNotFound}![]const u8 {
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const device = fields.next() orelse continue;
        const mount_point = fields.next() orelse continue;
        if (std.mem.eql(u8, mount_point, "/")) {
            return std.fs.path.basename(device);
        }
    }
    return error.RootMountNotFound;
}

/// Resolves the root partition's whole-disk name and partition number.
///
/// `class_block_dir` is an open handle to `/sys/class/block` (production)
/// or a synthetic directory tree (tests). The partition's whole-disk name
/// is found by reading its symlink target text (e.g.
/// `/sys/class/block/sda2` -> `../../devices/.../block/sda/sda2`) and
/// taking the parent path component's basename -- purely string
/// manipulation on the link text, no real filesystem walk needed, and
/// robust across `sdXN`/`vdXN`/`nvme0n1pN`/`mmcblk0pN` naming schemes
/// without hand-parsing the partition name itself.
pub fn findRootDevice(allocator: Allocator, io: std.Io, proc_mounts_content: []const u8, class_block_dir: std.Io.Dir) !RootDevice {
    const partition_name = try rootPartitionNameFromMounts(proc_mounts_content);

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_len = try class_block_dir.readLink(io, partition_name, &link_buf);
    const link_target = link_buf[0..link_len];
    const parent = std.fs.path.dirname(link_target) orelse return error.RootDiskNameNotFound;
    const disk_name = std.fs.path.basename(parent);

    var partition_attr_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const partition_attr_path = try std.fmt.bufPrint(&partition_attr_path_buf, "{s}/partition", .{partition_name});
    const partition_number_content = try class_block_dir.readFileAlloc(io, partition_attr_path, allocator, .limited(64));
    defer allocator.free(partition_number_content);
    const partition_number = try std.fmt.parseInt(u32, std.mem.trim(u8, partition_number_content, " \t\r\n"), 10);

    return .{
        .disk_name = try allocator.dupe(u8, disk_name),
        .partition_name = try allocator.dupe(u8, partition_name),
        .partition_number = partition_number,
    };
}

/// Reads the full content of `/proc/mounts` via raw `open(2)`/`read(2)`
/// syscalls, working around `/proc/mounts` reporting a misleadingly small
/// `stat` size (confirmed: 11 bytes, regardless of real content) that
/// silently empties/truncates results read through `Io.Dir.readFileAlloc`
/// (which trusts that reported size) -- matching this repo's established
/// workaround in `resource_disk.zig`'s `isSwapActive` for `/proc/swaps`.
fn readProcMounts(allocator: Allocator) ![]u8 {
    const open_rc = linux.open("/proc/mounts", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(open_rc) != .SUCCESS) return error.ProcMountsOpenFailed;
    const fd: linux.fd_t = @intCast(open_rc);
    defer _ = linux.close(fd);

    var list = std.array_list.Managed(u8).init(allocator);
    errdefer list.deinit();

    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const read_rc = linux.read(fd, &buf, buf.len);
        if (linux.errno(read_rc) != .SUCCESS) return error.ProcMountsReadFailed;
        if (read_rc == 0) break;
        try list.appendSlice(buf[0..read_rc]);
    }
    return try list.toOwnedSlice();
}

/// Grows the GPT root partition (identified as the *last* entry in the
/// table, matching both zvmi-built images and real Azure Linux images) to
/// the disk's new, larger end. Returns whether anything actually changed:
/// `false` (a clean no-op) if the disk hasn't actually grown since the
/// table was last written -- the common case on every boot after the
/// first successful grow.
fn growGptRoot(allocator: Allocator, io: std.Io, img: *Image, root: RootDevice) !bool {
    const parsed = try gpt.readGpt(img.*, io, allocator);
    defer allocator.free(parsed.partitions);
    if (parsed.partitions.len == 0) return error.RootPartitionNotFound;

    // Safety cross-check: the root partition's kernel-reported partition
    // number should match its position in the table. Fail loudly rather
    // than silently growing the wrong partition if this ever doesn't
    // hold.
    if (root.partition_number != parsed.partitions.len) return error.RootPartitionPositionMismatch;

    gpt.growLastPartition(img, io, parsed.header.disk_guid, parsed.partitions) catch |err| switch (err) {
        error.NotEnoughSpace => return false,
        else => return err,
    };
    return true;
}

/// Grows the MBR (Gen1) root partition in place. Same no-op-on-
/// `NotEnoughSpace` contract as `growGptRoot`.
fn growMbrRoot(io: std.Io, img: *Image, decoded: mbr.Mbr, root: RootDevice) !bool {
    if (root.partition_number == 0 or root.partition_number > mbr.max_entries) return error.RootPartitionPositionMismatch;

    var table = decoded;
    const total_sectors = img.virtual_size / mbr.sector_size;
    mbr.growPartition(&table, root.partition_number - 1, total_sectors) catch |err| switch (err) {
        error.NotEnoughSpace => return false,
        else => return err,
    };

    const encoded = table.encode();
    try img.pwrite(io, &encoded, 0);
    return true;
}

/// Linux `EXT4_IOC_RESIZE_FS` ioctl request code (`_IOW('f', 16, __u64)`),
/// used to grow an *already-mounted* ext4 filesystem live, in the kernel,
/// so its own in-memory cached superblock/group-descriptor state stays
/// consistent with what lands on disk.
///
/// Deliberately NOT this package's own `ext4.resize()`: that's an offline
/// algorithm (see its doc comment) that `pwrite`s new metadata directly to
/// the backing block device, bypassing the kernel's ext4 driver entirely
/// -- safe for `resource_disk.zig`'s fresh, not-yet-mounted disk, but not
/// for the root filesystem here, which is *always* mounted while
/// `azagent` runs (that's literally how `findRootDevice` locates it, via
/// `/proc/mounts`). Writing directly to a live mounted filesystem's
/// backing device risks the kernel's cached view going stale (the growth
/// silently unnoticed, or later overwritten by the kernel's own stale
/// cached metadata) -- exactly what `resize2fs` itself avoids by using
/// this same ioctl on a mounted filesystem instead of touching the device
/// directly.
const ext4_ioc_resize_fs: u32 = 0x40086610;

/// Issues `EXT4_IOC_RESIZE_FS` against the filesystem mounted at
/// `mount_point_path` (always `"/"` for this module's use), asking the
/// kernel to grow it live to `new_block_count` (4096-byte) blocks.
fn onlineResizeExt4(mount_point_path: [:0]const u8, new_block_count: u64) !void {
    const open_rc = linux.open(mount_point_path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(open_rc) != .SUCCESS) return error.MountPointOpenFailed;
    const fd: linux.fd_t = @intCast(open_rc);
    defer _ = linux.close(fd);

    var arg: u64 = new_block_count;
    const rc = linux.ioctl(fd, ext4_ioc_resize_fs, @intFromPtr(&arg));
    if (linux.errno(rc) != .SUCCESS) return error.Ext4OnlineResizeFailed;
}

/// Grows the root partition table entry and, if that changed anything,
/// the mounted-live root ext4 filesystem within it to match (via the
/// kernel's own `EXT4_IOC_RESIZE_FS` ioctl -- see `onlineResizeExt4`).
/// `disk_file` must be an already-open, read-write handle to the *whole
/// disk* device node (e.g. `/dev/sda`), not the partition node --
/// partition-table growth must go through the whole-disk node, while
/// reading the partition's post-grow real size (to compute the new block
/// count) goes through the *partition* node (`part_path`, e.g.
/// `/dev/sda2`); mixing these two up is an easy, silent bug to introduce.
fn growRoot(io: std.Io, allocator: Allocator, disk_file: std.Io.File, part_path: [:0]const u8, root: RootDevice) !void {
    const real_size = try resource_disk.blockDeviceSizeBytes(disk_file);
    var img = Image{ .file = disk_file, .format = .raw, .data_offset = 0, .virtual_size = real_size };

    var sector0: [mbr.sector_size]u8 = undefined;
    _ = try img.pread(io, &sector0, 0);
    const decoded_mbr = mbr.Mbr.decode(&sector0) catch return error.UnrecognizedPartitionTable;

    const grown = switch (decoded_mbr.entries[0].partition_type) {
        .gpt_protective => try growGptRoot(allocator, io, &img, root),
        .linux => try growMbrRoot(io, &img, decoded_mbr, root),
        else => return error.UnrecognizedPartitionTable,
    };
    if (!grown) return;

    // The kernel's view of the partition device node's size is stale
    // until the partition table is re-read.
    resource_disk.reReadPartitionTable(disk_file);

    var part_file = try std.Io.Dir.cwd().openFile(io, part_path, .{ .mode = .read_only });
    defer part_file.close(io);

    const part_size_bytes = try resource_disk.blockDeviceSizeBytes(part_file);
    // The partition's real size need not be an exact multiple of the
    // 4096-byte ext4 block size; round down to be safe.
    const aligned_length = part_size_bytes - (part_size_bytes % ext4.default_block_size);
    const new_block_count = aligned_length / ext4.default_block_size;

    // The root filesystem is always mounted (at "/") while this runs.
    try onlineResizeExt4("/", new_block_count);
}

pub const SetupOptions = struct {
    allocator: Allocator,
    io: std.Io,
    /// Open handle to `/sys/class/block` (production), or a synthetic
    /// directory tree (tests).
    class_block_dir: std.Io.Dir,
};

/// Runs the full every-boot root-grow sequence: find the root device from
/// `/proc/mounts`, read its partition table, and grow the partition +
/// ext4 filesystem to the disk's real current size if it has grown.
/// Deliberately not covered by an automated test end to end -- it needs a
/// real block device special file and root, matching `resource_disk.
/// setup`'s precedent for real-device-only glue in this package; the
/// pure/testable pieces above (mounts parser, sysfs symlink resolution,
/// codec-level grow logic in `gpt.zig`/`mbr.zig`) are covered directly.
pub fn setup(options: SetupOptions) !void {
    const mounts_content = try readProcMounts(options.allocator);
    defer options.allocator.free(mounts_content);

    const root = try findRootDevice(options.allocator, options.io, mounts_content, options.class_block_dir);
    defer options.allocator.free(root.disk_name);
    defer options.allocator.free(root.partition_name);

    var disk_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const disk_path = try std.fmt.bufPrintZ(&disk_path_buf, "/dev/{s}", .{root.disk_name});
    var part_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const part_path = try std.fmt.bufPrintZ(&part_path_buf, "/dev/{s}", .{root.partition_name});

    var disk_file = try std.Io.Dir.cwd().openFile(options.io, disk_path, .{ .mode = .read_write });
    defer disk_file.close(options.io);

    try growRoot(options.io, options.allocator, disk_file, part_path, root);
}

test "rootPartitionNameFromMounts finds the device mounted at /" {
    const content =
        \\/dev/sda3 / ext4 rw,relatime 0 0
        \\devtmpfs /dev devtmpfs rw,nosuid,size=4096k,nr_inodes=4094394,mode=755 0 0
        \\/dev/sda2 /boot ext4 rw,relatime 0 0
        \\/dev/sda1 /boot/efi vfat rw,relatime 0 0
        \\
    ;
    try std.testing.expectEqualStrings("sda3", try rootPartitionNameFromMounts(content));
}

test "rootPartitionNameFromMounts handles nvme-style partition names" {
    const content = "/dev/nvme0n1p2 / ext4 rw,relatime 0 0\n";
    try std.testing.expectEqualStrings("nvme0n1p2", try rootPartitionNameFromMounts(content));
}

test "rootPartitionNameFromMounts returns an error when nothing is mounted at /" {
    const content = "tmpfs /tmp tmpfs rw,nosuid,nodev 0 0\n";
    try std.testing.expectError(error.RootMountNotFound, rootPartitionNameFromMounts(content));
}

test "findRootDevice resolves disk name and partition number via a synthetic /sys/class/block tree" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Synthetic sysfs shape:
    //   devices/mock/sda/sda2/partition  (content "2\n")
    //   class_block/sda2 -> ../devices/mock/sda/sda2  (symlink)
    try tmp.dir.createDirPath(io, "devices/mock/sda/sda2");
    try tmp.dir.writeFile(io, .{ .sub_path = "devices/mock/sda/sda2/partition", .data = "2\n" });
    try tmp.dir.createDirPath(io, "class_block");

    var class_block_dir = try tmp.dir.openDir(io, "class_block", .{});
    defer class_block_dir.close(io);
    try class_block_dir.symLink(io, "../devices/mock/sda/sda2", "sda2", .{});

    const mounts_content = "/dev/sda2 / ext4 rw,relatime 0 0\n";

    const root = try findRootDevice(std.testing.allocator, io, mounts_content, class_block_dir);
    defer std.testing.allocator.free(root.disk_name);
    defer std.testing.allocator.free(root.partition_name);

    try std.testing.expectEqualStrings("sda", root.disk_name);
    try std.testing.expectEqualStrings("sda2", root.partition_name);
    try std.testing.expectEqual(@as(u32, 2), root.partition_number);
}

test "findRootDevice handles nvme-style symlink targets" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "devices/mock/nvme0n1/nvme0n1p1");
    try tmp.dir.writeFile(io, .{ .sub_path = "devices/mock/nvme0n1/nvme0n1p1/partition", .data = "1\n" });
    try tmp.dir.createDirPath(io, "class_block");

    var class_block_dir = try tmp.dir.openDir(io, "class_block", .{});
    defer class_block_dir.close(io);
    try class_block_dir.symLink(io, "../devices/mock/nvme0n1/nvme0n1p1", "nvme0n1p1", .{});

    const mounts_content = "/dev/nvme0n1p1 / ext4 rw,relatime 0 0\n";

    const root = try findRootDevice(std.testing.allocator, io, mounts_content, class_block_dir);
    defer std.testing.allocator.free(root.disk_name);
    defer std.testing.allocator.free(root.partition_name);

    try std.testing.expectEqualStrings("nvme0n1", root.disk_name);
    try std.testing.expectEqualStrings("nvme0n1p1", root.partition_name);
    try std.testing.expectEqual(@as(u32, 1), root.partition_number);
}
