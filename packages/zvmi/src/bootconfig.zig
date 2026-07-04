//! ESP/bootloader population helpers: discover prebuilt signed EFI binaries
//! in a merged source tree, copy them into a FAT32 ESP, and generate minimal
//! GRUB + Boot Loader Specification text configuration without invoking any
//! external bootloader tooling.
//!
//! To keep future image-build orchestration consistent with `zvmi.ext4`, this
//! module reuses the exact same vtable-style source-tree interface:
//! `bootconfig.SourceTreeView == ext4.FileTreeView`.

const std = @import("std");
const Io = std.Io;
const ext4 = @import("ext4.zig");
const fat32 = @import("fat32.zig");
const guid = @import("guid.zig");
const layout = @import("layout.zig");
const Image = @import("image.zig").Image;
const gpt = @import("gpt.zig");

pub const SourceTreeView = ext4.FileTreeView;
pub const SourceKind = ext4.Kind;

pub const Architecture = enum {
    x86_64,
    aarch64,

    fn defaultBootPath(self: Architecture) []const u8 {
        return switch (self) {
            .x86_64 => "EFI/BOOT/BOOTX64.EFI",
            .aarch64 => "EFI/BOOT/BOOTAA64.EFI",
        };
    }
};

pub const PlannedPartitionIdentity = struct {
    planned: layout.PlannedPartition,
    unique_guid: guid.Guid,
};

pub const PopulateOptions = struct {
    /// The planned GPT partitions plus the unique GUIDs written into the GPT.
    planned_partitions: []const PlannedPartitionIdentity,
    /// Optional explicit CPU architecture. If omitted, the module infers it
    /// from EFI binary names and/or the planned root-partition role.
    architecture: ?Architecture = null,
    /// Optional override when the root partition is not the DPS root role for
    /// the detected architecture.
    root_role: ?layout.PartitionRole = null,
    /// Optional override for the partition that will contain the kernel and
    /// initrd paths referenced from the generated GRUB config. Defaults to the
    /// resolved root partition.
    kernel_device_partuuid: ?guid.Guid = null,
    /// Optional leading path prefix to strip when emitting `linux`/`initrd`
    /// paths. For example, stripping `boot/` turns `boot/vmlinuz-*` into
    /// `/vmlinuz-*` for callers that materialize `/boot` into a separate
    /// XBOOTLDR partition.
    path_strip_prefix: []const u8 = "",
    /// Optional human-friendly prefix for generated menu/BLS titles.
    title_prefix: []const u8 = "",
    /// Extra kernel command-line arguments appended after
    /// `root=PARTUUID=<...>`.
    extra_kernel_options: []const u8 = "",
    grub_timeout_seconds: u32 = 1,
};

pub const PopulateReport = struct {
    architecture: Architecture,
    copied_efi_file_count: usize,
    bls_entry_count: usize,
    default_bootloader_path: []const u8,
    esp_partuuid: guid.Guid,
    root_partuuid: guid.Guid,
    kernel_device_partuuid: guid.Guid,
};

pub const PopulateError = std.mem.Allocator.Error || fat32.MutationError ||
    SourceTreeView.IteratorError || SourceTreeView.ContentError || error{
    AmbiguousArchitecture,
    AmbiguousRootPartition,
    FileTooLarge,
    MissingBootloader,
    MissingContentReader,
    MissingEspPartition,
    MissingKernel,
    MissingRootPartition,
    UnexpectedSourceLength,
};

const EfiBinaryKind = enum {
    default_boot,
    shim,
    grub,
    mok_manager,
};

const EfiBinary = struct {
    destination_path: []u8,
    architecture: Architecture,
    kind: EfiBinaryKind,
    size: u64,
    content: SourceTreeView.ContentReader,
};

const KernelCandidate = struct {
    source_path: []u8,
    config_path: []u8,
};

const ScanResult = struct {
    efi_binaries: []EfiBinary,
    kernels: []KernelCandidate,
    initrds: []KernelCandidate,

    fn deinit(self: *ScanResult, allocator: std.mem.Allocator) void {
        for (self.efi_binaries) |binary| allocator.free(binary.destination_path);
        allocator.free(self.efi_binaries);
        freeCandidates(allocator, self.kernels);
        freeCandidates(allocator, self.initrds);
        self.* = undefined;
    }
};

const CopyPlanEntry = struct {
    destination_path: []u8,
    size: u64,
    content: SourceTreeView.ContentReader,
};

const BootEntry = struct {
    id: []u8,
    title: []u8,
    linux_path: []const u8,
    initrd_path: ?[]const u8,
};

fn freeCandidates(allocator: std.mem.Allocator, entries: []KernelCandidate) void {
    for (entries) |entry| {
        allocator.free(entry.source_path);
        allocator.free(entry.config_path);
    }
    allocator.free(entries);
}

fn freeBootEntries(allocator: std.mem.Allocator, entries: []BootEntry) void {
    for (entries) |entry| {
        allocator.free(entry.id);
        allocator.free(entry.title);
    }
    allocator.free(entries);
}

fn freeCopyPlan(allocator: std.mem.Allocator, entries: []CopyPlanEntry) void {
    for (entries) |entry| allocator.free(entry.destination_path);
    allocator.free(entries);
}

/// Discovers EFI binaries + kernel/initrd paths in `source`, copies the EFI
/// binaries into `esp`, and generates `EFI/.../grub.cfg`, `loader/loader.conf`,
/// and `loader/entries/*.conf` files.
pub fn populateEsp(
    allocator: std.mem.Allocator,
    io: Io,
    esp: *fat32.FileSystem,
    source: *SourceTreeView,
    options: PopulateOptions,
) PopulateError!PopulateReport {
    var scan = try scanSourceTree(allocator, source, options.path_strip_prefix);
    defer scan.deinit(allocator);

    if (scan.efi_binaries.len == 0) return error.MissingBootloader;
    if (scan.kernels.len == 0) return error.MissingKernel;

    sortKernelCandidates(scan.kernels);
    sortKernelCandidates(scan.initrds);

    const architecture = try resolveArchitecture(scan.efi_binaries, options);
    const esp_partuuid = findPartitionGuidByRole(options.planned_partitions, .esp) orelse return error.MissingEspPartition;
    const root_partuuid = try resolveRootPartitionGuid(options.planned_partitions, architecture, options.root_role);
    const kernel_device_partuuid = options.kernel_device_partuuid orelse root_partuuid;

    const copy_plan = try buildCopyPlan(allocator, scan.efi_binaries, architecture);
    defer freeCopyPlan(allocator, copy_plan);

    for (copy_plan) |entry| try copyIntoFat32(allocator, io, esp, entry);

    const boot_entries = try buildBootEntries(allocator, scan.kernels, scan.initrds, options.title_prefix);
    defer freeBootEntries(allocator, boot_entries);

    const loader_conf = try renderLoaderConf(allocator, boot_entries, options.grub_timeout_seconds);
    defer allocator.free(loader_conf);
    try writeGeneratedFile(io, esp, "loader/loader.conf", loader_conf);

    const grub_cfg = try renderGrubCfg(allocator, boot_entries, root_partuuid, kernel_device_partuuid, options.extra_kernel_options, options.grub_timeout_seconds);
    defer allocator.free(grub_cfg);

    try writeGeneratedFile(io, esp, "EFI/BOOT/grub.cfg", grub_cfg);

    var vendor_cfg_paths = try collectVendorGrubCfgPaths(allocator, copy_plan);
    defer {
        for (vendor_cfg_paths.items) |path| allocator.free(path);
        vendor_cfg_paths.deinit();
    }
    for (vendor_cfg_paths.items) |path| try writeGeneratedFile(io, esp, path, grub_cfg);

    for (boot_entries) |entry| {
        const bls_text = try renderBlsEntry(allocator, entry, root_partuuid, options.extra_kernel_options);
        defer allocator.free(bls_text);
        const bls_path = try std.fmt.allocPrint(allocator, "loader/entries/{s}.conf", .{entry.id});
        defer allocator.free(bls_path);
        try writeGeneratedFile(io, esp, bls_path, bls_text);
    }

    return .{
        .architecture = architecture,
        .copied_efi_file_count = copy_plan.len,
        .bls_entry_count = boot_entries.len,
        .default_bootloader_path = architecture.defaultBootPath(),
        .esp_partuuid = esp_partuuid,
        .root_partuuid = root_partuuid,
        .kernel_device_partuuid = kernel_device_partuuid,
    };
}

fn scanSourceTree(
    allocator: std.mem.Allocator,
    source: *SourceTreeView,
    strip_prefix: []const u8,
) PopulateError!ScanResult {
    var efi_binaries = std.array_list.Managed(EfiBinary).init(allocator);
    errdefer {
        for (efi_binaries.items) |entry| allocator.free(entry.destination_path);
        efi_binaries.deinit();
    }

    var kernels = std.array_list.Managed(KernelCandidate).init(allocator);
    errdefer {
        freeCandidates(allocator, kernels.items);
        kernels.deinit();
    }

    var initrds = std.array_list.Managed(KernelCandidate).init(allocator);
    errdefer {
        freeCandidates(allocator, initrds.items);
        initrds.deinit();
    }

    source.reset();
    while (try source.next()) |entry| {
        if (entry.kind == .file) {
            if (entry.content) |content| {
                if (try classifyEfiBinary(allocator, entry.path)) |efi_binary| {
                    try efi_binaries.append(.{
                        .destination_path = efi_binary.destination_path,
                        .architecture = efi_binary.architecture,
                        .kind = efi_binary.kind,
                        .size = entry.size,
                        .content = content,
                    });
                }
            }
        }

        if (entry.kind == .directory) continue;
        if (isKernelPath(entry.path)) {
            try kernels.append(.{
                .source_path = try allocator.dupe(u8, entry.path),
                .config_path = try makeConfigPath(allocator, entry.path, strip_prefix),
            });
        } else if (isInitrdPath(entry.path)) {
            try initrds.append(.{
                .source_path = try allocator.dupe(u8, entry.path),
                .config_path = try makeConfigPath(allocator, entry.path, strip_prefix),
            });
        }
    }

    return .{
        .efi_binaries = try efi_binaries.toOwnedSlice(),
        .kernels = try kernels.toOwnedSlice(),
        .initrds = try initrds.toOwnedSlice(),
    };
}

fn classifyEfiBinary(
    allocator: std.mem.Allocator,
    path: []const u8,
) std.mem.Allocator.Error!?struct {
    destination_path: []u8,
    architecture: Architecture,
    kind: EfiBinaryKind,
} {
    const basename = baseName(path);
    const classification: ?struct { architecture: Architecture, kind: EfiBinaryKind } = if (std.ascii.eqlIgnoreCase(basename, "BOOTX64.EFI"))
        .{ .architecture = Architecture.x86_64, .kind = EfiBinaryKind.default_boot }
    else if (std.ascii.eqlIgnoreCase(basename, "shimx64.efi"))
        .{ .architecture = Architecture.x86_64, .kind = EfiBinaryKind.shim }
    else if (std.ascii.eqlIgnoreCase(basename, "grubx64.efi"))
        .{ .architecture = Architecture.x86_64, .kind = EfiBinaryKind.grub }
    else if (std.ascii.eqlIgnoreCase(basename, "mmx64.efi"))
        .{ .architecture = Architecture.x86_64, .kind = EfiBinaryKind.mok_manager }
    else if (std.ascii.eqlIgnoreCase(basename, "BOOTAA64.EFI"))
        .{ .architecture = Architecture.aarch64, .kind = EfiBinaryKind.default_boot }
    else if (std.ascii.eqlIgnoreCase(basename, "shimaa64.efi"))
        .{ .architecture = Architecture.aarch64, .kind = EfiBinaryKind.shim }
    else if (std.ascii.eqlIgnoreCase(basename, "grubaa64.efi"))
        .{ .architecture = Architecture.aarch64, .kind = EfiBinaryKind.grub }
    else if (std.ascii.eqlIgnoreCase(basename, "mmaa64.efi"))
        .{ .architecture = Architecture.aarch64, .kind = EfiBinaryKind.mok_manager }
    else
        null;
    if (classification == null) return null;

    const dest_path = try efiDestinationPath(allocator, path) orelse return null;
    return .{
        .destination_path = dest_path,
        .architecture = classification.?.architecture,
        .kind = classification.?.kind,
    };
}

fn efiDestinationPath(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!?[]u8 {
    var start: usize = 0;
    while (start < path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
        if (std.ascii.eqlIgnoreCase(path[start..end], "EFI")) {
            if (end == path.len) return null;
            const out = try std.fmt.allocPrint(allocator, "EFI/{s}", .{path[end + 1 ..]});
            return out;
        }
        if (end == path.len) break;
        start = end + 1;
    }
    return null;
}

fn isKernelPath(path: []const u8) bool {
    if (!isBootScopedPath(path)) return false;
    const basename = baseName(path);
    return std.ascii.startsWithIgnoreCase(basename, "vmlinuz") or
        std.ascii.startsWithIgnoreCase(basename, "linux") or
        std.ascii.eqlIgnoreCase(basename, "Image") or
        std.ascii.startsWithIgnoreCase(basename, "Image-");
}

fn isInitrdPath(path: []const u8) bool {
    if (!isBootScopedPath(path)) return false;
    const basename = baseName(path);
    return std.ascii.startsWithIgnoreCase(basename, "initrd") or
        std.ascii.startsWithIgnoreCase(basename, "initramfs");
}

fn isBootScopedPath(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, '/')) |slash| {
        return std.ascii.eqlIgnoreCase(path[0..slash], "boot");
    }
    const basename = baseName(path);
    return std.ascii.startsWithIgnoreCase(basename, "vmlinuz") or
        std.ascii.startsWithIgnoreCase(basename, "linux") or
        std.ascii.eqlIgnoreCase(basename, "Image");
}

fn makeConfigPath(allocator: std.mem.Allocator, source_path: []const u8, strip_prefix: []const u8) std.mem.Allocator.Error![]u8 {
    const trimmed_prefix = trimSlashes(strip_prefix);
    var remainder = source_path;
    if (trimmed_prefix.len > 0) {
        if (std.ascii.eqlIgnoreCase(remainder, trimmed_prefix)) {
            remainder = "";
        } else if (remainder.len > trimmed_prefix.len and
            std.ascii.eqlIgnoreCase(remainder[0..trimmed_prefix.len], trimmed_prefix) and
            remainder[trimmed_prefix.len] == '/')
        {
            remainder = remainder[trimmed_prefix.len + 1 ..];
        }
    }
    return std.fmt.allocPrint(allocator, "/{s}", .{remainder});
}

fn trimSlashes(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and value[start] == '/') : (start += 1) {}
    while (end > start and value[end - 1] == '/') : (end -= 1) {}
    return value[start..end];
}

fn sortKernelCandidates(entries: []KernelCandidate) void {
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, entries[j].source_path, entries[j - 1].source_path)) : (j -= 1) {
            std.mem.swap(KernelCandidate, &entries[j], &entries[j - 1]);
        }
    }
}

fn resolveArchitecture(efi_binaries: []const EfiBinary, options: PopulateOptions) PopulateError!Architecture {
    if (options.architecture) |architecture| return architecture;
    if (options.root_role) |role| {
        if (architectureForRole(role)) |architecture| return architecture;
    }

    var saw_x86 = false;
    var saw_arm = false;
    for (efi_binaries) |binary| switch (binary.architecture) {
        .x86_64 => saw_x86 = true,
        .aarch64 => saw_arm = true,
    };

    if (saw_x86 and !saw_arm) return .x86_64;
    if (saw_arm and !saw_x86) return .aarch64;

    var inferred_from_partitions: ?Architecture = null;
    for (options.planned_partitions) |partition| {
        const architecture = architectureForRole(partition.planned.role) orelse continue;
        if (inferred_from_partitions == null) {
            inferred_from_partitions = architecture;
        } else if (inferred_from_partitions.? != architecture) {
            inferred_from_partitions = null;
            break;
        }
    }
    if (inferred_from_partitions) |architecture| return architecture;

    return error.AmbiguousArchitecture;
}

fn architectureForRole(role: layout.PartitionRole) ?Architecture {
    return switch (role) {
        .root_x86_64, .usr_x86_64 => .x86_64,
        .root_aarch64, .usr_aarch64 => .aarch64,
        else => null,
    };
}

fn defaultRootRoleForArchitecture(architecture: Architecture) layout.PartitionRole {
    return switch (architecture) {
        .x86_64 => .root_x86_64,
        .aarch64 => .root_aarch64,
    };
}

fn findPartitionGuidByRole(
    planned_partitions: []const PlannedPartitionIdentity,
    role: layout.PartitionRole,
) ?guid.Guid {
    for (planned_partitions) |partition| {
        if (partition.planned.role == role) return partition.unique_guid;
    }
    return null;
}

fn resolveRootPartitionGuid(
    planned_partitions: []const PlannedPartitionIdentity,
    architecture: Architecture,
    override_role: ?layout.PartitionRole,
) PopulateError!guid.Guid {
    if (override_role) |role| {
        return findPartitionGuidByRole(planned_partitions, role) orelse error.MissingRootPartition;
    }

    if (findPartitionGuidByRole(planned_partitions, defaultRootRoleForArchitecture(architecture))) |partition_guid| {
        return partition_guid;
    }

    var fallback: ?guid.Guid = null;
    for (planned_partitions) |partition| {
        switch (partition.planned.role) {
            .root_x86_64, .root_aarch64, .linux_filesystem_data => {
                if (fallback == null) {
                    fallback = partition.unique_guid;
                } else if (!std.mem.eql(u8, &fallback.?, &partition.unique_guid)) {
                    return error.AmbiguousRootPartition;
                }
            },
            else => {},
        }
    }
    return fallback orelse error.MissingRootPartition;
}

fn buildCopyPlan(
    allocator: std.mem.Allocator,
    efi_binaries: []const EfiBinary,
    architecture: Architecture,
) std.mem.Allocator.Error![]CopyPlanEntry {
    var plan = std.array_list.Managed(CopyPlanEntry).init(allocator);
    errdefer {
        for (plan.items) |entry| allocator.free(entry.destination_path);
        plan.deinit();
    }

    for (efi_binaries) |binary| {
        if (containsPathIgnoreCase(plan.items, binary.destination_path)) continue;
        try plan.append(.{
            .destination_path = try allocator.dupe(u8, binary.destination_path),
            .size = binary.size,
            .content = binary.content,
        });
    }

    const fallback_path = architecture.defaultBootPath();
    if (!containsPathIgnoreCase(plan.items, fallback_path)) {
        if (bestFallbackBinary(efi_binaries, architecture)) |binary| {
            try plan.append(.{
                .destination_path = try allocator.dupe(u8, fallback_path),
                .size = binary.size,
                .content = binary.content,
            });
        }
    }

    return plan.toOwnedSlice();
}

fn containsPathIgnoreCase(entries: []const CopyPlanEntry, candidate: []const u8) bool {
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.destination_path, candidate)) return true;
    }
    return false;
}

fn bestFallbackBinary(efi_binaries: []const EfiBinary, architecture: Architecture) ?EfiBinary {
    var best: ?EfiBinary = null;
    var best_priority: usize = std.math.maxInt(usize);
    for (efi_binaries) |binary| {
        if (binary.architecture != architecture) continue;
        const priority: usize = switch (binary.kind) {
            .default_boot => 0,
            .shim => 1,
            .grub => 2,
            .mok_manager => 3,
        };
        if (best == null or priority < best_priority) {
            best = binary;
            best_priority = priority;
        }
    }
    return best;
}

fn copyIntoFat32(
    allocator: std.mem.Allocator,
    io: Io,
    esp: *fat32.FileSystem,
    entry: CopyPlanEntry,
) PopulateError!void {
    const contents = try readSourceFileAlloc(allocator, entry.content, entry.size);
    defer allocator.free(contents);
    try writeGeneratedFile(io, esp, entry.destination_path, contents);
}

fn readSourceFileAlloc(
    allocator: std.mem.Allocator,
    reader: SourceTreeView.ContentReader,
    size: u64,
) PopulateError![]u8 {
    const len = std.math.cast(usize, size) orelse return error.FileTooLarge;
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);

    var done: usize = 0;
    while (done < out.len) {
        const got = try reader.readAt(out[done..], done);
        if (got == 0) return error.UnexpectedSourceLength;
        done += got;
    }
    return out;
}

fn buildBootEntries(
    allocator: std.mem.Allocator,
    kernels: []const KernelCandidate,
    initrds: []const KernelCandidate,
    title_prefix: []const u8,
) std.mem.Allocator.Error![]BootEntry {
    var used_ids = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (used_ids.items) |id| allocator.free(id);
        used_ids.deinit();
    }

    var entries = std.array_list.Managed(BootEntry).init(allocator);
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.title);
        }
        entries.deinit();
    }

    for (kernels) |kernel| {
        const basename = baseName(kernel.source_path);
        const base_id = try sanitizeId(allocator, basename);
        defer allocator.free(base_id);
        const id = try makeUniqueId(allocator, base_id, used_ids.items);
        errdefer allocator.free(id);
        try used_ids.append(try allocator.dupe(u8, id));

        const title = if (title_prefix.len == 0)
            try allocator.dupe(u8, basename)
        else
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ title_prefix, basename });
        errdefer allocator.free(title);

        const initrd = bestMatchingInitrd(kernel, initrds);
        try entries.append(.{
            .id = id,
            .title = title,
            .linux_path = kernel.config_path,
            .initrd_path = if (initrd) |value| value.config_path else null,
        });
    }

    return entries.toOwnedSlice();
}

fn sanitizeId(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    for (value) |ch| {
        const mapped = if ((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.')
            ch
        else if (ch >= 'A' and ch <= 'Z')
            std.ascii.toLower(ch)
        else
            '-';
        try out.append(mapped);
    }
    if (out.items.len == 0) try out.appendSlice("entry");
    return out.toOwnedSlice();
}

fn makeUniqueId(
    allocator: std.mem.Allocator,
    base_id: []const u8,
    existing_ids: []const []u8,
) std.mem.Allocator.Error![]u8 {
    if (!containsString(existing_ids, base_id)) return allocator.dupe(u8, base_id);

    var suffix: usize = 2;
    while (true) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ base_id, suffix });
        errdefer allocator.free(candidate);
        if (!containsString(existing_ids, candidate)) return candidate;
        allocator.free(candidate);
    }
}

fn containsString(existing: []const []u8, candidate: []const u8) bool {
    for (existing) |value| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn bestMatchingInitrd(kernel: KernelCandidate, initrds: []const KernelCandidate) ?KernelCandidate {
    var best_index: ?usize = null;
    var best_score: i32 = -1;
    for (initrds, 0..) |candidate, index| {
        const score = scoreKernelInitrdPair(kernel, candidate);
        if (score > best_score) {
            best_score = score;
            best_index = index;
        }
    }
    if (best_index == null or best_score < 0) return null;
    return initrds[best_index.?];
}

fn scoreKernelInitrdPair(kernel: KernelCandidate, initrd: KernelCandidate) i32 {
    var score: i32 = 1;
    if (std.ascii.eqlIgnoreCase(dirName(kernel.source_path), dirName(initrd.source_path))) score += 10;

    const kernel_key = versionKey(baseName(kernel.source_path), true);
    const initrd_key = versionKey(baseName(initrd.source_path), false);
    if (kernel_key.len != 0 and initrd_key.len != 0 and std.ascii.eqlIgnoreCase(kernel_key, initrd_key)) {
        score += 100;
    } else if (kernel_key.len != 0 and endsWithIgnoreCase(baseName(initrd.source_path), kernel_key)) {
        score += 50;
    }

    return score;
}

fn versionKey(name: []const u8, comptime kernel: bool) []const u8 {
    if (kernel) {
        if (std.ascii.startsWithIgnoreCase(name, "vmlinuz-")) return name[8..];
        if (std.ascii.startsWithIgnoreCase(name, "linux-")) return name[6..];
        if (std.ascii.startsWithIgnoreCase(name, "Image-")) return name[6..];
        return "";
    }

    if (std.ascii.startsWithIgnoreCase(name, "initramfs-")) {
        return trimImgSuffix(name[10..]);
    }
    if (std.ascii.startsWithIgnoreCase(name, "initrd.img-")) {
        return trimImgSuffix(name[11..]);
    }
    if (std.ascii.startsWithIgnoreCase(name, "initrd-")) {
        return trimImgSuffix(name[7..]);
    }
    if (std.ascii.eqlIgnoreCase(name, "initrd.img") or std.ascii.eqlIgnoreCase(name, "initrd")) {
        return "";
    }
    return "";
}

fn trimImgSuffix(value: []const u8) []const u8 {
    if (value.len > 4 and std.ascii.eqlIgnoreCase(value[value.len - 4 ..], ".img")) {
        return value[0 .. value.len - 4];
    }
    return value;
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

fn renderLoaderConf(
    allocator: std.mem.Allocator,
    entries: []const BootEntry,
    timeout_seconds: u32,
) std.mem.Allocator.Error![]u8 {
    std.debug.assert(entries.len != 0);
    return std.fmt.allocPrint(allocator, "default {s}\ntimeout {d}\n", .{ entries[0].id, timeout_seconds });
}

fn renderGrubCfg(
    allocator: std.mem.Allocator,
    entries: []const BootEntry,
    root_partuuid: guid.Guid,
    kernel_device_partuuid: guid.Guid,
    extra_kernel_options: []const u8,
    timeout_seconds: u32,
) std.mem.Allocator.Error![]u8 {
    var root_guid_buf: [36]u8 = undefined;
    var kernel_guid_buf: [36]u8 = undefined;
    const root_partuuid_text = guid.formatLower(&root_guid_buf, root_partuuid);
    const kernel_partuuid_text = guid.formatLower(&kernel_guid_buf, kernel_device_partuuid);

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    out.writer.print(
        "set default=0\nset timeout={d}\n\ninsmod part_gpt\ninsmod ext2\nsearch --no-floppy --partuuid --set=kernel_root {s}\n\n",
        .{ timeout_seconds, kernel_partuuid_text },
    ) catch return error.OutOfMemory;

    for (entries) |entry| {
        out.writer.print("menuentry '{s}' --id '{s}' {{\n", .{ entry.title, entry.id }) catch return error.OutOfMemory;
        out.writer.print("    linux ($kernel_root){s} root=PARTUUID={s}", .{ entry.linux_path, root_partuuid_text }) catch return error.OutOfMemory;
        if (extra_kernel_options.len != 0) out.writer.print(" {s}", .{extra_kernel_options}) catch return error.OutOfMemory;
        out.writer.writeAll("\n") catch return error.OutOfMemory;
        if (entry.initrd_path) |initrd_path| {
            out.writer.print("    initrd ($kernel_root){s}\n", .{initrd_path}) catch return error.OutOfMemory;
        }
        out.writer.writeAll("}\n\n") catch return error.OutOfMemory;
    }

    return out.toOwnedSlice();
}

fn renderBlsEntry(
    allocator: std.mem.Allocator,
    entry: BootEntry,
    root_partuuid: guid.Guid,
    extra_kernel_options: []const u8,
) std.mem.Allocator.Error![]u8 {
    var root_guid_buf: [36]u8 = undefined;
    const root_partuuid_text = guid.formatLower(&root_guid_buf, root_partuuid);

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    out.writer.print(
        "title {s}\nversion {s}\nlinux {s}\n",
        .{ entry.title, baseName(entry.linux_path), entry.linux_path },
    ) catch return error.OutOfMemory;
    if (entry.initrd_path) |initrd_path| {
        out.writer.print("initrd {s}\n", .{initrd_path}) catch return error.OutOfMemory;
    }
    out.writer.print("options root=PARTUUID={s}", .{root_partuuid_text}) catch return error.OutOfMemory;
    if (extra_kernel_options.len != 0) out.writer.print(" {s}", .{extra_kernel_options}) catch return error.OutOfMemory;
    out.writer.writeAll("\n") catch return error.OutOfMemory;

    return out.toOwnedSlice();
}

fn collectVendorGrubCfgPaths(
    allocator: std.mem.Allocator,
    copy_plan: []const CopyPlanEntry,
) std.mem.Allocator.Error!std.array_list.Managed([]u8) {
    var paths = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }

    for (copy_plan) |entry| {
        const vendor = efiVendor(entry.destination_path) orelse continue;
        if (std.ascii.eqlIgnoreCase(vendor, "BOOT")) continue;
        const cfg_path = try std.fmt.allocPrint(allocator, "EFI/{s}/grub.cfg", .{vendor});
        errdefer allocator.free(cfg_path);
        if (containsSliceIgnoreCase(paths.items, cfg_path)) {
            allocator.free(cfg_path);
            continue;
        }
        try paths.append(cfg_path);
    }

    return paths;
}

fn containsSliceIgnoreCase(values: []const []u8, candidate: []const u8) bool {
    for (values) |value| {
        if (std.ascii.eqlIgnoreCase(value, candidate)) return true;
    }
    return false;
}

fn efiVendor(path: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(path, "EFI/")) return null;
    const rest = path[4..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return rest[0..slash];
}

fn writeGeneratedFile(io: Io, esp: *fat32.FileSystem, path: []const u8, contents: []const u8) PopulateError!void {
    const parent = dirName(path);
    if (parent.len != 0) try esp.createDir(io, parent);
    try esp.writeFile(io, path, contents);
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn dirName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

test "populateEsp copies EFI binaries and generates grub.cfg plus BLS entries" {
    const io = std.testing.io;
    const path = "test-bootconfig-populate.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const disk_size = 256 * 1024 * 1024;
    const requests = [_]layout.PartitionRequest{
        .{ .name = "ESP", .role = .esp, .size = .{ .fixed = 96 * 1024 * 1024 } },
        .{ .name = "root", .role = .root_x86_64, .size = .{ .percent = 100.0 } },
    };
    const planned = try layout.planLayout(std.testing.allocator, disk_size, &requests, null);
    defer std.testing.allocator.free(planned);

    const identities = [_]PlannedPartitionIdentity{
        .{ .planned = planned[0], .unique_guid = guid.parse("11111111-1111-1111-1111-111111111111") },
        .{ .planned = planned[1], .unique_guid = guid.parse("22222222-2222-2222-2222-222222222222") },
    };

    var img = try Image.create(io, path, .raw, disk_size, .{});
    defer img.close(io);

    const specs = [_]gpt.PlacedPartitionSpec{
        .{
            .type_guid = identities[0].planned.type_guid,
            .unique_guid = identities[0].unique_guid,
            .placement = .{ .first_lba = identities[0].planned.firstLba(), .last_lba = identities[0].planned.lastLba() },
            .name_utf16le = gpt.asciiName(identities[0].planned.name),
        },
        .{
            .type_guid = identities[1].planned.type_guid,
            .unique_guid = identities[1].unique_guid,
            .placement = .{ .first_lba = identities[1].planned.firstLba(), .last_lba = identities[1].planned.lastLba() },
            .name_utf16le = gpt.asciiName(identities[1].planned.name),
        },
    };
    try gpt.writeGptPlaced(&img, io, guid.parse("33333333-3333-3333-3333-333333333333"), &specs);

    try fat32.format(&img, io, .{
        .partition_offset = identities[0].planned.offset_bytes,
        .partition_len = identities[0].planned.length_bytes,
    });
    var esp = try fat32.open(&img, io, .{ .offset = identities[0].planned.offset_bytes, .length = identities[0].planned.length_bytes });

    var tree = InMemoryTree.init(&[_]InMemoryEntry{
        .{ .path = "EFI/BOOT/BOOTX64.EFI", .kind = .file, .bytes = "bootx64-bytes" },
        .{ .path = "EFI/Acme/shimx64.efi", .kind = .file, .bytes = "shimx64-bytes" },
        .{ .path = "EFI/Acme/grubx64.efi", .kind = .file, .bytes = "grubx64-bytes" },
        .{ .path = "EFI/Acme/mmx64.efi", .kind = .file, .bytes = "mmx64-bytes" },
        .{ .path = "boot/vmlinuz-6.8.12-test", .kind = .file, .bytes = "kernel-bits" },
        .{ .path = "boot/initramfs-6.8.12-test.img", .kind = .file, .bytes = "initrd-bits" },
    });
    tree.bind();

    const report = try populateEsp(std.testing.allocator, io, &esp, &tree.view, .{
        .planned_partitions = &identities,
        .extra_kernel_options = "console=ttyS0 quiet",
        .title_prefix = "zvmi",
    });
    try std.testing.expectEqual(Architecture.x86_64, report.architecture);
    try std.testing.expectEqual(@as(usize, 4), report.copied_efi_file_count);
    try std.testing.expectEqual(@as(usize, 1), report.bls_entry_count);

    const parsed = try gpt.readGpt(img, io, std.testing.allocator);
    defer std.testing.allocator.free(parsed.partitions);
    try std.testing.expectEqual(@as(usize, 2), parsed.partitions.len);
    try std.testing.expectEqualSlices(u8, &identities[0].unique_guid, &parsed.partitions[0].unique_partition_guid);
    try std.testing.expectEqualSlices(u8, &identities[1].unique_guid, &parsed.partitions[1].unique_partition_guid);

    const bootx64 = try esp.readFileAlloc(io, std.testing.allocator, "EFI/BOOT/BOOTX64.EFI");
    defer std.testing.allocator.free(bootx64);
    try std.testing.expectEqualStrings("bootx64-bytes", bootx64);

    const shim = try esp.readFileAlloc(io, std.testing.allocator, "EFI/Acme/shimx64.efi");
    defer std.testing.allocator.free(shim);
    try std.testing.expectEqualStrings("shimx64-bytes", shim);

    const grub = try esp.readFileAlloc(io, std.testing.allocator, "EFI/Acme/grubx64.efi");
    defer std.testing.allocator.free(grub);
    try std.testing.expectEqualStrings("grubx64-bytes", grub);

    const mok = try esp.readFileAlloc(io, std.testing.allocator, "EFI/Acme/mmx64.efi");
    defer std.testing.allocator.free(mok);
    try std.testing.expectEqualStrings("mmx64-bytes", mok);

    const loader_conf = try esp.readFileAlloc(io, std.testing.allocator, "loader/loader.conf");
    defer std.testing.allocator.free(loader_conf);
    try std.testing.expectEqualStrings("default vmlinuz-6.8.12-test\ntimeout 1\n", loader_conf);

    const grub_cfg = try esp.readFileAlloc(io, std.testing.allocator, "EFI/BOOT/grub.cfg");
    defer std.testing.allocator.free(grub_cfg);
    var root_guid_buf: [36]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, grub_cfg, "search --no-floppy --partuuid --set=kernel_root 22222222-2222-2222-2222-222222222222") != null);
    try std.testing.expect(std.mem.indexOf(u8, grub_cfg, "menuentry 'zvmi vmlinuz-6.8.12-test' --id 'vmlinuz-6.8.12-test'") != null);
    try std.testing.expect(std.mem.indexOf(u8, grub_cfg, "linux ($kernel_root)/boot/vmlinuz-6.8.12-test root=PARTUUID=22222222-2222-2222-2222-222222222222 console=ttyS0 quiet") != null);
    try std.testing.expect(std.mem.indexOf(u8, grub_cfg, "initrd ($kernel_root)/boot/initramfs-6.8.12-test.img") != null);
    _ = guid.formatLower(&root_guid_buf, parsed.partitions[1].unique_partition_guid);
    try std.testing.expect(std.mem.indexOf(u8, grub_cfg, root_guid_buf[0..]) != null);

    const vendor_grub_cfg = try esp.readFileAlloc(io, std.testing.allocator, "EFI/Acme/grub.cfg");
    defer std.testing.allocator.free(vendor_grub_cfg);
    try std.testing.expectEqualSlices(u8, grub_cfg, vendor_grub_cfg);

    const bls_entry = try esp.readFileAlloc(io, std.testing.allocator, "loader/entries/vmlinuz-6.8.12-test.conf");
    defer std.testing.allocator.free(bls_entry);
    const parsed_bls = try parseBlsEntry(bls_entry);
    try std.testing.expectEqualStrings("zvmi vmlinuz-6.8.12-test", parsed_bls.title.?);
    try std.testing.expectEqualStrings("/boot/vmlinuz-6.8.12-test", parsed_bls.linux.?);
    try std.testing.expectEqualStrings("/boot/initramfs-6.8.12-test.img", parsed_bls.initrd.?);
    try std.testing.expectEqualStrings("root=PARTUUID=22222222-2222-2222-2222-222222222222 console=ttyS0 quiet", parsed_bls.options.?);
}

test "populateEsp synthesizes fallback BOOTX64.EFI from shim when needed" {
    const io = std.testing.io;
    const path = "test-bootconfig-fallback.img";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const esp_len = 96 * 1024 * 1024;
    var img = try Image.create(io, path, .raw, esp_len, .{});
    defer img.close(io);
    try fat32.format(&img, io, .{ .partition_offset = 0, .partition_len = esp_len });
    var esp = try fat32.open(&img, io, .{ .offset = 0, .length = esp_len });

    const planned = [_]PlannedPartitionIdentity{
        .{ .planned = .{
            .name = "ESP",
            .role = .esp,
            .type_guid = guid.esp,
            .offset_bytes = 0,
            .length_bytes = esp_len,
        }, .unique_guid = guid.parse("44444444-4444-4444-4444-444444444444") },
        .{ .planned = .{
            .name = "root",
            .role = .root_x86_64,
            .type_guid = guid.linux_root_x86_64,
            .offset_bytes = esp_len,
            .length_bytes = esp_len,
        }, .unique_guid = guid.parse("55555555-5555-5555-5555-555555555555") },
    };

    var tree = InMemoryTree.init(&[_]InMemoryEntry{
        .{ .path = "EFI/Test/shimx64.efi", .kind = .file, .bytes = "shim-payload" },
        .{ .path = "boot/vmlinuz-test", .kind = .file, .bytes = "kernel" },
        .{ .path = "boot/initrd-test.img", .kind = .file, .bytes = "initrd" },
    });
    tree.bind();

    const report = try populateEsp(std.testing.allocator, io, &esp, &tree.view, .{
        .planned_partitions = &planned,
    });
    try std.testing.expectEqualStrings("EFI/BOOT/BOOTX64.EFI", report.default_bootloader_path);

    const fallback = try esp.readFileAlloc(io, std.testing.allocator, "EFI/BOOT/BOOTX64.EFI");
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("shim-payload", fallback);

    const shim = try esp.readFileAlloc(io, std.testing.allocator, "EFI/Test/shimx64.efi");
    defer std.testing.allocator.free(shim);
    try std.testing.expectEqualStrings("shim-payload", shim);
}

const ParsedBlsEntry = struct {
    title: ?[]const u8 = null,
    version: ?[]const u8 = null,
    linux: ?[]const u8 = null,
    initrd: ?[]const u8 = null,
    options: ?[]const u8 = null,
};

fn parseBlsEntry(contents: []const u8) !ParsedBlsEntry {
    var parsed = ParsedBlsEntry{};
    var it = std.mem.tokenizeScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const split = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..split];
        var value = line[split + 1 ..];
        while (value.len != 0 and value[0] == " "[0]) value = value[1..];
        if (std.mem.eql(u8, key, "title")) parsed.title = value else if (std.mem.eql(u8, key, "version")) parsed.version = value else if (std.mem.eql(u8, key, "linux")) parsed.linux = value else if (std.mem.eql(u8, key, "initrd")) parsed.initrd = value else if (std.mem.eql(u8, key, "options")) parsed.options = value;
    }
    try std.testing.expect(parsed.title != null);
    try std.testing.expect(parsed.linux != null);
    try std.testing.expect(parsed.options != null);
    return parsed;
}

const InMemoryEntry = struct {
    path: []const u8,
    kind: SourceKind,
    bytes: []const u8 = "",
    mode: u16 = 0o644,
    uid: u32 = 0,
    gid: u32 = 0,
};

const InMemoryTree = struct {
    entries: []const InMemoryEntry,
    index: usize = 0,
    view: SourceTreeView,

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

    fn next(ctx: *anyopaque) SourceTreeView.IteratorError!?SourceTreeView.Entry {
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
            .size = entry.bytes.len,
            .content = if (entry.kind == .directory)
                null
            else
                .{ .ctx = &self.entries[self.index - 1], .read_at_fn = readContent },
        };
    }

    fn readContent(ctx: *const anyopaque, buffer: []u8, offset: u64) SourceTreeView.ContentError!usize {
        const entry: *const InMemoryEntry = @ptrCast(@alignCast(ctx));
        const start = std.math.cast(usize, offset) orelse return error.UnexpectedEndOfStream;
        if (start > entry.bytes.len) return error.UnexpectedEndOfStream;
        const count = @min(buffer.len, entry.bytes.len - start);
        std.mem.copyForwards(u8, buffer[0..count], entry.bytes[start .. start + count]);
        return count;
    }
};
