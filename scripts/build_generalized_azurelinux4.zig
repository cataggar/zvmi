//! Build a minimal generalized Azure Linux 4 Gen2 QCOW2 image.
//!
//! Equivalent to scripts/build-generalized-azurelinux4.py but implemented as
//! native Zig 0.16 code. Invoked via `zig build generalized-azurelinux4 -- [args]`
//! rather than directly; the build system passes pre-built tool paths so this
//! binary does not invoke `zig build` internally.
//!
//! CLI arguments accepted:
//!   --architecture <arch> Azure Linux guest architecture (injected by build.zig)
//!   --iso <path>        Architecture-matched Azure Linux 4 ISO (downloaded if omitted)
//!   --output <path>     Output QCOW2 path (architecture-specific default)
//!   --size <size>       Disk size (default: 1184M)
//!   --work-dir <dir>    Working directory (architecture-specific default)
//!
//! Arguments injected automatically by build.zig:
//!   --zvmi <path>       Built native zvmi executable
//!   --zvminit <path>    Built guest zvminit binary
//!   --azagent <path>    Built guest azagent binary
//!   --preload <path>    Built zstd_max_preload.so shared library

const std = @import("std");
const builtin = @import("builtin");
const zvmi = @import("zvmi");
const oci = zvmi.oci;
const artifact_pipeline = zvmi.artifact_pipeline;

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;
const linux = std.os.linux;

// ─── constants ───────────────────────────────────────────────────────────────

const base_image = "azurelinux-beta/base/core";
const base_tag = "4.0";
const mcr_base = "https://mcr.microsoft.com/v2";
const AzureLinuxArchitecture = zvmi.bootconfig.Architecture;

/// All target-dependent Azure Linux core-image inputs and output conventions.
/// Keeping them together prevents a guest architecture from being selected in
/// one stage while another stage silently retains x86_64 defaults.
const ArchitectureDescriptor = struct {
    architecture: AzureLinuxArchitecture,
    target_cpu: std.Target.Cpu.Arch,
    oci_architecture: []const u8,
    dnf_architecture: []const u8,
    iso_url: []const u8,
    iso_name: []const u8,
    iso_sha256: []const u8,
    base_manifest_digest: []const u8,
    signing_key_path: []const u8,
    systemd_boot_rpm_name: []const u8,
    systemd_boot_rpm_url: []const u8,
    systemd_boot_rpm_sha256: []const u8,
    systemd_boot_stub_path: []const u8,
    fallback_efi_path: []const u8,
    uki_pe_machine: u16,
    root_role: zvmi.layout.PartitionRole,
    root_type_guid: zvmi.guid.Guid,
    serial_console: []const u8,
    extra_kernel_options: []const u8,
    binfmt_registration_name: []const u8,
    binfmt_registration_path: [:0]const u8,
    binfmt_static_name: []const u8,
    elf_file_marker: []const u8,
    default_output_path: []const u8,
    default_work_dir: []const u8,
};

const x86_64 = ArchitectureDescriptor{
    .architecture = .x86_64,
    .target_cpu = .x86_64,
    .oci_architecture = "amd64",
    .dnf_architecture = "x86_64",
    .iso_url = "https://aka.ms/azurelinux-4.0-x86_64.iso",
    .iso_name = "AzureLinux-4.0-x86_64.iso",
    // Official Azure Linux checksum resolved from the aka.ms endpoint on
    // 2026-07-17. Pinning it prevents a moving endpoint changing the recipe.
    .iso_sha256 = "d98f7d1ffaa916de7c9f66ffdadb150c174da691509e760835709ffa7829ca48",
    .base_manifest_digest = "sha256:9070b05147f01e5a4bac47723c95f2555e11b9d3324c1df1910ff3545b7ce319",
    .signing_key_path = "etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-4.0-x86_64",
    .systemd_boot_rpm_name = "systemd-boot-unsigned-258.4-4.azl4.x86_64.rpm",
    .systemd_boot_rpm_url = "https://packages.microsoft.com/azurelinux/4.0/beta/base/x86_64/Packages/s/systemd-boot-unsigned-258.4-4.azl4.x86_64.rpm",
    .systemd_boot_rpm_sha256 = "85dd3ac0c532bceb09fc0a85c6568c51fc4ee84e0c478d1302b7a2d84e1bea5c",
    .systemd_boot_stub_path = "usr/lib/systemd/boot/efi/linuxx64.efi.stub",
    .fallback_efi_path = "EFI/BOOT/BOOTX64.EFI",
    .uki_pe_machine = 0x8664,
    .root_role = .root_x86_64,
    .root_type_guid = zvmi.guid.linux_root_x86_64,
    .serial_console = "console=ttyS0,115200n8",
    .extra_kernel_options = "init=/sbin/zvminit zvminit.mode=persistent zvminit.azure=auto console=tty0 console=ttyS0,115200n8",
    .binfmt_registration_name = "qemu-x86_64",
    .binfmt_registration_path = "/proc/sys/fs/binfmt_misc/qemu-x86_64",
    .binfmt_static_name = "qemu-x86_64-static",
    .elf_file_marker = "x86-64",
    .default_output_path = "AzureLinux-4.0-x86_64.core.qcow2",
    .default_work_dir = ".scratch/azurelinux4-core-x86_64",
};

const aarch64 = ArchitectureDescriptor{
    .architecture = .aarch64,
    .target_cpu = .aarch64,
    .oci_architecture = "arm64",
    .dnf_architecture = "aarch64",
    .iso_url = "https://aka.ms/azurelinux-4.0-aarch64.iso",
    .iso_name = "AzureLinux-4.0-aarch64.iso",
    // Official Azure Linux checksum resolved from the aka.ms endpoint on
    // 2026-07-17. Pinning it prevents a moving endpoint changing the recipe.
    .iso_sha256 = "762039fde64a59806750ee86ca98132fad4f9df02e7684490017cdfda0c55157",
    .base_manifest_digest = "sha256:e541db83a8511c25fa1dd989161263874b7395ddd588f5caaa25453ea4e23263",
    .signing_key_path = "etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-4.0-aarch64",
    .systemd_boot_rpm_name = "systemd-boot-unsigned-258.4-4.azl4.aarch64.rpm",
    .systemd_boot_rpm_url = "https://packages.microsoft.com/azurelinux/4.0/beta/base/aarch64/Packages/s/systemd-boot-unsigned-258.4-4.azl4.aarch64.rpm",
    .systemd_boot_rpm_sha256 = "65aefdef9bc55f71f43c18b738fc1a61eeedd9fea7d803f0b0b06467fb748991",
    .systemd_boot_stub_path = "usr/lib/systemd/boot/efi/linuxaa64.efi.stub",
    .fallback_efi_path = "EFI/BOOT/BOOTAA64.EFI",
    .uki_pe_machine = 0xaa64,
    .root_role = .root_aarch64,
    .root_type_guid = zvmi.guid.linux_root_aarch64,
    .serial_console = "console=ttyAMA0,115200n8",
    .extra_kernel_options = "init=/sbin/zvminit zvminit.mode=persistent zvminit.azure=auto console=tty0 console=ttyAMA0,115200n8",
    .binfmt_registration_name = "qemu-aarch64",
    .binfmt_registration_path = "/proc/sys/fs/binfmt_misc/qemu-aarch64",
    .binfmt_static_name = "qemu-aarch64-static",
    .elf_file_marker = "aarch64",
    .default_output_path = "AzureLinux-4.0-aarch64.core.qcow2",
    .default_work_dir = ".scratch/azurelinux4-core-aarch64",
};

fn architectureDescriptor(architecture: AzureLinuxArchitecture) *const ArchitectureDescriptor {
    return switch (architecture) {
        .x86_64 => &x86_64,
        .aarch64 => &aarch64,
    };
}

fn requireArchitecture(
    architecture: ?AzureLinuxArchitecture,
) error{MissingArchitecture}!*const ArchitectureDescriptor {
    return architectureDescriptor(architecture orelse return error.MissingArchitecture);
}

const systemd_boot_unsigned_rpm_max_bytes: u64 = 16 * 1024 * 1024;
const oci_manifest_type = "application/vnd.oci.image.manifest.v1+json";
const oci_index_type = "application/vnd.oci.image.index.v1+json";
const docker_manifest_type = "application/vnd.docker.distribution.manifest.v2+json";
const docker_index_type = "application/vnd.docker.distribution.manifest.list.v2+json";
const zvmi_max_layer_bytes: u64 = 128 * 1024 * 1024;
const iso_max_bytes: u64 = 2 * 1024 * 1024 * 1024;
const accept_header = oci_index_type ++ ", " ++ docker_index_type ++ ", " ++ oci_manifest_type ++ ", " ++ docker_manifest_type;
const generalized_esp_size_bytes: u64 = 512 * 1024 * 1024;
const generalized_esp_size_arg = "512M";
const required_rootfs_files = [_][]const u8{
    "usr/bin/bash",
    "usr/bin/azagent",
    "usr/bin/zvminit",
    "usr/bin/sshd",
};
const zvminit_symlink_paths = [_][]const u8{
    "usr/bin/init",
    "usr/bin/poweroff",
    "usr/bin/reboot",
    "usr/bin/shutdown",
};

// ─── subprocess helpers ──────────────────────────────────────────────────────

/// Print "+  argv[0] argv[1] ..." then run the command inheriting stdin/stdout/stderr.
fn run(gpa: Allocator, io: Io, argv: []const []const u8) !void {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    try line.writer.print("+ ", .{});
    for (argv, 0..) |a, i| {
        if (i > 0) try line.writer.print(" ", .{});
        try line.writer.print("{s}", .{a});
    }
    const s = try line.toOwnedSlice();
    defer gpa.free(s);
    std.debug.print("{s}\n", .{s});

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("error: '{s}' exited with code {d}\n", .{ argv[0], code });
            return error.CommandFailed;
        },
        else => {
            std.debug.print("error: '{s}' terminated abnormally\n", .{argv[0]});
            return error.CommandFailed;
        },
    }
}

/// Like `run` but prepends "sudo".
fn sudo(gpa: Allocator, io: Io, argv: []const []const u8) !void {
    const full = try gpa.alloc([]const u8, argv.len + 1);
    defer gpa.free(full);
    full[0] = "sudo";
    @memcpy(full[1..], argv);
    try run(gpa, io, full);
}

/// Run command, capture stdout. Returns owned bytes (caller frees).
/// Fails if exit code is non-zero.
fn capture(gpa: Allocator, io: Io, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            gpa.free(result.stdout);
            std.debug.print("error: '{s}' exited with code {d}\n", .{ argv[0], code });
            return error.CommandFailed;
        },
        else => {
            gpa.free(result.stdout);
            return error.CommandFailed;
        },
    }
    return result.stdout;
}

fn readPseudoFile(gpa: Allocator, path: [:0]const u8) ![]u8 {
    const open_rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(open_rc) != .SUCCESS) return error.PseudoFileOpenFailed;
    const fd: linux.fd_t = @intCast(open_rc);
    defer _ = linux.close(fd);

    var content = std.array_list.Managed(u8).init(gpa);
    errdefer content.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const read_rc = linux.read(fd, &buf, buf.len);
        if (linux.errno(read_rc) != .SUCCESS) return error.PseudoFileReadFailed;
        if (read_rc == 0) break;
        try content.appendSlice(buf[0..read_rc]);
    }
    return content.toOwnedSlice();
}

// ─── sha256 helpers ──────────────────────────────────────────────────────────

/// SHA-256 of `bytes`, returned as lowercase hex (64 chars).
pub fn sha256Bytes(bytes: []const u8) [64]u8 {
    return artifact_pipeline.formatSha256(
        artifact_pipeline.sha256Bytes(bytes),
    );
}

/// SHA-256 hex of the file at `path`.  Streams in 64 KiB chunks.
fn sha256File(io: Io, path: []const u8) ![64]u8 {
    return artifact_pipeline.formatSha256(
        (try artifact_pipeline.hashFile(io, path)).sha256,
    );
}

fn systemdBootRpmCachePath(
    gpa: Allocator,
    work_dir: []const u8,
    architecture: *const ArchitectureDescriptor,
) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/downloads/{s}", .{ work_dir, architecture.systemd_boot_rpm_name });
}

fn isRegularNonemptyFile(kind: Io.File.Kind, size: u64) bool {
    return kind == .file and size != 0;
}

// ─── path safety ─────────────────────────────────────────────────────────────

/// Strip leading "./" and "/" from an OCI tar member name and validate that
/// no ".." components remain.  Returns null for empty/root entries.
pub fn safeLayerPath(name: []const u8) error{UnsafeLayerPath}!?[]const u8 {
    var s = name;
    if (std.mem.startsWith(u8, s, "./")) s = s[2..];
    while (std.mem.startsWith(u8, s, "/")) s = s[1..];
    if (s.len == 0) return null;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.UnsafeLayerPath;
    }
    return s;
}

/// Parse a "sha256:<hex>" or bare 64-char hex digest.
/// Returns the 64-char hex portion (not owned — points into `digest`).
pub fn parseDigestHex(digest: []const u8) error{InvalidDigest}![]const u8 {
    const hex = if (std.mem.startsWith(u8, digest, "sha256:"))
        digest["sha256:".len..]
    else
        digest;
    _ = artifact_pipeline.parseSha256(digest) catch
        return error.InvalidDigest;
    return hex;
}

// ─── OCI manifest resolution ─────────────────────────────────────────────────

/// Walk the parsed JSON index and return an owned copy of the requested Linux
/// platform manifest digest.
pub fn selectLinuxManifest(
    gpa: Allocator,
    index_doc: std.json.Value,
    oci_architecture: []const u8,
) ![]u8 {
    const manifests_val = switch (index_doc) {
        .object => |obj| obj.get("manifests") orelse return error.NoLinuxArchitectureManifest,
        else => return error.NoLinuxArchitectureManifest,
    };
    const items = switch (manifests_val) {
        .array => |a| a.items,
        else => return error.NoLinuxArchitectureManifest,
    };
    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const platform = switch (obj.get("platform") orelse continue) {
            .object => |p| p,
            else => continue,
        };
        const os_str = switch (platform.get("os") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const arch_str = switch (platform.get("architecture") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, os_str, "linux")) continue;
        if (!std.mem.eql(u8, arch_str, oci_architecture)) continue;
        const dig = switch (obj.get("digest") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        return gpa.dupe(u8, dig);
    }
    return error.NoLinuxArchitectureManifest;
}

/// Fetch `url` with optional `Accept:` header via curl.
/// Returns owned stdout bytes on HTTP 200; caller frees.
fn fetchBytes(gpa: Allocator, io: Io, url: []const u8, accept: ?[]const u8) ![]u8 {
    if (accept) |a| {
        const hdr = try std.fmt.allocPrint(gpa, "Accept: {s}", .{a});
        defer gpa.free(hdr);
        return capture(gpa, io, &.{ "curl", "-fsSL", "-H", hdr, url });
    }
    return capture(gpa, io, &.{ "curl", "-fsSL", url });
}

/// Resolve `repository:reference` on MCR, following an index to the requested
/// Linux architecture if needed.
/// Returns manifest JSON bytes and the manifest's sha256 digest (both caller-owned).
fn resolveManifest(
    gpa: Allocator,
    io: Io,
    repository: []const u8,
    reference: []const u8,
    architecture: *const ArchitectureDescriptor,
) !struct { bytes: []u8, digest: []u8 } {
    const url = try std.fmt.allocPrint(gpa, "{s}/{s}/manifests/{s}", .{ mcr_base, repository, reference });
    defer gpa.free(url);

    const manifest_bytes = try fetchBytes(gpa, io, url, accept_header);
    var return_manifest_bytes = false;
    defer if (!return_manifest_bytes) gpa.free(manifest_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, manifest_bytes, .{});
    defer parsed.deinit();

    const media_type: []const u8 = switch (parsed.value) {
        .object => |obj| switch (obj.get("mediaType") orelse .null) {
            .string => |s| s,
            else => "",
        },
        else => "",
    };

    const is_index = std.mem.eql(u8, media_type, oci_index_type) or
        std.mem.eql(u8, media_type, docker_index_type);

    if (!is_index) {
        const hex = sha256Bytes(manifest_bytes);
        const digest = try std.fmt.allocPrint(gpa, "sha256:{s}", .{&hex});
        return_manifest_bytes = true;
        return .{ .bytes = manifest_bytes, .digest = digest };
    }

    // It's an index — find and fetch the requested Linux platform manifest.
    const platform_digest = try selectLinuxManifest(gpa, parsed.value, architecture.oci_architecture);
    defer gpa.free(platform_digest);

    const m_url = try std.fmt.allocPrint(gpa, "{s}/{s}/manifests/{s}", .{ mcr_base, repository, platform_digest });
    defer gpa.free(m_url);

    const platform_bytes = try fetchBytes(gpa, io, m_url, accept_header);
    errdefer gpa.free(platform_bytes);

    const actual_hex = sha256Bytes(platform_bytes);
    const actual_digest = try std.fmt.allocPrint(gpa, "sha256:{s}", .{&actual_hex});
    defer gpa.free(actual_digest);

    if (!std.mem.eql(u8, actual_digest, platform_digest)) {
        std.debug.print("error: manifest digest mismatch: expected {s}, got {s}\n", .{ platform_digest, actual_digest });
        return error.DigestMismatch;
    }

    const return_digest = try std.fmt.allocPrint(gpa, "sha256:{s}", .{&actual_hex});
    return .{ .bytes = platform_bytes, .digest = return_digest };
}

/// Download a single OCI blob to `dest_path`, verifying sha256.
/// Skips if the file already exists with the correct digest.
fn downloadBlob(
    gpa: Allocator,
    io: Io,
    repository: []const u8,
    digest: []const u8,
    dest_path: []const u8,
) !void {
    const expected = try parseDigestHex(digest);

    // Create parent directory.
    if (std.fs.path.dirname(dest_path)) |parent| {
        Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const url = try std.fmt.allocPrint(gpa, "{s}/{s}/blobs/{s}", .{ mcr_base, repository, digest });
    defer gpa.free(url);

    const expected_digest = artifact_pipeline.parseSha256(digest) catch
        return error.InvalidDigest;
    var curl = artifact_pipeline.CurlDownloader{
        .executable_path = "curl",
    };
    const acquired = artifact_pipeline.acquireVerified(
        gpa,
        io,
        .{
            .url = url,
            .destination_path = dest_path,
            .expected_sha256 = expected_digest,
            .max_size = zvmi_max_layer_bytes,
        },
        curl.downloader(),
    ) catch |err| switch (err) {
        error.ChecksumMismatch => {
            std.debug.print("error: blob digest mismatch: expected {s}\n", .{expected});
            return error.DigestMismatch;
        },
        else => return err,
    };
    if (acquired.reused_cache) {
        std.debug.print("  blob {s}...: cached\n", .{expected[0..12]});
    } else {
        std.debug.print("  blob {s}...: verified\n", .{expected[0..12]});
    }
}

/// Acquire the pinned systemd UKI stub RPM in the work-directory cache.
fn acquireSystemdBootRpm(
    gpa: Allocator,
    io: Io,
    work_dir: []const u8,
    architecture: *const ArchitectureDescriptor,
) ![:0]u8 {
    const cache_path = try systemdBootRpmCachePath(gpa, work_dir, architecture);
    defer gpa.free(cache_path);
    const cache_dir = std.fs.path.dirname(cache_path) orelse return error.InvalidCachePath;
    try Dir.cwd().createDirPath(io, cache_dir);

    const expected_digest = artifact_pipeline.parseSha256(architecture.systemd_boot_rpm_sha256) catch
        return error.InvalidSystemdBootRpmChecksum;
    var curl = artifact_pipeline.CurlDownloader{
        .executable_path = "curl",
    };
    const acquired = try artifact_pipeline.acquireVerified(
        gpa,
        io,
        .{
            .url = architecture.systemd_boot_rpm_url,
            .destination_path = cache_path,
            .expected_sha256 = expected_digest,
            .max_size = systemd_boot_unsigned_rpm_max_bytes,
        },
        curl.downloader(),
    );
    if (acquired.reused_cache) {
        std.debug.print("Systemd boot RPM cached at {s}\n", .{cache_path});
    } else {
        std.debug.print("Systemd boot RPM downloaded and verified: {s}\n", .{cache_path});
    }
    return Dir.cwd().realPathFileAlloc(io, cache_path, gpa);
}

// ─── layer extraction ────────────────────────────────────────────────────────

/// Extract OCI layer `layer_path` into `rootfs_path`, applying whiteouts.
fn extractLayer(gpa: Allocator, io: Io, layer_path: []const u8, rootfs_path: []const u8) !void {
    // List the layer members to find whiteout entries.
    const listing = try capture(gpa, io, &.{ "tar", "-tzf", layer_path });
    defer gpa.free(listing);

    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw_name| {
        if (raw_name.len == 0) continue;
        const rel = (try safeLayerPath(raw_name)) orelse continue;
        const basename = std.fs.path.basename(rel);

        if (std.mem.eql(u8, basename, ".wh..wh..opq")) {
            // Opaque whiteout: remove all children of the parent directory.
            const parent_rel = std.fs.path.dirname(rel) orelse ".";
            const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rootfs_path, parent_rel });
            defer gpa.free(target);
            if (Dir.cwd().statFile(io, target, .{})) |_| {
                try sudo(gpa, io, &.{
                    "find",  target, "-mindepth", "1",  "-maxdepth", "1",
                    "-exec", "rm",   "-rf",       "--", "{}",        "+",
                });
            } else |_| {}
        } else if (std.mem.startsWith(u8, basename, ".wh.")) {
            const real_name = basename[".wh.".len..];
            const parent_rel = std.fs.path.dirname(rel) orelse ".";
            const target = if (std.mem.eql(u8, parent_rel, "."))
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rootfs_path, real_name })
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ rootfs_path, parent_rel, real_name });
            defer gpa.free(target);
            try sudo(gpa, io, &.{ "rm", "-rf", "--", target });
        }
    }

    try sudo(gpa, io, &.{ "tar", "-xzf", layer_path, "-C", rootfs_path, "--numeric-owner" });
    try sudo(gpa, io, &.{ "find", rootfs_path, "-name", ".wh.*", "-delete" });
}

// ─── rootfs pull ─────────────────────────────────────────────────────────────

/// Pull base image layers into `rootfs_path`.  Returns owned manifest digest.
fn pullRootfs(
    gpa: Allocator,
    io: Io,
    work_dir: []const u8,
    rootfs_path: []const u8,
    architecture: *const ArchitectureDescriptor,
) ![]u8 {
    std.debug.print("Resolving mcr.microsoft.com/{s}:{s}...\n", .{ base_image, base_tag });
    const manifest = try resolveManifest(gpa, io, base_image, base_tag, architecture);
    defer gpa.free(manifest.bytes);
    std.debug.print("Resolved to {s}\n", .{manifest.digest});
    if (!std.mem.eql(u8, manifest.digest, architecture.base_manifest_digest)) {
        std.debug.print(
            "error: {s} {s} manifest changed: expected {s}, got {s}\n",
            .{ architecture.oci_architecture, base_tag, architecture.base_manifest_digest, manifest.digest },
        );
        return error.BaseManifestDigestMismatch;
    }

    if (Dir.cwd().statFile(io, rootfs_path, .{})) |_| {
        try sudo(gpa, io, &.{ "rm", "-rf", "--", rootfs_path });
    } else |_| {}
    try Dir.cwd().createDirPath(io, rootfs_path);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, manifest.bytes, .{});
    defer parsed.deinit();

    const layers_val = switch (parsed.value) {
        .object => |obj| obj.get("layers") orelse return error.MissingLayers,
        else => return error.MissingLayers,
    };
    const layers = switch (layers_val) {
        .array => |a| a.items,
        else => return error.MissingLayers,
    };

    const blobs_dir = try std.fmt.allocPrint(gpa, "{s}/downloads/blobs", .{work_dir});
    defer gpa.free(blobs_dir);
    try Dir.cwd().createDirPath(io, blobs_dir);

    for (layers) |layer_item| {
        const layer_obj = switch (layer_item) {
            .object => |o| o,
            else => return error.InvalidLayer,
        };
        const digest = switch (layer_obj.get("digest") orelse return error.MissingDigest) {
            .string => |s| s,
            else => return error.MissingDigest,
        };
        const hex = try parseDigestHex(digest);
        const layer_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ blobs_dir, hex });
        defer gpa.free(layer_path);
        try downloadBlob(gpa, io, base_image, digest, layer_path);
        std.debug.print("Extracting layer {s}...\n", .{hex[0..12]});
        try extractLayer(gpa, io, layer_path, rootfs_path);
    }

    return manifest.digest;
}

// ─── guest content installation ──────────────────────────────────────────────

/// Write a file owned by root inside `rootfs_path`.
fn writeRootFile(
    gpa: Allocator,
    io: Io,
    rootfs_path: []const u8,
    work_dir: []const u8,
    relative_path: []const u8,
    content: []const u8,
    mode: []const u8,
) !void {
    const basename = std.fs.path.basename(relative_path);
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}/{s}.tmp", .{ work_dir, basename });
    defer gpa.free(tmp_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = content });
    const dest = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rootfs_path, relative_path });
    defer gpa.free(dest);
    try sudo(gpa, io, &.{ "install", "-D", "-o", "root", "-g", "root", "-m", mode, tmp_path, dest });
    Dir.cwd().deleteFile(io, tmp_path) catch {};
}

/// Install packages, binaries, and configuration into the rootfs.
fn installGuestContent(
    gpa: Allocator,
    io: Io,
    rootfs_path: []const u8,
    work_dir: []const u8,
    zvminit_path: []const u8,
    azagent_path: []const u8,
    systemd_boot_rpm_path: []const u8,
    architecture: *const ArchitectureDescriptor,
) !void {
    // On a non-native builder, put the registered static interpreter in the
    // target root just for RPM scriptlets, then remove it before layering.
    const target_is_native = builtin.target.cpu.arch == architecture.target_cpu;
    var binfmt_interpreter: ?[]u8 = null;
    defer if (binfmt_interpreter) |b| gpa.free(b);

    if (!target_is_native) {
        const reg = readPseudoFile(gpa, architecture.binfmt_registration_path) catch |err| {
            std.debug.print(
                "error: {s} binfmt not available ({s}); install {s}\n",
                .{ architecture.binfmt_registration_name, @errorName(err), architecture.binfmt_static_name },
            );
            return error.BinfmtMissing;
        };
        defer gpa.free(reg);
        var reg_lines = std.mem.splitScalar(u8, reg, '\n');
        if (!std.mem.eql(u8, reg_lines.next() orelse "", "enabled")) {
            std.debug.print("error: {s} binfmt registration is disabled\n", .{architecture.binfmt_registration_name});
            return error.BinfmtDisabled;
        }
        var interp_path: ?[]const u8 = null;
        while (reg_lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "interpreter ")) {
                interp_path = line["interpreter ".len..];
                break;
            }
        }
        const interp = interp_path orelse {
            std.debug.print("error: no interpreter line in binfmt registration\n", .{});
            return error.BinfmtMissing;
        };
        binfmt_interpreter = try gpa.dupe(u8, interp);

        const qemu_static_bytes = try capture(gpa, io, &.{ "which", architecture.binfmt_static_name });
        defer gpa.free(qemu_static_bytes);
        const qemu_static = std.mem.trimEnd(u8, qemu_static_bytes, "\n\r ");
        const interp_rel = std.mem.trimStart(u8, interp, "/");
        const guest_interp = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rootfs_path, interp_rel });
        defer gpa.free(guest_interp);
        try sudo(gpa, io, &.{ "install", "-D", "-m", "0755", qemu_static, guest_interp });
    }

    // Copy RPM signing key to host so dnf can verify it from outside the chroot.
    const signing_key_guest = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rootfs_path, architecture.signing_key_path });
    defer gpa.free(signing_key_guest);
    const host_key = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}",
        .{ work_dir, std.fs.path.basename(architecture.signing_key_path) },
    );
    defer gpa.free(host_key);
    try sudo(gpa, io, &.{ "install", "-m", "0644", signing_key_guest, host_key });

    const gpgkey_opt = try std.fmt.allocPrint(gpa, "--setopt=azurelinux-base.gpgkey=file://{s}", .{host_key});
    defer gpa.free(gpgkey_opt);
    const forcearch_opt = try std.fmt.allocPrint(gpa, "--forcearch={s}", .{architecture.dnf_architecture});
    defer gpa.free(forcearch_opt);
    try sudo(gpa, io, &.{
        "dnf",                              "-y",
        "--installroot",                    rootfs_path,
        "--releasever=4.0",                 forcearch_opt,
        "--repo=azurelinux-base",           gpgkey_opt,
        "--setopt=install_weak_deps=False", "install",
        "openssh-server",                   "sudo",
    });

    // Install the pinned local RPM in a separate, repository-free transaction.
    try sudo(gpa, io, &.{
        "dnf",              "-y",
        "--installroot",    rootfs_path,
        "--releasever=4.0", forcearch_opt,
        "--disablerepo=*",  "--setopt=install_weak_deps=False",
        "install",          systemd_boot_rpm_path,
    });
    const stub_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rootfs_path, architecture.systemd_boot_stub_path });
    defer gpa.free(stub_path);
    const stub_stat = try Dir.cwd().statFile(io, stub_path, .{ .follow_symlinks = false });
    if (!isRegularNonemptyFile(stub_stat.kind, stub_stat.size)) {
        std.debug.print("error: installed systemd boot stub is not a nonempty regular file: {s}\n", .{stub_path});
        return error.InvalidSystemdBootStub;
    }

    // Install zvminit and relative command symlinks.
    const sbin_zvminit = try std.fmt.allocPrint(gpa, "{s}/sbin/zvminit", .{rootfs_path});
    defer gpa.free(sbin_zvminit);
    try sudo(gpa, io, &.{ "install", "-m", "0755", zvminit_path, sbin_zvminit });
    for (&[_][]const u8{ "init", "poweroff", "reboot", "shutdown" }) |cmd| {
        const link = try std.fmt.allocPrint(gpa, "{s}/sbin/{s}", .{ rootfs_path, cmd });
        defer gpa.free(link);
        try sudo(gpa, io, &.{ "rm", "-f", link });
        try sudo(gpa, io, &.{ "ln", "-s", "zvminit", link });
    }

    // Install azagent.
    const azagent_dest = try std.fmt.allocPrint(gpa, "{s}/usr/sbin/azagent", .{rootfs_path});
    defer gpa.free(azagent_dest);
    try sudo(gpa, io, &.{ "install", "-m", "0755", azagent_path, azagent_dest });

    // Write sshd config drop-in.
    try writeRootFile(gpa, io, rootfs_path, work_dir, "etc/ssh/sshd_config.d/10-zvminit.conf", "PasswordAuthentication no\n" ++
        "PermitEmptyPasswords no\n" ++
        "PubkeyAuthentication yes\n", "0600");

    // Write waagent.conf.
    try writeRootFile(gpa, io, rootfs_path, work_dir, "etc/waagent.conf", "ResourceDisk.Format=y\n" ++
        "ResourceDisk.Filesystem=ext4\n" ++
        "ResourceDisk.MountPoint=/d\n" ++
        "ResourceDisk.EnableSwap=n\n" ++
        "DataDisk.Mount=y\n", "0644");

    // Verify sshd config and packages.
    try sudo(gpa, io, &.{ "chroot", rootfs_path, "/usr/bin/rpm", "-q", "openssh-server", "sudo" });
    try sudo(gpa, io, &.{ "chroot", rootfs_path, "/usr/bin/ssh-keygen", "-A" });
    try sudo(gpa, io, &.{ "chroot", rootfs_path, "/usr/sbin/sshd", "-t" });

    // Generalize: remove SSH host keys and machine identity.
    const etc_ssh = try std.fmt.allocPrint(gpa, "{s}/etc/ssh", .{rootfs_path});
    defer gpa.free(etc_ssh);
    try sudo(gpa, io, &.{ "find", etc_ssh, "-maxdepth", "1", "-name", "ssh_host_*", "-delete" });

    const hostname_f = try std.fmt.allocPrint(gpa, "{s}/etc/hostname", .{rootfs_path});
    defer gpa.free(hostname_f);
    const dbus_mid = try std.fmt.allocPrint(gpa, "{s}/var/lib/dbus/machine-id", .{rootfs_path});
    defer gpa.free(dbus_mid);
    const azagent_state = try std.fmt.allocPrint(gpa, "{s}/var/lib/azagent", .{rootfs_path});
    defer gpa.free(azagent_state);
    const machine_id = try std.fmt.allocPrint(gpa, "{s}/etc/machine-id", .{rootfs_path});
    defer gpa.free(machine_id);
    try sudo(gpa, io, &.{ "rm", "-f", hostname_f, dbus_mid });
    try sudo(gpa, io, &.{ "rm", "-rf", azagent_state });
    const home_dir = try std.fmt.allocPrint(gpa, "{s}/home", .{rootfs_path});
    defer gpa.free(home_dir);
    const var_lib = try std.fmt.allocPrint(gpa, "{s}/var/lib", .{rootfs_path});
    defer gpa.free(var_lib);
    try sudo(gpa, io, &.{ "install", "-d", "-m", "0755", home_dir, var_lib });
    try sudo(gpa, io, &.{ "truncate", "-s", "0", machine_id });

    // Remove binfmt interpreter from guest.
    if (binfmt_interpreter) |interp| {
        const interp_rel = std.mem.trimStart(u8, interp, "/");
        const guest_interp = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rootfs_path, interp_rel });
        defer gpa.free(guest_interp);
        try sudo(gpa, io, &.{ "rm", "-f", guest_interp });
    }

    // Clean dnf caches.
    try sudo(gpa, io, &.{
        "dnf",         "--installroot",          rootfs_path, "--releasever=4.0",
        forcearch_opt, "--repo=azurelinux-base", "clean",     "all",
    });
    const dnf_cache = try std.fmt.allocPrint(gpa, "{s}/var/cache/dnf", .{rootfs_path});
    defer gpa.free(dnf_cache);
    const dnf_log = try std.fmt.allocPrint(gpa, "{s}/var/log/dnf.log", .{rootfs_path});
    defer gpa.free(dnf_log);
    try sudo(gpa, io, &.{ "rm", "-rf", dnf_cache });
    try sudo(gpa, io, &.{ "rm", "-f", dnf_log });

    try run(gpa, io, &.{ "file", sbin_zvminit, azagent_dest });
}

// ─── OCI layout creation ─────────────────────────────────────────────────────

/// Write `bytes` as a blob under `blobs_dir`.  Returns heap-allocated "sha256:<hex>".
fn writeBlobBytesAlloc(gpa: Allocator, io: Io, blobs_dir: []const u8, bytes: []const u8) ![]u8 {
    const hex = sha256Bytes(bytes);
    const blob_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ blobs_dir, &hex });
    defer gpa.free(blob_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = blob_path, .data = bytes });
    return std.fmt.allocPrint(gpa, "sha256:{s}", .{&hex});
}

/// Create a gzip-compressed, deterministic tar layer from a rootfs subset.
/// Returns the diff_id ("sha256:<hex>", caller frees) and writes the
/// compressed blob to `blobs_dir`.
/// Also returns the layer descriptor as a heap-allocated JSON object (caller frees strings).
const LayerResult = struct {
    diff_id: []u8, // sha256 of uncompressed tar
    compressed_digest: []u8, // sha256 of gz
    compressed_size: u64,
};

fn gzipFile(io: Io, source_path: []const u8, output_path: []const u8) !u64 {
    var source_file = try Dir.cwd().openFile(io, source_path, .{});
    defer source_file.close(io);

    var output_file = try Dir.cwd().createFile(io, output_path, .{});
    errdefer {
        output_file.close(io);
        Dir.cwd().deleteFile(io, output_path) catch {};
    }
    defer output_file.close(io);

    var write_buf: [65536]u8 = undefined;
    var output_writer = output_file.writer(io, &write_buf);
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&output_writer.interface, &history, .gzip, .level_9);

    var read_buf: [65536]u8 = undefined;
    var source_reader = source_file.reader(io, &read_buf);
    const streamed = try source_reader.interface.streamRemaining(&compressor.writer);
    try compressor.finish();
    try output_writer.interface.flush();
    return @intCast(streamed);
}

fn createOciLayer(
    gpa: Allocator,
    io: Io,
    work_dir: []const u8,
    rootfs_path: []const u8,
    blobs_dir: []const u8,
    index: usize,
    includes: []const []const u8,
    excludes: []const []const u8,
) !LayerResult {
    var tar_path_buf: [512]u8 = undefined;
    var gz_path_buf: [512]u8 = undefined;
    const layer_tar = try std.fmt.bufPrint(&tar_path_buf, "{s}/rootfs-{d}.tar", .{ work_dir, index });
    const layer_gz = try std.fmt.bufPrint(&gz_path_buf, "{s}/rootfs-{d}.tar.gz", .{ work_dir, index });

    // Build tar command (requires sudo because rootfs has root-owned files).
    var argv = std.array_list.Managed([]const u8).init(gpa);
    defer argv.deinit();
    try argv.appendSlice(&.{
        "tar",          "--sort=name",                            "--mtime=@0", "--numeric-owner",
        "--format=pax", "--pax-option=delete=atime,delete=ctime",
    });
    for (excludes) |e| {
        const flag = try std.fmt.allocPrint(gpa, "--exclude={s}", .{e});
        defer gpa.free(flag);
        try argv.append(try gpa.dupe(u8, flag));
    }
    try argv.appendSlice(&.{ "-C", rootfs_path, "-cf", layer_tar });
    try argv.appendSlice(includes);
    try sudo(gpa, io, argv.items);

    // Free the --exclude=... strings we duped.
    const exclude_start = 6; // after the fixed args
    for (argv.items[exclude_start .. exclude_start + excludes.len]) |s| gpa.free(s);

    // Re-own the tar so we can read it.
    {
        var uid_buf: [32]u8 = undefined;
        var gid_buf: [32]u8 = undefined;
        const uid_str = try std.fmt.bufPrint(&uid_buf, "{d}", .{std.os.linux.getuid()});
        const gid_str = try std.fmt.bufPrint(&gid_buf, "{d}", .{std.os.linux.getgid()});
        const own = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ uid_str, gid_str });
        defer gpa.free(own);
        try sudo(gpa, io, &.{ "chown", own, layer_tar });
    }

    // Enforce zvmi's per-layer size cap.
    const tar_stat = try Dir.cwd().statFile(io, layer_tar, .{});
    if (tar_stat.size > zvmi_max_layer_bytes) {
        std.debug.print("error: layer {d} ({d} B) exceeds zvmi's {d}-B limit\n", .{
            index, tar_stat.size, zvmi_max_layer_bytes,
        });
        return error.LayerTooLarge;
    }

    // diff_id = sha256 of uncompressed tar.
    const diff_hex = try sha256File(io, layer_tar);
    const diff_id = try std.fmt.allocPrint(gpa, "sha256:{s}", .{&diff_hex});
    errdefer gpa.free(diff_id);

    // Zig's Reader.stream() copies only one chunk. Use streamRemaining() so
    // the OCI layer contains the complete tar rather than its first 64 KiB.
    const streamed = try gzipFile(io, layer_tar, layer_gz);
    if (streamed != tar_stat.size) return error.IncompleteOciLayer;

    const gz_hex = try sha256File(io, layer_gz);
    const compressed_digest = try std.fmt.allocPrint(gpa, "sha256:{s}", .{&gz_hex});
    errdefer gpa.free(compressed_digest);
    const gz_stat = try Dir.cwd().statFile(io, layer_gz, .{});

    // Copy blob to blobs_dir.
    const blob_dest = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ blobs_dir, &gz_hex });
    defer gpa.free(blob_dest);
    try Dir.copyFile(Dir.cwd(), layer_gz, Dir.cwd(), blob_dest, io, .{});

    return .{
        .diff_id = diff_id,
        .compressed_digest = compressed_digest,
        .compressed_size = gz_stat.size,
    };
}

/// Build the OCI image layout directory.  Returns the layout path (caller frees).
fn createOciLayout(
    gpa: Allocator,
    io: Io,
    work_dir: []const u8,
    rootfs_path: []const u8,
    base_digest: []const u8,
    architecture: *const ArchitectureDescriptor,
) ![]u8 {
    const layout_dir = try std.fmt.allocPrint(gpa, "{s}/oci-generalized", .{work_dir});

    // Remove stale layout.
    if (Dir.cwd().statFile(io, layout_dir, .{})) |_| {
        try run(gpa, io, &.{ "rm", "-rf", "--", layout_dir });
    } else |_| {}
    const blobs_dir = try std.fmt.allocPrint(gpa, "{s}/blobs/sha256", .{layout_dir});
    defer gpa.free(blobs_dir);
    try Dir.cwd().createDirPath(io, blobs_dir);

    // List top-level rootfs entries, sorted.
    var entry_names = std.array_list.Managed([]u8).init(gpa);
    defer {
        for (entry_names.items) |e| gpa.free(e);
        entry_names.deinit();
    }
    {
        var root_dir = try Dir.cwd().openDir(io, rootfs_path, .{ .iterate = true });
        defer root_dir.close(io);
        var iter = root_dir.iterate();
        while (try iter.next(io)) |entry| {
            try entry_names.append(try gpa.dupe(u8, entry.name));
        }
    }
    std.mem.sortUnstable([]u8, entry_names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // Three-layer split: all-except-large-subtrees / usr/share / usr/lib64.
    const LayerSpec = struct {
        includes: []const []const u8,
        excludes: []const []const u8,
    };
    const layer_specs: []const LayerSpec = &.{
        .{ .includes = entry_names.items, .excludes = &.{ "usr/share", "usr/lib64" } },
        .{ .includes = &.{"usr/share"}, .excludes = &.{} },
        .{ .includes = &.{"usr/lib64"}, .excludes = &.{} },
    };

    var layer_descriptors = std.array_list.Managed(struct {
        digest: []u8,
        size: u64,
    }).init(gpa);
    defer {
        for (layer_descriptors.items) |d| gpa.free(d.digest);
        layer_descriptors.deinit();
    }
    var diff_ids = std.array_list.Managed([]u8).init(gpa);
    defer {
        for (diff_ids.items) |d| gpa.free(d);
        diff_ids.deinit();
    }

    for (layer_specs, 0..) |spec, i| {
        std.debug.print("Creating OCI layer {d}...\n", .{i});
        const lr = try createOciLayer(gpa, io, work_dir, rootfs_path, blobs_dir, i, spec.includes, spec.excludes);
        try layer_descriptors.append(.{ .digest = lr.compressed_digest, .size = lr.compressed_size });
        try diff_ids.append(lr.diff_id);
    }

    // Build timestamp.
    const ts = std.Io.Clock.real.now(io);
    const secs: u64 = @intCast(@divTrunc(ts.nanoseconds, 1_000_000_000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    const created_ts = try std.fmt.allocPrint(gpa, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,              md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
    defer gpa.free(created_ts);

    const history_comment = try std.fmt.allocPrint(gpa, "Based on mcr.microsoft.com/{s}:{s} ({s})", .{
        base_image, base_tag, base_digest,
    });
    defer gpa.free(history_comment);

    // Collect diff_id strings for the config.
    const diff_ids_slice = try gpa.alloc([]const u8, diff_ids.items.len);
    defer gpa.free(diff_ids_slice);
    for (diff_ids.items, diff_ids_slice) |s, *d| d.* = s;

    // Config JSON.
    const config = .{
        .architecture = architecture.oci_architecture,
        .config = .{
            .Entrypoint = &[_][]const u8{"/sbin/zvminit"},
            .Env = &[_][]const u8{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"},
        },
        .created = created_ts,
        .history = &[_]struct {
            comment: []const u8,
            created: []const u8,
            created_by: []const u8,
        }{
            .{
                .comment = history_comment,
                .created = created_ts,
                .created_by = "scripts/build_generalized_azurelinux4.zig",
            },
        },
        .os = @as([]const u8, "linux"),
        .rootfs = .{
            .diff_ids = diff_ids_slice,
            .type = @as([]const u8, "layers"),
        },
    };
    const config_json = try std.json.Stringify.valueAlloc(gpa, config, .{});
    defer gpa.free(config_json);
    const config_digest = try writeBlobBytesAlloc(gpa, io, blobs_dir, config_json);
    defer gpa.free(config_digest);

    // Build layer array for the manifest.
    const LayerDesc = struct {
        digest: []const u8,
        mediaType: []const u8,
        size: u64,
    };
    const layers_json_arr = try gpa.alloc(LayerDesc, layer_descriptors.items.len);
    defer gpa.free(layers_json_arr);
    for (layer_descriptors.items, layers_json_arr) |ld, *jl| {
        jl.* = .{
            .digest = ld.digest,
            .mediaType = "application/vnd.oci.image.layer.v1.tar+gzip",
            .size = ld.size,
        };
    }

    // Manifest JSON.
    const manifest = .{
        .config = .{
            .digest = config_digest,
            .mediaType = @as([]const u8, "application/vnd.oci.image.config.v1+json"),
            .size = config_json.len,
        },
        .layers = layers_json_arr,
        .mediaType = @as([]const u8, oci_manifest_type),
        .schemaVersion = @as(u64, 2),
    };
    const manifest_json = try std.json.Stringify.valueAlloc(gpa, manifest, .{});
    defer gpa.free(manifest_json);
    const manifest_digest = try writeBlobBytesAlloc(gpa, io, blobs_dir, manifest_json);
    defer gpa.free(manifest_digest);

    // oci-layout file.
    const oci_layout_path = try std.fmt.allocPrint(gpa, "{s}/oci-layout", .{layout_dir});
    defer gpa.free(oci_layout_path);
    try Dir.cwd().writeFile(io, .{
        .sub_path = oci_layout_path,
        .data = "{\"imageLayoutVersion\":\"1.0.0\"}\n",
    });

    // index.json.
    const index = .{
        .manifests = &[_]struct {
            annotations: struct {
                @"org.opencontainers.image.ref.name": []const u8,
            },
            digest: []const u8,
            mediaType: []const u8,
            size: usize,
        }{
            .{
                .annotations = .{ .@"org.opencontainers.image.ref.name" = "generalized" },
                .digest = manifest_digest,
                .mediaType = oci_manifest_type,
                .size = manifest_json.len,
            },
        },
        .schemaVersion = @as(u64, 2),
    };
    var index_buf: std.Io.Writer.Allocating = .init(gpa);
    defer index_buf.deinit();
    try std.json.Stringify.value(index, .{}, &index_buf.writer);
    try index_buf.writer.writeByte('\n');
    const index_json = try index_buf.toOwnedSlice();
    defer gpa.free(index_json);

    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.json", .{layout_dir});
    defer gpa.free(index_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = index_json });

    return layout_dir;
}

fn validateOsRelease(image: anytype) !void {
    const os_release = image.get("etc/os-release") orelse {
        std.debug.print("error: generated OCI layout is missing required rootfs path: /etc/os-release\n", .{});
        return error.IncompleteOciRootfs;
    };
    switch (os_release.kind) {
        .file => {},
        .symlink => {
            const target = os_release.link_name orelse "";
            if (!std.mem.eql(u8, target, "../usr/lib/os-release") and
                !std.mem.eql(u8, target, "/usr/lib/os-release"))
            {
                std.debug.print("error: generated OCI rootfs has unexpected /etc/os-release target: {s}\n", .{target});
                return error.IncompleteOciRootfs;
            }
            const target_entry = image.get("usr/lib/os-release") orelse {
                std.debug.print("error: generated OCI rootfs is missing /usr/lib/os-release\n", .{});
                return error.IncompleteOciRootfs;
            };
            if (target_entry.kind != .file) {
                std.debug.print("error: generated OCI rootfs path is not a file: /usr/lib/os-release\n", .{});
                return error.IncompleteOciRootfs;
            }
        },
        else => {
            std.debug.print("error: generated OCI rootfs path is not a file or symlink: /etc/os-release\n", .{});
            return error.IncompleteOciRootfs;
        },
    }
}

fn ociConfigArchitectureMatches(
    config_architecture: ?[]const u8,
    architecture: *const ArchitectureDescriptor,
) bool {
    return if (config_architecture) |value|
        std.mem.eql(u8, value, architecture.oci_architecture)
    else
        false;
}

fn validateGeneralizedOciLayout(
    gpa: Allocator,
    io: Io,
    layout_dir: []const u8,
    architecture: *const ArchitectureDescriptor,
) !void {
    var image = try oci.loadLayout(io, gpa, layout_dir, .{});
    defer image.deinit();

    const config_architecture = image.config.architecture orelse return error.MissingOciArchitecture;
    if (!ociConfigArchitectureMatches(config_architecture, architecture)) {
        std.debug.print(
            "error: generated OCI config has architecture {s}, expected {s}\n",
            .{ config_architecture, architecture.oci_architecture },
        );
        return error.UnexpectedOciArchitecture;
    }
    try validateOsRelease(image);

    // Azure Linux uses merged-/usr symlinks, so OCI records these physical paths.
    for (required_rootfs_files) |path| {
        const entry = image.get(path) orelse {
            std.debug.print("error: generated OCI layout is missing required rootfs path: /{s}\n", .{path});
            return error.IncompleteOciRootfs;
        };
        if (entry.kind != .file) {
            std.debug.print("error: generated OCI rootfs path is not a file: /{s}\n", .{path});
            return error.IncompleteOciRootfs;
        }
    }
    const stub = image.get(architecture.systemd_boot_stub_path) orelse {
        std.debug.print(
            "error: generated OCI layout is missing required UKI stub: /{s}\n",
            .{architecture.systemd_boot_stub_path},
        );
        return error.IncompleteOciRootfs;
    };
    if (stub.kind != .file) return error.IncompleteOciRootfs;
    for (zvminit_symlink_paths) |path| {
        const entry = image.get(path) orelse {
            std.debug.print("error: generated OCI layout is missing required zvminit symlink: /{s}\n", .{path});
            return error.IncompleteOciRootfs;
        };
        if (entry.kind != .symlink or !std.mem.eql(u8, entry.link_name orelse "", "zvminit")) {
            std.debug.print("error: generated OCI rootfs path is not a relative symlink to zvminit: /{s}\n", .{path});
            return error.IncompleteOciRootfs;
        }
    }
}

const GeneralizedImageValidationReport = struct {
    virtual_size: u64,
    esp_size: u64,
    root_size: u64,
    uki_size: usize,
};

fn planGeneralizedGen2Layout(
    gpa: Allocator,
    virtual_size: u64,
    architecture: *const ArchitectureDescriptor,
) ![]zvmi.layout.PlannedPartition {
    const requests = [_]zvmi.layout.PartitionRequest{
        .{ .name = "ESP", .role = .esp, .size = .{ .fixed = generalized_esp_size_bytes } },
        .{
            .name = "root",
            .role = architecture.root_role,
            .size = .{ .percent = 100.0 },
            .type_guid = architecture.root_type_guid,
        },
    };
    return zvmi.layout.planLayout(gpa, virtual_size, &requests, null);
}

fn validatePartitionLayout(
    partitions: []const zvmi.gpt.PartitionEntry,
    expected: []const zvmi.layout.PlannedPartition,
) !void {
    if (partitions.len != expected.len) return error.UnexpectedPartitionCount;
    for (partitions, expected) |partition, planned| {
        if (!std.mem.eql(u8, &partition.partition_type_guid, &planned.type_guid)) {
            return error.UnexpectedPartitionType;
        }
        if (partition.first_lba != planned.firstLba() or partition.last_lba != planned.lastLba()) {
            return error.UnexpectedPartitionLayout;
        }
        if (partition.last_lba < partition.first_lba) return error.UnexpectedPartitionLayout;
        const offset_bytes = partition.first_lba * zvmi.gpt.sector_size;
        const length_bytes = (partition.last_lba - partition.first_lba + 1) * zvmi.gpt.sector_size;
        if (offset_bytes != planned.offset_bytes or length_bytes != planned.length_bytes) {
            return error.UnexpectedPartitionLayout;
        }
    }
}

fn requireAbsentFile(esp: *zvmi.fat32.FileSystem, gpa: Allocator, io: Io, path: []const u8) !void {
    const bytes = esp.readFileAlloc(io, gpa, path) catch |err| switch (err) {
        error.PathNotFound => return,
        else => return err,
    };
    gpa.free(bytes);
    return error.UnexpectedGeneratedBootConfig;
}

fn requireNoBlsEntries(esp: *zvmi.fat32.FileSystem, gpa: Allocator, io: Io) !void {
    const entries = esp.listDirAlloc(io, gpa, "loader/entries") catch |err| switch (err) {
        error.PathNotFound => return,
        else => return err,
    };
    defer zvmi.fat32.freeDirEntries(gpa, entries);
    for (entries) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".conf")) {
            return error.UnexpectedGeneratedBootConfig;
        }
    }
}

fn requireNoGeneratedGrubConfigs(esp: *zvmi.fat32.FileSystem, gpa: Allocator, io: Io) !void {
    try requireAbsentFile(esp, gpa, io, "EFI/BOOT/grub.cfg");

    const efi_entries = try esp.listDirAlloc(io, gpa, "EFI");
    defer zvmi.fat32.freeDirEntries(gpa, efi_entries);
    for (efi_entries) |entry| {
        if (entry.kind != .directory or std.ascii.eqlIgnoreCase(entry.name, "BOOT")) continue;
        const path = try std.fmt.allocPrint(gpa, "EFI/{s}/grub.cfg", .{entry.name});
        defer gpa.free(path);
        try requireAbsentFile(esp, gpa, io, path);
    }
}

fn expectedUkiCmdline(
    gpa: Allocator,
    root_guid: zvmi.guid.Guid,
    architecture: *const ArchitectureDescriptor,
) ![]u8 {
    var root_guid_text: [36]u8 = undefined;
    return std.fmt.allocPrint(
        gpa,
        "root=PARTUUID={s} {s}",
        .{ zvmi.guid.formatLower(&root_guid_text, root_guid), architecture.extra_kernel_options },
    );
}

fn requireNonemptyUkiSection(inspection: *const zvmi.uki.Inspection, name: []const u8) ![]const u8 {
    const section = inspection.findSection(name) orelse return error.MissingUkiSection;
    if (section.contents.len == 0) return error.EmptyUkiSection;
    return section.contents;
}

fn validateGeneralizedImage(
    gpa: Allocator,
    io: Io,
    image_path: []const u8,
    expected_virtual_size: u64,
    architecture: *const ArchitectureDescriptor,
) !GeneralizedImageValidationReport {
    var image = try zvmi.Image.openPathReadOnly(io, image_path);
    defer image.close(io);
    if (image.virtual_size != expected_virtual_size) return error.UnexpectedVirtualSize;

    const expected_layout = try planGeneralizedGen2Layout(gpa, image.virtual_size, architecture);
    defer gpa.free(expected_layout);
    const parsed = try zvmi.gpt.readGpt(image, io, gpa);
    defer gpa.free(parsed.partitions);
    try validatePartitionLayout(parsed.partitions, expected_layout);

    const esp_partition = parsed.partitions[0];
    const root_partition = parsed.partitions[1];
    if (std.mem.eql(u8, &root_partition.unique_partition_guid, &zvmi.guid.nil)) {
        return error.InvalidRootPartitionGuid;
    }
    var esp = try zvmi.fat32.open(&image, io, .{
        .offset = esp_partition.first_lba * zvmi.gpt.sector_size,
        .length = (esp_partition.last_lba - esp_partition.first_lba + 1) * zvmi.gpt.sector_size,
    });

    const fallback_uki = try esp.readFileAlloc(io, gpa, architecture.fallback_efi_path);
    defer gpa.free(fallback_uki);
    const linux_entries = try esp.listDirAlloc(io, gpa, "EFI/Linux");
    defer zvmi.fat32.freeDirEntries(gpa, linux_entries);

    var found_named_uki = false;
    var fallback_matches_named_uki = false;
    for (linux_entries) |entry| {
        if (entry.kind != .file or entry.name.len < 4 or
            !std.ascii.eqlIgnoreCase(entry.name[entry.name.len - 4 ..], ".efi")) continue;
        found_named_uki = true;
        const path = try std.fmt.allocPrint(gpa, "EFI/Linux/{s}", .{entry.name});
        defer gpa.free(path);
        const bytes = try esp.readFileAlloc(io, gpa, path);
        defer gpa.free(bytes);
        if (std.mem.eql(u8, fallback_uki, bytes)) {
            fallback_matches_named_uki = true;
            break;
        }
    }
    if (!found_named_uki) return error.MissingNamedUki;
    if (!fallback_matches_named_uki) return error.FallbackUkiMismatch;

    var inspection = try zvmi.uki.inspect(gpa, fallback_uki);
    defer inspection.deinit(gpa);
    if (inspection.machine != architecture.uki_pe_machine) return error.UnexpectedUkiMachine;
    if (inspection.subsystem != 10) return error.UnexpectedUkiSubsystem;
    _ = try requireNonemptyUkiSection(&inspection, ".linux");
    _ = try requireNonemptyUkiSection(&inspection, ".initrd");
    const cmdline = try requireNonemptyUkiSection(&inspection, ".cmdline");
    _ = try requireNonemptyUkiSection(&inspection, ".osrel");
    _ = try requireNonemptyUkiSection(&inspection, ".uname");

    const expected_cmdline = try expectedUkiCmdline(gpa, root_partition.unique_partition_guid, architecture);
    defer gpa.free(expected_cmdline);
    if (!std.mem.eql(u8, cmdline, expected_cmdline)) return error.UnexpectedUkiCmdline;

    try requireAbsentFile(&esp, gpa, io, "loader/loader.conf");
    try requireNoBlsEntries(&esp, gpa, io);
    try requireNoGeneratedGrubConfigs(&esp, gpa, io);

    return .{
        .virtual_size = image.virtual_size,
        .esp_size = expected_layout[0].length_bytes,
        .root_size = expected_layout[1].length_bytes,
        .uki_size = fallback_uki.len,
    };
}

// ─── ISO download ─────────────────────────────────────────────────────────────

fn isoChecksumMatches(
    actual: [64]u8,
    architecture: *const ArchitectureDescriptor,
) bool {
    return std.mem.eql(u8, &actual, architecture.iso_sha256);
}

fn validateIso(io: Io, iso_path: []const u8, architecture: *const ArchitectureDescriptor) !void {
    const stat = try Dir.cwd().statFile(io, iso_path, .{});
    if (!isRegularNonemptyFile(stat.kind, stat.size) or stat.size > iso_max_bytes) {
        return error.InvalidIso;
    }
    _ = artifact_pipeline.parseSha256(architecture.iso_sha256) catch return error.InvalidIsoChecksum;
    const actual = try sha256File(io, iso_path);
    if (!isoChecksumMatches(actual, architecture)) {
        std.debug.print(
            "error: ISO checksum mismatch for {s}: expected {s}, got {s}\n",
            .{ iso_path, architecture.iso_sha256, &actual },
        );
        return error.IsoChecksumMismatch;
    }
}

fn downloadIso(
    gpa: Allocator,
    io: Io,
    work_dir: []const u8,
    architecture: *const ArchitectureDescriptor,
) ![]u8 {
    const iso_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ work_dir, architecture.iso_name });
    errdefer gpa.free(iso_path);

    const expected_digest = artifact_pipeline.parseSha256(architecture.iso_sha256) catch
        return error.InvalidIsoChecksum;
    var curl = artifact_pipeline.CurlDownloader{
        .executable_path = "curl",
    };
    const acquired = artifact_pipeline.acquireVerified(
        gpa,
        io,
        .{
            .url = architecture.iso_url,
            .destination_path = iso_path,
            .expected_sha256 = expected_digest,
            .max_size = iso_max_bytes,
        },
        curl.downloader(),
    ) catch |err| switch (err) {
        error.ChecksumMismatch => return error.IsoChecksumMismatch,
        else => return err,
    };
    if (acquired.reused_cache) {
        std.debug.print("ISO cached at {s}\n", .{iso_path});
    } else {
        std.debug.print("ISO downloaded: {s}\n", .{iso_path});
    }
    try validateIso(io, iso_path, architecture);
    return iso_path;
}

// ─── tool check ──────────────────────────────────────────────────────────────

fn requireTool(gpa: Allocator, io: Io, name: []const u8) bool {
    const bytes = capture(gpa, io, &.{ "which", name }) catch return false;
    gpa.free(bytes);
    return true;
}

fn guestArtifactMatchesArchitecture(
    file_description: []const u8,
    architecture: *const ArchitectureDescriptor,
) bool {
    return std.mem.indexOf(u8, file_description, architecture.elf_file_marker) != null;
}

fn validateGuestArtifact(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    architecture: *const ArchitectureDescriptor,
) !void {
    const description = try capture(gpa, io, &.{ "file", "-b", path });
    defer gpa.free(description);
    if (!guestArtifactMatchesArchitecture(description, architecture)) {
        std.debug.print(
            "error: guest artifact {s} does not match requested {s}: {s}",
            .{ path, @tagName(architecture.architecture), description },
        );
        return error.GuestArtifactArchitectureMismatch;
    }
}

// ─── args ─────────────────────────────────────────────────────────────────────

const Args = struct {
    architecture: ?AzureLinuxArchitecture = null,
    iso: ?[]const u8 = null,
    output: ?[]const u8 = null,
    size: []const u8 = "1184M",
    work_dir: ?[]const u8 = null,
    zvmi_path: ?[]const u8 = null,
    zvminit_path: ?[]const u8 = null,
    azagent_path: ?[]const u8 = null,
    preload_path: ?[]const u8 = null,
};

const help_text =
    \\Usage: build_generalized_azurelinux4 [options]
    \\
    \\  --architecture <arch> x86_64 or aarch64 (injected by build.zig)
    \\  --iso <path>        Architecture-matched Azure Linux 4 ISO (downloaded if omitted)
    \\  --output <path>     Output QCOW2 (architecture-specific default)
    \\  --size <size>       Disk size (default: 1184M)
    \\  --work-dir <dir>    Working directory (architecture-specific default)
    \\  --zvmi <path>       zvmi executable (injected by build.zig)
    \\  --zvminit <path>    guest zvminit binary (injected by build.zig)
    \\  --azagent <path>    guest azagent binary (injected by build.zig)
    \\  --preload <path>    zstd_max_preload.so (injected by build.zig)
    \\
    \\Preferred invocation: zig build generalized-azurelinux4 -- [user options]
    \\
;

pub fn parseArchitecture(value: []const u8) error{UnsupportedArchitecture}!AzureLinuxArchitecture {
    if (std.mem.eql(u8, value, "x86_64")) return .x86_64;
    if (std.mem.eql(u8, value, "aarch64")) return .aarch64;
    return error.UnsupportedArchitecture;
}

fn parseArgs(argv: []const []const u8) !Args {
    var a = Args{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--architecture")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.architecture = try parseArchitecture(argv[i]);
        } else if (std.mem.eql(u8, arg, "--iso")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.iso = argv[i];
        } else if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.output = argv[i];
        } else if (std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.size = argv[i];
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.work_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--zvmi")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.zvmi_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--zvminit")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.zvminit_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--azagent")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.azagent_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--preload")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.preload_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{help_text});
            std.process.exit(0);
        } else {
            std.debug.print("error: unexpected argument '{s}'\n", .{arg});
            return error.UnexpectedArgument;
        }
    }
    return a;
}

// ─── main ─────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    const args = parseArgs(argv[1..]) catch |err| {
        std.debug.print("error: {s}\n{s}", .{ @errorName(err), help_text });
        std.process.exit(1);
    };
    const architecture = requireArchitecture(args.architecture) catch {
        std.debug.print("error: --architecture is required (provided by zig build)\n", .{});
        std.process.exit(1);
    };
    const output_path = args.output orelse architecture.default_output_path;
    const work_dir = args.work_dir orelse architecture.default_work_dir;
    const requested_size = zvmi.parseSize(args.size) catch |err| {
        std.debug.print("error: invalid --size ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const max_qcow2_file_size = std.math.add(
        u64,
        requested_size,
        requested_size / 64 + 64 * 1024 * 1024,
    ) catch {
        std.debug.print("error: --size is too large\n", .{});
        std.process.exit(1);
    };

    const zvmi_path = args.zvmi_path orelse {
        std.debug.print("error: --zvmi is required (provided by zig build)\n", .{});
        std.process.exit(1);
    };
    const zvminit_path = args.zvminit_path orelse {
        std.debug.print("error: --zvminit is required (provided by zig build)\n", .{});
        std.process.exit(1);
    };
    const azagent_path = args.azagent_path orelse {
        std.debug.print("error: --azagent is required (provided by zig build)\n", .{});
        std.process.exit(1);
    };
    const preload_path = args.preload_path orelse {
        std.debug.print("error: --preload is required (provided by zig build)\n", .{});
        std.process.exit(1);
    };

    // Check required external tools.
    var tools_ok = true;
    for (&[_][]const u8{ "sudo", "tar", "dnf", "curl", "qemu-img", "file" }) |tool| {
        if (!requireTool(gpa, io, tool)) {
            std.debug.print("error: required tool '{s}' not found in PATH\n", .{tool});
            tools_ok = false;
        }
    }
    if (!tools_ok) std.process.exit(1);
    try validateGuestArtifact(gpa, io, zvminit_path, architecture);
    try validateGuestArtifact(gpa, io, azagent_path, architecture);

    try Dir.cwd().createDirPath(io, work_dir);

    const downloaded_iso_path = if (args.iso == null) try downloadIso(gpa, io, work_dir, architecture) else null;
    defer if (downloaded_iso_path) |path| gpa.free(path);
    const iso_path = args.iso orelse downloaded_iso_path.?;
    _ = Dir.cwd().statFile(io, iso_path, .{}) catch |err| {
        std.debug.print("error: ISO not found: {s} ({s})\n", .{ iso_path, @errorName(err) });
        std.process.exit(1);
    };
    try validateIso(io, iso_path, architecture);

    const rootfs_path = try std.fmt.allocPrint(gpa, "{s}/rootfs", .{work_dir});
    defer gpa.free(rootfs_path);

    const base_digest = try pullRootfs(gpa, io, work_dir, rootfs_path, architecture);
    defer gpa.free(base_digest);

    const systemd_boot_rpm_path = try acquireSystemdBootRpm(gpa, io, work_dir, architecture);
    defer gpa.free(systemd_boot_rpm_path);
    try installGuestContent(
        gpa,
        io,
        rootfs_path,
        work_dir,
        zvminit_path,
        azagent_path,
        systemd_boot_rpm_path,
        architecture,
    );

    const layout_dir = try createOciLayout(gpa, io, work_dir, rootfs_path, base_digest, architecture);
    defer gpa.free(layout_dir);
    try validateGeneralizedOciLayout(gpa, io, layout_dir, architecture);

    // Ensure output parent directory exists.
    if (std.fs.path.dirname(output_path)) |parent| {
        Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Build the raw QCOW2 first (no compression).
    const raw_qcow2 = try std.fmt.allocPrint(gpa, "{s}.raw.qcow2", .{output_path});
    defer gpa.free(raw_qcow2);
    Dir.cwd().deleteFile(io, raw_qcow2) catch {};

    std.debug.print("Building disk image...\n", .{});
    try run(gpa, io, &.{
        zvmi_path,
        "build-image",
        "--iso",
        iso_path,
        "--container",
        layout_dir,
        "--generation",
        "2",
        "--size",
        args.size,
        "--skip-iso-rootfs",
        "--boot-mode",
        "uki",
        "--stub-source-path",
        architecture.systemd_boot_stub_path,
        "--esp-size",
        generalized_esp_size_arg,
        "--extra-kernel-options",
        architecture.extra_kernel_options,
        "-o",
        raw_qcow2,
        "-O",
        "qcow2",
        "-v",
    });

    // Compress to maximum-zstd QCOW2 via the LD_PRELOAD intercept library.
    std.debug.print("Compressing to maximum-zstd QCOW2...\n", .{});
    var env_map = try init.environ_map.clone(gpa);
    defer env_map.deinit();
    try env_map.put("LD_PRELOAD", preload_path);

    const staged_qcow2 = try std.fmt.allocPrint(gpa, "{s}.validated-stage", .{output_path});
    defer gpa.free(staged_qcow2);
    const raw_metadata = try artifact_pipeline.hashFile(io, raw_qcow2);
    const finalized = artifact_pipeline.finalizeQcow2(
        gpa,
        io,
        .{
            .input_path = raw_qcow2,
            .expected_input_sha256 = raw_metadata.sha256,
            .max_input_size = max_qcow2_file_size,
            .source_format = .qcow2,
            .expected_virtual_size = requested_size,
            .max_virtual_size = requested_size,
            .output_path = staged_qcow2,
            .max_output_size = max_qcow2_file_size,
            .qemu_img_path = "qemu-img",
            .compression = .zstd,
            .convert_environ_map = &env_map,
        },
    ) catch |err| {
        std.debug.print(
            "error: QCOW2 finalization failed ({s}); keeping {s}\n",
            .{ @errorName(err), raw_qcow2 },
        );
        return err;
    };

    const validation = validateGeneralizedImage(gpa, io, staged_qcow2, requested_size, architecture) catch |err| {
        std.debug.print(
            "error: generalized image structural validation failed ({s}); keeping {s} and {s}\n",
            .{ @errorName(err), raw_qcow2, staged_qcow2 },
        );
        return err;
    };
    std.debug.print(
        "Validated generalized QCOW2: virtual {d} bytes, ESP {d} bytes, root {d} bytes, UKI {d} bytes\n",
        .{ validation.virtual_size, validation.esp_size, validation.root_size, validation.uki_size },
    );

    Dir.cwd().rename(staged_qcow2, Dir.cwd(), output_path, io) catch |err| {
        std.debug.print(
            "error: could not publish validated image {s} as {s} ({s}); keeping {s}\n",
            .{ staged_qcow2, output_path, @errorName(err), raw_qcow2 },
        );
        return err;
    };

    // Remove the intermediate uncompressed QCOW2 on success.
    Dir.cwd().deleteFile(io, raw_qcow2) catch |err| {
        std.debug.print("warning: could not remove {s}: {s}\n", .{ raw_qcow2, @errorName(err) });
    };

    std.debug.print(
        "Built {s} ({d} bytes, virtual size {d})\n",
        .{ output_path, finalized.artifact.size, finalized.virtual_size },
    );
}

// ─── unit tests ──────────────────────────────────────────────────────────────

test "validateOsRelease accepts the standard Azure Linux symlink" {
    var entries = [_]oci.FileTree.Entry{
        .{
            .path = "etc/os-release",
            .kind = .symlink,
            .mode = 0o777,
            .size = 0,
            .link_name = "../usr/lib/os-release",
        },
        .{
            .path = "usr/lib/os-release",
            .kind = .file,
            .mode = 0o644,
            .size = 0,
        },
    };
    const image: oci.FileTree = .{
        .allocator = std.testing.allocator,
        .entries = &entries,
    };

    try validateOsRelease(image);
}

test "safeLayerPath strips ./ prefix" {
    try std.testing.expectEqualStrings("etc/passwd", (try safeLayerPath("./etc/passwd")).?);
}

test "safeLayerPath strips leading /" {
    try std.testing.expectEqualStrings("usr/bin/sh", (try safeLayerPath("/usr/bin/sh")).?);
}

test "safeLayerPath returns null for root" {
    try std.testing.expect((try safeLayerPath("./")) == null);
    try std.testing.expect((try safeLayerPath("")) == null);
    try std.testing.expect((try safeLayerPath("/")) == null);
}

test "safeLayerPath rejects .." {
    try std.testing.expectError(error.UnsafeLayerPath, safeLayerPath("../../etc/passwd"));
    try std.testing.expectError(error.UnsafeLayerPath, safeLayerPath("./etc/../../../passwd"));
    try std.testing.expectError(error.UnsafeLayerPath, safeLayerPath("a/../b"));
}

test "parseDigestHex accepts sha256: prefix" {
    const hex = try parseDigestHex("sha256:" ++ "a" ** 64);
    try std.testing.expectEqualStrings("a" ** 64, hex);
}

test "parseDigestHex accepts bare hex" {
    try std.testing.expectEqualStrings("b" ** 64, try parseDigestHex("b" ** 64));
}

test "parseDigestHex rejects short and invalid chars" {
    try std.testing.expectError(error.InvalidDigest, parseDigestHex("sha256:short"));
    try std.testing.expectError(error.InvalidDigest, parseDigestHex("sha256:" ++ "g" ** 64));
    try std.testing.expectError(error.InvalidDigest, parseDigestHex("notahex"));
}

test "selectLinuxManifest picks each requested Linux platform" {
    const gpa = std.testing.allocator;
    const json_text =
        \\{"manifests":[
        \\  {"platform":{"os":"linux","architecture":"arm64"},"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"},
        \\  {"platform":{"os":"linux","architecture":"amd64"},"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer parsed.deinit();
    const arm64_digest = try selectLinuxManifest(gpa, parsed.value, aarch64.oci_architecture);
    defer gpa.free(arm64_digest);
    try std.testing.expectEqualStrings("sha256:1111111111111111111111111111111111111111111111111111111111111111", arm64_digest);
    const amd64_digest = try selectLinuxManifest(gpa, parsed.value, x86_64.oci_architecture);
    defer gpa.free(amd64_digest);
    try std.testing.expectEqualStrings("sha256:2222222222222222222222222222222222222222222222222222222222222222", amd64_digest);
}

test "selectLinuxManifest rejects an unavailable platform" {
    const gpa = std.testing.allocator;
    const json_text =
        \\{"manifests":[{"platform":{"os":"linux","architecture":"arm64"},"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.NoLinuxArchitectureManifest,
        selectLinuxManifest(gpa, parsed.value, x86_64.oci_architecture),
    );
}

test "sha256Bytes produces known digest" {
    const hex = sha256Bytes("hello");
    // echo -n hello | sha256sum => 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", &hex);
}

test "architecture descriptors pin core inputs and output namespaces" {
    const gpa = std.testing.allocator;
    const cases = [_]*const ArchitectureDescriptor{ &x86_64, &aarch64 };
    for (cases) |architecture| {
        const cache_path = try systemdBootRpmCachePath(gpa, ".scratch/work", architecture);
        defer gpa.free(cache_path);
        const expected_cache_path = try std.fmt.allocPrint(
            gpa,
            ".scratch/work/downloads/{s}",
            .{architecture.systemd_boot_rpm_name},
        );
        defer gpa.free(expected_cache_path);
        try std.testing.expectEqualStrings(expected_cache_path, cache_path);
        _ = try artifact_pipeline.parseSha256(architecture.iso_sha256);
        _ = try artifact_pipeline.parseSha256(architecture.base_manifest_digest);
        _ = try artifact_pipeline.parseSha256(architecture.systemd_boot_rpm_sha256);
        try std.testing.expectEqual(architecture.root_type_guid, architecture.root_role.defaultTypeGuid());
    }
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), systemd_boot_unsigned_rpm_max_bytes);

    try std.testing.expectEqualStrings("https://aka.ms/azurelinux-4.0-x86_64.iso", x86_64.iso_url);
    try std.testing.expectEqualStrings("https://aka.ms/azurelinux-4.0-aarch64.iso", aarch64.iso_url);
    try std.testing.expectEqualStrings("AzureLinux-4.0-x86_64.iso", x86_64.iso_name);
    try std.testing.expectEqualStrings("AzureLinux-4.0-aarch64.iso", aarch64.iso_name);
    try std.testing.expectEqualStrings(
        "d98f7d1ffaa916de7c9f66ffdadb150c174da691509e760835709ffa7829ca48",
        x86_64.iso_sha256,
    );
    try std.testing.expectEqualStrings(
        "762039fde64a59806750ee86ca98132fad4f9df02e7684490017cdfda0c55157",
        aarch64.iso_sha256,
    );
    try std.testing.expectEqualStrings(
        "sha256:9070b05147f01e5a4bac47723c95f2555e11b9d3324c1df1910ff3545b7ce319",
        x86_64.base_manifest_digest,
    );
    try std.testing.expectEqualStrings(
        "sha256:e541db83a8511c25fa1dd989161263874b7395ddd588f5caaa25453ea4e23263",
        aarch64.base_manifest_digest,
    );
    try std.testing.expectEqualStrings("AzureLinux-4.0-x86_64.core.qcow2", x86_64.default_output_path);
    try std.testing.expectEqualStrings("AzureLinux-4.0-aarch64.core.qcow2", aarch64.default_output_path);
    try std.testing.expectEqualStrings(".scratch/azurelinux4-core-x86_64", x86_64.default_work_dir);
    try std.testing.expectEqualStrings(".scratch/azurelinux4-core-aarch64", aarch64.default_work_dir);
}

test "architecture descriptors select RPMs, stubs, EFI paths, and binfmt" {
    try std.testing.expectEqualStrings(
        "systemd-boot-unsigned-258.4-4.azl4.x86_64.rpm",
        x86_64.systemd_boot_rpm_name,
    );
    try std.testing.expectEqualStrings(
        "systemd-boot-unsigned-258.4-4.azl4.aarch64.rpm",
        aarch64.systemd_boot_rpm_name,
    );
    try std.testing.expectEqualStrings("x86_64", x86_64.dnf_architecture);
    try std.testing.expectEqualStrings("aarch64", aarch64.dnf_architecture);
    try std.testing.expectEqual(std.Target.Cpu.Arch.x86_64, x86_64.target_cpu);
    try std.testing.expectEqual(std.Target.Cpu.Arch.aarch64, aarch64.target_cpu);
    try std.testing.expectEqualStrings(
        "85dd3ac0c532bceb09fc0a85c6568c51fc4ee84e0c478d1302b7a2d84e1bea5c",
        x86_64.systemd_boot_rpm_sha256,
    );
    try std.testing.expectEqualStrings(
        "65aefdef9bc55f71f43c18b738fc1a61eeedd9fea7d803f0b0b06467fb748991",
        aarch64.systemd_boot_rpm_sha256,
    );
    try std.testing.expectEqualStrings(
        "etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-4.0-x86_64",
        x86_64.signing_key_path,
    );
    try std.testing.expectEqualStrings(
        "etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-4.0-aarch64",
        aarch64.signing_key_path,
    );
    try std.testing.expectEqualStrings(
        "usr/lib/systemd/boot/efi/linuxx64.efi.stub",
        x86_64.systemd_boot_stub_path,
    );
    try std.testing.expectEqualStrings(
        "usr/lib/systemd/boot/efi/linuxaa64.efi.stub",
        aarch64.systemd_boot_stub_path,
    );
    try std.testing.expectEqualStrings("EFI/BOOT/BOOTX64.EFI", x86_64.fallback_efi_path);
    try std.testing.expectEqualStrings("EFI/BOOT/BOOTAA64.EFI", aarch64.fallback_efi_path);
    try std.testing.expectEqual(@as(u16, 0x8664), x86_64.uki_pe_machine);
    try std.testing.expectEqual(@as(u16, 0xaa64), aarch64.uki_pe_machine);
    try std.testing.expectEqual(zvmi.layout.PartitionRole.root_x86_64, x86_64.root_role);
    try std.testing.expectEqual(zvmi.layout.PartitionRole.root_aarch64, aarch64.root_role);
    try std.testing.expectEqual(zvmi.guid.linux_root_x86_64, x86_64.root_type_guid);
    try std.testing.expectEqual(zvmi.guid.linux_root_aarch64, aarch64.root_type_guid);
    try std.testing.expectEqualStrings("qemu-x86_64-static", x86_64.binfmt_static_name);
    try std.testing.expectEqualStrings("qemu-aarch64-static", aarch64.binfmt_static_name);
    try std.testing.expectEqualStrings("/proc/sys/fs/binfmt_misc/qemu-x86_64", x86_64.binfmt_registration_path);
    try std.testing.expectEqualStrings("/proc/sys/fs/binfmt_misc/qemu-aarch64", aarch64.binfmt_registration_path);
}

test "OCI config architecture is required to match the descriptor" {
    try std.testing.expect(ociConfigArchitectureMatches("amd64", &x86_64));
    try std.testing.expect(ociConfigArchitectureMatches("arm64", &aarch64));
    try std.testing.expect(!ociConfigArchitectureMatches("arm64", &x86_64));
    try std.testing.expect(!ociConfigArchitectureMatches(null, &aarch64));
}

test "isRegularNonemptyFile accepts only nonempty regular files" {
    try std.testing.expect(isRegularNonemptyFile(.file, 1));
    try std.testing.expect(!isRegularNonemptyFile(.file, 0));
    try std.testing.expect(!isRegularNonemptyFile(.directory, 1));
    try std.testing.expect(!isRegularNonemptyFile(.sym_link, 1));
}

test "supplied ISO checksum must match the selected architecture" {
    const wrong_checksum = sha256Bytes("not an Azure Linux ISO");
    try std.testing.expect(!isoChecksumMatches(wrong_checksum, &x86_64));
    try std.testing.expect(!isoChecksumMatches(wrong_checksum, &aarch64));
}

test "architecture and argument parsing accepts only supported values" {
    try std.testing.expectEqual(AzureLinuxArchitecture.x86_64, try parseArchitecture("x86_64"));
    try std.testing.expectEqual(AzureLinuxArchitecture.aarch64, try parseArchitecture("aarch64"));
    try std.testing.expectError(error.UnsupportedArchitecture, parseArchitecture("amd64"));
    try std.testing.expectError(error.UnsupportedArchitecture, parseArchitecture("arm64"));
    try std.testing.expectError(error.MissingArchitecture, requireArchitecture(null));
    try std.testing.expectEqualStrings("1184M", (try parseArgs(&.{})).size);
    try std.testing.expectEqualStrings("2G", (try parseArgs(&.{ "--size", "2G" })).size);
    try std.testing.expectEqual(
        AzureLinuxArchitecture.aarch64,
        (try parseArgs(&.{ "--architecture", "aarch64" })).architecture.?,
    );
    try std.testing.expectEqualStrings(
        "zig-out/bin/zvminit",
        (try parseArgs(&.{ "--zvminit", "zig-out/bin/zvminit" })).zvminit_path.?,
    );
}

test "guest artifact architecture validation rejects mismatches" {
    try std.testing.expect(guestArtifactMatchesArchitecture(
        "ELF 64-bit LSB executable, x86-64, version 1 (SYSV)",
        &x86_64,
    ));
    try std.testing.expect(guestArtifactMatchesArchitecture(
        "ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV)",
        &aarch64,
    ));
    try std.testing.expect(!guestArtifactMatchesArchitecture(
        "ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV)",
        &x86_64,
    ));
}

test "zvminit rootfs layout requires relative command symlinks" {
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "usr/bin/init", "usr/bin/poweroff", "usr/bin/reboot", "usr/bin/shutdown" },
        &zvminit_symlink_paths,
    );
}

test "generalized Gen2 layout uses the descriptor root role and GUID" {
    const gpa = std.testing.allocator;
    const disk_size = try zvmi.parseSize("1184M");
    const cases = [_]*const ArchitectureDescriptor{ &x86_64, &aarch64 };
    for (cases) |architecture| {
        const planned = try planGeneralizedGen2Layout(gpa, disk_size, architecture);
        defer gpa.free(planned);

        try std.testing.expectEqual(@as(usize, 2), planned.len);
        try std.testing.expectEqual(generalized_esp_size_bytes, planned[0].length_bytes);
        try std.testing.expectEqual(@as(u64, 670 * 1024 * 1024), planned[1].length_bytes);
        try std.testing.expectEqual(architecture.root_role, planned[1].role);
        try std.testing.expectEqual(architecture.root_type_guid, planned[1].type_guid);

        var actual = [_]zvmi.gpt.PartitionEntry{
            .{
                .partition_type_guid = planned[0].type_guid,
                .first_lba = planned[0].firstLba(),
                .last_lba = planned[0].lastLba(),
            },
            .{
                .partition_type_guid = planned[1].type_guid,
                .first_lba = planned[1].firstLba(),
                .last_lba = planned[1].lastLba(),
            },
        };
        try validatePartitionLayout(&actual, planned);
        actual[1].last_lba -= 1;
        try std.testing.expectError(error.UnexpectedPartitionLayout, validatePartitionLayout(&actual, planned));
    }
    try std.testing.expectEqual(disk_size, @as(u64, 1184 * 1024 * 1024));
}

test "generalized UKI command line uses architecture-specific serial consoles" {
    const gpa = std.testing.allocator;
    const root_guid = zvmi.guid.parse("11111111-2222-3333-4444-555555555555");
    const x86_cmdline = try expectedUkiCmdline(gpa, root_guid, &x86_64);
    defer gpa.free(x86_cmdline);
    const arm_cmdline = try expectedUkiCmdline(gpa, root_guid, &aarch64);
    defer gpa.free(arm_cmdline);
    try std.testing.expectEqualStrings(
        "root=PARTUUID=11111111-2222-3333-4444-555555555555 init=/sbin/zvminit zvminit.mode=persistent zvminit.azure=auto console=tty0 console=ttyS0,115200n8",
        x86_cmdline,
    );
    try std.testing.expectEqualStrings(
        "root=PARTUUID=11111111-2222-3333-4444-555555555555 init=/sbin/zvminit zvminit.mode=persistent zvminit.azure=auto console=tty0 console=ttyAMA0,115200n8",
        arm_cmdline,
    );
    try std.testing.expectEqualStrings("console=ttyS0,115200n8", x86_64.serial_console);
    try std.testing.expectEqualStrings("console=ttyAMA0,115200n8", aarch64.serial_console);
    try std.testing.expectEqualStrings("512M", generalized_esp_size_arg);
}

test "gzipFile streams the complete source" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const source_path = "test-generalized-azurelinux4-gzip-source";
    const output_path = "test-generalized-azurelinux4-gzip-output";
    defer Dir.cwd().deleteFile(io, source_path) catch {};
    defer Dir.cwd().deleteFile(io, output_path) catch {};

    const payload = try gpa.alloc(u8, 192 * 1024 + 17);
    defer gpa.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @intCast(index % 251);
    try Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = payload });

    try std.testing.expectEqual(@as(u64, payload.len), try gzipFile(io, source_path, output_path));

    const compressed = try Dir.cwd().readFileAlloc(io, output_path, gpa, .limited(payload.len + 1024));
    defer gpa.free(compressed);
    var compressed_reader = Io.Reader.fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(&compressed_reader, .gzip, &window);
    const actual = try decompressor.reader.allocRemaining(gpa, .limited(payload.len + 1));
    defer gpa.free(actual);
    try std.testing.expectEqualSlices(u8, payload, actual);
}
