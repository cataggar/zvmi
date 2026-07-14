//! Build a minimal generalized Azure Linux 4 Gen2 QCOW2 image.
//!
//! Equivalent to scripts/build-generalized-azurelinux4.py but implemented as
//! native Zig 0.16 code. Invoked via `zig build generalized-azurelinux4 -- [args]`
//! rather than directly; the build system passes pre-built tool paths so this
//! binary does not invoke `zig build` internally.
//!
//! CLI arguments accepted:
//!   --iso <path>        Azure Linux 4 x86_64 ISO (downloaded if omitted)
//!   --output <path>     Output QCOW2 path (default: zvmi-azurelinux4-generalized.qcow2)
//!   --size <size>       Disk size (default: 768M)
//!   --work-dir <dir>    Working directory (default: .scratch/generalized-azurelinux4)
//!
//! Arguments injected automatically by build.zig:
//!   --zvmi <path>       Built native zvmi executable
//!   --azinit <path>     Built x86_64-linux azinit binary
//!   --azagent <path>    Built x86_64-linux azagent binary
//!   --preload <path>    Built zstd_max_preload.so shared library

const std = @import("std");
const builtin = @import("builtin");
const oci = @import("oci");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const linux = std.os.linux;

// ─── constants ───────────────────────────────────────────────────────────────

const base_image = "azurelinux-beta/base/core";
const base_tag = "4.0";
const mcr_base = "https://mcr.microsoft.com/v2";
const iso_url = "https://aka.ms/azurelinux-4.0-x86_64.iso";
const iso_checksum_url = "https://aka.ms/azurelinux-4.0-x86_64-iso-checksum";
const iso_name = "AzureLinux-4.0-x86_64.iso";
const oci_manifest_type = "application/vnd.oci.image.manifest.v1+json";
const oci_index_type = "application/vnd.oci.image.index.v1+json";
const docker_manifest_type = "application/vnd.docker.distribution.manifest.v2+json";
const docker_index_type = "application/vnd.docker.distribution.manifest.list.v2+json";
const zvmi_max_layer_bytes: u64 = 128 * 1024 * 1024;
const accept_header = oci_index_type ++ ", " ++ docker_index_type ++ ", " ++ oci_manifest_type ++ ", " ++ docker_manifest_type;

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
    var raw: [32]u8 = undefined;
    Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

/// SHA-256 hex of the file at `path`.  Streams in 64 KiB chunks.
fn sha256File(io: Io, path: []const u8) ![64]u8 {
    var file = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buf: [65536]u8 = undefined;
    const h = Sha256.init(.{});
    var file_reader = file.reader(io, &read_buf);
    var hash_proxy_buf: [256]u8 = undefined;
    var hashed = file_reader.interface.hashed(h, &hash_proxy_buf);
    _ = try hashed.reader.discardRemaining();
    var raw: [32]u8 = undefined;
    hashed.hasher.final(&raw);
    return std.fmt.bytesToHex(raw, .lower);
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
    if (hex.len != 64) return error.InvalidDigest;
    for (hex) |c| if (!std.ascii.isHex(c)) return error.InvalidDigest;
    return hex;
}

// ─── OCI manifest resolution ─────────────────────────────────────────────────

/// Walk the parsed JSON index and return an owned copy of the linux/amd64
/// manifest digest string, or error.NoLinuxAmd64Manifest.
pub fn selectLinuxAmd64Manifest(
    gpa: Allocator,
    index_doc: std.json.Value,
) ![]u8 {
    const manifests_val = switch (index_doc) {
        .object => |obj| obj.get("manifests") orelse return error.NoLinuxAmd64Manifest,
        else => return error.NoLinuxAmd64Manifest,
    };
    const items = switch (manifests_val) {
        .array => |a| a.items,
        else => return error.NoLinuxAmd64Manifest,
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
        if (!std.mem.eql(u8, arch_str, "amd64")) continue;
        const dig = switch (obj.get("digest") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        return gpa.dupe(u8, dig);
    }
    return error.NoLinuxAmd64Manifest;
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

/// Resolve `repository:reference` on MCR, following index → linux/amd64 if needed.
/// Returns manifest JSON bytes and the manifest's sha256 digest (both caller-owned).
fn resolveManifest(
    gpa: Allocator,
    io: Io,
    repository: []const u8,
    reference: []const u8,
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

    // It's an index — find and fetch the linux/amd64 manifest.
    const platform_digest = try selectLinuxAmd64Manifest(gpa, parsed.value);
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

    // Cache hit?
    if (Dir.cwd().statFile(io, dest_path, .{})) |_| {
        const actual = try sha256File(io, dest_path);
        if (std.mem.eql(u8, &actual, expected)) {
            std.debug.print("  blob {s}...: cached\n", .{expected[0..12]});
            return;
        }
    } else |_| {}

    // Create parent directory.
    if (std.fs.path.dirname(dest_path)) |parent| {
        Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const partial = try std.fmt.allocPrint(gpa, "{s}.part", .{dest_path});
    defer gpa.free(partial);

    const url = try std.fmt.allocPrint(gpa, "{s}/{s}/blobs/{s}", .{ mcr_base, repository, digest });
    defer gpa.free(url);

    std.debug.print("  blob {s}...: downloading\n", .{expected[0..12]});
    try run(gpa, io, &.{ "curl", "-fL", "--retry", "3", "-C", "-", "-o", partial, url });

    const actual = try sha256File(io, partial);
    if (!std.mem.eql(u8, &actual, expected)) {
        Dir.cwd().deleteFile(io, partial) catch {};
        std.debug.print("error: blob digest mismatch: expected {s}, got {s}\n", .{ expected, &actual });
        return error.DigestMismatch;
    }

    try Dir.rename(Dir.cwd(), partial, Dir.cwd(), dest_path, io);
    std.debug.print("  blob {s}...: verified\n", .{expected[0..12]});
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
) ![]u8 {
    std.debug.print("Resolving mcr.microsoft.com/{s}:{s}...\n", .{ base_image, base_tag });
    const manifest = try resolveManifest(gpa, io, base_image, base_tag);
    defer gpa.free(manifest.bytes);
    std.debug.print("Resolved to {s}\n", .{manifest.digest});

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
    azinit_path: []const u8,
    azagent_path: []const u8,
) !void {
    // On non-x86_64 hosts, set up binfmt qemu interpreter inside the rootfs.
    const is_x86_64 = builtin.target.cpu.arch == .x86_64;
    var binfmt_interpreter: ?[]u8 = null;
    defer if (binfmt_interpreter) |b| gpa.free(b);

    if (!is_x86_64) {
        const reg = readPseudoFile(gpa, "/proc/sys/fs/binfmt_misc/qemu-x86_64") catch |err| {
            std.debug.print("error: x86_64 binfmt not available ({s}); install qemu-user-static-x86\n", .{@errorName(err)});
            return error.BinfmtMissing;
        };
        defer gpa.free(reg);
        var reg_lines = std.mem.splitScalar(u8, reg, '\n');
        if (!std.mem.eql(u8, reg_lines.next() orelse "", "enabled")) {
            std.debug.print("error: qemu-x86_64 binfmt registration is disabled\n", .{});
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

        const qemu_static_bytes = try capture(gpa, io, &.{ "which", "qemu-x86_64-static" });
        defer gpa.free(qemu_static_bytes);
        const qemu_static = std.mem.trimEnd(u8, qemu_static_bytes, "\n\r ");
        const interp_rel = std.mem.trimStart(u8, interp, "/");
        const guest_interp = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rootfs_path, interp_rel });
        defer gpa.free(guest_interp);
        try sudo(gpa, io, &.{ "install", "-D", "-m", "0755", qemu_static, guest_interp });
    }

    // Copy RPM signing key to host so dnf can verify it from outside the chroot.
    const signing_key_guest = try std.fmt.allocPrint(gpa, "{s}/etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-4.0-x86_64", .{rootfs_path});
    defer gpa.free(signing_key_guest);
    const host_key = try std.fmt.allocPrint(gpa, "{s}/RPM-GPG-KEY-azurelinux-4.0-x86_64", .{work_dir});
    defer gpa.free(host_key);
    try sudo(gpa, io, &.{ "install", "-m", "0644", signing_key_guest, host_key });

    const gpgkey_opt = try std.fmt.allocPrint(gpa, "--setopt=azurelinux-base.gpgkey=file://{s}", .{host_key});
    defer gpa.free(gpgkey_opt);
    try sudo(gpa, io, &.{
        "dnf",                              "-y",
        "--installroot",                    rootfs_path,
        "--releasever=4.0",                 "--forcearch=x86_64",
        "--repo=azurelinux-base",           gpgkey_opt,
        "--setopt=install_weak_deps=False", "install",
        "openssh-server",                   "sudo",
    });

    // Install azinit as /sbin/init.
    const sbin_init = try std.fmt.allocPrint(gpa, "{s}/sbin/init", .{rootfs_path});
    defer gpa.free(sbin_init);
    try sudo(gpa, io, &.{ "rm", "-f", sbin_init });
    try sudo(gpa, io, &.{ "install", "-m", "0755", azinit_path, sbin_init });
    for (&[_][]const u8{ "poweroff", "reboot", "shutdown" }) |cmd| {
        const link = try std.fmt.allocPrint(gpa, "{s}/sbin/{s}", .{ rootfs_path, cmd });
        defer gpa.free(link);
        try sudo(gpa, io, &.{ "rm", "-f", link });
        try sudo(gpa, io, &.{ "ln", "-s", "init", link });
    }

    // Install azagent.
    const azagent_dest = try std.fmt.allocPrint(gpa, "{s}/usr/sbin/azagent", .{rootfs_path});
    defer gpa.free(azagent_dest);
    try sudo(gpa, io, &.{ "install", "-m", "0755", azagent_path, azagent_dest });

    // Write sshd config drop-in.
    try writeRootFile(gpa, io, rootfs_path, work_dir, "etc/ssh/sshd_config.d/10-azinit.conf", "PasswordAuthentication no\n" ++
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
        "dnf",                "--installroot",          rootfs_path, "--releasever=4.0",
        "--forcearch=x86_64", "--repo=azurelinux-base", "clean",     "all",
    });
    const dnf_cache = try std.fmt.allocPrint(gpa, "{s}/var/cache/dnf", .{rootfs_path});
    defer gpa.free(dnf_cache);
    const dnf_log = try std.fmt.allocPrint(gpa, "{s}/var/log/dnf.log", .{rootfs_path});
    defer gpa.free(dnf_log);
    try sudo(gpa, io, &.{ "rm", "-rf", dnf_cache });
    try sudo(gpa, io, &.{ "rm", "-f", dnf_log });

    try run(gpa, io, &.{ "file", sbin_init, azagent_dest });
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
        .architecture = @as([]const u8, "amd64"),
        .config = .{
            .Entrypoint = &[_][]const u8{"/sbin/init"},
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

fn validateGeneralizedOciLayout(gpa: Allocator, io: Io, layout_dir: []const u8) !void {
    var image = try oci.loadLayout(io, gpa, layout_dir, .{});
    defer image.deinit();

    try validateOsRelease(image);

    const required_paths = [_][]const u8{
        "usr/bin/bash",
        "usr/sbin/azagent",
        "usr/sbin/init",
        "usr/sbin/sshd",
    };
    for (required_paths) |path| {
        const entry = image.get(path) orelse {
            std.debug.print("error: generated OCI layout is missing required rootfs path: /{s}\n", .{path});
            return error.IncompleteOciRootfs;
        };
        if (entry.kind != .file) {
            std.debug.print("error: generated OCI rootfs path is not a file: /{s}\n", .{path});
            return error.IncompleteOciRootfs;
        }
    }
}

// ─── ISO download ─────────────────────────────────────────────────────────────

fn downloadIso(gpa: Allocator, io: Io, work_dir: []const u8) ![]const u8 {
    const iso_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ work_dir, iso_name });

    std.debug.print("Fetching ISO checksum...\n", .{});
    const checksum_bytes = try fetchBytes(gpa, io, iso_checksum_url, null);
    defer gpa.free(checksum_bytes);
    var checksum_fields = std.mem.tokenizeAny(u8, checksum_bytes, " \t\r\n");
    const expected = checksum_fields.next() orelse return error.InvalidIsoChecksum;
    _ = try parseDigestHex(expected);

    if (Dir.cwd().statFile(io, iso_path, .{})) |_| {
        const actual = try sha256File(io, iso_path);
        if (std.mem.eql(u8, &actual, expected)) {
            std.debug.print("ISO cached at {s}\n", .{iso_path});
            return iso_path;
        }
    } else |_| {}

    const partial = try std.fmt.allocPrint(gpa, "{s}.part", .{iso_path});
    defer gpa.free(partial);

    std.debug.print("Downloading ISO...\n", .{});
    try run(gpa, io, &.{ "curl", "-fL", "--retry", "3", "-C", "-", "-o", partial, iso_url });

    const actual = try sha256File(io, partial);
    if (!std.mem.eql(u8, &actual, expected)) {
        std.debug.print("error: ISO checksum mismatch\n", .{});
        return error.IsoChecksumMismatch;
    }
    try Dir.rename(Dir.cwd(), partial, Dir.cwd(), iso_path, io);
    std.debug.print("ISO downloaded: {s}\n", .{iso_path});
    return iso_path;
}

// ─── tool check ──────────────────────────────────────────────────────────────

fn requireTool(gpa: Allocator, io: Io, name: []const u8) bool {
    const bytes = capture(gpa, io, &.{ "which", name }) catch return false;
    gpa.free(bytes);
    return true;
}

// ─── args ─────────────────────────────────────────────────────────────────────

const Args = struct {
    iso: ?[]const u8 = null,
    output: []const u8 = "zvmi-azurelinux4-generalized.qcow2",
    size: []const u8 = "768M",
    work_dir: []const u8 = ".scratch/generalized-azurelinux4",
    zvmi_path: ?[]const u8 = null,
    azinit_path: ?[]const u8 = null,
    azagent_path: ?[]const u8 = null,
    preload_path: ?[]const u8 = null,
};

const help_text =
    \\Usage: build_generalized_azurelinux4 [options]
    \\
    \\  --iso <path>        Azure Linux 4 x86_64 ISO (downloaded if omitted)
    \\  --output <path>     Output QCOW2 (default: zvmi-azurelinux4-generalized.qcow2)
    \\  --size <size>       Disk size (default: 768M)
    \\  --work-dir <dir>    Working directory (default: .scratch/generalized-azurelinux4)
    \\  --zvmi <path>       zvmi executable (injected by build.zig)
    \\  --azinit <path>     x86_64-linux azinit binary (injected by build.zig)
    \\  --azagent <path>    x86_64-linux azagent binary (injected by build.zig)
    \\  --preload <path>    zstd_max_preload.so (injected by build.zig)
    \\
    \\Preferred invocation: zig build generalized-azurelinux4 -- [user options]
    \\
;

fn parseArgs(argv: []const []const u8) !Args {
    var a = Args{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--iso")) {
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
        } else if (std.mem.eql(u8, arg, "--azinit")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.azinit_path = argv[i];
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

    const zvmi_path = args.zvmi_path orelse {
        std.debug.print("error: --zvmi is required (provided by zig build)\n", .{});
        std.process.exit(1);
    };
    const azinit_path = args.azinit_path orelse {
        std.debug.print("error: --azinit is required (provided by zig build)\n", .{});
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

    const work_dir = args.work_dir;
    try Dir.cwd().createDirPath(io, work_dir);

    const iso_path = if (args.iso) |p| p else try downloadIso(gpa, io, work_dir);
    _ = Dir.cwd().statFile(io, iso_path, .{}) catch |err| {
        std.debug.print("error: ISO not found: {s} ({s})\n", .{ iso_path, @errorName(err) });
        std.process.exit(1);
    };

    const rootfs_path = try std.fmt.allocPrint(gpa, "{s}/rootfs", .{work_dir});
    defer gpa.free(rootfs_path);

    const base_digest = try pullRootfs(gpa, io, work_dir, rootfs_path);
    defer gpa.free(base_digest);

    try installGuestContent(gpa, io, rootfs_path, work_dir, azinit_path, azagent_path);

    const layout_dir = try createOciLayout(gpa, io, work_dir, rootfs_path, base_digest);
    defer gpa.free(layout_dir);
    try validateGeneralizedOciLayout(gpa, io, layout_dir);

    // Ensure output parent directory exists.
    if (std.fs.path.dirname(args.output)) |parent| {
        Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Build the raw QCOW2 first (no compression).
    const raw_qcow2 = try std.fmt.allocPrint(gpa, "{s}.raw.qcow2", .{args.output});
    defer gpa.free(raw_qcow2);
    const compressed_qcow2 = try std.fmt.allocPrint(gpa, "{s}.tmp", .{args.output});
    defer gpa.free(compressed_qcow2);
    Dir.cwd().deleteFile(io, raw_qcow2) catch {};
    Dir.cwd().deleteFile(io, compressed_qcow2) catch {};

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
        "--extra-kernel-options",
        "init=/sbin/init azinit.mode=persistent console=tty0 console=ttyS0,115200n8",
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

    var compress_child = try std.process.spawn(io, .{
        .argv = &.{
            "qemu-img",                                 "convert",
            "-c",                                       "-f",
            "qcow2",                                    "-O",
            "qcow2",                                    "-o",
            "compression_type=zstd,cluster_size=65536", raw_qcow2,
            compressed_qcow2,
        },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &env_map,
    });
    const compress_term = try compress_child.wait(io);
    switch (compress_term) {
        .exited => |code| if (code != 0) {
            Dir.cwd().deleteFile(io, compressed_qcow2) catch {};
            std.debug.print("error: qemu-img compress failed (code {d}); keeping {s}\n", .{ code, raw_qcow2 });
            return error.CompressionFailed;
        },
        else => {
            Dir.cwd().deleteFile(io, compressed_qcow2) catch {};
            std.debug.print("error: qemu-img terminated abnormally; keeping {s}\n", .{raw_qcow2});
            return error.CompressionFailed;
        },
    }

    try run(gpa, io, &.{ "qemu-img", "check", compressed_qcow2 });
    try Dir.rename(Dir.cwd(), compressed_qcow2, Dir.cwd(), args.output, io);

    // Remove the intermediate uncompressed QCOW2 on success.
    Dir.cwd().deleteFile(io, raw_qcow2) catch |err| {
        std.debug.print("warning: could not remove {s}: {s}\n", .{ raw_qcow2, @errorName(err) });
    };

    const stat = try Dir.cwd().statFile(io, args.output, .{});
    std.debug.print("Built {s} ({d} bytes)\n", .{ args.output, stat.size });
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

test "selectLinuxAmd64Manifest picks correct platform" {
    const gpa = std.testing.allocator;
    const json_text =
        \\{"manifests":[
        \\  {"platform":{"os":"linux","architecture":"arm64"},"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"},
        \\  {"platform":{"os":"linux","architecture":"amd64"},"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer parsed.deinit();
    const digest = try selectLinuxAmd64Manifest(gpa, parsed.value);
    defer gpa.free(digest);
    try std.testing.expectEqualStrings("sha256:2222222222222222222222222222222222222222222222222222222222222222", digest);
}

test "selectLinuxAmd64Manifest errors when no linux/amd64" {
    const gpa = std.testing.allocator;
    const json_text =
        \\{"manifests":[{"platform":{"os":"linux","architecture":"arm64"},"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.NoLinuxAmd64Manifest, selectLinuxAmd64Manifest(gpa, parsed.value));
}

test "sha256Bytes produces known digest" {
    const hex = sha256Bytes("hello");
    // echo -n hello | sha256sum => 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", &hex);
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
