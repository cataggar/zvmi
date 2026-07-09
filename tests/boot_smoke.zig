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
    ovmf: OvmfFirmwarePair,
    iso_path: []u8,
    oci_path: []u8,

    fn deinit(self: *QemuBootSmokePrereqs, allocator: std.mem.Allocator) void {
        allocator.free(self.qemu_path);
        self.ovmf.deinit(allocator);
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

    const ovmf = try requireOvmfFirmwarePairAlloc(allocator, io);
    errdefer {
        var ovmf_to_free = ovmf;
        ovmf_to_free.deinit(allocator);
    }

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
        .qemu_path = qemu_path,
        .ovmf = ovmf,
        .iso_path = iso_path,
        .oci_path = oci_path,
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
/// output or for QEMU to stop running (see `runGen2QemuBootSmoke`).
const qemu_boot_smoke_poll_interval_ms: u64 = 200;

fn runGen2QemuBootSmoke(
    allocator: std.mem.Allocator,
    io: Io,
    prereqs: QemuBootSmokePrereqs,
    image_path: []const u8,
    ovmf_vars_copy_path: []const u8,
    serial_output_path: []const u8,
) !QemuBootSmokeResult {
    const serial_arg = try std.fmt.allocPrint(allocator, "file:{s}", .{serial_output_path});
    defer allocator.free(serial_arg);
    const ovmf_code_drive = try std.fmt.allocPrint(
        allocator,
        "if=pflash,format=raw,readonly=on,file={s}",
        .{prereqs.ovmf.code_path},
    );
    defer allocator.free(ovmf_code_drive);
    const ovmf_vars_drive = try std.fmt.allocPrint(
        allocator,
        "if=pflash,format=raw,file={s}",
        .{ovmf_vars_copy_path},
    );
    defer allocator.free(ovmf_vars_drive);
    const image_drive = try std.fmt.allocPrint(
        allocator,
        "file={s},format=raw,if=virtio",
        .{image_path},
    );
    defer allocator.free(image_drive);

    // Drive QEMU over its QMP control socket (via `qmp.spawnAndConnect`)
    // instead of a single blocking `std.process.run(...).timeout`: this lets
    // us poll for the guest reaching the expected serial output *or* QEMU
    // itself stopping running (crash/triple-fault), and quit cleanly on
    // success, rather than always waiting out a fixed timeout regardless of
    // how quickly the guest actually finished booting (see issue #99).
    var spawned = try qmp.spawnAndConnect(allocator, io, .{
        .binary = prereqs.qemu_path,
        .extra_args = &.{
            "-M",            "q35",
            "-accel",        "tcg",
            "-m",            "2048",
            "-display",      "none",
            "-no-reboot",    "-monitor",
            "none",          "-serial",
            serial_arg,      "-drive",
            ovmf_code_drive, "-drive",
            ovmf_vars_drive, "-drive",
            image_drive,
        },
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

    const output_path = "test-build-image-qemu-gen2.raw";
    const ovmf_vars_copy_path = "test-build-image-qemu-gen2.OVMF_VARS.fd";
    const serial_output_path = "test-build-image-qemu-gen2.serial.log";
    defer Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, ovmf_vars_copy_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, serial_output_path) catch {};

    // The in-tree synthetic build-image fixture intentionally uses placeholder
    // EFI, GRUB, kernel, and initramfs bytes, so real QEMU smoke coverage has
    // to consume provisioned local artifacts. Expand this to Gen1, verity, and
    // UKI cases once a smaller real-media fixture story exists (see #59 / #51).
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

    try copyFileToPath(allocator, io, prereqs.ovmf.vars_path, ovmf_vars_copy_path);

    var qemu = try runGen2QemuBootSmoke(
        allocator,
        io,
        prereqs,
        output_path,
        ovmf_vars_copy_path,
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
