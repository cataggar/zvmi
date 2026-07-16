//! Prepare the verified FreeBSD 15.1 AArch64 cloud-image base used by the
//! generalized QEMU/Azure builder. This initial stage acquires, decompresses,
//! validates, and transactionally recompresses the official standalone QCOW2.

const std = @import("std");
const zvmi = @import("zvmi");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;
const artifact_pipeline = zvmi.artifact_pipeline;

const source_name = "FreeBSD-15.1-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2.xz";
const source_url = "https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/aarch64/Latest/" ++ source_name;
const official_source_sha256 = "9722aea499610802de9a14bb645707fc4f6df49ff765cd9ce372b783c4693963";
const source_max_size: u64 = 2 * 1024 * 1024 * 1024;
const image_max_size: u64 = 6 * 1024 * 1024 * 1024;
const official_virtual_size: u64 = 6_477_643_776;
const finalized_image_max_size: u64 = 7 * 1024 * 1024 * 1024;
const xz_memory_limit: u64 = 1024 * 1024 * 1024;

const Args = struct {
    source: ?[]const u8 = null,
    source_sha256: []const u8 = official_source_sha256,
    output: []const u8 = "zvmi-freebsd15.1-aarch64-base.qcow2",
    work_dir: []const u8 = ".scratch/generalized-freebsd15-aarch64",
    curl_path: []const u8 = "curl",
    xz_path: []const u8 = "xz",
    qemu_img_path: []const u8 = "qemu-img",
};

const help_text =
    \\Usage: build_generalized_freebsd15_aarch64 [options]
    \\
    \\  --source <path>          Local .qcow2.xz source (official image if omitted)
    \\  --source-sha256 <hex>    Expected compressed source SHA-256
    \\  --output <path>          Output QCOW2
    \\  --work-dir <dir>         Download/decompression cache directory
    \\  --curl <path>            curl executable (default: curl)
    \\  --xz <path>              XZ Utils executable (default: xz)
    \\  --qemu-img <path>        qemu-img executable (default: qemu-img)
    \\
    \\Preferred invocation: zig build generalized-freebsd15-aarch64 -- [options]
    \\
;

fn parseArgs(argv: []const []const u8) !Args {
    var args = Args{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--source")) {
            args.source = try nextValue(argv, &i);
        } else if (std.mem.eql(u8, arg, "--source-sha256")) {
            args.source_sha256 = try nextValue(argv, &i);
        } else if (std.mem.eql(u8, arg, "--output")) {
            args.output = try nextValue(argv, &i);
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            args.work_dir = try nextValue(argv, &i);
        } else if (std.mem.eql(u8, arg, "--curl")) {
            args.curl_path = try nextValue(argv, &i);
        } else if (std.mem.eql(u8, arg, "--xz")) {
            args.xz_path = try nextValue(argv, &i);
        } else if (std.mem.eql(u8, arg, "--qemu-img")) {
            args.qemu_img_path = try nextValue(argv, &i);
        } else if (std.mem.eql(u8, arg, "--help") or
            std.mem.eql(u8, arg, "-h"))
        {
            std.debug.print("{s}", .{help_text});
            std.process.exit(0);
        } else {
            return error.UnexpectedArgument;
        }
    }
    return args;
}

fn nextValue(argv: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= argv.len) return error.MissingValue;
    return argv[index.*];
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = parseArgs(argv[1..]) catch |err| {
        std.debug.print("error: {s}\n{s}", .{ @errorName(err), help_text });
        std.process.exit(1);
    };
    const expected_source = artifact_pipeline.parseSha256(
        args.source_sha256,
    ) catch {
        std.debug.print("error: invalid --source-sha256\n", .{});
        std.process.exit(1);
    };

    try Dir.cwd().createDirPath(io, args.work_dir);
    if (std.fs.path.dirname(args.output)) |parent| {
        try Dir.cwd().createDirPath(io, parent);
    }

    const cached_source = try std.fs.path.join(
        allocator,
        &.{ args.work_dir, source_name },
    );
    defer allocator.free(cached_source);
    const compressed_source = if (args.source) |path| path else blk: {
        var curl = artifact_pipeline.CurlDownloader{
            .executable_path = args.curl_path,
        };
        const acquired = try artifact_pipeline.acquireVerified(
            allocator,
            io,
            .{
                .url = source_url,
                .destination_path = cached_source,
                .expected_sha256 = expected_source,
                .max_size = source_max_size,
            },
            curl.downloader(),
        );
        std.debug.print(
            "{s} compressed source: {s}\n",
            .{
                if (acquired.reused_cache) "Using cached" else "Downloaded",
                acquired.artifact.path,
            },
        );
        break :blk cached_source;
    };

    const decompressed_path = try std.fs.path.join(
        allocator,
        &.{
            args.work_dir,
            "FreeBSD-15.1-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2",
        },
    );
    defer allocator.free(decompressed_path);
    std.debug.print("Decompressing and validating FreeBSD source...\n", .{});
    const decompressed = try artifact_pipeline.decompressXz(
        allocator,
        io,
        .{
            .input_path = compressed_source,
            .expected_input_sha256 = expected_source,
            .output_path = decompressed_path,
            .max_output_size = image_max_size,
            .max_memory_size = xz_memory_limit,
            .xz_path = args.xz_path,
        },
    );

    std.debug.print("Finalizing standalone zstd QCOW2...\n", .{});
    const finalized = try artifact_pipeline.finalizeQcow2(
        allocator,
        io,
        .{
            .input_path = decompressed.path,
            .expected_input_sha256 = decompressed.sha256,
            .max_input_size = image_max_size,
            .source_format = .qcow2,
            .expected_virtual_size = official_virtual_size,
            .max_virtual_size = official_virtual_size,
            .output_path = args.output,
            .max_output_size = finalized_image_max_size,
            .qemu_img_path = args.qemu_img_path,
            .compression = .zstd,
        },
    );
    const finalized_sha256 = artifact_pipeline.formatSha256(
        finalized.artifact.sha256,
    );
    std.debug.print(
        "Built {s} ({d} bytes, virtual size {d}, SHA-256 {s})\n",
        .{
            finalized.artifact.path,
            finalized.artifact.size,
            finalized.virtual_size,
            &finalized_sha256,
        },
    );
}

test "FreeBSD builder defaults pin the official release source" {
    const args = try parseArgs(&.{});
    try std.testing.expect(args.source == null);
    try std.testing.expectEqualStrings(official_source_sha256, args.source_sha256);
    try std.testing.expectEqualStrings("curl", args.curl_path);
    try std.testing.expectEqualStrings("xz", args.xz_path);
    try std.testing.expectEqualStrings("qemu-img", args.qemu_img_path);
    _ = try artifact_pipeline.parseSha256(args.source_sha256);
}

test "FreeBSD builder parses explicit source and tool paths" {
    const args = try parseArgs(&.{
        "--source",
        "base.qcow2.xz",
        "--source-sha256",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "--output",
        "out.qcow2",
        "--work-dir",
        "work",
        "--curl",
        "/tools/curl",
        "--xz",
        "/tools/xz",
        "--qemu-img",
        "/tools/qemu-img",
    });
    try std.testing.expectEqualStrings("base.qcow2.xz", args.source.?);
    try std.testing.expectEqualStrings("out.qcow2", args.output);
    try std.testing.expectEqualStrings("work", args.work_dir);
    try std.testing.expectEqualStrings("/tools/curl", args.curl_path);
    try std.testing.expectEqualStrings("/tools/xz", args.xz_path);
    try std.testing.expectEqualStrings("/tools/qemu-img", args.qemu_img_path);
}

test "FreeBSD builder rejects malformed arguments" {
    try std.testing.expectError(
        error.MissingValue,
        parseArgs(&.{"--source"}),
    );
    try std.testing.expectError(
        error.UnexpectedArgument,
        parseArgs(&.{"--unknown"}),
    );
}
