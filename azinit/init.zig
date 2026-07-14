//! Minimal PID 1 replacement for a from-scratch Azure Linux container-image
//! VM. Responsibilities:
//!   - mount /proc /sys /dev /run (essential pseudo-filesystems)
//!   - mount the ESP at /boot/efi (best-effort, tries a few device-name
//!     conventions since the disk controller varies: virtio -> vdaN,
//!     SCSI/Azure -> sdaN, NVMe -> nvme0n1pN)
//!   - set the hostname
//!   - bring up loopback + run a small DHCP client on the first non-lo
//!     interface, then write /etc/resolv.conf
//!   - install SIGTERM/SIGINT handlers that cleanly power off/reboot, and
//!     double as /sbin/poweroff, /sbin/reboot, /sbin/shutdown (dispatched
//!     by argv[0]) so the kernel's orderly_poweroff() usermode-helper path
//!     (driven by Hyper-V's shutdown integration service) has something to
//!     exec.
//!   - loop forever spawning an interactive shell on /dev/ttyS0, respawning
//!     it if it ever exits (PID 1 exiting panics the kernel), and reaping
//!     all other zombie children along the way.
//! Root stays mounted read-only by default (matches the dm-verity/immutable
//! image philosophy elsewhere in this project). `azinit.mode=persistent`
//! opts into a writable root for generalized VM images whose provisioned
//! accounts, SSH keys, host keys, and azagent sentinel must survive reboot.
const std = @import("std");
const linux = std.os.linux;

var log_fd: i32 = -1;

fn openDebugLog() void {
    const rc = linux.open("/run/azinit.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    const fd: i32 = @intCast(rc);
    if (linux.errno(rc) == .SUCCESS) log_fd = fd;
}

fn writeStr(s: []const u8) void {
    _ = linux.write(2, s.ptr, s.len);
    if (log_fd >= 0) _ = linux.write(log_fd, s.ptr, s.len);
}

fn writeErrno(prefix: []const u8, e: linux.E) void {
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: errno={d}\r\n", .{ prefix, @intFromEnum(e) }) catch "errno format failed\r\n";
    writeStr(msg);
}

fn forkProcess(error_prefix: []const u8) ?linux.pid_t {
    const rc = linux.fork();
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        writeErrno(error_prefix, e);
        return null;
    }
    return @intCast(rc);
}

fn mountIgnoreBusy(special: ?[*:0]const u8, dir: [*:0]const u8, fstype: ?[*:0]const u8, flags: u32) void {
    const rc = linux.mount(special, dir, fstype, flags, 0);
    const e = linux.errno(rc);
    if (e != .SUCCESS and e != .BUSY) {
        var buf: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "mount {s} failed: errno={d}\r\n", .{ dir, @intFromEnum(e) }) catch "mount failed\r\n";
        writeStr(msg);
    }
}

fn mkdirIgnoreExists(path: [*:0]const u8) void {
    const rc = linux.mkdir(path, 0o755);
    const e = linux.errno(rc);
    if (e != .SUCCESS and e != .EXIST) {
        writeErrno("mkdir failed", e);
    }
}

// --- ESP mount: try a handful of common partition-1 device-name schemes ---
// Retries briefly since the kernel may not have finished creating the
// partition device nodes by the time we first try (a real race observed in
// testing). Passes an explicit iocharset=ascii to sidestep environments
// where the vfat driver's default iso8859-1 NLS table isn't built in.
fn tryMountEsp() void {
    mkdirIgnoreExists("/boot");
    mkdirIgnoreExists("/boot/efi");
    const candidates = [_][*:0]const u8{
        "/dev/sda1",
        "/dev/vda1",
        "/dev/xvda1",
        "/dev/nvme0n1p1",
    };
    var retry: u32 = 0;
    while (retry < 5) : (retry += 1) {
        for (candidates) |dev| {
            const rc = linux.mount(dev, "/boot/efi", "vfat", 0, @intFromPtr("iocharset=ascii"));
            const e = linux.errno(rc);
            if (e == .SUCCESS) {
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "[azinit] mounted {s} at /boot/efi\r\n", .{dev}) catch "[azinit] mounted ESP\r\n";
                writeStr(msg);
                return;
            }
        }
        const req: linux.timespec = .{ .sec = 0, .nsec = 200_000_000 };
        _ = linux.nanosleep(&req, null);
    }
    writeStr("[azinit] no ESP candidate device mounted (non-fatal)\r\n");
}

// --- signal-driven / argv0-driven shutdown ---
fn doReboot(cmd: linux.LINUX_REBOOT.CMD) noreturn {
    _ = linux.syscall0(.sync);
    _ = linux.reboot(.MAGIC1, .MAGIC2, cmd, null);
    // reboot() only returns on failure.
    linux.exit(0);
}

var shutdown_requested: bool = false;

fn onTermSignal(sig: linux.SIG) callconv(.c) void {
    _ = sig;
    shutdown_requested = true;
}

fn installShutdownHandlers() void {
    var sa: linux.Sigaction = .{
        .handler = .{ .handler = &onTermSignal },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(.TERM, &sa, null);
    _ = linux.sigaction(.INT, &sa, null);
}

// --- hostname ---
fn setKernelHostname(name: []const u8) void {
    const rc = linux.syscall2(.sethostname, @intFromPtr(name.ptr), name.len);
    const e = linux.errno(rc);
    if (e != .SUCCESS) writeErrno("sethostname failed", e);
}

fn parsePersistedHostname(content: []const u8) ?[]const u8 {
    const name = std.mem.trim(u8, content, " \t\r\n");
    if (name.len == 0 or name.len > linux.HOST_NAME_MAX or std.mem.indexOfScalar(u8, name, 0) != null) return null;
    return name;
}

fn readPersistedHostname(buf: []u8) ?[]const u8 {
    const fd_rc = linux.open("/etc/hostname", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var total: usize = 0;
    while (total < buf.len) {
        const read_rc = linux.read(fd, buf[total..].ptr, buf.len - total);
        const read_error = linux.errno(read_rc);
        if (read_error == .INTR) continue;
        if (read_error != .SUCCESS) {
            writeErrno("[azinit] reading /etc/hostname failed", read_error);
            return null;
        }
        if (read_rc == 0) break;
        total += read_rc;
    }
    if (total == buf.len) {
        writeStr("[azinit] /etc/hostname is too long; using default hostname\r\n");
        return null;
    }
    return parsePersistedHostname(buf[0..total]);
}

fn setHostname(mode: BootMode, persistent_root_ready: bool) void {
    if (mode == .persistent and persistent_root_ready) {
        var buf: [linux.HOST_NAME_MAX + 2]u8 = undefined;
        if (readPersistedHostname(&buf)) |name| {
            setKernelHostname(name);
            return;
        }
    }
    setKernelHostname("azurelinux");
}

fn isValidMachineId(content: []const u8) bool {
    const id = std.mem.trimEnd(u8, content, "\r\n");
    if (id.len != 32) return false;
    for (id) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

fn formatMachineId(random: [16]u8) [33]u8 {
    const hex = "0123456789abcdef";
    var result: [33]u8 = undefined;
    for (random, 0..) |byte, index| {
        result[index * 2] = hex[byte >> 4];
        result[index * 2 + 1] = hex[byte & 0x0f];
    }
    result[32] = '\n';
    return result;
}

fn machineIdExists() bool {
    const fd_rc = linux.open("/etc/machine-id", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var buf: [34]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const read_rc = linux.read(fd, buf[total..].ptr, buf.len - total);
        const read_error = linux.errno(read_rc);
        if (read_error == .INTR) continue;
        if (read_error != .SUCCESS) return false;
        if (read_rc == 0) break;
        total += read_rc;
    }
    return total < buf.len and isValidMachineId(buf[0..total]);
}

fn ensureMachineId() void {
    if (!etc_writable or machineIdExists()) return;

    var random: [16]u8 = undefined;
    var random_len: usize = 0;
    while (random_len < random.len) {
        const random_rc = linux.getrandom(random[random_len..].ptr, random.len - random_len, 0);
        const random_error = linux.errno(random_rc);
        if (random_error == .INTR) continue;
        if (random_error != .SUCCESS or random_rc == 0) {
            writeErrno("[azinit] generating machine-id failed", random_error);
            return;
        }
        random_len += random_rc;
    }

    const content = formatMachineId(random);
    const fd_rc = linux.open("/etc/machine-id", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o444);
    if (linux.errno(fd_rc) != .SUCCESS) {
        writeErrno("[azinit] opening /etc/machine-id for writing failed", linux.errno(fd_rc));
        return;
    }
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var written: usize = 0;
    while (written < content.len) {
        const write_rc = linux.write(fd, content[written..].ptr, content.len - written);
        const write_error = linux.errno(write_rc);
        if (write_error == .INTR) continue;
        if (write_error != .SUCCESS or write_rc == 0) {
            writeErrno("[azinit] writing /etc/machine-id failed", write_error);
            return;
        }
        written += write_rc;
    }
    _ = linux.fsync(fd);
    writeStr("[azinit] generated /etc/machine-id\r\n");
}

const BootMode = enum {
    immutable,
    persistent,
};

const BootModeConfig = struct {
    mode: BootMode = .immutable,
    invalid_value: ?[]const u8 = null,
};

fn parseBootMode(cmdline: []const u8) BootModeConfig {
    const prefix = "azinit.mode=";
    var config: BootModeConfig = .{};
    var tokens = std.mem.tokenizeAny(u8, cmdline, " \t\r\n");
    while (tokens.next()) |token| {
        if (!std.mem.startsWith(u8, token, prefix)) continue;
        const value = token[prefix.len..];
        if (std.mem.eql(u8, value, "persistent")) {
            config = .{ .mode = .persistent };
        } else if (std.mem.eql(u8, value, "immutable")) {
            config = .{ .mode = .immutable };
        } else {
            config = .{ .invalid_value = value };
        }
    }
    return config;
}

fn readBootMode() BootMode {
    var fd_rc: usize = undefined;
    while (true) {
        fd_rc = linux.open("/proc/cmdline", .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(fd_rc) != .INTR) break;
    }
    if (linux.errno(fd_rc) != .SUCCESS) {
        writeErrno("[azinit] opening /proc/cmdline failed; using immutable mode", linux.errno(fd_rc));
        return .immutable;
    }
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var buf: [4097]u8 = undefined;
    var read_rc: usize = undefined;
    while (true) {
        read_rc = linux.read(fd, &buf, buf.len);
        if (linux.errno(read_rc) != .INTR) break;
    }
    if (linux.errno(read_rc) != .SUCCESS) {
        writeErrno("[azinit] reading /proc/cmdline failed; using immutable mode", linux.errno(read_rc));
        return .immutable;
    }
    if (read_rc == buf.len) {
        writeStr("[azinit] /proc/cmdline is too long; using immutable mode\r\n");
        return .immutable;
    }

    const config = parseBootMode(buf[0..read_rc]);
    if (config.invalid_value) |value| {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "[azinit] invalid azinit.mode={s}; using immutable mode\r\n", .{value}) catch "[azinit] invalid azinit.mode; using immutable mode\r\n";
        writeStr(msg);
        return .immutable;
    }
    return config.mode;
}

fn remountRootWritable() bool {
    const rc = linux.mount(null, "/", null, linux.MS.REMOUNT, 0);
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        writeErrno("[azinit] remounting / read-write failed", e);
        return false;
    }
    writeStr("[azinit] persistent mode: remounted / read-write\r\n");
    return true;
}

// --- writable paths on top of a read-only root ---
fn mountImmutableWritableOverlays() void {
    mountIgnoreBusy("tmpfs", "/var", "tmpfs", 0);
    mkdirIgnoreExists("/var/log");
    mkdirIgnoreExists("/var/cache");
    mkdirIgnoreExists("/var/lib");
    mkdirIgnoreExists("/var/tmp");
}

// /etc needs a handful of files written at runtime (resolv.conf, hostname,
// machine-id, ...) despite root staying read-only overall. Overlay a tmpfs
// upper layer on top of the existing (read-only) /etc content -- the
// standard pattern immutable-root distros use -- rather than punching a
// hole in the read-only design by making all of /etc a plain tmpfs (which
// would hide the real, pre-populated config files shipped by the image).
// Returns whether /etc ended up writable (the overlay filesystem isn't
// guaranteed to be built into every kernel).
var etc_writable: bool = false;

fn mountEtcOverlay() void {
    mkdirIgnoreExists("/run/etc-upper");
    mkdirIgnoreExists("/run/etc-work");
    const rc = linux.mount("overlay", "/etc", "overlay", 0, @intFromPtr("lowerdir=/etc,upperdir=/run/etc-upper,workdir=/run/etc-work"));
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        writeErrno("[azinit] /etc overlay mount failed", e);
        etc_writable = false;
    } else {
        etc_writable = true;
    }
}

// ============================== module autoload ==============================
// Loads a small, fixed set of kernel modules explicitly at boot. There is no
// udev/mdev daemon in this appliance to drive the kernel's usual
// uevent-triggered request_module() -> /sbin/modprobe autoload path (and no
// modprobe/kmod binary is shipped either) -- see zvmi issue #88: build-image
// used to drop /lib/modules entirely, and even after that's fixed, something
// still has to actually call insmod. Since the exact drivers this appliance
// needs are known ahead of time (Hyper-V networking, overlayfs for immutable
// mode, and the provisioning DVD's UDF/ISO9660 filesystems), loading them in
// dependency order with a raw init_module() syscall is simpler and more
// self-contained than shipping kmod: no MODALIAS matching and no extra
// shared-library dependencies (liblzma/libzstd/libcrypto) added to the image.

const max_module_file_size: usize = 4 * 1024 * 1024;

fn readWholeFileAlloc(gpa: std.mem.Allocator, path: [*:0]const u8) ?[]u8 {
    const fd_rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    const fd: i32 = @intCast(fd_rc);
    if (linux.errno(fd_rc) != .SUCCESS) return null;
    defer _ = linux.close(fd);

    const buf = gpa.alloc(u8, max_module_file_size) catch return null;
    var total: usize = 0;
    while (total < buf.len) {
        const n_rc = linux.read(fd, buf[total..].ptr, buf.len - total);
        const n: isize = @bitCast(n_rc);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return buf[0..total];
}

fn decompressXzAlloc(gpa: std.mem.Allocator, compressed: []const u8) ?[]u8 {
    var input = std.Io.Reader.fixed(compressed);
    var decompressor = std.compress.xz.Decompress.init(&input, gpa, &.{}) catch {
        return null;
    };
    defer decompressor.deinit();
    return decompressor.reader.allocRemaining(gpa, .limited(max_module_file_size * 8)) catch null;
}

// `rel_path` is relative to /lib/modules/<kernel-release>/, e.g.
// "kernel/drivers/net/hyperv/hv_netvsc.ko.xz".
fn loadModuleAt(gpa: std.mem.Allocator, release: []const u8, rel_path: []const u8) void {
    var path_buf: [256:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/lib/modules/{s}/{s}", .{ release, rel_path }) catch return;

    const compressed = readWholeFileAlloc(gpa, path) orelse {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[azinit] module {s} not found (non-fatal)\r\n", .{rel_path}) catch "[azinit] module not found\r\n";
        writeStr(msg);
        return;
    };
    defer gpa.free(compressed);

    const image = decompressXzAlloc(gpa, compressed) orelse {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[azinit] module {s} decompress failed (non-fatal)\r\n", .{rel_path}) catch "[azinit] module decompress failed\r\n";
        writeStr(msg);
        return;
    };
    defer gpa.free(image);

    const rc = linux.syscall3(.init_module, @intFromPtr(image.ptr), image.len, @intFromPtr(""));
    const e = linux.errno(rc);
    var buf: [160]u8 = undefined;
    if (e == .SUCCESS or e == .EXIST) {
        const msg = std.fmt.bufPrint(&buf, "[azinit] loaded module {s}\r\n", .{rel_path}) catch "[azinit] module loaded\r\n";
        writeStr(msg);
    } else {
        const msg = std.fmt.bufPrint(&buf, "[azinit] init_module {s} failed: errno={d}\r\n", .{ rel_path, @intFromEnum(e) }) catch "[azinit] init_module failed\r\n";
        writeStr(msg);
    }
}

fn loadBootModules(mode: BootMode) void {
    const gpa = std.heap.page_allocator;
    var uts: linux.utsname = undefined;
    if (linux.errno(linux.uname(&uts)) != .SUCCESS) {
        writeStr("[azinit] uname failed; skipping module autoload\r\n");
        return;
    }
    const release = std.mem.sliceTo(&uts.release, 0);

    if (mode == .immutable) {
        loadModuleAt(gpa, release, "kernel/fs/overlayfs/overlay.ko.xz");
    }
    loadModuleAt(gpa, release, "kernel/drivers/net/hyperv/hv_netvsc.ko.xz");
    loadModuleAt(gpa, release, "kernel/lib/crc/crc-itu-t.ko.xz");
    loadModuleAt(gpa, release, "kernel/fs/udf/udf.ko.xz");
    loadModuleAt(gpa, release, "kernel/fs/isofs/isofs.ko.xz");
}

// ============================== networking ==============================

// route.h flags; stable ABI, not exposed by std.os.linux.
const RTF_UP: u16 = 0x0001;
const RTF_GATEWAY: u16 = 0x0002;

// struct rtentry (linux/route.h); stable ABI, not exposed by std.os.linux.
const rtentry = extern struct {
    rt_pad1: usize = 0,
    rt_dst: linux.sockaddr = std.mem.zeroes(linux.sockaddr),
    rt_gateway: linux.sockaddr = std.mem.zeroes(linux.sockaddr),
    rt_genmask: linux.sockaddr = std.mem.zeroes(linux.sockaddr),
    rt_flags: u16 = 0,
    rt_pad2: i16 = 0,
    rt_pad3: usize = 0,
    rt_pad4: ?*anyopaque = null,
    rt_metric: i16 = 0,
    rt_dev: ?[*:0]const u8 = null,
    rt_mtu: usize = 0,
    rt_window: usize = 0,
    rt_irtt: u16 = 0,
};

fn ifUp(fd: i32, name: []const u8) void {
    var req: linux.ifreq = std.mem.zeroes(linux.ifreq);
    @memcpy(req.ifrn.name[0..name.len], name);

    _ = linux.ioctl(fd, linux.SIOCGIFFLAGS, @intFromPtr(&req));
    req.ifru.flags.UP = true;
    req.ifru.flags.RUNNING = true;
    _ = linux.ioctl(fd, linux.SIOCSIFFLAGS, @intFromPtr(&req));
}

fn sockaddrIn(addr_be: u32) linux.sockaddr {
    const in: linux.sockaddr.in = .{ .port = 0, .addr = addr_be };
    return @bitCast(in);
}

fn sockaddrInPort(addr_be: u32, port_be: u16) linux.sockaddr {
    const in: linux.sockaddr.in = .{ .port = port_be, .addr = addr_be };
    return @bitCast(in);
}

fn setIfaceAddr(fd: i32, name: []const u8, request: u32, addr_be: u32) void {
    var req: linux.ifreq = std.mem.zeroes(linux.ifreq);
    @memcpy(req.ifrn.name[0..name.len], name);
    req.ifru.addr = sockaddrIn(addr_be);
    _ = linux.ioctl(fd, request, @intFromPtr(&req));
}

fn findPrimaryInterface(buf: []u8) ?[]const u8 {
    const dir_fd_rc = linux.open("/sys/class/net", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    const dir_fd: i32 = @intCast(dir_fd_rc);
    if (linux.errno(dir_fd_rc) != .SUCCESS) return null;
    defer _ = linux.close(dir_fd);

    var dirent_buf: [2048]u8 align(8) = undefined;
    while (true) {
        const n_read_rc = linux.getdents64(dir_fd, &dirent_buf, dirent_buf.len);
        const n_read: isize = @bitCast(n_read_rc);
        if (n_read <= 0) break;
        var offset: usize = 0;
        while (offset < @as(usize, @intCast(n_read))) {
            const d: *align(1) linux.dirent64 = @ptrCast(&dirent_buf[offset]);
            const name_ptr: [*:0]const u8 = @ptrCast(&d.name);
            const name = std.mem.span(name_ptr);
            if (!std.mem.eql(u8, name, "lo") and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and name.len <= buf.len) {
                @memcpy(buf[0..name.len], name);
                return buf[0..name.len];
            }
            offset += d.reclen;
        }
    }
    return null;
}

const DhcpResult = struct {
    your_ip: u32, // network byte order
    subnet_mask: u32, // network byte order
    router: u32, // network byte order, 0 if absent
    dns: [2]u32, // network byte order, 0 if absent
};

const DHCP_MAGIC = [4]u8{ 0x63, 0x82, 0x53, 0x63 };

fn buildDhcpPacket(buf: []u8, xid: u32, mac: [6]u8, msg_type: u8, requested_ip: u32, server_ip: u32) usize {
    @memset(buf[0..240], 0);
    buf[0] = 1; // BOOTREQUEST
    buf[1] = 1; // htype ethernet
    buf[2] = 6; // hlen
    buf[3] = 0; // hops
    std.mem.writeInt(u32, buf[4..8], xid, .big);
    buf[10] = 0x80; // broadcast flag
    @memcpy(buf[28..34], &mac);
    @memcpy(buf[236..240], &DHCP_MAGIC);

    var pos: usize = 240;
    buf[pos] = 53;
    buf[pos + 1] = 1;
    buf[pos + 2] = msg_type;
    pos += 3;

    if (msg_type == 3) { // DHCPREQUEST: echo requested IP + server id
        buf[pos] = 50;
        buf[pos + 1] = 4;
        std.mem.writeInt(u32, buf[pos + 2 ..][0..4], requested_ip, .big);
        pos += 6;

        buf[pos] = 54;
        buf[pos + 1] = 4;
        std.mem.writeInt(u32, buf[pos + 2 ..][0..4], server_ip, .big);
        pos += 6;
    }

    buf[pos] = 55;
    buf[pos + 1] = 3;
    buf[pos + 2] = 1; // subnet mask
    buf[pos + 3] = 3; // router
    buf[pos + 4] = 6; // DNS
    pos += 5;

    buf[pos] = 255; // end
    pos += 1;
    return pos;
}

const ParsedReply = struct { msg_type: u8, your_ip: u32, server_ip: u32, router: u32, mask: u32, dns: [2]u32 };

fn parseDhcpReply(buf: []const u8, len: usize, expected_xid: u32) ?ParsedReply {
    if (len < 240) return null;
    if (buf[0] != 2) return null; // BOOTREPLY
    const xid = std.mem.readInt(u32, buf[4..8], .big);
    if (xid != expected_xid) return null;
    if (!std.mem.eql(u8, buf[236..240], &DHCP_MAGIC)) return null;

    const your_ip = std.mem.readInt(u32, buf[16..20], .big);
    var msg_type: u8 = 0;
    var server_ip: u32 = 0;
    var router: u32 = 0;
    var mask: u32 = 0;
    var dns: [2]u32 = .{ 0, 0 };

    var pos: usize = 240;
    while (pos < len) {
        const opt = buf[pos];
        if (opt == 255) break;
        if (opt == 0) {
            pos += 1;
            continue;
        }
        if (pos + 1 >= len) break;
        const opt_len = buf[pos + 1];
        const val_start = pos + 2;
        if (val_start + opt_len > len) break;
        switch (opt) {
            53 => if (opt_len >= 1) {
                msg_type = buf[val_start];
            },
            54 => if (opt_len >= 4) {
                server_ip = std.mem.readInt(u32, buf[val_start..][0..4], .big);
            },
            1 => if (opt_len >= 4) {
                mask = std.mem.readInt(u32, buf[val_start..][0..4], .big);
            },
            3 => if (opt_len >= 4) {
                router = std.mem.readInt(u32, buf[val_start..][0..4], .big);
            },
            6 => {
                if (opt_len >= 4) dns[0] = std.mem.readInt(u32, buf[val_start..][0..4], .big);
                if (opt_len >= 8) dns[1] = std.mem.readInt(u32, buf[val_start + 4 ..][0..4], .big);
            },
            else => {},
        }
        pos = val_start + opt_len;
    }
    return .{ .msg_type = msg_type, .your_ip = your_ip, .server_ip = server_ip, .router = router, .mask = mask, .dns = dns };
}

// --- raw packet socket receive path ---
// On Azure (unlike simpler local QEMU networking), DHCP replies sent to an
// interface that has no IP address configured yet get dropped by the
// kernel's normal IPv4 input path before they ever reach a recvfrom() on an
// AF_INET/SOCK_DGRAM socket: with no local route known for the interface,
// the reverse-path source check for the relay/server address fails and the
// packet is logged as "IPv4: martian source 255.255.255.255 from
// <relay-ip>, on dev ethN" and silently discarded. Real DHCP clients
// (dhclient/udhcpc/systemd-networkd) avoid this by receiving replies on a
// raw AF_PACKET socket bound to the interface, which taps the device's
// receive path *before* general IP routing/martian-source checks apply.
// Sending is unaffected (broadcast egress doesn't hit this check), so only
// the receive side needs to change.
const ETH_P_IP: u16 = 0x0800;

fn ifIndex(fd: i32, name: []const u8) ?i32 {
    var req: linux.ifreq = std.mem.zeroes(linux.ifreq);
    @memcpy(req.ifrn.name[0..name.len], name);
    const rc = linux.ioctl(fd, linux.SIOCGIFINDEX, @intFromPtr(&req));
    if (linux.errno(rc) != .SUCCESS) return null;
    return req.ifru.ivalue;
}

fn openRawIpRecvSocket(ctl_fd: i32, iface: []const u8) ?i32 {
    const index = ifIndex(ctl_fd, iface) orelse {
        writeStr("[azinit] dhcp: SIOCGIFINDEX failed\r\n");
        return null;
    };

    const sock_rc = linux.socket(linux.AF.PACKET, linux.SOCK.DGRAM, std.mem.nativeToBig(u16, ETH_P_IP));
    const sock: i32 = @intCast(sock_rc);
    if (linux.errno(sock_rc) != .SUCCESS) {
        writeErrno("[azinit] dhcp: AF_PACKET socket() failed", linux.errno(sock_rc));
        return null;
    }

    var addr: linux.sockaddr.ll = .{
        .protocol = std.mem.nativeToBig(u16, ETH_P_IP),
        .ifindex = index,
        .hatype = 0,
        .pkttype = 0,
        .halen = 0,
        .addr = std.mem.zeroes([8]u8),
    };
    const bind_rc = linux.bind(sock, @ptrCast(&addr), @sizeOf(linux.sockaddr.ll));
    if (linux.errno(bind_rc) != .SUCCESS) {
        writeErrno("[azinit] dhcp: AF_PACKET bind failed", linux.errno(bind_rc));
        _ = linux.close(sock);
        return null;
    }
    return sock;
}

/// Extracts the UDP payload from a raw IPv4 packet captured on an
/// AF_PACKET/SOCK_DGRAM socket (Ethernet header already stripped by the
/// kernel, IP header is not). Returns null unless it's a well-formed UDP
/// packet addressed to `dest_port`.
fn extractUdpPayload(packet: []const u8, dest_port: u16) ?[]const u8 {
    if (packet.len < 20) return null;
    if (packet[0] >> 4 != 4) return null; // IPv4 only
    const ihl: usize = @as(usize, packet[0] & 0x0f) * 4;
    if (ihl < 20 or packet.len < ihl + 8) return null;
    if (packet[9] != 17) return null; // protocol == UDP
    const udp = packet[ihl..];
    if (std.mem.readInt(u16, udp[2..4], .big) != dest_port) return null;
    const udp_len = std.mem.readInt(u16, udp[4..6], .big);
    if (udp_len < 8 or ihl + udp_len > packet.len) return null;
    return udp[8..udp_len];
}

fn runDhcp(iface: []const u8) ?DhcpResult {
    const ctl_fd_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    const ctl_fd: i32 = @intCast(ctl_fd_rc);
    if (linux.errno(ctl_fd_rc) != .SUCCESS) return null;
    defer _ = linux.close(ctl_fd);

    var hw_req: linux.ifreq = std.mem.zeroes(linux.ifreq);
    @memcpy(hw_req.ifrn.name[0..iface.len], iface);
    const hw_rc = linux.ioctl(ctl_fd, linux.SIOCGIFHWADDR, @intFromPtr(&hw_req));
    if (linux.errno(hw_rc) != .SUCCESS) writeErrno("[azinit] dhcp: SIOCGIFHWADDR failed", linux.errno(hw_rc));
    var mac: [6]u8 = undefined;
    @memcpy(&mac, hw_req.ifru.hwaddr.data[0..6]);
    {
        var mbuf: [64]u8 = undefined;
        const m = std.fmt.bufPrint(&mbuf, "[azinit] dhcp: mac={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\r\n", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] }) catch "[azinit] dhcp: mac read\r\n";
        writeStr(m);
    }

    ifUp(ctl_fd, iface);

    const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    const sock: i32 = @intCast(sock_rc);
    if (linux.errno(sock_rc) != .SUCCESS) {
        writeErrno("[azinit] dhcp: socket() failed", linux.errno(sock_rc));
        return null;
    }
    defer _ = linux.close(sock);

    var one: i32 = 1;
    _ = linux.setsockopt(sock, linux.SOL.SOCKET, linux.SO.BROADCAST, std.mem.asBytes(&one), @sizeOf(i32));
    const bindtodev_rc = linux.setsockopt(sock, linux.SOL.SOCKET, linux.SO.BINDTODEVICE, iface.ptr, @intCast(iface.len));
    if (linux.errno(bindtodev_rc) != .SUCCESS) writeErrno("[azinit] dhcp: SO_BINDTODEVICE failed", linux.errno(bindtodev_rc));

    const bind_addr = sockaddrInPort(0, std.mem.nativeToBig(u16, 68));
    const bind_rc = linux.bind(sock, &bind_addr, @sizeOf(linux.sockaddr));
    if (linux.errno(bind_rc) != .SUCCESS) {
        writeErrno("[azinit] dhcp bind failed", linux.errno(bind_rc));
        return null;
    }
    writeStr("[azinit] dhcp: bound to udp/68\r\n");

    var recv_sock = sock;
    var recv_is_raw = false;
    if (openRawIpRecvSocket(ctl_fd, iface)) |raw_sock| {
        recv_sock = raw_sock;
        recv_is_raw = true;
    } else {
        writeStr("[azinit] dhcp: falling back to udp recv (may miss replies on some networks)\r\n");
    }
    defer if (recv_is_raw) {
        _ = linux.close(recv_sock);
    };

    const dest_addr = sockaddrInPort(0xffffffff, std.mem.nativeToBig(u16, 67));

    var xid_buf: [4]u8 = undefined;
    _ = linux.getrandom(&xid_buf, xid_buf.len, 0);
    const xid = std.mem.readInt(u32, &xid_buf, .big);

    var packet: [512]u8 = undefined;
    var recv_buf: [1024]u8 = undefined;

    var send_len = buildDhcpPacket(&packet, xid, mac, 1, 0, 0);
    const send_rc = linux.sendto(sock, &packet, send_len, 0, &dest_addr, @sizeOf(linux.sockaddr));
    {
        var sbuf: [64]u8 = undefined;
        const smsg = std.fmt.bufPrint(&sbuf, "[azinit] dhcp: sent DISCOVER, sendto_rc={d}\r\n", .{send_rc}) catch "[azinit] dhcp: sent DISCOVER\r\n";
        writeStr(smsg);
    }

    var timeout: linux.timeval = .{ .sec = 5, .usec = 0 };
    _ = linux.setsockopt(recv_sock, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&timeout), @sizeOf(linux.timeval));

    var offer_ip: u32 = 0;
    var offer_server: u32 = 0;
    var got_offer = false;
    var attempt: u32 = 0;
    while (attempt < 3 and !got_offer) : (attempt += 1) {
        const n_rc = linux.recvfrom(recv_sock, &recv_buf, recv_buf.len, 0, null, null);
        const n_signed: isize = @bitCast(n_rc);
        {
            var rbuf: [80]u8 = undefined;
            const rmsg = std.fmt.bufPrint(&rbuf, "[azinit] dhcp: recvfrom attempt {d} -> {d}\r\n", .{ attempt, n_signed }) catch "[azinit] dhcp: recv attempt\r\n";
            writeStr(rmsg);
        }
        const payload: ?[]const u8 = if (n_signed <= 0)
            null
        else if (recv_is_raw)
            extractUdpPayload(recv_buf[0..@intCast(n_signed)], 68)
        else
            recv_buf[0..@intCast(n_signed)];
        if (payload) |data| {
            if (parseDhcpReply(data, data.len, xid)) |reply| {
                var pbuf: [64]u8 = undefined;
                const pmsg = std.fmt.bufPrint(&pbuf, "[azinit] dhcp: parsed reply msg_type={d}\r\n", .{reply.msg_type}) catch "[azinit] dhcp: parsed reply\r\n";
                writeStr(pmsg);
                if (reply.msg_type == 2) { // DHCPOFFER
                    offer_ip = reply.your_ip;
                    offer_server = reply.server_ip;
                    got_offer = true;
                }
            } else if (n_signed > 0) {
                writeStr("[azinit] dhcp: recv'd packet failed to parse (xid/magic mismatch?)\r\n");
            }
        } else {
            send_len = buildDhcpPacket(&packet, xid, mac, 1, 0, 0);
            _ = linux.sendto(sock, &packet, send_len, 0, &dest_addr, @sizeOf(linux.sockaddr));
        }
    }
    if (!got_offer) {
        writeStr("[azinit] dhcp: no offer received\r\n");
        return null;
    }

    send_len = buildDhcpPacket(&packet, xid, mac, 3, offer_ip, offer_server);
    _ = linux.sendto(sock, &packet, send_len, 0, &dest_addr, @sizeOf(linux.sockaddr));

    var got_ack: ?DhcpResult = null;
    attempt = 0;
    while (attempt < 3 and got_ack == null) : (attempt += 1) {
        const n_rc = linux.recvfrom(recv_sock, &recv_buf, recv_buf.len, 0, null, null);
        const n_signed: isize = @bitCast(n_rc);
        const payload: ?[]const u8 = if (n_signed <= 0)
            null
        else if (recv_is_raw)
            extractUdpPayload(recv_buf[0..@intCast(n_signed)], 68)
        else
            recv_buf[0..@intCast(n_signed)];
        if (payload) |data| {
            if (parseDhcpReply(data, data.len, xid)) |reply| {
                if (reply.msg_type == 5) { // DHCPACK
                    got_ack = DhcpResult{
                        .your_ip = std.mem.nativeToBig(u32, reply.your_ip),
                        .subnet_mask = if (reply.mask != 0) std.mem.nativeToBig(u32, reply.mask) else std.mem.nativeToBig(u32, 0xffffff00),
                        .router = std.mem.nativeToBig(u32, reply.router),
                        .dns = .{ std.mem.nativeToBig(u32, reply.dns[0]), std.mem.nativeToBig(u32, reply.dns[1]) },
                    };
                }
            }
        } else {
            send_len = buildDhcpPacket(&packet, xid, mac, 3, offer_ip, offer_server);
            _ = linux.sendto(sock, &packet, send_len, 0, &dest_addr, @sizeOf(linux.sockaddr));
        }
    }
    if (got_ack == null) writeStr("[azinit] dhcp: no ack received\r\n");
    return got_ack;
}

fn addDefaultRoute(iface: []const u8, gateway_be: u32) void {
    const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    const sock: i32 = @intCast(sock_rc);
    if (linux.errno(sock_rc) != .SUCCESS) return;
    defer _ = linux.close(sock);

    var iface_buf: [linux.IFNAMESIZE:0]u8 = std.mem.zeroes([linux.IFNAMESIZE:0]u8);
    @memcpy(iface_buf[0..iface.len], iface);

    var route: rtentry = .{
        .rt_dst = sockaddrIn(0),
        .rt_genmask = sockaddrIn(0),
        .rt_gateway = sockaddrIn(gateway_be),
        .rt_flags = RTF_UP | RTF_GATEWAY,
        .rt_dev = @ptrCast(&iface_buf),
    };

    const rc = linux.ioctl(sock, linux.SIOCADDRT, @intFromPtr(&route));
    const e = linux.errno(rc);
    if (e != .SUCCESS) writeErrno("[azinit] add default route failed", e);
}

fn writeResolvConf(dns: [2]u32) void {
    const path: [*:0]const u8 = if (etc_writable) "/etc/resolv.conf" else "/run/resolv.conf";
    const fd_rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    const fd: i32 = @intCast(fd_rc);
    if (linux.errno(fd_rc) != .SUCCESS) {
        writeErrno("[azinit] writing resolv.conf failed", linux.errno(fd_rc));
        return;
    }
    defer _ = linux.close(fd);
    if (!etc_writable) writeStr("[azinit] /etc not writable (no overlayfs); wrote /run/resolv.conf instead\r\n");

    var buf: [128]u8 = undefined;
    for (dns) |d| {
        if (d == 0) continue;
        const be_bytes = std.mem.asBytes(&d);
        const line = std.fmt.bufPrint(&buf, "nameserver {d}.{d}.{d}.{d}\n", .{ be_bytes[0], be_bytes[1], be_bytes[2], be_bytes[3] }) catch continue;
        _ = linux.write(fd, line.ptr, line.len);
    }
}

fn setupNetworking() void {
    const lo_sock_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    const lo_sock: i32 = @intCast(lo_sock_rc);
    if (linux.errno(lo_sock_rc) == .SUCCESS) {
        ifUp(lo_sock, "lo");
        _ = linux.close(lo_sock);
    }

    var iface_buf: [linux.IFNAMESIZE]u8 = undefined;
    const iface = findPrimaryInterface(&iface_buf) orelse {
        writeStr("[azinit] no non-lo network interface found\r\n");
        return;
    };
    var msg_buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "[azinit] running DHCP on {s}\r\n", .{iface}) catch "[azinit] running DHCP\r\n";
    writeStr(msg);

    const lease = runDhcp(iface) orelse return;

    const ctl_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    const ctl: i32 = @intCast(ctl_rc);
    if (linux.errno(ctl_rc) != .SUCCESS) return;
    defer _ = linux.close(ctl);

    setIfaceAddr(ctl, iface, linux.SIOCSIFADDR, lease.your_ip);
    setIfaceAddr(ctl, iface, linux.SIOCSIFNETMASK, lease.subnet_mask);
    ifUp(ctl, iface);

    if (lease.router != 0) addDefaultRoute(iface, lease.router);
    writeResolvConf(lease.dns);

    const ip_bytes = std.mem.asBytes(&lease.your_ip);
    var ok_buf: [96]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "[azinit] {s} configured: {d}.{d}.{d}.{d}\r\n", .{ iface, ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3] }) catch "[azinit] network configured\r\n";
    writeStr(ok_msg);
}

// ============================== azagent invocation ==============================
// If /usr/sbin/azagent exists (added via an extra container layer -- see
// zvmi build-image's automatic systemd-unit wiring for the full-image
// equivalent, and the root README's build-image section), fork+exec it
// once so this from-scratch init supports first-boot Azure provisioning
// too, serving as a reference for what any --skip-iso-rootfs init needs
// to do to actually reach a usable, provisioned login.
const azagent_path = "/usr/sbin/azagent";

const AzagentResult = enum {
    absent,
    success,
    failed,
};

fn runAzagentIfPresent() AzagentResult {
    const access_rc = linux.access(azagent_path, linux.F_OK);
    if (linux.errno(access_rc) != .SUCCESS) return .absent;

    writeStr("[azinit] running azagent...\r\n");

    const pid = forkProcess("[azinit] fork() for azagent failed") orelse return .failed;
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ azagent_path, null };
        const envp = [_:null]?[*:0]const u8{
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            null,
        };
        _ = linux.execve(azagent_path, &argv, &envp);
        writeStr("[azinit] execve(azagent) failed\r\n");
        linux.exit(127);
    }
    var status: u32 = 0;
    while (true) {
        const wait_rc = linux.waitpid(pid, &status, 0);
        const wait_error = linux.errno(wait_rc);
        if (wait_error == .INTR) continue;
        if (wait_error != .SUCCESS) {
            writeErrno("[azinit] waitpid() for azagent failed", wait_error);
            return .failed;
        }
        break;
    }
    if (linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0) {
        writeStr("[azinit] azagent completed successfully\r\n");
        return .success;
    } else {
        writeStr("[azinit] azagent exited non-zero\r\n");
        return .failed;
    }
}

// ============================== sshd invocation ==============================
// If /usr/sbin/sshd exists (added via an extra container layer), fork+exec
// it once networking and azagent's SSH host keys / authorized_keys
// deployment are in place, so a --skip-iso-rootfs image can actually be
// reached over SSH -- otherwise a "successfully provisioned" minimal
// container has no way to be reached at all (see issue #129). Called after
// runAzagentIfPresent() so host keys already exist by the time sshd
// starts. Tolerant of sshd being entirely absent (most azinit-based test
// images, including the boot-smoke QEMU tests, won't have it).
//
// Unlike azagent (a run-once step we wait for), sshd daemonizes itself and
// runs forever, so we must not block on it here: fork+exec it and return
// immediately, continuing on into shellLoop(). shellLoop()'s existing
// waitpid(-1, ...) reaping loop already tolerates other children coming
// and going (it only breaks when the *shell's* pid exits or waitpid
// errors), so it transparently reaps the transient first-generation sshd
// process once it exits after daemonizing -- no changes needed there.
const sshd_path = "/usr/sbin/sshd";

fn runSshdIfPresent() void {
    const access_rc = linux.access(sshd_path, linux.F_OK);
    if (linux.errno(access_rc) != .SUCCESS) return;

    // sshd's privilege-separation directory; some builds expect it to
    // already exist rather than creating it themselves.
    mkdirIgnoreExists("/run/sshd");

    writeStr("[azinit] running sshd...\r\n");

    const pid = forkProcess("[azinit] fork() for sshd failed") orelse return;
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ sshd_path, null };
        const envp = [_:null]?[*:0]const u8{
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            null,
        };
        _ = linux.execve(sshd_path, &argv, &envp);
        writeStr("[azinit] execve(sshd) failed\r\n");
        linux.exit(127);
    }
    // Do not waitpid here -- sshd daemonizes and runs forever; shellLoop's
    // reaping loop handles it (and any of its descendants) from here on.
}

const provisioning_retry_seconds = 5;

fn startPersistentProvisioning() void {
    if (linux.errno(linux.access(azagent_path, linux.F_OK)) != .SUCCESS) {
        writeStr("[azinit] persistent mode requires /usr/sbin/azagent; SSH will not start\r\n");
        return;
    }

    const supervisor_pid = forkProcess("[azinit] fork() for provisioning supervisor failed") orelse {
        writeStr("[azinit] SSH will not start\r\n");
        return;
    };
    if (supervisor_pid == 0) {
        while (true) {
            switch (runAzagentIfPresent()) {
                .success => {
                    runSshdIfPresent();
                    linux.exit(0);
                },
                .absent => {
                    writeStr("[azinit] azagent disappeared; SSH will not start\r\n");
                    linux.exit(1);
                },
                .failed => {
                    writeStr("[azinit] retrying azagent in 5 seconds\r\n");
                    const req: linux.timespec = .{ .sec = provisioning_retry_seconds, .nsec = 0 };
                    _ = linux.nanosleep(&req, null);
                },
            }
        }
    }
}

// ============================== main loop ==============================

fn shellLoop() noreturn {
    while (true) {
        if (shutdown_requested) doReboot(.POWER_OFF);

        const tty_fd_raw = linux.open("/dev/ttyS0", .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(tty_fd_raw) != .SUCCESS) {
            writeStr("[azinit] failed to open /dev/ttyS0, retrying in 1s\r\n");
            const req: linux.timespec = .{ .sec = 1, .nsec = 0 };
            _ = linux.nanosleep(&req, null);
            continue;
        }
        const tty_fd: i32 = @intCast(tty_fd_raw);

        _ = linux.setsid();
        _ = linux.ioctl(tty_fd, linux.T.IOCSCTTY, 0);

        const pid = forkProcess("[azinit] fork() for shell failed") orelse {
            _ = linux.close(tty_fd);
            const req: linux.timespec = .{ .sec = 1, .nsec = 0 };
            _ = linux.nanosleep(&req, null);
            continue;
        };
        if (pid == 0) {
            _ = linux.dup2(tty_fd, 0);
            _ = linux.dup2(tty_fd, 1);
            _ = linux.dup2(tty_fd, 2);
            if (tty_fd > 2) _ = linux.close(tty_fd);

            const argv = [_:null]?[*:0]const u8{ "/usr/bin/bash", "--login", null };
            const envp = [_:null]?[*:0]const u8{
                "HOME=/root",
                "TERM=linux",
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                null,
            };
            _ = linux.execve("/usr/bin/bash", &argv, &envp);
            writeStr("[azinit] execve(/usr/bin/bash) failed\r\n");
            linux.exit(127);
        }

        _ = linux.close(tty_fd);

        while (true) {
            if (shutdown_requested) break;
            var status: u32 = 0;
            const wait_rc = linux.waitpid(-1, &status, 0);
            const wait_error = linux.errno(wait_rc);
            if (wait_error == .INTR) continue;
            if (wait_error != .SUCCESS) break;
            const wpid: linux.pid_t = @intCast(wait_rc);
            if (wpid == pid) break;
        }

        if (shutdown_requested) doReboot(.POWER_OFF);
        writeStr("\r\n[azinit] shell exited, respawning...\r\n");
    }
}

pub fn main(init: std.process.Init.Minimal) noreturn {
    const argv0 = if (init.args.vector.len > 0) std.mem.span(init.args.vector[0]) else "";
    if (std.mem.endsWith(u8, argv0, "poweroff") or std.mem.endsWith(u8, argv0, "shutdown")) {
        doReboot(.POWER_OFF);
    }
    if (std.mem.endsWith(u8, argv0, "reboot")) {
        doReboot(.RESTART);
    }

    installShutdownHandlers();

    mountIgnoreBusy("proc", "/proc", "proc", 0);
    mountIgnoreBusy("sysfs", "/sys", "sysfs", 0);
    mountIgnoreBusy("devtmpfs", "/dev", "devtmpfs", 0);
    mountIgnoreBusy("tmpfs", "/run", "tmpfs", 0);
    openDebugLog();
    const boot_mode = readBootMode();
    const persistent_root_ready = if (boot_mode == .persistent) remountRootWritable() else false;
    loadBootModules(boot_mode);
    mountIgnoreBusy("tmpfs", "/tmp", "tmpfs", 0);
    if (boot_mode == .immutable) {
        mountImmutableWritableOverlays();
        mountEtcOverlay();
    } else {
        etc_writable = persistent_root_ready;
    }
    tryMountEsp();
    setHostname(boot_mode, persistent_root_ready);
    ensureMachineId();

    writeStr("\r\n[azinit] base mounts ready; configuring network...\r\n");
    setupNetworking();

    if (boot_mode == .persistent) {
        if (persistent_root_ready) {
            startPersistentProvisioning();
        } else {
            writeStr("[azinit] persistent storage is unavailable; azagent and SSH will not start\r\n");
        }
    } else {
        _ = runAzagentIfPresent();
        runSshdIfPresent();
    }

    writeStr("[azinit] spawning shell on ttyS0\r\n");
    shellLoop();
}

test "parseBootMode defaults to immutable" {
    try std.testing.expectEqual(BootMode.immutable, parseBootMode("root=/dev/sda2 console=ttyS0").mode);
}

test "parseBootMode accepts persistent and explicit immutable modes" {
    try std.testing.expectEqual(BootMode.persistent, parseBootMode("root=/dev/sda2 azinit.mode=persistent console=ttyS0").mode);
    try std.testing.expectEqual(BootMode.immutable, parseBootMode("azinit.mode=immutable").mode);
}

test "parseBootMode uses the last azinit mode" {
    const config = parseBootMode("azinit.mode=persistent azinit.mode=immutable");
    try std.testing.expectEqual(BootMode.immutable, config.mode);
    try std.testing.expectEqual(@as(?[]const u8, null), config.invalid_value);
}

test "parseBootMode allows a later valid mode to replace an invalid one" {
    const config = parseBootMode("azinit.mode=invalid azinit.mode=persistent");
    try std.testing.expectEqual(BootMode.persistent, config.mode);
    try std.testing.expectEqual(@as(?[]const u8, null), config.invalid_value);
}

test "parseBootMode rejects an invalid mode" {
    const config = parseBootMode("azinit.mode=writable");
    try std.testing.expectEqual(BootMode.immutable, config.mode);
    try std.testing.expectEqualStrings("writable", config.invalid_value.?);
}

test "parsePersistedHostname trims line endings and rejects invalid content" {
    try std.testing.expectEqualStrings("generalized-vm", parsePersistedHostname("generalized-vm\n").?);
    try std.testing.expectEqual(@as(?[]const u8, null), parsePersistedHostname(" \r\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), parsePersistedHostname("invalid\x00hostname"));

    const too_long = "a" ** (linux.HOST_NAME_MAX + 1);
    try std.testing.expectEqual(@as(?[]const u8, null), parsePersistedHostname(too_long));
}

test "machine-id validation accepts lowercase 128-bit hex only" {
    try std.testing.expect(isValidMachineId("0123456789abcdef0123456789abcdef\n"));
    try std.testing.expect(!isValidMachineId(""));
    try std.testing.expect(!isValidMachineId("0123456789ABCDEF0123456789ABCDEF\n"));
    try std.testing.expect(!isValidMachineId("0123456789abcdef0123456789abcdeg\n"));
}

test "formatMachineId emits lowercase hex and a newline" {
    try std.testing.expectEqualStrings(
        "000102030405060708090a0b0c0d0e0f\n",
        &formatMachineId(.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }),
    );
}
