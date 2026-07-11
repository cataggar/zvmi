//! Opportunistic real-QEMU boot verification for images produced by
//! `zvmi.build_image.build()`. Skipped gracefully (not failed) whenever
//! `qemu-system-x86_64`, OVMF firmware, or the `ZVMI_BOOT_TEST_ISO`/
//! `ZVMI_BOOT_TEST_OCI` fixture env vars aren't available, matching the
//! opportunistic-external-tool pattern used elsewhere in this repo.
//!
//! Lives outside `packages/zvmi` (rather than inside
//! `packages/zvmi/src/build_image.zig`, where this test used to live)
//! because it needs both `zvmi` (to actually build an image) and `qmp`
//! (to drive the resulting QEMU process precisely -- see issue #99) --
//! two independent top-level components of this repo's single root
//! `build.zig`, not something either component's own module should
//! depend on for its non-test build.

const std = @import("std");
const Io = std.Io;
const zvmi = @import("zvmi");
const qmp = @import("qmp");

const qemu_boot_smoke_timeout_seconds: i64 = 60;
const qemu_boot_smoke_serial_limit: usize = 256 * 1024;
const qemu_boot_smoke_disk_size: u64 = 4 * 1024 * zvmi.azure.one_mib;

const OvmfFirmwarePair = struct {
    code_path: []u8,
    vars_path: []u8,

    fn deinit(self: *OvmfFirmwarePair, allocator: std.mem.Allocator) void {
        allocator.free(self.code_path);
        allocator.free(self.vars_path);
        self.* = undefined;
    }
};

const QemuBootSmokePrereqs = struct {
    qemu_path: []u8,
    iso_path: []u8,
    oci_path: []u8,

    fn deinit(self: *QemuBootSmokePrereqs, allocator: std.mem.Allocator) void {
        allocator.free(self.qemu_path);
        allocator.free(self.iso_path);
        allocator.free(self.oci_path);
        self.* = undefined;
    }
};

const IsoOciFixtures = struct {
    iso_path: []u8,
    oci_path: []u8,

    fn deinit(self: *IsoOciFixtures, allocator: std.mem.Allocator) void {
        allocator.free(self.iso_path);
        allocator.free(self.oci_path);
        self.* = undefined;
    }
};

const QemuBootSmokeResult = struct {
    timed_out: bool,
    quit_acknowledged: bool,
    serial_output: []u8,

    fn deinit(self: *QemuBootSmokeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.serial_output);
        self.* = undefined;
    }
};

fn pathAccessible(io: Io, path: []const u8, options: Io.Dir.AccessOptions) !bool {
    Io.Dir.cwd().access(io, path, options) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied => return false,
        else => return err,
    };
    return true;
}

fn readOptionalFileAlloc(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    limit: usize,
) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => allocator.alloc(u8, 0),
        else => return err,
    };
}

fn getOptionalTestEnvPathAlloc(
    allocator: std.mem.Allocator,
    comptime key: []const u8,
) !?[]u8 {
    return std.testing.environ.getAlloc(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
}

fn requireProvisionedBootTestPathAlloc(
    allocator: std.mem.Allocator,
    io: Io,
    comptime key: []const u8,
    what: []const u8,
) ![]u8 {
    const path = try getOptionalTestEnvPathAlloc(allocator, key) orelse {
        std.debug.print(
            "skipping build-image QEMU boot smoke test: set {s} to a real local {s}\n",
            .{ key, what },
        );
        return error.SkipZigTest;
    };
    errdefer allocator.free(path);

    if (!try pathAccessible(io, path, .{ .read = true })) {
        std.debug.print(
            "skipping build-image QEMU boot smoke test: {s} points to an unreadable path: {s}\n",
            .{ key, path },
        );
        return error.SkipZigTest;
    }

    return path;
}

/// Like `requireProvisionedBootTestPathAlloc`, but returns `null` instead of
/// `error.SkipZigTest` when the env var isn't set at all -- for optional
/// fixtures (e.g. a verity-capable container) that most dev/CI setups won't
/// have provisioned, where the calling test should skip just that one case
/// rather than the whole test.
fn optionalProvisionedBootTestPathAlloc(
    allocator: std.mem.Allocator,
    io: Io,
    comptime key: []const u8,
) !?[]u8 {
    const path = try getOptionalTestEnvPathAlloc(allocator, key) orelse return null;
    errdefer allocator.free(path);

    if (!try pathAccessible(io, path, .{ .read = true })) {
        std.debug.print(
            "skipping: {s} points to an unreadable path: {s}\n",
            .{ key, path },
        );
        allocator.free(path);
        return null;
    }

    return path;
}

fn findExecutableInPathAlloc(
    allocator: std.mem.Allocator,
    io: Io,
    name: []const u8,
) !?[]u8 {
    const path_value = try getOptionalTestEnvPathAlloc(allocator, "PATH") orelse return null;
    defer allocator.free(path_value);

    var it = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (it.next()) |dir_path| {
        const candidate = if (dir_path.len == 0)
            try allocator.dupe(u8, name)
        else
            try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ dir_path, std.fs.path.sep, name });
        errdefer allocator.free(candidate);

        if (try pathAccessible(io, candidate, .{ .execute = true })) return candidate;
        allocator.free(candidate);
    }

    return null;
}

fn requireOvmfFirmwarePairAlloc(
    allocator: std.mem.Allocator,
    io: Io,
) !OvmfFirmwarePair {
    const env_code = try getOptionalTestEnvPathAlloc(allocator, "ZVMI_BOOT_TEST_OVMF_CODE");
    errdefer if (env_code) |path| allocator.free(path);
    const env_vars = try getOptionalTestEnvPathAlloc(allocator, "ZVMI_BOOT_TEST_OVMF_VARS");
    errdefer if (env_vars) |path| allocator.free(path);

    if (env_code != null or env_vars != null) {
        if (env_code == null or env_vars == null) {
            std.debug.print(
                "skipping build-image QEMU boot smoke test: set both ZVMI_BOOT_TEST_OVMF_CODE and ZVMI_BOOT_TEST_OVMF_VARS together\n",
                .{},
            );
            return error.SkipZigTest;
        }

        if (!try pathAccessible(io, env_code.?, .{ .read = true }) or
            !try pathAccessible(io, env_vars.?, .{ .read = true }))
        {
            std.debug.print(
                "skipping build-image QEMU boot smoke test: configured OVMF paths are unreadable ({s}, {s})\n",
                .{ env_code.?, env_vars.? },
            );
            return error.SkipZigTest;
        }

        return .{
            .code_path = env_code.?,
            .vars_path = env_vars.?,
        };
    }

    const candidates = [_]struct { code: []const u8, vars: []const u8 }{
        .{ .code = "/usr/share/OVMF/OVMF_CODE.fd", .vars = "/usr/share/OVMF/OVMF_VARS.fd" },
        // Ubuntu's `ovmf` package (e.g. 24.04 "noble") ships only the 4M
        // variants under these names -- no plain OVMF_CODE.fd/OVMF_VARS.fd.
        .{ .code = "/usr/share/OVMF/OVMF_CODE_4M.fd", .vars = "/usr/share/OVMF/OVMF_VARS_4M.fd" },
        .{ .code = "/usr/share/edk2/ovmf/OVMF_CODE.fd", .vars = "/usr/share/edk2/ovmf/OVMF_VARS.fd" },
        .{ .code = "/usr/share/edk2/x64/OVMF_CODE.fd", .vars = "/usr/share/edk2/x64/OVMF_VARS.fd" },
    };
    inline for (candidates) |candidate| {
        if (try pathAccessible(io, candidate.code, .{ .read = true }) and
            try pathAccessible(io, candidate.vars, .{ .read = true }))
        {
            return .{
                .code_path = try allocator.dupe(u8, candidate.code),
                .vars_path = try allocator.dupe(u8, candidate.vars),
            };
        }
    }

    std.debug.print(
        "skipping build-image QEMU boot smoke test: OVMF firmware not found; set ZVMI_BOOT_TEST_OVMF_CODE and ZVMI_BOOT_TEST_OVMF_VARS\n",
        .{},
    );
    return error.SkipZigTest;
}

fn requireIsoOciFixturesAlloc(
    allocator: std.mem.Allocator,
    io: Io,
) !IsoOciFixtures {
    const iso_path = try requireProvisionedBootTestPathAlloc(
        allocator,
        io,
        "ZVMI_BOOT_TEST_ISO",
        "bootable ISO fixture",
    );
    errdefer allocator.free(iso_path);

    const oci_path = try requireProvisionedBootTestPathAlloc(
        allocator,
        io,
        "ZVMI_BOOT_TEST_OCI",
        "OCI layout fixture",
    );
    errdefer allocator.free(oci_path);

    return .{
        .iso_path = iso_path,
        .oci_path = oci_path,
    };
}

fn requireQemuBootSmokePrereqs(
    allocator: std.mem.Allocator,
    io: Io,
) !QemuBootSmokePrereqs {
    const qemu_path = try findExecutableInPathAlloc(allocator, io, "qemu-system-x86_64") orelse {
        std.debug.print(
            "skipping build-image QEMU boot smoke test: qemu-system-x86_64 not found on PATH\n",
            .{},
        );
        return error.SkipZigTest;
    };
    errdefer allocator.free(qemu_path);

    var fixtures = try requireIsoOciFixturesAlloc(allocator, io);
    errdefer fixtures.deinit(allocator);

    return .{
        .qemu_path = qemu_path,
        .iso_path = fixtures.iso_path,
        .oci_path = fixtures.oci_path,
    };
}

fn copyFileToPath(
    allocator: std.mem.Allocator,
    io: Io,
    source_path: []const u8,
    output_path: []const u8,
) !void {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = bytes });
}

/// Polling interval while waiting for the guest to reach the expected serial
/// output or for QEMU to stop running (see `runQemuBootSmoke`).
const qemu_boot_smoke_poll_interval_ms: u64 = 200;

/// Drives a QEMU boot over its QMP control socket (see issue #99): polls the
/// serial log for the expected kernel-boot marker *and* `query-status`
/// (bailing out early if QEMU stops running, e.g. a crash or guest
/// triple-fault) instead of a single blocking call with a fixed timeout, and
/// quits cleanly once the guest reaches the expected serial output.
///
/// `ovmf` is `null` for a Gen1/BIOS boot (SeaBIOS, no `-drive if=pflash`
/// entries at all -- the raw MBR disk's embedded GRUB boots directly); pass
/// a firmware pair (with `ovmf_vars_copy_path` pointing at a *writable copy*
/// of its vars file) for a Gen2/UEFI boot.
fn runQemuBootSmoke(
    allocator: std.mem.Allocator,
    io: Io,
    qemu_path: []const u8,
    ovmf: ?struct { firmware: OvmfFirmwarePair, vars_copy_path: []const u8 },
    image_path: []const u8,
    serial_output_path: []const u8,
) !QemuBootSmokeResult {
    const serial_arg = try std.fmt.allocPrint(allocator, "file:{s}", .{serial_output_path});
    defer allocator.free(serial_arg);
    const image_drive = try std.fmt.allocPrint(
        allocator,
        "file={s},format=raw,if=virtio",
        .{image_path},
    );
    defer allocator.free(image_drive);

    var ovmf_code_drive: ?[]u8 = null;
    defer if (ovmf_code_drive) |d| allocator.free(d);
    var ovmf_vars_drive: ?[]u8 = null;
    defer if (ovmf_vars_drive) |d| allocator.free(d);
    if (ovmf) |firmware_pair| {
        ovmf_code_drive = try std.fmt.allocPrint(
            allocator,
            "if=pflash,format=raw,readonly=on,file={s}",
            .{firmware_pair.firmware.code_path},
        );
        ovmf_vars_drive = try std.fmt.allocPrint(
            allocator,
            "if=pflash,format=raw,file={s}",
            .{firmware_pair.vars_copy_path},
        );
    }

    var args = std.array_list.Managed([]const u8).init(allocator);
    defer args.deinit();
    try args.appendSlice(&.{
        "-M",         "q35",
        "-accel",     "tcg",
        "-m",         "2048",
        "-display",   "none",
        "-no-reboot", "-monitor",
        "none",       "-serial",
        serial_arg,
    });
    if (ovmf_code_drive) |d| try args.appendSlice(&.{ "-drive", d });
    if (ovmf_vars_drive) |d| try args.appendSlice(&.{ "-drive", d });
    try args.appendSlice(&.{ "-drive", image_drive });

    var spawned = try qmp.spawnAndConnect(allocator, io, .{
        .binary = qemu_path,
        .extra_args = args.items,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer spawned.deinit();

    const deadline = Io.Clock.awake.now(io).addDuration(.fromSeconds(qemu_boot_smoke_timeout_seconds));
    var timed_out = true;

    while (Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds) {
        const serial_output = try readOptionalFileAlloc(allocator, io, serial_output_path, qemu_boot_smoke_serial_limit);
        const reached_boot = serialOutputShowsKernelBoot(serial_output);
        allocator.free(serial_output);

        if (reached_boot) {
            timed_out = false;
            break;
        }

        // Bail out early (rather than waiting out the full timeout) if QEMU
        // has already stopped running, e.g. a crash or guest triple-fault.
        const still_running = blk: {
            var status = qmp.qapi.queryStatus(spawned.client, allocator) catch break :blk false;
            defer status.deinit();
            break :blk status.value.running;
        };
        if (!still_running) break;

        try Io.sleep(io, .fromMilliseconds(qemu_boot_smoke_poll_interval_ms), .awake);
    }

    var quit_acknowledged = false;
    if (!timed_out) {
        // Ask QEMU to exit cleanly. Tolerate the reply read racing the
        // connection closing (a known caveat documented in qmp/README.md's
        // "quit" notes) as long as the process actually exits below.
        if (spawned.client.execute("quit", null)) |reply| {
            reply.deinit();
            quit_acknowledged = true;
        } else |_| {}
        _ = spawned.wait() catch {};
    } else {
        spawned.kill();
    }

    const serial_output = try readOptionalFileAlloc(
        allocator,
        io,
        serial_output_path,
        qemu_boot_smoke_serial_limit,
    );
    errdefer allocator.free(serial_output);

    return .{
        .timed_out = timed_out,
        .quit_acknowledged = quit_acknowledged,
        .serial_output = serial_output,
    };
}

fn serialOutputShowsKernelBoot(serial_output: []const u8) bool {
    return std.mem.indexOf(u8, serial_output, "Linux version ") != null or
        std.mem.indexOf(u8, serial_output, "Kernel command line:") != null;
}

test "build-image opportunistically boot-smokes a provisioned Gen2 raw image under QEMU" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var prereqs = try requireQemuBootSmokePrereqs(allocator, io);
    defer prereqs.deinit(allocator);
    var ovmf = try requireOvmfFirmwarePairAlloc(allocator, io);
    defer ovmf.deinit(allocator);

    const output_path = "test-build-image-qemu-gen2.raw";
    const ovmf_vars_copy_path = "test-build-image-qemu-gen2.OVMF_VARS.fd";
    const serial_output_path = "test-build-image-qemu-gen2.serial.log";
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, ovmf_vars_copy_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, serial_output_path) catch {};

    var report = try zvmi.build_image.build(allocator, io, .{
        .iso_path = prereqs.iso_path,
        .container_path = prereqs.oci_path,
        .output_path = output_path,
        .output_format = .raw,
        .generation = .gen2,
        .size = qemu_boot_smoke_disk_size,
        .extra_kernel_options = "console=tty0 console=ttyS0,115200n8",
    });
    defer report.deinit(allocator);

    try copyFileToPath(allocator, io, ovmf.vars_path, ovmf_vars_copy_path);

    var qemu = try runQemuBootSmoke(
        allocator,
        io,
        prereqs.qemu_path,
        .{ .firmware = ovmf, .vars_copy_path = ovmf_vars_copy_path },
        output_path,
        serial_output_path,
    );
    defer qemu.deinit(allocator);

    if (!serialOutputShowsKernelBoot(qemu.serial_output)) {
        std.debug.print(
            "QEMU boot smoke test did not reach kernel serial output (timed_out={}, quit_acknowledged={})\nserial output:\n{s}\n",
            .{ qemu.timed_out, qemu.quit_acknowledged, qemu.serial_output },
        );
    }
    try std.testing.expect(serialOutputShowsKernelBoot(qemu.serial_output));
}

test "build-image opportunistically boot-smokes a provisioned Gen1 BIOS raw image under QEMU" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var prereqs = try requireQemuBootSmokePrereqs(allocator, io);
    defer prereqs.deinit(allocator);

    const output_path = "test-build-image-qemu-gen1.raw";
    const serial_output_path = "test-build-image-qemu-gen1.serial.log";
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, serial_output_path) catch {};

    // Gen1/BIOS: MBR-partitioned, GRUB embedded in the post-MBR gap. No OVMF
    // needed -- QEMU's built-in SeaBIOS boots the raw disk's embedded GRUB
    // directly (see PR #82/#83 for the structural coverage this complements).
    var report = try zvmi.build_image.build(allocator, io, .{
        .iso_path = prereqs.iso_path,
        .container_path = prereqs.oci_path,
        .output_path = output_path,
        .output_format = .raw,
        .generation = .gen1,
        .size = qemu_boot_smoke_disk_size,
        .extra_kernel_options = "console=tty0 console=ttyS0,115200n8",
    });
    defer report.deinit(allocator);

    var qemu = try runQemuBootSmoke(
        allocator,
        io,
        prereqs.qemu_path,
        null,
        output_path,
        serial_output_path,
    );
    defer qemu.deinit(allocator);

    if (!serialOutputShowsKernelBoot(qemu.serial_output)) {
        std.debug.print(
            "Gen1 QEMU boot smoke test did not reach kernel serial output (timed_out={}, quit_acknowledged={})\nserial output:\n{s}\n",
            .{ qemu.timed_out, qemu.quit_acknowledged, qemu.serial_output },
        );
    }
    try std.testing.expect(serialOutputShowsKernelBoot(qemu.serial_output));
}

test "build-image --boot-mode uki fails fast against a provisioned real ISO/OCI lacking a systemd EFI stub" {
    // Like --verity (see the test below), stock installer media -- including
    // the real Azure Linux 4.0 ISO this repo's own boot-smoke fixtures use --
    // typically doesn't ship the systemd-boot-unsigned package (or
    // equivalent) that provides the systemd EFI stub UKI generation needs,
    // so `build-image --boot-mode uki` fails fast with
    // `error.MissingUkiStub` against such media rather than silently
    // producing a broken image. No QEMU needed.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fixtures = try requireIsoOciFixturesAlloc(allocator, io);
    defer fixtures.deinit(allocator);

    const output_path = "test-build-image-uki-real-media.raw";
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};

    try std.testing.expectError(error.MissingUkiStub, zvmi.build_image.build(allocator, io, .{
        .iso_path = fixtures.iso_path,
        .container_path = fixtures.oci_path,
        .output_path = output_path,
        .output_format = .raw,
        .generation = .gen2,
        .esp_size = 512 * zvmi.azure.one_mib,
        .size = qemu_boot_smoke_disk_size + 512 * zvmi.azure.one_mib,
        .boot_mode = .uki_only,
    }));
}

test "build-image --boot-mode uki opportunistically boot-smokes a provisioned stub-providing container under QEMU" {
    // Like the --verity positive case below, this needs an *extra*,
    // separately-provisioned fixture beyond the base ISO/OCI: a container
    // that adds a systemd EFI stub (e.g. linuxx64.efi.stub from the
    // systemd-boot-unsigned package) into the merged source tree. Skips
    // (not fails) when ZVMI_BOOT_TEST_UKI_OCI isn't set.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var prereqs = try requireQemuBootSmokePrereqs(allocator, io);
    defer prereqs.deinit(allocator);
    var ovmf = try requireOvmfFirmwarePairAlloc(allocator, io);
    defer ovmf.deinit(allocator);

    const uki_oci_path = try optionalProvisionedBootTestPathAlloc(allocator, io, "ZVMI_BOOT_TEST_UKI_OCI") orelse {
        std.debug.print(
            "skipping build-image --boot-mode uki QEMU boot smoke test: set ZVMI_BOOT_TEST_UKI_OCI to an OCI layout providing a systemd EFI stub\n",
            .{},
        );
        return error.SkipZigTest;
    };
    defer allocator.free(uki_oci_path);

    const output_path = "test-build-image-qemu-uki.raw";
    const ovmf_vars_copy_path = "test-build-image-qemu-uki.OVMF_VARS.fd";
    const serial_output_path = "test-build-image-qemu-uki.serial.log";
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, ovmf_vars_copy_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, serial_output_path) catch {};

    var report = try zvmi.build_image.build(allocator, io, .{
        .iso_path = prereqs.iso_path,
        .container_path = uki_oci_path,
        .output_path = output_path,
        .output_format = .raw,
        .generation = .gen2,
        // UKI mode stores the kernel/initrd inside the EFI binary itself, so
        // it needs a bigger ESP than BLS/GRUB mode -- see README.md's
        // `--esp-size` note.
        .esp_size = 512 * zvmi.azure.one_mib,
        .size = qemu_boot_smoke_disk_size + 512 * zvmi.azure.one_mib,
        .boot_mode = .uki_only,
        .extra_kernel_options = "console=tty0 console=ttyS0,115200n8",
    });
    defer report.deinit(allocator);

    try copyFileToPath(allocator, io, ovmf.vars_path, ovmf_vars_copy_path);

    var qemu = try runQemuBootSmoke(
        allocator,
        io,
        prereqs.qemu_path,
        .{ .firmware = ovmf, .vars_copy_path = ovmf_vars_copy_path },
        output_path,
        serial_output_path,
    );
    defer qemu.deinit(allocator);

    if (!serialOutputShowsKernelBoot(qemu.serial_output)) {
        std.debug.print(
            "UKI QEMU boot smoke test did not reach kernel serial output (timed_out={}, quit_acknowledged={})\nserial output:\n{s}\n",
            .{ qemu.timed_out, qemu.quit_acknowledged, qemu.serial_output },
        );
    }
    try std.testing.expect(serialOutputShowsKernelBoot(qemu.serial_output));
}

test "build-image --verity fails fast against a provisioned real ISO/OCI whose initramfs lacks verity tooling" {
    // Regression coverage for issue #77/#91: stock installer media
    // (including the real Azure Linux 4.0 ISO this repo's own boot-smoke
    // fixtures use) ships an initramfs built for the *installer*
    // environment, which has no need for -- and so typically lacks --
    // dm-verity userspace tooling. `build-image --verity` should fail fast
    // with `error.InitramfsMissingVerityTooling` against such media instead
    // of silently producing an image that hangs at boot. No QEMU needed:
    // this only exercises `zvmi.build_image.build()` itself.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fixtures = try requireIsoOciFixturesAlloc(allocator, io);
    defer fixtures.deinit(allocator);

    const output_path = "test-build-image-verity-real-media.raw";
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};

    try std.testing.expectError(error.InitramfsMissingVerityTooling, zvmi.build_image.build(allocator, io, .{
        .iso_path = fixtures.iso_path,
        .container_path = fixtures.oci_path,
        .output_path = output_path,
        .output_format = .raw,
        .generation = .gen2,
        .size = qemu_boot_smoke_disk_size,
        .verity = true,
    }));
}

test "build-image --verity opportunistically boot-smokes a provisioned verity-capable container under QEMU" {
    // Unlike the other tests in this file, this one needs an *extra*,
    // separately-provisioned fixture: an OCI container that overlays a
    // regenerated initramfs (built with e.g. `dracut --add veritysetup`)
    // at the same boot/initramfs-<kver>.img path the base ISO/squashfs
    // rootfs uses -- see README.md's "Producing a verity-capable
    // initramfs" section. Most dev/CI setups won't have this provisioned,
    // so this skips (not fails) when ZVMI_BOOT_TEST_VERITY_OCI isn't set,
    // on top of the usual QEMU/OVMF/ISO prerequisites.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var prereqs = try requireQemuBootSmokePrereqs(allocator, io);
    defer prereqs.deinit(allocator);
    var ovmf = try requireOvmfFirmwarePairAlloc(allocator, io);
    defer ovmf.deinit(allocator);

    const verity_oci_path = try optionalProvisionedBootTestPathAlloc(allocator, io, "ZVMI_BOOT_TEST_VERITY_OCI") orelse {
        std.debug.print(
            "skipping build-image --verity QEMU boot smoke test: set ZVMI_BOOT_TEST_VERITY_OCI to an OCI layout overlaying a verity-capable initramfs\n",
            .{},
        );
        return error.SkipZigTest;
    };
    defer allocator.free(verity_oci_path);

    const output_path = "test-build-image-qemu-verity.raw";
    const ovmf_vars_copy_path = "test-build-image-qemu-verity.OVMF_VARS.fd";
    const serial_output_path = "test-build-image-qemu-verity.serial.log";
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, ovmf_vars_copy_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, serial_output_path) catch {};

    var report = zvmi.build_image.build(allocator, io, .{
        .iso_path = prereqs.iso_path,
        .container_path = verity_oci_path,
        .output_path = output_path,
        .output_format = .raw,
        .generation = .gen2,
        // A --no-hostonly-regenerated verity-capable initramfs (see
        // scripts/ci/build-verity-initramfs-fixture.sh) is much bigger than
        // the stock one -- --no-hostonly deliberately includes a broad,
        // hardware-independent driver set rather than just what the build
        // host itself needs, so it reliably boots on whatever virtual
        // hardware QEMU emulates for this test. The default 96 MiB ESP
        // (sized for a hostonly-trimmed initramfs) isn't big enough for it.
        .esp_size = 512 * zvmi.azure.one_mib,
        .size = qemu_boot_smoke_disk_size + 512 * zvmi.azure.one_mib,
        .verity = true,
        .extra_kernel_options = "console=tty0 console=ttyS0,115200n8",
    }) catch |err| {
        std.debug.print("DEBUG build_image.build error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer report.deinit(allocator);

    try copyFileToPath(allocator, io, ovmf.vars_path, ovmf_vars_copy_path);

    var qemu = try runQemuBootSmoke(
        allocator,
        io,
        prereqs.qemu_path,
        .{ .firmware = ovmf, .vars_copy_path = ovmf_vars_copy_path },
        output_path,
        serial_output_path,
    );
    defer qemu.deinit(allocator);

    // "Reached target veritysetup.target" is systemd's own confirmation
    // that the dm-verity root device was set up and mounted (see the real
    // boot log captured investigating #77); a kernel-boot-only check
    // wouldn't distinguish a hung/corrupted verity mount from success.
    const reached_verity_target = std.mem.indexOf(u8, qemu.serial_output, "Reached target veritysetup.target") != null;
    if (!reached_verity_target) {
        std.debug.print(
            "--verity QEMU boot smoke test did not reach veritysetup.target (timed_out={}, quit_acknowledged={})\nserial output:\n{s}\n",
            .{ qemu.timed_out, qemu.quit_acknowledged, qemu.serial_output },
        );
    }
    try std.testing.expect(reached_verity_target);
}
