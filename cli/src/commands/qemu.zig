//! `zvmi qemu [<image>] [--architecture auto|x86_64|aarch64]
//!             [--admin-username <name>] [--ssh-public-key <path>]
//!             [--ssh-port <port>] [--snapshot] [--accel auto|whpx|kvm|hvf|tcg]
//!             [--qemu <path>] [--ovmf-code <path>] [--ovmf-vars <path>]
//!             [-- <extra-qemu-args...>]`

const std = @import("std");
const builtin = @import("builtin");
const zvmi = @import("zvmi");
const qemu_host = @import("qemu_host");
const guest_validation = @import("guest_validation");

const GuestArchitecture = qemu_host.GuestArchitecture;

const KnownImage = struct {
    alias: []const u8,
    disk_name: []const u8,
    release_spec: []const u8,
    architecture: GuestArchitecture,
};

const known_images = [_]KnownImage{
    .{
        .alias = "AzureLinux-4.0-x86_64",
        .disk_name = "AzureLinux-4.0-x86_64.qcow2",
        .release_spec = "cataggar/zvmi/AzureLinux-4.0-x86_64.qcow2@AzureLinux-4.0-20260721",
        .architecture = .x86_64,
    },
    .{
        .alias = "AzureLinux-4.0-aarch64",
        .disk_name = "AzureLinux-4.0-aarch64.qcow2",
        .release_spec = "cataggar/zvmi/AzureLinux-4.0-aarch64.qcow2@AzureLinux-4.0-20260721",
        .architecture = .aarch64,
    },
};

const default_image_name = known_images[0].disk_name;
const default_image_spec = known_images[0].release_spec;
const default_ssh_port: u16 = 2222;
const max_ssh_port: u16 = 65535;
const local_provisioning_marker = "zvmi-local-provisioning";

const help_text =
    \\usage: zvmi qemu [<image>] [--architecture auto|x86_64|aarch64]
    \\                  [--admin-username <name>] [--ssh-public-key <path>]
    \\                  [--ssh-port <port>] [--snapshot] [--accel auto|whpx|kvm|hvf|tcg]
    \\                  [--qemu <path>] [--ovmf-code <path>] [--ovmf-vars <path>]
    \\                  [-- <extra-qemu-args...>]
    \\
    \\Boot an x86_64 or AArch64 Gen2/UEFI image interactively under QEMU.
    \\
    \\Known aliases:
    \\  AzureLinux
    \\  AzureLinux-4.0-x86_64
    \\  AzureLinux-4.0-aarch64
    \\
    \\A known alias downloads its missing .qcow2 with ghr. An explicit disk
    \\path must already exist. Missing .code.fd and .vars.fd bundle files are
    \\copied or decompressed beside the disk without modifying QEMU's files.
    \\
    \\Options:
    \\  --snapshot          Discard guest disk and UEFI variable changes on exit.
    \\  --architecture <a> Guest architecture: auto, x86_64 (default), or aarch64.
    \\  --admin-username <n> Provision this administrator account (requires a key).
    \\  --ssh-public-key <p> Read this public key for administrator provisioning.
    \\  --ssh-port <port>   Forward localhost TCP port to guest SSH (default 2222).
    \\  --xorriso <path>    Explicit xorriso executable for provisioning media.
    \\  --accel <name>      Accelerator: auto (default), whpx, kvm, hvf, or tcg.
    \\  --qemu <path>       Explicit architecture-specific QEMU executable.
    \\  --firmware-code <p> Explicit read-only UEFI code firmware (OVMF alias).
    \\  --firmware-vars <p> Explicit UEFI variables template (OVMF alias).
    \\  --ovmf-code/--ovmf-vars Retained compatibility aliases.
    \\  -h, --help          Show this help.
    \\
;

const Accel = enum {
    auto,
    whpx,
    kvm,
    hvf,
    tcg,

    fn parse(value: []const u8) ?Accel {
        if (std.mem.eql(u8, value, "auto")) return .auto;
        if (std.mem.eql(u8, value, "whpx")) return .whpx;
        if (std.mem.eql(u8, value, "kvm")) return .kvm;
        if (std.mem.eql(u8, value, "hvf")) return .hvf;
        if (std.mem.eql(u8, value, "tcg")) return .tcg;
        return null;
    }

    fn cliName(self: Accel) []const u8 {
        return @tagName(self);
    }
};

const ArchitectureRequest = enum {
    x86_64,
    aarch64,
    auto,

    fn parse(value: []const u8) ?ArchitectureRequest {
        if (std.mem.eql(u8, value, "auto")) return .auto;
        if (std.mem.eql(u8, value, "x86_64")) return .x86_64;
        if (std.mem.eql(u8, value, "aarch64")) return .aarch64;
        return null;
    }
};

const Options = struct {
    image_path: []const u8 = default_image_name,
    image_was_explicit: bool = false,
    architecture_request: ArchitectureRequest = .x86_64,
    architecture_was_explicit: bool = false,
    snapshot: bool = false,
    accel: Accel = .auto,
    qemu_path: ?[]const u8 = null,
    ovmf_code_path: ?[]const u8 = null,
    ovmf_vars_path: ?[]const u8 = null,
    admin_username: ?[]const u8 = null,
    ssh_public_key_path: ?[]const u8 = null,
    ssh_port: ?u16 = null,
    xorriso_path: ?[]const u8 = null,
    extra_qemu_args: []const []const u8 = &.{},
    help: bool = false,
};

const ParseFailure = struct {
    kind: Kind,
    arg: []const u8,

    const Kind = enum {
        missing_value,
        invalid_accel,
        invalid_architecture,
        invalid_username,
        invalid_ssh_port,
        provisioning_pair,
        ssh_port_without_provisioning,
        invalid_firmware_override,
        unknown_option,
        extra_image,
    };
};

const ParseResult = union(enum) {
    options: Options,
    failure: ParseFailure,
};

const ResolvedImage = struct {
    disk_path: []u8,
    code_path: []u8,
    vars_path: []u8,
    architecture: GuestArchitecture,
    release_spec: ?[]const u8,
    download_allowed: bool,

    fn deinit(self: *ResolvedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.disk_path);
        allocator.free(self.code_path);
        allocator.free(self.vars_path);
        self.* = undefined;
    }
};

const HostCapabilities = struct {
    os_tag: std.Target.Os.Tag,
    cpu_arch: std.Target.Cpu.Arch,
    kvm_available: bool = false,
};

const LaunchPlan = struct {
    qemu_path: []const u8,
    qemu_data_dir: ?[]const u8,
    architecture: qemu_host.GuestArchitecture = .x86_64,
    image_path: []const u8,
    image_format: zvmi.Format,
    ovmf_code_path: []const u8,
    ovmf_vars_path: []const u8,
    accel: Accel,
    seed_iso_path: ?[]const u8 = null,
    ssh_port: ?u16 = null,
    provisioned: bool = false,
    extra_qemu_args: []const []const u8 = &.{},
};

const ResolvedQemu = struct {
    binary_path: []u8,
    data_dir: ?[]u8,
    firmware: qemu_host.FirmwareSourcePair,

    fn deinit(self: *ResolvedQemu, allocator: std.mem.Allocator) void {
        allocator.free(self.binary_path);
        if (self.data_dir) |path| allocator.free(path);
        self.firmware.deinit(allocator);
        self.* = undefined;
    }
};

const GhrPackagePaths = struct {
    binary_path: []u8,
    data_dir: []u8,

    fn deinit(self: *GhrPackagePaths, allocator: std.mem.Allocator) void {
        allocator.free(self.binary_path);
        allocator.free(self.data_dir);
        self.* = undefined;
    }
};

const GhrMetadata = struct {
    bins: []const []const u8,
};

const PreparedVmState = struct {
    vars_path: []u8,
    temporary: bool,
    temporary_dir: ?[]u8 = null,
    overlay_path: ?[]u8 = null,

    fn deinit(self: *PreparedVmState, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.overlay_path) |overlay_path| {
            std.Io.Dir.cwd().deleteFile(io, overlay_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => std.debug.print(
                    "qemu: warning: failed to remove temporary disk overlay '{s}': {s}\n",
                    .{ overlay_path, @errorName(err) },
                ),
            };
            allocator.free(overlay_path);
        }
        if (self.temporary) {
            std.Io.Dir.cwd().deleteFile(io, self.vars_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => std.debug.print(
                    "qemu: warning: failed to remove temporary UEFI vars '{s}': {s}\n",
                    .{ self.vars_path, @errorName(err) },
                ),
            };
        }
        allocator.free(self.vars_path);
        if (self.temporary_dir) |temporary_dir| {
            std.Io.Dir.cwd().deleteTree(io, temporary_dir) catch |err| std.debug.print(
                "qemu: warning: failed to remove temporary QEMU directory '{s}': {s}\n",
                .{ temporary_dir, @errorName(err) },
            );
            allocator.free(temporary_dir);
        }
        self.* = undefined;
    }
};

const SeedState = struct {
    work_dir: []u8,
    iso_path: []u8,

    fn deinit(self: *SeedState, allocator: std.mem.Allocator, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, self.work_dir) catch |err| std.debug.print(
            "qemu: warning: failed to remove temporary provisioning directory '{s}': {s}\n",
            .{ self.work_dir, @errorName(err) },
        );
        allocator.free(self.iso_path);
        allocator.free(self.work_dir);
        self.* = undefined;
    }
};

const QemuArgv = struct {
    items: std.ArrayListUnmanaged([]const u8) = .empty,
    owned: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *QemuArgv, allocator: std.mem.Allocator) void {
        for (self.owned.items) |item| allocator.free(item);
        self.owned.deinit(allocator);
        self.items.deinit(allocator);
        self.* = undefined;
    }

    fn append(self: *QemuArgv, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.items.append(allocator, value);
    }

    fn appendFmt(
        self: *QemuArgv,
        allocator: std.mem.Allocator,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        const value = try std.fmt.allocPrint(allocator, format, args);
        self.owned.append(allocator, value) catch |err| {
            allocator.free(value);
            return err;
        };
        try self.items.append(allocator, value);
    }
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    args: []const []const u8,
) u8 {
    switch (parseArgs(args)) {
        .failure => |failure| {
            printParseFailure(failure);
            std.debug.print("\n{s}", .{help_text});
            return 1;
        },
        .options => |options| {
            if (options.help) {
                std.debug.print("{s}", .{help_text});
                return 0;
            }
            return runVm(gpa, io, environ, options);
        },
    }
}

fn runVm(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    options: Options,
) u8 {
    if (options.ssh_public_key_path) |public_key_path| {
        const public_key = readAndValidatePublicKeyAlloc(gpa, io, public_key_path) catch |err| {
            std.debug.print(
                "qemu: invalid or unreadable SSH public key '{s}': {s}\n",
                .{ public_key_path, @errorName(err) },
            );
            return 1;
        };
        gpa.free(public_key);
    }

    if (options.architecture_request == .aarch64 and !options.image_was_explicit) {
        std.debug.print(
            "qemu: --architecture aarch64 requires an explicit AArch64 image path\n",
            .{},
        );
        return 1;
    }

    var image = resolveImageAlloc(gpa, options) catch |err| {
        std.debug.print("qemu: failed to resolve image: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer image.deinit(gpa);

    ensureImage(io, image) catch |err| {
        switch (err) {
            error.ExplicitImageNotFound => std.debug.print(
                "qemu: image '{s}' does not exist; automatic download only applies to known aliases\n",
                .{image.disk_path},
            ),
            error.GhrNotFound => std.debug.print(
                "qemu: ghr was not found; install ghr or provide '{s}' directly\n",
                .{image.disk_path},
            ),
            error.DownloadFailed => std.debug.print(
                "qemu: failed to download '{s}' with ghr; the release asset may not be published yet\n",
                .{image.disk_path},
            ),
            error.DownloadMissingOutput => std.debug.print(
                "qemu: ghr reported success but '{s}' was not created\n",
                .{image.disk_path},
            ),
            else => std.debug.print(
                "qemu: failed to prepare image '{s}': {s}\n",
                .{ image.disk_path, @errorName(err) },
            ),
        }
        return 1;
    };

    const image_format = detectImageFormat(io, image.disk_path) catch |err| {
        std.debug.print(
            "qemu: failed to inspect image '{s}': {s}\n",
            .{ image.disk_path, @errorName(err) },
        );
        return 1;
    };

    const architecture = resolveArchitecture(io, options, image, image_format) catch |err| {
        if (err == error.ArchitectureMismatch) {
            std.debug.print(
                "qemu: --architecture {s} does not match the detected guest architecture in '{s}'\n",
                .{ @tagName(options.architecture_request), image.disk_path },
            );
        } else {
            std.debug.print(
                "qemu: failed to determine guest architecture for '{s}': {s}\n",
                .{ image.disk_path, @errorName(err) },
            );
        }
        return 1;
    };

    var qemu = resolveQemuAlloc(gpa, io, environ, options, architecture) catch |err| {
        printQemuResolutionError(options, architecture, err);
        return 1;
    };
    defer qemu.deinit(gpa);

    const explicit_firmware = options.ovmf_code_path != null;
    var local_firmware: ?qemu_host.FirmwarePair = null;
    defer if (local_firmware) |*firmware| firmware.deinit(gpa);

    if (explicit_firmware and !options.snapshot) {
        qemu_host.materializeFirmwareFile(
            io,
            qemu.firmware.vars,
            image.vars_path,
            .{},
        ) catch |err| {
            printFirmwarePreparationError(image.vars_path, err);
            return 1;
        };
    } else if (!explicit_firmware) {
        local_firmware = qemu_host.materializeFirmwarePairAlloc(
            gpa,
            io,
            qemu.firmware,
            image.code_path,
            image.vars_path,
            .{},
        ) catch |err| {
            printFirmwarePreparationError(image.disk_path, err);
            return 1;
        };
    }

    const host = currentHostCapabilities(io);
    const accel = resolveAccel(options.accel, host, architecture);
    var vm_state = prepareVmStateAlloc(
        gpa,
        io,
        environ,
        options.snapshot,
        image.disk_path,
        image.vars_path,
        qemu.firmware.vars,
    ) catch |err| {
        std.debug.print(
            "qemu: failed to prepare UEFI vars from '{s}': {s}\n",
            .{ qemu.firmware.vars.path, @errorName(err) },
        );
        return 1;
    };
    defer vm_state.deinit(gpa, io);

    var seed: ?SeedState = null;
    if (options.admin_username != null) {
        seed = createSeedStateAlloc(gpa, io, environ, options) catch |err| {
            std.debug.print("qemu: failed to create provisioning seed: {s}\n", .{@errorName(err)});
            return 1;
        };
    }
    defer if (seed) |*seed_state| seed_state.deinit(gpa, io);

    if (options.snapshot) {
        const temp_dir = std.fs.path.dirname(vm_state.vars_path) orelse {
            std.debug.print("qemu: temporary UEFI vars path has no parent directory\n", .{});
            return 1;
        };
        vm_state.overlay_path = createSnapshotOverlayAlloc(
            gpa,
            io,
            environ,
            qemu.binary_path,
            temp_dir,
            image.disk_path,
            image_format,
        ) catch |err| {
            std.debug.print("qemu: failed to create temporary disk overlay: {s}\n", .{@errorName(err)});
            return 1;
        };
    }

    const launch_image_path = vm_state.overlay_path orelse image.disk_path;
    const launch_image_format: zvmi.Format = if (vm_state.overlay_path != null) .qcow2 else image_format;
    var argv = buildQemuArgv(gpa, .{
        .qemu_path = qemu.binary_path,
        .qemu_data_dir = qemu.data_dir,
        .architecture = architecture,
        .image_path = launch_image_path,
        .image_format = launch_image_format,
        .ovmf_code_path = if (explicit_firmware)
            qemu.firmware.code.path
        else
            local_firmware.?.code_path,
        .ovmf_vars_path = vm_state.vars_path,
        .accel = accel,
        .seed_iso_path = if (seed) |seed_state| seed_state.iso_path else null,
        .ssh_port = options.ssh_port,
        .provisioned = seed != null,
        .extra_qemu_args = options.extra_qemu_args,
    }) catch |err| {
        std.debug.print("qemu: failed to build QEMU arguments: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer argv.deinit(gpa);

    const mode = if (options.snapshot) "snapshot" else "persistent";
    std.debug.print(
        "qemu: launching image='{s}' arch={s} format={s} qemu='{s}' accel={s} mode={s}\n",
        .{
            image.disk_path,
            @tagName(image.architecture),
            qemuFormatName(image_format),
            qemu.binary_path,
            accel.cliName(),
            mode,
        },
    );
    std.debug.print(
        "qemu: UEFI code='{s}' vars='{s}'\n",
        .{
            if (explicit_firmware) qemu.firmware.code.path else local_firmware.?.code_path,
            vm_state.vars_path,
        },
    );

    var child = std.process.spawn(io, .{
        .argv = argv.items.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print(
            "qemu: failed to launch '{s}': {s}\n",
            .{ qemu.binary_path, @errorName(err) },
        );
        return 1;
    };

    const term = child.wait(io) catch |err| {
        std.debug.print("qemu: failed while waiting for QEMU: {s}\n", .{@errorName(err)});
        return 1;
    };
    return childExitCode(term) orelse {
        std.debug.print("qemu: QEMU terminated abnormally ({s})\n", .{@tagName(term)});
        return 1;
    };
}

fn parseArgs(args: []const []const u8) ParseResult {
    var options = Options{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            options.extra_qemu_args = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--snapshot")) {
            options.snapshot = true;
        } else if (std.mem.eql(u8, arg, "--architecture")) {
            i += 1;
            if (i >= args.len) return parseFailure(.missing_value, arg);
            options.architecture_request = ArchitectureRequest.parse(args[i]) orelse
                return parseFailure(.invalid_architecture, args[i]);
            options.architecture_was_explicit = true;
        } else if (std.mem.eql(u8, arg, "--accel")) {
            i += 1;
            if (i >= args.len) return parseFailure(.missing_value, arg);
            options.accel = Accel.parse(args[i]) orelse
                return parseFailure(.invalid_accel, args[i]);
        } else if (std.mem.eql(u8, arg, "--qemu")) {
            i += 1;
            if (i >= args.len) return parseFailure(.missing_value, arg);
            options.qemu_path = args[i];
        } else if (std.mem.eql(u8, arg, "--ovmf-code")) {
            i += 1;
            if (i >= args.len) return parseFailure(.missing_value, arg);
            options.ovmf_code_path = args[i];
        } else if (std.mem.eql(u8, arg, "--ovmf-vars")) {
            i += 1;
            if (i >= args.len) return parseFailure(.missing_value, arg);
            options.ovmf_vars_path = args[i];
        } else if (std.mem.eql(u8, arg, "--firmware-code")) {
            i += 1;
            if (i >= args.len) return parseFailure(.missing_value, arg);
            options.ovmf_code_path = args[i];
        } else if (std.mem.eql(u8, arg, "--firmware-vars")) {
            i += 1;
            if (i >= args.len) return parseFailure(.missing_value, arg);
            options.ovmf_vars_path = args[i];
        } else if (std.mem.eql(u8, arg, "--admin-username")) {
            i += 1;
            if (i >= args.len) return parseFailure(.missing_value, arg);
            if (guest_validation.validateUsername(args[i])) |_| {} else |_| {
                return parseFailure(.invalid_username, args[i]);
            }
            options.admin_username = args[i];
        } else if (std.mem.eql(u8, arg, "--ssh-public-key")) {
            i += 1;
            if (i >= args.len) return parseFailure(.missing_value, arg);
            options.ssh_public_key_path = args[i];
        } else if (std.mem.eql(u8, arg, "--ssh-port")) {
            i += 1;
            if (i >= args.len) return parseFailure(.missing_value, arg);
            options.ssh_port = parseSshPort(args[i]) orelse
                return parseFailure(.invalid_ssh_port, args[i]);
        } else if (std.mem.eql(u8, arg, "--xorriso")) {
            i += 1;
            if (i >= args.len) return parseFailure(.missing_value, arg);
            options.xorriso_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return parseFailure(.unknown_option, arg);
        } else if (!options.image_was_explicit) {
            options.image_path = arg;
            options.image_was_explicit = true;
        } else {
            return parseFailure(.extra_image, arg);
        }
    }

    if ((options.admin_username == null) != (options.ssh_public_key_path == null))
        return parseFailure(.provisioning_pair, "--admin-username/--ssh-public-key");
    if (options.ssh_port != null and options.ssh_public_key_path == null)
        return parseFailure(.ssh_port_without_provisioning, "--ssh-port");
    if ((options.ovmf_code_path == null) != (options.ovmf_vars_path == null))
        return parseFailure(.invalid_firmware_override, "--firmware-code/--firmware-vars");
    if (options.ssh_public_key_path != null and options.ssh_port == null)
        options.ssh_port = default_ssh_port;

    return .{ .options = options };
}

fn parseSshPort(value: []const u8) ?u16 {
    if (value.len == 0 or value.len > 5) return null;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return null;
    const parsed = std.fmt.parseInt(u32, value, 10) catch return null;
    if (parsed == 0 or parsed > max_ssh_port) return null;
    return @intCast(parsed);
}

fn parseFailure(kind: ParseFailure.Kind, arg: []const u8) ParseResult {
    return .{ .failure = .{ .kind = kind, .arg = arg } };
}

fn printParseFailure(failure: ParseFailure) void {
    switch (failure.kind) {
        .missing_value => std.debug.print("qemu: {s} requires a value\n", .{failure.arg}),
        .invalid_accel => std.debug.print(
            "qemu: invalid accelerator '{s}' (expected auto, whpx, kvm, hvf, or tcg)\n",
            .{failure.arg},
        ),
        .invalid_architecture => std.debug.print(
            "qemu: invalid architecture '{s}' (expected auto, x86_64, or aarch64)\n",
            .{failure.arg},
        ),
        .invalid_username => std.debug.print(
            "qemu: invalid administrator username '{s}'\n",
            .{failure.arg},
        ),
        .invalid_ssh_port => std.debug.print(
            "qemu: invalid SSH port '{s}' (expected 1..65535)\n",
            .{failure.arg},
        ),
        .provisioning_pair => std.debug.print(
            "qemu: --admin-username and --ssh-public-key must be supplied together\n",
            .{},
        ),
        .ssh_port_without_provisioning => std.debug.print(
            "qemu: --ssh-port requires --admin-username and --ssh-public-key\n",
            .{},
        ),
        .invalid_firmware_override => std.debug.print(
            "qemu: firmware code and vars overrides must be supplied together\n",
            .{},
        ),
        .unknown_option => std.debug.print("qemu: unknown option '{s}'\n", .{failure.arg}),
        .extra_image => std.debug.print("qemu: unexpected image argument '{s}'\n", .{failure.arg}),
    }
}

fn resolveImageAlloc(
    allocator: std.mem.Allocator,
    options: Options,
) !ResolvedImage {
    if (!options.image_was_explicit)
        return resolvedKnownImageAlloc(allocator, known_images[0], null, true);

    const argument = options.image_path;
    const basename = std.fs.path.basename(argument);
    if (std.mem.eql(u8, basename, "AzureLinux"))
        return resolvedKnownImageAlloc(
            allocator,
            known_images[0],
            std.fs.path.dirname(argument),
            true,
        );
    for (known_images) |known| {
        if (std.mem.eql(u8, basename, known.alias))
            return resolvedKnownImageAlloc(
                allocator,
                known,
                std.fs.path.dirname(argument),
                true,
            );
    }

    for (known_images) |known| {
        if (std.mem.eql(u8, basename, known.disk_name))
            return resolvedDiskImageAlloc(
                allocator,
                argument,
                known.architecture,
                known.release_spec,
                false,
            );
    }

    return resolvedDiskImageAlloc(
        allocator,
        argument,
        .x86_64,
        null,
        false,
    );
}

fn validateImageSelection(options: Options, image_exists: bool) !void {
    if (options.architecture_request == .aarch64 and !options.image_was_explicit)
        return error.ArchitectureImageRequired;
    if (!image_exists and options.image_was_explicit)
        return error.ExplicitImageNotFound;
}

fn validateArchitectureMatch(
    requested: ArchitectureRequest,
    was_explicit: bool,
    detected: qemu_host.GuestArchitecture,
) !qemu_host.GuestArchitecture {
    return switch (requested) {
        .auto => detected,
        .x86_64 => if (was_explicit and detected != .x86_64)
            error.ArchitectureMismatch
        else
            .x86_64,
        .aarch64 => if (detected != .aarch64)
            error.ArchitectureMismatch
        else
            .aarch64,
    };
}

fn resolvedKnownImageAlloc(
    allocator: std.mem.Allocator,
    known: KnownImage,
    parent: ?[]const u8,
    download_allowed: bool,
) !ResolvedImage {
    const disk_path = if (parent) |directory|
        try std.fs.path.join(allocator, &.{ directory, known.disk_name })
    else
        try allocator.dupe(u8, known.disk_name);
    defer allocator.free(disk_path);

    return resolvedDiskImageAlloc(
        allocator,
        disk_path,
        known.architecture,
        known.release_spec,
        download_allowed,
    );
}

fn resolvedDiskImageAlloc(
    allocator: std.mem.Allocator,
    disk_path: []const u8,
    architecture: GuestArchitecture,
    release_spec: ?[]const u8,
    download_allowed: bool,
) !ResolvedImage {
    const owned_disk_path = try allocator.dupe(u8, disk_path);
    errdefer allocator.free(owned_disk_path);
    const code_path = try bundlePathAlloc(allocator, disk_path, ".code.fd");
    errdefer allocator.free(code_path);
    const vars_path = try bundlePathAlloc(allocator, disk_path, ".vars.fd");

    return .{
        .disk_path = owned_disk_path,
        .code_path = code_path,
        .vars_path = vars_path,
        .architecture = architecture,
        .release_spec = release_spec,
        .download_allowed = download_allowed,
    };
}

fn bundlePathAlloc(
    allocator: std.mem.Allocator,
    disk_path: []const u8,
    suffix: []const u8,
) ![]u8 {
    const extension = std.fs.path.extension(disk_path);
    const stem = disk_path[0 .. disk_path.len - extension.len];
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, suffix });
}

fn resolveAccel(
    requested: Accel,
    host: HostCapabilities,
    architecture: GuestArchitecture,
) Accel {
    if (requested != .auto) return requested;
    if (!hostMatchesGuest(host.cpu_arch, architecture)) return .tcg;

    return switch (host.os_tag) {
        .windows => if (architecture == .x86_64) .whpx else .tcg,
        .macos => .hvf,
        .linux => if (host.kvm_available) .kvm else .tcg,
        else => .tcg,
    };
}

fn hostMatchesGuest(host_arch: std.Target.Cpu.Arch, architecture: GuestArchitecture) bool {
    return switch (architecture) {
        .x86_64 => host_arch == .x86_64,
        .aarch64 => host_arch == .aarch64,
    };
}

fn currentHostCapabilities(io: std.Io) HostCapabilities {
    const kvm_available = if (builtin.os.tag == .linux)
        qemu_host.pathAccessible(io, "/dev/kvm", .{ .read = true, .write = true }) catch false
    else
        false;

    return .{
        .os_tag = builtin.os.tag,
        .cpu_arch = builtin.cpu.arch,
        .kvm_available = kvm_available,
    };
}

fn qemuFormatName(format: zvmi.Format) []const u8 {
    return switch (format) {
        .raw => "raw",
        .vhd => "vpc",
        .vhdx => "vhdx",
        .qcow2 => "qcow2",
    };
}

fn detectImageFormat(io: std.Io, image_path: []const u8) !zvmi.Format {
    var file = try std.Io.Dir.cwd().openFile(io, image_path, .{});
    defer file.close(io);

    const size = (try file.stat(io)).size;
    if (size >= 8) {
        var header: [8]u8 = undefined;
        const header_len = try file.readPositionalAll(io, &header, 0);
        if (header_len >= 4 and std.mem.eql(u8, header[0..4], &.{ 0x51, 0x46, 0x49, 0xfb }))
            return .qcow2;
        if (header_len == header.len and std.mem.eql(u8, &header, "vhdxfile"))
            return .vhdx;
    }

    if (size >= 512) {
        var footer_cookie: [8]u8 = undefined;
        const footer_len = try file.readPositionalAll(io, &footer_cookie, size - 512);
        if (footer_len == footer_cookie.len and std.mem.eql(u8, &footer_cookie, "conectix"))
            return .vhd;
    }

    return .raw;
}

fn resolveArchitecture(
    io: std.Io,
    options: Options,
    image: ResolvedImage,
    image_format: zvmi.Format,
) !qemu_host.GuestArchitecture {
    _ = image_format;
    if (!options.architecture_was_explicit) return image.architecture;
    const detected = try detectImageArchitecture(io, image.disk_path);
    return validateArchitectureMatch(
        options.architecture_request,
        options.architecture_was_explicit,
        detected,
    );
}

fn detectImageArchitecture(io: std.Io, image_path: []const u8) !qemu_host.GuestArchitecture {
    var image = try zvmi.Image.openPathReadOnly(io, image_path);
    defer image.close(io);

    var gpt_architecture: ?qemu_host.GuestArchitecture = null;
    if (zvmi.gpt.readGpt(image, io, std.heap.page_allocator)) |parsed| {
        defer std.heap.page_allocator.free(parsed.partitions);
        gpt_architecture = inferArchitectureFromGpt(parsed.partitions) catch |err| switch (err) {
            error.AmbiguousArchitecture => return err,
            error.ArchitectureNotFound => null,
        };
    } else |err| switch (err) {
        error.BadSignature => {},
        else => {},
    }
    const scan_len = @min(image.virtual_size, 64 * 1024 * 1024);
    if (scan_len > 0) {
        const scan_len_usize = std.math.cast(usize, scan_len) orelse return error.ArchitectureNotFound;
        const bytes = try std.heap.page_allocator.alloc(u8, scan_len_usize);
        defer std.heap.page_allocator.free(bytes);
        const read_len = try image.pread(io, bytes, 0);
        const uki_architecture = inferArchitectureFromUki(bytes[0..read_len]) catch |err| switch (err) {
            error.ArchitectureNotFound => null,
            else => return err,
        };
        if (gpt_architecture) |architecture| {
            if (uki_architecture) |uki| {
                if (architecture != uki) return error.AmbiguousArchitecture;
            }
            return architecture;
        }
        return uki_architecture orelse error.ArchitectureNotFound;
    }
    return gpt_architecture orelse error.ArchitectureNotFound;
}

pub fn inferArchitectureFromGpt(
    partitions: []const zvmi.gpt.PartitionEntry,
) !qemu_host.GuestArchitecture {
    var result: ?qemu_host.GuestArchitecture = null;
    for (partitions) |partition| {
        const architecture: ?qemu_host.GuestArchitecture =
            if (std.mem.eql(u8, &partition.partition_type_guid, &zvmi.guid.linux_root_x86_64) or
            std.mem.eql(u8, &partition.partition_type_guid, &zvmi.guid.linux_usr_x86_64))
                .x86_64
            else if (std.mem.eql(u8, &partition.partition_type_guid, &zvmi.guid.linux_root_aarch64) or
            std.mem.eql(u8, &partition.partition_type_guid, &zvmi.guid.linux_usr_aarch64))
                .aarch64
            else
                null;
        if (architecture) |candidate| {
            if (result) |existing| {
                if (existing != candidate) return error.AmbiguousArchitecture;
            } else {
                result = candidate;
            }
        }
    }
    return result orelse error.ArchitectureNotFound;
}

fn inferArchitectureFromUki(bytes: []const u8) !qemu_host.GuestArchitecture {
    var result: ?qemu_host.GuestArchitecture = null;
    var i: usize = 0;
    while (i + 0x40 <= bytes.len) : (i += 1) {
        if (!std.mem.eql(u8, bytes[i..][0..2], "MZ")) continue;
        const pe_offset = std.mem.readInt(u32, bytes[i + 0x3c ..][0..4], .little);
        const pe_index = std.math.add(usize, i, pe_offset) catch continue;
        if (pe_index + 6 > bytes.len or !std.mem.eql(u8, bytes[pe_index..][0..4], "PE\x00\x00"))
            continue;
        const machine = std.mem.readInt(u16, bytes[pe_index + 4 ..][0..2], .little);
        const candidate: ?qemu_host.GuestArchitecture = switch (machine) {
            0x8664 => .x86_64,
            0xaa64 => .aarch64,
            else => null,
        };
        if (candidate) |architecture| {
            if (result) |existing| {
                if (existing != architecture) return error.AmbiguousArchitecture;
            } else {
                result = architecture;
            }
        }
    }
    return result orelse error.ArchitectureNotFound;
}

fn persistentVarsPathAlloc(
    allocator: std.mem.Allocator,
    image_path: []const u8,
) ![]u8 {
    const extension = std.fs.path.extension(image_path);
    const stem = image_path[0 .. image_path.len - extension.len];
    return std.fmt.allocPrint(allocator, "{s}.vars.fd", .{stem});
}

fn prepareVmStateAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    snapshot: bool,
    image_path: []const u8,
    persistent_vars_path: []const u8,
    vars_source: qemu_host.FirmwareSource,
) !PreparedVmState {
    if (!snapshot)
        return preparePersistentVmStateAlloc(allocator, io, persistent_vars_path);

    const temp_dir = try createTemporaryWorkDirAlloc(allocator, io, environ, "zvmi-qemu-");
    errdefer {
        std.Io.Dir.cwd().deleteTree(io, temp_dir) catch {};
        allocator.free(temp_dir);
    }
    var state = try prepareSnapshotVmStateInDirAlloc(
        allocator,
        io,
        temp_dir,
        image_path,
        vars_source,
    );
    state.temporary_dir = temp_dir;
    return state;
}

fn preparePersistentVmStateAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    vars_path: []const u8,
) !PreparedVmState {
    try qemu_host.requireFirmwareWritable(io, vars_path);
    return .{
        .vars_path = try allocator.dupe(u8, vars_path),
        .temporary = false,
    };
}

fn prepareSnapshotVmStateInDirAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_dir: []const u8,
    image_path: []const u8,
    vars_source: qemu_host.FirmwareSource,
) !PreparedVmState {
    const image_stem = std.fs.path.stem(std.fs.path.basename(image_path));
    const vars_path = try randomTempPathAlloc(
        allocator,
        io,
        temp_dir,
        image_stem,
        ".fd",
    );
    errdefer allocator.free(vars_path);

    try qemu_host.materializeFirmwareFile(io, vars_source, vars_path, .{});
    return .{
        .vars_path = vars_path,
        .temporary = true,
    };
}

fn createSnapshotOverlayAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    qemu_path: []const u8,
    temp_dir: []const u8,
    image_path: []const u8,
    image_format: zvmi.Format,
) ![]u8 {
    const qemu_img_path = try resolveQemuImgPathAlloc(allocator, io, environ, qemu_path);
    defer allocator.free(qemu_img_path);
    const absolute_image_path = try std.Io.Dir.cwd().realPathFileAlloc(io, image_path, allocator);
    defer allocator.free(absolute_image_path);
    const overlay_path = try randomTempPathAlloc(
        allocator,
        io,
        temp_dir,
        "zvmi-qemu-overlay-",
        ".qcow2",
    );
    errdefer allocator.free(overlay_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, overlay_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.print(
            "qemu: warning: failed to remove incomplete disk overlay '{s}': {s}\n",
            .{ overlay_path, @errorName(err) },
        ),
    };

    const argv = qemuImgCreateArgv(
        qemu_img_path,
        qemuFormatName(image_format),
        absolute_image_path,
        overlay_path,
    );
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    const exit_code = childExitCode(term) orelse return error.QemuImgFailed;
    if (exit_code != 0) return error.QemuImgFailed;
    if (!try qemu_host.pathAccessible(io, overlay_path, .{ .read = true, .write = true }))
        return error.OverlayMissing;
    return overlay_path;
}

fn resolveQemuImgPathAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    qemu_path: []const u8,
) ![]u8 {
    if (std.fs.path.dirname(qemu_path)) |qemu_dir| {
        const sibling = try std.fs.path.join(
            allocator,
            &.{ qemu_dir, qemu_host.executableName("qemu-img") },
        );
        const accessible = qemu_host.pathAccessible(io, sibling, .{ .execute = true }) catch |err| {
            allocator.free(sibling);
            return err;
        };
        if (accessible) return sibling;
        allocator.free(sibling);
    }

    return (try qemu_host.findExecutableInPathAlloc(allocator, io, environ, "qemu-img")) orelse
        return error.QemuImgNotFound;
}

fn qemuImgCreateArgv(
    qemu_img_path: []const u8,
    backing_format: []const u8,
    backing_path: []const u8,
    overlay_path: []const u8,
) [9][]const u8 {
    return [9][]const u8{
        qemu_img_path,
        "create",
        "-f",
        "qcow2",
        "-b",
        backing_path,
        "-F",
        backing_format,
        overlay_path,
    };
}

fn randomTempPathAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_dir: []const u8,
    prefix: []const u8,
    suffix: []const u8,
) ![]u8 {
    var random: [16]u8 = undefined;
    std.Io.random(io, &random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const filename = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, &hex, suffix });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ temp_dir, filename });
}

fn createTemporaryWorkDirAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    prefix: []const u8,
) ![]u8 {
    const base_dir = try temporaryDirectoryAlloc(allocator, io, environ);
    defer allocator.free(base_dir);
    const work_dir = try randomTempPathAlloc(allocator, io, base_dir, prefix, "");
    errdefer {
        std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
        allocator.free(work_dir);
    }
    try std.Io.Dir.cwd().createDir(io, work_dir, .default_dir);
    try setPrivateDirectoryPermissions(io, work_dir);
    return work_dir;
}

fn setPrivateDirectoryPermissions(io: std.Io, path: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => {},
        else => try setDirectoryPermissions(io, path, .fromMode(0o700)),
    }
}

fn setDirectoryPermissions(
    io: std.Io,
    path: []const u8,
    permissions: std.Io.File.Permissions,
) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer directory.close(io);
    try directory.setPermissions(io, permissions);
}

fn temporaryDirectoryAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) ![]u8 {
    const keys: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "TEMP", "TMP" },
        else => &.{"TMPDIR"},
    };
    for (keys) |key| {
        const path = environ.getAlloc(allocator, key) catch |err| switch (err) {
            error.EnvironmentVariableMissing => continue,
            else => return err,
        };
        if (path.len > 0) return path;
        allocator.free(path);
    }

    return std.process.currentPathAlloc(io, allocator);
}

fn childExitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

fn resolveQemuAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    options: Options,
    architecture: qemu_host.GuestArchitecture,
) !ResolvedQemu {
    if (options.qemu_path) |explicit_qemu| {
        if (!try qemu_host.pathAccessible(io, explicit_qemu, .{ .execute = true }))
            return error.ExplicitQemuNotExecutable;

        const binary_path = try allocator.dupe(u8, explicit_qemu);
        errdefer allocator.free(binary_path);
        const firmware = (try qemu_host.findFirmwareSourcePairAlloc(allocator, io, .{
            .architecture = architecture,
            .explicit_code_path = options.ovmf_code_path,
            .explicit_vars_path = options.ovmf_vars_path,
            .qemu_path = binary_path,
        })) orelse return error.FirmwareNotFound;

        return .{
            .binary_path = binary_path,
            .data_dir = null,
            .firmware = firmware,
        };
    }

    if (try findGhrQemuAlloc(allocator, io, options, architecture)) |resolved| return resolved;

    return (try findSystemQemuAlloc(allocator, io, environ, options, architecture)) orelse
        return error.QemuNotFound;
}

fn findSystemQemuAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    options: Options,
    architecture: qemu_host.GuestArchitecture,
) !?ResolvedQemu {
    const path_value = environ.getAlloc(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => return err,
    };
    defer allocator.free(path_value);
    return findSystemQemuInPathValueAlloc(allocator, io, path_value, options, architecture);
}

fn findSystemQemuInPathValueAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path_value: []const u8,
    options: Options,
    architecture: qemu_host.GuestArchitecture,
) !?ResolvedQemu {
    const system_qemu = try qemu_host.findExecutableInPathValueAlloc(
        allocator,
        io,
        path_value,
        qemu_host.qemuSystemName(architecture),
    ) orelse return null;
    errdefer allocator.free(system_qemu);

    const firmware = (try qemu_host.findFirmwareSourcePairAlloc(allocator, io, .{
        .architecture = architecture,
        .explicit_code_path = options.ovmf_code_path,
        .explicit_vars_path = options.ovmf_vars_path,
        .qemu_path = system_qemu,
    })) orelse return error.FirmwareNotFound;

    return .{
        .binary_path = system_qemu,
        .data_dir = null,
        .firmware = firmware,
    };
}

fn findGhrQemuAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    architecture: qemu_host.GuestArchitecture,
) !?ResolvedQemu {
    const tools_path = try ghrToolsPathAlloc(allocator, io) orelse return null;
    defer allocator.free(tools_path);
    return findGhrQemuAtToolsPathAlloc(allocator, io, tools_path, options, architecture);
}

fn findGhrQemuAtToolsPathAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    tools_path: []const u8,
    options: Options,
    architecture: qemu_host.GuestArchitecture,
) !?ResolvedQemu {
    const tool_dir = try std.fs.path.join(allocator, &.{ tools_path, "cataggar", "qemu" });
    defer allocator.free(tool_dir);
    const metadata_path = try std.fs.path.join(allocator, &.{ tool_dir, "ghr.json" });
    defer allocator.free(metadata_path);

    const metadata_bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        metadata_path,
        allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(metadata_bytes);

    var package_paths = parseGhrPackagePathsForArchitectureAlloc(allocator, tool_dir, metadata_bytes, architecture) catch |err| switch (err) {
        error.InvalidGhrMetadata, error.QemuBinaryMissingFromGhrMetadata => return null,
        else => return err,
    };
    const binary_accessible = qemu_host.pathAccessible(
        io,
        package_paths.binary_path,
        .{ .execute = true },
    ) catch |err| {
        package_paths.deinit(allocator);
        return err;
    };
    if (!binary_accessible) {
        package_paths.deinit(allocator);
        return null;
    }

    const firmware_optional = qemu_host.findFirmwareSourcePairAlloc(allocator, io, .{
        .architecture = architecture,
        .explicit_code_path = options.ovmf_code_path,
        .explicit_vars_path = options.ovmf_vars_path,
        .qemu_path = package_paths.binary_path,
        .data_dirs = &.{package_paths.data_dir},
    }) catch |err| {
        package_paths.deinit(allocator);
        return err;
    };
    const firmware = firmware_optional orelse {
        package_paths.deinit(allocator);
        return null;
    };

    return .{
        .binary_path = package_paths.binary_path,
        .data_dir = package_paths.data_dir,
        .firmware = firmware,
    };
}

fn ghrToolsPathAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
) !?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "ghr", "path", "tools" },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return @as(?[]u8, try allocator.dupe(u8, trimmed));
}

fn parseGhrPackagePathsAlloc(
    allocator: std.mem.Allocator,
    tool_dir: []const u8,
    metadata_bytes: []const u8,
    architecture: GuestArchitecture,
) !GhrPackagePaths {
    return parseGhrPackagePathsForArchitectureAlloc(
        allocator,
        tool_dir,
        metadata_bytes,
        architecture,
    );
}

fn parseGhrPackagePathsForArchitectureAlloc(
    allocator: std.mem.Allocator,
    tool_dir: []const u8,
    metadata_bytes: []const u8,
    architecture: qemu_host.GuestArchitecture,
) !GhrPackagePaths {
    const parsed = std.json.parseFromSlice(GhrMetadata, allocator, metadata_bytes, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidGhrMetadata;
    defer parsed.deinit();

    const relative_binary = for (parsed.value.bins) |bin_path| {
        if (isQemuSystemName(portableBasename(bin_path), architecture)) break bin_path;
    } else return error.QemuBinaryMissingFromGhrMetadata;

    const native_relative_binary = try allocator.dupe(u8, relative_binary);
    defer allocator.free(native_relative_binary);
    for (native_relative_binary) |*byte| {
        if (byte.* == '/' or byte.* == '\\') byte.* = std.fs.path.sep;
    }
    const binary_path = try std.fs.path.join(allocator, &.{ tool_dir, native_relative_binary });
    errdefer allocator.free(binary_path);
    const package_root = std.fs.path.dirname(binary_path) orelse
        return error.InvalidGhrMetadata;
    const data_dir = try std.fs.path.join(allocator, &.{ package_root, "share" });

    return .{
        .binary_path = binary_path,
        .data_dir = data_dir,
    };
}

fn portableBasename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    const separator = if (slash) |slash_index|
        if (backslash) |backslash_index| @max(slash_index, backslash_index) else slash_index
    else
        backslash orelse return path;
    return path[separator + 1 ..];
}

fn isQemuSystemName(name: []const u8, architecture: GuestArchitecture) bool {
    const expected = qemu_host.qemuSystemName(architecture);
    if (std.ascii.eqlIgnoreCase(name, expected)) return true;
    if (!std.ascii.endsWithIgnoreCase(name, ".exe")) return false;
    return std.ascii.eqlIgnoreCase(name[0 .. name.len - ".exe".len], expected);
}

fn ensureImage(
    io: std.Io,
    image: ResolvedImage,
) !void {
    if (try qemu_host.pathAccessible(io, image.disk_path, .{ .read = true })) return;
    if (!image.download_allowed) return error.ExplicitImageNotFound;

    if (std.fs.path.dirname(image.disk_path)) |parent|
        try std.Io.Dir.cwd().createDirPath(io, parent);

    const argv = ghrDownloadArgv(image);
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.GhrNotFound,
        else => return err,
    };
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.DownloadFailed,
        else => return error.DownloadFailed,
    }

    if (!try qemu_host.pathAccessible(io, image.disk_path, .{ .read = true }))
        return error.DownloadMissingOutput;
}

fn ghrDownloadArgv(image: ResolvedImage) [5][]const u8 {
    return [5][]const u8{
        "ghr",
        "download",
        image.release_spec.?,
        "--output",
        image.disk_path,
    };
}

fn readAndValidatePublicKeyAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(guest_validation.max_public_key_len + 2),
    );
    defer allocator.free(contents);
    var end = contents.len;
    while (end > 0 and (contents[end - 1] == '\n' or contents[end - 1] == '\r')) : (end -= 1) {}
    const key = try allocator.dupe(u8, contents[0..end]);
    errdefer allocator.free(key);
    try guest_validation.validatePublicKey(key);
    return key;
}

fn appendXmlEscaped(
    output: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
) !void {
    for (value) |byte| {
        const escaped: []const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => "",
        };
        if (escaped.len == 0) {
            try output.append(allocator, byte);
        } else {
            try output.appendSlice(allocator, escaped);
        }
    }
}

fn appendYamlSingleQuoted(
    output: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
) !void {
    try output.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') try output.append(allocator, '\'');
        try output.append(allocator, byte);
    }
    try output.append(allocator, '\'');
}

fn buildOvfEnvAlloc(
    allocator: std.mem.Allocator,
    username: []const u8,
    public_key: []const u8,
) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<Environment xmlns="http://schemas.dmtf.org/ovf/environment/1" xmlns:wa="http://schemas.microsoft.com/windowsazure">
        \\  <wa:ProvisioningSection>
        \\    <LinuxProvisioningConfigurationSet xmlns="http://schemas.microsoft.com/windowsazure">
        \\      <ConfigurationSetType>LinuxProvisioningConfiguration</ConfigurationSetType>
        \\      <HostName>zvmi-local</HostName>
        \\      <UserName>
    );
    try appendXmlEscaped(&output, allocator, username);
    try output.appendSlice(allocator,
        \\</UserName>
        \\      <DisableSshPasswordAuthentication>true</DisableSshPasswordAuthentication>
        \\      <SSH><PublicKeys><PublicKey><Value>
    );
    try appendXmlEscaped(&output, allocator, public_key);
    try output.appendSlice(allocator,
        \\</Value></PublicKey></PublicKeys></SSH>
        \\    </LinuxProvisioningConfigurationSet>
        \\  </wa:ProvisioningSection>
        \\</Environment>
        \\
    );
    return output.toOwnedSlice(allocator);
}

fn buildNoCloudMetaDataAlloc(allocator: std.mem.Allocator, instance_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "instance-id: {s}\nlocal-hostname: zvmi-local\n",
        .{instance_id},
    );
}

fn buildNoCloudUserDataAlloc(
    allocator: std.mem.Allocator,
    username: []const u8,
    public_key: []const u8,
) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator,
        \\#cloud-config
        \\users:
        \\  - default
        \\  - name:
    );
    try output.append(allocator, ' ');
    try appendYamlSingleQuoted(&output, allocator, username);
    try output.appendSlice(allocator,
        \\
        \\    ssh_authorized_keys:
        \\      -
    );
    try output.append(allocator, ' ');
    try appendYamlSingleQuoted(&output, allocator, public_key);
    try output.appendSlice(allocator,
        \\
        \\    sudo:
        \\      - "ALL=(ALL) NOPASSWD:ALL"
        \\ssh_pwauth: false
        \\disable_root: true
        \\
    );
    return output.toOwnedSlice(allocator);
}

fn resolveXorrisoAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    explicit_path: ?[]const u8,
) ![]u8 {
    if (explicit_path) |path| {
        if (!try qemu_host.pathAccessible(io, path, .{ .execute = true }))
            return error.ExplicitXorrisoNotExecutable;
        return allocator.dupe(u8, path);
    }
    return (try qemu_host.findExecutableInPathAlloc(allocator, io, environ, "xorriso")) orelse
        return error.XorrisoNotFound;
}

fn createSeedStateAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    options: Options,
) !SeedState {
    const username = options.admin_username orelse return error.MissingProvisioningUsername;
    const key_path = options.ssh_public_key_path orelse return error.MissingProvisioningKey;
    const public_key = try readAndValidatePublicKeyAlloc(allocator, io, key_path);
    defer allocator.free(public_key);
    const xorriso_path = try resolveXorrisoAlloc(allocator, io, environ, options.xorriso_path);
    defer allocator.free(xorriso_path);

    const work_dir = try createTemporaryWorkDirAlloc(allocator, io, environ, "zvmi-qemu-seed-");
    errdefer {
        std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
        allocator.free(work_dir);
    }
    const seed_dir = try std.fs.path.join(allocator, &.{ work_dir, "seed" });
    defer allocator.free(seed_dir);
    try std.Io.Dir.cwd().createDir(io, seed_dir, .default_dir);
    try setPrivateDirectoryPermissions(io, seed_dir);

    const meta_path = try std.fs.path.join(allocator, &.{ seed_dir, "meta-data" });
    defer allocator.free(meta_path);
    const user_path = try std.fs.path.join(allocator, &.{ seed_dir, "user-data" });
    defer allocator.free(user_path);
    const ovf_path = try std.fs.path.join(allocator, &.{ seed_dir, "ovf-env.xml" });
    defer allocator.free(ovf_path);
    const marker_path = try std.fs.path.join(allocator, &.{ seed_dir, local_provisioning_marker });
    defer allocator.free(marker_path);
    const iso_path = try std.fs.path.join(allocator, &.{ work_dir, "seed.iso" });
    errdefer allocator.free(iso_path);

    const instance_id = std.fs.path.basename(work_dir);
    const meta_data = try buildNoCloudMetaDataAlloc(allocator, instance_id);
    defer allocator.free(meta_data);
    const user_data = try buildNoCloudUserDataAlloc(allocator, username, public_key);
    defer allocator.free(user_data);
    const ovf_env = try buildOvfEnvAlloc(allocator, username, public_key);
    defer allocator.free(ovf_env);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = meta_path, .data = meta_data });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = user_path, .data = user_data });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ovf_path, .data = ovf_env });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker_path, .data = "" });

    const xorriso_argv = [_][]const u8{
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
        iso_path,
        seed_dir,
    };
    var child = try std.process.spawn(io, .{
        .argv = &xorriso_argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    const exit_code = childExitCode(term) orelse return error.XorrisoFailed;
    if (exit_code != 0) return error.XorrisoFailed;
    if (!try qemu_host.pathAccessible(io, iso_path, .{ .read = true }))
        return error.SeedIsoMissing;

    return .{ .work_dir = work_dir, .iso_path = iso_path };
}

fn printQemuResolutionError(
    options: Options,
    architecture: qemu_host.GuestArchitecture,
    err: anyerror,
) void {
    const qemu_name = qemu_host.qemuSystemName(architecture);
    switch (err) {
        error.ExplicitQemuNotExecutable => std.debug.print(
            "qemu: configured QEMU executable is not accessible: '{s}'\n",
            .{options.qemu_path.?},
        ),
        error.IncompleteFirmwareOverride => std.debug.print(
            "qemu: --ovmf-code and --ovmf-vars must be provided together\n",
            .{},
        ),
        error.FirmwareNotReadable => std.debug.print(
            "qemu: configured UEFI firmware is not readable\n",
            .{},
        ),
        error.FirmwareNotFound => std.debug.print(
            "qemu: {s} firmware was not found; use --firmware-code and --firmware-vars\n",
            .{if (architecture == .x86_64) "OVMF" else "AAVMF"},
        ),
        error.QemuImgNotFound => std.debug.print(
            "qemu: qemu-img was not found; install the QEMU utilities\n",
            .{},
        ),
        error.QemuNotFound => std.debug.print(
            "qemu: {s} was not found\ninstall it with: ghr install cataggar/qemu\n",
            .{qemu_name},
        ),
        error.InvalidGhrMetadata, error.QemuBinaryMissingFromGhrMetadata => std.debug.print(
            "qemu: the cataggar/qemu ghr installation metadata is invalid: {s}\n",
            .{@errorName(err)},
        ),
        else => std.debug.print("qemu: failed to resolve QEMU: {s}\n", .{@errorName(err)}),
    }
}

fn printFirmwarePreparationError(path: []const u8, err: anyerror) void {
    switch (err) {
        error.FirmwareDestinationNotRegularFile,
        error.FirmwareDestinationEmpty,
        error.FirmwareDestinationNotReadable,
        error.FirmwareDestinationNotWritable,
        => std.debug.print(
            "qemu: existing firmware bundle file near '{s}' is invalid ({s}); move or delete it before retrying\n",
            .{ path, @errorName(err) },
        ),
        else => std.debug.print(
            "qemu: failed to prepare firmware bundle near '{s}': {s}\n",
            .{ path, @errorName(err) },
        ),
    }
}

fn qemuCpuName(
    architecture: qemu_host.GuestArchitecture,
    accel: Accel,
) []const u8 {
    if (architecture == .x86_64) return "Nehalem-v1";
    return switch (accel) {
        .kvm, .hvf, .whpx => "host",
        .tcg => "max",
        .auto => unreachable,
    };
}

fn buildQemuArgv(
    allocator: std.mem.Allocator,
    plan: LaunchPlan,
) !QemuArgv {
    std.debug.assert(plan.accel != .auto);

    var result = QemuArgv{};
    errdefer result.deinit(allocator);

    try result.append(allocator, plan.qemu_path);
    if (plan.qemu_data_dir) |data_dir| {
        try result.append(allocator, "-L");
        try result.append(allocator, data_dir);
    }
    try result.append(allocator, "-M");
    try result.appendFmt(allocator, "{s},accel={s}", .{
        if (plan.architecture == .x86_64) "q35" else "virt",
        plan.accel.cliName(),
    });
    try result.append(allocator, "-cpu");
    try result.append(allocator, qemuCpuName(plan.architecture, plan.accel));
    try result.append(allocator, "-m");
    try result.append(allocator, "2G");
    try result.append(allocator, "-smp");
    try result.append(allocator, "2");
    try result.append(allocator, "-drive");
    try result.appendFmt(
        allocator,
        "if=pflash,unit=0,format=raw,readonly=on,file={s}",
        .{plan.ovmf_code_path},
    );
    try result.append(allocator, "-drive");
    try result.appendFmt(
        allocator,
        "if=pflash,unit=1,format=raw,file={s}",
        .{plan.ovmf_vars_path},
    );
    try result.append(allocator, "-drive");
    try result.appendFmt(
        allocator,
        "file={s},format={s},if=virtio",
        .{ plan.image_path, qemuFormatName(plan.image_format) },
    );
    if (plan.seed_iso_path) |seed_iso_path| {
        try result.append(allocator, "-device");
        try result.append(allocator, "virtio-scsi-pci,id=scsi0");
        try result.append(allocator, "-drive");
        try result.appendFmt(
            allocator,
            "file={s},if=none,id=seed,media=cdrom,readonly=on,format=raw",
            .{seed_iso_path},
        );
        try result.append(allocator, "-device");
        try result.append(allocator, "scsi-cd,drive=seed,bus=scsi0.0");
    }
    try result.append(allocator, "-nic");
    if (plan.ssh_port) |ssh_port| {
        try result.appendFmt(
            allocator,
            "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:{d}-:22",
            .{ssh_port},
        );
    } else {
        try result.append(allocator, "user,model=virtio-net-pci");
    }
    if (!plan.provisioned) try result.append(allocator, "-no-reboot");
    try result.append(allocator, "-nographic");
    try result.items.appendSlice(allocator, plan.extra_qemu_args);

    return result;
}

fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

fn expectAarch64CpuArgv(accel: Accel, expected_cpu: []const u8) !void {
    const allocator = std.testing.allocator;
    var argv = try buildQemuArgv(allocator, .{
        .qemu_path = "qemu-system-aarch64",
        .qemu_data_dir = null,
        .architecture = .aarch64,
        .image_path = "disk.qcow2",
        .image_format = .qcow2,
        .ovmf_code_path = "AAVMF_CODE.fd",
        .ovmf_vars_path = "vars.fd",
        .accel = accel,
    });
    defer argv.deinit(allocator);

    var cpu_index: ?usize = null;
    for (argv.items.items, 0..) |item, index| {
        if (std.mem.eql(u8, item, "-cpu")) {
            cpu_index = index;
            break;
        }
    }
    try std.testing.expect(cpu_index != null);
    try std.testing.expectEqualStrings(expected_cpu, argv.items.items[cpu_index.? + 1]);
}

test "qemu parser defaults to the release image" {
    const parsed = parseArgs(&.{});
    try std.testing.expectEqualStrings(default_image_name, parsed.options.image_path);
    try std.testing.expect(!parsed.options.image_was_explicit);
}

test "qemu parser accepts every option and passthrough arguments" {
    const parsed = parseArgs(&.{
        "custom.qcow2",
        "--snapshot",
        "--accel",
        "tcg",
        "--qemu",
        "qemu-custom",
        "--ovmf-code",
        "code.fd",
        "--ovmf-vars",
        "vars.fd",
        "--",
        "-d",
        "guest_errors",
    });
    const options = parsed.options;

    try std.testing.expectEqualStrings("custom.qcow2", options.image_path);
    try std.testing.expect(options.image_was_explicit);
    try std.testing.expect(options.snapshot);
    try std.testing.expectEqual(Accel.tcg, options.accel);
    try std.testing.expectEqualStrings("qemu-custom", options.qemu_path.?);
    try std.testing.expectEqualStrings("code.fd", options.ovmf_code_path.?);
    try std.testing.expectEqualStrings("vars.fd", options.ovmf_vars_path.?);
    try expectArgv(&.{ "-d", "guest_errors" }, options.extra_qemu_args);
}

test "qemu parser accepts architecture and defaults the provisioning port" {
    const parsed = parseArgs(&.{
        "--architecture",
        "aarch64",
        "--admin-username",
        "azure_user",
        "--ssh-public-key",
        "id.pub",
    });
    const options = parsed.options;
    try std.testing.expectEqual(ArchitectureRequest.aarch64, options.architecture_request);
    try std.testing.expect(options.architecture_was_explicit);
    try std.testing.expectEqual(@as(?u16, 2222), options.ssh_port);
}

test "qemu parser validates provisioning cross-options and ports" {
    try std.testing.expectEqual(
        ParseFailure.Kind.provisioning_pair,
        parseArgs(&.{ "--admin-username", "azureuser" }).failure.kind,
    );
    try std.testing.expectEqual(
        ParseFailure.Kind.provisioning_pair,
        parseArgs(&.{ "--ssh-public-key", "id.pub" }).failure.kind,
    );
    try std.testing.expectEqual(
        ParseFailure.Kind.ssh_port_without_provisioning,
        parseArgs(&.{ "--ssh-port", "2222" }).failure.kind,
    );
    try std.testing.expectEqual(
        ParseFailure.Kind.invalid_ssh_port,
        parseArgs(&.{ "--ssh-port", "65536", "--admin-username", "u", "--ssh-public-key", "k" }).failure.kind,
    );
    try std.testing.expectEqual(
        ParseFailure.Kind.invalid_username,
        parseArgs(&.{ "--admin-username", "Root", "--ssh-public-key", "k" }).failure.kind,
    );
}

test "qemu parser validates options before passthrough arguments" {
    const parsed = parseArgs(&.{ "--ssh-port", "2222", "--", "-d", "guest_errors" });
    try std.testing.expectEqual(ParseFailure.Kind.ssh_port_without_provisioning, parsed.failure.kind);
}

test "qemu parser recognizes help" {
    const parsed = parseArgs(&.{"--help"});
    try std.testing.expect(parsed.options.help);
}

test "qemu parser reports missing values" {
    const flags = [_][]const u8{ "--accel", "--qemu", "--ovmf-code", "--ovmf-vars" };
    for (flags) |flag| {
        const parsed = parseArgs(&.{flag});
        try std.testing.expectEqual(ParseFailure.Kind.missing_value, parsed.failure.kind);
        try std.testing.expectEqualStrings(flag, parsed.failure.arg);
    }
}

test "qemu parser rejects invalid accelerators" {
    const parsed = parseArgs(&.{ "--accel", "fast" });
    try std.testing.expectEqual(ParseFailure.Kind.invalid_accel, parsed.failure.kind);
    try std.testing.expectEqualStrings("fast", parsed.failure.arg);
}

test "qemu parser rejects unknown options and extra images" {
    const unknown = parseArgs(&.{"--unknown"});
    try std.testing.expectEqual(ParseFailure.Kind.unknown_option, unknown.failure.kind);

    const extra = parseArgs(&.{ "one.qcow2", "two.qcow2" });
    try std.testing.expectEqual(ParseFailure.Kind.extra_image, extra.failure.kind);
    try std.testing.expectEqualStrings("two.qcow2", extra.failure.arg);
}

test "qemu resolves known aliases and explicit image paths" {
    const allocator = std.testing.allocator;

    var implicit = try resolveImageAlloc(allocator, .{});
    defer implicit.deinit(allocator);
    try std.testing.expectEqualStrings(default_image_name, implicit.disk_path);
    try std.testing.expect(implicit.download_allowed);

    var short_alias = try resolveImageAlloc(allocator, .{
        .image_path = "AzureLinux",
        .image_was_explicit = true,
    });
    defer short_alias.deinit(allocator);
    try std.testing.expectEqualStrings("AzureLinux-4.0-x86_64.qcow2", short_alias.disk_path);
    try std.testing.expectEqualStrings("AzureLinux-4.0-x86_64.code.fd", short_alias.code_path);
    try std.testing.expectEqualStrings("AzureLinux-4.0-x86_64.vars.fd", short_alias.vars_path);
    try std.testing.expectEqual(GuestArchitecture.x86_64, short_alias.architecture);
    try std.testing.expect(short_alias.download_allowed);

    var prefixed = try resolveImageAlloc(allocator, .{
        .image_path = "images/AzureLinux-4.0-aarch64",
        .image_was_explicit = true,
    });
    defer prefixed.deinit(allocator);
    try std.testing.expectEqualStrings("images/AzureLinux-4.0-aarch64.qcow2", prefixed.disk_path);
    try std.testing.expectEqualStrings("images/AzureLinux-4.0-aarch64.code.fd", prefixed.code_path);
    try std.testing.expectEqualStrings("images/AzureLinux-4.0-aarch64.vars.fd", prefixed.vars_path);
    try std.testing.expectEqual(GuestArchitecture.aarch64, prefixed.architecture);
    try std.testing.expect(prefixed.download_allowed);

    var explicit_known = try resolveImageAlloc(allocator, .{
        .image_path = "./AzureLinux-4.0-aarch64.qcow2",
        .image_was_explicit = true,
    });
    defer explicit_known.deinit(allocator);
    try std.testing.expectEqual(GuestArchitecture.aarch64, explicit_known.architecture);
    try std.testing.expect(!explicit_known.download_allowed);

    var custom = try resolveImageAlloc(allocator, .{
        .image_path = "custom.vhdx",
        .image_was_explicit = true,
    });
    defer custom.deinit(allocator);
    try std.testing.expectEqualStrings("custom.vhdx", custom.disk_path);
    try std.testing.expectEqualStrings("custom.code.fd", custom.code_path);
    try std.testing.expectEqualStrings("custom.vars.fd", custom.vars_path);
    try std.testing.expectEqual(GuestArchitecture.x86_64, custom.architecture);
    try std.testing.expect(custom.release_spec == null);
    try std.testing.expect(!custom.download_allowed);
}

test "qemu image selection keeps the implicit x86 default downloadable" {
    const implicit = parseArgs(&.{}).options;
    try validateImageSelection(implicit, true);
    try validateImageSelection(implicit, false);

    const aarch64 = parseArgs(&.{ "--architecture", "aarch64", "arm.qcow2" }).options;
    try validateImageSelection(aarch64, true);
    try std.testing.expectError(error.ExplicitImageNotFound, validateImageSelection(aarch64, false));

    const aarch64_without_image = parseArgs(&.{ "--architecture", "aarch64" }).options;
    try std.testing.expectError(
        error.ArchitectureImageRequired,
        validateImageSelection(aarch64_without_image, true),
    );
    try std.testing.expectError(
        error.ArchitectureImageRequired,
        validateImageSelection(aarch64_without_image, false),
    );
}

test "qemu explicit architectures must match detected image architecture" {
    try std.testing.expectEqual(
        qemu_host.GuestArchitecture.x86_64,
        try validateArchitectureMatch(.x86_64, true, .x86_64),
    );
    try std.testing.expectEqual(
        qemu_host.GuestArchitecture.aarch64,
        try validateArchitectureMatch(.aarch64, true, .aarch64),
    );
    try std.testing.expectError(
        error.ArchitectureMismatch,
        validateArchitectureMatch(.x86_64, true, .aarch64),
    );
    try std.testing.expectError(
        error.ArchitectureMismatch,
        validateArchitectureMatch(.aarch64, true, .x86_64),
    );
    try std.testing.expectEqual(
        qemu_host.GuestArchitecture.x86_64,
        try validateArchitectureMatch(.x86_64, false, .aarch64),
    );
}

test "qemu auto accelerator follows host capabilities" {
    try std.testing.expectEqual(Accel.whpx, resolveAccel(.auto, .{
        .os_tag = .windows,
        .cpu_arch = .x86_64,
    }, .x86_64));
    try std.testing.expectEqual(Accel.hvf, resolveAccel(.auto, .{
        .os_tag = .macos,
        .cpu_arch = .x86_64,
    }, .x86_64));
    try std.testing.expectEqual(Accel.kvm, resolveAccel(.auto, .{
        .os_tag = .linux,
        .cpu_arch = .x86_64,
        .kvm_available = true,
    }, .x86_64));
    try std.testing.expectEqual(Accel.tcg, resolveAccel(.auto, .{
        .os_tag = .linux,
        .cpu_arch = .x86_64,
    }, .x86_64));
    try std.testing.expectEqual(Accel.tcg, resolveAccel(.auto, .{
        .os_tag = .macos,
        .cpu_arch = .aarch64,
    }, .x86_64));
    try std.testing.expectEqual(Accel.hvf, resolveAccel(.auto, .{
        .os_tag = .macos,
        .cpu_arch = .aarch64,
    }, .aarch64));
    try std.testing.expectEqual(Accel.kvm, resolveAccel(.auto, .{
        .os_tag = .linux,
        .cpu_arch = .aarch64,
        .kvm_available = true,
    }, .aarch64));
    try std.testing.expectEqual(Accel.tcg, resolveAccel(.auto, .{
        .os_tag = .windows,
        .cpu_arch = .aarch64,
    }, .aarch64));
    try std.testing.expectEqual(Accel.hvf, resolveAccel(.hvf, .{
        .os_tag = .windows,
        .cpu_arch = .aarch64,
    }, .aarch64));
}

test "qemu architecture inference uses only recognized GPT root or usr GUIDs" {
    const x86 = [_]zvmi.gpt.PartitionEntry{.{
        .partition_type_guid = zvmi.guid.linux_root_x86_64,
    }};
    const arm = [_]zvmi.gpt.PartitionEntry{.{
        .partition_type_guid = zvmi.guid.linux_usr_aarch64,
    }};
    const ambiguous = [_]zvmi.gpt.PartitionEntry{
        .{ .partition_type_guid = zvmi.guid.linux_root_x86_64 },
        .{ .partition_type_guid = zvmi.guid.linux_root_aarch64 },
    };
    try std.testing.expectEqual(qemu_host.GuestArchitecture.x86_64, try inferArchitectureFromGpt(&x86));
    try std.testing.expectEqual(qemu_host.GuestArchitecture.aarch64, try inferArchitectureFromGpt(&arm));
    try std.testing.expectError(error.ArchitectureNotFound, inferArchitectureFromGpt(&.{}));
    try std.testing.expectError(error.AmbiguousArchitecture, inferArchitectureFromGpt(&ambiguous));
}

test "qemu architecture inference reads PE machine metadata" {
    var bytes = [_]u8{0} ** 128;
    bytes[0..2].* = "MZ".*;
    std.mem.writeInt(u32, bytes[0x3c..][0..4], 64, .little);
    bytes[64..68].* = "PE\x00\x00".*;
    std.mem.writeInt(u16, bytes[68..70], 0xaa64, .little);
    try std.testing.expectEqual(qemu_host.GuestArchitecture.aarch64, try inferArchitectureFromUki(&bytes));
}

test "qemu format names match QEMU block drivers" {
    try std.testing.expectEqualStrings("raw", qemuFormatName(.raw));
    try std.testing.expectEqualStrings("vpc", qemuFormatName(.vhd));
    try std.testing.expectEqualStrings("vhdx", qemuFormatName(.vhdx));
    try std.testing.expectEqualStrings("qcow2", qemuFormatName(.qcow2));
}

test "qemu detects supported image signatures without fully opening the image" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "disk.qcow2",
        .data = &.{ 0x51, 0x46, 0x49, 0xfb, 0, 0, 0, 3 },
    });
    const qcow2_path = try tmp.dir.realPathFileAlloc(io, "disk.qcow2", allocator);
    defer allocator.free(qcow2_path);
    try std.testing.expectEqual(zvmi.Format.qcow2, try detectImageFormat(io, qcow2_path));

    try tmp.dir.writeFile(io, .{
        .sub_path = "disk.vhdx",
        .data = "vhdxfile",
    });
    const vhdx_path = try tmp.dir.realPathFileAlloc(io, "disk.vhdx", allocator);
    defer allocator.free(vhdx_path);
    try std.testing.expectEqual(zvmi.Format.vhdx, try detectImageFormat(io, vhdx_path));

    try tmp.dir.writeFile(io, .{
        .sub_path = "disk.raw",
        .data = "plain raw bytes",
    });
    const raw_path = try tmp.dir.realPathFileAlloc(io, "disk.raw", allocator);
    defer allocator.free(raw_path);
    try std.testing.expectEqual(zvmi.Format.raw, try detectImageFormat(io, raw_path));
}

test "qemu bundle paths replace the image extension" {
    const allocator = std.testing.allocator;

    const with_extension = try bundlePathAlloc(allocator, "images/disk.qcow2", ".vars.fd");
    defer allocator.free(with_extension);
    try std.testing.expectEqualStrings("images/disk.vars.fd", with_extension);

    const without_extension = try bundlePathAlloc(allocator, "disk", ".code.fd");
    defer allocator.free(without_extension);
    try std.testing.expectEqualStrings("disk.code.fd", without_extension);
}

test "qemu persistent vars are reused" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "disk.vars.fd", .data = "template" });
    const vars_path = try tmp.dir.realPathFileAlloc(io, "disk.vars.fd", allocator);
    defer allocator.free(vars_path);

    var first = try preparePersistentVmStateAlloc(allocator, io, vars_path);
    defer first.deinit(allocator, io);
    try std.testing.expect(!first.temporary);
    const initial = try std.Io.Dir.cwd().readFileAlloc(
        io,
        first.vars_path,
        allocator,
        .limited(64),
    );
    defer allocator.free(initial);
    try std.testing.expectEqualStrings("template", initial);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = first.vars_path, .data = "preserved" });
    var second = try preparePersistentVmStateAlloc(allocator, io, vars_path);
    defer second.deinit(allocator, io);
    const reused = try std.Io.Dir.cwd().readFileAlloc(
        io,
        second.vars_path,
        allocator,
        .limited(64),
    );
    defer allocator.free(reused);
    try std.testing.expectEqualStrings("preserved", reused);
}

test "qemu snapshot vars are temporary and cleaned up" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "template.fd", .data = "template" });
    const template_path = try tmp.dir.realPathFileAlloc(io, "template.fd", allocator);
    defer allocator.free(template_path);
    var temp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const temp_len = try tmp.dir.realPath(io, &temp_buf);

    var state = try prepareSnapshotVmStateInDirAlloc(
        allocator,
        io,
        temp_buf[0..temp_len],
        "disk.qcow2",
        .{
            .path = template_path,
            .encoding = .raw,
        },
    );
    const vars_path = try allocator.dupe(u8, state.vars_path);
    defer allocator.free(vars_path);
    try std.testing.expect(state.temporary);
    try std.testing.expect(try qemu_host.pathAccessible(io, vars_path, .{ .read = true }));
    state.deinit(allocator, io);
    try std.testing.expect(!try qemu_host.pathAccessible(io, vars_path, .{ .read = true }));
}

test "qemu snapshot vars come from pristine compressed source" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const compressed_hex = "425a6839314159265359b2fb814a0000031180000223265480200022000f508069a6872f849c1e4e188f177245385090b2fb814a";
    var compressed: [compressed_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&compressed, compressed_hex);
    try tmp.dir.writeFile(io, .{ .sub_path = "template.fd.bz2", .data = &compressed });
    try tmp.dir.writeFile(io, .{ .sub_path = "disk.vars.fd", .data = "persistent-state" });

    const template_path = try tmp.dir.realPathFileAlloc(io, "template.fd.bz2", allocator);
    defer allocator.free(template_path);
    const persistent_path = try tmp.dir.realPathFileAlloc(io, "disk.vars.fd", allocator);
    defer allocator.free(persistent_path);
    var temp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const temp_len = try tmp.dir.realPath(io, &temp_buf);

    var state = try prepareSnapshotVmStateInDirAlloc(
        allocator,
        io,
        temp_buf[0..temp_len],
        "disk.qcow2",
        .{
            .path = template_path,
            .encoding = .bzip2,
        },
    );
    defer state.deinit(allocator, io);

    const snapshot_vars = try std.Io.Dir.cwd().readFileAlloc(
        io,
        state.vars_path,
        allocator,
        .limited(64),
    );
    defer allocator.free(snapshot_vars);
    const persistent_vars = try std.Io.Dir.cwd().readFileAlloc(
        io,
        persistent_path,
        allocator,
        .limited(64),
    );
    defer allocator.free(persistent_vars);
    try std.testing.expectEqualStrings("firmware-template", snapshot_vars);
    try std.testing.expectEqualStrings("persistent-state", persistent_vars);
}

test "qemu child exit mapping preserves normal exit status" {
    try std.testing.expectEqual(@as(?u8, 0), childExitCode(.{ .exited = 0 }));
    try std.testing.expectEqual(@as(?u8, 23), childExitCode(.{ .exited = 23 }));
    try std.testing.expectEqual(@as(?u8, null), childExitCode(.{ .unknown = 1 }));
}

test "qemu persistent launch argv matches the Azure Linux boot shape" {
    const allocator = std.testing.allocator;
    var argv = try buildQemuArgv(allocator, .{
        .qemu_path = "qemu-system-x86_64",
        .qemu_data_dir = "qemu/share",
        .architecture = .x86_64,
        .image_path = "AzureLinux-4.0-x86_64.qcow2",
        .image_format = .qcow2,
        .ovmf_code_path = "qemu/share/edk2-x86_64-code.fd",
        .ovmf_vars_path = "AzureLinux-4.0-x86_64.vars.fd",
        .accel = .whpx,
        .extra_qemu_args = &.{ "-d", "guest_errors" },
    });
    defer argv.deinit(allocator);

    try expectArgv(&.{
        "qemu-system-x86_64",
        "-L",
        "qemu/share",
        "-M",
        "q35,accel=whpx",
        "-cpu",
        "Nehalem-v1",
        "-m",
        "2G",
        "-smp",
        "2",
        "-drive",
        "if=pflash,unit=0,format=raw,readonly=on,file=qemu/share/edk2-x86_64-code.fd",
        "-drive",
        "if=pflash,unit=1,format=raw,file=AzureLinux-4.0-x86_64.vars.fd",
        "-drive",
        "file=AzureLinux-4.0-x86_64.qcow2,format=qcow2,if=virtio",
        "-nic",
        "user,model=virtio-net-pci",
        "-no-reboot",
        "-nographic",
        "-d",
        "guest_errors",
    }, argv.items.items);
}

test "qemu snapshot launch argv boots the temporary qcow2 overlay" {
    const allocator = std.testing.allocator;
    var argv = try buildQemuArgv(allocator, .{
        .qemu_path = "qemu-system-x86_64",
        .qemu_data_dir = null,
        .architecture = .x86_64,
        .image_path = "temporary-overlay.qcow2",
        .image_format = .qcow2,
        .ovmf_code_path = "code.fd",
        .ovmf_vars_path = "temporary-vars.fd",
        .accel = .tcg,
    });
    defer argv.deinit(allocator);

    try expectArgv(&.{
        "qemu-system-x86_64",
        "-M",
        "q35,accel=tcg",
        "-cpu",
        "Nehalem-v1",
        "-m",
        "2G",
        "-smp",
        "2",
        "-drive",
        "if=pflash,unit=0,format=raw,readonly=on,file=code.fd",
        "-drive",
        "if=pflash,unit=1,format=raw,file=temporary-vars.fd",
        "-drive",
        "file=temporary-overlay.qcow2,format=qcow2,if=virtio",
        "-nic",
        "user,model=virtio-net-pci",
        "-no-reboot",
        "-nographic",
    }, argv.items.items);
}

test "qemu AArch64 provisioning argv uses virt, SCSI CD, and host forwarding" {
    const allocator = std.testing.allocator;
    var argv = try buildQemuArgv(allocator, .{
        .qemu_path = "qemu-system-aarch64",
        .qemu_data_dir = null,
        .architecture = .aarch64,
        .image_path = "disk.qcow2",
        .image_format = .qcow2,
        .ovmf_code_path = "AAVMF_CODE.fd",
        .ovmf_vars_path = "disk.vars.fd",
        .accel = .tcg,
        .seed_iso_path = "seed.iso",
        .ssh_port = 2222,
        .provisioned = true,
    });
    defer argv.deinit(allocator);
    try expectArgv(&.{
        "qemu-system-aarch64",
        "-M",
        "virt,accel=tcg",
        "-cpu",
        "max",
        "-m",
        "2G",
        "-smp",
        "2",
        "-drive",
        "if=pflash,unit=0,format=raw,readonly=on,file=AAVMF_CODE.fd",
        "-drive",
        "if=pflash,unit=1,format=raw,file=disk.vars.fd",
        "-drive",
        "file=disk.qcow2,format=qcow2,if=virtio",
        "-device",
        "virtio-scsi-pci,id=scsi0",
        "-drive",
        "file=seed.iso,if=none,id=seed,media=cdrom,readonly=on,format=raw",
        "-device",
        "scsi-cd,drive=seed,bus=scsi0.0",
        "-nic",
        "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22",
        "-nographic",
    }, argv.items.items);
}

test "qemu AArch64 launch argv uses virt and max for TCG" {
    const allocator = std.testing.allocator;
    var argv = try buildQemuArgv(allocator, .{
        .qemu_path = "qemu-system-aarch64",
        .qemu_data_dir = null,
        .architecture = .aarch64,
        .image_path = "AzureLinux-4.0-aarch64.qcow2",
        .image_format = .qcow2,
        .ovmf_code_path = "AzureLinux-4.0-aarch64.code.fd",
        .ovmf_vars_path = "AzureLinux-4.0-aarch64.vars.fd",
        .accel = .tcg,
    });
    defer argv.deinit(allocator);

    try expectArgv(&.{
        "qemu-system-aarch64",
        "-M",
        "virt,accel=tcg",
        "-cpu",
        "max",
        "-m",
        "2G",
        "-smp",
        "2",
        "-drive",
        "if=pflash,unit=0,format=raw,readonly=on,file=AzureLinux-4.0-aarch64.code.fd",
        "-drive",
        "if=pflash,unit=1,format=raw,file=AzureLinux-4.0-aarch64.vars.fd",
        "-drive",
        "file=AzureLinux-4.0-aarch64.qcow2,format=qcow2,if=virtio",
        "-nic",
        "user,model=virtio-net-pci",
        "-no-reboot",
        "-nographic",
    }, argv.items.items);
}

test "qemu AArch64 KVM argv selects the host CPU" {
    try expectAarch64CpuArgv(.kvm, "host");
}

test "qemu AArch64 TCG argv selects the generic max CPU" {
    try expectAarch64CpuArgv(.tcg, "max");
}

test "qemu AArch64 HVF argv selects the host CPU" {
    try expectAarch64CpuArgv(.hvf, "host");
}

test "qemu x86 CPU selection remains stable across accelerators" {
    try std.testing.expectEqualStrings("Nehalem-v1", qemuCpuName(.x86_64, .kvm));
    try std.testing.expectEqualStrings("Nehalem-v1", qemuCpuName(.x86_64, .tcg));
}

test "qemu seed serializers escape XML and YAML user content" {
    const allocator = std.testing.allocator;
    const ovf = try buildOvfEnvAlloc(allocator, "admin", "ssh-ed25519 AAAA== a<&'b");
    defer allocator.free(ovf);
    try std.testing.expect(std.mem.indexOf(u8, ovf, "a&lt;&amp;&apos;b") != null);

    const user_data = try buildNoCloudUserDataAlloc(allocator, "admin", "ssh-ed25519 AAAA== a'b");
    defer allocator.free(user_data);
    try std.testing.expect(std.mem.indexOf(u8, user_data, "a''b'") != null);
    try std.testing.expect(std.mem.indexOf(u8, user_data, "ssh_authorized_keys") != null);
}

test "qemu-img snapshot overlay argv is explicit" {
    const argv = qemuImgCreateArgv(
        "qemu-img",
        "vpc",
        "C:\\images\\disk.vhd",
        "C:\\temp\\overlay.qcow2",
    );
    try expectArgv(&.{
        "qemu-img",
        "create",
        "-f",
        "qcow2",
        "-b",
        "C:\\images\\disk.vhd",
        "-F",
        "vpc",
        "C:\\temp\\overlay.qcow2",
    }, &argv);
}

test "qemu release download spec remains pinned to the validated Azure Linux release" {
    try std.testing.expectEqualStrings(
        "cataggar/zvmi/AzureLinux-4.0-x86_64.qcow2@AzureLinux-4.0-20260721",
        default_image_spec,
    );
    try std.testing.expectEqualStrings(
        "cataggar/zvmi/AzureLinux-4.0-x86_64.qcow2@AzureLinux-4.0-20260721",
        known_images[0].release_spec,
    );
    try std.testing.expectEqualStrings(
        "cataggar/zvmi/AzureLinux-4.0-aarch64.qcow2@AzureLinux-4.0-20260721",
        known_images[1].release_spec,
    );
}

test "qemu known image download argv is exact" {
    const allocator = std.testing.allocator;
    var image = try resolveImageAlloc(allocator, .{
        .image_path = "images/AzureLinux-4.0-aarch64",
        .image_was_explicit = true,
    });
    defer image.deinit(allocator);
    const argv = ghrDownloadArgv(image);
    try expectArgv(&.{
        "ghr",
        "download",
        "cataggar/zvmi/AzureLinux-4.0-aarch64.qcow2@AzureLinux-4.0-20260721",
        "--output",
        "images/AzureLinux-4.0-aarch64.qcow2",
    }, &argv);
}

test "qemu parses ghr metadata into package binary and data paths" {
    const allocator = std.testing.allocator;
    var paths = try parseGhrPackagePathsAlloc(allocator, "tools/cataggar/qemu",
        \\{
        \\  "tag": "v11.0.50-z.12",
        \\  "asset": "qemu-v11.0.50-z.12-windows-x64.zip",
        \\  "bins": [
        \\    "qemu-v11.0.50-z.12-windows-x64\\qemu-img.exe",
        \\    "qemu-v11.0.50-z.12-windows-x64\\qemu-system-x86_64.exe"
        \\  ]
        \\}
    , .x86_64);
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("qemu-system-x86_64.exe", std.fs.path.basename(paths.binary_path));
    try std.testing.expectEqualStrings("share", std.fs.path.basename(paths.data_dir));
}

test "qemu rejects ghr metadata without the x86_64 system emulator" {
    try std.testing.expectError(
        error.QemuBinaryMissingFromGhrMetadata,
        parseGhrPackagePathsAlloc(std.testing.allocator, "tools/cataggar/qemu",
            \\{"bins":["qemu-v11/qemu-img.exe"]}
        , .x86_64),
    );
}

test "qemu parses ghr metadata for the AArch64 system emulator" {
    const allocator = std.testing.allocator;
    var paths = try parseGhrPackagePathsForArchitectureAlloc(
        allocator,
        "tools/cataggar/qemu",
        "{\"bins\":[\"qemu-v11/qemu-img\",\"qemu-v11/qemu-system-aarch64\"]}",
        .aarch64,
    );
    defer paths.deinit(allocator);
    try std.testing.expectEqualStrings("qemu-system-aarch64", std.fs.path.basename(paths.binary_path));
}

test "qemu resolves a complete ghr package tree" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const package_dir = "cataggar/qemu/qemu-v11";
    try tmp.dir.createDirPath(io, package_dir);
    try tmp.dir.createDirPath(io, package_dir ++ "/share");

    const qemu_name = qemu_host.executableName("qemu-system-x86_64");
    const qemu_relative = try std.fs.path.join(allocator, &.{ package_dir, qemu_name });
    defer allocator.free(qemu_relative);
    var qemu_file = try tmp.dir.createFile(io, qemu_relative, .{ .permissions = .executable_file });
    qemu_file.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = package_dir ++ "/share/edk2-x86_64-code.fd",
        .data = "code",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = package_dir ++ "/share/edk2-i386-vars.fd",
        .data = "vars",
    });

    const metadata = try std.fmt.allocPrint(
        allocator,
        "{{\"bins\":[\"qemu-v11/{s}\"]}}",
        .{qemu_name},
    );
    defer allocator.free(metadata);
    try tmp.dir.writeFile(io, .{ .sub_path = "cataggar/qemu/ghr.json", .data = metadata });

    var tools_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tools_len = try tmp.dir.realPath(io, &tools_buf);
    var resolved = (try findGhrQemuAtToolsPathAlloc(
        allocator,
        io,
        tools_buf[0..tools_len],
        .{},
        .x86_64,
    )).?;
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings(qemu_name, std.fs.path.basename(resolved.binary_path));
    try std.testing.expectEqualStrings("share", std.fs.path.basename(resolved.data_dir.?));
    try std.testing.expectEqualStrings(
        "edk2-x86_64-code.fd",
        std.fs.path.basename(resolved.firmware.code.path),
    );
}

test "qemu resolves AArch64 from a ghr package containing both emulators" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const package_dir = "cataggar/qemu/qemu-v11";
    try tmp.dir.createDirPath(io, package_dir);
    try tmp.dir.createDirPath(io, package_dir ++ "/share");

    const x86_name = qemu_host.executableName("qemu-system-x86_64");
    const arm_name = qemu_host.executableName("qemu-system-aarch64");
    for ([_][]const u8{ x86_name, arm_name }) |qemu_name| {
        const relative = try std.fs.path.join(allocator, &.{ package_dir, qemu_name });
        defer allocator.free(relative);
        var file = try tmp.dir.createFile(io, relative, .{ .permissions = .executable_file });
        file.close(io);
    }
    try tmp.dir.writeFile(io, .{
        .sub_path = package_dir ++ "/share/edk2-aarch64-code.fd.bz2",
        .data = "compressed-code",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = package_dir ++ "/share/edk2-arm-vars.fd.bz2",
        .data = "compressed-vars",
    });

    const metadata = try std.fmt.allocPrint(
        allocator,
        "{{\"bins\":[\"qemu-v11/{s}\",\"qemu-v11/{s}\"]}}",
        .{ x86_name, arm_name },
    );
    defer allocator.free(metadata);
    try tmp.dir.writeFile(io, .{ .sub_path = "cataggar/qemu/ghr.json", .data = metadata });

    var tools_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tools_len = try tmp.dir.realPath(io, &tools_buf);
    var resolved = (try findGhrQemuAtToolsPathAlloc(
        allocator,
        io,
        tools_buf[0..tools_len],
        .{},
        .aarch64,
    )).?;
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings(arm_name, std.fs.path.basename(resolved.binary_path));
    try std.testing.expectEqual(qemu_host.FirmwareEncoding.bzip2, resolved.firmware.code.encoding);
    try std.testing.expectEqualStrings(
        "edk2-aarch64-code.fd.bz2",
        std.fs.path.basename(resolved.firmware.code.path),
    );
}

test "qemu ignores a ghr package whose recorded binary is missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "cataggar/qemu");
    try tmp.dir.writeFile(io, .{
        .sub_path = "cataggar/qemu/ghr.json",
        .data = "{\"bins\":[\"qemu-v11/qemu-system-x86_64.exe\"]}",
    });

    var tools_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tools_len = try tmp.dir.realPath(io, &tools_buf);
    const resolved = try findGhrQemuAtToolsPathAlloc(
        allocator,
        io,
        tools_buf[0..tools_len],
        .{},
        .x86_64,
    );
    try std.testing.expect(resolved == null);
}

test "qemu explicit paths bypass package and system discovery" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const qemu_name = qemu_host.executableName("qemu-system-x86_64");
    var qemu_file = try tmp.dir.createFile(io, qemu_name, .{ .permissions = .executable_file });
    qemu_file.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "code.fd", .data = "code" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vars.fd", .data = "vars" });

    const qemu_path = try tmp.dir.realPathFileAlloc(io, qemu_name, allocator);
    defer allocator.free(qemu_path);
    const code_path = try tmp.dir.realPathFileAlloc(io, "code.fd", allocator);
    defer allocator.free(code_path);
    const vars_path = try tmp.dir.realPathFileAlloc(io, "vars.fd", allocator);
    defer allocator.free(vars_path);

    var resolved = try resolveQemuAlloc(allocator, io, std.testing.environ, .{
        .qemu_path = qemu_path,
        .ovmf_code_path = code_path,
        .ovmf_vars_path = vars_path,
    }, .x86_64);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings(qemu_path, resolved.binary_path);
    try std.testing.expect(resolved.data_dir == null);
    try std.testing.expectEqualStrings(code_path, resolved.firmware.code.path);
    try std.testing.expectEqualStrings(vars_path, resolved.firmware.vars.path);
}

test "qemu resolves system QEMU and adjacent firmware from PATH" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "share", .default_dir);
    const qemu_name = qemu_host.executableName("qemu-system-x86_64");
    var qemu_file = try tmp.dir.createFile(io, qemu_name, .{ .permissions = .executable_file });
    qemu_file.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "share/edk2-x86_64-code.fd",
        .data = "code",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "share/edk2-i386-vars.fd",
        .data = "vars",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    var resolved = (try findSystemQemuInPathValueAlloc(
        allocator,
        io,
        path_buf[0..path_len],
        .{},
        .x86_64,
    )).?;
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings(qemu_name, std.fs.path.basename(resolved.binary_path));
    try std.testing.expectEqualStrings(
        "edk2-x86_64-code.fd",
        std.fs.path.basename(resolved.firmware.code.path),
    );
}

test "qemu system fallback returns null when PATH has no emulator" {
    const resolved = try findSystemQemuInPathValueAlloc(
        std.testing.allocator,
        std.testing.io,
        "definitely-missing-qemu-path",
        .{},
        .x86_64,
    );
    try std.testing.expect(resolved == null);
}
