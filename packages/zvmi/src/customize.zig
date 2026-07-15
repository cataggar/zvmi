//! Versioned image-customization request, planning, preflight, execution, and
//! provenance API. The v1 executor intentionally covers the existing native
//! ISO+OCI fresh-image backend; later customization backends extend the typed
//! policies without changing v1 semantics.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const azure = @import("azure.zig");
const bootconfig = @import("bootconfig.zig");
const build_image = @import("build_image.zig");
const ext4 = @import("ext4.zig");
const fat32 = @import("fat32.zig");
const Format = @import("formats.zig").Format;
const gpt = @import("gpt.zig");
const guid = @import("guid.zig");
const image_mod = @import("image.zig");
const layout = @import("layout.zig");
const verity = @import("verity.zig");

pub const current_api_version: u32 = 1;
pub const plan_schema_version: u32 = 1;
pub const provenance_schema_version: u32 = 1;
const mib: u64 = 1024 * 1024;

pub const Architecture = bootconfig.Architecture;

pub const Seed = struct {
    bytes: [32]u8,

    pub fn jsonStringify(self: Seed, stringify: anytype) !void {
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        try stringify.write(&hex);
    }
};

pub const Digest = struct {
    bytes: [32]u8,

    pub fn jsonStringify(self: Digest, stringify: anytype) !void {
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        try stringify.write(&hex);
    }
};

pub const Guid = struct {
    bytes: guid.Guid,

    pub fn jsonStringify(self: Guid, stringify: anytype) !void {
        var buf: [36]u8 = undefined;
        try stringify.write(guid.formatLower(&buf, self.bytes));
    }
};

pub const Uuid = struct {
    bytes: [16]u8,

    pub fn jsonStringify(self: Uuid, stringify: anytype) !void {
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        try stringify.write(&hex);
    }
};

pub const IsoOciInput = struct {
    iso_path: []const u8,
    container_path: []const u8,
    rootfs_path_in_iso: ?[]const u8,
};

pub const DiskInput = struct {
    path: []const u8,
};

pub const Input = union(enum) {
    iso_oci: IsoOciInput,
    disk: DiskInput,
};

pub const OutputFormat = enum {
    raw,
    vhd,
    vhdx,
    qcow2,
    cosi,

    fn imageFormat(self: OutputFormat) ?Format {
        return switch (self) {
            .raw => .raw,
            .vhd => .vhd,
            .vhdx => .vhdx,
            .qcow2 => .qcow2,
            .cosi => null,
        };
    }
};

pub const Output = struct {
    path: []const u8,
    format: OutputFormat,
    size: u64,
};

pub const FreshStorage = struct {
    generation: azure.Generation = .gen2,
    esp_size: u64 = build_image.default_esp_size,
    ext4_label: []const u8 = "rootfs",
    skip_iso_rootfs: bool = false,
};

pub const StoragePolicy = union(enum) {
    fresh: FreshStorage,
    preserve: void,
};

pub const OsCustomization = struct {};

pub const UkiOptions = struct {
    stub_source_path: ?[]const u8 = null,
    os_release_source_path: ?[]const u8 = null,
    splash_source_path: ?[]const u8 = null,
    output_directory: []const u8 = "EFI/Linux",
};

pub const BootSecurityPolicy = struct {
    boot_mode: bootconfig.BootMode = .bls_only,
    verity: bool = false,
    extra_kernel_options: []const u8 = "",
    uki: UkiOptions = .{},
};

pub const GeneralizationPolicy = enum {
    none,
    azure,
};

pub const ExecutionBackend = enum {
    native,
    chroot,
    vm,
};

pub const ExecutionPolicy = struct {
    workspace_path: []const u8,
    backend: ExecutionBackend = .native,
    overwrite: bool = false,
};

pub const Reproducibility = struct {
    seed: Seed,
    source_date_epoch: u64,
};

pub const Request = struct {
    api_version: u32 = current_api_version,
    target_architecture: ?Architecture = null,
    input: Input,
    output: Output,
    storage: StoragePolicy,
    os: OsCustomization = .{},
    boot_security: BootSecurityPolicy = .{},
    generalization: GeneralizationPolicy = .none,
    execution: ExecutionPolicy,
    reproducibility: Reproducibility,
};

pub const Severity = enum {
    info,
    warning,
    @"error",
};

pub const DiagnosticPhase = enum {
    validation,
    resolution,
    preflight,
    execution,
    cleanup,
};

pub const DiagnosticCode = enum {
    unsupported_api_version,
    missing_target_architecture,
    missing_input_path,
    missing_rootfs_path,
    unsupported_input,
    invalid_output,
    invalid_storage,
    unsupported_storage,
    unsupported_output_format,
    incompatible_boot_policy,
    unsupported_generalization,
    unsupported_execution_backend,
    incompatible_architecture,
    invalid_workspace,
    path_conflict,
    invalid_reproducibility,
    invalid_plan,
    missing_capability,
    source_hash_failed,
    source_changed,
    execution_failed,
    commit_failed,
    cleanup_completed,
    cleanup_failed,
    runtime_warning,
};

pub const Cause = struct {
    error_name: []const u8,
};

pub const CommandDiagnostic = struct {
    argv: []const []const u8,
    exit_status: ?u8 = null,
};

pub const Diagnostic = struct {
    severity: Severity,
    phase: DiagnosticPhase,
    code: DiagnosticCode,
    configuration_path: []const u8,
    message: []const u8,
    cause: ?Cause = null,
    command: ?CommandDiagnostic = null,
    remediation: ?[]const u8 = null,
};

pub const DiagnosticSet = struct {
    items: []Diagnostic,
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *DiagnosticSet, allocator: Allocator) void {
        if (self.arena) |*arena| {
            arena.deinit();
        } else {
            allocator.free(self.items);
        }
        self.* = undefined;
    }

    pub fn hasErrors(self: DiagnosticSet) bool {
        for (self.items) |diagnostic| {
            if (diagnostic.severity == .@"error") return true;
        }
        return false;
    }
};

pub fn validate(allocator: Allocator, request: *const Request) Allocator.Error!DiagnosticSet {
    var diagnostics = std.array_list.Managed(Diagnostic).init(allocator);
    errdefer diagnostics.deinit();

    if (request.api_version != current_api_version) {
        try diagnostics.append(validationError(
            .unsupported_api_version,
            "/api_version",
            "the request API version is not supported",
            "set api_version to 1 or explicitly migrate the request",
        ));
    }
    if (request.target_architecture == null) {
        try diagnostics.append(validationError(
            .missing_target_architecture,
            "/target_architecture",
            "target architecture must be specified explicitly",
            "set target_architecture to x86_64 or aarch64",
        ));
    }

    switch (request.input) {
        .iso_oci => |input| {
            if (input.iso_path.len == 0) {
                try diagnostics.append(validationError(.missing_input_path, "/input/iso_oci/iso_path", "ISO path must not be empty", null));
            }
            if (input.container_path.len == 0) {
                try diagnostics.append(validationError(.missing_input_path, "/input/iso_oci/container_path", "container path must not be empty", null));
            }
            if (input.rootfs_path_in_iso == null or input.rootfs_path_in_iso.?.len == 0) {
                try diagnostics.append(validationError(
                    .missing_rootfs_path,
                    "/input/iso_oci/rootfs_path_in_iso",
                    "rootfs_path_in_iso is required so the resolved plan contains no input-dependent path inference",
                    "set the exact SquashFS rootfs path from the ISO",
                ));
            }
        },
        .disk => try diagnostics.append(validationError(
            .unsupported_input,
            "/input/disk",
            "preserved disk inputs require the later existing-image backend",
            "use an ISO+OCI input for v1 or wait for the preserved-image backend",
        )),
    }

    if (request.output.path.len == 0) {
        try diagnostics.append(validationError(.invalid_output, "/output/path", "output path must not be empty", null));
    }
    if (request.output.size % 512 != 0) {
        try diagnostics.append(validationError(.invalid_output, "/output/size", "output size must be a multiple of 512 bytes", null));
    }
    if (request.output.size > std.math.maxInt(u64) - mib) {
        try diagnostics.append(validationError(.invalid_output, "/output/size", "output size is too large to align safely", null));
    }
    if (request.output.format == .cosi) {
        try diagnostics.append(validationError(
            .unsupported_output_format,
            "/output/format",
            "COSI is modeled but is not yet supported by the v1 ISO+OCI executor",
            "select raw, vhd, vhdx, or qcow2",
        ));
    }

    switch (request.storage) {
        .fresh => |storage| {
            const minimum_size = switch (storage.generation) {
                .gen1 => 2 * mib,
                .gen2 => if (storage.esp_size > std.math.maxInt(u64) - 2 * mib)
                    std.math.maxInt(u64)
                else
                    storage.esp_size + 2 * mib,
            };
            if (storage.generation == .gen2 and storage.esp_size > std.math.maxInt(u64) - 2 * mib) {
                try diagnostics.append(validationError(.invalid_storage, "/storage/fresh/esp_size", "ESP size is too large to plan safely", null));
            }
            if (request.output.size <= minimum_size) {
                try diagnostics.append(validationError(.invalid_storage, "/output/size", "output is too small for the selected partition layout", null));
            }
            if (storage.ext4_label.len > 16) {
                try diagnostics.append(validationError(.invalid_storage, "/storage/fresh/ext4_label", "ext4 label must be at most 16 bytes", null));
            }
            if (storage.generation == .gen1 and request.boot_security.boot_mode != .bls_only) {
                try diagnostics.append(validationError(
                    .incompatible_boot_policy,
                    "/boot_security/boot_mode",
                    "UKI modes require a Gen2 EFI System Partition",
                    "use bls_only for Gen1 or select Gen2 storage",
                ));
            }
            if (storage.generation == .gen1 and request.boot_security.verity) {
                try diagnostics.append(validationError(
                    .incompatible_boot_policy,
                    "/boot_security/verity",
                    "Gen1 verity cannot generate a final-hash-aware BIOS GRUB configuration",
                    "disable verity or select Gen2 storage",
                ));
            }
            if (storage.generation == .gen1 and request.target_architecture != null and request.target_architecture.? != .x86_64) {
                try diagnostics.append(validationError(
                    .incompatible_boot_policy,
                    "/target_architecture",
                    "the native Gen1 BIOS backend only supports x86_64 images",
                    "select x86_64 or use Gen2 storage for aarch64",
                ));
            }
            if (request.output.size % 512 == 0 and
                request.output.size <= std.math.maxInt(u64) - mib and
                (storage.generation == .gen1 or storage.esp_size <= std.math.maxInt(u64) - 2 * mib))
            {
                if (validateStorageGeometry(
                    if (request.output.format == .vhd) azure.alignSizeToMib(request.output.size) else request.output.size,
                    storage,
                    request.boot_security.verity,
                )) |diagnostic| {
                    try diagnostics.append(diagnostic);
                }
            }
        },
        .preserve => try diagnostics.append(validationError(
            .unsupported_storage,
            "/storage/preserve",
            "preserved storage requires the later existing-image mutation backend",
            "use fresh storage for v1",
        )),
    }

    if (request.generalization != .none) {
        try diagnostics.append(validationError(
            .unsupported_generalization,
            "/generalization",
            "generalization is modeled but not implemented by the v1 executor",
            "set generalization to none",
        ));
    }
    if (request.execution.backend != .native) {
        try diagnostics.append(validationError(
            .unsupported_execution_backend,
            "/execution/backend",
            "only the unprivileged native backend is implemented in v1",
            "set execution.backend to native",
        ));
    }
    if (request.execution.workspace_path.len == 0) {
        try diagnostics.append(validationError(.invalid_workspace, "/execution/workspace_path", "workspace path must not be empty", null));
    }
    if (request.output.path.len != 0 and
        request.execution.workspace_path.len != 0 and
        std.fs.path.isAbsolute(request.output.path) == std.fs.path.isAbsolute(request.execution.workspace_path))
    {
        const output_path = try std.fs.path.resolve(allocator, &.{request.output.path});
        defer allocator.free(output_path);
        const workspace_path = try std.fs.path.resolve(allocator, &.{request.execution.workspace_path});
        defer allocator.free(workspace_path);
        const output_parent = std.fs.path.dirname(output_path) orelse ".";
        if (!std.mem.eql(u8, workspace_path, output_parent)) {
            try diagnostics.append(validationError(
                .path_conflict,
                "/execution/workspace_path",
                "the v1 native workspace must be the output directory so publication is atomic",
                "set workspace_path to the parent directory of output.path",
            ));
        }
    }
    if (request.input == .iso_oci and request.output.path.len != 0) {
        const input = request.input.iso_oci;
        const output_path = try std.fs.path.resolve(allocator, &.{request.output.path});
        defer allocator.free(output_path);
        const iso_path = if (input.iso_path.len != 0) try std.fs.path.resolve(allocator, &.{input.iso_path}) else null;
        defer if (iso_path) |path| allocator.free(path);
        const container_path = if (input.container_path.len != 0) try std.fs.path.resolve(allocator, &.{input.container_path}) else null;
        defer if (container_path) |path| allocator.free(path);
        if ((iso_path != null and
            std.fs.path.isAbsolute(request.output.path) == std.fs.path.isAbsolute(input.iso_path) and
            std.mem.eql(u8, output_path, iso_path.?)) or
            (container_path != null and
                std.fs.path.isAbsolute(request.output.path) == std.fs.path.isAbsolute(input.container_path) and
                (std.mem.eql(u8, output_path, container_path.?) or pathContains(container_path.?, output_path))))
        {
            try diagnostics.append(validationError(
                .path_conflict,
                "/output/path",
                "output path must not alias or be contained by a source path",
                "choose an output directory outside the ISO and container inputs",
            ));
        }
    }
    if (request.reproducibility.source_date_epoch > std.math.maxInt(u32)) {
        try diagnostics.append(validationError(
            .invalid_reproducibility,
            "/reproducibility/source_date_epoch",
            "source_date_epoch exceeds the ext4 timestamp range",
            "use a value no greater than 4294967295",
        ));
    }

    return .{ .items = try diagnostics.toOwnedSlice() };
}

fn pathContains(parent: []const u8, child: []const u8) bool {
    return child.len > parent.len and
        std.mem.startsWith(u8, child, parent) and
        (std.fs.path.isSep(parent[parent.len - 1]) or std.fs.path.isSep(child[parent.len]));
}

fn validateStorageGeometry(
    disk_size: u64,
    storage: FreshStorage,
    verity_enabled: bool,
) ?Diagnostic {
    var root_length: u64 = undefined;
    switch (storage.generation) {
        .gen2 => {
            const first_usable_lba: u64 = 2 + gpt.partition_array_sectors;
            const backup_reserved_sectors: u64 = 1 + gpt.partition_array_sectors;
            const total_sectors = disk_size / gpt.sector_size;
            if (total_sectors <= first_usable_lba + backup_reserved_sectors) return storageGeometryError(
                "/output/size",
                "the requested Gen2 disk is too small for GPT metadata",
                error.DiskTooSmall,
                "increase output.size",
            );
            const first_partition_offset = azure.alignSizeToMib(first_usable_lba * gpt.sector_size);
            const usable_end_offset = disk_size - backup_reserved_sectors * gpt.sector_size;
            if (first_partition_offset >= usable_end_offset) return storageGeometryError(
                "/output/size",
                "the requested Gen2 disk has no aligned partition space",
                error.DiskTooSmall,
                "increase output.size",
            );
            const usable_aligned_bytes = (usable_end_offset - first_partition_offset) / mib * mib;
            const esp_length = azure.alignSizeToMib(storage.esp_size);
            if (esp_length >= usable_aligned_bytes) return storageGeometryError(
                "/storage/fresh/esp_size",
                "the requested ESP leaves no aligned root partition",
                error.OverAllocated,
                "increase the disk or reduce the ESP size",
            );

            fat32.validateFormatOptions(.{
                .partition_offset = first_partition_offset,
                .partition_len = esp_length,
            }) catch |err| return storageGeometryError(
                "/storage/fresh/esp_size",
                "the requested ESP cannot be formatted as FAT32",
                err,
                "use an ESP size supported by the native FAT32 backend",
            );
            root_length = usable_aligned_bytes - esp_length;
        },
        .gen1 => {
            const root_offset = mib;
            if (disk_size <= root_offset + mib) return storageGeometryError(
                "/output/size",
                "the requested Gen1 disk is too small for its BIOS boot gap and root partition",
                error.DiskTooSmall,
                "increase output.size",
            );
            root_length = (disk_size - root_offset) / mib * mib;
            if (root_length / gpt.sector_size > std.math.maxInt(u32)) return storageGeometryError(
                "/output/size",
                "the requested Gen1 root partition exceeds the MBR sector-count limit",
                error.PartitionTooLargeForMbr,
                "use a disk no larger than the MBR backend supports or select Gen2",
            );
        },
    }

    const max_ext4_length = @as(u64, std.math.maxInt(u32)) * ext4.default_block_size;
    if (verity_enabled) {
        const max_hash_tree_length = verity.hashTreeSizeBytes(
            max_ext4_length,
            ext4.default_block_size,
            ext4.default_block_size,
        ) catch unreachable;
        if (root_length > max_ext4_length + max_hash_tree_length) return storageGeometryError(
            "/output/size",
            "the requested verity data partition exceeds the native ext4 geometry limits",
            error.FilesystemTooLarge,
            "reduce output.size or select a backend that supports larger filesystems",
        );
        const verity_layout = verity.splitPartition(root_length, ext4.default_block_size, ext4.default_block_size) catch |err|
            return storageGeometryError(
                "/boot_security/verity",
                "the root partition is too small or misaligned for dm-verity",
                err,
                "increase output.size or disable verity",
            );
        root_length = verity_layout.data_size;
    }
    if (root_length == 0 or
        root_length % ext4.default_block_size != 0 or
        root_length > max_ext4_length)
    {
        return storageGeometryError(
            "/output/size",
            "the requested root partition exceeds the native ext4 geometry limits",
            error.FilesystemTooLarge,
            "reduce output.size or select a backend that supports larger filesystems",
        );
    }
    return null;
}

fn storageGeometryError(
    path: []const u8,
    message: []const u8,
    cause: anyerror,
    remediation: []const u8,
) Diagnostic {
    return .{
        .severity = .@"error",
        .phase = .validation,
        .code = .invalid_storage,
        .configuration_path = path,
        .message = message,
        .cause = .{ .error_name = @errorName(cause) },
        .remediation = remediation,
    };
}

fn validationError(
    code: DiagnosticCode,
    path: []const u8,
    message: []const u8,
    remediation: ?[]const u8,
) Diagnostic {
    return .{
        .severity = .@"error",
        .phase = .validation,
        .code = code,
        .configuration_path = path,
        .message = message,
        .remediation = remediation,
    };
}

pub const ResolveContext = struct {
    host_architecture: Architecture,
    base_path: []const u8 = ".",
    firmware_architecture: ?Architecture = null,
    repository_architecture: ?Architecture = null,
    runner_architecture: ?Architecture = null,
};

pub const ArchitectureSet = struct {
    host: Architecture,
    image: Architecture,
    firmware: Architecture,
    repository: Architecture,
    runner: Architecture,
};

pub const Phase = enum {
    prepare,
    filesystem_changes,
    generalization_cleanup,
    initramfs,
    bootloader_prepare,
    filesystem_finalize,
    verity_seal,
    bootloader_install,
    uki,
    filesystem_close,
    output_conversion,
};

pub const Action = build_image.Stage;

pub const Operation = struct {
    id: u16,
    phase: Phase,
    depends_on: []const u16,
    action: Action,
};

pub const CapabilityKind = enum {
    read_iso,
    read_container,
    write_workspace_parent,
    write_output_parent,
    output_absent,
    transaction_absent,
    path_isolation,
    unprivileged_native_backend,
    atomic_commit,
};

pub const CapabilityRequirement = struct {
    kind: CapabilityKind,
    path: []const u8,
    related_path: []const u8 = "",
    reason: []const u8,
};

pub const GeneratedIdentifiers = struct {
    disk_guid: Guid,
    esp_partition_guid: Guid,
    root_partition_guid: Guid,
    root_filesystem_uuid: Uuid,
    mbr_disk_signature: u32,
    verity_salt: Digest,
    output_unique_id: Uuid,
    vhdx_header_sequence_base: u64,
    vhdx_file_write_guid: Guid,
    vhdx_data_write_guid: Guid,
    vhdx_page83_guid: Guid,
    vhdx_write_guid_seed: Seed,
    transaction_id: Uuid,
};

pub const ResolvedInput = struct {
    iso_path: []const u8,
    container_path: []const u8,
    rootfs_path_in_iso: []const u8,
};

pub const ResolvedOutput = struct {
    path: []const u8,
    format: OutputFormat,
    requested_size: u64,
    disk_size: u64,
};

pub const ResolvedStorage = struct {
    generation: azure.Generation,
    esp_size: u64,
    ext4_label: []const u8,
    skip_iso_rootfs: bool,
};

pub const ResolvedPlanData = struct {
    schema_version: u32 = plan_schema_version,
    request_api_version: u32,
    architectures: ArchitectureSet,
    input: ResolvedInput,
    output: ResolvedOutput,
    storage: ResolvedStorage,
    os: OsCustomization,
    boot_security: BootSecurityPolicy,
    generalization: GeneralizationPolicy,
    execution: ExecutionPolicy,
    reproducibility: Reproducibility,
    transaction_path: []const u8,
    staging_output_path: []const u8,
    generated: GeneratedIdentifiers,
    operations: []const Operation,
    required_capabilities: []const CapabilityRequirement,
    plan_hash: Digest,
};

pub const ResolvedPlan = struct {
    arena: std.heap.ArenaAllocator,
    data: *const ResolvedPlanData,

    pub fn deinit(self: *ResolvedPlan) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn view(self: *const ResolvedPlan) *const ResolvedPlanData {
        return self.data;
    }
};

pub const ResolveOutcome = struct {
    diagnostics: DiagnosticSet,
    plan: ?ResolvedPlan,

    pub fn deinit(self: *ResolveOutcome, allocator: Allocator) void {
        self.diagnostics.deinit(allocator);
        if (self.plan) |*plan| plan.deinit();
        self.* = undefined;
    }
};

pub fn resolve(
    allocator: Allocator,
    request: *const Request,
    context: ResolveContext,
) Allocator.Error!ResolveOutcome {
    const diagnostics = try validate(allocator, request);
    if (diagnostics.hasErrors()) return .{ .diagnostics = diagnostics, .plan = null };

    const target_architecture = request.target_architecture.?;
    var resolution_diagnostics = std.array_list.Managed(Diagnostic).init(allocator);
    defer resolution_diagnostics.deinit();
    if (context.firmware_architecture) |architecture| {
        if (architecture != target_architecture) {
            try resolution_diagnostics.append(.{
                .severity = .@"error",
                .phase = .resolution,
                .code = .incompatible_architecture,
                .configuration_path = "/architectures/firmware",
                .message = "the v1 native backend uses image-architecture firmware assets",
                .remediation = "set firmware_architecture to the target image architecture",
            });
        }
    }
    if (context.repository_architecture) |architecture| {
        if (architecture != target_architecture) {
            try resolution_diagnostics.append(.{
                .severity = .@"error",
                .phase = .resolution,
                .code = .incompatible_architecture,
                .configuration_path = "/architectures/repository",
                .message = "the v1 ISO+OCI backend requires target-architecture source content",
                .remediation = "set repository_architecture to the target image architecture",
            });
        }
    }
    if (context.runner_architecture) |architecture| {
        if (architecture != context.host_architecture) {
            try resolution_diagnostics.append(.{
                .severity = .@"error",
                .phase = .resolution,
                .code = .incompatible_architecture,
                .configuration_path = "/architectures/runner",
                .message = "the v1 native backend executes on the host architecture",
                .remediation = "set runner_architecture to the host architecture",
            });
        }
    }

    const input = request.input.iso_oci;
    const checked_iso_path = try std.fs.path.resolve(allocator, &.{ context.base_path, input.iso_path });
    defer allocator.free(checked_iso_path);
    const checked_container_path = try std.fs.path.resolve(allocator, &.{ context.base_path, input.container_path });
    defer allocator.free(checked_container_path);
    const checked_output_path = try std.fs.path.resolve(allocator, &.{ context.base_path, request.output.path });
    defer allocator.free(checked_output_path);
    const checked_workspace_path = try std.fs.path.resolve(allocator, &.{ context.base_path, request.execution.workspace_path });
    defer allocator.free(checked_workspace_path);

    const checked_output_parent = std.fs.path.dirname(checked_output_path) orelse ".";
    if (!std.mem.eql(u8, checked_workspace_path, checked_output_parent)) {
        try resolution_diagnostics.append(.{
            .severity = .@"error",
            .phase = .resolution,
            .code = .path_conflict,
            .configuration_path = "/execution/workspace_path",
            .message = "the resolved v1 native workspace must be the output directory so publication is atomic",
            .remediation = "resolve workspace_path to the parent directory of output.path",
        });
    }
    if (std.mem.eql(u8, checked_output_path, checked_iso_path) or
        std.mem.eql(u8, checked_output_path, checked_container_path) or
        pathContains(checked_container_path, checked_output_path))
    {
        try resolution_diagnostics.append(.{
            .severity = .@"error",
            .phase = .resolution,
            .code = .path_conflict,
            .configuration_path = "/output/path",
            .message = "the resolved output path must not alias or be contained by a source path",
            .remediation = "resolve the output to a directory outside the ISO and container inputs",
        });
    }
    if (resolution_diagnostics.items.len != 0) {
        allocator.free(diagnostics.items);
        return .{
            .diagnostics = .{ .items = try resolution_diagnostics.toOwnedSlice() },
            .plan = null,
        };
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const plan_allocator = arena.allocator();

    const storage = request.storage.fresh;
    const disk_size = if (request.output.format == .vhd)
        azure.alignSizeToMib(request.output.size)
    else
        request.output.size;

    const resolved_iso_path = try std.fs.path.resolve(plan_allocator, &.{ context.base_path, input.iso_path });
    const resolved_container_path = try std.fs.path.resolve(plan_allocator, &.{ context.base_path, input.container_path });
    const resolved_output_path = try std.fs.path.resolve(plan_allocator, &.{ context.base_path, request.output.path });
    const resolved_workspace_path = try std.fs.path.resolve(plan_allocator, &.{ context.base_path, request.execution.workspace_path });

    var generated = deriveIdentifiers(request.reproducibility.seed);
    generated.transaction_id = deriveTransactionId(request.reproducibility.seed, resolved_output_path);
    const transaction_hex = std.fmt.bytesToHex(generated.transaction_id.bytes, .lower);
    const transaction_name = try std.fmt.allocPrint(plan_allocator, ".zvmi-{s}", .{transaction_hex});
    const transaction_path = try std.fs.path.join(plan_allocator, &.{ resolved_workspace_path, transaction_name });
    const staging_output_path = try std.fs.path.join(plan_allocator, &.{ transaction_path, "output.img" });

    const resolved_execution = ExecutionPolicy{
        .workspace_path = resolved_workspace_path,
        .backend = request.execution.backend,
        .overwrite = request.execution.overwrite,
    };
    const resolved_input = ResolvedInput{
        .iso_path = resolved_iso_path,
        .container_path = resolved_container_path,
        .rootfs_path_in_iso = try plan_allocator.dupe(u8, input.rootfs_path_in_iso.?),
    };
    const resolved_output = ResolvedOutput{
        .path = resolved_output_path,
        .format = request.output.format,
        .requested_size = request.output.size,
        .disk_size = disk_size,
    };
    const resolved_storage = ResolvedStorage{
        .generation = storage.generation,
        .esp_size = storage.esp_size,
        .ext4_label = try plan_allocator.dupe(u8, storage.ext4_label),
        .skip_iso_rootfs = storage.skip_iso_rootfs,
    };
    const resolved_boot = try dupeBootPolicy(plan_allocator, request.boot_security);
    const operations = try buildOperations(plan_allocator, resolved_boot, resolved_storage.generation);
    const capabilities = try buildCapabilities(
        plan_allocator,
        resolved_input,
        resolved_output,
        resolved_execution,
        transaction_path,
    );

    var data = ResolvedPlanData{
        .request_api_version = request.api_version,
        .architectures = .{
            .host = context.host_architecture,
            .image = target_architecture,
            .firmware = context.firmware_architecture orelse target_architecture,
            .repository = context.repository_architecture orelse target_architecture,
            .runner = context.runner_architecture orelse context.host_architecture,
        },
        .input = resolved_input,
        .output = resolved_output,
        .storage = resolved_storage,
        .os = request.os,
        .boot_security = resolved_boot,
        .generalization = request.generalization,
        .execution = resolved_execution,
        .reproducibility = request.reproducibility,
        .transaction_path = transaction_path,
        .staging_output_path = staging_output_path,
        .generated = generated,
        .operations = operations,
        .required_capabilities = capabilities,
        .plan_hash = .{ .bytes = [_]u8{0} ** 32 },
    };
    data.plan_hash = hashPlan(data);

    const data_ptr = try plan_allocator.create(ResolvedPlanData);
    data_ptr.* = data;

    return .{
        .diagnostics = diagnostics,
        .plan = .{ .arena = arena, .data = data_ptr },
    };
}

fn dupeBootPolicy(allocator: Allocator, policy: BootSecurityPolicy) Allocator.Error!BootSecurityPolicy {
    return .{
        .boot_mode = policy.boot_mode,
        .verity = policy.verity,
        .extra_kernel_options = try allocator.dupe(u8, policy.extra_kernel_options),
        .uki = .{
            .stub_source_path = if (policy.uki.stub_source_path) |path| try allocator.dupe(u8, path) else null,
            .os_release_source_path = if (policy.uki.os_release_source_path) |path| try allocator.dupe(u8, path) else null,
            .splash_source_path = if (policy.uki.splash_source_path) |path| try allocator.dupe(u8, path) else null,
            .output_directory = try allocator.dupe(u8, policy.uki.output_directory),
        },
    };
}

fn buildOperations(
    allocator: Allocator,
    policy: BootSecurityPolicy,
    generation: azure.Generation,
) Allocator.Error![]Operation {
    var specs_buffer: [12]OperationSpec = undefined;
    const specs = nativeOperationSpecs(policy, generation, &specs_buffer);
    const operations = try allocator.alloc(Operation, specs.len);
    for (specs, 0..) |spec, index| {
        const dependencies = if (index == 0) &.{} else blk: {
            const ids = try allocator.alloc(u16, 1);
            ids[0] = @intCast(index - 1);
            break :blk ids;
        };
        operations[index] = .{
            .id = @intCast(index),
            .phase = spec.phase,
            .depends_on = dependencies,
            .action = spec.action,
        };
    }
    return operations;
}

const OperationSpec = struct {
    phase: Phase,
    action: Action,
};

fn nativeOperationSpecs(
    policy: BootSecurityPolicy,
    generation: azure.Generation,
    buffer: *[12]OperationSpec,
) []const OperationSpec {
    var len: usize = 0;
    appendOperationSpec(buffer, &len, .prepare, .load_sources);
    appendOperationSpec(buffer, &len, .filesystem_changes, .apply_filesystem_changes);
    appendOperationSpec(buffer, &len, .generalization_cleanup, .generalize_and_cleanup);
    appendOperationSpec(buffer, &len, .initramfs, .prepare_initramfs);
    if (generation == .gen1) appendOperationSpec(buffer, &len, .bootloader_prepare, .prepare_boot_configuration);
    appendOperationSpec(buffer, &len, .filesystem_finalize, .populate_filesystem);
    if (policy.verity) appendOperationSpec(buffer, &len, .verity_seal, .seal_verity);
    if (generation == .gen2) appendOperationSpec(buffer, &len, .bootloader_prepare, .prepare_boot_configuration);
    appendOperationSpec(buffer, &len, .bootloader_install, .install_bootloader);
    if (policy.boot_mode != .bls_only) appendOperationSpec(buffer, &len, .uki, .generate_uki);
    appendOperationSpec(buffer, &len, .filesystem_close, .check_and_close_filesystems);
    appendOperationSpec(buffer, &len, .output_conversion, .convert_output);
    return buffer[0..len];
}

fn appendOperationSpec(buffer: *[12]OperationSpec, len: *usize, phase: Phase, action: Action) void {
    buffer[len.*] = .{ .phase = phase, .action = action };
    len.* += 1;
}

fn hasExpectedNativeOperations(plan: *const ResolvedPlan) bool {
    var specs_buffer: [12]OperationSpec = undefined;
    const specs = nativeOperationSpecs(plan.data.boot_security, plan.data.storage.generation, &specs_buffer);
    if (plan.data.operations.len != specs.len) return false;
    for (plan.data.operations, specs, 0..) |operation, spec, index| {
        if (operation.id != index or operation.phase != spec.phase or operation.action != spec.action) return false;
        if (index == 0) {
            if (operation.depends_on.len != 0) return false;
        } else if (operation.depends_on.len != 1 or operation.depends_on[0] != index - 1) {
            return false;
        }
    }
    return true;
}

fn buildCapabilities(
    allocator: Allocator,
    input: ResolvedInput,
    output: ResolvedOutput,
    execution: ExecutionPolicy,
    transaction_path: []const u8,
) Allocator.Error![]CapabilityRequirement {
    var capabilities = std.array_list.Managed(CapabilityRequirement).init(allocator);
    defer capabilities.deinit();

    try capabilities.append(.{ .kind = .read_iso, .path = input.iso_path, .reason = "read the source ISO" });
    try capabilities.append(.{ .kind = .read_container, .path = input.container_path, .reason = "read the source OCI layout or archive" });
    try capabilities.append(.{
        .kind = .path_isolation,
        .path = output.path,
        .related_path = input.iso_path,
        .reason = "keep the output distinct from the source ISO",
    });
    try capabilities.append(.{
        .kind = .path_isolation,
        .path = output.path,
        .related_path = input.container_path,
        .reason = "keep the output outside the source container",
    });
    try capabilities.append(.{
        .kind = .write_workspace_parent,
        .path = execution.workspace_path,
        .reason = "create the explicit transaction workspace",
    });
    try capabilities.append(.{
        .kind = .write_output_parent,
        .path = std.fs.path.dirname(output.path) orelse ".",
        .reason = "atomically commit the completed image",
    });
    if (!execution.overwrite) {
        try capabilities.append(.{ .kind = .output_absent, .path = output.path, .reason = "preserve an existing output" });
    }
    try capabilities.append(.{ .kind = .transaction_absent, .path = transaction_path, .reason = "avoid colliding with another or stale transaction" });
    try capabilities.append(.{ .kind = .unprivileged_native_backend, .path = "", .reason = "execute the selected rootless native backend" });
    try capabilities.append(.{ .kind = .atomic_commit, .path = output.path, .reason = "publish output only after successful completion" });
    return try capabilities.toOwnedSlice();
}

fn deriveIdentifiers(seed: Seed) GeneratedIdentifiers {
    return .{
        .disk_guid = .{ .bytes = deriveGuid(seed, "disk-guid") },
        .esp_partition_guid = .{ .bytes = deriveGuid(seed, "esp-partition-guid") },
        .root_partition_guid = .{ .bytes = deriveGuid(seed, "root-partition-guid") },
        .root_filesystem_uuid = .{ .bytes = deriveUuid(seed, "root-filesystem-uuid") },
        .mbr_disk_signature = deriveNonzeroU32(seed, "mbr-disk-signature"),
        .verity_salt = .{ .bytes = derive(seed, "verity-salt", 0) },
        .output_unique_id = .{ .bytes = deriveUuid(seed, "output-unique-id") },
        .vhdx_header_sequence_base = deriveHeaderSequenceBase(seed),
        .vhdx_file_write_guid = .{ .bytes = deriveGuid(seed, "vhdx-file-write-guid") },
        .vhdx_data_write_guid = .{ .bytes = deriveGuid(seed, "vhdx-data-write-guid") },
        .vhdx_page83_guid = .{ .bytes = deriveGuid(seed, "vhdx-page83-guid") },
        .vhdx_write_guid_seed = .{ .bytes = derive(seed, "vhdx-write-guid-seed", 0) },
        .transaction_id = .{ .bytes = deriveUuid(seed, "transaction-id") },
    };
}

fn deriveTransactionId(seed: Seed, output_path: []const u8) Uuid {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zvmi-transaction-id-v1\x00");
    hashString(&hash, output_path);
    hash.update(&seed.bytes);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var value: [16]u8 = digest[0..16].*;
    value[6] = (value[6] & 0x0F) | 0x40;
    value[8] = (value[8] & 0x3F) | 0x80;
    return .{ .bytes = value };
}

fn derive(seed: Seed, label: []const u8, index: u64) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zvmi-plan-derive-v1\x00");
    var label_len: [4]u8 = undefined;
    std.mem.writeInt(u32, &label_len, @intCast(label.len), .big);
    hash.update(&label_len);
    hash.update(label);
    var index_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &index_bytes, index, .big);
    hash.update(&index_bytes);
    hash.update(&seed.bytes);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn deriveGuid(seed: Seed, label: []const u8) guid.Guid {
    const digest = derive(seed, label, 0);
    var value: guid.Guid = digest[0..16].*;
    value[7] = (value[7] & 0x0F) | 0x40;
    value[8] = (value[8] & 0x3F) | 0x80;
    return value;
}

fn deriveUuid(seed: Seed, label: []const u8) [16]u8 {
    const digest = derive(seed, label, 0);
    var value: [16]u8 = digest[0..16].*;
    value[6] = (value[6] & 0x0F) | 0x40;
    value[8] = (value[8] & 0x3F) | 0x80;
    return value;
}

fn deriveU64(seed: Seed, label: []const u8) u64 {
    const digest = derive(seed, label, 0);
    return std.mem.readInt(u64, digest[0..8], .big);
}

fn deriveHeaderSequenceBase(seed: Seed) u64 {
    return @min(deriveU64(seed, "vhdx-header-sequence"), std.math.maxInt(u64) - 3);
}

fn deriveNonzeroU32(seed: Seed, label: []const u8) u32 {
    const digest = derive(seed, label, 0);
    const value = std.mem.readInt(u32, digest[0..4], .big);
    return if (value == 0) 1 else value;
}

fn hashPlan(plan: ResolvedPlanData) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zvmi-resolved-plan-v1\x00");
    hashInt(&hash, plan.schema_version);
    hashInt(&hash, plan.request_api_version);
    hashInt(&hash, @intFromEnum(plan.architectures.host));
    hashInt(&hash, @intFromEnum(plan.architectures.image));
    hashInt(&hash, @intFromEnum(plan.architectures.firmware));
    hashInt(&hash, @intFromEnum(plan.architectures.repository));
    hashInt(&hash, @intFromEnum(plan.architectures.runner));
    hashString(&hash, plan.input.iso_path);
    hashString(&hash, plan.input.container_path);
    hashString(&hash, plan.input.rootfs_path_in_iso);
    hashString(&hash, plan.output.path);
    hashInt(&hash, @intFromEnum(plan.output.format));
    hashInt(&hash, plan.output.requested_size);
    hashInt(&hash, plan.output.disk_size);
    hashInt(&hash, @intFromEnum(plan.storage.generation));
    hashInt(&hash, plan.storage.esp_size);
    hashString(&hash, plan.storage.ext4_label);
    hashBool(&hash, plan.storage.skip_iso_rootfs);
    hashInt(&hash, @intFromEnum(plan.boot_security.boot_mode));
    hashBool(&hash, plan.boot_security.verity);
    hashString(&hash, plan.boot_security.extra_kernel_options);
    hashOptionalString(&hash, plan.boot_security.uki.stub_source_path);
    hashOptionalString(&hash, plan.boot_security.uki.os_release_source_path);
    hashOptionalString(&hash, plan.boot_security.uki.splash_source_path);
    hashString(&hash, plan.boot_security.uki.output_directory);
    hashInt(&hash, @intFromEnum(plan.generalization));
    hashString(&hash, plan.execution.workspace_path);
    hashInt(&hash, @intFromEnum(plan.execution.backend));
    hashBool(&hash, plan.execution.overwrite);
    hash.update(&plan.reproducibility.seed.bytes);
    hashInt(&hash, plan.reproducibility.source_date_epoch);
    hashString(&hash, plan.transaction_path);
    hashString(&hash, plan.staging_output_path);
    hash.update(&plan.generated.disk_guid.bytes);
    hash.update(&plan.generated.esp_partition_guid.bytes);
    hash.update(&plan.generated.root_partition_guid.bytes);
    hash.update(&plan.generated.root_filesystem_uuid.bytes);
    hashInt(&hash, plan.generated.mbr_disk_signature);
    hash.update(&plan.generated.verity_salt.bytes);
    hash.update(&plan.generated.output_unique_id.bytes);
    hashInt(&hash, plan.generated.vhdx_header_sequence_base);
    hash.update(&plan.generated.vhdx_file_write_guid.bytes);
    hash.update(&plan.generated.vhdx_data_write_guid.bytes);
    hash.update(&plan.generated.vhdx_page83_guid.bytes);
    hash.update(&plan.generated.vhdx_write_guid_seed.bytes);
    hash.update(&plan.generated.transaction_id.bytes);
    for (plan.operations) |operation| {
        hashInt(&hash, operation.id);
        hashInt(&hash, @intFromEnum(operation.phase));
        hashInt(&hash, @intFromEnum(operation.action));
        for (operation.depends_on) |dependency| hashInt(&hash, dependency);
    }
    for (plan.required_capabilities) |capability| {
        hashInt(&hash, @intFromEnum(capability.kind));
        hashString(&hash, capability.path);
        hashString(&hash, capability.related_path);
        hashString(&hash, capability.reason);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .{ .bytes = digest };
}

fn hashInt(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .big);
    hash.update(&bytes);
}

fn hashBool(hash: *std.crypto.hash.sha2.Sha256, value: bool) void {
    hash.update(if (value) &.{1} else &.{0});
}

fn hashString(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hashInt(hash, @as(u64, value.len));
    hash.update(value);
}

fn hashOptionalString(hash: *std.crypto.hash.sha2.Sha256, value: ?[]const u8) void {
    if (value) |present| {
        hash.update(&.{1});
        hashString(hash, present);
    } else {
        hash.update(&.{0});
    }
}

pub const CapabilityState = enum {
    available,
    missing,
    unsupported,
};

pub const CapabilityCheck = struct {
    requirement: CapabilityRequirement,
    state: CapabilityState,
};

pub const Platform = struct {
    context: ?*anyopaque = null,
    checkFn: *const fn (context: ?*anyopaque, io: Io, requirement: CapabilityRequirement) CapabilityState,
    runFn: ?*const fn (
        context: ?*anyopaque,
        allocator: Allocator,
        io: Io,
        plan: *const ResolvedPlan,
        event_sink: ?EventSink,
        stage_sink: build_image.StageSink,
    ) anyerror!void = null,

    pub fn system() Platform {
        return .{ .checkFn = systemCapabilityCheck };
    }

    fn check(self: Platform, io: Io, requirement: CapabilityRequirement) CapabilityState {
        return self.checkFn(self.context, io, requirement);
    }
};

pub const PreflightReport = struct {
    arena: std.heap.ArenaAllocator,
    capabilities: []CapabilityCheck,
    diagnostics: DiagnosticSet,

    pub fn deinit(self: *PreflightReport, _: Allocator) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn ready(self: PreflightReport) bool {
        return !self.diagnostics.hasErrors();
    }
};

pub fn preflight(
    allocator: Allocator,
    io: Io,
    plan: *const ResolvedPlan,
    platform: Platform,
) Allocator.Error!PreflightReport {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const report_allocator = arena.allocator();
    const requirements = plan.data.required_capabilities;
    const checks = try report_allocator.alloc(CapabilityCheck, requirements.len);
    const diagnostic_buffer = try report_allocator.alloc(Diagnostic, requirements.len + 1);
    var diagnostic_count: usize = 0;

    if (!try hasValidPlanIntegrity(report_allocator, plan)) {
        diagnostic_buffer[diagnostic_count] = .{
            .severity = .@"error",
            .phase = .preflight,
            .code = .invalid_plan,
            .configuration_path = "/",
            .message = "the resolved plan failed its integrity or backend invariant checks",
            .remediation = "preflight the immutable plan returned by resolve without modification",
        };
        diagnostic_count += 1;
    }

    for (requirements, 0..) |requirement, index| {
        const state = platform.check(io, requirement);
        const owned_requirement = CapabilityRequirement{
            .kind = requirement.kind,
            .path = try report_allocator.dupe(u8, requirement.path),
            .related_path = try report_allocator.dupe(u8, requirement.related_path),
            .reason = try report_allocator.dupe(u8, requirement.reason),
        };
        checks[index] = .{ .requirement = owned_requirement, .state = state };
        if (state != .available) {
            diagnostic_buffer[diagnostic_count] = .{
                .severity = .@"error",
                .phase = .preflight,
                .code = .missing_capability,
                .configuration_path = owned_requirement.path,
                .message = if (state == .missing) "a required host capability is unavailable" else "a required host capability is unsupported",
                .remediation = owned_requirement.reason,
            };
            diagnostic_count += 1;
        }
    }

    return .{
        .arena = arena,
        .capabilities = checks,
        .diagnostics = .{ .items = diagnostic_buffer[0..diagnostic_count] },
    };
}

fn systemCapabilityCheck(_: ?*anyopaque, io: Io, requirement: CapabilityRequirement) CapabilityState {
    const cwd = Io.Dir.cwd();
    return switch (requirement.kind) {
        .read_iso => if (isReadableKind(cwd, io, requirement.path, .file)) .available else .missing,
        .read_container => if (isReadablePath(cwd, io, requirement.path)) .available else .missing,
        .write_workspace_parent => if (canCreatePath(cwd, io, requirement.path)) .available else .missing,
        .write_output_parent => if (canCreatePath(cwd, io, requirement.path)) .available else .missing,
        .output_absent, .transaction_absent => if (pathAbsent(cwd, io, requirement.path)) .available else .missing,
        .path_isolation => blk: {
            const overlaps = canonicalPathsOverlap(cwd, io, requirement.path, requirement.related_path) orelse
                break :blk .unsupported;
            break :blk if (overlaps) .missing else .available;
        },
        .unprivileged_native_backend, .atomic_commit => .available,
    };
}

fn canonicalPathsOverlap(dir: Io.Dir, io: Io, first: []const u8, second: []const u8) ?bool {
    var first_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var second_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const first_len = canonicalPath(dir, io, first, &first_buffer) orelse return null;
    const second_len = canonicalPath(dir, io, second, &second_buffer) orelse return null;
    const canonical_first = first_buffer[0..first_len];
    const canonical_second = second_buffer[0..second_len];
    return std.mem.eql(u8, canonical_first, canonical_second) or
        pathContains(canonical_second, canonical_first);
}

fn canonicalPath(dir: Io.Dir, io: Io, path: []const u8, buffer: *[Io.Dir.max_path_bytes]u8) ?usize {
    var absolute_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_path = if (std.fs.path.isAbsolute(path))
        path
    else blk: {
        const cwd_len = dir.realPathFile(io, ".", &absolute_buffer) catch return null;
        const separator_len: usize = @intFromBool(cwd_len != 0 and !std.fs.path.isSep(absolute_buffer[cwd_len - 1]));
        if (cwd_len + separator_len + path.len > absolute_buffer.len) return null;
        if (separator_len != 0) absolute_buffer[cwd_len] = std.fs.path.sep;
        @memcpy(absolute_buffer[cwd_len + separator_len ..][0..path.len], path);
        break :blk absolute_buffer[0 .. cwd_len + separator_len + path.len];
    };
    var candidate: []const u8 = absolute_path;
    while (true) {
        if (dir.realPathFile(io, candidate, buffer)) |len| {
            const suffix = absolute_path[candidate.len..];
            if (len + suffix.len > buffer.len) return null;
            @memcpy(buffer[len..][0..suffix.len], suffix);
            return len + suffix.len;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return null,
        }

        const parent = std.fs.path.dirname(candidate) orelse return null;
        if (std.mem.eql(u8, parent, candidate)) return null;
        candidate = parent;
    }
}

fn isReadableKind(dir: Io.Dir, io: Io, path: []const u8, kind: Io.File.Kind) bool {
    dir.access(io, path, .{ .read = true }) catch return false;
    const stat = dir.statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == kind;
}

fn isReadablePath(dir: Io.Dir, io: Io, path: []const u8) bool {
    dir.access(io, path, .{ .read = true }) catch return false;
    const stat = dir.statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .file or stat.kind == .directory;
}

fn canWrite(dir: Io.Dir, io: Io, path: []const u8) bool {
    dir.access(io, path, .{ .write = true }) catch return false;
    const stat = dir.statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

fn canCreatePath(dir: Io.Dir, io: Io, path: []const u8) bool {
    var candidate = path;
    while (true) {
        if (dir.statFile(io, candidate, .{})) |stat| {
            if (stat.kind != .directory) return false;
            return canWrite(dir, io, candidate);
        } else |err| switch (err) {
            error.FileNotFound => {
                candidate = std.fs.path.dirname(candidate) orelse ".";
            },
            else => return false,
        }
    }
}

fn pathAbsent(dir: Io.Dir, io: Io, path: []const u8) bool {
    _ = dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| return err == error.FileNotFound;
    return false;
}

pub const SourceKind = enum {
    iso,
    container,
};

pub const SourceRecord = struct {
    kind: SourceKind,
    path: []const u8,
    sha256: Digest,
};

pub const ToolRecord = struct {
    name: []const u8,
    version: []const u8,
    command: []const []const u8,
};

pub const ArtifactRecord = struct {
    path: []const u8,
    format: OutputFormat,
    size: u64,
    sha256: Digest,
};

pub const ResolvedConfiguration = struct {
    architectures: ArchitectureSet,
    input: ResolvedInput,
    output: ResolvedOutput,
    storage: ResolvedStorage,
    os: OsCustomization,
    boot_security: BootSecurityPolicy,
    generalization: GeneralizationPolicy,
    execution: ExecutionPolicy,
    operations: []const Operation,
};

pub const PartitionRecord = struct {
    name: []const u8,
    role: layout.PartitionRole,
    offset_bytes: u64,
    length_bytes: u64,
    unique_guid: ?Guid,
    mbr_disk_signature: ?u32,
};

pub const VhdxMetadataRecord = struct {
    header_sequence_number: u64,
    file_write_guid: Guid,
    data_write_guid: Guid,
    page83_guid: Guid,
};

pub const VerityRecord = struct {
    format: u32,
    hash_algorithm: []const u8,
    data_block_size: u32,
    hash_block_size: u32,
    data_blocks: u64,
    hash_offset: u64,
    hash_tree_size: u64,
    salt: Digest,
    root_hash: Digest,
};

pub const PartitionStyleRecord = struct {
    ok: bool,
    message: []const u8,
};

pub const ExecutionRecord = struct {
    rootfs_path_in_iso: []const u8,
    partitions: []const PartitionRecord,
    verity: ?VerityRecord,
    vhd_alignment: ?azure.FixupResult,
    partition_style: ?PartitionStyleRecord,
    vhdx_metadata: ?VhdxMetadataRecord,
};

pub const Provenance = struct {
    schema_version: u32 = provenance_schema_version,
    plan_hash: Digest,
    sources: []const SourceRecord,
    resolved: ResolvedConfiguration,
    generated: GeneratedIdentifiers,
    reproducibility: Reproducibility,
    tools: []const ToolRecord,
    execution: ExecutionRecord,
    final_output: ArtifactRecord,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    output_path: []const u8,
    provenance: Provenance,

    fn deinit(self: *Result, _: Allocator) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ExecutionEvent = union(enum) {
    progress: Progress,
    diagnostic: Diagnostic,
};

pub const Progress = struct {
    phase: DiagnosticPhase,
    message: []const u8,
};

pub const EventSink = struct {
    context: ?*anyopaque = null,
    emitFn: *const fn (context: ?*anyopaque, event: ExecutionEvent) void,

    fn emit(self: EventSink, event: ExecutionEvent) void {
        self.emitFn(self.context, event);
    }
};

pub const ExecutionOutcome = struct {
    diagnostics: DiagnosticSet,
    result: ?Result,

    pub fn deinit(self: *ExecutionOutcome, allocator: Allocator) void {
        self.diagnostics.deinit(allocator);
        if (self.result) |*result| result.deinit(allocator);
        self.* = undefined;
    }
};

fn ownDiagnosticSet(allocator: Allocator, diagnostics: []const Diagnostic) Allocator.Error!DiagnosticSet {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = try dupeDiagnostics(arena.allocator(), diagnostics, 0);
    return .{ .items = owned, .arena = arena };
}

fn ownDiagnosticSetWithCleanupSlot(
    allocator: Allocator,
    diagnostics: []const Diagnostic,
    transaction_path: []const u8,
) Allocator.Error!DiagnosticSet {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = try dupeDiagnostics(arena.allocator(), diagnostics, 1);
    owned[owned.len - 1] = .{
        .severity = .info,
        .phase = .cleanup,
        .code = .cleanup_completed,
        .configuration_path = try arena.allocator().dupe(u8, transaction_path),
        .message = "transaction artifacts were removed",
    };
    return .{ .items = owned, .arena = arena };
}

fn dupeDiagnostics(
    allocator: Allocator,
    diagnostics: []const Diagnostic,
    extra_items: usize,
) Allocator.Error![]Diagnostic {
    const owned = try allocator.alloc(Diagnostic, diagnostics.len + extra_items);
    for (diagnostics, 0..) |diagnostic, index| {
        const command = if (diagnostic.command) |command_value| blk: {
            const argv = try allocator.alloc([]const u8, command_value.argv.len);
            for (command_value.argv, 0..) |arg, arg_index| argv[arg_index] = try allocator.dupe(u8, arg);
            break :blk CommandDiagnostic{
                .argv = argv,
                .exit_status = command_value.exit_status,
            };
        } else null;
        owned[index] = .{
            .severity = diagnostic.severity,
            .phase = diagnostic.phase,
            .code = diagnostic.code,
            .configuration_path = try allocator.dupe(u8, diagnostic.configuration_path),
            .message = try allocator.dupe(u8, diagnostic.message),
            .cause = if (diagnostic.cause) |cause| .{
                .error_name = try allocator.dupe(u8, cause.error_name),
            } else null,
            .command = command,
            .remediation = if (diagnostic.remediation) |remediation| try allocator.dupe(u8, remediation) else null,
        };
    }
    return owned;
}

fn failureOutcome(allocator: Allocator, diagnostics: []const Diagnostic) Allocator.Error!ExecutionOutcome {
    return .{
        .diagnostics = try ownDiagnosticSet(allocator, diagnostics),
        .result = null,
    };
}

fn buildResult(
    allocator: Allocator,
    plan: *const ResolvedPlan,
    report: ?*const build_image.BuildImageReport,
    iso_digest: Digest,
    container_digest: Digest,
    output_digest: Digest,
    output_file_size: u64,
) Allocator.Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const result_allocator = arena.allocator();

    const output_path = try result_allocator.dupe(u8, plan.data.output.path);
    const input = ResolvedInput{
        .iso_path = try result_allocator.dupe(u8, plan.data.input.iso_path),
        .container_path = try result_allocator.dupe(u8, plan.data.input.container_path),
        .rootfs_path_in_iso = try result_allocator.dupe(u8, plan.data.input.rootfs_path_in_iso),
    };
    const sources = try result_allocator.alloc(SourceRecord, 2);
    sources[0] = .{ .kind = .iso, .path = input.iso_path, .sha256 = iso_digest };
    sources[1] = .{ .kind = .container, .path = input.container_path, .sha256 = container_digest };
    const resolved_output = ResolvedOutput{
        .path = output_path,
        .format = plan.data.output.format,
        .requested_size = plan.data.output.requested_size,
        .disk_size = plan.data.output.disk_size,
    };
    const resolved_storage = ResolvedStorage{
        .generation = plan.data.storage.generation,
        .esp_size = plan.data.storage.esp_size,
        .ext4_label = try result_allocator.dupe(u8, plan.data.storage.ext4_label),
        .skip_iso_rootfs = plan.data.storage.skip_iso_rootfs,
    };
    const resolved_execution = ExecutionPolicy{
        .workspace_path = try result_allocator.dupe(u8, plan.data.execution.workspace_path),
        .backend = plan.data.execution.backend,
        .overwrite = plan.data.execution.overwrite,
    };
    const resolved_boot = try dupeBootPolicy(result_allocator, plan.data.boot_security);
    const operations = try dupeOperations(result_allocator, plan.data.operations);
    const partitions = if (report) |build_report| blk: {
        const records = try result_allocator.alloc(PartitionRecord, build_report.planned_partitions.len);
        for (build_report.planned_partitions, 0..) |partition, index| {
            records[index] = .{
                .name = try result_allocator.dupe(u8, partition.planned.name),
                .role = partition.planned.role,
                .offset_bytes = partition.planned.offset_bytes,
                .length_bytes = partition.planned.length_bytes,
                .unique_guid = if (partition.mbr_disk_signature == null) .{ .bytes = partition.unique_guid } else null,
                .mbr_disk_signature = partition.mbr_disk_signature,
            };
        }
        break :blk records;
    } else &.{};
    const verity_record = if (report) |build_report|
        if (build_report.verity) |verity_info| VerityRecord{
            .format = verity_info.format,
            .hash_algorithm = try result_allocator.dupe(u8, verity_info.hashAlgorithm),
            .data_block_size = verity_info.dataBlockSize,
            .hash_block_size = verity_info.hashBlockSize,
            .data_blocks = verity_info.dataBlocks,
            .hash_offset = verity_info.hashOffset,
            .hash_tree_size = verity_info.hashTreeSize,
            .salt = .{ .bytes = verity_info.salt },
            .root_hash = .{ .bytes = verity_info.rootHash },
        } else null
    else
        null;
    const partition_style = if (report) |build_report|
        if (build_report.partition_style) |style| PartitionStyleRecord{
            .ok = style.ok,
            .message = try result_allocator.dupe(u8, style.message),
        } else null
    else
        null;
    const actual_rootfs_path = if (report) |build_report|
        try result_allocator.dupe(u8, build_report.rootfs_path_in_iso)
    else
        input.rootfs_path_in_iso;

    return .{
        .arena = arena,
        .output_path = output_path,
        .provenance = .{
            .plan_hash = plan.data.plan_hash,
            .sources = sources,
            .resolved = .{
                .architectures = plan.data.architectures,
                .input = input,
                .output = resolved_output,
                .storage = resolved_storage,
                .os = plan.data.os,
                .boot_security = resolved_boot,
                .generalization = plan.data.generalization,
                .execution = resolved_execution,
                .operations = operations,
            },
            .generated = plan.data.generated,
            .reproducibility = plan.data.reproducibility,
            .tools = &.{},
            .execution = .{
                .rootfs_path_in_iso = actual_rootfs_path,
                .partitions = partitions,
                .verity = verity_record,
                .vhd_alignment = if (report) |build_report| build_report.vhd_alignment else null,
                .partition_style = partition_style,
                .vhdx_metadata = if (report) |build_report|
                    if (build_report.vhdx_metadata) |metadata| .{
                        .header_sequence_number = metadata.header_sequence_number,
                        .file_write_guid = .{ .bytes = metadata.file_write_guid },
                        .data_write_guid = .{ .bytes = metadata.data_write_guid },
                        .page83_guid = .{ .bytes = metadata.page83_guid },
                    } else null
                else
                    null,
            },
            .final_output = .{
                .path = output_path,
                .format = plan.data.output.format,
                .size = output_file_size,
                .sha256 = output_digest,
            },
        },
    };
}

fn dupeOperations(allocator: Allocator, operations: []const Operation) Allocator.Error![]Operation {
    const owned = try allocator.alloc(Operation, operations.len);
    for (operations, 0..) |operation, index| {
        owned[index] = .{
            .id = operation.id,
            .phase = operation.phase,
            .depends_on = try allocator.dupe(u16, operation.depends_on),
            .action = operation.action,
        };
    }
    return owned;
}

pub fn execute(
    allocator: Allocator,
    io: Io,
    plan: *const ResolvedPlan,
    platform: Platform,
    event_sink: ?EventSink,
) Allocator.Error!ExecutionOutcome {
    var diagnostics = std.array_list.Managed(Diagnostic).init(allocator);
    defer diagnostics.deinit();
    try diagnostics.ensureTotalCapacity(8);

    if (!try hasValidPlanIntegrity(allocator, plan)) {
        try diagnostics.append(.{
            .severity = .@"error",
            .phase = .execution,
            .code = .invalid_plan,
            .configuration_path = "/",
            .message = "the resolved plan failed its integrity or backend invariant checks",
            .remediation = "execute the immutable plan returned by resolve without modification",
        });
        emitDiagnostics(event_sink, diagnostics.items);
        return try failureOutcome(allocator, diagnostics.items);
    }

    var preflight_report = try preflight(allocator, io, plan, platform);
    defer preflight_report.deinit(allocator);
    try diagnostics.appendSlice(preflight_report.diagnostics.items);
    if (!preflight_report.ready()) {
        emitDiagnostics(event_sink, diagnostics.items);
        return try failureOutcome(allocator, diagnostics.items);
    }
    const iso_digest_before = hashPath(allocator, io, plan.data.input.iso_path) catch |err| {
        try appendFailure(&diagnostics, .source_hash_failed, .execution, "/input/iso_oci/iso_path", "failed to hash the source ISO", err);
        emitDiagnostics(event_sink, diagnostics.items);
        return try failureOutcome(allocator, diagnostics.items);
    };
    const container_digest_before = hashPath(allocator, io, plan.data.input.container_path) catch |err| {
        try appendFailure(&diagnostics, .source_hash_failed, .execution, "/input/iso_oci/container_path", "failed to hash the source container", err);
        emitDiagnostics(event_sink, diagnostics.items);
        return try failureOutcome(allocator, diagnostics.items);
    };

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, plan.data.execution.workspace_path) catch |err| {
        try appendFailure(&diagnostics, .execution_failed, .execution, "/execution/workspace_path", "failed to create the workspace", err);
        emitDiagnostics(event_sink, diagnostics.items);
        return try failureOutcome(allocator, diagnostics.items);
    };
    cwd.createDir(io, plan.data.transaction_path, .default_dir) catch |err| {
        try appendFailure(&diagnostics, .execution_failed, .execution, "/execution/workspace_path", "failed to create the transaction directory", err);
        emitDiagnostics(event_sink, diagnostics.items);
        return try failureOutcome(allocator, diagnostics.items);
    };
    var transaction_active = true;
    errdefer if (transaction_active) cwd.deleteTree(io, plan.data.transaction_path) catch {};

    var bridge = BuildEventBridge{
        .event_sink = event_sink,
        .diagnostics = &diagnostics,
    };
    var report = runPlan(allocator, io, plan, platform, event_sink, &bridge) catch |err| {
        try appendFailure(&diagnostics, .execution_failed, .execution, "", "image execution failed", err);
        if (cleanupTransaction(io, plan.data.transaction_path)) |diagnostic| try diagnostics.append(diagnostic);
        emitDiagnostics(event_sink, diagnostics.items);
        return try failureOutcome(allocator, diagnostics.items);
    };
    defer if (report) |*build_report| build_report.deinit(allocator);

    const iso_digest_after = hashPath(allocator, io, plan.data.input.iso_path) catch |err| {
        try appendFailure(&diagnostics, .source_hash_failed, .execution, "/input/iso_oci/iso_path", "failed to verify the source ISO hash", err);
        if (cleanupTransaction(io, plan.data.transaction_path)) |diagnostic| try diagnostics.append(diagnostic);
        emitDiagnostics(event_sink, diagnostics.items);
        return try failureOutcome(allocator, diagnostics.items);
    };
    const container_digest_after = hashPath(allocator, io, plan.data.input.container_path) catch |err| {
        try appendFailure(&diagnostics, .source_hash_failed, .execution, "/input/iso_oci/container_path", "failed to verify the source container hash", err);
        if (cleanupTransaction(io, plan.data.transaction_path)) |diagnostic| try diagnostics.append(diagnostic);
        emitDiagnostics(event_sink, diagnostics.items);
        return try failureOutcome(allocator, diagnostics.items);
    };
    if (!std.mem.eql(u8, &iso_digest_before.bytes, &iso_digest_after.bytes) or
        !std.mem.eql(u8, &container_digest_before.bytes, &container_digest_after.bytes))
    {
        try diagnostics.append(.{
            .severity = .@"error",
            .phase = .execution,
            .code = .source_changed,
            .configuration_path = "/input",
            .message = "a source changed while the image was being built",
            .remediation = "retry with immutable or cache-snapshotted inputs",
        });
        if (cleanupTransaction(io, plan.data.transaction_path)) |diagnostic| try diagnostics.append(diagnostic);
        emitDiagnostics(event_sink, diagnostics.items);
        return try failureOutcome(allocator, diagnostics.items);
    }

    const output_digest = hashPath(allocator, io, plan.data.staging_output_path) catch |err| {
        try appendFailure(&diagnostics, .source_hash_failed, .execution, "/output/path", "failed to hash the completed output", err);
        if (cleanupTransaction(io, plan.data.transaction_path)) |diagnostic| try diagnostics.append(diagnostic);
        emitDiagnostics(event_sink, diagnostics.items);
        return try failureOutcome(allocator, diagnostics.items);
    };
    const output_file_size = (cwd.statFile(io, plan.data.staging_output_path, .{}) catch |err| {
        try appendFailure(&diagnostics, .execution_failed, .execution, "/output/path", "failed to inspect the completed output", err);
        if (cleanupTransaction(io, plan.data.transaction_path)) |diagnostic| try diagnostics.append(diagnostic);
        emitDiagnostics(event_sink, diagnostics.items);
        return try failureOutcome(allocator, diagnostics.items);
    }).size;

    var result = try buildResult(
        allocator,
        plan,
        if (report) |*build_report| build_report else null,
        iso_digest_before,
        container_digest_before,
        output_digest,
        output_file_size,
    );
    var result_owned_by_function = true;
    errdefer if (result_owned_by_function) result.deinit(allocator);
    var final_diagnostics = try ownDiagnosticSetWithCleanupSlot(
        allocator,
        diagnostics.items,
        plan.data.transaction_path,
    );
    var final_diagnostics_owned_by_function = true;
    errdefer if (final_diagnostics_owned_by_function) final_diagnostics.deinit(allocator);

    const commit_result = if (plan.data.execution.overwrite)
        cwd.rename(plan.data.staging_output_path, cwd, plan.data.output.path, io)
    else
        cwd.renamePreserve(plan.data.staging_output_path, cwd, plan.data.output.path, io);
    commit_result catch |err| {
        result.deinit(allocator);
        final_diagnostics.deinit(allocator);
        final_diagnostics_owned_by_function = false;
        result_owned_by_function = false;
        const cleanup_diagnostic = cleanupTransaction(io, plan.data.transaction_path);
        transaction_active = false;
        try appendFailure(&diagnostics, .commit_failed, .execution, "/output/path", "failed to atomically commit the completed output", err);
        if (cleanup_diagnostic) |diagnostic| try diagnostics.append(diagnostic);
        emitDiagnostics(event_sink, diagnostics.items);
        return try failureOutcome(allocator, diagnostics.items);
    };

    const cleanup_failure = cleanupTransaction(io, plan.data.transaction_path);
    transaction_active = false;
    const cleanup_slot = &final_diagnostics.items[final_diagnostics.items.len - 1];
    if (cleanup_failure != null) {
        cleanup_slot.severity = .warning;
        cleanup_slot.code = .cleanup_failed;
        cleanup_slot.message = "failed to remove the transaction directory";
    }
    if (event_sink) |sink| sink.emit(.{ .diagnostic = cleanup_slot.* });
    final_diagnostics_owned_by_function = false;
    result_owned_by_function = false;
    return .{
        .diagnostics = final_diagnostics,
        .result = result,
    };
}

fn hasValidPlanIntegrity(allocator: Allocator, plan: *const ResolvedPlan) Allocator.Error!bool {
    const data = plan.data;
    const computed_hash = hashPlan(data.*);
    if (data.schema_version != plan_schema_version or
        data.request_api_version != current_api_version or
        data.execution.backend != .native or
        data.output.format.imageFormat() == null or
        !hasExpectedNativeOperations(plan) or
        !std.mem.eql(u8, &computed_hash.bytes, &data.plan_hash.bytes))
    {
        return false;
    }
    if (data.storage.generation == .gen1 and data.architectures.image != .x86_64) return false;
    const output_parent = std.fs.path.dirname(data.output.path) orelse ".";
    if (!std.mem.eql(u8, output_parent, data.execution.workspace_path)) return false;

    const transaction_hex = std.fmt.bytesToHex(data.generated.transaction_id.bytes, .lower);
    const transaction_name = try std.fmt.allocPrint(allocator, ".zvmi-{s}", .{transaction_hex});
    defer allocator.free(transaction_name);
    const expected_transaction = try std.fs.path.join(allocator, &.{ data.execution.workspace_path, transaction_name });
    defer allocator.free(expected_transaction);
    const expected_staging = try std.fs.path.join(allocator, &.{ expected_transaction, "output.img" });
    defer allocator.free(expected_staging);
    return std.mem.eql(u8, expected_transaction, data.transaction_path) and
        std.mem.eql(u8, expected_staging, data.staging_output_path);
}

fn runPlan(
    allocator: Allocator,
    io: Io,
    plan: *const ResolvedPlan,
    platform: Platform,
    event_sink: ?EventSink,
    bridge: *BuildEventBridge,
) !?build_image.BuildImageReport {
    var stage_bridge = NativeStageBridge{ .operations = plan.data.operations };
    const stage_sink = build_image.StageSink{ .context = &stage_bridge, .advanceFn = NativeStageBridge.advance };
    if (platform.runFn) |run| {
        try run(platform.context, allocator, io, plan, event_sink, stage_sink);
        if (stage_bridge.next != plan.data.operations.len) return error.InvalidOperationOrder;
        return null;
    }
    var options = buildOptionsFromPlan(plan, bridge);
    options.stage_sink = stage_sink;
    var report = try build_image.build(allocator, io, options);
    errdefer report.deinit(allocator);
    if (stage_bridge.next != plan.data.operations.len) return error.InvalidOperationOrder;
    return report;
}

fn buildOptionsFromPlan(plan: *const ResolvedPlan, bridge: *BuildEventBridge) build_image.BuildImageOptions {
    const generated = plan.data.generated;
    return .{
        .iso_path = plan.data.input.iso_path,
        .container_path = plan.data.input.container_path,
        .output_path = plan.data.staging_output_path,
        .size = plan.data.output.disk_size,
        .generation = plan.data.storage.generation,
        .output_format = plan.data.output.format.imageFormat().?,
        .rootfs_path_in_iso = plan.data.input.rootfs_path_in_iso,
        .skip_iso_rootfs = plan.data.storage.skip_iso_rootfs,
        .esp_size = plan.data.storage.esp_size,
        .ext4_label = plan.data.storage.ext4_label,
        .verity = plan.data.boot_security.verity,
        .extra_kernel_options = plan.data.boot_security.extra_kernel_options,
        .boot_mode = plan.data.boot_security.boot_mode,
        .uki = .{
            .stub_source_path = plan.data.boot_security.uki.stub_source_path,
            .os_release_source_path = plan.data.boot_security.uki.os_release_source_path,
            .splash_source_path = plan.data.boot_security.uki.splash_source_path,
            .output_directory = plan.data.boot_security.uki.output_directory,
        },
        .architecture = plan.data.architectures.image,
        .deterministic = .{
            .disk_guid = generated.disk_guid.bytes,
            .esp_partition_guid = generated.esp_partition_guid.bytes,
            .root_partition_guid = generated.root_partition_guid.bytes,
            .mbr_disk_signature = generated.mbr_disk_signature,
            .root_filesystem_uuid = generated.root_filesystem_uuid.bytes,
            .verity_salt = generated.verity_salt.bytes,
            .filesystem_timestamp = @intCast(plan.data.reproducibility.source_date_epoch),
            .output_create_options = .{
                .unique_id = generated.output_unique_id.bytes,
                .timestamp_unix = @intCast(plan.data.reproducibility.source_date_epoch),
                .vhdx = .{
                    .header_sequence_base = generated.vhdx_header_sequence_base,
                    .file_write_guid = generated.vhdx_file_write_guid.bytes,
                    .data_write_guid = generated.vhdx_data_write_guid.bytes,
                    .page83_guid = generated.vhdx_page83_guid.bytes,
                    .write_guid_seed = generated.vhdx_write_guid_seed.bytes,
                },
            },
        },
        .event_sink = .{ .context = bridge, .emitFn = BuildEventBridge.emit },
    };
}

const NativeStageBridge = struct {
    operations: []const Operation,
    next: usize = 0,

    fn advance(context: ?*anyopaque, stage: build_image.Stage) bool {
        const self: *NativeStageBridge = @ptrCast(@alignCast(context.?));
        if (self.next >= self.operations.len) return false;
        const operation = self.operations[self.next];
        if (operation.action != stage) return false;
        for (operation.depends_on) |dependency| {
            if (dependency >= self.next) return false;
        }
        self.next += 1;
        return true;
    }
};

const BuildEventBridge = struct {
    event_sink: ?EventSink,
    diagnostics: *std.array_list.Managed(Diagnostic),

    fn emit(context: ?*anyopaque, event: build_image.Event) void {
        const self: *BuildEventBridge = @ptrCast(@alignCast(context.?));
        switch (event) {
            .progress => |message| {
                if (self.event_sink) |sink| {
                    sink.emit(.{ .progress = .{ .phase = .execution, .message = message } });
                }
            },
            .warning => |warning| {
                const diagnostic = Diagnostic{
                    .severity = .warning,
                    .phase = .execution,
                    .code = .runtime_warning,
                    .configuration_path = "",
                    .message = warning.message,
                };
                self.diagnostics.appendAssumeCapacity(diagnostic);
                if (self.event_sink) |sink| sink.emit(.{ .diagnostic = diagnostic });
            },
        }
    }
};

fn appendFailure(
    diagnostics: *std.array_list.Managed(Diagnostic),
    code: DiagnosticCode,
    phase: DiagnosticPhase,
    path: []const u8,
    message: []const u8,
    err: anyerror,
) Allocator.Error!void {
    try diagnostics.append(.{
        .severity = .@"error",
        .phase = phase,
        .code = code,
        .configuration_path = path,
        .message = message,
        .cause = .{ .error_name = @errorName(err) },
    });
}

fn cleanupTransaction(io: Io, transaction_path: []const u8) ?Diagnostic {
    Io.Dir.cwd().deleteTree(io, transaction_path) catch |err| {
        return .{
            .severity = .warning,
            .phase = .cleanup,
            .code = .cleanup_failed,
            .configuration_path = transaction_path,
            .message = "failed to remove the transaction directory",
            .cause = .{ .error_name = @errorName(err) },
        };
    };
    return null;
}

fn emitDiagnostics(event_sink: ?EventSink, diagnostics: []const Diagnostic) void {
    const sink = event_sink orelse return;
    for (diagnostics) |diagnostic| sink.emit(.{ .diagnostic = diagnostic });
}

const HashEntry = struct {
    path: []u8,
    kind: Io.File.Kind,
};

fn hashPath(allocator: Allocator, io: Io, path: []const u8) !Digest {
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    return switch (stat.kind) {
        .file => hashFile(io, Io.Dir.cwd(), path),
        .directory => hashDirectory(allocator, io, path),
        else => error.UnsupportedSourceEntry,
    };
}

pub fn hashSourcePath(allocator: Allocator, io: Io, path: []const u8) !Digest {
    return hashPath(allocator, io, path);
}

fn hashFile(io: Io, dir: Io.Dir, path: []const u8) !Digest {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const length: usize = @intCast(@min(size - offset, buffer.len));
        const read = try file.readPositionalAll(io, buffer[0..length], offset);
        if (read != length) return error.ShortRead;
        hash.update(buffer[0..length]);
        offset += length;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .{ .bytes = digest };
}

fn hashDirectory(allocator: Allocator, io: Io, path: []const u8) !Digest {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var entries = std.array_list.Managed(HashEntry).init(allocator);
    defer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit();
    }

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .directory) return error.UnsupportedSourceEntry;
        try entries.append(.{
            .path = try allocator.dupe(u8, entry.path),
            .kind = entry.kind,
        });
    }
    std.mem.sortUnstable(HashEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: HashEntry, rhs: HashEntry) bool {
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zvmi-directory-hash-v1\x00");
    for (entries.items) |entry| {
        hashString(&hash, entry.path);
        hashInt(&hash, @intFromEnum(entry.kind));
        if (entry.kind == .file) {
            const digest = try hashFile(io, dir, entry.path);
            hash.update(&digest.bytes);
        }
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .{ .bytes = digest };
}

pub fn writeRequestJson(request: Request, writer: *Io.Writer) !void {
    try std.json.Stringify.value(request, .{ .whitespace = .indent_2 }, writer);
}

pub fn writePlanJson(plan: *const ResolvedPlan, writer: *Io.Writer) !void {
    try std.json.Stringify.value(plan.data, .{ .whitespace = .indent_2 }, writer);
}

pub fn writeDiagnosticsJson(diagnostics: DiagnosticSet, writer: *Io.Writer) !void {
    try std.json.Stringify.value(diagnostics.items, .{ .whitespace = .indent_2 }, writer);
}

pub fn writeProvenanceJson(provenance: Provenance, writer: *Io.Writer) !void {
    try std.json.Stringify.value(provenance, .{ .whitespace = .indent_2 }, writer);
}

fn validRequest() Request {
    return .{
        .target_architecture = .x86_64,
        .input = .{ .iso_oci = .{
            .iso_path = "source.iso",
            .container_path = "oci-layout",
            .rootfs_path_in_iso = "images/rootfs.squashfs",
        } },
        .output = .{
            .path = "output.qcow2",
            .format = .qcow2,
            .size = 128 * mib,
        },
        .storage = .{ .fresh = .{} },
        .execution = .{ .workspace_path = "." },
        .reproducibility = .{
            .seed = .{ .bytes = [_]u8{0x5A} ** 32 },
            .source_date_epoch = 1_735_689_600,
        },
    };
}

test "validation reports multiple problems without mutating the request" {
    var request = validRequest();
    request.api_version = 99;
    request.target_architecture = null;
    request.output.path = "";
    request.output.size = 123;
    request.execution.workspace_path = "";
    const before = request;

    var diagnostics = try validate(std.testing.allocator, &request);
    defer diagnostics.deinit(std.testing.allocator);

    try std.testing.expect(diagnostics.items.len >= 5);
    try std.testing.expect(diagnostics.hasErrors());
    try std.testing.expect(std.meta.eql(before, request));
}

test "validation rejects normalized source aliases and unsupported aarch64 BIOS" {
    var request = validRequest();
    request.input.iso_oci.iso_path = "./output.qcow2";
    request.target_architecture = .aarch64;
    request.storage.fresh.generation = .gen1;
    request.boot_security.verity = true;
    request.execution.overwrite = true;

    var diagnostics = try validate(std.testing.allocator, &request);
    defer diagnostics.deinit(std.testing.allocator);

    var saw_path_conflict = false;
    var saw_boot_conflict = false;
    var saw_verity_conflict = false;
    for (diagnostics.items) |diagnostic| {
        saw_path_conflict = saw_path_conflict or diagnostic.code == .path_conflict;
        saw_boot_conflict = saw_boot_conflict or diagnostic.code == .incompatible_boot_policy;
        saw_verity_conflict = saw_verity_conflict or
            (diagnostic.code == .incompatible_boot_policy and
                std.mem.eql(u8, diagnostic.configuration_path, "/boot_security/verity"));
    }
    try std.testing.expect(saw_path_conflict);
    try std.testing.expect(saw_boot_conflict);
    try std.testing.expect(saw_verity_conflict);
}

test "validation rejects guaranteed-invalid filesystem and partition geometries" {
    var tiny_esp = validRequest();
    tiny_esp.storage.fresh.esp_size = 1;
    var tiny_diagnostics = try validate(std.testing.allocator, &tiny_esp);
    defer tiny_diagnostics.deinit(std.testing.allocator);
    var saw_fat32_limit = false;
    for (tiny_diagnostics.items) |diagnostic| {
        saw_fat32_limit = saw_fat32_limit or
            (diagnostic.code == .invalid_storage and
                std.mem.eql(u8, diagnostic.configuration_path, "/storage/fresh/esp_size"));
    }
    try std.testing.expect(saw_fat32_limit);

    var oversized_mbr = validRequest();
    oversized_mbr.storage.fresh.generation = .gen1;
    oversized_mbr.output.size = 3 * 1024 * 1024 * 1024 * 1024;
    var mbr_diagnostics = try validate(std.testing.allocator, &oversized_mbr);
    defer mbr_diagnostics.deinit(std.testing.allocator);
    var saw_mbr_limit = false;
    for (mbr_diagnostics.items) |diagnostic| {
        saw_mbr_limit = saw_mbr_limit or
            (diagnostic.cause != null and std.mem.eql(u8, diagnostic.cause.?.error_name, "PartitionTooLargeForMbr"));
    }
    try std.testing.expect(saw_mbr_limit);

    var oversized_ext4 = validRequest();
    oversized_ext4.output.size = 20 * 1024 * 1024 * 1024 * 1024;
    var ext4_diagnostics = try validate(std.testing.allocator, &oversized_ext4);
    defer ext4_diagnostics.deinit(std.testing.allocator);
    var saw_ext4_limit = false;
    for (ext4_diagnostics.items) |diagnostic| {
        saw_ext4_limit = saw_ext4_limit or
            (diagnostic.cause != null and std.mem.eql(u8, diagnostic.cause.?.error_name, "FilesystemTooLarge"));
    }
    try std.testing.expect(saw_ext4_limit);

    var oversized_esp = validRequest();
    oversized_esp.storage.fresh.esp_size = std.math.maxInt(u64);
    var esp_diagnostics = try validate(std.testing.allocator, &oversized_esp);
    defer esp_diagnostics.deinit(std.testing.allocator);
    try std.testing.expect(esp_diagnostics.hasErrors());

    var huge_verity = validRequest();
    huge_verity.boot_security.verity = true;
    huge_verity.output.size = std.math.maxInt(u64) / mib * mib - 2 * mib;
    var verity_diagnostics = try validate(std.testing.allocator, &huge_verity);
    defer verity_diagnostics.deinit(std.testing.allocator);
    var saw_huge_verity_limit = false;
    for (verity_diagnostics.items) |diagnostic| {
        saw_huge_verity_limit = saw_huge_verity_limit or
            (diagnostic.cause != null and std.mem.eql(u8, diagnostic.cause.?.error_name, "FilesystemTooLarge"));
    }
    try std.testing.expect(saw_huge_verity_limit);
}

test "resolution applies base_path before checking mixed path forms" {
    var cwd_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try Io.Dir.cwd().realPathFile(std.testing.io, ".", &cwd_buffer);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ cwd_buffer[0..cwd_len], "test-customize-base" });
    defer std.testing.allocator.free(base_path);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "output.qcow2" });
    defer std.testing.allocator.free(output_path);

    var request = validRequest();
    request.output.path = output_path;
    request.execution.workspace_path = ".";
    var resolved = try resolve(std.testing.allocator, &request, .{
        .host_architecture = .x86_64,
        .base_path = base_path,
    });
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expect(resolved.plan != null);
    try std.testing.expectEqualStrings(base_path, resolved.plan.?.data.execution.workspace_path);
}

test "resolution is deterministic and encodes operation ordering" {
    const request = validRequest();
    var first = try resolve(std.testing.allocator, &request, .{ .host_architecture = .aarch64 });
    defer first.deinit(std.testing.allocator);
    var second = try resolve(std.testing.allocator, &request, .{ .host_architecture = .aarch64 });
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(first.plan != null);
    try std.testing.expect(second.plan != null);
    try std.testing.expectEqualSlices(u8, &first.plan.?.data.plan_hash.bytes, &second.plan.?.data.plan_hash.bytes);
    try std.testing.expect(std.meta.eql(first.plan.?.data.generated, second.plan.?.data.generated));

    const operations = first.plan.?.data.operations;
    try std.testing.expectEqual(Phase.prepare, operations[0].phase);
    try std.testing.expectEqual(Phase.output_conversion, operations[operations.len - 1].phase);
    try std.testing.expectEqual(operations[operations.len - 2].id, operations[operations.len - 1].depends_on[0]);
    try std.testing.expectEqual(Action.populate_filesystem, operations[4].action);
    try std.testing.expectEqual(Action.prepare_boot_configuration, operations[5].action);
    var stage_bridge = NativeStageBridge{ .operations = operations };
    for (operations) |operation| {
        try std.testing.expect(NativeStageBridge.advance(&stage_bridge, operation.action));
    }
    try std.testing.expectEqual(operations.len, stage_bridge.next);
    try std.testing.expect(!NativeStageBridge.advance(&stage_bridge, .convert_output));

    var other_request = request;
    other_request.output.path = "other-output.qcow2";
    var other = try resolve(std.testing.allocator, &other_request, .{ .host_architecture = .aarch64 });
    defer other.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(
        u8,
        &first.plan.?.data.generated.transaction_id.bytes,
        &other.plan.?.data.generated.transaction_id.bytes,
    ));
    try std.testing.expectEqualSlices(
        u8,
        &first.plan.?.data.generated.disk_guid.bytes,
        &other.plan.?.data.generated.disk_guid.bytes,
    );

    var gen1_request = request;
    gen1_request.storage.fresh.generation = .gen1;
    var gen1 = try resolve(std.testing.allocator, &gen1_request, .{ .host_architecture = .x86_64 });
    defer gen1.deinit(std.testing.allocator);
    try std.testing.expectEqual(Action.prepare_boot_configuration, gen1.plan.?.data.operations[4].action);
    try std.testing.expectEqual(Action.populate_filesystem, gen1.plan.?.data.operations[5].action);
}

test "resolution rejects architecture roles the native backend cannot honor" {
    const request = validRequest();
    var resolved = try resolve(std.testing.allocator, &request, .{
        .host_architecture = .x86_64,
        .firmware_architecture = .aarch64,
    });
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expect(resolved.plan == null);
    try std.testing.expectEqual(@as(usize, 1), resolved.diagnostics.items.len);
    try std.testing.expectEqual(DiagnosticCode.incompatible_architecture, resolved.diagnostics.items[0].code);
}

test "preflight and execution reject a modified resolved plan" {
    const request = validRequest();
    var resolved = try resolve(std.testing.allocator, &request, .{ .host_architecture = .x86_64 });
    defer resolved.deinit(std.testing.allocator);
    @constCast(resolved.plan.?.data).output.format = .cosi;

    var report = try preflight(std.testing.allocator, std.testing.io, &resolved.plan.?, Platform.system());
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.ready());
    try std.testing.expectEqual(DiagnosticCode.invalid_plan, report.diagnostics.items[0].code);

    var outcome = try execute(std.testing.allocator, std.testing.io, &resolved.plan.?, Platform.system(), null);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome.result == null);
    try std.testing.expectEqual(DiagnosticCode.invalid_plan, outcome.diagnostics.items[0].code);
}

test "planned metadata makes VHD and VHDX creation deterministic" {
    const io = std.testing.io;
    const request = validRequest();
    var resolved = try resolve(std.testing.allocator, &request, .{ .host_architecture = .x86_64 });
    defer resolved.deinit(std.testing.allocator);
    const generated = resolved.plan.?.data.generated;
    const create_options = image_mod.CreateOptions{
        .vhd_subformat = .fixed,
        .unique_id = generated.output_unique_id.bytes,
        .timestamp_unix = @intCast(request.reproducibility.source_date_epoch),
        .vhdx = .{
            .header_sequence_base = generated.vhdx_header_sequence_base,
            .file_write_guid = generated.vhdx_file_write_guid.bytes,
            .data_write_guid = generated.vhdx_data_write_guid.bytes,
            .page83_guid = generated.vhdx_page83_guid.bytes,
            .write_guid_seed = generated.vhdx_write_guid_seed.bytes,
        },
    };

    inline for (.{ Format.vhd, Format.vhdx }) |format| {
        const first_path = "test-customize-deterministic-a." ++ @tagName(format);
        const second_path = "test-customize-deterministic-b." ++ @tagName(format);
        defer Io.Dir.cwd().deleteFile(io, first_path) catch {};
        defer Io.Dir.cwd().deleteFile(io, second_path) catch {};

        var first = try image_mod.Image.create(io, first_path, format, 8 * mib, create_options);
        defer first.close(io);
        var second = try image_mod.Image.create(io, second_path, format, 8 * mib, create_options);
        defer second.close(io);
        try first.pwrite(io, "deterministic", 4096);
        try second.pwrite(io, "deterministic", 4096);

        const first_digest = try hashPath(std.testing.allocator, io, first_path);
        const second_digest = try hashPath(std.testing.allocator, io, second_path);
        try std.testing.expectEqualSlices(u8, &first_digest.bytes, &second_digest.bytes);
    }
}

test "preflight reports multiple missing capabilities" {
    const request = validRequest();
    var resolved = try resolve(std.testing.allocator, &request, .{ .host_architecture = .x86_64 });

    const Fake = struct {
        fn check(_: ?*anyopaque, _: Io, requirement: CapabilityRequirement) CapabilityState {
            return switch (requirement.kind) {
                .unprivileged_native_backend, .atomic_commit => .available,
                else => .missing,
            };
        }
    };
    var report = try preflight(std.testing.allocator, std.testing.io, &resolved.plan.?, .{ .checkFn = Fake.check });
    defer report.deinit(std.testing.allocator);
    resolved.deinit(std.testing.allocator);

    try std.testing.expect(!report.ready());
    try std.testing.expect(report.diagnostics.items.len >= 4);
    try std.testing.expect(report.capabilities[0].requirement.path.len != 0);
}

test "preflight accepts a missing but creatable output directory" {
    const io = std.testing.io;
    const iso_path = "test-customize-creatable.iso";
    const container_path = "test-customize-creatable.container";
    const workspace_path = "test-customize-creatable-work";
    defer Io.Dir.cwd().deleteFile(io, iso_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, container_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, workspace_path) catch {};

    {
        const file = try Io.Dir.cwd().createFile(io, iso_path, .{});
        file.close(io);
    }
    {
        const file = try Io.Dir.cwd().createFile(io, container_path, .{});
        file.close(io);
    }

    var request = validRequest();
    request.input.iso_oci.iso_path = iso_path;
    request.input.iso_oci.container_path = container_path;
    request.output.path = workspace_path ++ "/output.raw";
    request.output.format = .raw;
    request.execution.workspace_path = workspace_path;

    var resolved = try resolve(std.testing.allocator, &request, .{ .host_architecture = .x86_64 });
    defer resolved.deinit(std.testing.allocator);
    var report = try preflight(std.testing.allocator, io, &resolved.plan.?, Platform.system());
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.ready());
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, workspace_path, .{}));
}

test "preflight resolves a symlink before missing output ancestors" {
    const io = std.testing.io;
    const source_path = "test-customize-isolation-source";
    const alias_path = "test-customize-isolation-alias";
    defer Io.Dir.cwd().deleteFile(io, alias_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, source_path) catch {};
    try Io.Dir.cwd().createDirPath(io, source_path);
    try Io.Dir.cwd().symLink(io, source_path, alias_path, .{ .is_directory = true });

    const source_absolute = try std.fs.path.resolve(std.testing.allocator, &.{source_path});
    defer std.testing.allocator.free(source_absolute);
    const output_absolute = try std.fs.path.resolve(std.testing.allocator, &.{ alias_path, "missing", "deeper", "output.raw" });
    defer std.testing.allocator.free(output_absolute);

    const state = systemCapabilityCheck(null, io, .{
        .kind = .path_isolation,
        .path = output_absolute,
        .related_path = source_absolute,
        .reason = "test prospective canonical isolation",
    });
    try std.testing.expectEqual(CapabilityState.missing, state);
}

test "failed execution leaves no final output and removes its transaction" {
    const io = std.testing.io;
    const iso_path = "test-customize-invalid.iso";
    const container_path = "test-customize-container.tar";
    const workspace_path = "test-customize-work";
    const output_path = workspace_path ++ "/output.raw";
    defer Io.Dir.cwd().deleteFile(io, iso_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, container_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, workspace_path) catch {};
    try Io.Dir.cwd().createDirPath(io, workspace_path);

    {
        var file = try Io.Dir.cwd().createFile(io, iso_path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, "not-an-iso", 0);
    }
    {
        var file = try Io.Dir.cwd().createFile(io, container_path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, "not-a-container", 0);
    }

    var request = validRequest();
    request.input = .{ .iso_oci = .{
        .iso_path = iso_path,
        .container_path = container_path,
        .rootfs_path_in_iso = "rootfs.squashfs",
    } };
    request.output = .{ .path = output_path, .format = .raw, .size = 128 * mib };
    request.execution.workspace_path = workspace_path;

    var resolved = try resolve(std.testing.allocator, &request, .{ .host_architecture = .x86_64 });
    const transaction_path = try std.testing.allocator.dupe(u8, resolved.plan.?.data.transaction_path);
    defer std.testing.allocator.free(transaction_path);
    var outcome = try execute(std.testing.allocator, io, &resolved.plan.?, Platform.system(), null);
    defer outcome.deinit(std.testing.allocator);
    resolved.deinit(std.testing.allocator);

    try std.testing.expect(outcome.result == null);
    try std.testing.expect(outcome.diagnostics.hasErrors());
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, output_path, .{}));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, transaction_path, .{}));
}

test "custom execution platforms must advance every planned operation" {
    const IncompleteRunner = struct {
        fn run(
            _: ?*anyopaque,
            _: Allocator,
            _: Io,
            _: *const ResolvedPlan,
            _: ?EventSink,
            _: build_image.StageSink,
        ) !void {}
    };

    const request = validRequest();
    var resolved = try resolve(std.testing.allocator, &request, .{ .host_architecture = .x86_64 });
    defer resolved.deinit(std.testing.allocator);

    var diagnostics = std.array_list.Managed(Diagnostic).init(std.testing.allocator);
    defer diagnostics.deinit();
    var bridge = BuildEventBridge{
        .event_sink = null,
        .diagnostics = &diagnostics,
    };
    var platform = Platform.system();
    platform.runFn = IncompleteRunner.run;
    try std.testing.expectError(
        error.InvalidOperationOrder,
        runPlan(std.testing.allocator, std.testing.io, &resolved.plan.?, platform, null, &bridge),
    );
}

test "successful execution commits output and emits provenance" {
    const io = std.testing.io;
    const iso_path = "test-customize-success.iso";
    const container_path = "test-customize-success.container";
    const workspace_path = "test-customize-success-work";
    const output_path = workspace_path ++ "/output.raw";
    defer Io.Dir.cwd().deleteFile(io, iso_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, container_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, workspace_path) catch {};
    try Io.Dir.cwd().createDirPath(io, workspace_path);

    {
        var file = try Io.Dir.cwd().createFile(io, iso_path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, "source-iso", 0);
    }
    {
        var file = try Io.Dir.cwd().createFile(io, container_path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, "source-container", 0);
    }

    var request = validRequest();
    request.input = .{ .iso_oci = .{
        .iso_path = iso_path,
        .container_path = container_path,
        .rootfs_path_in_iso = "rootfs.squashfs",
    } };
    request.output = .{ .path = output_path, .format = .raw, .size = 128 * mib };
    request.execution.workspace_path = workspace_path;

    const FakeRunner = struct {
        fn run(
            _: ?*anyopaque,
            _: Allocator,
            run_io: Io,
            plan: *const ResolvedPlan,
            _: ?EventSink,
            stage_sink: build_image.StageSink,
        ) !void {
            for (plan.data.operations) |operation| {
                if (!stage_sink.advance(operation.action)) return error.InvalidOperationOrder;
            }
            const file = try Io.Dir.cwd().createFile(run_io, plan.data.staging_output_path, .{});
            defer file.close(run_io);
            try file.writePositionalAll(run_io, "completed-image", 0);
        }
    };

    var resolved = try resolve(std.testing.allocator, &request, .{ .host_architecture = .x86_64 });
    const transaction_path = try std.testing.allocator.dupe(u8, resolved.plan.?.data.transaction_path);
    defer std.testing.allocator.free(transaction_path);
    var platform = Platform.system();
    platform.runFn = FakeRunner.run;
    var outcome = try execute(std.testing.allocator, io, &resolved.plan.?, platform, null);
    defer outcome.deinit(std.testing.allocator);
    resolved.deinit(std.testing.allocator);

    try std.testing.expect(outcome.result != null);
    try std.testing.expect(!outcome.diagnostics.hasErrors());
    try std.testing.expectEqual(@as(u64, "completed-image".len), outcome.result.?.provenance.final_output.size);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, transaction_path, .{}));
    const output_digest = try hashPath(std.testing.allocator, io, output_path);
    try std.testing.expectEqualSlices(
        u8,
        &output_digest.bytes,
        &outcome.result.?.provenance.final_output.sha256.bytes,
    );
}

test "plan JSON renders identifiers as stable strings" {
    const request = validRequest();
    var resolved = try resolve(std.testing.allocator, &request, .{ .host_architecture = .x86_64 });
    defer resolved.deinit(std.testing.allocator);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writePlanJson(&resolved.plan.?, &output.writer);
    const json = output.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plan_hash\": \"") != null);
}
