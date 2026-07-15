//! `zvmi qemu [<image>] [--snapshot] [--accel auto|whpx|kvm|hvf|tcg]
//!             [--qemu <path>] [--ovmf-code <path>] [--ovmf-vars <path>]
//!             [-- <extra-qemu-args...>]`

const std = @import("std");
const builtin = @import("builtin");
const zvmi = @import("zvmi");
const qemu_host = @import("qemu_host");

const default_image_name = "AzureLinux-4.0-x86_64.qcow2";
const default_image_spec = "cataggar/zvmi/AzureLinux-4.0-x86_64.qcow2@AzureLinux4.0-20260714";

const help_text =
    \\usage: zvmi qemu [<image>] [--snapshot] [--accel auto|whpx|kvm|hvf|tcg]
    \\                  [--qemu <path>] [--ovmf-code <path>] [--ovmf-vars <path>]
    \\                  [-- <extra-qemu-args...>]
    \\
    \\Boot an x86_64 Gen2/UEFI image interactively under QEMU.
    \\
    \\With no image argument, uses AzureLinux-4.0-x86_64.qcow2 in the current
    \\directory and downloads that release image with ghr when it is absent.
    \\
    \\Options:
    \\  --snapshot          Discard guest disk and UEFI variable changes on exit.
    \\  --accel <name>      Accelerator: auto (default), whpx, kvm, hvf, or tcg.
    \\  --qemu <path>       Explicit qemu-system-x86_64 executable.
    \\  --ovmf-code <path>  Explicit read-only OVMF code firmware.
    \\  --ovmf-vars <path>  Explicit OVMF variables template.
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

const Options = struct {
    image_path: []const u8 = default_image_name,
    image_was_explicit: bool = false,
    snapshot: bool = false,
    accel: Accel = .auto,
    qemu_path: ?[]const u8 = null,
    ovmf_code_path: ?[]const u8 = null,
    ovmf_vars_path: ?[]const u8 = null,
    extra_qemu_args: []const []const u8 = &.{},
    help: bool = false,
};

const ParseFailure = struct {
    kind: Kind,
    arg: []const u8,

    const Kind = enum {
        missing_value,
        invalid_accel,
        unknown_option,
        extra_image,
    };
};

const ParseResult = union(enum) {
    options: Options,
    failure: ParseFailure,
};

const ImageResolution = enum {
    use_existing,
    download_default,
    missing_explicit,
};

const HostCapabilities = struct {
    os_tag: std.Target.Os.Tag,
    cpu_arch: std.Target.Cpu.Arch,
    kvm_available: bool = false,
};

const LaunchPlan = struct {
    qemu_path: []const u8,
    qemu_data_dir: ?[]const u8,
    image_path: []const u8,
    image_format: zvmi.Format,
    ovmf_code_path: []const u8,
    ovmf_vars_path: []const u8,
    accel: Accel,
    extra_qemu_args: []const []const u8 = &.{},
};

const ResolvedQemu = struct {
    binary_path: []u8,
    data_dir: ?[]u8,
    firmware: qemu_host.FirmwarePair,

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
    var qemu = resolveQemuAlloc(gpa, io, environ, options) catch |err| {
        printQemuResolutionError(options, err);
        return 1;
    };
    defer qemu.deinit(gpa);

    ensureImage(io, options) catch |err| {
        switch (err) {
            error.ExplicitImageNotFound => std.debug.print(
                "qemu: image '{s}' does not exist; automatic download only applies to the default image\n",
                .{options.image_path},
            ),
            error.GhrNotFound => std.debug.print(
                "qemu: ghr was not found; install ghr or provide the default image as '{s}'\n",
                .{default_image_name},
            ),
            error.DownloadFailed => std.debug.print(
                "qemu: failed to download '{s}' with ghr\n",
                .{options.image_path},
            ),
            error.DownloadMissingOutput => std.debug.print(
                "qemu: ghr reported success but '{s}' was not created\n",
                .{options.image_path},
            ),
            else => std.debug.print(
                "qemu: failed to prepare image '{s}': {s}\n",
                .{ options.image_path, @errorName(err) },
            ),
        }
        return 1;
    };

    const image_format = detectImageFormat(io, options.image_path) catch |err| {
        std.debug.print(
            "qemu: failed to inspect image '{s}': {s}\n",
            .{ options.image_path, @errorName(err) },
        );
        return 1;
    };

    const host = currentHostCapabilities(io);
    const accel = resolveAccel(options.accel, host);
    var vm_state = prepareVmStateAlloc(
        gpa,
        io,
        environ,
        options,
        qemu.firmware.vars_path,
    ) catch |err| {
        std.debug.print(
            "qemu: failed to prepare UEFI vars from '{s}': {s}\n",
            .{ qemu.firmware.vars_path, @errorName(err) },
        );
        return 1;
    };
    defer vm_state.deinit(gpa, io);

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
            options.image_path,
            image_format,
        ) catch |err| {
            std.debug.print("qemu: failed to create temporary disk overlay: {s}\n", .{@errorName(err)});
            return 1;
        };
    }

    const launch_image_path = vm_state.overlay_path orelse options.image_path;
    const launch_image_format: zvmi.Format = if (vm_state.overlay_path != null) .qcow2 else image_format;
    var argv = buildQemuArgv(gpa, .{
        .qemu_path = qemu.binary_path,
        .qemu_data_dir = qemu.data_dir,
        .image_path = launch_image_path,
        .image_format = launch_image_format,
        .ovmf_code_path = qemu.firmware.code_path,
        .ovmf_vars_path = vm_state.vars_path,
        .accel = accel,
        .extra_qemu_args = options.extra_qemu_args,
    }) catch |err| {
        std.debug.print("qemu: failed to build QEMU arguments: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer argv.deinit(gpa);

    const mode = if (options.snapshot) "snapshot" else "persistent";
    std.debug.print(
        "qemu: launching image='{s}' format={s} qemu='{s}' accel={s} mode={s}\n",
        .{ options.image_path, qemuFormatName(image_format), qemu.binary_path, accel.cliName(), mode },
    );
    std.debug.print(
        "qemu: UEFI code='{s}' vars='{s}'\n",
        .{ qemu.firmware.code_path, vm_state.vars_path },
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
            return .{ .options = options };
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--snapshot")) {
            options.snapshot = true;
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
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return parseFailure(.unknown_option, arg);
        } else if (!options.image_was_explicit) {
            options.image_path = arg;
            options.image_was_explicit = true;
        } else {
            return parseFailure(.extra_image, arg);
        }
    }

    return .{ .options = options };
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
        .unknown_option => std.debug.print("qemu: unknown option '{s}'\n", .{failure.arg}),
        .extra_image => std.debug.print("qemu: unexpected image argument '{s}'\n", .{failure.arg}),
    }
}

fn resolveImage(options: Options, image_exists: bool) ImageResolution {
    if (image_exists) return .use_existing;
    return if (options.image_was_explicit) .missing_explicit else .download_default;
}

fn resolveAccel(requested: Accel, host: HostCapabilities) Accel {
    if (requested != .auto) return requested;
    if (host.cpu_arch != .x86_64) return .tcg;

    return switch (host.os_tag) {
        .windows => .whpx,
        .macos => .hvf,
        .linux => if (host.kvm_available) .kvm else .tcg,
        else => .tcg,
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
    options: Options,
    vars_template_path: []const u8,
) !PreparedVmState {
    if (!options.snapshot)
        return preparePersistentVmStateAlloc(allocator, io, options.image_path, vars_template_path);

    const temp_dir = try temporaryDirectoryAlloc(allocator, io, environ);
    defer allocator.free(temp_dir);
    return prepareSnapshotVmStateInDirAlloc(allocator, io, temp_dir, vars_template_path);
}

fn preparePersistentVmStateAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    image_path: []const u8,
    vars_template_path: []const u8,
) !PreparedVmState {
    const vars_path = try persistentVarsPathAlloc(allocator, image_path);
    errdefer allocator.free(vars_path);

    if (try qemu_host.pathAccessible(io, vars_path, .{ .read = true })) {
        if (!try qemu_host.pathAccessible(io, vars_path, .{ .write = true }))
            return error.VarsNotWritable;
    } else {
        try copyVarsTemplate(io, vars_template_path, vars_path);
    }

    return .{
        .vars_path = vars_path,
        .temporary = false,
    };
}

fn prepareSnapshotVmStateInDirAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_dir: []const u8,
    vars_template_path: []const u8,
) !PreparedVmState {
    const vars_path = try randomTempPathAlloc(
        allocator,
        io,
        temp_dir,
        "zvmi-qemu-vars-",
        ".fd",
    );
    errdefer allocator.free(vars_path);

    try copyVarsTemplate(io, vars_template_path, vars_path);
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

    if (builtin.os.tag != .windows)
        return allocator.dupe(u8, "/tmp");
    return std.process.currentPathAlloc(io, allocator);
}

fn copyVarsTemplate(
    io: std.Io,
    source_path: []const u8,
    destination_path: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.copyFile(source_path, cwd, destination_path, io, .{ .replace = false });
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
) !ResolvedQemu {
    if (options.qemu_path) |explicit_qemu| {
        if (!try qemu_host.pathAccessible(io, explicit_qemu, .{ .execute = true }))
            return error.ExplicitQemuNotExecutable;

        const binary_path = try allocator.dupe(u8, explicit_qemu);
        errdefer allocator.free(binary_path);
        const firmware = (try qemu_host.findFirmwarePairAlloc(allocator, io, .{
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

    if (try findGhrQemuAlloc(allocator, io, options)) |resolved| return resolved;

    return (try findSystemQemuAlloc(allocator, io, environ, options)) orelse
        return error.QemuNotFound;
}

fn findSystemQemuAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    options: Options,
) !?ResolvedQemu {
    const path_value = environ.getAlloc(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => return err,
    };
    defer allocator.free(path_value);
    return findSystemQemuInPathValueAlloc(allocator, io, path_value, options);
}

fn findSystemQemuInPathValueAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path_value: []const u8,
    options: Options,
) !?ResolvedQemu {
    const system_qemu = try qemu_host.findExecutableInPathValueAlloc(
        allocator,
        io,
        path_value,
        "qemu-system-x86_64",
    ) orelse return null;
    errdefer allocator.free(system_qemu);

    const firmware = (try qemu_host.findFirmwarePairAlloc(allocator, io, .{
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
) !?ResolvedQemu {
    const tools_path = try ghrToolsPathAlloc(allocator, io) orelse return null;
    defer allocator.free(tools_path);
    return findGhrQemuAtToolsPathAlloc(allocator, io, tools_path, options);
}

fn findGhrQemuAtToolsPathAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    tools_path: []const u8,
    options: Options,
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

    var package_paths = parseGhrPackagePathsAlloc(allocator, tool_dir, metadata_bytes) catch |err| switch (err) {
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

    const firmware_optional = qemu_host.findFirmwarePairAlloc(allocator, io, .{
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
) !GhrPackagePaths {
    const parsed = std.json.parseFromSlice(GhrMetadata, allocator, metadata_bytes, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidGhrMetadata;
    defer parsed.deinit();

    const relative_binary = for (parsed.value.bins) |bin_path| {
        if (isQemuSystemX86_64Name(std.fs.path.basename(bin_path))) break bin_path;
    } else return error.QemuBinaryMissingFromGhrMetadata;

    const binary_path = try std.fs.path.join(allocator, &.{ tool_dir, relative_binary });
    errdefer allocator.free(binary_path);
    const package_root = std.fs.path.dirname(binary_path) orelse
        return error.InvalidGhrMetadata;
    const data_dir = try std.fs.path.join(allocator, &.{ package_root, "share" });

    return .{
        .binary_path = binary_path,
        .data_dir = data_dir,
    };
}

fn isQemuSystemX86_64Name(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "qemu-system-x86_64") or
        std.ascii.eqlIgnoreCase(name, "qemu-system-x86_64.exe");
}

fn ensureImage(
    io: std.Io,
    options: Options,
) !void {
    const exists = try qemu_host.pathAccessible(io, options.image_path, .{ .read = true });
    switch (resolveImage(options, exists)) {
        .use_existing => return,
        .missing_explicit => return error.ExplicitImageNotFound,
        .download_default => {},
    }

    const argv = ghrDownloadArgv(options.image_path);
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

    if (!try qemu_host.pathAccessible(io, options.image_path, .{ .read = true }))
        return error.DownloadMissingOutput;
}

fn ghrDownloadArgv(image_path: []const u8) [5][]const u8 {
    return [5][]const u8{
        "ghr",
        "download",
        default_image_spec,
        "--output",
        image_path,
    };
}

fn printQemuResolutionError(options: Options, err: anyerror) void {
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
            "qemu: configured OVMF firmware is not readable\n",
            .{},
        ),
        error.FirmwareNotFound => std.debug.print(
            "qemu: OVMF firmware was not found; use --ovmf-code and --ovmf-vars\n",
            .{},
        ),
        error.QemuNotFound => std.debug.print(
            "qemu: qemu-system-x86_64 was not found\ninstall it with: ghr install cataggar/qemu\n",
            .{},
        ),
        error.InvalidGhrMetadata, error.QemuBinaryMissingFromGhrMetadata => std.debug.print(
            "qemu: the cataggar/qemu ghr installation metadata is invalid: {s}\n",
            .{@errorName(err)},
        ),
        else => std.debug.print("qemu: failed to resolve QEMU: {s}\n", .{@errorName(err)}),
    }
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
    try result.appendFmt(allocator, "q35,accel={s}", .{plan.accel.cliName()});
    try result.append(allocator, "-cpu");
    try result.append(allocator, "Nehalem-v1");
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
    try result.append(allocator, "-nic");
    try result.append(allocator, "user,model=virtio-net-pci");
    try result.append(allocator, "-no-reboot");
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

test "qemu parser defaults to the release image" {
    const parsed = parseArgs(&.{});
    const options = parsed.options;

    try std.testing.expectEqualStrings(default_image_name, options.image_path);
    try std.testing.expect(!options.image_was_explicit);
    try std.testing.expect(!options.snapshot);
    try std.testing.expectEqual(Accel.auto, options.accel);
    try std.testing.expectEqual(@as(usize, 0), options.extra_qemu_args.len);
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

test "qemu image resolution only downloads the absent implicit default" {
    const default_options = parseArgs(&.{}).options;
    try std.testing.expectEqual(ImageResolution.use_existing, resolveImage(default_options, true));
    try std.testing.expectEqual(ImageResolution.download_default, resolveImage(default_options, false));

    const explicit_options = parseArgs(&.{"custom.qcow2"}).options;
    try std.testing.expectEqual(ImageResolution.use_existing, resolveImage(explicit_options, true));
    try std.testing.expectEqual(ImageResolution.missing_explicit, resolveImage(explicit_options, false));
}

test "qemu auto accelerator follows host capabilities" {
    try std.testing.expectEqual(Accel.whpx, resolveAccel(.auto, .{
        .os_tag = .windows,
        .cpu_arch = .x86_64,
    }));
    try std.testing.expectEqual(Accel.hvf, resolveAccel(.auto, .{
        .os_tag = .macos,
        .cpu_arch = .x86_64,
    }));
    try std.testing.expectEqual(Accel.kvm, resolveAccel(.auto, .{
        .os_tag = .linux,
        .cpu_arch = .x86_64,
        .kvm_available = true,
    }));
    try std.testing.expectEqual(Accel.tcg, resolveAccel(.auto, .{
        .os_tag = .linux,
        .cpu_arch = .x86_64,
    }));
    try std.testing.expectEqual(Accel.tcg, resolveAccel(.auto, .{
        .os_tag = .macos,
        .cpu_arch = .aarch64,
    }));
    try std.testing.expectEqual(Accel.hvf, resolveAccel(.hvf, .{
        .os_tag = .windows,
        .cpu_arch = .aarch64,
    }));
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

test "qemu persistent vars path replaces the image extension" {
    const allocator = std.testing.allocator;

    const with_extension = try persistentVarsPathAlloc(allocator, "images/disk.qcow2");
    defer allocator.free(with_extension);
    try std.testing.expectEqualStrings("images/disk.vars.fd", with_extension);

    const without_extension = try persistentVarsPathAlloc(allocator, "disk");
    defer allocator.free(without_extension);
    try std.testing.expectEqualStrings("disk.vars.fd", without_extension);
}

test "qemu persistent vars are created once and reused" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "template.fd", .data = "template" });
    try tmp.dir.writeFile(io, .{ .sub_path = "disk.qcow2", .data = "disk" });
    const template_path = try tmp.dir.realPathFileAlloc(io, "template.fd", allocator);
    defer allocator.free(template_path);
    const image_path = try tmp.dir.realPathFileAlloc(io, "disk.qcow2", allocator);
    defer allocator.free(image_path);

    var first = try preparePersistentVmStateAlloc(allocator, io, image_path, template_path);
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
    var second = try preparePersistentVmStateAlloc(allocator, io, image_path, template_path);
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
        template_path,
    );
    const vars_path = try allocator.dupe(u8, state.vars_path);
    defer allocator.free(vars_path);
    try std.testing.expect(state.temporary);
    try std.testing.expect(try qemu_host.pathAccessible(io, vars_path, .{ .read = true }));
    state.deinit(allocator, io);
    try std.testing.expect(!try qemu_host.pathAccessible(io, vars_path, .{ .read = true }));
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

test "qemu release download spec remains pinned to the replace-in-place release" {
    try std.testing.expectEqualStrings(
        "cataggar/zvmi/AzureLinux-4.0-x86_64.qcow2@AzureLinux4.0-20260714",
        default_image_spec,
    );
}

test "qemu default image download argv is exact and verified by ghr defaults" {
    const argv = ghrDownloadArgv(default_image_name);
    try expectArgv(&.{
        "ghr",
        "download",
        "cataggar/zvmi/AzureLinux-4.0-x86_64.qcow2@AzureLinux4.0-20260714",
        "--output",
        "AzureLinux-4.0-x86_64.qcow2",
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
    );
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("qemu-system-x86_64.exe", std.fs.path.basename(paths.binary_path));
    try std.testing.expectEqualStrings("share", std.fs.path.basename(paths.data_dir));
}

test "qemu rejects ghr metadata without the x86_64 system emulator" {
    try std.testing.expectError(
        error.QemuBinaryMissingFromGhrMetadata,
        parseGhrPackagePathsAlloc(std.testing.allocator, "tools/cataggar/qemu",
            \\{"bins":["qemu-v11/qemu-img.exe"]}
        ),
    );
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
    var code = try tmp.dir.createFile(io, package_dir ++ "/share/edk2-x86_64-code.fd", .{});
    code.close(io);
    var vars = try tmp.dir.createFile(io, package_dir ++ "/share/edk2-i386-vars.fd", .{});
    vars.close(io);

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
    )).?;
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings(qemu_name, std.fs.path.basename(resolved.binary_path));
    try std.testing.expectEqualStrings("share", std.fs.path.basename(resolved.data_dir.?));
    try std.testing.expectEqualStrings(
        "edk2-x86_64-code.fd",
        std.fs.path.basename(resolved.firmware.code_path),
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
    var code = try tmp.dir.createFile(io, "code.fd", .{});
    code.close(io);
    var vars = try tmp.dir.createFile(io, "vars.fd", .{});
    vars.close(io);

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
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings(qemu_path, resolved.binary_path);
    try std.testing.expect(resolved.data_dir == null);
    try std.testing.expectEqualStrings(code_path, resolved.firmware.code_path);
    try std.testing.expectEqualStrings(vars_path, resolved.firmware.vars_path);
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
    var code = try tmp.dir.createFile(io, "share/edk2-x86_64-code.fd", .{});
    code.close(io);
    var vars = try tmp.dir.createFile(io, "share/edk2-i386-vars.fd", .{});
    vars.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    var resolved = (try findSystemQemuInPathValueAlloc(
        allocator,
        io,
        path_buf[0..path_len],
        .{},
    )).?;
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings(qemu_name, std.fs.path.basename(resolved.binary_path));
    try std.testing.expectEqualStrings(
        "edk2-x86_64-code.fd",
        std.fs.path.basename(resolved.firmware.code_path),
    );
}

test "qemu system fallback returns null when PATH has no emulator" {
    const resolved = try findSystemQemuInPathValueAlloc(
        std.testing.allocator,
        std.testing.io,
        "definitely-missing-qemu-path",
        .{},
    );
    try std.testing.expect(resolved == null);
}
