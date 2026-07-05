//! `zvmi build-image --iso <file.iso> --container <oci-layout> --generation 1|2 --size <size> -o <output.{raw|vhd|vhdx|qcow2}> [--skip-iso-rootfs] [--verity] [--extra-kernel-options <opts>] [--boot-mode bls|uki|both] [--stub-source-path <path>]`

const std = @import("std");
const zvmi = @import("zvmi");

const help_text =
    \\usage: zvmi build-image --iso <file.iso> --container <oci-layout> --generation 1|2 --size <size> -o <output.{{raw|vhd|vhdx|qcow2}}> [-O raw|vhd|vhdx|qcow2] [--rootfs-path <path>] [--skip-iso-rootfs] [--esp-size <size>] [--stub-source-path <path>] [--verity] [--extra-kernel-options <opts>] [--boot-mode bls|uki|both] [--dry-run] [-v]
    \\
    \\Options:
    \\  --boot-mode bls|uki|both   Gen2 boot files: GRUB+BLS only (default), UKI only, or both.
    \\  --esp-size <size>          ESP size (default 96M). UKI/both commonly need 512M or larger.
    \\  --skip-iso-rootfs          Use the container as the root filesystem; keep only boot-critical files from the ISO/squashfs.
    \\  --stub-source-path <path>  UKI/both only: use this systemd EFI stub path from the merged source tree.
    \\  --verity                   Append a dm-verity hash tree and wire the matching kernel arguments.
    \\  --extra-kernel-options     Extra kernel command-line arguments appended after root=...
    \\
    \\UKI notes:
    \\  A systemd EFI stub such as linuxx64.efi.stub, systemd-stubx64.efi, or the
    \\  matching aa64 variant must exist in the merged ISO/squashfs/container source tree,
    \\  usually via the systemd-boot-unsigned package.
    \\  If the base OS image does not ship it, inject that package via an extra container
    \\  layer or point --stub-source-path at the non-standard path you added.
;

const BuildImageFailureContext = struct {
    boot_mode: zvmi.bootconfig.BootMode = .bls_only,
    stub_source_path: ?[]const u8 = null,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    var iso_path: ?[]const u8 = null;
    var container_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var output_format: ?zvmi.Format = null;
    var rootfs_path: ?[]const u8 = null;
    var skip_iso_rootfs = false;
    var generation: zvmi.azure.Generation = .gen2;
    var size: ?u64 = null;
    var esp_size: ?u64 = null;
    var stub_source_path: ?[]const u8 = null;
    var enable_verity = false;
    var extra_kernel_options: []const u8 = "";
    var boot_mode: zvmi.bootconfig.BootMode = .bls_only;
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
        } else if (std.mem.eql(u8, arg, "--stub-source-path")) {
            i += 1;
            if (i >= args.len) return fail("build-image: --stub-source-path requires a path", .{});
            stub_source_path = args[i];
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
        } else if (std.mem.eql(u8, arg, "--skip-iso-rootfs")) {
            skip_iso_rootfs = true;
        } else if (std.mem.eql(u8, arg, "--verity")) {
            enable_verity = true;
        } else if (std.mem.eql(u8, arg, "--extra-kernel-options")) {
            i += 1;
            if (i >= args.len) return fail("build-image: --extra-kernel-options requires a value", .{});
            extra_kernel_options = args[i];
        } else if (std.mem.eql(u8, arg, "--boot-mode")) {
            i += 1;
            if (i >= args.len) return fail("build-image: --boot-mode requires bls, uki, or both", .{});
            if (std.mem.eql(u8, args[i], "bls")) {
                boot_mode = .bls_only;
            } else if (std.mem.eql(u8, args[i], "uki")) {
                boot_mode = .uki_only;
            } else if (std.mem.eql(u8, args[i], "both")) {
                boot_mode = .bls_and_uki;
            } else {
                return fail("build-image: invalid --boot-mode '{s}' (expected bls, uki, or both)", .{args[i]});
            }
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return fail(help_text, .{});
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
            .skip_iso_rootfs = skip_iso_rootfs,
            .esp_size = esp_size orelse zvmi.build_image.default_esp_size,
            .verity = enable_verity,
            .extra_kernel_options = extra_kernel_options,
            .boot_mode = boot_mode,
            .uki = .{
                .stub_source_path = stub_source_path,
            },
            .dry_run = dry_run,
            .verbose = verbose,
        }) catch |err| {
            const message = describeBuildImageFailure(gpa, err, .{
                .boot_mode = boot_mode,
                .stub_source_path = stub_source_path,
            }) catch return fail("build-image: failed: {s}", .{@errorName(err)});
            defer gpa.free(message);
            return fail("{s}", .{message});
        };
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

fn describeBuildImageFailure(
    allocator: std.mem.Allocator,
    err: anyerror,
    context: BuildImageFailureContext,
) std.mem.Allocator.Error![]u8 {
    const uki_mode_text = switch (context.boot_mode) {
        .uki_only => "--boot-mode uki",
        .bls_and_uki => "--boot-mode both",
        .bls_only => "UKI mode",
    };

    return switch (err) {
        error.MissingUkiStub => if (context.stub_source_path) |path|
            std.fmt.allocPrint(
                allocator,
                "build-image: failed: no systemd EFI stub was found at --stub-source-path {s} while preparing UKI boot files.\nExpected a stub such as linuxx64.efi.stub, systemd-stubx64.efi, or the matching aa64 variant, typically from the systemd-boot-unsigned package.\nInstall or inject that package into the merged source content, or update --stub-source-path to the correct in-tree location.",
                .{path},
            )
        else
            std.fmt.allocPrint(
                allocator,
                "build-image: failed: {s} was requested, but no systemd EFI stub was found in the merged ISO/squashfs/container source tree.\nExpected a stub such as linuxx64.efi.stub, systemd-stubx64.efi, or the matching aa64 variant, typically from the systemd-boot-unsigned package.\nInstall or inject that package into the source content (for example via an extra container layer), or pass --stub-source-path <path> if the stub already exists at a non-standard path.",
                .{uki_mode_text},
            ),
        error.EspTooSmallForBootArtifacts => allocator.dupe(
            u8,
            "build-image: failed: the ESP partition ran out of space while populating boot files.\nUKI mode stores large kernel/initrd payloads inside EFI binaries; try increasing --esp-size (512M is a good starting point for real distro images).",
        ),
        else => std.fmt.allocPrint(allocator, "build-image: failed: {s}", .{@errorName(err)}),
    };
}

test "describeBuildImageFailure explains MissingUkiStub" {
    const message = try describeBuildImageFailure(std.testing.allocator, error.MissingUkiStub, .{
        .boot_mode = .uki_only,
    });
    defer std.testing.allocator.free(message);

    try std.testing.expect(std.mem.indexOf(u8, message, "systemd-boot-unsigned") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "--stub-source-path") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "--boot-mode uki") != null);
}

test "describeBuildImageFailure mentions explicit stub path" {
    const message = try describeBuildImageFailure(std.testing.allocator, error.MissingUkiStub, .{
        .boot_mode = .bls_and_uki,
        .stub_source_path = "custom/linuxx64.efi.stub",
    });
    defer std.testing.allocator.free(message);

    try std.testing.expect(std.mem.indexOf(u8, message, "custom/linuxx64.efi.stub") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "systemd-boot-unsigned") != null);
}

test "describeBuildImageFailure explains small ESP for UKI artifacts" {
    const message = try describeBuildImageFailure(std.testing.allocator, error.EspTooSmallForBootArtifacts, .{});
    defer std.testing.allocator.free(message);

    try std.testing.expect(std.mem.indexOf(u8, message, "--esp-size") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "512M") != null);
}
