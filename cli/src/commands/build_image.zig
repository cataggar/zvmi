//! `zvmi build-image --iso <file.iso> --container <oci-layout> --generation 1|2 --size <size> -o <output.{raw|vhd}>`

const std = @import("std");
const zvmi = @import("zvmi");

pub fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    var iso_path: ?[]const u8 = null;
    var container_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var output_format: ?zvmi.Format = null;
    var rootfs_path: ?[]const u8 = null;
    var generation: zvmi.azure.Generation = .gen2;
    var size: ?u64 = null;
    var esp_size: ?u64 = null;
    var dry_run = false;
    var verbose = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--iso")) {
            i += 1;
            if (i >= args.len) return fail("build-image: --iso requires a path", .{});
            iso_path = args[i];
        } else if (std.mem.eql(u8, arg, "--container")) {
            i += 1;
            if (i >= args.len) return fail("build-image: --container requires a path", .{});
            container_path = args[i];
        } else if (std.mem.eql(u8, arg, "--generation")) {
            i += 1;
            if (i >= args.len) return fail("build-image: --generation requires 1 or 2", .{});
            if (std.mem.eql(u8, args[i], "1") or std.mem.eql(u8, args[i], "gen1")) {
                generation = .gen1;
            } else if (std.mem.eql(u8, args[i], "2") or std.mem.eql(u8, args[i], "gen2")) {
                generation = .gen2;
            } else {
                return fail("build-image: invalid --generation '{s}' (expected 1 or 2)", .{args[i]});
            }
        } else if (std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i >= args.len) return fail("build-image: --size requires a value", .{});
            size = zvmi.parseSize(args[i]) catch |err|
                return fail("build-image: invalid --size '{s}': {s}", .{ args[i], @errorName(err) });
        } else if (std.mem.eql(u8, arg, "--esp-size")) {
            i += 1;
            if (i >= args.len) return fail("build-image: --esp-size requires a value", .{});
            esp_size = zvmi.parseSize(args[i]) catch |err|
                return fail("build-image: invalid --esp-size '{s}': {s}", .{ args[i], @errorName(err) });
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return fail("build-image: -o/--output requires a path", .{});
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "-O")) {
            i += 1;
            if (i >= args.len) return fail("build-image: -O requires a format", .{});
            output_format = zvmi.Format.parseName(args[i]) orelse
                return fail("build-image: unknown output format '{s}'", .{args[i]});
        } else if (std.mem.eql(u8, arg, "--rootfs-path")) {
            i += 1;
            if (i >= args.len) return fail("build-image: --rootfs-path requires a path", .{});
            rootfs_path = args[i];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return fail("usage: zvmi build-image --iso <file.iso> --container <oci-layout> --generation 1|2 --size <size> -o <output.{{raw|vhd}}> [-O raw|vhd] [--rootfs-path <path>] [--esp-size <size>] [--dry-run] [-v]", .{});
        } else {
            return fail("build-image: unexpected argument '{s}'", .{arg});
        }
    }

    var report = blk: {
        const built = zvmi.build_image.build(gpa, io, .{
            .iso_path = iso_path orelse return fail("build-image: --iso is required", .{}),
            .container_path = container_path orelse return fail("build-image: --container is required", .{}),
            .output_path = output_path orelse return fail("build-image: -o/--output is required", .{}),
            .size = size orelse return fail("build-image: --size is required", .{}),
            .generation = generation,
            .output_format = output_format,
            .rootfs_path_in_iso = rootfs_path,
            .esp_size = esp_size orelse zvmi.build_image.default_esp_size,
            .dry_run = dry_run,
            .verbose = verbose,
        }) catch |err| return fail("build-image: failed: {s}", .{@errorName(err)});
        break :blk built;
    };
    defer report.deinit(gpa);

    printReport(report, dry_run);
    return 0;
}

fn printReport(report: zvmi.build_image.BuildImageReport, dry_run: bool) void {
    const gen_text = if (report.generation == .gen1) "Gen1" else "Gen2";
    const arch_text = switch (report.architecture) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
    };

    if (dry_run) {
        std.debug.print(
            "Dry run OK: format={s} generation={s} arch={s} size={d} rootfs={s}\n",
            .{ report.output_format.displayName(), gen_text, arch_text, report.disk_size, report.rootfs_path_in_iso },
        );
    } else {
        std.debug.print(
            "Built image: format={s} generation={s} arch={s} size={d} rootfs={s}\n",
            .{ report.output_format.displayName(), gen_text, arch_text, report.disk_size, report.rootfs_path_in_iso },
        );
    }

    for (report.planned_partitions) |partition| {
        std.debug.print(
            "  {s}: offset={d} length={d}\n",
            .{ partition.planned.name, partition.planned.offset_bytes, partition.planned.length_bytes },
        );
    }

    if (report.vhd_alignment) |alignment| {
        std.debug.print(
            "  vhd-alignment: old={d} new={d} resized={any}\n",
            .{ alignment.old_size, alignment.new_size, alignment.was_resized },
        );
    }
    if (report.partition_style) |style| {
        std.debug.print("  partition-style: {s}\n", .{style.message});
    }
}

fn fail(comptime format: []const u8, args: anytype) u8 {
    std.debug.print(format ++ "\n", args);
    return if (std.mem.startsWith(u8, format, "usage:")) 0 else 1;
}
