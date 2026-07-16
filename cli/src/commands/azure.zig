//! `zvmi azure derive --input-sha256 <hex> <input.qcow2> <output.vhd>`
//! `zvmi azure fixup --generation 1|2 <file>`
//! `zvmi azure deprovision [--user <username>] <file>`

const std = @import("std");
const zvmi = @import("zvmi");

pub fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    if (args.len < 1) return fail(usage, .{});
    if (std.mem.eql(u8, args[0], "derive")) return runDerive(gpa, io, args[1..]);
    if (std.mem.eql(u8, args[0], "fixup")) return runFixup(gpa, io, args[1..]);
    if (std.mem.eql(u8, args[0], "deprovision")) return runDeprovision(gpa, io, args[1..]);
    return fail(usage, .{});
}

const usage = "usage: zvmi azure derive --input-sha256 <hex> [--expected-virtual-size <size>] [--max-input-size <size>] [--max-virtual-size <size>] [--max-output-size <size>] <input.qcow2> <output.vhd>\n" ++
    "       zvmi azure fixup --generation 1|2 <file>\n" ++
    "       zvmi azure deprovision [--user <username>] <file>";

fn runDerive(gpa: std.mem.Allocator, io: std.Io, rest: []const []const u8) u8 {
    var input_sha256: ?zvmi.artifact_pipeline.Digest = null;
    var expected_virtual_size: ?u64 = null;
    var max_input_size: u64 = 64 * 1024 * 1024 * 1024;
    var max_virtual_size: u64 = 64 * 1024 * 1024 * 1024;
    var max_output_size: u64 = 64 * 1024 * 1024 * 1024 + 512;
    var positional: [2][]const u8 = undefined;
    var positional_count: usize = 0;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const argument = rest[i];
        if (std.mem.eql(u8, argument, "--input-sha256")) {
            i += 1;
            if (i >= rest.len) {
                return fail("azure derive: --input-sha256 requires an argument", .{});
            }
            input_sha256 = zvmi.artifact_pipeline.parseSha256(rest[i]) catch
                return fail("azure derive: invalid SHA-256 '{s}'", .{rest[i]});
        } else if (std.mem.eql(u8, argument, "--expected-virtual-size")) {
            i += 1;
            expected_virtual_size = parseSizeArgument(rest, i, argument) orelse
                return 1;
        } else if (std.mem.eql(u8, argument, "--max-input-size")) {
            i += 1;
            max_input_size = parseSizeArgument(rest, i, argument) orelse
                return 1;
        } else if (std.mem.eql(u8, argument, "--max-virtual-size")) {
            i += 1;
            max_virtual_size = parseSizeArgument(rest, i, argument) orelse
                return 1;
        } else if (std.mem.eql(u8, argument, "--max-output-size")) {
            i += 1;
            max_output_size = parseSizeArgument(rest, i, argument) orelse
                return 1;
        } else if (positional_count < positional.len) {
            positional[positional_count] = argument;
            positional_count += 1;
        } else {
            return fail("azure derive: unexpected argument '{s}'", .{argument});
        }
    }
    const digest = input_sha256 orelse
        return fail("azure derive: --input-sha256 <hex> is required", .{});
    if (positional_count != positional.len) return fail(usage, .{});

    const result = zvmi.azure.deriveFixedVhd(
        gpa,
        io,
        .{
            .input_path = positional[0],
            .expected_input_sha256 = digest,
            .max_input_size = max_input_size,
            .expected_virtual_size = expected_virtual_size,
            .max_virtual_size = max_virtual_size,
            .output_path = positional[1],
            .max_output_size = max_output_size,
        },
    ) catch |err| return fail("azure derive: failed: {s}", .{@errorName(err)});

    const output_sha256 =
        zvmi.artifact_pipeline.formatSha256(result.artifact.sha256);
    std.debug.print(
        "Derived fixed VHD '{s}': data size {d} -> {d} bytes, file size {d} bytes, {d} partitions, backup GPT LBA {d} -> {d}, SHA-256 {s}\n",
        .{
            positional[1],
            result.source_virtual_size,
            result.virtual_size,
            result.artifact.size,
            result.partition_count,
            result.relocation.old_backup_lba,
            result.relocation.new_backup_lba,
            &output_sha256,
        },
    );
    return 0;
}

fn parseSizeArgument(
    args: []const []const u8,
    index: usize,
    option: []const u8,
) ?u64 {
    if (index >= args.len) {
        _ = fail("azure derive: {s} requires an argument", .{option});
        return null;
    }
    return zvmi.parseSize(args[index]) catch {
        _ = fail(
            "azure derive: invalid size '{s}' for {s}",
            .{ args[index], option },
        );
        return null;
    };
}

fn runFixup(gpa: std.mem.Allocator, io: std.Io, rest: []const []const u8) u8 {
    var generation: ?zvmi.azure.Generation = null;
    var path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--generation")) {
            i += 1;
            if (i >= rest.len) return fail("azure fixup: --generation requires an argument (1 or 2)", .{});
            if (std.mem.eql(u8, rest[i], "1")) {
                generation = .gen1;
            } else if (std.mem.eql(u8, rest[i], "2")) {
                generation = .gen2;
            } else {
                return fail("azure fixup: invalid --generation '{s}' (expected 1 or 2)", .{rest[i]});
            }
        } else if (path == null) {
            path = a;
        } else {
            return fail("azure fixup: unexpected argument '{s}'", .{a});
        }
    }

    const gen = generation orelse return fail("azure fixup: --generation 1|2 is required", .{});
    const file_path = path orelse return fail("usage: zvmi azure fixup --generation 1|2 <file>", .{});

    var img = zvmi.Image.openPath(io, file_path) catch |err|
        return fail("azure fixup: failed to open '{s}': {s}", .{ file_path, @errorName(err) });
    defer img.close(io);

    const report = zvmi.azure.checkPartitionStyle(img, io, gpa, gen) catch |err|
        return fail("azure fixup: failed to check partition style: {s}", .{@errorName(err)});
    const gen_name: []const u8 = if (gen == .gen1) "Gen1" else "Gen2";
    if (!report.ok) {
        std.debug.print("Partition style check FAILED for {s}: {s}\n", .{ gen_name, report.message });
        return 2;
    }

    const align_result = zvmi.azure.alignFixedVhd(&img, io) catch |err| {
        if (err == error.GptRelocationRequired) {
            return fail(
                "azure fixup: GPT growth requires transactional relocation; use 'zvmi azure derive --input-sha256 <hex> <input.qcow2> <output.vhd>'",
                .{},
            );
        }
        return fail(
            "azure fixup: {s} (Azure managed-disk upload requires a *fixed* .vhd; convert first with " ++
                "'zvmi convert -O vhd -o subformat=fixed <src> {s}')",
            .{ @errorName(err), file_path },
        );
    };
    if (align_result.was_resized) {
        std.debug.print("Padded virtual size from {d} to {d} bytes (1 MiB alignment).\n", .{ align_result.old_size, align_result.new_size });
    } else {
        std.debug.print("Virtual size {d} bytes is already 1 MiB-aligned.\n", .{align_result.new_size});
    }

    std.debug.print("Partition style OK for {s}: {s}\n", .{ gen_name, report.message });
    return 0;
}

fn runDeprovision(gpa: std.mem.Allocator, io: std.Io, rest: []const []const u8) u8 {
    var username: ?[]const u8 = null;
    var path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--user")) {
            i += 1;
            if (i >= rest.len) return fail("azure deprovision: --user requires an argument", .{});
            username = rest[i];
        } else if (path == null) {
            path = a;
        } else {
            return fail("azure deprovision: unexpected argument '{s}'", .{a});
        }
    }

    const file_path = path orelse return fail("usage: zvmi azure deprovision [--user <username>] <file>", .{});

    var img = zvmi.Image.openPath(io, file_path) catch |err|
        return fail("azure deprovision: failed to open '{s}': {s}", .{ file_path, @errorName(err) });
    defer img.close(io);

    const offset = zvmi.deprovision.findRootExt4Offset(gpa, img, io) catch |err|
        return fail("azure deprovision: failed to locate the root ext4 filesystem: {s}", .{@errorName(err)});

    zvmi.deprovision.deprovision(gpa, img, io, offset, .{ .username = username }) catch |err|
        return fail("azure deprovision: failed: {s}", .{@errorName(err)});

    if (username) |u| {
        std.debug.print("Deprovisioned '{s}' (hostname reset, SSH host keys/machine-id/DHCP state cleared, user '{s}' removed).\n", .{ file_path, u });
    } else {
        std.debug.print("Deprovisioned '{s}' (hostname reset, SSH host keys/machine-id/DHCP state cleared).\n", .{file_path});
    }
    return 0;
}

fn fail(comptime format: []const u8, args: anytype) u8 {
    std.debug.print(format ++ "\n", args);
    return 1;
}
