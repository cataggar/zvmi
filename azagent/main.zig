//! `azagent`: minimal guest provisioning agent for first-boot Azure VM
//! setup. Native Zig replacement for the provisioning portion of Python
//! `waagent` (Microsoft Azure Linux Agent) -- see zvmi issue #112.
//!
//! Deliberately not named `waagent`: this project does not aim for
//! binary/config/CLI compatibility with the real Azure Linux Agent (no
//! `-deprovision` flag, no `/etc/waagent.conf`, no VM extension handling --
//! see the issue for the full list of what's explicitly out of scope).
const std = @import("std");
const wireserver = @import("wireserver");

pub const ovf = @import("ovf.zig");
pub const hostname = @import("hostname.zig");
pub const passwd = @import("passwd.zig");
pub const sudoers = @import("sudoers.zig");
pub const ssh_keys = @import("ssh_keys.zig");
pub const sentinel = @import("sentinel.zig");
pub const cdrom = @import("cdrom.zig");

/// Everything `provision` needs, injected rather than hardcoded, so it's
/// fully testable against a scoped temp directory instead of the real
/// `/etc`, `/home`, and `/var` (see the test at the bottom of this file).
pub const Deps = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    etc_dir: std.Io.Dir,
    home_parent_dir: std.Io.Dir,
    var_dir: std.Io.Dir,
    /// Already-read content of `ovf-env.xml` (fetching it off the
    /// provisioning CD-ROM is `main`'s job, via `cdrom.zig`, not
    /// `provision`'s -- keeps `provision` itself free of any real device
    /// I/O and therefore testable).
    ovf_env_xml: []const u8,
    now_unix_seconds: i64,
    /// `null` skips WireServer goal-state/health reporting entirely (used
    /// by tests, and tolerated in production too -- see the doc comment
    /// on `reportHealthBestEffort`).
    wireserver_client: ?*wireserver.Client = null,
    delete_root_password: bool = true,
    /// `null` skips host key regeneration (used by tests, since it needs a
    /// real `/etc/ssh` and the `ssh-keygen` binary on `PATH`).
    ssh_dir: ?std.Io.Dir = null,
};

/// Runs the full first-boot provisioning sequence (see issue #112's
/// phased plan), skipping entirely if the sentinel from a previous run is
/// already present. Idempotent by construction: every step it calls is
/// itself idempotent (see each module's doc comments), so re-running
/// `provision` (e.g. if the sentinel were ever lost) is safe.
pub fn provision(deps: Deps) !void {
    if (try sentinel.readSentinel(deps.allocator, deps.var_dir, deps.io)) |existing| {
        deps.allocator.free(existing);
        return;
    }

    const env = try ovf.OvfEnv.parse(deps.ovf_env_xml);

    try hostname.publish(deps.etc_dir, deps.io, env.hostname);

    const user = try passwd.createUserIfMissing(deps.allocator, deps.etc_dir, deps.home_parent_dir, deps.io, env.username, deps.now_unix_seconds);
    defer deps.allocator.free(user.home);

    {
        var home_dir = try deps.home_parent_dir.openDir(deps.io, env.username, .{ .iterate = true });
        defer home_dir.close(deps.io);

        var keys_buf: [ovf.OvfEnv.max_public_keys][]const u8 = undefined;
        var keys_len: usize = 0;
        for (env.publicKeys()) |pk| {
            keys_buf[keys_len] = pk.value;
            keys_len += 1;
        }
        try ssh_keys.deployAuthorizedKeys(deps.allocator, home_dir, deps.io, user.uid, user.gid, keys_buf[0..keys_len]);
    }

    try sudoers.configureSudoer(deps.allocator, deps.etc_dir, deps.io, env.username);

    if (deps.delete_root_password) {
        try passwd.lockRootPasswordInPlace(deps.allocator, deps.etc_dir, deps.io);
    }

    if (deps.ssh_dir) |ssh_dir| {
        try ssh_keys.regenerateHostKeys(deps.allocator, deps.io, ssh_dir);
    }

    if (deps.wireserver_client) |client| {
        reportHealthBestEffort(deps.allocator, client);
    }

    try sentinel.writeSentinel(deps.var_dir, deps.io, env.hostname);
}

/// Fetches the goal state and reports "Ready" health back to the
/// WireServer. Deliberately best-effort (logs and continues on failure,
/// rather than failing provisioning): unlike the local account-setup
/// steps, which are self-contained and either succeed or don't, WireServer
/// reachability depends on external network state this agent doesn't
/// control, and skipping it doesn't leave the VM any less usable (it's
/// telemetry back to the platform, not something the VM itself depends
/// on).
fn reportHealthBestEffort(allocator: std.mem.Allocator, client: *wireserver.Client) void {
    reportHealth(allocator, client) catch |err| {
        std.debug.print("azagent: warning: failed to report health to the WireServer: {t}\n", .{err});
    };
}

fn reportHealth(allocator: std.mem.Allocator, client: *wireserver.Client) !void {
    const goal_state_xml = try client.fetchGoalState(allocator);
    defer allocator.free(goal_state_xml);
    const gs = try wireserver.GoalState.parse(goal_state_xml);
    try client.reportHealth(allocator, .{
        .incarnation = gs.incarnation,
        .container_id = gs.container_id,
        .role_instance_id = gs.role_instance_id,
        .state = .ready,
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    if (std.os.linux.geteuid() != 0) {
        std.debug.print("azagent: must run as root\n", .{});
        std.process.exit(1);
    }

    const ovf_env_xml = cdrom.readOvfEnv(gpa, io) catch |err| {
        std.debug.print("azagent: failed to read ovf-env.xml from the provisioning media: {t}\n", .{err});
        std.process.exit(1);
    };
    defer gpa.free(ovf_env_xml);

    var etc_dir = try std.Io.Dir.cwd().openDir(io, "/etc", .{});
    defer etc_dir.close(io);
    var home_parent_dir = try std.Io.Dir.cwd().openDir(io, "/home", .{});
    defer home_parent_dir.close(io);
    var var_dir = try std.Io.Dir.cwd().openDir(io, "/var", .{});
    defer var_dir.close(io);
    var ssh_dir = try etc_dir.openDir(io, "ssh", .{ .iterate = true });
    defer ssh_dir.close(io);

    var client: wireserver.Client = .init(gpa, io);
    defer client.deinit();

    const now = std.Io.Clock.real.now(io);
    const now_unix_seconds: i64 = @intCast(@divTrunc(now.nanoseconds, 1_000_000_000));

    try provision(.{
        .allocator = gpa,
        .io = io,
        .etc_dir = etc_dir,
        .home_parent_dir = home_parent_dir,
        .var_dir = var_dir,
        .ovf_env_xml = ovf_env_xml,
        .now_unix_seconds = now_unix_seconds,
        .wireserver_client = &client,
        .ssh_dir = ssh_dir,
    });
}

test {
    _ = ovf;
    _ = hostname;
    _ = passwd;
    _ = sudoers;
    _ = ssh_keys;
    _ = sentinel;
    _ = cdrom;
}

test "provision runs the full sequence end to end against scoped temp directories" {
    if (std.os.linux.geteuid() != 0) {
        std.debug.print("skipping provision end-to-end test: not running as root, chown would fail\n", .{});
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "passwd", .data = "root:x:0:0::/root:/bin/bash\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "group", .data = "root:x:0:\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "shadow", .data = "root:$6$abc$def:19000:0:99999:7:::\n" });
    try tmp.dir.createDir(io, "home", .default_dir);
    try tmp.dir.createDir(io, "var", .default_dir);

    var etc_dir = try tmp.dir.openDir(io, ".", .{});
    defer etc_dir.close(io);
    var home_parent_dir = try tmp.dir.openDir(io, "home", .{});
    defer home_parent_dir.close(io);
    var var_dir = try tmp.dir.openDir(io, "var", .{});
    defer var_dir.close(io);

    const ovf_env_xml =
        \\<Environment xmlns="http://schemas.dmtf.org/ovf/environment/1">
        \\  <wa:ProvisioningSection xmlns:wa="http://schemas.microsoft.com/windowsazure">
        \\    <LinuxProvisioningConfigurationSet xmlns="http://schemas.microsoft.com/windowsazure">
        \\      <HostName>test-host</HostName>
        \\      <UserName>azureuser</UserName>
        \\      <DisableSshPasswordAuthentication>true</DisableSshPasswordAuthentication>
        \\      <SSH><PublicKeys><PublicKey><Value>ssh-rsa AAAATEST== a@b</Value></PublicKey></PublicKeys></SSH>
        \\    </LinuxProvisioningConfigurationSet>
        \\  </wa:ProvisioningSection>
        \\</Environment>
    ;

    try provision(.{
        .allocator = allocator,
        .io = io,
        .etc_dir = etc_dir,
        .home_parent_dir = home_parent_dir,
        .var_dir = var_dir,
        .ovf_env_xml = ovf_env_xml,
        .now_unix_seconds = 19700 * 86_400,
    });

    const passwd_after = try tmp.dir.readFileAlloc(io, "passwd", allocator, .limited(4096));
    defer allocator.free(passwd_after);
    try std.testing.expect(std.mem.indexOf(u8, passwd_after, "azureuser:x:1000:1000::/home/azureuser:/bin/bash\n") != null);

    const shadow_after = try tmp.dir.readFileAlloc(io, "shadow", allocator, .limited(4096));
    defer allocator.free(shadow_after);
    try std.testing.expect(std.mem.indexOf(u8, shadow_after, "root:!$6$abc$def:") != null);

    const authorized_keys = try tmp.dir.readFileAlloc(io, "home/azureuser/.ssh/authorized_keys", allocator, .limited(4096));
    defer allocator.free(authorized_keys);
    try std.testing.expectEqualStrings("ssh-rsa AAAATEST== a@b\n", authorized_keys);

    const sudoers_drop_in = try tmp.dir.readFileAlloc(io, "sudoers.d/azagent", allocator, .limited(4096));
    defer allocator.free(sudoers_drop_in);
    try std.testing.expectEqualStrings("azureuser ALL=(ALL) NOPASSWD: ALL\n", sudoers_drop_in);

    const sentinel_content = try tmp.dir.readFileAlloc(io, "var/lib/azagent/provisioned", allocator, .limited(4096));
    defer allocator.free(sentinel_content);
    try std.testing.expectEqualStrings("test-host", sentinel_content);

    // A second call should be a no-op (sentinel present).
    try provision(.{
        .allocator = allocator,
        .io = io,
        .etc_dir = etc_dir,
        .home_parent_dir = home_parent_dir,
        .var_dir = var_dir,
        .ovf_env_xml = ovf_env_xml,
        .now_unix_seconds = 19700 * 86_400,
    });
}
