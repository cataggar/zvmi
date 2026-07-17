//! Host-side QEMU executable and architecture-aware UEFI firmware discovery.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

pub const GuestArchitecture = enum {
    x86_64,
    aarch64,

    pub fn cliName(self: GuestArchitecture) []const u8 {
        return switch (self) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
        };
    }
};

pub const FirmwarePair = struct {
    code_path: []u8,
    vars_path: []u8,

    pub fn deinit(self: *FirmwarePair, allocator: std.mem.Allocator) void {
        allocator.free(self.code_path);
        allocator.free(self.vars_path);
        self.* = undefined;
    }
};

pub const FirmwareSearchOptions = struct {
    explicit_code_path: ?[]const u8 = null,
    explicit_vars_path: ?[]const u8 = null,
    qemu_path: ?[]const u8 = null,
    data_dirs: []const []const u8 = &.{},
    architecture: GuestArchitecture = .x86_64,
};

const FirmwareCandidate = struct {
    code: []const u8,
    vars: []const u8,
};

pub fn pathAccessible(io: Io, path: []const u8, options: Io.Dir.AccessOptions) !bool {
    Io.Dir.cwd().access(io, path, options) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied => return false,
        else => return err,
    };
    return true;
}

pub fn executableName(comptime base: []const u8) []const u8 {
    return if (builtin.os.tag == .windows) base ++ ".exe" else base;
}

pub fn qemuSystemName(architecture: GuestArchitecture) []const u8 {
    return switch (architecture) {
        .x86_64 => executableName("qemu-system-x86_64"),
        .aarch64 => executableName("qemu-system-aarch64"),
    };
}

pub fn findExecutableInPathAlloc(
    allocator: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    name: []const u8,
) !?[]u8 {
    const path_value = environ.getAlloc(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => return err,
    };
    defer allocator.free(path_value);
    return findExecutableInPathValueAlloc(allocator, io, path_value, name);
}

pub fn findExecutableInPathValueAlloc(
    allocator: std.mem.Allocator,
    io: Io,
    path_value: []const u8,
    name: []const u8,
) !?[]u8 {
    const suffix: []const u8 = if (builtin.os.tag == .windows and
        !(name.len >= 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".exe")))
        ".exe"
    else
        "";

    var it = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (it.next()) |dir_path| {
        const candidate = if (dir_path.len == 0)
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, suffix })
        else
            try std.fmt.allocPrint(
                allocator,
                "{s}{c}{s}{s}",
                .{ dir_path, std.fs.path.sep, name, suffix },
            );
        errdefer allocator.free(candidate);

        if (try pathAccessible(io, candidate, .{ .execute = true })) return candidate;
        allocator.free(candidate);
    }

    return null;
}

pub fn findFirmwarePairAlloc(
    allocator: std.mem.Allocator,
    io: Io,
    options: FirmwareSearchOptions,
) !?FirmwarePair {
    if (options.explicit_code_path != null or options.explicit_vars_path != null) {
        if (options.explicit_code_path == null or options.explicit_vars_path == null)
            return error.IncompleteFirmwareOverride;

        if (!try pathAccessible(io, options.explicit_code_path.?, .{ .read = true }) or
            !try pathAccessible(io, options.explicit_vars_path.?, .{ .read = true }))
        {
            return error.FirmwareNotReadable;
        }

        const code_path = try allocator.dupe(u8, options.explicit_code_path.?);
        errdefer allocator.free(code_path);
        return .{
            .code_path = code_path,
            .vars_path = try allocator.dupe(u8, options.explicit_vars_path.?),
        };
    }

    for (options.data_dirs) |data_dir| {
        if (try findFirmwareInDataDirAlloc(allocator, io, data_dir, options.architecture)) |pair| return pair;
    }

    if (options.qemu_path) |qemu_path| {
        if (std.fs.path.dirname(qemu_path)) |bin_dir| {
            const adjacent_share = try std.fs.path.join(allocator, &.{ bin_dir, "share" });
            defer allocator.free(adjacent_share);
            if (try findFirmwareInDataDirAlloc(allocator, io, adjacent_share, options.architecture)) |pair| return pair;

            if (std.fs.path.dirname(bin_dir)) |prefix| {
                const prefix_share = try std.fs.path.join(allocator, &.{ prefix, "share", "qemu" });
                defer allocator.free(prefix_share);
                if (try findFirmwareInDataDirAlloc(allocator, io, prefix_share, options.architecture)) |pair| return pair;
            }
        }
    }

    const candidates: []const FirmwareCandidate = switch (options.architecture) {
        .x86_64 => switch (builtin.os.tag) {
            .linux => &.{
                .{ .code = "/usr/share/OVMF/OVMF_CODE.fd", .vars = "/usr/share/OVMF/OVMF_VARS.fd" },
                .{ .code = "/usr/share/OVMF/OVMF_CODE_4M.fd", .vars = "/usr/share/OVMF/OVMF_VARS_4M.fd" },
                .{ .code = "/usr/share/edk2/ovmf/OVMF_CODE.fd", .vars = "/usr/share/edk2/ovmf/OVMF_VARS.fd" },
                .{ .code = "/usr/share/edk2/x64/OVMF_CODE.fd", .vars = "/usr/share/edk2/x64/OVMF_VARS.fd" },
                .{ .code = "/usr/share/qemu/edk2-x86_64-code.fd", .vars = "/usr/share/qemu/edk2-i386-vars.fd" },
            },
            .macos => &.{
                .{ .code = "/opt/homebrew/share/qemu/edk2-x86_64-code.fd", .vars = "/opt/homebrew/share/qemu/edk2-i386-vars.fd" },
                .{ .code = "/usr/local/share/qemu/edk2-x86_64-code.fd", .vars = "/usr/local/share/qemu/edk2-i386-vars.fd" },
                .{ .code = "/opt/local/share/qemu/edk2-x86_64-code.fd", .vars = "/opt/local/share/qemu/edk2-i386-vars.fd" },
            },
            else => &.{},
        },
        .aarch64 => switch (builtin.os.tag) {
            .linux => &.{
                .{ .code = "/usr/share/AAVMF/AAVMF_CODE.fd", .vars = "/usr/share/AAVMF/AAVMF_VARS.fd" },
                .{ .code = "/usr/share/AAVMF/AAVMF_CODE_4M.fd", .vars = "/usr/share/AAVMF/AAVMF_VARS_4M.fd" },
                .{ .code = "/usr/share/edk2/aarch64/QEMU_EFI.fd", .vars = "/usr/share/edk2/arm-vars.fd" },
                .{ .code = "/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw", .vars = "/usr/share/edk2/aarch64/vars-template-pflash.raw" },
                .{ .code = "/usr/share/edk2/aarch64/AAVMF_CODE.fd", .vars = "/usr/share/edk2/aarch64/AAVMF_VARS.fd" },
                .{ .code = "/usr/share/edk2/aarch64/edk2-aarch64-code.fd", .vars = "/usr/share/edk2/aarch64/edk2-arm-vars.fd" },
                .{ .code = "/usr/share/edk2/aarch64/code.fd", .vars = "/usr/share/edk2/aarch64/vars.fd" },
                .{ .code = "/usr/share/qemu/edk2-aarch64-code.fd", .vars = "/usr/share/qemu/edk2-arm-vars.fd" },
            },
            .macos => &.{
                .{ .code = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd", .vars = "/opt/homebrew/share/qemu/edk2-arm-vars.fd" },
                .{ .code = "/usr/local/share/qemu/edk2-aarch64-code.fd", .vars = "/usr/local/share/qemu/edk2-arm-vars.fd" },
                .{ .code = "/opt/local/share/qemu/edk2-aarch64-code.fd", .vars = "/opt/local/share/qemu/edk2-arm-vars.fd" },
            },
            else => &.{},
        },
    };

    for (candidates) |candidate| {
        if (try readableFirmwarePairAlloc(allocator, io, candidate.code, candidate.vars)) |pair|
            return pair;
    }

    return null;
}

fn findFirmwareInDataDirAlloc(
    allocator: std.mem.Allocator,
    io: Io,
    data_dir: []const u8,
    architecture: GuestArchitecture,
) !?FirmwarePair {
    const names = switch (architecture) {
        .x86_64 => [_]FirmwareCandidate{
            .{ .code = "edk2-x86_64-code.fd", .vars = "edk2-i386-vars.fd" },
            .{ .code = "OVMF_CODE.fd", .vars = "OVMF_VARS.fd" },
            .{ .code = "OVMF_CODE_4M.fd", .vars = "OVMF_VARS_4M.fd" },
            .{ .code = "", .vars = "" },
            .{ .code = "", .vars = "" },
            .{ .code = "", .vars = "" },
            .{ .code = "", .vars = "" },
        },
        .aarch64 => [_]FirmwareCandidate{
            .{ .code = "edk2-aarch64-code.fd", .vars = "edk2-arm-vars.fd" },
            .{ .code = "AAVMF_CODE.fd", .vars = "AAVMF_VARS.fd" },
            .{ .code = "AAVMF_CODE_4M.fd", .vars = "AAVMF_VARS_4M.fd" },
            .{ .code = "QEMU_EFI.fd", .vars = "AAVMF_VARS.fd" },
            .{ .code = "QEMU_EFI.fd", .vars = "vars.fd" },
            .{ .code = "QEMU_EFI-pflash.raw", .vars = "vars-template-pflash.raw" },
            .{ .code = "code.fd", .vars = "vars.fd" },
        },
    };

    for (names) |names_pair| {
        if (names_pair.code.len == 0) continue;
        const code_path = try std.fs.path.join(allocator, &.{ data_dir, names_pair.code });
        defer allocator.free(code_path);
        const vars_path = try std.fs.path.join(allocator, &.{ data_dir, names_pair.vars });
        defer allocator.free(vars_path);

        if (try readableFirmwarePairAlloc(allocator, io, code_path, vars_path)) |pair|
            return pair;
    }

    return null;
}

fn readableFirmwarePairAlloc(
    allocator: std.mem.Allocator,
    io: Io,
    code_path: []const u8,
    vars_path: []const u8,
) !?FirmwarePair {
    if (!try pathAccessible(io, code_path, .{ .read = true }) or
        !try pathAccessible(io, vars_path, .{ .read = true }))
    {
        return null;
    }

    const owned_code_path = try allocator.dupe(u8, code_path);
    errdefer allocator.free(owned_code_path);
    return .{
        .code_path = owned_code_path,
        .vars_path = try allocator.dupe(u8, vars_path),
    };
}

test "find executable in an explicit PATH value" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const name = executableName("qemu-system-x86_64");
    var executable = try tmp.dir.createFile(io, name, .{ .permissions = .executable_file });
    executable.close(io);

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const path_value = path_buf[0..path_len];

    const found = (try findExecutableInPathValueAlloc(allocator, io, path_value, "qemu-system-x86_64")).?;
    defer allocator.free(found);
    try std.testing.expectEqualStrings(name, std.fs.path.basename(found));
}

test "qemu executable names cover both guest architectures" {
    try std.testing.expectEqualStrings(
        executableName("qemu-system-x86_64"),
        qemuSystemName(.x86_64),
    );
    try std.testing.expectEqualStrings(
        executableName("qemu-system-aarch64"),
        qemuSystemName(.aarch64),
    );
}

test "find packaged edk2 firmware in a data directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "share", .default_dir);
    var code = try tmp.dir.createFile(io, "share/edk2-x86_64-code.fd", .{});
    code.close(io);
    var vars = try tmp.dir.createFile(io, "share/edk2-i386-vars.fd", .{});
    vars.close(io);

    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const data_dir = try std.fs.path.join(allocator, &.{ root_buf[0..root_len], "share" });
    defer allocator.free(data_dir);

    var pair = (try findFirmwarePairAlloc(allocator, io, .{
        .data_dirs = &.{data_dir},
    })).?;
    defer pair.deinit(allocator);

    try std.testing.expectEqualStrings("edk2-x86_64-code.fd", std.fs.path.basename(pair.code_path));
    try std.testing.expectEqualStrings("edk2-i386-vars.fd", std.fs.path.basename(pair.vars_path));
}

test "find packaged AAVMF firmware in a data directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "share", .default_dir);
    var code = try tmp.dir.createFile(io, "share/AAVMF_CODE.fd", .{});
    code.close(io);
    var vars = try tmp.dir.createFile(io, "share/AAVMF_VARS.fd", .{});
    vars.close(io);

    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const data_dir = try std.fs.path.join(allocator, &.{ root_buf[0..root_len], "share" });
    defer allocator.free(data_dir);

    var pair = (try findFirmwarePairAlloc(allocator, io, .{
        .architecture = .aarch64,
        .data_dirs = &.{data_dir},
    })).?;
    defer pair.deinit(allocator);
    try std.testing.expectEqualStrings("AAVMF_CODE.fd", std.fs.path.basename(pair.code_path));
    try std.testing.expectEqualStrings("AAVMF_VARS.fd", std.fs.path.basename(pair.vars_path));
}

test "find packaged AArch64 pflash firmware pair in a data directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "share", .default_dir);
    var code = try tmp.dir.createFile(io, "share/QEMU_EFI-pflash.raw", .{});
    code.close(io);
    var vars = try tmp.dir.createFile(io, "share/vars-template-pflash.raw", .{});
    vars.close(io);

    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const data_dir = try std.fs.path.join(allocator, &.{ root_buf[0..root_len], "share" });
    defer allocator.free(data_dir);

    var pair = (try findFirmwarePairAlloc(allocator, io, .{
        .architecture = .aarch64,
        .data_dirs = &.{data_dir},
    })).?;
    defer pair.deinit(allocator);
    try std.testing.expectEqualStrings("QEMU_EFI-pflash.raw", std.fs.path.basename(pair.code_path));
    try std.testing.expectEqualStrings("vars-template-pflash.raw", std.fs.path.basename(pair.vars_path));
}

test "firmware overrides must be complete" {
    try std.testing.expectError(
        error.IncompleteFirmwareOverride,
        findFirmwarePairAlloc(std.testing.allocator, std.testing.io, .{
            .explicit_code_path = "code.fd",
        }),
    );
}

test "unreadable explicit firmware is rejected" {
    try std.testing.expectError(
        error.FirmwareNotReadable,
        findFirmwarePairAlloc(std.testing.allocator, std.testing.io, .{
            .explicit_code_path = "missing-code.fd",
            .explicit_vars_path = "missing-vars.fd",
        }),
    );
}

test "firmware search returns null when no candidate is readable" {
    const pair = try findFirmwareInDataDirAlloc(
        std.testing.allocator,
        std.testing.io,
        "definitely-missing-qemu-data-dir",
        .x86_64,
    );
    try std.testing.expectEqual(@as(?FirmwarePair, null), pair);
}
