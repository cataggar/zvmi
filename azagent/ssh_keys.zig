//! Deploys SSH public keys into the provisioned user's
//! `~/.ssh/authorized_keys`, and regenerates the VM's SSH host keys.
//!
//! Only the raw `<Value>` public-key path from `ovf-env.xml` is supported
//! (see `ovf.zig`'s module doc comment for why the certificate-thumbprint
//! `<KeyPair>` private-key deployment path is out of scope).
const std = @import("std");
const Allocator = std.mem.Allocator;
const validation = @import("validation.zig");

/// True if `line` (an `authorized_keys` entry, no trailing newline) is
/// already present verbatim in `content`.
pub fn hasAuthorizedKey(content: []const u8, key_value: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, key_value)) return true;
    }
    return false;
}

/// Appends `key_value` to `content` if not already present, ensuring the
/// result ends with exactly one trailing newline. Deliberately idempotent
/// -- a small, deliberate improvement over upstream's unconditional
/// append, in case provisioning is ever re-run.
pub fn appendAuthorizedKeyIfMissing(allocator: Allocator, content: []const u8, key_value: []const u8) ![]u8 {
    if (hasAuthorizedKey(content, key_value)) {
        return allocator.dupe(u8, content);
    }
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, content.len + key_value.len + 2);
    errdefer out.deinit();
    const trimmed = std.mem.trimEnd(u8, content, "\n");
    if (trimmed.len > 0) {
        try out.writer.writeAll(trimmed);
        try out.writer.writeAll("\n");
    }
    try out.writer.writeAll(key_value);
    try out.writer.writeAll("\n");
    return out.toOwnedSlice();
}

/// True if `name` looks like an SSH host key file (`ssh_host_<type>_key`
/// or its `.pub` counterpart) -- what `reg_ssh_host_key`'s cleanup step
/// removes before regenerating fresh keys.
pub fn isSshHostKeyFile(name: []const u8) bool {
    const prefix = "ssh_host_";
    const infix = "_key";
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const rest = name[prefix.len..];
    return std.mem.indexOf(u8, rest, infix) != null;
}

test "hasAuthorizedKey matches a whole line only" {
    const content = "ssh-rsa AAAA1 a@b\nssh-rsa AAAA2 c@d\n";
    try std.testing.expect(hasAuthorizedKey(content, "ssh-rsa AAAA1 a@b"));
    try std.testing.expect(!hasAuthorizedKey(content, "ssh-rsa AAAA1"));
    try std.testing.expect(!hasAuthorizedKey(content, "ssh-rsa AAAA3 e@f"));
}

test "appendAuthorizedKeyIfMissing appends to empty content" {
    const allocator = std.testing.allocator;
    const result = try appendAuthorizedKeyIfMissing(allocator, "", "ssh-rsa AAAA1 a@b");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ssh-rsa AAAA1 a@b\n", result);
}

test "appendAuthorizedKeyIfMissing appends to existing content" {
    const allocator = std.testing.allocator;
    const result = try appendAuthorizedKeyIfMissing(allocator, "ssh-rsa AAAA1 a@b\n", "ssh-rsa AAAA2 c@d");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ssh-rsa AAAA1 a@b\nssh-rsa AAAA2 c@d\n", result);
}

test "appendAuthorizedKeyIfMissing is idempotent" {
    const allocator = std.testing.allocator;
    const existing = "ssh-rsa AAAA1 a@b\n";
    const result = try appendAuthorizedKeyIfMissing(allocator, existing, "ssh-rsa AAAA1 a@b");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(existing, result);
}

test "isSshHostKeyFile matches private and public host key files" {
    try std.testing.expect(isSshHostKeyFile("ssh_host_rsa_key"));
    try std.testing.expect(isSshHostKeyFile("ssh_host_rsa_key.pub"));
    try std.testing.expect(isSshHostKeyFile("ssh_host_ed25519_key"));
    try std.testing.expect(!isSshHostKeyFile("sshd_config"));
    try std.testing.expect(!isSshHostKeyFile("moduli"));
}

// ---------------------------------------------------------------------
// Impure half: real file I/O and process exec, scoped to caller-provided
// directory handles.
// ---------------------------------------------------------------------

const read_limit: std.Io.Limit = .limited(1024 * 1024);

/// Idempotently deploys `keys` into `home_dir`'s `.ssh/authorized_keys`
/// (creating `.ssh` with mode `0700` and the file with mode `0600`, both
/// owned by `uid`/`gid`, if not already present).
pub fn deployAuthorizedKeys(
    allocator: Allocator,
    home_dir: std.Io.Dir,
    io: std.Io,
    uid: std.Io.File.Uid,
    gid: std.Io.File.Gid,
    keys: []const []const u8,
) !void {
    if (keys.len == 0) return;
    for (keys) |key_value| try validation.validatePublicKey(key_value);

    try home_dir.createDirPath(io, ".ssh");
    var ssh_dir = try home_dir.openDir(io, ".ssh", .{ .iterate = true });
    defer ssh_dir.close(io);
    try ssh_dir.setPermissions(io, .fromMode(0o700));
    try ssh_dir.setOwner(io, uid, gid);

    // Make sure an existing authorized_keys is writable before we try to
    // update it (see sudoers.zig's configureSudoer for why: it may already
    // be locked to 0600 owned by a non-current-process uid from a previous
    // run, though unlike sudoers.zig's drop-in, 0600 is still owner-writable
    // so this mainly matters if a differently-privileged process re-runs
    // this step).
    ssh_dir.setFilePermissions(io, "authorized_keys", .fromMode(0o600), .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    var content = ssh_dir.readFileAlloc(io, "authorized_keys", allocator, read_limit) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(content);

    for (keys) |key_value| {
        const next = try appendAuthorizedKeyIfMissing(allocator, content, key_value);
        allocator.free(content);
        content = next;
    }

    try ssh_dir.writeFile(io, .{ .sub_path = "authorized_keys", .data = content });
    try ssh_dir.setFilePermissions(io, "authorized_keys", .fromMode(0o600), .{});
    {
        // Uses an opened File handle + File.setOwner rather than the
        // path-based Dir.setFileOwner (fchownat): this Zig toolchain's
        // Dir.setFileOwner has a declared error set narrower than what its
        // implementation can actually return (missing NameTooLong/
        // BadPathName), which fails to compile.
        const authorized_keys_file = try ssh_dir.openFile(io, "authorized_keys", .{});
        defer authorized_keys_file.close(io);
        try authorized_keys_file.setOwner(io, uid, gid);
    }
}

/// Removes any existing `ssh_host_*_key*` files under `ssh_dir` (see
/// `isSshHostKeyFile`), so a subsequent `ssh-keygen -A` generates fresh
/// ones rather than leaving a captured image's shared host keys in place.
pub fn removeHostKeyFiles(ssh_dir: std.Io.Dir, io: std.Io) !void {
    var it = ssh_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isSshHostKeyFile(entry.name)) continue;
        try ssh_dir.deleteFile(io, entry.name);
    }
}

/// Regenerates SSH host keys: removes existing `ssh_host_*_key*` files
/// under `ssh_dir`, then runs `ssh-keygen -A` (an explicit, deliberate
/// shell-out exception per issue #112 -- a normal, always-present OS
/// binary, not reimplementing key-generation cryptography from scratch).
/// `ssh_dir` must be `/etc/ssh` (or an equivalent real path) since
/// `ssh-keygen -A` itself always operates against the real `/etc/ssh`, not
/// an arbitrary directory handle -- so, unlike this module's other
/// functions, this one cannot be meaningfully sandboxed to a temp
/// directory and is not covered by an automated test.
pub fn regenerateHostKeys(allocator: Allocator, io: std.Io, ssh_dir: std.Io.Dir) !void {
    try removeHostKeyFiles(ssh_dir, io);
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "ssh-keygen", "-A" } });
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SshKeygenFailed,
        else => return error.SshKeygenFailed,
    }
}

test "removeHostKeyFiles deletes only ssh_host_*_key* entries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "ssh_host_rsa_key", .data = "priv" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ssh_host_rsa_key.pub", .data = "pub" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ssh_host_ed25519_key", .data = "priv2" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sshd_config", .data = "keep me" });

    var ssh_dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer ssh_dir.close(io);

    try removeHostKeyFiles(ssh_dir, io);

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "ssh_host_rsa_key", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "ssh_host_rsa_key.pub", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "ssh_host_ed25519_key", .{}));
    _ = try tmp.dir.statFile(io, "sshd_config", .{});
}

test "deployAuthorizedKeys writes and dedupes keys under a scoped home dir" {
    if (std.os.linux.geteuid() != 0) {
        std.debug.print("skipping deployAuthorizedKeys test: not running as root, chown would fail\n", .{});
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_dir = try tmp.dir.openDir(io, ".", .{});
    defer home_dir.close(io);

    try deployAuthorizedKeys(allocator, home_dir, io, 1000, 1000, &.{ "ssh-rsa AAAA1 a@b", "ssh-rsa AAAA2 c@d" });
    // Re-run to check idempotency (no duplicate lines).
    try deployAuthorizedKeys(allocator, home_dir, io, 1000, 1000, &.{"ssh-rsa AAAA1 a@b"});

    const content = try tmp.dir.readFileAlloc(io, ".ssh/authorized_keys", allocator, read_limit);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("ssh-rsa AAAA1 a@b\nssh-rsa AAAA2 c@d\n", content);
}
