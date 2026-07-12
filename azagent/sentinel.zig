//! Provisioning-complete sentinel file, so `azagent` doesn't re-provision
//! the VM on every subsequent boot. Matches upstream's
//! `ProvisionHandler.is_provisioned`/`write_provisioned`, minus the
//! unique-VM-identifier re-check (`is_current_instance_id`) -- out of
//! scope here since that requires IMDS access, explicitly out of scope
//! per issue #111.
const std = @import("std");

pub const sentinel_dir = "lib/azagent";
pub const sentinel_name = "provisioned";

/// True if `content` (the sentinel file's content, if present) indicates
/// provisioning already completed. Currently just existence-based (any
/// content, including empty, counts); kept as a function taking content
/// rather than a bare `exists` bool so a future version can validate the
/// content (e.g. an instance ID) without changing the call sites in
/// `main.zig`.
pub fn isProvisioned(content: ?[]const u8) bool {
    return content != null;
}

const read_limit: std.Io.Limit = .limited(4096);

/// Reads the sentinel file under `var_dir` (production passes the real
/// `/var`; tests pass a temp directory), returning its content if present.
pub fn readSentinel(allocator: std.mem.Allocator, var_dir: std.Io.Dir, io: std.Io) !?[]u8 {
    var dir = var_dir.openDir(io, sentinel_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);

    return dir.readFileAlloc(io, sentinel_name, allocator, read_limit) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

/// Writes the sentinel file (containing `content`, e.g. an instance
/// identifier or timestamp -- currently just informational) under
/// `var_dir`, creating `lib/azagent` if needed.
pub fn writeSentinel(var_dir: std.Io.Dir, io: std.Io, content: []const u8) !void {
    try var_dir.createDirPath(io, sentinel_dir);
    var dir = try var_dir.openDir(io, sentinel_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = sentinel_name, .data = content });
}

test "isProvisioned is false for null content and true otherwise" {
    try std.testing.expect(!isProvisioned(null));
    try std.testing.expect(isProvisioned(""));
    try std.testing.expect(isProvisioned("some-instance-id"));
}

test "readSentinel returns null when nothing has been written yet" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var var_dir = try tmp.dir.openDir(io, ".", .{});
    defer var_dir.close(io);

    try std.testing.expectEqual(@as(?[]u8, null), try readSentinel(allocator, var_dir, io));
}

test "writeSentinel then readSentinel round-trips the content" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var var_dir = try tmp.dir.openDir(io, ".", .{});
    defer var_dir.close(io);

    try writeSentinel(var_dir, io, "d34db33f-instance-id");

    const content = try readSentinel(allocator, var_dir, io);
    defer if (content) |c| allocator.free(c);
    try std.testing.expect(isProvisioned(content));
    try std.testing.expectEqualStrings("d34db33f-instance-id", content.?);
}
