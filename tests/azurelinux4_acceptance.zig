//! Opt-in native-QEMU acceptance for finalized Azure Linux 4 QCOW2 images.
//!
//! The selected build options and `ZVMI_AZURELINUX4_IMAGE` must agree on one
//! of the four release candidates.  This deliberately refuses TCG: release
//! acceptance is run only by a native x86_64 or AArch64 matrix entry.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const qemu_host = @import("qemu_host");
const qmp = @import("qmp");
const zvmi = @import("zvmi");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

const admin_username = "zvmitest";
const boot_timeout_seconds: i64 = 8 * 60;
const serial_limit: usize = 2 * 1024 * 1024;

const Architecture = enum {
    x86_64,
    aarch64,

    fn guestArchitecture(self: Architecture) qemu_host.GuestArchitecture {
        return switch (self) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
        };
    }

    fn rootGuid(self: Architecture) zvmi.guid.Guid {
        return switch (self) {
            .x86_64 => zvmi.guid.linux_root_x86_64,
            .aarch64 => zvmi.guid.linux_root_aarch64,
        };
    }

    fn ukiMachine(self: Architecture) u16 {
        return switch (self) {
            .x86_64 => 0x8664,
            .aarch64 => 0xaa64,
        };
    }

    fn fallbackUkiPath(self: Architecture) []const u8 {
        return switch (self) {
            .x86_64 => "EFI/BOOT/BOOTX64.EFI",
            .aarch64 => "EFI/BOOT/BOOTAA64.EFI",
        };
    }

    fn serialConsole(self: Architecture) []const u8 {
        return switch (self) {
            .x86_64 => "console=ttyS0,115200n8",
            .aarch64 => "console=ttyAMA0,115200n8",
        };
    }

    fn machineArg(self: Architecture) []const u8 {
        return switch (self) {
            .x86_64 => "q35,accel=kvm,smm=off",
            .aarch64 => "virt,accel=kvm",
        };
    }

    fn nativeCpu(self: Architecture) std.Target.Cpu.Arch {
        return switch (self) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
        };
    }
};

const Flavor = enum {
    core,
    full,
};

const Candidate = struct {
    architecture: Architecture,
    flavor: Flavor,

    fn expectedFileName(self: Candidate) []const u8 {
        return switch (self.flavor) {
            .core => switch (self.architecture) {
                .x86_64 => "AzureLinux-4.0-x86_64.core.qcow2",
                .aarch64 => "AzureLinux-4.0-aarch64.core.qcow2",
            },
            .full => switch (self.architecture) {
                .x86_64 => "AzureLinux-4.0-x86_64.qcow2",
                .aarch64 => "AzureLinux-4.0-aarch64.qcow2",
            },
        };
    }

    fn expectedVirtualSize(self: Candidate) u64 {
        return switch (self.flavor) {
            .core => 1184 * 1024 * 1024,
            .full => 5 * 1024 * 1024 * 1024,
        };
    }
};

const Firmware = qemu_host.FirmwarePair;

const GuestIdentity = struct {
    machine_id: []u8,
    ssh_fingerprint: []u8,
    boot_id: []u8,

    fn deinit(self: *GuestIdentity, allocator: Allocator) void {
        allocator.free(self.machine_id);
        allocator.free(self.ssh_fingerprint);
        allocator.free(self.boot_id);
        self.* = undefined;
    }
};

const Instance = struct {
    label: []const u8,
    port: u16,
    work_path: []u8,
    overlay_path: []u8,
    vars_path: []u8,
    seed_dir: []u8,
    seed_path: []u8,
    private_key_path: []u8,
    public_key_path: []u8,
    serial_path: []u8,
    qmp_socket_path: []u8,
    spawned: ?qmp.Spawned = null,
    child_waited: bool = false,

    fn init(
        self: *Instance,
        allocator: Allocator,
        io: Io,
        parent_path: []const u8,
        label: []const u8,
        port: u16,
    ) !void {
        const work_path = try std.fs.path.join(allocator, &.{ parent_path, label });
        errdefer allocator.free(work_path);
        try Dir.cwd().createDir(io, work_path, .default_dir);
        errdefer Dir.cwd().deleteTree(io, work_path) catch {};

        const overlay_path = try std.fs.path.join(allocator, &.{ work_path, "overlay.qcow2" });
        errdefer allocator.free(overlay_path);
        const vars_path = try std.fs.path.join(allocator, &.{ work_path, "vars.fd" });
        errdefer allocator.free(vars_path);
        const seed_dir = try std.fs.path.join(allocator, &.{ work_path, "seed" });
        errdefer allocator.free(seed_dir);
        const seed_path = try std.fs.path.join(allocator, &.{ work_path, "seed.iso" });
        errdefer allocator.free(seed_path);
        const private_key_path = try std.fs.path.join(allocator, &.{ work_path, "id_ed25519" });
        errdefer allocator.free(private_key_path);
        const public_key_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{private_key_path});
        errdefer allocator.free(public_key_path);
        const serial_path = try std.fs.path.join(allocator, &.{ work_path, "serial.log" });
        errdefer allocator.free(serial_path);
        const qmp_socket_path = try std.fs.path.join(allocator, &.{ work_path, "qmp.sock" });
        errdefer allocator.free(qmp_socket_path);

        self.* = .{
            .label = label,
            .port = port,
            .work_path = work_path,
            .overlay_path = overlay_path,
            .vars_path = vars_path,
            .seed_dir = seed_dir,
            .seed_path = seed_path,
            .private_key_path = private_key_path,
            .public_key_path = public_key_path,
            .serial_path = serial_path,
            .qmp_socket_path = qmp_socket_path,
        };
    }

    fn deinit(self: *Instance, allocator: Allocator) void {
        if (self.spawned) |*spawned| {
            if (!self.child_waited) spawned.kill();
            spawned.deinit();
        }
        allocator.free(self.work_path);
        allocator.free(self.overlay_path);
        allocator.free(self.vars_path);
        allocator.free(self.seed_dir);
        allocator.free(self.seed_path);
        allocator.free(self.private_key_path);
        allocator.free(self.public_key_path);
        allocator.free(self.serial_path);
        allocator.free(self.qmp_socket_path);
        self.* = undefined;
    }

    fn dumpSerial(self: *const Instance, allocator: Allocator, io: Io) void {
        const serial = Dir.cwd().readFileAlloc(
            io,
            self.serial_path,
            allocator,
            .limited(serial_limit),
        ) catch return;
        defer allocator.free(serial);
        std.debug.print(
            "\n--- Azure Linux acceptance serial log ({s}) ---\n{s}\n--- end serial log ---\n",
            .{ self.label, serial },
        );
    }
};

fn optionalEnvAlloc(allocator: Allocator, comptime name: []const u8) !?[]u8 {
    return std.testing.environ.getAlloc(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
}

fn selectedCandidate() !Candidate {
    const architecture = std.meta.stringToEnum(
        Architecture,
        build_options.azurelinux_architecture,
    ) orelse return error.InvalidBuildArchitecture;
    const flavor = std.meta.stringToEnum(
        Flavor,
        build_options.azurelinux_flavor,
    ) orelse return error.InvalidBuildFlavor;
    return .{ .architecture = architecture, .flavor = flavor };
}

fn requireImageAlloc(
    allocator: Allocator,
    io: Io,
    candidate: Candidate,
) ![]u8 {
    const image_path = try optionalEnvAlloc(
        allocator,
        "ZVMI_AZURELINUX4_IMAGE",
    ) orelse {
        std.debug.print(
            "skipping Azure Linux 4 acceptance: set ZVMI_AZURELINUX4_IMAGE to {s}\n",
            .{candidate.expectedFileName()},
        );
        return error.SkipZigTest;
    };
    errdefer allocator.free(image_path);

    if (!std.mem.eql(u8, std.fs.path.basename(image_path), candidate.expectedFileName())) {
        std.debug.print(
            "Azure Linux 4 acceptance requires the exact finalized candidate {s}, got {s}\n",
            .{ candidate.expectedFileName(), image_path },
        );
        return error.UnexpectedCandidateName;
    }
    if (!try qemu_host.pathAccessible(io, image_path, .{ .read = true })) {
        std.debug.print(
            "ZVMI_AZURELINUX4_IMAGE is not readable: {s}\n",
            .{image_path},
        );
        return error.AcceptanceImageNotReadable;
    }
    return image_path;
}

fn requireNativeKvm(io: Io, candidate: Candidate) !void {
    if (builtin.os.tag != .linux) {
        std.debug.print(
            "skipping Azure Linux 4 acceptance: native KVM QEMU is Linux-only\n",
            .{},
        );
        return error.SkipZigTest;
    }
    if (builtin.cpu.arch != candidate.architecture.nativeCpu()) {
        std.debug.print(
            "skipping Azure Linux 4 acceptance: {s} must run on a native {s} runner (TCG is forbidden)\n",
            .{ @tagName(candidate.architecture), @tagName(candidate.architecture.nativeCpu()) },
        );
        return error.SkipZigTest;
    }
    if (!try qemu_host.pathAccessible(io, "/dev/kvm", .{ .read = true, .write = true })) {
        std.debug.print(
            "skipping Azure Linux 4 acceptance: /dev/kvm is unavailable (TCG is forbidden)\n",
            .{},
        );
        return error.SkipZigTest;
    }
}

fn requireToolAlloc(
    allocator: Allocator,
    io: Io,
    name: []const u8,
) ![]u8 {
    return try qemu_host.findExecutableInPathAlloc(
        allocator,
        io,
        std.testing.environ,
        name,
    ) orelse {
        std.debug.print(
            "skipping Azure Linux 4 acceptance: {s} is not in PATH\n",
            .{name},
        );
        return error.SkipZigTest;
    };
}

fn requireToolOverrideAlloc(
    allocator: Allocator,
    io: Io,
    comptime environment_name: []const u8,
    default_name: []const u8,
) ![]u8 {
    if (try optionalEnvAlloc(allocator, environment_name)) |path| {
        errdefer allocator.free(path);
        if (!try qemu_host.pathAccessible(io, path, .{ .execute = true }))
            return error.ToolOverrideNotExecutable;
        return path;
    }
    return requireToolAlloc(allocator, io, default_name);
}

fn requireFirmwareAlloc(
    allocator: Allocator,
    io: Io,
    qemu_path: []const u8,
    architecture: Architecture,
) !Firmware {
    const explicit_code = try optionalEnvAlloc(
        allocator,
        "ZVMI_AZURELINUX4_UEFI_CODE",
    );
    defer if (explicit_code) |path| allocator.free(path);
    const explicit_vars = try optionalEnvAlloc(
        allocator,
        "ZVMI_AZURELINUX4_UEFI_VARS",
    );
    defer if (explicit_vars) |path| allocator.free(path);

    return (try qemu_host.findFirmwarePairAlloc(allocator, io, .{
        .explicit_code_path = explicit_code,
        .explicit_vars_path = explicit_vars,
        .qemu_path = qemu_path,
        .architecture = architecture.guestArchitecture(),
    })) orelse {
        std.debug.print(
            "skipping Azure Linux 4 acceptance: matching UEFI firmware was not found; set ZVMI_AZURELINUX4_UEFI_CODE and ZVMI_AZURELINUX4_UEFI_VARS\n",
            .{},
        );
        return error.SkipZigTest;
    };
}

fn runCommand(
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{
            .raw = .fromSeconds(90),
            .clock = .awake,
        } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    if (result.stderr.len != 0) {
        std.debug.print("command failed: {s}\n", .{result.stderr});
    }
    return error.CommandFailed;
}

fn commandOutputAlloc(
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{
            .raw = .fromSeconds(90),
            .clock = .awake,
        } },
    });
    allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    allocator.free(result.stdout);
    return error.CommandFailed;
}

fn validateQemuImgInfo(
    allocator: Allocator,
    io: Io,
    qemu_img_path: []const u8,
    image_path: []const u8,
) !void {
    try runCommand(allocator, io, &.{ qemu_img_path, "check", image_path });
    const output = try commandOutputAlloc(
        allocator,
        io,
        &.{ qemu_img_path, "info", "--output=json", image_path },
    );
    defer allocator.free(output);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();
    const info = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidQemuImgInfo,
    };
    const format = info.get("format") orelse return error.InvalidQemuImgInfo;
    if (format != .string or !std.mem.eql(u8, format.string, "qcow2"))
        return error.NotQcow2;
    if (info.get("backing-filename") != null or info.get("full-backing-filename") != null)
        return error.ImageHasBackingFile;

    const format_specific = info.get("format-specific") orelse return error.InvalidQemuImgInfo;
    const format_specific_object = switch (format_specific) {
        .object => |object| object,
        else => return error.InvalidQemuImgInfo,
    };
    const format_specific_data = format_specific_object.get("data") orelse
        return error.InvalidQemuImgInfo;
    const data = switch (format_specific_data) {
        .object => |object| object,
        else => return error.InvalidQemuImgInfo,
    };
    const compression_type = data.get("compression-type") orelse
        return error.MissingZstdCompression;
    if (compression_type != .string or !std.mem.eql(u8, compression_type.string, "zstd"))
        return error.MissingZstdCompression;
}

fn requireNonemptyUkiSection(
    inspection: *const zvmi.uki.Inspection,
    name: []const u8,
) ![]const u8 {
    const section = inspection.findSection(name) orelse return error.MissingUkiSection;
    if (section.contents.len == 0) return error.EmptyUkiSection;
    return section.contents;
}

fn validateFinalizedImage(
    allocator: Allocator,
    io: Io,
    image_path: []const u8,
    candidate: Candidate,
) !void {
    var file = try Dir.cwd().openFile(io, image_path, .{ .mode = .read_only });
    var image = try zvmi.Image.openStandaloneQcow2File(io, file);
    defer image.close(io);
    file = undefined;

    if (image.format != .qcow2) return error.NotQcow2;
    const qcow2 = image.qcow2 orelse return error.NotQcow2;
    if (qcow2.backing_file_len != 0) return error.ImageHasBackingFile;
    if (qcow2.data_file_len != 0) return error.ImageHasExternalDataFile;
    if (qcow2.compression_type != 1) return error.MissingZstdCompression;
    if (image.virtual_size != candidate.expectedVirtualSize())
        return error.UnexpectedVirtualSize;

    const parsed = try zvmi.gpt.readGpt(image, io, allocator);
    defer allocator.free(parsed.partitions);
    if (parsed.partitions.len != 2) return error.UnexpectedPartitionCount;
    const esp_partition = parsed.partitions[0];
    const root_partition = parsed.partitions[1];
    if (!std.mem.eql(u8, &esp_partition.partition_type_guid, &zvmi.guid.esp))
        return error.UnexpectedEspPartition;
    if (!std.mem.eql(u8, &root_partition.partition_type_guid, &candidate.architecture.rootGuid()))
        return error.UnexpectedRootArchitecture;
    const esp_size = (esp_partition.last_lba - esp_partition.first_lba + 1) *
        zvmi.gpt.sector_size;
    if (esp_size != 512 * 1024 * 1024)
        return error.UnexpectedEspSize;
    if (esp_partition.first_lba % (1024 * 1024 / zvmi.gpt.sector_size) != 0)
        return error.UnexpectedEspAlignment;
    if (root_partition.first_lba != esp_partition.last_lba + 1 or
        root_partition.last_lba != parsed.header.last_usable_lba or
        root_partition.last_lba < root_partition.first_lba)
        return error.InvalidRootPartition;
    if (std.mem.eql(u8, &root_partition.unique_partition_guid, &zvmi.guid.nil))
        return error.InvalidRootPartitionGuid;

    var esp = try zvmi.fat32.open(&image, io, .{
        .offset = esp_partition.first_lba * zvmi.gpt.sector_size,
        .length = (esp_partition.last_lba - esp_partition.first_lba + 1) *
            zvmi.gpt.sector_size,
    });
    const uki = try esp.readFileAlloc(
        io,
        allocator,
        candidate.architecture.fallbackUkiPath(),
    );
    defer allocator.free(uki);

    var inspection = try zvmi.uki.inspect(allocator, uki);
    defer inspection.deinit(allocator);
    if (inspection.machine != candidate.architecture.ukiMachine())
        return error.UnexpectedUkiArchitecture;
    if (inspection.subsystem != 10) return error.UnexpectedUkiSubsystem;
    _ = try requireNonemptyUkiSection(&inspection, ".linux");
    _ = try requireNonemptyUkiSection(&inspection, ".initrd");
    _ = try requireNonemptyUkiSection(&inspection, ".osrel");
    _ = try requireNonemptyUkiSection(&inspection, ".uname");
    const cmdline = try requireNonemptyUkiSection(&inspection, ".cmdline");

    var root_guid_text: [36]u8 = undefined;
    const root_guid = zvmi.guid.formatLower(
        &root_guid_text,
        root_partition.unique_partition_guid,
    );
    const expected_prefix = try std.fmt.allocPrint(
        allocator,
        "root=PARTUUID={s} ",
        .{root_guid},
    );
    defer allocator.free(expected_prefix);
    if (!std.mem.startsWith(u8, cmdline, expected_prefix))
        return error.UnexpectedUkiCmdline;

    switch (candidate.flavor) {
        .core => {
            const expected = try std.fmt.allocPrint(
                allocator,
                "{s}init=/sbin/zvminit zvminit.mode=persistent zvminit.azure=auto console=tty0 {s}",
                .{ expected_prefix, candidate.architecture.serialConsole() },
            );
            defer allocator.free(expected);
            if (!std.mem.eql(u8, cmdline, expected))
                return error.UnexpectedCoreUkiCmdline;
        },
        .full => {
            const expected = try std.fmt.allocPrint(
                allocator,
                "{s}{s}",
                .{ expected_prefix, candidate.architecture.serialConsole() },
            );
            defer allocator.free(expected);
            if (!std.mem.eql(u8, cmdline, expected))
                return error.UnexpectedFullUkiCmdline;
            if (std.mem.indexOf(u8, cmdline, "init=/sbin/zvminit") != null)
                return error.FullImageContainsZvminitBootContract;
        },
    }
}

fn createSeed(
    allocator: Allocator,
    io: Io,
    xorriso_path: []const u8,
    ssh_keygen_path: []const u8,
    instance: *const Instance,
) !void {
    try runCommand(allocator, io, &.{
        ssh_keygen_path,
        "-q",
        "-t",
        "ed25519",
        "-N",
        "",
        "-f",
        instance.private_key_path,
    });
    const public_key_file = try Dir.cwd().readFileAlloc(
        io,
        instance.public_key_path,
        allocator,
        .limited(16 * 1024),
    );
    defer allocator.free(public_key_file);
    const public_key = std.mem.trim(u8, public_key_file, " \t\r\n");

    try Dir.cwd().createDir(io, instance.seed_dir, .default_dir);
    const metadata = try std.fmt.allocPrint(
        allocator,
        "instance-id: zvmi-azurelinux4-acceptance-{s}\n" ++
            "local-hostname: zvmi-azurelinux4-{s}\n",
        .{ instance.label, instance.label },
    );
    defer allocator.free(metadata);
    const user_data = try std.fmt.allocPrint(
        allocator,
        \\#cloud-config
        \\users:
        \\  - default
        \\  - name: zvmitest
        \\    groups: wheel
        \\    shell: /bin/bash
        \\    sudo: "ALL=(ALL) NOPASSWD:ALL"
        \\    ssh_authorized_keys:
        \\      - {s}
        \\ssh_pwauth: false
        \\disable_root: true
        \\
    ,
        .{public_key},
    );
    defer allocator.free(user_data);
    const ovf_env = try std.fmt.allocPrint(
        allocator,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<Environment xmlns="http://schemas.dmtf.org/ovf/environment/1" xmlns:wa="http://schemas.microsoft.com/windowsazure">
        \\  <wa:ProvisioningSection>
        \\    <LinuxProvisioningConfigurationSet xmlns="http://schemas.microsoft.com/windowsazure">
        \\      <ConfigurationSetType>LinuxProvisioningConfiguration</ConfigurationSetType>
        \\      <HostName>zvmi-azurelinux4-{s}</HostName>
        \\      <UserName>{s}</UserName>
        \\      <DisableSshPasswordAuthentication>true</DisableSshPasswordAuthentication>
        \\      <SSH><PublicKeys><PublicKey><Path>/home/{s}/.ssh/authorized_keys</Path><Value>{s}</Value></PublicKey></PublicKeys></SSH>
        \\    </LinuxProvisioningConfigurationSet>
        \\  </wa:ProvisioningSection>
        \\</Environment>
        \\
    ,
        .{ instance.label, admin_username, admin_username, public_key },
    );
    defer allocator.free(ovf_env);

    const metadata_path = try std.fs.path.join(allocator, &.{ instance.seed_dir, "meta-data" });
    defer allocator.free(metadata_path);
    const user_data_path = try std.fs.path.join(allocator, &.{ instance.seed_dir, "user-data" });
    defer allocator.free(user_data_path);
    const ovf_path = try std.fs.path.join(allocator, &.{ instance.seed_dir, "ovf-env.xml" });
    defer allocator.free(ovf_path);
    const marker_path = try std.fs.path.join(
        allocator,
        &.{ instance.seed_dir, "zvmi-local-provisioning" },
    );
    defer allocator.free(marker_path);

    try Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata });
    try Dir.cwd().writeFile(io, .{ .sub_path = user_data_path, .data = user_data });
    try Dir.cwd().writeFile(io, .{ .sub_path = ovf_path, .data = ovf_env });
    try Dir.cwd().writeFile(io, .{ .sub_path = marker_path, .data = "" });

    try runCommand(allocator, io, &.{
        xorriso_path,
        "-as",
        "mkisofs",
        "-quiet",
        "-iso-level",
        "3",
        "-R",
        "-J",
        "-V",
        "cidata",
        "-o",
        instance.seed_path,
        instance.seed_dir,
    });
}

fn startInstance(
    allocator: Allocator,
    io: Io,
    qemu_img_path: []const u8,
    qemu_path: []const u8,
    xorriso_path: []const u8,
    ssh_keygen_path: []const u8,
    firmware: *const Firmware,
    source_image: []const u8,
    candidate: Candidate,
    instance: *Instance,
) !void {
    try runCommand(allocator, io, &.{
        qemu_img_path,
        "create",
        "-q",
        "-f",
        "qcow2",
        "-F",
        "qcow2",
        "-b",
        source_image,
        instance.overlay_path,
    });
    try Dir.copyFileAbsolute(firmware.vars_path, instance.vars_path, io, .{
        .replace = false,
    });
    try createSeed(allocator, io, xorriso_path, ssh_keygen_path, instance);

    const hostfwd = try std.fmt.allocPrint(
        allocator,
        "user,id=net0,hostfwd=tcp:127.0.0.1:{d}-:22",
        .{instance.port},
    );
    defer allocator.free(hostfwd);
    const serial_arg = try std.fmt.allocPrint(allocator, "file:{s}", .{instance.serial_path});
    defer allocator.free(serial_arg);
    const code_drive = try std.fmt.allocPrint(
        allocator,
        "if=pflash,unit=0,format=raw,readonly=on,file={s}",
        .{firmware.code_path},
    );
    defer allocator.free(code_drive);
    const vars_drive = try std.fmt.allocPrint(
        allocator,
        "if=pflash,unit=1,format=raw,file={s}",
        .{instance.vars_path},
    );
    defer allocator.free(vars_drive);
    const image_drive = try std.fmt.allocPrint(
        allocator,
        "file={s},format=qcow2,if=virtio",
        .{instance.overlay_path},
    );
    defer allocator.free(image_drive);
    const seed_drive = try std.fmt.allocPrint(
        allocator,
        "file={s},if=none,id=seed,media=cdrom,readonly=on,format=raw",
        .{instance.seed_path},
    );
    defer allocator.free(seed_drive);

    instance.spawned = try qmp.spawnAndConnect(allocator, io, .{
        .binary = qemu_path,
        .qmp_socket_path = instance.qmp_socket_path,
        .connect_timeout = .fromSeconds(30),
        .extra_args = &.{
            "-machine",
            candidate.architecture.machineArg(),
            "-cpu",
            "host",
            "-smp",
            "2",
            "-m",
            "2048",
            "-display",
            "none",
            "-monitor",
            "none",
            "-serial",
            serial_arg,
            "-no-shutdown",
            "-drive",
            code_drive,
            "-drive",
            vars_drive,
            "-drive",
            image_drive,
            "-device",
            "virtio-scsi-pci,id=scsi0",
            "-drive",
            seed_drive,
            "-device",
            "scsi-cd,drive=seed,bus=scsi0.0",
            "-netdev",
            hostfwd,
            "-device",
            "virtio-net-pci,netdev=net0,romfile=",
            "-device",
            "virtio-rng-pci",
        },
        .stdout = .ignore,
        .stderr = .inherit,
    });
}

fn commandSucceeded(
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
) !bool {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
        .timeout = .{ .duration = .{
            .raw = .fromSeconds(20),
            .clock = .awake,
        } },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn sshSucceeded(
    allocator: Allocator,
    io: Io,
    ssh_path: []const u8,
    instance: *const Instance,
    command: []const u8,
) !bool {
    const port_text = try std.fmt.allocPrint(allocator, "{d}", .{instance.port});
    defer allocator.free(port_text);
    return commandSucceeded(allocator, io, &.{
        ssh_path,
        "-i",
        instance.private_key_path,
        "-p",
        port_text,
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=5",
        "-o",
        "ConnectionAttempts=1",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "KbdInteractiveAuthentication=no",
        "-o",
        "PasswordAuthentication=no",
        "-o",
        "NumberOfPasswordPrompts=0",
        "-o",
        "PreferredAuthentications=publickey",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        admin_username ++ "@127.0.0.1",
        command,
    });
}

fn sshOutputAlloc(
    allocator: Allocator,
    io: Io,
    ssh_path: []const u8,
    instance: *const Instance,
    command: []const u8,
) ![]u8 {
    const port_text = try std.fmt.allocPrint(allocator, "{d}", .{instance.port});
    defer allocator.free(port_text);
    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            ssh_path,
            "-i",
            instance.private_key_path,
            "-p",
            port_text,
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=5",
            "-o",
            "ConnectionAttempts=1",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "KbdInteractiveAuthentication=no",
            "-o",
            "PasswordAuthentication=no",
            "-o",
            "NumberOfPasswordPrompts=0",
            "-o",
            "PreferredAuthentications=publickey",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            admin_username ++ "@127.0.0.1",
            command,
        },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
        .timeout = .{ .duration = .{
            .raw = .fromSeconds(20),
            .clock = .awake,
        } },
    });
    allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    allocator.free(result.stdout);
    return error.SshCommandFailed;
}

fn qemuRunning(instance: *const Instance, deadline: Io.Timestamp) !bool {
    const spawned = &(instance.spawned orelse return error.QemuNotStarted);
    return spawned.client.queryRunningUntil(deadline);
}

fn waitForSsh(
    allocator: Allocator,
    io: Io,
    ssh_path: []const u8,
    instance: *const Instance,
) !void {
    const deadline = Io.Clock.awake.now(io).addDuration(.fromSeconds(boot_timeout_seconds));
    while (Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds) {
        if (try sshSucceeded(allocator, io, ssh_path, instance, "true")) return;
        if (!try qemuRunning(instance, deadline)) return error.QemuExitedEarly;
        try Io.sleep(io, .fromSeconds(2), .awake);
    }
    return error.SshTimedOut;
}

const identity_command =
    \\set -eu
    \\test -s /etc/machine-id
    \\test -s /etc/ssh/ssh_host_ed25519_key.pub
    \\cat /etc/machine-id
    \\/usr/bin/ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256 | /usr/bin/awk '{ print $2 }'
    \\cat /proc/sys/kernel/random/boot_id
;

fn readGuestIdentityAlloc(
    allocator: Allocator,
    io: Io,
    ssh_path: []const u8,
    instance: *const Instance,
) !GuestIdentity {
    const output = try sshOutputAlloc(allocator, io, ssh_path, instance, identity_command);
    defer allocator.free(output);
    var lines = std.mem.splitScalar(u8, output, '\n');
    const machine_id = std.mem.trim(u8, lines.next() orelse return error.InvalidGuestIdentity, " \t\r");
    const ssh_fingerprint = std.mem.trim(u8, lines.next() orelse return error.InvalidGuestIdentity, " \t\r");
    const boot_id = std.mem.trim(u8, lines.next() orelse return error.InvalidGuestIdentity, " \t\r");
    if (machine_id.len == 0 or ssh_fingerprint.len == 0 or boot_id.len == 0)
        return error.InvalidGuestIdentity;
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len != 0)
            return error.InvalidGuestIdentity;
    }

    const owned_machine_id = try allocator.dupe(u8, machine_id);
    errdefer allocator.free(owned_machine_id);
    const owned_ssh_fingerprint = try allocator.dupe(u8, ssh_fingerprint);
    errdefer allocator.free(owned_ssh_fingerprint);
    return .{
        .machine_id = owned_machine_id,
        .ssh_fingerprint = owned_ssh_fingerprint,
        .boot_id = try allocator.dupe(u8, boot_id),
    };
}

fn verifyAdminLogin(
    allocator: Allocator,
    io: Io,
    ssh_path: []const u8,
    instance: *const Instance,
) !void {
    const output = try sshOutputAlloc(allocator, io, ssh_path, instance, "id -un");
    defer allocator.free(output);
    if (!std.mem.eql(u8, std.mem.trim(u8, output, " \t\r\n"), admin_username))
        return error.UnexpectedAdminUsername;
}

const core_checks =
    \\set -eu
    \\test /proc/1/exe -ef /sbin/zvminit
    \\test -f /var/lib/azagent/provisioned
    \\find_sshd_master() {
    \\  for proc in /proc/[0-9]*; do
    \\    test -r "$proc/status" || continue
    \\    name=$(awk '/^Name:/{print $2}' "$proc/status")
    \\    ppid=$(awk '/^PPid:/{print $2}' "$proc/status")
    \\    test "$name" = sshd && test "$ppid" = 1 || continue
    \\    cmdline=$(tr '\000' ' ' < "$proc/cmdline")
    \\    case "$cmdline" in
    \\      *"/usr/sbin/sshd -D -e"*) printf '%s\n' "${proc##*/}"; return 0 ;;
    \\    esac
    \\  done
    \\  return 1
    \\}
    \\find_sshd_master
;

fn readCoreSshdPid(
    allocator: Allocator,
    io: Io,
    ssh_path: []const u8,
    instance: *const Instance,
) !i32 {
    const output = try sshOutputAlloc(allocator, io, ssh_path, instance, core_checks);
    defer allocator.free(output);
    const pid_text = std.mem.trim(u8, output, " \t\r\n");
    return std.fmt.parseInt(i32, pid_text, 10) catch error.InvalidSshdPid;
}

const full_checks =
    \\set -eu
    \\test /proc/1/exe -ef /usr/lib/systemd/systemd
    \\test ! -e /sbin/zvminit
    \\test ! -e /usr/bin/zvminit
    \\for unit in cloud-init-local.service cloud-init-main.service cloud-init-network.service cloud-config.service cloud-final.service waagent.service sshd.service systemd-networkd.service; do
    \\  systemctl is-active --quiet "$unit"
    \\  systemctl is-enabled --quiet "$unit"
    \\done
;

fn verifyFlavorRuntime(
    allocator: Allocator,
    io: Io,
    ssh_path: []const u8,
    candidate: Candidate,
    instance: *const Instance,
) !void {
    switch (candidate.flavor) {
        .core => _ = try readCoreSshdPid(allocator, io, ssh_path, instance),
        .full => {
            if (!try sshSucceeded(allocator, io, ssh_path, instance, full_checks))
                return error.FullServiceContractFailed;
        },
    }
}

fn verifyCoreSshdRestart(
    allocator: Allocator,
    io: Io,
    ssh_path: []const u8,
    instance: *const Instance,
) !void {
    const initial_pid = try readCoreSshdPid(allocator, io, ssh_path, instance);
    const kill_command = try std.fmt.allocPrint(
        allocator,
        "sudo -n /usr/bin/kill -KILL {d}",
        .{initial_pid},
    );
    defer allocator.free(kill_command);
    _ = sshSucceeded(allocator, io, ssh_path, instance, kill_command) catch false;

    const deadline = Io.Clock.awake.now(io).addDuration(.fromSeconds(boot_timeout_seconds));
    while (Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds) {
        if (readCoreSshdPid(allocator, io, ssh_path, instance)) |new_pid| {
            if (new_pid != initial_pid) return;
        } else |err| switch (err) {
            error.SshCommandFailed => {},
            else => return err,
        }
        if (!try qemuRunning(instance, deadline)) return error.QemuExitedEarly;
        try Io.sleep(io, .fromSeconds(2), .awake);
    }
    return error.SshdDidNotRestart;
}

fn rebootAndReadIdentity(
    allocator: Allocator,
    io: Io,
    ssh_path: []const u8,
    instance: *const Instance,
    before: *const GuestIdentity,
) !GuestIdentity {
    _ = sshSucceeded(
        allocator,
        io,
        ssh_path,
        instance,
        "sudo -n /sbin/reboot",
    ) catch false;

    const deadline = Io.Clock.awake.now(io).addDuration(.fromSeconds(boot_timeout_seconds));
    while (Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds) {
        if (readGuestIdentityAlloc(allocator, io, ssh_path, instance)) |identity| {
            if (!std.mem.eql(u8, identity.boot_id, before.boot_id))
                return identity;
            var unchanged = identity;
            unchanged.deinit(allocator);
        } else |err| switch (err) {
            error.SshCommandFailed => {},
            else => return err,
        }
        if (!try qemuRunning(instance, deadline)) return error.QemuExitedEarly;
        try Io.sleep(io, .fromSeconds(2), .awake);
    }
    return error.RebootTimedOut;
}

fn waitForQemuExit(io: Io, instance: *Instance) !std.process.Child.Term {
    const spawned = &(instance.spawned orelse return error.QemuNotStarted);
    const deadline = Io.Clock.awake.now(io).addDuration(.fromSeconds(boot_timeout_seconds));
    while (Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds) {
        if (!try spawned.client.queryRunningUntil(deadline)) {
            var reply = try spawned.client.executeUntil("quit", null, deadline);
            defer reply.deinit();
            if (reply.err != null) return error.QemuQuitFailed;
            const term = try spawned.waitUntil(deadline);
            instance.child_waited = true;
            return term;
        }
        try Io.sleep(io, .fromMilliseconds(500), .awake);
    }
    return error.QemuShutdownTimedOut;
}

fn poweroff(
    allocator: Allocator,
    io: Io,
    ssh_path: []const u8,
    instance: *Instance,
) !void {
    _ = sshSucceeded(
        allocator,
        io,
        ssh_path,
        instance,
        "sudo -n /sbin/poweroff",
    ) catch false;
    const term = try waitForQemuExit(io, instance);
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.QemuDidNotExitCleanly;
}

test "Azure Linux 4 acceptance candidate names are exact" {
    try std.testing.expectEqualStrings(
        "AzureLinux-4.0-x86_64.qcow2",
        (Candidate{ .architecture = .x86_64, .flavor = .full }).expectedFileName(),
    );
    try std.testing.expectEqualStrings(
        "AzureLinux-4.0-aarch64.qcow2",
        (Candidate{ .architecture = .aarch64, .flavor = .full }).expectedFileName(),
    );
    try std.testing.expectEqualStrings(
        "AzureLinux-4.0-x86_64.core.qcow2",
        (Candidate{ .architecture = .x86_64, .flavor = .core }).expectedFileName(),
    );
    try std.testing.expectEqualStrings(
        "AzureLinux-4.0-aarch64.core.qcow2",
        (Candidate{ .architecture = .aarch64, .flavor = .core }).expectedFileName(),
    );
}

test "Azure Linux 4 finalized QCOW2 boots, provisions, restarts, and powers off" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const candidate = try selectedCandidate();
    try requireNativeKvm(io, candidate);

    const image_path = try requireImageAlloc(allocator, io, candidate);
    defer allocator.free(image_path);
    const absolute_image = try Dir.cwd().realPathFileAlloc(io, image_path, allocator);
    defer allocator.free(absolute_image);
    if (!std.mem.eql(u8, std.fs.path.basename(absolute_image), candidate.expectedFileName()))
        return error.UnexpectedCandidateName;

    const qemu_path = try requireToolOverrideAlloc(
        allocator,
        io,
        "ZVMI_AZURELINUX4_QEMU",
        qemu_host.qemuSystemName(candidate.architecture.guestArchitecture()),
    );
    defer allocator.free(qemu_path);
    const qemu_img_path = try requireToolAlloc(allocator, io, "qemu-img");
    defer allocator.free(qemu_img_path);
    const xorriso_path = try requireToolAlloc(allocator, io, "xorriso");
    defer allocator.free(xorriso_path);
    const ssh_keygen_path = try requireToolAlloc(allocator, io, "ssh-keygen");
    defer allocator.free(ssh_keygen_path);
    const ssh_path = try requireToolAlloc(allocator, io, "ssh");
    defer allocator.free(ssh_path);
    var firmware = try requireFirmwareAlloc(
        allocator,
        io,
        qemu_path,
        candidate.architecture,
    );
    defer firmware.deinit(allocator);

    try validateQemuImgInfo(allocator, io, qemu_img_path, absolute_image);
    try validateFinalizedImage(allocator, io, absolute_image, candidate);
    const source_sha256 = (try zvmi.artifact_pipeline.hashFile(
        io,
        absolute_image,
    )).sha256;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var temporary_path_buffer: [Dir.max_path_bytes]u8 = undefined;
    const temporary_path_length = try temporary.dir.realPath(io, &temporary_path_buffer);
    const temporary_path = temporary_path_buffer[0..temporary_path_length];

    var first: Instance = undefined;
    try first.init(allocator, io, temporary_path, "first", 22220);
    defer first.deinit(allocator);
    errdefer first.dumpSerial(allocator, io);

    var second: Instance = undefined;
    try second.init(allocator, io, temporary_path, "second", 22221);
    defer second.deinit(allocator);
    errdefer second.dumpSerial(allocator, io);

    // Launch both before waiting for either guest: identity generation is
    // thereby exercised by two concurrent first boots from one source image.
    try startInstance(
        allocator,
        io,
        qemu_img_path,
        qemu_path,
        xorriso_path,
        ssh_keygen_path,
        &firmware,
        absolute_image,
        candidate,
        &first,
    );
    try startInstance(
        allocator,
        io,
        qemu_img_path,
        qemu_path,
        xorriso_path,
        ssh_keygen_path,
        &firmware,
        absolute_image,
        candidate,
        &second,
    );

    try waitForSsh(allocator, io, ssh_path, &first);
    try waitForSsh(allocator, io, ssh_path, &second);
    try verifyAdminLogin(allocator, io, ssh_path, &first);
    try verifyAdminLogin(allocator, io, ssh_path, &second);
    try verifyFlavorRuntime(allocator, io, ssh_path, candidate, &first);
    try verifyFlavorRuntime(allocator, io, ssh_path, candidate, &second);

    var first_before = try readGuestIdentityAlloc(allocator, io, ssh_path, &first);
    defer first_before.deinit(allocator);
    var second_before = try readGuestIdentityAlloc(allocator, io, ssh_path, &second);
    defer second_before.deinit(allocator);
    try std.testing.expect(!std.mem.eql(
        u8,
        first_before.machine_id,
        second_before.machine_id,
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        first_before.ssh_fingerprint,
        second_before.ssh_fingerprint,
    ));

    if (candidate.flavor == .core) {
        try verifyCoreSshdRestart(allocator, io, ssh_path, &first);
        try verifyCoreSshdRestart(allocator, io, ssh_path, &second);
    }

    var first_after = try rebootAndReadIdentity(
        allocator,
        io,
        ssh_path,
        &first,
        &first_before,
    );
    defer first_after.deinit(allocator);
    var second_after = try rebootAndReadIdentity(
        allocator,
        io,
        ssh_path,
        &second,
        &second_before,
    );
    defer second_after.deinit(allocator);

    try std.testing.expectEqualStrings(
        first_before.machine_id,
        first_after.machine_id,
    );
    try std.testing.expectEqualStrings(
        first_before.ssh_fingerprint,
        first_after.ssh_fingerprint,
    );
    try std.testing.expectEqualStrings(
        second_before.machine_id,
        second_after.machine_id,
    );
    try std.testing.expectEqualStrings(
        second_before.ssh_fingerprint,
        second_after.ssh_fingerprint,
    );
    try verifyFlavorRuntime(allocator, io, ssh_path, candidate, &first);
    try verifyFlavorRuntime(allocator, io, ssh_path, candidate, &second);

    try poweroff(allocator, io, ssh_path, &first);
    try poweroff(allocator, io, ssh_path, &second);
    try std.testing.expectEqual(
        source_sha256,
        (try zvmi.artifact_pipeline.hashFile(io, absolute_image)).sha256,
    );
}
